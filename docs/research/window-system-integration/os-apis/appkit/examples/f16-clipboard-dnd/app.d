// macOS/AppKit F16 demo — clipboard + drag-and-drop (../../../features/f16-clipboard-dnd.md).
// The pasteboard server (com.apple.pboard) is the negotiation peer; this demo logs
// every step of the format negotiation:
//   COPY (eager): clearContents (changeCount bump = the ownership signal) +
//     setString:"é漢🎈" forType:public.utf8-plain-text; verified cross-process by
//     spawning `pbpaste` and diffing its bytes.
//   COPY (lazy): declareTypes:owner: + pasteboard:provideDataForType: — the promise
//     variant. The demo measures WHEN the promise is demanded (only when `pbpaste`
//     actually reads, N ticks after the declare) and on which thread.
//   Source-exits-first: run modes WSI_MODE=promise-exit-return / promise-exit-hard
//     declare a promise and quit WITHOUT rendering it — the driver's pbpaste then
//     shows who pays (run.sh / the findings doc record the outcome).
//   PASTE: an external `pbcopy` write is detected by polling changeCount in the
//     tick timer (there is NO change notification on macOS — polling is the only
//     change signal); the demo then logs the offered types array, the chosen type,
//     and the byte count. pasteboardChangedOwner: on the old owner logs the
//     ownership-loss callback (or its absence).
//   DnD: the content view is registerForDraggedTypes: (file URL + string) and
//     implements the full NSDraggingDestination protocol (draggingEntered/Updated/
//     Exited/performDragOperation, NSDragOperation masks logged); the source side
//     starts beginDraggingSessionWithItems:event:source: (NSDraggingSource) with a
//     synthetic mouse-down over its own view. Under A[ssh]+locked console the
//     session may never deliver destination events — logged honestly (Tier C).
//
// Modes: WSI_AUTO_EXIT=1 = bounded scripted run (default for CI);
//        WSI_MODE=promise-exit-return | promise-exit-hard = the unrendered-promise
//        probes (no run loop; exits immediately after the declare).
// Headless-safe: prints `SKIP:` and exits 0 when no window server is reachable.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf, fopen, fread, fclose, FILE, snprintf;
import core.stdc.stdlib : getenv, system;
import core.stdc.string : strlen, strcmp;

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

// --- CoreGraphics / CoreFoundation / libc ------------------------------------------

extern (C) nothrow @nogc
{
    uint CGMainDisplayID();
    void CFRelease(void* obj);
    void* CGSessionCopyCurrentDictionary();
    void* CFStringCreateWithCString(void* alloc, const(char)* s, uint encoding);
    void* CFDictionaryGetValue(void* dict, void* key);
    ubyte CFBooleanGetValue(void* b);
    void CGContextSetRGBFillColor(void* ctx, double r, double g, double b, double a);
    void CGContextFillRect(void* ctx, NSRect rect);
    int pthread_main_np();
    void _exit(int code);
}

enum uint kCFStringEncodingUTF8 = 0x08000100;

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
    // id<NSDraggingInfo> accessors — NSDraggingInfo is a protocol (no class object
    // to link against), and Objective-C dispatch is by selector, so declaring the
    // selectors on NSObject lets the destination methods message the info object.
    NSPasteboard draggingPasteboard() @selector("draggingPasteboard");
    ulong draggingSourceOperationMask() @selector("draggingSourceOperationMask");
    NSPoint draggingLocation() @selector("draggingLocation");
}

extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* s) @selector("initWithUTF8String:");
    const(char)* UTF8String() @selector("UTF8String");
    ulong lengthOfBytesUsingEncoding(ulong enc) @selector("lengthOfBytesUsingEncoding:");
}

extern class NSArray : NSObject
{
    static NSArray arrayWithObject(NSObject o) @selector("arrayWithObject:");
    ulong count() @selector("count");
    NSObject objectAtIndex(ulong i) @selector("objectAtIndex:");
}

