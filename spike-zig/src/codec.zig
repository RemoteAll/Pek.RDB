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

/// 一条记录的视图。**不拷贝**：`key` / `value` 直接借用 `buf`。
pub const RecView = struct {
    key: []const u8,
    value: []const u8,
    seq: u64,
    flags: u8,
    /// 下一条记录的起始偏移
    next: usize,
};

/// 行头字段的哨兵值：等于它就表示「真实值放不下，后面紧跟一个 varint」。
/// 选 255 / 255 / 0xFFFFFFFF 是因为它们恰好是各自定长字段能表示的最大值，
/// 用「最大值当逃逸」不浪费任何可表示空间。
const KLEN_ESC: u8 = 0xFF;
const VLEN_ESC: u8 = 0xFF;
const SEQ_ESC: u32 = 0xFFFF_FFFF;
/// 行头定长部分：`u8 klen, u8 vlen, u32 seq, u8 flags`
const REC_HDR: usize = 7;

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
/// 行格式（`PEKZAG05` 起）：
/// ```
/// u8 klen | u8 vlen | u32 seq | u8 flags | [klen 逃逸 varint] [vlen 逃逸] [seq 逃逸] | key | value
/// ```
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
pub inline fn readRec(buf: []const u8, pos: usize) ?RecView {
    if (pos + REC_HDR > buf.len) return null;
    const kraw = buf[pos];
    const vraw = buf[pos + 1];
    const sraw = std.mem.readInt(u32, buf[pos + 2 ..][0..4], .little);
    const flags = buf[pos + 6];
    var p = pos + REC_HDR;

    var klen: usize = kraw;
    if (kraw == KLEN_ESC) klen = @intCast(rdVarint(buf, &p) orelse return null);
    var vlen: usize = vraw;
    if (vraw == VLEN_ESC) vlen = @intCast(rdVarint(buf, &p) orelse return null);
    var seq: u64 = sraw;
    if (sraw == SEQ_ESC) seq = rdVarint(buf, &p) orelse return null;

    // 长度都是不可信输入：**先比剩余、再加**，避开 `p + klen` 溢出绕过判定。
    // 写成「先算剩余再减」而不是「先加再比」，编译器才能证明下面两个切片不越界，
    // 从而不插运行时边界检查（这正是配对微基准里那 20% 的来源）。
    const rest = buf.len - p;
    if (klen > rest) return null;
    const after_k = rest - klen;
    if (vlen > after_k) return null;
    const k = buf[p..][0..klen];
    const v = buf[p + klen ..][0..vlen];
    return .{ .key = k, .value = v, .seq = seq, .flags = flags, .next = p + klen + vlen };
}

/// 写行头到 `dst`（调用方保证至少 `7 + 30` 字节），返回写了几个字节。
/// **必须与 `readRec` 同改。**
pub fn writeRecHdr(dst: []u8, klen: usize, vlen: usize, seq: u64, flags: u8) usize {
    const k_esc = klen >= @as(usize, KLEN_ESC);
    const v_esc = vlen >= @as(usize, VLEN_ESC);
    const s_esc = seq >= @as(u64, SEQ_ESC);
    dst[0] = if (k_esc) KLEN_ESC else @intCast(klen);
    dst[1] = if (v_esc) VLEN_ESC else @intCast(vlen);
    std.mem.writeInt(u32, dst[2..6], if (s_esc) SEQ_ESC else @intCast(seq), .little);
    dst[6] = flags;
    var n: usize = 7;
    if (k_esc) n += encodeVarint(dst[n..], klen);
    if (v_esc) n += encodeVarint(dst[n..], vlen);
    if (s_esc) n += encodeVarint(dst[n..], seq);
    return n;
}

test "readRec: 定长 7B 头 + 哨兵逃逸 往返 + 边界（空值 / 长 key / 大 seq）" {
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
        // seq 逃逸边界
        .{ .key = "k4", .value = "v", .seq = @as(u64, SEQ_ESC) - 1, .flags = 0 },
        .{ .key = "k5", .value = "v", .seq = @as(u64, SEQ_ESC), .flags = 0 },
        .{ .key = "k6", .value = "v", .seq = std.math.maxInt(u64), .flags = 0 },
        // 三个逃逸同时命中
        .{ .key = &K300, .value = &V255, .seq = std.math.maxInt(u64), .flags = 1 },
    };

    var expect_off: [cases.len]usize = undefined;
    for (cases, 0..) |c, i| {
        expect_off[i] = buf.items.len;
        var hdr: [7 + 30]u8 = undefined;
        const hn = writeRecHdr(&hdr, c.key.len, c.value.len, c.seq, c.flags);
        try buf.appendSlice(alloc, hdr[0..hn]);
        try buf.appendSlice(alloc, c.key);
        try buf.appendSlice(alloc, c.value);
    }

    for (cases, 0..) |c, i| {
        const rec = readRec(buf.items, expect_off[i]) orelse return error.RecMissing;
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

    // 定长头确实只有 7 字节：小字段（8B key / 32B value / 小 seq）时整行 = 7+8+32
    {
        var hdr: [7 + 30]u8 = undefined;
        const hn = writeRecHdr(&hdr, 8, 32, 1_234_567, 0);
        try std.testing.expectEqual(@as(usize, 7), hn);
    }
    // 边界前后必须严格分开：254 不逃逸、255 逃逸（逃逸版多 2 字节：255 + 1B varint）
    {
        var hdr: [7 + 30]u8 = undefined;
        const a = writeRecHdr(&hdr, 254, 254, 0xFFFF_FFFE, 0);
        const b = writeRecHdr(&hdr, 255, 255, 0xFFFF_FFFF, 0);
        try std.testing.expectEqual(@as(usize, 7), a);
        try std.testing.expectEqual(@as(usize, 7 + 2 + 2 + 5), b);
    }

    // 截断必须返回 null，不能 panic、也不能读越界
    try std.testing.expect(readRec(buf.items, buf.items.len) == null);
    try std.testing.expect(readRec(buf.items, buf.items.len + 100) == null);
    var cut: usize = 0;
    while (cut < buf.items.len) : (cut += 3) {
        _ = readRec(buf.items[0..cut], 0); // 只要不 panic / 不越界
        _ = readRec(buf.items, cut);
    }
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
