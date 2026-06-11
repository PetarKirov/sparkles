// macOS/AppKit F15 demo — popup with "grab" (../../../features/f15-popup.md).
// macOS has no popup grab: a context menu built from raw windows is a borderless
// NSWindow (NSWindowStyleMaskBorderless) raised to NSPopUpMenuWindowLevel, and
// "dismiss on outside click" must be assembled from events the popup never
// receives. This demo implements and compares BOTH dismissal mechanisms:
//   (a) +[NSEvent addLocalMonitorForEventsMatchingMask:handler:] (in-app events,
//       block callback) and the global variant (other apps' events — needs
//       nothing for mouse, Accessibility for keys; what each actually sees under
//       an SSH-launched locked session is logged);
//   (b) the key-window route: canBecomeKeyWindow override (borderless windows
//       refuse key status by default — also required for Esc/keyDown!) +
//       windowDidResignKey as the dismissal signal.
// Plus: 3 items with tracking-area hover highlight, Esc via keyDown →
// interpretKeyEvents: → cancelOperation:, app-computed clamping near the
// bottom-right screen edge (and whether constrainFrameRect:toScreen: auto-clamps
// a borderless window — the override logs every call), and a one-level submenu
// as a child window (addChildWindow:ordered: — stacking + move-with-parent).
//
// All clicks/keys are synthetic (A[ssh], locked console): CGEvent-wrapped
// right-click per the f06/f07 recipes, plain NSEvent left-clicks/keys, dispatched
// via [NSApp postEvent:] (so local monitors see them) or [window sendEvent:]
// (fallback: direct method call — every route taken is logged).
//
// Modes: WSI_AUTO_EXIT=1 = bounded scripted run; without it the window stays up
// for a manual (Tier C) session. Headless-safe: prints `SKIP:` and exits 0.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;

import instrument : instr, instrInit;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d
import objc.block : Block, block;
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
    int CGWindowLevelForKey(int key);

    void* CGEventCreateMouseEvent(void* source, uint type, NSPoint pos, uint button);
    void CFRelease(void* obj);

    void* CGSessionCopyCurrentDictionary();
    void* CFStringCreateWithCString(void* alloc, const(char)* s, uint encoding);
    void* CFDictionaryGetValue(void* dict, void* key);
    ubyte CFBooleanGetValue(void* b);

    void CGContextSetRGBFillColor(void* ctx, double r, double g, double b, double a);
    void CGContextFillRect(void* ctx, NSRect rect);
}

enum uint kCFStringEncodingUTF8 = 0x08000100;
enum uint kCGEventRightMouseDown = 3;
enum uint kCGMouseButtonRight = 1;

// CGWindowLevelKey values (CGWindowLevel.h).
enum : int
{
    kCGNormalWindowLevelKey = 4,
    kCGFloatingWindowLevelKey = 5,
    kCGPopUpMenuWindowLevelKey = 11,
    kCGScreenSaverWindowLevelKey = 13,
    kCGMaximumWindowLevelKey = 14,
}

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
    void* locked = CFDictionaryGetValue(dict, kLocked);
    instr("session", "screen_locked=%d",
        locked !is null && CFBooleanGetValue(locked) ? 1 : 0);
    CFRelease(kLocked);
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
}

extern class NSArray : NSObject
{
    static NSArray arrayWithObject(NSObject o) @selector("arrayWithObject:");
}

extern class NSNotification : NSObject
{
    NSObject object() @selector("object");
}

