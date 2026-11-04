// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。

//! 固定池分配器（架构 §16.5 的 `-Dalloc` 档）。
//!
//! **为什么需要它**：C 档目标（无 MMU、无 OS、128KB 级 RAM）上没有 `malloc`。
//! 引擎本身**已经**零系统堆依赖——所有分配都走调用方传进来的 `std.mem.Allocator`
//! （见 `test "源码闸门"`），所以「支持固定池」剩下的唯一一件事，是**证明把固定池填进去能跑**：
//! 空口说「可以」不算，必须有一条用例在静态缓冲区上跑完 KV 全流程并归还全部内存。
//!
//! 布局：每个块 16 字节头部区 + 16 字节对齐的负载。
//! - 分配时头 16 字节空着（不用存元数据：总跨度由「申请长度」唯一决定，
//!   `total = 16 + alignForward(len, 16)`，`free` 收到的 `memory.len` 就是申请长度）；
//! - 释放时头 16 字节用来存空闲链表的下一个指针（侵入式，零额外内存）。
//!
//! 分配策略：**尺寸分箱 + 首次适配 + 剩余分裂**。同一尺寸反复申请/释放能原地复用；
//! 不会合并相邻空闲块（嵌入式上块数有限，合并的复杂度不值得），所以容量要按峰值给。
//!
//! 边界（有意为之，都有可观测计数器，不是静默降级）：
//! - 对齐 > 16 的申请返回 `null` 并让 `unsupported_align` +1 —— 引擎只用 1/8/16；
//! - `resize` 只在「四舍五入后大小不变」时返回 true，否则交回调用方做 alloc+copy+free；
//! - `remap` 一律返回 `null`（没有可重映射的地址空间）。

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");
const tablemod = @import("table.zig");

/// 头部区大小 = 负载的基础对齐（负载一定 16 对齐，满足 ≤16 的任何要求）
const HDR = 16;
/// 块的最短跨度：再小就不值得分裂（16 头 + 16 负载）
const MIN_BLOCK = 32;
/// 分箱数：跨度 1..2^39 足够覆盖任何静态池
const BINS = 40;

