// macOS/AppKit F05 demo — loop wakeup & external fds
// (../../../features/f05-loop-wakeup.md). A real event loop multiplexes more than
// window events; this demo measures cross-thread wakeup latency into `[NSApp run]`
// via three different mechanisms and probes whether an arbitrary file descriptor can
// join the AppKit run loop.
//
// A single worker thread (core.thread on darwin) drives all three for ~30 s:
//   mech=postevent       every 100 ms it builds an NSEventTypeApplicationDefined
//                        event carrying a monotonic send-timestamp in data1 and
//                        posts it with [NSApp postEvent:atStart:NO]. The main loop
//                        sees it in an overridden -[NSApplication sendEvent:] and
//                        logs `wakeup latency_us=… mech=postevent`.
//   mech=cfrunloopsource every 100 ms it pushes a send-timestamp onto an SPSC ring
//                        and signals a version-0 CFRunLoopSourceRef (+ CFRunLoopWakeUp).
//                        The source's perform callback runs on the main run loop,
//                        drains the ring, and logs `wakeup … mech=cfrunloopsource`.
//   fd_tick              every ~143 ms (7 Hz) it writes an 8-byte send-timestamp into
//                        a pipe; the read end is integrated via a CFFileDescriptorRef
//                        run-loop source. Its callout drains the pipe and logs
//                        `fd_tick t=… latency_us=…`.
//
// The finding the fd path proves: AppKit's run loop accepts a raw fd ONLY through a
// CoreFoundation (CFFileDescriptor) or libdispatch (dispatch_source_t) adapter — never
// directly, the way poll()/epoll do. We implement the CFFileDescriptor route and
// document the dispatch_source alternative in ../../f05-loop-wakeup.md.
//
// At exit, per-mechanism latency stats (min/median/p99/max) are reported, then a clean
// bounded exit via [NSApp stop:] + a synthetic event post (the scaffold idiom).
//
// Modes (environment variables):
//   WSI_AUTO_EXIT=1   bounded run for WSI_DURATION_S seconds (default 30), then stats
//                     and exit 0. This is the choreographed, fully agent-verifiable run.
//   WSI_DURATION_S=N  override the run duration (seconds).
//
// Headless-safe: prints `SKIP:` and exits 0 when there is no window server
// (CGMainDisplayID() == 0), per the research-docs guidelines.
module app;

import core.attribute : selector;
import core.atomic : atomicLoad, atomicStore, atomicFence;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv, atoi;
import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
import core.sys.posix.unistd : pipe, write, read, close;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;

import instrument : instr, instrInit, instrNowUs;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d
import objc.rt : SEL;

// --- CoreFoundation C API (comes with the Cocoa umbrella framework) -------------

alias CFRunLoopRef = void*;
alias CFRunLoopSourceRef = void*;
alias CFFileDescriptorRef = void*;
alias CFStringRef = void*;
alias CFAllocatorRef = void*;
alias CFIndex = long;
alias CFOptionFlags = ulong;
alias CFFileDescriptorNativeDescriptor = int;

// A version-0 run-loop source: `info` is passed to every callback; `perform` is the
// only one we use. All function-pointer slots are extern(C) callbacks or null.
extern (C) struct CFRunLoopSourceContext
{
    CFIndex version_;
    void* info;
    void* retain;
    void* release;
    void* copyDescription;
    void* equal;
    void* hash;
    void* schedule;
    void* cancel;
    void* perform; // void (*)(void* info)
}

extern (C) struct CFFileDescriptorContext
{
    CFIndex version_;
    void* info;
    void* retain;
    void* release;
    void* copyDescription;
}

extern (C) nothrow @nogc
{
    CFRunLoopRef CFRunLoopGetCurrent();
    void CFRunLoopAddSource(CFRunLoopRef rl, CFRunLoopSourceRef source, CFStringRef mode);
    void CFRunLoopSourceSignal(CFRunLoopSourceRef source);
    void CFRunLoopWakeUp(CFRunLoopRef rl);
    CFRunLoopSourceRef CFRunLoopSourceCreate(CFAllocatorRef allocator, CFIndex order,
        CFRunLoopSourceContext* context);

    CFFileDescriptorRef CFFileDescriptorCreate(CFAllocatorRef allocator,
        CFFileDescriptorNativeDescriptor fd, bool closeOnInvalidate, void* callout,
        CFFileDescriptorContext* context);
    void CFFileDescriptorEnableCallBacks(CFFileDescriptorRef f, CFOptionFlags types);
    CFRunLoopSourceRef CFFileDescriptorCreateRunLoopSource(CFAllocatorRef allocator,
        CFFileDescriptorRef f, CFIndex order);

    extern __gshared CFStringRef kCFRunLoopCommonModes;
    uint CGMainDisplayID();
}

