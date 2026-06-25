// macOS/AppKit F08 demo — DPI / backingScaleFactor (../../../features/f08-dpi-scaling.md).
// Where the scale lives, when it becomes learnable, and what AppKit pre-scales for a
// software renderer. Built on the scaffold/f02 recipe; the run findings are A[ssh]
// (locked console — no monitor drag possible; that path is Tier C).
//
// What it logs:
//   - every scale source: NSScreen.screens (per-screen backingScaleFactor + frame),
//     NSWindow.backingScaleFactor, NSView convertRectToBacking:, and the CALayer
//     contentsScale during a brief wantsLayer=YES probe;
//   - the created-at-wrong-scale timeline with µs timestamps: window scale at
//     initWithContentRect return, the VIEW's pre-install conversion scale (a windowless
//     view converts at 1.0), and viewDidChangeBackingProperties firing 1.0 -> 2.0
//     synchronously inside setContentView: — plus a counter proving nothing else
//     triggers it headless (resizes, ordering, an off-screen setFrameOrigin:);
//   - convertRectToBacking:/convertRectFromBacking: round-trips, incl. odd and
//     fractional point sizes;
//   - drawRect: ground truth: CGContextGetCTM of the view's context — the transform
//     AppKit pre-installs so points-rect drawing lands on device pixels;
//   - the deliberately-mismatched probe: one frame draws a 1.0-scale (points-sized)
//     CGImage into the 2.0 view — same points rect, half the pixels, so Quartz
//     resamples it x2 (the classic blurry-stretch); the CGImage size vs CTM scale is
//     the app-observable evidence;
//   - per-resize buffer math assert pixels == points x scale (the f02 invariant);
//     1-physical-px hairlines (1/scale-point rects) at the window edges;
//   - runtime-rescale observability: registration for
//     NSApplicationDidChangeScreenParametersNotification and
//     NSWindowDidChangeBackingPropertiesNotification (with the old-scale userInfo key),
//     which would fire on a display config change / monitor drag (Tier C).
//
// Modes: WSI_AUTO_EXIT=1 = bounded scripted run (exit 1 on any math mismatch);
// without it the window stays up for a manual monitor-drag session.
// Headless-safe: prints `SKIP:` and exits 0 when there is no window server.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv, malloc, free;

import instrument : instr, instrInit;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d
import objc.rt : SEL;

// --- C-level declarations ---------------------------------------------------------

extern (C) struct CGAffineTransform
{
    double a, b, c, d, tx, ty;
}

extern (C) nothrow @nogc
{
    uint CGMainDisplayID();
    void* CGColorSpaceCreateDeviceRGB();
    void CGColorSpaceRelease(void* space);
    void* CGDataProviderCreateWithData(void* info, const(void)* data, size_t size,
        void* releaseCallback);
    void CGDataProviderRelease(void* provider);
    void* CGImageCreate(size_t width, size_t height, size_t bitsPerComponent,
        size_t bitsPerPixel, size_t bytesPerRow, void* colorSpace, uint bitmapInfo,
        void* provider, const(double)* decode, bool shouldInterpolate, int intent);
    void CGImageRelease(void* image);
    size_t CGImageGetWidth(void* image);
    size_t CGImageGetHeight(void* image);
    void CGContextDrawImage(void* ctx, NSRect rect, void* image);
    void CGContextSetRGBFillColor(void* ctx, double r, double g, double b, double a);
    void CGContextFillRect(void* ctx, NSRect rect);
    CGAffineTransform CGContextGetCTM(void* ctx);

    // AppKit-exported notification-name / userInfo-key constants (NSString*).
    extern __gshared void* NSApplicationDidChangeScreenParametersNotification;
    extern __gshared void* NSWindowDidChangeBackingPropertiesNotification;
    extern __gshared void* NSBackingPropertyOldScaleFactorKey;
}

enum uint kCGImageAlphaNoneSkipFirst = 6;
enum uint kCGBitmapByteOrder32Little = 2 << 12;
enum int kCGRenderingIntentDefault = 0;

extern (C) struct NSPoint
{
    double x, y;
}

extern (C) struct NSSize
{
    double width, height;
}

extern (C) struct NSRect
{
    NSPoint origin;
    NSSize size;
}

// --- AppKit class declarations ----------------------------------------------------

