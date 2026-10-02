/**
What the Android app owes the platform beyond its surface
(docs/specs/terminal/protocols.md, selection.md): system notifications and
the way back from one (`TPR10`, `TPR12`), the system's light/dark setting
(`TPR13`), and the password-prompt probe and autofill spike (`TSE8`–`TSE10`).

The decisions are pure and tested on every host — which pane a return to the
foreground focuses ($(LREF deepLinkOnResume)), the notification tags; the
JNI half is $(LREF DroidPlatform), driven once per frame by
`droid_terminal.DroidTerminal`.
*/
module droid_platform;

import keymap : TermCommand;

/// The tag a pane's system notification is posted under: a later one from
/// the same pane replaces it (`TPR10`).
string paneTag(uint pane) @safe pure nothrow
{
    import std.conv : to;

    return "pane-" ~ pane.to!string;
}

/// The pane a $(LREF paneTag) names; `false` for a tag that is not one.
bool paneOfTag(scope const(char)[] tag, out uint pane) @safe pure nothrow @nogc
{
    enum prefix = "pane-";
    if (tag.length <= prefix.length || tag[0 .. prefix.length] != prefix)
        return false;
    uint v;
    foreach (c; tag[prefix.length .. $])
    {
        if (c < '0' || c > '9' || v > (uint.max - 9) / 10)
            return false;
        v = v * 10 + (c - '0');
    }
    pane = v;
    return true;
}

///
@("droid_platform.paneTag.roundTrips")
@safe pure nothrow unittest
{
    uint p;
    assert(paneTag(7) == "pane-7");
    assert(paneOfTag(paneTag(42), p) && p == 42);
    assert(!paneOfTag("pane-", p));
    assert(!paneOfTag("pane-x1", p));
    assert(!paneOfTag("other-1", p));
}

/// What a return to the foreground does (`TPR12`).
struct DeepLink
{
    enum Kind : ubyte
    {
        none, /// nothing: the app was opened some other way
        focusPane, /// select the pane's tab and focus it (`TSS15`)
        openLog, /// open the notification log (`TPG10`)
    }

    Kind kind;
    uint pane; /// for `focusPane`
}

/**
Where a return to the foreground leads, given the panes that posted a system
notification while the app was away (`posted`, in order, repeats allowed)
and those whose notification is still shown (`shown`).

A NativeActivity cannot read the tap's intent (the spike, D15), but a tapped
notification auto-cancels: so when the list of shown notifications could be
read (`shownKnown`), exactly one that is gone is the one tapped, none gone
means the app was opened another way, and several gone (a "clear all", then
a tap) open the log. When the list could not be read, D15's fallback: one
pane posted → it, several → the log.
*/
DeepLink deepLinkOnResume(scope const uint[] posted, scope const uint[] shown,
    bool shownKnown) @safe pure nothrow @nogc
{
    import std.algorithm.searching : canFind;

    uint first;
    size_t goneCount;
    foreach (i, p; posted)
    {
        if (posted[0 .. i].canFind(p))
            continue; // a pane's later post replaced its earlier one
        if (!shownKnown || !shown.canFind(p))
        {
            if (goneCount++ == 0)
                first = p;
        }
    }
    if (goneCount == 0)
        return DeepLink.init;
    if (goneCount == 1)
        return DeepLink(DeepLink.Kind.focusPane, first);
    return DeepLink(DeepLink.Kind.openLog);
}

///
@("droid_platform.deepLinkOnResume")
@safe pure nothrow @nogc unittest
{
    alias K = DeepLink.Kind;
    static immutable uint[] none_, one = [3], two = [3, 5], again = [3, 3];

    // Nothing posted while away: nothing to do.
    assert(deepLinkOnResume(none_, none_, true).kind == K.none);
    // The one notification is gone: it was tapped.
    assert(deepLinkOnResume(one, none_, true) == DeepLink(K.focusPane, 3));
    // Still shown: the app was opened from the launcher.
    assert(deepLinkOnResume(one, one, true).kind == K.none);
    // Two panes posted, one is gone: that one.
    static immutable uint[] five = [5];
    assert(deepLinkOnResume(two, five, true) == DeepLink(K.focusPane, 3));
    // Both gone: no way to tell which was tapped.
    assert(deepLinkOnResume(two, none_, true).kind == K.openLog);
    // A pane that posted twice is one notification (the tag replaces).
    assert(deepLinkOnResume(again, none_, true) == DeepLink(K.focusPane, 3));
    // The list unreadable: D15's fallback.
    assert(deepLinkOnResume(one, one, false) == DeepLink(K.focusPane, 3));
    assert(deepLinkOnResume(two, none_, false).kind == K.openLog);
}

