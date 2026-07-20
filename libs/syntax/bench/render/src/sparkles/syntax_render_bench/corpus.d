/++
Frozen benchmark corpus + the parse-once setup shared by every case.

The corpus files under `corpus/` are string-imported (deterministic,
cwd-independent — the test binary's cwd differs from the repo root). Each is a
real source file; `sized` takes the first `lines` lines to simulate a terminal
viewport of a given height (the app renders only the visible slice per frame).

`parse` runs the full tree-sitter precise pipeline (grammar from
$SPARKLES_TS_GRAMMAR_PATH) exactly as `apps/hue` does, returning the cached
`HighlightEvent[]`. Parsing is done once per case in untimed `setup`; the timed
body only re-renders that event stream — which is precisely the app's
theme-switch hot path (parse once, re-render per theme).
+/
module sparkles.syntax_render_bench.corpus;

import std.array : appender;

import sparkles.syntax.event : HighlightEvent;
import sparkles.syntax.label : LabelSet;
import sparkles.syntax.ts.registry : GrammarRegistry, canonicalLanguage;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.syntax.ts.highlighter : highlightInjected;

/// One corpus entry: a language tag (canonicalized on use) and its source.
struct Corpus
{
    string lang; /// language tag, e.g. "d", "python", "typescript"
    string source; /// the full frozen file
}

/// The frozen corpora, string-imported at compile time.
immutable Corpus[] corpora = [
    Corpus("d", import("sample.d")),
];

/// `corpus` truncated to its first `lines` lines (a viewport slice). `0` =
/// the whole file.
string sized(string corpus, size_t lines) @safe pure nothrow
{
    if (lines == 0)
        return corpus;
    size_t seen = 0;
    foreach (i, char c; corpus)
        if (c == '\n' && ++seen == lines)
            return corpus[0 .. i + 1];
    return corpus;
}

/// Parse `source` through the tree-sitter precise pipeline, returning the
/// highlight-event stream (or a single passthrough span when no grammar is
/// available). Runs once per case, untimed. `@system` (the highlighter is —
/// it threads scope pointers through the ImportC boundary) and allocating (the
/// event buffer, which is the point: the timed body reuses it).
HighlightEvent[] parse(string lang, string source, LabelSet labels) @system
{
    auto events = appender!(HighlightEvent[]);
    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, labels);
    auto res = highlightInjected(cache, canonicalLanguage(lang), source, events);
    if (res.hasError)
        events ~= HighlightEvent.sourceSpan(0, source.length);
    return events[];
}
