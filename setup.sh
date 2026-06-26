#!/bin/bash
#
#  PinWall — one-shot installer
#  A Pinterest-feed Mac screensaver: tiled, black, slow-scrolling, blooms in from
#  the bottom, never restarts. Built on top of WebViewScreenSaver (open source).
#
#  Run:  bash setup.sh
#
#  Heads up: this logs into Pinterest in an automated browser to grab your feed.
#  It's a personal hack and technically against Pinterest's ToS — fine for your
#  own machine, just know that going in.
#

DIR="$HOME/pinwall"
mkdir -p "$DIR"
cd "$DIR" || exit 1

echo ""
echo "==> Setting up PinWall in $DIR"

# ---------------------------------------------------------------------------
# 1. Write the screensaver page
# ---------------------------------------------------------------------------
cat > pinwall.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
<title>PinWall</title>
<style>
  html, body { margin: 0; height: 100%; background: #000; overflow: hidden; cursor: none; }
  body.tuning, body.gallery { cursor: auto; }
  #viewport { position: fixed; inset: 0; display: flex; gap: var(--gap);
    padding: var(--gap); box-sizing: border-box; background: #000; }
  .col { flex: 1; position: relative; will-change: transform; }
  .col img { width: 100%; display: block; margin-bottom: var(--gap);
    border-radius: 12px; background: #0b0b0b; -webkit-user-select: none; user-select: none;
    opacity: 0; transform: translateY(var(--rise));
    transition: opacity var(--fade) ease-out, transform var(--fade) ease-out; }
  .col img.show    { opacity: 1; transform: none; }
  .col img.instant { opacity: 1; transform: none; transition: none; }
  /* gallery mode: clickable tiles */
  body.gallery .col img { cursor: pointer; }
  body.gallery .col img.show:hover, body.gallery .col img.instant:hover {
    transform: scale(1.03); box-shadow: 0 0 0 2px #fff; transition: transform 150ms ease; }

  #tuner { position: fixed; top: 16px; left: 16px; z-index: 9999; display: none; width: 240px;
    background: rgba(20,20,22,.92); color: #e8e8ea; backdrop-filter: blur(10px);
    font: 12px/1.4 -apple-system, system-ui, sans-serif; padding: 14px 16px;
    border-radius: 12px; box-shadow: 0 10px 34px rgba(0,0,0,.55); }
  #tuner.open { display: block; }
  #tuner h4 { margin: 0 0 4px; font-size: 12px; font-weight: 600; letter-spacing: .02em; }
  #tuner label { display: flex; justify-content: space-between; margin: 12px 0 4px; opacity: .7; }
  #tuner input[type=range] { width: 100%; accent-color: #fff; }
  #tuner .row { display: flex; gap: 8px; margin-top: 14px; }
  #tuner button { flex: 1; background: #2a2a2e; color: #fff; border: 0; padding: 7px;
    border-radius: 8px; cursor: pointer; font: inherit; }
  #tuner button:hover { background: #3a3a40; }
  #tuner code { display: block; margin-top: 10px; padding: 8px; background: #000;
    border-radius: 6px; word-break: break-all; opacity: .85; font-size: 11px; }
  #tuner .hint { margin-top: 8px; opacity: .45; font-size: 11px; }
  #ghint { position: fixed; bottom: 14px; left: 50%; transform: translateX(-50%); z-index: 9999;
    display: none; font: 12px/1 -apple-system, system-ui, sans-serif; color: #fff;
    background: rgba(0,0,0,.55); padding: 8px 14px; border-radius: 20px; backdrop-filter: blur(8px); }
  body.gallery #ghint { display: block; }
</style>
</head>
<body>
<div id="viewport"></div>
<div id="ghint">Gallery — hover to pause, click a pin to open it on Pinterest</div>

<div id="tuner">
  <h4>PinWall tuner</h4>
  <label>Speed <span id="vSpeed"></span></label>
  <input type="range" id="sSpeed" min="2" max="120" step="1">
  <label>Fade (ms) <span id="vFade"></span></label>
  <input type="range" id="sFade" min="0" max="1200" step="10">
  <label>Rise (px) <span id="vRise"></span></label>
  <input type="range" id="sRise" min="0" max="120" step="1">
  <label>Stagger (ms) <span id="vStagger"></span></label>
  <input type="range" id="sStagger" min="0" max="1500" step="10">
  <div class="row">
    <button id="bReplay">Replay</button>
    <button id="bCopy">Copy URL</button>
  </div>
  <code id="urlOut"></code>
  <div class="hint">Press T to hide. Append this to your screensaver URL.</div>