extern class NSMutableArray : NSArray
{
    static NSMutableArray array() @selector("array");
    void addObject(NSObject o) @selector("addObject:");
}

extern class NSPasteboard : NSObject
{
    static NSPasteboard generalPasteboard() @selector("generalPasteboard");
    static NSPasteboard pasteboardWithName(NSString name) @selector("pasteboardWithName:");
    NSString name() @selector("name");
    long changeCount() @selector("changeCount");
    long clearContents() @selector("clearContents");
    bool setString(NSString s, NSString type) @selector("setString:forType:");
    NSString stringForType(NSString type) @selector("stringForType:");
    NSArray types() @selector("types");
    long declareTypes(NSArray types, NSObject owner) @selector("declareTypes:owner:");
}

extern class NSPasteboardItem : NSObject
{
    static NSPasteboardItem alloc() @selector("alloc");
    NSPasteboardItem init() @selector("init");
    bool setString(NSString s, NSString type) @selector("setString:forType:");
}

extern class NSDraggingItem : NSObject
{
    static NSDraggingItem alloc() @selector("alloc");
    NSDraggingItem initWithPasteboardWriter(NSObject writer)
        @selector("initWithPasteboardWriter:");
    void setDraggingFrame(NSRect frame, NSObject contents)
        @selector("setDraggingFrame:contents:");
}

extern class NSDraggingSession : NSObject
{
    long draggingSequenceNumber() @selector("draggingSequenceNumber");
}

extern class NSEvent : NSObject
{
    static NSEvent mouseEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, long eventNumber,
        long clickCount, double pressure)
        @selector("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:");
    static NSEvent otherEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, short subtype,
        long data1, long data2)
        @selector("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
    long type() @selector("type");
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
    void registerForDraggedTypes(NSArray types) @selector("registerForDraggedTypes:");
    NSWindow window() @selector("window");
    NSDraggingSession beginDraggingSession(NSArray items, NSEvent event, NSObject source)
        @selector("beginDraggingSessionWithItems:event:source:");
}

extern class NSWindow : NSObject
{
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer) @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void setContentView(NSObject view) @selector("setContentView:");
    void setReleasedWhenClosed(bool b) @selector("setReleasedWhenClosed:");
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
    long windowNumber() @selector("windowNumber");
}

class PlainWindow : NSWindow
{
    static PlainWindow alloc() @selector("alloc");
}

// Pasteboard owner: the lazy-promise provider + the ownership-loss callback;
// also the NSDraggingSource for the DnD attempt.
class PBOwner : NSObject
{
    static PBOwner alloc() @selector("alloc");
    PBOwner init() @selector("init");

    // The promise is demanded HERE — only when a reader actually asks for the type.
    void pasteboardProvideDataForType(NSPasteboard pb, NSString type)
        @selector("pasteboard:provideDataForType:")
    {
        ++g_provideCalls;
        instr("clip_request", "fmt=%s lazy=1 main_thread=%d declare_to_demand_us=%llu",
            type.UTF8String(), pthread_main_np(), instrNowUs() - g_declareUs);
        pb.setString(nsstr(kPayload), type); // render the promise
        instr("clip_send", "bytes=%d fmt=%s lazy=1", cast(int) strlen(kPayload),
            type.UTF8String());
    }

    // Old owner's loss signal (clipboard taken by another app). HAZARD, measured:
    // AppKit delivers this from INSIDE -[NSPasteboard changeCount] (the poll), and
    // calling changeCount here re-enters handleOwnershipChange → unbounded
    // recursion → stack-overflow SIGSEGV. Do not touch the pasteboard here.
    void pasteboardChangedOwner(NSPasteboard pb) @selector("pasteboardChangedOwner:")
    {
        ++g_ownerLost;
        instr("ownership_lost", "callback=pasteboardChangedOwner main_thread=%d n=%d",
            pthread_main_np(), g_ownerLost);
    }

