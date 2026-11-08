#!/usr/bin/env bash
#
# Mirror the pin set's toolchain outputs (nix/pin-targets.nix, `toolchain-*`)
# into the R2 binary cache, for every pinned system.
#
#   ci/push-pin-set-r2.sh
#
# Cachix holds the pins (TC24), but it holds 10 GiB and evicts, and an entry
# that was never pinned is evicted like anything else. R2 does not evict, so
# a copy there keeps TC23's gate (the `pin-cache` job, which accepts either
# cache) satisfied. ci/with-r2.sh pushes what CI builds; the pin set is
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
# Environment: as ci/with-r2.sh (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY,
# R2_ACCOUNT_ID, NIX_R2_SIGNING_KEY, R2_BUCKET), plus R2_CACHE_URL (default:
# https://cache.sparkles.petar-kirov.dev) for the existence check.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci/lib/common.sh
. "$here/lib/common.sh"

key_id=${R2_ACCESS_KEY_ID:-}
secret=${R2_SECRET_ACCESS_KEY:-}
account=${R2_ACCOUNT_ID:-}
signing=${NIX_R2_SIGNING_KEY:-}
bucket=${R2_BUCKET:-sparkles-nix-cache}
cache_url=${R2_CACHE_URL:-https://cache.sparkles.petar-kirov.dev}

if [ -z "$key_id" ] || [ -z "$secret" ] || [ -z "$account" ] || [ -z "$signing" ]; then
  printf 'R2 not configured; not mirroring the pin set.\n'
  exit 0
fi

dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pin-set-r2.XXXXXX")
trap 'rm -rf "$dir"' EXIT
(umask 077 && printf '%s\n' "$signing" > "$dir/signing.key")
store="s3://$bucket?endpoint=https://$account.r2.cloudflarestorage.com&region=auto&compression=zstd&secret-key=$dir/signing.key"

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
while read -r system name path; do
  [ -z "${seen[$path]:-}" ] || continue
  seen[$path]=1
  hash=$(basename "$path" | cut -c1-32)
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$cache_url/$hash.narinfo")" = 200 ]; then
    present=$((present + 1))
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
  if AWS_ACCESS_KEY_ID="$key_id" AWS_SECRET_ACCESS_KEY="$secret" nix copy --to "$store" "$path"; then
    mirrored=$((mirrored + 1))
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
