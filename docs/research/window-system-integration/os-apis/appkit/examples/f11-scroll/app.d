// macOS/AppKit F11 demo — scroll fidelity (../../../features/f11-scroll.md).
// AppKit hands scrollWheel: one NSEvent carrying THREE representations of the
// same physical scroll: scrollingDeltaX/Y (the modern, possibly pixel-precise
// deltas), deltaX/deltaY (the legacy line-ish units), and the phase /
// momentumPhase pair that turns a stream of events into trackpad gestures.
// This demo logs every field of every scroll event, keeps a scrollable-ruler
// offset, and prints per-gesture summaries keyed on phase transitions.
//
// What it logs (A[ssh]; locked console — no real wheel/trackpad, so events are
// built with CGEventCreateScrollWheelEvent2 and delivered IN-PROCESS via
// +[NSEvent eventWithCGEvent:] + [window sendEvent:], the f06/f07 route-1
// workhorse; the real-fling choreography is Tier C):
//   - per event: scrollingDeltaX/Y, legacy deltaX/deltaY, hasPreciseScrollingDeltas,
//     phase + momentumPhase (NSEventPhase bitmask decoded), and
//     isDirectionInvertedFromDevice;
//   - the unit duality at the CG layer: a line-unit event's synthesized
//     kCGScrollWheelEventDeltaAxis1 / FixedPtDeltaAxis1 / PointDeltaAxis1 /
//     IsContinuous fields read back (where "one notch = deltaY 1.0 =
//     scrollingDeltaY ~10" lives), same for a pixel-unit event;
//   - multi-tick and negative line values; a fractional line delta forced via
//     CGEventSetDoubleValueField(kCGScrollWheelEventFixedPtDeltaAxis1) — the
//     precision-touchpad analog;
//   - the phase probe: CGEventSetIntegerValueField(kCGScrollWheelEventScrollPhase /
//     ...MomentumPhase) with CGScrollPhase/CGMomentumScrollPhase values — does the
//     wrapped NSEvent surface them as NSEventPhase? (the CG->NS phase mapping is
//     the finding);
//   - a scripted synthetic fling: phase began -> changed... -> ended, then
//     momentum began -> changed... -> ended, plus a cancelled variant — each
//     transition driving the gesture summaries;
//   - a scrollable ruler (offset integrated from scrollingDeltaY) drawn in
//     drawRect: (visible pixels are Tier C; the offset is in the log).
//
// Modes: WSI_AUTO_EXIT=1 = bounded scripted run; without it the window stays up
// for a manual (Tier C) wheel/trackpad session. Headless-safe: prints `SKIP:`
// and exits 0 when there is no window server.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : getenv;

import instrument : instr, instrInit;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d
import objc.rt : SEL;

// --- Geometry ----------------------------------------------------------------------

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

// --- CoreGraphics C API --------------------------------------------------------------

extern (C) nothrow @nogc
{
    uint CGMainDisplayID();
    NSRect CGDisplayBounds(uint display);

    // The non-variadic scroll constructor (up to 3 axes; we use 2).
    void* CGEventCreateScrollWheelEvent2(void* source, uint units, uint wheelCount,
        int wheel1, int wheel2, int wheel3);
    void CGEventSetLocation(void* event, NSPoint location);
    void CGEventSetIntegerValueField(void* event, uint field, long value);
    long CGEventGetIntegerValueField(void* event, uint field);
    void CGEventSetDoubleValueField(void* event, uint field, double value);
    double CGEventGetDoubleValueField(void* event, uint field);
    void CFRelease(void* obj);

    void CGContextSetRGBFillColor(void* ctx, double r, double g, double b, double a);
    void CGContextFillRect(void* ctx, NSRect rect);
}

enum uint kCGScrollEventUnitPixel = 0; // CGScrollEventUnit
enum uint kCGScrollEventUnitLine = 1;

