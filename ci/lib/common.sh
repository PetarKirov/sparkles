# shellcheck shell=bash
#
# Provider-neutral helpers shared by the GitHub Actions and CircleCI configs.
#
# Source this; do not execute it:
#
#     . "$(dirname "$0")/lib/common.sh"
#
# Callers own `set -euo pipefail` — a sourced file that sets shell options
# changes the behaviour of whatever sourced it, which is a poor contract for a
# library.

# ---------------------------------------------------------------------------
# Provider detection
# ---------------------------------------------------------------------------

# `github`, `circleci`, or `local`. Every provider-specific branch in this
# directory goes through here rather than testing an ad-hoc variable, so adding
# a third provider is one case arm per behaviour rather than a grep.
ci_provider() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf 'github\n'
  elif [ -n "${CIRCLECI:-}" ]; then
    printf 'circleci\n'
  else
    printf 'local\n'
  fi
}

# ---------------------------------------------------------------------------
# Log annotations
#
# GitHub Actions folds `::group::`/`::endgroup::` in the web log and renders
# `::error::`/`::notice::` as annotations. CircleCI has no equivalent markup —
# it folds on the step boundary instead — so these degrade to plain lines.
# ---------------------------------------------------------------------------

ci_group() {
  case "$(ci_provider)" in
    github) printf '::group::%s\n' "$*" ;;
    *) printf -- '----- %s -----\n' "$*" ;;
  esac
}

ci_endgroup() {
  case "$(ci_provider)" in
    github) printf '::endgroup::\n' ;;
    *) : ;;
  esac
}

ci_notice() {
  case "$(ci_provider)" in
    github) printf '::notice::%s\n' "$*" ;;
    *) printf 'NOTICE: %s\n' "$*" ;;
  esac
}

ci_error() {
  case "$(ci_provider)" in
    github) printf '::error::%s\n' "$*" >&2 ;;
    *) printf 'ERROR: %s\n' "$*" >&2 ;;
  esac
}

ci_die() {
  ci_error "$@"
  exit 1
}

# ---------------------------------------------------------------------------
# Cross-step environment
#
# Both providers hand a job's steps to separate shells, so an `export` in one
# step is invisible in the next. Each offers a file that bridges the gap, but
# in a *different format*: GitHub Actions parses $GITHUB_ENV as KEY=VALUE
# pairs, while CircleCI sources $BASH_ENV as a shell script. `ci_export` hides
# that difference; `ci_env_format` exposes it for the one caller that needs it
# (`direnv export` can emit either shape natively).
# ---------------------------------------------------------------------------

ci_env_file() {
  case "$(ci_provider)" in
    github) printf '%s\n' "${GITHUB_ENV:-}" ;;
    circleci) printf '%s\n' "${BASH_ENV:-}" ;;
    *) printf '%s\n' "${CI_ENV_FILE:-}" ;;
  esac
}

# The `direnv export <format>` argument matching this provider's env file.
ci_env_format() {
  case "$(ci_provider)" in
    github) printf 'gha\n' ;;
    *) printf 'bash\n' ;;
  esac
}

# ci_export KEY VALUE — set KEY for this shell *and* for every later step.
#
# Values containing a newline are rejected rather than silently truncated:
# in the KEY=VALUE format a newline starts a new assignment, which is how
# untrusted content turns into arbitrary environment injection.
ci_export() {
  local key=$1 value=$2 file
  case "$value" in
    *$'\n'*) ci_die "ci_export: refusing to export multi-line value for '$key'" ;;
  esac

  export "$key=$value"

  file=$(ci_env_file)
  [ -n "$file" ] || return 0

  case "$(ci_env_format)" in
    gha) printf '%s=%s\n' "$key" "$value" >>"$file" ;;
    bash) printf 'export %s=%q\n' "$key" "$value" >>"$file" ;;
  esac
}

# ci_export_line 'shell source line' — for shell that must be *run* by later
# steps rather than assigned (e.g. sourcing the Nix daemon profile). No-op
# under the KEY=VALUE format, where there is nowhere to put executable shell;
# on GitHub Actions the equivalent work is done by the Nix installer action.
ci_export_line() {
  local file
  [ "$(ci_env_format)" = bash ] || return 0
  file=$(ci_env_file)
  [ -n "$file" ] || return 0
  printf '%s\n' "$1" >>"$file"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

ci_have() { command -v "$1" >/dev/null 2>&1; }

# Truthiness for values that arrive as strings from a YAML boolean. CircleCI
# renders `<< parameters.foo >>` as `true`/`false`; GitHub Actions inputs
# arrive the same way; a human writing `1` should also work.
ci_is_true() {
  case "${1:-}" in
    1 | true | TRUE | True | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# Repo root, so a script works regardless of the directory it is invoked from.
ci_repo_root() { git rev-parse --show-toplevel; }

# `nix run` for a tool that is not in the job's environment, resolved against
# *this flake's* nixpkgs (`--inputs-from .`) rather than the machine's registry
# — the registry is unpinned and, on a fresh CircleCI VM, absent entirely.
ci_nix_run() {
  local pkg=$1
  shift
  nix --extra-experimental-features 'nix-command flakes' \
    run --inputs-from . "nixpkgs#$pkg" -- "$@"
}
