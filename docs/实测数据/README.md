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
2b. **vs SQLite 的正式结论一律用 ABBA 批次**（见下），不用顺序跑法。
3. **禁止沿用旧数字**：换轮次就重新跑；旧轮次文件保留（可追溯），但文档只引用最新一期。
4. **异常先查环境**：曾出现 `sql_put` 单轮掉到 1/10（后台编译/杀毒干扰），`git stash` A/B 证明与代码无关。

## 口径一样（2026-11-01 起，硬性）

用户原话：**「对比的口径必须要一样」**。

**「口径一样」= 四条同时成立**，缺一条就必须标注，且**不得作为性能结论对外**：

1. **同逻辑工作量** —— 两边产出同样的行/同样的结果（不只是调用同名函数）；
2. **同事务粒度** —— 都是逐行提交，或都是一次提交 N 行，不能一边逐行一边单事务；
3. **同持久化档** —— 都不 fsync / 都 fsync，见上节；
4. **同写入字节量** —— **报吞吐必须同时报每行写入磁盘的字节数**。

第 4 条是 2026-11-01 补的，起因是一次被用户当场质疑的结论：

| 场景 | 每行写入 WAL |
|---|---|
| SQLite 逐行 autocommit（页 4096） | **4,201 B** |
| SQLite 一次提交 N 行 | **41.2 B** |
| 我方逐行写入 | **63.0 B** |
| 我方一次提交 N 行 | **43.0 B** |

SQLite 的 WAL 是**页粒度**：逐行 autocommit 时，一行 40 字节的数据要陪一整页 4KB 搬运。
所以「我方逐行写快 9.96×」衡量的是**写放大**（67 倍），**不是引擎效率**——
按字节带宽算，SQLite 反而是我们的 6.7 倍（159.5 MB/s vs 23.9 MB/s）。

**结论：逐行写这一档两边 WAL 粒度不同（行 vs 页），永远不能作为引擎性能对比，
只能作为「写放大 / 磁盘磨损」的对比。** 真正对等的是「一次提交 N 行」（43.0 vs 41.2 B/行，
差 4.4%），那一档我方领先 **2.27×**。

仪器：`tools/bench-vs-sqlite/src/bin/walbytes.rs`（SQLite 侧字节量）、
`spike-bench` 的 `put_sync_wal_bytes` / `put_batch_wal_bytes`（我方，取 `Wal.total_written`，
跨 WAL 轮换累计 —— 用 `Wal.written` 会在中途段 flush 后归零，读出偏小的假数）。
详见 `docs/架构设计.md` §16.1.36 与 `docs/决策记录.md` 七十九。

## 抖动量具：`tools/variance-report.ps1`（2026-11-01 起）

「现在抖动大不大」不许凭感觉答。量具口径：

- 每个指标按 `(a+b)/2` 取每轮的值（与 `abba-verdict.ps1` 同定义），再算**轮间 max/min**；
  `1.00` = 三轮完全相同，`1.30` = 最慢那轮比最快那轮慢 30%。
- 同时打印 `median-spread` 与 `spread>=1.15 / >=1.30` 的计数。

**2026-11-01 `p18` 实测（3 轮）**：

| 侧 | 指标数 | 中位 spread | ≥1.15 | ≥1.30 |
|---|---|---|---|---|
| 我方 | 160 | **1.122** | 70 | 27 |
| SQLite | 43 | **1.103** | 18 | 10 |

对照 `p17`（1.155 / 1.151）略好，但**并没有"抖动不大"**。分档看：

| 类别 | 成对比值 spread（p18） | 结论 |
|---|---|---|
| 点查 / SQL 读 | `get` 1.019、`sql_each` 1.066、`sql_agg_full` 1.076、`sql_get` 1.134、`sql_group_by` 1.148 | 稳，3 轮足够 |
| 扫描 / 删除 | `scan` 1.338、`del_100k` 1.370 | 偏抖 |
| 写 / 并发写 | `big_put` 1.763、`conc_put_4t` 1.766、`put_batch` 1.873 | 明显抖 |

