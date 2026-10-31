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
        var rows: std.ArrayList(spike.segment.RecordOwned) = .empty;
        defer tablemod.freeRecords(alloc, &rows);
        const lo = keyOf(scan_lo);
        const hi = keyOf(scan_hi);
        const t0 = nowNs(io);
        try t.scanRange(&lo, &hi, &rows);
        const ns = nowNs(io) - t0;
        std.debug.print("scan,{d},{d:.0}\n", .{ rows.items.len, opsPerSec(@intCast(rows.items.len), ns) });
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
        }
        const ns_put = nowNs(io) - t_sql_put;
        std.debug.print("sql_put,{d},{d:.0}\n", .{ n, opsPerSec(n, ns_put) });

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
}

