// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const builtin = @import("builtin");

/// Debug/ReleaseSafe 下才做「单线程」断言；且只在**确实支持 `std.Thread.getCurrentId()`** 的目标上做。
///
/// 为什么需要这个开关：`std` 在无 OS 目标（`freestanding` / `uefi` …）上把
/// `Thread.getCurrentId()` 实现成 **`@compileError`**（`UnsupportedImpl.getCurrentId`），
/// 于是在那种目标上开启断言会直接编译失败 —— 直接违反 §16.5「C 档无 OS 必须能编译」。
///
/// 判据用「白名单 + 默认关」而不是「黑名单 + 默认开」：断言只是开发期辅助，
/// 认错的代价应当是「少一个检查」，而不是「编译不过」。
/// 白名单与 `std/Thread.zig` 里 `Thread.Id` 的 `switch` 保持一致。
const thread_check_supported = std.debug.runtime_safety and switch (builtin.os.tag) {
    .windows,
    .linux,
    .macos,
    .ios,
    .tvos,
    .watchos,
    .visionos,
    .maccatalyst,
    .driverkit,
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    .haiku,
    .illumos,
    .serenity,
    .wasi,
    .emscripten,
    => true,
    else => false,
};
const Skiplist = @import("skiplist.zig").Skiplist;
const walmod = @import("wal.zig");
const segmod = @import("segment.zig");

const RecordOwned = segmod.RecordOwned;

pub const Options = struct {
    flush_bytes: usize = 64 << 20,
    wal_sync_every: usize = 10_000,
    /// 打开段时是否把整个数据文件读进页缓存（默认关：冷重开只加载索引，数据按需缺页）。
    mmap_preheat: bool = false,
    /// 数据段 mmap 允许预缺页的最大字节数；**`0` = 从不预取（默认）**。
    ///
    /// 注意 `mmap_preheat` 与它不同：前者是「打开时主动整段 read」的显式行为，
    /// 后者控制 Zig `MemoryMap` 的 `populate`（**默认 true**，Windows 会预取整段）。
    /// 想把旧行为（随机点查也整段预取）拿回来做 A/B，传 `1 << 62` 即可。
    data_prefault_max_bytes: u64 = 0,
    /// 索引归档（`seg/index.bin`）允许映射的最大字节数；**0 = 不限制**（默认，64 位目标）。
    ///
    /// 这不是磁盘格式限制，只是「明确想拒绝打开超大库」时的防御性上界。
    /// 历史上这里写死过 `64 << 30`，结果 64 GiB ÷ 实测 1.56 B/行 ≈ **440 亿行/表** 就成了单表
    /// 容量天花板 —— 一个防呆常量不该决定产品容量（决策记录八十九）。
    index_max_bytes: u64 = 0,
    /// 归档不超过该值时**整段预缺页**（populate），超过则不预缺页。
    ///
    /// 必须按大小限制：Zig 0.17 的 `MemoryMap.CreateOptions.populate` 默认 true，
    /// 而 Windows 实现真的会对整段调 `NtSetInformationVirtualMemory(Prefetch)`
    /// （见 `std/Io/Threaded.zig` 的 `createFileMap`）。3 MB 时预取是好事
    /// （冷重开 0.6 ms 里有它一份），100 GB 时预取 = 打开时读 100 GB 索引。
    index_prefault_max_bytes: u64 = 32 << 20,
    /// 新段索引的 Bloom 位数/key（0 = 不生成）。
    /// Bloom 占索引体积 ~80%，只对「不存在的 key」有用；关闭后冷重开与索引 IO 同步变小。
    bloom_bits: u8 = 10,
    /// 段数达到该值后，`flush` 结束时自动全量合并（**0 = 关闭，默认关闭**）。    ///
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
    /// **分层合并（size-tiered）的段数上限**：段数超过它就自动做一次
    /// `compactTier(tiered_fanout)`（只合并最小的 N 个段）。`0` = 关闭（默认）。
    ///
    /// 与 `compact_after_segs`（全量合并）二选一，**这个优先**：全量合并的单次阻塞
    /// 随数据量线性增长，大表不可用（44e9 行会有约 6.8 万段）。
    /// 推荐：`compact_max_segs = 16` + `tiered_fanout = 4`（段数封顶 16，写放大 ≈ log₄）。
    compact_max_segs: usize = 0,
    /// 分层合并每次合并几个段（`< 2` 视为关闭）。
    tiered_fanout: usize = 4,
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
    /// **仅用于基准 A/B**：置 true 时退回「flush 后 close + deleteFile + createFile」重建 WAL，
    /// 而不是原地 `setLength(0)` 复用句柄。生产路径永远留 false。
    ///
    /// 为什么要这个开关：写路径偶发整轮崩塌（约 7 轮 1 次，同轮读完全正常）。
    /// 删+建文件是写路径上唯一会增删目录项的操作，也是 Windows 实时扫描最容易插进来的点，
    /// 但「怀疑」不够 —— 必须同进程背靠背配对才能把 200 次元数据操作的代价从噪声里分出来。
    wal_rotate_recreate: bool = false,
    /// 用户态 WAL 缓冲上限（字节）；**`0` = 每次写入立即 `write` 到 OS**。
    ///
    /// 它定义的是**持久化强度**，不是性能旋钮：
    /// - 默认 `256 KB`：进程被强杀（任务管理器结束 / `kill -9` / 关机强杀）时
    ///   最多丢最后 256 KB（约 5000 行）**已返回成功的写**；
    /// - `0`：强杀一条不丢（数据已进 OS 页缓存，进程死了内核还在，只有**掉电**才丢）
    ///   —— 与 SQLite `synchronous=NORMAL` 对等（它每笔提交都 `pwrite` 到 WAL）。
    ///
    /// 跨引擎比吞吐前必须先对齐这一条，否则比的不是同一个持久化级别。
    wal_buf_bytes: usize = 256 * 1024,
    /// 提交返回前是否 `fsync`（**默认 true = 最强档：提交返回即落盘**）。
    ///
    /// - `true`：每批 `fsync` 后才返回。进程被杀、机器掉电都不丢已返回成功的写。
    /// - `false`：只把数据写进 OS 页缓存就返回（**SQLite `synchronous=NORMAL` 的等价档**）。
    ///
    /// 为什么要这个开关：跨引擎比较写入吞吐时，SQLite NORMAL 每笔提交**不** `fsync`
    /// （`sqlite3.c:63192` 原文），而我们默认每批都 `fsync` —— 拿更严的档去比，
    /// 写吞吐比值就没有意义。基准必须显式选同一档，并在表里写明是哪一档。
    durable_commit: bool = true,
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

const MemCursor = struct {
    it: Skiplist.Iterator,
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
/// `{table}/seg` 里是否已经有 `*.data`（用来判定「旧库丢了归档」而不是「全新空库」）。
///
/// 只认 `.data` 不认目录存在：表刚建好、还没 flush 过时 `seg/` 目录就已经存在了，
/// 那种情况应该继续当空表打开。
fn hasSegmentDataFiles(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, table_path: []const u8) !bool {
    const seg_dir_path = try alloc.print("{s}/seg", .{table_path});
    defer alloc.free(seg_dir_path);
    // `.iterate = true` 必须显式给：0.17 的 Dir 默认不带遍历权限，
    // 否则 `iterate().next()` 会在 Windows 上报 ACCESS_DENIED（"opened with iteration ability"）。
    var d = dir.openDir(io, seg_dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".data")) return true;
    }
    return false;
}