// CGEventField (CGEventTypes.h), axis 1 = vertical, axis 2 = horizontal.
enum : uint
{
    kCGScrollWheelEventDeltaAxis1 = 11, // integer line delta
    kCGScrollWheelEventDeltaAxis2 = 12,
    kCGScrollWheelEventFixedPtDeltaAxis1 = 93, // 16.16 fixed-point line delta
    kCGScrollWheelEventFixedPtDeltaAxis2 = 94,
    kCGScrollWheelEventPointDeltaAxis1 = 96, // integer pixel delta
    kCGScrollWheelEventPointDeltaAxis2 = 97,
    kCGScrollWheelEventIsContinuous = 88, // 1 = pixel-based device (trackpad)
    kCGScrollWheelEventScrollPhase = 99, // CGScrollPhase
    kCGScrollWheelEventMomentumPhase = 123, // CGMomentumScrollPhase
}

// CGScrollPhase (kCGScrollPhase*: bitmask-style values)...
enum : long
{
    cgPhaseBegan = 1,
    cgPhaseChanged = 2,
    cgPhaseEnded = 4,
    cgPhaseCancelled = 8,
    cgPhaseMayBegin = 128,
}

// ...vs CGMomentumScrollPhase (kCGMomentumScrollPhase*: sequential values).
enum : long
{
    cgMomentumNone = 0,
    cgMomentumBegin = 1,
    cgMomentumContinue = 2,
    cgMomentumEnd = 3,
}

// NSEventPhase bitmask (NSEvent.h).
enum : ulong
{
    NSEventPhaseNone = 0,
    NSEventPhaseBegan = 0x1,
    NSEventPhaseStationary = 0x2,
    NSEventPhaseChanged = 0x4,
    NSEventPhaseEnded = 0x8,
    NSEventPhaseCancelled = 0x10,
    NSEventPhaseMayBegin = 0x20,
}

// --- AppKit class declarations --------------------------------------------------------

extern (Objective-C):

extern class NSObject
{
}

extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* s) @selector("initWithUTF8String:");
}

extern class NSEvent : NSObject
{
    static NSEvent eventWithCGEvent(void* cgEvent) @selector("eventWithCGEvent:");
    static NSEvent otherEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, short subtype,
        long data1, long data2)
        @selector("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
    long type() @selector("type");
    NSPoint locationInWindow() @selector("locationInWindow");
    double deltaX() @selector("deltaX");
    double deltaY() @selector("deltaY");
    double scrollingDeltaX() @selector("scrollingDeltaX");
    double scrollingDeltaY() @selector("scrollingDeltaY");
    bool hasPreciseScrollingDeltas() @selector("hasPreciseScrollingDeltas");
    ulong phase() @selector("phase");
    ulong momentumPhase() @selector("momentumPhase");
    bool isDirectionInvertedFromDevice() @selector("isDirectionInvertedFromDevice");
}

extern class NSTimer : NSObject
{
    static NSTimer scheduledTimerWithTimeInterval(double interval, NSObject target,
        SEL sel, NSObject userInfo, bool repeats)
        @selector("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:");
}

extern class NSApplication : NSObject
{
    static NSApplication sharedApplication() @selector("sharedApplication");
    void setActivationPolicy(long policy) @selector("setActivationPolicy:");
    void activateIgnoringOtherApps(bool flag) @selector("activateIgnoringOtherApps:");
    void run() @selector("run");
    void stop(NSObject sender) @selector("stop:");
    void postEvent(NSEvent event, bool atStart) @selector("postEvent:atStart:");
}

extern class NSGraphicsContext : NSObject
{
    static NSGraphicsContext currentContext() @selector("currentContext");
    void* CGContext() @selector("CGContext");
}

extern class NSView : NSObject
{
    NSRect bounds() @selector("bounds");
    void setNeedsDisplay(bool flag) @selector("setNeedsDisplay:");
}

extern class NSWindow : NSObject
{
    static NSWindow alloc() @selector("alloc");
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer) @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void setContentView(NSObject view) @selector("setContentView:");
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
    bool makeFirstResponder(NSObject responder) @selector("makeFirstResponder:");
    void sendEvent(NSEvent event) @selector("sendEvent:");
    long windowNumber() @selector("windowNumber");
    NSRect frame() @selector("frame");
}

