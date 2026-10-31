# Pek.RDB

一体化数据引擎（Rust main-line / Zig spike）：**嵌入 + 网络双模**、**文件夹即数据库**，
四类能力融合 —— 关系型 Engine、时序 + MQ 的 Flux、Bitcask KV、Pek.RCode Provider。

> 设计口径唯一真相源：`docs/架构设计.md`。代码与文档冲突以文档为准，改设计必须同步文档并追加决策记录。

## 现状（2026-10-31）

- **M1 存储内核**：Arena SkipList memtable → 不可变段（稀疏索引 + Bloom + CRC，mmap 只读）→ WAL 组提交 → 恢复重放，已完成并有恢复回归。
- **M2 SQL 子集**：`CREATE TABLE` / `INSERT` 多行 / `SELECT`（WHERE / ORDER BY / LIMIT / OFFSET / 投影）/ `UPDATE` / `DELETE`，方言对齐 SQLite 子集（有意差异见 `docs/架构设计.md` §7.1）。
- **Zig 试验（`spike-zig/`）**：按用户 2026-10-31 决定「先试试 Zig」，用同一套磁盘格式做性能对照，结论写入 `docs/决策记录.md`。

## 实测（同机、单线程、1M 行 × 32B 值、SQLite 为 WAL + `synchronous=NORMAL`）

| 项目 | Pek.RDB（Zig spike） | SQLite | 比值 |
|---|---|---|---|
| 逐行写（autocommit 口径） | 1,685,876 行/s | 20,352 行/s | 82.84× |
| 单事务批量写 | 1,979,202 行/s | 998,268 行/s | 1.98× |
| 主键点查 | 1,393,359 次/s | 126,772 次/s | 10.99× |
| 范围扫描（含值） | 11,436,414 行/s | 7,439,369 行/s | 1.54× |
| 范围扫描（仅 key） | 16,249,594 行/s | 10,320,983 行/s | 1.57× |
| 多段合并扫描（2 段） | 11,429,878 行/s | — | — |
| 冷重开（1M 行） | 11.00 ms | 1.78 ms | 6.17×（越低越好，**仍落后**） |

> **数字来源**：`docs/实测数据/zig-2026-10-31-run{1,2,3}.csv` 与 `sqlite-2026-10-31-run{1,2,3}.csv`
> 为三轮原始输出，表格由 `tools/compare-bench.ps1` 自动生成（见 `docs/实测数据/对比-2026-10-31.md`）。
> 口径见 `docs/架构设计.md` §16.1；SQLite 逐行写在这台机器上波动极大（16K–40K），以中位为准。

## 构建与验证

```powershell
# Rust 主线（M1/M2 内核在 spike-zig 之前以 Rust 实现，见 docs）
$env:CARGO_TARGET_DIR='D:\cargo-target\pek-rdb'
cargo test
cargo clippy --all-targets -- -D warnings

# Zig 试验
cd spike-zig
zig build test                  # 单元 + 集成回归
zig build -Doptimize=ReleaseFast
.\zig-out\bin\spike-bench.exe   # 基准（std.debug.print → stderr）
```

## 许可（重要）

**个人使用免费；商业使用需要授权，或者同样开源（AGPL-3.0）。**

- 个人学习、研究、评估、本机自用：免费，可修改自用；
- 商业使用（产品内嵌、DBaaS/SaaS/托管/API 服务、企业内部生产经营、客户交付、转售）：
  **必须二选一**
  - 取得**商业授权**（闭源使用，见 `COMMERCIAL.md`）；
  - 或者完整遵守 **AGPL-3.0**：你的修改版（含对外提供服务所运行的版本）必须向使用者
    提供完整对应源码，并以 AGPL-3.0 授权。

详见 [`LICENSE`](LICENSE) 与 [`COMMERCIAL.md`](COMMERCIAL.md)。
