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
    /// `flat` 每行实际解码的列数。等于 `schema.columns.len` 时是全列解码；
    /// 小于它说明已按投影解码（`flat` 就是最终布局，`buildOutput` 无需再挑列）。
    ncols: usize = 0,

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
    values: []const []const u8,
    want: ?[]const usize,
) !Materialized {
    const ncols = if (want) |w| w.len else s.columns.len;
    var total: usize = 0;
    for (values) |v| total += v.len;

    const buf = try alloc.alloc(u8, total);
    errdefer alloc.free(buf);
    const flat = try alloc.alloc(sql.Value, values.len * ncols);
    errdefer alloc.free(flat);
    const hdrs = try alloc.alloc([]sql.Value, values.len);
    errdefer alloc.free(hdrs);

    var off: usize = 0;
    for (values, 0..) |v, i| {
        const raw = buf[off..][0..v.len];
        @memcpy(raw, v);
        off += v.len;
        const vals = flat[i * ncols ..][0..ncols];
        // `want` 非空时只解投影列，其余列仅跳过（SQLite `OP_Column` 的惰性）
        if (want) |w| try s.decodeRowProjected(vals, w, raw) else try s.decodeRowInto(vals, raw);
        hdrs[i] = vals;
    }
    return .{ .alloc = alloc, .buf = buf, .flat = flat, .hdrs = hdrs, .ncols = ncols };
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

    var identity = proj.indices.len == ncols;
    if (identity) {
        for (proj.indices, 0..) |ci, i| {
            if (ci != i) {
                identity = false;
                break;
            }
        }
    }

    // 全量（无 LIMIT/OFFSET 截断）+ 恒等投影：**直接转移 hdrs 所有权**，
    // 不再 memcpy 一份（100 万行那是 16MB 的切片头拷贝）。
    // 只有 start==0 且 end==hdrs.len 时才能转移：部分切片的长度与分配长度不同，
    // 而 `Rows.deinit` 是按 `len` 调 free 的，长度不匹配会出事。
    // 注意这一段必须在分配 out_rows **之前**，否则那条路径会把 out_rows 漏掉。
    if (identity and start == 0 and end == m.hdrs.len) {
        const out = m.hdrs;
        const flat = m.flat;
        const buf = m.buf;
        m.hdrs = &.{};
        m.flat = &.{};
        m.buf = &.{};
        return .{ .alloc = alloc, .columns = proj.columns, .rows = out, .flat = flat, .buf = buf };
    }

    // `decodeAll` 已按投影解码（`m.ncols == 投影列数`）：`flat` 就是最终布局，
    // 不用再从全列里挑。这是 `SELECT id` 比 `SELECT *` 还慢 16% 的根因修法 ——
    // 旧路径会另分配一份 `pflat` 再逐行拷 Value（100 万行 16MB）。
    if (m.ncols == proj.indices.len) {
        if (start == 0 and end == m.hdrs.len) {
            const out = m.hdrs;
            const flat = m.flat;
            const buf = m.buf;
            m.hdrs = &.{};
            m.flat = &.{};
            m.buf = &.{};
            return .{ .alloc = alloc, .columns = proj.columns, .rows = out, .flat = flat, .buf = buf };
        }
        const out_rows = try alloc.alloc([]sql.Value, n);
        errdefer alloc.free(out_rows);
        @memcpy(out_rows, m.hdrs[start..end]);
        const flat = m.flat;
        const buf = m.buf;
        m.flat = &.{};
        m.buf = &.{};
        return .{ .alloc = alloc, .columns = proj.columns, .rows = out_rows, .flat = flat, .buf = buf };
    }

    const out_rows = try alloc.alloc([]sql.Value, n);
    errdefer alloc.free(out_rows);

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
            // 聚合列不该走到这里：`selectRows` 已在入口把聚合语句分给 `selectGrouped`。
            // 留这一支是为了让编译器强制未来的新选择项被显式处理，而不是默认物化。
            .aggregate => return error.UnsupportedStatement,
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

    const one = [_][]const u8{raw};
    // 点查只要一行，额外做投影裁剪没有意义（单行解码成本可忽略），保持全列。
    var m = try decodeAll(alloc, s, &one, null);
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
    // 聚合 / GROUP BY 走独立路径：不物化原始行，只产出「每组一行」。
    // 放在最前面（ PK 点查之前），否则 `SELECT COUNT(*) FROM t WHERE id = 1` 会被
    // 当成点查返回整行。
    if (sel.group_by.len > 0 or sel.having != null or hasAggregate(sel.items)) return selectGrouped(t, s, sel, alloc);

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
    // 只收集 value 切片（16B/条），不收集 key/seq/flags（`RefRecord` 是 48B/条）。
    // 100 万行时输出量 48MB -> 16MB，而实测 `scanRefs` 占物化总耗时 66%。
    // 注意：**无 WHERE 且无 LIMIT 的主路径已经不收这个数组了**（走 `decodeAllRange` 两遍遍历），
    // 这里只服务 WHERE 过滤与 LIMIT 提前终止两条分支。
    var keep: std.ArrayList([]const u8) = .empty;
    defer keep.deinit(alloc);
    var all_vals: std.ArrayList([]const u8) = .empty;
    defer all_vals.deinit(alloc);
    // 容量上界：各段行数 + memtable 行数（段合并过时偏大，但不会重分配）。
    var cap: usize = t.mem.len();
    for (t.segs.items) |sg| cap +|= sg.rows;

    // ------------------------------------------------------------------
    // 提前终止：没有 ORDER BY 时扫描结果天然按主键升序，而 LIMIT/OFFSET 只要前
    // `offset + limit` 行 —— 凑够就能停。
    //
    // 改之前的行为是「扫全表 → 全量解码 → 最后才截断」：100 万行的表跑
    // `SELECT * FROM t LIMIT 10` 也要扫完 100 万行、解码 100 万个值再丢掉 99.999%，
    // 属于「白做的工作」，不是靠调优能弥补的量级差。
    // ------------------------------------------------------------------
    const need: ?usize = if (sel.order_by.len == 0 and sel.limit != null)
        @as(usize, sel.offset orelse 0) + @as(usize, sel.limit.?)
    else
        null;

    // `src` 指向 all_vals 或 keep（两者都在函数作用域内，defer 到函数末尾才释放）
    var src: []const []const u8 = &.{};

    if (need) |want| {
        var it = tablemod.MergeIter{};
        try it.init(t, &.{}, &hi);
        defer it.deinit(); // 只放 cursors，段数据归 Table，ref 在 deinit 后仍有效

        var scratch: ?[]sql.Value = null;
        defer if (scratch) |sc| alloc.free(sc);
        var widx: usize = 0;
        if (sel.where) |w| {
            widx = s.indexOf(w.column) orelse return error.ColumnNotFound;
            scratch = try alloc.alloc(sql.Value, s.columns.len);
        }

        try keep.ensureTotalCapacity(alloc, want);
        while (keep.items.len < want) {
            const rec = it.next() orelse break;
            if (sel.where) |w| {
                try s.decodeRowInto(scratch.?, rec.value);
                if (!evalWhere(scratch.?[widx], w.op, w.value)) continue;
            }
            try keep.append(alloc, rec.value);
        }
        src = keep.items;
    } else {
        // 有 ORDER BY 时必须看完全部候选才能排序；无 LIMIT 时必须返回全部。
        //
        // 有 WHERE 时走流式过滤：命中才 append，不先把全表 value 收进数组
        // （那会多一份 16MB 的中间数组，而且完全没有必要 —— `MergeIter` 本来就是流式的）。
        if (sel.where) |w| {
            const widx = s.indexOf(w.column) orelse return error.ColumnNotFound;
            const scratch = try alloc.alloc(sql.Value, s.columns.len);
            defer alloc.free(scratch);
            // **不要按全表上界预分配**：WHERE 的选择性事先完全未知，而 `cap` 是全表行数
            // 上界 —— 200 万行的表跑一个只命中几行的条件会白占 32MB（审计 P1）。
            // 命中多时 ArrayList 会按 2× 自然增长，那点拷贝远小于白占的内存。
            try keep.ensureTotalCapacity(alloc, @min(cap, 4096));
            var it = tablemod.MergeIter{};
            try it.init(t, &.{}, &hi);
            defer it.deinit();
            while (it.next()) |rec| {
                try s.decodeRowInto(scratch, rec.value);
                if (evalWhere(scratch[widx], w.op, w.value)) try keep.append(alloc, rec.value);
            }
            src = keep.items;
        } else {
            // 无 WHERE：cap 接近实际行数，预分配能避免重分配；
            // 但段合并过（大量覆盖/墓碑）时 cap 可能远大于实际，所以封顶 100 万条（16MB）。
            //
            // **这里曾经试过「两遍遍历直接解码」（省掉这 16MB 切片数组），实测是负优化**：
            // 省下的是 16B/条的连续写（约 3ms/100 万行），多付的是一整遍 k 路归并
            // （25 段 100 万行 ≈ 25ms）→ `sql_full` 18.63M → 12.86M（-31%）。
            // 对比 `Table.scanRange` 那个同款改法却是正收益：那里省的是 48B/条（RefRecord）
            // 且只有 20 万行，多一遍归并只 3.6ms。**同一种改法在不同规模下结论相反。**
            try all_vals.ensureTotalCapacity(alloc, @min(cap, 1 << 20));
            try t.scanValues(&[_]u8{}, &hi, &all_vals);
            src = all_vals.items;
        }
    }

    const proj = try buildProjection(alloc, s, sel.items);
    errdefer {
        for (proj.columns) |c| alloc.free(c);
        alloc.free(proj.columns);
        // `proj.indices` 平时由 `buildOutput` 的 defer 释放；但若下面提前返回（
        // decodeAll 失败），这里必须自己收拾。
        alloc.free(proj.indices);
    }

    // 有 ORDER BY 时排序键按**全列**索引取（`SortCtx` 用 `schema.indexOf`），
    // 所以那种情况下不能按投影解码。
    //
    // 另外 `decodeRowProjected` 是「一趟顺序扫描时顺手跳过未投影列」，要求 want **严格升序**；
    // 而 `SELECT v, id` 会给出 [1,0]、`SELECT id, id` 会给出重复下标 —— 这些都得退回全列解码。
    const ascending = blk: {
        for (proj.indices, 0..) |v, k| {
            if (k > 0 and v <= proj.indices[k - 1]) break :blk false;
        }
        break :blk true;
    };
    const want: ?[]const usize = if (sel.order_by.len == 0 and ascending) proj.indices else null;
    var m = try decodeAll(alloc, s, src, want);
    defer m.deinit();

    if (sel.order_by.len > 0) {
        const ctx = SortCtx{ .schema = s, .order = sel.order_by };
        std.mem.sort([]sql.Value, m.hdrs, ctx, rowLess);
    }

    var start: usize = 0;
    if (sel.offset) |o| start = @min(@as(usize, o), m.hdrs.len);
    var end: usize = m.hdrs.len;
    if (sel.limit) |l| end = @min(end, start + @as(usize, l));

    return buildOutput(alloc, s, &m, proj, start, end);
}

