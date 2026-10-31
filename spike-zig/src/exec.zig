const std = @import("std");
const sql = @import("sql.zig");
const schema_mod = @import("schema.zig");
const tablemod = @import("table.zig");
const segmod = @import("segment.zig");

pub const Rows = struct {
    alloc: std.mem.Allocator,
    columns: [][]const u8,
    rows: [][]sql.Value,
    bufs: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Rows) void {
        for (self.columns) |c| self.alloc.free(c);
        self.alloc.free(self.columns);
        for (self.rows) |r| self.alloc.free(r);
        self.alloc.free(self.rows);
        for (self.bufs.items) |b| self.alloc.free(b);
        self.bufs.deinit(self.alloc);
        self.* = undefined;
    }
};

fn evalWhere(a: sql.Value, op: sql.CmpOp, b: sql.Value) bool {
    const ord = schema_mod.valueCmp(a, b);
    return switch (op) {
        .eq => ord == .eq,
        .ne => ord != .eq,
        .lt => ord == .lt,
        .le => ord != .gt,
        .gt => ord == .gt,
        .ge => ord != .lt,
    };
}

const SortCtx = struct {
    schema: *const schema_mod.Schema,
    order: []const sql.OrderItem,
};

fn rowLess(ctx: SortCtx, a: []sql.Value, b: []sql.Value) bool {
    for (ctx.order) |o| {
        const idx = ctx.schema.indexOf(o.column) orelse return false;
        const ord = schema_mod.valueCmp(a[idx], b[idx]);
        if (ord == .eq) continue;
        return if (o.desc) ord == .gt else ord == .lt;
    }
    return false;
}

/// 把值深拷贝一份（text/blob 放进独立缓冲），便于返回给调用方。
fn copyRow(alloc: std.mem.Allocator, values: []const sql.Value) !struct { vals: []sql.Value, buf: []u8 } {
    var total: usize = 0;
    for (values) |v| {
        switch (v) {
            .text => |s| total += s.len,
            .blob => |s| total += s.len,
            else => {},
        }
    }
    const buf = try alloc.alloc(u8, total);
    errdefer alloc.free(buf);
    const vals = try alloc.alloc(sql.Value, values.len);
    errdefer alloc.free(vals);

    var off: usize = 0;
    for (values, 0..) |v, i| {
        vals[i] = switch (v) {
            .text => |s| blk: {
                @memcpy(buf[off .. off + s.len], s);
                const p = buf[off .. off + s.len];
                off += s.len;
                break :blk .{ .text = p };
            },
            .blob => |s| blk: {
                @memcpy(buf[off .. off + s.len], s);
                const p = buf[off .. off + s.len];
                off += s.len;
                break :blk .{ .blob = p };
            },
            else => v,
        };
    }
    return .{ .vals = vals, .buf = buf };
}

pub fn insertRows(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    ins: sql.Insert,
    alloc: std.mem.Allocator,
) !usize {
    var count: usize = 0;
    for (ins.rows) |row| {
        var mapped: []sql.Value = undefined;
        var owned = false;
        if (ins.columns.len == 0) {
            if (row.len != s.columns.len) return error.TypeMismatch;
            mapped = row;
        } else {
            mapped = try alloc.alloc(sql.Value, s.columns.len);
            owned = true;
            for (mapped) |*v| v.* = .null;
            for (ins.columns, row) |name, v| {
                const idx = s.indexOf(name) orelse return error.ColumnNotFound;
                mapped[idx] = v;
            }
        }
        defer if (owned) alloc.free(mapped);

        const key = try s.encodeKey(alloc, mapped);
        defer alloc.free(key);
        const encoded = try s.encodeRow(alloc, mapped);
        defer alloc.free(encoded);
        try t.put(key, encoded);
        count += 1;
    }
    return count;
}

const Projection = struct {
    indices: []usize,
    columns: [][]const u8,
};

fn buildProjection(alloc: std.mem.Allocator, s: *const schema_mod.Schema, items: []const sql.SelectItem) !Projection {
    var indices: std.ArrayList(usize) = .empty;
    var columns: std.ArrayList([]const u8) = .empty;
    errdefer {
        indices.deinit(alloc);
        for (columns.items) |c| alloc.free(c);
        columns.deinit(alloc);
    }
    for (items) |item| {
        switch (item) {
            .star => {
                for (0..s.columns.len) |i| {
                    try indices.append(alloc, i);
                    try columns.append(alloc, try alloc.dupe(u8, s.columns[i].name));
                }
            },
            .column => |name| {
                const idx = s.indexOf(name) orelse return error.ColumnNotFound;
                try indices.append(alloc, idx);
                try columns.append(alloc, try alloc.dupe(u8, s.columns[idx].name));
            },
        }
    }
    return .{ .indices = try indices.toOwnedSlice(alloc), .columns = try columns.toOwnedSlice(alloc) };
}

