<#
  The whole daily hunt in one script — no browser, no model tokens. Prints a short summary only.
  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File run-daily.ps1 [-Weekly] [-Date yyyy-MM-dd]
  Inputs (C:\Claude\Personal\property-hunt\):
    config.json, seen.json, market-ratios.json, market-growth.json, slopes.json (LiDAR results cache),
    shortlist.json   ← starred listing ids, written by Claude from the page's db before running (["4302...", ...])
    market-note.txt  ← optional two-line market update for the email
  Outputs: reports\<Date>.json, reports\report.html + reports\data.json, reports\email-<Date>.html,
           needs-slope.json (new sites without a slope — run slope.js for these, then run render step again), seen.json, sold-outcomes.json
  -Weekly also refreshes market-ratios.json from 12 months of sales and checks sold results for every tracked listing.
#>
param([switch]$Weekly, [string]$Date = (Get-Date -Format 'yyyy-MM-dd'), [switch]$SkipSearch)

$ErrorActionPreference = 'Continue'
# Time budget (minutes, env HUNT_MINUTES, default 270): the cloud job is killed at 350, losing everything, so each slow
# step stops early instead; unfinished listings are picked up by the next run.
$started = Get-Date; $budgetMin = if ($env:HUNT_MINUTES) { [int]$env:HUNT_MINUTES } else { 270 }
function MinLeft { $budgetMin - ((Get-Date) - $started).TotalMinutes }
# Data folder: HUNT_ROOT when set (the cloud run), else the local folder.
function HuntRoot { if ($env:HUNT_ROOT) { $env:HUNT_ROOT } else { 'C:\Claude\Personal\property-hunt' } }
$root = (HuntRoot); $sk = $PSScriptRoot; $utf8 = [Text.Encoding]::UTF8
$UA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36' }
$API = 'https://platform.realestate.co.nz/search/v1'
function ReadJson($p) { if (Test-Path $p) { [IO.File]::ReadAllText($p, $utf8) | ConvertFrom-Json } else { $null } }
function WriteJson($p, $o, $d = 8) { [IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth $d), (New-Object Text.UTF8Encoding($false))) }
function GetJson($u) { for ($i = 0; $i -lt 3; $i++) { try { return Invoke-RestMethod $u -Headers $UA -TimeoutSec 40 } catch { Start-Sleep -Seconds (2 + $i * 3) } }; $null }
function GetHtml($u) { for ($i = 0; $i -lt 3; $i++) { try { return (Invoke-WebRequest $u -Headers $UA -UseBasicParsing -TimeoutSec 60).Content } catch { Start-Sleep -Seconds (2 + $i * 3) } }; '' }
function ToHash($o) { $h = @{}; if ($o) { $o.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }; $h }

$cfg = ReadJson "$root\config.json"
# Region: config "region" = "chc" switches the search, site checks (check-site reads HUNT_REGION) and wording to Christchurch.
$CHC = "$($cfg.region)" -eq 'chc'; $env:HUNT_REGION = $(if ($CHC) { 'chc' } else { '' })
$searchPath = if ($cfg.search_path) { "$($cfg.search_path)" } else { 'auckland' }
$apiRegion = if ($cfg.api_region) { [int]$cfg.api_region } else { 35 }
$cityName = if ($cfg.region_label) { "$($cfg.region_label)" } elseif ($CHC) { 'Canterbury' } else { 'Auckland' }
$seen = ToHash (ReadJson "$root\seen.json")
# The old hunt dropped listings under 600 m², under 2 bedrooms, non-houses and over the price ceiling: forget those so they are checked now.
# Before Nov 2026 the site checks used the listing's map pin, which can sit on the neighbour's title (45 Avondale Rd read a
# next-door cross lease), so title, zone and flood could all be wrong. Re-check those rule failures once (still-listed ones
# only; overflow waits for the next runs); the checks now use LINZ's address point and mark it in addr_point.
$linzDone = @{}; foreach ($cf in @(Get-ChildItem "$root\site-checks*.jsonl" -ErrorAction SilentlyContinue)) { foreach ($ln in [IO.File]::ReadAllLines($cf.FullName)) { if ($ln -match '"addr_check":2' -and $ln -match '^\{"id":"([^"]+)"') { $linzDone[$Matches[1]] = 1 } } }
$recheck = @{}; foreach ($k in @($seen.Keys)) { if ($seen[$k].outcome -eq 'listed_fails_rules' -and -not $linzDone[$k]) { $seen[$k].outcome = 'candidate'; $recheck[$k] = 1 } }
foreach ($k in @($seen.Keys)) { if ($seen[$k].outcome -eq 'screened_out' -and ("$($seen[$k].reason)" -notmatch '^Outside ' -or -not $cfg.district_name)) { $seen.Remove($k) } }
$ratios = ReadJson "$root\market-ratios.json"
$slopes = ToHash (ReadJson "$root\slopes.json")
# Windows PowerShell returns a JSON array as one object; piping it enumerates the ids.
$starred = @((ReadJson "$root\shortlist.json") | ForEach-Object { "$_" })
$subs = @($cfg.suburbs); $max = [double]$cfg.max_price; $stretchMax = $max * (1 + [double]$cfg.stretch_pct / 100)
# search_max_price: the hunt keeps sites up to this so the page's price filter can reach them; budget labels still use max_price.
$keepMax = if ($cfg.search_max_price) { [math]::Max([double]$cfg.search_max_price, $stretchMax) } else { $stretchMax }
# Top secondary school zones (config top_schools): suburbs each zone covers, rebuilt every 90 days or when the list changes.
$zf = "$root\school-zones.json"; $zones = ReadJson $zf; $topIds = @($cfg.top_schools | ForEach-Object { "$($_.id)" })
if ($topIds.Count -and (-not $zones -or ((Get-Date) - (Get-Item $zf).LastWriteTime).TotalDays -gt 90 -or (@($zones.schools.PSObject.Properties.Name) -join ',') -ne ($topIds -join ','))) {
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File "$sk\school-zones.ps1"; $zones = ReadJson $zf
}
# With zone_search on, listings in a top-zone suburb outside your list are screened too, and kept only if the site is in that zone.
$zoneSubs = @(); if ($cfg.zone_search -and $zones) { $zoneSubs = @($zones.schools.PSObject.Properties | ForEach-Object { $_.Value.suburbs } | Sort-Object -Unique | Where-Object { $subs -notcontains $_ }) }
# Latest report up to and including today (a same-day re-run builds on today's report).
$prevFile = Get-ChildItem "$root\reports\*.json" | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}\.json$' -and $_.BaseName -le $Date } | Sort-Object Name | Select-Object -Last 1
$prev = if ($prevFile) { ReadJson $prevFile.FullName } else { $null }
$log = New-Object System.Collections.ArrayList
function Log($s) { [void]$log.Add($s) }

