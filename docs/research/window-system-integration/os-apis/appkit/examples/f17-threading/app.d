// macOS/AppKit F17 demo — threading probes (../../../features/f17-threading.md).
// Deliberately violates (and obeys) AppKit's main-thread rule and records exactly
// what breaks. Five --probe=N run modes, each ending in a verdict line
// (`probe n=… result=ok|error|crash|deadlock|silent detail=…`) that survives any
// outcome: fatal-signal handlers (SIGSEGV/SIGBUS/SIGILL/SIGABRT/SIGTRAP) and an
// NSUncaughtExceptionHandler turn crashes into a flushed verdict + _exit(0) —
// capturing AppKit's exact assert/exception text — and a SIGALRM watchdog converts
// hangs into result=deadlock. The no-argument run (what CI executes) spawns every
// probe TWICE as a fresh fork+exec'd child (fork-without-exec is forbidden to
// Objective-C apps on macOS), so a crashed probe can never poison the next and the
// parent always reports.
//
//   1  NSWindow created on a SECOND thread (pthread), main thread pumps events.
//   2  [NSApp run] on main; AFTER the loop starts, a worker creates a window.
//   3  The sanctioned pattern: worker computes, marshals to main via BOTH
//      performSelectorOnMainThread:withObject:waitUntilDone: and
//      dispatch_async_f(dispatch_get_main_queue()) — proves both land on main.
//   4  Render from a second thread: (a) worker fills the CPU buffer and marshals
//      setNeedsDisplay: to main vs (b) DIRECT cross-thread setNeedsDisplay: and
//      lockFocusIfCanDraw + CGContext drawing from the worker.
//   5  NSPasteboard write/read + NSEvent post from a worker thread.
//
// Headless-safe: prints `SKIP:` and exits 0 when no window server is reachable.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf, fprintf, snprintf, stderr, fflush;
import core.stdc.stdlib : getenv, atoi;
import core.stdc.string : strncmp, strlen;

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

// --- POSIX / CoreGraphics / libdispatch --------------------------------------------

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

    int pthread_create(void** thread, const(void)* attr,
        void* function(void*), void* arg);
    int pthread_join(void* thread, void** retval);
    int pthread_main_np();
    int usleep(uint usec);
    uint alarm(uint seconds);
    void function(int) signal(int sig, void function(int) handler);
    void _exit(int code);
    long write(int fd, const(void)* buf, size_t n);
    int fork();
    int execv(const(char)* path, const(char*)* argv);
    int waitpid(int pid, int* status, int options);

    // dispatch_get_main_queue() is a macro for &_dispatch_main_q.
    extern __gshared void* _dispatch_main_q;
    void dispatch_async_f(void* queue, void* context, void function(void*) work);

    alias NSUncaughtExceptionHandler = void function(void* exception);
    void NSSetUncaughtExceptionHandler(NSUncaughtExceptionHandler h);
}

enum uint kCFStringEncodingUTF8 = 0x08000100;
enum : int
{
    SIGILL = 4,
    SIGABRT = 6,
    SIGBUS = 10,
    SIGSEGV = 11,
    SIGALRM = 14,
    SIGTRAP = 5,
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
    void performSelectorOnMainThread(SEL sel, NSObject arg, bool wait)
        @selector("performSelectorOnMainThread:withObject:waitUntilDone:");
}

extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* s) @selector("initWithUTF8String:");
    const(char)* UTF8String() @selector("UTF8String");
}

extern class NSException : NSObject
{
    NSString name() @selector("name");
    NSString reason() @selector("reason");
}

extern class NSPasteboard : NSObject
{
    static NSPasteboard generalPasteboard() @selector("generalPasteboard");
    long changeCount() @selector("changeCount");
    long clearContents() @selector("clearContents");
    bool setString(NSString s, NSString type) @selector("setString:forType:");
    NSString stringForType(NSString type) @selector("stringForType:");
}

extern class NSDate : NSObject
{
    static NSDate distantPast() @selector("distantPast");
}