enum CFOptionFlags kCFFileDescriptorReadCallBack = 1UL << 0;

// --- Cocoa geometry (CGFloat == double on 64-bit) -------------------------------

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

// --- AppKit class declarations --------------------------------------------------

extern (Objective-C):

extern class NSObject
{
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
    long type() @selector("type");
    short subtype() @selector("subtype");
    long data1() @selector("data1");
}

// NSApplication declares sendEvent: so WakeApp can override it. sharedApplication is
// declared ONLY on the WakeApp leaf (returning WakeApp) to dodge the covariant-return
// clash on a base declaration — calling +sharedApplication on the subclass makes NSApp
// an instance of it, so our sendEvent: override is installed.
extern class NSApplication : NSResponder
{
    void setActivationPolicy(long policy) @selector("setActivationPolicy:");
    void activateIgnoringOtherApps(bool flag) @selector("activateIgnoringOtherApps:");
    void run() @selector("run");
    void stop(NSObject sender) @selector("stop:");
    void sendEvent(NSEvent event) @selector("sendEvent:");
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
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
}

// The NSApplication subclass: its sendEvent: override is where mech=postevent and the
// bounded-exit DONE signal are observed (the run loop calls -[NSApp sendEvent:] for
// every dequeued event, including NSEventTypeApplicationDefined).
class WakeApp : NSApplication
{
    static WakeApp sharedApplication() @selector("sharedApplication");

    override void sendEvent(NSEvent event) @selector("sendEvent:")
    {
        if (event.type() == NSEventTypeApplicationDefined)
        {
            immutable st = event.subtype();
            if (st == subtypeWake)
            {
                onWake(MechId.postevent, cast(ulong) event.data1());
                return; // consume — not a real UI event
            }
            if (st == subtypeDone)
            {
                onDone();
                return;
            }
            // subtypeStop (0): the synthetic unblock event — fall through to super.
        }
        super.sendEvent(event);
    }
}

// A minimal solid-color content view so the demo is a real windowed AppKit app.
class FillView : NSView
{
    static FillView alloc() @selector("alloc");
    FillView initWithFrame(NSRect frame) @selector("initWithFrame:");

