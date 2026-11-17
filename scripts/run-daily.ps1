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
$seenBefore = @{}; foreach ($k in @($seen.Keys)) { $seenBefore[$k] = 1 }
$ratios = ReadJson "$root\market-ratios.json"
$slopes = ToHash (ReadJson "$root\slopes.json")
# Windows PowerShell returns a JSON array as one object; piping it enumerates the ids.
$starred = @((ReadJson "$root\shortlist.json") | ForEach-Object { "$_" })
$subs = @($cfg.suburbs)
# Top secondary school zones (config top_schools): suburbs each zone covers, rebuilt every 90 days or when the list changes.
$zf = "$root\school-zones.json"; $zones = ReadJson $zf; $topIds = @($cfg.top_schools | ForEach-Object { "$($_.id)" })
if ($topIds.Count -and (-not $zones -or ((Get-Date) - (Get-Item $zf).LastWriteTime).TotalDays -gt 90 -or (@($zones.schools.PSObject.Properties.Name) -join ',') -ne ($topIds -join ','))) {
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File "$sk\school-zones.ps1"; $zones = ReadJson $zf
}
# Latest report up to and including today (a same-day re-run builds on today's report).
$prevFile = Get-ChildItem "$root\reports\*.json" | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}\.json$' -and $_.BaseName -le $Date } | Sort-Object Name | Select-Object -Last 1
$prev = if ($prevFile) { ReadJson $prevFile.FullName } else { $null }
$prevById = @{}; foreach ($x in @($prev.shortlist)) { if ($x -and $x.id) { $prevById["$($x.id)"] = $x } }
# Minutes kept after the site checks stop, for building the report and the page data (~17,000 sites).
$reserve = 40
$log = New-Object System.Collections.ArrayList
function Log($s) { [void]$log.Add($s) }
# seen.json entries are objects (read back from JSON) or dictionaries (added this run): set a field on either.
function SeenSet($id, $k, $v) { $e = $seen[$id]; if ($e -is [Collections.IDictionary]) { $e[$k] = $v } else { $e | Add-Member $k $v -Force } }

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

# ---------- 2. Every active listing: the listings API, district by district, + mortgagee sales ----------
# One search stops at 10,000 results (page 500 on the website, offset 9,900 in the API) and Auckland has ~17,000
# listings, so the walk goes district by district (the largest has ~3,700). Each result is the full listing record.
$found = [ordered]@{}; $attrs = @{}; $walkOk = $true; $total = 0
# Only the fields the hunt uses are kept: full records (photos, agents, open homes...) for ~17,000 listings take GBs.
$keepA = 'price-display', 'auction-date', 'published-date', 'listing-status', 'website-full-url', 'listing-sub-type', 'bedroom-count', 'bathroom-count', 'land-area', 'floor-area', 'description', 'is-mortgagee-sale', 'is-private-listing', 'property-short-id'
function Slim($a) { if (-not $a) { return $null }; $o = [ordered]@{}; foreach ($k in $keepA) { $o[$k] = $a.$k }
    $ad = $a.address; $o['address'] = [pscustomobject]@{ 'full-address' = $ad.'full-address'; suburb = $ad.suburb; district = $ad.district; latitude = $ad.latitude; longitude = $ad.longitude }; [pscustomobject]$o }
