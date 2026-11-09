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

import core.time : dur, Duration, MonoTime, msecs, nsecs, seconds, usecs;
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
import sparkles.ui_app.gui_options : defaultGuiFont, FontRequest, WindowCells, WindowSystem;
import sparkles.ui_app.interface_font : InterfaceMeasure, uiFontFamilyOf, uiStepSizes, xHeightRatio;
import sparkles.ui_app.host : HostState, isHost, noDraw, noSetup, noShutdown, PointerUnit,
    RunConfig, TouchGestures, withRealSize;
import sparkles.ui_app.lifecycle : Failure, FrameResult, Lifecycle, Rebuild, Surface;
import sparkles.ui_app.frame_title : fitTitle, TitleFace, titleCssPx, titleCssPxOf,
    titleFacePattern, titlePatternOf, TitleStrip;
import sparkles.ui_app.client_frame : ClientFrame, crossCoverage, FrameAction, FrameColours,
    FrameGeometry, FrameHit, FramePart, FrameShape;
import sparkles.ui_app.wsi_input : TouchContacts, WsiInput;
import sparkles.event_horizon.stream_ingest : StreamId, StreamIngest, StreamSink;
import sparkles.ui_app.frame_schedule : FrameSchedule, FrameSchedulePolicy;
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
    /// The face's index in its file, and its styled siblings' (bold, italic,
    /// bold-italic): non-zero where the family lives in a collection, as
    /// macOS's Menlo does.
    uint index;
    uint[3] styleIndices; /// ditto
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
    // Directories the application supplies are where its faces are, as on the
    // raylib arm (`openGuiSession`); and Android has no font database, only
    // `/system/fonts`.
    sources.useSystemFontDb = request.useSystemFontDb && extraSources.length == 0;
    version (Android)
    {
        sources.dirs ~= "/system/fonts";
        sources.useSystemFontDb = false;
    }
    string path = loaded !is null ? loaded.path : resolveFontPath(request.family, sources);
    // A family the resolver cannot offer the raylib arm, as it lives only in
    // a collection: its members, opened by index.
    import sparkles.ui_app.collection_face : FaceAt;

    FaceAt[4] inCollection;
    version (OSX)
    {
        import sparkles.ui_app.collection_face : collectionFamily;

        if (loaded is null && !path.length && sources.useSystemFontDb
            && collectionFamily(request.family, (string p) => mappedFont(p), inCollection))
            path = inCollection[0].path;
    }
    if (path.length == 0)
        return false;
    const index = loaded !is null ? loaded.index : inCollection[0].index;
    const bytes = loaded !is null ? loaded.bytes
        : inCollection[0].path.length ? mappedFont(path) : cast(const(ubyte)[]) read(path);
    auto face = openFace(bytes, index);
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
    const hh = hhea(face.value);
    const span = hh.hasValue ? long(hh.value.ascender) - hh.value.descender : 0;
    const upem = face.value.unitsPerEm;
    // The cell is the line the size names, `px` tall, with its baseline where
    // the exact em puts the ascender (truncated, as stb_truetype places the
    // raylib arm's glyphs): FTM19's height and baseline at the whole em
    // round each half of the line separately, which left the cell from one
    // pixel short to two pixels tall against the raylib arm's grid. Without
    // `hhea`, FTM19's own.
    const cellH = span > 0 ? px : cast(int)(m.height < 1 ? 1 : m.height);
    const ascent = span > 0
        ? cast(int)(long(hh.value.ascender) * px / span)
        : cast(int) m.baseline;
    // Measured down from the cell's top (`FTM19`), so moved with the
    // baseline; without `post`, the underline a pixel under the baseline.
    // Kept inside the cell.
    const thickness = cast(int)(m.hasUnderline && m.underlineThickness > 0 ? m.underlineThickness : 1);
    int underlineY = m.hasUnderline
        ? cast(int) m.underlinePosition + ascent - cast(int) m.baseline
        : ascent + 1;
    if (underlineY + thickness > cellH)
        underlineY = cellH - thickness;
    // The family's styled faces, found as the raylib arm finds them without
    // fontconfig: by their sibling files.
    import sparkles.raylib_text.font_discovery : fontVariantPaths;

    string boldPath, italicPath, boldItalicPath;
    if (loaded is null && inCollection[0].path.length)
    {
        boldPath = inCollection[1].path;
        italicPath = inCollection[2].path;
        boldItalicPath = inCollection[3].path;
    }
    else if (loaded is null)
        fontVariantPaths(path, boldPath, italicPath, boldItalicPath);
    // A sibling in the regular face's own collection shares its bytes.
    const(ubyte)[] load(string p) => !p.length ? null : p == path ? bytes : mappedFont(p);
    // The cell is as wide as the glyphs drawn in it: FTM19's width (the
    // advance of `0`, rounded to nearest, ties to even) at the exact em the
    // glyphs draw at — px · upem / span, the raylib arm's
    // `ScaleForPixelHeight` — not at the whole em the line was measured at.
    // That em rounds the line's ascent and descent up and the em down (about
    // 5% at 18 px for a typical monospace face), which left every cell
    // narrower than its glyph and the text tighter than on the raylib arm.
    int cellW = cast(int)(m.width < 1 ? 1 : m.width);
    if (span > 0)
    {
        import sparkles.base.text.layout_units : Rational, signedWide, U128;
        import sparkles.font : advance;
        import std.math : rint;

        const exact = Ppem.fromRational(Rational(signedWide(long(px) * upem),
            U128(cast(ulong) span, 0)));
        const zero = cmap.value.glyph('0');
        if (exact.hasValue && zero != 0)
        {
            auto inst = instance(face.value, InstanceSize.pixels(exact.value), null);
            if (inst.hasValue)
            {
                const a = advance(inst.value, zero, *points);
                if (a.hasValue && a.value.pixels.hasValue)
                {
                    const w = rint(a.value.pixels.value); // ties to even
                    cellW = w < 1 ? 1 : cast(int) w;
                }
            }
        }
    }
    cell = CellFont(path, px, cellW, cellH, bytes,
        loaded !is null ? loaded.bold : load(boldPath),
        loaded !is null ? loaded.italic : load(italicPath),
        loaded !is null ? loaded.boldItalic : load(boldItalicPath),
        cast(uint)(em < 1 ? 1 : em),
        span > 0 ? ulong(px) * upem : cast(ulong)(em < 1 ? 1 : em), span > 0 ? cast(ulong) span : 1,
        ascent, underlineY, thickness,
        ascent - (em * 28 + 50) / 100); // about half the x-height
    cell.index = index;
    cell.styleIndices = loaded !is null ? loaded.styleIndices
        : [inCollection[1].index, inCollection[2].index, inCollection[3].index];
    // Icons, text the face lacks, and emoji, from the faces the raylib arm
    // falls back to.
    import sparkles.raylib_text.font_resolve : systemFallbackFacePaths;

    string nerdPath, regularPath, emojiPath;
    if (loaded is null)
        systemFallbackFacePaths(path, sources, nerdPath, regularPath, emojiPath);
    // The resolver skips Apple Color Emoji for the raylib arm, which cannot
    // open a collection; this arm's `sparkles:font` reads the collection's
    // first face and its `sbix` strikes.
    version (OSX)
    {
        import std.file : exists;

        enum appleEmoji = "/System/Library/Fonts/Apple Color Emoji.ttc";
        if (loaded is null && !emojiPath.length && sources.useSystemFontDb && appleEmoji.exists)
            emojiPath = appleEmoji;
    }
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
        sources.useSystemFontDb = request.font.useSystemFontDb && request.extraFontSources.length == 0;
        version (Android)
        {
            sources.dirs ~= "/system/fonts";
            sources.useSystemFontDb = false;
        }
        string regular, bold;
        bool resolved = resolveUiFace(family, sources, regular, bold);
        // The resolver skips collections, which the raylib arm cannot open,
        // and macOS keeps its interface faces in them; but its system face,
        // SF Pro, is a plain variable TrueType this arm's `sparkles:font`
        // reads. It is what `sans-serif` means there.
        version (OSX)
        {
            import std.algorithm.searching : endsWith;
            import std.file : exists;

            enum systemUi = "/System/Library/Fonts/SFNS.ttf";
            if (!resolved && family.endsWith("sans-serif") && sources.useSystemFontDb
                && systemUi.exists)
            {
                regular = systemUi;
                bold = null;
                resolved = true;
            }
        }
        if (!resolved)
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

