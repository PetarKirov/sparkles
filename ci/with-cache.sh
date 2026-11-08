#!/usr/bin/env bash
#
# Run a command with every store path it builds pushed to Sparkles' binary
# caches: Cachix (sparkles.cachix.org) and the R2 bucket behind
# cache.sparkles.petar-kirov.dev (ci/with-r2.sh).
#
#   ci/with-cache.sh nix build --print-build-logs .#all-desktop
#
# Pushing *during* the build rather than after it means a job that fails in a
# later step, or hits its time limit, still leaves its finished paths in the
# caches — the next run does not rebuild them. On GitHub Actions the Cachix
# half overlaps with `cachix/cachix-action`'s post-job push, which pushes a
# superset; running both is idempotent.
#
# Each cache is pushed to only when its credentials are set, so the same
# invocation works on a fork PR with no secrets and on a contributor's laptop.
#
# Cachix wraps the R2 half, not the other way round: `cachix watch-exec`
# registers its post-build hook through a nix.conf of its own, and
# with-r2.sh reads that hook back and chains it after its own (NIX_CONFIG
# overrides nix.conf, so the inner wrapper's hook is the one Nix runs).
#
# Environment:
#   CACHIX_CACHE       Cachix cache name. Required to push to Cachix.
#   CACHIX_AUTH_TOKEN  Cachix write token. Required to push to Cachix.
#   R2_*, NIX_R2_*     See ci/with-r2.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci/lib/common.sh
. "$here/lib/common.sh"

cache=${CACHIX_CACHE:-}
token=${CACHIX_AUTH_TOKEN:-}

[ "$#" -gt 0 ] || ci_die 'usage: with-cache.sh <command> [args...]'

if [ -z "$cache" ] || [ -z "$token" ]; then
  printf 'Cachix not configured (CACHIX_CACHE / CACHIX_AUTH_TOKEN unset); not pushing to it.\n'
  exec "$here/with-r2.sh" "$@"
fi

export CACHIX_AUTH_TOKEN="$token"

if ci_have cachix; then
  exec cachix watch-exec "$cache" -- "$here/with-r2.sh" "$@"
fi

ci_nix_run cachix watch-exec "$cache" -- "$here/with-r2.sh" "$@"
