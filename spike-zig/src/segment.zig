// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const codec = @import("codec.zig");

/// 单调纳秒时钟（`Writer` 内部计时用）。
inline fn monoNs(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

pub const INDEX_STRIDE: usize = 64;
const FLUSH_BYTES: usize = 1 << 20;
/// `scanRefs` 这类「先收集再交还」的 API 用来落稳定 key 的分块 arena（实现在 codec 里，与段格式无关）。
pub const KeyArena = codec.KeyArena;
/// `PEKZIX05`：行格式改成「块内公共前缀压缩」（每 64 行一个块，块头 1 字节前缀长度），
/// 索引头多了 `max_klen`。旧库不兼容，按项目约定（尚未正式使用）直接升版本、不做迁移。
const IDX_MAGIC = "PEKZIX05";

/// 两串的最长公共前缀长度。
fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    // 8 字节 key（主流情形）一次 64 位异或 + 前导零个数就能算出前缀长度
    if (n >= 8) {
        const x = std.mem.readInt(u64, a[0..8], .big) ^ std.mem.readInt(u64, b[0..8], .big);
        if (x != 0) return @intCast(@clz(x) / 8);
        i = 8;
    }
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return i;
    }
    return n;
}

/// `push` 的升序不变量检查用（只在 Debug/ReleaseSafe 生效）。
fn keyCmpLessEq(a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) != .gt;
}

pub const IndexEntry = struct {
    offset: u64,
    key: []u8,
};

pub const RecordOwned = struct {
    key: []u8,
    seq: u64,
    flags: u8,
    value: []u8,
};

pub const Meta = struct {
    rows: usize,
    min_seq: u64,
    max_seq: u64,
};

/// 键比较（字节序即字典序）。
///
/// **8 字节 key 走单次 u64 比较**：`codec.encodeI64Key` 用大端编码，字节序就是数值序。
/// 扫描热路径每行要比较 1~2 次，逐字节循环在这里是可见开销（实测占 ~20%）。
/// `table.zig` 的 `recLess` / `refLess` 也复用它，不再各写一份。
pub fn keyCmp(a: []const u8, b: []const u8) std.math.Order {
    if (a.len == 8 and b.len == 8) {
        const x = std.mem.readInt(u64, a[0..8], .big);
        const y = std.mem.readInt(u64, b[0..8], .big);
        return std.math.order(x, y);
    }
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
    }
    if (a.len == b.len) return .eq;
    return if (a.len < b.len) .lt else .gt;
}

fn hashPair(key: []const u8) [2]u64 {
    const h1 = std.hash.Wyhash.hash(0, key);
    const h2 = (h1 *% 0x9E3779B97F4A7C15) | 1;
    return .{ h1, h2 };
}

