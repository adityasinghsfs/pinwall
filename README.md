# PinWall

Your Pinterest feed as a Mac screensaver. Tiled like Pinterest, black background,
slowly scrolling forever — and it picks up where it left off.

![demo](demo.gif)

## Install

One command:

```bash
curl -fsSL https://raw.githubusercontent.com/adityasinghsfs/pinwall/main/setup.sh | bash
```

Then:

1. A Pinterest window opens — **log in**, come back to Terminal, press Enter.
2. **System Settings → Wallpaper → Screen Saver → WebViewScreenSaver**
3. **Options → Add URL →** paste the `file://...` line the script printed → set
   **Seconds to `-1`** → Close.

Done. Flick your mouse into a hot corner (System Settings → Screen Saver → Hot
Corners) to trigger it, or just wait.

## Tweak it

- **Speed:** the `?speed=18` at the end of the URL. Lower = slower. Change it
  anytime, no files to edit.
- **Tile size:** open `~/pinwall/pinwall.html`, change `COLUMN_WIDTH` near the top.

## Refresh your feed

Pins are grabbed once and frozen into the file. To pull new ones:

```bash
cd ~/pinwall && python3 harvest_feed.py
```

Want it automatic? Run `python3 harvest_feed.py --headless` on a schedule via
`launchd` (after logging in once).

## How it works

- The visual is a single `pinwall.html` — a masonry wall with a seamless
  per-column scroll loop. It shuffles once per feed and remembers your scroll
  position between launches.
- The feed isn't available through Pinterest's RSS or public API, so
  `harvest_feed.py` drives a logged-in browser (Playwright), scrolls your home
  feed, and bakes the image URLs into the page.
- It runs inside [WebViewScreenSaver](https://github.com/liquidx/webviewscreensaver),
  which points a real screensaver at a local web page.

## Honest notes

- Scraping your feed is against Pinterest's Terms of Service. This is a personal
  hack for your own machine — use it at your own risk.
- Your Pinterest login lives in a local `.pw-pinterest/` folder on your machine.
  It never leaves your computer. **Don't commit it anywhere.**
- The screensaver engine is [WebViewScreenSaver](https://github.com/liquidx/webviewscreensaver)
  by liquidx — full credit there. This project is just the wall + the harvester.
