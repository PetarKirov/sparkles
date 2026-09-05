#!/usr/bin/env bash
#
# The Windows leg of the test matrix: `dub test` for the sub-packages that pass
# on native Windows, twice each — `-t 1`, then `-t 0` (the runner's auto width).
#
#   ci/test-windows.sh              # the allowlist below
#   ci/test-windows.sh wsi base     # just these
#
# Every other leg runs `ci --test`, the repo's own D helper. Its closure needs
# tree-sitter through pkg-config (sparkles:syntax, behind --audit-fences), which
# the hosted Windows runner cannot supply — no Nix there — so this is the
# helper's `--test` mode reduced to what a plain LDC + dub install can do. The
# two legs per package are kept for the helper's reason: a stack-heavy test
# cannot hide on the main thread. Coverage is not: it is a report, not a gate.
#
# Run with `shell: bash` (Git Bash on the GitHub runner, bash.exe on CircleCI)
# so this shares lib/common.sh with every other platform.
#
# Which packages: sparkles:wsi is why the leg exists — its Win32 backend had
# only ever been certified under Wine — so it runs first; the rest is best
# effort, in dependency order. A package is listed once its suite passes and
# left out with its reason otherwise; enabling one is adding it to the list.
# The reasons, from a sweep of every sub-package cross-built in the `.#win32`
# shell and run under Wine (2026-09-05):
#
#   syntax, tree-sitter, twoslash, twoslash-d, twoslash-extract, docs,
#   source-view, ci, hue, dmd-fmt, dmd-lsp, ghostty, terminal-view
#       C libraries via pkg-config (tree-sitter, libghostty-vt) or the DMD
#       frontend as a git dependency — nothing the runner has a toolchain for.
#       The frontend consumers also crash at startup under Wine, untriaged.
#   raylib-text, ui-raylib, ui-sdl3, vulkan, vulkan-wsi, terminal,
#   ui-app, ui-gallery, diagram
#       raylib / SDL3 / Vulkan headers and libraries the runner does not ship;
#       ui-app and its two consumers also reach ui-tui.
#   ui-tui       sparkles.tui's `PosixEvents`/`Terminal` are POSIX-only
#                (ui_tui/session.d:33).
#   event-horizon
#                the IOCP backend builds — wsi and http link it — but its own
#                suite drives POSIX pipes (io.d:385) and an `OpWrite` submit
#                the IOCP path lacks (sched.d:501): a port, not a flag.
#   wired        sdl/files.d calls `chmod`, undefined on Windows.
#   core-cli     9 of 98: process_utils spawns POSIX shells; common_dirs
#                expects XDG directories.
#   release      3 of 102: agents.resolveBinary / runAgent assume a POSIX
#                PATH and file shape.
#   test-utils   1 of 4: diff_tools shells out to `delta`, absent here.
#   terminal-benchmark
#                1 of 4: bench.workload.streams reads /proc.
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

default_packages=(
  wsi
  metadata
  reflection
  base
  math
  input
  test-runner
  test-runner-impl
  build-primitives
  code-instrumentation
  diff
  dsv
  fuzzy
  dql
  versions
  twoslash-protocol
  ui
  tui
  http
)

packages=("$@")
[ "${#packages[@]}" -gt 0 ] || packages=("${default_packages[@]}")
compiler=${DC:-ldc2}

cd "$(ci_repo_root)"
for pkg in "${packages[@]}"; do
  for threads in 1 0; do
    ci_group "dub test :$pkg -- -t $threads"
    if ! dub test ":$pkg" --compiler="$compiler" -- -t "$threads" </dev/null; then
      ci_endgroup
      ci_die "sparkles:$pkg failed under $compiler with -t $threads"
    fi
    ci_endgroup
  done
done
printf 'ok: %d sub-package(s) tested on %s\n' "${#packages[@]}" "$(uname -s)"
