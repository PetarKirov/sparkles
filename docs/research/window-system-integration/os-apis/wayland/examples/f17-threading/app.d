// F17 Wayland demo — threading probes: exercise (and deliberately violate)
// libwayland's threading model and record exactly what happens
// (../../../features/f17-threading.md; findings in ../../f17-threading.md).
//
// libwayland-client documents wl_display as thread-safe: any thread may issue
// requests, and events are routed to wl_event_queue objects that threads
// dispatch independently (wl_display_create_queue / wl_proxy_set_queue /
// wl_display_dispatch_queue). The read-intent protocol
// (wl_display_prepare_read_queue → read_events|cancel_read) serializes the
// one socket read among any number of reader threads. These probes measure
// that story instead of trusting it.
//
// Probes (--probe=N; no argument = fork+run every probe TWICE, the CI
// default, so race-dependent outcomes show their spread):
//   1  the whole window — registry binds, surface tree, first commit, frame
//      dispatch — built on a WORKER thread against a wl_display that the
//      main thread connected, while main sleeps (no main-thread rule?)
//   2  TWO threads both calling wl_display_dispatch on the same default
//      queue concurrently while frame callbacks keep events flowing — the
//      documented multi-reader shape; how do events distribute?
//   3  the designed pattern: a worker-owned wl_event_queue. The worker makes
//      a wl_proxy_create_wrapper of the display, wl_proxy_set_queue's it,
//      chains 50 wl_display.sync callbacks through its own queue via
//      wl_display_dispatch_queue — while main dispatches the default queue
//      and renders. Prove both run concurrently.
//   4  render thread: a worker paints the wl_shm buffer and issues
//      attach/damage/frame/commit (+ its own wl_display_flush) on the SHARED
//      wl_surface proxy for 100 frames while main dispatches; watch for
//      protocol errors / corruption.
//   5  one wl_display connection per thread — the X11 display-per-thread
//      analog; trivially safe, prove it.
//   6  read-intent protocol violated: thread A holds a successful
//      wl_display_prepare_read while thread B calls wl_display_read_events
//      WITHOUT its own prepare; then a health roundtrip. Timeboxed.
//
// Every probe ends in a verdict line
//     probe n=<N> result=ok|error|crash|deadlock|silent detail=...
// that survives ANY outcome: wl_display_get_error is checked after every
// probe, SIGSEGV/SIGABRT/SIGBUS handlers turn crashes into a flushed verdict
// + _exit(0), and a SIGALRM watchdog turns hangs into result=deadlock.
// Crash probes still exit 0 — crashing is their job.
//
// All probes are self-bounded (frame counts + wall-clock caps + the
// watchdog); WSI_AUTO_EXIT=1 is accepted for uniformity with the other
// Wayland demos but changes nothing.
//
// Headless-safe: no compositor -> prints `SKIP:` and exits 0.
module app;

import c; // ImportC: <wayland-client.h> + xdg-shell glue + wsi_* wrappers
import instrument;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.stdc.stdio : printf, snprintf;
import core.stdc.string : strcmp;
// glibc's <pthread.h> is not ImportC-able (linux/types.h __int128), so the
// thread API comes from druntime's POSIX declarations (see f05-loop-wakeup).
import core.sys.posix.pthread : pthread_create, pthread_join, pthread_self, pthread_t;
import core.sys.posix.signal : sigaction, sigaction_t, sigemptyset,
    SIGABRT, SIGALRM, SIGBUS, SIGSEGV;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.unistd : _exit, alarm, fork, usleep, write;

enum int defaultWidth = 640;
enum int defaultHeight = 480;

// -- verdict plumbing: must survive crashes ------------------------------------

private __gshared int g_probe;
private shared bool g_verdictDone;
private __gshared const(char)* g_watchdogDetail = "watchdog_timeout_12s";

/// The one line the spec requires per run. Async-signal-safe on purpose
/// (snprintf into a static buffer + write(2)) so the signal handlers can
/// call it; the normal path uses it too so the format is identical.
void verdict(scope const(char)* result, scope const(char)* detail) @nogc nothrow
{
    if (atomicLoad(g_verdictDone))
        return;
    atomicStore(g_verdictDone, true);
    static __gshared char[320] buf;
    const n = snprintf(buf.ptr, buf.length, "%lld f17_wayland probe n=%d result=%s detail=%s\n",
        nowUs(), g_probe, result, detail);
    write(2, buf.ptr, n);
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
    verdict("deadlock", g_watchdogDetail);
    _exit(0);
}

