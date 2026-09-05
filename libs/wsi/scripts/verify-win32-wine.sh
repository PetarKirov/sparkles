#!/usr/bin/env bash
# Cross-compile the native Win32 WSI/Event Horizon hosted-loop smoke test and
# run it against Wine's User32 path. Run from the repository root:
#
#   nix develop .#win32 -c libs/wsi/scripts/verify-win32-wine.sh
#
# The driver is built through its own dub recipe — the same build the native
# Windows CI leg runs (`ci/test-windows.sh` + the workflow's smoke step) — so
# the two lanes cannot drift apart in what they compile. `dub build` rather
# than `dub run`: the .exe is a foreign binary here, and Wine is the runner.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> cross-compiling sparkles:wsi Win32 hosted-loop smoke ..."
dub build --single --compiler=win32-ldc2 --arch=x86_64-windows-msvc \
  "$repo/libs/wsi/examples/win32-hosted-smoke.d"
exe="$repo/libs/wsi/examples/build/win32_hosted_smoke.exe"
[ -f "$exe" ] || { echo "smoke binary missing at $exe" >&2; exit 1; }

echo ">> running under Wine ..."
mkdir "$work/runtime"
chmod 700 "$work/runtime"
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$work/runtime" \
  WINEPREFIX="$work/wine" WINEDEBUG=-all \
  xvfb-run -a wine64 "$exe" \
  | tee "$work/output.log"
grep -q '^ok: Win32 WSI conformance (15 checked, 3 skipped)' "$work/output.log"
grep -q '^ok: Win32 text commit + IMM32 composition round trip' "$work/output.log"

# No 192-DPI phase: a per-monitor-V2-aware window under Wine always sees a
# 96-DPI monitor (GetDpiForWindow ignores LogPixels, which only feeds the
# system DPI), so the scale property stays runtime-skipped here. The native
# Windows CI leg runs this same driver on a real User32; its hosted runner is
# a 96-DPI desktop too, so per-monitor scale evidence is still owed. The
# driver already honours WSI_EXPECT_SCALE for a lane that can set it.
echo ">> sparkles:wsi Win32 hosted-loop smoke verified under Wine."
