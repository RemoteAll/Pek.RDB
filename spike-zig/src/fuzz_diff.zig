// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。

//! **差分随机测试**：随机生成查询 → 用一份**独立的朴素参考实现**算一遍 →
//! 与引擎结果逐格比对。
//!
//! 为什么要有这个文件：此前的审计是「读上一个 diff，想可能错在哪」，本质是**抽样**。
//! 仓库里有 360 个分配点、2900 个 `try`、20 种查询形态，抽样必然每轮只捞到一两处，
//! 于是「每审一次就冒出新问题」。内存类缺陷已经交给 `checkAllAllocationFailures`
//! （见 `engine.zig` 末尾的守卫），**语义类缺陷（索引/全扫不一致、排序、LIMIT/OFFSET、
//! NULL、JOIN 路径分歧）一直没有机械手段** —— 这个文件补的就是那一半。
//!
//! 参考实现刻意写得**又笨又直白**（全表线性过滤 + 排序），不复用引擎任何代码路径；
//! 它和引擎同时错的概率极低，两者不一致时至少有一方是错的，必须查清。
//!
//! 判定纪律：**不许因为「SQL 没规定相同键的先后」就放过** —— 同一句 SQL 走索引与
//! 走全扫给出不同的行，是实打实的内部不一致，分页会漏行 / 重行。

const std = @import("std");
const sql = @import("sql.zig");
const engine = @import("engine.zig");
const exec = @import("exec.zig");

// ---------------------------------------------------------------- 数据集

const text_pool = [_][]const u8{ "a", "b", "bb", "ccc" };

const Row = struct { id: i64, g: ?i64, s: ?[]const u8 };

const t_n = 24;

/// 故意造出三类麻烦：NULL、大量重复值（`g` 只有 4 个取值）、前缀重叠的文本（`b`/`bb`）。
/// 索引与排序最容易在这三处翻车。
fn buildT() [t_n]Row {
    var arr: [t_n]Row = undefined;
    for (0..t_n) |i| {
        arr[i] = .{
            .id = @intCast(i + 1),
            .g = if ((i * 7) % 5 == 0) null else @as(?i64, @intCast((i * 3) % 4)),
            .s = if ((i * 11) % 7 == 0) null else @as(?[]const u8, text_pool[(i * 5) % text_pool.len]),
        };
    }
    return arr;
}

fn buildTInsert(alloc: std.mem.Allocator) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(alloc);
    try b.appendSlice(alloc, "INSERT INTO t (id, g, s) VALUES ");
    const rows = buildT();
    for (rows, 0..) |r, i| {
        if (i > 0) try b.appendSlice(alloc, ", ");
        const head = try alloc.print("({d}, ", .{r.id});
        defer alloc.free(head);
        try b.appendSlice(alloc, head);
        if (r.g) |v| {
            const t = try alloc.print("{d}, ", .{v});
            defer alloc.free(t);
            try b.appendSlice(alloc, t);
        } else try b.appendSlice(alloc, "NULL, ");
        if (r.s) |v| {
            const t = try alloc.print("'{s}')", .{v});
            defer alloc.free(t);
            try b.appendSlice(alloc, t);
        } else try b.appendSlice(alloc, "NULL)");
    }
    return b.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------- 参考实现
//
// 只实现本测试用到的类型（NULL / INTEGER / TEXT），语义与引擎对外口径一致：
// - 与 NULL 比较恒不匹配（SQL 的 UNKNOWN）；
// - 排序里 NULL 最小；
// - 相同排序键时按主键升序（引擎做不到 ⇒ 内部不一致，测试就该红）。

const Col = enum { id, g, s };

fn colName(c: Col) []const u8 {
    return switch (c) {
        .id => "id",
        .g => "g",
        .s => "s",
    };
}

fn tagOf(v: sql.Value) std.meta.Tag(sql.Value) {
    return std.meta.activeTag(v);
}

fn valueEq(a: sql.Value, b: sql.Value) bool {
    if (tagOf(a) != tagOf(b)) return false;
    return switch (a) {
        .null => true,
        .integer => |x| x == b.integer,
        .real => |x| x == b.real,
        .text => |x| std.mem.eql(u8, x, b.text),
        .blob => |x| std.mem.eql(u8, x, b.blob),
    };
}

fn valueOrd(a: sql.Value, b: sql.Value) std.math.Order {
    if (tagOf(a) == .null) return if (tagOf(b) == .null) .eq else .lt;
    if (tagOf(b) == .null) return .gt;
    return switch (a) {
        .integer => |x| std.math.order(x, b.integer),
        .text => |x| std.mem.order(u8, x, b.text),
        else => unreachable,
    };
}

fn evalCmp(a: sql.Value, op: sql.CmpOp, b: sql.Value) bool {
    if (tagOf(a) == .null or tagOf(b) == .null) return false;
    const ord = valueOrd(a, b);
    return switch (op) {
        .eq => ord == .eq,
        .ne => ord != .eq,
        .lt => ord == .lt,
        .le => ord != .gt,
        .gt => ord == .gt,
        .ge => ord != .lt,
    };
}

fn rowCol(r: Row, c: Col) sql.Value {
    return switch (c) {
        .id => .{ .integer = r.id },
        .g => if (r.g) |v| .{ .integer = v } else .{ .null = {} },
        .s => if (r.s) |v| .{ .text = v } else .{ .null = {} },
    };
}