function AddListing($x) { $i = "$($x.id)"; if ($i -and -not $found.Contains($i)) { $found[$i] = 1; $attrs[$i] = Slim $x.attributes } }
$q = 'filter%5Bcategory%5D%5B%5D=res_sale'
if (-not $SkipSearch) {
    $loc = GetJson "$API/locations?q=$searchPath"
    $dIds = @(@($loc.data | Where-Object { "$($_.id)" -eq "$apiRegion" }) | ForEach-Object { $_.relationships.districts.data } | ForEach-Object { "$($_.id)" } | Where-Object { $_ })
    foreach ($did in $dIds) {
        for ($off = 0; $off -le 9900; $off += 100) {
            $r = GetJson "$API/listings?$q&filter%5Bdistrict%5D%5B%5D=$did&page%5Blimit%5D=100&page%5Boffset%5D=$off"
            if (-not $r) { $walkOk = $false; break }
            foreach ($x in @($r.data)) { AddListing $x }
            if (@($r.data).Count -lt 100 -or $off + 100 -ge [int]$r.meta.totalResults) { break }
        }
    }
    $total = [int](GetJson "$API/listings?$q&filter%5Bregion%5D%5B%5D=$apiRegion&page%5Blimit%5D=1").meta.totalResults
    # Backup: if the district walk came up short, the website's search pages (newest first, up to 10,000) fill the gap.
    if (-not $dIds.Count -or $found.Count -lt $total * 0.98) {
        $walkOk = $false
        for ($p = 1; $p -le 500; $p++) {
            $h = GetHtml "https://www.realestate.co.nz/residential/sale/${searchPath}?by=latest&page=$p"
            $m = [regex]::Matches($h, '/(\d{8})/residential/sale/'); if (-not $m.Count) { break }
            foreach ($x in $m) { $i = $x.Groups[1].Value; if (-not $found.Contains($i)) { $found[$i] = 1 } }
        }
    }
    $mg = GetJson "$API/listings?$q&filter%5Bregion%5D%5B%5D=$apiRegion&filter%5BisMortgageeSale%5D=true&page%5Blimit%5D=50"
    foreach ($x in @($mg.data)) { AddListing $x }
} else {
    # Local re-run without searching: retry the listings still waiting for site checks.
    foreach ($k in @($seen.Keys)) { if ($seen[$k].outcome -eq 'pending') { $found[$k] = 1 } }
}
Log "Search: $($found.Count) active listings in $cityName$(if ($total) { " (realestate.co.nz shows $total)" })$(if (-not $walkOk) { '; the district walk had gaps, so the website search pages filled in' })"

# ---------- 3. Work list ----------
# Nothing is dropped: every active listing goes on the page. Zone, title, school and district rules only add
# rule_fails and flags (step 5), and the page filters on them. A listing whose site checks aren't done yet is still
# listed (basic listing facts, zone/flood "Not checked yet", checks_pending) and is checked in a later run.
# Site checks are cached one JSON line per site in site-checks.jsonl, so a stopped run resumes where it left off.
$checked = @{}; $errored = @{}; $cacheF = "$root\site-checks.jsonl"
function IsErrLine($ln) { $ln -match '^\{"id":"[^"]*","address":"(?:[^"\\]|\\.)*","error":' }
function LoadChecks($files) { foreach ($cf in @($files)) { if (-not (Test-Path $cf)) { continue }; foreach ($ln in [IO.File]::ReadAllLines($cf, $utf8)) { if ($ln.Trim()) { try { $x = $ln | ConvertFrom-Json; $i = "$($x.id)"; if ($x.error) { $errored[$i] = 1 } else { $checked[$i] = $x } } catch {} } } } }
# Worker files left by a stopped run go into the main cache first.
foreach ($f in @(Get-ChildItem "$root\site-checks-*.jsonl" -ErrorAction SilentlyContinue)) { [IO.File]::AppendAllText($cacheF, [IO.File]::ReadAllText($f.FullName, $utf8), $utf8); Remove-Item $f.FullName }
LoadChecks $cacheF
# A current check uses LINZ's address point (addr_check 2). Before Nov 2026 the checks used the listing's map pin, which
# can sit on the neighbour's title (45 Avondale Rd read a next-door cross lease), so those are redone once; until then
# the old result is shown.
function Fresh($id) { $c = $checked[$id]; $c -and [int]$c.addr_check -ge 2 }
# A listing not found by the walk (HTML backup or -SkipSearch) needs its record from the API.
foreach ($id in @($found.Keys)) { if (-not $attrs[$id] -and (MinLeft) -gt $reserve + 30) { $a = (GetJson "$API/listings/$id").data.attributes; if ($a -and "$($a.'listing-status')" -eq 'active') { $attrs[$id] = Slim $a } } }
# Work = every active listing except those already on the page with a current check (those are carried in step 6).
$work = New-Object Collections.Generic.List[string]
foreach ($id in $found.Keys) { $o = $prevById[$id]; if ($attrs[$id] -and -not ($o -and -not $o.checks_pending -and (Fresh $id))) { $work.Add($id) } }
# Check order: never-checked listings (newest first), then old map-pin checks (title failures first, as those are the
# likeliest to be wrong), then sites whose check failed before.
$q1 = New-Object Collections.Generic.List[string]; $q2 = New-Object Collections.Generic.List[string]; $q3 = New-Object Collections.Generic.List[string]; $q4 = New-Object Collections.Generic.List[string]
foreach ($id in $work) {
    if (Fresh $id) { continue }
    if ($checked.ContainsKey($id)) { if ("$($seen[$id].reason)" -match '(^|; )Title:') { $q2.Add($id) } else { $q3.Add($id) } }
    elseif ($errored.ContainsKey($id)) { $q4.Add($id) } else { $q1.Add($id) }
}
$todo = @(@($q1 | Sort-Object { "$($attrs[$_].'published-date')" } -Descending) + @($q2) + @($q3) + @($q4))
Log "To do: $($work.Count) listings to build, $($todo.Count) site checks waiting ($($q1.Count) never checked, $($q2.Count + $q3.Count) old map-pin checks to redo, $($q4.Count) failed before)"

