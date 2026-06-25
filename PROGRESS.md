# PinWall — progress log

A Mac screensaver that shows my Pinterest feed as a scrolling tiled wall.
Black background, slow scroll, never restarts from the top.

## Status: working ✅

Everything's running on my Mac. Two files + an open-source screensaver engine.

## The 3 pieces

- **pinwall.html** — the actual screensaver. Masonry columns, clock-anchored
  scroll, deterministic shuffle per feed, reloads itself every 60 min for fresh pins.
- **harvest_feed.py** — logs into Pinterest in a real browser (Playwright),
  scrolls my home feed, and bakes ~100 image URLs into pinwall.html.
- **WebViewScreenSaver** — open-source screensaver that points at a local web
  page. Credit: liquidx. This project is just the wall + the harvester on top.

## Where stuff lives

- `~/pinwall/` — pinwall.html, harvest_feed.py
- `~/.pinwall-session` — the Pinterest login session (kept out of the project folder on purpose)
- `~/Library/Screen Savers/WebViewScreenSaver.saver` — the engine
- Screensaver URL: `file:///Users/aditya/pinwall/pinwall.html?speed=18`
- (optional) `~/Library/LaunchAgents/com.aditya.pinwall.plist` — hourly auto-refresh

## Use / maintain

- Refresh feed manually: `cd ~/pinwall && python3 harvest_feed.py`
- Change speed: edit `?speed=` in the screensaver URL (lower = slower)
- Change tile size: `COLUMN_WIDTH` in pinwall.html
- Change refresh cadence: `RELOAD_MINUTES` in pinwall.html (match the launchd interval)
- Pinterest logs me out every few weeks → just run harvest once to re-login
  (session is saved at `~/.pinwall-session`)

## Decisions & dead ends (so I don't repeat them)

- The Pinterest home feed isn't in RSS or the public API → had to automate a
  logged-in browser. It's against Pinterest's ToS, personal use only.
- Tried `localStorage` to "resume where I left off" → WKWebView drops the writes
  when the screensaver gets force-killed on unlock. Unreliable.
- Tried a localhost server to make storage stick → worked, but overkill and
  another thing to keep alive.
- **Final answer:** anchor the scroll to the clock. No storage, no server.
  Position is derived by math from the current time, so it resumes by definition
  and never restarts.
- Shuffle is seeded from the feed signature, so the layout stays stable until the
  feed actually changes — then it reshuffles into a fresh wall.

## The scary popup

WebViewScreenSaver isn't notarized → "Apple could not verify" on first run.
Click **Done**, then System Settings → Privacy & Security → **Open Anyway**.
(The setup script auto-handles this with `xattr`.)

## Sharing it

- `setup.sh` = one-command installer (embeds both files, installs everything).
- Repo: github.com/adityasinghsfs/pinwall
- **Never commit `~/.pinwall-session`** — that's my Pinterest login. It lives
  outside the project folder, so the repo only holds `setup.sh` + `README.md`.

## Maybe later

- Companion app / other sources (specific boards, or a local folder of images)
- The "sellable" clean version (no scraping, pulls from a folder or the official
  API) if I ever want to actually ship it