# ---------- 1. Weekly: refresh sale/CV ratios (rolling 12 months) ----------
if ($Weekly) {
    $since = (Get-Date $Date).AddDays(-365).ToString('yyyy-MM-dd'); $sales = @{}
    $suburbDistrict = @{}; foreach ($s in $subs) { $suburbDistrict[$s] = 'auckland-city' }
    foreach ($s in 'botany-downs', 'sunnyhills', 'cockle-bay', 'half-moon-bay', 'mellons-bay', 'somerville') { $suburbDistrict[$s] = 'manukau-city' }
    if ($CHC) {
        # Christchurch: one city-wide pass over recent sales, grouped by each property's own suburb.
        $ids = New-Object System.Collections.Generic.HashSet[string]
        for ($p = 1; $p -le 40; $p++) { $h = GetHtml "https://www.realestate.co.nz/residential/sold/${searchPath}?page=$p"; $m = [regex]::Matches($h, '/property/[a-z0-9-]+/([a-z0-9]{6,12})'); if (-not $m.Count) { break }; foreach ($x in $m) { [void]$ids.Add($x.Groups[1].Value) } }
        foreach ($id in $ids) { if ((MinLeft) -lt $budgetMin * 0.8) { break }   # the price refresh gets at most a fifth of the time
            $a = (GetJson "$API/properties/$id").data.attributes; $sl = $a.'latest-sale'; $cv = $a.'council-information'.'capital-value'
            if ($sl -and $sl.'sale-price' -and $cv -and $sl.'sale-date' -ge $since -and "$($sl.category)" -match 'Residence|Home and Income') {
                $sk2 = ("$($a.address.suburb)".ToLower() -replace '^st\.? ', 'saint ' -replace '^mt\.? ', 'mount ' -replace '[^a-z]+', '-').Trim('-')
                if (-not $sales.ContainsKey($sk2)) { $sales[$sk2] = @() }
                $sales[$sk2] += [pscustomobject]@{ r = $sl.'sale-price' / $cv; land = [double]$a.'land-area' } } }
        $subs = @()
    }
    foreach ($s in ($subs | Where-Object { $_ -notmatch '^st-' } | Select-Object -Unique)) {
        if ((MinLeft) -lt $budgetMin * 0.8) { break }
        $ids = New-Object System.Collections.Generic.HashSet[string]
        for ($p = 1; $p -le 4; $p++) { $h = GetHtml "https://www.realestate.co.nz/residential/sold/auckland/$($suburbDistrict[$s])/${s}?page=$p"; $m = [regex]::Matches($h, '/property/[a-z0-9-]+/([a-z0-9]{6,12})'); if (-not $m.Count) { break }; foreach ($x in $m) { [void]$ids.Add($x.Groups[1].Value) } }
        $rows = @(); foreach ($id in $ids) { $a = (GetJson "$API/properties/$id").data.attributes; $sl = $a.'latest-sale'; $cv = $a.'council-information'.'capital-value'
            if ($sl -and $sl.'sale-price' -and $cv -and $sl.'sale-date' -ge $since -and "$($sl.category)" -match 'Residence|Home and Income') { $rows += [pscustomobject]@{ r = $sl.'sale-price' / $cv; land = [double]$a.'land-area' } } }
        $sales[$s] = $rows
    }
    function Q($a, $p) { $s = @($a | Sort-Object); if ($s.Count) { [math]::Round($s[[math]::Floor($p * ($s.Count - 1))], 3) } else { $null } }
    function Stats($rows) { $big = @($rows | Where-Object { $_.land -ge 600 }); [ordered]@{ n = @($rows).Count; median = Q ($rows.r) .5; p25 = Q ($rows.r) .25; p10 = Q ($rows.r) .1; big_n = $big.Count; big_median = Q ($big.r) .5; big_p25 = Q ($big.r) .25; big_p10 = Q ($big.r) .1 } }
    $out = [ordered]@{ updated = $Date; since = $since; all = Stats (@($sales.Values | ForEach-Object { $_ })); suburbs = [ordered]@{} }
    foreach ($k in $sales.Keys) { $out.suburbs[$k] = Stats $sales[$k] }
    WriteJson "$root\market-ratios.json" $out 5; $ratios = ReadJson "$root\market-ratios.json"
    Log "Weekly: sale/CV ratios refreshed ($($out.all.n) sales since $since)"
}

