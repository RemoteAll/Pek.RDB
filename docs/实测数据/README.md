# 实测数据（原始记录 + 生成表格）

本目录只放**实测产物**，不放估算值。文档里的对比数字必须能在这里找到出处。

## 文件命名

| 文件 | 含义 |
|---|---|
| `zig-<日期>-run<N>.csv` | `spike-zig/zig-out/bin/spike-bench.exe` 的原始 stderr（每行 `metric,count,value`） |
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
```

## 纪律（硬性）

1. **禁止手填数字**：对比表只能是 `tools/compare-bench.ps1` 的输出。
2. **禁止单轮下结论**：至少三轮，看中位与 min–max。这台机器上 SQLite 逐行写实测 16K–40K 行/s（2.4× 波动），
   单轮会给出完全相反的结论。
3. **禁止沿用旧数字**：换轮次就重新跑；旧轮次文件保留（可追溯），但文档只引用最新一期。
4. **异常先查环境**：曾出现 `sql_put` 单轮掉到 1/10（后台编译/杀毒干扰），`git stash` A/B 证明与代码无关。
   反常数据先看机器负载，别急着改代码。
