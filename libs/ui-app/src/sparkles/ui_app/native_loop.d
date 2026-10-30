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

import core.time : Duration, MonoTime, msecs, seconds;

import sparkles.base.term_color : RgbColor;
import sparkles.base.term_control : PointerShape;
import sparkles.event_horizon : DefaultLoop, LoopConfig;
import sparkles.input : Event, InputCapabilities, mousePointer, touchPointer;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.effect : EffectRegistry;
import sparkles.ui.geometry : Size;
import sparkles.ui.image : ImageRegistry;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.gui_options : FontRequest, WindowCells;
import sparkles.ui_app.host : HostState, isHost, noDraw, noSetup, noShutdown, PointerUnit,
    RunConfig, withRealSize;
import sparkles.ui_app.lifecycle : Failure, FrameResult, Lifecycle, Rebuild, Surface;
import sparkles.ui_app.wsi_input : TouchContacts, WsiInput;
import sparkles.ui_vulkan;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
import sparkles.wsi;

/// What the native arm opens.
struct NativeRequest
{
    string title;             /// the window's title
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
}

/// The host an application sees in a native window.
struct NativeHost
{
    mixin HostState;

    private NativeSession* session_;

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

    /// The window system offers no retitling yet; accepted and dropped.
    void title(in char[]) @safe pure nothrow @nogc {}

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
    // Before `linux`, which Android also is: it has neither Wayland nor X11.
    // The window is the activity's, its frames paced by `AChoreographer`.
    version (Android)
    {
        AndroidWsi wsi;
        if (AndroidWsi.open(wsi).hasError || wsi.attach(loop).hasError)
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
            if (!WaylandWsi.open(wsi, loop).hasError)
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
        if (X11Wsi.open(wsi).hasError || wsi.attach(loop).hasError)
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
    bool up;

    @disable this(this);

    void destroy() @system
    {
        if (!up)
            return;
        if (vk.device.device !is null)
            vk.device.deviceWaitIdle(vk.device.device);
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
    cast(void) config.title.assign(request.title.length > 255 ? request.title[0 .. 255]
        : request.title);
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

    void measure(int px)
    {
        CellFont font;
        if (measureCellFont(request.font, request.extraFontSources, px, font))
            session.font = font;
    }
    void takeMetrics()
    {
        session.scale = metrics.scale.value;
        session.pixelW = metrics.physicalSize.width;
        session.pixelH = metrics.physicalSize.height;
        session.insets = metrics.safeInsets;
    }
    Surface surfaceOf(in SurfaceMetrics m)
        => Surface(m.physicalSize.width, m.physicalSize.height, m.scale.value);
    takeMetrics();
    if (const px = lc.metrics(surfaceOf(metrics)))
        measure(px);

    // ── the device ──
    auto gpu = new Gpu;
    scope (exit)
        gpu.destroy();

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
        gpu.swapchain.destroy(gpu.vk);
        if (gpu.vk.surface !is null)
            gpu.vk.base.instance.destroySurfaceKHR(gpu.vk.base.instance.instance,
                gpu.vk.surface, null);
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

    bool rebuildSwapchain(bool force)
    {
        if (gpu.sync.imageCount)
            cast(void) gpu.sync.waitAll(gpu.vk);
        gpu.canvas.releaseTargets();
        bool ok;
        cast(void) nativeIo(() {
            auto updated = Swapchain.recreate(gpu.swapchain, gpu.vk, metrics.physicalSize, force);
            ok = !updated.hasError;
            if (!ok)
                whyNot(i"the native arm could not build a swapchain: $(updated.error)");
            return ok;
        });
        if (!ok)
            return false;
        gpu.views.create(gpu.vk, gpu.swapchain);
        const images = cast(uint) gpu.swapchain.images.length;
        const synced = gpu.sync.imageCount == 0 ? FrameSync.create(gpu.sync, gpu.vk, images)
            : gpu.sync.replaceImages(gpu.vk, images);
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
                applicationName: request.title, apiVersion: apiVersion13,
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
        gpu.destroy();
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
    input.capabilities = host.capabilities;
    input.touchGestures = touch;
    input.fractionalScroll = cfg.fractionalScroll;
    input.scale = metrics.scale.value;
    input.originX = metrics.safeInsets.left;
    input.originY = metrics.safeInsets.top;

    session.setCursor = (PointerShape s) { cast(void) wsi.setCursor(window, s); };
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
    // presented — its time and whether an event or the application asked
    // for it — so a run can show an idle window drawing nothing.
    import core.stdc.stdlib : getenv;
    const traceFrames = getenv("SPARKLES_NATIVE_TRACE_FRAMES") !is null;
    const opened = MonoTime.currTime;
    Duration now() => MonoTime.currTime - opened;
    uint presented;
    // `SPARKLES_NATIVE_LOSE_DEVICE_AT=<n>`: treat frame `n` as a lost
    // device, which no software driver produces on demand, so the rebuild
    // can be shown to redraw.
    import std.conv : to;
    import std.string : fromStringz;
    uint loseDeviceAt;
    if (const at = getenv("SPARKLES_NATIVE_LOSE_DEVICE_AT"))
        loseDeviceAt = (() @trusted => at.fromStringz.to!uint)();

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
                metrics = m;
                takeMetrics();
                input.scale = m.scale.value;
                input.originX = m.safeInsets.left;
                input.originY = m.safeInsets.top;
                if (const px = lc.metrics(surfaceOf(m)))
                    {
                    measure(px);
                    bindFont();
                }
            }
            e.payload.match!(
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
            gpu.destroy();
        if (plan.releaseSurface)
            releaseSurface();
        if (plan.releaseCaches && gpu.up)
            gpu.canvas.releaseCaches();
        if (plan.createDevice)
        {
            trace(i"native arm: rebuilding the device");
            gpu.destroy();
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
            if (!rebuildSwapchain(plan.createSurface))
            {
                lc.rebuildFailed(Rebuild.targets);
                continue;
            }
            lc.rebuilt(Rebuild.targets);
        }

        if (plan.draw)
        {
            const started = MonoTime.currTime;
            lastPass = started;
            buildFrame!present(host, plan.mustDraw);
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
            static if (__traits(hasMember, Wsi, "beginNativeIo"))
                if (wsi.beginNativeIo().hasError)
                {
                    lc.frameDone(FrameResult.again, now());
                    continue;
                }
            auto outcome = drawFrame!draw(*gpu, host, session, request.ground);
            static if (__traits(hasMember, Wsi, "beginNativeIo"))
                cast(void) wsi.endNativeIo();
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
                    if (traceFrames)
                        whyNot(i"native frame $(presented) at $((started - opened).total!"msecs") ms");
                    session.frameSeconds = lc.frameSeconds;
                    if (gpu.sync.hasRetired || gpu.swapchain.hasRetired)
                    {
                        gpu.sync.reap(gpu.vk, 8);
                        gpu.swapchain.reap(gpu.vk, 1);
                    }
                    break;
                case FrameOutcome.again:
                    lc.frameDone(FrameResult.again, now());
                    break;
                case FrameOutcome.rebuild:
                    lc.frameDone(FrameResult.outOfDate, now());
                    break;
                case FrameOutcome.deviceLost:
                    trace(i"native arm: the device was lost");
                    lc.frameDone(FrameResult.deviceLost, now());
                    break;
                case FrameOutcome.failed:
                    lc.frameDone(FrameResult.failed, now());
                    break;
            }
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
    input.flush((Event x) {
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

// Acquires an image, draws the host's operations and the draw phase into it,
// and presents it.
private FrameOutcome drawFrame(alias draw)(ref Gpu gpu, ref NativeHost host,
    ref NativeSession session, RgbColor ground) @system
{
    import sparkles.ui.interp.immediate : paint;

    auto vk = &gpu.vk;
    if (gpu.sync.waitForFrame(*vk).hasError)
        return FrameOutcome.deviceLost;
    uint index;
    const acquired = vk.device.acquireNextImageKHR(vk.device.device, gpu.swapchain.handle,
        ulong.max, gpu.sync.imageAvailable, null, &index);
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

    VkImage image = gpu.swapchain.images[index];
    gpu.canvas.beginFrame(CanvasTarget(image: image, view: gpu.views.views[index],
        format: gpu.swapchain.format, extent: gpu.swapchain.extent, usage: gpu.swapchain.usage,
        finalLayout: VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        turn: quarterTurns(gpu.swapchain.transform)), cmd, gpu.sync.frame,
        FrameMetrics(cellW: session.font.cellW, cellH: session.font.cellH,
            originX: session.insets.left, originY: session.insets.top,
            density: cast(float) session.scale), ground);
    paint(gpu.canvas, host.ops()[]);
    draw(host);
    auto ended = gpu.canvas.endFrame();
    FrameOutcome outcome = FrameOutcome.presented;
    if (ended.hasError)
    {
        if (ended.error == VkResult.VK_ERROR_DEVICE_LOST)
            return FrameOutcome.deviceLost;
        // Abandoned: the acquired image still has to be presented, so it
        // shows the ground, and the next frame draws again.
        clearTo(gpu, cmd, image, ground);
        outcome = FrameOutcome.again;
    }
    VkBuffer shot;
    GpuBuffer shotBuffer;
    if (session.shotPath.length && outcome == FrameOutcome.presented
        && (gpu.swapchain.usage & VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT))
        recordCapture(gpu, cmd, image, shotBuffer);
    if (gpu.commands.end(*vk, gpu.sync.frame).hasError)
        return FrameOutcome.deviceLost;
    const submitted = gpu.sync.submit(*vk, cmd, index);
    if (submitted.hasError)
        return submitted.error == VkResult.VK_ERROR_DEVICE_LOST ? FrameOutcome.deviceLost
            : FrameOutcome.failed;
    const presented = gpu.swapchain.present(*vk, index, gpu.sync.renderFinished(index));
    gpu.sync.advance();
    if (shotBuffer.handle !is null)
    {
        writeCapture(gpu, shotBuffer, session.shotPath);
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
private void clearTo(ref Gpu gpu, VkCommandBuffer cmd, VkImage image, RgbColor ground) @system
{
    auto device = &gpu.vk.device;
    transition(*device, cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
        VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT);
    VkClearColorValue colour;
    colour.float32 = [ground.r / 255.0f, ground.g / 255.0f, ground.b / 255.0f, 1];
    auto range = colourRange;
    device.cmdClearColorImage(cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        &colour, 1, &range);
    transition(*device, cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0);
}

// Copies the presentable image into a host-visible buffer, after the frame
// drew it and before it is presented.
private void recordCapture(ref Gpu gpu, VkCommandBuffer cmd, VkImage image,
    out GpuBuffer buffer) @system
{
    auto device = &gpu.vk.device;
    const extent = gpu.swapchain.extent;
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
private void writeCapture(ref Gpu gpu, ref GpuBuffer buffer, string path) @system
{
    import std.file : write;
    import sparkles.image.png : encodePng;

    scope (exit)
        buffer.destroy(gpu.vk.device, gpu.memory);
    gpu.vk.device.queueWaitIdle(gpu.vk.queue);
    const extent = gpu.swapchain.extent;
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
        void withText(Fn)(TextId id, scope Fn fn) => fn(texts[id.index], false);
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
