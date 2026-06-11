// macOS/AppKit F14 demo — window state transitions & the vetoable close
// (../../../features/f14-window-state.md).
// The deliverable is the ORDERED delegate-method + notification sequence for each
// state transition (zoom:, miniaturize:/deminiaturize:, toggleFullScreen:,
// orderOut:/orderFront:) plus the close contract (windowShouldClose: as the
// first-class veto, and the proof that -close skips the delegate ask while
// -performClose: honors it).
//
// Instrumentation: every NSWindowDelegate method the demo implements logs
// `delegate m=<method>` and a catch-all NSNotificationCenter observer
// (addObserver:selector:name:nil object:window) logs `note name=<NSWindow…>` —
// interleaving the two by timestamp yields the choreography per transition.
// A `phase=` tag carried on every line names the request being serviced.
// NSWindowDidUpdateNotification fires once per run-loop pass and would flood the
// log; it is counted and suppressed.
//
// A[ssh]: built/run on mac-bsn over SSH; the console-session lock state is read
// from CGSessionCopyCurrentDictionary (CGSSessionScreenIsLocked) and logged so
// findings can be labelled honestly (miniaturize/fullscreen behave differently
// when no one is watching).
//
// Modes: WSI_AUTO_EXIT=1 = bounded scripted run (the sequence below); without it
// the window stays up for a manual (Tier C) session. Headless-safe: prints
// `SKIP:` and exits 0 when there is no window server.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;

import instrument : instr, instrInit, instrNowUs;
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

// --- CoreGraphics / CoreFoundation C API -------------------------------------------

extern (C) nothrow @nogc
{
    uint CGMainDisplayID();
    NSRect CGDisplayBounds(uint display);

    // Session dictionary: carries CGSSessionScreenIsLocked when the console is locked.
    void* CGSessionCopyCurrentDictionary();
    void* CFStringCreateWithCString(void* alloc, const(char)* s, uint encoding);
    void* CFDictionaryGetValue(void* dict, void* key);
    ubyte CFBooleanGetValue(void* b);
    void CFRelease(void* obj);

    void CGContextSetRGBFillColor(void* ctx, double r, double g, double b, double a);
    void CGContextFillRect(void* ctx, NSRect rect);
}

enum uint kCFStringEncodingUTF8 = 0x08000100;

// Logs lock state via the CGSSessionScreenIsLocked key (absent when unlocked).
void logSessionLockState()
{
    void* dict = CGSessionCopyCurrentDictionary();
    if (dict is null)
    {
        instr("session", "lock_state=no_session_dictionary");
        return;
    }
    void* kLocked = CFStringCreateWithCString(null, "CGSSessionScreenIsLocked",
        kCFStringEncodingUTF8);
    void* kConsole = CFStringCreateWithCString(null, "kCGSSessionOnConsoleKey",
        kCFStringEncodingUTF8);
    void* locked = CFDictionaryGetValue(dict, kLocked);
    void* console = CFDictionaryGetValue(dict, kConsole);
    instr("session", "screen_locked=%d on_console=%d",
        locked !is null && CFBooleanGetValue(locked) ? 1 : 0,
        console !is null && CFBooleanGetValue(console) ? 1 : 0);
    CFRelease(kLocked);
    CFRelease(kConsole);
    CFRelease(dict);
}

// --- AppKit class declarations -----------------------------------------------------

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

extern class NSNotification : NSObject
{
    NSString name() @selector("name");
    NSObject object() @selector("object");
}

extern class NSNotificationCenter : NSObject
{
    static NSNotificationCenter defaultCenter() @selector("defaultCenter");
    void addObserver(NSObject observer, SEL sel, NSString name, NSObject obj)
        @selector("addObserver:selector:name:object:");
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
}

