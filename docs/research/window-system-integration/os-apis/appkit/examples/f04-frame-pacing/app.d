// macOS/AppKit F04 demo — vsync / frame pacing (../../../features/f04-frame-pacing.md).
// Redraw of a trivially cheap frame (solid color flip) is paced by the platform
// frame clock: a CADisplayLink obtained from the view via
// displayLinkWithTarget:selector: (macOS 14+; the older CVDisplayLink C API is
// deprecated since macOS 15) and added to the main run loop in
// NSRunLoopCommonModes. Every fire logs
//     frame_callback t=<link.timestamp> target=<link.targetTimestamp> path=displaylink
// until 600 frames are paced; at exit the demo prints min/median/p99/max
// inter-frame delta and a coarse jitter histogram.
//
// Fallback chain (so the demo always completes headless / screen-locked, where
// the WindowServer may never drive the link):
//   1. NSView responds to displayLinkWithTarget:selector:?  no -> NSTimer path.
//   2. CADisplayLink silent for >3 s (watchdog, ignoring the deliberate hidden
//      phase)? -> invalidate it and fall back to a ~16 ms NSTimer; every frame
//      logs path=displaylink|timer so the two are never conflated.
//
// Occlusion probe: ~6 s in (or at frame 300), the window is sent orderOut: for
// ~3 s, then makeKeyAndOrderFront: again — Apple documents the view display link
// as following the view's window/display visibility, so the fires should pause;
// the demo logs vis_change, frames observed while hidden, the resume gap, and
// windowDidChangeOcclusionState:. NSScreen.maximumFramesPerSecond is logged at
// startup as the nominal cadence reference.
// Findings: ../../f04-frame-pacing.md; recipe and build command: ../../scaffold.md.
//
// Always bounded: exits 0 after 600 paced frames + the occlusion probe, or at a
// hard ~30 s deadline, whichever comes first. Headless-safe: prints `SKIP:` and
// exits 0 when there is no window server (CGMainDisplayID() == 0).
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;
import core.stdc.stdlib : malloc, free, qsort;

import instrument : instr, instrInit, instrNowUs;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d

// Objective-C runtime selector lookup (objective-d wraps libobjc; declaring
// sel_registerName ourselves would clash with objc.rt's typed declaration).
import objc.rt : SEL;

// --- C-level declarations -----------------------------------------------------

// CoreGraphics C API — linked transitively via the Cocoa umbrella framework.
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

// --- AppKit/QuartzCore class declarations --------------------------------------

extern (Objective-C):

extern class NSObject
{
    bool respondsToSelector(SEL sel) @selector("respondsToSelector:");
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
    static NSTimer timerWithTimeInterval(double interval, NSObject target,
        SEL sel, NSObject userInfo, bool repeats)
        @selector("timerWithTimeInterval:target:selector:userInfo:repeats:");
    void invalidate() @selector("invalidate");
}

extern class NSRunLoop : NSObject
{
    static NSRunLoop currentRunLoop() @selector("currentRunLoop");
    void addTimer(NSTimer timer, NSString mode) @selector("addTimer:forMode:");
}

// QuartzCore's frame clock (-framework QuartzCore). The macOS 14+ instance comes
// from -[NSView displayLinkWithTarget:selector:]; timestamps are CFTimeInterval
// seconds on the mach_absolute_time/CACurrentMediaTime timebase.
extern class CADisplayLink : NSObject
{
    double timestamp() @selector("timestamp");
    double targetTimestamp() @selector("targetTimestamp");
    double duration() @selector("duration");
    bool isPaused() @selector("isPaused");
    void addToRunLoop(NSRunLoop runLoop, NSString mode) @selector("addToRunLoop:forMode:");
    void invalidate() @selector("invalidate");
}

extern class NSScreen : NSObject
{
    static NSScreen mainScreen() @selector("mainScreen");
    long maximumFramesPerSecond() @selector("maximumFramesPerSecond");
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
    void setNeedsDisplay(bool flag) @selector("setNeedsDisplay:");
    NSRect bounds() @selector("bounds");
    // macOS 14.0+ — gated at runtime via respondsToSelector:.
    CADisplayLink displayLinkWithTarget(NSObject target, SEL sel)
        @selector("displayLinkWithTarget:selector:");
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
    void orderOut(NSObject sender) @selector("orderOut:");
    ulong occlusionState() @selector("occlusionState");
    double backingScaleFactor() @selector("backingScaleFactor");
}

