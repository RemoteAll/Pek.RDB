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

        try self.file.writePositionalAll(self.io, &hdr, self.written);
        try self.file.writePositionalAll(self.io, self.payload.items, self.written + 8);
        const n = 8 + self.payload.items.len;
        self.written += n;
        return n;
    }

    pub fn sync(self: *Wal) !void {
        try self.file.sync(self.io);
    }

    pub fn close(self: *Wal) void {
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
        for (self.batches.items) |b| self.alloc.free(b.ops);
        self.batches.deinit(self.alloc);
        self.alloc.free(self.buf);
        self.* = undefined;
    }
};

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
    errdefer batches.deinit(alloc);

    var pos: usize = 0;
    while (pos + 8 <= data.len) {
        const crc = std.mem.readInt(u32, data[pos..][0..4], .little);
        const len: usize = @intCast(std.mem.readInt(u32, data[pos + 4 ..][0..4], .little));
        if (pos + 8 + len > data.len) break;
        const payload = data[pos + 8 ..][0..len];
        if (codec.crc32(payload) != crc) break;

        var r = codec.Reader{ .buf = payload };
        const seq = r.u64le() catch break;
        const count: usize = @intCast(r.u32le() catch break);
        const ops = try alloc.alloc(Op, count);
        var ok = true;
        for (ops) |*op| {
            op.flags = r.u8v() catch {
                ok = false;
                break;
            };
            const klen: usize = @intCast(r.varint() catch {
                ok = false;
                break;
            });
            op.key = r.bytes(klen) catch {
                ok = false;
                break;
            };
            const vlen: usize = @intCast(r.varint() catch {
                ok = false;
                break;
            });
            op.value = r.bytes(vlen) catch {
                ok = false;
                break;
            };
        }
        if (!ok) {
            alloc.free(ops);
            break;
        }
        try batches.append(alloc, .{ .seq = seq, .ops = ops });
        pos += 8 + len;
    }

    return .{ .buf = buf, .batches = batches, .alloc = alloc };
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
