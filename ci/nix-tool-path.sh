#!/usr/bin/env bash
#
# Put nixpkgs tools on PATH for the rest of the job.
#
#   ci/nix-tool-path.sh nodejs_24
#
# Resolved against *this flake's* pinned nixpkgs, so a job that needs a tool
# outside any devShell (the docs build needs Node before it can `npm ci`) gets
# the same version every run — which `actions/setup-node` and its CircleCI
# equivalents, pinned to a major only, do not guarantee.
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -gt 0 ] || ci_die 'usage: nix-tool-path.sh <nixpkgs-attr> [attr...]'

bins=()
for attr in "$@"; do
  out=$(nix --extra-experimental-features 'nix-command flakes' \
    build --no-link --print-out-paths --inputs-from . "nixpkgs#$attr" | head -n 1)
  [ -n "$out" ] || ci_die "nixpkgs#$attr produced no output path"
  printf '%s -> %s\n' "$attr" "$out"
  bins+=("$out/bin")
done

ci_export PATH "$(
  IFS=:
  printf '%s' "${bins[*]}"
):$PATH"