    void drawRect(NSRect dirtyRect) @selector("drawRect:")
    {
        // The loop, not the pixels, is the subject here; nothing to draw.
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

// applicationDefined subtypes we distinguish in sendEvent:
enum short subtypeStop = 0; // synthetic post that unblocks [NSApp run] after stop:
enum short subtypeWake = 0x57; // 'W' — a mech=postevent wakeup
enum short subtypeDone = 0x44; // 'D' — worker signalling end-of-run

// --- Demo state -----------------------------------------------------------------

enum MechId : int
{
    postevent = 0,
    cfrunloopsource = 1,
}

immutable string[2] mechNames = ["postevent", "cfrunloopsource"];

__gshared WakeApp g_app;
__gshared NSWindow g_win;
__gshared CFRunLoopRef g_mainRL;
__gshared CFRunLoopSourceRef g_cfSource;
__gshared int g_pipeRead = -1, g_pipeWrite = -1;
__gshared Thread g_worker;
shared bool g_stopWorker;
__gshared int g_durationS = 30;

// Latency samples (main thread only appends — all callbacks run on the main loop).
enum sampleCap = 8192;
__gshared double[sampleCap][2] g_lat; // [mech][i], microseconds
__gshared size_t[2] g_latN;
__gshared double[sampleCap] g_fdLat;
__gshared size_t g_fdN;
__gshared uint g_wakeCount, g_fdCount;

// SPSC ring carrying send-timestamps for the coalescing-prone CFRunLoopSource path:
// one signal may collapse several pushes into a single perform, so we drain the ring.
enum ringCap = 4096; // power of two
__gshared ulong[ringCap] g_ring;
shared size_t g_ringHead; // producer (worker)
shared size_t g_ringTail; // consumer (main perform)

void ringPush(ulong v) nothrow @nogc
{
    immutable h = atomicLoad(g_ringHead);
    g_ring[h & (ringCap - 1)] = v;
    atomicFence();
    atomicStore(g_ringHead, h + 1);
}

void onWake(MechId mech, ulong sendUs)
{
    immutable now = instrNowUs();
    immutable lat = now > sendUs ? cast(double)(now - sendUs) : 0.0;
    if (g_latN[mech] < sampleCap)
        g_lat[mech][g_latN[mech]++] = lat;
    ++g_wakeCount;
    instr("wakeup", "latency_us=%.1f mech=%.*s n=%u", lat,
        cast(int) mechNames[mech].length, mechNames[mech].ptr, g_wakeCount);
}

void onDone()
{
    instr("step", "name=worker_done wakes=%u fd_ticks=%u", g_wakeCount, g_fdCount);
    g_app.stop(null);
    // stop: only takes effect after the next event dispatch; post a synthetic
    // application-defined event so [NSApp run] wakes up and returns (scaffold finding).
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, subtypeStop, 0, 0);
    g_app.postEvent(ev, true);
}

// CFRunLoopSource perform callback (main run loop): drain every queued send-timestamp.
extern (C) void performCFSource(void* info) nothrow
{
    size_t tail = atomicLoad(g_ringTail);
    immutable head = atomicLoad(g_ringHead);
    while (tail != head)
    {
        immutable sendUs = g_ring[tail & (ringCap - 1)];
        ++tail;
        immutable now = instrNowUs();
        immutable lat = now > sendUs ? cast(double)(now - sendUs) : 0.0;
        if (g_latN[MechId.cfrunloopsource] < sampleCap)
            g_lat[MechId.cfrunloopsource][g_latN[MechId.cfrunloopsource]++] = lat;
        ++g_wakeCount;
        instr("wakeup", "latency_us=%.1f mech=cfrunloopsource n=%u", lat, g_wakeCount);
    }
    atomicStore(g_ringTail, tail);
}

// CFFileDescriptor callout (main run loop): drain all 8-byte timestamps from the pipe.
// CFFileDescriptor disables its callbacks after each fire, so we must re-enable them.
extern (C) void fdCallout(CFFileDescriptorRef f, CFOptionFlags types, void* info) nothrow
{
    ubyte[8 * 64] buf;
    for (;;)
    {
        immutable n = read(g_pipeRead, buf.ptr, buf.length);
        if (n <= 0)
            break;
        size_t off = 0;
        while (off + 8 <= cast(size_t) n)
        {
            ulong sendUs = *cast(ulong*)(buf.ptr + off);
            off += 8;
            immutable now = instrNowUs();
            immutable lat = now > sendUs ? cast(double)(now - sendUs) : 0.0;
            if (g_fdN < sampleCap)
                g_fdLat[g_fdN++] = lat;
            ++g_fdCount;
            instr("fd_tick", "t=%u latency_us=%.1f", g_fdCount, lat);
        }
        if (cast(size_t) n < buf.length)
            break;
    }
    CFFileDescriptorEnableCallBacks(f, kCFFileDescriptorReadCallBack);
}

// The worker thread: posts mech A + mech B at 10 Hz and the fd at ~7 Hz for the run
// duration, then signals DONE. All wakeup primitives below are documented thread-safe:
// -[NSApp postEvent:atStart:], CFRunLoopSourceSignal, CFRunLoopWakeUp, and write().
void workerMain()
{
    auto pool = autoreleasepool_push(); // Cocoa from a secondary thread needs a pool
    scope (exit)
        autoreleasepool_pop(pool);

    immutable start = MonoTime.currTime;
    immutable deadline = start + g_durationS.seconds;
    MonoTime nextAB = start;
    MonoTime nextFd = start;
    immutable abPeriod = 100.msecs; // 10 Hz
    immutable fdPeriod = 143.msecs; // ~7 Hz

    while (MonoTime.currTime < deadline && !atomicLoad(g_stopWorker))
    {
        immutable now = MonoTime.currTime;

        if (now >= nextAB)
        {
            immutable sendUs = instrNowUs();
            // mech A: post an applicationDefined event carrying the send time in data1.
            NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
                NSPoint(0, 0), 0, 0, 0, null, subtypeWake, cast(long) sendUs, 0);
            g_app.postEvent(ev, false);
            // mech B: push the send time and signal the run-loop source.
            ringPush(instrNowUs());
            CFRunLoopSourceSignal(g_cfSource);
            CFRunLoopWakeUp(g_mainRL);
            nextAB += abPeriod;
        }

        if (now >= nextFd)
        {
            ulong sendUs = instrNowUs();
            write(g_pipeWrite, &sendUs, sendUs.sizeof);
            nextFd += fdPeriod;
        }

        Thread.sleep(2.msecs);
    }