extern class NSWindow : NSObject
{
    static NSWindow alloc() @selector("alloc");
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer) @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void setContentView(NSObject view) @selector("setContentView:");
    void setDelegate(NSObject d) @selector("setDelegate:");
    void setReleasedWhenClosed(bool b) @selector("setReleasedWhenClosed:");
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
    void orderOut(NSObject sender) @selector("orderOut:");
    void orderFront(NSObject sender) @selector("orderFront:");
    long windowNumber() @selector("windowNumber");
    NSRect frame() @selector("frame");

    // State requests + readbacks.
    void zoom(NSObject sender) @selector("zoom:");
    bool isZoomed() @selector("isZoomed");
    void miniaturize(NSObject sender) @selector("miniaturize:");
    void deminiaturize(NSObject sender) @selector("deminiaturize:");
    bool isMiniaturized() @selector("isMiniaturized");
    void toggleFullScreen(NSObject sender) @selector("toggleFullScreen:");
    ulong styleMask() @selector("styleMask");
    ulong collectionBehavior() @selector("collectionBehavior");
    void setCollectionBehavior(ulong b) @selector("setCollectionBehavior:");
    bool isVisible() @selector("isVisible");
    bool isKeyWindow() @selector("isKeyWindow");
    ulong occlusionState() @selector("occlusionState");

    // The close pair under test.
    void performClose(NSObject sender) @selector("performClose:");
    void close() @selector("close");
}

// The content view — a flat fill so state changes have something to composite.
class StateView : NSView
{
    static StateView alloc() @selector("alloc");
    StateView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        CGContextSetRGBFillColor(ctx, 0.15, 0.25, 0.35, 1);
        CGContextFillRect(ctx, this.bounds());
    }
}

// The NSWindowDelegate + catch-all notification observer + script driver, in one
// pure-D NSObject subclass (selector-matched methods need no protocol declaration).
class StateDelegate : NSObject
{
    static StateDelegate alloc() @selector("alloc");
    StateDelegate init() @selector("init");

    // --- Close contract ------------------------------------------------------------
    bool windowShouldClose(NSWindow sender) @selector("windowShouldClose:")
    {
        immutable isMain = sender is g_win;
        if (isMain && g_dirty)
        {
            g_dirty = false; // once-veto: the dirty flag is consumed
            instr("close_requested", "veto=1 win=%s phase=%s mechanism=windowShouldClose_NO",
                winLabel(sender), g_phase);
            return false;
        }
        instr("close_requested", "veto=0 win=%s phase=%s", winLabel(sender), g_phase);
        return true;
    }

    void windowWillClose(NSNotification n) @selector("windowWillClose:")
    {
        instr("delegate", "m=windowWillClose win=%s phase=%s",
            winLabel(cast(NSWindow) n.object()), g_phase);
        if (cast(NSWindow) n.object() is g_win)
            stopApp(); // second close request → willClose → terminate
    }

    // --- Zoom (maximize) choreography ------------------------------------------------
    NSRect windowWillUseStandardFrame(NSWindow w, NSRect frame)
        @selector("windowWillUseStandardFrame:defaultFrame:")
    {
        instr("delegate", "m=windowWillUseStandardFrame default=(%.0f,%.0f %.0fx%.0f) phase=%s",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, g_phase);
        return frame;
    }

    bool windowShouldZoom(NSWindow w, NSRect frame)
        @selector("windowShouldZoom:toFrame:")
    {
        instr("delegate", "m=windowShouldZoom toFrame=(%.0f,%.0f %.0fx%.0f) phase=%s answer=YES",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, g_phase);
        return true;
    }

    NSSize windowWillResize(NSWindow w, NSSize size)
        @selector("windowWillResize:toSize:")
    {
        instr("delegate", "m=windowWillResize toSize=%.0fx%.0f phase=%s",
            size.width, size.height, g_phase);
        return size;
    }

    void windowDidResize(NSNotification n) @selector("windowDidResize:")
    {
        immutable f = g_win.frame();
        instr("delegate", "m=windowDidResize frame=(%.0f,%.0f %.0fx%.0f) phase=%s",
            f.origin.x, f.origin.y, f.size.width, f.size.height, g_phase);
    }

    void windowDidMove(NSNotification n) @selector("windowDidMove:")
    {
        instr("delegate", "m=windowDidMove phase=%s", g_phase);
    }

    void windowWillStartLiveResize(NSNotification n) @selector("windowWillStartLiveResize:")
    {
        instr("delegate", "m=windowWillStartLiveResize phase=%s", g_phase);
    }

    void windowDidEndLiveResize(NSNotification n) @selector("windowDidEndLiveResize:")
    {
        instr("delegate", "m=windowDidEndLiveResize phase=%s", g_phase);
    }

