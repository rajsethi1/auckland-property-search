# Auckland Property Search — setup

How it works: every morning at about 6am NZ time, GitHub (free) runs the hunt in the cloud, then uploads the
website and today's data to your Hostinger hosting by FTP. Nothing runs on your PC.

```
GitHub Actions (6am)  ──FTP──►  Hostinger
  scripts/run-daily.ps1           public_html/   index.html, data.json, api/lists.php (saved lists)
  cloud/run.ps1                   hunt-state/    the hunt's memory (seen listings, site-check cache, last report)
```

## 1. Hostinger (about 10 minutes)

1. **Website on a temporary domain.** hPanel → Websites → Add website → choose *Empty website* (no WordPress).
   Pick the free temporary domain Hostinger offers (something like `xyz.hostingersite.com`). Write it down.
2. **FTP details.** hPanel → that website → Files → **FTP Accounts**. Note:
   - **FTP host** (an IP address or `ftp.…`), **username**, and set/reset the **password**.
   - The folder the FTP account opens in. If it opens in a folder that *contains* `public_html`, you're done.
     If it opens *inside* `public_html`, set the GitHub variable `FTP_SITE_DIR` to `.` (step 2.4).
3. **Password-protect the site.** hPanel → Advanced → **Password Protect Directories** → folder `public_html`
   → add a username and password. Share that login with Vanessa. (The page also tells search engines not to list it.)

## 2. GitHub (about 15 minutes)

1. Create a free account at github.com (if you don't have one).
2. New repository → name `auckland-property-search` → **Private** → Create.
3. On the empty repo page click **uploading an existing file**, then drag in everything inside
   `C:\Claude\Personal\auckland-property-search` (the folders `.github`, `assets`, `cloud`, `scripts`, `seed-state`, `site`
   and this file). If Windows hides `.github`, turn on View → Show → Hidden items first. Click **Commit changes**.
4. Repo → Settings → **Secrets and variables** → Actions:
   - **Secrets** (New repository secret): `FTP_HOST`, `FTP_USER`, `FTP_PASS` — from step 1.2.
   - **Variables** tab: `SITE_URL` = `https://<your temporary domain>`; and `FTP_SITE_DIR` = `.` only if step 1.2 said so.
5. Repo → **Actions** tab → enable workflows if asked → *Daily property hunt* → **Run workflow**.
   The first run takes 20–40 minutes. Green tick = done; open your temporary domain and log in.

After that it runs by itself every morning. To run it on demand: Actions → Daily property hunt → Run workflow.
Tick *weekly* to also refresh sale/CV ratios (it does this automatically on Sundays).

## 3. Later

- **Real domain:** register `aucklandpropertysearch.co.nz` in hPanel → Domains (about $30 NZD/yr), connect it to the
  website, then change the `SITE_URL` variable.
- **Daily email from the cloud:** once the domain has a mailbox (hPanel → Emails), add secrets `SMTP_HOST`
  (`smtp.hostinger.com`), `SMTP_USER` (the mailbox address) and `SMTP_PASS`. Without them the run skips the email.
- **Turn off the Claude morning task** (`property-hunt-morning`) once the cloud run has worked for a few days, so it
  stops using Claude tokens.

## Notes

- Saved lists live on Hostinger (`public_html/api/data/lists.json`); anyone with the site login can change them.
- Slope (LiDAR) isn't checked in the cloud; new sites show slope as Unknown.
- If realestate.co.nz starts blocking GitHub's servers, the run's log will show the search finding 0 listings.
- `seed-state` is only used for the very first run. After that the state lives on Hostinger.
