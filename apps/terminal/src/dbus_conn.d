/**
A D-Bus connection over a `unix:` socket (decisions.md, D43): `EXTERNAL`
authentication, `Hello`, then non-blocking message exchange the frame loop
polls. `dbus_wire` does the encoding.

Opening blocks — authentication and `Hello` are a few local round trips —
bounded by a timeout. After that nothing blocks unless asked to:
`next` returns a message only if one has fully arrived, and `callSync`
waits for one reply, setting aside whatever arrives meanwhile for `next`.
*/
module dbus_conn;

import core.time : Duration, MonoTime, msecs;

import dbus_wire : Decoded, decodeMessage, Message, MessageFlags, MessageType,
    Outgoing, UnixAddress;

/// The bus daemon's own name, path and interface.
enum busName = "org.freedesktop.DBus";
/// ditto
enum busPath = "/org/freedesktop/DBus";

/// One connection to a message bus.
struct BusConnection
{
    /// This connection's unique name (`:1.42`), from `Hello`.
    string uniqueName;
    /// Why the connection failed or closed, empty while it works.
    string error;

    private int fd = -1;
    private uint lastSerial;
    private ubyte[] rx, tx;
    private Message[] backlog;

    @disable this(this);

    ~this() @safe nothrow
    {
        close();
    }

    /// Whether the connection is usable.
    bool isOpen() const @safe pure nothrow @nogc => fd >= 0;

    /**
    Connects to `address` (a D-Bus address list, as
    `DBUS_SESSION_BUS_ADDRESS` holds), authenticates and says `Hello`, all
    within `timeout`. On failure `error` says why and the connection stays
    closed.
    */
    bool open(string address, Duration timeout) @safe
    {
        import core.sys.posix.unistd : getuid;

        import dbus_wire : authExternalLine, parseBusAddress;

        close();
        error = null;
        UnixAddress a;
        if (!parseBusAddress(address, a))
            return failWith("no connectable unix: entry in the bus address");
        if (!connectUnix(a))
            return false;
        const deadline = MonoTime.currTime + timeout;

        tx ~= cast(const(ubyte)[]) authExternalLine(getuid());
        if (!flushUntil(deadline))
            return false;
        string line;
        if (!readLine(deadline, line))
            return false;
        if (line.length < 3 || line[0 .. 3] != "OK ")
            return failWith("the bus refused EXTERNAL authentication: " ~ line);
        tx ~= cast(const(ubyte)[]) "BEGIN\r\n";

        Outgoing hello = {
            destination: busName, path: busPath, iface: busName, member: "Hello",
        };
        Message reply;
        if (!callSync(hello, deadline - MonoTime.currTime, reply))
            return failWith(error.length ? error : "Hello was not answered");
        auto r = reply.bodyReader;
        uniqueName = r.str().idup;
        return true;
    }

    /// Closes the socket; `error` keeps any reason already recorded.
    void close() @trusted nothrow
    {
        import core.sys.posix.unistd : sysClose = close;

        if (fd >= 0)
            sysClose(fd);
        fd = -1;
        rx = null;
        tx = null;
    }

    /// Queues `m` and writes what the socket takes now. Returns its serial,
    /// 0 when the connection is closed.
    uint send(in Outgoing m) @safe
    {
        import dbus_wire : encodeMessage;

        if (!isOpen)
            return 0;
        if (++lastSerial == 0)
            lastSerial = 1;
        tx ~= encodeMessage(m, lastSerial);
        flush();
        return isOpen ? lastSerial : 0;
    }

    /// Asks the bus to route signals matching `rule` here (no reply awaited).
    void addMatch(string rule) @safe
    {
        import dbus_wire : WireWriter;

        WireWriter w;
        w.str(rule);
        Outgoing m = {
            flags: MessageFlags.noReplyExpected, destination: busName,
            path: busPath, iface: busName, member: "AddMatch",
            signature: "s", body: w.data,
        };
        send(m);
    }

    /**
    The next message that has fully arrived — one set aside by `callSync`
    first — without blocking. Also writes what is still queued.
    */
    bool next(out Message m) @safe
    {
        if (backlog.length)
        {
            m = backlog[0];
            backlog = backlog[1 .. $];
            return true;
        }
        flush();
        return receive(m);
    }

    /// `next`, waiting until `deadline` for a message.
    bool wait(out Message m, MonoTime deadline) @safe
    {
        while (true)
        {
            if (next(m))
                return true;
            if (!isOpen || !waitReadable(deadline))
                return false;
        }
    }

    /**
    Sends `call` and waits up to `timeout` for its reply; any other message
    arriving meanwhile is kept for `next`. True for a method return, false
    for an error reply (in `reply`, `error` set), a timeout or a closed bus.
    */
    bool callSync(in Outgoing call, Duration timeout, out Message reply) @safe
    {
        const deadline = MonoTime.currTime + timeout;
        const serial = send(call);
        if (!serial)
            return false;
        while (true)
        {
            Message m;
            flush();
            if (receive(m))
            {
                if (m.replySerial == serial && (m.type == MessageType.methodReturn
                    || m.type == MessageType.error))
                {
                    reply = m;
                    if (m.type == MessageType.error)
                    {
                        error = m.errorName;
                        return false;
                    }
                    return true;
                }
                backlog ~= m;
                continue;
            }
            if (!isOpen)
                return false;
            if (!waitReadable(deadline))
            {
                error = "timed out waiting for " ~ call.member;
                return false;
            }
        }
    }

