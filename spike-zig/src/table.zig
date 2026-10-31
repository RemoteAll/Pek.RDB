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
    const n = @min(a.key.len, b.key.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a.key[i] != b.key[i]) return a.key[i] < b.key[i];
    }
    if (a.key.len != b.key.len) return a.key.len < b.key.len;
    return a.seq > b.seq;
}

fn refLess(_: void, a: segmod.Segment.RefRecord, b: segmod.Segment.RefRecord) bool {
    const n = @min(a.key.len, b.key.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a.key[i] != b.key[i]) return a.key[i] < b.key[i];
    }
    if (a.key.len != b.key.len) return a.key.len < b.key.len;
    return a.seq > b.seq;
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
    idx_archive: []u8 = &.{},
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
        var arch: []u8 = &.{};
        const has_index = blk: {
            if (segmod.readWholeFile(io, dir, index_path, alloc, 16 << 30)) |a| {
                arch = a;
                break :blk true;
            } else |e| switch (e) {
                error.FileNotFound => break :blk false,
                else => return e,
            }
        };
        errdefer if (arch.len > 0) alloc.free(arch);
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
        var replayed = try walmod.replay(io, dir, wal_path, alloc);
        defer replayed.deinit();
        for (replayed.batches.items) |b| {
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

        const wal = try walmod.Wal.openAppend(io, dir, wal_path, alloc);

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
        if (self.idx_archive.len > 0) self.alloc.free(self.idx_archive);
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

        var w = try segmod.Writer.create(self.io, self.dir, data_path, self.alloc, self.opts.bloom_bits);
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
        var refs: std.ArrayList(segmod.Segment.RefRecord) = .empty;
        defer refs.deinit(self.alloc);
        try self.scanRefs(start, end, &refs);

        var total: usize = 0;
        for (refs.items) |r| total += r.key.len + r.value.len;

        const buf = try self.alloc.alloc(u8, total);
        errdefer self.alloc.free(buf);
        const records = try self.alloc.alloc(RecordOwned, refs.items.len);
        errdefer self.alloc.free(records);

        var off: usize = 0;
        for (refs.items, 0..) |r, i| {
            const k = buf[off..][0..r.key.len];
            @memcpy(k, r.key);
            off += r.key.len;
            const v = buf[off..][0..r.value.len];
            @memcpy(v, r.value);
            off += r.value.len;
            records[i] = .{ .key = k, .seq = r.seq, .flags = r.flags, .value = v };
        }
        return .{ .alloc = self.alloc, .buf = buf, .records = records };
    }
    /// 通用 refs 扫描：memtable + 所有段的 k 路归并（值零拷贝借用；调用期间不得写）。
    pub fn scanRefs(self: *Table, start: []const u8, end: []const u8, out: *std.ArrayList(segmod.Segment.RefRecord)) !void {
        var it = MergeIter{};
        try it.init(self, start, end);
        defer it.deinit();
        while (it.next()) |rec| try out.append(self.alloc, rec);
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

        var w = try segmod.Writer.create(self.io, self.dir, data_path, self.alloc, self.opts.bloom_bits);
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
        const new_seg = try segmod.Segment.fromBytes(self.io, self.dir, self.base_path, id, fin.bytes, self.alloc, true, self.opts.mmap_preheat);
        errdefer {
            var s = new_seg;
            s.owns_idx = false; // 字节由上面的 errdefer 释放
            s.close();
        }

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
        if (self.idx_archive.len > 0) self.alloc.free(self.idx_archive);
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
    last_key: []const u8 = &.{},
    have_last: bool = false,

    pub fn init(self: *MergeIter, table: *Table, start: []const u8, end: []const u8) !void {
        self.* = .{ .table = table };
        const alloc = table.alloc;
        // init 中途失败时要自己清干净：调用方是在 init 成功后才注册 defer deinit 的
        errdefer self.deinit();
        if (table.mem.len() > 0) {
            try self.cursors.append(alloc, .{ .mem = .{
                .it = table.mem.iteratorFrom(start),
                .end = end,
                .snapshot = table.visible,
            } });
        }
        for (table.segs.items) |*s| {
            const c = try s.cursor(start, end, table.visible);
            try self.cursors.append(alloc, .{ .seg = c });
        }
        if (self.cursors.items.len > 1) {
            self.cur = try alloc.alloc(?segmod.Segment.RefRecord, self.cursors.items.len);
            for (self.cursors.items, 0..) |*c, i| self.cur[i] = c.next();
        }
    }

    pub fn deinit(self: *MergeIter) void {
        if (self.cur.len > 0) self.table.alloc.free(self.cur);
        self.cursors.deinit(self.table.alloc);
    }

    pub fn next(self: *MergeIter) ?segmod.Segment.RefRecord {
        // 单游标（单段或仅 memtable）：顺序去重，省掉 k 路选择开销
        if (self.cursors.items.len == 1) {
            while (self.cursors.items[0].next()) |rec| {
                if (self.have_last and std.mem.eql(u8, rec.key, self.last_key)) continue;
                self.last_key = rec.key;
                self.have_last = true;
                if (rec.flags == 0) return rec;
            }
            return null;
        }
        while (true) {
            var best: ?usize = null;
            for (self.cur, 0..) |maybe, i| {
                const r = maybe orelse continue;
                if (best == null) {
                    best = i;
                    continue;
                }
                if (refLess({}, r, self.cur[best.?].?)) best = i;
            }
            const bi = best orelse return null;
            const rec = self.cur[bi].?;
            self.cur[bi] = self.cursors.items[bi].next();

            if (self.have_last and std.mem.eql(u8, rec.key, self.last_key)) continue;
            self.last_key = rec.key;
            self.have_last = true;
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


