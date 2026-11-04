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

// ---------------------------------------------------------------- 二级索引
//
// 索引键 = `值分量 ++ 主键分量`（都复用 schema 的顺序保持编码，每段自定界），
// 所以「等值查询」就是一次键前缀扫描，而取主键只需切掉前缀 —— 不用解码主键。
//
// **写入顺序的硬规矩：索引宁可多一条脏项，不可少一条。**
// - 插入：先写索引项、再写行 → 崩溃点最坏是多一条指向「不存在的行」的脏项；
// - 删除：先删行、再删索引项 → 崩溃点最坏是留一条脏项；
// - 更新（索引列变了）：先写新索引项 → 写新行 → 删旧索引项。
// 反过来（先写行后写索引）一旦崩在中间，索引就**缺条目**，走索引的查询会静默漏行。
// 脏项由查询侧的「回表复核」兜住：取出整行后重新判一次谓词，不匹配就跳过。

/// 一张表的索引集合（表 → 索引名 → 索引表）。
pub const IndexHost = struct {
    schema: *const schema_mod.Schema,
    tables: *std.StringHashMap(tablemod.Table),

    pub fn onColumn(self: *const IndexHost, column_idx: usize) ?*tablemod.Table {
        const ix = self.schema.indexOnColumn(column_idx) orelse return null;
        return self.tables.getPtr(ix.name);
    }
};

/// 键前缀的上界（不含）。全 `0xFF` 时返回空切片表示「无上界」，
/// 调用方仍需在循环里按 `startsWith` 判断并 break。
fn prefixUpperBound(alloc: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var i = prefix.len;
    while (i > 0) {
        i -= 1;
        if (prefix[i] != 0xFF) {
            const out = try alloc.dupe(u8, prefix[0 .. i + 1]);
            out[i] +%= 1;
            return out;
        }
    }
    return alloc.alloc(u8, 0);
}

/// 按索引列出「列 = want」的候选行值（**已回表复核过**，可直接当扫描结果用）。
///
/// 返回的切片是 `owned` 里各自独立分配的行值 —— 与全表扫描的切片不同，
/// 这里每次 `t.get` 都填同一个复用缓冲，不复制就会全变成最后一行的内容。
fn indexCollect(
    host: *const IndexHost,
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    column_idx: usize,
    want: sql.Value,
    alloc: std.mem.Allocator,
    owned: *std.ArrayList([]u8),
    max: ?usize,
    reuse: ?*tablemod.MergeIter,
) !void {
    if (isNullValue(want)) return; // `= NULL` 永远不匹配
    const itbl = host.onColumn(column_idx) orelse return error.ColumnNotFound;

    const prefix = try s.encodeValueComponent(alloc, column_idx, want);
    defer alloc.free(prefix);
    const hi = try prefixUpperBound(alloc, prefix);
    defer alloc.free(hi);

    const row_vals = try alloc.alloc(sql.Value, s.columns.len);
    defer alloc.free(row_vals);
    var vbuf: std.ArrayList(u8) = .empty;
    // `t.get` 内部用**表自己的**分配器填充 `out`，释放必须用同一个：
    // 两个分配器一攻一放是堆破坏的经典来源（生产里两者是同一个对象，所以不暴露）。
    defer vbuf.deinit(t.alloc);

    // 游标可复用：JOIN 对右表的**每一行**都要扫一次索引前缀（1 万行 = 1 万次），
    // 而 `init` 每次都重建段的 `dataView`（open + mmap）与 `RecIter`（2 次分配）——
    // 实测这一项把 1 万行 JOIN 拖到 13.9 ms（SQLite 同 SQL 2.4 ms）。
    var local_it = tablemod.MergeIter{};
    defer if (local_it.live) local_it.deinit();
    const it: *tablemod.MergeIter = blk: {
        if (reuse) |r| {
            if (!r.reset(itbl, prefix, hi)) {
                if (r.live) r.deinit();
                // **不裁段**：同一个游标要被指向成千上万个不同区间，裁剪是按区间做的，
                // 裁掉一次就再也找不回来（实测会让 JOIN 少返回行）。
                try r.initNoPrune(itbl);
                _ = r.reset(itbl, prefix, hi);
            }
            break :blk r;
        }
        try local_it.init(itbl, prefix, hi);
        break :blk &local_it;
    };

    // 复合索引：前缀只吃掉**首列**那一段，剩下的还有 (n-1) 个值分量，必须按索引定义继续跳过
    // —— 直接 `rec.key[prefix.len..]` 当主键会在多列索引上取到「第二列 ++ 主键」，回表全错。
    const ix = s.indexOnColumn(column_idx) orelse return error.ColumnNotFound;
    while (it.next()) |rec| {
        // 前缀不匹配就停：脏项、以及上界为「无上界」时的越界都靠这一句兜住
        if (!std.mem.startsWith(u8, rec.key, prefix)) break;
        const pk = try indexPkSlice(s, .{ .name = ix.name, .columns = ix.columns[1..] }, rec.key[prefix.len..]);
        const raw = (try t.get(pk, &vbuf)) orelse continue; // 行已删 → 脏项
        try s.decodeRowInto(row_vals, raw);
        // **回表复核**：索引项可能过期（更新/删除的中间态），必须重判谓词
        if (!evalWhere(row_vals[column_idx], .eq, want)) continue;
        const copy = try alloc.dupe(u8, raw);
        errdefer alloc.free(copy);
        try owned.append(alloc, copy);
        if (max) |m| {
            if (owned.items.len >= m) return;
        }
    }
    // 索引表损坏 ⇒ 候选集会静默变少（漏行）。`break` 是前缀越界（正常），不查。
    if (it.corrupt) return error.SegmentCorrupt;
}

/// 按索引列出「列 `<op>` want」的候选行值（**范围扫描**，已回表复核）。
///
/// 索引键 = `值分量 ++ 主键分量`，而值分量「顺序保持 + 自定界」⇒ 范围谓词就是一段键区间：
///
/// | 谓词 | 扫描区间 |
/// |---|---|
/// | `>  v` | `[upperBound(v分量), ∞)` —— 跳过整个「= v」前缀（同值所有主键都 ≤ 上界） |
/// | `>= v` | `[v分量, ∞)` |
/// | `<  v` | `(−∞, v分量)` |
/// | `<= v` | `(−∞, upperBound(v分量))` |
///
/// 上界是**排他**的（`MergeIter` 的 `end` 语义），所以 `<=` 必须用 `upperBound`。
/// `!=` 无法用一段区间表达，直接拒掉（调用方不会送来）。
///
/// 主键用 `indexPkSlice` 切而不是按 `comp.len` 切：**范围扫描里的值分量长度可能各不相同**
/// （text 列 `"a"` 与 `"aaaa"` 编码长度不同），按本行谓词的长度切会切错。
fn indexCollectRange(
    host: *const IndexHost,
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    column_idx: usize,
    op: sql.CmpOp,
    want: sql.Value,
    alloc: std.mem.Allocator,
    owned: *std.ArrayList([]u8),
    max: ?usize,
) !void {
    if (isNullValue(want)) return; // 与 NULL 比较恒不匹配
    const itbl = host.onColumn(column_idx) orelse return error.ColumnNotFound;

    const comp = try s.encodeValueComponent(alloc, column_idx, want);
    defer alloc.free(comp);
    const hi = try prefixUpperBound(alloc, comp);
    defer alloc.free(hi);

    var start: []const u8 = &.{};
    var end: []const u8 = &.{};
    switch (op) {
        .gt => start = hi,
        .ge => start = comp,
        .lt => end = comp,
        .le => end = hi,
        .eq, .ne => return error.UnsupportedStatement,
    }

    const row_vals = try alloc.alloc(sql.Value, s.columns.len);
    defer alloc.free(row_vals);
    var vbuf: std.ArrayList(u8) = .empty;
    defer vbuf.deinit(t.alloc); // `t.get` 用自己的分配器填充 ⇒ 同源释放

    var it = tablemod.MergeIter{};
    try it.init(itbl, start, end);
    defer it.deinit();

    const ix = s.indexOnColumn(column_idx) orelse return error.ColumnNotFound;
    while (it.next()) |rec| {
        const pk = try indexPkSlice(s, ix, rec.key);
        const raw = (try t.get(pk, &vbuf)) orelse continue; // 行已删 → 脏项
        try s.decodeRowInto(row_vals, raw);
        // **回表复核**：索引项可能过期（更新/删除的中间态），必须重判谓词
        if (!evalWhere(row_vals[column_idx], op, want)) continue;
        const copy = try alloc.dupe(u8, raw);
        errdefer alloc.free(copy);
        try owned.append(alloc, copy);
        if (max) |m| {
            if (owned.items.len >= m) return;
        }
    }
    // 索引表损坏 ⇒ 候选集会静默变少（漏行）
    if (it.corrupt) return error.SegmentCorrupt;
}

/// 维护索引项：`vals` 为行值。**任一索引列为 NULL 就不收录**（索引对 NULL 无意义，
/// 且 `=` 永远匹配不到 NULL）。
fn putIndexEntries(host: ?*const IndexHost, s: *const schema_mod.Schema, vals: []const sql.Value, alloc: std.mem.Allocator) !void {
    const h = host orelse return;
    for (h.schema.indexes) |ix| {
        var any_null = false;
        for (ix.columns) |ci| {
            if (isNullValue(vals[ci])) any_null = true;
        }
        if (any_null) continue;
        const itbl = h.tables.getPtr(ix.name) orelse continue;
        const key = try s.encodeIndexKey(alloc, ix.columns, vals, vals[s.pk_index]);
        defer alloc.free(key);
        try itbl.put(key, &.{});
    }
}

fn delIndexEntries(host: ?*const IndexHost, s: *const schema_mod.Schema, vals: []const sql.Value, alloc: std.mem.Allocator) !void {
    const h = host orelse return;
    for (h.schema.indexes) |ix| {
        var any_null = false;
        for (ix.columns) |ci| {
            if (isNullValue(vals[ci])) any_null = true;
        }
        if (any_null) continue;
        const itbl = h.tables.getPtr(ix.name) orelse continue;
        const key = try s.encodeIndexKey(alloc, ix.columns, vals, vals[s.pk_index]);
        defer alloc.free(key);
        try itbl.delete(key);
    }
}

/// 从索引键里切出**主键分量**（把前 N 个值分量依次跳过）。实现已下沉到 `schema`：
/// 建索引回填、查询、维护三处必须用同一套切分规则，否则“建的时候按 1 段、查的时候按 2 段”
/// 这类不一致会直接表现为漏行。
fn indexPkSlice(s: *const schema_mod.Schema, ix: schema_mod.IndexDef, key: []const u8) ![]const u8 {
    return s.indexPkSlice(ix.columns, key);
}

/// `ORDER BY <已建索引的非主键列> ASC`（无 WHERE）⇒ 直接扫索引表，凑够 `offset+limit` 就停。
///
/// 索引键是 `值分量 ++ 主键分量` 且**顺序保持**，所以索引表的顺序就是
/// 「该列升序、同值按主键升序」——这正好等于全量路径（主表按主键顺序扫描 + 稳定排序）
/// 的结果顺序，两条路径逐行一致（见 `engine.zig` 的守门用例）。
///
/// 每个索引键切出主键后**回表**取整行；脏项（索引有、行已删）直接跳过 ——
/// 与 `indexCollect` 的回表复核是同一套约定。
///
/// **降序不走这里**：`g++id` 倒序扫得到的是「同值按主键降序」，与全量路径的
/// 「同值按主键升序」不同；要在并列处截断得取整组，语义与成本都还没摊清，
/// 先让 `DESC` 回退全量路径（正确优先）。`Table.topKDesc` 也不能复用：它输出的是
/// **值**，而索引表的值是空的。
///
/// 返回 `null` = 这条路径不适用（没有索引 / 没有 LIMIT），调用方回退全量路径。
/// **0 行是合法结果**（谓词无匹配），不会回退 —— 回退只会把同样的活儿白干一遍。
fn selectByIndexOrder(
    host: *const IndexHost,
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    ix: schema_mod.IndexDef,
    alloc: std.mem.Allocator,
) !?Rows {
    const itbl = host.tables.getPtr(ix.name) orelse return null;
    // 谓词剪枝只能用**首列**（只有首列在索引键里是全局有序的）
    const ci = ix.firstColumn();
    const limit = sel.limit orelse return null;
    const want = @as(usize, sel.offset orelse 0) + @as(usize, limit);

    // 回表拿到的整行**连续存进一个缓冲**（`t.get` 复用 `vbuf` ⇒ 每行都必须拷走）。
    // 攒成一段再切切片，而不是每行 `dupe` 一次：k 行就少 k-1 次分配/释放。
    var store: std.ArrayList(u8) = .empty;
    defer store.deinit(alloc);
    var spans: std.ArrayList([2]usize) = .empty; // {off, len}
    defer spans.deinit(alloc);
    var vbuf: std.ArrayList(u8) = .empty;
    defer vbuf.deinit(t.alloc); // `t.get` 用它自己的分配器填充 ⇒ 同源释放

    // **一次到位，不长式增长**：`LIMIT 10` 这种小结果集上，ArrayList 从 0 长到 10
    // 要经历 8→16→32… 一串 realloc，实测这一项就吃掉小查询的相当比例
    // （`sql_orderby_index10` 曾是唯一落后 SQLite 的指标：470ns vs 450ns）。
    // 行宽按 96B 估：估小只是会再扩一次，估大也只是多占一点临时内存。
    try spans.ensureTotalCapacity(alloc, want);
    try store.ensureTotalCapacity(alloc, want * 96);

    // ------------------------------------------------------------------
    // WHERE：谓词在扫描循环里判（不匹配的行**不占** limit 名额）。
    // 若谓词正好作用在排序列上，索引键还给出整体下界 —— 直接 seek 过去，
    // 不必从头扫（`WHERE g >= 50000` 只读后半段）。
    //
    // 这是 §16.1.46 留的缺口：以前只要带 WHERE 就整条回退全表扫描。
    // 实测 `WHERE g >= 50000 ORDER BY g LIMIT 10`（100 万行）：
    // 每次扫 100 万行、53.97 ms，SQLite 5.0 µs（≈10800×）。
    // ------------------------------------------------------------------
    var where_col: ?usize = null;
    var where_op: sql.CmpOp = .eq;
    var where_val: sql.Value = .{ .null = {} };
    var start_owned: ?[]u8 = null;
    defer if (start_owned) |p| alloc.free(p);
    var end_owned: ?[]u8 = null;
    defer if (end_owned) |p| alloc.free(p);
    var start: []const u8 = &.{};
    var end: []const u8 = &.{};
    if (sel.where) |w| {
        const wci = s.indexOf(w.column) orelse return error.ColumnNotFound;
        where_col = wci;
        where_op = w.op;
        where_val = w.value;
        // 只有「谓词列 == 排序列」时才有整体下界；`>=` 与 `=` 都能定下界（同一个值分量前缀），
        // `=` 顺带能用前缀上界把范围收死。`>` / `<=` 不剪枝：值分量编码的边界靠推断容易出错，
        // 交给循环过滤更稳妥（慢一点但不会错）。
        if (wci == ci and !isNullValue(w.value) and (w.op == .ge or w.op == .eq)) {
            const pfx = try s.encodeValueComponent(alloc, ci, w.value);
            start_owned = pfx;
            start = pfx;
            if (w.op == .eq) {
                const hi = try prefixUpperBound(alloc, pfx);
                end_owned = hi;
                end = hi;
            }
        }
    }

    const row_vals: ?[]sql.Value = if (where_col != null) try alloc.alloc(sql.Value, s.columns.len) else null;
    defer if (row_vals) |rv| alloc.free(rv);

    var it = tablemod.MergeIter{};
    try it.init(itbl, start, end);
    defer it.deinit();
    while (it.next()) |rec| {
        if (spans.items.len >= want) break;
        const pk = try indexPkSlice(s, ix, rec.key);
        const raw = (try t.get(pk, &vbuf)) orelse continue; // 脏项
        if (where_col) |wci| {
            try s.decodeRowInto(row_vals.?, raw);
            // **回表后重判**：索引项可能过期（更新/删除的中间态），不能只信索引键
            if (!evalWhere(row_vals.?[wci], where_op, where_val)) continue;
        }
        try spans.append(alloc, .{ store.items.len, raw.len });
        try store.appendSlice(alloc, raw);
    }
    // 索引表损坏 ⇒ 结果会静默少几行
    if (it.corrupt) return error.SegmentCorrupt;
    // 切片在这之后才建：`store` 不再增长，指针稳定
    const rows = try alloc.alloc([]const u8, spans.items.len);
    defer alloc.free(rows);
    for (spans.items, 0..) |sp, i| rows[i] = store.items[sp[0]..][0..sp[1]];

    // **索引顺序已经满足 ORDER BY**：把 `order_by` 清掉再交给统一装配 —— 装配层就会
    // ①跳过排序、②只 decode 投影用到的列（`want = proj.indices`）。这两件事本来由
    // 「排序列必须先解码」那条约束逼出来的，索引路径不需要付。
    // `where` 也清掉：循环里已经判过，装配层再判一遍只是白解码。
    var sel2 = sel;
    sel2.order_by = &[_]sql.OrderItem{};
    sel2.where = null;
    return try finishFromValues(t.io, s, sel2, alloc, rows);
}

