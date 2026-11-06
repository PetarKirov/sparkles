/**
The native arm of the host: an application in a `sparkles:wsi` window, drawn
by `sparkles:ui-vulkan` (the `gui-vulkan` configuration; plan slice V4 of
`docs/specs/ui-vulkan`).

The raylib arm's mirror, with the difference that motivates it: a window here
$(B waits) instead of polling. The loop parks in the event loop until the
window system has something — input, a resize, a frame callback — or the
application's own deadline (`requestFrame`, `wakeIn`) comes due, so an idle
window draws nothing and costs nothing. Input is translated once, by
$(REF WsiInput, sparkles,ui_app,wsi_input) (`INT5`), and handed to the
application; a frame follows input, and on Wayland waits for the compositor's
frame callback, while X11 presents at once and its FIFO swapchain paces it.

Declining a frame (`skipFrame`) acquires no image and presents nothing. A
frame the canvas abandons on exhausted memory presents the ground and asks
for another; a lost device is rebuilt, surface to canvas, and the frame drawn
again on the new one.

Glyphs arrive with plan slice V3: until then text draws nothing, and the
cells are measured from the cell font by `sparkles:font`'s cell rule, the
font file found through `sparkles:raylib-text`'s resolver (an interim source,
which the font library's catalog replaces).
*/
module sparkles.ui_app.native_loop;

version (UiAppGuiVulkan):

import sparkles.ui_app.prepared_specimen : PreparedSpecimenFont;
import sparkles.ui_app.specimen_font : sameSpecimenRequest, SpecimenFontRequest, SpecimenLatencyStats;

import core.time : dur, Duration, MonoTime, msecs, nsecs, seconds;
import std.algorithm.comparison : max, min;

import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;
import sparkles.base.term_color : RgbColor;
import sparkles.base.term_control : PointerShape;
import sparkles.event_horizon : DefaultLoop, LoopConfig;
import sparkles.appearance : ContrastLevel, overriddenBy, SystemAppearance;
version (Android) {} else version (linux)
    import sparkles.appearance.portal : PortalAppearance;
import sparkles.input : ColorSchemeEvent, Event, InputCapabilities, InputTextPool, mousePointer, PointerButton,
    touchPointer;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.effect : EffectRegistry;
import sparkles.ui.geometry : Size;
import sparkles.ui.image : ImageRegistry;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.gui_options : FontRequest, WindowCells, WindowSystem;
import sparkles.ui_app.interface_font : InterfaceMeasure, uiFontFamilyOf, uiStepSizes, xHeightRatio;
import sparkles.ui_app.host : HostState, isHost, noDraw, noSetup, noShutdown, PointerUnit,
    RunConfig, TouchGestures, withRealSize;
import sparkles.ui_app.lifecycle : Failure, FrameResult, Lifecycle, Rebuild, Surface;
import sparkles.ui_app.frame_title : fitTitle, TitleFace, titleCssPx, titleCssPxOf,
    titleFacePattern, titlePatternOf, TitleStrip;
import sparkles.ui_app.client_frame : ClientFrame, crossCoverage, FrameAction, FrameColours,
    FrameGeometry, FrameHit, FramePart, FrameShape;
import sparkles.ui_app.wsi_input : TouchContacts, WsiInput;
import sparkles.ui.style : Palette;
import sparkles.ui_vulkan;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
import sparkles.vulkan_wsi.presenter : pollCompleted, PresentWait, waitForNewest;
import sparkles.profiling : FrameClock, FrameFlags, FrameHistory, FramePhase, FrameRecord,
    FrameStats, writeChromeTrace;
// `PRF20`: empty inline functions unless built with `version (SparklesTracy)`.
import sparkles.profiling.tracy : tracyFrameMark, tracyPlot, tracyZone;
import sparkles.profiling.counters.frame : FrameCounters;
import sparkles.profiling.zones : cpuZone, FrameZones, ZoneStats;
import sparkles.wsi;

/// The pointer shape over a resize border's edge or corner.
PointerShape resizeCursor(ResizeEdge edge) @safe pure nothrow @nogc
{
    switch (edge)
    {
        case ResizeEdge.left, ResizeEdge.right: return PointerShape.ewResize;
        case ResizeEdge.top, ResizeEdge.bottom: return PointerShape.nsResize;
        case ResizeEdge.topLeft, ResizeEdge.bottomRight: return PointerShape.nwseResize;
        case ResizeEdge.topRight, ResizeEdge.bottomLeft: return PointerShape.neswResize;
        default: return PointerShape.default_;
    }
}

/// What the native arm opens.
struct NativeRequest
{
    string title;             /// the window's title
    AppIdentity app;          /// who the application is (`RunConfig.app`)
    /// The palette a client-drawn frame is drawn in (`F13`): the
    /// application's theme where it gives one, else one derived from `ground`.
    Palette framePalette;
    bool hasFramePalette;     /// ditto
    FontRequest font;         /// the cell font
    WindowCells cells;        /// the window's size, in cells
    int fontSizePoints = 18;  /// resolved against the window's scale
    int fontSizePxOverride;   /// a pixel size used verbatim (`CLI6`)
    string[] extraFontSources; /// directories searched before the system's
    /// The colour the window is cleared to under everything drawn.
    RgbColor ground = RgbColor(0, 0, 0);
}

/// The cell font's file and metrics at a pixel size.
struct CellFont
{
    string path;       /// the resolved face
    int px;            /// the pixel size it is measured at
    int cellW = 1;     ///
    int cellH = 1;     ///
    /// The face's bytes, and the pixels per em its cells were measured at:
    /// what the canvas draws text with (`UVK18`).
    const(ubyte)[] bytes;
    /// Its bold, italic and bold-italic siblings' bytes, empty where the
    /// family has none (text in that style then draws in `bytes`).
    const(ubyte)[] bold, italic, boldItalic;
    uint ppem;         /// ditto
    /// The em the glyphs draw at, exactly: the line height over the face's
    /// `hhea` ascender-to-descender span, the scale the raylib arm's fonts
    /// draw at (`ScaleForPixelHeight`), so both arms' glyphs are one size.
    ulong emNumerator, emDenominator = 1;
    /// Pixels from a cell's top: the baseline, the underline (and its
    /// thickness) and the strikethrough.
    int ascent;
    int underlineY;    /// ditto
    int underlineHeight = 1; /// ditto
    int strikeY;       /// ditto
    /// The faces text falls back to where the cell font has no glyph, in
    /// order (`systemFallbackFacePaths`), each at its own exact em.
    FallbackFont[] fallbacks;
}

/// A fallback face's bytes and the em its glyphs draw at: the cell's line
/// height over the face's own `hhea` span, as the raylib arm sizes every face.
struct FallbackFont
{
    const(ubyte)[] bytes; ///
    ulong emNumerator, emDenominator = 1; ///
}

/**
Resolves `request`'s cell font and measures its cells for a line `px` pixels
tall from ascent to descent, as the raylib arm sizes its fonts:
`sparkles:font`'s cell rule (`FTM19`) — the width of `0`, the height of the
line — at the em that gives that line. `false` when no face resolves or the
face cannot be measured.
*/
bool measureCellFont(in FontRequest request, in string[] extraSources, int px,
    out CellFont cell) @system
    => measureCellFontImpl(request, extraSources, px, cell, null);

/// Remeasures already loaded primary, styled and fallback faces without I/O.
bool remeasureCellFont(in CellFont loaded, int px, out CellFont cell) @system
    => measureCellFontImpl(FontRequest.init, null, px, cell, &loaded);

/// Resizing a loaded source performs no filesystem or font-database lookup.
@("ui_app.native_loop.remeasureLoadedFacesWithoutIO")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    CellFont loaded;
    loaded.path = "/this/path/does/not/exist.ttf";
    loaded.bytes = cast(const(ubyte)[]) read(buildPath(root, "DejaVuSansMono.ttf"));
    loaded.bold = loaded.bytes;
    loaded.fallbacks = [FallbackFont(loaded.bytes)];
    CellFont small, big;
    assert(remeasureCellFont(loaded, 18, small));
    assert(remeasureCellFont(small, 36, big));
    assert(big.bytes.ptr == loaded.bytes.ptr && big.bold.ptr == loaded.bold.ptr);
    assert(big.fallbacks[0].bytes.ptr == loaded.bytes.ptr);
    assert(big.cellW > small.cellW && big.cellH > small.cellH);
}

private bool measureCellFontImpl(in FontRequest request, in string[] extraSources, int px,
    out CellFont cell, scope const(CellFont)* loaded) @system
{
    import std.file : read;
    import sparkles.base.unique : makeUnique;
    import sparkles.font : cellMetrics, CellMetrics, charMap, fontErr, hhea, instance, InstanceSize,
        openFace, PointWorkspace, Ppem;
    import sparkles.raylib_text.font_discovery : FontSources;
    import sparkles.raylib_text.font_resolve : resolveFontPath;

    FontSources sources;
    sources.dirs = request.searchDirs.dup ~ extraSources.dup;
    sources.useSystemFontDb = request.useSystemFontDb;
    const path = loaded !is null ? loaded.path : resolveFontPath(request.family, sources);
    if (path.length == 0)
        return false;
    const bytes = loaded !is null ? loaded.bytes : cast(const(ubyte)[]) read(path);
    auto face = openFace(bytes);
    if (face.hasError)
        return false;
    auto cmap = charMap(face.value);
    if (cmap.hasError)
        return false;
    auto points = makeUnique!PointWorkspace();
    if (points.empty)
        return false;
    // The size names the line's ascent plus descent in pixels, as the raylib
    // arm's fonts do, so both arms lay out the same grid: measured once at
    // that many pixels per em, then at the em that gives that line.
    auto at(int ppem)
    {
        const size = Ppem.fromInteger(ppem < 1 ? 1 : ppem);
        auto inst = instance(face.value, InstanceSize.pixels(size.value), null);
        return inst.hasError ? fontErr!CellMetrics(inst.error)
            : inst.value.cellMetrics(cmap.value, ppem < 1 ? 1 : ppem, *points);
    }
    px = px < 1 ? 1 : px;
    const probe = at(px);
    if (probe.hasError)
        return false;
    const line = probe.value.ascent + probe.value.descent;
    const em = line > 0 ? cast(int)((long(px) * px + line / 2) / line) : px;
    const metrics = at(em);
    if (metrics.hasError)
        return false;
    const m = metrics.value;
    const cellH = cast(int)(m.height < 1 ? 1 : m.height);
    // Both measured down from the cell's top (`FTM19`); without `post`, the
    // underline a pixel under the baseline. Kept inside the cell.
    const ascent = cast(int) m.baseline;
    const thickness = cast(int)(m.hasUnderline && m.underlineThickness > 0 ? m.underlineThickness : 1);
    int underlineY = m.hasUnderline ? cast(int) m.underlinePosition : ascent + 1;
    if (underlineY + thickness > cellH)
        underlineY = cellH - thickness;
    // The family's styled faces, found as the raylib arm finds them without
    // fontconfig: by their sibling files.
    import sparkles.raylib_text.font_discovery : fontVariantPaths;

    string boldPath, italicPath, boldItalicPath;
    if (loaded is null)
        fontVariantPaths(path, boldPath, italicPath, boldItalicPath);
    static const(ubyte)[] load(string p)
        => p.length ? cast(const(ubyte)[]) read(p) : null;
    const hh = hhea(face.value);
    const span = hh.hasValue ? long(hh.value.ascender) - hh.value.descender : 0;
    const upem = face.value.unitsPerEm;
    cell = CellFont(path, px, cast(int)(m.width < 1 ? 1 : m.width), cellH, bytes,
        loaded !is null ? loaded.bold : load(boldPath),
        loaded !is null ? loaded.italic : load(italicPath),
        loaded !is null ? loaded.boldItalic : load(boldItalicPath),
        cast(uint)(em < 1 ? 1 : em),
        span > 0 ? ulong(px) * upem : cast(ulong)(em < 1 ? 1 : em), span > 0 ? cast(ulong) span : 1,
        ascent, underlineY, thickness,
        ascent - (em * 28 + 50) / 100); // about half the x-height
    // Icons, text the face lacks, and emoji, from the faces the raylib arm
    // falls back to.
    import sparkles.raylib_text.font_resolve : systemFallbackFacePaths;

    string nerdPath, regularPath, emojiPath;
    if (loaded is null)
        systemFallbackFacePaths(path, sources, nerdPath, regularPath, emojiPath);
    const count = loaded !is null ? loaded.fallbacks.length : 3;
    const paths = [regularPath, nerdPath, emojiPath];
    foreach (i; 0 .. count)
    {
        if (loaded is null && !paths[i].length)
            continue;
        const fb = loaded !is null ? loaded.fallbacks[i].bytes : load(paths[i]);
        auto fbFace = openFace(fb);
        if (fbFace.hasError)
            continue;
        const fbHh = hhea(fbFace.value);
        const fbSpan = fbHh.hasValue ? long(fbHh.value.ascender) - fbHh.value.descender : 0;
        if (fbSpan > 0)
            cell.fallbacks ~= FallbackFont(fb, ulong(px) * fbFace.value.unitsPerEm, cast(ulong) fbSpan);
    }
    return true;
}

/**
Finds and reads the interface face (`UVK20`, design-system `GLY10`) into
`session`: `request.font.ui` (`--ui-font`) where given, else the desktop's
interface font where `desktop` names one, else a conventional sans list
(`uiFontFamilyOf`) — resolved like the cell font, through the system font
database or the request's directories, and on Android from `/system/fonts`
(Roboto). Leaves `session.uiRegular` empty where nothing resolves or `none`
was asked for: interface runs then draw in the cell font. `session.uiFamily`
keeps the family asked for, which a desktop change is compared against.
*/
void resolveInterfaceFace(ref NativeSession session, in NativeRequest request,
    in SystemAppearance desktop) @system
{
    session.uiFamily = uiFontFamilyOf(request.font.ui, desktop);
    const found = lookUpInterfaceFace(session.uiFamily, request);
    if (found.why.length)
        whyNot(found.why);
    session.uiRegular = found.regular;
    session.uiBold = found.bold;
}

/// An interface face's files, read; `why` says what failed where `regular`
/// is empty and a family was asked for.
struct InterfaceFaceFiles
{
    const(ubyte)[] regular, bold; ///
    string why; /// ditto
}

/**
`family`'s regular and bold files, resolved for `request` and read —
`resolveInterfaceFace`'s lookup, apart from any session, so a thread may run
it. Empty for an empty family.
*/
InterfaceFaceFiles lookUpInterfaceFace(string family, in NativeRequest request) @system nothrow
{
    import std.conv : text;
    import std.file : read;
    import sparkles.raylib_text.font_discovery : FontSources;
    import sparkles.raylib_text.font_resolve : resolveUiFace;

    InterfaceFaceFiles found;
    if (!family.length)
        return found;
    try
    {
        FontSources sources;
        sources.dirs = request.font.searchDirs.dup ~ request.extraFontSources.dup;
        sources.useSystemFontDb = request.font.useSystemFontDb;
        version (Android)
        {
            sources.dirs ~= "/system/fonts";
            sources.useSystemFontDb = false;
        }
        string regular, bold;
        if (!resolveUiFace(family, sources, regular, bold))
        {
            found.why = text("no interface face resolved for `", family,
                "`: interface text draws in the cell font");
            return found;
        }
        found.regular = cast(const(ubyte)[]) read(regular);
        if (bold.length)
            found.bold = cast(const(ubyte)[]) read(bold);
    }
    catch (Exception e)
    {
        found = InterfaceFaceFiles.init;
        found.why = "the interface face could not be read: " ~ e.msg;
    }
    return found;
}

/**
An interface face the desktop changed to, looked up on a thread of its own:
the font database is asked through `fc-match`, a process, and no frame
waits on it. The face being drawn stays bound until the lookup settles.
*/
final class InterfaceFaceLookup
{
    import core.thread : Thread;

    string family; /// the family being looked up
    private Thread thread_;
    private InterfaceFaceFiles found_;

    /// Starts looking `family` up for `request`; null where no thread could
    /// start (the face is then looked up at once by `take`).
    static InterfaceFaceLookup start(string family, const NativeRequest request) @system
    {
        auto lookup = new InterfaceFaceLookup;
        lookup.family = family;
        try
        {
            lookup.thread_ = new Thread(() { lookup.found_ = lookUpInterfaceFace(family, request); });
            lookup.thread_.isDaemon = true;
            lookup.thread_.start();
        }
        catch (Exception)
            lookup.found_ = lookUpInterfaceFace(family, request);
        return lookup;
    }

    /// Whether `take` would not wait.
    bool settled() @system => thread_ is null || !thread_.isRunning;

    /// The files found, once settled.
    InterfaceFaceFiles take() @system
    {
        if (thread_ !is null)
            thread_.join(false);
        thread_ = null;
        return found_;
    }
}

/**
Follows the desktop's interface font while the window runs: a change to the
family `desktop` names starts a lookup of it (`InterfaceFaceLookup`), unless
`--ui-font` chose the face or the same family is already drawn or sought.
True when a lookup was started.
*/
bool followDesktopInterfaceFont(ref NativeSession session, in NativeRequest request,
    in SystemAppearance desktop) @system
{
    if (request.font.ui.length)
        return false;
    const family = uiFontFamilyOf(null, desktop);
    if (session.nextUi !is null ? session.nextUi.family == family : session.uiFamily == family)
        return false;
    session.nextUi = InterfaceFaceLookup.start(family, request);
    return true;
}