# ---------- 2. Search (HTML pages, newest first) + mortgagee sales ----------
$found = [ordered]@{}
if (-not $SkipSearch) {
    # auckland_wide: one region-level search covers every district; otherwise the listed districts.
    $areas = if ($cfg.auckland_wide) { @('') } else { @($cfg.districts | ForEach-Object { "/$_" }) }
    foreach ($d in $areas) {
        for ($p = 1; $p -le 800; $p++) {
            $h = GetHtml "https://www.realestate.co.nz/residential/sale/$searchPath${d}?by=latest&page=$p"
            $m = [regex]::Matches($h, '/(\d{8})/residential/sale/([a-z0-9-]+)'); if (-not $m.Count) { break }
            $newHere = 0; foreach ($x in $m) { $id = $x.Groups[1].Value; if (-not $found.Contains($id)) { $found[$id] = $x.Groups[2].Value; if (-not $seen.ContainsKey($id)) { $newHere++ } } }
            if ($p -gt 2 -and $newHere -eq 0 -and $seen.Count -gt 200) { break }   # caught up with what we've already screened
        }
    }
    $mg = GetJson "$API/listings?filter%5Bcategory%5D%5B%5D=res_sale&filter%5Bregion%5D%5B%5D=$apiRegion&filter%5BisMortgageeSale%5D=true&page%5Blimit%5D=50"
    foreach ($x in $mg.data) { $slug = ("$($x.attributes.'website-slug')" -split '/')[-1]; if ($slug -and -not $found.Contains("$($x.id)")) { $found["$($x.id)"] = $slug } }
}
$inArea = @($found.Keys | Where-Object { $s = $found[$_]; ($cfg.auckland_wide -or ($subs | Where-Object { $s.EndsWith("-$_") }).Count -gt 0) })
$zoneOnly = @($found.Keys | Where-Object { $s = $found[$_]; $inArea -notcontains $_ -and ($zoneSubs | Where-Object { $s.EndsWith("-$_") }).Count -gt 0 -and $s -notmatch '^\d+-\d+-|^lot-' })
# 'candidate' = passed the first screen but its site checks never finished (a stopped run): screen it again.
if ($SkipSearch) { foreach ($k in @($seen.Keys)) { if ($seen[$k].outcome -eq 'candidate' -and -not $found.Contains($k)) { $found[$k] = ("$($seen[$k].url)" -split '/')[-1] } } }
$inArea = @($found.Keys | Where-Object { $s = $found[$_]; ($cfg.auckland_wide -or ($subs | Where-Object { $s.EndsWith("-$_") }).Count -gt 0) })
$newIds = @(@($inArea) + @($zoneOnly) | Where-Object { -not $seen.ContainsKey($_) -or $seen[$_].outcome -eq 'candidate' })
Log "Search: $($found.Count) listings, $($inArea.Count) in $(if ($cfg.auckland_wide) { $cityName } else { 'your suburbs' }), $($zoneOnly.Count) in top-school-zone suburbs, $($newIds.Count) new"