fn openSegmentsFromArchive(
    io: std.Io,
    dir: std.Io.Dir,
    base_path: []const u8,
    buf: []const u8,
    alloc: std.mem.Allocator,
    preheat: bool,
    data_prefault_max: u64,
    segs: *std.ArrayList(segmod.Segment),
) !OpenSegmentsResult {
    // **两遍**：先按顺序应用删除标记（`payload.len == 0`），得到活段列表，再建段。
    // 归档是只追加的，合并掉的段只写一条删除标记 —— 若一遍边解边建，
    // 删除标记出现在段后面时已经建好的那个段还得反悔（而 `fromBytes` 已经解了头）。
    var live: std.ArrayList(segmod.ArchiveRecord) = .empty;
    defer live.deinit(alloc);
    var it = segmod.ArchiveIter{ .buf = buf };
    var max_id: u64 = 0;
    while (it.next()) |rec| {
        // `max_id` 要覆盖**已死的段号**：段号绝不能重用，否则新段会被旧的删除标记误杀。
        max_id = @max(max_id, rec.id);
        if (rec.payload.len == 0) {
            var j: usize = 0;
            while (j < live.items.len) : (j += 1) {
                if (live.items[j].id == rec.id) {
                    _ = live.orderedRemove(j);
                    break;
                }
            }
            continue;
        }
        // 同 id 出现两次（理论上不该有）→ 后者胜，不能建成两个同号段
        var dup = false;
        for (live.items) |*e| {
            if (e.id == rec.id) {
                e.payload = rec.payload;
                dup = true;
                break;
            }
        }
        if (!dup) try live.append(alloc, rec);
    }
    const valid_end = it.validEnd();

    for (live.items) |rec| {
        var ta: u64 = 0;
        if (segmod.timing_enabled) ta = segmod.tick(io);
        var seg = try segmod.Segment.fromBytes(io, dir, base_path, rec.id, rec.payload, alloc, false, preheat);
        seg.data_prefault_max = data_prefault_max;
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
    return .{ .valid_end = valid_end, .max_id = max_id };
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
    /// **创建这张表的线程 id**。`Table` 没有任何锁（`seq += 1`、`mem.insert`、
    /// `wal.append` 全是裸操作），因此**只能由创建它的那个线程使用**。
    ///
    /// 为什么要有这个字段：多线程误用会造成**静默数据竞争**（两个线程拿到同一个 seq、
    /// skiplist 被并发修改）——这类问题事后极难定位，且看起来完全像“数据自己错乱”了。
    /// 在 Debug/ReleaseSafe 下用 `checkThread()` 把它变成立刻 panic（ReleaseFast 下断言被
    /// 编译器消除，基准零成本）。
    ///
    /// 需要并发写怎么办：每个线程各开一张表（基准里的 `concWriter` 就是这么做的），
    /// 或者由上层加锁。**不要**在多个线程间共享同一个 `Table`。
    owner: std.Thread.Id,
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
    /// 段 key 范围是否**严格递增且不重叠**。用于把 `get` 从「逐段倒序试」降到「二分 1 个段」。
    /// 只在段集合变化（open / flush / merge）时由 `recomputeSegLayout()` 重算。
    /// **默认 false（保守）**：没算过就走逐段扫，宁可慢也不能给出「看起来查过了其实没查」的结果。
    segs_disjoint_asc: bool = false,
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
    /// 累计花在 `wal.sync()`（fsync）上的纳秒数。
    ///
    /// 为什么要这个：7 轮交替配对里写指标偶发**整轮崩塌**（`big_put` 1.33M → 238K），
    /// 而同轮读指标完全正常 —— 只看总吞吐只能看到「这一轮慢」，看不出慢在哪一段。
    /// 把 fsync 与段 flush 分开计时，才能判定是「周期 fsync 抖动」还是「段落盘抖动」，
    /// 否则任何优化都只能靠猜。
    ns_wal_sync: u64 = 0,
    /// 累计花在 `flush()`（段落盘 + 索引追加）上的纳秒数。
    ns_flush: u64 = 0,
    /// `flush()` 被调用次数（含 `put` 触发的与显式调用的）。
    flush_calls: u64 = 0,
    /// 单次 `flush()` 最长耗时（纳秒）：尾部抖动的直接证据。
    ns_flush_max: u64 = 0,
    /// 段数据文件写入 + fsync 的累计纳秒（`Writer.create` → `finishBytes`）。
    ns_seg_data: u64 = 0,
    /// `ns_seg_data` 的三段拆分：建文件（含 Bloom 位图分配）/ 写块 / fsync。
    ns_seg_create: u64 = 0,
    ns_seg_write: u64 = 0,
    ns_seg_sync: u64 = 0,
    /// 索引归档追加 + fsync 的累计纳秒（`archiveAppend`）。
    ns_idx: u64 = 0,
    /// WAL 轮换（sync + 关/删/建，或原地截断）的累计纳秒。
    ns_walrot: u64 = 0,
    /// 单次 WAL 轮换最长耗时（纳秒）。
    ns_walrot_max: u64 = 0,
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
    /// 重叠段点查的候选用缓冲（跨段比 seq 时要先放这里，赢了才拷进调用方的 out）。
    hit_buf: std.ArrayList(u8) = .empty,

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
            // 上限/预缺页都由 Options 控制：0 = 不限制（64 位默认），预缺页只对小归档开。
            if (segmod.mapWholeFile(io, dir, index_path, opts.index_max_bytes, opts.index_prefault_max_bytes)) |m| {
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
            // 归档缺失时先分清「全新库」与「归档丢了」：
            // 以前这里一律当新建库，于是「index.bin 被删/丢失但 seg/*.data 还在」会表现为
            // **静默空表**，而且下一次 flush 的段号从 max_id+1=1 开始，直接覆盖 seg/000001.data。
            // 宁可直接拒开，也不允许「看起来是空表」这种默默丢数据的形态。
            if (try hasSegmentDataFiles(io, dir, alloc, path)) return error.ArchiveMissingButSegmentsExist;
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
        var wal = rw.wal;
        wal.buf_bytes = opts.wal_buf_bytes;

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

        // 段内部保存的 `base_path` 是**借用切片**：必须传自己 dup 的那份（`base_path`），
        // 不能传调用方的 `path` —— 调用方往往在 open 返回后立刻释放（`Engine` 拼的
        // `{root}/{table}`、索引的 `{table}/idx/{name}` 都走 defer free），段就会带着
        // 悬空指针活下来，等到第一次 `cursor()` 才以 `FileNotFound` 的形式爆出来。
        const opened = try openSegmentsFromArchive(io, dir, base_path, arch, alloc, opts.mmap_preheat, opts.data_prefault_max_bytes, &segs);
        const id: u64 = opened.max_id + 1;
        for (segs.items) |s| seq = @max(seq, s.max_seq);

        if (segmod.timing_enabled) {
            const t1 = @as(u64, @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds));
            segmod.timing.segs += t1 - t0;
        }

        var t = Table{
            .io = io,
            .dir = dir,
            .alloc = alloc,
            .owner = if (comptime thread_check_supported) std.Thread.getCurrentId() else 0,
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
        // 段集合定型后算一次布局标记：不重叠且递增时 `get` 走二分定位（只碰 1 个段）
        t.recomputeSegLayout();
        return t;
    }

    pub fn deinit(self: *Table) void {
        self.checkThread();
        for (self.segs.items) |*s| s.close();
        self.segs.deinit(self.alloc);
        if (self.idx_map) |*m| m.destroy();
        self.idx_map = null;
        self.idx_archive = &.{};
        self.key_arena.deinit(self.alloc);
        self.hit_buf.deinit(self.alloc);
        self.mem.deinit();
        self.wal.close();
        self.alloc.free(self.base_path);
        self.alloc.free(self.wal_path);
        self.alloc.free(self.index_path);
        self.* = undefined;
    }

    /// 把用户态 WAL 缓冲写进 OS 并 `fsync`。
    ///
    /// `put` 返回成功只保证「进了缓冲」（`wal_buf_bytes > 0` 时），
    /// 只有这个调用才保证「已经在盘上」。宿主在收到退出信号、或需要「写到哪儿算哪儿」的
    /// 检查点时调它。
    pub fn sync(self: *Table) !void {
        const t = self.nowNs();
        try self.wal.sync();
        self.ns_wal_sync += self.nowNs() - t;
        self.pending = 0;
    }

    /// 收尾动作本体（**不释放资源**，运行期可当 checkpoint 反复调用）。
    ///
    /// 1. `flush()`：memtable 全部落成段（段数据与索引归档各自 `fsync`），随后 WAL 原地清空；
    /// 2. `wal.sync()` 兜底：即使 memtable 为空、`flush` 走了只轮换 WAL 的路径，
    ///    也保证残留缓冲落盘并在盘上。
    ///
    /// 为什么第 2 步不能省：`flush` 的 WAL 轮换是 `setLength(0)`，
    /// 它丢的是「已经进段的数据」对应的那批 WAL —— 但如果 memtable 为空而用户态缓冲里
    /// 还有没 `write` 出去的行，轮换会把它们直接丢掉。先 sync 再轮换才是安全的。
    pub fn checkpoint(self: *Table) !void {
        try self.sync();
        try self.flush();
        try self.wal.sync();
        self.pending = 0;
    }

    /// **有序收尾**：checkpoint（落段 + 清 WAL + 全部 `fsync`）后释放资源。
    ///
    /// 这是「数据库层面」应有的正常退出路径。宿主收到 SIGTERM / SIGINT /
    /// 控制台 Ctrl+C / Windows 服务停止 / 系统关机时应当调它，**而不是**只等进程
    /// 退出时的 `deinit`：
    /// - `deinit` 只做资源释放 + 一次尽力写（不 `fsync`、失败只记日志）；
    /// - `wal_buf_bytes > 0` 时，被强杀的进程会在缓冲里丢最多 `buf_bytes` 字节
    ///   **已返回成功的写**。信号处理的参考实现在 `shutdown.zig`。
    ///
    /// 失败时**仍然释放资源**（避免泄漏），错误往上抛给调用方决定怎么上报。
    pub fn close(self: *Table) !void {
        const r = self.checkpoint();
        self.deinit();
        try r;
    }

    /// 单调纳秒时钟（`Table` 内部计时用；不依赖外部注入）。
    inline fn nowNs(self: *Table) u64 {
        const ts = std.Io.Timestamp.now(self.io, .awake);
        return @intCast(ts.nanoseconds);
    }

    /// 单线程不变量：`Table` 没有锁，只能由创建它的线程使用（见 `owner` 字段）。
    ///
    /// Debug/ReleaseSafe 下误用会直接 panic；ReleaseFast 下整段被编译器消除（零成本）。
    /// 这是有意为之：并发写同一张表会 **静默** 抢同一个 seq、并发改 skiplist，
    /// 事后表现得像「数据自己错乱了」，极难定位 —— 宁可开发期直接炸。
    inline fn checkThread(self: *const Table) void {
        if (comptime !thread_check_supported) return;
        if (std.Thread.getCurrentId() != self.owner) {
            @panic("Table 不是线程安全的：检测到非创建线程在操作同一张表（请每线程各开一张表）");
        }
    }

    pub fn put(self: *Table, key: []const u8, value: []const u8) !void {
        self.checkThread();
        self.seq += 1;
        const seq = self.seq;
        _ = try self.wal.append(seq, &.{.{ .flags = 0, .key = key, .value = value }});
        try self.mem.insert(key, seq, 0, value);
        self.visible = seq;
        self.pending += 1;
        if (self.opts.wal_sync_every > 0 and self.pending >= self.opts.wal_sync_every) {
            const t_sync = self.nowNs();
            try self.wal.sync();
            self.ns_wal_sync += self.nowNs() - t_sync;
            self.pending = 0;
        }
        if (self.mem.sizeBytes() >= self.opts.flush_bytes) try self.flush();
    }

    pub fn delete(self: *Table, key: []const u8) !void {
        self.checkThread();
        self.seq += 1;
        const seq = self.seq;
        _ = try self.wal.append(seq, &.{.{ .flags = 1, .key = key, .value = "" }});
        try self.mem.insert(key, seq, 1, "");
        self.visible = seq;
    }

    /// 批量写：一批一个 WAL 提交（对应 SQLite 的单事务批量插入）。
    pub fn putBatch(self: *Table, keys: []const []const u8, values: []const []const u8) !void {
        self.checkThread();
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
        // 持久化档由调用方选（见 `Options.durable_commit`）。耗时必须计入 `ns_wal_sync`：
        // 否则「写入慢」到底慢在 `fsync` 还是慢在内存结构，没有任何证据可看。
        const t_sync = self.nowNs();
        if (self.opts.durable_commit) {
            try self.wal.sync();
        } else {
            try self.wal.flushToOs();
        }
        self.ns_wal_sync += self.nowNs() - t_sync;
        // **必须和 `put` 一样按 `flush_bytes` 回落**：漏了这一句的后果是「批量导入时 memtable
        // 无界增长」——1 亿行 × 39 B ≈ 3.9 GB 全留在内存里，最后一次性 flush 要 71 s，
        // 而且只产出一个巨型段（段数=1 会让点查/合并的实测结果失去意义）。
        if (self.mem.sizeBytes() >= self.opts.flush_bytes) try self.flush();
    }

    pub fn get(self: *Table, key: []const u8, out: *std.ArrayList(u8)) !?[]const u8 {
        self.checkThread();
        if (self.mem.get(key, self.visible)) |e| {
            if (e.flags != 0) return null;
            out.clearRetainingCapacity();
            try out.appendSlice(self.alloc, e.value);
            return out.items;
        }
        // 段 key 范围**不重叠且递增**时，二分直接定位到唯一候选段，不用逐段倒序试。
        // 实测背景（容量线 1 亿行）：155 段时逐段试把热态点查从 669k 次/s 拖到 99k 次/s，
        // 而段头本来就有 `firstKey()`/`maxKey()`，定位成本只有 log2(155)≈7 次比较。
        if (self.segs_disjoint_asc) {
            const i = self.findSegByRange(key) orelse return null;
            if (try self.segs.items[i].get(key, self.visible, out)) |flags| {
                if (flags != 0) return null;
                return out.items;
            }
            // 范围说在这个段里但段内没有 ⇒ 不存在（段不可变，除墓碑外不会"暂时没有"）
            return null;
        }
        // **重叠段：命中不能“先到先得”**。分层合并（`compactTier`）之后，合并出的段带着
        // **旧**数据却被追加在数组末尾（段号最大），而幸存段里可能存着更新的版本 ——
        // 「段序 = 新旧序」不再成立。唯一正确的判据是 **seq 最大的可见版本**。
        var best_seq: u64 = 0;
        var best_flags: u8 = 0;
        var found = false;
        var i = self.segs.items.len;
        while (i > 0) {
            i -= 1;
            // **按段头 `max_seq` 剪枝**：段内任何记录的 seq 都 ≤ `max_seq`，
            // 所以「整段最新的版本都不如已找到的」时连 Bloom 都不必过。
            // 这一条让「顺序写入（段序 = 新旧序）」的情形退化成只查 1 个段，与旧路径同价。
            if (found and self.segs.items[i].max_seq <= best_seq) continue;
            var got_seq: u64 = 0;
            const flags = try self.segs.items[i].getSeq(key, self.visible, &self.hit_buf, &got_seq) orelse continue;
            if (!found or got_seq > best_seq) {
                found = true;
                best_seq = got_seq;
                best_flags = flags;
                out.clearRetainingCapacity();
                try out.appendSlice(self.alloc, self.hit_buf.items);
            }
        }
        if (!found) return null;
        if (best_flags != 0) return null;
        return out.items;
    }

    /// 重算「段 key 范围是否严格递增不重叠」这个布局标记（O(段数)，只在段集合变化时调）。
    ///
    /// 为什么需要标记而不是每次现算：`get` 是热路径，每次查都 O(n) 就本末倒置了。
    /// 为什么可以只算一次：段不可变，只有 flush / 合并才会改变段集合。
    fn recomputeSegLayout(self: *Table) void {
        self.segs_disjoint_asc = true;
        if (self.segs.items.len == 0) return;
        var prev_max: ?[]const u8 = null;
        for (self.segs.items) |*s| {
            const fk = s.firstKey() orelse {
                self.segs_disjoint_asc = false; // 空段：保守回退到逐段扫
                return;
            };
            if (prev_max) |pm| {
                if (segmod.keyCmp(pm, fk) != .lt) {
                    self.segs_disjoint_asc = false;
                    return;
                }
            }
            prev_max = s.maxKey() orelse {
                self.segs_disjoint_asc = false;
                return;
            };
        }
    }

    /// 在「不重叠且递增」的段列表里二分：返回唯一可能包含 `key` 的段下标。
    fn findSegByRange(self: *const Table, key: []const u8) ?usize {
        var lo: usize = 0;
        var hi: usize = self.segs.items.len; // [lo, hi)
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const fk = self.segs.items[mid].firstKey() orelse return null;
            if (segmod.keyCmp(fk, key) == .gt) hi = mid else lo = mid + 1;
        }
        if (lo == 0) return null; // 所有段的 firstKey 都 > key
        const i = lo - 1;
        const mk = self.segs.items[i].maxKey() orelse return null;
        if (segmod.keyCmp(mk, key) == .lt) return null; // 落在两段之间的空洞
        return i;
    }

    /// 把 memtable 落盘。
    ///
    /// **注意语义**：开了 `compact_after_segs` 时，本函数末尾可能触发全量合并，
    /// 于是这一次 flush 的耗时可从微秒级变成数百毫秒（200 万行约 0.4–0.7 s）。
    /// 合并失败不影响本次 flush 成功（数据已落盘），错误记在 `auto_compact_error`。
    pub fn flush(self: *Table) !void {
        self.checkThread();
        const t_flush = self.nowNs();
        defer {
            const d = self.nowNs() - t_flush;
            self.ns_flush += d;
            self.flush_calls += 1;
            if (d > self.ns_flush_max) self.ns_flush_max = d;
        }
        try self.flushImpl();
        self.maybeAutoCompact();
    }

    /// 把一批**已按 key 升序排好**的记录一次性写成一个新段：**不写 WAL、不经 memtable**。
    ///
    /// 为什么需要独立入口（对齐 RocksDB `SstFileWriter` 的批量装载思路）：
    /// `CREATE INDEX` 回填若走 `put()`，每行都要「WAL 编码一次 + 跳表插入一次」，
    /// 而 SQLite 的 `CREATE INDEX` 是「扫表 → 排序 → 顺序写页」—— 两边不是同一档工作量，
    /// 实测（p20 批次）索引构建 0.633× 落后，差距就在这里。本入口直接喂 `Writer`
    /// （它本来就是「按 key 升序顺序写」的），把 WAL 与 memtable 两步整段省掉。
    ///
    /// 调用方责任：
    /// - key 必须**严格升序**（`Writer.push` 在 Debug/ReleaseSafe 下会断言，ReleaseFast 下不检查）；
    /// - 这条路径**不写 WAL**，所以只能用于「崩了可以整段重建」的场景（索引回填、批量导入）。
    ///   索引回填正是这样：`.ready` 标记在回填成功之后才写，崩了就整个重建。
    /// - `values == null` 表示所有记录的值都是空串（索引表的形态）。
    pub fn bulkLoadSorted(
        self: *Table,
        keys: []const []const u8,
        values: ?[]const []const u8,
    ) !void {
        self.checkThread();
        if (values) |vs| std.debug.assert(vs.len == keys.len);
        if (keys.len == 0) return;
        const id = self.next_seg;
        const data_path = try self.alloc.print("{s}/seg/{d:0>6}.data", .{ self.base_path, id });
        defer self.alloc.free(data_path);

        // 整批算一次提交：与 `putBatch` 同语义，记录之间不需要各自的 seq
        self.seq += 1;
        const seq = self.seq;

        const t_seg = self.nowNs();
        var w = try segmod.Writer.create(self.io, self.dir, data_path, self.alloc, self.opts.bloom_bits, keys.len);
        defer w.deinit();
        if (values) |vs| {
            for (keys, vs) |k, v| try w.push(k, seq, 0, v);
        } else {
            for (keys) |k| try w.push(k, seq, 0, &.{});
        }
        const fin = try w.finishBytes();
        errdefer self.alloc.free(fin.bytes);
        self.ns_seg_data += self.nowNs() - t_seg;
        self.ns_seg_create += w.ns_create;
        self.ns_seg_write += w.ns_write;
        self.ns_seg_sync += w.ns_sync;
        const t_idx = self.nowNs();
        self.index_valid_len = try segmod.archiveAppend(self.io, self.dir, self.index_path, @intCast(id), fin.bytes, self.index_valid_len);
        self.ns_idx += self.nowNs() - t_idx;

        var seg = try segmod.Segment.fromBytes(self.io, self.dir, self.base_path, id, fin.bytes, self.alloc, true, self.opts.mmap_preheat);
        seg.data_prefault_max = self.opts.data_prefault_max_bytes;
        self.segs.append(self.alloc, seg) catch |e| {
            var s = seg;
            s.owns_idx = false;
            s.close();
            return e;
        };
        self.next_seg = id + 1;
        self.visible = seq;
        self.recomputeSegLayout();
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
        if (self.going_compact) return; // compact 内部的 flush 不得递归触发
        if (self.auto_compact_fails >= AUTO_COMPACT_MAX_FAILS) return;

        // 分层合并优先：段数超过上限就合并最小的 N 个段，最多连着做 4 次
        // （每次减少 fanout−1 段，4 次足够从 30 段收敛到 16 段以内）。
        if (self.opts.compact_max_segs > 0 and self.opts.tiered_fanout >= 2) {
            var guard: usize = 0;
            while (self.segs.items.len > self.opts.compact_max_segs and guard < 4) : (guard += 1) {
                const cr = self.compactTier(self.opts.tiered_fanout) catch |e| {
                    self.auto_compact_error = e;
                    self.auto_compact_fails +|= 1;
                    return;
                };
                if (!cr.did) return;
                self.auto_compact_count +|= 1;
            }
            return;
        }

        if (self.opts.compact_after_segs == 0) return;
        if (self.segs.items.len < self.opts.compact_after_segs) return;
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

        const t_seg = self.nowNs();
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
        // 数据段（create → finishBytes）落盘耗时
        self.ns_seg_data += self.nowNs() - t_seg;
        self.ns_seg_create += w.ns_create;
        self.ns_seg_write += w.ns_write;
        self.ns_seg_sync += w.ns_sync;
        // 从「有效末尾」写：若上次追加留下崩溃残片，这里会把它覆盖掉
        const t_idx = self.nowNs();
        self.index_valid_len = try segmod.archiveAppend(self.io, self.dir, self.index_path, @intCast(id), fin.bytes, self.index_valid_len);
        self.ns_idx += self.nowNs() - t_idx;

        var seg = try segmod.Segment.fromBytes(self.io, self.dir, self.base_path, id, fin.bytes, self.alloc, true, self.opts.mmap_preheat);
        seg.data_prefault_max = self.opts.data_prefault_max_bytes;
        self.segs.append(self.alloc, seg) catch |e| {
            // 别在这里 free(fin.bytes)：交给上面的 errdefer，否则 double free
            var s = seg;
            s.owns_idx = false;
            s.close();
            return e;
        };
        self.next_seg = id + 1;
        // 段集合变了：重算「范围是否不重叠」，供 `get` 二分定位
        self.recomputeSegLayout();

        self.mem.reset();
        // WAL 轮换：memtable 已全部落到段，这份 WAL 到此作废。
        //
        // **默认走原地截断**（`reset`）：只付一次 `setLength`，不增删目录项。
        // 旧写法是「sync → close → deleteFile → createFile」，每 flush 一次就在
        // 写路径上增删一个目录项；200 万行要 flush 25 次，而实测有约 1/7 的轮次
        // 写路径整轮崩塌 3–6 倍（同轮读正常、SQLite 正常、单次 flush 从 22ms 卡到 203ms）。
        // `wal_rotate_recreate` 只为基准 A/B 保留旧路径，生产恒 false。
        const t_rot = self.nowNs();
        if (self.opts.wal_rotate_recreate) {
            try self.wal.sync();
            self.wal.close();
            self.dir.deleteFile(self.io, self.wal_path) catch {};
            self.wal = try walmod.Wal.create(self.io, self.dir, self.wal_path, self.alloc);
            self.wal.buf_bytes = self.opts.wal_buf_bytes;
        } else {
            try self.wal.reset();
        }
        const d_rot = self.nowNs() - t_rot;
        self.ns_walrot += d_rot;
        if (d_rot > self.ns_walrot_max) self.ns_walrot_max = d_rot;
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
        self.checkThread();
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
        new_seg.data_prefault_max = self.opts.data_prefault_max_bytes;
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
        self.recomputeSegLayout();

        // 合并成功：清除自动触发积累的失败状态
        self.auto_compact_error = null;
        self.auto_compact_fails = 0;
        self.compact_bytes_total += out_bytes;

        return .{ .before = before, .after = self.segs.items.len, .rows = rows, .bytes = out_bytes, .did = true };
    }

    /// 用磁盘上的归档**重建整个段数组**。
    ///
    /// 归档被 `archiveRewrite` 换掉之后必须这么做：段的 `idx` 是**旧归档映射的切片**，
    /// rename 之后旧映射虽然还活着（Windows 上 rename 不被拒，见
    /// `test "mmap 存活时 rename 覆盖同路径"`），但它的内容已经不对应磁盘上的那份 ——
    /// 继续用就会让「内存里看到的索引」与「磁盘上的索引」永久分叉。
    fn reloadFromArchive(self: *Table) !void {
        for (self.segs.items) |*s| s.close();
        self.segs.clearRetainingCapacity();
        if (self.idx_map) |*m| m.destroy();
        self.idx_map = null;
        self.idx_archive = &.{};

        // 先落字段再做事：后面任何一步失败，`deinit` 都能把已建立的东西收干净
        self.idx_map = try segmod.mapWholeFile(self.io, self.dir, self.index_path, self.opts.index_max_bytes, self.opts.index_prefault_max_bytes);
        self.idx_archive = self.idx_map.?.bytes();
        try segmod.archiveCheckMagic(self.idx_archive);
        const opened = try openSegmentsFromArchive(
            self.io,
            self.dir,
            self.base_path,
            self.idx_archive,
            self.alloc,
            self.opts.mmap_preheat,
            self.opts.data_prefault_max_bytes,
            &self.segs,
        );
        self.index_valid_len = opened.valid_end;
        if (opened.max_id >= self.next_seg) self.next_seg = opened.max_id + 1;
        self.recomputeSegLayout();
    }

    /// **分层（size-tiered）合并**：只把最小的 `fanout` 个段合成一个段。
    ///
    /// 为什么必须有它（而不是每次全量 `compact()`）：
    /// - 全量合并每次重写「当时全部数据」，**单次阻塞时长随数据量线性增长**
    ///   （200 万行 0.4–0.7 s，线性外推 2000 万行就到秒级，期间该表串行阻塞）；
    /// - 写放大只由「总段数/阈值」决定，数据越大段越多，全量合并越不可行。
    ///   44e9 行按默认 `flush_bytes` 约 6.8 万段，全量合并等于自杀。
    ///
    /// size-tiered 的形状（对齐 Cassandra STCS / RocksDB universal compaction）：
    /// 每次只碰**同量级**的若干段，段数维持 O(log n)，写放大 ≈ log_fanout(段数)。
    ///
    /// 代价：合并后的段与幸存段 key 范围**必然重叠** ⇒ `segs_disjoint_asc` 变 false，
    /// `get` 回到「逐段倒序 + Bloom 排除」路径（实测 25 段时不命中仍有 1.6M 次/s，
    /// 见 §16.1.7）。这是用点查换「合并可终止」，段数受 `compact_max_segs` 约束后代价有限。
    pub fn compactTier(self: *Table, fanout: usize) !CompactResult {
        self.checkThread();
        const before = self.segs.items.len;
        if (fanout < 2 or before <= fanout) {
            return .{ .before = before, .after = before, .rows = 0, .did = false };
        }

        const was_going = self.going_compact;
        self.going_compact = true;
        defer self.going_compact = was_going;

        // memtable 先落盘：子集归并不包含 memtable（它还没进 WAL 轮换边界）
        if (self.mem.len() > 0) try self.flushImpl();
        const n = self.segs.items.len;
        if (fanout < 2 or n <= fanout) {
            return .{ .before = before, .after = n, .rows = 0, .did = false };
        }

        // 选「最小的 fanout 个段」（按行数；同量级时取段号小的，保证行为可预测）
        const idx = try self.alloc.alloc(usize, n);
        defer self.alloc.free(idx);
        for (0..n) |i| idx[i] = i;
        std.mem.sortUnstable(usize, idx, self.segs.items, segRowLess);
        // **必须按「同量级」成组，不能无条件取最小的 N 个。**
        // 无条件取会写出爆炸的写放大：16 段时每次合并要重写约 D/4 的数据，
        // 却只换来 3 个新段（实测写吞吐掉到 1 MB/s，比完全不合并还慢 26 倍）。
        // size-tiered 的规则是：大小不超过最小段 `TIER_RATIO` 倍的才算同一量级，
        // 凑够 fanout 个才合并，否则**什么都不做，等同量级的段攒够**。
        const min_rows = @max(@as(usize, 1), self.segs.items[idx[0]].rows);
        var in_class: usize = 0;
        while (in_class < n and self.segs.items[idx[in_class]].rows <= min_rows * TIER_RATIO) in_class += 1;
        if (in_class < fanout) {
            return .{ .before = before, .after = n, .rows = 0, .did = false };
        }
        const chosen = idx[0..fanout];
        std.mem.sort(usize, chosen, {}, std.sort.asc(usize));

        const id = self.next_seg;
        const data_path = try self.alloc.print("{s}/seg/{d:0>6}.data", .{ self.base_path, id });
        defer self.alloc.free(data_path);
        var orphan_maybe = true;
        errdefer if (orphan_maybe) self.dir.deleteFile(self.io, data_path) catch {};

        var expected_rows: usize = 0;
        for (chosen) |si| expected_rows +|= self.segs.items[si].rows;

        var w = try segmod.Writer.create(self.io, self.dir, data_path, self.alloc, self.opts.bloom_bits, expected_rows);
        defer w.deinit();
        var rows: usize = 0;
        {
            var it = MergeIter{};
            try it.initSubset(self, chosen);
            defer it.deinit();
            while (it.next()) |rec| {
                try w.push(rec.key, rec.seq, rec.flags, rec.value);
                rows += 1;
            }
        }
        const data_bytes: u64 = @intCast(w.buf_base + w.buf.items.len);
        const fin = try w.finishBytes();
        var fin_owned = true;
        errdefer if (fin_owned) self.alloc.free(fin.bytes);
        const out_bytes: u64 = data_bytes + fin.bytes.len;

        // 同 `compact()`：**先在内存里验证新段可解析**，再动磁盘。
        // 所有权直接交给新段（`take_ownership = true`），之后的错误由它释放，
        // 外层 `fin_owned` 必须立刻置 false，否则两条 errdefer 会双重释放。
        var new_seg = try segmod.Segment.fromBytes(self.io, self.dir, self.base_path, id, fin.bytes, self.alloc, true, self.opts.mmap_preheat);
        fin_owned = false;
        errdefer {
            var s = new_seg;
            s.close();
        }
        try new_seg.ensureParsed();

        // 记录段号用于删旧文件
        const del_id = try self.alloc.alloc(u32, fanout);
        defer self.alloc.free(del_id);
        for (chosen, 0..) |si, j| del_id[j] = @intCast(self.segs.items[si].id);

        // **只追加**：新段索引 + 被合并段的删除标记。
        // 不整份重写归档 —— 那是 O(总索引)×合并次数，1 亿行/4883 段要重写两千多次 × 156 MB
        // （实测 56 分钟都跑不完）。追加成本只与「新索引 + 3 条标记」有关。
        var at = try segmod.archiveAppend(self.io, self.dir, self.index_path, @intCast(id), fin.bytes, self.index_valid_len);
        at = try segmod.archiveAppendDead(self.io, self.dir, self.index_path, del_id, at);
        self.index_valid_len = at;
        orphan_maybe = false; // 归档已引用新段，不能再把它当孤儿删掉

        // 内存里的段集合就地更新：**不等价于 `reloadFromArchive`** ——
        // 追加不会移动已有字节，幸存段的 `idx` 切片（指向旧映射）仍然有效。
        {
            // 先关掉被合并的段（解除数据文件映射/句柄），再删文件：
            // Windows 上删除「还打开着」的文件会失败，而 `catch {}` 会留下永久孤儿。
            var j: usize = fanout;
            while (j > 0) {
                j -= 1;
                var s = self.segs.orderedRemove(chosen[j]);
                s.close();
            }
            try self.segs.append(self.alloc, new_seg);
        }
        // 段集合变了：重算布局并提升可见段号
        if (id >= self.next_seg) self.next_seg = id + 1;
        self.recomputeSegLayout();

        // 段已不再被归档与内存引用 → 删数据文件是安全的
        var del_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (del_id) |oid| {
            const op = std.fmt.bufPrint(&del_buf, "{s}/seg/{d:0>6}.data", .{ self.base_path, oid }) catch continue;
            self.dir.deleteFile(self.io, op) catch {};
        }

        // 归档膨胀治理：死标记累计到「超过活数据」就整份重写一次（摊还后可忽略）
        {
            var live_bytes: u64 = 0;
            for (self.segs.items) |s| live_bytes += s.idx.len;
            const total = if (self.dir.openFile(self.io, self.index_path, .{})) |f| blk: {
                defer f.close(self.io);
                break :blk (f.stat(self.io) catch break :blk live_bytes).size;
            } else |_| live_bytes;
            if (total > live_bytes * 2 + 4096) {
                const records = try self.alloc.alloc(segmod.ArchiveRecord, self.segs.items.len);
                defer self.alloc.free(records);
                for (self.segs.items, 0..) |s, i| records[i] = .{ .id = @intCast(s.id), .payload = s.idx };
                self.index_valid_len = try segmod.archiveRewrite(self.io, self.dir, self.index_path, records, self.alloc);
                // 归档换了 ⇒ 段的索引切片失效，必须整体重载（`close()` 会释放 `fin.bytes`）
                try self.reloadFromArchive();
            }
        }

        self.auto_compact_error = null;
        self.auto_compact_fails = 0;
        self.compact_bytes_total += out_bytes;

        return .{ .before = before, .after = self.segs.items.len, .rows = rows, .bytes = out_bytes, .did = true };
    }
};

