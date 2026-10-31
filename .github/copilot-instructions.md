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

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；② `tools/continuity/sync-memory.ps1` 同步记忆；
③ 跑回归验证并如实汇报（测试通过数、clippy 结果）；④ 提交并推送（远程 `main`；提交信息用 `git commit -F <UTF-8 文件>`）。
