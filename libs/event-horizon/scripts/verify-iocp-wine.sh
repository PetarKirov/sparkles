#!/usr/bin/env bash
# Cross-compile the IOCP backend's data-path unittest to a Windows .exe and
# run it under headless Wine — the M11 gate (SPEC §3.5, backend/iocp.d).
#
# Must run inside a win32 dev shell (which provides win32-ldc2 + wine64) whose
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
base="$repo/libs/base/src"
# The `expected` runtime dep, resolved from the dub package cache.
exp="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
exp_src="$(dirname "$exp")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

ehm="$eh/sparkles/event_horizon"
echo ">> building dependency closure (no -unittest) ..."
win32-ldc2 -lib -preview=in -preview=dip1000 \
  -I"$eh" -I"$base" -I"$exp_src" \
  "$ehm/errors.d" "$ehm/op.d" "$ehm/buffer.d" "$ehm/net.d" \
  "$ehm/capability.d" "$ehm/cause.d" \
  "$ehm/backend/concept.d" "$ehm/backend/probe.d" "$exp_src/expected.d" \
  -of=deps.lib

echo ">> linking the IOCP data-path test ..."
win32-ldc2 -unittest -main -g -preview=in -preview=dip1000 \
  -I"$eh" -I"$base" -I"$exp_src" \
  "$ehm/backend/iocp.d" deps.lib -of=iocptest.exe

echo ">> running under Wine ..."
WINEPREFIX="$(mktemp -d)" WINEDEBUG=-all wine64 iocptest.exe
echo ">> IOCP backend verified under Wine."
