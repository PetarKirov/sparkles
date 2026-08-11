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

import core.time : Duration;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_control : PointerShape;
import sparkles.input : Event, InputCapabilities, Mods;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.gui_options : GuiOptions;

/// How many draw operations a host's per-frame buffer holds before it spills to
/// the heap. Sized for a full screen of decorated content; a frame that exceeds
/// it still works, it just allocates once.
enum size_t frameOpCapacity = 2048;

/**
What a host that draws nowhere reserves instead.

A quarter-megabyte of inline storage is the right trade for a host that paints
a real surface once per frame, and the wrong one for a host that is $(B created
per test), often several deep, on a thread whose stack the platform sizes
rather than the application: macOS gives a non-main thread 512 KiB, so two
recorders alone exhaust it and the frame that then runs walks off the guard
page. The recorder copies each frame's operations to the heap the moment it has
them, so the inline buffer bought it nothing to begin with.
*/
enum size_t recordedOpCapacity = 16;

/// The per-frame display-list buffer a host owns and reuses (`HST4`), at a
/// given inline capacity.
alias FrameOpsOf(size_t capacity) = SmallBuffer!(DrawOp, capacity);

/// ditto, at the capacity a host painting a real surface wants.
alias FrameOps = FrameOpsOf!frameOpCapacity;

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
    /**
    Ask the GPU target for the terminal-grade keyboard: the full physical key
    set as press/repeat/release with the unshifted codepoint, typed text
    paired onto its keystroke. What a terminal emulator component needs
    (`INP15`); everything else leaves it off and gets the classic stream.
    The terminal target ignores it — a tty cannot report releases (`INP16`).
    */
    bool keyRelease;
    int targetFps = 60;         /// GPU pacing
    int idleTimeoutMs = -1;     /// TUI: wake `present` without input (< 0 = never)
    PointerUnit pointerUnit;    /// what pointer positions are measured in (`HST18`)
}

/**
The unit an application reads pointer positions in (`HST18`).

Cells are the default and the toolkit's own unit: a widget's rect is in cells,
so a hit test against a laid-out tree wants a cell. But the third render level
exists precisely for applications that paint their own pixels (`HST3`), and
those hit-test in pixels — a text selection lands mid-glyph, a popup's close
box is 14 px across, and quantising to a cell would move both.

Only pointer and wheel $(B positions) change; sizes stay in cells (an
application still reasons about its surface in the toolkit's unit) and so does
the resize event, which is about the surface rather than the pointer. The GPU
arm implements this by handing its synthesizer a 1×1 cell — the divisor it
already applies — so nothing on the path learns a second coordinate system. The
terminal arm ignores it: a cell is the only unit a tty reports.
*/
enum PointerUnit : ubyte
{
    cells,  /// the toolkit's unit, and what a widget tree is laid out in
    pixels, /// device pixels, for an application painting its own surface
}

/**
The bookkeeping every host shares: what the application asked of this frame.

Mixed into each concrete host so the three targets cannot drift on the meaning
of "quit", "another frame please" or "do not draw this one".

`opCapacity` is how much of the per-frame buffer the host carries inline —
$(LREF frameOpCapacity) for a host that paints, $(LREF recordedOpCapacity) for
one that does not. The names are qualified because a template mixin's body is
looked up at the point it is mixed in, and a host module should not have to
import the spelling of a member it never names.
*/
mixin template HostState(size_t opCapacity = frameOpCapacity)
{
    /// The per-frame buffer's type at this host's inline capacity.
    private alias HostOps = sparkles.ui_app.host.FrameOpsOf!opCapacity;

    // A mixin template resolves names at its instantiation site, so the
    // imports must travel with it rather than rely on this module's.
    private import core.time : Duration;
    private import sparkles.input : Mods;

    private bool _quit;
    private bool _frameRequested;
    private bool _skipFrame;
    private HostOps _ops;

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

    /**
    Ask to be woken within `d` even if no input arrives (`HST16`).

    `RunConfig.idleTimeoutMs` is fixed at startup, but an application's next
    self-imposed deadline moves every frame — a panel due to open, a poll
    whose cap survives on some backend. Like `requestFrame` this is an ask,
    re-armed each frame it is still wanted (the frame bracket clears it);
    repeated asks keep the soonest. The expiry is observable as the same
    idle wake `idleTimeoutMs` produces: a frame pass with no event. The
    terminal arm's park deadline becomes the minimum of the two; a GPU arm
    at a fixed cadence subsumes it; the recorder records it per frame.
    */
    void wakeIn(Duration d) @safe pure nothrow @nogc
    {
        if (d < _wakeIn)
            _wakeIn = d;
    }

    /// The soonest ask this frame, `Duration.max` when none was made.
    Duration wakeAsk() const @safe pure nothrow @nogc => _wakeIn;

    private Duration _wakeIn = Duration.max;

    /**
    The modifier keys held right now (`HST17`).

    A level, not an edge, and deliberately not folded from the event stream:
    an application asking "is Shift down?" while dragging a stationary mouse
    gets no event to fold, and would read a stale answer forever. The arms
    refresh it once per frame from whatever their target can say — the GPU
    arm from the synthesizer's live poll, the others from the last event that
    carried one, which is the best that target has.
    */
    Mods modifiers() const @safe pure nothrow @nogc => _mods;

    /// Called by the loop, not the app.
    private void noteModifiers(Mods m) @safe pure nothrow @nogc { _mods = m; }

    private Mods _mods;

    /// The per-frame display list, owned and reused by the host (`HST4`). An
    /// application appends; it never sizes or clears one.
    ref HostOps ops() return @safe pure nothrow @nogc => _ops;

    /// Clears the per-frame flags and buffer. Called by the loop, not the app.
    private void beginFrameState() @safe pure nothrow @nogc
    {
        _frameRequested = false;
        _skipFrame = false;
        _wakeIn = Duration.max;
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
    // The font errand (`HST14`): the GPU host reloads and re-measures; the
    // terminal accepts and drops (the emulator owns the glyphs there).
    int fs = h.fontSizePx;
    h.fontSize(fs + 2);
    // The modifier level (`HST17`) — `HostState` carries it, so every host
    // that mixes the state in satisfies this for free.
    Mods m = h.modifiers;
});