/// 找一个能**直接满足 `ORDER BY`** 的索引：索引列序必须与排序列表**完全一致**且全为 `ASC`。
///
/// 为什么必须完全一致：索引顺序是 `(c1, c2, …, pk)`。若只匹配前两列而索引还有第三列，
/// 那「c1 相同、c2 相同」的行是按 c3 排的，而全量路径按主键稳定排序 —— 两条路径结果不同。
/// 只有「索引列数与排序列表长度相等」时，并列处的顺序才统一落到主键上。
///
/// 三条降级条件（与单列时代同一口径）：`DESC` 不用（并列次序会反）、
/// 可空列不用（NULL 不入索引，升序里 NULL 本应排最前）、索引列不能是主键。
fn findIndexMatchingOrder(s: *const schema_mod.Schema, h: *const IndexHost, order: []const sql.OrderItem) ?schema_mod.IndexDef {
    for (s.indexes) |ix| {
        if (ix.columns.len != order.len) continue;
        if (h.tables.getPtr(ix.name) == null) continue;
        var ok = true;
        for (order, ix.columns) |o, ci| {
            if (o.desc) {
                ok = false;
                break;
            }
            if (ci == s.pk_index or !s.columns[ci].not_null) {
                ok = false;
                break;
            }
            const oc = s.indexOf(o.column) orelse {
                ok = false;
                break;
            };
            // 列序必须**逐位相同**：索引是 (g,h) 就不能拿来回答 `ORDER BY h,g`
            if (oc != ci) {
                ok = false;
                break;
            }
        }
        if (ok) return ix;
    }
    return null;
}

fn evalWhere(a: sql.Value, op: sql.CmpOp, b: sql.Value) bool {
    // **与 NULL 比较恒不匹配**（SQL 的 UNKNOWN）。`valueCmp` 把 NULL 当作「比任何值都小」，
    // 直接拿它比较会让 `WHERE x >= NULL` 变成「全部行」——语义错，而且会让
    // 「走索引 / 走全表」两条路径给出不同结果（索引键里根本不收 NULL）。
    //
    // **两侧都要判**：只判 `b` 时，`x < 5` / `x <= 5` / `x <> 5` 对 NULL 行会返回 true
    // （因为 `valueCmp(NULL, 5) == .lt`），而索引路径根本不收 NULL ⇒ 同一句 SQL
    // 「走索引 / 走全表」条数不同。2026-11-03 审计抓到的这一类分歧。
    if (isNullValue(a) or isNullValue(b)) return false;
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

/// 查询阶段计时（**仅基准用**，生产路径保持 `false`）。
///
/// 为什么要它：审计后 `sql_orderby_limit10` 的真实成本是 ≈11 µs/查询，
/// 但「里面哪一段贵」不能靠猜 —— §九十二（索引构建）就是靠先拆阶段
/// （94/240/127 ms）才逐段超车的。纪律与 `segmod.timing` 一致：**非线程安全**，
/// 只能单线程跑基准时开启。
pub const QueryTiming = struct {
    /// `Table.topKDesc`（段尾定位 + memtable 反向 + 候选归并归组）
    topk: u64 = 0,
    /// `buildProjection`（分配 + 列名匹配）
    projection: u64 = 0,
    /// `decodeAll`（buf/flat/hdrs 三块分配 + 逐行解码）
    decode: u64 = 0,
    /// 排序（有 ORDER BY 时对候选/结果集排序）
    sort: u64 = 0,
    /// `buildOutput`（输出行分配或所有权转移）
    output: u64 = 0,
    /// 进入 `finishFromValues` 的次数（用于把累计值折算成每次）
    calls: u64 = 0,
};
pub var timing_enabled: bool = false;
pub var timing: QueryTiming = .{};

/// 计时点：未开启时**不读时钟**（`now` 在 Windows 上要约 20–40 ns，
/// 8 个点就会吃掉 11 µs 的 2–3%）。
inline fn stamp(io: std.Io) u64 {
    return if (timing_enabled) segmod.tick(io) else 0;
}

/// `ORDER BY` 是否**恰好**就是主键那一列（单列、无次级键）。
///
/// 返回 `null` = 不是主键排序；`false` = 主键升序；`true` = 主键降序。
///
/// 为什么值得单独识别：存储层扫描输出本来就是主键升序，所以
/// - 升序：可以走「凑够 offset+limit 就停」的提前终止，k 行排序可忽略；
/// - 降序：可以走 `Table.topKDesc`（段尾定位 + 反向迭代），O(k) 而不是 O(n)。
/// 这正是 SQLite 用 rowid 索引把 `ORDER BY rowid DESC LIMIT 10` 做成常数级的同一条路。
fn pkOrderOnly(s: *const schema_mod.Schema, order: []const sql.OrderItem) ?bool {
    if (order.len != 1) return null;
    const idx = resolveColumn(s, order[0].column) catch return null;
    if (idx != s.pk_index) return null;
    return order[0].desc;
}

/// 排序前校验 `ORDER BY` 的每一列都能解析到。
///
/// 为什么必须有：`rowLess` 是排序比较器，**不能返回错误**，解析失败只能退化成
/// 「相等」⇒ 整条 ORDER BY 静默失效（结果顺序乱但不报错）。这一层把错误提前报出来。
fn validateOrderBy(s: *const schema_mod.Schema, order: []const sql.OrderItem) !void {
    for (order) |o| _ = try resolveColumn(s, o.column);
}

fn rowLess(ctx: SortCtx, a: []sql.Value, b: []sql.Value) bool {
    for (ctx.order) |o| {
        // 解析已在 `validateOrderBy` 里做过；这里退化成 false 只是防御（排序比较器
        // 不能返回错误），不会静默漏列的根因已经挡住了。
        const idx = resolveColumn(ctx.schema, o.column) catch return false;
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
    /// **`flat` 是否已经是「投影顺序」的最终布局**。
    ///
    /// 不能用 `ncols == 投影列数` 去推断：全列解码（`ncols == 列数`）+ 「全列但乱序」的投影
    /// （`SELECT s, id, g`）两个条件同时成立时，长度相等而布局是**表顺序**，
    /// 于是 `buildOutput` 会认为「已经是最终布局」直接转移所有权 ⇒
    /// **列名是投影顺序、值是表顺序**。2026-11-03 由差分随机测试抓到（此前所有用例
    /// 都是 `id, g` 这种表序投影，从未踩到）。
    pushed: bool = false,

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
    return .{ .alloc = alloc, .buf = buf, .flat = flat, .hdrs = hdrs, .ncols = ncols, .pushed = want != null };
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
    // 失败时 `proj.columns` 由本函数释放：调用方用 `ProjGuard.release()` 把所有权
    // 完整交过来，不要再自己释放（否则就是重复释放）。
    errdefer {
        for (proj.columns) |c| alloc.free(c);
        alloc.free(proj.columns);
    }
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

    // `decodeAll` 已按投影解码（`m.pushed`）：`flat` 就是最终布局，不用再从全列里挑。
    // 这是 `SELECT id` 比 `SELECT *` 还慢 16% 的根因修法 —— 旧路径会另分配一份
    // `pflat` 再逐行拷 Value（100 万行 16MB）。
    if (m.pushed) {
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

/// 一张参与 JOIN 的表（`name` 用于合成 schema 的 `表.列` 列名）。
pub const JoinedTable = struct {
    name: []const u8,
    table: *tablemod.Table,
    schema: *const schema_mod.Schema,
    host: ?*const IndexHost,
};

const JoinSide = struct { idx: usize, on_left: bool };

/// 把 `ON` 一侧的 `表.列` 归一化成「哪一侧 + 列下标」。
/// 不带表名的一律拒绝（两表有同名列时无法判断）——这是 parser 已经强制的，
/// 这里再兜一次，防手写 AST 的调用方绕过。
fn resolveJoinSide(
    ref: []const u8,
    lname: []const u8,
    rname: []const u8,
    sa: *const schema_mod.Schema,
    sb: *const schema_mod.Schema,
) !JoinSide {
    const dot = std.mem.indexOfScalar(u8, ref, '.') orelse return error.UnsupportedStatement;
    const tbl = ref[0..dot];
    const col = ref[dot + 1 ..];
    const on_left = std.ascii.eqlIgnoreCase(tbl, lname);
    const on_right = std.ascii.eqlIgnoreCase(tbl, rname);
    if (on_left and on_right) return error.UnsupportedStatement; // 自连接需要别名，暂不支持
    if (!on_left and !on_right) return error.ColumnNotFound;
    const s = if (on_left) sa else sb;
    const idx = s.indexOf(col) orelse return error.ColumnNotFound;
    return .{ .idx = idx, .on_left = on_left };
}

/// 合成 schema：列 = 左表列（名 `左表.列`）++ 右表列（名 `右表.列`）。
///
/// 用限定名而不是裸名，是为了让 `t.id` / `u.id` 能区分同名列；
/// 裸名投影（`SELECT id`）由 `resolveColumn` 的「唯一匹配」兜住，重名报歧义。
fn buildJoinSchema(
    alloc: std.mem.Allocator,
    lname: []const u8,
    sa: *const schema_mod.Schema,
    rname: []const u8,
    sb: *const schema_mod.Schema,
) !schema_mod.Schema {
    const n = sa.columns.len + sb.columns.len;
    const cols = try alloc.alloc(schema_mod.Column, n);
    // `made` 计数而不是「无条件释放全部」：中途失败时右表那几列的 `name`
    // 还是未初始化的垃圾，盲目 free 会 double free（第一版就这么崩的）。
    var made: usize = 0;
    defer {
        for (cols[0..made]) |c| alloc.free(c.name);
        alloc.free(cols);
    }
    for (sa.columns, 0..) |c, i| {
        cols[i] = .{
            .name = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ lname, c.name }),
            .col_type = c.col_type,
            // **合成 schema 只能有一个主键**（`Schema.init` 的硬约束）：
            // 两张表各带一个主键，两个都保留会被 `init` 判 TooManyPrimaryKeys。
            // JOIN 执行本身不用 `pk_index`，所以只留左表的即可。
            .primary_key = c.primary_key,
            .auto_increment = c.auto_increment,
            .not_null = c.not_null,
        };
        made += 1;
    }
    for (sb.columns, 0..) |c, i| {
        cols[sa.columns.len + i] = .{
            .name = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ rname, c.name }),
            .col_type = c.col_type,
            .primary_key = false,
            .auto_increment = c.auto_increment,
            .not_null = c.not_null,
        };
        made += 1;
    }
    // `Schema.init` 会再 dupe 一遍列名（它自己的所有权契约），临时名由上面的 defer 释放
    return schema_mod.Schema.init(alloc, "join", cols);
}

