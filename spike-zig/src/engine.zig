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
    dropped: bool,
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
///
/// **三步：流式扫表 → 排序 → 一次写成段**（对齐 SQLite `CREATE INDEX` 与
/// RocksDB 批量装载的形状）。旧实现是「先 `scanValues` 把整表原始行抄进内存，
/// 再逐行 `put`」，两个问题：
/// 1. 逐行 `put` = 每行一次 WAL 编码 + 一次跳表插入，实测索引构建只有 SQLite 的 0.633×；
/// 2. `scanValues` 把整表值抄一份，1 亿行时是 3.9 GB —— 建索引会直接把内存打爆。
/// 现在只保留「索引键」（~20 B/行）并用 arena 一次性分配，排序后直接喂 `bulkLoadSorted`。
/// 索引回填的三阶段耗时（纳秒）。**不是性能指标本身**，是用来回答
/// 「索引建得慢」到底慢在哪一步（扫表解码 / 排序 / 写段）的证据。
pub const FillPhases = struct {
    scan_ns: u64 = 0,
    sort_ns: u64 = 0,
    write_ns: u64 = 0,
    rows: usize = 0,
};

fn monoNs(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

/// 排序元素：`key` 的前 8 字节另外存一份（`pre`）。
///
/// 为什么要多存 8 字节：索引键 = 「值分量 ++ 主键分量」，而数值型值分量是
/// **8 字节大端定长、顺序保持**的（见 `schema.appendValueComponent`），
/// 所以绝大多数比较在 `pre` 上就能分出胜负 —— 不用去解引用两个散落在 arena 里的
/// key 切片（那才是 1M 条排序里 20M 次比较真正的开销）。
/// `pre` 相等时才回退到全键比较，所以对任意 key（含 text/blob）都是正确的。
const KeyItem = struct {
    pre: u64,
    key: []const u8,
};

/// key 的前 8 字节左对齐大端值（不足 8 字节用 0 填充）。
/// 零填充只是为了让「前缀相同」时 `pre` 相等并回到全键比较，不影响正确性。
fn prefix8(k: []const u8) u64 {
    var b: [8]u8 = @splat(0);
    const n = @min(k.len, 8);
    @memcpy(b[0..n], k[0..n]);
    return std.mem.readInt(u64, &b, .big);
}

fn keyItemLess(_: void, a: KeyItem, b: KeyItem) bool {
    if (a.pre != b.pre) return a.pre < b.pre;
    return std.mem.order(u8, a.key, b.key) == .lt;
}

pub fn fillIndex(
    alloc: std.mem.Allocator,
    it: *tablemod.Table,
    s: *const schema_mod.Schema,
    base: *tablemod.Table,
    ix: schema_mod.IndexDef,
) !void {
    var ph = FillPhases{};
    try fillIndexTimed(alloc, it, s, base, ix, &ph);
}

pub fn fillIndexTimed(
    alloc: std.mem.Allocator,
    it: *tablemod.Table,
    s: *const schema_mod.Schema,
    base: *tablemod.Table,
    ix: schema_mod.IndexDef,
    ph: *FillPhases,
) !void {
    try fillIndexTimedChunks(alloc, it, s, base, ix, ph, FILL_CHUNK_ROWS);
}

/// 每块行数：排序必须在内存里（`Writer` 要求 key 升序），每行约 64 B
///（24 B 排序元素 + 24 B 临时缓冲 + ~16 B 键），1 亿行就是 6.4 GB —— 不分块等于
/// 「大表建不了索引」。4M 行/块 ≈ 256 MB 上界。
const FILL_CHUNK_ROWS: usize = 4 << 20;

pub fn fillIndexTimedChunks(
    alloc: std.mem.Allocator,
    it: *tablemod.Table,
    s: *const schema_mod.Schema,
    base: *tablemod.Table,
    ix: schema_mod.IndexDef,
    ph: *FillPhases,
    chunk_rows: usize,
) !void {
    const io = base.io;
    const t_scan = monoNs(io);

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(alloc);

    // **只解码「索引列 + 主键」两列**（对齐 SQLite `OP_Column` 的惰性取值）：
    // `decodeRowInto` 会把整行所有列都解出来，而我们只需要这两个；
    // `decodeRowProjected` 对其余列只读长度 varint、不碰内容。
    var want: [2]usize = undefined;
    var want_len: usize = 2;
    if (ix.column_idx == s.pk_index) {
        want[0] = ix.column_idx;
        want_len = 1;
    } else if (ix.column_idx < s.pk_index) {
        want[0] = ix.column_idx;
        want[1] = s.pk_index;
    } else {
        want[0] = s.pk_index;
        want[1] = ix.column_idx;
    }
    const col_pos: usize = if (want[0] == ix.column_idx) 0 else 1;
    const pk_pos: usize = if (want[0] == s.pk_index) 0 else 1;

    const row_vals = try alloc.alloc(sql.Value, want_len);
    defer alloc.free(row_vals);

    // 索引列是数值型时，键的前 8 字节就是完整的值分量（见 `schema.writeFixedComponent`），
    // 于是「按前 8 字节稳定排序」= 完全正确且不需要全键比较（主键部分天然已升序）。
    const numeric_col = switch (s.columns[ix.column_idx].col_type) {
        .integer, .bigint, .datetime, .real, .double => true,
        else => false,
    };

    // **分块**：排序必须在内存里（`Writer` 要求 key 升序），每行约 64 B，
    // 1 亿行就是 6.4 GB。每块独立排序后各写一个段，最后 `compact()` 合并成一个；
    // 代价只在超过一块时多一次读写，换来 O(块) 的内存上界。
    const CHUNK_ROWS: usize = @max(1, chunk_rows);
    var chunk_arena: ?std.heap.ArenaAllocator = null;
    defer if (chunk_arena) |*a| a.deinit();
    var items_buf: []KeyItem = &.{};
    defer if (items_buf.len > 0) alloc.free(items_buf);
    var scratch_buf: []KeyItem = &.{};
    defer if (scratch_buf.len > 0) alloc.free(scratch_buf);
    var chunks: usize = 0;
    var emit_ns: u64 = 0;

    // 1) 流式扫基础表（`MergeIter` 已跳过墓碑，不需要 `scanValues` 那层拷贝）
    var hi: [16]u8 = @splat(0xFF);
    var cur = tablemod.MergeIter{};
    try cur.init(base, &[_]u8{}, &hi);
    defer cur.deinit();
    while (cur.next()) |rec| {
        // arena 按块重建：键只在各自块内被排序/写出，写完就能整体释放
        if (chunk_arena == null) chunk_arena = std.heap.ArenaAllocator.init(alloc);
        const aa = chunk_arena.?.allocator();
        try s.decodeRowProjected(row_vals, want[0..want_len], rec.value);
        const v = row_vals[col_pos];
        switch (v) {
            .null => continue, // NULL 不入索引
            else => {},
        }
        const pk = row_vals[if (want_len == 1) 0 else pk_pos];
        // 数值 + 数值：键恰好 16 字节定长，直接在栈上拼（省掉 encodeIndexKey 里
        // 两次 ArrayList 分配/拼接）；其余情形走通用编码。
        var fixed: [16]u8 = undefined;
        const key: []const u8 = if (@import("schema.zig").writeFixedComponent(fixed[0..8], v) and
            @import("schema.zig").writeFixedComponent(fixed[8..16], pk))
            try aa.dupe(u8, &fixed)
        else
            try s.encodeIndexKey(aa, ix.column_idx, v, pk);
        try keys.append(alloc, key);
        ph.rows += 1;
        if (keys.items.len >= CHUNK_ROWS) {
            const te = monoNs(io);
            try sortChunkAndEmit(alloc, it, &keys, &items_buf, &scratch_buf, numeric_col, ph);
            emit_ns += monoNs(io) - te;
            chunk_arena.?.deinit();
            chunk_arena = null;
            chunks += 1;
        }
    }
    // 基础表段损坏 ⇒ 索引会静默缺项（建出一个「少键」的索引，比报错危险得多）
    if (cur.corrupt) return error.SegmentCorrupt;
    ph.scan_ns = (monoNs(io) - t_scan) -| emit_ns;

    // 2~3) 最后一块：排序 + 写成段
    if (keys.items.len > 0) {
        const te = monoNs(io);
        try sortChunkAndEmit(alloc, it, &keys, &items_buf, &scratch_buf, numeric_col, ph);
        emit_ns += monoNs(io) - te;
        chunks += 1;
    }

    // 多块 ⇒ 段之间 key 范围重叠（各块按主键顺序切分，不是按键范围切分），
    // 合并成一个段才能恢复「段范围不重叠」这个查询快路径的前提。
    if (chunks > 1) {
        const t_merge = monoNs(io);
        _ = try it.compact();
        ph.write_ns += monoNs(io) - t_merge;
    }
}

/// 一块索引键：排序后一次性写成段，然后清空 `keys` 供下一块复用。
fn sortChunkAndEmit(
    alloc: std.mem.Allocator,
    it: *tablemod.Table,
    keys: *std.ArrayList([]const u8),
    items_buf: *[]KeyItem,
    scratch_buf: *[]KeyItem,
    numeric: bool,
    ph: *FillPhases,
) !void {
    const n = keys.items.len;
    if (n == 0) return;
    if (items_buf.len < n) {
        if (items_buf.len > 0) alloc.free(items_buf.*);
        items_buf.* = try alloc.alloc(KeyItem, n);
    }
    const items = items_buf.*[0..n];
    for (keys.items, 0..) |k, i| items[i] = .{ .pre = prefix8(k), .key = k };

    const io = it.io;
    const t_sort = monoNs(io);
    if (numeric) {
        // 稳定基数排序：键的排序键就是前 8 字节（值分量定长），主键部分在输入里已升序，
        // 稳定排序保证「同值按键升序」正确，且不需要任何全键比较。
        if (scratch_buf.len < n) {
            if (scratch_buf.len > 0) alloc.free(scratch_buf.*);
            scratch_buf.* = try alloc.alloc(KeyItem, n);
        }
        radixSortByPre(items, scratch_buf.*[0..n]);
    } else {
        // text/blob 的值分量是变长 + 转义：前 8 字节相同不代表值相同，
        // 必须全键比较，且不能依赖输入顺序（稳定排序也无济于事）。
        std.mem.sortUnstable(KeyItem, items, {}, keyItemLess);
    }
    ph.sort_ns += monoNs(io) - t_sort;
    for (items, 0..) |e, i| keys.items[i] = e.key;

    const t_write = monoNs(io);
    try it.bulkLoadSorted(keys.items, null);
    ph.write_ns += monoNs(io) - t_write;
    keys.clearRetainingCapacity();
}

/// 稳定 LSD 基数排序（8 趟 × 8 位），按 `pre` 升序。
///
/// 为什么值得单独写一个：1M 条索引键用 pdqsort 实测 **154 ms**（约 20 次比较/元素，
/// 元素 24 字节、每次比较可能跨缓存行），是建索引最大的单项；
/// 基数排序是 O(8n) 的连续读写，实测约 1/3。
///
/// **稳定性是功能的一部分**，不是巧合：输入按基础表主键升序，索引键 = 值 ++ 主键，
/// 所以「值相同」的键天然已按主键有序 —— 稳定排序后整个数组就是正确的索引顺序，
/// 不需要靠回退比较去修。
fn radixSortByPre(items: []KeyItem, scratch: []KeyItem) void {
    if (items.len < 2) return;
    var src = items;
    var dst = scratch;
    var shift: u6 = 0;
    while (true) : (shift += 8) {
        var cnt: [256]u32 = @splat(0);
        for (src) |e| cnt[@intCast((e.pre >> shift) & 0xFF)] += 1;
        var distinct: usize = 0;
        for (cnt) |c| {
            if (c != 0) distinct += 1;
        }
        if (distinct > 1) {
            var off: [256]u32 = @splat(0);
            var acc: u32 = 0;
            for (cnt, 0..) |c, i| {
                off[i] = acc;
                acc += c;
            }
            for (src) |e| {
                const d: usize = @intCast((e.pre >> shift) & 0xFF);
                dst[off[d]] = e;
                off[d] += 1;
            }
            const t = src;
            src = dst;
            dst = t;
        }
        if (shift == 56) break;
    }
    if (src.ptr != items.ptr) @memcpy(items, src);
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
        return self.executeWithParams(stmt, null, alloc);
    }

    /// 带参数的执行入口（目前只有 `LIMIT ?` / `OFFSET ?` 用得上）。
    ///
    /// `params` 按**占位符出现顺序** 1-based 对应；`null` 等价于 `&.{}`。
    /// 设计上只把「取值的时机」推到执行时：同一条 AST 可以换不同参数反复执行，
    /// 无需重解析（SQLite 的 `sqlite3_bind_*` 就是这个形状）。
    pub fn executeWithParams(self: *Engine, stmt: sql.Statement, params: ?[]const sql.Value, alloc: std.mem.Allocator) !Result {
        switch (stmt) {
            .create_table => |def| return .{ .created = try self.createTable(def) },
            .create_index => |def| return .{ .created = try self.createIndex(def) },
            .drop_index => |def| return .{ .dropped = try self.dropIndex(def) },
            .insert => |ins| {
                const e = self.tables.getPtr(ins.table) orelse return error.TableNotFound;
                var host = exec.IndexHost{ .schema = &e.schema, .tables = &e.idx_tables };
                return .{ .inserted = try exec.insertRowsHost(&e.table, &e.schema, ins, alloc, &host) };
            },
            .select => |sel_in| {
                var sel = sel_in;
                // **`params == null` 也要过一遍解析**：否则 `LIMIT ?` 会因 `limit == null`
                // 而静默返回全部行（把「忘了绑参数」变成「翻页失效」这种难查的 bug）。
                try applyLimitParams(&sel, params orelse &[_]sql.Value{});
                if (sel.join) |jc| {
                    // JOIN 走独立路径：两表各带自己的 IndexHost（右表 ON 列可走索引/主键）
                    const el = self.tables.getPtr(sel.table) orelse return error.TableNotFound;
                    const er = self.tables.getPtr(jc.table) orelse return error.TableNotFound;
                    var host_l = exec.IndexHost{ .schema = &el.schema, .tables = &el.idx_tables };
                    var host_r = exec.IndexHost{ .schema = &er.schema, .tables = &er.idx_tables };
                    return .{ .rows = try exec.selectJoin(
                        .{ .name = sel.table, .table = &el.table, .schema = &el.schema, .host = &host_l },
                        .{ .name = jc.table, .table = &er.table, .schema = &er.schema, .host = &host_r },
                        sel,
                        alloc,
                    ) };
                }
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

    /// `DROP INDEX name`：从 schema 移除 → 落盘 → 删索引表目录。
    ///
    /// **顺序不能反**：先删目录、后存 schema 时，一旦崩在中间，schema 里还留着这个索引，
    /// 下次打开会把它当「已存在的索引表」去打开（表不在 ⇒ 报错或静默重建全表），
    /// 而查询侧仍认为「这列有索引」→ 走一条拿不到数据的路径 ⇒ **漏行**。
    /// 先存 schema 则最坏结果只是一个没人引用的孤儿目录（垃圾，不是错数据）。
    pub fn dropIndex(self: *Engine, def: sql.DropIndex) !bool {
        var it = self.tables.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr;
            const ix = e.schema.findIndex(def.name) orelse continue;
            // `findIndex` 返回的是值拷贝，`name` 还指向 schema 数组里的内存 ——
            // 下面 `removeIndex` 会释放它，所以先把名字抄一份。
            const key = try self.alloc.dupe(u8, ix.name);
            defer self.alloc.free(key);

            const path = try self.alloc.print("{s}/{s}", .{ self.root, kv.key_ptr.* });
            defer self.alloc.free(path);

            // 1) 内存：schema 与索引表集合都摘掉（此后查询不再认为有索引）
            _ = e.schema.removeIndex(self.alloc, key);
            if (e.idx_tables.fetchRemove(key)) |rm| {
                var t = rm.value;
                t.deinit();
                self.alloc.free(rm.key);
            }
            // 2) 落盘 schema（这一步成功后，索引在逻辑上已经不存在）
            try catalog.saveSchema(self.io, self.dir, path, &e.schema, self.alloc);
            // 3) 最后删目录；删失败只是留下孤儿文件，不影响正确性
            const idx_path = try self.alloc.print("{s}/idx/{s}", .{ path, key });
            defer self.alloc.free(idx_path);
            self.dir.deleteTree(self.io, idx_path) catch {};
            return true;
        }
        if (def.if_exists) return false;
        return error.IndexNotFound;
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
            var p = try sql.parse(alloc, "INSERT INTO sales (id, city, amount) VALUES " ++
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
        var p = try sql.parse(alloc, "SELECT city, COUNT(*), SUM(amount) FROM sales GROUP BY city HAVING SUM(amount) >= 100 ORDER BY sum(amount) DESC");
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
        var p = try sql.parse(alloc, "SELECT city, SUM(amount) FROM sales GROUP BY city HAVING SUM(amount) > 0 ORDER BY sum(amount) DESC");
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

/// 把 `LIMIT ?` / `OFFSET ?` 的参数序号解析成具体值（字面值原样保留）。
fn applyLimitParams(sel: *sql.Select, params: []const sql.Value) !void {
    if (sel.limit_param != 0) sel.limit = try paramAsCount(params, sel.limit_param);
    if (sel.offset_param != 0) sel.offset = try paramAsCount(params, sel.offset_param);
}

/// 参数必须是**非负整数**且 ≤ `u32` 上限。
///
/// 拒绝浮点/文本而不是做隐式转换：SQLite 对 `LIMIT 'abc'` 同样报错，
/// 而「悄悄取整」会把调用方的类型 bug 变成很难查的翻页错位。
fn paramAsCount(params: []const sql.Value, idx: u8) !u32 {
    if (idx == 0 or idx > params.len) return error.MissingParameter;
    return switch (params[idx - 1]) {
        .integer => |x| blk: {
            if (x < 0 or x > std.math.maxInt(u32)) break :blk error.ParameterOutOfRange;
            break :blk @as(u32, @intCast(x));
        },
        else => error.ParameterTypeMismatch,
    };
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

// `LIMIT ?` / `OFFSET ?` 参数绑定：占位符只记序号，取值推迟到执行时。
// 这条用例同时钉住「同一份 AST 换参数反复执行」——若在 parse 阶段就把值固化，
// 这里第二条 case 会拿到和第一条一样的结果。
test "LIMIT/OFFSET 占位符：取值、顺序、错误、同 AST 复用" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-limit-param";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)");
    try run(&eng, alloc, "INSERT INTO t (id, v) VALUES (1,10),(2,20),(3,30),(4,40),(5,50)");

    var p = try sql.parse(alloc, "SELECT id FROM t ORDER BY id LIMIT ? OFFSET ?");
    defer p.deinit();

    const cases = [_]struct { lim: i64, off: i64, want: []const i64 }{
        .{ .lim = 2, .off = 0, .want = &.{ 1, 2 } },
        .{ .lim = 2, .off = 2, .want = &.{ 3, 4 } },
        .{ .lim = 10, .off = 3, .want = &.{ 4, 5 } },
        .{ .lim = 0, .off = 0, .want = &.{} },
    };
    for (cases) |c| {
        const params = [_]sql.Value{ .{ .integer = c.lim }, .{ .integer = c.off } };
        const res = try eng.executeWithParams(p.stmt, &params, alloc);
        var rows = res.rows;
        defer rows.deinit();
        try std.testing.expectEqual(c.want.len, rows.rows.len);
        for (rows.rows, c.want) |r, w| try std.testing.expectEqual(w, r[0].integer);
    }

    // 参数个数不足 / 类型错 / 负数 / 超 u32：都必须报错，不能悄悄当 0 或截断
    const one = [_]sql.Value{.{ .integer = 2 }};
    try std.testing.expectError(error.MissingParameter, eng.executeWithParams(p.stmt, &one, alloc));
    const bad_type = [_]sql.Value{ .{ .text = "2" }, .{ .integer = 0 } };
    try std.testing.expectError(error.ParameterTypeMismatch, eng.executeWithParams(p.stmt, &bad_type, alloc));
    const negative = [_]sql.Value{ .{ .integer = -1 }, .{ .integer = 0 } };
    try std.testing.expectError(error.ParameterOutOfRange, eng.executeWithParams(p.stmt, &negative, alloc));
    const too_big = [_]sql.Value{ .{ .integer = @as(i64, 1) << 40 }, .{ .integer = 0 } };
    try std.testing.expectError(error.ParameterOutOfRange, eng.executeWithParams(p.stmt, &too_big, alloc));

    // 不带参数的 `execute` 遇到占位符也必须报错（否则会静默返回全部行）
    try std.testing.expectError(error.MissingParameter, eng.execute(p.stmt, alloc));

    // 字面 LIMIT 不受影响
    var p2 = try sql.parse(alloc, "SELECT id FROM t ORDER BY id LIMIT 3");
    defer p2.deinit();
    const res2 = try eng.execute(p2.stmt, alloc);
    var rows2 = res2.rows;
    defer rows2.deinit();
    try std.testing.expectEqual(@as(usize, 3), rows2.rows.len);
}

// `JOIN`：只支持单条等值 ON；右表 ON 列按「主键点查 / 索引前缀扫描 / 全表扫」三档查找。
// 用例重点不是「能查出来」，而是：ON 反向写结果一致、LEFT 补 NULL、限定名与裸名歧义、
// 以及**索引路径与全扫路径结果一致**。
test "JOIN：INNER/LEFT、ON 反向、索引路径、裸名歧义、不支持的形态" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-join";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, uid INTEGER NOT NULL, tag TEXT NOT NULL)");
    try run(&eng, alloc, "CREATE TABLE u (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    try run(&eng, alloc, "INSERT INTO t (id, uid, tag) VALUES (1,10,'a'), (2,10,'b'), (3,20,'c'), (4,99,'d')");
    try run(&eng, alloc, "INSERT INTO u (id, name) VALUES (10,'ten'), (20,'twenty'), (30,'thirty')");

    // INNER：t.uid = u.id ⇒ 3 行（uid=99 无匹配被排除）；同一 uid 两行都要出现
    {
        var rows = try queryRows(&eng, alloc, "SELECT t.id, t.tag, u.name FROM t JOIN u ON t.uid = u.id ORDER BY t.id");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
        try std.testing.expectEqualStrings("ten", rows.rows[0][2].text);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[2][0].integer);
        try std.testing.expectEqualStrings("twenty", rows.rows[2][2].text);
    }

    // ON 反向写（右表列在左）：结果必须一样
    {
        var rows = try queryRows(&eng, alloc, "SELECT t.id FROM t JOIN u ON u.id = t.uid ORDER BY t.id");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[2][0].integer);
    }

    // LEFT：4 行，uid=99 那行右表列全 NULL
    {
        var rows = try queryRows(&eng, alloc, "SELECT t.id, u.name FROM t LEFT JOIN u ON t.uid = u.id ORDER BY t.id");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
        try std.testing.expect(rows.rows[3][1] == .null);
    }

    // WHERE + ORDER BY + LIMIT 与 JOIN 组合
    {
        var rows = try queryRows(&eng, alloc, "SELECT t.id FROM t JOIN u ON t.uid = u.id WHERE u.name = 'ten' ORDER BY t.id DESC LIMIT 1");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 2), rows.rows[0][0].integer);
    }

    // 裸名列两表唯一 ⇒ 可用；`id` 两表都有 ⇒ 必须报歧义，不能默默取第一个
    {
        var rows = try queryRows(&eng, alloc, "SELECT name FROM t JOIN u ON t.uid = u.id ORDER BY name LIMIT 1");
        defer rows.deinit();
        try std.testing.expectEqualStrings("ten", rows.rows[0][0].text);
    }
    try std.testing.expectError(error.AmbiguousColumn, queryRows(&eng, alloc, "SELECT id FROM t JOIN u ON t.uid = u.id"));

    // ON 用右表的**索引列**（非主键）⇒ 走键前缀扫描；先给 u.name 建索引再插一行可匹配的 tag
    try run(&eng, alloc, "CREATE INDEX idx_name ON u (name)");
    try run(&eng, alloc, "INSERT INTO t (id, uid, tag) VALUES (5, 0, 'ten')");
    {
        // 确定性证据：**右表最多只扫一遍**（哈希连接整表建一次索引）。
        // 旧口径是「右表主表一行都不扫」（按行查索引前缀），换哈希连接后必然扫一次；
        // 但若退化成「左行数 × 右行数」的嵌套全扫，这里会变成 15 —— 那才是要拦的。
        eng.get("u").?.table.scan_rows_read = 0;
        var rows = try queryRows(&eng, alloc, "SELECT t.id, u.id FROM t JOIN u ON t.tag = u.name ORDER BY t.id");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 5), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 10), rows.rows[0][1].integer);
        try std.testing.expect(eng.get("u").?.table.scan_rows_read <= 3);
    }

    // 不支持的形态：自连接（需要别名）与非等值 ON
    try std.testing.expectError(error.UnsupportedStatement, queryRows(&eng, alloc, "SELECT t.id FROM t JOIN t ON t.id = t.uid"));
    try std.testing.expectError(error.UnexpectedToken, queryRows(&eng, alloc, "SELECT t.id FROM t JOIN u ON t.uid > u.id"));
}