const OrderKey = struct { col: Col, desc: bool };

fn rowLessKeys(keys: []const OrderKey, a: Row, b: Row) bool {
    for (keys) |k| {
        const ord = valueOrd(rowCol(a, k.col), rowCol(b, k.col));
        if (ord == .eq) continue;
        return if (k.desc) ord == .gt else ord == .lt;
    }
    return a.id < b.id; // 相同键 → 主键升序（确定性分页的前提）
}

// ---------------------------------------------------------------- 随机源

const Rng = struct {
    s: u64,
    fn next(self: *Rng) u64 {
        self.s = self.s *% 6364136223846793005 +% 1442695040888963407;
        return self.s >> 33;
    }
    fn below(self: *Rng, n: usize) usize {
        std.debug.assert(n > 0);
        return @intCast(self.next() % n);
    }
    fn truthy(self: *Rng, one_in: usize) bool {
        return self.below(one_in) == 0;
    }
};

const all_cols = [_]Col{ .id, .g, .s };

const ops = [_]sql.CmpOp{ .eq, .ne, .lt, .le, .gt, .ge };
const opText = [_][]const u8{ "=", "<>", "<", "<=", ">", ">=" };

fn opIndex(op: sql.CmpOp) usize {
    for (ops, 0..) |o, i| if (o == op) return i;
    unreachable;
}

const Buf = std.ArrayList(u8);

fn addInt(alloc: std.mem.Allocator, b: *Buf, v: i64) !void {
    const t = try alloc.print("{d}", .{v});
    defer alloc.free(t);
    try b.appendSlice(alloc, t);
}

// ---------------------------------------------------------------- 单表

const SingleCase = struct {
    proj: []const Col,
    star: bool,
    where: ?struct { col: Col, op: sql.CmpOp, lit: sql.Value } = null,
    keys: []const OrderKey = &.{},
    limit: ?u32 = null,
    offset: ?u32 = null,
};

fn genSingle(alloc: std.mem.Allocator, rng: *Rng, out: *Buf) !SingleCase {
    const star = rng.truthy(6);
    var proj: std.ArrayList(Col) = .empty;
    if (!star) {
        const all = [_]Col{ .id, .g, .s };
        var start = rng.below(3);
        var count = 1 + rng.below(3);
        while (count > 0) : (count -= 1) {
            try proj.append(alloc, all[start % 3]);
            start += 1;
        }
    }

    try out.appendSlice(alloc, "SELECT ");
    if (star) {
        try out.appendSlice(alloc, "*");
    } else {
        for (proj.items, 0..) |c, i| {
            if (i > 0) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, colName(c));
        }
    }
    try out.appendSlice(alloc, " FROM t");

    var case = SingleCase{ .proj = try proj.toOwnedSlice(alloc), .star = star };
    if (rng.truthy(3)) {
        const c = all_cols[rng.below(all_cols.len)];
        const op = ops[rng.below(ops.len)];
        const lit: sql.Value = switch (c) {
            .id => .{ .integer = @intCast(rng.below(t_n + 3)) },
            .g => .{ .integer = @as(i64, @intCast(rng.below(6))) - 1 },
            .s => .{ .text = text_pool[rng.below(text_pool.len)] },
        };
        try out.appendSlice(alloc, " WHERE ");
        try out.appendSlice(alloc, colName(c));
        try out.appendSlice(alloc, " ");
        try out.appendSlice(alloc, opText[opIndex(op)]);
        try out.appendSlice(alloc, " ");
        switch (lit) {
            .integer => |v| try addInt(alloc, out, v),
            .text => |v| {
                try out.appendSlice(alloc, "'");
                try out.appendSlice(alloc, v);
                try out.appendSlice(alloc, "'");
            },
            else => unreachable,
        }
        case.where = .{ .col = c, .op = op, .lit = lit };
    }

    var keys: std.ArrayList(OrderKey) = .empty;
    if (!rng.truthy(3)) {
        const first = all_cols[rng.below(all_cols.len)];
        try keys.append(alloc, .{ .col = first, .desc = rng.truthy(2) });
        if (rng.truthy(4)) {
            const second = all_cols[rng.below(all_cols.len)];
            if (second != first) try keys.append(alloc, .{ .col = second, .desc = rng.truthy(2) });
        }
        // **末位补主键**：没有它，相同排序键的先后在 SQL 里未定义，引擎走索引 /
        // 走全扫 / 走 top-K 各给一个次序都「合法」—— 那样测出来的分歧是噪声。
        // 确定性分页本来也必须这么写。
        var has_pk = false;
        for (keys.items) |k| {
            if (k.col == .id) has_pk = true;
        }
        if (!has_pk) try keys.append(alloc, .{ .col = .id, .desc = false });

        try out.appendSlice(alloc, " ORDER BY ");
        for (keys.items, 0..) |k, i| {
            if (i > 0) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, colName(k.col));
            if (k.desc) try out.appendSlice(alloc, " DESC");
        }
    }
    case.keys = try keys.toOwnedSlice(alloc);

    // `LIMIT`/`OFFSET` **只在有 ORDER BY 时生成**：没有 ORDER BY 的「前 N 行」
    // 本来就依赖未定义的顺序，比出来的差异是噪声。不加 LIMIT 时无 ORDER BY 的
    // 结果集是全集，可以按多重集比对 —— 那才是在测「索引不改变结果集」。
    if (case.keys.len > 0 and rng.truthy(2)) {
        const lim: u32 = @intCast(1 + rng.below(8));
        try out.appendSlice(alloc, " LIMIT ");
        try addInt(alloc, out, lim);
        case.limit = lim;
        if (rng.truthy(2)) {
            const off: u32 = @intCast(rng.below(6));
            try out.appendSlice(alloc, " OFFSET ");
            try addInt(alloc, out, off);
            case.offset = off;
        }
    }
    return case;
}

