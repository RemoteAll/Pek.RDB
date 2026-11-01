# 实测数据（原始记录 + 生成表格）

本目录只放**实测产物**，不放估算值。文档里的对比数字必须能在这里找到出处。

## 文件命名

| 文件 | 含义 |
|---|---|
| `zig-<日期>-run<N>.csv` | `spike-zig/zig-out/bin/spike-bench.exe` 的原始 stderr（每行 `metric,count,value`） |
| `zig-<日期>-acbench-run<N>.csv` | `spike-zig/zig-out/bin/spike-bench-ac.exe`（自动 compaction 专项，独立入口） |
| `zig-<日期>-<批次>-run<N>.csv` | 同一日期的**分批重测**（如 `reopen` 只重测冷重开相关项），用 `-ZigGlob` 单独出表 |
| `sqlite-<日期>-run<N>.csv` | `tools/bench-vs-sqlite` 的原始 stdout（同机、同数据集） |
| `对比-<日期>.md` | 由 `tools/compare-bench.ps1` 从上面两类 CSV **自动生成**的中位数对比表（含 min–max） |
| `嵌入式-<日期>.csv` | 极小资源档的 `size` 报告（flash/RAM 字节数，见 `docs/架构设计.md` §16.5） |

## 复现步骤

```powershell
# 1) Zig 侧（三轮，原始输出落盘）
cd spike-zig
zig build -Doptimize=ReleaseFast
$dir = '..\docs\实测数据'
1..3 | ForEach-Object {
    $p = Start-Process .\zig-out\bin\spike-bench.exe `
        -RedirectStandardError (Join-Path $dir "zig-<日期>-run$_.csv") `
        -RedirectStandardOutput (Join-Path $env:TEMP 'bench-stdout.txt') -PassThru
    $p.WaitForExit()
}

# 2) SQLite 对照侧（三轮）
$env:CARGO_TARGET_DIR='D:\cargo-target\pek-rdb-tools'
cargo build --release --manifest-path tools\bench-vs-sqlite\Cargo.toml
1..3 | ForEach-Object {
    $p = Start-Process 'D:\cargo-target\pek-rdb-tools\release\bench-vs-sqlite.exe' `
        -WorkingDirectory (Resolve-Path tools\bench-vs-sqlite) `
        -RedirectStandardOutput "docs\实测数据\sqlite-<日期>-run$_.csv" `
        -RedirectStandardError (Join-Path $env:TEMP 'sqlite-bench-err.txt') -PassThru
    $p.WaitForExit()
}

# 3) 由原始 CSV 生成对比表
powershell -NoProfile -ExecutionPolicy Bypass -File tools\compare-bench.ps1 `
    -Date <日期> -OutFile docs\实测数据\对比-<日期>.md

# 3b) 同一日期有多批数据（比如只改了冷重开）：用 glob 分批，避免新旧混算中位数
powershell -NoProfile -ExecutionPolicy Bypass -File tools\compare-bench.ps1 -Date <日期> `
    -ZigGlob 'zig-<日期>-reopen-run*.csv' -OutFile docs\实测数据\对比-<日期>-reopen.md