/**
Adopts a settled lookup's face into `session`: true when the interface face
changed, and the caller rebinds it. A family that resolved nothing keeps the
face already drawn.
*/
bool adoptInterfaceFace(ref NativeSession session) @system
{
    if (session.nextUi is null || !session.nextUi.settled)
        return false;
    const family = session.nextUi.family;
    const found = session.nextUi.take();
    session.nextUi = null;
    if (!found.regular.length)
    {
        if (found.why.length)
            whyNot(found.why);
        return false;
    }
    session.uiFamily = family;
    session.uiRegular = found.regular;
    session.uiBold = found.bold;
    return true;
}

@("ui_app.native_loop.followsTheDesktopsInterfaceFont")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import std.file : getSize;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.appearance.types : parseFontDescription;

    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    NativeSession session;
    NativeRequest request;
    request.font.searchDirs = [dir];
    SystemAppearance desktop;
    desktop.font = parseFontDescription("Noto Sans 11");
    desktop.hasFont = true;
    resolveInterfaceFace(session, request, desktop);
    const noto = session.uiRegular;
    assert(noto.length == getSize(dir.buildPath("NotoSans.ttf")));

    assert(!followDesktopInterfaceFont(session, request, desktop), "the same family: nothing to do");
    // The desktop changes its interface font: looked up apart, then adopted.
    desktop.font = parseFontDescription("Roboto 11");
    assert(followDesktopInterfaceFont(session, request, desktop));
    assert(!followDesktopInterfaceFont(session, request, desktop), "already being sought");
    assert(session.uiRegular is noto, "the old face is drawn until the new one is found");
    while (!session.nextUi.settled)
        Thread.sleep(1.msecs);
    assert(adoptInterfaceFace(session));
    assert(session.uiRegular.length == getSize(dir.buildPath("Roboto-Regular.ttf")));
    assert(session.uiBold.length == getSize(dir.buildPath("Roboto-Bold.ttf")));
    assert(session.nextUi is null && !adoptInterfaceFace(session));

    // A face `--ui-font` chose stays, whatever the desktop says.
    request.font.ui = "Noto Sans";
    desktop.font = parseFontDescription("Cantarell 11");
    assert(!followDesktopInterfaceFont(session, request, desktop));
}

@("ui_app.native_loop.resolveInterfaceFace")
@system unittest
{
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.appearance.types : parseFontDescription;
    import std.file : getSize;

    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    NativeSession session;
    NativeRequest request;
    request.font.searchDirs = [dir];
    // The desktop's family wins over the list, from the request's directories.
    SystemAppearance desktop;
    desktop.font = parseFontDescription("Noto Sans 11");
    desktop.hasFont = true;
    resolveInterfaceFace(session, request, desktop);
    assert(session.uiRegular.length == getSize(dir.buildPath("NotoSans.ttf")),
        "Noto Sans, as the desktop names it");
    // `--ui-font` wins over the desktop; a path names its file.
    request.font.ui = dir.buildPath("Roboto-Regular.ttf");
    resolveInterfaceFace(session, request, desktop);
    assert(session.uiRegular.length == getSize(request.font.ui));
    assert(session.uiBold.length == getSize(dir.buildPath("Roboto-Bold.ttf")), "its bold sibling");
    // `none` keeps the interface in the cell font.
    request.font.ui = "none";
    resolveInterfaceFace(session, request, desktop);
    assert(!session.uiRegular.length && !session.uiBold.length);
}

/// Why the native arm did not open, on standard error — logcat on Android,
/// where standard error goes nowhere: the run reports only that it failed,
/// and an application need not have set up a logger.
private void whyNot(Args...)(Args args) @system => note(args);

/// A line of what the native arm reports — why it failed, `--debug log-events`,
/// `--debug trace-frames` — where $(LREF whyNot) writes it.
private void note(Args...)(Args args) @system
{
    import std.conv : text;

    version (Android)
    {
        import sparkles.wsi.platform.android : logFailure;

        logFailure(text(args));
    }
    else
    {
        import std.stdio : stderr;

        stderr.writeln(text(args));
    }
}

/// The canvas the native arm draws with.
alias NativeCanvas = VulkanCanvas!DeviceMemoryBackend;

/**
What the arm keeps between frames that the host reads: the surface's size
and scale, the cell metrics, and the canvas. The window-system calls a host
errand makes go through delegates, so the host's type does not depend on
which window system runs it.
*/
struct NativeSession
{
    uint pixelW, pixelH;     /// the surface, in device pixels
    double scale = 1;        /// device pixels per logical unit
    /// The edges system bars or cutouts cover, in device pixels: the cells
    /// start inside them (an Android window is edge to edge).
    PhysicalInsets insets;
    CellFont font;           ///
    PreparedSpecimenFont specimen; /// independent preview, em pixels
    FallbackFace[] specimenFallbackFaces; /// retained conversion of supplied script faces
    CellFont interfaceFont; /// stable UI font while the preview drives the UI
    /// The interface face (`UVK20`, design-system `GLY10`): its regular and
    /// bold files' bytes, empty where none resolved, and whether the canvas
    /// draws it — what the target declares `proportionalText` by.
    const(ubyte)[] uiRegular, uiBold;
    bool uiFaceBound; /// ditto
    /// The family the interface face was asked for, and a lookup of one the
    /// desktop changed to (`followDesktopInterfaceFont`).
    string uiFamily;
    InterfaceFaceLookup nextUi; /// ditto
    bool delegate(in SpecimenFontRequest) @system setSpecimen; ///
    ulong specimenGeneration; /// latest accepted request
    MonoTime specimenRequestedAt; /// event arrival, when supplied by the caller
    ulong specimenDrawnGeneration; /// the scope actually painted
    SpecimenLatencyStats specimenLatency; /// end-to-end submission/display counters
    FrameStats* frameStats; /// the live run's measured frame distribution
    TextRendering specimenRendering, interfaceRendering; /// independent rendering choices
    bool specimenRenderingSet; /// whether the application configured its preview
    NativeCanvas* canvas;    ///
    float frameSeconds = 0;  /// how long the last frame took to build and submit
    string shotPath;         /// a screenshot to take on the next frame drawn
    void delegate(PointerShape) @system setCursor;           ///
    void delegate(scope const(char)[]) @system setClipboard; ///
    void delegate(int px) @system setFontSize;               ///
    void delegate(bool on) @system setTextInput;             ///
    /// The fingers down, as the last drain left them.
    TouchContacts touches;
    /// The frame the host draws itself where the window system leaves it to
    /// the client (`F13`), the title it shows and the palette it is drawn in.
    ClientFrame frame;
    char[] title;  /// ditto
    Palette framePalette; /// ditto
    bool frameHighContrast; /// the desktop asks for more contrast (`RES45`)
    /// The title's face, found the first time a frame is drawn, and the
    /// title set in it.
    TitleFace titleFace;
    TitleStrip titleStrip; /// ditto
    /// A face being looked up for a title font the desktop changed to, and
    /// its pattern and size: the title stays in the old one until it is
    /// found, so no frame waits on the font database.
    TitleFace nextTitleFace;
    string nextTitlePattern; /// ditto
    float nextTitleCss = 0;  /// ditto
    /// The title's face and size, as the desktop names them (`RES45`).
    string titlePattern = titleFacePattern;
    float titleCss = titleCssPx; /// ditto
    void delegate(in char[]) @system setTitle; ///
    /// The transparent margin round the window, each side, in device pixels
    /// (`SurfaceMetrics.frameMargin`): the frame's shadow and outer resize
    /// border are drawn there, and the cells start inside it.
    int margin;
    /// The swapchain's alpha reaches the compositor: frames start
    /// transparent, and the window's ground is filled before the content.
    bool transparent;
}

private FallbackFace[] preparedFallbacks(ref NativeSession session) @safe
{
    const sources = session.specimen.request.fallbacks;
    if (session.specimenFallbackFaces.length != sources.length)
        session.specimenFallbackFaces.length = sources.length;
    foreach (i, source; sources)
        session.specimenFallbackFaces[i] = FallbackFace(source.bytes, session.specimen.ppem,
            source.faceIndex, source.contentHash);
    return session.specimenFallbackFaces;
}

/**
The canvas's interface faces, as `InterfaceMeasure` reads them (`GLY10`).
The host hands one out only while the canvas lives.

$(B Why `@trusted nothrow @nogc`.) Measuring reads the canvas's faces and
shapes into its own caches — fixed-capacity, malloc-backed — through the
glyph source's delegates and HarfBuzz, typed `@system` and unannotated
because they share code with drawing, which uploads to the atlas. The
measure-only path changes no layout-visible state and allocates no GC
memory (`ui_vulkan.canvas.measuringAnInterfaceRunAllocatesNoGcMemory`), so it
is safe and `@nogc` in fact; an exception is caught here, not thrown through.
The layout's wrap solver needs the attributes: with a measurer that is not
`nothrow @nogc` it measures every candidate through a value-compared cache,
which took the gallery's layout from under a millisecond to a second a frame.
*/
struct NativeFaces
{
    private NativeCanvas* canvas_;

    /// See `VulkanCanvas.interfaceWidthPx`.
    double interfaceWidthPx(scope const(char)[] text, int step, bool bold) @trusted nothrow @nogc
    {
        static double measured(NativeCanvas* canvas, scope const(char)[] text, int step, bool bold)
            @system nothrow
        {
            try
                return canvas.interfaceWidthPx(text, step, bold);
            catch (Exception)
                return -1;
        }

        alias Measured = double function(NativeCanvas*, scope const(char)[], int, bool)
            @system nothrow @nogc;
        return canvas_ is null ? -1 : (cast(Measured) &measured)(canvas_, text, step, bold);
    }

    /// See `VulkanCanvas.interfaceStep`.
    InterfaceStep interfaceStep(int step) const @safe pure nothrow @nogc
        => canvas_ is null ? InterfaceStep.init : canvas_.interfaceStep(step);
}

@("ui_app.native_loop.theMeasurerKeepsTheWrapSolversDirectPath")
@safe nothrow @nogc
unittest
{
    import sparkles.ui.layout : isIncrementalTextMeasure, isStyledTextMeasure,
        monotoneMeasurePrefixes;
    import sparkles.ui.style : TextStyle;

    alias M = InterfaceMeasure!NativeFaces;
    static assert(isStyledTextMeasure!M && isIncrementalTextMeasure!M && monotoneMeasurePrefixes!M);
    // `nothrow @nogc`, as the wrap solver's direct path needs (`NativeFaces`).
    static assert(is(typeof(() @safe nothrow @nogc {
        M m;
        int w = m.width("x", TextStyle.init) + m.rows(TextStyle.init);
        auto run = m.brushMetrics(TextStyle.init);
        w += run.append("x");
    })));
    // With no canvas, the cells.
    auto m = M(NativeFaces.init, true, 10, 20);
    assert(m.width("abc", TextStyle.init) == 3);
}

/// The host an application sees in a native window.
struct NativeHost
{
    mixin HostState;

    private NativeSession* session_;
    private WsiInput* input_;

    /// Where a `CompositionEvent`'s preedit resolves (`INP24`), until the next
    /// drain: the window-system adapter's pool.
    ref InputTextPool inputTexts() return @safe => input_.texts;

    /// A desktop window is a mouse target (`TGT5`).
    InputCapabilities capabilities = mousePointer;

    /// The surface, in cells.
    Size size() const @safe pure nothrow @nogc
        => Size(pixels.width / session_.font.cellW, pixels.height / session_.font.cellH);

    /// ditto
    Backend backend() const @safe pure nothrow @nogc => Backend.gui;

    /// Seconds the last frame took — the clock an animation reads.
    float frameSeconds() const @safe pure nothrow @nogc => session_.frameSeconds;

    /// The cell font's pixel size, and the errand changing it (`HST14`):
    /// the cells are measured again, so `size` changes on its next read.
    int fontSizePx() const @safe pure nothrow @nogc => session_.font.px;

    /// The surface inside its safe insets, in device pixels: what an
    /// application sizes chrome it paints in pixels by, remainder of a cell
    /// included.
    Size pixels() const @safe pure nothrow @nogc
    {
        static int inside(uint whole, uint a, uint b) => whole > a + b ? cast(int)(whole - a - b) : 0;

        with (session_.insets)
            return Size(inside(session_.pixelW, left, right), inside(session_.pixelH, top, bottom));
    }

    /// The edges system bars, cutouts or the soft keyboard cover, in device
    /// pixels: outside `pixels`, which starts inside them.
    PhysicalInsets insets() const @safe pure nothrow @nogc => session_.insets;

    /// The fingers on a touch surface, positions in device pixels from the
    /// cells' origin: what a press drawn while the finger is still down
    /// reads, the gestures arriving as events.
    TouchContacts touches() const @safe pure nothrow @nogc => session_.touches;

    /// Asks for text input — on a phone, the soft keyboard — or puts it away.
    /// A hardware keyboard types either way.
    void textInput(bool on) @system => session_.setTextInput(on);

    /// One cell, in device pixels. A terminal pane opens with these
    /// (`openPixels`) and needs `PointerUnit.pixels` so pointer events
    /// arrive in the same unit.
    int cellWidth() const scope @safe pure nothrow @nogc => session_.font.cellW;
    /// ditto
    int cellHeight() const scope @safe pure nothrow @nogc => session_.font.cellH;

    /// ditto
    void fontSize(int px) @system => session_.setFontSize(px);

    /// Selects an exact face for preview; a failed request keeps the old face.
    bool specimenFont(in SpecimenFontRequest request) @system
        => session_.setSpecimen !is null && session_.setSpecimen(request);

    /// Last successful selection, including the resolved collection index.
    SpecimenFontRequest specimenFont() const @system => session_.specimen.request;

    /// Conventional-em specimen metrics, independent of the interface grid.
    int specimenCellWidth() const @safe pure nothrow @nogc => session_.specimen.cellW;
    /// ditto
    int specimenCellHeight() const @safe pure nothrow @nogc => session_.specimen.cellH;
    /// Device pixels per logical pixel for point-to-em specimen sizing.
    double fontDensity() const @safe pure nothrow @nogc => session_.scale;
    /// The startup/resolved interface path, useful to seed a preview selection.
    string fontPath() const @safe pure nothrow @nogc => session_.font.path;
    /// Borrowed bytes of the successfully prepared exact face.
    const(ubyte)[] specimenFontBytes() const @safe pure nothrow @nogc => session_.specimen.bytes;
    /// Its collection member; metadata must be read at this index.
    uint specimenFontIndex() const @safe pure nothrow @nogc => session_.specimen.request.faceIndex;
    /// A usable preview is bound; preparation failures preserve this value.
    bool specimenFontReady() const @safe pure nothrow @nogc => session_.specimen.bytes.length != 0;
    /// Glyphs using fallback faces in the current specimen frame.
    uint specimenFallbackGlyphs() const @system
        => session_.canvas is null ? 0 : session_.canvas.specimenFallbackGlyphs;
    /// Natural runs rendered on the grid because shaping could not cover them.
    uint specimenGridFallbacks() const @system
        => session_.canvas is null ? 0 : session_.canvas.specimenGridFallbacks;

    /// Opens the drawing scope after a successful preview preparation.
    bool beginSpecimen() @system
    {
        if (session_.canvas is null || !session_.canvas.beginSpecimen(
                specimenCellWidth, specimenCellHeight))
            return false;
        session_.specimenDrawnGeneration = session_.specimenGeneration;
        return true;
    }
    /// Restores the interface even when begin failed.
    void endSpecimen() @system
    {
        if (session_.canvas !is null)
            session_.canvas.endSpecimen();
    }

    /// Timing of accepted requests through queue submission and observed display.
    SpecimenLatencyStats specimenLatencyStatistics() const @safe pure nothrow @nogc
        => session_.specimenLatency;

    /// Completed frame durations; presentation latency remains a separate metric.
    FrameStats frameStatistics() const @system
        => session_.frameStats is null ? FrameStats.init : *session_.frameStats;

    /// Changes preview rendering independently of interface text by default.
    void specimenTextRendering(in TextRendering settings) @system
    {
        session_.specimenRendering = settings;
        session_.specimenRenderingSet = true;
        if (session_.canvas !is null)
        {
            session_.canvas.specimenTextRendering(settings);
            if (session_.specimen.request.uiFollows)
                session_.canvas.textRendering(settings);
        }
    }

    /// The pointer's shape over the window (`IXB4`).
    void pointerShape(PointerShape shape) @system => session_.setCursor(shape);

    /// Offers `text` as the clipboard's (`HST8`).
    void clipboard(in char[] text) @system => session_.setClipboard(text);

    /// Retitles the window: the window system's title, and the bar's where
    /// the host draws the frame.
    void title(in char[] t) @system => session_.setTitle(t);

    /// How the canvas renders text (`UVX12`): compositing, hinting, shaping.
    /// An application offering these as settings probes for the errand.
    void textRendering(in TextRendering settings) @system => session_.canvas.textRendering(settings);

    /// ditto
    TextRendering textRendering() const @system => session_.canvas.textRendering;

