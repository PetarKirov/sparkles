#!/usr/bin/env bash
#
# Record store paths as a garbage-collection root of the R2 binary cache, and
# make sure the cache holds their whole closures.
#
#   ci/gc-root.sh <label> [<store path>...]
#
# With no paths, the `./result*` symlinks `nix build` left are the roots.
#
# A root is the object `gc-roots/<tree>/<label>-<system>`, one store path
# per line. It is keyed by the git *tree* of the checkout, not the commit: the
# bucket's garbage collection (`ci --gc-r2`) keeps the roots of the trees of
# the last commits on `main`, so a pull request's roots become `main`'s the
# moment it lands with its tree unchanged — exactly when `main-checks.yml`
# mirrors its checks rather than rebuilding. The label and system keep jobs
# from overwriting each other.
#
# The closure is copied before the root is written, so a root only names
# paths the cache can serve: ci/with-cache.sh pushes what the job built, and
# this adds what it substituted from elsewhere (Cachix, which may evict it).
# cache.nixos.org paths are copied too: a binary cache refuses a path whose
# references it lacks. ci/with-cache.sh already copied most of it, and `nix copy`
# skips what the bucket has, so this usually costs a query per path.
#
# Without the R2 credentials it does nothing. A failure is reported, never
# fatal: a missing root only makes paths collectable sooner.
#
# Environment: see ci/lib/r2.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci/lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=ci/lib/r2.sh
. "$here/lib/r2.sh"

[ "$#" -gt 0 ] || ci_die 'usage: gc-root.sh <label> [<store path>...]'
label=$1
shift

if ! r2_configured; then
  printf 'R2 not configured; not recording the %s root.\n' "$label"
  exit 0
fi

dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gc-root.XXXXXX")
trap 'rm -rf "$dir"' EXIT
r2_init "$dir"

if [ "$#" -gt 0 ]; then
  printf '%s\n' "$@" > "$dir/paths"
else
  for link in result result-*; do
    [ -L "$link" ] && readlink -f "$link"
  done > "$dir/paths" || true
fi
sort -u -o "$dir/paths" "$dir/paths"
count=$(wc -l < "$dir/paths" | tr -d ' ')
[ "$count" -gt 0 ] || { ci_notice "R2: no store paths for the $label root"; exit 0; }

tree=$(git rev-parse 'HEAD^{tree}')
system=$(nix eval --impure --raw --expr builtins.currentSystem)
key="gc-roots/$tree/$label-$system"

ci_group "R2: copying the closure of the $label root ($count paths)"
copied=0
r2_copy --stdin < "$dir/paths" && copied=1
ci_endgroup
if [ "$copied" = 0 ]; then
  ci_notice "R2: could not copy the $label root's closure; not recording it"
  exit 0
fi

if r2_put "$key" "$dir/paths"; then
  printf 'R2: recorded %s (%s paths).\n' "$key" "$count"
else
  ci_notice "R2: could not write $key"
fi
