# Spread / variance report for one ABBA batch.
#
# "Is the noise small now?" must be answered with numbers, not impressions.
# For every metric we take, per side, the per-round value (mean of the a/b samples,
# same definition as tools\abba-verdict.ps1) and compute max/min across rounds.
# A spread of 1.00 means the three rounds were identical; 1.30 means the worst round
# was 30% slower than the best one.
#
# ASCII-only on purpose (PowerShell 5.1 reads BOM-less scripts as ANSI).

param(
    [string]$Date = '2026-11-01',
    [string]$Tag = 'p18',
    [int]$Rounds = 3,
    [string]$DataDir = ''
)

$root = Split-Path $PSScriptRoot -Parent
if (-not $DataDir) {
    $docs = Join-Path $root 'docs'
    $cand = Get-ChildItem -Path $docs -Directory -ErrorAction SilentlyContinue |
        Where-Object { Get-ChildItem -Path $_.FullName -Filter '*.csv' -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $cand) { Write-Host 'cannot locate CSV data dir'; exit 1 }
    $DataDir = $cand.FullName
}

function Read-Metric([string]$path, [string]$name) {
    if (-not (Test-Path $path)) { return $null }
    $line = Get-Content $path -Encoding UTF8 |
        Where-Object { $_ -match ('^' + [regex]::Escape($name) + ',') } | Select-Object -First 1
    if (-not $line) { return $null }
    $p = $line -split ','
    if ($p.Count -lt 3) { return $null }
    $v = 0.0
    if (-not [double]::TryParse($p[2], [ref]$v)) { return $null }
    if ($v -le 0) { return $null }
    return $v
}

function Metric-Names([string]$side) {
    $p = Join-Path $DataDir "$side-$Date-$Tag-run1-a.csv"
    if (-not (Test-Path $p)) { return @() }
    Get-Content $p -Encoding UTF8 | ForEach-Object {
        $f = $_ -split ','
        if ($f.Count -ge 3) { $f[0] }
    } | Sort-Object -Unique
}

function Round-Means([string]$side, [string]$metric) {
    $out = @()
    for ($r = 1; $r -le $Rounds; $r++) {
        $a = Read-Metric (Join-Path $DataDir "$side-$Date-$Tag-run$r-a.csv") $metric
        $b = Read-Metric (Join-Path $DataDir "$side-$Date-$Tag-run$r-b.csv") $metric
        if ($null -eq $a) { continue }
        if ($null -eq $b) { $b = $a }
        $out += ($a + $b) / 2.0
    }
    return $out
}

function Report([string]$side) {
    $names = Metric-Names $side
    $rows = @()
    foreach ($m in $names) {
        $vals = Round-Means $side $m
        if ($vals.Count -lt 2) { continue }
        $min = ($vals | Measure-Object -Minimum).Minimum
        $max = ($vals | Measure-Object -Maximum).Maximum
        if ($min -le 0) { continue }
        $rows += [pscustomobject]@{
            metric = $m
            spread = [math]::Round($max / $min, 3)
            min    = [math]::Round($min, 1)
            max    = [math]::Round($max, 1)
            n      = $vals.Count
        }
    }
    Write-Host "== $side =="
    $rows | Sort-Object -Property spread -Descending | Select-Object -First 12 |
        ForEach-Object { "  {0,-28} spread={1,5}  min={2,12}  max={3,12}  rounds={4}" -f $_.metric, $_.spread, $_.min, $_.max, $_.n }
    $med = ($rows | ForEach-Object { $_.spread } | Sort-Object)
    if ($med.Count -gt 0) {
        $mid = $med[[int][math]::Floor($med.Count / 2)]
        $over15 = ($rows | Where-Object { $_.spread -ge 1.15 }).Count
        $over30 = ($rows | Where-Object { $_.spread -ge 1.30 }).Count
        Write-Host ("  metrics={0}  median-spread={1}  spread>=1.15: {2}  spread>=1.30: {3}" -f $rows.Count, $mid, $over15, $over30)
    }
    Write-Host ''
}

Report 'zig'
Report 'sqlite'
