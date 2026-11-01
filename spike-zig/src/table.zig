// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const Skiplist = @import("skiplist.zig").Skiplist;
const walmod = @import("wal.zig");
const segmod = @import("segment.zig");

const RecordOwned = segmod.RecordOwned;

pub const Options = struct {
    flush_bytes: usize = 64 << 20,
    wal_sync_every: usize = 10_000,
    /// 打开段时是否把整个数据文件读进页缓存（默认关：冷重开只加载索引，数据按需缺页）。
    mmap_preheat: bool = false,
    /// 新段索引的 Bloom 位数/key（0 = 不生成）。
    /// Bloom 占索引体积 ~80%，只对「不存在的 key」有用；关闭后冷重开与索引 IO 同步变小。
    bloom_bits: u8 = 10,
    /// 段数达到该值后，`flush` 结束时自动全量合并（**0 = 关闭，默认关闭**）。
    ///
    /// 只在 flush 之后检查，不起后台线程：写入抖动可预测（合并期间该次写变慢，
    /// 不会让别的线程随时被卡），也不需要双写 + 引用计数。
    ///
    /// **选值看 §16.1.7 的实测，不要凭「段数少就快」的直觉**：
    /// 不命中点查与段数**近似成反比**（25 段 1.66M / 10 段 3.58M / 4 段 9.21M / 1 段 30.8M 次/s），
    /// 并没有「≤8 段就可忽略」这回事 —— §16.1.6 里 7 段已比 2 段慢 3.3×。
    /// 写放大只由「总段数/阈值」决定、与数据总量无关（25 段下：阈值 16→1.6×、8→2.8×、4→5.7×）。
    /// 推荐：写多读少 16/0、均衡 8、读多写少 4。
    /// 注意它只控制**触发时机**，单次合并的阻塞时长仍随数据总量线性增长（分层合并才能治本）。
    compact_after_segs: usize = 0,
    /// **仅用于基准 A/B**：置 true 时禁用「顺序拼接」快路径，强制走 k 路堆归并。
    ///
    /// 为什么要这个开关：§16.1.22 的收益原本是拿「本批 25 段 ÷ 本批 1 段」的比值，
    /// 再跟**上一批**的同一个比值比，属于跨批次对照 —— 而本机该指标的批内波动就有
    /// 20–40%（同一轮里两者比值从 1.01 到 0.88 都出现过）。跨批次比值差 14% 完全可能是噪声。
    /// 有了这个开关就能在**同一进程、同一张表、背靠背交替**跑两种模式，得到配对结论。
    /// 生产路径永远留 false。
    no_concat: bool = false,
    /// **仅用于基准 A/B**：置 true 时禁用「反向段裁剪」（`maxKey() < start` 的整段跳过）。
    /// 同样是为了在同进程里拿到配对结论，生产路径永远留 false。
    no_prune_before: bool = false,
};

/// 自动 compaction 连续失败上限：到顶就停手，避免每次 flush 都白跑一遍合并。
/// **停手后不会自动恢复** —— 上层必须定期查 `autoCompactHealthy()`，
/// 排除原因（磁盘满/OOM 等）后调 `resetAutoCompact()` 重新启用。
const AUTO_COMPACT_MAX_FAILS: u8 = 5;

/// 范围扫描结果：records 的 key/value 均指向 buf（一次性大缓冲），deinit 只释放 2 块。
pub const RecordSet = struct {
    alloc: std.mem.Allocator,
    buf: []u8 = &.{},
    records: []RecordOwned = &.{},

    pub fn deinit(self: *RecordSet) void {
        self.alloc.free(self.buf);
        self.alloc.free(self.records);
        self.* = undefined;
    }
};

fn recLess(_: void, a: RecordOwned, b: RecordOwned) bool {
    const o = segmod.keyCmp(a.key, b.key);
    if (o != .eq) return o == .lt;
    return a.seq > b.seq;
}

fn refLess(_: void, a: segmod.Segment.RefRecord, b: segmod.Segment.RefRecord) bool {
    const o = segmod.keyCmp(a.key, b.key);
    if (o != .eq) return o == .lt;
    return a.seq > b.seq;
}

/// 能否走「顺序拼接」：memtable 为空，且相邻段的 `[firstKey, maxKey]` 严格不重叠。
///
/// 为什么值得单独判：§16.1.21 的确定性计数器显示，即使 25 段范围不重叠，
/// 堆归并仍要**每行 2 次比较 + 一次跨游标间接调用**（siftDown 首轮就 return，
/// 所以不是 log k）；而拼接后走单游标路径，比较次数为 0。
///
/// **memtable 非空时一律不走拼接**：它的 key 可能插在任意两段之间，拼接会乱序。
fn canConcat(table: *Table) bool {
    if (table.opts.no_concat) return false; // 基准 A/B 用，生产路径永不置位
    if (table.mem.len() > 0) return false;
    const segs = table.segs.items;
    if (segs.len <= 1) return false;
    var i: usize = 1;
    while (i < segs.len) : (i += 1) {
        // 空段（刚 flush 完还没写？）不影响顺序，直接跳过它
        const amax = segs[i - 1].maxKey() orelse continue;
        const bmin = segs[i].firstKey() orelse return false;
        // 前一段的最大 key 必须**严格小于**后一段的最小 key，否则可能有重叠 key
        if (segmod.keyCmp(amax, bmin) != .lt) return false;
    }
    return true;
}

const MemCursor = struct {    it: Skiplist.Iterator,
    end: []const u8,
    snapshot: u64,

    fn next(self: *MemCursor) ?segmod.Segment.RefRecord {
        while (self.it.next()) |e| {
            // 空 end = 无上界（compaction 全量归并）
            if (self.end.len > 0 and std.mem.order(u8, e.key, self.end) != .lt) return null;
            if (e.seq > self.snapshot) continue;
            return .{ .key = e.key, .seq = e.seq, .flags = e.flags, .value = e.value };
        }
        return null;
    }
};

const ScanCursor = union(enum) {
    mem: MemCursor,
    seg: segmod.RefCursor,

    fn next(self: *ScanCursor) ?segmod.Segment.RefRecord {
        return switch (self.*) {
            .mem => |*m| m.next(),
            .seg => |*s| s.next(),
        };
    }

    fn deinit(self: *ScanCursor, alloc: std.mem.Allocator) void {
        _ = alloc;
        switch (self.*) {
            .mem => {},
            .seg => |*s| s.deinit(),
        }
    }

    fn useStableKeys(self: *ScanCursor, arena: ?*segmod.KeyArena) void {
        switch (self.*) {
            .mem => {},
            .seg => |*s| s.it.sink = arena,
        }
    }
};

/// 从 `seg/index.bin`（索引聚合文件）打开全部段。
/// 一次 IO 拿到所有段的索引；数据文件仍然懒打开（见 `Segment.dataView`）。
/// `buf` 的所有权留在调用方（Table 持有），段里只存切片。
/// 返回**有效末尾偏移**（下次追加要从这里写，覆盖崩溃残片）。
fn openSegmentsFromArchive(
    io: std.Io,
    dir: std.Io.Dir,
    base_path: []const u8,
    buf: []const u8,
    alloc: std.mem.Allocator,
    preheat: bool,
    segs: *std.ArrayList(segmod.Segment),
) !OpenSegmentsResult {
    var it = segmod.ArchiveIter{ .buf = buf };
    var max_id: u64 = 0;
    while (it.next()) |rec| {
        var ta: u64 = 0;
        if (segmod.timing_enabled) ta = segmod.tick(io);
        const seg = try segmod.Segment.fromBytes(io, dir, base_path, rec.id, rec.payload, alloc, false, preheat);
        if (segmod.timing_enabled) {
            const tb = segmod.tick(io);
            segmod.timing.mkseg += tb - ta;
            ta = tb;
        }
        max_id = @max(max_id, rec.id);
        segs.append(alloc, seg) catch |e| {
            var s = seg;
            s.close();
            return e;
        };
        if (segmod.timing_enabled) segmod.timing.seg_append += segmod.tick(io) - ta;
    }
    return .{ .valid_end = it.validEnd(), .max_id = max_id };
}

pub const OpenSegmentsResult = struct {
    valid_end: u64,
    max_id: u64,
};

