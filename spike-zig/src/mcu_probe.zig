// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
//
// MCU 探针：只用 M0 档（无 OS / 无堆 / 无 mmap），给 riscv32-freestanding 编译出真实 ELF，
// 供 tools/elf-size.py 量 flash / 静态 RAM。不是产品代码，只用于尺寸与链接验证。
const std = @import("std");
const m0 = @import("pek_rdb_spike").m0;

/// 极小档：32B “扇区”（模拟页访问器）、2 分区、key/value 各 8B、无表 CRC
const sector: u32 = 32;
var flash: [512]u8 = undefined;
var scratch: [32]u8 = undefined;
var out: [8]u8 = undefined;

export fn _start() callconv(.c) noreturn {
    var dev = m0.RamDevice.init(&flash);
    const bd = dev.device(sector);

    var store = m0.TinyStore.open(
        bd,
        .{ .partitions = 2, .key_max = 8, .value_max = 8 },
        &scratch,
    ) catch spin();

    store.put("boot", "ok", &scratch) catch spin();
    const got = store.get("boot", &out, &scratch) catch spin();
    if (got == null) spin();
    spin();
}

fn spin() noreturn {
    while (true) {
        std.atomic.spinLoopHint();
    }
}
