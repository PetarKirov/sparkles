#!/bin/sh
# Tier-A driver for the F15 popup demo (see ./app.d and ../../f15-popup.md).
#
#   ./run.sh weston   headless weston (socket wsi-w8a): no seat → no grab; the
#                     noinput scenario still exercises xdg_positioner solving
#                     (popup + nested popup + the v3 reposition probe).
#   ./run.sh sway     headless sway, three scenarios:
#                       menu   right-click menu + grab + hover + reposition +
#                              nested submenu + outside-click popup_done chain
#                       edge   menu at the output's bottom-right corner (the
#                              compositor's slide/flip decision) + Esc via a
#                              wtype virtual keyboard on the grab's wl_keyboard
#                       stale  xdg_popup.grab with serial=1, no input ever —
#                              the invalid-grab-serial outcome, measured
#
# weston/dub come from the repo dev shell; the sway mode needs sway/swaymsg
# and wtype, e.g. `nix shell nixpkgs#sway nixpkgs#wtype -c ./run.sh sway`.
# Each mode is self-contained: private XDG_RUNTIME_DIR, compositor killed on
# exit. Without a compositor every mode prints SKIP and exits 0.
set -eu
cd "$(dirname "$0")"
mode="${1:-weston}"
demo=./build/f15_popup
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
    weston --backend=headless --socket=wsi-w8a --idle-time=0 \
        > "$rt/weston.log" 2>&1 &
    comp_pid=$!
    sleep 2
    WAYLAND_DISPLAY=wsi-w8a WSI_SCENARIO=noinput WSI_AUTO_EXIT=1 WSI_RUN_MS=3000 "$demo"
    ;;
sway)
    command -v sway >/dev/null || { echo "SKIP: sway not on PATH"; exit 0; }
    {
        printf 'output HEADLESS-1 resolution 1280x720\n'
        printf 'default_border none\ndefault_floating_border none\n'
        printf 'for_window [app_id="wsi-f15-popup"] floating enable, move position 320 120\n'
        printf 'for_window [app_id="wsi-f15-edge"] floating enable, move position 632 232\n'
    } > "$rt/sway.cfg"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        sway -c "$rt/sway.cfg" > "$rt/sway.log" 2>&1 &
    comp_pid=$!
    sleep 3
    wld="$(cd "$rt" && ls wayland-* 2>/dev/null | grep -v '\.lock$' | head -n 1)"
    [ -n "$wld" ] || { echo "SKIP: sway did not create a wayland socket"; exit 0; }

    echo "--- scenario: menu (grab + hover + reposition + submenu + outside click) ---"
    env WAYLAND_DISPLAY="$wld" WSI_SCENARIO=menu WSI_AUTO_EXIT=1 WSI_RUN_MS=9000 \
        ${WSI_DEMO_DEBUG:+WAYLAND_DEBUG=1} "$demo" &
    demo_pid=$!
    sleep 2
    WAYLAND_DISPLAY="$wld" "$demo" inject menu 2>/dev/null
    wait "$demo_pid"

    echo "--- scenario: edge (compositor-constrained placement + Esc dismissal) ---"
    env WAYLAND_DISPLAY="$wld" WSI_APP_ID=wsi-f15-edge WSI_SCENARIO=edge \
        WSI_AUTO_EXIT=1 WSI_RUN_MS=9000 ${WSI_DEMO_DEBUG:+WAYLAND_DEBUG=1} "$demo" &
    demo_pid=$!
    sleep 2
    WAYLAND_DISPLAY="$wld" "$demo" inject edge 2>/dev/null &
    inj_pid=$!
    sleep 3.5 # popup is up and grabbed; the injector still holds its device
    if command -v wtype >/dev/null; then
        WAYLAND_DISPLAY="$wld" wtype -k Escape
    else
        echo "note: wtype not on PATH; Esc leg skipped" >&2
    fi
    wait "$inj_pid"
    wait "$demo_pid"

    echo "--- scenario: stale (grab with serial=1, no input event ever) ---"
    env WAYLAND_DISPLAY="$wld" WSI_SCENARIO=stale WSI_AUTO_EXIT=1 WSI_RUN_MS=4000 \
        ${WSI_DEMO_DEBUG:+WAYLAND_DEBUG=1} "$demo"
    grep -i "serial\|grab" "$rt/sway.log" | tail -n 3 || true
    ;;
*)
    echo "usage: $0 [weston|sway]" >&2
    exit 2
    ;;
esac
