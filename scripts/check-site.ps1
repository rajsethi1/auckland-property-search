<#
  Site check for Auckland addresses against Auckland Council's open GIS layers.
  Single:  powershell -NoProfile -File check-site.ps1 -Address "123 Example Road, Mount Roskill, Auckland" [-Lat -36.9 -Lon 174.7]
  Batch:   powershell -NoProfile -File check-site.ps1 -InputCsv sites.csv     (columns: id,address,lat,lon; lat/lon optional)
  Output:  JSON (one object, or an array for batch) with zone, flood, special character, heritage.
  Zoning is the OPERATIVE Unitary Plan base zone; proposed plan changes are not reflected.
  Checks are a point test at the coordinates — a flood plain crossing the back of a site can be missed.
#>
param([string]$Address, [double]$Lat = 0, [double]$Lon = 0, [string]$InputCsv, [string]$JsonLines, [switch]$FloodOnly)
# -FloodOnly: just the whole-parcel flood share ({id, flood_site}) — for re-checking flood on existing sites.
# -JsonLines <file>: with -InputCsv, append each result as one JSON line as soon as it's done (resumable; run-daily caches these).

$ErrorActionPreference = 'Stop'
$base = 'https://services1.arcgis.com/n4yPwebTjJCmXB6W/arcgis/rest/services'
# HUNT_REGION=chc: Christchurch City Council's District Plan, flood and pipe layers instead of Auckland's.
$CHC = $env:HUNT_REGION -eq 'chc'
$ccc = 'https://gis.ccc.govt.nz/server/rest/services/OpenData'
# Canterbury beyond the city: Selwyn (Partially Operative District Plan, ArcGIS Online) and Waimakariri (2025 decisions plan).
$sdc = 'https://services6.arcgis.com/Aa15joGcFNhhKYEJ/arcgis/rest/services'
$wdc = 'https://gisservices.waimakariri.govt.nz/arcgis/rest/services'
$linzRoads = "https://services.arcgis.com/xdsHIIxuCWByZiCB/arcgis/rest/services/LINZ_NZ_Primary_Parcels/FeatureServer/0/query?where=parcel_intent%3D'Road'"
$wdcZones = @{ GRZ = 'General Residential'; MRZ = 'Medium Density Residential'; LLRZ = 'Large Lot Residential'; SETZ = 'Settlement'; RLZ = 'Rural Lifestyle'
    GRUZ = 'General Rural'; TCZ = 'Town Centre'; LCZ = 'Local Centre'; NCZ = 'Neighbourhood Centre'; LFRZ = 'Large Format Retail'; MUZ = 'Mixed Use'
    GIZ = 'General Industrial'; HIZ = 'Heavy Industrial'; LIZ = 'Light Industrial'; OSZ = 'Open Space'; NOSZ = 'Natural Open Space'; SARZ = 'Sport and Active Recreation' }
$councilSrc = @{
    sdc = @{ flood = [ordered]@{ plain = "$sdc/PDP_Layers/FeatureServer/8"; prone = "$sdc/PDP_Layers/FeatureServer/9"; sensitive = "$sdc/PDP_Layers/FeatureServer/6" }
             names = @('Plains flood management area', 'Waimakariri River flood management area', 'Coastal inundation area')
             pipes = [ordered]@{ stormwater = "$sdc/Stormwater_Network/FeatureServer/1"; wastewater = "$sdc/Sewer_Network/FeatureServer/2" }
             where = @{ stormwater = "STATUS='In Service'"; wastewater = "STATUS='In Service' AND AMS2<>'Lateral'" } }
    wdc = @{ flood = [ordered]@{ plain = "$wdc/District_Plan_2021/Urban_Flood_Assessment_Area/MapServer/36"; prone = "$wdc/District_Plan_2021/Non_Urban_Flood_Assessment/MapServer/0"; sensitive = "$wdc/District_Plan_2021/Urban_Flood_Assessment_Area/MapServer/0" }
             names = @('Urban flood assessment area', 'Non-urban flood assessment area', 'Coastal flood assessment area')
             pipes = [ordered]@{ stormwater = "$wdc/3Waters/Assets_Stormwater/MapServer/12"; wastewater = "$wdc/3Waters/Assets_Wastewater/MapServer/12" }
             where = @{ stormwater = '1=1'; wastewater = '1=1' } }
}
$script:council = 'ccc'
# Same keys as Auckland, so the rest of the pipeline is unchanged: plain = High Flood Hazard Management Area,
# prone = Flood Management Area, sensitive = Fixed Floor Level area (Christchurch District Plan chapter 5).
$floodLayers = if ($CHC) { [ordered]@{ plain = "$ccc/DistrictPlanB/FeatureServer/25"; prone = "$ccc/DistrictPlanB/FeatureServer/30"; sensitive = "$ccc/DistrictPlan/FeatureServer/89" } }
               else { [ordered]@{ plain = 'Flood_Plains'; prone = 'Flood_Prone_Areas'; sensitive = 'Flood_Sensitive_Areas' } }
function Svc([string]$s) { if ($s -match '^https?://') { $s } else { "$base/$s/FeatureServer/0" } }
$cacheFile = Join-Path $PSScriptRoot 'zone-codes.json'

function Get-ZoneNames {
    if (Test-Path $cacheFile) {
        $obj = Get-Content $cacheFile -Raw | ConvertFrom-Json
        $map = @{}; $obj.PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value }; return $map
    }
    $meta = Invoke-RestMethod "$base/Unitary_Plan_Base_Zone/FeatureServer/0?f=json"
    $map = @{}
    ($meta.fields | Where-Object name -eq 'ZONE').domain.codedValues | ForEach-Object { $map["$($_.code)"] = $_.name }
    $map | ConvertTo-Json | Set-Content $cacheFile -Encoding utf8
    return $map
}

# Returns a wrapper (not the bare array) so PowerShell doesn't unroll an empty result into $null.
function Test-Layer([string]$service, [double]$x, [double]$y, [string]$where = '1=1') {
    $url = "$(Svc $service)/query?geometry=$x,$y&geometryType=esriGeometryPoint&inSR=4326&where=$([uri]::EscapeDataString($where))" +
           "&spatialRel=esriSpatialRelIntersects&outFields=*&returnGeometry=false&f=json"
    try {
        $r = Invoke-RestMethod $url
        if ($r.error) { return [pscustomobject]@{ ok = $false; count = 0; first = $null } }
        $f = @($r.features)
        return [pscustomobject]@{ ok = $true; count = $f.Count; first = $(if ($f.Count) { $f[0].attributes } else { $null }) }
    } catch { return [pscustomobject]@{ ok = $false; count = 0; first = $null } }
}

function Hit([string]$svc, [double]$x, [double]$y) { $f = Test-Layer $svc $x $y; if (-not $f.ok) { 'lookup-failed' } else { $f.count -gt 0 } }

$zones = Get-ZoneNames

