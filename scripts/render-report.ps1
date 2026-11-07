<#
  Builds reports\report.html (small page, no data) and reports\data.json (the day's report) for publishing together:
    Artifact publish  file_path = reports\report.html,  files = { "data.json": "<root>\reports\data.json" }
  Keeping the data out of the page keeps reads and republishes of the artifact small.
  Usage: powershell -NoProfile -File render-report.ps1 -Date 2026-10-31
#>
param([Parameter(Mandatory = $true)][string]$Date)

$ErrorActionPreference = 'Stop'
# Data folder: HUNT_ROOT when set (the cloud run), else the local folder.
function HuntRoot { if ($env:HUNT_ROOT) { $env:HUNT_ROOT } else { 'C:\Claude\Personal\property-hunt' } }
$reports = "$(HuntRoot)\reports"
$json = Join-Path $reports "$Date.json"
if (-not (Test-Path $json)) { throw "No report data at $json" }
$enc = New-Object Text.UTF8Encoding($false)
# Compact JSON: Auckland-wide runs list 1,000+ sites and the indented form is ~3x bigger (16 MB publish limit per file).
$compact = [IO.File]::ReadAllText($json, [Text.Encoding]::UTF8) | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
[IO.File]::WriteAllText((Join-Path $reports 'data.json'), $compact, $enc)
# Auckland districts -> suburbs (from realestate.co.nz's location list) for the page's grouped Suburbs filter.
$subsSrc = @("$(HuntRoot)\auckland-suburbs.json", "$(HuntRoot)\christchurch-suburbs.json") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (Test-Path $subsSrc) { Copy-Item $subsSrc (Join-Path $reports 'suburbs.json') -Force }
$html = [IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot '..\assets\report-template.html')), [Text.Encoding]::UTF8)
$out = Join-Path $reports 'report.html'
[IO.File]::WriteAllText($out, $html, $enc)
Write-Output $out
