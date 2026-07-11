/**
`sparkles:tree-sitter` — D bindings for the tree-sitter C runtime.

Three layers, re-exported here: the raw ImportC surface
(`sparkles.tree_sitter.tree_sitter_c`, the whole `tree_sitter/api.h`), RAII
wrappers with `TsError`-based failure reporting
(`sparkles.tree_sitter.wrappers`), and grammar dlopen
(`sparkles.tree_sitter.loader`). Highlighting policy lives in
`sparkles:syntax` (`sparkles.syntax.ts`).

This module only re-exports — unittests live with the features (the runner
does not discover tests in `package.d`).
*/
module sparkles.tree_sitter;

public import sparkles.tree_sitter.errors;
public import sparkles.tree_sitter.loader;
public import sparkles.tree_sitter.tree_sitter_c;
public import sparkles.tree_sitter.wrappers;