fn oracleSingle(arena: std.mem.Allocator, rows: []const Row, case: SingleCase) ![][]sql.Value {
    var kept: std.ArrayList(Row) = .empty;
    for (rows) |r| {
        if (case.where) |w| {
            if (!evalCmp(rowCol(r, w.col), w.op, w.lit)) continue;
        }
        try kept.append(arena, r);
    }
    std.mem.sort(Row, kept.items, @as([]const OrderKey, case.keys), rowLessKeys);

    const off: usize = case.offset orelse 0;
    const from = @min(off, kept.items.len);
    const end = if (case.limit) |l| @min(kept.items.len, from + l) else kept.items.len;

    var out: std.ArrayList([]sql.Value) = .empty;
    for (kept.items[from..end]) |r| {
        const one = try arena.alloc(sql.Value, if (case.star) 3 else case.proj.len);
        if (case.star) {
            one[0] = rowCol(r, .id);
            one[1] = rowCol(r, .g);
            one[2] = rowCol(r, .s);
        } else {
            for (case.proj, 0..) |c, i| one[i] = rowCol(r, c);
        }
        try out.append(arena, one);
    }
    return out.items;
}

// ---------------------------------------------------------------- 装库

fn execSilent(eng: *engine.Engine, alloc: std.mem.Allocator, text: []const u8) !void {
    var p = try sql.parse(alloc, text);
    defer p.deinit();
    var res = try eng.execute(p.stmt, alloc);
    switch (res) {
        .rows => |*r| r.deinit(),
        else => {},
    }
}

fn describe(v: sql.Value, buf: []u8) []const u8 {
    return switch (v) {
        .null => "NULL",
        .integer => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch "?",
        .text => |x| std.fmt.bufPrint(buf, "'{s}'", .{x}) catch "?",
        else => "?",
    };
}

fn printRow(vals: []sql.Value) void {
    for (vals, 0..) |v, i| {
        if (i > 0) std.debug.print(",", .{});
        var b: [64]u8 = undefined;
        std.debug.print("{s}", .{describe(v, &b)});
    }
}

/// 行级字典序比较（无 ORDER BY 时按多重集比对要用）。
fn rowLexLess(_: void, a: []sql.Value, b: []sql.Value) bool {
    for (a, b) |x, y| {
        const ord = valueOrd(x, y);
        if (ord != .eq) return ord == .lt;
    }
    return false;
}

/// 失配时把「引擎看到的」与「参考实现算出的」各打几行 —— 一次性看够，不用反复猜。
fn dumpMismatch(it: usize, qtext: []const u8, got: *const exec.Rows, want: []const []sql.Value, case: SingleCase) void {
    std.debug.print("\n[MISMATCH #{d}] {s}\n", .{ it, qtext });
    std.debug.print("  engine cols({d}):", .{got.columns.len});
    for (got.columns) |c| std.debug.print(" {s}", .{c});
    std.debug.print("  rows={d}\n", .{got.rows.len});
    for (got.rows[0..@min(4, got.rows.len)], 0..) |r, i| {
        std.debug.print("  e[{d}] ", .{i});
        printRow(r);
        std.debug.print("\n", .{});
    }
    std.debug.print("  oracle proj:", .{});
    if (case.star) std.debug.print(" *", .{}) else for (case.proj) |c| std.debug.print(" {s}", .{colName(c)});
    std.debug.print("  rows={d}\n", .{want.len});
    for (want[0..@min(4, want.len)], 0..) |r, i| {
        std.debug.print("  o[{d}] ", .{i});
        printRow(r);
        std.debug.print("\n", .{});
    }
}

