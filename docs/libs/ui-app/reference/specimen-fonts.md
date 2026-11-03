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

`beginSpecimen` scopes canvas drawing to the prepared font and metrics.
`endSpecimen` restores the interface context. Use the pixel drawing methods for
an independent specimen layout. `naturalTextPx` draws with shaped advances and
returns the advance; `naturalTextWidthPx` measures without rasterizing. Cell
text remains available for terminal-style comparisons.

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
