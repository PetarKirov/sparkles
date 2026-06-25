// macOS/AppKit F02 demo — resize correctness (../../../features/f02-resize.md).
// A continuously refreshed, corner-anchored gradient survives a three-phase
// programmatic resize storm:
//   phase 1: eight setFrame:display:YES content-size changes (incl. odd sizes),
//   phase 2: three setContentSize: changes (the content-rect-first resize API),
//   phase 3: zoom: (a maximize-like state transition) and zoom: again to restore.
// Every geometry event is logged with BOTH the logical (point) and the physical
// (pixel, via convertRectToBacking:) size plus backingScaleFactor, and the demo
// asserts pixels == points × scale on each one (the Retina buffer-math deliverable).
// viewWillStartLiveResize/viewDidEndLiveResize and viewDidChangeBackingProperties
// are instrumented to prove which callbacks programmatic resizes do NOT trigger.
// Findings: ../../f02-resize.md; recipe and build command: ../../scaffold.md.
//
// Modes (environment variables):
//   WSI_AUTO_EXIT=1  bounded run: a ~16 ms NSTimer drives setNeedsDisplay:; the
//                    storm phases run on the tick schedule above; after ~135
//                    ticks [NSApp stop:nil] (plus a synthetic
//                    NSEventTypeApplicationDefined post) -> exit 0 (exit 1 if
//                    any point/pixel assertion failed).
//   (neither)        runs until the window closes — no storm, so a human can
//                    drag the window border and capture the *interactive*
//                    live-resize sequence (Tier C; see the manual-run queue).
//
// Headless-safe: prints `SKIP:` and exits 0 when there is no window server
// (CGMainDisplayID() == 0), per the research-docs guidelines.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv, malloc, free;

import instrument : instr, instrInit;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d

// Objective-C runtime selector lookup (objective-d wraps libobjc; declaring
// sel_registerName ourselves would clash with objc.rt's typed declaration).
import objc.rt : SEL;

// --- C-level declarations -----------------------------------------------------

// CoreGraphics C API — linked transitively via the Cocoa umbrella framework.
// CGRect has the same layout as NSRect (4 CGFloat = double on 64-bit), so the
// struct-by-value calls below reuse NSRect. The CF objects (CGColorSpaceRef,
// CGDataProviderRef, CGImageRef, CGContextRef) are opaque pointers.
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
    void CGContextDrawImage(void* ctx, NSRect rect, void* image);
}

enum uint kCGImageAlphaNoneSkipFirst = 6;       // XRGB: alpha byte present, ignored
enum uint kCGBitmapByteOrder32Little = 2 << 12; // 32-bit little-endian packing
enum int kCGRenderingIntentDefault = 0;

// Cocoa geometry (CGFloat == double on 64-bit). Plain C structs, not ObjC objects.
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

// --- AppKit class declarations (objective-d bundles Foundation, not AppKit) ----

extern (Objective-C):

extern class NSObject
{
    // `alloc` is declared on the leaf classes that need it (with their own return
    // type) to avoid an Objective-C covariant-return clash on the base method.
}

extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* s) @selector("initWithUTF8String:");
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
    void* CGContext() @selector("CGContext"); // CGContextRef
}

extern class NSApplication : NSResponder
{
    static NSApplication sharedApplication() @selector("sharedApplication");
    void setActivationPolicy(long policy) @selector("setActivationPolicy:");
    void activateIgnoringOtherApps(bool flag) @selector("activateIgnoringOtherApps:");
    void run() @selector("run");
    void stop(NSObject sender) @selector("stop:");
    void postEvent(NSEvent event, bool atStart) @selector("postEvent:atStart:");
    void terminate(NSObject sender) @selector("terminate:");
}

extern class NSView : NSResponder
{
    void setFrameSize(NSSize newSize) @selector("setFrameSize:");
    void setNeedsDisplay(bool flag) @selector("setNeedsDisplay:");
    NSRect bounds() @selector("bounds");
    NSRect convertRectToBacking(NSRect rect) @selector("convertRectToBacking:");
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
    void setFrame(NSRect frameRect, bool display) @selector("setFrame:display:");
    void setContentSize(NSSize size) @selector("setContentSize:");
    void zoom(NSObject sender) @selector("zoom:");
    bool isZoomed() @selector("isZoomed");
    NSRect frame() @selector("frame");
    NSRect frameRectForContentRect(NSRect contentRect) @selector("frameRectForContentRect:");
    double backingScaleFactor() @selector("backingScaleFactor");
}

