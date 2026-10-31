// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
//
// SPI NOR Flash 适配层：把「SPI 总线 + CS + 延时」三个原语，接成 m0.BlockDevice。
// 设计目标：不绑定任何 MCU/RTOS；只依赖 `SpiBus` 的三个函数指针。
// 处理了真实芯片的两个硬约束：
//   1. 页编程不能跨页（256B/页），适配层按页自动切分；
//   2. 只能 1→0，改写前必须按扇区（4KB）擦除。
// 另带一个 `SimNor`（模拟芯片，强制上述约束）用于主机侧回归——真机行为靠它兜底。

const std = @import("std");
const m0 = @import("m0.zig");

pub const Error = m0.Error;

/// 最小 SPI 原语：全双工传输 + 片选 + 毫秒延时。
pub const SpiBus = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 全双工：发送 tx，同时把收到的字节写入 rx（rx 长度可与 tx 不同）
        transceive: *const fn (ctx: *anyopaque, tx: []const u8, rx: []u8) Error!void,
        cs: *const fn (ctx: *anyopaque, level: bool) Error!void,
        delay_ms: *const fn (ctx: *anyopaque, ms: u32) Error!void,
    };

    fn tx(self: SpiBus, bytes: []const u8, rx: []u8) Error!void {
        return self.vtable.transceive(self.ctx, bytes, rx);
    }
    fn chipSelect(self: SpiBus, level: bool) Error!void {
        return self.vtable.cs(self.ctx, level);
    }
    fn delay(self: SpiBus, ms: u32) Error!void {
        return self.vtable.delay_ms(self.ctx, ms);
    }
};

const CMD_WREN: u8 = 0x06;
const CMD_RDSR: u8 = 0x05;
const CMD_READ: u8 = 0x03;
const CMD_PP: u8 = 0x02;
const CMD_SE: u8 = 0x20; // 4KB sector erase

/// SPI NOR 适配器：`capacity` 决定 BlockDevice 的容量，`sector_size` 必须等于芯片擦除粒度。
pub const SpiNor = struct {
    bus: SpiBus,
    capacity: u32,
    page_size: u16 = 256,
    sector_size: u32 = 4096,
    /// 擦除/编程后的最大等待（毫秒），超时视为失败
    timeout_ms: u16 = 1000,

    pub fn blockDevice(self: *SpiNor) m0.BlockDevice {
        return .{
            .ctx = @ptrCast(self),
            .vtable = &vtable,
            .capacity = self.capacity,
            .sector_size = self.sector_size,
        };
    }

    const vtable = m0.BlockDevice.VTable{
        .read = readImpl,
        .write = writeImpl,
        .erase = eraseImpl,
        .sync = syncImpl,
    };

    fn sendCmd(self: *SpiNor, code: u8, addr: u32, payload: []const u8, rx: []u8) Error!void {
        var hdr = [4]u8{ code, @truncate(addr >> 16), @truncate(addr >> 8), @truncate(addr) };
        var empty: [0]u8 = .{};
        try self.bus.chipSelect(true);
        defer self.bus.chipSelect(false) catch {};
        try self.bus.tx(&hdr, &empty);
        if (payload.len > 0) try self.bus.tx(payload, &empty);
        if (rx.len > 0) try self.bus.tx(rx, rx);
    }

    fn writeEnable(self: *SpiNor) Error!void {
        var buf = [1]u8{CMD_WREN};
        var empty: [0]u8 = .{};
        try self.bus.chipSelect(true);
        defer self.bus.chipSelect(false) catch {};
        try self.bus.tx(&buf, &empty);
    }

    /// 轮询状态寄存器 BUSY 位（bit0）。
    fn waitReady(self: *SpiNor) Error!void {
        var waited: u32 = 0;
        while (waited <= self.timeout_ms) : (waited += 1) {
            var sr = [1]u8{0};
            var cmd = [1]u8{CMD_RDSR};
            try self.bus.chipSelect(true);
            try self.bus.tx(&cmd, &sr);
            try self.bus.chipSelect(false);
            if (sr[0] & 0x01 == 0) return;
            try self.bus.delay(1);
        }
        return error.DeviceFailure;
    }

    fn readImpl(ctx: *anyopaque, offset: u32, buf: []u8) Error!void {
        const self: *SpiNor = @ptrCast(@alignCast(ctx));
        if (offset + buf.len > self.capacity) return error.DeviceFailure;
        if (buf.len == 0) return;
        var empty: [0]u8 = .{};
        var hdr = [4]u8{ CMD_READ, @truncate(offset >> 16), @truncate(offset >> 8), @truncate(offset) };
        try self.bus.chipSelect(true);
        defer self.bus.chipSelect(false) catch {};
        try self.bus.tx(&hdr, &empty);
        try self.bus.tx(buf, buf); // 全双工：发 dummy，收数据
    }

    fn writeImpl(ctx: *anyopaque, offset: u32, bytes: []const u8) Error!void {
        const self: *SpiNor = @ptrCast(@alignCast(ctx));
        if (offset + bytes.len > self.capacity) return error.DeviceFailure;

        var off = offset;
        var rest = bytes;
        while (rest.len > 0) {
            // 页编程不能跨页：按页边界切分
            const room = self.page_size - (off % self.page_size);
            const n = @min(rest.len, room);
            try self.writeEnable();
            try self.sendCmd(CMD_PP, off, rest[0..n], &.{});
            try self.waitReady();
            off += @intCast(n);
            rest = rest[n..];
        }
    }

    fn eraseImpl(ctx: *anyopaque, offset: u32, len: u32) Error!void {
        const self: *SpiNor = @ptrCast(@alignCast(ctx));
        if (offset % self.sector_size != 0 or len % self.sector_size != 0) return error.DeviceFailure;
        var off = offset;
        while (off < offset + len) : (off += self.sector_size) {
            try self.writeEnable();
            try self.sendCmd(CMD_SE, off, &.{}, &.{});
            try self.waitReady();
        }
    }

    fn syncImpl(_: *anyopaque) Error!void {}
};

