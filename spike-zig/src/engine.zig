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
    /// 索引名 → 索引表。每个索引是一张**独立 LSM 表**（`{表}/idx/{索引名}`）：
    /// 白得 WAL、段、崩溃恢复、后台合并，不用另写一套持久化。
    idx_tables: std.StringHashMap(tablemod.Table),
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

/// 把基础表全部行灌进索引表（`CREATE INDEX` 回填，以及崩溃后重建）。
///
/// `pub` 是为了让基准/工具能直接建索引而不必绕过 `Engine`：
/// 生产路径一律走 `Engine.createIndex`（它会先落 `.building` 标记再调这里）。
pub fn fillIndex(
    alloc: std.mem.Allocator,
    it: *tablemod.Table,
    s: *const schema_mod.Schema,
    base: *tablemod.Table,
    ix: schema_mod.IndexDef,
) !void {
    var hi: [16]u8 = @splat(0xFF);
    var vals: std.ArrayList([]const u8) = .empty;
    defer vals.deinit(alloc);
    try base.scanValues(&[_]u8{}, &hi, &vals);

    const row_vals = try alloc.alloc(sql.Value, s.columns.len);
    defer alloc.free(row_vals);
    for (vals.items) |raw| {
        try s.decodeRowInto(row_vals, raw);
        const v = row_vals[ix.column_idx];
        switch (v) {
            .null => continue, // NULL 不入索引
            else => {},
        }
        const key = try s.encodeIndexKey(alloc, ix.column_idx, v, row_vals[s.pk_index]);
        defer alloc.free(key);
        try it.put(key, &[_]u8{});
    }
    try it.flush();
}

