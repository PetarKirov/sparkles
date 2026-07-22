# Reference: the overlay API

## Ingest (`sparkles.twoslash.ingest`)

| Symbol             | Signature                                                           | Notes                        |
| ------------------ | ------------------------------------------------------------------- | ---------------------------- |
| `parseTwoslash`    | `JsonResult!TwoslashReturn parseTwoslash(scope const(char)[] json)` | parse + decode a JSON string |
| `loadTwoslashFile` | `JsonResult!TwoslashReturn loadTwoslashFile(string path)`           | read + parse + decode a file |
| `fromTwoslashJson` | `JsonResult!TwoslashReturn fromTwoslashJson(JSONValue root)`        | decode a pre-parsed object   |

Errors are returned (never thrown). Not `@nogc` (`std.json` + wired allocate).

## Protocol (`sparkles.twoslash.protocol`)

- `enum NodeType : ubyte { hover, query, completion, error, highlight, tag }` —
  lowercase members map the wire `type` verbatim.
- `struct Node` — flat POD: `type`, `start`, `length`, `line`, `character`, plus the
  `@WireOptional` payload fields (`text`, `docs`, `tags`, `level`, `code`, `id`,
  `completions`, `completionsPrefix`, `name`). `tags` is `string[][]` (each inner
  `[name, text?]` — hover/query JSDoc tags). `end() => start + length`.
- `struct Completion { string name; string kind; }`
- `struct TwoslashReturn { string code; Node[] nodes; }`

## Overlay planner (`sparkles.twoslash.overlay`)

- `TwoslashPlan planTwoslash(in TwoslashReturn tw)` — partition into
  `inlineDecorations` (sorted outer-first) and `belowBlocks` (sorted by line). Drops
  the inline `hover` on a token that also has a `query` (the query supersedes it).
- `hasInlineDecoration(NodeType)` / `hasBelowBlock(NodeType)` — classification.
- `highlightSignature(ref TsConfigCache, sig, ref sink)` — reentrant popup
  re-highlight (degrades to plain text on a missing grammar). `@system`.
- `withoutQuickinfoPrefix(sig)` — strips a leading TS quickinfo kind prefix
  (`(property) `, …); a real leading paren (`(a: number) => void`) is preserved.

## Renderers

- `renderTwoslashHtml(in TwoslashReturn tw, const(HighlightEvent)[] events,
in ResolvedTheme theme, ref TsConfigCache cache, ref Writer w,
in TwoslashHtmlOptions = …)` — content-only HTML overlay. `@system`.
- `renderTwoslashAnsi(… , in TwoslashAnsiOptions = …)` — terminal overlay
  (`TwoslashAnsiOptions { ColorDepth depth; bool italics, emitBackground, hovers; }`).
  `@system`.

`TwoslashHtmlOptions` controls the HTML fidelity/chrome:

| Field                  | Default         | Effect                                                     |
| ---------------------- | --------------- | ---------------------------------------------------------- |
| `classPrefix`          | `"syn-"`        | class prefix for the inner syntax spans                    |
| `completionIcons`      | `IconStyle.svg` | completion-kind icon set (`svg` \| `glyph` \| `none`)      |
| `customCompletionIcon` | `null`          | per-kind icon override delegate (non-empty return wins)    |
| `tagIcons`             | `IconStyle.svg` | `// @tag` line icon set (`svg` \| `glyph` \| `none`)       |
| `stripQuickinfoPrefix` | `false`         | strip `(property) ` etc. from popup signatures             |
| `renderDocsMarkdown`   | `true`          | render `docs` (block) + `@tag` values (inline) as markdown |

The `svg` icon sets are the reference `@shikijs/twoslash` icons, string-imported from
`views/icons/{completions,tags}/*.svg` by `sparkles.twoslash.icons`.

With `renderDocsMarkdown` (default on), hover/query `docs` render as **block**
markdown and each `@tag` value as **inline** markdown, via the `MdDoc → HTML`
emitter in `sparkles:syntax` (`renderMarkdownHtml` / `renderMarkdownInlineHtml`,
Shiki's `renderMarkdown`/`renderMarkdownInline` seam). It degrades to escaped text
automatically when the markdown grammars are unavailable, so no grammar bundle is
required for correct — if plainer — output.

Both take the snippet already highlighted into `events` (over `tw.code`) and the
`cache` used to re-highlight popup signatures. Neither is `@nogc`.

## Stylesheet (`sparkles.twoslash.style`)

- `enum twoslashStyleCss` — the ported `style-rich.css`, compiled in.
- `writeTwoslashStyles(ref Writer w)` — write it (no `<style>` wrapper). Styles only
  the `.twoslash-*` chrome; syntax token colors come from
  `writeThemeStylesheet` (`.syn-*`).

## GUI

`hue --gui --twoslash <nodes.json>` — the raylib overlay (`apps/hue`,
`runGuiTwoslash`, `version(HueGui)`).