所以两条纪律：① **写类指标不许单轮定论**；② 3 轮判「全胜」时看的是**最小比值是否 >1**，
不是中位数好看就行。最抖的 `cm_ms`（4.78×）与 `big_put_phases`（2.79×）都是内部阶段计时，
量级小、只用于定位，不参与对外结论。

## 读基准的额外要求：结果集必须逐组对得上（2026-11-01 起）

写指标看字节量，**读指标看结果**。聚合 / GROUP BY 这类「把 N 行压成 M 行」的查询，
如果两边分组语义有偏差（NULL 是否计入、整数/浮点混算、MIN/MAX 忽略 NULL 的规则），
吞吐再接近也没有意义。所以：

- 两侧同一条 SQL、同一张逻辑表（1,000,000 行：`id` 0..n−1、`g = id % 100000`、`x = id % 1000`），
  物理形态各自最优（我方每表一个目录 / SQLite 独立库文件 `bench-agg.db`）；
- **两侧都把结果集全部取出来算一个 digest**：`Σ(count × 1000003 + sum)`，
  以及 `sql_agg_cnt` / `sql_agg_sum` / `sql_agg_minmax` 三行单值；
  这些是确定性指标，**必须逐项相等**才允许把吞吐写进对比表（实测 `p18`：全部一致）；
- **同时报 `agg_disk_bytes`（每行落盘字节）**：读基准里「读得少」是真实优势，
  但不能混进「引擎更快」里 —— 我方 33.76 B/行 vs SQLite 侧由 CSV 实测值给出；
- 指标：`sql_group_by`（10 万组，单位「行/秒」= 扫描行数 ÷ 耗时）、
  `sql_agg_full`（全表 COUNT/SUM/MIN/MAX，1 行结果）。

## 索引基准的额外要求：投影列必须两侧都「回表」（2026-11-01 起）

`sql_index_eq`（5000 次 `WHERE g = ?` 等值点查）必须 **`SELECT x`**，不能 `SELECT id`：

| 投影 | SQLite 走什么 | 我们走什么 | 单跑结果 |
|---|---|---|---|
| `SELECT id` | **覆盖索引**（索引项里含 rowid，只读索引） | 索引 seek + **回表** | 152,790 vs 63,048 = **0.41×** |
| `SELECT x` | 索引 seek + **回表** | 索引 seek + **回表** | 20,575 vs 73,703 = **3.58×** |

同一个实现、同一条 SQL，只换一个投影就反转结论——所以 `x`（既非索引列也非主键）是**口径的一部分**，
不是随手选的列名。`sql_index_eq_readrows`（我方走索引时主表扫描行数）必须恒为 `0`。

`sql_index_build`（建索引耗时）是**一次性**指标：两侧自身波动都很大（SQLite 374–744 ms / 3 轮），
只用于给「谁更慢」的方向性结论，**不要拿它抠倍数**。

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

## 轮次质量判定（2026-11-01 起，硬性）

写路径有两类偶发抖动（`docs/审计-2026-11-01-第八轮.md` §3.6）：

| 类型 | 判据 | 能不能改代码解决 |
|---|---|---|
| **A 长窗口（环境级）** | 裸写探针也崩（实测 339 → 27 MB/s） | **不能**（基准把机器写饱和后触发写回阻塞，读走页缓存不受影响） |
| **B 短脉冲（我方更敏感）** | 裸写探针正常，引擎写掉 2–4× | 部分能（我方操作次数多，撞上瞬时停顿概率高） |

**任何引用某批次结论之前，必须先跑轮次质量判定**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\round-quality.ps1 `
    -ZigGlob 'zig-<日期>-<批次>-run*.csv'
```

