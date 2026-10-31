// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
//
// M0 档：极小资源 KV 存储层（目标 8KB RAM、无 OS、无堆、无 mmap）。
// 设计要点见 docs/架构设计.md §16.5.8：
//   - 键哈希分区，每分区一条追加日志 → 查 key 只读该分区的扇区，常驻 RAM 里**不存任何 key**；
//   - 所有缓冲由调用方提供（scratch），结构体本身固定大小；
//   - 记录自带 CRC32，撕裂尾/坏记录即视为分区末尾，上电重放自愈；
//   - 块设备是 4 个函数指针 + 容量/扇区大小 → NOR/NAND Flash、SD、EEPROM、RAM 盘都能接。

const std = @import("std");
const codec = @import("codec.zig");

pub const Error = error{
    DeviceFailure,
    KeyTooLong,
    ValueTooLong,
    NoSpace,
    BufferTooSmall,
    BadPartitions,
    NotFound,
};

/// 块设备抽象（零分配、零 OS 依赖）。
pub const BlockDevice = struct {
    pub const VTable = struct {
        /// 读：offset 与 buf.len 都按扇区对齐。
        read: *const fn (ctx: *anyopaque, offset: u32, buf: []u8) Error!void,
        /// 写：只能把 0xFF/0x00 变成数据（NOR Flash 语义）；offset 按扇区对齐。
        write: *const fn (ctx: *anyopaque, offset: u32, bytes: []const u8) Error!void,
        /// 擦除：offset/len 按扇区对齐，擦成 0xFF。
        erase: *const fn (ctx: *anyopaque, offset: u32, len: u32) Error!void,
        sync: *const fn (ctx: *anyopaque) Error!void,
    };

    ctx: *anyopaque,
    vtable: *const VTable,
    capacity: u32,
    sector_size: u32,

    pub fn read(self: *const BlockDevice, offset: u32, buf: []u8) Error!void {
        return self.vtable.read(self.ctx, offset, buf);
    }
    pub fn write(self: *const BlockDevice, offset: u32, bytes: []const u8) Error!void {
        return self.vtable.write(self.ctx, offset, bytes);
    }
    pub fn erase(self: *const BlockDevice, offset: u32, len: u32) Error!void {
        return self.vtable.erase(self.ctx, offset, len);
    }
    pub fn sync(self: *const BlockDevice) Error!void {
        return self.vtable.sync(self.ctx);
    }
};

pub const Config = struct {
    /// 分区数（必须是 2 的幂，且 ≤ 实例化的 max_parts）。越多分区 → 单次 get 读得越少、可用空间越碎。
    partitions: u8 = 8,
    key_max: u8 = 32,
    value_max: u16 = 64,
};

/// CRC 实现必须是**编译期**选择：否则三个实现（含 1KB 表）会被全部链进固件。
pub const CrcKind = enum { table, nibble, bitwise };

fn crcOf(comptime kind: CrcKind, bytes: []const u8) u32 {
    return switch (kind) {
        .table => codec.crc32(bytes),
        .nibble => codec.crc32Nibble(bytes),
        .bitwise => codec.crc32Bitwise(bytes),
    };
}

/// 记录：`[op u8][klen u8][vlen u16][key][value][crc32 u32]`
const OP_PUT: u8 = 0x01;
const OP_DEL: u8 = 0x02;
const BLANK: u8 = 0xFF;
const header_len: usize = 4;
const trailer_len: usize = 4;

