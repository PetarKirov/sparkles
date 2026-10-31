/**
The desktop's appearance on Linux, from the XDG settings portal
(`org.freedesktop.portal.Settings`): GNOME, KDE and any desktop with a
portal backend, sandboxed or not.

$(LREF PortalAppearance.open) asks for every key at once (`ReadAll`) and
subscribes to `SettingChanged`, waiting a short budget for the answer — the
first frame should be drawn in the right scheme — and taking a late answer
when it comes. After that, $(LREF PortalAppearance.service), called whenever
the loop has found the bus readable, applies each change and says whether
the appearance changed: the portal was seen signalling one change twice, so
a change is compared before it is reported.

Keys:

| Namespace                           | Key                         | Gives                             |
| ----------------------------------- | --------------------------- | --------------------------------- |
| `org.freedesktop.appearance`        | `color-scheme` (`u`)        | 0 none, 1 dark, 2 light           |
|                                     | `accent-color` (`(ddd)`)    | sRGB in [0, 1]; outside: unset    |
|                                     | `contrast` (`u`)            | 1 high                            |
|                                     | `reduced-motion` (`u`)      | 1 reduced                         |
| `org.gnome.desktop.interface`       | `font-name` (`s`)           | the interface font                |
|                                     | `enable-animations` (`b`)   | reduced motion where the portal does not say (GNOME) |
| `org.gnome.desktop.wm.preferences`  | `button-layout` (`s`)       | the title bar's controls          |
|                                     | `titlebar-font` (`s`), `titlebar-uses-system-font` (`b`) | the title's font |
*/
module sparkles.appearance.portal;

version (linux):

import core.time : Duration, msecs;

import sparkles.base.expected : err, ok;

import sparkles.appearance.types : ContrastLevel, FontDescription, parseButtonLayout,
    parseFontDescription, SchemePreference, SystemAppearance;
import sparkles.base.term_color : RgbColor;
import sparkles.dbus.connection : Connection, DBusError, DBusResult;
import sparkles.dbus.message : Header, MessageType, Parsed;
import sparkles.dbus.wire : Reader, Writer;
import sparkles.event_horizon.loop : DefaultLoop;

private enum portalName = "org.freedesktop.portal.Desktop";
private enum portalPath = "/org/freedesktop/portal/desktop";
private enum settingsInterface = "org.freedesktop.portal.Settings";

/// The namespaces read.
private immutable string[3] namespaces = [
    "org.freedesktop.appearance",
    "org.gnome.desktop.interface",
    "org.gnome.desktop.wm.preferences",
];

/**
The appearance the portal reports, kept current.
*/
struct PortalAppearance
{
    private Connection bus_;
    private SystemAppearance current_;
    private PortalKeys keys_;
    private uint readSerial_;
    // The portal's unique name on the bus: what its signals come from.
    private char[64] owner_;
    private size_t ownerLength_;

    @disable this(this);

    /// The appearance as last read.
    ref const(SystemAppearance) current() const return @safe pure nothrow @nogc => current_;

    /// Whether the portal could be asked: the bus is open.
    bool isOpen() const @safe pure nothrow @nogc => bus_.isOpen;

    /**
    Connects to the session bus, subscribes to changes and reads every key,
    waiting at most `budget` for the answer. A later answer is applied by
    $(LREF service).
    */
    static DBusResult!void open(out PortalAppearance p, Duration budget = 250.msecs)
        @trusted nothrow
        => start(p, budget, -1);

    /// As $(LREF open), over `fd`, a socket connected to a bus: a test's.
    static DBusResult!void adopt(out PortalAppearance p, int fd, Duration budget = 250.msecs)
        @trusted nothrow
        => start(p, budget, fd);

