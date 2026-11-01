// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。

//! 退出信号接入 —— **宿主应用的参考实现**（引擎本身不自动接管）。
//!
//! ## 为什么引擎不自己装信号处理
//!
//! 库无法判断「这个进程此刻该不该退出」：同一进程里可能还有别的库、别的表、
//! 还没提交完的事务、还要写日志。SQLite（`sqlite3_close`）、LMDB（`mdb_env_close`）、
//! RocksDB（`DB::Close`）都是同一个分工 —— **信号由宿主接，收尾由引擎提供入口**。
//!
//! 引擎侧的入口（见 `table.zig`）：
//! - `Table.sync()`：WAL 缓冲落盘 + `fsync`（不落段，最快）；
//! - `Table.checkpoint()`：memtable 落段 + 清 WAL + 全部 `fsync`（不释放资源）；
//! - `Table.close()`：checkpoint + 释放资源（**有序退出的标准入口**）。
//!
//! ## 用法
//!
//! ```zig
//! shutdown.install();
//! while (!shutdown.requested()) { ... 正常干活 ... }
//! try table.close();          // 落段 + 清 WAL + fsync
//! ```
//!
//! ## 平台差异（决定处理器里能不能干活）
//!
//! - **Windows**：`SetConsoleCtrlHandler` 的回调在**另一个线程**上跑，理论上可以做真实
//!   IO；但本模块仍只置标志 —— 在别人的线程里 `fsync` 会跟主线程抢锁，得不偿失。
//!   覆盖 Ctrl+C / Ctrl+Break / 关窗口 / 注销 / 关机五类。
//! - **POSIX**：信号处理器只允许 async-signal-safe 操作，**只能置原子标志**，
//!   绝不能在里面 `flush` / `fsync` / 分配内存。
//!
//! 两边的共同做法：**信号只负责「喊停」，收尾永远在主循环里做**。

const std = @import("std");
const builtin = @import("builtin");

var requested_flag: std.atomic.Value(bool) = .init(false);
var installed: bool = false;

/// 真的有「系统信号」这回事的平台。
///
/// 不能用「非 Windows 就当 POSIX」：`freestanding` / `wasm` / `uefi` 等目标也有
/// `builtin.os.tag != .windows`，但它们根本没有进程信号 —— 在那些目标上
/// `std.posix.SIG` 就是 `void`。用类型本身当判据，比手写平台白名单可靠：
/// 白名单会漏平台（第一版写了 `solaris`，而 Zig 0.17 的 `Target.Os.Tag` 里根本没这个成员，
/// 编译直接报错），也会在新增目标时悄悄失配。
/// 这条直接关系到项目硬约束 §16.5（C 档无 OS 必须能编）。
const has_posix_signals = std.posix.SIG != void;

/// 是否收到过退出请求（幂等，可反复查）。
pub fn requested() bool {
    return requested_flag.load(.seq_cst);
}

/// 置位退出请求。信号处理器与测试共用这一条写入路径 ——
/// 只有一处写，才不会出现「某一类信号忘了置标志」这种漏。
pub fn request() void {
    requested_flag.store(true, .seq_cst);
}

/// 清掉退出请求（**仅供测试**与「用户取消退出」场景）。
pub fn reset() void {
    requested_flag.store(false, .seq_cst);
}

/// 安装退出信号处理器（幂等：重复调用不会重复注册）。
///
/// **注册失败不置位**：Windows 上 `SetConsoleCtrlHandler` 会返回 0 表示失败，
/// 此时保留 `installed = false`，调用方修好环境后可以重试。
/// （旧写法是“先置位再注册”，一旦失败就永远无法重试 —— 而没处理器等于强杀。）
pub fn install() void {
    if (installed) return;

    if (comptime builtin.os.tag == .windows) {
        // 返回 0 表示注册失败 —— 不该静默当成功：没有处理器就等于强杀。
        if (kernel32.SetConsoleCtrlHandler(&handleWindowsCtrl, 1) == 0) {
            std.log.err("注册控制台控制处理器失败：进程被 Ctrl+C / 关窗口 / 关机时将直接终止，" ++
                "WAL 用户态缓冲中未落盘的数据会丢失（wal_buf_bytes 越大丢得越多）", .{});
            return; // 不置位，允许重试
        }
        installed = true;
    } else if (comptime has_posix_signals) {
        const posix = std.posix;
        const act: posix.Sigaction = .{
            .handler = .{ .handler = handlePosixSignal },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        posix.sigaction(.INT, &act, null);
        posix.sigaction(.TERM, &act, null);
        // 注意：`SIGHUP` 不接 —— 那是「终端断开」不是「该退出」，两者语义不同。
    } else {
        // freestanding / wasm / uefi 等：没有进程信号这回事，什么都不做。
        // 这些场景下「有序收尾」由宿主在关闭电源/跳转前自己调 `Table.close()`。
    }
}

// ---------------------------------------------------------------- Windows

const kernel32 = struct {
    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (u32) callconv(.winapi) i32,
        add: i32,
    ) callconv(.winapi) i32;
};

/// 控制台控制事件代码（`wincon.h`）。
const CTRL_C: u32 = 0;
const CTRL_BREAK: u32 = 1;
const CTRL_CLOSE: u32 = 2;
const CTRL_LOGOFF: u32 = 5;
const CTRL_SHUTDOWN: u32 = 6;