/// 流式查询：逐行解码到**复用的 scratch**，回调消费，**不物化结果集**。
///
/// 这是 SQLite `sqlite3_step` 的等价物（PostgreSQL 的 slot、DuckDB 的 chunk 同理）。
/// 成熟数据库一律不把结果集攒在内存里，而是「游标 + 复用槽位」：
/// `sqlite3_step` 每步只重填 `ncols` 个 `Mem`，整个查询期间结果集侧的分配是 **0**。
///
/// 对比一下我们的 `selectRows`：100 万行 × 2 列要分配
/// `flat` 48MB + `buf` 32MB + `hdrs` 16MB ≈ 96MB，而真实数据只有 32MB。
/// 这段差距不是「算法慢」，是**接口逼着物化**——在 `selectRows` 里再怎么调优也填不平。
///
/// 回调收到的一行**只在回调期间有效**：text/blob 直接指向段 mmap / memtable 缓冲。
/// 要保留必须自己复制。这是省掉 96MB 的代价，也是这个 API 唯一的坑。
///
/// 有 ORDER BY 时无法流式（排序天然要看完全部候选），内部回退到 `selectRows`。
// ---------------------------------------------------------------- 聚合 / GROUP BY

/// 单个聚合的累加器。
///
/// 整数与浮点分开累加：SQLite 的 `SUM` 在「所有输入都是整数」时返回整数，
/// 一旦出现浮点就整体转浮点。用 i128 装整数和，避免 100 万行 × 大值就溢出。
const AggAcc = struct {
    /// `COUNT(*)` 与 `COUNT(col)`（非 null）共用；`SUM`/`AVG` 也用它记非空个数。
    count: u64 = 0,
    sum_i: i128 = 0,
    sum_f: f64 = 0,
    any_real: bool = false,
    min_v: sql.Value = .null,
    max_v: sql.Value = .null,
};

const AggSpec = struct {
    func: sql.AggFunc,
    /// `null` 仅用于 `COUNT(*)`。
    col_idx: ?usize = null,
};

const Group = struct {
    /// 分组键值（按 `GROUP BY` 书写顺序）；text/blob 已复制进 arena。
    keys: []sql.Value,
    aggs: []AggAcc,
};

/// 输出列来源：分组键的第 k 个，或第 k 个聚合。
const OutSrc = union(enum) { grp: usize, agg: usize };

fn aggFuncName(f: sql.AggFunc) []const u8 {
    return switch (f) {
        .count => "count",
        .sum => "sum",
        .avg => "avg",
        .min => "min",
        .max => "max",
    };
}