void installCrashHandlers() @nogc nothrow
{
    sigaction_t sa;
    sa.sa_handler = &signalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, null);
    sigaction(SIGBUS, &sa, null);
    sigaction(SIGABRT, &sa, null);
    sa.sa_handler = &alarmHandler;
    sigaction(SIGALRM, &sa, null);
    alarm(12); // the deadlock watchdog
}

// -- window machinery (the scaffold, re-parameterized on a Ctx*) ---------------

/// One wl_shm ARGB8888 buffer. `busy` is owned by the compositor between
/// wl_surface.commit and wl_buffer.release — and in probe 4 it crosses
/// threads (release lands on the dispatching main thread, the render worker
/// polls it), hence atomic.
struct Buffer
{
    wl_buffer* handle;
    uint* pixels;
    size_t byteSize;
    int width, height;
    shared bool busy;
}

/// Everything one connection-plus-window owns. Probes share one global Ctx,
/// except probe 5, which gives each thread its own.
struct Ctx
{
    const(char)* tag = "main";
    wl_display* display;
    wl_registry* registry;
    wl_compositor* compositor;
    wl_shm* shm;
    xdg_wm_base* wmBase;
    wl_surface* surface;
    xdg_surface* xdgSurface;
    xdg_toplevel* toplevel;
    wl_callback* frameCb;
    Buffer[2] buffers;
    int width = defaultWidth;
    int height = defaultHeight;
    int pendingW, pendingH;
    bool configured;
    bool autoRender = true; // frame callback re-renders (probes 1,2,3,5)
    shared bool running = true;
    shared int frames; // frame callbacks received (any thread)
    int commits;
}

bool ensureBuffer(Ctx* ctx, ref Buffer b, int w, int h) @nogc nothrow
{
    if (b.handle !is null && (b.width != w || b.height != h))
    {
        wsi_buffer_destroy(b.handle);
        munmap(b.pixels, b.byteSize);
        b = Buffer.init;
    }
    if (b.handle !is null)
        return true;

    immutable stride = w * 4;
    immutable size = cast(size_t) stride * h;
    immutable fd = memfd_create("wsi-f17", MFD_CLOEXEC);
    if (fd < 0)
        return false;
    if (ftruncate(fd, cast(long) size) != 0)
    {
        close(fd);
        return false;
    }
    void* mem = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mem is cast(void*)-1)
    {
        close(fd);
        return false;
    }
    wl_shm_pool* pool = wsi_shm_create_pool(ctx.shm, fd, cast(int) size);
    b.handle = wsi_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wsi_shm_pool_destroy(pool);
    close(fd);
    wsi_buffer_add_listener(b.handle, &g_bufferListener, &b);
    b.pixels = cast(uint*) mem;
    b.byteSize = size;
    b.width = w;
    b.height = h;
    atomicStore(b.busy, false);
    return true;
}

/// Solid fill keyed to the frame counter — cheap, and each redraw observable.
void paint(ref Buffer b, int frame) @nogc nothrow
{
    immutable uint color = 0xff00_0000 | ((frame * 2 & 0xff) << 16)
        | ((255 - (frame * 2 & 0xff)) << 8) | 0x40;
    foreach (i; 0 .. cast(size_t) b.width * b.height)
        b.pixels[i] = color;
}

Buffer* freeBuffer(Ctx* ctx) @nogc nothrow
{
    foreach (ref b; ctx.buffers)
        if (!atomicLoad(b.busy))
            return &b;
    return null;
}

/// Paint + attach/damage/commit (+ at most one frame callback in flight).
/// Runs on whichever thread the probe says — that is the experiment.
bool render(Ctx* ctx) @nogc nothrow
{
    Buffer* buf = freeBuffer(ctx);
    if (buf is null)
        return true; // both held by the compositor; release will free one
    if (!ensureBuffer(ctx, *buf, ctx.width, ctx.height))
        return false;
    paint(*buf, atomicLoad(ctx.frames));
    wsi_surface_attach(ctx.surface, buf.handle, 0, 0);
    wsi_surface_damage_buffer(ctx.surface, 0, 0, buf.width, buf.height);
    if (ctx.frameCb is null)
    {
        ctx.frameCb = wsi_surface_frame(ctx.surface);
        wsi_callback_add_listener(ctx.frameCb, &g_frameListener, ctx);
    }
    wsi_surface_commit(ctx.surface);
    atomicStore(buf.busy, true);
    ctx.commits++;
    return true;
}

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) @nogc nothrow
{
    auto ctx = cast(Ctx*) data;
    if (strcmp(iface, wl_compositor_interface.name) == 0)
        ctx.compositor = cast(wl_compositor*) wsi_registry_bind(reg, name,
            &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        ctx.shm = cast(wl_shm*) wsi_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        ctx.wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name, &xdg_wm_base_interface, 1);
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) @nogc nothrow
{
}

