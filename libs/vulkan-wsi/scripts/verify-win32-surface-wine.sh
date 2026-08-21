#!/usr/bin/env bash
# Cross-compile the Win32 runtime Vulkan surface smoke and execute it under
# Wine's winevulkan. Run from the repository root:
#
#   nix develop .#win32 -c libs/vulkan-wsi/scripts/verify-win32-surface-wine.sh
#
# The example skips honestly when Wine reaches no Vulkan runtime or device;
# this lane treats that skip as a failure because winevulkan plus the host ICD
# is the point being verified.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
expected="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
expected_src="$(dirname "$expected")"
vulkan_include="$(pkg-config --variable=includedir vulkan)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> cross-compiling sparkles:vulkan-wsi Win32 runtime surface smoke ..."
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
  "$repo/libs/vulkan-wsi/examples/native-win32-surface-smoke.d" \
  -of="$work/vulkan-wsi-win32-surface.exe"

echo ">> running under Wine ..."
mkdir "$work/runtime"
chmod 700 "$work/runtime"
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$work/runtime" \
  WINEPREFIX="$work/wine" WINEDEBUG=-all \
  xvfb-run -a wine64 "$work/vulkan-wsi-win32-surface.exe" \
  | tee "$work/output.log"
grep -q '^ok: Win32 native handles -> Vulkan surface -> present device' \
  "$work/output.log"
echo ">> sparkles:vulkan-wsi Win32 runtime surface verified under Wine."