    private bool failWith(string why) @safe nothrow
    {
        error = why;
        close();
        return false;
    }

    private bool connectUnix(in UnixAddress a) @trusted
    {
        import core.stdc.errno : errno;
        import core.sys.posix.fcntl : F_GETFL, F_SETFD, F_SETFL, fcntl,
            FD_CLOEXEC, O_NONBLOCK;
        import core.sys.posix.sys.socket : AF_UNIX, connect, SOCK_STREAM,
            sockaddr, socket, socklen_t;
        import core.sys.posix.sys.un : sockaddr_un;

        sockaddr_un sa;
        sa.sun_family = AF_UNIX;
        const lead = a.abstract_ ? 1 : 0;
        if (lead + a.path.length + 1 > sa.sun_path.length)
            return failWith("the bus socket path is too long");
        foreach (i, c; a.path)
            sa.sun_path[lead + i] = c;
        const len = cast(socklen_t)(sockaddr_un.sun_path.offsetof + lead
            + a.path.length + (a.abstract_ ? 0 : 1));

        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0)
            return failWith("socket() failed");
        // The pane's shell must not inherit the bus connection.
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        // A write to a closed bus is an error, not a SIGPIPE (Linux says
        // so per `send`, with MSG_NOSIGNAL).
        version (OSX)
        {
            import core.sys.posix.sys.socket : setsockopt, SO_NOSIGPIPE, SOL_SOCKET;

            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, on.sizeof);
        }
        if (connect(fd, cast(sockaddr*) &sa, len) != 0)
        {
            import std.conv : text;

            return failWith(text("cannot connect to the bus (errno ", errno, ")"));
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        return true;
    }

    // Writes as much of `tx` as the socket takes; an error closes.
    private void flush() @trusted
    {
        import core.stdc.errno : EAGAIN, EINTR, errno, EWOULDBLOCK;
        import core.sys.posix.sys.socket : sysSend = send;

        version (linux)
            import core.sys.posix.sys.socket : MSG_NOSIGNAL;
        else
            enum MSG_NOSIGNAL = 0; // SO_NOSIGPIPE on the socket instead

        while (isOpen && tx.length)
        {
            const n = sysSend(fd, tx.ptr, tx.length, MSG_NOSIGNAL);
            if (n > 0)
            {
                tx = tx[n .. $];
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                return;
            failWith("the bus connection broke while writing");
        }
        if (!tx.length)
            tx = null; // drop the consumed prefix's storage
    }

    private bool flushUntil(MonoTime deadline) @safe
    {
        while (isOpen && tx.length)
        {
            flush();
            if (tx.length && !waitFor(deadline, writable: true))
                return failWith("timed out writing to the bus");
        }
        return isOpen;
    }

    // Moves every byte the socket has into `rx`; EOF or an error closes.
    private void fill() @trusted
    {
        import core.stdc.errno : EAGAIN, EINTR, errno, EWOULDBLOCK;
        import core.sys.posix.sys.socket : recv;

        ubyte[4096] buf;
        while (isOpen)
        {
            const n = recv(fd, buf.ptr, buf.length, 0);
            if (n > 0)
            {
                rx ~= buf[0 .. n];
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                return;
            failWith(n == 0 ? "the bus closed the connection"
                : "the bus connection broke while reading");
        }
    }

    // One complete message off `rx`, reading the socket first.
    private bool receive(out Message m) @safe
    {
        const wasOpen = isOpen;
        fill();
        size_t used;
        final switch (decodeMessage(rx, m, used))
        {
            case Decoded.incomplete:
                return false;
            case Decoded.ok:
                rx = rx[used .. $].dup;
                return true;
            case Decoded.malformed:
                if (wasOpen)
                    failWith("the bus sent a malformed message");
                return false;
        }
    }

    private bool readLine(MonoTime deadline, out string line) @safe
    {
        import std.algorithm.searching : countUntil;

        while (true)
        {
            fill();
            const end = rx.countUntil(cast(const(ubyte)[]) "\r\n");
            if (end >= 0)
            {
                line = (cast(const(char)[]) rx[0 .. end]).idup;
                rx = rx[end + 2 .. $].dup;
                return true;
            }
            if (!isOpen)
                return false;
            if (!waitReadable(deadline))
                return failWith("timed out authenticating with the bus");
        }
    }

    private bool waitReadable(MonoTime deadline) @safe => waitFor(deadline, writable: false);

    // Polls until the socket is readable (or writable), or `deadline`.
    private bool waitFor(MonoTime deadline, bool writable) @trusted
    {
        import core.stdc.errno : EINTR, errno;
        import core.sys.posix.poll : poll, POLLIN, POLLOUT, pollfd;

        while (isOpen)
        {
            const left = deadline - MonoTime.currTime;
            if (left <= Duration.zero)
                return false;
            pollfd p = {fd: fd, events: writable ? POLLOUT : POLLIN};
            const ms = cast(int) left.total!"msecs" + 1;
            const n = poll(&p, 1, ms);
            if (n > 0)
                return true;
            if (n < 0 && errno != EINTR)
                return false;
        }
        return false;
    }
}

version (unittest)
{
    /**
    A private `dbus-daemon` for a test: its own socket, no service
    activation, everything allowed. A test calls `skipTest` when `start`
    says no daemon is available.
    */
    struct PrivateBus
    {
        import std.process : Pid;

        string address;
        private Pid pid;
        private string dir;

        @disable this(this);

        /// Starts the daemon; false when `dbus-daemon` is not on `PATH`.
        bool start() @system
        {
            import std.conv : text;
            import std.file : mkdirRecurse, tempDir, write;
            import std.path : buildPath;
            import std.process : pipeProcess, ProcessException, Redirect, thisProcessID;
            import std.string : strip;

            dir = buildPath(tempDir, text("sparkles-terminal-bus-", thisProcessID,
                "-", cast(size_t) &this));
            mkdirRecurse(dir);
            const conf = buildPath(dir, "bus.conf");
            write(conf, text(
                `<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"`,
                ` "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">`,
                `<busconfig><type>session</type>`,
                `<listen>unix:path=`, buildPath(dir, "bus"), `</listen>`,
                `<auth>EXTERNAL</auth>`,
                `<policy context="default">`,
                `<allow send_destination="*" eavesdrop="true"/>`,
                `<allow eavesdrop="true"/><allow own="*"/>`,
                `</policy></busconfig>`));
            try
            {
                auto p = pipeProcess(["dbus-daemon", "--config-file=" ~ conf,
                    "--nofork", "--nopidfile", "--print-address=1"], Redirect.stdout);
                pid = p.pid;
                address = p.stdout.readln.strip;
            }
            catch (ProcessException)
                return false;
            return address.length > 0;
        }

        ~this() @system
        {
            import std.file : rmdirRecurse;
            import std.process : kill, wait;

            if (pid !is null)
            {
                kill(pid);
                wait(pid);
            }
            if (dir.length)
                try
                    rmdirRecurse(dir);
                catch (Exception)
                {
                }
        }
    }
}

///
@("dbus_conn.BusConnection.callsRepliesAndSignalsOnAPrivateBus")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    import dbus_wire : WireWriter;

    PrivateBus bus;
    if (!bus.start())
        skipTest("no dbus-daemon on PATH");

    BusConnection server, client;
    assert(server.open(bus.address, 2000.msecs), server.error);
    assert(client.open(bus.address, 2000.msecs), client.error);
    assert(server.uniqueName.length && server.uniqueName != client.uniqueName);

    // The server owns a name; the client calls it and listens to it.
    WireWriter name;
    name.str("org.sparkles.Test");
    name.u32(4); // DBUS_NAME_FLAG_DO_NOT_QUEUE
    Outgoing request = {
        destination: busName, path: busPath, iface: busName,
        member: "RequestName", signature: "su", body: name.data,
    };
    Message reply;
    assert(server.callSync(request, 2000.msecs, reply), server.error);
    client.addMatch("type='signal',interface='org.sparkles.Test'");

    WireWriter arg;
    arg.str("ping");
    Outgoing call = {
        destination: "org.sparkles.Test", path: "/", iface: "org.sparkles.Test",
        member: "Echo", signature: "s", body: arg.data,
    };
    const serial = client.send(call);
    assert(serial);

    const deadline = MonoTime.currTime + 2000.msecs;
    Message got;
    do
        assert(server.wait(got, deadline), "the call never arrived");
    while (got.member != "Echo");
    assert(got.sender == client.uniqueName);
    assert(got.bodyReader.str() == "ping");

    WireWriter answer;
    answer.str("pong");
    Outgoing ret = {
        type: MessageType.methodReturn, destination: got.sender,
        replySerial: got.serial, signature: "s", body: answer.data,
    };
    server.send(ret);
    Outgoing sig = {
        type: MessageType.signal, path: "/", iface: "org.sparkles.Test",
        member: "Changed", signature: "s", body: answer.data,
    };
    server.send(sig);

    bool sawReply, sawSignal;
    while (!(sawReply && sawSignal) && client.wait(got, deadline))
    {
        sawReply |= got.type == MessageType.methodReturn && got.replySerial == serial;
        sawSignal |= got.type == MessageType.signal && got.member == "Changed";
    }
    assert(sawReply && sawSignal);
}

///
@("dbus_conn.BusConnection.failsCleanlyWithoutABus")
@system unittest
{
    BusConnection c;
    assert(!c.open("unix:path=/nonexistent/sparkles-terminal-bus", 100.msecs));
    assert(!c.isOpen && c.error.length);
    assert(!c.open("tcp:host=localhost,port=1", 100.msecs));
    Message m;
    assert(!c.next(m));
}
