# PinWall — progress log

A Mac screensaver that shows my Pinterest feed as a scrolling tiled wall.
Black background, slow scroll, blooms in from the bottom, never restarts from the top.

## Status: working ✅ (including the entrance animation)

## The pieces

- **pinwall.html** — the screensaver itself. Masonry columns, clock-anchored
  scroll, deterministic shuffle per feed, bottom-to-top fade-in on start, a hidden
  live tuner (press `T`), reloads itself every 60 min for fresh pins. Also holds
  gallery mode (`?gallery=1`) — same wall, hand-driveable, clickable.
- **gallery.html** — a one-line redirect to `pinwall.html?gallery=1`. Exists only
  because macOS `open` eats the query string (see dead ends).
- **pins.js** — just my pin URLs (`window.PINS = [...]`). Written by the harvester,
  read by pinwall.html. Keeping pins separate means I can update the screensaver
  code without re-harvesting.
- **harvest_feed.py** — logs into Pinterest in a real browser (Playwright),
  scrolls my home feed, and writes the image URLs to `pins.js`.
- **WebViewScreenSaver** — open-source screensaver that points at a local web
  page. Credit: liquidx. This project is just the wall + harvester on top.

## Where stuff lives

- `~/pinwall/` — pinwall.html, gallery.html, pins.js, harvest_feed.py
- `~/.pinwall-session` — the Pinterest login (kept out of the project folder)
- `~/Library/Screen Savers/WebViewScreenSaver.saver` — the engine
- Screensaver URL: `file:///Users/aditya/pinwall/pinwall.html?speed=36&fade=1200&rise=0&stagger=800&delay=600`
- (optional) `~/Library/LaunchAgents/com.aditya.pinwall.plist` — hourly auto-refresh

## Gallery mode — going back to a pin that scrolled past

`open ~/pinwall/gallery.html`. Scroll or drag either direction, click a pin to
open it on Pinterest, arrows/PageUp/PageDown to step, `Space` toggles the drift,
`L` snaps to the live position.

- The wall is a `transform` loop on an `overflow:hidden` page, so there's no
  native scroll to hijack. Offset is `vt * speed`, so moving `dy` pixels is just
  `vt += dy / speed` — one `nudge()` drives wheel, drag and keys alike.
- Screensaver mode reads the real clock (`Date.now()`); gallery mode swaps in a
  virtual `vt` **initialised to the real clock**, so it opens on exactly the wall
  the screensaver is showing and scrolling up = what just went past.
- Auto-scroll starts *off* in gallery mode — you're there to hunt, not watch.
  Any manual scroll also switches it off.
- A drag >4px swallows the click so panning doesn't fire off a pin.

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
- Browse the wall by hand / click through to Pinterest: `open ~/pinwall/gallery.html`.

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
- **macOS `open` silently eats the query string off a `file://` URL.**
  `open "file://.../pinwall.html?gallery=1"` loads plain `pinwall.html` --
  LaunchServices resolves it to a filesystem path and `?` isn't valid in one.
  Symptom: the wall looks right but there's no cursor and nothing is clickable,
  i.e. you're in screensaver mode and don't realise it. `open -a "Google Chrome"`
  and `osascript -e 'open location ...'` drop it too. What *does* work: the Chrome
  binary directly (`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  "file://...?gallery=1"`) or Chrome's AppleScript `make new tab`.
  **Fix:** `gallery.html`, a one-line `location.replace('pinwall.html?gallery=1')`.
  `open` gets a bare path, and the redirect is an in-browser navigation where the
  query survives -- works in whatever the default browser is.

## The scary popup

WebViewScreenSaver isn't notarized -> "Apple could not verify" on first run.
Click **Done**, then System Settings -> Privacy & Security -> **Open Anyway**.
(The setup script auto-handles this with `xattr`.)

## Sharing it

- `setup.sh` = one-command installer (embeds pinwall.html + gallery.html +
  harvest_feed.py, installs everything, skips the Gatekeeper popup).
- Editing the wall means editing it in **two** places: `~/pinwall/pinwall.html`
  (what actually runs) and the `HTMLEOF` heredoc in `setup.sh` (what ships).
  Diff the two before committing:
  `awk '/^cat > pinwall.html/{f=1;next} /^HTMLEOF$/{f=0} f' setup.sh | diff - ~/pinwall/pinwall.html`
- Repo: github.com/adityasinghsfs/pinwall
- **Never commit `~/.pinwall-session` or `pins.js`** -- that's my login and my feed.
  They live outside the repo; the repo only holds `setup.sh`, `README.md`, `PROGRESS.md`.

## Maybe later

- Other sources (specific boards, or a local folder of images)
- The "sellable" clean version (no scraping) if I ever want to ship it
