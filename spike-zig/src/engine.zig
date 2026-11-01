// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const sql = @import("sql.zig");
const schema_mod = @import("schema.zig");
const tablemod = @import("table.zig");
const exec = @import("exec.zig");
const catalog = @import("catalog.zig");

pub const Options = struct {
    table: tablemod.Options = .{},
};

pub const Entry = struct {
    schema: schema_mod.Schema,
    table: tablemod.Table,
};

pub const Result = union(enum) {
    created: bool,
    inserted: usize,
    updated: usize,
    deleted: usize,
    rows: exec.Rows,
};

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// 数据库引擎：根目录 = 一个数据库，每表一个子目录。
pub const Engine = struct {
    io: std.Io,
    dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    root: []u8,
    opts: Options,
    tables: std.StringHashMap(Entry),

    pub fn open(io: std.Io, dir: std.Io.Dir, root: []const u8, alloc: std.mem.Allocator, opts: Options) !Engine {
        try dir.createDirPath(io, root);
        const root_copy = try alloc.dupe(u8, root);
        errdefer alloc.free(root_copy);

        var tables = std.StringHashMap(Entry).init(alloc);
        errdefer {
            var it = tables.iterator();
            while (it.next()) |e| {
                e.value_ptr.table.deinit();
                e.value_ptr.schema.deinit(alloc);
            }
            tables.deinit();
        }

        const names = try catalog.loadCatalog(io, dir, root, alloc);
        defer catalog.freeCatalog(alloc, names);
        for (names) |name| {
            const path = try alloc.print("{s}/{s}", .{ root, name });
            defer alloc.free(path);
            var sch = try catalog.loadSchema(io, dir, path, alloc);
            errdefer sch.deinit(alloc);
            const tbl = try tablemod.Table.open(io, dir, path, alloc, opts.table);
            // 分两步：写在内层会让 put 失败时丢掉刚 dupe 的 name
            const key = try alloc.dupe(u8, name);
            errdefer alloc.free(key);
            try tables.put(key, .{ .schema = sch, .table = tbl });
        }

        return .{
            .io = io,
            .dir = dir,
            .alloc = alloc,
            .root = root_copy,
            .opts = opts,
            .tables = tables,
        };
    }

    pub fn deinit(self: *Engine) void {
        var it = self.tables.iterator();
        while (it.next()) |e| {
            e.value_ptr.table.deinit();
            e.value_ptr.schema.deinit(self.alloc);
            self.alloc.free(e.key_ptr.*);
        }
        self.tables.deinit();
        self.alloc.free(self.root);
        self.* = undefined;
    }

    pub fn get(self: *Engine, name: []const u8) ?*Entry {
        return self.tables.getPtr(name);
    }

    fn saveCatalog(self: *Engine) !void {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.alloc);
        var it = self.tables.iterator();
        while (it.next()) |e| try names.append(self.alloc, e.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, lessStr);
        try catalog.saveCatalog(self.io, self.dir, self.root, names.items, self.alloc);
    }

    /// 建表；`if_not_exists` 已存在时返回 false。
    pub fn createTable(self: *Engine, def: sql.CreateTable) !bool {
        if (self.tables.getPtr(def.name) != null) {
            if (def.if_not_exists) return false;
            return error.TableExists;
        }

        const cols = try self.alloc.alloc(schema_mod.Column, def.columns.len);
        defer self.alloc.free(cols);
        for (def.columns, 0..) |c, i| {
            cols[i] = .{
                .name = c.name,
                .col_type = c.col_type,
                .primary_key = c.primary_key,
                .auto_increment = c.auto_increment,
                .not_null = c.not_null,
            };
        }
        var sch = try schema_mod.Schema.init(self.alloc, def.name, cols);
        errdefer sch.deinit(self.alloc);

        const path = try self.alloc.print("{s}/{s}", .{ self.root, def.name });
        defer self.alloc.free(path);
        try self.dir.createDirPath(self.io, path);
        try catalog.saveSchema(self.io, self.dir, path, &sch, self.alloc);

        const tbl = try tablemod.Table.open(self.io, self.dir, path, self.alloc, self.opts.table);
        // 分两步：写在内层会让 put 失败时丢掉刚 dupe 的 name
        const key = try self.alloc.dupe(u8, def.name);
        errdefer self.alloc.free(key);
        try self.tables.put(key, .{ .schema = sch, .table = tbl });
        try self.saveCatalog();
        return true;
    }

    pub fn execute(self: *Engine, stmt: sql.Statement, alloc: std.mem.Allocator) !Result {
        switch (stmt) {
            .create_table => |def| return .{ .created = try self.createTable(def) },
            .insert => |ins| {
                const e = self.tables.getPtr(ins.table) orelse return error.TableNotFound;
                return .{ .inserted = try exec.insertRows(&e.table, &e.schema, ins, alloc) };
            },
            .select => |sel| {
                const e = self.tables.getPtr(sel.table) orelse return error.TableNotFound;
                return .{ .rows = try exec.selectRows(&e.table, &e.schema, sel, alloc) };
            },
            .update => |upd| {
                const e = self.tables.getPtr(upd.table) orelse return error.TableNotFound;
                return .{ .updated = try exec.updateRows(&e.table, &e.schema, upd, alloc) };
            },
            .delete => |del| {
                const e = self.tables.getPtr(del.table) orelse return error.TableNotFound;
                return .{ .deleted = try exec.deleteRows(&e.table, &e.schema, del, alloc) };
            },
        }
    }
};

