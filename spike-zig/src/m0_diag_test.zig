// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
//
// 自检模块的回归测试：用「诚实设备」与「撒谎设备」各跑一遍，
// 证明 selfTest 既能通过合规实现，也能抓出不合规实现（不会永远绿）。

const std = @import("std");
const m0 = @import("m0.zig");
const diag = @import("m0_diag.zig");

const testing = std.testing;

test "diag: 合规设备（RamDevice）通过自检" {
    var storage: [16384]u8 = undefined;
    var dev = m0.RamDevice.init(&storage);
    var scratch: [1024]u8 = undefined;
    const bd = dev.device(64);

    const r = diag.selfTest(bd, .{ .partitions = 2 }, &scratch);
    testing.expect(r.ok()) catch |e| {
        std.debug.print("diag_fail failed={d} last_error={?}\n", .{ r.failed, r.last_error });
        return e;
    };
    try testing.expect(r.passed >= 8);
}

/// 撒谎设备：空白读返回 0x00（真实 Flash 应为 0xFF）——自检必须发现。
const LiarDevice = struct {
    buf: []u8,

    fn readImpl(ctx: *anyopaque, offset: u32, out: []u8) Error!void {
        const self: *LiarDevice = @ptrCast(@alignCast(ctx));
        if (offset + out.len > self.buf.len) return error.DeviceFailure;
        @memset(out, 0x00); // 永远给 0，绝不返回 0xFF
    }
    fn writeImpl(ctx: *anyopaque, offset: u32, bytes: []const u8) Error!void {
        const self: *LiarDevice = @ptrCast(@alignCast(ctx));
        if (offset + bytes.len > self.buf.len) return error.DeviceFailure;
        @memcpy(self.buf[offset..][0..bytes.len], bytes);
    }
    fn eraseImpl(ctx: *anyopaque, offset: u32, len: u32) Error!void {
        const self: *LiarDevice = @ptrCast(@alignCast(ctx));
        if (offset + len > self.buf.len) return error.DeviceFailure;
        @memset(self.buf[offset..][0..len], 0x00);
    }
    fn syncImpl(_: *anyopaque) Error!void {}

    const Error = m0.Error;
    const vtable = m0.BlockDevice.VTable{
        .read = readImpl,
        .write = writeImpl,
        .erase = eraseImpl,
        .sync = syncImpl,
    };
};

test "diag: 撒谎设备（空白读 0x00）必须被判不合规" {
    var storage: [16384]u8 = undefined;
    var liar = LiarDevice{ .buf = &storage };
    const bd = m0.BlockDevice{
        .ctx = @ptrCast(&liar),
        .vtable = &LiarDevice.vtable,
        .capacity = @intCast(storage.len),
        .sector_size = 64,
    };
    var scratch: [1024]u8 = undefined;
    const r = diag.selfTest(bd, .{ .partitions = 2 }, &scratch);
    try testing.expect(!r.ok());
}
