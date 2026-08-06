#!/usr/bin/env bash
#
# Install Nix, unless the job already has it.
#
# This is the one script here that *cannot* be a D program (which AGENTS.md
# would otherwise require): it is what makes the D toolchain exist. Everything
# it does happens strictly before `nix`, `dub`, or `ldc2` are on PATH.
#
# On GitHub Actions this is a no-op — `cachix/install-nix-action` has already
# run — and it stays in the shared path only so both providers go through the
# same "is Nix usable, and is it on PATH for later steps?" check.
#
# Environment:
#   CI_NIX_SINGLE_USER  1 = single-user install into a user-owned /nix.
#                       Required for any job that caches /nix, because a
#                       root-owned store cannot be read back by the cache
#                       restore, which runs unprivileged.
#   NIX_VERSION         Pin a specific Nix release (default: current stable).
#
# Note the ordering constraint this implies for the caller: /nix must already
# exist and be owned by the job user *before* the cache is restored into it.
# See the `install /nix` step in .circleci/config.yml.
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

nix_version=${NIX_VERSION:-}

if ci_is_true "${CI_NIX_SINGLE_USER:-}"; then
  single_user=1
else
  single_user=0
fi

if [ -n "$nix_version" ]; then
  installer_url="https://releases.nixos.org/nix/nix-${nix_version}/install"
else
  installer_url="https://nixos.org/nix/install"
fi

# Where a single-user install puts the profile. The daemon install uses
# /nix/var/nix/profiles/default and ships a profile script to source.
user_profile="$HOME/.nix-profile/bin"
daemon_profile_script="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"

# --- Already usable? -------------------------------------------------------

if ci_have nix; then
  printf 'Nix already on PATH: %s\n' "$(nix --version)"
  exit 0
fi

# A restored /nix cache brings the store and the profile symlink back, but not
# the PATH entry — the installer's ~/.bash_profile edit is not part of what we
# cache, and CircleCI does not source it anyway. Re-export and skip the
# download rather than reinstalling over a populated store.
if [ -x "$user_profile/nix" ]; then
  printf 'Reusing the restored /nix store (single-user profile)\n'
  ci_export PATH "$user_profile:$PATH"
  printf 'Nix restored: %s\n' "$(nix --version)"
  exit 0
fi

if [ -f "$daemon_profile_script" ]; then
  printf 'Reusing the restored /nix store (daemon profile)\n'
  # shellcheck source=/dev/null
  . "$daemon_profile_script"
  ci_export_line ". $daemon_profile_script"
  ci_export PATH "$PATH"
  printf 'Nix restored: %s\n' "$(nix --version)"
  exit 0
fi

# --- Install ---------------------------------------------------------------

ci_group "Installing Nix ($([ "$single_user" = 1 ] && echo single-user || echo daemon))"

installer=$(mktemp)
trap 'rm -f "$installer"' EXIT
curl --fail --silent --show-error --location --retry 3 "$installer_url" -o "$installer"

if [ "$single_user" = 1 ]; then
  # Idempotent: the caller normally creates this before restoring the cache.
  if [ ! -d /nix ]; then
    sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" /nix
  fi
  sh "$installer" --no-daemon --yes --no-channel-add
  ci_export PATH "$user_profile:$PATH"
else
  sh "$installer" --daemon --yes --no-channel-add
  # shellcheck source=/dev/null
  . "$daemon_profile_script"
  ci_export_line ". $daemon_profile_script"
  ci_export PATH "$PATH"
fi

ci_endgroup

printf 'Installed Nix: %s\n' "$(nix --version)"