    /// A loupe over the frame: a region of the window's pixels drawn
    /// magnified, exactly as composited.
    void loupe(in Loupe l) @system => session_.canvas.loupe(l);

    /// Binds the image registry the canvas draws images from (`IMG3`).
    void images(const(ImageRegistry)* registry) @system => session_.canvas.images(registry);

    /// Effects draw their contents unaffected here (`UVK15`, `EFX3`); the
    /// registry is accepted so an application binds it the same on every arm.
    void effects(const(EffectRegistry)*, RgbColor) @safe pure nothrow @nogc {}

    /// A window has no out-of-band channel.
    void writeOutOfBand(scope const(char)[]) @safe pure nothrow @nogc {}

    /// Not offered by the window system yet.
    bool fullscreenSupported() const @safe pure nothrow @nogc => false;
    /// ditto
    void toggleFullscreen() @safe pure nothrow @nogc {}

    /// Captures the next frame drawn into a PNG at `path`.
    void screenshot(in char[] path) @safe
    {
        session_.shotPath = path.idup;
    }

    /// The canvas, for an application with a renderer of its own (`HST3`):
    /// valid in the draw phase, inside the frame bracket. A pointer, so it
    /// copies like the raylib arm's canvas value.
    NativeCanvas* canvas() @safe pure nothrow @nogc => session_.canvas;

    /**
    The text measurer layout and the display list use on this target
    (`GLY10`): interface runs as the canvas draws them in the interface face
    while the target draws it, cell metrics otherwise — so a narrowed preview
    lays out as the terminal would. Asked after `view`, so it also tells the
    canvas whether to draw interface runs in their face this frame: a
    narrowing made while building the frame lays out and draws alike.
    */
    InterfaceMeasure!NativeFaces textMeasure() @system
    {
        const faces = target.proportionalText && session_.canvas !is null;
        if (session_.canvas !is null)
            session_.canvas.interfaceFaces(faces);
        return InterfaceMeasure!NativeFaces(NativeFaces(session_.canvas), faces,
            session_.font.cellW, session_.font.cellH);
    }

    /// No ring paces this arm's daemons yet: a component keeps its polled
    /// path (`HST15`).
    bool spawnDaemon(void delegate()) @safe pure nothrow @nogc => false;
    /// ditto — the next frame is already coming.
    void wake() @safe pure nothrow @nogc {}
}

static assert(isHost!NativeHost);

/**
Runs `present`/`handle` in a native window until the application quits or
the window closes. `false` when no window, font or device could be opened.
*/
bool runNative(alias present, alias handle, alias draw = noDraw, alias setup = noSetup,
    alias shutdown = noShutdown)(in RunConfig cfg, in NativeRequest request) @system
{
    DefaultLoop loop;
    if (DefaultLoop.create(loop, LoopConfig()).hasError)
    {
        whyNot(i"the native arm could not open an event loop");
        return false;
    }
    WsiConfig wsiConfig;
    wsiConfig.app = request.app;
    if (auto fault = request.app.fault)
    {
        whyNot(i"the application's identity is malformed: $(fault)");
        return false;
    }
    // Android is `linux` too, and has neither Wayland nor X11: its window is
    // the activity's, its frames paced by `AChoreographer`. Wayland's are
    // paced by the compositor's frame callbacks; X11 presents at once, and
    // its FIFO swapchain paces it.
    version (Android)
        enum integrated = true;
    else version (linux)
        enum integrated = true;
    else
        enum integrated = false;
    static if (!integrated)
    {
        whyNot(i"the native arm runs on Wayland, X11 and Android only so far");
        return false;
    }
    else
    {
        bool drove;
        const opened = openNative!((ref wsi) {
            enum paced = backendKindOf!(typeof(wsi)) != BackendKind.x11;
            drove = drive!(present, handle, draw, setup, shutdown)(wsi, loop, cfg, request,
                paced: paced);
        })(loop, preferenceOf(cfg.native.windowSystem), wsiConfig);
        if (opened.hasError)
        {
            whyNot(i"the native arm opened no window system: $(opened.error.diagnostic[])");
            return false;
        }
        return drove;
    }
}

/// The window system `system` asks the native arm for.
private BackendPreference preferenceOf(WindowSystem system) @safe pure nothrow @nogc
{
    // Android has only its own window system, whatever is asked.
    version (Android)
        return BackendPreference.automatic;
    else final switch (system)
    {
        case WindowSystem.auto_: return BackendPreference.automatic;
        case WindowSystem.wayland: return BackendPreference.wayland;
        case WindowSystem.x11: return BackendPreference.x11;
    }
}

// The surface's views, one per swapchain image.
private struct Views
{
    VkImageView[] views;

    void create(ref VulkanContext vk, ref Swapchain swapchain) @system
    {
        destroy(vk);
        views = new VkImageView[swapchain.images.length];
        foreach (i, image; swapchain.images)
        {
            auto info = vkInfo(VkImageViewCreateInfo(
                image: image,
                viewType: VkImageViewType.VK_IMAGE_VIEW_TYPE_2D,
                format: swapchain.format,
                subresourceRange: colourRange,
            ));
            vk.device.createImageView(vk.device.device, &info, null, &views[i]);
        }
    }

    void destroy(ref VulkanContext vk) @system
    {
        foreach (v; views)
            if (v !is null)
                vk.device.destroyImageView(vk.device.device, v, null);
        views = null;
    }
}

// Everything on the device, made together and rebuilt together when the
// device is lost.
private struct Gpu
{
    VulkanContext vk;
    DeviceMemory!DeviceMemoryBackend memory;
    Swapchain swapchain;
    Views views;
    FrameSync sync;
    CommandPool commands;
    NativeCanvas canvas;
    GpuProfiler profiler; /// the device's time, in named scopes (`PRF10`)
    bool profilerTried;   /// made once per device, where a switch asks
    FrameClock clock;     /// the run's, for calibrated scopes
    /// When presents reached the display, where no window-system feedback
    /// says (`PRF13`): `VK_GOOGLE_display_timing` (Android) exactly, else
    /// `VK_KHR_present_wait` as the time a poll saw the present complete.
    DisplayTimes displayTimes;
    PresentWait presentWait; /// ditto
    ulong presentTag;     /// the record number the next present belongs to
    bool tagPresents;     /// a switch or a specimen wants display times
    bool waitPresents;    /// and present wait is the source
    bool up;

    @disable this(this);

    /*
    The swapchain is about to be retired (a rebuild) or destroyed (a surface
    released): its outstanding present ids go with it. Ids are per swapchain,
    and a retired one may not be waited on (`VUID-vkWaitForPresentKHR-
    swapchain-04997`) — an X11 loop paced by present wait would otherwise wait,
    before the rebuilt swapchain's first frame, on the one it replaced, and
    after a released surface on a handle already destroyed.
    */
    void swapchainGoes() @safe pure nothrow @nogc
    {
        presentWait.forget();
    }

    void destroy() @system
    {
        if (!up)
            return;
        if (vk.device.device !is null)
            vk.device.deviceWaitIdle(vk.device.device);
        profiler.destroy(vk);
        profilerTried = false;
        presentWait.forget();
        displayTimes = DisplayTimes.init;
        canvas.destroy();
        commands.destroy(vk);
        sync.destroy(vk);
        views.destroy(vk);
        swapchain.destroy(vk);
        memory.destroy();
        vk.destroy();
        up = false;
    }
}

@("ui_app.native_loop.aGoneSwapchainIsNotWaitedOn")
@system unittest
{
    // An X11 loop paced by present wait (`PRF13`) waits only on the
    // swapchain it presents to: a rebuild drops the retired one's ids, and
    // the ids keep increasing on the next.
    Gpu gpu;
    const old = cast(VkSwapchainKHR) cast(void*) 0x40;
    gpu.presentWait.submitted(old, 7);
    gpu.presentWait.submitted(old, 8);
    gpu.swapchainGoes();
    assert(gpu.presentWait.outstanding == 0, "nothing left to wait on");
    assert(!gpu.presentWait.waitForNewest(gpu.vk, 50.msecs), "no wait, no call");
    assert(gpu.presentWait.idFor(3) == 9, "ids still increase");

    const next = cast(VkSwapchainKHR) cast(void*) 0x41;
    gpu.presentWait.submitted(next, 9);
    assert(gpu.presentWait.outstanding == 1 && gpu.presentWait.lastSubmitted == 9);
}