/// 按「编译期最大分区数 + CRC 实现」实例化：`StoreType(2, .bitwise)` 的常量区与 RAM 都最小。
pub fn StoreType(comptime max_parts: usize, comptime crc_kind: CrcKind) type {
    return struct {
        const Self = @This();

        dev: BlockDevice,
        cfg: Config,
        /// 每个分区占用的字节数（cap / partitions，向下对齐到扇区）
        part_size: u32,
        /// 每个分区的下一个追加位置（绝对偏移）
        append_at: [max_parts]u32,
        /// 每个分区最低的「仍可能有存活记录」扇区起点；压缩后才能向后推进（回卷靠它）
        tail_at: [max_parts]u32,

    /// 打开：扫描各分区定位追加点。`scratch` 至少一个扇区，打开后可复用。
    pub fn open(dev: BlockDevice, cfg: Config, scratch: []u8) Error!Self {
        if (cfg.partitions == 0 or cfg.partitions > max_parts) return error.BadPartitions;
        if (cfg.partitions & (cfg.partitions - 1) != 0) return error.BadPartitions;
        if (dev.sector_size == 0 or dev.capacity < dev.sector_size) return error.BadPartitions;
        if (scratch.len < dev.sector_size) return error.BufferTooSmall;

        var self = Self{
            .dev = dev,
            .cfg = cfg,
            .part_size = (dev.capacity / cfg.partitions) & ~(dev.sector_size - 1),
            .append_at = @splat(0),
            .tail_at = @splat(0),
        };
        if (self.part_size < dev.sector_size) return error.BadPartitions;

        var p: u8 = 0;
        while (p < cfg.partitions) : (p += 1) {
            self.append_at[p] = try self.scanPartition(p, scratch);
        }
        return self;
    }

    /// 分区起点
    pub fn partitionStart(self: *const Self, p: u8) u32 {
        return @as(u32, p) * self.part_size;
    }

    pub fn partitionEnd(self: *const Self, p: u8) u32 {
        return @as(u32, p + 1) * self.part_size;
    }

    fn partitionOf(self: *const Self, key: []const u8) u8 {
        var h: u32 = 2166136261;
        for (key) |b| {
            h ^= b;
            h *%= 16777619;
        }
        return @intCast(h & (self.cfg.partitions - 1));
    }

    /// 扫描整个分区，返回可安全追加的位置。
    /// 规则：扇区首字节是 0xFF → 数据到此为止；扇区内出现填充/撕裂记录 → 该扇区剩余不可用，
    /// 追加点移到下一个扇区边界（NOR Flash 只能 1→0，已被编程的字节不能再写）。
    fn scanPartition(self: *Self, p: u8, scratch: []u8) Error!u32 {
        const start = self.partitionStart(p);
        const end = self.partitionEnd(p);
        const ssize = self.dev.sector_size;

        var last_end: u32 = start;
        var tail: u32 = end; // 全空时 tail = 末尾（表示没有存活数据）
        var pos = start;
        while (pos < end) : (pos += ssize) {
            try self.dev.read(pos, scratch[0..ssize]);
            // 空白扇区可能出现在中间（压缩后会这样），不能当作「数据结束」直接 break
            if (scratch[0] == BLANK) continue;
            if (tail == end) tail = pos;

            var off: usize = 0;
            var clean = true;
            while (off + header_len + trailer_len <= ssize) {
                const b = scratch[off];
                if (b != OP_PUT and b != OP_DEL) {
                    clean = false;
                    break;
                }
                const klen: usize = scratch[off + 1];
                const vlen: usize = std.mem.readInt(u16, scratch[off + 2 ..][0..2], .little);
                const total = header_len + klen + vlen + trailer_len;
                if (off + total > ssize) {
                    clean = false;
                    break;
                }
                const want = std.mem.readInt(u32, scratch[off + total - trailer_len ..][0..4], .little);
                if (want != crcOf(crc_kind, scratch[off .. off + total - trailer_len])) {
                    clean = false;
                    break;
                }
                off += total;
            }
            if (!clean) {
                // 撕裂或填充：本扇区剩余不可再写，跳到下一扇区（回卷后后面可能还有数据）
                if (pos + ssize > last_end) last_end = pos + ssize;
                continue;
            }
            if (off > 0 and pos + @as(u32, @intCast(off)) > last_end) {
                last_end = pos + @as(u32, @intCast(off));
            }
        }
        if (tail == end and last_end != start) tail = start;
        self.tail_at[p] = tail;
        return last_end;
    }

    /// 取 key：只读它所属的分区，值拷进 `out`。
    /// 返回 `null` = 不存在（或被删除）。
    pub fn get(self: *Self, key: []const u8, out: []u8, scratch: []u8) Error!?[]const u8 {
        if (key.len > self.cfg.key_max) return error.KeyTooLong;
        if (scratch.len < self.dev.sector_size) return error.BufferTooSmall;

        const p = self.partitionOf(key);
        const start = self.partitionStart(p);
        const end = self.partitionEnd(p);
        const ssize = self.dev.sector_size;

        var found: ?usize = null;
        var best_dist: u32 = 0;
        var have_best = false;
        const part = self.part_size;
        const tail = self.tail_at[p];
        var pos = start;
        while (pos < end) : (pos += ssize) {
            try self.dev.read(pos, scratch[0..ssize]);
            var off: usize = 0;
            while (off + header_len + trailer_len <= ssize) {
                const b = scratch[off];
                if (b != OP_PUT and b != OP_DEL) break;
                const klen: usize = scratch[off + 1];
                const vlen: usize = std.mem.readInt(u16, scratch[off + 2 ..][0..2], .little);
                const total = header_len + klen + vlen + trailer_len;
                if (off + total > ssize) break;
                const want = std.mem.readInt(u32, scratch[off + total - trailer_len ..][0..4], .little);
                if (want != crcOf(crc_kind, scratch[off .. off + total - trailer_len])) break;

                const k = scratch[off + header_len ..][0..klen];
                if (std.mem.eql(u8, k, key)) {
                    // 环形日志：离 tail 越远越新
                    const abs = pos + @as(u32, @intCast(off));
                    const dist = if (tail == end) abs - start else (abs + part - tail) % part;
                    if (!have_best or dist >= best_dist) {
                        have_best = true;
                        best_dist = dist;
                        if (b == OP_DEL) {
                            found = null;
                        } else {
                            if (vlen > out.len) return error.BufferTooSmall;
                            @memcpy(out[0..vlen], scratch[off + header_len + klen ..][0..vlen]);
                            found = vlen;
                        }
                    }
                }
                off += total;
            }
        }
        if (found) |n| return out[0..n];
        return null;
    }

    /// 写 key（覆盖语义：同 key 后写为准）。
    pub fn put(self: *Self, key: []const u8, value: []const u8, scratch: []u8) Error!void {
        return self.append(OP_PUT, key, value, scratch);
    }

    /// 删 key（写墓碑，语义上覆盖之前的 put）。
    pub fn del(self: *Self, key: []const u8, scratch: []u8) Error!void {
        return self.append(OP_DEL, key, &.{}, scratch);
    }

    fn append(self: *Self, op: u8, key: []const u8, value: []const u8, scratch: []u8) Error!void {
        if (key.len == 0 or key.len > self.cfg.key_max) return error.KeyTooLong;
        if (value.len > self.cfg.value_max) return error.ValueTooLong;
        const total = header_len + key.len + value.len + trailer_len;
        if (scratch.len < self.dev.sector_size or scratch.len < total) return error.BufferTooSmall;

        scratch[0] = op;
        scratch[1] = @intCast(key.len);
        std.mem.writeInt(u16, scratch[2..4], @intCast(value.len), .little);
        @memcpy(scratch[header_len..][0..key.len], key);
        @memcpy(scratch[header_len + key.len ..][0..value.len], value);
        const body = total - trailer_len;
        std.mem.writeInt(u32, scratch[body..][0..4], crcOf(crc_kind, scratch[0..body]), .little);

        try self.rawAppend(self.partitionOf(key), scratch[0..total]);
    }

    /// 追加一段已组好的记录（供 put 与压缩复用）。尾部放不下则回卷到分区头（环形日志）。
    fn rawAppend(self: *Self, p: u8, rec: []const u8) Error!void {
        const ssize = self.dev.sector_size;
        const start = self.partitionStart(p);
        const end = self.partitionEnd(p);
        const tail = self.tail_at[p];

        var at: ?u32 = null;
        if (self.findSlot(p, self.append_at[p], rec.len)) |slot| {
            if (tail == end or slot >= tail or slot + rec.len <= tail) at = slot;
        }
        if (at == null) {
            // 尾部放不下（或会压到存活区）→ 回卷到分区头，且不得越过 tail
            if (tail == end) {
                at = self.findSlot(p, start, rec.len);
            } else if (self.findSlot(p, start, rec.len)) |slot| {
                if (slot + rec.len <= tail) at = slot;
            }
        }
        const at_pos = at orelse return error.NoSpace;
        if (tail != end and at_pos < tail and at_pos + rec.len > tail) return error.NoSpace;

        // 真跳过了扇区剩余（而不是正好对齐）才写 0x00 标记：否则会踩到上一条记录已编程的字节
        if (at_pos != self.append_at[p] and at_pos % ssize == 0 and at_pos > start and self.append_at[p] % ssize != 0) {
            const pad = [1]u8{0};
            try self.dev.write(at_pos - 1, &pad);
        }

        try self.dev.write(at_pos, rec);
        // 原本空分区：第一条记录所在扇区成为 tail（存活区起点）
        if (self.tail_at[p] == end) self.tail_at[p] = at_pos - (at_pos % ssize);
        self.append_at[p] = at_pos + @as(u32, @intCast(rec.len));
    }

    /// 从 origin 找一段 rec_len 字节、不跨扇区、不超分区尾的位置（不检查 tail）。
    fn findSlot(self: *const Self, p: u8, origin: u32, rec_len: usize) ?u32 {
        const ssize = self.dev.sector_size;
        const end = self.partitionEnd(p);
        var pos = origin;
        const in_sector = pos % ssize;
        if (in_sector + rec_len > ssize) pos += ssize - in_sector;
        if (pos + rec_len > end) return null;
        return pos;
    }

    /// 环序上 `from` 之后（到追加点为止）是否还有同 key 记录。
    fn hasNewer(self: *Self, p: u8, from: u32, key: []const u8, buf: []u8) Error!bool {
        const ssize = self.dev.sector_size;
        const start = self.partitionStart(p);
        const end = self.partitionEnd(p);
        const part = self.part_size;
        const append_pos = self.append_at[p];
        const append_dist = (append_pos + part - from) % part;
        if (append_dist == 0) return false;

        var pos = start;
        while (pos < end) : (pos += ssize) {
            try self.dev.read(pos, buf[0..ssize]);
            var off: usize = 0;
            while (off + header_len + trailer_len <= ssize) {
                const b = buf[off];
                if (b != OP_PUT and b != OP_DEL) break;
                const klen: usize = buf[off + 1];
                const vlen: usize = std.mem.readInt(u16, buf[off + 2 ..][0..2], .little);
                const total = header_len + klen + vlen + trailer_len;
                if (off + total > ssize) break;
                const want = std.mem.readInt(u32, buf[off + total - trailer_len ..][0..4], .little);
                if (want != crcOf(crc_kind, buf[off .. off + total - trailer_len])) break;

                const abs = pos + @as(u32, @intCast(off));
                const dist = (abs + part - from) % part;
                if (dist != 0 and dist < append_dist) {
                    const k = buf[off + header_len ..][0..klen];
                    if (std.mem.eql(u8, k, key)) return true;
                }
                off += total;
            }
        }
        return false;
    }

    /// 压缩一个分区：按**环序**从最旧扇区开始，把仍有存活价值的记录搬到追加点，再擦掉旧扇区。
    /// `scratch` 需要 **2 个扇区**（一个读旧扇区、一个做环序查重）。
    /// 搬家途中断电安全（搬的是副本，旧扇区未擦前原数据仍在）；返回搬移条数。
    pub fn compact(self: *Self, p: u8, scratch: []u8) Error!usize {
        const ssize = self.dev.sector_size;
        if (scratch.len < 2 * ssize) return error.BufferTooSmall;
        const sector_buf = scratch[0..ssize];
        const probe_buf = scratch[ssize..][0..ssize];

        const start = self.partitionStart(p);
        const end = self.partitionEnd(p);
        const total_sectors = self.part_size / ssize;

        var moved: usize = 0;
        var pos = self.tail_at[p];
        if (pos == end) return 0; // 空分区
        var n: u32 = 0;
        while (n < total_sectors) : (n += 1) {
            const head_sector = self.append_at[p] - (self.append_at[p] % ssize);
            if (pos == head_sector) break; // 不碰正在写入的扇区

            try self.dev.read(pos, sector_buf);
            if (sector_buf[0] == BLANK) {
                // 已空白：只推进 tail
            } else {
                var off: usize = 0;
                while (off + header_len + trailer_len <= ssize) {
                    const b = sector_buf[off];
                    if (b != OP_PUT and b != OP_DEL) break;
                    const klen: usize = sector_buf[off + 1];
                    const vlen: usize = std.mem.readInt(u16, sector_buf[off + 2 ..][0..2], .little);
                    const total = header_len + klen + vlen + trailer_len;
                    if (off + total > ssize) break;
                    const want = std.mem.readInt(u32, sector_buf[off + total - trailer_len ..][0..4], .little);
                    if (want != crcOf(crc_kind, sector_buf[off .. off + total - trailer_len])) break;

                    const key = sector_buf[off + header_len ..][0..klen];
                    const next_pos = pos + @as(u32, @intCast(off + total));
                    if (!try self.hasNewer(p, next_pos, key, probe_buf)) {
                        try self.rawAppend(p, sector_buf[off .. off + total]);
                        moved += 1;
                    }
                    off += total;
                }
                try self.dev.erase(pos, ssize);
            }

            pos += ssize;
            if (pos >= end) pos = start;
        }

        // 重算 tail：第一个非空扇区起点
        self.tail_at[p] = try self.findTail(p, scratch[0..ssize]);
        return moved;
    }

    fn findTail(self: *Self, p: u8, buf: []u8) Error!u32 {
        const ssize = self.dev.sector_size;
        const start = self.partitionStart(p);
        const end = self.partitionEnd(p);
        var pos = start;
        while (pos < end) : (pos += ssize) {
            try self.dev.read(pos, buf[0..ssize]);
            if (buf[0] != BLANK) return pos;
        }
        return end;
    }

    /// 压缩所有分区（数据快满时调一次）。
    pub fn compactAll(self: *Self, scratch: []u8) Error!usize {
        var moved: usize = 0;
        var p: u8 = 0;
        while (p < self.cfg.partitions) : (p += 1) {
            moved += try self.compact(p, scratch);
        }
        return moved;
    }

    /// 全擦（出厂/清库）。之后 Store 可继续使用。
    pub fn eraseAll(self: *Self) Error!void {
        try self.dev.erase(0, self.dev.capacity);
        var p: u8 = 0;
        while (p < self.cfg.partitions) : (p += 1) {
            self.append_at[p] = self.partitionStart(p);
            self.tail_at[p] = self.partitionEnd(p);
        }
    }

    /// 已用字节（所有分区累加），供上层做「快满了」判断。
    pub fn usedBytes(self: *const Self) u32 {
        var sum: u32 = 0;
        var p: u8 = 0;
        while (p < self.cfg.partitions) : (p += 1) {
            sum += self.append_at[p] - self.partitionStart(p);
        }
        return sum;
    }
    };
}

