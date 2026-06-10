// F05 loop wakeup & external fds on Wayland (../../f05-loop-wakeup.md): can a
// second thread wake the native event loop, and can arbitrary fds join it?
//
// Wayland's answer is structural: the wl_display connection IS a file
// descriptor, and libwayland's documented thread-safe pump —
// wl_display_prepare_read / poll / wl_display_read_events /
// wl_display_dispatch_pending — is *designed* around the application owning
// the poll(2) call. So "integrate an external fd" is not a workaround on
// Wayland, it is the intended shape: put the wl fd, an eventfd, and a timerfd
// into ONE pollfd array (see pumpOnce, the deliverable of this demo).
//
// What Wayland does NOT have is a protocol-level user event (no XSendEvent /
// PostMessage analogue): a client cannot send itself a message through the
// compositor. The absence is the finding — cross-thread wakeup must be a
// client-owned fd. This demo uses eventfd(2):
//
//   1. A producer pthread writes the eventfd 10×/s for 30 s; each post's
//      monotonic timestamp travels through a lock-free ring (the eventfd
//      counter is a *sum*, so coalesced posts would corrupt an inline
//      timestamp — the side buffer is the correct pattern). The main loop
//      logs `wakeup latency_us=… mech=eventfd` per post.
//   2. A timerfd ticking at 7 Hz is the arbitrary-fd probe; its `fd_tick`
//      lines interleave with the 60 Hz frame-callback redraws.
//   3. min/median/p99/max latency is printed at exit.
//
// Based on the scaffold (../scaffold/app.d, findings ../../scaffold.md);
// instrumentation contract: ./instrument.d. Headless-safe: no compositor →
// SKIP, exit 0. WSI_AUTO_EXIT is accepted for runner symmetry; the run is
// inherently bounded (producer stops after WSI_F05_WAKEUPS posts, default 300).
module app;

import c; // ImportC: <wayland-client.h> + xdg-shell glue + eventfd/timerfd/poll + wsi_* wrappers
import instrument;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;
// glibc 2.42's <pthread.h> is not ImportC-able (linux/types.h __int128), so
// the thread API comes from druntime's POSIX declarations instead (see c.c).
import core.sys.posix.pthread : pthread_create, pthread_join, pthread_t;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv, qsort;
import core.stdc.string : strcmp;

// ----------------------------------------------------------------- tunables

enum int defaultWidth = 640;
enum int defaultHeight = 480;
enum int wakeupHz = 10; // producer posts 10×/s …
enum int defaultWakeups = 300; // … for 30 s (override: WSI_F05_WAKEUPS)
enum long timerTickNs = 1_000_000_000L / 7; // the 7 Hz timerfd probe
enum int pollTimeoutMs = 250; // backstop tick (poll is the real wait)
enum long hardCapSlackUs = 10_000_000; // grace beyond the nominal run length
enum int maxSamples = 4096;

// -------------------------------------------------------------------- state

/// One wl_shm-backed ARGB8888 buffer. `busy` is owned by the compositor
/// between wl_surface.commit and the wl_buffer.release event.
struct Buffer
{
    wl_buffer* handle;
    uint* pixels; // mmap'ed, shared with the compositor
    size_t byteSize;
    int width, height;
    bool busy;
}

__gshared
{
    wl_display* g_display;
    wl_registry* g_registry;
    wl_compositor* g_compositor;
    wl_shm* g_shm;
    wl_seat* g_seat;
    xdg_wm_base* g_wmBase;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb; // at most one outstanding frame callback

    Buffer[2] g_buffers;

    int g_width = defaultWidth; // last *acked* size — buffers must match it
    int g_height = defaultHeight;
    int g_pendingWidth;
    int g_pendingHeight;
    bool g_configured;
    bool g_presented;
    bool g_running = true;
    int g_frames;
    int g_commits;

    // The two external fds multiplexed with the wl_display fd.
    int g_eventfd = -1; // cross-thread wakeup channel (mech=eventfd)
    int g_timerfd = -1; // arbitrary-fd probe (mech=timerfd, 7 Hz)

    // Producer → consumer timestamp ring. The eventfd's 8-byte counter is a
    // SUM of the posted values, so coalesced posts (two writes before one
    // read) would add two timestamps into garbage; the ring carries each
    // timestamp intact and the counter only says how many to pop.
    long[maxSamples] g_ring;
    ulong g_ringWrite; // producer-owned, release-published
    ulong g_ringRead; // consumer-owned
    bool g_producerDone; // release-published by the producer thread

    int g_wakeupsWanted = defaultWakeups;
    long[maxSamples] g_latencies; // consumed-wakeup latencies, µs
    int g_latCount;
    int g_coalesced; // posts that arrived >1 per eventfd read
    long g_fdTicks; // timerfd expirations seen
}

