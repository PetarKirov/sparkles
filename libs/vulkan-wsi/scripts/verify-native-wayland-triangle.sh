#!/usr/bin/env bash
# Build the dependency-free native Wayland triangle and exercise safe gates.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

echo ">> building the native Wayland Vulkan triangle ..."
(
  cd "$repo/libs/vulkan-wsi/examples"
  dub build --single native-wayland-triangle.d --compiler=ldc2 --force
)

triangle="$repo/libs/vulkan-wsi/examples/build/native_wayland_triangle"

echo ">> checking --help and the no-compositor capability gate ..."
"$triangle" --help >"$work/help.log"
grep -q 'No SDL or libdecor is loaded' "$work/help.log"
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=vulkan-wsi-missing \
  "$triangle" --frames 1 | tee "$work/skip.log"
grep -q '^SKIP: no Wayland compositor' "$work/skip.log"

echo ">> native triangle build/capability gates verified."
echo ">> A real compositor run is the presentation gate; headless Weston"
echo ">> currently reports VK_ERROR_SURFACE_LOST_KHR for swapchain capabilities."
