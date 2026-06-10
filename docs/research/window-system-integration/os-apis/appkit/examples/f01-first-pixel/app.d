// macOS/AppKit F01 demo — first pixel & init cost (../../../features/f01-first-pixel.md).
// Presents ONE software-drawn gradient frame and exits right after presentation is
// confirmed. Every initialization API call is logged as a `step name=…` event so the
// cost of each can be split out — in particular the first-WindowServer-connection
// cost (the scaffold saw CGMainDisplayID() alone take ~19 ms cold). Run the binary
// twice in a row to compare cold vs warm process starts. Findings:
// ../../f01-first-pixel.md; the subclassing recipe and build command come from
// ../../scaffold.md (this demo is the scaffold minus the resize storm, plus
// finer-grained init steps and an exit-on-first-pixel schedule).
//
// Modes (environment variables):
//   WSI_AUTO_EXIT=1  exit as soon as the first drawRect: has returned (first pixel
//                    presented); a ~16 ms NSTimer is the exit scheduler and a
//                    600-tick watchdog bounds the run if no draw ever arrives
//                    (exit code 1 in that case).
//   (neither)        runs until the window closes (windowWillClose: ->
//                    [NSApp terminate:]).
//
// Headless-safe: prints `SKIP:` and exits 0 when there is no window server
// (CGMainDisplayID() == 0), per the research-docs guidelines.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv, malloc, free;

import instrument : instr, instrInit, instrNowUs;
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
    double backingScaleFactor() @selector("backingScaleFactor");
}

// --- The custom NSView subclass, defined in D ----------------------------------
// A *non-extern* `extern (Objective-C)` class per the scaffold recipe: bodied
// @selector methods are the subclass implementation; bodyless alloc/initWithFrame
// bind to the inherited implementations; drawRect:/tick:/windowWillClose: are
// dispatched by selector and need no base declaration.
class GradientView : NSView
{
    static GradientView alloc() @selector("alloc");
    GradientView initWithFrame(NSRect frame) @selector("initWithFrame:");

