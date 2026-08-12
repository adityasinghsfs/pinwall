# dmgbuild layout for the PinWall installer window.
# Writes the window's .DS_Store directly (no Finder AppleScript / TCC prompts).
# Invoked by package.sh:  python3 -m dmgbuild -s scripts/dmg_settings.py \
#     -D app=<PinWall.app> -D icon=<AppIcon.icns> -D bg=<bg.tiff> "PinWall" out.dmg
import os.path

app  = defines.get("app")
icon = defines.get("icon")
bg   = defines.get("bg")

format   = "UDZO"
files    = [app]
symlinks = {"Applications": "/Applications"}

icon          = icon          # volume icon (shown when mounted)
background     = bg           # 600x480 (hidpi tiff)
window_rect    = ((240, 180), (600, 480))
default_view   = "icon-view"
show_icon_preview = False
icon_size     = 128
text_size     = 13

# positions are in background-image pixels (top-left origin): app left, /Applications right
icon_locations = {
    os.path.basename(app): (165, 250),
    "Applications":        (435, 250),
}
