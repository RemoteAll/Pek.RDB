// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const spike = @import("pek_rdb_spike");
const build_options = @import("build_options");
const codec = spike.codec;
const tablemod = spike.table;

fn opsPerSec(count: u64, ns: u64) f64 {
    return @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(ns)) / 1e9);
}

fn nowNs(io: std.Io) u64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(ts.nanoseconds);
}

/// **裸文件写探针**：完全不经过引擎，只做「建文件 → 分块写 → 每块 fsync」。
///
/// 存在的理由：审计发现同一份配置、同一数据量的 `big_put` 与 `b8_put` 在同一轮里能差 4×
/// （p11 r2：503,836 vs 2,033,491），而读指标完全正常。这可能是「我们的写路径暴露」，
/// 也可能是「这台机器在某个时间窗口里写盘就是慢」。两种情况对策完全不同：
/// - 裸写也掉 → 环境（NTFS/Defender/写回），优化我们的代码没用，只能多轮取中位或加窗口检测；
/// - 裸写不掉 → 确实是我们的写路径，继续往文件数/fsync 次数上查。
/// 所以把干净变量（同进程、同一时刻、只差「有没有引擎」）放进基准里。
fn bareWriteMbPerSec(io: std.Io, dir: std.Io.Dir, path: []const u8, mb: usize) f64 {
    const chunk = 8 << 20;
    var buf: [8 << 20]u8 = undefined;
    @memset(&buf, 'b');
    dir.deleteFile(io, path) catch {};
    const t0 = nowNs(io);
    const f = dir.createFile(io, path, .{ .read = false, .truncate = true }) catch return 0;
    defer f.close(io);
    defer dir.deleteFile(io, path) catch {};
    var off: u64 = 0;
    var i: usize = 0;
    while (i < mb) : (i += 8) {
        f.writePositionalAll(io, &buf, off) catch return 0;
        f.sync(io) catch return 0;
        off += chunk;
    }
    const ns = nowNs(io) - t0;
    if (ns == 0) return 0;
    return @as(f64, @floatFromInt(mb)) / (@as(f64, @floatFromInt(ns)) / 1e9);
}

/// 时间轴标记：打印「距进程启动多少秒」。
///
/// 为什么需要：写抖动分两类，其中 A 类（裸写也崩、环境级）没法靠代码解决，
/// 但**能不能规避**取决于它出现得规律不规律 —— 固定时刻（比如每 N 秒一次的写回周期）
/// 可以靠调整基准节奏避开；随机时刻就只能靠多轮 + 好坏窗口分离。
/// 没有时间轴就没法区分这两者，只能拍脑袋。
fn benchMark(io: std.Io, t0: u64, name: []const u8) void {
    const ns = nowNs(io) - t0;
    std.debug.print("t_sec,{s},{d:.2}\n", .{ name, @as(f64, @floatFromInt(ns)) / 1e9 });
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

/// 批量写的公共口径（`flush_bytes` 可调），用于「段 fsync 次数 vs 吞吐/尾部」的敏感度实验。
///
/// 背景（`docs/审计-2026-11-01-第八轮.md`）：段写耗时里 **fsync 占 ~60%**
/// （235–288ms / 394–453ms，200 万行 / 25 次 flush），而 `flush_calls` 与 `flush_bytes`
/// 近似成反比 —— 8MB→25 次、32MB→约 7 次、64MB→约 4 次。
/// 如果尾部崩塌与 fsync **次数**有关，那么同样 200 万行、同样总量的写入，
/// 更大 `flush_bytes` 应当更稳。这是「实测」而不是「按直觉调参」。
const BulkResult = struct {
    ops: f64,
    flushes: u64,
    ns_flush: u64,
    ns_seg_sync: u64,
};

fn bulkWrite(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    alloc: std.mem.Allocator,
    value: []const u8,
    n: u64,
    flush_bytes: usize,
) !BulkResult {
    dir.deleteTree(io, path) catch {};
    defer dir.deleteTree(io, path) catch {};
    var t = try tablemod.Table.open(io, dir, path, alloc, .{
        .wal_sync_every = 0,
        .flush_bytes = flush_bytes,
    });
    defer t.deinit();
    const t0 = nowNs(io);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const kb = keyOf(@intCast(i));
        try t.put(&kb, value);
    }
    try t.flush();
    return .{
        .ops = opsPerSec(n, nowNs(io) - t0),
        .flushes = t.flush_calls,
        .ns_flush = t.ns_flush,
        .ns_seg_sync = t.ns_seg_sync,
    };
}

