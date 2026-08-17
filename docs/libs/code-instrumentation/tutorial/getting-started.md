# Getting started

By the end of this tutorial you will have produced a real coverage artifact,
loaded it, and printed which lines of your code ran and which did not.

## 1. Produce a listing

DMD and LDC both write `-cov` listings. `dub` exposes that as a build type:

```bash
dub test :versions -b unittest-cov
```

Each source file gets a `.lst` beside the binary, named after the module path
with `-` for each separator. Open one and you will see the shape:

```
       |module m;
      5|    return a + b;
0000000|    return a - b;
libs/x/src/math.d is 50% covered
```

Three kinds of line: a blank counter (no code emitted), a count, and
`0000000` for code that never ran. The trailer names the source the listing
describes — which matters, because it is the only place that appears.

## 2. Load it

`loadCoverage` picks the parser from the path's extension, falling back to the
contents. You never name a format.

The listing is inlined here so this page runs as written; in your own program
it is `readText(path)`.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "coverage_tutorial"
    dependency "sparkles:code-instrumentation" version="*"
+/

import std.stdio : writefln, writeln;

import sparkles.code_instrumentation;

void main()
{
    enum listing = "       |module math;\n"
        ~ "      5|    return a + b;\n"
        ~ "0000000|    return a - b;\n"
        ~ "libs/x/src/math.d is 50% covered\n";

    auto report = loadCoverage("build/cov/math.lst", listing);
    if (!report)
    {
        writeln("could not read it: ", report.error.context);
        return;
    }

    foreach (ref file; report.value.files)
    {
        writefln("%s — %.1f%% of %s coverable lines",
            file.sourcePath, file.linePercent, file.coverableLines);

        foreach (ref line; file.lines)
            if (line.state == LineState.uncovered)
                writefln("  line %s never ran", line.lineNumber);
    }
}
```

```[Output]
libs/x/src/math.d — 50.0% of 2 coverable lines
  line 3 never ran
```

## 3. Read the result

Three things are worth noticing about what came back.

**`lines` is not one entry per source line.** A `.lst` happens to describe
every line, but `.info`, `.gcov` and `llvm-cov` all describe a subset. Each
`LineCoverage` carries the `lineNumber` it belongs to; index by that, never
by array position.

**`sourcePath` came from the trailer**, not from the artifact's path. That is
what lets `findFile("src/math.d")` match a listing sitting in `build/cov/`.

**A failure is a value.** `loadCoverage` returns
`ParseExpected!CoverageReport`, so a truncated or malformed artifact gives
you an error with a byte offset rather than an empty report you would have to
guess about.

## 4. Plan a gutter

If you are rendering rather than reporting, `planCoverage` turns one file's
coverage into the decorations a viewer paints:

```d
const plan = planCoverage(report.value.files[0]);
writeln(plan.summaryBanner);          // Coverage: 50.0% (1/2 lines covered)

foreach (item; plan.gutterItems)
    writefln("%4s | line %s", item.countText, item.lineNumber);
```

`countText` is pre-formatted and bounded to four cells (`5`, `163k`, `2.5M`,
`>1T`), so a gutter sized to the counts it holds cannot be overrun.

## Where to go next

- [Handle parse failures](../how-to/handle-parse-failures.md) — degrade
  rather than fail when an artifact is stale or truncated.
- [Why the parsers look the way they do](../explanation/format-quirks.md) —
  the format quirks each one had to learn.
