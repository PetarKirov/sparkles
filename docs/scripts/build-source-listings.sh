#!/usr/bin/env bash
# Render the repository's source-code listings (+ manifest.json) into
# docs/public/src with `hue site` — link-driven discovery over the docs'
# markdown, mirrored pages, twoslash overlays for .d sources, and the
# manifest the VitePress link rewriting consumes
# (docs/specs/docs/discovery.md, DSC1-DSC4).
#
# Reproducible build artifact, NOT committed to git (see .gitignore). Rebuilt
# automatically before `docs:dev` / `docs:build` (see package.json); regenerate
# by hand with this script (needs Nix on PATH).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out_rel="docs/public/src"
out="$repo_root/$out_rel"

if ! command -v nix >/dev/null 2>&1; then
    if [ -f "$out/manifest.json" ]; then
        echo "build-source-listings: nix not found; reusing existing $out_rel" >&2
        exit 0
    fi
    echo "build-source-listings: nix not found on PATH and $out_rel is missing;" >&2
    echo "build-source-listings: continuing WITHOUT source listings (links stay plain)." >&2
    exit 0
fi

echo "build-source-listings: building .#hue, .#twoslash-extract and .#ts-grammars ..." >&2
hue="$(nix build "$repo_root#hue" --no-link --print-out-paths)/bin/hue"
SPARKLES_TWOSLASH_EXTRACT="$(nix build "$repo_root#twoslash-extract" --no-link --print-out-paths)/bin/twoslash-extract"
SPARKLES_TS_GRAMMAR_PATH="$(nix build "$repo_root#ts-grammars" --no-link --print-out-paths)"
export SPARKLES_TWOSLASH_EXTRACT SPARKLES_TS_GRAMMAR_PATH

# Clean stale pages (a source file may have been removed) then render fresh.
rm -rf "$out"
"$hue" --theme catppuccin-latte site \
    --dark-theme catppuccin-mocha \
    --repo-root "$repo_root" \
    --repo-url "https://github.com/PetarKirov/sparkles/blob/main" \
    --out "$out" >&2
echo "build-source-listings: wrote $(find "$out" -name '*.html' | wc -l) pages to $out_rel" >&2