test "差分随机：单表查询与朴素参考实现逐格一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    const root = "test-fuzz-single";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try engine.Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    const ins = try buildTInsert(alloc);
    defer alloc.free(ins);
    // 索引路径与全扫路径必须给一样的结果 —— 两个二级索引都建上
    for ([_][]const u8{
        "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER, s TEXT)",
        ins,
        "CREATE INDEX idx_t_g ON t (g)",
        "CREATE INDEX idx_t_s ON t (s)",
    }) |st| try execSilent(&eng, alloc, st);

    const rows = buildT();
    var rng = Rng{ .s = 0x9e3779b97f4a7c15 };
    var fails: usize = 0;
    const iters = 500;
    for (0..iters) |it| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // SQL 文本与查询计划一律用 arena：AST 里的列名切片**指向这段文本**，
        // 生命周期必须覆盖整个语句（由 arena 统一释放，不单独 deinit）。
        var q: Buf = .empty;
        const case = try genSingle(arena, &rng, &q);

        var p = sql.parse(alloc, q.items) catch |e| {
            std.debug.print("[单表 #{d}] 解析失败 {s}: {s}\n", .{ it, @errorName(e), q.items });
            fails += 1;
            continue;
        };
        defer p.deinit();
        var res = eng.execute(p.stmt, alloc) catch |e| {
            std.debug.print("[单表 #{d}] 执行失败 {s}: {s}\n", .{ it, @errorName(e), q.items });
            fails += 1;
            continue;
        };
        switch (res) {
            .rows => |*got| {
                defer got.deinit();
                const want = try oracleSingle(arena, &rows, case);
                // 列名也是契约的一部分：投影顺序错了，`SELECT s, id` 会悄悄返回 `(id, s)`。
                const ncols: usize = if (case.star) 3 else case.proj.len;
                var ok = got.rows.len == want.len and got.columns.len == ncols;
                if (ok) {
                    for (got.columns, 0..) |cn, ci| {
                        const want_col: Col = if (case.star) all_cols[ci] else case.proj[ci];
                        if (!std.ascii.eqlIgnoreCase(cn, colName(want_col))) {
                            ok = false;
                            break;
                        }
                    }
                }
                if (ok) {
                    // 无 `ORDER BY` ⇒ 行序未定义，按**多重集**比对（排序后逐格比）。
                    // 有 `ORDER BY` ⇒ 已用主键收尾成全序，逐格严格比。
                    if (case.keys.len == 0) {
                        std.mem.sort([]sql.Value, got.rows, {}, rowLexLess);
                        std.mem.sort([]sql.Value, want, {}, rowLexLess);
                    }
                    outer: for (got.rows, want) |grow, wrow| {
                        if (grow.len != wrow.len) {
                            ok = false;
                            break :outer;
                        }
                        for (grow, wrow) |gv, wv| {
                            if (!valueEq(gv, wv)) {
                                ok = false;
                                break :outer;
                            }
                        }
                    }
                }
                if (!ok) {
                    dumpMismatch(it, q.items, got, want, case);
                    fails += 1;
                }
            },
            else => {
                std.debug.print("[单表 #{d}] 未返回行集 ← {s}\n", .{ it, q.items });
                fails += 1;
            },
        }
    }
    std.debug.print("[差分单表] {d} 条随机查询，失败 {d}\n", .{ iters, fails });
    try std.testing.expectEqual(@as(usize, 0), fails);
}

// ===========================================================================
// JOIN：三条执行路径（哈希连接 / 索引嵌套循环 / 全表扫兜底）必须与嵌套循环
// 参考实现逐格一致，且 INNER / LEFT 的「补 NULL」语义必须对。
// ===========================================================================

const URow = struct { id: i64, k: ?i64, n: ?[]const u8 };
const u_n = 9;

fn buildU() [u_n]URow {
    var arr: [u_n]URow = undefined;
    for (0..u_n) |i| {
        arr[i] = .{
            .id = @intCast(i + 1),
            .k = if (i % 4 == 3) null else @as(?i64, @intCast(i % 3)),
            .n = if (i % 5 == 4) null else @as(?[]const u8, text_pool[(i * 3) % text_pool.len]),
        };
    }
    return arr;
}

/// 右表列名：`Col.g` 映射到 `k`，`Col.s` 映射到 `n`（左表是 id/g/s）。
fn uColName(c: Col) []const u8 {
    return switch (c) {
        .id => "id",
        .g => "k",
        .s => "n",
    };
}

fn uColOf(r: URow, c: Col) sql.Value {
    return switch (c) {
        .id => .{ .integer = r.id },
        .g => if (r.k) |v| .{ .integer = v } else .{ .null = {} },
        .s => if (r.n) |v| .{ .text = v } else .{ .null = {} },
    };
}

fn buildUInsert(alloc: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(alloc);
    try b.appendSlice(alloc, "INSERT INTO u (id, k, n) VALUES ");
    const rows = buildU();
    for (rows, 0..) |r, i| {
        if (i > 0) try b.appendSlice(alloc, ", ");
        const head = try alloc.print("({d}, ", .{r.id});
        defer alloc.free(head);
        try b.appendSlice(alloc, head);
        if (r.k) |v| {
            const t = try alloc.print("{d}, ", .{v});
            defer alloc.free(t);
            try b.appendSlice(alloc, t);
        } else try b.appendSlice(alloc, "NULL, ");
        if (r.n) |v| {
            const t = try alloc.print("'{s}')", .{v});
            defer alloc.free(t);
            try b.appendSlice(alloc, t);
        } else try b.appendSlice(alloc, "NULL)");
    }
    return b.toOwnedSlice(alloc);
}

const JoinCase = struct {
    kind: sql.JoinKind,
    on_l: Col,
    on_r: Col,
    lc: Col,
    rc: Col,
    where: ?struct { op: sql.CmpOp, lit: sql.Value } = null,
    order_col: ?Col = null,
    order_desc: bool = false,
    limit: ?u32 = null,
    offset: ?u32 = null,
};