// The ruler view: logs every scrollWheel: payload and scrolls a tick ruler.
class RulerView : NSView
{
    static RulerView alloc() @selector("alloc");
    RulerView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        // Tier-C visual aid: ruler ticks every 20 pt (major every 100) offset by
        // the integrated scroll position, so over/under-scroll is visible.
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        immutable b = this.bounds();
        CGContextSetRGBFillColor(ctx, 0.12, 0.12, 0.14, 1);
        CGContextFillRect(ctx, b);
        immutable off = g_offsetY % 20.0;
        for (double y = -off; y < b.size.height; y += 20)
        {
            immutable absPos = y + g_offsetY;
            immutable major = (cast(long)(absPos / 20 + 0.5)) % 5 == 0;
            CGContextSetRGBFillColor(ctx, 0.7, 0.7, 0.75, 1);
            CGContextFillRect(ctx, NSRect(NSPoint(0, y), NSSize(major ? 60 : 30, 1)));
        }
    }

    void scrollWheel(NSEvent e) @selector("scrollWheel:")
    {
        onScroll(e);
    }

    void tick(NSTimer t) @selector("tick:")
    {
        onStep();
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

// --- Demo state -----------------------------------------------------------------------

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared RulerView g_view;
__gshared bool g_auto;
__gshared int g_step;
__gshared int g_arrivals;

__gshared double g_offsetY = 0; // ruler position (points)

// Per-gesture accumulators, keyed on phase transitions.
__gshared bool g_gestureActive;
__gshared int g_gestureEvents;
__gshared double g_gestureScrollY = 0, g_gestureLegacyY = 0;
__gshared bool g_momentumActive;
__gshared int g_momentumEvents;
__gshared double g_momentumScrollY = 0;
__gshared int g_gestureN; // gesture counter

// Decode the NSEventPhase bitmask into a readable token list.
void phaseName(ulong phase, char* buf, size_t cap) nothrow @nogc
{
    if (phase == 0)
    {
        snprintf(buf, cap, "none");
        return;
    }
    size_t n = 0;
    void add(const(char)* t) nothrow @nogc
    {
        n += snprintf(buf + n, cap - n, "%s%s", n ? "|".ptr : "".ptr, t);
    }

    if (phase & NSEventPhaseBegan)
        add("began");
    if (phase & NSEventPhaseStationary)
        add("stationary");
    if (phase & NSEventPhaseChanged)
        add("changed");
    if (phase & NSEventPhaseEnded)
        add("ended");
    if (phase & NSEventPhaseCancelled)
        add("cancelled");
    if (phase & NSEventPhaseMayBegin)
        add("mayBegin");
}

// --- The scrollWheel: funnel -----------------------------------------------------------

void onScroll(NSEvent e)
{
    ++g_arrivals;
    immutable sdx = e.scrollingDeltaX();
    immutable sdy = e.scrollingDeltaY();
    immutable ldx = e.deltaX();
    immutable ldy = e.deltaY();
    immutable precise = e.hasPreciseScrollingDeltas();
    immutable ph = e.phase();
    immutable mph = e.momentumPhase();
    char[64] pn = void, mn = void;
    phaseName(ph, pn.ptr, pn.length);
    phaseName(mph, mn.ptr, mn.length);
    instr("scroll",
        "sdx=%.2f sdy=%.2f legacy_dx=%.3f legacy_dy=%.3f precise=%d phase=0x%llx(%s) momentum=0x%llx(%s) inverted=%d",
        sdx, sdy, ldx, ldy, precise ? 1 : 0, ph, pn.ptr, mph, mn.ptr,
        e.isDirectionInvertedFromDevice() ? 1 : 0);

    // Ruler: integrate the modern deltas (positive sdy scrolls content up).
    g_offsetY -= sdy;
    instr("ruler", "offset_y=%.1f", g_offsetY);
    g_view.setNeedsDisplay(true);

    // Gesture bookkeeping keyed on the phase transitions.
    if (ph & NSEventPhaseBegan)
    {
        g_gestureActive = true;
        ++g_gestureN;
        g_gestureEvents = 0;
        g_gestureScrollY = g_gestureLegacyY = 0;
        instr("gesture", "n=%d state=begin", g_gestureN);
    }
    if (g_gestureActive)
    {
        ++g_gestureEvents;
        g_gestureScrollY += sdy;
        g_gestureLegacyY += ldy;
    }
    if (ph & (NSEventPhaseEnded | NSEventPhaseCancelled))
    {
        instr("gesture_summary",
            "n=%d kind=drag end=%s events=%d total_sdy=%.2f total_legacy_dy=%.3f",
            g_gestureN, (ph & NSEventPhaseCancelled) ? "cancelled".ptr : "ended".ptr,
            g_gestureEvents, g_gestureScrollY, g_gestureLegacyY);
        g_gestureActive = false;
    }
    if (mph & NSEventPhaseBegan)
    {
        g_momentumActive = true;
        g_momentumEvents = 0;
        g_momentumScrollY = 0;
        instr("gesture", "n=%d state=momentum_begin", g_gestureN);
    }
    if (g_momentumActive)
    {
        ++g_momentumEvents;
        g_momentumScrollY += sdy;
    }
    if (mph & (NSEventPhaseEnded | NSEventPhaseCancelled))
    {
        instr("gesture_summary", "n=%d kind=momentum events=%d total_sdy=%.2f",
            g_gestureN, g_momentumEvents, g_momentumScrollY);
        g_momentumActive = false;
    }
    if (ph == NSEventPhaseNone && mph == NSEventPhaseNone)
        instr("gesture_summary", "kind=discrete events=1 sdy=%.2f legacy_dy=%.3f",
            sdy, ldy);
}

// --- Synthetic scroll injection ----------------------------------------------------------

// Read back what CG synthesized (or what we forced) at the Quartz layer.
void logCGFields(void* cg, const(char)* label)
{
    instr("cg_fields",
        "label=%s delta1=%ld fixedpt1=%.3f point1=%ld continuous=%ld phase=%ld momentum=%ld",
        label,
        CGEventGetIntegerValueField(cg, kCGScrollWheelEventDeltaAxis1),
        CGEventGetDoubleValueField(cg, kCGScrollWheelEventFixedPtDeltaAxis1),
        CGEventGetIntegerValueField(cg, kCGScrollWheelEventPointDeltaAxis1),
        CGEventGetIntegerValueField(cg, kCGScrollWheelEventIsContinuous),
        CGEventGetIntegerValueField(cg, kCGScrollWheelEventScrollPhase),
        CGEventGetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase));
}