fn isNullValue(v: sql.Value) bool {
    return switch (v) {
        .null => true,
        else => false,
    };
}

/// 把值复制进长生命周期分配器（text/blob 加拷贝，其余按值）。
fn ownValue(a: std.mem.Allocator, v: sql.Value) !sql.Value {
    return switch (v) {
        .text => |s| .{ .text = try a.dupe(u8, s) },
        .blob => |s| .{ .blob = try a.dupe(u8, s) },
        else => v,
    };
}

fn appendVarint(out: *std.ArrayList(u8), alloc: std.mem.Allocator, n: usize) !void {
    var v = n;
    while (true) {
        var b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) b |= 0x80;
        try out.append(alloc, b);
        if (v == 0) break;
    }
}

/// 分组键编码：类型标签 + 定长/长度前缀，保证不同值不同编码、同值同编码。
///
/// 不按 `valueCmp` 语义归一（例如 int 1 与 real 1.0 相等）——
/// 同一列的数据类型固定，跨类型混排只可能来自手工构造的测试数据。
fn appendKeyPart(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: sql.Value) !void {
    switch (v) {
        .null => try out.append(alloc, 0),
        .integer => |x| {
            try out.append(alloc, 1);
            try out.appendSlice(alloc, &@as([8]u8, @bitCast(x)));
        },
        .real => |x| {
            try out.append(alloc, 2);
            try out.appendSlice(alloc, &@as([8]u8, @bitCast(x)));
        },
        .text => |s| {
            try out.append(alloc, 3);
            try appendVarint(out, alloc, s.len);
            try out.appendSlice(alloc, s);
        },
        .blob => |s| {
            try out.append(alloc, 4);
            try appendVarint(out, alloc, s.len);
            try out.appendSlice(alloc, s);
        },
    }
}

pub fn hasAggregate(items: []const sql.SelectItem) bool {
    for (items) |it| {
        switch (it) {
            .aggregate => return true,
            else => {},
        }
    }
    return false;
}

/// 输出行排序上下文：聚合结果的 `ORDER BY` 按**输出列名**匹配
/// （`ORDER BY g` / `ORDER BY count(*)`），因为分组后已无原始行可比。
const GroupSortCtx = struct {
    flat: []const sql.Value,
    ncols: usize,
    order: []const sql.OrderItem,
    /// 与 `order` 一一对应的输出列下标（排序前解析一次）。
    /// 不在比较函数里按列名查 —— 10 万组时那是 n·log n 次字符串比较。
    cols: []const usize,
};

fn groupRowLess(ctx: GroupSortCtx, a: usize, b: usize) bool {
    for (ctx.order, ctx.cols) |o, ci| {
        const ord = schema_mod.valueCmp(ctx.flat[a * ctx.ncols + ci], ctx.flat[b * ctx.ncols + ci]);
        if (ord == .eq) continue;
        return if (o.desc) ord == .gt else ord == .lt;
    }
    return false;
}

fn accValue(acc: *const AggAcc, func: sql.AggFunc) !sql.Value {
    return switch (func) {
        .count => .{ .integer = @intCast(acc.count) },
        .sum => blk: {
            if (acc.count == 0) break :blk .null; // SQL：对空集求和是 NULL，不是 0
            if (acc.any_real) {
                break :blk .{ .real = @as(f64, @floatFromInt(acc.sum_i)) + acc.sum_f };
            }
            break :blk .{ .integer = std.math.cast(i64, acc.sum_i) orelse return error.IntegerOverflow };
        },
        .avg => blk: {
            if (acc.count == 0) break :blk .null; // AVG 恒为浮点（SQLite 同）
            const total = @as(f64, @floatFromInt(acc.sum_i)) + acc.sum_f;
            break :blk .{ .real = total / @as(f64, @floatFromInt(acc.count)) };
        },
        .min => acc.min_v,
        .max => acc.max_v,
    };
}