/// The page a debug trigger names: `about`, `logs` or `notifications`
/// (surrounding space ignored); `none` for anything else.
TermCommand pageCommand(scope const(char)[] name) @safe pure nothrow @nogc
{
    import std.ascii : isWhite;

    while (name.length && isWhite(name[0]))
        name = name[1 .. $];
    while (name.length && isWhite(name[$ - 1]))
        name = name[0 .. $ - 1];
    switch (name)
    {
        case "about": return TermCommand.openAbout;
        case "logs": return TermCommand.openLogs;
        case "notifications": return TermCommand.openNotifications;
        default: return TermCommand.none;
    }
}

///
@("droid_platform.pageCommand")
@safe pure nothrow @nogc unittest
{
    assert(pageCommand("logs\n") == TermCommand.openLogs);
    assert(pageCommand(" about") == TermCommand.openAbout);
    assert(pageCommand("notifications") == TermCommand.openNotifications);
    assert(pageCommand("settings") == TermCommand.none);
}

version (Android):

import sparkles.android.autofill : AutofillReport;
import sparkles.base.logger : info, warning;
import sparkles.terminal_view.component : TerminalView;
import sparkles.terminal_view.notification_log : NotificationRoute;
import sparkles.terminal_view.osc_scan : Notification;
import sparkles.terminal_view.process_info : PtyReading;

/// The notification channel (`TPR10`).
enum channelId = "terminal";

/// The Android platform's per-app state; one instance, alive as long as the
/// app (the notification hooks point into it).
struct DroidPlatform
{
    /// Asked to focus a pane (`TSS15`); unset, a deep link only logs.
    void delegate(uint pane) focusPane;
    /// Asked to open a page: the notification log after a deep link that
    /// could not tell which pane (`TPG10`), any page from a debug trigger;
    /// unset, a deep link only logs.
    void delegate(TermCommand page) openPage;
    /// Where the autofill spike's test triggers live (`SessionPaths.debugDir`).
    string debugDir;

    private int night = -1; // systemDarkMode as last seen
    private bool resumed, channelMade;
    private uint[] postedWhileAway;
    private PtyReading reading;
    private int probeCountdown, triggerCountdown, schemeCountdown;

    @disable this(this);

    /// Create the channel — in the foreground, which is when an app
    /// targeting API 28 has the system ask for the permission (`TPR10`).
    void start()
    {
        import sparkles.android.notify : createChannel;

        const err = createChannel(channelId, "Terminal");
        channelMade = err is null;
        if (!channelMade)
            warning(i"terminal: no notification channel: $(err)");
        const d = currentSystemDark;
        night = d;
        info(i"terminal: system scheme $(d < 0 ? "unknown" : d ? "dark" : "light")");
        readReducedMotion();
    }

    /// Whether the system is in dark mode now (unknown counts as dark, the
    /// terminal's own default).
    bool systemDark() const @safe pure nothrow @nogc => night != 0;

    /// The `notify` hook for pane `pane` (`TerminalViewHooks.notify`).
    void delegate(in Notification, NotificationRoute) notifyHook(uint pane) return
    {
        return (in Notification n, NotificationRoute route) { post(pane, n, route); };
    }

    /**
    The per-frame half: follow the system scheme (returns `true` when it
    changed, and the caller recolours), notice a return to the foreground
    (deep link), and run the password probe and the autofill spike against
    `tv`.
    */
    bool frame(ref TerminalView tv)
    {
        import sparkles.android.activity : activityResumed;

        const nowResumed = activityResumed();
        const cameBack = nowResumed && !resumed;
        if (cameBack)
        {
            onResume();
            readReducedMotion();
        }
        resumed = nowResumed;

        probe(tv);
        autofill(tv);

        // A JNI round trip: about once a second, and at once on a return.
        if (!cameBack && schemeCountdown-- > 0)
            return false;
        schemeCountdown = 60;
        const d = currentSystemDark;
        if (d < 0 || d == night)
            return false;
        night = d;
        info(i"terminal: system scheme changed to $(d ? "dark" : "light")");
        return true;
    }

    // ── notifications ───────────────────────────────────────────────────────

    private void post(uint pane, in Notification n, NotificationRoute route)
    {
        import sparkles.android.notify : NotificationPost, post_ = post;

        if (route != NotificationRoute.system)
            return; // the toast is the pane's (M8)
        const err = channelMade ? post_(NotificationPost(
                channel: channelId,
                tag: paneTag(pane),
                title: n.title.length ? n.title.idup : "Terminal",
                text: n.body.idup,
                source: cast(int) pane))
            : "no notification channel";
        if (err !is null)
        {
            warning(i"terminal: notification from pane $(pane) not shown: $(err)");
            return;
        }
        info(i"terminal: notification posted for pane $(pane)");
        if (!resumed)
            postedWhileAway ~= pane;
    }