    // --- Miniaturize ------------------------------------------------------------------
    void windowWillMiniaturize(NSNotification n) @selector("windowWillMiniaturize:")
    {
        instr("delegate", "m=windowWillMiniaturize phase=%s", g_phase);
    }

    void windowDidMiniaturize(NSNotification n) @selector("windowDidMiniaturize:")
    {
        instr("delegate", "m=windowDidMiniaturize miniaturized=%d phase=%s",
            g_win.isMiniaturized() ? 1 : 0, g_phase);
    }

    void windowDidDeminiaturize(NSNotification n) @selector("windowDidDeminiaturize:")
    {
        instr("delegate", "m=windowDidDeminiaturize phase=%s", g_phase);
    }

    // --- Focus / key status -------------------------------------------------------------
    void windowDidBecomeKey(NSNotification n) @selector("windowDidBecomeKey:")
    {
        instr("focus", "state=in win=%s phase=%s reason=didBecomeKey",
            winLabel(cast(NSWindow) n.object()), g_phase);
    }

    void windowDidResignKey(NSNotification n) @selector("windowDidResignKey:")
    {
        instr("focus", "state=out win=%s phase=%s reason=didResignKey",
            winLabel(cast(NSWindow) n.object()), g_phase);
    }

    void windowDidBecomeMain(NSNotification n) @selector("windowDidBecomeMain:")
    {
        instr("focus", "state=main_in win=%s phase=%s", winLabel(cast(NSWindow) n.object()), g_phase);
    }

    void windowDidResignMain(NSNotification n) @selector("windowDidResignMain:")
    {
        instr("focus", "state=main_out win=%s phase=%s", winLabel(cast(NSWindow) n.object()), g_phase);
    }

    // --- Fullscreen (Space transition) ----------------------------------------------------
    void windowWillEnterFullScreen(NSNotification n) @selector("windowWillEnterFullScreen:")
    {
        g_fsT0 = instrNowUs();
        instr("delegate", "m=windowWillEnterFullScreen phase=%s", g_phase);
    }

    void windowDidEnterFullScreen(NSNotification n) @selector("windowDidEnterFullScreen:")
    {
        g_fsEntered = true;
        instr("delegate", "m=windowDidEnterFullScreen dur_ms=%.1f styleMask=0x%llx phase=%s",
            (instrNowUs() - g_fsT0) / 1000.0, g_win.styleMask(), g_phase);
    }

    void windowWillExitFullScreen(NSNotification n) @selector("windowWillExitFullScreen:")
    {
        g_fsT0 = instrNowUs();
        instr("delegate", "m=windowWillExitFullScreen phase=%s", g_phase);
    }

    void windowDidExitFullScreen(NSNotification n) @selector("windowDidExitFullScreen:")
    {
        g_fsExited = true;
        instr("delegate", "m=windowDidExitFullScreen dur_ms=%.1f styleMask=0x%llx phase=%s",
            (instrNowUs() - g_fsT0) / 1000.0, g_win.styleMask(), g_phase);
    }

    void windowDidFailToEnterFullScreen(NSWindow w)
        @selector("windowDidFailToEnterFullScreen:")
    {
        g_fsFailed = true;
        instr("delegate", "m=windowDidFailToEnterFullScreen phase=%s", g_phase);
    }