extern (C) void onWmBasePing(void* data, xdg_wm_base* b, uint serial) @nogc nothrow
{
    wsi_wm_base_pong(b, serial);
}

extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) @nogc nothrow
{
    auto ctx = cast(Ctx*) data;
    ctx.pendingW = w;
    ctx.pendingH = h;
}

extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) @nogc nothrow
{
    auto ctx = cast(Ctx*) data;
    wsi_xdg_surface_ack_configure(s, serial);
    ctx.width = ctx.pendingW > 0 ? ctx.pendingW : defaultWidth;
    ctx.height = ctx.pendingH > 0 ? ctx.pendingH : defaultHeight;
    if (!ctx.configured)
    {
        ctx.configured = true;
        emitf("first_configure", "tag=%s size=%dx%d", ctx.tag, ctx.width, ctx.height);
        render(ctx);
    }
}

extern (C) void onToplevelClose(void* data, xdg_toplevel* t) @nogc nothrow
{
    atomicStore((cast(Ctx*) data).running, false);
}

extern (C) void onToplevelConfigureBounds(void* data, xdg_toplevel* t, int w, int h) @nogc nothrow
{
}

extern (C) void onToplevelWmCapabilities(void* data, xdg_toplevel* t, wl_array* caps) @nogc nothrow
{
}

extern (C) void onBufferRelease(void* data, wl_buffer* b) @nogc nothrow
{
    atomicStore((cast(Buffer*) data).busy, false);
}

// Probe-2 bookkeeping: which thread ran the frame-callback handler?
private __gshared pthread_t[2] g_dispThreads;
private shared int[3] g_framesOnThread; // [main, dispatcher a, dispatcher b]

extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) @nogc nothrow
{
    auto ctx = cast(Ctx*) data;
    wsi_callback_destroy(cb);
    ctx.frameCb = null;
    atomicOp!"+="(ctx.frames, 1);
    const self = pthread_self();
    if (self == g_dispThreads[0])
        atomicOp!"+="(g_framesOnThread[1], 1);
    else if (self == g_dispThreads[1])
        atomicOp!"+="(g_framesOnThread[2], 1);
    else
        atomicOp!"+="(g_framesOnThread[0], 1);
    if (ctx.autoRender && atomicLoad(ctx.running))
        render(ctx);
}

__gshared wl_registry_listener g_registryListener = {&onGlobal, &onGlobalRemove};
__gshared xdg_wm_base_listener g_wmBaseListener = {&onWmBasePing};
__gshared xdg_surface_listener g_xdgSurfaceListener = {&onXdgSurfaceConfigure};
__gshared xdg_toplevel_listener g_toplevelListener = {
    &onToplevelConfigure, &onToplevelClose,
    &onToplevelConfigureBounds, &onToplevelWmCapabilities
};
__gshared wl_buffer_listener g_bufferListener = {&onBufferRelease};
__gshared wl_callback_listener g_frameListener = {&onFrameDone};

/// Registry roundtrip + surface tree + initial no-buffer commit + dispatch
/// until the first configure is acked (which commits the first buffer).
/// Runs on whichever thread the probe says.
bool setupWindow(Ctx* ctx, const(char)* title) @nogc nothrow
{
    ctx.registry = wsi_display_get_registry(ctx.display);
    wsi_registry_add_listener(ctx.registry, &g_registryListener, ctx);
    if (wl_display_roundtrip(ctx.display) < 0)
        return false;
    if (ctx.compositor is null || ctx.shm is null || ctx.wmBase is null)
        return false;
    wsi_wm_base_add_listener(ctx.wmBase, &g_wmBaseListener, ctx);
    ctx.surface = wsi_compositor_create_surface(ctx.compositor);
    ctx.xdgSurface = wsi_wm_base_get_xdg_surface(ctx.wmBase, ctx.surface);
    wsi_xdg_surface_add_listener(ctx.xdgSurface, &g_xdgSurfaceListener, ctx);
    ctx.toplevel = wsi_xdg_surface_get_toplevel(ctx.xdgSurface);
    wsi_toplevel_add_listener(ctx.toplevel, &g_toplevelListener, ctx);
    wsi_toplevel_set_title(ctx.toplevel, title);
    wsi_toplevel_set_app_id(ctx.toplevel, title);
    wsi_surface_commit(ctx.surface); // the mandatory no-buffer initial commit
    emitf("window_created", "tag=%s", ctx.tag);
    while (!ctx.configured)
        if (wl_display_dispatch(ctx.display) < 0)
            return false;
    return true;
}

