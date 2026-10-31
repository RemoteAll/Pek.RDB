const std = @import("std");
const codec = @import("codec.zig");

pub const INDEX_STRIDE: usize = 64;
const FLUSH_BYTES: usize = 1 << 20;
const IDX_MAGIC = "PEKZIX01";

pub const IndexEntry = struct {
    offset: u64,
    key: []u8,
};

pub const RecordOwned = struct {
    key: []u8,
    seq: u64,
    flags: u8,
    value: []u8,
};

pub const Meta = struct {
    rows: usize,
    min_seq: u64,
    max_seq: u64,
};

fn keyCmp(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
    }
    if (a.len == b.len) return .eq;
    return if (a.len < b.len) .lt else .gt;
}

fn hashPair(key: []const u8) [2]u64 {
    const h1 = std.hash.Wyhash.hash(0, key);
    const h2 = (h1 *% 0x9E3779B97F4A7C15) | 1;
    return .{ h1, h2 };
}

fn readWholeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator, max: u64) ![]u8 {
    const f = try dir.openFile(io, path, .{});
    defer f.close(io);
    const size = (try f.stat(io)).size;
    if (size > max) return error.FileTooBig;
    const buf = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

// ---------------- 写入 ----------------

pub const Writer = struct {
    io: std.Io,
    file: std.Io.File,
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    buf_base: u64 = 0,
    rows: usize = 0,
    entries: std.ArrayList(IndexEntry) = .empty,
    hashes: std.ArrayList(u64) = .empty,
    min_seq: u64 = std.math.maxInt(u64),
    max_seq: u64 = 0,
    scratch: std.ArrayList(u8) = .empty,

    pub fn create(io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator) !Writer {
        const f = try dir.createFile(io, path, .{ .read = true, .truncate = true });
        return .{ .io = io, .file = f, .alloc = alloc };
    }

    pub fn push(self: *Writer, key: []const u8, seq: u64, flags: u8, value: []const u8) !void {
        if (self.rows % INDEX_STRIDE == 0) {
            try self.entries.append(self.alloc, .{
                .offset = self.buf_base + self.buf.items.len,
                .key = try self.alloc.dupe(u8, key),
            });
        }

        self.scratch.clearRetainingCapacity();
        try codec.putU32le(&self.scratch, self.alloc, @intCast(key.len));
        try codec.putU32le(&self.scratch, self.alloc, @intCast(value.len));
        try codec.putU64le(&self.scratch, self.alloc, seq);
        try self.scratch.append(self.alloc, flags);
        try self.scratch.appendSlice(self.alloc, key);
        try self.scratch.appendSlice(self.alloc, value);
        try self.buf.appendSlice(self.alloc, self.scratch.items);

        const hp = hashPair(key);
        try self.hashes.append(self.alloc, hp[0]);

        self.rows += 1;
        self.min_seq = @min(self.min_seq, seq);
        self.max_seq = @max(self.max_seq, seq);

        if (self.buf.items.len >= FLUSH_BYTES) try self.flushBuf();
    }

    fn flushBuf(self: *Writer) !void {
        if (self.buf.items.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buf.items, self.buf_base);
        self.buf_base += self.buf.items.len;
        self.buf.clearRetainingCapacity();
    }

    /// 收尾：落数据、写索引（稀疏索引 + Bloom + CRC）。调用后 Writer 不可再用。
    pub fn finish(self: *Writer, idx_dir: std.Io.Dir, idx_path: []const u8) !Meta {
        try self.flushBuf();
        try self.file.sync(self.io);
        self.file.close(self.io);

        var idx: std.ArrayList(u8) = .empty;
        defer idx.deinit(self.alloc);
        try idx.appendSlice(self.alloc, IDX_MAGIC);
        try codec.putU64le(&idx, self.alloc, @intCast(self.rows));
        try codec.putU64le(&idx, self.alloc, if (self.rows == 0) 0 else self.min_seq);
        try codec.putU64le(&idx, self.alloc, self.max_seq);
        try codec.putU32le(&idx, self.alloc, @intCast(self.entries.items.len));
        for (self.entries.items) |e| {
            try codec.putU64le(&idx, self.alloc, e.offset);
            try codec.putU32le(&idx, self.alloc, @intCast(e.key.len));
            try idx.appendSlice(self.alloc, e.key);
        }

        // Bloom：10 bit/key，k=7
        const bits_len: usize = @max(@as(usize, 64), self.rows * 10);
        const bytes_len = (bits_len + 7) / 8;
        const bits = try self.alloc.alloc(u8, bytes_len);
        defer self.alloc.free(bits);
        @memset(bits, 0);
        for (self.hashes.items) |h1| {
            const h2 = (h1 *% 0x9E3779B97F4A7C15) | 1;
            var i: usize = 0;
            while (i < 7) : (i += 1) {
                const step: u64 = @as(u64, @intCast(i)) *% h2;
                const pos: usize = @intCast((h1 +% step) % @as(u64, bits_len));
                bits[pos / 8] |= @as(u8, 1) << @intCast(pos % 8);
            }
        }
        try codec.putU64le(&idx, self.alloc, bits_len);
        try idx.append(self.alloc, 7);
        try idx.appendSlice(self.alloc, bits);
        try codec.putU32le(&idx, self.alloc, codec.crc32(idx.items));

        var f = try idx_dir.createFile(self.io, idx_path, .{ .truncate = true });
        try f.writePositionalAll(self.io, idx.items, 0);
        try f.sync(self.io);
        f.close(self.io);

        const meta = Meta{
            .rows = self.rows,
            .min_seq = if (self.rows == 0) 0 else self.min_seq,
            .max_seq = self.max_seq,
        };

        for (self.entries.items) |e| self.alloc.free(e.key);
        self.entries.deinit(self.alloc);
        self.hashes.deinit(self.alloc);
        self.buf.deinit(self.alloc);
        self.scratch.deinit(self.alloc);
        return meta;
    }
};

// ---------------- 读取 ----------------

pub const Segment = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    data: []const u8 = &.{},
    mm: ?std.Io.File.MemoryMap = null,
    file: ?std.Io.File = null,
    entries: std.ArrayList(IndexEntry) = .empty,
    bits: []u8 = &.{},
    bits_len: u64 = 0,
    rows: usize = 0,
    min_seq: u64 = 0,
    max_seq: u64 = 0,
    file_size: u64 = 0,

    pub fn open(
        io: std.Io,
        dir: std.Io.Dir,
        data_path: []const u8,
        idx_path: []const u8,
        alloc: std.mem.Allocator,
    ) !Segment {
        const idx_bytes = try readWholeFile(io, dir, idx_path, alloc, 64 << 20);
        defer alloc.free(idx_bytes);
        if (idx_bytes.len < 12 or std.mem.readInt(u32, idx_bytes[idx_bytes.len - 4 ..][0..4], .little) != codec.crc32(idx_bytes[0 .. idx_bytes.len - 4])) {
            return error.BadIndexChecksum;
        }
        if (!std.mem.eql(u8, idx_bytes[0..8], IDX_MAGIC)) return error.BadIndexMagic;

        var r = codec.Reader{ .buf = idx_bytes[8..] };
        var seg = Segment{ .io = io, .alloc = alloc };
        seg.rows = @intCast(try r.u64le());
        seg.min_seq = try r.u64le();
        seg.max_seq = try r.u64le();
        const n: usize = @intCast(try r.u32le());
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const off = try r.u64le();
            const klen: usize = @intCast(try r.u32le());
            const key = try r.bytes(klen);
            try seg.entries.append(alloc, .{ .offset = off, .key = try alloc.dupe(u8, key) });
        }
        seg.bits_len = try r.u64le();
        const k = try r.u8v();
        const bits_bytes = (seg.bits_len + 7) / 8;
        seg.bits = try alloc.dupe(u8, try r.bytes(@intCast(bits_bytes)));

        // k 未存进结构：固定 7（与写入一致）
        _ = k;

        const df = try dir.openFile(io, data_path, .{});
        seg.file = df;
        seg.file_size = (try df.stat(io)).size;
        if (seg.file_size > 0) {
            var mm = try std.Io.File.MemoryMap.create(io, df, .{
                .len = @intCast(seg.file_size),
                .protection = .{ .read = true, .write = false },
            });
            try mm.read(io);
            seg.mm = mm;
            seg.data = mm.memory;
        }
        return seg;
    }

    pub fn close(self: *Segment) void {
        for (self.entries.items) |e| self.alloc.free(e.key);
        self.entries.deinit(self.alloc);
        self.alloc.free(self.bits);
        if (self.mm) |*m| m.destroy(self.io);
        if (self.file) |f| f.close(self.io);
        self.* = undefined;
    }

    fn mayContain(self: *const Segment, key: []const u8) bool {
        if (self.bits_len == 0) return true;
        const hp = hashPair(key);
        var i: usize = 0;
        while (i < 7) : (i += 1) {
            const pos: usize = @intCast((hp[0] +% (@as(u64, i) *% hp[1])) % self.bits_len);
            if ((self.bits[pos / 8] & (@as(u8, 1) << @intCast(pos % 8))) == 0) return false;
        }
        return true;
    }

    fn candidateIndex(self: *const Segment, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (keyCmp(self.entries.items[mid].key, key) == .gt) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        if (lo == 0) return 0;
        return lo - 1;
    }

    /// 点查：Bloom 否定 → 稀疏索引定位 → 读出该段记录扫描。
    /// out 为避免每次分配的复用缓冲；返回 flags。
    pub fn get(self: *Segment, key: []const u8, snapshot: u64, out: *std.ArrayList(u8)) !?u8 {
        if (!self.mayContain(key)) return null;
        if (self.entries.items.len == 0) return null;

        const i = self.candidateIndex(key);
        const begin = self.entries.items[i].offset;
        const end = if (i + 1 < self.entries.items.len) self.entries.items[i + 1].offset else self.file_size;
        if (end <= begin) return null;

        const n: usize = @intCast(end - begin);
        _ = n;
        const data = self.data[@intCast(begin)..@intCast(end)];

        var pos: usize = 0;
        while (pos + 17 <= data.len) {
            const klen = std.mem.readInt(u32, data[pos..][0..4], .little);
            const vlen = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
            const seq = std.mem.readInt(u64, data[pos + 8 ..][0..8], .little);
            const flags = data[pos + 16];
            const total = 17 + @as(usize, klen) + @as(usize, vlen);
            if (pos + total > data.len) break;
            const k = data[pos + 17 ..][0..@as(usize, klen)];
            const v = data[pos + 17 + @as(usize, klen) ..][0..@as(usize, vlen)];
            pos += total;

            switch (keyCmp(k, key)) {
                .lt => continue,
                .gt => return null,
                .eq => {
                    if (seq <= snapshot) {
                        out.clearRetainingCapacity();
                        try out.appendSlice(self.alloc, v);
                        return flags;
                    }
                },
            }
        }
        return null;
    }

    pub const RefRecord = struct {
        key: []const u8,
        seq: u64,
        flags: u8,
        value: []const u8,
    };

    /// 零拷贝扫描：输出借用 mmap 的切片（调用方保证段存活）。
    /// 同一 key 只输出一个可见版本（墓碑跳过）。
    pub fn scanRefs(self: *Segment, start: []const u8, end: []const u8, snapshot: u64, out: *std.ArrayList(RefRecord)) !void {
        if (self.entries.items.len == 0) return;
        const data = self.data;
        var pos: usize = @intCast(self.entries.items[self.candidateIndex(start)].offset);
        var cur_key: []const u8 = &.{};
        var have_cur = false;
        var decided = false;

        while (pos + 17 <= data.len) {
            const klen: usize = @intCast(std.mem.readInt(u32, data[pos..][0..4], .little));
            const vlen: usize = @intCast(std.mem.readInt(u32, data[pos + 4 ..][0..4], .little));
            const seq = std.mem.readInt(u64, data[pos + 8 ..][0..8], .little);
            const flags = data[pos + 16];
            const total = 17 + klen + vlen;
            if (pos + total > data.len) break;
            const k = data[pos + 17 ..][0..klen];
            const v = data[pos + 17 + klen ..][0..vlen];
            pos += total;

            switch (keyCmp(k, end)) {
                .gt, .eq => return,
                .lt => {},
            }
            if (keyCmp(k, start) == .lt) continue;
            if (!have_cur or !std.mem.eql(u8, k, cur_key)) {
                cur_key = k;
                have_cur = true;
                decided = false;
            }
            if (decided) continue;
            if (seq <= snapshot) {
                decided = true;
                if (flags == 0) try out.append(self.alloc, .{ .key = k, .seq = seq, .flags = flags, .value = v });
            }
        }
    }

    /// 流式游标：按 (key asc, seq desc) 逐条产出可见记录（不去重）。
    pub fn cursor(self: *Segment, start: []const u8, end: []const u8, snapshot: u64) RefCursor {
        var pos: usize = self.data.len;
        if (self.entries.items.len > 0) {
            pos = @intCast(self.entries.items[self.candidateIndex(start)].offset);
        }
        return .{ .seg = self, .pos = pos, .start = start, .end = end, .snapshot = snapshot };
    }

    /// 范围扫描（start 含、end 排他），只输出 seq <= snapshot 的记录（含墓碑）。
    pub fn scanRange(
        self: *Segment,
        start: []const u8,
        end: []const u8,
        snapshot: u64,
        out: *std.ArrayList(RecordOwned),
    ) !void {
        if (self.entries.items.len == 0) return;
        const i = self.candidateIndex(start);
        const begin: usize = @intCast(self.entries.items[i].offset);
        var pos: usize = begin;
        const data = self.data;

        while (pos + 17 <= data.len) {
            const klen: usize = @intCast(std.mem.readInt(u32, data[pos..][0..4], .little));
            const vlen: usize = @intCast(std.mem.readInt(u32, data[pos + 4 ..][0..4], .little));
            const seq = std.mem.readInt(u64, data[pos + 8 ..][0..8], .little);
            const flags = data[pos + 16];
            const total = 17 + klen + vlen;
            if (pos + total > data.len) break;
            const k = data[pos + 17 ..][0..klen];
            const v = data[pos + 17 + klen ..][0..vlen];
            pos += total;

            switch (keyCmp(k, end)) {
                .gt, .eq => return,
                .lt => {},
            }
            if (keyCmp(k, start) == .lt) continue;
            if (seq > snapshot) continue;
            try out.append(self.alloc, .{
                .key = try self.alloc.dupe(u8, k),
                .seq = seq,
                .flags = flags,
                .value = try self.alloc.dupe(u8, v),
            });
        }
    }
};