extern class NSEvent : NSObject
{
    static NSEvent otherEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, short subtype,
        long data1, long data2)
        @selector("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
    long type() @selector("type");
    short subtype() @selector("subtype");
    long data1() @selector("data1");
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
    void sendEvent(NSEvent event) @selector("sendEvent:");
    NSEvent nextEventMatchingMask(ulong mask, NSDate untilDate, NSString inMode,
        bool dequeue)
        @selector("nextEventMatchingMask:untilDate:inMode:dequeue:");
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
    bool lockFocusIfCanDraw() @selector("lockFocusIfCanDraw");
    void unlockFocus() @selector("unlockFocus");
}

extern class NSWindow : NSObject
{
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer) @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void setContentView(NSObject view) @selector("setContentView:");
    void setReleasedWhenClosed(bool b) @selector("setReleasedWhenClosed:");
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
    void orderOut(NSObject sender) @selector("orderOut:");
    long windowNumber() @selector("windowNumber");
}

class PlainWindow : NSWindow
{
    static PlainWindow alloc() @selector("alloc");
}

// Probe 4's view: drawRect logs which thread it runs on and blits g_fill.
class ProbeView : NSView
{
    static ProbeView alloc() @selector("alloc");
    ProbeView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        ++g_draws;
        instr("draw_rect", "n=%d main_thread=%d fill=%.2f", g_draws,
            pthread_main_np(), g_fill);
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        CGContextSetRGBFillColor(ctx, g_fill, 0.3, 0.5, 1);
        CGContextFillRect(ctx, this.bounds());
    }
}

// Main-thread marshaling target for probe 3 (performSelectorOnMainThread:).
class Marshal : NSObject
{
    static Marshal alloc() @selector("alloc");
    Marshal init() @selector("init");

    void report(NSObject arg) @selector("report:")
    {
        g_perfSelOnMain = pthread_main_np();
        instr("marshal", "route=performSelectorOnMainThread main_thread=%d", g_perfSelOnMain);
        maybeFinishProbe3();
    }

    void tick(NSTimer t) @selector("tick:")
    {
        onTick();
    }
}

extern (D): // back to D linkage

enum NSApplicationActivationPolicyRegular = 0;
enum ulong NSWindowStyleMaskTitled = 1;
enum ulong NSBackingStoreBuffered = 2;
enum long NSEventTypeApplicationDefined = 15;

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared ProbeView g_view;
__gshared Marshal g_marshal;
__gshared int g_probe;
__gshared int g_ticks;
__gshared int g_draws;
__gshared int g_perfSelOnMain = -1;
__gshared int g_dispatchOnMain = -1;
__gshared bool g_workerDone;
__gshared bool g_verdictWritten;
__gshared double g_fill = 0.2;
__gshared char[256] g_detail;

NSString nsstr(const(char)* s)
{
    return NSString.alloc().initWithUTF8String(s);
}

// --- Verdicts that survive crashes ---------------------------------------------------

// Async-signal-safe: snprintf into a static buffer + write(2).
void verdict(const(char)* result, const(char)* detail) nothrow @nogc
{
    if (g_verdictWritten)
        return;
    g_verdictWritten = true;
    __gshared char[512] buf;
    immutable n = snprintf(buf.ptr, buf.length,
        "%llu APPKIT_F17 probe n=%d result=%s detail=%s\n",
        instrNowUs(), g_probe, result, detail);
    write(2, buf.ptr, n > 0 ? n : 0);
}

extern (C) void onFatalSignal(int sig) nothrow @nogc
{
    __gshared char[128] d;
    snprintf(d.ptr, d.length, "fatal_signal_%d%s", sig,
        sig == SIGABRT ? "_abort(see_exception_log_above)".ptr : "".ptr);
    verdict("crash", d.ptr);
    _exit(0); // crashing is this probe's job; the verdict got out
}

extern (C) void onAlarm(int sig) nothrow @nogc
{
    verdict("deadlock", "watchdog_12s_expired");
    _exit(0);
}

// AppKit's main-thread violations usually surface as NSExceptions → capture the
// exact assert text before abort() turns it into SIGABRT.
extern (C) void onUncaught(void* exception)
{
    NSException e = cast(NSException) exception;
    instr("uncaught_exception", "name=%s reason=%s",
        e !is null ? e.name().UTF8String() : "null",
        e !is null ? e.reason().UTF8String() : "null");
    __gshared char[256] d;
    snprintf(d.ptr, d.length, "nsexception:%s",
        e !is null ? e.name().UTF8String() : "unknown");
    verdict("crash", d.ptr);
    _exit(0);
}