/// 索引归档的只读映射（`seg/index.bin`）。
///
/// 为什么用 mmap 而不是「读进堆」：200 万行 25 段时间 3.13MB，`readPositionalAll`
/// 实测 1.0–1.6ms（3.1GB/s，是 Windows 内核拷贝的实速）。mmap 后：
/// - 建立映射 ~0.3ms，不拷贝；
/// - 只访问各段头部（`parseIdxHeader`）时只缺页 25 页（实测 0.022ms）；
/// - CRC 与 Bloom 在 `Segment.ensureParsed()` 时才访存，推迟到真正查询时。
///
/// 这就是 SQLite `sqlite3BtreeOpen` 的做法：open 只读第 1 页（`pPage1`），其余页按需缺页。
pub const IndexMap = struct {
    io: std.Io,
    file: std.Io.File,
    mm: std.Io.File.MemoryMap,

    pub fn bytes(self: *const IndexMap) []const u8 {
        return self.mm.memory;
    }

    /// 释放映射与文件句柄。**必须在 Table 生命周期结束前、或归档被 rename 覆盖后调用**
    /// （rename 本身不会被拒，见 `test "mmap 存活时 rename 覆盖同路径"`，但映射
    /// 仍指向旧 inode，内容会过期，所以之后必须不再使用）。
    pub fn destroy(self: *IndexMap) void {
        self.mm.destroy(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

/// 把整个文件映射成只读切片；空文件/不存在按 `FileNotFound` 上报（调用方据此区分「新建库」）。
pub fn mapWholeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, max: u64) !IndexMap {
    const f = try dir.openFile(io, path, .{});
    errdefer f.close(io);
    const size = (try f.stat(io)).size;
    if (size > max) return error.FileTooBig;
    if (size == 0) return error.FileNotFound;
    const mm = try std.Io.File.MemoryMap.create(io, f, .{
        .len = @intCast(size),
        .protection = .{ .read = true, .write = false },
    });
    return .{ .io = io, .file = f, .mm = mm };
}

pub fn readWholeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator, max: u64) ![]u8 {
    var t0: u64 = 0;
    if (timing_enabled) t0 = tick(io);
    const f = try dir.openFile(io, path, .{});
    defer f.close(io);
    // 先 stat 拿长度再一次性读：比「盲读 64KB 再扩容」少一次 read（实测后者慢 ~1ms / 25 段）。
    const size = (try f.stat(io)).size;
    if (size > max) return error.FileTooBig;
    const buf = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(buf);
    if (timing_enabled) {
        const t1 = tick(io);
        timing.idx_alloc += t1 - t0;
        t0 = t1;
    }
    const n = try f.readPositionalAll(io, buf, 0);
    if (timing_enabled) timing.idx_copy += tick(io) - t0;
    // 注意：这里**不能**手动 free（errdefer 已经会释放），否则是 double free
    if (n != buf.len) return error.UnexpectedEndOfFile;
    return buf;
}

// ---------------- 写入 ----------------

pub const Writer = struct {
    io: std.Io,
    file: std.Io.File,
    alloc: std.mem.Allocator,
    /// 本段累计耗时拆分（纳秒）。审计用：`big_put` 偶发单次 flush 卡到 373ms（正常 25ms），
    /// 而同一时刻的裸文件写探针完全正常（314 MB/s），所以必须拆开看是「建文件」「写」还是「sync」。
    /// 产品路径不计时（开销只有几个单调时钟读，但它们是导出字段，不影响热循环）。
    ns_create: u64 = 0,
    ns_write: u64 = 0,
    ns_sync: u64 = 0,
    /// Bloom 位数/key（0 = 不生成 Bloom）。默认 10（误报率 ~1%）。
    /// Bloom 占索引体积的 ~80%（200 万行时 2.4MB / 3.1MB），而它只对「不存在的 key」有用，
    /// 所以做成可配：关掉后索引只剩稀疏索引，冷重开与索引 IO 同步变小。
    bloom_bits: u8 = 10,
    buf: std.ArrayList(u8) = .empty,
    buf_base: u64 = 0,
    rows: usize = 0,
    entries: std.ArrayList(IndexEntry) = .empty,
    /// Bloom 位图，**创建时按预估行数一次性分配、push 时在线置位**。
    ///
    /// 旧做法是「先把每行 hash 收进 `ArrayList(u64)`，收尾时再统一置位」——
    /// 200 万行时那个数组要 **16MB**，比位图本身（10 bit/key ≈ 2.4MB）还大 6 倍，
    /// 而且收尾时还要再遍历一遍（缓存完全不友好）。
    ///
    /// 在线置位的前提是「位图大小先定」，所以 `create` 要一个 `expected_rows` 上界。
    /// 估大了只是位图偏大（误报率更低，无副作用）；估小了**仍然正确**——
    /// 位置按 `bits_len` 取模，行数超过预估只会抬高误报率，不会产生假阴性。
    bloom: std.ArrayList(u8) = .empty,
    /// 位图总位数（写进索引头，读取侧按同一个值算位置）。`bloom_bits == 0` 时为 0。
    bits_len: usize = 0,
    min_seq: u64 = std.math.maxInt(u64),
    max_seq: u64 = 0,
    /// 最后一个 `push` 的 key（= 本段最大 key，因为 push 按 key 升序调用）。
    ///
    /// **必须拷贝**（`last_buf`）：调用方把游标刚产出的 key 直接传进来，
    /// 而那些切片指向游标的双缓冲，下一次 `next()` 就会被覆写 ——
    /// 引用版会在 `compact` 里直接触发升序断言。
    last_key: []const u8 = &.{},
    last_buf: std.ArrayList(u8) = .empty,
    /// 本段内 key 长度上界（读侧靠它一次性预留重建缓冲，避免热路径分配）。
    max_klen: usize = 0,
    /// **块缓冲**：当前块最多 `INDEX_STRIDE` 条记录（key 先按完整长度写进来）。
    ///
    /// 为什么必须先攒一块再落盘：块内公共前缀只有看到「本块全部 key」才知道，
    /// 而 `push` 是流式的。攒满 64 行就定死前缀并就地改写，块大小与稀疏索引步长
    /// 一致（都指向块头），读侧不必再存第二套偏移。
    blk_buf: std.ArrayList(u8) = .empty,
    /// 每条记录在 `blk_buf` 里的起始偏移（行头首字节）
    blk_off: [INDEX_STRIDE]usize = @splat(0),
    /// 每条记录 **key** 在 `blk_buf` 里的起始偏移（= `blk_off[i]` + 行头长度）
    blk_koff: [INDEX_STRIDE]usize = @splat(0),
    blk_n: u32 = 0,
    /// 本块首条 key 的长度（它在 `blk_buf[blk_koff[0]..]`，是前缀来源）
    blk_first_klen: usize = 0,
    /// 当前块的公共前缀长度，**在 `push` 里增量收敛**。
    ///
    /// 不放着收尾时再算：那样收尾要重新解一遍每行的头，
    /// 实测把 `big_put` 拖慢 ~8%（写入路径本来就只有 6+8+32 字节的工作量）。
    blk_pfx: usize = 0,
    /// 文件句柄是否还开着（`finishBytes` 关掉后置 false）
    file_open: bool = true,
    /// 四个缓冲是否还没释放（`finishBytes` 成功后置 false）
    buffers_live: bool = true,

    /// `expected_rows`：本段将写入的行数**上界**，只用于定 Bloom 位图大小。
    /// `flushImpl` 传 memtable 行数（精确），`compact` 传各段行数之和（上界，去重后更少）。
    pub fn create(
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        alloc: std.mem.Allocator,
        bloom_bits: u8,
        expected_rows: usize,
    ) !Writer {
        const t_create = monoNs(io);
        const f = try dir.createFile(io, path, .{ .read = true, .truncate = true });
        var w = Writer{ .io = io, .file = f, .alloc = alloc, .bloom_bits = bloom_bits };
        if (bloom_bits > 0) {
            w.bits_len = @max(@as(usize, 64), expected_rows * @as(usize, bloom_bits));
            const bytes_len = (w.bits_len + 7) / 8;
            // errdefer 连文件一起关：下面 alloc 失败的话，createFile 建的句柄会漏。
            errdefer f.close(io);
            try w.bloom.resize(alloc, bytes_len);
            @memset(w.bloom.items, 0);
        }
        w.ns_create = monoNs(io) - t_create;
        return w;
    }

    /// 释放缓冲并关闭文件，**幂等**。
    ///
    /// 调用方应该无条件写上 `defer w.deinit()`：`finishBytes` 只在**成功路径**
    /// 自己释放；一旦 `push` / `flushBuf` / `sync` 失败，这 4 个缓冲与文件句柄就全漏了
    /// （M1 起就存在，第四轮审计才发现）。成功路径下本函数是 no-op。
    ///
    /// 幂等靠两个标志位：`std.ArrayList.deinit` 会把自身置 `undefined`，
    /// 不能靠「再 deinit 一次空表」来幂等 —— 那是在读 undefined。
    pub fn deinit(self: *Writer) void {
        if (self.file_open) {
            self.file.close(self.io);
            self.file_open = false;
        }
        if (self.buffers_live) self.releaseBuffers();
    }

    fn releaseBuffers(self: *Writer) void {
        for (self.entries.items) |e| self.alloc.free(e.key);
        self.entries.deinit(self.alloc);
        self.bloom.deinit(self.alloc);
        self.buf.deinit(self.alloc);
        self.blk_buf.deinit(self.alloc);
        self.last_buf.deinit(self.alloc);
        self.buffers_live = false;
    }

    /// **不变量：`key` 必须按升序（`keyCmp` ≤ 0）调用。**
    /// 段头写的是「最后一个 `push` 的 key」，只有在升序前提下它才等于段内最大 key；
    /// 一旦违序，`MergeIter` 的 `canConcat` 就会把「其实重叠」的两段判成不重叠 →
    /// 顺序拼接会产出乱序甚至漏行。
    /// 断言只在 Debug/ReleaseSafe 下有效（ReleaseFast 会整条抹掉，热路径零成本）；
    /// 现有调用方（memtable 刷盘 / compaction 归并）都是升序，测试也跑在 Debug 下。
    pub fn push(self: *Writer, key: []const u8, seq: u64, flags: u8, value: []const u8) !void {
        std.debug.assert(self.rows == 0 or keyCmpLessEq(self.last_key, key));
        std.debug.assert(self.blk_n < INDEX_STRIDE);
        const bi: usize = self.blk_n;

        // 先按**完整 key** 写进块缓冲；块攒满后再把公共前缀裁掉。
        // 行头：6 字节定长 + 哨兵逃逸（§16.1.26/§16.1.30）。编解码只有
        // `codec.writeRecHdr` / `codec.readRec` 这一对，两边必须同改。
        {
            var hdr: [6 + 33]u8 = undefined;
            const hn = codec.writeRecHdr(&hdr, key.len, value.len, seq, flags);
            self.blk_off[bi] = self.blk_buf.items.len;
            try self.blk_buf.appendSlice(self.alloc, hdr[0..hn]);
        }
        self.blk_koff[bi] = self.blk_buf.items.len;
        try self.blk_buf.appendSlice(self.alloc, key);
        try self.blk_buf.appendSlice(self.alloc, value);

        // 增量求块内公共前缀：只需和**块首 key** 比，不用碰其它行
        if (bi == 0) {
            self.blk_pfx = key.len;
            self.blk_first_klen = key.len;
        } else if (self.blk_pfx > 0) {
            const first = self.blk_buf.items[self.blk_koff[0]..][0..self.blk_first_klen];
            self.blk_pfx = commonPrefixLen(first[0..self.blk_pfx], key);
        }
        self.blk_n += 1;

        if (self.bits_len > 0) self.bloomSet(key);

        self.rows += 1;
        self.max_klen = @max(self.max_klen, key.len);
        self.min_seq = @min(self.min_seq, seq);
        self.max_seq = @max(self.max_seq, seq);
        self.last_buf.clearRetainingCapacity();
        try self.last_buf.appendSlice(self.alloc, key);
        self.last_key = self.last_buf.items;

        if (self.blk_n == INDEX_STRIDE) try self.flushBlock();
        if (self.buf.items.len >= FLUSH_BYTES) try self.flushBuf();
    }

    /// 把攒满（或收尾时不满）的一块落到 `buf`：**块内公共前缀压缩**。
    ///
    /// 块布局：`u8 pfx_len` + 最多 `INDEX_STRIDE` 条记录。
    /// - **第 1 条存完整 key**（它同时是本块后续记录的前缀来源，块因此自描述）；；
    /// - 第 2 条起只存 `key[pfx_len..]`。
    ///
    /// 稀疏索引项的 `offset` 指向**块头**（那个 pfx 字节），与 `INDEX_STRIDE` 对齐，
    /// 所以不需要第二套偏移表。
    ///
    /// 前缀在 `push` 里已经增量算好（`blk_pfx`），这里只做「原样搬两段字节」：
    /// `[行头] + [key 去掉前 pfx 字节后的部分 + value]` —— **不重新解头、不重编码**。
    fn flushBlock(self: *Writer) !void {
        if (self.blk_n == 0) return;
        const n: usize = @intCast(self.blk_n);
        const raw = self.blk_buf.items;
        // 块头只有 1 字节（≤255），而 key 长度没有上限：
        // 长 key 且块内共享超长前缀时，必须**截到 255**，否则 @intCast 溢出
        // （ReleaseFast 下是未定义行为，Debug 下直接 panic）。
        // 截断只损失一点压缩率，语义不变 —— 读侧按块头里的 pfx 补前缀，不会多不少。
        const pfx: usize = @min(self.blk_pfx, 255);
        const stored: u8 = @intCast(pfx);

        // 索引项：offset 指向即将写入的块头；key 用块首 key 的**拷贝**
        // （块首 key 在 `raw` 里，下一块就会复用）。
        {
            const first = raw[self.blk_koff[0]..][0..self.blk_first_klen];
            const k = try self.alloc.dupe(u8, first);
            errdefer self.alloc.free(k);
            try self.entries.append(self.alloc, .{
                .offset = self.buf_base + self.buf.items.len,
                .key = k,
            });
        }

        try self.buf.append(self.alloc, stored);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const hdr_end = self.blk_koff[i];
            const rec_end = if (i + 1 < n) self.blk_off[i + 1] else raw.len;
            // 行头原样搬（klen 仍写**完整**长度，读侧据此知道要补多少前缀字节）
            try self.buf.appendSlice(self.alloc, raw[self.blk_off[i]..hdr_end]);
            // 块首那条从 key 首字节开始，其余跳过公共前缀
            const skip: usize = if (i == 0) 0 else stored;
            try self.buf.appendSlice(self.alloc, raw[hdr_end + skip .. rec_end]);
        }

        self.blk_buf.clearRetainingCapacity();
        self.blk_n = 0;
        self.blk_pfx = 0;
    }

    /// 在线置位（k = 7）。位置算法与读取侧 `mayContain` 必须逐位一致。
    fn bloomSet(self: *Writer, key: []const u8) void {
        const hp = hashPair(key);
        const h1 = hp[0];
        const h2 = hp[1];
        std.debug.assert(self.bits_len > 0);
        var i: usize = 0;
        while (i < 7) : (i += 1) {
            const step: u64 = @as(u64, @intCast(i)) *% h2;
            const pos: usize = @intCast((h1 +% step) % @as(u64, self.bits_len));
            self.bloom.items[pos / 8] |= @as(u8, 1) << @intCast(pos % 8);
        }
    }

    fn flushBuf(self: *Writer) !void {
        if (self.buf.items.len == 0) return;
        const t = monoNs(self.io);
        try self.file.writePositionalAll(self.io, self.buf.items, self.buf_base);
        self.ns_write += monoNs(self.io) - t;
        self.buf_base += self.buf.items.len;
        self.buf.clearRetainingCapacity();
    }

    /// 收尾：落数据 + 返回索引字节（调用方决定写哪：单段 `.idx` 还是聚合 `index.bin`）。
    /// 调用后 Writer 不可再用。
    pub fn finishBytes(self: *Writer) !Finished {
        try self.flushBlock(); // 收尾时最后不满一块的残块
        try self.flushBuf();
        const t_sync = monoNs(self.io);
        try self.file.sync(self.io);
        self.ns_sync += monoNs(self.io) - t_sync;
        self.file.close(self.io);
        self.file_open = false;

        var idx: std.ArrayList(u8) = .empty;
        errdefer idx.deinit(self.alloc);
        try idx.appendSlice(self.alloc, IDX_MAGIC);
        try codec.putU64le(&idx, self.alloc, @intCast(self.rows));
        try codec.putU64le(&idx, self.alloc, if (self.rows == 0) 0 else self.min_seq);
        try codec.putU64le(&idx, self.alloc, self.max_seq);
        try codec.putU32le(&idx, self.alloc, @intCast(self.entries.items.len));
        // 段内最大 key（空段写 0 长度）。有了它才能判定「两段 key 范围是否重叠」，
        // 从而在 `MergeIter` 里走顺序拼接快路径（§16.1.21：25 路归并 → 单游标，+34%）。
        try codec.putU32le(&idx, self.alloc, @intCast(self.last_key.len));
        try idx.appendSlice(self.alloc, self.last_key);
        // 段内 key 长度上界：读侧用它一次性预留「块内前缀重建」缓冲，避免逐行分配。
        try codec.putU32le(&idx, self.alloc, @intCast(self.max_klen));
        for (self.entries.items) |e| {
            try codec.putU64le(&idx, self.alloc, e.offset);
            try codec.putU32le(&idx, self.alloc, @intCast(e.key.len));
            try idx.appendSlice(self.alloc, e.key);
        }

        // Bloom：默认 10 bit/key、k=7；bloom_bits=0 时 bits_len=0，读取侧 mayContain 直接返回 true。
        // 位图已在 push 期间填好，这里只是把 ownership 挪进索引字节。
        try codec.putU64le(&idx, self.alloc, self.bits_len);
        try idx.append(self.alloc, 7);
        if (self.bits_len > 0) try idx.appendSlice(self.alloc, self.bloom.items);
        try codec.putU64le(&idx, self.alloc, codec.hashIdx(idx.items));

        const meta = Meta{
            .rows = self.rows,
            .min_seq = if (self.rows == 0) 0 else self.min_seq,
            .max_seq = self.max_seq,
        };

        self.releaseBuffers();

        return .{ .bytes = try idx.toOwnedSlice(self.alloc), .meta = meta };
    }

    /// 便捷封装：落数据 + 写单段 `.idx` 文件（测试与独立段场景用）。
    pub fn finish(self: *Writer, idx_dir: std.Io.Dir, idx_path: []const u8) !Meta {
        const f = try self.finishBytes();
        defer self.alloc.free(f.bytes);
        var file = try idx_dir.createFile(self.io, idx_path, .{ .truncate = true });
        try file.writePositionalAll(self.io, f.bytes, 0);
        try file.sync(self.io);
        file.close(self.io);
        return f.meta;
    }
};