/// `GROUP BY` + 聚合。无 `GROUP BY` 时整表当作一个组（SQL 语义，空表也返回一行）。
///
/// 与 `selectRows` 的分工：这条路径只扫描、聚合、产出**每组一行**，
/// 不物化任何原始行 —— 100 万行聚合 10 万组时内存是「组数 × 列数」而不是「行数 × 列数」。
fn selectGrouped(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
) !Rows {
    const ncols = s.columns.len;

    // ---- 1) 解析分组键与聚合参数，并建立「输出列 ← 来源」映射 ----
    const gidx = try alloc.alloc(usize, sel.group_by.len);
    defer alloc.free(gidx);
    for (sel.group_by, 0..) |name, i| gidx[i] = s.indexOf(name) orelse return error.ColumnNotFound;

    var specs: std.ArrayList(AggSpec) = .empty;
    defer specs.deinit(alloc);
    const src_of = try alloc.alloc(OutSrc, sel.items.len);
    defer alloc.free(src_of);

    var n_agg: usize = 0;
    for (sel.items, 0..) |item, i| {
        switch (item) {
            // `SELECT *, COUNT(*)` 没有定义：* 展开的原始行与聚合行无法共存
            .star => return error.UnsupportedStatement,
            .column => |c| {
                const ci = s.indexOf(c) orelse return error.ColumnNotFound;
                var k: ?usize = null;
                for (gidx, 0..) |g, gi| {
                    if (g == ci) {
                        k = gi;
                        break;
                    }
                }
                // 非分组列在聚合查询里「取任意一行」是 SQLite 的放任行为，我们不猜：
                // 直接拒绝，避免同一条语句在不同引擎给出不同结果。
                src_of[i] = .{ .grp = k orelse return error.UnsupportedStatement };
            },
            .aggregate => |a| {
                const ci: ?usize = if (a.column) |c| (s.indexOf(c) orelse return error.ColumnNotFound) else null;
                try specs.append(alloc, .{ .func = a.func, .col_idx = ci });
                src_of[i] = .{ .agg = n_agg };
                n_agg += 1;
            },
        }
    }

    // ---- 1.5) HAVING 的聚合可能不在选择列表里 ----
    //
    // `SELECT g FROM t GROUP BY g HAVING COUNT(*) > 1` 就是这种：`COUNT(*)` 只用于过滤，
    // 不输出。这种情况下在 specs 末尾补一个槽（只算不输出），
    // 已存在的聚合则直接复用，避免同一个聚合算两遍。
    var having_spec: ?usize = null;
    if (sel.having) |hv| {
        const hci: ?usize = if (hv.agg.column) |c| (s.indexOf(c) orelse return error.ColumnNotFound) else null;
        for (specs.items, 0..) |sp, k| {
            if (sp.func == hv.agg.func and sp.col_idx == hci) {
                having_spec = k;
                break;
            }
        }
        if (having_spec == null) {
            try specs.append(alloc, .{ .func = hv.agg.func, .col_idx = hci });
            having_spec = specs.items.len - 1;
        }
    }

    // ---- 2) 只解码真正要用的列（分组键 / 聚合参数 / WHERE 列）----
    const need = try alloc.alloc(bool, ncols);
    defer alloc.free(need);
    @memset(need, false);
    for (gidx) |i| need[i] = true;
    for (specs.items) |sp| {
        if (sp.col_idx) |ci| need[ci] = true;
    }
    var where_idx: ?usize = null;
    if (sel.where) |w| {
        const wi = s.indexOf(w.column) orelse return error.ColumnNotFound;
        need[wi] = true;
        where_idx = wi;
    }
    var want: std.ArrayList(usize) = .empty;
    defer want.deinit(alloc);
    const pos_of = try alloc.alloc(usize, ncols);
    defer alloc.free(pos_of);
    for (need, 0..) |n, i| {
        if (!n) continue;
        pos_of[i] = want.items.len;
        try want.append(alloc, i);
    }

    // ---- 3) 扫描 + 聚合 ----
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var groups: std.ArrayList(Group) = .empty;
    var map = std.StringHashMap(usize).init(arena);
    // 单列整数分组键的快路径：不拼字节串、不哈希变长 key。
    // 实测 100 万行 / 10 万组时，字节编码路径每行要 append 9 字节 + 哈希变长切片，
    // 这是与 SQLite 差距的主要来源（SQLite 的 GROUP BY 直接用 i64 做键）。
    var map_int = std.AutoHashMap(?i64, usize).init(arena);
    const int_key: bool = blk: {
        if (gidx.len != 1) break :blk false;
        break :blk switch (s.columns[gidx[0]].col_type) {
            .integer, .bigint, .boolean, .datetime => true,
            else => false,
        };
    };
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);

    const scratch = try alloc.alloc(sql.Value, want.items.len);
    defer alloc.free(scratch);

    if (sel.group_by.len == 0) {
        // 全局聚合：先建唯一一组，空表时 COUNT=0 / SUM=NULL 也符合 SQL
        try groups.append(arena, .{ .keys = &.{}, .aggs = try arena.alloc(AggAcc, specs.items.len) });
        for (groups.items[0].aggs) |*a| a.* = .{};
    }

    var hi: [16]u8 = @splat(0xFF);
    var it = tablemod.MergeIter{};
    try it.init(t, &.{}, &hi);
    defer it.deinit();

    while (it.next()) |rec| {
        try s.decodeRowProjected(scratch, want.items, rec.value);
        if (sel.where) |w| {
            if (!evalWhere(scratch[pos_of[where_idx.?]], w.op, w.value)) continue;
        }

        var slot: usize = 0;
        if (sel.group_by.len > 0) {
            if (int_key) {
                // 快路径：整数键直接进 `AutoHashMap(?i64)`；NULL 用 null 作键（不用哨兵值，
                // 免得和真实数据里的 minInt(i64) 撞车）。
                const v = scratch[pos_of[gidx[0]]];
                const iv: ?i64 = switch (v) {
                    .null => null,
                    .integer => |x| x,
                    else => return error.TypeMismatch,
                };
                const gop = try map_int.getOrPut(iv);
                if (!gop.found_existing) {
                    const new_keys = try arena.alloc(sql.Value, 1);
                    new_keys[0] = v; // 整数/NULL 按值，无需复制
                    const aggs = try arena.alloc(AggAcc, specs.items.len);
                    for (aggs) |*a| a.* = .{};
                    gop.value_ptr.* = groups.items.len;
                    try groups.append(arena, .{ .keys = new_keys, .aggs = aggs });
                }
                slot = gop.value_ptr.*;
            } else {
                key.clearRetainingCapacity();
                for (gidx) |gi| try appendKeyPart(&key, alloc, scratch[pos_of[gi]]);
                // getOrPut 先用**临时缓冲**查：命中就不分配。
                // 未命中时把 key_ptr 换成 arena 里的副本 —— 哈希按内容算，等值替换安全。
                const gop = try map.getOrPut(key.items);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try arena.dupe(u8, key.items);
                    const new_keys = try arena.alloc(sql.Value, gidx.len);
                    for (gidx, 0..) |gi, k| new_keys[k] = try ownValue(arena, scratch[pos_of[gi]]);
                    const aggs = try arena.alloc(AggAcc, specs.items.len);
                    for (aggs) |*a| a.* = .{};
                    gop.value_ptr.* = groups.items.len;
                    try groups.append(arena, .{ .keys = new_keys, .aggs = aggs });
                }
                slot = gop.value_ptr.*;
            }
        }

        const g = &groups.items[slot];
        for (specs.items, 0..) |sp, k| {
            const acc = &g.aggs[k];
            if (sp.func == .count and sp.col_idx == null) {
                acc.count += 1; // COUNT(*) 数行，不看值
                continue;
            }
            const v = scratch[pos_of[sp.col_idx.?]];
            switch (sp.func) {
                .count => {
                    if (!isNullValue(v)) acc.count += 1; // COUNT(col) 数非空
                },
                .sum, .avg => switch (v) {
                    .null => {},
                    .integer => |x| {
                        acc.sum_i += x;
                        acc.count += 1;
                    },
                    .real => |x| {
                        acc.sum_f += x;
                        acc.any_real = true;
                        acc.count += 1;
                    },
                    else => return error.TypeMismatch, // SUM/AVG 对 text 无意义
                },
                .min => {
                    if (!isNullValue(v) and (isNullValue(acc.min_v) or schema_mod.valueCmp(v, acc.min_v) == .lt)) {
                        acc.min_v = try ownValue(arena, v);
                    }
                },
                .max => {
                    if (!isNullValue(v) and (isNullValue(acc.max_v) or schema_mod.valueCmp(v, acc.max_v) == .gt)) {
                        acc.max_v = try ownValue(arena, v);
                    }
                },
            }
        }
    }

    // ---- 4) 输出列名 ----
    const out_n = sel.items.len;
    const columns = try alloc.alloc([]const u8, out_n);
    var cols_done: usize = 0;
    errdefer {
        for (columns[0..cols_done]) |c| alloc.free(c);
        alloc.free(columns);
    }
    for (sel.items, 0..) |item, i| {
        columns[i] = switch (item) {
            .star => unreachable,
            .column => |c| try alloc.dupe(u8, s.columns[s.indexOf(c).?].name),
            .aggregate => |a| if (a.column) |c|
                try alloc.print("{s}({s})", .{ aggFuncName(a.func), c })
            else
                try alloc.print("{s}(*)", .{aggFuncName(a.func)}),
        };
        cols_done += 1;
    }

    // ---- 5) 每组算一行，再按 HAVING / ORDER BY / LIMIT 取子集 ----
    //
    // SQL 语义：聚合值为 NULL 时比较结果是 unknown → 整组被过滤掉（不是当作 0 参与比较）。
    var kept: std.ArrayList(usize) = .empty;
    if (sel.having) |hv| {
        const hs = having_spec.?;
        for (groups.items, 0..) |*g, gi| {
            const hv_val = try accValue(&g.aggs[hs], specs.items[hs].func);
            if (isNullValue(hv_val)) continue;
            if (evalWhere(hv_val, hv.op, hv.value)) try kept.append(arena, gi);
        }
    } else {
        for (0..groups.items.len) |gi| try kept.append(arena, gi);
    }

    const nkeep = kept.items.len;
    const flat0 = try alloc.alloc(sql.Value, nkeep * out_n);
    defer alloc.free(flat0);
    for (kept.items, 0..) |gi, r| {
        const g = &groups.items[gi];
        for (src_of, 0..) |src, ci| {
            flat0[r * out_n + ci] = switch (src) {
                .grp => |k| g.keys[k],
                .agg => |k| try accValue(&g.aggs[k], specs.items[k].func),
            };
        }
    }

    const order_idx = try alloc.alloc(usize, nkeep);
    defer alloc.free(order_idx);
    for (order_idx, 0..) |*p, i| p.* = i;
    if (sel.order_by.len > 0) {
        // 排序键先解析成输出列下标；列名不存在时报错，而不是静默不排序
        const order_cols = try alloc.alloc(usize, sel.order_by.len);
        defer alloc.free(order_cols);
        for (sel.order_by, 0..) |o, k| {
            var found: ?usize = null;
            for (columns, 0..) |cn, ci| {
                if (std.ascii.eqlIgnoreCase(cn, o.column)) {
                    found = ci;
                    break;
                }
            }
            order_cols[k] = found orelse return error.ColumnNotFound;
        }
        const ctx = GroupSortCtx{ .flat = flat0, .ncols = out_n, .order = sel.order_by, .cols = order_cols };
        std.mem.sort(usize, order_idx, ctx, groupRowLess);
    }

    var start: usize = 0;
    if (sel.offset) |o| start = @min(@as(usize, o), nkeep);
    var end: usize = nkeep;
    if (sel.limit) |l| end = @min(end, start + @as(usize, l));
    const m = end - start;

    const flat = try alloc.alloc(sql.Value, m * out_n);
    errdefer alloc.free(flat);
    var text_total: usize = 0;
    for (order_idx[start..end], 0..) |gi, r| {
        for (0..out_n) |ci| {
            const v = flat0[gi * out_n + ci];
            flat[r * out_n + ci] = v;
            switch (v) {
                .text => |x| text_total += x.len,
                .blob => |x| text_total += x.len,
                else => {},
            }
        }
    }

    // text/blob 从 arena 复制进 Rows 自己的缓冲：arena 在返回前就销毁了
    const buf = try alloc.alloc(u8, text_total);
    errdefer alloc.free(buf);
    var off: usize = 0;
    for (flat) |*v| {
        switch (v.*) {
            .text => |x| {
                @memcpy(buf[off..][0..x.len], x);
                v.* = .{ .text = buf[off..][0..x.len] };
                off += x.len;
            },
            .blob => |x| {
                @memcpy(buf[off..][0..x.len], x);
                v.* = .{ .blob = buf[off..][0..x.len] };
                off += x.len;
            },
            else => {},
        }
    }

    const rows = try alloc.alloc([]sql.Value, m);
    errdefer alloc.free(rows);
    for (0..m) |i| rows[i] = flat[i * out_n ..][0..out_n];

    return .{ .alloc = alloc, .columns = columns, .rows = rows, .flat = flat, .buf = buf };
}