/// Blocking-dispatch the default queue until `nFrames` frame callbacks or
/// `capUs` elapse.
bool dispatchFrames(Ctx* ctx, int nFrames, long capUs) @nogc nothrow
{
    const deadline = nowUs() + capUs;
    while (atomicLoad(ctx.frames) < nFrames && nowUs() < deadline)
        if (wl_display_dispatch(ctx.display) < 0)
            return false;
    return true;
}

void teardownCtx(Ctx* ctx, bool disconnect) @nogc nothrow
{
    foreach (ref b; ctx.buffers)
        if (b.handle !is null)
        {
            wsi_buffer_destroy(b.handle);
            munmap(b.pixels, b.byteSize);
            b = Buffer.init;
        }
    if (ctx.frameCb !is null)
        wsi_callback_destroy(ctx.frameCb);
    if (ctx.toplevel !is null)
        wsi_toplevel_destroy(ctx.toplevel);
    if (ctx.xdgSurface !is null)
        wsi_xdg_surface_destroy(ctx.xdgSurface);
    if (ctx.surface !is null)
        wsi_surface_destroy(ctx.surface);
    if (ctx.wmBase !is null)
        wsi_wm_base_destroy(ctx.wmBase);
    if (ctx.shm !is null)
        wl_proxy_destroy(cast(wl_proxy*) ctx.shm);
    if (ctx.compositor !is null)
        wl_proxy_destroy(cast(wl_proxy*) ctx.compositor);
    if (ctx.registry !is null)
        wl_proxy_destroy(cast(wl_proxy*) ctx.registry);
    if (disconnect && ctx.display !is null)
        wl_display_disconnect(ctx.display);
}

/// Post-probe health check shared by every probe that keeps its connection.
const(char)* protocolErrorText(Ctx* ctx) @nogc nothrow
{
    return wl_display_get_error(ctx.display) == 0 ? "0".ptr : "SET".ptr;
}

private __gshared Ctx g_ctx;

// -- probe 1: the whole window built on a worker thread, main sleeps -----------

private shared bool g_workerDone;
private shared bool g_workerOk;

extern (C) void* windowWorker(void*) @nogc nothrow
{
    emit("thread=worker action=setup_window_start");
    bool ok = setupWindow(&g_ctx, "wsi-f17-threading");
    if (ok)
        ok = dispatchFrames(&g_ctx, 30, 4_000_000);
    emitf("thread=worker", "action=done ok=%d frames=%d commits=%d",
        cast(int) ok, atomicLoad(g_ctx.frames), g_ctx.commits);
    teardownCtx(&g_ctx, false); // even teardown happens off-main
    atomicStore(g_workerOk, ok && atomicLoad(g_ctx.frames) >= 30);
    atomicStore(g_workerDone, true);
    return null;
}

int probeWindowOnWorker() @nogc nothrow
{
    g_ctx.display = wl_display_connect(null); // connected on MAIN …
    if (g_ctx.display is null)
    {
        verdict("error", "no_compositor_in_child");
        return 0;
    }
    emit("step name=wl_display_connect thread=main");
    pthread_t t;
    pthread_create(&t, null, &windowWorker, null);
    // … and never touched by main again until the worker is done: main SLEEPS.
    while (!atomicLoad(g_workerDone))
        usleep(10_000);
    pthread_join(t, null);

    static __gshared char[192] d;
    snprintf(d.ptr, d.length,
        "window_and_30_frames_entirely_on_worker=%d connect_thread=main protocol_error=%s",
        cast(int) atomicLoad(g_workerOk), protocolErrorText(&g_ctx));
    verdict(atomicLoad(g_workerOk) ? "ok" : "error", d.ptr);
    wl_display_disconnect(g_ctx.display);
    return 0;
}