private bool drive(alias present, alias handle, alias draw, alias setup, alias shutdown,
    Wsi)(ref Wsi wsi, ref DefaultLoop loop, in RunConfig cfg, in NativeRequest request,
    bool paced) @system
{
    import sparkles.base.logger : trace;
    import sparkles.raylib_text.metrics_dpi : DisplayMetrics, pixelsForPoints;
    import sparkles.ui.interp.immediate : paint;

    NativeSession session;
    // `--debug log-events`: each event as the drain delivers it — text read there,
    // the one place it can be (`ED8`) — and the counts by kind when the
    // window closes.
    EventStats events;
    const eventPretty = PrettyPrintOptions!void(colored: false, softMaxWidth: 120);
    // What each presented frame took, from the draw decision to the present,
    // summarized when the window closes under any frame switch.
    FrameStats frameTimes;
    session.frameStats = &frameTimes;
    // `--debug gpu-timing`: the device's time per frame, summarized the same
    // way. `--debug frame-trace=PATH`: the last frames, each a `FrameRecord`,
    // written as a Chrome trace at the end (`PRF19`).
    FrameStats gpuTimes;
    // The device's memory under any frame switch, read at most once a second
    // and reported at its peak (`PRF15`).
    MemoryPeaks memory;
    // The named CPU zones the application and the canvas open in a frame
    // (`PRF22`): summed per frame, summarized per name.
    FrameZones zones;
    ZoneStats* zoneTimes = new ZoneStats;
    FrameHistory!4096* history;
    const(string)[] traceNames; // the device scopes' names, for the trace
    const summarizeFrames = cfg.native.debugging.traceFrames
        || cfg.native.debugging.traceFramesOver > 0 || cfg.native.debugging.frames > 0
        || cfg.native.debugging.resizeStress || cfg.native.debugging.gpuTiming
        || cfg.native.debugging.frameTrace.length || cfg.native.debugging.frameCounters;
    // `--debug frame-counters`: the frame thread's hardware counters, read at
    // each pass's edges (`PRF23`). Opened here: they count this thread.
    FrameCounters* counters = new FrameCounters;
    if (cfg.native.debugging.frameCounters)
        counters.start();
    scope (exit)
        counters.stop();
    // Kept under any frame switch: a display time arrives frames after its
    // frame, and finds its record here (`PRF13`).
    if (summarizeFrames)
        history = new FrameHistory!4096;
    void noteEvent(in WindowEvent e) @trusted
    {
        if (!cfg.native.debugging.logEvents)
            return;
        events.count(e);
        note(eventLine(wsi, e, eventPretty));
    }
    // Cells measured at scale 1 size the window; the surface's real scale
    // re-measures them once it is known.
    int pxAt(double scale) => request.fontSizePxOverride > 0 ? request.fontSizePxOverride
        : pixelsForPoints(request.fontSizePoints, DisplayMetrics(scale: cast(float) scale));
    if (!measureCellFont(request.font, request.extraFontSources, pxAt(1), session.font))
    {
        whyNot(i"the native arm resolved no cell font for `$(request.font.family)`");
        return false;
    }

    WindowConfig config;
    cast(void) config.title.assign(fitTitle(request.title, 255));
    config.logicalSize = LogicalSize(request.cells.cols * session.font.cellW,
        request.cells.rows * session.font.cellH);
    auto created = wsi.createWindow(config);
    if (created.hasError)
    {
        whyNot(i"the native arm could not create a window: $(created.error.diagnostic[])");
        return false;
    }
    const window = created.value;
    scope (exit)
        if (cfg.native.debugging.logEvents)
            note(i"native window events: $(events)");
    scope (exit)
        if (summarizeFrames)
        {
            note(i"native window frames: $(frameTimes)");
            if (gpuTimes.frames)
                note(i"native window gpu: $(gpuTimes)");
            if (zoneTimes.any)
                note(i"native window $(*zoneTimes)");
            if (cfg.native.debugging.frameCounters)
                note(i"native window counters: $(counters.stats)");
            if (memory.samples)
                note(i"native window memory: $(memory)");
        }
    scope (exit)
        if (cfg.native.debugging.frameTrace.length)
            writeFrameTrace(*history, traceNames, cfg.native.debugging.frameTrace);

    // ── the first configure ──
    SurfaceMetrics metrics;
    bool ready, closeRequested;
    auto first = MonoTime.currTime + 5.seconds;
    while (!ready && MonoTime.currTime < first)
    {
        if (wsi.runIntegratedOnce(loop, 100.msecs).hasError)
            break;
        cast(void) wsi.drain((WindowEvent e) {
            noteEvent(e);
            if (e.window != window)
                return;
            e.payload.match!(
                (in WindowStateChangedEvent w) { session.frame.state = w.state; },
                (in ReadyEvent r) { metrics = r.metrics; ready = true; },
                (in SurfaceMetricsChangedEvent m) { metrics = m.metrics; },
                (in _) {});
        });
    }
    if (!ready)
    {
        whyNot(i"the native window was never configured");
        return false;
    }
    /*
    The desktop's appearance (`RES45`): read before the first frame, the
    portal given a short budget to answer, then followed as it changes
    (`drainEvents`). The client frame takes its controls' layout and its
    title's font; the application, the colour scheme. `--appearance`
    (`dark`, `light`, `high-contrast`) pins it over what the desktop says.
    */
    SystemAppearance appearance;
    const(char)[] pinnedAppearance = cfg.native.appearance;
    version (Android) {} else version (linux)
    {
        // Watched by the loop through its address: it must not move, and
        // goes before the loop does.
        auto portal = new PortalAppearance;
        scope (exit)
            portal.close();
        if (!PortalAppearance.open(*portal).hasError)
        {
            appearance = portal.current;
            // Not watched is not followed: closed, it is not serviced.
            if (portal.arm(loop).hasError)
                portal.close();
        }
    }
    appearance = appearance.overriddenBy(pinnedAppearance);
    resolveInterfaceFace(session, request, appearance);
    // The frame's share: the layout and the title's face, set again only
    // when they change.
    void frameAppearance(in SystemAppearance a, bool started)
    {
        session.frameHighContrast = a.hasContrast && a.contrast == ContrastLevel.high;
        const layout = a.hasButtons ? a.buttons : ClientFrame.defaultLayout;
        if (layout != session.frame.layout)
        {
            session.frame.layout = layout;
            // What the pointer was over may have moved or gone.
            session.frame.hover = session.frame.pressed = FramePart.content;
        }
        const pattern = a.hasTitleFont ? titlePatternOf(a.titleFont) : titleFacePattern;
        const css = a.hasTitleFont ? titleCssPxOf(a.titleFont) : titleCssPx;
        if (!started)
        {
            session.titlePattern = pattern;
            session.titleCss = css;
            return;
        }
        if (pattern == session.titlePattern && css == session.titleCss)
        {
            session.nextTitlePattern = null; // a change undone before it landed
            return;
        }
        if (pattern != session.nextTitlePattern)
        {
            session.nextTitleFace = TitleFace.init;
            session.nextTitleFace.prepare(pattern);
        }
        session.nextTitlePattern = pattern;
        session.nextTitleCss = css;
    }
    frameAppearance(appearance, false);
    // The title face is looked up while the cells are measured and the
    // device is made, not in the first frame.
    if (session.frame.active)
        session.titleFace.prepare(session.titlePattern);

    // Every lifecycle decision is the machine's (`sparkles.ui_app.lifecycle`,
    // resilience §1); this loop executes its plans. Cell font sizes are in
    // points, as `pxAt` reads them, unless the request fixed the pixels.
    Lifecycle lc;
    lc.paced = paced;
    if (request.fontSizePxOverride > 0)
    {
        lc.base = request.fontSizePxOverride;
        lc.sizeAt = (double base, double) => cast(int) base;
        lc.baseOf = (int px, double) => double(px);
    }
    else
    {
        lc.base = request.fontSizePoints;
        lc.sizeAt = (double points, double scale)
            => pixelsForPoints(points, DisplayMetrics(scale: cast(float) scale));
        lc.baseOf = (int px, double scale) => pointsForPixels(px, scale);
    }

    // The client frame's bar is an inset above the cells (`F13`): set again
    // wherever the metrics, the cell height or the frame change, for the
    // canvas's origin and the input's alike.
    WsiInput* insetInput;
    // The smallest window a framed one may be resized to, last asked for.
    LogicalSize minimumAsked;
    void inset()
    {
        // The cells start inside the margin, the safe area and the bar.
        session.margin = metrics.frameMargin.left;
        session.insets = metrics.safeInsets;
        session.insets.left += metrics.frameMargin.left;
        session.insets.right += metrics.frameMargin.right;
        session.insets.bottom += metrics.frameMargin.bottom;
        session.insets.top += metrics.frameMargin.top
            + session.frame.barPx(cast(float) session.scale);
        static if (__traits(hasMember, Wsi, "setMinimumSize"))
        {
            const scale = metrics.scale.value > 0 ? metrics.scale.value : 1;
            const px = session.frame.minimumPx(session.font.cellH, cast(float) session.scale);
            const minimum = LogicalSize(px.width / scale, px.height / scale);
            if (minimum != minimumAsked)
            {
                minimumAsked = minimum;
                cast(void) wsi.setMinimumSize(window, minimum);
            }
        }
        if (insetInput !is null)
        {
            insetInput.originX = session.insets.left;
            insetInput.originY = session.insets.top;
        }
    }
    void adoptSpecimen()
    {
        const ref p = session.specimen;
        auto f = session.font;
        f.path = p.request.path;
        f.px = p.request.px;
        f.cellW = p.cellW;
        f.cellH = p.cellH;
        f.bytes = p.bytes;
        f.bold = f.italic = f.boldItalic = null;
        if (p.request.familyStyles)
        {
            f.bold = p.request.styleBytes[0];
            f.italic = p.request.styleBytes[1];
            f.boldItalic = p.request.styleBytes[2];
        }
        f.ppem = p.request.px;
        f.emNumerator = p.request.px;
        f.emDenominator = 1;
        f.ascent = p.metrics.ascent;
        f.underlineY = p.metrics.underlineY;
        f.underlineHeight = p.metrics.underlineHeight;
        f.strikeY = p.metrics.strikeY;
        session.font = f;
    }
    void measure(int px)
    {
        if (session.specimen.bytes.length && session.specimen.request.uiFollows)
        {
            auto selected = session.specimen.request;
            selected.px = px;
            if (session.specimen.prepare(selected))
                adoptSpecimen();
            inset();
            return;
        }
        CellFont font;
        if (session.font.bytes.length ? remeasureCellFont(session.font, px, font)
                : measureCellFont(request.font, request.extraFontSources, px, font))
            session.font = font;
        inset();
    }
    void takeMetrics()
    {
        session.scale = metrics.scale.value;
        session.pixelW = metrics.physicalSize.width;
        session.pixelH = metrics.physicalSize.height;
        inset();
    }
    Surface surfaceOf(in SurfaceMetrics m)
        => Surface(m.physicalSize.width, m.physicalSize.height, m.scale.value);
    takeMetrics();
    if (const px = lc.metrics(surfaceOf(metrics)))
        measure(px);

    // Teardown inside the window system's native-I/O borrow, as acquire and
    // present are: Mesa's Wayland swapchain destruction round-trips the
    // shared display, and with the window system's read prepared that
    // round-trip waits forever. Every close hung there — the overview's
    // close button, the shot's quit — with the window still on screen. The
    // work runs whether or not the borrow is had: a device must not leak,
    // and a borrow that cannot be had holds no read.
    void underBorrow(scope void delegate() @system work)
    {
        static if (__traits(hasMember, Wsi, "beginNativeIo"))
        {
            const held = !wsi.beginNativeIo().hasError;
            scope (exit)
                if (held)
                    cast(void) wsi.endNativeIo();
        }
        work();
    }

    // ── the device ──
    /*
    Pipelines compile through a cache kept between runs, under the
    application's cache directory: on a warm start the first frame does not
    compile its pipelines again (18 ms of its recording on lavapipe). A
    cache another driver or device wrote is ignored by the driver itself.
    Saved after a device's first frame, which built its pipelines, and when
    the window goes.
    */
    string pipelineCachePath;
    {
        import std.path : buildPath;
        import sparkles.core_cli.common_dirs : cacheDir;

        if (const dir = cacheDir())
            pipelineCachePath = buildPath(dir, request.app.idOrDefault.idup,
                "vulkan-pipelines.bin");
    }
    auto gpu = new Gpu;
    bool pipelinesSaved;
    void savePipelines()
    {
        import std.file : mkdirRecurse;
        import std.path : dirName;

        if (!gpu.up || pipelineCachePath.length == 0)
            return;
        try
            mkdirRecurse(pipelineCachePath.dirName);
        catch (Exception)
            return;
        cast(void) gpu.vk.savePipelineCache(pipelineCachePath);
        pipelinesSaved = true;
    }
    scope (exit)
        underBorrow(() {
            savePipelines();
            gpu.destroy();
        });

    /*
    The interface face, at every type step (`UVK20`, design-system `GLY10`),
    sized as the raylib arm's `UiFonts` is: the steps' density-independent
    px at the surface's scale (1 for a pinned capture), or — `RunConfig.
    uiFollowsCellFont` — the body step at the cell font's size, the rest in
    proportion, shrunk so its x-height is the cell font's. Bound again with
    the cell font: a font size, a scale, a new device.
    */
    void bindInterfaceFace()
    {
        import sparkles.raylib_text.ui_sizing : xHeightMatched;

        session.uiFaceBound = false;
        if (!gpu.up || !session.uiRegular.length)
            return;
        const scale = request.fontSizePxOverride > 0 ? 1.0f : cast(float) session.scale;
        auto sizes = uiStepSizes(scale, cfg.uiFollowsCellFont ? session.font.px : 0);
        if (cfg.uiFollowsCellFont)
            sizes = xHeightMatched(sizes, xHeightRatio(session.uiRegular, session.font.bytes));
        session.uiFaceBound = gpu.canvas.interfaceFont(session.uiRegular, session.uiBold, sizes);
    }

    // The cell font the canvas draws text with, at the size just measured
    // (`UVK18`).
    void bindFont()
    {
        if (!gpu.up)
            return;
        const f = session.font;
        const(ubyte)[][FaceStyle.max + 1] faces = [f.bytes, f.bold, f.italic, f.boldItalic];
        import sparkles.base.text.layout_units : I128, Rational, U128;
        import sparkles.font : Ppem;

        static auto exactly(ulong num, ulong den)
            => Ppem.fromRational(Rational(I128(U128(num, 0)), U128(den ? den : 1, 0)));
        auto em = exactly(f.emNumerator, f.emDenominator);
        if (em.hasError)
            em = Ppem.fromInteger(f.ppem ? f.ppem : 1);
        FallbackFace[] fallbacks;
        foreach (fb; f.fallbacks)
        {
            const fbEm = exactly(fb.emNumerator, fb.emDenominator);
            if (fbEm.hasValue)
                fallbacks ~= FallbackFace(fb.bytes, fbEm.value);
        }
        const follows = session.specimen.bytes.length && session.specimen.request.uiFollows;
        cast(void) gpu.canvas.cellFont(faces, em.value, TextMetrics(ascent: f.ascent,
            underlineY: f.underlineY, underlineHeight: f.underlineHeight, strikeY: f.strikeY), fallbacks,
            follows ? session.specimen.request.faceIndex : 0,
            follows ? session.specimen.request.coordinates : null,
            follows ? session.specimen.request.styleIndices[] : null);
        if (session.specimen.bytes.length)
            cast(void) gpu.canvas.specimenFont(session.specimen.bytes, session.specimen.request.faceIndex,
                session.specimen.ppem, session.specimen.request.coordinates, session.specimen.metrics,
                session.specimen.request.contentHash, session.specimen.cellH,
                session.specimen.request.familyStyles ? session.specimen.request.styleBytes[] : null,
                session.specimen.request.styleIndices[], session.specimen.request.styleContentHashes[],
                preparedFallbacks(session));
        if (session.specimenRenderingSet)
        {
            gpu.canvas.specimenTextRendering(session.specimenRendering);
            if (follows)
                gpu.canvas.textRendering(session.specimenRendering);
        }
        bindInterfaceFace();
    }

    bool nativeIo(bool delegate() @system work)
    {
        static if (__traits(hasMember, Wsi, "beginNativeIo"))
        {
            if (wsi.beginNativeIo().hasError)
                return false;
            scope (exit)
                cast(void) wsi.endNativeIo();
        }
        return work();
    }

    // Set when the GPU did not finish in time for a surface to go: its next
    // frame reports the device lost, so a fresh one replaces it.
    bool deviceSuspect;

    // The surface scope ends: what the targets need, then the native
    // surface itself (`RES12`, `RES22`). The device stays.
    void releaseSurface()
    {
        if (!gpu.up)
            return;
        // Bounded: Android takes the window back 2 s after asking for it,
        // whether or not it was released (`sparkles.wsi.platform.android`).
        // A GPU that has not finished by then is treated as lost, and the
        // release goes on while the window still exists.
        if (gpu.sync.imageCount)
        {
            const finished = gpu.sync.finishedWithin(gpu.vk, surfaceReleaseWait.total!"nsecs");
            if (finished.hasError || !finished.value)
            {
                whyNot(i"the native arm's frames did not finish within $(surfaceReleaseWait); replacing the device");
                deviceSuspect = true;
            }
        }
        gpu.canvas.releaseTargets();
        gpu.views.destroy(gpu.vk);
        gpu.swapchainGoes();
        underBorrow(() {
            gpu.swapchain.destroy(gpu.vk);
            if (gpu.vk.surface !is null)
                gpu.vk.base.instance.destroySurfaceKHR(gpu.vk.base.instance.instance,
                    gpu.vk.surface, null);
        });
        gpu.vk.surface = null;
    }

    // A surface on the same device from the window's current handles.
    // `hasHandles` false: the window has none now, which is suspension.
    bool createSurface(out bool hasHandles)
    {
        releaseSurface();
        auto handles = wsi.nativeHandles(window);
        hasHandles = !handles.hasError;
        if (!hasHandles)
            return false;
        bool ok;
        cast(void) nativeIo(() {
            auto made = createNativeSurface(gpu.vk.base.instance, handles.value);
            if (made.hasError)
                return false;
            VkBool32 presentable;
            ok = gpu.vk.base.instance.getPhysicalDeviceSurfaceSupportKHR(
                gpu.vk.physicalDevice, gpu.vk.queueFamily, made.value, &presentable) >= 0
                && presentable;
            if (ok)
                gpu.vk.surface = made.value;
            else
                gpu.vk.base.instance.destroySurfaceKHR(gpu.vk.base.instance.instance,
                    made.value, null);
            return ok;
        });
        return ok;
    }

    // Presentation epochs stamp retired resources. A returned image and the
    // completed submit that waited for its acquisition prove earlier presents
    // are finished; a fixed number of rendering frames cannot prove that.
    ulong presents;

    // The frame's extents (`F13`), asked for once the swapchain shows
    // alpha: without it, the margin would show black, and the frame keeps
    // to the window. Asked again only when the answer changes.
    // The metrics they change follow in the event queue, and are taken
    // before the next frame is drawn: drawn first, a frame of the old size
    // would be committed with the new window geometry (`extentsPending`).
    bool extentsAsked, extentsPending;
    // What the traced frame spent (`--debug trace-frames`).
    FrameTiming timing;
    void askFrameExtents()
    {
        static if (__traits(hasMember, Wsi, "setFrameExtents"))
        {
            const want = session.frame.active && session.transparent;
            if (want == extentsAsked)
                return;
            extentsAsked = want;
            extentsPending = !wsi.setFrameExtents(window,
                want ? ClientFrame.extents : FrameExtents.init).hasError;
        }
    }

    /*
    Through an interactive resize the swapchain is kept while the window
    fits it, and grown with room to spare when it does not: the compositor
    crops each frame to the window (`setBufferCrop`). A new swapchain costs
    Mesa's Wayland WSI a round trip to the compositor, which mutter, busy
    resizing the window, answered in up to 110 ms; built for every step of a
    drag, those stalls were the drag's stutter. The room goes when the
    resize ends.
    */
    bool cropRefused;
    bool resizing()
    {
        static if (__traits(hasMember, Wsi, "setBufferCrop"))
            return !cropRefused && wsi.canCropBuffers
                && session.frame.state.has(ToplevelState.resizing);
        else
            return false;
    }

    bool rebuildSwapchain(bool force)
    {
        const window = metrics.physicalSize;
        const roomy = resizing();
        if (roomy && !force && gpu.swapchain.handle !is null
            && window.width <= gpu.swapchain.extent.width
            && window.height <= gpu.swapchain.extent.height)
            return true; // drawn into its corner, no rebuild
        const room = roomy ? roomFor(window, session.frame.state, metrics.scale.value,
            metrics.frameMargin) : PhysicalSize.init;
        // Stamped now: a swapchain made since the last present (a new
        // device's, a new surface's) has not been told the epoch yet.
        gpu.swapchain.epoch = gpu.sync.epoch = presents;
        // A frame of the client's casts its shadow and rounds its corners
        // in a transparent margin, which the swapchain's alpha must reach.
        gpu.swapchain.wantsAlpha = session.frame.active;
        auto mark = MonoTime.currTime;
        Duration lap()
        {
            const at = MonoTime.currTime, since = at - mark;
            mark = at;
            return since;
        }
        if (gpu.sync.imageCount)
            cast(void) gpu.sync.waitAll(gpu.vk);
        timing.settle += lap();
        gpu.canvas.releaseTargets();
        timing.release += lap();
        const before = gpu.swapchain.handle;
        bool ok;
        cast(void) nativeIo(() {
            auto updated = Swapchain.recreate(gpu.swapchain, gpu.vk, window, force,
                minAlloc: room, growOnly: roomy);
            // The room is a guess the device may not afford (the whole
            // output, on a large one): the window's own size is tried
            // before the rebuild fails. The failed swapchain is gone
            // either way, so this one is made afresh.
            if (updated.hasError && room != PhysicalSize.init)
                updated = Swapchain.recreate(gpu.swapchain, gpu.vk, window, true);
            ok = !updated.hasError;
            if (!ok)
                whyNot(i"the native arm could not build a swapchain: $(updated.error)");
            return ok;
        });
        timing.swapchain += lap();
        // A new handle retired the old one, the rebuild failed or not.
        if (gpu.swapchain.handle !is before)
            gpu.swapchainGoes();
        if (!ok)
            return false;
        gpu.views.create(gpu.vk, gpu.swapchain);
        timing.views += lap();
        // Premultiplied in the stored bytes only on a UNORM target: an sRGB
        // one encodes the colour but not the alpha, so its translucent
        // pixels would not be premultiplied as the compositor reads them.
        session.transparent = gpu.swapchain.compositeAlpha
            == VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR
            && !isSrgb(gpu.swapchain.format);
        askFrameExtents();
        const images = cast(uint) gpu.swapchain.images.length;
        const synced = gpu.sync.imageCount == 0 ? FrameSync.create(gpu.sync, gpu.vk, images)
            : gpu.sync.replaceImages(gpu.vk, images);
        timing.sync += lap();
        if (synced.hasError)
            whyNot(i"the native arm could not synchronize its frames: $(synced.error)");
        return !synced.hasError;
    }

    bool bringUpOnce()
    {
        auto handles = wsi.nativeHandles(window);
        if (handles.hasError)
        {
            whyNot(i"the native arm found no native handles for the window: $(handles.error.diagnostic[])");
            return false;
        }
        bool made;
        cast(void) nativeIo(() {
            auto context = VulkanContext.create(gpu.vk, handles.value, ContextRequest(
                applicationName: request.app.nameOrDefault.idup,
                applicationVersion: makeApiVersion(0, request.app.version_[0],
                    request.app.version_[1], request.app.version_[2]),
                apiVersion: apiVersion13,
                validation: cfg.native.debugging.vulkanValidation,
                // Scopes as debug labels too, for RenderDoc and Nsight.
                debugLabels: cfg.native.debugging.gpuTiming
                    || cfg.native.debugging.renderdocCapture > 0));
            made = !context.hasError;
            if (!made)
                whyNot(i"the native arm found no Vulkan device for the window: $(context.error.diagnostic[])");
            return made;
        });
        if (!made)
            return false;
        gpu.memory = DeviceMemory!DeviceMemoryBackend(DeviceMemoryBackend(gpu.vk.instance,
            gpu.vk.physicalDevice, gpu.vk.device));
        gpu.up = true;
        cast(void) gpu.vk.loadPipelineCache(pipelineCachePath);
        pipelinesSaved = false;
        if (!rebuildSwapchain(true))
            return false;
        const pool = CommandPool.create(gpu.commands, gpu.vk, gpu.sync.framesInFlight);
        if (pool.hasError)
        {
            whyNot(i"the native arm could not create its command pool: $(pool.error)");
            return false;
        }
        CanvasConfig canvasConfig;
        canvasConfig.frameSlots = gpu.sync.framesInFlight;
        canvasConfig.baselineShaders = cfg.native.debugging.vulkanSpirv11;
        canvasConfig.forceRenderPass = cfg.native.debugging.vulkanRenderPass;
        canvasConfig.suppressPipelineFeedback = cfg.native.debugging.vulkanNoFeedback;
        const canvasMade = NativeCanvas.create(gpu.canvas, gpu.vk.device, gpu.memory,
            DeviceFacts.of(gpu.vk.base), canvasConfig);
        if (canvasMade.hasError)
        {
            whyNot(i"the native arm could not create its canvas: $(canvasMade.error)");
            return false;
        }
        session.canvas = &gpu.canvas;
        bindFont();
        return true;
    }

    // A device brought up partway is torn down again, so every retry starts
    // from nothing: no device of an earlier attempt is leaked, and no fence
    // of one is waited on by another.
    bool bringUp()
    {
        if (bringUpOnce())
            return true;
        underBorrow(() { gpu.destroy(); });
        return false;
    }

    // A window can lose its surface before the device comes up — an Android
    // activity started behind the keyguard is given one and has it taken
    // away at once — and then waits for the next one rather than failing.
    while (!bringUp())
    {
        if (!wsi.nativeHandles(window).hasError)
        {
            whyNot(i"the native arm could not bring up Vulkan on the window");
            return false;
        }
        bool closing;
        do
        {
            if (wsi.runIntegratedOnce(loop, 1.seconds).hasError)
                return false;
            cast(void) wsi.drain((WindowEvent e) {
                noteEvent(e);
                if (e.window != window)
                    return;
                e.payload.match!(
                    (in SurfaceMetricsChangedEvent m) { metrics = m.metrics; },
                    (in CloseRequestedEvent _) { closing = true; },
                    (in _) {});
            });
            if (closing)
                return true;
        }
        while (wsi.nativeHandles(window).hasError);
        takeMetrics();
        if (const px = lc.metrics(surfaceOf(metrics)))
            measure(px);
    }
    lc.started(surfaceOf(metrics));
    trace(i"native arm: $(gpu.vk.deviceName) $(gpu.swapchain.extent.width)x$(gpu.swapchain.extent.height), cells $(session.font.cellW)x$(session.font.cellH)");

    // ── the host ──
    NativeHost host;
    host.session_ = &session;
    // The platform determines capabilities; gesture recognition is optional.
    // Applications with raw touch capture (such as sliders) still need to
    // distinguish a touchscreen from a hovering mouse.
    TouchGestures touch = TouchGestures.none;
    version (Android)
    {
        touch = cfg.touchGestures;
        host.capabilities = touchPointer;
    }
    host.capabilities.keyRelease = cfg.keyRelease;
    WsiInput input;
    host.input_ = &input;
    input.capabilities = host.capabilities;
    input.touchGestures = touch;
    input.gestures.cfg.fractional = true;
    input.fractionalScroll = cfg.fractionalScroll;
    input.scale = metrics.scale.value;
    insetInput = &input;
    inset();

    // The application's pointer shape, kept while the frame shows its own
    // over a resize border, and shown again when the pointer leaves it.
    PointerShape appCursor = PointerShape.default_;
    bool frameCursor;
    session.setCursor = (PointerShape s) {
        appCursor = s;
        if (!frameCursor)
            cast(void) wsi.setCursor(window, s);
    };
    session.title = fitTitle(request.title, 255).dup;
    // Without the application's colours the frame is Adwaita's own.
    session.framePalette = request.hasFramePalette ? request.framePalette : Palette.init;
    // Well-formed, so the window system takes it; a long one is the
    // window system's to shorten, as the bar ellipsizes it.
    session.setTitle = (in char[] t) {
        session.title = fitTitle(t, maxTitleBytes).dup;
        static if (__traits(hasMember, Wsi, "setTitle"))
            cast(void) wsi.setTitle(window, session.title);
    };
    session.setClipboard = (scope const(char)[] text) {
        cast(void) wsi.offerClipboard(window, "text/plain;charset=utf-8",
            cast(const(ubyte)[]) text);
    };
    // The user's size: kept by the machine across later scale changes
    // (`RES55`).
    session.setFontSize = (int px) {
        measure(lc.fontSize(px));
        bindFont();
    };
    session.setSpecimen = (in SpecimenFontRequest wanted) {
        if (session.specimen.bytes.length && sameSpecimenRequest(wanted, session.specimen.request))
        {
            if (wanted.generation && wanted.generation != session.specimenGeneration)
            {
                session.specimenGeneration = wanted.generation;
                session.specimenRequestedAt = wanted.requestedAt != MonoTime.init
                    ? wanted.requestedAt : MonoTime.currTime;
            }
            return true;
        }
        const followed = session.specimen.bytes.length && session.specimen.request.uiFollows;
        if (!session.specimen.prepare(wanted))
            return false;
        session.specimenGeneration = wanted.generation ? wanted.generation : session.specimenGeneration + 1;
        session.specimenRequestedAt = wanted.requestedAt != MonoTime.init
            ? wanted.requestedAt : MonoTime.currTime;
        if (wanted.uiFollows)
        {
            if (!followed)
            {
                session.interfaceFont = session.font;
                if (gpu.up)
                    session.interfaceRendering = gpu.canvas.textRendering;
            }
            cast(void) lc.fontSize(wanted.px);
            adoptSpecimen();
            inset();
            bindFont();
            if (gpu.up && session.specimenRenderingSet)
                gpu.canvas.textRendering(session.specimenRendering);
        }
        else
        {
            if (followed)
            {
                session.font = session.interfaceFont;
                cast(void) lc.fontSize(session.font.px);
                inset();
                bindFont();
                if (gpu.up)
                    gpu.canvas.textRendering(session.interfaceRendering);
            }
            else if (gpu.up)
                cast(void) gpu.canvas.specimenFont(session.specimen.bytes, wanted.faceIndex,
                    session.specimen.ppem, wanted.coordinates, session.specimen.metrics, wanted.contentHash,
                    session.specimen.cellH, wanted.familyStyles ? wanted.styleBytes[] : null,
                    wanted.styleIndices[], wanted.styleContentHashes[], preparedFallbacks(session));
        }
        return true;
    };
    session.setTextInput = (bool on) {
        static if (__traits(hasMember, Wsi, "setTextInput"))
            cast(void) wsi.setTextInput(window, on);
    };

    scope (exit)
        shutdown(host);
    setup(host);
    // The scheme the application starts in, as the desktop prefers it.
    if (appearance.hasScheme)
        handle(host, Event(ColorSchemeEvent(dark: appearance.prefersDark)));

    const unitW = () => cfg.pointerUnit == PointerUnit.pixels ? 1 : session.font.cellW;
    const unitH = () => cfg.pointerUnit == PointerUnit.pixels ? 1 : session.font.cellH;

    // `--debug trace-frames`: a line on standard error per frame presented,
    // and per frame the swapchain turned out stale for, so a run can show an
    // idle window drawing nothing, or one rebuilding forever.
    // `trace-frames-over=N` collects the same detail and logs only the frames
    // that took N ms or more.
    const traceFrames = cfg.native.debugging.traceFrames
        || cfg.native.debugging.traceFramesOver > 0;
    const traceOver = dur!"msecs"(cfg.native.debugging.traceFramesOver);
    const opened = MonoTime.currTime;
    // The device's time is measured where a switch reports it.
    const timeDevice = traceFrames || cfg.native.debugging.gpuTiming
        || cfg.native.debugging.frameTrace.length || cfg.native.debugging.renderdocCapture > 0;
    // `--debug renderdoc-capture=N`: RenderDoc captures frame N, its GPU
    // scopes labelled (`PRF12`).
    RenderDoc renderDoc;
    scope (exit)
        if (cfg.native.debugging.renderdocCapture > 0)
            note(i"native window renderdoc: $(renderDoc.captures) captures");
    gpu.clock = FrameClock.since(opened);
    ulong recorded; // frames recorded, presented or not
    struct PendingSpecimen
    {
        ulong frame = ulong.max;
        ulong generation;
        MonoTime requestedAt;
    }
    PendingSpecimen[128] pendingSpecimens;
    ulong submittedSpecimenGeneration;
    // Pipelines the driver built (not served from its cache) so far: a frame
    // that built one carries `pipelineCompiled` (`PRF16`). A new canvas, after
    // a lost device, counts from zero again.
    uint pipelinesBuilt;
    // A frame drawn (presented or not) as a `FrameRecord`: its phases in the
    // order the pass ran them, the rebuild before it included.
    FrameRecord recordOf(MonoTime started, in FrameTiming timing, FrameFlags flags)
    {
        FrameRecord r;
        r.number = recorded++;
        r.start = started - opened - timing.rebuild;
        r.flags = flags;
        if (timing.rebuild > Duration.zero)
            r.flags |= FrameFlags.rebuilt;
        if (timing.acquired == VkResult.VK_SUBOPTIMAL_KHR
            || timing.presented == VkResult.VK_SUBOPTIMAL_KHR)
            r.flags |= FrameFlags.suboptimal;
        const made = gpu.canvas.pipelineCompiles;
        const built = made.compiled + made.unreported;
        if (built < pipelinesBuilt)
            pipelinesBuilt = 0;
        if (built > pipelinesBuilt)
        {
            r.flags |= FrameFlags.pipelineCompiled;
            pipelinesBuilt = built;
        }
        Duration at;
        void phase(FramePhase p, Duration took)
        {
            r.phases[p].start = at;
            r.phases[p].took = took;
            at += took;
        }
        phase(FramePhase.rebuild, timing.rebuild);
        phase(FramePhase.build, timing.build);
        phase(FramePhase.wait, timing.wait);
        phase(FramePhase.acquire, timing.acquire);
        phase(FramePhase.record, timing.record);
        phase(FramePhase.present, timing.present);
        r.cpu = MonoTime.currTime - opened - r.start;
        r.zones = zones;
        return r;
    }
    // The device's time arrives `framesInFlight` frames late: it belongs to
    // the record of the frame that slot drew last.
    void noteDeviceTime(in FrameRecord late, ulong frame)
    {
        if (late.gpu <= Duration.zero)
            return;
        gpuTimes.note(late.gpu);
        tracyPlot!"gpu ms"(late.gpu.total!"hnsecs" / 1e4);
        if (history is null)
            return;
        if (auto r = history.find(frame))
        {
            r.gpu = late.gpu;
            foreach (ref s; late.scopes)
                r.addGpuScope(s);
        }
    }
    // When a frame reached the display, where the window system says
    // (`PRF13`, Wayland's presentation feedback): its record is marked, its
    // latency counted, and the display's refresh measures the hitches.
    // Frame `tag` reached the display at `shown`, `refresh` its period where
    // known: from Wayland's feedback, Android's display timing, or a present
    // wait's poll.
    void onShown(ulong tag, MonoTime shown, Duration refresh)
    {
        ref pending = pendingSpecimens[tag % pendingSpecimens.length];
        if (pending.frame == tag && pending.generation && shown >= pending.requestedAt)
        {
            const took = shown - pending.requestedAt;
            ++session.specimenLatency.shown;
            session.specimenLatency.latestShownGeneration = pending.generation;
            session.specimenLatency.latestShown = took;
            if (took > dur!"hnsecs"(166_667))
                ++session.specimenLatency.shownDeadlineMisses;
            if (traceFrames)
                note(i"specimen generation $(pending.generation): request-to-visible $(took.total!"usecs") us");
            pending = PendingSpecimen.init;
        }
        frameTimes.noteRefresh(refresh);
        gpuTimes.noteRefresh(refresh); // the device's hitches by the same display
        if (history is null)
            return;
        if (auto r = history.markShown(tag, shown - opened))
        {
            Duration latency;
            if (!r.has(FrameFlags.skipped) && r.latency(latency))
                frameTimes.noteLatency(latency);
        }
    }
    // Wayland's presentation feedback.
    void onPresented(in PresentedEvent p)
    {
        if (!p.discarded && p.shownKnown)
            onShown(p.tag, p.shown, p.refresh);
    }
    // Which recorded frame each slot drew last.
    ulong[8] slotFrame = ulong.max;
    Duration now() => MonoTime.currTime - opened;
    uint presented;
    // Since when the traced frame's size has waited.
    MonoTime resizedAt;
    // `--debug lose-device-at=N`: treat frame N as a lost device, which no
    // software driver produces on demand, so the rebuild can be shown to
    // redraw.
    uint loseDeviceAt = cfg.native.debugging.loseDeviceAt;

    /*
    The frame answers the pointer before the application (`F13`): a press on
    the bar or a border goes to the window system as a move, a resize or a
    button's action, and never reaches the cells. `true` when the frame took
    the event. `frameDirty` says the bar's hover or pressed state changed,
    taken or not, so the frame is drawn again.
    */
    bool frameDirty;
    bool routeFrame(in sparkles.wsi.events.PointerEvent p)
    {
        if (!session.frame.active)
            return false;
        const geometry = FrameGeometry(surfaceW: session.pixelW, surfaceH: session.pixelH,
            top: metrics.safeInsets.top + metrics.frameMargin.top, cellW: session.font.cellW,
            cellH: session.font.cellH, density: cast(float) session.scale,
            margin: metrics.frameMargin.left);
        const hit = session.frame.hitTest(cast(int) p.physicalPosition.x,
            cast(int) p.physicalPosition.y, geometry);
        void cursorFor(in FrameHit h)
        {
            if (h.part == FramePart.resize)
            {
                frameCursor = true;
                cast(void) wsi.setCursor(window, resizeCursor(h.edge));
            }
            else if (frameCursor)
            {
                frameCursor = false;
                cast(void) wsi.setCursor(window, appCursor);
            }
        }
        void act(FrameAction action)
        {
            final switch (action)
            {
                case FrameAction.none:
                    break;
                case FrameAction.move:
                    static if (__traits(hasMember, Wsi, "startInteractiveMove"))
                        cast(void) wsi.startInteractiveMove(window);
                    break;
                case FrameAction.resize:
                    static if (__traits(hasMember, Wsi, "startInteractiveResize"))
                        cast(void) wsi.startInteractiveResize(window, hit.edge);
                    break;
                case FrameAction.toggleMaximized:
                    static if (__traits(hasMember, Wsi, "setMaximized"))
                        cast(void) wsi.setMaximized(window,
                            !session.frame.state.has(ToplevelState.maximized));
                    break;
                case FrameAction.minimize:
                    static if (__traits(hasMember, Wsi, "setMinimized"))
                        cast(void) wsi.setMinimized(window);
                    break;
                case FrameAction.close:
                    lc.close();
                    break;
                case FrameAction.windowMenu:
                    static if (__traits(hasMember, Wsi, "showWindowMenu"))
                        cast(void) wsi.showWindowMenu(window, p.logicalPosition);
                    break;
            }
        }
        // A press the application took keeps its drag, over the frame or
        // not, until its release.
        alias Phase = ClientFrame.Phase;
        const phase = p.phase == PointerPhase.pressed ? Phase.pressed
            : p.phase == PointerPhase.released ? Phase.released : Phase.moved;
        if (p.phase == PointerPhase.left)
            session.frame.pointerLeft();
        else if (session.frame.applicationOwns(phase, p.button, hit.part))
            return false;
        final switch (p.phase)
        {
            case PointerPhase.entered:
            case PointerPhase.moved:
                cursorFor(hit);
                if (session.frame.holding)
                {
                    act(session.frame.motion(cast(int) p.physicalPosition.x,
                        cast(int) p.physicalPosition.y, cast(float) session.scale));
                    return true;
                }
                const was = session.frame.hover;
                session.frame.hover = hit.part == FramePart.resize ? FramePart.content : hit.part;
                frameDirty |= session.frame.hover != was;
                return hit.part != FramePart.content;
            case PointerPhase.left:
                cursorFor(FrameHit(FramePart.content));
                frameDirty |= session.frame.hover != FramePart.content;
                session.frame.hover = FramePart.content;
                return false;
            case PointerPhase.pressed:
                if (hit.part == FramePart.content)
                    return false;
                act(session.frame.press(hit, p.button == PointerButton.right, MonoTime.currTime,
                    cast(int) p.physicalPosition.x, cast(int) p.physicalPosition.y));
                frameDirty = true;
                return true;
            case PointerPhase.released:
                if (session.frame.holding)
                {
                    act(session.frame.release(hit));
                    frameDirty = true;
                    return true;
                }
                return hit.part != FramePart.content;
        }
    }

    // One drain: everything the window system queued, translated and handed
    // to the application. Metrics apply at once, so the application's
    // resize and every later event in the batch see the new scale and cell
    // size (`HST7`, `RES42`).
    void drainEvents()
    {
        bool delivered;
        cast(void) wsi.drain((WindowEvent e) @trusted {
            noteEvent(e);
            // `@trusted` for the one call it exists for: the WSI asks for a
            // `@safe` sink, and the event goes to the application, whose
            // handler it cannot vouch for. Text is read only here (`ED8`).
            if (e.window != window && e.window != WindowId.init)
                return;
            bool input_ = true;
            void onMetrics(in SurfaceMetrics m)
            {
                // A lost surface goes before this drain returns, which is
                // what acknowledges the loss (`RES12`): Android destroys the
                // native window then. The machine's later release finds
                // nothing left to do.
                if (m.suspended)
                    releaseSurface();
                if (traceFrames && m.physicalSize != metrics.physicalSize
                    && resizedAt == MonoTime.init)
                    resizedAt = MonoTime.currTime;
                metrics = m;
                takeMetrics();
                input.scale = m.scale.value;
                if (const px = lc.metrics(surfaceOf(m)))
                    {
                    measure(px);
                    bindFont();
                }
            }
            e.payload.match!(
                (in WindowStateChangedEvent w) {
                    // A frame drawn from now on looks its title face up now,
                    // not in its first frame (a no-op once looked up).
                    if (ClientFrame(state: w.state).active)
                        session.titleFace.prepare(session.titlePattern);
                    // A crop refused once is tried again with the next resize.
                    if (w.state.has(ToplevelState.resizing)
                        && !session.frame.state.has(ToplevelState.resizing))
                        cropRefused = false;
                    session.frame.state = w.state;
                    // The resize's room goes with it.
                    if (gpu.up && !resizing() && cornerOf(gpu.swapchain.extent,
                        metrics.physicalSize.width, metrics.physicalSize.height,
                        quarterTurns(gpu.swapchain.transform)).width)
                        lc.retarget();
                    askFrameExtents();
                    inset();
                    lc.exposed();
                    input_ = false;
                },
                (in sparkles.wsi.events.PointerEvent p) {
                    if (routeFrame(p))
                        input_ = false;
                    delivered |= !input_ || frameDirty;
                    frameDirty = false;
                },
                (in ReadyEvent r) { onMetrics(r.metrics); },
                (in SurfaceMetricsChangedEvent m) { onMetrics(m.metrics); },
                (in FrameReadyEvent _) { lc.frameReady(); input_ = false; },
                (in PresentedEvent p) { onPresented(p); input_ = false; },
                (in ExposedEvent _) { lc.exposed(); input_ = false; },
                (in OccludedEvent o) { lc.occluded(o.occluded); input_ = false; },
                (in CloseRequestedEvent _) { lc.close(); input_ = false; },
                (in MemoryPressureEvent m) { lc.memoryPressure(m.critical); input_ = false; },
                (in _) {});
            if (input_)
            {
                configureGestures(input, session.font);
                deliverInput!handle(host, input, wsi, e, unitW(), unitH(), delivered);
            }
        });
        // Time resolves gestures too: a long-press, a fling's tail.
        if (input.gesturing)
            input.tickGestures(MonoTime.currTime, unitW(), unitH(), (Event x) {
                handle(host, withRealSize(x, host.size));
                delivered = true;
            });
        session.touches = input.contacts;
        flushInput!handle(host, input, delivered);
        version (Android) {} else version (linux)
            if (portal.isOpen && portal.service())
            {
                const next = portal.current.overriddenBy(pinnedAppearance);
                frameAppearance(next, true);
                // The interface font too, where the desktop chooses it.
                cast(void) followDesktopInterfaceFont(session, request, next);
                lc.exposed();
                if (next.hasScheme && (!appearance.hasScheme
                    || next.prefersDark != appearance.prefersDark))
                {
                    handle(host, Event(ColorSchemeEvent(dark: next.prefersDark)));
                    delivered = true;
                }
                appearance = next;
            }
        if (delivered)
            lc.input();
    }

    bool ok = true;
    // The last frame pass, drawn or not: the application's timed wake
    // (`HST16`) counts from here, not from each park, which a window system
    // waking the loop with nothing to deliver (Android's inset poll while the
    // keyboard is up) would otherwise restart forever.
    MonoTime lastPass = MonoTime.currTime;
    // `--debug resize-stress`: every 30 frames a new size — a maximize toggle
    // where the compositor sizes the window (Wayland), a step through a band
    // of sizes where the client may (X11). `--debug frames=N`: close after N.
    // A window system with neither verb (Android) cannot be stressed: the
    // switch is reported once and changes nothing.
    enum canStress = __traits(hasMember, Wsi, "setMaximized")
        || __traits(hasMember, Wsi, "setLogicalSize");
    const resizeStress = canStress && cfg.native.debugging.resizeStress;
    if (cfg.native.debugging.resizeStress && !canStress)
        whyNot(i"resize-stress: this window system cannot resize a window");
    // A scripted run that stops presenting — a window minimized, a surface
    // lost for good — ends, failed, rather than waiting out a lane's timeout.
    const scripted = resizeStress || cfg.native.debugging.frames > 0;
    enum stalledAfter = 10.seconds;
    MonoTime lastProgress = MonoTime.currTime;
    uint stressStep;
    bool drawsContinuously() => resizeStress
        || (cfg.native.debugging.frames > 0 && presented < cfg.native.debugging.frames);
    void stressAndBudget()
    {
        lastProgress = MonoTime.currTime;
        if (cfg.native.debugging.frames > 0 && presented >= cfg.native.debugging.frames)
            host.quit();
        if (!resizeStress || presented % 30 != 0)
            return;
        static if (__traits(hasMember, Wsi, "setMaximized"))
        {
            // From the state the compositor reports, not a guess: a window
            // that starts maximized is restored first.
            cast(void) wsi.setMaximized(window,
                !session.frame.state.has(ToplevelState.maximized));
        }
        else static if (__traits(hasMember, Wsi, "setLogicalSize"))
        {
            ++stressStep;
            cast(void) wsi.setLogicalSize(window, LogicalSize(480 + (stressStep % 7) * 160,
                320 + (stressStep % 5) * 120));
        }
    }

    for (;;)
    {
        if (host.quitRequested)
            lc.close();
        if (scripted && MonoTime.currTime - lastProgress >= stalledAfter)
        {
            whyNot(i"the scripted run presented nothing for $(stalledAfter.total!"seconds") s, after $(presented) frames");
            ok = false;
            break;
        }
        const plan = lc.step(now(), host.wakeAsk);
        if (plan.stop)
        {
            if (plan.failure != Failure.none)
            {
                whyNot(i"the native arm stopped: $(plan.failure)");
                ok = false;
            }
            break;
        }
        if (plan.releaseDevice)
            underBorrow(() { gpu.destroy(); });
        if (plan.releaseSurface)
            releaseSurface();
        if (plan.releaseCaches && gpu.up)
            gpu.canvas.releaseCaches();
        if (plan.createDevice)
        {
            trace(i"native arm: rebuilding the device");
            underBorrow(() { gpu.destroy(); });
            if (!bringUp())
            {
                lc.rebuildFailed(Rebuild.device);
                continue;
            }
            lc.rebuilt(Rebuild.device);
            // A new device: no slot holds a frame, no pipeline is built, and
            // the lost pass's times are nobody's.
            slotFrame[] = ulong.max;
            pipelinesBuilt = 0;
            timing = FrameTiming.init;
        }
        if (plan.createSurface)
        {
            bool hasHandles;
            if (!createSurface(hasHandles))
            {
                lc.rebuildFailed(Rebuild.surface, hasHandles);
                continue;
            }
            lc.rebuilt(Rebuild.surface);
        }
        if (plan.rebuildTargets && !plan.createDevice)
        {
            const rebuildStarted = MonoTime.currTime;
            scope (exit)
                timing.rebuild += MonoTime.currTime - rebuildStarted;
            auto rebuildZone = tracyZone!"rebuild";
            if (!rebuildSwapchain(plan.createSurface || plan.replaceTargets))
            {
                lc.rebuildFailed(Rebuild.targets);
                continue;
            }
            lc.rebuilt(Rebuild.targets);
        }

        if (plan.draw)
        {
            if (extentsPending)
            {
                extentsPending = false;
                drainEvents();
                continue;
            }
            // X11 presents at once: a loop drawing continuously would draw
            // frames mailbox never shows. Wait until the last present is
            // shown, so it draws one a refresh and each is shown, its
            // display time stamped as the wait ends (`PRF13`).
            if (!paced && gpu.up && gpu.vk.presentWait)
                cast(void) waitForNewest(gpu.presentWait, gpu.vk, 50.msecs,
                    (ulong id, MonoTime at) { onShown(id - 1, at, Duration.zero); });
            const started = MonoTime.currTime;
            lastPass = started;
            // The pass's zones, on this thread, until it ends however it does.
            zones = FrameZones.init;
            () @trusted { FrameZones.current = &zones; }();
            counters.beginFrame();
            scope (exit)
                FrameZones.current = null;
            // Tracy's zones for the pass: the frame, and within it the phases
            // `FrameTiming` laps (the rebuild before it stands alone).
            auto frameZone = tracyZone!"frame";
            auto buildZone = tracyZone!"build";
            // A scripted run (`frames=N`, `resize-stress`) draws continuously:
            // an idle application presents nothing, and neither would end. Its
            // frames may not be skipped either: a skipped frame keeps the
            // request standing and the opportunity open, and the loop spun.
            buildFrame!present(host, plan.mustDraw || drawsContinuously);
            timing.build = MonoTime.currTime - started;
            buildZone.end();
            lc.requested(host.frameRequested || drawsContinuously);
            if (host.frameSkipped)
                continue;
            // Acquire and present may read the shared display themselves —
            // Mesa's Wayland present round-trips for a compositor's colour
            // management, and its acquire waits for buffer releases — and a
            // read the window system holds prepared would block them forever.
            // Without the borrow the frame is not drawn — the same rule as
            // `nativeIo` — and is asked for again.
            if (deviceSuspect)
            {
                deviceSuspect = false;
                lc.frameDone(FrameResult.deviceLost, now());
                continue;
            }
            // A frame that does not present comes back at once, so the
            // window system is read first without waiting: a swapchain that
            // stays stale must not keep input and a close from arriving.
            bool pollNow()
            {
                if (wsi.runIntegratedOnce(loop, Duration.zero).hasError)
                    return false;
                drainEvents();
                return true;
            }
            static if (__traits(hasMember, Wsi, "beginNativeIo"))
                if (wsi.beginNativeIo().hasError)
                {
                    lc.frameDone(FrameResult.again, now());
                    if (!pollNow())
                        break;
                    continue;
                }
            FrameOutcome outcome;
            {
                // Ended however the frame ends, a throw included.
                static if (__traits(hasMember, Wsi, "beginNativeIo"))
                    scope (exit)
                        cast(void) wsi.endNativeIo();
                // A swapchain with room shows only the window's corner of it.
                // Without the crop the whole image would show, its undrawn
                // rest too: the frame is not presented, and the swapchain is
                // built again at the window's size.
                bool cropped = true;
                static if (__traits(hasMember, Wsi, "setBufferCrop"))
                {
                    const corner = cornerOf(gpu.swapchain.extent, session.pixelW, session.pixelH,
                        quarterTurns(gpu.swapchain.transform));
                    if ((corner.width || wsi.canCropBuffers) && wsi.setBufferCrop(window,
                        PhysicalSize(corner.width, corner.height)).hasError && corner.width)
                    {
                        cropRefused = true;
                        cropped = false;
                        lc.retarget();
                    }
                }
                timing.traced = timeDevice;
                // Asked once the frame is submitted, just before the present
                // whose commit it answers for: such a pass is always a
                // record, numbered `recorded`.
                void beforePresent() @system
                {
                    // Even an out-of-date present queues semaphore waits.
                    // Count attempts so an earlier acquire proof cannot free
                    // resources still used by that later rejected present.
                    gpu.swapchain.epoch = gpu.sync.epoch = ++presents;
                    const generation = session.specimenDrawnGeneration;
                    const changed = generation && generation != submittedSpecimenGeneration;
                    if (changed)
                    {
                        pendingSpecimens[recorded % pendingSpecimens.length] =
                            PendingSpecimen(recorded, generation, session.specimenRequestedAt);
                        submittedSpecimenGeneration = generation;
                        const took = MonoTime.currTime - session.specimenRequestedAt;
                        ++session.specimenLatency.submitted;
                        session.specimenLatency.latestSubmittedGeneration = generation;
                        session.specimenLatency.latestSubmitted = took;
                        if (took > dur!"hnsecs"(166_667))
                            ++session.specimenLatency.submissionDeadlineMisses;
                        if (traceFrames)
                            note(i"specimen generation $(generation): request-to-submit $(took.total!"usecs") us");
                    }
                    bool feedback;
                    static if (__traits(hasMember, Wsi, "requestPresentationFeedback"))
                        if ((history !is null || changed) && wsi.canReportPresentation)
                            feedback = !wsi.requestPresentationFeedback(window, recorded).hasError;
                    // Without the window system's feedback, the device's.
                    gpu.presentTag = recorded;
                    gpu.tagPresents = !feedback && (history !is null || changed);
                    // Unpaced, every present carries an id: the next pass
                    // waits for it.
                    gpu.waitPresents = gpu.vk.presentWait
                        && (!paced || gpu.tagPresents && !gpu.vk.displayTiming);
                }
                if (presented + 1 == cfg.native.debugging.renderdocCapture)
                {
                    if (renderDoc.find())
                        renderDoc.triggerCapture();
                    else
                        note(i"native window renderdoc: not in the process; run under renderdoccmd capture");
                }
                outcome = cropped
                    ? drawFrame!draw(*gpu, host, session, request.ground, timing, &beforePresent)
                    : FrameOutcome.again;
            }
            if (presented + 1 == loseDeviceAt)
            {
                loseDeviceAt = 0;
                outcome = FrameOutcome.deviceLost;
            }
            // The pass as a record (`PRF1`): every pass that submitted is
            // one, presented or not, so the presentation feedback it asked
            // for finds it; one that queued nothing is one only for the
            // trace. A frame presented suboptimal or before a rebuild was
            // still shown, and counts as shown.
            const took = MonoTime.currTime - started + timing.rebuild;
            const shown = timing.shown && outcome != FrameOutcome.again;
            if (shown && gpu.sync.presentationCompletionKnown)
            {
                gpu.sync.reapThrough(gpu.vk, gpu.sync.completedPresentEpoch);
                gpu.swapchain.reapThrough(gpu.vk, gpu.sync.completedPresentEpoch);
            }
            bool recordMade;
            if (timing.collected)
            {
                // What the slot measured belongs to the frame it drew last,
                // whatever became of this pass.
                const slot = timing.slot % slotFrame.length;
                if (slotFrame[slot] != ulong.max)
                    noteDeviceTime(timing.late, slotFrame[slot]);
                slotFrame[slot] = timing.submitted ? recorded : ulong.max;
            }
            if (timing.submitted || (history !is null
                && (outcome == FrameOutcome.rebuild || outcome == FrameOutcome.deviceLost)))
            {
                FrameFlags flags = frameTimes.frames == 0 && shown ? FrameFlags.firstFrame
                    : FrameFlags.none;
                if (!shown)
                    flags |= FrameFlags.skipped;
                if (outcome == FrameOutcome.deviceLost)
                    flags |= FrameFlags.deviceLost;
                else if (outcome == FrameOutcome.rebuild && !shown)
                    flags |= FrameFlags.outOfDate;
                auto r = recordOf(started, timing, flags);
                r.cpu = took;
                counters.endFrame(keep: shown);
                if (shown)
                {
                    frameTimes.note(r);
                    zoneTimes.note(r.zones);
                }
                if (history !is null)
                    history.add(r);
                recordMade = true;
            }
            // What the device says reached the display, its record now in
            // the history: never waits.
            if (timing.submitted && gpu.up)
            {
                if (gpu.vk.displayTiming)
                    gpu.displayTimes.poll(gpu.vk, gpu.swapchain.handle, (uint id, long ns) {
                        onShown(id - 1, MonoTime.zero + nsecs(ns), gpu.displayTimes.refresh);
                    });
                else if (gpu.vk.presentWait)
                    pollCompleted(gpu.presentWait, gpu.vk, (ulong id, MonoTime at) {
                        onShown(id - 1, at, Duration.zero);
                    });
            }
            if (timing.collected && traceNames.length != gpu.profiler.names.length)
                traceNames = gpu.profiler.names.dup; // a copy: the table goes with the device
            final switch (outcome)
            {
                case FrameOutcome.presented:
                    lc.frameDone(FrameResult.presented, now());
                    ++presented;
                    const done = MonoTime.currTime;
                    frameZone.end();
                    tracyFrameMark();
                    tracyPlot!"frame ms"(took.total!"hnsecs" / 1e4);
                    if (summarizeFrames)
                        cast(void) memory.sample(gpu.vk, done);
                    if (!pipelinesSaved)
                        savePipelines();
                    stressAndBudget();
                    if (traceFrames && (cfg.native.debugging.traceFrames || took >= traceOver))
                    {
                        const resize = resizedAt == MonoTime.init ? Duration.zero
                            : done - resizedAt;
                        note(i"native frame $(presented) at $((started - opened).total!"msecs") ms, $(session.pixelW)x$(session.pixelH) in $(gpu.swapchain.extent.width)x$(gpu.swapchain.extent.height): rebuild $(timing.rebuild.total!"usecs") us, build $(timing.build.total!"usecs"), wait $(timing.wait.total!"usecs"), acquire $(timing.acquire.total!"usecs"), record $(timing.record.total!"usecs"), present $(timing.present.total!"usecs"), gpu $(timing.gpu.total!"usecs") (frame -$(gpu.sync.framesInFlight)); resize shown after $(resize.total!"usecs") us; rebuild: settle $(timing.settle.total!"usecs"), release $(timing.release.total!"usecs"), swapchain $(timing.swapchain.total!"usecs"), views $(timing.views.total!"usecs"), sync $(timing.sync.total!"usecs")");
                        resizedAt = MonoTime.init;
                    }
                    session.frameSeconds = lc.frameSeconds;
                    break;
                case FrameOutcome.again:
                    lc.frameDone(FrameResult.again, now());
                    break;
                case FrameOutcome.rebuild:
                    lc.frameDone(FrameResult.outOfDate, now());
                    if (cfg.native.debugging.traceFrames
                        || (traceFrames && took >= traceOver))
                        note(i"native frame: the swapchain is stale at $((started - opened).total!"msecs") ms, $(session.pixelW)x$(session.pixelH): acquire $(timing.acquired), present $(timing.presented), rebuild $(timing.rebuild.total!"usecs") us");
                    break;
                case FrameOutcome.deviceLost:
                    trace(i"native arm: the device was lost");
                    lc.frameDone(FrameResult.deviceLost, now());
                    break;
                case FrameOutcome.failed:
                    lc.frameDone(FrameResult.failed, now());
                    break;
            }
            // A record took the pass's times, its rebuild's included: the next
            // pass starts from none.
            if (recordMade)
                timing = FrameTiming.init;
            // X11 presents unpaced, so a continuously drawing run must read
            // its events between frames, or input, a close and its own resizes
            // wait until a frame fails.
            if ((outcome != FrameOutcome.presented || !paced) && !pollNow())
                break;
            continue;
        }

        // A frame waits for its opportunity: ask for one where the window
        // system gives them only on request (Android).
        static if (__traits(hasMember, Wsi, "requestFrame"))
            if (plan.askFrame)
                cast(void) wsi.requestFrame(window);

        // Park until the window system has something, or the application's
        // next deadline.
        Duration timeout = plan.park < 1.seconds ? plan.park : 1.seconds;
        if (host.wakeAsk != Duration.max)
        {
            const since = MonoTime.currTime - lastPass;
            const left = host.wakeAsk > since ? host.wakeAsk - since : Duration.zero;
            if (left < timeout)
                timeout = left;
        }
        // A gesture in flight is ticked at the display's rate until it rests;
        // a title face being looked up is checked as often.
        if ((input.gesturing || session.nextTitlePattern.length || session.nextUi !is null)
                && timeout > gestureTick)
            timeout = gestureTick;
        if (cfg.idleTimeoutMs >= 0 && cfg.idleTimeoutMs.msecs < timeout)
            timeout = cfg.idleTimeoutMs.msecs;
        const parkedAt = MonoTime.currTime;
        if (wsi.runIntegratedOnce(loop, timeout).hasError)
            break;
        drainEvents();
        if (session.nextTitlePattern.length && session.nextTitleFace.settled)
            lc.exposed(); // the frame takes the new face
        // An interface face the desktop changed to, once found: bound with
        // the cell font's rules, and laid out again by the next frame.
        if (adoptInterfaceFace(session))
        {
            bindInterfaceFace();
            lc.exposed();
        }
        // A wake with nothing to draw is still a frame pass for an
        // application that asked to be woken (`HST16`), or for an idle
        // timeout.
        if ((host.wakeAsk != Duration.max && MonoTime.currTime - lastPass >= host.wakeAsk)
            || (cfg.idleTimeoutMs >= 0 && MonoTime.currTime - parkedAt >= cfg.idleTimeoutMs.msecs))
        {
            lc.input();
            lastPass = MonoTime.currTime;
        }
    }
    return ok;
}

