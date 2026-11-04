// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const sql = @import("sql.zig");
const schema_mod = @import("schema.zig");

pub const Error = error{BadCatalog} || std.mem.Allocator.Error;

fn readWholeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const f = dir.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return alloc.alloc(u8, 0),
        else => return err,
    };
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

fn writeText(io: std.Io, dir: std.Io.Dir, path: []const u8, text: []const u8) !void {
    var f = try dir.createFile(io, path, .{ .truncate = true });
    try f.writePositionalAll(io, text, 0);
    try f.sync(io);
    f.close(io);
}

/// 每表 schema：`v1` + 表名 + 每列 `name type pk notnull autoinc`。
pub fn saveSchema(io: std.Io, dir: std.Io.Dir, table_path: []const u8, s: *const schema_mod.Schema, alloc: std.mem.Allocator) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "v1\n");
    try out.appendSlice(alloc, s.name);
    try out.append(alloc, '\n');
    for (s.columns) |c| {
        const line = try alloc.print("{s} {s} {d} {d} {d}\n", .{
            c.name,
            @tagName(c.col_type),
            @intFromBool(c.primary_key),
            @intFromBool(c.not_null),
            @intFromBool(c.auto_increment),
        });
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    // 索引用 `#idx ` 前缀：列名是 SQL 标识符，永远不会以 `#` 开头，
    // 所以老文件（没有这些行）= 无索引，新老文件可以互相读。
    for (s.indexes) |ix| {
        // 名字带空格会把下一行加载拆成两段（索引静默消失）。`addIndex` 已拦，这里是
        // 第二道闸：写盘前再确认一次，宁可报错也不写出一个下次读不回来的 catalog。
        if (std.mem.indexOfAny(u8, ix.name, " \t\r\n") != null) return error.BadCatalog;
        // 列号写成逗号分隔：单列时形如 `#idx idx_g 1`，与**旧格式逐字节一致**，
        // 所以旧库不用迁移、旧版本也能读新库的单列索引。
        var cols_text: std.ArrayList(u8) = .empty;
        defer cols_text.deinit(alloc);
        for (ix.columns, 0..) |ci, k| {
            if (k != 0) try cols_text.append(alloc, ',');
            var nb: [24]u8 = undefined;
            const nt = try std.fmt.bufPrint(&nb, "{d}", .{ci});
            try cols_text.appendSlice(alloc, nt);
        }
        const line = try alloc.print("#idx {s} {s}\n", .{ ix.name, cols_text.items });
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    const path = try alloc.print("{s}/schema.txt", .{table_path});
    defer alloc.free(path);
    try writeText(io, dir, path, out.items);
}

/// 解析中途的索引行：列号列表要自己持有（`Schema` 还没建好，没法调 `addIndex`）。
const PendingIdx = struct {
    name: []const u8,
    cols: std.ArrayList(usize),
};

pub fn loadSchema(io: std.Io, dir: std.Io.Dir, table_path: []const u8, alloc: std.mem.Allocator) !schema_mod.Schema {
    const path = try alloc.print("{s}/schema.txt", .{table_path});
    defer alloc.free(path);
    const text = try readWholeFile(io, dir, path, alloc);
    defer alloc.free(text);

    var it = std.mem.splitScalar(u8, text, '\n');
    const ver = std.mem.trim(u8, it.next() orelse return error.BadCatalog, " \r\t");
    if (!std.mem.eql(u8, ver, "v1")) return error.BadCatalog;
    const tname = std.mem.trim(u8, it.next() orelse return error.BadCatalog, " \r\t");

    var cols: std.ArrayList(schema_mod.Column) = .empty;
    defer cols.deinit(alloc);
    var idxs: std.ArrayList(PendingIdx) = .empty;
    defer {
        for (idxs.items) |*p| p.cols.deinit(alloc);
        idxs.deinit(alloc);
    }
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#idx ")) {
            var tok = std.mem.tokenizeScalar(u8, line[5..], ' ');
            const iname = tok.next() orelse return error.BadCatalog;
            const icols = tok.next() orelse return error.BadCatalog;
            var icols_list: std.ArrayList(usize) = .empty;
            errdefer icols_list.deinit(alloc);
            var cit = std.mem.splitScalar(u8, icols, ',');
            while (cit.next()) |one| {
                if (one.len == 0) return error.BadCatalog;
                const ci = std.fmt.parseInt(usize, one, 10) catch return error.BadCatalog;
                try icols_list.append(alloc, ci);
            }
            if (icols_list.items.len == 0) return error.BadCatalog;
            // 名字先借 text 的切片，等 Schema.init 之后再统一 dupe 进 Schema
            try idxs.append(alloc, .{ .name = iname, .cols = icols_list });
            continue;
        }
        var tok = std.mem.tokenizeScalar(u8, line, ' ');
        const cname = tok.next() orelse return error.BadCatalog;
        const ctype = tok.next() orelse return error.BadCatalog;
        const pk = tok.next() orelse "0";
        const nn = tok.next() orelse "0";
        const ai = tok.next() orelse "0";
        const ct = std.meta.stringToEnum(sql.ColumnType, ctype) orelse return error.BadCatalog;
        try cols.append(alloc, .{
            .name = cname,
            .col_type = ct,
            .primary_key = std.mem.eql(u8, pk, "1"),
            .not_null = std.mem.eql(u8, nn, "1"),
            .auto_increment = std.mem.eql(u8, ai, "1"),
        });
    }
    var sch = try schema_mod.Schema.init(alloc, tname, cols.items);
    errdefer sch.deinit(alloc);
    for (idxs.items) |ix| {
        for (ix.cols.items) |ci| {
            if (ci >= sch.columns.len) return error.BadCatalog;
        }
        // addIndex 内部会 dupe 名字与列号：这里传的是 text 的借用，函数返回前 text 就释放了。
        // **除了 OOM，其余错误都意味着目录文件坏了**（如重复列/非法列号）：
        // 不能把 `InvalidIdentifier` 这种内部错误名泄给上层，否则运维看到的报错与
        // 「catalog 损坏」这个事实对不上。
        _ = sch.addIndex(alloc, ix.name, ix.cols.items) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return error.BadCatalog,
        };
    }
    return sch;
}

