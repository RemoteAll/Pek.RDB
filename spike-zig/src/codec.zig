// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");

// ---------- CRC32（IEEE，表驱动，comptime 生成） ----------
const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if ((c & 1) != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
        }
        t[i] = c;
    }
    break :blk t;
};

/// 查表占用的常量区字节数（供 size 报告使用；C 档可换 16 项半字节表降到 64B）。
pub const CRC_TABLE_BYTES: usize = @sizeOf(@TypeOf(crc_table));

/// 16 项半字节表（64B）：比全表慢约 2×，但常量区从 1KB 降到 64B。
const crc_nibble_table: [16]u32 = blk: {
    var t: [16]u32 = undefined;
    for (0..16) |i| {
        var c: u32 = @intCast(i);
        for (0..4) |_| {
            c = if ((c & 1) != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
        }
        t[i] = c;
    }
    break :blk t;
};

pub const CRC_NIBBLE_TABLE_BYTES: usize = @sizeOf(@TypeOf(crc_nibble_table));

/// 半字节表 CRC32（常量区 64B）。
pub fn crc32Nibble(bytes: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (bytes) |b| {
        c ^= b;
        c = (c >> 4) ^ crc_nibble_table[@as(u4, @truncate(c))];
        c = (c >> 4) ^ crc_nibble_table[@as(u4, @truncate(c))];
    }
    return ~c;
}

/// 无表 CRC32（零常量区，约比全表慢 6~8×）。flash 极小时用。
pub fn crc32Bitwise(bytes: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (bytes) |b| {
        c ^= b;
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            c = if ((c & 1) != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
        }
    }
    return ~c;
}

pub fn crc32(bytes: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (bytes) |b| {
        c = (c >> 8) ^ crc_table[@as(u8, @truncate(c)) ^ b];
    }
    return ~c;
}

/// 索引/归档完整性校验：64 位 XxHash（约 10GB/s，实测 3MB 从 1.67ms 降到 0.2ms）。
/// 只用于**派生数据**（段索引可从 .data 重建），目的是发现截断/位翻转；
/// 64 位哈希对随机误码的抗碰撞能力高于 32 位 CRC，所以校验强度是提升而非降低。
/// WAL（写入热路径、崩溃恢复语义）仍用 `crc32`，不在此列。
pub fn hashIdx(bytes: []const u8) u64 {
    return std.hash.XxHash64.hash(0, bytes);
}

// ---------- CRC32 快速版（slicing-by-8，8KB 表） ----------
// 只给主引擎的大块校验用（段索引、WAL 批次）：值域与 `crc32` 完全一致、可互验，
// 但常量区 8KB。**M0 档不得用**（flash 预算只有 2KB），那里走 `crc32`/`crc32Nibble`/`crc32Bitwise`。
const crc_tables8: [8][256]u32 = blk: {
    @setEvalBranchQuota(400000);
    var t: [8][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if ((c & 1) != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
        }
        t[0][i] = c;
    }
    for (1..8) |k| {
        for (0..256) |i| {
            const p = t[k - 1][i];
            t[k][i] = (p >> 8) ^ t[0][@as(u8, @truncate(p))];
        }
    }
    break :blk t;
};

pub const CRC_FAST_TABLE_BYTES: usize = @sizeOf(@TypeOf(crc_tables8));

/// slicing-by-8 CRC32（实测 3MB 从 6.5ms 降到 ~1ms 量级）。
pub fn crc32Fast(bytes: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    var i: usize = 0;
    const n8 = bytes.len & ~@as(usize, 7);
    while (i < n8) : (i += 8) {
        const lo = std.mem.readInt(u32, bytes[i..][0..4], .little) ^ c;
        const hi = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        c = crc_tables8[7][@as(u8, @truncate(lo))] ^
            crc_tables8[6][@as(u8, @truncate(lo >> 8))] ^
            crc_tables8[5][@as(u8, @truncate(lo >> 16))] ^
            crc_tables8[4][@as(u8, @truncate(lo >> 24))] ^
            crc_tables8[3][@as(u8, @truncate(hi))] ^
            crc_tables8[2][@as(u8, @truncate(hi >> 8))] ^
            crc_tables8[1][@as(u8, @truncate(hi >> 16))] ^
            crc_tables8[0][@as(u8, @truncate(hi >> 24))];
    }
    while (i < bytes.len) : (i += 1) {
        c = (c >> 8) ^ crc_tables8[0][@as(u8, @truncate(c)) ^ bytes[i]];
    }
    return ~c;
}

// ---------- 小工具 ----------
pub fn putU32le(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(alloc, &b);
}

pub fn putU64le(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try out.appendSlice(alloc, &b);
}

pub fn putVarint(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: u64) !void {
    var b: [10]u8 = undefined;
    try out.appendSlice(alloc, b[0..encodeVarint(&b, value)]);
}

/// 把 `value` 编成 LEB128 写进 `dst`（**不检查容量**，调用方保证 dst 至少 10 字节），
/// 返回写了几个字节。
///
/// 为什么单独拿一个这个：`putVarint` 走 `ArrayList.append` 是**逐字节**的，
/// 每字节都要一次容量检查；行头一次要写 3 个 varint，那就是 4–6 次检查。
/// 先栈上拼好再一次 `appendSlice` 只付一次。
pub fn encodeVarint(dst: []u8, value: u64) usize {
    var v = value;
    var n: usize = 0;
    while (v >= 0x80) {
        dst[n] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
        n += 1;
    }
    dst[n] = @truncate(v);
    return n + 1;
}

/// 顺序保持的 i64 键编码：翻转符号位后大端。
pub fn encodeI64Key(buf: *[8]u8, v: i64) void {
    const u: u64 = @as(u64, @bitCast(v)) ^ 0x8000_0000_0000_0000;
    std.mem.writeInt(u64, buf, u, .big);
}

// ---------- 读游标 ----------
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    pub fn u8v(self: *Reader) !u8 {
        if (self.pos >= self.buf.len) return error.Truncated;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn u32le(self: *Reader) !u32 {
        if (self.remaining() < 4) return error.Truncated;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn u64le(self: *Reader) !u64 {
        if (self.remaining() < 8) return error.Truncated;
        const v = std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    pub fn varint(self: *Reader) !u64 {
        var shift: u6 = 0;
        var v: u64 = 0;
        while (true) {
            const b = try self.u8v();
            v |= (@as(u64, b & 0x7F) << shift);
            if ((b & 0x80) == 0) return v;
            if (shift >= 63) return error.Overflow;
            shift += 7;
        }
    }

    pub fn bytes(self: *Reader, n: usize) ![]const u8 {
        if (self.remaining() < n) return error.Truncated;
        const s = self.buf[self.pos..][0..n];
        self.pos += n;
        return s;
    }
};

// ---------- 数据文件里的「一条记录」 ----------

/// 一条记录的视图。**不拷贝**：`key` / `value` 直接借用 `buf`
/// （`key` 在「块内前缀压缩」的块里是 **suffix**，见 `RecIter`）。
pub const RecView = struct {
    key: []const u8,
    value: []const u8,
    seq: u64,
    flags: u8,
    /// 完整 key 长度（`key.len` 是**实际存储**的字节数 = `klen - pfx`）
    klen: usize,
    /// 下一条记录的起始偏移
    next: usize,
};

/// 行头字段的哨兵值：等于它就表示「真实值放不下，后面紧跟一个 varint」。
/// 选 255 / 255 / 0xFFFFFFFF 是因为它们恰好是各自定长字段能表示的最大值，
/// 用「最大值当逃逸」不浪费任何可表示空间。
const KLEN_ESC: u8 = 0xFF;
const VLEN_ESC: u8 = 0xFF;
const SEQ_ESC: u32 = 0xFFFF_FFFF;
/// `seq` 字段能原地容纳的上界（2³¹−1）：**最高位借给墓碑标志**（`PEKZAG07`）。
/// 全项目只用到 `flags` 的 bit0（0 = 正常、1 = 墓碑），所以把它挂到 seq 的高位，
/// 行头就从 7 字节降到 6 字节（2M 行省 2MB）。超过上界或 flags 带其它位时走逃逸。
const SEQ_MAX_INLINE: u64 = 0x7FFF_FFFF;
/// 行头定长部分：`u8 klen, u8 vlen, u32 (seq<<1 位|墓碑)`
const REC_HDR: usize = 6;

/// LEB128 解码的**快路径版**（只给行头的哨兵逃逸用）：
/// 一字节能表示的值直接 return，不建 `Reader`、不走 error union。
inline fn rdVarint(buf: []const u8, p: *usize) ?u64 {
    const i = p.*;
    if (i >= buf.len) return null;
    const b0 = buf[i];
    if (b0 < 0x80) {
        p.* = i + 1;
        return b0;
    }
    var v: u64 = b0 & 0x7F;
    var shift: u6 = 7;
    var j = i + 1;
    while (true) {
        if (j >= buf.len) return null;
        const b = buf[j];
        j += 1;
        v |= @as(u64, b & 0x7F) << shift;
        if (b < 0x80) {
            p.* = j;
            return v;
        }
        if (shift >= 63) return null;
        shift += 7;
    }
}

/// 解一条记录；**越界 / 截断一律返回 null**（各调用点都把它当「这段读完了」）。
///
/// 行格式（`PEKZAG07` 起）：
/// ```
/// u8 klen | u8 vlen | u32 (seq|墓碑位) | [klen 逃逸 varint] [vlen 逃逸] [seq 逃逸 varint + u8 flags] | key[klen-pfx] | value
/// ```
///
/// `pfx` = 本块的公共前缀长度（块头里那个字节，见 `RecIter`）。`pfx == 0` 时记录的
/// key 就是完整 key，**行为与 `PEKZAG05` 完全一致**。
///
/// **为什么是「定长 7 字节 + 哨兵逃逸」而不是纯 varint**：
/// 旧头是 `klen4 + vlen4 + seq8 + flags1 = 17 B`，每行白扔 10 B ——
/// 换算成磁盘就是「比 SQLite 多占 41%」里的大头（§16.1.25）。
/// 第一版改成纯 varint 确实把磁盘降到 47 B/行，但解码要跑 3 个 varint 循环
/// （seq 就占 3 字节）→ 整条扫描流水线实测退化 ~10%（`big_count` 42.9M → 38.3M 行/s，
/// 区间不重叠）。定长 7 字节同时拿到两边：比旧版少 10 B/行，
/// 解码仍是 **1 次边界检查 + 4 次定长读**，与旧版同速。
/// 哨兵逃逸只在 key>254B / value>254B / seq>4G 时才走，那个分支几乎永不命中。
///
/// 这 4 个调用点（`Segment.get` / `scanRefs` / `scanRange` / `RefCursor.next`）
/// 原来各抄了一份**完全相同的**解析循环；格式一改就得改 4 遍，漏一处就是数据损坏。
/// 收编到这里之后，行格式只在 `readRec` / `writeRecHdr` 这一对里定义。
///
/// `inline`：不标的话热循环里会变成一次真实函数调用 + 结构体返回。
/// 配对微基准（`recdec_*`）实测这层开销比解码本身还大。
pub inline fn readRec(buf: []const u8, pos: usize, pfx: usize) ?RecView {
    if (pos + REC_HDR > buf.len) return null;
    const kraw = buf[pos];
    const vraw = buf[pos + 1];
    const sraw = std.mem.readInt(u32, buf[pos + 2 ..][0..4], .little);
    var p = pos + REC_HDR;

    var klen: usize = kraw;
    if (kraw == KLEN_ESC) klen = @intCast(rdVarint(buf, &p) orelse return null);
    var vlen: usize = vraw;
    if (vraw == VLEN_ESC) vlen = @intCast(rdVarint(buf, &p) orelse return null);
    var seq: u64 = sraw & 0x7FFF_FFFF;
    var flags: u8 = @intCast(sraw >> 31);
    if (sraw == SEQ_ESC) {
        seq = rdVarint(buf, &p) orelse return null;
        if (p >= buf.len) return null;
        flags = buf[p];
        p += 1;
    }

    // 长度都是不可信输入：**先比剩余、再加**，避开 `p + klen` 溢出绕过判定。
    // 写成「先算剩余再减」而不是「先加再比」，编译器才能证明下面两个切片不越界，
    // 从而不插运行时边界检查（这正是配对微基准里那 20% 的来源）。
    if (pfx > klen) return null;
    const stored = klen - pfx;
    const rest = buf.len - p;
    if (stored > rest) return null;
    const after_k = rest - stored;
    if (vlen > after_k) return null;
    const k = buf[p..][0..stored];
    const v = buf[p + stored ..][0..vlen];
    return .{ .key = k, .value = v, .seq = seq, .flags = flags, .klen = klen, .next = p + stored + vlen };
}

/// 写行头到 `dst`（调用方保证至少 `6 + 33` 字节），返回写了几个字节。
/// **必须与 `readRec` 同改。**
pub fn writeRecHdr(dst: []u8, klen: usize, vlen: usize, seq: u64, flags: u8) usize {
    const k_esc = klen >= @as(usize, KLEN_ESC);
    const v_esc = vlen >= @as(usize, VLEN_ESC);
    // flags 只用到 bit0（墓碑），它被挂到 seq 字段最高位；其它位不能丢，走逃逸
    const s_esc = seq >= SEQ_MAX_INLINE or (flags & ~@as(u8, 1)) != 0;
    dst[0] = if (k_esc) KLEN_ESC else @intCast(klen);
    dst[1] = if (v_esc) VLEN_ESC else @intCast(vlen);
    if (s_esc) {
        std.mem.writeInt(u32, dst[2..6], SEQ_ESC, .little);
    } else {
        const sf: u32 = @as(u32, @intCast(seq)) | (@as(u32, flags & 1) << 31);
        std.mem.writeInt(u32, dst[2..6], sf, .little);
    }
    var n: usize = 6;
    if (k_esc) n += encodeVarint(dst[n..], klen);
    if (v_esc) n += encodeVarint(dst[n..], vlen);
    if (s_esc) {
        n += encodeVarint(dst[n..], seq);
        dst[n] = flags;
        n += 1;
    }
    return n;
}

// ---------- 分块 key arena ----------

/// 只增分块的字节 arena：用来把「重建出来的临时 key」落成**长期有效**的切片。
///
/// 为什么不用 `ArrayList(u8)`：它扩容会搬到新地址，先前发出的切片全部悬空。
/// 常见的绕法是「先收集偏移、最后统一回填」，但那是**第二遍遍历输出数组**
/// （200 万行 × 48B = 96MB 再写一遍），实测把 `scan_refs` 从 12.2M 行/s 打到 9.8M。
/// 分块就解决了：块一旦分配就不再移动，单个 key 天然稳定，一遍过。
///
/// 分块跨调用复用（`reset` 只回到第 0 块），所以反复扫描不会反复分配。
pub const KeyArena = struct {
    chunks: std.ArrayList([]u8) = .empty,
    idx: usize = 0,
    used: usize = 0,
    chunk_size: usize = 1 << 20,
    /// `reset` 时最多保留多少字节的分块。超出部分**释放**，下次扫描按需重新分配。
    ///
    /// 不设上限的话，跑过一次全表 `scanRefs`（200 万行 × 8B ≈ 16MB）之后，
    /// 那些分块会一直挂在 `Table` 上 —— 对「偶尔一次大扫描」的进程就是纯浪费。
    /// 保留 4MB 是为了让常规的小范围扫描（几万行）完全免分配。
    retain_bytes: usize = 4 << 20,

    pub fn deinit(self: *KeyArena, a: std.mem.Allocator) void {
        for (self.chunks.items) |c| a.free(c);
        self.chunks.deinit(a);
    }

    /// 回到起点：保留前 `retain_bytes` 字节的分块供复用，其余释放。
    pub fn reset(self: *KeyArena, a: std.mem.Allocator) void {
        var keep: usize = 0;
        var total: usize = 0;
        while (total < self.retain_bytes and keep < self.chunks.items.len) : (keep += 1) {
            total += self.chunks.items[keep].len;
        }
        while (self.chunks.items.len > keep) {
            const c = self.chunks.pop().?;
            a.free(c);
        }
        self.idx = 0;
        self.used = 0;
    }

    fn pushChunk(self: *KeyArena, a: std.mem.Allocator, need: usize) !void {
        const c = try a.alloc(u8, @max(self.chunk_size, need));
        errdefer a.free(c);
        try self.chunks.append(a, c);
    }

    /// 分配 `n` 字节；返回的切片在本 arena 存活期内**永不移动**。
    pub fn alloc(self: *KeyArena, a: std.mem.Allocator, n: usize) ![]u8 {
        if (self.chunks.items.len == 0) try self.pushChunk(a, n);
        var c = self.chunks.items[self.idx];
        if (self.used + n > c.len) {
            self.idx += 1;
            self.used = 0;
            if (self.idx >= self.chunks.items.len) try self.pushChunk(a, n);
            c = self.chunks.items[self.idx];
        }
        const s = c[self.used..][0..n];
        self.used += n;
        return s;
    }
};

// ---------- 块内公共前缀：段内行迭代器 ----------

/// 段内行迭代器，负责「块内公共前缀」的重建。
///
/// **块布局**：`u8 pfx_len` 后面跟最多 `stride` 条记录。
/// - 块内**第 1 条记录存完整 key**（它同时充当本块后续记录的前缀来源，所以块本身
///   是自描述、可独立迭代的；不依赖稀疏索引，也就不必在建游标时额外传进来）。
/// - 第 2 条起只存 `key[pfx_len..]`，完整 key = 首条 key 的前 `pfx_len` 字节 + suffix。
/// - `pfx_len == 0`（随机 key，块内无公共前缀）时**每条记录都存完整 key**，
///   迭代直接借用 `buf` 切片 —— **零拷贝**，随机 key 场景完全不退化。
///
/// **为什么用双缓冲**：重建出来的 key 不能指向 mmap（不连续），必须落到内部缓冲。
/// 但排序归并会跨行持有「上一行的 key」；单缓冲会被下一次 `next()` 覆盖。
/// 双缓冲交替使用，保证「上一行」在下一条产出后仍然有效。
///
/// **契约**：返回的 `key` 在**再下一次** `next()` 之前有效。需要跨更多行保留的调用方
/// （例如「收集全部记录」）必须自己拷走。
pub const RecIter = struct {
    buf: []const u8,
    pos: usize = 0,
    stride: usize = 64,
    /// 当前块剩余行数；0 表示下一条要先读块头
    blk_left: usize = 0,
    /// 当前块的公共前缀长度
    pfx: usize = 0,
    /// 本块首 key（指向 `buf`，稳定）
    base: []const u8 = &.{},
    kbuf: [2]std.ArrayList(u8) = .{ .empty, .empty },
    cur: usize = 1,
    /// 设了就表示「重建出来的 key 要落成长期稳定切片」：不开双缓冲，直接向 arena 要内存。
    /// 给「先收集、后使用」的 API（`Table.scanRefs`）用，省掉一次额外 memcpy。
    sink: ?*KeyArena = null,

    /// `max_key`：本段内 key 长度上界（段头里有，用来一次性预留重建缓冲，避免热路径分配）
    pub fn init(alloc: std.mem.Allocator, buf: []const u8, stride: usize, max_key: usize) !RecIter {
        var it = RecIter{ .buf = buf, .stride = stride };
        errdefer it.deinit(alloc);
        const cap = if (max_key == 0) 1 else max_key;
        try it.kbuf[0].ensureTotalCapacity(alloc, cap);
        try it.kbuf[1].ensureTotalCapacity(alloc, cap);
        return it;
    }

    pub fn deinit(self: *RecIter, alloc: std.mem.Allocator) void {
        self.kbuf[0].deinit(alloc);
        self.kbuf[1].deinit(alloc);
    }

    /// 定位到某个**块头**（稀疏索引项的 offset 就指向块头）。
    pub fn seek(self: *RecIter, pos: usize) void {
        self.pos = pos;
        self.blk_left = 0;
    }

    /// 解下一条。**`key` 指向内部双缓冲（pfx>0 时），再下一次 `next()` 前有效。**
    pub fn next(self: *RecIter, alloc: std.mem.Allocator) ?RecView {
        if (self.pos >= self.buf.len) return null;
        if (self.blk_left == 0) {
            self.pfx = self.buf[self.pos];
            self.pos += 1;
            self.blk_left = self.stride;
            // 块首记录存的是完整 key（pfx 不适用于它），顺带成为本块的前缀来源
            const h0 = readRec(self.buf, self.pos, 0) orelse return null;
            self.pos = h0.next;
            self.blk_left -= 1;
            self.base = h0.key;
            return h0;
        }
        const h = readRec(self.buf, self.pos, self.pfx) orelse return null;
        self.pos = h.next;
        self.blk_left -= 1;
        if (self.pfx == 0) return h; // 零拷贝
        if (self.pfx > self.base.len or h.klen > self.kbuf[0].capacity) return null; // 文件损坏
        if (self.sink) |arena| {
            const k = arena.alloc(alloc, h.klen) catch return null;
            @memcpy(k[0..self.pfx], self.base[0..self.pfx]);
            @memcpy(k[self.pfx..], h.key);
            return .{ .key = k, .value = h.value, .seq = h.seq, .flags = h.flags, .klen = h.klen, .next = h.next };
        }
        self.cur ^= 1;
        const kb = &self.kbuf[self.cur];
        kb.resize(alloc, h.klen) catch return null;
        @memcpy(kb.items[0..self.pfx], self.base[0..self.pfx]);
        @memcpy(kb.items[self.pfx..], h.key);
        return .{ .key = kb.items, .value = h.value, .seq = h.seq, .flags = h.flags, .klen = h.klen, .next = h.next };
    }
};


test "readRec: 定长 6B 头 + 哨兵逃逸 往返 + 边界（空值 / 长 key / 大 seq）" {
    const K254: [254]u8 = @splat('x');
    const K255: [255]u8 = @splat('y');
    const K300: [300]u8 = @splat('z');
    const V254: [254]u8 = @splat('p');
    const V255: [255]u8 = @splat('q');
    const V200: [200]u8 = @splat('w');

    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    const cases = [_]struct { key: []const u8, value: []const u8, seq: u64, flags: u8 }{
        .{ .key = "", .value = "", .seq = 0, .flags = 0 },
        .{ .key = "a", .value = "v", .seq = 1, .flags = 0 },
        // 墓碑：value 为空
        .{ .key = "k1", .value = "", .seq = 2, .flags = 1 },
        // klen 逃逸边界：254 还在定长里，255 必须走逃逸
        .{ .key = &K254, .value = "v", .seq = 3, .flags = 0 },
        .{ .key = &K255, .value = "v", .seq = 4, .flags = 0 },
        .{ .key = &K300, .value = &V200, .seq = 5, .flags = 0 },
        // vlen 逃逸边界
        .{ .key = "k2", .value = &V254, .seq = 6, .flags = 0 },
        .{ .key = "k3", .value = &V255, .seq = 7, .flags = 0 },
        // seq 逃逸边界（上界是 2³¹−1：最高位借给墓碑标志）
        .{ .key = "k4", .value = "v", .seq = SEQ_MAX_INLINE - 1, .flags = 0 },
        .{ .key = "k4b", .value = "v", .seq = SEQ_MAX_INLINE, .flags = 1 },
        .{ .key = "k5", .value = "v", .seq = SEQ_MAX_INLINE + 1, .flags = 0 },
        .{ .key = "k6", .value = "v", .seq = std.math.maxInt(u64), .flags = 0 },
        // 三个逃逸同时命中
        .{ .key = &K300, .value = &V255, .seq = std.math.maxInt(u64), .flags = 1 },
        // flags 带 bit0 以外的位：不能丢，必须走逃逸
        .{ .key = "k7", .value = "v", .seq = 8, .flags = 0x81 },
    };

    var expect_off: [cases.len]usize = undefined;
    for (cases, 0..) |c, i| {
        expect_off[i] = buf.items.len;
        var hdr: [6 + 33]u8 = undefined;
        const hn = writeRecHdr(&hdr, c.key.len, c.value.len, c.seq, c.flags);
        try buf.appendSlice(alloc, hdr[0..hn]);
        try buf.appendSlice(alloc, c.key);
        try buf.appendSlice(alloc, c.value);
    }

    for (cases, 0..) |c, i| {
        const rec = readRec(buf.items, expect_off[i], 0) orelse return error.RecMissing;
        try std.testing.expectEqualStrings(c.key, rec.key);
        try std.testing.expectEqualStrings(c.value, rec.value);
        try std.testing.expectEqual(c.seq, rec.seq);
        try std.testing.expectEqual(c.flags, rec.flags);
        if (i + 1 < cases.len) {
            try std.testing.expectEqual(expect_off[i + 1], rec.next);
        } else {
            try std.testing.expectEqual(buf.items.len, rec.next);
        }
    }

    // 定长头确实只有 6 字节：小字段（8B key / 32B value / 小 seq）时整行 = 6+8+32
    {
        var hdr: [6 + 33]u8 = undefined;
        const hn = writeRecHdr(&hdr, 8, 32, 1_234_567, 0);
        try std.testing.expectEqual(@as(usize, 6), hn);
        // 墓碑位不额外占字节
        try std.testing.expectEqual(@as(usize, 6), writeRecHdr(&hdr, 8, 0, 1_234_567, 1));
    }
    // 边界前后必须严格分开：254 不逃逸、255 逃逸（逃逸版多 2 字节：255 + 1B varint）
    {
        var hdr: [6 + 33]u8 = undefined;
        const a = writeRecHdr(&hdr, 254, 254, SEQ_MAX_INLINE - 1, 0);
        const b = writeRecHdr(&hdr, 255, 255, SEQ_MAX_INLINE + 1, 0);
        try std.testing.expectEqual(@as(usize, 6), a);
        // seq 逃逸 = varint(2³¹) 5 字节 + 1 字节 flags
        try std.testing.expectEqual(@as(usize, 6 + 2 + 2 + 5 + 1), b);
    }

    // 截断必须返回 null，不能 panic、也不能读越界
    try std.testing.expect(readRec(buf.items, buf.items.len, 0) == null);
    try std.testing.expect(readRec(buf.items, buf.items.len + 100, 0) == null);
    var cut: usize = 0;
    while (cut < buf.items.len) : (cut += 3) {
        _ = readRec(buf.items[0..cut], 0, 0); // 只要不 panic / 不越界
        _ = readRec(buf.items, cut, 0);
        // pfx 不可大于 klen：文件损坏时必须报 null，不能把 suffix 读越界
        _ = readRec(buf.items[0..cut], 0, 4096);
    }
}

test "RecIter: 块内公共前缀往返（pfx=0 / pfx>0 / 残块 / 空 key）" {
    const alloc = std.testing.allocator;
    const stride: usize = 4;

    // 造三块数据：① pf=3 满块 ② pf=0 满块（key 无公共前缀）③ 2 条残块，含空 key
    const keys = [_][]const u8{
        "abc000", "abc001", "abc002", "abc003", // 块 1：pfx=3
        "abc004", "xyz005", "qqq006", "zzz007", // 块 2：pfx=0
        "",      "zzz999", // 块 3：pfx=0（空 key 的公共前缀是 0）
    };

    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(alloc);

    var block_starts: [3]usize = undefined;
    var nblk: usize = 0;
    var i: usize = 0;
    while (i < keys.len) {
        const n = @min(stride, keys.len - i);
        var pfx = keys[i].len;
        var j: usize = 1;
        while (j < n) : (j += 1) {
            const a = keys[i][0..pfx];
            const b = keys[i + j];
            const m = @min(a.len, b.len);
            var k: usize = 0;
            while (k < m and a[k] == b[k]) k += 1;
            pfx = k;
        }
        block_starts[nblk] = blob.items.len;
        nblk += 1;
        try blob.append(alloc, @intCast(pfx));
        j = 0;
        while (j < n) : (j += 1) {
            const key = keys[i + j];
            const val = [_]u8{@intCast('0' + (i + j) % 10)};
            var hdr: [6 + 33]u8 = undefined;
            const hn = writeRecHdr(&hdr, key.len, val.len, i + j + 1, 0);
            try blob.appendSlice(alloc, hdr[0..hn]);
            // 块首那条写完整 key（自描述），其余写 suffix
            try blob.appendSlice(alloc, if (j == 0) key else key[pfx..]);
            try blob.appendSlice(alloc, &val);
        }
        i += n;
    }

    var it = try RecIter.init(alloc, blob.items, stride, 8);
    defer it.deinit(alloc);

    // 逐行解，结果必须与原始 key 完全一致；同时验证「上一行的 key」仍然可读（双缓冲）
    var prev: ?RecView = null;
    for (keys, 0..) |want, n| {
        const rec = it.next(alloc) orelse return error.MissingRow;
        try std.testing.expectEqualStrings(want, rec.key);
        try std.testing.expectEqual(@as(usize, want.len), rec.klen);
        try std.testing.expectEqual(n + 1, rec.seq);
        if (prev) |p| try std.testing.expectEqualStrings(keys[n - 1], p.key);
        prev = rec;
    }
    try std.testing.expect(it.next(alloc) == null);

    // 直接跳到第 2 / 第 3 块块头必须也能正确解出（块自描述，不依赖稀疏索引）
    for ([_]usize{ 1, 2 }) |bi| {
        var it2 = try RecIter.init(alloc, blob.items, stride, 8);
        defer it2.deinit(alloc);
        it2.seek(block_starts[bi]);
        const want = keys[bi * stride];
        const r0 = it2.next(alloc) orelse return error.MissingRow;
        try std.testing.expectEqualStrings(want, r0.key);
        if (bi * stride + 1 < keys.len) {
            const r1 = it2.next(alloc) orelse return error.MissingRow;
            try std.testing.expectEqualStrings(keys[bi * stride + 1], r1.key);
        }
    }
}

test "KeyArena：跨块分配的切片永不移动；reset 复用；retain 有上界" {
    const alloc = std.testing.allocator;
    var a = KeyArena{ .chunk_size = 64, .retain_bytes = 128 };
    defer a.deinit(alloc);

    // 分配 4 块（远超 retain）：先前拿到的切片内容必须还在原处
    var ptrs: [8][]u8 = undefined;
    for (&ptrs, 0..) |*p, i| {
        p.* = try a.alloc(alloc, 40);
        @memset(p.*, @intCast('a' + i));
    }
    for (ptrs, 0..) |p, i| {
        try std.testing.expectEqual(@as(usize, 40), p.len);
        try std.testing.expectEqual(@as(u8, @intCast('a' + i)), p[0]);
        try std.testing.expectEqual(@as(u8, @intCast('a' + i)), p[39]);
    }

    // raw slice 超过 chunk_size 也要能分配（单独占一块）
    const big = try a.alloc(alloc, 100);
    @memset(big, 'Z');
    try std.testing.expectEqual(@as(usize, 100), big.len);

    // reset 后最多保留 retain_bytes（128），其余释放；再分配仍可用
    a.reset(alloc);
    var kept: usize = 0;
    for (a.chunks.items) |c| kept += c.len;
    try std.testing.expect(kept <= a.retain_bytes);

    const again = try a.alloc(alloc, 40);
    @memset(again, 'q');
    try std.testing.expectEqual(@as(u8, 'q'), again[0]);
}

test "crc32 known value" {
    // CRC32("123456789") = 0xCBF43926
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32Fast("123456789"));

    // 快速版与单表版必须逐字节一致（含 0..40 各种长度与长块）
    {
        var buf: [1000]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(0x1234);
        const rnd = prng.random();
        rnd.bytes(&buf);
        var len: usize = 0;
        while (len <= 40) : (len += 1) {
            try std.testing.expectEqual(crc32(buf[0..len]), crc32Fast(buf[0..len]));
        }
        len = 41;
        while (len <= buf.len) : (len += 7) {
            try std.testing.expectEqual(crc32(buf[0..len]), crc32Fast(buf[0..len]));
        }
        try std.testing.expectEqual(crc32(&buf), crc32Fast(&buf));
        try std.testing.expectEqual(crc32(""), crc32Fast(""));
    }
}

test "varint roundtrip" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    for ([_]u64{ 0, 1, 127, 128, 300, 1 << 32, std.math.maxInt(u64) }) |v| {
        out.clearRetainingCapacity();
        try putVarint(&out, std.testing.allocator, v);
        var r = Reader{ .buf = out.items };
        try std.testing.expectEqual(v, try r.varint());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
}

test "i64 key order" {
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    encodeI64Key(&a, -5);
    encodeI64Key(&b, 7);
    try std.testing.expect(std.mem.order(u8, &a, &b) == .lt);
    encodeI64Key(&a, 7);
    encodeI64Key(&b, 7);
    try std.testing.expectEqualSlices(u8, &a, &b);
}