// The longest title the window is given, in bytes.
private enum size_t maxTitleBytes = 4096;

// How often a gesture in flight is ticked while nothing else arrives.
private enum gestureTick = 16.msecs;

// How long a surface's release waits for the frames still in flight: under
// the 2 s Android allows before taking the window back.
private enum surfaceReleaseWait = 1500.msecs;

// The recogniser's thresholds are physical, so they follow the cell: a
// pinch or a font-size change moves it, as on the raylib arm.
private void configureGestures(ref WsiInput input, in CellFont font) @safe pure nothrow @nogc
{
    const slop = font.cellH / 2.0f;
    input.gestures.cfg.slopPx = slop > 8 ? slop : 8;
    input.gestures.cfg.cellH = font.cellH;
    input.gestures.cfg.cellW = font.cellW;
    input.gestures.cfg.fractional = input.fractionalScroll;
}

// The loop's halves an application sees — input in, a frame's operations
// out — shared with `replayNative`, so the parity oracle runs this arm's own
// code rather than a copy of it.

// One window-system event, translated, to the application (`INT5`).
private void deliverInput(alias handle, Wsi)(ref NativeHost host, ref WsiInput input,
    ref Wsi wsi, in WindowEvent e, int unitW, int unitH, ref bool dirty)
{
    input.pointerCaptured = host.pointerCaptured;
    input.translate(wsi, e, unitW, unitH, (Event x) {
        handle(host, withRealSize(x, host.size));
        input.pointerCaptured = host.pointerCaptured;
        dirty = true;
    });
    if (!input.pointerCaptured && host.pointerCaptured)
        host.capturePointer(false);
}