```

### 专项基准：自动 compaction（`run-bench-ac`）

**必须用独立入口**，不要塞进整套 `run-bench`。实测：整套跑时前面的 `big_*` 把脏页与页缓存占满，
同一配置三轮波动达 **84%（写入耗时）与 435%（阈值 16）**，中位数完全不可信；
独立进程从干净状态起跑，波动降到 13–45%。

```powershell
cd spike-zig
zig build -Doptimize=ReleaseFast
$dir = '..\docs\实测数据'
1..5 | ForEach-Object {
    $p = Start-Process .\zig-out\bin\spike-bench-ac.exe `
        -RedirectStandardError (Join-Path $dir "zig-<日期>-acbench-run$_.csv") `
        -RedirectStandardOutput (Join-Path $env:TEMP 'acbench-stdout.txt') -PassThru
    $p.WaitForExit()
}
```

汇总时注意**取列不同**：`ac_segs_*` / `ac_compacts_*` / `ac_err_*` / `ac_userbytes_*` / `ac_cmpbytes_*`
的值在**第 2 列**（count），其余指标在第 3 列（value）。

**核心结论用确定性指标**（`ac_wamp_*` 写放大、段数、次数），它们 5 轮波动 0%；
写入耗时在本机受 Windows Defender 实时扫描干扰，只能报区间。

## 纪律（硬性）

1. **禁止手填数字**：对比表只能是 `tools/compare-bench.ps1` 的输出。
2. **禁止单轮下结论**：至少三轮，看中位与 min–max。这台机器上 SQLite 逐行写实测 16K–40K 行/s（2.4× 波动），
   单轮会给出完全相反的结论。
3. **禁止沿用旧数字**：换轮次就重新跑；旧轮次文件保留（可追溯），但文档只引用最新一期。
4. **异常先查环境**：曾出现 `sql_put` 单轮掉到 1/10（后台编译/杀毒干扰），`git stash` A/B 证明与代码无关。

## 耐久口径（2026-11-01 起，硬性）

**基准一律以 SQLite `synchronous=NORMAL` 为对等档**：所有基准表 `wal_sync_every = 0`
（不做周期 WAL fsync；**段 flush 仍逐段 fsync**，严格程度仍高于 SQLite NORMAL）。
`big_put_strong`（`wal_sync_every=10_000`）只作「开强耐久要付多少」的参考行，**不参与 vs-SQLite 判定**。
对照表与实测数据见 `docs/架构设计.md` §16.1.31。

**2026-11-01 及以前的批次**（`p7` 及更早）用的是 `wal_sync_every=10_000`，与 SQLite 不同口径，
写指标不可直接引用；口径对齐后的正式批次是 **`p8` / `p9`**。

### 写路径分解可观测项

`spike-bench` 额外输出两行，专门用来定位「整轮写崩」发生在哪一段：

| 指标 | 第 2 列 | 第 3 列 |
|---|---|---|
| `big_put_breakdown` | `ns_wal_sync`（累计 WAL fsync 纳秒） | `ns_flush`（累计段 flush 纳秒） |
| `big_put_flushmax` | `flush_calls`（flush 次数） | `ns_flush_max`（**单次** flush 最长纳秒） |
| `big_put_strong_breakdown` | 同上，强耐久档 | 同上，强耐久档 |

实测：正常 `ns_flush_max` ≈ 22ms；出问题的轮次会到 **203ms（10 倍）**，同时整体吞吐掉 3–6 倍。
**见到 `big_put` 环比掉一半以上，先看这两行再怀疑算法。**

### WAL 轮换配对 A/B（2026-11-01 起）

`spike-bench` 还会在同进程内跑 7 对「原地截断 vs 删+建 WAL」的配对写，输出
`walab_pair` / `walab_pair_recreate`（每对的两种模式吞吐）与 `walab_ratio`（截断÷重建）。
**这是判定写路径轮换代价的唯一可信口径** —— 该差异只有约 35%，跨批次对比会被 1/7 概率的崩塌噪声吃掉。


## 要不要 git 过滤？（结论：**不要**，2026-11-01 定）

用户问过「实时数据不用 git 过滤吗？」。结论是**这些 CSV 必须进 git**，因为它们是**证据**不是产物：

| | 构建产物 | 基准数据 |
|---|---|---|
| 可再生 | ✅ 重编一次就有 | ❌ **不可复现**——同一次运行不会重来，重跑得到的是另一组数 |
| 用途 | 运行 | 支撑 `docs/决策记录.md` / `docs/架构设计.md` 里的每一个数字 |

`决策记录` 里上百个比值、区间、B/行全引到这里的具体文件；过滤掉就等于「手填数字」，
与硬性纪律 1 直接冲突。体积也不是问题：**203 个文件约 723 KB，最大单文件 8.7 KB**。

**真正该 ignore 的是二进制/中间产物**，已经挡住（`.gitignore`）：

| 路径 | 量级 |
|---|---|
| `/bench-*.db`（SQLite 对照库） | **82 MB** |
| `/bench-data*/`（Zig 基准落盘目录，中断时会留） | 几十 MB |
| `spike-zig/zig-out/`、`spike-zig/.zig-cache/` | 百 MB 级 |

要治理的是**信噪比**，规则如下：

1. **只提交「同批成对 + 至少 3 轮」的批次**。单独一轮没有统计意义。
2. **中间态批次不要留**：改到一半跑出来的批次会污染后续判断（已删过两个）。
3. **探索性批次可以留**，但不得再拿来做比较；下列主题可查。
4. 判定表只允许 `tools/pairs-verdict.ps1`（区间重叠）或 `tools/pairs-paired.ps1`（逐轮比值 + 符号检验）生成。

### 批次索引（按主题）

**最终结论所用（引用时优先看这些）**

| 批次 | 内容 |
|---|---|
| `zig/sqlite-2026-11-01-pfxblk2` + `zig-…-scan10k` | 块内前缀压缩后的同批全量对比：磁盘 40.92 vs 41.56 B/行；21/24 可判定、0 落后 |
| `zig/sqlite-2026-11-01-p7` | **7 轮交替配对**（zig/sqlite 相邻测量），用于 `big_write` 的符号检验 |
| `zig/sqlite-2026-11-01-full` | 第 6 轮审计后的同批全量复核 |
| `zig/sqlite-2026-11-01-disk` | 磁盘占用首次实测（+41% → 经行头瘦身/前缀压缩反超） |

**行格式与编码**：`hdr7` / `hdr7b` / `hdr7c`（行头 17→7 B）、
`varint` / `varint2`（纯 varint 头，**已否**）、`recdec`（行解码配对微基准）、
`keycmp`（三种 key 比较实现）、`pfxprobe`（**逐条**前缀压缩探针，**已否**）

**扫描 / 归并 / 裁剪**：`concat`（顺序拼接）、`prunebefore`（反向段裁剪）、`merge2` / `mergegap`、
`proj` / `matopt` / `sqlnocopy`（投影下推 / 物化 / SQL 零拷贝）、
`scan1` / `scanfull` / `onescan` / `streaming` / `limit`

**存储与恢复**：`wal1`（组提交）、`reopen`（5 轮）/ `reopen2`、`compact` / `acbench`、
`bloomonline`（Bloom 在线置位）、`heap` / `lazy`

**审计与复核**：`audit6` / `abaudit`（第 6 轮审计同进程 A/B）、
`equal` / `final` / `rerun` / `regress`、`vector`（向量检索原型）、`嵌入式` / `嵌入式-m0`（M0 内存预算）

> 其中 `final` / `regress` / `hdr7b` / `onescan` / `scanfull` / `varint` / `varint2` /
> `bloomonline` / `recdec` 的批次名未被任何文档引用（结论以指标名或节号引用），属保留备查。

   反常数据先看机器负载，别急着改代码。
5. **口径不对，数字再稳也是错的**：算写放大时第一版累加的是索引字节（`fin.bytes.len`）而不是数据文件字节，
   得到的是「索引写放大」。**报数字前先确认这个数字代表什么**。
6. **改了基准也要在 Debug 下跑一次 `zig test`**：曾出现 UAF（`finishBytes()` 之后读 `w.buf`），
   ReleaseFast 下数字全对、退出码 0，只有 Debug 测试崩（退出码 3）。
