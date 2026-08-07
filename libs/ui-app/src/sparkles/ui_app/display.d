/**
Is there a display, really? The impure half of the backend decision (`BKD3`).

$(MREF sparkles,ui_app,backend) decides which sink to open as a pure function;
this module answers the one question it cannot, and is deliberately kept apart
from it so the decision stays a table of unit tests.

$(B Two layers, because the environment lies.) Reading `$DISPLAY` says what the
session $(I advertises); connecting to the socket says whether that is still
true. The gap between them is not hypothetical — a `su` into another user, a
container that inherited the variable, a service session, a detached tmux from a
logged-out session — and in every one of those a window would fail to open after
the application had already committed to trying.

$(B What is deliberately NOT probed:) a remote X11 display (`host:0`, what
`ssh -X` sets up). Reaching it means a TCP connect with no useful bound — an
unreachable host costs the operating system's connect timeout, minutes of it,
$(I before the application decides anything). A startup path cannot spend that,
so a remote display is taken at its word: `$DISPLAY` said so, and the failure
mode of believing it is a clear error at window creation rather than a hang.
*/
module sparkles.ui_app.display;

import std.process : environment;

@safe:

/// Which display system answered.
enum DisplaySystem : ubyte
{
    none,           /// nothing reachable — headless
    x11,            ///
    wayland,        ///
    quartz,         /// macOS Aqua session
    win32,          /// an interactive Windows window station
    androidSurface, /// the NativeActivity surface, which IS the application
}

/// What a probe found.
struct DisplayProbe
{
    DisplaySystem system;

    /**
    The display was confirmed by $(B reaching) it, not merely inferred from the
    environment.

    Worth reporting rather than collapsing into `present`: an inferred display
    is a guess that a stale variable can make wrong, and a diagnostic that says
    which one it was turns "the window did not open" into a one-line answer.
    */
    bool probed;

    /// Whether a window can be expected to open.
    bool present() const pure nothrow @nogc => system != DisplaySystem.none;
}

/**
Probes for a usable display.

Params:
    liveness = attempt to reach the display server, not just read the
        environment. The cost is one local socket `connect` (or one framework
        call); pass `false` on a path that cannot afford even that.
*/
DisplayProbe probeDisplay(bool liveness = true)
{
    version (Android)
    {
        // The surface IS the application (`BKD4`); there is nothing to probe
        // and no environment to read.
        return DisplayProbe(DisplaySystem.androidSurface, probed: true);
    }
    else version (OSX)
        return probeQuartz(liveness);
    else version (Windows)
        return probeWin32();
    else version (Posix)
        return probePosix(liveness);
    else
        return DisplayProbe.init;
}

/// Whether a graphical display appears to exist — the answer
/// $(REF BackendPolicy.displayPresent, sparkles,ui_app,backend) wants.
///
/// A false negative costs only a fallback to the terminal, and `--gui`
/// overrides the whole question, so this is allowed to be a heuristic.
bool displayAvailable() => probeDisplay().present;

// ---------------------------------------------------------------------------
// X11 display strings — the parsing half, which is pure and therefore testable
// ---------------------------------------------------------------------------

/// A parsed `$DISPLAY`.
struct X11Display
{
    /// Empty or `unix` means a local socket. Borrowed from the string parsed,
    /// which is the caller's to keep alive — every caller here passes an
    /// environment string that outlives the decision.
    const(char)[] host;
    uint number;        /// the display number, before any `.screen` suffix
    bool valid;         ///

    /// Whether this names a socket on this machine rather than a TCP peer.
    bool isLocal() const pure nothrow @nogc
        => host.length == 0 || host == "unix";
}

/**
Parses `$DISPLAY`: `[host]:number[.screen]`, or `[host]/transport:number`.

An empty or `unix` host is the local socket; anything else is a TCP peer, which
is what `ssh -X` sets up — so a remote-looking display is emphatically not a
dead one.
*/
X11Display parseX11Display(const(char)[] display) pure nothrow @nogc
{
    X11Display r;
    if (display.length == 0)
        return r;

    // The LAST colon: an IPv6 literal contains several, and the display number
    // always follows the final one.
    ptrdiff_t colon = -1;
    foreach_reverse (i, c; display)
        if (c == ':')
        {
            colon = i;
            break;
        }
    if (colon < 0)
        return r;

    auto host = display[0 .. colon];
    auto rest = display[colon + 1 .. $];

    // Drop the `.screen` suffix; which screen is not this question.
    foreach (i, c; rest)
        if (c == '.')
        {
            rest = rest[0 .. i];
            break;
        }

    if (rest.length == 0)
        return r;
    uint number;
    foreach (c; rest)
    {
        if (c < '0' || c > '9')
            return r;
        number = number * 10 + (c - '0');
    }

    // A `host/transport` prefix (`host/unix:0`) names the transport, and the
    // part after the slash is what decides local versus remote.
    foreach_reverse (i, c; host)
        if (c == '/')
        {
            host = host[i + 1 .. $];
            break;
        }

    r.host = host;
    r.number = number;
    r.valid = true;
    return r;
}