pub fn forEachRow(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
    ctx: anytype,
    cb: anytype,
) !usize {
    // PK 等值 / ORDER BY 这两条路本来就只需一行或必须全量，物化代价可忽略，
    // 直接复用 `selectRows` 的既有逻辑再回放，避免两处各写一份语义。
    // 聚合也归入这条：流式 API 回放的应该是「每组一行」的结果，而不是原始行。
    const must_materialize = blk: {
        if (sel.group_by.len > 0 or sel.having != null or hasAggregate(sel.items)) break :blk true;
        if (sel.order_by.len > 0) break :blk true;
        if (sel.where) |w| {
            if (w.op == .eq) {
                if (s.indexOf(w.column)) |idx| {
                    if (idx == s.pk_index) break :blk true;
                }
            }
        }
        break :blk false;
    };
    if (must_materialize) {
        var rows = try selectRows(t, s, sel, alloc);
        defer rows.deinit();
        for (rows.rows) |r| try cb(ctx, r);
        return rows.rows.len;
    }

    const proj = try buildProjection(alloc, s, sel.items);
    defer {
        for (proj.columns) |c| alloc.free(c);
        alloc.free(proj.columns);
        alloc.free(proj.indices);
    }

    // 全列复用槽位：每行都写回这一份，绝不按行分配。
    const scratch = try alloc.alloc(sql.Value, s.columns.len);
    defer alloc.free(scratch);

    var identity = proj.indices.len == s.columns.len;
    if (identity) {
        for (proj.indices, 0..) |ci, i| {
            if (ci != i) {
                identity = false;
                break;
            }
        }
    }
    // 非恒等投影：复用同一个小缓冲，每行只搬选中的列（不按行分配）。
    const pbuf = try alloc.alloc(sql.Value, proj.indices.len);
    defer alloc.free(pbuf);

    const widx: ?usize = if (sel.where) |w| s.indexOf(w.column) orelse return error.ColumnNotFound else null;
    const off: usize = sel.offset orelse 0;
    const lim: ?usize = if (sel.limit) |l| @as(usize, l) else null;

    var seen: usize = 0;
    var emitted: usize = 0;

    var hi: [16]u8 = @splat(0xFF);
    var it = tablemod.MergeIter{};
    try it.init(t, &.{}, &hi);
    defer it.deinit();

    while (it.next()) |rec| {
        // 先判 LIMIT 再解码：凑够了就停，不多解一行（与 `selectRows` 的提前终止同口径）。
        if (lim) |l| {
            if (emitted >= l) break;
        }
        try s.decodeRowInto(scratch, rec.value);
        if (sel.where) |w| {
            if (!evalWhere(scratch[widx.?], w.op, w.value)) continue;
        }
        seen += 1;
        if (seen <= off) continue;
        if (identity) {
            try cb(ctx, scratch);
        } else {
            for (proj.indices, 0..) |ci, k| pbuf[k] = scratch[ci];
            try cb(ctx, pbuf);
        }
        emitted += 1;
    }
    return emitted;
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


test "select LIMIT 提前终止：只读 offset+limit 行，不扫全表" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-limit-early";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "age", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "t", &cols);
    defer s.deinit(alloc);

    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    // 200 行，age 全部 30，便于构造 WHERE 全匹配/全不匹配
    {
        var sqlbuf: std.ArrayList(u8) = .empty;
        defer sqlbuf.deinit(alloc);
        try sqlbuf.appendSlice(alloc, "INSERT INTO t (id, age) VALUES ");
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            if (i > 0) try sqlbuf.appendSlice(alloc, ", ");
            var num_buf: [32]u8 = undefined;
            try sqlbuf.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "({d}, 30)", .{i}));
        }
        var p = try sql.parse(alloc, sqlbuf.items);
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    const cases = [_]struct { q: []const u8, want: usize, read: u64 }{
        .{ .q = "SELECT * FROM t LIMIT 5", .want = 5, .read = 5 },
        .{ .q = "SELECT * FROM t LIMIT 5 OFFSET 7", .want = 5, .read = 12 },
        // WHERE 全不匹配时必须扫完（否则会错报 0 行是因为「提前停了」还是「真的没有」）
        .{ .q = "SELECT * FROM t WHERE age = 99 LIMIT 5", .want = 0, .read = 200 },
        // WHERE 全匹配时只需凑够 5 行
        .{ .q = "SELECT * FROM t WHERE age = 30 LIMIT 5", .want = 5, .read = 5 },
        // 有 ORDER BY 必须全扫（否则排序结果错），这是有意保留的全量路径
        .{ .q = "SELECT * FROM t ORDER BY age DESC LIMIT 5", .want = 5, .read = 200 },
    };

    for (cases) |c| {
        var p = try sql.parse(alloc, c.q);
        defer p.deinit();
        t.scan_rows_read = 0;
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(c.want, rows.rows.len);
        try std.testing.expectEqual(c.read, t.scan_rows_read);
    }
}


