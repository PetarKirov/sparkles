#!/usr/bin/env bash
# The native arm's frames sent to Tracy (docs/specs/profiling/SPEC.md, PRF20)
# with no desktop session: text-lab built with `-c tracy`, a scripted run on
# headless Weston (lavapipe) captured by `tracy-capture`, its zones exported
# by `tracy-csvexport` and checked. Never starts the `tracy` GUI.
# Run from the repository root inside the dev shell.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
: "${SPARKLES_TRACY_PREFIX:?is unset: enter the dev shell}"
work="$(mktemp -d /tmp/tracy.XXXX)"
chmod 700 "$work"
# A process not running (or not yet started) is skipped: `kill 0` would end the group.
stop() { for pid in "$@"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done; true; }
trap 'stop "${weston:-}" "${capture:-}"; rm -rf "$work"' EXIT
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json}"
unset WAYLAND_DISPLAY DISPLAY
# Off Tracy's default port, so an instrumented program already running is
# not the one captured.
export TRACY_PORT="${TRACY_PORT:-18086}"

echo ">> building text-lab with Tracy ..."
dub build -q --root="$repo" :text-lab -c tracy
lab="$repo/apps/text-lab/build/text-lab"

XDG_RUNTIME_DIR="$work" weston --backend=headless --socket=tracy --idle-time=0 \
  --log="$work/weston.log" &
weston=$!
for _ in $(seq 1 100); do [ -S "$work/tracy" ] && break; sleep 0.05; done

# The capture retries until the client listens, and ends when it leaves.
tracy-capture -o "$work/run.tracy" -a 127.0.0.1 -p "$TRACY_PORT" -f -s 120 \
  >"$work/capture.log" 2>&1 &
capture=$!

echo ">> Wayland: 120 frames, GPU timing on, captured ..."
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=tracy timeout 120 "$lab" --window-system wayland \
  --debug frames=120,gpu-timing 2>"$work/lab.log" >/dev/null
grep -q 'native window frames: 120 frames' "$work/lab.log"
wait "$capture"
capture=
# Tracy counts the stretch before the first mark and after the last as
# frames too: one mark reads `Frames: 3`.
tr '\r' '\n' <"$work/capture.log" | grep -a -E '^(Frames|Time span|Zones):' \
  | tee "$work/frames.txt"
grep -q '^Frames: 122$' "$work/frames.txt"

tracy-csvexport "$work/run.tracy" >"$work/zones.csv"
cat "$work/zones.csv"
# name,src_file,src_line,total_ns,total_perc,counts,mean_ns,min_ns,max_ns,std_ns
grep -q '^frame,[^,]*native_loop.d,[0-9]*,[0-9]*,[0-9.]*,120,' "$work/zones.csv"
for zone in build wait acquire record present; do
  grep -q "^$zone,[^,]*native_loop.d,[0-9]*,[0-9]*,[0-9.]*,1[2-9][0-9]," "$work/zones.csv" \
    || { echo "zone $zone: not in 120 or more frames" >&2; exit 1; }
done
# The plots: a point per presented frame, and per frame the device timed.
tracy-csvexport -u -p "$work/run.tracy" >"$work/events.csv"
frameMs="$(grep -c '^frame ms,' "$work/events.csv" || true)"
gpuMs="$(grep -c '^gpu ms,' "$work/events.csv" || true)"
echo "plot points: frame ms $frameMs, gpu ms $gpuMs"
[ "$frameMs" -eq 120 ] && [ "$gpuMs" -gt 0 ]
echo ">> sparkles:ui-app native frames verified in Tracy on Weston."
