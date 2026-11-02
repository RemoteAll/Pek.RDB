// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const codec = @import("codec.zig");
const sql = @import("sql.zig");

pub const Error = error{
    InvalidSchema,
    InvalidIdentifier,
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

/// 单列二级索引定义。
pub const IndexDef = struct {
    name: []const u8,
    column_idx: usize,
};

pub const Schema = struct {
    name: []const u8,
    columns: []const Column,
    pk_index: usize,
    /// 二级索引（声明顺序）。空时是 `&.{}`，**deinit 要判空**：
    /// 对静态空切片调 `alloc.free` 是未定义行为。
    indexes: []IndexDef = &.{},

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
        if (self.indexes.len != 0) {
            for (self.indexes) |ix| alloc.free(ix.name);
            alloc.free(self.indexes);
        }
        self.* = undefined;
    }

    /// 登记一个索引（深拷贝名字）。同名视为已存在，返回 false。
    ///
    /// 名字**不得含空白**：catalog 的 `#idx <名字> <列号>` 是单行空格分隔的格式，
    /// 名字带空格会让它下次加载时被拆成两段（索引静默消失 = 查询退回全扫，还看不出错）。
    /// 词法层本来也只认 `[A-Za-z0-9_]` 标识符（没有引号/方括号），这个限制与全局一致。
    pub fn addIndex(self: *Schema, alloc: std.mem.Allocator, name: []const u8, column_idx: usize) Error!bool {
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t\r\n") != null) return error.InvalidIdentifier;
        for (self.indexes) |ix| {
            if (std.ascii.eqlIgnoreCase(ix.name, name)) return false;
        }
        const grown = try alloc.alloc(IndexDef, self.indexes.len + 1);
        errdefer alloc.free(grown);
        @memcpy(grown[0..self.indexes.len], self.indexes);
        grown[self.indexes.len] = .{ .name = try alloc.dupe(u8, name), .column_idx = column_idx };
        if (self.indexes.len != 0) alloc.free(self.indexes);
        self.indexes = grown;
        return true;
    }

    /// 哪些索引建在这一列上（单列索引最多一个，返回第一个）。
    pub fn indexOnColumn(self: *const Schema, column_idx: usize) ?IndexDef {
        for (self.indexes) |ix| {
            if (ix.column_idx == column_idx) return ix;
        }
        return null;
    }

    pub fn findIndex(self: *const Schema, name: []const u8) ?IndexDef {
        for (self.indexes) |ix| {
            if (std.ascii.eqlIgnoreCase(ix.name, name)) return ix;
        }
        return null;
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
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try appendValueComponent(&out, alloc, values[self.pk_index]);
        return out.toOwnedSlice(alloc);
    }

    /// 单列值分量（二级索引键的第一段）。NULL 不收录 —— 索引对 NULL 无意义，
    /// 且 `=` 永远匹配不到 NULL，收录只会白白变大。
    pub fn encodeValueComponent(self: *const Schema, alloc: std.mem.Allocator, column_idx: usize, v: sql.Value) Error![]u8 {
        _ = self;
        _ = column_idx;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try appendValueComponent(&out, alloc, v);
        return out.toOwnedSlice(alloc);
    }

    /// 二级索引键 = `值分量 ++ 主键分量`。
    ///
    /// 两段都自定界，所以查询时把前缀长度切掉就得到**行的主键键**（无需解码主键）；
    /// 顺序保持，所以等值查询等价于一次键前缀范围扫描。
    pub fn encodeIndexKey(
        self: *const Schema,
        alloc: std.mem.Allocator,
        column_idx: usize,
        col_value: sql.Value,
        pk_value: sql.Value,
    ) Error![]u8 {
        _ = self;
        _ = column_idx;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try appendValueComponent(&out, alloc, col_value);
        try appendValueComponent(&out, alloc, pk_value);
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

    /// 只解码 `want` 指定的列（**必须严格升序**），其余列仅按类型跳过。
    ///
    /// 这就是 SQLite `OP_Column` 的惰性：不取值就不解码。跳 text/blob 时只读长度
    /// varint、不碰内容（`r.bytes` 返回的切片被丢弃，只推进游标）。
    ///
    /// 为什么它值钱：`SELECT id FROM t` 现在会解码全部列再把没投影的丢掉，
    /// 而投影结果还要另分配一份 `pflat` 逐行拷贝 —— 实测比 `SELECT *` 还慢 16%
    /// （14.68M vs 17.51M 行/s，§16.1.20）。按投影解码后 `flat` 直接就是最终布局。
    pub fn decodeRowProjected(self: *const Schema, dst: []sql.Value, want: []const usize, bytes: []const u8) Error!void {
        const n = self.columns.len;
        const bitmap_len = (n + 7) / 8;
        if (bytes.len < bitmap_len) return error.CorruptRow;
        if (dst.len != want.len) return error.TypeMismatch;
        var r = codec.Reader{ .buf = bytes[bitmap_len..] };
        var wi: usize = 0;
        for (self.columns, 0..) |col, i| {
            const is_null = (bytes[i / 8] & (@as(u8, 1) << @intCast(i % 8))) != 0;
            if (wi < want.len and want[wi] == i) {
                if (is_null) {
                    dst[wi] = .null;
                } else {
                    dst[wi] = switch (col.col_type) {
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
                wi += 1;
                continue;
            }
            // 未投影：只前进游标，不解码也不拷贝
            if (is_null) continue;
            switch (col.col_type) {
                .integer, .bigint, .datetime, .real, .double => _ = try r.u64le(),
                .boolean => _ = try r.u8v(),
                .text, .blob => {
                    const len: usize = @intCast(try r.varint());
                    _ = try r.bytes(len);
                },
            }
        }
    }
};

/// 把「8 字节定长」的值分量写进 `dst`（数值型：integer/bigint/datetime/real/double）。
///
/// 返回 `false` 表示不是数值型，调用方走通用路径（text/blob 是变长 + 转义）。
/// **存在的意义是消除重复实现**：`appendValueComponent` 与索引回填的快路径都用它，
/// 两处各写一份迟早会不一致，而不一致的后果是「索引键顺序与行键顺序不同」→ 查出来漏行。
pub fn writeFixedComponent(dst: *[8]u8, v: sql.Value) bool {
    switch (v) {
        .integer => |x| {
            codec.encodeI64Key(dst, x);
            return true;
        },
        .real => |x| {
            var bits: u64 = @bitCast(x);
            bits = if ((bits >> 63) != 0) ~bits else bits | 0x8000_0000_0000_0000;
            std.mem.writeInt(u64, dst, bits, .big);
            return true;
        },
        else => return false,
    }
}

/// 单个值分量编码：**顺序保持 + 自定界**（数值 8 字节定长；text/blob 转义后以 `0x00 0x01` 收尾）。
///
/// 主键与二级索引键共用这一份 —— 两处各写一遍迟早会不一致，而不一致的后果是
/// 「索引键的前缀比较与行键比较得出不同顺序」，查出来的结果就会漏行或乱序。
fn appendValueComponent(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: sql.Value) !void {
    var fixed: [8]u8 = undefined;
    if (writeFixedComponent(&fixed, v)) {
        try out.appendSlice(alloc, &fixed);
        return;
    }
    switch (v) {
        .null => return error.TypeMismatch,
        .text => |s| try Schema.escapeComponent(out, alloc, s, true),
        .blob => |s| try Schema.escapeComponent(out, alloc, s, true),
        else => unreachable, // 数值型已在上面处理
    }
}

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

test "二级索引：名字不许含空白（catalog 行是空格分隔的），重复名字返回 false" {
    const alloc = std.testing.allocator;
    const cols = [_]Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "g", .col_type = .integer },
    };
    var s = try Schema.init(alloc, "t", &cols);
    defer s.deinit(alloc);

    // 名字带空格 → 拒绝：写进 `schema.txt` 后下次加载会被拆成两段，索引静默消失
    try std.testing.expectError(error.InvalidIdentifier, s.addIndex(alloc, "my idx", 1));
    try std.testing.expectError(error.InvalidIdentifier, s.addIndex(alloc, "", 1));
    try std.testing.expectEqual(@as(usize, 0), s.indexes.len);

    try std.testing.expect(try s.addIndex(alloc, "idx_g", 1));
    // 同名（大小写不敏感）→ false，不重复登记
    try std.testing.expect(!try s.addIndex(alloc, "IDX_G", 1));
    try std.testing.expectEqual(@as(usize, 1), s.indexes.len);
    try std.testing.expectEqual(@as(usize, 1), s.indexOnColumn(1).?.column_idx);
    try std.testing.expect(s.indexOnColumn(0) == null);
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