extern class NSEvent : NSObject
{
    static NSEvent mouseEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, long eventNumber,
        long clickCount, double pressure)
        @selector("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:");
    static NSEvent keyEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, NSString characters,
        NSString charactersIgnoringModifiers, bool isARepeat, ushort keyCode)
        @selector("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:");
    static NSEvent eventWithCGEvent(void* cgEvent) @selector("eventWithCGEvent:");
    static NSEvent otherEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, short subtype,
        long data1, long data2)
        @selector("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
    static NSObject addLocalMonitorForEventsMatchingMask(ulong mask,
        Block!(void*, void*)* handler)
        @selector("addLocalMonitorForEventsMatchingMask:handler:");
    static NSObject addGlobalMonitorForEventsMatchingMask(ulong mask,
        Block!(void, void*)* handler)
        @selector("addGlobalMonitorForEventsMatchingMask:handler:");
    static void removeMonitor(NSObject monitor) @selector("removeMonitor:");
    long type() @selector("type");
    NSPoint locationInWindow() @selector("locationInWindow");
    long windowNumber() @selector("windowNumber");
    ushort keyCode() @selector("keyCode");
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
    void sendEvent(NSEvent event) @selector("sendEvent:");
}

extern class NSGraphicsContext : NSObject
{
    static NSGraphicsContext currentContext() @selector("currentContext");
    void* CGContext() @selector("CGContext");
}

extern class NSTrackingArea : NSObject
{
    static NSTrackingArea alloc() @selector("alloc");
    NSTrackingArea initWithRect(NSRect rect, ulong options, NSObject owner,
        NSObject userInfo) @selector("initWithRect:options:owner:userInfo:");
}

extern class NSView : NSObject
{
    NSRect bounds() @selector("bounds");
    void setNeedsDisplay(bool flag) @selector("setNeedsDisplay:");
    void addTrackingArea(NSTrackingArea area) @selector("addTrackingArea:");
    void interpretKeyEvents(NSArray events) @selector("interpretKeyEvents:");
    bool acceptsFirstResponder() @selector("acceptsFirstResponder");
}

extern class NSWindow : NSObject
{
    // (alloc is declared on the leaf classes — a base declaration clashes with
    // the covariant leaf override, per the scaffold recipe.)
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer) @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void setContentView(NSObject view) @selector("setContentView:");
    void setDelegate(NSObject d) @selector("setDelegate:");
    void setReleasedWhenClosed(bool b) @selector("setReleasedWhenClosed:");
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
    bool makeFirstResponder(NSObject responder) @selector("makeFirstResponder:");
    void orderOut(NSObject sender) @selector("orderOut:");
    void orderFront(NSObject sender) @selector("orderFront:");
    void sendEvent(NSEvent event) @selector("sendEvent:");
    long windowNumber() @selector("windowNumber");
    NSRect frame() @selector("frame");
    void setFrameOrigin(NSPoint p) @selector("setFrameOrigin:");
    NSRect convertRectToScreen(NSRect r) @selector("convertRectToScreen:");
    long level() @selector("level");
    void setLevel(long level) @selector("setLevel:");
    bool isKeyWindow() @selector("isKeyWindow");
    bool isVisible() @selector("isVisible");
    void addChildWindow(NSWindow child, long ordered) @selector("addChildWindow:ordered:");
    void removeChildWindow(NSWindow child) @selector("removeChildWindow:");
    NSWindow parentWindow() @selector("parentWindow");

    bool canBecomeKeyWindow() @selector("canBecomeKeyWindow");
    NSRect constrainFrameRect(NSRect frameRect, NSObject screen)
        @selector("constrainFrameRect:toScreen:");
}

// A plain leaf so the main window can be alloc'd (see the note in NSWindow).
class PlainWindow : NSWindow
{
    static PlainWindow alloc() @selector("alloc");
}

// The borderless popup window. canBecomeKeyWindow=YES is mechanism (b)'s enabler
// AND the prerequisite for receiving keyDown (Esc); the constrainFrameRect
// override logs whether AppKit ever asks to clamp a borderless window.
class PopupWindow : NSWindow
{
    static PopupWindow alloc() @selector("alloc");

    override bool canBecomeKeyWindow() @selector("canBecomeKeyWindow")
    {
        return true;
    }

    override NSRect constrainFrameRect(NSRect frameRect, NSObject screen)
        @selector("constrainFrameRect:toScreen:")
    {
        immutable r = super.constrainFrameRect(frameRect, screen);
        instr("constrain_frame_rect", "in=(%.0f,%.0f %.0fx%.0f) out=(%.0f,%.0f %.0fx%.0f) screen_nil=%d",
            frameRect.origin.x, frameRect.origin.y, frameRect.size.width, frameRect.size.height,
            r.origin.x, r.origin.y, r.size.width, r.size.height, screen is null ? 1 : 0);
        return r;
    }
}