extern (Objective-C):

extern class NSObject
{
}

extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* s) @selector("initWithUTF8String:");
    const(char)* UTF8String() @selector("UTF8String");
}

extern class NSArray : NSObject
{
    ulong count() @selector("count");
    NSObject objectAtIndex(ulong index) @selector("objectAtIndex:");
}

extern class NSNumber : NSObject
{
    double doubleValue() @selector("doubleValue");
}

extern class NSDictionary : NSObject
{
    NSObject objectForKey(NSObject key) @selector("objectForKey:");
}

extern class NSNotification : NSObject
{
    NSDictionary userInfo() @selector("userInfo");
}

extern class NSNotificationCenter : NSObject
{
    static NSNotificationCenter defaultCenter() @selector("defaultCenter");
    void addObserver(NSObject observer, SEL sel, NSObject name, NSObject obj)
        @selector("addObserver:selector:name:object:");
    void postNotificationName(NSObject name, NSObject obj)
        @selector("postNotificationName:object:");
}

extern class NSScreen : NSObject
{
    static NSArray screens() @selector("screens");
    static NSScreen mainScreen() @selector("mainScreen");
    double backingScaleFactor() @selector("backingScaleFactor");
    NSRect frame() @selector("frame");
    NSString localizedName() @selector("localizedName");
}

extern class CALayer : NSObject
{
    double contentsScale() @selector("contentsScale");
}

extern class NSResponder : NSObject
{
}

extern class NSEvent : NSObject
{
    static NSEvent otherEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, short subtype,
        long data1, long data2)
        @selector("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
}

extern class NSTimer : NSObject
{
    static NSTimer scheduledTimerWithTimeInterval(double interval, NSObject target,
        SEL sel, NSObject userInfo, bool repeats)
        @selector("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:");
}

extern class NSGraphicsContext : NSObject
{
    static NSGraphicsContext currentContext() @selector("currentContext");
    void* CGContext() @selector("CGContext");
}

extern class NSApplication : NSResponder
{
    static NSApplication sharedApplication() @selector("sharedApplication");
    void setActivationPolicy(long policy) @selector("setActivationPolicy:");
    void activateIgnoringOtherApps(bool flag) @selector("activateIgnoringOtherApps:");
    void run() @selector("run");
    void stop(NSObject sender) @selector("stop:");
    void postEvent(NSEvent event, bool atStart) @selector("postEvent:atStart:");
}

extern class NSView : NSResponder
{
    void setFrameSize(NSSize newSize) @selector("setFrameSize:");
    void setNeedsDisplay(bool flag) @selector("setNeedsDisplay:");
    NSRect bounds() @selector("bounds");
    NSRect convertRectToBacking(NSRect rect) @selector("convertRectToBacking:");
    NSRect convertRectFromBacking(NSRect rect) @selector("convertRectFromBacking:");
    void setWantsLayer(bool flag) @selector("setWantsLayer:");
    CALayer layer() @selector("layer");
    NSWindow window() @selector("window");
}

extern class NSWindow : NSResponder
{
    static NSWindow alloc() @selector("alloc");
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer) @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void setContentView(NSView view) @selector("setContentView:");
    void setDelegate(NSObject anObject) @selector("setDelegate:");
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
    void setContentSize(NSSize size) @selector("setContentSize:");
    void setFrameOrigin(NSPoint point) @selector("setFrameOrigin:");
    NSRect frame() @selector("frame");
    double backingScaleFactor() @selector("backingScaleFactor");
    NSScreen screen() @selector("screen");
    NSRect convertRectToBacking(NSRect rect) @selector("convertRectToBacking:");
}

// The instrumented view: scale-aware CPU blit + CTM logging + the mismatch probe.
class ScaleView : NSView
{
    static ScaleView alloc() @selector("alloc");
    ScaleView initWithFrame(NSRect frame) @selector("initWithFrame:");

    override void setFrameSize(NSSize newSize) @selector("setFrameSize:")
    {
        super.setFrameSize(newSize);
        onViewResized(this, newSize);
    }

