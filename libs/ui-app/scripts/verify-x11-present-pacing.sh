#!/usr/bin/env bash
# The native arm's X11 present pacing (docs/specs/profiling/SPEC.md, PRF13)
# with no desktop session: text-lab on the Xwayland of a headless Weston,
# presenting through a GPU driver with present wait (RADV by default), a plain
# run and a resize-stressed one, each checked to draw a frame a refresh and to
# have its frames shown. Xvfb cannot serve: lavapipe has no present wait, and
# RADV cannot present to it. Run from the repository root inside the dev
# shell; `Xwayland` comes from `$PATH`, else the flake's nixpkgs.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d /tmp/xpp.XXXX)" # short: the sockets live in it
chmod 700 "$work"
trap 'if [ -n "${weston:-}" ]; then kill "$weston" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json}"
unset WAYLAND_DISPLAY DISPLAY

xwayland="$(command -v Xwayland || true)"
if [ -z "$xwayland" ]; then
  echo ">> building Xwayland ..."
  xwayland="$(nix build --inputs-from "$repo" nixpkgs#xwayland --no-link --print-out-paths)/bin/Xwayland"
fi

echo ">> building text-lab ..."
dub build -q --root="$repo" :text-lab -b checked
lab="$repo/apps/text-lab/build/text-lab"

printf '[core]\nidle-time=0\n[xwayland]\npath=%s\n' "$xwayland" >"$work/weston.ini"
XDG_RUNTIME_DIR="$work" weston --config="$work/weston.ini" --backend=headless --renderer=gl \
  --xwayland --socket=w --width=1920 --height=1080 --log="$work/weston.log" >"$work/weston.out" 2>&1 &
weston=$!
display=
for _ in $(seq 1 100); do
  display="$(sed -n 's/.*xserver listening on display \(:[0-9]*\).*/\1/p' "$work/weston.log" 2>/dev/null || true)"
  [ -n "$display" ] && break
  sleep 0.05
done
[ -n "$display" ] || { cat "$work/weston.log"; echo "no Xwayland display" >&2; exit 1; }
echo ">> Xwayland of a headless Weston on $display"

# run NAME DEBUG-SWITCHES: frames FRAMES-SHOWN FPS (frames over wall time).
run() {
  local name="$1" switches="$2" start end frames shown
  start=$(date +%s%N)
  XDG_RUNTIME_DIR="$work" DISPLAY="$display" timeout 120 "$lab" --window-system x11 \
    --debug "$switches,frame-trace=$work/$name.json" 2>"$work/$name.log" >/dev/null
  end=$(date +%s%N)
  grep 'native window frames' "$work/$name.log"
  frames=$(grep -o '"cat":"frame"' "$work/$name.json" | wc -l)
  shown=$(grep -o '"name":"shown"' "$work/$name.json" | wc -l)
  echo "$frames $shown $((frames * 1000000000 / (end - start)))"
}

check() {
  local name="$1" frames="$2" shown="$3" fps="$4" minShown="$5"
  echo ">> $name: $shown of $frames frames shown, $fps fps over the run's wall time"
  # Weston's headless output refreshes at 60 Hz; the wall time holds the
  # start-up too. Unpaced, the loop drew ~1500 fps and showed a handful.
  [ "$fps" -ge 40 ] && [ "$fps" -le 70 ] || { echo "not paced: $fps fps" >&2; exit 1; }
  [ "$shown" -ge "$minShown" ] || { echo "too few frames shown: $shown" >&2; exit 1; }
}

echo ">> X11: 300 frames, paced by present wait ..."
read -r frames shown fps < <(run plain "frames=300,gpu-timing" | tee /dev/stderr | tail -n 1)
check plain "$frames" "$shown" "$fps" 290
grep -q 'latency .* mean, .* worst' "$work/plain.log"

echo ">> X11: resize-stressed, a swapchain rebuilt every 30 frames ..."
read -r frames shown fps < <(run stress "resize-stress,frames=300" | tee /dev/stderr | tail -n 1)
# A rebuild drops the retired swapchain's outstanding present: its frame has
# no display time.
check stress "$frames" "$shown" "$fps" 280
grep -q '"name":"rebuild","cat":"phase"' "$work/stress.json"
echo ">> sparkles:ui-app X11 present pacing verified on headless Weston's Xwayland."