# ---------- 4. Site checks (background) + property facts (meanwhile) ----------
# Uncached sites are split across 6 parallel check-site workers (~18 s per site each, so ~20 sites a minute); they run
# until the time budget's last $reserve minutes. Whatever isn't reached stays listed as checks pending.
function AddrOf($a) { (("$($a.address.'full-address')" -split ',')[0..1] -join ',').Trim() }
$procs = @(); $nW = 0
if ($todo.Count -and (MinLeft) -gt $reserve + 5) {
    # $nW, not $W: PowerShell names are case-insensitive, so $W and a loop's $w would be one variable.
    $nW = [math]::Min(6, $todo.Count)
    for ($w = 0; $w -lt $nW; $w++) {
        $csv = "$env:TEMP\hunt-sites-$w.csv"
        @(for ($i = $w; $i -lt $todo.Count; $i += $nW) { $a = $attrs[$todo[$i]]; [pscustomobject]@{ id = $todo[$i]; address = "$(AddrOf $a), $cityName"; lat = "$($a.address.latitude)"; lon = "$($a.address.longitude)" } }) | Export-Csv $csv -NoTypeInformation -Encoding UTF8
        $procs += Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$sk\check-site.ps1`"", '-InputCsv', "`"$csv`"", '-JsonLines', "`"$root\site-checks-$w.jsonl`"" -WindowStyle Hidden -PassThru
    }
}

