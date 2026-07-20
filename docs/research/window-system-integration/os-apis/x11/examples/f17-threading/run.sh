#!/usr/bin/env bash
# F17 test driver — NOT part of the CI contract (CI builds and runs the demo
# binary with no arguments, which forks every probe twice in-process and
# exits 0). This driver runs each probe twice in its OWN Xvfb instance
# instead, so a probe that corrupts or kills its X connection can never
# contaminate the next probe's server-side state, and so per-probe exit codes
# are individually visible. Run it from the repo dev shell (`nix develop`,
# for dub/xvfb-run).
#
#     ./run.sh        # build, then 6 probes x 2 runs, one Xvfb each
#
# Probes (see ../../f17-threading.md for the outcome table they produce):
#   1  window on worker thread, NO XInitThreads, main pumps  (violation)
#   2  same WITH XInitThreads                                (legal)
#   3  two threads sharing one Display, both in XNextEvent   (legal)
#   4  XShmPutImage from a render thread, main pumps         (legal)
#   5  one Display per thread, NO XInitThreads               (always safe)
#   6  XInitThreads called AFTER XOpenDisplay                (violation)
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
demo="$dir/build/f17_threading_x11"

dub build --root="$dir"
for n in 1 2 3 4 5 6; do
    for run in 1 2; do
        echo "=== probe $n run $run ==="
        xvfb-run -a "$demo" --probe="$n"
    done
done
