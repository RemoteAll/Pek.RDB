param(
    # Which batch to compare. Defaults to the historical 'full' batch.
    # NOTE: passing these is MANDATORY when you just measured a new batch --
    # a missing parameter used to silently fall back to 'full' and report
    # stale numbers as if they were the new ones.
    [string]$ZigGlob = 'zig-2026-11-01-full-run*.csv',
    [string]$SqliteGlob = 'sqlite-2026-11-01-full-run*.csv'
)
# Verdict helper: per-metric overlap check between Pek.RDB and SQLite min-max ranges.
# Project rule: overlapping intervals => cannot conclude ("indistinguishable").
# NOTE: keep this file ASCII-only. PowerShell 5.1 reads BOM-less .ps1 as ANSI,
#       so any CJK literal here would be mangled and break parsing.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root 'docs'
$zf = @(Get-ChildItem -Path $dir -Recurse -Filter $ZigGlob -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
$sf = @(Get-ChildItem -Path $dir -Recurse -Filter $SqliteGlob -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
if ($zf.Count -eq 0) { throw "zig csv not found: $ZigGlob" }
if ($sf.Count -eq 0) { throw "sqlite csv not found: $SqliteGlob" }
Write-Output "zig=$($zf.Count) file(s)  sqlite=$($sf.Count) file(s)"

function Get-Triple {
    param([string[]]$Files, [string]$Key)
    $v = @()
    foreach ($f in $Files) {
        foreach ($l in Get-Content $f -Encoding UTF8) {
            $p = $l.Trim() -split ','
            if ($p.Count -ge 3 -and $p[0] -eq $Key) {
                $d = 0.0
                if ([double]::TryParse($p[2], [ref]$d)) { $v += $d }
            }
        }
    }
    if ($v.Count -eq 0) { return $null }
    $s = @($v | Sort-Object)
    $n = $s.Count
    $med = if ($n % 2 -eq 1) { $s[($n - 1) / 2] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2.0 }
    return @($s[0], $med, $s[$n - 1])
}

$pairs = @(
    @('put', 'put', 'write_row', $true),
    @('put_batch', 'put_txn', 'write_txn', $true),
    @('get', 'get', 'point_get', $true),
    @('scan_full', 'scan_v_big', 'range_v_200k', $true),
    @('count_range', 'scan_big', 'range_k_200k', $true),
    @('sql_put', 'put_txn', 'sql_insert', $true),
    @('sql_get', 'get', 'sql_get', $true),
    @('sql_full', 'sql_full', 'sql_full_mat', $true),
    @('sql_each', 'sql_full_touch', 'sql_full_decode', $true),
    @('recover', 'recover', 'recover_1m', $false),
    @('conc_put_1t', 'conc_put_1t_txn', 'conc1', $true),
    @('conc_put_2t', 'conc_put_2t_txn', 'conc2', $true),
    @('conc_put_4t', 'conc_put_4t_txn', 'conc4', $true),
    @('big_put', 'big_put_txn', 'big_write', $true),
    @('big_get', 'big_get', 'big_get', $true),
    @('big_count_range', 'big_count_range', 'big_range_k', $true),
    @('big_count', 'big_count', 'big_full', $true),
    @('big_recover', 'big_recover_open', 'big_recover_ms', $false),
    @('upd_random', 'upd_random_txn', 'upd_random', $true),
    @('upd_get', 'upd_get', 'upd_get', $true),
    # Equal-work scan pairs: both sides only advance a cursor and count rows.
    # (`scan_refs` / `big_scan_refs` collect RefRecord = 48 B/row and are therefore
    #  NOT comparable to sqlite's SELECT-and-count; they are listed separately below.)
    @('count_10k', 'scan', 'scan_10k_count', $true),
    @('big_count_10k', 'big_scan', 'big_scan_10k_count', $true),
    @('scan_refs', 'scan', 'arch_scan_refs', $true, 'UNEQUAL'),
    @('big_scan_refs', 'big_scan', 'arch_big_scan_refs', $true, 'UNEQUAL')
)

$rows = @()
foreach ($p in $pairs) {
    $higher = $p[3]
    $noteq = ($p.Count -ge 5 -and $p[4] -eq 'UNEQUAL')
    $z = Get-Triple -Files $zf -Key $p[0]
    $l = Get-Triple -Files $sf -Key $p[1]
    if ($null -eq $z -or $null -eq $l) { Write-Output ("{0}: missing" -f $p[2]); continue }
    $overlap = -not (($z[0] -gt $l[2]) -or ($l[0] -gt $z[2]))
    $ratio = $z[1] / $l[1]
    # For "lower is better" metrics (ms), ratio < 1 means we are faster.
    $behind = if ($higher) { $ratio -lt 1.0 } else { $ratio -gt 1.0 }
    if ($noteq) { $behind = $false }
    $verdict = if ($noteq) { 'UNEQUAL' } elseif ($overlap) { 'OVERLAP' } else { 'DECIDABLE' }
    $rows += [pscustomobject]@{
        Metric  = $p[2]
        ZigMed  = '{0:N0}' -f $z[1]
        ZigRng  = '{0:N0}-{1:N0}' -f $z[0], $z[2]
        LiteMed = '{0:N0}' -f $l[1]
        LiteRng = '{0:N0}-{1:N0}' -f $l[0], $l[2]
        Ratio   = '{0:N2}x' -f $ratio
        Verdict = $verdict
        Behind  = $behind
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 200

$dec = @($rows | Where-Object { $_.Verdict -eq 'DECIDABLE' })
$behind = @($dec | Where-Object { $_.Behind })
$ov = @($rows | Where-Object { $_.Verdict -eq 'OVERLAP' })
$ue = @($rows | Where-Object { $_.Verdict -eq 'UNEQUAL' })
"decidable = {0} / {1}; overlap = {2}; decidable-and-behind = {3}; unequal-work = {4}" -f $dec.Count, $rows.Count, $ov.Count, $behind.Count, $ue.Count
foreach ($x in $behind) { "  BEHIND: {0} {1}" -f $x.Metric, $x.Ratio }
foreach ($x in $ov) { "  OVERLAP: {0} {1}" -f $x.Metric, $x.Ratio }
foreach ($x in $ue) { "  UNEQUAL: {0} {1} (not counted)" -f $x.Metric, $x.Ratio }
