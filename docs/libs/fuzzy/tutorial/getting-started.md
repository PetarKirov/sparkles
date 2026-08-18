# Build a small fuzzy file search

Add `sparkles:fuzzy` as a DUB dependency, then parse the prompt once and reuse
one matcher workspace for every candidate:

```d
import sparkles.fuzzy;

auto parsed = parseQuery(`app ext:d`);
assert(parsed.hasValue);

MatcherWorkspace!() workspace;
CandidateView candidate;
candidate.id.low = 1;
candidate.path = "src/app.d";
candidate.filenameOffset = 4;

auto result = match(parsed.value, candidate, workspace);
assert(result.hasValue && result.value.admitted);
assert(result.value.score > 0);

TextRange[16] highlights;
auto count = positions(parsed.value, candidate, MatchConfig.init,
    FuzzyLimits.init, workspace, highlights);
assert(count.hasValue);
```

`QueryStorage` borrows the prompt, and `CandidateView` borrows the path. Keep
both byte buffers alive and unchanged for the whole operation. Each worker
needs its own `MatcherWorkspace`; workspaces are deliberately not synchronized.

The default `codePath` profile is NFC with smart case. Use
`QueryParseOptions.profile = AnalysisProfile.generalLanguage()` for NFKC,
full folding, accent removal, and optional caller-owned stopwords.