    // AppKit's geometry callback to a view: the first call fires synchronously
    // inside setContentView: (our "first_configure"). Must forward to super or
    // the view never resizes.
    override void setFrameSize(NSSize newSize) @selector("setFrameSize:")
    {
        super.setFrameSize(newSize);
        onViewResized(newSize);
    }

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        onDrawRect(this.bounds());
    }

    void tick(NSTimer timer) @selector("tick:")
    {
        onTick(this);
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
__gshared int g_tick, g_frames;
__gshared bool g_auto;
__gshared bool g_firstConfigureSeen, g_firstDrawSeen, g_firstPixelSeen, g_stopRequested;
__gshared ulong g_firstPixelUs;

enum watchdogTicks = 600; // ~10 s upper bound if no drawRect: ever arrives

// Corner-anchored diagonal gradient (one frame is enough for F01).
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

void onViewResized(NSSize size)
{
    immutable double scale = g_win !is null ? g_win.backingScaleFactor() : 1.0;
    if (!g_firstConfigureSeen)
    {
        g_firstConfigureSeen = true;
        instr("first_configure", "size=%dx%d scale=%.1f",
            cast(int) size.width, cast(int) size.height, scale);
    }
    else
        instr("resize", "size=%dx%d scale=%.1f",
            cast(int) size.width, cast(int) size.height, scale);
}

void onDrawRect(NSRect bounds)
{
    // Split run-loop dispatch latency from render+blit cost: the entry of the
    // first drawRect: is its own step; first_pixel_presented is its *return*.
    if (!g_firstDrawSeen)
    {
        g_firstDrawSeen = true;
        instr("step", "name=first_drawRect_entered size=%dx%d",
            cast(int) bounds.size.width, cast(int) bounds.size.height);
    }

    immutable double scale = g_win.backingScaleFactor();
    immutable size_t pw = cast(size_t) (bounds.size.width * scale);
    immutable size_t ph = cast(size_t) (bounds.size.height * scale);
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
    if (!g_firstPixelSeen)
    {
        g_firstPixelSeen = true;
        g_firstPixelUs = instrNowUs();
        // "Presented" = return of the first drawRect:. This is the strongest
        // confirmation AppKit gives a software renderer — CoreAnimation may
        // still defer actual compositing to the end-of-cycle CATransaction
        // commit (the F04 frame-pacing demo's CADisplayLink/CVDisplayLink
        // territory), and with the console locked nothing is composited at all.
        instr("first_pixel_presented", "t=%d", g_frames);
    }
    instr("frame_callback", "t=%d", g_frames);
}

void onTick(GradientView view)
{
    ++g_tick;
    if (!g_auto)
        return;

    if (!g_firstPixelSeen)
    {
        // Belt and braces: the initial display pass should draw on its own, but
        // keep marking the view dirty until the first frame lands.
        view.setNeedsDisplay(true);
        if (g_tick < watchdogTicks)
            return;
        instr("watchdog_timeout", "ticks=%d", g_tick);
    }

    if (g_stopRequested)
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
    instrInit("APPKIT_F01");
    instr("init_start", "auto_exit=%d", g_auto ? 1 : 0);

    // Headless guard — and, per the scaffold finding, itself the *first
    // WindowServer round-trip*: the first call into CoreGraphics bootstraps the
    // connection (~19 ms cold), so its return is instrumented as its own step.
    instr("step", "name=CGMainDisplayID");
    immutable displayID = CGMainDisplayID();
    instr("step", "name=CGMainDisplayID_returned id=%u", displayID);
    if (displayID == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }

    // objective-d's autorelease pool wraps the AppKit setup; [NSApp run] drains
    // its own per-event pools.
    auto pool = autoreleasepool_push();
    scope (exit)
        autoreleasepool_pop(pool);

    // 1. The shared application object + activation policy.
    instr("step", "name=NSApplication_sharedApplication");
    g_app = NSApplication.sharedApplication();
    instr("step", "name=setActivationPolicy policy=regular");
    g_app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    // 2. A titled, closable, resizable window with a buffered backing store.
    //    alloc and the designated initializer are separate steps so the window
    //    *device* creation cost is visible on its own.
    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    instr("step", "name=NSWindow_alloc");
    NSWindow win = NSWindow.alloc();
    instr("step", "name=NSWindow_initWithContentRect size=480x320");
    g_win = win.initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    instr("step", "name=setTitle");
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f01"));
    instr("window_created", "scale=%.1f", g_win.backingScaleFactor());

    // 3. The D-defined NSView subclass becomes the content view; installing it
    //    triggers the first setFrameSize: (-> first_configure) *synchronously
    //    inside setContentView:*. It also serves as window delegate.
    instr("step", "name=GradientView_alloc");
    GradientView view = GradientView.alloc();
    instr("step", "name=GradientView_initWithFrame");
    view = view.initWithFrame(contentRect);
    instr("step", "name=setContentView");
    g_win.setContentView(view);
    instr("step", "name=setDelegate");
    g_win.setDelegate(view);

    // 4. Show + activate.
    instr("step", "name=makeKeyAndOrderFront");
    g_win.makeKeyAndOrderFront(null);
    instr("step", "name=activateIgnoringOtherApps");
    g_app.activateIgnoringOtherApps(true);

    // 5. A ~16 ms repeating NSTimer is the exit scheduler (and a dirty-mark
    //    fallback until the first frame). It is bookkeeping, not part of the
    //    draw path — the initial drawRect: arrives from the run loop's first
    //    drawing pass regardless.
    instr("step", "name=NSTimer_scheduledTimerWithTimeInterval interval_ms=16");
    NSTimer.scheduledTimerWithTimeInterval(0.016, view, SEL.register("tick:"),
        null, true);

    // 6. Cede the main thread to AppKit. The first drawRect: only arrives inside
    //    run — makeKeyAndOrderFront: paints nothing (scaffold finding).
    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "frames=%d ticks=%d first_pixel_us=%llu",
        g_frames, g_tick, g_firstPixelUs);
    free(g_buf);
    if (g_auto && !g_firstPixelSeen)
        return 1;
    return 0;
}
