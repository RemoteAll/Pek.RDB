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
    /// 分区数（必须是 2 的幂，且 ≤ max_partitions）。越多分区 → 单次 get 读得越少、可用空间越碎。
    partitions: u8 = 8,
    key_max: u8 = 32,
    value_max: u16 = 64,
};

/// 记录：`[op u8][klen u8][vlen u16][key][value][crc32 u32]`
const OP_PUT: u8 = 0x01;
const OP_DEL: u8 = 0x02;
const BLANK: u8 = 0xFF;
const header_len: usize = 4;
const trailer_len: usize = 4;

pub const Store = struct {
    pub const max_partitions: usize = 16;

    dev: BlockDevice,
    cfg: Config,
    /// 每个分区占用的字节数（cap / partitions，向下对齐到扇区）
    part_size: u32,
    /// 每个分区的下一个追加位置（绝对偏移）
    append_at: [max_partitions]u32,

    /// 打开：扫描各分区定位追加点。`scratch` 至少一个扇区，打开后可复用。
    pub fn open(dev: BlockDevice, cfg: Config, scratch: []u8) Error!Store {
        if (cfg.partitions == 0 or cfg.partitions > max_partitions) return error.BadPartitions;
        if (cfg.partitions & (cfg.partitions - 1) != 0) return error.BadPartitions;
        if (dev.sector_size == 0 or dev.capacity < dev.sector_size) return error.BadPartitions;
        if (scratch.len < dev.sector_size) return error.BufferTooSmall;

        var self = Store{
            .dev = dev,
            .cfg = cfg,
            .part_size = (dev.capacity / cfg.partitions) & ~(dev.sector_size - 1),
            .append_at = @splat(0),
        };
        if (self.part_size < dev.sector_size) return error.BadPartitions;

        var p: u8 = 0;
        while (p < cfg.partitions) : (p += 1) {
            self.append_at[p] = try self.scanPartition(p, scratch);
        }
        return self;
    }

    /// 分区起点
    pub fn partitionStart(self: *const Store, p: u8) u32 {
        return @as(u32, p) * self.part_size;
    }

    pub fn partitionEnd(self: *const Store, p: u8) u32 {
        return @as(u32, p + 1) * self.part_size;
    }

    fn partitionOf(self: *const Store, key: []const u8) u8 {
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
    fn scanPartition(self: *Store, p: u8, scratch: []u8) Error!u32 {
        const start = self.partitionStart(p);
        const end = self.partitionEnd(p);
        const ssize = self.dev.sector_size;

        var last_end: u32 = start;
        var pos = start;
        while (pos < end) : (pos += ssize) {
            try self.dev.read(pos, scratch[0..ssize]);
            if (scratch[0] == BLANK) break;

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
                if (want != codec.crc32(scratch[off .. off + total - trailer_len])) {
                    clean = false;
                    break;
                }
                off += total;
            }
            if (!clean) {
                // 撕裂或填充：本扇区剩余不可再写，跳到下一扇区
                last_end = pos + ssize;
                break;
            }
            last_end = pos + @as(u32, @intCast(off));
        }
        return last_end;
    }

    /// 取 key：只读它所属的分区，值拷进 `out`。
    /// 返回 `null` = 不存在（或被删除）。
    pub fn get(self: *Store, key: []const u8, out: []u8, scratch: []u8) Error!?[]const u8 {
        if (key.len > self.cfg.key_max) return error.KeyTooLong;
        if (scratch.len < self.dev.sector_size) return error.BufferTooSmall;

        const p = self.partitionOf(key);
        const start = self.partitionStart(p);
        const end = self.partitionEnd(p);
        const ssize = self.dev.sector_size;

        var found: ?usize = null;
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
                if (want != codec.crc32(scratch[off .. off + total - trailer_len])) break;

                const k = scratch[off + header_len ..][0..klen];
                if (std.mem.eql(u8, k, key)) {
                    if (b == OP_DEL) {
                        found = null;
                    } else {
                        if (vlen > out.len) return error.BufferTooSmall;
                        @memcpy(out[0..vlen], scratch[off + header_len + klen ..][0..vlen]);
                        found = vlen;
                    }
                }
                off += total;
            }
        }
        if (found) |n| return out[0..n];
        return null;
    }

    /// 写 key（覆盖语义：同 key 后写为准）。
    pub fn put(self: *Store, key: []const u8, value: []const u8, scratch: []u8) Error!void {
        return self.append(OP_PUT, key, value, scratch);
    }

    /// 删 key（写墓碑，语义上覆盖之前的 put）。
    pub fn del(self: *Store, key: []const u8, scratch: []u8) Error!void {
        return self.append(OP_DEL, key, &.{}, scratch);
    }

    fn append(self: *Store, op: u8, key: []const u8, value: []const u8, scratch: []u8) Error!void {
        if (key.len == 0 or key.len > self.cfg.key_max) return error.KeyTooLong;
        if (value.len > self.cfg.value_max) return error.ValueTooLong;
        const total = header_len + key.len + value.len + trailer_len;
        if (scratch.len < self.dev.sector_size or scratch.len < total) return error.BufferTooSmall;

        const p = self.partitionOf(key);
        const end = self.partitionEnd(p);
        const ssize = self.dev.sector_size;
        var pos = self.append_at[p];

        // 记录不跨扇区：剩余空间不够就把该扇区剩余部分写成 0x00（扫描视为填充）
        const in_sector = pos % ssize;
        if (in_sector + total > ssize) {
            pos += ssize - in_sector;
        }
        if (pos + total > end) return error.NoSpace;

        // 组记录
        scratch[0] = op;
        scratch[1] = @intCast(key.len);
        std.mem.writeInt(u16, scratch[2..4], @intCast(value.len), .little);
        @memcpy(scratch[header_len..][0..key.len], key);
        @memcpy(scratch[header_len + key.len ..][0..value.len], value);
        const body = total - trailer_len;
        std.mem.writeInt(u32, scratch[body..][0..4], codec.crc32(scratch[0..body]), .little);

        // 扇区填充标记：把新扇区的第一个字节之外的内容保持 0xFF，扫描遇到非记录字节就跳下一扇区。
        // 跨扇区时，先把旧扇区剩余的首字节写 0x00，避免扫描把它当成「全空白」。
        if (in_sector + total > ssize) {
            const pad = [1]u8{0};
            try self.dev.write(pos - 1, &pad); // 只写 1 字节（设备允许字节内写入）
        }

        try self.dev.write(pos, scratch[0..total]);
        self.append_at[p] = pos + @as(u32, @intCast(total));
    }

    /// 全擦（出厂/清库）。之后 Store 可继续使用。
    pub fn eraseAll(self: *Store) Error!void {
        try self.dev.erase(0, self.dev.capacity);
        var p: u8 = 0;
        while (p < self.cfg.partitions) : (p += 1) {
            self.append_at[p] = self.partitionStart(p);
        }
    }

    /// 已用字节（所有分区累加），供上层做「快满了」判断。
    pub fn usedBytes(self: *const Store) u32 {
        var sum: u32 = 0;
        var p: u8 = 0;
        while (p < self.cfg.partitions) : (p += 1) {
            sum += self.append_at[p] - self.partitionStart(p);
        }
        return sum;
    }
};

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

test "m0: 常驻 RAM 预算（Store + 1 扇区 + 1 记录缓冲）≤ 2KB" {
    const cfg = Config{};
    const store_bytes = @sizeOf(Store);
    const record_bytes = header_len + cfg.key_max + cfg.value_max + trailer_len;
    const zone = store_bytes + 512 + record_bytes;
    // 实测项（不含调用方栈）——目标 8KB 设备留足余量
    try testing.expect(zone <= 2048);
    std.debug.print("m0_ram,store={d},record={d},sector=512,total={d}\n", .{ store_bytes, record_bytes, zone });
}
