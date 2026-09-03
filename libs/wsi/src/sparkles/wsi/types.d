/**
Unit-explicit geometry, identity, configuration, and errors for `sparkles:wsi`.

No type in this module owns a platform object. The values are copyable and
comparable so a native trace can be recorded and replayed without a live
display connection.
*/
module sparkles.wsi.types;

import expected : Expected, err, ok;
import std.math : isFinite;

import sparkles.base.buffer : InlineBuffer;
import sparkles.base.text.cstring : hasInteriorNul;
import sparkles.base.text.utf8 : validateUtf8;
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

/**
How a process presents itself while it has windows. AppKit only; every other
backend ignores it, because on those platforms it is the window manager's
decision rather than the application's.
*/
enum ActivationPolicy : ubyte
{
    /// A normal application: menu bar, Dock tile, and it may become frontmost.
    /// The default, because a process that opens a window is one.
    regular,
    /// No Dock tile; windows may still take focus. For an accessory to a
    /// terminal session, where taking over the Dock would be an imposition.
    accessory,
}

/// Process-wide WSI options, fixed at `open` and not per window.
struct WsiConfig
{
    BackendPreference backend;
    ActivationPolicy activation;
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
    InlineBuffer!(char, 256) title;
    LogicalSize logicalSize = LogicalSize(800, 600);
    bool visible = true;
    bool resizable = true;
    bool transparent;
    DecorationPreference decorations;
    WindowStartupState state;
    WindowId parent;

    /**
    Why no backend can realise this configuration, or `null` if one can.

    The backend-independent half of validation, in one place because the
    backends had drifted apart: AppKit rejected an embedded NUL in the title and
    Wayland did not, and AppKit accepted a zero logical size that Wayland
    refused — so the same `WindowConfig` meant different things per platform.
    What stays with each backend is what only it knows: which
    `DecorationPreference` and `WindowStartupState` it has implemented.

    The title is text on its way to a C string it is not yet — three of the four
    platform APIs take one — which makes an embedded NUL a silent truncation
    rather than a rejection. Hence `hasInteriorNul` and not `isExactStringz`:
    the terminator is written at the seam, not stored here.

    A query rather than an `invariant`, because a `WindowConfig` is filled in
    field by field after default construction (`config.title.assign(name)`), so
    there is no point at which the value is known to be complete.

    Returns a static message, so the slice outlives any caller.
    */
    const(char)[] fault() const @safe pure nothrow @nogc
    {
        if (!logicalSize.width.isFinite || !logicalSize.height.isFinite
            || logicalSize.width <= 0 || logicalSize.height <= 0
            || logicalSize.width > int.max || logicalSize.height > int.max)
            return "invalid logical window size";
        if (validateUtf8(title[]).hasError)
            return "window title is not valid UTF-8";
        if (hasInteriorNul(title[]))
            return "window title contains an embedded NUL";
        return null;
    }
}

@("wsi.types.configFaultIsBackendIndependent")
@safe pure nothrow @nogc
unittest
{
    WindowConfig config;
    assert(config.fault is null);          // the defaults are realisable

    config.logicalSize = LogicalSize(0, 600);
    assert(config.fault == "invalid logical window size");
    config.logicalSize = LogicalSize(800, double.nan);
    assert(config.fault == "invalid logical window size");
    config.logicalSize = LogicalSize(800, 600);

    assert(config.title.assign("caf\xC3\xA9"));
    assert(config.fault is null);
    assert(config.title.assign("caf\xC3"));       // a truncated sequence
    assert(config.fault == "window title is not valid UTF-8");

    // A NUL would reach the platform as a shorter title than `.length` claims.
    assert(config.title.assign("before\0after"));
    assert(config.fault == "window title contains an embedded NUL");
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
    InlineBuffer!(char, 96) diagnostic;
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
    {
        // The fallback text fits the inline capacity by construction.
        const assigned =
            result.diagnostic.assign("diagnostic exceeds inline capacity");
        assert(assigned);
    }
    return result;
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