/// 单表引擎（试验版）：memtable + WAL + 不可变段。
pub const Table = struct {
    io: std.Io,
    dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    base_path: []u8,
    wal_path: []u8,
    /// 索引聚合文件路径（`seg/index.bin`）
    index_path: []u8,
    /// 从 index.bin 一次读入的全部段索引（段的 idx 指向这里）
    /// 索引归档的只读映射；`idx_archive` 就是它的一部分切片。
    /// 生命周期由 Table 持有：注销时 `destroy()`，compact 后置空。
    idx_map: ?segmod.IndexMap = null,
    idx_archive: []const u8 = &.{},
    /// index.bin 的有效末尾（下次追加从这里写，覆盖崩溃残片）
    index_valid_len: u64 = 8,
    mem: Skiplist,
    segs: std.ArrayList(segmod.Segment) = .empty,
    wal: walmod.Wal,
    seq: u64 = 0,
    visible: u64 = 0,
    next_seg: u64 = 1,
    pending: usize = 0,
    opts: Options = .{},
    /// `compact()` 正在执行：防止 flush 末尾的自动触发递归回来。
    going_compact: bool = false,
    /// 自动 compaction 最近一次失败的错误（成功后清空）。
    /// 写路径不因自动合并失败而报错（数据此时已落盘），但错误不能丢，留给上层可查。
    auto_compact_error: ?anyerror = null,
    /// 自动 compaction 连续失败次数（手动/自动合并成功后清零）。
    auto_compact_fails: u8 = 0,
    /// 自动触发并成功的合并次数（累计，供基准/运维观测）。
    auto_compact_count: u32 = 0,
    /// 写入（flush）产生的段字节总数：即「用户数据量」的口径。
    flush_bytes_total: u64 = 0,
    /// 合并累计重写的字节数（**含手动调 `compact()`**，所以叫 compact 而非 auto_compact）。
    /// 写放大 = (flush_bytes_total + compact_bytes_total) / flush_bytes_total，
    /// 是**确定性量**：不受磁盘/CPU 噪声影响，比计时可靠得多。
    /// 失败的合并不计入（它没产出可用段）。
    compact_bytes_total: u64 = 0,
    /// 扫描/归并**实际产出**的行数（累计）。
    /// 确定性指标：用来证明「LIMIT 提前终止」真的没白读，而不是靠计时猜。
    scan_rows_read: u64 = 0,
    /// 最近一次 `MergeIter.init` **实际建了几个游标**（段裁剪是否生效的可观测证据）。
    /// 「不裁剪只是慢、结果一样」，只看结果永远看不出裁剪有没有生效 —— 必须有这个计数。
    merge_cursors_built: usize = 0,
    /// 最近一次 `MergeIter.init` 中因「整段落在查询起点之前」而被跳过的段数。
    /// 与 `merge_cursors_built` 配对：段数 = 建游标数 + 反向剪掉的 + 正向剪掉的。
    merge_pruned_before: usize = 0,
    /// 归并累计**比较次数**。确定性指标：它不依赖计时器精度与机器噪声。
    /// 已用它证伪了「k 小改线性」的直觉 —— 见 `MergeIter.compares` 的注释。
    merge_compares_total: u64 = 0,
    /// `scanRefs` 收集记录时用的 key arena。
    ///
    /// 块内前缀压缩（`PEKZAG07`）后，压缩块里的 key 是**重建**到游标双缓冲的，
    /// 只在下一两行内有效；而 `scanRefs` 是把记录收集起来交给调用方之后才读，
    /// 所以必须拷到一份活过扫描的内存。用**分块 arena** 而不是 `ArrayList`：
    /// 分块不会搬地址，一遍就能定下稳定切片。
    key_arena: segmod.KeyArena = .{},

    pub fn open(
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        alloc: std.mem.Allocator,
        opts: Options,
    ) !Table {
        var t0: u64 = 0;
        if (segmod.timing_enabled) t0 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);

        const index_path = try alloc.print("{s}/seg/index.bin", .{path});
        errdefer alloc.free(index_path);

        // 索引文件读得到 ⇒ 库已初始化 ⇒ 目录一定存在，直接跳过 3 次 createDirPath
        // （实测 createDirPath × 3 在冷重开里占 0.2–0.8ms）。
        var idx_map: ?segmod.IndexMap = null;
        errdefer if (idx_map) |*m| m.destroy();
        var arch: []const u8 = &.{};
        const has_index = blk: {
            // mmap 而非读入堆：3.13MB 的 `readPositionalAll` 实测 1.0–1.6ms（内核拷贝），
            // 而 mmap 建映射 ~0.3ms，且只访问段头部时只缺页 25 页（~0.02ms）。
            // 这是 SQLite `sqlite3BtreeOpen` 只读第 1 页的同款做法。
            if (segmod.mapWholeFile(io, dir, index_path, 64 << 30)) |m| {
                idx_map = m;
                arch = m.bytes();
                break :blk true;
            } else |e| switch (e) {
                error.FileNotFound => break :blk false,
                else => return e,
            }
        };
        // 归档格式必须对得上：宁可报错，也不能把旧格式按新布局解析出乱数据
        try segmod.archiveCheckMagic(arch);

        if (!has_index) {
            // 新建库（或目录缺失）：把三层目录建好
            try dir.createDirPath(io, path);
            const wal_dir = try alloc.print("{s}/wal", .{path});
            defer alloc.free(wal_dir);
            try dir.createDirPath(io, wal_dir);
            const seg_dir = try alloc.print("{s}/seg", .{path});
            defer alloc.free(seg_dir);
            try dir.createDirPath(io, seg_dir);
        }

        if (segmod.timing_enabled) {
            const t1 = @as(u64, @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds));
            segmod.timing.dirs += t1 - t0;
            t0 = t1;
        }

        const base_path = try alloc.dupe(u8, path);
        errdefer alloc.free(base_path);
        const wal_path = try alloc.print("{s}/wal/000001.wal", .{path});
        errdefer alloc.free(wal_path);

        var mem = Skiplist.init(alloc);
        errdefer mem.deinit();

        var seq: u64 = 0;
        // 一次 open 同时拿到「重放内容」与「追加句柄」——旧代码是 `replay()` 读一次、
        // `openAppend()` 再开一次，同一个文件两次 open + 两次 stat
        // （Windows 上单次 open 实测 0.1–0.15ms，冷重开只剩 0.67ms 时占比过半）。
        var rw = try walmod.openReplay(io, dir, wal_path, alloc);
        defer rw.replay.deinit();
        errdefer rw.wal.close();
        for (rw.replay.batches.items) |b| {
            for (b.ops) |op| {
                try mem.insert(op.key, b.seq, op.flags, op.value);
            }
            seq = @max(seq, b.seq);
        }

        if (segmod.timing_enabled) {
            const t1 = @as(u64, @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds));
            segmod.timing.wal_replay += t1 - t0;
            t0 = t1;
        }

        // open 与 replay 已合并，`wal_open` 恒为 0；字段保留是为了不打断
        // 基准与文档里已有的分段口径（`big_recover_breakdown_ms`）。
        const wal = rw.wal;

        if (segmod.timing_enabled) {
            const t1 = @as(u64, @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds));
            segmod.timing.wal_open += t1 - t0;
            t0 = t1;
        }

        var segs: std.ArrayList(segmod.Segment) = .empty;
        errdefer {
            for (segs.items) |*s| s.close();
            segs.deinit(alloc);
        }

        const opened = try openSegmentsFromArchive(io, dir, path, arch, alloc, opts.mmap_preheat, &segs);
        const id: u64 = opened.max_id + 1;
        for (segs.items) |s| seq = @max(seq, s.max_seq);

        if (segmod.timing_enabled) {
            const t1 = @as(u64, @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds));
            segmod.timing.segs += t1 - t0;
        }

        return .{
            .io = io,
            .dir = dir,
            .alloc = alloc,
            .base_path = base_path,
            .wal_path = wal_path,
            .index_path = index_path,
            .idx_map = idx_map,
            .idx_archive = arch,
            .index_valid_len = opened.valid_end,
            .mem = mem,
            .segs = segs,
            .wal = wal,
            .seq = seq,
            .visible = seq,
            .next_seg = id,
            .opts = opts,
        };
    }

    pub fn deinit(self: *Table) void {
        for (self.segs.items) |*s| s.close();
        self.segs.deinit(self.alloc);
        if (self.idx_map) |*m| m.destroy();
        self.idx_map = null;
        self.idx_archive = &.{};
        self.key_arena.deinit(self.alloc);
        self.mem.deinit();
        self.wal.close();
        self.alloc.free(self.base_path);
        self.alloc.free(self.wal_path);
        self.alloc.free(self.index_path);
        self.* = undefined;
    }

    pub fn put(self: *Table, key: []const u8, value: []const u8) !void {
        self.seq += 1;
        const seq = self.seq;
        _ = try self.wal.append(seq, &.{.{ .flags = 0, .key = key, .value = value }});
        try self.mem.insert(key, seq, 0, value);
        self.visible = seq;
        self.pending += 1;
        if (self.opts.wal_sync_every > 0 and self.pending >= self.opts.wal_sync_every) {
            try self.wal.sync();
            self.pending = 0;
        }
        if (self.mem.sizeBytes() >= self.opts.flush_bytes) try self.flush();
    }

    pub fn delete(self: *Table, key: []const u8) !void {
        self.seq += 1;
        const seq = self.seq;
        _ = try self.wal.append(seq, &.{.{ .flags = 1, .key = key, .value = "" }});
        try self.mem.insert(key, seq, 1, "");
        self.visible = seq;
    }

    /// 批量写：一批一个 WAL 提交（对应 SQLite 的单事务批量插入）。
    pub fn putBatch(self: *Table, keys: []const []const u8, values: []const []const u8) !void {
        std.debug.assert(keys.len == values.len);
        self.seq += 1;
        const seq = self.seq;
        var ops: std.ArrayList(walmod.Op) = .empty;
        defer ops.deinit(self.alloc);
        try ops.ensureTotalCapacity(self.alloc, keys.len);
        for (keys, values) |k, v| {
            ops.appendAssumeCapacity(.{ .flags = 0, .key = k, .value = v });
        }
        _ = try self.wal.append(seq, ops.items);
        for (keys, values) |k, v| {
            try self.mem.insert(k, seq, 0, v);
        }
        self.visible = seq;
        try self.wal.sync();
    }

    pub fn get(self: *Table, key: []const u8, out: *std.ArrayList(u8)) !?[]const u8 {
        if (self.mem.get(key, self.visible)) |e| {
            if (e.flags != 0) return null;
            out.clearRetainingCapacity();
            try out.appendSlice(self.alloc, e.value);
            return out.items;
        }
        var i = self.segs.items.len;
        while (i > 0) {
            i -= 1;
            if (try self.segs.items[i].get(key, self.visible, out)) |flags| {
                if (flags != 0) return null;
                return out.items;
            }
        }
        return null;
    }

    /// 把 memtable 落盘。
    ///
    /// **注意语义**：开了 `compact_after_segs` 时，本函数末尾可能触发全量合并，
    /// 于是这一次 flush 的耗时可从微秒级变成数百毫秒（200 万行约 0.4–0.7 s）。
    /// 合并失败不影响本次 flush 成功（数据已落盘），错误记在 `auto_compact_error`。
    pub fn flush(self: *Table) !void {
        try self.flushImpl();
        self.maybeAutoCompact();
    }

    /// 自动 compaction 是否还能工作。到上限后就**不会**再自动合并（不会自动恢复），
    /// 上层应定期检查；排除原因（磁盘满 / OOM 等）后调 `resetAutoCompact()`。
    pub fn autoCompactHealthy(self: *const Table) bool {
        return self.auto_compact_fails < AUTO_COMPACT_MAX_FAILS;
    }

    /// 重置自动 compaction 的失败状态，让它重新尝试。
    pub fn resetAutoCompact(self: *Table) void {
        self.auto_compact_fails = 0;
        self.auto_compact_error = null;
    }

    /// 段数达到 `compact_after_segs` 就自动全量合并。
    /// 合并失败**不让本次写失败**（数据已经落盘、WAL 已同步），错误记到
    /// `auto_compact_error` 供上层查询；连续失败到上限就停手，避免每次 flush 都白跑。
    ///
    /// 返回 void（内部 catch）：不把 compact 的错误集传染给写路径。
    /// 代价：写路径看不到合并失败，**上层必须自己查 `autoCompactHealthy()` / `auto_compact_error`**，
    /// 否则自动合并会静默失效。
    fn maybeAutoCompact(self: *Table) void {
        if (self.opts.compact_after_segs == 0) return;
        if (self.going_compact) return; // compact 内部的 flush 不得递归触发
        if (self.segs.items.len < self.opts.compact_after_segs) return;
        if (self.auto_compact_fails >= AUTO_COMPACT_MAX_FAILS) return;
        const cr = self.compact() catch |e| {
            self.auto_compact_error = e;
            self.auto_compact_fails +|= 1;
            return;
        };
        // 只在真的合并了才计数：段数 ≤ 1 时 compact() 会直接返回 did = false，
        // 不判这个就会在 compact_after_segs = 1 下每次 flush 都虚增 1 次
        if (cr.did) self.auto_compact_count +|= 1;
    }

    /// 真正落盘。返回 `anyerror` 是**有意**的：`compact()` 也要先落盘，
    /// 若两边都用推断错误集就会形成 `flush ↔ compact` 的依赖环（`error: dependency loop`）。
    fn flushImpl(self: *Table) anyerror!void {
        if (self.mem.len() == 0) return;
        const id = self.next_seg;
        const data_path = try self.alloc.print("{s}/seg/{d:0>6}.data", .{ self.base_path, id });
        defer self.alloc.free(data_path);
        // **不要**在这条路上 errdefer 删 .data：`archiveAppend` 是「写 record → setLength → sync」，
        // sync 失败时磁盘上已经有完整 record，只是 `index_valid_len` 没更新；
        // 此时删掉文件就成了「归档 record 指向不存在的 .data」→ 下次 open 报 FileNotFound。
        // 不删代价只是多一个文件，而且 `next_seg` 没递增、下次 flush 会用同一路径覆盖，天然自愈；
        // 万一是「写成功但没回传」的情况，保留它反而能恢复到一致状态。

        var w = try segmod.Writer.create(self.io, self.dir, data_path, self.alloc, self.opts.bloom_bits, self.mem.len());
        defer w.deinit();
        var it = self.mem.iterator();
        while (it.next()) |e| {
            try w.push(e.key, e.seq, e.flags, e.value);
        }
        // 数据文件字节（buf_base = 已写出的，buf.items.len = 还没写的）
        const data_bytes = w.buf_base + w.buf.items.len;
        // 索引：追加到聚合文件（一次小写），并直接接管内存字节，不重复读盘
        const fin = try w.finishBytes();
        errdefer self.alloc.free(fin.bytes);
        // 从「有效末尾」写：若上次追加留下崩溃残片，这里会把它覆盖掉
        self.index_valid_len = try segmod.archiveAppend(self.io, self.dir, self.index_path, @intCast(id), fin.bytes, self.index_valid_len);

        const seg = try segmod.Segment.fromBytes(self.io, self.dir, self.base_path, id, fin.bytes, self.alloc, true, self.opts.mmap_preheat);
        self.segs.append(self.alloc, seg) catch |e| {
            // 别在这里 free(fin.bytes)：交给上面的 errdefer，否则 double free
            var s = seg;
            s.owns_idx = false;
            s.close();
            return e;
        };
        self.next_seg = id + 1;

        self.mem.reset();

        try self.wal.sync();
        self.wal.close();
        self.dir.deleteFile(self.io, self.wal_path) catch {};
        self.wal = try walmod.Wal.create(self.io, self.dir, self.wal_path, self.alloc);
        self.pending = 0;

        // 计数放最后：上面的 WAL 同步若失败，调用方会重试 flush，
        // 提前累加会让同一批数据被统计两次（写放大失真）。
        self.flush_bytes_total += data_bytes + fin.bytes.len;
    }
    pub fn scanRange(
        self: *Table,
        start: []const u8,
        end: []const u8,
    ) !RecordSet {
        // 第一遍：只统计条数与总字节，**不收集任何记录**。
        //
        // 旧实现是「scanRefs 收集全部 RefRecord（48B/条，20 万行 = 9.6MB 写入）
        // → 算 total → 分配 buf → 再把它们逐条复制进 buf → 扔掉 refs」。
        // 中间那 9.6MB 纯粹是为了「知道 buf 多大」而付的，扫两遍就能完全省掉。
        // 代价是多走一遍 k 路归并：`count_range` 档实测 55.5M 行/s（20 万行 3.6ms），
        // 而收集那 9.6MB 要 7.6ms（`count_range` → `scan_refs_full` 的落差，见 §16.1.14）。
        var n: usize = 0;
        var total: usize = 0;
        {
            var it = MergeIter{};
            try it.init(self, start, end);
            defer it.deinit();
            while (it.next()) |rec| {
                n += 1;
                total += rec.key.len + rec.value.len;
            }
        }

        const buf = try self.alloc.alloc(u8, total);
        errdefer self.alloc.free(buf);
        const records = try self.alloc.alloc(RecordOwned, n);
        errdefer self.alloc.free(records);

        // 第二遍：边遍历边填，不再产生中间数组。
        //
        // 两遍必须产出一致的结果：`MergeIter` 对同一 snapshot 是确定性的，且约定
        // 「扫描期间不得写」。但 **`std.debug.assert` 在 ReleaseFast 下会被抹掉** ——
        // 万一真有人违反契约（并发写让 memtable 变大），第二遍就会**越界写**
        // records/buf，那是静默的内存破坏而不是报错。所以用运行时检查 + 明确错误。
        var off: usize = 0;
        var i: usize = 0;
        {
            var it = MergeIter{};
            try it.init(self, start, end);
            defer it.deinit();
            while (it.next()) |r| {
                if (i >= n) return error.ConcurrentModification;
                if (off + r.key.len + r.value.len > total) return error.ConcurrentModification;
                const k = buf[off..][0..r.key.len];
                @memcpy(k, r.key);
                off += r.key.len;
                const v = buf[off..][0..r.value.len];
                @memcpy(v, r.value);
                off += r.value.len;
                records[i] = .{ .key = k, .seq = r.seq, .flags = r.flags, .value = v };
                i += 1;
            }
        }
        // 变少了也算违约：否则返回的 records 会是 n 条、后半段是未初始化内存。
        if (i != n) return error.ConcurrentModification;
        std.debug.assert(off == total);
        return .{ .alloc = self.alloc, .buf = buf, .records = records };
    }
    /// 通用 refs 扫描：memtable + 所有段的 k 路归并（值零拷贝借用；调用期间不得写）。
    ///
    /// **key 有效期**：指向本表内部的 `key_slab`，在下一次 `scanRefs` 之前都可用（value 不受影响）。
    pub fn scanRefs(self: *Table, start: []const u8, end: []const u8, out: *std.ArrayList(segmod.Segment.RefRecord)) !void {
        self.key_arena.reset(self.alloc);
        var it = MergeIter{};
        try it.initStable(self, start, end, &self.key_arena);
        defer it.deinit();
        while (it.next()) |rec| try out.append(self.alloc, rec);
    }

    /// 只收集 **value 切片**（不收集 key / seq / flags）。
    ///
    /// `RefRecord` 是 48 字节（key 16 + seq 8 + flags 1 + padding + value 16），
    /// 而「全表解码」这类消费方只用得到 `value`（16 字节）。100 万行时输出量
    /// 从 48MB 降到 16MB —— 实测 `scanRefs` 占了物化总耗时的 66%，写少 2/3 就是最值钱的一刀。
    ///
    /// 语义与 `scanRefs` 完全一致（同一套 `MergeIter` 去重、同一可见性规则），
    /// 只是不往外抛 key。需要 key 的调用方仍用 `scanRefs`。
    pub fn scanValues(self: *Table, start: []const u8, end: []const u8, out: *std.ArrayList([]const u8)) !void {
        var it = MergeIter{};
        try it.init(self, start, end);
        defer it.deinit();
        while (it.next()) |rec| try out.append(self.alloc, rec.value);
    }

    /// 全量合并：把全部段重写成一个新段。
    /// - 只保留每个 key 的最新可见版本，**墓碑直接丢弃**（全量合并后不再需要）
    /// - 重建 `index.bin`（用临时文件 + rename，崩溃时不会留下半个归档）
    /// - 删除旧段数据文件
    /// 内存是流式的：不为全部结果分配缓冲（200 万行时那是 100MB+）。
    pub fn compact(self: *Table) !CompactResult {
        if (self.segs.items.len <= 1) {
            return .{ .before = self.segs.items.len, .after = self.segs.items.len, .rows = 0, .did = false };
        }

        // 防重入：下面会调 flush()，而 flush() 末尾可能触发自动合并 ——
        // 不抑制就是无限递归（手动调 compact() 也一样）。
        // 用 `was` 保留外层状态：自动触发 → compact → 内部 flush 期间标志必须仍为 true。
        const was_going = self.going_compact;
        self.going_compact = true;
        defer self.going_compact = was_going;

        // 先把 memtable 落盘，避免「合并结果 + memtable」重复持有同一批 key
        // （调 flushImpl 而非 flush：flush 末尾的自动触发会绕回 compact）
        if (self.mem.len() > 0) try self.flushImpl();
        const before = self.segs.items.len;

        const id = self.next_seg;
        const data_path = try self.alloc.print("{s}/seg/{d:0>6}.data", .{ self.base_path, id });
        defer self.alloc.free(data_path);
        // 合并中途失败时新段是半成品：删掉它。
        // 这里能删、`flushImpl` 里不能删，差别在**失败时权威记录有没有变**：
        // `archiveRewrite` 是「写 tmp → sync → rename」，任何一步失败都意味着归档原封未动；
        // 而 `archiveAppend` 在 sync 之前就已把 record 写进文件了。
        var orphan_maybe = true;
        errdefer if (orphan_maybe) self.dir.deleteFile(self.io, data_path) catch {};

        // Bloom 位图要预先定大小，这里给一个上界：各段行数之和（去重后只会更少）。
        // 估大只会让位图偏大（误报率更低）；估小也不出错，见 `Writer.create` 的说明。
        var expected_rows: usize = 0;
        for (self.segs.items) |s| expected_rows +|= s.rows;

        var w = try segmod.Writer.create(self.io, self.dir, data_path, self.alloc, self.opts.bloom_bits, expected_rows);
        defer w.deinit();
        var rows: usize = 0;
        {
            var it = MergeIter{};
            try it.init(self, &.{}, &.{}); // 无下界、无上界
            defer it.deinit();
            while (it.next()) |rec| {
                try w.push(rec.key, rec.seq, rec.flags, rec.value);
                rows += 1;
            }
        }
        // 必须在 finishBytes() **之前**取：它会接管/释放 Writer 的缓冲
        const data_bytes: u64 = @intCast(w.buf_base + w.buf.items.len);
        const fin = try w.finishBytes();
        errdefer self.alloc.free(fin.bytes);
        const out_bytes: u64 = data_bytes + fin.bytes.len;

        // 关键次序：**先在内存里建好新段**（验证索引可解析），再改磁盘，最后才清理旧段。
        // 若反过来（先清旧段再建新段），中途失败会让 Table 变成空表，而磁盘上归档已指向新段。
        var new_seg = try segmod.Segment.fromBytes(self.io, self.dir, self.base_path, id, fin.bytes, self.alloc, true, self.opts.mmap_preheat);
        // errdefer 必须在 ensureParsed **之前**注册：校验失败时段的 `entries` 已经分配，
        // 而 `fromBytes` 内部的 errdefer 只覆盖它自己那一段，管不到这里。
        errdefer {
            var s = new_seg;
            s.owns_idx = false; // 字节由上面的 errdefer 释放
            s.close();
        }
        // **懒解析之后这一句是关键**：`fromBytes` 现在只读头部、不做 CRC 校验，
        // 而 compact 的整个安全性都建立在「动手改磁盘之前，先确认新段索引真能解析」之上
        // （上面那条注释写的就是这件事）。不在这里强制全量校验，就等于把
        // 「归档已指向新段」和「新段索引是否完好」这两件事脱钩了。
        try new_seg.ensureParsed();

        // 重建归档（临时文件 + 原子 rename）：成功后磁盘才指向新段
        const records = [_]segmod.ArchiveRecord{.{ .id = @intCast(id), .payload = fin.bytes }};
        self.index_valid_len = try segmod.archiveRewrite(self.io, self.dir, self.index_path, &records, self.alloc);
        orphan_maybe = false; // 归档已指向新段

        // 磁盘已一致，现在才清理旧段与旧归档缓冲。
        // 这里**不允许再有可能失败的分配**：一旦在这之后返回错误，归档指向新段
        // 而内存 segs 已清空 → Table 变空表（上轮审计 P0-2 的那类状态）。
        var del_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (self.segs.items) |*s| {
            const old_id = s.id;
            s.close();
            const op = std.fmt.bufPrint(&del_buf, "{s}/seg/{d:0>6}.data", .{ self.base_path, old_id }) catch continue;
            self.dir.deleteFile(self.io, op) catch {};
        }
        self.segs.clearRetainingCapacity();
        if (self.idx_map) |*m| m.destroy();
        self.idx_map = null;
        self.idx_archive = &.{};

        // 用 assumeCapacity：`segs` 刚装过 ≥2 个元素、容量一定够，append 不会重分配。
        // 若这里用 append 而它恰好失败，磁盘归档已指向新段、旧段已删、segs 已空
        // —— Table 会变成空表（上轮审计 P0-2 的残留路径）。
        self.segs.appendAssumeCapacity(new_seg);
        self.next_seg = id + 1;

        // 合并成功：清除自动触发积累的失败状态
        self.auto_compact_error = null;
        self.auto_compact_fails = 0;
        self.compact_bytes_total += out_bytes;

        return .{ .before = before, .after = self.segs.items.len, .rows = rows, .bytes = out_bytes, .did = true };
    }
};

