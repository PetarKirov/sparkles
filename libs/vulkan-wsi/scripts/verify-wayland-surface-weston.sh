#!/usr/bin/env bash
# Prove typed Wayland handles can create a Vulkan surface and present device.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
weston_pid=""
cleanup() {
  if [ -n "$weston_pid" ]; then
    kill "$weston_pid" 2>/dev/null || true
    wait "$weston_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
chmod 700 "$work"

echo ">> building sparkles:vulkan-wsi native surface smoke ..."
(
  cd "$repo/libs/vulkan-wsi/examples"
  dub build --single native-surface-smoke.d --compiler=ldc2 --force
)

echo ">> checking the no-compositor capability gate ..."
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=vulkan-wsi-missing \
  "$repo/libs/vulkan-wsi/examples/build/vulkan_wsi_native_surface_smoke" \
  | tee "$work/skip.log"
grep -q '^SKIP: no Wayland compositor' "$work/skip.log"

echo ">> starting headless Weston ..."
XDG_RUNTIME_DIR="$work" weston --backend=headless --socket=vulkan-wsi-wayland \
  --idle-time=0 --log="$work/weston.log" &
weston_pid=$!
for _ in $(seq 1 100); do
  [ -S "$work/vulkan-wsi-wayland" ] && break
  sleep 0.02
done
test -S "$work/vulkan-wsi-wayland"

echo ">> creating a Vulkan surface against headless Weston ..."
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=vulkan-wsi-wayland \
  "$repo/libs/vulkan-wsi/examples/build/vulkan_wsi_native_surface_smoke" \
  | tee "$work/output.log"
grep -q '^ok: Wayland native handles -> Vulkan surface' "$work/output.log"
echo ">> sparkles:vulkan-wsi Wayland surface verified under Weston."
