# `sparkles:twoslash`

Render [Twoslash](https://github.com/twoslashes/twoslash) type-annotation overlays
on top of `sparkles:syntax`, in **HTML**, **ANSI**, and the **raylib GUI**
(`hue --gui`).

Twoslash augments a type-checked code snippet with hover popups (type signatures),
`^?` queries, completion lists, compiler errors, highlighted spans, and `// @tag`
annotation lines. This library consumes the TypeScript `twoslash` **node model as
opaque data** (JSON, via `sparkles:wired`) and overlays it on a highlighted snippet
— the render half of the D-native Twoslash umbrella (issue #120). The semantic
backend that will one day replace TypeScript `twoslash` as the data source is
`sparkles:dmd-lsp` (issue #124); it slots in behind the proven node model here.

## Modules

| Module        | Role |
| ------------- | ---- |
| `protocol`    | the flat node model (`Node` + `NodeType` + `Completion` + `TwoslashReturn`) |
| `ingest`      | decode a `TwoslashReturn` from JSON via `sparkles:wired` (`parseTwoslash`, `loadTwoslashFile`) |
| `overlay`     | the backend-agnostic planner (`planTwoslash`) + reentrant popup re-highlighter (`highlightSignature`) |
| `render_html` | the HTML overlay matching the `.twoslash-*` class contract |
| `render_ansi` | the terminal overlay (meta-lines below the code) |
| `style`       | the ported `style-rich.css` (`writeTwoslashStyles`) |

The raylib GUI backend lives in `apps/hue` (`hue --gui --twoslash`), consuming the
same `overlay` plan.

## Documentation

- [How-to: render a twoslash payload](how-to/render-twoslash.md)
- [Reference: the overlay API](reference/overview.md)
- Design: [`docs/specs/twoslash/SPEC.md`](../../specs/twoslash/SPEC.md)

## See also

- [`sparkles:syntax`](../syntax/index.md) — the highlight-event stream + ANSI/HTML
  renderers this overlays.
