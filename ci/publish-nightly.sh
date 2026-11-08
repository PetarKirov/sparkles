#!/usr/bin/env bash
#
# Publish the nightly APKs as a new immutable pre-release, delete the oldest
# ones, and point the redirect site at the new one.
#
#   ci/publish-nightly.sh dist/
#
# The repository has immutable releases on: a published release's assets and
# tag are fixed, and a tag name, once used, cannot be reused even after its
# release is deleted. So there is no rolling `nightly` release. Every build
# gets its own tag, `<prefix>-<date>-<sha>`, and the stable address is a
# Cloudflare Pages project holding only redirects, served at
# https://releases.sparkles.petar-kirov.dev (its custom domain):
#
#   /                  the repository's releases
#   /nightly/          the newest release's page
#   /nightly/<asset>   that release's asset
#
# It is not the docs project, because a Pages deploy replaces the whole
# site: deploying these redirects there would delete the docs.
#
# Environment:
#   GH_TOKEN               Required: creates and deletes releases.
#   GITHUB_REPOSITORY      owner/name. Required.
#   GITHUB_SHA             The commit the APKs were built from. Required.
#   NIGHTLY_PREFIX         Tag prefix (default: nightly). A branch test uses
#                          nightly-test, so it never touches the nightly.
#   NIGHTLY_KEEP           Releases of this prefix to keep (default: 7).
#   CLOUDFLARE_API_TOKEN   With CLOUDFLARE_ACCOUNT_ID, deploys the redirects;
#   CLOUDFLARE_ACCOUNT_ID  without them that step is skipped.
#   CF_PAGES_PROJECT       Pages project name (default: sparkles-nightly).
#   CI_BRANCH              Pages branch (default: main, the production
#                          deployment); a branch test deploys a preview.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci/lib/common.sh
. "$here/lib/common.sh"

dist=${1:-}
[ -d "$dist" ] || ci_die 'usage: publish-nightly.sh <directory of assets>'
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}"

prefix=${NIGHTLY_PREFIX:-nightly}
keep=${NIGHTLY_KEEP:-7}
project=${CF_PAGES_PROJECT:-sparkles-nightly}
branch=${CI_BRANCH:-main}
short=${GITHUB_SHA::9}
ref=${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}
tag="$prefix-$(date -u +%Y%m%d)-$short"
repo_url="https://github.com/$GITHUB_REPOSITORY"

# A re-run of the same commit on the same day: its release already exists
# and cannot change, so only the redirects are (re)deployed.
if gh release view "$tag" > /dev/null 2>&1; then
  ci_notice "$tag already exists; not publishing it again"
else
  notes=$(mktemp)
  trap 'rm -f "$notes"' EXIT
  cat > "$notes" <<EOF
Development APKs built from \`$ref\` at $GITHUB_SHA.

Debuggable and signed with the in-tree debug key: installing a build signed
with any other key requires uninstalling first. Verify a download with
\`sha256sum -c SHA256SUMS\`.
EOF
  # gh uploads the assets to a draft and publishes it after, so the release
  # is complete when it becomes immutable.
  ci_group "Publishing $tag"
  title="Nightly $(date -u +%F) ($short)"
  [ "$prefix" = nightly ] || title="Nightly test: $ref ($short)"
  gh release create "$tag" "$dist"/* --target "$GITHUB_SHA" \
    --title "$title" --notes-file "$notes" \
    --prerelease --latest=false
  ci_endgroup
fi

# Newest first. The pattern excludes the other prefix: `nightly-` followed by
# a digit is never a `nightly-test-` tag.
ci_group "Keeping the newest $keep $prefix releases"
gh release list --limit 200 --json tagName,createdAt \
  --jq "[.[] | select(.tagName | test(\"^${prefix}-[0-9]{8}-[0-9a-f]+\$\"))]
        | sort_by(.createdAt) | reverse | .[$keep:] | .[].tagName" |
  while read -r old; do
    printf 'Deleting %s\n' "$old"
    gh release delete "$old" --cleanup-tag --yes
  done
ci_endgroup

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  ci_notice 'Cloudflare not configured; the redirects were not deployed'
  exit 0
fi

site=$(mktemp -d)
{
  printf '/ %s/releases 302\n' "$repo_url"
  printf '/nightly %s/releases/tag/%s 302\n' "$repo_url" "$tag"
  printf '/nightly/ %s/releases/tag/%s 302\n' "$repo_url" "$tag"
  for f in "$dist"/*; do
    name=$(basename "$f")
    printf '/nightly/%s %s/releases/download/%s/%s 302\n' "$name" "$repo_url" "$tag" "$name"
  done
} > "$site/_redirects"
# Served only if a redirect does not match first.
printf '<!doctype html><meta http-equiv="refresh" content="0; url=%s/releases">\n' \
  "$repo_url" > "$site/index.html"
cat "$site/_redirects"

wrangler=(nix run --inputs-from "$here/.." nixpkgs#wrangler --)
if ! "${wrangler[@]}" pages project list 2>/dev/null | grep -qw "$project"; then
  "${wrangler[@]}" pages project create "$project" --production-branch main
fi
ci_group "Deploying the redirects to $project ($branch)"
"${wrangler[@]}" pages deploy "$site" --project-name "$project" --branch "$branch"
ci_endgroup
