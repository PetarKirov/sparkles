#!/usr/bin/env bash
#
# Run the entire sparkles CI pipeline locally.
#
# Reuses the provider-neutral CI scripts in ci/ (lib/common.sh, run-batch.sh)
# and mirrors the stages defined in .github/workflows/ci.yml and
# .circleci/config.yml:
#
#   1. Flake checks (nix flake check)
#   2. DUB sub-package unit tests under LDC (ci --test)
#   3. DUB sub-package unit tests under DMD (ci --test)
#   4. Standalone example files (ci --example-files)
#   5. OS-API windowing examples (X11 + Wayland + cursor-shapes)
#   6. Extracted test modes (ci --test-extracted: --better-c, --wasm)
#   7. Nix desktop packages & runnable examples (all-desktop, run-all-examples)
#   8. Android APK closure (all-android; x86_64-linux only)
#   9. Lint & local link check (prek run --all-files)
#  10. Markdown runnable example verification (ci --verify)
#  11. Documentation site build (npm run docs:build)
#
# Usage:
#   ci/run-all.sh [options]
#
# Options:
#   -h, --help        Show this help message
#   --skip-android    Skip the Android APK closure build
#   --skip-dmd        Skip the DMD test suite pass
#   --skip-docs       Skip the VitePress documentation build
#   --skip-nix        Skip Nix package builds (all-desktop, all-android)
#   --skip-lint       Skip pre-commit linting and link checks
#   --skip-tests      Skip DUB unit test runs
#   --skip-examples   Skip standalone and markdown example verification
#   --only-test       Run only the test suites
#   --only-build      Run only the Nix package builds
#   --only-lint       Run only the linting and link checks
#   --only-examples   Run only the example verifications
#   --only-docs       Run only the documentation site build
#   -k, --keep-going  Continue running remaining stages even if one fails
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

repo_root="$(ci_repo_root)"
cd "$repo_root"

# --- CLI flags -------------------------------------------------------------

skip_android=0
skip_dmd=0
skip_docs=0
skip_nix=0
skip_lint=0
skip_tests=0
skip_examples=0
keep_going=0

usage() {
  cat <<'EOF'
Usage: ci/run-all.sh [options]

Run the entire sparkles CI pipeline locally.

Options:
  -h, --help        Show this help message
  --skip-android    Skip the Android APK closure build
  --skip-dmd        Skip the DMD test suite pass
  --skip-docs       Skip the VitePress documentation build
  --skip-nix        Skip Nix package builds (all-desktop, all-android)
  --skip-lint       Skip pre-commit linting and link checks
  --skip-tests      Skip DUB unit test runs
  --skip-examples   Skip standalone and markdown example verification
  --only-test       Run only the test suites
  --only-build      Run only the Nix package builds
  --only-lint       Run only the linting and link checks
  --only-examples   Run only the example verifications
  --only-docs       Run only the documentation site build
  -k, --keep-going  Continue running remaining stages even if one fails
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --skip-android)
      skip_android=1
      shift
      ;;
    --skip-dmd)
      skip_dmd=1
      shift
      ;;
    --skip-docs)
      skip_docs=1
      shift
      ;;
    --skip-nix)
      skip_nix=1
      shift
      ;;
    --skip-lint)
      skip_lint=1
      shift
      ;;
    --skip-tests)
      skip_tests=1
      shift
      ;;
    --skip-examples)
      skip_examples=1
      shift
      ;;
    --only-test)
      skip_android=1
      skip_docs=1
      skip_nix=1
      skip_lint=1
      skip_examples=1
      shift
      ;;
    --only-build)
      skip_tests=1
      skip_dmd=1
      skip_docs=1
      skip_lint=1
      skip_examples=1
      shift
      ;;
    --only-lint)
      skip_tests=1
      skip_dmd=1
      skip_docs=1
      skip_nix=1
      skip_android=1
      skip_examples=1
      shift
      ;;
    --only-examples)
      skip_tests=1
      skip_dmd=1
      skip_docs=1
      skip_nix=1
      skip_android=1
      skip_lint=1
      shift
      ;;
    --only-docs)
      skip_tests=1
      skip_dmd=1
      skip_nix=1
      skip_android=1
      skip_lint=1
      skip_examples=1
      shift
      ;;
    -k|--keep-going)
      keep_going=1
      shift
      ;;
    *)
      ci_die "Unknown option: $1 (see --help)"
      ;;
  esac
done

# --- Execution tracking ----------------------------------------------------

failures=0
failed_stages=()
total_start="$(date +%s)"

run_stage() {
  local name="$1"
  shift
  local start_time elapsed status

  ci_group "$name"
  start_time="$(date +%s)"

  if "$@"; then
    status=0
  else
    status=$?
  fi

  elapsed=$(( $(date +%s) - start_time ))
  ci_endgroup

  if [ "$status" -eq 0 ]; then
    printf '✓ %s (%ds)\n\n' "$name" "$elapsed"
  else
    printf '✗ %s FAILED (%ds)\n\n' "$name" "$elapsed" >&2
    failures=$(( failures + 1 ))
    failed_stages+=("$name")
    if [ "$keep_going" -eq 0 ]; then
      print_summary
      exit "$status"
    fi
  fi
}

