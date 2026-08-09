/**
The recording target: a host with no window and no tty (`TST1`–`TST3`).

$(B This is the point of the package, not a test helper.) An application's frame
loop has never been testable — `apps/hue`'s GUI module is excluded from its test
build, `apps/terminal`'s entry point likewise — not because the logic is
untestable but because it sits next to a window. A host that satisfies the same
contract while recording instead of drawing removes that reason.

Scripted events go in; what the application $(I asked for) comes out — the frames
it drew, the operations in each, whether it skipped one, the pointer shapes and
clipboard writes it requested, whether it quit. A test asserts on intent, not on
pixels, which is both easier to write and more stable than a screenshot.

It is also the parity oracle (`TST3`): the same script driven through this and
through a live backend must produce the same operation stream, so "one definition,
three targets" is checkable at $(I session) scope rather than only per widget.
*/
module sparkles.ui_app.record;

import sparkles.base.term_control : PointerShape;
import sparkles.input : Event, InputCapabilities, cellPointer;
import sparkles.ui.canvas : DrawOp, RecordingCanvas;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.host : FrameOpsOf, HostState, isHost, recordedOpCapacity,
    RunConfig, withRealSize;

/// One recorded frame: what the application drew, and whether it drew at all.
struct RecordedFrame
{
    DrawOp[] ops;  /// the display list it produced
    bool skipped;  /// it declined to draw (`skipFrame`)
    bool requested; /// it asked for another frame after this one
}

/**
A host that records instead of drawing.

Satisfies $(REF isHost, sparkles,ui_app,host), so an application's `present` and
`handle` are the same code here as against a live backend.
*/
struct RecordingHost
{
    // A recorder is the one host a test puts on the stack — by the dozen, and
    // on whatever thread the runner picked. `recordedOpCapacity` keeps it a few
    // hundred bytes instead of a quarter-megabyte; every frame's operations are
    // `dup`ed to the heap on the line below anyway, so nothing here was ever
    // served by inline storage.
    mixin HostState!recordedOpCapacity;

    // ── what the caller sets up ─────────────────────────────────────────────

    /// The surface size reported to the application.
    Size size = Size(80, 24);
    /// The capabilities it declares. A terminal by default, since that is the
    /// more constrained target and the one a test should default to proving
    /// against.
    InputCapabilities capabilities = cellPointer;
    /// The backend it claims to be.
    Backend backend = Backend.tui;
    /// Seconds per frame, for an application that animates.
    float frameSeconds = 1.0f / 60;

    // ── what the run produced ───────────────────────────────────────────────

    /// Every frame, in order.
    RecordedFrame[] frames;
    /// Pointer shapes requested, in order.
    PointerShape[] shapes;
    /// Clipboard writes, window titles, and out-of-band terminal writes.
    string[] clipboardWrites;
    /// ditto
    string[] titles;
    /// ditto
    string[] outOfBand;
    /// Whether the application asked for fullscreen at any point.
    bool fullscreenToggled;

@safe:

    /// The canvas an application reaches for at the third render level. A
    /// recorder, so even a hand-written renderer is checkable here.
    RecordingCanvas canvas;

    void pointerShape(PointerShape s) pure nothrow { shapes ~= s; }
    void clipboard(scope const(char)[] text) pure nothrow { clipboardWrites ~= text.idup; }
    void title(scope const(char)[] t) pure nothrow { titles ~= t.idup; }
    void writeOutOfBand(scope const(char)[] seq) pure nothrow { outOfBand ~= seq.idup; }

    /// Reported `false`, matching a terminal and Android — a test that assumes
    /// fullscreen exists should have to say so.
    bool fullscreenSupported() const pure nothrow @nogc => false;
    /// ditto
    void toggleFullscreen() pure nothrow { fullscreenToggled = true; }

    /// The font errand (`HST14`), recorded: each request is captured and
    /// becomes the reported size — a test asserts both the asks and the value
    /// the application then reads back. The cell `size` does not change (the
    /// recorder has no real glyphs to re-measure).
    int fontSizePx() const pure nothrow @nogc => fontSizePxValue;
    /// ditto
    void fontSize(int px) pure nothrow
    {
        fontSizePxValue = px;
        fontSizeRequests ~= px;
    }

