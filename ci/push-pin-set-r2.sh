#!/usr/bin/env bash
#
# Mirror the pin set's toolchain outputs (nix/pin-targets.nix, `toolchain-*`)
# into the R2 binary cache, for every pinned system, and record them as the
# `pin-set` garbage-collection root (ci/gc-root.sh).
#
#   ci/push-pin-set-r2.sh
#
# Cachix holds the pins (TC24), but it holds 10 GiB and evicts, and an entry
# that was never pinned is evicted like anything else. R2 does not evict, so
# a copy there keeps TC23's gate (the `pin-cache` job, which accepts either
# cache) satisfied. ci/with-cache.sh pushes what CI builds; the pin set is
# mostly substituted, never built, so it is pushed here.
#
# For each output R2 lacks: evaluate its outPath (which fetches a flake
# input's source), substitute it if it is not in the local store, copy it with
# its closure to R2, then delete it locally again, so mirroring the whole set
# does not fill the runner's disk. An output nothing can provide is reported
# and the gate reports it too. Paths R2 already has are skipped with one HEAD
# request, so after the first run this costs seconds.
#
# Without the R2 credentials it does nothing.
#
# Environment: see ci/lib/r2.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci/lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=ci/lib/r2.sh
. "$here/lib/r2.sh"

if ! r2_configured; then
  printf 'R2 not configured; not mirroring the pin set.\n'
  exit 0
fi

dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pin-set-r2.XXXXXX")
trap 'rm -rf "$dir"' EXIT
r2_init "$dir"

# `<system> <name> <outPath>` per toolchain entry. Evaluating a flake input's
# outPath fetches it, which is what makes a source no cache has available.
for system in x86_64-linux aarch64-darwin aarch64-linux; do
  # shellcheck disable=SC2016 # ${name} and ${drv.outPath} are Nix's.
  nix eval --raw ".#legacyPackages.$system.pinTargets" --apply '
    targets: builtins.concatStringsSep "" (builtins.attrValues (builtins.mapAttrs
      (name: drv: if builtins.substring 0 10 name == "toolchain-"
        then "'"$system"' ${name} ${drv.outPath}\n" else "") targets))'
done > "$dir/targets"

mirrored=0 present=0 failed=0
declare -A seen
: > "$dir/roots"
while read -r system name path; do
  [ -z "${seen[$path]:-}" ] || continue
  seen[$path]=1
  if r2_has "$path"; then
    present=$((present + 1))
    printf '%s\n' "$path" >> "$dir/roots"
    continue
  fi
  ci_group "R2: mirroring $name ($system) $path"
  local_copy=0
  if ! nix path-info "$path" > /dev/null 2>&1; then
    if ! nix-store --realise "$path" > /dev/null; then
      ci_endgroup
      ci_error "R2: no cache serves $name ($system) $path, and it is not a fetchable source"
      failed=$((failed + 1))
      continue
    fi
    local_copy=1
  fi
  if r2_copy "$path"; then
    mirrored=$((mirrored + 1))
    printf '%s\n' "$path" >> "$dir/roots"
  else
    ci_error "R2: could not push $name ($system) $path"
    failed=$((failed + 1))
  fi
  # Only what this script fetched; a path something else holds stays.
  [ "$local_copy" = 0 ] || nix store delete "$path" > /dev/null 2>&1 || true
  ci_endgroup
done < "$dir/targets"

printf 'R2: %d toolchain outputs already mirrored, %d mirrored now, %d failed.\n' \
  "$present" "$mirrored" "$failed"

# Every root path is in the cache already, closure included (`nix copy`
# copies closures, and a narinfo is written only after its references'), so
# the root is written directly rather than through gc-root.sh's copy.
if [ -s "$dir/roots" ]; then
  key="gc-roots/$(git rev-parse 'HEAD^{tree}')/pin-set"
  if r2_put "$key" "$dir/roots"; then
    printf 'R2: recorded %s (%s paths).\n' "$key" "$(wc -l < "$dir/roots" | tr -d ' ')"
  else
    ci_notice "R2: could not write $key"
  fi
fi