fn segRowLess(segs: []segmod.Segment, a: usize, b: usize) bool {
    if (segs[a].rows != segs[b].rows) return segs[a].rows < segs[b].rows;
    return segs[a].id < segs[b].id;
}

/// 分层合并的「同量级」判据：行数不超过最小段 `TIER_RATIO` 倍就算同一级。
///
/// 取 2 与「每次合并 fanout 个同量级段」配合，段大小会沿 2×→8×→32×… 的阶梯上爬，
/// 每个段在其生命周期里被重写 ≈ log_fanout(总段数) 次（440 亿行约 7 次）。
/// 取大了（比如无条件合并最小的 N 个）写放大随数据量线性增长，实测会慢到不可用。
const TIER_RATIO: usize = 2;

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

    /// **只归并指定段子集**（分层合并用）。不包含 memtable、不走顺序拼接：
    /// 子集的 key 范围可能互相重叠（合并后的段与幸存段必然重叠），拼接的前提不成立。
    pub fn initSubset(self: *MergeIter, table: *Table, only: []const usize) !void {
        try self.initStableOnly(table, &[_]u8{}, &[_]u8{}, null, only);
    }

    /// `arena != null` 时，压缩块重建出来的 key 直接落进 arena（稳定切片，供收集型 API 使用）。
    /// **必须在建游标之前设定**：堆模式下 `init` 末尾会预读每条游标的第 1 条记录，
    /// 那批 key 若落在双缓冲里，后续推进就会把它们覆盖。
    pub fn initStable(self: *MergeIter, table: *Table, start: []const u8, end: []const u8, arena: ?*segmod.KeyArena) !void {
        try self.initStableOnly(table, start, end, arena, null);
    }

    /// 段游标的公共构造：裁剪判定 + 建游标 + 稳定 key 模式。
    fn addSegCursor(
        self: *MergeIter,
        table: *Table,
        s: *segmod.Segment,
        start: []const u8,
        end: []const u8,
        arena: ?*segmod.KeyArena,
        pruned_before: *usize,
    ) !void {
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
                    pruned_before.* += 1;
                    return;
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
                if (segmod.keyCmp(k0, end) != .lt) return;
            }
        }
        const c = try s.cursor(start, end, table.visible);
        var sc = ScanCursor{ .seg = c };
        sc.useStableKeys(arena);
        try self.cursors.append(table.alloc, sc);
    }

    fn initStableOnly(
        self: *MergeIter,
        table: *Table,
        start: []const u8,
        end: []const u8,
        arena: ?*segmod.KeyArena,
        only: ?[]const usize,
    ) !void {
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
        // 子集归并用在合并路径上，而合并前已把 memtable 落盘；仍然不碰 memtable，
        // 否则会把「未落盘的写」卷进合并结果，而它们还没进 WAL 轮换的边界。
        if (only == null and table.mem.len() > 0) {
            try self.cursors.append(alloc, .{ .mem = .{
                .it = table.mem.iteratorFrom(start),
                .end = end,
                .snapshot = table.visible,
            } });
        }
        if (only) |idxs| {
            for (idxs) |si| try self.addSegCursor(table, &table.segs.items[si], start, end, arena, &pruned_before);
        } else {
            for (table.segs.items) |*s| try self.addSegCursor(table, s, start, end, arena, &pruned_before);
        }
        if (only == null and self.cursors.items.len > 1 and canConcat(table)) {
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

// WAL 轮换改「原地截断」后的守门用例。
//
// 为什么必须有这条：旧路径是「sync → close → deleteFile → createFile」，
// 新路径只做 `setLength(0)` + 复用同一句柄。两者**语义**必须完全等价：
// flush 成功后这份 WAL 内容作废，重开时只能看到段里的数据 + 截断后新写入的数据。
// 这条用「多次 flush + 重开」把它钉住；`wal_rotate_recreate` 两种模式各跑一遍，
// 保证 A/B 开关不是只在基准里才成立的假开关。
test "flush 后 WAL 原地截断：多次 flush 后重开数据完整（truncate 与 recreate 两种模式）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    for ([_]bool{ false, true }) |recreate| {
        const tmp = if (recreate) "test-walrot-re" else "test-walrot-tr";
        dir.deleteTree(io, tmp) catch {};
        defer dir.deleteTree(io, tmp) catch {};

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        {
            // flush_bytes 取很小 → 每写几条就触发一次 flush，几轮下来 WAL 被轮换多次
            var t = try Table.open(io, dir, tmp, alloc, .{
                .wal_sync_every = 0,
                .flush_bytes = 1,
                .wal_rotate_recreate = recreate,
            });
            defer t.deinit();
            var i: u64 = 0;
            while (i < 50) : (i += 1) {
                var kb: [8]u8 = undefined;
                std.mem.writeInt(u64, &kb, i, .little);
                try t.put(&kb, "v");
                // 每写一条都会 flush；中途留下「已落段但还没再写」的状态
            }
            try t.flush();
            // flush 之后 WAL 必须是空的：非空就说明「作废的 WAL」没被清掉，
            // 重开时会把已入段的数据重复回放一遍
            var wp: [128]u8 = undefined;
            const wpath = try std.fmt.bufPrint(&wp, "{s}/wal/000001.wal", .{tmp});
            const st = try dir.statFile(io, wpath, .{});
            try std.testing.expectEqual(@as(u64, 0), st.size);
            try std.testing.expect(t.segs.items.len > 1); // 确认真的发生了多次轮换
        }

        var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t2.deinit();
        var i: u64 = 0;
        while (i < 50) : (i += 1) {
            var kb: [8]u8 = undefined;
            std.mem.writeInt(u64, &kb, i, .little);
            const v = try t2.get(&kb, &out);
            try std.testing.expect(v != null);
            try std.testing.expectEqualStrings("v", v.?);
        }
    }
}

