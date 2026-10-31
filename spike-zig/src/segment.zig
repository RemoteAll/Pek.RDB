// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const codec = @import("codec.zig");

pub const INDEX_STRIDE: usize = 64;
const FLUSH_BYTES: usize = 1 << 20;
const IDX_MAGIC = "PEKZIX02";

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

fn keyCmp(a: []const u8, b: []const u8) std.math.Order {
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

pub fn readWholeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator, max: u64) ![]u8 {
    const f = try dir.openFile(io, path, .{});
    defer f.close(io);
    // 先 stat 拿长度再一次性读：比「盲读 64KB 再扩容」少一次 read（实测后者慢 ~1ms / 25 段）。
    const size = (try f.stat(io)).size;
    if (size > max) return error.FileTooBig;
    const buf = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    // 注意：这里**不能**手动 free（errdefer 已经会释放），否则是 double free
    if (n != buf.len) return error.UnexpectedEndOfFile;
    return buf;
}

// ---------------- 写入 ----------------

pub const Writer = struct {
    io: std.Io,
    file: std.Io.File,
    alloc: std.mem.Allocator,
    /// Bloom 位数/key（0 = 不生成 Bloom）。默认 10（误报率 ~1%）。
    /// Bloom 占索引体积的 ~80%（200 万行时 2.4MB / 3.1MB），而它只对「不存在的 key」有用，
    /// 所以做成可配：关掉后索引只剩稀疏索引，冷重开与索引 IO 同步变小。
    bloom_bits: u8 = 10,
    buf: std.ArrayList(u8) = .empty,
    buf_base: u64 = 0,
    rows: usize = 0,
    entries: std.ArrayList(IndexEntry) = .empty,
    hashes: std.ArrayList(u64) = .empty,
    min_seq: u64 = std.math.maxInt(u64),
    max_seq: u64 = 0,
    scratch: std.ArrayList(u8) = .empty,

    pub fn create(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator, bloom_bits: u8) !Writer {
        const f = try dir.createFile(io, path, .{ .read = true, .truncate = true });
        return .{ .io = io, .file = f, .alloc = alloc, .bloom_bits = bloom_bits };
    }

    pub fn push(self: *Writer, key: []const u8, seq: u64, flags: u8, value: []const u8) !void {
        if (self.rows % INDEX_STRIDE == 0) {
            try self.entries.append(self.alloc, .{
                .offset = self.buf_base + self.buf.items.len,
                .key = try self.alloc.dupe(u8, key),
            });
        }

        self.scratch.clearRetainingCapacity();
        try codec.putU32le(&self.scratch, self.alloc, @intCast(key.len));
        try codec.putU32le(&self.scratch, self.alloc, @intCast(value.len));
        try codec.putU64le(&self.scratch, self.alloc, seq);
        try self.scratch.append(self.alloc, flags);
        try self.scratch.appendSlice(self.alloc, key);
        try self.scratch.appendSlice(self.alloc, value);
        try self.buf.appendSlice(self.alloc, self.scratch.items);

        if (self.bloom_bits > 0) {
            const hp = hashPair(key);
            try self.hashes.append(self.alloc, hp[0]);
        }

        self.rows += 1;
        self.min_seq = @min(self.min_seq, seq);
        self.max_seq = @max(self.max_seq, seq);

        if (self.buf.items.len >= FLUSH_BYTES) try self.flushBuf();
    }

    fn flushBuf(self: *Writer) !void {
        if (self.buf.items.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buf.items, self.buf_base);
        self.buf_base += self.buf.items.len;
        self.buf.clearRetainingCapacity();
    }

    /// 收尾：落数据 + 返回索引字节（调用方决定写哪：单段 `.idx` 还是聚合 `index.bin`）。
    /// 调用后 Writer 不可再用。
    pub fn finishBytes(self: *Writer) !Finished {
        try self.flushBuf();
        try self.file.sync(self.io);
        self.file.close(self.io);

        var idx: std.ArrayList(u8) = .empty;
        errdefer idx.deinit(self.alloc);
        try idx.appendSlice(self.alloc, IDX_MAGIC);
        try codec.putU64le(&idx, self.alloc, @intCast(self.rows));
        try codec.putU64le(&idx, self.alloc, if (self.rows == 0) 0 else self.min_seq);
        try codec.putU64le(&idx, self.alloc, self.max_seq);
        try codec.putU32le(&idx, self.alloc, @intCast(self.entries.items.len));
        for (self.entries.items) |e| {
            try codec.putU64le(&idx, self.alloc, e.offset);
            try codec.putU32le(&idx, self.alloc, @intCast(e.key.len));
            try idx.appendSlice(self.alloc, e.key);
        }

        // Bloom：默认 10 bit/key、k=7；bloom_bits=0 时 bits_len=0，读取侧 mayContain 直接返回 true
        const bits_len: usize = if (self.bloom_bits == 0) 0 else @max(@as(usize, 64), self.rows * @as(usize, self.bloom_bits));
        try codec.putU64le(&idx, self.alloc, bits_len);
        try idx.append(self.alloc, 7);
        if (bits_len > 0) {
            const bytes_len = (bits_len + 7) / 8;
            const bits = try self.alloc.alloc(u8, bytes_len);
            defer self.alloc.free(bits);
            @memset(bits, 0);
            for (self.hashes.items) |h1| {
                const h2 = (h1 *% 0x9E3779B97F4A7C15) | 1;
                var i: usize = 0;
                while (i < 7) : (i += 1) {
                    const step: u64 = @as(u64, @intCast(i)) *% h2;
                    const pos: usize = @intCast((h1 +% step) % @as(u64, bits_len));
                    bits[pos / 8] |= @as(u8, 1) << @intCast(pos % 8);
                }
            }
            try idx.appendSlice(self.alloc, bits);
        }
        try codec.putU64le(&idx, self.alloc, codec.hashIdx(idx.items));

        const meta = Meta{
            .rows = self.rows,
            .min_seq = if (self.rows == 0) 0 else self.min_seq,
            .max_seq = self.max_seq,
        };

        for (self.entries.items) |e| self.alloc.free(e.key);
        self.entries.deinit(self.alloc);
        self.hashes.deinit(self.alloc);
        self.buf.deinit(self.alloc);
        self.scratch.deinit(self.alloc);

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
pub const ARCHIVE_MAGIC = "PEKZAG03";

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
pub fn archiveRewrite(io: std.Io, dir: std.Io.Dir, path: []const u8, records: []const ArchiveRecord) !u64 {
    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp", .{path});
    defer std.heap.page_allocator.free(tmp_path);

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
    if (at < 8) {
        try f.writePositionalAll(io, ARCHIVE_MAGIC, 0);
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
    bits_off: u32 = 0,
    bits_len: u64 = 0,
    rows: usize = 0,
    min_seq: u64 = 0,
    max_seq: u64 = 0,
    file_size: u64 = 0,

    pub fn entryKey(self: *const Segment, i: usize) []const u8 {
        const e = self.entries.items[i];
        return self.idx[e.key_off..][0..e.key_len];
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
        try seg.parseIdxBytes(idx_bytes);
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
        try seg.parseIdxBytes(payload);
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
    fn parseIdxBytes(self: *Segment, idx_bytes: []const u8) !void {
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

        var r = codec.Reader{ .buf = idx_bytes[8..] };
        self.rows = @intCast(try r.u64le());
        self.min_seq = try r.u64le();
        self.max_seq = try r.u64le();
        const n: usize = @intCast(try r.u32le());
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
        if (self.owns_idx and self.idx.len > 0) self.alloc.free(@constCast(self.idx));
        if (self.mm) |*m| m.destroy(self.io);
        if (self.file) |f| f.close(self.io);
        self.* = undefined;
    }

    fn mayContain(self: *const Segment, key: []const u8) bool {
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
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (keyCmp(self.entryKey(mid), key) == .gt) {
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
        if (!self.mayContain(key)) return null;
        if (self.entries.items.len == 0) return null;

        const i = self.candidateIndex(key);
        const begin = self.entries.items[i].offset;
        const view = try self.dataView();
        const end: u64 = if (i + 1 < self.entries.items.len) self.entries.items[i + 1].offset else view.len;
        if (end <= begin) return null;

        const data = view[@intCast(begin)..@intCast(end)];

        var pos: usize = 0;
        while (pos + 17 <= data.len) {
            const klen = std.mem.readInt(u32, data[pos..][0..4], .little);
            const vlen = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
            const seq = std.mem.readInt(u64, data[pos + 8 ..][0..8], .little);
            const flags = data[pos + 16];
            const total = 17 + @as(usize, klen) + @as(usize, vlen);
            if (pos + total > data.len) break;
            const k = data[pos + 17 ..][0..@as(usize, klen)];
            const v = data[pos + 17 + @as(usize, klen) ..][0..@as(usize, vlen)];
            pos += total;

            switch (keyCmp(k, key)) {
                .lt => continue,
                .gt => return null,
                .eq => {
                    if (seq <= snapshot) {
                        out.clearRetainingCapacity();
                        try out.appendSlice(self.alloc, v);
                        return flags;
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

    /// 零拷贝扫描：输出借用 mmap 的切片（调用方保证段存活）。
    /// 同一 key 只输出一个可见版本（墓碑跳过）。
    pub fn scanRefs(self: *Segment, start: []const u8, end: []const u8, snapshot: u64, out: *std.ArrayList(RefRecord)) !void {
        if (self.entries.items.len == 0) return;
        const data = try self.dataView();
        var pos: usize = @intCast(self.entries.items[self.candidateIndex(start)].offset);
        var cur_key: []const u8 = &.{};
        var have_cur = false;
        var decided = false;

        while (pos + 17 <= data.len) {
            const klen: usize = @intCast(std.mem.readInt(u32, data[pos..][0..4], .little));
            const vlen: usize = @intCast(std.mem.readInt(u32, data[pos + 4 ..][0..4], .little));
            const seq = std.mem.readInt(u64, data[pos + 8 ..][0..8], .little);
            const flags = data[pos + 16];
            const total = 17 + klen + vlen;
            if (pos + total > data.len) break;
            const k = data[pos + 17 ..][0..klen];
            const v = data[pos + 17 + klen ..][0..vlen];
            pos += total;

            switch (keyCmp(k, end)) {
                .gt, .eq => return,
                .lt => {},
            }
            if (keyCmp(k, start) == .lt) continue;
            if (!have_cur or !std.mem.eql(u8, k, cur_key)) {
                cur_key = k;
                have_cur = true;
                decided = false;
            }
            if (decided) continue;
            if (seq <= snapshot) {
                decided = true;
                if (flags == 0) try out.append(self.alloc, .{ .key = k, .seq = seq, .flags = flags, .value = v });
            }
        }
    }

    /// 流式游标：按 (key asc, seq desc) 逐条产出可见记录（不去重）。
    pub fn cursor(self: *Segment, start: []const u8, end: []const u8, snapshot: u64) !RefCursor {
        const view = try self.dataView();
        var pos: usize = view.len;
        if (self.entries.items.len > 0) {
            pos = @intCast(self.entries.items[self.candidateIndex(start)].offset);
        }
        return .{ .seg = self, .pos = pos, .start = start, .end = end, .snapshot = snapshot };
    }

    /// 范围扫描（start 含、end 排他），只输出 seq <= snapshot 的记录（含墓碑）。
    pub fn scanRange(
        self: *Segment,
        start: []const u8,
        end: []const u8,
        snapshot: u64,
        out: *std.ArrayList(RecordOwned),
    ) !void {
        if (self.entries.items.len == 0) return;
        const i = self.candidateIndex(start);
        const begin: usize = @intCast(self.entries.items[i].offset);
        var pos: usize = begin;
        const data = try self.dataView();

        while (pos + 17 <= data.len) {
            const klen: usize = @intCast(std.mem.readInt(u32, data[pos..][0..4], .little));
            const vlen: usize = @intCast(std.mem.readInt(u32, data[pos + 4 ..][0..4], .little));
            const seq = std.mem.readInt(u64, data[pos + 8 ..][0..8], .little);
            const flags = data[pos + 16];
            const total = 17 + klen + vlen;
            if (pos + total > data.len) break;
            const k = data[pos + 17 ..][0..klen];
            const v = data[pos + 17 + klen ..][0..vlen];
            pos += total;

            switch (keyCmp(k, end)) {
                .gt, .eq => return,
                .lt => {},
            }
            if (keyCmp(k, start) == .lt) continue;
            if (seq > snapshot) continue;
            try out.append(self.alloc, .{
                .key = try self.alloc.dupe(u8, k),
                .seq = seq,
                .flags = flags,
                .value = try self.alloc.dupe(u8, v),
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

    pub fn next(self: *RefCursor) ?Segment.RefRecord {
        const data = self.seg.data;
        while (self.pos + 17 <= data.len) {
            const klen: usize = @intCast(std.mem.readInt(u32, data[self.pos..][0..4], .little));
            const vlen: usize = @intCast(std.mem.readInt(u32, data[self.pos + 4 ..][0..4], .little));
            const seq = std.mem.readInt(u64, data[self.pos + 8 ..][0..8], .little);
            const flags = data[self.pos + 16];
            const total = 17 + klen + vlen;
            if (self.pos + total > data.len) return null;
            const k = data[self.pos + 17 ..][0..klen];
            const v = data[self.pos + 17 + klen ..][0..vlen];
            self.pos += total;

            // 空 end = 无上界（compaction 全量归并时用）
            if (self.end.len > 0) {
                switch (keyCmp(k, self.end)) {
                    .gt, .eq => return null,
                    .lt => {},
                }
            }
            if (keyCmp(k, self.start) == .lt) continue;
            if (seq > self.snapshot) continue;
            return .{ .key = k, .seq = seq, .flags = flags, .value = v };
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
        var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc, 10);
        try w.push("a", 1, 0, "va");
        try w.push("b", 2, 0, "vb");
        _ = try w.finish(dir, tmp ++ "/000001.idx");
    }

    // 改中间一个字节（既不破坏 magic，也与尾部哈希不符）
    {
        const bytes = try readWholeFile(io, dir, tmp ++ "/000001.idx", alloc, 1 << 20);
        defer alloc.free(bytes);
        bytes[bytes.len / 2] ^= 0xFF;
        var f = try dir.createFile(io, tmp ++ "/000001.idx", .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, bytes, 0);
    }

    try std.testing.expectError(error.BadIndexChecksum, Segment.open(io, dir, tmp ++ "/000001.data", tmp ++ "/000001.idx", alloc, false));
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
        var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc, 10);
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
