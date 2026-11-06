<#
  Turns the run's screened candidates into reports\<Date>.json: adds pricing, finance numbers, growth outlook, score and label.
  Usage: powershell -NoProfile -File build-report.ps1 -Candidates run.json -Date 2026-10-31

  run.json shape:
  {
    "summary": "...", "sources": [...], "notes": [...], "rejected": [...], "school_rejects": [...],
    "shortlist": [ { id, address, suburb, url, source, status, price_text, asking (number or null),
                     beds, baths, land_m2, floor_m2, title, title_estate, decade_built, cv, land_value,
                     estimate {low,mid,high}, zone, lat, lon, school {name, band}, schools, services, transport, flood,
                     weekly_rent, dev_angle, why, flags [], questions [] } ]
  }
  Assumptions mirror profile.md; pass overrides if the profile changes.
#>
param(
    [Parameter(Mandatory = $true)][string]$Candidates,
    [Parameter(Mandatory = $true)][string]$Date,
    [double]$DepositPct = 0.20,
    [double]$Rate = 0.05,
    [int]$Years = 30,
    [double]$MaxPrice = 1100000,
    [double]$IdealHigh = 900000,
    [double]$StretchPct = 0.15,
    [double]$BuildPerM2 = 3500,
    [double]$SecondDwellingM2 = 90,
    [double]$SubdivisionCost = 120000
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.Encoding]::UTF8
$run = [IO.File]::ReadAllText($Candidates, $utf8) | ConvertFrom-Json

$r = $Rate / 52; $n = $Years * 52
$factor = $r / (1 - [math]::Pow(1 + $r, -$n))

# Real sale-price / CV ratios from recent sales (market-ratios.json, refreshed monthly by collect-sales.js).
# Data folder: HUNT_ROOT when set (the cloud run), else the local folder.
function HuntRoot { if ($env:HUNT_ROOT) { $env:HUNT_ROOT } else { 'C:\Claude\Personal\property-hunt' } }
$ratiosFile = "$(HuntRoot)\market-ratios.json"
$ratios = if (Test-Path $ratiosFile) { [IO.File]::ReadAllText($ratiosFile, $utf8) | ConvertFrom-Json } else { $null }
# Suburb price history, infrastructure catalysts and the 5-year outlook method (market-growth.json).
$growthFile = "$(HuntRoot)\market-growth.json"
$growth = if (Test-Path $growthFile) { [IO.File]::ReadAllText($growthFile, $utf8) | ConvertFrom-Json } else { $null }

function Get-Slug([string]$suburb) { ($suburb.ToLower() -replace '^st\.? ', 'saint ' -replace '^mt\.? ', 'mount ' -replace '[^a-z]+', '-').Trim('-') }

# Suburb-specific ratios (never one Auckland-wide figure unless a suburb has no sales at all).
# Likely = suburb median sale/CV for 600 m2+ sites (or all houses if <8 big sales).
# Low case = suburb bottom-quartile (p25) sale/CV for the same group: a realistic discount, not the extreme bottom 10%.
function Get-Ratios([string]$slug, [double]$land) {
    $s = if ($ratios) { $ratios.suburbs.$slug } else { $null }
    $a = if ($ratios) { $ratios.all } else { $null }
    $useBig = $s -and $land -ge 600 -and $s.big_n -ge 8
    $likely = if ($useBig) { $s.big_median } elseif ($s -and $s.n -ge 5) { $s.median } elseif ($a) { if ($land -ge 600) { $a.big_median } else { $a.median } } else { 1 }
    $low = if ($useBig -and $s.big_p25) { $s.big_p25 } elseif ($s -and $s.n -ge 5 -and $s.p25) { $s.p25 } elseif ($a) { $a.big_p25 } else { 0.85 }
    $basis = if ($useBig) { "$slug, $($s.big_n) sales of 600 m²+ in 12 months" } elseif ($s -and $s.n -ge 5) { "$slug, $($s.n) house sales in 12 months" } else { 'Auckland-wide (too few local sales)' }
    [pscustomobject]@{ likely = [double]$likely; low = [double]$low; basis = $basis }
}

