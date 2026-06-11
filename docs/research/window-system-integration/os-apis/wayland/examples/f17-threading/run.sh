#!/bin/sh
# F17 test driver — NOT part of the CI contract (CI builds and runs the demo
# binary with no arguments, which forks every probe twice in-process and
# exits 0). This driver runs each probe twice against its OWN headless weston
# instance (socket wsi-w9) instead, so a probe that wedges its connection or
# the compositor can never contaminate the next probe, and per-probe exit
# codes are individually visible. Run it from the repo dev shell
# (`nix develop`, for dub/weston).
#
#     ./run.sh        # build, then 6 probes x 2 runs, one weston each
#
# Probes (see ../../f17-threading.md for the outcome table they produce):
#   1  window built entirely on a worker thread, main sleeps     (legal)
#   2  two threads concurrently dispatching the default queue    (legal)
#   3  per-thread wl_event_queue via a display wrapper           (the pattern)
#   4  attach/damage/frame/commit from a render thread           (legal)
#   5  one wl_display connection per thread                      (always safe)
#   6  read_events without prepare_read while another holds it   (violation)
set -eu
cd "$(dirname "$0")"
demo=./build/f17_threading_wayland
command -v weston > /dev/null || { echo "SKIP: weston not on PATH"; exit 0; }
[ -x "$demo" ] || dub build --compiler=ldc2 >&2

for n in 1 2 3 4 5 6; do
    for run in 1 2; do
        echo "=== probe $n run $run ==="
        rt="$(mktemp -d)"
        XDG_RUNTIME_DIR="$rt" weston --backend=headless --socket=wsi-w9 \
            --idle-time=0 > "$rt/weston.log" 2>&1 &
        comp_pid=$!
        sleep 1
        XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wsi-w9 \
            "$demo" --probe="$n" || true
        kill "$comp_pid" 2> /dev/null || true
        wait "$comp_pid" 2> /dev/null || true
        rm -rf "$rt"
    done
done