# ---------- 3. Facts for new listings + pre-screen ----------
function Get-Ratios([string]$slug, [double]$land) {
    $s = $ratios.suburbs.$slug; $a = $ratios.all
    $useBig = $s -and $land -ge 600 -and $s.big_n -ge 8
    $likely = if ($useBig) { $s.big_median } elseif ($s -and $s.n -ge 5) { $s.median } else { $a.big_median }
    $low = if ($useBig -and $s.big_p25) { $s.big_p25 } elseif ($s -and $s.n -ge 5 -and $s.p25) { $s.p25 } else { $a.big_p25 }
    @([double]$likely, [double]$low)
}
$CLAD = [ordered]@{ 'Monolithic plaster/stucco' = '\b(plaster(ed)?|stucco|monolithic|EIFS|polystyrene)\b'; 'Harditex / fibre-cement sheet' = '\b(harditex|hardiflex|fibre[- ]?cement (sheet|board))\b'; 'Linea / fibre-cement weatherboard' = '\b(linea|hardiplank)\b'; 'Fibrolite (asbestos-era)' = '\b(fibrolite|super six|asbestos)\b'; 'Brick' = '\b(brick|clinker)\b'; 'Weatherboard (timber)' = '\b(weatherboards?|bevel[- ]?back|rusticated|cedar)\b'; 'Block / concrete' = '\b(concrete block|blockwork|solid concrete)\b'; 'Roughcast' = '\broughcast\b'; 'Board and batten' = '\bboard (and|&) batten\b' }
$ROOF = [ordered]@{ 'Tile (concrete/clay)' = '\b(tile roof|tiled roof|(brick|block|weatherboard) (and|&) tile|terracotta|concrete tiles?)\b'; 'Long-run iron / Colorsteel' = '\b(iron roof|corrugated|long[- ]?run|colou?rsteel|metal roof|(brick|weatherboard) (and|&) iron)\b'; 'Decramastic (pressed metal tile)' = '\b(decramastic|pressed metal tile)\b'; 'Butynol / membrane (flat roof)' = '\b(butynol|membrane roof|flat roof)\b' }
$cands = @(); $screenedOut = 0; $deferred = 0
# Site checks take ~20 s each, so each run checks at most max_new_per_run new listings (newest first) to stay inside the time limit.
$maxNew = if ($cfg.max_new_per_run) { [int]$cfg.max_new_per_run } else { 300 }
foreach ($id in $newIds) {
    if ($cands.Count -ge $maxNew -or (MinLeft) -lt 120) { $deferred++; continue }   # the rest are checked on the next runs (not marked seen)
    $l = (GetJson "$API/listings/$id").data.attributes; if (-not $l) { continue }
    $desc = (("$($l.description)") -replace '<[^>]+>', ' ' -replace '\s+', ' ')
    $land = [double]$l.'land-area'; $beds = [int]$l.'bedroom-count'; $sub = "$($l.address.suburb)"
    # Listing-only checks first: skip the property lookup for sites that fail on land, beds or type.
    # Region-wide mortgagee sales can be outside the city (e.g. Selwyn): keep only the configured district.
    $quick = if ($cfg.district_name -and "$($l.address.district)" -ne "$($cfg.district_name)") { "Outside $($cfg.district_name)" } else { $null }
    if ($quick) { $seen[$id] = [ordered]@{ address = "$($l.address.'full-address')"; url = "$($l.'website-full-url')"; first_seen = $Date; last_seen = $Date; price_text = "$($l.'price-display')"; outcome = 'screened_out'; reason = $quick }; $screenedOut++; continue }
    $p = if ($l.'property-short-id') { (GetJson "$API/properties/$($l.'property-short-id')").data.attributes } else { $null }
    $slug = ($sub.ToLower() -replace '^st\.? ', 'saint ' -replace '^mt\.? ', 'mount ' -replace '[^a-z]+', '-').Trim('-')
    $cv = [double]$p.'council-information'.'capital-value'; $est = $p.'estimated-value'
    $ask = 0; $mm = [regex]::Match("$($l.'price-display')", '\$([\d,]+)'); if ($mm.Success) { $ask = [double]($mm.Groups[1].Value -replace ',', '') }
    $r = Get-Ratios $slug $land
    $expected = if ($ask) { $ask } elseif ($est.'value-mid' -and $cv) { ($est.'value-mid' + $cv * $r[0]) / 2 } elseif ($cv) { $cv * $r[0] } else { 0 }
    $low = if ($cv) { $cv * $r[1] } else { $expected }
    $why = $null
    # No land, bedroom, type or price limits: every listing is kept, and people filter on the site.
    $seen[$id] = [ordered]@{ address = "$($l.address.'full-address')"; url = "$($l.'website-full-url')"; first_seen = $Date; last_seen = $Date; price_text = "$($l.'price-display')"; outcome = $(if ($why) { 'screened_out' } else { 'candidate' }); reason = $why }
    if ($why) { $screenedOut++; continue }
    $types = @(); if ($l.'is-mortgagee-sale' -or $desc -match 'mortgagee') { $types += 'Mortgagee sale' }; if ($l.'is-private-listing') { $types += 'Private sale' }
    if ($desc -match 'deceased estate|estate sale|executors?\b|estate of the late') { $types += 'Estate sale' }; if ($desc -match 'ex[- ]state|former state|state house|kainga ora|kāinga ora|housing new zealand') { $types += 'Ex-state home' }
    if ($desc -match 'must (be )?sell|motivated|instructions? to sell|overseas vendor|moving overseas|relocat') { $types += 'Motivated vendor' }
    $age = "$($p.'building-age')"
    $cands += [pscustomobject]@{ id = $id; address = (("$($l.address.'full-address')" -split ',')[0..1] -join ',').Trim(); suburb = $sub; district = "$($l.address.district)"; url = "$($l.'website-full-url')"; source = 'realestate.co.nz'; status = 'new'; ptype = "$($l.'listing-sub-type')"
        price_text = ("$($l.'price-display')" + $(if ($l.'auction-date') { ' ' + ("$($l.'auction-date')" + '          ').Substring(0, 10).Trim() })); asking = $(if ($ask) { $ask } else { $null })
        beds = $beds; baths = $l.'bathroom-count'; land_m2 = $land; floor_m2 = $p.'floor-area'; decade_built = $(if ($age -and $age -ne '0') { "${age}s" } else { '' })
        cv = $cv; land_value = $p.'council-information'.'land-value'; estimate = $(if ($est) { [ordered]@{ low = $est.'value-low'; mid = $est.'value-mid'; high = $est.'value-high' } } else { $null })
        lat = $p.address.latitude; lon = $p.address.longitude; sale_type = $types
        materials = [ordered]@{ c = @($CLAD.Keys | Where-Object { $desc -match $CLAD[$_] }); r = @($ROOF.Keys | Where-Object { $desc -match $ROOF[$_] }); reclad = $desc -match 're-?clad'; ccc = $desc -match '\bCCC\b|code compliance' }
        consent = $(if ($desc -match 'resource consent|consented for|RC (approved|granted)') { $true } else { $false }); desc_flags = @() }
}
Log "New listings: $($cands.Count) to check, $screenedOut outside the area$(if ($deferred) { ", $deferred left for the next runs" })"

