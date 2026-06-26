# PinWall — progress log

A Mac screensaver that shows my Pinterest feed as a scrolling tiled wall.
Black background, slow scroll, blooms in from the bottom, never restarts from the top.

## Status: working ✅ (including the entrance animation)

## The pieces

- **pinwall.html** — the screensaver itself. Masonry columns, clock-anchored
  scroll, deterministic shuffle per feed, bottom-to-top fade-in on start, a hidden
  live tuner (press `T`), reloads itself every 60 min for fresh pins.
- **pins.js** — just my pin URLs (`window.PINS = [...]`). Written by the harvester,
  read by pinwall.html. Keeping pins separate means I can update the screensaver
  code without re-harvesting.
- **harvest_feed.py** — logs into Pinterest in a real browser (Playwright),
  scrolls my home feed, and writes the image URLs to `pins.js`.
- **WebViewScreenSaver** — open-source screensaver that points at a local web
  page. Credit: liquidx. This project is just the wall + harvester on top.

## Where stuff lives

- `~/pinwall/` — pinwall.html, pins.js, harvest_feed.py
- `~/.pinwall-session` — the Pinterest login (kept out of the project folder)
- `~/Library/Screen Savers/WebViewScreenSaver.saver` — the engine
- Screensaver URL: `file:///Users/aditya/pinwall/pinwall.html?speed=36&fade=1200&rise=0&stagger=800&delay=600`
- (optional) `~/Library/LaunchAgents/com.aditya.pinwall.plist` — hourly auto-refresh

## The knobs (all URL params, or tune live with the T key in a browser)

- `speed` — scroll px/sec (lower = slower)
- `fade` — per-tile fade duration (ms)
- `rise` — how far each tile rises in (px); 0 = pure fade
- `stagger` — spread of the bottom-to-top wave (ms)
- `delay` — how long to hold black before blooming (ms) — lets the macOS crossfade finish first
- `debug=1` — shows a live readout (loaded/shown counts, etc.) for diagnosing

## Use / maintain

- Update the screensaver code: just replace `pinwall.html`. Pins stay put, no harvest.
- Fresh pins: `cd ~/pinwall && python3 harvest_feed.py` (rewrites `pins.js` only).
- Pinterest logs me out every few weeks -> run harvest once to re-login.
- Tile size: `COLUMN_WIDTH` near the top of pinwall.html.

## Decisions & dead ends (so I don't repeat them)

- Home feed isn't in RSS or the API -> automate a logged-in browser. Against
  Pinterest's ToS, personal use only.
- "Resume where I left off" via `localStorage` -> WKWebView drops the writes when
  the screensaver is force-killed. Then a localhost server to fix it -> overkill.
  **Final answer:** clock-anchored scroll. Position is math from the current time,
  so it resumes by definition. No storage, no server.
- Shuffle seeded from the feed signature -> stable layout until the feed changes.
- Pins were baked into pinwall.html -> every code update wiped them and forced a
  re-harvest. **Fix:** split pins into `pins.js`.
- Entrance animation looked broken in the real screensaver. Debugging chain:
  - Pasted URL had a double `??` -> params didn't parse. (One `?` only.)
  - WKWebView was serving a **cached** old build -> bust it by renaming the file
    (pinwall2/3/4...) or "Clear Browser Data" in WVSS Options.
  - Tiles faded in **empty** because images downloaded after the fade -> fade each
    tile only once **its own** image is decoded (`img.decode()` then `.show`).
  - The bloom was real but **racing the macOS screensaver crossfade**, so it played
    under the system fade and looked instant -> added `delay` (~600ms) to hold black
    until the crossfade finishes, then bloom. The WVSS log + `debug=1` readout
    (started:true, loaded:200/200, shown:20) is what proved this.
  - Don't trust `document.visibilityState` in a screensaver -- it lies. Just run on
    load; the screensaver loads the page exactly when it shows it.

## The scary popup

WebViewScreenSaver isn't notarized -> "Apple could not verify" on first run.
Click **Done**, then System Settings -> Privacy & Security -> **Open Anyway**.
(The setup script auto-handles this with `xattr`.)

## Sharing it

- `setup.sh` = one-command installer (embeds pinwall.html + harvest_feed.py,
  installs everything, skips the Gatekeeper popup).
- Repo: github.com/adityasinghsfs/pinwall
- **Never commit `~/.pinwall-session` or `pins.js`** -- that's my login and my feed.
  They live outside the repo; the repo only holds `setup.sh`, `README.md`, `PROGRESS.md`.

## Maybe later

- Other sources (specific boards, or a local folder of images)
- The "sellable" clean version (no scraping) if I ever want to ship it