    // NSDraggingSource (required method).
    ulong sourceOperationMask(NSDraggingSession session, long context)
        @selector("draggingSession:sourceOperationMaskForDraggingContext:")
    {
        instr("dnd_source", "event=sourceOperationMask context=%ld mask=copy", context);
        return 1; // NSDragOperationCopy
    }

    void sessionWillBegin(NSDraggingSession session, NSPoint p)
        @selector("draggingSession:willBeginAtPoint:")
    {
        instr("dnd_source", "event=willBeginAtPoint loc=(%.0f,%.0f)", p.x, p.y);
    }

    void sessionEnded(NSDraggingSession session, NSPoint p, ulong op)
        @selector("draggingSession:endedAtPoint:operation:")
    {
        instr("dnd_source", "event=endedAtPoint loc=(%.0f,%.0f) operation=%lu", p.x, p.y, op);
    }

    void tick(NSTimer t) @selector("tick:")
    {
        onStep();
    }
}

// The drop target: full NSDraggingDestination protocol, every callback logged.
class DropView : NSView
{
    static DropView alloc() @selector("alloc");
    DropView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        CGContextSetRGBFillColor(ctx, 0.15, 0.2, 0.25, 1);
        CGContextFillRect(ctx, this.bounds());
    }

    ulong draggingEntered(NSObject info) @selector("draggingEntered:")
    {
        ++g_dndEntered;
        logOffer("dnd_enter", info.draggingPasteboard());
        instr("dnd_enter", "source_mask=0x%lx loc=(%.0f,%.0f) accept=copy",
            info.draggingSourceOperationMask(), info.draggingLocation().x,
            info.draggingLocation().y);
        return 1; // NSDragOperationCopy
    }

    ulong draggingUpdated(NSObject info) @selector("draggingUpdated:")
    {
        ++g_dndUpdated;
        if (g_dndUpdated <= 3)
            instr("dnd_update", "loc=(%.0f,%.0f) accept=copy",
                info.draggingLocation().x, info.draggingLocation().y);
        return 1;
    }

    void draggingExited(NSObject info) @selector("draggingExited:")
    {
        instr("dnd_exit", "");
    }

    bool prepareForDragOperation(NSObject info)
        @selector("prepareForDragOperation:")
    {
        instr("dnd_prepare", "accept=1");
        return true;
    }

    bool performDragOperation(NSObject info) @selector("performDragOperation:")
    {
        ++g_dndDropped;
        auto pb = info.draggingPasteboard();
        logOffer("dnd_drop_offer", pb);
        NSString url = pb.stringForType(nsstr("public.file-url"));
        if (url !is null)
            instr("dnd_drop", "fmt=public.file-url bytes=%lu data=%s",
                url.lengthOfBytesUsingEncoding(4), url.UTF8String());
        NSString s = pb.stringForType(nsstr("public.utf8-plain-text"));
        if (s !is null)
            instr("dnd_drop", "fmt=public.utf8-plain-text bytes=%lu data=%s",
                s.lengthOfBytesUsingEncoding(4), s.UTF8String());
        return true;
    }

    void concludeDragOperation(NSObject info)
        @selector("concludeDragOperation:")
    {
        instr("dnd_conclude", "");
    }
}

extern (D): // back to D linkage

enum NSApplicationActivationPolicyRegular = 0;
enum ulong NSWindowStyleMaskTitled = 1;
enum ulong NSBackingStoreBuffered = 2;
enum long NSEventTypeLeftMouseDown = 1;
enum long NSEventTypeApplicationDefined = 15;
enum ulong NSUTF8StringEncoding = 4;

// The non-ASCII payload required by the spec: 2 + 3 + 4 UTF-8 bytes.
__gshared const(char)* kPayload = "é漢🎈";

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared DropView g_view;
__gshared PBOwner g_owner;
__gshared NSPasteboard g_pb;
__gshared bool g_auto;
__gshared int g_step;
__gshared long g_lastSeenCC; // the changeCount poll (the only change signal)
__gshared bool g_pollArmed;
__gshared int g_provideCalls;
__gshared int g_ownerLost;
__gshared ulong g_declareUs;
__gshared int g_dndEntered, g_dndUpdated, g_dndDropped;
__gshared NSDraggingSession g_session;

