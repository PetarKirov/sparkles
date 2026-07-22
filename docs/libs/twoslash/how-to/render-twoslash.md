# How to render a twoslash payload

You have a TypeScript `twoslash` JSON payload (a `TwoslashReturn`: its trimmed
`code` plus a flat `nodes` array). This guide renders it as a type-annotation
overlay in the terminal, as HTML, and in the raylib GUI.

## With `hue`

`hue --twoslash <nodes.json>` is the ready-made driver. The JSON's own `code` field
is the source; hue highlights it as TypeScript and overlays the nodes.

```bash
# ANSI (terminal) — the default
hue --twoslash payload.twoslash.json

# HTML — a self-contained <style> + <pre class="syn-root twoslash">…</pre>
hue --twoslash --html payload.twoslash.json > out.html

# raylib GUI window (requires the gui build: dub build :hue -c gui)
hue --gui --twoslash payload.twoslash.json
```

Committed sample payloads live under
`libs/twoslash/examples/fixtures/*.twoslash.json`.

## From D

```d
import sparkles.twoslash;
import sparkles.syntax;

// 1. Decode the payload (opaque node data — any twoslash-compatible source).
auto res = loadTwoslashFile("payload.twoslash.json");
if (res.hasError) { /* res.error.msg */ }
const tw = res.value;

// 2. Highlight the display source as TypeScript.
const labels = LabelSet.standard();
const theme  = resolveTheme(builtinDark, labels);
auto registry = GrammarRegistry.fromEnvironment();
auto cache    = TsConfigCache.create(&registry, labels);
SmallBuffer!HighlightEvent events;
if (highlightInjected(cache, "typescript", tw.code, events).hasError)
    events ~= HighlightEvent.sourceSpan(0, tw.code.length); // plain-text fallback

// 3a. HTML overlay (content only — wrap it yourself).
SmallBuffer!char html;
html ~= `<style>`;
writeThemeStylesheet(theme, html);  // syntax token colors (.syn-*)
writeTwoslashStyles(html);          // the .twoslash-* chrome
html ~= `</style><pre class="syn-root twoslash"><code>`;
renderTwoslashHtml(tw, events[], theme, cache, html);
html ~= `</code></pre>`;

// 3b. ANSI overlay.
SmallBuffer!char ansi;
renderTwoslashAnsi(tw, events[], theme, cache, ansi,
    TwoslashAnsiOptions(depth: detectColorDepth()));
```

## Notes

- The popup type signatures are re-highlighted by re-entering `sparkles:syntax` as
  TypeScript, so the TypeScript grammar must be in the bundle
  (`$SPARKLES_TS_GRAMMAR_PATH`). Without it the overlay still renders — the
  signatures just fall back to plain text.
- The node array is **opaque**: it is decoupled from how it was produced (TypeScript
  `twoslash` today, `sparkles:dmd-lsp` in the future).
