// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
//! AI 向量检索可行性原型：**只测暴力全扫到底有多快**，不引入任何索引。
//!
//! 目的：回答「Pek.RDB 能不能支持 AI 向量检索」这个问题里最关键的一步 ——
//! 如果暴力扫描已经够用（比如 10 万条 768 维能在几十毫秒内出 Top-K），
//! 那就不必一上来就做 HNSW；如果慢到几百毫秒，才值得投入图索引。
//!
//! 度量方式：预生成 N 条 D 维 float32 向量，串行算 Q 次 L2 距离并取最小值，
//! 输出「单次查询耗时」与「有效算力（GB/s）」。
const std = @import("std");

/// x86-64 AVX2 是 8 个 f32 一条；用 `@Vector(8, f32)` 让编译器直接出 SIMD 指令，
/// 不写 intrinsics（Zig 的 `@Vector` 在两侧平台都能映射）。
const LANES = 8;
const V = @Vector(LANES, f32);

/// 平方 L2 距离。返回平方值即可 —— Top-K 排序只关心相对大小，省一次 sqrt。
fn l2Sq(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    std.debug.assert(a.len % LANES == 0);
    var acc: V = @splat(0.0);
    var i: usize = 0;
    while (i < a.len) : (i += LANES) {
        const va: V = a[i..][0..LANES].*;
        const vb: V = b[i..][0..LANES].*;
        const d = va - vb;
        acc += d * d;
    }
    return @reduce(.Add, acc);
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const alloc = std.heap.smp_allocator;

    const dim: usize = 768; // 常见 embedding 维度（bge-base / text-embedding-3-small 级别）
    const n: usize = 100_000; // 约 307 MB：既能看出量级，又不会把机器打爆
    const queries: usize = 20;
    const topk: usize = 10;

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();

    // 数据布局：行主序连续存放，扫描时顺序访问 —— 这正是 mmap 段文件的形态。
    const data = try alloc.alloc(f32, n * dim);
    defer alloc.free(data);
    for (data) |*x| x.* = rnd.float(f32) * 2.0 - 1.0;

    const q = try alloc.alloc(f32, dim);
    defer alloc.free(q);

    var best_idx: usize = 0;
    var best: f32 = std.math.inf(f32);
    var bytes_scanned: u64 = 0;

    const t0 = std.Io.Timestamp.now(io, .awake).nanoseconds;
    var qi: usize = 0;
    while (qi < queries) : (qi += 1) {
        for (q) |*x| x.* = rnd.float(f32) * 2.0 - 1.0;
        // Top-K 用「先全扫再取最小的 k 个」的最朴素做法：本原型只测扫描下限，
        // 不做堆（真要上线才需要堆，那部分开销是 O(n log k)，相对扫描可忽略）。
        var top: [64]f32 = @splat(std.math.inf(f32));
        best_idx = 0;
        best = std.math.inf(f32);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const v = l2Sq(data[i * dim ..][0..dim], q);
            bytes_scanned += dim * @sizeOf(f32);
            if (v < best) {
                best = v;
                best_idx = i;
            }
            // 维护 top-k 的插入排序（k=10，开销可忽略）
            if (v < top[topk - 1]) {
                var j: usize = topk - 1;
                while (j > 0 and v < top[j - 1]) : (j -= 1) top[j] = top[j - 1];
                top[j] = v;
            }
        }
    }
    const ns: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - t0);

    const per_query_ns = ns / queries;
    const gb_scanned = @as(f64, @floatFromInt(bytes_scanned)) / (1024.0 * 1024.0 * 1024.0);
    const gbps = gb_scanned / (@as(f64, @floatFromInt(ns)) / 1e9);

    std.debug.print("vec_dim,{d}\n", .{dim});
    std.debug.print("vec_n,{d}\n", .{n});
    std.debug.print("vec_queries,{d}\n", .{queries});
    std.debug.print("vec_total_ms,{d}\n", .{ns / 1_000_000});
    std.debug.print("vec_per_query_ms,{d:.2}\n", .{@as(f64, @floatFromInt(per_query_ns)) / 1e6});
    std.debug.print("vec_qps,{d:.1}\n", .{1e9 / @as(f64, @floatFromInt(per_query_ns))});
    std.debug.print("vec_gbps,{d:.2}\n", .{gbps});
    std.debug.print("vec_best_idx,{d}\n", .{best_idx});
    std.debug.print("vec_best_len,{d}\n", .{best});
}
