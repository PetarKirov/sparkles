#!/usr/bin/env bash
# Build and run the FULL EventLoop!KqueueBackend integration on Linux, on top
# of mheily/libkqueue (an epoll compatibility shim) — the loop-portability
# gate for the kqueue peer backend. Unlike verify-kqueue-macos.sh (which needs
# a Mac and tests only the backend's data path), this drives the whole stack —
# tier-A loop + tier-B fibers + the accept/connect/recv/send verbs — through
# the kqueue backend on Linux, so it runs in ordinary Linux CI.
#
#     LIBKQUEUE_SRC=/path/to/mheily/libkqueue \
#       libs/event-horizon/scripts/verify-kqueue-linux.sh
#
# It builds libkqueue from source into a temp dir, then compiles the fiber-echo
# example with -d-version=EventHorizonLibkqueue (which selects the kqueue
# backend, see backend/select.d) linked against libkqueue, and runs it.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
eh="$repo/libs/event-horizon/src"
base="$repo/libs/base/src"
ehm="$eh/sparkles/event_horizon"
exp="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
exp_src="$(dirname "$exp")"
libkqueue_src="${LIBKQUEUE_SRC:-$HOME/code/repos/libkqueue}"

if [[ ! -f "$libkqueue_src/CMakeLists.txt" ]]; then
  echo "libkqueue source not found at $libkqueue_src; set LIBKQUEUE_SRC." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> building libkqueue ..."
nix shell nixpkgs#cmake nixpkgs#gcc nixpkgs#gnumake -c bash -c "
  cd '$work' && cmake -DCMAKE_BUILD_TYPE=Release '$libkqueue_src' >/dev/null && make -j4 >/dev/null
"
kqinc="$work/include"
kqlib="$work"

# The fiber-echo example is the workload; strip its dub single-file header.
sed '/^#!/d; /^\/+ dub.sdl:/,/^+\//d' \
  "$repo/libs/event-horizon/examples/fiber-echo.d" > "$work/echo.d"

echo ">> compiling the fiber echo against EventLoop!KqueueBackend ..."
nix shell nixpkgs#ldc -c bash -c "
  ldc2 -d-version=EventHorizonLibkqueue -preview=in -preview=dip1000 -g \
    -I'$eh' -I'$base' -I'$exp_src' -I'$kqinc' \
    '$work/echo.d' \
    '$ehm/errors.d' '$ehm/op.d' '$ehm/buffer.d' '$ehm/net.d' '$ehm/capability.d' \
    '$ehm/cause.d' '$ehm/scope_.d' '$ehm/schedule.d' '$ehm/clock.d' '$ehm/loop.d' \
    '$ehm/sched.d' '$ehm/io.d' '$ehm/backend/concept.d' '$ehm/backend/probe.d' \
    '$ehm/backend/kqueue.d' '$ehm/backend/select.d' '$exp_src/expected.d' \
    -L-L'$kqlib' -L-lkqueue -of='$work/kqecho'
"

echo ">> running under libkqueue ..."
LD_LIBRARY_PATH="$kqlib" "$work/kqecho"
echo ">> EventLoop!KqueueBackend verified on Linux via libkqueue."