pub const CompactResult = struct {
    before: usize,
    after: usize,
    rows: usize,
    /// 本次合并写出的段字节数（算写放大用，确定性量、不受磁盘噪声影响）
    bytes: u64 = 0,
    /// 是否真的做了合并。**段数 ≤ 1 时直接返回 false** —— 调用方不能拿
    /// `before == after` 去判断（空表合并也是 before == after == 1 但 did = true）。
    did: bool = false,
};

/// memtable + 所有段的流式 k 路归并：按 (key asc, seq desc) 产出**可见**记录，
/// 同一 key 只产出一次（seq 最大的可见版本），墓碑跳过。
pub const MergeIter = struct {
    table: *Table = undefined,
    cursors: std.ArrayList(ScanCursor) = .empty,
    cur: []?segmod.Segment.RefRecord = &.{},
    /// 顺序拼接：段 key 范围两两不重叠时，同一时刻只需 1 个活跃游标
    /// （见 `canConcat`）。此时完全不走堆，直接复用单游标逻辑。
    concat: bool = false,
    concat_i: usize = 0,
    /// 最小堆，存的是 `cur` 的下标（按当前记录 key 排序）。
    ///
    /// 原来每产出一行要**线性扫一遍全部游标**找最小 —— O(k)/行。实测 200 万行 25 段时
    /// 全表遍历只有 6.45M 行/s，而同一张表合并成单段后是 **28.9M（4.48×）**，
    /// 差距全部来自这 25 次比较。改成堆后是 O(log k)，k=25 时约 5 层。
    heap: []usize = &.{},
    heap_len: usize = 0,
    /// 本次归并的**比较次数**。确定性指标：不依赖计时，用来判断
    /// 「某个归并改动到底有没有减少实际工作」。
    ///
    /// 已量化：k=2 重叠两段、20 万行时恒为 **399,999**（= 2×200000−1），与实现无关 ——
    /// 这是「归并不得不做的比较数」的下界。
    ///
    /// 曾据此想「k 小改用线性选最小」，但那次 A/B 两边一边冷一边热
    /// （线性跑第一次、堆跑预热后的第二次），得到的 50% 差异是假的，**该方向已放弃**，
    /// 代码里只保留堆。要重试必须两边都预热后再比。
    compares: u64 = 0,
    /// 上一个**产出**的 key。
    ///
    /// **块内前缀压缩之后必须拷贝**（`PEKZAG06`）：段游标重建出来的 key 指向游标
    /// 的双缓冲，而「上一个产出」可能距当前行 2 行以上（同 key 的多个版本被跳过的场景）——
    /// 那时双缓冲可能刚好轮回到同一个 buffer 把它覆盖掉，比较就退化成「自己和自己比」
    /// → 误判重复 → **整行丢失**。`last_buf` 容量按段头里的 `max_klen` 预留，永远够。
    last_buf: []u8 = &.{},
    last_key: []const u8 = &.{},
    have_last: bool = false,

    /// 记下本行 key。传进来的 key 可能指向游标双缓冲（会被覆写），所以必须拷贝。
    inline fn setLast(self: *MergeIter, key: []const u8) void {
        if (key.len > self.last_buf.len) {
            // 只有 memtable 的 key 会走到这里（段内 key 长度由 `max_klen` 精确限定），
            // 而 memtable 的 key 切片是稳定的，直接引用是安全的。
            self.last_key = key;
        } else {
            @memcpy(self.last_buf[0..key.len], key);
            self.last_key = self.last_buf[0..key.len];
        }
        self.have_last = true;
    }

    pub fn init(self: *MergeIter, table: *Table, start: []const u8, end: []const u8) !void {
        try self.initStable(table, start, end, null);
    }

    /// `arena != null` 时，压缩块重建出来的 key 直接落进 arena（稳定切片，供收集型 API 使用）。
    /// **必须在建游标之前设定**：堆模式下 `init` 末尾会预读每条游标的第 1 条记录，
    /// 那批 key 若落在双缓冲里，后续推进就会把它们覆盖。
    pub fn initStable(self: *MergeIter, table: *Table, start: []const u8, end: []const u8, arena: ?*segmod.KeyArena) !void {
        self.* = .{ .table = table };
        const alloc = table.alloc;
        var pruned_before: usize = 0;
        // init 中途失败时要自己清干净：调用方是在 init 成功后才注册 defer deinit 的
        errdefer self.deinit();
        // `last_key` 的稳定副本：容量取「段头里记录的最大 key 长度」上界
        {
            var mk: usize = 0;
            for (table.segs.items) |*s| mk = @max(mk, @as(usize, s.max_klen));
            if (mk > 0) self.last_buf = try alloc.alloc(u8, mk);
        }
        if (table.mem.len() > 0) {
            try self.cursors.append(alloc, .{ .mem = .{
                .it = table.mem.iteratorFrom(start),
                .end = end,
                .snapshot = table.visible,
            } });
        }
        for (table.segs.items) |*s| {
            // **反向段裁剪**（§16.1.23）：段内最大 key 都小于查询起点 → 整段不可能命中。
            //
            // 判据是段头里**精确**的 `maxKey()`（§16.1.22 才加的），不是稀疏索引的近似值 ——
            // 段头之前就只能剪「段在查询之后」那一侧，因为稀疏索引最后几行没有索引项。
            //
            // 收益不只在大表：`s.cursor()` 里每段都要 `ensureParsed()`（整段 CRC）+
            // `dataView()`（open + mmap，平台成本 ~0.3ms/段）。冷重开后的窄范围查询
            // 以前要为「一行都不命中」的段付这笔钱，现在是零。
            if (start.len > 0 and !table.opts.no_prune_before) {
                if (s.maxKey()) |k1| {
                    if (segmod.keyCmp(k1, start) == .lt) {
                        pruned_before += 1;
                        continue;
                    }
                }
            }
            // **正向段裁剪**：稀疏索引的第 0 条就是段内最小的 key。若它已经排到查询上界之后，
            // 整段不可能命中，连游标都不必建 —— 建了不用也要付「每行多一路归并」的钱。
            //
            // 实测背景：200 万行、25 段时纯遍历只有 7.26M 行/s，而单段表能到 11–17M；
            // 顺序写入的段 key 范围几乎不重叠，这一刀能砍掉大部分路数。
            if (end.len > 0) {
                // 用 `firstKey()`（段头部就有，不需要 `ensureParsed`）——
                // 冷重开只解析头部，裁剪判定的信息已经够了。
                if (s.firstKey()) |k0| {
                    if (segmod.keyCmp(k0, end) != .lt) continue;
                }
            }
            const c = try s.cursor(start, end, table.visible);
            var sc = ScanCursor{ .seg = c };
            sc.useStableKeys(arena);
            try self.cursors.append(alloc, sc);
        }
        if (self.cursors.items.len > 1 and canConcat(table)) {
            // 顺序拼接：段 key 范围两两不重叠且有序 → 按段依次耗尽游标。
            // §16.1.21 实测：25 路归并每行 2 次比较 + 一次跨游标间接调用，
            // 走拼接后这些全免（与单段同速）。
            // **不建 cur** —— 建了就得预读，而拼接路径要自己控制游标。
            self.concat = true;
        } else if (self.cursors.items.len > 1) {
            self.cur = try alloc.alloc(?segmod.Segment.RefRecord, self.cursors.items.len);
            for (self.cursors.items, 0..) |*c, i| self.cur[i] = c.next();

            // 建堆：只把有记录的游标放进去，按当前 key 做一次 heapify（O(k)）。
            self.heap = try alloc.alloc(usize, self.cursors.items.len);
            for (self.cur, 0..) |maybe, i| {
                if (maybe == null) continue;
                self.heap[self.heap_len] = i;
                self.heap_len += 1;
            }
            if (self.heap_len > 1) {
                var i = self.heap_len / 2;
                while (i > 0) {
                    i -= 1;
                    self.siftDown(i);
                }
            }
        }
        // 诊断：本次归并实际建了几个游标。段裁剪有没有生效必须**能观测**，
        // 否则「结果对」不代表「真的剪了整段」（不剪只是慢，结果一样）。
        table.merge_cursors_built = self.cursors.items.len;
        table.merge_pruned_before = pruned_before;
    }

    /// 堆内比较必须用 `refLess`（它含「同 key 时 seq 大的在前」），
    /// **不能只比 key** —— 只比 key 会让同 key 的旧版本排在前面，
    /// 实测会直接让 compaction/scan 的用例读到 v1a 而不是 v1b。
    inline fn lessAt(self: *MergeIter, a: usize, b: usize) bool {
        self.compares += 1;
        return refLess({}, self.cur[self.heap[a]].?, self.cur[self.heap[b]].?);
    }


    /// 顺序拼接：段间 key 范围不重叠时，同一时刻只需 1 个活跃游标，
    /// 走与单游标完全相同的逻辑（无比较、无堆维护）。
    fn nextConcat(self: *MergeIter) ?segmod.Segment.RefRecord {
        while (true) {
            if (self.concat_i >= self.cursors.items.len) return null;
            while (self.cursors.items[self.concat_i].next()) |rec| {
                if (self.have_last and std.mem.eql(u8, rec.key, self.last_key)) continue;
                self.setLast(rec.key);
                self.table.scan_rows_read += 1;
                if (rec.flags == 0) return rec;
            }
            self.concat_i += 1;
        }
    }

    fn siftDown(self: *MergeIter, start: usize) void {
        var i = start;
        while (true) {
            const l = 2 * i + 1;
            if (l >= self.heap_len) return;
            const r = l + 1;
            var smallest = l;
            if (r < self.heap_len and self.lessAt(r, l)) smallest = r;
            if (!self.lessAt(smallest, i)) return;
            std.mem.swap(usize, &self.heap[i], &self.heap[smallest]);
            i = smallest;
        }
    }

    pub fn deinit(self: *MergeIter) void {
        if (self.cur.len > 0) self.table.alloc.free(self.cur);
        if (self.heap.len > 0) self.table.alloc.free(self.heap);
        if (self.last_buf.len > 0) self.table.alloc.free(self.last_buf);
        for (self.cursors.items) |*c| c.deinit(self.table.alloc);
        self.cursors.deinit(self.table.alloc);
        self.table.merge_compares_total += self.compares;
    }

    pub fn next(self: *MergeIter) ?segmod.Segment.RefRecord {
        // 单游标（单段或仅 memtable）：顺序去重，省掉 k 路选择开销
        if (self.cursors.items.len == 1) {
            while (self.cursors.items[0].next()) |rec| {
                if (self.have_last and std.mem.eql(u8, rec.key, self.last_key)) continue;
                self.setLast(rec.key);
                self.table.scan_rows_read += 1;
                if (rec.flags == 0) return rec;
            }
            return null;
        }
        if (self.concat) return self.nextConcat();
        while (true) {
            if (self.heap_len == 0) return null;
            const bi = self.heap[0];
            const rec = self.cur[bi].?;

            // 推进刚取走的那个游标，再把它放回堆里；游标耗尽则把堆尾挪到根。
            self.cur[bi] = self.cursors.items[bi].next();
            if (self.cur[bi] == null) {
                self.heap_len -= 1;
                if (self.heap_len > 0) self.heap[0] = self.heap[self.heap_len];
            }
            if (self.heap_len > 1) self.siftDown(0);

            if (self.have_last and std.mem.eql(u8, rec.key, self.last_key)) continue;
            self.setLast(rec.key);
            self.table.scan_rows_read += 1;
            if (rec.flags == 0) return rec;
        }
    }
};