/// 打开（必要时新建并回填）一张索引表。
///
/// **可信判据是「写完才置位」的 `.ready` 标记，不是「目录存在」。**
/// 建索引期间目录就已经存在了（要先 `createDirPath` 才能放标记），如果拿「目录存在」
/// 当判据，那么「崩在回填之前/回填中途」留下的空目录或半成品会被当成好索引直接用，
/// 结果就是**静默漏行** —— 比多花一次重建昂贵得多。
///
/// 所以顺序固定为：删旧 → 建目录 → 回填 → flush → 写 `.ready`。
/// 任何时刻崩掉，下次打开看到的都是「没有 `.ready`」→ 整个重建。
fn openOrBuildIndex(
    io: std.Io,
    dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    opts: Options,
    table_path: []const u8,
    s: *const schema_mod.Schema,
    base: *tablemod.Table,
    ix: schema_mod.IndexDef,
) !tablemod.Table {
    const idx_path = try alloc.print("{s}/idx/{s}", .{ table_path, ix.name });
    defer alloc.free(idx_path);
    const ready = try alloc.print("{s}/.ready", .{idx_path});
    defer alloc.free(ready);

    var ready_present = true;
    if (dir.openFile(io, ready, .{})) |f| {
        f.close(io);
    } else |_| {
        ready_present = false;
    }

    if (!ready_present) {
        // 旧目录（崩掉的半成品 / 空目录）一律推倒重来
        dir.deleteTree(io, idx_path) catch {};
        try dir.createDirPath(io, idx_path);

        var it = try tablemod.Table.open(io, dir, idx_path, alloc, opts.table);
        errdefer it.deinit();
        try fillIndex(alloc, &it, s, base, ix);
        {
            var mf = try dir.createFile(io, ready, .{});
            mf.close(io);
        }
        return it;
    }
    return tablemod.Table.open(io, dir, idx_path, alloc, opts.table);
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
                var ie = e.value_ptr.idx_tables.iterator();
                while (ie.next()) |x| x.value_ptr.deinit();
                e.value_ptr.idx_tables.deinit();
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
            var tbl = try tablemod.Table.open(io, dir, path, alloc, opts.table);

            var idx_tables = std.StringHashMap(tablemod.Table).init(alloc);
            errdefer {
                var ie = idx_tables.iterator();
                while (ie.next()) |x| x.value_ptr.deinit();
                idx_tables.deinit();
            }
            for (sch.indexes) |ix| {
                const itbl = try openOrBuildIndex(io, dir, alloc, opts, path, &sch, &tbl, ix);
                const ikey = try alloc.dupe(u8, ix.name);
                errdefer alloc.free(ikey);
                try idx_tables.put(ikey, itbl);
            }

            // 分两步：写在内层会让 put 失败时丢掉刚 dupe 的 name
            const key = try alloc.dupe(u8, name);
            errdefer alloc.free(key);
            try tables.put(key, .{ .schema = sch, .table = tbl, .idx_tables = idx_tables });
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
            var ie = e.value_ptr.idx_tables.iterator();
            while (ie.next()) |x| {
                x.value_ptr.deinit();
                self.alloc.free(x.key_ptr.*);
            }
            e.value_ptr.idx_tables.deinit();
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
        try self.tables.put(key, .{
            .schema = sch,
            .table = tbl,
            .idx_tables = std.StringHashMap(tablemod.Table).init(self.alloc),
        });
        try self.saveCatalog();
        return true;
    }

    pub fn execute(self: *Engine, stmt: sql.Statement, alloc: std.mem.Allocator) !Result {
        switch (stmt) {
            .create_table => |def| return .{ .created = try self.createTable(def) },
            .create_index => |def| return .{ .created = try self.createIndex(def) },
            .insert => |ins| {
                const e = self.tables.getPtr(ins.table) orelse return error.TableNotFound;
                var host = exec.IndexHost{ .schema = &e.schema, .tables = &e.idx_tables };
                return .{ .inserted = try exec.insertRowsHost(&e.table, &e.schema, ins, alloc, &host) };
            },
            .select => |sel| {
                const e = self.tables.getPtr(sel.table) orelse return error.TableNotFound;
                var host = exec.IndexHost{ .schema = &e.schema, .tables = &e.idx_tables };
                return .{ .rows = try exec.selectRowsHost(&e.table, &e.schema, sel, alloc, &host) };
            },
            .update => |upd| {
                const e = self.tables.getPtr(upd.table) orelse return error.TableNotFound;
                var host = exec.IndexHost{ .schema = &e.schema, .tables = &e.idx_tables };
                return .{ .updated = try exec.updateRowsHost(&e.table, &e.schema, upd, alloc, &host) };
            },
            .delete => |del| {
                const e = self.tables.getPtr(del.table) orelse return error.TableNotFound;
                var host = exec.IndexHost{ .schema = &e.schema, .tables = &e.idx_tables };
                return .{ .deleted = try exec.deleteRowsHost(&e.table, &e.schema, del, alloc, &host) };
            },
        }
    }

    /// `CREATE INDEX name ON table (col)`。返回是否真的新建（`if_not_exists` 命中时 false）。
    ///
    /// 建索引顺序：**先建表并回填、后写 schema** —— 两者之间崩溃时 schema 里没有这个索引，
    /// 于是它不会被任何查询使用（脏目录顶多是垃圾），不会出现“索引缺条目 → 漏行”。
    pub fn createIndex(self: *Engine, def: sql.CreateIndex) !bool {
        const e = self.tables.getPtr(def.table) orelse return error.TableNotFound;
        if (e.schema.findIndex(def.name) != null) {
            if (def.if_not_exists) return false;
            return error.IndexExists;
        }
        const ci = e.schema.indexOf(def.column) orelse return error.ColumnNotFound;

        const path = try self.alloc.print("{s}/{s}", .{ self.root, def.table });
        defer self.alloc.free(path);

        var itbl = try openOrBuildIndex(
            self.io,
            self.dir,
            self.alloc,
            self.opts,
            path,
            &e.schema,
            &e.table,
            .{ .name = def.name, .column_idx = ci },
        );
        errdefer itbl.deinit();

        const name_copy = try self.alloc.dupe(u8, def.name);
        errdefer self.alloc.free(name_copy);
        try e.idx_tables.put(name_copy, itbl);

        _ = try e.schema.addIndex(self.alloc, def.name, ci);
        try catalog.saveSchema(self.io, self.dir, path, &e.schema, self.alloc);
        return true;
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

test "二级索引：建索引回填 + 等值查询走索引（结果是全扫的同一批）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-idx";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    {
        var p = try sql.parse(alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER, v TEXT)");
        defer p.deinit();
        _ = try eng.execute(p.stmt, alloc);
    }
    {
        // 100 行，g = id % 10
        var i: i64 = 0;
        while (i < 100) : (i += 1) {
            const text = try alloc.print("INSERT INTO t (id, g, v) VALUES ({d}, {d}, 'x')", .{ i, @mod(i, 10) });
            defer alloc.free(text);
            var p = try sql.parse(alloc, text);
            defer p.deinit();
            _ = try eng.execute(p.stmt, alloc);
        }
    }

    // 建索引前的基准：全扫
    var before: std.ArrayList(i64) = .empty;
    defer before.deinit(alloc);
    {
        const e = eng.get("t").?;
        e.table.scan_rows_read = 0;
        var p = try sql.parse(alloc, "SELECT id FROM t WHERE g = 3 ORDER BY id");
        defer p.deinit();
        const res = try eng.execute(p.stmt, alloc);
        var rows = res.rows;
        defer rows.deinit();
        for (rows.rows) |r| try before.append(alloc, r[0].integer);
        try std.testing.expectEqual(@as(usize, 10), before.items.len);
        try std.testing.expect(e.table.scan_rows_read >= 100); // 确实全扫了
    }

    // 建索引（回填已有 100 行）
    {
        var p = try sql.parse(alloc, "CREATE INDEX idx_g ON t (g)");
        defer p.deinit();
        const r = try eng.execute(p.stmt, alloc);
        try std.testing.expect(r.created);
        try std.testing.expectEqual(@as(usize, 1), eng.get("t").?.schema.indexes.len);
    }

    // 同样的查询：结果必须一模一样，而且**不再扫全表**
    {
        const e = eng.get("t").?;
        e.table.scan_rows_read = 0;
        var p = try sql.parse(alloc, "SELECT id FROM t WHERE g = 3 ORDER BY id");
        defer p.deinit();
        const res = try eng.execute(p.stmt, alloc);
        var rows = res.rows;
        defer rows.deinit();
        try std.testing.expectEqual(before.items.len, rows.rows.len);
        for (rows.rows, before.items) |r, want| try std.testing.expectEqual(want, r[0].integer);
        // 索引路径：主表零扫描（0 行被 count 到，因为只做了点查）
        try std.testing.expectEqual(@as(u64, 0), e.table.scan_rows_read);
    }
}

