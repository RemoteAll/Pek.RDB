// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const codec = @import("codec.zig");

pub const Op = struct {
    flags: u8,
    key: []const u8,
    value: []const u8,
};

/// WAL record 头长度：`u32 crc32(payload)` + `u32 payload_len`。
const WAL_REC_HDR: usize = 8;

/// 每条 op 在 `buf` 里的**预留量**：`flags(1) + klen varint(≤5) + vlen varint(≤5)`，再留 1 字节余量
/// 给 `codec.encodeVarint`（它要一个 ≥ 10 字节的可写窗口，见 `encodeBatch`）。
/// 实际写的字节数比它少，末尾按实际用量 `items.len` 收回，所以不会浪费。
const OP_RESERVE: usize = 12;

pub const Batch = struct {
    seq: u64,
    ops: []Op,
};

/// 预留量累加的溢出出口：`encodeBatch` 后面的写入全是裸指针，**少预留就等于写越界**，
/// 所以宁可显式报错也不能让 `usize` 卷回去。
fn addOrTooLarge(a: usize, b: usize) error{WalBatchTooLarge}!usize {
    return std.math.add(usize, a, b) catch error.WalBatchTooLarge;
}

pub const Wal = struct {
    io: std.Io,
    file: std.Io.File,
    written: u64 = 0,
    /// **跨 WAL 轮换累计**写入字节数（只增不减）。
    ///
    /// `written` 会在 `reset()` 后归零（那是当前文件的追加点），量「这次工作总共写了多少盘」
    /// 必须用这个：否则中途发生一次段 flush 就会把前面的量抹掉，
    /// 读出个偏小的数（实测踩过：1,000,000 行只读到 22.35MB，实际约 71B/行）。
    total_written: u64 = 0,
    /// 用户态缓冲上限（字节）。**`0` = 每次 `append` 立即 `write` 到 OS**。
    ///
    /// 这个值直接决定「进程被强杀（任务管理器结束任务 / `kill -9` / 系统关机强杀）
    /// 时，**调用方已确认成功的写**会丢多少」：
    /// - `> 0`：最多丢 `buf_bytes`（还在用户态缓冲里）；
    /// - `== 0`：一条都不丢（数据已进 OS 页缓存，进程死了内核还在；只有**掉电**才丢）。
    ///
    /// 为什么要有这个：SQLite 的 WAL 提交 **每笔都 `pwrite` 到 WAL 文件**，
    /// `synchronous=NORMAL` 只是不 `fsync`（`sqlite3.c:63192` 原文）。
    /// 也就是说默认的 256 KB 缓冲档 **比 SQLite 弱** —— 跨引擎比吞吐时必须把这条对齐。
    buf_bytes: usize = 256 * 1024,
    buf: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    pub fn create(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator) !Wal {
        const f = try dir.createFile(io, path, .{ .read = true, .truncate = true });
        return .{ .io = io, .file = f, .alloc = alloc };
    }

    /// 打开已有 WAL 并在末尾继续追加（不截断）。
    pub fn openAppend(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator) !Wal {
        const f = dir.createFile(io, path, .{ .read = true, .truncate = false }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(io, path, .{ .read = true, .truncate = true }),
            else => return err,
        };
        const size = (try f.stat(io)).size;
        return .{ .io = io, .file = f, .written = size, .alloc = alloc };
    }

    /// 追加一个提交批次（原子单位）。返回本批写入的字节数。
    pub fn append(self: *Wal, seq: u64, ops: []const Op) !usize {
        return self.encodeBatch(seq, .{ .ops = ops });
    }

    /// 同 `append`，但**直接从 key/value 数组编码**（flags 全 0）——调用方不必先建一层 `Op` 中转。
    ///
    /// 为什么需要（2026-11-04，`put_batch` 比逐行 `put` 还慢 35% 时查出来的）：
    /// 旧实现先把整批编进 `payload`、再整块 `appendSlice` 到 `buf`，`payload` 从 0 长到
    /// 几十 MB 会反复扩容搬移，接着又多一次全量拷贝；而逐行路径的 `payload` 一直在
    /// 256 KB 量级复用，扩容成本被摊平了 —— 所以「批量反而更慢」。
    pub fn appendPairs(self: *Wal, seq: u64, keys: []const []const u8, values: []const []const u8) !usize {
        std.debug.assert(keys.len == values.len);
        return self.encodeBatch(seq, .{ .pairs = .{ .keys = keys, .values = values } });
    }

    /// 批次来源：`Op` 数组（可能带 flags）或纯 key/value 数组。
    const BatchSrc = union(enum) {
        ops: []const Op,
        pairs: struct { keys: []const []const u8, values: []const []const u8 },
    };

    /// 把整批编码进 `buf`（一条 record = `[crc32][payload_len][seq][n_ops][op...]`）。
    ///
    /// **实现要点（都是实测逼出来的）**：
    /// - 容量**一次算准**再写：`ensureUnusedCapacity` 一次，之后走裸指针 ——
    ///   逐字段 `append` 会为每个字段各做一次容量检查（每行 5 次），
    ///   实测 1M 行时编码段要 **285 ms / 43 MB（仅 150 MB/s）**，改成裸写后降到几十毫秒；
    /// - 头 8 字节**先占位、末尾回填**：这样 payload 不需要中转缓冲，少一次全量拷贝；
    /// - CRC 用 `crc32Fast`（slicing-by-8）：与 1 KB 表版**逐字节等价**（见 codec 注释），
    ///   而 43 MB 上比查表版快数倍。
    fn encodeBatch(self: *Wal, seq: u64, src: BatchSrc) !usize {
        const n_ops = switch (src) {
            .ops => |ops| ops.len,
            .pairs => |p| p.keys.len,
        };
        // 预留量 = 头(8) + seq(8) + n_ops(4) + 每行 `OP_RESERVE + klen + vlen`。
        //
        // **必须用 checked add**：这个式子把「调用方给的 key/value 长度」直接累进 `usize`，
        // 一旦溢出就会**少预留**，而下面全是裸指针写入（不经 `ArrayList` 的容量检查）
        // ⇒ 直接写越界。现实的批次不可能到 usize 上限，但「不可信输入参与算术」必须显式拒绝，
        // 不能靠「应该不会」。
        var need: usize = WAL_REC_HDR + 12;
        switch (src) {
            .ops => |ops| for (ops) |op| {
                need = try addOrTooLarge(need, OP_RESERVE);
                need = try addOrTooLarge(need, op.key.len);
                need = try addOrTooLarge(need, op.value.len);
            },
            .pairs => |p| for (p.keys, p.values) |k, v| {
                need = try addOrTooLarge(need, OP_RESERVE);
                need = try addOrTooLarge(need, k.len);
                need = try addOrTooLarge(need, v.len);
            },
        }
        // **必须在写之前就拒绝超 u32 的批次**：record 头里 `n_ops` 与 `payload_len` 都是 u32，
        // 而 `@intCast` 在 ReleaseFast 下**不做检查**（溢出是未定义行为，实际表现为静默截断）——
        // 一旦截断，写出去的是一条长度字段与内容不符的 record，replay 时 CRC 必不过，
        // 整段 WAL 变成不可恢复的垃圾。宁可在这里显式报错，让调用方拆批。
        if (n_ops > std.math.maxInt(u32)) return error.WalBatchTooLarge;
        if (need - WAL_REC_HDR > std.math.maxInt(u32)) return error.WalBatchTooLarge;
        try self.buf.ensureUnusedCapacity(self.alloc, need);

        const start = self.buf.items.len;
        // 先把 `items.len` 推到「预留末尾」（占位），末尾按实际用量收回。
        // 这样做的合法性依赖：**中间没有任何可失败操作**（只有裸内存写），所以不存在
        // 「返回错误时把未初始化区当数据用」的路径。
        self.buf.items.len = start + need;
        const limit = start + need; // 写入不得越过它（Debug 断言用）
        var p: [*]u8 = self.buf.items[start..].ptr;
        p += WAL_REC_HDR;
        std.mem.writeInt(u64, p[0..8], seq, .little);
        p += 8;
        std.mem.writeInt(u32, p[0..4], @intCast(n_ops), .little);
        p += 4;

        // **`p[0..10]` 是不经边界检查的裸指针切片**（`[*]u8` 取切片没有运行时检查）：
        // 它安全的唯一依据是「每行留了 `OP_RESERVE`，且 `encodeVarint` 只会按实际需要写
        // 1..5 字节（u32 量级的长度），绝不写满 10 字节」。
        // `std.debug.assert` 在 ReleaseFast 下不生成代码，所以这里零成本。
        switch (src) {
            .ops => |ops| for (ops) |op| {
                p[0] = op.flags;
                p += 1;
                p += codec.encodeVarint(p[0..10], op.key.len);
                @memcpy(p[0..op.key.len], op.key);
                p += op.key.len;
                p += codec.encodeVarint(p[0..10], op.value.len);
                @memcpy(p[0..op.value.len], op.value);
                p += op.value.len;
                std.debug.assert(@intFromPtr(p) <= @intFromPtr(self.buf.items.ptr) + limit);
            },
            .pairs => |pr| for (pr.keys, pr.values) |k, v| {
                p[0] = 0;
                p += 1;
                p += codec.encodeVarint(p[0..10], k.len);
                @memcpy(p[0..k.len], k);
                p += k.len;
                p += codec.encodeVarint(p[0..10], v.len);
                @memcpy(p[0..v.len], v);
                p += v.len;
                std.debug.assert(@intFromPtr(p) <= @intFromPtr(self.buf.items.ptr) + limit);
            },
        }

        const payload_len = @intFromPtr(p) - (@intFromPtr(self.buf.items.ptr) + start + WAL_REC_HDR);
        // 预留量里，`WAL_REC_HDR` 给 record 头、剩下的（12 + Σ 每行）全都归 payload。
        std.debug.assert(payload_len <= need - WAL_REC_HDR); // 预留真的够（Debug）
        const rec = self.buf.items[start..][0..(WAL_REC_HDR + payload_len)];
        std.mem.writeInt(u32, rec[0..4], codec.crc32Fast(rec[WAL_REC_HDR..]), .little);
        std.mem.writeInt(u32, rec[4..8], @intCast(payload_len), .little);
        self.buf.items.len = start + WAL_REC_HDR + payload_len; // 收回多余的预留

        if (self.buf_bytes == 0 or self.buf.items.len >= self.buf_bytes) try self.flushBuf();
        return WAL_REC_HDR + payload_len;
    }

    fn flushBuf(self: *Wal) !void {
        if (self.buf.items.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buf.items, self.written);
        self.written += self.buf.items.len;
        self.total_written += self.buf.items.len;
        self.buf.clearRetainingCapacity();
    }

    pub fn sync(self: *Wal) !void {
        try self.flushBuf();
        try self.file.sync(self.io);
    }

    /// 只把用户态缓冲写进 OS、**不** `fsync`：与 SQLite `synchronous=NORMAL` 的等价档。
    /// 语义：进程被杀不丢（内核还持有），**掉电**可能丢最后一段。
    ///
    /// 为什么要这个口：跨引擎比写入吞吐必须同一持久化档 ——
    /// SQLite NORMAL 每笔提交只 `pwrite` 不 `fsync`（`sqlite3.c:63192`），
    /// 而我们每批 `fsync` 就等于拿更严的档去比，比值没有意义。
    pub fn flushToOs(self: *Wal) !void {
        try self.flushBuf();
    }

    /// **原地清空**并复用同一个文件句柄：`setLength(0)` + 复位追加点。
    ///
    /// 语义与「close + deleteFile + createFile」完全等价（flush 成功后这一点 WAL 内容已作废），
    /// 但只付**一次** `setLength`：
    /// - 少两次元数据操作（删目录项 + 重建目录项）；
    /// - **不产生新目录项** → 不会触发文件系统「新文件」实时扫描。
    ///
    /// 为什么要改：7 轮交替配对里有约 1 轮写路径**整轮崩塌 3–6 倍**（而同轮读指标正常、
    /// SQLite 同轮正常），实测段 flush 单次从 22ms 卡到 203ms。200 万行要 flush 25 次，
    /// 每次删+建一个 WAL 文件 —— 这是写路径上**唯一**会产生目录项增删的地方。
    pub fn reset(self: *Wal) !void {
        self.buf.clearRetainingCapacity();
        try self.file.setLength(self.io, 0);
        // **`written` 必须在 `sync` 之前置 0**：`setLength` 已经成功、文件就是 0 字节了，
        // 而 `sync` 若失败会把错误往上抛。此时若 `written` 还是旧值，下一次 `flushBuf`
        // 会用 `writePositionalAll(buf, written)` 在末尾**打一个空洞** —— 文件前 `written`
        // 字节全是 0，重开时 `parseBatches` 在偏移 0 就把前面当撕裂尾，**空洞之后的 WAL 全丢**。
        self.written = 0;
        try self.file.sync(self.io);
    }

    pub fn close(self: *Wal) void {
        // 收尾写盘失败**不能吞**：缓冲里的行是调用方已确认成功的写，写不出去就是真丢。
        // `close` 是资源释放路径（调用链上是 `deinit`，返回 void），没法把错误往上抛，
        // 所以至少必须留下可检索的日志并说清后果 —— 静默吞掉等于让数据消失且没人知道。
        self.flushBuf() catch |e| std.log.err(
            "WAL 收尾写盘失败：缓冲 {d} 字节未能落盘，已确认的写将丢失（原因：{s}）",
            .{ self.buf.items.len, @errorName(e) },
        );
        self.buf.deinit(self.alloc);
        self.file.close(self.io);
        self.* = undefined;
    }
};