/// 在右表里找 `col = want` 的所有行，**每行都深拷进 `a`**（arena）。
///
/// 深浅拷贝在这里是硬要求：索引路径与点查路径的 `text`/`blob` 都指向
/// 临时缓冲（`indexCollect` 的 owned 数组 / `t.get` 的复用缓冲），
/// 出了本函数就失效。
fn joinLookup(
    rt: JoinedTable,
    col_idx: usize,
    want: sql.Value,
    alloc: std.mem.Allocator,
    a: std.mem.Allocator,
    out: *std.ArrayList([]sql.Value),
    /// 可复用的索引扫描游标（整个 JOIN 共一个）：右表要对左表每一行查一次，
    /// 不复用的话 1 万行就要重建 1 万次段游标（实测把 JOIN 拖到 SQLite 的 5.7 倍慢）。
    reuse: ?*tablemod.MergeIter,
) !void {
    if (isNullValue(want)) return; // `= NULL` 永远无匹配（与 WHERE 同口径）
    const nb = rt.schema.columns.len;

    // ① ON 列是右表主键 ⇒ 点查
    if (col_idx == rt.schema.pk_index) {
        const key = try rt.schema.encodeValueComponent(alloc, col_idx, want);
        defer alloc.free(key);
        var vbuf: std.ArrayList(u8) = .empty;
        defer vbuf.deinit(alloc);
        const raw = (try rt.table.get(key, &vbuf)) orelse return;
        try appendDupRow(rt.schema, raw, alloc, a, out, nb);
        return;
    }

    // ② ON 列有索引 ⇒ 键前缀扫描 + 回表复核
    if (rt.host) |h| {
        if (h.onColumn(col_idx) != null) {
            var owned: std.ArrayList([]u8) = .empty;
            defer {
                for (owned.items) |x| alloc.free(x);
                owned.deinit(alloc);
            }
            try indexCollect(h, rt.table, rt.schema, col_idx, want, alloc, &owned, null, reuse);
            for (owned.items) |raw| try appendDupRow(rt.schema, raw, alloc, a, out, nb);
            return;
        }
    }

    // ③ 兜底：全表扫（O(右表行数)/次）。正确但慢 —— 大表必须给 ON 列建索引。
    const rvals = try alloc.alloc(sql.Value, nb);
    defer alloc.free(rvals);
    var it = tablemod.MergeIter{};
    try it.init(rt.table, &[_]u8{}, &[_]u8{});
    defer it.deinit();
    while (it.next()) |rec| {
        try rt.schema.decodeRowInto(rvals, rec.value);
        if (schema_mod.valueCmp(rvals[col_idx], want) != .eq) continue;
        const row = try a.alloc(sql.Value, nb);
        for (rvals, row) |v, *dst| dst.* = try dupValue(a, v);
        try out.append(a, row);
    }
    // JOIN 右表兜底全扫：段损坏会让连接静默少匹配
    if (it.corrupt) return error.SegmentCorrupt;
}

fn dupValue(a: std.mem.Allocator, v: sql.Value) !sql.Value {
    return switch (v) {
        .text => |x| .{ .text = try a.dupe(u8, x) },
        .blob => |x| .{ .blob = try a.dupe(u8, x) },
        else => v,
    };
}

/// 哈希连接的内存上限（右表行数）：超过就走索引/点查的嵌套循环。
///
/// 右表每行要在内存里留一份解码后的行（`nb × 16B`）+ 一条链节点 + 一份键，
/// 20 万行 × 3 列 ≈ 10 MB —— 再大就该交给索引路径，而不是把整表塞进内存。
/// `pub var` 是为了让用例能把它设成 0 去覆盖嵌套循环的兵底路径。
pub var join_hash_max_rows: usize = 200_000;

/// 「建哈希」与「按行查索引」的交叉点：左表行数 × 4 还不足以覆盖右表行数时，
/// 建一次全表哈希反而更贵（例：左 1 行 / 右 10 万行 ⇒ 哈希要解 10 万行，索引探测只要 1 次）。
const join_hash_min_left_ratio: usize = 4;

/// 右表行数估算（memtable + 各段行数），只用来决定走不走哈希连接，不参与正确性。
fn rowEstimate(t: *tablemod.Table) usize {
    var n: usize = @intCast(t.mem.len());
    for (t.segs.items) |s| n +|= @as(usize, @intCast(s.rows));
    return n;
}

/// 哈希键的临时缓冲。
///
/// 数值键固定 9 字节（1 字节类型 + 8 字节全序 f64）⇒ 直接写栈缓冲，**不进 ArrayList**；
/// 只有 text/blob 长度不定才用 `txt`。进 JOIN 热循环的每一次探测都要算一次键，
/// 所以不给它分配器分配路径。
const HashKeyBuf = struct {
    num: [9]u8 = undefined,
    txt: std.ArrayList(u8) = .empty,

    fn deinit(self: *HashKeyBuf, alloc: std.mem.Allocator) void {
        self.txt.deinit(alloc);
    }
};

/// 一个分组：右表里键相同的全部行，按**右表扫描顺序**串成链。
const HashGroup = struct { head: u32 = no_entry, tail: u32 = no_entry };
const no_entry: u32 = std.math.maxInt(u32);
const HashEntry = struct { next: u32 = no_entry, row: []sql.Value };

/// JOIN 的**哈希连接**侧：右表整表扫一遍建「键 → 行链」，左表每行 O(1) 探测。
///
/// **为什么必须有这条路径**：等值 JOIN 原来的做法是「左表每行查一次右表」
/// （索引前缀扫描 / 主键点查 / 全表扫）。实测本引擎的单次点查就要 ~1.9 µs
/// （`sql_get` 521k 次/s），所以 1 万行 JOIN 无论怎么"复用游标"都卡在 12.5 ms 以上，
/// 而 SQLite 同一条 SQL 是 2.4 ms。要做的是**根本不按行查**，不是把单次查得更快。
///
/// 键的规范化口径与 `valueCmp` 对齐：整数与实数是**同一个数值空间**（都按 f64 比较），
/// 所以 `1` 与 `1.0` 落同一个桶；text/blob 按字节。命中后仍用 `valueCmp` 复核一次，
/// 保证「哈希判等」永远是 `valueCmp` 判等的充分条件而不是替代品。
const JoinHash = struct {
    map: std.StringHashMapUnmanaged(HashGroup) = .empty,
    entries: std.ArrayList(HashEntry) = .empty,

    fn build(
        self: *JoinHash,
        rt: JoinedTable,
        col_idx: usize,
        alloc: std.mem.Allocator,
        a: std.mem.Allocator,
    ) !void {
        const nb = rt.schema.columns.len;
        const vals = try alloc.alloc(sql.Value, nb);
        defer alloc.free(vals);
        var kb: HashKeyBuf = .{};
        defer kb.deinit(alloc);
        var it = tablemod.MergeIter{};
        try it.init(rt.table, &[_]u8{}, &[_]u8{});
        defer it.deinit();
        while (it.next()) |rec| {
            try rt.schema.decodeRowInto(vals, rec.value);
            if (isNullValue(vals[col_idx])) continue; // `= NULL` 永不匹配
            const k = try hashKeyInto(&kb, alloc, vals[col_idx]);
            const gop = try self.map.getOrPut(alloc, k);
            if (!gop.found_existing) {
                // 键拷进 arena（生命周期同结果集），map 的桶由 `alloc` 管
                gop.key_ptr.* = try a.dupe(u8, k);
                gop.value_ptr.* = .{};
            }
            const row = try a.alloc(sql.Value, nb);
            for (vals, row) |v, *dst| dst.* = try dupValue(a, v);
            if (gop.value_ptr.tail != no_entry) {
                self.entries.items[gop.value_ptr.tail].next = @intCast(self.entries.items.len);
            } else {
                gop.value_ptr.head = @intCast(self.entries.items.len);
            }
            gop.value_ptr.tail = @intCast(self.entries.items.len);
            try self.entries.append(alloc, .{ .row = row });
        }
        if (it.corrupt) return error.SegmentCorrupt;
    }

    /// 把 `want` 命中的右表行**按右表顺序**追加进 `out`（行本就住在 arena 里，无需再拷）。
    fn probe(
        self: *JoinHash,
        col_idx: usize,
        want: sql.Value,
        alloc: std.mem.Allocator,
        a: std.mem.Allocator,
        kb: *HashKeyBuf,
        out: *std.ArrayList([]sql.Value),
    ) !void {
        if (isNullValue(want)) return;
        const k = try hashKeyInto(kb, alloc, want);
        const g = self.map.get(k) orelse return;
        var e = g.head;
        while (e != no_entry) {
            const ent = self.entries.items[e];
            // 复核：哈希只是「可能相等」，判等一律以 `valueCmp` 为准
            if (schema_mod.valueCmp(ent.row[col_idx], want) == .eq) try out.append(a, ent.row);
            e = ent.next;
        }
    }

    fn deinit(self: *JoinHash, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc); // 键在 arena 里，这里只释放桶
        self.entries.deinit(alloc);
    }
};

/// 哈希键：数值统一走 f64（与 `valueCmp` 的数值比较口径一致），text/blob 走字节。
/// 返回值只在下次调用前有效。
fn hashKeyInto(kb: *HashKeyBuf, alloc: std.mem.Allocator, v: sql.Value) ![]const u8 {
    switch (v) {
        .integer, .real => {
            kb.num[0] = 'n';
            var f: f64 = switch (v) {
                .integer => |x| @floatFromInt(x),
                .real => |x| x,
                else => unreachable,
            };
            if (f == 0) f = 0; // -0.0 与 +0.0 必须同桶（`valueCmp` 判等）
            var bits: u64 = @bitCast(f);
            bits = if ((bits >> 63) != 0) ~bits else bits | 0x8000_0000_0000_0000;
            std.mem.writeInt(u64, kb.num[1..9], bits, .big);
            return kb.num[0..9];
        },
        .null => {
            kb.num[0] = 0;
            return kb.num[0..1];
        },
        .text => |s| {
            kb.txt.clearRetainingCapacity();
            try kb.txt.append(alloc, 't');
            try kb.txt.appendSlice(alloc, s);
            return kb.txt.items;
        },
        .blob => |s| {
            kb.txt.clearRetainingCapacity();
            try kb.txt.append(alloc, 'b');
            try kb.txt.appendSlice(alloc, s);
            return kb.txt.items;
        },
    }
}

fn appendDupRow(
    s: *const schema_mod.Schema,
    raw: []const u8,
    alloc: std.mem.Allocator,
    a: std.mem.Allocator,
    out: *std.ArrayList([]sql.Value),
    nb: usize,
) !void {
    const tmp = try alloc.alloc(sql.Value, nb);
    defer alloc.free(tmp);
    try s.decodeRowInto(tmp, raw);
    const row = try a.alloc(sql.Value, nb);
    for (tmp, row) |v, *dst| dst.* = try dupValue(a, v);
    try out.append(a, row);
}

/// `JoinSink` 预留容量的硬上限（`Value` 个数，16 B/个 ⇒ 65,536 个 ≈ 1 MB）。
///
/// 上限存在的理由见 `JoinSink.init`：按「左表行数 × 投影列数」预留，在
/// 「大左表 + 宽投影 + 低命中率」下会是 GB 级请求 —— **预分配失败会让本来能跑完的查询报 OOM**。
const join_sink_prealloc_cap: usize = 65_536;

/// JOIN 产出装配器：**直接写最终布局**（投影后的 `flat` + `hdrs`）。
///
/// 这一步是照 SQLite 的执行模型改的：`sqlite3_step` 把一行写进 prepare 时就分配好的
/// 寄存器数组，**每行不分配、不搬运**。我们原来的写法是「arena 逐行分配一个宽行 →
/// `finishFromRows` 再深拷一遍 → `buildOutput` 按投影再拷一遍」，1 万行要搬运
/// 近百万元素并反复触碰新分配的页（首次触碰的缺页是实打实的钱）。
///
/// text/blob 先追加进 `txt` 并**记下单元下标**，最后统一回填切片 —— 不能存切片指针，
/// `flat`/`txt` 扩容会让它们失效（这也是为什么不能用「先记指针后修补」的偷懒写法）。
const JoinSink = struct {
    alloc: std.mem.Allocator,
    flat: std.ArrayList(sql.Value) = .empty,
    txt: std.ArrayList(u8) = .empty,
    fix: std.ArrayList(TxtFix) = .empty,
    /// 每行写入的列数（= 投影列数）
    ncols: usize = 0,

    const TxtFix = struct { cell: usize, start: usize, len: usize };

    fn init(alloc: std.mem.Allocator, ncols: usize, expect_rows: usize) !JoinSink {
        var s = JoinSink{ .alloc = alloc, .ncols = ncols };
        // 预留到估算行数，但**必须有上限**：`expect_rows × ncols` 在「大左表 + 宽投影」下
        // 是 GB 级（1000 万行 × 20 列 = 3.2 GB），而连接命中数本来就可能远小于左表行数
        // （INNER JOIN 甚至可能为 0）。超出的部分交给 ArrayList 的倍增扩容。
        const want = expect_rows *| ncols;
        const cap = @max(@as(usize, 8), @min(want, join_sink_prealloc_cap));
        try s.flat.ensureTotalCapacity(alloc, cap);
        return s;
    }

    fn deinit(self: *JoinSink) void {
        self.flat.deinit(self.alloc);
        self.txt.deinit(self.alloc);
        self.fix.deinit(self.alloc);
    }

    inline fn rows(self: *const JoinSink) usize {
        return if (self.ncols == 0) 0 else self.flat.items.len / self.ncols;
    }

    /// 写入一行（`vals.len` 必须等于 `ncols`）。text/blob 在这里就拷进 `txt`。
    fn emit(self: *JoinSink, vals: []const sql.Value) !void {
        for (vals) |v| {
            const cell = self.flat.items.len;
            switch (v) {
                .text => |x| {
                    try self.flat.append(self.alloc, .{ .text = &.{} });
                    const st = self.txt.items.len;
                    try self.txt.appendSlice(self.alloc, x);
                    try self.fix.append(self.alloc, .{ .cell = cell, .start = st, .len = x.len });
                },
                .blob => |x| {
                    try self.flat.append(self.alloc, .{ .blob = &.{} });
                    const st = self.txt.items.len;
                    try self.txt.appendSlice(self.alloc, x);
                    try self.fix.append(self.alloc, .{ .cell = cell, .start = st, .len = x.len });
                },
                else => try self.flat.append(self.alloc, v),
            }
        }
    }

    /// 收尾成可直接交给 `assembleMaterialized` 的 `Materialized`（所有权转移）。
    fn materialize(self: *JoinSink) !Materialized {
        const nrows = self.rows();
        const flat = try self.flat.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(flat);
        const buf = try self.txt.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(buf);
        for (self.fix.items) |f| {
            const sl = buf[f.start..][0..f.len];
            flat[f.cell] = switch (flat[f.cell]) {
                .text => .{ .text = sl },
                .blob => .{ .blob = sl },
                else => unreachable,
            };
        }
        const hdrs = try self.alloc.alloc([]sql.Value, nrows);
        errdefer self.alloc.free(hdrs);
        for (0..nrows) |i| hdrs[i] = flat[i * self.ncols ..][0..self.ncols];
        // `emit` 写入的就是**投影列、投影顺序**，所以这里布局已经是最终布局
        return .{ .alloc = self.alloc, .flat = flat, .hdrs = hdrs, .buf = buf, .ncols = self.ncols, .pushed = true };
    }
};