$CLAD = [ordered]@{ 'Monolithic plaster/stucco' = '\b(plaster(ed)?|stucco|monolithic|EIFS|polystyrene)\b'; 'Harditex / fibre-cement sheet' = '\b(harditex|hardiflex|fibre[- ]?cement (sheet|board))\b'; 'Linea / fibre-cement weatherboard' = '\b(linea|hardiplank)\b'; 'Fibrolite (asbestos-era)' = '\b(fibrolite|super six|asbestos)\b'; 'Brick' = '\b(brick|clinker)\b'; 'Weatherboard (timber)' = '\b(weatherboards?|bevel[- ]?back|rusticated|cedar)\b'; 'Block / concrete' = '\b(concrete block|blockwork|solid concrete)\b'; 'Roughcast' = '\broughcast\b'; 'Board and batten' = '\bboard (and|&) batten\b' }
$ROOF = [ordered]@{ 'Tile (concrete/clay)' = '\b(tile roof|tiled roof|(brick|block|weatherboard) (and|&) tile|terracotta|concrete tiles?)\b'; 'Long-run iron / Colorsteel' = '\b(iron roof|corrugated|long[- ]?run|colou?rsteel|metal roof|(brick|weatherboard) (and|&) iron)\b'; 'Decramastic (pressed metal tile)' = '\b(decramastic|pressed metal tile)\b'; 'Butynol / membrane (flat roof)' = '\b(butynol|membrane roof|flat roof)\b' }
function D10($s) { $s = "$s"; if ($s.Length -ge 10) { $s.Substring(0, 10) } else { '' } }
# Time on market. A property that was withdrawn and relisted gets a new listing id and date; the property record lists
# its earlier listings (matched-listings), so the run walks back through earlier for-sale listings of the same property
# while each started within 180 days of the next one and no sale came in between.
function FirstListed($cur, $pa) {
    if (-not $pa -or -not $cur) { return $cur }
    $sold = D10 $pa.'latest-sale'.'sale-date'; $first = $cur
    $older = @(@($pa.'matched-listings') | Where-Object { $_ -and "$($_.'listing-category')" -eq 'res_sale' -and (D10 $_.'listing-published-date') -lt $cur } | Sort-Object { "$($_.'listing-published-date')" } -Descending)
    foreach ($m in $older) {
        $d = D10 $m.'listing-published-date'
        if ("$($m.'listing-status-id')" -eq '2' -or ($sold -and $d -le $sold) -or ([datetime]$first - [datetime]$d).TotalDays -gt 180) { break }
        $first = $d
    }
    $first
}
# A listing's record from the listing ($l), the property ($pa, or the facts kept on its previous record $old).
function NewCand($id, $l, $pa, $old) {
    $desc = (("$($l.description)") -replace '<[^>]+>', ' ' -replace '\s+', ' ')
    $usePrev = -not $pa -and $old -and $old.pf
    $ask = 0; $mm = [regex]::Match("$($l.'price-display')", '\$([\d,]+)'); if ($mm.Success) { $ask = [double]($mm.Groups[1].Value -replace ',', '') }
    $est = if ($pa) { $pa.'estimated-value' } else { $null }; $age = if ($pa) { "$($pa.'building-age')" } else { '' }
    $types = @(); if ($l.'is-mortgagee-sale' -or $desc -match 'mortgagee') { $types += 'Mortgagee sale' }; if ($l.'is-private-listing') { $types += 'Private sale' }
    if ($desc -match 'deceased estate|estate sale|executors?\b|estate of the late') { $types += 'Estate sale' }; if ($desc -match 'ex[- ]state|former state|state house|kainga ora|kāinga ora|housing new zealand') { $types += 'Ex-state home' }
    if ($desc -match 'must (be )?sell|motivated|instructions? to sell|overseas vendor|moving overseas|relocat') { $types += 'Motivated vendor' }
    # Keep the earliest listed date ever recorded for the site: a re-processed listing never resets it.
    $listed = D10 $l.'published-date'; if ($old -and $old.listed -and (-not $listed -or "$($old.listed)" -lt $listed)) { $listed = "$($old.listed)" }
    $since = if ($pa) { FirstListed $listed $pa } else { '' }; if ($old -and $old.on_market_since -and (-not $since -or "$($old.on_market_since)" -lt $since)) { $since = "$($old.on_market_since)" }
    $p = [pscustomobject]@{ id = $id; address = (AddrOf $l); suburb = "$($l.address.suburb)"; district = "$($l.address.district)"; url = "$($l.'website-full-url')"; source = 'realestate.co.nz'; status = 'new'; ptype = "$($l.'listing-sub-type')"
        price_text = ("$($l.'price-display')" + $(if ($l.'auction-date') { ' ' + ("$($l.'auction-date')" + '          ').Substring(0, 10).Trim() })); asking = $(if ($ask) { $ask } else { $null })
        beds = [int]$l.'bedroom-count'; baths = $l.'bathroom-count'; land_m2 = [double]$l.'land-area'
        floor_m2 = $(if ($pa) { $pa.'floor-area' } elseif ($usePrev) { $old.floor_m2 } else { $l.'floor-area' })
        decade_built = $(if ($pa) { if ($age -and $age -ne '0') { "${age}s" } else { '' } } elseif ($usePrev) { $old.decade_built } else { '' })
        cv = $(if ($pa) { [double]$pa.'council-information'.'capital-value' } elseif ($usePrev) { $old.cv } else { $null })
        land_value = $(if ($pa) { $pa.'council-information'.'land-value' } elseif ($usePrev) { $old.land_value } else { $null })
        estimate = $(if ($est) { [ordered]@{ low = $est.'value-low'; mid = $est.'value-mid'; high = $est.'value-high' } } elseif ($usePrev) { $old.estimate } else { $null })
        lat = $(if ($pa -and $pa.address.latitude) { $pa.address.latitude } elseif ($usePrev -and $old.lat) { $old.lat } elseif ("$($l.address.latitude)") { [double]"$($l.address.latitude)" } else { $null })
        lon = $(if ($pa -and $pa.address.longitude) { $pa.address.longitude } elseif ($usePrev -and $old.lon) { $old.lon } elseif ("$($l.address.longitude)") { [double]"$($l.address.longitude)" } else { $null })
        sale_type = $types
        materials = [ordered]@{ c = @($CLAD.Keys | Where-Object { $desc -match $CLAD[$_] }); r = @($ROOF.Keys | Where-Object { $desc -match $ROOF[$_] }); reclad = $desc -match 're-?clad'; ccc = $desc -match '\bCCC\b|code compliance' }
        consent = $(if ($desc -match 'resource consent|consented for|RC (approved|granted)') { $true } else { $false }); desc_flags = @()
        listed = $listed
        # pf: the property's facts are in (property lookup done, kept from before, or no property record to look up).
        pf = [bool]($pa -or $usePrev -or -not $l.'property-short-id') }
    if ($since -and $since -lt $listed) { $p | Add-Member on_market_since $since }
    $p
}
# Property facts (CV, estimate, floor area, build age, earlier listings): one lookup per site, done while the checks run.
# Sites already checked come first, then the check queue's order; sites whose earlier record has them reuse those.
$cands = @{}; $nFacts = 0; $inTodo = @{}; foreach ($id in $todo) { $inTodo[$id] = 1 }
$factOrder = @(@($work | Where-Object { -not $inTodo[$_] }) + @($todo))
foreach ($id in $factOrder) {
    if ((MinLeft) -lt $reserve) { break }
    $l = $attrs[$id]; $old = $prevById[$id]; $pa = $null
    if (-not ($old -and $old.pf) -and $l.'property-short-id') { $pa = (GetJson "$API/properties/$($l.'property-short-id')").data.attributes; $nFacts++ }
    $cands[$id] = NewCand $id $l $pa $old
}
Log "Property facts: $nFacts looked up, $($cands.Count) of $($work.Count) listings ready ($([math]::Round(((Get-Date) - $started).TotalMinutes)) min in)"

