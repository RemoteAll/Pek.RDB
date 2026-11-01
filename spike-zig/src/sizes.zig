// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
//
// 结构体尺寸报告：`zig build sizes` 输出 `metric,item,bytes`，供嵌入式 RAM 预算核算。
// 注意：这里报的是**类型布局实测值**（@sizeOf，编译期真实计算），不是估算。
const std = @import("std");
const builtin = @import("builtin");
const spike = @import("pek_rdb_spike");

fn row(name: []const u8, bytes: usize) void {
    std.debug.print("sizeof,{s},{d}\n", .{ name, bytes });
}

// **编译期守门**：只做 `@sizeOf` 不会分析函数体，于是「某个入口在目标平台上
// 引入了不可用依赖」这类问题会被完整漏掉（真实踩过：`Table.checkThread` 调
// `std.Thread.getCurrentId()`，而它在 freestanding 上是 `@compileError`）。
// 取地址会强迫语义分析。
//
// **只对「有 OS」的目标设这道门**：主引擎目前在 freestanding 上还编不了
// （`std.heap.page_size_min` 未定义，与 `/sizes` 无关、也不是本轮引入），
// 那是 §16.5 M8 的工作。硬约束 §16.5 目前只对 `m0` 成立 —— 已写入决策记录。
comptime {
    if (builtin.os.tag != .freestanding and builtin.os.tag != .uefi and builtin.os.tag != .other) {
        _ = &spike.table.Table.open;
        _ = &spike.table.Table.put;
        _ = &spike.table.Table.putBatch;
        _ = &spike.table.Table.delete;
        _ = &spike.table.Table.get;
        _ = &spike.table.Table.flush;
        _ = &spike.table.Table.checkpoint;
        _ = &spike.table.Table.close;
        _ = &spike.table.Table.compact;
    }
}

pub fn main() void {
    std.debug.print("metric,item,bytes\n", .{});

    // 存储内核
    row("skiplist.Skiplist", @sizeOf(spike.skiplist.Skiplist));
    row("skiplist.Node", @sizeOf(spike.skiplist.Node));
    row("skiplist.Entry", @sizeOf(spike.skiplist.Entry));
    row("wal.Wal", @sizeOf(spike.wal.Wal));
    row("wal.Op", @sizeOf(spike.wal.Op));
    row("wal.Batch", @sizeOf(spike.wal.Batch));
    row("segment.Segment", @sizeOf(spike.segment.Segment));
    row("segment.Entry", @sizeOf(spike.segment.Entry));
    row("segment.IndexEntry", @sizeOf(spike.segment.IndexEntry));
    row("segment.RefRecord", @sizeOf(spike.segment.Segment.RefRecord));
    row("segment.RecordOwned", @sizeOf(spike.segment.RecordOwned));
    row("segment.RefCursor", @sizeOf(spike.segment.RefCursor));
    row("table.Table", @sizeOf(spike.table.Table));
    row("table.Options", @sizeOf(spike.table.Options));
    row("table.RecordSet", @sizeOf(spike.table.RecordSet));

    // SQL 层
    row("schema.Schema", @sizeOf(spike.schema.Schema));
    row("schema.Column", @sizeOf(spike.schema.Column));
    row("sql.Value", @sizeOf(spike.sql.Value));
    row("exec.Rows", @sizeOf(spike.exec.Rows));

    // 常量区
    row("codec.CRC_TABLE_BYTES", spike.codec.CRC_TABLE_BYTES);
    row("codec.CRC_FAST_TABLE_BYTES", spike.codec.CRC_FAST_TABLE_BYTES);
    row("codec.Reader", @sizeOf(spike.codec.Reader));

    // M0 极小资源档（8KB RAM 目标）
    row("m0.Store", @sizeOf(spike.m0.Store));
    row("m0.TinyStore", @sizeOf(spike.m0.TinyStore));
    row("m0.BlockDevice", @sizeOf(spike.m0.BlockDevice));
    row("m0.Config", @sizeOf(spike.m0.Config));
    row("codec.CRC_NIBBLE_TABLE_BYTES", spike.codec.CRC_NIBBLE_TABLE_BYTES);

    // 关键预算项（按 8KB 目标核算用）：每 key 的常驻 RAM = Node + key + value 拷贝
    const sk = spike.skiplist.Skiplist;
    _ = sk;
}
