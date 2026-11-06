#!/usr/bin/env bash
# Build and run the native AppKit/Event Horizon hosted-loop smoke test.
# Run from the repository root inside the macOS dev shell:
#
#   nix develop -c libs/wsi/scripts/verify-appkit-macos.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> building sparkles:wsi AppKit hosted-loop smoke ..."
dub build --single "$repo/libs/wsi/examples/appkit-hosted-smoke.d" -q
cp "$repo/libs/wsi/examples/build/appkit_hosted_smoke" "$work/wsi-appkit-smoke"

echo ">> running against AppKit ..."
"$work/wsi-appkit-smoke" | tee "$work/output.log"
if grep -q '^SKIP: no macOS WindowServer' "$work/output.log"; then
  echo ">> AppKit smoke skipped: no WindowServer."
  exit 0
fi
grep -q '^ok: AppKit WSI conformance (18 checked, 4 skipped)' "$work/output.log"
grep -q '^ok: AppKit marked-text round trip' "$work/output.log"
grep -q '^ok: AppKit clipboard conformance (4 checked, 32 MiB' "$work/output.log"
grep -q "^ok: AppKit reads another writer's pasteboard" "$work/output.log"
echo ">> sparkles:wsi AppKit hosted-loop smoke verified on macOS."
