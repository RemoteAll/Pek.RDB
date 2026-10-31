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

    var t = try tablemod.Table.open(io, dir, path, alloc, .{ .wal_sync_every = 10_000 });
    defer t.deinit();

    {
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const kb = keyOf(@intCast(i));
            try t.put(&kb, &value);
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
}
