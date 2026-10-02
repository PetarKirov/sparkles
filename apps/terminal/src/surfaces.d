/**
What the terminal shows over its panes: confirmations, menus and pages on a
stack, the topmost owning the keyboard (`TKM4`), and toasts that come and go
on their own (docs/specs/terminal/design.md).

A surface is a small class behind the $(LREF Surface) interface: it builds its
widget tree for the room it is given, says where it goes, and answers its own
hits and its cancel. The stack places them each frame — a card anchored at its
subject, or a bottom sheet, as `ui.overlayStyle` says (`TCF10`) — and routes
taps and the overlay keys to the top one.

$(B An anchored card never covers its subject) — the line, link or selection
it is about — nor the keyboard or the extra keys: it goes above the subject,
else below it, and when neither fits that occurrence is a sheet instead.
*/
module surfaces;

import core.time : Duration, MonoTime, seconds;

import sparkles.input.events : KeyEvent;
import sparkles.ui.geometry : Rect;
import sparkles.ui.widget : WidgetTree;

import chrome : ChromeTheme, Layer, paintLayer, place, Place;
import settings : ButtonLabels, OverlayStyle;

/// What a surface is laid out against.
struct SurfaceContext
{
    /// The area the panes take, in pixels, and the cell size.
    Rect area;
    /// ditto
    int cellW = 1, cellH = 1;
    /// What the surface is about, in pixels (the cursor line, a link) — an
    /// empty rect for a surface about nothing in particular.
    Rect subject;
    /// `ui.buttonLabels` and `ui.overlayStyle`.
    ButtonLabels labels;
    /// ditto
    OverlayStyle style;
    /// How many rows a button takes to be a touch target (`TOK7`).
    int targetRows = 1;
    /// A touch screen: search fields sit at the bottom, within reach of the
    /// keyboard (`TSS13`).
    bool touch;
    /// Where a `panel` goes: beside the tab rail, or below the tab pill.
    Rect panelArea;
}

/// Where a surface goes.
enum Placement : ubyte
{
    sheet,    /// a band along the bottom of the area
    anchored, /// a card at the subject (a sheet when none fits)
    page,     /// the whole area
    panel,    /// the tab tree's place: `SurfaceContext.panelArea`
}

/// One surface on the stack.
interface Surface
{
    /// Its widget tree, at most `cols` wide.
    WidgetTree build(in SurfaceContext ctx, int cols) @safe;
    /// Where it goes; `anchored` defers to `ui.overlayStyle`.
    Placement placement() const @safe;
    /// A hit on `id`; true when the surface is done (and leaves the stack).
    bool activate(size_t id) @system;
    /// The primary action (Enter); true when done.
    bool confirm() @system;
    /// Escape, Back or a tap outside: the safe answer.
    void cancel() @system;
    /// A key nothing bound — typing into a search field, moving a
    /// selection; true when the surface used it.
    bool key(in KeyEvent k) @system;
}

/// A transient line: a refusal, "Copied by …", "Saved".
struct Toast
{
    string text;
    MonoTime until;
}

/// The stack and the toasts.
struct Surfaces
{
    Surface[] stack;
    Toast[] toasts;
    private Layer[] layers; // `stack`, placed this frame, bottom to top
    private Layer toastLayer;
    /// Set when something was shown, closed or expired: the frame must
    /// repaint. The host clears it.
    bool changed;

    /// Whether a surface owns the keyboard.
    bool modal() const @safe pure nothrow @nogc => stack.length != 0;

    /// Shows `s` on top.
    void push(Surface s) @safe pure nothrow
    {
        stack ~= s;
        changed = true;
    }

    /// Shows `text` for `forDuration`.
    void toast(string text, Duration forDuration = 3.seconds) @safe nothrow
    {
        toasts ~= Toast(text, MonoTime.currTime + forDuration);
        changed = true;
    }

    /// Whether anything is showing or about to stop showing (the frame must
    /// repaint).
    bool active() const @safe pure nothrow @nogc => stack.length || toasts.length;

    /// Drops expired toasts; true when one went (the frame must repaint).
    bool expire() @safe nothrow
    {
        import std.algorithm.mutation : remove;

        const now = MonoTime.currTime;
        const before = toasts.length;
        toasts = toasts.remove!(t => t.until <= now);
        changed |= toasts.length != before;
        return toasts.length != before;
    }

