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
    const must_materialize = blk: {
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
