# Zig 0.17 试验方案（先 Zig、再决定是否回 Rust）

> 用户口径（2026-10-31）：「我想先用ziglang试试，如果最终结果不合适再换用rust」
> 本文件是试验的边界与退出标准；**不影响** `docs/架构设计.md` 作为产品设计口径（语言无关部分照旧）。

## 1. 为什么要试

- 用户希望验证 Zig 是否能以更低开销达成 §16.1 的达标线（SQLite/Redis/TDengine/MySQL 强项对标）。
- 只有**同架构、同基准**的实测对比能回答"换语言值不值"，不靠印象（沿用 2026-10-29「不能猜」）。

## 2. 试验范围（只做 M1 核心，不做 SQL/网络/集群）

| 模块 | 内容 |
|---|---|
| `codec` | varint、CRC32、NULL 位图 |
| `key` | 顺序保持键编码（单列 int/text 起步） |
| `memtable` | Arena SkipList，排序 `(key ASC, seq DESC)` |
| `wal` | 追加日志、批次记录、组提交、撕裂尾截断重放 |
| `segment` | 不可变段 `.data` + `.idx`（稀疏索引 + Bloom + 块内二分） |
| `table` | put/get/delete/scan、snapshot 可见性、flush 到段 |
| `bench` | 纯内存与落盘两档：写入吞吐、点查 p50/p99、范围扫描、恢复耗时 |

**不做**：SQL 解析/执行、KV、Flux、网络协议、复制。试验只回答"存储内核在 Zig 下够不够快、够不够稳"。

## 3. 退出标准（先定，避免事后找理由）

| 判定 | 条件 | 动作 |
|---|---|---|
| **继续 Zig** | 与 Rust 参考实现（同算法）相比：写入吞吐 ≥1.0×、点查 ≥1.0×，且代码量/缺陷率可接受 | Zig 作为主实现，架构文档 §16.4 改写 |
| **回 Rust** | 任一核心指标 <0.9×，或 Zig 版 0.17 API 阻力导致同等功能代码量 >1.5× Rust，或出现难以定位的内存/并发缺陷 | 回 Rust 落 M1，Zig 仅留作参考 |
| **灰区（0.9–1.0×）** | 指标接近但开发成本明显更高 | 由用户拍板（默认回 Rust） |

基准必须同机同盘、同数据量（10⁶ 行）、同 WAL 策略（`Normal` 组提交），预热后取 p50/p99；结果只写 CSV 与结论，不写"感觉"。

## 4. 工具链与资料（已确认）

- `zig version` = **0.17.0**（`%LOCALAPPDATA%\Microsoft\WinGet\Links\zig.exe`）。
- 项目级 skill 已安装：
  - `.github/skills/zig-0-17/SKILL.md`（含 `scripts/check-zig-version.sh`）
  - `.github/skills/zig-tiger-style/SKILL.md`
  - 来源：`https://github.com/zigcc/skills`，提交 `2f9bf9d609be85bb2d171e6977a3bbad0badb83c`（2026-10-12，MIT）。
- 本地权威源码：`<zig>/lib/std`（写代码前用 `zig env` 定位，不硬编码路径）。

## 5. 0.17 已知硬变更（本试验会直接踩到）

- `std.Io` 成为统一 IO 接口：`File`/`Dir`/`Mutex` 的操作都需要 `io: Io` 参数；
  `std.Io.Threaded.init(alloc, .{})` 提供阻塞实现，`threaded.io()` 取句柄。
- `std.Thread.Mutex` 不再提供，互斥量在 `std.Io.Mutex`（`lockUncancelable(io)` / `unlock(io)`）。
- `std.ArrayList(T)` 为 **unmanaged**：`var l: std.ArrayList(T) = .empty; l.append(alloc, x); l.deinit(alloc);`
- 分配器：`std.heap.DebugAllocator`（0.17 新推荐 `SafeAllocator`）/ `std.heap.smp_allocator`。
- 语言层：`@backingInt`/`@fromBackingInt` 取代枚举转换、`@splat` 取代 `**`、`@cImport` 移除（改用 translate-c 包）。

## 6. 产物与验证

- 代码：`spike-zig/`（独立 `build.zig`，不混进 Rust crate）。
- 每次提交前：`zig build test` 全绿 + `zig build run-bench` 输出 CSV。
- 结论写入 `docs/决策记录.md`（含实测数字与命令），并同步记忆。