// **`JOIN` 的两条装配路径**：有 `ORDER BY` 走「arena 宽行 → 深拷」老路，
// 无 `ORDER BY` 走 `JoinSink` 直写最终布局。两者必须给出**同一组行、同一顺序**。
//
// 为什么顺序也必须一样：左表按主键升序流式扫，命中的右表行按右表扫描顺序串成链，
// 所以「无 ORDER BY」的天然顺序就是 `(左主键, 右主键)` 升序 —— 正好等于那条带
// `ORDER BY 左主键, 右主键` 的 SQL。用例把这个等价关系钉死，直写路径改错就会露。
test "JOIN 直写路径（无 ORDER BY）与排序路径逐格一致，并保持左表顺序" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-join-direct";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE p (id INTEGER PRIMARY KEY, k TEXT NOT NULL)");
    try run(&eng, alloc, "CREATE TABLE q (id INTEGER PRIMARY KEY, k TEXT NOT NULL, n INTEGER NOT NULL)");
    try run(&eng, alloc, "CREATE INDEX idx_q_k ON q (k)");
    try run(&eng, alloc, "INSERT INTO p (id, k) VALUES (1,'aa'), (2,'bb'), (3,'cc'), (4,'aa'), (5,'dd')");
    try run(&eng, alloc, "INSERT INTO q (id, k, n) VALUES (10,'aa',1), (11,'aa',2), (12,'cc',3), (13,'zz',4)");

    // 每对：直写路径（无 ORDER BY） vs 排序路径（有 ORDER BY，顺序应相同）
    const pairs = [_][2][]const u8{
        .{
            "SELECT p.id, q.id, q.n FROM p JOIN q ON p.k = q.k",
            "SELECT p.id, q.id, q.n FROM p JOIN q ON p.k = q.k ORDER BY p.id, q.id",
        },
        // 投影里带 text（走 JoinSink 的 text 回填分支）
        .{
            "SELECT p.k, q.n, p.id FROM p JOIN q ON p.k = q.k",
            "SELECT p.k, q.n, p.id FROM p JOIN q ON p.k = q.k ORDER BY p.id, q.id",
        },
        // LEFT JOIN：补 NULL 的行也要一致
        .{
            "SELECT p.id, q.n FROM p LEFT JOIN q ON p.k = q.k",
            "SELECT p.id, q.n FROM p LEFT JOIN q ON p.k = q.k ORDER BY p.id",
        },
        // WHERE 在直写路径上先判宽行
        .{
            "SELECT p.id, q.n FROM p JOIN q ON p.k = q.k WHERE q.n > 1",
            "SELECT p.id, q.n FROM p JOIN q ON p.k = q.k WHERE q.n > 1 ORDER BY p.id, q.id",
        },
        // WHERE 引用的列**不在投影里**：直写路径必须用「宽行」判 WHERE 再投影，
        // 若先投影再判就会 `ColumnNotFound` 或静默判错（这正是提前投影最容易踩的坑）
        .{
            "SELECT p.k FROM p JOIN q ON p.k = q.k WHERE q.n > 2",
            "SELECT p.k FROM p JOIN q ON p.k = q.k WHERE q.n > 2 ORDER BY p.id, q.id",
        },
        // LIMIT：直写路径会「凑够就停」，结果必须与全量再截断一致
        .{
            "SELECT p.id, q.id FROM p JOIN q ON p.k = q.k LIMIT 3",
            "SELECT p.id, q.id FROM p JOIN q ON p.k = q.k ORDER BY p.id, q.id LIMIT 3",
        },
        // OFFSET
        .{
            "SELECT p.id, q.id FROM p JOIN q ON p.k = q.k LIMIT 2 OFFSET 2",
            "SELECT p.id, q.id FROM p JOIN q ON p.k = q.k ORDER BY p.id, q.id LIMIT 2 OFFSET 2",
        },
    };

    for (pairs, 0..) |pr, ci| {
        var direct = try queryRows(&eng, alloc, pr[0]);
        defer direct.deinit();
        var sorted = try queryRows(&eng, alloc, pr[1]);
        defer sorted.deinit();
        if (direct.rows.len != sorted.rows.len) {
            std.debug.print("case {d}: 直写 {d} 行 != 排序 {d} 行\n", .{ ci, direct.rows.len, sorted.rows.len });
            return error.JoinDirectRowCountMismatch;
        }
        for (direct.rows, sorted.rows, 0..) |dr, sr, ri| {
            for (dr, sr) |a, b| {
                if (schema_mod.valueCmp(a, b) != .eq) {
                    std.debug.print("case {d} 第 {d} 行不一致\n", .{ ci, ri });
                    return error.JoinDirectValueMismatch;
                }
            }
        }
    }

    // 直写路径的顺序必须是「左主键升序、同左主键时右主键升序」
    {
        var rows = try queryRows(&eng, alloc, "SELECT p.id, q.id FROM p JOIN q ON p.k = q.k");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 5), rows.rows.len); // 1→{10,11}、4→{10,11}、3→{12}
        const want = [_][2]i64{ .{ 1, 10 }, .{ 1, 11 }, .{ 3, 12 }, .{ 4, 10 }, .{ 4, 11 } };
        for (rows.rows, want) |r, w| {
            try std.testing.expectEqual(w[0], r[0].integer);
            try std.testing.expectEqual(w[1], r[1].integer);
        }
    }
}

