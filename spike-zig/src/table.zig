const std = @import("std");
const Skiplist = @import("skiplist.zig").Skiplist;
const walmod = @import("wal.zig");
const segmod = @import("segment.zig");

const RecordOwned = segmod.RecordOwned;

pub const Options = struct {
    flush_bytes: usize = 64 << 20,
    wal_sync_every: usize = 10_000,
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

/// 单表引擎（试验版）：memtable + WAL + 不可变段。
pub const Table = struct {
    io: std.Io,
    dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    base_path: []u8,
    wal_path: []u8,
    mem: Skiplist,
    segs: std.ArrayList(segmod.Segment) = .empty,
    wal: walmod.Wal,
    seq: u64 = 0,
    visible: u64 = 0,
    next_seg: u64 = 1,
    pending: usize = 0,
    opts: Options = .{},

    pub fn open(
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        alloc: std.mem.Allocator,
        opts: Options,
    ) !Table {
        try dir.createDirPath(io, path);
        const wal_dir = try alloc.print("{s}/wal", .{path});
        defer alloc.free(wal_dir);
        try dir.createDirPath(io, wal_dir);
        const seg_dir = try alloc.print("{s}/seg", .{path});
        defer alloc.free(seg_dir);
        try dir.createDirPath(io, seg_dir);

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

        const wal = try walmod.Wal.openAppend(io, dir, wal_path, alloc);

        var segs: std.ArrayList(segmod.Segment) = .empty;
        errdefer {
            for (segs.items) |*s| s.close();
            segs.deinit(alloc);
        }

        var id: u64 = 1;
        while (true) : (id += 1) {
            const dp = try alloc.print("{s}/seg/{d:0>6}.data", .{ path, id });
            defer alloc.free(dp);
            const ip = try alloc.print("{s}/seg/{d:0>6}.idx", .{ path, id });
            defer alloc.free(ip);
            const s = segmod.Segment.open(io, dir, dp, ip, alloc) catch |err| switch (err) {
                error.FileNotFound => break,
                else => return err,
            };
            try segs.append(alloc, s);
        }

        return .{
            .io = io,
            .dir = dir,
            .alloc = alloc,
            .base_path = base_path,
            .wal_path = wal_path,
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
        self.mem.deinit();
        self.wal.close();
        self.alloc.free(self.base_path);
        self.alloc.free(self.wal_path);
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

    pub fn flush(self: *Table) !void {
        if (self.mem.len() == 0) return;
        const id = self.next_seg;
        const data_path = try self.alloc.print("{s}/seg/{d:0>6}.data", .{ self.base_path, id });
        defer self.alloc.free(data_path);
        const idx_path = try self.alloc.print("{s}/seg/{d:0>6}.idx", .{ self.base_path, id });
        defer self.alloc.free(idx_path);

        var w = try segmod.Writer.create(self.io, self.dir, data_path, self.alloc);
        var it = self.mem.iterator();
        while (it.next()) |e| {
            try w.push(e.key, e.seq, e.flags, e.value);
        }
        _ = try w.finish(self.dir, idx_path);

        const seg = try segmod.Segment.open(self.io, self.dir, data_path, idx_path, self.alloc);
        try self.segs.append(self.alloc, seg);
        self.next_seg = id + 1;

        self.mem.reset();

        self.wal.close();
        self.dir.deleteFile(self.io, self.wal_path) catch {};
        self.wal = try walmod.Wal.create(self.io, self.dir, self.wal_path, self.alloc);
        self.pending = 0;
    }

    pub fn scanRange(
        self: *Table,
        start: []const u8,
        end: []const u8,
        out: *std.ArrayList(RecordOwned),
    ) !void {
        const snap = self.visible;
        var tmp: std.ArrayList(RecordOwned) = .empty;
        defer {
            for (tmp.items) |r| {
                self.alloc.free(r.key);
                self.alloc.free(r.value);
            }
            tmp.deinit(self.alloc);
        }

        var it = self.mem.iteratorFrom(start);
        while (it.next()) |e| {
            if (e.key.len < end.len and std.mem.startsWith(u8, e.key, end)) break;
            if (std.mem.order(u8, e.key, end) != .lt) break;
            if (e.seq > snap) continue;
            try tmp.append(self.alloc, .{
                .key = try self.alloc.dupe(u8, e.key),
                .seq = e.seq,
                .flags = e.flags,
                .value = try self.alloc.dupe(u8, e.value),
            });
        }

        for (self.segs.items) |*s| {
            try s.scanRange(start, end, snap, &tmp);
        }

        std.mem.sort(RecordOwned, tmp.items, {}, recLess);

        var i: usize = 0;
        while (i < tmp.items.len) {
            const key = tmp.items[i].key;
            var j = i;
            var best: ?usize = null;
            while (j < tmp.items.len and std.mem.eql(u8, tmp.items[j].key, key)) : (j += 1) {
                if (best == null or tmp.items[j].seq > tmp.items[best.?].seq) best = j;
            }
            if (best) |b| {
                if (tmp.items[b].flags == 0) {
                    try out.append(self.alloc, .{
                        .key = try self.alloc.dupe(u8, tmp.items[b].key),
                        .seq = tmp.items[b].seq,
                        .flags = 0,
                        .value = try self.alloc.dupe(u8, tmp.items[b].value),
                    });
                }
            }
            i = j;
        }
    }
};

pub fn freeRecords(alloc: std.mem.Allocator, list: *std.ArrayList(RecordOwned)) void {
    for (list.items) |r| {
        alloc.free(r.key);
        alloc.free(r.value);
    }
    list.deinit(alloc);
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

    var rows: std.ArrayList(RecordOwned) = .empty;
    defer freeRecords(alloc, &rows);
    try t2.scanRange("a", "z", &rows);
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("b", rows.items[0].key);
}
