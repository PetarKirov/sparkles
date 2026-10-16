/**
Lossless, owned, Regular events at the native WSI boundary.

These are deliberately not `sparkles.input.Event`: toolkit events are already
cell-quantized and scroll-normalized, while this layer preserves both logical
and physical coordinates and the source metadata needed to make that policy.
*/
module sparkles.wsi.events;

import std.sumtype : SumType;
import std.traits : EnumMembers;
public import std.sumtype : match;

import sparkles.base.pool.handle : Handle;
import sparkles.input.events : KeyAction, Mods, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.wsi.types;

@safe:

struct NoWindowEvent {}
struct ReadyEvent { SurfaceMetrics metrics; }
struct ExposedEvent {}
struct CloseRequestedEvent {}
struct DestroyedEvent {}
struct OccludedEvent { bool occluded; }

/**
Events the queue dropped because it was full (`ED5`). Not attributable to one
window, so `window` is `WindowId.init`; the count is the number lost since the
previous drain. It is delivered last in a drain and carries the sequence of the
last dropped event, so the delivered order stays strictly increasing and the gap
in sequence numbers names exactly what was lost.
*/
struct EventsDroppedEvent { uint count; }
struct FocusChangedEvent { bool focused; }
struct SurfaceMetricsChangedEvent { SurfaceMetrics metrics; }
struct MovedEvent { PhysicalPosition position; }

struct OutputEnteredEvent
{
    OutputId output;
    bool entered;
}

struct FrameReadyEvent
{
    ulong token;
    long predictedPresentationNanoseconds;
}

enum KeyLocation : ubyte
{
    standard,
    left,
    right,
    numpad,
}

enum LogicalKeyKind : ubyte
{
    unknown,
    character,
    named,
}

struct PhysicalKey
{
    uint nativeCode;
    uint usbUsage;
}

/*
Layout-derived identity at the key's unshifted base level (matching
`sparkles.input`'s `unshifted` convention): `character` is the base
spelling under the current layout, and `nativeCode` carries the platform's
logical code — an xkb keysym, a Win32 virtual key, or a macOS function-key
scalar — which is all a key without a printable base spelling has.
*/
struct LogicalKey
{
    LogicalKeyKind kind;
    dchar character;
    uint nativeCode;
}

struct KeyboardEvent
{
    PhysicalKey physical;
    LogicalKey logical;
    KeyLocation location;
    KeyAction action;
    Mods modifiers;
    bool composing;
}

/**
Names an event's text: a handle into the delivering queue's `TextPool`
(`ED8`). Read it with the WSI's `withText` during the drain callback that
delivered the event; afterwards it is stale. `TextId.init` names the empty
text.
*/
struct EventTextTag {}

/// ditto
alias TextId = Handle!EventTextTag;

/// The most bytes one event text keeps (`ED8`): longer text is cut at a UTF-8
/// boundary and reported truncated. It is also the largest offset a
/// composition field holds, which is why those fit a `ushort`.
enum size_t maxEventText = ushort.max;

/// The longest MIME type an offer may name. A longer one drops the offer
/// instead of shortening it into a different type (`ED8`).
enum size_t maxMimeType = 255;

struct TextCommittedEvent { TextId text; }

enum CompositionSegmentStyle : ubyte
{
    none,
    underline,
    selected,
    converted,
}

struct CompositionSegment
{
    ushort start;
    ushort length;
    CompositionSegmentStyle style;
}

/**
A pre-edit update. Offsets are UTF-8 byte offsets into the pre-edit text
(`preedit`); an event whose `preedit` is `TextId.init` ends the composition.
*/
struct CompositionEvent
{
    TextId preedit;
    ushort selectionStart;
    ushort selectionLength;
    ushort cursor;
    CompositionSegment[8] segments;
    ubyte segmentCount;

    /**
    Clamps every offset to the first `kept` bytes of the pre-edit — what the
    queue stored when the native text was longer than `maxEventText`.
    `kept` lies on a code-point boundary, so a clamped offset does too; a
    segment that starts at or past it is dropped, one that crosses it is
    shortened.
    */
    void clampTo(size_t kept) @safe pure nothrow @nogc
    {
        static ushort at(size_t offset, size_t kept)
            => cast(ushort)(offset < kept ? offset : kept);

        const selectionEnd = at(selectionStart + selectionLength, kept);
        selectionStart = at(selectionStart, kept);
        selectionLength = cast(ushort)(selectionEnd - selectionStart);
        cursor = at(cursor, kept);

        ubyte count;
        foreach (segment; segments[0 .. segmentCount])
        {
            if (segment.start >= kept)
                continue;
            const end = at(segment.start + segment.length, kept);
            segments[count++] = CompositionSegment(segment.start,
                cast(ushort)(end - segment.start), segment.style);
        }
        segments[count .. segmentCount] = CompositionSegment.init;
        segmentCount = count;
    }
}

