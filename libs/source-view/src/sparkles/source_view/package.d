/**
`sparkles:source-view` — interactive code and markdown document widget views.

Builds $(MREF sparkles,ui) widget trees from syntax-highlighted code streams
and CommonMark AST documents, providing character-accurate selection, inline
tints, folds, line numbering, callouts, task lists, and scrollable tables.
*/
module sparkles.source_view;

public import sparkles.source_view.code;
public import sparkles.source_view.markdown;
public import sparkles.source_view.search;
