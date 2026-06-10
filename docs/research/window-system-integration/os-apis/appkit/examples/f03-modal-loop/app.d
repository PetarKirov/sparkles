// macOS/AppKit F03 demo — modal-loop survival (../../../features/f03-modal-loop.md).
// On macOS the "modal loop" is a *run-loop mode switch*: during interactive
// live-resize / menu tracking AppKit runs the run loop in NSEventTrackingRunLoopMode
// instead of the default mode, so timers scheduled only in the default mode starve
// and any animation they drive freezes. The cure is scheduling the animation timer
// in NSRunLoopCommonModes, which AppKit's tracking/modal modes are members of.
//
// The demo animates a full-window ~2 Hz color cycle and races two identical
// ~100 ms NSTimers:
//   timer=default  scheduledTimerWithTimeInterval: (default run-loop mode only)
//   timer=common   timerWithTimeInterval: + addTimer:forMode:NSRunLoopCommonModes
//                  (this one drives setNeedsDisplay: -> the color cycle)
// Both log `tick timer=… n=… gap_ms=… phase=…` per fire.
//
// Because a programmatic setFrame: never enters live-resize (scaffold finding) and
// an interactive border-drag cannot be performed over SSH, the bounded run proves
// the *mechanism* headless: two one-shot common-modes timers each run the run loop
// nested (runMode:beforeDate:) in a non-default mode for ~2 s — first
// NSEventTrackingRunLoopMode (the very mode AppKit's live-resize/menu tracking
// loops run in), then NSModalPanelRunLoopMode. The default-mode timer starves for
// each whole phase; the common-modes timer keeps ticking — the same starvation an
// interactive drag causes. Per-timer max-gap statistics are reported per phase at
// exit.
//
// The nested phases are deliberately entered from their own one-shot timers, NOT
// from the animation timer's callback: a repeating NSTimer never fires
// re-entrantly while its own callout is on the stack, so a nested loop run from
// inside tickCommon: would starve the common-modes timer too (measured — see the
// findings doc).
//
// Live-resize instrumentation for the interactive Tier-C run:
// viewWillStartLiveResize/viewDidEndLiveResize log `modal_enter`/`modal_exit`
// (kind=live_resize), and every drawRect: logs inLiveResize.
// Findings: ../../f03-modal-loop.md; recipe and build command: ../../scaffold.md.
//
// Modes (environment variables):
//   WSI_AUTO_EXIT=1  bounded run: default (~3 s) -> tracking (~2 s, nested
//                    NSEventTrackingRunLoopMode) -> resumed (~2 s) -> panel
//                    (~2 s, nested NSModalPanelRunLoopMode) -> resumed (~3 s) ->
//                    [NSApp stop:nil] (+ synthetic event post) -> exit 0.
//   (none)           interactive: no modal phase is injected; runs until the
//                    window closes so a human can border-drag and observe the
//                    default-mode timer freeze while the color cycle survives
//                    (Tier C; see the manual-run queue).
//
// Headless-safe: prints `SKIP:` and exits 0 when there is no window server
// (CGMainDisplayID() == 0), per the research-docs guidelines.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv, malloc, free;
import core.sys.posix.unistd : usleep;
import core.time : MonoTime, msecs;

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

// --- AppKit class declarations (objective-d bundles Foundation, not AppKit) ----

extern (Objective-C):

extern class NSObject
{
}

extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* s) @selector("initWithUTF8String:");
}

extern class NSDate : NSObject
{
    static NSDate dateWithTimeIntervalSinceNow(double secs)
        @selector("dateWithTimeIntervalSinceNow:");
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
    // Schedules on the *current* run loop in the *default* mode.
    static NSTimer scheduledTimerWithTimeInterval(double interval, NSObject target,
        SEL sel, NSObject userInfo, bool repeats)
        @selector("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:");
    // Creates without scheduling — the caller picks the run-loop mode(s).
    static NSTimer timerWithTimeInterval(double interval, NSObject target,
        SEL sel, NSObject userInfo, bool repeats)
        @selector("timerWithTimeInterval:target:selector:userInfo:repeats:");
}

