/**
The platform's native backend, chosen by a `BackendPreference` and opened
ready for windows.

Each backend is its own type, so $(LREF openNative) hands the opened one to a
callback rather than returning it: the callback is instantiated once per
backend the platform has. Opening includes what each needs before it can
create a window — X11 and Android attach to the loop; Wayland also waits,
bounded, for its registry and the first round trips.

`automatic` picks Wayland when `$WAYLAND_DISPLAY` is set and the compositor
answers, and X11 otherwise, so a stale `$WAYLAND_DISPLAY` still reaches an X
server. An explicit preference is that backend or an error, never a fallback:
`unavailable` when its display does not answer, `unsupported` when the
platform has no such backend.
*/
module sparkles.wsi.platform.native;

import core.time : Duration, MonoTime, msecs, seconds;

import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.wsi.types;

version (Windows)
    import sparkles.wsi.platform.win32 : Win32Wsi;
else version (OSX)
    import sparkles.wsi.platform.appkit : AppKitWsi;
else version (Android)
    import sparkles.wsi.platform.android : AndroidWsi;
else version (linux)
{
    import sparkles.wsi.platform.wayland : WaylandWsi;
    import sparkles.wsi.platform.x11 : X11Wsi;
}

/**
Opens the native backend `preference` names, ready to create windows on
`loop`, and calls `use(ref backend)` with it; the backend closes when `use`
returns. The error is the open's: `unavailable` when the display does not
answer, `unsupported` when the platform has no such backend. Wayland's
start-up waits at most
`bootstrap`.
*/
WsiResult!void openNative(alias use)(ref DefaultLoop loop, BackendPreference preference,
    in WsiConfig config = WsiConfig.init, Duration bootstrap = 5.seconds)
{
    const automatic = preference == BackendPreference.automatic;
    version (Windows)
    {
        if (!automatic && preference != BackendPreference.win32)
            return refused(preference, BackendKind.win32);
        Win32Wsi wsi;
        auto opened = Win32Wsi.open(wsi, config);
        if (opened.hasError)
            return opened;
        use(wsi);
        return wsiOk();
    }
    else version (OSX)
    {
        if (!automatic && preference != BackendPreference.appkit)
            return refused(preference, BackendKind.appkit);
        AppKitWsi wsi;
        auto opened = AppKitWsi.open(wsi, config);
        if (opened.hasError)
            return opened;
        use(wsi);
        return wsiOk();
    }
    else version (Android)
    {
        if (!automatic && preference != BackendPreference.android)
            return refused(preference, BackendKind.android);
        AndroidWsi wsi;
        auto opened = AndroidWsi.open(wsi, config);
        if (opened.hasError)
            return opened;
        auto attached = wsi.attach(loop);
        if (attached.hasError)
            return attached;
        use(wsi);
        return wsiOk();
    }
    else version (linux)
    {
        import core.stdc.stdlib : getenv;

        if (!automatic && preference != BackendPreference.wayland
            && preference != BackendPreference.x11)
            return refused(preference, BackendKind.x11);
        auto waylandFailed = wsiOk();
        if (preference == BackendPreference.wayland
            || (automatic && getenv("WAYLAND_DISPLAY") !is null))
        {
            WaylandWsi wsi;
            auto opened = openWayland(wsi, loop, config, bootstrap);
            if (!opened.hasError)
            {
                use(wsi);
                return wsiOk();
            }
            if (!automatic)
                return opened;
            // A compositor that does not answer: X11 may still be live.
            waylandFailed = opened;
        }
        X11Wsi wsi;
        auto opened = X11Wsi.open(wsi, config);
        // With no X server advertised either, the compositor's failure is
        // the one that says what went wrong.
        if (opened.hasError)
            return waylandFailed.hasError && getenv("DISPLAY") is null ? waylandFailed : opened;
        auto attached = wsi.attach(loop);
        if (attached.hasError)
            return attached;
        use(wsi);
        return wsiOk();
    }
    else
        return refused(preference, BackendKind.x11);
}

