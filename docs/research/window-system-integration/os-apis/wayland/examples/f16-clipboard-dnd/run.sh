#!/bin/sh
# Tier-A driver for the F16 clipboard + DnD demo (see ./app.d and
# ../../f16-clipboard-dnd.md).
#
#   ./run.sh weston   headless weston (socket wsi-w8b): wl_data_device_manager
#                     IS advertised but there is no seat — the clipboard is
#                     seat-scoped by construction; registry probe only.
#   ./run.sh sway     headless sway + wl-clipboard as the REAL second client:
#                       1. stale probe: set_selection(serial=0) at startup →
#                          `wl-paste` proves nothing was installed
#                       2. injected right-click → valid serial → copy é漢🎈;
#                          `wl-paste -l` lists the offer, `wl-paste` reads it
#                          (the demo serves the send fd)
#                       3. `wl-copy` steals the selection → cancelled
#                          (ownership loss); a wtype keyboard then delivers
#                          keyboard focus → the demo receives wl-copy's offer
#                          and pastes it back through its own pipe
#                       4. injected press-hold-sweep-release drags from
#                          window A into window B (same client both sides):
#                          the full enter/accept/actions/drop/finish handshake
#
# weston/dub come from the repo dev shell; the sway mode needs sway/swaymsg,
# wl-clipboard and wtype, e.g.
# `nix shell nixpkgs#sway nixpkgs#wl-clipboard nixpkgs#wtype -c ./run.sh sway`.
# Each mode is self-contained: private XDG_RUNTIME_DIR, compositor killed on
# exit. Without a compositor every mode prints SKIP and exits 0.
set -eu
cd "$(dirname "$0")"
mode="${1:-weston}"
demo=./build/f16_clipboard_dnd
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
    weston --backend=headless --socket=wsi-w8b --idle-time=0 \
        > "$rt/weston.log" 2>&1 &
    comp_pid=$!
    sleep 2
    WAYLAND_DISPLAY=wsi-w8b WSI_AUTO_EXIT=1 "$demo"
    ;;
sway)
    command -v sway >/dev/null || { echo "SKIP: sway not on PATH"; exit 0; }
    command -v wl-paste >/dev/null || { echo "SKIP: wl-clipboard not on PATH"; exit 0; }
    {
        printf 'output HEADLESS-1 resolution 1280x720\n'
        printf 'default_border none\ndefault_floating_border none\n'
        printf 'for_window [app_id="wsi-f16-a"] floating enable, move position 0 120\n'
        printf 'for_window [app_id="wsi-f16-b"] floating enable, move position 640 120\n'
    } > "$rt/sway.cfg"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        sway -c "$rt/sway.cfg" > "$rt/sway.log" 2>&1 &
    comp_pid=$!
    sleep 3
    wld="$(cd "$rt" && ls wayland-* 2>/dev/null | grep -v '\.lock$' | head -n 1)"
    [ -n "$wld" ] || { echo "SKIP: sway did not create a wayland socket"; exit 0; }
    SWAYSOCK="$(ls "$rt"/sway-ipc.*.sock | head -n 1)"
    export SWAYSOCK

    env WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=18000 \
        ${WSI_DEMO_DEBUG:+WAYLAND_DEBUG=1} "$demo" &
    demo_pid=$!
    sleep 2.5 # both windows mapped; the stale set_selection(serial=0) probe ran

    echo "--- after stale set_selection(serial=0): what does wl-paste see? ---"
    WAYLAND_DISPLAY="$wld" wl-paste --list-types 2>&1 || echo "(wl-paste exit=$?)"

    echo "--- injected right-click on A -> set_selection with a REAL serial ---"
    WAYLAND_DISPLAY="$wld" "$demo" inject click 320 360 273 2>/dev/null
    sleep 0.5
    echo "--- wl-paste --list-types (the offer, seen by a second client) ---"
    WAYLAND_DISPLAY="$wld" wl-paste --list-types 2>&1 || echo "(wl-paste exit=$?)"
    echo "--- wl-paste (the payload; demo serves the send fd) ---"
    WAYLAND_DISPLAY="$wld" wl-paste --no-newline 2>&1 || echo "(wl-paste exit=$?)"
    echo ""

    echo "--- wl-copy takes the selection over -> cancelled on our source ---"
    WAYLAND_DISPLAY="$wld" wl-copy "stolen-by-wl-copy"
    sleep 0.5
    # Selection offers are delivered on keyboard-focus enter; plug a wtype
    # virtual keyboard so the demo client gains keyboard focus and receives
    # wl-copy's offer (the paste leg).
    swaymsg '[app_id=wsi-f16-a] focus' > /dev/null || true
    if command -v wtype >/dev/null; then
        WAYLAND_DISPLAY="$wld" wtype -k a
    else
        echo "note: wtype not on PATH; paste-on-focus leg skipped" >&2
    fi
    sleep 1

    echo "--- injected drag: press on A, sweep into B, release (drop) ---"
    WAYLAND_DISPLAY="$wld" "$demo" inject drag 320 360 960 360 2>/dev/null

    wait "$demo_pid"
    ;;
*)
    echo "usage: $0 [weston|sway]" >&2
    exit 2
    ;;
esac
