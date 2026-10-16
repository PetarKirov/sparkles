/**
Wayland driver for the shared WSI conformance suite.

Every behavior assertion lives in `sparkles.wsi.conformance`; this driver
supplies what Wayland alone can: the integrated prepare-read step, a
maximize request as the compositor-driven resize (the compositor picks the
size, so the property checks change, not dimensions), and the keyboard
chord lane. Key injection is external — `scripts/verify-wayland-keys.sh`
chords through Xvfb into Weston's X11 backend — so the chord property is
gated on `$WSI_CONFORMANCE_KEYS`, and the driver then maps a throwaway shm
buffer under the native-I/O borrow, because compositors only grant keyboard
focus to mapped surfaces. `scripts/verify-wayland-weston.sh` runs the
chord-free lane against headless Weston.
*/
module wayland_hosted_smoke;

version (linux):

import core.stdc.stdlib : getenv;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : text;
import std.stdio : writeln;
import std.sumtype : match;

import core.stdc.string : strcmp;
import core.sys.posix.stdlib : mkstemp;
import core.sys.posix.unistd : ftruncate, posixClose = close, unlink;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.wsi;
import wayland_native;

private struct ShmProbe
{
    wl_shm* shm;
}

private extern (C) void onShmGlobal(void* data, wl_registry* registry,
    uint name, const(char)* interfaceName, uint version_) nothrow @nogc
{
    auto probe = cast(ShmProbe*) data;
    if (strcmp(interfaceName, wl_shm_interface.name) == 0
        && probe.shm is null)
        probe.shm = cast(wl_shm*) wl_registry_bind(registry, name,
            &wl_shm_interface, 1);
}

private extern (C) void onShmGlobalRemove(void*, wl_registry*,
    uint) nothrow @nogc
{
}

// ImportC drops the C const from the add_listener parameter; the protocol
// never writes through a listener table.
private immutable wl_registry_listener shmRegistryListener = {
    &onShmGlobal, &onShmGlobalRemove
};

/*
Attach a throwaway shm buffer so the surface actually maps — compositors
only grant keyboard focus to mapped surfaces. Runs its own registry round
trips on the shared display, so the caller must hold the WSI native-I/O
borrow, exactly as a renderer would.
*/
private bool attachShmBuffer(wl_display* display, wl_surface* surface,
    int width, int height)
{
    ShmProbe probe;
    auto registry = wl_display_get_registry(display);
    if (registry is null)
        return false;
    scope (exit) wl_proxy_destroy(cast(wl_proxy*) registry);
    if (wl_registry_add_listener(registry,
            cast(wl_registry_listener*) &shmRegistryListener, &probe) != 0
        || wl_display_roundtrip(display) < 0 || probe.shm is null)
        return false;
    scope (exit) wl_proxy_destroy(cast(wl_proxy*) probe.shm);

    char[25] path = "/tmp/wsi-test-shm-XXXXXX\0";
    const fd = mkstemp(path.ptr);
    if (fd < 0)
        return false;
    scope (exit) posixClose(fd);
    unlink(path.ptr);
    const stride = width * 4;
    const size = stride * height;
    if (ftruncate(fd, size) != 0)
        return false;
    auto pool = wl_shm_create_pool(probe.shm, fd, size);
    if (pool is null)
        return false;
    scope (exit) wl_shm_pool_destroy(pool);
    auto buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride,
        WL_SHM_FORMAT_XRGB8888);
    if (buffer is null)
        return false;
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    return wl_display_roundtrip(display) >= 0;
}

private struct WaylandHooks
{
    WaylandWsi* wsi;
    DefaultLoop* loop;
    WindowId id;
    bool chordEnabled;
    bool pointerEnabled;
    bool resizeEnabled = true;
    bool readySizeExact = true;
    double expectedScale = 0;

    enum uint chordShiftCode = 42; // evdev KEY_LEFTSHIFT
    enum uint chordKeyCode = 30; // evdev KEY_A
    // Layout-derived unshifted spelling the chorded key must carry.
    enum dchar chordKeyCharacter = 'a';
    enum bool expectFocusEvent = true;
    enum bool resizeExact = false;
    enum bool expectPointerMotion = true;
    enum chordDeadline = 20.seconds;

    void step(Duration timeout)
    {
        // timedOut is a legitimate quiet outcome while waiting on the
        // external injector; the conformance deadline is the failure.
        auto ran = wsi.runIntegratedOnce(*loop, timeout);
        assert(!ran.hasError, text("the integrated step failed: ", ran.error.context,
            " (", ran.error.op, "/", ran.error.stage, ", code ", ran.error.code, ")"));
    }