</div>

<script>
// ---- defaults --------------------------------------------------------------
const SPEED          = 24;
const COLUMN_WIDTH   = 320;
const GAP            = 14;
const RELOAD_MINUTES = 60;
const FADE_MS        = 300;
const RISE_PX        = 24;
const STAGGER_MS     = 350;
const START_DELAY    = 600;

// ---- pure helpers ----------------------------------------------------------
function demoPins() {
  const heights = [360, 480, 300, 540, 420, 600, 380, 460, 320, 500];
  const out = [];
  for (let i = 1; i <= 48; i++) out.push({ img: `https://picsum.photos/seed/pin${i}/600/${heights[i % heights.length]}`, link: "" });
  return out;
}
function signature(arr) {
  let h = 5381; const s = arr.join('|');
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
  return arr.length + ':' + (h >>> 0);
}
function seedFrom(str) { let h = 2166136261 >>> 0;
  for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
function mulberry32(a) { return function () { a |= 0; a = a + 0x6D2B79F5 | 0;
  let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
  return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }

// ---- load pins, then boot --------------------------------------------------
(function loadPins() {
  const s = document.createElement('script');
  s.src = 'pins.js';
  s.onload  = () => boot(Array.isArray(window.PINS) ? window.PINS : []);
  s.onerror = () => boot([]);
  document.head.appendChild(s);
})();

// ============================================================================
function boot(PINS) {
  // normalize: accept both ["url", ...] and [{img, link}, ...]
  let base = (PINS && PINS.length ? PINS : demoPins())
    .map(p => typeof p === 'string' ? { img: p, link: '' } : p)
    .filter(p => p && p.img);

  const sig  = signature(base.map(p => p.img));
  const rand = mulberry32(seedFrom(sig));
  const sources = base.map(v => [rand(), v]).sort((a,b)=>a[0]-b[0]).map(p => p[1]);

  const params = new URLSearchParams(location.search);
  const gallery = !!params.get('gallery');
  let savedTuner = {};
  try { const s = localStorage.getItem('pinwall_tuner');
    if (s) savedTuner = Object.fromEntries(new URLSearchParams(s)); } catch (e) {}
  const pick = (k, d) => {
    const u = params.get(k);
    if (u !== null && u !== '') { const n = parseFloat(u); if (!isNaN(n)) return n; }
    if (savedTuner[k] != null) { const n = parseFloat(savedTuner[k]); if (!isNaN(n)) return n; }
    return d;
  };
  let speed     = pick('speed',   SPEED);
  let fadeMs    = pick('fade',    FADE_MS);
  let risePx    = pick('rise',    RISE_PX);
  let staggerMs = pick('stagger', STAGGER_MS);
  let startDelay = gallery ? 0 : pick('delay', START_DELAY);

  function persistParams() {
    const qs = `speed=${speed}&fade=${fadeMs}&rise=${risePx}&stagger=${staggerMs}`;
    try { history.replaceState(null, '', '?' + qs); } catch (e) {}
    try { localStorage.setItem('pinwall_tuner', qs); } catch (e) {}
  }

  const root = document.documentElement;
  root.style.setProperty('--gap', GAP + 'px');
  function applyCssVars() {
    root.style.setProperty('--fade', fadeMs + 'ms');
    root.style.setProperty('--rise', risePx + 'px');
  }
  applyCssVars();
  if (gallery) document.body.classList.add('gallery');

  const viewport = document.getElementById('viewport');
  let columns = [], firstBuild = true;

  function build() {
    viewport.innerHTML = ''; columns = [];
    const colCount = Math.max(2, Math.floor(window.innerWidth / COLUMN_WIDTH));
    const buckets = Array.from({ length: colCount }, () => []);
    sources.forEach((item, i) => buckets[i % colCount].push(item));
    buckets.forEach((bucket, ci) => {
      const col = document.createElement('div'); col.className = 'col';
      const makeImg = (item) => { const img = document.createElement('img'); img.src = item.img;
        if (item.link) img.dataset.link = item.link;
        img.loading = 'eager'; img.addEventListener('load', scheduleRemeasure);
        img.addEventListener('error', scheduleRemeasure); return img; };
      bucket.forEach((item) => col.appendChild(makeImg(item)));
      bucket.forEach((item) => col.appendChild(makeImg(item)));
      viewport.appendChild(col);
      columns.push({ el: col, loopHeight: 0, phase: ci * 173 });
    });
    remeasure();
    if (firstBuild) { firstBuild = false; }
    else { viewport.querySelectorAll('img').forEach(img => img.classList.add('instant')); }
  }

  function fadeIn(img, delay) { img.style.transitionDelay = (delay || 0) + 'ms'; img.classList.add('show'); }
  function paintThenFade(img, delay) {
    const go = () => fadeIn(img, delay);
    if (img.decode) img.decode().then(go).catch(go); else go();
  }
  function revealEntrance() {
    const vh = window.innerHeight;
    const onScreen = img => { const r = img.getBoundingClientRect(); return r.bottom > 0 && r.top < vh; };
    viewport.querySelectorAll('img').forEach(img => {
      if (img.complete && img.naturalHeight > 0) {
        if (onScreen(img)) {
          const r = img.getBoundingClientRect();
          const t = Math.min(Math.max(r.top, 0), vh) / vh;
          paintThenFade(img, staggerMs * (1 - t));
        } else { img.classList.add('instant'); }
      } else {
        const done = () => { img.removeEventListener('load', done); img.removeEventListener('error', err);
          if (onScreen(img)) paintThenFade(img, 0); else img.classList.add('instant'); };
        const err = () => { img.removeEventListener('load', done); img.removeEventListener('error', err); img.classList.add('instant'); };
        img.addEventListener('load', done);
        img.addEventListener('error', err);
        if (img.complete) { if (img.naturalHeight > 0) done(); else err(); }
      }
    });
    setTimeout(() => viewport.querySelectorAll('img:not(.show):not(.instant)')
      .forEach(i => i.classList.add('instant')), 8000);
  }
  function replayEntrance() {
    const imgs = viewport.querySelectorAll('img');
    imgs.forEach(img => { img.style.transition = 'none'; img.classList.remove('show', 'instant'); img.style.transitionDelay = ''; });
    void viewport.offsetWidth;
    imgs.forEach(img => { img.style.transition = ''; });
    void viewport.offsetWidth;
    requestAnimationFrame(() => requestAnimationFrame(revealEntrance));
  }
  function remeasure() {
    columns.forEach((c) => { const h = c.el.scrollHeight / 2; if (h > 0) c.loopHeight = h; });
  }
  let remeasureTimer = null;
  function scheduleRemeasure() { clearTimeout(remeasureTimer); remeasureTimer = setTimeout(remeasure, 120); }

  // scroll: real clock in the screensaver (resumes across launches);
  // pausable virtual clock in gallery mode (so you can hover & click)
  let vt = 0, lastTs = null, paused = false;
  function tick(now) {
    if (gallery) {
      if (lastTs == null) lastTs = now;
      if (!paused) vt += (now - lastTs) / 1000;
      lastTs = now;
    }
    const t = gallery ? vt : (Date.now() / 1000);
    columns.forEach((c) => { if (!c.loopHeight) return;
      const off = ((t * speed + c.phase) % c.loopHeight + c.loopHeight) % c.loopHeight;
      c.el.style.transform = `translateY(${-off}px)`; });
    requestAnimationFrame(tick);
  }

  // gallery interactions: hover pauses, click opens the pin
  if (gallery) {
    viewport.addEventListener('mouseover', e => { if (e.target.closest('img')) paused = true; });
    viewport.addEventListener('mouseout',  e => { if (e.target.closest('img')) paused = false; });
    viewport.addEventListener('click', e => {
      const img = e.target.closest('img'); if (!img) return;
      const url = img.dataset.link || img.src;
      if (url) window.open(url, '_blank');
    });
  }

  if (!gallery && RELOAD_MINUTES > 0) {
    setTimeout(() => {
      const u = new URL(location.href);
      u.searchParams.set('t', Date.now());
      location.replace(u.toString());
    }, RELOAD_MINUTES * 60 * 1000);
  }

  let resizeTimer = null;
  window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(build, 200); });

  // ---- tuner ----
  const tuner = document.getElementById('tuner');
  const el = id => document.getElementById(id);
  const sliders = { speed: el('sSpeed'), fade: el('sFade'), rise: el('sRise'), stagger: el('sStagger') };
  const vals    = { speed: el('vSpeed'), fade: el('vFade'), rise: el('vRise'), stagger: el('vStagger') };
  function syncTuner() {
    sliders.speed.value = speed;       vals.speed.textContent   = speed;
    sliders.fade.value  = fadeMs;      vals.fade.textContent    = fadeMs;
    sliders.rise.value  = risePx;      vals.rise.textContent    = risePx;
    sliders.stagger.value = staggerMs; vals.stagger.textContent = staggerMs;
    el('urlOut').textContent = `?speed=${speed}&fade=${fadeMs}&rise=${risePx}&stagger=${staggerMs}`;
  }
  sliders.speed.addEventListener('input',   e => { speed = +e.target.value; syncTuner(); persistParams(); });
  sliders.fade.addEventListener('input',    e => { fadeMs = +e.target.value; applyCssVars(); syncTuner(); persistParams(); });
  sliders.rise.addEventListener('input',    e => { risePx = +e.target.value; applyCssVars(); syncTuner(); persistParams(); });
  sliders.stagger.addEventListener('input', e => { staggerMs = +e.target.value; syncTuner(); persistParams(); });
  el('bReplay').addEventListener('click', replayEntrance);
  el('bCopy').addEventListener('click', () => { navigator.clipboard.writeText(el('urlOut').textContent).catch(() => {}); });
  function toggleTuner() { const open = tuner.classList.toggle('open'); document.body.classList.toggle('tuning', open); if (open) syncTuner(); }
  window.addEventListener('keydown', e => { if (e.key === 't' || e.key === 'T') toggleTuner(); });
  if (params.get('tune')) toggleTuner();

  // ---- start ----
  let started = false;
  function start() {
    if (started) return;
    started = true;
    setTimeout(() => requestAnimationFrame(() => requestAnimationFrame(revealEntrance)), startDelay);
  }
  window.addEventListener('pageshow', start);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') start(); });

  if (params.get('debug')) {
    const hud = document.createElement('div');
    hud.style.cssText = 'position:fixed;top:8px;right:8px;z-index:99999;font:12px monospace;' +
      'color:#0f0;background:rgba(0,0,0,.7);padding:8px 10px;border-radius:6px;white-space:pre;pointer-events:none;';
    document.body.appendChild(hud);
    setInterval(() => {
      const imgs = viewport.querySelectorAll('img'); let loaded = 0, shown = 0;
      imgs.forEach(i => { if (i.complete && i.naturalHeight > 0) loaded++; if (i.classList.contains('show')) shown++; });
      hud.textContent = `vis: ${document.visibilityState}\nstarted: ${started}\n` +
        `loaded: ${loaded}/${imgs.length}\nshown: ${shown}\ngallery:${gallery}`;
    }, 250);
  }

  build();
  requestAnimationFrame(tick);
  start();
}
</script>
</body>
</html>
HTMLEOF

