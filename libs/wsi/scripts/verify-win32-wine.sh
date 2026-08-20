#!/usr/bin/env bash
# Cross-compile the native Win32 WSI/Event Horizon hosted-loop smoke test and
# run it against Wine's User32 path. Run from the repository root:
#
#   nix develop .#win32 -c libs/wsi/scripts/verify-win32-wine.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
expected="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
expected_src="$(dirname "$expected")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> cross-compiling sparkles:wsi Win32 hosted-loop smoke ..."
win32-ldc2 -preview=in -preview=dip1000 -g -i \
  -I"$repo/libs/wsi/src" \
  -I"$repo/libs/event-horizon/src" \
  -I"$repo/libs/input/src" \
  -I"$repo/libs/math/src" \
  -I"$repo/libs/base/src" \
  -I"$repo/libs/test-runner/src" \
  -I"$expected_src" \
  "$repo/libs/wsi/examples/win32-hosted-smoke.d" \
  -of="$work/wsi-win32-smoke.exe"

echo ">> running under Wine ..."
mkdir "$work/runtime"
chmod 700 "$work/runtime"
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$work/runtime" \
  WINEPREFIX="$work/wine" WINEDEBUG=-all \
  xvfb-run -a wine64 "$work/wsi-win32-smoke.exe" \
  | tee "$work/output.log"
grep -q '^ok: Win32 HWND + keyboard/IMM32 + IOCP hosted wait' "$work/output.log"
echo ">> sparkles:wsi Win32 hosted-loop smoke verified under Wine."