test "table put/get/flush/reopen" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-tmp";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        try t.put("a", "va");
        try t.put("b", "vb");
        try t.put("b", "vb2");
        try std.testing.expectEqualStrings("vb2", (try t.get("b", &out)).?);
        try t.flush();
        try std.testing.expectEqualStrings("vb2", (try t.get("b", &out)).?);
        try t.delete("a");
        try std.testing.expect((try t.get("a", &out)) == null);
    }

    var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t2.deinit();
    try std.testing.expectEqualStrings("vb2", (try t2.get("b", &out)).?);
    try std.testing.expect((try t2.get("a", &out)) == null);

    var set = try t2.scanRange("a", "z");
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.records.len);
    try std.testing.expectEqualStrings("b", set.records[0].key);
}

test "table reopen: 懒加载 / 预热 / 并行 三种打开方式结果一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-reopen-modes";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // 写 10 个段（超过并行批大小 8，覆盖第二批与缺号终止）
    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        var seg_i: usize = 0;
        while (seg_i < 10) : (seg_i += 1) {
            var r: usize = 0;
            while (r < 20) : (r += 1) {
                var kb: [16]u8 = undefined;
                var vb: [16]u8 = undefined;
                const k = try std.fmt.bufPrint(&kb, "k{d:0>3}_{d:0>2}", .{ seg_i, r });
                const v = try std.fmt.bufPrint(&vb, "v{d:0>3}_{d:0>2}", .{ seg_i, r });
                try t.put(k, v);
            }
            try t.flush();
        }
        try std.testing.expectEqual(@as(usize, 10), t.segs.items.len);
    }

    const modes = [_]struct { name: []const u8, opts: Options }{
        .{ .name = "lazy", .opts = .{ .wal_sync_every = 0 } },
        .{ .name = "preheat", .opts = .{ .wal_sync_every = 0, .mmap_preheat = true } },
    };
    for (modes) |m| {
        var t = try Table.open(io, dir, tmp, alloc, m.opts);
        try std.testing.expectEqual(@as(usize, 10), t.segs.items.len);
        try std.testing.expectEqualStrings("v003_07", (try t.get("k003_07", &out)).?);
        try std.testing.expectEqualStrings("v009_19", (try t.get("k009_19", &out)).?);
        try std.testing.expect((try t.get("nope", &out)) == null);

        var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
        defer refs.deinit(alloc);
        try t.scanRefs("k000_00", "k010_00", &refs);
        try std.testing.expectEqual(@as(usize, 200), refs.items.len);
        t.deinit();
    }
}