pub const FixedPool = struct {
    buf: []u8,
    /// bump 指针（相对 `buf` 的偏移）；已分配区不会回退，只有空闲箱会复用
    used: usize = 0,
    bins: [BINS]?*FreeNode = @splat(null),

    // ---- 观测（用例断言用；生产可读，无副作用） ----
    /// 当前占用字节（含头部），正确归还后必须回到 0
    bytes_in_use: usize = 0,
    bytes_peak: usize = 0,
    live_allocs: usize = 0,
    /// 池耗尽次数（返回 null/OutOfMemory 的次数）
    oom_count: usize = 0,
    /// 对齐 > 16 被拒次数——必须是 0，否则说明调用方用了池模式不支持的对齐
    unsupported_align: usize = 0,

    const FreeNode = struct {
        next: ?*FreeNode,
        /// 块的总跨度（含 16 字节头部）
        total: usize,
    };

    pub fn init(buf: []u8) FixedPool {
        assert(buf.len >= 1024);
        assert(@intFromPtr(buf.ptr) % HDR == 0);
        return .{ .buf = buf };
    }

    pub fn allocator(self: *FixedPool) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// 归还全部内存后应为 0；e2e 用例用它证明「引擎没有额外持有内存」
    pub fn idle(self: *const FixedPool) bool {
        return self.bytes_in_use == 0 and self.live_allocs == 0;
    }

    fn binOf(total: usize) usize {
        return @min(@as(usize, std.math.log2_int(usize, total)), BINS - 1);
    }

    fn payloadOf(block: usize) [*]u8 {
        return @ptrFromInt(block + HDR);
    }

    fn blockOf(payload: [*]u8) usize {
        return @intFromPtr(payload) - HDR;
    }

    /// 申请长度 → 块跨度。**唯一真相源**：alloc 与 free 都必须用这一个函数，
    /// 否则「分配记 128、释放算 64」会悄悄泄漏后半截。
    fn spanOf(len: usize) usize {
        return HDR + std.mem.alignForward(usize, len, HDR);
    }

    fn allocImpl(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *FixedPool = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() > HDR) {
            self.unsupported_align += 1;
            return null;
        }
        const need = spanOf(len);
        if (need > self.buf.len) {
            self.oom_count += 1;
            return null;
        }

        // ① 空闲箱里找（从本尺寸所在的箱往上找，允许大块分裂）
        var b = binOf(need);
        while (b < BINS) : (b += 1) {
            var prev: ?*FreeNode = null;
            var cur = self.bins[b];
            while (cur) |node| {
                if (node.total >= need) {
                    // 摘链
                    if (prev) |p| p.next = node.next else self.bins[b] = node.next;
                    const block: usize = @intFromPtr(node);
                    if (node.total - need >= MIN_BLOCK) {
                        const rest: *FreeNode = @ptrFromInt(block + need);
                        rest.* = .{ .next = self.bins[binOf(node.total - need)], .total = node.total - need };
                        self.bins[binOf(rest.total)] = rest;
                    }
                    _ = self.noteAlloc(need);
                    return payloadOf(block);
                }
                prev = node;
                cur = node.next;
            }
        }

        // ② bump 分配（头部区也对齐到 16，保证 `blockOf` 与分裂都成立）
        const base = std.mem.alignForward(usize, @intFromPtr(self.buf.ptr) + self.used, HDR) - @intFromPtr(self.buf.ptr);
        if (base + need > self.buf.len) {
            self.oom_count += 1;
            return null;
        }
        self.used = base + need;
        _ = self.noteAlloc(need);
        return payloadOf(@intFromPtr(self.buf.ptr) + base);
    }

    fn noteAlloc(self: *FixedPool, total: usize) usize {
        self.bytes_in_use += total;
        self.bytes_peak = @max(self.bytes_peak, self.bytes_in_use);
        self.live_allocs += 1;
        return total;
    }

    fn resizeImpl(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
        // 只有「四舍五入后跨度不变」才算原地成功：跨度变了就必须让调用方
        // alloc+copy+free，否则 free 时按新长度算出的跨度与真实块不符 → 后半截永久漏掉。
        _ = alignment;
        return spanOf(memory.len) == spanOf(new_len);
    }

    fn remapImpl(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null; // 没有可重映射的地址空间：交回调用方 alloc+copy
    }

    fn freeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
        _ = alignment;
        if (memory.len == 0) return; // 0 长度不占块（alloc 也不会为它建块）
        const self: *FixedPool = @ptrCast(@alignCast(ctx));
        const total = spanOf(memory.len);
        const block = blockOf(memory.ptr);
        assert(block >= @intFromPtr(self.buf.ptr));
        assert(block + total <= @intFromPtr(self.buf.ptr) + self.buf.len);
        assert(self.bytes_in_use >= total);
        assert(self.live_allocs > 0);
        const node: *FreeNode = @ptrFromInt(block);
        const bin = binOf(total);
        node.* = .{ .next = self.bins[bin], .total = total };
        self.bins[bin] = node;
        self.bytes_in_use -= total;
        self.live_allocs -= 1;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocImpl,
        .resize = resizeImpl,
        .remap = remapImpl,
        .free = freeImpl,
    };
};

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

test "固定池：同尺寸释放后原位复用，记账归零" {
    var buf: [4096]u8 align(HDR) = @splat(0);
    var pool = FixedPool.init(&buf);
    const a = pool.allocator();

    const p1 = try a.alloc(u8, 100);
    try std.testing.expect(!pool.idle());
    try std.testing.expectEqual(@as(usize, 1), pool.live_allocs);
    @memset(p1, 0xAB);
    a.free(p1);
    try std.testing.expect(pool.idle());

    const p2 = try a.alloc(u8, 100);
    try std.testing.expectEqual(@intFromPtr(p1.ptr), @intFromPtr(p2.ptr)); // 真的复用
    @memset(p2, 0xCD);
    a.free(p2);
    try std.testing.expect(pool.idle());
    try std.testing.expectEqual(@as(usize, 0), pool.oom_count);
    try std.testing.expectEqual(@as(usize, 0), pool.unsupported_align);
}