// --------------------------- 模拟 NOR 芯片（测试用） ---------------------------

/// 用内存模拟一颗 SPI NOR：强制「页编程不跨页」「只能 1→0」「改写前必须擦除」，
/// 并把违规次数记到 `violations`，用来证明适配层没有踩坑。
pub const SimNor = struct {
    buf: []u8,
    page_size: u32 = 256,
    sector_size: u32 = 4096,
    wel: bool = false,

    // 统计（断言用）
    pp_count: u32 = 0,
    se_count: u32 = 0,
    violations: u32 = 0,

    phase: Phase = .idle,
    pos: u32 = 0,
    /// 本次页编程所属页号（用于检测跨页）
    pp_page: u32 = 0,

    const Phase = enum { idle, read, program };

    pub fn init(buf: []u8) SimNor {
        @memset(buf, 0xFF);
        return .{ .buf = buf };
    }

    pub fn bus(self: *SimNor) SpiBus {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = SpiBus.VTable{
        .transceive = transceiveImpl,
        .cs = csImpl,
        .delay_ms = delayImpl,
    };

    fn csImpl(ctx: *anyopaque, level: bool) Error!void {
        const self: *SimNor = @ptrCast(@alignCast(ctx));
        if (level) self.phase = .idle;
    }

    fn delayImpl(_: *anyopaque, _: u32) Error!void {}

    fn transceiveImpl(ctx: *anyopaque, tx: []const u8, rx: []u8) Error!void {
        const self: *SimNor = @ptrCast(@alignCast(ctx));
        if (self.phase == .idle) {
            if (tx.len < 1) return;
            const code = tx[0];
            switch (code) {
                CMD_WREN => {
                    self.wel = true;
                    return;
                },
                CMD_RDSR => {
                    if (rx.len > 0) rx[0] = 0; // 不模拟忙碌
                    return;
                },
                CMD_READ, CMD_PP, CMD_SE => {
                    if (tx.len < 4) {
                        self.violations += 1;
                        return;
                    }
                    self.pos = (@as(u32, tx[1]) << 16) | (@as(u32, tx[2]) << 8) | tx[3];
                    if (code == CMD_SE) {
                        if (!self.wel) self.violations += 1;
                        self.wel = false;
                        const s = self.pos - (self.pos % self.sector_size);
                        if (s + self.sector_size > self.buf.len) return error.DeviceFailure;
                        @memset(self.buf[s..][0..self.sector_size], 0xFF);
                        self.se_count += 1;
                        return;
                    }
                    self.phase = if (code == CMD_READ) .read else .program;
                    if (code == CMD_PP) self.pp_page = self.pos / self.page_size;
                    // 头部之后的字节属于数据阶段（rx 与 tx 一一对应）
                    if (tx.len > 4) try self.data(tx[4..], rx, 4);
                    return;
                },
                else => {
                    self.violations += 1;
                    return;
                },
            }
        }
        try self.data(tx, rx, 0);
    }

    /// 数据阶段：tx 与 rx 一一对应；读把 flash 写到 rx，编程把 tx 写到 flash。
    fn data(self: *SimNor, tx: []const u8, rx: []u8, rx_off: usize) Error!void {
        switch (self.phase) {
            .idle => {},
            .read => {
                for (tx, 0..) |_, i| {
                    if (self.pos >= self.buf.len) return error.DeviceFailure;
                    if (rx_off + i < rx.len) rx[rx_off + i] = self.buf[self.pos];
                    self.pos += 1;
                }
            },
            .program => {
                if (!self.wel) self.violations += 1;
                for (tx) |b| {
                    if (self.pos >= self.buf.len) return error.DeviceFailure;
                    // 一条页编程命令不得跨页
                    if (self.pos / self.page_size != self.pp_page) self.violations += 1;
                    const cur = self.buf[self.pos];
                    if (cur != 0xFF and b != 0xFF) self.violations += 1; // 未擦除就写
                    self.buf[self.pos] = cur & b;
                    self.pos += 1;
                }
                self.pp_count += 1;
                self.wel = false;
            },
        }
    }
};

// --------------------------------- 测试 ---------------------------------

const testing = std.testing;

test "spi: 适配层按页切分、不跨页、不覆盖未擦除区域" {
    var flash: [16384]u8 = undefined;
    var sim = SimNor.init(&flash);
    var nor = SpiNor{ .bus = sim.bus(), .capacity = @intCast(flash.len) };
    const bd = nor.blockDevice();

    var scratch: [4096]u8 = undefined;
    var st = try m0.StoreType(2, .nibble).open(bd, .{ .partitions = 2, .key_max = 8, .value_max = 600 }, &scratch);

    // 650B 的值必然跨 256B 页边界（记录头 4 + key 2 + 600 + 尾 4 = 610）
    var big: [600]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast('a' + (i % 26));
    try st.put("k1", &big, &scratch);

    var out: [700]u8 = undefined;
    const got = (try st.get("k1", &out, &scratch)).?;
    try testing.expectEqual(@as(usize, 600), got.len);
    try testing.expectEqualSlices(u8, &big, got);

    try testing.expectEqual(@as(u32, 0), sim.violations);
    try testing.expect(sim.pp_count >= 3); // 610B / 256B → 至少 3 次页编程
}

test "spi: 擦除粒度正确 + 掉电重开可读" {
    var flash: [16384]u8 = undefined;
    var sim = SimNor.init(&flash);
    var nor = SpiNor{ .bus = sim.bus(), .capacity = @intCast(flash.len) };
    const bd = nor.blockDevice();

    var scratch: [4096]u8 = undefined;
    const Cfg = m0.Config{ .partitions = 2, .key_max = 8, .value_max = 32 };
    var st = try m0.StoreType(2, .nibble).open(bd, Cfg, &scratch);
    try st.put("a", "1", &scratch);
    try st.put("b", "2", &scratch);

    // 重开：扫到同样的数据
    var st2 = try m0.StoreType(2, .nibble).open(bd, Cfg, &scratch);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("1", (try st2.get("a", &out, &scratch)).?);

    // 全擦后是空库，且擦除按扇区发起
    try st2.eraseAll();
    try testing.expect((try st2.get("a", &out, &scratch)) == null);
    try testing.expect(sim.se_count >= 1);
    try testing.expectEqual(@as(u32, 0), sim.violations);
}
