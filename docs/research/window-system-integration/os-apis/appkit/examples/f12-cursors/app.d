// macOS/AppKit F12 demo — cursors (../../../features/f12-cursors.md).
// The server composites the cursor on macOS; the app's job is only to SAY which
// cursor — via NSCursor standard cursors set from cursorUpdate: (driven by
// NSTrackingArea with the NSTrackingCursorUpdate option), the legacy
// addCursorRect:cursor: mechanism, or a custom NSCursor initWithImage:hotSpot:.
// Built on the scaffold/f08 recipe; run findings are A[ssh] (locked console — no
// pointer motion possible, so cursorUpdate: is driven directly per zone and the
// on-screen pixels are Tier C).
//
// What it logs:
//   - the standard-cursor VOCABULARY: every public NSCursor class getter probed via
//     class_getClassMethod (available=0/1), including the macOS 15 additions
//     (columnResize/rowResize/zoomIn/zoomOut/frameResizeCursorFromPosition:
//     inDirections:) and the never-public diagonal-resize names — the vocabulary gap
//     vs Win32/X11 is the deliverable;
//   - a 3x3 hover-zone grid of NSTrackingAreas (options MouseEnteredAndExited |
//     CursorUpdate | ActiveInKeyWindow — CursorUpdate is documented as NOT supported
//     with ActiveAlways), each install logged, plus updateTrackingAreas and the
//     legacy resetCursorRects/addCursorRect:cursor: path;
//   - cursor_set per zone driven through cursorUpdate: directly (locked session =
//     no real pointer), with each cursor's image size, rep count and rep pixel
//     widths (the built-in 1x+2x HiDPI pairs);
//   - the eight resize directions: the soft-deprecated pre-15 six
//     (left/right/leftRight/up/down/upDown — no public diagonals before macOS 15)
//     then frameResizeCursorFromPosition:inDirections: for all four edges + four
//     corners via objc_msgSend;
//   - one custom cursor: a CPU-drawn 24x24 ARGB bullseye NSBitmapImageRep plus a
//     48x48 2x rep in the same NSImage (AppKit picks the rep by screen scale at
//     display time), hotspot (12,12), set + read back;
//   - push/pop vs set: the cursor-stack probe (what currentCursor reports after
//     each push/pop/set, including set-under-a-stack);
//   - NSCursor.hide/unhide pairing (the F10 visibility connection);
//   - a synthetic CGEventPost mouse-move probe: does an in-process posted move
//     reach the tracking areas in a locked session? (counters say at exit).
//
// Modes: WSI_AUTO_EXIT=1 = bounded scripted run; without it the window stays up for
// a manual (Tier C) hover session. Headless-safe: prints `SKIP:` and exits 0 when
// there is no window server.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : getenv;
import core.stdc.string : memcpy;

import instrument : instr, instrInit;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d
import objc.rt : SEL, Class, Method;

// Dynamic dispatch for the macOS-15 availability-gated NSCursor getters: resolve
// objc_msgSend via dlsym (objc.rt's own declaration is private) and cast it to the
// exact signature — the Apple-documented calling pattern for objc_msgSend.
import core.sys.posix.dlfcn : dlsym;

enum RTLD_DEFAULT = cast(void*) -2; // dlfcn.h, macOS
alias MsgSend0 = extern (C) void* function(void*, void*) nothrow @nogc;
alias MsgSend2 = extern (C) void* function(void*, void*, ulong, ulong) nothrow @nogc;

void* msgSendAddr()
{
    __gshared void* addr;
    if (addr is null)
        addr = dlsym(RTLD_DEFAULT, "objc_msgSend");
    return addr;
}

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
    NSRect CGDisplayBounds(uint display);
    void CGContextSetRGBFillColor(void* ctx, double r, double g, double b, double a);
    void CGContextFillRect(void* ctx, NSRect rect);
    void* CGEventCreateMouseEvent(void* source, uint type, NSPoint pos, uint button);
    void CGEventPost(uint tap, void* event);
    void CFRelease(void* obj);

}

enum uint kCGEventMouseMoved = 5;
enum uint kCGSessionEventTap = 1;