# ---------- 4. Site checks for new candidates ----------
# Results are cached one JSON line per site in site-checks.jsonl, so a stopped run resumes where it left off.
# Uncached sites are split across 6 parallel check-site workers (~18 s per site each).
$checked = @{}; $cacheF = "$root\site-checks.jsonl"
function LoadChecks { foreach ($cf in @(Get-ChildItem "$root\site-checks*.jsonl" -ErrorAction SilentlyContinue)) { foreach ($ln in [IO.File]::ReadAllLines($cf.FullName, $utf8)) { if ($ln.Trim()) { try { $x = $ln | ConvertFrom-Json; if (-not $x.error -and ($x.addr_check -ge 2 -or -not $recheck["$($x.id)"])) { $checked["$($x.id)"] = $x } } catch {} } } } }
LoadChecks
$todo = @($cands | Where-Object { -not $checked.ContainsKey("$($_.id)") })
if ($todo.Count) {
    # $nW, not $W: PowerShell names are case-insensitive, so $W and a loop's $w would be one variable.
    $nW = [math]::Min(6, $todo.Count); $procs = @()
    for ($w = 0; $w -lt $nW; $w++) {
        $csv = "$env:TEMP\hunt-sites-$w.csv"
        @(for ($i = $w; $i -lt $todo.Count; $i += $nW) { $t = $todo[$i]; [pscustomobject]@{ id = $t.id; address = "$($t.address), $cityName"; lat = $t.lat; lon = $t.lon } }) | Export-Csv $csv -NoTypeInformation -Encoding UTF8
        $procs += Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$sk\check-site.ps1`"", '-InputCsv', "`"$csv`"", '-JsonLines', "`"$root\site-checks-$w.jsonl`"" -WindowStyle Hidden -PassThru
    }
    # Stop the checkers in time to build and save the report; each finished site is already written to its file.
    $waitS = [int][math]::Max(60, ((MinLeft) - 25) * 60)
    try { $procs | Wait-Process -Timeout $waitS -ErrorAction Stop } catch { }
    $late = @($procs | Where-Object { -not $_.HasExited }); if ($late.Count) { $late | Stop-Process -Force; Log "Site checks stopped at the time limit; the rest continue next run" }
    for ($w = 0; $w -lt $nW; $w++) { $f = "$root\site-checks-$w.jsonl"; if (Test-Path $f) { [IO.File]::AppendAllText($cacheF, [IO.File]::ReadAllText($f, $utf8), $utf8); Remove-Item $f } }
    LoadChecks
}
Log "Site checks: $($todo.Count) queued today ($([math]::Round(((Get-Date) - $started).TotalMinutes)) min in), $(@($cands | Where-Object { $checked.ContainsKey("$($_.id)") }).Count) of $($cands.Count) available"