// --- The custom NSView subclass, defined in D ----------------------------------
// A *non-extern* `extern (Objective-C)` class per the scaffold recipe: bodied
// @selector methods are the subclass implementation; bodyless alloc/initWithFrame
// bind to the inherited implementations. drawRect:/tick:/windowWillClose:/
// windowDidResize:/viewWillStartLiveResize/viewDidEndLiveResize/
// viewDidChangeBackingProperties are dispatched by selector and need no base
// declaration — defining them with the right @selector shadows the NSView/
// delegate defaults.
class GradientView : NSView
{
    static GradientView alloc() @selector("alloc");
    GradientView initWithFrame(NSRect frame) @selector("initWithFrame:");

    // AppKit's geometry callback to a view: the first call fires synchronously
    // inside setContentView: (our "first_configure"); every later call is one
    // `resize` event. Must forward to super or the view never resizes.
    override void setFrameSize(NSSize newSize) @selector("setFrameSize:")
    {
        super.setFrameSize(newSize);
        onViewResized(this, newSize);
    }

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        onDrawRect(this, this.bounds());
    }

    // Interactive (mouse-drag) resize brackets — instrumented to prove they do
    // NOT fire for programmatic setFrame:/setContentSize:/zoom: (F02 finding;
    // the interactive path is Tier C, see the manual-run queue).
    void viewWillStartLiveResize() @selector("viewWillStartLiveResize")
    {
        instr("live_resize_start");
    }

    void viewDidEndLiveResize() @selector("viewDidEndLiveResize")
    {
        instr("live_resize_end");
    }

    // Fires when the backing scale changes (e.g. window moved between a 1x and
    // a 2x display) — expected absent in this single-display storm.
    void viewDidChangeBackingProperties() @selector("viewDidChangeBackingProperties")
    {
        immutable double scale = g_win !is null ? g_win.backingScaleFactor() : 0.0;
        instr("backing_changed", "scale=%.1f", scale);
    }

    void tick(NSTimer timer) @selector("tick:")
    {
        onTick(this);
    }

    // NSWindowDelegate notification — ordering vs setFrameSize: is a finding.
    void windowDidResize(NSObject notification) @selector("windowDidResize:")
    {
        immutable f = g_win.frame();
        instr("window_did_resize", "frame=%dx%d zoomed=%d",
            cast(int) f.size.width, cast(int) f.size.height,
            g_win.isZoomed() ? 1 : 0);
    }

    void windowWillClose(NSObject notification) @selector("windowWillClose:")
    {
        instr("close_requested");
        g_app.terminate(null);
    }
}

extern (D): // back to D linkage for the rest of the module

enum NSApplicationActivationPolicyRegular = 0;
enum : ulong
{
    NSWindowStyleMaskTitled = 1,
    NSWindowStyleMaskClosable = 2,
    NSWindowStyleMaskResizable = 8,
}

enum ulong NSBackingStoreBuffered = 2;
enum long NSEventTypeApplicationDefined = 15;

// --- Demo state (single window — module globals keep the ObjC class trivial) ---

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared uint* g_buf;          // CPU framebuffer, 0xAARRGGBB (BGRA bytes, LE)
__gshared size_t g_bufW, g_bufH;
__gshared int g_tick, g_frames, g_resizesSeen, g_buffersAllocated, g_mismatches;
__gshared bool g_auto;
__gshared bool g_firstConfigureSeen, g_stopRequested;

// Phase 1 — setFrame:display:YES storm: eight content sizes, including odd
// point sizes (333x217, 415x289) to exercise the points->pixels rounding, ending
// back at the initial size.
immutable int[2][8] frameStormSizes = [
    [640, 400], [320, 240], [800, 520], [333, 217],
    [1024, 640], [415, 289], [560, 352], [480, 320],
];
enum frameStormStartTick = 30;

// Phase 2 — setContentSize: storm (resizes the content rect in place; the
// window's top-left is kept, so the *bottom* edge moves in AppKit's y-up space).
immutable int[2][3] contentStormSizes = [[600, 380], [280, 200], [480, 320]];
enum contentStormStartTick = 60;

