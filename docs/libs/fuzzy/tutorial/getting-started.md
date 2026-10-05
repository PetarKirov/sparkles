# Build a small fuzzy file search

Add `sparkles:fuzzy` as a DUB dependency, then parse the prompt once and reuse
one matcher workspace for every candidate:

```d
import sparkles.fuzzy;

auto workspace = new MatcherWorkspace!();
auto parsed = parseQuery(`app ext:d`, workspace.textWorkspace);
assert(parsed.hasValue);

CandidateView candidate;
candidate.id.low = 1;
candidate.path = "src/app.d";
candidate.filenameOffset = 4;

auto result = match(parsed.value, candidate, *workspace);
assert(result.hasValue && result.value.admitted);
assert(result.value.score > 0);

TextRange[16] highlights;
auto count = positions(parsed.value, candidate, MatchConfig.init,
    FuzzyLimits.init, *workspace, highlights);
assert(count.hasValue);
```

`QueryStorage` borrows the prompt, and `CandidateView` borrows the path. Keep
both byte buffers alive and unchanged for the whole operation. Each worker
needs its own `MatcherWorkspace`; workspaces are deliberately not synchronized.
Allocate the workspace once, before interactive parsing. `textWorkspace` exposes
its reusable Unicode scratch: parsing finishes before matching overwrites that
scratch, while `QueryStorage` retains only its own bounded data and prompt borrow.
The default matcher is about 13.1 MiB on x86-64; do not put it on a worker stack.

The default `codePath` profile is NFC with smart case. Use
`QueryParseOptions.profile = AnalysisProfile.generalLanguage()` for NFKC,
full folding, accent removal, and optional caller-owned stopwords.