# ---------------------------------------------------------------------------
# 2. Write the feed harvester (writes pins.js, which pinwall.html reads)
# ---------------------------------------------------------------------------
cat > harvest_feed.py << 'PYEOF2'
#!/usr/bin/env python3
import os, re, sys, time, json
from playwright.sync_api import sync_playwright

PINS_FILE = "pins.js"        # writes here — pinwall.html reads it
USER_DATA = os.path.join(os.path.expanduser("~"), ".pinwall-session")
TARGET, SCROLLS = 100, 50
MIN_PINS = 15                # below this we assume a failed/logged-out scrape and DON'T overwrite

def upsize(u): return re.sub(r'/\d+x\d*/', '/736x/', u)
def is_pin(src):
    if not src or "i.pinimg.com" not in src: return False
    if "/avatars/" in src or "/user/" in src or "_RS" in src: return False
    # width before the 'x' in size tokens like /236x/, /75x75_RS/, /736x/
    m = re.search(r'/(\d+)x', src)
    if m and int(m.group(1)) < 200: return False
    return True
def abslink(href):
    if not href: return ""
    if href.startswith("/"): return "https://www.pinterest.com" + href
    return href
def logged_out(page):
    try:
        if page.get_by_text("Log in", exact=True).count() > 0: return True
        if page.get_by_text("Sign up", exact=True).count() > 0: return True
    except Exception: pass
    return False

