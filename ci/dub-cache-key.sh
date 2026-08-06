#!/usr/bin/env bash
#
# Write a digest of every dub manifest in the tree, for use as a cache key.
#
#   ci/dub-cache-key.sh [output-path]     # default: .dub-cache-key
#
# GitHub Actions spells this `hashFiles('**/dub.sdl', '**/dub.selections.json')`
# inline in the cache key. CircleCI's `{{ checksum "..." }}` takes one literal
# path and does not glob, and this repo has no root `dub.selections.json` — the
# 85 manifests all live in sub-packages — so the digest has to be materialised
# into a file before `restore_cache`/`save_cache` can key on it.
#
# Both the paths and the contents go into the digest, so adding, removing, or
# renaming a sub-package busts the cache as surely as editing one does.
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

out=${1:-.dub-cache-key}

# GNU coreutils ships sha256sum; the macOS executor has BSD userland and
# ships shasum instead. A command array, not a function — xargs execs a real
# binary and cannot see shell functions.
if ci_have sha256sum; then
  digest=(sha256sum)
elif ci_have shasum; then
  digest=(shasum -a 256)
else
  ci_die 'no sha256sum or shasum available'
fi

# `git ls-files` rather than `find`, so untracked scratch files and anything
# under .gitignore cannot perturb the key. LC_ALL=C for a stable sort order
# across the Linux and macOS runners.
git ls-files '*dub.sdl' '*dub.selections.json' \
  | LC_ALL=C sort \
  | xargs "${digest[@]}" \
  | "${digest[@]}" >"$out"

printf 'dub cache key (%s files): %s\n' \
  "$(git ls-files '*dub.sdl' '*dub.selections.json' | wc -l | tr -d ' ')" \
  "$(cut -c1-16 <"$out")"
