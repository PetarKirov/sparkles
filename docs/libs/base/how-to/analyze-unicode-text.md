# Analyze Unicode text without allocation

Use `AnalysisWorkspace` when a matcher or index needs normalized units plus
their original source-byte ranges:

```d
import sparkles.base.text.analysis;

AnalysisWorkspace!(256, 64) workspace;
auto result = analyzeText("A\u0308ffin",
    AnalysisOptions.codePath(AnalysisCase.simpleFold), workspace);
assert(result.succeeded);
assert(workspace.output[0].sourceStart == 0);
assert(workspace.output[0].sourceEnd == 3);
```

`codePath` uses NFC and either sensitive or Unicode simple-fold comparison.
`generalLanguage` uses NFKC, full folding, mark removal, word segmentation,
and an optional immutable `StopwordLexicon`.

Malformed UTF-8 is not discarded: every invalid byte becomes a distinct opaque
unit with a one-byte source interval. Check `AnalysisResult.error` before
consuming output. `outputFull` and `segmentTooLong` mean the caller must choose
larger compile-time capacities; analysis never truncates silently.
