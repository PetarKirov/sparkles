#!/usr/bin/env bash
# The native macOS Vulkan path on a real window: the shared surface
# conformance probe (NSWindow -> CAMetalLayer -> VK_EXT_metal_surface ->
# present device on MoltenVK), then the AppKit triangle presenting 300 frames
# through a resize stress. Needs a WindowServer session; `caffeinate` keeps
# the display awake, since a locked or sleeping display still presents but
# shows nothing. Run from the repository root inside the macOS dev shell:
#
#   nix develop -c libs/vulkan-wsi/scripts/verify-appkit-vulkan-macos.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$repo/libs/vulkan-wsi/examples"

echo ">> AppKit native-surface conformance on MoltenVK ..."
caffeinate -dimsu dub run --single native-appkit-surface-smoke.d -q | tee "$work/surface.log"
grep -q '^ok: AppKit native handles -> CAMetalLayer -> Vulkan surface -> present device' "$work/surface.log"

echo ">> AppKit triangle: 300 frames with resize stress ..."
dub build --single native-appkit-triangle.d -q
caffeinate -dimsu ./build/native_appkit_triangle --frames 300 --resize-stress --no-color 2>&1 \
  | tee "$work/triangle.log"
grep -q 'framesPresented: 300,' "$work/triangle.log"
grep -q 'outOfDate: 0,' "$work/triangle.log"
if grep -q 'Cereal serialization' "$work/triangle.log"; then
  echo "MoltenVK was built against a SPIRV-Cross it does not pin" >&2
  exit 1
fi
echo ">> native macOS Vulkan path verified."
