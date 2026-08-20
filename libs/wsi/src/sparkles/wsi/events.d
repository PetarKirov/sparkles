/**
Lossless, owned, Regular events at the native WSI boundary.

These are deliberately not `sparkles.input.Event`: toolkit events are already
cell-quantized and scroll-normalized, while this layer preserves both logical
and physical coordinates and the source metadata needed to make that policy.
*/
module sparkles.wsi.events;

import std.sumtype : SumType;
public import std.sumtype : match;

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

struct TextCommittedEvent { InlineUtf8!256 text; }

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
    InlineUtf8!512 preedit;
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
    InlineUtf8!128 mimeType;
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
        (in TextCommittedEvent t) => t.text.value == "λ",
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
