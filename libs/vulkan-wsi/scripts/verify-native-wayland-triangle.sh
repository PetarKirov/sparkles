#!/usr/bin/env bash
# Build the dependency-free native Wayland triangle, exercise safe gates, and
# run the scripted presentation gate: Weston's X11 backend inside Xvfb with the
# client pinned to lavapipe. Weston's *headless* backend reports
# VK_ERROR_SURFACE_LOST_KHR for swapchain capabilities, and a hardware ICD
# exports dmabufs a software Weston cannot mmap (Weston 14 then segfaults) —
# the windowed backend plus lavapipe avoids both, so presentation verifies
# without a live desktop session. A real-compositor HITL run remains the
# fidelity gate for live resize.
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

lavapipe=/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json
if ! command -v weston >/dev/null || ! command -v xvfb-run >/dev/null \
  || [ ! -f "$lavapipe" ]; then
  echo ">> native triangle build/capability gates verified."
  echo ">> SKIP: presentation gate needs weston, xvfb-run, and lavapipe."
  exit 0
fi

echo ">> presenting against Weston (X11 backend) under Xvfb ..."
cat >"$work/present.sh" <<EOF
set -euo pipefail
rt="\$(mktemp -d /tmp/swl.XXXXXX)"
chmod 700 "\$rt"
export XDG_RUNTIME_DIR="\$rt"
weston --backend=x11 --socket=sparkles-weston-x11 --width=960 --height=600 \
  --idle-time=0 --log="$work/weston.log" &
weston_pid=\$!
trap 'kill \$weston_pid 2>/dev/null || true; \
  wait \$weston_pid 2>/dev/null || true; rm -rf "\$rt"' EXIT
for _ in \$(seq 1 150); do
  [ -S "\$rt/sparkles-weston-x11" ] && break
  sleep 0.02
done
test -S "\$rt/sparkles-weston-x11"
VK_LAYER_VALIDATE_SYNC=1 WAYLAND_DISPLAY=sparkles-weston-x11 \
  VK_DRIVER_FILES="$lavapipe" \
  "$triangle" --frames 150 --resize-stress --validation --no-color
EOF
env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1280x800x24" \
  bash "$work/present.sh" | tee "$work/present.log"
grep -q 'framesPresented: 150' "$work/present.log"
grep -q 'framesOver100ms: 0' "$work/present.log"
grep -q 'outOfDate: 0' "$work/present.log"

echo ">> native triangle presentation verified under Weston/Xvfb."
