const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("pek_rdb_spike", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // **lite 模式**（`-Dlite=true`）：跳过重型诊断探针，只跑与 SQLite 对比的指标。
    // 为什么要它：加上 strong/fb32/fb64/walab 四组后，一次基准的写入量从约 1.0GB 涨到约 2.5GB，
    // 这本身就容易把机器写到饱和（A 类写抖动的触发源）。官方对比用 lite，
    // 重型探针用单独批次跑。
    // 用编译期开关而不是环境变量：Zig 0.17 的 `std.process` 已经没有 `getEnvVarOwned`，
    // 而编译期常量零开销、也进不了热路径。
    const lite = b.option(bool, "lite", "Skip heavy diagnostic probes (official vs-SQLite runs)") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "lite", lite);

    const exe = b.addExecutable(.{
        .name = "spike-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pek_rdb_spike", .module = mod },
                .{ .name = "build_options", .module = opts.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run-bench", "Run the spike benchmark");
    run_step.dependOn(&run_cmd.step);

    // 自动 compaction 专项基准：只跑一个场景，从干净状态起跑。
    // 整套 bench 里 ac 段的同配置波动实测到 84%，中位数不可信，故单独入口。
    const ac_exe = b.addExecutable(.{
        .name = "spike-bench-ac",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_ac.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pek_rdb_spike", .module = mod },
            },
        }),
    });
    b.installArtifact(ac_exe);
    const run_ac = b.addRunArtifact(ac_exe);
    const ac_step = b.step("run-bench-ac", "Run the auto-compaction benchmark only");
    ac_step.dependOn(&run_ac.step);

    // AI 向量检索可行性原型：只测「暴力全扫 + SIMD 距离」的下限，不引入任何索引。
    // 独立入口，因为它是 300MB 级分配、且与存储引擎无关。
    const vec_exe = b.addExecutable(.{
        .name = "spike-bench-vector",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_vector.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(vec_exe);
    const run_vec = b.addRunArtifact(vec_exe);
    const vec_step = b.step("run-bench-vector", "Run the vector search feasibility prototype");
    vec_step.dependOn(&run_vec.step);

    // 容量阶梓基准（决策记录八十九）：1 亿行量级的开表/冷重开/点查/扫描。
    // 单独入口：灌数据写 4.86 GB、跑几分钟，不能塞进 vs-SQLite 的正式批次。
    // 参数用编译期选项（Zig 0.17 的 `main` 签名/`b.args` 与旧版不同，编译期常量零风险）：
    //   zig build run-scale -Doptimize=ReleaseFast -Dscale-rows=100000000 -Dscale-dir=scale-1e8
    const scale_rows = b.option(u64, "scale-rows", "run-scale: rows to insert") orelse 2_000_000;
    const scale_dir = b.option([]const u8, "scale-dir", "run-scale: data directory") orelse "scale-data";
    // 段数单变量实验用：同样行数、只改 flush_bytes 造出不同段数。
    const scale_flush = b.option(u64, "scale-flush-bytes", "run-scale: flush_bytes (smaller = more segments)") orelse (64 << 20);
    // 数据段 mmap 预缺页上限（0 = 不预取，默认）。旧行为（populate 默认 true）用大值恢复：
    //   -Dscale-data-prefault=4611686018427387904
    const scale_data_prefault = b.option(u64, "scale-data-prefault", "run-scale: prefault data mmap when file <= N bytes (0 = never)") orelse 0;
    // 持久化档：true = 每批 fsync（最强）；false = 只写进 OS 缓存（与 SQLite synchronous=NORMAL 对齐）。
    const scale_durable = b.option(bool, "scale-durable", "run-scale: fsync before commit returns (false = SQLite NORMAL equivalent)") orelse true;
    // 分层合并（容量线②）：段数超过 max 就合并最小的 fanout 个段。0 = 关闭。
    const scale_tiered_max = b.option(u64, "scale-tiered-max", "run-scale: tiered compaction segment cap (0 = off)") orelse 0;
    const scale_tiered_fanout = b.option(u64, "scale-tiered-fanout", "run-scale: tiered compaction fanout") orelse 4;
    const scale_opts = b.addOptions();
    scale_opts.addOption(u64, "rows", scale_rows);
    scale_opts.addOption([]const u8, "dir", scale_dir);
    scale_opts.addOption(u64, "flush_bytes", scale_flush);
    scale_opts.addOption(u64, "data_prefault", scale_data_prefault);
    scale_opts.addOption(bool, "durable", scale_durable);
    scale_opts.addOption(u64, "tiered_max", scale_tiered_max);
    scale_opts.addOption(u64, "tiered_fanout", scale_tiered_fanout);
    const scale_exe = b.addExecutable(.{
        .name = "spike-scale",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_scale.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pek_rdb_spike", .module = mod },
                .{ .name = "build_options", .module = scale_opts.createModule() },
            },
        }),
    });
    b.installArtifact(scale_exe);
    const run_scale = b.addRunArtifact(scale_exe);
    const scale_step = b.step("run-scale", "Run the capacity ladder benchmark (-Dscale-rows / -Dscale-dir)");
    scale_step.dependOn(&run_scale.step);

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
    // 注意：**不能** b.installArtifact(mcu)，否则默认 `zig build` 会在宿主上尝试链接 mcu-probe
    // （没有 main，只有 _start）→ 默认构建失败。只由 `zig build mcu` 步骤安装。
    const mcu_step = b.step("mcu", "Build the bare-metal M0 probe (cross-compile)");
    mcu_step.dependOn(&b.addInstallArtifact(mcu, .{}).step);
}