const Collect = struct {
    rows: std.ArrayList([]sql.Value) = .empty,
    alloc: std.mem.Allocator,

    /// **必须深拷贝 text/blob**：流式 API 的回调参数只在回调期间有效
    /// （text 指向段 mmap / memtable / 物化回退的临时 buf）。只存 Value 数组会留下野指针。
    fn add(self: *Collect, row: []const sql.Value) !void {
        const dup = try self.alloc.alloc(sql.Value, row.len);
        errdefer self.alloc.free(dup);
        var filled: usize = 0;
        errdefer for (dup[0..filled]) |v| switch (v) {
            .text => |s| self.alloc.free(s),
            .blob => |s| self.alloc.free(s),
            else => {},
        };
        for (row, 0..) |v, i| {
            dup[i] = switch (v) {
                .text => |s| .{ .text = try self.alloc.dupe(u8, s) },
                .blob => |s| .{ .blob = try self.alloc.dupe(u8, s) },
                else => v,
            };
            filled += 1;
        }
        try self.rows.append(self.alloc, dup);
    }

    fn deinit(self: *Collect) void {
        for (self.rows.items) |r| {
            for (r) |v| switch (v) {
                .text => |s| self.alloc.free(s),
                .blob => |s| self.alloc.free(s),
                else => {},
            };
            self.alloc.free(r);
        }
        self.rows.deinit(self.alloc);
    }
};

test "forEachRow 与 selectRows 结果逐行一致（where/limit/offset/投影/排序/PK 等值）" {
    // 流式 API 省掉整个结果集物化，但如果结果和物化路径不一致就是灾难。
    // 两条路径在同一张表上跑同一批语句，逐行逐列比对。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-each-tmp";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "n", .col_type = .integer },
        .{ .name = "s", .col_type = .text },
    };
    var s = try schema_mod.Schema.init(alloc, "t", &cols);
    defer s.deinit(alloc);
    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    var i: i64 = 0;
    while (i < 200) : (i += 1) {
        var vals = [_]sql.Value{ .{ .integer = i }, .{ .integer = @mod(i, 7) }, .{ .text = "x" } };
        var row = [_][]sql.Value{&vals};
        _ = try insertRows(&t, &s, .{ .table = "t", .columns = &.{ "id", "n", "s" }, .rows = &row }, alloc);
    }

    var star = [_]sql.SelectItem{.{ .star = {} }};
    var only_id = [_]sql.SelectItem{.{ .column = "id" }};
    var two = [_]sql.SelectItem{ .{ .column = "n" }, .{ .column = "id" } };
    var order_desc = [_]sql.OrderItem{.{ .column = "id", .desc = true }};
    const w_n3 = sql.Expr{ .column = "n", .op = .eq, .value = .{ .integer = 3 } };
    const w_id42 = sql.Expr{ .column = "id", .op = .eq, .value = .{ .integer = 42 } };

    // 聚合路径也要能经 `forEachRow` 回放（内部归入 must_materialize），
    // 且回放结果与 `selectRows` 逐行一致。
    var agg_items = [_]sql.SelectItem{
        .{ .column = "n" },
        .{ .aggregate = .{ .func = .count, .column = null } },
        .{ .aggregate = .{ .func = .sum, .column = "id" } },
    };
    var gb_n = [_][]const u8{"n"};

    const cases = [_]sql.Select{
        .{ .items = &star, .table = "t" },
        .{ .items = &star, .table = "t", .where = w_n3 },
        .{ .items = &star, .table = "t", .limit = 7 },
        .{ .items = &star, .table = "t", .offset = 5, .limit = 7 },
        .{ .items = &only_id, .table = "t", .limit = 11 },
        .{ .items = &two, .table = "t", .offset = 3, .limit = 9 },
        .{ .items = &star, .table = "t", .order_by = &order_desc, .limit = 5 },
        .{ .items = &star, .table = "t", .where = w_id42 },
        .{ .items = &star, .table = "t", .limit = 0 },
        .{ .items = &agg_items, .table = "t", .group_by = &gb_n },
        .{ .items = &agg_items, .table = "t", .group_by = &gb_n, .where = w_n3 },
    };

    for (cases, 0..) |sel, ci| {
        var mat = try selectRows(&t, &s, sel, alloc);
        defer mat.deinit();
        var col = Collect{ .alloc = alloc };
        defer col.deinit();
        const n = try forEachRow(&t, &s, sel, alloc, &col, Collect.add);
        if (n != mat.rows.len or n != col.rows.items.len) {
            std.debug.print("case {d}: 行数不一致 each={d} mat={d} got={d}\n", .{ ci, n, mat.rows.len, col.rows.items.len });
            return error.RowCountMismatch;
        }
        for (mat.rows, col.rows.items) |want, got| {
            if (want.len != got.len) return error.ColCountMismatch;
            for (want, got) |w, g| {
                if (schema_mod.valueCmp(w, g) != .eq) {
                    std.debug.print("case {d}: 值不一致\n", .{ci});
                    return error.ValueMismatch;
                }
            }
        }
    }
}