# ---- Title + parcel (LINZ property titles, NZTM metres) and underground services ----
$titleSvc = 'https://services.arcgis.com/xdsHIIxuCWByZiCB/arcgis/rest/services/LINZ_NZ_Property_Titles/FeatureServer/0'
$pipeSvcs = if ($CHC) { [ordered]@{ stormwater = "$ccc/StormWater/FeatureServer/1"; wastewater = "$ccc/WasteWater/FeatureServer/1" } } else { [ordered]@{
    stormwater = 'https://services1.arcgis.com/n4yPwebTjJCmXB6W/arcgis/rest/services/Stormwater_Pipe/FeatureServer/0'
    # Watercare's own network (includes local 150 mm reticulation; the council's public layer only has trunk mains).
    wastewater = 'https://services5.arcgis.com/PnnKqtqi3qfxnaPc/arcgis/rest/services/Wastewater_Network/FeatureServer/5'
} }

function Get-Title([double]$x, [double]$y) {
    $url = "$titleSvc/query?geometry=$x,$y&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects" +
           '&outFields=title_no,type,estate_description,number_owners,spatial_extents_shared&returnGeometry=true&outSR=2193&f=json'
    try { $f = @((Invoke-RestMethod $url).features); if ($f.Count) { return $f[0] } } catch { }
    return $null
}

function Dist-PointSeg($px, $py, $ax, $ay, $bx, $by) {
    $dx = $bx - $ax; $dy = $by - $ay; $len2 = $dx * $dx + $dy * $dy
    $t = if ($len2 -gt 0) { [math]::Max(0, [math]::Min(1, (($px - $ax) * $dx + ($py - $ay) * $dy) / $len2)) } else { 0 }
    $cx = $ax + $t * $dx; $cy = $ay + $t * $dy
    [math]::Sqrt(($px - $cx) * ($px - $cx) + ($py - $cy) * ($py - $cy))
}

function Test-Inside($px, $py, $ring) {
    $inside = $false; $j = $ring.Count - 1
    for ($i = 0; $i -lt $ring.Count; $i++) {
        $xi = $ring[$i][0]; $yi = $ring[$i][1]; $xj = $ring[$j][0]; $yj = $ring[$j][1]
        if ((($yi -gt $py) -ne ($yj -gt $py)) -and ($px -lt ($xj - $xi) * ($py - $yi) / ($yj - $yi) + $xi)) { $inside = -not $inside }
        $j = $i
    }
    $inside
}

$cccFlood = $floodLayers; $cccPipes = $pipeSvcs   # Christchurch City defaults; Check-Site swaps in Selwyn/Waimakariri per site

# Counts grid points inside a set of polygon rings (even-odd). Only edges that can cross a rightward ray from inside the box are kept.
Add-Type -TypeDefinition @"
using System; using System.Collections.Generic;
public static class FloodGeo {
    static object U(object o) { var ps = o as System.Management.Automation.PSObject; return ps != null ? ps.BaseObject : o; }
    static object[] A(object o) { return (object[])U(o); }
    static double D(object o) { return Convert.ToDouble(U(o)); }
    public static int CountInside(object[] pts, object[] rings, double x0, double y0, double x1, double y1) {
        var e = new List<double[]>();
        foreach (object ro in rings) { var r = A(ro); int n = r.Length; if (n == 0) continue;
            for (int i = 0, j = n - 1; i < n; j = i++) {
                var a = A(r[i]); var b = A(r[j]);
                double ax = D(a[0]), ay = D(a[1]), bx = D(b[0]), by = D(b[1]);
                if ((ay < y0 && by < y0) || (ay > y1 && by > y1) || (ax < x0 && bx < x0)) continue;
                e.Add(new[] { ax, ay, bx, by }); } }
        int count = 0;
        foreach (object po in pts) { var p = A(po); double px = D(p[0]), py = D(p[1]); bool odd = false;
            foreach (var s in e) if (((s[1] > py) != (s[3] > py)) && (px < (s[2] - s[0]) * (py - s[1]) / (s[3] - s[1]) + s[0])) odd = !odd;
            if (odd) count++; }
        return count;
    }
}
"@

# Share of the whole title parcel (not just the address point) inside each flood layer, in % of site area.
# Fetches the flood polygons around the parcel once per layer and tests a ~400-point grid locally.
function Get-FloodShare($parcel) {
    $ring = $parcel.geometry.rings | Sort-Object { - (Get-RingArea $_) } | Select-Object -First 1
    $xs = $ring | ForEach-Object { $_[0] }; $ys = $ring | ForEach-Object { $_[1] }
    $x0 = ($xs | Measure-Object -Min).Minimum; $x1 = ($xs | Measure-Object -Max).Maximum; $y0 = ($ys | Measure-Object -Min).Minimum; $y1 = ($ys | Measure-Object -Max).Maximum
    $step = [math]::Max(1, [math]::Sqrt(($x1 - $x0) * ($y1 - $y0) / 400))
    $pts = @(for ($x = $x0 + $step / 2; $x -lt $x1; $x += $step) { for ($y = $y0 + $step / 2; $y -lt $y1; $y += $step) { if (Test-Inside $x $y $ring) { , @($x, $y) } } })
    $out = [ordered]@{}; $layers = $floodLayers
    foreach ($k in $layers.GetEnumerator()) {
        try {
            # One flood area covering the whole parcel box (e.g. Selwyn's plains-wide overlay) = 100%, without downloading its huge outline.
            $whole = Invoke-RestMethod "$(Svc $k.Value)/query?where=1%3D1&geometry=$x0,$y0,$x1,$y1&geometryType=esriGeometryEnvelope&inSR=2193&spatialRel=esriSpatialRelWithin&returnCountOnly=true&f=json"
            if ($whole.count -gt 0) { $out[$k.Key] = 100; continue }
            # Outline length first: past ~3,000 km (Waimakariri's rural flood area is 20,000 km, a 65 MB download)
            # sample 12 points of the site with point queries instead of downloading the shape.
            $info = Invoke-RestMethod "$(Svc $k.Value)/query?where=1%3D1&geometry=$x0,$y0,$x1,$y1&geometryType=esriGeometryEnvelope&inSR=2193&spatialRel=esriSpatialRelIntersects&returnGeometry=false&outFields=*&f=json"
            if ($info.error) { $out[$k.Key] = 'lookup-failed'; continue }
            if (-not @($info.features).Count -or -not $pts.Count) { $out[$k.Key] = 0; continue }
            $len = 0; foreach ($f in $info.features) { foreach ($pr in $f.attributes.PSObject.Properties) { if ($pr.Name -match '(?i)^shape.*len' -and $pr.Value) { $len += [double]$pr.Value } } }
            if ($len -gt 3e6) {
                $n = [math]::Min(12, $pts.Count); $hits = 0
                for ($i = 0; $i -lt $n; $i++) { $p = $pts[[int][math]::Floor(($i + 0.5) * $pts.Count / $n)]
                    $q = Invoke-RestMethod "$(Svc $k.Value)/query?where=1%3D1&geometry=$($p[0]),$($p[1])&geometryType=esriGeometryPoint&inSR=2193&spatialRel=esriSpatialRelIntersects&returnCountOnly=true&f=json"
                    if ($q.error) { throw 'point query failed' }; if ($q.count -gt 0) { $hits++ } }
                $out[$k.Key] = [math]::Round(100 * $hits / $n); continue
            }
            $r = Invoke-RestMethod "$(Svc $k.Value)/query?where=1%3D1&geometry=$x0,$y0,$x1,$y1&geometryType=esriGeometryEnvelope&inSR=2193&spatialRel=esriSpatialRelIntersects&returnGeometry=true&maxAllowableOffset=1&outSR=2193&f=json"
            if ($r.error) { $out[$k.Key] = 'lookup-failed'; continue }
            $rings = @($r.features | ForEach-Object { $_.geometry.rings } | ForEach-Object { , $_ })
            if (-not $rings.Count -or -not $pts.Count) { $out[$k.Key] = 0; continue }
            # Even-odd across all rings (handles holes); compiled because district-wide outlines run to 200k+ vertices.
            $in = [FloodGeo]::CountInside($pts, $rings, $x0, $y0, $x1, $y1)
            $out[$k.Key] = [math]::Round(100 * $in / $pts.Count)
        } catch { $out[$k.Key] = 'lookup-failed' }
    }
    $out
}