    private void onResume()
    {
        import sparkles.android.notify : activeTags;

        if (postedWhileAway.length == 0)
            return;
        bool known;
        uint[] shown;
        foreach (tag; activeTags(known))
        {
            uint p;
            if (paneOfTag(tag, p))
                shown ~= p;
        }
        const link = deepLinkOnResume(postedWhileAway, shown, known);
        postedWhileAway = null;
        final switch (link.kind)
        {
            case DeepLink.Kind.none:
                break;
            case DeepLink.Kind.focusPane:
                info(i"terminal: deep link to pane $(link.pane)");
                if (focusPane !is null)
                    focusPane(link.pane);
                break;
            case DeepLink.Kind.openLog:
                info(i"terminal: deep link to the notification log");
                if (openPage !is null)
                    openPage(TermCommand.openNotifications);
                break;
        }
    }

    private static int currentSystemDark() @trusted nothrow
    {
        import sparkles.android.system_scheme : systemDarkMode;

        return systemDarkMode();
    }

    /// Whether the user removed animations (`ACC5`): the selection's edge
    /// scroll then steps a row at a time (`TSE3`). Read at start and on every
    /// return to the foreground, where a change in the settings shows up.
    bool reducedMotion;

    private void readReducedMotion() @trusted nothrow
    {
        import sparkles.android.motion : animationsRemoved;

        const r = animationsRemoved();
        if (r >= 0 && (r == 1) != reducedMotion)
        {
            reducedMotion = r == 1;
            info(i"terminal: animations $(reducedMotion ? "removed" : "on")");
        }
    }

    // ── the password probe and the autofill spike ───────────────────────────

    /// `TSE10`'s probe, about once a second: its transitions are logged (the
    /// chip that acts on them is M8's).
    private void probe(ref TerminalView tv)
    {
        import sparkles.terminal_view.process_info : ptyReading;

        if (probeCountdown-- > 0)
            return;
        probeCountdown = 60;
        const r = (() @trusted => ptyReading(tv.s.pty_fd))();
        if (r == reading)
            return;
        reading = r;
        static immutable names = ["unknown", "echoing", "password", "raw"];
        info(i"terminal: pty reads $(names[r])");
    }

    /**
    The spike's triggers, checked about once a second: a file
    `<debugDir>/autofill-request` opens a request; `<debugDir>/autofill-fake`
    fills the open one with its contents as a service would (`TSE9`'s marker
    test). Each frame an open request is polled, and a filled value goes to
    the pty — and nowhere else.
    */
    private void autofill(ref TerminalView tv)
    {
        import sparkles.android.autofill : autofillPending, autofillReport,
            fakeAutofill, pollAutofill, requestPasswordAutofill, takeAutofilled;

        if (autofillPending)
            pollAutofill();
        takeAutofilled((scope const(char)[] secret) {
            typeSecret(tv, secret);
            info(i"terminal: autofill sent $(secret.length) bytes to the pty");
        });

        if (debugDir.length == 0 || triggerCountdown-- > 0)
            return;
        triggerCountdown = 60;
        if (takeTrigger("autofill-request") !is null)
        {
            const ok = requestPasswordAutofill();
            info(i"terminal: autofill requested: $(ok)");
        }
        if (auto marker = takeTrigger("autofill-fake"))
        {
            fakeAutofill(marker);
            marker[] = 0;
        }
        // `open-page` holding `about`, `logs` or `notifications` opens that
        // page — the on-device test of the pages (`TPG`).
        if (auto page = takeTrigger("open-page"))
        {
            const cmd = pageCommand(page);
            info(i"terminal: debug trigger opens $(page)");
            if (cmd != TermCommand.none && openPage !is null)
                openPage(cmd);
        }
        const rep = autofillReport;
        if (rep != lastReport)
        {
            lastReport = rep;
            info(i"terminal: autofill manager=$(rep.managerFound) enabled=$(rep.enabled) requested=$(rep.requested)");
        }
    }

    private AutofillReport lastReport;

    /// The trigger file's contents (an empty file reads as one space), and
    /// the file removed; `null` when it does not exist.
    private char[] takeTrigger(string name) nothrow
    {
        import std.file : read, remove;
        import std.path : buildPath;

        const path = buildPath(debugDir, name);
        try
        {
            auto bytes = cast(char[]) read(path);
            remove(path);
            return bytes.length ? bytes : " ".dup;
        }
        catch (Exception)
            return null;
    }

    /// Type `secret` into the pane, one character at a time — straight to the
    /// key encoder, past the terminal's key table, so no character of it can
    /// fire a binding (`TSE8`).
    private static void typeSecret(ref TerminalView tv, scope const(char)[] secret) nothrow
    {
        import std.utf : decode;
        import sparkles.input : Key, KeyEvent;

        size_t i;
        while (i < secret.length)
        {
            const start = i;
            dchar c;
            try
                c = decode(secret, i);
            catch (Exception)
                return;
            KeyEvent k;
            k.key = Key.char_;
            k.text = secret[start .. i];
            k.unshifted = c;
            (() @trusted => cast(void) tv.sendKey(k))();
        }
    }
}
