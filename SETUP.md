# PropertyHunte — setup

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

## Sign-in and accounts

- The first person to open the site after the sign-in update gets **"Set up your site"** and becomes the **admin**.
  Do this yourself straight away, while the hPanel password is still on.
- Then remove the hPanel password (Advanced → Password Protect Directories → delete the `public_html` entry),
  so people only see the site's own sign-in.
- **Admin** page (top menu): the invite code to send people, *New code* (stops the old one working),
  *Close sign-up*, reset someone's password (shows a temporary one to send them), make or remove admins, remove users.
- Everyone has their own saved lists. The daily run tracks the admins' saved sites.
- Accounts and lists live in `public_html/api/data/` (`users.json`, `lists.json`), which the web can't read directly.
  Passwords are stored hashed.

## 3. Later

- **Domain propertyhunte.com:** in hPanel → Websites → this site → **Change domain** (or Domains → connect it to this
  website) so the same files and `public_html` keep working. Turn on SSL for it, then change the repo variable
  `SITE_URL` to `https://propertyhunte.com`. If hPanel gives the site a new FTP host, update the `FTP_HOST` secret too.
- **Forgot password emails** are sent by the site itself (PHP mail) from `noreply@<your domain>`. They arrive
  reliably once the domain is on Hostinger with its email (SPF/DKIM) set up; until then they may land in spam.
  People without an email on their account show a red "Forgot password" tag on the Admin page instead.
- **Daily email from the cloud:** once the domain has a mailbox (hPanel → Emails), add secrets `SMTP_HOST`
  (`smtp.hostinger.com`), `SMTP_USER` (the mailbox address) and `SMTP_PASS`. Without them the run skips the email.
- **Turn off the Claude morning task** (`property-hunt-morning`) once the cloud run has worked for a few days, so it
  stops using Claude tokens.

## Christchurch

- The daily workflow runs two hunts side by side: `akl` (Auckland, also uploads the website pages) and `chc`
  (Christchurch). Each has its own saved state on Hostinger (`hunt-state` and `hunt-state-chc`); Christchurch
  writes `api/data/data-chc.json` and `suburbs-chc.json`. If one city fails, the other still updates.
- Christchurch's first run starts from `seed-state-chc` and does the weekly price refresh straight away, so it
  takes longer (roughly 30-60 minutes).
- Christchurch checks use Christchurch City Council's District Plan (zones, High Flood Hazard, Flood Management,
  Fixed Floor Level, Residential Character, heritage settings), council stormwater/wastewater pipes, and Metro bus
  stops. No train or motorway checks, and no suburb growth history yet.
- People switch city with the selector at the top of the site.

## Notes

- The hunt keeps every listing (no land, price, bedroom or type limits); people filter on the site. Each run checks
  at most 500 new listings (config `max_new_per_run`), newest first, so a big backlog fills in over several days.
- The site data is split: `api/data/data.json` is a light list of every site, and `api/data/parts/00-63.json`
  (`parts-chc/` for Christchurch) hold the full details, loaded when someone opens a property.

- Saved lists and budgets live on Hostinger (`public_html/api/data/lists.json`), one set per person.
- Slope (LiDAR) isn't checked in the cloud; new sites show slope as Unknown.
- If realestate.co.nz starts blocking GitHub's servers, the run's log will show the search finding 0 listings.
- `seed-state` is only used for the very first run. After that the state lives on Hostinger.