/// 默认实例：最多 8 个分区 + 全表 CRC（桌面/大 RAM 设备）。
pub const Store = StoreType(8, .table);

/// 极小实例：2 个分区 + 无表 CRC（8 位/16 位 MCU 档）。
pub const TinyStore = StoreType(2, .bitwise);

// ------------------------- 测试用 RAM 块设备 -------------------------

/// 把一段内存当 NOR Flash 用（擦成 0xFF、只允许 1→0 写入），行为与真实 Flash 一致。
pub const RamDevice = struct {
    buf: []u8,

    pub fn init(buf: []u8) RamDevice {
        @memset(buf, BLANK);
        return .{ .buf = buf };
    }

    pub fn device(self: *RamDevice, sector_size: u32) BlockDevice {
        return .{
            .ctx = @ptrCast(self),
            .vtable = &vtable,
            .capacity = @intCast(self.buf.len),
            .sector_size = sector_size,
        };
    }

    const vtable = BlockDevice.VTable{
        .read = readImpl,
        .write = writeImpl,
        .erase = eraseImpl,
        .sync = syncImpl,
    };

    fn readImpl(ctx: *anyopaque, offset: u32, out: []u8) Error!void {
        const self: *RamDevice = @ptrCast(@alignCast(ctx));
        if (offset + out.len > self.buf.len) return error.DeviceFailure;
        @memcpy(out, self.buf[offset..][0..out.len]);
    }

    fn writeImpl(ctx: *anyopaque, offset: u32, bytes: []const u8) Error!void {
        const self: *RamDevice = @ptrCast(@alignCast(ctx));
        if (offset + bytes.len > self.buf.len) return error.DeviceFailure;
        for (bytes, 0..) |b, i| {
            const cur = self.buf[offset + i];
            // NOR 语义：只能把 1 变 0
            if ((cur & b) != b) return error.DeviceFailure;
            self.buf[offset + i] = b;
        }
    }

    fn eraseImpl(ctx: *anyopaque, offset: u32, len: u32) Error!void {
        const self: *RamDevice = @ptrCast(@alignCast(ctx));
        if (offset + len > self.buf.len) return error.DeviceFailure;
        @memset(self.buf[offset..][0..len], BLANK);
    }

    fn syncImpl(_: *anyopaque) Error!void {}
};