test "固定池：1/2/4/8/16 对齐都被满足" {
    var buf: [8192]u8 align(HDR) = @splat(0);
    var pool = FixedPool.init(&buf);
    const a = pool.allocator();

    const s1 = try a.alignedAlloc(u8, .@"1", 13);
    const s2 = try a.alignedAlloc(u8, .@"2", 13);
    const s4 = try a.alignedAlloc(u8, .@"4", 13);
    const s8 = try a.alignedAlloc(u8, .@"8", 13);
    const s16 = try a.alignedAlloc(u8, .@"16", 13);
    try std.testing.expect(@intFromPtr(s1.ptr) % 1 == 0);
    try std.testing.expect(@intFromPtr(s2.ptr) % 2 == 0);
    try std.testing.expect(@intFromPtr(s4.ptr) % 4 == 0);
    try std.testing.expect(@intFromPtr(s8.ptr) % 8 == 0);
    try std.testing.expect(@intFromPtr(s16.ptr) % 16 == 0);
    a.free(s1);
    a.free(s2);
    a.free(s4);
    a.free(s8);
    a.free(s16);
    try std.testing.expect(pool.idle());
    try std.testing.expectEqual(@as(usize, 0), pool.unsupported_align);
}

test "固定池：对齐 > 16 被拒且计数可见（不静默降级）" {
    var buf: [4096]u8 align(HDR) = @splat(0);
    var pool = FixedPool.init(&buf);
    const a = pool.allocator();
    try std.testing.expectError(error.OutOfMemory, a.alignedAlloc(u8, .@"32", 64));
    try std.testing.expectEqual(@as(usize, 1), pool.unsupported_align);
    try std.testing.expectEqual(@as(usize, 0), pool.live_allocs);
}

test "固定池：耗尽返回 OOM，释放后可再分配；扩张不越界" {
    var buf: [4096]u8 align(HDR) = @splat(0);
    var pool = FixedPool.init(&buf);
    const a = pool.allocator();

    var held = std.ArrayList([]u8).empty;
    defer held.deinit(std.testing.allocator);
    while (true) {
        const p = a.alloc(u8, 200) catch |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            break;
        };
        try held.append(std.testing.allocator, p);
        try std.testing.expect(held.items.len < 64); // 防空跑：真能装下若干块
    }
    try std.testing.expect(pool.oom_count > 0);
    try std.testing.expect(held.items.len >= 4);

    const freed = held.pop().?;
    a.free(freed);
    const again = try a.alloc(u8, 200);
    try std.testing.expectEqual(@intFromPtr(freed.ptr), @intFromPtr(again.ptr));

    for (held.items) |p| a.free(p);
    a.free(again);
    try std.testing.expect(pool.idle());
}

