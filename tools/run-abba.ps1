# ABBA interleaved runner for the Pek.RDB vs SQLite comparison.
#
# WHY ABBA
#   The old runner did:  round = [our full bench ~18s] then [SQLite full bench ~25s].
#   That means the two engines NEVER sample the same time window. The machine has
#   intermittent write stalls lasting tens of seconds (see
#   docs/audit-2026-11-01-round8.md and docs/juece section 73-74); with a
#   sequential runner a stall can land entirely on us or entirely on SQLite, and
#   the paired ratio then measures the window, not the engines.
#   Evidence: fbsize r6 - our bare-write probe fell 339 -> 27 MB/s while SQLite,
#   which ran ~30s later, was completely normal. "SQLite was fine in the same
#   round" was therefore never valid evidence.
#
#   ABBA fixes it: within one round each engine runs TWICE, once in each half,
#   so a stall hits both. Analysing with median-of-2 per engine per round makes
#   the ratio robust to a single bad window.
#
# USAGE
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-abba.ps1 `
#       -Date 2026-11-01 -Tag p12 -Rounds 5
#
# NOTE: ASCII-only on purpose. PowerShell 5.1 reads BOM-less scripts as ANSI,
# so CJK literals would be mangled and break parsing.

param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [string]$Tag = 'abba',
    [int]$Rounds = 5,
    [string]$DataDir = '',
    [string]$ZigExe = '',
    [string]$SqliteExe = 'D:\cargo-target\pek-rdb-tools\release\bench-vs-sqlite.exe'
)

$root = Split-Path $PSScriptRoot -Parent

if (-not $DataDir) {
    $docs = Join-Path $root 'docs'
    $cand = Get-ChildItem -Path $docs -Directory -ErrorAction SilentlyContinue |
        Where-Object { Get-ChildItem -Path $_.FullName -Filter '*.csv' -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $cand) { Write-Host "cannot locate CSV data dir; pass -DataDir"; exit 1 }
    $DataDir = $cand.FullName
}

if (-not $ZigExe) { $ZigExe = Join-Path $root 'spike-zig\zig-out\bin\spike-bench.exe' }
if (-not (Test-Path $ZigExe)) { Write-Host "missing zig bench: $ZigExe"; exit 1 }
if (-not (Test-Path $SqliteExe)) { Write-Host "missing sqlite bench: $SqliteExe"; exit 1 }

$sqliteWd = Join-Path $root 'tools\bench-vs-sqlite'

function Run-Zig([string]$out) {
    $p = Start-Process $ZigExe -RedirectStandardError $out `
        -RedirectStandardOutput (Join-Path $env:TEMP 'abba-zig-out.txt') -PassThru -NoNewWindow
    $p.WaitForExit()
}

function Run-Sqlite([string]$out) {
    $p = Start-Process $SqliteExe -WorkingDirectory $sqliteWd -RedirectStandardOutput $out `
        -RedirectStandardError (Join-Path $env:TEMP 'abba-sqlite-err.txt') -PassThru -NoNewWindow
    $p.WaitForExit()
}

for ($r = 1; $r -le $Rounds; $r++) {
    $za = Join-Path $DataDir "zig-$Date-$Tag-run$r-a.csv"
    $zb = Join-Path $DataDir "zig-$Date-$Tag-run$r-b.csv"
    $sa = Join-Path $DataDir "sqlite-$Date-$Tag-run$r-a.csv"
    $sb = Join-Path $DataDir "sqlite-$Date-$Tag-run$r-b.csv"

    if ($r % 2 -eq 1) {
        # A B B A
        Run-Zig $za; Run-Sqlite $sa; Run-Sqlite $sb; Run-Zig $zb
    } else {
        # B A A B  (start with SQLite so drift cancels across rounds)
        Run-Sqlite $sa; Run-Zig $za; Run-Zig $zb; Run-Sqlite $sb
    }
    Write-Host "round $r/$Rounds done"
}

Write-Host ''
Write-Host "raw CSVs written to: $DataDir"
Write-Host "analyse with: powershell -File tools\abba-verdict.ps1 -Tag $Tag -Date $Date"