pub const Finished = struct {
    bytes: []u8,
    meta: Meta,
};

// ---------------- 索引聚合文件（seg/index.bin） ----------------
// 冷重开的最大成本原本是「每段一次 open/stat/read/close」：25 段实测 3.66ms，
// 而索引总量才 3MB。把全部段的索引按顺序追加进一个文件后，重开只需 **一次 open + 一次读**。
// 格式：ARCHIVE_MAGIC(8) 之后为连续 record：{ u32 len, u32 crc32Fast(payload), payload[len] }；
// payload 就是单段 `.idx` 的完整内容（自带 magic 与尾部 CRC，读取时仍逐段校验、能定位损坏段）。
// 只追加不改写，所以 flush 的代价仍是一段索引的大小。
pub const ARCHIVE_MAGIC = "PEKZAG06";

/// 校验归档文件头。空文件（新建库）视为合法。
pub fn archiveCheckMagic(bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (bytes.len < ARCHIVE_MAGIC.len or !std.mem.eql(u8, bytes[0..ARCHIVE_MAGIC.len], ARCHIVE_MAGIC)) {
        return error.BadArchiveMagic;
    }
}

pub const ArchiveRecord = struct {
    /// 段号（跟数据文件名里的数字一致）。
    /// **不能靠 record 在文件里的序号推断**：compaction 后新段的段号会比段数大得多。
    id: u32,
    payload: []const u8,
};

pub const ArchiveIter = struct {
    buf: []const u8,
    pos: usize = 8,

    /// 取下一段索引；遇到截断的 record（追加时崩溃）就停下，等效于该段不存在。
    pub fn next(self: *ArchiveIter) ?ArchiveRecord {
        if (self.buf.len < 16 or self.pos + 16 > self.buf.len) return null;
        const len: usize = @intCast(std.mem.readInt(u32, self.buf[self.pos..][0..4], .little));
        const id = std.mem.readInt(u32, self.buf[self.pos + 4 ..][0..4], .little);
        const off = self.pos + 16;
        if (off + len > self.buf.len) return null;
        self.pos = off + len;
        return .{ .id = id, .payload = self.buf[off..][0..len] };
    }

    /// 最后一条**完整** record 的末尾偏移（= 下次追加应写的位置）。
    /// 尾部若有崩溃残片，必须从这里覆盖，不能接在残片后面
    /// （否则迭代器永远越过不了残片，新段会永久不可见 —— 已由用例守住）。
    pub fn validEnd(self: *const ArchiveIter) u64 {
        return @intCast(self.pos);
    }
};

fn writeRecord(f: std.Io.File, io: std.Io, at: u64, id: u32, payload: []const u8) !u64 {
    var hdr: [16]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len), .little);
    std.mem.writeInt(u32, hdr[4..8], id, .little);
    std.mem.writeInt(u64, hdr[8..16], codec.hashIdx(payload), .little);
    try f.writePositionalAll(io, &hdr, at);
    try f.writePositionalAll(io, payload, at + 16);
    return at + 16 + payload.len;
}