// The end of a drain: whatever the translation held back, and the modifier
// level the batch left (`HST17`).
private void flushInput(alias handle)(ref NativeHost host, ref WsiInput input, ref bool dirty)
{
    input.pointerCaptured = host.pointerCaptured;
    input.endDrain((Event x) {
        handle(host, withRealSize(x, host.size));
        input.pointerCaptured = host.pointerCaptured;
        dirty = true;
    });
    if (!input.pointerCaptured && host.pointerCaptured)
        host.capturePointer(false);
    host.noteModifiers(input.modifiers);
}

// A frame's operations: the host's per-frame state reset, then the
// application's `present`.
private void buildFrame(alias present)(ref NativeHost host, bool mustDraw)
{
    host.beginFrameState(mustDraw: mustDraw);
    declareFaces(host);
    present(host);
}

// The target declares `proportionalText` while the canvas draws the
// interface face (`GLY10`, `CAP1`): it follows a rebinding — a font size,
// a scale, a rebuilt device — from the next frame on.
private void declareFaces(ref NativeHost host) @safe pure nothrow @nogc
{
    auto declared = host.declaredTarget;
    declared.proportionalText = host.session_.uiFaceBound;
    host.declareTarget(declared);
}

@("ui_app.native_loop.declaresProportionalTextWhileTheFaceIsBound")
@system pure nothrow @nogc
unittest
{
    NativeSession session;
    NativeHost host;
    host.session_ = &session;
    declareFaces(host);
    assert(!host.target.proportionalText, "no interface face: interface runs in the cells");
    session.uiFaceBound = true;
    declareFaces(host);
    assert(host.target.proportionalText);
    assert(host.target.colorDepth == host.declaredTarget.colorDepth, "the rest kept");
}

