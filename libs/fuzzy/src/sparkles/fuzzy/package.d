/**
`sparkles:fuzzy` — bounded fuzzy query, matching, ranking, and history.

Feature modules carry the implementation and tests; this package module only
re-exports the public surface.
*/
module sparkles.fuzzy;

public import sparkles.fuzzy.common;
public import sparkles.fuzzy.glob;
public import sparkles.fuzzy.history;
public import sparkles.fuzzy.match;
public import sparkles.fuzzy.query;
public import sparkles.fuzzy.rank;
public import sparkles.fuzzy.search;
