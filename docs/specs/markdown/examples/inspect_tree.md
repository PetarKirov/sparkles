# Inspect Tree Example Plan

## Goal

Add a runnable example app under `libs/markdown/examples` that behaves like existing Sparkles examples and prints a compact, inspect-focused AST tree for markdown input.

The output should feel similar in intent to NeoVim/tree-sitter `InspectTree`: node-kind-first, terse metadata, and obvious parent/child structure.

## Scope

1. Provide one single-file Dub example script: `libs/markdown/examples/inspect_tree.d`.
2. Input source is either `--input FILE` (preferred when provided) or stdin when omitted.
3. Parse with the current public markdown API (`parse`) and current `AstNode` model.
4. Render tree output via `sparkles.core_cli.ui.tree_view`.
5. Keep output concise and stable for manual debugging use.

## Out Of Scope

1. New parser grammar or AST schema changes.
2. New markdown feature completeness work (CommonMark/VitePress/Nextra parity remains separate).
3. Full interactive TUI behavior.

## CLI Contract

1. `inspect_tree.d --input FILE`
2. `inspect_tree.d --input=FILE`
3. `inspect_tree.d -i FILE`
4. `inspect_tree.d --help` or `-h`

Behavior:

1. Unknown argument or missing `--input` value prints usage to stderr and exits non-zero.
2. File read failures return non-zero with a readable error.
3. Parsing diagnostics are shown after tree output (stderr), and process exits non-zero when error diagnostics are present.

## Output Model

Each tree node label should be:

1. `AstKind` name.
2. Optional compact detail list in square brackets.

Detail selection should prioritize high-signal fields only:

1. Heading level.
2. List block shape (`ordered`/`unordered`, start number, loose/tight).
3. Task list state on list items.
4. Link destination/title.
5. Heading/custom identifiers where available.
6. Fence info/language hints where available.
7. Small escaped preview of literal payload for text-like nodes.

Literal preview rules:

1. Escape `\\`, `"`, `\n`, `\r`, `\t`.
2. Truncate to a fixed max length with `...`.
3. Show only on selected node kinds (text/code/html/math/MDX literal carriers).

## Rendering Strategy

1. Convert `AstNode` recursively to a minimal view model:
   `struct InspectNode { string label; InspectNode[] children; }`.
2. Use `drawTree(..., TreeViewProps!void(useColors: false))` for deterministic output.
3. Emit exactly one tree to stdout.

## Implementation Steps

1. Create `libs/markdown/examples/inspect_tree.d` with embedded Dub metadata.
2. Implement argument parsing and usage text.
3. Implement file/stdin input loading.
4. Parse markdown and map AST nodes to inspect labels.
5. Render via `tree_view` and print diagnostics/exit code.
6. Mark script executable.

## Validation

1. Build/run help path:
   `dub run --root <repo> --single libs/markdown/examples/inspect_tree.d -- --help`
2. Validate stdin mode with a small inline sample.
3. Validate `--input` mode with a fixture file.

## Acceptance Criteria

1. Example compiles and runs in the current repository layout.
2. Output is compact and readable for quick AST inspection.
3. No dependency on unimplemented future parser features.
4. Works with existing markdown package registration and public APIs.
