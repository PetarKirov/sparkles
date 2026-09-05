#!/usr/bin/env bash
# The three generated inputs of the docs site, built concurrently:
#
#   build-wasm.sh               .#table-wasm  → docs/public/…       (~30 s)
#   build-twoslash-showcase.sh  hue gallery   → docs/public/apps/hue/twoslash
#   build-source-listings.sh    hue site      → docs/public/src
#
# They write to disjoint directories and share nothing but the nix builds of
# `.#hue` / `.#ts-grammars`, which nix serialises on its own locks — so running
# them in parallel is safe, and turns 30 s + 3m20 + 2m30 of sequential wall
# clock into the longest of the three. Any failure fails the whole step, after
# the others have finished (so a log never ends mid-way through a sibling).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$here/build-wasm.sh" & wasm=$!
bash "$here/build-twoslash-showcase.sh" & showcase=$!
bash "$here/build-source-listings.sh" & listings=$!

rc=0
wait "$wasm" || { echo "build-inputs: build-wasm.sh failed" >&2; rc=1; }
wait "$showcase" || { echo "build-inputs: build-twoslash-showcase.sh failed" >&2; rc=1; }
wait "$listings" || { echo "build-inputs: build-source-listings.sh failed" >&2; rc=1; }
exit "$rc"