    // The scale-migration signal. Counted + timestamped: the only firing expected in
    // this headless run is the 1.0 -> 2.0 flip inside setContentView:.
    void viewDidChangeBackingProperties() @selector("viewDidChangeBackingProperties")
    {
        ++g_backingChanges;
        NSWindow w = this.window();
        immutable scale = w !is null ? w.backingScaleFactor() : 0.0;
        immutable b = this.convertRectToBacking(NSRect(NSPoint(0, 0), NSSize(100, 100)));
        instr("backing_changed", "n=%d window_scale=%.1f view_converts_100pt_to=%.0fpx phase=%s",
            g_backingChanges, scale, b.size.width, g_phase);
    }

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        onDrawRect(this, this.bounds());
    }

    void tick(NSTimer timer) @selector("tick:")
    {
        onTick(this);
    }

    // Would fire on any display configuration change (resolution/scale/arrangement,
    // monitor plug/unplug) — the app-level runtime-rescale signal. Registration is
    // the headless deliverable; an actual firing needs Tier C.
    void screenParamsChanged(NSNotification n) @selector("screenParamsChanged:")
    {
        instr("screen_params_changed", "phase=%s", g_phase);
        logScreens("notification");
    }

    // Window-level backing change notification; userInfo carries the OLD scale.
    void windowBackingChanged(NSNotification n) @selector("windowBackingChanged:")
    {
        double oldScale = 0;
        NSDictionary info = n.userInfo();
        if (info !is null)
        {
            auto num = cast(NSNumber) info.objectForKey(
                cast(NSObject) NSBackingPropertyOldScaleFactorKey);
            if (num !is null)
                oldScale = num.doubleValue();
        }
        instr("window_backing_changed", "old_scale=%.1f new_scale=%.1f phase=%s",
            oldScale, g_win !is null ? g_win.backingScaleFactor() : 0.0, g_phase);
    }

    void windowWillClose(NSObject notification) @selector("windowWillClose:")
    {
        instr("close_requested");
        g_app.stop(null);
    }
}

extern (D): // back to D linkage

enum NSApplicationActivationPolicyRegular = 0;
enum : ulong
{
    NSWindowStyleMaskTitled = 1,
    NSWindowStyleMaskClosable = 2,
    NSWindowStyleMaskResizable = 8,
}

enum ulong NSBackingStoreBuffered = 2;
enum long NSEventTypeApplicationDefined = 15;

// --- Demo state --------------------------------------------------------------------

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared uint* g_buf;
__gshared size_t g_bufW, g_bufH;
__gshared int g_tick, g_frames, g_backingChanges, g_mismatches;
__gshared bool g_auto, g_stopRequested, g_firstConfigureSeen;
__gshared bool g_probeMismatch; // next drawRect uses a 1.0-scale (points-sized) buffer
__gshared CGAffineTransform g_lastCtm;
__gshared bool g_ctmLogged, g_ctmVsBackingLogged;
__gshared const(char)* g_phase = "setup";

// Schedule (ticks of a ~16 ms timer).
immutable int[2][3] resizeSizes = [[640, 400], [333, 217], [480, 320]];
enum resizeStartTick = 20;
enum resizeStrideTicks = 8;
enum mismatchProbeTick = 50;
enum offscreenMoveTick = 60;
enum moveBackTick = 70;
enum observerSelftestTick = 78;
enum autoExitTick = 85;

void renderGradient(uint* buf, size_t w, size_t h) nothrow @nogc
{
    foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            immutable r = cast(uint)(x * 255 / w);
            immutable g = cast(uint)(y * 255 / h);
            immutable b = cast(uint)((x + y) * 255 / (w + h));
            buf[y * w + x] = 0xFF00_0000 | (r << 16) | (g << 8) | b;
        }
}

long pixelsFor(double points, double scale) nothrow @nogc
{
    return cast(long)(points * scale + 0.5);
}

void logScreens(const(char)* when)
{
    NSArray screens = NSScreen.screens();
    immutable n = screens !is null ? screens.count() : 0;
    instr("screens", "when=%s count=%llu", when, n);
    foreach (i; 0 .. n)
    {
        auto s = cast(NSScreen) screens.objectAtIndex(i);
        immutable f = s.frame();
        NSString name = s.localizedName();
        instr("screen", "idx=%llu scale=%.1f frame=(%.0f,%.0f %.0fx%.0f) name=\"%s\"",
            i, s.backingScaleFactor(), f.origin.x, f.origin.y, f.size.width,
            f.size.height, name !is null ? name.UTF8String() : "");
    }
    NSScreen main = NSScreen.mainScreen();
    if (main !is null)
        instr("screen", "idx=main scale=%.1f", main.backingScaleFactor());
}

