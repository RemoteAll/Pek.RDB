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
    # Same durability tier: we write() each row straight to the OS (wal_buf_bytes=0, no fsync)
    # vs SQLite pwrite on every commit to WAL (synchronous=NORMAL, no fsync). Both survive a kill.
    @('put_sync', 'put', $true),
    @('put_batch', 'put_txn', $true),
    @('get', 'get', $true),
    @('scan', 'scan_v', $true),
    @('count_10k', 'scan_big', $true),
    # scan_refs COLLECTS the matching records (200k x 48B); the old pairing used scan_big, which only
    # advances the cursor -- not the same criteria (that once produced a fake 0.70x). Now uses the
    @('scan_refs', 'scan_big_collect', $true),
    # sql_put is our SQL-layer per-row INSERT (one insertRows call per row, no transaction wrapper),
    # so it must pair with SQLite put (per-row autocommit), NOT put_txn (single-transaction batch).
    # The old map paired it with put_txn, crushing 48.4x into 1.85x and suggesting the gap came from
    # the SQL layer -- storage API vs SQL layer differ by ~7%; the gap is one full commit per row.
    @('sql_put', 'put', $true),
    @('sql_get', 'sql_get', $true),
    @('sql_full', 'sql_full', $true),
    # Ours sql_each = streaming, decodes 2 columns; SQLite sql_full_touch = reads 2 column values.
    # Both decode two columns, so it is the same criteria. In the old table sql_full_touch was paired
    # with itself (we never had that metric), so this item had never been compared at all.
    @('sql_each', 'sql_full_touch', $true),
    # LIMIT early exit: both run `SELECT * FROM t LIMIT 10`; we stop after 10 rows.
    @('sql_limit10', 'sql_limit10', $true),
    # ORDER BY + LIMIT (top-N): both run `SELECT * FROM t ORDER BY id DESC LIMIT 10` on the same
    # 1M-row table. Both sides keep only the top N (our exec.keepTopN heap vs SQLite's sorter
    # top-N), so this compares the same work -- neither side materialises/sorts all 1M rows.
    @('sql_orderby_limit10', 'sql_orderby_limit10', $true),
    # Aggregate: same logical table on both sides (1M rows, id / g=id%100000 / x=id%1000), same SQL,
    # and both pull the whole result set to compute a digest (consistency is asserted separately).
    @('sql_group_by', 'sql_group_by', $true),
    @('sql_agg_full', 'sql_agg_full', $true),
    # HAVING + ORDER BY aggregate + LIMIT (top-N): same SQL, with a tie-breaker key so the result
    @('sql_having_top10', 'sql_having_top10', $true),
    # Secondary index: both sides build the same index agg(g) over the same 1M rows, then
    # run the same 5000 equality lookups (shared xorshift key sequence) and compare digests.
    @('sql_index_eq', 'sql_index_eq', $true),
    # ORDER BY <indexed col> ASC LIMIT 10: same SQL on both sides (`ORDER BY g ASC LIMIT 10`);
    # idx_g(g) gives the order directly, the projected `x` is not in the index so both sides
    # must fetch the row. 200 reps median, statement prepared outside the timed region.
    @('sql_orderby_index10', 'sql_orderby_index10', $true),
    # WHERE on the SAME indexed column + ORDER BY it + LIMIT: the index supplies both the range
    # bound and the order, so both sides stop after 10 rows. This is the item that used to fall
    # back to a full table scan on our side (no WHERE support on the index-order path).
    @('sql_where_orderby_index10', 'sql_where_orderby_index10', $true),
    # JOIN: same two tables on both sides, same INNER JOIN, same index on the ON column,
    # 128 reps median with the statement prepared outside the timed region.
    @('sql_join_index', 'sql_join_index', $true),
    # Index build time is a one-shot latency-like metric (milliseconds, lower is better).
    @('sql_index_build', 'sql_index_build', $false),
    # The three items below are per-row writes on our side vs a single transaction on SQLite (its
    # most favourable form) -- a conservative choice that favours SQLite. Kept because SQLite has
    # no per-row variant at this scale (2M autocommit takes tens of seconds) and it never flatters us.
    @('conc_put_1t', 'conc_put_1t_txn', $true),
    @('conc_put_2t', 'conc_put_2t_txn', $true),
    @('conc_put_4t', 'conc_put_4t_txn', $true),
    @('big_put', 'big_put_txn', $true),
    @('big_get', 'big_get', $true),
    @('big_count', 'big_count', $true),
    @('big_count_range', 'big_count_range', $true),
    @('upd_random', 'upd_random_txn', $true),
    # DELETE: both delete 100k rows in one commit (same transaction scope); bytes reported separately.
    @('del_100k', 'del_100k', $true),
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
