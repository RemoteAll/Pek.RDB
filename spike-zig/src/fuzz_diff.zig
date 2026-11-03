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

            // ---- 主键迁移（`UPDATE ... SET id = ...`）----
            // 索引键 = 值 ++ 主键，所以改主键要「删旧行 + 删旧索引项 + 插新行 + 插新索引项」
            // 四步全对齐。只改非主键列永远碰不到这条路径，而它恰恰最容易漏掉其中一步。
            // 新主键取「当前最大 + 1..5」（预留区，保证不与现有主键撞车：撞车会变成两行同键，
            // 那是「重复键怎么写」的另一条用例，不是索引维护）。
            if (rows.items.len > 0 and rng.truthy(6)) {
                var max_id: i64 = 0;
                for (rows.items) |r| max_id = @max(max_id, r.id);
                const old_id = rows.items[rng.below(rows.items.len)].id;
                const new_id = max_id + 1 + @as(i64, @intCast(rng.below(5)));
                try q.appendSlice(alloc, "UPDATE t SET id = ");
                try addInt(alloc, &q, new_id);
                try q.appendSlice(alloc, " WHERE id = ");
                try addInt(alloc, &q, old_id);
                try execSilent(&eng, alloc, q.items);
                for (rows.items) |*r| {
                    if (r.id == old_id) r.id = new_id;
                }
                continue;
            }

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

        // 参考表按 id 排序（主键迁移会打乱原插入顺序），对账全部基于这份
        var sorted: std.ArrayList(Row) = .empty;
        defer sorted.deinit(alloc);
        try sorted.appendSlice(alloc, rows.items);
        std.mem.sort(Row, sorted.items, {}, idLess);

        // 对账 ①：全表（走全扫 + 主键排序）
        {
            const got_rows = try fetchAll(&eng, alloc, "SELECT id, g, s FROM t ORDER BY id");
            defer freeRows(got_rows, alloc);
            if (!rowsEqual(&got_rows, sorted.items)) {
                std.debug.print("[DML 第 {d} 轮] 全表对账不符：引擎 {d} 行 / 参考 {d} 行\n", .{
                    round, got_rows.len, sorted.items.len,
                });
                dumpFirst(&got_rows, sorted.items);
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
                defer freeRows(got_ids, alloc);

                var want_ids: std.ArrayList(sql.Value) = .empty;
                defer want_ids.deinit(alloc);
                for (sorted.items) |r| {
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

fn freeRows(rows: []const []sql.Value, alloc: std.mem.Allocator) void {
    for (rows) |row| {
        for (row) |v| switch (v) {
            .text => |x| alloc.free(x),
            .blob => |x| alloc.free(x),
            else => {},
        };
        alloc.free(row);
    }
    alloc.free(rows);
}

fn idLess(_: void, a: Row, b: Row) bool {
    return a.id < b.id;
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

// ===========================================================================
// 聚合 / GROUP BY / HAVING 差分
//
// 为什么单独做：`selectGrouped` 有 550 行、四条互相纠缠的语义（分组键编码、隐藏排序列、
// HAVING 的聚合可能不在选择列表、SUM/AVG 的整数/浮点分野）。这类逻辑一旦错，
// 报出来的数字**看着完全正常**（少算一行、把 NULL 当 0、AVG 用错分母），
// 没有任何断言会红 —— 只能靠「与朴素参考实现逐格比」。
//
// 参考实现刻意用 O(组数 × 组内行数) 的笨写法：每组现扫一遍算聚合，好读、不易同错。
// ===========================================================================

const AggItem = struct { func: sql.AggFunc, col: ?Col };

const AggOut = union(enum) { grp: Col, agg: AggItem };

const AggCase = struct {
    group_by: []const Col,
    items: []const AggOut,
    where: ?Cond = null,
    having: ?struct { item: AggItem, op: sql.CmpOp, lit: sql.Value } = null,
};

fn aggFuncName(f: sql.AggFunc) []const u8 {
    return switch (f) {
        .count => "count",
        .sum => "sum",
        .avg => "avg",
        .min => "min",
        .max => "max",
    };
}

fn aggLabelAlloc(alloc: std.mem.Allocator, item: AggItem) ![]const u8 {
    return if (item.col) |c|
        try alloc.print("{s}({s})", .{ aggFuncName(item.func), colName(c) })
    else
        try alloc.print("{s}(*)", .{aggFuncName(item.func)});
}

fn genAggItem(rng: *Rng) AggItem {
    const funcs = [_]sql.AggFunc{ .count, .count, .sum, .avg, .min, .max };
    const f = funcs[rng.below(funcs.len)];
    // `count(*)`
    if (f == .count and rng.truthy(3)) return .{ .func = .count, .col = null };
    // SUM/AVG 只对数值列有意义（对 text 引擎直接报 TypeMismatch，那是另一条用例）
    const cols: []const Col = if (f == .sum or f == .avg) &[_]Col{ .id, .g } else &all_cols;
    return .{ .func = f, .col = cols[rng.below(cols.len)] };
}

fn genAgg(alloc: std.mem.Allocator, rng: *Rng, out: *Buf) !AggCase {
    var group_by: std.ArrayList(Col) = .empty;
    const mode = rng.below(4);
    if (mode != 0) { // 25% 全局聚合
        try group_by.append(alloc, .g);
        if (mode >= 2) try group_by.append(alloc, .s); // 50% 两列分组
    }

    var items: std.ArrayList(AggOut) = .empty;
    for (group_by.items) |c| try items.append(alloc, .{ .grp = c });
    const naggs = 1 + rng.below(2);
    for (0..naggs) |_| try items.append(alloc, .{ .agg = genAggItem(rng) });

    try out.appendSlice(alloc, "SELECT ");
    for (items.items, 0..) |it, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        switch (it) {
            .grp => |c| try out.appendSlice(alloc, colName(c)),
            .agg => |a| {
                const lab = try aggLabelAlloc(alloc, a);
                defer alloc.free(lab);
                try out.appendSlice(alloc, lab);
            },
        }
    }
    try out.appendSlice(alloc, " FROM t");

    var case = AggCase{ .group_by = &.{}, .items = &.{} };
    if (rng.truthy(3)) {
        const num_only = [_]Col{ .id, .g };
        const c = num_only[rng.below(num_only.len)];
        const op = ops[rng.below(ops.len)];
        const lit: sql.Value = .{ .integer = @as(i64, @intCast(rng.below(6))) - 1 };
        try out.appendSlice(alloc, " WHERE ");
        try out.appendSlice(alloc, colName(c));
        try out.appendSlice(alloc, " ");
        try out.appendSlice(alloc, opText[opIndex(op)]);
        try out.appendSlice(alloc, " ");
        try addInt(alloc, out, lit.integer);
        case.where = .{ .col = c, .op = op, .lit = lit };
    }
    if (group_by.items.len > 0) {
        try out.appendSlice(alloc, " GROUP BY ");
        for (group_by.items, 0..) |c, i| {
            if (i > 0) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, colName(c));
        }
    }
    if (rng.truthy(3)) {
        // HAVING 的聚合**故意不与投影里的重复**，覆盖「补隐藏槽」那条路径
        const having_funcs = [_]sql.AggFunc{ .count, .sum, .min };
        const hf = having_funcs[rng.below(having_funcs.len)];
        // `sum(*)` / `min(*)` 不是合法 SQL：只有 count 接受 `*`
        const ha = AggItem{ .func = hf, .col = if (hf != .count or rng.truthy(2)) .g else null };
        const hop = ops[rng.below(ops.len)];
        const hlit: sql.Value = .{ .integer = @as(i64, @intCast(rng.below(4))) };
        try out.appendSlice(alloc, " HAVING ");
        const lab = try aggLabelAlloc(alloc, ha);
        defer alloc.free(lab);
        try out.appendSlice(alloc, lab);
        try out.appendSlice(alloc, " ");
        try out.appendSlice(alloc, opText[opIndex(hop)]);
        try out.appendSlice(alloc, " ");
        try addInt(alloc, out, hlit.integer);
        case.having = .{ .item = ha, .op = hop, .lit = hlit };
    }
    case.group_by = try group_by.toOwnedSlice(alloc);
    case.items = try items.toOwnedSlice(alloc);
    return case;
}

/// 朴素聚合：在一组行上现扫一遍。`null` 列跳过；空集时 SUM/AVG/MIN/MAX 都是 NULL。
fn computeAgg(rows: []const Row, item: AggItem) sql.Value {
    switch (item.func) {
        .count => {
            if (item.col) |c| {
                var n: i64 = 0;
                for (rows) |r| {
                    if (tagOf(rowCol(r, c)) != .null) n += 1;
                }
                return .{ .integer = n };
            }
            return .{ .integer = @intCast(rows.len) };
        },
        .sum, .avg => {
            var sum: i128 = 0;
            var n: i64 = 0;
            for (rows) |r| {
                const v = rowCol(r, item.col.?);
                switch (v) {
                    .null => {},
                    .integer => |x| {
                        sum += x;
                        n += 1;
                    },
                    else => unreachable,
                }
            }
            if (n == 0) return .{ .null = {} };
            if (item.func == .sum) return .{ .integer = std.math.cast(i64, sum).? };
            return .{ .real = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n)) };
        },
        .min, .max => {
            var best: sql.Value = .{ .null = {} };
            for (rows) |r| {
                const v = rowCol(r, item.col.?);
                if (tagOf(v) == .null) continue;
                if (tagOf(best) == .null) {
                    best = v;
                    continue;
                }
                const ord = valueOrd(v, best);
                if (item.func == .min and ord == .lt) best = v;
                if (item.func == .max and ord == .gt) best = v;
            }
            return best;
        },
    }
}