// ---------------------------------------------------------------- 崩溃一致性
//
// 这三条守的是「掉电后能不能正确还原」这条线。现有用例覆盖了「归档尾部残片」
// （index.bin 尾部残片后新增段必须仍可见），但**没有**覆盖下面三种真实崩溃态：
//   ① put 已提交到 WAL、memtable 还没落段 → 必须靠 WAL 回放恢复；
//   ② WAL 尾部只写了半条批次 → 只能回放完整批次，半条要丢弃，且之后还能继续写；
//   ③ 段文件存在但归档没有它的记录（崩溃在 archiveAppend 之前）→ 该段必须被忽略、不得报错
//      （归档是权威；这种情况数据仍在 WAL 里，由 ① 那条路径恢复）。

test "崩溃：WAL 里有已提交批次但未落段，重开必须回放出来" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-crash-wal-replay";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // 先建出目录骨架（wal/ 目录由 Table.open 创建）
    {
        var t0 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        t0.deinit();
    }

    // 直接往 WAL 写两个已提交批次 —— 等价于「put 返回了，但 memtable 还没 flush 就掉电」
    {
        var wp: [128]u8 = undefined;
        const wpath = try std.fmt.bufPrint(&wp, "{s}/wal/000001.wal", .{tmp});
        var w = try walmod.Wal.create(io, dir, wpath, alloc);
        defer w.close();
        _ = try w.append(1, &.{.{ .flags = 0, .key = "k1", .value = "v1" }});
        _ = try w.append(2, &.{.{ .flags = 0, .key = "k2", .value = "v2" }});
        try w.sync();
    }

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();
    try std.testing.expectEqualStrings("v1", (try t.get("k1", &out)).?);
    try std.testing.expectEqualStrings("v2", (try t.get("k2", &out)).?);

    // 回放出来的行必须能正常落段，且落段后重开仍在
    try t.flush();
    var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t2.deinit();
    try std.testing.expectEqualStrings("v1", (try t2.get("k1", &out)).?);
    try std.testing.expectEqualStrings("v2", (try t2.get("k2", &out)).?);
}

