#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while IFS= read -r pkg; do
    echo "Testing sparkles:$(basename "$pkg")"
    dub --root "$root_dir" test ":$(basename "$pkg")"
done < <(grep -o 'subPackage "[^"]*"' "$root_dir/dub.sdl" | sed 's/subPackage "\([^"]*\)"/\1/')