/// A mixed-style rich run, laid out by the host's measurer over a real
/// canvas, painted through the display list and read back: each piece is
/// measured as the canvas draws it — kerned across its clusters, the next
/// piece starting where the measure ends it.
@("ui_app.native_loop.aMixedRunIsMeasuredAsItIsDrawn")
@system unittest
{
    import sparkles.ui_vulkan.testing : Canvas, readbackEnabled, readbackSkipReason, Rig;
    import sparkles.test_runner.skip : skipTest;

    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    import std.conv : text;
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.base.text.grapheme : byGraphemeCluster;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui.layout : layout;
    import sparkles.ui.pixel_geometry : cellsCeil;
    import sparkles.ui.style : FontRole, TextStyle, TypeStep;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;
    import sparkles.ui.wrap : spanPaintAdvance, TextSpan;

    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    const mono = cast(const(ubyte)[]) read(dir.buildPath("DejaVuSansMono.ttf"));
    const sans = cast(const(ubyte)[]) read(dir.buildPath("NotoSans.ttf"));
    enum width = 480, cellW = 11, cellH = 22;
    auto rig = new Rig;
    rig.open("ui-app-mixed-run", width, cellH);
    scope (success)
        rig.close();
    assert(rig.canvas.cellFont(mono, 18, TextMetrics(ascent: 16)));
    const int[4] steps = [20, 17, 18, 24];
    assert(rig.canvas.interfaceFont(sans, null, steps));

    // Two pieces, regular then bold, each full of kerned pairs.
    enum first = "AVAWAVATAVAWAVATAY", second = "TAVAWAY";
    const regular = TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.body);
    TextStyle bold = regular;
    bold.bold = true;
    auto faces = NativeFaces(&rig.canvas);
    double whole(string s, bool b) => rig.canvas.interfaceWidthPx(s, TypeStep.body, b);
    // The test discriminates: the clusters apart are over a cell wider.
    double apart = 0;
    foreach (c; byGraphemeCluster(first))
        apart += whole(c.slice.idup, false);
    assert(apart > whole(first, false) + cellW, text(apart, " vs ", whole(first, false)));

    auto m = InterfaceMeasure!NativeFaces(faces, true, cellW, cellH);
    auto b = Builder();
    const r = b.add(Widget(kind: WidgetKind.rich, textStyle: regular, spans: [
        TextSpan(first, textStyle: regular, fg: RgbColor(255, 0, 0), hasFg: true),
        TextSpan(second, textStyle: bold, fg: RgbColor(0, 255, 0), hasFg: true)]));
    auto tree = b.finish(r);
    auto frames = layout(tree, Constraints(width / cellW, 1), m);
    assert(frames[r].spanLines.length == 1, "one line");
    long[2] cells;
    foreach (ref span; frames[r].spanLines[0])
        cells[span.textStyle.bold] += spanPaintAdvance(span);
    assert(cells[0] == cellsCeil(cast(float) whole(first, false), cellW), text(cells));
    assert(cells[1] == cellsCeil(cast(float) whole(second, true), cellW), text(cells));

    auto ops = buildDisplayList(tree, frames, Palette.init, RgbColor(255, 255, 255),
        RgbColor(0, 0, 0), m);
    FrameReport report;
    VkResult failure;
    const frame = rig.draw((ref Canvas c) { paint(c, ops[]); },
        FrameMetrics(cellW: cellW, cellH: cellH), RgbColor(0, 0, 0), report, failure);
    // Where each piece's ink starts and ends, by its colour's channel.
    int[2][2] ink = [[int.max, 0], [int.max, 0]];
    foreach (y; 0 .. cellH)
        foreach (x; 0 .. width)
        {
            const p = frame[(y * width + x) * 4 .. (y * width + x) * 4 + 4];
            foreach (piece; 0 .. 2)
                if (p[piece] > 32 && p[1 - piece] < 16)
                {
                    ink[piece][0] = x < ink[piece][0] ? x : ink[piece][0];
                    ink[piece][1] = x + 1 > ink[piece][1] ? x + 1 : ink[piece][1];
                }
        }
    const seam = cast(int) cells[0] * cellW, end = cast(int)(cells[0] + cells[1]) * cellW;
    // Drawn as measured: each piece's ink fills its cells but the last
    // one's slack, and the bold piece starts at the measured seam.
    assert(ink[0][1] <= seam + 1 && seam - ink[0][1] < cellW + 2, text(ink, " seam ", seam));
    assert(ink[1][0] >= seam - 1 && ink[1][0] - seam < 4, text(ink, " seam ", seam));
    assert(ink[1][1] <= end + 1 && end - ink[1][1] < cellW + 2, text(ink, " end ", end));
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

