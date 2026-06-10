#!/usr/bin/env bash
# F10 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, whose built-in XWarpPointer probes script all five phases and
# exit 0). This driver adds the half warps cannot prove: real *device* motion
# (xdotool -> XTest) that exercises raw events, mouselook deltas, grab
# confinement, and pointer barriers. Run it from the repo dev shell
# (`nix develop`, for dub/xvfb-run); xdotool comes via `nix shell`.
#
#     ./run.sh        # build, then run both passes under Xvfb
#
# Passes (see ../../f10-pointer-capture.md for the findings they produce):
#   A  built-in:  WSI_AUTO_EXIT=1 self-warp probes — warps make NO XI_RawMotion,
#      pierce pointer barriers, and (measured, Xvfb) escape confine_to too
#   B  driven:    WSI_DRIVEN=1 + xdotool sweeps — absolute moves (mousemove)
#      and relative steps (mousemove_relative) per phase: raw-vs-accel valuator
#      pairs, mouselook deltas, and the grab-clamps vs barrier-clamps contrast
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${WSI_F10_INNER:-}" ]]; then
    dub build --root="$dir"
    exec nix shell nixpkgs#xdotool --command xvfb-run -a env WSI_F10_INNER=1 "$0"
fi

demo="$dir/build/f10_pointer_capture_x11"

echo "=== pass A: built-in self-warp probes ==="
WSI_AUTO_EXIT=1 "$demo"

echo "=== pass B: xdotool-driven (XTest device motion) ==="
# Driven phases are 2 s each, anchored at the first Expose: unlocked 0-2 s,
# locked 2-4 s, confine_grab 4-6 s, confine_barrier 6-8 s, barrier_plus_grab
# 8-10 s. The window maps at +20+20 with a 1px border, so window-local (x,y)
# = root (x+21, y+21); the confine rect is root 141,101..381,261.
WSI_AUTO_EXIT=1 WSI_DRIVEN=1 "$demo" &
pid=$!
sleep 0.8
# unlocked: absolute sweep (pointer abs + raw_motion), then relative steps
for p in "61 61" "161 121" "261 181" "361 241" "461 301"; do
    xdotool mousemove $p
    sleep 0.12
done
xdotool mousemove 261 181
for _ in 1 2 3; do
    xdotool mousemove_relative -- 17 9
    sleep 0.12
done
sleep 0.55
# locked (mouselook): relative steps only; the demo re-centers after each
for _ in 1 2 3 4 5 6; do
    xdotool mousemove_relative -- 23 -11
    sleep 0.18
done
sleep 0.7
# confine_grab: absolute jump outside the rect, then pushes against its edges
xdotool mousemove 29 29
sleep 0.2
for _ in 1 2 3 4; do
    xdotool mousemove_relative -- -90 -60
    sleep 0.15
done
xdotool mousemove 492 332
sleep 0.2
sleep 1.0
# confine_barrier: demo warped the pointer to the rect center on phase entry;
# push left past the edge, back right, then down (expect barrier_hit + clamps)
for _ in 1 2 3 4; do
    xdotool mousemove_relative -- -80 0
    sleep 0.12
done
for _ in 1 2 3 4; do
    xdotool mousemove_relative -- 80 0
    sleep 0.12
done
for _ in 1 2 3 4; do
    xdotool mousemove_relative -- 0 60
    sleep 0.12
done
sleep 0.45
# barrier_plus_grab: same pushes while our own grab (confine_to=None) is held
for _ in 1 2 3 4; do
    xdotool mousemove_relative -- -80 -40
    sleep 0.12
done
xdotool mousemove 29 29
sleep 0.2
wait "$pid"
