#!/usr/bin/env bash
# Prove typed XCB handles can create a Vulkan surface and present device.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> building sparkles:vulkan-wsi native X11 surface smoke ..."
(
  cd "$repo/libs/vulkan-wsi/examples"
  dub build --single native-x11-surface-smoke.d --compiler=ldc2 --force
)

echo ">> checking the no-display capability gate ..."
env -u DISPLAY -u WAYLAND_DISPLAY \
  "$repo/libs/vulkan-wsi/examples/build/vulkan_wsi_native_x11_surface_smoke" \
  | tee "$work/skip.log"
grep -q '^SKIP: no X11 display' "$work/skip.log"

echo ">> creating a Vulkan surface against Xvfb ..."
env -u WAYLAND_DISPLAY xvfb-run -a \
  "$repo/libs/vulkan-wsi/examples/build/vulkan_wsi_native_x11_surface_smoke" \
  | tee "$work/output.log"
grep -q '^ok: X11 native handles -> Vulkan surface' "$work/output.log"
echo ">> sparkles:vulkan-wsi X11 surface verified under Xvfb."
