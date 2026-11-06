<#
  Builds the full report as email-safe HTML (tables, links, headings only — no styles or images), so anyone can read it
  without a Claude account. Writes reports\email-<Date>.html and prints its path.
  Usage: powershell -NoProfile -File render-email.ps1 -Date 2026-10-31 [-MarketNote "..."]
#>
param([Parameter(Mandatory = $true)][string]$Date, [string]$MarketNote = '', [int]$Detailed = 8, [switch]$Full)
$Short = -not $Full

$ErrorActionPreference = 'Stop'
$utf8 = [Text.Encoding]::UTF8
# Data folder: HUNT_ROOT when set (the cloud run), else the local folder.
function HuntRoot { if ($env:HUNT_ROOT) { $env:HUNT_ROOT } else { 'C:\Claude\Personal\property-hunt' } }
$reports = "$(HuntRoot)\reports"
$run = [IO.File]::ReadAllText((Join-Path $reports "$Date.json"), $utf8) | ConvertFrom-Json
$cfg = [IO.File]::ReadAllText("$(HuntRoot)\config.json", $utf8) | ConvertFrom-Json

function Enc([object]$s) { [Net.WebUtility]::HtmlEncode("$s") }
function Money($n) { if ($n) { '$' + ('{0:N0}' -f [double]$n) } else { '—' } }
function K($n) { if (-not $n) { '—' } elseif ($n -ge 1e6) { '$' + ('{0:N2}' -f ($n / 1e6)) + 'm' } else { '$' + [math]::Round($n / 1000) + 'k' } }
function Dist($m) { if ($null -eq $m) { '—' } elseif ($m -ge 1000) { ('{0:N1}' -f ($m / 1000)) + ' km' } else { "$([math]::Round($m)) m" } }
function Pct($v) { if ($null -eq $v) { '—' } elseif ($v -gt 0) { "+$v%" } else { "$v%" } }
function Svc($s) {
    if (-not $s -or $s -is [string]) { 'Unknown' }
    elseif ($s.on_site) { "On site$(if ($s.diameter_mm) { " ($($s.diameter_mm) mm)" })" }
    elseif ($null -eq $s.distance_m) { 'None found within 80 m' }
    else { "$([math]::Round($s.distance_m)) m away$(if ($s.diameter_mm) { " ($($s.diameter_mm) mm)" })" }
}
function Schools($z) {
    if (-not $z) { return 'Unknown' }
    $rows = foreach ($lvl in 'primary', 'intermediate', 'secondary') {
        foreach ($s in @($z.$lvl) | Where-Object { $_ -and $_.name }) {
            $basis = if ("$($s.ncea_l3_pct)" -match '^[\d.]+$') { "NCEA L3 $($s.ncea_l3_pct)%" } elseif ("$($s.eqi)" -match '^\d+$') { "EQI $($s.eqi)" } else { '' }
            $integ = if ("$($s.authority)" -match 'Integrated') { ' [state-integrated, own enrolment]' } else { '' }
            "$((Get-Culture).TextInfo.ToTitleCase($lvl)): <a href=`"$(Enc $s.ero)`">$(Enc $s.name)</a>$integ <b>$(Enc $s.band)</b>$(if ($basis) { " ($basis)" })"
        }
    }
    if ($rows) { $rows -join '<br>' } else { 'No zones found' }
}

function Site($p) {
    $pr = $p.pricing; $tr = $p.transport; $sh = $p.state_housing; $g = $p.growth
    $status = if ($p.status -eq 'new') { ' (new)' } elseif ($p.status -eq 'price_change') { ' (price change)' } else { '' }
    $rows = @(
        @('Price', "$(Enc $p.price_text)<br>Expected <b>$(Money $pr.expected)</b> ($(Enc $p.price_basis)) · Low case $(Money $pr.low_case) · <b>$(Enc $pr.fit)</b>"),
        @('Valuation', "CV $(K $p.cv) · land value $(K $p.land_value) · site estimate $(if ($p.estimate) { "$(K $p.estimate.low)–$(K $p.estimate.high)" } else { '—' })"),
        @('Site', "$($p.land_m2) m² · $(Enc(("$($p.zone)") -replace 'Residential - ','' -replace ' Zone','')) · $($p.beds) bed / $($p.baths) bath · built $(if ($p.decade_built) { Enc $p.decade_built } else { 'unknown' })"),
        @('Title', (Enc $p.title_estate)),
        @('Location', "$(if ($tr) { "$($tr.cbd_km) km to CBD · train: $(if ($tr.train) { "$(Enc $tr.train.name) $(Dist $tr.train.distance_m)" } else { '—' }) · bus stop: $(if ($tr.bus -and $null -ne $tr.bus.distance_m) { Dist $tr.bus.distance_m } else { 'none within 800 m' })" } else { '—' })"),
        @('Future growth', "$(if ($g) { "<b>$(Pct $g.outlook_5y_pct)</b> over 5 years (range $(Pct $g.outlook_low_pct) to $(Pct $g.outlook_high_pct)) · suburb last 12 months $(Pct $g.suburb_12m_pct), 10 years $(Pct $g.suburb_10y_pct), from 2021 peak $(Pct $g.suburb_from_peak_pct)$(if (@($g.drivers).Count) { '<br>' + ((@($g.drivers) | ForEach-Object { Enc $_ }) -join '<br>') })" } else { '—' })"),
        @('State housing', "$(if ($sh -and -not $sh.error) { "<b>$(Enc $sh.level)</b> · $($sh.within_100m) within 100 m · $($sh.within_200m) within 200 m · $($sh.within_400m) of $($sh.titles_within_400m) titles within 400 m ($($sh.share_400m_pct)%)" } else { 'Unknown' })"),
        @('Flood', $(if ($p.flood) { "<b>$(Enc $p.flood)</b>" } else { 'No flood overlay' })),
        @('Services', "Wastewater: $(Svc $p.services.wastewater) · Stormwater: $(Svc $p.services.stormwater)"),
        @('Schools', (Schools $p.schools)),
        @('Development angle', (Enc $p.dev_angle)),
        @('Why', (Enc $p.why))
    )
    if (@($p.flags).Count) { $rows += , @('Watch out', ((@($p.flags) | ForEach-Object { Enc $_ }) -join '<br>')) }
    if (@($p.questions).Count) { $rows += , @('Ask the agent', ((@($p.questions) | ForEach-Object { Enc $_ }) -join '<br>')) }
    $mapLink = if ($p.lat) { " · <a href=`"https://www.google.com/maps/search/?api=1&amp;query=$($p.lat),$($p.lon)`">Map</a>" } else { '' }
    "<h3>$($p.score) · $(Enc $p.address)$status</h3>" +
    "<p><a href=`"$(Enc $p.url)`"><b>View listing on realestate.co.nz</b></a>$mapLink</p>" +
    '<table border="1" cellpadding="5" cellspacing="0">' +
    (($rows | ForEach-Object { "<tr><th align=`"left`" valign=`"top`">$($_[0])</th><td>$($_[1])</td></tr>" }) -join '') + '</table>'
}

