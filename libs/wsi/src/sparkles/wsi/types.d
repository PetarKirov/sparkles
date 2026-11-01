/**
Unit-explicit geometry, identity, configuration, and errors for `sparkles:wsi`.

No type in this module owns a platform object. The values are copyable and
comparable so a native trace can be recorded and replayed without a live
display connection.
*/
module sparkles.wsi.types;

import sparkles.base.expected : Expected, err, ok;
import std.math : isFinite;

import sparkles.base.buffer : InlineBuffer;
import sparkles.base.pool.handle : Handle;
import sparkles.base.text.cstring : hasInteriorNul;
public import sparkles.base.app_identity : AppIdentity;
import sparkles.base.text.utf8 : validateUtf8;
import sparkles.math : ScreenPosition, ScreenSize;
import sparkles.metadata.wire : WireName;

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
///
/// A fieldless value with one `@property`: structural reflection presents it
/// as its value (a leaf), not as a wrapper around one.
struct ScaleFactor
{
    private double value_ = 1.0;

    @property double value() const pure nothrow @nogc => value_;

    bool valid() const pure nothrow @nogc => value_ > 0.0 && isFinite(value_);
}

/// One atomic logical/physical/scale observation.
/**
Pixels at each edge of a surface that something else covers or reserves:
system bars, a display cutout, a soft keyboard. Content may extend under
them, but nothing the user must read or reach belongs there.
*/
struct PhysicalInsets
{
    uint left;
    uint top;
    uint right;
    uint bottom;
}

struct SurfaceMetrics
{
    LogicalSize logicalSize;
    PhysicalSize physicalSize;
    ScaleFactor scale;
    /// Zero on a platform that reports no covered edges, and on every
    /// desktop backend today.
    PhysicalInsets safeInsets;
    /// The part of the surface outside the window, each side: transparent,
    /// for a client-drawn frame's shadow and the resize border beyond the
    /// window's edge (`F13`, $(LREF FrameExtents)). The sizes above are the
    /// whole surface's; the window is the surface inside this margin. Zero
    /// unless the application asked for extents and the frame is its own.
    PhysicalInsets frameMargin;

    /// A zero pixel extent suspends presentation but is not a WSI error.
    bool suspended() const pure nothrow @nogc
        => physicalSize.width == 0 || physicalSize.height == 0;

    /// The region inside `safeInsets`, in logical units: its top-left corner
    /// and its extent.
    LogicalPosition safeOrigin() const pure nothrow @nogc
        => LogicalPosition(safeInsets.left / scale.value,
            safeInsets.top / scale.value);

    /// ditto
    LogicalSize safeSize() const pure nothrow @nogc
    {
        static double span(uint extent, uint a, uint b) pure nothrow @nogc
            => a + b >= extent ? 0 : extent - a - b;
        return LogicalSize(
            span(physicalSize.width, safeInsets.left, safeInsets.right) / scale.value,
            span(physicalSize.height, safeInsets.top, safeInsets.bottom) / scale.value);
    }
}

@("wsi.types.safeRegionIsTheSurfaceInsideItsInsets")
@safe pure nothrow @nogc
unittest
{
    const metrics = SurfaceMetrics(LogicalSize(400, 300), PhysicalSize(800, 600),
        ScaleFactor(2), PhysicalInsets(0, 40, 0, 160));
    assert(metrics.safeOrigin == LogicalPosition(0, 20));
    assert(metrics.safeSize == LogicalSize(400, 200));

    const covered = SurfaceMetrics(LogicalSize(10, 10), PhysicalSize(10, 10),
        ScaleFactor(1), PhysicalInsets(6, 0, 6, 0));
    assert(covered.safeSize.width == 0, "insets wider than the surface leave none");
}

/**
Generation-checked public identity: a `sparkles.base.pool` handle, a 0-based
slot index plus the generation the slot was issued at. Generations start at
1, so the all-zero value is invalid; a removed object's ids are stale.
*/
alias ObjectId(Tag) = Handle!Tag;

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
    android,
}

/// Backend request. `automatic` uses platform/runtime availability.
enum BackendPreference : ubyte
{
    @WireName("auto") automatic,
    wayland,
    x11,
    win32,
    appkit,
    android,
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
    AppIdentity app; /// who the application is (`F13`'s dock identity)
}

/**
Interactive-resize edge for compositor-driven resizing, with
`xdg_toplevel`'s `resize_edge` values (a vertical|horizontal bitfield the
other platforms can map). Client affordances need this wherever no server
decoration exists to grab — GNOME draws none.
*/
enum ResizeEdge : uint
{
    none = 0,
    top = 1,
    bottom = 2,
    left = 4,
    topLeft = 5,
    bottomLeft = 6,
    right = 8,
    topRight = 9,
    bottomRight = 10,
}

