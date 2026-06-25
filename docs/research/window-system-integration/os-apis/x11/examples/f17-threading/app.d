// F17 X11 demo — threading probes: deliberately violate (and then obey)
// Xlib's threading rules and record exactly what breaks and how
// (../../../features/f17-threading.md; findings in ../../f17-threading.md).
//
// Probes (--probe=N; no argument = fork+run every probe TWICE, the CI default,
// so race-dependent outcomes show their spread):
//   1  window created on a worker thread WITHOUT XInitThreads while the main
//      thread pumps events and XSyncs on the same Display — the classic
//      "unexpected async reply" corruption / XIO / crash
//   2  the same choreography WITH XInitThreads — legal; prove it
//   3  two threads sharing one Display, BOTH blocking in XNextEvent (with
//      XInitThreads): how do queued events distribute? does one starve?
//   4  render thread: XShmPutImage + XFlush from a worker while the main
//      thread pumps (with XInitThreads); completion events land on the pump
//   5  one Display per thread, NO XInitThreads — the always-safe model
//   6  XInitThreads called LATE (after XOpenDisplay), then the probe-1
//      choreography — does the late call rescue the existing Display?
//
// Every probe ends in a verdict line
//     probe n=<N> result=ok|error|crash|deadlock|silent detail=...
// that survives ANY outcome: XSetErrorHandler counts protocol errors,
// XSetIOErrorHandler + SIGSEGV/SIGABRT/SIGBUS handlers turn crashes into a
// flushed verdict + _exit(0), and a SIGALRM watchdog turns hangs into
// result=deadlock. Crash probes still exit 0 — crashing is their job.
//
// Headless-safe: no X server -> prints `SKIP:` and exits 0.
module app;

import c; // ImportC: Xlib + Xutil + Xatom + XShm + sys/ipc + sys/shm + poll
import instrument;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf, snprintf;
import core.stdc.string : memset, strlen;
import core.sys.posix.pthread : pthread_create, pthread_join, pthread_t;
import core.sys.posix.signal : SA_RESTART, sigaction, sigaction_t, sigemptyset,
    SIGABRT, SIGALRM, SIGBUS, SIGSEGV;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.unistd : _exit, alarm, fork, usleep, write;

// -- macro constants ImportC cannot export ------------------------------------
enum : c_long
{
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
}

enum // XEvent.type discriminators
{
    Expose = 12,
    MapNotify = 19,
    ClientMessage = 33,
}

enum ZPixmap = 2;
enum False = 0;
enum True = 1;
enum IPC_PRIVATE = 0;
enum IPC_CREAT = 0x200;
enum IPC_RMID = 0;

// -- verdict plumbing: must survive crashes ------------------------------------

private __gshared int g_probe;
private shared int g_xlibErrors;
private __gshared char[128] g_lastXlibError = '\0';
private shared bool g_verdictDone;

/// The one line the spec requires per run. Async-signal-safe on purpose
/// (snprintf into a static buffer + write(2)) so the signal/XIO handlers can
/// call it; the normal path uses it too so the format is identical.
void verdict(scope const(char)* result, scope const(char)* detail) @nogc nothrow
{
    if (atomicLoad(g_verdictDone))
        return;
    atomicStore(g_verdictDone, true);
    static __gshared char[256] buf;
    const n = snprintf(buf.ptr, buf.length, "%lld f17_x11 probe n=%d result=%s detail=%s\n",
        nowUs(), g_probe, result, detail);
    write(2, buf.ptr, n);
}

extern (C) int xlibErrorHandler(Display* dpy, XErrorEvent* e) @nogc nothrow
{
    atomicOp!"+="(g_xlibErrors, 1);
    char[64] text;
    XGetErrorText(dpy, e.error_code, text.ptr, text.length);
    snprintf(g_lastXlibError.ptr, g_lastXlibError.length,
        "code=%d(%s)_request=%d.%d_resource=0x%lx",
        e.error_code, text.ptr, e.request_code, e.minor_code, e.resourceid);
    emitf("xlib_error", "%s", g_lastXlibError.ptr);
    return 0; // continue; the verdict decides
}

extern (C) int xioErrorHandler(Display*) @nogc nothrow
{
    // Xlib is about to exit() — flush the verdict first. Must not return.
    verdict("crash", "xio_error_connection_lost");
    _exit(0);
    return 0;
}

