// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
//! 容量阶梯基准（决策记录八十九/九十）。
//!
//! 为什么单独一个入口：主基准固定 100 万行，而容量线要回答的是
//! 「数据量 ×100 之后（1 亿行 ≈ 4.86 GB）开表 / 冷重开 / 点查 / 扫描还成不成立」。
//! 灌数据本身要几分钟、写 4.86 GB，不适合塞进 vs-SQLite 的正式批次。
//!
//! 用法：
//!   zig build run-scale -- --rows 2000000
//!   zig build run-scale -- --rows 100000000 --dir scale-1e8
//!
//! 输出：`名称,数量,数值` 的 CSV 行（与主基准同格式，便于 `tools/` 里的脚本读）。
const std = @import("std");
const spike = @import("pek_rdb_spike");
const tablemod = spike.table;
const segmod = spike.segment;
const build_options = @import("build_options");

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

fn perSec(n: u64, ns: u64) f64 {
    if (ns == 0) return 0;
    return @as(f64, @floatFromInt(n)) * 1e9 / @as(f64, @floatFromInt(ns));
}

fn putLine(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// 文件字节数（不存在按 0 计，不让统计本身把基准搞挂）。
fn fileSize(io: std.Io, dir: std.Io.Dir, path: []const u8) u64 {
    if (dir.openFile(io, path, .{})) |f| {
        defer f.close(io);
        return (f.stat(io) catch return 0).size;
    } else |_| return 0;
}

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const rows: u64 = build_options.rows;
    const root: []const u8 = build_options.dir;

    dir.deleteTree(io, root) catch {};
    try dir.createDirPath(io, root);

    const keybuf = try alloc.alloc([8]u8, 1024);
    defer alloc.free(keybuf);
    const keys = try alloc.alloc([]const u8, 1024);
    defer alloc.free(keys);
    const vals = try alloc.alloc([]const u8, 1024);
    defer alloc.free(vals);
    const valbuf = try alloc.alloc([32]u8, 1024);
    defer alloc.free(valbuf);
    for (valbuf) |*v| @memset(v, 'x');
    for (0..1024) |i| vals[i] = &valbuf[i];

    var t = try tablemod.Table.open(io, dir, root, alloc, .{ .wal_sync_every = 0 });
    var t_live = true;
    defer if (t_live) t.deinit();

    // ---------------- 灌数据（分批一次 WAL 提交） ----------------
    const t_put = nowNs(io);
    var done: u64 = 0;
    while (done < rows) {
        const n: usize = @intCast(@min(@as(u64, 1024), rows - done));
        for (0..n) |i| {
            var kb: [8]u8 = undefined;
            spike.codec.encodeI64Key(&kb, @intCast(done + i));
            keybuf[i] = kb;
            keys[i] = &keybuf[i];
        }
        try t.putBatch(keys[0..n], vals[0..n]);
        done += n;
        if (done % 10_000_000 == 0) {
            std.debug.print("progress,{d},{d}\n", .{ done, (nowNs(io) - t_put) / 1_000_000 });
        }
    }
    const ns_put = nowNs(io) - t_put;
    putLine("scale_put,{d},{d:.0}", .{ rows, perSec(rows, ns_put) });

    // ---------------- flush（落段 + 归档） ----------------
    const t_flush = nowNs(io);
    try t.flush();
    const ns_flush = nowNs(io) - t_flush;
    putLine("scale_flush_ms,{d},{d}", .{ rows, ns_flush / 1_000_000 });
    putLine("scale_flush_calls,{d},{d}", .{ rows, t.flush_calls });
    putLine("scale_segs,{d},{d}", .{ rows, t.segs.items.len });

    // ---------------- 落盘体积（确定性指标） ----------------
    var data_bytes: u64 = 0;
    for (t.segs.items) |sg| {
        const p = try alloc.print("{s}/seg/{d:0>6}.data", .{ root, sg.id });
        defer alloc.free(p);
        data_bytes += fileSize(io, dir, p);
    }
    const idx_path = try alloc.print("{s}/seg/index.bin", .{root});
    defer alloc.free(idx_path);
    const idx_bytes = fileSize(io, dir, idx_path);
    putLine("scale_data_bytes,{d},{d}", .{ rows, data_bytes });
    putLine("scale_index_bytes,{d},{d}", .{ rows, idx_bytes });
    if (rows > 0) {
        putLine("scale_bytes_per_row_x100,{d},{d}", .{
            rows,
            @as(u64, @intFromFloat(@as(f64, @floatFromInt(data_bytes + idx_bytes)) * 100.0 / @as(f64, @floatFromInt(rows)))),
        });
    }

    // ---------------- 热态点查（命中 / 未命中） ----------------
    {
        var vbuf: std.ArrayList(u8) = .empty;
        defer vbuf.deinit(alloc);
        const probes: u64 = 20_000;
        var x: u64 = 88172645463325252;
        var hits: u64 = 0;
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < probes) : (i += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            var kb: [8]u8 = undefined;
            spike.codec.encodeI64Key(&kb, @intCast(x % rows));
            if (try t.get(&kb, &vbuf)) |_| hits += 1;
        }
        putLine("scale_get_hit,{d},{d:.0}", .{ hits, perSec(probes, nowNs(io) - t0) });

        // 第二遍：数据页已经热了。与主基准（1M 行、页已热）同口径的「CPU 侧」点查。
        // 第一遍实际上是「冷随机读」——3.9 GB 段上随机 2 万次几乎每次都缺页，数字会很低。
        var hits2: u64 = 0;
        const t2 = nowNs(io);
        i = 0;
        while (i < probes) : (i += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            var kb: [8]u8 = undefined;
            spike.codec.encodeI64Key(&kb, @intCast(x % rows));
            if (try t.get(&kb, &vbuf)) |_| hits2 += 1;
        }
        putLine("scale_get_hit_warm,{d},{d:.0}", .{ hits2, perSec(probes, nowNs(io) - t2) });

        var found_but_should_not: u64 = 0;
        const t1 = nowNs(io);
        i = 0;
        while (i < probes) : (i += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            var kb: [8]u8 = undefined;
            // 超出范围 + 落在中间但不存在（偶数 key 是存在的，这里用 rows+... 保证不存在）
            spike.codec.encodeI64Key(&kb, @intCast(rows + (x % rows) + 1));
            if (try t.get(&kb, &vbuf)) |_| found_but_should_not += 1;
        }
        putLine("scale_get_miss,{d},{d:.0}", .{ probes - found_but_should_not, perSec(probes, nowNs(io) - t1) });
    }

    // ---------------- 全表扫描（流式，不收集） ----------------
    {
        var hi: [16]u8 = @splat(0xFF);
        var cnt: u64 = 0;
        const t0 = nowNs(io);
        var it = tablemod.MergeIter{};
        try it.init(&t, &.{}, &hi);
        defer it.deinit();
        while (it.next()) |_| cnt += 1;
        putLine("scale_scan,{d},{d:.0}", .{ cnt, perSec(cnt, nowNs(io) - t0) });
    }

    // ---------------- 冷重开：预缺页开 / 关 各 3 次，交替顺序 ----------------
    //
    // 为什么必须两边都测：`populate` 在 Windows 上真的会整段 Prefetch，
    // 归档小的时候是好事，归档大的时候等于 open 时把整个索引读一遍。
    // 交替顺序是为了让「谁先跑谁占页缓存」的偏差在两档之间对消一半。
    t.deinit();
    t_live = false;

    const pref: [2]struct { name: []const u8, max: u64 } = .{
        .{ .name = "prefault_on", .max = 1 << 62 },
        .{ .name = "prefault_off", .max = 0 },
    };
    var round: usize = 0;
    while (round < 6) : (round += 1) {
        const p = pref[round % 2];
        const t0 = nowNs(io);
        var tr = try tablemod.Table.open(io, dir, root, alloc, .{
            .wal_sync_every = 0,
            .index_prefault_max_bytes = p.max,
        });
        // 用**微秒**：2M 行时重开不到 1ms，按 ms 打印全是 0，看不出差别。
        const us = (nowNs(io) - t0) / 1000;
        putLine("scale_reopen_us,{s},{d}", .{ p.name, us });
        // 开完立刻做一次点查，验证映射内容真的可读（不是只有 open 成功）
        if (round == 0) {
            var vbuf: std.ArrayList(u8) = .empty;
            defer vbuf.deinit(alloc);
            var kb: [8]u8 = undefined;
            spike.codec.encodeI64Key(&kb, 0);
            const ok = (try tr.get(&kb, &vbuf)) != null;
            putLine("scale_reopen_get_ok,0,{d}", .{@intFromBool(ok)});
        }
        tr.deinit();
    }

    dir.deleteTree(io, root) catch {};
    putLine("scale_done,{d},0", .{rows});
}