test "index.bin 尾部残片后新增段必须仍可见（崩溃一致性）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-torn-index";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    // 1) 写两段
    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        try t.put("a", "va");
        try t.flush();
        try t.put("b", "vb");
        try t.flush();
        t.deinit();
    }

    // 2) 往 index.bin 尾部追加垃圾，模拟「追加 record 写到一半崩溃」留下的残片
    {
        const p = tmp ++ "/seg/index.bin";
        const ro = try dir.openFile(io, p, .{});
        const size = (try ro.stat(io)).size;
        ro.close(io);
        const w = try dir.createFile(io, p, .{ .read = true, .truncate = false });
        try w.writePositionalAll(io, "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a", size);
        w.close(io);
    }

    // 3) 重开：两段仍可见，数据正确
    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        try std.testing.expectEqual(@as(usize, 2), t.segs.items.len);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try std.testing.expectEqualStrings("vb", (try t.get("b", &out)).?);
        // 4) 残片之后继续写第三段
        try t.put("c", "vc");
        try t.flush();
        t.deinit();
    }

    // 5) 再重开：三段都必须可见（否则就是「崩溃后新数据永久丢失」）
    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        try std.testing.expectEqual(@as(usize, 3), t.segs.items.len);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try std.testing.expectEqualStrings("vc", (try t.get("c", &out)).?);
    }
}