// --------------------------------------------------------- producer thread

/// Second thread: every 100 ms, stamp "now", publish it in the ring, write
/// the eventfd. The write(2) is the only wakeup mechanism Wayland offers a
/// thread that is not the dispatcher — there is no protocol-level user event
/// to post. (libwayland itself is thread-safe, but events it queues are only
/// seen when the *dispatching* thread next wakes — which is this eventfd.)
extern (C) void* producerMain(void*) nothrow @nogc
{
    foreach (i; 0 .. g_wakeupsWanted)
    {
        timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 1_000_000_000 / wakeupHz;
        nanosleep(&ts, null);

        immutable stamp = instrNowUs(); // same MonoTime epoch as the main loop
        immutable wi = atomicLoad!(MemoryOrder.raw)(*cast(shared ulong*)&g_ringWrite);
        g_ring[cast(size_t)(wi % maxSamples)] = stamp;
        atomicStore!(MemoryOrder.rel)(*cast(shared ulong*)&g_ringWrite, wi + 1);

        ulong one = 1;
        write(g_eventfd, &one, one.sizeof); // the doorbell: kicks poll()
    }
    atomicStore!(MemoryOrder.rel)(*cast(shared bool*)&g_producerDone, true);
    ulong one = 1;
    write(g_eventfd, &one, one.sizeof); // final kick so the loop notices done
    return null;
}

// ------------------------------------------------- external-fd drain hooks

/// eventfd readable: one read returns (and zeroes) the whole counter — the
/// number of posts since the last read. Latency is measured per post against
/// the timestamp it carried through the ring.
void drainEventfd() nothrow @nogc
{
    ulong count;
    if (read(g_eventfd, &count, count.sizeof) != count.sizeof)
        return;
    immutable now = instrNowUs();
    immutable wi = atomicLoad!(MemoryOrder.acq)(*cast(shared ulong*)&g_ringWrite);
    int popped;
    while (g_ringRead < wi)
    {
        immutable stamp = g_ring[cast(size_t)(g_ringRead % maxSamples)];
        immutable lat = now - stamp;
        if (g_latCount < maxSamples)
            g_latencies[g_latCount++] = lat;
        instrEvent("wakeup", "latency_us=%lld mech=eventfd seq=%llu", lat, g_ringRead);
        g_ringRead++;
        popped++;
    }
    if (popped > 1)
    {
        g_coalesced += popped - 1;
        instrEvent("wakeup_coalesced", "posts=%d eventfd_count=%llu", popped, count);
    }
}

/// timerfd readable: the 8-byte read is the number of expirations since the
/// last read (>1 means the loop was late by a full period).
void drainTimerfd() nothrow @nogc
{
    ulong expirations;
    if (read(g_timerfd, &expirations, expirations.sizeof) != expirations.sizeof)
        return;
    g_fdTicks += expirations;
    instrEvent("fd_tick", "t=%lld mech=timerfd expirations=%llu n=%lld",
        instrNowUs(), expirations, g_fdTicks);
}

// ------------------------------------------- the canonical multiplexing loop