# Flood: worst layer that touches the whole parcel (flood_site, % of site area), else the old address-point test.
function FloodText($c) {
    $fs = $c.flood_site
    $names = if (@($c.flood_names).Count -eq 3) { @($c.flood_names) } elseif ($CHC) { 'High flood hazard', 'Flood management area', 'Fixed floor level area' } else { 'Flood plain', 'Flood prone', 'Flood sensitive' }
    foreach ($k in @(@('plain', $names[0], $c.flood_plain), @('prone', $names[1], $c.flood_prone), @('sensitive', $names[2], $c.flood_sensitive))) {
        $pct = if ($fs -and $fs -isnot [string] -and "$($fs.($k[0]))" -match '^\d+$') { [int]$fs.($k[0]) } else { $null }
        if ($pct -gt 0) { return "$($k[1]) ($pct% of site)" }
        if ($k[2] -eq $true) { return $k[1] }
    }
    ''
}

# ---------- 5. Apply rules + auto-write the angle/why/questions ----------
$great = 'High'; $bandRank = @{ High = 3; Medium = 2; Low = 1 }
$newItems = @(); $rejected = [Collections.ArrayList]@(); $schoolRej = [Collections.ArrayList]@()
foreach ($p in $cands) {
    $c = $checked[$p.id]; if (-not $c) { continue }
    if ($c.addr_point -eq 'linz') { $p.lat = $c.lat; $p.lon = $c.lon }   # map pin on the right parcel
    $flags = @()
    foreach ($k in 'zone', 'schools', 'services', 'transport', 'state_housing', 'motorway', 'land', 'power_lines') { $p | Add-Member $k $c.$k -Force }
    if ($zoneOnly -contains $p.id) {
        $inTop = @($c.schools.secondary | Where-Object { $_ -and $topIds -contains "$($_.id)" })
        if (-not $inTop.Count) { $seen[$p.id].outcome = 'outside_top_zone'; continue }
    }
    # Title, zone and school rules no longer drop a site: they're recorded in rule_fails and the page filters on them.
    $fails = @()
    if ($c.title -isnot [string]) {
        $lines = "$($c.title.estate)" -split "`n" | Where-Object { $_.Trim() }
        $main = $lines | Sort-Object { [double](([regex]::Match($_, '([\d,]+) m2').Groups[1].Value) -replace ',', '' -replace '^$', '0') } -Descending | Select-Object -First 1
        $share = [regex]::Matches("$main", '\b(\d+)/(\d+)\b') | Where-Object { $_.Groups[1].Value -ne $_.Groups[2].Value }
        $p | Add-Member title_estate "$($c.title.type): $(($lines -join '; '))" -Force; $p | Add-Member title $c.title.type -Force
        if ($c.title.type -ne 'Freehold' -or $share -or "$($c.title.estate)" -match 'Leasehold|Stratum|Unit') { $fails += "Title: $($c.title.type), $($lines[0])" }
        elseif ($lines.Count -gt 1) { $flags += 'Title includes a share of a shared lot (likely a common driveway): check rights and costs' }
    } else { $flags += 'Title not found in LINZ data: confirm with agent' }
    # Canterbury outside Christchurch City: the council zone layers only cover the city, so the zone isn't known.
    # Council layers are checked for Christchurch City, Selwyn and Waimakariri; the rest of Canterbury isn't covered yet.
    $outside = $CHC -and $p.district -and $p.district -notmatch '^(Christchurch City|Selwyn|Waimakariri)'
    if ($outside) { $c.zone = 'Not checked (council maps not covered)'; $p.zone = $c.zone; $flags += "$($p.district): zone, flood and pipes not checked yet; see the district council's plan maps" }
    elseif ("$($c.zone)" -notmatch 'Mixed Housing|Terrace Housing') { $fails += "Zone: $($c.zone)" }
    $sec = @($c.schools.secondary | Where-Object { $_ -and $_.name -and $_.authority -notmatch 'Integrated' })
    $best = $sec | Sort-Object { - $bandRank["$($_.band)"] } | Select-Object -First 1
    $names = ($sec | ForEach-Object { $_.name }) -join ', '
    if ($best -and $best.band -eq 'Low') { $fails += "School: $names (NCEA L3 $($best.ncea_l3_pct)%)" }
    $p | Add-Member rule_fails @($fails) -Force
    $p | Add-Member school ([ordered]@{ name = $(if ($names) { $names } else { 'No state secondary zone' }); band = $(if ($best) { $best.band } else { 'Unknown' }) }) -Force
    $p | Add-Member flood $(if ($outside) { 'Not checked (council maps not covered)' } else { FloodText $c }) -Force
    if ($c.special_character -eq $true) { $flags += $(if ($CHC) { 'Residential Character Area: demolition and new building need consent' } else { 'Special Character Area overlay: demolition needs consent' }) }
    if ($c.historic_heritage -eq $true) { $flags += 'Heritage setting or item on the site: check the District Plan schedule' }
    $ww = $c.services.wastewater; if ($ww -isnot [string] -and ($null -eq $ww.distance_m -or $ww.distance_m -gt 50)) { $flags += 'Public wastewater more than 50 m away: may need an extension or easement' }
    if ($c.state_housing.level -eq 'High') { $flags += "High state-housing concentration: $($c.state_housing.within_100m) Kāinga Ora parcels within 100 m" }
    if ($c.land -isnot [string] -and $null -ne $c.land.access_width_m -and $c.land.access_width_m -lt 3.5) { $flags += "Access only $($c.land.access_width_m) m wide: 1 rear dwelling only under the 3.5 m rule" }
    $pw = $c.power_lines; if ($pw -isnot [string] -and "$($pw.level)" -match 'Over site|corridor') { $flags += "High-voltage line: $($pw.level) ($($pw.line), $($pw.kv) kV). Building near it is restricted (AUP D26 National Grid Corridor)" }
    $sl = $slopes[$p.id]; if ($sl) { $p | Add-Member slope $sl -Force; if ($sl.class -eq 'Steep') { $flags += "Steep site ($($sl.fall_m) m fall): budget for retaining and earthworks" } }
    # Auto-written summary (no model prose needed).
    $zs = ("$($c.zone)" -replace 'Residential - ', '' -replace ' Zone', '' -replace 'Terrace Housing and Apartment Building', 'THAB')
    $ld = $c.land; $shape = if ($ld -isnot [string]) { "$($ld.shape)".ToLower() } else { 'site' }
    $front = if ($ld -isnot [string] -and $ld.position -match '^Road front') { "$($ld.frontage_m) m frontage$(if ($ld.position -match 'corner') { ', corner site' })$(if ($ld.path_frontage_m -is [ValueType] -and $ld.path_frontage_m -gt 0) { ", also $($ld.path_frontage_m) m beside a walkway" })" } elseif ($ld -isnot [string] -and $ld.access_width_m) { "rear site, $($ld.access_width_m) m access" } else { 'rear site' }
    $p | Add-Member dev_angle "$([math]::Round($p.land_m2)) m² $zs, $shape, $front$(if ($p.consent) { '; listing mentions a resource consent' })." -Force
    $tr = $c.transport
    $near = if ($tr.train) { "$($tr.train.name) station $(if ($tr.train.distance_m -ge 1000) { "$([math]::Round($tr.train.distance_m / 1000, 1)) km away" } else { "$($tr.train.distance_m) m away" })" }
            elseif ($tr.bus -and $null -ne $tr.bus.distance_m) { "bus stop $($tr.bus.distance_m) m away" } else { 'no bus stop within 800 m' }
    $p | Add-Member why ("{0} km to the {1}, {2}; {3}." -f $tr.cbd_km, $(if ($CHC) { 'central city' } else { 'CBD' }), $near, $(if (@($p.sale_type).Count) { ($p.sale_type -join ', ') } else { 'standard agency sale' })) -Force
    $qs = @('What is the vendor''s price expectation?', 'Is the title freehold with no covenants limiting dwellings?')
    if ($ld -isnot [string] -and $ld.position -match '^Rear') { $qs += 'How wide is the driveway / access leg along its whole length?' }
    if ($p.flood) { $qs += 'What does the LIM say about flooding and overland flow?' }
    if ($p.consent) { $qs += 'Can you share the resource consent, conditions and lapse date?' }
    if ($p.decade_built -match '^199|^200') { $qs += 'What is the cladding, and is there a cavity / CCC?' }
    $p | Add-Member questions $qs -Force
    # Rough weekly rent by bedrooms (2026 market medians for houses).
    $p | Add-Member weekly_rent $(if ($CHC) { switch ([int]$p.beds) { 2 { 500 } 3 { 590 } 4 { 690 } default { 760 } } } else { switch ([int]$p.beds) { 2 { 600 } 3 { 700 } 4 { 800 } default { 850 } } }) -Force
    $p | Add-Member flags @($flags | Select-Object -Unique) -Force
    $seen[$p.id].outcome = $(if ($fails.Count) { 'listed_fails_rules' } else { 'shortlisted' }); if ($fails.Count) { $seen[$p.id].reason = $fails -join '; ' }
    $newItems += $p
}