// 哈希连接与嵌套循环是**两条代码路径**，结果必须逐格相同。
// 撤销这条用例的方式：把 `use_hash` 写死成 `false` ⇒ 只测嵌套循环；写死成 `true` ⇒ 只测哈希。
test "JOIN：哈希连接与嵌套循环（索引前缀扫描）结果逐格一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-join-hash-vs-loop";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE p (id INTEGER PRIMARY KEY, k TEXT NOT NULL)");
    try run(&eng, alloc, "CREATE TABLE q (id INTEGER PRIMARY KEY, k TEXT NOT NULL, n INTEGER NOT NULL)");
    try run(&eng, alloc, "CREATE INDEX idx_q_k ON q (k)");
    try run(&eng, alloc, "INSERT INTO p (id, k) VALUES (1,'aa'), (2,'bb'), (3,'cc'), (4,'aa')");
    try run(&eng, alloc, "INSERT INTO q (id, k, n) VALUES (10,'aa',1), (11,'aa',2), (12,'cc',3), (13,'zz',4)");

    const jq = "SELECT p.id, q.id, q.n FROM p JOIN q ON p.k = q.k ORDER BY p.id, q.id";

    var hash_rows = try queryRows(&eng, alloc, jq);
    defer hash_rows.deinit();
    // 1→{10,11}、4→{10,11}、3→{12}，共 5 行（`bb` 与 `zz` 两侧都无匹配）
    try std.testing.expectEqual(@as(usize, 5), hash_rows.rows.len);

    const saved = exec.join_hash_max_rows;
    exec.join_hash_max_rows = 0; // 上限设 0 ⇒ 强制走嵌套循环（索引前缀扫描）
    defer exec.join_hash_max_rows = saved;

    var loop_rows = try queryRows(&eng, alloc, jq);
    defer loop_rows.deinit();

    try std.testing.expectEqual(hash_rows.rows.len, loop_rows.rows.len);
    for (hash_rows.rows, loop_rows.rows) |hr, lr| {
        try std.testing.expectEqual(hr.len, lr.len);
        for (hr, lr) |x, y| try std.testing.expect(schema_mod.valueCmp(x, y) == .eq);
    }
}