# Stop the checkers in time to build and save the report; each finished site is already written to its file.
if ($procs.Count) {
    $waitS = [int][math]::Max(30, ((MinLeft) - $reserve) * 60)
    try { $procs | Wait-Process -Timeout $waitS -ErrorAction Stop } catch { }
    $late = @($procs | Where-Object { -not $_.HasExited }); if ($late.Count) { $late | Stop-Process -Force; Log "Site checks stopped at the time limit; the rest continue next run" }
    for ($w = 0; $w -lt $nW; $w++) { $f = "$root\site-checks-$w.jsonl"; if (Test-Path $f) { LoadChecks $f; [IO.File]::AppendAllText($cacheF, [IO.File]::ReadAllText($f, $utf8), $utf8); Remove-Item $f } }
}
# One line per site in the cache (its newest good result), so re-checks don't make it grow.
if (Test-Path $cacheF) {
    $keepL = [ordered]@{}
    foreach ($ln in [IO.File]::ReadAllLines($cacheF, $utf8)) { if ($ln -match '^\{"id":"([^"]*)"') { $i = $Matches[1]; if (-not (IsErrLine $ln) -or -not $keepL.Contains($i) -or (IsErrLine $keepL[$i])) { $keepL[$i] = $ln } } }
    if ($keepL.Count) { [IO.File]::WriteAllText("$cacheF.tmp", (($keepL.Values -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false))); Move-Item "$cacheF.tmp" $cacheF -Force }
}
$doneToday = @($todo | Where-Object { Fresh $_ }).Count
Log "Site checks: $doneToday of $($todo.Count) done today ($([math]::Round(((Get-Date) - $started).TotalMinutes)) min in)"

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
$newItems = New-Object Collections.Generic.List[object]; $built = @{}; $nPending = 0; $rejected = [Collections.ArrayList]@(); $schoolRej = [Collections.ArrayList]@()
$today0 = [datetime]$Date
foreach ($id in $work) {
    $l = $attrs[$id]; $old = $prevById[$id]
    $p = $cands[$id]; if (-not $p) { $p = NewCand $id $l $null $old }
    # Status: a price change against the site's previous record; 'new' only for a listing first seen and listed this week.
    if ($old) { if ("$($p.price_text)" -ne "$($old.price_text)" -and "$($old.price_text)" -notmatch 'was asking') { $p.status = 'price_change'; $p | Add-Member price_text_prev $old.price_text -Force } else { $p.status = 'still_listed' } }
    elseif ($seenBefore[$id] -or -not $p.listed -or ($today0 - [datetime]$p.listed).TotalDays -gt 7) { $p.status = 'still_listed' }
    if (-not $seen.ContainsKey($id)) { $seen[$id] = [ordered]@{ address = "$($l.address.'full-address')"; url = $p.url; first_seen = $Date; last_seen = $Date; price_text = "$($l.'price-display')"; outcome = 'pending'; reason = $null } }
    else { SeenSet $id 'last_seen' $Date; SeenSet $id 'price_text' "$($l.'price-display')" }
    $c = $checked[$id]
    if (-not $c) {
        if ($old -and -not $old.checks_pending) { continue }   # its earlier full record is carried in step 6 until the check is done
        # Site checks pending: listed with the listing's own facts; zone, title, flood and schools come in a later run.
        $p | Add-Member checks_pending $true -Force
        $p | Add-Member zone 'Not checked yet' -Force
        $p | Add-Member flood 'Not checked yet' -Force
        $p | Add-Member rule_fails @() -Force
        $p | Add-Member flags @() -Force
        $p | Add-Member school ([ordered]@{ name = 'Not checked yet'; band = 'Unknown' }) -Force
        $p | Add-Member dev_angle "$(if ($p.land_m2) { "$([math]::Round($p.land_m2)) m² " })$(if ($p.ptype) { "$($p.ptype)".ToLower() } else { 'site' }); zoning, title, flood and schools not checked yet." -Force
        $p | Add-Member why '' -Force
        $p | Add-Member questions @('What is the vendor''s price expectation?', 'Is the title freehold with no covenants limiting dwellings?') -Force
        $p | Add-Member weekly_rent $(if ($CHC) { switch ([int]$p.beds) { 2 { 500 } 3 { 590 } 4 { 690 } default { 760 } } } else { switch ([int]$p.beds) { 2 { 600 } 3 { 700 } 4 { 800 } default { 850 } } }) -Force
        SeenSet $id 'outcome' 'pending'
        $newItems.Add($p); $built[$id] = 1; $nPending++; continue
    }
    if ($c.addr_point -eq 'linz') { $p.lat = $c.lat; $p.lon = $c.lon }   # map pin on the right parcel
    $flags = @()
    foreach ($k in 'zone', 'schools', 'services', 'transport', 'state_housing', 'motorway', 'land', 'power_lines') { $p | Add-Member $k $c.$k -Force }
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
    if ($cfg.district_name -and $p.district -and "$($p.district)" -ne "$($cfg.district_name)") { $fails += "Outside $($cfg.district_name)" }   # shown and filterable, never dropped
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
    SeenSet $p.id 'outcome' $(if ($fails.Count) { 'listed_fails_rules' } else { 'shortlisted' }); SeenSet $p.id 'reason' $(if ($fails.Count) { $fails -join '; ' } else { $null })
    $newItems.Add($p); $built[$id] = 1
}

