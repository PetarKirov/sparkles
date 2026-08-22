#!/usr/bin/env bash
# Full-stack Wayland keyboard evidence with no desktop session: Weston's X11
# backend runs inside Xvfb, an XTEST injector chords left-shift + a into the
# X server (PointerRoot focus routes it to Weston's window), and Weston
# forwards it to the focused Wayland client as real wl_keyboard events.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
expected="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
expected_src="$(dirname "$expected")"
during="$(find "$HOME/.dub/packages/during" -path '*/source/during/package.d' | sort -V | tail -1)"
during_src="$(dirname "$(dirname "$during")")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

echo ">> building sparkles:wsi Wayland keys smoke ..."
ldc2 -preview=in -preview=dip1000 -g -i \
  -I"$repo/libs/wsi/src" \
  -I"$repo/libs/wsi/examples" \
  -I"$repo/libs/event-horizon/src" \
  -I"$repo/libs/input/src" \
  -I"$repo/libs/math/src" \
  -I"$repo/libs/base/src" \
  -I"$repo/libs/test-runner/src" \
  -I"$expected_src" \
  -I"$during_src" \
  "$repo/libs/wsi/examples/wayland-hosted-smoke.d" \
  "$repo/libs/wsi/src/wayland_native.c" \
  -L-lwayland-client -L-lxkbcommon \
  -of="$work/wsi-wayland-keys-smoke"

echo ">> building the XTEST key injector ..."
ldc2 -preview=in -preview=dip1000 -g -i \
  -I"$repo/libs/wsi/src" \
  -I"$repo/libs/wsi/examples" \
  "$repo/libs/wsi/examples/x11-key-injector.d" \
  "$repo/libs/wsi/src/xcb_native.c" \
  -L-lxcb -L-lxcb-xkb -L-lxcb-xtest -L-lxkbcommon -L-lxkbcommon-x11 \
  -of="$work/x11-key-injector"

cat >"$work/lane.sh" <<EOF
set -euo pipefail
rt="\$(mktemp -d /tmp/swl.XXXXXX)"
chmod 700 "\$rt"
export XDG_RUNTIME_DIR="\$rt"
weston --backend=x11 --shell=kiosk-shell.so --socket=wsi-keys \
  --width=960 --height=600 --scale=2 \
  --idle-time=0 --log="$work/weston.log" &
weston_pid=\$!
smoke_pid=""
cleanup() {
  [ -n "\$smoke_pid" ] && kill "\$smoke_pid" 2>/dev/null || true
  kill "\$weston_pid" 2>/dev/null || true
  wait "\$weston_pid" 2>/dev/null || true
  rm -rf "\$rt"
}
trap cleanup EXIT
for _ in \$(seq 1 150); do
  [ -S "\$rt/wsi-keys" ] && break
  sleep 0.02
done
test -S "\$rt/wsi-keys"

WSI_POINTER_GO="\$rt/pointer-go" WSI_HOLD_GO="\$rt/hold-go" \\
  WSI_HOLD_RELEASE_GO="\$rt/hold-release-go" WSI_CONFORMANCE_KEYS=1 \\
  WSI_CONFORMANCE_KIOSK=1 WSI_EXPECT_SCALE=2 WAYLAND_DISPLAY=wsi-keys \\
  "$work/wsi-wayland-keys-smoke" \
  >"$work/smoke.log" 2>&1 &
smoke_pid=\$!

# Re-inject until the smoke observes a full chord; duplicates are ignored.
for _ in \$(seq 1 60); do
  if ! kill -0 "\$smoke_pid" 2>/dev/null; then
    break
  fi
  WSI_POINTER_GO="\$rt/pointer-go" WSI_HOLD_GO="\$rt/hold-go" \\
    WSI_HOLD_RELEASE_GO="\$rt/hold-release-go" \\
    "$work/x11-key-injector" || true
  sleep 0.3
done
wait "\$smoke_pid"
smoke_pid=""
EOF
echo ">> chording through Xvfb -> Weston -> wl_keyboard ..."
lane_status=0
env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1280x800x24" \
  bash "$work/lane.sh" || lane_status=$?
cat "$work/smoke.log" 2>/dev/null || true
test "$lane_status" -eq 0
grep -q '^ok: Wayland WSI conformance (13 checked, 5 skipped)' "$work/smoke.log"
echo ">> sparkles:wsi Wayland keyboard verified through Weston."