// JOIN 的边界与「以前会静默」的形态：`*` 投影、1:N 多匹配、LEFT+WHERE 滤 NULL、
// 空表、JOIN 与 `LIMIT ?` 组合、ORDER BY 列不存在、JOIN+GROUP BY。
test "JOIN 边界：* 投影 / 1:N / LEFT+WHERE / 空表 / LIMIT ? / 错误形态" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-join-edge";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE a (id INTEGER PRIMARY KEY, k INTEGER NOT NULL)");
    try run(&eng, alloc, "CREATE TABLE b (id INTEGER PRIMARY KEY, k INTEGER NOT NULL, v TEXT NOT NULL)");
    try run(&eng, alloc, "CREATE TABLE empty_t (id INTEGER PRIMARY KEY, k INTEGER NOT NULL)");
    try run(&eng, alloc, "INSERT INTO a (id, k) VALUES (1, 7), (2, 8)");
    // b 里 k=7 有两行（1:N），k=9 没有对应左行
    try run(&eng, alloc, "INSERT INTO b (id, k, v) VALUES (10, 7, 'x'), (11, 7, 'y'), (12, 9, 'z')");

    // `*` 投影：合成 schema 是 2 + 3 = 5 列，列名带表名限定
    {
        var rows = try queryRows(&eng, alloc, "SELECT * FROM a JOIN b ON a.k = b.k ORDER BY a.id, b.id");
        defer rows.deinit();
        // a 的 k 只有 7/8；b 里 k=7 两行、k=9 一行 ⇒ INNER 只匹配到 2 行
        // （a.id=2 的 k=8 在 b 里没有，k=9 在 a 里没有）
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqual(@as(usize, 5), rows.columns.len);
        try std.testing.expectEqualStrings("a.id", rows.columns[0]);
        try std.testing.expectEqualStrings("b.v", rows.columns[4]);
    }

    // 1:N：a.id=1 匹配 b 的两行，都要出现
    {
        var rows = try queryRows(&eng, alloc, "SELECT a.id, b.id FROM a JOIN b ON a.k = b.k WHERE a.id = 1 ORDER BY b.id");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 10), rows.rows[0][1].integer);
        try std.testing.expectEqual(@as(i64, 11), rows.rows[1][1].integer);
    }

    // LEFT JOIN + WHERE：补出来的 NULL 行会被 `b.v = 'x'` 滤掉（SQL 语义）
    {
        var rows = try queryRows(&eng, alloc, "SELECT a.id, b.v FROM a LEFT JOIN b ON a.k = b.k WHERE b.v = 'x'");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
    }
    // 同一 SQL 去掉 WHERE：a.id=2 那行右表列是 NULL
    {
        var rows = try queryRows(&eng, alloc, "SELECT a.id, b.v FROM a LEFT JOIN b ON a.k = b.k ORDER BY a.id, b.id");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
        try std.testing.expect(rows.rows[2][1] == .null);
    }

    // 空表：INNER ⇒ 0 行；LEFT ⇒ 左表行 + 全 NULL
    {
        var rows = try queryRows(&eng, alloc, "SELECT a.id FROM a JOIN empty_t ON a.k = empty_t.k");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 0), rows.rows.len);
    }
    {
        var rows = try queryRows(&eng, alloc, "SELECT a.id, empty_t.id FROM a LEFT JOIN empty_t ON a.k = empty_t.k ORDER BY a.id");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expect(rows.rows[0][1] == .null);
    }

    // JOIN 与 `LIMIT ?` 组合（参数绑定走 executeWithParams，JOIN 走自己的派发）
    {
        var p = try sql.parse(alloc, "SELECT a.id FROM a JOIN b ON a.k = b.k ORDER BY a.id, b.id LIMIT ?");
        defer p.deinit();
        const params = [_]sql.Value{.{ .integer = 2 }};
        const res = try eng.executeWithParams(p.stmt, &params, alloc);
        var rows = res.rows;
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
    }

    // 两处「以前会静默」的形态现在必须报错
    try std.testing.expectError(error.ColumnNotFound, queryRows(&eng, alloc, "SELECT a.id FROM a JOIN b ON a.k = b.k ORDER BY nosuchcol"));
    try std.testing.expectError(error.UnsupportedStatement, queryRows(&eng, alloc, "SELECT a.id FROM a JOIN b ON a.k = b.k GROUP BY a.id"));
}