// Window-content center in CG global coords (top-left-origin), so sendEvent's
// hit test can route the wrapped event to the ruler view.
NSPoint windowCenterCG()
{
    immutable wf = g_win.frame(); // AppKit screen coords, y-up
    immutable db = CGDisplayBounds(CGMainDisplayID());
    return NSPoint(wf.origin.x + wf.size.width / 2,
        db.size.height - (wf.origin.y + wf.size.height / 2));
}

// Build, wrap, dispatch. phase/momentum < 0 = leave the field untouched.
void injectScroll(uint units, int wheel1, long phase, long momentum,
    const(char)* label, double fixedPtOverride = double.nan)
{
    void* cg = CGEventCreateScrollWheelEvent2(null, units, 2, wheel1, 0, 0);
    if (cg is null)
    {
        instr("inject", "label=%s result=create_failed", label);
        return;
    }
    CGEventSetLocation(cg, windowCenterCG());
    if (phase >= 0)
        CGEventSetIntegerValueField(cg, kCGScrollWheelEventScrollPhase, phase);
    if (momentum >= 0)
        CGEventSetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase, momentum);
    if (fixedPtOverride == fixedPtOverride) // !isNaN
        CGEventSetDoubleValueField(cg, kCGScrollWheelEventFixedPtDeltaAxis1,
            fixedPtOverride);
    instr("inject", "label=%s units=%s wheel1=%d cg_phase=%ld cg_momentum=%ld",
        label, units == kCGScrollEventUnitLine ? "line".ptr : "pixel".ptr, wheel1,
        phase, momentum);
    logCGFields(cg, label);

    NSEvent e = NSEvent.eventWithCGEvent(cg);
    if (e is null)
    {
        instr("wrap", "label=%s result=nil", label);
        CFRelease(cg);
        return;
    }
    immutable before = g_arrivals;
    g_win.sendEvent(e);
    if (g_arrivals == before)
    {
        instr("route", "label=%s sendEvent=not_delivered fallback=direct", label);
        g_view.scrollWheel(e);
    }
    else
        instr("route", "label=%s sendEvent=delivered", label);
    CFRelease(cg);
}

