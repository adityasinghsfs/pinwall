#!/bin/bash
#
#  PinWall — one-shot installer
#  A Pinterest-feed Mac screensaver: tiled, black, slow-scrolling, clock-anchored
#  (never restarts from the top). Built on top of WebViewScreenSaver (open source).
#
#  Run:  bash setup.sh
#
#  Heads up: this logs into Pinterest in an automated browser to grab your
#  feed. It's a personal hack and technically against Pinterest's ToS — fine
#  for your own machine, just know that going in.
#

DIR="$HOME/pinwall"
mkdir -p "$DIR"
cd "$DIR" || exit 1

echo ""
echo "==> Setting up PinWall in $DIR"

# ---------------------------------------------------------------------------
# 1. Write the screensaver page
# ---------------------------------------------------------------------------
cat > pinwall.html << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
<title>PinWall</title>
<style>
  html, body { margin: 0; height: 100%; background: #000; overflow: hidden; cursor: none; }
  #viewport { position: fixed; inset: 0; display: flex; gap: var(--gap);
    padding: var(--gap); box-sizing: border-box; background: #000; }
  .col { flex: 1; position: relative; will-change: transform; }
  .col img { width: 100%; display: block; margin-bottom: var(--gap);
    border-radius: 12px; background: #0b0b0b; -webkit-user-select: none; user-select: none; }
</style>
</head>
<body>
<div id="viewport"></div>
<script>
const SPEED          = 24;   // scroll px/sec (lower = slower). URL override: ?speed=18
const COLUMN_WIDTH   = 320;  // target tile width in px
const GAP            = 14;   // spacing between tiles
const RELOAD_MINUTES = 60;   // reload to pull fresh pins. MATCH your harvest schedule. 0 = never.

const PINS = [
];

function demoPins() {
  const heights = [360, 480, 300, 540, 420, 600, 380, 460, 320, 500];
  const out = [];
  for (let i = 1; i <= 48; i++) out.push(`https://picsum.photos/seed/pin${i}/600/${heights[i % heights.length]}`);
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

const base = PINS.length ? PINS : demoPins();
const sig  = signature(base);
const rand = mulberry32(seedFrom(sig));
const sources = base.map(v => [rand(), v]).sort((a,b)=>a[0]-b[0]).map(p => p[1]);

const root = document.documentElement;
root.style.setProperty('--gap', GAP + 'px');
const params = new URLSearchParams(location.search);
const speed  = parseFloat(params.get('speed')) || SPEED;

const viewport = document.getElementById('viewport');
let columns = [];

function build() {
  viewport.innerHTML = ''; columns = [];
  const colCount = Math.max(2, Math.floor(window.innerWidth / COLUMN_WIDTH));
  const buckets = Array.from({ length: colCount }, () => []);
  sources.forEach((src, i) => buckets[i % colCount].push(src));
  buckets.forEach((bucket, ci) => {
    const col = document.createElement('div'); col.className = 'col';
    const makeImg = (src) => { const img = document.createElement('img'); img.src = src;
      img.loading = 'eager'; img.addEventListener('load', scheduleRemeasure);
      img.addEventListener('error', scheduleRemeasure); return img; };
    bucket.forEach((src) => col.appendChild(makeImg(src)));
    bucket.forEach((src) => col.appendChild(makeImg(src)));
    viewport.appendChild(col);
    columns.push({ el: col, loopHeight: 0, phase: ci * 173 });
  });
  remeasure();
}
function remeasure() {
  columns.forEach((c) => { const h = c.el.scrollHeight / 2; if (h > 0) c.loopHeight = h; });
}
let remeasureTimer = null;
function scheduleRemeasure() { clearTimeout(remeasureTimer); remeasureTimer = setTimeout(remeasure, 120); }
function tick() {
  const t = Date.now() / 1000;
  columns.forEach((c) => { if (!c.loopHeight) return;
    const off = ((t * speed + c.phase) % c.loopHeight + c.loopHeight) % c.loopHeight;
    c.el.style.transform = `translateY(${-off}px)`; });
  requestAnimationFrame(tick);
}
if (RELOAD_MINUTES > 0) {
  setTimeout(() => {
    const u = new URL(location.href);
    u.searchParams.set('t', Date.now());
    location.replace(u.toString());
  }, RELOAD_MINUTES * 60 * 1000);
}
let resizeTimer = null;
window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(build, 200); });
build(); requestAnimationFrame(tick);
</script>
</body>
</html>
HTML

# ---------------------------------------------------------------------------
# 2. Write the feed harvester
# ---------------------------------------------------------------------------
cat > harvest_feed.py << 'PY'
#!/usr/bin/env python3
import os, re, sys, time
from playwright.sync_api import sync_playwright

HTML_FILE = "pinwall.html"
# login lives outside the project folder so it never lands in a git repo
USER_DATA = os.path.join(os.path.expanduser("~"), ".pinwall-session")
TARGET, SCROLLS = 100, 50

def upsize(u): return re.sub(r'/\d+x\d*/', '/736x/', u)
def is_pin(src):
    if "i.pinimg.com" not in src: return False
    if "/avatars/" in src or "/user/" in src: return False
    m = re.search(r'/(\d+)x\d*/', src)
    if m and int(m.group(1)) < 200: return False
    return True
def logged_out(page):
    try:
        if page.get_by_text("Log in", exact=True).count() > 0: return True
        if page.get_by_text("Sign up", exact=True).count() > 0: return True
    except Exception: pass
    return False

def main():
    headless = "--headless" in sys.argv
    seen, collected = set(), []
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(USER_DATA, headless=headless,
                viewport={"width": 1400, "height": 900})
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto("https://www.pinterest.com/", wait_until="domcontentloaded"); time.sleep(4)
        if headless:
            if logged_out(page):
                print("Not logged in. Run once WITHOUT --headless first."); ctx.close(); sys.exit(1)
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
            srcs = page.eval_on_selector_all('img', '''els => els.map(e => {
                const ss = e.getAttribute("srcset");
                if (ss) { const parts = ss.split(",").map(s => s.trim().split(" ")[0]); return parts[parts.length-1]; }
                return e.src; })''')
            for s in srcs:
                if s and is_pin(s):
                    u = upsize(s)
                    if u not in seen: seen.add(u); collected.append(u)
            if len(collected) >= TARGET: break
            page.mouse.wheel(0, 2200); time.sleep(1.2)
        ctx.close()
    collected = collected[:TARGET]
    print(f"Collected {len(collected)} pins")
    if not collected: print("Nothing collected - are you logged in?"); sys.exit(1)
    block = "const PINS = [\n" + "".join(f'  "{u}",\n' for u in collected) + "];"
    with open(HTML_FILE, encoding="utf-8") as f: html = f.read()
    html = re.sub(r"const PINS = \[.*?\];", block, html, count=1, flags=re.DOTALL)
    with open(HTML_FILE, "w", encoding="utf-8") as f: f.write(html)
    print(f"Updated {HTML_FILE}")

if __name__ == "__main__": main()
PY

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
# 5. Grab your feed
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

       file://$DIR/pinwall.html?speed=18

  4. Set Seconds to -1, click Close.

(If the Options button seems dead, close & reopen System Settings.)
==================================================

DONE
