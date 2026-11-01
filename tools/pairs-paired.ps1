param(
    # Paired (interleaved) comparison: round i of zig is measured next to round i of
    # sqlite, so machine drift hits both sides equally.
    # NOTE: keep this file ASCII-only. PowerShell 5.1 reads BOM-less .ps1 as ANSI,
    #       so any CJK literal here would be mangled and break parsing.
    [Parameter(Mandatory = $true)][string]$ZigGlob,
    [Parameter(Mandatory = $true)][string]$SqliteGlob
)
# Per-round ratio + sign test.
#
# Why not min-max overlap: that answers "do the two distributions interleave",
# which with a noisy machine answers "no measurement", not "who is faster".
# Interleaving the two implementations makes drift common-mode, so the per-round
# RATIO is the thing that is actually comparable. Then:
#   - median ratio  = effect size
#   - wins/N        = consistency, judged by an exact two-sided sign test
# With N=7 only 7/7 is significant (p = 2/128 = 0.0156); 6/7 gives p = 0.125.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root 'docs'

function Get-RoundMap {
    param([string]$Glob)
    $m = @{}
    foreach ($f in (Get-ChildItem -Path $dir -Recurse -Filter $Glob -ErrorAction SilentlyContinue)) {
        if ($f.Name -notmatch 'run(\d+)\.csv$') { continue }
        $idx = [int]$Matches[1]
        $vals = @{}
        foreach ($line in (Get-Content $f.FullName -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $p = $line.Trim() -split ','
            if ($p.Count -lt 3) { continue }
            if ($p[0] -notmatch '^[a-z][a-z0-9_]*$') { continue }
            $v = 0.0
            if (-not [double]::TryParse($p[2], [ref]$v)) { continue }
            $vals[$p[0]] = $v
        }
        $m[$idx] = $vals
    }
    return $m
}

$zm = Get-RoundMap -Glob $ZigGlob
$sm = Get-RoundMap -Glob $SqliteGlob
$rounds = @($zm.Keys | Where-Object { $sm.ContainsKey($_) } | Sort-Object)
if ($rounds.Count -lt 3) { throw "need >=3 paired rounds, got $($rounds.Count)" }
Write-Output ("paired rounds = {0} ({1})" -f $rounds.Count, ($rounds -join ','))

# name = display name, z = zig metric, s = sqlite metric, higher-better
$pairs = @(
    @('write_row', 'put', 'put', $true),
    @('write_txn', 'put_batch', 'put_txn', $true),
    @('point_get', 'get', 'get', $true),
    @('range_v_200k', 'scan_full', 'scan_v_big', $true),
    @('range_k_200k', 'count_range', 'scan_big', $true),
    @('sql_insert', 'sql_put', 'put_txn', $true),
    @('sql_get', 'sql_get', 'get', $true),
    @('sql_full_mat', 'sql_full', 'sql_full', $true),
    @('sql_full_decode', 'sql_each', 'sql_full_touch', $true),
    @('recover_1m', 'recover', 'recover', $false),
    @('conc1', 'conc_put_1t', 'conc_put_1t_txn', $true),
    @('conc2', 'conc_put_2t', 'conc_put_2t_txn', $true),
    @('conc4', 'conc_put_4t', 'conc_put_4t_txn', $true),
    @('big_write', 'big_put', 'big_put_txn', $true),
    @('big_get', 'big_get', 'big_get', $true),
    @('big_range_k', 'big_count_range', 'big_count_range', $true),
    @('big_full', 'big_count', 'big_count', $true),
    @('big_recover_ms', 'big_recover', 'big_recover_open', $false),
    @('upd_random', 'upd_random', 'upd_random_txn', $true),
    @('upd_get', 'upd_get', 'upd_get', $true),
    @('scan_10k_count', 'count_10k', 'scan', $true),
    @('big_scan_10k_count', 'big_count_10k', 'big_scan', $true)
)

function Get-Median {
    param([double[]]$v)
    $s = @($v | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return $s[($n - 1) / 2] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2.0
}

$rows = @()
foreach ($p in $pairs) {
    $name = $p[0]; $zk = $p[1]; $sk = $p[2]; $higher = $p[3]
    $ratios = @()
    foreach ($r in $rounds) {
        $zv = $zm[$r]
        $sv = $sm[$r]
        if (-not $zv.ContainsKey($zk) -or -not $sv.ContainsKey($sk)) { continue }
        $a = $zv[$zk]; $b = $sv[$sk]
        if ($b -le 0) { continue }
        # Both directions can end up dividing by zero: our `recover` prints whole ms and can
        # round to 0. Skip that round rather than feeding Infinity/NaN into the median.
        if (-not $higher -and $a -le 0) { continue }
        # normalise so that ratio > 1 always means "we are better"
        if ($higher) { $ratios += ($a / $b) } else { $ratios += ($b / $a) }
    }
    if ($ratios.Count -eq 0) { Write-Output ("{0}: missing" -f $name); continue }
    $med = Get-Median -v $ratios
    $wins = @($ratios | Where-Object { $_ -gt 1.0 }).Count
    $n = $ratios.Count
    $verdict = if ($wins -eq $n) { 'ALWAYS AHEAD' } elseif ($wins -eq 0) { 'ALWAYS BEHIND' } else { 'UNRESOLVED' }
    $rows += [pscustomobject]@{
        Metric  = $name
        Median  = '{0:N3}x' -f $med
        Min     = '{0:N3}x' -f ($ratios | Measure-Object -Minimum).Minimum
        Max     = '{0:N3}x' -f ($ratios | Measure-Object -Maximum).Maximum
        Wins    = '{0}/{1}' -f $wins, $n
        Verdict = $verdict
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 200

$behind = @($rows | Where-Object { $_.Verdict -eq 'ALWAYS BEHIND' })
$unres = @($rows | Where-Object { $_.Verdict -eq 'UNRESOLVED' })
$ahead = @($rows | Where-Object { $_.Verdict -eq 'ALWAYS AHEAD' })
"always-ahead = {0}; always-behind = {1}; unresolved = {2} (of {3})" -f $ahead.Count, $behind.Count, $unres.Count, $rows.Count
foreach ($x in $behind) { "  BEHIND: {0} median {1} wins {2}" -f $x.Metric, $x.Median, $x.Wins }
foreach ($x in $unres) { "  UNRESOLVED: {0} median {1} wins {2}" -f $x.Metric, $x.Median, $x.Wins }