extern (C) void signalHandler(int sig) @nogc nothrow
{
    static __gshared char[64] d;
    snprintf(d.ptr, d.length, "fatal_signal=%d", sig);
    verdict("crash", d.ptr);
    _exit(0);
}

extern (C) void alarmHandler(int) @nogc nothrow
{
    verdict("deadlock", "watchdog_timeout_8s");
    _exit(0);
}

void installCrashHandlers() @nogc nothrow
{
    XSetErrorHandler(&xlibErrorHandler);
    XSetIOErrorHandler(&xioErrorHandler);
    sigaction_t sa;
    sa.sa_handler = &signalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, null);
    sigaction(SIGBUS, &sa, null);
    sigaction(SIGABRT, &sa, null);
    sa.sa_handler = &alarmHandler;
    sigaction(SIGALRM, &sa, null);
    alarm(8); // the deadlock watchdog
}

// -- probes 1/2/6: window on a worker thread, pump + XSync storm on main -------

private __gshared Display* g_dpy;
private shared bool g_workerDone;

/// Worker: create/map a window, then hammer reply-carrying requests
/// (XInternAtom round-trips) for ~1.2 s. Without XInitThreads both threads
/// read the one connection -> interleaved replies -> corruption.
extern (C) void* windowWorker(void*) @nogc nothrow
{
    auto dpy = g_dpy;
    emit("thread=worker action=XCreateSimpleWindow");
    Window win = XCreateSimpleWindow(dpy, XRootWindow(dpy, XDefaultScreen(dpy)),
        0, 0, 200, 120, 1, 0, 0xffffff);
    XSelectInput(dpy, win, ExposureMask | StructureNotifyMask);
    XMapWindow(dpy, win);
    XFlush(dpy);
    emitf("thread=worker", "action=window_created xid=0x%lx", win);

    XEvent msg;
    msg.xclient.type = ClientMessage;
    msg.xclient.window = win;
    msg.xclient.message_type = XInternAtom(dpy, "WSI_F17_TICK", False);
    msg.xclient.format = 32;

    // Request storm: buffered requests (XStoreName marshals into the shared
    // Display output buffer) mixed with reply-carrying round-trips and event
    // traffic — while the main thread appends to the SAME buffer and reads
    // the SAME reply/event stream, unlocked.
    const deadline = nowUs() + 1_200_000;
    int i = 0;
    char[32] name;
    while (nowUs() < deadline)
    {
        snprintf(name.ptr, name.length, "WSI_F17_%d", i++);
        XStoreName(dpy, win, name.ptr); // buffered (no reply)
        if (i % 8 == 0)
            XInternAtom(dpy, name.ptr, False); // round-trip
        if (i % 64 == 0)
        {
            msg.xclient.data.l[0] = 42; // event traffic for the main pump
            XSendEvent(dpy, win, False, 0, &msg);
        }
    }
    emitf("thread=worker", "action=done roundtrips=%d", i * 2);
    atomicStore(g_workerDone, true);
    msg.xclient.data.l[0] = 99; // wake the main pump out of XNextEvent
    XSendEvent(dpy, win, False, 0, &msg);
    XFlush(dpy);
    return null;
}

/// XGetGeometry needs 9 out-params; tuck them away.
void XGetGeometry_(Display* dpy, Window win) @nogc nothrow
{
    Window root;
    int x, y;
    uint w, h, bw, depth;
    XGetGeometry(dpy, win, &root, &x, &y, &w, &h, &bw, &depth);
}