fn genJoin(alloc: std.mem.Allocator, rng: *Rng, out: *Buf) !JoinCase {
    const kind: sql.JoinKind = if (rng.truthy(2)) .inner else .left;
    // ON 两侧只用**数值列**：文本列与整数列做等值连接时引擎的 `valueCmp` 走的是
    // 「类型序」分支（text > number），那是跨类型比较器的另一条用例，本用例先把同类型路径测干净。
    const num_cols = [_]Col{ .id, .g };
    const on_l = num_cols[rng.below(num_cols.len)];
    const on_r = num_cols[rng.below(num_cols.len)];
    const lc = all_cols[rng.below(all_cols.len)];
    const rc = all_cols[rng.below(all_cols.len)];

    try out.appendSlice(alloc, "SELECT t.");
    try out.appendSlice(alloc, colName(lc));
    try out.appendSlice(alloc, ", u.");
    try out.appendSlice(alloc, uColName(rc));
    try out.appendSlice(alloc, " FROM t ");
    try out.appendSlice(alloc, if (kind == .inner) "INNER JOIN u ON t." else "LEFT JOIN u ON t.");
    try out.appendSlice(alloc, colName(on_l));
    try out.appendSlice(alloc, " = u.");
    try out.appendSlice(alloc, uColName(on_r));

    var case = JoinCase{ .kind = kind, .on_l = on_l, .on_r = on_r, .lc = lc, .rc = rc };

    if (rng.truthy(3)) {
        // WHERE 只作用在左表列上（右表列在 LEFT JOIN 补 NULL 时语义容易吵，
        // 那是另一条用例的事；这里先把「连接 + 排序 + 分页」测干净）
        const op = ops[rng.below(ops.len)];
        const lit: sql.Value = if (on_l == .s)
            .{ .text = text_pool[rng.below(text_pool.len)] }
        else
            .{ .integer = @as(i64, @intCast(rng.below(6))) - 1 };
        try out.appendSlice(alloc, " WHERE t.");
        try out.appendSlice(alloc, colName(on_l));
        try out.appendSlice(alloc, " ");
        try out.appendSlice(alloc, opText[opIndex(op)]);
        try out.appendSlice(alloc, " ");
        switch (lit) {
            .integer => |v| try addInt(alloc, out, v),
            .text => |v| {
                try out.appendSlice(alloc, "'");
                try out.appendSlice(alloc, v);
                try out.appendSlice(alloc, "'");
            },
            else => unreachable,
        }
        case.where = .{ .op = op, .lit = lit };
    }

    if (!rng.truthy(3)) {
        // 排序键：可选一个前缀键 + **固定用 `t.id, u.id` 收尾**。
        // 只用 `t.g` 排序时，同 `g` 的左行 × 同 `g` 的多条右行会大量并列，
        // 并列的先后在 SQL 里未定义 ⇒ 比出来的差异是噪声。两边主键一起收尾才是全序。
        if (rng.truthy(2)) {
            const oc = all_cols[rng.below(all_cols.len)];
            case.order_col = oc;
            case.order_desc = rng.truthy(2);
            try out.appendSlice(alloc, " ORDER BY t.");
            try out.appendSlice(alloc, colName(oc));
            if (case.order_desc) try out.appendSlice(alloc, " DESC");
            try out.appendSlice(alloc, ", t.id, u.id");
        } else {
            case.order_col = null;
            try out.appendSlice(alloc, " ORDER BY t.id, u.id");
        }
    }

    // 只有「写了 ORDER BY」时才允许 LIMIT/OFFSET —— 否则取哪几行本就未定义。
    if (std.mem.indexOf(u8, out.items, " ORDER BY ") != null and rng.truthy(2)) {
        const lim: u32 = @intCast(1 + rng.below(10));
        try out.appendSlice(alloc, " LIMIT ");
        try addInt(alloc, out, lim);
        case.limit = lim;
        if (rng.truthy(2)) {
            const off: u32 = @intCast(rng.below(6));
            try out.appendSlice(alloc, " OFFSET ");
            try addInt(alloc, out, off);
            case.offset = off;
        }
    }
    return case;
}

const Pair = struct { l: Row, r: ?URow };

fn pairLess(case: JoinCase, a: Pair, b: Pair) bool {
    if (case.order_col) |oc| {
        const ord = valueOrd(rowCol(a.l, oc), rowCol(b.l, oc));
        if (ord != .eq) return if (case.order_desc) ord == .gt else ord == .lt;
    }
    if (a.l.id != b.l.id) return a.l.id < b.l.id;
    const ai = if (a.r) |r| r.id else std.math.maxInt(i64);
    const bi = if (b.r) |r| r.id else std.math.maxInt(i64);
    return ai < bi;
}

fn oracleJoin(arena: std.mem.Allocator, ts: []const Row, us: []const URow, case: JoinCase) ![][]sql.Value {
    var pairs: std.ArrayList(Pair) = .empty;
    for (ts) |t| {
        if (case.where) |w| {
            if (!evalCmp(rowCol(t, case.on_l), w.op, w.lit)) continue;
        }
        var matched = false;
        for (us) |u| {
            const a = rowCol(t, case.on_l);
            const b = uColOf(u, case.on_r);
            if (tagOf(a) == .null or tagOf(b) == .null) continue;
            if (valueOrd(a, b) != .eq) continue;
            matched = true;
            try pairs.append(arena, .{ .l = t, .r = u });
        }
        if (!matched and case.kind == .left) try pairs.append(arena, .{ .l = t, .r = null });
    }
    // 插入排序风格的 sort 用 comptime 上下文不安全（case 是运行期值）⇒ 手工包一层
    const Ctx = struct {
        case: JoinCase,
        fn less(ctx: @This(), a: Pair, b: Pair) bool {
            return pairLess(ctx.case, a, b);
        }
    };
    std.mem.sort(Pair, pairs.items, Ctx{ .case = case }, Ctx.less);

    const off: usize = case.offset orelse 0;
    const from = @min(off, pairs.items.len);
    const end = if (case.limit) |l| @min(pairs.items.len, from + l) else pairs.items.len;

    var out: std.ArrayList([]sql.Value) = .empty;
    for (pairs.items[from..end]) |p| {
        const one = try arena.alloc(sql.Value, 2);
        one[0] = rowCol(p.l, case.lc);
        one[1] = if (p.r) |r| uColOf(r, case.rc) else .{ .null = {} };
        try out.append(arena, one);
    }
    return out.items;
}