function Get-Growth([string]$slug, $transport) {
    if (-not $growth) { return $null }
    $m = $growth.outlook_method
    $hist = $growth.suburbs.$slug
    $keys = @($growth.suburb_catalysts.$slug)
    $drivers = @($keys | Where-Object { $_ } | ForEach-Object { $growth.catalysts.$_ })
    $train = if ($transport -and $transport.train) { [double]$transport.train.distance_m } else { 99999 }
    $cbd = if ($transport) { [double]$transport.cbd_km } else { 99 }
    $outlook = [double]$m.base_5y_pct
    if ($train -le 800) { $outlook += $m.train_premium_5y_pct.within_800m; $drivers = @("Train station $([math]::Round($train)) m away: rail catchments have outgrown Auckland by ~7 points a decade") + $drivers }
    elseif ($train -le 1500) { $outlook += $m.train_premium_5y_pct.'800_to_1500m'; $drivers = @("Train station $([math]::Round($train)) m away") + $drivers }
    if ($keys -contains 'eastern_busway') { $outlook += $m.busway_premium_5y_pct }
    if ($cbd -le 10 -and $train -le 1500) { $drivers += $growth.catalysts.pc120_10km }
    [ordered]@{
        outlook_5y_pct = [math]::Round($outlook, 1)
        outlook_low_pct = [math]::Round($outlook - $m.range_pct, 1)
        outlook_high_pct = [math]::Round($outlook + $m.range_pct, 1)
        suburb_12m_pct = $(if ($hist) { $hist.chg_12m_pct }); suburb_10y_pct = $(if ($hist) { $hist.chg_10y_pct })
        suburb_from_peak_pct = $(if ($hist) { $hist.from_2021_peak_pct }); suburb_median = $(if ($hist) { $hist.median_last12 })
        drivers = @($drivers | Select-Object -Unique)
    }
}

# Construction materials and their known NZ issues (cladding/roof from the listing; era-based risks when not stated).
$riskText = @{
    'Monolithic plaster/stucco'         = 'Leaky-home risk, especially 1990s–2005 builds without a cavity: get a weathertightness survey with moisture testing.'
    'Harditex / fibre-cement sheet'     = 'Same leaky-home risk as plaster when direct-fixed (mid-1990s–2004); pre-1985 sheet can contain asbestos.'
    'Fibrolite (asbestos-era)'          = 'Asbestos-cement: never cut or drill; licensed removal needed before demolition (budget ~$10–30k+).'
    'Roughcast'                         = 'Older roughcast over timber can hide moisture damage behind it; check framing.'
    'Weatherboard (timber)'             = 'Generally sound and easy to repair; check for rot, paint condition and borer in older boards.'
    'Linea / fibre-cement weatherboard' = 'Modern fibre-cement weatherboard, generally fine when installed over a cavity.'
    'Brick'                             = 'Low-maintenance; check brick ties and cracking on older veneer.'
    'Block / concrete'                  = 'Durable; check for damp and efflorescence in older block.'
    'Board and batten'                  = 'Check joints and lower edges for moisture.'
    'Tile (concrete/clay)'              = 'Durable; check broken tiles, ridge pointing and underlay.'
    'Long-run iron / Colorsteel'        = 'Check rust and fixings; re-roof roughly every 30–40 years.'
    'Decramastic (pressed metal tile)'  = '1960s–80s pressed-metal tiles lose their chip coat and rust; often need replacing (~$20–40k).'
    'Butynol / membrane (flat roof)'    = 'Flat or membrane roofs leak more often; check age, falls and outlets.'
    'Slate'                             = 'Long-lasting but expensive to repair.'
}
function Get-Materials($p) {
    $m = $p.materials; $clad = @($m.c | Where-Object { $_ }); $roof = @($m.r | Where-Object { $_ })
    $dec = [int](("$($p.decade_built)") -replace '\D', '' -replace '^$', '0')
    $issues = @(); foreach ($x in $clad + $roof) { if ($riskText[$x]) { $issues += "${x}: $($riskText[$x])" } }
    $level = 'Low'
    if ($clad -match 'Monolithic|Harditex' -and ($dec -eq 0 -or ($dec -ge 1990 -and $dec -le 2000)) -and -not $m.reclad) { $level = 'High' }
    elseif ($clad -match 'Fibrolite|Roughcast' -or $roof -match 'Decramastic|Butynol') { $level = 'Medium' }
    if ($dec -ge 1990 -and $dec -le 2000 -and -not $clad.Count) { $issues += "Built in the ${dec}s (leaky-home era) and the cladding isn't stated: confirm it's not monolithic plaster or direct-fixed sheet."; if ($level -eq 'Low') { $level = 'Medium' } }
    if ($dec -gt 0 -and $dec -lt 1990) { $issues += 'Built before 1990: asbestos is possible in soffits, linings, vinyl and textured ceilings; an asbestos survey is needed before demolition or major renovation.' }
    if ($dec -gt 0 -and $dec -lt 1940) { $issues += 'Pre-1940 house: check wiring, piles, borer, and any pre-1940 demolition or character controls.' }
    if (-not $clad.Count -and -not $roof.Count) { $issues += 'Materials not stated in the listing: ask the agent or check the photos and builder''s report.' }
    [ordered]@{ cladding = $clad; roof = $roof; risk = $level; issues = $issues; reclad = [bool]$m.reclad; ccc_mentioned = [bool]$m.ccc }
}

