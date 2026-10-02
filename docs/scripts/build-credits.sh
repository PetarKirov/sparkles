#!/usr/bin/env bash
# Stage the credits document's licence texts into docs/credits/licenses/ so
# the include directives in docs/credits/parts/*.md resolve
# (docs/specs/terminal/pages.md TPG13).
#
# The texts come from each component's own source, through the same
# derivation the APKs bundle (`.#credits`, nix/packages/credits.nix), so the
# site and the apps cannot disagree (TPG16). They are NOT committed (see
# .gitignore); this runs before `docs:dev` / `docs:build` (see package.json).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$repo_root/docs/credits/licenses"

if ! command -v nix >/dev/null 2>&1; then
    if [ -d "$out" ]; then
        echo "build-credits: nix not found on PATH; reusing existing $out" >&2
        exit 0
    fi
    echo "build-credits: nix not found on PATH and $out is missing." >&2
    echo "build-credits: install Nix, or copy the licenses/ directory of" >&2
    echo "build-credits: 'nix build .#credits' to $out." >&2
    exit 1
fi

echo "build-credits: building .#credits ..." >&2
store="$(nix build "$repo_root#credits" --no-link --print-out-paths)"
rm -rf "$out"
cp -r "$store/licenses" "$out"
chmod -R u+w "$out"
echo "build-credits: staged $(find "$out" -type f | wc -l) licence files in $out" >&2