test "差分随机：JOIN 与嵌套循环参考实现逐格一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    const root = "test-fuzz-join";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try engine.Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    const ins_t = try buildTInsert(alloc);
    defer alloc.free(ins_t);
    const ins_u = try buildUInsert(alloc);
    defer alloc.free(ins_u);
    for ([_][]const u8{
        "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER, s TEXT)",
        "CREATE TABLE u (id INTEGER PRIMARY KEY, k INTEGER, n TEXT)",
        ins_t,
        ins_u,
        "CREATE INDEX idx_t_g ON t (g)",
        "CREATE INDEX idx_u_k ON u (k)",
    }) |st| try execSilent(&eng, alloc, st);

    const ts = buildT();
    const us = buildU();
    var rng = Rng{ .s = 0x2545f4914f6cdd1d };
    var fails: usize = 0;
    const iters = 260;
    for (0..iters) |it| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var q: Buf = .empty;
        const case = try genJoin(arena, &rng, &q);

        var p = sql.parse(alloc, q.items) catch |e| {
            std.debug.print("[JOIN #{d}] 解析失败 {s}: {s}\n", .{ it, @errorName(e), q.items });
            fails += 1;
            continue;
        };
        defer p.deinit();
        var res = eng.execute(p.stmt, alloc) catch |e| {
            std.debug.print("[JOIN #{d}] 执行失败 {s}: {s}\n", .{ it, @errorName(e), q.items });
            fails += 1;
            continue;
        };
        switch (res) {
            .rows => |*got| {
                defer got.deinit();
                const want = try oracleJoin(arena, &ts, &us, case);
                const has_order = std.mem.indexOf(u8, q.items, " ORDER BY ") != null;
                if (!has_order) {
                    std.mem.sort([]sql.Value, got.rows, {}, rowLexLess);
                    std.mem.sort([]sql.Value, want, {}, rowLexLess);
                }
                var ok = got.rows.len == want.len and got.columns.len == 2;
                if (ok) {
                    var exp: [2][32]u8 = undefined;
                    const e0 = std.fmt.bufPrint(&exp[0], "t.{s}", .{colName(case.lc)}) catch "?";
                    const e1 = std.fmt.bufPrint(&exp[1], "u.{s}", .{uColName(case.rc)}) catch "?";
                    if (!std.ascii.eqlIgnoreCase(got.columns[0], e0) or
                        !std.ascii.eqlIgnoreCase(got.columns[1], e1)) ok = false;
                }
                if (ok) {
                    outer: for (got.rows, want) |grow, wrow| {
                        if (grow.len != 2 or wrow.len != 2) {
                            ok = false;
                            break :outer;
                        }
                        for (grow, wrow) |gv, wv| {
                            if (!valueEq(gv, wv)) {
                                ok = false;
                                break :outer;
                            }
                        }
                    }
                }
                if (!ok) {
                    std.debug.print("\n[MISMATCH-JOIN #{d}] {s}\n", .{ it, q.items });
                    std.debug.print("  engine cols({d}):", .{got.columns.len});
                    for (got.columns) |c| std.debug.print(" {s}", .{c});
                    std.debug.print("  rows={d}\n", .{got.rows.len});
                    for (got.rows[0..@min(4, got.rows.len)], 0..) |r, i| {
                        std.debug.print("  e[{d}] ", .{i});
                        printRow(r);
                        std.debug.print("\n", .{});
                    }
                    std.debug.print("  oracle rows={d}\n", .{want.len});
                    for (want[0..@min(4, want.len)], 0..) |r, i| {
                        std.debug.print("  o[{d}] ", .{i});
                        printRow(r);
                        std.debug.print("\n", .{});
                    }
                    fails += 1;
                }
            },
            else => {
                std.debug.print("[JOIN #{d}] 未返回行集 ← {s}\n", .{ it, q.items });
                fails += 1;
            },
        }
    }
    std.debug.print("[差分 JOIN] {d} 条随机查询，失败 {d}\n", .{ iters, fails });
    try std.testing.expectEqual(@as(usize, 0), fails);
}

// ===========================================================================
// DML 差分：随机 UPDATE / DELETE 之后，**全表**与**走索引的查询**都必须与
// 内存参考表一致。
//
// 为什么单列这一块：更新/删除要同时维护「行」与「索引项」，顺序错了（先删行后删
// 索引项之外的情况）不会报错，只会让走索引的查询**静默漏行或多行**。这类缺陷
// 只有「改完再全量对账」才抓得住，与查询侧的差分测试完全不是一回事。
// ===========================================================================

/// `WHERE <col> <op> <lit>` 的一个具体实例（命名类型：匿名结构体不能跨函数签名）。
const Cond = struct { col: Col, op: sql.CmpOp, lit: sql.Value };