NSString nsstr(const(char)* s)
{
    return NSString.alloc().initWithUTF8String(s);
}

void logOffer(const(char)* kind, NSPasteboard pb)
{
    auto types = pb.types();
    immutable n = types !is null ? types.count() : 0;
    char[1024] buf = 0;
    size_t off = 0;
    foreach (i; 0 .. n)
    {
        auto t = (cast(NSString) types.objectAtIndex(i)).UTF8String();
        off += snprintf(buf.ptr + off, buf.length - off, "%s%s",
            i ? ",".ptr : "".ptr, t);
        if (off >= buf.length - 1)
            break;
    }
    instr(kind, "change_count=%ld formats=[%s] n=%lu", pb.changeCount(), buf.ptr, n);
}

// Read a small file written by a background pbpaste; returns bytes read.
int readBack(const(char)* path, char[] sink)
{
    FILE* f = fopen(path, "rb");
    if (f is null)
        return -1;
    immutable n = cast(int) fread(sink.ptr, 1, sink.length - 1, f);
    fclose(f);
    sink[n < 0 ? 0 : n] = 0;
    return n;
}

void stopApp()
{
    instr("step", "name=NSApp_stop");
    g_app.stop(null);
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true);
}

// --- The scripted run (one step per 300 ms tick) ------------------------------------

