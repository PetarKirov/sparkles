#!/bin/sh
# Tier-A driver for the F09 output demo (see ./app.d and ../../f09-outputs.md).
#
#   ./run.sh weston   headless weston: static single-output baseline
#                     (the headless backend cannot hotplug — recorded as such)
#   ./run.sh sway     headless sway + LIVE hotplug choreography against the
#                     running demo:
#                       1. swaymsg create_output            → output_added
#                       2. reposition + rescale HEADLESS-2  → update storm
#                       3. move the window onto HEADLESS-2  → leave/enter
#                       4. swaymsg output HEADLESS-2 disable → the *occupied*
#                          output vanishes: output_removed + configure storm
#
# The weston mode needs the repo dev shell (weston, dub on PATH); the sway mode
# additionally needs sway/swaymsg, e.g. `nix shell nixpkgs#sway -c ./run.sh sway`.
# Each mode is self-contained: private XDG_RUNTIME_DIR, compositor killed on exit.
set -eu
cd "$(dirname "$0")"
mode="${1:-weston}"
demo=./build/f09_outputs
[ -x "$demo" ] || dub build --compiler=ldc2 >&2

rt="$(mktemp -d)"
export XDG_RUNTIME_DIR="$rt"
unset WAYLAND_DISPLAY DISPLAY || true

cleanup()
{
    [ -n "${comp_pid:-}" ] && kill "$comp_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

case "$mode" in
weston)
    command -v weston >/dev/null || { echo "SKIP: weston not on PATH"; exit 0; }
    weston --backend=headless --socket=wsi-w5a --idle-time=0 \
        > "$rt/weston.log" 2>&1 &
    comp_pid=$!
    sleep 2
    WAYLAND_DISPLAY=wsi-w5a WSI_AUTO_EXIT=1 "$demo"
    ;;
sway)
    command -v sway >/dev/null || { echo "SKIP: sway not on PATH"; exit 0; }
    printf 'output HEADLESS-1 resolution 1280x720\ndefault_border none\n' > "$rt/sway.cfg"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        sway -c "$rt/sway.cfg" > "$rt/sway.log" 2>&1 &
    comp_pid=$!
    sleep 3
    wld="$(cd "$rt" && ls wayland-* 2>/dev/null | grep -v '\.lock$' | head -n 1)"
    [ -n "$wld" ] || { echo "SKIP: sway did not create a wayland socket"; exit 0; }
    SWAYSOCK="$(ls "$rt"/sway-ipc.*.sock | head -n 1)"
    export SWAYSOCK
    WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=10000 "$demo" &
    demo_pid=$!
    sleep 2
    swaymsg create_output > /dev/null                       # hot-ADD → output_added
    sleep 1.5
    swaymsg output HEADLESS-2 resolution 1024x768 position 1280 0 scale 2 \
        > /dev/null                                         # reconfigure storm
    sleep 1.5
    swaymsg '[app_id="wsi-f09-outputs"]' move container to output HEADLESS-2 \
        > /dev/null                                         # cross-output move
    sleep 1.5
    swaymsg output HEADLESS-2 disable > /dev/null           # the OCCUPIED output dies
    sleep 1.5
    wait "$demo_pid"
    ;;
*)
    echo "usage: $0 [weston|sway]" >&2
    exit 2
    ;;
esac