/// THE deliverable: the wl_display fd multiplexed with arbitrary fds in one
/// poll(2), via libwayland's thread-safe read pattern.
///
/// wl_display_prepare_read's contract (wayland-client.h): it registers this
/// thread's intent to read the socket and FAILS (-1) while the default queue
/// still holds undispatched events — so step 1 loops dispatch_pending until
/// the queue is empty and the intent is registered. After it succeeds, this
/// thread must call exactly one of read_events (socket readable) or
/// cancel_read (woken for any other reason) — leaking the intent deadlocks
/// other readers. Requests are flushed *before* blocking so the compositor is
/// never left waiting on a half-sent message.
bool pumpOnce(int timeoutMs) nothrow @nogc
{
    // 1. Dispatch what is already queued; acquire the read intent.
    while (wl_display_prepare_read(g_display) != 0)
        if (wl_display_dispatch_pending(g_display) < 0)
            return false;
    // 2. Flush outgoing requests before sleeping.
    wl_display_flush(g_display);

    // 3. ONE poll over all event sources — the whole point of the pattern.
    pollfd[3] pfds;
    pfds[0].fd = wl_display_get_fd(g_display);
    pfds[0].events = POLLIN;
    pfds[1].fd = g_eventfd;
    pfds[1].events = POLLIN;
    pfds[2].fd = g_timerfd;
    pfds[2].events = POLLIN;
    immutable r = poll(pfds.ptr, 3, timeoutMs);
    if (r < 0)
    {
        wl_display_cancel_read(g_display);
        return false;
    }

    // 4. Exactly one of read_events / cancel_read, per the contract.
    if (pfds[0].revents & POLLIN)
    {
        if (wl_display_read_events(g_display) < 0)
            return false; // read_events consumed the intent
        if (wl_display_dispatch_pending(g_display) < 0)
            return false;
    }
    else
        wl_display_cancel_read(g_display);

    // 5. The external fds, on the same wakeup.
    if (pfds[1].revents & POLLIN)
        drainEventfd();
    if (pfds[2].revents & POLLIN)
        drainTimerfd();
    return true;
}

// ---------------------------------------------------------- shm buffer pool

/// (Re)allocate `b` so it matches `w`×`h` (scaffold pattern).
bool ensureBuffer(ref Buffer b, int w, int h) nothrow @nogc
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
    immutable size = cast(size_t)(stride) * h;
    immutable fd = memfd_create("wsi-f05", MFD_CLOEXEC);
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

    wl_shm_pool* pool = wsi_shm_create_pool(g_shm, fd, cast(int) size);
    b.handle = wsi_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wsi_shm_pool_destroy(pool);
    close(fd);
    wsi_buffer_add_listener(b.handle, &g_bufferListener, &b);

    b.pixels = cast(uint*) mem;
    b.byteSize = size;
    b.width = w;
    b.height = h;
    b.busy = false;
    instrEvent("buffer_alloc", "size=%dx%d bytes=%zu", w, h, size);
    return true;
}

/// Trivially cheap redraw (two alternating solid colors) — the window's only
/// job here is to keep real frame callbacks interleaving with the fd events.
void paint(ref Buffer b, int frame) nothrow @nogc
{
    immutable uint color = (frame & 1) ? 0xff20_6080 : 0xff80_4020;
    immutable n = cast(size_t) b.width * b.height;
    foreach (i; 0 .. n)
        b.pixels[i] = color;
}

/// Paint into a free buffer and commit it, requesting the next frame callback.
void render() nothrow @nogc
{
    Buffer* buf = null;
    foreach (ref b; g_buffers)
        if (!b.busy)
        {
            buf = &b;
            break;
        }
    if (buf is null)
    {
        instrEvent("frame_skipped", "reason=all_buffers_busy");
        return;
    }
    if (!ensureBuffer(*buf, g_width, g_height))
    {
        g_running = false;
        return;
    }
    paint(*buf, g_frames);
    assert(buf.width == g_width && buf.height == g_height,
        "committed buffer size does not match the acked configure size");

    wsi_surface_attach(g_surface, buf.handle, 0, 0);
    wsi_surface_damage_buffer(g_surface, 0, 0, buf.width, buf.height);
    if (g_frameCb is null) // keep exactly one frame callback in flight
    {
        g_frameCb = wsi_surface_frame(g_surface);
        wsi_callback_add_listener(g_frameCb, &g_frameListener, null);
    }
    wsi_surface_commit(g_surface);
    buf.busy = true;
    g_commits++;
    if (g_commits == 1)
        instrEvent("first_commit", "size=%dx%d", buf.width, buf.height);
}

// ---------------------------------------------------------------- listeners
// All callbacks are `extern (C) nothrow @nogc` to match the listener
// function-pointer types the ImportC `#pragma attribute` stamped in c.c.

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    static uint capped(uint advertised, uint want) nothrow @nogc
    {
        return advertised < want ? advertised : want;
    }

    if (strcmp(iface, wl_compositor_interface.name) == 0)
        g_compositor = cast(wl_compositor*) wsi_registry_bind(reg, name,
            &wl_compositor_interface, capped(ver, 4));
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        g_shm = cast(wl_shm*) wsi_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        g_wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0)
        g_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface,
            capped(ver, 2));
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
}