fn oracleAgg(arena: std.mem.Allocator, rows: []const Row, case: AggCase) ![][]sql.Value {
    const filt = try arena.alloc(Row, rows.len);
    var nf: usize = 0;
    for (rows) |r| {
        if (case.where) |w| {
            if (!evalCmp(rowCol(r, w.col), w.op, w.lit)) continue;
        }
        filt[nf] = r;
        nf += 1;
    }

    const Grp = struct { key: []sql.Value, rows: std.ArrayList(Row) };
    var groups: std.ArrayList(Grp) = .empty;
    if (case.group_by.len == 0) {
        // 全局聚合：空输入也产出一组（SQL 语义）
        try groups.append(arena, .{ .key = &.{}, .rows = .empty });
        for (filt[0..nf]) |r| try groups.items[0].rows.append(arena, r);
    } else {
        for (filt[0..nf]) |r| {
            const key = try arena.alloc(sql.Value, case.group_by.len);
            for (case.group_by, 0..) |c, i| key[i] = rowCol(r, c);
            var hit: ?usize = null;
            for (groups.items, 0..) |g, gi| {
                var same = true;
                for (g.key, key) |a, b| {
                    if (valueOrd(a, b) != .eq) {
                        same = false;
                        break;
                    }
                }
                if (same) {
                    hit = gi;
                    break;
                }
            }
            if (hit) |gi| {
                try groups.items[gi].rows.append(arena, r);
            } else {
                var grp = Grp{ .key = key, .rows = .empty };
                try grp.rows.append(arena, r);
                try groups.append(arena, grp);
            }
        }
    }

    var out: std.ArrayList([]sql.Value) = .empty;
    for (groups.items) |g| {
        // HAVING：聚合值 NULL 视为 unknown ⇒ 整组被滤掉
        if (case.having) |hv| {
            const hv_val = computeAgg(g.rows.items, hv.item);
            if (tagOf(hv_val) == .null) continue;
            if (!evalCmp(hv_val, hv.op, hv.lit)) continue;
        }
        const one = try arena.alloc(sql.Value, case.items.len);
        for (case.items, 0..) |it, i| {
            one[i] = switch (it) {
                .grp => |c| blk: {
                    for (case.group_by, 0..) |gc, k| {
                        if (gc == c) break :blk g.key[k];
                    }
                    unreachable;
                },
                .agg => |a| computeAgg(g.rows.items, a),
            };
        }
        try out.append(arena, one);
    }
    return out.items;
}

