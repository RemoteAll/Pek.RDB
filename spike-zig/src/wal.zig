// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const codec = @import("codec.zig");

pub const Op = struct {
    flags: u8,
    key: []const u8,
    value: []const u8,
};

pub const Batch = struct {
    seq: u64,
    ops: []Op,
};

pub const Wal = struct {
    io: std.Io,
    file: std.Io.File,
    written: u64 = 0,
    buf: std.ArrayList(u8) = .empty,
    payload: std.ArrayList(u8) = .empty,
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
        self.payload.clearRetainingCapacity();
        try codec.putU64le(&self.payload, self.alloc, seq);
        try codec.putU32le(&self.payload, self.alloc, @intCast(ops.len));
        for (ops) |op| {
            try self.payload.append(self.alloc, op.flags);
            try codec.putVarint(&self.payload, self.alloc, op.key.len);
            try self.payload.appendSlice(self.alloc, op.key);
            try codec.putVarint(&self.payload, self.alloc, op.value.len);
            try self.payload.appendSlice(self.alloc, op.value);
        }

        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], codec.crc32(self.payload.items), .little);
        std.mem.writeInt(u32, hdr[4..8], @intCast(self.payload.items.len), .little);

        // 先入用户态缓冲，达到阈值或 sync 时批量落盘（组提交）。
        try self.buf.appendSlice(self.alloc, &hdr);
        try self.buf.appendSlice(self.alloc, self.payload.items);
        const n = 8 + self.payload.items.len;
        if (self.buf.items.len >= 256 * 1024) try self.flushBuf();
        return n;
    }

    fn flushBuf(self: *Wal) !void {
        if (self.buf.items.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buf.items, self.written);
        self.written += self.buf.items.len;
        self.buf.clearRetainingCapacity();
    }

    pub fn sync(self: *Wal) !void {
        try self.flushBuf();
        try self.file.sync(self.io);
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
        try self.file.sync(self.io);
        self.written = 0;
    }

    pub fn close(self: *Wal) void {
        self.flushBuf() catch {};
        self.buf.deinit(self.alloc);
        self.payload.deinit(self.alloc);
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