extern (C) void onWmBasePing(void* data, xdg_wm_base* b, uint serial) nothrow @nogc
{
    wsi_wm_base_pong(b, serial);
}

extern (C) void onSeatCapabilities(void* data, wl_seat* s, uint caps) nothrow @nogc
{
}

extern (C) void onSeatName(void* data, wl_seat* s, const(char)* name) nothrow @nogc
{
}

extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) nothrow @nogc
{
    g_pendingWidth = w;
    g_pendingHeight = h;
}

extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    immutable w = g_pendingWidth > 0 ? g_pendingWidth : defaultWidth;
    immutable h = g_pendingHeight > 0 ? g_pendingHeight : defaultHeight;
    instrEvent("configure", "serial=%u size=%dx%d", serial, w, h);

    wsi_xdg_surface_ack_configure(s, serial);

    immutable resized = w != g_width || h != g_height;
    g_width = w;
    g_height = h;

    if (!g_configured)
    {
        g_configured = true;
        instrFirstConfigure();
        render();
    }
    else if (resized)
    {
        instrResize(w, h, 1);
        render();
    }
}

extern (C) void onToplevelClose(void* data, xdg_toplevel* t) nothrow @nogc
{
    instrCloseRequested();
    g_running = false;
}

extern (C) void onToplevelConfigureBounds(void* data, xdg_toplevel* t, int w, int h) nothrow @nogc
{
}

extern (C) void onToplevelWmCapabilities(void* data, xdg_toplevel* t, wl_array* caps) nothrow @nogc
{
}

extern (C) void onBufferRelease(void* data, wl_buffer* b) nothrow @nogc
{
    auto buf = cast(Buffer*) data;
    buf.busy = false;
    if (g_running && g_configured && g_frameCb is null)
        render();
}

extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) nothrow @nogc
{
    wsi_callback_destroy(cb);
    g_frameCb = null;
    g_frames++;
    // Log every 30th redraw so the fd_tick interleaving stays visible without
    // 60 Hz noise drowning the trace.
    if (g_frames % 30 == 0)
        instrFrameCallback(timeMs);

    if (!g_presented)
    {
        g_presented = true;
        instrFirstPixelPresented();
    }
    render();
}

__gshared wl_registry_listener g_registryListener = {&onGlobal, &onGlobalRemove};
__gshared xdg_wm_base_listener g_wmBaseListener = {&onWmBasePing};
__gshared wl_seat_listener g_seatListener = {&onSeatCapabilities, &onSeatName};
__gshared xdg_surface_listener g_xdgSurfaceListener = {&onXdgSurfaceConfigure};
__gshared xdg_toplevel_listener g_toplevelListener = {
    &onToplevelConfigure, &onToplevelClose,
    &onToplevelConfigureBounds, &onToplevelWmCapabilities
};
__gshared wl_buffer_listener g_bufferListener = {&onBufferRelease};
__gshared wl_callback_listener g_frameListener = {&onFrameDone};

// ------------------------------------------------------------------ stats

extern (C) int cmpLong(const(void)* a, const(void)* b) nothrow @nogc
{
    immutable x = *cast(const(long)*) a;
    immutable y = *cast(const(long)*) b;
    return (x > y) - (x < y);
}

/// min/median/p99/max over the recorded wakeup latencies, to stdout.
void printStats() nothrow @nogc
{
    if (g_latCount == 0)
    {
        printf("stats: no wakeups recorded\n");
        return;
    }
    qsort(g_latencies.ptr, g_latCount, long.sizeof, &cmpLong);
    immutable size_t p99Idx = cast(size_t)(g_latCount - 1) * 99 / 100;
    printf("stats mech=eventfd n=%d min_us=%lld median_us=%lld p99_us=%lld max_us=%lld coalesced=%d\n",
        g_latCount, g_latencies[0], g_latencies[g_latCount / 2],
        g_latencies[p99Idx], g_latencies[g_latCount - 1], g_coalesced);
    printf("stats mech=timerfd ticks=%lld expected_hz=7\n", g_fdTicks);
}

// ----------------------------------------------------------------- teardown

