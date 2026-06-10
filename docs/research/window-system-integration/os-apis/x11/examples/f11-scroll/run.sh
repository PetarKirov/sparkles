#!/usr/bin/env bash
# F11 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, whose built-in pass dumps the scroll-class device query and
# probes XSendEvent-fabricated wheel events, then exits 0). This driver adds
# real XTest wheel clicks (xdotool click 4/5/6/7) so both representations of
# a wheel event — core buttons and XI2 button events — are captured, and the
# XIPointerEmulated flag can be measured on the XI2 side. Run it from the
# repo dev shell (`nix develop`, for dub/xvfb-run); xdotool via `nix shell`.
#
#     ./run.sh        # build, then run both passes under Xvfb
#
# Passes (see ../../f11-scroll.md for the findings they produce):
#   A  built-in:  device query (scroll_class none=1 on every Xvfb device) +
#      XSendEvent probes (send_event=1, core-only, no XI2 twin)
#   B  driven:    WSI_DRIVEN=1 + xdotool wheel clicks against three phases —
#      dual_client (core on conn 2, XI2 on conn 1), dual_selection (one
#      client selecting core AND XI2: who gets the event?), then core_only
#      (XI2 selection cleared: does core delivery resume?)
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${WSI_F11_INNER:-}" ]]; then
    dub build --root="$dir"
    exec nix shell nixpkgs#xdotool --command xvfb-run -a env WSI_F11_INNER=1 "$0"
fi

demo="$dir/build/f11_scroll_x11"

echo "=== pass A: built-in (device query + XSendEvent probes) ==="
WSI_AUTO_EXIT=1 "$demo"

echo "=== pass B: xdotool-driven (XTest wheel clicks) ==="
# Driven phases are 4 s each, anchored at the first Expose: dual_client
# 0-4 s, dual_selection 4-8 s, core_only 8-12 s. The window maps at +20+20.
WSI_AUTO_EXIT=1 WSI_DRIVEN=1 "$demo" &
pid=$!
sleep 0.8
xdotool mousemove 261 181 # pointer over the window: clicks deliver there
sleep 0.2
# phase dual_client: one "gesture" of 3 detents down, pause, then a mixed one
xdotool click --repeat 3 --delay 120 5
sleep 0.7
xdotool click --repeat 2 --delay 120 4
xdotool click 6
xdotool click 7
sleep 1.7
# phase dual_selection: same wheel input against the merged selection
xdotool click --repeat 3 --delay 120 5
sleep 0.7
xdotool click 4
sleep 2.6
# phase core_only: same wheel input with the XI2 selection cleared
xdotool click --repeat 3 --delay 120 5
sleep 0.7
xdotool click 4
sleep 0.3
wait "$pid"