/// **只给基准用**：旧版定长行头（`klen4+vlen4+seq8+flags1 = 17 B`）的解析。
///
/// 存在的唯一目的是和 `codec.readRec`（varint 头，6 B）做**同进程、背靠背**的配对对比 ——
/// 跨批次比扫描吞吐在这台机器上一点都不可信（批内波动 20–40%）。
/// 生产代码里不再有这条路径，别拿它当参考实现。
///
/// 返回值形状与 `codec.readRec` 一致（key/value 都借用 `buf`），保证两边做的工作相同。
fn readRecLegacy(buf: []const u8, pos: usize) ?codec.RecView {
    if (pos + 17 > buf.len) return null;
    const klen: usize = @intCast(std.mem.readInt(u32, buf[pos..][0..4], .little));
    const vlen: usize = @intCast(std.mem.readInt(u32, buf[pos + 4 ..][0..4], .little));
    const total = 17 + klen + vlen;
    if (pos + total > buf.len) return null;
    const flags = buf[pos + 16];
    const seq = std.mem.readInt(u64, buf[pos + 8 ..][0..8], .little);
    return .{
        .key = buf[pos + 17 ..][0..klen],
        .value = buf[pos + 17 + klen ..][0..vlen],
        .seq = seq,
        .flags = flags,
        .klen = klen,
        .next = pos + total,
    };
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

    // **lite 模式**（编译期 `-Dlite=true`）：跳过重型诊断探针，只跑与 SQLite 对比的那些指标。
    //
    // 为什么需要：加上 `big_put_strong` / `fb32` / `fb64` / `walab` 这四组之后，一次跑的写入量
    // 从约 1.0GB 涨到约 2.5GB —— **这本身就把机器写到饱和，是 A 类写抖动的触发源之一**。
    // 官方对比用 lite（每轮 ~1.0GB），重型探针用单独批次跑，不要混在一起。
    const lite = build_options.lite;

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
    const t_bench = nowNs(io);

    // 裸文件写探针：基准的**起点**。与后面两个点对比就能看出「是否某个时间窗口写盘变慢」。
    std.debug.print("bare_write_mbps,{d},{d:.1}\n", .{ 64, bareWriteMbPerSec(io, dir, "bench-bare-1.tmp", 64) });

    var t = try tablemod.Table.open(io, dir, path, alloc, .{ .wal_sync_every = 0, .flush_bytes = 1 << 30 });
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
        benchMark(io, t_bench, "after_put");
    }

    {
        const t0 = nowNs(io);
        try t.flush();
        const ns = nowNs(io) - t0;
        std.debug.print("flush,{d},{d:.0}\n", .{ n, opsPerSec(n, ns) });
    }

    // 同持久化档位对照：`wal_buf_bytes = 0` → 每行立即 `write` 到 OS（不 fsync），
    // 与 SQLite `synchronous=NORMAL`「每笔提交都 pwrite 到 WAL 文件、不 fsync」**完全对等**。
    //
    // 为什么必须单独测这一档：默认 256 KB 缓冲档比它**弱** —— 进程被强杀时会丢缓冲里
    // 已返回成功的写（SQLite 那一档一条不丢）。所以对外报 `put` 的 51.7× 时，
    // 必须同时给出这一档的数字，否则等于拿「更弱的持久化」换吞吐。
    {
        const path_sync = "bench-data-walsync";
        dir.deleteTree(io, path_sync) catch {};
        var ts = try tablemod.Table.open(io, dir, path_sync, alloc, .{ .wal_sync_every = 0, .wal_buf_bytes = 0 });
        defer {
            ts.deinit();
            dir.deleteTree(io, path_sync) catch {};
        }

        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const kb = keyOf(@intCast(i));
            try ts.put(&kb, &value);
        }
        try ts.wal.sync();
        const ns = nowNs(io) - t0;
        std.debug.print("put_sync,{d},{d:.0}\n", .{ n, opsPerSec(n, ns) });
        // 同档位对照必须给出**两边各自的每行字节量**，否则「快 10 倍」会被误解成
        // 「引擎更强」。SQLite 的 WAL 是页粒度：每次提交要把整页（默认 4096B）写进 WAL。
        // 这个计数器就是 `Wal.written`（本表累计写入 WAL 的逻辑字节数），可逐字节核对。
        std.debug.print("put_sync_wal_bytes,{d},{d}\n", .{ n, ts.wal.total_written });
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
        // 同口径（一次提交 N 行）下两边的每行字节量 —— 与 SQLite `put_txn` 对照。
        std.debug.print("put_batch_wal_bytes,{d},{d}\n", .{ n, t3.wal.total_written });
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

    // 同口径对照（1 万行区间「只数行」）：对应 SQLite 的 `SELECT id ... while rows.next()`。
    // 上面 `scan` 是 `scanRange`，会把 key+value 物化进缓冲；SQLite 那档一条都不取。
    // 两个数字放在一起才看得出「物化」本身要多少钱，也才有公平的参照。
    {
        const lo = keyOf(scan_lo);
        const hi = keyOf(scan_hi);
        var it = tablemod.MergeIter{};
        try it.init(&t, &lo, &hi);
        defer it.deinit();
        const t0 = nowNs(io);
        var cnt: u64 = 0;
        while (it.next()) |_| cnt += 1;
        const ns = nowNs(io) - t0;
        std.debug.print("count_10k,{d},{d:.0}\n", .{ cnt, opsPerSec(cnt, ns) });
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
        var t5 = try tablemod.Table.open(io, dir, path5, alloc, .{ .wal_sync_every = 0 });
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
        var t8 = try tablemod.Table.open(io, dir, path8, alloc, .{ .wal_sync_every = 0 });
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
        var t2 = try tablemod.Table.open(io, dir, path, alloc, .{ .wal_sync_every = 0 });
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
        var t4 = try tablemod.Table.open(io, dir, path4, alloc, .{ .wal_sync_every = 0 });
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
        benchMark(io, t_bench, "after_sql_put");
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
        benchMark(io, t_bench, "after_conc");
    }

    // 超内存数据集：小 memtable → 大量段，考察多段 k 路归并的点查/扫描
    {
        const path6 = "bench-data-big";
        dir.deleteTree(io, path6) catch {};
        defer dir.deleteTree(io, path6) catch {};

        const big_n: u64 = 2_000_000;
        var t6 = try tablemod.Table.open(io, dir, path6, alloc, .{
            .wal_sync_every = 0,
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
        // 写路径分解：总耗时里 fsync 占多少、段 flush 占多少、单次 flush 最长多少。
        // 判定偶发崩塌是「周期 fsync 抖动」还是「段落盘抖动」的直接证据。
        std.debug.print("big_put_breakdown,{d},{d}\n", .{ t6.ns_wal_sync, t6.ns_flush });
        std.debug.print("big_put_flushmax,{d},{d}\n", .{ t6.flush_calls, t6.ns_flush_max });
        // 段 flush 内部三段分解：段数据写入+fsync / 索引归档追加+fsync / WAL 轮换。
        // 三段相加接近 `ns_flush` 才算拆全；剩下的差额是 Segment.fromBytes 的 mmap 等。
        std.debug.print("big_put_phases,{d},{d}\n", .{ t6.ns_seg_data, t6.ns_idx });
        std.debug.print("big_put_phases2,{d},{d}\n", .{ t6.ns_walrot, t6.ns_walrot_max });
        // 裸文件写探针：**紧接着 big_put**（同一时刻，只差「不经引擎」）
        std.debug.print("bare_write2_mbps,{d},{d:.1}\n", .{ 64, bareWriteMbPerSec(io, dir, "bench-bare-2.tmp", 64) });
        // 段数据三段拆分：建文件 / 写块 / fsync
        std.debug.print("big_put_segphase,{d},{d}\n", .{ t6.ns_seg_create, t6.ns_seg_write });
        std.debug.print("big_put_segphase2,{d},{d}\n", .{ t6.ns_seg_sync, t6.ns_seg_data });

        // **`flush_bytes` 敏感度实验**：同样 200 万行 / 同一时间窗口，只改段大小。
        // 8MB（`big_put`）→ 约 25 次 flush；32MB/64MB → 约 7/4 次。
        // 判据看两点：① 吞吐是否更高（fsync 次数少）；② **同轮内**是否比 `big_put` 更稳。
        // 注意：结论是「**不是解药**」（见决策记录七十三），保留只为重评估；lite 模式跳过。
        if (!lite) {
            const r32 = try bulkWrite(io, dir, "bench-data-fb32", alloc, &value, big_n, 32 << 20);
            std.debug.print("big_put_fb32,{d},{d:.0}\n", .{ big_n, r32.ops });
            std.debug.print("big_put_fb32_flushes,{d},{d}\n", .{ r32.flushes, r32.ns_seg_sync });
            const r64 = try bulkWrite(io, dir, "bench-data-fb64", alloc, &value, big_n, 64 << 20);
            std.debug.print("big_put_fb64,{d},{d:.0}\n", .{ big_n, r64.ops });
            std.debug.print("big_put_fb64_flushes,{d},{d}\n", .{ r64.flushes, r64.ns_seg_sync });
        }
        benchMark(io, t_bench, "after_big_put");

        // **强耐久档参考**：`wal_sync_every = 10_000` = 每 1 万条 put 做一次 WAL fsync。
        //
        // 基准口径为什么用 `wal_sync_every = 0`（见上）：SQLite 侧是 `synchronous=NORMAL`，
        // WAL 模式下**提交根本不 fsync**（只在 checkpoint 刷盘）。拿每 200 万行 200 次
        // WAL fsync + 25 次段 fsync 去比它的零 fsync，是我方自己加了两百多次 fsync 再比，
        // 实测代价约 +16% 吞吐且尾部抖动放大到 3.3–9.2 倍 —— 那 6 项「判不出来」的来源。
        //
        // 对等口径下（p8 批 7 轮交替配对）`big_put` vs SQLite `big_put_txn` **7/7 全胜**，
        // 中位 1,421,424 vs 612,163 = 2.32×，波动 1.56× 反而小于 SQLite 的 3.97×。
        // 这一行留作「开强耐久要付多少」的证据，不参与 vs-SQLite 判定。
        if (!lite) {
            const path_strong = "bench-data-bigstrong";
            dir.deleteTree(io, path_strong) catch {};
            defer dir.deleteTree(io, path_strong) catch {};
            var ts = try tablemod.Table.open(io, dir, path_strong, alloc, .{
                .wal_sync_every = 10_000,
                .flush_bytes = 8 << 20,
            });
            defer ts.deinit();
            const t0 = nowNs(io);
            var j: u64 = 0;
            while (j < big_n) : (j += 1) {
                const kb = keyOf(@intCast(j));
                try ts.put(&kb, &value);
            }
            try ts.flush();
            const ns = nowNs(io) - t0;
            std.debug.print("big_put_strong,{d},{d:.0}\n", .{ big_n, opsPerSec(big_n, ns) });
            std.debug.print("big_put_strong_breakdown,{d},{d}\n", .{ ts.ns_wal_sync, ts.ns_flush });
        }

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

        // 同口径对照（1 万行区间「只数行」）：对应 SQLite 的 `big_scan`。
        // 上面 `big_scan_refs` 是收集 RefRecord，两件事不同；这一档两边都只数行。
        {
            const lo8 = keyOf(scan_lo);
            const hi8 = keyOf(scan_hi);
            var it8 = tablemod.MergeIter{};
            try it8.init(&t6, &lo8, &hi8);
            defer it8.deinit();
            const t0 = nowNs(io);
            var cnt8: u64 = 0;
            while (it8.next()) |_| cnt8 += 1;
            const ns = nowNs(io) - t0;
            std.debug.print("big_count_10k,{d},{d:.0}\n", .{ cnt8, opsPerSec(cnt8, ns) });
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
            // 必须打小数：整数除法把 40.92 截成 40、把 SQLite 的 41.56 截成 41，
            // 两边各自向下取整，但余额不同，等于我们自己多让了 0.9 B/行（对自己有利的偏差也要修）。
            std.debug.print("big_disk_bytes_row,1,{d:.3}\n", .{@as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(big_n))});
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
                .wal_sync_every = 0,
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
                .wal_sync_every = 0,
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
            .wal_sync_every = 0,
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
        benchMark(io, t_bench, "after_b8_put");
        // 裸文件写探针：**紧接着 b8_put**（同配置的第二次 200 万行写完之后）
        std.debug.print("bare_write3_mbps,{d},{d:.1}\n", .{ 64, bareWriteMbPerSec(io, dir, "bench-bare-3.tmp", 64) });

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
                .wal_sync_every = 0,
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

        var tu = try tablemod.Table.open(io, dir, path8, alloc, .{ .wal_sync_every = 0, .flush_bytes = 1 << 30 });
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

    // DELETE：100 万行已落段的表上，按主键删 10 万行。
    //
    // 口径（与 SQLite `del_100k` 完全一致，逐条对齐）：
    // - 同一个 xorshift64 随机序列（种子 88172645463325252）、同样取 `x % n`；
    // - **一次提交**：我方循环里只 append 到 WAL，循环结束后统一 flush + sync；
    //   SQLite 侧是 BEGIN … COMMIT；
    // - 同时报 **每行写入 WAL 的字节数**（`del_wal_bytes`）——
    //   删除的写放大和插入不同（我方删除记录只带 key，SQLite 仍按页写），
    //   不报字节量就又变成第七十九节那个坑。
    // - 正确性用两条确定性计数守住：删完点查必须 0 命中，剩余行数必须 = n - get_n。
    {
        const path_del = "bench-data-del";
        dir.deleteTree(io, path_del) catch {};
        defer dir.deleteTree(io, path_del) catch {};

        var td = try tablemod.Table.open(io, dir, path_del, alloc, .{ .wal_sync_every = 0, .flush_bytes = 1 << 30 });
        defer td.deinit();

        var di: u64 = 0;
        while (di < n) : (di += 1) {
            const kb = keyOf(@intCast(di));
            try td.put(&kb, &value);
        }
        // 先全部落段，让删除阶段只反映删除本身
        try td.flush();

        const wal_before = td.wal.total_written;
        {
            const t0 = nowNs(io);
            var x: u64 = 88172645463325252;
            di = 0;
            while (di < get_n) : (di += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(x % n));
                try td.delete(&kb);
            }
            // 一次提交：落段 + 清 WAL + fsync
            try td.flush();
            const ns = nowNs(io) - t0;
            std.debug.print("del_100k,{d},{d:.0}\n", .{ get_n, opsPerSec(get_n, ns) });
        }
        std.debug.print("del_wal_bytes,{d},{d}\n", .{ get_n, td.wal.total_written - wal_before });

        // 正确性：被删的 key 必须全部查不到
        {
            var x: u64 = 88172645463325252;
            var hits: u64 = 0;
            di = 0;
            while (di < get_n) : (di += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const kb = keyOf(@intCast(x % n));
                if (try td.get(&kb, &out) != null) hits += 1;
            }
            std.debug.print("del_deleted_hits,{d},{d}\n", .{ get_n, hits });
        }
        // 正确性：剩余行数必须正好是 n - get_n（扫描全表数一遍）
        {
            var hi_d: [16]u8 = @splat(0xFF);
            var it_d = tablemod.MergeIter{};
            try it_d.init(&td, &.{}, &hi_d);
            defer it_d.deinit();
            var c: u64 = 0;
            while (it_d.next()) |_| c += 1;
            std.debug.print("del_remaining,{d},{d}\n", .{ n, c });
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

            var ct = try tablemod.Table.open(io, dir, cp, alloc, .{ .wal_sync_every = 0, .flush_bytes = c.fb });
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
                var ct2 = try tablemod.Table.open(io, dir, cp, alloc, .{ .wal_sync_every = 0, .flush_bytes = c.fb });
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

        var kt = try tablemod.Table.open(io, dir, kp, alloc, .{ .wal_sync_every = 0, .flush_bytes = 8 << 20 });
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
                        .wal_sync_every = 0,
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
            kt = try tablemod.Table.open(io, dir, kp, alloc, .{ .wal_sync_every = 0, .flush_bytes = 8 << 20 });
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
            var kt2 = try tablemod.Table.open(io, dir, kp, alloc, .{ .wal_sync_every = 0, .flush_bytes = 8 << 20 });
            defer kt2.deinit();
            std.debug.print("cm_recover,{d},{d:.2}\n", .{ kn, @as(f64, @floatFromInt(nowNs(io) - t0)) / 1e6 });
        }
    }
    // 自动 compaction 的基准已移到独立入口：zig build run-bench-ac（src/bench_ac.zig）。
    // 放在整套 bench 末尾时，前面 big_* 留下的脏页与页缓存让同配置波动达 84%~435%，
    // 中位数不可信；独立进程从干净状态起跑才测得准。

    // **行头格式：旧定长(17B) vs 新定长(7B+逃逸) 的解码成本**（§16.1.26）。
    //
    // 纯内存、不碰磁盘；两种格式各建一份同样的内容，**同进程交替**跑、奇偶轮换顺序。
    // 跨批次比扫描吞吐在这台机器上不可信（批内波动 20–40%），配对才是唯一能用的口径。
    //
    // **缓冲区必须小到能待在 L3 里**：第一版用 100 万条 × 57B = 57MB，一趟跑完是
    // 13 GB/s —— 那是在测内存带宽，不是测解码，两种格式的差异被淹没。
    // 200k 条（11.4MB / 9.2MB）放进 32MB L3，再重复 20 趟，测到的才是解码本身。
    {
        const RN: usize = 200_000;
        const REP: usize = 20;
        var old_buf: std.ArrayList(u8) = .empty;
        defer old_buf.deinit(alloc);
        var new_buf: std.ArrayList(u8) = .empty;
        defer new_buf.deinit(alloc);
        try old_buf.ensureTotalCapacity(alloc, RN * 57);
        try new_buf.ensureTotalCapacity(alloc, RN * 48);

        {
            var i: usize = 0;
            while (i < RN) : (i += 1) {
                const kb = keyOf(@intCast(i));
                const seq: u64 = i + 1;
                // 旧格式
                try codec.putU32le(&old_buf, alloc, kb.len);
                try codec.putU32le(&old_buf, alloc, value.len);
                try codec.putU64le(&old_buf, alloc, seq);
                try old_buf.append(alloc, 0);
                try old_buf.appendSlice(alloc, &kb);
                try old_buf.appendSlice(alloc, &value);
                // 新格式
                var hdr: [6 + 33]u8 = undefined;
                const hn = codec.writeRecHdr(&hdr, kb.len, value.len, seq, 0);
                try new_buf.appendSlice(alloc, hdr[0..hn]);
                try new_buf.appendSlice(alloc, &kb);
                try new_buf.appendSlice(alloc, &value);
            }
        }
        // 对拍：两边解出来的内容必须完全一致（否则下面的计时毫无意义）
        {
            var po: usize = 0;
            var pn: usize = 0;
            while (true) {
                const a = readRecLegacy(old_buf.items, po);
                const b = codec.readRec(new_buf.items, pn, 0);
                if (a == null or b == null) {
                    if (a != null or b != null) return error.RecFmtMismatch;
                    break;
                }
                if (!std.mem.eql(u8, a.?.key, b.?.key) or !std.mem.eql(u8, a.?.value, b.?.value) or
                    a.?.seq != b.?.seq or a.?.flags != b.?.flags) return error.RecFmtMismatch;
                po = a.?.next;
                pn = b.?.next;
            }
        }

        var round: usize = 0;
        while (round < 5) : (round += 1) {
            const order: [2]bool = if (round % 2 == 0) .{ true, false } else .{ false, true };
            for (order) |use_old| {
                const buf = if (use_old) old_buf.items else new_buf.items;
                const t0 = nowNs(io);
                var acc: u64 = 0;
                var total: u64 = 0;
                var rep: usize = 0;
                while (rep < REP) : (rep += 1) {
                    var pos: usize = 0;
                    while (true) {
                        const rec = if (use_old) readRecLegacy(buf, pos) else codec.readRec(buf, pos, 0);
                        const r = rec orelse break;
                        acc +%= r.seq +% r.key.len +% r.value.len +% r.key[0] +% r.flags;
                        pos = r.next;
                        total += 1;
                    }
                }
                const ns = nowNs(io) - t0;
                const tag = if (use_old) "old17" else "hdr7";
                std.debug.print("recdec_{s},{d},{d:.0}\n", .{ tag, total, opsPerSec(total, ns) });
                if (acc == 0xDEADBEEF) std.debug.print("recdec_guard,1,0\n", .{});
            }
        }
        std.debug.print("recdec_bytes,{d},{d}\n", .{ old_buf.items.len, new_buf.items.len });
    }

    // **假设性实验：块内 key 前缀压缩值不值得做**（§16.1.27）。
    //
    // 现在的行是零拷贝的：`key` / `value` 直接是 mmap 里的切片，一格不碰。
    // 前缀压缩能把 key 从 8 B 压到 ~2 B，但解出来的 key **不再是连续内存** ——
    // 必须物化到一个缓冲区里。这里不改产品代码，只把「压 + 物化」的代价量出来：
    // 压缩版缓冲 vs 现有 7 B 头缓冲（都是同一份内容、200k 条、L3 常驻、重复 20 趟）。
    //
    // 为什么必须量：§16.1.26 已经踩过一次 —— 只是把 `readRec` 从非 inline 改成 inline、
    // 把边界检查改成编译器可证明的形状，同一份数据就差了 20%。
    // 「只是多了一次 memcpy」这种判断在这台机器上从来没准过。
    {
        const PN: usize = 200_000;
        const PREP: usize = 20;
        var pbuf: std.ArrayList(u8) = .empty;
        defer pbuf.deinit(alloc);
        try pbuf.ensureTotalCapacity(alloc, PN * 44);
        // 同内容的 7 B 定长头版本（对照组），与上一块的 `new_buf` 等价，
        // 但建在同一个作用域里，两边才能真正配对
        var plain_buf: std.ArrayList(u8) = .empty;
        defer plain_buf.deinit(alloc);
        try plain_buf.ensureTotalCapacity(alloc, PN * 48);

        // 造前缀压缩缓冲：块内第 0 条写整 key，其余写 (pfx, suffix)。
        // 每行布局：u8 tag | u8 vlen | u32 seq | u8 flags | [u8 pfx,u8 slen | suffix] 或 [key]
        // tag = 0xFE 表示压缩。
        {
            var prev: [8]u8 = @splat(0);
            var i: usize = 0;
            while (i < PN) : (i += 1) {
                const kb = keyOf(@intCast(i));
                const seq: u32 = @intCast(i + 1);
                const block_start = (i % 64 == 0);
                var pfx: usize = 0;
                if (!block_start) {
                    while (pfx < 8 and prev[pfx] == kb[pfx]) pfx += 1;
                }
                if (block_start) {
                    try pbuf.append(alloc, 8);
                    try pbuf.append(alloc, value.len);
                    try codec.putU32le(&pbuf, alloc, seq);
                    try pbuf.append(alloc, 0);
                    try pbuf.appendSlice(alloc, &kb);
                } else {
                    try pbuf.append(alloc, 0xFE);
                    try pbuf.append(alloc, value.len);
                    try codec.putU32le(&pbuf, alloc, seq);
                    try pbuf.append(alloc, 0);
                    try pbuf.append(alloc, @intCast(pfx));
                    try pbuf.append(alloc, @intCast(8 - pfx));
                    try pbuf.appendSlice(alloc, kb[pfx..]);
                }
                try pbuf.appendSlice(alloc, &value);
                {
                    var hdr: [6 + 33]u8 = undefined;
                    const hn = codec.writeRecHdr(&hdr, kb.len, value.len, seq, 0);
                    try plain_buf.appendSlice(alloc, hdr[0..hn]);
                    try plain_buf.appendSlice(alloc, &kb);
                    try plain_buf.appendSlice(alloc, &value);
                }
                prev = kb;
            }
        }

        var kbuf: std.ArrayList(u8) = .empty;
        defer kbuf.deinit(alloc);
        try kbuf.ensureTotalCapacity(alloc, 512);

        var round: usize = 0;
        while (round < 5) : (round += 1) {
            const order: [2]bool = if (round % 2 == 0) .{ true, false } else .{ false, true };
            for (order) |use_plain| {
                const t0 = nowNs(io);
                var acc: u64 = 0;
                var total: u64 = 0;
                var rep: usize = 0;
                while (rep < PREP) : (rep += 1) {
                    if (use_plain) {
                        var pos: usize = 0;
                        while (codec.readRec(plain_buf.items, pos, 0)) |r| {
                            acc +%= r.seq +% r.key.len +% r.value.len +% r.key[0] +% r.flags;
                            pos = r.next;
                            total += 1;
                        }
                    } else {
                        var pos: usize = 0;
                        while (pos < pbuf.items.len) {
                            kbuf.clearRetainingCapacity();
                            const tag = pbuf.items[pos];
                            const vlen: usize = pbuf.items[pos + 1];
                            const seq = std.mem.readInt(u32, pbuf.items[pos + 2 ..][0..4], .little);
                            const flags = pbuf.items[pos + 6];
                            var p = pos + 7;
                            if (tag == 0xFE) {
                                const pfx: usize = pbuf.items[p];
                                const slen: usize = pbuf.items[p + 1];
                                p += 2;
                                // 物化：保留已有前缀，接上后缀
                                try kbuf.appendSlice(alloc, pbuf.items[p..][0..slen]);
                                acc +%= seq +% (pfx + slen) +% vlen;
                                p += slen;
                            } else {
                                try kbuf.appendSlice(alloc, pbuf.items[p..][0..tag]);
                                acc +%= seq +% @as(u64, tag) +% vlen;
                                p += tag;
                            }
                            acc +%= kbuf.items[0] +% flags;
                            pos = p + vlen;
                            total += 1;
                        }
                    }
                }
                const ns = nowNs(io) - t0;
                const tag2 = if (use_plain) "plain7" else "pfx";
                std.debug.print("recdec_{s},{d},{d:.0}\n", .{ tag2, total, opsPerSec(total, ns) });
            }
        }
        std.debug.print("recdec_pfx_bytes,1,{d},{d}\n", .{ plain_buf.items.len, pbuf.items.len });
    }

    // **keyCmp 快路径到底值多少**（§16.1.28）。
    //
    // `segment.zig` 里那句「逐字节循环实测占 ~20%」是拿**手写循环**比 u64 得出的。
    // 但 `std.mem.order` 会落到 memcmp（向量化），对手写循环快得多。
    // 如果 memcmp 与 u64 差不多，那「key 必须定长 8 字节」这个前提就不成立了 ——
    // 变长保序编码能直接省 4 B/行且保持零拷贝。
    //
    // 三种比法，同进程配对、奇偶轮换：
    {
        const KN: usize = 8192;
        const KREP: usize = 200;
        var keys: [KN][8]u8 = undefined;
        {
            var i: usize = 0;
            while (i < KN) : (i += 1) {
                // 打散一下，避免全部前缀相同导致「第一次字节就分胜负」的假象
                var kb: [8]u8 = undefined;
                codec.encodeI64Key(&kb, @as(i64, @intCast(i)) * 0x9E37 + @as(i64, @intCast(i % 97)) * 65536);
                keys[i] = kb;
            }
        }
        var round: usize = 0;
        while (round < 5) : (round += 1) {
            const order: [3]u8 = switch (round % 3) {
                0 => .{ 0, 1, 2 },
                1 => .{ 1, 2, 0 },
                else => .{ 2, 0, 1 },
            };
            for (order) |which| {
                const t0 = nowNs(io);
                var acc: u64 = 0;
                var rep: usize = 0;
                while (rep < KREP) : (rep += 1) {
                    var i: usize = 0;
                    while (i < KN) : (i += 1) {
                        const a = keys[i][0..];
                        const b = keys[(i * 31 + 1) % KN][0..];
                        const o: std.math.Order = switch (which) {
                            0 => blk: {
                                const x = std.mem.readInt(u64, a[0..8], .big);
                                const y = std.mem.readInt(u64, b[0..8], .big);
                                break :blk std.math.order(x, y);
                            },
                            1 => std.mem.order(u8, a, b),
                            else => blk: {
                                const nn = @min(a.len, b.len);
                                var j: usize = 0;
                                var r: std.math.Order = .eq;
                                while (j < nn) : (j += 1) {
                                    if (a[j] != b[j]) {
                                        r = if (a[j] < b[j]) .lt else .gt;
                                        break;
                                    }
                                }
                                break :blk r;
                            },
                        };
                        acc +%= @intFromEnum(o);
                    }
                }
                const ns = nowNs(io) - t0;
                const tag = switch (which) {
                    0 => "u64",
                    1 => "memcmp",
                    else => "hand",
                };
                std.debug.print("keycmp_{s},{d},{d:.0}\n", .{ tag, KN * KREP, opsPerSec(KN * KREP, ns) });
                if (acc == 0xDEADBEEF) std.debug.print("keycmp_guard,1,0\n", .{});
            }
        }
    }

    // **WAL 轮换 A/B（同进程背靠背配对）**：原地截断 vs 关/删/建文件。
    //
    // 为什么要配对：写路径偶发整轮崩塌只有约 1/7 的概率，跨批次比必然被噪声吃掉
    // （§16.1.22 那一轮就是跨批次比比值、结论差 14% 全在噪声里）。
    // 这里同进程交替、**奇偶轮交换先后**抵消冷热偏差，逐对输出比值。
    //
    // **必须放在整套基准的最末尾**（§16.1.7 的教训）：本探针要写 14 × 100 万行 ≈ 570MB，
    // 放在中间会把脏页与页缓存占满，让后面的 `big_*` 读指标波动从 20% 放大到 400%+。
    // 第一版就是放在 `big_put_strong` 后面的，审计时已挪到 `bench_done` 之前。
    // lite 模式跳过（官方对比不做重型探针：单轮写入量从 ~2.5GB 降到 ~1.0GB）。
    if (!lite) {
        const ab_n: u64 = 1_000_000;
        var pair: usize = 0;
        while (pair < 7) : (pair += 1) {
            const recreate_first = (pair % 2) == 1;
            var vals: [2]f64 = undefined;
            var k: usize = 0;
            while (k < 2) : (k += 1) {
                const recreate = if (k == 0) recreate_first else !recreate_first;
                const p = if (recreate) "bench-data-walab-re" else "bench-data-walab-tr";
                dir.deleteTree(io, p) catch {};
                defer dir.deleteTree(io, p) catch {};
                var tab = try tablemod.Table.open(io, dir, p, alloc, .{
                    .wal_sync_every = 0,
                    .flush_bytes = 8 << 20,
                    .wal_rotate_recreate = recreate,
                });
                defer tab.deinit();
                const t0 = nowNs(io);
                var j: u64 = 0;
                while (j < ab_n) : (j += 1) {
                    const kb = keyOf(@intCast(j));
                    try tab.put(&kb, &value);
                }
                try tab.flush();
                vals[k] = opsPerSec(ab_n, nowNs(io) - t0);
            }
            const trunc = if (recreate_first) vals[1] else vals[0];
            const recre = if (recreate_first) vals[0] else vals[1];
            std.debug.print("walab_pair,{d},{d:.0}\n", .{ pair + 1, trunc });
            std.debug.print("walab_pair_recreate,{d},{d:.0}\n", .{ pair + 1, recre });
            std.debug.print("walab_ratio,{d},{d:.4}\n", .{ pair + 1, trunc / recre });
        }
    }

    benchMark(io, t_bench, "end");
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
    var t = tablemod.Table.open(a.io, a.dir, a.path, alloc, .{ .wal_sync_every = 0 }) catch {
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