enum stormStrideTicks = 3;
enum zoomTick = 75;             // zoom: #1 — maximize-like transition
enum unzoomTick = 95;           // zoom: #2 — restore the saved user frame
enum autoExitTick = 135;

// Corner-anchored diagonal gradient: geometry visibly tracks the window size
// (per F02 — stretching or a stale buffer is immediately visible).
void renderGradient(uint* buf, size_t w, size_t h) nothrow @nogc
{
    foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            immutable r = cast(uint) (x * 255 / w);
            immutable g = cast(uint) (y * 255 / h);
            immutable b = cast(uint) ((x + y) * 255 / (w + h));
            buf[y * w + x] = 0xFF00_0000 | (r << 16) | (g << 8) | b;
        }
}

// Round a point extent to pixels the way AppKit does (scale is 1.0 or 2.0, so
// this is exact for integer point sizes).
long pixelsFor(double points, double scale) nothrow @nogc
{
    return cast(long) (points * scale + 0.5);
}

void onViewResized(GradientView view, NSSize size)
{
    immutable double scale = g_win !is null ? g_win.backingScaleFactor() : 1.0;
    // Physical size as AppKit reports it (convertRectToBacking:) vs the naive
    // points × scale math — asserting they agree is the Retina deliverable.
    immutable backing = view.convertRectToBacking(NSRect(NSPoint(0, 0), size));
    immutable long pw = cast(long) backing.size.width;
    immutable long ph = cast(long) backing.size.height;
    immutable bool match = pw == pixelsFor(size.width, scale)
        && ph == pixelsFor(size.height, scale);
    if (!match)
        ++g_mismatches;

    if (!g_firstConfigureSeen)
    {
        g_firstConfigureSeen = true;
        instr("first_configure", "points=%dx%d pixels=%lldx%lld scale=%.1f match=%d",
            cast(int) size.width, cast(int) size.height, pw, ph, scale, match ? 1 : 0);
    }
    else
    {
        ++g_resizesSeen;
        instr("resize", "points=%dx%d pixels=%lldx%lld scale=%.1f match=%d",
            cast(int) size.width, cast(int) size.height, pw, ph, scale, match ? 1 : 0);
    }
}

void onDrawRect(GradientView view, NSRect bounds)
{
    // Buffer size from convertRectToBacking: — the authoritative points->pixels
    // mapping (identical to bounds × backingScaleFactor; asserted in
    // onViewResized on every geometry change).
    immutable backing = view.convertRectToBacking(bounds);
    immutable size_t pw = cast(size_t) backing.size.width;
    immutable size_t ph = cast(size_t) backing.size.height;
    if (pw == 0 || ph == 0)
        return;

    // Buffer strategy: per-resize free+malloc, no pooling — reallocation only
    // when the pixel size actually changed (an F02 finding; see ../../f02-resize.md).
    if (pw != g_bufW || ph != g_bufH)
    {
        free(g_buf);
        g_buf = cast(uint*) malloc(pw * ph * 4);
        g_bufW = pw;
        g_bufH = ph;
        ++g_buffersAllocated;
        instr("buffer_alloc", "size=%zux%zu bytes=%zu n=%d",
            pw, ph, pw * ph * 4, g_buffersAllocated);
    }
    renderGradient(g_buf, pw, ph);

    // Wrap the pixel buffer in a CGImage and draw it into the view's current
    // CGContext. The image is pw×ph *pixels* drawn into a points rect — Quartz
    // maps points->pixels via the context's CTM, so the blit is 1:1 on screen.
    void* cs = CGColorSpaceCreateDeviceRGB();
    void* dp = CGDataProviderCreateWithData(null, g_buf, pw * ph * 4, null);
    void* img = CGImageCreate(pw, ph, 8, 32, pw * 4, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, dp, null, false,
        kCGRenderingIntentDefault);
    void* ctx = NSGraphicsContext.currentContext().CGContext();
    CGContextDrawImage(ctx, bounds, img);
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);

    ++g_frames;
    instr("frame_callback", "t=%d points=%dx%d pixels=%zux%zu", g_frames,
        cast(int) bounds.size.width, cast(int) bounds.size.height, pw, ph);
}