void installHandlers()
{
    signal(SIGSEGV, &onFatalSignal);
    signal(SIGBUS, &onFatalSignal);
    signal(SIGILL, &onFatalSignal);
    signal(SIGABRT, &onFatalSignal);
    signal(SIGTRAP, &onFatalSignal);
    signal(SIGALRM, &onAlarm);
    NSSetUncaughtExceptionHandler(cast(NSUncaughtExceptionHandler) &onUncaught);
    alarm(12);
}

// --- Run-loop helpers ----------------------------------------------------------------

void stopApp()
{
    g_app.stop(null);
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true);
}

// Pump the main-thread event queue manually for ~ms milliseconds.
void pumpFor(int ms)
{
    NSString mode = nsstr("kCFRunLoopDefaultMode");
    foreach (i; 0 .. ms / 10)
    {
        for (;;)
        {
            NSEvent e = g_app.nextEventMatchingMask(ulong.max, NSDate.distantPast(),
                mode, true);
            if (e is null)
                break;
            if (e.type() == NSEventTypeApplicationDefined && e.data1() == 42)
                instr("event", "kind=worker_posted_event_received main_thread=%d data1=%ld",
                    pthread_main_np(), e.data1());
            g_app.sendEvent(e);
        }
        usleep(10_000);
    }
}

void createWindow(const(char)* who)
{
    instr("step", "name=NSWindow_init thread=%s main_thread=%d", who, pthread_main_np());
    g_win = PlainWindow.alloc().initWithContentRect(
        NSRect(NSPoint(120, 120), NSSize(320, 240)),
        NSWindowStyleMaskTitled, NSBackingStoreBuffered, false);
    g_win.setTitle(nsstr("wsi-f17"));
    g_win.setReleasedWhenClosed(false);
    g_view = ProbeView.alloc().initWithFrame(NSRect(NSPoint(0, 0), NSSize(320, 240)));
    g_win.setContentView(g_view);
    g_win.makeKeyAndOrderFront(null);
    instr("step", "name=window_created thread=%s win_num=%ld", who, g_win.windowNumber());
}

// --- Probe 1: NSWindow on a second thread; main pumps --------------------------------

extern (C) void* probe1Worker(void* arg)
{
    auto pool = autoreleasepool_push();
    createWindow("worker");
    autoreleasepool_pop(pool);
    g_workerDone = true;
    return null;
}

void probe1()
{
    void* th;
    pthread_create(&th, null, &probe1Worker, null);
    pumpFor(2500); // events pumped on main while the worker violates the rule
    pthread_join(th, null);
    if (g_win !is null)
        g_win.orderOut(null);
    char* d = g_detail.ptr;
    snprintf(d, g_detail.length, "window_created_off_main=%d win=%ld no_assert_no_crash",
        g_workerDone ? 1 : 0, g_win !is null ? g_win.windowNumber() : -1);
    verdict(g_workerDone ? "silent" : "error", d);
}

// --- Probe 2: [NSApp run] on main; worker creates the window after run starts --------

extern (C) void* probe2Worker(void* arg)
{
    auto pool = autoreleasepool_push();
    createWindow("worker_after_run");
    autoreleasepool_pop(pool);
    g_workerDone = true;
    return null;
}

void probe2()
{
    g_marshal = Marshal.alloc().init();
    NSTimer.scheduledTimerWithTimeInterval(0.3, g_marshal, SEL.register("tick:"), null, true);
    instr("step", "name=NSApp_run");
    g_app.run(); // ticks drive the script (onTick)
    if (g_win !is null)
        g_win.orderOut(null);
    char* d = g_detail.ptr;
    snprintf(d, g_detail.length,
        "run_loop_alive=1 window_created_on_worker_during_run=%d draws=%d",
        g_workerDone ? 1 : 0, g_draws);
    verdict(g_workerDone ? "silent" : "error", d);
}

// --- Probe 3: the sanctioned pattern --------------------------------------------------

extern (C) void dispatchedToMain(void* ctx) // runs on the main queue
{
    g_dispatchOnMain = pthread_main_np();
    instr("marshal", "route=dispatch_async_main_queue main_thread=%d", g_dispatchOnMain);
    maybeFinishProbe3();
}

