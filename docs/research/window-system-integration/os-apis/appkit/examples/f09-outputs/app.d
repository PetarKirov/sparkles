// macOS/AppKit F09 demo — output enumeration & hotplug (../../../features/f09-outputs.md).
// The NSScreen-vs-CGDisplay duality: the same physical display surfaces as two object
// models — AppKit's NSScreen (points, y-up global space, per-screen scale) and
// CoreGraphics' CGDirectDisplayID (pixels, top-left-origin global space, modes) —
// bridged by the `NSScreenNumber` key in -[NSScreen deviceDescription]. Built on the
// scaffold/f08 recipe; run findings are A[ssh] (locked console, single built-in
// display — physical hotplug is Tier C).
//
// What it logs:
//   - CG-side enumeration BEFORE NSApplication exists (CGGetOnlineDisplayList /
//     CGGetActiveDisplayList — enumeration is global, no window or app object needed):
//     per display CGDisplayBounds, CGDisplayPixelsWide/High, vendor/model/serial,
//     CGDisplayScreenSize (physical mm), builtin/main/active/online/asleep flags, and
//     the current CGDisplayMode (points + pixels + CGDisplayModeGetRefreshRate);
//   - NSScreen-side enumeration: per screen frame, visibleFrame (and the
//     menubar/Dock delta between them), backingScaleFactor, localizedName,
//     maximumFramesPerSecond, and deviceDescription (NSScreenNumber + NSDeviceSize +
//     NSDeviceResolution);
//   - the bridge: NSScreenNumber == CGDirectDisplayID, matched against the CG list;
//   - which screen the window is on: -[NSWindow screen] — AppKit answers directly
//     (Win32 derives via MonitorFromWindow, X11 makes you intersect geometry yourself);
//   - change tracking: NSWindowDidChangeScreenNotification +
//     NSApplicationDidChangeScreenParametersNotification observers and a
//     CGDisplayRegisterReconfigurationCallback, with a hand-posted self-test proving
//     the NSNotification wiring (a real hotplug/reconfig is Tier C);
//   - the headless probe: a late re-enumeration diffs the active/online lists against
//     startup — does the locked session itself ever change the answer?
//
// Modes: WSI_AUTO_EXIT=1 = bounded scripted run; without it the window stays up for a
// manual (Tier C) plug/unplug session. Headless-safe: prints `SKIP:` and exits 0 when
// there is no window server.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;

import instrument : instr, instrInit;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d
import objc.rt : SEL;

// --- C-level declarations ---------------------------------------------------------

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

extern (C) nothrow @nogc
{
    uint CGMainDisplayID();
    int CGGetOnlineDisplayList(uint maxDisplays, uint* displays, uint* count);
    int CGGetActiveDisplayList(uint maxDisplays, uint* displays, uint* count);
    NSRect CGDisplayBounds(uint display); // CGRect, top-left-origin global space
    size_t CGDisplayPixelsWide(uint display);
    size_t CGDisplayPixelsHigh(uint display);
    uint CGDisplayVendorNumber(uint display);
    uint CGDisplayModelNumber(uint display);
    uint CGDisplaySerialNumber(uint display);
    uint CGDisplayIsBuiltin(uint display);
    uint CGDisplayIsMain(uint display);
    uint CGDisplayIsActive(uint display);
    uint CGDisplayIsOnline(uint display);
    uint CGDisplayIsAsleep(uint display);
    uint CGDisplayIsInMirrorSet(uint display);
    NSSize CGDisplayScreenSize(uint display); // physical size in millimetres
    void* CGDisplayCopyDisplayMode(uint display);
    size_t CGDisplayModeGetWidth(void* mode); // points
    size_t CGDisplayModeGetHeight(void* mode);
    size_t CGDisplayModeGetPixelWidth(void* mode); // pixels
    size_t CGDisplayModeGetPixelHeight(void* mode);
    double CGDisplayModeGetRefreshRate(void* mode);
    void CGDisplayModeRelease(void* mode);
    void CGContextSetRGBFillColor(void* ctx, double r, double g, double b, double a);
    void CGContextFillRect(void* ctx, NSRect rect);

    // AppKit-exported notification-name constants (NSString*).
    extern __gshared void* NSApplicationDidChangeScreenParametersNotification;
    extern __gshared void* NSWindowDidChangeScreenNotification;
}

// Declared outside the @nogc block above: the callback logs (fprintf is not @nogc).
extern (C) nothrow
{
    alias CGDisplayReconfigurationCallBack =
        void function(uint display, uint flags, void* userInfo) nothrow;
    int CGDisplayRegisterReconfigurationCallback(
        CGDisplayReconfigurationCallBack callback, void* userInfo);
}