int probeWindowOnWorker(bool initFirst, bool initLate) @nogc nothrow
{
    if (initFirst)
        emitf("step", "name=XInitThreads ret=%d order=first", XInitThreads());
    g_dpy = XOpenDisplay(null);
    if (initLate)
        emitf("step", "name=XInitThreads ret=%d order=AFTER_XOpenDisplay", XInitThreads());
    emitf("step", "name=XOpenDisplay fd=%d xinitthreads=%s",
        XConnectionNumber(g_dpy),
        initFirst ? "first".ptr : initLate ? "late".ptr : "no".ptr);

    atomicStore(g_workerDone, false);
    pthread_t t;
    pthread_create(&t, null, &windowWorker, null);

    // Main pumps events while issuing its own (buffered) requests — i.e. a
    // normal GUI main loop — on the same unlocked Display the worker is
    // hammering. XNoOp appends to the output buffer; XPending flushes it and
    // reads events; both race the worker's marshalling and replies.
    int eventsOnMain = 0;
    bool sawDoneWakeup = false;
    emit("thread=main action=pump_start");
    while (!sawDoneWakeup && !(atomicLoad(g_workerDone) && XPending(g_dpy) == 0))
    {
        XNoOp(g_dpy); // buffered request from the main thread
        while (XPending(g_dpy) > 0)
        {
            XEvent ev;
            XNextEvent(g_dpy, &ev);
            ++eventsOnMain;
            if (ev.type == MapNotify)
                emitf("thread=main", "action=event type=MapNotify window=0x%lx events_on_main=%d",
                    ev.xmap.window, eventsOnMain);
            if (ev.type == ClientMessage && ev.xclient.data.l[0] == 99)
                sawDoneWakeup = true; // the worker's done-wakeup
        }
    }
    pthread_join(t, null);
    XSync(g_dpy, False);

    static __gshared char[192] d;
    const errs = atomicLoad(g_xlibErrors);
    if (errs > 0)
    {
        snprintf(d.ptr, d.length, "xlib_errors=%d last=%s events_on_main=%d",
            errs, g_lastXlibError.ptr, eventsOnMain);
        verdict("error", d.ptr);
    }
    else if (initFirst)
    {
        snprintf(d.ptr, d.length, "window_created_on_worker events_on_main=%d", eventsOnMain);
        verdict("ok", d.ptr);
    }
    else
    {
        snprintf(d.ptr, d.length,
            "no_corruption_observed_this_run events_on_main=%d (nondeterministic)", eventsOnMain);
        verdict("silent", d.ptr);
    }
    XCloseDisplay(g_dpy);
    return 0;
}

// -- probe 3: two threads blocked in XNextEvent on one Display ------------------

private shared int g_recvCount;
private shared int[2] g_perThread;
private shared int g_waitersAlive;

extern (C) void* eventWaiter(void* arg) @nogc nothrow
{
    const idx = cast(int) cast(size_t) arg;
    atomicOp!"+="(g_waitersAlive, 1);
    for (;;)
    {
        XEvent ev;
        XNextEvent(g_dpy, &ev); // blocking; the lock is released while waiting
        if (ev.type != ClientMessage)
            continue;
        if (ev.xclient.data.l[0] == 99) // sentinel: drain and exit
            break;
        atomicOp!"+="(g_perThread[idx], 1);
        atomicOp!"+="(g_recvCount, 1);
    }
    atomicOp!"-="(g_waitersAlive, 1);
    return null;
}

int probeTwoReaders() @nogc nothrow
{
    emitf("step", "name=XInitThreads ret=%d order=first", XInitThreads());
    g_dpy = XOpenDisplay(null);
    Window win = XCreateSimpleWindow(g_dpy, XRootWindow(g_dpy, XDefaultScreen(g_dpy)),
        0, 0, 100, 100, 0, 0, 0);
    emitf("step", "name=window_created xid=0x%lx", win);

    pthread_t[2] ts;
    pthread_create(&ts[0], null, &eventWaiter, cast(void*) 0);
    pthread_create(&ts[1], null, &eventWaiter, cast(void*) 1);
    usleep(50_000); // let both block inside XNextEvent

    enum N = 100;
    XEvent ev;
    ev.xclient.type = ClientMessage;
    ev.xclient.window = win;
    ev.xclient.message_type = XInternAtom(g_dpy, "WSI_F17_MSG", False);
    ev.xclient.format = 32;
    foreach (i; 0 .. N)
    {
        ev.xclient.data.l[0] = 42;
        XSendEvent(g_dpy, win, False, 0, &ev); // self-addressed event
        XFlush(g_dpy);
        usleep(1000);
    }
    // Wake the (possibly both-blocked) waiters out of XNextEvent.
    int sentinels = 0;
    while (atomicLoad(g_waitersAlive) > 0 && sentinels < 200)
    {
        ev.xclient.data.l[0] = 99;
        XSendEvent(g_dpy, win, False, 0, &ev);
        XFlush(g_dpy);
        ++sentinels;
        usleep(5000);
    }
    pthread_join(ts[0], null);
    pthread_join(ts[1], null);

    static __gshared char[160] d;
    const t0 = atomicLoad(g_perThread[0]), t1 = atomicLoad(g_perThread[1]);
    snprintf(d.ptr, d.length,
        "sent=%d received=%d thread_a=%d thread_b=%d sentinels_to_unblock=%d xlib_errors=%d",
        N, t0 + t1, t0, t1, sentinels, atomicLoad(g_xlibErrors));
    verdict(t0 + t1 == N ? "ok" : "error", d.ptr);
    XCloseDisplay(g_dpy);
    return 0;
}

