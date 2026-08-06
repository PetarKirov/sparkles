#!/usr/bin/env bash
#
# Run a command with every store path it produces pushed to Cachix.
#
#   ci/with-cachix.sh nix build --print-build-logs .#all-desktop
#
# Pushing *during* the build rather than after it means a job that fails in a
# later step still leaves its successfully built paths in the cache — the next
# run does not rebuild them. On GitHub Actions this overlaps with
# `cachix/cachix-action`'s post-job push, which pushes a superset; running both
# is idempotent.
#
# With no cache configured the command runs unwrapped, so the same invocation
# works on a fork PR with no secrets and on a contributor's laptop.
#
# Environment:
#   CACHIX_CACHE       Cache name. Required to push.
#   CACHIX_AUTH_TOKEN  Write token. Required to push.
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

cache=${CACHIX_CACHE:-}
token=${CACHIX_AUTH_TOKEN:-}

[ "$#" -gt 0 ] || ci_die 'usage: with-cachix.sh <command> [args...]'

if [ -z "$cache" ] || [ -z "$token" ]; then
  printf 'Cachix not configured (CACHIX_CACHE / CACHIX_AUTH_TOKEN unset); running unwrapped.\n'
  exec "$@"
fi

export CACHIX_AUTH_TOKEN="$token"

if ci_have cachix; then
  exec cachix watch-exec "$cache" -- "$@"
fi

ci_nix_run cachix watch-exec "$cache" -- "$@"
