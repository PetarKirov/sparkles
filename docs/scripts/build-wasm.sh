#!/usr/bin/env bash
# Build the drawTable playground wasm module and copy it into docs/public/ so the
# interactive playground (docs/libs/core-cli/table.md) can fetch it at runtime.
#
# The module is the REAL `sparkles.core_cli.ui.table` (drawTable) plus a
# grapheme-segmentation oracle, compiled to wasm32-wasip1 by
# nix/packages/table-wasm.nix (dlang.nix's ldc-wasm toolchain, full Phobos + GC).
#
# This is a reproducible build artifact, NOT committed to git (see .gitignore).
# It is rebuilt automatically before `docs:dev` / `docs:build` (see package.json);
# regenerate it by hand with `nix build .#table-wasm`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$repo_root/docs/public/spk-table.wasm"

if ! command -v nix >/dev/null 2>&1; then
    if [ -f "$out" ]; then
        echo "build-wasm: nix not found on PATH; reusing existing $out" >&2
        exit 0
    fi
    echo "build-wasm: nix not found on PATH and $out is missing." >&2
    echo "build-wasm: install Nix, or run 'nix build .#table-wasm' elsewhere and" >&2
    echo "build-wasm: copy its spk-table.wasm to $out." >&2
    exit 1
fi

echo "build-wasm: building .#table-wasm (uses the ldc-wasm toolchain) ..." >&2
store="$(nix build "$repo_root#table-wasm" --no-link --print-out-paths)"
install -Dm644 "$store/spk-table.wasm" "$out"
echo "build-wasm: wrote $out ($(wc -c < "$out") bytes)" >&2