test "bloom_bits 0 与 10 的读写结果必须一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const cases = [_]struct { path: []const u8, bits: u8 }{
        .{ .path = "test-table-bloom10", .bits = 10 },
        .{ .path = "test-table-bloom0", .bits = 0 },
    };
    defer for (cases) |c| dir.deleteTree(io, c.path) catch {};

    var i: u64 = 0;
    for (cases) |c| {
        dir.deleteTree(io, c.path) catch {};
        var t = try Table.open(io, dir, c.path, alloc, .{ .wal_sync_every = 0, .bloom_bits = c.bits });
        // 20 行，覆盖多个稀疏索引区间
        i = 0;
        while (i < 20) : (i += 1) {
            var kb: [8]u8 = undefined;
            var vb: [8]u8 = undefined;
            const k = try std.fmt.bufPrint(&kb, "k{d:0>3}", .{i});
            const v = try std.fmt.bufPrint(&vb, "v{d:0>3}", .{i});
            try t.put(k, v);
        }
        try t.flush();
        t.deinit();

        // 重开（读路径不依赖写入时的 bloom 配置）
        var t2 = try Table.open(io, dir, c.path, alloc, .{ .wal_sync_every = 0 });
        defer t2.deinit();

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        // 全部命中且值正确
        i = 0;
        while (i < 20) : (i += 1) {
            var kb: [8]u8 = undefined;
            var vb: [8]u8 = undefined;
            const k = try std.fmt.bufPrint(&kb, "k{d:0>3}", .{i});
            const want = try std.fmt.bufPrint(&vb, "v{d:0>3}", .{i});
            try std.testing.expectEqualStrings(want, (try t2.get(k, &out)).?);
        }
        // 不存在的 key 必须返回 null（bloom=0 时靠二分+扫块判断）
        try std.testing.expect((try t2.get("k999", &out)) == null);
        try std.testing.expect((try t2.get("aaa", &out)) == null);
        try std.testing.expect((try t2.get("zzz", &out)) == null);

        // 范围扫描结果一致
        var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
        defer refs.deinit(alloc);
        try t2.scanRefs("k000", "k020", &refs);
        try std.testing.expectEqual(@as(usize, 20), refs.items.len);
        try std.testing.expectEqualStrings("k000", refs.items[0].key);
        try std.testing.expectEqualStrings("v019", refs.items[19].value);
    }
}

test "compact 合并多段后数据一致（含更新与墓碑）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-compact";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });

        // 先落 5 段，每段 10 行
        var seg_i: usize = 0;
        while (seg_i < 5) : (seg_i += 1) {
            var r: usize = 0;
            while (r < 10) : (r += 1) {
                var kb: [16]u8 = undefined;
                var vb: [16]u8 = undefined;
                const k = try std.fmt.bufPrint(&kb, "k{d:0>2}_{d:0>2}", .{ seg_i, r });
                const v = try std.fmt.bufPrint(&vb, "v{d:0>2}_{d:0>2}", .{ seg_i, r });
                try t.put(k, v);
            }
            try t.flush();
        }
        try std.testing.expectEqual(@as(usize, 5), t.segs.items.len);

        // 再产生一段：更新一行 + 删除一行
        try t.put("k00_00", "UPDATED");
        try t.delete("k02_03");
        try t.flush();
        try std.testing.expectEqual(@as(usize, 6), t.segs.items.len);

        const res = try t.compact();
        try std.testing.expectEqual(@as(usize, 6), res.before);
        try std.testing.expectEqual(@as(usize, 1), res.after);
        try std.testing.expectEqual(@as(usize, 49), res.rows); // 50 - 1 个墓碑

        // 合并后数据必须完全一致
        try std.testing.expectEqualStrings("UPDATED", (try t.get("k00_00", &out)).?);
        try std.testing.expect((try t.get("k02_03", &out)) == null);
        try std.testing.expectEqualStrings("v04_09", (try t.get("k04_09", &out)).?);

        var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
        defer refs.deinit(alloc);
        try t.scanRefs("", "z", &refs);
        try std.testing.expectEqual(@as(usize, 49), refs.items.len);
        try std.testing.expectEqualStrings("k00_00", refs.items[0].key);
        try std.testing.expectEqualStrings("UPDATED", refs.items[0].value);

        t.deinit();
    }

    // 重开后仍正确
    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
        try std.testing.expectEqualStrings("UPDATED", (try t.get("k00_00", &out)).?);
        try std.testing.expect((try t.get("k02_03", &out)) == null);

        // compaction 之后继续写，编号与归档必须仍然对得上
        try t.put("zzz", "after");
        try t.flush();
        try std.testing.expectEqualStrings("after", (try t.get("zzz", &out)).?);
        t.deinit();
    }

    // 再重开：compaction 后的段 + 新写的一段
    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        try std.testing.expectEqual(@as(usize, 2), t.segs.items.len);
        try std.testing.expectEqualStrings("after", (try t.get("zzz", &out)).?);
        try std.testing.expectEqualStrings("UPDATED", (try t.get("k00_00", &out)).?);
    }
}

