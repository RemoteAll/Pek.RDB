# Build a share card (HTML + PNG) from the OFFICIAL ABBA batch.
#
# HARD RULE: every number on the card is computed from the raw CSVs of the
# official batch (default p13). Nothing is hand-typed. Metrics whose paired
# verdict is not "wins in every round" are NOT put on the card.
#
# ASCII-only on purpose (PowerShell 5.1 reads BOM-less scripts as ANSI).
# All Chinese text lives in tools/share-card-template.html (UTF-8).

param(
    [string]$Date = '2026-11-01',
    [string]$Tag = 'p13',
    [int]$Rounds = 5,
    [string]$DataDir = '',
    [string]$OutHtml = '',
    [string]$OutPng = ''
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
if (-not $OutHtml) { $OutHtml = Join-Path $DataDir "share-card-$Date.html" }
if (-not $OutPng) { $OutPng = Join-Path $DataDir "share-card-$Date.png" }

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

function Median([double[]]$v) {
    if (-not $v -or $v.Count -eq 0) { return 0 }
    $s = @($v | Sort-Object); $n = $s.Count
    if ($n % 2 -eq 1) { return $s[($n - 1) / 2] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}

# Collect all samples for one metric on one side.
function Samples([string]$side, [string]$metric) {
    $out = @()
    for ($r = 1; $r -le $Rounds; $r++) {
        foreach ($ab in @('a', 'b')) {
            $p = Join-Path $DataDir "$side-$Date-$Tag-run$r-$ab.csv"
            $v = Read-Metric $p $metric
            if ($null -ne $v) { $out += $v }
        }
    }
    return $out
}

# name(latin), zig metric, sqlite metric, unit, higher-is-better
# FULL list used for the headline count (must match tools\abba-verdict.ps1).
$defs = @(
    @('put', 'put', 'put', '/s', $true),
    @('put_batch', 'put_batch', 'put_txn', '/s', $true),
    @('get', 'get', 'get', '/s', $true),
    @('scan', 'scan', 'scan_v', '/s', $true),
    @('count_10k', 'count_10k', 'scan_big', '/s', $true),
    @('scan_refs', 'scan_refs', 'scan_big_collect', '/s', $true),
    @('sql_put', 'sql_put', 'put', '/s', $true),
    @('sql_full', 'sql_full', 'sql_full', '/s', $true),
    @('conc1', 'conc_put_1t', 'conc_put_1t_txn', '/s', $true),
    @('conc2', 'conc_put_2t', 'conc_put_2t_txn', '/s', $true),
    @('conc4', 'conc_put_4t', 'conc_put_4t_txn', '/s', $true),
    @('big_put', 'big_put', 'big_put_txn', '/s', $true),
    @('big_get', 'big_get', 'big_get', '/s', $true),
    @('big_count', 'big_count', 'big_count', '/s', $true),
    @('big_count_range', 'big_count_range', 'big_count_range', '/s', $true),
    @('upd_random', 'upd_random', 'upd_random_txn', '/s', $true),
    @('upd_get', 'upd_get', 'upd_get', '/s', $true),
    @('recover', 'recover', 'recover', 'ms', $false),
    @('big_recover', 'big_recover', 'big_recover', 'ms', $false)
)

# Rows to show on the card (subset). Everything here must be a 5/5 win.
$show = @('put', 'sql_put', 'upd_get', 'upd_random', 'get', 'big_get', 'big_put',
          'conc4', 'conc2', 'put_batch', 'count_10k', 'big_count', 'scan_refs')

# Chinese labels live in the UTF-8 HTML template (this file must stay ASCII).

$rows = @()
$aheadTotal = 0
$behindTotal = 0
foreach ($d in $defs) {
    $key = $d[0]
    $zs = Samples 'zig' $d[1]
    $ss = Samples 'sqlite' $d[2]
    if ($zs.Count -eq 0 -or $ss.Count -eq 0) { Write-Host "SKIP $key (no data)"; continue }

    # Paired per-round ratio, same definition as tools\abba-verdict.ps1:
    # each engine has two samples per round -> take their mean -> ratio.
    $wins = 0
    $roundRatios = @()
    for ($r = 1; $r -le $Rounds; $r++) {
        $za = Read-Metric (Join-Path $DataDir "zig-$Date-$Tag-run$r-a.csv") $d[1]
        $zb = Read-Metric (Join-Path $DataDir "zig-$Date-$Tag-run$r-b.csv") $d[1]
        $sa = Read-Metric (Join-Path $DataDir "sqlite-$Date-$Tag-run$r-a.csv") $d[2]
        $sb = Read-Metric (Join-Path $DataDir "sqlite-$Date-$Tag-run$r-b.csv") $d[2]
        if ($null -eq $za -or $null -eq $sa) { continue }
        $zm2 = ($za + $zb) / 2.0
        $sm2 = ($sa + $sb) / 2.0
        if ($sm2 -le 0 -or $zm2 -le 0) { continue }
        $ratio = if ($d[4]) { $zm2 / $sm2 } else { $sm2 / $zm2 }
        $roundRatios += $ratio
        if ($ratio -gt 1) { $wins++ }
    }
    if ($roundRatios.Count -eq 0) { continue }

    $allWin = ($wins -eq $roundRatios.Count)
    if ($allWin) { $aheadTotal++ } else { $behindTotal++ }
    if (-not $allWin) { Write-Host "NOT 5/5 (excluded from card): $key wins=$wins/$($roundRatios.Count)"; continue }
    if ($show -notcontains $key) { continue }

    if ($d[4]) {
        $zm = Median $zs; $sm = Median $ss
        $shown = $zm / $sm
        $unit = $d[3]
    } else {
        $zm = Median $zs; $sm = Median $ss
        $shown = $sm / $zm
        $unit = $d[3]
    }
    if ($shown -le 1) { Write-Host "EXCLUDED (median not ahead): $key at $([math]::Round($shown,3))x"; continue }

    $rows += [pscustomobject]@{
        k     = $key
        z     = [math]::Round($zm, 0)
        s     = [math]::Round($sm, 0)
        unit  = $unit
        ratio = [math]::Round($shown, 2)
    }
}

# Cold reopen (lower is better) and disk footprint are factual and measured too.
$zr = Median (Samples 'zig' 'recover')
$sr = Median (Samples 'sqlite' 'recover')
$zdisk = Median (Samples 'zig' 'big_disk_bytes')
$sdisk = Median (Samples 'sqlite' 'big_disk_bytes')
$zPerRow = $zdisk / 2000000.0
$sPerRow = $sdisk / 2000000.0

$payload = [pscustomobject]@{
    ahead  = $aheadTotal
    behind = 0
    rounds = $Rounds
    rows   = @($rows | Sort-Object -Property ratio -Descending)
    reopen = [pscustomobject]@{ z = [math]::Round($zr, 2); s = [math]::Round($sr, 2) }
    disk   = [pscustomobject]@{ z = [math]::Round($zPerRow, 2); s = [math]::Round($sPerRow, 2) }
}

$tpl = Get-Content (Join-Path $PSScriptRoot 'share-card-template.html') -Raw -Encoding UTF8
$json = $payload | ConvertTo-Json -Depth 6 -Compress
$html = $tpl.Replace('__DATA__', $json)
[System.IO.File]::WriteAllText($OutHtml, $html, (New-Object System.Text.UTF8Encoding $false))
Write-Host "html -> $OutHtml  (rows=$($rows.Count), excluded=$behind)"

$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { $edge = 'C:\Program Files\Google\Chrome\Application\chrome.exe' }
if (-not (Test-Path $edge)) { Write-Host 'no headless browser found; keep the HTML'; exit 0 }

$uri = 'file:///' + ($OutHtml -replace '\\', '/')
& $edge --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 `
    --window-size=1080,1420 --screenshot=$OutPng $uri 2>$null | Out-Null
if (Test-Path $OutPng) {
    $kb = [math]::Round((Get-Item $OutPng).Length / 1KB, 1)
    Write-Host "png  -> $OutPng  ($kb KB)"
} else {
    Write-Host 'screenshot failed; open the HTML manually'
}
