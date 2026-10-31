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

pub fn crc32(bytes: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (bytes) |b| {
        c = (c >> 8) ^ crc_table[@as(u8, @truncate(c)) ^ b];
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