// The menu surface: 3 items, hover highlight via tracking areas, item click,
// Esc via keyDown → interpretKeyEvents: → cancelOperation:.
class MenuView : NSView
{
    static MenuView alloc() @selector("alloc");
    MenuView initWithFrame(NSRect frame) @selector("initWithFrame:");

    override bool acceptsFirstResponder() @selector("acceptsFirstResponder")
    {
        return true;
    }

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        immutable b = this.bounds();
        CGContextSetRGBFillColor(ctx, 0.22, 0.22, 0.24, 1);
        CGContextFillRect(ctx, b);
        foreach (i; 0 .. kItems)
        {
            if (i == g_hover)
                CGContextSetRGBFillColor(ctx, 0.30, 0.42, 0.65, 1); // hover highlight
            else
                CGContextSetRGBFillColor(ctx, 0.27, 0.27, 0.30, 1);
            immutable r = itemRect(b, i);
            CGContextFillRect(ctx, NSRect(NSPoint(r.origin.x + 2, r.origin.y + 1),
                NSSize(r.size.width - 4, r.size.height - 2)));
        }
    }

    void mouseEntered(NSEvent e) @selector("mouseEntered:")
    {
        immutable i = itemAt(e.locationInWindow());
        instr("tracking", "event=mouseEntered item=%d", i);
        setHover(i);
    }

    void mouseExited(NSEvent e) @selector("mouseExited:")
    {
        instr("tracking", "event=mouseExited item=%d", g_hover);
        setHover(-1);
    }

    void mouseMoved(NSEvent e) @selector("mouseMoved:")
    {
        ++g_movesSeen;
    }

    void mouseDown(NSEvent e) @selector("mouseDown:")
    {
        ++g_itemClicks;
        immutable p = e.locationInWindow();
        immutable i = itemAt(p);
        instr("popup_item", "event=mouseDown item=%d loc=(%.0f,%.0f)", i, p.x, p.y);
        if (i == 1)
            openSubmenu(); // item 1 = "Submenu >" — child-window test
        else if (i >= 0)
            dismissPopup("item_click");
    }

    void keyDown(NSEvent e) @selector("keyDown:")
    {
        instr("key", "event=keyDown keycode=%u routing=interpretKeyEvents", e.keyCode());
        g_escViaCancel = false;
        this.interpretKeyEvents(NSArray.arrayWithObject(e));
        if (!g_escViaCancel && e.keyCode() == 53)
        {
            // Fallback path if the text system did not map Esc to cancelOperation:.
            instr("key", "esc_route=keyCode_fallback");
            dismissPopup("esc_keydown");
        }
    }

    // Esc lands here when routed through the text system (doCommandBySelector:).
    void cancelOperation(NSObject sender) @selector("cancelOperation:")
    {
        g_escViaCancel = true;
        instr("key", "esc_route=cancelOperation");
        dismissPopup("esc_cancelOperation");
    }
}

// Mechanism (b): the popup's delegate — losing key status means "clicked elsewhere".
class PopupDelegate : NSObject
{
    static PopupDelegate alloc() @selector("alloc");
    PopupDelegate init() @selector("init");

    void windowDidResignKey(NSNotification n) @selector("windowDidResignKey:")
    {
        instr("popup_focus", "event=windowDidResignKey armed=%d", g_resignArmed ? 1 : 0);
        if (g_resignArmed && g_popup !is null)
            dismissPopup("resign_key");
    }
}