void onStep()
{
    // The changeCount poll runs on every tick: this IS the macOS clipboard event
    // model — NSPasteboard posts no notification on change; readers poll.
    if (g_pollArmed)
    {
        immutable cc = g_pb.changeCount();
        if (cc != g_lastSeenCC)
        {
            instr("clip_external_change", "detected_by=changeCount_poll old=%ld new=%ld",
                g_lastSeenCC, cc);
            g_lastSeenCC = cc;
        }
    }
    if (!g_auto)
        return;
    switch (g_step)
    {
    case 0: // Baseline.
        g_lastSeenCC = g_pb.changeCount();
        instr("step", "name=baseline pb=%s change_count=%ld",
            g_pb.name().UTF8String(), g_lastSeenCC);
        break;
    case 1: // COPY, eager: clearContents bump + setString.
        {
            immutable cc0 = g_pb.changeCount();
            immutable cc1 = g_pb.clearContents();
            immutable ok = g_pb.setString(nsstr(kPayload), nsstr("public.utf8-plain-text"));
            immutable cc2 = g_pb.changeCount();
            instr("clip_copy", "mode=eager fmt=public.utf8-plain-text bytes=%d ok=%d change_count=%ld->%ld(clear)->%ld",
                cast(int) strlen(kPayload), ok ? 1 : 0, cc0, cc1, cc2);
            g_lastSeenCC = cc2;
            // Cross-process verification: pbpaste in another process, async so the
            // run loop keeps servicing the pasteboard server.
            system("/bin/sh -c 'LANG=en_US.UTF-8 pbpaste > /tmp/wsi-m8/f16-eager.txt 2>&1 &'");
        }
        break;
    case 2: // Read pbpaste's harvest back.
        {
            char[256] sink;
            immutable n = readBack("/tmp/wsi-m8/f16-eager.txt", sink);
            instr("clip_verify", "via=pbpaste mode=eager bytes=%d data=%s match=%d",
                n, sink.ptr, n == cast(int) strlen(kPayload)
                    && strcmp(sink.ptr, kPayload) == 0 ? 1 : 0);
        }
        break;
    case 3: // COPY, lazy: declareTypes:owner: — the promise.
        {
            immutable cc0 = g_pb.changeCount();
            auto types = NSMutableArray.array();
            types.addObject(nsstr("public.utf8-plain-text"));
            immutable cc1 = g_pb.declareTypes(types, g_owner);
            g_declareUs = instrNowUs();
            instr("clip_offer", "mode=lazy formats=[public.utf8-plain-text] change_count=%ld->%ld provider_called=%d",
                cc0, cc1, g_provideCalls);
            g_lastSeenCC = g_pb.changeCount();
        }
        break;
    case 4: // One full tick later: still not demanded? Then unleash the reader.
        instr("clip_lazy", "provider_called=%d note=no_reader_yet", g_provideCalls);
        system("/bin/sh -c 'LANG=en_US.UTF-8 pbpaste > /tmp/wsi-m8/f16-lazy.txt 2>&1 &'");
        break;
    case 5: // The promise should have been demanded by pbpaste by now.
        {
            char[256] sink;
            immutable n = readBack("/tmp/wsi-m8/f16-lazy.txt", sink);
            instr("clip_verify", "via=pbpaste mode=lazy bytes=%d data=%s provider_called=%d match=%d",
                n, sink.ptr, g_provideCalls,
                n == cast(int) strlen(kPayload) && strcmp(sink.ptr, kPayload) == 0 ? 1 : 0);
        }
        break;
    case 6: // Ownership loss: an external pbcopy takes the board from us.
        instr("step", "name=external_pbcopy_takeover promise_state=fulfilled");
        system("/bin/sh -c \"printf 'external-Ω' | LANG=en_US.UTF-8 pbcopy &\"");
        g_pollArmed = true; // detection = changeCount poll (top of tick)
        break;
    case 7: // (poll fires above) — nothing; give the takeover a full tick.
        break;
    case 8: // PASTE: offered types first, then the chosen one + byte count.
        {
            logOffer("clip_offer_read", g_pb);
            NSString s = g_pb.stringForType(nsstr("public.utf8-plain-text"));
            if (s !is null)
                instr("clip_paste", "fmt=public.utf8-plain-text bytes=%lu data=%s ownership_lost_callbacks=%d",
                    s.lengthOfBytesUsingEncoding(NSUTF8StringEncoding),
                    s.UTF8String(), g_ownerLost);
            else
                instr("clip_paste", "fmt=public.utf8-plain-text result=nil");
        }
        break;
    case 9: // Ownership loss with an UNFULFILLED promise: declare lazy again …
        {
            auto types = NSMutableArray.array();
            types.addObject(nsstr("public.utf8-plain-text"));
            immutable cc = g_pb.declareTypes(types, g_owner);
            instr("clip_offer", "mode=lazy_unfulfilled change_count=%ld ownership_lost_callbacks=%d",
                cc, g_ownerLost);
            g_lastSeenCC = g_pb.changeCount();
        }
        break;
    case 10: // … and let pbcopy take the board while the promise is pending.
        instr("step", "name=external_pbcopy_takeover promise_state=unfulfilled");
        system("/bin/sh -c \"printf 'takeover2' | LANG=en_US.UTF-8 pbcopy &\"");
        break;
    case 11: // Did pasteboardChangedOwner: fire this time?
        instr("ownership_probe", "callbacks=%d provider_calls=%d note=takeover_with_pending_promise",
            g_ownerLost, g_provideCalls);
        break;
    case 12: // DnD: in-process drag attempt over our own registered view.
        {
            system("/bin/sh -c 'echo wsi-f16-drop-payload > /tmp/wsi-m8/f16-drop.txt'");
            auto item = NSPasteboardItem.alloc().init();
            item.setString(nsstr("file:///tmp/wsi-m8/f16-drop.txt"), nsstr("public.file-url"));
            item.setString(nsstr(kPayload), nsstr("public.utf8-plain-text"));
            auto drag = NSDraggingItem.alloc().initWithPasteboardWriter(item);
            drag.setDraggingFrame(NSRect(NSPoint(100, 100), NSSize(32, 32)), null);
            NSEvent down = NSEvent.mouseEventWithType(NSEventTypeLeftMouseDown,
                NSPoint(120, 120), 0, 0, g_win.windowNumber(), null, 0, 1, 0);
            instr("dnd_begin", "api=beginDraggingSessionWithItems types=[public.file-url,public.utf8-plain-text]");
            g_session = g_view.beginDraggingSession(NSArray.arrayWithObject(drag),
                down, g_owner);
            instr("dnd_session", "started=%d seq=%ld", g_session !is null ? 1 : 0,
                g_session !is null ? g_session.draggingSequenceNumber() : -1);
        }
        break;
    case 13: // Inspect the DRAG pasteboard the session populated.
    case 14:
        break;
    case 15:
        {
            auto dragPb = NSPasteboard.pasteboardWithName(nsstr("Apple CFPasteboard drag"));
            logOffer("dnd_drag_pasteboard", dragPb);
            NSString url = dragPb.stringForType(nsstr("public.file-url"));
            instr("dnd_drag_pasteboard", "file_url=%s",
                url !is null ? url.UTF8String() : "nil");
            instr("dnd_summary", "entered=%d updated=%d dropped=%d note=%s",
                g_dndEntered, g_dndUpdated, g_dndDropped,
                g_dndEntered == 0
                    ? "no_destination_events_headless_locked_session_tierC".ptr
                    : "destination_protocol_exercised".ptr);
        }
        break;
    case 16:
        instr("summary", "provider_calls=%d ownership_lost=%d dnd_entered=%d dnd_dropped=%d",
            g_provideCalls, g_ownerLost, g_dndEntered, g_dndDropped);
        stopApp();
        break;
    default:
        stopApp();
        break;
    }
    ++g_step;
}