pub const RefCursor = struct {
    seg: *Segment,
    pos: usize,
    start: []const u8,
    end: []const u8,
    snapshot: u64,

    pub fn next(self: *RefCursor) ?Segment.RefRecord {
        const data = self.seg.data;
        while (self.pos + 17 <= data.len) {
            const klen: usize = @intCast(std.mem.readInt(u32, data[self.pos..][0..4], .little));
            const vlen: usize = @intCast(std.mem.readInt(u32, data[self.pos + 4 ..][0..4], .little));
            const seq = std.mem.readInt(u64, data[self.pos + 8 ..][0..8], .little);
            const flags = data[self.pos + 16];
            const total = 17 + klen + vlen;
            if (self.pos + total > data.len) return null;
            const k = data[self.pos + 17 ..][0..klen];
            const v = data[self.pos + 17 + klen ..][0..vlen];
            self.pos += total;

            switch (keyCmp(k, self.end)) {
                .gt, .eq => return null,
                .lt => {},
            }
            if (keyCmp(k, self.start) == .lt) continue;
            if (seq > self.snapshot) continue;
            return .{ .key = k, .seq = seq, .flags = flags, .value = v };
        }
        return null;
    }
};

test "segment write + point get + scan" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const tmp = "test-seg-tmp";
    dir.deleteTree(io, tmp) catch {};
    try dir.createDirPath(io, tmp);
    defer dir.deleteTree(io, tmp) catch {};

    {
        var w = try Writer.create(io, dir, tmp ++ "/000001.data", alloc);
        try w.push("a", 1, 0, "va");
        try w.push("b", 2, 0, "vb2");
        try w.push("b", 1, 0, "vb1");
        try w.push("c", 1, 0, "vc");
        const meta = try w.finish(dir, tmp ++ "/000001.idx");
        try std.testing.expectEqual(@as(usize, 4), meta.rows);
        try std.testing.expectEqual(@as(u64, 1), meta.min_seq);
        try std.testing.expectEqual(@as(u64, 2), meta.max_seq);
    }

    var seg = try Segment.open(io, dir, tmp ++ "/000001.data", tmp ++ "/000001.idx", alloc);
    defer seg.close();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const f2 = try seg.get("b", 2, &out);
    try std.testing.expectEqual(@as(u8, 0), f2.?);
    try std.testing.expectEqualStrings("vb2", out.items);

    _ = try seg.get("b", 1, &out);
    try std.testing.expectEqualStrings("vb1", out.items);

    try std.testing.expect((try seg.get("zz", 2, &out)) == null);

    var rows: std.ArrayList(RecordOwned) = .empty;
    defer {
        for (rows.items) |r| {
            alloc.free(r.key);
            alloc.free(r.value);
        }
        rows.deinit(alloc);
    }
    try seg.scanRange("a", "z", 2, &rows);
    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
    try std.testing.expectEqualStrings("a", rows.items[0].key);
    try std.testing.expectEqualStrings("c", rows.items[3].key);

    var refs: std.ArrayList(Segment.RefRecord) = .empty;
    defer refs.deinit(alloc);
    try seg.scanRefs("a", "z", 2, &refs);
    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
    try std.testing.expectEqualStrings("b", refs.items[1].key);
}