pub const Replay = struct {
    buf: []u8,
    batches: std.ArrayList(Batch),
    alloc: std.mem.Allocator,

    pub fn count(self: *const Replay) usize {
        return self.batches.items.len;
    }

    pub fn deinit(self: *Replay) void {
        // 复用 `freeBatches`：同一逻辑不能有两份（否则将来改一处漏一处）。
        freeBatches(&self.batches, self.alloc);
        self.alloc.free(self.buf);
        self.* = undefined;
    }
};

pub const ReplayAndWal = struct {
    replay: Replay,
    wal: Wal,
};

/// 解析一个批次的 payload。返回的 `ops` 由调用方负责释放。
fn parseBatch(payload: []const u8, alloc: std.mem.Allocator) !Batch {
    var r = codec.Reader{ .buf = payload };
    const seq = try r.u64le();
    const count: usize = @intCast(try r.u32le());
    const ops = try alloc.alloc(Op, count);
    errdefer alloc.free(ops);
    for (ops) |*op| {
        op.flags = try r.u8v();
        const klen: usize = @intCast(try r.varint());
        op.key = try r.bytes(klen);
        const vlen: usize = @intCast(try r.varint());
        op.value = try r.bytes(vlen);
    }
    return .{ .seq = seq, .ops = ops };
}

