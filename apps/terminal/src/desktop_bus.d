/**
The desktop terminal on the session bus (decisions.md, D43): system
notifications through `org.freedesktop.Notifications` (`TPR11`), a click
on one finding its pane (`TPR12`), and the system's light/dark preference
from the XDG desktop portal (`TPR13`).

$(B Notifications) — `Notify` with a `default` action, replacing the pane's
previous notification rather than stacking; `ActionInvoked` from the server
that posted it reports the pane; `NotificationClosed` forgets it. The body
is markup-escaped when the server renders markup (`GetCapabilities`).

$(B Appearance) — `org.freedesktop.portal.Settings.ReadOne` (`Read`, its
version-1 form, when the portal is older) of
`org.freedesktop.appearance color-scheme` at start, then its
`SettingChanged` signal: 1 prefers dark, 2 light, 0 no preference.

Nothing here blocks except `open` and `settleScheme`, both bounded; the
frame loop calls `pump`.
*/
module desktop_bus;

import core.time : Duration, MonoTime, msecs;

import dbus_conn : BusConnection;
import dbus_wire : Message, MessageType, Outgoing, WireReader, WireWriter;

/// The notification server.
enum notificationsName = "org.freedesktop.Notifications";
/// ditto
enum notificationsPath = "/org/freedesktop/Notifications";
/// The desktop portal and its settings interface.
enum portalName = "org.freedesktop.portal.Desktop";
/// ditto
enum portalPath = "/org/freedesktop/portal/desktop";
/// ditto
enum settingsIface = "org.freedesktop.portal.Settings";
/// The vendor-neutral appearance namespace and its scheme key.
enum appearanceNamespace = "org.freedesktop.appearance";
/// ditto
enum colorSchemeKey = "color-scheme";

/// The application name a notification carries.
enum appName = "sparkles:terminal";

/// `org.freedesktop.appearance color-scheme`.
enum SystemScheme : ubyte
{
    noPreference, /// 0 — the application's own default
    dark,         /// 1
    light,        /// 2
}

/// The scheme a `color-scheme` value names; unknown values are no preference.
SystemScheme systemSchemeOf(uint value) @safe pure nothrow @nogc
    => value == 1 ? SystemScheme.dark : value == 2 ? SystemScheme.light
        : SystemScheme.noPreference;

///
@("desktop_bus.systemSchemeOf")
@safe pure nothrow @nogc unittest
{
    assert(systemSchemeOf(0) == SystemScheme.noPreference);
    assert(systemSchemeOf(1) == SystemScheme.dark);
    assert(systemSchemeOf(2) == SystemScheme.light);
    assert(systemSchemeOf(7) == SystemScheme.noPreference);
}

/// Reads a `u` wrapped in any number of variants (`ReadOne` answers `v`,
/// the deprecated `Read` `v` of `v`). False for anything else.
bool readVariantUint(ref WireReader r, out uint value) @safe pure nothrow @nogc
{
    foreach (_; 0 .. 4)
    {
        const sig = r.signature();
        if (r.failed)
            return false;
        if (sig == "u")
        {
            value = r.u32();
            return !r.failed;
        }
        if (sig != "v")
            return false;
    }
    return false;
}

///
@("desktop_bus.readVariantUint.unwrapsNestedVariants")
@safe pure nothrow unittest
{
    WireWriter w;
    w.signature("v");
    w.signature("u");
    w.u32(2);
    auto r = WireReader(w.data);
    uint v;
    assert(readVariantUint(r, v) && v == 2);

    WireWriter s;
    s.signature("s");
    s.str("2");
    auto r2 = WireReader(s.data);
    assert(!readVariantUint(r2, v));
}

/// `s` with the characters notification markup gives meaning escaped.
string escapeMarkup(in char[] s) @safe pure nothrow
{
    string o;
    foreach (c; s)
    {
        switch (c)
        {
            case '&':
                o ~= "&amp;";
                break;
            case '<':
                o ~= "&lt;";
                break;
            case '>':
                o ~= "&gt;";
                break;
            default:
                o ~= c;
        }
    }
    return o;
}

