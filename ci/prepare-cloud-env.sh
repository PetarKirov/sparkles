#!/usr/bin/env bash
#
# One-shot setup for an ephemeral cloud agent container (Claude Code on the
# web, and anything else that clones the repo into a fresh box and then expects
# `dub test` to work).
#
# Point the environment's setup script at this file and nothing else:
#
#     /home/user/sparkles/ci/prepare-cloud-env.sh
#
# The heavy lifting is delegated to the scripts already in this directory
# (`nix-install.sh`, `nix-configure.sh`). What is added here is only the three
# things such a container needs that a CI runner does not:
#
#   1. Nix on PATH for *non-interactive* shells. The agent's tool shells read
#      neither ~/.bashrc nor a login profile, and the container may already
#      export __ETC_PROFILE_NIX_SOURCED=1 — which makes sourcing nix-daemon.sh
#      a silent no-op, so a `.bashrc` edit leaves the agent with
#      `nix: command not found`. Unset the guard, then symlink into
#      /usr/local/bin, which is on PATH unconditionally.
#
#   2. A flake.lock whose inputs are actually reachable. The egress proxy
#      allows the git protocol to github.com but 403s the tarball and API
#      endpoints that Nix's `github:` fetcher uses, so locked `github` refs are
#      rewritten to equivalent shallow `git+https` refs. This is probed, not
#      assumed: on a developer machine or in CI it is a no-op.
#
#   3. Wrappers, so `dub`/`ldc2` resolve without every command having to be
#      spelled `nix develop -c …`.
#
# Like nix-install.sh, this is the one other script here that cannot be a D
# program (which AGENTS.md would otherwise require): it is what makes the D
# toolchain exist.
#
# Environment:
#   CI_DEVSHELL         devShell to prebuild and wrap. Default `default` — the
#                       quiet one, because a `figlet` banner would pollute
#                       captured stdout. See "Choosing a devShell" below.
#   CI_WRAP_BIN         Where to write wrappers. Defaults to /usr/local/bin when
#                       that is writable, else ~/.local/bin.
#   CI_FORCE_GIT_INPUTS Rewrite flake.lock even where the tarball endpoints are
#                       reachable. This is how CI exercises the blocked-egress
#                       path on a runner with open egress; `0` forces it off.
#   CI_FORCE_GIT_DEPS   The same, for seeding dub registry packages from git.
#
# Choosing a devShell:
#
#     CI_DEVSHELL=full ci/prepare-cloud-env.sh   # interactive, with the banner
#     CI_DEVSHELL=ci   ci/prepare-cloud-env.sh   # the CI floor, smallest closure
#
# The wrappers are regenerated against whichever shell was named, so re-running
# with a different CI_DEVSHELL switches the toolchain the container resolves.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci/lib/common.sh
. "$here/lib/common.sh"

repo=$(cd "$here/.." && pwd)
devshell=${CI_DEVSHELL:-default}
# /usr/local/bin is on PATH unconditionally, which is the whole point — but a
# CI runner runs unprivileged, so fall back rather than fail.
if [ -n "${CI_WRAP_BIN:-}" ]; then
  wrap_bin=$CI_WRAP_BIN
elif mkdir -p /usr/local/bin 2>/dev/null && [ -w /usr/local/bin ]; then
  wrap_bin=/usr/local/bin
else
  wrap_bin=$HOME/.local/bin
fi
profile=/nix/var/nix/profiles/sparkles-devshell

cd "$repo"

# --- 1. Nix on PATH --------------------------------------------------------

ci_group 'Locating Nix'

# The container may inherit this guard from whatever sourced the profile script
# first. Left set, the `.` below returns immediately and PATH is never touched.
unset __ETC_PROFILE_NIX_SOURCED

daemon_profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
if ! ci_have nix && [ -f "$daemon_profile" ]; then
  # shellcheck source=/dev/null
  . "$daemon_profile"
fi

add_nix_to_path() {
  export PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"
}

ci_have nix || add_nix_to_path
ci_have nix || { "$here/nix-install.sh"; add_nix_to_path; }
ci_have nix || ci_die 'Nix is not installed and could not be installed'

# An `--init none` install leaves no daemon, so talk to the store directly.
# Harmless where a daemon does exist and this user is trusted.
[ -S /nix/var/nix/daemon-socket/socket ] || export NIX_REMOTE=local

# nix-daemon.sh only respects an already-set NIX_SSL_CERT_FILE, and the agent
# proxy re-terminates TLS — be explicit rather than depend on that ordering.
if [ -z "${NIX_SSL_CERT_FILE:-}" ] && [ -f /root/.ccr/ca-bundle.crt ]; then
  export NIX_SSL_CERT_FILE=/root/.ccr/ca-bundle.crt
