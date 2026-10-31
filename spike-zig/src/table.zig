// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const builtin = @import("builtin");
const Skiplist = @import("skiplist.zig").Skiplist;
const walmod = @import("wal.zig");
const segmod = @import("segment.zig");

const RecordOwned = segmod.RecordOwned;

pub const Options = struct {
    flush_bytes: usize = 64 << 20,
    wal_sync_every: usize = 10_000,
    /// 打开段时是否把整个数据文件读进页缓存（默认关：冷重开只加载索引，数据按需缺页）。
    mmap_preheat: bool = false,
    /// 是否并行打开段。默认 **false**：本机实测（25 段 / 索引共 3MB，同轮 A/B）
    /// 并行 6ms vs 串行 7ms，差异在噪声内，而 IO 争用反而可能更低效；大库可手动打开。
    parallel_open: bool = false,
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

const MemCursor = struct {    it: Skiplist.Iterator,
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

/// 并行开段的任务（段之间完全独立）。
const OpenTask = struct {
    io: std.Io,
    dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    base_path: []const u8,
    id: u64,
    preheat: bool,
    seg: ?segmod.Segment = null,
    err: ?anyerror = null,
};

fn openTaskRun(t: *OpenTask) void {
    const dp = std.fmt.allocPrint(t.alloc, "{s}/seg/{d:0>6}.data", .{ t.base_path, t.id }) catch |e| {
        t.err = e;
        return;
    };
    defer t.alloc.free(dp);
    const ip = std.fmt.allocPrint(t.alloc, "{s}/seg/{d:0>6}.idx", .{ t.base_path, t.id }) catch |e| {
        t.err = e;
        return;
    };
    defer t.alloc.free(ip);
    t.seg = segmod.Segment.open(t.io, t.dir, dp, ip, t.alloc, t.preheat) catch |e| {
        t.err = e;
        return;
    };
}

/// 枚举并打开全鄨9段（000001 起，遇缺号即停）。
/// 段之间完全独立，索引读取是纯 IO + 校验，所以按批并行；单线程构建退化为串行。
/// 返回「第一个不存在的段号」。
fn openSegments(
    io: std.Io,
    dir: std.Io.Dir,
    base_path: []const u8,
    alloc: std.mem.Allocator,
    preheat: bool,
    parallel: bool,
    segs: *std.ArrayList(segmod.Segment),
) !u64 {
    const BATCH = 8;
    var next: u64 = 1;
    while (true) {
        var tasks: [BATCH]OpenTask = undefined;
        var threads: [BATCH]std.Thread = undefined;
        var launched: [BATCH]bool = @splat(false);

        var k: usize = 0;
        while (k < BATCH) : (k += 1) {
            tasks[k] = .{
                .io = io,
                .dir = dir,
                .alloc = alloc,
                .base_path = base_path,
                .id = next + k,
                .preheat = preheat,
            };
            // 空库探测：第一段的第一个同步跑（库为空时省掉一批线程创建）
            if (builtin.single_threaded or !parallel or (next == 1 and k == 0)) {
                openTaskRun(&tasks[k]);
            } else if (std.Thread.spawn(.{}, openTaskRun, .{&tasks[k]})) |th| {
                threads[k] = th;
                launched[k] = true;
            } else |_| {
                openTaskRun(&tasks[k]);
            }
        }
        k = 0;
        while (k < BATCH) : (k += 1) {
            if (launched[k]) threads[k].join();
        }

        // 按 id 顺序合并：遇到缺号即停，缺号之后（含已打开的）全部丢弃
        var miss_id: ?u64 = null;
        k = 0;
        while (k < BATCH) : (k += 1) {
            if (miss_id != null) {
                if (tasks[k].seg) |*s| s.close();
                continue;
            }
            if (tasks[k].err) |e| {
                if (tasks[k].seg) |*s| s.close();
                if (e == error.FileNotFound) {
                    miss_id = next + k;
                    continue;
                }
                var j = k + 1;
                while (j < BATCH) : (j += 1) {
                    if (tasks[j].seg) |*s| s.close();
                }
                for (segs.items) |*s| s.close();
                segs.clearRetainingCapacity();
                return e;
            }
            try segs.append(alloc, tasks[k].seg.?);
            tasks[k].seg = null;
        }
        if (miss_id) |m| return m;
        next += BATCH;
    }
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

        const id: u64 = try openSegments(io, dir, path, alloc, opts.mmap_preheat, opts.parallel_open, &segs);
        for (segs.items) |s| seq = @max(seq, s.max_seq);

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

        const seg = try segmod.Segment.open(self.io, self.dir, data_path, idx_path, self.alloc, self.opts.mmap_preheat);
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
            try cursors.append(self.alloc, .{ .seg = try s.cursor(start, end, self.visible) });
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
        .{ .name = "parallel", .opts = .{ .wal_sync_every = 0, .parallel_open = true } },
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