fn keyArrLess(_: void, a: [16]u8, b: [16]u8) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

/// 跑一条查询并交回结果行（调用方 `deinit`）。
///
/// `execute` 返回的是 union：非 `.rows` 变体（如 INSERT 的 `.count`）一律报错，
/// 不要直接取 `.rows`（在 Debug 下会 panic，ReleaseFast 下是 UB）。
fn queryRows(eng: *Engine, alloc: std.mem.Allocator, text: []const u8) !exec.Rows {
    var p = try sql.parse(alloc, text);
    defer p.deinit();
    const res = try eng.execute(p.stmt, alloc);
    return switch (res) {
        .rows => res.rows,
        else => error.NotARowsStatement,
    };
}

// `ORDER BY <已建索引的非主键列>` 走索引的守门用例。
//
// 对照组不能用「同一条 SQL 关掉索引」——所以表里放两列同值（`g` 有索引、`h` 没有）：
// `ORDER BY g` 走索引（新路径），`ORDER BY h` 走全量扫描 + 排序（旧路径），
// 两者必须**逐行一致**（含并列行：索引键是 `g ++ id`，所以同 g 按 id 升序，
// 与全量路径的稳定排序结果相同）。
test "ORDER BY 索引列：正序/降序 + LIMIT/OFFSET 走索引，结果与全量扫描逐行一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-order-idx";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER NOT NULL, h INTEGER NOT NULL)");

    // 300 行，g 只有 23 个取值（大量并列）；h 与 g 同值但不建索引
    var b: usize = 0;
    while (b < 6) : (b += 1) {
        var sb: std.ArrayList(u8) = .empty;
        defer sb.deinit(alloc);
        try sb.appendSlice(alloc, "INSERT INTO t (id, g, h) VALUES ");
        for (0..50) |j| {
            const i: i64 = @intCast(b * 50 + j);
            const g: i64 = @intCast(@mod(i * 7, 23));
            try sb.appendSlice(alloc, if (j == 0) "" else ", ");
            var num: [64]u8 = undefined;
            try sb.appendSlice(alloc, try std.fmt.bufPrint(&num, "({d}, {d}, {d})", .{ i, g, g }));
        }
        try run(&eng, alloc, sb.items);
    }
    try run(&eng, alloc, "CREATE INDEX idx_g ON t (g)");

    // 每条用例：`[0]` 走索引列 `g`，`[1]` 走无索引的同值列 `h`（对照组，全量扫描 + 排序），
    // `[2]` 标记该用例是否**必须**走索引（降序目前回退全量路径，见 exec.zig 的说明）。
    const cases = [_]struct { by_idx: []const u8, full: []const u8, must_index: bool }{
        .{ .by_idx = "SELECT id, g FROM t ORDER BY g ASC LIMIT 10", .full = "SELECT id, g FROM t ORDER BY h ASC LIMIT 10", .must_index = true },
        .{ .by_idx = "SELECT id, g FROM t ORDER BY g LIMIT 10", .full = "SELECT id, g FROM t ORDER BY h LIMIT 10", .must_index = true },
        .{ .by_idx = "SELECT id, g FROM t ORDER BY g ASC LIMIT 10 OFFSET 5", .full = "SELECT id, g FROM t ORDER BY h ASC LIMIT 10 OFFSET 5", .must_index = true },
        .{ .by_idx = "SELECT id, g FROM t ORDER BY g ASC LIMIT 1", .full = "SELECT id, g FROM t ORDER BY h ASC LIMIT 1", .must_index = true },
        .{ .by_idx = "SELECT id, g FROM t ORDER BY g ASC LIMIT 40 OFFSET 280", .full = "SELECT id, g FROM t ORDER BY h ASC LIMIT 40 OFFSET 280", .must_index = true },
        // 降序 + 超过行数（取全表）：必须与对照组一致，但**不要求**走索引
        .{ .by_idx = "SELECT id, g FROM t ORDER BY g DESC LIMIT 300", .full = "SELECT id, g FROM t ORDER BY h DESC LIMIT 300", .must_index = false },
    };

    for (cases, 0..) |c, ci| {
        eng.get("t").?.table.scan_rows_read = 0;
        var got = try queryRows(&eng, alloc, c.by_idx);
        defer got.deinit();
        const idx_scanned = eng.get("t").?.table.scan_rows_read;

        var want = try queryRows(&eng, alloc, c.full);
        defer want.deinit();

        if (got.rows.len != want.rows.len) {
            std.debug.print("case {d}: 行数 {d} != {d}\n", .{ ci, got.rows.len, want.rows.len });
            return error.RowCountMismatch;
        }
        for (got.rows, want.rows, 0..) |gr, wr, ri| {
            if (gr[0].integer != wr[0].integer or gr[1].integer != wr[1].integer) {
                std.debug.print("case {d} 第 {d} 行: idx={any} full={any}\n", .{ ci, ri, gr, wr });
                return error.ValueMismatch;
            }
        }
        // 确定性证据：该走索引的用例下 `scan_rows_read` 必须为 0（不扫主表，只有回表）
        if (c.must_index and idx_scanned != 0) {
            std.debug.print("case {d}: 走索引却扫了主表 {d} 行\n", .{ ci, idx_scanned });
            return error.IndexPathScannedTable;
        }
    }
}

/// 测试用：按「第 2 列（升序）→ 第 1 列（升序）」排结果行。
/// 无 `ORDER BY` 时 SQL 不保证行序，所以「走索引」与「走全表」两条路径
/// 只能比**集合**——各自排序后再逐行比。
fn lessCol1ThenCol0(_: void, a: []sql.Value, b: []sql.Value) bool {
    const av = if (a.len > 1) a[1].integer else 0;
    const bv = if (b.len > 1) b[1].integer else 0;
    if (av != bv) return av < bv;
    return a[0].integer < b[0].integer;
}