    void onWindowReady(WindowId ready, in SurfaceMetrics metrics)
    {
        id = ready;
        if (!chordEnabled)
            return;
        auto handles = wsi.nativeHandles(id).value;
        auto display = handles.display.match!(
            (in WaylandDisplayHandle handle) => cast(wl_display*) handle.display,
            (_) => null);
        auto surface = handles.window.match!(
            (in WaylandWindowHandle handle) => cast(wl_surface*) handle.surface,
            (_) => null);
        assert(display !is null && surface !is null);
        // The buffer matches the compositor-imposed size (the kiosk shell
        // fullscreens the surface), so the mapped commit is protocol-clean.
        assert(!wsi.beginNativeIo().hasError);
        assert(attachShmBuffer(display, surface,
            metrics.physicalSize.width, metrics.physicalSize.height));
        assert(!wsi.endNativeIo().hasError);
    }

    void checkHandles(in NativeHandles handles)
    {
        assert(handles.display.match!(
            (in WaylandDisplayHandle handle) => handle.display !is null,
            (_) => false));
        assert(handles.window.match!(
            (in WaylandWindowHandle handle) => handle.surface !is null,
            (_) => false));
    }

    void requestResize(uint, uint)
    {
        assert(!wsi.setMaximized(id, true).hasError);
    }

    void injectChord()
    {
        // External: the verify script's XTEST injector chords repeatedly
        // through Weston until the property observes it.
    }

    enum uint holdKeyCode = chordKeyCode;

    /*
    The hold lifecycle is signal-file choreography with the external
    injector: `holdKey` raises the hold gate (the injector presses and
    keeps the key down, skipping its chord replays meanwhile), and
    `releaseHold` raises the release gate once the property has observed
    a synthesized repeat. Weston filters the X server's own auto-repeat,
    so every repeat seen here is this client's repeat_info synthesis.
    */
    void holdKey()
    {
        signalFile("WSI_HOLD_GO");
    }

    void releaseHold()
    {
        signalFile("WSI_HOLD_RELEASE_GO");
    }

    private void signalFile(scope const(char)* name)
    {
        import core.stdc.stdlib : getenv;
        import std.string : fromStringz;
        import std.file : write;

        auto path = getenv(name);
        if (path !is null)
            write(path.fromStringz, "go");
    }

    /*
    The external injector clicks and scrolls at the output's center, but
    only once this signal file exists: Weston's click-to-activate binding
    crashes on a click over the bare desktop (its background helper never
    maps here), and by the time this property runs the resize property has
    maximized the surface across the output, so the center is ours.
    */
    void injectClick()
    {
        import core.stdc.stdlib : getenv;
        import std.string : fromStringz;
        import std.file : write;

        auto path = getenv("WSI_POINTER_GO");
        if (path !is null)
            write(path.fromStringz, "go");
    }

    void injectScroll()
    {
        injectClick();
    }

    /*
    The injector's pointer leg warps Weston's X11 window between two
    points, which Weston turns into relative deltas for the focused
    surface; only a relative-pointer object receives them. No
    `injectMotionOutside`: a fullscreen kiosk surface has no outside, so
    the capture and confinement properties skip here.
    */
    void injectRelativeMotion()
    {
        injectClick();
    }
}

