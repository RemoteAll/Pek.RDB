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

    // 零拷贝扫描（mmap + 单段快路径）
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

        // 诊断：索引聚合文件大小（现在全部段索引在 seg/index.bin 里）
        {
            const ip = try alloc.print("{s}/seg/index.bin", .{path6});
            defer alloc.free(ip);
            const f = try dir.openFile(io, ip, .{});
            defer f.close(io);
            std.debug.print("big_idx_bytes,1,{d}\n", .{(try f.stat(io)).size});
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