# Feasibility studies already done (site-feasibility skill), keyed by listing id.
$feas = @{}
$fi = "$(HuntRoot)\feasibility\index.json"
if (Test-Path $fi) { ([IO.File]::ReadAllText($fi, $utf8) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { if ($_.Value.listing_id) { $feas["$($_.Value.listing_id)"] = $_.Value } } }

foreach ($p in $run.shortlist) {
    $slug = Get-Slug "$($p.suburb)"
    $p | Add-Member -NotePropertyName construction -NotePropertyValue (Get-Materials $p) -Force
    if ($feas["$($p.id)"]) { $p | Add-Member -NotePropertyName feasibility -NotePropertyValue $feas["$($p.id)"] -Force }
    # Expected price: asking if given; otherwise the average of the AVM estimate and CV x the suburb's real sale/CV ratio.
    $rt = Get-Ratios $slug ([double]$p.land_m2)
    $cvLikely = if ($p.cv) { [double]$p.cv * $rt.likely } else { 0 }
    $lowCase = if ($p.cv) { [double]$p.cv * $rt.low } else { 0 }
    # Never above the bottom of the site's own estimate range.
    if ($p.estimate -and $p.estimate.low -and ($lowCase -eq 0 -or [double]$p.estimate.low -lt $lowCase)) { $lowCase = [double]$p.estimate.low }
    if ($p.asking) { $price = [double]$p.asking; $basis = 'asking' }
    elseif ($p.estimate -and $p.estimate.mid -and $cvLikely) { $price = ([double]$p.estimate.mid + $cvLikely) / 2; $basis = 'estimate + recent sales' }
    elseif ($p.estimate -and $p.estimate.mid) { $price = [double]$p.estimate.mid; $basis = 'estimate' }
    elseif ($cvLikely) { $price = $cvLikely; $basis = 'recent sales vs CV' }
    else { $price = [double]$p.cv; $basis = 'CV' }
    $fit = if ($price -le $IdealHigh) { 'Ideal range' } elseif ($price -le $MaxPrice) { 'In budget' }
           elseif ($lowCase -and $lowCase -le $MaxPrice) { 'Possible: below CV' }
           elseif ($price -le $MaxPrice * (1 + $StretchPct)) { 'Stretch: slightly over' } else { 'Over budget' }
    $p | Add-Member -NotePropertyName pricing -NotePropertyValue ([ordered]@{
        expected = [math]::Round($price); low_case = [math]::Round($lowCase); cv_x_ratio = [math]::Round($cvLikely)
        ratio_likely = $rt.likely; ratio_low = $rt.low; ratio_basis = $rt.basis; fit = $fit }) -Force

    $deposit = $price * $DepositPct; $loan = $price - $deposit
    $rent = [double]$p.weekly_rent
    $lvShare = if ($p.cv) { 100 * [double]$p.land_value / [double]$p.cv } else { 0 }
    $numbers = [ordered]@{
        deposit              = [math]::Round($deposit)
        loan                 = [math]::Round($loan)
        weekly_repayment     = [math]::Round($loan * $factor)
        weekly_rent          = $rent
        gross_yield_pct      = if ($price) { [math]::Round(100 * $rent * 52 / $price, 2) } else { 0 }
        land_value_share_pct = [math]::Round($lvShare, 1)
        second_dwelling_cost = [math]::Round($BuildPerM2 * $SecondDwellingM2 + $SubdivisionCost)
    }
    $g = Get-Growth $slug $p.transport
    $p | Add-Member -NotePropertyName growth -NotePropertyValue $g -Force

    # ---- Score (raw points, then scaled to 0-100) ----
    $zone = "$($p.zone)"
    $sZone = if ($zone -match 'Terrace Housing') { 25 } elseif ($zone -match 'Mixed Housing Urban') { 20 } elseif ($zone -match 'Mixed Housing Suburban') { 14 } else { 0 }
    $land = [double]$p.land_m2
    $sLand = if ($land -ge 850) { 20 } elseif ($land -ge 750) { 17 } elseif ($land -ge 650) { 14 } elseif ($land -ge 600) { 10 } else { 4 }
    $sPrice = switch -Wildcard ($fit) { 'Ideal*' { 20 } 'In budget' { 14 } 'Possible*' { 8 } 'Stretch*' { 5 } default { 0 } }
    if ($lowCase -and $lowCase -le $IdealHigh) { $sPrice += 3 }
    $sSchool = switch ("$($p.school.band)") { 'High' { 15 } 'Medium' { 9 } default { 3 } }
    $sLv = if ($lvShare -ge 90) { 10 } elseif ($lvShare -ge 80) { 7 } else { 4 }
    $sv = $p.services; $sServices = 0
    if ($sv -and $sv.wastewater -and $null -ne $sv.wastewater.distance_m) { $sServices += $(if ($sv.wastewater.distance_m -le 5) { 3 } elseif ($sv.wastewater.distance_m -le 20) { 2 } else { 0 }) }
    if ($sv -and $sv.stormwater -and $null -ne $sv.stormwater.distance_m) { $sServices += $(if ($sv.stormwater.distance_m -le 5) { 2 } elseif ($sv.stormwater.distance_m -le 20) { 1 } else { 0 }) }
    # Location: closer to the CBD first, then train stations (much more than bus stops).
    $tr = $p.transport
    $cbd = if ($tr) { [double]$tr.cbd_km } else { 99 }
    $sCbd = if ($cbd -le 5) { 15 } elseif ($cbd -le 7) { 12 } elseif ($cbd -le 9) { 9 } elseif ($cbd -le 11) { 6 } elseif ($cbd -le 14) { 3 } else { 0 }
    $trainM = if ($tr -and $tr.train) { [double]$tr.train.distance_m } else { 99999 }
    $sTrain = if ($trainM -le 800) { 10 } elseif ($trainM -le 1200) { 7 } elseif ($trainM -le 2000) { 4 } else { 0 }
    $sBus = if ($tr -and $tr.bus -and $null -ne $tr.bus.distance_m -and $tr.bus.distance_m -le 400) { 1 } else { 0 }
    $sGrowth = if ($g) { [math]::Max(0, [math]::Min(5, [math]::Round(($g.outlook_5y_pct - 9) * 1.2))) } else { 0 }
    # Slope drives development cost (retaining, earthworks, access): flat helps, steep hurts.
    $sSlope = switch ("$($p.slope.class)") { 'Flat' { 3 } 'Gentle' { 1 } 'Moderate' { -3 } 'Steep' { -7 } default { 0 } }
    # Sale types that usually sell below market.
    $types = @($p.sale_type)
    $sSale = 0
    if ($types -match 'Mortgagee') { $sSale += 4 }; if ($types -match 'Estate') { $sSale += 3 }
    if ($types -match '^Private sale') { $sSale += 3 } elseif ($types -match 'Possible private') { $sSale += 1 }
    if ($types -match 'Ex-state') { $sSale += 1 }; if ($types -match 'Motivated') { $sSale += 1 }
    $sSale = [math]::Min($sSale, 6)
    # Land shape, frontage and access.
    $ld = $p.land; $sLand2 = 0
    if ($ld -and $ld -isnot [string]) {
        if ($ld.shape -match '^(Rectangle|Square)') { $sLand2 += 2 } elseif ($ld.shape -match 'Triangle|Irregular') { $sLand2 -= 2 }
        if ($ld.position -match 'corner') { $sLand2 += 2 }
        if ($ld.position -match '^Road front' -and $ld.frontage_m -ge 15) { $sLand2 += 1 } elseif ($ld.position -match '^Road front' -and $ld.frontage_m -lt 10) { $sLand2 -= 1 }
        if ($null -ne $ld.access_width_m) { if ($ld.access_width_m -lt 3.5) { $sLand2 -= 4 } } elseif ($ld.position -match '^Rear') { $sLand2 -= 2 }
    }
    # Motorway access.
    $mw = $p.motorway; $sMw = 0
    if ($mw -and $mw.on_ramp) { $sMw = if ($mw.on_ramp.distance_km -le 2) { 2 } elseif ($mw.on_ramp.distance_km -le 4) { 1 } else { 0 } }
    # Construction risk.
    $sMat = switch ($p.construction.risk) { 'High' { -5 } 'Medium' { -2 } default { 0 } }
    # Flood and state-housing concentration are shown, not hidden, but cost points.
    $sh = "$($p.state_housing.level)"
    $penalty = 3 * @($p.flags).Count + $(if ($p.flood -match 'plain|prone') { 6 } else { 0 }) + $(switch ($sh) { 'High' { 8 } 'Medium' { 3 } default { 0 } })
    # High-voltage lines: over the site or in the grid corridor limits where you can build.
    $penalty += switch ("$($p.power_lines.level)") { 'Over site' { 10 } 'In grid corridor' { 8 } 'Within 40 m' { 3 } default { 0 } }
    $raw = $sZone + $sLand + $sPrice + $sSchool + $sLv + $sServices + $sCbd + $sTrain + $sBus + $sGrowth + $sSlope + $sSale + $sLand2 + $sMw + $sMat - $penalty
    $maxRaw = 25 + 20 + 23 + 15 + 10 + 5 + 15 + 10 + 1 + 5 + 3 + 6 + 5 + 2
    $score = [math]::Max(0, [math]::Min(100, [math]::Round(100 * $raw / $maxRaw)))

    $p | Add-Member -NotePropertyName price_used -NotePropertyValue ([math]::Round($price)) -Force
    $p | Add-Member -NotePropertyName price_basis -NotePropertyValue $basis -Force
    $p | Add-Member -NotePropertyName numbers -NotePropertyValue $numbers -Force
    $p | Add-Member -NotePropertyName score -NotePropertyValue ([int]$score) -Force
    $p | Add-Member -NotePropertyName label -NotePropertyValue $(if (@($p.rule_fails | Where-Object { $_ }).Count) { 'Outside your rules' } elseif ($fit -match 'Stretch|Over') { 'Stretch' } elseif ($score -ge 60) { 'Strong' } elseif ($score -ge 45) { 'Worth a look' } else { 'Marginal' }) -Force
}

$run | Add-Member -NotePropertyName run_date -NotePropertyValue $Date -Force
$run.shortlist = @($run.shortlist | Sort-Object { - $_.score })

$out = "$(HuntRoot)\reports\$Date.json"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
[IO.File]::WriteAllText($out, ($run | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
$run.shortlist | ForEach-Object { '{0,3}  {1,-13} {2}' -f $_.score, $_.label, $_.address }
Write-Output $out