// The main window's content view: right-click target.
class MainView : NSView
{
    static MainView alloc() @selector("alloc");
    MainView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        CGContextSetRGBFillColor(ctx, 0.13, 0.16, 0.13, 1);
        CGContextFillRect(ctx, this.bounds());
    }

    void rightMouseDown(NSEvent e) @selector("rightMouseDown:")
    {
        immutable p = e.locationInWindow();
        // Anchor = the click point in screen coords; popup opens below-right.
        immutable sp = g_win.convertRectToScreen(NSRect(p, NSSize(1, 1))).origin;
        instr("right_click", "loc_window=(%.0f,%.0f) anchor_screen=(%.0f,%.0f)",
            p.x, p.y, sp.x, sp.y);
        openPopup(sp, "right_click");
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
    NSWindowStyleMaskBorderless = 0,
    NSWindowStyleMaskTitled = 1,
    NSWindowStyleMaskClosable = 2,
    NSWindowStyleMaskResizable = 8,
}

enum ulong NSBackingStoreBuffered = 2;
enum : long
{
    NSEventTypeLeftMouseDown = 1,
    NSEventTypeRightMouseDown = 3,
    NSEventTypeMouseMoved = 5,
    NSEventTypeKeyDown = 10,
    NSEventTypeApplicationDefined = 15,
}

enum ulong NSEventMaskLeftMouseDown = 1UL << NSEventTypeLeftMouseDown;
enum ulong NSEventMaskRightMouseDown = 1UL << NSEventTypeRightMouseDown;
enum long NSWindowAbove = 1;
// NSPopUpMenuWindowLevel == kCGPopUpMenuWindowLevel (read at runtime, expected 101).
enum ulong kTrackingOptions = 0x01 /*MouseEnteredAndExited*/ | 0x80 /*ActiveAlways*/ ;

enum int kItems = 3;
enum double kItemH = 28, kMenuW = 160;
enum double kMenuH = kItems * kItemH;

// --- Demo state ----------------------------------------------------------------------

__gshared NSApplication g_app;
__gshared NSWindow g_win; // main window
__gshared PopupWindow g_popup; // the open popup (null when closed)
__gshared PopupWindow g_submenu; // child window (null when closed)
__gshared MenuView g_menuView;
__gshared PopupDelegate g_popupDlg;
__gshared MainView g_mainView;
__gshared long g_winNum;
__gshared bool g_auto;
__gshared int g_step;
__gshared int g_hover = -1;
__gshared int g_movesSeen;
__gshared bool g_escViaCancel;
__gshared bool g_resignArmed; // mechanism (b) active for the current popup
__gshared NSObject g_localMon, g_globalMon;
__gshared Block!(void*, void*) g_localBlock;
__gshared Block!(void, void*) g_globalBlock;
__gshared int g_localSeen, g_globalSeen;
__gshared int g_opens;
__gshared int g_itemClicks;

NSRect itemRect(NSRect b, int i)
{
    return NSRect(NSPoint(0, b.size.height - (i + 1) * kItemH), NSSize(b.size.width, kItemH));
}

int itemAt(NSPoint p)
{
    if (p.x < 0 || p.x >= kMenuW || p.y < 0 || p.y >= kMenuH)
        return -1;
    immutable i = cast(int) ((kMenuH - p.y) / kItemH);
    return i >= 0 && i < kItems ? i : -1;
}

void setHover(int i)
{
    if (g_hover == i)
        return;
    g_hover = i;
    instr("hover", "item=%d", i);
    if (g_menuView !is null)
        g_menuView.setNeedsDisplay(true);
}

double screenHeight()
{
    return CGDisplayBounds(CGMainDisplayID()).size.height;
}

// --- Event monitors (mechanism a) ------------------------------------------------------

// Called from the local-monitor block (via an attribute-erasing cast — the body
// is ObjC message sends, which never GC-allocate or throw here).
void onLocalEvent(void* ev)
{
    ++g_localSeen;
    NSEvent e = cast(NSEvent) ev;
    immutable wn = e.windowNumber();
    immutable popupWn = g_popup !is null ? g_popup.windowNumber() : -1;
    immutable subWn = g_submenu !is null ? g_submenu.windowNumber() : -1;
    immutable outside = wn != popupWn && wn != subWn;
    instr("monitor", "scope=local type=%ld win=%ld outside_popup=%d", e.type(), wn,
        outside ? 1 : 0);
    if (e.type() == NSEventTypeLeftMouseDown && outside && g_popup !is null)
        dismissPopup("outside_click_local_monitor");
}