enum PointerPhase : ubyte
{
    entered,
    left,
    moved,
    pressed,
    released,
}

struct PointerEvent
{
    PointerId pointer;
    PointerPhase phase;
    PointerButton button = PointerButton.none;
    LogicalPosition logicalPosition;
    PhysicalPosition physicalPosition;
    Mods modifiers;
    double pressure;
}

struct RelativePointerEvent
{
    PointerId pointer;
    double dx;
    double dy;
    bool raw;
}

enum ScrollSource : ubyte
{
    unknown,
    wheel,
    finger,
    continuous,
}

enum ScrollUnit : ubyte
{
    logical,
    pixel,
}

enum ScrollPhase : ubyte
{
    none,
    began,
    changed,
    ended,
    momentum,
}

/*
Sign convention (Wayland's axis convention, every backend translates to it):
positive `dy`/`discreteY` scrolls the content view down, positive
`dx`/`discreteX` scrolls right; a mouse wheel rolled away from the user is
negative `dy`. `inverted` reports the platform's natural-scrolling flag
without changing the deltas.
*/
struct ScrollEvent
{
    LogicalPosition logicalPosition;
    PhysicalPosition physicalPosition;
    double dx;
    double dy;
    int discreteX;
    int discreteY;
    ScrollSource source;
    ScrollUnit unit;
    ScrollPhase phase;
    bool inverted;
    Mods modifiers;
}

enum TouchPhase : ubyte
{
    began,
    moved,
    ended,
    cancelled,
}

struct TouchEvent
{
    PointerId contact;
    TouchPhase phase;
    LogicalPosition logicalPosition;
    PhysicalPosition physicalPosition;
    double pressure;
    double majorRadius;
    double minorRadius;
}

enum OutputChange : ubyte
{
    added,
    changed,
    removed,
}

struct OutputEvent
{
    OutputId output;
    OutputChange change;
    PhysicalPosition position;
    PhysicalSize size;
    ScaleFactor scale;
    uint refreshMilliHertz;
    bool primary;
}

enum DataOfferAction : ubyte
{
    /// The offer exists and names this MIME type (one event per type).
    offered,
    entered,
    moved,
    left,
    dropped,
    completed,
    failed,
    /// An offer this application made ended: another source replaced it,
    /// or it was withdrawn (`DT1`).
    withdrawn,
}

struct DataOfferEvent
{
    OfferId offer;
    DataOfferAction action;
    TextId mimeType; /// at most `maxMimeType` bytes
    LogicalPosition logicalPosition;
}

struct PopupConfiguredEvent
{
    PhysicalPosition position;
    PhysicalSize size;
    uint repositionToken;
}

struct PopupDismissedEvent {}
/**
The pointer shape a window now shows. Stored as the shape's position in
`PointerShape`: that enum is a `string`, and holding one would put a pointer
in every `WindowEvent` (`ED8` keeps events pointer-free).
*/
struct CursorChangedEvent
{
    private ubyte shape_;

    this(PointerShape shape) @safe pure nothrow @nogc
    {
        static foreach (i, member; EnumMembers!PointerShape)
            if (shape == member)
                shape_ = cast(ubyte) i;
    }

    PointerShape shape() const @safe pure nothrow @nogc
    {
        static immutable PointerShape[] shapes = [EnumMembers!PointerShape];
        return shapes[shape_];
    }
}

alias WindowEventPayload = SumType!(NoWindowEvent, ReadyEvent, ExposedEvent,
    CloseRequestedEvent, DestroyedEvent, OccludedEvent, FocusChangedEvent,
    SurfaceMetricsChangedEvent, MovedEvent, OutputEnteredEvent, FrameReadyEvent,
    KeyboardEvent, TextCommittedEvent, CompositionEvent, PointerEvent,
    RelativePointerEvent, ScrollEvent, TouchEvent, OutputEvent, DataOfferEvent,
    PopupConfiguredEvent, PopupDismissedEvent, CursorChangedEvent,
    EventsDroppedEvent);

/// Sequence-stamped event. Sequence zero is reserved for uninitialized data.
struct WindowEvent
{
    ulong sequence;
    WindowId window;
    WindowEventPayload payload;
}

