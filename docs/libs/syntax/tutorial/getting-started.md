# Getting started

This walkthrough highlights a D file to the terminal and to HTML. It needs
the grammar bundle on the environment — inside the repo's `nix develop`
shell, `$SPARKLES_TS_GRAMMAR_PATH` is already exported; outside it, every
grammar lookup returns an error and your program should fall back to plain
text.

## 1. Configure a language (once)

```d
import sparkles.syntax;

const labels = LabelSet.standard();          // the canonical vocabulary
auto registry = GrammarRegistry.fromEnvironment();

auto grammar = registry.grammar("d");        // dlopen + ABI check, cached
auto query = registry.queryText("d");        // the bundled highlights.scm
if (grammar.hasError || query.hasError)
    return renderPlain(source);              // totality: your fallback

TsError error;
auto config = TsHighlightConfig.create(grammar.value, query.value, error);
if (error)
    return renderPlain(source);
config.configure(labels);                    // capture names → LabelIds
```

`TsHighlightConfig` is built once per (language, vocabulary) and reused for
every buffer. Unsupported query predicates disable their one pattern and
land in `config.warnings` — the language still highlights.

## 2. Highlight a buffer

```d
import std.array : appender;

auto events = appender!(HighlightEvent[]);
auto result = highlight(config, source, events);
if (result.hasError)                         // timeout, size cap, …
    return renderPlain(source);
```

`highlight` parses the whole buffer and walks the query captures into a
stream of `source`/`push`/`pop` events. Guards are named-argument options:

```d
highlight(config, source, events, HighlightOptions(
    parseBudget: 100.msecs,   // default 500 ms
    maxSourceBytes: 4 << 20,  // default 512 MiB
));
```

## 3. Render — ANSI

```d
const theme = resolveTheme(builtinDark, labels);   // once per theme

auto ansi = appender!string;
renderAnsi(source, events[], theme, ansi,
    AnsiOptions(depth: detectColorDepth()));       // $COLORTERM/$TERM tier
write(ansi[]);
```

Every output line is independently valid: styles reset before each newline
and re-open after it, so the output survives paging and line-wise slicing.

## 4. Render — HTML

```d
auto html = appender!string;
html ~= "<style>";
writeThemeStylesheet(theme, html);                 // .syn-* rules
html ~= "</style><pre><code>";
renderHtml(source, events[], theme, html,
    HtmlOptions(mode: HtmlMode.cssClasses));
html ~= "</code></pre>";
```

`inlineStyles` mode needs no stylesheet (`style="color:#…"` per span);
`cssClasses` maps labels to class names (`string.special.key` →
`syn-string-special-key`).

## The whole program

[`libs/syntax/examples/highlight-file.d`][example] is this tutorial as a
runnable script — `dub run --single highlight-file.d` inside the devshell
highlights its own source; `--html` switches backends.

<!-- References -->

[example]: https://github.com/PetarKirov/sparkles/blob/3cc01cfdc8ae867f0558e43c731885a004cb0130/libs/syntax/examples/highlight-file.d
