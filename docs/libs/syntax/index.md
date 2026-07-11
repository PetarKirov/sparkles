# `sparkles:syntax`

Syntax highlighting with pluggable engines and backends: token producers
emit one engine-agnostic **highlight-event stream**; a scope-compatible
**label vocabulary** and a **theme layer** resolve labels to styles; and
rendering backends fold the stream into **ANSI** (like `bat`) or **HTML**
(like Shiki) — or consume styled runs directly as data. The first engine is
the **tree-sitter precise mode**: whole-buffer CST + `highlights.scm`
queries, grammars supplied by the Nix `ts-grammars` bundle.

```d
import std.array : appender;
import sparkles.syntax;

// configure once per language …
const labels = LabelSet.standard();
auto registry = GrammarRegistry.fromEnvironment(); // $SPARKLES_TS_GRAMMAR_PATH
auto grammar = registry.grammar("d");
TsError error;
auto config = TsHighlightConfig.create(
    grammar.value, registry.queryText("d").value, error);
config.configure(labels);

// … highlight any number of buffers …
auto events = appender!(HighlightEvent[]);
auto result = highlight(config, source, events);

// … and fold the same events into either backend
auto ansi = appender!string;
renderAnsi(source, events[], resolveTheme(builtinDark, labels), ansi);
```

Any engine failure is an `Expected` error value — the caller renders plain
text instead (a highlighter's worst legal output is uncolored text, never a
crash). The runnable version of this pipeline is
[`libs/syntax/examples/highlight-file.d`][example].

## How this documentation is organised

### [Tutorial](./tutorial/getting-started.md)

- [Getting started](./tutorial/getting-started.md) — highlight a file to the
  terminal and to HTML, end to end.

### Reference

- [The core](./reference/core.md) — events, labels, colors, themes, and the
  two renderers.
- [The tree-sitter engine](./reference/engine.md) — grammar registry,
  highlight configuration, predicates, guards, and error codes.

### Explanation

- [The design](./explanation/design.md) — why an event-stream seam, and how
  the pieces map to the surveyed prior art.

## See also

- The [design proposal](../../specs/syntax/index.md) and
  [delivery plan](../../specs/syntax/PLAN.md) in `docs/specs/syntax/`.
- The research this library reifies:
  [the syntax-highlighting cluster](../../research/parsing/syntax-highlighting.md)
  of the parsing survey.

<!-- References -->

[example]: https://github.com/PetarKirov/sparkles/blob/main/libs/syntax/examples/highlight-file.d
