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
import sparkles.input : Event, InputCapabilities, mousePointer;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.effect : EffectRegistry;
import sparkles.ui.geometry : Size;
import sparkles.ui.image : ImageRegistry;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.gui_options : FontRequest, WindowCells;
import sparkles.ui_app.host : HostState, isHost, noDraw, noSetup, noShutdown, PointerUnit,
    RunConfig, withRealSize;
import sparkles.ui_app.wsi_input : WsiInput;
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
    import sparkles.font : cellMetrics, CellMetrics, charMap, fontErr, instance, InstanceSize,
        openFace, PointWorkspace, Ppem;
    import sparkles.raylib_text.font_discovery : FontSources;
    import sparkles.raylib_text.font_set : resolveFontPath;

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
    const metrics = at(line > 0 ? cast(int)((long(px) * px + line / 2) / line) : px);
    if (metrics.hasError)
        return false;
    cell = CellFont(path, px, cast(int)(metrics.value.width < 1 ? 1 : metrics.value.width),
        cast(int)(metrics.value.height < 1 ? 1 : metrics.value.height));
    return true;
}

/// Why the native arm did not open, on standard error: the run reports only
/// that it failed, and an application need not have set up a logger.
private void whyNot(Args...)(Args args) @system
{
    import std.conv : text;
    import std.stdio : stderr;

    stderr.writeln(text(args));
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
    CellFont font;           ///
    NativeCanvas* canvas;    ///
    float frameSeconds = 0;  /// how long the last frame took to build and submit
    string shotPath;         /// a screenshot to take on the next frame drawn
    void delegate(PointerShape) @system setCursor;           ///
    void delegate(scope const(char)[]) @system setClipboard; ///
    void delegate(int px) @system setFontSize;               ///
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
        => Size(cast(int)(session_.pixelW / session_.font.cellW),
            cast(int)(session_.pixelH / session_.font.cellH));

    /// ditto
    Backend backend() const @safe pure nothrow @nogc => Backend.gui;

    /// Seconds the last frame took — the clock an animation reads.
    float frameSeconds() const @safe pure nothrow @nogc => session_.frameSeconds;

    /// The cell font's pixel size, and the errand changing it (`HST14`):
    /// the cells are measured again, so `size` changes on its next read.
    int fontSizePx() const @safe pure nothrow @nogc => session_.font.px;
    /// ditto
    void fontSize(int px) @system => session_.setFontSize(px);

    /// The pointer's shape over the window (`IXB4`).
    void pointerShape(PointerShape shape) @system => session_.setCursor(shape);

    /// Offers `text` as the clipboard's (`HST8`).
    void clipboard(in char[] text) @system => session_.setClipboard(text);

    /// The window system offers no retitling yet; accepted and dropped.
    void title(in char[]) @safe pure nothrow @nogc {}

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
    version (linux)
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

    void remeasure()
    {
        CellFont font;
        if (measureCellFont(request.font, request.extraFontSources, pxAt(metrics.scale.value),
                font))
            session.font = font;
        session.scale = metrics.scale.value;
        session.pixelW = metrics.physicalSize.width;
        session.pixelH = metrics.physicalSize.height;
    }
    remeasure();

    // ── the device ──
    auto gpu = new Gpu;
    scope (exit)
        gpu.destroy();

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

    bool rebuildSwapchain(bool force)
    {
        if (metrics.suspended)
            return true;
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
        return gpu.sync.imageCount == 0
            ? !FrameSync.create(gpu.sync, gpu.vk, images).hasError
            : !gpu.sync.replaceImages(gpu.vk, images).hasError;
    }

    bool bringUp()
    {
        auto handles = wsi.nativeHandles(window);
        if (handles.hasError)
            return false;
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
        if (CommandPool.create(gpu.commands, gpu.vk, gpu.sync.framesInFlight).hasError)
            return false;
        CanvasConfig canvasConfig;
        canvasConfig.frameSlots = gpu.sync.framesInFlight;
        if (NativeCanvas.create(gpu.canvas, gpu.vk.device, gpu.memory,
                DeviceFacts.of(gpu.vk.base), canvasConfig).hasError)
            return false;
        session.canvas = &gpu.canvas;
        return true;
    }

    if (!bringUp())
    {
        whyNot(i"the native arm could not bring up Vulkan on the window");
        return false;
    }
    trace(i"native arm: $(gpu.vk.deviceName) $(gpu.swapchain.extent.width)x$(gpu.swapchain.extent.height), cells $(session.font.cellW)x$(session.font.cellH)");

    // ── the host ──
    NativeHost host;
    host.session_ = &session;
    host.capabilities.keyRelease = cfg.keyRelease;
    WsiInput input;
    input.capabilities = host.capabilities;
    input.fractionalScroll = cfg.fractionalScroll;
    input.scale = metrics.scale.value;

    bool dirty = true;
    session.setCursor = (PointerShape s) { cast(void) wsi.setCursor(window, s); };
    session.setClipboard = (scope const(char)[] text) {
        cast(void) wsi.offerClipboard(window, "text/plain;charset=utf-8",
            cast(const(ubyte)[]) text);
    };
    session.setFontSize = (int px) {
        CellFont font;
        if (measureCellFont(request.font, request.extraFontSources, px, font))
        {
            session.font = font;
            dirty = true;
        }
    };

    scope (exit)
        shutdown(host);
    setup(host);

    const unitW = () => cfg.pointerUnit == PointerUnit.pixels ? 1 : session.font.cellW;
    const unitH = () => cfg.pointerUnit == PointerUnit.pixels ? 1 : session.font.cellH;

    bool frameReady = true, resized, freshSurface = true, wanted;
    // `SPARKLES_NATIVE_TRACE_FRAMES`: a line on standard error per frame
    // presented — its time and whether an event or the application asked
    // for it — so a run can show an idle window drawing nothing.
    import core.stdc.stdlib : getenv;
    const traceFrames = getenv("SPARKLES_NATIVE_TRACE_FRAMES") !is null;
    const opened = MonoTime.currTime;
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
    // to the application.
    void drainEvents()
    {
        cast(void) wsi.drain((WindowEvent e) @trusted {
            // `@trusted` for the one call it exists for: the WSI asks for a
            // `@safe` sink, and the event goes to the application, whose
            // handler it cannot vouch for. Text is read only here (`ED8`).
            if (e.window != window && e.window != WindowId.init)
                return;
            bool input_ = true;
            e.payload.match!(
                (in ReadyEvent r) { metrics = r.metrics; resized = true; },
                (in SurfaceMetricsChangedEvent m) { metrics = m.metrics; resized = true; },
                (in FrameReadyEvent _) { frameReady = true; input_ = false; },
                (in ExposedEvent _) { dirty = true; input_ = false; },
                (in CloseRequestedEvent _) { closeRequested = true; input_ = false; },
                (in MemoryPressureEvent _) { gpu.canvas.releaseCaches(); input_ = false; },
                (in _) {});
            if (resized)
                remeasure();
            if (input_)
                deliverInput!handle(host, input, wsi, e, unitW(), unitH(), dirty);
        });
        flushInput!handle(host, input, dirty);
    }

    while (!closeRequested && !host.quitRequested)
    {
        // Park until the window system has something, or the application's
        // next deadline. A frame that is wanted and may be drawn now waits
        // for nothing.
        const want = dirty || wanted;
        Duration timeout = want && (frameReady || !paced) ? Duration.zero : 1.seconds;
        if (!want && host.wakeAsk < timeout)
            timeout = host.wakeAsk;
        if (cfg.idleTimeoutMs >= 0 && cfg.idleTimeoutMs.msecs < timeout)
            timeout = cfg.idleTimeoutMs.msecs;
        if (wsi.runIntegratedOnce(loop, timeout).hasError)
            break;
        drainEvents();
        if (closeRequested || host.quitRequested)
            break;
        if (resized)
        {
            resized = false;
            input.scale = metrics.scale.value;
            if (!rebuildSwapchain(false))
                break;
            dirty = true;
        }
        if (timeout != Duration.zero && !dirty && !wanted)
        {
            // A wake with nothing to draw is still a frame pass for an
            // application that asked to be woken (`HST16`).
            if (host.wakeAsk == Duration.max && cfg.idleTimeoutMs < 0)
                continue;
            dirty = true;
        }
        if (!(dirty || wanted) || (paced && !frameReady) || metrics.suspended)
            continue;

        const started = MonoTime.currTime;
        const cause = dirty ? "event" : "request";
        dirty = false;
        buildFrame!present(host, freshSurface);
        wanted = host.frameRequested;
        if (host.frameSkipped)
            continue;

        auto outcome = drawFrame!draw(*gpu, host, session, request.ground);
        if (presented + 1 == loseDeviceAt)
        {
            loseDeviceAt = 0;
            outcome = FrameOutcome.deviceLost;
        }
        if (outcome == FrameOutcome.deviceLost)
        {
            trace(i"native arm: the device was lost; rebuilding it");
            gpu.destroy();
            if (!bringUp())
                break;
            dirty = true;
            continue;
        }
        if (outcome == FrameOutcome.failed)
            break;
        if (outcome == FrameOutcome.rebuild)
        {
            if (!rebuildSwapchain(true))
                break;
            dirty = true;
            continue;
        }
        if (outcome == FrameOutcome.again)
            dirty = true;
        freshSurface = false;
        frameReady = false;
        ++presented;
        if (traceFrames)
            whyNot(i"native frame $(presented) at $((started - opened).total!"msecs") ms ($(cause))");
        session.frameSeconds = (MonoTime.currTime - started).total!"usecs" / 1e6f;
        if (gpu.sync.hasRetired || gpu.swapchain.hasRetired)
        {
            gpu.sync.reap(gpu.vk, 8);
            gpu.swapchain.reap(gpu.vk, 1);
        }
    }
    return true;
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
        finalLayout: VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR), cmd, gpu.sync.frame,
        FrameMetrics(cellW: session.font.cellW, cellH: session.font.cellH,
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
    import sparkles.ui_app.png : encodePng;

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