// --- The custom NSView subclass, defined in D ----------------------------------
// Scaffold recipe: bodied @selector methods are the implementation; the display
// link / timer / delegate callbacks are selector-only (no base declaration).
class FlipView : NSView
{
    static FlipView alloc() @selector("alloc");
    FlipView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        onDrawRect(this.bounds());
    }

    // CADisplayLink fire — the platform frame clock.
    void displayTick(CADisplayLink link) @selector("displayTick:")
    {
        onFrame(link.timestamp(), link.targetTimestamp(), Path.displaylink);
    }

    // Fallback frame clock: a ~16 ms NSTimer in NSRunLoopCommonModes.
    void timerTick(NSTimer timer) @selector("timerTick:")
    {
        immutable t = instrNowUs() / 1e6;
        onFrame(t, t + fallbackIntervalMs / 1000.0, Path.timer);
    }

    // 100 ms state-machine scheduler (watchdog, occlusion probe, deadline).
    void schedTick(NSTimer timer) @selector("schedTick:")
    {
        onSchedule();
    }

    // NSWindowDelegate: occlusion-state transitions (orderOut:/orderFront:).
    void windowDidChangeOcclusionState(NSObject notification)
        @selector("windowDidChangeOcclusionState:")
    {
        instr("vis_change", "state=occlusion occlusion_state=%lu visible=%d",
            g_win.occlusionState(),
            (g_win.occlusionState() & NSWindowOcclusionStateVisible) != 0 ? 1 : 0);
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
enum ulong NSWindowOcclusionStateVisible = 1UL << 1;

// --- Demo state -----------------------------------------------------------------

enum Path : int
{
    displaylink = 0,
    timer = 1,
}

immutable string[2] pathNames = ["displaylink", "timer"];

enum targetFrames = 600;      // per the F04 spec
enum fallbackIntervalMs = 16; // NSTimer fallback cadence
enum watchdogSilenceMs = 3000;
enum hideAtMs = 6000;         // occlusion probe: orderOut: ...
enum hideAtFrame = 300;       // ... or at frame 300, whichever first
enum hiddenForMs = 3000;
enum deadlineMs = 30_000;     // hard stop: the demo always completes

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared NSRunLoop g_runLoop;
__gshared NSString g_modeCommon;
__gshared FlipView g_view;
__gshared CADisplayLink g_link;
__gshared uint* g_buf;
__gshared size_t g_bufW, g_bufH;
__gshared Path g_path = Path.displaylink;

__gshared int g_frames, g_draws;
__gshared int[2] g_framesPerPath;
__gshared double g_lastTs = 0;
__gshared bool g_skipNextDelta;       // after path switch / un-hide: gap is not jitter
__gshared double[2048] g_deltas;      // seconds; capped, extra frames only counted
__gshared int g_deltaCount;

__gshared bool g_hidden, g_hideDone, g_showDone, g_fellBack, g_finished;
__gshared ulong g_hideAtUs, g_lastFrameUs;
__gshared int g_framesAtHide, g_hiddenFrames;
__gshared double g_resumeGapMs = -1;

void onFrame(double ts, double target, Path path)
{
    if (g_finished || path != g_path)
        return; // ignore stragglers from an invalidated clock
    ++g_frames;
    ++g_framesPerPath[path];
    g_lastFrameUs = instrNowUs();
    if (g_hidden)
        ++g_hiddenFrames;

    instr("frame_callback", "t=%.6f target=%.6f path=%.*s",
        ts, target, cast(int) pathNames[path].length, pathNames[path].ptr);

    if (g_lastTs > 0)
    {
        immutable delta = ts - g_lastTs;
        if (g_skipNextDelta)
        {
            g_skipNextDelta = false;
            if (g_showDone && g_resumeGapMs < 0)
            {
                g_resumeGapMs = delta * 1000.0;
                instr("resume_gap", "gap_ms=%.1f", g_resumeGapMs);
            }
        }
        else if (g_deltaCount < cast(int) g_deltas.length)
            g_deltas[g_deltaCount++] = delta;
    }
    g_lastTs = ts;

    g_view.setNeedsDisplay(true); // solid color flip — the trivially cheap frame

    // Don't finish while the occlusion probe is mid-flight; onSchedule's
    // deadline covers the pathological cases.
    if (g_frames >= targetFrames && g_showDone)
        finish("frames");
}

void onSchedule()
{
    if (g_finished)
        return;
    immutable nowMs = instrNowUs() / 1000;

    // Watchdog: the display link never fired / went silent (and not because we
    // hid the window on purpose) -> fall back to the NSTimer frame clock.
    if (g_path == Path.displaylink && !g_fellBack && !g_hidden)
    {
        immutable sinceLast = g_frames == 0 ? nowMs : (instrNowUs() - g_lastFrameUs) / 1000;
        if (sinceLast > watchdogSilenceMs)
        {
            g_fellBack = true;
            instr("watchdog",
                "displaylink_silent_ms=%llu frames_so_far=%d link_paused=%d occlusion_state=%lu action=fallback_timer",
                cast(ulong) sinceLast, g_frames,
                (g_link !is null && g_link.isPaused()) ? 1 : 0, g_win.occlusionState());
            if (g_link !is null)
                g_link.invalidate();
            startTimerPath();
        }
    }

    // Occlusion probe: hide for ~3 s mid-run, then show again.
    if (!g_hideDone && (nowMs >= hideAtMs || g_frames >= hideAtFrame))
    {
        g_hideDone = true;
        g_hidden = true;
        g_hideAtUs = instrNowUs();
        g_framesAtHide = g_frames;
        instr("vis_change", "state=hidden api=orderOut frames=%d link_paused=%d",
            g_frames, (g_link !is null && g_path == Path.displaylink && g_link.isPaused()) ? 1 : 0);
        g_win.orderOut(null);
    }
    else if (g_hideDone && !g_showDone && instrNowUs() >= g_hideAtUs + hiddenForMs * 1000)
    {
        g_showDone = true;
        g_hidden = false;
        g_skipNextDelta = true;
        instr("vis_change",
            "state=visible api=makeKeyAndOrderFront hidden_frames=%d link_paused=%d",
            g_hiddenFrames,
            (g_link !is null && g_path == Path.displaylink && g_link.isPaused()) ? 1 : 0);
        g_win.makeKeyAndOrderFront(null);
    }

    if (nowMs >= deadlineMs)
        finish("deadline");
    else if (g_frames >= targetFrames && g_showDone)
        finish("frames");
}

void startTimerPath()
{
    g_path = Path.timer;
    g_lastTs = 0; // timer timestamps are on the demo's own monotonic epoch
    g_skipNextDelta = true;
    instr("path_select", "path=timer interval_ms=%d", fallbackIntervalMs);
    NSTimer t = NSTimer.timerWithTimeInterval(fallbackIntervalMs / 1000.0, g_view,
        SEL.register("timerTick:"), null, true);
    g_runLoop.addTimer(t, g_modeCommon);
}

extern (C) int cmpDouble(const(void)* a, const(void)* b) nothrow @nogc
{
    immutable x = *cast(const double*) a, y = *cast(const double*) b;
    return (x > y) - (x < y);
}

void finish(const(char)* reason)
{
    if (g_finished)
        return;
    g_finished = true;
    instr("step", "name=finish reason=%s", reason);

    if (g_deltaCount > 0)
    {
        qsort(g_deltas.ptr, g_deltaCount, double.sizeof, &cmpDouble);
        immutable minMs = g_deltas[0] * 1000.0;
        immutable medMs = g_deltas[g_deltaCount / 2] * 1000.0;
        immutable p99Ms = g_deltas[(g_deltaCount * 99) / 100 >= g_deltaCount
            ? g_deltaCount - 1 : (g_deltaCount * 99) / 100] * 1000.0;
        immutable maxMs = g_deltas[g_deltaCount - 1] * 1000.0;
        instr("stats", "n=%d min_ms=%.3f median_ms=%.3f p99_ms=%.3f max_ms=%.3f",
            g_deltaCount, minMs, medMs, p99Ms, maxMs);

        // Coarse jitter histogram (inter-frame delta, ms).
        static immutable double[9] edges = [2, 4, 6, 9, 13, 18, 25, 40, 100];
        int[10] buckets;
        foreach (i; 0 .. g_deltaCount)
        {
            immutable ms = g_deltas[i] * 1000.0;
            size_t b = edges.length;
            foreach (j, e; edges)
                if (ms < e)
                {
                    b = j;
                    break;
                }
            ++buckets[b];
        }
        foreach (j, count; buckets)
        {
            if (count == 0)
                continue;
            if (j == 0)
                instr("histogram", "bucket_ms=<%.0f count=%d", edges[0], count);
            else if (j == edges.length)
                instr("histogram", "bucket_ms=>=%.0f count=%d", edges[$ - 1], count);
            else
                instr("histogram", "bucket_ms=%.0f-%.0f count=%d",
                    edges[j - 1], edges[j], count);
        }
    }
    else
        instr("stats", "n=0");

    instr("loop_exit",
        "frames=%d frames_displaylink=%d frames_timer=%d draws=%d hidden_frames=%d fell_back=%d",
        g_frames, g_framesPerPath[Path.displaylink], g_framesPerPath[Path.timer],
        g_draws, g_hiddenFrames, g_fellBack ? 1 : 0);

    g_app.stop(null);
    // stop: is only checked after an event dispatch; post a synthetic event so
    // [NSApp run] wakes up and exits (scaffold finding).
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true);
}