/// PK 等值查询走点查（不扫全表）。
fn selectByPk(t: *tablemod.Table, s: *const schema_mod.Schema, sel: sql.Select, pk: sql.Value, alloc: std.mem.Allocator) !Rows {
    var vals = try alloc.alloc(sql.Value, s.columns.len);
    defer alloc.free(vals);
    for (vals) |*v| v.* = .null;
    vals[s.pk_index] = pk;

    const key = try s.encodeKey(alloc, vals);
    defer alloc.free(key);

    const proj = try buildProjection(alloc, s, sel.items);
    defer alloc.free(proj.indices);
    errdefer {
        for (proj.columns) |c| alloc.free(c);
        alloc.free(proj.columns);
    }

    var out_rows: std.ArrayList([]sql.Value) = .empty;
    var bufs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out_rows.items) |r| alloc.free(r);
        out_rows.deinit(alloc);
        for (bufs.items) |b| alloc.free(b);
        bufs.deinit(alloc);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    if (try t.get(key, &buf)) |bytes| {
        const decoded = try s.decodeRow(alloc, bytes);
        defer alloc.free(decoded);
        const copied = try copyRow(alloc, decoded);
        try bufs.append(alloc, copied.buf);
        const p = try alloc.alloc(sql.Value, proj.indices.len);
        for (proj.indices, 0..) |ci, k| p[k] = copied.vals[ci];
        alloc.free(copied.vals);
        try out_rows.append(alloc, p);
    }

    return .{
        .alloc = alloc,
        .columns = proj.columns,
        .rows = try out_rows.toOwnedSlice(alloc),
        .bufs = bufs,
    };
}

fn freeRecs(alloc: std.mem.Allocator, recs: *std.ArrayList(segmod.RecordOwned)) void {
    for (recs.items) |r| {
        alloc.free(r.key);
        alloc.free(r.value);
    }
    recs.deinit(alloc);
}

pub fn updateRows(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    upd: sql.Update,
    alloc: std.mem.Allocator,
) !usize {
    var recs: std.ArrayList(segmod.RecordOwned) = .empty;
    defer freeRecs(alloc, &recs);
    var hi: [16]u8 = @splat(0xFF);
    try t.scanRange(&[_]u8{}, &hi, &recs);

    var count: usize = 0;
    for (recs.items) |rec| {
        const vals = try s.decodeRow(alloc, rec.value);
        var matched = true;
        if (upd.where) |w| {
            const idx = s.indexOf(w.column) orelse {
                alloc.free(vals);
                return error.ColumnNotFound;
            };
            matched = evalWhere(vals[idx], w.op, w.value);
        }
        if (!matched) {
            alloc.free(vals);
            continue;
        }
        for (upd.assignments) |a| {
            const idx = s.indexOf(a.column) orelse {
                alloc.free(vals);
                return error.ColumnNotFound;
            };
            vals[idx] = a.value;
        }
        const key = try s.encodeKey(alloc, vals);
        defer alloc.free(key);
        const encoded = try s.encodeRow(alloc, vals);
        defer alloc.free(encoded);
        if (!std.mem.eql(u8, key, rec.key)) try t.delete(rec.key);
        try t.put(key, encoded);
        alloc.free(vals);
        count += 1;
    }
    return count;
}

pub fn deleteRows(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    del: sql.Delete,
    alloc: std.mem.Allocator,
) !usize {
    var recs: std.ArrayList(segmod.RecordOwned) = .empty;
    defer freeRecs(alloc, &recs);
    var hi: [16]u8 = @splat(0xFF);
    try t.scanRange(&[_]u8{}, &hi, &recs);

    var count: usize = 0;
    for (recs.items) |rec| {
        if (del.where) |w| {
            const vals = try s.decodeRow(alloc, rec.value);
            const idx = s.indexOf(w.column) orelse {
                alloc.free(vals);
                return error.ColumnNotFound;
            };
            const ok = evalWhere(vals[idx], w.op, w.value);
            alloc.free(vals);
            if (!ok) continue;
        }
        try t.delete(rec.key);
        count += 1;
    }
    return count;
}

fn appendDecoded(
    alloc: std.mem.Allocator,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    bytes: []const u8,
    full_rows: *std.ArrayList([]sql.Value),
    bufs: *std.ArrayList([]u8),
) !void {
    const vals = try s.decodeRow(alloc, bytes);
    if (sel.where) |w| {
        const idx = s.indexOf(w.column) orelse {
            alloc.free(vals);
            return error.ColumnNotFound;
        };
        if (!evalWhere(vals[idx], w.op, w.value)) {
            alloc.free(vals);
            return;
        }
    }
    const copied = try copyRow(alloc, vals);
    alloc.free(vals);
    try full_rows.append(alloc, copied.vals);
    try bufs.append(alloc, copied.buf);
}

