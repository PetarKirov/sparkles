# Glyph inspection

`VulkanCanvas.inspectTextPx(text, x, bold, italic, direction, grid)` inspects a
run-local pixel position using the font context currently bound to the canvas.
Call it between `beginSpecimen` and `endSpecimen` to inspect specimen text;
otherwise it describes the interface font. `grid` selects the cell rendering
path instead of natural advances. The query never allocates atlas entries.

The returned `GlyphInspection` owns its face and glyph names and borrows no
font storage. `found` distinguishes a hit from a position outside the run.
`glyph`, `glyphName`, `faceName`, `faceIndex`, and `faceSerial` identify the
serving face and glyph. `fallback` distinguishes a fallback face from the
requested styled face; `colour` describes the face's colour capability.
`ppem`, `advance`, `xOffset`, and `yOffset` describe the active instance.

For shaped text, `cluster` retains the selected glyph's raw shaper byte offset;
`start` and `end` expand its source span to whole graphemes. `glyphs` includes
all glyph IDs in that span, including zero-advance marks, and `flags` preserves
the shaper's safety flags. A ligature can cover several
codepoints, and combining glyphs can share a cluster. Hit selection uses the
glyph's advance interval rather than its outline: zero-advance marks are
described through the same source cluster as their advancing glyph. The query
shares the renderer's face-order and prepared-run cache. It does not guess a
fallback from a Unicode block or family name.

Text lab presents this metadata on hover and as a retained touch popup,
together with codepoint values, scripts, general categories, and bidi classes
from the owned Unicode tables.
