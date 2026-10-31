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
};

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

const MemCursor = struct {
    it: Skiplist.Iterator,
    end: []const u8,
    snapshot: u64,

    fn next(self: *MemCursor) ?segmod.Segment.RefRecord {
        while (self.it.next()) |e| {
            if (std.mem.order(u8, e.key, self.end) != .lt) return null;
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
            seq = @max(seq, s.max_seq);
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

        try self.wal.sync();
        self.wal.close();
        self.dir.deleteFile(self.io, self.wal_path) catch {};
        self.wal = try walmod.Wal.create(self.io, self.dir, self.wal_path, self.alloc);
        self.pending = 0;
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
        var cursors: std.ArrayList(ScanCursor) = .empty;
        defer cursors.deinit(self.alloc);

        if (self.mem.len() > 0) {
            try cursors.append(self.alloc, .{ .mem = .{
                .it = self.mem.iteratorFrom(start),
                .end = end,
                .snapshot = self.visible,
            } });
        }
        for (self.segs.items) |*s| {
            try cursors.append(self.alloc, .{ .seg = s.cursor(start, end, self.visible) });
        }
        if (cursors.items.len == 0) return;

        // 单游标（单段或仅 memtable）：直接顺序去重，省掉 k 路选择开销。
        if (cursors.items.len == 1) {
            var last_key: []const u8 = &.{};
            var have_last = false;
            while (cursors.items[0].next()) |rec| {
                if (have_last and std.mem.eql(u8, rec.key, last_key)) continue;
                last_key = rec.key;
                have_last = true;
                if (rec.flags == 0) try out.append(self.alloc, rec);
            }
            return;
        }

        const cur = try self.alloc.alloc(?segmod.Segment.RefRecord, cursors.items.len);
        defer self.alloc.free(cur);
        for (cursors.items, 0..) |*c, i| cur[i] = c.next();

        var last_key: []const u8 = &.{};
        var have_last = false;
        while (true) {
            var best: ?usize = null;
            for (cur, 0..) |maybe, i| {
                const r = maybe orelse continue;
                if (best == null) {
                    best = i;
                    continue;
                }
                const b = cur[best.?].?;
                if (refLess({}, r, b)) best = i;
            }
            const bi = best orelse break;
            const rec = cur[bi].?;
            cur[bi] = cursors.items[bi].next();

            if (have_last and std.mem.eql(u8, rec.key, last_key)) continue;
            last_key = rec.key;
            have_last = true;
            if (rec.flags == 0) try out.append(self.alloc, rec);
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