// CGDisplayChangeSummaryFlags bits (CGDisplayConfiguration.h).
enum : uint
{
    kCGDisplayBeginConfigurationFlag = 1 << 0,
    kCGDisplayMovedFlag = 1 << 1,
    kCGDisplaySetMainFlag = 1 << 2,
    kCGDisplaySetModeFlag = 1 << 3,
    kCGDisplayAddFlag = 1 << 4,
    kCGDisplayRemoveFlag = 1 << 5,
    kCGDisplayEnabledFlag = 1 << 8,
    kCGDisplayDisabledFlag = 1 << 9,
    kCGDisplayMirrorFlag = 1 << 10,
    kCGDisplayUnMirrorFlag = 1 << 11,
    kCGDisplayDesktopShapeChangedFlag = 1 << 12,
}

// The reconfiguration callback fires twice per change (begin + after) per display.
// Headless expectation: never — the registration + the static answer is the
// deliverable; counting proves it.
extern (C) void displayReconfigCb(uint display, uint flags, void* userInfo) nothrow
{
    ++g_reconfigCalls;
    try
        instr("cg_reconfig", "id=%u flags=0x%x begin=%d add=%d remove=%d set_mode=%d",
            display, flags,
            (flags & kCGDisplayBeginConfigurationFlag) != 0,
            (flags & kCGDisplayAddFlag) != 0,
            (flags & kCGDisplayRemoveFlag) != 0,
            (flags & kCGDisplaySetModeFlag) != 0);
    catch (Exception)
    {
    }
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
    uint unsignedIntValue() @selector("unsignedIntValue");
}

extern class NSValue : NSObject
{
    NSSize sizeValue() @selector("sizeValue");
}

extern class NSDictionary : NSObject
{
    NSObject objectForKey(NSObject key) @selector("objectForKey:");
}

extern class NSNotification : NSObject
{
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
    NSRect frame() @selector("frame");
    NSRect visibleFrame() @selector("visibleFrame");
    double backingScaleFactor() @selector("backingScaleFactor");
    NSString localizedName() @selector("localizedName");
    long maximumFramesPerSecond() @selector("maximumFramesPerSecond");
    NSDictionary deviceDescription() @selector("deviceDescription");
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
    void run() @selector("run");
    void stop(NSObject sender) @selector("stop:");
    void postEvent(NSEvent event, bool atStart) @selector("postEvent:atStart:");
}

extern class NSView : NSResponder
{
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
    NSRect frame() @selector("frame");
    NSScreen screen() @selector("screen");
}

// The instrumented view: flat fill + notification handlers + the tick schedule.
class OutputView : NSView
{
    static OutputView alloc() @selector("alloc");
    OutputView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        CGContextSetRGBFillColor(ctx, 0.15, 0.3, 0.5, 1);
        CGContextFillRect(ctx, this.bounds());
    }

    void tick(NSTimer timer) @selector("tick:")
    {
        onTick();
    }

    // App-level: display configuration changed — re-enumerate everything.
    void screenParamsChanged(NSNotification n) @selector("screenParamsChanged:")
    {
        ++g_screenParamsEvents;
        instr("screen_params_changed", "n=%d", g_screenParamsEvents);
        logNSScreens("notification");
    }

    // Window-level: THIS window moved to a different screen.
    void windowScreenChanged(NSNotification n) @selector("windowScreenChanged:")
    {
        ++g_windowScreenEvents;
        instr("window_screen_changed", "n=%d", g_windowScreenEvents);
        logWindowScreen("notification");
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
enum maxDisplays = 16;

// --- Demo state --------------------------------------------------------------------

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared int g_tick, g_reconfigCalls, g_screenParamsEvents, g_windowScreenEvents;
__gshared bool g_auto, g_stopRequested;
__gshared uint g_startupActive, g_startupOnline; // startup counts for the late diff

// Schedule (ticks of a ~16 ms timer).
enum windowScreenTick = 10;
enum reEnumTick = 20;
enum selftestTick = 30;
enum autoExitTick = 45;

NSString nsstr(const(char)* s)
{
    return NSString.alloc().initWithUTF8String(s);
}

// The bridge key: -[NSScreen deviceDescription][@"NSScreenNumber"] IS the
// CGDirectDisplayID, boxed in an NSNumber.
uint screenNumber(NSScreen s)
{
    NSDictionary dd = s.deviceDescription();
    auto num = cast(NSNumber) dd.objectForKey(cast(NSObject) nsstr("NSScreenNumber"));
    return num !is null ? num.unsignedIntValue() : 0;
}

// --- CG-side enumeration (pixels, top-left-origin, modes) --------------------------

uint[2] logCGDisplays(const(char)* when)
{
    uint[maxDisplays] online, active;
    uint nOnline, nActive;
    CGGetOnlineDisplayList(maxDisplays, online.ptr, &nOnline);
    CGGetActiveDisplayList(maxDisplays, active.ptr, &nActive);
    instr("cg_displays", "when=%s online=%u active=%u", when, nOnline, nActive);

    // Iterate the ONLINE list: in a locked session the ACTIVE list can be empty
    // (drawable-desktop displays only) while the hardware is still online.
    foreach (i; 0 .. nOnline)
    {
        immutable id = online[i];
        immutable b = CGDisplayBounds(id);
        immutable mm = CGDisplayScreenSize(id);
        instr("output",
            "api=cg id=%u bounds=(%.0f,%.0f %.0fx%.0f) px=%zux%zu mm=%.0fx%.0f "
                ~ "vendor=0x%x model=0x%x serial=0x%x builtin=%u main=%u "
                ~ "active=%u online=%u asleep=%u mirror=%u",
            id, b.origin.x, b.origin.y, b.size.width, b.size.height,
            CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id), mm.width, mm.height,
            CGDisplayVendorNumber(id), CGDisplayModelNumber(id),
            CGDisplaySerialNumber(id), CGDisplayIsBuiltin(id), CGDisplayIsMain(id),
            CGDisplayIsActive(id), CGDisplayIsOnline(id), CGDisplayIsAsleep(id),
            CGDisplayIsInMirrorSet(id));

        void* mode = CGDisplayCopyDisplayMode(id);
        if (mode !is null)
        {
            instr("output_mode", "api=cg id=%u mode_pt=%zux%zu mode_px=%zux%zu refresh=%.2f",
                id, CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
                CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode),
                CGDisplayModeGetRefreshRate(mode));
            CGDisplayModeRelease(mode);
        }
        else
            instr("output_mode", "api=cg id=%u mode=nil", id);
    }
    return [nActive, nOnline];
}

