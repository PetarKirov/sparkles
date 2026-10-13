# The site build, as a `ci` dev-shell step. The generators under
# docs/scripts would `nix build` their tools from the flake; here the tools are
# this step's own inputs, so they are store paths in the step's closure — and
# a change to any of them is a change to the step.
t:
let
  p = t.packages;
in
''
  export SPARKLES_HUE=${p.hue}/bin/hue
  export SPARKLES_TWOSLASH_EXTRACT=${p.twoslash-extract}/bin/twoslash-extract
  export SPARKLES_TS_GRAMMAR_PATH=${p.ts-grammars}
  export SPARKLES_TABLE_WASM=${p.table-wasm}
  export SPARKLES_CREDITS=${p.credits}

  yarn install --immutable
  # The build sits just under node's default ~4 GB heap.
  NODE_OPTIONS=--max-old-space-size=8192 yarn docs:build
''