void teardown() nothrow @nogc
{
    foreach (ref b; g_buffers)
        if (b.handle !is null)
        {
            wsi_buffer_destroy(b.handle);
            munmap(b.pixels, b.byteSize);
            b = Buffer.init;
        }
    if (g_frameCb !is null)
        wsi_callback_destroy(g_frameCb);
    if (g_toplevel !is null)
        wsi_toplevel_destroy(g_toplevel);
    if (g_xdgSurface !is null)
        wsi_xdg_surface_destroy(g_xdgSurface);
    if (g_surface !is null)
        wsi_surface_destroy(g_surface);
    if (g_wmBase !is null)
        wsi_wm_base_destroy(g_wmBase);
    if (g_seat !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_seat);
    if (g_shm !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_shm);
    if (g_compositor !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    if (g_registry !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);
    if (g_eventfd >= 0)
        close(g_eventfd);
    if (g_timerfd >= 0)
        close(g_timerfd);
}

// --------------------------------------------------------------------- main

int main()
{
    instrInit("f05-wayland");
    cast(void) getenv("WSI_AUTO_EXIT"); // accepted for runner symmetry; the run is bounded
    if (const n = getenv("WSI_F05_WAKEUPS")) // shorter smoke runs
        if (atoi(n) > 0 && atoi(n) <= maxSamples)
            g_wakeupsWanted = atoi(n);

    // 1. Connect (SKIP cleanly on hosts without a compositor).
    g_display = wl_display_connect(null);
    if (g_display is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }

    // 2. Registry: bind the globals a window needs.
    g_registry = wsi_display_get_registry(g_display);
    wsi_registry_add_listener(g_registry, &g_registryListener, null);
    wl_display_roundtrip(g_display);

    if (g_compositor is null || g_shm is null || g_wmBase is null)
    {
        printf("SKIP: compositor lacks a required global (wl_compositor/wl_shm/xdg_wm_base)\n");
        teardown();
        return 0;
    }
    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    if (g_seat !is null)
        wsi_seat_add_listener(g_seat, &g_seatListener, null);

    // 3. Window object tree (scaffold handshake).
    g_surface = wsi_compositor_create_surface(g_compositor);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f05-loop-wakeup");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f05-loop-wakeup");
    instrWindowCreated();
    wsi_surface_commit(g_surface); // mandatory initial no-buffer commit

    // 4. The two external fds. EFD_NONBLOCK/TFD_NONBLOCK: a spurious-looking
    //    drain must never block the loop.
    g_eventfd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    g_timerfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (g_eventfd < 0 || g_timerfd < 0)
    {
        printf("SKIP: eventfd/timerfd unavailable\n");
        teardown();
        return 0;
    }
    itimerspec its;
    its.it_value.tv_nsec = timerTickNs;
    its.it_interval.tv_nsec = timerTickNs;
    timerfd_settime(g_timerfd, 0, &its, null);
    instrEvent("fd_setup", "eventfd=%d timerfd=%d timer_hz=7", g_eventfd, g_timerfd);

    // 5. The producer thread — raw pthread_create (druntime's POSIX decls):
    //    no GC interaction to rule out, the demo is allocation-free after
    //    startup, and the thread only touches atomics + write(2).
    pthread_t producer;
    if (pthread_create(&producer, null, &producerMain, null) != 0)
    {
        printf("SKIP: pthread_create failed\n");
        teardown();
        return 0;
    }
    instrEvent("producer_started", "hz=%d posts=%d", wakeupHz, g_wakeupsWanted);

    // 6. The multiplexing loop (see pumpOnce). Terminates when every posted
    //    wakeup has been consumed; hard wall-clock cap as a backstop.
    immutable long capUs = (cast(long) g_wakeupsWanted * 1_000_000) / wakeupHz + hardCapSlackUs;
    while (g_running)
    {
        if (!pumpOnce(pollTimeoutMs))
            break;
        if (atomicLoad!(MemoryOrder.acq)(*cast(shared bool*)&g_producerDone)
            && g_ringRead >= atomicLoad!(MemoryOrder.acq)(*cast(shared ulong*)&g_ringWrite))
            g_running = false;
        if (instrNowUs() > capUs)
        {
            instrEvent("hard_cap_hit");
            g_running = false;
        }
    }
    pthread_join(producer, null);

    // 7. Teardown + the numbers.
    teardown();
    printStats();
    printf("ok: %d wakeups consumed, %lld fd_ticks, %d frame callbacks, %d commits\n",
        g_latCount, g_fdTicks, g_frames, g_commits);
    return g_latCount == g_wakeupsWanted ? 0 : 1;
}
