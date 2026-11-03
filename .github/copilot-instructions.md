# Pek.RDB · 项目指令

> 全项目通用规则见用户级《跨项目接续协议》（本机 `%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md`；模板在 `tools/continuity/templates/`）。
> **开工先读（存在则读，按序）**：`.github/copilot-instructions.md` → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` → `docs/决策记录.md` 最新节。

## 项目定位

一体化数据引擎（Rust）：**嵌入 + 网络双模**、**文件夹即数据库**、四类能力融合
（关系型 Engine / 时序+MQ 的 Flux / Bitcask KV / Pek.RCode Provider）。

- **设计唯一口径**：`docs/架构设计.md`（磁盘格式、读写路径、SQL 子集、里程碑）。
- 代码与文档冲突 → 以文档为准；改设计必须同步文档 + 追加决策记录。

## 硬约束（写码前必看）

1. **复用优先**：写任何功能前先检索 `DH.RustBase` / `Pek.RCode` / 兄弟项目；本仓已确定复用：
   | 能力 | 复用来源 |
   |---|---|
   | 原子写 / 目录 / 执行位 | `dhrust::io::{write_all_text_atomic, write_all_bytes_atomic, exe_dir}` |
   | 日志 / 时间 / 配置 | `dhrust::logs`、`dhrust::times`、`dhrust::config`（feature `toml`） |
   | 网络 / 路由 / 鉴权 / WAF | `dhrust::net::*`、`pek_rwaf`（网络模式接入时） |
   | ORM 协议 | `pek_rcode::db_service::DbService`（`/Db/*`）、`pek_rcode::session::SqlSession` |
   | 数据库类型判定 | `pek_rcode::dialect::DatabaseKind` |
2. **纯 Rust 依赖**：不允许引入 C/C++ 静态库；允许 `crc32fast` / `memmap2` / `lz4_flex` 这类纯 Rust 或 syscall 封装。
3. **磁盘格式变更 = 破坏兼容**：段/WAL 格式改动必须升 `format` 版本号并在决策记录说明迁移方案。
4. **禁止静默吞错**：CRC 失败 / 段缺失 / 版本不匹配必须报 `文件:偏移 + 原因`，不得跳过当没事。
5. **不在读路径做 IO 持锁**：读锁只用于取快照（`Arc<Memtable>` / `Vec<Arc<Segment>>`），块读取在锁外。
6. **极小资源档不可破坏（§16.5）**：任何新能力都必须能**编译期关闭**、容量必须**可静态配置且允许为 0**；
   不得引入不可关闭的固定内存开销、后台线程、mmap 或系统堆依赖（C 档：无 MMU、无 OS、固定池）。
   提交前自检：这段代码在 `sql`/`mmap`/`threads`/`alloc` 全关的配置下能否编译并通过 KV 回归。
7. **基准数字必须来自实测**：报数字前先跑，原始输出落 `docs/实测数据/*.csv`，
   表格用 `tools/compare-bench.ps1` 从原始文件生成；禁止手填/沿用旧数字，禁止单轮下结论（三轮取中位）。

## 许可（硬约束，2026-10-31 定）

- 本项目**双许可**：个人非商业使用免费；**商业使用需取得商业授权，或同样开源（AGPL-3.0）**。
  见 `LICENSE`、`COMMERCIAL.md`、`README.md`「许可」节。
- 新增源文件首行加 SPDX 头：`SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial`
  （Zig 用 `//`，Rust 用 `//`，Markdown/配置免加）。
- **引入第三方依赖先核许可**：必须允许本项目的双许可形态（闭源商业授权场景可闭源分发）。
  允许 MIT / Apache-2.0 / BSD-2/3 / ISC / Zlib / 0BSD / Unlicense / MPL-2.0（MPL 只触碰其自身文件）；
  **禁止** GPL / AGPL（作为依赖）/ SSPL / Commons-Clause / 任何「限制商业使用」的条款。
  `tools/bench-vs-sqlite` 仅为对照工具（rusqlite，MIT），不随产品分发。
- 不得移除、篡改既有版权与许可声明。

## 构建与验证

```powershell
$env:CARGO_TARGET_DIR='D:\cargo-target\pek-rdb'   # G 盘曾只剩 0.6GB；统一把 target 放 D
cargo test                                         # 单元 + 集成回归
cargo clippy --all-targets -- -D warnings          # 合入前零告警
```

- 依赖下载走 `rsproxy`（`.cargo/config.toml` 已配 `[source.crates-io] replace-with`）。
- 只 Windows 验证不够：涉及 `#[cfg(unix)]` 的改动要补 `cargo check --target x86_64-unknown-linux-musl`。

## Zig 试验（`spike-zig/`，用户 2026-10-31 指定「先试试 Zig」）

- 工具链：**Zig 0.17.0**（`zig version` 校验）；试验边界与退出标准见 `docs/Zig试验方案.md`。
- **写 Zig 代码前必读**（项目级 skill，来源 `github.com/zigcc/skills` @ `2f9bf9d`，MIT）：
  - `.github/skills/zig-0-17/SKILL.md`（0.17 API 变更与迁移）
  - `.github/skills/zig-tiger-style/SKILL.md`（TigerStyle：安全 > 性能 > 开发体验）
- 0.17 硬变更（已实测）：`std.Io` 统一 IO（`File`/`Dir`/`Mutex` 都要 `io` 参数）、`std.Thread.Mutex` 已移除、
  `std.ArrayList` 为 unmanaged（`= .empty` + `append(alloc, x)`）、`@backingInt`/`@fromBackingInt`、`@splat`。
- 构建：`cd spike-zig; zig build test` / `zig build run-bench`；产物目录 `spike-zig/.zig-cache`、`spike-zig/zig-out` 不入库。
- 试验结论必须实测写入 `docs/决策记录.md`（含数据与命令），不靠印象。

## 审计纪律（硬约束，2026-11-03 定）

**审计 ≠ 读 diff。** 读 diff 只覆盖改动的那点地方，且覆盖不了"改动的反面"（失败路径、空结果、
空表、截断文件）。所以：

1. **先填 `docs/审计覆盖矩阵.md`，再动手。** 表里有空格就不能说"审完了"；
   新增能力时先在表里加一行（状态空间 + 机械检查位置），再写代码。
2. **每一类缺陷都必须有"跑测试就报"的机械手段**：内存类交给
   `checkAllAllocationFailures` / 自驱 OOM 扫描；语义类交给**差分随机测试**
   （独立朴素参考实现，逐格比列名与值）；持久化类交给**注入破坏**（截断/位翻转/崩溃态）。
   人眼只用来处理机器报出来的差异。
3. **每修一处必须做撤销验证**：撤掉修复 ⇒ 守卫必须红。不做这一步就不知道守卫有没有用。
4. **任何注入/破坏/恢复类用例都要有防空跑断言**（证明"破坏真的发生了、恢复真的干了活"）。
   第一版 WAL 截断用例就截的是**空文件**，全绿但什么都没测。
5. **已知缺口必须带棘轮**（`expect(fails <= N)` 这类），修好只会变少、变差立刻红；
   禁止用"记在文档里"代替棘轮，也禁止为了绿而放宽断言。

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；② `tools/continuity/sync-memory.ps1` 同步记忆；
③ 跑回归验证并如实汇报（测试通过数、clippy 结果）；④ 提交并推送（远程 `main`；提交信息用 `git commit -F <UTF-8 文件>`）。