test "固定池：随机分配/释放后活块内容完好、无重叠" {
    const alloc = std.testing.allocator;
    var buf: [64 * 1024]u8 align(HDR) = @splat(0);
    var pool = FixedPool.init(&buf);
    const a = pool.allocator();

    const Slot = struct { p: []u8, tag: u8, len: usize };
    var live = std.ArrayList(Slot).empty;
    defer live.deinit(alloc);

    var rng = std.Random.DefaultPrng.init(0x5EED_1234);
    var ops: usize = 0;
    while (ops < 4000) : (ops += 1) {
        const r = rng.random();
        const len: usize = switch (r.uintLessThan(u8, 4)) {
            0 => r.uintLessThan(usize, 16),
            1 => r.uintLessThan(usize, 64),
            2 => r.uintLessThan(usize, 512),
            else => r.uintLessThan(usize, 4096),
        };
        if (live.items.len > 0 and r.boolean()) {
            const i = r.uintLessThan(usize, live.items.len);
            const s = live.swapRemove(i);
            // 释放前校验内容未被踩
            for (s.p[0..s.len]) |byte| try std.testing.expectEqual(s.tag, byte);
            a.free(s.p);
        } else {
            const p = a.alloc(u8, len) catch continue;
            const tag: u8 = @truncate(ops *% 37 +% 11 +% 1);
            @memset(p, tag);
            try live.append(alloc, .{ .p = p, .tag = tag, .len = len });
        }
    }
    // 收尾：所有活块内容仍完好（证明分裂/复用没有把块写重叠）
    for (live.items) |s| {
        for (s.p[0..s.len]) |byte| try std.testing.expectEqual(s.tag, byte);
        a.free(s.p);
    }
    try std.testing.expect(pool.idle());
    try std.testing.expectEqual(@as(usize, 0), pool.unsupported_align);
    try std.testing.expect(pool.bytes_peak > 0);
}

test "固定池：resize 只在跨度不变时原地成功（跨度变了必须交回调用方）" {
    var buf: [4096]u8 align(HDR) = @splat(0);
    var pool = FixedPool.init(&buf);
    const a = pool.allocator();
    const p = try a.alloc(u8, 100);
    defer a.free(p);
    // 100 → 112 仍在同一 16 字节跨度内：可以原地
    try std.testing.expect(a.resize(p, 112));
    // 跨度变了就不许原地（否则 free 按新长度算出的跨度与真实块不符 → 后半截永久漏掉）
    try std.testing.expect(!a.resize(p, 200));
}

// ---------------------------------------------------------------------------
// KV 核心在**固定池**上跑通：D3d（`-Dalloc`）的机械证明
//
// 「我们把分配器做成可传入」不等于「固定池真的能用」——必须有一条用例，
// 全程用静态缓冲区（零系统堆）跑完 建表 → 写 → 点查 → 扫描 → flush → compact → 重开，
// 并在关闭后断言池子归还干净。
// ---------------------------------------------------------------------------
test "固定池：KV 核心全流程零系统堆可跑通，退出归还全部内存" {
    const alloc = std.testing.allocator; // 只用于测试自身的临时容器，不进引擎
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const root = "test-pool-kv";
    dir.deleteTree(io, root) catch {};
    defer dir.deleteTree(io, root) catch {};

    // 静态池：16MB，够这个工作负载（用例会断言峰值确实用到了有意义的量）
    const static_buf = try alloc.alignedAlloc(u8, .@"16", 16 * 1024 * 1024);
    defer alloc.free(static_buf);

    var pool = FixedPool.init(static_buf);
    const pool_alloc = pool.allocator();

    var opened = try tablemod.Table.open(io, dir, root, pool_alloc, .{ .flush_bytes = 1 << 30, .wal_sync_every = 0 });
    {
        var kbuf: [32]u8 = undefined;
        var vbuf: [64]u8 = undefined;
        // 两批 + 显式 flush ⇒ 两个段，后面的 compact 才会真的动手（段数 ≤ 1 时它早退）
        var i: usize = 0;
        while (i < 400) : (i += 1) {
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>5}", .{i});
            const v = try std.fmt.bufPrint(&vbuf, "value-{d:0>5}", .{i});
            try opened.put(k, v);
            if (i == 199) try opened.flush();
        }
        try opened.flush();
        try std.testing.expectEqual(@as(usize, 2), opened.segs.items.len);

        // 点查（命中 + 未命中）
        // **容器必须用与表相同的分配器释放**：`Table.get` 内部用 `self.alloc`（= 池）
        // 往调用方容器里 append，用测试分配器释放就是「free of invalid memory」。
        var out = std.ArrayList(u8).empty;
        defer out.deinit(pool_alloc);
        const got = try opened.get("k00123", &out);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("value-00123", got.?);
        out.clearRetainingCapacity();
        try std.testing.expectEqual(@as(?[]const u8, null), try opened.get("nope", &out));

        // 扫描（合并路径）
        var set = try opened.scanRange("", "");
        defer set.deinit();
        try std.testing.expectEqual(@as(usize, 400), set.records.len);

        // 合并（compact 会重写段与归档）
        const res = try opened.compact();
        try std.testing.expect(res.did);

        var set2 = try opened.scanRange("", "");
        defer set2.deinit();
        try std.testing.expectEqual(@as(usize, 400), set2.records.len);

        opened.deinit();
    }
    try std.testing.expect(pool.idle());

    // 重开（恢复路径同样只能用池）
    {
        var again = try tablemod.Table.open(io, dir, root, pool_alloc, .{ .flush_bytes = 1 << 30, .wal_sync_every = 0 });
        var out2 = std.ArrayList(u8).empty;
        defer out2.deinit(pool_alloc);
        const got = try again.get("k00399", &out2);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("value-00399", got.?);
        again.deinit();
    }
    try std.testing.expect(pool.idle());

    // 防空跑 + 边界：真用到了池子，且没有用池模式不支持的对齐
    try std.testing.expect(pool.bytes_peak > 1024);
    try std.testing.expectEqual(@as(usize, 0), pool.unsupported_align);
}

