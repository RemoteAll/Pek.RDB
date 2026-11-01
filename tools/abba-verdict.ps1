# ABBA verdict: paired comparison that is robust to intermittent write stalls.
#
# See tools/run-abba.ps1 for why ABBA ordering is required.
#
# Per round each engine has TWO samples (a, b). We take the median of the two
# (for throughput: mean of two; for latency-like: also mean) and then the paired
# ratio. A single bad window therefore cannot decide a metric - it would have to
# hit both halves.
#
# ASCII-only on purpose (PowerShell 5.1 reads BOM-less scripts as ANSI).

param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [string]$Tag = 'abba',
    [string]$DataDir = '',
    [double]$MinWins = 0.999
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

# Metric pairs: zig name, sqlite name, higher-is-better
$pairs = @(
    @('put', 'put', $true),
    @('put_batch', 'put_txn', $true),
    @('get', 'get', $true),
    @('scan', 'scan_v', $true),
    @('count_10k', 'scan_big', $true),
    # scan_refs 会「收集」命中记录（20 万 × 48B），旧配对用的是 scan_big（只推进游标、
    # 一条不收）——那是不对等口径（曾因此得出假的 0.70x）。现改为 SQLite 也收集的 scan_big_collect。
    @('scan_refs', 'scan_big_collect', $true),
    @('sql_put', 'put_txn', $true),
    @('sql_get', 'sql_get', $true),
    @('sql_full', 'sql_full', $true),
    @('sql_full_touch', 'sql_full_touch', $true),
    @('conc_put_1t', 'conc_put_1t_txn', $true),
    @('conc_put_2t', 'conc_put_2t_txn', $true),
    @('conc_put_4t', 'conc_put_4t_txn', $true),
    @('big_put', 'big_put_txn', $true),
    @('big_get', 'big_get', $true),
    @('big_count', 'big_count', $true),
    @('big_count_range', 'big_count_range', $true),
    @('upd_random', 'upd_random_txn', $true),
    @('upd_get', 'upd_get', $true),
    @('recover', 'recover', $false),
    @('big_recover', 'big_recover', $false)
)

function Read-Metric([string]$path, [string]$name) {
    if (-not (Test-Path $path)) { return $null }
    $line = Get-Content $path -Encoding UTF8 |
        Where-Object { $_ -match ('^' + [regex]::Escape($name) + ',') } |
        Select-Object -First 1
    if (-not $line) { return $null }
    $p = $line -split ','
    if ($p.Count -lt 3) { return $null }
    $v = 0.0
    if (-not [double]::TryParse($p[2], [ref]$v)) { return $null }
    if ($v -le 0) { return $null }
    return $v
}

function Get-Mid([double[]]$v) {
    if (-not $v -or $v.Count -eq 0) { return $null }
    if ($v.Count -eq 1) { return $v[0] }
    $s = @($v | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return $s[($n - 1) / 2] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}

# Collect per-round, per-engine medians
$rounds = @()
for ($r = 1; $r -le 200; $r++) {
    $za = Join-Path $DataDir "zig-$Date-$Tag-run$r-a.csv"
    $zb = Join-Path $DataDir "zig-$Date-$Tag-run$r-b.csv"
    if (-not (Test-Path $za) -and -not (Test-Path $zb)) { break }
    $rounds += , @{ r = $r; za = $za; zb = $zb
        sa = (Join-Path $DataDir "sqlite-$Date-$Tag-run$r-a.csv")
        sb = (Join-Path $DataDir "sqlite-$Date-$Tag-run$r-b.csv") }
}

if ($rounds.Count -eq 0) { Write-Host "no rounds found for tag '$Tag' date '$Date'"; exit 1 }

Write-Host "ABBA rounds = $($rounds.Count) (each engine sampled twice per round)"
Write-Host ''
Write-Host ('Metric'.PadRight(18) + 'Median'.PadLeft(10) + 'Min'.PadLeft(10) + 'Max'.PadLeft(10) + '  Wins  Verdict')
Write-Host ('------'.PadRight(18) + '------'.PadLeft(10) + '---'.PadLeft(10) + '---'.PadLeft(10) + '  ----  -------')

$ahead = 0; $behind = 0; $unres = 0
$behindList = @()
foreach ($p in $pairs) {
    $zm = $p[0]; $sm = $p[1]; $hib = $p[2]
    $ratios = @()
    foreach ($rd in $rounds) {
        $z = Get-Mid @((Read-Metric $rd.za $zm), (Read-Metric $rd.zb $zm) | Where-Object { $null -ne $_ })
        $s = Get-Mid @((Read-Metric $rd.sa $sm), (Read-Metric $rd.sb $sm) | Where-Object { $null -ne $_ })
        if ($null -eq $z -or $null -eq $s -or $s -eq 0) { continue }
        # normalise so >1 always means "we are better"
        if ($hib) { $ratios += ($z / $s) } else { $ratios += ($s / $z) }
    }
    if ($ratios.Count -eq 0) { continue }
    $srt = @($ratios | Sort-Object)
    $med = Get-Mid $ratios
    $wins = @($ratios | Where-Object { $_ -gt 1 }).Count
    $n = $ratios.Count
    $verdict = 'UNRESOLVED'
    if ($wins -eq $n) { $verdict = 'ALWAYS AHEAD'; $ahead++ }
    elseif ($wins -eq 0) { $verdict = 'ALWAYS BEHIND'; $behind++; $behindList += $zm }
    else { $unres++ }
    Write-Host ($zm.PadRight(18) + ('{0:N3}x' -f $med).PadLeft(10) +
        ('{0:N3}x' -f $srt[0]).PadLeft(10) + ('{0:N3}x' -f $srt[$n - 1]).PadLeft(10) +
        ("  $wins/$n  ") + $verdict)
}

Write-Host ''
Write-Host "always-ahead = $ahead; always-behind = $behind; unresolved = $unres"
if ($behindList.Count -gt 0) { Write-Host ("ALWAYS BEHIND: " + ($behindList -join ', ')) }