/**
The native arm without a window or a device: each batch of `script` drained
the way the loop drains one — through this arm's translation into `handle` —
and a frame built after it, as the recording host builds one per event. The
live half of the parity oracle (`TST3`): `onFrame` sees every frame's
operations while they are still valid, before the next frame reuses them.

`session` supplies the surface, the cell font and, for an application that
draws images, the canvas; delegates it leaves unset accept and drop the
errand. `texts` answers `withText` for the script's text ids.
*/
void replayNative(alias present, alias handle, Texts)(ref NativeSession session,
    in RunConfig cfg, ref Texts texts, in WindowEvent[][] script,
    scope void delegate(in DrawOp[] ops, bool skipped) @system onFrame) @system
{
    if (session.setCursor is null)
        session.setCursor = (PointerShape) {};
    if (session.setClipboard is null)
        session.setClipboard = (scope const(char)[]) {};
    if (session.setFontSize is null)
        session.setFontSize = (int) {};
    if (session.setTextInput is null)
        session.setTextInput = (bool) {};

    NativeHost host;
    host.session_ = &session;
    host.capabilities.keyRelease = cfg.keyRelease;
    WsiInput input;
    host.input_ = &input;
    input.capabilities = host.capabilities;
    input.fractionalScroll = cfg.fractionalScroll;
    input.scale = session.scale;
    const unitW = cfg.pointerUnit == PointerUnit.pixels ? 1 : session.font.cellW;
    const unitH = cfg.pointerUnit == PointerUnit.pixels ? 1 : session.font.cellH;

    void frame(bool first)
    {
        buildFrame!present(host, first);
        onFrame(host.ops()[], host.frameSkipped);
    }

    frame(true);
    foreach (batch; script)
    {
        if (host.quitRequested)
            break;
        bool dirty;
        foreach (e; batch)
            deliverInput!handle(host, input, texts, e, unitW, unitH, dirty);
        flushInput!handle(host, input, dirty);
        frame(false);
    }
}

private enum FrameOutcome
{
    presented, /// drawn and presented
    again,     /// presented the ground instead; draw another frame
    rebuild,   /// the swapchain is out of date: rebuild it and draw again
    deviceLost, ///
    failed,    ///
}

// The window's ground, inside the frame's margin, in device pixels from the
// surface's corner.
private void fillWindowGround(C)(ref C canvas, ref NativeSession session, RgbColor ground) @system
{
    const m = session.margin;
    canvas.pushOffsetPx(-session.insets.left, -session.insets.top);
    scope (exit)
        canvas.popOffsetPx();
    canvas.fillPx(m, m, session.pixelW - 2 * m, session.pixelH - 2 * m, rgba(ground, 255));
}

// The client frame in device pixels from the surface's corner: the canvas's
// pixel calls start at the content's origin, which the bar moved down.
private void drawClientFrame(C)(ref C canvas, ref NativeSession session, RgbColor ground) @system
{
    const density = cast(float) session.scale;
    const geometry = FrameGeometry(surfaceW: session.pixelW, surfaceH: session.pixelH,
        top: session.insets.top - session.frame.barPx(density), cellW: session.font.cellW,
        cellH: session.font.cellH, density: density, margin: session.margin);
    auto colours = FrameColours.of(session.framePalette, ground);
    colours.highContrast = session.frameHighContrast;
    FrameShape[ClientFrame.maxShapes] shapes;
    const n = session.frame.build(shapes[], geometry, colours);
    canvas.pushOffsetPx(-session.insets.left, -session.insets.top);
    scope (exit)
        canvas.popOffsetPx();
    foreach (ref s; shapes[0 .. n])
    {
        final switch (s.kind)
        {
            case FrameShape.Kind.fill:
                canvas.fillPx(s.x, s.y, s.w, s.h, rgba(s.colour, s.alpha));
                break;
            case FrameShape.Kind.disc:
                canvas.roundedPx(s.x, s.y, s.w, s.h, s.w / 2.0f, rgba(s.colour, s.alpha));
                break;
            case FrameShape.Kind.shadow:
                canvas.shadowPx(s.x, s.y, s.w, s.h, s.radius, s.blur, s.spread,
                    rgba(s.colour, s.alpha));
                break;
            case FrameShape.Kind.erase:
                canvas.eraseOutsidePx(s.x, s.y, s.w, s.h, s.radius);
                break;
            case FrameShape.Kind.cross:
                foreach (y; 0 .. s.h)
                    foreach (x; 0 .. s.w)
                        if (const cover = crossCoverage(s.w, x, y))
                            canvas.fillPx(s.x + x, s.y + y, 1, 1,
                                rgba(s.colour, cast(ubyte)(cover * s.alpha / 255)));
                break;
        }
    }
    // The title in the desktop's title face at its fixed size, set again
    // only when the text, the room or the density changes.
    // A face the desktop changed to, once found: never waited for here.
    if (session.nextTitlePattern.length && session.nextTitleFace.settled)
    {
        import core.lifetime : move;

        session.nextTitleFace.load(session.nextTitlePattern);
        session.titleFace = move(session.nextTitleFace);
        session.titlePattern = session.nextTitlePattern;
        session.titleCss = session.nextTitleCss;
        session.titleStrip = TitleStrip.init;
        session.nextTitlePattern = null;
    }
    session.titleFace.load(session.titlePattern);
    const ppem = cast(int)(session.titleCss * density + 0.5f);
    if (session.titleFace.set(session.titleStrip, session.title,
            session.frame.titleRoom(geometry), ppem) && session.titleStrip.width > 0)
    {
        const strip = &session.titleStrip;
        const t = session.frame.titleAt(strip.width, strip.height, geometry, colours);
        // A run of equal coverage is one fill: a stem is a few, not a
        // pixel each.
        foreach (y; 0 .. strip.height)
        {
            const row = strip.coverage[size_t(y) * strip.width .. size_t(y + 1) * strip.width];
            for (int x = 0; x < strip.width;)
            {
                const cover = row[x];
                int end = x + 1;
                while (end < strip.width && row[end] == cover)
                    ++end;
                if (cover)
                    canvas.fillPx(t.x + x, t.y + y, end - x, 1,
                        rgba(t.colour, cast(ubyte)(cover * t.alpha / 255)));
                x = end;
            }
        }
    }
}

// Where a frame's time went, for `--debug trace-frames`.
private struct FrameTiming
{
    /// Time the device's work too (`GpuProfiler`).
    bool traced;
    /// The device's time for the frame drawn `framesInFlight` before.
    Duration gpu;
    /// That frame's device scopes, read when its slot came round again.
    FrameRecord late;
    Duration rebuild, build, wait, acquire, record, present;
    /// The rebuild's parts: the wait for frames in flight, the canvas's
    /// targets released, the swapchain, its views, the frames' sync.
    Duration settle, release, swapchain, views, sync;
    VkResult acquired, presented; /// what each call said, for a stale frame
    uint slot; /// the frame slot it was drawn in, whose device time `gpu` is
    bool collected; /// the slot's previous frame was read (into `late`)
    bool submitted; /// the frame's commands were submitted
    bool shown;     /// and presented without an error
}

// Acquires an image, draws the host's operations and the draw phase into it,
// and presents it.
private FrameOutcome drawFrame(alias draw)(ref Gpu gpu, ref NativeHost host,
    ref NativeSession session, RgbColor ground, ref FrameTiming timing,
    scope void delegate() @system beforePresent) @system
{
    import sparkles.ui.interp.immediate : paint;

    auto vk = &gpu.vk;
    auto mark = MonoTime.currTime;
    Duration lap()
    {
        const at = MonoTime.currTime, since = at - mark;
        mark = at;
        return since;
    }
    // Tracy's zone for each lapped phase, ended however the frame ends.
    auto zone = tracyZone!"wait";
    if (gpu.sync.waitForFrame(*vk).hasError)
        return FrameOutcome.deviceLost;
    timing.wait = lap();
    zone.next!"acquire";
    if (timing.traced && !gpu.profilerTried)
    {
        gpu.profilerTried = true;
        cast(void) GpuProfiler.create(gpu.profiler, *vk, gpu.sync.framesInFlight);
    }
    timing.late = FrameRecord.init;
    gpu.profiler.collect(*vk, gpu.sync.frame, timing.late, gpu.clock);
    timing.gpu = timing.late.gpu;
    timing.slot = gpu.sync.frame;
    timing.collected = true;
    // Reading the queries is the profiler's cost, not the acquire's.
    mark = MonoTime.currTime;
    uint index;
    const acquired = vk.device.acquireNextImageKHR(vk.device.device, gpu.swapchain.handle,
        ulong.max, gpu.sync.imageAvailable, null, &index);
    timing.acquire = lap();
    zone.next!"record";
    timing.acquired = acquired;
    const decision = decideAcquire(acquired);
    if (decision.failed)
        return acquired == VkResult.VK_ERROR_DEVICE_LOST ? FrameOutcome.deviceLost
            : FrameOutcome.failed;
    if (!decision.proceed)
        return decision.recreate ? FrameOutcome.rebuild : FrameOutcome.again;
    if (gpu.sync.waitForImage(*vk, index).hasError || gpu.sync.beginFrame(*vk, index).hasError)
        return FrameOutcome.deviceLost;
    auto begun = gpu.commands.begin(*vk, gpu.sync.frame);
    if (begun.hasError)
        return FrameOutcome.deviceLost;
    auto cmd = begun.value;
    // The frame's commands, and the canvas's inside them; reset outside any
    // render pass.
    gpu.profiler.beginFrame(*vk, cmd, gpu.sync.frame);
    // Not submitted, its queries were never reset: they are not read as new.
    const slot = gpu.sync.frame;
    scope (exit)
        if (!timing.submitted)
            gpu.profiler.abandon(slot);
    gpu.profiler.begin(*vk, cmd, gpu.sync.frame, gpu.profiler.name("frame"));
    gpu.profiler.begin(*vk, cmd, gpu.sync.frame, gpu.profiler.name("canvas"));

    VkImage image = gpu.swapchain.images[index];
    const corner = cornerOf(gpu.swapchain.extent, session.pixelW, session.pixelH,
        quarterTurns(gpu.swapchain.transform));
    gpu.canvas.beginFrame(CanvasTarget(image: image, view: gpu.views.views[index],
        format: gpu.swapchain.format, extent: gpu.swapchain.extent, usage: gpu.swapchain.usage,
        finalLayout: VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        turn: quarterTurns(gpu.swapchain.transform), transparent: session.transparent,
        drawn: corner), cmd,
        gpu.sync.frame,
        FrameMetrics(cellW: session.font.cellW, cellH: session.font.cellH,
            originX: session.insets.left, originY: session.insets.top,
            density: cast(float) session.scale), ground);
    // On a transparent surface the window's ground is laid first, inside
    // the margin; the content draws over it, the frame's shadow beyond it.
    if (session.transparent)
        fillWindowGround(gpu.canvas, session, ground);
    {
        auto paintZone = cpuZone!"paint";
        // Interface runs in their face while the target draws it (`UVK20`).
        gpu.canvas.interfaceFaces(host.target.proportionalText);
        paint(gpu.canvas, host.ops()[]);
    }
    {
        auto drawZone = cpuZone!"app-draw";
        draw(host);
    }
    // The client frame last, over everything, in the bar's rows above the
    // cells (`F13`).
    if (session.frame.active)
        drawClientFrame(gpu.canvas, session, ground);
    auto endZone = cpuZone!"end-frame";
    auto ended = gpu.canvas.endFrame();
    endZone.destroy();
    gpu.profiler.end(*vk, cmd, gpu.sync.frame);
    FrameOutcome outcome = FrameOutcome.presented;
    if (ended.hasError)
    {
        if (ended.error == VkResult.VK_ERROR_DEVICE_LOST)
            return FrameOutcome.deviceLost;
        // Abandoned: the acquired image still has to be presented, so it
        // shows the ground, and the next frame draws again.
        clearTo(gpu, cmd, image, ground, session.transparent);
        outcome = FrameOutcome.again;
    }
    VkBuffer shot;
    GpuBuffer shotBuffer;
    if (session.shotPath.length && outcome == FrameOutcome.presented
        && (gpu.swapchain.usage & VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT))
        recordCapture(gpu, cmd, image, corner.width ? corner : gpu.swapchain.extent, shotBuffer);
    gpu.profiler.end(*vk, cmd, gpu.sync.frame);
    if (gpu.commands.end(*vk, gpu.sync.frame).hasError)
        return FrameOutcome.deviceLost;
    const submitted = gpu.sync.submit(*vk, cmd, index);
    if (submitted.hasError)
        return submitted.error == VkResult.VK_ERROR_DEVICE_LOST ? FrameOutcome.deviceLost
            : FrameOutcome.failed;
    timing.submitted = true;
    timing.record = lap();
    zone.next!"present";
    beforePresent();
    const presentId = gpu.waitPresents ? gpu.presentWait.idFor(gpu.presentTag) : 0;
    const timingId = gpu.tagPresents && vk.displayTiming ? DisplayTimes.idFor(gpu.presentTag) : 0;
    const presented = gpu.swapchain.present(*vk, index, gpu.sync.renderFinished(index), presentId,
        timingId);
    if (!presented.hasError && presentId)
        gpu.presentWait.submitted(gpu.swapchain.handle, presentId);
    if (!presented.hasError) gpu.sync.notePresent(index);
    timing.shown = !presented.hasError;
    timing.present = lap();
    zone.end();
    timing.presented = presented.hasError ? presented.error : presented.value;
    gpu.sync.advance();
    if (shotBuffer.handle !is null)
    {
        writeCapture(gpu, shotBuffer, corner.width ? corner : gpu.swapchain.extent,
            session.shotPath);
        session.shotPath = null;
    }
    if (presented.hasError)
        return Swapchain.needsRecreation(presented.error) ? FrameOutcome.rebuild
            : presented.error == VkResult.VK_ERROR_DEVICE_LOST ? FrameOutcome.deviceLost
            : FrameOutcome.failed;
    if (Swapchain.needsRecreation(presented.value) || decision.recreate)
        return FrameOutcome.rebuild;
    return outcome;
}