/// 数据库根目录的表清单：`v1` + 每行一个表名。
pub fn saveCatalog(io: std.Io, dir: std.Io.Dir, root: []const u8, names: []const []const u8, alloc: std.mem.Allocator) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "v1\n");
    for (names) |n| {
        try out.appendSlice(alloc, n);
        try out.append(alloc, '\n');
    }
    const path = try alloc.print("{s}/tables.txt", .{root});
    defer alloc.free(path);
    try writeText(io, dir, path, out.items);
}

pub fn loadCatalog(io: std.Io, dir: std.Io.Dir, root: []const u8, alloc: std.mem.Allocator) ![][]u8 {
    const path = try alloc.print("{s}/tables.txt", .{root});
    defer alloc.free(path);
    const text = try readWholeFile(io, dir, path, alloc);
    defer alloc.free(text);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    const first = std.mem.trim(u8, it.next() orelse "", " \r\t");
    if (first.len > 0 and std.mem.eql(u8, first, "v1")) {
        while (it.next()) |raw| {
            const n = std.mem.trim(u8, raw, " \r\t");
            if (n.len == 0) continue;
            // 分两步：写在内层会让 append 失败时丢掉刚 dupe 的内存
            const owned = try alloc.dupe(u8, n);
            errdefer alloc.free(owned);
            try names.append(alloc, owned);
        }
    }
    return names.toOwnedSlice(alloc);
}

pub fn freeCatalog(alloc: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

test "schema save/load roundtrip" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-catalog-tmp";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true, .auto_increment = true },
        .{ .name = "name", .col_type = .text, .not_null = true },
    };
    var s = try schema_mod.Schema.init(alloc, "users", &cols);
    defer s.deinit(alloc);
    try saveSchema(io, dir, tmp, &s, alloc);

    var loaded = try loadSchema(io, dir, tmp, alloc);
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("users", loaded.name);
    try std.testing.expectEqual(@as(usize, 2), loaded.columns.len);
    try std.testing.expect(loaded.columns[0].primary_key);
    try std.testing.expect(loaded.columns[0].auto_increment);
    try std.testing.expect(loaded.columns[1].not_null);
    try std.testing.expectEqual(sql.ColumnType.text, loaded.columns[1].col_type);
}

test "catalog：索引行坏掉时必须报 BadCatalog（不是内部错误名、更不是默默少一个索引）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-catalog-bad-idx";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);

    const head = "v1\nt\nid integer 1 1 0\ng integer 0 1 0\n";
    // 四种坏法：列号列表为空、尾逗号、重复列、越界列号
    const bad = [_][]const u8{
        "#idx x \n",
        "#idx x 1,\n",
        "#idx x 1,1\n",
        "#idx x 0,9\n",
    };
    for (bad) |line| {
        const text = try std.fmt.allocPrint(alloc, "{s}{s}", .{ head, line });
        defer alloc.free(text);
        try writeText(io, dir, tmp ++ "/schema.txt", text);
        try std.testing.expectError(error.BadCatalog, loadSchema(io, dir, tmp, alloc));
    }

    // 对照：合法格式必须读得回来 —— ① 旧的单列写法（只有列号，没有逗号）
    {
        try writeText(io, dir, tmp ++ "/schema.txt", head ++ "#idx x 1\n");
        var s1 = try loadSchema(io, dir, tmp, alloc);
        defer s1.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), s1.indexes[0].columns.len);
        try std.testing.expectEqual(@as(usize, 1), s1.indexes[0].columns[0]);
    }
    // ② 新的多列写法（顺序必须原样保留：(1,0) 不能变成 (0,1)）
    {
        try writeText(io, dir, tmp ++ "/schema.txt", head ++ "#idx x 1,0\n");
        var s2 = try loadSchema(io, dir, tmp, alloc);
        defer s2.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), s2.indexes[0].columns.len);
        try std.testing.expectEqual(@as(usize, 1), s2.indexes[0].columns[0]);
        try std.testing.expectEqual(@as(usize, 0), s2.indexes[0].columns[1]);
    }
}

test "catalog save/load roundtrip" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-catalog-list";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);

    try saveCatalog(io, dir, tmp, &.{ "users", "orders" }, alloc);
    const names = try loadCatalog(io, dir, tmp, alloc);
    defer freeCatalog(alloc, names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("users", names[0]);
    try std.testing.expectEqualStrings("orders", names[1]);
}
