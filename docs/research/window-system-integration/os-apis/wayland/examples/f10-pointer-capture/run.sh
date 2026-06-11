#!/bin/sh
# Tier-A driver for the F10 pointer-capture demo (see ./app.d and
# ../../f10-pointer-capture.md).
#
#   ./run.sh weston   headless weston: registry probe only — no seat, so no
#                     pointer and nothing to lock; recorded as such
#   ./run.sh sway     headless sway; input is injected by the demo binary's
#                     own `inject` mode (zwlr_virtual_pointer_v1, ./inject.d);
#                     a second, PASSIVE demo instance (WSI_PASSIVE=1) exists
#                     purely as a focus-steal target, because sway only
#                     deactivates a constraint on a window-focus change —
#                     never on pointer-focus loss or device unplug (measured)
#
# The main window floats at (320,120) sized 640x480 (sway config below) so
# the pointer can genuinely be OUTSIDE the surface — the lock-while-outside /
# locked-on-entry contract is unobservable with a fullscreen-tiled window;
# the passive window tiles fullscreen behind it. Global geometry derived from
# that: confine region (center half, surface 160,120 320x240) is global
# (480,240)-(800,480); the cursor-position hint (surface 400,300) is global
# (720,420).
#
# The weston mode needs the repo dev shell (weston, dub on PATH); the sway
# mode additionally needs sway/swaymsg, e.g. `nix shell nixpkgs#sway -c ./run.sh sway`.
# Each mode is self-contained: private XDG_RUNTIME_DIR, compositor killed on exit.
set -eu
cd "$(dirname "$0")"
mode="${1:-sway}"
demo=./build/f10_pointer_capture
[ -x "$demo" ] || dub build --compiler=ldc2 >&2

rt="$(mktemp -d)"
export XDG_RUNTIME_DIR="$rt"
unset WAYLAND_DISPLAY DISPLAY || true

cleanup()
{
    [ -n "${comp_pid:-}" ] && kill "$comp_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

inject() # inject <hold_ms> <steps> <dx> <dy> <interval_ms>  (one plug/unplug cycle)
{
    WAYLAND_DISPLAY="$wld" "$demo" inject "$@" 2>/dev/null
    sleep 0.5
}

warp() # warp <x> <y>  (global coordinates; works with no device plugged)
{
    swaymsg seat seat0 cursor set "$1" "$2" > /dev/null
}

case "$mode" in
weston)
    command -v weston >/dev/null || { echo "SKIP: weston not on PATH"; exit 0; }
    weston --backend=headless --socket=wsi-w6a --idle-time=0 \
        > "$rt/weston.log" 2>&1 &
    comp_pid=$!
    sleep 2
    WAYLAND_DISPLAY=wsi-w6a WSI_AUTO_EXIT=1 "$demo"
    ;;
sway)
    command -v sway >/dev/null || { echo "SKIP: sway not on PATH"; exit 0; }
    {
        printf 'output HEADLESS-1 resolution 1280x720\n'
        printf 'default_border none\ndefault_floating_border none\n'
        printf 'for_window [app_id="wsi-f10-pointer-capture"] floating enable, move position 320 120\n'
    } > "$rt/sway.cfg"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        sway -c "$rt/sway.cfg" > "$rt/sway.log" 2>&1 &
    comp_pid=$!
    sleep 3
    wld="$(cd "$rt" && ls wayland-* 2>/dev/null | grep -v '\.lock$' | head -n 1)"
    [ -n "$wld" ] || { echo "SKIP: sway did not create a wayland socket"; exit 0; }
    SWAYSOCK="$(ls "$rt"/sway-ipc.*.sock | head -n 1)"
    export SWAYSOCK

    WAYLAND_DISPLAY="$wld" WSI_PASSIVE=1 WSI_AUTO_EXIT=1 WSI_RUN_MS=30000 "$demo" \
        > "$rt/passive.log" 2>&1 &
    passive_pid=$!
    sleep 1 # passive maps first → tiles fullscreen behind the floating main
    env WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=24000 ${WSI_DEMO_DEBUG:+WAYLAND_DEBUG=1} "$demo" &
    demo_pid=$!
    sleep 2

    # sway deactivates a constraint only when the WINDOW focus moves away —
    # this is the compositor-initiated `unlocked` each lifetime phase needs.
    steal_focus()
    {
        swaymsg '[app_id=wsi-f10-passive] focus' > /dev/null
        sleep 0.4
    }

    warp 640 360             # inside the main window
    inject 200 3 6 4 80      # pre: enter + abs AND relative motion (unlocked)
    warp 100 100             # OUTSIDE the main window for every lock request
    inject 200 8 60 45 70    # lock-oneshot: locked only once the path crosses the edge
    steal_focus              # → unlocked → oneshot object is defunct
    warp 100 100
    inject 200 8 60 45 70    # relock-oneshot: brand-new object, same lifecycle
    steal_focus              # → unlocked #2
    warp 100 100
    inject 200 8 60 45 70    # lock-persistent: activation #1
    steal_focus              # → unlocked, object KEPT (persistent)
    warp 100 100
    inject 600 10 60 45 70   # activation #2 (same object!) → hint+client-unlock
    # (cont.) → confine; the post-unlock motions reveal the warp
    inject 300 6 80 0 60     # push right → motion clamps at surface x≈480
    inject 300 6 0 80 60     # push down  → motion clamps at surface y≈480
    steal_focus              # → unconfined (persistent confine deactivated)
    warp 200 200             # over the passive window — no constraint active
    inject 400 12 40 30 60   # focus-follows back into the main window: does the
    # (cont.) persistent confinement reactivate? (finding)
    wait "$demo_pid"
    kill "$passive_pid" 2>/dev/null || wait "$passive_pid" 2>/dev/null || true
    ;;
*)
    echo "usage: $0 [weston|sway]" >&2
    exit 2
    ;;
esac
