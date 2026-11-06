<#
  The daily cloud run (GitHub Actions, Windows PowerShell 5.1):
    1. pull the hunt's state (seen listings, site-check cache, market data, last report) from Hostinger by FTP
       — on the very first run, from this repo's seed-state folder instead;
    2. turn the site's saved lists into shortlist.json, so saved sites are tracked like starred ones;
    3. run scripts\run-daily.ps1 (search, screen, site checks, report, email body);
    4. upload the website (page + today's data.json) and the new state back to Hostinger;
    5. email the short summary when SMTP settings are present.
  Settings come from the workflow's secrets/variables: FTP_HOST, FTP_USER, FTP_PASS, FTP_SITE_DIR (default public_html),
  FTP_STATE_DIR (default hunt-state), SITE_URL, SMTP_HOST, SMTP_USER, SMTP_PASS. WEEKLY=true forces the weekly refresh.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$root = Join-Path $env:RUNNER_TEMP 'hunt'
$env:HUNT_ROOT = $root
New-Item -ItemType Directory -Force "$root\reports" | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
foreach ($v in 'FTP_HOST', 'FTP_USER', 'FTP_PASS') { if (-not [Environment]::GetEnvironmentVariable($v)) { throw "Missing secret $v" } }
# Pull a bare host name or IP (optionally :port) out of FTP_HOST, whatever else was pasted with it.
$hostRaw = $env:FTP_HOST -replace '[a-z]+://', ''
$hostName = [regex]::Match($hostRaw, '[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d+)?').Value
"FTP_HOST shape: '$($hostRaw -replace '[0-9]', '9' -replace '[A-Za-z]', 'a' -replace "`r|`n", '<newline>')' -> using a $($hostName.Length)-character host"
if (-not $hostName) { throw 'FTP_HOST does not contain a host name or IP address' }
$ftp = "ftp://$hostName"; $cred = "$($env:FTP_USER):$($env:FTP_PASS)"
$stateDir = if ($env:FTP_STATE_DIR) { $env:FTP_STATE_DIR.Trim('/') } else { 'hunt-state' }
# Check the FTP login before the long hunt, so a bad host or password fails in seconds, not after 25 minutes.
# Encrypted FTP (FTPS). Hostinger's certificate names its server, not the IP, so if it can't be verified (curl 60)
# keep the encryption but skip the name check.
$tls = @('--ssl-reqd')
& curl.exe -s @tls -l -u $cred "$ftp/" -o NUL
if ($LASTEXITCODE -eq 60) {
    "FTPS certificate doesn't match '$hostName': connecting encrypted without the certificate name check"
    $tls = @('--ssl-reqd', '--insecure')
    & curl.exe -s @tls -l -u $cred "$ftp/" -o NUL
}
if ($LASTEXITCODE) { throw "Can't log in to FTP (curl error $($LASTEXITCODE); 6/7 = host unreachable, 67 = wrong username or password)" }
# Hostinger FTP logins open either above public_html or inside it: use public_html when the login can see it.
$siteDir = if ($env:FTP_SITE_DIR) { $env:FTP_SITE_DIR.Trim('/') } else {
    & curl.exe -s @tls -l -u $cred "$ftp/public_html/" -o NUL
    if ($LASTEXITCODE -eq 0) { 'public_html' } else { '.' }
}
"FTP: website folder '$siteDir', state folder '$stateDir'"

# curl.exe ships with Windows; @tls uses FTPS when the server offers it.
# FtpGet is fully silent (-s): a missing file is normal on the first run, and stderr text would stop the script under 'Stop'.
function FtpGet($remote, $local) {
    $remote = $remote -replace '^\./', ''
    if (Test-Path $local) { Remove-Item $local }
    & curl.exe -s @tls --create-dirs -u $cred -o $local "$ftp/$remote"
    ($LASTEXITCODE -eq 0) -and (Test-Path $local)
}
function FtpPut($local, $remote, [switch]$Atomic) {
    $remote = $remote -replace '^\./', ''
    if ($Atomic) {
        # Upload under a temporary name, then rename, so visitors never load a half-written file.
        $name = Split-Path $remote -Leaf
        & curl.exe -sS @tls --ftp-create-dirs -u $cred -T $local "$ftp/$remote.new" -Q "-RNFR $name.new" -Q "-RNTO $name"
    } else { & curl.exe -sS @tls --ftp-create-dirs -u $cred -T $local "$ftp/$remote" }
    if ($LASTEXITCODE) { throw "FTP upload failed ($LASTEXITCODE): $remote" }
}

# NZ date, so a 6am run is named for the NZ day.
$nz = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'New Zealand Standard Time')
$Date = $nz.ToString('yyyy-MM-dd')
$weekly = $env:WEEKLY -eq 'true' -or $nz.DayOfWeek -eq 'Sunday'
"Run date $Date (weekly: $weekly)"