void maybeFinishProbe3()
{
    if (g_probe != 3 || g_perfSelOnMain < 0 || g_dispatchOnMain < 0)
        return;
    char* d = g_detail.ptr;
    snprintf(d, g_detail.length,
        "performSelectorOnMainThread_on_main=%d dispatch_async_on_main=%d",
        g_perfSelOnMain, g_dispatchOnMain);
    verdict(g_perfSelOnMain == 1 && g_dispatchOnMain == 1 ? "ok" : "error", d);
    stopApp();
}

extern (C) void* probe3Worker(void* arg)
{
    // "Work" off-main, then marshal the UI-facing part to the main thread.
    ulong sum;
    foreach (i; 0 .. 1_000_000)
        sum += i;
    instr("step", "name=worker_work_done sum=%llu main_thread=%d", sum, pthread_main_np());
    g_marshal.performSelectorOnMainThread(SEL.register("report:"), null, false);
    dispatch_async_f(cast(void*) &_dispatch_main_q, null, &dispatchedToMain);
    return null;
}

void probe3()
{
    g_marshal = Marshal.alloc().init();
    void* th;
    pthread_create(&th, null, &probe3Worker, null);
    instr("step", "name=NSApp_run");
    g_app.run(); // maybeFinishProbe3 stops it
    pthread_join(th, null);
}

// --- Probe 4: render from a second thread ---------------------------------------------

extern (C) void marshaledSetNeedsDisplay(void* ctx)
{
    instr("render", "route=marshaled_setNeedsDisplay main_thread=%d", pthread_main_np());
    g_view.setNeedsDisplay(true);
}

extern (C) void* probe4Worker(void* arg)
{
    auto pool = autoreleasepool_push();
    // (a) The sanctioned render loop: CPU work on the worker, dirty-mark on main.
    g_fill = 0.9;
    instr("render", "route=worker_buffer_fill fill=0.9 main_thread=%d", pthread_main_np());
    dispatch_async_f(cast(void*) &_dispatch_main_q, null, &marshaledSetNeedsDisplay);
    usleep(600_000);
    immutable drawsAfterMarshal = g_draws;

    // (b1) DIRECT cross-thread setNeedsDisplay: (docs: not thread-safe).
    g_fill = 0.5;
    instr("render", "route=direct_setNeedsDisplay_from_worker main_thread=%d",
        pthread_main_np());
    g_view.setNeedsDisplay(true);
    usleep(600_000);

    // (b2) DIRECT lockFocus + CGContext drawing from the worker.
    instr("render", "route=direct_lockFocusIfCanDraw_from_worker main_thread=%d",
        pthread_main_np());
    immutable locked = g_view.lockFocusIfCanDraw();
    instr("render", "lockFocusIfCanDraw=%d", locked ? 1 : 0);
    if (locked)
    {
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        CGContextSetRGBFillColor(ctx, 1, 0, 0, 1);
        CGContextFillRect(ctx, NSRect(NSPoint(0, 0), NSSize(64, 64)));
        g_view.unlockFocus();
        instr("render", "direct_cgcontext_draw=done from_worker=1");
    }
    autoreleasepool_pop(pool);

    char* d = g_detail.ptr;
    snprintf(d, g_detail.length,
        "marshaled_draws=%d direct_setNeedsDisplay_survived=1 lockFocusIfCanDraw=%d total_draws=%d",
        drawsAfterMarshal, locked ? 1 : 0, g_draws);
    g_workerDone = true;
    return null;
}

void probe4()
{
    createWindow("main");
    g_marshal = Marshal.alloc().init();
    NSTimer.scheduledTimerWithTimeInterval(0.3, g_marshal, SEL.register("tick:"), null, true);
    void* th;
    pthread_create(&th, null, &probe4Worker, null);
    instr("step", "name=NSApp_run");
    g_app.run(); // onTick stops once the worker is done
    pthread_join(th, null);
    g_win.orderOut(null);
    verdict("silent", g_detail.ptr);
}

// --- Probe 5: NSPasteboard + NSEvent APIs from a worker -------------------------------