function Row($p) {
    $sec = @($p.schools.secondary | Where-Object { $_ -and $_.name -and $_.authority -notmatch 'Integrated' })[0]
    $tr = $p.transport
    "<tr><td>$($p.score)</td><td><a href=`"$(Enc $p.url)`">$(Enc $p.address)</a></td><td>$(Money $p.pricing.expected)<br>$(Enc $p.pricing.fit)</td>" +
    "<td>$($p.land_m2) m²<br>$(Enc (("$($p.zone)") -replace 'Residential - ','' -replace ' Zone','' -replace 'Terrace Housing and Apartment Building','THAB' -replace 'Mixed Housing ','MH '))$(if ($p.land -and $p.land -isnot [string]) { '<br>' + (Enc $p.land.shape) + $(if ($p.land.access_width_m) { ", $($p.land.access_width_m) m driveway" } elseif ($p.land.frontage_m) { ", $($p.land.frontage_m) m front" }) })</td>" +
    "<td>$(if ($tr) { "$($tr.cbd_km) km" })</td><td>$(if ($tr -and $tr.train) { "$(Enc $tr.train.name) $(Dist $tr.train.distance_m)" })</td>" +
    "<td>$(if ($sec) { "$(Enc $sec.name) ($(Enc $sec.band))" })</td><td>$(Enc $p.state_housing.level)</td><td>$(if ($p.flood) { Enc $p.flood } else { 'None' })$(if ("$($p.power_lines.level)" -match 'Over|corridor|40 m') { "<br><b>HV power line: $(Enc $p.power_lines.level)</b>" })</td><td>$(if ($p.slope -and -not $p.slope.error) { "$(Enc $p.slope.class) ($($p.slope.fall_m) m)" } else { '—' })</td><td>$(Enc ((@($p.sale_type) | Where-Object { $_ }) -join ', '))</td><td>$(Pct $p.growth.outlook_5y_pct)</td></tr>"
}
$rowHead = '<table border="1" cellpadding="4" cellspacing="0"><tr><th>Score</th><th>Address (listing)</th><th>Expected price</th><th>Land / zone</th><th>To CBD</th><th>Nearest train</th><th>Secondary school</th><th>State housing</th><th>Flood</th><th>Slope</th><th>Sale type</th><th>5-yr growth</th></tr>'

# The page lists everything; the email sticks to sites that pass your rules and are at most 15% over budget.
$sl = @($run.shortlist | Where-Object { -not @($_.rule_fails | Where-Object { $_ }).Count -and $_.pricing.expected -le 1100000 * 1.15 })
$detail = @($sl | Where-Object { $_.label -ne 'Marginal' } | Select-Object -First $Detailed)
$rest = @($sl | Where-Object { $detail -notcontains $_ })
$inBudget = @($detail | Where-Object { $_.pricing.expected -le 1100000 })
$over = @($detail | Where-Object { $_.pricing.expected -gt 1100000 })
$marginal = @()

$html = @()
$html += "<h2>Auckland site hunt: $Date</h2>"
if ($MarketNote) { $html += "<p><b>Market update:</b> $(Enc $MarketNote)</p>" }
$html += "<p>$(Enc $run.summary)</p>"
$html += "<p><b><a href=`"$($cfg.report_url)`">Open the full interactive shortlist ($($sl.Count) sites)</a></b>: every site with its listing link, pricing, growth, schools, state housing, flood and services.</p>"
$stars = @($sl | Where-Object { $_.starred })
if ($stars.Count) {
    $html += '<h3>★ Your shortlist</h3>' + $rowHead + (($stars | ForEach-Object { Row $_ }) -join '') + '</table>'
}
if ($Short) {
    # Short summary (default): top 6 in budget as a table, then the best few slightly over budget.
    $topIn = @($sl | Where-Object { $_.pricing.expected -le 1100000 -and $_.label -ne 'Marginal' } | Select-Object -First 6)
    $topOver = @($sl | Where-Object { $_.pricing.expected -gt 1100000 -and $_.label -ne 'Marginal' } | Select-Object -First 4)
    $html += '<h3>Top picks in budget</h3>' + $rowHead + (($topIn | ForEach-Object { Row $_ }) -join '') + '</table>'
    if ($topOver.Count) {
        $html += '<h3>Slightly over budget (could sell below CV)</h3><ul>' + (($topOver | ForEach-Object {
            "<li><a href=`"$(Enc $_.url)`">$(Enc $_.address)</a>: expected $(Money $_.pricing.expected), low case $(Money $_.pricing.low_case), $($_.land_m2) m², $($_.transport.cbd_km) km to CBD, state housing $(Enc $_.state_housing.level)$(if ($_.flood) { ', ' + (Enc $_.flood) })</li>" }) -join '') + '</ul>'
    }
} else {
    $html += '<hr><h2>Top picks: in budget</h2>' + (($inBudget | ForEach-Object { Site $_ }) -join '<hr>')
    if ($over.Count) { $html += '<hr><h2>Top picks: slightly over budget (could sell below CV)</h2>' + (($over | ForEach-Object { Site $_ }) -join '<hr>') }
    if ($rest.Count) { $html += "<hr><h2>All other sites ($($rest.Count))</h2>" + $rowHead + (($rest | ForEach-Object { Row $_ }) -join '') + '</table>' }
}
if (-not $Short) {
    if (@($run.school_rejects).Count) {
        $html += '<hr><h3>Left out: secondary school rated Low</h3><ul>' + ((@($run.school_rejects) | ForEach-Object { "<li><a href=`"$(Enc $_.url)`">$(Enc $_.address)</a>: $(Enc $_.school)</li>" }) -join '') + '</ul>'
    }
    $html += '<hr><h3>How to read this</h3><ul>' + ((@($run.notes) | ForEach-Object { "<li>$(Enc $_)</li>" }) -join '') + '</ul>'
}
$html += '<p><i>Figures are rough screening estimates from listing data, council GIS and public datasets. Confirm title, LIM, zoning and flood overlays before any offer, and take finance and purchase decisions with your broker, lawyer and adviser.</i></p>'

$out = Join-Path $reports "email-$Date.html"
[IO.File]::WriteAllText($out, ($html -join "`n"), (New-Object Text.UTF8Encoding($false)))
"$out  ($((Get-Item $out).Length) bytes)"