// 范围谓词（`>` / `>=` / `<` / `<=`）走索引键区间：把「值分量」的上下界翻译成
// `MergeIter` 的 `[start, end)`。对照组是「同值但无索引的 `h` 列」（全表扫）。
test "索引范围查询：> / >= / < / <= 走索引键区间，结果与全表一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-index-range";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER NOT NULL, h INTEGER NOT NULL)");
    var b: usize = 0;
    while (b < 6) : (b += 1) {
        var sb: std.ArrayList(u8) = .empty;
        defer sb.deinit(alloc);
        try sb.appendSlice(alloc, "INSERT INTO t (id, g, h) VALUES ");
        for (0..50) |j| {
            const i: i64 = @intCast(b * 50 + j);
            const g: i64 = @intCast(@mod(i * 7, 23));
            try sb.appendSlice(alloc, if (j == 0) "" else ", ");
            var num: [64]u8 = undefined;
            try sb.appendSlice(alloc, try std.fmt.bufPrint(&num, "({d}, {d}, {d})", .{ i, g, g }));
        }
        try run(&eng, alloc, sb.items);
    }
    try run(&eng, alloc, "CREATE INDEX idx_g ON t (g)");

    // LIMIT 取 300（> 命中数）⇒ 索引路径取全集，集合才可比
    const cases = [_]struct { by_idx: []const u8, full: []const u8 }{
        .{ .by_idx = "SELECT id, g FROM t WHERE g > 20 LIMIT 300", .full = "SELECT id, g FROM t WHERE h > 20" },
        .{ .by_idx = "SELECT id, g FROM t WHERE g >= 21 LIMIT 300", .full = "SELECT id, g FROM t WHERE h >= 21" },
        .{ .by_idx = "SELECT id, g FROM t WHERE g < 2 LIMIT 300", .full = "SELECT id, g FROM t WHERE h < 2" },
        .{ .by_idx = "SELECT id, g FROM t WHERE g <= 1 LIMIT 300", .full = "SELECT id, g FROM t WHERE h <= 1" },
        // 边界：区间为空（上界超过最大值 / 下界低于最小值）
        .{ .by_idx = "SELECT id, g FROM t WHERE g > 22 LIMIT 300", .full = "SELECT id, g FROM t WHERE h > 22" },
        .{ .by_idx = "SELECT id, g FROM t WHERE g < 0 LIMIT 300", .full = "SELECT id, g FROM t WHERE h < 0" },
    };

    for (cases, 0..) |c, ci| {
        eng.get("t").?.table.scan_rows_read = 0;
        var got = try queryRows(&eng, alloc, c.by_idx);
        defer got.deinit();
        const scanned = eng.get("t").?.table.scan_rows_read;

        var want = try queryRows(&eng, alloc, c.full);
        defer want.deinit();

        if (got.rows.len != want.rows.len) {
            std.debug.print("case {d}: 行数 {d} != {d}\n", .{ ci, got.rows.len, want.rows.len });
            return error.RowCountMismatch;
        }
        std.mem.sort([]sql.Value, got.rows, {}, lessCol1ThenCol0);
        std.mem.sort([]sql.Value, want.rows, {}, lessCol1ThenCol0);
        for (got.rows, want.rows, 0..) |gr, wr, ri| {
            if (gr[0].integer != wr[0].integer or gr[1].integer != wr[1].integer) {
                std.debug.print("case {d} 第 {d} 行: idx={any} full={any}\n", .{ ci, ri, gr, wr });
                return error.ValueMismatch;
            }
        }
        // 确定性证据：命中非空时必须走索引（不扫主表）
        if (want.rows.len > 0 and scanned != 0) {
            std.debug.print("case {d}: 走索引却扫了主表 {d} 行\n", .{ ci, scanned });
            return error.IndexPathScannedTable;
        }
    }
}

// **NULL 参与比较**：`x < 5` / `x <= 5` 对 NULL 行是 UNKNOWN（不匹配）。
//
// 这类分歧最容易被漏掉：索引键里根本不收 NULL，所以「走索引」那条路径天然不含 NULL 行；
// 而全表扫如果只判了谓词右侧（`b`），`valueCmp(NULL, 5) == .lt` 就会把 NULL 行算成命中
// ⇒ **同一句 SQL 走索引与走全表条数不同**。用例两侧都跑、要求条数相同。
test "NULL 与范围谓词：走索引与走全表的条数必须一致（NULL 不算命中）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-null-range";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER, h INTEGER)");
    var b: usize = 0;
    while (b < 4) : (b += 1) {
        var sb: std.ArrayList(u8) = .empty;
        defer sb.deinit(alloc);
        try sb.appendSlice(alloc, "INSERT INTO t (id, n, h) VALUES ");
        for (0..25) |j| {
            const i: i64 = @intCast(b * 25 + j);
            const v: i64 = @intCast(@mod(i * 5, 11));
            try sb.appendSlice(alloc, if (j == 0) "" else ", ");
            var num: [64]u8 = undefined;
            // 每 4 行「n 与 h 同时为 NULL」（h 是 n 的**无索引镜像**，用来强制走全表扫）；
            // 两列的 NULL 形态必须完全一致，否则两条 SQL 本来就不该同条数。
            if (@mod(i, 4) == 0) {
                try sb.appendSlice(alloc, try std.fmt.bufPrint(&num, "({d}, NULL, NULL)", .{i}));
            } else {
                try sb.appendSlice(alloc, try std.fmt.bufPrint(&num, "({d}, {d}, {d})", .{ i, v, v }));
            }
        }
        try run(&eng, alloc, sb.items);
    }
    try run(&eng, alloc, "CREATE INDEX idx_n ON t (n)");

    const cases = [_]struct { by_idx: []const u8, full: []const u8 }{
        .{ .by_idx = "SELECT id, n FROM t WHERE n < 4 LIMIT 300", .full = "SELECT id, h FROM t WHERE h < 4" },
        .{ .by_idx = "SELECT id, n FROM t WHERE n <= 4 LIMIT 300", .full = "SELECT id, h FROM t WHERE h <= 4" },
        .{ .by_idx = "SELECT id, n FROM t WHERE n > 6 LIMIT 300", .full = "SELECT id, h FROM t WHERE h > 6" },
    };
    for (cases, 0..) |c, ci| {
        var got = try queryRows(&eng, alloc, c.by_idx);
        defer got.deinit();
        var want = try queryRows(&eng, alloc, c.full);
        defer want.deinit();
        if (got.rows.len != want.rows.len) {
            std.debug.print("case {d}: 索引 {d} 行 != 全表 {d} 行\n", .{ ci, got.rows.len, want.rows.len });
            return error.NullComparisonDiverged;
        }
        // 方向性证据：表里确实有 NULL 行，且它们一条都没被算成命中
        try std.testing.expect(want.rows.len < 100);
        for (got.rows) |r| try std.testing.expect(r[1] != .null);
    }
}

/// 测试用：text 列（第 2 列）升序 → 第 1 列升序。
fn lessTextCol1ThenCol0(_: void, a: []sql.Value, b: []sql.Value) bool {
    const ao = std.mem.order(u8, a[1].text, b[1].text);
    if (ao != .eq) return ao == .lt;
    return a[0].integer < b[0].integer;
}

// **text 列的范围查询**：值分量是「转义 + `0x00 0x01` 收尾」的**变长**编码，
// 所以范围扫描里每条记录的「值分量长度」都可能不同 —— 切主键必须按本行自己的长度
// （`indexPkSlice` 扫终止符），按谓词那个值的编码长度切会切到别的字节上。
test "索引范围查询（text 变长值分量）：切主键必须按本行长度，不能按谓词的编码长度" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-index-range-text";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t2 (id INTEGER PRIMARY KEY, s TEXT NOT NULL, h TEXT NOT NULL)");
    // 200 行，s 的长度在 1..5 之间循环（"a" / "aa" / "aaa" / "aaaa" / "aaaaa"）
    var b: usize = 0;
    while (b < 4) : (b += 1) {
        var sb: std.ArrayList(u8) = .empty;
        defer sb.deinit(alloc);
        try sb.appendSlice(alloc, "INSERT INTO t2 (id, s, h) VALUES ");
        for (0..50) |j| {
            const i: i64 = @intCast(b * 50 + j);
            const n: usize = @intCast(@mod(i, 5) + 1);
            var sv: [8]u8 = @splat('a');
            const s = sv[0..n];
            try sb.appendSlice(alloc, if (j == 0) "" else ", ");
            var num: [64]u8 = undefined;
            try sb.appendSlice(alloc, try std.fmt.bufPrint(&num, "({d}, '{s}', '{s}')", .{ i, s, s }));
        }
        try run(&eng, alloc, sb.items);
    }
    try run(&eng, alloc, "CREATE INDEX idx_s ON t2 (s)");

    const cases = [_]struct { by_idx: []const u8, full: []const u8 }{
        // 'aaa' 的编码长度是 5（3 字节 + 2 字节终止符），比 'aa'/'a' 长 —— 最容易暴露切错
        .{ .by_idx = "SELECT id, s FROM t2 WHERE s > 'aaa' LIMIT 999", .full = "SELECT id, s FROM t2 WHERE h > 'aaa'" },
        .{ .by_idx = "SELECT id, s FROM t2 WHERE s < 'aaa' LIMIT 999", .full = "SELECT id, s FROM t2 WHERE h < 'aaa'" },
        .{ .by_idx = "SELECT id, s FROM t2 WHERE s >= 'aa' LIMIT 999", .full = "SELECT id, s FROM t2 WHERE h >= 'aa'" },
        .{ .by_idx = "SELECT id, s FROM t2 WHERE s <= 'aa' LIMIT 999", .full = "SELECT id, s FROM t2 WHERE h <= 'aa'" },
    };

    for (cases, 0..) |c, ci| {
        eng.get("t2").?.table.scan_rows_read = 0;
        var got = try queryRows(&eng, alloc, c.by_idx);
        defer got.deinit();
        const scanned = eng.get("t2").?.table.scan_rows_read;

        var want = try queryRows(&eng, alloc, c.full);
        defer want.deinit();

        if (got.rows.len != want.rows.len) {
            std.debug.print("text case {d}: 行数 {d} != {d}\n", .{ ci, got.rows.len, want.rows.len });
            return error.RowCountMismatch;
        }
        std.mem.sort([]sql.Value, got.rows, {}, lessTextCol1ThenCol0);
        std.mem.sort([]sql.Value, want.rows, {}, lessTextCol1ThenCol0);
        for (got.rows, want.rows, 0..) |gr, wr, ri| {
            if (gr[0].integer != wr[0].integer or !std.mem.eql(u8, gr[1].text, wr[1].text)) {
                std.debug.print("text case {d} 第 {d} 行: idx={any} full={any}\n", .{ ci, ri, gr, wr });
                return error.ValueMismatch;
            }
        }
        if (want.rows.len > 0 and scanned != 0) {
            std.debug.print("text case {d}: 走索引却扫了主表 {d} 行\n", .{ ci, scanned });
            return error.IndexPathScannedTable;
        }
    }
}