/**
Whether `next` supersedes `tail` at the back of a bounded event queue: the
same window and a payload kind where only the newest observation matters —
surface metrics, window position, and expose opportunities. This is the
bounded queue's answer to native event floods: an interactive resize can
batch hundreds of configures into one dispatch, and during a Win32 or
AppKit modal phase the application cannot drain at all, so keeping the
latest observation beats failing on capacity. Input, text, focus, and
lifecycle events never coalesce.
*/
bool supersedes(in WindowEvent tail, in WindowEvent next)
    @safe pure nothrow @nogc
{
    if (tail.window != next.window)
        return false;
    static bool bothAre(Payload)(in WindowEvent a, in WindowEvent b)
        => isKind!Payload(a) && isKind!Payload(b);
    return bothAre!SurfaceMetricsChangedEvent(tail, next)
        || bothAre!MovedEvent(tail, next)
        || bothAre!ExposedEvent(tail, next);
}

/// The text `event` carries, or `TextId.init` if its kind carries none.
TextId textOf(in WindowEvent event) @safe pure nothrow @nogc
    => event.payload.match!(
        (in TextCommittedEvent e) => e.text,
        (in CompositionEvent e) => e.preedit,
        (in DataOfferEvent e) => e.mimeType,
        _ => TextId.init);

/// Makes `event` name `id` as its text; an event that carries none is left
/// unchanged.
void setTextOf(ref WindowEvent event, TextId id) @safe pure nothrow @nogc
{
    event.payload.match!(
        (ref TextCommittedEvent e) { e.text = id; },
        (ref CompositionEvent e) { e.preedit = id; },
        (ref DataOfferEvent e) { e.mimeType = id; },
        (ref _) {});
}

// match, not std.sumtype.has: `has!T` on a const sum answers for `const T`
// only, and these events arrive through `in` parameters.
private bool isKind(Payload)(in WindowEvent event) @safe pure nothrow @nogc
    => event.payload.match!((in Payload _) => true, _ => false);

/// Whether this event's kind can ever be superseded — the queue may scan
/// past it when coalescing; everything else anchors ordering.
bool coalescible(in WindowEvent event) @safe pure nothrow @nogc
    => isKind!SurfaceMetricsChangedEvent(event) || isKind!MovedEvent(event)
        || isKind!ExposedEvent(event);

@("wsi.events.supersedesCoalescesOnlyLatestObservationKinds")
@safe pure nothrow @nogc
unittest
{
    const window = WindowId(1, 1);
    const other = WindowId(2, 1);
    const metrics = SurfaceMetrics(LogicalSize(1, 1), PhysicalSize(1, 1),
        ScaleFactor(1));
    auto resizeA = WindowEvent(1, window,
        WindowEventPayload(SurfaceMetricsChangedEvent(metrics)));
    auto resizeB = WindowEvent(2, window,
        WindowEventPayload(SurfaceMetricsChangedEvent(metrics)));
    assert(supersedes(resizeA, resizeB));
    // Never across windows, kinds, or for input.
    assert(!supersedes(WindowEvent(1, other, resizeA.payload), resizeB));
    assert(!supersedes(resizeA,
        WindowEvent(2, window, WindowEventPayload(ExposedEvent()))));
    assert(!supersedes(
        WindowEvent(1, window, WindowEventPayload(KeyboardEvent())),
        WindowEvent(2, window, WindowEventPayload(KeyboardEvent()))));
}

@("wsi.events.eventsHoldNoPointerAndFitTwoCacheLines")
@safe pure nothrow @nogc
unittest
{
    import std.traits : hasIndirections;

    // `ED8`: text lives in the queue's pool, so an event is plain data and
    // assigning one is `@safe` — no `@trusted` copy, no reference count.
    static assert(!hasIndirections!WindowEvent);
    static assert(WindowEvent.sizeof <= 128);

    auto a = WindowEvent(1, WindowId(1, 1),
        WindowEventPayload(TextCommittedEvent(TextId(3, 1))));
    WindowEvent b;
    b = a;
    assert(a == b);
}

@("wsi.events.compositionClampsToTheKeptText")
@safe pure nothrow @nogc
unittest
{
    CompositionEvent e;
    e.selectionStart = 4;
    e.selectionLength = 8;
    e.cursor = 20;
    e.segments[0] = CompositionSegment(0, 6, CompositionSegmentStyle.underline);
    e.segments[1] = CompositionSegment(6, 6, CompositionSegmentStyle.selected);
    e.segments[2] = CompositionSegment(12, 9, CompositionSegmentStyle.none);
    e.segmentCount = 3;

    e.clampTo(9);
    assert(e.selectionStart == 4 && e.selectionLength == 5);
    assert(e.cursor == 9);
    assert(e.segmentCount == 2);
    assert(e.segments[0] == CompositionSegment(0, 6, CompositionSegmentStyle.underline));
    assert(e.segments[1] == CompositionSegment(6, 3, CompositionSegmentStyle.selected));
    assert(e.segments[2] == CompositionSegment.init);
}

