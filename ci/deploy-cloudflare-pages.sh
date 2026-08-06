#!/usr/bin/env bash
#
# Deploy the built VitePress site to Cloudflare Pages and, on a pull request,
# post the preview URL back to the thread.
#
# GitHub Actions gets this from `cloudflare/wrangler-action` plus
# `actions/github-script`; both are thin wrappers over the same two commands,
# so doing it directly is what lets one implementation serve both providers.
#
# Environment:
#   CLOUDFLARE_API_TOKEN   Required.
#   CLOUDFLARE_ACCOUNT_ID  Required.
#   CF_PAGES_PROJECT       Pages project name (default: sparkles-docs).
#   CF_PAGES_DIST          Directory to upload (default: docs/.vitepress/dist).
#   CI_BRANCH              Deployment branch. Defaults to the provider's branch
#                          variable; a PR deploys under its head branch, which
#                          is what makes it a preview rather than production.
#   GITHUB_TOKEN           Only needed for the PR comment.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci/lib/common.sh
. "$here/lib/common.sh"

project=${CF_PAGES_PROJECT:-sparkles-docs}
dist=${CF_PAGES_DIST:-docs/.vitepress/dist}

[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || ci_die 'CLOUDFLARE_API_TOKEN is required'
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || ci_die 'CLOUDFLARE_ACCOUNT_ID is required'
[ -d "$dist" ] || ci_die "$dist does not exist — build the site first"

branch=${CI_BRANCH:-}
if [ -z "$branch" ]; then
  case "$(ci_provider)" in
    # On a pull_request event GITHUB_HEAD_REF is the source branch; on a push
    # to main it is empty and GITHUB_REF_NAME is the branch.
    github) branch=${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-main}} ;;
    circleci) branch=${CIRCLE_BRANCH:-main} ;;
    *) branch=$(git rev-parse --abbrev-ref HEAD) ;;
  esac
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT

ci_group "Deploying $dist to Cloudflare Pages ($project, branch $branch)"
npx --yes wrangler pages deploy "$dist" \
  --project-name "$project" \
  --branch "$branch" 2>&1 | tee "$log"
ci_endgroup

# wrangler prints the deployment URL as the last *.pages.dev it emits; the
# earlier ones are the project alias and the branch alias.
url=$(grep -oE 'https://[A-Za-z0-9.-]+\.pages\.dev' "$log" | tail -n 1 || true)

if [ -z "$url" ]; then
  ci_notice 'Deployed, but no preview URL was found in the wrangler output'
  exit 0
fi

printf 'Deployment URL: %s\n' "$url"
ci_export DOCS_PREVIEW_URL "$url"

if [ -n "${GITHUB_TOKEN:-}" ]; then
  "$here/pr-comment.sh" docs-preview "📄 Docs preview deployed to: $url"
fi
