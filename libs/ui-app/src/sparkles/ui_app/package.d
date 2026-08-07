/**
`sparkles:ui-app` — the application host for $(MREF sparkles,ui).

The toolkit is backend-free by construction, and the concrete canvases live in
sibling packages ($(MREF sparkles,ui_tui), $(MREF sparkles,ui_raylib)). Nothing
owned the layer $(B above) them: choosing which backend to open, resolving fonts,
sizing a window, draining input, and driving a frame. Every application
implemented that privately, which is why two of them disagree about what
`--font-size` defaults to and why neither of their frame loops has ever had a
test.

This package is that layer, as one more sibling — the toolkit gains no
dependency and no knowledge of window systems.

$(B What it owns:)

$(LIST
    * $(B backend selection) — the flags, the probes, and the platform facts
        behind the choice, as a pure function over an injected policy;
    * the $(B window/font command line) and the order its setup must happen in;
    * the $(B frame and event loop), so an application never names a canvas.
)

$(B The three targets) — a terminal, a window, and a $(I recording) one that
needs neither. The last is what makes an application's own `present`/`handle`
pair testable: scripted events in, the frames and platform calls it asked for
out.

Specified in $(LINK2 ../../../../docs/specs/ui-app/index.md, docs/specs/ui-app).
*/
module sparkles.ui_app;

public import sparkles.ui_app.backend;
public import sparkles.ui_app.display;