    private static DBusResult!void start(ref PortalAppearance p, Duration budget, int fd)
        @trusted nothrow
    {
        import core.time : MonoTime;

        // One budget for every step: connecting, subscribing, asking.
        const deadline = MonoTime.currTime + budget;
        Duration left() => deadline - MonoTime.currTime;
        bool done;
        scope (exit)
            if (!done)
                p.bus_.close();
        auto opened = fd < 0 ? Connection.openSession(p.bus_, budget)
            : Connection.adopt(p.bus_, fd, budget);
        if (opened.hasError)
            return opened;
        // From the portal only: any program on the bus may send a signal of
        // the same name, and the bus checks the sender for us.
        auto matched = p.bus_.addMatch("type='signal',sender='org.freedesktop.portal.Desktop',"
            ~ "interface='org.freedesktop.portal.Settings',member='SettingChanged',"
            ~ "path='/org/freedesktop/portal/desktop'", left);
        if (matched.hasError)
            return matched;
        // The portal restarted: its signals come from its new name.
        matched = p.bus_.addMatch("type='signal',sender='org.freedesktop.DBus',"
            ~ "interface='org.freedesktop.DBus',member='NameOwnerChanged',"
            ~ "arg0='org.freedesktop.portal.Desktop'", left);
        if (matched.hasError)
            return matched;
        Writer body;
        const at = body.beginArray(4);
        foreach (ns; namespaces)
            body.str(ns);
        body.endArray(at, 4);
        auto sent = p.bus_.send(Header(type: MessageType.methodCall, destination: portalName,
            path: portalPath, iface: settingsInterface, member: "ReadAll", signature: "as"),
            body.data, left);
        if (sent.hasError)
            return err!void(sent.error);
        p.readSerial_ = sent.value;
        auto reply = p.bus_.waitReply(sent.value, left);
        if (!reply.hasError)
        {
            auto parsed = reply.value.parse();
            // No portal (none installed, or it failed to start): nothing to
            // follow.
            if (parsed.header.type == MessageType.error)
                return err!void(DBusError("the settings portal is not available"));
            p.take(parsed);
        }
        done = true;
        return ok!DBusError();
    }

    /// Has `loop` watch the bus for changes. $(LREF close) before the loop
    /// goes: the loop holds the poll until then.
    DBusResult!void arm(ref DefaultLoop loop) @trusted nothrow => bus_.arm(loop);

    /// Closes the bus, cancelling its poll.
    void close() @trusted nothrow
    {
        bus_.close();
    }

    /**
    Applies what the bus has brought: a late answer to the first read, and
    each `SettingChanged`. `true` when the appearance changed.
    */
    bool service() @trusted nothrow
    {
        const before = current_;
        cast(void) bus_.service((ref Parsed p) nothrow { take(p); });
        return current_ != before;
    }

    private void own(scope const(char)[] name) @safe pure nothrow @nogc
    {
        ownIn(owner_, ownerLength_, name);
    }

    // A message from the bus: the first read's answer, or a change.
    private void take(ref Parsed p) @safe nothrow
    {
        if (!p.ok)
            return;
        if ((p.header.type == MessageType.methodReturn || p.header.type == MessageType.error)
            && p.header.replySerial == readSerial_ && readSerial_ != 0)
        {
            readSerial_ = 0;
            if (p.header.type == MessageType.methodReturn && p.header.signature == "a{sa{sv}}")
            {
                keys_.readAll(p.body);
                own(p.header.sender);
            }
        }
        else if (p.header.type == MessageType.signal && p.header.member == "NameOwnerChanged"
            && p.header.sender == "org.freedesktop.DBus" && p.header.signature == "sss")
        {
            const name = p.body.str();
            p.body.str();
            const next = p.body.str();
            if (!p.body.failed && name == portalName)
                own(next);
        }
        // Only the portal's own: the match rule asks the bus for its
        // broadcasts, but a signal sent to this connection alone can come
        // from anyone.
        else if (p.header.type == MessageType.signal && p.header.member == "SettingChanged"
            && p.header.iface == settingsInterface && p.header.path == portalPath
            && p.header.signature == "ssv" && ownerLength_ > 0
            && p.header.sender == owner_[0 .. ownerLength_])
        {
            const ns = p.body.str();
            const key = p.body.str();
            const sig = p.body.variant();
            if (!p.body.failed)
                keys_.apply(ns, key, sig, p.body);
        }
        current_ = keys_.appearance();
    }
}