// convertRectToBacking:/convertRectFromBacking: round-trips, incl. odd + fractional
// point sizes — the points <-> pixels unit conversion contract.
void roundTrips(ScaleView view)
{
    immutable double[2][4] sizes = [[480.0, 320.0], [333.0, 217.0], [100.5, 50.25],
        [1.0, 1.0]];
    foreach (sz; sizes)
    {
        immutable pt = NSRect(NSPoint(0, 0), NSSize(sz[0], sz[1]));
        immutable px = view.convertRectToBacking(pt);
        immutable back = view.convertRectFromBacking(px);
        immutable ok = back.size.width == pt.size.width && back.size.height == pt.size.height;
        if (!ok)
            ++g_mismatches;
        instr("round_trip", "points=%.2fx%.2f -> pixels=%.2fx%.2f -> points=%.2fx%.2f exact=%d",
            pt.size.width, pt.size.height, px.size.width, px.size.height,
            back.size.width, back.size.height, ok ? 1 : 0);
    }
    // The window-level converter answers the same question pre-contentView.
    immutable wpx = g_win.convertRectToBacking(NSRect(NSPoint(0, 0), NSSize(100, 100)));
    instr("round_trip", "window_converts_100pt_to=%.0fpx", wpx.size.width);
}

// Brief wantsLayer probe: what contentsScale does AppKit hand the backing layer?
void layerProbe(ScaleView view)
{
    instr("layer_probe", "stage=before layer=%s",
        view.layer() !is null ? "non-nil".ptr : "nil".ptr);
    view.setWantsLayer(true);
    CALayer layer = view.layer();
    instr("layer_probe", "stage=wants_layer layer=%s contents_scale=%.1f",
        layer !is null ? "non-nil".ptr : "nil".ptr,
        layer !is null ? layer.contentsScale() : 0.0);
    view.setWantsLayer(false);
    instr("layer_probe", "stage=after_revert layer=%s",
        view.layer() !is null ? "non-nil".ptr : "nil".ptr);
}

void onViewResized(ScaleView view, NSSize size)
{
    NSWindow w = view.window();
    immutable backing = view.convertRectToBacking(NSRect(NSPoint(0, 0), size));
    immutable pw = cast(long) backing.size.width;
    immutable ph = cast(long) backing.size.height;
    if (w is null)
    {
        // The first setFrameSize: fires inside setContentView: BEFORE the view's
        // window link is established — informational, not a math failure.
        instr(g_firstConfigureSeen ? "resize".ptr : "first_configure".ptr,
            "points=%dx%d pixels=%lldx%lld window=nil",
            cast(int) size.width, cast(int) size.height, pw, ph);
    }
    else
    {
        immutable scale = w.backingScaleFactor();
        immutable match = pw == pixelsFor(size.width, scale)
            && ph == pixelsFor(size.height, scale);
        if (!match)
            ++g_mismatches;
        instr(g_firstConfigureSeen ? "resize".ptr : "first_configure".ptr,
            "points=%dx%d pixels=%lldx%lld scale=%.1f match=%d",
            cast(int) size.width, cast(int) size.height, pw, ph, scale, match ? 1 : 0);
    }
    g_firstConfigureSeen = true;
}

void logCtmIfChanged(void* ctx, const(char)* when)
{
    immutable ctm = CGContextGetCTM(ctx);
    if (g_ctmLogged && ctm == g_lastCtm)
        return;
    g_lastCtm = ctm;
    g_ctmLogged = true;
    instr("ctm", "when=%s a=%.2f b=%.2f c=%.2f d=%.2f tx=%.2f ty=%.2f", when,
        ctm.a, ctm.b, ctm.c, ctm.d, ctm.tx, ctm.ty);
}