void onGlobalEvent(void* ev)
{
    ++g_globalSeen;
    instr("monitor", "scope=global type=%ld", (cast(NSEvent) ev).type());
}

void installMonitors()
{
    g_localBlock = block((void* ev) {
        (cast(void function(void*) nothrow @nogc) &onLocalEvent)(ev);
        return ev; // pass the event through to normal dispatch
    });
    g_globalBlock = block((void* ev) {
        (cast(void function(void*) nothrow @nogc) &onGlobalEvent)(ev);
    });
    g_localMon = NSEvent.addLocalMonitorForEventsMatchingMask(
        NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown, &g_localBlock);
    g_globalMon = NSEvent.addGlobalMonitorForEventsMatchingMask(
        NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown, &g_globalBlock);
    instr("monitor", "installed local=%d global=%d note=global_sees_only_other_apps_no_a11y_needed_for_mouse",
        g_localMon !is null ? 1 : 0, g_globalMon !is null ? 1 : 0);
}

void removeMonitors()
{
    if (g_localMon !is null)
        NSEvent.removeMonitor(g_localMon);
    if (g_globalMon !is null)
        NSEvent.removeMonitor(g_globalMon);
    g_localMon = g_globalMon = null;
}

// --- Popup open / dismiss ----------------------------------------------------------------

// Opens the popup below-right of `anchor` (AppKit screen coords, y-up), with
// app-computed clamping to the screen rect — placement ownership on macOS is
// 100% the app's; nothing repositions a borderless window for you.
NSRect clampToScreen(NSRect r, NSPoint anchor)
{
    immutable sh = screenHeight();
    immutable sw = CGDisplayBounds(CGMainDisplayID()).size.width;
    auto placed = r;
    if (placed.origin.x + r.size.width > sw)
        placed.origin.x = sw - r.size.width; // slide left off the right edge
    if (placed.origin.y < 0)
        placed.origin.y = anchor.y; // flip above the anchor off the bottom edge
    if (placed.origin.y + r.size.height > sh)
        placed.origin.y = sh - r.size.height;
    return placed;
}

// `doClamp=false` places the popup at the raw (possibly off-screen) frame so the
// edge test can measure whether anything else (AppKit, WindowServer) clamps it.
void openPopup(NSPoint anchor, const(char)* why, bool doClamp = true)
{
    if (g_popup !is null)
        dismissPopup("reopen");
    ++g_opens;
    immutable db = CGDisplayBounds(CGMainDisplayID());
    // Desired: top-left corner at the anchor → frame origin (bottom-left, y-up).
    auto want = NSRect(NSPoint(anchor.x, anchor.y - kMenuH), NSSize(kMenuW, kMenuH));
    auto placed = doClamp ? clampToScreen(want, anchor) : want;
    instr("popup_open", "cause=%s anchor=(%.0f,%.0f) gravity=bottom_right want=(%.0f,%.0f %.0fx%.0f) placed=(%.0f,%.0f %.0fx%.0f) app_clamp=%d screen=%.0fx%.0f",
        why, anchor.x, anchor.y, want.origin.x, want.origin.y, want.size.width,
        want.size.height, placed.origin.x, placed.origin.y, placed.size.width,
        placed.size.height, doClamp ? 1 : 0, db.size.width, db.size.height);

    g_popup = cast(PopupWindow) PopupWindow.alloc().initWithContentRect(placed,
        NSWindowStyleMaskBorderless, NSBackingStoreBuffered, false);
    g_popup.setReleasedWhenClosed(false);
    g_popup.setLevel(CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey));
    g_menuView = MenuView.alloc().initWithFrame(NSRect(NSPoint(0, 0), placed.size));
    g_popup.setContentView(g_menuView);
    g_popup.setDelegate(g_popupDlg);
    foreach (i; 0 .. kItems)
        g_menuView.addTrackingArea(NSTrackingArea.alloc().initWithRect(
            itemRect(NSRect(NSPoint(0, 0), placed.size), i), kTrackingOptions,
            g_menuView, null));
    g_hover = -1;
    g_popup.makeKeyAndOrderFront(null); // key status: mechanism (b) + Esc delivery
    g_popup.makeFirstResponder(g_menuView);
    g_resignArmed = false; // armed explicitly by the resign-key script step
    installMonitors();
    immutable f = g_popup.frame();
    instr("popup_placed", "rect=(%.0f,%.0f %.0fx%.0f) level=%ld is_key=%d can_become_key=%d",
        f.origin.x, f.origin.y, f.size.width, f.size.height, g_popup.level(),
        g_popup.isKeyWindow() ? 1 : 0, g_popup.canBecomeKeyWindow() ? 1 : 0);
}