test "DROP INDEX：删除后查询退回全表且结果不变，重开不复活，再建仍走索引" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-drop-index";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var dropped_ok = false;
    {
        var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
        defer eng.deinit();

        try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER NOT NULL)");
        var b: usize = 0;
        while (b < 4) : (b += 1) {
            var sb: std.ArrayList(u8) = .empty;
            defer sb.deinit(alloc);
            try sb.appendSlice(alloc, "INSERT INTO t (id, g) VALUES ");
            for (0..25) |j| {
                const i: i64 = @intCast(b * 25 + j);
                try sb.appendSlice(alloc, if (j == 0) "" else ", ");
                var num: [48]u8 = undefined;
                try sb.appendSlice(alloc, try std.fmt.bufPrint(&num, "({d}, {d})", .{ i, @mod(i, 10) }));
            }
            try run(&eng, alloc, sb.items);
        }
        try run(&eng, alloc, "CREATE INDEX idx_g ON t (g)");

        // 建好后必须走索引（不扫主表），并记下命中行数
        eng.get("t").?.table.scan_rows_read = 0;
        var r1 = try queryRows(&eng, alloc, "SELECT id FROM t WHERE g = 7");
        defer r1.deinit();
        const hits = r1.rows.len;
        try std.testing.expect(hits > 0);
        try std.testing.expectEqual(@as(u64, 0), eng.get("t").?.table.scan_rows_read);

        // DROP 之后：结果一致，但**退回全表**（必须真的扫主表，证明索引已被摘除）
        {
            var p = try sql.parse(alloc, "DROP INDEX idx_g");
            defer p.deinit();
            const res = try eng.execute(p.stmt, alloc);
            try std.testing.expectEqual(true, res.dropped);
        }
        eng.get("t").?.table.scan_rows_read = 0;
        var r2 = try queryRows(&eng, alloc, "SELECT id FROM t WHERE g = 7");
        defer r2.deinit();
        try std.testing.expectEqual(hits, r2.rows.len);
        try std.testing.expect(eng.get("t").?.table.scan_rows_read > 0);

        // IF EXISTS：删一个不存在的索引不报错；不带 IF EXISTS 必须报 IndexNotFound
        {
            var p = try sql.parse(alloc, "DROP INDEX IF EXISTS nope");
            defer p.deinit();
            const res = try eng.execute(p.stmt, alloc);
            try std.testing.expectEqual(false, res.dropped);
        }
        {
            var p = try sql.parse(alloc, "DROP INDEX nope");
            defer p.deinit();
            try std.testing.expectError(error.IndexNotFound, eng.execute(p.stmt, alloc));
        }

        // 再建一次：回填后查询又走索引（证明「删掉再建」不是一次性状态）
        try run(&eng, alloc, "CREATE INDEX idx_g ON t (g)");
        eng.get("t").?.table.scan_rows_read = 0;
        var r3 = try queryRows(&eng, alloc, "SELECT id FROM t WHERE g = 7");
        defer r3.deinit();
        try std.testing.expectEqual(hits, r3.rows.len);
        try std.testing.expectEqual(@as(u64, 0), eng.get("t").?.table.scan_rows_read);

        dropped_ok = true;
    }
    try std.testing.expect(dropped_ok);

    // 重开：最后一次「再建」必须已经落盘 ⇒ 索引存在，且查询走索引
    {
        var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
        defer eng.deinit();
        try std.testing.expect(eng.get("t").?.schema.findIndex("idx_g") != null);
        eng.get("t").?.table.scan_rows_read = 0;
        var r = try queryRows(&eng, alloc, "SELECT id FROM t WHERE g = 7");
        defer r.deinit();
        try std.testing.expect(r.rows.len > 0);
        try std.testing.expectEqual(@as(u64, 0), eng.get("t").?.table.scan_rows_read);
    }
}

// `WHERE` + `ORDER BY <索引列>`：谓词在扫描循环里判，谓词落在排序列上时用索引键下界剪枝。
// 对照组用「同值但无索引的 `h`」—— 两条查询语义等价，结果必须逐行相同。
test "WHERE + ORDER BY 索引列：下界剪枝与逐行过滤都正确，且不扫主表" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-where-order-idx";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER NOT NULL, h INTEGER NOT NULL)");

    // 300 行，g 只有 23 个取值（大量并列）；h 与 g 同值但**不建索引**，用作对照组
    var b: usize = 0;
    while (b < 6) : (b += 1) {
        var sb: std.ArrayList(u8) = .empty;
        defer sb.deinit(alloc);
        try sb.appendSlice(alloc, "INSERT INTO t (id, g, h) VALUES ");
        for (0..50) |j| {
            const i: i64 = @intCast(b * 50 + j);
            const g: i64 = @intCast(@mod(i * 7, 23));
            try sb.appendSlice(alloc, if (j == 0) "" else ", ");
            var num: [64]u8 = undefined;
            try sb.appendSlice(alloc, try std.fmt.bufPrint(&num, "({d}, {d}, {d})", .{ i, g, g }));
        }
        try run(&eng, alloc, sb.items);
    }
    try run(&eng, alloc, "CREATE INDEX idx_g ON t (g)");

    const cases = [_]struct { by_idx: []const u8, full: []const u8, must_index: bool }{
        // 谓词 = 排序列 + `>=`：索引键给下界，直接 seek 过去
        .{ .by_idx = "SELECT id, g FROM t WHERE g >= 15 ORDER BY g ASC LIMIT 10", .full = "SELECT id, g FROM t WHERE h >= 15 ORDER BY h ASC LIMIT 10", .must_index = true },
        // 等值：下界与上界都能用前缀收死
        .{ .by_idx = "SELECT id, g FROM t WHERE g = 7 ORDER BY g LIMIT 5", .full = "SELECT id, g FROM t WHERE h = 7 ORDER BY h LIMIT 5", .must_index = true },
        // `>` / `<=` 不剪枝（值分量边界靠推断容易错），但仍逐行过滤
        .{ .by_idx = "SELECT id, g FROM t WHERE g > 15 ORDER BY g LIMIT 5", .full = "SELECT id, g FROM t WHERE h > 15 ORDER BY h LIMIT 5", .must_index = true },
        .{ .by_idx = "SELECT id, g FROM t WHERE g <= 3 ORDER BY g LIMIT 5", .full = "SELECT id, g FROM t WHERE h <= 3 ORDER BY h LIMIT 5", .must_index = true },
        // 谓词**不在**排序列上：不能剪枝，必须逐行回表判
        .{ .by_idx = "SELECT id, g FROM t WHERE h >= 15 ORDER BY g LIMIT 10", .full = "SELECT id, g FROM t WHERE g >= 15 ORDER BY h LIMIT 10", .must_index = true },
        // OFFSET：被跳过的行不占 limit 名额
        .{ .by_idx = "SELECT id, g FROM t WHERE g >= 15 ORDER BY g LIMIT 10 OFFSET 5", .full = "SELECT id, g FROM t WHERE h >= 15 ORDER BY h LIMIT 10 OFFSET 5", .must_index = true },
        // 空结果：必须返回 0 行（不许报错，也不许因为「索引路径 0 行」就回退全表）
        .{ .by_idx = "SELECT id, g FROM t WHERE g >= 1000 ORDER BY g LIMIT 5", .full = "SELECT id, g FROM t WHERE h >= 1000 ORDER BY h LIMIT 5", .must_index = true },
        // 与 NULL 比较恒不匹配：`>= NULL` 不能变成「全部行」，也不能因为给 NULL 编码而报错
        .{ .by_idx = "SELECT id, g FROM t WHERE g >= NULL ORDER BY g LIMIT 5", .full = "SELECT id, g FROM t WHERE h >= NULL ORDER BY h LIMIT 5", .must_index = true },
    };

    for (cases, 0..) |c, ci| {
        eng.get("t").?.table.scan_rows_read = 0;
        var got = try queryRows(&eng, alloc, c.by_idx);
        defer got.deinit();
        const idx_scanned = eng.get("t").?.table.scan_rows_read;

        var want = try queryRows(&eng, alloc, c.full);
        defer want.deinit();

        if (got.rows.len != want.rows.len) {
            std.debug.print("case {d}: 行数 {d} != {d}\n", .{ ci, got.rows.len, want.rows.len });
            return error.RowCountMismatch;
        }
        for (got.rows, want.rows, 0..) |gr, wr, ri| {
            if (gr[0].integer != wr[0].integer or gr[1].integer != wr[1].integer) {
                std.debug.print("case {d} 第 {d} 行: idx={any} full={any}\n", .{ ci, ri, gr, wr });
                return error.ValueMismatch;
            }
        }
        // 确定性证据：索引路径不扫主表（只有回表）
        if (c.must_index and idx_scanned != 0) {
            std.debug.print("case {d}: 走索引却扫了主表 {d} 行\n", .{ ci, idx_scanned });
            return error.IndexPathScannedTable;
        }
    }
}

