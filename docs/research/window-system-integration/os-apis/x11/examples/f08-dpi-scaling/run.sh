#!/usr/bin/env bash
# F08 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, which observes a static Xvfb and exits 0). Run it from the
# repo dev shell (`nix develop`, for dub/xvfb-run); xrdb and xrandr are
# pulled in via `nix shell`.
#
#     ./run.sh        # build, then run the xrdb/xrandr choreography under Xvfb
#
# Sequence (see ../../f08-dpi-scaling.md for the findings it produces):
#   demo starts     -> startup snapshot: no Xft.dpi, core-screen DPI, RandR
#   xrdb -merge 144 -> root RESOURCE_MANAGER PropertyNotify (the ONLY live
#                      channel); XResourceManagerString stays stale, a fresh
#                      XGetWindowProperty sees 144; NOTHING on the window
#   xrdb -merge 192 -> same again (proves repeatability, 144 -> 192)
#   xrandr --dpi 144 -> does Xvfb emit RRScreenChangeNotify? (measured)
#
# Note: properties on a bare Xvfb only persist while at least one client is
# connected (the server resets when the last client exits) — the demo itself
# keeps the server alive here, but don't expect `xrdb -merge` + later
# `xrdb -query` to work across separate one-shot clients.
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${WSI_F08_INNER:-}" ]]; then
    dub build --root="$dir"
    exec nix shell nixpkgs#xorg.xrdb nixpkgs#xorg.xrandr --command \
        xvfb-run -a env WSI_F08_INNER=1 "$0"
fi

# ---- inner: DISPLAY points at a fresh Xvfb ----------------------------------
WSI_AUTO_EXIT=1 WSI_DURATION_MS=${WSI_DURATION_MS:-8000} \
    "$dir/build/f08_dpi_scaling_x11" &
demo=$!
sleep 2 # let the demo map and finish its startup snapshot

# The "system scale change" an X11 desktop actually performs: merge a new
# Xft.dpi into the root RESOURCE_MANAGER property. -nocpp so the driver does
# not depend on a C preprocessor being on PATH.
echo 'Xft.dpi: 144' | xrdb -merge -nocpp -
sleep 1.5
echo 'Xft.dpi: 192' | xrdb -merge -nocpp -
sleep 1.5

# RandR: --dpi rewrites the screen's physical-millimeter size to match the
# requested DPI at the current pixel size. Does a live client hear about it?
xrandr --dpi 144 || echo "driver: xrandr --dpi failed (logged as a finding)"
sleep 1.5

wait "$demo"