test "归档 magic 不匹配必须报错（不能把旧格式按新布局解析）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-bad-archive";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        try t.put("a", "va");
        try t.flush();
        t.deinit();
    }

    // 把 magic 改成旧版本（模拟旧库 / 归档损坏）
    {
        const p = tmp ++ "/seg/index.bin";
        const w = try dir.createFile(io, p, .{ .read = true, .truncate = false });
        try w.writePositionalAll(io, "PEKZAG02", 0);
        w.close(io);
    }

    try std.testing.expectError(error.BadArchiveMagic, Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 }));
}

test "自动 compaction: 段数达到阈值后自动合并，数据一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-autocompact";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .compact_after_segs = 3 });
    var live = true;
    defer if (live) t.deinit();

    // 前两次 flush 不足阈值：段数逐个累加
    try t.put("k1", "v1a");
    try t.flush();
    try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
    try t.put("k2", "v2a");
    try t.flush();
    try std.testing.expectEqual(@as(usize, 2), t.segs.items.len);

    // 第三次 flush 后段数到 3 → 自动合并回 1 段
    try t.put("k1", "v1b"); // 同 key 更新，合并后必须留最新值
    try t.flush();
    try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
    try std.testing.expect(t.auto_compact_error == null);
    try std.testing.expectEqualStrings("v1b", (try t.get("k1", &out)).?);
    try std.testing.expectEqualStrings("v2a", (try t.get("k2", &out)).?);
    try std.testing.expect((try t.get("k9", &out)) == null);

    // 自动合并可以反复发生：1 → 2 → 3(触发) → 1
    try t.put("k3", "v3");
    try t.flush();
    try std.testing.expectEqual(@as(usize, 2), t.segs.items.len);
    try t.put("k4", "v4");
    try t.flush();
    try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);

    // 墓碑：删除后合并，重开仍返回 null
    try t.delete("k2");
    try t.flush();
    try std.testing.expectEqual(@as(usize, 2), t.segs.items.len);
    try std.testing.expect((try t.get("k2", &out)) == null);

    t.deinit();
    live = false;
    {
        var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .compact_after_segs = 3 });
        defer t2.deinit();
        try std.testing.expectEqual(@as(usize, 2), t2.segs.items.len);
        try std.testing.expectEqualStrings("v1b", (try t2.get("k1", &out)).?);
        try std.testing.expectEqualStrings("v4", (try t2.get("k4", &out)).?);
        try std.testing.expect((try t2.get("k2", &out)) == null);
    }
}

test "自动 compaction: compact_after_segs=0（默认）不触发" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-autocompact-off";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var kb: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "k{d}", .{i});
        try t.put(k, "v");
        try t.flush();
    }
    // 默认关闭：段数原样保留（回归基准依赖这个默认值）
    try std.testing.expectEqual(@as(usize, 4), t.segs.items.len);
    try std.testing.expect(t.auto_compact_error == null);
}

test "自动 compaction: compact 内部的 flush 不得递归触发" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-autocompact-recursion";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // 阈值 3：手动 compact 内部先落盘会把段数推到正好 3。
    // compact() 内部调的是 flushImpl（不经过 flush），结构上已断开递归；
    // going_compact 是第二道保险，这里同时验证两者都不会让结果错乱。
    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .compact_after_segs = 3 });
    defer t.deinit();

    try t.put("a", "va");
    try t.flush(); // 1 段（不足阈值）
    try t.put("b", "vb");
    try t.flush(); // 2 段（不足阈值）
    try std.testing.expectEqual(@as(usize, 2), t.segs.items.len);

    try t.put("c", "vc"); // 留在 memtable
    const cr = try t.compact();
    try std.testing.expectEqual(@as(usize, 3), cr.before); // 含 compact 内部 flush 出来的那段
    try std.testing.expectEqual(@as(usize, 1), cr.after);
    t.maybeAutoCompact(); // 已 1 段，再调一次不应有任何动作
    try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
    try std.testing.expect(t.auto_compact_error == null);

    try std.testing.expectEqualStrings("va", (try t.get("a", &out)).?);
    try std.testing.expectEqualStrings("vb", (try t.get("b", &out)).?);
    try std.testing.expectEqualStrings("vc", (try t.get("c", &out)).?);

    // did 必须如实反映「有没有真合并」：段数 ≤1 时 compact 直接返回 did=false
    const cr_again = try t.compact();
    try std.testing.expectEqual(@as(usize, 1), cr_again.before);
    try std.testing.expect(!cr_again.did);
    try std.testing.expectEqual(@as(u64, 0), cr_again.bytes);
}

test "自动 compaction: 阈值 1 不得虚增合并次数（compact 提前返回）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-autocompact-thresh1";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .compact_after_segs = 1 });
    defer t.deinit();

    // 第 1 次 flush：1 段达到阈值，但 compact() 见段数 ≤1 会直接返回（未合并）
    // → auto_compact_count 必须仍是 0。不做这个判断就会虚增 1 次。
    try t.put("a", "1");
    try t.flush();
    try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
    try std.testing.expectEqual(@as(u32, 0), t.auto_compact_count);

    // 第 2、3 次：2 段 → 真合并 → 各计 1 次
    try t.put("b", "2");
    try t.flush();
    try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
    try std.testing.expectEqual(@as(u32, 1), t.auto_compact_count);

    try t.put("c", "3");
    try t.flush();
    try std.testing.expectEqual(@as(u32, 2), t.auto_compact_count);
    try std.testing.expect(t.autoCompactHealthy());
}

test "自动 compaction: 失败到上限后停手，resetAutoCompact 能恢复" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-autocompact-fails";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .compact_after_segs = 2 });
    defer t.deinit();

    try t.put("a", "1");
    try t.flush(); // 1 段

    // 伪造「连续失败已到上限」：此后不得再自动合并
    t.auto_compact_fails = AUTO_COMPACT_MAX_FAILS;
    try std.testing.expect(!t.autoCompactHealthy());

    try t.put("b", "2");
    try t.flush(); // 2 段达到阈值，但已停手 → 不合并
    try std.testing.expectEqual(@as(usize, 2), t.segs.items.len);
    try std.testing.expectEqual(@as(u32, 0), t.auto_compact_count);

    // 排除原因后重置 → 下一次 flush 恢复自动合并
    t.resetAutoCompact();
    try std.testing.expect(t.autoCompactHealthy());
    try std.testing.expect(t.auto_compact_error == null);

    try t.put("c", "3");
    try t.flush();
    try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
    try std.testing.expectEqual(@as(u32, 1), t.auto_compact_count);
}

test "写放大计数: compact_bytes_total 含手动合并，flush_bytes_total 只算用户数据" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-wamp-counters";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    // 关闭自动合并，只手动触发 → 两个计数器口径必须分清
    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    try t.put("a", "1");
    try t.flush();
    const after_first = t.flush_bytes_total;
    try std.testing.expect(after_first > 0);
    try std.testing.expectEqual(@as(u64, 0), t.compact_bytes_total);

    try t.put("b", "2");
    try t.flush();
    try std.testing.expect(t.flush_bytes_total > after_first);
    try std.testing.expectEqual(@as(u64, 0), t.compact_bytes_total);

    // 手动合并：compact_bytes_total 增加，flush_bytes_total 不变
    const user_before = t.flush_bytes_total;
    const cr = try t.compact();
    try std.testing.expect(cr.did);
    try std.testing.expectEqual(@as(u64, 0), t.auto_compact_count); // 手动不算「自动次数」
    try std.testing.expectEqual(user_before, t.flush_bytes_total);
    try std.testing.expectEqual(cr.bytes, t.compact_bytes_total);

    // 写放大 = (用户 + 合并) / 用户 > 1（手动合并也算进去，字段名已不叫 auto_）
    try std.testing.expect(t.compact_bytes_total > 0);
}

test "table scanRefs merges multiple segments" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-refs";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    try t.put("a", "va1");
    try t.put("b", "vb1");
    try t.flush();

    try t.put("b", "vb2");
    try t.put("c", "vc1");
    try t.flush();

    var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
    defer refs.deinit(alloc);
    try t.scanRefs("", "z", &refs);
    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
    try std.testing.expectEqualStrings("a", refs.items[0].key);
    try std.testing.expectEqualStrings("b", refs.items[1].key);
    try std.testing.expectEqualStrings("vb2", refs.items[1].value);
    try std.testing.expectEqualStrings("c", refs.items[2].key);
}



