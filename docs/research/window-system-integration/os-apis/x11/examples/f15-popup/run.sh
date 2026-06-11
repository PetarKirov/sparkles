#!/usr/bin/env bash
# F15 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, whose WSI_AUTO_EXIT=1 schedule self-drives the placement /
# stacking / grab-return-code probes and exits 0). This driver adds what
# needs real device input (xdotool -> XTEST): hover highlight through the
# grab, submenu hover-open, item activation, outside-click dismissal, the
# second-client starvation measurement, and Esc — each on bare Xvfb AND
# under icewm. Run it from the repo dev shell (`nix develop`, for
# dub/xvfb-run); xdotool and icewm come via `nix shell`.
#
#     ./run.sh        # build, then run all four passes, each in its own Xvfb
#
# Passes (see ../../f15-popup.md for the findings they produce):
#   A  bare Xvfb, self-driven probes (edge clamp math, XQueryTree stacking,
#      AlreadyGrabbed return code)
#   B  icewm, same self-driven probes (override-redirect: the WM changes
#      nothing about the popup itself)
#   C  bare Xvfb, xdotool-driven: right-click open -> hover items -> submenu
#      -> click item; reopen -> click the second client's window (the grab
#      eats it: dismissal for us, starvation for it; the contrast click
#      after dismissal reaches it); reopen -> Esc
#   D  icewm, the same choreography (coordinates re-derived from the
#      WM-placed window position via getwindowgeometry)
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
demo="$dir/build/f15_popup_x11"

if [[ -z "${WSI_F15_PASS:-}" ]]; then
    dub build --root="$dir"
    exec nix shell nixpkgs#xdotool nixpkgs#icewm --command bash -c "
        set -euo pipefail
        echo '=== pass A: bare Xvfb (no WM), self-driven probes ==='
        WSI_F15_PASS=A xvfb-run -a '$0'
        echo '=== pass B: icewm, self-driven probes ==='
        WSI_F15_PASS=B xvfb-run -a '$0'
        echo '=== pass C: bare Xvfb, xdotool-driven menu choreography ==='
        WSI_F15_PASS=C xvfb-run -a '$0'
        echo '=== pass D: icewm, xdotool-driven menu choreography ==='
        WSI_F15_PASS=D xvfb-run -a '$0'
    "
fi

drive() {
    WSI_DRIVEN=1 "$demo" &
    local pid=$!
    sleep 1.5
    local wid sw px py sx sy
    wid=$(xdotool search --name 'F15 popup' | head -1)
    sw=$(xdotool search --name 'F15 second client' | head -1)
    # Root coordinates of the (possibly WM-placed) windows:
    eval "$(xdotool getwindowgeometry --shell "$wid")" # X= Y= WIDTH= ...
    px=$((X + 180)) py=$((Y + 180))                    # right-click spot
    eval "$(xdotool getwindowgeometry --shell "$sw")"
    sx=$((X + 50)) sy=$((Y + 50)) # second client's center

    xdotool mousemove "$px" "$py" click 3 # open: popup at (px,py), 160x72
    sleep 0.5
    xdotool mousemove $((px + 40)) $((py + 12)) # hover item 0
    sleep 0.3
    xdotool mousemove $((px + 40)) $((py + 36)) # hover item 1
    sleep 0.3
    xdotool mousemove $((px + 40)) $((py + 60)) # hover item 2 -> submenu
    sleep 0.5
    xdotool mousemove $((px + 196)) $((py + 60)) # into submenu item 0
    sleep 0.4
    xdotool click 1 # activate -> dismiss cause=item_activated
    sleep 0.5
    xdotool mousemove "$px" "$py" click 3 # reopen
    sleep 0.5
    xdotool mousemove "$sx" "$sy" click 1 # outside click over the 2nd client:
    sleep 0.5                             #   our grab eats it, client starves
    xdotool click 1                       # no grab now: the 2nd client gets it
    sleep 0.5
    xdotool mousemove "$px" "$py" click 3 # reopen
    sleep 0.5
    xdotool key Escape # dismiss cause=esc
    sleep 0.4
    xdotool mousemove "$px" "$py" key q # quit (PointerRoot/clicked focus)
    wait "$pid"
}

case "$WSI_F15_PASS" in
A)
    WSI_AUTO_EXIT=1 "$demo"
    ;;
B)
    icewm >/dev/null 2>&1 &
    sleep 2
    WSI_AUTO_EXIT=1 "$demo"
    ;;
C)
    drive
    ;;
D)
    icewm >/dev/null 2>&1 &
    sleep 2
    drive
    ;;
esac
