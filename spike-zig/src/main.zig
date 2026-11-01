// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const spike = @import("pek_rdb_spike");
const codec = spike.codec;
const tablemod = spike.table;

fn opsPerSec(count: u64, ns: u64) f64 {
    return @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(ns)) / 1e9);
}

fn nowNs(io: std.Io) u64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(ts.nanoseconds);
}

/// 流式基准的消费回调：只数行，不保留任何东西。
/// 真实系统里对应「边读边算 / 边读边发」——这正是 SQLite `while rows.next()` 的用法。
fn countRow(cnt: *usize, row: []const spike.sql.Value) anyerror!void {
    if (row.len > 0) cnt.* += 1;
}

fn keyOf(v: i64) [8]u8 {
    var b: [8]u8 = undefined;
    codec.encodeI64Key(&b, v);
    return b;
}

pub fn main() void {
    benchMain() catch |e| {
        std.debug.print("bench_failed,{s},1\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.process.exit(0);
}

fn benchMain() !void {
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const path = "bench-data";
    dir.deleteTree(io, path) catch {};
    defer dir.deleteTree(io, path) catch {};

    const n: u64 = 1_000_000;
    const value: [32]u8 = @splat('x');
    const get_n: u64 = 100_000;
    const scan_lo: i64 = 500_000;
    const scan_hi: i64 = 510_000;

    var out: std.ArrayList(u8) = .empty;
    std.debug.print("metric,count,value\n", .{});

    var t = try tablemod.Table.open(io, dir, path, alloc, .{ .wal_sync_every = 10_000, .flush_bytes = 1 << 30 });
    // recover 之前要手动关掉再 reopen，用标志位避免 defer 二次 deinit（use-after-free）
    var t_live = true;
    defer if (t_live) t.deinit();

    {
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const kb = keyOf(@intCast(i));
            try t.put(&kb, &value);
            if (i % 100_000 == 0) {
                std.debug.print("progress_put,{d},{d}\n", .{ i, (nowNs(io) - t0) / 1_000_000 });
            }
        }
        try t.wal.sync();
        const ns = nowNs(io) - t0;
        std.debug.print("put,{d},{d:.0}\n", .{ n, opsPerSec(n, ns) });
    }

    {
        const t0 = nowNs(io);
        try t.flush();
        const ns = nowNs(io) - t0;
        std.debug.print("flush,{d},{d:.0}\n", .{ n, opsPerSec(n, ns) });
    }

    // 批量写：与 SQLite 单事务批量插入同口径（1M 行一次提交）
    {
        const path2 = "bench-data-batch";
        dir.deleteTree(io, path2) catch {};
        var t3 = try tablemod.Table.open(io, dir, path2, alloc, .{ .wal_sync_every = 0 });
        defer {
            t3.deinit();
            dir.deleteTree(io, path2) catch {};
        }

        const keys = try alloc.alloc([]const u8, @intCast(n));
        defer {
            for (keys) |k| alloc.free(k);
            alloc.free(keys);
        }
        const vals = try alloc.alloc([]const u8, @intCast(n));
        defer alloc.free(vals);
        for (0..@intCast(n)) |i| {
            const kb = try alloc.alloc(u8, 8);
            const enc = keyOf(@intCast(i));
            @memcpy(kb, &enc);
            keys[i] = kb;
            vals[i] = &value;
        }

        const t0 = nowNs(io);
        try t3.putBatch(keys, vals);
        const ns = nowNs(io) - t0;
        std.debug.print("put_batch,{d},{d:.0}\n", .{ n, opsPerSec(n, ns) });
    }

    {
        const t0 = nowNs(io);
        var x: u64 = 88172645463325252;
        var hits: u64 = 0;
        var i: u64 = 0;
        while (i < get_n) : (i += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            const kb = keyOf(@intCast(x % n));
            if (try t.get(&kb, &out) != null) hits += 1;
        }
        const ns = nowNs(io) - t0;
        std.debug.print("get,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, ns) });
        std.debug.print("get_hits,{d},{d}\n", .{ get_n, hits });
    }

    {
        const lo = keyOf(scan_lo);
        const hi = keyOf(scan_hi);
        const t0 = nowNs(io);
        var set = try t.scanRange(&lo, &hi);
        const ns = nowNs(io) - t0;
        defer set.deinit();
        std.debug.print("scan,{d},{d:.0}\n", .{ set.records.len, opsPerSec(@intCast(set.records.len), ns) });
    }

    // 零拷贝扫描（mmap + 单段快路径，1 万行）
    {
        var refs: std.ArrayList(spike.segment.Segment.RefRecord) = .empty;
        defer refs.deinit(alloc);
        const lo = keyOf(scan_lo);
        const hi = keyOf(scan_hi);
        const t0 = nowNs(io);
        try t.scanRefs(&lo, &hi, &refs);
        const ns = nowNs(io) - t0;
        std.debug.print("scan_refs,{d},{d:.0}\n", .{ refs.items.len, opsPerSec(@intCast(refs.items.len), ns) });
    }

    // 大样本扫描（20 万行）：1 万行那两档样本太小，mmap 触页与启动开销占比过重，
    // 波动可达 30%+，不足以判断「扫描能力」。这里扫 20 万行（≈13MB）把固定开销摊掉；
    // 不用 100 万行是为了避免 66MB 级大分配污染后续场景。
    {
        var refs: std.ArrayList(spike.segment.Segment.RefRecord) = .empty;
        defer refs.deinit(alloc);
        const lo0 = keyOf(0);
        const hi0 = keyOf(200_000);
        const t0 = nowNs(io);
        try t.scanRefs(&lo0, &hi0, &refs);
        const ns = nowNs(io) - t0;
        std.debug.print("scan_refs_full,{d},{d:.0}\n", .{ refs.items.len, opsPerSec(@intCast(refs.items.len), ns) });
    }
    {
        const lo0 = keyOf(0);
        const hi0 = keyOf(200_000);
        const t0 = nowNs(io);
        var full = try t.scanRange(&lo0, &hi0);
        const ns = nowNs(io) - t0;
        defer full.deinit();
        std.debug.print("scan_full,{d},{d:.0}\n", .{ full.records.len, opsPerSec(@intCast(full.records.len), ns) });
    }

    // 区间「只数行」（20 万行）：与上面 scan_refs_full 的差别只有**不收集**。
    //
    // 为什么必须单独一档：`scan_refs_full` 会把 20 万条 RefRecord 收进 ArrayList
    // （48B × 20 万 = 9.6MB 写入），而 SQLite 侧对等的参照是 `SELECT id ... while rows.next()`
    // 只推进游标、一条不收集。两边做的事不同，比出来的比值没有意义（前几轮就栽在这上面）。
    // 这一档两边都只数行，才是真正的「扫描能力」。
    {
        const lo0 = keyOf(0);
        const hi0 = keyOf(200_000);
        var it = tablemod.MergeIter{};
        try it.init(&t, &lo0, &hi0);
        defer it.deinit();
        const t0 = nowNs(io);
        var cnt: u64 = 0;
        while (it.next()) |_| cnt += 1;
        const ns = nowNs(io) - t0;
        std.debug.print("count_range,{d},{d:.0}\n", .{ cnt, opsPerSec(cnt, ns) });
    }

    // 多段合并扫描（默认 64MB memtable 会中途自动 flush → 多段）
    {
        const path5 = "bench-data-multi";
        dir.deleteTree(io, path5) catch {};
        var t5 = try tablemod.Table.open(io, dir, path5, alloc, .{ .wal_sync_every = 10_000 });
        defer {
            t5.deinit();
            dir.deleteTree(io, path5) catch {};
        }
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const kb = keyOf(@intCast(i));
            try t5.put(&kb, &value);
        }
        try t5.flush();

        var refs5: std.ArrayList(spike.segment.Segment.RefRecord) = .empty;
        defer refs5.deinit(alloc);
        const lo5 = keyOf(scan_lo);
        const hi5 = keyOf(scan_hi);
        const t0 = nowNs(io);
        try t5.scanRefs(&lo5, &hi5, &refs5);
        const ns = nowNs(io) - t0;
        std.debug.print("scan_refs_multi,{d},{d:.0}\n", .{ refs5.items.len, opsPerSec(@intCast(refs5.items.len), ns) });
        std.debug.print("scan_refs_multi_segs,{d},0\n", .{t5.segs.items.len});
        std.debug.print("merge_cursors_multi,1,{d}\n", .{t5.merge_cursors_built});
    }

    // k=2 归并的**确定性**观测：必须构造范围完全重叠的两段（同一批 key 写两次、各 flush 一次）。
    // 前面那档测不到 k=2 —— 两段是顺序写入、key 范围不重叠，段裁剪直接把第 2 段剪掉
    // （实测 `merge_cursors_multi` 恒为 1），全程走单游标快路径。
    //
    // 本档的价值是确定性指标：`merge2_compares` 恒为 399,999（= 2×200000−1），
    // 与归并实现无关，是「k=2 不得不做的比较数」的下界；`merge2_cursors = 2` 证明真的走了 2 路。
    //
    // 曾想用本档证明「k 小走线性更快」，但那次 A/B 两边一边冷一边热（线性跑第一次、
    // 堆跑预热后的第二次），差异全是假象。**该方向已放弃**；要重试必须两边都预热。
    {
        const path8 = "bench-data-2seg";
        dir.deleteTree(io, path8) catch {};
        var t8 = try tablemod.Table.open(io, dir, path8, alloc, .{ .wal_sync_every = 10_000 });
        defer {
            t8.deinit();
            dir.deleteTree(io, path8) catch {};
        }
        var j: u64 = 0;
        while (j < 200_000) : (j += 1) {
            const kb = keyOf(@intCast(j));
            try t8.put(&kb, &value);
        }
        try t8.flush();
        j = 0;
        while (j < 200_000) : (j += 1) {
            const kb = keyOf(@intCast(j));
            try t8.put(&kb, &value);
        }
        try t8.flush();

        var hi8: [16]u8 = @splat(0xFF);
        const cmp8 = t8.merge_compares_total;
        const tm0 = nowNs(io);
        var cnt8: u64 = 0;
        {
            var it8 = tablemod.MergeIter{};
            try it8.init(&t8, &.{}, &hi8);
            defer it8.deinit();
            while (it8.next()) |_| cnt8 += 1;
        }
        const nsm = nowNs(io) - tm0;
        std.debug.print("merge2,{d},{d:.0}\n", .{ cnt8, opsPerSec(cnt8, nsm) });
        std.debug.print("merge2_cursors,{d},0\n", .{t8.merge_cursors_built});
        std.debug.print("merge2_compares,{d},{d}\n", .{ cnt8, t8.merge_compares_total - cmp8 });
    }

    // 100 万行**全表**裸扫描（含值），与 SQL 层 sql_full 同口径。
    // 这一档是为了分清「SQL 层比 SQLite 慢 23%」到底差在存储扫描还是行解码/结果集构造：
    // 前面 scan / scan_full 只扫 1 万 / 20 万行区间，不能与 sql_full（100 万行）直接比。
    // 注意：本档会分配约 98MB（66MB buf + 32MB records），会挤占后续场景的页缓存，
    // 所以放在 t 生命周期末尾。
    {
        const t0 = nowNs(io);
        var full = try t.scanRange(&.{}, &.{});
        const ns = nowNs(io) - t0;
        defer full.deinit();
        std.debug.print("scan_full1m,{d},{d:.0}\n", .{ full.records.len, opsPerSec(@intCast(full.records.len), ns) });
    }
    {
        var refsf: std.ArrayList(spike.segment.Segment.RefRecord) = .empty;
        defer refsf.deinit(alloc);
        const t0 = nowNs(io);
        try t.scanRefs(&.{}, &.{}, &refsf);
        const ns = nowNs(io) - t0;
        std.debug.print("scan_refs_full1m,{d},{d:.0}\n", .{ refsf.items.len, opsPerSec(@intCast(refsf.items.len), ns) });
    }

    t.deinit();
    t_live = false;

    {
        const t0 = nowNs(io);
        var t2 = try tablemod.Table.open(io, dir, path, alloc, .{ .wal_sync_every = 10_000 });
        const ns = nowNs(io) - t0;
        defer t2.deinit();
        std.debug.print("recover,{d},{d:.2}\n", .{ n, @as(f64, @floatFromInt(ns)) / 1e6 });
        const kb = keyOf(12345);
        const v = try t2.get(&kb, &out);
        std.debug.print("recover_read,1,{d}\n", .{@intFromBool(v != null)});
    }

    // SQL 层同层基准：INSERT 逐行 / PK 点查（解析只做一次，等价于预编译语句）
    {
        const path4 = "bench-data-sql";
        dir.deleteTree(io, path4) catch {};
        const cols = [_]spike.schema.Column{
            .{ .name = "id", .col_type = .integer, .primary_key = true },
            .{ .name = "v", .col_type = .text },
        };
        var s = try spike.schema.Schema.init(alloc, "bench_sql", &cols);
        defer s.deinit(alloc);
        var t4 = try tablemod.Table.open(io, dir, path4, alloc, .{ .wal_sync_every = 10_000 });
        defer {
            t4.deinit();
            dir.deleteTree(io, path4) catch {};
        }

        const text_val: []const u8 = &value;
        const t_sql_put = nowNs(io);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            var row_vals = [_]spike.sql.Value{ .{ .integer = @intCast(i) }, .{ .text = text_val } };
            var row = [_][]spike.sql.Value{&row_vals};
            const ins = spike.sql.Insert{
                .table = "bench_sql",
                .columns = &.{ "id", "v" },
                .rows = &row,
            };
            _ = try spike.exec.insertRows(&t4, &s, ins, alloc);
            if (i % 100_000 == 0) {
                std.debug.print("progress_sql_put,{d},{d},segs={d},mem={d}\n", .{
                    i, (nowNs(io) - t_sql_put) / 1_000_000, t4.segs.items.len, t4.mem.len(),
                });
            }
        }
        const ns_put = nowNs(io) - t_sql_put;
        std.debug.print("sql_put,{d},{d:.0}\n", .{ n, opsPerSec(n, ns_put) });
        std.debug.print("sql_put_segs,{d},0\n", .{t4.segs.items.len});

        const t_sql_get = nowNs(io);
        var hits: u64 = 0;
        var x: u64 = 88172645463325252;
        i = 0;
        while (i < get_n) : (i += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            var items = [_]spike.sql.SelectItem{ .{ .column = "id" }, .{ .column = "v" } };
            const sel = spike.sql.Select{
                .items = &items,
                .table = "bench_sql",
                .where = .{ .column = "id", .op = .eq, .value = .{ .integer = @intCast(x % n) } },
            };
            var rows = try spike.exec.selectRows(&t4, &s, sel, alloc);
            if (rows.rows.len > 0) hits += 1;
            rows.deinit();
        }
        const ns_get = nowNs(io) - t_sql_get;
        std.debug.print("sql_get,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, ns_get) });
        std.debug.print("sql_get_hits,{d},{d}\n", .{ get_n, hits });

        // 分页查询：100 万行表上 `SELECT * FROM t LIMIT 10`。
        // 改之前要扫全表 + 全量解码再截断；现在凑够 10 行就停。
        {
            var items_l = [_]spike.sql.SelectItem{.{ .star = {} }};
            const sel_l = spike.sql.Select{ .items = &items_l, .table = "bench_sql", .limit = 10 };
            t4.scan_rows_read = 0;
            const t0 = nowNs(io);
            var rows = try spike.exec.selectRows(&t4, &s, sel_l, alloc);
            const ns = nowNs(io) - t0;
            defer rows.deinit();
            std.debug.print("sql_limit10,{d},{d:.0}\n", .{ rows.rows.len, opsPerSec(rows.rows.len, ns) });
            // 确定性指标：读了多少行（不是靠计时推断「省了多少」）
            std.debug.print("sql_limit10_readrows,{d},0\n", .{t4.scan_rows_read});
        }
        // 对照：同样的表取全部（无 LIMIT）—— 证明上面的差距来自「少读」而不是缓存
        {
            var items_f = [_]spike.sql.SelectItem{.{ .star = {} }};
            const sel_f = spike.sql.Select{ .items = &items_f, .table = "bench_sql" };
            t4.scan_rows_read = 0;
            const t0 = nowNs(io);
            var rows = try spike.exec.selectRows(&t4, &s, sel_f, alloc);
            const ns = nowNs(io) - t0;
            defer rows.deinit();
            std.debug.print("sql_full,{d},{d:.0}\n", .{ rows.rows.len, opsPerSec(@intCast(rows.rows.len), ns) });
            std.debug.print("sql_full_readrows,{d},0\n", .{t4.scan_rows_read});
        }
        // 投影扫描：同一张表、同样全表范围，只取 1 列（`SELECT id`）。
        //
        // 为什么单独一档：SQLite 的 `OP_Column` 是惰性的（不调 `sqlite3_column_*` 就
        // 不解码），而我们现在是「解码全部列再丢掉未投影的」。
        // 这一档就是「惰性列解码到底值多少钱」的基准 —— 先量现状再决定改不改。
        {
            var items_p = [_]spike.sql.SelectItem{.{ .column = "id" }};
            const sel_p = spike.sql.Select{ .items = &items_p, .table = "bench_sql" };
            t4.scan_rows_read = 0;
            const t0 = nowNs(io);
            var rows_p = try spike.exec.selectRows(&t4, &s, sel_p, alloc);
            const ns = nowNs(io) - t0;
            defer rows_p.deinit();
            std.debug.print("sql_proj1,{d},{d:.0}\n", .{ rows_p.rows.len, opsPerSec(@intCast(rows_p.rows.len), ns) });
            std.debug.print("sql_proj1_cols,{d},0\n", .{if (rows_p.rows.len > 0) rows_p.rows[0].len else 0});
        }
        // 投影流式（不物化）：`SELECT id` 走 forEachRow，与 sql_each 同口径
        {
            var items_p2 = [_]spike.sql.SelectItem{.{ .column = "id" }};
            const sel_p2 = spike.sql.Select{ .items = &items_p2, .table = "bench_sql" };
            var cnt_p: usize = 0;
            t4.scan_rows_read = 0;
            const t0 = nowNs(io);
            _ = try spike.exec.forEachRow(&t4, &s, sel_p2, alloc, &cnt_p, countRow);
            const ns = nowNs(io) - t0;
            std.debug.print("sql_each_proj1,{d},{d:.0}\n", .{ cnt_p, opsPerSec(@intCast(cnt_p), ns) });
        }
        // 流式（不物化）：SQLite `while rows.next()` 的等价物。
        // 与上面的 sql_full 跑同一条语句、同一张表，唯一差别是**消费方式**：
        // 物化要 flat 48MB + buf 32MB + hdrs 16MB，流式只有几个复用槽位。
        // 这一对数字才是「同一件事」的对比 —— 之前拿我们的物化比 SQLite 的流式，本身就不对等。
        {
            var items_e = [_]spike.sql.SelectItem{.{ .star = {} }};
            const sel_e = spike.sql.Select{ .items = &items_e, .table = "bench_sql" };
            var cnt: usize = 0;
            t4.scan_rows_read = 0;
            const t0 = nowNs(io);
            _ = try spike.exec.forEachRow(&t4, &s, sel_e, alloc, &cnt, countRow);
            const ns = nowNs(io) - t0;
            std.debug.print("sql_each,{d},{d:.0}\n", .{ cnt, opsPerSec(@intCast(cnt), ns) });
            std.debug.print("sql_each_readrows,{d},0\n", .{t4.scan_rows_read});
        }
        // 低选择性 WHERE（审计 P1 的度量）：200 万行表上跑一个命中 0 行的条件。
        // 修复前 `keep.ensureTotalCapacity(cap)` 会按全表上界预分配 200万×16B = 32MB，
        // 白交分配与缺页的代价；修复后只给 4096 初值。这个指标专门盯住它。
        {
            var items_w = [_]spike.sql.SelectItem{.{ .star = {} }};
            const sel_w = spike.sql.Select{
                .items = &items_w,
                .table = "bench_sql",
                .where = .{ .column = "v", .op = .eq, .value = .{ .text = "nonexistent-value" } },
            };
            const t0 = nowNs(io);
            var rows_w = try spike.exec.selectRows(&t4, &s, sel_w, alloc);
            const ns = nowNs(io) - t0;
            defer rows_w.deinit();
            std.debug.print("sql_where_rare,{d},{d:.0}\n", .{ rows_w.rows.len, opsPerSec(@intCast(t4.scan_rows_read), ns) });
        }
        // 物化成本拆解：把 selectRows 的四个阶段分别计时，**不猜**。
        // 只有知道 61ms 花在哪一段，才知道该优化什么（§16.1.11 的起点）。
        // 本段会重新分配约 136MB，放在 t4 生命周期最后。
        {
            var hi: [16]u8 = @splat(0xFF);
            var vals: std.ArrayList([]const u8) = .empty;
            defer vals.deinit(alloc);

            const ta = nowNs(io);
            try t4.scanValues(&.{}, &hi, &vals);
            const tb = nowNs(io);

            var total_len: usize = 0;
            for (vals.items) |v| total_len += v.len;
            const buf = try alloc.alloc(u8, total_len);
            defer alloc.free(buf);
            var off: usize = 0;
            for (vals.items) |v| {
                @memcpy(buf[off..][0..v.len], v);
                off += v.len;
            }
            const tc = nowNs(io);

            const ncols = s.columns.len;
            const flat = try alloc.alloc(spike.sql.Value, vals.items.len * ncols);
            defer alloc.free(flat);
            var k: usize = 0;
            var o2: usize = 0;
            while (k < vals.items.len) : (k += 1) {
                const raw = buf[o2..][0..vals.items[k].len];
                o2 += vals.items[k].len;
                try s.decodeRowInto(flat[k * ncols ..][0..ncols], raw);
            }
            const td = nowNs(io);

            const hdrs = try alloc.alloc([]spike.sql.Value, vals.items.len);
            defer alloc.free(hdrs);
            for (0..vals.items.len) |j| hdrs[j] = flat[j * ncols ..][0..ncols];
            const te = nowNs(io);

            const rows_n: u64 = @intCast(vals.items.len);
            std.debug.print("mat_scanrefs,{d},{d:.0}\n", .{ rows_n, opsPerSec(rows_n, tb - ta) });
            std.debug.print("mat_buf_copy,{d},{d:.0}\n", .{ @as(u64, @intCast(total_len)), opsPerSec(@intCast(total_len), tc - tb) });
            std.debug.print("mat_decode,{d},{d:.0}\n", .{ rows_n, opsPerSec(rows_n, td - tc) });
            std.debug.print("mat_hdrs,{d},{d:.0}\n", .{ rows_n, opsPerSec(rows_n, te - td) });
            std.debug.print("mat_ms,{d},{d},{d},{d},{d}\n", .{ (tb - ta) / 1_000_000, (tc - tb) / 1_000_000, (td - tc) / 1_000_000, (te - td) / 1_000_000, (te - ta) / 1_000_000 });
        }
    }

    // 并发写（**跨表并行**：架构口径是「单表串行、跨表并行」）
    // 每个线程持有独立的 Table，互不共享，测的是引擎在多核上的扩展性。
    {
        const threads_list = [_]u32{ 1, 2, 4 };
        for (threads_list) |nt| {
            const per: u64 = 300_000;
            var paths: [4][24]u8 = undefined;
            var names: [4][]const u8 = undefined;
            for (0..nt) |i| {
                const name = try std.fmt.bufPrint(&paths[i], "bench-data-conc-{d}", .{i});
                names[i] = name;
                dir.deleteTree(io, name) catch {};
            }
            defer for (0..nt) |i| dir.deleteTree(io, names[i]) catch {};

            const t0 = nowNs(io);
            var workers: [4]std.Thread = undefined;
            var done: [4]u64 = @splat(0);
            var failed: [4]bool = @splat(false);
            for (0..nt) |i| {
                workers[i] = try std.Thread.spawn(.{}, concWriter, .{ConcArgs{
                    .io = io,
                    .dir = dir,
                    .path = names[i],
                    .n = per,
                    .done = &done[i],
                    .failed = &failed[i],
                }});
            }
            for (0..nt) |i| workers[i].join();
            const ns = nowNs(io) - t0;
            var total: u64 = 0;
            var any_fail = false;
            for (0..nt) |i| {
                total += done[i];
                any_fail = any_fail or failed[i];
            }
            std.debug.print("conc_put_{d}t,{d},{d:.0}\n", .{ nt, total, opsPerSec(total, ns) });
            if (any_fail) std.debug.print("conc_put_{d}t_failed,1,1\n", .{nt});
        }
    }

    // 超内存数据集：小 memtable → 大量段，考察多段 k 路归并的点查/扫描
    {
        const path6 = "bench-data-big";
        dir.deleteTree(io, path6) catch {};
        defer dir.deleteTree(io, path6) catch {};

        const big_n: u64 = 2_000_000;
        var t6 = try tablemod.Table.open(io, dir, path6, alloc, .{
            .wal_sync_every = 10_000,
            .flush_bytes = 8 << 20, // 8MB → 约 28 个段
        });
        // 冷重开那一步要先手动关掉，所以用标志位避免 defer 二次 deinit（否则是 use-after-free）
        var t6_live = true;
        defer if (t6_live) t6.deinit();

        const t_big_put = nowNs(io);
        var i: u64 = 0;
        while (i < big_n) : (i += 1) {
            const kb = keyOf(@intCast(i));
            try t6.put(&kb, &value);
        }
        try t6.flush();
        const ns_big_put = nowNs(io) - t_big_put;
        std.debug.print("big_put,{d},{d:.0}\n", .{ big_n, opsPerSec(big_n, ns_big_put) });
        std.debug.print("big_segs,{d},0\n", .{t6.segs.items.len});

        // 点查（随机）
        {
            const t0 = nowNs(io);
            var x: u64 = 88172645463325252;
            var hits: u64 = 0;
            i = 0;
            while (i < get_n) : (i += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(x % big_n));
                if (try t6.get(&kb, &out) != null) hits += 1;
            }
            const ns = nowNs(io) - t0;
            std.debug.print("big_get,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, ns) });
            std.debug.print("big_get_hits,{d},{d}\n", .{ get_n, hits });
        }

        // 不命中点查：全部查不存在的 key（这正是 Bloom 的价值——避免为不存在的 key 读数据块）
        {
            const t0 = nowNs(io);
            var x: u64 = 1442695040888963407;
            var hits: u64 = 0;
            i = 0;
            while (i < get_n) : (i += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(big_n + (x % big_n)));
                if (try t6.get(&kb, &out) != null) hits += 1;
            }
            const ns = nowNs(io) - t0;
            std.debug.print("big_get_miss,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, ns) });
            std.debug.print("big_get_miss_hits,{d},{d}\n", .{ get_n, hits });
        }

        // 多段范围扫描
        {
            var refs6: std.ArrayList(spike.segment.Segment.RefRecord) = .empty;
            defer refs6.deinit(alloc);
            const lo6 = keyOf(scan_lo);
            const hi6 = keyOf(scan_hi);
            const t0 = nowNs(io);
            try t6.scanRefs(&lo6, &hi6, &refs6);
            const ns = nowNs(io) - t0;
            std.debug.print("big_scan_refs,{d},{d:.0}\n", .{ refs6.items.len, opsPerSec(@intCast(refs6.items.len), ns) });
        }

        // 纯遍历计数（不收集、不复制）：与 SQLite 的 `while rows.next()` 只数行**同口径**。
        // 上面那档只扫 1 万行，绝对耗时 <1µs，测到的其实是固定开销与计时粒度，
        // 不足以判断「扫描能力」；这里扫 50 万行，把绝对耗时推进到 ms 级。
        {
            var hi6: [16]u8 = @splat(0xFF);
            var it6 = tablemod.MergeIter{};
            try it6.init(&t6, &.{}, &hi6);
            defer it6.deinit();
            const t0 = nowNs(io);
            var cnt6: u64 = 0;
            while (it6.next()) |_| {
                cnt6 += 1;
                if (cnt6 >= 500_000) break;
            }
            const ns = nowNs(io) - t0;
            std.debug.print("big_count,{d},{d:.0}\n", .{ cnt6, opsPerSec(cnt6, ns) });
        }

        // 超内存 · 区间「只数行」（20 万行）：对等 SQLite 的 `SELECT id WHERE id >= 0 AND id < 200000`。
        // 上面 `big_scan_refs` 是收集 RefRecord、SQLite 的 `big_scan` 是只数行，两边不对等；
        // 且样本只 1 万行（绝对耗时 <1µs，测的是计时粒度）。这一档把两件事一起修掉。
        {
            const lo7 = keyOf(0);
            const hi7 = keyOf(200_000);
            var it7 = tablemod.MergeIter{};
            try it7.init(&t6, &lo7, &hi7);
            defer it7.deinit();
            const t0 = nowNs(io);
            var cnt7: u64 = 0;
            while (it7.next()) |_| cnt7 += 1;
            const ns = nowNs(io) - t0;
            std.debug.print("big_count_range,{d},{d:.0}\n", .{ cnt7, opsPerSec(cnt7, ns) });
        }

        // 诊断：索引聚合文件大小（现在全部段索引在 seg/index.bin 里）
        {
            const ip = try alloc.print("{s}/seg/index.bin", .{path6});
            defer alloc.free(ip);
            const f = try dir.openFile(io, ip, .{});
            defer f.close(io);
            std.debug.print("big_idx_bytes,1,{d}\n", .{(try f.stat(io)).size});
        }

        // **落盘占用**（确定性指标：不依赖计时，一轮即可）。
        //
        // 这是 LSM 的已知弱项，此前 20 多轮里**一次都没测过** —— 只知道读写快，
        // 不知道代价是多少磁盘。SQLite 侧同档输出 `big_disk_bytes`（先做
        // wal_checkpoint(TRUNCATE)，与我们「flush 后删 WAL」的稳态对齐）。
        {
            var total: u64 = 0;
            {
                const ip = try alloc.print("{s}/seg/index.bin", .{path6});
                defer alloc.free(ip);
                if (dir.openFile(io, ip, .{})) |ff| {
                    defer ff.close(io);
                    total += (try ff.stat(io)).size;
                } else |_| {}
            }
            for (t6.segs.items) |s| {
                const p = try alloc.print("{s}/seg/{d:0>6}.data", .{ path6, s.id });
                defer alloc.free(p);
                if (dir.openFile(io, p, .{})) |ff| {
                    defer ff.close(io);
                    total += (try ff.stat(io)).size;
                } else |_| {}
            }
            std.debug.print("big_disk_bytes,{d},{d}\n", .{ big_n, total });
            std.debug.print("big_disk_bytes_row,1,{d}\n", .{total / big_n});
            // 写放大（千分比）：flush 产出 + 合并重写 ÷ 用户数据量。
            // 本档不触发自动合并，所以 ≈1000（1.0×）；有合并的档位见 `cm_write_amp_milli`。
            std.debug.print("big_write_amp_milli,1,{d}\n", .{(t6.flush_bytes_total + t6.compact_bytes_total) * 1000 / @max(1, t6.flush_bytes_total)});
        }

        // 冷重开：默认（索引懒加载）vs 预热（全量读入页缓存）
        {
            t6.deinit();
            t6_live = false;
            spike.segment.timing = .{};
            spike.segment.timing_enabled = true;
            const t0 = nowNs(io);
            var t7 = try tablemod.Table.open(io, dir, path6, alloc, .{
                .wal_sync_every = 10_000,
                .flush_bytes = 8 << 20,
            });
            const ns = nowNs(io) - t0;
            spike.segment.timing_enabled = false;
            const tm = spike.segment.timing;
            std.debug.print("big_recover,{d},{d:.2}\n", .{ big_n, @as(f64, @floatFromInt(ns)) / 1e6 });
            std.debug.print("big_recover_breakdown_ms,dirs,{d:.2}\n", .{@as(f64, @floatFromInt(tm.dirs)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,idx_alloc,{d:.2}\n", .{@as(f64, @floatFromInt(tm.idx_alloc)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,idx_copy,{d:.2}\n", .{@as(f64, @floatFromInt(tm.idx_copy)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,wal_replay,{d:.2}\n", .{@as(f64, @floatFromInt(tm.wal_replay)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,wal_open,{d:.2}\n", .{@as(f64, @floatFromInt(tm.wal_open)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,segs,{d:.2}\n", .{@as(f64, @floatFromInt(tm.segs)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,mkseg,{d:.2}\n", .{@as(f64, @floatFromInt(tm.mkseg)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,seg_append,{d:.2}\n", .{@as(f64, @floatFromInt(tm.seg_append)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,idx_read,{d:.2}\n", .{@as(f64, @floatFromInt(tm.idx_read)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,crc,{d:.2}\n", .{@as(f64, @floatFromInt(tm.crc)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,parse,{d:.2}\n", .{@as(f64, @floatFromInt(tm.parse)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,data_open,{d:.2}\n", .{@as(f64, @floatFromInt(tm.data_open)) / 1e6});
            std.debug.print("big_recover_breakdown_ms,mmap,{d:.2}\n", .{@as(f64, @floatFromInt(tm.mmap)) / 1e6});

            // 重开后立刻点查：懒加载的缺页代价落到读路径上（先量，再决定要不要预热）
            {
                const t1 = nowNs(io);
                var x: u64 = 88172645463325252;
                var hits: u64 = 0;
                i = 0;
                while (i < get_n) : (i += 1) {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    const kb = keyOf(@intCast(x % big_n));
                    if (try t7.get(&kb, &out) != null) hits += 1;
                }
                const ns2 = nowNs(io) - t1;
                std.debug.print("big_get_after_reopen,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, ns2) });
                std.debug.print("big_get_after_reopen_hits,{d},{d}\n", .{ get_n, hits });
            }
            t7.deinit();

            const t2 = nowNs(io);
            var t8 = try tablemod.Table.open(io, dir, path6, alloc, .{
                .wal_sync_every = 10_000,
                .flush_bytes = 8 << 20,
                .mmap_preheat = true,
            });
            const ns_pre = nowNs(io) - t2;
            std.debug.print("big_recover_preheat,{d},{d:.0}\n", .{ big_n, @as(f64, @floatFromInt(ns_pre)) / 1e6 });
            t8.deinit();
        }

        // 诊断：索引「读取方式」对照 —— 堆读 vs mmap。
        //
        // 背景：`big_recover` 的分阶段实测显示 `idx_copy` = 1.01ms 占 57%
        // （3.13MB / 1.01ms = 3.1GB/s，是 Windows 上 readPositionalAll 的实速），
        // 而 `idx_alloc` 只占 0.19ms。也就是说**只要还把索引拷进用户空间，这 1ms 就下不来**。
        // 这里只量「拿到可访问字节」的成本，不解析、不校验，回答两个问题：
        //   ① mmap 建映射本身有多贵（应该接近 0）；
        //   ② mmap 之后「只读 record 头」vs「全量访存」各多贵（决定能否懒加载）。
        // 顺序要紧：只读头在前，全量在后，否则前者会被后者的缺页掩盖。
        {
            const ip = try alloc.print("{s}/seg/index.bin", .{path6});
            defer alloc.free(ip);

            // 先预热页缓存一次，避免 A 先跑替 B 付了首次 IO 的账
            {
                const f = try dir.openFile(io, ip, .{});
                defer f.close(io);
                const sz: usize = @intCast((try f.stat(io)).size);
                const warm = try alloc.alloc(u8, sz);
                defer alloc.free(warm);
                _ = try f.readPositionalAll(io, warm, 0);
            }

            var sum: u64 = 0;

            // A. 堆读：openFile + stat + alloc + readPositionalAll（= 现在的做法）
            const ta = nowNs(io);
            var heap: []u8 = &.{};
            {
                const f = try dir.openFile(io, ip, .{});
                defer f.close(io);
                const sz: usize = @intCast((try f.stat(io)).size);
                heap = try alloc.alloc(u8, sz);
                _ = try f.readPositionalAll(io, heap, 0);
            }
            const ns_heap = nowNs(io) - ta;
            defer alloc.free(heap);
            sum +%= heap[heap.len / 2];

            // B. mmap：openFile + stat + MemoryMap.create（不触碰页面）
            const tb = nowNs(io);
            const f2 = try dir.openFile(io, ip, .{});
            const sz2: usize = @intCast((try f2.stat(io)).size);
            var mm = try std.Io.File.MemoryMap.create(io, f2, .{
                .len = sz2,
                .protection = .{ .read = true, .write = false },
            });
            const ns_map = nowNs(io) - tb;
            defer {
                mm.destroy(io);
                f2.close(io);
            }

            // C. mmap + 只读 record 头（模拟「只读段元信息表就完成重开」）
            const tc = nowNs(io);
            var pos: usize = 8;
            var nrec: u64 = 0;
            while (pos + 16 <= mm.memory.len) {
                const len: usize = @intCast(std.mem.readInt(u32, mm.memory[pos..][0..4], .little));
                if (pos + 16 + len > mm.memory.len) break;
                sum +%= mm.memory[pos];
                pos += 16 + len;
                nrec += 1;
            }
            const ns_hdr = nowNs(io) - tc;

            // D. mmap + 全量访存（模拟 CRC 校验必须读全部 payload 的缺页成本）
            const td = nowNs(io);
            var k: usize = 0;
            while (k < mm.memory.len) : (k += 4096) sum +%= mm.memory[k];
            const ns_touch = nowNs(io) - td;

            std.mem.doNotOptimizeAway(sum);
            std.debug.print("idx_read_probe_ms,heap,{d:.3}\n", .{@as(f64, @floatFromInt(ns_heap)) / 1e6});
            std.debug.print("idx_read_probe_ms,mmap,{d:.3}\n", .{@as(f64, @floatFromInt(ns_map)) / 1e6});
            std.debug.print("idx_read_probe_ms,mmap_hdronly,{d:.3}\n", .{@as(f64, @floatFromInt(ns_hdr)) / 1e6});
            std.debug.print("idx_read_probe_ms,mmap_touch,{d:.3}\n", .{@as(f64, @floatFromInt(ns_touch)) / 1e6});
            std.debug.print("idx_read_probe_recs,1,{d}\n", .{nrec});
            std.debug.print("idx_read_probe_bytes,1,{d}\n", .{mm.memory.len});
        }
    }

    // Bloom 开关对照：同数据集（200 万行 / 25 段），bloom_bits=0。
    // Bloom 占索引体积 ~80%，但只对「不存在的 key」有用 —— 用同轮 A/B 决定默认值。
    {
        const path9 = "bench-data-b8";
        dir.deleteTree(io, path9) catch {};
        defer dir.deleteTree(io, path9) catch {};

        const bn: u64 = 2_000_000;
        var t9 = try tablemod.Table.open(io, dir, path9, alloc, .{
            .wal_sync_every = 10_000,
            .flush_bytes = 8 << 20,
            .bloom_bits = 8,
        });
        var t9_live = true;
        defer if (t9_live) t9.deinit();

        const t_nb_put = nowNs(io);
        var bi: u64 = 0;
        while (bi < bn) : (bi += 1) {
            const kb = keyOf(@intCast(bi));
            try t9.put(&kb, &value);
        }
        try t9.flush();
        std.debug.print("b8_put,{d},{d:.0}\n", .{ bn, opsPerSec(bn, nowNs(io) - t_nb_put) });
        std.debug.print("b8_segs,{d},0\n", .{t9.segs.items.len});

        {
            const ip = try alloc.print("{s}/seg/index.bin", .{path9});
            defer alloc.free(ip);
            const f = try dir.openFile(io, ip, .{});
            defer f.close(io);
            std.debug.print("b8_idx_bytes,1,{d}\n", .{(try f.stat(io)).size});
        }

        // 命中点查
        {
            const t0 = nowNs(io);
            var x: u64 = 88172645463325252;
            var hits: u64 = 0;
            bi = 0;
            while (bi < get_n) : (bi += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(x % bn));
                if (try t9.get(&kb, &out) != null) hits += 1;
            }
            std.debug.print("b8_get,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, nowNs(io) - t0) });
            std.debug.print("b8_get_hits,{d},{d}\n", .{ get_n, hits });
        }

        // 不命中点查（Bloom 在这里才有价值）
        {
            const t0 = nowNs(io);
            var x: u64 = 1442695040888963407;
            var hits: u64 = 0;
            bi = 0;
            while (bi < get_n) : (bi += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(bn + (x % bn)));
                if (try t9.get(&kb, &out) != null) hits += 1;
            }
            std.debug.print("b8_get_miss,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, nowNs(io) - t0) });
            std.debug.print("b8_get_miss_hits,{d},{d}\n", .{ get_n, hits });
        }

        // 冷重开
        t9.deinit();
        t9_live = false;
        {
            const t0 = nowNs(io);
            var t10 = try tablemod.Table.open(io, dir, path9, alloc, .{
                .wal_sync_every = 10_000,
                .flush_bytes = 8 << 20,
                .bloom_bits = 8,
            });
            const ns = nowNs(io) - t0;
            defer t10.deinit();
            std.debug.print("b8_recover,{d},{d:.2}\n", .{ bn, @as(f64, @floatFromInt(ns)) / 1e6 });
            {
                const t1 = nowNs(io);
                var x: u64 = 88172645463325252;
                var hits: u64 = 0;
                bi = 0;
                while (bi < get_n) : (bi += 1) {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    const kb = keyOf(@intCast(x % bn));
                    if (try t10.get(&kb, &out) != null) hits += 1;
                }
                std.debug.print("b8_get_after_reopen,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, nowNs(io) - t1) });
                std.debug.print("b8_get_after_reopen_hits,{d},{d}\n", .{ get_n, hits });
            }
            {
                const t1 = nowNs(io);
                var x: u64 = 1442695040888963407;
                var hits: u64 = 0;
                bi = 0;
                while (bi < get_n) : (bi += 1) {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    const kb = keyOf(@intCast(bn + (x % bn)));
                    if (try t10.get(&kb, &out) != null) hits += 1;
                }
                std.debug.print("b8_get_miss_after_reopen,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, nowNs(io) - t1) });
                std.debug.print("b8_get_miss_after_reopen_hits,{d},{d}\n", .{ get_n, hits });
            }
        }
    }

    // 随机原地 UPDATE（§16.1 达标线里 SQLite 的强项）：在已落段的 100 万行表上随机改 10 万行。
    // Zig 侧所有写都走 WAL 组提交（wal_sync_every=10000），口径对应 SQLite 的「单事务」形态。
    {
        const path8 = "bench-data-update";
        dir.deleteTree(io, path8) catch {};
        defer dir.deleteTree(io, path8) catch {};

        var tu = try tablemod.Table.open(io, dir, path8, alloc, .{ .wal_sync_every = 10_000, .flush_bytes = 1 << 30 });
        defer tu.deinit();

        // 先建 100 万行并落成 1 段（模拟「已有数据的表」）
        var ui: u64 = 0;
        while (ui < n) : (ui += 1) {
            const kb = keyOf(@intCast(ui));
            try tu.put(&kb, &value);
        }
        try tu.flush();

        const value2: [32]u8 = @splat('y');

        // 随机更新 10 万行
        {
            const t0 = nowNs(io);
            var x: u64 = 88172645463325252;
            ui = 0;
            while (ui < get_n) : (ui += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(x % n));
                try tu.put(&kb, &value2);
            }
            const ns = nowNs(io) - t0;
            std.debug.print("upd_random,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, ns) });
        }

        // 更新后点查
        {
            const t0 = nowNs(io);
            var x: u64 = 88172645463325252;
            var hits: u64 = 0;
            var saw_new: u64 = 0;
            ui = 0;
            while (ui < get_n) : (ui += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(x % n));
                if (try tu.get(&kb, &out)) |v| {
                    hits += 1;
                    if (v.len == value2.len and v[0] == 'y') saw_new += 1;
                }
            }
            const ns = nowNs(io) - t0;
            std.debug.print("upd_get,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, ns) });
            std.debug.print("upd_get_hits,{d},{d}\n", .{ get_n, hits });
            std.debug.print("upd_get_newvalues,{d},{d}\n", .{ get_n, saw_new });
        }

        // 把 10 万条新版本落成新段：LSM 的更新代价在这里体现（段数 + 读放大）
        {
            const t0 = nowNs(io);
            try tu.flush();
            const ns = nowNs(io) - t0;
            std.debug.print("upd_flush_ms,{d},{d:.2}\n", .{ get_n, @as(f64, @floatFromInt(ns)) / 1e6 });
            std.debug.print("upd_segs,{d},0\n", .{tu.segs.items.len});
        }
        {
            const t0 = nowNs(io);
            var x: u64 = 88172645463325252;
            var hits: u64 = 0;
            ui = 0;
            while (ui < get_n) : (ui += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(x % n));
                if (try tu.get(&kb, &out) != null) hits += 1;
            }
            const ns = nowNs(io) - t0;
            std.debug.print("upd_get_after_flush,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, ns) });
            std.debug.print("upd_get_after_flush_hits,{d},{d}\n", .{ get_n, hits });
        }
    }

    // 段数曲线：**同一份数据**（200 万行）、不同 flush_bytes → 不同段数，
    // 量出「段数 → 点查 / 扫描 / 冷重开」的代价。这是 compaction 触发策略的依据（先量再做）。
    {
        const cn: u64 = 2_000_000;
        const curve = [_]struct { tag: []const u8, fb: usize }{
            .{ .tag = "c128m", .fb = 128 << 20 },
            .{ .tag = "c32m", .fb = 32 << 20 },
            .{ .tag = "c16m", .fb = 16 << 20 },
            .{ .tag = "c8m", .fb = 8 << 20 },
        };
        for (curve) |c| {
            const cp = try alloc.print("bench-data-curve-{s}", .{c.tag});
            defer alloc.free(cp);
            dir.deleteTree(io, cp) catch {};
            defer dir.deleteTree(io, cp) catch {};

            var ct = try tablemod.Table.open(io, dir, cp, alloc, .{ .wal_sync_every = 10_000, .flush_bytes = c.fb });
            var ct_live = true;
            defer if (ct_live) ct.deinit();

            var ci: u64 = 0;
            const cput0 = nowNs(io);
            while (ci < cn) : (ci += 1) {
                const kb = keyOf(@intCast(ci));
                try ct.put(&kb, &value);
            }
            try ct.flush();
            std.debug.print("{s}_put,{d},{d:.0}\n", .{ c.tag, cn, opsPerSec(cn, nowNs(io) - cput0) });
            std.debug.print("{s}_segs,{d},0\n", .{ c.tag, ct.segs.items.len });

            {
                const ip = try alloc.print("{s}/seg/index.bin", .{cp});
                defer alloc.free(ip);
                const f = try dir.openFile(io, ip, .{});
                defer f.close(io);
                std.debug.print("{s}_idx_bytes,1,{d}\n", .{ c.tag, (try f.stat(io)).size });
            }

            // 命中点查
            {
                const t0 = nowNs(io);
                var x: u64 = 88172645463325252;
                var hits: u64 = 0;
                ci = 0;
                while (ci < get_n) : (ci += 1) {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    const kb = keyOf(@intCast(x % cn));
                    if (try ct.get(&kb, &out) != null) hits += 1;
                }
                std.debug.print("{s}_get,{d},{d:.0}\n", .{ c.tag, get_n, opsPerSec(get_n, nowNs(io) - t0) });
                std.debug.print("{s}_get_hits,{d},{d}\n", .{ c.tag, get_n, hits });
            }
            // 不命中点查
            {
                const t0 = nowNs(io);
                var x: u64 = 1442695040888963407;
                var hits: u64 = 0;
                ci = 0;
                while (ci < get_n) : (ci += 1) {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    const kb = keyOf(@intCast(cn + (x % cn)));
                    if (try ct.get(&kb, &out) != null) hits += 1;
                }
                std.debug.print("{s}_miss,{d},{d:.0}\n", .{ c.tag, get_n, opsPerSec(get_n, nowNs(io) - t0) });
                std.debug.print("{s}_miss_hits,{d},{d}\n", .{ c.tag, get_n, hits });
            }
            // 范围扫描
            {
                var refs: std.ArrayList(spike.segment.Segment.RefRecord) = .empty;
                defer refs.deinit(alloc);
                const lo = keyOf(scan_lo);
                const hi = keyOf(scan_hi);
                const t0 = nowNs(io);
                try ct.scanRefs(&lo, &hi, &refs);
                std.debug.print("{s}_scan,{d},{d:.0}\n", .{ c.tag, refs.items.len, opsPerSec(@intCast(refs.items.len), nowNs(io) - t0) });
            }

            // 冷重开 + 重开后点查
            ct.deinit();
            ct_live = false;
            {
                const t0 = nowNs(io);
                var ct2 = try tablemod.Table.open(io, dir, cp, alloc, .{ .wal_sync_every = 10_000, .flush_bytes = c.fb });
                defer ct2.deinit();
                std.debug.print("{s}_recover,{d},{d:.2}\n", .{ c.tag, cn, @as(f64, @floatFromInt(nowNs(io) - t0)) / 1e6 });
                const t1 = nowNs(io);
                var x: u64 = 88172645463325252;
                var hits: u64 = 0;
                ci = 0;
                while (ci < get_n) : (ci += 1) {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    const kb = keyOf(@intCast(x % cn));
                    if (try ct2.get(&kb, &out) != null) hits += 1;
                }
                std.debug.print("{s}_get_after_reopen,{d},{d:.0}\n", .{ c.tag, get_n, opsPerSec(get_n, nowNs(io) - t1) });
                std.debug.print("{s}_get_after_reopen_hits,{d},{d}\n", .{ c.tag, get_n, hits });
            }
        }
    }

    // compaction 效果：25 段 → 1 段，量「合并耗时 vs 点查收益」
    {
        const kn: u64 = 2_000_000;
        const kp = "bench-data-compact";
        dir.deleteTree(io, kp) catch {};
        defer dir.deleteTree(io, kp) catch {};

        var kt = try tablemod.Table.open(io, dir, kp, alloc, .{ .wal_sync_every = 10_000, .flush_bytes = 8 << 20 });
        var kt_live = true;
        defer if (kt_live) kt.deinit();

        var ki: u64 = 0;
        while (ki < kn) : (ki += 1) {
            const kb = keyOf(@intCast(ki));
            try kt.put(&kb, &value);
        }
        try kt.flush();
        std.debug.print("cm_segs_before,{d},0\n", .{kt.segs.items.len});

        // 全表遍历（与 big_count 同口径：只计数、不收集）。
        // 与下面的 cm_count_after 配对，**同一张表、同一份数据，只差段数** ——
        // 这是量化「k 路归并代价」最干净的对照。
        {
            var hic: [16]u8 = @splat(0xFF);
            var itc = tablemod.MergeIter{};
            try itc.init(&kt, &.{}, &hic);
            defer itc.deinit();
            const t0 = nowNs(io);
            var cnt: u64 = 0;
            while (itc.next()) |_| {
                cnt += 1;
                if (cnt >= 500_000) break;
            }
            std.debug.print("cm_count_before,{d},{d:.0}\n", .{ cnt, opsPerSec(cnt, nowNs(io) - t0) });
            // 确定性观测：25 段到底建了几个游标、比了多少次。
            //
            // **别再用「每行 log2(k) 次比较」来推断归并开销** —— §16.1.21 的计数器已经把它
            // 证伪了：25 段顺序写入时 key 范围互不重叠，堆顶游标推进后仍是最小值，
            // `siftDown` 第一轮就 return，实测是每行 **2.0** 次比较（不是 4.6）。
            // 真正的每行成本是「2 次 keyCmp + 一次跨游标间接调用」。
            // §16.1.22 的顺序拼接把这些降到 0（compares 归零即证明快路径生效）。
            std.debug.print("cm_cursors_before,1,{d}\n", .{kt.merge_cursors_built});
            std.debug.print("cm_compares_before,{d},{d}\n", .{ cnt, itc.compares });
        }

        // **配对 A/B：顺序拼接 on vs off，同一进程、同一张表、背靠背交替。**
        //
        // 为什么必须有这一档：§16.1.22 原本用「本批 25 段 ÷ 本批 1 段」的比值去比
        // **上一批**的同一个比值，而这两个档在本机的批内波动就有 20–40%
        // （实测同一轮里 cm_count_before/cm_count_after 从 1.01 到 0.88 都出现过），
        // 跨批次比值差 14% 根本不可信。这里把「要不要拼接」做成同一进程内的开关，
        // 每轮背靠背跑两边，并奇偶轮交换先后顺序抵消「先跑的更冷/更热」的系统偏差。
        {
            var hic3: [16]u8 = @splat(0xFF);
            var round: usize = 0;
            while (round < 3) : (round += 1) {
                const order: [2]bool = if (round % 2 == 0) .{ true, false } else .{ false, true };
                for (order) |off| {
                    kt.opts.no_concat = off;
                    var it = tablemod.MergeIter{};
                    try it.init(&kt, &.{}, &hic3);
                    const t0 = nowNs(io);
                    var cnt: u64 = 0;
                    while (it.next()) |_| {
                        cnt += 1;
                        if (cnt >= 500_000) break;
                    }
                    const ns = nowNs(io) - t0;
                    const tag = if (off) "off" else "on";
                    std.debug.print("cm_ab_{s},{d},{d:.0}\n", .{ tag, cnt, opsPerSec(cnt, ns) });
                    std.debug.print("cm_ab_{s}_compares,{d},{d}\n", .{ tag, cnt, it.compares });
                    it.deinit();
                }
            }
            kt.opts.no_concat = false;
        }

        // **反向段裁剪 A/B（§16.1.23）**：范围落在表中段时，起点之前的整段可以整段跳过。
        //
        // 每侧都**先关表再重开**，保证两边同样冷（`cursor()` 里每段要 `ensureParsed`
        // 做整段 CRC + `dataView` 建 mmap，热态下测不出这笔开销）。
        // 计时只包住 `MergeIter` 的扫描，不含 `Table.open` —— 要量的是「查询前的段准备」。
        {
            const rstart = keyOf(1_000_000);
            const rend = keyOf(1_001_000);
            var round: usize = 0;
            while (round < 3) : (round += 1) {
                const order: [2]bool = if (round % 2 == 0) .{ true, false } else .{ false, true };
                for (order) |off| {
                    if (kt_live) {
                        kt.deinit();
                        kt_live = false;
                    }
                    kt = try tablemod.Table.open(io, dir, kp, alloc, .{
                        .wal_sync_every = 10_000,
                        .flush_bytes = 8 << 20,
                        .no_prune_before = off,
                    });
                    kt_live = true;

                    var it = tablemod.MergeIter{};
                    try it.init(&kt, &rstart, &rend);
                    const t0 = nowNs(io);
                    var cnt: u64 = 0;
                    while (it.next()) |_| cnt += 1;
                    const ns = nowNs(io) - t0;
                    const tag = if (off) "off" else "on";
                    std.debug.print("prune_range_{s},{d},{d:.0}\n", .{ tag, cnt, opsPerSec(cnt, ns) });
                    // 确定性凭据：剪了几段 / 建了几个游标 / 实际读了几条记录
                    std.debug.print("prune_pruned_{s},1,{d}\n", .{ tag, kt.merge_pruned_before });
                    std.debug.print("prune_cursors_{s},1,{d}\n", .{ tag, kt.merge_cursors_built });
                    std.debug.print("prune_rowsread_{s},1,{d}\n", .{ tag, kt.scan_rows_read });
                    it.deinit();
                }
            }
            // 复原成后续档位期望的状态
            if (kt_live) {
                kt.deinit();
                kt_live = false;
            }
            kt = try tablemod.Table.open(io, dir, kp, alloc, .{ .wal_sync_every = 10_000, .flush_bytes = 8 << 20 });
            kt_live = true;
        }

        // 合并前点查
        {
            const t0 = nowNs(io);
            var x: u64 = 88172645463325252;
            var hits: u64 = 0;
            ki = 0;
            while (ki < get_n) : (ki += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(x % kn));
                if (try kt.get(&kb, &out) != null) hits += 1;
            }
            std.debug.print("cm_get_before,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, nowNs(io) - t0) });
            std.debug.print("cm_get_before_hits,{d},{d}\n", .{ get_n, hits });
        }

        // 合并
        {
            const tcm = nowNs(io);
            const cr = try kt.compact();
            const cmns = nowNs(io) - tcm;
            std.debug.print("cm_ms,{d},{d:.2}\n", .{ cr.rows, @as(f64, @floatFromInt(cmns)) / 1e6 });
            std.debug.print("cm_segs_after,{d},0\n", .{cr.after});
            // 注意：这里**不要**算写放大。`kt` 在本轮的反向裁剪 A/B 里被重开过，
            // `flush_bytes_total` 已经从 0 重新开始，拿它当分母得到的是个假的巨大值
            // （第一次就是这么错的：分母被 `@max(1, …)` 兜成 1）。
            // 写放大的可信口径在 §16.1.7（按 `compact_after_segs` 阈值 4/8/16 实测）。
        }

        // 合并成单段后再遍历一次（与 cm_count_before 完全同口径）
        {
            var hic2: [16]u8 = @splat(0xFF);
            var itc2 = tablemod.MergeIter{};
            try itc2.init(&kt, &.{}, &hic2);
            defer itc2.deinit();
            const t0 = nowNs(io);
            var cnt: u64 = 0;
            while (itc2.next()) |_| {
                cnt += 1;
                if (cnt >= 500_000) break;
            }
            std.debug.print("cm_count_after,{d},{d:.0}\n", .{ cnt, opsPerSec(cnt, nowNs(io) - t0) });
            // 与 cm_cursors_before / cm_compares_before 配对：段数从 25 降到 1 后，
            // 游标数应为 1、比较次数应为 0（单游标快路径根本不比较）——
            // 两个指标一起才能证明「归并代价的来源确实是 k 路选择」。
            std.debug.print("cm_cursors_after,1,{d}\n", .{kt.merge_cursors_built});
            std.debug.print("cm_compares_after,{d},{d}\n", .{ cnt, itc2.compares });
        }

        // 合并后点查
        {
            const t0 = nowNs(io);
            var x: u64 = 88172645463325252;
            var hits: u64 = 0;
            ki = 0;
            while (ki < get_n) : (ki += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(x % kn));
                if (try kt.get(&kb, &out) != null) hits += 1;
            }
            std.debug.print("cm_get_after,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, nowNs(io) - t0) });
            std.debug.print("cm_get_after_hits,{d},{d}\n", .{ get_n, hits });
        }
        // 合并后不命中点查
        {
            const t0 = nowNs(io);
            var x: u64 = 1442695040888963407;
            var hits: u64 = 0;
            ki = 0;
            while (ki < get_n) : (ki += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(kn + (x % kn)));
                if (try kt.get(&kb, &out) != null) hits += 1;
            }
            std.debug.print("cm_miss_after,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, nowNs(io) - t0) });
            std.debug.print("cm_miss_after_hits,{d},{d}\n", .{ get_n, hits });
        }

        // 合并后重开
        kt.deinit();
        kt_live = false;
        {
            const t0 = nowNs(io);
            var kt2 = try tablemod.Table.open(io, dir, kp, alloc, .{ .wal_sync_every = 10_000, .flush_bytes = 8 << 20 });
            defer kt2.deinit();
            std.debug.print("cm_recover,{d},{d:.2}\n", .{ kn, @as(f64, @floatFromInt(nowNs(io) - t0)) / 1e6 });
        }
    }
    // 自动 compaction 的基准已移到独立入口：zig build run-bench-ac（src/bench_ac.zig）。
    // 放在整套 bench 末尾时，前面 big_* 留下的脏页与页缓存让同配置波动达 84%~435%，
    // 中位数不可信；独立进程从干净状态起跑才测得准。

    std.debug.print("bench_done,1,1\n", .{});
    out.deinit(alloc);
    // threaded.deinit() 会让进程收尾更慢，基准进程直接靠 OS 回收；这里保留但注释说明
    // threaded.deinit();
}

const ConcArgs = struct {
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    n: u64,
    done: *u64,
    failed: *bool,
};

fn concWriter(a: ConcArgs) void {
    const alloc = std.heap.smp_allocator;
    var t = tablemod.Table.open(a.io, a.dir, a.path, alloc, .{ .wal_sync_every = 10_000 }) catch {
        a.failed.* = true;
        return;
    };
    defer t.deinit();

    const value: [32]u8 = @splat('x');
    var i: u64 = 0;
    while (i < a.n) : (i += 1) {
        const kb = keyOf(@intCast(i));
        t.put(&kb, &value) catch {
            a.failed.* = true;
            break;
        };
        a.done.* = i + 1;
    }
    t.wal.sync() catch {
        a.failed.* = true;
    };
}


