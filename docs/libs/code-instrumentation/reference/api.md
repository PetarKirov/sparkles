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
    const(char)[] path, const(char)[] contents,
    scope V8SourceResolver resolveSource = null,
    scope V8ScriptSelector selectScript = null) @safe;
```

Detects the format and dispatches. The resolver and selector are used only by
V8; other formats do not need source snapshots. Import their types from
`sparkles.code_instrumentation.coverage.formats.v8`.

```d
CoverageFormat detectFormat(const(char)[] path, const(char)[] contents);
CoverageFormat formatFromExtension(const(char)[] path);
```

`formatFromExtension` consults only the extension. Prefer it when deciding
whether to _act_ on a file — an extension is a statement by whoever produced
it, where a content match is a guess about a file someone asked to view.

## Formats

Each parser is also callable directly.

| Format       | Entry point           | Notes                                          |
| ------------ | --------------------- | ---------------------------------------------- |
| DMD `-cov`   | `parseDmdCoverage`    | one file per listing; trailer names it         |
| gcov         | `parseGcovCoverage`   | `-b` branch annotations attach by position     |
| LCOV `.info` | `parseLcovCoverage`   | many files; records joined by line number      |
| V8 / Vitest  | `parseV8Coverage`     | resolves each selected original UTF-8 snapshot |
| `llvm-cov`   | `parseLlvmExportJson` | honours `hasCount` and gap-region flags        |

### V8 source snapshots and script selection

`sparkles.code_instrumentation.coverage.formats.v8`

```d
alias V8SourceResolver = ParseExpected!(const(char)[]) delegate(
    const(char)[] scriptPath) @safe;
alias V8ScriptSelector = bool delegate(const(char)[] scriptPath) @safe;

ParseExpected!CoverageReport parseV8Coverage(
    const(char)[] jsonText, scope V8SourceResolver resolveSource,
    scope V8ScriptSelector selectScript = null) @safe;
```

The resolver receives a normalized script path (`file://` URLs become file
paths) once per selected script. It returns a **borrowed original UTF-8
snapshot**, which the caller must keep alive and unchanged throughout the
parse. The slice type is `const(char)[]`; it does not freeze other mutable
aliases. The parser does not fetch sources or substitute the displayed file
for every script. A missing snapshot must return a parse error; a successful
empty slice means a genuinely empty source.

The optional selector runs **before source resolution**. Null selects every
script; false excludes that script from both resolution and the returned
report. For example, an artifact with `/src/a.js` and `/src/b.js` can resolve
two distinct snapshots, or explicitly project only `/src/a.js`:

```d
import sparkles.base.text.errors : ParseErrorCode, parseErr, parseOk;
import sparkles.code_instrumentation.coverage.formats.v8 :
    parseV8Coverage, V8SourceResolver, V8ScriptSelector;

immutable string sourceA = "A😀\n界B\n";
immutable string sourceB = "let b = 1;\n";
V8SourceResolver resolve = (const(char)[] scriptPath) @safe {
    if (scriptPath == "/src/a.js")
        return parseOk(cast(const(char)[]) sourceA);
    if (scriptPath == "/src/b.js")
        return parseOk(cast(const(char)[]) sourceB);
    return parseErr!(const(char)[])(ParseErrorCode.unknownValue, 0,
        "original source snapshot unavailable");
};
auto allScripts = parseV8Coverage(jsonText, resolve);
V8ScriptSelector onlyA = (const(char)[] scriptPath) @safe {
    return scriptPath == "/src/a.js";
};
auto selected = parseV8Coverage(jsonText, resolve, onlyA);
// Universal ingestion accepts the same resolver and selector:
// auto selected = loadCoverage("coverage.json", jsonText, resolve, onlyA);
```

`jsonText` is the producer's artifact, not reconstructed source. Its
`startOffset` and `endOffset` are native **UTF-16 code-unit coordinates**.
For `sourceA`, `[4, 6)` maps exactly to original UTF-8 bytes `[6, 10)`
(`界B` on line 2); the supplementary `😀` occupies two UTF-16 units but four
UTF-8 bytes. Returned `SpanCoverage.span` values are always UTF-8 byte ranges.

Each selected snapshot is strictly validated in full, including suffixes
outside covered ranges, then mapped once for all its ranges. Malformed
UTF-8, surrogate-interior boundaries, inverted or out-of-range offsets, and
byte spans exceeding `TextSpan` capacity reject the parse with structured
errors. No invalid ranges are silently skipped, clamped, or mapped through
replacement text. See [Handle parse failures](../how-to/handle-parse-failures.md)
for error-coordinate details.

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