private void ownIn(ref char[64] owner, ref size_t length, scope const(char)[] name)
    @safe pure nothrow @nogc
{
    length = name.length <= owner.length ? name.length : 0;
    owner[0 .. length] = name[0 .. length];
}

/**
The keys as the portal last gave them, and the appearance they make. Kept
apart from the bus so a test can feed it messages.
*/
struct PortalKeys
{
    SystemAppearance a; ///
    // GNOME's sources for what the portal's own namespace may not say.
    private bool portalMotion_, animations_ = true, haveAnimations_;
    private bool titleUsesSystem_ = true;
    private FontDescription titlebarFont_;
    private bool haveTitlebarFont_;

@safe pure nothrow @nogc:

    /// Reads a `ReadAll` answer, `a{sa{sv}}`: all of it, or, where it is
    /// cut short or malformed, none.
    void readAll(ref Reader r)
    {
        PortalKeys read = this;
        read.readAllInto(r);
        if (!r.failed)
            this = read;
    }

    private void readAllInto(ref Reader r)
    {
        const end = r.beginArray(8);
        while (r.more(end))
        {
            r.beginStruct();
            const ns = r.str();
            const keys = r.beginArray(8);
            while (r.more(keys))
            {
                r.beginStruct();
                const key = r.str();
                const sig = r.variant();
                apply(ns, key, sig, r);
            }
        }
    }

    /// Applies one key's value, read from `r` as `sig`; skipped when it is
    /// not one of the keys, or not of the type expected.
    void apply(scope const(char)[] ns, scope const(char)[] key, scope const(char)[] sig,
        ref Reader r)
    {
        if (r.failed)
            return;
        if (ns == "org.freedesktop.appearance")
        {
            if (key == "color-scheme" && sig == "u")
            {
                const v = r.u32();
                if (r.failed)
                    return;
                a.scheme = v == 1 ? SchemePreference.dark : v == 2 ? SchemePreference.light
                    : SchemePreference.noPreference;
                a.hasScheme = true;
                return;
            }
            if (key == "accent-color" && sig == "(ddd)")
            {
                r.beginStruct();
                const red = r.f64(), green = r.f64(), blue = r.f64();
                if (r.failed)
                    return;
                a.hasAccent = inUnit(red) && inUnit(green) && inUnit(blue);
                if (a.hasAccent)
                    a.accent = RgbColor(channel(red), channel(green), channel(blue));
                return;
            }
            if (key == "contrast" && sig == "u")
            {
                const v = r.u32();
                if (r.failed)
                    return;
                a.contrast = v == 1 ? ContrastLevel.high : ContrastLevel.standard;
                a.hasContrast = true;
                return;
            }
            if (key == "reduced-motion" && sig == "u")
            {
                const v = r.u32();
                if (r.failed)
                    return;
                a.reducedMotion = v == 1;
                a.hasReducedMotion = portalMotion_ = true;
                return;
            }
        }
        else if (ns == "org.gnome.desktop.interface")
        {
            if (key == "font-name" && sig == "s")
            {
                const v = r.str();
                if (r.failed)
                    return;
                a.font = parseFontDescription(v);
                a.hasFont = true;
                return;
            }
            if (key == "enable-animations" && sig == "b")
            {
                const v = r.boolean();
                if (r.failed)
                    return;
                animations_ = v;
                haveAnimations_ = true;
                return;
            }
        }
        else if (ns == "org.gnome.desktop.wm.preferences")
        {
            if (key == "button-layout" && sig == "s")
            {
                const v = r.str();
                if (r.failed)
                    return;
                a.buttons = parseButtonLayout(v);
                a.hasButtons = true;
                return;
            }
            if (key == "titlebar-font" && sig == "s")
            {
                const v = r.str();
                if (r.failed)
                    return;
                titlebarFont_ = parseFontDescription(v);
                haveTitlebarFont_ = true;
                return;
            }
            if (key == "titlebar-uses-system-font" && sig == "b")
            {
                const v = r.boolean();
                if (!r.failed)
                    titleUsesSystem_ = v;
                return;
            }
        }
        r.skip(sig);
    }