void openSubmenu()
{
    immutable pf = g_popup.frame();
    // One level deep: to the right of item 1, top-aligned with it.
    auto rect = NSRect(NSPoint(pf.origin.x + kMenuW - 4,
        pf.origin.y + kMenuH - 2 * kItemH), NSSize(kMenuW, 2 * kItemH));
    g_submenu = cast(PopupWindow) PopupWindow.alloc().initWithContentRect(rect,
        NSWindowStyleMaskBorderless, NSBackingStoreBuffered, false);
    g_submenu.setReleasedWhenClosed(false);
    auto v = MenuView.alloc().initWithFrame(NSRect(NSPoint(0, 0), rect.size));
    g_submenu.setContentView(v);
    g_popup.addChildWindow(g_submenu, NSWindowAbove);
    g_submenu.orderFront(null);
    immutable f = g_submenu.frame();
    instr("submenu_open", "rect=(%.0f,%.0f %.0fx%.0f) parent_win=%ld child_win=%ld level_parent=%ld level_child=%ld ordered=NSWindowAbove",
        f.origin.x, f.origin.y, f.size.width, f.size.height,
        g_popup.windowNumber(), g_submenu.windowNumber(), g_popup.level(),
        g_submenu.level());
}

void dismissPopup(const(char)* cause)
{
    if (g_popup is null)
        return;
    instr("popup_dismiss", "cause=%s", cause);
    g_resignArmed = false;
    if (g_submenu !is null)
    {
        g_popup.removeChildWindow(g_submenu);
        g_submenu.orderOut(null);
        g_submenu = null;
    }
    removeMonitors();
    g_popup.setDelegate(null);
    g_popup.orderOut(null);
    g_popup = null;
    g_menuView = null;
}

// --- Synthetic input ------------------------------------------------------------------------

// Right-click, CGEvent-backed (the f06/f07 "route 2 object, route 1 dispatch"
// hybrid): build a CGEvent, wrap via eventWithCGEvent:, dispatch in-process.
void injectRightClick(NSPoint viewPt)
{
    immutable sp = g_win.convertRectToScreen(NSRect(viewPt, NSSize(1, 1))).origin;
    immutable cgPt = NSPoint(sp.x, screenHeight() - sp.y); // CG is y-down
    void* cg = CGEventCreateMouseEvent(null, kCGEventRightMouseDown, cgPt,
        kCGMouseButtonRight);
    NSEvent e = NSEvent.eventWithCGEvent(cg);
    instr("inject", "kind=right_click route=cgevent_wrap view=(%.0f,%.0f) cg=(%.0f,%.0f) wrapped_win=%ld",
        viewPt.x, viewPt.y, cgPt.x, cgPt.y, e !is null ? e.windowNumber() : -1);
    // A wrapped CGEvent carries no window; sendEvent on the target window routes
    // by responder chain, falling back to the direct method call if undelivered.
    if (e !is null)
        g_win.sendEvent(e);
    if (g_popup is null)
    {
        instr("inject", "kind=right_click result=sendEvent_not_delivered fallback=direct_call");
        NSEvent plain = NSEvent.mouseEventWithType(NSEventTypeRightMouseDown, viewPt,
            0, 0, g_winNum, null, 0, 1, 0);
        g_mainView.rightMouseDown(plain);
    }
    CFRelease(cg);
}