/// 重写整个归档（compaction 用）：写临时文件 → 原子 rename 覆盖目标。
/// 这样「重写归档途中断电」不会留下半个文件导致整个库打不开。
/// 返回新的有效末尾。
pub fn archiveRewrite(io: std.Io, dir: std.Io.Dir, path: []const u8, records: []const ArchiveRecord, alloc: std.mem.Allocator) !u64 {
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);

    var at: u64 = 8;
    {
        const f = try dir.createFile(io, tmp_path, .{ .read = true, .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, ARCHIVE_MAGIC, 0);
        for (records) |r| at = try writeRecord(f, io, at, r.id, r.payload);
        try f.sync(io);
    }
    try dir.rename(tmp_path, dir, path, io);
    return at;
}

/// 追加一段索引，从 `at` 处开始写（会覆盖该位置之后的残片），返回新的有效末尾。
/// `at < 8` 视为新建，先写 magic。
pub fn archiveAppend(io: std.Io, dir: std.Io.Dir, path: []const u8, id: u32, payload: []const u8, at_in: u64) !u64 {
    // truncate=false：已存在则保留内容
    const f = try dir.createFile(io, path, .{ .read = true, .truncate = false });
    defer f.close(io);
    var at = at_in;
    // 用**文件实际长度**判断是否新建：不能只看 `at_in`，因为空库的 valid_len 初值就是 8，
    // 那样首条 record 会写在没有 magic 的文件头（曾导致 archiveCheckMagic 报 BadArchiveMagic）。
    if ((try f.stat(io)).size < ARCHIVE_MAGIC.len) {
        try f.writePositionalAll(io, ARCHIVE_MAGIC, 0);
        at = 8;
    } else if (at < 8) {
        at = 8;
    }
    const new_end = try writeRecord(f, io, at, id, payload);
    // 截断到新末尾：若之前尾部有更长的崩溃残片，残留字节会被下一次读取当成
    // 一条「看似合法」的 record（虽然 hash 会拒掉，但会让整个库打开失败）。
    try f.setLength(io, new_end);
    try f.sync(io);
    return new_end;
}

// ---------------- 读取 ----------------

/// 段内稀疏索引项：key 不单独分配，而是记录它在 `.idx` 整块缓冲里的偏移。
/// 这样一个段只做 **1 次大分配 + 1 次 entries 数组分配**，而不是「每项一个 key」。
pub const Entry = struct {
    offset: u64,
    key_off: u32,
    key_len: u32,
};

/// 诊断：打开段的分阶段耗时（纳秒）。默认关，仅基准/排查时打开。
/// **不是线程安全的**：开启时不能与 `Table.Options.parallel_open = true` 同用（累加会竞争，
/// 且并行时累加得到的是各线程耗时之和而非墙钟）。
pub const Timing = struct {
    idx_open: u64 = 0,
    idx_read: u64 = 0,
    crc: u64 = 0,
    parse: u64 = 0,
    data_open: u64 = 0,
    mmap: u64 = 0,
    // 以下为 Table.open 层面的分项（不属于单个段）
    dirs: u64 = 0,
    wal_replay: u64 = 0,
    wal_open: u64 = 0,
    segs: u64 = 0,
    /// 每段：建路径 + 构造 Segment（含 CRC/解析）
    mkseg: u64 = 0,
    /// 每段：数组 append
    seg_append: u64 = 0,
    /// `readWholeFile` 的分配阶段（smp_allocator 大块走 mmap，首次写有却页）。
    /// 单独计是为了判断 3.13MB 索引读入的 1.3ms 到底花在「分配+却页」还是「内核拷贝」。
    idx_alloc: u64 = 0,
    /// `readWholeFile` 的 readPositionalAll 阶段（内核从页缓存拷到用户空间）。
    idx_copy: u64 = 0,
};
pub var timing_enabled: bool = false;
pub var timing: Timing = .{};