// ---------------------------------------------------------------------------
// Platform probes
// ---------------------------------------------------------------------------

version (Android) {} else version (Posix)
{
    private DisplayProbe probePosix(bool liveness)
    {
        import std.path : buildPath, isAbsolute;

        // Wayland wins where both are advertised: XWayland also exports
        // `$DISPLAY`, so a Wayland session that answered X11 first would
        // report the wrong system for no benefit.
        const wayland = environment.get("WAYLAND_DISPLAY", "");
        if (wayland.length)
        {
            const path = wayland.isAbsolute
                ? wayland
                : buildPath(environment.get("XDG_RUNTIME_DIR", ""), wayland);

            if (!liveness)
                return DisplayProbe(DisplaySystem.wayland);
            if (path.length && canConnectUnix(path))
                return DisplayProbe(DisplaySystem.wayland, probed: true);
            // A stale `WAYLAND_DISPLAY`; X11 may still be live, so fall through
            // rather than reporting the session headless.
        }

        const display = environment.get("DISPLAY", "");
        if (display.length)
        {
            const d = parseX11Display(display);
            if (d.valid)
            {
                if (!liveness || !d.isLocal)
                    // A remote display is believed, not dialled — see the
                    // module note on why a TCP probe is not affordable here.
                    return DisplayProbe(DisplaySystem.x11);
                if (canConnectX11(d.number))
                    return DisplayProbe(DisplaySystem.x11, probed: true);
            }
        }

        // Last resort: what logind says the session is. Useful inside sandboxes
        // that scrub `$DISPLAY` but still reach a portal.
        switch (environment.get("XDG_SESSION_TYPE", ""))
        {
            case "wayland": return DisplayProbe(DisplaySystem.wayland);
            case "x11":     return DisplayProbe(DisplaySystem.x11);
            default:        return DisplayProbe.init;
        }
    }

    /// Whether X display `number` answers on this machine.
    private bool canConnectX11(uint number)
    {
        import std.conv : text;

        const path = text("/tmp/.X11-unix/X", number);
        version (linux)
        {
            // The abstract-namespace socket modern servers bind, tried first
            // because a filesystem socket may be hidden by a mount namespace
            // while the abstract one is still reachable. A leading NUL selects
            // that namespace.
            if (canConnectUnix("\0" ~ path))
                return true;
        }
        return canConnectUnix(path);
    }

    /**
    Whether a `connect` to the AF_UNIX socket at `path` succeeds.

    A leading NUL selects Linux's abstract namespace, where the address length
    — not a terminator — delimits the name, which is why the length is computed
    explicitly rather than left to `strlen`.
    */
    private bool canConnectUnix(scope const(char)[] path) @trusted
    {
        import core.stdc.string : memcpy;
        import core.sys.posix.sys.socket : AF_UNIX, connect, SOCK_STREAM,
            sockaddr, socket, socklen_t;
        import core.sys.posix.sys.un : sockaddr_un;
        import core.sys.posix.unistd : close;

        sockaddr_un addr;
        if (path.length == 0 || path.length > addr.sun_path.sizeof)
            return false;

        const fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0)
            return false;
        scope (exit) close(fd);

        addr.sun_family = AF_UNIX;
        memcpy(addr.sun_path.ptr, path.ptr, path.length);

        const len = cast(socklen_t)(addr.sun_family.offsetof
            + addr.sun_family.sizeof + path.length);
        return connect(fd, cast(sockaddr*) &addr, len) == 0;
    }
}

version (OSX)
{
    /**
    Asks the WindowServer whether this process has a graphical session.

    `CGSessionCopyCurrentDictionary` returns null when it does not — an SSH
    login, a `launchd` daemon in the system context, a session without Aqua —
    which is exactly the question, so here the probe is the primary signal
    rather than a confirmation of the environment.

    Resolved with `dlopen` so a terminal-only build does not link
    ApplicationServices to ask.
    */
    private DisplayProbe probeQuartz(bool liveness) @trusted
    {
        import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_LAZY,
            RTLD_LOCAL;

        if (!liveness)
        {
            // Without the probe there is nothing better than the old guess: a
            // login session that is not SSH is almost always Aqua.
            const remote = environment.get("SSH_CONNECTION", "").length != 0;
            return remote ? DisplayProbe.init : DisplayProbe(DisplaySystem.quartz);
        }

        enum framework = "/System/Library/Frameworks/ApplicationServices"
            ~ ".framework/ApplicationServices\0";

        void* handle = dlopen(framework.ptr, RTLD_LAZY | RTLD_LOCAL);
        if (handle is null)
            return DisplayProbe.init;
        scope (exit) dlclose(handle);

        alias CopyDictFn = extern (C) void* function() nothrow @nogc;
        alias ReleaseFn = extern (C) void function(void*) nothrow @nogc;

        auto copyDict = cast(CopyDictFn) dlsym(handle, "CGSessionCopyCurrentDictionary");
        if (copyDict is null)
            return DisplayProbe.init;

        void* dict = copyDict();
        if (dict is null)
            return DisplayProbe.init; // no graphical session

        // `Copy` in the name means this reference is ours to release.
        if (auto release = cast(ReleaseFn) dlsym(handle, "CFRelease"))
            release(dict);

        return DisplayProbe(DisplaySystem.quartz, probed: true);
    }
}

