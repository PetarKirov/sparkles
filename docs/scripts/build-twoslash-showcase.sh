#!/usr/bin/env bash
# Render the sparkles:twoslash example gallery into docs/public/ so the docs site
# can showcase the real `hue --twoslash --html` output (see docs/apps/hue/).
#
# This drives the SAME dev previewer as `libs/twoslash/examples/render-html.mjs`
# (npm run render), pointed at the nix-built hue and the committed fixtures, with
# the grammar bundle wired up for full-fidelity highlighting + markdown docs. The
# output is a set of self-contained static HTML pages (inline CSS, no deps).
#
# Reproducible build artifact, NOT committed to git (see .gitignore). Rebuilt
# automatically before `docs:dev` / `docs:build` (see package.json); regenerate by
# hand with this script (needs Nix + Node on PATH).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out_rel="docs/public/apps/hue/twoslash"
out="$repo_root/$out_rel"

if ! command -v nix >/dev/null 2>&1; then
    if [ -f "$out/index.html" ]; then
        echo "build-twoslash-showcase: nix not found; reusing existing $out_rel" >&2
        exit 0
    fi
    echo "build-twoslash-showcase: nix not found on PATH and $out_rel is missing." >&2
    echo "build-twoslash-showcase: install Nix, or run this script elsewhere and" >&2
    echo "build-twoslash-showcase: copy its output into $out_rel." >&2
    exit 1
fi

echo "build-twoslash-showcase: building .#hue and .#ts-grammars ..." >&2
hue="$(nix build "$repo_root#hue" --no-link --print-out-paths)/bin/hue"
SPARKLES_TS_GRAMMAR_PATH="$(nix build "$repo_root#ts-grammars" --no-link --print-out-paths)"
export SPARKLES_TS_GRAMMAR_PATH

# Clean stale pages (a fixture may have been removed) then render fresh.
rm -rf "$out"
HUE_BIN="$hue" OUT_DIR="$out_rel" node "$repo_root/libs/twoslash/examples/render-html.mjs" >&2
echo "build-twoslash-showcase: wrote $(find "$out" -name '*.html' | wc -l) pages to $out_rel" >&2