print_summary() {
  local total_elapsed=$(( $(date +%s) - total_start ))
  printf '\n════════════════════════════════════════════════════════════════════════════════\n'
  if [ "$failures" -eq 0 ]; then
    printf '✓ Entire CI pipeline passed in %ds!\n' "$total_elapsed"
  else
    printf '✗ CI pipeline encountered %d failure(s) in %ds:\n' "$failures" "$total_elapsed" >&2
    for stage in "${failed_stages[@]}"; do
      printf '  - %s\n' "$stage" >&2
    done
  fi
  printf '════════════════════════════════════════════════════════════════════════════════\n'
}

# --- Stage 1: Flake Check --------------------------------------------------

if ci_have nix; then
  run_stage "Nix flake checks" \
    nix flake check
fi

# --- Stage 2: DUB Unit Tests (LDC) -----------------------------------------

if [ "$skip_tests" -eq 0 ]; then
  run_stage "Unit tests (LDC)" \
    env DC=ldc2 "${repo_root}/ci/run-batch.sh" 20m ci --test --fail-fast
fi

# --- Stage 3: DUB Unit Tests (DMD) -----------------------------------------

if [ "$skip_tests" -eq 0 ] && [ "$skip_dmd" -eq 0 ]; then
  if ci_have dmd; then
    run_stage "Unit tests (DMD)" \
      env DC=dmd "${repo_root}/ci/run-batch.sh" 20m ci --test --fail-fast
  else
    ci_notice "Skipping DMD test suite pass (dmd not found on PATH)"
  fi
fi

# --- Stage 4: Standalone Example Files -------------------------------------

if [ "$skip_examples" -eq 0 ]; then
  run_stage "Standalone example files" \
    "${repo_root}/ci/run-batch.sh" 20m ci --example-files --fail-fast
fi

# --- Stage 5: OS-API Windowing Examples ------------------------------------

if [ "$skip_examples" -eq 0 ] && [ "$(uname -s)" = "Linux" ]; then
  run_os_api_examples() {
    if ci_have xvfb-run; then
      xvfb-run -a dub run --compiler=ldc2 --root=docs/research/window-system-integration/os-apis/x11/example
    elif [ -n "${DISPLAY:-}" ]; then
      dub run --compiler=ldc2 --root=docs/research/window-system-integration/os-apis/x11/example
    else
      ci_notice "Skipping X11 OS-API example (neither xvfb-run nor DISPLAY available)"
    fi
    dub run --compiler=ldc2 --root=docs/research/window-system-integration/os-apis/wayland/example
    dub build --single --compiler=ldc2 docs/research/window-system-integration/cursor-shapes/cursor-shapes.d
  }

  run_stage "OS-API windowing examples (X11 + Wayland + cursor-shapes)" \
    run_os_api_examples
fi

# --- Stage 6: Extracted Test Modes (--better-c, --wasm) --------------------

if [ "$skip_tests" -eq 0 ]; then
  run_stage "Extracted test modes (--better-c, --wasm)" \
    env DC=ldc2 "${repo_root}/ci/run-batch.sh" 20m ci --test-extracted --fail-fast
fi

# --- Stage 7: Nix Desktop Build & Runnable Examples ------------------------

if [ "$skip_nix" -eq 0 ] && ci_have nix; then
  run_stage "Nix desktop packages (all-desktop)" \
    "${repo_root}/ci/run-batch.sh" 30m nix build --print-build-logs .#all-desktop

  if [ "$skip_examples" -eq 0 ]; then
    run_stage "Nix runnable examples" \
      "${repo_root}/ci/run-batch.sh" 20m nix run .#run-all-examples
  fi
fi

# --- Stage 8: Nix Android Build --------------------------------------------

if [ "$skip_nix" -eq 0 ] && [ "$skip_android" -eq 0 ] && ci_have nix; then
  # Android NDK/SDK in this repo is supported on x86_64-linux.
  if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ]; then
    run_stage "Nix Android APK closure (all-android)" \
      "${repo_root}/ci/run-batch.sh" 90m nix build --print-build-logs .#all-android
  fi
fi

# --- Stage 9: Lint & Pre-Commit Checks -------------------------------------

if [ "$skip_lint" -eq 0 ]; then
  if ci_have prek; then
    run_stage "Lint and local link checks" \
      env SKIP=verify-md-examples,lychee,no-commit-to-branch \
      "${repo_root}/ci/run-batch.sh" 35m prek run --all-files --show-diff-on-failure --color always
  else
    ci_notice "Skipping pre-commit lint (prek not found on PATH)"
  fi
fi

# --- Stage 10: Markdown Runnable Examples Verification ---------------------

if [ "$skip_examples" -eq 0 ] && ci_have nix; then
  run_stage "Markdown runnable examples verification" \
    "${repo_root}/ci/run-batch.sh" 35m nix run .#ci -- --verify --fail-fast --include-files '**.md' --exclude-files 'libs/syntax/test/data/**'
fi

# --- Stage 11: Documentation Site Build ------------------------------------

if [ "$skip_docs" -eq 0 ]; then
  if ci_have npm && [ -f "${repo_root}/package.json" ]; then
    run_stage "Documentation site build" \
      npm run docs:build
  else
    ci_notice "Skipping documentation build (npm not found on PATH or package.json absent)"
  fi
fi

# --- Final Summary ---------------------------------------------------------

print_summary
if [ "$failures" -gt 0 ]; then
  exit 1
fi