    /// ditto
    int fontSizePxValue = 18;
    /// ditto
    int[] fontSizeRequests;

    /// The operations of the last frame, for the common single-frame assertion.
    const(DrawOp)[] lastOps() const pure nothrow @nogc
        => frames.length ? frames[$ - 1].ops : null;

    /// Frames actually drawn — a skipped one is not a frame the user saw.
    size_t drawnFrames() const pure nothrow @nogc
    {
        size_t n;
        foreach (ref f; frames)
            if (!f.skipped)
                ++n;
        return n;
    }
}

static assert(isHost!RecordingHost, "the recorder must satisfy the same"
    ~ " contract as a live host — that is the whole point of it");


/**
Drives `present`/`handle` over a scripted event list and returns the record.

One frame per event, plus a first frame before any input (an application draws
before it is touched) and one more for each `requestFrame`. The loop ends when
the script runs out or the application quits — whichever comes first, so a test
for "does `q` quit" does not have to pad its script.

Params:
    cfg = the run configuration the application would have been given
    present = called to build each frame
    handle = called per event
    script = the events to deliver, in order
    setup = an optional lambda to configure the host (size, capabilities)
        before the run
*/
RecordingHost runRecorded(Present, Handle)(
    in RunConfig cfg, scope Present present, scope Handle handle,
    in Event[] script, scope void delegate(ref RecordingHost) @safe setup = null)
{
    RecordingHost h;
    if (setup !is null)
        setup(h);

    void frame()
    {
        h.beginFrameState();
        present(h);
        h.frames ~= RecordedFrame(
            ops: h.ops()[].dup,
            skipped: h.frameSkipped,
            requested: h.frameRequested,
        );
    }

    frame(); // an application draws before anything happens to it

    foreach (e; script)
    {
        if (h.quitRequested)
            break;
        handle(h, withRealSize(e, h.size));
        frame();
    }

    // Honour the last frame's request, so an animation's final step is recorded
    // rather than cut off by the script ending.
    while (!h.quitRequested && h.frames.length && h.frames[$ - 1].requested)
        frame();

    return h;
}

// ---------------------------------------------------------------------------
// Tests — the contract, asserted with no window and no tty.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.geometry : Rect;
    import sparkles.input : charEvent, Key, keyEvent, PointerAction,
        PointerButton, PointerEvent, Point, ResizeEvent;

    // Attributes are explicit: a non-templated helper does NOT infer them, so
    // an unannotated one is `@system` and makes every lambda calling it
    // `@system` too — which then cannot be called from a `@safe` unittest.
    private DrawOp fill(int x) @safe pure nothrow
        => DrawOp(kind: OpKind.fillRect, rect: Rect(x, 0, 1, 1));
}

@("ui_app.record.framesAndOps")
@safe
unittest
{
    // The shape every application has: draw in `present`, react in `handle`.
    int marks;
    auto rec = runRecorded(RunConfig.init,
        (ref RecordingHost h) { h.ops() ~= fill(marks); },
        (ref RecordingHost h, in Event e) { ++marks; },
        [charEvent('a'), charEvent('b')]);

    // One frame before input, then one per event.
    assert(rec.frames.length == 3);
    assert(rec.frames[0].ops.length == 1 && rec.frames[0].ops[0].rect.x == 0);
    assert(rec.frames[1].ops[0].rect.x == 1);
    assert(rec.frames[2].ops[0].rect.x == 2);
    assert(rec.drawnFrames == 3);
}

@("ui_app.record.quitStopsTheRun")
@safe
unittest
{
    // A test for "does `q` quit" should not have to pad its script: the loop
    // ends at the quit, and the remaining events are not delivered.
    int handled;
    auto rec = runRecorded(RunConfig.init,
        (ref RecordingHost h) {},
        (ref RecordingHost h, in Event e) {
            ++handled;
            h.quit();
        },
        [charEvent('q'), charEvent('x'), charEvent('y')]);

    assert(rec.quitRequested);
    assert(handled == 1, "events after the quit are not delivered");
    assert(rec.frames.length == 2, "the frame the quit happened in is recorded");
}