test "崩溃：WAL 尾部撕裂（半条批次）只回放完整批次，且之后仍可继续写" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-crash-wal-torn";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    {
        var t0 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        t0.deinit();
    }

    var wp: [128]u8 = undefined;
    const wpath = try std.fmt.bufPrint(&wp, "{s}/wal/000001.wal", .{tmp});
    {
        var w = try walmod.Wal.create(io, dir, wpath, alloc);
        defer w.close();
        _ = try w.append(1, &.{.{ .flags = 0, .key = "ok1", .value = "v1" }});
        try w.sync();
        _ = try w.append(2, &.{.{ .flags = 0, .key = "torn", .value = "v2" }});
        try w.sync();
    }
    // 砍掉尾部 5 个字节 —— 模拟写到一半掉电
    {
        const f = try dir.openFile(io, wpath, .{ .mode = .read_write });
        defer f.close(io);
        const sz = (try f.stat(io)).size;
        try f.setLength(io, sz - 5);
        try f.sync(io);
    }

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();
    // 完整的那条必须在，被撕裂的那条必须被丢弃（不能被当成有效数据）
    try std.testing.expectEqualStrings("v1", (try t.get("ok1", &out)).?);
    try std.testing.expect((try t.get("torn", &out)) == null);

    // 撕裂之后仍能继续写并 flush，重开数据一致
    try t.put("after", "v3");
    try t.flush();
    var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t2.deinit();
    try std.testing.expectEqualStrings("v1", (try t2.get("ok1", &out)).?);
    try std.testing.expectEqualStrings("v3", (try t2.get("after", &out)).?);
}

