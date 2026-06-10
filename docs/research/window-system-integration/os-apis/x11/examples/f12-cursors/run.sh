#!/usr/bin/env bash
# F12 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, whose built-in XWarpPointer storm sweeps the 3x3 zone grid and
# exits 0). Run it from the repo dev shell (`nix develop`, for dub/xvfb-run);
# xdotool comes via `nix shell`, the Adwaita cursor theme via `nix build`.
#
#     ./run.sh        # build, then run the cursor-theme choreography under Xvfb
#
# Passes (see ../../f12-cursors.md for the findings they produce):
#   A  bare Xvfb, XCURSOR_* scrubbed  -> no theme resolves: every themed
#      lookup returns 0, default size = display-height/48, font fallback runs
#   B  XCURSOR_THEME=Adwaita + XCURSOR_PATH (no SIZE) -> which size does
#      libXcursor pick on a 640x480 screen, and from which theme files?
#   C  ... + XCURSOR_SIZE=16          -> is the env size honored?
#   D  ... + XCURSOR_SIZE=48          -> full storm at 48: themed zone
#      cursors, custom bullseye, 60-frame server-animated watch
#   E  xdotool-driven (WSI_NO_WARP=1) -> external pointer driver crosses the
#      zones; same cursor_set stream without XWarpPointer
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${WSI_F12_INNER:-}" ]]; then
    dub build --root="$dir"
    adw="$(nix build --no-link --print-out-paths nixpkgs#adwaita-icon-theme)"
    exec nix shell nixpkgs#xdotool --command \
        xvfb-run -a env WSI_F12_INNER=1 WSI_ADWAITA="$adw" "$0"
fi

demo="$dir/build/f12_cursors_x11"
icons="$WSI_ADWAITA/share/icons"

echo "=== pass A: bare (no theme reachable) ==="
env -u XCURSOR_THEME -u XCURSOR_PATH -u XCURSOR_SIZE \
    WSI_AUTO_EXIT=1 WSI_DURATION_MS=6500 "$demo"

echo "=== pass B: Adwaita, size unset ==="
env -u XCURSOR_SIZE XCURSOR_THEME=Adwaita XCURSOR_PATH="$icons" \
    WSI_AUTO_EXIT=1 WSI_DURATION_MS=1500 WSI_NO_WARP=1 "$demo"

echo "=== pass C: Adwaita, XCURSOR_SIZE=16 ==="
env XCURSOR_THEME=Adwaita XCURSOR_PATH="$icons" XCURSOR_SIZE=16 \
    WSI_AUTO_EXIT=1 WSI_DURATION_MS=1500 WSI_NO_WARP=1 "$demo"

echo "=== pass D: Adwaita, XCURSOR_SIZE=48, full storm ==="
env XCURSOR_THEME=Adwaita XCURSOR_PATH="$icons" XCURSOR_SIZE=48 \
    WSI_AUTO_EXIT=1 WSI_DURATION_MS=6500 "$demo"

echo "=== pass E: Adwaita, xdotool-driven ==="
env XCURSOR_THEME=Adwaita XCURSOR_PATH="$icons" XCURSOR_SIZE=48 \
    WSI_AUTO_EXIT=1 WSI_DURATION_MS=8000 WSI_NO_WARP=1 "$demo" &
pid=$!
sleep 1.5
# The window maps at +20+20, 480x480, 1px border: zone z's centre in root
# coordinates is (21 + (z%3)*160 + 80, 21 + (z/3)*160 + 80). Revisit the
# centre (zone 4) between edge zones so its 5-cursor cycle advances.
for z in 0 4 1 4 2 4 3 4 5 4 6 7 8; do
    x=$((21 + (z % 3) * 160 + 80))
    y=$((21 + (z / 3) * 160 + 80))
    xdotool mousemove "$x" "$y"
    sleep 0.35
done
wait "$pid"