    /// The appearance the keys make.
    SystemAppearance appearance() const
    {
        SystemAppearance out_ = a;
        if (!portalMotion_ && haveAnimations_)
        {
            out_.reducedMotion = !animations_;
            out_.hasReducedMotion = true;
        }
        // The title is set bold in the interface font unless the title bar
        // names a font of its own (GNOME's `titlebar-uses-system-font`).
        if (!titleUsesSystem_ && haveTitlebarFont_)
        {
            out_.titleFont = titlebarFont_;
            out_.hasTitleFont = true;
        }
        else if (a.hasFont)
        {
            out_.titleFont = a.font;
            out_.titleFont.bold = true;
            out_.hasTitleFont = true;
        }
        return out_;
    }

    private static bool inUnit(double v) => v >= 0 && v <= 1;
    private static ubyte channel(double v) => cast(ubyte)(v * 255 + 0.5);
}

version (unittest)
{
    // One key's value as `SettingChanged` would carry it: `ssv`.
    private PortalKeys applied(PortalKeys keys, string ns, string key,
        scope void delegate(ref Writer) @safe pure nothrow value, string sig) @safe
    {
        Writer w;
        w.sig(sig);
        value(w);
        auto r = Reader(w.data);
        const s = r.sig();
        keys.apply(ns, key, s, r);
        return keys;
    }
}

@("appearance.portal.keys")
@safe unittest
{
    PortalKeys k;
    k = applied(k, "org.freedesktop.appearance", "color-scheme", (ref w) { w.u32(1); }, "u");
    k = applied(k, "org.freedesktop.appearance", "accent-color", (ref w) {
        w.beginStruct();
        w.f64(0.207843);
        w.f64(0.517647);
        w.f64(0.894118);
    }, "(ddd)");
    k = applied(k, "org.gnome.desktop.wm.preferences", "button-layout",
        (ref w) { w.str("appmenu:minimize,maximize,close"); }, "s");
    k = applied(k, "org.gnome.desktop.interface", "font-name",
        (ref w) { w.str("Adwaita Sans 11"); }, "s");
    k = applied(k, "org.gnome.desktop.interface", "enable-animations", (ref w) { w.boolean(false); },
        "b");
    const a = k.appearance();
    assert(a.prefersDark && a.hasAccent && a.accent == RgbColor(0x35, 0x84, 0xe4));
    assert(a.hasButtons && a.buttons.atEnd.length == 3);
    assert(a.titleFont.family[] == "Adwaita Sans" && a.titleFont.bold && a.titleFont.size == 11);
    assert(a.hasReducedMotion && a.reducedMotion, "GNOME's animations switch, off");

    k = applied(k, "org.freedesktop.appearance", "reduced-motion", (ref w) { w.u32(0); }, "u");
    assert(!k.appearance().reducedMotion, "the portal's own key wins");
    k = applied(k, "org.freedesktop.appearance", "accent-color", (ref w) {
        w.beginStruct();
        w.f64(-1);
        w.f64(0);
        w.f64(0);
    }, "(ddd)");
    assert(!k.appearance().hasAccent, "out of range: unset");
    k = applied(k, "org.freedesktop.appearance", "color-scheme", (ref w) { w.str("dark"); }, "s");
    assert(k.appearance().prefersDark, "a key of the wrong type is skipped");
    k = applied(k, "org.gnome.desktop.wm.preferences", "titlebar-uses-system-font",
        (ref w) { w.boolean(false); }, "b");
    k = applied(k, "org.gnome.desktop.wm.preferences", "titlebar-font",
        (ref w) { w.str("Cantarell Bold 12"); }, "s");
    assert(k.appearance().titleFont.family[] == "Cantarell"
        && k.appearance().titleFont.size == 12);
}