/**
One turn of `loop` for `wsi`: an integrated backend (Wayland, X11, Android)
runs its own turn, a hosted one (Win32, AppKit) is run by the loop. Waits at
most `timeout`.
*/
auto tickNative(Backend)(ref Backend wsi, ref DefaultLoop loop, Duration timeout)
{
    static if (is(typeof(wsi.runIntegratedOnce(loop, timeout))))
        return wsi.runIntegratedOnce(loop, timeout);
    else
        return loop.runHostedOnce(wsi, timeout);
}

/// Which backend the type `Backend` is.
template backendKindOf(Backend)
{
    version (Windows)
        enum backendKindOf = BackendKind.win32;
    else version (OSX)
        enum backendKindOf = BackendKind.appkit;
    else version (Android)
        enum backendKindOf = BackendKind.android;
    else version (linux)
    {
        static if (is(Backend == WaylandWsi))
            enum backendKindOf = BackendKind.wayland;
        else static if (is(Backend == X11Wsi))
            enum backendKindOf = BackendKind.x11;
        else
            static assert(false, Backend.stringof ~ " is not a native backend");
    }
    else
        static assert(false, "no native backend on this platform");
}

version (Android) {} else version (linux)
{
    // Open, then wait for the registry and the first round trips: a window
    // asked for earlier would miss globals the compositor has not listed.
    private WsiResult!void openWayland(out WaylandWsi wsi, ref DefaultLoop loop,
        in WsiConfig config, Duration bootstrap)
    {
        auto opened = WaylandWsi.open(wsi, loop, config);
        if (opened.hasError)
            return opened;
        const deadline = MonoTime.currTime + bootstrap;
        while (!wsi.bootstrapComplete && MonoTime.currTime < deadline)
            if (wsi.runIntegratedOnce(loop, 100.msecs).hasError)
                break;
        if (!wsi.bootstrapComplete)
            return wsiErr!void(wsiError(WsiErrorKind.unavailable, WsiOperation.open,
                BackendKind.wayland, diagnostic: "the compositor did not finish the Wayland start-up"));
        if (!wsi.canCreateWindows)
            return wsiErr!void(wsiError(WsiErrorKind.unavailable, WsiOperation.open,
                BackendKind.wayland, diagnostic: "the compositor offers no xdg-shell toplevels"));
        return wsiOk();
    }
}

// A backend this platform does not have: `unsupported`, not `unavailable` —
// asking for it is the caller's mistake, not a missing display — naming the
// backend asked for.
private WsiResult!void refused(BackendPreference preference, BackendKind here) @safe pure nothrow @nogc
{
    const(char)[] what;
    BackendKind asked = here;
    final switch (preference)
    {
        case BackendPreference.automatic: what = "no native backend on this platform"; break;
        case BackendPreference.wayland:
            what = "Wayland is not a backend on this platform";
            asked = BackendKind.wayland;
            break;
        case BackendPreference.x11:
            what = "X11 is not a backend on this platform";
            asked = BackendKind.x11;
            break;
        case BackendPreference.win32:
            what = "Win32 is not a backend on this platform";
            asked = BackendKind.win32;
            break;
        case BackendPreference.appkit:
            what = "AppKit is not a backend on this platform";
            asked = BackendKind.appkit;
            break;
        case BackendPreference.android:
            what = "Android is not a backend on this platform";
            asked = BackendKind.android;
            break;
    }
    return wsiErr!void(wsiError(WsiErrorKind.unsupported, WsiOperation.open, asked,
        diagnostic: what));
}

@("wsi.platform.native.refusesABackendThePlatformLacks")
@system unittest
{
    import sparkles.event_horizon.loop : LoopConfig;

    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);
    version (OSX)
        enum foreign = BackendPreference.x11;
    else
        enum foreign = BackendPreference.appkit;
    bool used;
    const opened = openNative!((ref wsi) { used = true; })(loop, foreign);
    assert(opened.hasError && opened.error.kind == WsiErrorKind.unsupported,
        "a backend the platform lacks is asked for in error, not missing");
    version (OSX)
        assert(opened.error.backend == BackendKind.x11);
    else
        assert(opened.error.backend == BackendKind.appkit, "the error names the backend asked for");
    assert(!used, "nothing opens for a backend the platform lacks");
}
