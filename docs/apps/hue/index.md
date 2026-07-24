# hue

An interactive syntax-highlighting file viewer and live theme previewer over
[`sparkles:syntax`](../../libs/syntax/). It reads a source file, highlights it
with the precise tree-sitter pipeline, and renders it in one of four modes:
non-interactive **ANSI**, **HTML**, an interactive terminal **previewer**, and an
optional [raylib **GUI**](../../specs/hue/gui) window with a
render-markdown.nvim-style markdown preview.

```bash
dub run :hue -- path/to/file.d          # highlight in the terminal
dub run :hue -- --html file.d > out.html
dub run :hue -- --gui file.md           # raylib window + markdown preview
```

The full, traceable feature inventory lives in the
[hue feature spec](../../specs/hue/).

## Twoslash overlay

`hue --twoslash <nodes.json>` renders a TypeScript
[Twoslash](https://twoslash.netlify.app/) node model as a type-annotation
**overlay** on the highlighted code — hovers, `^?` queries, `^|` completions,
errors, highlights, and custom `@tag`s — in **HTML** (the Shiki `.twoslash-*`
contract, 100% CSS `:hover`, no JS), **ANSI** (terminal twoslash — the
differentiator), and the raylib **GUI**. Hover/query docs and `@tag` values
render as Markdown; a browser copy of the code yields only the code (annotations
are non-selectable). See the [twoslash spec](../../specs/hue/twoslash) for the
requirements and the [library docs](../../libs/twoslash/) for the API.

### Interactive showcase

Every example fixture, rendered by `hue --twoslash --html` and served exactly as
the overlay emits it — hover the dotted-underline tokens for the type popups,
and use prev/next to browse:

<!-- The gallery is a static page under docs/public/, not a VitePress route, so
     the links open in a new tab (target=_blank) to bypass the SPA router — an
     in-app navigation to it would 404. -->

<a href="/apps/hue/twoslash/" target="_blank" rel="noreferrer"><img src="./twoslash-preview.png" alt="The hue twoslash HTML overlay: a Readonly&lt;Todo&gt; snippet with a query popup, a read-only-assignment error (wavy underline plus message), and a completion list" /></a>

<div style="text-align:center">

<a href="/apps/hue/twoslash/" target="_blank" rel="noreferrer"><strong>→ Open the interactive twoslash showcase ↗</strong></a>

</div>

The gallery is generated at docs-build time from the committed
`libs/twoslash/examples/fixtures/*.twoslash.json` (the same
`libs/twoslash/examples/render-html.mjs` previewer developers run with
`npm run render`), so it always matches the shipped overlay.