# ---------- 6. Carry forward the previous shortlist (status + price changes) ----------
$carried = @(); $gone = @(); $soldOut = ToHash (ReadJson "$root\sold-outcomes.json").sold
foreach ($p in @($prev.shortlist | Where-Object { $_ -and $_.id })) {
    $l = (GetJson "$API/listings/$($p.id)").data.attributes
    if ($l -and $l.'listing-status' -eq 'active') {
        $pt = "$($l.'price-display')" + $(if ($l.'auction-date') { ' ' + ("$($l.'auction-date')" + '          ').Substring(0, 10).Trim() })
        if ($pt -ne "$($p.price_text)" -and $p.price_text -notmatch 'was asking') { $p.status = 'price_change'; $p | Add-Member price_text_prev $p.price_text -Force; $p.price_text = $pt
            $mm = [regex]::Match("$($l.'price-display')", '\$([\d,]+)'); $p.asking = $(if ($mm.Success) { [double]($mm.Groups[1].Value -replace ',', '') } else { $null }) }
        else { $p.status = 'still_listed' }
        if ($seen[$p.id]) { $seen[$p.id].last_seen = $Date }
        $carried += $p
    } else {
        $pa = if ($l.'property-short-id') { (GetJson "$API/properties/$($l.'property-short-id')").data.attributes } else { $null }
        $s = $pa.'latest-sale'; $listed = "$($l.'published-date')".Substring(0, [math]::Min(10, "$($l.'published-date')".Length))
        $rec = [ordered]@{ address = $p.address; status = "$($l.'listing-status')"; checked = $Date; sale_date = $null; sale_price = $null; cv = $p.cv; expected = $p.pricing.expected; low = $p.pricing.low_case }
        if ($s -and $s.'sale-date' -ge $listed) { $rec.sale_date = $s.'sale-date'; $rec.sale_price = $s.'sale-price'; $rec.sale_vs_cv = [math]::Round($s.'sale-price' / $p.cv, 3); if ($p.pricing.expected) { $rec.sale_vs_expected = [math]::Round($s.'sale-price' / $p.pricing.expected, 3) } }
        $soldOut[$p.id] = $rec; $gone += $rec
    }
}
WriteJson "$root\sold-outcomes.json" ([ordered]@{ last_checked = $Date; sold = $soldOut })
foreach ($g in $gone) { Log ("Off the market: {0} ({1}){2}" -f $g.address, $g.status, $(if ($g.sale_price) { ", sold $($g.sale_price.ToString('N0')) = $([math]::Round(100 * $g.sale_vs_cv))% of CV" + $(if ($g.sale_vs_expected) { ", $([math]::Round(100 * ($g.sale_vs_expected - 1)))% vs our expected" }) } else { ', sale price not yet published' })) }

