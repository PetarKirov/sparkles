# `sparkles:code-instrumentation`

A **coverage ingestion library** for D. It reads the coverage artifacts five
different toolchains emit — DMD's `-cov` listings, GCC's `gcov`, LCOV `.info`
tracefiles, V8 block coverage from Node and Vitest, and `llvm-cov export`
JSON — into one data model, and plans the gutter decorations a viewer needs
to paint them.

Every parser reports failure the same way, as a
[`ParseExpected`](../base/index.md), so "I could not read this" is
distinguishable from "this describes nothing" — the distinction a caller
needs to warn about a broken artifact instead of silently rendering a file
with no coverage on it.

```d
import sparkles.code_instrumentation;

auto report = loadCoverage("build/cov/math.lst", readText("build/cov/math.lst"));
if (!report)
    stderr.writeln("unreadable at byte ", report.error.offset);
else if (auto file = report.value.findFile("src/math.d"))
    writeln(planCoverage(*file).summaryBanner);
```

## What it is not

It does not **produce** coverage. Instrumenting a build and running it is the
compiler's and the test runner's job; this library starts from the artifact
they leave behind.

It does not render, either. `planCoverage` returns a `CoveragePlan` — line
numbers, states, formatted counts — and a viewer decides what to do with it.
That separation is what lets one plan drive a terminal gutter, a GPU-rendered
window and an HTML export without the library knowing any of them exist.

## How this documentation is organised

These docs follow the [Diátaxis](https://diataxis.fr/) framework: four
sections, each answering a different kind of question. If you are not sure
where to start, read the tutorial.

### [Tutorial](./tutorial/getting-started.md)

Learning-oriented. Produce a real `.lst` from a `dub test` run, load it, and
print a per-line report — start to finish, with nothing assumed.

### [How-to guides](./how-to/handle-parse-failures.md)

Task-oriented, for when you know what you want.

- [Handle parse failures](./how-to/handle-parse-failures.md) — what the
  error codes mean and how to degrade instead of failing.
- [Match a report to a source file](./how-to/match-a-source-file.md) — why
  the paths rarely agree and what `findFile` does about it.

### [Reference](./reference/api.md)

Information-oriented: the data model, the supported formats, and the parsing
surface, described exactly.

### [Explanation](./explanation/format-quirks.md)

Understanding-oriented. [Why the parsers look the way they
do](./explanation/format-quirks.md) — the real-world quirks of each format,
each of which cost a defect before it was understood.
