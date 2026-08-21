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
  -I"$repo/libs/event-horizon/src" \
  -I"$repo/libs/input/src" \
  -I"$repo/libs/math/src" \
  -I"$repo/libs/base/src" \
  -I"$repo/libs/test-runner/src" \
  -I"$expected_src" \
  -I"$during_src" \
  "$repo/libs/wsi/examples/x11-hosted-smoke.d" \
  "$repo/libs/wsi/src/xcb_native.c" \
  -L-lxcb -L-lxcb-xkb -L-lxcb-xtest \
  -of="$work/wsi-x11-smoke"

echo ">> running under Xvfb ..."
xvfb-run -a "$work/wsi-x11-smoke" | tee "$work/output.log"
grep -q '^ok: XCB window + keys + Event Horizon timer/waker' "$work/output.log"
echo ">> sparkles:wsi X11 foreign-fd smoke verified under Xvfb."
