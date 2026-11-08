#!/usr/bin/env bash
#
# Run a command with every store path it builds pushed to Sparkles' primary
# binary cache: the R2 bucket served at https://cache.sparkles.petar-kirov.dev.
#
#   ci/with-cache.sh nix build --print-build-logs .#all-desktop
#
# Cachix (sparkles.cachix.org) is not pushed to here: it holds 10 GiB and
# evicts, so it keeps only the pin set (TC24, `ci/toolchain-pin.d`), and R2,
# which does not evict, holds everything else. ci/gc-root.sh records what a
# build produced, so the bucket's garbage collection keeps it.
#
# How:
#
#   1. A post-build hook, passed to the command's Nix calls through
#      NIX_CONFIG, appends each built output to a queue file. The daemon
#      honours the hook from a trusted client, so no /etc/nix edit or daemon
#      restart is needed. The hook only appends, so it does not slow the build
#      loop, and it then runs any hook it replaced.
#   2. A background uploader `nix copy`s new queue entries, with their
#      closures, every few seconds while the command runs, so a job that later
#      fails or times out has still pushed what it finished. `nix copy` writes
#      the NAR before the narinfo, so an interrupted upload never leaves a
#      narinfo without its NAR.
#   3. When the command exits, the queue is drained, and this script exits
#      with the command's status. An upload failure is reported, never fatal.
#
# Only paths built here are queued, not ones substituted from another cache;
# their closures go up with them, so the bucket can serve them on its own.
#
# Without the R2 credentials the command runs unwrapped.
#
# Environment: see ci/lib/r2.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci/lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=ci/lib/r2.sh
. "$here/lib/r2.sh"

[ "$#" -gt 0 ] || ci_die 'usage: with-cache.sh <command> [args...]'

if ! r2_configured; then
  printf 'R2 not configured (R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ACCOUNT_ID / NIX_R2_SIGNING_KEY unset); not pushing to it.\n'
  exec "$@"
fi

dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/with-cache.XXXXXX")
trap 'rm -rf "$dir"' EXIT
r2_init "$dir"
queue=$dir/queue
: > "$queue"

# The hook runs as root, in the daemon, with OUT_PATHS in its environment. One
# printf per build is one append, so the uploader never counts half a line.
previous=$(nix config show post-build-hook 2>/dev/null || true)
hook=$dir/post-build-hook.sh
{
  printf '#!/bin/sh\n'
  # shellcheck disable=SC2016 # $OUT_PATHS is the hook's, expanded when it runs.
  printf 'printf "%%s\\n" $OUT_PATHS >> %q\n' "$queue"
  [ -z "$previous" ] || printf 'exec %q\n' "$previous"
} > "$hook"
chmod 755 "$dir" "$hook"

# Copies queue lines [from, to] to the bucket. Two tries, as Nix already
# retries each S3 request with backoff; then the batch is skipped.
upload() {
  local from=$1 to=$2 try
  for try in 1 2; do
    if sed -n "${from},${to}p" "$queue" | r2_copy --stdin; then
      return 0
    fi
    sleep $((try * 5))
  done
  ci_notice "R2: could not push queue entries $from-$to; they were not pushed to R2"
  return 1
}

(
  sent=0 pushed=0
  while :; do
    total=$(wc -l < "$queue" | tr -d ' ')
    if [ "$total" -gt "$sent" ]; then
      if upload $((sent + 1)) "$total"; then
        pushed=$((pushed + total - sent))
      fi
      sent=$total
    elif [ -e "$dir/stop" ]; then
      printf 'R2: pushed %s of %s built paths (with closures) to %s.\n' "$pushed" "$sent" "$r2_bucket"
      exit 0
    else
      sleep 5
    fi
  done
) &
uploader=$!

export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}post-build-hook = $hook"

status=0
"$@" || status=$?

touch "$dir/stop"
ci_group 'R2: pushing the paths built last'
wait "$uploader" || true
ci_endgroup
exit "$status"
