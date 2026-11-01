# Round-quality classifier for spike-bench batches.
#
# WHY THIS EXISTS
#   The write path has two kinds of intermittent slowdown (see
#   docs/audit-2026-11-01-round8.md / docs/juece section 73):
#     A) long environmental window - the bare-file-write probe ALSO collapses
#        (339 -> 27 MB/s observed), lasting tens of seconds, reads unaffected.
#     B) short pulse - bare probe looks normal but engine writes drop 2-4x.
#   Class A cannot be fixed in code, so the only honest handling is to DETECT
#   the bad rounds, report them explicitly, and exclude them with a stated reason.
#   Reporting only the cleaned-up numbers would be fabrication.
#
# USAGE
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\round-quality.ps1 `
#       -ZigGlob 'zig-2026-11-01-fbsize-run*.csv'
#
# NOTE: this file is intentionally ASCII-only. PowerShell 5.1 reads BOM-less
# scripts as ANSI, so CJK literals would be mangled and break parsing.

param(
    [string]$ZigGlob = 'zig-*.csv',
    [string]$DataDir = '',
    [double]$Threshold = 0.5
)

# The data directory name contains CJK characters and this script must stay
# ASCII-only, so resolve it by pattern: the docs sub-directory that holds CSVs.
if (-not $DataDir) {
    $docs = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs'
    $cand = Get-ChildItem -Path $docs -Directory -ErrorAction SilentlyContinue |
        Where-Object { Get-ChildItem -Path $_.FullName -Filter '*.csv' -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $cand) {
        Write-Host "could not locate the CSV data directory under '$docs'; pass -DataDir"
        exit 1
    }
    $DataDir = $cand.FullName
}

$files = Get-ChildItem -Path $DataDir -Filter $ZigGlob -ErrorAction SilentlyContinue |
    Sort-Object Name
if (-not $files) {
    Write-Host "no files matched '$ZigGlob' under '$DataDir'"
    exit 1
}

function Read-Metric([string]$path, [string]$name) {
    $line = (Get-Content $path -Encoding UTF8 | Where-Object { $_ -match ('^' + [regex]::Escape($name) + ',') } | Select-Object -First 1)
    if (-not $line) { return $null }
    $parts = $line -split ','
    if ($parts.Count -lt 3) { return $null }
    return [double]$parts[2]
}

function Get-Median([double[]]$v) {
    if (-not $v -or $v.Count -eq 0) { return 0 }
    $s = @($v | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return $s[($n - 1) / 2] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}

# Metrics: three bare-write probes (environment control) + four engine writes.
$metrics = @(
    'bare_write_mbps',
    'bare_write2_mbps',
    'bare_write3_mbps',
    'put',
    'sql_put',
    'big_put',
    'b8_put'
)

$data = @{}
foreach ($m in $metrics) {
    $vals = @()
    foreach ($f in $files) {
        $v = Read-Metric $f.FullName $m
        if ($null -ne $v -and $v -gt 0) { $vals += $v }
    }
    $data[$m] = @{ median = (Get-Median $vals); values = $vals }
}

Write-Host ("round  " + (($metrics | ForEach-Object { '{0,10}' -f $_.Replace('bare_write_mbps', 'bare1').Replace('bare_write2_mbps', 'bare2').Replace('bare_write3_mbps', 'bare3').Replace('_mbps', '') }) -join '') + "  class")

$badA = 0
$badB = 0
$idx = 0
foreach ($f in $files) {
    $idx++
    $row = @()
    $bareBad = $false
    $engineBad = $false
    $bareSeen = $false
    foreach ($m in $metrics) {
        $v = Read-Metric $f.FullName $m
        $med = $data[$m].median
        if ($null -eq $v -or $med -le 0) { $row += ('{0,10}' -f 'n/a'); continue }
        $r = $v / $med
        $row += ('{0,10:N2}' -f $r)
        if ($m -like 'bare_write*') { $bareSeen = $true }
        if ($m -like 'bare_write*' -and $r -lt $Threshold) { $bareBad = $true }
        if ($m -notlike 'bare_write*' -and $r -lt $Threshold) { $engineBad = $true }
    }
    $class = 'OK'
    if (-not $bareSeen) {
        # No bare-write probe in this batch: A and B are indistinguishable, so we
        # must NOT claim class B. Say so instead of guessing.
        if ($engineBad) { $class = '?(no-bare)'; $badB++ } else { $class = 'OK' }
    } elseif ($bareBad -and $engineBad) { $class = 'A(env)'; $badA++ }
    elseif ($engineBad) { $class = 'B(pulse)'; $badB++ }
    elseif ($bareBad) { $class = 'A-ish'; $badA++ }
    $label = $f.BaseName
    if ($label.Length -gt 30) { $label = $label.Substring($label.Length - 30) }
    Write-Host ("$($label.PadRight(31))" + ($row -join '') + "  $class")
}

Write-Host ''
Write-Host "files=$($files.Count)  threshold=$Threshold"
Write-Host "class A (bare probe also collapsed, environment): $badA"
Write-Host "class B (engine only, bare probe normal):         $badB"
Write-Host 'class "?(no-bare)" = batch predates the bare-write probe; A and B cannot be'
Write-Host '  distinguished, so the round is flagged but NOT attributed.'
Write-Host ''
Write-Host 'REPORTING RULE: rounds classified A/B must be listed with their raw values'
Write-Host 'and the exclusion reason. Publishing only the surviving median is fabrication.'