///
@("desktop_bus.escapeMarkup")
@safe pure nothrow unittest
{
    assert(escapeMarkup(`<a href="x">&</a>`) == `&lt;a href="x"&gt;&amp;&lt;/a&gt;`);
    assert(escapeMarkup("plain") == "plain");
}

/**
The `Notify` arguments for one notification: `replaces` is the pane's
previous notification (0 for none), the text is scrubbed for the bus and,
when the server renders markup, escaped.
*/
ubyte[] notifyBody(uint replaces, in char[] summary, in char[] body,
    bool bodyMarkup) @safe pure nothrow
{
    import dbus_wire : scrubUtf8;

    WireWriter w;
    w.str(appName);
    w.u32(replaces);
    w.str("utilities-terminal");
    w.str(scrubUtf8(summary));
    const text = scrubUtf8(body);
    w.str(bodyMarkup ? escapeMarkup(text) : text);
    auto actions = w.beginArray(4);
    w.str("default"); // a click on the notification itself
    w.str("Show");
    w.endArray(actions);
    auto hints = w.beginArray(8);
    w.beginStruct();
    w.str("urgency");
    w.signature("y");
    w.u8(1); // normal
    w.endArray(hints);
    w.i32(-1); // the server's default timeout
    return w.data;
}

///
@("desktop_bus.notifyBody.carriesADefaultAction")
@safe pure nothrow unittest
{
    const b = notifyBody(5, "make", "<done>\xff", bodyMarkup: true);
    auto r = WireReader(b);
    assert(r.str() == appName);
    assert(r.u32() == 5);
    r.str();
    assert(r.str() == "make");
    assert(r.str() == "&lt;done&gt;\uFFFD");
    const n = r.u32();
    const end = r.pos + n;
    assert(r.str() == "default" && r.str() == "Show" && r.pos == end);
    const(char)[] rest = "a{sv}i";
    r.skip(rest);
    assert(rest == "i" && r.i32() == -1 && r.empty && !r.failed);
}

/**
The terminal's session-bus client. `open` it once; post notifications with
`post`; call `pump` every frame and collect what changed with
`takeScheme` and `takeActivation`.
*/
struct DesktopBus
{
    private BusConnection conn;
    private bool bodyMarkup;
    private string notifier; // the unique name of the server that took a post
    private uint capsSerial, readOneSerial, readSerial;
    private ulong[uint] postOfSerial; // a Notify call → its pane
    private ulong[uint] paneOfId;     // a posted notification → its pane
    private uint[ulong] idOfPane;     // a pane → its notification on screen
    private SystemScheme scheme_;
    private bool schemeSettled, schemeDirty;
    private ulong[] activations;

    @disable this(this);

    /// Whether the bus is connected.
    bool isOpen() const @safe pure nothrow @nogc => conn.isOpen;

    /// Why the bus is not connected.
    string error() const @safe pure nothrow @nogc => conn.error;

    /**
    Connects to the bus at `address`, subscribes to the notification and
    portal signals, asks the notification server what it renders and the
    portal for the scheme. The answers arrive through `pump`.
    */
    bool open(string address, Duration timeout) @safe
    {
        if (!conn.open(address, timeout))
            return false;
        conn.addMatch("type='signal',interface='" ~ notificationsName
            ~ "',member='ActionInvoked'");
        conn.addMatch("type='signal',interface='" ~ notificationsName
            ~ "',member='NotificationClosed'");
        conn.addMatch("type='signal',interface='" ~ settingsIface
            ~ "',member='SettingChanged',arg0='" ~ appearanceNamespace ~ "'");
        Outgoing caps = {
            destination: notificationsName, path: notificationsPath,
            iface: notificationsName, member: "GetCapabilities",
        };
        capsSerial = conn.send(caps);
        readOneSerial = sendRead("ReadOne");
        return conn.isOpen;
    }

    /**
    Waits up to `timeout` for the portal's first answer, so the first frame
    is drawn in the right scheme. A portal that is slow to start answers
    later, through `pump`.
    */
    void settleScheme(Duration timeout) @safe
    {
        const deadline = MonoTime.currTime + timeout;
        Message m;
        while (!schemeSettled && conn.wait(m, deadline))
            handle(m);
    }

