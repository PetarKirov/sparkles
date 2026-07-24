/**
`sparkles:syntax` — syntax highlighting with pluggable engines and backends.

Token producers (the tree-sitter precise engine; a TextMate-style line engine
later) emit one engine-agnostic highlight-event stream
($(MREF sparkles,syntax,event)); a scope-compatible label vocabulary
($(MREF sparkles,syntax,label)) and a theme layer resolve labels to styles;
rendering backends fold the stream into ANSI or HTML — or consume styled runs
directly as data.

Design: `docs/specs/syntax/` (proposal + delivery plan), grounded in the
`docs/research/parsing/` syntax-highlighting cluster.

This module only re-exports the feature modules — unittests live with the
features (the runner does not discover tests in `package.d`).
*/
module sparkles.syntax;

public import sparkles.syntax.color;
public import sparkles.syntax.event;
public import sparkles.syntax.label;
public import sparkles.syntax.md.model;
public import sparkles.syntax.md.render_html;
public import sparkles.syntax.render.ansi;
public import sparkles.syntax.render.html;
public import sparkles.syntax.theme;
public import sparkles.syntax.themes;
public import sparkles.syntax.ts;