test "崩溃：段文件存在但归档无记录时被忽略且不报错（归档是权威）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-crash-orphan-seg";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        try t.put("a", "va");
        try t.flush();
        try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
    }

    // 把归档砍回「只有 magic」，等于「崩溃发生在 archiveAppend 之前」：
    // 段文件留在盘上，但归档没有引用它。
    {
        var ip: [128]u8 = undefined;
        const ipath = try std.fmt.bufPrint(&ip, "{s}/seg/index.bin", .{tmp});
        const f = try dir.openFile(io, ipath, .{ .mode = .read_write });
        defer f.close(io);
        try f.setLength(io, 8);
        try f.sync(io);
    }

    // 必须能打开（不报错），且那个孤儿段被忽略
    var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t2.deinit();
    try std.testing.expectEqual(@as(usize, 0), t2.segs.items.len);
    try std.testing.expect((try t2.get("a", &out)) == null);

    // 之后新建的段必须仍可见（残留的孤儿文件不能让 next_seg 复用同名文件而丢数据）
    try t2.put("b", "vb");
    try t2.flush();
    var t3 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t3.deinit();
    try std.testing.expectEqualStrings("vb", (try t3.get("b", &out)).?);
}

// ---------------------------------------------------------------- 有序收尾 / 持久化档位
//
// 这一组守的是「宿主收到退出信号之后该怎么做」以及「不做会丢多少」。
// 两条命题必须**分别**有证据，不能只凭「有 WAL 所以安全」：
//   ① `close()` 之后数据全部落段、WAL 归零 —— 这是有序收尾的有效性；
//   ② `wal_buf_bytes` 的两档差别 —— 这是「强杀会不会丢」的量化口径。

/// 取磁盘上某个文件的字节数（不存在返 0）。
fn fileSizeOnDisk(io: std.Io, dir: std.Io.Dir, path: []const u8) !u64 {
    const f = dir.openFile(io, path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer f.close(io);
    return (try f.stat(io)).size;
}

test "有序收尾：close() 后数据全部落段、WAL 归零，重开一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-graceful-close";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var wp: [128]u8 = undefined;
    const wpath = try std.fmt.bufPrint(&wp, "{s}/wal/000001.wal", .{tmp});

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        var i: u32 = 0;
        while (i < 200) : (i += 1) {
            var kb: [32]u8 = undefined;
            var vb: [32]u8 = undefined;
            try t.put(try std.fmt.bufPrint(&kb, "k{d:0>4}", .{i}), try std.fmt.bufPrint(&vb, "v{d:0>4}", .{i}));
        }
        // 收尾之前：数据还在 WAL / memtable 里
        try std.testing.expectEqual(@as(usize, 0), t.segs.items.len);

        try t.close();
        // 注意：close() 内部已 deinit（`self.* = undefined`），之后**不能再碰 `t`**。
    }
    // 收尾之后：WAL 归零。此时数据只可能在段里（WAL 是空的），
    // 下面重开能读全 200 行就证明「确实落到了段」而不是靠 WAL 回放。
    try std.testing.expectEqual(@as(u64, 0), try fileSizeOnDisk(io, dir, wpath));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t2.deinit();
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        var kb: [32]u8 = undefined;
        var vb: [32]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&vb, "v{d:0>4}", .{i}),
            (try t2.get(try std.fmt.bufPrint(&kb, "k{d:0>4}", .{i}), &out)).?,
        );
    }
}

