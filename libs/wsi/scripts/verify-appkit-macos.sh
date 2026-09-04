#!/usr/bin/env bash
# Build and run the native AppKit/Event Horizon hosted-loop smoke test.
# Run from the repository root inside the macOS dev shell:
#
#   nix develop -c libs/wsi/scripts/verify-appkit-macos.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
expected="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
expected_src="$(dirname "$expected")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> building sparkles:wsi AppKit hosted-loop smoke ..."
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
  "$repo/libs/wsi/examples/appkit-hosted-smoke.d" \
  -L-framework -LCocoa \
  -of="$work/wsi-appkit-smoke"

echo ">> running against AppKit ..."
"$work/wsi-appkit-smoke" | tee "$work/output.log"
if grep -q '^SKIP: no macOS WindowServer' "$work/output.log"; then
  echo ">> AppKit smoke skipped: no WindowServer."
  exit 0
fi
grep -q '^ok: AppKit WSI conformance (15 checked, 3 skipped)' "$work/output.log"
grep -q '^ok: AppKit marked-text round trip' "$work/output.log"
echo ">> sparkles:wsi AppKit hosted-loop smoke verified on macOS."
