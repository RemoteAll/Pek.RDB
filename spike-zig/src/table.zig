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
) !u64 {
    var it = segmod.ArchiveIter{ .buf = buf };
    var id: u64 = 1;
    while (it.next()) |payload| : (id += 1) {
        var ta: u64 = 0;
        if (segmod.timing_enabled) ta = segmod.tick(io);
        const seg = try segmod.Segment.fromBytes(io, dir, base_path, id, payload, alloc, false, preheat);
        if (segmod.timing_enabled) {
            const tb = segmod.tick(io);
            segmod.timing.mkseg += tb - ta;
            ta = tb;
        }
        segs.append(alloc, seg) catch |e| {
            var s = seg;
            s.close();
            return e;
        };
        if (segmod.timing_enabled) segmod.timing.seg_append += segmod.tick(io) - ta;
    }
    return it.validEnd();
}

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

        const valid_len = try openSegmentsFromArchive(io, dir, path, arch, alloc, opts.mmap_preheat, &segs);
        const id: u64 = @intCast(segs.items.len + 1);
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
            .index_valid_len = valid_len,
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

    pub fn flush(self: *Table) !void {
        if (self.mem.len() == 0) return;
        const id = self.next_seg;
        const data_path = try self.alloc.print("{s}/seg/{d:0>6}.data", .{ self.base_path, id });
        defer self.alloc.free(data_path);

        var w = try segmod.Writer.create(self.io, self.dir, data_path, self.alloc, self.opts.bloom_bits);
        var it = self.mem.iterator();
        while (it.next()) |e| {
            try w.push(e.key, e.seq, e.flags, e.value);
        }
        // 索引：追加到聚合文件（一次小写），并直接接管内存字节，不重复读盘
        const fin = try w.finishBytes();
        errdefer self.alloc.free(fin.bytes);
        // 从「有效末尾」写：若上次追加留下崩溃残片，这里会把它覆盖掉
        self.index_valid_len = try segmod.archiveAppend(self.io, self.dir, self.index_path, fin.bytes, self.index_valid_len);

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