// ------------------------------- 测试 -------------------------------

const testing = std.testing;

test "m0: 压缩回收空间 + 环形回卷后数据与掉电重开都正确" {
    var storage: [1024]u8 = undefined;
    var dev = RamDevice.init(&storage);
    const bd = dev.device(64); // 64B 扇区；2 分区 → 每分区 512B
    var scratch: [64]u8 = undefined;
    const cfg = Config{ .partitions = 2, .key_max = 8, .value_max = 24 };
    var st = try TinyStore.open(bd, cfg, &scratch);

    // 反复覆盖同一批 key 制造垃圾；写满后必须明确报 NoSpace（不静默丢数据）
    var keybuf: [8]u8 = undefined;
    var round: usize = 0;
    var hit_full = false;
    while (round < 500) : (round += 1) {
        const k = try std.fmt.bufPrint(&keybuf, "k{d}", .{round % 3});
        st.put(k, "0123456789", &scratch) catch |e| {
            try testing.expectEqual(Error.NoSpace, e);
            hit_full = true;
            break;
        };
    }
    try testing.expect(hit_full);

    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("0123456789", (try st.get("k0", &out, &scratch)).?);

    // 压缩：把存活记录搬到追加点、擦掉旧扇区
    var cscratch: [128]u8 = undefined; // 需要 2 个扇区
    _ = try st.compactAll(&cscratch);

    // 压缩后三个 key 都在
    try testing.expectEqualStrings("0123456789", (try st.get("k0", &out, &scratch)).?);
    try testing.expectEqualStrings("0123456789", (try st.get("k1", &out, &scratch)).?);
    try testing.expectEqualStrings("0123456789", (try st.get("k2", &out, &scratch)).?);

    // 腾出的空间可以继续写（这里会走到环形回卷）
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const k = try std.fmt.bufPrint(&keybuf, "n{d}", .{i});
        try st.put(k, "new", &scratch);
    }

    // 掉电重开：环形日志跨扇区扫描仍能读对
    var st2 = try TinyStore.open(bd, cfg, &scratch);
    try testing.expectEqualStrings("0123456789", (try st2.get("k1", &out, &scratch)).?);
    try testing.expectEqualStrings("new", (try st2.get("n3", &out, &scratch)).?);
    try testing.expectEqualStrings("new", (try st2.get("n5", &out, &scratch)).?);
}