fn oracleApplyUpdate(rows: []Row, set_col: Col, val: sql.Value, w: ?Cond) void {
    for (rows) |*r| {
        if (w) |cond| {
            if (!evalCmp(rowCol(r.*, cond.col), cond.op, cond.lit)) continue;
        }
        switch (set_col) {
            .id => r.id = val.integer,
            .g => r.g = if (tagOf(val) == .null) null else val.integer,
            .s => r.s = if (tagOf(val) == .null) null else val.text,
        }
    }
}

fn oracleApplyDelete(rows: *std.ArrayList(Row), w: ?Cond) void {
    var i: usize = 0;
    while (i < rows.items.len) {
        const keep = if (w) |cond| !evalCmp(rowCol(rows.items[i], cond.col), cond.op, cond.lit) else false;
        if (keep) {
            i += 1;
        } else {
            _ = rows.orderedRemove(i);
        }
    }
}

test "差分随机：DML 更新/删除后全表与索引一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    const root = "test-fuzz-dml";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    var eng = try engine.Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();

    const ins = try buildTInsert(alloc);
    defer alloc.free(ins);
    for ([_][]const u8{
        "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER, s TEXT)",
        ins,
        "CREATE INDEX idx_t_g ON t (g)",
        "CREATE INDEX idx_t_s ON t (s)",
    }) |st| try execSilent(&eng, alloc, st);

    // 内存参考表：与引擎同步地应用同一批 DML
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(alloc);
    const init_rows = buildT();
    for (init_rows) |r| try rows.append(alloc, r);

    var rng = Rng{ .s = 0xcafebabe12345678 };
    var fails: usize = 0;

    for (0..30) |round| {
        // 每轮 6 条 DML
        for (0..6) |_| {
            const cond_col = all_cols[rng.below(all_cols.len)];
            const cond_op = ops[rng.below(ops.len)];
            const cond_lit: sql.Value = if (cond_col == .s)
                .{ .text = text_pool[rng.below(text_pool.len)] }
            else
                .{ .integer = @as(i64, @intCast(rng.below(t_n))) - 1 };
            const cond = Cond{ .col = cond_col, .op = cond_op, .lit = cond_lit };

            var q: Buf = .empty;
            defer q.deinit(alloc);

            if (rng.truthy(2)) {
                // UPDATE
                const set_col = all_cols[rng.below(all_cols.len)];
                const set_val: sql.Value = if (set_col == .s)
                    .{ .text = text_pool[rng.below(text_pool.len)] }
                else
                    .{ .integer = @as(i64, @intCast(rng.below(t_n))) };
                try q.appendSlice(alloc, "UPDATE t SET ");
                try q.appendSlice(alloc, colName(set_col));
                try q.appendSlice(alloc, " = ");
                switch (set_val) {
                    .integer => |v| try addInt(alloc, &q, v),
                    .text => |v| {
                        try q.appendSlice(alloc, "'");
                        try q.appendSlice(alloc, v);
                        try q.appendSlice(alloc, "'");
                    },
                    else => unreachable,
                }
                try q.appendSlice(alloc, " WHERE ");
                try q.appendSlice(alloc, colName(cond_col));
                try q.appendSlice(alloc, " ");
                try q.appendSlice(alloc, opText[opIndex(cond_op)]);
                try q.appendSlice(alloc, " ");
                switch (cond_lit) {
                    .integer => |v| try addInt(alloc, &q, v),
                    .text => |v| {
                        try q.appendSlice(alloc, "'");
                        try q.appendSlice(alloc, v);
                        try q.appendSlice(alloc, "'");
                    },
                    else => unreachable,
                }
                // 主键不能被改乱：改 id 会让参考表与引擎的主键集合分叉，
                // 那不是「索引维护」问题，另行用例。这里只改非主键列。
                if (set_col == .id) continue;
                try execSilent(&eng, alloc, q.items);
                oracleApplyUpdate(rows.items, set_col, set_val, cond);
            } else {
                // DELETE
                try q.appendSlice(alloc, "DELETE FROM t WHERE ");
                try q.appendSlice(alloc, colName(cond_col));
                try q.appendSlice(alloc, " ");
                try q.appendSlice(alloc, opText[opIndex(cond_op)]);
                try q.appendSlice(alloc, " ");
                switch (cond_lit) {
                    .integer => |v| try addInt(alloc, &q, v),
                    .text => |v| {
                        try q.appendSlice(alloc, "'");
                        try q.appendSlice(alloc, v);
                        try q.appendSlice(alloc, "'");
                    },
                    else => unreachable,
                }
                try execSilent(&eng, alloc, q.items);
                oracleApplyDelete(&rows, cond);
            }
        }

        // 对账 ①：全表（走全扫 + 主键排序）
        {
            const got_rows = try fetchAll(&eng, alloc, "SELECT id, g, s FROM t ORDER BY id");
            defer freeRows(&got_rows, alloc);
            if (!rowsEqual(&got_rows, rows.items)) {
                std.debug.print("[DML 第 {d} 轮] 全表对账不符：引擎 {d} 行 / 参考 {d} 行\n", .{
                    round, got_rows.len, rows.items.len,
                });
                dumpFirst(&got_rows, rows.items);
                fails += 1;
            }
        }
        // 对账 ②：每个二级索引列做一次等值查询（走索引路径），按主键排序比集合
        for ([_]Col{ .g, .s }) |c| {
            const vals: [5]sql.Value = if (c == .g)
                [_]sql.Value{ .{ .integer = 0 }, .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 }, .{ .integer = 9 } }
            else
                [_]sql.Value{ .{ .text = "a" }, .{ .text = "b" }, .{ .text = "bb" }, .{ .text = "ccc" }, .{ .text = "zz" } };
            for (vals) |v| {
                var q: Buf = .empty;
                defer q.deinit(alloc);
                try q.appendSlice(alloc, "SELECT id FROM t WHERE ");
                try q.appendSlice(alloc, colName(c));
                try q.appendSlice(alloc, " = ");
                switch (v) {
                    .integer => |x| try addInt(alloc, &q, x),
                    .text => |x| {
                        try q.appendSlice(alloc, "'");
                        try q.appendSlice(alloc, x);
                        try q.appendSlice(alloc, "'");
                    },
                    else => unreachable,
                }
                try q.appendSlice(alloc, " ORDER BY id");
                const got_ids = try fetchAll(&eng, alloc, q.items);
                defer freeRows(&got_ids, alloc);

                var want_ids: std.ArrayList(sql.Value) = .empty;
                defer want_ids.deinit(alloc);
                for (rows.items) |r| {
                    const cell = rowCol(r, c);
                    if (tagOf(cell) == .null) continue;
                    if (valueOrd(cell, v) != .eq) continue;
                    try want_ids.append(alloc, .{ .integer = r.id });
                }
                var bad = got_ids.len != want_ids.items.len;
                if (!bad) {
                    for (got_ids, want_ids.items) |g, w| {
                        if (!valueEq(g[0], w)) {
                            bad = true;
                            break;
                        }
                    }
                }
                if (bad) {
                    std.debug.print("[DML 第 {d} 轮] 索引对账不符（列 {s}）：{s} → 引擎 {d} 行 / 参考 {d} 行\n", .{
                        round, colName(c), q.items, got_ids.len, want_ids.items.len,
                    });
                    fails += 1;
                }
            }
        }
    }
    std.debug.print("[差分 DML] 30 轮 × 6 条 DML，失败 {d}\n", .{fails});
    try std.testing.expectEqual(@as(usize, 0), fails);
}

