<#
  Builds property-hunt\school-zones.json: for each school in config.json top_schools, the suburbs its MoE enrolment zone covers.
  run-daily.ps1 calls this when the cache is missing, older than 90 days, or the school list changed.
#>
$ErrorActionPreference = 'Stop'
# Data folder: HUNT_ROOT when set (the cloud run), else the local folder.
function HuntRoot { if ($env:HUNT_ROOT) { $env:HUNT_ROOT } else { 'C:\Claude\Personal\property-hunt' } }
$root = (HuntRoot)
$cfg = [IO.File]::ReadAllText("$root\config.json", [Text.Encoding]::UTF8) | ConvertFrom-Json
$zoneSvc = 'https://services.arcgis.com/XTtANUDT8Va4DLwI/arcgis/rest/services/NZ_School_Zone_boundaries/FeatureServer/0/query'
$subSvc = 'https://services.arcgis.com/xdsHIIxuCWByZiCB/arcgis/rest/services/LINZ_NZ_Suburbs_and_Localities/FeatureServer/0/query'
$out = [ordered]@{ updated = (Get-Date -Format 'yyyy-MM-dd'); schools = [ordered]@{} }
foreach ($s in $cfg.top_schools) {
    $z = Invoke-RestMethod "${zoneSvc}?where=School_ID%3D$($s.id)&outFields=School_name&returnGeometry=true&outSR=4326&maxAllowableOffset=0.0003&f=json"
    $subs = @()
    foreach ($f in $z.features) {
        $geom = @{ rings = $f.geometry.rings; spatialReference = @{ wkid = 4326 } } | ConvertTo-Json -Depth 6 -Compress
        $q = Invoke-RestMethod $subSvc -Method Post -Body @{ geometry = $geom; geometryType = 'esriGeometryPolygon'; inSR = 4326; spatialRel = 'esriSpatialRelIntersects'; outFields = 'name_ascii'; returnGeometry = 'false'; f = 'json' }
        foreach ($a in $q.features.attributes) {
            $slug = ("$($a.name_ascii)".ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
            $subs += $slug; if ($slug -match '^st-') { $subs += ($slug -replace '^st-', 'saint-') }
        }
    }
    $out.schools["$($s.id)"] = [ordered]@{ name = $s.name; ncea_l3_pct = $s.ncea_l3_pct; suburbs = @($subs | Sort-Object -Unique) }
}
[IO.File]::WriteAllText("$root\school-zones.json", ($out | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
$out.schools.Values | ForEach-Object { "$($_.name): $($_.suburbs.Count) suburbs" }