fn testStore(storage: []u8, cfg: Config) !struct { dev: RamDevice, store: Store, scratch: [512]u8 } {
    var dev = RamDevice.init(storage);
    var scratch: [512]u8 = undefined;
    const st = try Store.open(dev.device(512), cfg, &scratch);
    return .{ .dev = dev, .store = st, .scratch = scratch };
}

test "m0: put/get/overwrite/delete/reopen" {
    var storage: [8192]u8 = undefined;
    var dev = RamDevice.init(&storage);
    const bd = dev.device(512);
    var scratch: [512]u8 = undefined;

    var st = try Store.open(bd, .{}, &scratch);
    try st.put("alpha", "one", &scratch);
    try st.put("beta", "two", &scratch);
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings("one", (try st.get("alpha", &out, &scratch)).?);

    // 覆盖
    try st.put("alpha", "one-v2", &scratch);
    try testing.expectEqualStrings("one-v2", (try st.get("alpha", &out, &scratch)).?);

    // 删除
    try st.del("beta", &scratch);
    try testing.expect((try st.get("beta", &out, &scratch)) == null);

    // 重开（模拟掉电重启）：数据仍在
    var st2 = try Store.open(bd, .{}, &scratch);
    try testing.expectEqualStrings("one-v2", (try st2.get("alpha", &out, &scratch)).?);
    try testing.expect((try st2.get("beta", &out, &scratch)) == null);
    try testing.expect((try st2.get("nope", &out, &scratch)) == null);
}