// --- NSScreen-side enumeration (points, y-up, per-screen scale) --------------------

void logNSScreens(const(char)* when)
{
    NSArray screens = NSScreen.screens();
    immutable n = screens !is null ? screens.count() : 0;
    instr("ns_screens", "when=%s count=%llu", when, n);
    foreach (i; 0 .. n)
    {
        auto s = cast(NSScreen) screens.objectAtIndex(i);
        immutable f = s.frame();
        immutable v = s.visibleFrame();
        NSString name = s.localizedName();
        instr("output",
            "api=appkit idx=%llu id=%u frame=(%.0f,%.0f %.0fx%.0f) "
                ~ "visible=(%.0f,%.0f %.0fx%.0f) scale=%.1f max_fps=%ld name=\"%s\"",
            i, screenNumber(s), f.origin.x, f.origin.y, f.size.width, f.size.height,
            v.origin.x, v.origin.y, v.size.width, v.size.height,
            s.backingScaleFactor(), s.maximumFramesPerSecond(),
            name !is null ? name.UTF8String() : "");
        // The frame/visibleFrame split: menubar shaves the top, the Dock the bottom.
        instr("output_insets", "api=appkit id=%u menubar_pt=%.0f dock_pt=%.0f side_pt=%.0f",
            screenNumber(s),
            (f.origin.y + f.size.height) - (v.origin.y + v.size.height),
            v.origin.y - f.origin.y, v.origin.x - f.origin.x);

        // deviceDescription extras: NSDeviceSize (points) + NSDeviceResolution (dpi).
        NSDictionary dd = s.deviceDescription();
        auto devSize = cast(NSValue) dd.objectForKey(cast(NSObject) nsstr("NSDeviceSize"));
        auto devRes = cast(NSValue) dd.objectForKey(cast(NSObject) nsstr("NSDeviceResolution"));
        if (devSize !is null && devRes !is null)
        {
            immutable sz = devSize.sizeValue();
            immutable res = devRes.sizeValue();
            instr("output_device", "api=appkit id=%u device_size_pt=%.0fx%.0f device_dpi=%.0fx%.0f",
                screenNumber(s), sz.width, sz.height, res.width, res.height);
        }
    }
}

// The NSScreenNumber <-> CGDirectDisplayID bridge, checked both ways.
void logBridge()
{
    uint[maxDisplays] online, active;
    uint nOnline, nActive;
    CGGetOnlineDisplayList(maxDisplays, online.ptr, &nOnline);
    CGGetActiveDisplayList(maxDisplays, active.ptr, &nActive);
    NSArray screens = NSScreen.screens();
    immutable n = screens !is null ? screens.count() : 0;
    foreach (i; 0 .. n)
    {
        auto s = cast(NSScreen) screens.objectAtIndex(i);
        immutable id = screenNumber(s);
        bool foundActive = false, foundOnline = false;
        foreach (j; 0 .. nActive)
            foundActive |= active[j] == id;
        foreach (j; 0 .. nOnline)
            foundOnline |= online[j] == id;
        instr("bridge", "nsscreen_idx=%llu nsscreen_number=%u in_cg_online_list=%d "
                ~ "in_cg_active_list=%d px_check=%zux%zu", i, id, foundOnline ? 1 : 0,
            foundActive ? 1 : 0, CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id));
    }
}