    // --- Catch-all notification observer + script timer -------------------------------------
    void onNote(NSNotification n) @selector("onNote:")
    {
        const(char)* name = n.name().UTF8String();
        // NSWindowDidUpdateNotification fires once per run-loop drawing pass — count, don't log.
        if (streq(name, "NSWindowDidUpdateNotification"))
        {
            ++g_updates;
            return;
        }
        instr("note", "name=%s phase=%s", name, g_phase);
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
    NSWindowStyleMaskMiniaturizable = 4,
    NSWindowStyleMaskResizable = 8,
    NSWindowStyleMaskFullScreen = 1 << 14,
}

enum ulong NSBackingStoreBuffered = 2;
enum long NSEventTypeApplicationDefined = 15;
enum ulong NSWindowCollectionBehaviorFullScreenPrimary = 1 << 7;

// --- Demo state -----------------------------------------------------------------------

__gshared NSApplication g_app;
__gshared NSWindow g_win; // the main window under test
__gshared NSWindow g_aux; // throwaway window for the close-vs-performClose proof
__gshared StateDelegate g_dlg;
__gshared bool g_auto;
__gshared int g_step;
__gshared int g_waitTicks; // budget for async (fullscreen) waits
__gshared const(char)* g_phase = "init"; // request currently being serviced
__gshared bool g_dirty; // the vetoable-close dirty flag
__gshared bool g_fsEntered, g_fsExited, g_fsFailed;
__gshared ulong g_fsT0;
__gshared int g_updates; // suppressed NSWindowDidUpdateNotification count

bool streq(const(char)* a, const(char)* b) nothrow @nogc
{
    import core.stdc.string : strcmp;

    return a !is null && b !is null && strcmp(a, b) == 0;
}

const(char)* winLabel(NSWindow w)
{
    if (w is g_win)
        return "main";
    if (w is g_aux)
        return "aux";
    return "other";
}

void logState(const(char)* tag)
{
    immutable f = g_win.frame();
    instr("state_changed", "tag=%s frame=(%.0f,%.0f %.0fx%.0f) zoomed=%d mini=%d visible=%d key=%d occlusion=0x%llx fullscreen=%d",
        tag, f.origin.x, f.origin.y, f.size.width, f.size.height,
        g_win.isZoomed() ? 1 : 0, g_win.isMiniaturized() ? 1 : 0,
        g_win.isVisible() ? 1 : 0, g_win.isKeyWindow() ? 1 : 0,
        g_win.occlusionState(),
        (g_win.styleMask() & NSWindowStyleMaskFullScreen) ? 1 : 0);
}

void stopApp()
{
    instr("step", "name=NSApp_stop");
    g_app.stop(null);
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true); // stop: is only checked after an event dispatch
}

// --- The scripted run --------------------------------------------------------------------

void onStep()
{
    if (!g_auto)
        return;
    switch (g_step)
    {
    case 0: // Baseline.
        g_phase = "baseline";
        logState("baseline");
        instr("collection_behavior", "before=0x%llx", g_win.collectionBehavior());
        g_win.setCollectionBehavior(NSWindowCollectionBehaviorFullScreenPrimary);
        instr("collection_behavior", "after=0x%llx note=FullScreenPrimary_prerequisite_for_toggleFullScreen",
            g_win.collectionBehavior());
        break;
    case 1: // Zoom on (programmatic maximize).
        g_phase = "zoom_on";
        instr("state_request", "kind=zoom api=zoom: zoomed_before=%d", g_win.isZoomed() ? 1 : 0);
        g_win.zoom(null);
        logState("after_zoom_on");
        break;
    case 2: // Zoom off (restore).
        g_phase = "zoom_off";
        instr("state_request", "kind=zoom_restore api=zoom: zoomed_before=%d",
            g_win.isZoomed() ? 1 : 0);
        g_win.zoom(null);
        logState("after_zoom_off");
        break;
    case 3: // Miniaturize.
        g_phase = "miniaturize";
        instr("state_request", "kind=minimize api=miniaturize:");
        g_win.miniaturize(null);
        logState("after_miniaturize");
        break;
    case 4: // Deminiaturize.
        g_phase = "deminiaturize";
        instr("state_request", "kind=restore api=deminiaturize:");
        g_win.deminiaturize(null);
        logState("after_deminiaturize");
        break;
    case 5: // orderOut (hide without state).
        g_phase = "order_out";
        instr("state_request", "kind=hide api=orderOut:");
        g_win.orderOut(null);
        logState("after_order_out");
        break;
    case 6: // orderFront + makeKey restore.
        g_phase = "order_front";
        instr("state_request", "kind=show api=makeKeyAndOrderFront:");
        g_win.makeKeyAndOrderFront(null);
        logState("after_order_front");
        break;
    case 7: // Fullscreen enter — async Space transition; wait for didEnter.
        g_phase = "fullscreen_enter";
        instr("state_request", "kind=fullscreen api=toggleFullScreen:");
        g_fsEntered = g_fsFailed = false;
        g_waitTicks = 40; // 8 s budget at 200 ms ticks
        g_win.toggleFullScreen(null);
        break;
    case 8: // Wait for the enter transition to settle (or time out).
        if (!g_fsEntered && !g_fsFailed && --g_waitTicks > 0)
            return; // stay on this step
        instr("state_settled", "kind=fullscreen entered=%d failed=%d timed_out=%d",
            g_fsEntered ? 1 : 0, g_fsFailed ? 1 : 0, g_waitTicks <= 0 ? 1 : 0);
        logState("after_fullscreen_enter");
        break;
    case 9: // Fullscreen exit.
        g_phase = "fullscreen_exit";
        if (g_win.styleMask() & NSWindowStyleMaskFullScreen)
        {
            instr("state_request", "kind=fullscreen_exit api=toggleFullScreen:");
            g_fsExited = false;
            g_waitTicks = 40;
            g_win.toggleFullScreen(null);
        }
        else
        {
            instr("state_request", "kind=fullscreen_exit skipped=not_fullscreen");
            g_step += 1; // skip the wait step too
        }
        break;
    case 10:
        if (!g_fsExited && --g_waitTicks > 0)
            return;
        instr("state_settled", "kind=fullscreen_exit exited=%d timed_out=%d",
            g_fsExited ? 1 : 0, g_waitTicks <= 0 ? 1 : 0);
        logState("after_fullscreen_exit");
        break;
    case 11: // Proof: -close skips windowShouldClose:; -performClose: asks first.
        g_phase = "aux_close_direct";
        instr("close_probe", "api=close win=aux expect=no_windowShouldClose");
        g_aux.close(); // delegate's windowShouldClose must NOT fire; willClose must
        break;
    case 12: // Vetoable close, attempt 1: dirty → veto.
        g_phase = "veto_close_1";
        g_dirty = true;
        instr("close_probe", "api=performClose win=main dirty=1 expect=veto");
        g_win.performClose(null);
        instr("close_probe", "after=performClose still_visible=%d dirty=%d",
            g_win.isVisible() ? 1 : 0, g_dirty ? 1 : 0);
        break;
    case 13: // Attempt 2: flag consumed → close proceeds → willClose stops the app.
        g_phase = "veto_close_2";
        instr("close_probe", "api=performClose win=main dirty=0 expect=close");
        g_win.performClose(null);
        break;
    default:
        // Safety net if windowWillClose never fired.
        instr("close_probe", "result=window_did_not_close visible=%d", g_win.isVisible() ? 1 : 0);
        stopApp();
        break;
    }
    ++g_step;
}