pub fn tick(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

pub const Segment = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    dir: std.Io.Dir = undefined,
    /// 数据文件定位：`id == 0` 时 base_path 就是完整路径（单段场景）；
    /// `id > 0` 时首次读数据才拼 `{base_path}/seg/{id:0>6}.data`。
    /// 这样做是为了让重开时**不碰字符串**（25 段 × 拼路径 + 分配实测占 0.3ms）。
    base_path: []const u8 = &.{},
    id: u64 = 0,
    preheat: bool = false,
    mapped: bool = false,
    data: []const u8 = &.{},
    mm: ?std.Io.File.MemoryMap = null,
    file: ?std.Io.File = null,
    /// 索引字节：单段 `.idx` 文件内容，或聚合 `index.bin` 里本段的切片。
    /// `owns_idx=true` 时由本段负责释放（单文件模式 / flush 后接管）；
    /// `false` 时指向 Table 持有的聚合缓冲（生命周期由 Table 管）。
    idx: []const u8 = &.{},
    owns_idx: bool = false,
    entries: std.ArrayList(Entry) = .empty,
    /// 稀疏索引总条数（来自段头部，**不需要解析全量 entries 就能知道**）。
    n_entries: u32 = 0,
    /// 段内最大 key 在 `idx` 里的偏移/长度（0 长度 = 空段）。
    max_key_off: u32 = 0,
    max_key_len: u32 = 0,
    /// 段内 key 长度上界（写索引时记录的），用于一次性预留行重建缓冲。
    max_klen: u32 = 0,
    /// 复用的行迭代器（`get` / `scanRefs` / `scanRange` 专用）。
    /// **游标不共用它**：`RefCursor` 自带一份，否则多段归并时会被互相覆盖。
    it: ?codec.RecIter = null,
    /// `scanRefs` 的 key arena（压缩块重建出来的 key 只在一两行内有效，收集型 API 必须掉到稳定内存）。
    key_arena: codec.KeyArena = .{},
    /// `entries` / `bits_*` / CRC 是否已真正解析。
    /// 对齐 SQLite：`sqlite3BtreeOpen` 只读第 1 页（`pPage1`），叶页/索引页按需缺页。
    /// 我们同样只读段头部（magic + 行数/seq 水位 + 第 1 条稀疏索引），
    /// 足够做段裁剪与可见性判定，剩下的 entries/Bloom/CRC 推到 `ensureParsed()`。
    parsed: bool = false,
    bits_off: u32 = 0,
    bits_len: u64 = 0,
    rows: usize = 0,
    min_seq: u64 = 0,
    max_seq: u64 = 0,
    file_size: u64 = 0,

    pub fn entryKey(self: *const Segment, i: usize) []const u8 {
        std.debug.assert(self.parsed);
        const e = self.entries.items[i];
        return self.idx[e.key_off..][0..e.key_len];
    }

    /// 段内最小 key（第 1 条稀疏索引）。
    /// **不要求 `ensureParsed()`** —— 头部解析时就已装好第 1 条，段裁剪靠它。
    pub fn firstKey(self: *const Segment) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        const e = self.entries.items[0];
        return self.idx[e.key_off..][0..e.key_len];
    }

    /// 段内最大 key（头部就有）。**空段**返回 null。
    /// 与 `firstKey()` 配合就能判定「两段 key 范围是否重叠」（顺序拼接的前提），
    /// 也能判定「整段是否落在查询起点之前」（反向段裁剪）。
    ///
    /// 判空段用 `rows`，**不能用 `max_key_len == 0`**：空字符串是合法 key
    /// （`Table.put` 不校验），「最后一条记录的 key 是 ``」写出的 klen 也是 0。
    /// 两种情形混淆的后果：两个都含空 key 的段（真重叠）会被 `canConcat` 当成
    /// 「前面那段是空的」而放行 → 顺序拼接先吐旧版本、再被 `last_key` 去重吃掉
    /// 新版本 → **返回陈旧值**（用例 `空字符串 key` 守着这条）。
    pub fn maxKey(self: *const Segment) ?[]const u8 {
        if (self.rows == 0) return null;
        return self.idx[self.max_key_off..][0..self.max_key_len];
    }

    /// 首次真正使用本段（扫描/点查/Bloom）前调用：完成 CRC 校验 + entries + Bloom 解析。
    ///
    /// 代价说明：CRC 覆盖整段字节，所以一次 `ensureParsed()` 必然访存整段 ——
    /// 这正是「open 只读头部」换来的推迟，不是省掉。要判断值不值，请看
    /// `big_recover`（纯 open）与 `big_get_after_reopen`（重开+查询）两个指标的变化。
    pub fn ensureParsed(self: *Segment) !void {
        if (self.parsed) return;
        try self.parseIdxBody(self.idx);
        self.parsed = true;
    }

    /// `preheat`：是否在打开时就把数据文件全部读进页缓存。
    /// 默认 **false**（懒加载）——冷重开只加载索引，数据文件连 open/mmap 都推迟到首次读；
    /// 点查里 Bloom 不通过的段根本不会打开数据文件。
    pub fn open(
        io: std.Io,
        dir: std.Io.Dir,
        data_path: []const u8,
        idx_path: []const u8,
        alloc: std.mem.Allocator,
        preheat: bool,
    ) !Segment {
        var t0: u64 = 0;
        if (timing_enabled) t0 = tick(io);
        const idx_bytes = try readWholeFile(io, dir, idx_path, alloc, 64 << 20);
        errdefer alloc.free(idx_bytes);
        if (timing_enabled) {
            const t1 = tick(io);
            timing.idx_read += t1 - t0;
            t0 = t1;
        }
        var seg = Segment{ .io = io, .alloc = alloc, .idx = idx_bytes, .owns_idx = true };
        errdefer seg.entries.deinit(alloc);
        try seg.parseIdxHeader(idx_bytes);
        try seg.attach(dir, data_path, 0, preheat);
        return seg;
    }

    /// 从聚合索引里的切片构造（不读文件；`take_ownership` 决定是否接管这块内存）。
    /// `base_path` + `id` 只是记下位置，路径拼装推迟到首次读数据。
    pub fn fromBytes(
        io: std.Io,
        dir: std.Io.Dir,
        base_path: []const u8,
        id: u64,
        payload: []const u8,
        alloc: std.mem.Allocator,
        take_ownership: bool,
        preheat: bool,
    ) !Segment {
        var seg = Segment{
            .io = io,
            .alloc = alloc,
            .idx = payload,
            .owns_idx = take_ownership,
        };
        errdefer seg.entries.deinit(alloc);
        try seg.parseIdxHeader(payload);
        try seg.attach(dir, base_path, id, preheat);
        return seg;
    }

    fn attach(self: *Segment, dir: std.Io.Dir, base_path: []const u8, id: u64, preheat: bool) !void {
        // 数据文件延迟打开 + 延迟 mmap（冷重开只做索引）；preheat=true 时立即建视图。
        self.dir = dir;
        self.base_path = base_path;
        self.id = id;
        self.preheat = preheat;
        if (preheat) _ = try self.dataView();
    }

    /// 解析一段索引的字节：自己带 magic + 尾部 CRC（聚合归档里定位损坏段用）。
    ///
    /// 拆成两半：
    /// - `parseIdxHeader`：open 时只读这一段（magic + 行数/seq 水位 + 第 1 条稀疏索引），
    ///   几十字节就够做段裁剪与可见性判定；
    /// - `parseIdxBody`：首次使用时才做（CRC 覆盖整段，必须全读）。
    fn parseIdxHeader(self: *Segment, idx_bytes: []const u8) !void {
        if (idx_bytes.len < 16) return error.BadIndexChecksum;
        if (!std.mem.eql(u8, idx_bytes[0..8], IDX_MAGIC)) return error.BadIndexMagic;

        var r = codec.Reader{ .buf = idx_bytes[8..] };
        self.rows = @intCast(try r.u64le());
        self.min_seq = try r.u64le();
        self.max_seq = try r.u64le();
        self.n_entries = @intCast(try r.u32le());

        // 段内最大 key（§16.1.21）：顺序拼接判定靠它，所以必须在头部读出来。
        const mklen: usize = @intCast(try r.u32le());
        const mk = try r.bytes(mklen);
        self.max_key_off = @intCast(@intFromPtr(mk.ptr) - @intFromPtr(idx_bytes.ptr));
        self.max_key_len = @intCast(mklen);
        self.max_klen = try r.u32le();

        // 第 1 条稀疏索引就是段内最小 key —— 段裁剪只需要它。
        // 先把它装进 `entries`，这样「只 open 不查询」的路径也能正确裁剪。
        if (self.n_entries > 0) {
            const off = try r.u64le();
            const klen: usize = @intCast(try r.u32le());
            const key = try r.bytes(klen);
            try self.entries.append(self.alloc, .{
                .offset = off,
                .key_off = @intCast(@intFromPtr(key.ptr) - @intFromPtr(idx_bytes.ptr)),
                .key_len = @intCast(klen),
            });
        }
    }

    /// 全量解析（CRC + 全部稀疏索引 + Bloom）。
    fn parseIdxBody(self: *Segment, idx_bytes: []const u8) !void {
        var t0: u64 = 0;
        if (timing_enabled) t0 = tick(self.io);
        if (idx_bytes.len < 16 or std.mem.readInt(u64, idx_bytes[idx_bytes.len - 8 ..][0..8], .little) != codec.hashIdx(idx_bytes[0 .. idx_bytes.len - 8])) {
            return error.BadIndexChecksum;
        }
        if (!std.mem.eql(u8, idx_bytes[0..8], IDX_MAGIC)) return error.BadIndexMagic;

        if (timing_enabled) {
            const t1 = tick(self.io);
            timing.crc += t1 - t0;
            t0 = t1;
        }

        self.entries.clearRetainingCapacity();
        var r = codec.Reader{ .buf = idx_bytes[8..] };
        _ = try r.u64le(); // rows（头部已读）
        _ = try r.u64le(); // min_seq
        _ = try r.u64le(); // max_seq
        const n: usize = @intCast(try r.u32le());
        // 跳过头部已读的 max_key（它已在 `parseIdxHeader` 里记好偏移）
        const mklen: usize = @intCast(try r.u32le());
        _ = try r.bytes(mklen);
        self.max_klen = try r.u32le();
        try self.entries.ensureTotalCapacity(self.alloc, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const off = try r.u64le();
            const klen: usize = @intCast(try r.u32le());
            const key = try r.bytes(klen);
            self.entries.appendAssumeCapacity(.{
                .offset = off,
                .key_off = @intCast(@intFromPtr(key.ptr) - @intFromPtr(idx_bytes.ptr)),
                .key_len = @intCast(klen),
            });
        }
        self.bits_len = try r.u64le();
        const k = try r.u8v();
        const bits_bytes = (self.bits_len + 7) / 8;
        const bits = try r.bytes(@intCast(bits_bytes));
        self.bits_off = @intCast(@intFromPtr(bits.ptr) - @intFromPtr(idx_bytes.ptr));

        // k 未存进结构：固定 7（与写入一致）
        _ = k;

        if (timing_enabled) {
            const t1 = tick(self.io);
            timing.parse += t1 - t0;
        }
    }

    /// 首次访问数据视图时才 open + mmap（"按需打开"）。
    /// 单表串行执行模型下无需同步；**不要在多线程里同时首次访问同一个段**。
    /// 失败时**不**置 mapped，允许下一个调用重试（否则会永久返回空视图）。
    fn dataView(self: *Segment) ![]const u8 {
        if (self.mapped) return self.data;
        if (self.base_path.len == 0) {
            self.mapped = true;
            return self.data;
        }

        var tmp: ?[]u8 = null;
        defer if (tmp) |p| self.alloc.free(p);
        const path: []const u8 = if (self.id == 0) self.base_path else blk: {
            const p = try std.fmt.allocPrint(self.alloc, "{s}/seg/{d:0>6}.data", .{ self.base_path, self.id });
            tmp = p;
            break :blk p;
        };

        var t0: u64 = 0;
        if (timing_enabled) t0 = tick(self.io);
        const f = try self.dir.openFile(self.io, path, .{});
        // 先 stat 再落字段：否则 stat 失败时 f 已存进 self.file，重试会把它覆盖掉（句柄泄漏）
        const st = f.stat(self.io) catch |e| {
            f.close(self.io);
            return e;
        };
        self.file = f;
        self.file_size = st.size;
        if (timing_enabled) {
            const t1 = tick(self.io);
            timing.data_open += t1 - t0;
            t0 = t1;
        }
        if (self.file_size > 0) {
            var mm = try std.Io.File.MemoryMap.create(self.io, f, .{
                .len = @intCast(self.file_size),
                .protection = .{ .read = true, .write = false },
            });
            errdefer mm.destroy(self.io);
            if (self.preheat) try mm.read(self.io);
            self.mm = mm;
            self.data = mm.memory;
        }
        if (timing_enabled) timing.mmap += tick(self.io) - t0;
        // 只有全邨成功才标记，失败的调用可以被重试
        self.mapped = true;
        return self.data;
    }

    pub fn close(self: *Segment) void {
        self.entries.deinit(self.alloc);
        if (self.it) |*it| it.deinit(self.alloc);
        self.key_arena.deinit(self.alloc);
        if (self.owns_idx and self.idx.len > 0) self.alloc.free(@constCast(self.idx));
        if (self.mm) |*m| m.destroy(self.io);
        if (self.file) |f| f.close(self.io);
        self.* = undefined;
    }

    /// 取（必要时建）复用的行迭代器，并把数据视图换成本段的。
    /// `get` / `scanRefs` / `scanRange` 都是「一次调用从头扫一遍」，不会嵌套，所以可以共用。
    fn iter(self: *Segment) !*codec.RecIter {
        const view = try self.dataView();
        if (self.it == null) self.it = try codec.RecIter.init(self.alloc, view, INDEX_STRIDE, self.max_klen);
        const it = &self.it.?;
        it.buf = view;
        it.sink = null; // 只有 `scanRefs` 需要稳定切片，其余入口保持双缓冲
        return it;
    }

    fn mayContain(self: *const Segment, key: []const u8) bool {
        // 未解析时 `bits_len` 还是 0，会误以为「没有 Bloom、一律放行」——
        // 结果不丢数据但会静默退化成「每段全扫」。所有入口都已 `ensureParsed`，
        // 这里用断言守住，防将来新增入口时漏调。
        std.debug.assert(self.parsed);
        if (self.bits_len == 0) return true;
        const bits = self.idx[self.bits_off..];
        const hp = hashPair(key);
        var i: usize = 0;
        while (i < 7) : (i += 1) {
            const pos: usize = @intCast((hp[0] +% (@as(u64, i) *% hp[1])) % self.bits_len);
            if ((bits[pos / 8] & (@as(u8, 1) << @intCast(pos % 8))) == 0) return false;
        }
        return true;
    }

    fn candidateIndex(self: *const Segment, key: []const u8) usize {
        // 未解析时 `entries` 只有头部装的那 1 条，二分会在 1 条里找 → **结果错**。
        // 这是懒解析最危险的一处静默错误，用断言守住。
        std.debug.assert(self.parsed);
        // 找「第一个段首 key >= target」的块，再回退一块 —— 也就是
        // 「最后一个段首 key **严格小于** target 的块」。
        //
        // **不能用「最后一个段首 key ≤ target」**（即 `== .gt` 那版）：同一 key 的多个版本
        // 会跨段界（稀疏索引每 64 行一条，而版本列是按 seq 降序排的），
        // 那时第 i−1 块与第 i 块的段首 key **都是这个 key**，
        // 从第 i 块开始扫就漏掉了第 i−1 块里更新的版本 → **读到旧值**
        // （用例 `同一 key 的多个版本跨过索引边界` 守着，撤掉修复会返回 v6 而不是 v70）。
        //
        // 代价：仅当 target 恰好等于某个段首 key 时才多扫一块（约 1/64 的查询），
        // 其余情形与旧写法完全一致。
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (keyCmp(self.entryKey(mid), key) != .lt) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        if (lo == 0) return 0;
        return lo - 1;
    }

    /// 点查：Bloom 否定 → 稀疏索引定位 → 读出该段记录扫描。
    /// out 为避免每次分配的复用缓冲；返回 flags。
    pub fn get(self: *Segment, key: []const u8, snapshot: u64, out: *std.ArrayList(u8)) !?u8 {
        try self.ensureParsed();
        if (!self.mayContain(key)) return null;
        if (self.entries.items.len == 0) return null;

        const i = self.candidateIndex(key);
        const begin: usize = @intCast(self.entries.items[i].offset);
        const it = try self.iter();
        // 上界要**放宽一块**：`candidateIndex` 返回的是「最后一个段首 key 严格小于 target 的块」，
        // 当 target 恰好是下一块的段首 key 时，`begin` 就在它的**前一块**上。
        // 只放到 `entries[i+1]` 会在扫完前一块就停，target 根本见不到 → 返回 null
        // （用例 `同一 key 的多个版本跨过索引边界` 与 `>255 公共前缀` 都会踩到）。
        const end: u64 = if (i + 2 < self.entries.items.len) self.entries.items[i + 2].offset else it.buf.len;
        if (end <= begin) return null;
        it.seek(begin);

        var pos: usize = begin;
        while (pos < end) {
            const rec = it.next(self.alloc) orelse break;
            pos = rec.next;
            switch (keyCmp(rec.key, key)) {
                .lt => continue,
                .gt => return null,
                .eq => {
                    if (rec.seq <= snapshot) {
                        out.clearRetainingCapacity();
                        try out.appendSlice(self.alloc, rec.value);
                        return rec.flags;
                    }
                },
            }
        }
        return null;
    }

    pub const RefRecord = struct {
        key: []const u8,
        seq: u64,
        flags: u8,
        value: []const u8,
    };

    /// 零拷贝扫描：值的切片借用 mmap（调用方保证段存活）。
    /// 同一 key 只输出一个可见版本（墓碑跳过）。
    /// **`key` 落在本段的 `key_arena` 里**：在下一次 `scanRefs` 之前有效。
    pub fn scanRefs(self: *Segment, start: []const u8, end: []const u8, snapshot: u64, out: *std.ArrayList(RefRecord)) !void {
        try self.ensureParsed();
        if (self.entries.items.len == 0) return;
        self.key_arena.reset(self.alloc);
        const i = self.candidateIndex(start);
        const it = try self.iter();
        it.sink = &self.key_arena; // 收集型 API：key 直接重建进 arena
        it.seek(@intCast(self.entries.items[i].offset));
        // 只回看**上一行**的 key 判重：双缓冲就是为这个设计的。
        // 写成「记住上一次换 key 的那行」会把回看距离拉到任意远 → 缓冲被覆盖 → 误判重复、漏行。
        var prev_key: []const u8 = &.{};
        var have_prev = false;
        var decided = false;

        while (it.next(self.alloc)) |rec| {
            switch (keyCmp(rec.key, end)) {
                .gt, .eq => return,
                .lt => {},
            }
            if (keyCmp(rec.key, start) == .lt) continue;
            const same = have_prev and std.mem.eql(u8, rec.key, prev_key);
            prev_key = rec.key;
            have_prev = true;
            if (!same) decided = false;
            if (decided) continue;
            if (rec.seq <= snapshot) {
                decided = true;
                if (rec.flags == 0) try out.append(self.alloc, .{ .key = rec.key, .seq = rec.seq, .flags = rec.flags, .value = rec.value });
            }
        }
    }

    /// 流式游标：按 (key asc, seq desc) 逐条产出可见记录（不去重）。
    pub fn cursor(self: *Segment, start: []const u8, end: []const u8, snapshot: u64) !RefCursor {
        try self.ensureParsed();
        const view = try self.dataView();
        var pos: usize = view.len;
        if (self.entries.items.len > 0) {
            pos = @intCast(self.entries.items[self.candidateIndex(start)].offset);
        }
        // **游标自带一份迭代器**：多段归并时每个游标都要同时活着，不能共用段上的那份。
        var it = try codec.RecIter.init(self.alloc, view, INDEX_STRIDE, self.max_klen);
        it.seek(pos);
        // 空 start = 无下界：直接标记已越过，省掉每行一次无谓的 key 比较
        return .{ .seg = self, .pos = pos, .start = start, .end = end, .snapshot = snapshot, .passed_start = start.len == 0, .it = it };
    }

    /// 范围扫描（start 含、end 排他），只输出 seq <= snapshot 的记录（含墓碑）。
    pub fn scanRange(
        self: *Segment,
        start: []const u8,
        end: []const u8,
        snapshot: u64,
        out: *std.ArrayList(RecordOwned),
    ) !void {
        try self.ensureParsed();
        if (self.entries.items.len == 0) return;
        const i = self.candidateIndex(start);
        const it = try self.iter();
        it.seek(@intCast(self.entries.items[i].offset));

        while (it.next(self.alloc)) |rec| {
            switch (keyCmp(rec.key, end)) {
                .gt, .eq => return,
                .lt => {},
            }
            if (keyCmp(rec.key, start) == .lt) continue;
            if (rec.seq > snapshot) continue;
            try out.append(self.alloc, .{
                .key = try self.alloc.dupe(u8, rec.key),
                .seq = rec.seq,
                .flags = rec.flags,
                .value = try self.alloc.dupe(u8, rec.value),
            });
        }
    }
};

