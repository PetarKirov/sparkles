#!/usr/bin/env bash
#
# Upsert a marker-identified comment on the pull request for this build.
#
#   ci/pr-comment.sh 'docs-preview' "📄 Docs preview deployed to: $url"
#
# The marker is embedded as an HTML comment, so re-running a job edits its own
# comment instead of appending a new one to the thread. GitHub Actions gets
# this from `actions/github-script`; this is the provider-neutral equivalent.
#
# A no-op (exit 0) when the build is not attached to a pull request.
#
# Environment:
#   GITHUB_TOKEN  Token with `pull-requests: write`. Required.
#   CI_REPO       owner/repo. Defaults to the provider's variables.
#   CI_PR_NUMBER  Overrides PR detection.
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -eq 2 ] || ci_die 'usage: pr-comment.sh <marker> <body>'
marker=$1
body=$2

repo=${CI_REPO:-}
if [ -z "$repo" ]; then
  case "$(ci_provider)" in
    github) repo=${GITHUB_REPOSITORY:-} ;;
    circleci) repo="${CIRCLE_PROJECT_USERNAME:-}/${CIRCLE_PROJECT_REPONAME:-}" ;;
  esac
fi

pr=${CI_PR_NUMBER:-}
if [ -z "$pr" ]; then
  case "$(ci_provider)" in
    # `refs/pull/<n>/merge`
    github) pr=$(printf '%s' "${GITHUB_REF:-}" | sed -n 's#^refs/pull/\([0-9]*\)/.*#\1#p') ;;
    # `https://github.com/<owner>/<repo>/pull/<n>`, and unset entirely on a
    # non-PR build — so default it before trimming, or `set -u` fires.
    circleci)
      pr=${CIRCLE_PULL_REQUEST:-}
      pr=${pr##*/}
      ;;
  esac
fi

if [ -z "$pr" ] || [ -z "$repo" ]; then
  printf 'Not a pull-request build (repo=%s pr=%s); skipping comment.\n' "${repo:-?}" "${pr:-?}"
  exit 0
fi

[ -n "${GITHUB_TOKEN:-}" ] || ci_die 'GITHUB_TOKEN is required to comment on a PR'

gh() {
  if ci_have gh; then
    command gh "$@"
  else
    ci_nix_run gh "$@"
  fi
}

tag="<!-- ci-comment:$marker -->"
full="$tag"$'\n'"$body"

existing=$(gh api "repos/$repo/issues/$pr/comments" --paginate \
  --jq "[.[] | select(.body | contains(\"$tag\"))] | first | .id // empty")

if [ -n "$existing" ]; then
  gh api -X PATCH "repos/$repo/issues/comments/$existing" -f body="$full" >/dev/null
  printf 'Updated comment %s on %s#%s\n' "$existing" "$repo" "$pr"
else
  gh api -X POST "repos/$repo/issues/$pr/comments" -f body="$full" >/dev/null
  printf 'Created a comment on %s#%s\n' "$repo" "$pr"
fi