    /// The time until the next toast expires; `Duration.max` with none.
    Duration nextExpiry() const @safe nothrow
    {
        Duration d = Duration.max;
        const now = MonoTime.currTime;
        foreach (ref t; toasts)
            if (t.until - now < d)
                d = t.until - now;
        return d < Duration.zero ? Duration.zero : d;
    }

    /// Lays every surface out for this frame.
    void place(in SurfaceContext ctx) @safe
    {
        layers.length = 0;
        foreach (s; stack)
            layers ~= placeOne(s, ctx);
        toastLayer = Layer.init;
        if (toasts.length)
        {
            import chrome : band, label;
            import sparkles.ui.widget : Builder;

            Builder b;
            uint[] lines;
            foreach (ref t; toasts)
                lines ~= label(b, t.text);
            const cols = ctx.area.width / ctx.cellW;
            toastLayer = .place(b.finish(band(b, lines, fullWidth: false)), cols,
                ctx.area.height / ctx.cellH, ctx.area.x + ctx.cellW, ctx.area.y,
                ctx.cellW, ctx.cellH, Place.top);
            // Top-right: clear of the prompt, which a terminal keeps at the left.
            toastLayer.x = ctx.area.x + ctx.area.width
                - (toastLayer.bounds.width + 1) * ctx.cellW;
        }
    }

    /// Paints the toasts, then the stack bottom to top.
    void paint(H)(ref H h, in ChromeTheme theme) @system
    {
        foreach (ref l; layers)
            paintLayer(h, l, theme);
        paintLayer(h, toastLayer, theme);
    }

    /**
    A tap or click at pixel (`x`, `y`): true when a surface took it. A hit on
    the top surface activates it; a tap elsewhere while one is modal cancels
    it (the scrim).
    */
    bool tap(int x, int y) @system
    {
        if (!stack.length || !layers.length)
            return false;
        auto top = &layers[$ - 1];
        if (top.contains(x, y))
        {
            const id = top.hitAt(x, y);
            if (id && stack[$ - 1].activate(id))
                pop();
            return true;
        }
        stack[$ - 1].cancel();
        pop();
        return true;
    }

    /// Enter on the top surface.
    void confirm() @system
    {
        if (stack.length && stack[$ - 1].confirm())
            pop();
    }

    /// A key nothing bound, to the top surface; true when it used it.
    bool key(in KeyEvent k) @system
    {
        if (!stack.length)
            return false;
        const used = stack[$ - 1].key(k);
        changed |= used;
        return used;
    }

    /// Escape or Back: the top surface's safe answer.
    void cancel() @system
    {
        if (!stack.length)
            return;
        stack[$ - 1].cancel();
        pop();
    }

    private void pop() @safe pure nothrow
    {
        stack = stack[0 .. $ - 1];
        changed = true;
        if (layers.length > stack.length)
            layers = layers[0 .. stack.length];
    }
}

/**
Places `s` (`TCF10`): a page fills the area; a sheet runs along its bottom; an
anchored card goes above its subject, else below it — never over it — and
becomes a sheet when it fits neither side or `ui.overlayStyle` is `sheet`.
*/
Layer placeOne(Surface s, in SurfaceContext ctx) @safe
{
    const cols = ctx.area.width / ctx.cellW, rows = ctx.area.height / ctx.cellH;
    final switch (s.placement)
    {
        case Placement.page:
            return place(s.build(ctx, cols), cols, rows, ctx.area.x, ctx.area.y, ctx.cellW,
                ctx.cellH, Place.top);
        case Placement.panel:
            const pc = ctx.panelArea.width / ctx.cellW, pr = ctx.panelArea.height / ctx.cellH;
            return place(s.build(ctx, pc), pc, pr, ctx.panelArea.x, ctx.panelArea.y, ctx.cellW,
                ctx.cellH, Place.top);
        case Placement.sheet:
            return place(s.build(ctx, cols), cols, rows, ctx.area.x, ctx.area.y, ctx.cellW,
                ctx.cellH, Place.bottom);
        case Placement.anchored:
            if (ctx.style == OverlayStyle.anchored && ctx.subject.height > 0)
            {
                Layer card;
                if (anchor(s, ctx, card))
                    return card;
            }
            return place(s.build(ctx, cols), cols, rows, ctx.area.x, ctx.area.y, ctx.cellW,
                ctx.cellH, Place.bottom);
    }
}