// NSTrackingAreaOptions (NSTrackingArea.h). Note the header on ActiveAlways:
// "Not supported for NSTrackingCursorUpdate."
enum : ulong
{
    NSTrackingMouseEnteredAndExited = 0x01,
    NSTrackingCursorUpdate = 0x04,
    NSTrackingActiveInKeyWindow = 0x20,
}

// NSCursorFrameResizePosition (NSCursor.h, macOS 15): edges are bits, corners ORs.
enum : ulong
{
    frpTop = 1 << 0,
    frpLeft = 1 << 1,
    frpBottom = 1 << 2,
    frpRight = 1 << 3,
}
enum ulong frameResizeDirectionsAll = 0b11; // Inward | Outward

// --- AppKit class declarations ----------------------------------------------------

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
    ulong count() @selector("count");
    NSObject objectAtIndex(ulong index) @selector("objectAtIndex:");
}

extern class NSEvent : NSObject
{
    static NSEvent otherEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, short subtype,
        long data1, long data2)
        @selector("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
    NSPoint locationInWindow() @selector("locationInWindow");
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

extern class NSImageRep : NSObject
{
    long pixelsWide() @selector("pixelsWide");
    long pixelsHigh() @selector("pixelsHigh");
}

extern class NSBitmapImageRep : NSImageRep
{
    static NSBitmapImageRep alloc() @selector("alloc");
    NSBitmapImageRep initWithBitmapDataPlanes(ubyte** planes, long pixelsWide,
        long pixelsHigh, long bitsPerSample, long samplesPerPixel, bool hasAlpha,
        bool isPlanar, NSString colorSpaceName, long bytesPerRow, long bitsPerPixel)
        @selector("initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:");
    ubyte* bitmapData() @selector("bitmapData");
    void setSize(NSSize size) @selector("setSize:");
}

extern class NSImage : NSObject
{
    static NSImage alloc() @selector("alloc");
    NSImage initWithSize(NSSize size) @selector("initWithSize:");
    void addRepresentation(NSImageRep rep) @selector("addRepresentation:");
    NSSize size() @selector("size");
    NSArray representations() @selector("representations");
}

extern class NSCursor : NSObject
{
    static NSCursor alloc() @selector("alloc");
    NSCursor initWithImage(NSImage image, NSPoint hotSpot)
        @selector("initWithImage:hotSpot:");
    // The pre-macOS-15 public vocabulary (resize* are soft-deprecated since 15).
    static NSCursor arrowCursor() @selector("arrowCursor");
    static NSCursor IBeamCursor() @selector("IBeamCursor");
    static NSCursor crosshairCursor() @selector("crosshairCursor");
    static NSCursor pointingHandCursor() @selector("pointingHandCursor");
    static NSCursor openHandCursor() @selector("openHandCursor");
    static NSCursor resizeLeftCursor() @selector("resizeLeftCursor");
    static NSCursor resizeRightCursor() @selector("resizeRightCursor");
    static NSCursor resizeLeftRightCursor() @selector("resizeLeftRightCursor");
    static NSCursor resizeUpCursor() @selector("resizeUpCursor");
    static NSCursor resizeDownCursor() @selector("resizeDownCursor");
    static NSCursor resizeUpDownCursor() @selector("resizeUpDownCursor");
    static NSCursor currentCursor() @selector("currentCursor");
    static void hide() @selector("hide");
    static void unhide() @selector("unhide");
    void set() @selector("set");
    void push() @selector("push");
    void pop() @selector("pop");
    NSImage image() @selector("image");
    NSPoint hotSpot() @selector("hotSpot");
}

extern class NSTrackingArea : NSObject
{
    static NSTrackingArea alloc() @selector("alloc");
    NSTrackingArea initWithRect(NSRect rect, ulong options, NSObject owner,
        NSObject userInfo) @selector("initWithRect:options:owner:userInfo:");
}

extern class NSResponder : NSObject
{
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
    void addTrackingArea(NSTrackingArea area) @selector("addTrackingArea:");
    NSArray trackingAreas() @selector("trackingAreas");
    void addCursorRect(NSRect rect, NSCursor cursor) @selector("addCursorRect:cursor:");
    void updateTrackingAreas() @selector("updateTrackingAreas");
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
    void invalidateCursorRectsForView(NSView view)
        @selector("invalidateCursorRectsForView:");
    bool areCursorRectsEnabled() @selector("areCursorRectsEnabled");
    NSRect frame() @selector("frame");
}

// The instrumented view: 3x3 zone grid, tracking areas, cursorUpdate: routing.
class ZoneView : NSView
{
    static ZoneView alloc() @selector("alloc");
    ZoneView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        // Checkerboard the 9 zones (the Tier-C visual aid; cheap flat fills).
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        immutable b = this.bounds();
        foreach (z; 0 .. 9)
        {
            immutable shade = 0.25 + 0.08 * z;
            CGContextSetRGBFillColor(ctx, shade, shade, shade, 1);
            CGContextFillRect(ctx, zoneRect(b, z));
        }
    }

    void tick(NSTimer timer) @selector("tick:")
    {
        onTick(this);
    }

    // The modern path: AppKit sends cursorUpdate: when the pointer enters a tracking
    // area registered with NSTrackingCursorUpdate. Locked session = no pointer, so
    // the schedule calls this directly with e=null and g_forcedZone set.
    void cursorUpdate(NSEvent e) @selector("cursorUpdate:")
    {
        ++g_cursorUpdates;
        int zone = g_forcedZone;
        if (e !is null)
        {
            immutable p = e.locationInWindow();
            zone = zoneAt(this.bounds(), p);
        }
        instr("cursor_update", "n=%d zone=%d source=%s", g_cursorUpdates, zone,
            e !is null ? "event".ptr : "driven".ptr);
        if (zone >= 0 && zone < 9)
            setZoneCursor(zone);
    }

    void mouseEntered(NSEvent e) @selector("mouseEntered:")
    {
        ++g_mouseEnters;
        instr("mouse_entered", "n=%d", g_mouseEnters);
    }

    void mouseExited(NSEvent e) @selector("mouseExited:")
    {
        ++g_mouseExits;
        instr("mouse_exited", "n=%d", g_mouseExits);
    }

    // AppKit calls this when tracking areas need recomputation (resize, scroll, …).
    override void updateTrackingAreas() @selector("updateTrackingAreas")
    {
        ++g_updateTrackingCalls;
        instr("update_tracking_areas", "n=%d count=%llu", g_updateTrackingCalls,
            this.trackingAreas().count());
        super.updateTrackingAreas();
    }

    // The legacy mechanism (pre-NSTrackingArea, still alive): AppKit asks the view
    // to re-declare its cursor rects; one addCursorRect:cursor: per region.
    void resetCursorRects() @selector("resetCursorRects")
    {
        ++g_resetCursorRects;
        this.addCursorRect(this.bounds(), NSCursor.crosshairCursor());
        instr("reset_cursor_rects", "n=%d mechanism=addCursorRect_cursor legacy=1",
            g_resetCursorRects);
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
__gshared ZoneView g_view;
__gshared NSCursor g_customCursor;
__gshared int g_tick, g_cursorUpdates, g_mouseEnters, g_mouseExits;
__gshared int g_updateTrackingCalls, g_resetCursorRects, g_forcedZone = -1;
__gshared bool g_auto, g_stopRequested;

// Name registry so currentCursor() pointers are loggable by name.
__gshared void*[40] g_curPtrs;
__gshared const(char)*[40] g_curNames;
__gshared int g_curCount;

// Schedule (ticks of a ~16 ms timer).
enum zoneDriveStartTick = 5; // zones 0..8 on ticks 5..13
enum legacyResizeTick = 16;
enum macos15Tick = 18;
enum invalidateRectsTick = 20;
enum cgEventTick = 24;
enum syntheticResultTick = 38;
enum autoExitTick = 45;

NSString nsstr(const(char)* s)
{
    return NSString.alloc().initWithUTF8String(s);
}

NSRect zoneRect(NSRect b, int z)
{
    immutable w = b.size.width / 3, h = b.size.height / 3;
    return NSRect(NSPoint(b.origin.x + (z % 3) * w, b.origin.y + (z / 3) * h),
        NSSize(w, h));
}

int zoneAt(NSRect b, NSPoint p)
{
    if (b.size.width <= 0 || b.size.height <= 0)
        return -1;
    immutable cx = cast(int) (3 * (p.x - b.origin.x) / b.size.width);
    immutable cy = cast(int) (3 * (p.y - b.origin.y) / b.size.height);
    return cx < 0 || cx > 2 || cy < 0 || cy > 2 ? -1 : cy * 3 + cx;
}

void registerCursor(NSCursor c, const(char)* name)
{
    if (c is null || g_curCount >= g_curPtrs.length)
        return;
    g_curPtrs[g_curCount] = cast(void*) c;
    g_curNames[g_curCount] = name;
    ++g_curCount;
}

const(char)* cursorName(NSCursor c)
{
    foreach (i; 0 .. g_curCount)
        if (g_curPtrs[i] is cast(void*) c)
            return g_curNames[i];
    return c is null ? "nil".ptr : "unregistered".ptr;
}

// One cursor_set log line, with the image facts (size in points, reps, rep pixel
// widths — standard cursors ship 1x+2x pairs; that is the HiDPI mechanism).
void setAndLog(NSCursor c, const(char)* name, const(char)* path)
{
    if (c is null)
    {
        instr("cursor_set", "name=%s path=%s skipped=nil", name, path);
        return;
    }
    registerCursor(c, name);
    c.set();
    NSImage img = c.image();
    immutable sz = img !is null ? img.size() : NSSize(0, 0);
    immutable hot = c.hotSpot();
    char[64] reps = void;
    repsSummary(img, reps[]);
    instr("cursor_set", "name=%s path=%s size_pt=%.0fx%.0f hotspot=(%.0f,%.0f) reps=%s",
        name, path, sz.width, sz.height, hot.x, hot.y, reps.ptr);
}

// "n:px1,px2,…" — rep count and per-rep pixel width.
void repsSummary(NSImage img, char[] buf)
{
    buf[0] = '0';
    buf[1] = 0;
    if (img is null)
        return;
    NSArray rs = img.representations();
    immutable n = rs.count();
    size_t off = snprintf(buf.ptr, buf.length, "%llu:", n);
    foreach (i; 0 .. n)
    {
        auto r = cast(NSImageRep) rs.objectAtIndex(i);
        off += snprintf(buf.ptr + off, buf.length - off, i == 0 ? "%ld" : ",%ld",
            r.pixelsWide());
    }
}

// --- The standard-cursor vocabulary probe -------------------------------------------

void probeVocabulary()
{
    // Public class getters (pre-15 + the macOS 15 additions), the parameterized
    // 15.0 selectors, and the diagonal names that never existed publicly.
    static struct Probe
    {
        string sel;
        string note;
    }

    static immutable Probe[] probes = [
        {"arrowCursor", "10.0"},
        {"IBeamCursor", "10.0"},
        {"IBeamCursorForVerticalLayout", "10.7"},
        {"crosshairCursor", "10.0"},
        {"pointingHandCursor", "10.0"},
        {"closedHandCursor", "10.0"},
        {"openHandCursor", "10.0"},
        {"operationNotAllowedCursor", "10.5"},
        {"dragLinkCursor", "10.6"},
        {"dragCopyCursor", "10.6"},
        {"contextualMenuCursor", "10.6"},
        {"disappearingItemCursor", "10.0"},
        {"resizeLeftCursor", "10.0_soft_deprecated_15.0"},
        {"resizeRightCursor", "10.0_soft_deprecated_15.0"},
        {"resizeLeftRightCursor", "10.0_soft_deprecated_15.0"},
        {"resizeUpCursor", "10.0_soft_deprecated_15.0"},
        {"resizeDownCursor", "10.0_soft_deprecated_15.0"},
        {"resizeUpDownCursor", "10.0_soft_deprecated_15.0"},
        {"zoomInCursor", "15.0"},
        {"zoomOutCursor", "15.0"},
        {"columnResizeCursor", "15.0"},
        {"rowResizeCursor", "15.0"},
        {"columnResizeCursorInDirections:", "15.0"},
        {"rowResizeCursorInDirections:", "15.0"},
        {"frameResizeCursorFromPosition:inDirections:", "15.0"},
        {"currentCursor", "10.0"},
        {"currentSystemCursor", "10.6_deprecated"},
        // The gap: no public diagonal resize cursors existed before macOS 15.
        {"resizeNorthWestSouthEastCursor", "never_public"},
        {"resizeNorthEastSouthWestCursor", "never_public"},
        {"_windowResizeNorthWestSouthEastCursor", "private"},
    ];

    Class cls = Class.lookup("NSCursor");
    foreach (p; probes)
        instr("vocab", "sel=%s available=%d note=%s", p.sel.ptr,
            cls.getClassMethod(SEL.register(p.sel.ptr)).ptr !is null ? 1 : 0,
            p.note.ptr);
}

// --- The custom bullseye cursor ------------------------------------------------------

// CPU-paint an RGBA bullseye: alternating dark/light rings, transparent corners.
void paintBullseye(ubyte* px, int n)
{
    immutable c = (n - 1) / 2.0;
    foreach (y; 0 .. n)
        foreach (x; 0 .. n)
        {
            immutable dx = x - c, dy = y - c;
            immutable r = (dx * dx + dy * dy) ^^ 0.5;
            ubyte* p = px + 4 * (y * n + x);
            if (r > c) // outside: fully transparent
            {
                p[0] = p[1] = p[2] = p[3] = 0;
                continue;
            }
            immutable ring = cast(int) (r * 8 / n); // 0..3 rings
            immutable dark = (ring & 1) == 0;
            p[0] = dark ? 16 : 240; // R (premultiplied; alpha=255 so identical)
            p[1] = dark ? 16 : 64; // G
            p[2] = dark ? 16 : 32; // B
            p[3] = 255; // A
        }
}

NSBitmapImageRep makeRep(int px, double sizePt)
{
    auto rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes(null, px, px, 8, 4,
        true, false, nsstr("NSDeviceRGBColorSpace"), px * 4, 32);
    paintBullseye(rep.bitmapData(), px);
    rep.setSize(NSSize(sizePt, sizePt)); // pt size != px size on the 2x rep
    return rep;
}

NSCursor buildCustomCursor()
{
    NSImage img = NSImage.alloc().initWithSize(NSSize(24, 24));
    img.addRepresentation(makeRep(24, 24)); // 1x
    img.addRepresentation(makeRep(48, 24)); // 2x — AppKit picks by screen scale
    NSCursor cur = NSCursor.alloc().initWithImage(img, NSPoint(12, 12));
    char[64] reps = void;
    repsSummary(img, reps[]);
    immutable hot = cur.hotSpot();
    instr("custom_cursor", "image_pt=%.0fx%.0f reps=%s hotspot=(%.0f,%.0f) "
            ~ "note=hotspot_in_flipped_image_coords", img.size().width,
        img.size().height, reps.ptr, hot.x, hot.y);
    return cur;
}

// --- Probes -------------------------------------------------------------------------

void logCurrent(const(char)* after)
{
    NSCursor cur = NSCursor.currentCursor();
    instr("cursor_stack", "after=%s current=%s", after, cursorName(cur));
}

// push/pop vs set: what does the app-side stack report?
void stackProbe()
{
    NSCursor arrow = NSCursor.arrowCursor();
    NSCursor ibeam = NSCursor.IBeamCursor();
    NSCursor cross = NSCursor.crosshairCursor();
    NSCursor hand = NSCursor.pointingHandCursor();
    registerCursor(arrow, "arrow");
    registerCursor(ibeam, "iBeam");
    registerCursor(cross, "crosshair");
    registerCursor(hand, "pointingHand");

    instr("step", "name=stack_probe");
    arrow.set();
    logCurrent("arrow.set");
    ibeam.push();
    logCurrent("iBeam.push");
    cross.push();
    logCurrent("crosshair.push");
    hand.set(); // set while two pushes are outstanding: replace top? bypass?
    logCurrent("pointingHand.set_under_stack");
    cross.pop();
    logCurrent("pop_1");
    ibeam.pop();
    logCurrent("pop_2");
    arrow.set();
    logCurrent("arrow.set_final");

    // The F10 connection: hide/unhide is a balanced counter, independent of which
    // cursor is set — a capture/lock mode must pair them or leak invisibility.
    NSCursor.hide();
    NSCursor.unhide();
    instr("cursor_visibility", "hide_unhide=balanced note=f10_lock_pairing");
}

// Zone -> cursor mapping (zones 0..8, row-major from bottom-left in view coords).
void setZoneCursor(int zone)
{
    switch (zone)
    {
    case 0:
        setAndLog(NSCursor.arrowCursor(), "arrow", "standard");
        break;
    case 1:
        setAndLog(NSCursor.IBeamCursor(), "iBeam", "standard");
        break;
    case 2:
        setAndLog(NSCursor.pointingHandCursor(), "pointingHand", "standard");
        break;
    case 3:
        setAndLog(NSCursor.crosshairCursor(), "crosshair", "standard");
        break;
    case 4:
        setAndLog(NSCursor.openHandCursor(), "openHand", "standard");
        break;
    case 5:
        setAndLog(NSCursor.resizeLeftRightCursor(), "resizeLeftRight",
            "standard_soft_deprecated");
        break;
    case 6:
        setAndLog(NSCursor.resizeUpDownCursor(), "resizeUpDown",
            "standard_soft_deprecated");
        break;
    case 7:
        setAndLog(macos15Cursor("columnResizeCursor"), "columnResize", "macos15");
        break;
    case 8:
        setAndLog(g_customCursor, "customBullseye", "initWithImage_hotSpot");
        break;
    default:
        break;
    }
}

// Availability-gated class getter via the runtime (returns null when absent).
NSCursor macos15Cursor(const(char)* sel)
{
    Class cls = Class.lookup("NSCursor");
    auto s = SEL.register(sel);
    if (cls.getClassMethod(s).ptr is null)
        return null;
    auto send0 = cast(MsgSend0) msgSendAddr();
    return cast(NSCursor) send0(cls.ptr, s.ptr);
}

// The eight resize directions, both vocabularies.
void resizeSequence()
{
    instr("step", "name=legacy_resize_six note=no_public_diagonals_before_macos15");
    setAndLog(NSCursor.resizeLeftCursor(), "resizeLeft", "standard_soft_deprecated");
    setAndLog(NSCursor.resizeRightCursor(), "resizeRight", "standard_soft_deprecated");
    setAndLog(NSCursor.resizeLeftRightCursor(), "resizeLeftRight",
        "standard_soft_deprecated");
    setAndLog(NSCursor.resizeUpCursor(), "resizeUp", "standard_soft_deprecated");
    setAndLog(NSCursor.resizeDownCursor(), "resizeDown", "standard_soft_deprecated");
    setAndLog(NSCursor.resizeUpDownCursor(), "resizeUpDown",
        "standard_soft_deprecated");
}

void frameResizeSequence()
{
    Class cls = Class.lookup("NSCursor");
    auto s = SEL.register("frameResizeCursorFromPosition:inDirections:");
    if (cls.getClassMethod(s).ptr is null)
    {
        instr("step", "name=frame_resize_eight available=0");
        return;
    }
    instr("step", "name=frame_resize_eight available=1");
    static immutable string[8] names = ["top", "left", "bottom", "right", "topLeft",
        "topRight", "bottomLeft", "bottomRight"];
    static immutable ulong[8] pos = [frpTop, frpLeft, frpBottom, frpRight,
        frpTop | frpLeft, frpTop | frpRight, frpBottom | frpLeft,
        frpBottom | frpRight];
    foreach (i; 0 .. 8)
    {
        auto send2 = cast(MsgSend2) msgSendAddr();
        auto c = cast(NSCursor) send2(cls.ptr, s.ptr, pos[i], frameResizeDirectionsAll);
        char[32] nm = void;
        snprintf(nm.ptr, nm.length, "frameResize.%s", names[i].ptr);
        setAndLog(c, nm.ptr, "macos15_frame_resize");
    }
}

// Synthetic pointer motion: post a CGEvent mouse-move into zone centers. In-process
// posting needs no accessibility grant, but a locked session has no live pointer
// pipeline — counters at syntheticResultTick give the honest answer.
void cgEventProbe()
{
    immutable wf = g_win.frame(); // AppKit global coords: bottom-left origin, y-up
    immutable db = CGDisplayBounds(CGMainDisplayID()); // CG: top-left origin
    // Global CG point of the window-content center.
    immutable gx = wf.origin.x + wf.size.width / 2;
    immutable gy = db.size.height - (wf.origin.y + wf.size.height / 2);
    instr("step", "name=cg_event_probe target_global=(%.0f,%.0f) tap=session", gx, gy);
    foreach (i; 0 .. 2)
    {
        void* ev = CGEventCreateMouseEvent(null, kCGEventMouseMoved,
            NSPoint(gx + i * 40, gy), 0);
        CGEventPost(kCGSessionEventTap, ev);
        CFRelease(ev);
    }
    instr("cg_event_posted", "moves=2");
}

void installTrackingAreas(ZoneView view)
{
    immutable b = view.bounds();
    immutable opts = NSTrackingMouseEnteredAndExited | NSTrackingCursorUpdate
        | NSTrackingActiveInKeyWindow;
    foreach (z; 0 .. 9)
    {
        immutable r = zoneRect(b, z);
        auto area = NSTrackingArea.alloc().initWithRect(r, opts, view, null);
        view.addTrackingArea(area);
        instr("tracking_install", "zone=%d rect=(%.0f,%.0f %.0fx%.0f) options=0x%llx",
            z, r.origin.x, r.origin.y, r.size.width, r.size.height, opts);
    }
    instr("tracking_areas", "count=%llu note=cursor_update_incompatible_with_active_always",
        view.trackingAreas().count());
}

void onTick(ZoneView view)
{
    ++g_tick;
    if (!g_auto)
        return; // interactive mode: keep the window up for a manual hover session

    if (g_tick >= zoneDriveStartTick && g_tick < zoneDriveStartTick + 9)
    {
        g_forcedZone = g_tick - zoneDriveStartTick;
        view.cursorUpdate(null); // drive the cursorUpdate: logic directly (no pointer)
        g_forcedZone = -1;
    }
    else if (g_tick == legacyResizeTick)
        resizeSequence();
    else if (g_tick == macos15Tick)
        frameResizeSequence();
    else if (g_tick == invalidateRectsTick)
    {
        instr("step", "name=invalidateCursorRectsForView rects_enabled=%d",
            g_win.areCursorRectsEnabled() ? 1 : 0);
        g_win.invalidateCursorRectsForView(view);
    }
    else if (g_tick == cgEventTick)
        cgEventProbe();
    else if (g_tick == syntheticResultTick)
        instr("synthetic_result", "cursor_updates_from_events=%d mouse_entered=%d "
                ~ "mouse_exited=%d reset_cursor_rects=%d note=locked_session",
            g_cursorUpdates - 9, g_mouseEnters, g_mouseExits, g_resetCursorRects);
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
    instrInit("APPKIT_F12");
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

    probeVocabulary();

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(nsstr("wsi-f12-cursors"));

    g_view = ZoneView.alloc().initWithFrame(contentRect);
    g_win.setContentView(g_view);
    g_win.setDelegate(g_view);
    installTrackingAreas(g_view);
    g_win.makeKeyAndOrderFront(null);

    g_customCursor = buildCustomCursor();
    registerCursor(g_customCursor, "customBullseye");
    stackProbe();

    instr("step", "name=NSTimer_scheduledTimerWithTimeInterval interval_ms=16");
    NSTimer.scheduledTimerWithTimeInterval(0.016, g_view, SEL.register("tick:"), null,
        true);

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "ticks=%d cursor_updates=%d mouse_entered=%d mouse_exited=%d "
            ~ "update_tracking=%d reset_rects=%d",
        g_tick, g_cursorUpdates, g_mouseEnters, g_mouseExits, g_updateTrackingCalls,
        g_resetCursorRects);
    return 0;
}