/**
A font file's bytes, mapped read-only where the platform maps files (a face
outlives every frame, so the mapping is the process's), else read. Apple
Color Emoji is 190 MB: mapped, only the strikes a frame draws are paged in,
and from the system's own cache.
*/
private const(ubyte)[] mappedFont(string path) @system
{
    version (Posix)
    {
        import core.sys.posix.fcntl : open, O_RDONLY;
        import core.sys.posix.sys.mman : mmap, MAP_FAILED, MAP_PRIVATE, PROT_READ;
        import core.sys.posix.sys.stat : fstat, stat_t;
        import core.sys.posix.unistd : close;
        import std.string : toStringz;

        const fd = open(path.toStringz, O_RDONLY);
        if (fd >= 0)
        {
            scope (exit) close(fd);
            stat_t st;
            if (fstat(fd, &st) == 0 && st.st_size > 0)
            {
                auto at = mmap(null, cast(size_t) st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
                if (at != MAP_FAILED)
                    return (cast(const(ubyte)*) at)[0 .. cast(size_t) st.st_size];
            }
        }
    }
    import std.file : read;

    return cast(const(ubyte)[]) read(path);
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
    /// Shows or hides the window system's pointer; null where it cannot.
    void delegate(bool visible) @system setCursorVisible;
    /// The clock effects read as `uTime`, pinned (`pinEffectClock`); negative
    /// runs it live, from the first frame drawn.
    float pinnedEffectClock = -1;
    /// The registry effect brackets resolve against, bound on every frame's
    /// canvas — one remade after a lost device included.
    const(EffectRegistry)* effectRegistry;
    MonoTime effectEpoch; /// ditto — when the live clock started
    void delegate(scope const(char)[]) @system setClipboard; ///
    void delegate(uint request) @system readClipboard;       ///
    /// Takes the window full screen or back; null where the window
    /// system cannot.
    void delegate(bool on) @system setFullscreen;
    bool fullscreen; /// as last asked for, or as the window system reports
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

    /**
    Reads the clipboard for request `request` (`INP25`): the text streams
    from the window system, and arrives after a later drain as `PasteEvent`s
    carrying `request` — one empty paste when the clipboard holds no text.
    */
    void readClipboard(uint request) @system => session_.readClipboard(request);

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

    /**
    Binds the effect registry the canvas resolves a bracket's id against
    (`EFX11`, `EFX13`): a bracket, nested or not, whose record carries passes
    for the device runs them (`UVK15`), the CRT's included; any other
    draws its contents unaffected (`EFX3`). `pageFg` is unused — the canvas
    paints resolved colours — and accepted so an application binds its
    registry the same on every arm.
    */
    void effects(const(EffectRegistry)* registry, RgbColor pageFg) @safe pure nothrow @nogc
    {
        session_.effectRegistry = registry;
    }

    /**
    Pins the clock every effect's `uTime` reads to `seconds`, for the rest of
    the run; a negative value runs it live again (`DBG1`). A capture pins it,
    so an animated effect — the CRT's roll and flicker — is at the same phase
    in every run.
    */
    void pinEffectClock(float seconds) @safe pure nothrow @nogc
    {
        session_.pinnedEffectClock = seconds;
    }

    /**
    Shows or hides the window system's pointer over the window (`PTR1`): an
    effect that draws its own pointer hides it. A window system that cannot
    hide it keeps it.
    */
    void pointerVisible(bool visible) @system
    {
        if (session_.setCursorVisible !is null)
            session_.setCursorVisible(visible);
    }

    /// A window has no out-of-band channel.
    void writeOutOfBand(scope const(char)[]) @safe pure nothrow @nogc {}

    /// Whether the window system can take the window full screen.
    bool fullscreenSupported() const @system => session_.setFullscreen !is null;
    /// Takes the window full screen, or back; the size that results
    /// arrives as a resize.
    void toggleFullscreen() @system
    {
        if (session_.setFullscreen !is null)
            session_.setFullscreen(!session_.fullscreen);
    }

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

    /**
    Asks for a frame pass as soon as `fd` turns readable (`HST15`'s polled
    form): the component that drains a descriptor in its frame — a terminal
    pane's pty — asks again each pass it is still reading, and the loop parks
    a readiness poll on it beside the window system's own. Without it such a
    component reads only when something else wakes the loop, which a reader
    faster than its writer turns into a stall.

    The ask lasts one pass: a descriptor not asked for again is let go, so a
    closed one is never watched. `false` where this run cannot watch it (no
    loop, every slot taken): the component's next wake is then its own.
    */
    bool wakeWhenReadable(int fd) @system nothrow @nogc
        => readable_ !is null && readable_.want(fd);

    private ReadableWakes* readable_;

    /**
    Reads `fd` as a stream source (output-latency.md `OPL1`–`OPL9`): its
    bytes reach `sink` as they arrive, between frames, and each delivery
    makes a frame pass due. `fd` must be non-blocking. `StreamId.init` where
    this run cannot read it: the component keeps its polled path.
    */
    StreamId openStream(int fd, StreamSink sink) @system nothrow @nogc
        => ingest_ is null ? StreamId.init : ingest_.open(fd, sink);

    /// Closes a stream source: its sink hears nothing after this (`OPL9`).
    void closeStream(StreamId id) @system nothrow @nogc
    {
        if (ingest_ !is null)
            ingest_.close(id);
    }

    /// Delivers a source's held bytes now, reading nothing (`OPL7`).
    void flushStream(StreamId id) @system nothrow @nogc
    {
        if (ingest_ !is null)
            ingest_.flush(id);
    }

    /// Every byte delivered to stream sinks so far (`OPL25`).
    ulong streamPosition() const @safe pure nothrow @nogc
        => ingest_ is null ? 0 : ingest_.position;

    private StreamIngest* ingest_;
}

/**
The readiness polls behind `NativeHost.wakeWhenReadable`: one one-shot poll
per descriptor at a time, on the loop the window system's events arrive on, a
completion marking a frame pass due (`fired`).

A slot is free, armed, or cancelling, and is reused only once its completion —
readiness or the cancellation — has come back, so a descriptor number a closed
pane's successor reuses never shares a poll with it. Address-pinned: the polls
carry pointers to their slots, so it lives in the loop's frame and every armed
poll is cancelled and reaped (`close`) before that frame ends.
*/
private struct ReadableWakes
{
    import sparkles.event_horizon.op : Completion, OpHandle, OpPollAdd, PollEvents;

    @disable this(this);

    private enum State : ubyte { free, armed, cancelling }

    private static struct Slot
    {
        ReadableWakes* owner;
        int fd = -1;
        OpHandle op;
        State state;
        bool wanted; // asked for during the current pass
    }

    DefaultLoop* loop;
    /// A watched descriptor turned readable: a frame pass is due.
    bool fired;
    private Slot[16] slots;

    /// A component's ask, for this pass.
    bool want(int fd) @system nothrow @nogc
    {
        if (loop is null || fd < 0)
            return false;
        foreach (ref s; slots)
            if (s.state == State.armed && s.fd == fd)
            {
                s.wanted = true;
                return true;
            }
        foreach (ref s; slots)
        {
            if (s.state != State.free)
                continue;
            s.owner = &this;
            auto h = loop.submit(OpPollAdd(fd, PollEvents.readable, false), &onReady, &s);
            if (h.hasError)
                return false;
            s.fd = fd;
            s.op = h.value;
            s.state = State.armed;
            s.wanted = true;
            return true;
        }
        return false;
    }

    /// A pass begins: every ask must be made again.
    void beginPass() @safe pure nothrow @nogc
    {
        foreach (ref s; slots)
            s.wanted = false;
    }

    /// A pass ended: let go of what nobody asked for again.
    void endPass() @system nothrow @nogc
    {
        foreach (ref s; slots)
            if (s.state == State.armed && !s.wanted)
                cancel(s);
    }

    /// Cancels every poll and reaps the cancellations, so no completion
    /// outlives the slots it points at.
    void close() @system nothrow
    {
        import core.time : Duration;

        if (loop is null)
            return;
        foreach (ref s; slots)
            if (s.state == State.armed)
                cancel(s);
        // A cancellation completes in the loop's next turns; a few suffice.
        foreach (_; 0 .. 64)
        {
            bool pending = false;
            foreach (ref s; slots)
                pending |= s.state != State.free;
            if (!pending || loop.runOnce(Duration.zero).hasError)
                break;
        }
        loop = null;
    }

    private void cancel(ref Slot s) @system nothrow @nogc
    {
        // A refused cancel leaves the slot armed and unwanted: the next
        // pass's `endPass` asks again, and the poll's own completion, if it
        // comes first, frees it.
        if (!loop.cancel(s.op).hasError)
            s.state = State.cancelling;
    }

    private static void onReady(void* ctx, ref Completion done) nothrow @nogc
    {
        auto s = cast(Slot*) ctx;
        // Readiness (any of readable, hangup, error) is a reason to read;
        // a cancellation is only the slot coming back.
        if (s.state == State.armed && done.res >= 0)
            s.owner.fired = true;
        s.state = State.free;
        s.fd = -1;
    }
}

@("native_loop.ReadableWakes.wakesOnceReadableAndLetsGoUnasked")
@system unittest
{
    import core.sys.posix.unistd : close, pipe, write;
    import sparkles.test_runner.skip : skipTest;

    DefaultLoop loop;
    if (DefaultLoop.create(loop, LoopConfig()).hasError)
        return skipTest("no event loop here (a sandbox without io_uring)");
    scope (exit) loop.destroy();

    int[2] fds;
    assert(pipe(fds) == 0);
    scope (exit)
    {
        close(fds[0]);
        close(fds[1]);
    }

    ReadableWakes wakes;
    wakes.loop = &loop;
    scope (exit) wakes.close();

    // Asked for during a pass: armed once, however often it is asked.
    wakes.beginPass();
    assert(wakes.want(fds[0]));
    assert(wakes.want(fds[0]));
    wakes.endPass();
    size_t armed;
    foreach (ref s; wakes.slots)
        armed += s.state == ReadableWakes.State.armed;
    assert(armed == 1, "one poll per descriptor");

    // Nothing written yet: no wake.
    cast(void) loop.runOnce(Duration.zero);
    assert(!wakes.fired);

    // The writer writes: the next turn of the loop marks a pass due, and the
    // one-shot poll's slot is free again.
    ubyte one = 1;
    assert(write(fds[1], &one, 1) == 1);
    foreach (_; 0 .. 8)
        if (!wakes.fired)
            cast(void) loop.runOnce(10.msecs);
    assert(wakes.fired, "readability wakes the loop");
    foreach (ref s; wakes.slots)
        assert(s.state == ReadableWakes.State.free);

    // Asked for, then not asked for again: let go (cancelled and reaped),
    // with no wake for it.
    wakes.fired = false;
    wakes.beginPass();
    int[2] quiet;
    assert(pipe(quiet) == 0);
    scope (exit)
    {
        close(quiet[0]);
        close(quiet[1]);
    }
    assert(wakes.want(quiet[0]));
    wakes.endPass();
    wakes.beginPass();
    wakes.endPass(); // the next pass did not ask
    foreach (_; 0 .. 8)
        cast(void) loop.runOnce(Duration.zero);
    foreach (ref s; wakes.slots)
        assert(s.state == ReadableWakes.State.free, "an unasked poll is let go");
    assert(!wakes.fired, "a cancellation is not a wake");

    // Without a loop, nothing can be watched.
    ReadableWakes none;
    assert(!none.want(fds[0]));
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
    // paced by the compositor's frame callbacks, AppKit's by the view's
    // display link; X11 presents at once, and its FIFO swapchain paces it.
    version (Android)
        enum supported = true;
    else version (linux)
        enum supported = true;
    else version (OSX)
        enum supported = true;
    else
        enum supported = false;
    static if (!supported)
    {
        whyNot(i"the native arm runs on Wayland, X11, AppKit and Android only so far");
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
        case WindowSystem.appkit: return BackendPreference.appkit;
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
    /// When presents reached the display, from the swapchain itself where
    /// it was created for `VK_EXT_present_timing` (`OPL22`): the first source.
    PresentTimes presentTimes;
    ulong presentTag;     /// the record number the next present belongs to
    bool tagPresents;     /// a switch or a specimen wants display times
    bool waitPresents;    /// and present wait is the source
    bool timePresents;    /// the next present asks its time through present timing
    MonoTime presentAim;  /// the refresh the next present is aimed at; init for none
    bool up;

    @disable this(this);

    /// Whether present timing is the source of display times (`OPL13`).
    bool presentTimed() const @safe pure nothrow @nogc
        => swapchain.presentTiming && presentTimes.ready;

    /// Whether presents can be waited on: through present ids and waits 2
    /// where the swapchain was created for them (`OPL20`), else the first.
    bool presentsWaitable() @system nothrow
        => swapchain.presentId2 ? vk.device.waitForPresent2KHR !is null : vk.presentWait;

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
        presentTimes = PresentTimes.init;
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

/**
Where the frame schedule's presentation times come from, in `OPL13`'s order:
the swapchain's present timing, the window system's presentation feedback,
Android's display timing, then the completion of a present wait — the second
extension where the swapchain was created for it.
*/
package string presentTimeSource(bool presentTiming, bool windowFeedback, bool displayTiming,
    bool presentWait2, bool presentWait) @safe pure nothrow @nogc
    => presentTiming ? "VK_EXT_present_timing"
        : windowFeedback ? "the window system's presentation feedback"
        : displayTiming ? "VK_GOOGLE_display_timing"
        : presentWait2 ? "VK_KHR_present_wait2"
        : presentWait ? "VK_KHR_present_wait" : "nowhere";

///
@("ui_app.native_loop.presentTimeSource.followsTheOrder")
@safe pure nothrow @nogc unittest
{
    assert(presentTimeSource(true, true, false, true, true) == "VK_EXT_present_timing");
    assert(presentTimeSource(false, true, false, true, true)
        == "the window system's presentation feedback");
    assert(presentTimeSource(false, false, false, true, true) == "VK_KHR_present_wait2");
    assert(presentTimeSource(false, false, false, false, true) == "VK_KHR_present_wait");
    assert(presentTimeSource(false, false, false, false, false) == "nowhere");
}

/// How a mechanism stands, for `OPL24`'s report: the device enabled it,
/// and the swapchain uses it, or not.
package string enabledOn(bool device, bool swapchain) @safe pure nothrow @nogc
    => !device ? "off (not offered)" : swapchain ? "on" : "off (the surface does not support it)";

///
@("ui_app.native_loop.enabledOn.namesWhoLacksIt")
@safe pure nothrow @nogc unittest
{
    assert(enabledOn(true, true) == "on");
    assert(enabledOn(true, false) == "off (the surface does not support it)");
    assert(enabledOn(false, false) == "off (not offered)");
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
        || cfg.native.debugging.frameTrace.length || cfg.native.debugging.frameCounters
        || cfg.native.debugging.latencyLog.length;
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
        // A family that is not installed costs its look, not the window:
        // the default list, said aloud.
        FontRequest fallback;
        fallback.searchDirs = request.font.searchDirs.dup;
        if (request.font.family == defaultGuiFont
            || !measureCellFont(fallback, request.extraFontSources, pxAt(1), session.font))
        {
            whyNot(i"the native arm resolved no cell font for `$(request.font.family)`");
            return false;
        }
        whyNot(i"no font `$(request.font.family)`; drawing in the default face");
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

    // The clipboard's offers (`INP25`), from the first drain on: X11
    // announces an owner from before the window opened while the window
    // is still being configured. On the heap: a transfer's sink must
    // outlive it (`DT2`), and the window system may still hold one when
    // this function returns.
    auto clip = new ClipboardRead;
    void noteOffer(in WindowEvent e)
    {
        e.payload.match!((in DataOfferEvent d) {
            cast(void) wsi.withText(d.mimeType, (scope const(char)[] type, bool) @safe {
                clip.note(d, type);
            });
        }, (in _) {});
    }

    // ── the first configure ──
    SurfaceMetrics metrics;
    bool ready, closeRequested;
    auto first = MonoTime.currTime + 5.seconds;
    while (!ready && MonoTime.currTime < first)
    {
        if (tickNative(wsi, loop, 100.msecs).hasError)
            break;
        cast(void) wsi.drain((WindowEvent e) {
            noteEvent(e);
            noteOffer(e);
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
            follows ? session.specimen.request.faceIndex : f.index,
            follows ? session.specimen.request.coordinates : null,
            follows ? session.specimen.request.styleIndices[] : f.styleIndices[]);
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

    // How many swapchains the run built: a present-mode switch between
    // compatible modes builds none (`OPL23`).
    uint swapchainsBuilt;

    // Once a device: which of the present path's mechanisms it enabled, and
    // where the frame schedule's presentation times come from (`OPL24`).
    void reportPresentPath()
    {
        bool feedback;
        static if (__traits(hasMember, Wsi, "requestPresentationFeedback"))
            feedback = wsi.canReportPresentation;
        const source = presentTimeSource(gpu.presentTimed, feedback, gpu.vk.displayTiming,
            gpu.swapchain.presentId2 && gpu.presentsWaitable, gpu.vk.presentWait);
        string modes;
        foreach (m; gpu.swapchain.compatiblePresentModes)
            modes ~= (modes.length ? " " : "") ~ presentModeName(m);
        if (modes.length)
            modes = " (" ~ presentModeName(gpu.swapchain.presentMode) ~ " among " ~ modes ~ ")";
        const targets = !gpu.presentTimed ? ""
            : gpu.swapchain.presentAtAbsoluteTime ? " with absolute targets" : " without targets";
        trace(i"native arm present path: present ids and waits 2 $(enabledOn(gpu.vk.presentWait2, gpu.swapchain.presentId2)), present timing $(enabledOn(gpu.vk.presentTiming, gpu.presentTimed))$(targets), swapchain maintenance1 $(enabledOn(gpu.vk.swapchainMaintenance1, modes.length > 0))$(modes); presentation times from $(source)");
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
        // Results kept for every frame in flight and the one shown (`OPL22`).
        gpu.swapchain.timingQueueSize = (gpu.sync.framesInFlight ? gpu.sync.framesInFlight
            : FrameSync.defaultFramesInFlight) + 1;
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
        {
            gpu.swapchainGoes();
            ++swapchainsBuilt;
        }
        if (!ok)
            return false;
        if (gpu.swapchain.presentTiming)
            cast(void) gpu.presentTimes.prepare(gpu.vk, gpu.swapchain.handle,
                gpu.swapchain.presentStages, gpu.swapchain.presentAtAbsoluteTime,
                gpu.swapchain.timingQueueSize);
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
        reportPresentPath();
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
            if (tickNative(wsi, loop, 1.seconds).hasError)
                return false;
            cast(void) wsi.drain((WindowEvent e) {
                noteEvent(e);
                noteOffer(e);
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
    // The descriptors the application drains in its frame wake it when they
    // turn readable (`wakeWhenReadable`); their polls end with this frame.
    ReadableWakes readable;
    readable.loop = &loop;
    host.readable_ = &readable;
    scope (exit)
    {
        host.readable_ = null;
        readable.close();
    }
    // The stream sources the application reads between frames
    // (`openStream`); closed, and their buffers given back, with this frame.
    StreamIngest ingest;
    ingest.loop = &loop;
    host.ingest_ = &ingest;
    scope (exit)
    {
        host.ingest_ = null;
        ingest.closeAll();
    }
    // The stream position the frame pass in progress started at.
    ulong framePosition;
    // When a frame starts (output-latency.md §3): at the latch deadline of
    // the earliest refresh it can reach, on Wayland; elsewhere at once.
    static if (__traits(compiles, backendKindOf!Wsi))
        enum onWayland = backendKindOf!Wsi == BackendKind.wayland;
    else
        enum onWayland = false;
    FrameSchedule schedule;
    schedule.policy = paced && onWayland ? cfg.native.frameSchedule : FrameSchedulePolicy.asap;
    const lateSchedule = schedule.policy == FrameSchedulePolicy.late;
    // The presentation each recent frame aimed at, by its record number, for
    // the margin's adaptation (`OPL16`).
    static struct Aim
    {
        ulong frame = ulong.max;
        MonoTime target;
    }
    Aim[64] aims;
    MonoTime aimNow;   // what the frame pass in progress (or held) aims at
    MonoTime latchAt;  // a due frame is held until this latch deadline (`OPL14`)
    MonoTime aimOf(ulong frame) @safe pure nothrow @nogc
    {
        const a = aims[frame % aims.length];
        return a.frame == frame ? a.target : MonoTime.init;
    }
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
    // `readClipboard` streams the offer's text (`INP25`).
    host.capabilities.clipboardRead = __traits(hasMember, Wsi, "receive");
    WsiInput input;
    host.input_ = &input;
    input.capabilities = host.capabilities;
    input.touchGestures = touch;
    input.longPressDrags = cfg.longPressDrags;
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
    // Asked every frame by an application that may draw its own pointer:
    // only a change reaches the window system.
    static if (__traits(hasMember, Wsi, "setCursorVisible"))
    {
        bool cursorShown = true;
        session.setCursorVisible = (bool visible) {
            if (visible != cursorShown && !wsi.setCursorVisible(window, visible).hasError)
                cursorShown = visible;
        };
    }
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
    static if (__traits(hasMember, Wsi, "setFullscreen"))
        session.setFullscreen = (bool on) {
            if (!wsi.setFullscreen(window, on).hasError)
                session.fullscreen = on;
        };
    session.readClipboard = (uint request) {
        clip.ask(request);
        if (clip.inFlight)
            return; // the running read answers this request
        static if (__traits(hasMember, Wsi, "receive"))
            if (const type = clip.textType)
                if (!wsi.receive(clip.offer, type, *clip).hasError)
                {
                    clip.inFlight = true;
                    return;
                }
        clip.answerEmpty();
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
    LatencyLog latencyLog;
    if (cfg.native.debugging.latencyLog.length)
        latencyLog.open(cfg.native.debugging.latencyLog, opened);
    scope (exit)
        if (history !is null)
            latencyLog.close(*history);
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
        r.streamPosition = framePosition;
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
        schedule.noteShown(shown, refresh, aimOf(tag), MonoTime.currTime);
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
    // `--debug switch-present-mode-at=N`: after frame N, the next present
    // mode the swapchain was created compatible with, from the next present
    // on and without a rebuild (`OPL23`); 30 frames on, how many swapchains
    // were built since.
    uint modeSwitchedAt, builtAtSwitch;
    void switchPresentMode(uint presented)
    {
        const from = gpu.swapchain.presentMode;
        if (modeSwitchedAt)
        {
            note(i"native window present mode: $(presentModeName(from)) for 30 frames, $(swapchainsBuilt - builtAtSwitch) swapchains built since the switch");
            modeSwitchedAt = 0;
            return;
        }
        const modes = gpu.swapchain.compatiblePresentModes;
        VkPresentModeKHR to = from;
        foreach (i, m; modes)
            if (m == from)
            {
                to = modes[(i + 1) % modes.length];
                break;
            }
        if (to == from || !gpu.swapchain.switchPresentMode(to))
        {
            note(i"native window present mode: $(presentModeName(from)), the swapchain switches to no other");
            return;
        }
        modeSwitchedAt = presented;
        builtAtSwitch = swapchainsBuilt;
        note(i"native window present mode: $(presentModeName(from)) to $(presentModeName(to)) after frame $(presented), without a rebuild ($(swapchainsBuilt) swapchains built so far)");
    }
    // What the device says reached the display, never waiting (`OPL21`):
    // after a frame pass, and after each loop turn while a present is
    // outstanding. Android's display timing is read after a frame pass only.
    // Mesa answers both by reading the shared Wayland display for its own
    // queue, which a read the window system holds prepared would starve:
    // the reads borrow it, as `nativeIo` does.
    void pollPresents(bool afterFrame)
    {
        if (!gpu.up)
            return;
        const timed = gpu.presentTimed && gpu.presentTimes.outstanding;
        const waited = !gpu.vk.displayTiming && gpu.presentWait.outstanding;
        if (timed || waited)
            cast(void) nativeIo(() {
                if (timed)
                    gpu.presentTimes.poll(gpu.vk, (ulong id, long ns) {
                        onShown(id - 1, MonoTime.zero + nsecs(ns), gpu.presentTimes.refresh);
                    });
                if (waited)
                    pollCompleted(gpu.presentWait, gpu.vk, (ulong id, MonoTime at) {
                        onShown(id - 1, at, Duration.zero);
                    });
                return true;
            });
        if (gpu.vk.displayTiming && afterFrame)
            gpu.displayTimes.poll(gpu.vk, gpu.swapchain.handle, (uint id, long ns) {
                onShown(id - 1, MonoTime.zero + nsecs(ns), gpu.displayTimes.refresh);
            });
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
                    // Where the window system reports it, the state is
                    // its, a user's own toggle included.
                    session.fullscreen = w.state.has(ToplevelState.fullscreen);
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
                (in DataOfferEvent _) {
                    noteOffer(e);
                    input_ = false;
                },
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
        // `INP25`: a clipboard read that ended in this drain (or had
        // nothing to read) is answered after its input, as a tagged paste.
        clip.deliver((Event x) {
            handle(host, x);
            delivered = true;
        });
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
    bool shotAsked;
    void stressAndBudget()
    {
        lastProgress = MonoTime.currTime;
        // `shot=PATH`: the frame after this one is captured — the budget's
        // last, or the second of an open-ended run.
        if (cfg.native.debugging.shot.length && !shotAsked
            && (cfg.native.debugging.frames == 0 || presented + 1 >= cfg.native.debugging.frames))
        {
            shotAsked = true;
            session.shotPath = cfg.native.debugging.shot;
        }
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

        // A due frame waits for the latch deadline of the earliest refresh it
        // can reach, the loop reading stream sources meanwhile (`OPL14`); a
        // frame the window needs — a new surface or size — does not.
        // A hold, once set, is kept: woken at its deadline, the frame draws
        // for the refresh it was held for, though asked afresh the scheduler
        // would by then aim at the next.
        bool held;
        if (plan.draw && lateSchedule && !plan.mustDraw && !extentsPending && !scripted)
        {
            const nowTime = MonoTime.currTime;
            if (latchAt == MonoTime.init)
            {
                const st = schedule.start(nowTime);
                latchAt = st.at;
                aimNow = st.target;
            }
            held = latchAt > nowTime + latchSlack;
            if (held)
                lc.frameDone(FrameResult.again, now()); // still due
            else
                latchAt = MonoTime.init;
        }
        else
        {
            latchAt = MonoTime.init;
            aimNow = MonoTime.init;
        }

        if (plan.draw && !held)
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
            if (!paced && gpu.up && gpu.presentsWaitable)
                cast(void) waitForNewest(gpu.presentWait, gpu.vk, 50.msecs,
                    (ulong id, MonoTime at) { onShown(id - 1, at, Duration.zero); });
            const started = MonoTime.currTime;
            framePosition = ingest.position; // the bytes this frame shows (`OPL25`)
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
                if (tickNative(wsi, loop, Duration.zero).hasError)
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
                    // The scheduler learns from every frame (`OPL19`).
                    aims[recorded % aims.length] = Aim(recorded, aimNow);
                    const wantTimes = history !is null || changed || lateSchedule;
                    // The swapchain's own present timing first, aimed at
                    // the refresh the frame was scheduled for (`OPL13`,
                    // `OPL22`); a present the timing queue has no room for
                    // goes untimed.
                    const timed = wantTimes && gpu.presentTimed;
                    gpu.timePresents = timed && gpu.presentTimes.canRequest(MonoTime.currTime);
                    gpu.presentAim = aimNow;
                    bool feedback;
                    static if (__traits(hasMember, Wsi, "requestPresentationFeedback"))
                        if (wantTimes && !timed && wsi.canReportPresentation)
                            feedback = !wsi.requestPresentationFeedback(window, recorded).hasError;
                    // Without the window system's feedback, the device's.
                    gpu.presentTag = recorded;
                    gpu.tagPresents = !feedback && !timed && wantTimes;
                    // Unpaced, every present carries an id: the next pass
                    // waits for it.
                    gpu.waitPresents = gpu.presentsWaitable
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
                {
                    history.add(r);
                    latencyLog.write(*history, now() - 1.seconds);
                }
                recordMade = true;
            }
            // What the device says reached the display, its record now in
            // the history: never waits.
            if (timing.submitted)
                pollPresents(afterFrame: true);
            if (timing.collected && traceNames.length != gpu.profiler.names.length)
                traceNames = gpu.profiler.names.dup; // a copy: the table goes with the device
            final switch (outcome)
            {
                case FrameOutcome.presented:
                    lc.frameDone(FrameResult.presented, now());
                    schedule.noteCost(took); // start to the present's return (`OPL15`)
                    ++presented;
                    if (presented == cfg.native.debugging.switchPresentModeAt
                        || (modeSwitchedAt && presented == modeSwitchedAt + 30))
                        switchPresentMode(presented);
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
        // system gives them only on request (Android, AppKit).
        static if (__traits(hasMember, Wsi, "requestFrame"))
            if (plan.askFrame)
                cast(void) wsi.requestFrame(window);

        // Park until the window system has something, or the application's
        // next deadline: for a frame held for its latch, the latch.
        Duration timeout = plan.park < 1.seconds ? plan.park : 1.seconds;
        if (latchAt != MonoTime.init)
        {
            const left = latchAt - MonoTime.currTime;
            timeout = left > Duration.zero ? left : Duration.zero;
        }
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
        // An answer already in hand (an empty clipboard) goes out now.
        if (clip.ready)
            timeout = Duration.zero;
        // The turn's ingest budget: bytes a stream source holds go to its
        // sink first, and while any remain the loop does not wait (`OPL5`).
        ingest.beginTurn();
        if (ingest.hasPending)
            timeout = Duration.zero;
        const parkedAt = MonoTime.currTime;
        if (tickNative(wsi, loop, timeout).hasError)
            break;
        drainEvents();
        pollPresents(afterFrame: false);
        if (history !is null)
            latencyLog.write(*history, now() - 1.seconds);
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
        // timeout, for a descriptor it drains turning readable, or for bytes
        // a stream source delivered (`OPL12`).
        const readied = readable.fired || ingest.delivered;
        readable.fired = false;
        ingest.delivered = false;
        if (readied
            || (host.wakeAsk != Duration.max && MonoTime.currTime - lastPass >= host.wakeAsk)
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

// A latch deadline closer than this is now: a park that short costs more
// than it saves.
private enum latchSlack = 200.usecs;

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

/**
The native host's clipboard reads (`INP25`): the clipboard's offer as the
window system last announced it, with its best text type, and the one read in
flight. A read streams the offer's text into `bytes` (`DT2`, this is the
sink); the loop answers the request after the drain the transfer ends in.
*/
private struct ClipboardRead
{
    import sparkles.wsi : DataOfferAction, DataOfferEvent, OfferId,
        TransferId, TransferStatus;

    OfferId offer;        /// the clipboard's offer, as last announced
    char[64] mime = 0;    /// its best text type (see `rankText`)
    size_t mimeLength;    /// ditto
    int rank;             /// ditto, 0: no text
    char[] bytes;         /// what the transfer has delivered
    uint request;         /// the read being answered (0: none)
    bool inFlight;        /// a transfer is running
    bool ready;           /// `request`'s answer waits for the loop

    /// How good a text type `mime` is: every backend names UTF-8 text
    /// `text/plain;charset=utf-8`; Wayland peers may offer bare `text/plain`.
    static int rankText(scope const(char)[] mime) @safe pure nothrow @nogc
        => mime == "text/plain;charset=utf-8" ? 2 : mime == "text/plain" ? 1 : 0;

    /// One `DataOfferEvent` and its MIME type: a new offer replaces the old.
    void note(in DataOfferEvent d, scope const(char)[] type) @safe pure nothrow @nogc
    {
        if (d.action != DataOfferAction.offered)
        {
            if (d.action == DataOfferAction.withdrawn && d.offer == offer)
                rank = 0;
            return;
        }
        if (d.offer != offer)
        {
            offer = d.offer;
            rank = 0;
        }
        const r = rankText(type);
        if (r > rank && type.length <= mime.length)
        {
            mime[0 .. type.length] = type;
            mimeLength = type.length;
            rank = r;
        }
    }

    /// The text type to receive, or null when the clipboard holds no text.
    const(char)[] textType() const return @safe pure nothrow @nogc
        => rank ? mime[0 .. mimeLength] : null;

    /// Asks for `request`'s answer; a read already in flight answers the
    /// newest request instead.
    void ask(uint request_) @safe pure nothrow
    {
        request = request_;
        if (!inFlight)
            bytes.length = 0;
    }

    /// The answer is the empty text (no text offered, or the read failed).
    void answerEmpty() @safe pure nothrow
    {
        bytes.length = 0;
        inFlight = false;
        ready = request != 0;
    }

    /// `DT2`'s sink: the transfer's bytes, then its end.
    void chunk(TransferId, scope const(ubyte)[] piece) @safe nothrow
    {
        bytes ~= cast(const(char)[]) piece;
    }

    /// ditto
    void finish(TransferId, TransferStatus status) @safe nothrow
    {
        inFlight = false;
        if (status != TransferStatus.completed)
            bytes.length = 0;
        ready = request != 0;
    }

    /// Hands the answer to `sink` as tagged paste chunks, once.
    void deliver(Sink)(scope Sink sink)
    {
        import sparkles.input.events : pasteChunks;

        if (!ready)
            return;
        const answering = request;
        ready = false;
        request = 0;
        // Gathered first: the chunker is `@safe`, the application's handler
        // need not be.
        Event[] answer;
        pasteChunks(bytes, (Event e) @safe { answer ~= e; }, answering);
        bytes.length = 0;
        foreach (e; answer)
            sink(e);
    }
}

/// The best text type wins, a new offer forgets the last one's, and only
/// this offer's withdrawal clears it.
@("ui_app.native_loop.ClipboardRead.tracksTheTextOffer")
@safe pure nothrow
unittest
{
    import sparkles.wsi : DataOfferAction, DataOfferEvent, OfferId;

    ClipboardRead c;
    const a = OfferId(1, 1), b = OfferId(2, 1);
    c.note(DataOfferEvent(a, DataOfferAction.offered), "text/html");
    assert(c.textType is null);
    c.note(DataOfferEvent(a, DataOfferAction.offered), "text/plain");
    c.note(DataOfferEvent(a, DataOfferAction.offered), "text/plain;charset=utf-8");
    c.note(DataOfferEvent(a, DataOfferAction.offered), "text/plain");
    assert(c.textType == "text/plain;charset=utf-8");
    c.note(DataOfferEvent(b, DataOfferAction.offered), "image/png");
    assert(c.textType is null, "another application copied an image");
    c.note(DataOfferEvent(b, DataOfferAction.offered), "text/plain");
    c.note(DataOfferEvent(a, DataOfferAction.withdrawn), "text/plain");
    assert(c.textType == "text/plain", "a stale offer's withdrawal is not this one's");
    c.note(DataOfferEvent(b, DataOfferAction.withdrawn), "text/plain");
    assert(c.textType is null);
}

/// A read streams into the sink and is answered once, tagged; a failed
/// transfer answers empty; a second request while one is in flight takes
/// over the answer.
@("ui_app.native_loop.ClipboardRead.answersTheRequest")
@safe nothrow
unittest
{
    import sparkles.input.events : match, PasteEvent;
    import sparkles.wsi : TransferId, TransferStatus;

    ClipboardRead c;
    char[64] got = 0;
    size_t n;
    uint tag;
    bool last;
    void collect(Event e) @safe nothrow
    {
        const p = e.match!((in PasteEvent p) => p, _ => PasteEvent.init);
        foreach (ch; p.text[])
            got[n++] = ch;
        tag = p.request;
        last = p.last;
    }

    c.ask(7);
    c.inFlight = true;
    c.ask(8);
    c.chunk(TransferId.init, cast(const(ubyte)[]) "héllo");
    c.deliver(&collect);
    assert(n == 0, "nothing before the transfer ends");
    c.finish(TransferId.init, TransferStatus.completed);
    c.deliver(&collect);
    assert(got[0 .. n] == "héllo" && tag == 8 && last);
    n = 0;
    c.deliver(&collect);
    assert(n == 0, "answered once");

    c.ask(9);
    c.inFlight = true;
    c.chunk(TransferId.init, cast(const(ubyte)[]) "partial");
    c.finish(TransferId.init, TransferStatus.failed);
    c.deliver(&collect);
    assert(n == 0 && tag == 9 && last, "a failed read answers empty");
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
    // A pass's readiness asks replace the last pass's (`wakeWhenReadable`).
    if (host.readable_ !is null)
        host.readable_.beginPass();
    present(host);
    if (host.readable_ !is null)
        host.readable_.endPass();
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
    if (session.readClipboard is null)
        session.readClipboard = (uint) {};
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
    // The effects' clock: pinned for a capture, else seconds since the
    // first frame drawn (`DBG1`).
    if (session.effectEpoch == MonoTime.init)
        session.effectEpoch = MonoTime.currTime;
    gpu.canvas.effectClock(session.pinnedEffectClock >= 0 ? session.pinnedEffectClock
        : (MonoTime.currTime - session.effectEpoch).total!"usecs" / 1e6f);
    gpu.canvas.effects(session.effectRegistry);
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
    // A present waited on, or timed by the swapchain, carries an id; ids
    // increase over the swapchain's presents either way.
    const presentId = gpu.waitPresents || gpu.timePresents
        ? gpu.presentWait.idFor(gpu.presentTag) : 0;
    const timingId = gpu.tagPresents && vk.displayTiming ? DisplayTimes.idFor(gpu.presentTag) : 0;
    const timingRequest = gpu.presentTimes.request(gpu.presentAim);
    const presented = gpu.swapchain.present(*vk, index, gpu.sync.renderFinished(index), presentId,
        timingId, gpu.timePresents ? &timingRequest : null);
    if (!presented.hasError && presentId)
    {
        if (gpu.waitPresents)
            gpu.presentWait.submitted(gpu.swapchain.handle, presentId, gpu.swapchain.presentId2);
        else
            gpu.presentWait.lastSubmitted = presentId;
        if (gpu.timePresents)
            gpu.presentTimes.requested(MonoTime.currTime);
    }
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
/*
`--debug latency-log=PATH`: one line per recorded frame — its number, its
start and display time in `CLOCK_MONOTONIC` nanoseconds (display -1 where
unknown), and the stream bytes delivered before it started
(output-latency.md `OPL25`, the input `OPL26` joins against).

Written as the run goes, a frame once a second has passed since it started —
its display time has come back by then, or never will — and the rest when the
window closes, so a run ended by a signal keeps all but its last second.
*/
private struct LatencyLog
{
    import std.stdio : File;

    File file;
    ulong next;   // the first frame number not yet written
    long origin;  // the run's origin, in CLOCK_MONOTONIC nanoseconds
    string path;

    void open(string path, MonoTime opened) @system
    {
        this.path = path;
        origin = (opened - MonoTime.zero).total!"nsecs";
        try
        {
            file = File(path, "w");
            file.write("frame\tstart_ns\tshown_ns\tstream_position\n");
            file.flush();
        }
        catch (Exception e)
            whyNot(i"native window latency log: $(path): $(e.msg)");
    }

    // Writes the frames that started before `settled` (from the run's
    // origin), or every frame when `settled` is `Duration.max`.
    void write(in FrameHistory!4096 history, Duration settled) @system
    {
        if (!file.isOpen)
            return;
        try
        {
            foreach (ref r; history[])
            {
                if (r.number < next)
                    continue;
                if (r.start >= settled)
                    break;
                file.writef("%s\t%s\t%s\t%s\n", r.number, origin + r.start.total!"nsecs",
                    r.shownKnown ? origin + r.shown.total!"nsecs" : -1, r.streamPosition);
                next = r.number + 1;
            }
            file.flush();
        }
        catch (Exception e)
        {
            whyNot(i"native window latency log: $(path): $(e.msg)");
            file.close();
        }
    }

    void close(in FrameHistory!4096 history) @system
    {
        if (!file.isOpen)
            return;
        write(history, Duration.max);
        note(i"native window latency log: $(next) frames in $(path)");
        file.close();
    }
}

/// A cell is the line its size names, as on the raylib arm, whatever the
/// face's rounding at a whole em would make it.
@("ui_app.native_loop.aCellIsTheLineItsSizeNames")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    foreach (name; ["DejaVuSansMono.ttf", "FiraCodeNerdFontMono-Regular.ttf",
            "MapleMono-NF-CN-Regular.ttf"])
    {
        CellFont loaded;
        loaded.path = "/this/path/does/not/exist.ttf";
        loaded.bytes = cast(const(ubyte)[]) read(buildPath(root, name));
        loaded.fallbacks = [FallbackFont(loaded.bytes)];
        foreach (px; 10 .. 41)
        {
            CellFont c;
            assert(remeasureCellFont(loaded, px, c));
            assert(c.cellH == px, name);
            assert(c.ascent > px / 2 && c.ascent < px, name);
            assert(c.underlineY > c.ascent - 1 && c.underlineY + c.underlineHeight <= px, name);
        }
    }
}
