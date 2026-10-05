# Analyze Unicode text without allocation

Use `AnalysisWorkspace` when a matcher or index needs normalized units and
exact original source-byte contributor sets:

```d
import sparkles.base.text.analysis;

// Final units, segment units, intermediate units, provenance spans per bank.
AnalysisWorkspace!(256, 64, 1024, 4096) workspace;
auto result = analyzeText("A\u0308ffin",
    AnalysisOptions.codePath(AnalysisCase.simpleFold), workspace);
assert(result.succeeded);
assert(workspace.output[0].sourceStart == 0);
assert(workspace.output[0].sourceEnd == 3);
auto exact = workspace.contributingSourceSpans(workspace.output[0]);
assert(exact[0].start == 0);
```

`codePath` uses NFC and either sensitive or Unicode simple-fold comparison.
`generalLanguage` uses NFKC, full folding, mark removal, word segmentation,
and an optional immutable `StopwordLexicon`.

Malformed UTF-8 is not discarded: every invalid byte becomes a distinct opaque
unit with a one-byte source interval and terminates Unicode context.
Check `AnalysisResult.error` before consuming output. `outputFull`,
`segmentTooLong` and `workspaceFull` identify distinct storage limits; increase
the appropriate explicit capacity rather than assuming final capacity also
fits intermediate decomposition/expansion. Failure publishes no partial output.

Use `contributingSourceSpans` for highlighting: `sourceStart`/`sourceEnd`
are only an enclosing envelope and can include unrelated reordered marks.
Read `workspace.deletions` when removed marks or stopwords matter to inverse
mapping. Output, contributor and deletion slices borrow workspace storage and
are invalidated by the next analysis call. Keep an immutable stopword lexicon
alive during analysis and include its revision in external cache identities.

For standalone normalization, casing, paragraph bidi or typed coordinate maps,
import the corresponding owned module directly. See the
[reference](../reference/unicode-analysis.md) for arena requirements and lifetimes.