    /// Posts a notification from `pane`, replacing that pane's previous one.
    void post(ulong pane, in char[] summary, in char[] body) @safe
    {
        Outgoing m = {
            destination: notificationsName, path: notificationsPath,
            iface: notificationsName, member: "Notify",
            signature: "susssasa{sv}i",
            body: notifyBody(idOfPane.get(pane, 0), summary, body, bodyMarkup),
        };
        if (const serial = conn.send(m))
            postOfSerial[serial] = pane;
    }

    /// Handles everything that has arrived.
    void pump() @safe
    {
        Message m;
        while (conn.next(m))
            handle(m);
    }

    /// The system scheme, when it changed since the last call (or was first
    /// read).
    bool takeScheme(out SystemScheme s) @safe pure nothrow @nogc
    {
        if (!schemeDirty)
            return false;
        schemeDirty = false;
        s = scheme_;
        return true;
    }

    /// The system scheme as last read.
    SystemScheme scheme() const @safe pure nothrow @nogc => scheme_;

    /// A pane whose notification the user activated, oldest first.
    bool takeActivation(out ulong pane) @safe pure nothrow
    {
        if (!activations.length)
            return false;
        pane = activations[0];
        activations = activations[1 .. $];
        return true;
    }

    private uint sendRead(string member) @safe
    {
        WireWriter w;
        w.str(appearanceNamespace);
        w.str(colorSchemeKey);
        Outgoing m = {
            destination: portalName, path: portalPath, iface: settingsIface,
            member: member, signature: "ss", body: w.data,
        };
        return conn.send(m);
    }

    private void setScheme(SystemScheme s) @safe pure nothrow @nogc
    {
        // Several portal backends each emit the change: report it once.
        if (s != scheme_ || !schemeSettled)
            schemeDirty = true;
        scheme_ = s;
        schemeSettled = true;
    }

    private void handle(ref Message m) @safe
    {
        import sparkles.base.logger : warning;

        final switch (m.type)
        {
            case MessageType.invalid:
            case MessageType.methodCall:
                return;
            case MessageType.methodReturn:
                auto r = m.bodyReader;
                if (m.replySerial == capsSerial)
                {
                    const n = r.u32();
                    const end = r.pos + n;
                    while (!r.failed && r.pos < end)
                        if (r.str() == "body-markup")
                            bodyMarkup = true;
                }
                else if (m.replySerial == readOneSerial || m.replySerial == readSerial)
                {
                    uint v;
                    setScheme(readVariantUint(r, v) ? systemSchemeOf(v)
                        : SystemScheme.noPreference);
                }
                else if (auto pane = m.replySerial in postOfSerial)
                {
                    const id = r.u32();
                    if (!r.failed)
                    {
                        paneOfId[id] = *pane;
                        idOfPane[*pane] = id;
                        notifier = m.sender;
                    }
                    postOfSerial.remove(m.replySerial);
                }
                return;
            case MessageType.error:
                if (m.replySerial == readOneSerial
                    && m.errorName == "org.freedesktop.DBus.Error.UnknownMethod")
                    readSerial = sendRead("Read"); // a version-1 portal
                else if (m.replySerial == readOneSerial || m.replySerial == readSerial)
                    setScheme(SystemScheme.noPreference); // no portal, no key
                else if (m.replySerial in postOfSerial)
                {
                    postOfSerial.remove(m.replySerial);
                    warning(i"notification not posted: $(m.errorName)");
                }
                return;
            case MessageType.signal:
                auto r = m.bodyReader;
                if (m.iface == notificationsName && m.member == "ActionInvoked")
                {
                    const id = r.u32();
                    r.str();
                    // Only the server that took the post speaks for it.
                    if (auto pane = id in paneOfId)
                        if (!r.failed && m.sender == notifier)
                            activations ~= *pane;
                }
                else if (m.iface == notificationsName && m.member == "NotificationClosed")
                {
                    uint id = r.u32();
                    if (auto pane = id in paneOfId)
                        if (m.sender == notifier)
                        {
                            if (idOfPane.get(*pane, 0) == id)
                                idOfPane.remove(*pane);
                            paneOfId.remove(id);
                        }
                }
                else if (m.iface == settingsIface && m.member == "SettingChanged")
                {
                    const ns = r.str(), key = r.str();
                    uint v;
                    if (!r.failed && ns == appearanceNamespace && key == colorSchemeKey
                        && readVariantUint(r, v))
                        setScheme(systemSchemeOf(v));
                }
                return;
        }
    }
}