/**
Maps a position to the border zone it lands in — the shared client-side
affordance for `startInteractiveResize`, sized by `grip` logical units.
*/
ResizeEdge resizeEdgeAt(in SurfaceMetrics metrics, double x, double y,
    double grip = 16) pure nothrow @nogc
{
    const width = metrics.logicalSize.width;
    const height = metrics.logicalSize.height;
    uint edge;
    if (y < grip) edge |= ResizeEdge.top;
    else if (y > height - grip) edge |= ResizeEdge.bottom;
    if (x < grip) edge |= ResizeEdge.left;
    else if (x > width - grip) edge |= ResizeEdge.right;
    return cast(ResizeEdge) edge;
}

@("wsi.types.resizeEdgeAt.zonesAndCorners")
pure nothrow @nogc
unittest
{
    const metrics = SurfaceMetrics(LogicalSize(200, 100),
        PhysicalSize(200, 100), ScaleFactor(1));
    assert(resizeEdgeAt(metrics, 100, 50) == ResizeEdge.none);
    assert(resizeEdgeAt(metrics, 8, 50) == ResizeEdge.left);
    assert(resizeEdgeAt(metrics, 195, 95) == ResizeEdge.bottomRight);
    assert(resizeEdgeAt(metrics, 100, 5) == ResizeEdge.top);
}

/**
Explicit pointer capture, as two distinct capabilities (F10): `capture`
routes every pointer event to the window even outside its content until
released, `confine` keeps the pointer inside the content area. Raw relative
motion is a separate switch (`setRelativePointer`). A backend without a
mode reports typed `unsupported`; it never silently succeeds.
*/
enum PointerCaptureMode : ubyte
{
    none,
    capture,
    confine,
}

enum DecorationPreference : ubyte
{
    automatic,
    server,
    client,
    none,
}

/**
Who draws a window's frame — title bar, buttons, borders — as the window system
decided it (`F13`). `server`: the window system does. `client`: it declined,
as GNOME's compositor declines every request, and the application draws its own
frame and drives the window from it (`startInteractiveMove`,
`startInteractiveResize`, `setMaximized`, `setMinimized`, `showWindowMenu`).
`none`: no frame at all — a fullscreen-only target, or `DecorationPreference.none`.
*/
enum DecorationMode : ubyte
{
    server,
    client,
    none,
}

/**
What a client-drawn frame draws outside its window (`F13`), in logical units:
a transparent margin on every side for its shadow, the part of it that still
takes a press to resize the window, and the window's corner radius, outside
which the window is not opaque. A backend that draws the window into a
surface larger than the window — Wayland's window geometry — applies them
while the frame is the client's, and reports the margin with the metrics.

GNOME's are GTK's: a 20-pixel margin (Adwaita's shadow reaches 19), the
outer 12 pixels of the window's edge resizing it, and 15-pixel corners.

Setting them promises that the window is opaque inside its rounded corners:
a backend tells the compositor so (Wayland's opaque region), which then
draws nothing behind it.
*/
struct FrameExtents
{
    uint margin;  /// outside the window, each side; 0: none
    uint resize;  /// how far outside the window a press resizes it, within `margin`
    uint radius;  /// the window's corner radius

@safe pure nothrow @nogc:

    /// Why these extents cannot be applied, or `null`: a resize border
    /// wider than its margin, or a margin or radius past 1024.
    string fault() const
        => resize > margin ? "a frame's resize border lies within its margin"
            : margin > 1024 || radius > 1024 ? "a frame's margin and radius are at most 1024"
            : null;

    /**
    The margin a window in `state` keeps: none unless the frame is the
    client's, and none maximized or fullscreen, where the window fills its
    output and casts no shadow. A tiled window keeps it, as GTK's does, so
    the surface does not change size as the window tiles.
    */
    uint marginIn(in WindowState state) const
        => state.decorations != DecorationMode.client
            || state.has(ToplevelState.maximized) || state.has(ToplevelState.fullscreen)
            ? 0 : margin;

    /// How far beyond the window a press resizes it, in `state`: none where
    /// an edge is held (`WindowState.edgesHeld`).
    uint resizeIn(in WindowState state) const
    {
        const m = marginIn(state);
        return state.edgesHeld ? 0 : resize < m ? resize : m;
    }

    /// The corner radius in `state`: square where an edge is held.
    uint radiusIn(in WindowState state) const
        => marginIn(state) == 0 || state.edgesHeld ? 0 : radius;
}

