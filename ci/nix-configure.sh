#!/usr/bin/env bash
#
# Write the job's nix.conf and netrc.
#
# Shared verbatim by both providers: this is the file that decides which binary
# caches a job trusts, and having one copy of it is the whole point of this
# directory. It used to live as a heredoc inside
# .github/actions/setup-nix/action.yml.
#
# Environment (all optional — an unset value simply omits its line):
#   NIX_SUBSTITUTERS          Extra substituters, space-separated.
#   NIX_TRUSTED_PUBLIC_KEYS   Extra trusted public keys, space-separated.
#   CACHIX_CACHE              Cachix cache name (for the netrc entry).
#   CACHIX_AUTH_TOKEN         Cachix auth token (for the netrc entry).
#   NIX_GITHUB_TOKEN          access-token for github.com.
#   NIX_GITLAB_TOKEN          access-token for NIX_GITLAB_DOMAIN.
#   NIX_GITLAB_DOMAIN         Defaults to gitlab.com.
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

substituters=${NIX_SUBSTITUTERS:-}
trusted_keys=${NIX_TRUSTED_PUBLIC_KEYS:-}
cachix_cache=${CACHIX_CACHE:-}
cachix_token=${CACHIX_AUTH_TOKEN:-}
gh_token=${NIX_GITHUB_TOKEN:-}
gl_token=${NIX_GITLAB_TOKEN:-}
gl_domain=${NIX_GITLAB_DOMAIN:-gitlab.com}

conf_dir="$HOME/.config/nix"
conf="$conf_dir/nix.conf"
netrc="$conf_dir/netrc"

mkdir -p "$conf_dir"

# --- access-tokens ---------------------------------------------------------
#
# One line holding every host, because nix.conf has no merge semantics: a
# second `access-tokens` line replaces the first rather than adding to it.

access_tokens=''
[ -n "$gh_token" ] && access_tokens="github.com=$gh_token"
if [ -n "$gl_token" ]; then
  access_tokens="${access_tokens:+$access_tokens }$gl_domain=PAT:$gl_token"
fi

# --- nix.conf --------------------------------------------------------------

{
  [ -n "$access_tokens" ] && printf 'access-tokens = %s\n' "$access_tokens"

  # The CircleCI machine executor installs Nix from scratch, where neither
  # flakes nor `nix build` are on by default. GitHub Actions' installer action
  # already enables both; repeating it here is idempotent.
  printf 'experimental-features = nix-command flakes\n'

  # Store optimisation rewrites the store into hard links. On a throwaway CI
  # machine that is pure cost, and it actively hurts a job that tars /nix into
  # a cache.
  printf 'auto-optimise-store = false\n'

  # Build locally rather than failing when a substituter is unreachable — CI
  # runners see transient cache outages often enough to matter.
  printf 'fallback = true\n'
  printf 'download-attempts = 2\n'
  printf 'connect-timeout = 5\n'
  printf 'narinfo-cache-negative-ttl = 120\n'

  # nix/packages/ reads build outputs during evaluation (dub-lock.json).
  printf 'allow-import-from-derivation = true\n'

  printf 'substituters = https://cache.nixos.org%s\n' "${substituters:+ $substituters}"
  printf 'trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=%s\n' \
    "${trusted_keys:+ $trusted_keys}"

  printf 'netrc-file = %s\n' "$netrc"
} >"$conf"

# --- netrc -----------------------------------------------------------------
#
# Cachix reads pull credentials from here. Created empty even without a token
# so the `netrc-file` line above always resolves.

touch "$netrc"
chmod 0600 "$netrc"
if [ -n "$cachix_cache" ] && [ -n "$cachix_token" ]; then
  printf 'machine %s.cachix.org password %s\n' "$cachix_cache" "$cachix_token" >>"$netrc"
fi

# --- daemon installs: make this user trusted -------------------------------
#
# A multi-user daemon ignores substituters and trusted-public-keys coming from
# an untrusted user's nix.conf — so on a daemon install everything written
# above is advisory until the user is in `trusted-users`. GitHub Actions'
# installer action already arranges this; CircleCI's macOS executor (where a
# single-user store is not an option, the store needs its own APFS volume)
# does not.

# Guarded on being *in* CI: outside it this script is only ever run to inspect
# what it would produce, and rewriting a developer's system-wide /etc/nix is
# not something a dry run should do.
provider=$(ci_provider)

if [ "$provider" = local ]; then
  printf 'Not running in CI; leaving /etc/nix alone.\n'
elif [ "$provider" != github ] && [ -d /etc/nix ]; then
  if ! grep -qE "^trusted-users .*\b$(id -un)\b" /etc/nix/nix.conf 2>/dev/null; then
    printf 'trusted-users = root %s\n' "$(id -un)" | sudo tee -a /etc/nix/nix.conf >/dev/null
    printf 'auto-optimise-store = false\n' | sudo tee -a /etc/nix/nix.conf >/dev/null

    if [ "$(uname -s)" = Darwin ]; then
      sudo launchctl kickstart -k system/org.nixos.nix-daemon || true
    else
      sudo systemctl restart nix-daemon || true
    fi
  fi
elif [ -f /etc/nix/nix.conf ]; then
  printf 'auto-optimise-store = false\n' | sudo tee -a /etc/nix/nix.conf >/dev/null
fi

ci_group 'Effective nix.conf'
sed -E 's/(access-tokens = ).*/\1<redacted>/' "$conf"
ci_endgroup
