#!/usr/bin/env bash
#
# Run a long batch command the way a CI runner wants it.
#
#   ci/run-batch.sh 20m ci --example-files --fail-fast
#
# Three wrappers, each fixing something CircleCI does differently:
#
#   * `timeout` — CircleCI has no per-job wall-clock cap, which is what
#     GitHub Actions' `timeout-minutes` provided. Without one, a stuck child
#     runs until the account-level maximum.
#
#   * `| cat` — `ci` renders a live spinner because `isatty(stdout)` is true
#     on a CircleCI runner and false on a GitHub one. Piping makes stdout a
#     pipe, so the live region degrades to plain lines. That gives readable
#     logs (one verify step produced 400 KB of redrawn spinner frames) and,
#     more importantly, makes `no_output_timeout` a working backstop: a
#     spinner is *output*, so a stalled step with one can never trip it.
#
#   * `</dev/null` — nothing this wrapper runs should ever read stdin, and a
#     TTY on stdin is what made the prompts example go interactive.
#
# CircleCI runs steps under `bash -eo pipefail`, and this script sets the
# same, so the pipeline reports `timeout`'s status rather than `cat`'s —
# including 124 when the wall clock runs out.
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -ge 2 ] || ci_die 'usage: run-batch.sh <timeout> <command> [args...]'

limit=$1
shift

timeout "$limit" "$@" </dev/null | cat
