/**
The host contract: what a frame loop hands an application (`HST`).

An application's loop is written once, against $(LREF isHost). The concrete host
is a $(B per-backend template instantiation), never an interface — so there is no
vtable in the frame path and `@safe`/`@nogc`/`nothrow` infer from the backend,
the same discipline `isCanvas` uses for drawing.

$(B Three render levels), mirroring the toolkit's own (`UIA2`), so an application
defers as much of the pipeline as it wants and none is forced through one it does
not need:

$(LIST
    $(LI $(B widgets) — hand over a tree and a theme; the host lays it out,
        builds the display list and paints it.)
    $(LI $(B display list) — append $(REF DrawOp, sparkles,ui,canvas)s into a
        buffer the host owns and reuses.)
    $(LI $(B canvas) — drive the backend's own primitives, for an application
        with a renderer of its own. This is why `apps/terminal` can migrate at
        all: its paint walks a terminal screen cell by cell and is benchmarked,
        so routing it through a display list would be a rewrite of a hot path.)
)

$(B Declining a frame is part of the contract), not an optimization a backend may
ignore. When nothing changed, `apps/terminal` polls input and paces the frame
$(I without swapping buffers), keeping the last frame on screen and idle CPU near
zero. A host that unconditionally began and ended a frame would erase that, so
$(LREF HostState.skipFrame) is something every target must honour.
*/
module sparkles.ui_app.host;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_control : PointerShape;
import sparkles.input : Event, InputCapabilities;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.gui_options : GuiOptions;

/// How many draw operations a host's per-frame buffer holds before it spills to
/// the heap. Sized for a full screen of decorated content; a frame that exceeds
/// it still works, it just allocates once.
enum size_t frameOpCapacity = 2048;

/// The per-frame display-list buffer a host owns and reuses (`HST4`).
alias FrameOps = SmallBuffer!(DrawOp, frameOpCapacity);

/**
What the caller wants of a run.

`idleTimeoutMs` is what lets a terminal host do background work — polling a
subprocess, refreshing a status — without dropping input: below zero it blocks
on input alone, and otherwise `present` is called on that interval even when
nothing arrived.
*/
struct RunConfig
{
    string title = "app";       /// window title, where there is one
    GuiOptions gui;             /// the window/font/theme settings (`CLI`)
    Backend backend;            /// `Backend.init` (gui) unless overridden; see `run`
    bool autoBackend = true;    /// ignore `backend` and pick one
    bool mouse = true;          /// ask the terminal for mouse reporting
    bool motion;                /// ...including bare motion (hover)
    int targetFps = 60;         /// GPU pacing
    int idleTimeoutMs = -1;     /// TUI: wake `present` without input (< 0 = never)
}

/**
The bookkeeping every host shares: what the application asked of this frame.

Mixed into each concrete host so the three targets cannot drift on the meaning
of "quit", "another frame please" or "do not draw this one".
*/
mixin template HostState()
{
    private bool _quit;
    private bool _frameRequested;
    private bool _skipFrame;
    private FrameOps _ops;

    /// End the loop after this frame.
    void quit() @safe pure nothrow @nogc { _quit = true; }

    /// `true` once $(LREF quit) was called.
    bool quitRequested() const @safe pure nothrow @nogc => _quit;

    /**
    Ask for one more frame after this one, even with no input.

    What an animation or an eased transition needs on a target that otherwise
    blocks. It is a $(B request for one frame), not a mode: a continuing
    animation asks again each time, so a finished one stops costing anything
    without having to remember to turn itself off.
    */
    void requestFrame() @safe pure nothrow @nogc { _frameRequested = true; }

    /// ditto
    bool frameRequested() const @safe pure nothrow @nogc => _frameRequested;

    /**
    Decline to draw this frame: present nothing and leave the last frame up.

    The terminal skips its cell diff; the GPU target skips the buffer swap.
    */
    void skipFrame() @safe pure nothrow @nogc { _skipFrame = true; }

    /// ditto
    bool frameSkipped() const @safe pure nothrow @nogc => _skipFrame;

    /// The per-frame display list, owned and reused by the host (`HST4`). An
    /// application appends; it never sizes or clears one.
    ref FrameOps ops() return @safe pure nothrow @nogc => _ops;

    /// Clears the per-frame flags and buffer. Called by the loop, not the app.
    private void beginFrameState() @safe pure nothrow @nogc
    {
        _frameRequested = false;
        _skipFrame = false;
        _ops.length = 0;
    }
}