/// `[INNER|LEFT] JOIN` 执行：左表流式扫描 × 右表按键查找，物化成宽行后走统一装配。
///
/// **已知性能边界**：右表 ON 列既不是主键也没有索引时走全表扫描 ⇒ O(左行 × 右行)。
/// 这是正确但慢的兜底，大表必须给 ON 列建索引。
pub fn selectJoin(
    left: JoinedTable,
    right: JoinedTable,
    sel: sql.Select,
    alloc: std.mem.Allocator,
) !Rows {
    const jc = sel.join orelse return error.UnsupportedStatement;
    // `GROUP BY` / `HAVING` 在 JOIN 路径没实现：不拦的话会被**完全忽略**，
    // 静默返回未分组的明细行（投影里的聚合项则会由 buildProjection 报错）。
    if (sel.group_by.len > 0 or sel.having != null) return error.UnsupportedStatement;

    const l = try resolveJoinSide(jc.left, left.name, right.name, left.schema, right.schema);
    const r = try resolveJoinSide(jc.right, left.name, right.name, left.schema, right.schema);
    if (l.on_left == r.on_left) return error.UnsupportedStatement; // 两侧同表（自连接）
    const lcol = if (l.on_left) l.idx else r.idx;
    const rcol = if (l.on_left) r.idx else l.idx;

    var jschema = try buildJoinSchema(alloc, left.name, left.schema, right.name, right.schema);
    defer jschema.deinit(alloc);

    // 宽行全部从 arena 分配：`finishFromRows` 会把它们深拷进结果缓冲，
    // 所以这里不需要逐行追踪所有权（也就不会漏 free）。
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const na = left.schema.columns.len;
    const nb = right.schema.columns.len;
    // WHERE 在**宽行**上过滤：单表路径在扫描阶段就过滤了，JOIN 没有那个阶段，
    // 漏了这一步会让 `WHERE u.name = 'ten'` 静默失效（用例当场抓到过）。
    const where_idx: ?usize = if (sel.where) |w| try resolveColumn(&jschema, w.column) else null;
    // **无 `ORDER BY` 时直写最终布局**（`narrow`）：排序要按未投影的列比较，所以只有这一档能提前投影。
    // 直写路径下 `flat` 的宽度就是投影列数，`buildOutput` 会走「所有权转移」分支 ⇒ 全链只搬一次。
    const narrow = sel.order_by.len == 0;
    // 直写路径要在循环**之前**知道投影列下标，所以只有它提前建投影；
    // 排序路径交给 `finishFromRows`（它自己建，顺带做 ORDER BY 列校验）。
    var pg: ProjGuard = .{ .alloc = alloc };
    if (narrow) {
        try validateOrderBy(&jschema, sel.order_by);
        pg = ProjGuard.take(alloc, try buildProjection(alloc, &jschema, sel.items));
    }
    defer pg.deinit();

    var wide: std.ArrayList([]sql.Value) = .empty;
    var matches: std.ArrayList([]sql.Value) = .empty;
    const lvals = try alloc.alloc(sql.Value, na);
    defer alloc.free(lvals);
    // 直写路径的「宽行」暂存（`na + nb` 个值），**只用于 WHERE 判定与挑投影列**；
    // 一条查询只分配一次（不是每行），排序路径用不到也不算浪费。
    const wrow = try alloc.alloc(sql.Value, na + nb);
    defer alloc.free(wrow);
    var sink: JoinSink = .{ .alloc = alloc };
    var sink_ready = false;
    defer if (sink_ready) sink.deinit();

    var it = tablemod.MergeIter{};
    try it.init(left.table, &[_]u8{}, &[_]u8{});
    defer it.deinit();
    // 右表索引查找共用**一个**扫描游标：JOIN 对左表每一行都要查一次右表，
    // 每行都重建段游标（open + mmap + 2 次分配）会把这条路径拖成 SQLite 的 5 倍慢。
    var rscan: tablemod.MergeIter = .{};
    defer if (rscan.live) rscan.deinit();
    // **哈希连接**（右表放得进内存就一律走它）：整表建一次哈希，左表每行 O(1) 探测。
    // 嵌套循环（下面 `joinLookup`）只在小表以外/内存受限时兜底。
    var jh: JoinHash = .{};
    defer jh.deinit(alloc);
    const jr = rowEstimate(right.table);
    const use_hash = jr <= join_hash_max_rows and rowEstimate(left.table) * join_hash_min_left_ratio >= jr;
    if (use_hash) try jh.build(right, rcol, alloc, a);
    if (narrow) {
        // 预留容量：按「左表行数 × 投影列数」估，但**必须设上限** ——
        // 左表 1000 万行、投影 20 列就是 3.2 GB，预分配会直接 OOM；
        // 连接命中数本来就可能远小于左表行数（INNER 甚至可能为 0）。
        sink = try JoinSink.init(alloc, pg.proj.indices.len, rowEstimate(left.table));
        sink_ready = true;
    }
    // `LIMIT` 且无 `ORDER BY` ⇒ 凑够 `offset + limit` 就停（顺序是确定的，提前停不改变结果）
    const stop_at: ?usize = if (narrow and sel.limit != null)
        @as(usize, sel.limit.?) + @as(usize, sel.offset orelse 0)
    else
        null;
    var kb: HashKeyBuf = .{};
    defer kb.deinit(alloc);
    outer: while (it.next()) |rec| {
        try left.schema.decodeRowInto(lvals, rec.value);
        matches.clearRetainingCapacity();
        if (use_hash) {
            try jh.probe(rcol, lvals[lcol], alloc, a, &kb, &matches);
        } else {
            try joinLookup(right, rcol, lvals[lcol], alloc, a, &matches, &rscan);
        }
        if (!narrow) {
            if (matches.items.len == 0) {
                if (jc.kind == .left) {
                    const row = try a.alloc(sql.Value, na + nb);
                    for (row[0..na], lvals) |*dst, v| dst.* = try dupValue(a, v);
                    for (row[na..]) |*dst| dst.* = .null;
                    try pushJoined(a, &wide, row, sel, where_idx);
                }
                continue;
            }
            for (matches.items) |rv| {
                const row = try a.alloc(sql.Value, na + nb);
                for (row[0..na], lvals) |*dst, v| dst.* = try dupValue(a, v);
                @memcpy(row[na..], rv);
                try pushJoined(a, &wide, row, sel, where_idx);
            }
            continue;
        }
        // ---- 直写路径 ----
        // 左值**不深拷**：text/blob 立刻被 `sink.emit` 拷进 `txt`，`lvals` 在本轮内一直有效。
        if (matches.items.len == 0) {
            if (jc.kind == .left) {
                @memcpy(wrow[0..na], lvals);
                for (wrow[na..]) |*dst| dst.* = .null;
                try sinkJoined(&sink, wrow, pg.proj.indices, sel, where_idx);
            }
            if (stop_at) |lim| if (sink.rows() >= lim) break :outer;
            continue;
        }
        for (matches.items) |rv| {
            @memcpy(wrow[0..na], lvals);
            @memcpy(wrow[na..], rv);
            try sinkJoined(&sink, wrow, pg.proj.indices, sel, where_idx);
            if (stop_at) |lim| if (sink.rows() >= lim) break :outer;
        }
    }
    // 左表段损坏 ⇒ 行集会静默缺行
    if (it.corrupt) return error.SegmentCorrupt;

    if (narrow) {
        var m = try sink.materialize();
        sink_ready = false; // 所有权已转给 m
        sink.deinit();
        defer m.deinit();
        return assembleMaterialized(left.table.io, &jschema, sel, alloc, pg.release(), &m, stamp(left.table.io));
    }

    // 排序路径：交给 `finishFromRows`（它自建投影 + 校验 ORDER BY，再深拷装配）
    return finishFromRows(left.table.io, &jschema, sel, alloc, wide.items);
}

/// 直写路径的「入结果集」：`WHERE` 先判（在宽行上），命中就按投影列写进 sink。
fn sinkJoined(
    sink: *JoinSink,
    wrow: []const sql.Value,
    proj_idx: []const usize,
    sel: sql.Select,
    where_idx: ?usize,
) !void {
    if (sel.where) |w| {
        if (!evalWhere(wrow[where_idx.?], w.op, w.value)) return;
    }
    // 投影列逐个挑出来写进 flat（`ncols` 很小，栈上够用；超宽投影才走分配）
    var buf: [24]sql.Value = undefined;
    if (proj_idx.len <= buf.len) {
        for (proj_idx, 0..) |ci, k| buf[k] = wrow[ci];
        return sink.emit(buf[0..proj_idx.len]);
    }
    const tmp = try sink.alloc.alloc(sql.Value, proj_idx.len);
    defer sink.alloc.free(tmp);
    for (proj_idx, 0..) |ci, k| tmp[k] = wrow[ci];
    try sink.emit(tmp);
}

/// 宽行入结果集前的过滤（`WHERE`）。NULL 参与比较时按 `valueCmp` 的语义走，
/// 所以 `LEFT JOIN` 补出来的 NULL 行在 `WHERE u.x = 'v'` 下会被正确滤除。
fn pushJoined(
    a: std.mem.Allocator,
    wide: *std.ArrayList([]sql.Value),
    row: []sql.Value,
    sel: sql.Select,
    where_idx: ?usize,
) !void {
    if (sel.where) |w| {
        if (!evalWhere(row[where_idx.?], w.op, w.value)) return;
    }
    try wide.append(a, row);
}

/// 把「已解码的宽行」装配成 `Rows`：投影 / 排序 / 输出三段与 `finishFromValues` 同一套逻辑，
/// 区别只在输入已经是值（JOIN 产出），不需要再从行编码解码。
/// 把值深拷进 `buf`（text/blob 指向调用方的临时缓冲或 arena，出了这层就失效）。
/// `off` 是 `buf` 的写游标，调用方保证总字节数已经预先统计好。
inline fn copyValue(buf: []u8, off: *usize, v: sql.Value) sql.Value {
    return switch (v) {
        .text => |x| blk: {
            @memcpy(buf[off.*..][0..x.len], x);
            const sl = buf[off.*..][0..x.len];
            off.* += x.len;
            break :blk .{ .text = sl };
        },
        .blob => |x| blk: {
            @memcpy(buf[off.*..][0..x.len], x);
            const sl = buf[off.*..][0..x.len];
            off.* += x.len;
            break :blk .{ .blob = sl };
        },
        else => v,
    };
}

fn finishFromRows(
    io: std.Io,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
    rows: []const []sql.Value,
) !Rows {
    var t0 = stamp(io);
    // 排序前列校验：比较器不能返回错误，解析失败会静默变成「不排序」
    try validateOrderBy(s, sel.order_by);
    var pg = ProjGuard.take(alloc, try buildProjection(alloc, s, sel.items));
    defer pg.deinit();
    if (timing_enabled) {
        const t1 = stamp(io);
        timing.projection += t1 - t0;
        t0 = t1;
    }
    return finishFromRowsCopy(io, s, sel, alloc, &pg, rows, t0);
}

/// 主体：把 `rows` 深拷成 `Materialized` 后交给 `assembleMaterialized`。
/// `pg` 的释放由调用方的 `defer` 负责；本函数只在交给 `buildOutput` 时 `release()`。
///
/// **只服务「有 `ORDER BY`」的路径**：排序要按未投影的列比较，所以只能全宽拷贝；
/// 无 `ORDER BY` 的 JOIN 走 `JoinSink` 直写（那里能提前投影、全链只搬一次），
/// 不再经过这里 —— 两个分支都留着的话，窄分支就再没有用例走过了（死代码）。
fn finishFromRowsCopy(
    io: std.Io,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
    pg: *ProjGuard,
    rows: []const []sql.Value,
    t0_in: u64,
) !Rows {
    var t0 = t0_in;
    const ncols = s.columns.len;
    // 深拷贝 text/blob：它们指向 JOIN 的 arena，出函数就失效。
    var total: usize = 0;
    for (rows) |r| {
        for (r) |v| switch (v) {
            .text => |x| total += x.len,
            .blob => |x| total += x.len,
            else => {},
        };
    }
    // **三块缓冲直接挂在 `m` 上**，只留一个 `defer m.deinit()`：
    // 旧写法是「三个 errdefer + 最后 `defer m.deinit()`」，一旦 `assembleMaterialized`
    // 返回错误，`m.deinit` 和三个 errdefer 会**各释放一遍** ⇒ double free。
    // `free` 对空切片是安全空操作（`Allocator.free` 第一句就 `if (bytes.len == 0) return`），
    // 所以中途失败时 `m.deinit` 只会释放已经分配出来的那几块。
    var m = Materialized{ .alloc = alloc };
    defer m.deinit();
    m.buf = try alloc.alloc(u8, total);
    m.flat = try alloc.alloc(sql.Value, rows.len * ncols);
    m.hdrs = try alloc.alloc([]sql.Value, rows.len);
    m.ncols = ncols;
    const buf = m.buf;
    const flat = m.flat;
    const hdrs = m.hdrs;

    var off: usize = 0;
    for (rows, 0..) |src, i| {
        const dst = flat[i * ncols ..][0..ncols];
        for (src, 0..) |v, c| dst[c] = copyValue(buf, &off, v);
        hdrs[i] = dst;
    }
    if (timing_enabled) {
        const t1 = stamp(io);
        timing.decode += t1 - t0;
        t0 = t1;
    }
    return assembleMaterialized(io, s, sel, alloc, pg.release(), &m, t0);
}

/// 装配尾部：排序 → OFFSET/LIMIT 切片 → 按投影产出 `Rows`。
///
/// 拆出来是为了让「已经处在最终布局」的调用方（JOIN 的直写路径）**跳过整段拷贝**。
/// `m` 的 `flat/buf/hdrs` 所有权在成功时转给 `Rows`；失败时由调用方的 `defer m.deinit()` 收。
fn assembleMaterialized(
    io: std.Io,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
    proj: Projection,
    m: *Materialized,
    t0_in: u64,
) !Rows {
    var t0 = t0_in;
    if (sel.order_by.len > 0) {
        const ctx = SortCtx{ .schema = s, .order = sel.order_by };
        std.mem.sort([]sql.Value, m.hdrs, ctx, rowLess);
    }

    var start: usize = 0;
    if (sel.offset) |o| start = @min(@as(usize, o), m.hdrs.len);
    var end: usize = m.hdrs.len;
    if (sel.limit) |l| end = @min(end, start + @as(usize, l));

    if (timing_enabled) {
        const t1 = stamp(io);
        timing.sort += t1 - t0;
        t0 = t1;
        timing.calls += 1;
    }
    const out = try buildOutput(alloc, s, m, proj, start, end);
    if (timing_enabled) timing.output += stamp(io) - t0;
    return out;
}

