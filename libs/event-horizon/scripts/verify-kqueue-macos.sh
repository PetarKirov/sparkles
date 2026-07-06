#!/usr/bin/env bash
# Compile the kqueue backend's data-path unittest and run it on macOS — the
# M10 gate (SPEC §3.5, backend/kqueue.d). kqueue is macOS/BSD-only, so this
# must run on a Mac (e.g. over ssh to the build host). It uses `nix shell
# nixpkgs#ldc` for the compiler because `dub build`/`dub run` fork-ENOMEM on
# recent macOS — build via ldc2 directly.
#
#     # on macOS, from a repo checkout:
#     libs/event-horizon/scripts/verify-kqueue-macos.sh
#
# Two-step like the Wine/IOCP script: the module closure builds into a static
# lib WITHOUT -unittest (so only the kqueue backend's own tests run), then
# kqueue.d links WITH -unittest -main and the exe runs natively.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
eh="$repo/libs/event-horizon/src"
base="$repo/libs/base/src"
exp="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
exp_src="$(dirname "$exp")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

ehm="$eh/sparkles/event_horizon"
run() { nix shell nixpkgs#ldc -c bash -c "$1"; }

echo ">> building dependency closure (no -unittest) ..."
run "ldc2 -lib -preview=in -preview=dip1000 \
  -I'$eh' -I'$base' -I'$exp_src' \
  '$ehm/errors.d' '$ehm/op.d' '$ehm/buffer.d' '$ehm/net.d' \
  '$ehm/capability.d' '$ehm/cause.d' \
  '$ehm/backend/concept.d' '$ehm/backend/probe.d' '$exp_src/expected.d' \
  -of=deps.a"

echo ">> linking the kqueue data-path test ..."
run "ldc2 -unittest -main -g -preview=in -preview=dip1000 \
  -I'$eh' -I'$base' -I'$exp_src' \
  '$ehm/backend/kqueue.d' deps.a -of=kqtest"

echo ">> running natively ..."
./kqtest
echo ">> kqueue backend verified on macOS."