// --- Promise-exit modes: declare, then die with the promise unrendered ---------------

int runPromiseExit(bool hard)
{
    g_pb = NSPasteboard.generalPasteboard();
    auto types = NSMutableArray.array();
    types.addObject(nsstr("public.utf8-plain-text"));
    immutable cc = g_pb.declareTypes(types, g_owner);
    instr("clip_offer", "mode=promise_exit formats=[public.utf8-plain-text] change_count=%ld provider_called=%d",
        cc, g_provideCalls);
    if (hard)
    {
        instr("exit", "kind=_exit_2 provider_called=%d note=promise_unrendered", g_provideCalls);
        _exit(2); // no atexit, no ObjC teardown — the source vanishes
    }
    instr("exit", "kind=return_from_main provider_called=%d", g_provideCalls);
    return 0; // normal exit: does anything render the promise on the way out?
}

int main()
{
    g_auto = getenv("WSI_AUTO_EXIT") !is null;
    const(char)* mode = getenv("WSI_MODE");
    instrInit("APPKIT_F16");
    instr("init_start", "auto_exit=%d mode=%s", g_auto ? 1 : 0,
        mode !is null ? mode : "scripted");

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
    g_owner = PBOwner.alloc().init();

    if (mode !is null && strcmp(mode, "promise-exit-return") == 0)
        return runPromiseExit(false);
    if (mode !is null && strcmp(mode, "promise-exit-hard") == 0)
        return runPromiseExit(true);

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 320));
    g_win = PlainWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled, NSBackingStoreBuffered, false);
    g_win.setTitle(nsstr("wsi-f16-clipboard-dnd"));
    g_win.setReleasedWhenClosed(false);
    g_view = DropView.alloc().initWithFrame(NSRect(NSPoint(0, 0), contentRect.size));
    auto dndTypes = NSMutableArray.array();
    dndTypes.addObject(nsstr("public.file-url"));
    dndTypes.addObject(nsstr("public.utf8-plain-text"));
    g_view.registerForDraggedTypes(dndTypes);
    instr("dnd_register", "types=[public.file-url,public.utf8-plain-text]");
    g_win.setContentView(g_view);
    g_win.makeKeyAndOrderFront(null);
    instr("window_created", "win_num=%ld", g_win.windowNumber());

    g_pb = NSPasteboard.generalPasteboard();
    NSTimer.scheduledTimerWithTimeInterval(0.3, g_owner, SEL.register("tick:"), null, true);

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "steps=%d", g_step);
    return 0;
}