/*
The swapchain a resize grows into once the window outgrows the last one: half
as large again (at least 256 px more) on each side, and at least the output's
work area as the compositor bounds the window, with the client frame's
margin, so a drag within one output needs one swapchain, not one per step.
Whole 64-pixel units.
*/
private PhysicalSize roomFor(PhysicalSize window, in WindowState state, double scale,
    in PhysicalInsets margin) @safe pure nothrow @nogc
{
    static uint up(uint side) => (side + 63) & ~63u;
    static uint grown(uint side) => up(side + max(side / 2, 256u));
    if (!(scale > 0))
        scale = 1;
    uint bounded(uint bound, uint edges) => bound ? up(cast(uint)(bound * scale + 0.5) + edges) : 0;
    return PhysicalSize(
        max(grown(window.width), bounded(state.boundsWidth, margin.left + margin.right)),
        max(grown(window.height), bounded(state.boundsHeight, margin.top + margin.bottom)));
}

@("ui_app.native_loop.roomForAResize")
@safe pure nothrow @nogc unittest
{
    WindowState s;
    assert(roomFor(PhysicalSize(740, 720), s, 1, PhysicalInsets.init) == PhysicalSize(1152, 1088),
        "half again, in 64-pixel units");
    assert(roomFor(PhysicalSize(100, 100), s, 1, PhysicalInsets.init) == PhysicalSize(384, 384),
        "at least 256 more");
    s.boundsWidth = 2560;
    s.boundsHeight = 1371;
    assert(roomFor(PhysicalSize(740, 720), s, 1, PhysicalInsets(20, 20, 20, 20))
        == PhysicalSize(2624, 1472), "the work area and the margin");
    assert(roomFor(PhysicalSize(740, 720), s, 2, PhysicalInsets.init) == PhysicalSize(5120, 2752),
        "bounds are logical");
    assert(roomFor(PhysicalSize(4000, 720), s, 1, PhysicalInsets.init).width == 6016,
        "past the output: half again");
}

/*
The window's corner of a swapchain image kept larger than the window through
a resize, in image pixels: what a frame draws, the compositor shows and a
screenshot keeps. Empty when the image is drawn and shown whole: the
window's size, turned (Android, never kept larger), or smaller on either
side (a driver's cap), where a crop past the buffer is a protocol error.
*/
private VkExtent2D cornerOf(VkExtent2D image, uint windowW, uint windowH, uint turns)
    @safe pure nothrow @nogc
{
    if (turns % 4 || windowW == 0 || windowH == 0 || windowW > image.width
        || windowH > image.height || (windowW == image.width && windowH == image.height))
        return VkExtent2D.init;
    return VkExtent2D(windowW, windowH);
}

@("ui_app.native_loop.cornerOfAKeptSwapchain")
@safe pure nothrow @nogc unittest
{
    assert(cornerOf(VkExtent2D(1200, 900), 800, 600, 0) == VkExtent2D(800, 600));
    assert(cornerOf(VkExtent2D(800, 600), 800, 600, 0) == VkExtent2D.init, "the window's size");
    assert(cornerOf(VkExtent2D(40, 80), 80, 40, 1) == VkExtent2D.init, "turned: whole");
    assert(cornerOf(VkExtent2D(1200, 900), 800, 600, 2) == VkExtent2D.init);
    assert(cornerOf(VkExtent2D(8192, 900), 10_000, 600, 0) == VkExtent2D.init,
        "a capped image is shown whole, never cropped past its edge");
    assert(cornerOf(VkExtent2D(1200, 900), 0, 600, 0) == VkExtent2D.init);
}

// The quarter turns a pre-rotated swapchain's images take on their way to the
// display (Android with the panel turned): the canvas draws into them turned.
private uint quarterTurns(VkSurfaceTransformFlagBitsKHR transform) @safe pure nothrow @nogc
{
    with (VkSurfaceTransformFlagBitsKHR) switch (transform)
    {
        case VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR: return 1;
        case VK_SURFACE_TRANSFORM_ROTATE_180_BIT_KHR: return 2;
        case VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR: return 3;
        default: return 0;
    }
}

// The acquired image cleared to `ground` and made presentable, for a frame
// the canvas abandoned.
private void clearTo(ref Gpu gpu, VkCommandBuffer cmd, VkImage image, RgbColor ground,
    bool transparent = false) @system
{
    auto device = &gpu.vk.device;
    transition(*device, cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
        VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT);
    VkClearColorValue colour;
    // A transparent surface shows nothing rather than a ground over its
    // shadow's margin.
    colour.float32 = transparent ? [0.0f, 0, 0, 0]
        : [ground.r / 255.0f, ground.g / 255.0f, ground.b / 255.0f, 1];
    auto range = colourRange;
    device.cmdClearColorImage(cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        &colour, 1, &range);
    transition(*device, cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0);
}

// Copies the frame's `extent` of the presentable image, from its top-left
// corner, into a host-visible buffer, after the frame drew it and before it
// is presented.
private void recordCapture(ref Gpu gpu, VkCommandBuffer cmd, VkImage image, VkExtent2D extent,
    out GpuBuffer buffer) @system
{
    auto device = &gpu.vk.device;
    if (GpuBuffer.create(buffer, *device, gpu.memory, ulong(extent.width) * extent.height * 4,
            VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
            | VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT).hasError)
        return;
    transition(*device, cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        VkAccessFlagBits.VK_ACCESS_TRANSFER_READ_BIT);
    VkBufferImageCopy region;
    region.imageSubresource = VkImageSubresourceLayers(
        aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT, layerCount: 1);
    region.imageExtent = VkExtent3D(extent.width, extent.height, 1);
    device.cmdCopyImageToBuffer(cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        buffer.handle, 1, &region);
    transition(*device, cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0);
}

// Waits for the captured frame and writes it as a PNG, in RGBA order.
private void writeCapture(ref Gpu gpu, ref GpuBuffer buffer, VkExtent2D extent,
    string path) @system
{
    import std.file : write;
    import sparkles.image.png : encodePng;

    scope (exit)
        buffer.destroy(gpu.vk.device, gpu.memory);
    gpu.vk.device.queueWaitIdle(gpu.vk.queue);
    auto pixels = buffer.region.host[0 .. size_t(extent.width) * extent.height * 4].dup;
    with (VkFormat) if (gpu.swapchain.format == VK_FORMAT_B8G8R8A8_UNORM
        || gpu.swapchain.format == VK_FORMAT_B8G8R8A8_SRGB)
        for (size_t i = 0; i < pixels.length; i += 4)
        {
            const b = pixels[i];
            pixels[i] = pixels[i + 2];
            pixels[i + 2] = b;
        }
    write(path, encodePng(pixels, extent.width, extent.height));
}

// A template arm is analysed only where it is instantiated: without this the
// whole native loop could be broken and the package's tests still pass.
@("ui_app.native_loop.instantiates")
@system unittest
{
    import sparkles.ui.canvas : DrawOp;

    cast(void) &runNative!((ref NativeHost h) { h.ops() ~= DrawOp.init; },
        (ref NativeHost h, in Event e) { h.quit(); });
    static void typeCheck(ref NativeHost h)
    {
        h.pointerShape(PointerShape.grab);
        h.clipboard("copied");
        h.screenshot("frame.png");
        h.fontSize(h.fontSizePx + 2);
        h.textInput(true);
        const contacts = h.touches.count + h.insets.bottom;
        auto c = h.canvas;
    }
}

@("ui_app.native_loop.measuresTheCellFont")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    CellFont font;
    if (!measureCellFont(FontRequest.init, null, 18, font))
        return skipTest("no monospace font resolves on this machine");
    assert(font.px == 18 && font.cellW > 1 && font.cellH > font.cellW,
        "a monospace cell is narrower than it is tall");
    CellFont larger;
    assert(measureCellFont(FontRequest.init, null, 36, larger));
    assert(larger.cellH > font.cellH && larger.cellW > font.cellW);
}

@("ui_app.native_loop.cellMetricsAreTheMeasuredFont")
@safe pure nothrow @nogc unittest
{
    NativeSession session;
    session.font = CellFont(null, 18, 9, 18);
    NativeHost host;
    host.session_ = &session;
    assert(host.cellWidth == 9 && host.cellHeight == 18);
}

// The parity oracle (`TST3`, plan slice V4's gate): the same input, scripted
// as window-system events for this arm and as `sparkles:input` events for the
// recorder, produces the same operations frame for frame. The component shows
// every event it sees and the modifier level, so a translation that loses or
// reshapes one changes the display list.
@("ui_app.native_loop.sameScriptSameOperationsAsTheRecorder")
@system unittest
{
    import std.conv : text;
    import sparkles.input : charEvent, Key, KeyAction, KeyEvent, keyEvent, Mods,
        Point, PointerAction, PointerButton, PointerEvent, WheelEvent;
    import sparkles.ui.canvas : DrawOp;
    import sparkles.ui.style : Slot;
    import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : appThemeOf, FrameSnapshot, presentApp, runAppRecorded;
    import sparkles.wsi.events : KeyboardEvent, LogicalKey, LogicalKeyKind, PhysicalKey,
        PointerPhase, ScrollEvent, TextCommittedEvent, TextId, WindowEventPayload;
    import sparkles.wsi.types : PhysicalPosition, WindowId;

    static struct Echo
    {
        string[] seen;

        WidgetTree view(H)(ref H h)
        {
            auto b = Builder();
            uint[] lines;
            foreach (line; seen ~ text("mods ", h.modifiers, " size ", h.size))
                lines ~= b.add(Widget(kind: WidgetKind.text, text: line, slot: Slot.code));
            return b.finish(b.container(WidgetKind.column, lines));
        }

        void handle(H)(ref H h, in Event e)
        {
            seen ~= text(e);
        }
    }

    // ── the script, as each arm receives it ──
    WindowEvent ev(P)(P payload)
    {
        WindowEvent e;
        e.window = WindowId(0, 1);
        e.payload = WindowEventPayload(payload);
        return e;
    }
    KeyboardEvent key(LogicalKeyKind kind, uint value, Mods mods = Mods.init)
        => KeyboardEvent(PhysicalKey.init, LogicalKey(kind, value, value),
            action: KeyAction.press, modifiers: mods);
    auto pointer(PointerPhase phase, int x, int y, PointerButton button)
    {
        sparkles.wsi.events.PointerEvent p;
        p.phase = phase;
        p.button = button;
        p.physicalPosition = PhysicalPosition(x, y);
        return p;
    }
    ScrollEvent notch;
    notch.physicalPosition = PhysicalPosition(15, 25);
    notch.discreteY = 1;
    notch.dx = 0;
    notch.dy = 15;
    const ctrl = Mods(ctrl: true);

    static struct Texts
    {
        string[] texts;
        auto withText(Fn)(TextId id, scope Fn fn)
        {
            import sparkles.wsi.types : wsiOk;

            fn(texts[id.index], false);
            return wsiOk();
        }
    }
    auto texts = Texts(["a", "\x03"]);

    const WindowEvent[][] native = [
        [ev(key(LogicalKeyKind.named, 0xFF52))],                             // Up
        [ev(key(LogicalKeyKind.character, 'a')), ev(TextCommittedEvent(TextId(0, 1)))],
        [ev(pointer(PointerPhase.pressed, 25, 45, PointerButton.left))],
        [ev(pointer(PointerPhase.released, 39, 61, PointerButton.left))],
        [ev(notch)],
        [ev(key(LogicalKeyKind.character, 'c', ctrl)), ev(TextCommittedEvent(TextId(1, 1)))],
    ];
    const Event[] recorded = [
        keyEvent(Key.up),
        charEvent('a'),
        Event(PointerEvent(action: PointerAction.press, button: PointerButton.left,
            pos: Point(2, 2))),
        Event(PointerEvent(action: PointerAction.release, button: PointerButton.left,
            pos: Point(3, 3))),
        Event(WheelEvent(dy: 3, pos: Point(1, 1), begins: true)),
        Event(KeyEvent(Key.char_, 'c', ctrl, KeyAction.press, 'c')),
    ];

    // ── the recorder, sized and described as the window is ──
    NativeSession session;
    session.pixelW = 800;
    session.pixelH = 480;
    session.font = CellFont(null, 18, 10, 20);
    auto recApp = Echo();
    auto rec = runAppRecorded(recApp, RunConfig.init, recorded, (ref RecordingHost h) {
        h.size = Size(80, 24);
        h.capabilities = mousePointer;
        h.backend = Backend.gui;
        h.frameSeconds = 0;
    });
    assert(rec.frames.length == recorded.length + 1);

    // ── this arm ──
    auto app = Echo();
    const th = appThemeOf(RunConfig.init.gui);
    FrameSnapshot snap;
    size_t frame;
    replayNative!((ref NativeHost h) => presentApp(app, h, th, snap),
        (ref NativeHost h, in Event e) => app.handle(h, e))(session, RunConfig.init, texts,
        native, (in DrawOp[] ops, bool skipped) {
            assert(frame < rec.frames.length, "a frame the recorder did not draw");
            assert(!skipped && !rec.frames[frame].skipped);
            assert(ops == rec.frames[frame].ops, text("frame ", frame, " differs"));
            ++frame;
        });
    assert(frame == rec.frames.length);
    assert(app.seen == recApp.seen && app.seen.length == recorded.length);
}

// The points a size of `px` pixels is at `scale`: `pixelsForPoints`
// inverted, before its rounding, so a size the user chose survives a
// scale change and back (`RES55`).
private double pointsForPixels(int px, double scale) @safe pure nothrow @nogc
{
    import sparkles.raylib_text.metrics_dpi : DisplayMetrics;

    const m = DisplayMetrics(scale: cast(float) scale);
    const s = m.scale < 1.0f ? 1.0f : (m.scale > m.maxScale ? m.maxScale : m.scale);
    return px * 72.0 / (m.dpi * s);
}

@("ui_app.native_loop.aChosenSizeSurvivesAScaleRoundTrip")
@safe pure nothrow @nogc unittest
{
    import sparkles.raylib_text.metrics_dpi : DisplayMetrics, pixelsForPoints;

    foreach (px; 6 .. 97)
        foreach (scale; [1.0, 1.25, 1.5, 2.0, 2.625])
            assert(pixelsForPoints(pointsForPixels(px, scale),
                DisplayMetrics(scale: cast(float) scale)) == px);
}

// `--debug frame-trace=PATH`: the history as a Chrome trace, said where it
// went or why it did not.
private void writeFrameTrace(in FrameHistory!4096 history, scope const(string)[] gpuNames,
    string path) @system
{
    import std.array : appender;
    import std.file : write;

    auto text = appender!string;
    writeChromeTrace(text, history[], gpuNames, "sparkles native window");
    try
    {
        write(path, text[]);
        note(i"native window frame trace: $(history.length) frames in $(path)");
    }
    catch (Exception e)
        whyNot(i"native window frame trace: $(path): $(e.msg)");
}
