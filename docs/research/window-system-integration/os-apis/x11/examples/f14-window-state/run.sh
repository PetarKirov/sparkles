#!/usr/bin/env bash
# F14 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, whose WSI_AUTO_EXIT=1 schedule self-drives every transition and
# exits 0). This driver adds what the self-driven run cannot: the WM-mode
# contrast (bare Xvfb vs icewm), externally injected keys (xdotool), a real
# WM-originated close (icewm's Alt+F4 -> WM_DELETE_WINDOW ClientMessage), and
# the WM_PROTOCOLS-absent probe (Alt+F4 -> XKillClient -> dead connection).
# Run it from the repo dev shell (`nix develop`, for dub/xvfb-run); xdotool
# and icewm come via `nix shell`.
#
#     ./run.sh        # build, then run all four passes, each in its own Xvfb
#
# Passes (see ../../f14-window-state.md for the findings they produce):
#   A  bare Xvfb, self-driven: the no-WM truth — every state request is a
#      ClientMessage to the root that only a SubstructureRedirect client (a
#      WM) would receive; with none running, nothing comes back (summary
#      state_changes=0 configures=0)
#   B  icewm, self-driven: the real sequences (property/configure/focus echo
#      per transition) that feed event-sequences.md
#   C  icewm, xdotool-driven: XTEST keys to the focused window (an iconified
#      window has no focus, so de-iconify comes from `xdotool windowactivate`
#      = _NET_ACTIVE_WINDOW, the pager/taskbar path), then two Alt+F4
#      presses: the first WM-originated WM_DELETE_WINDOW is vetoed (dirty),
#      the second closes
#   D  icewm, WSI_NO_WM_DELETE=1: WM_DELETE_WINDOW not in WM_PROTOCOLS.
#      Alt+F4 does NOT kill silently — icewm pops its confirm-kill YMsgBox
#      (wmConfirmKill, icewm src/wmframe.cc; visible in the log as a focus
#      steal under a grab). The deterministic kill is then driven directly:
#      `xdotool windowkill` = XKillClient — the connection dies, the demo's
#      XIO handler logs `connection_lost` and exits 0
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
demo="$dir/build/f14_window_state_x11"

if [[ -z "${WSI_F14_PASS:-}" ]]; then
    dub build --root="$dir"
    exec nix shell nixpkgs#xdotool nixpkgs#icewm --command bash -c "
        set -euo pipefail
        echo '=== pass A: bare Xvfb (no WM), self-driven ==='
        WSI_F14_PASS=A xvfb-run -a '$0'
        echo '=== pass B: icewm, self-driven ==='
        WSI_F14_PASS=B xvfb-run -a '$0'
        echo '=== pass C: icewm, xdotool keys + Alt+F4 vetoable close ==='
        WSI_F14_PASS=C xvfb-run -a '$0'
        echo '=== pass D: icewm, no WM_DELETE_WINDOW -> XKillClient ==='
        WSI_F14_PASS=D xvfb-run -a '$0'
    "
fi

case "$WSI_F14_PASS" in
A)
    WSI_AUTO_EXIT=1 "$demo"
    ;;
B)
    icewm >/dev/null 2>&1 &
    sleep 2
    WSI_AUTO_EXIT=1 "$demo"
    ;;
C)
    icewm >/dev/null 2>&1 &
    sleep 2
    WSI_DRIVEN=1 "$demo" &
    pid=$!
    sleep 1.5
    wid=$(xdotool search --name 'F14 window state' | head -1)
    # XTEST keys land on the focused window. (XSendEvent-style
    # `xdotool key --window` is unreliable here: keys sent around the
    # iconify/restore boundary were observed re-delivered after re-maps.)
    for k in m m f f i; do
        xdotool key "$k"
        sleep 0.7
    done
    # The iconified window holds no focus, so no key can reach it; restore
    # the way a taskbar would: _NET_ACTIVE_WINDOW via windowactivate.
    xdotool windowactivate "$wid"
    sleep 0.7
    xdotool key d
    sleep 0.7
    xdotool key alt+F4 # WM-originated close request #1 -> vetoed (dirty)
    sleep 0.7
    xdotool key alt+F4 # close request #2 -> demo quits
    wait "$pid"
    ;;
D)
    icewm >/dev/null 2>&1 &
    sleep 2
    WSI_NO_WM_DELETE=1 WSI_DRIVEN=1 "$demo" &
    pid=$!
    sleep 1.5
    wid=$(xdotool search --name 'F14 window state' | head -1)
    xdotool key alt+F4 # no handshake -> icewm confirm-kill dialog, no event
    sleep 1
    xdotool windowkill "$wid" # XKillClient: the no-handshake worst case
    wait "$pid"
    ;;
esac