# ---- 1. State ----
$oldReport = $null
if (FtpGet "$stateDir/manifest.txt" "$root\manifest.txt") {
    $files = @([IO.File]::ReadAllLines("$root\manifest.txt") | Where-Object { $_.Trim() })
    foreach ($f in $files) { if (-not (FtpGet "$stateDir/$f" (Join-Path $root $f))) { throw "Could not download state file $f" } }
    $oldReport = $files | Where-Object { $_ -match '^reports/' } | Select-Object -First 1
    "State: $($files.Count) files from Hostinger"
} else {
    Copy-Item "$repo\seed-state\*" $root -Recurse -Force
    $oldReport = Get-ChildItem "$root\reports\*.json" | Select-Object -First 1 | ForEach-Object { "reports/$($_.Name)" }
    "State: first run, seeded from the repo"
}

# ---- 2. Saved lists -> shortlist.json ----
$ids = @()
if (FtpGet "$siteDir/api/data/lists.json" "$root\lists.json") {
    $store = [IO.File]::ReadAllText("$root\lists.json", $utf8) | ConvertFrom-Json
    if ($store.shortlist) { $ids = @($store.shortlist.PSObject.Properties.Name) }
}
[IO.File]::WriteAllText("$root\shortlist.json", (ConvertTo-Json @($ids) -Compress), $utf8)
"Saved sites: $($ids.Count)"

# The email links to the website.
if ($env:SITE_URL) {
    $cfg = [IO.File]::ReadAllText("$root\config.json", $utf8) | ConvertFrom-Json
    $cfg.report_url = $env:SITE_URL
    [IO.File]::WriteAllText("$root\config.json", ($cfg | ConvertTo-Json -Depth 8), $utf8)
}

# ---- 3. The hunt ----
$runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$repo\scripts\run-daily.ps1", '-Date', $Date)
if ($weekly) { $runArgs += '-Weekly' }
& powershell @runArgs
if ($LASTEXITCODE) { throw "run-daily.ps1 failed ($LASTEXITCODE)" }
if (-not (Test-Path "$root\reports\data.json")) { throw 'No data.json was produced' }

# ---- 4. Website, then state ----
$site = Join-Path $repo 'site'
foreach ($f in 'index.html', 'zone-codes.json', 'robots.txt', 'api/lists.php', 'api/data/.htaccess') { FtpPut (Join-Path $site $f) "$siteDir/$f" }
FtpPut "$root\reports\suburbs.json" "$siteDir/suburbs.json"
FtpPut "$root\reports\data.json" "$siteDir/data.json" -Atomic
"Website updated"

# Keep only today's report in the state, written compact (the indented form is ~4x bigger).
$rep = "reports/$Date.json"
$compact = [IO.File]::ReadAllText("$root\$rep", $utf8) | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
[IO.File]::WriteAllText("$root\$rep", $compact, $utf8)
$stateFiles = @('config.json', 'seen.json', 'site-checks.jsonl', 'market-ratios.json', 'market-growth.json', 'school-zones.json',
    'slopes.json', 'sold-outcomes.json', 'auckland-suburbs.json', $rep) | Where-Object { Test-Path (Join-Path $root $_) }
foreach ($f in $stateFiles) { FtpPut (Join-Path $root $f) "$stateDir/$f" }
[IO.File]::WriteAllText("$root\manifest.txt", ($stateFiles -join "`n"), $utf8)
FtpPut "$root\manifest.txt" "$stateDir/manifest.txt"
Set-Content "$root\deny.htaccess" "Require all denied" -Encoding ascii
FtpPut "$root\deny.htaccess" "$stateDir/.htaccess"
if ($oldReport -and $oldReport -ne $rep) { & curl.exe -s @tls -u $cred "$ftp/" -Q "DELE $stateDir/$oldReport" -o NUL }
"State saved: $($stateFiles.Count) files"

# ---- 5. Email (optional) ----
$mail = "$root\reports\email-$Date.html"
if ($env:SMTP_HOST -and $env:SMTP_USER -and $env:SMTP_PASS -and (Test-Path $mail)) {
    $cfg = [IO.File]::ReadAllText("$root\config.json", $utf8) | ConvertFrom-Json
    $pw = ConvertTo-SecureString $env:SMTP_PASS -AsPlainText -Force
    $c = New-Object Management.Automation.PSCredential($env:SMTP_USER, $pw)
    $summary = ([IO.File]::ReadAllText("$root\reports\$Date.json", $utf8) | ConvertFrom-Json).summary
    Send-MailMessage -SmtpServer $env:SMTP_HOST -Port 587 -UseSsl -Credential $c -From $env:SMTP_USER -To @($cfg.email_to) `
        -Subject "Auckland sites $Date - $summary" -Body ([IO.File]::ReadAllText($mail, $utf8)) -BodyAsHtml -Encoding UTF8
    "Email sent to $(@($cfg.email_to) -join ', ')"
} else { 'Email skipped (no SMTP settings)' }