void onDrawRect(NSRect bounds)
{
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
    }

    // The cheapest possible frame: a solid color flipping per paced frame.
    immutable uint color = (g_frames & 1) ? 0xFFFF_FFFF : 0xFF10_1018;
    foreach (i; 0 .. pw * ph)
        g_buf[i] = color;

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
    ++g_draws;
}

int main()
{
    instrInit("APPKIT_F04");
    instr("init_start", "target_frames=%d deadline_ms=%d", targetFrames, deadlineMs);

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

    NSScreen screen = NSScreen.mainScreen();
    instr("screen_info", "max_fps=%ld",
        screen !is null ? screen.maximumFramesPerSecond() : -1);

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f04-frame-pacing"));
    instr("window_created", "scale=%.1f occlusion_state=%lu",
        g_win.backingScaleFactor(), g_win.occlusionState());

    g_view = FlipView.alloc().initWithFrame(contentRect);
    g_win.setContentView(g_view);
    g_win.setDelegate(g_view);
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);

    g_runLoop = NSRunLoop.currentRunLoop();
    g_modeCommon = NSString.alloc().initWithUTF8String("kCFRunLoopCommonModes");

    // Frame-clock selection: CADisplayLink via the macOS 14+ NSView API, else
    // the NSTimer fallback. The link is created unscheduled and must be added
    // to a run loop explicitly; common modes so it survives tracking loops (F03).
    if (g_view.respondsToSelector(SEL.register("displayLinkWithTarget:selector:")))
    {
        g_link = g_view.displayLinkWithTarget(g_view, SEL.register("displayTick:"));
        if (g_link !is null)
        {
            g_link.addToRunLoop(g_runLoop, g_modeCommon);
            instr("path_select", "path=displaylink api=NSView_displayLinkWithTarget paused=%d",
                g_link.isPaused() ? 1 : 0);
        }
    }
    if (g_link is null)
    {
        instr("path_select", "path=timer reason=no_displaylink_api");
        startTimerPath();
    }

    // The 100 ms scheduler (watchdog / occlusion probe / deadline), common modes.
    NSTimer sched = NSTimer.timerWithTimeInterval(0.1, g_view,
        SEL.register("schedTick:"), null, true);
    g_runLoop.addTimer(sched, g_modeCommon);

    instr("step", "name=NSApp_run");
    g_app.run();

    free(g_buf);
    return g_finished ? 0 : 1;
}