test "持久化档位：wal_buf_bytes=0 时 put 返回即已落盘（强杀不丢，与 SQLite NORMAL 对等）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-walbuf-zero";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var wp: [128]u8 = undefined;
    const wpath = try std.fmt.bufPrint(&wp, "{s}/wal/000001.wal", .{tmp});

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .wal_buf_bytes = 0 });
    defer t.deinit();

    try std.testing.expectEqual(@as(u64, 0), try fileSizeOnDisk(io, dir, wpath));
    try t.put("a", "1");
    // **第一次 put 返回后 WAL 文件就必须非 0** —— 这就是「强杀不丢」的定义：
    // 数据已经不在进程里了，进程此刻被结束也不影响。
    try std.testing.expect(try fileSizeOnDisk(io, dir, wpath) > 0);

    const after_first = try fileSizeOnDisk(io, dir, wpath);
    try t.put("b", "2");
    try std.testing.expect(try fileSizeOnDisk(io, dir, wpath) > after_first);
}

test "持久化档位：默认缓冲下 put 返回时数据仍在用户态（强杀会丢，必须靠 close/sync 兜）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-walbuf-default";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var wp: [128]u8 = undefined;
    const wpath = try std.fmt.bufPrint(&wp, "{s}/wal/000001.wal", .{tmp});

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .wal_buf_bytes = 1 << 20 });
    defer t.deinit();

    try t.put("a", "1");
    // 缓冲没满：数据**一个字节都还没出进程**。此刻被强杀 = 这条已返回成功的写丢失。
    // 这条断言不是「应该如此」，而是把「必须调 close()/sync()」的代价量化出来 ——
    // 没有它，默认档的丢失风险就只是文档里的一句空话。
    try std.testing.expectEqual(@as(u64, 0), try fileSizeOnDisk(io, dir, wpath));

    try t.sync();
    try std.testing.expect(try fileSizeOnDisk(io, dir, wpath) > 0);
}

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

// ---------------------------------------------------------------- 墓碑（删除）的正确性
//
// 「删除的成本延后到 compaction」不等于「结果可以不一致」。真正会出错的是这三条，
// 全部用用例钉住：
//   ① 删除只在 WAL 里、还没落段就崩溃重开 → 回放出来的墓碑必须仍然生效；
//   ② 删除后再插入同一个 key（复活）→ 新版本必须可见，墓碑不得压住它；
//   ③ compact 丢弃墓碑之后 → 结果不变，且**空间真的被回收**（行数降到存活数）。

test "墓碑：删除只在 WAL 里就重开，回放后必须仍然删除" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-tombstone-wal";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        try t.put("a", "va");
        try t.put("b", "vb");
        try t.delete("a");
        // **故意不 flush**：删除只存在于 WAL 里。等价于「进程在落段前就退出」。
        t.deinit();
    }

    var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t2.deinit();
    try std.testing.expect((try t2.get("a", &out)) == null); // 墓碑必须仍然生效
    try std.testing.expectEqualStrings("vb", (try t2.get("b", &out)).?);
}

test "墓碑：删除后重新插入必须复活，墓碑不得压住新版本（跨 3 段 + compact）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-tombstone-resurrect";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        // 同一个 key 依次经历：写入 → 删除 → 再写入，各自独立成段，
        // 段之间 key 范围完全重叠 → 强制走 k 路堆归并（不是顺序拼接）。
        try t.put("k", "v1");
        try t.flush();
        try t.delete("k");
        try t.flush();
        try t.put("k", "v2");
        try t.flush();
        try std.testing.expectEqual(@as(usize, 3), t.segs.items.len);

        // 归并必须按 (key asc, seq desc)：最先看到的是 v2 → 可见；不能是墓碑先出。
        try std.testing.expectEqualStrings("v2", (try t.get("k", &out)).?);

        // 合并后仍然必须是 v2（墓碑与 v1 都该被淘汰）
        const res = try t.compact();
        try std.testing.expect(res.did);
        try std.testing.expectEqual(@as(usize, 1), res.rows); // 只剩 1 条存活
        try std.testing.expectEqualStrings("v2", (try t.get("k", &out)).?);
    }

    // 重开后仍然一致
    var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t2.deinit();
    try std.testing.expectEqualStrings("v2", (try t2.get("k", &out)).?);
}

test "墓碑：同一批既有删除又有新写，memtable / 落段 / 合并三条路径结果必须一致" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-tombstone-mixed-batch";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    try t.put("a", "va1");
    try t.put("b", "vb");
    try t.put("c", "vc");

    // 尚未落盘的一批里混着：删除 b、新写 d、更新 a
    try t.delete("b");
    try t.put("d", "vd");
    try t.put("a", "va2");

    // ① memtable 路径
    try std.testing.expectEqualStrings("va2", (try t.get("a", &out)).?);
    try std.testing.expect((try t.get("b", &out)) == null);
    try std.testing.expectEqualStrings("vc", (try t.get("c", &out)).?);
    try std.testing.expectEqualStrings("vd", (try t.get("d", &out)).?);

    // ② 落段后（墓碑与更新各成一条记录）—— 结果必须一模一样
    try t.flush();
    try std.testing.expectEqualStrings("va2", (try t.get("a", &out)).?);
    try std.testing.expect((try t.get("b", &out)) == null);
    try std.testing.expectEqualStrings("vc", (try t.get("c", &out)).?);
    try std.testing.expectEqualStrings("vd", (try t.get("d", &out)).?);

    // ③ 再写一批（首段 b 已被删，这里写 b 的新值 = 复活），然后合并
    try t.put("b", "vb2");
    try t.flush();
    _ = try t.compact();
    try std.testing.expectEqualStrings("va2", (try t.get("a", &out)).?);
    try std.testing.expectEqualStrings("vb2", (try t.get("b", &out)).?); // 复活
    try std.testing.expectEqualStrings("vc", (try t.get("c", &out)).?);
    try std.testing.expectEqualStrings("vd", (try t.get("d", &out)).?);
}

test "墓碑：compact 丢弃墓碑之后，同一 key 的新写入必须正常可见" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-tombstone-after-compact-write";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        try t.put("k", "v1");
        try t.flush();
        try t.delete("k");
        try t.flush();
        // 合并后墓碑与 v1 都被丢弃 → 磁盘上根本没有 k
        const res = try t.compact();
        try std.testing.expectEqual(@as(usize, 0), res.rows);
        try std.testing.expect((try t.get("k", &out)) == null);

        // 紧接着再写 k：必须正常可见（不能因为「曾经删过」而失效）
        try t.put("k", "v3");
        try std.testing.expectEqualStrings("v3", (try t.get("k", &out)).?);
        try t.flush();
        try std.testing.expectEqualStrings("v3", (try t.get("k", &out)).?);
    }

    // 重开后仍然可见
    var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t2.deinit();
    try std.testing.expectEqualStrings("v3", (try t2.get("k", &out)).?);
}

test "墓碑：compact 丢弃墓碑后结果不变，且空间确实被回收" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-tombstone-reclaim";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    // 200 行 → 删掉一半 → 分两段落盘
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        var kb: [16]u8 = undefined;
        var vb: [16]u8 = undefined;
        try t.put(try std.fmt.bufPrint(&kb, "k{d:0>4}", .{i}), try std.fmt.bufPrint(&vb, "v{d:0>4}", .{i}));
    }
    try t.flush();
    i = 0;
    while (i < 200) : (i += 2) {
        var kb: [16]u8 = undefined;
        try t.delete(try std.fmt.bufPrint(&kb, "k{d:0>4}", .{i}));
    }
    try t.flush();
    try std.testing.expectEqual(@as(usize, 2), t.segs.items.len);

    const res = try t.compact();
    // 关键断言：合并产出的行数 = 存活行数（100）。墓碑被丢弃，不是被当成数据留下来。
    try std.testing.expectEqual(@as(usize, 100), res.rows);

    // 数据仍然正确：偶数 key 全没了，奇数 key 都在
    i = 0;
    while (i < 200) : (i += 1) {
        var kb: [16]u8 = undefined;
        var vb: [16]u8 = undefined;
        const got = try t.get(try std.fmt.bufPrint(&kb, "k{d:0>4}", .{i}), &out);
        if (i % 2 == 0) {
            try std.testing.expect(got == null);
        } else {
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&vb, "v{d:0>4}", .{i}), got.?);
        }
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

