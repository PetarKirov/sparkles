#!/usr/bin/env bash
# Build and run the native Wayland/Event Horizon smoke under headless Weston.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
expected="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
expected_src="$(dirname "$expected")"
during="$(find "$HOME/.dub/packages/during" -path '*/source/during/package.d' | sort -V | tail -1)"
during_src="$(dirname "$(dirname "$during")")"
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

echo ">> building sparkles:wsi Wayland prepare-read smoke ..."
ldc2 -preview=in -preview=dip1000 -g -i \
  -I"$repo/libs/wsi/src" \
  -I"$repo/libs/event-horizon/src" \
  -I"$repo/libs/input/src" \
  -I"$repo/libs/metadata/src" \
  -I"$repo/libs/reflection/src" \
  -I"$repo/libs/math/src" \
  -I"$repo/libs/base/src" \
  -I"$repo/libs/test-runner/src" \
  -I"$expected_src" \
  -I"$during_src" \
  "$repo/libs/wsi/examples/wayland-hosted-smoke.d" \
  "$repo/libs/wsi/src/wayland_native.c" \
  -L-lwayland-client -L-lxkbcommon \
  -of="$work/wsi-wayland-smoke"

echo ">> checking the no-compositor capability gate ..."
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=wsi-missing \
  "$work/wsi-wayland-smoke" | tee "$work/skip.log"
grep -q '^SKIP: no Wayland compositor' "$work/skip.log"

echo ">> starting headless Weston ..."
XDG_RUNTIME_DIR="$work" weston --backend=headless --socket=wsi-wayland \
  --idle-time=0 --log="$work/weston.log" &
weston_pid=$!
for _ in $(seq 1 100); do
  [ -S "$work/wsi-wayland" ] && break
  sleep 0.02
done
test -S "$work/wsi-wayland"

echo ">> running against headless Weston ..."
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=wsi-wayland \
  "$work/wsi-wayland-smoke" | tee "$work/output.log"
grep -q '^ok: Wayland WSI conformance (9 checked, 9 skipped)' "$work/output.log"
echo ">> sparkles:wsi Wayland prepare-read smoke verified under Weston."