int main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);

    WaylandWsi wsi;
    auto opened = WaylandWsi.open(wsi, loop);
    if (opened.hasError && opened.error.kind == WsiErrorKind.unavailable)
    {
        writeln("SKIP: no Wayland compositor");
        return 0;
    }
    assert(!opened.hasError);

    const bootstrapStart = MonoTime.currTime;
    while (!wsi.bootstrapComplete)
    {
        assert(wsi.runIntegratedOnce(loop, 2.seconds).value
            == RunStatus.dispatched);
        assert(MonoTime.currTime - bootstrapStart < 2.seconds);
    }
    assert(wsi.canCreateWindows);

    // The injection lane runs under Weston's kiosk shell: the compositor
    // owns the initial (fullscreen) size and a maximize request changes
    // nothing, so those two properties adapt; in exchange every click and
    // scroll lands on our surface, and this Weston's desktop-shell
    // click-to-activate binding — which crashes in this headless
    // environment — is never registered.
    const externalInjection = getenv("WSI_CONFORMANCE_KEYS") !is null;
    const kiosk = getenv("WSI_CONFORMANCE_KIOSK") !is null;
    const scaleText = getenv("WSI_EXPECT_SCALE");
    import core.stdc.stdlib : atof;

    auto hooks = WaylandHooks(&wsi, &loop,
        chordEnabled: externalInjection,
        pointerEnabled: externalInjection && kiosk,
        resizeEnabled: !kiosk,
        readySizeExact: !kiosk,
        expectedScale: scaleText !is null ? atof(scaleText) : 0);
    const outcome = checkWsiConformance(wsi, loop, hooks,
        "sparkles:wsi Wayland conformance");
    writeln("ok: Wayland WSI conformance (", outcome.checked, " checked, ",
        outcome.skipped, " skipped)");

    /*
    Kiosk addendum: confinement has no conformance evidence under a
    fullscreen surface (there is no outside to aim at), so prove what the
    compositor can still tell us — it accepts the constraint and its
    release without a protocol error (one would poison the connection and
    surface on the next command), and explicit capture is refused with the
    typed kind rather than pretended.
    */
    if (hooks.pointerEnabled)
    {
        // The conformance window is gone; this addendum needs a live one.
        WindowConfig config;
        assert(config.title.assign("sparkles:wsi Wayland confine"));
        const id = wsi.createWindow(config).value;
        bool ready;
        const deadline = MonoTime.currTime + 5.seconds;
        while (!ready)
        {
            assert(MonoTime.currTime < deadline,
                "no ReadyEvent for the confine window");
            hooks.step(200.msecs);
            SurfaceMetrics readyMetrics;
            assert(!wsi.drain((WindowEvent event) {
                if (event.window == id)
                    event.payload.match!(
                        (in ReadyEvent value) {
                            ready = true;
                            readyMetrics = value.metrics;
                        },
                        (_) {});
            }).hasError);
            if (ready)
                hooks.onWindowReady(id, readyMetrics);
        }
        // Weston 16 dies when a constraint is requested for a surface the
        // pointer is not over ("pointer focus doesn't match", then
        // SIGSEGV), so wait until the injector's next warp gives the new
        // window pointer focus.
        bool entered;
        const focusDeadline = MonoTime.currTime + 5.seconds;
        while (!entered)
        {
            assert(MonoTime.currTime < focusDeadline,
                "the confine window never gained pointer focus");
            hooks.step(100.msecs);
            assert(!wsi.drain((WindowEvent event) {
                if (event.window == id)
                    event.payload.match!(
                        (in PointerEvent value) {
                            entered |= value.phase == PointerPhase.entered;
                        },
                        (_) {});
            }).hasError);
        }
        const confined = wsi.setPointerCapture(id, PointerCaptureMode.confine);
        if (confined.hasError)
            writeln("confine failed: ", confined.error.kind, " ",
                confined.error.diagnostic[]);
        assert(!confined.hasError);
        hooks.step(200.msecs);
        assert(!wsi.setPointerCapture(id, PointerCaptureMode.none).hasError);
        hooks.step(200.msecs);
        assert(!wsi.setCursorVisible(id, true).hasError,
            "the compositor rejected the pointer constraint");
        const captured = wsi.setPointerCapture(id, PointerCaptureMode.capture);
        assert(captured.hasError
            && captured.error.kind == WsiErrorKind.unsupported);
        assert(!wsi.destroyWindow(id).hasError);
        writeln("ok: Wayland pointer confinement accepted and released");
    }

    /*
    Clipboard addendum (`DT1`–`DT5`): only where a keyboard gives this client
    focus, since the compositor sends the selection to the focused client and
    setting it takes an input serial. The shared suite round-trips 32 MiB
    through the compositor: this client's `wl_data_source` writes a pipe and
    its own `wl_data_offer` reads it. Then a second client (another
    `WaylandWsi`, on its own connection) takes focus, offers text and hands
    focus back; its offer arrives as a foreign one and reads back intact.
    */
    if (externalInjection && wsi.clipboardAvailable)
    {
        WindowConfig config;
        assert(config.title.assign("sparkles:wsi Wayland clipboard"));
        const id = wsi.createWindow(config).value;
        awaitFocus(wsi, hooks, id, "the clipboard window never gained keyboard focus");

        WaylandWsi other;
        static struct ClipboardHooks
        {
            WaylandWsi* wsi;
            WaylandWsi* other;
            DefaultLoop* loop;
            ulong transferBytes = 32UL << 20; // `DT5`
            enum size_t maxChunkBytes = WaylandWsi.clipChunkBytes;

            void step(Duration timeout)
            {
                auto ran = wsi.runIntegratedOnce(*loop, timeout);
                assert(!ran.hasError, "the integrated step failed");
                // The other client shares the loop; its completions are
                // serviced by its own step.
                if (other.bootstrapComplete)
                    assert(!other.runIntegratedOnce(*loop, Duration.zero).hasError);
            }
        }
        auto clipHooks = ClipboardHooks(&wsi, &other, &loop);
        const before = residentKiB();
        const started = MonoTime.currTime;
        const clip = checkClipboardConformance(wsi, loop, clipHooks, id);
        const grew = residentKiB() - before;
        assert(grew < 4 * 1024, text("resident memory grew by ", grew,
            " KiB across a 32 MiB round trip"));
        writeln("ok: Wayland clipboard conformance (", clip.checked,
            " checked, 32 MiB through the compositor in ",
            (MonoTime.currTime - started).total!"msecs", " ms, resident +", grew, " KiB)");

        static immutable string theirs = "copied in another client: ünïcode";
        assert(!WaylandWsi.open(other, loop).hasError, "the second client did not connect");
        const bootstrapDeadline = MonoTime.currTime + 5.seconds;
        while (!other.bootstrapComplete)
        {
            assert(MonoTime.currTime < bootstrapDeadline, "the second client never bootstrapped");
            assert(!other.runIntegratedOnce(loop, 100.msecs).hasError);
        }
        WindowConfig otherConfig;
        assert(otherConfig.title.assign("sparkles:wsi Wayland other client"));
        const otherWindow = other.createWindow(otherConfig).value;
        // Its own hooks map a buffer when the window is ready: the
        // compositor focuses a window only once it is mapped.
        auto otherHooks = WaylandHooks(&other, &loop, chordEnabled: true,
            pointerEnabled: false, resizeEnabled: false, readySizeExact: false);
        awaitFocus(other, otherHooks, otherWindow,
            "the second client's window never gained keyboard focus");
        assert(!other.offerClipboard(otherWindow, "text/plain;charset=utf-8",
            cast(const(ubyte)[]) theirs).hasError);
        clipHooks.step(100.msecs);
        assert(!other.drain((WindowEvent event) {}).hasError);
        // Focus returns to this client, and the selection with it.
        assert(!other.destroyWindow(otherWindow).hasError);

        OfferId offer;
        const deadline = MonoTime.currTime + 10.seconds;
        while (offer == OfferId.init)
        {
            assert(MonoTime.currTime < deadline, "the other client's offer was never announced");
            clipHooks.step(50.msecs);
            assert(!other.drain((WindowEvent event) {}).hasError);
            assert(!wsi.drain((WindowEvent event) {
                event.payload.match!(
                    (in DataOfferEvent e) {
                        if (e.action != DataOfferAction.offered)
                            return;
                        assert(!wsi.withText(e.mimeType, (scope const(char)[] mime) {
                            if (mime == "text/plain;charset=utf-8")
                                offer = e.offer;
                        }).hasError);
                    },
                    (_) {});
            }).hasError);
        }
        static struct Collect
        {
            char[128] text;
            size_t length;
            bool done, ok;

            void chunk(TransferId, scope const(ubyte)[] bytes) @safe nothrow
            {
                text[length .. length + bytes.length] = cast(const(char)[]) bytes;
                length += bytes.length;
            }

            void finish(TransferId, TransferStatus status) @safe nothrow
            {
                done = true;
                ok = status == TransferStatus.completed;
            }
        }
        Collect paste;
        assert(!wsi.receive(offer, "text/plain;charset=utf-8", paste).hasError);
        while (!paste.done)
        {
            assert(MonoTime.currTime < deadline + 5.seconds, "the paste never finished");
            clipHooks.step(50.msecs);
        }
        assert(paste.ok && paste.text[0 .. paste.length] == theirs,
            "the other client's text did not arrive intact");
        assert(!other.close().hasError);
        assert(!wsi.destroyWindow(id).hasError);
        writeln("ok: Wayland reads another client's clipboard");
    }
    return 0;
}

