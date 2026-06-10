#!/usr/bin/env bash
# F09 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, which enumerates a static Xvfb, runs its XMoveWindow occupancy
# storm, and exits 0). Run it from the repo dev shell (`nix develop`, for
# dub/xvfb-run); xrandr and Xephyr are pulled in via `nix shell`.
#
#     ./run.sh        # build, then run the RandR choreography under Xvfb
#
# Sequence (see ../../f09-outputs.md for the findings it produces):
#
# Phase 1 — Xvfb (RandR 1.6, but a STATIC output set: one output "screen",
#           one synthetic mode, max screen size = initial size):
#   demo starts            -> both enumerations + occupancy move storm
#   xrandr --dpi 144       -> RRScreenChangeNotify (mm-only change — the one
#                             screen-change event Xvfb can emit, per F08)
#   xrandr --output screen --set non-desktop 1
#                          -> does RRNotify_OutputProperty reach a client?
#   xrandr -s 640x480      -> -s against the only size in the list (no-op?)
#
# Phase 2 — Xephyr nested inside Xvfb (also RandR 1.6, but with a 15-entry
#           mode list on its "default" output, so `xrandr -s` performs a REAL
#           pixel-size switch):
#   demo starts on :77     -> same enumeration, nmode=15
#   xrandr -s 1024x768     -> real size switch: RRScreenChangeNotify with the
#                             new px size + RRNotify CrtcChange/OutputChange
#   xrandr -s 640x480      -> and back
#
# A real connector hot-unplug is not reachable on either server — Tier C.
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${WSI_F09_INNER:-}" ]]; then
    dub build --root="$dir"
    exec nix shell nixpkgs#xorg.xrandr nixpkgs#xorg.xorgserver --command \
        xvfb-run -a -s "-screen 0 1280x1024x24" env WSI_F09_INNER=1 "$0"
fi

demo="$dir/build/f09_outputs_x11"

# ---- Phase 1: Xvfb ----------------------------------------------------------
echo "=== phase 1: Xvfb (DISPLAY=$DISPLAY) ==="
WSI_AUTO_EXIT=1 WSI_DURATION_MS=${WSI_DURATION_MS:-9000} "$demo" &
pid=$!
sleep 4.5 # let the enumeration + the 3-step occupancy move storm finish

xrandr --dpi 144 # mm rewrite -> RRScreenChangeNotify (no px change)
sleep 1
xrandr --output screen --set non-desktop 1 \
    || echo "driver: --set non-desktop failed (logged as a finding)"
sleep 1
# -s against Xvfb's single-entry size list: index 0 is the only legal value.
xrandr -s 1280x1024 || echo "driver: xrandr -s failed (logged as a finding)"
sleep 1

wait "$pid"

# ---- Phase 2: Xephyr nested in Xvfb ----------------------------------------
echo "=== phase 2: Xephyr :77 (15-mode size list) ==="
Xephyr :77 -screen 800x600 2>/dev/null &
xephyr=$!
trap 'kill $xephyr 2>/dev/null || true' EXIT
sleep 1.5

DISPLAY=:77 WSI_AUTO_EXIT=1 WSI_DURATION_MS=7000 "$demo" &
pid=$!
sleep 4.5

DISPLAY=:77 xrandr -s 1024x768 || echo "driver: -s 1024x768 failed on Xephyr"
sleep 1
DISPLAY=:77 xrandr -s 640x480 || echo "driver: -s 640x480 failed on Xephyr"
sleep 1

wait "$pid"