int main()
{
    g_auto = getenv("WSI_AUTO_EXIT") !is null;
    instrInit("APPKIT_F14");
    instr("init_start", "auto_exit=%d", g_auto ? 1 : 0);

    if (CGMainDisplayID() == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }
    logSessionLockState();

    auto pool = autoreleasepool_push();
    scope (exit)
        autoreleasepool_pop(pool);

    g_app = NSApplication.sharedApplication();
    g_app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    immutable mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    g_win = NSWindow.alloc().initWithContentRect(
        NSRect(NSPoint(120, 120), NSSize(480, 320)), mask, NSBackingStoreBuffered, false);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f14-window-state"));
    g_win.setReleasedWhenClosed(false); // we read isVisible after close
    StateView view = StateView.alloc().initWithFrame(NSRect(NSPoint(0, 0), NSSize(480, 320)));
    g_win.setContentView(view);

    g_aux = NSWindow.alloc().initWithContentRect(
        NSRect(NSPoint(700, 120), NSSize(200, 120)), mask, NSBackingStoreBuffered, false);
    g_aux.setTitle(NSString.alloc().initWithUTF8String("wsi-f14-aux"));
    g_aux.setReleasedWhenClosed(false);

    g_dlg = StateDelegate.alloc().init();
    g_win.setDelegate(g_dlg);
    g_aux.setDelegate(g_dlg);

    // Catch-all observer: every notification whose object is the main window.
    NSNotificationCenter.defaultCenter().addObserver(g_dlg, SEL.register("onNote:"),
        null, g_win);

    g_aux.orderFront(null);
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);
    instr("window_created", "main_win=%ld aux_win=%ld styleMask=0x%llx",
        g_win.windowNumber(), g_aux.windowNumber(), g_win.styleMask());

    instr("step", "name=script_timer_start interval_ms=200");
    NSTimer.scheduledTimerWithTimeInterval(0.2, g_dlg, SEL.register("tick:"), null, true);

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "steps=%d suppressed_didUpdate_notes=%d", g_step, g_updates);
    return 0;
}
