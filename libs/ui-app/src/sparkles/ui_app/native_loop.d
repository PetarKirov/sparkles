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

import core.time : dur, Duration, MonoTime, msecs, seconds;
import std.algorithm.comparison : max, min;

import sparkles.base.term_color : RgbColor;
import sparkles.base.term_control : PointerShape;
import sparkles.event_horizon : DefaultLoop, LoopConfig;
import sparkles.input : Event, InputCapabilities, InputTextPool, mousePointer, PointerButton, touchPointer;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.effect : EffectRegistry;
import sparkles.ui.geometry : Size;
import sparkles.ui.image : ImageRegistry;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.gui_options : FontRequest, WindowCells;
import sparkles.ui_app.host : HostState, isHost, noDraw, noSetup, noShutdown, PointerUnit,
    RunConfig, withRealSize;
import sparkles.ui_app.lifecycle : Failure, FrameResult, Lifecycle, Rebuild, Surface;
import sparkles.ui_app.frame_title : fitTitle, TitleFace, titleCssPx, TitleStrip;
import sparkles.ui_app.client_frame : ClientFrame, crossCoverage, FrameAction, FrameColours,
    FrameGeometry, FrameHit, FramePart, FrameShape;
import sparkles.ui_app.wsi_input : TouchContacts, WsiInput;
import sparkles.ui.style : Palette;
import sparkles.ui_vulkan;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
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
    const path = resolveFontPath(request.family, sources);
    if (path.length == 0)
        return false;
    const bytes = cast(const(ubyte)[]) read(path);
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
    fontVariantPaths(path, boldPath, italicPath, boldItalicPath);
    static const(ubyte)[] load(string p)
        => p.length ? cast(const(ubyte)[]) read(p) : null;
    const hh = hhea(face.value);
    const span = hh.hasValue ? long(hh.value.ascender) - hh.value.descender : 0;
    const upem = face.value.unitsPerEm;
    cell = CellFont(path, px, cast(int)(m.width < 1 ? 1 : m.width), cellH, bytes,
        load(boldPath), load(italicPath), load(boldItalicPath),
        cast(uint)(em < 1 ? 1 : em),
        span > 0 ? ulong(px) * upem : cast(ulong)(em < 1 ? 1 : em), span > 0 ? cast(ulong) span : 1,
        ascent, underlineY, thickness,
        ascent - (em * 28 + 50) / 100); // about half the x-height
    // Icons, text the face lacks, and emoji, from the faces the raylib arm
    // falls back to.
    import sparkles.raylib_text.font_resolve : systemFallbackFacePaths;

    string nerdPath, regularPath, emojiPath;
    systemFallbackFacePaths(path, sources, nerdPath, regularPath, emojiPath);
    foreach (p; [regularPath, nerdPath, emojiPath])
    {
        if (!p.length)
            continue;
        const fb = load(p);
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

/// Why the native arm did not open, on standard error — logcat on Android,
/// where standard error goes nowhere: the run reports only that it failed,
/// and an application need not have set up a logger.
private void whyNot(Args...)(Args args) @system
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
    /// The title's face, found the first time a frame is drawn, and the
    /// title set in it.
    TitleFace titleFace;
    TitleStrip titleStrip; /// ditto
    void delegate(in char[]) @system setTitle; ///
    /// The transparent margin round the window, each side, in device pixels
    /// (`SurfaceMetrics.frameMargin`): the frame's shadow and outer resize
    /// border are drawn there, and the cells start inside it.
    int margin;
    /// The swapchain's alpha reaches the compositor: frames start
    /// transparent, and the window's ground is filled before the content.
    bool transparent;
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
    import core.stdc.stdlib : getenv;

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
    // Before `linux`, which Android also is: it has neither Wayland nor X11.
    // The window is the activity's, its frames paced by `AChoreographer`.
    version (Android)
    {
        AndroidWsi wsi;
        if (AndroidWsi.open(wsi, wsiConfig).hasError || wsi.attach(loop).hasError)
        {
            whyNot(i"the native arm has no activity: start the app through AndroidWsiMain");
            return false;
        }
        return drive!(present, handle, draw, setup, shutdown)(wsi, loop, cfg, request,
            paced: true);
    }
    else version (linux)
    {
        if (getenv("WAYLAND_DISPLAY") !is null)
        {
            WaylandWsi wsi;
            if (!WaylandWsi.open(wsi, loop, wsiConfig).hasError)
            {
                const deadline = MonoTime.currTime + 5.seconds;
                while (!wsi.bootstrapComplete && MonoTime.currTime < deadline)
                    if (wsi.runIntegratedOnce(loop, 100.msecs).hasError)
                        break;
                if (wsi.bootstrapComplete && wsi.canCreateWindows)
                    return drive!(present, handle, draw, setup, shutdown)(wsi, loop, cfg,
                        request, paced: true);
            }
        }
        X11Wsi wsi;
        if (X11Wsi.open(wsi, wsiConfig).hasError || wsi.attach(loop).hasError)
        {
            whyNot(i"the native arm found no Wayland compositor or X server");
            return false;
        }
        return drive!(present, handle, draw, setup, shutdown)(wsi, loop, cfg, request,
            paced: false);
    }
    else
    {
        whyNot(i"the native arm runs on Wayland and X11 only so far");
        return false;
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
    GpuTimer timer;
    bool up;

    @disable this(this);

    void destroy() @system
    {
        if (!up)
            return;
        if (vk.device.device !is null)
            vk.device.deviceWaitIdle(vk.device.device);
        timer.destroy(vk);
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

private bool drive(alias present, alias handle, alias draw, alias setup, alias shutdown,
    Wsi)(ref Wsi wsi, ref DefaultLoop loop, in RunConfig cfg, in NativeRequest request,
    bool paced) @system
{
    import sparkles.base.logger : trace;
    import sparkles.raylib_text.metrics_dpi : DisplayMetrics, pixelsForPoints;
    import sparkles.ui.interp.immediate : paint;

    NativeSession session;
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

    // ── the first configure ──
    SurfaceMetrics metrics;
    bool ready, closeRequested;
    auto first = MonoTime.currTime + 5.seconds;
    while (!ready && MonoTime.currTime < first)
    {
        if (wsi.runIntegratedOnce(loop, 100.msecs).hasError)
            break;
        cast(void) wsi.drain((WindowEvent e) {
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
    // The title face is looked up while the cells are measured and the
    // device is made, not in the first frame.
    if (session.frame.active)
        session.titleFace.prepare();

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
    void measure(int px)
    {
        CellFont font;
        if (measureCellFont(request.font, request.extraFontSources, px, font))
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
        cast(void) gpu.canvas.cellFont(faces, em.value, TextMetrics(ascent: f.ascent,
            underlineY: f.underlineY, underlineHeight: f.underlineHeight, strikeY: f.strikeY), fallbacks);
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

    // Frames presented so far: the epoch what a rebuild retires is stamped
    // with. Each frame waits for its slot's previous submit before reusing
    // the slot, so once every slot has drawn again after a rebuild (and one
    // frame more, for the presents that waited on the retired semaphores),
    // the queue is done with what it retired. Each retiree is reaped by its
    // own epoch: a resize that rebuilds every frame still reaps behind it.
    ulong presents;

    // The frame's extents (`F13`), asked for once the swapchain shows
    // alpha: without it, the margin would show black, and the frame keeps
    // to the window. Asked again only when the answer changes.
    // The metrics they change follow in the event queue, and are taken
    // before the next frame is drawn: drawn first, a frame of the old size
    // would be committed with the new window geometry (`extentsPending`).
    bool extentsAsked, extentsPending;
    // What the traced frame spent (`SPARKLES_NATIVE_TRACE_FRAMES`).
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
        import core.stdc.stdlib : getenv;

        bool made;
        cast(void) nativeIo(() {
            auto context = VulkanContext.create(gpu.vk, handles.value, ContextRequest(
                applicationName: request.app.nameOrDefault.idup,
                applicationVersion: makeApiVersion(0, request.app.version_[0],
                    request.app.version_[1], request.app.version_[2]),
                apiVersion: apiVersion13,
                validation: getenv("SPARKLES_VULKAN_VALIDATION") !is null));
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
    // A touch surface where the platform is one and the application asked
    // for gestures (`RunConfig.touchGestures`).
    bool touch;
    version (Android)
        touch = cfg.touchGestures;
    if (touch)
        host.capabilities = touchPointer;
    host.capabilities.keyRelease = cfg.keyRelease;
    WsiInput input;
    host.input_ = &input;
    input.capabilities = host.capabilities;
    input.touchGestures = touch;
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
    session.setTextInput = (bool on) {
        static if (__traits(hasMember, Wsi, "setTextInput"))
            cast(void) wsi.setTextInput(window, on);
    };

    scope (exit)
        shutdown(host);
    setup(host);

    const unitW = () => cfg.pointerUnit == PointerUnit.pixels ? 1 : session.font.cellW;
    const unitH = () => cfg.pointerUnit == PointerUnit.pixels ? 1 : session.font.cellH;

    // `SPARKLES_NATIVE_TRACE_FRAMES`: a line on standard error per frame
    // presented, and per frame the swapchain turned out stale for, so a run
    // can show an idle window drawing nothing, or one rebuilding forever.
    import core.stdc.stdlib : getenv;
    const traceFrames = getenv("SPARKLES_NATIVE_TRACE_FRAMES") !is null;
    const opened = MonoTime.currTime;
    Duration now() => MonoTime.currTime - opened;
    uint presented;
    // Since when the traced frame's size has waited.
    MonoTime resizedAt;
    // `SPARKLES_NATIVE_LOSE_DEVICE_AT=<n>`: treat frame `n` as a lost
    // device, which no software driver produces on demand, so the rebuild
    // can be shown to redraw.
    import std.conv : to;
    import std.string : fromStringz;
    uint loseDeviceAt;
    if (const at = getenv("SPARKLES_NATIVE_LOSE_DEVICE_AT"))
        loseDeviceAt = (() @trusted => at.fromStringz.to!uint)();

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
        if (delivered)
            lc.input();
    }

    bool ok = true;
    // The last frame pass, drawn or not: the application's timed wake
    // (`HST16`) counts from here, not from each park, which a window system
    // waking the loop with nothing to deliver (Android's inset poll while the
    // keyboard is up) would otherwise restart forever.
    MonoTime lastPass = MonoTime.currTime;
    for (;;)
    {
        if (host.quitRequested)
            lc.close();
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
            const started = MonoTime.currTime;
            lastPass = started;
            buildFrame!present(host, plan.mustDraw);
            timing.build = MonoTime.currTime - started;
            lc.requested(host.frameRequested);
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
                timing.traced = traceFrames;
                outcome = cropped
                    ? drawFrame!draw(*gpu, host, session, request.ground, timing)
                    : FrameOutcome.again;
            }
            if (presented + 1 == loseDeviceAt)
            {
                loseDeviceAt = 0;
                outcome = FrameOutcome.deviceLost;
            }
            final switch (outcome)
            {
                case FrameOutcome.presented:
                    lc.frameDone(FrameResult.presented, now());
                    ++presented;
                    if (!pipelinesSaved)
                        savePipelines();
                    if (traceFrames)
                    {
                        const done = MonoTime.currTime;
                        const resize = resizedAt == MonoTime.init ? Duration.zero
                            : done - resizedAt;
                        whyNot(i"native frame $(presented) at $((started - opened).total!"msecs") ms, $(session.pixelW)x$(session.pixelH) in $(gpu.swapchain.extent.width)x$(gpu.swapchain.extent.height): rebuild $(timing.rebuild.total!"usecs") us, build $(timing.build.total!"usecs"), wait $(timing.wait.total!"usecs"), acquire $(timing.acquire.total!"usecs"), record $(timing.record.total!"usecs"), present $(timing.present.total!"usecs"), gpu $(timing.gpu.total!"usecs") (frame -$(gpu.sync.framesInFlight)); resize shown after $(resize.total!"usecs") us; rebuild: settle $(timing.settle.total!"usecs"), release $(timing.release.total!"usecs"), swapchain $(timing.swapchain.total!"usecs"), views $(timing.views.total!"usecs"), sync $(timing.sync.total!"usecs")");
                        resizedAt = MonoTime.init;
                    }
                    timing = FrameTiming.init;
                    session.frameSeconds = lc.frameSeconds;
                    // What a rebuild retired goes once nothing can still be
                    // presenting it; destroyed at the next present, a quick
                    // second rebuild's swapchain and semaphores were still in
                    // use (`VUID-vkDestroySwapchainKHR-swapchain-01282`).
                    gpu.swapchain.epoch = gpu.sync.epoch = ++presents;
                    const settled = gpu.sync.framesInFlight + 1;
                    if (presents > settled)
                    {
                        gpu.sync.reapThrough(gpu.vk, presents - settled);
                        gpu.swapchain.reapThrough(gpu.vk, presents - settled);
                    }
                    break;
                case FrameOutcome.again:
                    lc.frameDone(FrameResult.again, now());
                    break;
                case FrameOutcome.rebuild:
                    lc.frameDone(FrameResult.outOfDate, now());
                    if (traceFrames)
                        whyNot(i"native frame: the swapchain is stale at $((started - opened).total!"msecs") ms, $(session.pixelW)x$(session.pixelH): acquire $(timing.acquired), present $(timing.presented), rebuild $(timing.rebuild.total!"usecs") us");
                    break;
                case FrameOutcome.deviceLost:
                    trace(i"native arm: the device was lost");
                    lc.frameDone(FrameResult.deviceLost, now());
                    break;
                case FrameOutcome.failed:
                    lc.frameDone(FrameResult.failed, now());
                    break;
            }
            if (outcome != FrameOutcome.presented && !pollNow())
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
        // A gesture in flight is ticked at the display's rate until it rests.
        if (input.gesturing && timeout > gestureTick)
            timeout = gestureTick;
        if (cfg.idleTimeoutMs >= 0 && cfg.idleTimeoutMs.msecs < timeout)
            timeout = cfg.idleTimeoutMs.msecs;
        const parkedAt = MonoTime.currTime;
        if (wsi.runIntegratedOnce(loop, timeout).hasError)
            break;
        drainEvents();
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
    input.translate(wsi, e, unitW, unitH, (Event x) {
        handle(host, withRealSize(x, host.size));
        dirty = true;
    });
}

// The end of a drain: whatever the translation held back, and the modifier
// level the batch left (`HST17`).
private void flushInput(alias handle)(ref NativeHost host, ref WsiInput input, ref bool dirty)
{
    input.endDrain((Event x) {
        handle(host, withRealSize(x, host.size));
        dirty = true;
    });
    host.noteModifiers(input.modifiers);
}

// A frame's operations: the host's per-frame state reset, then the
// application's `present`.
private void buildFrame(alias present)(ref NativeHost host, bool mustDraw)
{
    host.beginFrameState(mustDraw: mustDraw);
    present(host);
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
    const colours = FrameColours.of(session.framePalette, ground);
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
    session.titleFace.load();
    const ppem = cast(int)(titleCssPx * density + 0.5f);
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

/*
The device's time for each frame slot's commands, from a timestamp at their
start and one at their end, for `SPARKLES_NATIVE_TRACE_FRAMES`. A slot's
pair is read when the slot comes round again, its fence waited: the time is
that of the frame drawn `framesInFlight` frames before. A queue whose
timestamps carry no valid bits gets no timer.
*/
private struct GpuTimer
{
    VkQueryPool pool;
    uint slots;
    double nanosPerTick = 0;
    ulong validMask; // the bits a timestamp counts in; it wraps at their width
    bool[] written;

    // Tried once per device: `slots` stays set where the queue has no
    // timestamps and `pool` null.
    void create(ref VulkanContext vk, uint slots) @system
    {
        this.slots = slots;
        uint families;
        vk.instance.getPhysicalDeviceQueueFamilyProperties(vk.physicalDevice, &families, null);
        auto props = new VkQueueFamilyProperties[families];
        vk.instance.getPhysicalDeviceQueueFamilyProperties(vk.physicalDevice, &families,
            props.ptr);
        if (vk.queueFamily >= families || props[vk.queueFamily].timestampValidBits == 0)
            return;
        auto info = vkInfo(VkQueryPoolCreateInfo(
            queryType: VkQueryType.VK_QUERY_TYPE_TIMESTAMP, queryCount: 2 * slots));
        if (vk.device.createQueryPool(vk.device.device, &info, null, &pool) != VkResult.VK_SUCCESS)
        {
            pool = null;
            return;
        }
        nanosPerTick = vk.properties.limits.timestampPeriod;
        const bits = props[vk.queueFamily].timestampValidBits;
        validMask = bits >= 64 ? ulong.max : (1UL << bits) - 1;
        written = new bool[slots];
    }

    void destroy(ref VulkanContext vk) @system
    {
        if (pool !is null && vk.device.device !is null)
            vk.device.destroyQueryPool(vk.device.device, pool, null);
        this = GpuTimer.init;
    }

    // What the slot's last frame took on the device; `Duration.zero` when
    // it has none.
    Duration read(ref VulkanContext vk, uint slot) @system
    {
        if (pool is null || slot >= slots || !written[slot])
            return Duration.zero;
        ulong[2] ticks;
        const got = vk.device.getQueryPoolResults(vk.device.device, pool, 2 * slot, 2,
            ticks.sizeof, ticks.ptr, ulong.sizeof, VkQueryResultFlagBits.VK_QUERY_RESULT_64_BIT);
        if (got != VkResult.VK_SUCCESS)
            return Duration.zero;
        // Only the valid bits count, and a frame across the counter's wrap
        // is measured modulo it.
        const elapsed = ((ticks[1] & validMask) - (ticks[0] & validMask)) & validMask;
        return dur!"nsecs"(cast(long)(elapsed * nanosPerTick));
    }

    void begin(ref VulkanContext vk, VkCommandBuffer cmd, uint slot) @system
    {
        if (pool is null || slot >= slots)
            return;
        vk.device.cmdResetQueryPool(cmd, pool, 2 * slot, 2);
        vk.device.cmdWriteTimestamp(cmd,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, pool, 2 * slot);
    }

    void end(ref VulkanContext vk, VkCommandBuffer cmd, uint slot) @system
    {
        if (pool is null || slot >= slots)
            return;
        vk.device.cmdWriteTimestamp(cmd,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, pool, 2 * slot + 1);
        written[slot] = true;
    }
}

// Where a frame's time went, for `SPARKLES_NATIVE_TRACE_FRAMES`.
private struct FrameTiming
{
    /// Time the device's work too (`GpuTimer`).
    bool traced;
    /// The device's time for the frame drawn `framesInFlight` before.
    Duration gpu;
    Duration rebuild, build, wait, acquire, record, present;
    /// The rebuild's parts: the wait for frames in flight, the canvas's
    /// targets released, the swapchain, its views, the frames' sync.
    Duration settle, release, swapchain, views, sync;
    VkResult acquired, presented; /// what each call said, for a stale frame
}

// Acquires an image, draws the host's operations and the draw phase into it,
// and presents it.
private FrameOutcome drawFrame(alias draw)(ref Gpu gpu, ref NativeHost host,
    ref NativeSession session, RgbColor ground, ref FrameTiming timing) @system
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
    if (gpu.sync.waitForFrame(*vk).hasError)
        return FrameOutcome.deviceLost;
    timing.wait = lap();
    if (timing.traced && gpu.timer.pool is null && gpu.timer.slots == 0)
        gpu.timer.create(*vk, gpu.sync.framesInFlight);
    timing.gpu = gpu.timer.read(*vk, gpu.sync.frame);
    uint index;
    const acquired = vk.device.acquireNextImageKHR(vk.device.device, gpu.swapchain.handle,
        ulong.max, gpu.sync.imageAvailable, null, &index);
    timing.acquire = lap();
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
    gpu.timer.begin(*vk, cmd, gpu.sync.frame);

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
    paint(gpu.canvas, host.ops()[]);
    draw(host);
    // The client frame last, over everything, in the bar's rows above the
    // cells (`F13`).
    if (session.frame.active)
        drawClientFrame(gpu.canvas, session, ground);
    auto ended = gpu.canvas.endFrame();
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
    gpu.timer.end(*vk, cmd, gpu.sync.frame);
    if (gpu.commands.end(*vk, gpu.sync.frame).hasError)
        return FrameOutcome.deviceLost;
    const submitted = gpu.sync.submit(*vk, cmd, index);
    if (submitted.hasError)
        return submitted.error == VkResult.VK_ERROR_DEVICE_LOST ? FrameOutcome.deviceLost
            : FrameOutcome.failed;
    timing.record = lap();
    const presented = gpu.swapchain.present(*vk, index, gpu.sync.renderFinished(index));
    timing.present = lap();
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