# Nearest pipe of each network to the title boundary: 0 m = crosses the site.
function Get-Services($parcel) {
    $ring = $parcel.geometry.rings[0]
    $xs = $ring | ForEach-Object { $_[0] }; $ys = $ring | ForEach-Object { $_[1] }
    $pad = 80
    $env = '{0},{1},{2},{3}' -f (($xs | Measure-Object -Minimum).Minimum - $pad), (($ys | Measure-Object -Minimum).Minimum - $pad),
                                (($xs | Measure-Object -Maximum).Maximum + $pad), (($ys | Measure-Object -Maximum).Maximum + $pad)
    $out = [ordered]@{}
    foreach ($k in $pipeSvcs.Keys) {
        # Watercare's layer also holds connection links (UNITTYPE NA, diameter 999); keep operational pipes only.
        $where = if ($script:council -ne 'ccc' -and $CHC) { [uri]::EscapeDataString($councilSrc[$script:council].where[$k]) } elseif ($CHC) { [uri]::EscapeDataString("ServiceStatus='In Service' AND Ownership='CCC'") } elseif ($k -eq 'wastewater') { [uri]::EscapeDataString("STATUS='OP' AND UNITTYPE LIKE 'PIPE%'") } else { '1%3D1' }
        $url = "$($pipeSvcs[$k])/query?geometry=$env&geometryType=esriGeometryEnvelope&inSR=2193&spatialRel=esriSpatialRelIntersects" +
               "&where=$where&outFields=*&returnGeometry=true&outSR=2193&f=json"
        try { $feats = @((Invoke-RestMethod $url).features) } catch { $out[$k] = 'lookup-failed'; continue }
        $best = [double]::MaxValue; $dia = $null
        foreach ($f in $feats) {
            foreach ($path in $f.geometry.paths) {
                for ($i = 0; $i -lt $path.Count; $i++) {
                    $vx = $path[$i][0]; $vy = $path[$i][1]
                    if (Test-Inside $vx $vy $ring) { $d = 0 }
                    else {
                        $d = [double]::MaxValue
                        for ($e = 0; $e -lt $ring.Count - 1; $e++) {
                            $d = [math]::Min($d, (Dist-PointSeg $vx $vy $ring[$e][0] $ring[$e][1] $ring[$e + 1][0] $ring[$e + 1][1]))
                        }
                        if ($i -lt $path.Count - 1) {
                            foreach ($pt in $ring) {
                                $d = [math]::Min($d, (Dist-PointSeg $pt[0] $pt[1] $vx $vy $path[$i + 1][0] $path[$i + 1][1]))
                            }
                        }
                    }
                    if ($d -lt $best) { $best = $d; $dia = $(if ($f.attributes.SW_DIAMETER_MM) { $f.attributes.SW_DIAMETER_MM } elseif ($f.attributes.NominalDiameter) { $f.attributes.NominalDiameter } elseif ($f.attributes.DIAMPIPE) { $f.attributes.DIAMPIPE } else { $f.attributes.NOM_DIA_MM }) }
                }
            }
        }
        $out[$k] = if ($best -eq [double]::MaxValue) { [ordered]@{ on_site = $false; distance_m = $null; note = "none within $pad m" } }
                   else { [ordered]@{ on_site = ($best -lt 0.5); distance_m = [math]::Round($best, 1); diameter_mm = $dia } }
    }
    $out
}

