# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
# Scale-level ABBA runner: alternates Zig engine and SQLite at the same row count,
# so the two engines see the same machine/file-cache state within a round.
#
# Why not compare against "last time's SQLite numbers": an earlier SQLite run on the
# same box measured 90,390/s cold-get while a later one measured 39,855/s - a 2.3x
# swing caused purely by OS file cache state, NOT by code. Cross-batch ratios are traps.
#
# Order per round alternates (A,B then B,A) so "who ran first / who got the cold cache"
# bias cancels out over two rounds.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-scale-abba.ps1 -Rows 100000000 -Tag s1 -Rounds 2
param(
    [long]$Rows = 100000000,
    [string]$Date = '2026-11-02',
    [string]$Tag = 's1',
    [int]$Rounds = 2,
    # Zig side durability tier. $false = commit returns after the WAL reaches the OS
    # (equivalent to SQLite synchronous=NORMAL, which is what the SQLite side uses),
    # $true = fsync before returning (stricter than SQLite NORMAL: only fair if the
    # SQLite side is run with synchronous=FULL too).
    [switch]$Durable,
    # SQLite durability tier: NORMAL (no fsync per commit) or FULL (fsync per commit).
    # Pair it with -Durable: same tier on both sides, otherwise the write ratio is meaningless.
    [ValidateSet('NORMAL', 'FULL')]
    [string]$SqliteSync = 'NORMAL'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'docs\实测数据'
$zigDir = Join-Path $root 'spike-zig'
$sqliteExe = 'D:\cargo-target\pek-rdb-tools\release\scale.exe'
if (-not (Test-Path $sqliteExe)) { throw "missing sqlite scale binary: $sqliteExe (build with: cd tools\bench-vs-sqlite; cargo build --release --bin scale)" }

# NOTE: the round parameter must NOT be named $tag - PowerShell variable names are
# case-insensitive, so `param([string]$tag)` shadows the script-level `$Tag` and the
# output file name silently loses the tag (two tiers then overwrite each other's CSVs).
function Run-Zig([string]$round) {
    $out = Join-Path $outDir ("规模-$Date-$Tag-z{0}.csv" -f $round)
    $t0 = Get-Date
    # Native-command stderr must NOT go through PowerShell's pipeline: PS 5.1 wraps every
    # stderr line in an ErrorRecord ("zig : scale_put,...") and `$ErrorActionPreference='Stop'`
    # then aborts, and the prefix also breaks `^scale_` matching. Redirect to files instead.
    $so = [System.IO.Path]::GetTempFileName()
    $se = [System.IO.Path]::GetTempFileName()
    $dur = if ($Durable) { 'true' } else { 'false' }
    $args = @('build', 'run-scale', '-Doptimize=ReleaseFast', "-Dscale-rows=$Rows", '-Dscale-dir=scale-abba', '-Dscale-data-prefault=0', "-Dscale-durable=$dur")
    $p = Start-Process -FilePath 'zig' -ArgumentList $args -WorkingDirectory $zigDir -NoNewWindow -Wait -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
    $lines = @(@(Get-Content $so -ErrorAction SilentlyContinue) + @(Get-Content $se -ErrorAction SilentlyContinue)) | Where-Object { $_ -match '^scale_' }
    Remove-Item $so, $se -ErrorAction SilentlyContinue
    $lines | Out-File -FilePath $out -Encoding ascii
    if (@($lines).Count -eq 0) { throw "zig scale produced no output (exit=$($p.ExitCode), see $out)" }
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    Write-Host ("[zig {0}] {1}s -> {2}" -f $round, $secs, (Split-Path -Leaf $out))
    return $lines
}

function Run-Sqlite([string]$round) {
    $out = Join-Path $outDir ("sqlite-规模-$Date-$Tag-s{0}.csv" -f $round)
    $db = Join-Path $env:TEMP ("pek-scale-{0}.db" -f $round)
    $t0 = Get-Date
    $so = [System.IO.Path]::GetTempFileName()
    $se = [System.IO.Path]::GetTempFileName()
    $sqliteArgs = @("$Rows", $db)
    if ($SqliteSync -eq 'FULL') { $sqliteArgs += '--full' }
    $p = Start-Process -FilePath $sqliteExe -ArgumentList $sqliteArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
    $lines = @(Get-Content $so -ErrorAction SilentlyContinue) | Where-Object { $_ -match '^sqlite_scale_' }
    Remove-Item $so, $se -ErrorAction SilentlyContinue
    $lines | Out-File -FilePath $out -Encoding ascii
    if (@($lines).Count -eq 0) { throw "sqlite scale produced no output (exit=$($p.ExitCode), see $out)" }
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    Write-Host ("[sqlite {0}] {1}s -> {2}" -f $round, $secs, (Split-Path -Leaf $out))
    return $lines
}

# name -> value from lines of the form "key,count,value".
# Key may be two-part ("scale_reopen_us,prefault_off") because some rows carry a label in
# the count column; without the two-part form the prefault_on rows would match too.
function Get-Val($lines, [string]$key) {
    $parts = $key.Split(',')
    foreach ($l in $lines) {
        $p = $l.Split(',')
        if ($p.Count -ge 3 -and $p[0] -eq $parts[0] -and ($parts.Count -lt 2 -or $p[1] -eq $parts[1])) {
            return [double]$p[2]
        }
    }
    return [double]::NaN
}

$zig = @()
$sq = @()
$sqliteFlag = if ($SqliteSync -eq 'FULL') { '--full' } else { '' }
for ($r = 1; $r -le $Rounds; $r++) {
    if ($r % 2 -eq 1) {
        $zig += ,(Run-Zig "$r")
        $sq += ,(Run-Sqlite "$r")
    } else {
        $sq += ,(Run-Sqlite "$r")
        $zig += ,(Run-Zig "$r")
    }
}

function Median($vals) {
    $s = @($vals | Where-Object { -not [double]::IsNaN($_) } | Sort-Object)
    if ($s.Count -eq 0) { return [double]::NaN }
    if ($s.Count % 2 -eq 1) { return $s[[int](($s.Count - 1) / 2)] }
    return ($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2
}

function Min-Val($vals) {
    $s = @($vals | Where-Object { -not [double]::IsNaN($_) })
    if ($s.Count -eq 0) { return [double]::NaN }
    return ($s | Measure-Object -Minimum).Minimum
}

# metric -> more_is_better; zig key; sqlite key
$specs = @(
    @{ name = 'put';           better = $true;  z = 'scale_put';              s = 'sqlite_scale_put' },
    @{ name = 'scan';          better = $true;  z = 'scale_scan';             s = 'sqlite_scale_scan' },
    @{ name = 'get_cold';      better = $true;  z = 'scale_get_hit';          s = 'sqlite_scale_get_hit' },
    @{ name = 'get_warm';      better = $true;  z = 'scale_get_hit_warm';     s = 'sqlite_scale_get_hit_warm' },
    @{ name = 'get_miss';      better = $true;  z = 'scale_get_miss';         s = 'sqlite_scale_get_miss' },
    @{ name = 'get_cold_p50';  better = $false; z = 'scale_get_hit_p50';      s = 'sqlite_scale_get_hit_p50' },
    @{ name = 'get_cold_p99';  better = $false; z = 'scale_get_hit_p99';      s = 'sqlite_scale_get_hit_p99' },
    @{ name = 'get_warm_p50';  better = $false; z = 'scale_get_hit_warm_p50'; s = 'sqlite_scale_get_hit_warm_p50' },
    @{ name = 'get_warm_p99';  better = $false; z = 'scale_get_hit_warm_p99'; s = 'sqlite_scale_get_hit_warm_p99' },
    @{ name = 'miss_p99';      better = $false; z = 'scale_get_miss_p99';     s = 'sqlite_scale_get_miss_p99' }
)

Write-Host ''
Write-Host ("=== scale ABBA  rows={0}  rounds={1}  zig_durable={2}  sqlite_sync={3} ===" -f $Rows, $Rounds, [bool]$Durable, $SqliteSync)
Write-Host ('{0,-14} {1,14} {2,14} {3,8}' -f 'metric', 'zig', 'sqlite', 'ratio')
$walSync = Median @($zig | ForEach-Object { Get-Val $_ 'scale_wal_sync_ms' })
$putMs = Median @($zig | ForEach-Object { Get-Val $_ 'scale_put_ms' })
if (-not [double]::IsNaN($walSync) -and $putMs -gt 0) {
    Write-Host ('{0,-14} {1,14:N0} {2,14} {3,7:N0}%' -f 'zig_fsync_ms', $walSync, '', (100.0 * $walSync / $putMs))
}
foreach ($sp in $specs) {
    $zv = @($zig | ForEach-Object { Get-Val $_ $sp.z })
    $sv = @($sq | ForEach-Object { Get-Val $_ $sp.s })
    $zm = Median $zv
    $sm = Median $sv
    if ([double]::IsNaN($zm) -or [double]::IsNaN($sm) -or $sm -eq 0) { continue }
    $ratio = $zm / $sm
    Write-Host ('{0,-14} {1,14:N0} {2,14:N0} {3,7:N2}x' -f $sp.name, $zm, $sm, $ratio)
}
# reopen: zig reports alternating prefault_on/off x3 -> take min of prefault_off; sqlite reports open twice
$zro = @($zig | ForEach-Object { Get-Val $_ 'scale_reopen_us,prefault_off' })
$sro = @($sq | ForEach-Object { Get-Val $_ 'sqlite_scale_reopen_us,open' })
Write-Host ('{0,-14} {1,14:N0} {2,14:N0} {3,7:N2}x' -f 'reopen_us', (Min-Val $zro), (Min-Val $sro), ((Min-Val $zro) / (Min-Val $sro)))