pub fn selectRows(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
) !Rows {
    // PK 等值查询：直接点查，不扫全表。
    if (sel.where) |w| {
        if (w.op == .eq) {
            if (s.indexOf(w.column)) |idx| {
                if (idx == s.pk_index) {
                    return selectByPk(t, s, sel, w.value, alloc);
                }
            }
        }
    }

    var hi: [16]u8 = @splat(0xFF);
    var full_rows: std.ArrayList([]sql.Value) = .empty;
    var bufs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (full_rows.items) |r| alloc.free(r);
        full_rows.deinit(alloc);
        for (bufs.items) |b| alloc.free(b);
        bufs.deinit(alloc);
    }

    var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
    defer refs.deinit(alloc);
    try t.scanRefs(&[_]u8{}, &hi, &refs);
    for (refs.items) |rec| {
        try appendDecoded(alloc, s, sel, rec.value, &full_rows, &bufs);
    }

    if (sel.order_by.len > 0) {
        const ctx = SortCtx{ .schema = s, .order = sel.order_by };
        std.mem.sort([]sql.Value, full_rows.items, ctx, rowLess);
    }

    var start: usize = 0;
    if (sel.offset) |o| start = @min(@as(usize, o), full_rows.items.len);
    var end: usize = full_rows.items.len;
    if (sel.limit) |l| end = @min(end, start + @as(usize, l));

    // 投影
    const proj = try buildProjection(alloc, s, sel.items);
    defer alloc.free(proj.indices);
    errdefer {
        for (proj.columns) |c| alloc.free(c);
        alloc.free(proj.columns);
    }

    var out_rows: std.ArrayList([]sql.Value) = .empty;
    errdefer {
        for (out_rows.items) |r| alloc.free(r);
        out_rows.deinit(alloc);
    }
    for (full_rows.items[start..end]) |full| {
        const p = try alloc.alloc(sql.Value, proj.indices.len);
        for (proj.indices, 0..) |ci, k| p[k] = full[ci];
        try out_rows.append(alloc, p);
    }
    for (full_rows.items) |r| alloc.free(r);
    full_rows.deinit(alloc);

    const rows_slice = try out_rows.toOwnedSlice(alloc);
    const cols_slice = proj.columns;

    return .{
        .alloc = alloc,
        .columns = cols_slice,
        .rows = rows_slice,
        .bufs = bufs,
    };
}

test "insert + select with where/order/limit" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-tmp";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "name", .col_type = .text },
        .{ .name = "age", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "users", &cols);
    defer s.deinit(alloc);

    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    {
        var p = try sql.parse(alloc, "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30), (2, 'Bob', 25), (3, 'Cara', 30)");
        defer p.deinit();
        const n = try insertRows(&t, &s, p.stmt.insert, alloc);
        try std.testing.expectEqual(@as(usize, 3), n);
    }

    {
        var p = try sql.parse(alloc, "SELECT id, name FROM users WHERE age >= 30 ORDER BY id DESC LIMIT 2");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqualStrings("Cara", rows.rows[0][1].text);
        try std.testing.expectEqualStrings("Alice", rows.rows[1][1].text);
    }

    {
        var p = try sql.parse(alloc, "SELECT * FROM users WHERE id = 2");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(usize, 3), rows.rows[0].len);
        try std.testing.expectEqualStrings("Bob", rows.rows[0][1].text);
    }
}

test "update + delete" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-ud";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "name", .col_type = .text },
        .{ .name = "age", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "users", &cols);
    defer s.deinit(alloc);

    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    {
        var p = try sql.parse(alloc, "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30), (2, 'Bob', 25), (3, 'Cara', 30)");
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    {
        var p = try sql.parse(alloc, "UPDATE users SET age = 40 WHERE id = 1");
        defer p.deinit();
        const n = try updateRows(&t, &s, p.stmt.update, alloc);
        try std.testing.expectEqual(@as(usize, 1), n);
    }

    {
        var p = try sql.parse(alloc, "SELECT * FROM users WHERE id = 1");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 40), rows.rows[0][2].integer);
    }

    {
        var p = try sql.parse(alloc, "DELETE FROM users WHERE age < 28");
        defer p.deinit();
        const n = try deleteRows(&t, &s, p.stmt.delete, alloc);
        try std.testing.expectEqual(@as(usize, 1), n);
    }

    {
        var p = try sql.parse(alloc, "SELECT id FROM users ORDER BY id");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[1][0].integer);
    }
}

