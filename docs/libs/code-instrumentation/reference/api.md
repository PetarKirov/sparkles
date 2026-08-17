# API reference

## Data model

`sparkles.code_instrumentation.coverage.model`

| Type               | Holds                                                            |
| ------------------ | ---------------------------------------------------------------- |
| `LineState`        | `nonCode`, `uncovered`, `covered`, `partial`                     |
| `LineCoverage`     | one line: number, execution count, state, branches taken / total |
| `SpanCoverage`     | a byte range (`TextSpan`) with its own count — sub-line, from V8 |
| `FunctionCoverage` | a named function's start line and count                          |
| `FileCoverage`     | one file: its lines, spans, functions and totals                 |
| `CoverageSummary`  | totals aggregated across files                                   |
| `CoverageReport`   | the files a single artifact describes                            |

`LineState.partial` means the line ran but not every path out of it — some
branch untaken (LCOV, gcov) or a nested block that never executed (V8).

### Conventions

- **Line numbers are 1-based.** `lines` is _not_ indexed by line: only a DMD
  `.lst` describes every line. Use `FileCoverage.lineAt(n)`, and read `null`
  as "not described" rather than "not covered".
- **An empty denominator reads as 100%.** `linePercent` on a file with no
  coverable lines is `100.0`; a module that emits no code is fully covered,
  not zero percent. `branchPercent` follows the same rule.
- **`totalLines`** is the file's physical line count where the format states
  it, and the highest line it describes where it does not.

## Loading

`sparkles.code_instrumentation.coverage.ingest`

```d
ParseExpected!CoverageReport loadCoverage(
    const(char)[] path, const(char)[] contents, const(char)[] sourceText = null);
```

Detects the format and dispatches. `sourceText` is used only by V8, which
records byte offsets rather than line numbers.

```d
CoverageFormat detectFormat(const(char)[] path, const(char)[] contents);
CoverageFormat formatFromExtension(const(char)[] path);
```

`formatFromExtension` consults only the extension. Prefer it when deciding
whether to _act_ on a file — an extension is a statement by whoever produced
it, where a content match is a guess about a file someone asked to view.

## Formats

Each parser is also callable directly.

| Format       | Entry point           | Notes                                      |
| ------------ | --------------------- | ------------------------------------------ |
| DMD `-cov`   | `parseDmdCoverage`    | one file per listing; trailer names it     |
| gcov         | `parseGcovCoverage`   | `-b` branch annotations attach by position |
| LCOV `.info` | `parseLcovCoverage`   | many files; records joined by line number  |
| V8 / Vitest  | `parseV8Coverage`     | needs `sourceText` for line mapping        |
| `llvm-cov`   | `parseLlvmExportJson` | honours `hasCount` and gap-region flags    |

## Overlay planning

`sparkles.code_instrumentation.coverage.overlay`

```d
CoveragePlan planCoverage(in FileCoverage file);
string formatCount(LineState state, ulong count);
enum size_t maxCountWidth = 4;
```

`CoveragePlan.gutterItems` carries one item per _described_ line, each with
its `lineNumber`. `countText` is pre-formatted and never exceeds
`maxCountWidth` cells, so a gutter sized to its contents cannot overrun.

## Record scanning

`sparkles.code_instrumentation.coverage.record` — `@safe pure nothrow @nogc`,
and the shared basis of the three textual formats.

```d
struct RecordScanner;                                   // lines + byte offsets
Halves splitOnce(const(char)[] s, char separator);
size_t splitFields(const(char)[] s, char sep, scope const(char)[][] fields,
                   scope size_t[] starts = null);
ParseExpected!ulong wholeNumber(const(char)[] field, size_t offset);
const(char)[] trimmed(const(char)[] s);
```

`wholeNumber` requires the field to be _entirely_ digits. That is the whole
point of it: a reader that skips non-digits turns `3,f1ab29d0` into 31290.