@("appearance.portal.aReadCutShortChangesNothing")
@safe unittest
{
    // `{"org.freedesktop.appearance": {"color-scheme": <u 1>, …}}`, cut
    // inside the second key's value.
    Writer w;
    const outer = w.beginArray(8);
    w.beginStruct();
    w.str("org.freedesktop.appearance");
    const inner = w.beginArray(8);
    w.beginStruct();
    w.str("color-scheme");
    w.sig("u");
    w.u32(1);
    w.beginStruct();
    w.str("accent-color");
    w.sig("(ddd)");
    w.beginStruct();
    w.f64(0.5);
    w.endArray(inner, 8);
    w.endArray(outer, 8);
    auto cut = Reader(w.data[0 .. $ - 4]);
    PortalKeys k;
    k.readAll(cut);
    assert(cut.failed && !k.appearance().hasScheme && !k.appearance().hasAccent,
        "none of it, not part");
}

@("appearance.portal.liveSession")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    PortalAppearance p;
    const opened = PortalAppearance.open(p, 1000.msecs);
    if (opened.hasError)
        return skipTest("no session bus: " ~ opened.error.what);
    if (!p.current.hasScheme && !p.current.hasFont)
        return skipTest("no settings portal answered");
    // A desktop with a portal says at least the scheme.
    assert(p.current.hasScheme);
}

@("appearance.portal.followsThePortalThroughTheLoop")
@system unittest
{
    // The portal's whole path, over a socket pair: the bus authenticates and
    // says Hello, the portal answers ReadAll light, then signals dark through
    // the loop; a program elsewhere on the bus signals light, and is not
    // heard. (RSC33's portal half.)
    import core.sys.posix.sys.socket : AF_UNIX, SOCK_STREAM, socketpair;
    import core.sys.posix.unistd : close, write;
    import sparkles.dbus.message : encodeMessage;
    import sparkles.event_horizon : LoopConfig;

    int[2] fds;
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    scope (exit)
        close(fds[1]);
    uint serial;
    void say(scope const(ubyte)[] bytes) { assert(write(fds[1], bytes.ptr, bytes.length) == bytes.length); }
    void message(Header h, scope void delegate(ref Writer) body_ = null)
    {
        Writer b;
        if (body_ !is null)
            body_(b);
        h.serial = ++serial;
        Writer m;
        encodeMessage(m, h, b.data);
        say(m.data);
    }
    void scheme(ref Writer w, uint v)
    {
        w.str("org.freedesktop.appearance");
        w.str("color-scheme");
        w.sig("u");
        w.u32(v);
    }
    say(cast(const(ubyte)[]) "OK 0123456789abcdef0123456789abcdef\r\n");
    message(Header(type: MessageType.methodReturn, replySerial: 1, sender: "org.freedesktop.DBus",
        signature: "s"), (ref w) { w.str(":1.5"); });
    // Hello 1, the two AddMatch 2 and 3, ReadAll 4.
    message(Header(type: MessageType.methodReturn, replySerial: 4, sender: ":1.2",
        signature: "a{sa{sv}}"), (ref w) {
        const outer = w.beginArray(8);
        w.beginStruct();
        w.str("org.freedesktop.appearance");
        const inner = w.beginArray(8);
        w.beginStruct();
        w.str("color-scheme");
        w.sig("u");
        w.u32(2);
        w.endArray(inner, 8);
        w.endArray(outer, 8);
    });

    PortalAppearance p;
    assert(!PortalAppearance.adopt(p, fds[0], 1000.msecs).hasError);
    assert(p.current.hasScheme && !p.current.prefersDark, "light, as read");

    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);
    scope (exit)
        p.close();
    assert(!p.arm(loop).hasError);
    enum settings = Header(type: MessageType.signal, path: portalPath, iface: settingsInterface,
        member: "SettingChanged", signature: "ssv");
    Header genuine = settings;
    genuine.sender = ":1.2";
    message(genuine, (ref w) { scheme(w, 1); });
    Header forged = settings;
    forged.sender = ":1.9";
    message(forged, (ref w) { scheme(w, 2); });
    bool changed;
    foreach (turn; 0 .. 6) // both arrive; every turn is run
    {
        cast(void) loop.runOnce(30.msecs);
        changed |= p.service();
    }
    assert(changed && p.current.prefersDark, "dark, as the portal said, not the other program");
}