test "m0: 记录不跨扇区 + 重开后追加点正确" {
    var storage: [32768]u8 = undefined;
    var dev = RamDevice.init(&storage);
    const bd = dev.device(512);
    var scratch: [512]u8 = undefined;
    var st = try Store.open(bd, .{ .key_max = 32, .value_max = 200 }, &scratch);

    // 写若干条，制造跨扇区填充
    var i: u8 = 0;
    var keybuf: [8]u8 = undefined;
    var valbuf: [120]u8 = undefined;
    while (i < 12) : (i += 1) {
        const k = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
        @memset(&valbuf, 'v');
        try st.put(k, &valbuf, &scratch);
    }

    var out: [256]u8 = undefined;
    var j: u8 = 0;
    while (j < 12) : (j += 1) {
        const k = try std.fmt.bufPrint(&keybuf, "k{d}", .{j});
        try testing.expectEqual(@as(usize, 120), (try st.get(k, &out, &scratch)).?.len);
    }

    // 重开后还能继续写
    var st2 = try Store.open(bd, .{ .key_max = 32, .value_max = 200 }, &scratch);
    try st2.put("after-reopen", "ok", &scratch);
    try testing.expectEqualStrings("ok", (try st2.get("after-reopen", &out, &scratch)).?);
    try testing.expectEqual(@as(usize, 120), (try st2.get("k5", &out, &scratch)).?.len);
}

