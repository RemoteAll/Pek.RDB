// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
//
// 移植自检（conformance self-test）：任何新平台的 BlockDevice 实现，只需实现
// read/write/erase/sync 四个函数，然后调用 `selfTest()` 就能验证语义是否满足 M0 的要求。
// **会破坏被测试区域的数据**——请只在空白/专用区域上跑，或在产线首启时跑一次。
//
// 典型用法（裸机）：
//   var scratch: [1024]u8 = undefined;
//   const r = try m0_diag.selfTest(myDev, .{ .partitions = 2 }, &scratch);
//   if (r.failed != 0) { /* 打印 r.last_error / 停用存储 */ }

const std = @import("std");
const m0 = @import("m0.zig");

pub const Report = struct {
    passed: u16 = 0,
    failed: u16 = 0,
    last_error: ?m0.Error = null,

    fn expect(self: *Report, cond: bool) void {
        if (cond) self.passed += 1 else self.failed += 1;
    }

    fn failErr(self: *Report, e: m0.Error) void {
        self.failed += 1;
        self.last_error = e;
    }

    pub fn ok(self: Report) bool {
        return self.failed == 0;
    }
};

/// 自检用的 Store 实例（4 分区 + 半字节 CRC，flash 占用最小）
const DiagStore = m0.StoreType(4, .nibble);
const max_parts: u8 = 4;
const key_max: u8 = 8;
const value_max: u16 = 16;

/// 跑一组最小但覆盖关键语义的检查：
/// 空白=0xFF、擦除、写入回读、只能 1→0（由设备自身保证）、掉电重开、
/// 覆盖写、删除、写满→压缩→继续写。
pub fn selfTest(dev: m0.BlockDevice, cfg: m0.Config, scratch: []u8) Report {
    var r = Report{};
    const ssize = dev.sector_size;

    // 0) 参数合法性
    if (ssize < 8 or dev.capacity < ssize * @as(u32, max_parts)) {
        r.failErr(error.BadPartitions);
        return r;
    }
    if (scratch.len < 2 * ssize) {
        r.failErr(error.BufferTooSmall);
        return r;
    }
    if (cfg.partitions == 0 or cfg.partitions > max_parts) {
        r.failErr(error.BadPartitions);
        return r;
    }

    // 1) 全擦后必须是 0xFF
    dev.erase(0, dev.capacity) catch |e| {
        r.failErr(e);
        return r;
    };
    {
        var all_blank = true;
        var pos: u32 = 0;
        while (pos < dev.capacity) : (pos += ssize) {
            dev.read(pos, scratch[0..ssize]) catch |e| {
                r.failErr(e);
                return r;
            };
            for (scratch[0..ssize]) |b| {
                if (b != 0xFF) {
                    all_blank = false;
                    break;
                }
            }
            if (!all_blank) break;
        }
        r.expect(all_blank);
    }

    // 2) 打开 → 写入 → 回读
    var store = DiagStore.open(dev, .{
        .partitions = cfg.partitions,
        .key_max = key_max,
        .value_max = value_max,
    }, scratch) catch |e| {
        r.failErr(e);
        return r;
    };
    store.put("t0", "hello", scratch) catch |e| {
        r.failErr(e);
        return r;
    };
    var out: [32]u8 = undefined;
    {
        const v = store.get("t0", &out, scratch) catch |e| {
            r.failErr(e);
            return r;
        };
        r.expect(v != null and std.mem.eql(u8, v.?, "hello"));
    }

    // 3) 覆盖写
    store.put("t0", "hello2", scratch) catch |e| {
        r.failErr(e);
        return r;
    };
    {
        const v = store.get("t0", &out, scratch) catch |e| {
            r.failErr(e);
            return r;
        };
        r.expect(v != null and std.mem.eql(u8, v.?, "hello2"));
    }

    // 4) 删除（墓碑）
    store.del("t0", scratch) catch |e| {
        r.failErr(e);
        return r;
    };
    {
        const v = store.get("t0", &out, scratch) catch |e| {
            r.failErr(e);
            return r;
        };
        r.expect(v == null);
    }

    // 5) 掉电语义：重新 open 后墓碑仍然生效、另一条数据仍在
    store.put("keep", "v", scratch) catch |e| {
        r.failErr(e);
        return r;
    };
    var store2 = DiagStore.open(dev, .{
        .partitions = cfg.partitions,
        .key_max = key_max,
        .value_max = value_max,
    }, scratch) catch |e| {
        r.failErr(e);
        return r;
    };
    {
        const gone = store2.get("t0", &out, scratch) catch |e| {
            r.failErr(e);
            return r;
        };
        const kept = store2.get("keep", &out, scratch) catch |e| {
            r.failErr(e);
            return r;
        };
        r.expect(gone == null);
        r.expect(kept != null and std.mem.eql(u8, kept.?, "v"));
    }

    // 6) 写满 → 压缩 → 继续写（验证环形日志/擦除都正常）
    var filled: u32 = 0;
    var i: usize = 0;
    var kb: [8]u8 = undefined;
    while (i < 200) : (i += 1) {
        const k = std.fmt.bufPrint(&kb, "f{d}", .{i % 4}) catch break;
        store2.put(k, "0123456789abcdef", scratch) catch |e| {
            if (e == error.NoSpace) break;
            r.failErr(e);
            return r;
        };
        filled += 1;
    }
    r.expect(filled > 0);
    _ = store2.compactAll(scratch) catch |e| {
        r.failErr(e);
        return r;
    };
    var ok_after = true;
    store2.put("after", "ok", scratch) catch {
        ok_after = false;
    };
    if (ok_after) {
        const v = store2.get("after", &out, scratch) catch |e| {
            r.failErr(e);
            return r;
        };
        ok_after = v != null and std.mem.eql(u8, v.?, "ok");
    }
    r.expect(ok_after);

    return r;
}