def main():
    headless = "--headless" in sys.argv
    seen, pairs = set(), []
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(USER_DATA, headless=headless,
                viewport={"width": 1400, "height": 900})
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto("https://www.pinterest.com/", wait_until="domcontentloaded"); time.sleep(4)
        if headless:
            if logged_out(page):
                print("Not logged in (session expired). Keeping existing pins.js. Run once WITHOUT --headless to re-login.")
                ctx.close(); sys.exit(1)
        else:
            print("\n" + "="*60)
            print("A Pinterest window is open.")
            print("1. Make sure you are LOGGED IN (you should see YOUR feed).")
            print("2. Then come back here and press Enter.")
            print("="*60)
            input("Press Enter when your feed is showing... ")
            page.goto("https://www.pinterest.com/", wait_until="domcontentloaded"); time.sleep(3)
            if logged_out(page):
                print("\nStill looks logged out - log in and re-run."); ctx.close(); sys.exit(1)
        for _ in range(SCROLLS):
            items = page.eval_on_selector_all('img', '''els => els.map(e => {
                const ss = e.getAttribute("srcset");
                let img = e.src;
                if (ss) { const parts = ss.split(",").map(s => s.trim().split(" ")[0]); img = parts[parts.length-1]; }
                const a = e.closest('a[href*="/pin/"]');
                return { img: img, link: a ? a.getAttribute("href") : "" };
            })''')
            for it in items:
                img = it.get("img")
                if img and is_pin(img):
                    u = upsize(img)
                    if u not in seen:
                        seen.add(u); pairs.append((u, abslink(it.get("link"))))
            if len(pairs) >= TARGET: break
            page.mouse.wheel(0, 2200); time.sleep(1.2)
        ctx.close()
    pairs = pairs[:TARGET]
    print(f"Collected {len(pairs)} pins ({sum(1 for _,l in pairs if l)} with links)")

    # GUARDRAIL: never wipe a good pins.js with a tiny/failed scrape
    if len(pairs) < MIN_PINS:
        print(f"Only {len(pairs)} pins — looks like a failed or logged-out scrape.")
        print("Keeping the existing pins.js untouched.")
        sys.exit(1)

    block = "window.PINS = [\n" + "".join(
        f'  {{ "img": {json.dumps(i)}, "link": {json.dumps(l)} }},\n' for i, l in pairs) + "];\n"
    with open(PINS_FILE, "w", encoding="utf-8") as f: f.write(block)
    print(f"Wrote {len(pairs)} pins to {PINS_FILE}")

