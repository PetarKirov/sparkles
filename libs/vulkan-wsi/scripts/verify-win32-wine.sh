#!/usr/bin/env bash
# Cross-compile the Win32 Vulkan surface ABI/plan and execute it under Wine.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
expected="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
expected_src="$(dirname "$expected")"
vulkan_include="$(pkg-config --variable=includedir vulkan)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> cross-compiling sparkles:vulkan-wsi Win32 surface plan ..."
win32-ldc2 -preview=in -preview=dip1000 -g -i \
  -I"$repo/libs/vulkan-wsi/src" \
  -I"$repo/libs/vulkan/src" \
  -I"$repo/libs/wsi/src" \
  -I"$repo/libs/event-horizon/src" \
  -I"$repo/libs/input/src" \
  -I"$repo/libs/math/src" \
  -I"$repo/libs/base/src" \
  -I"$repo/libs/test-runner/src" \
  -I"$expected_src" \
  -P-I"$WIN32_SDK/crt/include" \
  -P-I"$WIN32_SDK/sdk/include/ucrt" \
  -P-I"$WIN32_SDK/sdk/include/shared" \
  -P-I"$WIN32_SDK/sdk/include/um" \
  -P-I"$vulkan_include" \
  "$repo/libs/vulkan-wsi/examples/surface-plan-smoke.d" \
  -of="$work/vulkan-wsi-win32-plan.exe"

echo ">> running under Wine ..."
mkdir "$work/runtime"
chmod 700 "$work/runtime"
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$work/runtime" \
  WINEPREFIX="$work/wine" WINEDEBUG=-all \
  xvfb-run -a wine64 "$work/vulkan-wsi-win32-plan.exe" \
  | tee "$work/output.log"
grep -q '^ok: Win32 native Vulkan surface ABI/plan' "$work/output.log"
echo ">> sparkles:vulkan-wsi Win32 surface plan verified under Wine."
