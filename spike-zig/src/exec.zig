// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const sql = @import("sql.zig");
const schema_mod = @import("schema.zig");
const tablemod = @import("table.zig");
const segmod = @import("segment.zig");

/// 查询结果：行头数组 + 值扁平数组 + 值原文缓冲。三块一次性分配，deinit 只释放固定几块。
pub const Rows = struct {
    alloc: std.mem.Allocator,
    columns: [][]const u8,
    rows: [][]sql.Value,
    flat: []sql.Value = &.{},
    buf: []u8 = &.{},

    pub fn deinit(self: *Rows) void {
        for (self.columns) |c| self.alloc.free(c);
        self.alloc.free(self.columns);
        self.alloc.free(self.rows);
        self.alloc.free(self.flat);
        self.alloc.free(self.buf);
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

/// 一批已过滤的 refs 一次性解码：值原文 memcpy 进单块缓冲，text/blob 切片指向该缓冲。
const Materialized = struct {
    alloc: std.mem.Allocator,
    buf: []u8 = &.{},
    flat: []sql.Value = &.{},
    hdrs: [][]sql.Value = &.{},

    fn deinit(self: *Materialized) void {
        self.alloc.free(self.flat);
        self.alloc.free(self.hdrs);
        self.alloc.free(self.buf);
        self.* = undefined;
    }
};

fn decodeAll(
    alloc: std.mem.Allocator,
    s: *const schema_mod.Schema,
    refs: []const segmod.Segment.RefRecord,
) !Materialized {
    const ncols = s.columns.len;
    var total: usize = 0;
    for (refs) |r| total += r.value.len;

    const buf = try alloc.alloc(u8, total);
    errdefer alloc.free(buf);
    const flat = try alloc.alloc(sql.Value, refs.len * ncols);
    errdefer alloc.free(flat);
    const hdrs = try alloc.alloc([]sql.Value, refs.len);
    errdefer alloc.free(hdrs);

    var off: usize = 0;
    for (refs, 0..) |r, i| {
        const raw = buf[off..][0..r.value.len];
        @memcpy(raw, r.value);
        off += r.value.len;
        const vals = flat[i * ncols ..][0..ncols];
        try s.decodeRowInto(vals, raw);
        hdrs[i] = vals;
    }
    return .{ .alloc = alloc, .buf = buf, .flat = flat, .hdrs = hdrs };
}

/// 结果装配：按投影产出 Rows；恒等投影直接复用扁平数组（零拷贝）。
/// 成功后 m 的 buf/flat 所有权转移给 Rows，hdrs 仍由调用方释放。
fn buildOutput(
    alloc: std.mem.Allocator,
    s: *const schema_mod.Schema,
    m: *Materialized,
    proj: Projection,
    start: usize,
    end: usize,
) !Rows {
    defer alloc.free(proj.indices);
    const ncols = s.columns.len;
    const n = end - start;
    const out_rows = try alloc.alloc([]sql.Value, n);
    errdefer alloc.free(out_rows);

    var identity = proj.indices.len == ncols;
    if (identity) {
        for (proj.indices, 0..) |ci, i| {
            if (ci != i) {
                identity = false;
                break;
            }
        }
    }
    if (identity) {
        @memcpy(out_rows, m.hdrs[start..end]);
        const flat = m.flat;
        const buf = m.buf;
        m.flat = &.{};
        m.buf = &.{};
        return .{ .alloc = alloc, .columns = proj.columns, .rows = out_rows, .flat = flat, .buf = buf };
    }

    const pflat = try alloc.alloc(sql.Value, n * proj.indices.len);
    errdefer alloc.free(pflat);
    for (0..n) |i| {
        const dst = pflat[i * proj.indices.len ..][0..proj.indices.len];
        for (proj.indices, 0..) |ci, k| dst[k] = m.hdrs[start + i][ci];
        out_rows[i] = dst;
    }
    const buf = m.buf;
    m.buf = &.{};
    return .{ .alloc = alloc, .columns = proj.columns, .rows = out_rows, .flat = pflat, .buf = buf };
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
                    const cn = try alloc.dupe(u8, s.columns[i].name);
                    errdefer alloc.free(cn);
                    try columns.append(alloc, cn);
                }
            },
            .column => |name| {
                const idx = s.indexOf(name) orelse return error.ColumnNotFound;
                try indices.append(alloc, idx);
                const cn = try alloc.dupe(u8, s.columns[idx].name);
                errdefer alloc.free(cn);
                try columns.append(alloc, cn);
            },
        }
    }
    return .{ .indices = try indices.toOwnedSlice(alloc), .columns = try columns.toOwnedSlice(alloc) };
}