fi

printf 'Using %s (%s)\n' "$(command -v nix)" "$(nix --version)"
ci_endgroup

# Make it stick for shells that source nothing at all. Resolve through any
# symlink first: on a re-run `command -v nix` finds the link this loop made
# last time, and re-linking that onto itself leaves a self-referential symlink
# and a `nix: command not found` several steps later.
mkdir -p "$wrap_bin"
for tool in nix nix-build nix-shell nix-store nix-env nix-instantiate; do
  target=$(command -v "$tool" 2>/dev/null) || continue
  target=$(readlink -f "$target")
  [ -x "$target" ] || continue
  case "$target" in
    "$wrap_bin"/*) continue ;;
  esac
  ln -sfn "$target" "$wrap_bin/$tool"
done

# --- 2. Reachable flake inputs ---------------------------------------------

if [ -n "${CI_FORCE_GIT_INPUTS:-}" ]; then
  ci_is_true "$CI_FORCE_GIT_INPUTS" && tarball_status=forced || tarball_status=200
else
  tarball_status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    https://codeload.github.com/NixOS/nixpkgs/tar.gz/master 2>/dev/null || echo 000)
fi

if [ "$tarball_status" = 200 ]; then
  printf 'GitHub tarball egress is available; leaving flake.lock alone.\n'
else
  ci_group "Rewriting locked github: inputs to git+https (codeload: $tarball_status)"

  # The pristine lock comes from git, not from a backup file: a backup taken on
  # a re-run would capture a lock this script had already rewritten, and the
  # rewrite would then be a no-op over refs that are no longer `github`.
  git show HEAD:flake.lock >flake.lock

  # Only the `locked` side. Rewriting `original` too makes Nix decide the lock
  # no longer matches flake.nix and re-resolve every input over the blocked
  # API. `shallow` keeps this from turning into multi-GiB full clones (nixpkgs
  # alone is ~2.7 GiB unshallowed) and is a lock *attribute*, not a `?shallow=1`
  # query param — inside flake.lock the url is taken literally. narHash is
  # dropped because a git checkout hashes differently from a release tarball;
  # Nix recomputes and re-pins it.
  python3 - <<'PY'
import json

with open('flake.lock') as f:
    lock = json.load(f)

rewritten = 0
for node in lock['nodes'].values():
    ref = node.get('locked')
    if isinstance(ref, dict) and ref.get('type') == 'github':
        owner, repo = ref.pop('owner'), ref.pop('repo')
        ref['type'] = 'git'
        ref['url'] = f'https://github.com/{owner}/{repo}'
        ref['shallow'] = True
        ref.pop('narHash', None)
        rewritten += 1

with open('flake.lock', 'w') as f:
    json.dump(lock, f, indent=2)
    f.write('\n')

print(f'rewrote {rewritten} locked refs')
PY

  # A local accommodation, never something to commit.
  git update-index --skip-worktree flake.lock 2>/dev/null || true
  ci_notice 'flake.lock rewritten for this container (tracked copy is untouched in git)'
  ci_notice 'to undo: git update-index --no-skip-worktree flake.lock && git restore flake.lock'
  ci_endgroup
fi

# --- 3. nix.conf -----------------------------------------------------------
#
# flake.nix's nixConfig names this project's two Cachix caches. Without them a
# container builds LDC, DMD, dub, the tree-sitter grammars and ghostty from
# source, which is hours rather than minutes.

export NIX_ACCEPT_FLAKE_CONFIG=1
export NIX_SUBSTITUTERS='https://sparkles.cachix.org https://dlang-community.cachix.org'
export NIX_TRUSTED_PUBLIC_KEYS='sparkles.cachix.org-1:CPQ+GG8UKQCNUyvCrgZj8p7P+7cYqpjmGAmUPlLwbZc= dlang-community.cachix.org-1:eAX1RqX4PjTDPCAp/TvcZP+DYBco2nJBackkAJ2BsDQ='

"$here/nix-configure.sh"

# --- 3b. Make those caches actually apply ----------------------------------
#
# A multi-user daemon does not merge an untrusted user's `substituters` and
# `trusted-public-keys` — it discards them. So everything nix-configure.sh just
# wrote is advisory until this user is in `trusted-users`, and the symptom is
# not an error: the build simply proceeds from source, for about an hour.
#
# nix-configure.sh has this step but skips it when it detects GitHub Actions,
# because there it assumes `cachix/install-nix-action` already arranged trust.
# This script is the one caller that breaks that assumption: an agent container
# has no action, and the `cloud-env` CI job deliberately does not use it either
# (bootstrapping without it is the thing under test). So do it here, for any
# daemon install, whatever the provider.

if [ "${NIX_REMOTE:-}" != local ] && [ -S /nix/var/nix/daemon-socket/socket ]; then
  if ! grep -qE "^trusted-users .*\b$(id -un)\b" /etc/nix/nix.conf 2>/dev/null; then
    ci_group 'Adding this user to trusted-users (daemon install)'

    # Written system-wide as well as per-user: the system file is authoritative
    # no matter who asks, so the caches apply even on the first evaluation
    # after this, before any re-login.
    {
      printf 'trusted-users = root %s\n' "$(id -un)"
      printf 'extra-substituters = %s\n' "$NIX_SUBSTITUTERS"
      printf 'extra-trusted-public-keys = %s\n' "$NIX_TRUSTED_PUBLIC_KEYS"
    } | sudo tee -a /etc/nix/nix.conf >/dev/null

    if [ "$(uname -s)" = Darwin ]; then
      sudo launchctl kickstart -k system/org.nixos.nix-daemon || true
    else
      sudo systemctl restart nix-daemon || true
    fi

    ci_endgroup
  fi
fi

# --- 3c. Prove it, rather than assume it -----------------------------------
#
# This is a hard failure on purpose. The alternative — which is what actually
# happened the first time this job ran — is a silent hour of compiling LDC and
# DMD that ends in a cancelled job and no stated reason. Failing here names the
# cause in one line.

ci_group 'Verifying the caches are in effect'
effective_substituters=$(nix config show substituters 2>/dev/null || echo '')
printf 'substituters: %s\n' "$effective_substituters"
# --json, because plain `nix store info` writes its report to stderr.
printf 'trusted user: %s\n' "$(nix store info --json 2>/dev/null | sed -n 's/.*"trusted":\([a-z0-9]*\).*/\1/p')"