pub const RefCursor = struct {
    seg: *Segment,
    pos: usize,
    start: []const u8,
    end: []const u8,
    snapshot: u64,
    /// 是否已越过 start。稀疏索引每 64 行一项，定位后最多再跳 63 行就到起点，
    /// 之后不必每行都和 start 比（热路径上省一次 key 比较）。
    passed_start: bool = false,
    /// 本游标**独立**的行迭代器（块内前缀重建缓冲）。
    /// 它随游标一起存放于 `MergeIter.cursors`（堆上的稳定数组），所以返回的 key
    /// 切片在游标存活期间一直有效 —— 双缓冲保证「上一行」在下一条产出后仍可读。
    it: codec.RecIter,

    pub fn deinit(self: *RefCursor) void {
        self.it.deinit(self.seg.alloc);
    }

    pub fn next(self: *RefCursor) ?Segment.RefRecord {
        while (self.it.next(self.seg.alloc)) |rec| {
            self.pos = rec.next;

            // 空 end = 无上界（compaction 全量归并时用）
            if (self.end.len > 0) {
                switch (keyCmp(rec.key, self.end)) {
                    .gt, .eq => return null,
                    .lt => {},
                }
            }
            if (!self.passed_start) {
                if (keyCmp(rec.key, self.start) == .lt) continue;
                self.passed_start = true;
            }
            if (rec.seq > self.snapshot) continue;
            return .{ .key = rec.key, .seq = rec.seq, .flags = rec.flags, .value = rec.value };
        }
        return null;
    }
};