test "MergeIter 堆化：多段 key 交错时顺序正确，且部分游标先耗尽不影响结果" {
    // 堆化（O(log k) 替代每行线性扫全部游标）是纯新增逻辑，靠 compaction/scan 的
    // 间接用例覆盖不够 —— 这里直接构造「key 交错 + 各段长度不等」的最刁钻形态：
    //   seg0: 00 03 06        （3 条，最早耗尽）
    //   seg1: 01 04 07 09     （4 条）
    //   seg2: 02 05 08        （3 条）
    // 正确输出必须是 00..09 严格升序、不重不漏。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-heap-order";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    const pat = [3][]const u8{
        &.{ 0, 3, 6 },
        &.{ 1, 4, 7, 9 },
        &.{ 2, 5, 8 },
    };
    for (pat) |keys| {
        for (keys) |k| {
            var kb: [8]u8 = @splat(0);
            kb[7] = k;
            try t.put(&kb, "v");
        }
        try t.flush(); // 每批一段
    }
    try std.testing.expectEqual(@as(usize, 3), t.segs.items.len);

    var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
    defer refs.deinit(alloc);
    try t.scanRefs(&.{}, &.{}, &refs);
    try std.testing.expectEqual(@as(usize, 10), refs.items.len);
    for (refs.items, 0..) |r, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), r.key[7]);
    }
}

test "MergeIter 段裁剪：查询只落在一段内时结果与全量过滤一致" {
    // 段裁剪靠「稀疏索引第 0 条 = 段内最小 key」跳过排在查询之后的整段。
    // 这里把 5 段写成 key 递增不重叠的形态，再对每个区间扫一遍，
    // 断言「裁剪后的结果」与「按 key 全量过滤的期望值」逐条一致。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-seg-prune";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    // 5 段 × 10 行，key = 段号*10 + 行号，段间不重叠
    var seg_i: u8 = 0;
    while (seg_i < 5) : (seg_i += 1) {
        var r: u8 = 0;
        while (r < 10) : (r += 1) {
            var kb: [8]u8 = @splat(0);
            kb[7] = seg_i * 10 + r;
            try t.put(&kb, "v");
        }
        try t.flush();
    }
    try std.testing.expectEqual(@as(usize, 5), t.segs.items.len);

    // 覆盖四种形态：段内、跨段、全区间、空区间
    const cases = [_]struct { lo: u8, hi: u8 }{
        .{ .lo = 0, .hi = 50 },
        .{ .lo = 13, .hi = 27 },
        .{ .lo = 22, .hi = 23 },
        .{ .lo = 45, .hi = 50 },
        .{ .lo = 100, .hi = 120 },
    };

    var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
    defer refs.deinit(alloc);

    for (cases, 0..) |c, ci| {
        refs.clearRetainingCapacity();
        var lo: [8]u8 = @splat(0);
        lo[7] = c.lo;
        var hi: [8]u8 = @splat(0);
        hi[7] = c.hi;
        try t.scanRefs(&lo, &hi, &refs);

        // **裁剪是否真的生效**：不裁剪只是慢、结果一样，光看结果看不出来。
        // 5 段、每段 10 行、段间 key 不重叠 → 第 i 段覆盖 [i*10, i*10+9]。两侧都能剪：
        //   反向（§16.1.23）：段内最大 key < lo  → 整段在起点之前，跳过；
        //   正向：            段内最小 key >= hi → 整段在终点之后，跳过。
        var expect_cursors: usize = 0;
        var expect_pruned_before: usize = 0;
        for (0..5) |si| {
            const kmin = si * 10;
            const kmax = si * 10 + 9;
            if (kmax < c.lo) {
                expect_pruned_before += 1;
                continue;
            }
            if (kmin >= c.hi) continue;
            expect_cursors += 1;
        }
        if (t.merge_cursors_built != expect_cursors) {
            std.debug.print("case {d}: 期望建 {d} 个游标，实际 {d} 个\n", .{ ci, expect_cursors, t.merge_cursors_built });
            return error.CursorCountMismatch;
        }
        if (t.merge_pruned_before != expect_pruned_before) {
            std.debug.print("case {d}: 期望反向剪 {d} 段，实际 {d} 段\n", .{ ci, expect_pruned_before, t.merge_pruned_before });
            return error.PrunedCountMismatch;
        }

        const want: usize = blk: {
            if (c.hi <= c.lo) break :blk 0;
            if (c.lo >= 50) break :blk 0; // 落在全部数据之后
            break :blk @min(@as(usize, c.hi), 50) - c.lo;
        };
        if (refs.items.len != want) {
            std.debug.print("case {d}: 期望 {d} 行，实际 {d} 行\n", .{ ci, want, refs.items.len });
            return error.RowCountMismatch;
        }
        for (refs.items, 0..) |r, i| {
            const expect_key: u8 = c.lo + @as(u8, @intCast(i));
            if (r.key[7] != expect_key) {
                std.debug.print("case {d}: 第 {d} 条期望 {d}，实际 {d}\n", .{ ci, i, expect_key, r.key[7] });
                return error.KeyMismatch;
            }
        }
    }
}

test "空字符串 key：两段都含同一个空 key 时必须判「重叠」，不能走顺序拼接" {
    // 守的是 §16.1.22 引入的一个**歧义**：段头里写的是 `u32 klen + key`，
    // 空段的 klen 是 0，而「最后一条记录的 key 就是空字符串」的 klen 也是 0。
    //
    // 若 `maxKey()` 用 `max_key_len == 0` 判空段，这里两段的 maxKey() 都会返回 null：
    // `canConcat` 把「前一段是空的」当成事实而 `continue`，最终误判为「可拼接」。
    // 拼接按段依次产出 → 先吐旧版本 v1、再被 last_key 去重吃掉新版 v2 → **读到陈旧值**。
    // 修法：判空段用 `rows == 0`（段头里就有，无歧义）。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-empty-key";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    try t.put("", "v1");
    try t.flush();
    try t.put("", "v2");
    try t.flush();
    try std.testing.expectEqual(@as(usize, 2), t.segs.items.len);

    // 两段都是 ["" , ""]，真重叠 → 不允许拼接
    try std.testing.expect(!canConcat(&t));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const got = try t.get("", &out);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v2", out.items);

    // 扫描同样只应产出一条，且是新版本
    var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
    defer refs.deinit(alloc);
    try t.scanRefs(&.{}, &.{}, &refs);
    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqualStrings("", refs.items[0].key);
    try std.testing.expectEqualStrings("v2", refs.items[0].value);
    // 走的是堆路径（两段真重叠），比较次数不为 0 就是证据
    try std.testing.expect(t.merge_compares_total > 0);
}

test "反向段裁剪：范围落在表中段时，起点之前的整段必须被跳过且结果不变" {
    // §16.1.23：段头 `maxKey()` 让「整段在查询起点之前」也能剪。
    // 这里除了断言结果一致，还要断言 `merge_pruned_before` —— 不剪只是慢、结果一样，
    // 光看结果永远看不出裁剪有没有生效。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-prune-before";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    // 10 段 × 10 行，第 i 段覆盖 [i*10, i*10+9]
    var seg_i: u8 = 0;
    while (seg_i < 10) : (seg_i += 1) {
        var r: u8 = 0;
        while (r < 10) : (r += 1) {
            var kb: [8]u8 = @splat(0);
            kb[7] = seg_i * 10 + r;
            try t.put(&kb, "v");
        }
        try t.flush();
    }
    try std.testing.expectEqual(@as(usize, 10), t.segs.items.len);

    var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
    defer refs.deinit(alloc);

    // 只查第 7 段的后半 + 第 8 段：lo=75, hi=85
    var lo: [8]u8 = @splat(0);
    lo[7] = 75;
    var hi: [8]u8 = @splat(0);
    hi[7] = 85;
    try t.scanRefs(&lo, &hi, &refs);

    // 期望：反向剪掉第 0..6 段（maxKey 9,19,...,69 都 < 75）共 7 段，
    // 正向剪掉第 9 段（段首 90 >= 85），实际建 2 个游标。
    try std.testing.expectEqual(@as(usize, 7), t.merge_pruned_before);
    try std.testing.expectEqual(@as(usize, 2), t.merge_cursors_built);
    try std.testing.expectEqual(@as(usize, 10), refs.items.len);
    for (refs.items, 0..) |r, i| {
        try std.testing.expectEqual(@as(u8, 75 + @as(u8, @intCast(i))), r.key[7]);
    }

    // 关掉反向裁剪后结果必须**完全相同**（只是变的更慢）—— 证明裁剪纯属优化、不改变语义
    t.opts.no_prune_before = true;
    refs.clearRetainingCapacity();
    try t.scanRefs(&lo, &hi, &refs);
    try std.testing.expectEqual(@as(usize, 0), t.merge_pruned_before);
    // 反向裁剪关掉后仍有**正向**裁剪：第 9 段段首 90 >= 85 依旧要剪 → 剩 9 个游标
    try std.testing.expectEqual(@as(usize, 9), t.merge_cursors_built);
    try std.testing.expectEqual(@as(usize, 10), refs.items.len);
    for (refs.items, 0..) |r, i| {
        try std.testing.expectEqual(@as(u8, 75 + @as(u8, @intCast(i))), r.key[7]);
    }
    t.opts.no_prune_before = false;
}
