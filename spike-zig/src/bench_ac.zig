// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
//
// 自动 compaction 专项基准：**只跑这一个场景**。
//
// 为什么不放在整套 bench 里：整套跑会先产生 big_* 的几百万行，脏页与页缓存
// 全被占满，接着测 ac 段时同配置三轮波动实测达 84%（写入耗时）与 435%（阈值 16），
// 中位数不可信。独立进程从干净状态起跑，波动降到可接受范围。
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

const ROWS: u64 = 500_000;
/// 2MB → 约 25 段（4MB 时只有 13 段，阈值 16 压根不触发，等于没测）
const FLUSH_BYTES: usize = 2 << 20;
const GET_N: u64 = 100_000;

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const value: [32]u8 = @splat('x');

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    std.debug.print("metric,count,value\n", .{});

    // 主场景：50 万行 / 2MB flush → 约 25 段
    try runCase(io, dir, alloc, &out, "off", 0, 0, 1, ROWS, FLUSH_BYTES, value);
    // 阈值三档（全量合并）
    for ([_]usize{ 4, 8, 16 }) |th| {
        var tag_buf: [16]u8 = undefined;
        const tag = try std.fmt.bufPrint(&tag_buf, "on{d}", .{th});
        try runCase(io, dir, alloc, &out, tag, th, 0, 1, ROWS, FLUSH_BYTES, value);
    }
    // **分层合并（生产推荐路径：compact_max_segs 优先，`compact_after_segs` 不管用）**。
    // 两档段数上限：12（均衡）与 6（写少读多）；12 档再对比 burst=1 / burst=4。
    for ([_]usize{ 12, 6 }) |ms| {
        var tag_buf: [16]u8 = undefined;
        const tag = try std.fmt.bufPrint(&tag_buf, "tier{d}", .{ms});
        try runCase(io, dir, alloc, &out, tag, 0, ms, 1, ROWS, FLUSH_BYTES, value);
    }
    try runCase(io, dir, alloc, &out, "tier12b4", 0, 12, 4, ROWS, FLUSH_BYTES, value);

    // 数据量 ×4（同样约 25 段）：验证全量合并的两个关键局限——
    //   ① 写放大的**绝对值**随总数据量增长（比例取决于阈值，与总量无关）
    //   ② 单次合并的**阻塞时长**随总数据量线性增长（超大数据集不可接受）
    const big_rows: u64 = 2_000_000;
    const big_fb: usize = 8 << 20; // 同样 → 约 25 段
    try runCase(io, dir, alloc, &out, "big_off", 0, 0, 1, big_rows, big_fb, value);
    try runCase(io, dir, alloc, &out, "big_on8", 8, 0, 1, big_rows, big_fb, value);
    try runCase(io, dir, alloc, &out, "big_tier12", 0, 12, 1, big_rows, big_fb, value);
    std.debug.print("ac_bench_done,1,1\n", .{});
}