# ---- Transport: nearest train station (AT), nearest bus stop (AT), straight-line distance to the CBD (Britomart) ----
$atBase = 'https://services2.arcgis.com/JkPEgZJGxhSjYOo0/arcgis/rest/services'
function Get-Metres([double]$lat1, [double]$lon1, [double]$lat2, [double]$lon2) {
    $r = 6371000; $p1 = $lat1 * [math]::PI / 180; $p2 = $lat2 * [math]::PI / 180
    $dp = ($lat2 - $lat1) * [math]::PI / 180; $dl = ($lon2 - $lon1) * [math]::PI / 180
    $a = [math]::Sin($dp / 2) * [math]::Sin($dp / 2) + [math]::Cos($p1) * [math]::Cos($p2) * [math]::Sin($dl / 2) * [math]::Sin($dl / 2)
    2 * $r * [math]::Atan2([math]::Sqrt($a), [math]::Sqrt(1 - $a))
}
$script:stations = $null
function Get-Stations {
    if ($script:stations) { return $script:stations }
    $cache = Join-Path $PSScriptRoot 'train-stations.json'
    if (-not (Test-Path $cache) -or ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalDays -gt 30) {
        try {
            $q = Invoke-RestMethod "$atBase/TrainService/FeatureServer/0/query?where=1%3D1&outFields=STOPNAME,STOPLAT,STOPLON&returnGeometry=false&f=json"
            $list = $q.features.attributes | Group-Object { $_.STOPNAME -replace ' Train Station.*$', '' } | ForEach-Object {
                [ordered]@{ name = $_.Name; lat = ($_.Group.STOPLAT | Measure-Object -Average).Average; lon = ($_.Group.STOPLON | Measure-Object -Average).Average } }
            $list | ConvertTo-Json | Set-Content $cache -Encoding utf8
        } catch { }
    }
    $script:stations = if (Test-Path $cache) { Get-Content $cache -Raw | ConvertFrom-Json } else { @() }
    $script:stations
}
function Get-Transport([double]$lat, [double]$lon) {
    if ($CHC) {
        # Christchurch: no suburban trains; Metro bus stops; CBD = Cathedral Square.
        $bus = $null
        try {
            $q = Invoke-RestMethod ('https://services1.arcgis.com/ISqEHdhr3detVO9I/arcgis/rest/services/Metro_Bus_Stops/FeatureServer/0/query?geometry=' + "$lon,$lat" +
                '&geometryType=esriGeometryPoint&inSR=4326&distance=800&units=esriSRUnit_Meter&spatialRel=esriSpatialRelIntersects&outFields=PlatformNa&returnGeometry=true&outSR=4326&f=json')
            foreach ($f in $q.features) { $d = Get-Metres $lat $lon $f.geometry.y $f.geometry.x; if (-not $bus -or $d -lt $bus.d) { $bus = @{ n = $f.attributes.PlatformNa; d = $d } } }
        } catch { }
        return [ordered]@{
            train  = $null
            bus    = $(if ($bus) { [ordered]@{ name = $bus.n; distance_m = [math]::Round($bus.d) } } else { [ordered]@{ name = $null; distance_m = $null; note = 'none within 800 m' } })
            cbd_km = [math]::Round((Get-Metres $lat $lon -43.5310 172.6366) / 1000, 1)
        }
    }
    $best = $null
    foreach ($s in Get-Stations) { $d = Get-Metres $lat $lon $s.lat $s.lon; if (-not $best -or $d -lt $best.d) { $best = @{ n = $s.name; d = $d } } }
    $bus = $null
    try {
        $q = Invoke-RestMethod ("$atBase/BusService/FeatureServer/0/query?geometry=$lon,$lat&geometryType=esriGeometryPoint&inSR=4326" +
            '&distance=800&units=esriSRUnit_Meter&spatialRel=esriSpatialRelIntersects&outFields=STOPNAME,STOPLAT,STOPLON&returnGeometry=false&f=json')
        foreach ($f in $q.features) { $d = Get-Metres $lat $lon $f.attributes.STOPLAT $f.attributes.STOPLON; if (-not $bus -or $d -lt $bus.d) { $bus = @{ n = $f.attributes.STOPNAME; d = $d } } }
    } catch { }
    [ordered]@{
        train  = $(if ($best) { [ordered]@{ name = $best.n; distance_m = [math]::Round($best.d) } })
        bus    = $(if ($bus) { [ordered]@{ name = $bus.n; distance_m = [math]::Round($bus.d) } } else { [ordered]@{ name = $null; distance_m = $null; note = 'none within 800 m' } })
        cbd_km = [math]::Round((Get-Metres $lat $lon -36.8442 174.7676) / 1000, 1)
    }
}

# ---- Motorway access: nearest on-ramp and off-ramp (NZTA carriageway data, cached in motorway-ramps.json) ----
$script:ramps = $null
function Get-Motorway([double]$lat, [double]$lon) {
    if ($CHC) { return [ordered]@{ on_ramp = $null; off_ramp = $null; note = 'Not checked for Christchurch' } }
    if (-not $script:ramps) { $p = Join-Path $PSScriptRoot 'motorway-ramps.json'; $script:ramps = if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json } else { @() } }
    $best = @{}
    foreach ($r in $script:ramps) {
        $d = Get-Metres $lat $lon $r.lat $r.lon
        if (-not $best[$r.type] -or $d -lt $best[$r.type].d) { $best[$r.type] = @{ d = $d; n = $r.name } }
    }
    $fmt = { param($b) if ($b) { [ordered]@{ distance_km = [math]::Round($b.d / 1000, 1); near = $b.n } } }
    [ordered]@{ on_ramp = & $fmt $best['On ramp']; off_ramp = & $fmt $best['Off ramp']; note = 'Straight-line distance to the local-road end of the ramp; drive distance is typically 1.3-1.5x.' }
}

