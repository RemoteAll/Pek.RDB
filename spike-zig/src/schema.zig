// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const codec = @import("codec.zig");
const sql = @import("sql.zig");

pub const Error = error{
    InvalidSchema,
    MissingPrimaryKey,
    TooManyPrimaryKeys,
    TypeMismatch,
    CorruptRow,
    Truncated,
    Overflow,
} || std.mem.Allocator.Error;

pub const Column = struct {
    name: []const u8,
    col_type: sql.ColumnType,
    primary_key: bool = false,
    auto_increment: bool = false,
    not_null: bool = false,
};

pub const Schema = struct {
    name: []const u8,
    columns: []const Column,
    pk_index: usize,

    pub fn init(alloc: std.mem.Allocator, name: []const u8, columns: []const Column) Error!Schema {
        var pk_count: usize = 0;
        var pk_index: usize = 0;
        for (columns, 0..) |c, i| {
            if (c.primary_key) {
                pk_count += 1;
                pk_index = i;
            }
        }
        if (pk_count == 0) return error.MissingPrimaryKey;
        if (pk_count > 1) return error.TooManyPrimaryKeys;

        const name_copy = try alloc.dupe(u8, name);
        errdefer alloc.free(name_copy);
        const cols = try alloc.alloc(Column, columns.len);
        errdefer alloc.free(cols);
        for (columns, 0..) |c, i| {
            cols[i] = c;
            cols[i].name = try alloc.dupe(u8, c.name);
        }
        return .{
            .name = name_copy,
            .columns = cols,
            .pk_index = pk_index,
        };
    }

    pub fn deinit(self: *Schema, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.columns) |c| alloc.free(c.name);
        alloc.free(self.columns);
        self.* = undefined;
    }

    pub fn indexOf(self: *const Schema, name: []const u8) ?usize {
        for (self.columns, 0..) |c, i| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) return i;
        }
        return null;
    }

    fn escapeComponent(out: *std.ArrayList(u8), alloc: std.mem.Allocator, bytes: []const u8, term: bool) !void {
        for (bytes) |b| {
            if (b == 0) {
                try out.append(alloc, 0);
                try out.append(alloc, 0xFF);
            } else {
                try out.append(alloc, b);
            }
        }
        if (term) {
            try out.append(alloc, 0);
            try out.append(alloc, 0x01);
        }
    }

    /// 顺序保持的单列主键编码（复合主键后续再扩）。
    pub fn encodeKey(self: *const Schema, alloc: std.mem.Allocator, values: []const sql.Value) Error![]u8 {
        if (values.len != self.columns.len) return error.TypeMismatch;
        const v = values[self.pk_index];
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        switch (v) {
            .null => return error.TypeMismatch,
            .integer => |x| {
                var b: [8]u8 = undefined;
                codec.encodeI64Key(&b, x);
                try out.appendSlice(alloc, &b);
            },
            .real => |x| {
                var bits: u64 = @bitCast(x);
                bits = if ((bits >> 63) != 0) ~bits else bits | 0x8000_0000_0000_0000;
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, bits, .big);
                try out.appendSlice(alloc, &b);
            },
            .text => |s| try escapeComponent(&out, alloc, s, true),
            .blob => |s| try escapeComponent(&out, alloc, s, true),
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn encodeRow(self: *const Schema, alloc: std.mem.Allocator, values: []const sql.Value) Error![]u8 {
        if (values.len != self.columns.len) return error.TypeMismatch;
        const n = self.columns.len;
        const bitmap_len = (n + 7) / 8;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.resize(alloc, bitmap_len);
        @memset(out.items, 0);

        for (self.columns, values, 0..) |col, v, i| {
            switch (v) {
                .null => {
                    out.items[i / 8] |= @as(u8, 1) << @intCast(i % 8);
                    continue;
                },
                else => {},
            }
            switch (col.col_type) {
                .integer, .bigint, .datetime => {
                    const x: i64 = switch (v) {
                        .integer => |x| x,
                        else => return error.TypeMismatch,
                    };
                    var b: [8]u8 = undefined;
                    std.mem.writeInt(i64, &b, x, .little);
                    try out.appendSlice(alloc, &b);
                },
                .real, .double => {
                    const x: f64 = switch (v) {
                        .real => |x| x,
                        .integer => |x| @floatFromInt(x),
                        else => return error.TypeMismatch,
                    };
                    var b: [8]u8 = undefined;
                    std.mem.writeInt(u64, &b, @bitCast(x), .little);
                    try out.appendSlice(alloc, &b);
                },
                .boolean => {
                    const x: i64 = switch (v) {
                        .integer => |x| x,
                        else => return error.TypeMismatch,
                    };
                    try out.append(alloc, @intFromBool(x != 0));
                },
                .text, .blob => {
                    const s = switch (v) {
                        .text => |s| s,
                        .blob => |s| s,
                        else => return error.TypeMismatch,
                    };
                    try codec.putVarint(&out, alloc, s.len);
                    try out.appendSlice(alloc, s);
                },
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// 解码行到调用方提供的目标切片（零分配）；text/blob 切片指向 `bytes`（调用方需保证其生命周期）。
    pub fn decodeRowInto(self: *const Schema, dst: []sql.Value, bytes: []const u8) Error!void {
        const n = self.columns.len;
        if (dst.len != n) return error.TypeMismatch;
        const bitmap_len = (n + 7) / 8;
        if (bytes.len < bitmap_len) return error.CorruptRow;
        var r = codec.Reader{ .buf = bytes[bitmap_len..] };

        for (self.columns, 0..) |col, i| {
            const is_null = (bytes[i / 8] & (@as(u8, 1) << @intCast(i % 8))) != 0;
            if (is_null) {
                dst[i] = .null;
                continue;
            }
            dst[i] = switch (col.col_type) {
                .integer, .bigint, .datetime => .{ .integer = @bitCast(try r.u64le()) },
                .real, .double => .{ .real = @bitCast(try r.u64le()) },
                .boolean => .{ .integer = @intFromBool(try r.u8v() != 0) },
                .text, .blob => blk: {
                    const len: usize = @intCast(try r.varint());
                    const s = try r.bytes(len);
                    break :blk if (col.col_type == .text) .{ .text = s } else .{ .blob = s };
                },
            };
        }
    }

    /// 解码行（返回新分配的值数组）；text/blob 切片指向 `bytes`。
    pub fn decodeRow(self: *const Schema, alloc: std.mem.Allocator, bytes: []const u8) Error![]sql.Value {
        const vals = try alloc.alloc(sql.Value, self.columns.len);
        errdefer alloc.free(vals);
        try self.decodeRowInto(vals, bytes);
        return vals;
    }
};

pub fn valueCmp(a: sql.Value, b: sql.Value) std.math.Order {
    return switch (a) {
        .null => switch (b) {
            .null => .eq,
            else => .lt,
        },
        .integer => |x| switch (b) {
            .integer => |y| std.math.order(x, y),
            .real => |y| std.math.order(@as(f64, @floatFromInt(x)), y),
            .null => .gt,
            else => .lt,
        },
        .real => |x| switch (b) {
            .real => |y| std.math.order(x, y),
            .integer => |y| std.math.order(x, @as(f64, @floatFromInt(y))),
            .null => .gt,
            else => .lt,
        },
        .text => |x| switch (b) {
            .text => |y| std.mem.order(u8, x, y),
            .null => .gt,
            else => .lt,
        },
        .blob => |x| switch (b) {
            .blob => |y| std.mem.order(u8, x, y),
            .null => .gt,
            else => .lt,
        },
    };
}

test "schema key encode order" {
    const alloc = std.testing.allocator;
    const cols = [_]Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "name", .col_type = .text },
    };
    var s = try Schema.init(alloc, "users", &cols);
    defer s.deinit(alloc);

    const k1 = try s.encodeKey(alloc, &.{ .{ .integer = -5 }, .{ .text = "a" } });
    defer alloc.free(k1);
    const k2 = try s.encodeKey(alloc, &.{ .{ .integer = 7 }, .{ .text = "a" } });
    defer alloc.free(k2);
    try std.testing.expect(std.mem.order(u8, k1, k2) == .lt);
}

test "schema row roundtrip" {
    const alloc = std.testing.allocator;
    const cols = [_]Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "name", .col_type = .text },
        .{ .name = "score", .col_type = .double },
    };
    var s = try Schema.init(alloc, "t", &cols);
    defer s.deinit(alloc);

    const values = [_]sql.Value{ .{ .integer = 1 }, .{ .text = "Alice" }, .{ .real = 3.5 } };
    const encoded = try s.encodeRow(alloc, &values);
    defer alloc.free(encoded);

    const decoded = try s.decodeRow(alloc, encoded);
    defer alloc.free(decoded);
    try std.testing.expectEqual(@as(i64, 1), decoded[0].integer);
    try std.testing.expectEqualStrings("Alice", decoded[1].text);
    try std.testing.expectEqual(@as(f64, 3.5), decoded[2].real);
}

test "schema null bitmap" {
    const alloc = std.testing.allocator;
    const cols = [_]Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "name", .col_type = .text },
    };
    var s = try Schema.init(alloc, "t", &cols);
    defer s.deinit(alloc);
    const values = [_]sql.Value{ .{ .integer = 1 }, .null };
    const encoded = try s.encodeRow(alloc, &values);
    defer alloc.free(encoded);
    const decoded = try s.decodeRow(alloc, encoded);
    defer alloc.free(decoded);
    try std.testing.expect(decoded[1] == .null);
}