// Which screen is the window on? AppKit answers directly — no derivation needed.
void logWindowScreen(const(char)* when)
{
    NSScreen s = g_win.screen();
    immutable f = g_win.frame();
    if (s is null)
    {
        instr("window_screen", "when=%s screen=nil note=offscreen_window", when);
        return;
    }
    NSString name = s.localizedName();
    instr("window_screen", "when=%s id=%u name=\"%s\" window_frame=(%.0f,%.0f %.0fx%.0f) "
            ~ "api=window.screen derived=no",
        when, screenNumber(s), name !is null ? name.UTF8String() : "",
        f.origin.x, f.origin.y, f.size.width, f.size.height);
}

void onTick()
{
    ++g_tick;
    if (!g_auto)
        return; // interactive mode: keep the window up for a manual plug/unplug

    if (g_tick == windowScreenTick)
    {
        instr("step", "name=window_screen_steady");
        logWindowScreen("steady");
    }
    else if (g_tick == reEnumTick)
    {
        // The headless probe: does the locked session itself ever change the lists?
        instr("step", "name=re_enumerate note=locked_session_diff");
        immutable counts = logCGDisplays("re_enum");
        logNSScreens("re_enum");
        instr("hotplug_probe", "active_delta=%d online_delta=%d reconfig_cb_calls=%d "
                ~ "note=locked_session_static",
            cast(int) counts[0] - cast(int) g_startupActive,
            cast(int) counts[1] - cast(int) g_startupOnline, g_reconfigCalls);
    }
    else if (g_tick == selftestTick)
    {
        // Prove the NSNotification wiring (nothing fires it headless): post both by hand.
        instr("step", "name=post_notifications note=selftest");
        NSNotificationCenter nc = NSNotificationCenter.defaultCenter();
        nc.postNotificationName(
            cast(NSObject) NSApplicationDidChangeScreenParametersNotification, null);
        nc.postNotificationName(
            cast(NSObject) NSWindowDidChangeScreenNotification, cast(NSObject) g_win);
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
    instrInit("APPKIT_F09");
    instr("init_start", "auto_exit=%d", g_auto ? 1 : 0);

    if (CGMainDisplayID() == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }

    auto pool = autoreleasepool_push();
    scope (exit)
        autoreleasepool_pop(pool);

    // CG enumeration FIRST — before NSApplication.sharedApplication() even exists.
    // CoreGraphics enumeration needs only the WindowServer connection, no app object,
    // no window: it is global. (NSScreen is AppKit, so it waits for the app below.)
    instr("step", "name=cg_enumeration note=pre_NSApplication main_id=%u", CGMainDisplayID());
    immutable counts = logCGDisplays("startup");
    g_startupActive = counts[0];
    g_startupOnline = counts[1];

    // Hotplug/reconfiguration callback — also app-object-free, registered pre-AppKit.
    immutable cbErr = CGDisplayRegisterReconfigurationCallback(&displayReconfigCb, null);
    instr("step", "name=CGDisplayRegisterReconfigurationCallback err=%d", cbErr);

    g_app = NSApplication.sharedApplication();
    g_app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    logNSScreens("startup");
    logBridge();

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(nsstr("wsi-f09-outputs"));
    // -[NSWindow screen] answers before the window is even ordered in.
    logWindowScreen("post_init");

    OutputView view = OutputView.alloc().initWithFrame(contentRect);
    NSNotificationCenter nc = NSNotificationCenter.defaultCenter();
    nc.addObserver(view, SEL.register("screenParamsChanged:"),
        cast(NSObject) NSApplicationDidChangeScreenParametersNotification, null);
    nc.addObserver(view, SEL.register("windowScreenChanged:"),
        cast(NSObject) NSWindowDidChangeScreenNotification, cast(NSObject) g_win);
    instr("step", "name=notification_observers "
            ~ "registered=didChangeScreenParameters,windowDidChangeScreen");

    g_win.setContentView(view);
    g_win.setDelegate(view);
    g_win.makeKeyAndOrderFront(null);
    logWindowScreen("post_order_front");

    instr("step", "name=NSTimer_scheduledTimerWithTimeInterval interval_ms=16");
    NSTimer.scheduledTimerWithTimeInterval(0.016, view, SEL.register("tick:"), null, true);

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "ticks=%d reconfig_cb=%d screen_params=%d window_screen=%d",
        g_tick, g_reconfigCalls, g_screenParamsEvents, g_windowScreenEvents);
    return 0;
}