    // Signal end-of-run to the main loop (also delivered through sendEvent:).
    NSEvent done = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, subtypeDone, 0, 0);
    g_app.postEvent(done, false);
}

void reportStats(const(char)* mech, double[] s)
{
    if (s.length == 0)
    {
        instr("stats", "mech=%s n=0", mech);
        return;
    }
    import std.algorithm.sorting : sort;

    sort(s);
    immutable mn = s[0];
    immutable mx = s[$ - 1];
    immutable med = s[s.length / 2];
    size_t i99 = cast(size_t)(s.length * 99 / 100);
    if (i99 >= s.length)
        i99 = s.length - 1;
    instr("stats", "mech=%s n=%zu min_us=%.1f med_us=%.1f p99_us=%.1f max_us=%.1f",
        mech, s.length, mn, med, s[i99], mx);
}

int main()
{
    immutable autoExit = getenv("WSI_AUTO_EXIT") !is null;
    if (auto d = getenv("WSI_DURATION_S"))
    {
        immutable v = atoi(d);
        if (v > 0)
            g_durationS = v;
    }
    instrInit("APPKIT_F05");
    instr("init_start", "auto_exit=%d duration_s=%d", autoExit ? 1 : 0, g_durationS);

    instr("step", "name=CGMainDisplayID");
    if (CGMainDisplayID() == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }

    auto pool = autoreleasepool_push();
    scope (exit)
        autoreleasepool_pop(pool);

    // Shared app — instantiated as a WakeApp so our sendEvent: override is live.
    instr("step", "name=NSApplication_sharedApplication class=WakeApp");
    g_app = WakeApp.sharedApplication();
    g_app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(360, 240));
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f05-loop-wakeup"));
    FillView view = FillView.alloc().initWithFrame(contentRect);
    g_win.setContentView(view);
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);
    instr("window_created");

    // We are on the main thread; [NSApp run] will pump THIS run loop. Add both the
    // CFRunLoopSource (mech B) and the CFFileDescriptor source (fd) to it.
    g_mainRL = CFRunLoopGetCurrent();

    instr("step", "name=CFRunLoopSourceCreate version=0");
    CFRunLoopSourceContext ctx;
    ctx.version_ = 0;
    ctx.perform = cast(void*)&performCFSource;
    g_cfSource = CFRunLoopSourceCreate(null, 0, &ctx);
    CFRunLoopAddSource(g_mainRL, g_cfSource, kCFRunLoopCommonModes);

    // Arbitrary fd: a pipe, read end made nonblocking and wrapped in a
    // CFFileDescriptor run-loop source. This is the ONLY way a raw fd joins AppKit's
    // loop — see ../../f05-loop-wakeup.md for the dispatch_source_t alternative.
    int[2] fds;
    if (pipe(fds) != 0)
    {
        printf("SKIP: pipe() failed\n");
        return 0;
    }
    g_pipeRead = fds[0];
    g_pipeWrite = fds[1];
    fcntl(g_pipeRead, F_SETFL, fcntl(g_pipeRead, F_GETFL, 0) | O_NONBLOCK);
    instr("step", "name=CFFileDescriptorCreate fd=%d", g_pipeRead);
    CFFileDescriptorContext fctx;
    CFFileDescriptorRef cffd = CFFileDescriptorCreate(null, g_pipeRead, true,
        cast(void*)&fdCallout, &fctx);
    CFFileDescriptorEnableCallBacks(cffd, kCFFileDescriptorReadCallBack);
    CFRunLoopSourceRef fdSource = CFFileDescriptorCreateRunLoopSource(null, cffd, 0);
    CFRunLoopAddSource(g_mainRL, fdSource, kCFRunLoopCommonModes);

    // Launch the worker and cede the main thread to AppKit.
    instr("step", "name=worker_start period_ms=100 fd_period_ms=143 duration_s=%d",
        g_durationS);
    g_worker = new Thread(&workerMain);
    g_worker.start();

    instr("step", "name=NSApp_run");
    g_app.run();

    atomicStore(g_stopWorker, true);
    g_worker.join();

    reportStats("postevent", g_lat[MechId.postevent][0 .. g_latN[MechId.postevent]]);
    reportStats("cfrunloopsource",
        g_lat[MechId.cfrunloopsource][0 .. g_latN[MechId.cfrunloopsource]]);
    reportStats("fd", g_fdLat[0 .. g_fdN]);
    instr("loop_exit", "wakes=%u fd_ticks=%u", g_wakeCount, g_fdCount);

    close(g_pipeRead);
    close(g_pipeWrite);
    return 0;
}