test "GROUP BY：COUNT/SUM/AVG/MIN/MAX 与手算逐一对照" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-group";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "g", .col_type = .integer },
        .{ .name = "x", .col_type = .integer },
        .{ .name = "t", .col_type = .text },
    };
    var s = try schema_mod.Schema.init(alloc, "agg", &cols);
    defer s.deinit(alloc);

    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    {
        // g=1 两行全有值；g=2 三行里有一行 x/t 为 NULL（COUNT(col) 与 COUNT(*) 才会分叉）
        var p = try sql.parse(alloc,
            "INSERT INTO agg (id, g, x, t) VALUES (1, 1, 10, 'a'), (2, 1, 20, 'b'), " ++
                "(3, 2, 5, 'c'), (4, 2, NULL, NULL), (5, 2, 7, 'e')");
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    {
        var p = try sql.parse(alloc,
            "SELECT g, COUNT(*), COUNT(x), SUM(x), AVG(x), MIN(x), MAX(x) FROM agg GROUP BY g ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();

        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqualStrings("g", rows.columns[0]);
        try std.testing.expectEqualStrings("count(*)", rows.columns[1]);
        try std.testing.expectEqualStrings("count(x)", rows.columns[2]);
        try std.testing.expectEqualStrings("sum(x)", rows.columns[3]);

        // g = 1
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 2), rows.rows[0][1].integer); // COUNT(*)
        try std.testing.expectEqual(@as(i64, 2), rows.rows[0][2].integer); // COUNT(x)
        try std.testing.expectEqual(@as(i64, 30), rows.rows[0][3].integer); // SUM 全整数 -> 整数
        try std.testing.expectEqual(@as(f64, 15.0), rows.rows[0][4].real); // AVG 恒浮点
        try std.testing.expectEqual(@as(i64, 10), rows.rows[0][5].integer);
        try std.testing.expectEqual(@as(i64, 20), rows.rows[0][6].integer);

        // g = 2：COUNT(*) 数 3 行，COUNT(x) 只数 2 个非空
        try std.testing.expectEqual(@as(i64, 2), rows.rows[1][0].integer);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[1][1].integer);
        try std.testing.expectEqual(@as(i64, 2), rows.rows[1][2].integer);
        try std.testing.expectEqual(@as(i64, 12), rows.rows[1][3].integer);
        try std.testing.expectEqual(@as(f64, 6.0), rows.rows[1][4].real);
        try std.testing.expectEqual(@as(i64, 5), rows.rows[1][5].integer); // MIN 忽略 NULL
        try std.testing.expectEqual(@as(i64, 7), rows.rows[1][6].integer);
    }

    // 文本分组键 + MIN/MAX 文本 + ORDER BY 聚合列 DESC + LIMIT
    {
        var p = try sql.parse(alloc,
            "SELECT t, COUNT(*), MIN(id), MAX(id) FROM agg GROUP BY t ORDER BY count(*) DESC LIMIT 2");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        // 每个 t 都是唯一值（a/b/c/e 各 1 行，NULL 1 行）：按 count(*) 全为 1，
        // 排序稳定与否不参与断言，只验分组数与文本值可用
        for (rows.rows) |r| {
            try std.testing.expectEqual(@as(i64, 1), r[1].integer);
        }
    }
}

test "聚合：空表 / 全局聚合 / WHERE 过滤 的边界语义" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-agg-empty";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "g", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "agg2", &cols);
    defer s.deinit(alloc);

    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    // 空表 + 全局聚合：必须返回 1 行（COUNT=0、SUM/MIN/MAX 为 NULL），不能返回 0 行
    {
        var p = try sql.parse(alloc, "SELECT COUNT(*), SUM(g), MIN(g), MAX(g), AVG(g) FROM agg2");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 0), rows.rows[0][0].integer);
        try std.testing.expect(isNullValue(rows.rows[0][1]));
        try std.testing.expect(isNullValue(rows.rows[0][2]));
        try std.testing.expect(isNullValue(rows.rows[0][3]));
        try std.testing.expect(isNullValue(rows.rows[0][4]));
    }

    // 空表 + GROUP BY：必须返回 0 行
    {
        var p = try sql.parse(alloc, "SELECT g, COUNT(*) FROM agg2 GROUP BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 0), rows.rows.len);
    }

    {
        var p = try sql.parse(alloc, "INSERT INTO agg2 (id, g) VALUES (1, 7), (2, 8), (3, 9)");
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    // WHERE 先过滤再聚合（不是聚合后过滤）
    {
        var p = try sql.parse(alloc, "SELECT COUNT(*), SUM(g) FROM agg2 WHERE g > 7");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 2), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 17), rows.rows[0][1].integer);
    }

    // 聚合 + 主键等值：不能被当成 PK 点查返回整行
    {
        var p = try sql.parse(alloc, "SELECT COUNT(*) FROM agg2 WHERE id = 2");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
    }
}

test "聚合：非分组列被拒绝（不猜任意行）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-agg-bad";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "g", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "agg3", &cols);
    defer s.deinit(alloc);
    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    var p1 = try sql.parse(alloc, "SELECT g, id, COUNT(*) FROM agg3 GROUP BY g");
    defer p1.deinit();
    try std.testing.expectError(error.UnsupportedStatement, selectRows(&t, &s, p1.stmt.select, alloc));

    var p2 = try sql.parse(alloc, "SELECT *, COUNT(*) FROM agg3 GROUP BY g");
    defer p2.deinit();
    try std.testing.expectError(error.UnsupportedStatement, selectRows(&t, &s, p2.stmt.select, alloc));

    var p3 = try sql.parse(alloc, "SELECT g, COUNT(*) FROM agg3 GROUP BY g ORDER BY nosuch");
    defer p3.deinit();
    try std.testing.expectError(error.ColumnNotFound, selectRows(&t, &s, p3.stmt.select, alloc));
}