@("wsi.events.scrollDoesNotNormalizeAwaySource")
pure nothrow @nogc
unittest
{
    const e = ScrollEvent(dx: 0.25, dy: -1.5, discreteY: -1,
        source: ScrollSource.finger, unit: ScrollUnit.pixel,
        phase: ScrollPhase.momentum, inverted: true);
    assert(e.source == ScrollSource.finger);
    assert(e.unit == ScrollUnit.pixel && e.phase == ScrollPhase.momentum);
    assert(e.inverted && e.discreteY == -1);
}

/*
Shared Linux key-translation policy. Wayland delivers evdev keycodes
directly and X11 delivers evdev + 8; both express chord modifiers through
the fixed xkb real-modifier bit positions (Shift, Lock, Control, Mod1–Mod5),
which the X11 core state mask shares. Location falls back to `standard` on
an unknown code — never to a wrong pairing — because left/right identity
lives in the keycode itself under the evdev-standard map.
*/
package KeyLocation evdevKeyLocation(uint evdevCode) @safe pure nothrow @nogc
{
    switch (evdevCode)
    {
        case 42: // KEY_LEFTSHIFT
        case 29: // KEY_LEFTCTRL
        case 56: // KEY_LEFTALT
        case 125: // KEY_LEFTMETA
            return KeyLocation.left;
        case 54: // KEY_RIGHTSHIFT
        case 97: // KEY_RIGHTCTRL
        case 100: // KEY_RIGHTALT
        case 126: // KEY_RIGHTMETA
            return KeyLocation.right;
        case 55: // KEY_KPASTERISK
        case 71: .. case 83: // KEY_KP7 .. KEY_KPDOT
        case 96: // KEY_KPENTER
        case 98: // KEY_KPSLASH
            return KeyLocation.numpad;
        default:
            return KeyLocation.standard;
    }
}

/// Shared xkb classifier: a printable base-level spelling is a character
/// key; anything else keeps its keysym as the named identity.
package LogicalKey logicalFromKeysym(uint keysym, uint utf32)
    @safe pure nothrow @nogc
{
    if (utf32 >= 0x20 && utf32 != 0x7F)
        return LogicalKey(LogicalKeyKind.character, cast(dchar) utf32, keysym);
    return keysym != 0
        ? LogicalKey(LogicalKeyKind.named, dchar.init, keysym)
        : LogicalKey.init;
}

@("wsi.events.keysymClassifierSeparatesTextFromNamedKeys")
@safe pure nothrow @nogc
unittest
{
    const a = logicalFromKeysym(0x61, 'a');
    assert(a.kind == LogicalKeyKind.character && a.character == 'a'
        && a.nativeCode == 0x61);
    const escape = logicalFromKeysym(0xFF1B, 0x1B);
    assert(escape.kind == LogicalKeyKind.named && escape.nativeCode == 0xFF1B);
    const shift = logicalFromKeysym(0xFFE1, 0);
    assert(shift.kind == LogicalKeyKind.named && shift.nativeCode == 0xFFE1);
    assert(logicalFromKeysym(0, 0).kind == LogicalKeyKind.unknown);
}

/// Chord modifiers only: Lock (caps) and Mod2 (num lock) are latched states.
package Mods xkbRealMods(uint mask) @safe pure nothrow @nogc
    => Mods(
        ctrl: (mask & 0x4) != 0,
        alt: (mask & 0x8) != 0,
        shift: (mask & 0x1) != 0,
        super_: (mask & 0x40) != 0);

@("wsi.events.evdevLocationAndRealModsAreSharedPolicy")
@safe pure nothrow @nogc
unittest
{
    assert(evdevKeyLocation(42) == KeyLocation.left);
    assert(evdevKeyLocation(97) == KeyLocation.right);
    assert(evdevKeyLocation(96) == KeyLocation.numpad);
    assert(evdevKeyLocation(30) == KeyLocation.standard);
    assert(xkbRealMods(0x1 | 0x40) == Mods(shift: true, super_: true));
    assert(xkbRealMods(0x2 | 0x10) == Mods());
}

@("wsi.events.cursorChangedRoundTripsEveryShape")
@safe pure nothrow @nogc
unittest
{
    static foreach (member; EnumMembers!PointerShape)
        assert(CursorChangedEvent(member).shape == member);
    static assert(CursorChangedEvent.sizeof == 1);
}