test "差分随机：聚合 / GROUP BY / HAVING 与朴素参考实现一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    const root = "test-fuzz-agg";
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
    }) |st| try execSilent(&eng, alloc, st);

    const rows = buildT();
    var rng = Rng{ .s = 0x5deece66d1234567 };
    var fails: usize = 0;
    const iters = 250;
    for (0..iters) |it| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var q: Buf = .empty;
        const case = try genAgg(arena, &rng, &q);

        var p = sql.parse(alloc, q.items) catch |e| {
            std.debug.print("[聚合 #{d}] 解析失败 {s}: {s}\n", .{ it, @errorName(e), q.items });
            fails += 1;
            continue;
        };
        defer p.deinit();
        var res = eng.execute(p.stmt, alloc) catch |e| {
            std.debug.print("[聚合 #{d}] 执行失败 {s}: {s}\n", .{ it, @errorName(e), q.items });
            fails += 1;
            continue;
        };
        switch (res) {
            .rows => |*got| {
                defer got.deinit();
                const want = try oracleAgg(arena, &rows, case);
                // 无 ORDER BY ⇒ 组顺序未定义，按多重集比
                std.mem.sort([]sql.Value, got.rows, {}, rowLexLess);
                std.mem.sort([]sql.Value, want, {}, rowLexLess);

                var ok = got.rows.len == want.len and got.columns.len == case.items.len;
                if (ok) {
                    for (got.columns, 0..) |cn, ci| {
                        const exp = switch (case.items[ci]) {
                            .grp => |c| try alloc.dupe(u8, colName(c)),
                            .agg => |a| try aggLabelAlloc(alloc, a),
                        };
                        defer alloc.free(exp);
                        if (!std.ascii.eqlIgnoreCase(cn, exp)) {
                            ok = false;
                            break;
                        }
                    }
                }
                if (ok) {
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
                    std.debug.print("\n[MISMATCH-AGG #{d}] {s}\n", .{ it, q.items });
                    std.debug.print("  engine cols({d}):", .{got.columns.len});
                    for (got.columns) |c| std.debug.print(" {s}", .{c});
                    std.debug.print("  rows={d}\n", .{got.rows.len});
                    for (got.rows[0..@min(5, got.rows.len)], 0..) |r, i| {
                        std.debug.print("  e[{d}] ", .{i});
                        printRow(r);
                        std.debug.print("\n", .{});
                    }
                    std.debug.print("  oracle rows={d}\n", .{want.len});
                    for (want[0..@min(5, want.len)], 0..) |r, i| {
                        std.debug.print("  o[{d}] ", .{i});
                        printRow(r);
                        std.debug.print("\n", .{});
                    }
                    fails += 1;
                }
            },
            else => {
                std.debug.print("[聚合 #{d}] 未返回行集 ← {s}\n", .{ it, q.items });
                fails += 1;
            },
        }
    }
    std.debug.print("[差分聚合] {d} 条随机查询，失败 {d}\n", .{ iters, fails });
    try std.testing.expectEqual(@as(usize, 0), fails);
}

