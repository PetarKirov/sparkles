#!/bin/sh
# Tier-A driver for the F08 DPI demo (see ./app.d and ../../f08-dpi-scaling.md).
#
#   ./run.sh weston         headless weston, scale 1   (integer path, no change)
#   ./run.sh weston-scale2  headless weston, [output] scale=2 in weston.ini
#   ./run.sh sway           headless sway + LIVE `swaymsg output … scale` storm
#                           1 → 1.5 → 2 → 1 against the running demo
#
# The weston modes need the repo dev shell (weston, dub on PATH); the sway mode
# additionally needs sway/swaymsg, e.g. `nix shell nixpkgs#sway -c ./run.sh sway`.
# Each mode is self-contained: private XDG_RUNTIME_DIR, compositor killed on exit.
set -eu
cd "$(dirname "$0")"
mode="${1:-weston}"
demo=./build/f08_dpi_scaling
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
weston | weston-scale2)
    command -v weston >/dev/null || { echo "SKIP: weston not on PATH"; exit 0; }
    cfg=""
    if [ "$mode" = weston-scale2 ]; then
        printf '[output]\nname=headless\nscale=2\n' > "$rt/weston.ini"
        cfg="-c$rt/weston.ini"
    fi
    weston --backend=headless --socket=wsi-f08 --idle-time=0 $cfg \
        > "$rt/weston.log" 2>&1 &
    comp_pid=$!
    sleep 2
    WAYLAND_DISPLAY=wsi-f08 WSI_AUTO_EXIT=1 "$demo"
    ;;
sway)
    command -v sway >/dev/null || { echo "SKIP: sway not on PATH"; exit 0; }
    printf 'output HEADLESS-1 resolution 1280x720\n' > "$rt/sway.cfg"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        sway -c "$rt/sway.cfg" > "$rt/sway.log" 2>&1 &
    comp_pid=$!
    sleep 3
    # The wayland socket sway picked (usually wayland-1 in a fresh runtime dir).
    wld="$(cd "$rt" && ls wayland-* 2>/dev/null | grep -v '\.lock$' | head -n 1)"
    [ -n "$wld" ] || { echo "SKIP: sway did not create a wayland socket"; exit 0; }
    SWAYSOCK="$(ls "$rt"/sway-ipc.*.sock | head -n 1)"
    export SWAYSOCK
    WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=9000 "$demo" &
    demo_pid=$!
    sleep 2.5
    swaymsg output HEADLESS-1 scale 1.5 > /dev/null
    sleep 2
    swaymsg output HEADLESS-1 scale 2 > /dev/null
    sleep 2
    swaymsg output HEADLESS-1 scale 1 > /dev/null
    wait "$demo_pid"
    ;;
*)
    echo "usage: $0 [weston|weston-scale2|sway]" >&2
    exit 2
    ;;
esac