# ---- Land shape, frontage and access (LINZ title polygon vs Unitary Plan road zone, NZTM metres) ----
function Get-RingArea($ring) { $s = 0; for ($i = 0; $i -lt $ring.Count - 1; $i++) { $s += $ring[$i][0] * $ring[$i + 1][1] - $ring[$i + 1][0] * $ring[$i][1] }; [math]::Abs($s) / 2 }
function Get-MinRect($ring) {
    # Minimum-area bounding rectangle over the polygon's own edge directions.
    $best = $null
    for ($i = 0; $i -lt $ring.Count - 1; $i++) {
        $dx = $ring[$i + 1][0] - $ring[$i][0]; $dy = $ring[$i + 1][1] - $ring[$i][1]; $len = [math]::Sqrt($dx * $dx + $dy * $dy); if ($len -lt 0.5) { continue }
        $ux = $dx / $len; $uy = $dy / $len
        $us = $ring | ForEach-Object { $_[0] * $ux + $_[1] * $uy }; $vs = $ring | ForEach-Object { - $_[0] * $uy + $_[1] * $ux }
        $w = ($us | Measure-Object -Max).Maximum - ($us | Measure-Object -Min).Minimum; $h = ($vs | Measure-Object -Max).Maximum - ($vs | Measure-Object -Min).Minimum
        if (-not $best -or $w * $h -lt $best.area) { $best = @{ area = $w * $h; a = [math]::Max($w, $h); b = [math]::Min($w, $h) } }
    }
    $best
}
function Get-Corners($ring) {
    # Count vertices where the boundary turns by more than 25 degrees.
    $n = 0; $pts = $ring[0..($ring.Count - 2)]
    for ($i = 0; $i -lt $pts.Count; $i++) {
        $p0 = $pts[($i - 1 + $pts.Count) % $pts.Count]; $p1 = $pts[$i]; $p2 = $pts[($i + 1) % $pts.Count]
        $a1 = [math]::Atan2($p1[1] - $p0[1], $p1[0] - $p0[0]); $a2 = [math]::Atan2($p2[1] - $p1[1], $p2[0] - $p1[0])
        $t = [math]::Abs((($a2 - $a1 + 3 * [math]::PI) % (2 * [math]::PI)) - [math]::PI) * 180 / [math]::PI
        if ($t -gt 25) { $n++ }
    }
    $n
}
function Get-RoadPolys($ring, [double]$pad, $lines) {
    $xs = $ring | ForEach-Object { $_[0] }; $ys = $ring | ForEach-Object { $_[1] }
    $env = '{0},{1},{2},{3}' -f (($xs | Measure-Object -Min).Minimum - $pad), (($ys | Measure-Object -Min).Minimum - $pad), (($xs | Measure-Object -Max).Maximum + $pad), (($ys | Measure-Object -Max).Maximum + $pad)
    $url = $(if ($CHC -and $script:council -ne 'ccc') { $linzRoads } elseif ($CHC) { "$ccc/DistrictPlan/FeatureServer/78/query?where=Type%3D'Transport'" } else { "$base/Unitary_Plan_Base_Zone/FeatureServer/0/query?where=ZONE%3D27" }) + "&geometry=$env&geometryType=esriGeometryEnvelope&inSR=2193&spatialRel=esriSpatialRelIntersects&returnGeometry=true&outSR=2193&f=json"
    # Each road-zone polygon is tagged by the AT centrelines running inside it: only walkway/path lines = a path strip, not a road.
    $list = New-Object System.Collections.ArrayList
    try { foreach ($f in (Invoke-RestMethod $url).features) {
        $road = $false; $paths = @()
        foreach ($l in $lines) {
            $in = $false
            for ($j = 0; $j -lt $l.path.Count -and -not $in; $j++) {
                $px = $l.path[$j][0]; $py = $l.path[$j][1]
                if ($j -lt $l.path.Count - 1) { $px = ($px + $l.path[$j + 1][0]) / 2; $py = ($py + $l.path[$j + 1][1]) / 2 }
                foreach ($r in $f.geometry.rings) { if (Test-Inside $px $py $r) { $in = $true; break } }
            }
            if ($in) { if ($l.is_path) { $paths += $l.name } else { $road = $true } }
        }
        $isPath = (-not $road) -and $paths.Count -gt 0
        foreach ($r in $f.geometry.rings) { [void]$list.Add([pscustomobject]@{ ring = $r; is_path = $isPath; name = ($paths | Select-Object -First 1) }) }
    } } catch { }
    , $list
}
# AT road centrelines also carry walkways, accessways and shared paths; the road zone covers both.
$atRoads = 'https://services2.arcgis.com/JkPEgZJGxhSjYOo0/arcgis/rest/services/RoadingService/FeatureServer/3'
$pathName = '(\bSUP$|WWAY|WALKWAY|ACCESSWAY|SHARED PATH|CYWAY|CYCLEWAY|PATHWAY|PEDESTRIAN|\bTRACK( \(|$))'
function Get-Centrelines($ring, [double]$pad) {
    # Auckland Transport data only; in Christchurch every Transport-zone strip counts as road.
    if ($CHC) { return , (New-Object System.Collections.ArrayList) }
    $xs = $ring | ForEach-Object { $_[0] }; $ys = $ring | ForEach-Object { $_[1] }
    $env = '{0},{1},{2},{3}' -f (($xs | Measure-Object -Min).Minimum - $pad), (($ys | Measure-Object -Min).Minimum - $pad), (($xs | Measure-Object -Max).Maximum + $pad), (($ys | Measure-Object -Max).Maximum + $pad)
    $list = New-Object System.Collections.ArrayList
    try {
        foreach ($f in (Invoke-RestMethod "$atRoads/query?where=1%3D1&geometry=$env&geometryType=esriGeometryEnvelope&inSR=2193&spatialRel=esriSpatialRelIntersects&outFields=road_name&returnGeometry=true&outSR=2193&f=json").features) {
            foreach ($p in $f.geometry.paths) { [void]$list.Add([pscustomobject]@{ name = "$($f.attributes.road_name)"; path = $p; is_path = ("$($f.attributes.road_name)" -match $pathName) }) }
        }
    } catch { }
    , $list
}
function Get-RoadFrontage($ring, $roads) {
    # Edges whose outward side (2.5 m out from the midpoint) falls in the road zone; path strips are counted separately.
    $front = 0; $edges = @(); $pathLen = 0; $pathNames = @()
    for ($i = 0; $i -lt $ring.Count - 1; $i++) {
        $x1 = $ring[$i][0]; $y1 = $ring[$i][1]; $x2 = $ring[$i + 1][0]; $y2 = $ring[$i + 1][1]
        $len = [math]::Sqrt(($x2 - $x1) * ($x2 - $x1) + ($y2 - $y1) * ($y2 - $y1)); if ($len -lt 0.3) { continue }
        $mx = ($x1 + $x2) / 2; $my = ($y1 + $y2) / 2; $nx = - ($y2 - $y1) / $len; $ny = ($x2 - $x1) / $len
        $ox = $mx + 2.5 * $nx; $oy = $my + 2.5 * $ny
        if (Test-Inside $ox $oy $ring) { $ox = $mx - 2.5 * $nx; $oy = $my - 2.5 * $ny }
        $hit = $null; foreach ($rr in $roads) { if (Test-Inside $ox $oy $rr.ring) { $hit = $rr; break } }
        if ($hit -and $hit.is_path) { $pathLen += $len; if ($pathNames -notcontains $hit.name) { $pathNames += $hit.name } }
        elseif ($hit) { $front += $len; $edges += $len }
    }
    [pscustomobject]@{ frontage = $front; edges = $edges; path_m = $pathLen; path_names = $pathNames }
}
function Get-SiteShape($parcel, [double]$lat, [double]$lon) {
    $ring = $parcel.geometry.rings | Sort-Object { - (Get-RingArea $_) } | Select-Object -First 1
    $area = Get-RingArea $ring
    $mr = Get-MinRect $ring
    $rect = if ($mr) { $area / $mr.area } else { 0 }
    $corners = Get-Corners $ring
    $lines = Get-Centrelines $ring 120
    $roads = Get-RoadPolys $ring 30 $lines
    $fr = Get-RoadFrontage $ring $roads
    $front = [math]::Round($fr.frontage, 1)
    $position = 'Road front'; $access = $null; $accessNote = $null
    if ($front -lt 0.5) {
        $position = 'Rear site (no road frontage)'
        # Look for a narrow neighbouring title (shared driveway lot) that touches both this site and the road.
        $xs = $ring | ForEach-Object { $_[0] }; $ys = $ring | ForEach-Object { $_[1] }
        $env = '{0},{1},{2},{3}' -f (($xs | Measure-Object -Min).Minimum - 40), (($ys | Measure-Object -Min).Minimum - 40), (($xs | Measure-Object -Max).Maximum + 40), (($ys | Measure-Object -Max).Maximum + 40)
        try {
            $nb = (Invoke-RestMethod "$titleSvc/query?geometry=$env&geometryType=esriGeometryEnvelope&inSR=2193&spatialRel=esriSpatialRelIntersects&outFields=title_no,estate_description&returnGeometry=true&outSR=2193&f=json").features
            foreach ($f in $nb) {
                $r2 = $f.geometry.rings | Sort-Object { - (Get-RingArea $_) } | Select-Object -First 1
                $a2 = Get-RingArea $r2; if ($a2 -gt 450 -or $a2 -lt 20) { continue }
                $touch = $false; foreach ($p in $r2) { foreach ($q in $ring) { if ([math]::Abs($p[0] - $q[0]) + [math]::Abs($p[1] - $q[1]) -lt 1.0) { $touch = $true; break } }; if ($touch) { break } }
                if (-not $touch) { continue }
                $f2 = Get-RoadFrontage $r2 $roads
                if ($f2.frontage -gt 0.5 -and $f2.frontage -lt 9) { $access = [math]::Round($f2.frontage, 1); $accessNote = 'Shared access lot (width at the road)'; break }
            }
        } catch { }
        if (-not $access) { $accessNote = 'Access is by right of way or a shared lot not found in the data: confirm the driveway width on the title plan' }
    } elseif ($mr -and $front -gt [math]::Max($mr.b, 12) * 1.35) {
        $position = 'Road front (corner site, two frontages)'
    } elseif ($front -lt 8 -and $rect -lt 0.8) {
        $position = 'Rear site (battle-axe access leg)'; $access = $front; $accessNote = 'Width of the access leg at the road'
    }
    $shape = if ($position -match 'battle-axe') { 'Battle-axe (rear lot with access leg)' }
             elseif ($rect -ge 0.92 -and $mr.a / $mr.b -lt 1.35) { 'Square' }
             elseif ($rect -ge 0.92) { $(if ($mr.a / $mr.b -gt 3) { 'Rectangle (long and narrow)' } else { 'Rectangle' }) }
             elseif ($corners -le 3 -and $rect -lt 0.7) { 'Triangle / wedge' }
             elseif ($corners -le 4 -and $rect -ge 0.75) { 'Trapezoid (tapered)' }
             else { 'Irregular' }
    $driveRule = if ($null -ne $access) {
        if ($access -ge 3.5) { 'Access 3.5 m or wider: supports 2 dwellings at the rear (user rule; check AUP E27)' }
        elseif ($access -gt 3.0) { 'Access 3.0-3.5 m: 1 dwelling; 2 needs 3.5 m+ (user rule; check AUP E27)' }
        else { 'Access 3 m or narrower: 1 dwelling only (user rule; check AUP E27)' }
    } elseif ($position -eq 'Road front') { 'Road-front site: a new driveway down the side can serve rear dwellings (check width available beside the house)' } else { $null }
    [ordered]@{
        shape = $shape; rectangularity = [math]::Round($rect, 2); corners = $corners
        width_m = $(if ($mr) { [math]::Round($mr.b, 1) }); depth_m = $(if ($mr) { [math]::Round($mr.a, 1) })
        frontage_m = $front; position = $position; access_width_m = $access; access_note = $accessNote; driveway_rule = $driveRule
        path_frontage_m = $(if ($fr.path_m -gt 0.5) { [math]::Round($fr.path_m, 1) } else { $null }); path_names = $(if ($fr.path_m -gt 0.5) { $fr.path_names -join ', ' } else { $null })
    }
}

