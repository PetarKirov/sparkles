# Reference: the overlay API

## Ingest (`sparkles.twoslash.ingest`)

| Symbol | Signature | Notes |
| ------ | --------- | ----- |
| `parseTwoslash` | `JsonResult!TwoslashReturn parseTwoslash(scope const(char)[] json)` | parse + decode a JSON string |
| `loadTwoslashFile` | `JsonResult!TwoslashReturn loadTwoslashFile(string path)` | read + parse + decode a file |
| `fromTwoslashJson` | `JsonResult!TwoslashReturn fromTwoslashJson(JSONValue root)` | decode a pre-parsed object |

Errors are returned (never thrown). Not `@nogc` (`std.json` + wired allocate).

## Protocol (`sparkles.twoslash.protocol`)

- `enum NodeType : ubyte { hover, query, completion, error, highlight, tag }` —
  lowercase members map the wire `type` verbatim.
- `struct Node` — flat POD: `type`, `start`, `length`, `line`, `character`, plus the
  `@WireOptional` payload fields (`text`, `docs`, `level`, `code`, `id`,
  `completions`, `completionsPrefix`, `name`). `end() => start + length`.
- `struct Completion { string name; string kind; }`
- `struct TwoslashReturn { string code; Node[] nodes; }`

## Overlay planner (`sparkles.twoslash.overlay`)

- `TwoslashPlan planTwoslash(in TwoslashReturn tw)` — partition into
  `inlineDecorations` (sorted outer-first) and `belowBlocks` (sorted by line).
- `hasInlineDecoration(NodeType)` / `hasBelowBlock(NodeType)` — classification.
- `highlightSignature(ref TsConfigCache, sig, ref sink)` — reentrant popup
  re-highlight (degrades to plain text on a missing grammar). `@system`.

## Renderers

- `renderTwoslashHtml(in TwoslashReturn tw, const(HighlightEvent)[] events,
  in ResolvedTheme theme, ref TsConfigCache cache, ref Writer w,
  in TwoslashHtmlOptions = …)` — content-only HTML overlay. `@system`.
- `renderTwoslashAnsi(… , in TwoslashAnsiOptions = …)` — terminal overlay
  (`TwoslashAnsiOptions { ColorDepth depth; bool italics, emitBackground, hovers; }`).
  `@system`.

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