pub fn insertRows(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    ins: sql.Insert,
    alloc: std.mem.Allocator,
) !usize {
    return insertRowsHost(t, s, ins, alloc, null);
}

/// 带索引维护的插入。**先写索引项、再写行**（见文件头「索引宁可多一条脏项」）。
pub fn insertRowsHost(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    ins: sql.Insert,
    alloc: std.mem.Allocator,
    host: ?*const IndexHost,
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
        try putIndexEntries(host, s, mapped, alloc);
        try t.put(key, encoded);
        count += 1;
    }
    return count;
}

const Projection = struct {
    indices: []usize,
    columns: [][]const u8,
};

/// `Projection` 的所有权守卫。
///
/// **为什么必须有一个显式守卫**：`buildOutput` 会**接手** `proj` —— 成功时把 `columns` 交给
/// `Rows`，失败时自己释放（`indices` 一直由它的 `defer` 释放）。而调用方在调用它**之前**
/// 也可能出错，那些路径又得自己释放。两边都「顺手 free 一下」就变成**重复释放**
/// （检查历史：`finishFromValues` / `finishFromRowsCopy` / `selectJoin` 都在 errdefer 里
/// 连 `indices` 一起释放，而 `buildOutput` 内部的 `defer` 已经释放过了 ⇒ OOM 路径 double free），
/// 都不释放则是泄漏。用 `release()` 把所有权交出去，这一层就不再有人猜。
const ProjGuard = struct {
    alloc: std.mem.Allocator,
    proj: Projection = .{ .indices = &.{}, .columns = &.{} },
    owned: bool = false,

    fn take(alloc: std.mem.Allocator, p: Projection) ProjGuard {
        return .{ .alloc = alloc, .proj = p, .owned = true };
    }

    fn release(self: *ProjGuard) Projection {
        self.owned = false;
        return self.proj;
    }

    fn deinit(self: *ProjGuard) void {
        if (!self.owned) return;
        for (self.proj.columns) |c| self.alloc.free(c);
        self.alloc.free(self.proj.columns);
        self.alloc.free(self.proj.indices);
    }
};

/// 列名解析：**完整名优先**，再退化成「裸名唯一匹配」。
///
/// 为什么需要后者：JOIN 的合成 schema 列名是 `表.列`（`t.id`、`u.id`），
/// 而 `SELECT id` 这种写法在 SQL 里仍然要能工作——此时只能靠「裸名在两表里唯一」
/// 来定位；两表都有就叫歧义，必须报错而不是默默取第一个。
pub fn resolveColumn(s: *const schema_mod.Schema, name: []const u8) !usize {
    if (s.indexOf(name)) |i| return i;
    if (std.mem.indexOfScalar(u8, name, '.') != null) return error.ColumnNotFound;
    var found: ?usize = null;
    for (s.columns, 0..) |c, i| {
        const dot = std.mem.lastIndexOfScalar(u8, c.name, '.') orelse continue;
        if (!std.ascii.eqlIgnoreCase(c.name[dot + 1 ..], name)) continue;
        if (found != null) return error.AmbiguousColumn;
        found = i;
    }
    return found orelse error.ColumnNotFound;
}

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
                const idx = try resolveColumn(s, name);
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
    // **不能写成 `return .{ .indices = try ..., .columns = try ... }`**：
    // 前一个 `toOwnedSlice` 成功、后一个失败时，前者的缓冲已经脱离 `indices`
    // （`toOwnedSlice` 会把列表清空），errdefer 里 `deinit` 变空操作 ⇒ 泄漏。
    // 2026-11-03 由 `checkAllAllocationFailures` 当场抓出（16 字节 = 2 个 usize）。
    const idx_slice = try indices.toOwnedSlice(alloc);
    errdefer alloc.free(idx_slice);
    const col_slice = try columns.toOwnedSlice(alloc);
    return .{ .indices = idx_slice, .columns = col_slice };
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

    var pg = ProjGuard.take(alloc, try buildProjection(alloc, s, sel.items));
    defer pg.deinit();

    var vbuf: std.ArrayList(u8) = .empty;
    defer vbuf.deinit(t.alloc); // `t.get` 用自己的分配器填充 ⇒ 同源释放

    const raw = (try t.get(key, &vbuf)) orelse {
        const empty = try alloc.alloc([]sql.Value, 0);
        // **未命中也要收拾 `indices`**：`Rows` 只持有 `columns`，而 `indices` 是
        // `buildProjection` 另分配的。这条分支以前直接 `return` ⇒ 每次「主键查不到」
        // 都漏一个 `[]usize`（用例 `主键点查未命中：返回 0 行且不泄漏` 当场抓出 2 处）。
        const got = pg.release();
        alloc.free(got.indices);
        return .{ .alloc = alloc, .columns = got.columns, .rows = empty };
    };

    const one = [_][]const u8{raw};
    // 点查只要一行，额外做投影裁剪没有意义（单行解码成本可忽略），保持全列。
    var m = try decodeAll(alloc, s, &one, null);
    defer m.deinit();
    return buildOutput(alloc, s, &m, pg.release(), 0, 1);
}

pub fn updateRows(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    upd: sql.Update,
    alloc: std.mem.Allocator,
) !usize {
    return updateRowsHost(t, s, upd, alloc, null);
}

/// 带索引维护的更新。顺序：**新索引项 → 行 → 删旧索引项**（见文件头）。
pub fn updateRowsHost(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    upd: sql.Update,
    alloc: std.mem.Allocator,
    host: ?*const IndexHost,
) !usize {
    var hi: [16]u8 = @splat(0xFF);
    var set = try t.scanRange(&[_]u8{}, &hi);
    defer set.deinit();

    var count: usize = 0;
    for (set.records) |rec| {
        const old_vals = try s.decodeRow(alloc, rec.value);
        defer alloc.free(old_vals);

        var matched = true;
        if (upd.where) |w| {
            const idx = s.indexOf(w.column) orelse return error.ColumnNotFound;
            matched = evalWhere(old_vals[idx], w.op, w.value);
        }
        if (!matched) continue;

        const new_vals = try alloc.dupe(sql.Value, old_vals);
        defer alloc.free(new_vals);
        for (upd.assignments) |a| {
            const idx = s.indexOf(a.column) orelse return error.ColumnNotFound;
            new_vals[idx] = a.value;
        }

        const key = try s.encodeKey(alloc, new_vals);
        defer alloc.free(key);
        const encoded = try s.encodeRow(alloc, new_vals);
        defer alloc.free(encoded);

        try putIndexEntries(host, s, new_vals, alloc); // 可能临时多一条（旧值那条还在）
        if (!std.mem.eql(u8, key, rec.key)) try t.delete(rec.key);
        try t.put(key, encoded);
        try delIndexEntriesIfChanged(host, s, old_vals, new_vals, alloc);
        count += 1;
    }
    return count;
}

/// 更新后删掉「键确实变了」的旧索引项。新旧键相同就什么都不做 ——
/// 否则会把刚写进去的那条删掉，造成索引缺条目（比脏项危险得多）。
fn delIndexEntriesIfChanged(
    host: ?*const IndexHost,
    s: *const schema_mod.Schema,
    old_vals: []const sql.Value,
    new_vals: []const sql.Value,
    alloc: std.mem.Allocator,
) !void {
    const h = host orelse return;
    for (h.schema.indexes) |ix| {
        var old_null = false;
        for (ix.columns) |ci| {
            if (isNullValue(old_vals[ci])) old_null = true;
        }
        if (old_null) continue; // 旧值本就未收录
        const itbl = h.tables.getPtr(ix.name) orelse continue;
        const okey = try s.encodeIndexKey(alloc, ix.columns, old_vals, old_vals[s.pk_index]);
        defer alloc.free(okey);
        var new_null = false;
        for (ix.columns) |ci| {
            if (isNullValue(new_vals[ci])) new_null = true;
        }
        if (new_null) {
            try itbl.delete(okey); // 新值为 NULL → 索引里不该有它
            continue;
        }
        const nkey = try s.encodeIndexKey(alloc, ix.columns, new_vals, new_vals[s.pk_index]);
        defer alloc.free(nkey);
        if (std.mem.eql(u8, okey, nkey)) continue;
        try itbl.delete(okey);
    }
}

pub fn deleteRows(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    del: sql.Delete,
    alloc: std.mem.Allocator,
) !usize {
    return deleteRowsHost(t, s, del, alloc, null);
}

/// 带索引维护的删除。顺序：**先删行、再删索引项**（见文件头）。
pub fn deleteRowsHost(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    del: sql.Delete,
    alloc: std.mem.Allocator,
    host: ?*const IndexHost,
) !usize {
    var hi: [16]u8 = @splat(0xFF);
    var set = try t.scanRange(&[_]u8{}, &hi);
    defer set.deinit();

    var count: usize = 0;
    for (set.records) |rec| {
        // 有索引时必须拿到旧值才能删索引项；没有索引且无 WHERE 时不必解码
        var old_vals: ?[]sql.Value = null;
        defer if (old_vals) |v| alloc.free(v);
        if (del.where != null or host != null) old_vals = try s.decodeRow(alloc, rec.value);

        if (del.where) |w| {
            const idx = s.indexOf(w.column) orelse return error.ColumnNotFound;
            if (!evalWhere(old_vals.?[idx], w.op, w.value)) continue;
        }
        try t.delete(rec.key);
        if (host) |h| try delIndexEntries(h, s, old_vals.?, alloc);
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
    return selectRowsHost(t, s, sel, alloc, null);
}

/// 带二级索引的查询。`host` 为 null 时退化成纯扫描（与改造前完全一致）。
pub fn selectRowsHost(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
    host: ?*const IndexHost,
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

    // 二级索引：`WHERE <已建索引的列> = 常量` → 键前缀扫描 + 回表复核。
    // 聚合/分组不走这条（本来就要全表）；`= NULL` 也不走（永远无匹配）。
    if (host) |h| {
        if (sel.where) |w| {
            if (w.op == .eq) {
                if (s.indexOf(w.column)) |ci| {
                    if (ci != s.pk_index and h.onColumn(ci) != null) {
                        var owned: std.ArrayList([]u8) = .empty;
                        defer {
                            for (owned.items) |x| alloc.free(x);
                            owned.deinit(alloc);
                        }
                        const max: ?usize = if (sel.order_by.len == 0) blk: {
                            const l = sel.limit orelse break :blk null;
                            break :blk @as(usize, sel.offset orelse 0) + @as(usize, l);
                        } else null;
                        try indexCollect(h, t, s, ci, w.value, alloc, &owned, max, null);
                        return finishFromValues(t.io, s, sel, alloc, owned.items);
                    }
                }
            }
        }
    }

    // 二级索引范围：`WHERE <已建索引的列> <op> 常量 LIMIT k`（无 ORDER BY）→ 只扫命中那段键区间。
    //
    // **为什么限定「有 LIMIT 且无 ORDER BY」**：范围谓词的结果集大小事先未知。
    // `WHERE g > 50000` 在 100 万行均匀数据上命中 50 万行 —— 走索引要 50 万次回表，
    // 比顺序全表扫**慢**；而 `... LIMIT 10` 只需从区间起点取 10 条就停，快几个数量级。
    // 有 ORDER BY 时结果必须全量物化，同理不走索引。
    //
    // 可空列**不需要**闸门：`x > 5` 对 NULL 是 UNKNOWN（不匹配），而索引本来就不收 NULL ——
    // 两侧语义一致（与 `ORDER BY <可空索引列>` 那种「漏掉 NULL 就排错」的情形不同）。
    if (host) |h| {
        if (sel.where) |w| {
            if (sel.order_by.len == 0 and sel.limit != null and w.op != .eq and w.op != .ne) {
                if (s.indexOf(w.column)) |ci| {
                    if (ci != s.pk_index and h.onColumn(ci) != null) {
                        var owned: std.ArrayList([]u8) = .empty;
                        defer {
                            for (owned.items) |x| alloc.free(x);
                            owned.deinit(alloc);
                        }
                        const max = @as(usize, sel.offset orelse 0) + @as(usize, sel.limit.?);
                        try indexCollectRange(h, t, s, ci, w.op, w.value, alloc, &owned, max);
                        return finishFromValues(t.io, s, sel, alloc, owned.items);
                    }
                }
            }
        }
    }

    // 索引排序：`ORDER BY <已建索引的非主键列> ASC LIMIT n`（WHERE 可有可无）
    // ⇒ 索引顺序即该列顺序，顺序扫到凑够就停，既不必扫主表也不必对结果排序（§九十七）。
    // 带 WHERE 时谓词在循环里判、且谓词落在排序列上时借索引键下界 seek（§一百零四）。
    //
    // **只对 `NOT NULL` 列启用**：NULL 不入索引（`putIndexEntries` 里 `isNullValue` 直接跳过），
    // 可空列走索引会把 NULL 行整批漏掉 —— 而升序里 NULL 恰恰排在最前面。
    // （把 NULL 也编进索引、按「比任何值都小」排序是后续项；在那之前宁可走全表。）
    if (host) |h| {
        if (sel.order_by.len >= 1 and sel.limit != null) {
            if (findIndexMatchingOrder(s, h, sel.order_by)) |ix| {
                if (try selectByIndexOrder(h, t, s, sel, ix, alloc)) |rows| return rows;
            }
        }
    }

    var hi: [16]u8 = @splat(0xFF);
    // 只收集 value 切片（16B/条），不收集 key/seq/flags（`RefRecord` 是 48B/条）。
    // 100 万行时输出量 48MB -> 16MB，而实测 `scanRefs` 占物化总耗时 66%。
    // 定位：这里只服务 **WHERE 过滤 / LIMIT 提前终止 / ORDER BY + LIMIT 预筛** 三条分支；
    // 「无 WHERE 且无 ORDER BY 且无 LIMIT」的整表物化走 `materializeScan`（一趟走完，不收这个数组）。
    var keep: std.ArrayList([]const u8) = .empty;
    defer keep.deinit(alloc);
    var all_vals: std.ArrayList([]const u8) = .empty;
    defer all_vals.deinit(t.alloc); // `scanValues` 用 `t.alloc` 填 ⇒ 同源释放
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
    //
    // **`ORDER BY <pk> ASC` 也算「天然有序」**：扫描输出本来就是主键升序，
    // 只排 k 行就能得到最终结果，没有任何理由全扫。`ORDER BY <pk> DESC` 走下面的
    // 反向快速路径（`Table.topKDesc`）。
    const pk_order = pkOrderOnly(s, sel.order_by); // null = 排序键不是主键
    const early_ok = sel.order_by.len == 0 or pk_order == false;
    const need: ?usize = if (early_ok and sel.limit != null)
        @as(usize, sel.offset orelse 0) + @as(usize, sel.limit.?)
    else
        null;

    // ------------------------------------------------------------------
    // `ORDER BY <pk> DESC LIMIT k`：SQLite 是「沿 rowid 索引倒着走，走够 k 行就停」，
    // 代价 O(k)。我们原来只有「全表扫描 + top-N 堆」= O(n)，100 万行实测差 1600 倍
    // （0.0006×）。这里改用 `Table.topKDesc`：段尾块定位 + memtable 反向迭代取候选 key，
    // 再逐 key `get()` 拿精确新版本 —— 同样是 O(k log n) 量级。
    //
    // 只在**无 WHERE** 时用：`topKDesc` 不做条件过滤，有 WHERE 时交给全量路径，
    // 免得「先取 k 行再过滤」把结果过滤空了。凑不够 k 行（表太小/尾部全是墓碑）也回退。
    // ------------------------------------------------------------------
    if (pk_order == true and sel.where == null and sel.limit != null) {
        const k = @as(usize, sel.offset orelse 0) + @as(usize, sel.limit.?);
        var top: std.ArrayList([]const u8) = .empty;
        // 「表方法用**自己的**分配器填调用方容器」是本仓的约定（`topKDesc` / `scanValues` /
        // `scanRefs` / `get` 都是），所以释放必须用 `t.alloc`：两个分配器一攻一放属于堆破坏，
        // 生产里两者恰好是同一个对象所以不暴露，但一旦变成「查询用另一个分配器」就会炸。
        defer top.deinit(t.alloc);
        if (k > 0) {
            const t_k = stamp(t.io);
            const hit = try t.topKDesc(k, &top);
            if (timing_enabled) timing.topk += stamp(t.io) - t_k;
            if (hit) return finishFromValues(t.io, s, sel, alloc, top.items);
        }
    }

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
        if (it.corrupt) return error.SegmentCorrupt;
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
            if (it.corrupt) return error.SegmentCorrupt;
            src = keep.items;
        } else {
            // **整表物化快路径**：无 WHERE / 无 ORDER BY / 无 LIMIT 时一趟走完。
            // 100 万行 × 2 列实测 61 ms → 48 ms，归因见 `materializeScan` 的注释。
            if (sel.order_by.len == 0 and sel.limit == null and sel.offset == null) {
                return materializeScanToRows(t, s, sel, alloc);
            }
            // 无 WHERE：cap 接近实际行数，预分配能避免重分配；
            // 但段合并过（大量覆盖/墓碑）时 cap 可能远大于实际，所以封顶 100 万条（16MB）。
            //
            // **这里曾经试过「两遍遍历直接解码」（省掉这 16MB 切片数组），实测是负优化**：
            // 省下的是 16B/条的连续写（约 3ms/100 万行），多付的是一整遍 k 路归并
            // （25 段 100 万行 ≈ 25ms）→ `sql_full` 18.63M → 12.86M（-31%）。
            // 对比 `Table.scanRange` 那个同款改法却是正收益：那里省的是 48B/条（RefRecord）
            // 且只有 20 万行，多一遍归并只 3.6ms。**同一种改法在不同规模下结论相反。**
            try all_vals.ensureTotalCapacity(t.alloc, @min(cap, 1 << 20));
            try t.scanValues(&[_]u8{}, &hi, &all_vals);
            src = all_vals.items;
        }
    }

    // 有 ORDER BY 时排序键按**全列**索引取（`SortCtx` 用 `schema.indexOf`），
    // 所以那种情况下不能按投影解码。
    //
    // 另外 `decodeRowProjected` 是「一趟顺序扫描时顺手跳过未投影列」，要求 want **严格升序**；
    // 而 `SELECT v, id` 会给出 [1,0]、`SELECT id, id` 会给出重复下标 —— 这些都得退回全列解码。
    //
    // **但在交给 `finishFromValues` 之前先做一次 top-N 预筛**：`ORDER BY ... LIMIT k`
    // 只需要前 k 名，而 `finishFromValues` 会把所有候选解码进 `flat/hdrs`（100 万行约 96 MB）
    // 再整体排序 —— 那 99.999% 的工作是白做的（同 §16.1.8 的 LIMIT 提前终止一类）。
    //
    // **只当 `k` 明显小于候选数时才预筛**（2× 判据）：预筛要为此保留的 k 行各拷一份值，
    // 当 k 接近 n 时「少物化 n−k 行」的收益消失、而拷贝的代价还在 ⇒ 反而更慢。
    if (sel.order_by.len > 0 and sel.limit != null) {
        const k = @as(usize, sel.offset orelse 0) + @as(usize, sel.limit.?);
        if (src.len > k *| 2) {
            var top: std.ArrayList([]const u8) = .empty;
            defer top.deinit(alloc);
            try keepTopN(s, sel, alloc, src, k, &top);
            src = top.items;
            return finishFromValues(t.io, s, sel, alloc, src);
        }
    }
    return finishFromValues(t.io, s, sel, alloc, src);
}