// --- The scripted run ----------------------------------------------------------------------

void stopApp()
{
    instr("step", "name=NSApp_stop");
    g_app.stop(null);
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true); // stop: is only checked after an event dispatch
}

void onStep()
{
    if (!g_auto)
        return;
    switch (g_step)
    {
    // -- Unit duality: line-unit (wheel notches) vs pixel-unit (trackpad-like) --
    case 0: // one wheel notch up: the deltaY 1.0 / scrollingDeltaY ~10 anchor
        injectScroll(kCGScrollEventUnitLine, 1, -1, -1, "line_1_notch");
        break;
    case 1: // multi-tick
        injectScroll(kCGScrollEventUnitLine, 3, -1, -1, "line_3_notches");
        break;
    case 2: // negative (scroll down)
        injectScroll(kCGScrollEventUnitLine, -2, -1, -1, "line_minus2");
        break;
    case 3: // pixel unit: does the wrapped event turn precise?
        injectScroll(kCGScrollEventUnitPixel, 10, -1, -1, "pixel_10");
        break;
    case 4:
        injectScroll(kCGScrollEventUnitPixel, 120, -1, -1, "pixel_120");
        break;
    case 5: // fractional line delta via the 16.16 fixed-point field
        injectScroll(kCGScrollEventUnitLine, 0, -1, -1, "line_fractional_0.4", 0.4);
        break;
    // -- Phase probe: can a CGEvent carry gesture phases into NSEvent? --
    case 6:
        injectScroll(kCGScrollEventUnitPixel, 5, cgPhaseBegan, -1, "phase_began_probe");
        break;
    // -- Full synthetic trackpad fling: drag phases then momentum phases --
    case 7:
        injectScroll(kCGScrollEventUnitPixel, 30, cgPhaseChanged, -1, "fling_changed_30");
        break;
    case 8:
        injectScroll(kCGScrollEventUnitPixel, 20, cgPhaseChanged, -1, "fling_changed_20");
        break;
    case 9:
        injectScroll(kCGScrollEventUnitPixel, 0, cgPhaseEnded, -1, "fling_ended");
        break;
    case 10:
        injectScroll(kCGScrollEventUnitPixel, 15, -1, cgMomentumBegin, "momentum_begin_15");
        break;
    case 11:
        injectScroll(kCGScrollEventUnitPixel, 8, -1, cgMomentumContinue, "momentum_continue_8");
        break;
    case 12:
        injectScroll(kCGScrollEventUnitPixel, 3, -1, cgMomentumContinue, "momentum_continue_3");
        break;
    case 13:
        injectScroll(kCGScrollEventUnitPixel, 0, -1, cgMomentumEnd, "momentum_end");
        break;
    // -- What does a cancelled gesture look like? --
    case 14:
        injectScroll(kCGScrollEventUnitPixel, 4, cgPhaseBegan, -1, "cancel_began");
        break;
    case 15:
        injectScroll(kCGScrollEventUnitPixel, 0, cgPhaseCancelled, -1, "cancel_cancelled");
        break;
    case 16:
        instr("totals", "arrivals=%d gestures=%d final_offset_y=%.1f",
            g_arrivals, g_gestureN, g_offsetY);
        break;
    case 17:
        stopApp();
        break;
    default:
        break;
    }
    ++g_step;
}

int main()
{
    g_auto = getenv("WSI_AUTO_EXIT") !is null;
    instrInit("APPKIT_F11");
    instr("init_start", "auto_exit=%d", g_auto ? 1 : 0);

    instr("step", "name=CGMainDisplayID");
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
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f11-scroll"));
    g_view = RulerView.alloc().initWithFrame(NSRect(NSPoint(0, 0), contentRect.size));
    g_win.setContentView(g_view);
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);
    g_win.makeFirstResponder(g_view);
    instr("window_created", "win_num=%ld", g_win.windowNumber());

    instr("step", "name=script_timer_start interval_ms=150");
    NSTimer.scheduledTimerWithTimeInterval(0.15, g_view, SEL.register("tick:"), null, true);

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "steps=%d arrivals=%d", g_step, g_arrivals);
    return 0;
}