/// PK 等值查询走点查（不扫全表）。
fn selectByPk(t: *tablemod.Table, s: *const schema_mod.Schema, sel: sql.Select, pk: sql.Value, alloc: std.mem.Allocator) !Rows {
    const ncols = s.columns.len;
    const vals = try alloc.alloc(sql.Value, ncols);
    defer alloc.free(vals);
    for (vals) |*v| v.* = .null;
    vals[s.pk_index] = pk;

    const key = try s.encodeKey(alloc, vals);
    defer alloc.free(key);

    const proj = try buildProjection(alloc, s, sel.items);
    errdefer {
        for (proj.columns) |c| alloc.free(c);
        alloc.free(proj.columns);
    }

    var vbuf: std.ArrayList(u8) = .empty;
    defer vbuf.deinit(alloc);

    const raw = (try t.get(key, &vbuf)) orelse {
        const empty = try alloc.alloc([]sql.Value, 0);
        return .{ .alloc = alloc, .columns = proj.columns, .rows = empty };
    };

    const one = [_]segmod.Segment.RefRecord{.{ .key = key, .seq = 0, .flags = 0, .value = raw }};
    var m = try decodeAll(alloc, s, &one);
    defer m.deinit();
    return buildOutput(alloc, s, &m, proj, 0, 1);
}

pub fn updateRows(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    upd: sql.Update,
    alloc: std.mem.Allocator,
) !usize {
    var hi: [16]u8 = @splat(0xFF);
    var set = try t.scanRange(&[_]u8{}, &hi);
    defer set.deinit();

    var count: usize = 0;
    for (set.records) |rec| {
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
    var hi: [16]u8 = @splat(0xFF);
    var set = try t.scanRange(&[_]u8{}, &hi);
    defer set.deinit();

    var count: usize = 0;
    for (set.records) |rec| {
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
    var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
    defer refs.deinit(alloc);
    try t.scanRefs(&[_]u8{}, &hi, &refs);

    // 过滤：只解码到复用的 scratch，不分配行
    var keep: std.ArrayList(segmod.Segment.RefRecord) = .empty;
    defer keep.deinit(alloc);
    if (sel.where) |w| {
        const widx = s.indexOf(w.column) orelse return error.ColumnNotFound;
        const scratch = try alloc.alloc(sql.Value, s.columns.len);
        defer alloc.free(scratch);
        for (refs.items) |rec| {
            try s.decodeRowInto(scratch, rec.value);
            if (evalWhere(scratch[widx], w.op, w.value)) try keep.append(alloc, rec);
        }
    } else {
        try keep.appendSlice(alloc, refs.items);
    }

    var m = try decodeAll(alloc, s, keep.items);
    defer m.deinit();

    if (sel.order_by.len > 0) {
        const ctx = SortCtx{ .schema = s, .order = sel.order_by };
        std.mem.sort([]sql.Value, m.hdrs, ctx, rowLess);
    }

    var start: usize = 0;
    if (sel.offset) |o| start = @min(@as(usize, o), m.hdrs.len);
    var end: usize = m.hdrs.len;
    if (sel.limit) |l| end = @min(end, start + @as(usize, l));

    const proj = try buildProjection(alloc, s, sel.items);
    errdefer {
        for (proj.columns) |c| alloc.free(c);
        alloc.free(proj.columns);
    }
    return buildOutput(alloc, s, &m, proj, start, end);
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

