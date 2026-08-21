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
import core.time : Duration, MonoTime, seconds;
import std.stdio : writeln;

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
        wsi.runIntegratedOnce(*loop, timeout).value;
    }

    void onWindowReady(WindowId ready)
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
        assert(!wsi.beginNativeIo().hasError);
        assert(attachShmBuffer(display, surface, 480, 320));
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
    auto hooks = WaylandHooks(&wsi, &loop,
        chordEnabled: externalInjection,
        pointerEnabled: externalInjection && kiosk,
        resizeEnabled: !kiosk,
        readySizeExact: !kiosk);
    const outcome = checkWsiConformance(wsi, loop, hooks,
        "sparkles:wsi Wayland conformance");
    writeln("ok: Wayland WSI conformance (", outcome.checked, " checked, ",
        outcome.skipped, " skipped)");
    return 0;
}