// -- probe 2: two threads dispatching the same default queue -------------------

private shared bool g_p2Running;
private shared int g_alive;
private shared int[2] g_dispatched; // events returned by wl_display_dispatch
private shared int[2] g_dispatchCalls;
private shared int g_syncDone;

extern (C) void onSyncCount(void* data, wl_callback* cb, uint t) @nogc nothrow
{
    wsi_callback_destroy(cb);
    atomicOp!"+="(g_syncDone, 1);
}

__gshared wl_callback_listener g_syncCountListener = {&onSyncCount};

extern (C) void* dispatcher(void* arg) @nogc nothrow
{
    const idx = cast(int) cast(size_t) arg;
    atomicOp!"+="(g_alive, 1);
    emitf("thread_start", "thread=dispatcher_%c", cast(char)('a' + idx));
    while (atomicLoad(g_p2Running))
    {
        const n = wl_display_dispatch(g_ctx.display); // blocking, default queue
        if (n < 0)
            break;
        atomicOp!"+="(g_dispatched[idx], n);
        atomicOp!"+="(g_dispatchCalls[idx], 1);
    }
    emitf("thread_done", "thread=dispatcher_%c events=%d calls=%d",
        cast(char)('a' + idx), atomicLoad(g_dispatched[idx]), atomicLoad(g_dispatchCalls[idx]));
    atomicOp!"-="(g_alive, 1);
    return null;
}

int probeConcurrentDispatch() @nogc nothrow
{
    g_ctx.display = wl_display_connect(null);
    if (g_ctx.display is null || !setupWindow(&g_ctx, "wsi-f17-threading"))
    {
        verdict("error", "setup_failed");
        return 0;
    }
    // autoRender keeps frame callbacks (≈60 Hz events) flowing; the frame
    // handler runs on whichever thread happens to dispatch it.
    atomicStore(g_p2Running, true);
    pthread_t[2] ts;
    pthread_create(&ts[0], null, &dispatcher, cast(void*) 0);
    pthread_create(&ts[1], null, &dispatcher, cast(void*) 1);
    g_dispThreads[0] = ts[0];
    g_dispThreads[1] = ts[1];

    usleep(2_000_000); // main does NOT dispatch — only the two workers do
    atomicStore(g_p2Running, false);

    // A thread blocked in wl_display_dispatch only wakes when an event
    // arrives — feed wl_display.sync done events until both exit (cap 400).
    int wakes = 0;
    while (atomicLoad(g_alive) > 0 && wakes < 400)
    {
        auto cb = wsi_display_sync(g_ctx.display);
        wsi_callback_add_listener(cb, &g_syncCountListener, null);
        wl_display_flush(g_ctx.display);
        ++wakes;
        usleep(5000);
    }
    const stuck = atomicLoad(g_alive);
    static __gshared char[256] d;
    if (stuck > 0)
    {
        snprintf(d.ptr, d.length,
            "threads_stuck_in_dispatch=%d after_%d_sync_wakes events_a=%d events_b=%d",
            stuck, wakes, atomicLoad(g_dispatched[0]), atomicLoad(g_dispatched[1]));
        verdict("deadlock", d.ptr);
        _exit(0); // cannot join a stuck thread; verdict is flushed
    }
    pthread_join(ts[0], null);
    pthread_join(ts[1], null);
    snprintf(d.ptr, d.length,
        "events_a=%d events_b=%d frames=%d frames_handled_on_a=%d on_b=%d sync_wakes_to_unblock=%d protocol_error=%s",
        atomicLoad(g_dispatched[0]), atomicLoad(g_dispatched[1]),
        atomicLoad(g_ctx.frames), atomicLoad(g_framesOnThread[1]),
        atomicLoad(g_framesOnThread[2]), wakes, protocolErrorText(&g_ctx));
    verdict(wl_display_get_error(g_ctx.display) == 0 ? "ok" : "error", d.ptr);
    teardownCtx(&g_ctx, true);
    return 0;
}

// -- probe 3: the designed pattern — a worker-owned wl_event_queue -------------

private shared bool g_qSyncSeen;
private shared int g_workerSyncs;
private shared long g_workerFirstUs, g_workerLastUs;
private shared bool g_p3WorkerDone;