///
@("wsi.types.frameExtents.followTheState")
@safe pure nothrow @nogc
unittest
{
    const gnome = FrameExtents(margin: 20, resize: 12, radius: 15);
    WindowState s;
    assert(gnome.marginIn(s) == 0, "the window system's own frame: no margin");
    s.decorations = DecorationMode.client;
    assert(gnome.marginIn(s) == 20 && gnome.resizeIn(s) == 12 && gnome.radiusIn(s) == 15);
    s.flags = ToplevelState.tiledLeft;
    assert(gnome.marginIn(s) == 20 && gnome.resizeIn(s) == 0 && gnome.radiusIn(s) == 0);
    s.flags = ToplevelState.maximized;
    assert(gnome.marginIn(s) == 0 && gnome.resizeIn(s) == 0 && gnome.radiusIn(s) == 0);
    assert(FrameExtents(margin: 8, resize: 12).resizeIn(WindowState(DecorationMode.client)) == 8,
        "the resize border lies within the margin");
    // Extents that cannot be applied are refused where a window is made too.
    assert(gnome.fault is null && FrameExtents(margin: 8, resize: 12).fault !is null);
    WindowConfig config;
    config.frameExtents = FrameExtents(margin: 4, resize: 12);
    assert(config.fault !is null);
}

/// One state a window manager reports for a toplevel (`F14`), as a bit of
/// $(LREF WindowState.flags).
enum ToplevelState : ushort
{
    maximized = 1 << 0,
    fullscreen = 1 << 1,
    resizing = 1 << 2,   /// an interactive resize is in progress
    activated = 1 << 3,  /// the window has the user's attention: draw it active
    tiledLeft = 1 << 4,  /// an edge sits against another window or the screen
    tiledRight = 1 << 5,
    tiledTop = 1 << 6,
    tiledBottom = 1 << 7,
    suspended = 1 << 8,  /// not visible: skip frames, keep state
}

/// What the window manager offers for a toplevel, as a bit of
/// $(LREF WindowState.capabilities): a frame shows only the controls it offers.
enum WindowCapability : ubyte
{
    windowMenu = 1 << 0,
    maximize = 1 << 1,
    fullscreen = 1 << 2,
    minimize = 1 << 3,
    all = windowMenu | maximize | fullscreen | minimize,
}

/**
A toplevel's frame as the window manager has configured it: who draws it, the
states that change how it looks (maximized and tiled edges drop the resize
borders and rounded corners; an inactive window dims), and the controls the
window manager offers. A backend reports it once before $(B ReadyEvent) and
again whenever it changes; one that never reports it draws its own frames.
*/
struct WindowState
{
    DecorationMode decorations;
    ubyte capabilities = WindowCapability.all;
    ushort flags;
    /// The largest the window would usefully be, in logical units: the
    /// output's work area, as the compositor bounds it
    /// (`xdg_toplevel.configure_bounds`); zero where it says nothing. A
    /// renderer keeping room through a resize can make it this size at once.
    ushort boundsWidth, boundsHeight;

@safe pure nothrow @nogc:

    /// Whether `state` is set.
    bool has(ToplevelState state) const => (flags & state) != 0;

    /// Whether the window manager offers `capability`.
    bool offers(WindowCapability capability) const => (capabilities & capability) != 0;

    /// Whether any edge is held: a maximized, fullscreen or tiled window
    /// cannot be resized from its borders.
    bool edgesHeld() const
        => (flags & (ToplevelState.maximized | ToplevelState.fullscreen
            | ToplevelState.tiledLeft | ToplevelState.tiledRight
            | ToplevelState.tiledTop | ToplevelState.tiledBottom)) != 0;
}

///
@("wsi.types.windowState.flagsAndCapabilities")
@safe pure nothrow @nogc
unittest
{
    WindowState s;
    assert(s.decorations == DecorationMode.server);
    assert(s.offers(WindowCapability.minimize) && !s.has(ToplevelState.maximized));
    assert(!s.edgesHeld);
    s.flags = ToplevelState.tiledLeft | ToplevelState.activated;
    assert(s.edgesHeld && s.has(ToplevelState.activated));
    s.capabilities = WindowCapability.windowMenu;
    assert(!s.offers(WindowCapability.maximize));
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
    /// What the frame draws outside the window when it is the client's
    /// (`F13`); the default draws nothing outside it.
    FrameExtents frameExtents;
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
        if (const extents = frameExtents.fault)
            return extents;
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

@("wsi.types.idsRequireAGeneration")
pure nothrow @nogc
unittest
{
    assert(!WindowId.init.valid);
    assert(WindowId(0, 1).valid);
    assert(!WindowId(1, 0).valid);
    static assert(!is(OutputId : WindowId));
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
