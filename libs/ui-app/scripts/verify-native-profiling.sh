#!/usr/bin/env bash
# The native arm's frame profiling (docs/specs/profiling/SPEC.md, PRF19) with
# no desktop session: text-lab on headless Weston (lavapipe) and on Xvfb, each
# a scripted run under the frame switches, its summaries and trace checked.
# Run from the repository root inside the dev shell.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d /tmp/prf.XXXX)"
chmod 700 "$work"
trap 'if [ -n "${weston:-}" ]; then kill "$weston" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json}"
unset WAYLAND_DISPLAY DISPLAY

echo ">> building text-lab ..."
dub build -q --root="$repo" :text-lab
lab="$repo/apps/text-lab/build/text-lab"

XDG_RUNTIME_DIR="$work" weston --backend=headless --socket=prf --idle-time=0 \
  --log="$work/weston.log" &
weston=$!
for _ in $(seq 1 100); do [ -S "$work/prf" ] && break; sleep 0.05; done

echo ">> Wayland: frames, GPU scopes, CPU zones, counters, display times, trace ..."
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=prf timeout 120 "$lab" --window-system wayland \
  --debug "frames=120,gpu-timing,frame-counters,frame-trace=$work/wayland.json" \
  2>"$work/wayland.log" >/dev/null
grep 'native window' "$work/wayland.log"
grep -q 'native window frames: 120 frames: .*p99 .*1% low .*latency .* mean' "$work/wayland.log"
grep -q 'native window gpu: ' "$work/wayland.log"
grep -q 'native window memory: heap 0' "$work/wayland.log"
grep -q 'native window zones (ms a frame, mean/p95): .*view .*layout .*paint .*end-frame' "$work/wayland.log"
# Counters where the kernel allows them; a refusal must say why.
grep -Eq 'native window counters: (120 frames: .* instructions.*page faults|no counters \()' "$work/wayland.log"
grep -q '"cat":"gpu","ph":"X"' "$work/wayland.json"
grep -q '"name":"shown"' "$work/wayland.json"
grep -q '"name":"frame 119"' "$work/wayland.json"

echo ">> X11: a resize-stressed run ..."
XDG_RUNTIME_DIR="$work" timeout 120 xvfb-run -a "$lab" --window-system x11 \
  --debug "resize-stress,frames=120,frame-trace=$work/x11.json" 2>"$work/x11.log" >/dev/null
grep 'native window' "$work/x11.log"
grep -q 'native window frames: 120 frames: .*hitch' "$work/x11.log"
grep -q '"name":"rebuild","cat":"phase"' "$work/x11.json"
echo ">> sparkles:ui-app native frame profiling verified on Weston and Xvfb."