# ---- High-voltage power lines: Transpower national grid lines and the Unitary Plan National Grid Corridor overlay ----
$tpLines = 'https://services3.arcgis.com/AkUq3zcWf7TVqyR9/arcgis/rest/services/TransmissionLines/FeatureServer/0'
function Get-PowerLines($parcel) {
    $ring = $parcel.geometry.rings | Sort-Object { - (Get-RingArea $_) } | Select-Object -First 1
    $xs = $ring | ForEach-Object { $_[0] }; $ys = $ring | ForEach-Object { $_[1] }
    $minX = ($xs | Measure-Object -Min).Minimum; $minY = ($ys | Measure-Object -Min).Minimum; $maxX = ($xs | Measure-Object -Max).Maximum; $maxY = ($ys | Measure-Object -Max).Maximum
    $out = [ordered]@{ over_site = $false; nearest_m = $null; kv = $null; line = $null; kind = $null; grid_corridor = $null }
    try {
        $env = '{0},{1},{2},{3}' -f ($minX - 250), ($minY - 250), ($maxX + 250), ($maxY + 250)
        $feats = @((Invoke-RestMethod "$tpLines/query?where=status%3D'COMMISSIONED'&geometry=$env&geometryType=esriGeometryEnvelope&inSR=2193&spatialRel=esriSpatialRelIntersects&outFields=designvolt,description,type&returnGeometry=true&outSR=2193&f=json").features)
        $best = [double]::MaxValue
        foreach ($f in $feats) { foreach ($path in $f.geometry.paths) { for ($i = 0; $i -lt $path.Count - 1; $i++) {
            $ax = $path[$i][0]; $ay = $path[$i][1]; $bx = $path[$i + 1][0]; $by = $path[$i + 1][1]
            $d = [double]::MaxValue
            if ((Test-Inside $ax $ay $ring) -or (Test-Inside $bx $by $ring)) { $d = 0 }
            else {
                foreach ($pt in $ring) { $d = [math]::Min($d, (Dist-PointSeg $pt[0] $pt[1] $ax $ay $bx $by)) }
                # A span crossing the lot with both towers outside it.
                for ($e = 0; $e -lt $ring.Count - 1 -and $d -gt 0; $e++) {
                    $cx = $ring[$e][0]; $cy = $ring[$e][1]; $dx2 = $ring[$e + 1][0]; $dy2 = $ring[$e + 1][1]
                    $d1 = ($bx - $ax) * ($cy - $ay) - ($by - $ay) * ($cx - $ax); $d2 = ($bx - $ax) * ($dy2 - $ay) - ($by - $ay) * ($dx2 - $ax)
                    $d3 = ($dx2 - $cx) * ($ay - $cy) - ($dy2 - $cy) * ($ax - $cx); $d4 = ($dx2 - $cx) * ($by - $cy) - ($dy2 - $cy) * ($bx - $cx)
                    if (($d1 * $d2 -lt 0) -and ($d3 * $d4 -lt 0)) { $d = 0 }
                }
            }
            if ($d -lt $best) { $best = $d; $out.kv = $f.attributes.designvolt; $out.line = $f.attributes.description; $out.kind = $(if ($f.attributes.type -eq 'CABLE') { 'Underground cable' } else { 'Overhead line' }) }
        } } }
        if ($best -lt [double]::MaxValue) { $out.nearest_m = [math]::Round($best); $out.over_site = ($best -lt 0.5) }
    } catch { $out.nearest_m = 'lookup-failed' }
    try {
        $env = '{0},{1},{2},{3}' -f $minX, $minY, $maxX, $maxY
        $types = @{ 1 = 'National Grid Corridor'; 2 = 'National Grid Yard'; 3 = 'National Grid Yard (compromised)'; 4 = 'National Grid Yard'; 5 = 'Substation Corridor'; 6 = 'National Grid Subdivision Corridor' }
        $hit = @()
        foreach ($f in (Invoke-RestMethod "$base/National_Grid_Corridor_Overlay/FeatureServer/0/query?where=1%3D1&geometry=$env&geometryType=esriGeometryEnvelope&inSR=2193&spatialRel=esriSpatialRelIntersects&outFields=TYPE&returnGeometry=true&outSR=2193&f=json").features) {
            $in = $false
            foreach ($r in $f.geometry.rings) {
                foreach ($p in $ring) { if (Test-Inside $p[0] $p[1] $r) { $in = $true; break } }
                if (-not $in) { foreach ($p in $r) { if (Test-Inside $p[0] $p[1] $ring) { $in = $true; break } } }
                if ($in) { break }
            }
            if ($in) { $hit += $types[[int]$f.attributes.TYPE] }
        }
        $out.grid_corridor = $(if ($hit.Count) { ($hit | Select-Object -Unique) -join ', ' } else { 'None' })
    } catch { $out.grid_corridor = 'lookup-failed' }
    $n = $out.nearest_m
    $out.level = if ($out.over_site -and $out.kind -eq 'Overhead line') { 'Over site' }
                 elseif ($out.grid_corridor -and $out.grid_corridor -notin 'None', 'lookup-failed') { 'In grid corridor' }
                 elseif ($n -is [double] -or $n -is [int] -or $n -is [long]) { if ($n -le 40) { 'Within 40 m' } elseif ($n -le 100) { 'Within 100 m' } else { 'None nearby' } }
                 elseif ($n -eq 'lookup-failed') { 'lookup-failed' } else { 'None nearby' }
    $out.note = 'Transpower national grid only. Vector 11-33 kV lines are not in public data: look up on site or Vector''s map.'
    $out
}

