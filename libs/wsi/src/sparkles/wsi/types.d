/**
Unit-explicit geometry, identity, configuration, and errors for `sparkles:wsi`.

No type in this module owns a platform object. The values are copyable and
comparable so a native trace can be recorded and replayed without a live
display connection.
*/
module sparkles.wsi.types;

import expected : Expected, err, ok;
import std.math : isFinite;

import sparkles.math : ScreenPosition, ScreenSize;

@safe:

/// Device-independent coordinates used by application layout.
alias LogicalPosition = ScreenPosition!double;
/// ditto
alias LogicalSize = ScreenSize!double;
/// Signed device pixels; positions may lie outside a window or output.
alias PhysicalPosition = ScreenPosition!int;
/// Unsigned framebuffer/surface pixels.
alias PhysicalSize = ScreenSize!uint;

/// Physical pixels per logical unit.
struct ScaleFactor
{
    double value = 1.0;

    bool valid() const pure nothrow @nogc => value > 0.0 && isFinite(value);
}

/// One atomic logical/physical/scale observation.
struct SurfaceMetrics
{
    LogicalSize logicalSize;
    PhysicalSize physicalSize;
    ScaleFactor scale;

    /// A zero pixel extent suspends presentation but is not a WSI error.
    bool suspended() const pure nothrow @nogc
        => physicalSize.width == 0 || physicalSize.height == 0;
}

/**
Fixed-capacity owned UTF-8 bytes.

Assignment rejects overflow rather than cutting a multi-byte sequence. UTF-8
validation belongs to the shared base conversion milestone; this type's job is
ownership and deterministic storage.
*/
struct InlineUtf8(size_t Capacity)
if (Capacity > 0 && Capacity <= ushort.max)
{
    private char[Capacity] bytes_;
    private ushort length_;

    /// Replace the value. On overflow the old value is retained.
    bool assign(scope const(char)[] value) pure nothrow @nogc
    {
        if (value.length > Capacity)
            return false;

        bytes_[] = 0;
        bytes_[0 .. value.length] = value;
        length_ = cast(ushort) value.length;
        return true;
    }

    /// Borrow this value's own storage.
    const(char)[] value() const return pure nothrow @nogc
        => bytes_[0 .. length_];

    /// Remove all bytes, including unused bytes relevant to value equality.
    void clear() pure nothrow @nogc
    {
        bytes_[] = 0;
        length_ = 0;
    }

    size_t length() const pure nothrow @nogc => length_;
    bool empty() const pure nothrow @nogc => length_ == 0;
}

/// Generation-checked public identity. The all-zero value is invalid.
struct ObjectId(Tag)
{
    uint slot;
    uint generation;

    bool valid() const pure nothrow @nogc
        => slot != 0 && generation != 0;
}

struct WindowTag {}
struct OutputTag {}
struct SeatTag {}
struct PointerTag {}
struct OfferTag {}

alias WindowId = ObjectId!WindowTag;
alias OutputId = ObjectId!OutputTag;
alias SeatId = ObjectId!SeatTag;
alias PointerId = ObjectId!PointerTag;
alias OfferId = ObjectId!OfferTag;

/// Native implementation selected for this WSI instance.
enum BackendKind : ubyte
{
    wayland,
    x11,
    win32,
    appkit,
}

/// Backend request. `automatic` uses platform/runtime availability.
enum BackendPreference : ubyte
{
    automatic,
    wayland,
    x11,
    win32,
    appkit,
}

struct WsiConfig
{
    BackendPreference backend;
}

enum DecorationPreference : ubyte
{
    automatic,
    server,
    client,
    none,
}

enum WindowStartupState : ubyte
{
    normal,
    minimized,
    maximized,
    fullscreen,
}

struct WindowConfig
{
    InlineUtf8!256 title;
    LogicalSize logicalSize = LogicalSize(800, 600);
    bool visible = true;
    bool resizable = true;
    bool transparent;
    DecorationPreference decorations;
    WindowStartupState state;
    WindowId parent;
}

/// Stable error categories suitable for exhaustive handling.
enum WsiErrorKind : ubyte
{
    unsupported,
    unavailable,
    wrongThread,
    staleId,
    capacity,
    reentrant,
    invalidArgument,
    nativeFailure,
    closed,
}

/// Operation that failed without conflating WSI with byte-stream I/O.
enum WsiOperation : ubyte
{
    none,
    open,
    attach,
    createWindow,
    command,
    queryHandle,
    dispatch,
    close,
}

/// Structured, allocation-free WSI failure.
struct WsiError
{
    WsiErrorKind kind;
    BackendKind backend;
    WsiOperation operation;
    long nativeCode;
    InlineUtf8!96 diagnostic;
}

struct WsiExpectedHook
{
    static immutable bool enableDefaultConstructor = false;

    static void onAccessEmptyValue(E)(E error) pure nothrow @nogc
        => assert(false, "accessed the value of an error WsiResult");
}

alias WsiResult(T) = Expected!(T, WsiError, WsiExpectedHook);

WsiResult!T wsiOk(T)(auto ref T value)
{
    import core.lifetime : forward;

    return ok!(WsiError, WsiExpectedHook)(forward!value);
}

WsiResult!void wsiOk() pure nothrow @nogc
    => ok!(WsiError, WsiExpectedHook)();

WsiResult!T wsiErr(T)(WsiError error) pure nothrow @nogc
    => err!(T, WsiExpectedHook)(error);

WsiError wsiError(WsiErrorKind kind, WsiOperation operation,
    BackendKind backend = BackendKind.wayland, long nativeCode = 0,
    scope const(char)[] diagnostic = null) pure nothrow @nogc
{
    WsiError result = WsiError(kind, backend, operation, nativeCode);
    if (!result.diagnostic.assign(diagnostic))
        cast(void) result.diagnostic.assign("diagnostic exceeds inline capacity");
    return result;
}

@("wsi.types.inlineTextOwnsAndRejectsOverflow")
pure nothrow @nogc
unittest
{
    InlineUtf8!8 text;
    assert(text.assign("wayland"));
    assert(text.value == "wayland");
    assert(!text.assign("too-long!"));
    assert(text.value == "wayland");
    text.clear();
    assert(text.empty);
}

@("wsi.types.idsRequireSlotAndGeneration")
pure nothrow @nogc
unittest
{
    assert(!WindowId.init.valid);
    assert(WindowId(1, 1).valid);
    assert(!WindowId(1, 0).valid);
}

@("wsi.types.metricsKeepUnitsTogether")
pure nothrow @nogc
unittest
{
    const live = SurfaceMetrics(LogicalSize(400, 300),
        PhysicalSize(800, 600), ScaleFactor(2));
    assert(!live.suspended && live.scale.valid);
    assert(SurfaceMetrics(LogicalSize(400, 300), PhysicalSize(0, 0),
        ScaleFactor(2)).suspended);
}