它把每轮的 `bare_write`/`bare_write2`/`bare_write3`（环境对照）与
`put`/`sql_put`/`big_put`/`b8_put`（引擎写）对本批中位数归一化，输出 `OK` / `A(env)` / `B(pulse)`。
没有裸写探针的老批次标 `?(no-bare)` —— **只标记、不归因**（A 与 B 无法区分，不许猜）。

> **报告纪律**：被判为 A/B 的轮次**必须在报告里列出原始值并说明剔除理由**；
> 只发布剔除之后的中位数等于造假。原始 CSV 一律保留，不复用旧名。

### 时间轴（`t_sec`）

`spike-bench` 输出 `t_sec,<名称>,<距进程启动秒数>`，用于判断坏轮次是**固定时刻**（可调节奏避开）
还是**随机时刻**（只能多轮 + 好坏窗口分离）。采样点：`after_put`、`after_sql_put`、
`after_conc`、`after_big_put`、`after_b8_put`、`end`。

## ABBA 跑法（2026-11-01 起，vs-SQLite 正式结论唯一跑法）

**旧顺序跑法有窗口偏差**：`round = [我方 18–30s] → [SQLite 25s]`，两个引擎永远不在同一时间窗口采样，
而写抖动可持续数十秒 —— 实测 `fbsize` r6 我方裸写 8s 时已从 339 掉到 27 MB/s，SQLite 是 30s 之后的另一个窗口。
判据详见 `docs/架构设计.md` §16.1.33。

```powershell
# 1) 官方对比用 lite（跳过 strong/fb32/fb64/walab，单轮写入量 ~2.5GB -> ~1.0GB）
cd spike-zig; zig build -Doptimize=ReleaseFast -Dlite=true

# 2) ABBA：一轮内 zig,sqlite,sqlite,zig（偶数轮反向）
powershell -File tools\run-abba.ps1 -Date <日期> -Tag <标签> -Rounds 5

# 3) 判定：每引擎两样本取中位 -> 配对比值
powershell -File tools\abba-verdict.ps1 -Tag <标签> -Date <日期>
```

**对等口径**：每条指标都要能回答「两边做的工作是否相同」。反例：`scan_refs`（收集 20 万条）
曾配对 `scan_big`（只推进游标）→ 假的 0.702× 全输；补 `scan_big_collect`（同样收集、
`get_ref` 不复制 payload）后变为 **1.197× 全胜**。

| 批次 | 用途 |
|---|---|
| `zig|sqlite-2026-11-01-p13-run{1..5}-{a,b}.csv` | **正式结论批次**：18 全胜 / 0 落后 / 1 持平 |
| `zig|sqlite-2026-11-01-p12-run{1..5}-{a,b}.csv` | 第一版 ABBA，**对等口径修正前**，只留档不得引用 |




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
| `zig/sqlite-2026-11-01-p20` | **二级索引首次实测**（3 轮 ABBA）：`sql_index_eq` **3.025×**（3/3）、索引落盘大 1.30×、**`sql_index_build` 0.633×（落后，如实列出）**；全批 26 胜 / 1 负 / 2 未决；digest `25,379,000` 三轮两侧全同、`readrows` 恒 0；中位 spread 1.106 / 1.143 |
| `zig/sqlite-2026-11-01-p19` | **HAVING + top-N 首次实测**（3 轮 ABBA）：`sql_having_top10` 1.769×；全批 27 胜 / 0 负 / 0 未决；中位 spread 1.056（我方）/ 1.082（SQLite），比 p18 的 1.122/1.103 更稳 |
| `zig/sqlite-2026-11-01-p18` | **SQL 聚合 / GROUP BY 首次实测**（3 轮 ABBA）：`sql_group_by` 1.547×、`sql_agg_full` 1.306×；全批 26 胜 / 0 负 / **0 未决**；两侧 digest 与单值校验项全部相等；落盘 33.76 vs 14.62 B/行（我方多 2.31×） |
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