/// top-N 预筛的元素：`vals` 是解码后的值（text/blob 指向 `raw`，`raw` 指向段 mmap，
/// 两者在查询期间都稳定），`idx` 是扫描序号（并列时的次级键，保证与「稳定排序后切片」一致）。
const TopItem = struct { vals: []sql.Value, raw: []const u8, idx: usize };

/// `a` 是否比 `b` **差**（即应该优先被淘汰）。堆顶永远是当前最差的那个。
fn topWorse(ctx: SortCtx, a: TopItem, b: TopItem) bool {
    if (rowLess(ctx, a.vals, b.vals)) return false; // a 更好
    if (rowLess(ctx, b.vals, a.vals)) return true; // b 更好 ⇒ a 更差
    return a.idx > b.idx; // 完全并列：后来者更差（保持稳定序）
}

/// `ORDER BY ... LIMIT` 的 top-N 预筛：只保留最好的 k 行（大小顶堆）。
///
/// 只保留**集合**，顺序交给 `finishFromValues`（k 行排序是 O(k log k)，可忽略）——
/// 这样投影 / 偏移 / 输出全部沿用同一条路径，不会出现「top-N 与普通路径行为不一致」。
///
/// 复杂度：每个候选一次解码（本来也要解）+ 只有「比当前第 k 名更好」时才做一次
/// O(log k) 的堆调整。随机数据下替换次数约 k·ln(n)，几乎可以忽略。
fn keepTopN(
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
    src: []const []const u8,
    k: usize,
    out: *std.ArrayList([]const u8),
) !void {
    if (k == 0 or src.len <= k) {
        try out.appendSlice(alloc, src);
        return;
    }
    const ctx = SortCtx{ .schema = s, .order = sel.order_by };
    const ncols = s.columns.len;
    const scratch = try alloc.alloc(sql.Value, ncols);
    defer alloc.free(scratch);
    var heap: std.ArrayList(TopItem) = .empty;
    defer {
        for (heap.items) |h| alloc.free(h.vals);
        heap.deinit(alloc);
    }
    try heap.ensureTotalCapacity(alloc, k);
    try out.ensureTotalCapacity(alloc, k);

    for (src, 0..) |raw, i| {
        try s.decodeRowInto(scratch, raw);
        const cand = TopItem{ .vals = scratch, .raw = raw, .idx = i };
        if (heap.items.len < k) {
            // 堆没满：值数组必须复制（`scratch` 下一行就被覆写）
            const copy = try alloc.alloc(sql.Value, ncols);
            errdefer alloc.free(copy);
            @memcpy(copy, scratch);
            try heap.append(alloc, .{ .vals = copy, .raw = raw, .idx = i });
            // 上浮：**子比父更差**就交换，把更差的顶上去（堆顶＝最差）
            var c = heap.items.len - 1;
            while (c > 0) {
                const p = (c - 1) / 2;
                if (!topWorse(ctx, heap.items[c], heap.items[p])) break;
                std.mem.swap(TopItem, &heap.items[p], &heap.items[c]);
                c = p;
            }
        } else if (topWorse(ctx, heap.items[0], cand)) {
            // 比堆顶（当前第 k 名）更好 ⇒ 顶掉它。
            // **先分配再释放旧值**：反过来写的话，分配失败时堆顶留着野指针，
            // 上面的 defer 会二次释放（OOM 路径上的 double free）。
            const copy = try alloc.alloc(sql.Value, ncols);
            @memcpy(copy, scratch);
            alloc.free(heap.items[0].vals);
            heap.items[0] = .{ .vals = copy, .raw = raw, .idx = i };
            // 下沉：换到**更差的那个孩子**上（`worst` 里放三者中最差的）
            var p: usize = 0;
            while (true) {
                const l = p * 2 + 1;
                const r = l + 1;
                var worst = p;
                if (l < heap.items.len and topWorse(ctx, heap.items[l], heap.items[worst])) worst = l;
                if (r < heap.items.len and topWorse(ctx, heap.items[r], heap.items[worst])) worst = r;
                if (worst == p) break; // 父已经比孩子都差，堆序恢复
                std.mem.swap(TopItem, &heap.items[p], &heap.items[worst]);
                p = worst;
            }
        }
    }
    // 按**扫描顺序**交回（而不是堆序）：后续 `finishFromValues` 用的是稳定排序，
    // 顺序恢复成扫描序后，「并列行」的最终次序与「稳定排序再切片」逐行一致。
    std.mem.sort(TopItem, heap.items, {}, topIdxLess);
    for (heap.items) |h| try out.append(alloc, h.raw);
}

fn topIdxLess(_: void, a: TopItem, b: TopItem) bool {
    return a.idx < b.idx;
}

/// 把「已定位到的一组行值」装配成 `Rows`：投影 → 解码 → 排序 → LIMIT → 输出。
///
/// 全表扫描与索引扫描共用这一段 —— 两条路径若各写一份装配逻辑，迟早会出现
/// 「走索引时 ORDER BY 不生效」这种只在一半场景里错的 bug。
/// 整表物化：**一趟归并，边取、边拷字节、边解码**。
///
/// 为什么要有这条（2026-11-04 实测，1M 行 × 2 列，`mat_*` 探针）：
///
/// | 阶段 | 耗时 |
/// |---|---|
/// | 归并遍历地板（只走 `MergeIter` 只计数）| **30 ms** |
/// | 收集 value 切片到 `all_vals` | 5 ms |
/// | 把 42 MB payload 拷进 `buf` | 11 ms |
/// | 从 `buf` 解码进 `flat` | 12.5 ms |
/// | 建 `hdrs` 指针数组 | 2 ms |
///
/// 前两步里，「收集 16 MB 切片数组」**只为了知道 `buf` 要多大** —— 而 `flat`/`hdrs`
/// 又要在下游再走一遍才能填。两趟都是白走的。
///
/// 段头部（`Segment.rows` / `file_size`，**不需要 `ensureParsed()`**）与 memtable 计数
/// 已经给出上界，于是可以一次分配、一趟填完；解码时数据还在 L1 里（流式路径
/// `forEachRow` 的解码只要 ~7 ns/行，而这里从冷 `buf` 解要 12.5 ns/行）。
///
/// 上界只是**虚拟**地址：没写到的页不会缺页，所以偏大几乎不花钱；最后按实际大小收缩。
/// 这里**不能**用「先统计再第二遍填」（`decodeAllRange` 当初就是这么写的）：
/// 多一整遍归并 25 ms，只省 3 ms，实测 -31%。
fn materializeScan(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    alloc: std.mem.Allocator,
    want: ?[]const usize,
) !Materialized {
    const ncols = if (want) |w| w.len else s.columns.len;

    // 行数上界 = memtable 行数 + 各段行数（段合并过时偏大：同 key 多版本/墓碑会被归并掉）
    // 字节上界 = memtable 字节 + 各段数据文件大小（含每条 7B 记录头，同样偏大）
    //
    // **`file_size` 只有 `dataView()` 之后才有值**（它是懒映射的副产物）：刚 flush 出来的段
    // 还没被读过，这里若直接取 `file_size` 会拿到 0 —— 第一版就是这么写的，导致
    // `ub_bytes == 0`、直接把整表当空表返回（4 个用例当场红，包括「聚合 1000 行」）。
    // 全表扫描本来就要映射每一个段，所以这里提前映射不算额外代价。
    var ub_rows: usize = t.mem.len();
    var ub_bytes: u64 = t.mem.sizeBytes();
    for (t.segs.items) |*sg| {
        ub_rows +|= sg.rows;
        ub_bytes +|= try sg.dataBytes();
    }
    if (ub_rows == 0) return try decodeAll(alloc, s, &.{}, want);

    var flat = try alloc.alloc(sql.Value, ub_rows * ncols);
    errdefer alloc.free(flat);
    var hdrs = try alloc.alloc([]sql.Value, ub_rows);
    errdefer alloc.free(hdrs);
    var buf = try alloc.alloc(u8, @intCast(ub_bytes));
    errdefer alloc.free(buf);

    var hi: [16]u8 = @splat(0xFF);
    var it = tablemod.MergeIter{};
    try it.init(t, &.{}, &hi);
    defer it.deinit();

    var n: usize = 0;
    var off: usize = 0;
    while (it.next()) |rec| {
        // 上界是**构造性**保证的（每条 yield 的记录都来自某个游标，其 value 指向该段的
        // mmap 且长度计入该段文件大小），但这里仍然真检查而不是靠 `assert`：
        // `assert` 在 ReleaseFast 下是空的，真越界就是静默堆溢出。
        if (n >= ub_rows or off + rec.value.len > buf.len) return error.ScanBoundExceeded;
        const raw = buf[off..][0..rec.value.len];
        @memcpy(raw, rec.value);
        off += rec.value.len;
        const vals = flat[n * ncols ..][0..ncols];
        if (want) |w| try s.decodeRowProjected(vals, w, raw) else try s.decodeRowInto(vals, raw);
        hdrs[n] = vals;
        n += 1;
    }
    if (it.corrupt) return error.SegmentCorrupt;

    // 收缩到实际大小（`Rows` 按 len 释放，绝不能把上界长度传出去）。
    //
    // **两条顺序/取舍都必须遵守**：
    // ① `hdrs[i]` 是**指进 `flat` 的切片**，`flat` 一旦 realloc 搬家，hdrs 立刻悬垂
    //    ⇒ 先收缩 flat、按新基址重建 hdrs、再收缩 hdrs；
    // ② `buf` **绝不收缩**：`flat` 里的 text/blob 值是指进 `buf` 的切片，realloc 搬家后
    //    这些指针没有任何办法跟着修正（逐条记录 payload 偏移才能修，那是额外 4B/行）。
    //    上界超出的部分只是**没写过的虚拟地址**，不缺页也不占物理内存。
    //    第一版两条都踩了：`SELECT *` 在多段表上直接返回垃圾值（被
    //    「融合路径与两遍路径逐格一致」用例当场抓住）。
    if (n != ub_rows) {
        if (n == 0) {
            alloc.free(flat);
            alloc.free(hdrs);
            flat = &.{};
            hdrs = &.{};
        } else {
            flat = try alloc.realloc(flat, n * ncols);
            for (0..n) |j| hdrs[j] = flat[j * ncols ..][0..ncols];
            hdrs = try alloc.realloc(hdrs, n);
        }
    }
    return .{ .alloc = alloc, .buf = buf, .flat = flat, .hdrs = hdrs, .ncols = ncols, .pushed = want != null };
}