# ---------- 6. Carry forward the rest of the previous list (status + price changes) ----------
# Listings found by today's walk are active, and their record came with it; the rest are looked up one by one
# (sold, withdrawn, or missed by the walk).
$carried = New-Object Collections.Generic.List[object]; $gone = @(); $soldOut = ToHash (ReadJson "$root\sold-outcomes.json").sold
foreach ($p in @($prev.shortlist | Where-Object { $_ -and $_.id })) {
    $id = "$($p.id)"; if ($built[$id]) { continue }
    $l = $attrs[$id]; if (-not $l) { $l = (GetJson "$API/listings/$id").data.attributes }
    if (-not $l) { $carried.Add($p); continue }   # lookup failed: keep it as it was, try again tomorrow
    if ($l.'listing-status' -eq 'active') {
        $pt = "$($l.'price-display')" + $(if ($l.'auction-date') { ' ' + ("$($l.'auction-date')" + '          ').Substring(0, 10).Trim() })
        if ($pt -ne "$($p.price_text)" -and $p.price_text -notmatch 'was asking') { $p.status = 'price_change'; $p | Add-Member price_text_prev $p.price_text -Force; $p.price_text = $pt
            $mm = [regex]::Match("$($l.'price-display')", '\$([\d,]+)'); $p.asking = $(if ($mm.Success) { [double]($mm.Groups[1].Value -replace ',', '') } else { $null }) }
        else { $p.status = 'still_listed' }
        if (-not $p.listed -and $l.'published-date') { $p | Add-Member listed (D10 $l.'published-date') -Force }
        if ($seen[$id]) { SeenSet $id 'last_seen' $Date }
        $carried.Add($p)
    } else {
        $pa = if ($l.'property-short-id') { (GetJson "$API/properties/$($l.'property-short-id')").data.attributes } else { $null }
        $s = $pa.'latest-sale'; $listed = "$($l.'published-date')".Substring(0, [math]::Min(10, "$($l.'published-date')".Length))
        $rec = [ordered]@{ address = $p.address; status = "$($l.'listing-status')"; checked = $Date; sale_date = $null; sale_price = $null; cv = $p.cv; expected = $p.pricing.expected; low = $p.pricing.low_case }
        if ($s -and $s.'sale-date' -ge $listed) { $rec.sale_date = $s.'sale-date'; $rec.sale_price = $s.'sale-price'; if ($p.cv) { $rec.sale_vs_cv = [math]::Round($s.'sale-price' / $p.cv, 3) }; if ($p.pricing.expected) { $rec.sale_vs_expected = [math]::Round($s.'sale-price' / $p.pricing.expected, 3) } }
        if ($seen[$id]) { SeenSet $id 'outcome' 'off_market' }
        $soldOut[$id] = $rec; $gone += $rec
    }
}
WriteJson "$root\sold-outcomes.json" ([ordered]@{ last_checked = $Date; sold = $soldOut })
foreach ($g in $gone) { Log ("Off the market: {0} ({1}){2}" -f $g.address, $g.status, $(if ($g.sale_price) { ", sold $($g.sale_price.ToString('N0'))$(if ($g.sale_vs_cv) { " = $([math]::Round(100 * $g.sale_vs_cv))% of CV" })" + $(if ($g.sale_vs_expected) { ", $([math]::Round(100 * ($g.sale_vs_expected - 1)))% vs our expected" }) } else { ', sale price not yet published' })) }

