/**
The tree-sitter precise-mode engine of `sparkles:syntax`.

Grammar discovery ($(MREF sparkles,syntax,ts,registry)), per-language
highlight configuration ($(MREF sparkles,syntax,ts,config)), text-predicate
evaluation ($(MREF sparkles,syntax,ts,predicates)), injection discovery
($(MREF sparkles,syntax,ts,injection)), and the event-producing highlighter
($(MREF sparkles,syntax,ts,highlighter)) — a port of the reference
`tree-sitter-highlight` semantics (single-language `highlight` and injection-
aware `highlightInjected`) over the `sparkles:tree-sitter` binding.

This module only re-exports — unittests live with the features.
*/
module sparkles.syntax.ts;

public import sparkles.syntax.ts.config;
public import sparkles.syntax.ts.highlighter;
public import sparkles.syntax.ts.injection;
public import sparkles.syntax.ts.predicates;
public import sparkles.syntax.ts.registry;

// the binding's error vocabulary — every engine API speaks it
public import sparkles.tree_sitter.errors : TsError, TsErrorCode, TsExpected;