test "engine create/insert/reopen/update/delete" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-db";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    {
        var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
        defer eng.deinit();

        var p = try sql.parse(alloc, "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");
        defer p.deinit();
        const created = try eng.execute(p.stmt, alloc);
        try std.testing.expectEqual(true, created.created);

        var q = try sql.parse(alloc, "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30), (2, 'Bob', 25)");
        defer q.deinit();
        const ins = try eng.execute(q.stmt, alloc);
        try std.testing.expectEqual(@as(usize, 2), ins.inserted);
    }

    {
        var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
        defer eng.deinit();

        var p = try sql.parse(alloc, "SELECT id, age FROM users ORDER BY id");
        defer p.deinit();
        const res = try eng.execute(p.stmt, alloc);
        var rows = res.rows;
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 30), rows.rows[0][1].integer);
    }

    {
        var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
        defer eng.deinit();

        var p = try sql.parse(alloc, "UPDATE users SET age = 40 WHERE id = 1");
        defer p.deinit();
        const upd = try eng.execute(p.stmt, alloc);
        try std.testing.expectEqual(@as(usize, 1), upd.updated);

        var q = try sql.parse(alloc, "DELETE FROM users WHERE age < 28");
        defer q.deinit();
        const del = try eng.execute(q.stmt, alloc);
        try std.testing.expectEqual(@as(usize, 1), del.deleted);

        var r = try sql.parse(alloc, "SELECT id FROM users ORDER BY id");
        defer r.deinit();
        const res = try eng.execute(r.stmt, alloc);
        var rows = res.rows;
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
    }
}

test "engine 全链路：CREATE/INSERT 后 GROUP BY + HAVING + ORDER BY 聚合" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-agg";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    {
        var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
        defer eng.deinit();

        {
            var p = try sql.parse(alloc, "CREATE TABLE sales (id INTEGER PRIMARY KEY, city TEXT, amount INTEGER)");
            defer p.deinit();
            _ = try eng.execute(p.stmt, alloc);
        }
        {
            // 北京 2 笔共 300；上海 1 笔 50；广州 3 笔共 60
            var p = try sql.parse(alloc,
                "INSERT INTO sales (id, city, amount) VALUES " ++
                    "(1,'bj',100), (2,'bj',200), (3,'sh',50), (4,'gz',10), (5,'gz',20), (6,'gz',30)");
            defer p.deinit();
            const ins = try eng.execute(p.stmt, alloc);
            try std.testing.expectEqual(@as(usize, 6), ins.inserted);
        }
    }

    // 关闭后从磁盘重开：证明聚合依赖的 schema/catalog 落盘是对的
    var eng2 = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng2.deinit();

    {
        var p = try sql.parse(alloc,
            "SELECT city, COUNT(*), SUM(amount) FROM sales GROUP BY city HAVING SUM(amount) >= 100 ORDER BY sum(amount) DESC");
        defer p.deinit();
        const res = try eng2.execute(p.stmt, alloc);
        var rows = res.rows;
        defer rows.deinit();

        try std.testing.expectEqual(@as(usize, 1), rows.rows.len); // 只有 bj(300) 达到 100
        try std.testing.expectEqualStrings("bj", rows.rows[0][0].text);
        try std.testing.expectEqual(@as(i64, 2), rows.rows[0][1].integer);
        try std.testing.expectEqual(@as(i64, 300), rows.rows[0][2].integer);
        try std.testing.expectEqualStrings("city", rows.columns[0]);
        try std.testing.expectEqualStrings("count(*)", rows.columns[1]);
        try std.testing.expectEqualStrings("sum(amount)", rows.columns[2]);
    }

    // 放宽 HAVING 后三座城市都在，按金额降序（bj 300 / gz 60 / sh 50）
    {
        var p = try sql.parse(alloc,
            "SELECT city, SUM(amount) FROM sales GROUP BY city HAVING SUM(amount) > 0 ORDER BY sum(amount) DESC");
        defer p.deinit();
        const res = try eng2.execute(p.stmt, alloc);
        var rows = res.rows;
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
        try std.testing.expectEqualStrings("bj", rows.rows[0][0].text);
        try std.testing.expectEqualStrings("gz", rows.rows[1][0].text);
        try std.testing.expectEqualStrings("sh", rows.rows[2][0].text);
    }
}
