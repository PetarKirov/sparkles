#!/usr/bin/env bash
# Regenerate the committed fixtures/*.twoslash.json overlays from src/*.ts(x)
# using the reference TypeScript `twoslash`.
#
# DEVELOPER-ONLY. The sparkles build and `dub test` are hermetic and node-free;
# the outputs are committed so nothing downstream needs node. This is the single
# place node is invoked, and only when a developer refreshes the fixtures. The
# `twoslash` node model is opaque input to the D renderer, so any
# twoslash-compatible source (twoslash today, sparkles:dmd-lsp in the future)
# yields the same `{ code, nodes }` shape.
#
# Requires node + Yarn Berry (already on the docs-site toolchain; Node's
# Corepack is the fallback when `yarn` itself is not on PATH). Usage:
#
#   ./regen.sh                 # install deps (if needed) and regenerate
#
# To add an example: drop a twoslash-annotated `src/NN-name.ts(x)` file and rerun.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d node_modules/twoslash ]]; then
    echo "Installing fixture-generator deps (twoslash + typescript)…"
    if command -v yarn >/dev/null 2>&1; then
        yarn install
    else
        corepack yarn install
    fi
fi

node regen.mjs