void onDrawRect(ScaleView view, NSRect bounds)
{
    void* ctx = NSGraphicsContext.currentContext().CGContext();
    logCtmIfChanged(ctx, "drawRect"); // THE ground truth of what AppKit pre-scales

    NSWindow w = view.window();
    immutable scale = w !is null ? w.backingScaleFactor() : 1.0;
    if (!g_ctmVsBackingLogged && g_lastCtm.a != scale)
    {
        g_ctmVsBackingLogged = true;
        instr("ctm_vs_backing", "ctm_a=%.1f backing_scale=%.1f note=context_scale_disagrees_with_geometry_scale",
            g_lastCtm.a, scale);
    }
    immutable backing = view.convertRectToBacking(bounds);
    // Buffer size: backing pixels normally; points (1.0-scale) for the mismatch probe.
    immutable pw = g_probeMismatch ? cast(size_t) bounds.size.width
        : cast(size_t) backing.size.width;
    immutable ph = g_probeMismatch ? cast(size_t) bounds.size.height
        : cast(size_t) backing.size.height;
    if (pw == 0 || ph == 0)
        return;

    if (pw != g_bufW || ph != g_bufH)
    {
        free(g_buf);
        g_buf = cast(uint*) malloc(pw * ph * 4);
        g_bufW = pw;
        g_bufH = ph;
        instr("buffer_alloc", "size=%zux%zu bytes=%zu", pw, ph, pw * ph * 4);
    }
    renderGradient(g_buf, pw, ph);

    void* cs = CGColorSpaceCreateDeviceRGB();
    void* dp = CGDataProviderCreateWithData(null, g_buf, pw * ph * 4, null);
    void* img = CGImageCreate(pw, ph, 8, 32, pw * 4, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, dp, null, false,
        kCGRenderingIntentDefault);
    CGContextDrawImage(ctx, bounds, img);

    if (g_probeMismatch)
    {
        // App-observable mismatch evidence: the CGImage is points-sized while the CTM
        // maps the same points rect onto scale x as many device pixels -> Quartz
        // resamples (stretches) the image x scale. On screen: blurry.
        instr("mismatch_probe",
            "img_px=%zux%zu rect_pt=%.0fx%.0f ctm_scale=%.1f device_px=%.0fx%.0f note=resampled_x%.1f_blurry",
            CGImageGetWidth(img), CGImageGetHeight(img), bounds.size.width,
            bounds.size.height, g_lastCtm.a, bounds.size.width * g_lastCtm.a,
            bounds.size.height * g_lastCtm.a, g_lastCtm.a);
        g_probeMismatch = false;
        g_bufW = g_bufH = 0; // force a realloc back to backing size next frame
    }
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);

    // Crisp 1-physical-px hairlines at the window edges: thickness 1/scale POINTS.
    // With the CTM pre-scale (x scale) that is exactly one device pixel.
    immutable hl = 1.0 / scale;
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, NSRect(NSPoint(0, 0), NSSize(bounds.size.width, hl)));
    CGContextFillRect(ctx, NSRect(NSPoint(0, bounds.size.height - hl),
        NSSize(bounds.size.width, hl)));
    CGContextFillRect(ctx, NSRect(NSPoint(0, 0), NSSize(hl, bounds.size.height)));
    CGContextFillRect(ctx, NSRect(NSPoint(bounds.size.width - hl, 0),
        NSSize(hl, bounds.size.height)));
    if (g_frames == 0)
        instr("hairline", "thickness_pt=%.2f device_px=%.1f", hl, hl * g_lastCtm.a);

    ++g_frames;
}

