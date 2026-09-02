/**
Lossless, owned, Regular events at the native WSI boundary.

These are deliberately not `sparkles.input.Event`: toolkit events are already
cell-quantized and scroll-normalized, while this layer preserves both logical
and physical coordinates and the source metadata needed to make that policy.
*/
module sparkles.wsi.events;

import std.sumtype : SumType;
public import std.sumtype : match;

import sparkles.base.buffer : InlineBuffer;
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

struct TextCommittedEvent { InlineBuffer!(char, 256) text; }

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

struct CompositionEvent
{
    InlineBuffer!(char, 512) preedit;
    ushort selectionStart;
    ushort selectionLength;
    ushort cursor;
    CompositionSegment[8] segments;
    ubyte segmentCount;
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
    offered,
    entered,
    moved,
    left,
    dropped,
    completed,
    failed,
}

struct DataOfferEvent
{
    OfferId offer;
    DataOfferAction action;
    InlineBuffer!(char, 128) mimeType;
    LogicalPosition logicalPosition;
}

struct PopupConfiguredEvent
{
    PhysicalPosition position;
    PhysicalSize size;
    uint repositionToken;
}

struct PopupDismissedEvent {}
struct CursorChangedEvent { PointerShape shape; }

alias WindowEventPayload = SumType!(NoWindowEvent, ReadyEvent, ExposedEvent,
    CloseRequestedEvent, DestroyedEvent, OccludedEvent, FocusChangedEvent,
    SurfaceMetricsChangedEvent, MovedEvent, OutputEnteredEvent, FrameReadyEvent,
    KeyboardEvent, TextCommittedEvent, CompositionEvent, PointerEvent,
    RelativePointerEvent, ScrollEvent, TouchEvent, OutputEvent, DataOfferEvent,
    PopupConfiguredEvent, PopupDismissedEvent, CursorChangedEvent);

/// Sequence-stamped event. Sequence zero is reserved for uninitialized data.
struct WindowEvent
{
    ulong sequence;
    WindowId window;
    WindowEventPayload payload;
}

@("wsi.events.textAndCompositionOwnTheirBytes")
@safe
pure nothrow @nogc
unittest
{
    TextCommittedEvent committed;
    assert(committed.text.assign("λ"));
    auto a = WindowEvent(1, WindowId(1, 1), WindowEventPayload(committed));
    auto b = a;
    assert(a == b);
    assert(b.payload.match!(
        (in TextCommittedEvent t) => t.text[] == "λ",
        _ => false));
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