version (unittest)
{
    import dbus_conn : PrivateBus;

    /// A stand-in for the notification server and the portal, on a private
    /// bus: owns both names and answers the calls the terminal makes.
    struct FakeDesktop
    {
        BusConnection conn;
        uint nextId = 40;
        bool oldPortal;          /// answer `ReadOne` with UnknownMethod
        uint colorScheme = 2;    /// what the portal reports
        string[] notified;       /// "summary|body|replaces" of each Notify

        @disable this(this);

        void open(string address) @safe
        {
            import dbus_conn : busName, busPath;

            assert(conn.open(address, 2000.msecs), conn.error);
            foreach (name; [notificationsName, portalName])
            {
                WireWriter w;
                w.str(name);
                w.u32(4);
                Outgoing m = {
                    destination: busName, path: busPath, iface: busName,
                    member: "RequestName", signature: "su", body: w.data,
                };
                Message reply;
                assert(conn.callSync(m, 2000.msecs, reply), conn.error);
            }
        }

        /// Answers every call that has arrived.
        void serve() @safe
        {
            import std.conv : text;

            Message m;
            while (conn.next(m))
            {
                if (m.type != MessageType.methodCall)
                    continue;
                WireWriter w;
                string sig;
                auto r = m.bodyReader;
                if (m.member == "GetCapabilities")
                {
                    auto a = w.beginArray(4);
                    w.str("actions");
                    w.str("body-markup");
                    w.endArray(a);
                    sig = "as";
                }
                else if (m.member == "Notify")
                {
                    r.str();
                    const replaces = r.u32();
                    r.str();
                    const summary = r.str(), body = r.str();
                    notified ~= text(summary, "|", body, "|", replaces);
                    w.u32(++nextId);
                    sig = "u";
                }
                else if (m.member == "ReadOne" && oldPortal)
                {
                    reply(m, "org.freedesktop.DBus.Error.UnknownMethod");
                    continue;
                }
                else if (m.member == "ReadOne" || m.member == "Read")
                {
                    w.signature("v");
                    if (m.member == "Read")
                        w.signature("v");
                    w.signature("u");
                    w.u32(colorScheme);
                    sig = "v";
                }
                Outgoing ret = {
                    type: MessageType.methodReturn, destination: m.sender,
                    replySerial: m.serial, signature: sig, body: w.data,
                };
                conn.send(ret);
            }
        }

        void reply(in Message m, string errorName) @safe
        {
            Outgoing e = {
                type: MessageType.error, destination: m.sender,
                replySerial: m.serial, errorName: errorName,
            };
            conn.send(e);
        }

        void signal(string iface, string path, string member, string sig,
            const(ubyte)[] body) @safe
        {
            Outgoing s = {
                type: MessageType.signal, path: path, iface: iface,
                member: member, signature: sig, body: body,
            };
            conn.send(s);
        }
    }

    /// Serves `desk` and pumps `bus` until `done` or `timeout` passes.
    bool exchange(ref FakeDesktop desk, ref DesktopBus bus, scope bool delegate() @safe done,
        Duration timeout = 2000.msecs) @safe
    {
        const deadline = MonoTime.currTime + timeout;
        while (MonoTime.currTime < deadline)
        {
            desk.serve();
            bus.pump();
            if (done())
                return true;
            import core.thread : Thread;

            () @trusted { Thread.sleep(2.msecs); }();
        }
        return false;
    }
}