test "m0: 分区写满返回 NoSpace（可预测，不静默丢数据）" {
    var storage: [1024]u8 = undefined;
    var dev = RamDevice.init(&storage);
    const bd = dev.device(512);
    var scratch: [512]u8 = undefined;
    var st = try Store.open(bd, .{ .partitions = 2, .value_max = 64 }, &scratch);

    var i: usize = 0;
    var err: ?Error = null;
    var keybuf: [8]u8 = undefined;
    const val: [40]u8 = @splat('x');
    while (i < 100) : (i += 1) {
        const k = try std.fmt.bufPrint(&keybuf, "s{d}", .{i});
        st.put(k, &val, &scratch) catch |e| {
            err = e;
            break;
        };
    }
    try testing.expect(err != null);
    try testing.expectEqual(Error.NoSpace, err.?);
}

test "m0: 掉电撕裂尾（截断最后一条记录）后仍可读旧值并继续写" {
    var storage: [32768]u8 = undefined;
    var dev = RamDevice.init(&storage);
    const bd = dev.device(512);
    var scratch: [512]u8 = undefined;
    var st = try Store.open(bd, .{ .key_max = 16, .value_max = 32 }, &scratch);
    try st.put("k", "v1", &scratch);
    const used = st.usedBytes();
    try st.put("k", "v2-longer", &scratch);

    // 模拟：第二条只写了一半（CRC 区域被破坏）
    const tail_start = st.append_at[st.partitionOf("k")] - 8;
    storage[tail_start - 1] +%= 0x5A;

    var st2 = try Store.open(bd, .{ .key_max = 16, .value_max = 32 }, &scratch);
    var out: [64]u8 = undefined;
    // 撕裂的记录被丢弃，保留上一条完整记录
    try testing.expectEqualStrings("v1", (try st2.get("k", &out, &scratch)).?);
    try st2.put("k", "v3", &scratch);
    try testing.expectEqualStrings("v3", (try st2.get("k", &out, &scratch)).?);
    _ = used;
}

test "m0: 常驻 RAM 预算（Store + 1 扇区 + 1 记录缓冲）≤ 2KB" {    const cfg = Config{};
    const store_bytes = @sizeOf(Store);
    const record_bytes = header_len + cfg.key_max + cfg.value_max + trailer_len;
    const zone = store_bytes + 512 + record_bytes;
    // 实测项（不含调用方栈）——目标 8KB 设备留足余量
    try testing.expect(zone <= 2048);
    std.debug.print("m0_ram,store={d},record={d},sector=512,total={d}\n", .{ store_bytes, record_bytes, zone });
}

test "m0: 极小档（2 分区 / 32B 扇区 / 无表 CRC）在 512B 存储上可用" {
    var storage: [512]u8 = undefined;
    var dev = RamDevice.init(&storage);
    const bd = dev.device(32);
    var scratch: [32]u8 = undefined;
    const cfg = Config{ .partitions = 2, .key_max = 8, .value_max = 8 };
    var st = try TinyStore.open(bd, cfg, &scratch);

    try st.put("k1", "v1", &scratch);
    try st.put("k2", "v2", &scratch);
    var out: [16]u8 = undefined;
    try testing.expectEqualStrings("v1", (try st.get("k1", &out, &scratch)).?);

    // 重开（掉电重启）后仍可读
    var st2 = try TinyStore.open(bd, cfg, &scratch);
    try testing.expectEqualStrings("v2", (try st2.get("k2", &out, &scratch)).?);
    try st2.del("k1", &scratch);
    try testing.expect((try st2.get("k1", &out, &scratch)) == null);

    // 预算：结构体 + 扇区 + 记录缓冲（实测项，不含栈）
    const budget = @sizeOf(TinyStore) + 32 + (header_len + cfg.key_max + cfg.value_max + trailer_len);
    std.debug.print("m0_tiny_ram,store={d},budget={d}\n", .{ @sizeOf(TinyStore), budget });
    try testing.expect(budget <= 256);
}