# ---- State housing: Kāinga Ora parcels (LINZ Central Record of State Land, "Housing New Zealand") near the site ----
$crosl = 'https://services.arcgis.com/xdsHIIxuCWByZiCB/arcgis/rest/services/CRoSL_Layer_N/FeatureServer/0'
function Get-StateHousing([double]$lat, [double]$lon) {
    $where = [uri]::EscapeDataString("(Managed_By LIKE '%Housing New Zealand%' OR Managed_By LIKE '%Kainga%' OR Managed_By LIKE '%Kāinga%') AND Shape__Area > 150")
    $out = [ordered]@{}
    try {
        foreach ($r in 100, 200, 400) {
            $q = Invoke-RestMethod ("$crosl/query?where=$where&geometry=$lon,$lat&geometryType=esriGeometryPoint&inSR=4326&distance=$r" +
                '&units=esriSRUnit_Meter&spatialRel=esriSpatialRelIntersects&returnCountOnly=true&f=json')
            $out["within_${r}m"] = $q.count
        }
        $all = Invoke-RestMethod ("$titleSvc/query?where=1%3D1&geometry=$lon,$lat&geometryType=esriGeometryPoint&inSR=4326&distance=400" +
            '&units=esriSRUnit_Meter&spatialRel=esriSpatialRelIntersects&returnCountOnly=true&f=json')
        $out.titles_within_400m = $all.count
        $out.share_400m_pct = if ($all.count) { [math]::Round(100 * $out.within_400m / $all.count, 1) } else { $null }
        $out.level = if ($out.within_100m -ge 3 -or $out.share_400m_pct -ge 20) { 'High' } elseif ($out.within_100m -ge 1 -or $out.share_400m_pct -ge 10) { 'Medium' } else { 'Low' }
    } catch { $out.error = 'lookup-failed' }
    $out
}

# MoE Schools Directory (Equity Index, roll, authority), cached for 30 days next to this script.
$script:schoolDir = $null
function Get-SchoolDirectory {
    if ($script:schoolDir) { return $script:schoolDir }
    $cache = Join-Path $PSScriptRoot 'school-directory.csv'
    if (-not (Test-Path $cache) -or ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalDays -gt 30) {
        try {
            $pkg = Invoke-RestMethod 'https://catalogue.data.govt.nz/api/3/action/package_show?id=directory-of-educational-institutions'
            $res = $pkg.result.resources | Where-Object { $_.name -match '^Schools Directory' } | Select-Object -First 1
            Invoke-WebRequest $res.url -OutFile $cache -UseBasicParsing
        } catch { }
    }
    $map = @{}
    if (Test-Path $cache) {
        # The CSV has a few title lines before the header row on some releases; find the header.
        $lines = Get-Content $cache -Encoding UTF8
        $start = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^"?School_Id' })
        if ($start -ge 0) { $lines[$start..($lines.Count - 1)] | ConvertFrom-Csv | ForEach-Object { $map["$($_.School_Id)"] = $_ } }
    }
    $script:schoolDir = $map
    $map
}

# Secondary results (school leavers with NCEA Level 3+, 2023-2025) from Education Counts, saved by the skill to school-results.json.
$script:schoolRes = $null
function Get-SchoolResults {
    if ($null -ne $script:schoolRes) { return $script:schoolRes }
    $p = Join-Path $PSScriptRoot 'school-results.json'
    $script:schoolRes = if (Test-Path $p) { Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json } else { $false }
    $script:schoolRes
}

# In-zone state schools (NZ School Zone boundaries layer on ArcGIS Online, published by Eagle Technology from MoE data).
function Get-Schools([double]$x, [double]$y) {
    $url = 'https://services.arcgis.com/XTtANUDT8Va4DLwI/arcgis/rest/services/NZ_School_Zone_boundaries/FeatureServer/0/query' +
           "?geometry=$x,$y&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects" +
           '&outFields=School_name,Institution_type&returnGeometry=false&f=json'
    try {
        $f = @((Invoke-RestMethod ($url -replace 'outFields=School_name,Institution_type', 'outFields=School_ID,School_name,Institution_type')).features)
        $dir = Get-SchoolDirectory
        $res = Get-SchoolResults
        $pick = { param($re) @($f | Where-Object { $_.attributes.Institution_type -match $re } | ForEach-Object {
            $a = $_.attributes; $d = $dir["$($a.School_ID)"]; $eqi = $(if ($d -and $d.EQi_Index -match '^\d+$') { [int]$d.EQi_Index })
            # Secondary: band on results (NCEA L3+ rate vs Auckland). Others: band on EQI terciles across Auckland schools.
            $l3 = if ($res) { $res.schools."$($a.School_ID)" } else { $null }
            $l3avg = if ($l3) { ($l3 | Where-Object { $_ -match '^[\d.]+$' } | ForEach-Object { [double]$_ } | Measure-Object -Average).Average } else { $null }
            $band = if ($l3avg) { if ($l3avg -ge $res.auckland_avg + 10) { 'High' } elseif ($l3avg -le $res.auckland_avg - 15) { 'Low' } else { 'Medium' } }
                    elseif ($eqi) { if ($eqi -le 407) { 'High' } elseif ($eqi -le 473) { 'Medium' } else { 'Low' } } else { $null }
            [ordered]@{ name = $a.School_name; id = $a.School_ID; eqi = $eqi; roll = $(if ($d) { $d.Total });
                        authority = $(if ($d) { $d.Authority }); ncea_l3_pct = $(if ($l3avg) { [math]::Round($l3avg, 1) });
                        band = $band; band_basis = $(if ($l3avg) { 'results' } elseif ($eqi) { 'EQI' });
                        ero = "https://ero.govt.nz/institution/$($a.School_ID)" } }) }
        [ordered]@{
            primary      = & $pick 'Contributing|Full Primary'
            intermediate = & $pick 'Intermediate'
            secondary    = & $pick 'Secondary|Composite'
        }
    } catch { 'lookup-failed' }
}

