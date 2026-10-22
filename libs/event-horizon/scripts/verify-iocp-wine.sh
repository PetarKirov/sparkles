#!/usr/bin/env bash
# Cross-compile the IOCP backend's data-path, batch and cancellation tests and
# run it under headless Wine — the M11 gate (SPEC §3.5, backend/iocp.d).
#
# Must run inside a win32 dev shell (which provides win32-ldc2 + wine) whose
# `ldc2` is LLD-integrated (the official ldc-binary release) — `-link-internally`
# needs it. This repo's `.#win32` shell inherits its `ldc2` from `d-toolchain`;
# if that build lacks integrated LLD you'll see "Unknown command line argument
# '-link-internally'". Run from a shell with the ldc-binary, e.g. the
# window-system research repo's win32 shell:
#
#     nix develop .#win32 -c libs/event-horizon/scripts/verify-iocp-wine.sh
#
# It builds the module closure iocp.d needs into a static lib WITHOUT
# -unittest (so only the IOCP backend's own tests run, not the deps'), then
# links iocp.d WITH -unittest -main and runs the exe under a throwaway Wine
# prefix. Exits non-zero if the Wine run fails.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
eh="$repo/libs/event-horizon/src"
# The `expected` runtime dep, resolved from the dub package cache.
exp="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
exp_src="$(dirname "$exp")"

work="$(mktemp -d)"
export WINEPREFIX="$work/wine"
trap 'wineserver -k 2>/dev/null || true; wineserver -w 2>/dev/null || true; rm -rf "$work"' EXIT
cd "$work"

includes=(
  -I"$eh"
  -I"$repo/libs/event-horizon-sys/src"
  -I"$repo/libs/base/src"
  -I"$repo/libs/metadata/src"
  -I"$repo/libs/reflection/src"
  -I"$repo/libs/test-runner/src"
  -I"$repo/libs/test-runner-impl/src"
  -I"$exp_src"
)
ehm="$eh/sparkles/event_horizon"

# `-i` compiles whatever iocp.d imports, so the closure follows the code
# instead of a hand-kept file list. The root is a stub importing iocp.d, which
# `-i=-…` leaves out: the test links its own `-unittest` build of it. `skip.d`
# is named because only iocp.d's tests import it, and this build does not
# compile them.
echo ">> building dependency closure (no -unittest) ..."
echo "module deps; import sparkles.event_horizon.backend.iocp;" > deps.d
win32-ldc2 -lib -i -i=-sparkles.event_horizon.backend.iocp \
  -preview=in -preview=dip1000 "${includes[@]}" \
  deps.d "$repo/libs/test-runner-impl/src/sparkles/test_runner/skip.d" \
  -of=deps.lib

echo ">> linking the IOCP data-path test ..."
win32-ldc2 -unittest -main -g -preview=in -preview=dip1000 "${includes[@]}" \
  "$ehm/backend/iocp.d" deps.lib -of=iocptest.exe

echo ">> running under Wine ..."
WINEDEBUG=-all timeout 60 wine iocptest.exe
echo ">> IOCP backend verified under Wine."