extern (C) void onQueueSync(void* data, wl_callback* cb, uint t) @nogc nothrow
{
    wsi_callback_destroy(cb);
    const now = nowUs();
    if (atomicLoad(g_workerFirstUs) == 0)
        atomicStore(g_workerFirstUs, now);
    atomicStore(g_workerLastUs, now);
    atomicStore(g_qSyncSeen, true);
}

__gshared wl_callback_listener g_queueSyncListener = {&onQueueSync};

extern (C) void* queueWorker(void*) @nogc nothrow
{
    auto display = g_ctx.display;
    // The worker's own queue, and a display *wrapper* to assign it through —
    // wl_proxy_set_queue on a wrapper is the race-free idiom: objects created
    // via the wrapper are born on the worker's queue, never the default one.
    auto queue = wl_display_create_queue(display);
    auto wrapper = cast(wl_display*) wl_proxy_create_wrapper(display);
    wl_proxy_set_queue(cast(wl_proxy*) wrapper, queue);
    emit("thread=worker action=queue_and_wrapper_created");

    foreach (i; 0 .. 50)
    {
        atomicStore(g_qSyncSeen, false);
        auto cb = wsi_display_sync(wrapper); // done event -> worker's queue
        wsi_callback_add_listener(cb, &g_queueSyncListener, null);
        bool failed = false;
        while (!atomicLoad(g_qSyncSeen))
            if (wl_display_dispatch_queue(display, queue) < 0)
            {
                failed = true;
                break;
            }
        if (failed)
            break;
        atomicOp!"+="(g_workerSyncs, 1);
        usleep(10_000); // ~10 ms apart, so the runs overlap main's frames
    }
    wl_proxy_wrapper_destroy(cast(wl_proxy*) wrapper);
    wl_event_queue_destroy(queue);
    emitf("thread=worker", "action=done syncs=%d", atomicLoad(g_workerSyncs));
    atomicStore(g_p3WorkerDone, true);
    return null;
}

int probePerThreadQueue() @nogc nothrow
{
    g_ctx.display = wl_display_connect(null);
    if (g_ctx.display is null || !setupWindow(&g_ctx, "wsi-f17-threading"))
    {
        verdict("error", "setup_failed");
        return 0;
    }
    const mainFirstUs = nowUs();
    pthread_t t;
    pthread_create(&t, null, &queueWorker, null);

    // Main dispatches the DEFAULT queue (frame callbacks + rendering) while
    // the worker dispatches ITS queue — concurrently, on one connection.
    while (!atomicLoad(g_p3WorkerDone))
        if (wl_display_dispatch(g_ctx.display) < 0)
            break;
    pthread_join(t, null);
    const mainLastUs = nowUs();

    // Concurrency evidence: the worker's 50 sync round-trips and main's frame
    // stream span overlapping time windows on the same wl_display.
    const overlap = atomicLoad(g_workerFirstUs) < mainLastUs
        && mainFirstUs < atomicLoad(g_workerLastUs)
        && atomicLoad(g_ctx.frames) > 0;
    static __gshared char[256] d;
    snprintf(d.ptr, d.length,
        "worker_syncs=%d/50 main_frames=%d overlap=%d worker_window_us=%lld..%lld protocol_error=%s",
        atomicLoad(g_workerSyncs), atomicLoad(g_ctx.frames), cast(int) overlap,
        atomicLoad(g_workerFirstUs), atomicLoad(g_workerLastUs), protocolErrorText(&g_ctx));
    verdict(atomicLoad(g_workerSyncs) == 50 && overlap
            && wl_display_get_error(g_ctx.display) == 0 ? "ok" : "error", d.ptr);
    teardownCtx(&g_ctx, true);
    return 0;
}

// -- probe 4: render thread committing the shared wl_surface -------------------

private shared int g_renderFrames; // frame callbacks for worker commits
private shared int g_renderCommits;
private shared bool g_p4WorkerDone;

extern (C) void onRenderFrame(void* data, wl_callback* cb, uint t) @nogc nothrow
{
    wsi_callback_destroy(cb);
    atomicOp!"+="(g_renderFrames, 1);
}

__gshared wl_callback_listener g_renderFrameListener = {&onRenderFrame};