function Check-Site([string]$id, [string]$addr, [double]$lat, [double]$lon) {
    $matched = $null; $score = $null
    if ($lat -eq 0 -or $lon -eq 0) {
        $enc = [uri]::EscapeDataString($addr)
        $geo = Invoke-RestMethod "https://geocode.arcgis.com/arcgis/rest/services/World/GeocodeServer/findAddressCandidates?SingleLine=$enc&countryCode=NZL&maxLocations=1&f=json"
        $c = $geo.candidates | Select-Object -First 1
        if (-not $c) { return [ordered]@{ id = $id; address = $addr; error = 'Address not found by geocoder' } }
        $lon = $c.location.x; $lat = $c.location.y; $matched = $c.address; $score = $c.score
    }
    $t = Get-Title $lon $lat
    if ($CHC) {
        # District Plan zone still in force (Plan Change 14 zones carry a CreatedByPlanChange and replace older ones).
        $zoneHits = Test-Layer "$ccc/DistrictPlan/FeatureServer/78" $lon $lat 'RemovedByPlanChangeIdentifier IS NULL'
        $zoneName = if (-not $zoneHits.ok) { 'lookup-failed' } elseif ($zoneHits.count) {
            $zt = "$($zoneHits.first.Type)"
            switch -Regex ($zt) { '^Medium density residential' { 'Residential Medium Density' } '^High density residential' { 'Residential High Density' } default { $zt } }
        } else { 'none (road/unzoned?)' }
        # Not in the city plan: try Selwyn, then Waimakariri. Their flood, pipe and road layers then replace the city's for this site.
        $script:council = 'ccc'; $script:floodLayers = $cccFlood; $script:pipeSvcs = $cccPipes; $floodNames = $null
        if ($zoneHits.ok -and -not $zoneHits.count) {
            $sz = Test-Layer "$sdc/PDP_Layers/FeatureServer/80" $lon $lat
            if ($sz.count) { $script:council = 'sdc'; $zoneName = (Get-Culture).TextInfo.ToTitleCase(("$($sz.first.Zone_Name)" -replace '(?i)\s*zone\b', '').Trim().ToLower()) }
            else { $wz = Test-Layer "$wdc/District_Plan_2025/District_Plan_Decisions_Zones_2025/MapServer/11" $lon $lat
                if ($wz.count) { $script:council = 'wdc'; $code = "$($wz.first.NAME)"; $zoneName = if ($wdcZones[$code]) { $wdcZones[$code] } elseif ($code -match '^SPZ') { "Special Purpose $code" } else { $code } } }
            if ($script:council -ne 'ccc') { $src = $councilSrc[$script:council]; $script:floodLayers = $src.flood; $script:pipeSvcs = $src.pipes; $floodNames = $src.names }
        }
        $fl = $script:floodLayers
        $chk = [ordered]@{ plain = Hit $fl.plain $lon $lat; prone = Hit $fl.prone $lon $lat; sensitive = Hit $fl.sensitive $lon $lat
            sc = $false; hh = $(if ($script:council -eq 'sdc') { Hit "$sdc/PDP_Layers/FeatureServer/16" $lon $lat } elseif ($script:council -eq 'wdc') { $null } else { Hit "$ccc/DistrictPlanB/FeatureServer/32" $lon $lat }) }
        if ($script:council -eq 'ccc') { $chk.sc = Hit "$ccc/DistrictPlan/FeatureServer/59" $lon $lat }
    } else {
        $zoneHits = Test-Layer 'Unitary_Plan_Base_Zone' $lon $lat
        $zoneName = if (-not $zoneHits.ok) { 'lookup-failed' } elseif ($zoneHits.count) { $zones["$($zoneHits.first.ZONE)"] } else { 'none (road/unzoned?)' }
        $chk = [ordered]@{ plain = Hit 'Flood_Plains' $lon $lat; prone = Hit 'Flood_Prone_Areas' $lon $lat; sensitive = Hit 'Flood_Sensitive_Areas' $lon $lat
            sc = Hit 'Special_Character_Areas_Overlay_Residential_and_Business' $lon $lat; hh = Hit 'Historic_Heritage_Overlay_Extent_of_Place' $lon $lat }
    }
    [ordered]@{
        id                = $id
        address           = $addr
        matched_address   = $matched
        geocode_score     = $score
        lat               = $lat
        lon               = $lon
        zone              = $zoneName
        council           = $(if ($CHC) { $script:council } else { $null })
        flood_names       = $(if ($CHC) { $floodNames } else { $null })
        flood_plain       = $chk.plain
        flood_prone       = $chk.prone
        flood_sensitive   = $chk.sensitive
        special_character = $chk.sc
        historic_heritage = $chk.hh
        schools           = Get-Schools $lon $lat
        title             = $(if ($t) { [ordered]@{ title_no = $t.attributes.title_no; type = $t.attributes.type; estate = $t.attributes.estate_description; owners = $t.attributes.number_owners; shared_extent = $t.attributes.spatial_extents_shared } } else { 'not found' })
        services          = $(if ($t) { Get-Services $t } else { 'no parcel' })
        transport         = Get-Transport $lat $lon
        state_housing     = Get-StateHousing $lat $lon
        motorway          = Get-Motorway $lat $lon
        land              = $(if ($t) { Get-SiteShape $t $lat $lon } else { 'no parcel' })
        power_lines       = $(if ($t) { Get-PowerLines $t } else { 'no parcel' })
        flood_site        = $(if ($t) { Get-FloodShare $t } else { 'no parcel' })
    }
}

if ($InputCsv -and $JsonLines) {
    foreach ($r in Import-Csv $InputCsv) {
        $la = if ($r.lat) { [double]$r.lat } else { 0 }; $lo = if ($r.lon) { [double]$r.lon } else { 0 }
        $res = try { if ($FloodOnly) { $t = Get-Title $lo $la; [ordered]@{ id = $r.id; flood_site = $(if ($t) { Get-FloodShare $t } else { 'no parcel' }) } } else { Check-Site $r.id $r.address $la $lo } } catch { [ordered]@{ id = $r.id; address = $r.address; error = "$_" } }
        [IO.File]::AppendAllText($JsonLines, ($res | ConvertTo-Json -Depth 8 -Compress) + "`n", (New-Object Text.UTF8Encoding($false)))
    }
} elseif ($InputCsv) {
    $rows = Import-Csv $InputCsv
    $out = foreach ($r in $rows) {
        $la = if ($r.lat) { [double]$r.lat } else { 0 }; $lo = if ($r.lon) { [double]$r.lon } else { 0 }
        Check-Site $r.id $r.address $la $lo
    }
    ConvertTo-Json @($out) -Depth 8
} elseif ($Address) {
    Check-Site '' $Address $Lat $Lon | ConvertTo-Json -Depth 8
} else { throw 'Pass -Address or -InputCsv' }