test "segment idx 被翻位后必须报错（不静默返回错误结果）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-segment-corrupt";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);

    {
        var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc, 10, 2);
        defer w.deinit();
        try w.push("a", 1, 0, "va");
        try w.push("b", 2, 0, "vb");
        _ = try w.finish(dir, tmp ++ "/000001.idx");
    }

    // 改 bloom 尾部一个字节（既不破坏 magic，也与尾部哈希不符）。
    //
    // **不能翻 `len/2`**：头部（rows/min_seq/max_seq/n/max_key 长度）不参加 CRC 校验
    // （懒解析只在 `ensureParsed` 校验），翻到那里的长度字段会先报 `error.Truncated`，
    // 而不是这里要验证的 `BadIndexChecksum`。这是「open 只读头部」的固有代价：
    // 头部结构性损坏可能先以解析错误的形式暴露。
    {
        const bytes = try readWholeFile(io, dir, tmp ++ "/000001.idx", alloc, 1 << 20);
        defer alloc.free(bytes);
        bytes[bytes.len - 16] ^= 0xFF;
        var f = try dir.createFile(io, tmp ++ "/000001.idx", .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, bytes, 0);
    }

    // CRC 改为**懒校验**（对齐 SQLite：open 只读第 1 页，页完整性在使用时才发现）。
    // 所以这里不能指望 `open` 就报错，必须走到 `ensureParsed()` 才校验。
    var seg = try Segment.open(io, dir, tmp ++ "/000001.data", tmp ++ "/000001.idx", alloc, false);
    defer seg.close();
    try std.testing.expectError(error.BadIndexChecksum, seg.ensureParsed());
}

test "segment：块内前缀 >255 字节（块头 1 字节必须截断）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-longpfx-tmp";
    dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);
    defer dir.deleteTree(io, tmp) catch {};

    // 70 条 key：前 300 字节完全相同，后 6 字节是升序编号。
    // 块头只有 1 字节 pfx（≤255），所以写入侧必须把前缀**截到 255**；
    // 不截断就是 @intCast 溢出（Debug panic / ReleaseFast UB）。
    // 70 条 > INDEX_STRIDE(64)，正好跨两块：满块 + 残块，两条路径都覆盖。
    const N = 70;
    var common: [300]u8 = @splat('p');
    var keys: [N][306]u8 = undefined;
    for (&keys, 0..) |*k, i| {
        @memcpy(k[0..300], &common);
        std.mem.writeInt(u48, k[300..306], @intCast(i), .big);
    }

    {
        var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc, 10, N);
        defer w.deinit();
        for (&keys, 0..) |*k, i| try w.push(k, i + 1, 0, "v");
        _ = try w.finish(dir, tmp ++ "/000001.idx");
    }

    var seg = try Segment.open(io, dir, tmp ++ "/000001.data", tmp ++ "/000001.idx", alloc, false);
    defer seg.close();

    // 点查：跨块边界两侧各取一条
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for ([_]usize{ 0, 63, 64, N - 1 }) |i| {
        try std.testing.expectEqual(@as(u8, 0), (try seg.get(&keys[i], N + 1, &out)).?);
        try std.testing.expectEqualStrings("v", out.items);
    }

    // 全量扫描：每条 key 必须逐字节还原
    var rows: std.ArrayList(RecordOwned) = .empty;
    defer {
        for (rows.items) |r| {
            alloc.free(r.key);
            alloc.free(r.value);
        }
        rows.deinit(alloc);
    }
    try seg.scanRange("", "q", 999, &rows);
    try std.testing.expectEqual(@as(usize, N), rows.items.len);
    for (&keys, 0..) |*k, i| try std.testing.expectEqualStrings(k, rows.items[i].key);
}

test "segment：同一 key 的多个版本跨过索引边界（64 行）时，点查必须拿到最新可见版本" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-dupkey-boundary-tmp";
    dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);
    defer dir.deleteTree(io, tmp) catch {};

    // 同一个 key "k" 的 70 个版本（seq 70..1，按 key asc / seq desc 升序排列），
    // 必然跨过第 64 行那条稀疏索引边界。
    //
    // 会踩到的坑：`candidateIndex` 若返回「最后一个段首 key ≤ target 的块」，
    // 而第 1 块与第 2 块的段首 key **都是 "k"**，就会从第 2 块（较旧版本）开始扫，
    // 直接漏掉第 1 块里 seq 61..70 这些更新的版本 → 返回旧值。
    const nver: u64 = 70;
    {
        var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc, 10, nver);
        defer w.deinit();
        var s: u64 = nver;
        while (s >= 1) : (s -= 1) {
            const buf = try std.fmt.allocPrint(alloc, "v{d}", .{s});
            defer alloc.free(buf);
            try w.push("k", s, 0, buf);
            if (s == 1) break;
        }
        _ = try w.finish(dir, tmp ++ "/000001.idx");
    }

    var seg = try Segment.open(io, dir, tmp ++ "/000001.data", tmp ++ "/000001.idx", alloc, false);
    defer seg.close();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // 快照 = 无限：必须拿到 seq 最大的版本
    try std.testing.expectEqual(@as(u8, 0), (try seg.get("k", 1_000_000, &out)).?);
    try std.testing.expectEqualStrings("v70", out.items);

    // 快照 = 65：必须拿到 seq ≤ 65 里最大的那个（v65）
    _ = try seg.get("k", 65, &out);
    try std.testing.expectEqualStrings("v65", out.items);

    // 快照 = 5：只有 v5 及更旧可见
    _ = try seg.get("k", 5, &out);
    try std.testing.expectEqualStrings("v5", out.items);
}