// -- probe 4: XShmPutImage from a render thread, events pumped on main ----------

private __gshared Window g_win;
private __gshared GC g_gc;
private __gshared XImage* g_ximg;
private shared int g_puts;

extern (C) void* renderWorker(void*) @nogc nothrow
{
    foreach (frame; 0 .. 60)
    {
        memset(g_ximg.data, frame * 4, cast(size_t)(g_ximg.bytes_per_line * g_ximg.height));
        XShmPutImage(g_dpy, g_win, g_gc, g_ximg, 0, 0, 0, 0,
            cast(uint) g_ximg.width, cast(uint) g_ximg.height, True);
        XFlush(g_dpy); // the worker owns its own flushes
        atomicOp!"+="(g_puts, 1);
        usleep(3000); // paced by time, not by completion (main eats those)
    }
    emit("thread=render action=done puts=60");
    atomicStore(g_workerDone, true);
    return null;
}

int probeRenderThread() @nogc nothrow
{
    emitf("step", "name=XInitThreads ret=%d order=first", XInitThreads());
    g_dpy = XOpenDisplay(null);
    const screen = XDefaultScreen(g_dpy);
    if (!XShmQueryExtension(g_dpy))
    {
        verdict("ok", "skipped_no_MIT_SHM");
        return 0;
    }
    const completionType = XShmGetEventBase(g_dpy) + 0 /* ShmCompletion */ ;
    g_win = XCreateSimpleWindow(g_dpy, XRootWindow(g_dpy, screen), 0, 0,
        320, 240, 1, 0, 0xffffff);
    XSelectInput(g_dpy, g_win, ExposureMask | StructureNotifyMask);
    XMapWindow(g_dpy, g_win);
    g_gc = XDefaultGC(g_dpy, screen);

    XShmSegmentInfo shminfo;
    g_ximg = XShmCreateImage(g_dpy, XDefaultVisual(g_dpy, screen),
        cast(uint) XDefaultDepth(g_dpy, screen), ZPixmap, null, &shminfo, 320, 240);
    shminfo.shmid = shmget(IPC_PRIVATE,
        cast(size_t)(g_ximg.bytes_per_line * g_ximg.height), IPC_CREAT | 0x180);
    shminfo.shmaddr = cast(char*) shmat(shminfo.shmid, null, 0);
    g_ximg.data = shminfo.shmaddr;
    shminfo.readOnly = False;
    XShmAttach(g_dpy, &shminfo);
    XSync(g_dpy, False);
    shmctl(shminfo.shmid, IPC_RMID, null);
    emitf("step", "name=shm_image size=320x240 completion_event=%d", completionType);

    atomicStore(g_workerDone, false);
    pthread_t t;
    pthread_create(&t, null, &renderWorker, null);

    int completions = 0, otherEvents = 0;
    emit("thread=main action=pump_start");
    const deadline = nowUs() + 4_000_000;
    while (nowUs() < deadline)
    {
        while (XPending(g_dpy) > 0)
        {
            XEvent ev;
            XNextEvent(g_dpy, &ev);
            if (ev.type == completionType)
                ++completions;
            else
                ++otherEvents;
        }
        if (atomicLoad(g_workerDone) && completions >= atomicLoad(g_puts))
            break;
        usleep(1000);
    }
    pthread_join(t, null);

    static __gshared char[160] d;
    snprintf(d.ptr, d.length,
        "puts_from_render_thread=%d completions_on_main=%d other_events_on_main=%d xlib_errors=%d",
        atomicLoad(g_puts), completions, otherEvents, atomicLoad(g_xlibErrors));
    verdict(completions == atomicLoad(g_puts) && atomicLoad(g_xlibErrors) == 0
            ? "ok" : "error", d.ptr);

    XSync(g_dpy, False);
    XShmDetach(g_dpy, &shminfo);
    g_ximg.f.destroy_image(g_ximg);
    shmdt(shminfo.shmaddr);
    XCloseDisplay(g_dpy);
    return 0;
}

