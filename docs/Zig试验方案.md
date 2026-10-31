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

## 7. 首轮实测（2026-10-31，试验版）

- 构建：首次 `-Doptimize=ReleaseFast` ~11s；缓存 0.24s；`zig build test` ~3s（含跑测试）。
- 单线程、段整段载入内存（尚未 mmap/块缓存）：

| 指标 | 数值 |
|---|---|
| 写入 100 万行 | 139 万行/s |
| flush 100 万行 | 976 万行/s |
| 点查（段内） | 193 万次/s |
| 范围扫描 | 478 万行/s |
| 重开恢复 | 25ms |

- 已修的硬伤：SkipList 查找退化 O(n×层数)、WAL 逐条写、重开未合并段水位（详见决策记录 2026-10-31（九））。
- **首轮对比已完成（见 §7.1）**，但口径受限：Zig 段整段载入内存、扫描含 merge/拷贝、单线程。下一轮改 mmap + 流式迭代后重测，才能按 §3 下结论。

> 说明：`tools/bench-vs-sqlite` 只是**对照基线工具**（测 SQLite 侧数字），不是产品；产品是 `spike-zig/` 的存储内核与后续 SQL 层。

### 7.1 与 SQLite 首轮对比（同机、1M 行、32B 值、WAL+NORMAL、单线程）

| 指标 | Zig 试验版 | SQLite 3.53.2 | 比值 |
|---|---|---|---|
| 逐行写 | 125.9 万/s | 6.5 万/s | 19.2× |
| 批量写 | 203.9 万/s | 179.8 万/s | 1.13× |
| 点查 | 189.4 万/s | 13.5 万/s | 14.0× |
| 范围扫描（含值） | 447.8 万/s | 926.1 万/s | 0.48× |
| 重开恢复 | 26ms | 2.3ms | 0.09× |

SQL 同层（PK 点查快路径后）：逐行 INSERT 109.2 万/s vs 6.5 万/s（16.7×）；PK 点查 78.1 万/s vs 13.5 万/s（5.8×）。

mmap + 零拷贝扫描后：扫描（refs）1742 万行/s vs SQLite scan_v 926 万（1.88×，口径不同需注明）；重开 12ms vs 2.3ms（仍落后）。
注意：Zig 侧尚无约束/二级索引/事务隔离，段仍在内存，单线程；这些数字不能直接当产品结论。

口径警告：Zig 段整段载入内存（高估读、低估恢复）；扫描含 merge/去重/拷贝；单线程 Windows。
下一轮：流式扫描 + mmap 后重测。

## 8. 下一步

1. 写 `tools/bench-vs-sqlite`（Rust 独立小工具，rusqlite 已由 Pek.RCode 引入）：同 100 万行、相同点查/扫描/批量写场景。
2. Zig 侧补齐块内二分、段 mmap（当前整段载入内存会高估读性能）。
3. 按 §3 退出标准给出结论；若回 Rust，Zig 代码保留为参考。
