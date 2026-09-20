# The Sparkles theme (`SPK`)

_**Status:** proposed — **no values yet** · **Date:** 2026-09-21 · **Owner:**
this tree; shipped as `builtinThemes["sparkles"]` and as a DTCG file ·
**Scope:** the constraints the concrete brand must satisfy, and how it is
delivered. The palette, type and glyph choices are a design exercise still to
be done **from scratch** ([D3](./decisions.md)); nothing here is the result of
it._

| ID     | Requirement                                                                                                                                                                                                                                                             | Status      | Traces to                                |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------- |
| `SPK1` | Sparkles sets **every** semantic token of [`TOK3`](./SPEC.md) explicitly, in both a light and a dark scheme, and every state override the components read — no fallback path is exercised. It is the one theme for which the framework's defaults are never the answer. | not started |                                          |
| `SPK2` | Sparkles declares `conformance: required` and **passes** [`ACC1`](./SPEC.md) in both schemes; a regression is a test failure ([`ACC2`](./SPEC.md)).                                                                                                                     | not started | [`testing.md` O2](./testing.md)          |
| `SPK3` | Sparkles is the **default theme** of `ui-gallery`, of the generated `hue gallery`/`sparkles:docs` output and of the VitePress site; `hue`'s own default follows once its settings migrate ([PLAN](./PLAN.md)).                                                          | not started | `ui-gallery` `themes_page`; `custom.css` |
| `SPK4` | Sparkles fixes the **type stack**: mono = the bundled Maple Mono NF CN with the FiraCode Nerd Font fallback ([`FNT`](../hue/gui.md)); sans = to be chosen with the palette. Both are tokens ([`WEB6`](./web.md)).                                                       | not started |                                          |
| `SPK5` | Sparkles fixes the **glyph preferences** per role (`GLY1`): frame, rule, tree-guide, thumb and mark charsets, and whether rules use sub-cell edges (`GLY2a`). Chosen on the TUI first, then checked unchanged on GUI and Web.                                           | not started |                                          |
| `SPK6` | Sparkles **ships as a DTCG document** in the repository (`FMT5`) and is the first file the loader is tested against — the brand and the file format land together.                                                                                                      | not started | [`FMT`](./SPEC.md)                       |

## Not inherited from the docs site

The VitePress theme's "Midnight Aurora" look (indigo `#6366f1` / cyan
`#22d3ee`, Space Grotesk / Inter / JetBrains Mono) is **not** the seed
([D3](./decisions.md)). It is replaced when `SPK3` lands; until then it is the
site's interim appearance and no token references it.

→ [Overview](./index.md) · [Specification](./SPEC.md) · [Delivery plan](./PLAN.md)