/// 取回行集并**深拷 text/blob**。
///
/// 必须深拷：`Rows.deinit` 会把 `buf` 整块释放，而 text/blob 是指向 `buf` 的切片。
/// 只拷 `sql.Value`（浅拷贝）的话，函数一返回就拿着一堆悬垂切片 ——
/// 表现是「值变成 0x55 填充」或直接段错误。写这个差分用例时脚手架自己就踩了这一步，
/// 差点误判成「引擎把文本存坏了」（靠把字节打成十六进制才看清）。
fn fetchAll(eng: *engine.Engine, alloc: std.mem.Allocator, text: []const u8) ![][]sql.Value {
    var p = try sql.parse(alloc, text);
    defer p.deinit();
    var res = try eng.execute(p.stmt, alloc);
    switch (res) {
        .rows => |*r| {
            defer r.deinit();
            const out = try alloc.alloc([]sql.Value, r.rows.len);
            var made: usize = 0;
            errdefer {
                for (out[0..made]) |row| {
                    for (row) |v| switch (v) {
                        .text => |x| alloc.free(x),
                        .blob => |x| alloc.free(x),
                        else => {},
                    };
                    alloc.free(row);
                }
                alloc.free(out);
            }
            for (r.rows, 0..) |row, i| {
                const dst = try alloc.alloc(sql.Value, row.len);
                out[i] = dst;
                made += 1;
                for (row, 0..) |v, k| {
                    dst[k] = switch (v) {
                        .text => |x| .{ .text = try alloc.dupe(u8, x) },
                        .blob => |x| .{ .blob = try alloc.dupe(u8, x) },
                        else => v,
                    };
                }
            }
            return out;
        },
        else => return error.UnsupportedStatement,
    }
}

fn freeRows(rows: *const [][]sql.Value, alloc: std.mem.Allocator) void {
    for (rows.*) |row| {
        for (row) |v| switch (v) {
            .text => |x| alloc.free(x),
            .blob => |x| alloc.free(x),
            else => {},
        };
        alloc.free(row);
    }
    alloc.free(rows.*);
}

fn rowsEqual(got: *const [][]sql.Value, want: []const Row) bool {
    if (got.*.len != want.len) return false;
    for (got.*, want) |grow, w| {
        if (grow.len != 3) return false;
        if (!valueEq(grow[0], .{ .integer = w.id })) return false;
        if (!valueEq(grow[1], rowCol(w, .g))) return false;
        if (!valueEq(grow[2], rowCol(w, .s))) return false;
    }
    return true;
}

fn dumpFirst(got: *const [][]sql.Value, want: []const Row) void {
    for (got.*[0..@min(5, got.*.len)], 0..) |r, i| {
        std.debug.print("  e[{d}] ", .{i});
        printRow(r);
        std.debug.print("\n", .{});
    }
    for (want[0..@min(5, want.len)], 0..) |r, i| {
        var b1: [64]u8 = undefined;
        var b2: [64]u8 = undefined;
        std.debug.print("  o[{d}] {d},{s},{s}\n", .{
            i, r.id, describe(rowCol(r, .g), &b1), describe(rowCol(r, .s), &b2),
        });
    }
}