void runStormStep(int tick)
{
    // Phase 1: setFrame:display:YES — frame rect computed from the content rect.
    immutable f1End = frameStormStartTick + cast(int) frameStormSizes.length * stormStrideTicks;
    if (tick >= frameStormStartTick && tick < f1End
        && (tick - frameStormStartTick) % stormStrideTicks == 0)
    {
        immutable size = frameStormSizes[(tick - frameStormStartTick) / stormStrideTicks];
        immutable content = NSRect(NSPoint(120, 120), NSSize(size[0], size[1]));
        instr("step", "name=setFrame_display size=%dx%d", size[0], size[1]);
        g_win.setFrame(g_win.frameRectForContentRect(content), true);
        return;
    }

    // Phase 2: setContentSize: — the content-rect-first API, no display flag.
    immutable f2End = contentStormStartTick + cast(int) contentStormSizes.length * stormStrideTicks;
    if (tick >= contentStormStartTick && tick < f2End
        && (tick - contentStormStartTick) % stormStrideTicks == 0)
    {
        immutable size = contentStormSizes[(tick - contentStormStartTick) / stormStrideTicks];
        instr("step", "name=setContentSize size=%dx%d", size[0], size[1]);
        g_win.setContentSize(NSSize(size[0], size[1]));
        return;
    }

    // Phase 3: zoom: twice — a maximize-like state transition and its restore.
    if (tick == zoomTick || tick == unzoomTick)
    {
        instr("step", "name=zoom pre_zoomed=%d", g_win.isZoomed() ? 1 : 0);
        g_win.zoom(null);
        instr("step", "name=zoom_returned zoomed=%d", g_win.isZoomed() ? 1 : 0);
    }
}

void onTick(GradientView view)
{
    ++g_tick;
    view.setNeedsDisplay(true); // continuous refresh; AppKit coalesces dirty marks

    if (!g_auto)
        return; // interactive mode: no storm — drag the border instead (Tier C)

    runStormStep(g_tick);

    if (g_tick < autoExitTick || g_stopRequested)
        return;
    g_stopRequested = true;
    instr("step", "name=NSApp_stop tick=%d", g_tick);
    g_app.stop(null);
    // stop: is only checked after an event is dispatched; without a real event
    // in the queue [NSApp run] would keep blocking. Post a synthetic
    // application-defined event so the loop wakes up and exits.
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true);
}

int main()
{
    g_auto = getenv("WSI_AUTO_EXIT") !is null;
    instrInit("APPKIT_F02");
    instr("init_start", "auto_exit=%d", g_auto ? 1 : 0);

    instr("step", "name=CGMainDisplayID");
    if (CGMainDisplayID() == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }

    // objective-d's autorelease pool wraps the AppKit setup; [NSApp run] drains
    // its own per-event pools.
    auto pool = autoreleasepool_push();
    scope (exit)
        autoreleasepool_pop(pool);

    instr("step", "name=NSApplication_sharedApplication");
    g_app = NSApplication.sharedApplication();
    instr("step", "name=setActivationPolicy policy=regular");
    g_app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    instr("step", "name=NSWindow_initWithContentRect size=480x320");
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f02"));
    instr("window_created", "scale=%.1f", g_win.backingScaleFactor());

    // The D-defined NSView subclass becomes the content view (first
    // setFrameSize: -> first_configure fires synchronously inside
    // setContentView:) and the window delegate (windowDidResize:/windowWillClose:).
    instr("step", "name=GradientView_initWithFrame");
    GradientView view = GradientView.alloc().initWithFrame(contentRect);
    instr("step", "name=setContentView");
    g_win.setContentView(view);
    g_win.setDelegate(view);

    instr("step", "name=makeKeyAndOrderFront");
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);

    // A ~16 ms repeating NSTimer drives setNeedsDisplay: and the storm schedule.
    instr("step", "name=NSTimer_scheduledTimerWithTimeInterval interval_ms=16");
    NSTimer.scheduledTimerWithTimeInterval(0.016, view, SEL.register("tick:"),
        null, true);

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "frames=%d ticks=%d resizes=%d buffers=%d mismatches=%d",
        g_frames, g_tick, g_resizesSeen, g_buffersAllocated, g_mismatches);
    free(g_buf);
    return g_mismatches == 0 ? 0 : 1;
}