// Plain left-click at a window-local point, posted through the app queue so the
// local monitor (which hooks the app's dispatch) gets to see it.
void postLeftClick(NSWindow target, NSPoint pt, const(char)* label)
{
    NSEvent e = NSEvent.mouseEventWithType(NSEventTypeLeftMouseDown, pt, 0, 0,
        target.windowNumber(), null, 0, 1, 0);
    instr("inject", "kind=left_click label=%s win=%ld loc=(%.0f,%.0f) route=postEvent",
        label, target.windowNumber(), pt.x, pt.y);
    g_app.postEvent(e, false);
}

void injectEsc()
{
    NSString esc = NSString.alloc().initWithUTF8String("\x1b");
    NSEvent e = NSEvent.keyEventWithType(NSEventTypeKeyDown, NSPoint(0, 0), 0, 0,
        g_popup.windowNumber(), null, esc, esc, false, 53);
    instr("inject", "kind=esc keycode=53 win=%ld is_key=%d route=sendEvent",
        g_popup.windowNumber(), g_popup.isKeyWindow() ? 1 : 0);
    g_popup.sendEvent(e);
}

// --- The scripted run --------------------------------------------------------------------------

void stopApp()
{
    instr("step", "name=NSApp_stop");
    g_app.stop(null);
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true);
}

