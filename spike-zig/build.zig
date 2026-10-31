const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("pek_rdb_spike", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "spike-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pek_rdb_spike", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run-bench", "Run the spike benchmark");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // 结构体尺寸报告（嵌入式 RAM 预算核算用）：zig build sizes
    // 可加 -Dtarget=x86-windows 得到 32 位指针宽度下的布局（与 RISC-V / Cortex-M 同宽）
    const sizes_exe = b.addExecutable(.{
        .name = "size-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sizes.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "pek_rdb_spike", .module = mod },
            },
        }),
    });
    const run_sizes = b.addRunArtifact(sizes_exe);
    const sizes_step = b.step("sizes", "Report struct sizes (embedded RAM budget)");
    sizes_step.dependOn(&run_sizes.step);

    // 嵌入式交叉编译检查（只编译不链接，不需要 entry）：
    //   zig build check -Dtarget=riscv32-freestanding -Dcpu=baseline
    const check_obj = b.addObject(.{
        .name = "pek-rdb-check",
        .root_module = mod,
    });
    const check_step = b.step("check", "Cross-compile the core module for an arbitrary target");
    check_step.dependOn(&check_obj.step);

    // MCU 探针（M0 档裸机链接 + flash/RAM 实测）：
    //   zig build mcu -Dtarget=riscv32-freestanding -Doptimize=ReleaseSmall
    const mcu = b.addExecutable(.{
        .name = "mcu-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcu_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pek_rdb_spike", .module = mod },
            },
        }),
    });
    mcu.root_module.strip = true;
    b.installArtifact(mcu);
    const mcu_step = b.step("mcu", "Build the bare-metal M0 probe (cross-compile)");
    mcu_step.dependOn(&b.addInstallArtifact(mcu, .{}).step);
}