# ---------- 7. Build, render, email ----------
# One entry per listing: a site both carried over and re-screened keeps its fresh copy.
$all = @(@($carried) + @($newItems) | Group-Object { "$($_.id)" } | ForEach-Object { $_.Group[-1] })
foreach ($p in $all) { $p | Add-Member starred ($starred -contains "$($p.id)") -Force }
$needs = @($all | Where-Object { -not $_.slope -and -not $slopes[$_.id] } | ForEach-Object { [ordered]@{ id = $_.id; lat = $_.lat; lon = $_.lon } })
foreach ($p in $all) { if (-not $p.slope -and $slopes[$p.id]) { $p | Add-Member slope $slopes[$p.id] -Force } }
WriteJson "$root\needs-slope.json" @($needs) 3
$run = [ordered]@{
    summary = "$($newItems.Count) new site(s) today, $($carried.Count) still listed$(if ($gone.Count) { ", $($gone.Count) off the market" })."
    sources = @([ordered]@{ name = 'realestate.co.nz'; status = 'ok'; scanned = $found.Count })
    notes = @($prev.notes)
    shortlist = $all
    rejected = @(@($prev.rejected) + @($rejected) | Select-Object -Last 60)
    school_rejects = @(@($prev.school_rejects) + @($schoolRej) | Select-Object -Last 30)
    top_zones = $zones.schools
}
WriteJson "$env:TEMP\hunt-run.json" $run 10
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File "$sk\build-report.ps1" -Candidates "$env:TEMP\hunt-run.json" -Date $Date
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File "$sk\render-report.ps1" -Date $Date
$note = if (Test-Path "$root\market-note.txt") { [IO.File]::ReadAllText("$root\market-note.txt", $utf8).Trim() } else { '' }
& "$sk\render-email.ps1" -Date $Date -MarketNote $note | Out-Null
WriteJson "$root\seen.json" $seen 4

# ---------- 8. Short summary for Claude ----------
$rep = ReadJson "$root\reports\$Date.json"
"DATE $Date | shortlist $(@($rep.shortlist).Count) | new $($newItems.Count) | gone $($gone.Count) | needs-slope $($needs.Count) | starred $($starred.Count)"
$log | ForEach-Object { "- $_" }
"TOP:"; @($rep.shortlist) | Select-Object -First 5 | ForEach-Object { "  $($_.score) $($_.address) | $([math]::Round($_.pricing.expected/1000))k $($_.pricing.fit)$(if ($_.status -eq 'new') { ' | NEW' })$(if ($_.status -eq 'price_change') { ' | PRICE CHANGE' })" }
$st = @($rep.shortlist | Where-Object { $_.starred -and $_.status -eq 'price_change' }); if ($st.Count) { "STARRED PRICE CHANGES:"; $st | ForEach-Object { "  $($_.address): $($_.price_text_prev) -> $($_.price_text)" } }
"FILES: reports\report.html + reports\data.json (publish), reports\email-$Date.html (send)"
