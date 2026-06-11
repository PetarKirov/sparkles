#!/bin/sh
# Tier-A driver for the F14 window-state demo (see ./app.d and
# ../../f14-window-state.md).
#
#   ./run.sh weston       full state storm on headless weston (socket wsi-w7a):
#                         maximize → unmaximize → fullscreen → unfullscreen →
#                         minimize, every configure's states array decoded.
#                         Headless weston has no way to deliver a close, so
#                         the run ends on the time cap.
#   ./run.sh sway         same storm on headless sway (tiled), then the
#                         vetoable-close choreography: `swaymsg kill` once
#                         (vetoed — the window survives), `swaymsg kill`
#                         again (accepted — clean exit).
#   ./run.sh sway-epipe   veto *every* close (WSI_VETO_CLOSE=99), `swaymsg
#                         kill`, then kill the compositor out from under the
#                         lingering client — dispatch fails, errno captured.
#
# weston/dub come from the repo dev shell; sway modes need sway+swaymsg, e.g.
# `nix shell nixpkgs#sway -c ./run.sh sway`. Each mode is self-contained:
# private XDG_RUNTIME_DIR, compositor killed on exit.
set -eu
cd "$(dirname "$0")"
mode="${1:-weston}"
demo=./build/f14_window_state
[ -x "$demo" ] || dub build --compiler=ldc2 >&2

rt="$(mktemp -d)"
export XDG_RUNTIME_DIR="$rt"
unset WAYLAND_DISPLAY DISPLAY || true

cleanup()
{
    [ -n "${comp_pid:-}" ] && kill "$comp_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

start_sway()
{
    command -v sway >/dev/null || { echo "SKIP: sway not on PATH"; exit 0; }
    printf 'output HEADLESS-1 resolution 1280x720\n' > "$rt/sway.cfg"
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
    weston --backend=headless --socket=wsi-w7a --idle-time=0 > "$rt/weston.log" 2>&1 &
    comp_pid=$!
    sleep 2
    WAYLAND_DISPLAY=wsi-w7a WSI_AUTO_EXIT=1 "$demo"
    ;;
sway)
    start_sway
    # Storm finishes at ~4.7 s; keep the demo alive past it so both closes
    # land while the window still exists.
    WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=9000 "$demo" &
    demo_pid=$!
    sleep 6
    echo "--- swaymsg kill #1 (must be vetoed) ---"
    swaymsg '[app_id=wsi-f14-window-state] kill' > /dev/null || true
    sleep 1
    echo "--- swaymsg kill #2 (accepted) ---"
    swaymsg '[app_id=wsi-f14-window-state] kill' > /dev/null || true
    wait "$demo_pid" || true
    ;;
sway-epipe)
    start_sway
    WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=9000 WSI_VETO_CLOSE=99 "$demo" &
    demo_pid=$!
    sleep 6
    swaymsg '[app_id=wsi-f14-window-state] kill' > /dev/null || true
    sleep 1
    echo "--- compositor dies under the lingering veto-er ---"
    kill "$comp_pid" 2>/dev/null || true
    comp_pid=
    wait "$demo_pid" || true
    ;;
*)
    echo "usage: $0 [weston|sway|sway-epipe]" >&2
    exit 2
    ;;
esac