///
@("desktop_bus.DesktopBus.postsAndFindsThePaneOfAClick")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    PrivateBus daemon;
    if (!daemon.start())
        skipTest("no dbus-daemon on PATH");
    FakeDesktop desk;
    desk.open(daemon.address);

    DesktopBus bus;
    assert(bus.open(daemon.address, 2000.msecs), bus.error);
    assert(exchange(desk, bus, () => bus.bodyMarkup));

    bus.post(7, "build", "done <ok>");
    assert(exchange(desk, bus, () => (41 in bus.paneOfId) !is null));
    assert(desk.notified == ["build|done &lt;ok&gt;|0"]);

    // The same pane again replaces its notification.
    bus.post(7, "build", "again");
    assert(exchange(desk, bus, () => (42 in bus.paneOfId) !is null));
    assert(desk.notified[1] == "build|again|41");

    // A click on it reports pane 7; the same signal from another client
    // does not.
    WireWriter w;
    w.u32(42);
    w.str("default");
    Outgoing forged = {
        type: MessageType.signal, path: notificationsPath, iface: notificationsName,
        member: "ActionInvoked", signature: "us", body: w.data,
    };
    BusConnection stranger;
    assert(stranger.open(daemon.address, 2000.msecs), stranger.error);
    stranger.send(forged);
    desk.signal(notificationsName, notificationsPath, "ActionInvoked", "us", w.data);
    ulong pane;
    assert(exchange(desk, bus, () => bus.takeActivation(pane)));
    assert(pane == 7);
    assert(!exchange(desk, bus, () => bus.takeActivation(pane), 200.msecs));

    // Closed, the pane's next notification stacks afresh.
    WireWriter c;
    c.u32(42);
    c.u32(2);
    desk.signal(notificationsName, notificationsPath, "NotificationClosed", "uu", c.data);
    assert(exchange(desk, bus, () => 42 !in bus.paneOfId));
    bus.post(7, "build", "third");
    assert(exchange(desk, bus, () => desk.notified.length == 3));
    assert(desk.notified[2] == "build|third|0");
}

///
@("desktop_bus.DesktopBus.followsThePortalColorScheme")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    PrivateBus daemon;
    if (!daemon.start())
        skipTest("no dbus-daemon on PATH");
    FakeDesktop desk;
    desk.open(daemon.address);
    desk.colorScheme = 2;

    DesktopBus bus;
    assert(bus.open(daemon.address, 2000.msecs), bus.error);
    SystemScheme s;
    assert(exchange(desk, bus, () => bus.takeScheme(s)));
    assert(s == SystemScheme.light);

    void change(string ns, string key, uint value)
    {
        WireWriter w;
        w.str(ns);
        w.str(key);
        w.signature("u");
        w.u32(value);
        desk.signal(settingsIface, portalPath, "SettingChanged", "ssv", w.data);
    }

    change(appearanceNamespace, colorSchemeKey, 1);
    assert(exchange(desk, bus, () => bus.takeScheme(s)));
    assert(s == SystemScheme.dark);

    // Another key, a repeat of the value (a second backend), then a switch:
    // only the switch is reported.
    change(appearanceNamespace, "accent-color", 2);
    change(appearanceNamespace, colorSchemeKey, 1);
    change(appearanceNamespace, colorSchemeKey, 2);
    assert(exchange(desk, bus, () => bus.takeScheme(s)));
    assert(s == SystemScheme.light);
    bus.pump();
    assert(!bus.takeScheme(s));
}

///
@("desktop_bus.DesktopBus.readsAVersionOnePortal")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    PrivateBus daemon;
    if (!daemon.start())
        skipTest("no dbus-daemon on PATH");
    FakeDesktop desk;
    desk.open(daemon.address);
    desk.oldPortal = true;
    desk.colorScheme = 1;

    DesktopBus bus;
    assert(bus.open(daemon.address, 2000.msecs), bus.error);
    SystemScheme s;
    assert(exchange(desk, bus, () => bus.takeScheme(s)));
    assert(s == SystemScheme.dark);
}

///
@("desktop_bus.DesktopBus.settlesWithoutAPortal")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    PrivateBus daemon;
    if (!daemon.start())
        skipTest("no dbus-daemon on PATH");

    // Nobody owns the portal's name: the bus answers ServiceUnknown at once.
    DesktopBus bus;
    assert(bus.open(daemon.address, 2000.msecs), bus.error);
    bus.settleScheme(2000.msecs);
    SystemScheme s;
    assert(bus.takeScheme(s) && s == SystemScheme.noPreference);
}