case "$effective_substituters" in
  *sparkles.cachix.org*) ;;
  *)
    ci_die "sparkles.cachix.org is not an effective substituter.
        On a daemon install this means $(id -un) is not in trusted-users, so
        nix discarded the substituter list nix-configure.sh wrote, and every
        derivation would be built from source. Add the user to trusted-users
        in /etc/nix/nix.conf."
    ;;
esac
ci_endgroup

# --- 4. Prebuild the devShell ----------------------------------------------
#
# Into a profile, which doubles as a GC root. Building it here means the first
# `dub test` does not pay for it, and a toolchain that cannot be built fails
# *this* script rather than surfacing later as a missing binary.

ci_group "Building devShell .#$devshell"
nix develop --profile "$profile" ".#$devshell" -c true
ci_endgroup

# --- 5. Wrappers -----------------------------------------------------------
#
# `nix develop --profile` records the shell derivation as a GC root, but it
# does not populate a bin/ directory — the devShell's tools only exist on the
# PATH the shell sets up. So snapshot that environment once with
# `print-dev-env` and have each wrapper source it. That keeps a wrapper call to
# a shell source rather than a flake evaluation.

env_snapshot=${XDG_CACHE_HOME:-$HOME/.cache}/sparkles/devenv.sh
mkdir -p "$(dirname "$env_snapshot")"

ci_group 'Snapshotting the devShell environment'
nix print-dev-env ".#$devshell" >"$env_snapshot"
ci_endgroup

for tool in dub ldc2 ldc-build-runtime dmd delta direnv prek lychee; do
  cat >"$wrap_bin/$tool" <<EOF
#!/usr/bin/env bash
# Generated by ci/prepare-cloud-env.sh — $tool from the Nix devShell.
set -euo pipefail
# stderr is dropped for the source only: the devShell's shellHook shells out
# to gh, which is not installed here, so every wrapper call would otherwise
# print a 'command not found' line into captured output.
. "$env_snapshot" 2>/dev/null
exec $tool "\$@"
EOF
  chmod +x "$wrap_bin/$tool"
done

# `ci` is deliberately NOT wrapped. AGENTS.md calls the stale store copy a
# recurring footgun: it lags behind edits to apps/ci. Use `dub run :ci -- …`.
rm -f "$wrap_bin/ci"

