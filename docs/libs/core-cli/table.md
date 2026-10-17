---
aside: false
---

# `drawTable` — interactive playground

`sparkles.ui.components.table.drawTable` renders a boxed table entirely in terminal
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

| Control                                   | Maps to                                                                                                |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| **Grid** data                             | a dense `string[][]` (tab = column, newline = row)                                                     |
| **Raw cells** → `Cell[][]`                | dense cells with `colSpan` / `rowSpan`                                                                 |
| **Raw cells** → `Placement[]`             | sparse, order-independent cells that name their own `(row, col)`                                       |
| border / columnSeparators / rowSeparators | the frame + interior separator toggles                                                                 |
| headerRows / headerCols                   | a distinct **heavy** rule after N header rows / stub columns                                           |
| preset                                    | `stylePresets["rounded" \| "square" \| "ascii" \| "double" \| "heavy"]`                                |
| maxWidth                                  | total-width cap (frame included); columns shrink + wrap to fit                                         |
| title / footer                            | frame `title` / `footer` spliced into the top & bottom border (`…`-truncated when narrow)              |
| defaultAlign / per-column align           | `Align{left,center,right,decimal}` horizontal alignment (`decimal` aligns a numeric column on its dot) |
| defaultVAlign / per-column valign         | `VAlign{top,middle,bottom}` vertical alignment (rowspan / wrap)                                        |
| per-column max width                      | `columnMaxWidths` — cap one column; its content wraps                                                  |
| Advanced → raw spec                       | the exact JSON request; custom `glyphs` overrides go here                                              |

The **Samples** cover the headline features: styled + CJK/emoji content, column &
row spans, sparse placement, width-capped wrapping, and decimal alignment under a
framed title/footer. **Show D code** prints the equivalent
`drawTable(…, TableProps(…))` call.

> [!NOTE]
> Alignment in the browser depends on the page's monospace font rendering CJK and
> emoji at exactly two cells; a terminal is the source of truth. The playground
> nudges the browser toward full-width metrics, but small visual differences from a
> real terminal are a font-rendering artifact, not a `drawTable` bug.

## Build cells in place

A table has to measure every cell before it can draw a line, so cell text must
exist before rendering. When cells are formatted from values (durations,
counts, sizes), build them with `TableBuilder` instead of a `string` per cell:
each cell is written into one buffer the builder owns.

```d
TableBuilder t;
t.row("Job", "Runs", "Median");                 // strings are copied
foreach (job; jobs)
    t.row(job.name, job.runs, duration(job.median));
t.row.cell("total").span(2).aligned(Align.right)  // one cell at a time
    .cell!writeDuration(total);                     // written in place

writeln(drawTable(t, TableProps(headerRows: 1)));
```

`row(values...)` writes each non-string value as `writeValue` renders it
(numbers, enums, anything with `toString(Writer)`); `cell!write(args)` calls
`write(buffer, args)`. Building and snapshotting are `@safe pure nothrow @nogc`
when the supplied writers are too. `auto cells = t.cells` owns a snapshot;
`cells[]` borrows its dense cell view for the other APIs. The snapshot survives
builder growth and destruction, but its slices must not outlive it.
`drawTable(cells, props)` is the table as a value: `writeln` streams it
into stdout without building a string, and `.toString` makes one where it is
stored. `drawTable(w, cells, props)` writes it into any output range `w`.

## Beyond the controls

Beyond what the controls expose, `Cell`/`Placement` also carry per-cell
`halign`/`valign` overrides (e.g. a centered colspan banner). The same layout
also renders lazily: `drawTableLines` (a forward range of lines, ready for a
`LiveRegion` frame) and `drawTableChunks` (cell-by-cell pacing) emit
`drawTable`'s exact bytes.

For the full API — spans, alignment, glyph presets, custom glyphs, validation,
streaming — see the module `libs/ui/src/sparkles/ui/components/table/` and
the runnable gallery `libs/core-cli/examples/table.d`.

The same layout core also has a **widget view**: `buildTableWidgets`
(`sparkles.ui.components.table.widgets`) emits the table as a `sparkles:ui`
widget subtree — styled `TextSpan` cells with source identity, per-cell element
keys for hit-testing, theme slots, and an optional top-border cutout — which is
how `hue`'s markdown preview renders its tables. The two views share every
sizing and junction decision, so a table looks the same whether it is printed
or painted.