/// 顺序解析 WAL 字节流；遇到 CRC 不符 / 长度越界 / 字段解析失败即**停止**
/// （容忍断电撕裂尾，不报错）。返回已消费的字节数。
fn parseBatches(data: []const u8, alloc: std.mem.Allocator, batches: *std.ArrayList(Batch)) !usize {
    var pos: usize = 0;
    while (pos + 8 <= data.len) {
        const crc = std.mem.readInt(u32, data[pos..][0..4], .little);
        const len: usize = @intCast(std.mem.readInt(u32, data[pos + 4 ..][0..4], .little));
        if (pos + 8 + len > data.len) break;
        const payload = data[pos + 8 ..][0..len];
        if (codec.crc32(payload) != crc) break;
        const b = parseBatch(payload, alloc) catch break;
        batches.append(alloc, b) catch |e| {
            alloc.free(b.ops);
            return e;
        };
        pos += 8 + len;
    }
    return pos;
}

fn freeBatches(batches: *std.ArrayList(Batch), alloc: std.mem.Allocator) void {
    for (batches.items) |b| alloc.free(b.ops);
    batches.deinit(alloc);
}

/// 一次 open 同时完成「读旧内容」与「取追加句柄」。
///
/// 旧做法是 `replay()` 打开一次读、`Wal.openAppend()` 再打开一次写 ——
/// 同一个文件两次 `createFile`/`openFile` + 两次 `stat`。Windows 上单次 open 实测
/// 0.1–0.15 ms，在冷重开只剩 0.67 ms 的情况下占比过半（见架构 §16.1.16）。
/// 合并后只剩一次 open + 一次 stat。
///
/// 返回值里 `replay.buf` 与 `wal.file` 各自独立：调用方先 `replay.deinit()`，
/// `wal` 继续用于追加直到 `close()`。
pub fn openReplay(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator) !ReplayAndWal {
    // 一次性拿到可读可写的句柄；不存在则创建（与 `openAppend` 的语义一致）。
    const f = dir.createFile(io, path, .{ .read = true, .truncate = false }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, path, .{ .read = true, .truncate = true }),
        else => return err,
    };
    errdefer f.close(io);

    const size: usize = @intCast((try f.stat(io)).size);
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);

    var batches: std.ArrayList(Batch) = .empty;
    errdefer freeBatches(&batches, alloc);
    _ = try parseBatches(buf[0..n], alloc, &batches);

    // `written` 用文件实际长度：撕裂尾之后的位置才是安全追加点（与旧语义一致）。
    return .{
        .replay = .{ .buf = buf, .batches = batches, .alloc = alloc },
        .wal = .{ .io = io, .file = f, .written = size, .alloc = alloc },
    };
}