/**
The optional `HST15` errands, capability-by-presence — the ladder's shape,
like `isCanvas`'s optional primitives: a component probes with these and
keeps its polled fallback where a host offers neither (a foreign embedding,
an older host). Presence is compile-time; availability is per-run —
`spawnDaemon` returns `false` where no ring drives this run (the blocking
fallback arms, the recorder), and that is the same cue.
*/
enum bool canSpawnDaemon(H) = __traits(compiles, (ref H h) {
    bool live = h.spawnDaemon(delegate void() {});
});

/// ditto
enum bool canWake(H) = __traits(compiles, (ref H h) { h.wake(); });

/**
The default draw phase: nothing.

The loop's third callback (`HST13`) — the post-display-list slot inside the
frame bracket where an application with a renderer of its own paints through
the host's canvas. Most applications have no such renderer, so the arms take
this no-op by default and it costs nothing (an empty template instantiation).
*/
void noDraw(Host)(ref Host) {}

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

/**
The modifier level `e` reports, or `fallback` where it reports none (`HST17`).

What an arm with no live modifier poll refreshes its host from: four of the
event kinds carry a level, and everything else — focus, resize, end of input —
leaves the last one standing rather than clearing it, since none of them is
evidence a key was let go.
*/
Mods modsOf(in Event e, Mods fallback) @safe
{
    import sparkles.input : GestureEvent, KeyEvent, match, PointerEvent,
        WheelEvent;

    return e.match!(
        (in KeyEvent k) => k.mods,
        (in PointerEvent p) => p.mods,
        (in WheelEvent w) => w.mods,
        (in GestureEvent g) => g.mods,
        (in _) => fallback,
    );
}

version (unittest)
{
    private struct FullFake
    {
        mixin HostState!recordedOpCapacity;
        Size size;
        InputCapabilities capabilities;
        Backend backend;
        void pointerShape(PointerShape) @safe pure nothrow @nogc {}
        int fontSizePx() const @safe pure nothrow @nogc => 18;
        void fontSize(int) @safe pure nothrow @nogc {}
    }

    static assert(isHost!FullFake, "the concept must accept a complete host");
}

@("ui_app.host.frameStateIsPerFrame")
@safe pure nothrow @nogc
unittest
{
    static struct Fake
    {
        mixin HostState!recordedOpCapacity;
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

@("ui_app.host.wakeInKeepsTheSoonestAskPerFrame")
@safe pure nothrow @nogc
unittest
{
    import core.time : msecs;

    static struct Fake
    {
        mixin HostState;
        void newFrame() { beginFrameState(); }
    }

    Fake h;
    assert(h.wakeAsk == Duration.max, "no ask until the application makes one");

    // Repeated asks keep the soonest — a later, longer one must not push the
    // wake back past a deadline already promised.
    h.wakeIn(150.msecs);
    h.wakeIn(33.msecs);
    h.wakeIn(500.msecs);
    assert(h.wakeAsk == 33.msecs);

    // An ask is per-frame, like requestFrame: re-armed each frame it is
    // still wanted, so a lapsed deadline stops costing wakeups by itself.
    h.newFrame();
    assert(h.wakeAsk == Duration.max);
}

@("ui_app.host.opsBufferIsReused")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.geometry : Rect;

    static struct Fake
    {
        mixin HostState!recordedOpCapacity;
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

@("ui_app.host.modsOfKeepsTheLastLevelWhereAnEventCarriesNone")
@safe
unittest
{
    import sparkles.input : charEvent, EndOfInput, FocusEvent, PointerAction,
        PointerButton, PointerEvent, Point, ResizeEvent;

    const shift = Mods(shift: true);
    const ctrl = Mods(ctrl: true);

    // The four kinds that carry a level report it.
    assert(modsOf(charEvent('a', shift), Mods.init) == shift);
    assert(modsOf(Event(PointerEvent(PointerAction.press, PointerButton.left,
        Point(3, 4), ctrl)), Mods.init) == ctrl);

    // Everything else leaves the last one standing. A focus change or a resize
    // is not evidence a key was let go, and clearing on one would drop Shift
    // out from under a drag the moment the window was resized.
    assert(modsOf(Event(FocusEvent(true)), shift) == shift);
    assert(modsOf(Event(ResizeEvent(Size(80, 24))), shift) == shift);
    assert(modsOf(Event(EndOfInput()), shift) == shift);
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
