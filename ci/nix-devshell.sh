#!/usr/bin/env bash
#
# Build a flake devShell and export it so every later step in the job runs
# inside it.
#
# Usage:
#   ci/nix-devshell.sh [devshell-name]
#
# Environment:
#   CI_DEVSHELL     devShell name, e.g. `default` or `pre-commit`. Equivalent
#                   to the positional argument.
#   CI_USE_DIRENV   1 = take the flake ref from the repo's .envrc instead.
#                   Mutually exclusive with CI_DEVSHELL.
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

devshell=${1:-${CI_DEVSHELL:-}}
use_direnv=0
ci_is_true "${CI_USE_DIRENV:-}" && use_direnv=1

if [ -n "$devshell" ] && [ "$use_direnv" = 1 ]; then
  ci_die "CI_DEVSHELL and CI_USE_DIRENV are mutually exclusive"
fi

# --- Resolve the flake ref -------------------------------------------------

flake_ref=''
if [ -n "$devshell" ]; then
  flake_ref=".#$devshell"
elif [ "$use_direnv" = 1 ]; then
  [ -f .envrc ] || ci_die "CI_USE_DIRENV is set but .envrc does not exist"
  # Only a `use flake [ref]` .envrc can be pre-built; anything else is left to
  # direnv alone, and flake_ref stays empty.
  if grep -qE '^[[:space:]]*use[[:space:]]+flake' .envrc; then
    flake_ref=$(sed -n 's/^[[:space:]]*use[[:space:]][[:space:]]*flake[[:space:]]*//p' .envrc | head -n1)
    flake_ref=${flake_ref:-.}
  fi
else
  printf 'No devShell requested; nothing to activate.\n'
  exit 0
fi

printf "Resolved devShell flake ref: '%s'\n" "${flake_ref:-<none>}"

# --- Build it, so a build failure fails *here* -----------------------------
#
# direnv's `use flake` swallows build failures: it runs
# `eval "$(nix print-dev-env ...)"`, so a devShell that fails to build
# substitutes to the empty string, `eval ""` succeeds, and the export still
# exits 0 — leaving the job with an unmodified PATH and a failure that only
# surfaces several steps later as `<tool>: command not found`. Calling
# `print-dev-env` directly propagates the real exit code.

if [ -n "$flake_ref" ]; then
  ci_group 'Building the Nix devShell'
  nix --extra-experimental-features 'nix-command flakes' \
    print-dev-env "$flake_ref" >/dev/null
  ci_endgroup
fi

# --- Activate --------------------------------------------------------------

# The devShell's shellHook runs `export GITHUB_TOKEN="$(gh auth token)"`, which
# on a CI runner has no logged-in `gh` and so resolves to the empty string. Left
# alone that would overwrite the token the job was given — silently turning
# lychee's authenticated GitHub requests into anonymous, rate-limited ones. Snapshot
# it here and put it back after the export.
github_token_before=${GITHUB_TOKEN:-}

if [ -n "$devshell" ]; then
  # Generated, so restore whatever the repo had (a tracked .envrc, or none).
  restore_envrc() {
    if git ls-files --error-unmatch .envrc >/dev/null 2>&1; then
      git restore .envrc
    else
      rm -f .envrc
    fi
  }
  trap restore_envrc EXIT

  printf 'use flake .#%s\n' "$devshell" >.envrc
fi

ci_nix_run direnv allow .

ci_group 'Exporting the devShell environment'
env_file=$(ci_env_file)
if [ -n "$env_file" ]; then
  ci_nix_run direnv export "$(ci_env_format)" >>"$env_file"
else
  ci_nix_run direnv export "$(ci_env_format)"
fi
ci_endgroup

if [ -n "$github_token_before" ]; then
  ci_export GITHUB_TOKEN "$github_token_before"
fi
