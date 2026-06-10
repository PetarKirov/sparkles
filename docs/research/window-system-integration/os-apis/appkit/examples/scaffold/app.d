// macOS/AppKit windowing scaffold — ../../example/app.d evolved into a full demo:
// a custom NSView subclass (defined **in D** via `extern (Objective-C)`) whose
// `drawRect:` blits a CPU-rendered gradient through CoreGraphics, an NSTimer-driven
// redraw loop inside `[NSApp run]`, a programmatic `setFrame:display:` resize storm,
// and clean termination. Instrumented per ../../../features/f01-first-pixel.md and
// ../../../features/f02-resize.md via instrument.d. Findings: ../../scaffold.md.
//
// Modes (environment variables):
//   WSI_AUTO_EXIT=1  bounded run: a ~16 ms NSTimer drives setNeedsDisplay:; after
//                    ~30 ticks a 6-step setFrame:display: resize storm; after
//                    ~120 ticks [NSApp stop:nil] (plus a synthetic
//                    NSEventTypeApplicationDefined post, without which stop: only
//                    takes effect on the *next* real event) -> clean exit 0.
//   WSI_HOLD=1       like AUTO_EXIT but no storm and ~600 ticks (~10 s), so an
//                    external observer (the CGWindowListCopyWindowInfo sidecar)
//                    can inspect the window while it is up.
//   (neither)        runs until the window closes (windowWillClose: ->
//                    [NSApp terminate:]).
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
    NSRect frame() @selector("frame");
    NSRect frameRectForContentRect(NSRect contentRect) @selector("frameRectForContentRect:");
    double backingScaleFactor() @selector("backingScaleFactor");
}

// --- The custom NSView subclass, defined in D ----------------------------------
// A *non-extern* `extern (Objective-C)` class: the D compiler emits real
// Objective-C class metadata, the runtime registers `GradientView` at load, and
// AppKit dispatches `drawRect:` / `setFrameSize:` to the D method bodies below.
// Bodyless `@selector` methods (alloc/initWithFrame) bind to the inherited
// NSObject/NSView implementations. The view doubles as the window delegate
// (`windowWillClose:`) and the NSTimer target (`tick:`) — delegate/timer lookup
// is by selector, so no protocol declaration is needed.
class GradientView : NSView
{
    static GradientView alloc() @selector("alloc");
    GradientView initWithFrame(NSRect frame) @selector("initWithFrame:");

    // AppKit's geometry callback to a view: called when the window sizes the
    // content view to fit (first call = our "first_configure") and on every
    // later window resize. Must forward to super or the view never resizes.
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
__gshared int g_tick, g_frames, g_resizesSeen;
__gshared bool g_auto, g_hold;
__gshared bool g_firstConfigureSeen, g_firstPixelSeen;

// Resize storm: 6 content-size changes, ending back at the initial size.
immutable int[2][6] stormSizes =
    [[640, 400], [320, 240], [800, 520], [416, 288], [560, 352], [480, 320]];
enum stormStartTick = 30;
enum stormStrideTicks = 3;
enum autoExitTick = 120;
enum holdExitTick = 600; // ~10 s for the CGWindowList sidecar

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
    {
        ++g_resizesSeen;
        instr("resize", "size=%dx%d scale=%.1f",
            cast(int) size.width, cast(int) size.height, scale);
    }
}

void onDrawRect(NSRect bounds)
{
    immutable double scale = g_win.backingScaleFactor();
    immutable size_t pw = cast(size_t) (bounds.size.width * scale);
    immutable size_t ph = cast(size_t) (bounds.size.height * scale);
    if (pw == 0 || ph == 0)
        return;

    // Per-resize realloc (the simplest strategy — a finding for F02).
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
        // "Presented" = return of the first drawRect:. CoreAnimation may still
        // defer actual compositing to the end-of-cycle CATransaction commit —
        // this is the strongest confirmation AppKit gives a software renderer.
        instr("first_pixel_presented", "t=%d", g_frames);
    }
    instr("frame_callback", "t=%d", g_frames);
}

void onTick(GradientView view)
{
    ++g_tick;
    view.setNeedsDisplay(true);

    if (g_auto && !g_hold && g_tick >= stormStartTick
        && g_tick < stormStartTick + cast(int) stormSizes.length * stormStrideTicks
        && (g_tick - stormStartTick) % stormStrideTicks == 0)
    {
        immutable size = stormSizes[(g_tick - stormStartTick) / stormStrideTicks];
        immutable content = NSRect(NSPoint(120, 120), NSSize(size[0], size[1]));
        instr("step", "name=setFrame_display size=%dx%d", size[0], size[1]);
        g_win.setFrame(g_win.frameRectForContentRect(content), true);
    }

    if (!(g_auto || g_hold))
        return;
    immutable limit = g_hold ? holdExitTick : autoExitTick;
    if (g_tick >= limit)
    {
        instr("step", "name=NSApp_stop tick=%d", g_tick);
        g_app.stop(null);
        // stop: is only checked after an event is dispatched; without a real
        // event in the queue [NSApp run] would keep blocking. Post a synthetic
        // application-defined event so the loop wakes up and exits.
        NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
            NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
        g_app.postEvent(ev, true);
    }
}

int main()
{
    g_auto = getenv("WSI_AUTO_EXIT") !is null;
    g_hold = getenv("WSI_HOLD") !is null;
    instrInit("APPKIT");
    instr("init_start", "auto_exit=%d hold=%d", g_auto ? 1 : 0, g_hold ? 1 : 0);

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

    // 1. The shared application object (connects to the WindowServer).
    instr("step", "name=NSApplication_sharedApplication");
    g_app = NSApplication.sharedApplication();
    instr("step", "name=setActivationPolicy policy=regular");
    g_app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    // 2. A titled, closable, resizable window with a buffered backing store.
    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    instr("step", "name=NSWindow_initWithContentRect size=480x320");
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-scaffold"));
    instr("window_created", "scale=%.1f", g_win.backingScaleFactor());

    // 3. The D-defined NSView subclass becomes the content view; installing it
    //    triggers the first setFrameSize: (-> first_configure). It also serves
    //    as window delegate for windowWillClose:.
    instr("step", "name=GradientView_initWithFrame");
    GradientView view = GradientView.alloc().initWithFrame(contentRect);
    instr("step", "name=setContentView");
    g_win.setContentView(view);
    g_win.setDelegate(view);

    // 4. Show + activate.
    instr("step", "name=makeKeyAndOrderFront");
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);

    // 5. A ~16 ms repeating NSTimer on the run loop drives setNeedsDisplay:
    //    (and the auto-exit/storm schedule). AppKit coalesces the dirty marks
    //    into drawRect: calls on the next run-loop drawing pass.
    instr("step", "name=NSTimer_scheduledTimerWithTimeInterval interval_ms=16");
    NSTimer.scheduledTimerWithTimeInterval(0.016, view, SEL.register("tick:"),
        null, true);

    // 6. Cede the main thread to AppKit. Returns only after [NSApp stop:].
    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "frames=%d ticks=%d resizes=%d", g_frames, g_tick, g_resizesSeen);
    free(g_buf);
    return 0;
}