extern class NSRunLoop : NSObject
{
    static NSRunLoop currentRunLoop() @selector("currentRunLoop");
    void addTimer(NSTimer timer, NSString mode) @selector("addTimer:forMode:");
    bool runMode(NSString mode, NSDate beforeDate) @selector("runMode:beforeDate:");
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
    bool inLiveResize() @selector("inLiveResize");
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
// Same recipe as the scaffold: bodied @selector methods are the implementation;
// selector-only callbacks (timer fires, delegate methods, the live-resize
// notifications) need no base declaration — Objective-C dispatch is by selector.
class ColorView : NSView
{
    static ColorView alloc() @selector("alloc");
    ColorView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        onDrawRect(this.bounds(), this.inLiveResize());
    }

    // The control timer: default run-loop mode only.
    void tickDefault(NSTimer timer) @selector("tickDefault:")
    {
        onTimerFire(TimerId.defaultMode);
    }

    // The animation timer: NSRunLoopCommonModes; drives the color cycle.
    void tickCommon(NSTimer timer) @selector("tickCommon:")
    {
        onTimerFire(TimerId.commonModes);
        ++g_hueStep;
        this.setNeedsDisplay(true);
        if (g_auto)
            onAutoExitCheck();
    }

    // One-shot phase triggers (their own callouts, so neither measured timer is
    // blocked by NSTimer's no-re-entrant-fire rule while the nested loop runs).
    void enterTracking(NSTimer timer) @selector("enterTracking:")
    {
        runNestedPhase(Phase.tracking, g_modeTracking, "NSEventTrackingRunLoopMode");
    }

    void enterPanel(NSTimer timer) @selector("enterPanel:")
    {
        runNestedPhase(Phase.panel, g_modePanel, "NSModalPanelRunLoopMode");
    }

    // AppKit's live-resize bracket — the platform's `modal_enter`/`modal_exit`.
    // Fires only for interactive border-drags (Tier C), never programmatically.
    void viewWillStartLiveResize() @selector("viewWillStartLiveResize")
    {
        instr("modal_enter", "kind=live_resize");
        g_phase = Phase.tracking; // live-resize IS NSEventTrackingRunLoopMode
    }

    void viewDidEndLiveResize() @selector("viewDidEndLiveResize")
    {
        instr("modal_exit", "kind=live_resize");
        g_phase = Phase.resumed;
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

// --- Demo state -----------------------------------------------------------------

enum TimerId : int
{
    defaultMode = 0, // control: starves in non-default modes
    commonModes = 1, // animation: survives them
}

enum Phase : int
{
    defaultRun = 0, // [NSApp run] pumping the default mode
    tracking = 1,   // nested NSEventTrackingRunLoopMode (== live-resize's mode)
    panel = 2,      // nested NSModalPanelRunLoopMode
    resumed = 3,    // back in the default mode after a nested phase
}

immutable string[2] timerNames = ["default", "common"];
immutable string[4] phaseNames = ["default", "tracking", "panel", "resumed"];

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared NSRunLoop g_runLoop;
__gshared NSString g_modeTracking, g_modePanel;
__gshared uint* g_buf;
__gshared size_t g_bufW, g_bufH;
__gshared Phase g_phase = Phase.defaultRun;
__gshared bool g_auto;
__gshared int g_hueStep, g_draws;

// Per-timer fire accounting: last fire time, then fires/max-gap per phase.
__gshared ulong[2] g_lastFireUs;
__gshared uint[2] g_fireCount;
__gshared uint[4][2] g_firesPerPhase;   // [timer][phase]
__gshared ulong[4][2] g_maxGapPerPhase; // [timer][phase], µs

enum timerIntervalMs = 100;     // both timers; the color cycle advances per common tick
enum hueStepsPerCycle = 5;      // 5 × 100 ms = 500 ms per full cycle ≈ 2 Hz
enum trackingEnterSec = 3.0;    // ~3 s of phase `default` first
enum panelEnterSec = 7.0;       // ~2 s `resumed` between the nested phases
enum nestedPhaseMs = 2000;      // ~2 s per nested mode
enum autoExitUs = 12_000_000;   // ~12 s total

void onTimerFire(TimerId id)
{
    immutable now = instrNowUs();
    immutable gapUs = g_lastFireUs[id] != 0 ? now - g_lastFireUs[id] : 0;
    g_lastFireUs[id] = now;
    ++g_fireCount[id];
    ++g_firesPerPhase[id][g_phase];
    if (gapUs > g_maxGapPerPhase[id][g_phase])
        g_maxGapPerPhase[id][g_phase] = gapUs;
    instr("tick", "timer=%.*s n=%u gap_ms=%.1f phase=%.*s",
        cast(int) timerNames[id].length, timerNames[id].ptr, g_fireCount[id],
        gapUs / 1000.0, cast(int) phaseNames[g_phase].length, phaseNames[g_phase].ptr);
}

// The headline measurement: run the run loop nested in a non-default mode —
// structurally what AppKit does for live-resize/menu tracking
// (NSEventTrackingRunLoopMode) and modal panels (NSModalPanelRunLoopMode). The
// common-modes timer keeps firing into the nested loop; the default-mode timer
// cannot. Entered from a one-shot timer's callout so neither measured timer is
// blocked by its own in-progress callout.
void runNestedPhase(Phase phase, NSString mode, const(char)* modeName)
{
    g_phase = phase;
    instr("phase_enter", "name=%.*s mode=%s dur_ms=%d",
        cast(int) phaseNames[phase].length, phaseNames[phase].ptr, modeName,
        nestedPhaseMs);
    immutable deadline = MonoTime.currTime + nestedPhaseMs.msecs;
    while (MonoTime.currTime < deadline)
    {
        auto pool = autoreleasepool_push();
        immutable ranSource = g_runLoop.runMode(mode,
            NSDate.dateWithTimeIntervalSinceNow(0.05));
        autoreleasepool_pop(pool);
        if (!ranSource)
            usleep(10_000); // mode has no sources/timers: don't spin hot
    }
    g_phase = Phase.resumed;
    instr("phase_exit", "name=%.*s",
        cast(int) phaseNames[phase].length, phaseNames[phase].ptr);
}

void onAutoExitCheck()
{
    if (g_phase != Phase.resumed || instrNowUs() < autoExitUs)
        return;
    foreach (timer; 0 .. 2)
        foreach (phase; 0 .. 4)
            instr("gap_summary", "timer=%.*s phase=%.*s fires=%u max_gap_ms=%.1f",
                cast(int) timerNames[timer].length, timerNames[timer].ptr,
                cast(int) phaseNames[phase].length, phaseNames[phase].ptr,
                g_firesPerPhase[timer][phase],
                g_maxGapPerPhase[timer][phase] / 1000.0);
    instr("step", "name=NSApp_stop");
    g_app.stop(null);
    // stop: is only checked after an event dispatch; post a synthetic event
    // so [NSApp run] wakes up and exits (scaffold finding).
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true);
}

void onDrawRect(NSRect bounds, bool live)
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

    // Full-window solid color cycling through hues, one step per common tick
    // (~2 Hz full cycle). A frozen color = a starved animation timer.
    immutable color = hueColor(g_hueStep % hueStepsPerCycle, hueStepsPerCycle);
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
    instr("draw", "n=%d hue_step=%d live_resize=%d phase=%.*s",
        g_draws, g_hueStep, live ? 1 : 0,
        cast(int) phaseNames[g_phase].length, phaseNames[g_phase].ptr);
}