void onTick(ScaleView view)
{
    ++g_tick;
    view.setNeedsDisplay(true);
    if (!g_auto)
        return; // interactive mode: keep the window up for a manual monitor drag

    immutable rEnd = resizeStartTick + cast(int) resizeSizes.length * resizeStrideTicks;
    if (g_tick >= resizeStartTick && g_tick < rEnd
        && (g_tick - resizeStartTick) % resizeStrideTicks == 0)
    {
        immutable size = resizeSizes[(g_tick - resizeStartTick) / resizeStrideTicks];
        g_phase = "resize_storm";
        instr("step", "name=setContentSize size=%dx%d", size[0], size[1]);
        g_win.setContentSize(NSSize(size[0], size[1]));
    }
    else if (g_tick == mismatchProbeTick)
    {
        g_phase = "mismatch_probe";
        instr("step", "name=mismatch_probe note=next_frame_draws_points_sized_buffer");
        g_probeMismatch = true;
    }
    else if (g_tick == offscreenMoveTick)
    {
        // A hypothetical second screen: with none attached, what does AppKit do with
        // an off-screen frame origin, and does any backing/screen change fire?
        g_phase = "offscreen_move";
        instr("step", "name=setFrameOrigin origin=(5000,100) note=no_second_screen");
        g_win.setFrameOrigin(NSPoint(5000, 100));
        immutable f = g_win.frame();
        NSScreen scr = g_win.screen();
        instr("offscreen_result", "frame=(%.0f,%.0f %.0fx%.0f) screen=%s scale=%.1f backing_changes=%d",
            f.origin.x, f.origin.y, f.size.width, f.size.height,
            scr !is null ? "non-nil".ptr : "nil".ptr,
            g_win.backingScaleFactor(), g_backingChanges);
    }
    else if (g_tick == moveBackTick)
    {
        g_phase = "move_back";
        instr("step", "name=setFrameOrigin origin=(120,120)");
        g_win.setFrameOrigin(NSPoint(120, 120));
    }
    else if (g_tick == observerSelftestTick)
    {
        // Prove the notification observers are wired (nothing fires them headless):
        // post the screen-params notification by hand and expect the handler to log.
        g_phase = "observer_selftest";
        instr("step", "name=post_didChangeScreenParameters note=selftest");
        NSNotificationCenter.defaultCenter().postNotificationName(
            cast(NSObject) NSApplicationDidChangeScreenParametersNotification, null);
    }
    else if (g_tick >= autoExitTick && !g_stopRequested)
    {
        g_stopRequested = true;
        instr("step", "name=NSApp_stop tick=%d", g_tick);
        g_app.stop(null);
        NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
            NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
        g_app.postEvent(ev, true); // stop: needs an event dispatch to take effect
    }
}

int main()
{
    g_auto = getenv("WSI_AUTO_EXIT") !is null;
    instrInit("APPKIT_F08");
    instr("init_start", "auto_exit=%d", g_auto ? 1 : 0);

    if (CGMainDisplayID() == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }

    auto pool = autoreleasepool_push();
    scope (exit)
        autoreleasepool_pop(pool);

    g_app = NSApplication.sharedApplication();
    g_app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    logScreens("startup");

    // --- created-at-wrong-scale timeline (timestamps are the instr() µs column) ----
    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    instr("timeline", "t=window_init_call size=480x320");
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    NSScreen wscr = g_win.screen();
    instr("timeline", "t=window_init_return window_scale=%.1f screen_scale=%.1f",
        g_win.backingScaleFactor(), wscr !is null ? wscr.backingScaleFactor() : 0.0);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f08-dpi"));

    ScaleView view = ScaleView.alloc().initWithFrame(contentRect);
    immutable preInstall = view.convertRectToBacking(NSRect(NSPoint(0, 0), NSSize(100, 100)));
    instr("timeline", "t=view_pre_install view_converts_100pt_to=%.0fpx window=%s",
        preInstall.size.width, view.window() !is null ? "non-nil".ptr : "nil".ptr);

    // Notification registrations BEFORE setContentView: so any backing flip is caught.
    NSNotificationCenter nc = NSNotificationCenter.defaultCenter();
    nc.addObserver(view, SEL.register("screenParamsChanged:"),
        cast(NSObject) NSApplicationDidChangeScreenParametersNotification, null);
    nc.addObserver(view, SEL.register("windowBackingChanged:"),
        cast(NSObject) NSWindowDidChangeBackingPropertiesNotification, null);
    instr("step", "name=notification_observers registered=didChangeScreenParameters,windowDidChangeBackingProperties");

    instr("timeline", "t=setContentView_call");
    g_win.setContentView(view);
    g_win.setDelegate(view);
    instr("timeline", "t=setContentView_return backing_changes=%d", g_backingChanges);

    instr("step", "name=makeKeyAndOrderFront");
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);
    instr("timeline", "t=after_order_front backing_changes=%d", g_backingChanges);

    roundTrips(view);
    layerProbe(view);

    g_phase = "run";
    instr("step", "name=NSTimer_scheduledTimerWithTimeInterval interval_ms=16");
    NSTimer.scheduledTimerWithTimeInterval(0.016, view, SEL.register("tick:"), null, true);

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "frames=%d ticks=%d backing_changes=%d mismatches=%d",
        g_frames, g_tick, g_backingChanges, g_mismatches);
    free(g_buf);
    return g_mismatches == 0 ? 0 : 1;
}
