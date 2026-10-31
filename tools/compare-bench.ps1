<#
.SYNOPSIS
    从原始基准 CSV 生成对比表（禁止手填数字）。

.DESCRIPTION
    读取 docs/实测数据/zig-<日期>-run*.csv 与 sqlite-<日期>-run*.csv，
    按指标取中位数与极值，输出 Markdown 表格；并可写入指定文件。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\compare-bench.ps1 -Date 2026-10-31 `
        -OutFile docs\实测数据\对比-2026-10-31.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Date,
    [string]$DataDir,
    [string]$OutFile,
    # 可选：自定义输入 glob（默认 zig-<日期>-run*.csv / sqlite-<日期>-run*.csv）。
    # 同一日期有多批数据时用它分批比对，避免新旧混在一起取中位数失真。
    [string]$ZigGlob,
    [string]$SqliteGlob
)

$ErrorActionPreference = 'Stop'

if (-not $DataDir) {
    $DataDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\实测数据'
}
if (-not (Test-Path $DataDir)) { throw "数据目录不存在：$DataDir" }

function Get-Metrics {
    param([string[]]$Files)
    $acc = @{}
    $used = @()
    foreach ($f in $Files) {
        $used += (Split-Path -Leaf $f)
        foreach ($line in (Get-Content $f -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $p = $line.Trim() -split ','
            if ($p.Count -lt 3) { continue }
            if ($p[0] -notmatch '^[a-z][a-z0-9_]*$') { continue }
            $v = 0.0
            if (-not [double]::TryParse($p[2], [ref]$v)) { continue }
            if (-not $acc.ContainsKey($p[0])) { $acc[$p[0]] = New-Object System.Collections.Generic.List[double] }
            $acc[$p[0]].Add($v)
        }
    }
    $out = @{}
    foreach ($k in $acc.Keys) {
        $s = $acc[$k] | Sort-Object
        $n = $s.Count
        if ($n -eq 0) { continue }
        $med = if ($n % 2 -eq 1) { $s[($n - 1) / 2] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2.0 }
        $out[$k] = [pscustomobject]@{
            Median = $med
            Min    = $s[0]
            Max    = $s[$n - 1]
            N      = $n
        }
    }
    return [pscustomobject]@{ Metrics = $out; Files = $used }
}

if (-not $ZigGlob) { $ZigGlob = "zig-$Date-run*.csv" }
if (-not $SqliteGlob) { $SqliteGlob = "sqlite-$Date-run*.csv" }
$zigFiles = @(Get-ChildItem -Path $DataDir -Filter $ZigGlob | Sort-Object Name | ForEach-Object { $_.FullName })
$sqliteFiles = @(Get-ChildItem -Path $DataDir -Filter $SqliteGlob | Sort-Object Name | ForEach-Object { $_.FullName })
if ($zigFiles.Count -eq 0) { throw "找不到 $ZigGlob（$DataDir）" }
if ($sqliteFiles.Count -eq 0) { throw "找不到 $SqliteGlob（$DataDir）" }

$zig = Get-Metrics -Files $zigFiles
$lite = Get-Metrics -Files $sqliteFiles

# 对比口径：Zig 指标 ←→ SQLite 指标；Higher=吞吐越高越好，$false=延迟越低越好
$pairs = @(
    [pscustomobject]@{ Name = '逐行写（autocommit 口径）'; Zig = 'put';         Lite = 'put';      Unit = '行/s';  Higher = $true },
    [pscustomobject]@{ Name = '单事务批量写';             Zig = 'put_batch';   Lite = 'put_txn';  Unit = '行/s';  Higher = $true },
    [pscustomobject]@{ Name = '主键点查';                 Zig = 'get';         Lite = 'get';      Unit = '次/s';  Higher = $true },
    [pscustomobject]@{ Name = '范围扫描（含值）';         Zig = 'scan';        Lite = 'scan_v';   Unit = '行/s';  Higher = $true },
    [pscustomobject]@{ Name = '范围扫描（仅 key）';       Zig = 'scan_refs';   Lite = 'scan';     Unit = '行/s';  Higher = $true },
    [pscustomobject]@{ Name = 'SQL 层插入';               Zig = 'sql_put';     Lite = 'put_txn';  Unit = '行/s';  Higher = $true },
    [pscustomobject]@{ Name = 'SQL 层点查';               Zig = 'sql_get';     Lite = 'get';      Unit = '次/s';  Higher = $true },
    [pscustomobject]@{ Name = '冷重开（1M 行）';          Zig = 'recover';     Lite = 'recover';  Unit = 'ms';    Higher = $false },
    # 并发写（跨表并行；SQLite 侧每线程独立库文件）
    [pscustomobject]@{ Name = '并发写 1 线程（vs SQLite 事务）'; Zig = 'conc_put_1t'; Lite = 'conc_put_1t_txn'; Unit = '行/s'; Higher = $true },
    [pscustomobject]@{ Name = '并发写 2 线程（vs SQLite 事务）'; Zig = 'conc_put_2t'; Lite = 'conc_put_2t_txn'; Unit = '行/s'; Higher = $true },
    [pscustomobject]@{ Name = '并发写 4 线程（vs SQLite 事务）'; Zig = 'conc_put_4t'; Lite = 'conc_put_4t_txn'; Unit = '行/s'; Higher = $true },
    [pscustomobject]@{ Name = '并发写 4 线程（vs SQLite 逐行 auto）'; Zig = 'conc_put_4t'; Lite = 'conc_put_4t_auto'; Unit = '行/s'; Higher = $true },
    # 超内存数据集（200 万行）
    [pscustomobject]@{ Name = '超内存写 200 万行';        Zig = 'big_put';        Lite = 'big_put_txn'; Unit = '行/s'; Higher = $true },
    [pscustomobject]@{ Name = '超内存点查';               Zig = 'big_get';        Lite = 'big_get';     Unit = '次/s'; Higher = $true },
    [pscustomobject]@{ Name = '超内存范围扫描（仅 key）'; Zig = 'big_scan_refs';  Lite = 'big_scan';    Unit = '行/s'; Higher = $true },
    [pscustomobject]@{ Name = '超内存冷重开';             Zig = 'big_recover';    Lite = 'big_recover'; Unit = 'ms';   Higher = $false }
)

function Format-Num {
    param([double]$v, [string]$unit)
    if ($unit -eq 'ms') { return ('{0:N2}' -f $v) }
    return ('{0:N0}' -f $v)
}

$sb = New-Object System.Text.StringBuilder
function Add-Line { param([string]$s) [void]$sb.AppendLine($s) }

Add-Line "# 实测对比（$Date）"
Add-Line ''
Add-Line '> 本文件由 `tools/compare-bench.ps1` 从原始 CSV **自动生成**，请勿手改数字。'
Add-Line '> 口径：同机、单线程、1,000,000 行 × 32 B 值；SQLite 为 `journal_mode=WAL` + `synchronous=NORMAL`。'
Add-Line ''
Add-Line '原始数据：'
foreach ($f in $zig.Files) { Add-Line "- ``$f``" }
foreach ($f in $lite.Files) { Add-Line "- ``$f``" }
Add-Line ''
Add-Line '| 指标 | Pek.RDB 中位 | 区间（min–max） | SQLite 中位 | 区间（min–max） | 比值 |'
Add-Line '|---|---|---|---|---|---|'

foreach ($p in $pairs) {
    $z = $zig.Metrics[$p.Zig]
    $l = $lite.Metrics[$p.Lite]
    if (-not $z) { Add-Line ("| {0} | 未采到 | - | - | - | - |" -f $p.Name); continue }
    if (-not $l) { Add-Line ("| {0} | {1} {2} | {3}–{4} | 未采到 | - | - |" -f $p.Name, (Format-Num $z.Median $p.Unit), $p.Unit, (Format-Num $z.Min $p.Unit), (Format-Num $z.Max $p.Unit)); continue }
    $ratio = if ($l.Median -gt 0) { $z.Median / $l.Median } else { 0 }
    $ratioTxt = if ($p.Higher) { '{0:N2}×' -f $ratio } else { '{0:N2}×（越低越好）' -f $ratio }
    Add-Line ("| {0} | {1} {2} | {3}–{4} | {5} {2} | {6}–{7} | {8} |" -f `
        $p.Name, (Format-Num $z.Median $p.Unit), $p.Unit, (Format-Num $z.Min $p.Unit), (Format-Num $z.Max $p.Unit), `
        (Format-Num $l.Median $p.Unit), (Format-Num $l.Min $p.Unit), (Format-Num $l.Max $p.Unit), $ratioTxt)
}

Add-Line ''
Add-Line '## 本轮独有指标（无对照）'
Add-Line ''
Add-Line '| 指标 | 中位 | 区间（min–max） |'
Add-Line '|---|---|---|'
foreach ($k in @('scan_refs_multi', 'flush')) {
    $m = $zig.Metrics[$k]
    if ($m) { Add-Line ("| {0} | {1:N0} | {2:N0}–{3:N0} |" -f $k, $m.Median, $m.Min, $m.Max) }
}

Add-Line ''
Add-Line '## 说明'
Add-Line ''
Add-Line '- `scan_refs` / `scan` 为“仅取 key、零拷贝”，`scan` / `scan_v` 为“取值并解码”。'
Add-Line '- `recover` 单位为毫秒，越低越好；其余为越高越好。'
Add-Line '- SQLite 的 `put`（逐行 autocommit）在 Windows + WAL 下波动极大（本轮 min–max 已列出），比较时以中位为准。'

$text = $sb.ToString()
if ($OutFile) {
    $full = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Split-Path -Parent $PSScriptRoot) $OutFile }
    $dir = Split-Path -Parent $full
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已写入 $full"
}
$text