version (Windows)
{
    import core.sys.windows.windef : BOOL, DWORD, HANDLE;

    private
    {
        alias HWINSTA = HANDLE;
        enum UOI_FLAGS = 1;
        enum WSF_VISIBLE = 0x0001;

        struct USEROBJECTFLAGS
        {
            BOOL fInherit;
            BOOL fReserved;
            DWORD dwFlags;
        }

        extern (Windows) nothrow @nogc
        {
            HWINSTA GetProcessWindowStation();
            BOOL GetUserObjectInformationW(HANDLE, int, void*, DWORD, DWORD*);
        }
    }

    /**
    Whether this process sits on an interactive window station.

    A process can only create windows if its station is `WSF_VISIBLE`. Services
    in session 0, scheduled tasks configured to run without a logged-on user,
    and shells spawned by the Windows OpenSSH server all get a non-interactive
    station — and all of them would pass a "not an SSH session" check while
    being quite unable to open a window.

    Declared locally rather than imported so this compiles against any druntime
    version, regardless of what `core.sys.windows.winuser` exposes.
    */
    private DisplayProbe probeWin32() @trusted
    {
        HWINSTA station = GetProcessWindowStation();
        if (station is null)
            return DisplayProbe.init;

        USEROBJECTFLAGS flags;
        DWORD needed;
        if (!GetUserObjectInformationW(station, UOI_FLAGS, &flags,
                USEROBJECTFLAGS.sizeof, &needed))
            return DisplayProbe.init;

        return (flags.dwFlags & WSF_VISIBLE)
            ? DisplayProbe(DisplaySystem.win32, probed: true)
            : DisplayProbe.init;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui_app.display.parseX11Display")
@safe pure nothrow @nogc
unittest
{
    // The ordinary local forms.
    const local = parseX11Display(":0");
    assert(local.valid && local.isLocal && local.number == 0);
    assert(parseX11Display(":12").number == 12);

    // A screen suffix is not part of the question.
    const screen = parseX11Display(":0.1");
    assert(screen.valid && screen.number == 0 && screen.isLocal);

    // An explicit `unix` host, and the `host/transport` form, are both local.
    assert(parseX11Display("unix:0").isLocal);
    assert(parseX11Display("myhost/unix:0").isLocal);

    // A real host is remote — this is what `ssh -X` sets up, and it is live,
    // not dead.
    const remote = parseX11Display("192.168.1.5:0");
    assert(remote.valid && !remote.isLocal && remote.host == "192.168.1.5");

    // An IPv6 literal contains colons of its own; the number follows the LAST.
    const v6 = parseX11Display("::1:0");
    assert(v6.valid && v6.number == 0 && !v6.isLocal);

    // Malformed input is rejected rather than guessed at.
    assert(!parseX11Display("").valid);
    assert(!parseX11Display("nocolon").valid);
    assert(!parseX11Display(":").valid);
    assert(!parseX11Display(":abc").valid);
    assert(!parseX11Display(":1x").valid);
}

@("ui_app.display.probeIsSelfConsistent")
@safe
unittest
{
    // Whatever this machine is, a probe must not throw and must agree with
    // itself. Both layers are exercised, since the cheap one is a separate
    // path rather than a subset of the other.
    foreach (liveness; [false, true])
    {
        const p = probeDisplay(liveness);
        assert(p.present == (p.system != DisplaySystem.none));
        if (p.probed)
            assert(p.present, "a confirmed display is a present one");
        if (!liveness)
            assert(!p.probed, "nothing was reached, so nothing is confirmed");
    }

    // The convenience form is the probe's `present`, by construction.
    const p = probeDisplay();
    assert(p.present == (p.system != DisplaySystem.none));
}

version (Android) {} else version (Posix)
@("ui_app.display.unreachableDisplayIsNotConfirmed")
@safe
unittest
{
    // The gap this module exists for: an advertised display that is not there.
    // A display number nothing binds must not report as reachable — that is a
    // `su`, a container, or a logged-out session, and believing it means
    // committing to a window that cannot open.
    //
    // The socket probe is called directly rather than through the environment.
    // Setting `$DISPLAY` would be a global mutation, and this suite runs in
    // parallel: another test reading the environment mid-run would see it, and
    // a test that can be perturbed by its neighbours is worse than no test.
    assert(!canConnectX11(97), "nothing binds display :97");
    assert(!canConnectUnix("/tmp/.X11-unix/X97"));

    // Degenerate inputs are rejected rather than passed to the kernel.
    assert(!canConnectUnix(""));
    char[256] tooLong = 'x';
    assert(!canConnectUnix(tooLong[]), "a path longer than sun_path");
}