/// 读取 WAL；CRC/长度损坏或撕裂尾记录处停止（容忍断电）。
pub fn replay(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator) !Replay {
    const f = dir.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .buf = try alloc.alloc(u8, 0),
            .batches = .empty,
            .alloc = alloc,
        },
        else => return err,
    };
    defer f.close(io);

    const st = try f.stat(io);
    const size: usize = @intCast(st.size);
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    const data = buf[0..n];

    var batches: std.ArrayList(Batch) = .empty;
    // 用 `freeBatches` 而不是 `batches.deinit`：后者只释放数组本身，
    // 已解析出来的 `ops` 会漏（旧实现就有这个漏点）。
    errdefer freeBatches(&batches, alloc);
    _ = try parseBatches(data, alloc, &batches);

    return .{ .buf = buf, .batches = batches, .alloc = alloc };
}

test "wal reset：原地截断后文件为 0 字节，旧批次不得被回放" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-wal-reset";
    dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);
    defer dir.deleteTree(io, tmp) catch {};

    const path = tmp ++ "/000001.wal";

    var w = try Wal.create(io, dir, path, alloc);
    _ = try w.append(1, &.{.{ .flags = 0, .key = "k1", .value = "v1" }});
    try w.sync();
    // 先确认「确实写出了内容」——否则下面的「截断成功」只是空文件对空文件的假相等
    try std.testing.expect((try dir.statFile(io, path, .{})).size > 0);

    try w.reset();
    try std.testing.expectEqual(@as(u64, 0), (try dir.statFile(io, path, .{})).size);
    // `written`（追加点）必须与文件长度一致。它若停在旧值，下一次 flushBuf 会在末尾
    // 打一个空洞，重开时 parseBatches 在偏移 0 就把前面当撕裂尾 → 空洞之后的 WAL 全丢。
    // （这个不一致只在 `sync` 失败时才会出现，本用例覆盖不到那条失败路径，见审计报告。）
    try std.testing.expectEqual(@as(u64, 0), w.written);

    // 截断后写入的新批次必须能被读到，且**只能读到这一批**
    _ = try w.append(2, &.{.{ .flags = 0, .key = "k2", .value = "v2" }});
    try w.sync();
    w.close();

    var rp = try openReplay(io, dir, path, alloc);
    defer rp.replay.deinit();
    defer rp.wal.close();
    try std.testing.expectEqual(@as(usize, 1), rp.replay.batches.items.len);
    try std.testing.expectEqual(@as(u64, 2), rp.replay.batches.items[0].seq);
    try std.testing.expectEqualStrings("k2", rp.replay.batches.items[0].ops[0].key);
}

