---
aside: false
---

# `drawTable` — interactive playground

`sparkles.core_cli.ui.table.drawTable` renders a boxed table entirely in terminal
cells — it measures every cell with `sparkles.base.text` (the same width engine
documented in the [text spec](../../specs/base/text/)), so CJK, emoji, combining
marks, and ANSI-styled content all stay aligned.

The widget below is the **real `drawTable`** compiled to WebAssembly by
`nix build .#table-wasm` (full Phobos via the LDC WASI fork) and driven from your
browser — not a re-implementation. Tweak the Storybook-style controls and watch
the output re-render live.

<ClientOnly>
  <TablePlayground />
</ClientOnly>

## What the controls map to

Every control corresponds to a field of `TableProps` (or the table data itself):

| Control                                   | Maps to                                                                 |
| ----------------------------------------- | ----------------------------------------------------------------------- |
| **Grid** data                             | a dense `string[][]` (tab = column, newline = row)                      |
| **Raw cells** → `Cell[][]`                | dense cells with `colSpan` / `rowSpan`                                  |
| **Raw cells** → `Placement[]`             | sparse, order-independent cells that name their own `(row, col)`        |
| border / columnSeparators / rowSeparators | the frame + interior separator toggles                                  |
| headerRows / headerCols                   | a distinct **heavy** rule after N header rows / stub columns            |
| preset                                    | `stylePresets["rounded" \| "square" \| "ascii" \| "double" \| "heavy"]` |
| maxWidth                                  | total-width cap (frame included); columns shrink + wrap to fit          |
| defaultAlign / per-column align           | `Align{left,center,right}` horizontal alignment                         |
| defaultVAlign / per-column valign         | `VAlign{top,middle,bottom}` vertical alignment (rowspan / wrap)         |
| per-column max width                      | `columnMaxWidths` — cap one column; its content wraps                   |
| Advanced → raw spec                       | the exact JSON request; custom `glyphs` overrides go here               |

The **Samples** cover the headline features: styled + CJK/emoji content, column &
row spans, sparse placement, and width-capped wrapping. **Show D code** prints the
equivalent `drawTable(…, TableProps(…))` call.

> [!NOTE]
> Alignment in the browser depends on the page's monospace font rendering CJK and
> emoji at exactly two cells; a terminal is the source of truth. The playground
> nudges the browser toward full-width metrics, but small visual differences from a
> real terminal are a font-rendering artifact, not a `drawTable` bug.

For the full API — spans, alignment, glyph presets, custom glyphs, validation — see
the module `libs/core-cli/src/sparkles/core_cli/ui/table/` and the runnable demo
`libs/core-cli/examples/table.d`.