// -- probe 5: one Display per thread, no XInitThreads ---------------------------

private shared int g_threadOk;

extern (C) void* displayPerThread(void* arg) @nogc nothrow
{
    const idx = cast(int) cast(size_t) arg;
    Display* dpy = XOpenDisplay(null); // private connection: nothing shared
    const screen = XDefaultScreen(dpy);
    Window win = XCreateSimpleWindow(dpy, XRootWindow(dpy, screen), 0, 0,
        160, 120, 1, 0, 0xffffff);
    XSelectInput(dpy, win, ExposureMask | StructureNotifyMask);
    XMapWindow(dpy, win);
    emitf("thread=t%d", "action=window_created xid=0x%lx fd=%d",
        idx, win, XConnectionNumber(dpy));
    bool exposed = false;
    const deadline = nowUs() + 3_000_000;
    while (!exposed && nowUs() < deadline)
    {
        XEvent ev;
        XNextEvent(dpy, &ev); // each thread blocks on ITS OWN connection
        if (ev.type == Expose)
        {
            XFillRectangle(dpy, win, XDefaultGC(dpy, screen), 10, 10, 140, 100);
            XSync(dpy, False);
            exposed = true;
        }
    }
    emitf("thread=t%d", "action=done exposed=%d", idx, cast(int) exposed);
    if (exposed)
        atomicOp!"+="(g_threadOk, 1);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return null;
}

int probeDisplayPerThread() @nogc nothrow
{
    emit("step name=XInitThreads SKIPPED_ON_PURPOSE model=display_per_thread");
    pthread_t[2] ts;
    pthread_create(&ts[0], null, &displayPerThread, cast(void*) 0);
    pthread_create(&ts[1], null, &displayPerThread, cast(void*) 1);
    pthread_join(ts[0], null);
    pthread_join(ts[1], null);
    static __gshared char[96] d;
    snprintf(d.ptr, d.length, "threads_completed=%d/2 xlib_errors=%d no_xinitthreads=1",
        atomicLoad(g_threadOk), atomicLoad(g_xlibErrors));
    verdict(atomicLoad(g_threadOk) == 2 ? "ok" : "error", d.ptr);
    return 0;
}

// ---------------------------------------------------------------------------

int runProbe(int n) @nogc nothrow
{
    g_probe = n;
    installCrashHandlers();
    emitf("probe_start", "n=%d", n);
    switch (n)
    {
    case 1:
        probeWindowOnWorker(false, false);
        break;
    case 2:
        probeWindowOnWorker(true, false);
        break;
    case 3:
        probeTwoReaders();
        break;
    case 4:
        probeRenderThread();
        break;
    case 5:
        probeDisplayPerThread();
        break;
    case 6:
        probeWindowOnWorker(false, true);
        break;
    default:
        verdict("error", "unknown_probe");
    }
    alarm(0);
    return 0;
}

int main(string[] args)
{
    initInstrument("f17_x11");

    int probe = 0;
    foreach (a; args[1 .. $])
        if (a.length > 8 && a[0 .. 8] == "--probe=")
            probe = a[8] - '0';

    // Capability gate in the parent, before any fork.
    Display* test = XOpenDisplay(null);
    if (test is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    XCloseDisplay(test);

    if (probe != 0)
        return runProbe(probe);

    // No argument: run the full matrix, each probe TWICE (the F17 spec's
    // nondeterminism rule), each in a forked child so a corrupted Xlib or a
    // caught crash never poisons the next probe. Children always _exit(0).
    foreach (n; 1 .. 7)
        foreach (run; 1 .. 3)
        {
            const pid = fork();
            if (pid == 0)
            {
                runProbe(n);
                _exit(0);
            }
            int status;
            waitpid(pid, &status, 0);
            emitf("probe_child", "n=%d run=%d wait_status=%d", n, run, status);
        }
    emit("teardown all_probes_done");
    return 0;
}
