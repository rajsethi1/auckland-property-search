<#
  The daily cloud run (GitHub Actions, Windows PowerShell 5.1):
    1. pull the hunt's state (seen listings, site-check cache, market data, last report) from Hostinger by FTP
       — on the very first run, from this repo's seed-state folder instead;
    2. turn the site's saved lists into shortlist.json, so saved sites are tracked like starred ones;
    3. run scripts\run-daily.ps1 (search, screen, site checks, report, email body);
    4. stage the website (page + today's data.json) and the new state in an outbox, with an lftp script
       that the workflow's Linux job runs to upload them to Hostinger;
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
$ftpUser = $env:FTP_USER.Trim(); $ftpPass = $env:FTP_PASS.Trim()
"FTP_USER shape: '$($ftpUser -replace '[0-9]', '9' -replace '[A-Za-z]', 'a')' ($($ftpUser.Length) characters); FTP_PASS is $($ftpPass.Length) characters$(if ($ftpPass.Length -ne $env:FTP_PASS.Length -or $ftpUser.Length -ne $env:FTP_USER.Length) { ' (spaces or line breaks were trimmed)' })"
$ftp = "ftp://$hostName"; $cred = "$($ftpUser):$($ftpPass)"
# REGION=chc runs the Christchurch hunt: its own state folder, seed and data file; the pages are uploaded by the Auckland run.
$CHC = $env:REGION -eq 'chc'
$stateDir = if ($CHC) { 'hunt-state-chc' } elseif ($env:FTP_STATE_DIR) { $env:FTP_STATE_DIR.Trim('/') } else { 'hunt-state' }
$seedDir = if ($CHC) { "$repo\seed-state-chc" } else { "$repo\seed-state" }
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
# Uploads are staged in an outbox with an lftp script; the workflow's Linux job sends them.
# (Windows' own TLS ends encrypted FTP uploads in a way Hostinger rejects with 426, so uploads can't be done from here.)
$outbox = Join-Path $env:RUNNER_TEMP 'outbox'
New-Item -ItemType Directory -Force "$outbox\files" | Out-Null
$lftp = New-Object Collections.Generic.List[string]; $madeDirs = @{}; $staged = 0
function FtpPut($local, $remote, [switch]$Atomic) {
    $remote = $remote -replace '^\./', ''
    $script:staged++; $f = "files/$($script:staged)"   # numbered names: no quoting trouble in the lftp script
    Copy-Item $local (Join-Path $outbox $f)
    $dir = if ($remote -match '/') { $remote -replace '/[^/]*$', '' } else { '' }
    if ($dir -and -not $madeDirs.ContainsKey($dir)) { $madeDirs[$dir] = 1; $lftp.Add("mkdir -p -f `"$dir`"") }
    # Atomic: upload beside it, then swap in, so visitors never load a half-written file.
    if ($Atomic) { $lftp.Add("put `"$f`" -o `"$remote.new`""); $lftp.Add("rm -f `"$remote`""); $lftp.Add("mv `"$remote.new`" `"$remote`"") }
    else { $lftp.Add("put `"$f`" -o `"$remote`"") }
}
function FtpDel($remote) { $lftp.Add("rm -f `"$($remote -replace '^\./', '')`"") }

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
    Copy-Item "$seedDir\*" $root -Recurse -Force
    $oldReport = Get-ChildItem "$root\reports\*.json" -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { "reports/$($_.Name)" }
    "State: first run, seeded from the repo"
}

# No sale/CV ratios yet (a new region's first run): do the weekly refresh now so prices have a basis.
if (-not (Test-Path "$root\market-ratios.json")) { $weekly = $true; 'No market ratios yet: running the weekly refresh' }
New-Item -ItemType Directory -Force "$root\reports" | Out-Null

# ---- 2. Saved lists -> shortlist.json ----
# Each user has their own lists; the hunt tracks what the admins have saved (and any pre-login shared lists).
$ids = @()
if (FtpGet "$siteDir/api/data/lists.json" "$root\lists.json") {
    $store = [IO.File]::ReadAllText("$root\lists.json", $utf8) | ConvertFrom-Json
    if ($store.shortlist) { $ids += @($store.shortlist.PSObject.Properties.Name) }
    $admins = @()
    if (FtpGet "$siteDir/api/data/users.json" "$root\users.json") {
        $users = ([IO.File]::ReadAllText("$root\users.json", $utf8) | ConvertFrom-Json).users
        if ($users) { $admins = @($users.PSObject.Properties | Where-Object { $_.Value.admin } | ForEach-Object { $_.Name }) }
    }
    foreach ($a in $admins) { $sl = $store.users.$a.shortlist; if ($sl) { $ids += @($sl.PSObject.Properties.Name) } }
    $ids = @($ids | Sort-Object -Unique)
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
$pages = 'index.html', 'app.js', 'zone-codes.json', 'robots.txt', 'api/data/.htaccess', 'api/common.php', 'api/auth.php', 'api/admin.php', 'api/lists.php', 'api/data.php'
$sfx = if ($CHC) { '-chc' } else { '' }
if (-not $CHC) { foreach ($f in $pages) { FtpPut (Join-Path $site $f) "$siteDir/$f" } }
FtpPut "$root\reports\suburbs.json" "$siteDir/suburbs$sfx.json"
# The sites go in the closed api/data folder; api/data.php serves them to signed-in users only.
FtpPut "$root\reports\data.json" "$siteDir/api/data/data$sfx.json" -Atomic
# Remove the public copy older versions uploaded (no error if it's already gone).
if (-not $CHC) { FtpDel "$siteDir/data.json" }
"Website files staged"

# Keep only today's report in the state, written compact (the indented form is ~4x bigger).
$rep = "reports/$Date.json"
$compact = [IO.File]::ReadAllText("$root\$rep", $utf8) | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
[IO.File]::WriteAllText("$root\$rep", $compact, $utf8)
$stateFiles = @('config.json', 'seen.json', 'site-checks.jsonl', 'market-ratios.json', 'market-growth.json', 'school-zones.json',
    'slopes.json', 'sold-outcomes.json', 'auckland-suburbs.json', 'christchurch-suburbs.json', $rep) | Where-Object { Test-Path (Join-Path $root $_) }
foreach ($f in $stateFiles) { FtpPut (Join-Path $root $f) "$stateDir/$f" }
[IO.File]::WriteAllText("$root\manifest.txt", ($stateFiles -join "`n"), $utf8)
FtpPut "$root\manifest.txt" "$stateDir/manifest.txt"
Set-Content "$root\deny.htaccess" "Require all denied" -Encoding ascii
FtpPut "$root\deny.htaccess" "$stateDir/.htaccess"
if ($oldReport -and $oldReport -ne $rep) { FtpDel "$stateDir/$oldReport" }
# The manifest goes last, so a broken upload never points the next run at files that aren't there.
$i = $lftp.FindIndex([Predicate[string]] { param($x) $x -like '*manifest.txt"' })
if ($i -ge 0) { $m = $lftp[$i]; $lftp.RemoveAt($i); $lftp.Add($m) }
[IO.File]::WriteAllText("$outbox\upload.lftp", (($lftp -join "`n") + "`n"), $utf8)
[IO.File]::WriteAllText("$outbox\host.txt", $hostName, $utf8)
"State staged: $($stateFiles.Count) files; $($lftp.Count) upload steps for the Linux job"

# ---- 5. Email (optional) ----
$mail = "$root\reports\email-$Date.html"
if (-not $CHC -and $env:SMTP_HOST -and $env:SMTP_USER -and $env:SMTP_PASS -and (Test-Path $mail)) {
    $cfg = [IO.File]::ReadAllText("$root\config.json", $utf8) | ConvertFrom-Json
    $pw = ConvertTo-SecureString $env:SMTP_PASS -AsPlainText -Force
    $c = New-Object Management.Automation.PSCredential($env:SMTP_USER, $pw)
    $summary = ([IO.File]::ReadAllText("$root\reports\$Date.json", $utf8) | ConvertFrom-Json).summary
    Send-MailMessage -SmtpServer $env:SMTP_HOST -Port 587 -UseSsl -Credential $c -From $env:SMTP_USER -To @($cfg.email_to) `
        -Subject "Auckland sites $Date - $summary" -Body ([IO.File]::ReadAllText($mail, $utf8)) -BodyAsHtml -Encoding UTF8
    "Email sent to $(@($cfg.email_to) -join ', ')"
} else { 'Email skipped (no SMTP settings)' }
