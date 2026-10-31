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
    const path = try alloc.print("{s}/schema.txt", .{table_path});
    defer alloc.free(path);
    try writeText(io, dir, path, out.items);
}

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
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
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
    return schema_mod.Schema.init(alloc, tname, cols.items);
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
            try names.append(alloc, try alloc.dupe(u8, n));
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