/// `materializeScan` 的投影层：与 `finishFromValues` 的「无排序 / 无截断」分支等价。
fn materializeScanToRows(
    t: *tablemod.Table,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
) !Rows {
    var pg = ProjGuard.take(alloc, try buildProjection(alloc, s, sel.items));
    defer pg.deinit();
    const proj = pg.proj;
    // 与 `finishFromValues` 同一条判据：`decodeRowProjected` 要求 want **严格升序**。
    const ascending = blk: {
        for (proj.indices, 0..) |v, k| {
            if (k > 0 and v <= proj.indices[k - 1]) break :blk false;
        }
        break :blk true;
    };
    const want: ?[]const usize = if (ascending) proj.indices else null;
    var m = try materializeScan(t, s, alloc, want);
    defer m.deinit();
    return buildOutput(alloc, s, &m, pg.release(), 0, m.hdrs.len);
}

fn finishFromValues(
    io: std.Io,
    s: *const schema_mod.Schema,
    sel: sql.Select,
    alloc: std.mem.Allocator,
    src: []const []const u8,
) !Rows {
    var t0 = stamp(io);
    // 排序前列校验：比较器不能返回错误，解析失败会静默变成「不排序」
    try validateOrderBy(s, sel.order_by);
    var pg = ProjGuard.take(alloc, try buildProjection(alloc, s, sel.items));
    defer pg.deinit();
    const proj = pg.proj;
    if (timing_enabled) {
        const t1 = stamp(io);
        timing.projection += t1 - t0;
        t0 = t1;
    }

    const ascending = blk: {
        for (proj.indices, 0..) |v, k| {
            if (k > 0 and v <= proj.indices[k - 1]) break :blk false;
        }
        break :blk true;
    };
    const want: ?[]const usize = if (sel.order_by.len == 0 and ascending) proj.indices else null;
    var m = try decodeAll(alloc, s, src, want);
    defer m.deinit();
    if (timing_enabled) {
        const t1 = stamp(io);
        timing.decode += t1 - t0;
        t0 = t1;
    }

    if (sel.order_by.len > 0) {
        const ctx = SortCtx{ .schema = s, .order = sel.order_by };
        std.mem.sort([]sql.Value, m.hdrs, ctx, rowLess);
    }

    var start: usize = 0;
    if (sel.offset) |o| start = @min(@as(usize, o), m.hdrs.len);
    var end: usize = m.hdrs.len;
    if (sel.limit) |l| end = @min(end, start + @as(usize, l));

    if (timing_enabled) {
        const t1 = stamp(io);
        timing.sort += t1 - t0;
        t0 = t1;
        timing.calls += 1;
    }
    const out = try buildOutput(alloc, s, &m, pg.release(), start, end);
    if (timing_enabled) timing.output += stamp(io) - t0;
    return out;
}

/// 流式查询：逐行解码到**复用的 scratch**，回调消费，**不物化结果集**。///
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

/// 聚合的规范列名：`sum(x)` / `count(*)`。**输出列名与 ORDER BY 匹配用同一份**，
/// 两处各拼一次字符串迟早会不一致。
fn aggLabel(alloc: std.mem.Allocator, a: sql.Agg) ![]const u8 {
    return if (a.column) |c|
        try alloc.print("{s}({s})", .{ aggFuncName(a.func), c })
    else
        try alloc.print("{s}(*)", .{aggFuncName(a.func)});
}