/// Steps until `id` reports keyboard focus, after it became ready.
private void awaitFocus(Hooks)(ref WaylandWsi wsi, ref Hooks hooks, WindowId id,
    string failure)
{
    bool ready, focused;
    const deadline = MonoTime.currTime + 10.seconds;
    while (!ready || !focused)
    {
        assert(MonoTime.currTime < deadline, failure);
        hooks.step(100.msecs);
        SurfaceMetrics metrics;
        assert(!wsi.drain((WindowEvent event) {
            if (event.window != id)
                return;
            event.payload.match!(
                (in ReadyEvent e) { ready = true; metrics = e.metrics; },
                (in FocusChangedEvent e) { focused = e.focused; },
                (_) {});
        }).hasError);
        static if (is(typeof(hooks.onWindowReady(id, metrics))))
            if (ready && metrics != SurfaceMetrics.init)
                hooks.onWindowReady(id, metrics);
    }
}

/// This process' resident set, from `/proc/self/statm`, in KiB.
private long residentKiB()
{
    import std.file : readText;
    import std.string : split;
    import std.conv : to;
    import core.sys.posix.unistd : sysconf, _SC_PAGESIZE;

    const pages = readText("/proc/self/statm").split[1].to!long;
    return pages * sysconf(_SC_PAGESIZE) / 1024;
}