test "wal append + replay" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-wal-tmp";
    dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);
    defer dir.deleteTree(io, tmp) catch {};

    {
        var w = try Wal.create(io, dir, tmp ++ "/000001.wal", alloc);
        defer w.close();
        _ = try w.append(1, &.{.{ .flags = 0, .key = "k1", .value = "v1" }});
        _ = try w.append(2, &.{
            .{ .flags = 0, .key = "k2", .value = "v2" },
            .{ .flags = 1, .key = "k3", .value = "" },
        });
        try w.sync();
    }

    var r = try replay(io, dir, tmp ++ "/000001.wal", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.count());
    try std.testing.expectEqual(@as(u64, 2), r.batches.items[1].seq);
    try std.testing.expectEqual(@as(usize, 2), r.batches.items[1].ops.len);
    try std.testing.expectEqualStrings("k2", r.batches.items[1].ops[0].key);
    try std.testing.expectEqual(@as(u8, 1), r.batches.items[1].ops[1].flags);
}

test "wal 编码：varint 进位边界（127/128/16383/16384/7 万）与空 key/空 value 必须逐字节往返" {
    // **为什么必须测这几个长度**：`encodeBatch` 现在是「一次算准容量 + 裸指针写」，
    // 而长度是用 varint 编码的 —— 127→128、16383→16384 正是 varint 从 1 字节变 2 字节、
    // 2 字节变 3 字节的进位点。预留量只要在进位点算少 1 字节，写就越界；
    // 而既有往返用例的 key/value 都很短（8/32 字节，varint 恒 1 字节），**覆盖不到这些点**。
    // 空 key / 空 value 也要测：它们的 varint 是 1 字节 0x00，长度 0 最容易在上界里被算掉。
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-wal-varint-edges";
    dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);
    defer dir.deleteTree(io, tmp) catch {};

    // 边界长度：0 / 1 / 127 / 128 / 16383 / 16384 / 70000（跨 3 字节 varint）
    const lens = [_]usize{ 0, 1, 127, 128, 16383, 16384, 70000 };
    const big = try alloc.alloc(u8, lens[lens.len - 1]);
    defer alloc.free(big);
    for (big, 0..) |*b, i| b.* = @truncate('a' + (i % 26));

    {
        var w = try Wal.create(io, dir, tmp ++ "/000001.wal", alloc);
        defer w.close();
        var seq: u64 = 0;
        // ① 逐个长度：key 长 = len、value 空
        for (lens) |len| {
            seq += 1;
            _ = try w.append(seq, &.{.{ .flags = 0, .key = big[0..len], .value = "" }});
        }
        // ② 逐个长度：key 空、value 长 = len
        for (lens) |len| {
            seq += 1;
            _ = try w.append(seq, &.{.{ .flags = 1, .key = "", .value = big[0..len] }});
        }
        // ③ 同一批里混合各种长度（走 out = appendPairs 那条也不会错）
        var keys: [lens.len][]const u8 = undefined;
        var vals: [lens.len][]const u8 = undefined;
        for (lens, 0..) |len, i| {
            keys[i] = big[0..len];
            vals[i] = big[0..lens[lens.len - 1 - i]];
        }
        seq += 1;
        _ = try w.appendPairs(seq, &keys, &vals);
        try w.sync();
    }

    var r = try replay(io, dir, tmp ++ "/000001.wal", alloc);
    defer r.deinit();
    try std.testing.expectEqual(lens.len * 2 + 1, r.count());

    for (lens, 0..) |len, i| {
        const b = r.batches.items[i];
        try std.testing.expectEqual(@as(u64, @intCast(i + 1)), b.seq);
        try std.testing.expectEqual(@as(usize, 1), b.ops.len);
        try std.testing.expectEqualSlices(u8, big[0..len], b.ops[0].key);
        try std.testing.expectEqual(@as(usize, 0), b.ops[0].value.len);
    }
    for (lens, 0..) |len, i| {
        const b = r.batches.items[lens.len + i];
        try std.testing.expectEqual(@as(usize, 0), b.ops[0].key.len);
        try std.testing.expectEqual(@as(u8, 1), b.ops[0].flags);
        try std.testing.expectEqualSlices(u8, big[0..len], b.ops[0].value);
    }
    {
        const b = r.batches.items[lens.len * 2];
        try std.testing.expectEqual(lens.len, b.ops.len);
        for (lens, 0..) |len, i| {
            try std.testing.expectEqualSlices(u8, big[0..len], b.ops[i].key);
            try std.testing.expectEqualSlices(u8, big[0..lens[lens.len - 1 - i]], b.ops[i].value);
        }
    }
}