// ===========================================================================
// WAL 截断（恢复健壮性）
//
// 真实世界的中断点**一定**落在记录中间：断电、`kill -9`、磁盘写满、容器被驱逐。
// 恢复时只有两种结果可以接受：
//   ① 显式报错（可诊断，带得出来是哪一步/哪一段）；
//   ② 恢复到「**完整记录的连续前缀**」，且每行数据与写入值逐字节一致。
// **不可接受**：静默返回半条记录（长度对、内容是垃圾）、跳过损坏段继续当没事、
// 或者恢复出来的行集不是前缀（出现「后面的行在、前面的行没了」）。
//
// 每次重开都开两次：恢复必须是幂等的（第二次读到的与第一次完全一样），
// 否则说明恢复过程又写坏了什么。
//
// **造「崩溃态」的正确做法**（第一版写错过，记在这里）：
// `Engine.deinit` 会把 memtable 刷成段并把 WAL 截回 0，所以「写完 → 正常关闭 → 截断 WAL」
// 截的是一个**空文件**，用例看着绿、实际什么都没测（实测 `total = 0`）。
// 正确构造：① 建一个只有 schema、没有数据的库并正常关闭（WAL 归零）；
// ② 另开一次、插入若干行，**在关闭之前**把 WAL 字节读出来；
// ③ 每个截断点：重建空库 → 把捕获的 WAL 前 `cut` 字节写回去 → 重开 ⇒ 这才是断电现场。
// 并且显式断言「捕获到的 WAL 非空」，防止将来又退化成空跑。
// ===========================================================================

