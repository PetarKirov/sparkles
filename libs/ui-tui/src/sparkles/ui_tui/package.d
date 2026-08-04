/**
`sparkles:ui-tui` — the terminal backend adapter for $(MREF sparkles,ui): a
$(REF isCanvas, sparkles,ui,canvas)-conforming $(REF GridCanvas,
sparkles,ui_tui,grid_canvas) painting the toolkit's display list into a
$(REF Grid, sparkles,tui,cell), which `sparkles:tui`'s retained `Screen`
cell-diffs to a minimal byte stream. Backends adapt to the toolkit, never the
reverse (`TGT6`/`PKG2`).

$(H3 What this module is the whole of)

An application targeting cells needs two things from a backend: somewhere to
paint, and the vocabulary that describes what a painted cell $(I is). Both are
here — the canvas, and the cell types it paints into — so
`import sparkles.ui_tui;` is the complete surface and an application never has
to name `sparkles:tui` to describe a cell (`UIA8`).

The cell vocabulary is re-exported rather than restated. `CellStyle`, `Color`
and the rest are `sparkles:tui`'s types; wrapping them would create a second
spelling of one concept, and every value crossing the seam would need
converting. A re-export means the adapter $(I adopts) the vocabulary it paints
in, which is the same direction as `TGT6`: backends adapt to the toolkit.

$(H3 Why the session is not part of it)

$(REF TerminalSession, sparkles,ui_tui,session) is deliberately $(B not)
re-exported. The split is not stylistic — it is what the module can be
compiled on:

$(UL
$(LI The canvas and the cell types are $(B portable). `cell.d` reaches only
    `sparkles.base`, so it builds anywhere the toolkit does.)
$(LI The session is $(B POSIX-only). It reaches `sparkles.tui.terminal`, whose
    `core.sys.posix.termios` imports (`tcgetattr`/`tcsetattr`) do not resolve
    under the Android NDK's bionic druntime.)
)

Re-exporting the session put termios in the import closure of every consumer of
`paintGrid` — including hue's `tui.d`/`explorer.d`/`twoslash_tui.d`, which
$(I are) compiled for Android even though its `runWorkspace` is version-gated
out — and broke the APK build. On a cross target the import closure is the
build surface, not the call graph, so a `version (Android)` gate on the caller
proves nothing.

So the rule is: this module carries what every cell target can compile, and a
caller that wants a $(I terminal) names the module —
`import sparkles.ui_tui.session;`.
*/
module sparkles.ui_tui;

public import sparkles.ui_tui.grid_canvas;

/**
The cell vocabulary this adapter paints in: `Grid`, `Cell`, `CellStyle`,
`Color`, `TextAttr` and friends.

Part of the public surface on purpose — see the module docs. Note this is the
$(I leaf) module, never the `sparkles.tui` package module, which would drag the
POSIX terminal into every consumer's closure.
*/
public import sparkles.tui.cell;