fn handleWindowsCtrl(ctrl_type: u32) callconv(.winapi) i32 {
    switch (ctrl_type) {
        CTRL_C, CTRL_BREAK, CTRL_CLOSE, CTRL_LOGOFF, CTRL_SHUTDOWN => {},
        // 未知类型：不认领，交回默认处理程序
        else => return 0,
    }
    request();
    // 返回 1 = 已处理：**阻止系统直接杀进程**，给主循环一次收尾的机会。
    // 这是和 POSIX 最大的差别 —— Windows 上「认领」本身就是在争取退出时间。
    return 1;
}

// ---------------------------------------------------------------- POSIX

/// 信号处理器的参数类型 —— 不能硬写 `c_int`。
///
/// 0.17 里 `std.posix.SIG` 在 Linux 上是**枚举**（`os.linux.SIG__enum_1`），
/// 而不是整数；`Sigaction.handler` 的期望类型因此是
/// `*align(1) const fn (SIG__enum_1) callconv(.c) void`。
/// 硬写 `c_int` 在 Windows 上永远验不出来（那边走另一分支），**一交叉到 Linux 就报**：
/// `expected type '... fn (os.linux.SIG__enum_1) ...', found '... fn (c_int) ...'`。
///
/// 解包路径（实测得出，不是猜）：
/// `Sigaction.handler` 是 **C 侧 union**（`os.linux.Sigaction__union_0`，含 `handler` /
/// `sigaction` 两支，对应 SA_SIGINFO）→ 取 `.handler` → `?sigaction_fn` → 函数 → `params[0]`。
const SigArg = if (has_posix_signals) sigArgOf(@FieldType(std.posix.Sigaction, "handler")) else c_int;

fn sigArgOf(comptime HandlerField: type) type {
    const arm: type = switch (@typeInfo(HandlerField)) {
        .@"union" => @FieldType(HandlerField, "handler"),
        else => HandlerField,
    };
    const maybe_fn: type = switch (@typeInfo(arm)) {
        .optional => |o| o.child,
        else => arm,
    };
    const fn_type: type = switch (@typeInfo(maybe_fn)) {
        .pointer => |p| p.child,
        .@"fn" => maybe_fn,
        else => @compileError("Sigaction.handler 解不出函数类型：" ++ @typeName(maybe_fn)),
    };
    return switch (@typeInfo(fn_type)) {
        // 0.17：`Fn.params` 已改成 `param_types: []const ?type`（null = 泛型/anytype）
        .@"fn" => |f| f.param_types[0] orelse c_int,
        else => @compileError("Sigaction.handler 解不出函数类型：" ++ @typeName(fn_type)),
    };
}

fn handlePosixSignal(_: SigArg) callconv(.c) void {
    // async-signal-safe：只置一个原子标志，别的一律不做。
    request();
}

// ---------------------------------------------------------------- 测试

test "退出标志：request / requested / reset 单一路径" {
    reset();
    try std.testing.expect(!requested());
    request();
    try std.testing.expect(requested());
    // 重复置位幂等
    request();
    try std.testing.expect(requested());
    reset();
    try std.testing.expect(!requested());
}

test "退出标志：信号处理器置位后主循环能看见（模拟真实退出握手）" {
    reset();
    // 直接调处理器本体（等于「信号到了」），不依赖真的发信号：
    // 发真信号在 CI/无控制台环境下不可移植，而这里要验的是**标志链**而不是信号投递。
    if (comptime builtin.os.tag == .windows) {
        try std.testing.expectEqual(@as(i32, 1), handleWindowsCtrl(CTRL_C));
    } else if (comptime has_posix_signals) {
        // 直接调处理器本体（等于「信号到了」）。参数类型随平台变（见 SigArg），
        // 枚举型 SIG 用 @enumFromInt，整数型照原样传。
        handlePosixSignal(if (@typeInfo(SigArg) == .@"enum")
            @as(SigArg, @enumFromInt(2)) // SIGINT
        else
            2);
    } else {
        request(); // 无信号平台：只能验标志本身
    }
    try std.testing.expect(requested());

    // 主循环退出后清干净，不影响同一进程里后面的测试
    reset();
    try std.testing.expect(!requested());
}

test "退出标志：Windows 未识别的控制事件不认领（返回 0，交回默认处理）" {
    if (comptime builtin.os.tag != .windows) return;
    reset();
    try std.testing.expectEqual(@as(i32, 0), handleWindowsCtrl(99));
    try std.testing.expect(!requested());
}

test "信号注册：install() 幂等，且本机确实注册成功" {
    reset();
    install();
    install(); // 第二次必须是无副作用的空转
    try std.testing.expect(!requested());

    if (comptime builtin.os.tag == .windows) {
        // `install()` 内部的失败只记日志（返回值不是错误码），所以这里直接再问一次内核：
        // 能注册成功 = extern 声明、`callconv(.winapi)` 与 BOOL 宽度都写对了。
        // 没有这条断言，Windows 分支就只是「能编译」，从没被真正跑过。
        try std.testing.expect(kernel32.SetConsoleCtrlHandler(&handleWindowsCtrl, 1) != 0);
    }
}