if __name__ == "__main__": main()
PYEOF2

# ---------------------------------------------------------------------------
# 3. Install browser automation (one-time)
# ---------------------------------------------------------------------------
echo "==> Installing browser automation (~200MB, one-time)..."
(pip3 install --quiet playwright || pip install --quiet playwright)
python3 -m playwright install chromium

# ---------------------------------------------------------------------------
# 4. Install the screensaver engine (WebViewScreenSaver) + skip Gatekeeper popup
# ---------------------------------------------------------------------------
echo "==> Installing screensaver engine..."
mkdir -p "$HOME/Library/Screen Savers"
TMP="$(mktemp -d)"
ZIP_URL="$(curl -fsSL https://api.github.com/repos/liquidx/webviewscreensaver/releases/latest | grep -o 'https://[^"]*\.zip' | head -n1)"
if [ -n "$ZIP_URL" ]; then
  curl -fsSL "$ZIP_URL" -o "$TMP/wvss.zip"
  unzip -oq "$TMP/wvss.zip" -d "$TMP"
  SAVER="$(find "$TMP" -maxdepth 3 -name '*.saver' | head -n1)"
  if [ -n "$SAVER" ]; then
    rm -rf "$HOME/Library/Screen Savers/WebViewScreenSaver.saver"
    cp -R "$SAVER" "$HOME/Library/Screen Savers/WebViewScreenSaver.saver"
    xattr -dr com.apple.quarantine "$HOME/Library/Screen Savers/WebViewScreenSaver.saver" 2>/dev/null || true
    echo "    installed."
  else
    echo "    couldn't unpack it — install manually from github.com/liquidx/webviewscreensaver/releases"
  fi
else
  echo "    download failed — install manually from github.com/liquidx/webviewscreensaver/releases"
fi
rm -rf "$TMP"

# ---------------------------------------------------------------------------
# 5. Grab your feed (writes pins.js)
# ---------------------------------------------------------------------------
echo "==> Opening Pinterest. Log in, then press Enter back here."
python3 harvest_feed.py

# ---------------------------------------------------------------------------
# 6. Final manual step
# ---------------------------------------------------------------------------
cat << DONE

==================  ALMOST DONE  ==================
Last step (System Settings does this part, not a script):

  1. System Settings > Wallpaper > scroll down > Screen Saver
  2. Pick "WebViewScreenSaver"
  3. Click Options > Add URL > paste exactly:

       file://$DIR/pinwall.html?speed=24&fade=600&delay=600

  4. Set Seconds to -1, click Close.

Tips:
  - Press T while pinwall.html is open in a browser for a live tuner.
  - Open pinwall.html?gallery=1 in a browser to click pins through to Pinterest.

(If the Options button seems dead, close & reopen System Settings.)
==================================================

DONE
