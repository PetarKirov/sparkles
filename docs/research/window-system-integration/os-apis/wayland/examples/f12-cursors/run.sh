#!/bin/sh
# Tier-A driver for the F12 cursor demo (see ./app.d and ../../f12-cursors.md).
#
#   ./run.sh weston       headless weston: registry probe (is cursor-shape-v1
#                         offered?) + theme dump; headless weston has NO seat,
#                         so no pointer and no set_cursor — recorded as such
#   ./run.sh sway         headless sway + `swaymsg seat seat0 cursor set`
#                         walking the 3×3 zones (shape path by default)
#   ./run.sh sway-theme   same walk, WSI_FORCE_PATH=theme, output scale 2 —
#                         exercises libwayland-cursor + HiDPI size selection
#
# The weston mode needs the repo dev shell (weston, dub on PATH); the sway
# modes additionally need sway/swaymsg, e.g. `nix shell nixpkgs#sway -c ./run.sh sway`.
# Each mode is self-contained: private XDG_RUNTIME_DIR, compositor killed on exit.
set -eu
cd "$(dirname "$0")"
mode="${1:-weston}"
demo=./build/f12_cursors
[ -x "$demo" ] || dub build --compiler=ldc2 >&2

rt="$(mktemp -d)"
export XDG_RUNTIME_DIR="$rt"
unset WAYLAND_DISPLAY DISPLAY || true

cleanup()
{
    [ -n "${comp_pid:-}" ] && kill "$comp_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Headless sway with WLR_LIBINPUT_NO_DEVICES=1 has a seat with NO pointer
# capability, and wlroots hard-errors a premature wl_seat.get_pointer. wlrctl
# plugs a zwlr_virtual_pointer in, which makes sway add the capability — the
# demo then creates its wl_pointer conformantly. Without wlrctl the demo's
# blind request tour still produces the WAYLAND_DEBUG protocol evidence.
seed_pointer()
{
    if command -v wlrctl >/dev/null; then
        WAYLAND_DISPLAY="$wld" wlrctl pointer move 1 1
        sleep 0.5
    else
        echo "note: wlrctl not on PATH; seat keeps capabilities=0 (blind tour mode)" >&2
    fi
}

# Walk the pointer over the 3×3 zone grid of the (fullscreen-tiled, border-
# less) window: 8 border zones + repeated center entries to advance the
# default → text → pointer → bullseye → wait cycle. The wlrctl-created
# virtual pointer only lives for the duration of one wlrctl invocation (the
# capability flaps with it), so each warp is paired with a 1-px wlrctl move
# that delivers a fresh wl_pointer.enter at the warped position.
zone_walk() # zone_walk <output-width> <output-height>
{
    w=$1
    h=$2
    # "5 5" appears twice: a device plug occasionally races the warp and the
    # enter is dropped (observed ~1 in 16 steps); the retry always lands.
    for xy in "1 1" "3 1" "5 1" "1 3" "3 3" "5 3" "1 5" "3 5" "5 5" \
        "3 3" "1 1" "3 3" "5 1" "3 3" "1 5" "3 3" "5 5"; do
        x=$(echo "$xy" | cut -d' ' -f1)
        y=$(echo "$xy" | cut -d' ' -f2)
        swaymsg seat seat0 cursor set $((w * x / 6)) $((h * y / 6)) > /dev/null
        sleep 0.1 # let sway process the warp before the virtual device appears
        WAYLAND_DISPLAY="$wld" wlrctl pointer move 1 1 2>/dev/null || true
        sleep 0.4
    done
}

start_sway() # start_sway <extra-output-config>
{
    command -v sway >/dev/null || { echo "SKIP: sway not on PATH"; exit 0; }
    printf 'output HEADLESS-1 resolution 1280x720 %s\ndefault_border none\n' "$1" \
        > "$rt/sway.cfg"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        sway -c "$rt/sway.cfg" > "$rt/sway.log" 2>&1 &
    comp_pid=$!
    sleep 3
    wld="$(cd "$rt" && ls wayland-* 2>/dev/null | grep -v '\.lock$' | head -n 1)"
    [ -n "$wld" ] || { echo "SKIP: sway did not create a wayland socket"; exit 0; }
    SWAYSOCK="$(ls "$rt"/sway-ipc.*.sock | head -n 1)"
    export SWAYSOCK
}

case "$mode" in
weston)
    command -v weston >/dev/null || { echo "SKIP: weston not on PATH"; exit 0; }
    weston --backend=headless --socket=wsi-w5b --idle-time=0 \
        > "$rt/weston.log" 2>&1 &
    comp_pid=$!
    sleep 2
    WAYLAND_DISPLAY=wsi-w5b WSI_AUTO_EXIT=1 "$demo"
    ;;
sway)
    start_sway ""
    WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=12000 "$demo" &
    demo_pid=$!
    sleep 2
    seed_pointer
    zone_walk 1280 720
    wait "$demo_pid"
    ;;
sway-theme)
    start_sway "scale 2"
    WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=12000 WSI_FORCE_PATH=theme "$demo" &
    demo_pid=$!
    sleep 2
    seed_pointer
    zone_walk 640 360 # logical coordinates: the scale-2 output is 640×360
    wait "$demo_pid"
    ;;
*)
    echo "usage: $0 [weston|sway|sway-theme]" >&2
    exit 2
    ;;
esac