/// 隐藏排序列去重：同一个来源只占一个槽，返回已有或新建的槽下标。
fn hiddenSlot(alloc: std.mem.Allocator, hidden: *std.ArrayList(OutSrc), src: OutSrc) !usize {
    for (hidden.items, 0..) |h, i| {
        const same = switch (h) {
            .grp => |a| switch (src) {
                .grp => |b| a == b,
                else => false,
            },
            .agg => |a| switch (src) {
                .agg => |b| a == b,
                else => false,
            },
        };
        if (same) return i;
    }
    try hidden.append(alloc, src);
    return hidden.items.len - 1;
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

/// 输出行排序上下文：聚合结果的 `ORDER BY` 按**输出列名或隐藏列**匹配。
///
/// `pos` 是「stride 位置」：`0..out_n` 是输出列，`out_n..` 是只参与排序、不进结果集的
/// 隐藏列（`ORDER BY g` 而 `g` 未被选中、或 `ORDER BY sum(x)` 而 `sum(x)` 未输出）。
const GroupSortCtx = struct {
    flat: []const sql.Value,
    ncols: usize,
    order: []const sql.OrderItem,
    /// 与 `order` 一一对应的 stride 位置（排序前解析一次）。
    /// 不在比较函数里按列名查 —— 10 万组时那是 n·log n 次字符串比较。
    pos: []const usize,
};

fn groupRowLess(ctx: GroupSortCtx, a: usize, b: usize) bool {
    for (ctx.order, ctx.pos) |o, ci| {
        const ord = schema_mod.valueCmp(ctx.flat[a * ctx.ncols + ci], ctx.flat[b * ctx.ncols + ci]);
        if (ord == .eq) continue;
        return if (o.desc) ord == .gt else ord == .lt;
    }
    return false;
}

/// 把规范化的聚合列名（`sum(x)` / `count(*)`）解回聚合描述。
///
/// `ORDER BY` 的目标在解析阶段已被归一到这种文本，这里必须用**同一张名字表**解回去，
/// 否则 `ORDER BY SUM(x)` 会变成“查不到列”。
fn parseAggTarget(text: []const u8) ?sql.Agg {
    const lp = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    if (text.len < lp + 2 or text[text.len - 1] != ')') return null;
    const func = sql.aggFuncFromName(text[0..lp]) orelse return null;
    const inner = text[lp + 1 .. text.len - 1];
    if (std.mem.eql(u8, inner, "*")) {
        if (func != .count) return null;
        return .{ .func = func, .column = null };
    }
    return .{ .func = func, .column = inner };
}

/// 取一组某一列的值（输出列与隐藏列共用）。
fn groupCell(g: *const Group, src: OutSrc, specs: []const AggSpec) !sql.Value {
    return switch (src) {
        .grp => |k| g.keys[k],
        .agg => |k| try accValue(&g.aggs[k], specs[k].func),
    };
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

    // ---- 1.6) 输出列名（提前算：ORDER BY 要靠它匹配）----
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
            .aggregate => |a| try aggLabel(alloc, a),
        };
        cols_done += 1;
    }

    // ---- 1.7) ORDER BY 可以引用「没被选中的分组键 / 聚合」→ 做成隐藏列 ----
    //
    // SQLite 接受 `SELECT COUNT(*) FROM t GROUP BY g ORDER BY g`（实测 3.53.2，见
    // tools/bench-vs-sqlite/src/bin/having_semantics.rs 的 Q7）；我们原先报 ColumnNotFound。
    // 做法：这些列参与排序、**不进结果集** —— 输出仍然只有 `sel.items` 那几列。
    var order_pos_list: std.ArrayList(usize) = .empty;
    defer order_pos_list.deinit(alloc);
    var hidden: std.ArrayList(OutSrc) = .empty;
    defer hidden.deinit(alloc);
    if (sel.order_by.len > 0) {
        // 匹配顺序很重要：**输出列优先**。否则一个名字长得像聚合的输出列
        // （例如有人真建了 `[sum(x)]` 这么个列）会先被当成聚合表达式，
        // 一旦内层列不存在就直接误报 ColumnNotFound。
        const outputIndexOf = struct {
            fn get(cols: [][]const u8, text: []const u8) ?usize {
                for (cols, 0..) |cn, ci| {
                    if (std.ascii.eqlIgnoreCase(cn, text)) return ci;
                }
                return null;
            }
        }.get;

        // 第一步：把隐藏聚合的槽先建好 —— 必须在算 `need` 之前，
        // 否则 `ORDER BY SUM(x)`（x 未被选中）的参数列不会被解码。
        for (sel.order_by) |o| {
            if (outputIndexOf(columns, o.column) != null) continue; // 是输出列，不是隐藏聚合
            const agg = parseAggTarget(o.column) orelse continue;
            const ci: ?usize = if (agg.column) |c| (s.indexOf(c) orelse return error.ColumnNotFound) else null;
            var found = false;
            for (specs.items) |sp| {
                if (sp.func == agg.func and sp.col_idx == ci) {
                    found = true;
                    break;
                }
            }
            if (!found) try specs.append(alloc, .{ .func = agg.func, .col_idx = ci });
        }

        for (sel.order_by) |o| {
            var at: ?usize = outputIndexOf(columns, o.column);
            // 2) 聚合（隐藏）
            if (at == null) {
                if (parseAggTarget(o.column)) |agg| {
                    const ci: ?usize = if (agg.column) |c| (s.indexOf(c) orelse return error.ColumnNotFound) else null;
                    for (specs.items, 0..) |sp, si| {
                        if (sp.func != agg.func or sp.col_idx != ci) continue;
                        at = out_n + (try hiddenSlot(alloc, &hidden, .{ .agg = si }));
                        break;
                    }
                }
            }
            // 3) 分组键（隐藏）
            if (at == null) {
                for (sel.group_by, 0..) |gname, gi| {
                    if (!std.ascii.eqlIgnoreCase(gname, o.column)) continue;
                    at = out_n + (try hiddenSlot(alloc, &hidden, .{ .grp = gi }));
                    break;
                }
            }
            try order_pos_list.append(alloc, at orelse return error.ColumnNotFound);
        }
    }
    const order_pos = order_pos_list.items;

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

    // ---- 4) 每组算一行，再按 HAVING / ORDER BY / LIMIT 取子集 ----
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
    // 步长 = 输出列 + 隐藏排序列（隐藏列只参与排序）
    const stride = out_n + hidden.items.len;
    const flat0 = try alloc.alloc(sql.Value, nkeep * stride);
    defer alloc.free(flat0);
    for (kept.items, 0..) |gi, r| {
        const g = &groups.items[gi];
        for (src_of, 0..) |src, ci| flat0[r * stride + ci] = try groupCell(g, src, specs.items);
        for (hidden.items, 0..) |src, hk| flat0[r * stride + out_n + hk] = try groupCell(g, src, specs.items);
    }

    const order_idx = try alloc.alloc(usize, nkeep);
    defer alloc.free(order_idx);
    for (order_idx, 0..) |*p, i| p.* = i;
    if (sel.order_by.len > 0) {
        const ctx = GroupSortCtx{ .flat = flat0, .ncols = stride, .order = sel.order_by, .pos = order_pos };
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
            const v = flat0[gi * stride + ci];
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
    // 流式回调路径：损坏必须报错。`emitted >= lim` 的 break 是提前终止（正常），但
    // 损坏与「凑够了」在同一处退出时仍应报错 —— 宁可让调用方看到错误也不给他半份数据。
    if (it.corrupt) return error.SegmentCorrupt;
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

test "ORDER BY + LIMIT：top-N 预筛与全量排序结果逐行一致（含并列）" {
    // 预筛把「全量物化 + 全量排序」降成「只留前 k 行」，最容易走样的是**并列行**的次序：
    // 老路径是「稳定排序后切片」，新路径是「堆里替换」。这里用对照组验证两者逐行相同。
    //
    // 对照组故意写 `LIMIT 300`（= 行数），使 `src.len > k` 不成立 ⇒ 走全量排序老路径。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-topn";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "n", .col_type = .integer },
        .{ .name = "g", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "t", &cols);
    defer s.deinit(alloc);
    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    // 300 行；n 只有 7 个取值（大量并列），g 只有 3 个取值
    {
        var i: i64 = 0;
        while (i < 300) : (i += 1) {
            var vals = [_]sql.Value{
                .{ .integer = i },
                .{ .integer = @mod(i * 13, 7) },
                .{ .integer = @mod(i, 3) },
            };
            var row = [_][]sql.Value{&vals};
            _ = try insertRows(&t, &s, .{ .table = "t", .columns = &.{ "id", "n", "g" }, .rows = &row }, alloc);
        }
    }

    var star = [_]sql.SelectItem{.{ .star = {} }};
    var proj = [_]sql.SelectItem{ .{ .column = "id" }, .{ .column = "n" } };
    var ord_n_desc = [_]sql.OrderItem{.{ .column = "n", .desc = true }};
    var ord_n_asc = [_]sql.OrderItem{.{ .column = "n" }};
    var ord_two = [_]sql.OrderItem{ .{ .column = "n", .desc = true }, .{ .column = "id", .desc = true } };
    var ord_g = [_]sql.OrderItem{.{ .column = "g" }};
    // 主键排序：走 `Table.topKDesc`（降序）/ 提前终止（升序）两条快速路径
    var ord_pk_desc = [_]sql.OrderItem{.{ .column = "id", .desc = true }};
    var ord_pk_asc = [_]sql.OrderItem{.{ .column = "id" }};

    const cases = [_]struct {
        items: []sql.SelectItem,
        order: []sql.OrderItem,
        offset: ?u32,
        limit: u32,
    }{
        .{ .items = &star, .order = &ord_n_desc, .offset = null, .limit = 10 },
        .{ .items = &proj, .order = &ord_n_asc, .offset = 5, .limit = 10 },
        .{ .items = &star, .order = &ord_two, .offset = null, .limit = 7 },
        .{ .items = &proj, .order = &ord_g, .offset = 0, .limit = 4 },
        .{ .items = &star, .order = &ord_n_desc, .offset = null, .limit = 1 },
        // offset+limit 刚好 290（< 300 ⇒ 触发预筛），且落在并列最多的尾部
        .{ .items = &star, .order = &ord_g, .offset = 250, .limit = 40 },
        // 主键降序（`Table.topKDesc` 快速路径）与主键升序（提前终止路径）
        .{ .items = &star, .order = &ord_pk_desc, .offset = null, .limit = 10 },
        .{ .items = &proj, .order = &ord_pk_desc, .offset = 7, .limit = 10 },
        .{ .items = &star, .order = &ord_pk_desc, .offset = null, .limit = 1 },
        .{ .items = &star, .order = &ord_pk_asc, .offset = 3, .limit = 10 },
        // 大 LIMIT（几乎取全表）也必须与全量对照一致：这条覆盖「k 接近表大小」时
        // 快速路径 / 回退路径的分界（`Options.topk_desc_max`）
        .{ .items = &star, .order = &ord_pk_desc, .offset = null, .limit = 250 },
    };

    for (cases, 0..) |c, ci| {
        const off: usize = c.offset orelse 0;
        var full = try selectRows(&t, &s, .{
            .items = c.items,
            .table = "t",
            .order_by = c.order,
            .limit = 300,
        }, alloc);
        defer full.deinit();
        var got = try selectRows(&t, &s, .{
            .items = c.items,
            .table = "t",
            .order_by = c.order,
            .offset = c.offset,
            .limit = c.limit,
        }, alloc);
        defer got.deinit();
        if (got.rows.len != c.limit) {
            std.debug.print("case {d}: 行数 {d} != {d}\n", .{ ci, got.rows.len, c.limit });
            return error.RowCountMismatch;
        }
        for (got.rows, 0..) |row, ri| {
            const want = full.rows[off + ri];
            if (want.len != row.len) return error.ColCountMismatch;
            for (want, row) |w, g| {
                if (schema_mod.valueCmp(w, g) != .eq) {
                    std.debug.print("case {d}: 第 {d} 行值不一致\n  want={any}\n  got ={any}\n", .{ ci, ri, want, row });
                    return error.ValueMismatch;
                }
            }
        }
    }

    // 超过 `Options.topk_desc_max` 的大 LIMIT 必须**回退全量路径**且结果仍正确
    // （审计项：快速路径在 k 大时反而更慢，回退后不能悄悄变成少行/乱序）
    {
        var big = try selectRows(&t, &s, .{
            .items = &star,
            .table = "t",
            .order_by = &ord_pk_desc,
            .limit = 5000,
        }, alloc);
        defer big.deinit();
        try std.testing.expectEqual(@as(usize, 300), big.rows.len);
        try std.testing.expect(schema_mod.valueCmp(big.rows[0][0], .{ .integer = 299 }) == .eq);
        try std.testing.expect(schema_mod.valueCmp(big.rows[299][0], .{ .integer = 0 }) == .eq);
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

test "整表物化融合路径与两遍路径逐格一致（多段/墓碑/多版本/投影）" {
    // 背景（2026-11-04）：给「无 WHERE / 无 ORDER BY / 无 LIMIT」的整表物化加了
    // 一条**一趟走完**的快路径（`materializeScan`）：段头部给出上界，一次分配，
    // 边遍历边拷字节边解码。同进程 A/B 实测 63 → 55.5 ms（6/6）。
    //
    // 代价是**同一段语义存在两处实现**（本仓明令禁止的形态）。所以必须有这条用例：
    // 同一查询分别走两条路（`offset` 缺省 = 融合；显式 `OFFSET 0` = 原来的
    // 「收集切片 → decodeAll」），**逐行逐列比对**。任一侧将来漂移，这条立刻红。
    //
    // 故意造出「上界偏大」的形态：多段 + 覆盖写 + 墓碑 —— 那样融合路径必须走
    // 「收缩到实际大小」的分支，而不是只在整齐数据上凑巧对。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-fuse-tmp";
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

    // 第 1 段
    var i: i64 = 0;
    while (i < 120) : (i += 1) {
        var vals = [_]sql.Value{ .{ .integer = i }, .{ .integer = @mod(i, 5) }, .{ .text = "first" } };
        var row = [_][]sql.Value{&vals};
        _ = try insertRows(&t, &s, .{ .table = "t", .columns = &.{ "id", "n", "s" }, .rows = &row }, alloc);
    }
    try t.flush();
    // 第 2 段：覆盖写一批（同 key 新版本 → 归并时要丢掉旧版本，上界因此偏大）
    i = 0;
    while (i < 60) : (i += 1) {
        var vals = [_]sql.Value{ .{ .integer = i * 2 }, .{ .integer = 9 }, .{ .text = "second" } };
        var row = [_][]sql.Value{&vals};
        _ = try insertRows(&t, &s, .{ .table = "t", .columns = &.{ "id", "n", "s" }, .rows = &row }, alloc);
    }
    try t.flush();
    // 第 3 段：删除一批（墓碑也要被归并丢掉）
    i = 0;
    while (i < 30) : (i += 1) {
        _ = try deleteRows(&t, &s, .{ .table = "t", .where = .{ .column = "id", .op = .eq, .value = .{ .integer = i * 3 + 1 } } }, alloc);
    }
    try t.flush();
    // memtable 里也留几行（上界要把 memtable 算进来）
    i = 0;
    while (i < 10) : (i += 1) {
        var vals = [_]sql.Value{ .{ .integer = 500 + i }, .{ .integer = 1 }, .{ .text = "mem" } };
        var row = [_][]sql.Value{&vals};
        _ = try insertRows(&t, &s, .{ .table = "t", .columns = &.{ "id", "n", "s" }, .rows = &row }, alloc);
    }

    // 防空跑：真的有多段、真的有墓碑与多版本
    try std.testing.expect(t.segs.items.len >= 3);
    try std.testing.expect(t.mem.len() > 0);

    var star = [_]sql.SelectItem{.{ .star = {} }};
    var two_desc = [_]sql.SelectItem{ .{ .column = "n" }, .{ .column = "id" } };
    var only_id = [_]sql.SelectItem{.{ .column = "id" }};
    var only_s = [_]sql.SelectItem{.{ .column = "s" }};

    const cases = [_]sql.Select{
        .{ .items = &star, .table = "t" }, // 恒等投影 + 全列解码
        .{ .items = &two_desc, .table = "t" }, // want 非升序 ⇒ 全列解码 + pflat 重排
        .{ .items = &only_id, .table = "t" }, // 投影下推（decodeRowProjected）
        .{ .items = &only_s, .table = "t" }, // text 列投影
    };

    for (cases, 0..) |sel, ci| {
        // 显式 `OFFSET 0` ⇒ 不命中融合路径，走「收集切片 → decodeAll」
        var legacy = sel;
        legacy.offset = 0;
        var a = try selectRows(&t, &s, sel, alloc);
        defer a.deinit();
        var b = try selectRows(&t, &s, legacy, alloc);
        defer b.deinit();
        if (a.rows.len != b.rows.len) {
            std.debug.print("case {d}: 行数不一致 fuse={d} legacy={d}\n", .{ ci, a.rows.len, b.rows.len });
            return error.RowCountMismatch;
        }
        try std.testing.expect(a.rows.len > 0); // 防空跑
        for (a.rows, b.rows) |ra, rb| {
            if (ra.len != rb.len) return error.ColCountMismatch;
            for (ra, rb) |va, vb| {
                if (schema_mod.valueCmp(va, vb) != .eq) {
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
        var p = try sql.parse(alloc, "INSERT INTO agg (id, g, x, t) VALUES (1, 1, 10, 'a'), (2, 1, 20, 'b'), " ++
            "(3, 2, 5, 'c'), (4, 2, NULL, NULL), (5, 2, 7, 'e')");
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    {
        var p = try sql.parse(alloc, "SELECT g, COUNT(*), COUNT(x), SUM(x), AVG(x), MIN(x), MAX(x) FROM agg GROUP BY g ORDER BY g");
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
        var p = try sql.parse(alloc, "SELECT t, COUNT(*), MIN(id), MAX(id) FROM agg GROUP BY t ORDER BY count(*) DESC LIMIT 2");
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
        var p = try sql.parse(alloc, "INSERT INTO h (id, g, x) VALUES (1,1,10), (2,1,20), (3,2,5), (4,3,NULL), (5,4,1), (6,4,2), (7,4,3)");
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
        var p = try sql.parse(alloc, "SELECT g, SUM(x) FROM h GROUP BY g HAVING SUM(x) > 0 ORDER BY sum(x) DESC LIMIT 2");
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
        var p = try sql.parse(alloc, "INSERT INTO wh (id, g, x, s) VALUES (1,1,1,'b'), (2,1,2,'a'), (3,1,3,'c'), " ++
            "(4,2,10,'z'), (5,2,20,'y'), (6,3,100,'m')");
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    // WHERE x < 10 只剩 g=1 的 3 行与 g=2 的 1 行（x=10 被排除），
    // 再 HAVING COUNT(*) >= 2 → 只剩 g=1（3 行）；g=2 只有 1 行被淘汰。
    // 若把两个过滤顺序弄反（先 HAVING 再 WHERE），g=2 会被保留 → 结果不同。
    {
        var p = try sql.parse(alloc, "SELECT g, COUNT(*), SUM(x) FROM wh WHERE x < 10 GROUP BY g HAVING COUNT(*) >= 2 ORDER BY g");
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

test "ORDER BY 可引用未选中的分组键 / 聚合（隐藏列）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-hidden-order";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "g", .col_type = .integer },
        .{ .name = "x", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "ho", &cols);
    defer s.deinit(alloc);
    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    {
        // g=1: 10,20(2 行) / g=2: 5(1) / g=3: NULL(1) / g=4: 1,2,3(3)
        var p = try sql.parse(alloc, "INSERT INTO ho (id, g, x) VALUES (1,1,10), (2,1,20), (3,2,5), (4,3,NULL), (5,4,1), (6,4,2), (7,4,3)");
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    // Q7：`g` 没被选中，但 ORDER BY 引用了它（SQLite 3.53.2 接受；我们原先报 ColumnNotFound）
    {
        var p = try sql.parse(alloc, "SELECT COUNT(*) FROM ho GROUP BY g ORDER BY g");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
        // 隐藏列不能泄漏到结果集：每行仍只有 1 列
        for (rows.rows) |r| try std.testing.expectEqual(@as(usize, 1), r.len);
        try std.testing.expectEqual(@as(usize, 1), rows.columns.len);
        // 按 g 升序 → 各组行数 2,1,1,3（与 SQLite 实测一致）
        try std.testing.expectEqual(@as(i64, 2), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[1][0].integer);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[2][0].integer);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[3][0].integer);
    }

    // 聚合没被选中但用于排序：`ORDER BY SUM(x) DESC` → 30(g1) / 6(g4) / 5(g2) / NULL(g3)
    {
        var p = try sql.parse(alloc, "SELECT g FROM ho GROUP BY g ORDER BY SUM(x) DESC");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
        for (rows.rows) |r| try std.testing.expectEqual(@as(usize, 1), r.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 4), rows.rows[1][0].integer);
        try std.testing.expectEqual(@as(i64, 2), rows.rows[2][0].integer);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[3][0].integer); // SUM 为 NULL，降序排最后
    }

    // 两个排序键都与输出无关（一个聚合 + 一个分组键），并且要能去重（只算一次）
    {
        var p = try sql.parse(alloc, "SELECT g FROM ho GROUP BY g ORDER BY COUNT(*) DESC, g ASC");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
        // 行数 3(g4) / 2(g1) / 1(g2) / 1(g3)；并列的 g2<g3 按 g 升序
        try std.testing.expectEqual(@as(i64, 4), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[1][0].integer);
        try std.testing.expectEqual(@as(i64, 2), rows.rows[2][0].integer);
        try std.testing.expectEqual(@as(i64, 3), rows.rows[3][0].integer);
    }

    // 既不是输出列、也不是分组键/聚合 → 仍然要报错（不能静默不排序）
    {
        var p = try sql.parse(alloc, "SELECT g FROM ho GROUP BY g ORDER BY x");
        defer p.deinit();
        try std.testing.expectError(error.ColumnNotFound, selectRows(&t, &s, p.stmt.select, alloc));
    }
}

test "ORDER BY 匹配顺序：名字长得像聚合的输出列不能被当成聚合表达式" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-exec-aggish-name";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    // 故意把列名起成 `sum(x)`：如果 ORDER BY 的解析先按聚合表达式匹配，
    // 就会去找一个叫 `x` 的列（不存在）→ 误报 ColumnNotFound。
    const cols = [_]schema_mod.Column{
        .{ .name = "id", .col_type = .integer, .primary_key = true },
        .{ .name = "sum(x)", .col_type = .integer },
    };
    var s = try schema_mod.Schema.init(alloc, "aggish", &cols);
    defer s.deinit(alloc);
    var t = try tablemod.Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    {
        var p = try sql.parse(alloc, "INSERT INTO aggish (id, [sum(x)]) VALUES (1, 7), (2, 9)");
        defer p.deinit();
        _ = try insertRows(&t, &s, p.stmt.insert, alloc);
    }

    // 分组键就是那个「像聚合」的列；ORDER BY 引用它 → 必须走输出列路径，不能报错
    {
        var p = try sql.parse(alloc, "SELECT [sum(x)], COUNT(*) FROM aggish GROUP BY [sum(x)] ORDER BY [sum(x)]");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 7), rows.rows[0][0].integer);
        try std.testing.expectEqual(@as(i64, 9), rows.rows[1][0].integer);
        try std.testing.expectEqualStrings("sum(x)", rows.columns[0]); // 列名原样保留
        try std.testing.expectEqualStrings("count(*)", rows.columns[1]);
    }

    // 对照：真正的聚合排序仍然要能工作（`ORDER BY sum(id)` 而 sum(id) 未输出）
    {
        var p = try sql.parse(alloc, "SELECT [sum(x)] FROM aggish GROUP BY [sum(x)] ORDER BY SUM(id) DESC");
        defer p.deinit();
        var rows = try selectRows(&t, &s, p.stmt.select, alloc);
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        // 每组只有 1 行：SUM(id) 就是该行的 id → 降序 9 在前
        try std.testing.expectEqual(@as(i64, 9), rows.rows[0][0].integer);
    }
}
