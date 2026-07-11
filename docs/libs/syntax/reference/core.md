# Reference — the core

The engine-agnostic middle of `sparkles:syntax`: what engines produce, what
themes resolve, and what renderers consume. Everything here is pure D over
`sparkles:base`; nothing depends on tree-sitter.

## Events (`sparkles.syntax.event`)

| Symbol                    | What it is                                                                                  |
| ------------------------- | ------------------------------------------------------------------------------------------- |
| `LabelId`                 | `ushort` index into a `LabelSet`; `LabelId.none` = unlabeled                                |
| `HighlightEvent`          | flat POD: `kind ∈ {source, push, pop}`, byte offsets `start`/`end` (source), `label` (push) |
| `isHighlightEventRange!R` | the concept both engines target and both renderers accept                                   |
| `StyledSpan`              | a maximal run with one resolved label (innermost wins)                                      |
| `byStyledSpan(events)`    | lazy flatten of the event stream into `StyledSpan`s                                         |

The **stream contract**: events are ordered; `source` ranges ascend without
overlapping; `push`/`pop` are balanced and never split a `source` span; the
stream is **infallible** — engine errors surface around the stream, never in
it, so renderers are total.

`byStyledSpan`, `StyledSpan`, and `ResolvedTheme` are the third-backend
contract: a consumer that wants styled runs as _data_ (a GPU text renderer,
a paginator) folds these instead of parsing markup.

## Labels (`sparkles.syntax.label`)

| Symbol                      | What it is                                                                          |
| --------------------------- | ----------------------------------------------------------------------------------- |
| `standardLabels`            | the canonical vocabulary: 72 dotted names, sorted                                   |
| `LabelSet.standard()`       | wraps `standardLabels`, allocation-free                                             |
| `LabelSet.fromNames(names)` | custom vocabulary (sorted + deduplicated)                                           |
| `find(name)`                | exact lookup, binary search                                                         |
| `resolve(name)`             | **longest-dot-prefix**: `function.builtin.static` → `function.builtin` → `function` |

Resolution is Helix's rule, deliberately not the reference crate's
part-subset match — one predictable algorithm shared by capture names and
theme selectors. The whole configure-time path is CTFE-able.

## Colors (`sparkles.syntax.color`)

| Symbol                                | What it is                                                                                              |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `Color`                               | sum type: `unset` / `default_` / `palette(index)` / `rgb`                                               |
| `parseHexColor`                       | `#RGB`, `#RRGGBB`, `#RRGGBBAA` (bat's alpha conventions: `00` = palette index, `01` = terminal default) |
| `ColorDepth`                          | `none` / `ansi16` / `ansi256` / `trueColor`                                                             |
| `ansi256FromRgb` / `ansi16FromRgb`    | nearest-match tier folds (6×6×6 cube + gray ramp; xterm classic 16)                                     |
| `xterm256ToRgb`                       | palette index → RGB (the concretization step for non-terminal backends)                                 |
| `classifyColorDepth(colorterm, term)` | pure tier classifier; `detectColorDepth()` reads the environment                                        |

## Themes (`sparkles.syntax.theme`, `.themes`)

| Symbol                         | What it is                                                                                                       |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `FontStyle`                    | backend-neutral flags: bold, dim, italic, underline, strikethrough                                               |
| `StyleSpec`                    | `{ fg, bg, font }`; `Color.Kind.unset` = unspecified                                                             |
| `Theme`                        | plain data: name, defaults, ordered `ThemeRule[]` (`selector` → `StyleSpec`)                                     |
| `resolveTheme(theme, labels)`  | folds rules into a flat `ResolvedTheme` table — longest-dot-prefix, whole spec wins, last rule wins among equals |
| `ResolvedTheme`                | `labelId → StyleSpec` in O(1); `theme[LabelId.none]` = the defaults                                              |
| `builtinDark` / `builtinLight` | Catppuccin-Mocha- / Solarized-Light-derived data themes                                                          |

Theme _files_ (TOML/JSON) are a recorded seam: only a parser producing
`ThemeRule[]` is missing.

## Renderers (`sparkles.syntax.render.*`)

Both are attribute-inferring template folds over any `char` output range —
`@safe pure nothrow @nogc` given `@nogc` inputs — and both guarantee
**per-line validity**: at every newline, active styling closes and re-opens,
so each output line stands alone.

### ANSI — `renderAnsi(source, events, theme, writer, AnsiOptions)`

- `AnsiOptions`: `depth` (default `ansi256`; `none` = verbatim passthrough),
  `emitBackground` (default off — respect the terminal), `italics` (default
  off — bat's defensive gate).
- Minimal SGR diffs between adjacent runs (`writeStyleTransition`); palette
  colors stay palette-native so the user's terminal scheme applies.

### HTML — `renderHtml(source, events, theme, writer, HtmlOptions)`

- `HtmlOptions.mode`: `inlineStyles` (self-contained `style="…"`) or
  `cssClasses` (`class="syn-…"`, dots → dashes); `classPrefix` default
  `"syn-"`.
- `writeThemeStylesheet(theme, writer, prefix)` emits one rule per styled
  label plus a `syn-root` rule for the theme defaults.
- Source text is escaped via `sparkles.base.text.html.writeHtmlEscaped`.
- Output is content-only — wrap it in `<pre><code>` yourself.

## See also

- [The tree-sitter engine](./engine.md) — the event producer.
- [The design](../explanation/design.md) — why these seams.
