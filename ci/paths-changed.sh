#!/usr/bin/env bash
#
# Exit 0 if any of the given git pathspecs changed relative to the base ref,
# 1 if none did.
#
#   ci/paths-changed.sh docs/ libs/twoslash/ package.json || circleci-agent step halt
#
# This is what GitHub Actions expresses declaratively as `on: push: paths:`.
# CircleCI's only native equivalent is the path-filtering orb, which requires
# splitting the config into a setup workflow plus a continuation config and
# turning on dynamic config for the project. Halting the job from inside is a
# fraction of the machinery for the same outcome; the cost is that the job
# spins up before deciding, which is a few seconds.
#
# Fails *open* — anything it cannot determine (no base ref, shallow clone,
# first commit) counts as changed. A docs deploy that runs unnecessarily is
# cheap; one that silently skips is a stale site.
#
# Environment:
#   CI_DIFF_BASE  Override the base ref (default: the PR target, else HEAD~1).
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -gt 0 ] || ci_die 'usage: paths-changed.sh <pathspec> [pathspec...]'

default_branch=${CI_DEFAULT_BRANCH:-main}
base=${CI_DIFF_BASE:-}

if [ -z "$base" ]; then
  case "$(ci_provider)" in
    github)
      # On a pull_request event GITHUB_BASE_REF is the target branch; on a
      # push it is empty and the previous commit is the right comparison.
      base=${GITHUB_BASE_REF:+origin/$GITHUB_BASE_REF}
      ;;
    circleci)
      base=${CIRCLE_PULL_REQUEST:+origin/$default_branch}
      ;;
  esac
  base=${base:-HEAD~1}
fi

if [ "$base" != "HEAD~1" ]; then
  git fetch --quiet --no-tags origin "${base#origin/}" 2>/dev/null || true
fi

if ! merge_base=$(git merge-base "$base" HEAD 2>/dev/null); then
  printf 'Cannot resolve a merge base against %s; treating paths as changed.\n' "$base"
  exit 0
fi

changed=$(git diff --name-only "$merge_base" HEAD -- "$@")

if [ -n "$changed" ]; then
  printf 'Changed under %s (vs %s):\n' "$*" "$base"
  printf '%s\n' "$changed" | head -n 20
  exit 0
fi

printf 'No changes under %s (vs %s).\n' "$*" "$base"
exit 1
