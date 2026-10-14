# The relative cost, in seconds, of `dub test :<pkg>` (both legs, dependency
# closure included), for balancing the static test shards.
#
# Measured on the sharded, uncovered legs of CI run 33956387221 (2026-09-05),
# taking each package's slowest leg — so a package heavy anywhere is kept in a
# small shard. A package missing here weighs a typical library (10). Refresh
# when the ORDER of the costs changes, not when the numbers drift.
{
  "hue" = 210;
  "twoslash-extract" = 126;
  "dmd-lsp" = 84;
  "dmd-fmt" = 81;
  "release" = 78;
  "ci" = 72;
  "docs" = 67;
  "terminal" = 66;
  "ui-gallery" = 65;
  "diagram" = 60;
  "terminal-benchmark" = 54;
  "base" = 53;
  "ui" = 43;
  "ui-raylib" = 27;
  "tui" = 26;
  "core-cli" = 26;
  "wired" = 24;
  "tree-sitter" = 24;
  "test-utils" = 23;
  "ui-app" = 22;
  "twoslash-d" = 22;
  "dql" = 22;
  "diff" = 20;
  "syntax" = 16;
  "dsv" = 15;
  "test-runner-impl" = 14;
  "fuzzy" = 14;
  "raylib-text" = 13;
  "input" = 13;
  "twoslash" = 12;
  "source-view" = 12;
  "ui-sdl3" = 11;
  "terminal-view" = 9;
  "event-horizon" = 8;
  "versions" = 7;
  "ui-tui" = 7;
  "vulkan-wsi" = 6;
  "http" = 6;
  "code-instrumentation" = 6;
  "wsi" = 5;
  "vulkan" = 5;
  "twoslash-protocol" = 5;
  "test-runner" = 3;
  "math" = 2;
  "ghostty" = 2;
  "build-primitives" = 2;
  "reflection" = 1;
  "metadata" = 1;
}
