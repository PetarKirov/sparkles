#!/usr/bin/env bash
# Build and run the native XCB/Event Horizon foreign-fd smoke under Xvfb.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
expected="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
expected_src="$(dirname "$expected")"
during="$(find "$HOME/.dub/packages/during" -path '*/source/during/package.d' | sort -V | tail -1)"
during_src="$(dirname "$(dirname "$during")")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> building sparkles:wsi X11 foreign-fd smoke ..."
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
  "$repo/libs/wsi/examples/x11-hosted-smoke.d" \
  "$repo/libs/wsi/src/xcb_native.c" \
  -L-lxcb -L-lxcb-xkb -L-lxcb-xtest -L-lxcb-imdkit \
  -L-lxkbcommon -L-lxkbcommon-x11 \
  -of="$work/wsi-x11-smoke"

echo ">> building the test XIM server ..."
ldc2 -preview=in -preview=dip1000 -g -i \
  -I"$repo/libs/wsi/src" \
  -I"$repo/libs/wsi/examples" \
  "$repo/libs/wsi/examples/xim-test-server.d" \
  "$repo/libs/wsi/src/xcb_native.c" \
  -L-lxcb -L-lxcb-xkb -L-lxcb-xtest -L-lxcb-imdkit \
  -L-lxkbcommon -L-lxkbcommon-x11 \
  -of="$work/xim-test-server"

cat >"$work/lane.sh" <<EOF
set -euo pipefail
"$work/xim-test-server" >"$work/xim-server.log" 2>&1 &
server_pid=\$!
trap 'kill "\$server_pid" 2>/dev/null || true' EXIT
for _ in \$(seq 1 100); do
  grep -q 'ready' "$work/xim-server.log" 2>/dev/null && break
  sleep 0.05
done
grep -q 'ready' "$work/xim-server.log"
XMODIFIERS=@im=test WSI_XIM_LANE=1 "$work/wsi-x11-smoke"
EOF

echo ">> running under Xvfb with the test XIM server ..."
xvfb-run -a -s "-screen 0 1024x768x24" bash "$work/lane.sh" \
  | tee "$work/output.log"
grep -q '^ok: X11 WSI conformance (16 checked, 2 skipped)' "$work/output.log"
echo ">> sparkles:wsi X11 foreign-fd smoke verified under Xvfb."
