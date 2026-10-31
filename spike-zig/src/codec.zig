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
    var v = value;
    while (v >= 0x80) {
        try out.append(alloc, @as(u8, @truncate(v)) | 0x80);
        v >>= 7;
    }
    try out.append(alloc, @truncate(v));
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
