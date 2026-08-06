#!/usr/bin/env bash
#
# Push the release closure to Cachix and pin it, so it survives garbage
# collection.
#
# Cachix has no unpin command (the public API only creates pins), so retention
# works by re-pinning: each release adds a revision to the same
# `latest-<system>` pin and --keep-revisions drops the oldest, whose closure
# becomes collectable.
#
# Expects ./result to be the `nix build` output to pin.
#
# Environment:
#   CACHIX_CACHE       Cache name. Required.
#   CACHIX_AUTH_TOKEN  Write token. Required.
#   CI_TAG             The tag being released. Defaults to the provider's ref
#                      variable ($GITHUB_REF_NAME / $CIRCLE_TAG).
#   CI_SYSTEM          Nix system double for the pin name. Defaults to the
#                      host's `builtins.currentSystem`.
#   CI_PIN_REVISIONS   Revisions to keep (default 3).
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

cache=${CACHIX_CACHE:-}
token=${CACHIX_AUTH_TOKEN:-}
tag=${CI_TAG:-${GITHUB_REF_NAME:-${CIRCLE_TAG:-}}}
revisions=${CI_PIN_REVISIONS:-3}

[ -n "$cache" ] || ci_die 'CACHIX_CACHE is required'
[ -n "$token" ] || ci_die 'CACHIX_AUTH_TOKEN is required'
[ -n "$tag" ] || ci_die 'no tag: set CI_TAG (or run from a tag ref)'
[ -e ./result ] || ci_die './result does not exist — run the nix build first'

system=${CI_SYSTEM:-$(nix --extra-experimental-features 'nix-command flakes' \
  eval --impure --raw --expr 'builtins.currentSystem')}

export CACHIX_AUTH_TOKEN="$token"

# `release --split` publishes a chain of releases whose runs race, and an old
# release can be re-published by hand. Only the highest tag may move the
# `latest-*` pin. (Plain `vX.Y.Z` tags version-sort correctly.)
latest=$(git tag --list 'v*' --sort=-v:refname | head -n1)
if [ "$tag" != "$latest" ]; then
  ci_notice "$tag is not the highest tag ($latest); not moving the pin"
  exit 0
fi

# The pin needs the path to be in the cache *now* — a post-job push hook runs
# too late.
out=$(readlink -f ./result)

cachix() {
  if ci_have cachix; then
    command cachix "$@"
  else
    ci_nix_run cachix "$@"
  fi
}

cachix push "$cache" "$out"
cachix pin "$cache" "latest-$system" "$out" --keep-revisions "$revisions"

printf 'Pinned %s as latest-%s (keeping %s revisions)\n' "$out" "$system" "$revisions"