test "二级索引：插入/更新/删除都维护索引，且脏项被回表复核挡住" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-idx-maint";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER)");
    try run(&eng, alloc, "CREATE INDEX idx_g ON t (g)");

    // 建索引之后插入的行也要进索引
    try run(&eng, alloc, "INSERT INTO t (id, g) VALUES (1, 7), (2, 7), (3, 8)");
    try expectIds(&eng, alloc, 7, &.{ 1, 2 });
    try expectIds(&eng, alloc, 8, &.{3});

    // 更新索引列：旧值查不到、新值查得到
    try run(&eng, alloc, "UPDATE t SET g = 9 WHERE id = 1");
    try expectIds(&eng, alloc, 7, &.{2});
    try expectIds(&eng, alloc, 9, &.{1});

    // 更新主键（索引列不变）：索引键里带着主键，所以旧键必须换掉；旧行已不存在，
    // 就算换不掉也会被回表复核挡下 —— 但查询结果得是「这一行的新主键」。
    try run(&eng, alloc, "UPDATE t SET id = 10 WHERE id = 2");
    try expectIds(&eng, alloc, 7, &.{10});
    try expectIds(&eng, alloc, 9, &.{1});

    // 删除：索引项也要没
    try run(&eng, alloc, "DELETE FROM t WHERE id = 1");
    try expectIds(&eng, alloc, 9, &.{});

    // **脏项测试**：手工往索引里塞一条指向不存在行的条目，查询必须仍然正确
    {
        const e = eng.get("t").?;
        const itbl = e.idx_tables.getPtr("idx_g").?;
        const bogus = try e.schema.encodeIndexKey(alloc, 1, .{ .integer = 99 }, .{ .integer = 12345 });
        defer alloc.free(bogus);
        try itbl.put(bogus, &[_]u8{});
        try itbl.flush();
    }
    try expectIds(&eng, alloc, 99, &.{}); // 行不存在 → 跳过，不报错、也不错
}

test "二级索引：关闭重开后仍走索引；崩在回填中途会重建而不是用半成品" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-idx-reopen";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    {
        var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
        defer eng.deinit();
        try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER)");
        try run(&eng, alloc, "INSERT INTO t (id, g) VALUES (1, 5), (2, 5), (3, 6)");
        try run(&eng, alloc, "CREATE INDEX idx_g ON t (g)");
        try expectIds(&eng, alloc, 5, &.{ 1, 2 });
    }

    // 正常重开：schema 里的 #idx 让索引表被重新挂上
    {
        var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
        defer eng.deinit();
        try std.testing.expectEqual(@as(usize, 1), eng.get("t").?.schema.indexes.len);
        const e = eng.get("t").?;
        e.table.scan_rows_read = 0;
        try expectIds(&eng, alloc, 5, &.{ 1, 2 });
        try std.testing.expectEqual(@as(u64, 0), e.table.scan_rows_read);
    }

    // 模拟「回填到一半崩了」：目录与已写条目都在，只差最后一步 `.ready` 没写。
    // （旧实现拿「目录存在」当判据，这种状态会被直接当成好索引用 → 静默漏行。）
    {
        const ready = root ++ "/t/idx/idx_g/.ready";
        try dir.deleteFile(io, ready);
    }
    {
        // 重开时必须重建（否则半成品索引会漏行）：重建后结果仍正确
        var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
        defer eng.deinit();
        try expectIds(&eng, alloc, 5, &.{ 1, 2 });
        try expectIds(&eng, alloc, 6, &.{3});
        // 重建完成后 `.ready` 必须重新写上（否则下次又要白重建一次）
        const ready = root ++ "/t/idx/idx_g/.ready";
        if (dir.openFile(io, ready, .{})) |f| f.close(io) else |_| return error.TestExpectedReadyMarker;
    }
}

fn run(eng: *Engine, alloc: std.mem.Allocator, text: []const u8) !void {
    var p = try sql.parse(alloc, text);
    defer p.deinit();
    var res = try eng.execute(p.stmt, alloc);
    switch (res) {
        .rows => |*r| r.deinit(),
        else => {},
    }
}

fn expectIds(eng: *Engine, alloc: std.mem.Allocator, g: i64, want: []const i64) !void {
    const text = try alloc.print("SELECT id FROM t WHERE g = {d} ORDER BY id", .{g});
    defer alloc.free(text);
    var p = try sql.parse(alloc, text);
    defer p.deinit();
    const res = try eng.execute(p.stmt, alloc);
    var rows = res.rows;
    defer rows.deinit();
    try std.testing.expectEqual(want.len, rows.rows.len);
    for (rows.rows, want) |r, w| try std.testing.expectEqual(w, r[0].integer);
}