/**
The host capability concept: `true` iff `T` offers what an application's frame
loop is written against.

Attributes are deliberately not constrained — a recording host is `@safe`, a GPU
host is `@system`, and both satisfy this.
*/
enum bool isHost(T) = __traits(compiles, (ref T h) {
    Size sz = h.size;
    InputCapabilities caps = h.capabilities;
    Backend b = h.backend;
    h.quit();
    h.requestFrame();
    h.skipFrame();
    DrawOp op;
    h.ops() ~= op;
    h.pointerShape(PointerShape.default_);
});

/**
Normalizes a resize event to carry the surface size the host actually has
(`HST7`).

The GPU event synthesizer emits `ResizeEvent()` with a $(B zero) size by design —
the caller is expected to re-query — which is a reasonable producer contract and
a trap for every consumer. The host absorbs it once, here, so no application
learns it the hard way.
*/
Event withRealSize(Event e, Size sz) @safe
{
    import sparkles.input : match, ResizeEvent;

    return e.match!(
        (ResizeEvent _) => Event(ResizeEvent(sz)),
        _ => e,
    );
}

version (unittest)
{
    private struct FullFake
    {
        mixin HostState;
        Size size;
        InputCapabilities capabilities;
        Backend backend;
        void pointerShape(PointerShape) @safe pure nothrow @nogc {}
    }

    static assert(isHost!FullFake, "the concept must accept a complete host");
}

@("ui_app.host.frameStateIsPerFrame")
@safe pure nothrow @nogc
unittest
{
    static struct Fake
    {
        mixin HostState;
        void newFrame() { beginFrameState(); }
    }

    Fake h;
    assert(!h.quitRequested && !h.frameRequested && !h.frameSkipped);

    h.requestFrame();
    h.skipFrame();
    h.quit();
    assert(h.frameRequested && h.frameSkipped && h.quitRequested);

    // The per-frame flags reset; quit does NOT — it ends the run rather than
    // describing one frame.
    h.newFrame();
    assert(!h.frameRequested && !h.frameSkipped);
    assert(h.quitRequested, "quit outlives the frame it was asked in");
}

@("ui_app.host.opsBufferIsReused")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.geometry : Rect;

    static struct Fake
    {
        mixin HostState;
        void newFrame() { beginFrameState(); }
    }

    Fake h;
    foreach (i; 0 .. 10)
        h.ops() ~= DrawOp(kind: OpKind.fillRect, rect: Rect(i, 0, 1, 1));
    assert(h.ops().length == 10);

    // The next frame starts empty but keeps the buffer — an application never
    // sizes or clears one, and a per-frame rebuild does not allocate again.
    h.newFrame();
    assert(h.ops().length == 0);
}

@("ui_app.host.resizeCarriesTheRealSize")
@safe
unittest
{
    import sparkles.input : match, PointerAction, PointerEvent, Point,
        ResizeEvent;

    // The producer's zero-size resize is filled in.
    const fixed = withRealSize(Event(ResizeEvent()), Size(120, 40));
    fixed.match!(
        (in ResizeEvent r) { assert(r.size == Size(120, 40)); },
        (in _) { assert(false, "still a resize"); },
    );

    // Everything else passes through untouched.
    const p = Event(PointerEvent(action: PointerAction.press, pos: Point(3, 4)));
    assert(withRealSize(p, Size(120, 40)) == p);
}