/// The card above the subject, else below it; false when it fits neither.
private bool anchor(Surface s, in SurfaceContext ctx, out Layer card) @safe
{
    const cols = ctx.area.width / ctx.cellW;
    const width = cols - 2 > 20 ? (cols - 2 < 60 ? cols - 2 : 60) : cols;
    auto l = place(s.build(ctx, width), width, ctx.area.height / ctx.cellH, 0, 0,
        ctx.cellW, ctx.cellH, Place.top);
    const h = l.bounds.height * ctx.cellH, w = l.bounds.width * ctx.cellW;

    // Horizontally: start at the subject, slid back inside the area.
    int x = ctx.subject.x;
    if (x + w > ctx.area.x + ctx.area.width)
        x = ctx.area.x + ctx.area.width - w;
    if (x < ctx.area.x)
        x = ctx.area.x;

    const above = ctx.subject.y - h;
    const below = ctx.subject.y + ctx.subject.height;
    if (above >= ctx.area.y)
        l.y = above;
    else if (below + h <= ctx.area.y + ctx.area.height)
        l.y = below;
    else
        return false;
    l.x = x;
    card = l;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private final class Probe : Surface
    {
        Placement where;
        int lines;
        bool cancelled, confirmed;
        size_t activated;

        this(Placement where, int lines) @safe pure nothrow
        {
            this.where = where;
            this.lines = lines;
        }

        WidgetTree build(in SurfaceContext ctx, int cols) @safe
        {
            import chrome : band, button, label;
            import sparkles.ui.widget : Builder;

            Builder b;
            uint[] rows;
            foreach (_; 0 .. lines - 1)
                rows ~= label(b, "line");
            rows ~= button(b, "✓", "OK", ctx.labels, 42);
            return b.finish(band(b, rows, fullWidth: false));
        }

        Placement placement() const @safe => where;
        bool activate(size_t id) @system { activated = id; return true; }
        bool confirm() @system { confirmed = true; return true; }
        void cancel() @system { cancelled = true; }
        bool key(in KeyEvent k) @system { return false; }
    }
}

@("surfaces.anchor.neverCoversTheSubject")
@safe unittest
{
    // An 80×24 area of 10×20 cells; the subject is a line near the bottom.
    SurfaceContext ctx = {area: Rect(0, 0, 800, 480), cellW: 10, cellH: 20,
        subject: Rect(50, 400, 300, 20)};
    auto p = new Probe(Placement.anchored, 3);

    const above = placeOne(p, ctx);
    assert(above.y + above.bounds.height * 20 <= 400, "above the subject");

    // Near the top: no room above, so below.
    ctx.subject = Rect(50, 20, 300, 20);
    const below = placeOne(p, ctx);
    assert(below.y >= 40, "below the subject, not over it");

    // A subject filling the middle of a short area: neither fits — a sheet.
    ctx.area = Rect(0, 0, 800, 100);
    ctx.subject = Rect(0, 40, 800, 20);
    const sheet = placeOne(p, ctx);
    assert(sheet.x == 0 && sheet.y + sheet.bounds.height * 20 == 100, "the sheet fallback");

    // `ui.overlayStyle = sheet` always sheets.
    ctx.area = Rect(0, 0, 800, 480);
    ctx.subject = Rect(50, 400, 300, 20);
    ctx.style = OverlayStyle.sheet;
    const forced = placeOne(p, ctx);
    assert(forced.y + forced.bounds.height * 20 == 480);
}

@("surfaces.Surfaces.tapsAndKeysReachTheTop")
@system unittest
{
    SurfaceContext ctx = {area: Rect(0, 0, 800, 480), cellW: 10, cellH: 20};
    Surfaces s;
    auto a = new Probe(Placement.sheet, 2);
    s.push(a);
    s.place(ctx);
    assert(s.modal);

    // A tap outside the sheet cancels it (the scrim).
    assert(s.tap(5, 5));
    assert(a.cancelled && !s.modal);

    auto b = new Probe(Placement.sheet, 2);
    s.push(b);
    s.place(ctx);
    // The button is on the sheet's last row, one cell in.
    assert(s.tap(15, 470));
    assert(b.activated == 42 && !s.modal);

    auto c = new Probe(Placement.sheet, 1);
    s.push(c);
    s.confirm();
    assert(c.confirmed && !s.modal);
}

@("surfaces.Surfaces.toastsExpire")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;

    Surfaces s;
    s.toast("Copied by nvim", 30.msecs);
    assert(s.active && !s.modal);
    assert(!s.expire());
    Thread.sleep(40.msecs);
    assert(s.expire() && !s.active);
}