extern (C) void* renderWorker(void*) @nogc nothrow
{
    emit("thread=render action=start frames_target=100");
    foreach (frame; 0 .. 100)
    {
        // Wait for a free buffer (wl_buffer.release lands on the main pump).
        Buffer* buf = null;
        const bufDeadline = nowUs() + 1_000_000;
        while (buf is null && nowUs() < bufDeadline)
        {
            buf = freeBuffer(&g_ctx);
            if (buf is null)
                usleep(500);
        }
        if (buf is null)
            break;
        if (!ensureBuffer(&g_ctx, *buf, g_ctx.width, g_ctx.height))
            break;
        paint(*buf, frame);
        // Requests on the shared wl_surface proxy, from the worker:
        wsi_surface_attach(g_ctx.surface, buf.handle, 0, 0);
        wsi_surface_damage_buffer(g_ctx.surface, 0, 0, buf.width, buf.height);
        auto cb = wsi_surface_frame(g_ctx.surface);
        wsi_callback_add_listener(cb, &g_renderFrameListener, null);
        wsi_surface_commit(g_ctx.surface);
        atomicStore(buf.busy, true);
        wl_display_flush(g_ctx.display); // each thread flushes its own requests
        atomicOp!"+="(g_renderCommits, 1);
        // Throttle on presentation: the frame callback is dispatched by MAIN.
        const frameDeadline = nowUs() + 1_000_000;
        while (atomicLoad(g_renderFrames) < atomicLoad(g_renderCommits)
            && nowUs() < frameDeadline)
            usleep(500);
    }
    emitf("thread=render", "action=done commits=%d frames_acked=%d",
        atomicLoad(g_renderCommits), atomicLoad(g_renderFrames));
    atomicStore(g_p4WorkerDone, true);
    // One last sync so the main dispatcher wakes and sees the done flag.
    auto cb = wsi_display_sync(g_ctx.display);
    wsi_callback_add_listener(cb, &g_syncCountListener, null);
    wl_display_flush(g_ctx.display);
    return null;
}

int probeRenderThread() @nogc nothrow
{
    g_ctx.autoRender = false; // main only pumps; the worker owns rendering
    g_ctx.display = wl_display_connect(null);
    if (g_ctx.display is null || !setupWindow(&g_ctx, "wsi-f17-threading"))
    {
        verdict("error", "setup_failed");
        return 0;
    }
    pthread_t t;
    pthread_create(&t, null, &renderWorker, null);
    while (!atomicLoad(g_p4WorkerDone))
        if (wl_display_dispatch(g_ctx.display) < 0)
            break;
    pthread_join(t, null);

    const commits = atomicLoad(g_renderCommits);
    const acked = atomicLoad(g_renderFrames);
    static __gshared char[224] d;
    snprintf(d.ptr, d.length,
        "commits_from_render_thread=%d/100 frame_callbacks=%d protocol_error=%s",
        commits, acked, protocolErrorText(&g_ctx));
    verdict(commits == 100 && acked >= 99 && wl_display_get_error(g_ctx.display) == 0
            ? "ok" : "error", d.ptr);
    teardownCtx(&g_ctx, true);
    return 0;
}

// -- probe 5: one wl_display connection per thread ------------------------------

private __gshared Ctx[2] g_p5ctx;
private shared int g_p5Ok;

extern (C) void* connectionPerThread(void* arg) @nogc nothrow
{
    const idx = cast(int) cast(size_t) arg;
    auto ctx = &g_p5ctx[idx];
    ctx.tag = idx == 0 ? "t0".ptr : "t1".ptr;
    ctx.display = wl_display_connect(null); // private connection: nothing shared
    if (ctx.display is null)
        return null;
    emitf("thread_connect", "tag=%s fd=%d", ctx.tag, wl_display_get_fd(ctx.display));
    bool ok = setupWindow(ctx, idx == 0 ? "wsi-f17-t0".ptr : "wsi-f17-t1".ptr);
    if (ok)
        ok = dispatchFrames(ctx, 20, 3_000_000) && atomicLoad(ctx.frames) >= 20;
    emitf("thread_done", "tag=%s ok=%d frames=%d", ctx.tag, cast(int) ok,
        atomicLoad(ctx.frames));
    teardownCtx(ctx, true);
    if (ok)
        atomicOp!"+="(g_p5Ok, 1);
    return null;
}

int probeConnectionPerThread() @nogc nothrow
{
    pthread_t[2] ts;
    pthread_create(&ts[0], null, &connectionPerThread, cast(void*) 0);
    pthread_create(&ts[1], null, &connectionPerThread, cast(void*) 1);
    pthread_join(ts[0], null);
    pthread_join(ts[1], null);
    static __gshared char[96] d;
    snprintf(d.ptr, d.length, "threads_completed=%d/2 model=connection_per_thread",
        atomicLoad(g_p5Ok));
    verdict(atomicLoad(g_p5Ok) == 2 ? "ok" : "error", d.ptr);
    return 0;
}

