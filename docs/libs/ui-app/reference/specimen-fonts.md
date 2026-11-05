# Independent specimen fonts

The native host supports a specimen font independently of its interface font.
Submit a `SpecimenFontRequest` through `host.specimenFont(request)`. A request
identifies a file and collection index, an em size in physical pixels, and
tagged user coordinates. The text lab converts points to physical pixels using
`fontDensity`. The interface retains its original font and cell metrics unless
the request enables `uiFollows`.

Supply preloaded bytes and their optional FNV-1a content hash to keep file reads
and hashing off the frame thread. Bytes must outlive all renderer instances
that borrow them. Coordinate arrays are retained by the host. Repeated size or
axis changes reuse parsed faces and metric/hint scratch; ordinary cell-font
size changes also reuse resolved primary, styled, and fallback bytes.

`SpecimenFontRequest.fallbacks` supplies an ordered list of preloaded
`SpecimenFallbackFace` values: bytes, collection member, and an optional content
hash. The host retains the list; the application keeps its font bytes alive.
Load these through background workers alongside the selected face. These script
faces precede the ordinary interface fallbacks and keep their own default axes;
resizing the specimen reuses the supplied storage without file discovery.
Fallback lookup visits the complete supplied list. Emoji presentation prefers
color faces; text presentation preserves the ordinary face order. Variation
selectors and joiners participate in shaping without requiring standalone cmap
glyphs.

`beginSpecimen` scopes canvas drawing to the prepared font and metrics.
`endSpecimen` restores the interface context. Use the pixel drawing methods for
an independent specimen layout. `naturalTextPx` draws with shaped advances and
returns the advance; `naturalTextWidthPx` measures without rasterizing. Cell
text remains available for terminal-style comparisons.

The Vulkan canvas retains up to 256 shaped runs in a four-way cache shared by
measurement, drawing, and subsequent frames. Keys include exact face identity,
physical em size, normalized variation coordinates, direction, and cluster text. Runs own
their keys and glyph positions; colors and raster images remain independent.
Memory-pressure cache release drops these runs along with the glyph atlases.

Natural text methods accept an optional `ClusterDirection` after their style
arguments. Resolve paragraph levels and wrapped-line ordering before supplying
`ltr` or `rtl`; automatic direction remains the default for existing callers.
Logical source text is passed unchanged to shaping, which also handles mirroring.

For natural text laid out before drawing, call `canvas.beginGlyphPreparation`
before measuring runs and `canvas.finishGlyphPreparation` before drawing them.
Measurements collect up to 128 unique coverage misses. An Event Horizon pool
with 1–4 workers produces tiles using independent outline and raster scratch;
one worker runs directly on the frame thread. Completion joins the batch before
atlas placement, and GPU uploads remain on the frame thread. No batch survives
the frame or borrows font bytes after completion. Keep bindings and their
borrowed bytes valid until finishing; each job captures its instance and hints.
Color glyphs and unsupported or oversized tiles use the ordinary drawing path.
Each retained tile is capped at 65,536 bytes and each worker's accumulation
at 1,048,576 floats, with outline scratch capped at 32,768 points. The renderer
joins its workers before teardown.

Exact-face mode uses the selected face for every style. Family mode accepts
explicit preloaded bold, italic, and bold-italic members; missing siblings use
the selected face. Hosts do no implicit sibling discovery during a frame.
Fallback and grid-degradation counters let an application distinguish the
selected face's specimen from substituted text.

Recording hosts capture requests by value for application tests. Applications
must probe these optional errands before using them on other hosts.

For latency measurements, attach a monotonic generation and request timestamp.
The native host associates each new generation with its first submitted frame
and, when the window system reports presentation feedback, its first observed
display. `specimenLatencyStatistics` reports submission and observed-display
deadline misses separately. An unavailable display timestamp is not a zero
latency measurement.
