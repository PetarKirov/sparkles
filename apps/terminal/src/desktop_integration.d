/**
What the desktop terminal takes from the desktop (decisions.md, D43): the
system's light/dark preference, recolouring the panes (`TPR13`), and
system notifications for what the user cannot see (`TPR11`), a click on
one raising the window (`TPR12`).

`DesktopBus` speaks the protocol; this module turns its answers into
`TerminalView` calls. Without a session bus (macOS, a bare TTY login, a
container) nothing is posted — the notification log still records every
notification — and the scheme stays the configuration's dark one.
*/
module desktop_integration;

import core.time : msecs;

import desktop_bus : DesktopBus, SystemScheme;
import settings : TerminalConfig;
import sparkles.terminal_view.component : ColorOverrides, TerminalView;
import sparkles.terminal_view.notification_log : NotificationRoute;
import sparkles.terminal_view.osc_scan : Notification;
import sparkles.terminal_view.protocols : ColorScheme;

/// The terminal's scheme for a system preference: light only when asked
/// for; no preference keeps the terminal's default, dark.
ColorScheme terminalSchemeOf(SystemScheme s) @safe pure nothrow @nogc
    => s == SystemScheme.light ? ColorScheme.light : ColorScheme.dark;

///
@("desktop_integration.terminalSchemeOf.noPreferenceIsDark")
@safe pure nothrow @nogc unittest
{
    assert(terminalSchemeOf(SystemScheme.light) == ColorScheme.light);
    assert(terminalSchemeOf(SystemScheme.dark) == ColorScheme.dark);
    assert(terminalSchemeOf(SystemScheme.noPreference) == ColorScheme.dark);
}

/**
The summary of a system notification: the notification's title, else the
pane's (OSC 9 carries a body only), else the application's name.
*/
const(char)[] summaryOf(in Notification n, return scope const(char)[] paneTitle) @safe pure nothrow
{
    import desktop_bus : appName;

    if (n.title.length)
        return n.title.idup;
    return paneTitle.length ? paneTitle : appName;
}

///
@("desktop_integration.summaryOf.fallsBackToThePane")
@safe pure nothrow unittest
{
    Notification n;
    n.appendBody("done");
    assert(summaryOf(n, "make") == "make");
    assert(summaryOf(n, "") == "sparkles:terminal");
    n.appendTitle("build");
    assert(summaryOf(n, "make") == "build");
}

/// The desktop's side of the terminal: one per window.
struct DesktopIntegration
{
    /// The session bus.
    DesktopBus bus;
    /// Whether panes follow the system scheme (`appearance.followSystem`).
    bool followSystem;
    /// The colours of each scheme (`appearance.colors.dark`/`.light`).
    ColorOverrides darkColors, lightColors;

    private bool warnedNoBus;

    @disable this(this);

    /**
    Connects to the session bus, reads the system scheme (waiting briefly,
    so the first frame is drawn in it) and resolves both schemes' colours.
    Warnings about the scheme not in effect land in `warnings`; the one in
    effect is the caller's (`viewOptionsFrom` reports it).
    */
    void start(TerminalConfig c, ref string[] warnings) @safe
    {
        import std.process : environment;

        import settings_load : colorOverrides;
        import sparkles.base.logger : info;

        const address = environment.get("DBUS_SESSION_BUS_ADDRESS");
        if (address.length)
        {
            if (bus.open(address, 500.msecs))
                bus.settleScheme(300.msecs);
            else
                info(i"desktop: no session bus ($(bus.error)); no system notifications or scheme");
        }

        followSystem = c.appearance.followSystem;
        string[] ignored;
        const light = followSystem && !systemDark;
        darkColors = colorOverrides(c.appearance.colors.dark, "appearance.colors.dark",
            light ? warnings : ignored);
        if (followSystem)
            lightColors = colorOverrides(c.appearance.colors.light, "appearance.colors.light",
                light ? ignored : warnings);
        current = light ? ColorScheme.light : ColorScheme.dark;
    }

    /// The scheme panes are in now: a new pane opens in it.
    ColorScheme current = ColorScheme.dark;

    /// The colours a new pane opens with.
    ref const(ColorOverrides) currentColors() const return @safe pure nothrow @nogc
        => colorsOf(current);

    /// Whether the system asks for dark — or says nothing (`TPR13`).
    bool systemDark() const @safe pure nothrow @nogc
        => terminalSchemeOf(bus.scheme) == ColorScheme.dark;

    /// The colours of `scheme`.
    ref const(ColorOverrides) colorsOf(ColorScheme scheme) const return @safe pure nothrow @nogc
        => scheme == ColorScheme.light && followSystem ? lightColors : darkColors;

    /**
    `TerminalViewHooks.notify` for `pane`: a notification routed to the
    system is posted (`TPR11`); a toast awaits the overlay layer (M8).
    */
    void notify(ulong pane, in Notification n, NotificationRoute route,
        scope const(char)[] paneTitle) @safe
    {
        import sparkles.base.logger : warning;

        if (route != NotificationRoute.system)
            return;
        if (!bus.isOpen)
        {
            if (!warnedNoBus)
                warning(i"desktop: no session bus — notifications are only logged");
            warnedNoBus = true;
            return;
        }
        bus.post(pane, summaryOf(n, paneTitle), n.body);
    }

    /**
    Handles what the bus said since the last frame: a scheme change
    recolours every pane of `host` (and returns true, so the caller can follow
    with its chrome); an activated notification focuses its pane — selecting
    its tab (`TSS15`) — and raises the window.
    */
    bool tick(Host)(ref Host host) @system
    {
        import std.conv : text;

        import sparkles.base.logger : info;

        if (!bus.isOpen)
            return false;
        bus.pump();
        ulong pane;
        while (bus.takeActivation(pane))
        {
            cast(void) host.ws.focusPane(cast(uint) pane);
            host.invalidate();
            raiseWindow();
        }
        SystemScheme s;
        if (!bus.takeScheme(s) || !followSystem)
            return false;
        const scheme = terminalSchemeOf(s);
        info(i"desktop: the system prefers $(s.text); panes follow, $(scheme.text)");
        current = scheme;
        foreach (id, tv; host.pool)
            tv.setColorScheme(scheme, colorsOf(scheme));
        host.invalidate();
        return true;
    }
}

/// Brings the window forward: restored if minimized, then focused. A
/// Wayland compositor may only flag it as wanting attention.
void raiseWindow() @system
{
    import raylib : IsWindowMinimized, IsWindowReady, RestoreWindow, SetWindowFocused;

    if (!IsWindowReady())
        return;
    if (IsWindowMinimized())
        RestoreWindow();
    SetWindowFocused();
}
