# Match a report to a source file

The path inside a coverage artifact rarely matches the path you have in hand.
A listing written from the repository root says `libs/x/src/math.d`; the
viewer opened `/home/me/repo/libs/x/src/math.d`; an LCOV tracefile from CI
may say either. `CoverageReport.findFile` resolves that.

```d
auto report = loadCoverage(artifactPath, contents);
if (auto file = report.value.findFile(documentPath))
    attach(planCoverage(*file));
```

## What it matches

1. **Exact equality** first.
2. **Whole-component suffix**, in either direction — `src/m.d` matches
   `/repo/src/m.d`, and `/repo/src/m.d` matches a report that only recorded
   `src/m.d`.

The boundary matters: `m.d` does _not_ match `stream.d`, because the match
must begin at a path separator. Both `/` and `\` count, so a report produced
on Windows still resolves.

An empty path never matches anything. That sounds obvious, but a DMD listing
with no trailer leaves `sourcePath` empty, and a suffix test that accepted it
would make that one record answer every lookup.

## When it returns `null`

`null` means the report does not describe that file — usually because the
artifact is for a different file entirely. Treat it as "no coverage
available" and render plainly.

Resist the temptation to fall back to "if the report has exactly one file,
use that one". A single-file report is the common case for `.lst`, so the
fallback looks harmless, and then every file you browse to inherits the
coverage of whichever artifact is attached.
