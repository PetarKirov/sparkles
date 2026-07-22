#!/usr/bin/env bash
# Regenerate the committed *.twoslash.json fixtures from *.ts sources using the
# real TypeScript `twoslash`. DEVELOPER-ONLY — never run at build or test time
# (the sparkles build is hermetic and node-free; these fixtures are committed so
# `dub test` / `hue --twoslash` need no node dependency).
#
# The fixtures here were captured from the upstream twoslash test corpus
# (https://github.com/twoslashes/twoslash, packages/twoslash/test/results),
# reduced to the { code, nodes } slice the renderer consumes. To refresh or add
# one from your own snippet:
#
#   npx twoslash < input.ts        # or use the twoslash Node API
#
# then keep only the top-level `code` and `nodes` keys, e.g. with jq:
#
#   npx twoslash ... | jq '{code, nodes}' > name.twoslash.json
#
# The overlay treats `nodes` as opaque input, so any twoslash-compatible source
# (twoslash, twoslash-vue, or the future sparkles:dmd-lsp backend) works.
set -euo pipefail
echo "This is a documentation stub — see the comment above. No automatic regen" \
     "is wired, on purpose (the build stays node-free)."