// ---------------------------------------------------------------------------
// 源码闸门：不许出现系统堆分配器
//
// `-Dalloc=false` 的语义是「引擎不依赖系统堆」。这个结论不能靠嘴说：
// 只要引擎模块里写了系统堆分配器（`std.` + `heap.` 下的 page / c 两种），本用例必须立刻红。
// `ArenaAllocator` 不算系统堆（它是对**传入分配器**的包装），所以允许。
//
// **两个必须处理的坑（第一版都踩了）**：
// ① 针要拼出来，否则本文件自己的注释/字面量会命中自己；
// ② 宿主侧程序（基准/尺寸探针）**不在约束范围内**，它们跑在开发机上、本来就用宿主分配器。
// ---------------------------------------------------------------------------
test "源码闸门：src/ 下不得出现系统堆分配器" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    var d = try dir.openDir(io, "src", .{ .iterate = true });
    defer d.close(io);

    var scanned: usize = 0;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        scanned += 1;

        // 宿主侧程序：跑在开发机上，本来就用宿主分配器，不在「无堆」约束范围内。
        var host_only = false;
        for ([_][]const u8{ "main.zig", "bench_ac.zig", "bench_scale.zig", "bench_vector.zig", "sizes.zig" }) |name| {
            if (std.mem.eql(u8, entry.name, name)) host_only = true;
        }
        if (host_only) continue;

        buf.clearRetainingCapacity();
        const f = try d.openFile(io, entry.name, .{});
        defer f.close(io);
        const size = (try f.stat(io)).size;
        try buf.resize(alloc, @intCast(size));
        const n = try f.readPositionalAll(io, buf.items, 0);
        try std.testing.expectEqual(buf.items.len, n);
        const text = buf.items;

        for ([_][]const u8{ "page_" ++ "allocator", "c_" ++ "allocator", "raw_c_" ++ "allocator" }) |bad| {
            if (std.mem.indexOf(u8, text, bad)) |pos| {
                const from = pos -| 60;
                const to = @min(pos + 60, text.len);
                std.debug.print("命中 {s} 于 src/{s}\n{s}\n", .{ bad, entry.name, text[from..to] });
                try std.testing.expect(false);
            }
        }
        // `-Dalloc=false`（固定池模式）额外收紧：只允许 ArenaAllocator 包装
        if (!build_options.alloc) {
            const heap_prefix = "std." ++ "heap.";
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, text, i, heap_prefix)) |pos| {
                const rest = text[pos + heap_prefix.len ..];
                try std.testing.expect(std.mem.startsWith(u8, rest, "ArenaAllocator"));
                i = pos + 1;
            }
        }
    }
    try std.testing.expect(scanned > 5); // 防空跑：真的扫到了源码
}
