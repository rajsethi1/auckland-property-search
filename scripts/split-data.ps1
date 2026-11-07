<#
  Splits the day's data.json for the website:
    <Out>\summary.json      every top-level field, with each site cut down to what the home, search, map and saved
                            pages need (filters, sorting, cards). Loaded once when the site opens.
    <Out>\parts\NN.json     the full site records, in 64 buckets ({ "<id>": record }). The property and feasibility
                            pages load one bucket when opened. Bucket = a small hash of the id (h = (h*31 + char) mod
                            1000003, then mod 64), the same hash app.js uses.
  Without this, ~10,000 sites would make one ~50 MB file that phones struggle to open.
#>
param([Parameter(Mandatory)][string]$DataFile, [Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$d = [IO.File]::ReadAllText($DataFile, $utf8) | ConvertFrom-Json
New-Item -ItemType Directory -Force "$Out\parts" | Out-Null
Get-ChildItem "$Out\parts\*.json" -ErrorAction SilentlyContinue | Remove-Item

function Bucket([string]$id) { [long]$h = 0; foreach ($c in $id.ToCharArray()) { $h = ($h * 31 + [int]$c) % 1000003 }; [int]($h % 64) }
function SlimSchools($list) { @(@($list) | Where-Object { $_ } | ForEach-Object { [ordered]@{ id = $_.id; band = $_.band } }) }
function Num($v) { if ($v -is [ValueType]) { $v } else { $null } }

$keep = 'id', 'address', 'suburb', 'lat', 'lon', 'status', 'label', 'score', 'price_text', 'price_used', 'land_m2', 'beds',
        'zone', 'title', 'flood', 'sale_type', 'ptype', 'url', 'starred'
$slim = New-Object Collections.Generic.List[object]
$parts = @{}; for ($i = 0; $i -lt 64; $i++) { $parts[$i] = [ordered]@{} }
foreach ($p in @($d.shortlist)) {
    if (-not $p) { continue }
    $parts[(Bucket "$($p.id)")]["$($p.id)"] = $p
    $s = [ordered]@{}
    foreach ($k in $keep) { if ($null -ne $p.$k) { $s[$k] = $p.$k } }
    if ($p.pricing) { $s.pricing = [ordered]@{ expected = Num $p.pricing.expected; low_case = Num $p.pricing.low_case } }
    if ($p.numbers) { $s.numbers = [ordered]@{ weekly_rent = Num $p.numbers.weekly_rent } }
    if ($p.growth) { $s.growth = [ordered]@{ outlook_5y_pct = Num $p.growth.outlook_5y_pct } }
    if ($p.power_lines) { $s.power_lines = [ordered]@{ level = $p.power_lines.level } }
    if ($p.state_housing) { $s.state_housing = [ordered]@{ level = $p.state_housing.level } }
    if ($p.schools) { $s.schools = [ordered]@{ secondary = SlimSchools $p.schools.secondary; primary = SlimSchools $p.schools.primary } }
    if ($p.land -and $p.land -isnot [string]) { $s.land = [ordered]@{ position = $p.land.position } }
    if ($p.transport) { $s.transport = [ordered]@{ cbd_km = Num $p.transport.cbd_km; train = $(if ($p.transport.train) { [ordered]@{ distance_m = Num $p.transport.train.distance_m } } else { $null }) } }
    $slim.Add($s)
}
$sum = [ordered]@{}
foreach ($pr in $d.PSObject.Properties) { $sum[$pr.Name] = $(if ($pr.Name -eq 'shortlist') { $slim.ToArray() } else { $pr.Value }) }
$sum.parts = 64
[IO.File]::WriteAllText("$Out\summary.json", ($sum | ConvertTo-Json -Depth 8 -Compress), $utf8)
for ($i = 0; $i -lt 64; $i++) { [IO.File]::WriteAllText(("$Out\parts\{0:D2}.json" -f $i), ($parts[$i] | ConvertTo-Json -Depth 12 -Compress), $utf8) }
"Split $($slim.Count) sites: summary $([math]::Round((Get-Item "$Out\summary.json").Length / 1KB)) KB, 64 detail parts"