extern (C) void* probe5Worker(void* arg)
{
    auto pool = autoreleasepool_push();
    auto pb = NSPasteboard.generalPasteboard();
    immutable cc = pb.clearContents();
    immutable ok = pb.setString(nsstr("f17-worker-thread"), nsstr("public.utf8-plain-text"));
    NSString back = pb.stringForType(nsstr("public.utf8-plain-text"));
    instr("step", "name=pasteboard_from_worker main_thread=%d change_count=%ld set_ok=%d readback=%s",
        pthread_main_np(), cc, ok ? 1 : 0, back !is null ? back.UTF8String() : "nil");

    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 7, 42, 0);
    g_app.postEvent(ev, false); // postEvent: from a non-main thread
    instr("step", "name=postEvent_from_worker main_thread=%d", pthread_main_np());

    char* d = g_detail.ptr;
    snprintf(d, g_detail.length,
        "pasteboard_set_ok=%d readback_ok=%d postEvent_from_worker=accepted",
        ok ? 1 : 0,
        back !is null && strncmp(back.UTF8String(), "f17-worker-thread", 17) == 0 ? 1 : 0);
    autoreleasepool_pop(pool);
    g_workerDone = true;
    return null;
}

void probe5()
{
    void* th;
    pthread_create(&th, null, &probe5Worker, null);
    pumpFor(1500); // main pumps; does the worker's posted event arrive here?
    pthread_join(th, null);
    verdict(g_workerDone ? "ok" : "error", g_detail.ptr);
}

// --- Tick script (probes 2 and 4) ------------------------------------------------------

void onTick()
{
    ++g_ticks;
    if (g_probe == 2)
    {
        if (g_ticks == 1)
        {
            instr("step", "name=spawn_worker_inside_run tick=%d", g_ticks);
            void* th;
            pthread_create(&th, null, &probe2Worker, null);
        }
        if (g_ticks >= 6)
            stopApp();
    }
    else if (g_probe == 4)
    {
        if (g_workerDone || g_ticks >= 20)
            stopApp();
    }
}

// --- Probe driver / parent -----------------------------------------------------------

int runProbe(int n)
{
    g_probe = n;
    installHandlers();
    instr("probe_start", "n=%d main_thread=%d", n, pthread_main_np());

    if (CGMainDisplayID() == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }
    logSessionLockState();

    auto pool = autoreleasepool_push();
    g_app = NSApplication.sharedApplication();
    g_app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    switch (n)
    {
    case 1:
        probe1();
        break;
    case 2:
        probe2();
        break;
    case 3:
        probe3();
        break;
    case 4:
        probe4();
        break;
    case 5:
        probe5();
        break;
    default:
        verdict("error", "unknown_probe");
        break;
    }
    autoreleasepool_pop(pool);
    return 0;
}

// Parent: fork+exec each probe twice (the spec's nondeterminism rule); a crashed
// child can never poison the next, and the parent reports every exit status.
int runAll(const(char)* self)
{
    foreach (n; 1 .. 6)
    {
        foreach (run; 1 .. 3)
        {
            char[32] argbuf;
            snprintf(argbuf.ptr, argbuf.length, "--probe=%d", n);
            const(char)*[3] argv = [self, argbuf.ptr, null];
            immutable pid = fork();
            if (pid == 0)
            {
                execv(self, argv.ptr);
                _exit(127);
            }
            int status;
            waitpid(pid, &status, 0);
            immutable exited = (status & 0x7f) == 0;
            instr("probe_run", "n=%d run=%d exit_normal=%d code=%d term_signal=%d",
                n, run, exited ? 1 : 0, exited ? (status >> 8) & 0xff : -1,
                exited ? 0 : status & 0x7f);
        }
    }
    instr("all_probes_done", "runs=10");
    return 0;
}

int main(string[] args)
{
    instrInit("APPKIT_F17");
    if (args.length > 1 && args[1].length > 8 && args[1][0 .. 8] == "--probe=")
        return runProbe(atoi(args[1].ptr + 8));

    instr("init_start", "mode=all_probes_forked_twice");
    if (CGMainDisplayID() == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }
    char[1024] self;
    snprintf(self.ptr, self.length, "%s", args[0].ptr);
    return runAll(self.ptr);
}