uint hueColor(int step, int steps) nothrow @nogc
{
    // Coarse hue wheel: interpolate R->G->B->R over `steps` positions.
    immutable t = step * 768 / steps; // 0..767
    int r, g, b;
    if (t < 256)
    {
        r = 255 - t;
        g = t;
    }
    else if (t < 512)
    {
        g = 255 - (t - 256);
        b = t - 256;
    }
    else
    {
        b = 255 - (t - 512);
        r = t - 512;
    }
    return 0xFF00_0000 | (cast(uint) r << 16) | (cast(uint) g << 8) | cast(uint) b;
}

int main()
{
    g_auto = getenv("WSI_AUTO_EXIT") !is null;
    instrInit("APPKIT_F03");
    instr("init_start", "auto_exit=%d timer_interval_ms=%d", g_auto ? 1 : 0,
        timerIntervalMs);

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

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f03-modal-loop"));
    instr("window_created", "scale=%.1f", g_win.backingScaleFactor());

    ColorView view = ColorView.alloc().initWithFrame(contentRect);
    g_win.setContentView(view);
    g_win.setDelegate(view);
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);

    g_runLoop = NSRunLoop.currentRunLoop();
    g_modeTracking = NSString.alloc().initWithUTF8String("NSEventTrackingRunLoopMode");
    g_modePanel = NSString.alloc().initWithUTF8String("NSModalPanelRunLoopMode");
    NSString modeCommon = NSString.alloc().initWithUTF8String("kCFRunLoopCommonModes");

    // Timer 1 — the control: scheduledTimerWithTimeInterval: puts it on the
    // current run loop in the DEFAULT mode only. This is the naive animation
    // timer that freezes during live-resize/menu tracking.
    instr("step", "name=timer_default api=scheduledTimerWithTimeInterval mode=default");
    NSTimer.scheduledTimerWithTimeInterval(timerIntervalMs / 1000.0, view,
        SEL.register("tickDefault:"), null, true);

    // Timer 2 — the fix: an unscheduled timer added explicitly for
    // NSRunLoopCommonModes, which AppKit's event-tracking and modal-panel modes
    // are members of. This one drives the color cycle.
    instr("step", "name=timer_common api=addTimer_forMode mode=NSRunLoopCommonModes");
    NSTimer common = NSTimer.timerWithTimeInterval(timerIntervalMs / 1000.0, view,
        SEL.register("tickCommon:"), null, true);
    g_runLoop.addTimer(common, modeCommon);

    if (g_auto)
    {
        // One-shot phase triggers, themselves in common modes (so the tracking
        // trigger can still fire if anything else changes the mode underneath).
        instr("step", "name=schedule_nested tracking_at_s=%.1f panel_at_s=%.1f",
            trackingEnterSec, panelEnterSec);
        NSTimer t1 = NSTimer.timerWithTimeInterval(trackingEnterSec, view,
            SEL.register("enterTracking:"), null, false);
        g_runLoop.addTimer(t1, modeCommon);
        NSTimer t2 = NSTimer.timerWithTimeInterval(panelEnterSec, view,
            SEL.register("enterPanel:"), null, false);
        g_runLoop.addTimer(t2, modeCommon);
    }

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "ticks_default=%u ticks_common=%u draws=%d",
        g_fireCount[TimerId.defaultMode], g_fireCount[TimerId.commonModes], g_draws);
    free(g_buf);
    return 0;
}