/// 建一个只有表结构、没有数据的库并正常关闭（此时 WAL 被截回 0）。
fn buildSchemaOnly(io: std.Io, dir: std.Io.Dir, root: []const u8, alloc: std.mem.Allocator) !void {
    var eng = try engine.Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();
    try execSilent(&eng, alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, g INTEGER, s TEXT)");
}

fn walPath(alloc: std.mem.Allocator, root: []const u8) ![]u8 {
    return alloc.print("{s}/t/wal/000001.wal", .{root});
}

/// 在「关闭之前」把 WAL 的字节整段读出来 —— 这就是崩溃时会留在磁盘上的东西。
///
/// **必须 `wal_sync_every = 1`**：`wal.append` 只把记录堆在内存 buffer 里，
/// 真正 `writePositionalAll` 发生在 `sync()`（默认 `wal_sync_every = 0` ⇒ 永不同步），
/// 所以用 0 抓到的永远是 0 字节（第一版就是这么空跑到绿的）。
fn captureWalBytes(io: std.Io, dir: std.Io.Dir, root: []const u8, alloc: std.mem.Allocator, rows: []const Row) ![]u8 {
    var eng = try engine.Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 1 } });
    defer eng.deinit();
    for (rows) |r| {
        var b: Buf = .empty;
        defer b.deinit(alloc);
        try b.appendSlice(alloc, "INSERT INTO t (id, g, s) VALUES (");
        try addInt(alloc, &b, r.id);
        try b.appendSlice(alloc, ", ");
        if (r.g) |g| try addInt(alloc, &b, g) else try b.appendSlice(alloc, "NULL");
        try b.appendSlice(alloc, ", ");
        if (r.s) |v| {
            try b.appendSlice(alloc, "'");
            try b.appendSlice(alloc, v);
            try b.appendSlice(alloc, "'");
        } else try b.appendSlice(alloc, "NULL");
        try b.appendSlice(alloc, ")");
        try execSilent(&eng, alloc, b.items);
    }
    // 此刻引擎还开着、memtable 还没刷 —— WAL 里就是那 N 条记录
    const path = try walPath(alloc, root);
    defer alloc.free(path);
    const f = try dir.openFile(io, path, .{});
    defer f.close(io);
    const size: usize = @intCast((try f.stat(io)).size);
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

fn reopenAndRead(io: std.Io, dir: std.Io.Dir, root: []const u8, alloc: std.mem.Allocator) ![][]sql.Value {
    var eng = try engine.Engine.open(io, dir, root, alloc, .{ .table = .{ .wal_sync_every = 0 } });
    defer eng.deinit();
    return fetchAll(&eng, alloc, "SELECT id, g, s FROM t ORDER BY id");
}

