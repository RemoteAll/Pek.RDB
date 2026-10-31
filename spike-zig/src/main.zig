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

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
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
    defer out.deinit(alloc);

    std.debug.print("metric,count,value\n", .{});

    var t = try tablemod.Table.open(io, dir, path, alloc, .{ .wal_sync_every = 10_000, .flush_bytes = 1 << 30 });
    defer t.deinit();

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

    {
        const t0 = nowNs(io);
        var t2 = try tablemod.Table.open(io, dir, path, alloc, .{ .wal_sync_every = 10_000 });
        const ns = nowNs(io) - t0;
        defer t2.deinit();
        std.debug.print("recover,{d},{d:.0}\n", .{ n, @as(f64, @floatFromInt(ns)) / 1e6 });
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
        defer t6.deinit();

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

        // 冷重开
        {
            t6.deinit();
            const t0 = nowNs(io);
            var t7 = try tablemod.Table.open(io, dir, path6, alloc, .{
                .wal_sync_every = 10_000,
                .flush_bytes = 8 << 20,
            });
            const ns = nowNs(io) - t0;
            defer t7.deinit();
            std.debug.print("big_recover,{d},{d:.0}\n", .{ big_n, @as(f64, @floatFromInt(ns)) / 1e6 });
        }
    }
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