// 可空列**不能**走索引排序：NULL 不入索引，走索引会把 NULL 行整批漏掉，
// 而升序里 NULL 恰恰排在最前面。这条用例钉住「宁可慢也不能少行」。
test "ORDER BY 可空索引列：NULL 行不能丢（必须回退全表，不走索引）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-order-idx-null";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER)");
    try run(&eng, alloc, "INSERT INTO t (id, g) VALUES (1, 9), (2, NULL), (3, 4), (4, NULL)");
    try run(&eng, alloc, "CREATE INDEX idx_g ON t (g)");

    eng.get("t").?.table.scan_rows_read = 0;
    var got = try queryRows(&eng, alloc, "SELECT id, g FROM t ORDER BY g ASC LIMIT 3");
    defer got.deinit();
    const scanned = eng.get("t").?.table.scan_rows_read;

    // NULL 排最前（与 SQLite 一致），然后才是 4 —— 共 3 行，一行都不能少
    try std.testing.expectEqual(@as(usize, 3), got.rows.len);
    try std.testing.expect(got.rows[0][1] == .null);
    try std.testing.expect(got.rows[1][1] == .null);
    try std.testing.expectEqual(@as(i64, 3), got.rows[2][0].integer);
    try std.testing.expect(scanned > 0); // 回退了全表路径（走索引就会漏)
}

// text 索引列：`indexPkSlice` 必须按 `0x00 0x01` 终止符切主键
// （数值是 8 字节定长，text 是转义 + 终止符 —— 两条分支都得有用例）。
test "ORDER BY NOT NULL 的 text 索引列：走索引且结果与全表一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-order-idx-text";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, alias TEXT NOT NULL)");
    try run(&eng, alloc,
        \\INSERT INTO t (id, name, alias) VALUES
        \\  (1, 'delta', 'delta'), (2, 'alpha', 'alpha'), (3, 'charlie', 'charlie'),
        \\  (4, 'bravo', 'bravo'), (5, 'echo', 'echo'), (6, 'alpha2', 'alpha2')
    );
    try run(&eng, alloc, "CREATE INDEX idx_name ON t (name)");

    eng.get("t").?.table.scan_rows_read = 0;
    var got = try queryRows(&eng, alloc, "SELECT id, name FROM t ORDER BY name ASC LIMIT 3");
    defer got.deinit();
    const scanned = eng.get("t").?.table.scan_rows_read;

    var want = try queryRows(&eng, alloc, "SELECT id, name FROM t ORDER BY alias ASC LIMIT 3");
    defer want.deinit();

    try std.testing.expectEqual(@as(usize, 3), got.rows.len);
    for (got.rows, want.rows) |gr, wr| {
        try std.testing.expectEqual(wr[0].integer, gr[0].integer);
        try std.testing.expectEqualStrings(wr[1].text, gr[1].text);
    }
    try std.testing.expectEqual(@as(i64, 2), got.rows[0][0].integer); // alpha
    try std.testing.expectEqual(@as(u64, 0), scanned); // 真走了索引
}
// boolean 索引列：**值分量是 8 字节定长**（走 `.integer` 分支），而它在行编码里只占 1 字节 ——
// 「切主键」必须按**值分量**的实际长度算，不能按行编码的长度算。
// 这条用例能抓到那个 bug：0/1 的 `encodeI64Key` 尾部恰好有 `00 01`，按 text 分支切会错位。
test "ORDER BY NOT NULL 的 boolean 索引列：值分量仍是 8 字节定长" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-engine-order-idx-bool";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    try run(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, flag BOOLEAN NOT NULL, flag2 BOOLEAN NOT NULL)");
    try run(&eng, alloc, "INSERT INTO t (id, flag, flag2) VALUES (1, 1, 1), (2, 0, 0), (3, 1, 1), (4, 0, 0), (5, 1, 1)");
    try run(&eng, alloc, "CREATE INDEX idx_flag ON t (flag)");

    eng.get("t").?.table.scan_rows_read = 0;
    var got = try queryRows(&eng, alloc, "SELECT id, flag FROM t ORDER BY flag ASC LIMIT 2");
    defer got.deinit();
    const scanned = eng.get("t").?.table.scan_rows_read;

    var want = try queryRows(&eng, alloc, "SELECT id, flag FROM t ORDER BY flag2 ASC LIMIT 2");
    defer want.deinit();

    try std.testing.expectEqual(@as(usize, 2), got.rows.len);
    for (got.rows, want.rows) |gr, wr| {
        try std.testing.expectEqual(wr[0].integer, gr[0].integer);
        try std.testing.expectEqual(wr[1].integer, gr[1].integer);
    }
    try std.testing.expectEqual(@as(i64, 2), got.rows[0][0].integer); // flag=0 且 id 最小
    try std.testing.expectEqual(@as(u64, 0), scanned); // 真走了索引
}

// 分块回填的守门用例。
//
// 为什么必须有：分块路径（`chunk_rows` 小到 7）在正式基准里跑不到（1M 行 < 4M/块），
// 而不分块时「多块各写一段、最后 compact 合并」的代码一次也不会执行。
// 这里同时钉住三件事：行数不丢、**顺序完全正确**（基数排序 + 稳定性）、
// 以及**最后只剩 1 个段**（段范围不重叠是 `get` 二分快路径的前提）。
test "索引回填分块：强制多块（每块 7 行）后必须合并成单段，内容与顺序全对" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-fill-chunk";
    const idx_root = "test-fill-chunk-idx";
    dir.deleteTree(io, root) catch {};
    dir.deleteTree(io, idx_root) catch {};
    defer dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, idx_root) catch {};

    var eng = try Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();
    {
        var p = try sql.parse(alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER, v TEXT)");
        defer p.deinit();
        _ = try eng.execute(p.stmt, alloc);
    }
    {
        var i: i64 = 0;
        while (i < 100) : (i += 1) {
            const text = try alloc.print("INSERT INTO t (id, g, v) VALUES ({d}, {d}, 'x')", .{ i, @mod(i, 10) });
            defer alloc.free(text);
            var p = try sql.parse(alloc, text);
            defer p.deinit();
            _ = try eng.execute(p.stmt, alloc);
        }
    }

    try dir.createDirPath(io, idx_root);
    var itbl = try tablemod.Table.open(io, dir, idx_root, alloc, .{ .wal_sync_every = 0 });
    defer itbl.deinit();

    const e = eng.get("t").?;
    var ph = FillPhases{};
    // chunk_rows = 7 => 100 行切成 15 块，每块各写一个段，最后 compact 合并成 1 段
    try fillIndexTimedChunks(alloc, &itbl, &e.schema, &e.table, .{ .name = "idx_g", .column_idx = 1 }, &ph, 7);
    try std.testing.expectEqual(@as(usize, 100), ph.rows);
    try std.testing.expectEqual(@as(usize, 1), itbl.segs.items.len);

    // 期望：100 个索引键 = 值分量(8) ++ 主键分量(8)，按字节序升序
    const Key = [16]u8;
    var want: std.ArrayList(Key) = .empty;
    defer want.deinit(alloc);
    for (0..100) |i| {
        var k: Key = undefined;
        _ = schema_mod.writeFixedComponent(k[0..8], .{ .integer = @intCast(i % 10) });
        _ = schema_mod.writeFixedComponent(k[8..16], .{ .integer = @intCast(i) });
        try want.append(alloc, k);
    }
    std.mem.sort(Key, want.items, {}, keyArrLess);

    var n: usize = 0;
    var it2 = tablemod.MergeIter{};
    try it2.init(&itbl, &.{}, &.{});
    defer it2.deinit();
    while (it2.next()) |rec| {
        try std.testing.expect(n < want.items.len);
        try std.testing.expectEqualSlices(u8, &want.items[n], rec.key);
        n += 1;
    }
    try std.testing.expectEqual(want.items.len, n);
}
