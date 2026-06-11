#!/bin/sh
# Tier-A driver for the F11 scroll demo (see ./app.d and ../../f11-scroll.md).
#
#   ./run.sh weston   headless weston: registry probe only — no seat, so no
#                     pointer and no axis events; recorded as such
#   ./run.sh sway     headless sway + `wlrctl pointer scroll <dy> <dx>`:
#                     measures exactly what axis anatomy (value, v120, source,
#                     stop, frame grouping) a zwlr_virtual_pointer_v1 client
#                     produces — the injection-fidelity finding
#
# The weston mode needs the repo dev shell (weston, dub on PATH); the sway
# mode additionally needs sway/swaymsg/wlrctl, e.g.
# `nix shell nixpkgs#sway nixpkgs#wlrctl -c ./run.sh sway`.
# Each mode is self-contained: private XDG_RUNTIME_DIR, compositor killed on exit.
set -eu
cd "$(dirname "$0")"
mode="${1:-sway}"
demo=./build/f11_scroll
[ -x "$demo" ] || dub build --compiler=ldc2 >&2

rt="$(mktemp -d)"
export XDG_RUNTIME_DIR="$rt"
unset WAYLAND_DISPLAY DISPLAY || true

cleanup()
{
    [ -n "${comp_pid:-}" ] && kill "$comp_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

scroll() # scroll <dy> <dx>  (one wlrctl plug/unplug cycle = one "gesture")
{
    WAYLAND_DISPLAY="$wld" wlrctl pointer scroll "$1" "$2" 2>/dev/null || true
    sleep 0.7
}

case "$mode" in
weston)
    command -v weston >/dev/null || { echo "SKIP: weston not on PATH"; exit 0; }
    weston --backend=headless --socket=wsi-w6b --idle-time=0 \
        > "$rt/weston.log" 2>&1 &
    comp_pid=$!
    sleep 2
    WAYLAND_DISPLAY=wsi-w6b WSI_AUTO_EXIT=1 "$demo"
    ;;
sway)
    command -v sway >/dev/null || { echo "SKIP: sway not on PATH"; exit 0; }
    command -v wlrctl >/dev/null || { echo "SKIP: wlrctl not on PATH"; exit 0; }
    printf 'output HEADLESS-1 resolution 1280x720\ndefault_border none\n' > "$rt/sway.cfg"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        sway -c "$rt/sway.cfg" > "$rt/sway.log" 2>&1 &
    comp_pid=$!
    sleep 3
    wld="$(cd "$rt" && ls wayland-* 2>/dev/null | grep -v '\.lock$' | head -n 1)"
    [ -n "$wld" ] || { echo "SKIP: sway did not create a wayland socket"; exit 0; }
    SWAYSOCK="$(ls "$rt"/sway-ipc.*.sock | head -n 1)"
    export SWAYSOCK

    env WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=17000 ${WSI_DEMO_DEBUG:+WAYLAND_DEBUG=1} "$demo" &
    demo_pid=$!
    sleep 2

    swaymsg seat seat0 cursor set 640 360 > /dev/null # over the window
    # Hold the pointer capability up for the whole choreography (steps=0 =
    # plug and sleep): without it each wlrctl burst is delivered before the
    # demo's get_pointer round-trip completes and every axis event is lost
    # (measured — see ../../f11-scroll.md).
    WAYLAND_DISPLAY="$wld" "$demo" inject 13000 0 0 0 0 2>/dev/null &
    hold_pid=$!
    sleep 1 # enter delivered on the held device's plug
    scroll 1 0     # single wheel detent down
    scroll 5 0     # burst: five detents in one frame group?
    scroll -3 0    # three detents up (sign convention)
    scroll 0 2     # horizontal axis
    scroll 0.5 0   # fractional detent — does wlrctl/sway quantize or carry?
    scroll 2 1     # both axes in one injection: one frame or two?
    # wlrctl never sends discrete steps, so the wheel/v120 path needs the
    # demo's own injector: notched-wheel clicks via axis_discrete (wlroots
    # converts to axis_value120 = discrete x 120 for the demo's v9 bind).
    WAYLAND_DISPLAY="$wld" "$demo" inject 200 3 1 0 250 wheel 2>/dev/null # 3 single clicks
    sleep 0.5
    WAYLAND_DISPLAY="$wld" "$demo" inject 200 1 -2 0 100 wheel 2>/dev/null # one -2-detent frame
    sleep 0.5
    wait "$hold_pid" || true
    wait "$demo_pid"
    ;;
*)
    echo "usage: $0 [weston|sway]" >&2
    exit 2
    ;;
esac