// -- probe 6: read-intent protocol violated -------------------------------------

private shared bool g_prepared;
private shared bool g_holderDone;
private shared bool g_violatorDone;
private shared int g_violatorRet;
private shared long g_violatorUs;

extern (C) void* intentHolder(void*) @nogc nothrow
{
    auto display = g_ctx.display;
    while (wl_display_prepare_read(display) != 0)
        wl_display_dispatch_pending(display);
    emit("thread=holder action=prepare_read_acquired");
    atomicStore(g_prepared, true);
    usleep(600_000); // hold the read intent while the violator strikes
    wl_display_cancel_read(display);
    emit("thread=holder action=cancel_read_returned");
    atomicStore(g_holderDone, true);
    return null;
}

extern (C) void* readViolator(void*) @nogc nothrow
{
    const t0 = nowUs();
    // The violation: read_events without this thread ever calling
    // prepare_read. The documented contract pairs them strictly 1:1.
    const r = wl_display_read_events(g_ctx.display);
    atomicStore(g_violatorUs, nowUs() - t0);
    atomicStore(g_violatorRet, r);
    emitf("thread=violator", "action=read_events_returned ret=%d took_us=%lld",
        r, atomicLoad(g_violatorUs));
    atomicStore(g_violatorDone, true);
    return null;
}

int probePrepareReadViolation() @nogc nothrow
{
    g_ctx.display = wl_display_connect(null);
    if (g_ctx.display is null)
    {
        verdict("error", "no_compositor_in_child");
        return 0;
    }
    pthread_t holder, violator;
    pthread_create(&holder, null, &intentHolder, null);
    while (!atomicLoad(g_prepared))
        usleep(1000);
    pthread_create(&violator, null, &readViolator, null);

    // Timebox the violator: it may block forever inside read_events.
    const deadline = nowUs() + 3_000_000;
    while (!atomicLoad(g_violatorDone) && nowUs() < deadline)
        usleep(10_000);
    static __gshared char[256] d;
    if (!atomicLoad(g_violatorDone))
    {
        snprintf(d.ptr, d.length,
            "read_events_without_prepare_blocked_3s holder_done=%d",
            cast(int) atomicLoad(g_holderDone));
        verdict("deadlock", d.ptr);
        _exit(0); // cannot join the stuck thread; verdict is flushed
    }
    pthread_join(violator, null);
    while (!atomicLoad(g_holderDone))
        usleep(10_000);
    pthread_join(holder, null);

    // Health check: does the connection still work after the violation?
    g_watchdogDetail = "health_roundtrip_hung_after_violation";
    alarm(4);
    const rt = wl_display_roundtrip(g_ctx.display);
    alarm(0);
    const err = wl_display_get_error(g_ctx.display);
    snprintf(d.ptr, d.length,
        "read_events_no_prepare ret=%d took_us=%lld health_roundtrip=%d display_error=%d (nondeterministic)",
        atomicLoad(g_violatorRet), atomicLoad(g_violatorUs), rt, err);
    verdict(err != 0 || rt < 0 ? "error" : "silent", d.ptr);
    wl_display_disconnect(g_ctx.display);
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
        probeWindowOnWorker();
        break;
    case 2:
        probeConcurrentDispatch();
        break;
    case 3:
        probePerThreadQueue();
        break;
    case 4:
        probeRenderThread();
        break;
    case 5:
        probeConnectionPerThread();
        break;
    case 6:
        probePrepareReadViolation();
        break;
    default:
        verdict("error", "unknown_probe");
    }
    alarm(0);
    return 0;
}

int main(string[] args)
{
    initInstrument("f17_wayland");

    int probe = 0;
    foreach (a; args[1 .. $])
        if (a.length > 8 && a[0 .. 8] == "--probe=")
            probe = a[8] - '0';

    // Capability gate in the parent, before any fork.
    wl_display* test = wl_display_connect(null);
    if (test is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }
    wl_display_disconnect(test);

    if (probe != 0)
        return runProbe(probe);

    // No argument: run the full matrix, each probe TWICE (the F17 spec's
    // nondeterminism rule), each in a forked child so a wedged libwayland or
    // a caught crash never poisons the next probe. Children always _exit(0).
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