fn runCase(
    io: std.Io,
    dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: []const u8,
    thresh: usize,
    max_segs: usize,
    burst: usize,
    rows: u64,
    flush_bytes: usize,
    value: [32]u8,
) !void {
    const p = try std.fmt.allocPrint(alloc, "ac-data-{s}", .{tag});
    defer alloc.free(p);
    dir.deleteTree(io, p) catch {};
    defer dir.deleteTree(io, p) catch {};

    const opts: tablemod.Options = .{
        .wal_sync_every = 10_000,
        .flush_bytes = flush_bytes,
        .compact_after_segs = thresh,
        .compact_max_segs = max_segs,
        .auto_compact_burst = burst,
    };

    var t = try tablemod.Table.open(io, dir, p, alloc, opts);
    var live = true;
    defer if (live) t.deinit();

    // 写入（含自动合并）
    const t0 = nowNs(io);
    var i: u64 = 0;
    while (i < rows) : (i += 1) {
        const k = keyOf(@intCast(i));
        try t.put(&k, &value);
    }
    try t.flush();
    const ns = nowNs(io) - t0;

    std.debug.print("ac_put_{s},{d},{d:.0}\n", .{ tag, rows, opsPerSec(rows, ns) });
    std.debug.print("ac_ms_{s},{d},{d:.2}\n", .{ tag, rows, @as(f64, @floatFromInt(ns)) / 1e6 });
    std.debug.print("ac_segs_{s},{d},0\n", .{ tag, t.segs.items.len });
    std.debug.print("ac_compacts_{s},{d},0\n", .{ tag, t.auto_compact_count });
    std.debug.print("ac_err_{s},{d},0\n", .{ tag, @as(u64, if (t.auto_compact_error == null) 0 else 1) });
    // 写放大（确定性指标）：总写入字节 / 用户数据字节。
    // 不依赖计时，不受磁盘/CPU 噪声影响，是这组实验真正可靠的核心数据。
    {
        const user_bytes = t.flush_bytes_total;
        const total_bytes = user_bytes + t.compact_bytes_total;
        const wamp: f64 = @as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(user_bytes));
        std.debug.print("ac_userbytes_{s},{d},0\n", .{ tag, user_bytes });
        std.debug.print("ac_cmpbytes_{s},{d},0\n", .{ tag, t.compact_bytes_total });
        std.debug.print("ac_wamp_{s},{d},{d:.3}\n", .{ tag, rows, wamp });
    }

    // 命中点查
    {
        const h0 = nowNs(io);
        var x: u64 = 88172645463325252;
        var hits: u64 = 0;
        i = 0;
        while (i < GET_N) : (i += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            const k = keyOf(@intCast(x % rows));
            if (try t.get(&k, out) != null) hits += 1;
        }
        std.debug.print("ac_get_{s},{d},{d:.0}\n", .{ tag, GET_N, opsPerSec(GET_N, nowNs(io) - h0) });
        std.debug.print("ac_get_{s}_hits,{d},{d}\n", .{ tag, GET_N, hits });
    }
    // 不命中点查
    {
        const h0 = nowNs(io);
        var x: u64 = 1442695040888963407;
        var hits: u64 = 0;
        i = 0;
        while (i < GET_N) : (i += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            const k = keyOf(@intCast(rows + (x % rows)));
            if (try t.get(&k, out) != null) hits += 1;
        }
        std.debug.print("ac_miss_{s},{d},{d:.0}\n", .{ tag, GET_N, opsPerSec(GET_N, nowNs(io) - h0) });
        std.debug.print("ac_miss_{s}_hits,{d},{d}\n", .{ tag, GET_N, hits });
    }

    // 冷重开
    t.deinit();
    live = false;
    {
        const r0 = nowNs(io);
        var t2 = try tablemod.Table.open(io, dir, p, alloc, opts);
        defer t2.deinit();
        std.debug.print("ac_recover_{s},{d},{d:.2}\n", .{ tag, rows, @as(f64, @floatFromInt(nowNs(io) - r0)) / 1e6 });
    }

    // **单次合并阻塞时长**（本轮新增的唯一目的）：判定「要不要把合并挪到后台线程」。
    // 写放大（`ac_wamp_*`）与阻塞时长无关：写放大 5 倍也可能是每次只卡 3ms，
    // 写放大 2 倍也可能每次卡 1s。只有这里量到的数才是「写路径被独占多久」。
    {
        const n = @max(@as(u64, 1), t.compact_calls);
        const avg_ms = @as(f64, @floatFromInt(t.ns_compact)) / @as(f64, @floatFromInt(n)) / 1e6;
        const max_ms = @as(f64, @floatFromInt(t.ns_compact_max)) / 1e6;
        std.debug.print("ac_cmp_calls_{s},{d},{d}\n", .{ tag, rows, t.compact_calls });
        std.debug.print("ac_cmp_ms_avg_{s},{d},{d:.3}\n", .{ tag, rows, avg_ms });
        std.debug.print("ac_cmp_ms_max_{s},{d},{d:.3}\n", .{ tag, rows, max_ms });
        // 每次合并平均重写多少字节（与耗时一起看才能区分「合并大」还是「磁盘慢」）
        const per = if (t.compact_calls == 0) 0.0 else @as(f64, @floatFromInt(t.compact_bytes_total)) / @as(f64, @floatFromInt(t.compact_calls));
        std.debug.print("ac_cmp_bytes_per_{s},{d},{d:.0}\n", .{ tag, rows, per });
        // **一次写的最坏停顿**：`flush()` 内部末尾会跑自动合并，所以 `ns_flush_max`
        // 就是「写路径被独占多久」的真实上界。`ac_cmp_ms_max_*` 只是**单轮合并**的耗时，
        // burst>1 时一次写可以叠好几轮 —— 只有这个指标能体现出 burst 的差别。
        std.debug.print("ac_flush_ms_max_{s},{d},{d:.3}\n", .{ tag, rows, @as(f64, @floatFromInt(t.ns_flush_max)) / 1e6 });
        std.debug.print("ac_flush_calls_{s},{d},{d}\n", .{ tag, rows, t.flush_calls });
    }
}