void onStep()
{
    if (!g_auto)
        return;
    switch (g_step)
    {
    case 0: // The window-level ladder this demo slots into.
        instr("levels", "normal=%d floating=%d popup_menu=%d screensaver=%d maximum=%d",
            CGWindowLevelForKey(kCGNormalWindowLevelKey),
            CGWindowLevelForKey(kCGFloatingWindowLevelKey),
            CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey),
            CGWindowLevelForKey(kCGScreenSaverWindowLevelKey),
            CGWindowLevelForKey(kCGMaximumWindowLevelKey));
        break;
    case 1: // Open via synthetic right-click.
        injectRightClick(NSPoint(240, 160));
        break;
    case 2: // Hover: do synthetic moves reach tracking areas? (cursor-driven — no)
        {
            if (g_popup is null)
                break;
            NSEvent mv = NSEvent.mouseEventWithType(NSEventTypeMouseMoved,
                NSPoint(kMenuW / 2, kMenuH - kItemH / 2), 0, 0,
                g_popup.windowNumber(), null, 0, 0, 0);
            immutable before = g_movesSeen;
            g_popup.sendEvent(mv);
            instr("tracking", "probe=synthetic_mouseMoved delivered_to_view=%d entered_fired=%d note=tracking_areas_are_cursor_driven",
                g_movesSeen - before, g_hover >= 0 ? 1 : 0);
            if (g_hover < 0)
                setHover(0); // drive the highlight directly for the visual path
        }
        break;
    case 3: // Click item 1 → submenu (child window).
        if (g_popup !is null)
        {
            NSEvent e = NSEvent.mouseEventWithType(NSEventTypeLeftMouseDown,
                NSPoint(kMenuW / 2, kMenuH - kItemH - kItemH / 2), 0, 0,
                g_popup.windowNumber(), null, 0, 1, 0);
            immutable before = g_itemClicks;
            g_popup.sendEvent(e);
            if (g_itemClicks == before)
            {
                // Same f10 finding: [window sendEvent:] drops synthetic mouse
                // events under the locked session — call the handler directly.
                instr("inject", "kind=item_click result=sendEvent_not_delivered fallback=direct_call");
                g_menuView.mouseDown(e);
            }
        }
        break;
    case 4: // Move-with-parent proof.
        if (g_popup !is null && g_submenu !is null)
        {
            immutable before = g_submenu.frame();
            immutable pf = g_popup.frame();
            g_popup.setFrameOrigin(NSPoint(pf.origin.x + 24, pf.origin.y + 24));
            immutable after = g_submenu.frame();
            instr("child_move", "parent_moved=(+24,+24) child_before=(%.0f,%.0f) child_after=(%.0f,%.0f) parent_of_child=%ld",
                before.origin.x, before.origin.y, after.origin.x, after.origin.y,
                g_submenu.parentWindow() !is null
                    ? g_submenu.parentWindow().windowNumber() : -1);
        }
        break;
    case 5: // Outside click → local monitor dismissal (mechanism a).
        postLeftClick(g_win, NSPoint(50, 50), "outside_click");
        break;
    case 6: // Reopen near the bottom-right screen edge, UNclamped: who fixes it?
        {
            instr("monitor", "after_outside_click popup_open=%d local_seen=%d global_seen=%d",
                g_popup !is null ? 1 : 0, g_localSeen, g_globalSeen);
            immutable db = CGDisplayBounds(CGMainDisplayID());
            openPopup(NSPoint(db.size.width - 30, 40), "edge_test_bottom_right", false);
        }
        break;
    case 7: // Nobody clamped it — apply the app-side math and read back.
        if (g_popup !is null)
        {
            immutable before = g_popup.frame();
            immutable db = CGDisplayBounds(CGMainDisplayID());
            immutable anchor = NSPoint(db.size.width - 30, 40);
            immutable target = clampToScreen(NSRect(NSPoint(anchor.x, anchor.y - kMenuH),
                NSSize(kMenuW, kMenuH)), anchor);
            g_popup.setFrameOrigin(target.origin);
            immutable after = g_popup.frame();
            instr("edge_clamp", "offscreen_frame=(%.0f,%.0f) app_clamped_to=(%.0f,%.0f) readback=(%.0f,%.0f) owner=app",
                before.origin.x, before.origin.y, target.origin.x, target.origin.y,
                after.origin.x, after.origin.y);
        }
        break;
    case 8: // Esc → keyDown → cancelOperation: (needs key status on borderless!).
        if (g_popup !is null)
            injectEsc();
        break;
    case 9: // Reopen, then arm mechanism (b) and steal key status.
        openPopup(NSPoint(400, 400), "resign_key_test");
        g_resignArmed = true;
        break;
    case 10:
        if (g_popup !is null)
        {
            instr("popup_focus", "action=makeKeyAndOrderFront_main popup_is_key=%d",
                g_popup.isKeyWindow() ? 1 : 0);
            if (!g_popup.isKeyWindow())
                instr("popup_focus", "mechanism_b=untestable_headless note=no_window_gets_key_status_in_locked_session tier_c=resign_key_dismissal");
            g_win.makeKeyAndOrderFront(null); // → popup windowDidResignKey → dismiss
        }
        break;
    case 11:
        instr("summary", "opens=%d popup_open=%d item_clicks=%d local_seen=%d global_seen=%d",
            g_opens, g_popup !is null ? 1 : 0, g_itemClicks, g_localSeen, g_globalSeen);
        dismissPopup("shutdown");
        stopApp();
        break;
    default:
        stopApp();
        break;
    }
    ++g_step;
}

int main()
{
    g_auto = getenv("WSI_AUTO_EXIT") !is null;
    instrInit("APPKIT_F15");
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

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    g_win = PlainWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f15-popup"));
    g_win.setReleasedWhenClosed(false);
    g_mainView = MainView.alloc().initWithFrame(NSRect(NSPoint(0, 0), contentRect.size));
    g_win.setContentView(g_mainView);
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);
    g_winNum = g_win.windowNumber();
    g_popupDlg = PopupDelegate.alloc().init();
    instr("window_created", "win_num=%ld", g_winNum);

    instr("step", "name=script_timer_start interval_ms=250");
    NSTimer.scheduledTimerWithTimeInterval(0.25, g_mainView, SEL.register("tick:"), null, true);

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "steps=%d opens=%d local_seen=%d global_seen=%d moves_seen=%d",
        g_step, g_opens, g_localSeen, g_globalSeen, g_movesSeen);
    return 0;
}