test "聚合结果与全表扫描手算一致（1000 行随机分布）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-agg-consistency";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "g", .col_type = .integer },
        .{ .name = "x", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "agg4", &cols);
    defer s.deinit(alloc);
    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    const n: usize = 1000;
    const ngroups: i64 = 37;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var vals = [_]sql.Value{ .{ .integer = @intCast(i) }, .{ .integer = @rem(@as(i64, @intCast(i)), ngroups) }, .{ .integer = @intCast(i * 3 % 251) } };
        var row = [_][]sql.Value{&vals};
        const ins = sql.Insert{ .table = "agg4", .columns = &.{ "id", "g", "x" }, .rows = &row };
        _ = try insertRows(&t, &s, ins, alloc);
    }
    t.flush() catch {};

    const R = struct {
        cnt: i64,
        sum: i64,
        min: i64,
        max: i64,
    };
    // 0.17 的 `@splat` 支持数组（比 `[_]R{...} ** 37` 少一层括号陷阱）
    var expect: [37]R = @splat(.{ .cnt = 0, .sum = 0, .min = 0, .max = 0 });
    var seen: [37]bool = @splat(false);

    // 手算：走 selectRows 全表扫描，自己聚合
    {
        var p = try sql.parse(alloc, "SELECT g, x FROM agg4");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(n, rows.rows.len);
        for (rows.rows) |r| {
            const gi: usize = @intCast(r[0].integer);
            const x = r[1].integer;
            if (!seen[gi]) {
                seen[gi] = true;
                expect[gi] = .{ .cnt = 1, .sum = x, .min = x, .max = x };
            } else {
                expect[gi].cnt += 1;
                expect[gi].sum += x;
                expect[gi].min = @min(expect[gi].min, x);
                expect[gi].max = @max(expect[gi].max, x);
            }
        }
    }

    // 引擎算：GROUP BY
    {
        var p = try sql.parse(alloc, "SELECT g, COUNT(*), SUM(x), MIN(x), MAX(x) FROM agg4 GROUP BY g ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();

        var total: i64 = 0;
        for (rows.rows) |r| {
            const gi: usize = @intCast(r[0].integer);
            total += r[1].integer;
            try std.testing.expect(seen[gi]);
            try std.testing.expectEqual(expect[gi].cnt, r[1].integer);
            try std.testing.expectEqual(expect[gi].sum, r[2].integer);
            try std.testing.expectEqual(expect[gi].min, r[3].integer);
            try std.testing.expectEqual(expect[gi].max, r[4].integer);
        }
        // 组的行数之和必须等于总行数（不漏组、不重复计）
        try std.testing.expectEqual(@as(i64, n), total);
        try std.testing.expectEqual(@as(usize, 37), rows.rows.len);
    }
}

test "HAVING：按聚合结果过滤组，NULL 聚合被排除" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-having";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "g", .col_type = .integer },
        .{ .name = "x", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "h", &cols);
    defer s.deinit(alloc);
    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    {
        // g=1: 10,20 / g=2: 5 / g=3: NULL / g=4: 1,2,3
        var p = try sql.parse(alloc,
            "INSERT INTO h (id, g, x) VALUES (1,1,10), (2,1,20), (3,2,5), (4,3,NULL), (5,4,1), (6,4,2), (7,4,3)");
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    // COUNT(*) >= 2 → 只剩 g=1 与 g=4
    {
        var p = try sql.parse(alloc, "SELECT g, COUNT(*) FROM h GROUP BY g HAVING COUNT(*) >= 2 ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 2), rows.rows[0][1].integer);
        try std.testing.expectEqual(@as(i64, 4), rows.rows[1][0].integer);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[1][1].integer);
    }

    // SUM(x) >= 6 → g=1(30)、g=4(6)；g=2(5) 不够；g=3 的 SUM 是 NULL → 必须被排除（不是当 0）
    {
        var p = try sql.parse(alloc, "SELECT g, SUM(x) FROM h GROUP BY g HAVING SUM(x) >= 6 ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 30), rows.rows[0][1].integer);
        try std.testing.expectEqual(@as(i64, 4), rows.rows[1][0].integer);
        try std.testing.expectEqual(@as(i64, 6), rows.rows[1][1].integer);
    }

    // 反向验证：不加 HAVING 时 NULL 组要在，且 SUM 为 NULL（证明上面的排除不是因为组不存在）
    {
        var p = try sql.parse(alloc, "SELECT g, SUM(x) FROM h GROUP BY g ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[2][0].integer);
        try std.testing.expect(isNullValue(rows.rows[2][1]));
    }

    // HAVING 里用的聚合可以不在选择列表里
    {
        var p = try sql.parse(alloc, "SELECT g FROM h GROUP BY g HAVING COUNT(*) = 1 ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len); // g=2, g=3
        try std.testing.expectEqual(@as(i64, 2), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[1][0].integer);
    }

    // HAVING + ORDER BY 聚合 + LIMIT（top-N 形状）
    {
        var p = try sql.parse(alloc,
            "SELECT g, SUM(x) FROM h GROUP BY g HAVING SUM(x) > 0 ORDER BY sum(x) DESC LIMIT 2");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer); // 30 最大
        try std.testing.expectEqual(@as(i64, 30), rows.rows[0][1].integer);
        try std.testing.expectEqual(@as(i64, 4), rows.rows[1][0].integer); // 6 次之
    }
}

test "HAVING 与 WHERE 组合：WHERE 先过滤行，HAVING 后过滤组" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-where-having";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "g", .col_type = .integer },
        .{ .name = "x", .col_type = .integer },
        .{ .name = "s", .col_type = .text },
    };
    var s = try schema_mod.Schema.init(alloc, "wh", &cols);
    defer s.deinit(alloc);
    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    {
        // g=1: x=1,2,3 / g=2: x=10,20 / g=3: x=100
        var p = try sql.parse(alloc,
            "INSERT INTO wh (id, g, x, s) VALUES (1,1,1,'b'), (2,1,2,'a'), (3,1,3,'c'), " ++
                "(4,2,10,'z'), (5,2,20,'y'), (6,3,100,'m')");
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    // WHERE x < 10 只剩 g=1 的 3 行与 g=2 的 1 行（x=10 被排除），
    // 再 HAVING COUNT(*) >= 2 → 只剩 g=1（3 行）；g=2 只有 1 行被淘汰。
    // 若把两个过滤顺序弄反（先 HAVING 再 WHERE），g=2 会被保留 → 结果不同。
    {
        var p = try sql.parse(alloc,
            "SELECT g, COUNT(*), SUM(x) FROM wh WHERE x < 10 GROUP BY g HAVING COUNT(*) >= 2 ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[0][1].integer);
        try std.testing.expectEqual(@as(i64, 6), rows.rows[0][2].integer); // 1+2+3，不是 1+2+3+10
    }

    // 文本列上的 MIN/MAX（走 ownValue + valueCmp 的文本分支）
    {
        var p = try sql.parse(alloc, "SELECT g, MIN(s), MAX(s) FROM wh GROUP BY g ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
        try std.testing.expectEqualStrings("a", rows.rows[0][1].text); // g=1: b,a,c
        try std.testing.expectEqualStrings("c", rows.rows[0][2].text);
        try std.testing.expectEqualStrings("y", rows.rows[1][1].text); // g=2: z,y
        try std.testing.expectEqualStrings("z", rows.rows[1][2].text);
        try std.testing.expectEqualStrings("m", rows.rows[2][1].text); // g=3: m
    }

    // HAVING 作用在文本聚合上（MIN(s) > 'b' 的组）
    {
        var p = try sql.parse(alloc, "SELECT g FROM wh GROUP BY g HAVING MIN(s) > 'b' ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        // g=1 MIN='a' 不满足；g=2 MIN='y' 满足；g=3 MIN='m' 满足
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 2), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[1][0].integer);
    }
}