# --- 6. Registry dependencies ----------------------------------------------
#
# `dub` fetches a registry package as a zip from code.dlang.org, which 302s to
# codeload.github.com — the one GitHub endpoint family the proxy blocks. The
# git protocol is allowed, and the registry's JSON API (same host, no redirect)
# names each package's upstream repo, so clone the tag and register it as a
# local package. Nix cannot stand in here: nix/dub-lock.json fetches the same
# blocked zips.
#
# This has to stay shell despite AGENTS.md: the `ci` helper it would otherwise
# live in is itself a dub package, and it cannot resolve `expected` until this
# has run.

if [ -n "${CI_FORCE_GIT_DEPS:-}" ]; then
  ci_is_true "$CI_FORCE_GIT_DEPS" && registry_status=forced || registry_status=200
else
  registry_status=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 25 \
    https://code.dlang.org/packages/expected/0.4.1.zip 2>/dev/null || echo 000)
fi

if [ "$registry_status" = 200 ]; then
  printf 'The dub registry is directly reachable; not seeding local packages.\n'
else
  ci_group "Seeding registry dependencies from git (registry zip: $registry_status)"

  dub_src=${XDG_CACHE_HOME:-$HOME/.cache}/sparkles/dub-src
  plan=$(mktemp)
  trap 'rm -f "$plan"' EXIT
  mkdir -p "$dub_src"

  # Resolve every wanted package to an upstream repo in one pass, so the shell
  # below only has to clone. Only the sub-packages actually built here: the
  # research examples under docs/ pull a long tail (pyd, objective-d, numem,
  # icu, …) that no test run touches.
  # shellcheck disable=SC2016  # single-quoted on purpose: this is Python source.
  git ls-files 'libs/*/dub.selections.json' 'apps/*/dub.selections.json' \
    | python3 -c '
import json, sys, urllib.request

wanted = {}
for path in sys.stdin.read().split():
    with open(path) as f:
        for name, pin in json.load(f)["versions"].items():
            # A dict pin is a path= or git repository= dependency. dub resolves
            # those itself, and the git ones go over the protocol that works.
            if name.startswith("sparkles") or not isinstance(pin, str):
                continue
            wanted[name] = max(wanted.get(name, pin), pin)

for name, version in sorted(wanted.items()):
    # code.dlang.org 403s the default Python-urllib user agent.
    request = urllib.request.Request(
        f"https://code.dlang.org/api/packages/{name}/info",
        headers={"User-Agent": "curl/8"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            repo = json.load(response)["repository"]
    except Exception as error:
        print(f"{name}\t{version}\t-\t{error}")
        continue

    if repo.get("kind") != "github":
        kind = repo.get("kind")
        print(f"{name}\t{version}\t-\tnot hosted on github ({kind})")
        continue

    owner, project = repo["owner"], repo["project"]
    # `-` rather than an empty field: tab is IFS whitespace, so `read` collapses
    # runs of it and an empty column would silently shift every later one.
    print(f"{name}\t{version}\thttps://github.com/{owner}/{project}\t-")
' >"$plan" || ci_die 'could not resolve registry dependencies'

  # `--depth 1` on the tag: these are consumed as sources, not history. A miss
  # is a warning, never fatal — `silly` is pinned in several selections at a
  # version that was never tagged upstream, and nothing builds against it any
  # more (the repo has its own test runner).
  while IFS=$'\t' read -r name version url reason; do
    [ -n "$name" ] || continue

    if [ "$url" = - ]; then
      ci_notice "skipping $name $version: $reason"
      continue
    fi

    dest="$dub_src/$name-$version"
    if [ ! -d "$dest" ]; then
      cloned=0
      for tag in "v$version" "$version"; do
        if git clone --quiet --depth 1 --branch "$tag" "$url" "$dest" 2>/dev/null; then
          cloned=1
          break
        fi
      done

      if [ "$cloned" = 0 ]; then
        rm -rf "$dest"
        ci_notice "skipping $name $version: no v$version or $version tag at $url"
        continue
      fi
    fi

    dub add-local "$dest" "$version" >/dev/null
    printf 'seeded %s %s\n' "$name" "$version"
  done <"$plan"

  ci_endgroup
fi

# A fallback wrap_bin is not necessarily on PATH. `ci_export` also writes it to
# $GITHUB_ENV / $BASH_ENV, so later CI steps inherit it.
case ":$PATH:" in
  *":$wrap_bin:"*) ;;
  *) ci_export PATH "$wrap_bin:$PATH" ;;
esac

ci_group 'Verification'
dub --version
ldc2 --version | head -n1
ci_endgroup

printf '\nReady (devShell .#%s, wrappers in %s). Try: dub test :base\n' \
  "$devshell" "$wrap_bin"