test "WAL 截断：只能是完整前缀或显式报错，不得静默返回坏数据" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    const root = "test-wal-trunc";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    const all = buildT();
    const rows = all[0..13];

    // ① 空库（schema 已落盘、WAL = 0）→ ② 再开一次灌数据并在关闭前抓 WAL 字节
    try buildSchemaOnly(io, dir, root, alloc);
    const wal_bytes = try captureWalBytes(io, dir, root, alloc, rows);
    defer alloc.free(wal_bytes);
    const total: u64 = wal_bytes.len;
    // 防退化：抓不到内容说明「崩溃态」没造出来，这时用例是空跑，必须直接报错
    try std.testing.expect(total > 0);

    var fails: usize = 0;
    var explicit_errors: usize = 0;
    var recovered: usize = 0;
    var max_rows: usize = 0;
    var partial_rows: usize = 0;

    const cuts = [_]u64{ 0, 1, 2, 4, 7, 8, 16, total / 4, total / 2, total * 3 / 4, total * 7 / 8, total -| 32, total -| 16, total -| 8, total -| 4, total -| 1, total };
    for (cuts) |cut| {
        if (cut > total) continue;
        dir.deleteTree(io, root) catch {};
        try buildSchemaOnly(io, dir, root, alloc);

        // 把捕获的 WAL 前 `cut` 字节写回去 —— 等价于「写到一半断电」
        {
            const path = try walPath(alloc, root);
            defer alloc.free(path);
            const f = try dir.openFile(io, path, .{ .mode = .read_write });
            defer f.close(io);
            try f.writePositionalAll(io, wal_bytes[0..@intCast(cut)], 0);
            try f.setLength(io, cut);
        }

        // ③ 重开：允许显式报错
        const got = reopenAndRead(io, dir, root, alloc) catch |e| {
            std.debug.print("[WAL 截断 {d}/{d}] 显式报错：{s}\n", .{ cut, total, @errorName(e) });
            explicit_errors += 1;
            continue;
        };
        defer freeRows(got, alloc);
        recovered += 1;
        max_rows = @max(max_rows, got.len);
        if (got.len > 0 and got.len < rows.len) partial_rows += 1;

        // ④ 必须正好是「完整记录的连续前缀」，且值逐字节一致
        var bad: ?[]const u8 = null;
        if (got.len > rows.len) {
            bad = "行数超过写入数";
        } else {
            for (got, 0..) |g, i| {
                if (g.len != 3) {
                    bad = "列数不对";
                    break;
                }
                if (!valueEq(g[0], .{ .integer = rows[i].id })) {
                    bad = "主键不是前缀";
                    break;
                }
                if (!valueEq(g[1], rowCol(rows[i], .g)) or !valueEq(g[2], rowCol(rows[i], .s))) {
                    bad = "值不是写入值（半条记录/脏数据）";
                    break;
                }
            }
        }

        // ⑤ 恢复要幂等
        if (bad == null) {
            const again = reopenAndRead(io, dir, root, alloc) catch |e| blk: {
                std.debug.print("[WAL 截断 {d}/{d}] 第二次重开报错 {s}\n", .{ cut, total, @errorName(e) });
                fails += 1;
                break :blk &[_][]sql.Value{};
            };
            defer freeRows(again, alloc);
            if (again.len != got.len) {
                bad = "两次重开结果不一致（恢复不幂等）";
            } else {
                for (again, got) |a, b| {
                    for (a, b) |av, bv| {
                        if (!valueEq(av, bv)) {
                            bad = "两次重开结果不一致（恢复不幂等）";
                            break;
                        }
                    }
                }
            }
        }

        if (bad) |why| {
            std.debug.print("[WAL 截断 {d}/{d}] {s}：恢复出 {d} 行\n", .{ cut, total, why, got.len });
            for (got, 0..) |g, i| {
                std.debug.print("  r[{d}] ", .{i});
                printRow(g);
                std.debug.print("\n", .{});
            }
            fails += 1;
        }
    }
    std.debug.print("[WAL 截断] 崩溃态 WAL 总长 {d} 字节；{d} 个截断点：显式报错 {d}、恢复成功 {d}、不合格 {d}\n", .{
        total, cuts.len, explicit_errors, recovered, fails,
    });
    // **防空跑**：如果引擎根本不重放 WAL，每个截断点都会恢复出 0 行，上面那些断言
    // 全都「通过」—— 什么都没测。所以必须钉死两件事：
    //   ① 完整 WAL 能恢复出全部行（重放真的发生了）
    //   ② 至少有一个截断点恢复出「部分行」（截断点真的落在记录中间）
    try std.testing.expectEqual(rows.len, max_rows);
    try std.testing.expect(partial_rows > 0);
    try std.testing.expectEqual(@as(usize, 0), fails);
}