test "get 按段范围定位：不重叠时二分只碰一个段，出现重叠后自动回退且结果仍正确" {
    // 容量线（决策记录九十）实测：155 段时逐段倒序试把热态点查从 669k 次/s 拖到 99k 次/s。
    // 段头本来就有 firstKey()/maxKey()，所以不重叠时可以二分定位到唯一候选段。
    // 这条用例同时守住两件事：①不重叠时定位正确；②一旦重叠，标记必须变 false 并回退，
    // 不能因为"大多数情况不重叠"就在重叠时给出陈旧值。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-get-range";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t.deinit();

    // 3 段：1..10 / 11..20 / 21..30
    var base: u8 = 1;
    var s: u8 = 0;
    while (s < 3) : (s += 1) {
        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            var kb: [8]u8 = @splat(0);
            kb[7] = base + i;
            try t.put(&kb, "v");
        }
        base += 10;
        try t.flush();
    }
    try std.testing.expectEqual(@as(usize, 3), t.segs.items.len);
    try std.testing.expect(t.segs_disjoint_asc);

    var vbuf: std.ArrayList(u8) = .empty;
    defer vbuf.deinit(alloc);

    // 每段中间各命中一次
    for ([_]u8{ 5, 15, 25 }) |k| {
        var kb: [8]u8 = @splat(0);
        kb[7] = k;
        try std.testing.expect((try t.get(&kb, &vbuf)) != null);
    }
    // 首段之前 / 末段之后：必须返回 null（二分边界不能越界、也不能误判存在）
    {
        var kb: [8]u8 = @splat(0);
        try std.testing.expect((try t.get(&kb, &vbuf)) == null);
    }
    {
        var kb: [8]u8 = @splat(0);
        kb[7] = 31;
        try std.testing.expect((try t.get(&kb, &vbuf)) == null);
    }

    // 制造重叠：重写 15（落在第 2 段范围内部）→ 新段范围与旧段重叠
    {
        var kb: [8]u8 = @splat(0);
        kb[7] = 15;
        try t.put(&kb, "v2");
        try t.flush();
    }
    try std.testing.expect(!t.segs_disjoint_asc); // 自动回退到逐段扫
    {
        var kb: [8]u8 = @splat(0);
        kb[7] = 15;
        try std.testing.expectEqualStrings("v2", (try t.get(&kb, &vbuf)) orelse unreachable);
    }
    {
        // 回退后其它 key 也必须仍然正确
        var kb: [8]u8 = @splat(0);
        kb[7] = 5;
        try std.testing.expectEqualStrings("v", (try t.get(&kb, &vbuf)) orelse unreachable);
    }
}

test "归档丢失保护：有段数据但没有 index.bin 时拒开，不能当成空表（否则下一次 flush 会覆盖 000001.data）" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-orphan-segments";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        try t.put("k1", "v1");
        try t.flush(); // 产生 seg/000001.data + seg/index.bin
    }
    // 模拟「归档丢失」：只删 index.bin，段数据还在
    const idx_path = tmp ++ "/seg/index.bin";
    try dir.deleteFile(io, idx_path);

    // 以前这里会开出一个空表，然后 flush 时 id=1 覆盖 000001.data —— 静默丢数据
    try std.testing.expectError(
        error.ArchiveMissingButSegmentsExist,
        Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 }),
    );
    // 段数据文件必须原样还在（我们什么都没删）
    var d = try dir.openDir(io, tmp ++ "/seg", .{ .iterate = true });
    defer d.close(io);
    var found = false;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.eql(u8, e.name, "000001.data")) found = true;
    }
    try std.testing.expect(found);
}

test "空表重开不能被误判成「归档丢失」：没有 .data 时照常当新库打开" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-empty-reopen";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        // 只建目录、不写不 flush：seg/ 目录已存在但没有 .data
    }
    var t2 = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
    defer t2.deinit();
    try std.testing.expectEqual(@as(usize, 0), t2.segs.items.len);
    try t2.put("k", "v");
    var vbuf: std.ArrayList(u8) = .empty;
    defer vbuf.deinit(alloc);
    try std.testing.expectEqualStrings("v", (try t2.get("k", &vbuf)) orelse unreachable);
}

test "索引归档上限可配：index_max_bytes=0 不限，设小了明确报 FileTooBig" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-table-index-cap";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        try t.put("k1", "v1");
        try t.flush();
    }
    // 默认（0 = 不限制）能开
    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
    }
    // 上限设成 1 字节 → 明确报 FileTooBig（不是静默降级、也不是当成空表）
    try std.testing.expectError(
        error.FileTooBig,
        Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .index_max_bytes = 1 }),
    );
    // 上限给足 → 正常打开（证明失败原因就是上限，不是别的东西）
    {
        const big = @as(u64, 1) << 40;
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .index_max_bytes = big });
        defer t.deinit();
        try std.testing.expectEqual(@as(usize, 1), t.segs.items.len);
    }
}

fn tKey(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "k{d:0>6}", .{n}) catch unreachable;
}

fn tVal(buf: []u8, prefix: u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{c}{d:0>6}", .{ prefix, n }) catch unreachable;
}

// 分层合并（size-tiered）的守门用例。
//
// 为什么必须有：`compactTier` 是**唯一**会「只合并一部分段」的路径，
// 它引入两个别处没有的风险：
// 1. 幸存段的 `idx` 指向被 rename 掉的旧归档映射 —— 必须整体 `reloadFromArchive`，
//    漏了就会让内存索引与磁盘索引分叉（读得到旧值，重开后变成另一个结果）；
// 2. 合并后的段与幸存段 key 范围**必然重叠**，版本优先级只能靠 `seq`，不能靠段序。
// 用例同时钉住：数据不丢、**更新后的新值赢**、段数按预期下降、**重开后仍然一致**。
test "分层合并 compactTier：只合并最小的 N 段，数据/版本/重开都必须正确" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-tier-compact";
    dir.deleteTree(io, tmp) catch {};
    defer dir.deleteTree(io, tmp) catch {};

    const batch = 100;
    const batches = 6;

    // 第一次打开：灌 6 段（每批 100 行，flush_bytes 很小 ⇒ 每批落一个段）
    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0, .flush_bytes = 4096 });
        defer t.deinit();
        var kb: [batch][16]u8 = undefined;
        var vb: [batch][16]u8 = undefined;
        var keys: [batch][]const u8 = undefined;
        var vals: [batch][]const u8 = undefined;
        var b: usize = 0;
        while (b < batches) : (b += 1) {
            for (0..batch) |i| {
                const n = b * batch + i;
                keys[i] = tKey(&kb[i], n);
                vals[i] = tVal(&vb[i], 'v', n);
            }
            try t.putBatch(keys[0..batch], vals[0..batch]);
        }
        // 再一批：把 100..199 更新成 u....（这些 key 的最新版本在最后一段里）
        for (0..batch) |i| {
            const n = 100 + i;
            keys[i] = tKey(&kb[i], n);
            vals[i] = tVal(&vb[i], 'u', n);
        }
        try t.putBatch(keys[0..batch], vals[0..batch]);
        try t.flush();

        try std.testing.expectEqual(@as(usize, batches + 1), t.segs.items.len);

        const cr = try t.compactTier(3);
        try std.testing.expect(cr.did);
        try std.testing.expectEqual(@as(usize, batches + 1), cr.before);
        try std.testing.expectEqual(@as(usize, batches + 1 - 3 + 1), cr.after);
        try std.testing.expectEqual(cr.after, t.segs.items.len);
    }

    // 重开：证明归档重写 + 重载落到了磁盘上，而不是只在内存里对
    {
        var t = try Table.open(io, dir, tmp, alloc, .{ .wal_sync_every = 0 });
        defer t.deinit();
        try std.testing.expectEqual(@as(usize, batches + 1 - 3 + 1), t.segs.items.len);

        var kb: [16]u8 = undefined;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        var n: usize = 0;
        while (n < batches * batch) : (n += 1) {
            const want_prefix: u8 = if (n >= 100 and n < 200) 'u' else 'v';
            var wb: [16]u8 = undefined;
            const want = tVal(&wb, want_prefix, n);
            const got = try t.get(tKey(&kb, n), &out);
            try std.testing.expect(got != null);
            try std.testing.expectEqualStrings(want, got.?);
        }

        // 全表遍历：600 行、key 严格升序（重叠段归并不会乱序）
        var cnt: usize = 0;
        var it = MergeIter{};
        try it.init(&t, &[_]u8{}, &[_]u8{});
        defer it.deinit();
        var prev: [16]u8 = undefined;
        var have_prev = false;
        while (it.next()) |rec| {
            try std.testing.expect(rec.key.len <= prev.len);
            if (have_prev) {
                const pr = prev[0..rec.key.len];
                try std.testing.expect(segmod.keyCmp(pr, rec.key) == .lt);
            }
            @memcpy(prev[0..rec.key.len], rec.key);
            have_prev = true;
            cnt += 1;
        }
        try std.testing.expectEqual(@as(usize, batches * batch), cnt);
        // 段数上限字段也验证一下：设置了上限后 `maybeAutoCompact` 会收敛到 ≤ 上限
        try std.testing.expect(t.segs.items.len <= 16);
    }
}