# ---------- 7. Build, render, email ----------
$all = @($carried.ToArray()) + @($newItems.ToArray())
# Time on market: information and a page filter only. Long-listed sites get a flag (the flag doesn't cost score points).
$today = [datetime]$Date
foreach ($p in $all) {
    $p | Add-Member starred ($starred -contains "$($p.id)") -Force
    $since = if ($p.on_market_since) { "$($p.on_market_since)" } else { "$($p.listed)" }
    $fl = @(@($p.flags) | Where-Object { $_ -and "$_" -notmatch '^On the market over 6 months' })
    if ($since -match '^\d{4}-\d{2}-\d{2}$' -and ($today - [datetime]$since).TotalDays -gt 182) { $fl += "On the market over 6 months (since $since$(if ($p.on_market_since) { ', counting earlier listings of this property' })): may have issues, find out why it hasn't sold" }
    $p | Add-Member flags @($fl) -Force
}
$needs = @($all | Where-Object { -not $_.slope -and -not $slopes[$_.id] } | ForEach-Object { [ordered]@{ id = $_.id; lat = $_.lat; lon = $_.lon } })
foreach ($p in $all) { if (-not $p.slope -and $slopes[$p.id]) { $p | Add-Member slope $slopes[$p.id] -Force } }
WriteJson "$root\needs-slope.json" @($needs) 3
$run = [ordered]@{
    summary = "$($all.Count) sites listed: $(@($all | Where-Object { $_.status -eq 'new' }).Count) new today, $nPending waiting for site checks$(if ($gone.Count) { ", $($gone.Count) off the market" })."
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
"DATE $Date | shortlist $(@($rep.shortlist).Count) | new $(@($all | Where-Object { $_.status -eq 'new' }).Count) | pending $nPending | gone $($gone.Count) | needs-slope $($needs.Count) | starred $($starred.Count)"
$log | ForEach-Object { "- $_" }
"TOP:"; @($rep.shortlist) | Select-Object -First 5 | ForEach-Object { "  $($_.score) $($_.address) | $([math]::Round($_.pricing.expected/1000))k $($_.pricing.fit)$(if ($_.status -eq 'new') { ' | NEW' })$(if ($_.status -eq 'price_change') { ' | PRICE CHANGE' })" }
$st = @($rep.shortlist | Where-Object { $_.starred -and $_.status -eq 'price_change' }); if ($st.Count) { "STARRED PRICE CHANGES:"; $st | ForEach-Object { "  $($_.address): $($_.price_text_prev) -> $($_.price_text)" } }
"FILES: reports\report.html + reports\data.json (publish), reports\email-$Date.html (send)"