@("ui_app.record.skippedFramesAreVisible")
@safe
unittest
{
    // `skipFrame` is part of the contract, so a test can assert an application
    // declines to draw when nothing changed — the property `apps/terminal`'s
    // near-zero idle CPU depends on.
    bool dirty = true;
    auto rec = runRecorded(RunConfig.init,
        (ref RecordingHost h) {
            if (!dirty)
                return h.skipFrame();
            h.ops() ~= fill(0);
            dirty = false;
        },
        (ref RecordingHost h, in Event e) {},
        [charEvent('a'), charEvent('b')]);

    assert(rec.frames.length == 3);
    assert(!rec.frames[0].skipped && rec.frames[1].skipped && rec.frames[2].skipped);
    assert(rec.drawnFrames == 1, "a skipped frame is not one the user saw");
}

@("ui_app.record.requestedFramesAreDelivered")
@safe
unittest
{
    // An animation asks for one more frame at a time; the run keeps going until
    // it stops asking, rather than being cut off when the script ends.
    int steps = 3;
    auto rec = runRecorded(RunConfig.init,
        (ref RecordingHost h) {
            if (--steps > 0)
                h.requestFrame();
        },
        (ref RecordingHost h, in Event e) {},
        Event[].init);

    assert(rec.frames.length == 3, "the animation ran to its own end");
    assert(!rec.frames[$ - 1].requested, "and stopped asking");
}

@("ui_app.record.platformCallsAreCaptured")
@safe
unittest
{
    // The errands an application performs on its host are recorded as intent,
    // which is what makes them assertable at all — a real run writes them to a
    // terminal or a window manager and leaves nothing to check.
    auto rec = runRecorded(RunConfig.init,
        (ref RecordingHost h) { h.pointerShape(PointerShape.pointer); },
        (ref RecordingHost h, in Event e) {
            h.clipboard("copied");
            h.title("new title");
            h.writeOutOfBand("\x1b]52;c;…\x07");
            h.toggleFullscreen();
        },
        [charEvent('y')]);

    assert(rec.shapes == [PointerShape.pointer, PointerShape.pointer]);
    assert(rec.clipboardWrites == ["copied"]);
    assert(rec.titles == ["new title"]);
    assert(rec.outOfBand.length == 1);
    assert(rec.fullscreenToggled);

    // Fullscreen is reported unsupported by default — a terminal and Android
    // both lack it, so a test that assumes otherwise has to say so.
    assert(!rec.fullscreenSupported);
}

@("ui_app.record.fontSizeErrandIsCaptured")
@safe
unittest
{
    // The font errand (`HST14`): each ask is recorded, and the value the
    // application reads back is the one it set — a Ctrl+= handler's whole
    // observable contract, with no window and no atlas.
    auto rec = runRecorded(RunConfig.init,
        (ref RecordingHost h) {},
        (ref RecordingHost h, in Event e) { h.fontSize(h.fontSizePx + 2); },
        [charEvent('+'), charEvent('+')]);

    assert(rec.fontSizeRequests == [20, 22]);
    assert(rec.fontSizePx == 22);
}

@("ui_app.record.resizeIsNormalized")
@safe
unittest
{
    // `HST7`: the producer's zero-size resize never reaches the application.
    Size seen;
    auto rec = runRecorded(RunConfig.init,
        (ref RecordingHost h) {},
        (ref RecordingHost h, in Event e) {
            import sparkles.input : match;
            e.match!(
                (in ResizeEvent r) { seen = r.size; },
                (in _) {},
            );
        },
        [Event(ResizeEvent())],
        (ref RecordingHost h) { h.size = Size(120, 40); });

    assert(seen == Size(120, 40), "the application never sees a zero resize");
}

@("ui_app.record.capabilitiesReachTheApplication")
@safe
unittest
{
    // A held-key affordance must ask before using it (`INP16`), and this is
    // where that branch becomes testable: the same application code, two
    // declared targets, two paths.
    bool usedHeldKeys;
    auto run(InputCapabilities caps)
    {
        usedHeldKeys = false;
        return runRecorded(RunConfig.init,
            (ref RecordingHost h) { usedHeldKeys = h.capabilities.keyRelease; },
            (ref RecordingHost h, in Event e) {},
            Event[].init,
            (ref RecordingHost h) { h.capabilities = caps; });
    }

    run(cellPointer);
    assert(!usedHeldKeys, "a terminal cannot report key-up");

    run(InputCapabilities(keyRelease: true));
    assert(usedHeldKeys);
}