test "segment write + point get + scan" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-seg-tmp";
    dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);
    defer dir.deleteTree(io, tmp) catch {};

    {
        var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc, 10, 4);
        defer w.deinit();
        try w.push("a", 1, 0, "va");
        try w.push("b", 2, 0, "vb2");
        try w.push("b", 1, 0, "vb1");
        try w.push("c", 1, 0, "vc");
        const meta = try w.finish(dir, tmp ++ "/000001.idx");
        try std.testing.expectEqual(@as(usize, 4), meta.rows);
        try std.testing.expectEqual(@as(u64, 1), meta.min_seq);
        try std.testing.expectEqual(@as(u64, 2), meta.max_seq);
    }

    var seg = try Segment.open(io, dir, tmp ++ "/000001.data", tmp ++ "/000001.idx", alloc, false);
    defer seg.close();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const f2 = try seg.get("b", 2, &out);
    try std.testing.expectEqual(@as(u8, 0), f2.?);
    try std.testing.expectEqualStrings("vb2", out.items);

    _ = try seg.get("b", 1, &out);
    try std.testing.expectEqualStrings("vb1", out.items);

    try std.testing.expect((try seg.get("zz", 2, &out)) == null);

    var rows: std.ArrayList(RecordOwned) = .empty;
    defer {
        for (rows.items) |r| {
            alloc.free(r.key);
            alloc.free(r.value);
        }
        rows.deinit(alloc);
    }
    try seg.scanRange("a", "z", 2, &rows);
    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
    try std.testing.expectEqualStrings("a", rows.items[0].key);
    try std.testing.expectEqualStrings("c", rows.items[3].key);

    var refs: std.ArrayList(Segment.RefRecord) = .empty;
    defer refs.deinit(alloc);
    try seg.scanRefs("a", "z", 2, &refs);
    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
    try std.testing.expectEqualStrings("b", refs.items[1].key);
}

test "Writer.deinit 幂等：finishBytes 成功后再调不得二次释放" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-writer-deinit-idem";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);

    var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc, 10, 1);
    defer w.deinit();
    try w.push("a", 1, 0, "va");
    const f = try w.finishBytes();
    defer alloc.free(f.bytes);

    // `std.ArrayList.deinit` 会把字段置 undefined，所以「幂等」只能靠标志位。
    // 没有标志位时这三行会是 double free / 读 undefined。
    w.deinit();
    w.deinit();
    w.deinit();
}

fn writerAttempt(alloc: std.mem.Allocator) !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-writer-allocfail";
    try dir.createDirPath(io, tmp);
    defer dir.deleteTree(io, tmp) catch {};

    var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc, 10, 3);
    defer w.deinit();
    try w.push("aaaa", 1, 0, "va");
    try w.push("bbbb", 2, 0, "vb");
    try w.push("cccc", 3, 1, "");
    const f = try w.finishBytes();
    defer alloc.free(f.bytes);
}

test "Writer 在任意分配失败点都必须释放缓冲与句柄（不泄漏）" {
    // checkAllAllocationFailures 会逐个分配点注入 OOM：每个失败点都要求
    // ① 返回 error（不 abort/panic）② 无泄漏。没有 `defer w.deinit()` 时这条会挂。
    try std.testing.checkAllAllocationFailures(std.testing.allocator, writerAttempt, .{});
}

test "Bloom 在线累积：位图大小由预估行数定，行数超预估也不产生假阴性" {
    // 在线置位（push 时写位图）省掉了「先收 200 万行 hash 再统一置位」的 16MB 数组，
    // 代价是位图大小必须**提前**确定 → create 要一个 expected_rows。这里守两条：
    //   ① 位图大小 = max(64, expected_rows * bloom_bits)，证明预估真的生效；
    //   ② 实际行数远超预估时**仍无假阴性**（Bloom 只有假阳性没有假阴性）——
    //      位置按 bits_len 取模，写多了只抬高误报率，不会让存在的 key 查不到。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-seg-bloom-tmp";
    dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);
    defer dir.deleteTree(io, tmp) catch {};

    const n: usize = 50;
    {
        // 预估只有 2 行 -> bits_len = 64；实际写 50 行，位图严重偏小
        var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc, 10, 2);
        defer w.deinit();
        try std.testing.expectEqual(@as(usize, 64), w.bits_len);
        var i: usize = 0;
        // `k` **必须声明在循环外**：`Writer` 现在会记住最后一个 key 的**地址**（段头 max_key），
        // 到 `finish` 时才读。声明在循环体内的话，作用域早已结束，`finish` 读到的是
        // 悬垂栈地址（实践中能跑通，但属未定义行为）。
        var k: [8]u8 = undefined;
        while (i < n) : (i += 1) {
            std.mem.writeInt(u64, &k, @as(u64, @intCast(i)), .big);
            try w.push(&k, @intCast(i + 1), 0, "v");
        }
        _ = try w.finish(dir, tmp ++ "/000001.idx");
    }

    var seg = try Segment.open(io, dir, tmp ++ "/000001.data", tmp ++ "/000001.idx", alloc, false);
    defer seg.close();
    // rows 来自段头部（open 时就有）；bits_len 属于主体，必须先 ensureParsed。
    try std.testing.expectEqual(@as(usize, n), seg.rows);
    try seg.ensureParsed();
    try std.testing.expectEqual(@as(u64, 64), seg.bits_len);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var k: [8]u8 = undefined;
        std.mem.writeInt(u64, &k, @as(u64, @intCast(i)), .big);
        if ((try seg.get(&k, @intCast(i + 1), &out)) == null) {
            std.debug.print("假阴性：i={d}\n", .{i});
            return error.BloomFalseNegative;
        }
    }

    // 反向验证：bloom_bits = 0 时不分配位图，bits_len 写 0（读取侧 mayContain 恒 true）
    {
        var w = try Writer.create(io, dir, tmp ++ "/000002.data", alloc, 0, 4);
        defer w.deinit();
        try std.testing.expectEqual(@as(usize, 0), w.bits_len);
        try std.testing.expectEqual(@as(usize, 0), w.bloom.items.len);
        try w.push("a", 1, 0, "va");
        _ = try w.finish(dir, tmp ++ "/000002.idx");
    }
    var seg2 = try Segment.open(io, dir, tmp ++ "/000002.data", tmp ++ "/000002.idx", alloc, false);
    defer seg2.close();
    try seg2.ensureParsed();
    try std.testing.expectEqual(@as(u64, 0), seg2.bits_len);
}

test "mmap 存活时 rename 覆盖同路径：验证 compact 重写归档是否可行" {
    // 冷重开优化（对齐 SQLite 的懒加载）打算把 `seg/index.bin` 改成 mmap，
    // 而 `compact()` 的 `archiveRewrite` 是「写临时文件 + rename 覆盖目标」。
    // 若映射存活时 rename 会被拒（Windows 可能返回 AccessDenied），方案就得改设计。
    // 这个用例就是那个前提的守门人。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const dirname = "test-mmap-rename-tmp";
    cwd.deleteTree(io, dirname) catch {};
    defer cwd.deleteTree(io, dirname) catch {};
    try cwd.createDirPath(io, dirname);

    const p = dirname ++ "/index.bin";
    const tmp = dirname ++ "/index.bin.tmp";
    const original = "ORIGINAL-CONTENT-0123456789";
    const replacement = "NEW";

    {
        const f = try cwd.createFile(io, p, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, original, 0);
    }

    const f_map = try cwd.openFile(io, p, .{});
    var mm = try std.Io.File.MemoryMap.create(io, f_map, .{
        .len = original.len,
        .protection = .{ .read = true, .write = false },
    });
    defer {
        mm.destroy(io);
        f_map.close(io);
    }
    try std.testing.expectEqualStrings(original, mm.memory[0..original.len]);

    {
        const f = try cwd.createFile(io, tmp, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, replacement, 0);
    }

    // 关键动作：映射还活着时 rename 覆盖目标路径
    // 这里**不允许** SkipZigTest：跳过等于没测，而这条正是懒加载方案的前提。
    cwd.rename(tmp, cwd, p, io) catch |e| {
        std.debug.print("\n[结论] mmap 存活时 rename 被拒: {s}\n", .{@errorName(e)});
        return e;
    };

    // 映射仍指向旧文件：内容不变
    try std.testing.expectEqualStrings(original, mm.memory[0..original.len]);
    // 重新 open 则是新内容
    const f3 = try cwd.openFile(io, p, .{});
    defer f3.close(io);
    var rd: [3]u8 = undefined;
    _ = try f3.readPositionalAll(io, &rd, 0);
    try std.testing.expectEqualStrings(replacement, &rd);
}
