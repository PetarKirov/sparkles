/**
A connection to a message bus: connected and authenticated synchronously,
then read as the loop finds its socket readable.

$(LREF Connection.openSession) connects to the session bus named by
`DBUS_SESSION_BUS_ADDRESS` (or `$XDG_RUNTIME_DIR/bus`), authenticates with
SASL `EXTERNAL` — the peer's credentials, read by the bus from the socket —
and says `Hello`. $(LREF Connection.call) sends a method call and waits, up
to a deadline, for its reply: what a program asks once at start. Signals and
anything else that arrives meanwhile are kept for $(LREF Connection.service),
which a program calls whenever the loop has found the socket readable
($(LREF Connection.arm)), and which hands each message to a handler.

Linux only: its socket flags are Linux's.
*/
module sparkles.dbus.connection;

version (linux):

import core.time : Duration, MonoTime, msecs;

import sparkles.base.expected : Expected, err, ok;

import sparkles.base.buffer : Buffer, Storage;
import sparkles.dbus.message : encodeMessage, Header, maxMessageLength, messageLength,
    MessageType, Parsed, parseMessage;
import sparkles.dbus.wire : Writer;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion, OpHandle, OpPollAdd, PollEvents;

/// Why a connection failed: a fixed description, and `errno` where the
/// system gave one.
struct DBusError
{
    string what; ///
    int code;    /// `errno`, or 0
}

/// A result or why there is none.
alias DBusResult(T) = Expected!(T, DBusError);

private DBusResult!T failure(T)(string what, int code = 0) @safe nothrow @nogc
    => err!T(DBusError(what, code));

/// A message received whole: its bytes, owned, and what they say.
struct Message
{
    Buffer!(ubyte, 0, cast(Storage)(Storage.heap | Storage.unique)) bytes; ///

    /// The header and a reader over the body, slicing `bytes`.
    Parsed parse() const return scope @trusted nothrow @nogc
        => parseMessage(bytes[]); // the slices live as long as `this`
}

/**
A Unix-socket address from a D-Bus address list (`unix:path=…` or
`unix:abstract=…`, alternatives separated by `;`, values %-escaped): the
first usable one, as `sun_path` bytes — a leading NUL for an abstract name.
Empty when none is.
*/
const(char)[] unixSocketPath(scope const(char)[] addresses, return ref char[108] storage)
    @safe pure nothrow @nogc
{
    while (addresses.length)
    {
        size_t end;
        while (end < addresses.length && addresses[end] != ';')
            ++end;
        auto one = addresses[0 .. end];
        addresses = end < addresses.length ? addresses[end + 1 .. $] : null;
        enum prefix = "unix:";
        if (one.length < prefix.length || one[0 .. prefix.length] != prefix)
            continue;
        one = one[prefix.length .. $];
        while (one.length)
        {
            size_t comma;
            while (comma < one.length && one[comma] != ',')
                ++comma;
            const pair = one[0 .. comma];
            one = comma < one.length ? one[comma + 1 .. $] : null;
            size_t eq;
            while (eq < pair.length && pair[eq] != '=')
                ++eq;
            if (eq == pair.length)
                continue;
            const key = pair[0 .. eq];
            const abstract_ = key == "abstract";
            if (!abstract_ && key != "path")
                continue;
            size_t n;
            if (abstract_)
                storage[n++] = '\0';
            const value = pair[eq + 1 .. $];
            bool usable = true;
            for (size_t i = 0; usable && i < value.length; ++i)
            {
                // A path keeps a byte for its NUL; an abstract name needs none.
                if (n == storage.length - (abstract_ ? 0 : 1))
                {
                    usable = false;
                    break;
                }
                char c = value[i];
                if (c == '%')
                {
                    const hi = i + 2 < value.length ? hexValue(value[i + 1]) : -1;
                    const lo = i + 2 < value.length ? hexValue(value[i + 2]) : -1;
                    if (hi < 0 || lo < 0)
                    {
                        usable = false;
                        break;
                    }
                    c = cast(char)(hi * 16 + lo);
                    i += 2;
                }
                storage[n++] = c;
            }
            // A malformed alternative gives way to the next.
            if (usable && n > (abstract_ ? 1 : 0))
                return storage[0 .. n];
            break;
        }
    }
    return null;
}

private int hexValue(char c) @safe pure nothrow @nogc
    => c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10
    : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;

///
@("dbus.connection.unixSocketPath")
@safe pure nothrow @nogc unittest
{
    char[108] buf;
    assert(unixSocketPath("unix:path=/run/user/1000/bus", buf) == "/run/user/1000/bus");
    assert(unixSocketPath("tcp:host=x;unix:path=/a%2cb,guid=00ff", buf) == "/a,b",
        "the first usable alternative, its value unescaped");
    assert(unixSocketPath("unix:abstract=/tmp/dbus-x", buf) == "\0/tmp/dbus-x");
    assert(unixSocketPath("unix:guid=1", buf) is null && unixSocketPath("", buf) is null);
    assert(unixSocketPath("unix:path=/a%2", buf) is null, "a cut escape");
    assert(unixSocketPath("unix:path=/a%2;unix:path=/good", buf) == "/good",
        "a malformed alternative gives way to the next");
}

/**
One connection to a bus. Not copyable; closed when it goes.
*/
struct Connection
{
    private int fd_ = -1;
    private uint serial_;
    private Buffer!(ubyte, 0, cast(Storage)(Storage.heap | Storage.unique)) rx_;
    private size_t rxStart_;
    // Whole messages read while waiting for a reply, one after another, for
    // `service`.
    private Buffer!(ubyte, 0, cast(Storage)(Storage.heap | Storage.unique)) held_;
    private char[64] unique_;
    private size_t uniqueLength_;
    private DefaultLoop* loop_;
    private OpHandle poll_;
    private bool armed_, ready_, servicing_;
    private DefaultLoop* wanted_;
    // Where the loop's poll writes back: the connection must stay there.
    private Connection* self_;
    private int pollResult_;

    @disable this(this);

    ~this() @trusted nothrow
    {
        close();
    }

    /// Whether the connection is open.
    bool isOpen() const @safe pure nothrow @nogc => fd_ >= 0;

    /// The unique name the bus gave the connection (`:1.42`).
    const(char)[] uniqueName() const return @safe pure nothrow @nogc
        => unique_[0 .. uniqueLength_];

    /// The socket, for a loop to watch.
    int fd() const @safe pure nothrow @nogc => fd_;

    /**
    Connects to the session bus, authenticates and says `Hello`, waiting at
    most `timeout` for the bus's answers.
    */
    static DBusResult!void openSession(out Connection c, Duration timeout = 1000.msecs)
        @trusted nothrow
    {
        import core.stdc.stdlib : getenv;
        import core.stdc.string : strlen;

        char[108] storage;
        const(char)[] path;
        if (auto env = getenv("DBUS_SESSION_BUS_ADDRESS"))
            path = unixSocketPath(env[0 .. strlen(env)], storage);
        // Where the address names no Unix socket we can use, the systemd
        // user bus's.
        if (path.length == 0)
            if (auto runtime = getenv("XDG_RUNTIME_DIR"))
        {
            const dir = runtime[0 .. strlen(runtime)];
            enum tail = "/bus";
            if (dir.length + tail.length <= storage.length)
            {
                storage[0 .. dir.length] = dir[];
                storage[dir.length .. dir.length + tail.length] = tail[];
                path = storage[0 .. dir.length + tail.length];
            }
        }
        if (path.length == 0)
            return failure!void("no session bus address");
        return open(c, path, timeout);
    }

    /// Connects to the bus at the Unix socket `path` (`sun_path` bytes), as
    /// $(LREF openSession) does.
    static DBusResult!void open(out Connection c, scope const(char)[] path,
        Duration timeout = 1000.msecs) @trusted nothrow
    {
        import core.stdc.errno : EAGAIN, EINPROGRESS, EINTR, errno;
        import core.sys.posix.poll : poll, pollfd, POLLOUT;
        import core.sys.posix.sys.socket : AF_UNIX, connect, getsockopt, sockaddr, socket,
            SOCK_STREAM, SOL_SOCKET, SO_ERROR, socklen_t;
        import core.sys.posix.sys.un : sockaddr_un;
        import core.sys.posix.unistd : close_ = close;

        const deadline = MonoTime.currTime + timeout;
        enum SOCK_CLOEXEC = 0x80000, SOCK_NONBLOCK = 0x800;
        sockaddr_un address;
        const abstract_ = path.length > 0 && path[0] == '\0';
        if (path.length == 0 || path.length > address.sun_path.length
            || (!abstract_ && path.length == address.sun_path.length))
            return failure!void("the bus's socket path is too long");
        address.sun_family = AF_UNIX;
        foreach (i, ch; path)
            address.sun_path[i] = ch;
        // Non-blocking from the start, so even a bus that never accepts
        // keeps to the deadline.
        const fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (fd < 0)
            return failure!void("socket failed", errno);
        const length = cast(uint)(sockaddr_un.sun_path.offsetof + path.length
            + (abstract_ ? 0 : 1));
        int code;
        while (connect(fd, cast(sockaddr*) &address, length) != 0)
        {
            code = errno;
            if (code == EINTR)
                continue;
            if (code != EINPROGRESS && code != EAGAIN)
                break;
            // Wait for the connection, then ask how it went.
            code = 0;
            auto p = pollfd(fd, POLLOUT, 0);
            int ready;
            for (;;)
            {
                const left = deadline - MonoTime.currTime;
                if (left <= Duration.zero)
                    break;
                ready = poll(&p, 1, cast(int) left.total!"msecs" + 1);
                if (ready >= 0 || errno != EINTR)
                    break;
            }
            if (ready <= 0)
            {
                close_(fd);
                return failure!void("the bus did not accept the connection in time");
            }
            socklen_t size = code.sizeof;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) != 0)
                code = errno;
            break;
        }
        if (code != 0)
        {
            close_(fd);
            return failure!void("connect to the bus failed", code);
        }
        return adopt(c, fd, deadline - MonoTime.currTime);
    }

    /**
    Takes `fd`, a stream socket connected to a bus, and authenticates and
    says `Hello` over it: what $(LREF open) does once connected, and what a
    test does over one end of a socket pair.
    */
    static DBusResult!void adopt(out Connection c, int fd, Duration timeout = 1000.msecs)
        @trusted nothrow
    {
        import core.sys.posix.unistd : getuid;

        c.fd_ = fd;
        const deadline = MonoTime.currTime + timeout;
        // Closed again on any failure: half a connection is none.
        bool done;
        scope (exit)
            if (!done)
                c.close();
        // SASL: a NUL, `AUTH EXTERNAL` with the uid in hex-encoded decimal,
        // `OK <guid>` back, then `BEGIN`; the binary protocol follows.
        char[64] line;
        size_t n;
        line[n++] = '\0';
        foreach (ch; "AUTH EXTERNAL ")
            line[n++] = ch;
        char[16] digits;
        size_t d;
        for (uint uid = getuid(); ; uid /= 10)
        {
            digits[d++] = cast(char)('0' + uid % 10);
            if (uid < 10)
                break;
        }
        enum hex = "0123456789abcdef";
        while (d)
        {
            const ch = digits[--d];
            line[n++] = hex[ch >> 4];
            line[n++] = hex[ch & 15];
        }
        line[n++] = '\r';
        line[n++] = '\n';
        auto sent = c.writeAll(cast(const(ubyte)[]) line[0 .. n], deadline);
        if (sent.hasError)
            return failure!void(sent.error.what, sent.error.code);
        auto answer = c.readLine(deadline);
        if (answer.hasError)
            return failure!void(answer.error.what, answer.error.code);
        const reply = answer.value;
        if (reply.length < 3 || reply[0 .. 3] != "OK ")
            return failure!void("the bus refused EXTERNAL authentication");
        auto begun = c.writeAll(cast(const(ubyte)[]) "BEGIN\r\n", deadline);
        if (begun.hasError)
            return failure!void(begun.error.what, begun.error.code);

        auto hello = c.call(Header(type: MessageType.methodCall, destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus", iface: "org.freedesktop.DBus", member: "Hello"),
            null, deadline - MonoTime.currTime);
        if (hello.hasError)
            return failure!void(hello.error.what, hello.error.code);
        auto parsed = hello.value.parse();
        if (parsed.header.type != MessageType.methodReturn || parsed.header.signature != "s")
            return failure!void("the bus did not answer Hello");
        const name = parsed.body.str();
        if (parsed.body.failed || name.length > c.unique_.length)
            return failure!void("the bus's Hello reply is malformed");
        c.unique_[0 .. name.length] = name[];
        c.uniqueLength_ = name.length;
        done = true;
        return ok!DBusError();
    }

    /// Closes the connection, cancelling its poll.
    void close() @trusted nothrow
    {
        import core.sys.posix.unistd : close_ = close;

        disarm();
        if (fd_ >= 0)
            close_(fd_);
        fd_ = -1;
    }

    /**
    Sends `header` with `body` (marshalled for `header.signature`); the
    serial is the connection's next, and returned.
    */
    DBusResult!uint send(Header header, scope const(ubyte)[] body,
        Duration timeout = 1000.msecs) @trusted nothrow
    {
        if (fd_ < 0)
            return failure!uint("the connection is closed");
        header.serial = ++serial_;
        if (serial_ == uint.max)
            serial_ = 0;
        Writer w;
        encodeMessage(w, header, body);
        auto sent = writeAll(w.data, MonoTime.currTime + timeout);
        if (sent.hasError)
            return failure!uint(sent.error.what, sent.error.code);
        return ok!DBusError(header.serial);
    }

    /**
    Sends a method call and waits up to `timeout` for its reply — a return
    or an error. What arrives meanwhile is kept for $(LREF service).
    */
    DBusResult!Message call(Header header, scope const(ubyte)[] body,
        Duration timeout = 1000.msecs) @trusted nothrow
    {
        const deadline = MonoTime.currTime + timeout;
        header.type = MessageType.methodCall;
        auto sent = send(header, body, timeout);
        if (sent.hasError)
            return failure!Message(sent.error.what, sent.error.code);
        return waitReply(sent.value, deadline - MonoTime.currTime);
    }

    /**
    Waits up to `timeout` for the reply to the call sent as `serial`. What
    arrives meanwhile is kept for $(LREF service); a reply that comes after
    the wait gave up reaches the handler there.
    */
    DBusResult!Message waitReply(uint serial, Duration timeout) @trusted nothrow
    {
        const deadline = MonoTime.currTime + timeout;
        for (;;)
        {
            Message m;
            const got = takeMessage(m);
            if (got.hasError)
                return failure!Message(got.error.what, got.error.code);
            if (got.value)
            {
                const p = m.parse();
                if ((p.header.type == MessageType.methodReturn
                    || p.header.type == MessageType.error)
                    && p.header.replySerial == serial)
                    return ok!DBusError(move(m));
                foreach (b; m.bytes[])
                    held_ ~= b;
                continue;
            }
            const waited = waitReadable(deadline);
            if (waited.hasError)
                return failure!Message(waited.error.what, waited.error.code);
            const read = fill();
            if (read.hasError)
                return failure!Message(read.error.what, read.error.code);
        }
    }

    /// Asks the bus to route to the connection the messages `rule` matches
    /// (`type='signal',interface='…'`), without waiting for its answer.
    DBusResult!void addMatch(scope const(char)[] rule, Duration timeout = 1000.msecs)
        @trusted nothrow
    {
        Writer body;
        body.str(rule);
        auto sent = send(Header(type: MessageType.methodCall,
            flags: 1 /* no reply expected */, destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus", iface: "org.freedesktop.DBus", member: "AddMatch",
            signature: "s"), body.data, timeout);
        if (sent.hasError)
            return failure!void(sent.error.what, sent.error.code);
        return ok!DBusError();
    }

    /**
    Has `loop` tell the connection when its socket is readable. A program
    then calls $(LREF service) after each turn of the loop, and
    $(LREF close)s the connection before the loop goes: the loop holds the
    poll, and the connection's address, until then. The connection must not
    move while armed.
    */
    DBusResult!void arm(ref DefaultLoop loop) @trusted nothrow
    {
        wanted_ = &loop; // retried by `service` if the loop cannot take it now
        if (armed_)
            return loop_ is &loop ? ok!DBusError()
                : failure!void("the connection is polled by another loop");
        if (fd_ < 0)
            return failure!void("the connection is closed");
        auto submitted = loop.submit(OpPollAdd(fd_, PollEvents.readable, false), &onReady, &this);
        if (submitted.hasError)
            return failure!void("could not poll the bus's socket", submitted.error.code);
        loop_ = &loop;
        self_ = &this;
        poll_ = submitted.value;
        armed_ = true;
        return ok!DBusError();
    }

    /**
    Hands `handler` each message kept while a call waited, then each one
    the socket holds once the loop found it readable, and polls again.
    `false` when the connection failed (and is closed). A message's slices
    are valid during the handler's call only, which must not use the
    connection.
    */
    bool service(scope void delegate(ref Parsed) nothrow handler) @trusted nothrow
    in (!armed_ || self_ is &this, "an armed connection moved: the loop writes to where it was")
    {
        if (servicing_)
            return fd_ >= 0; // a handler's own call: the outer one goes on
        servicing_ = true;
        scope (exit)
            servicing_ = false;
        for (size_t at = 0; at < held_.length;)
        {
            const length = messageLength(held_[][at .. $]);
            auto p = parseMessage(held_[][at .. at + length]);
            handler(p);
            at += length;
        }
        held_.clear();
        if (!ready_)
        {
            // A poll the loop could not take before is asked for again.
            if (!armed_ && fd_ >= 0 && wanted_ !is null)
                cast(void) arm(*wanted_);
            return fd_ >= 0;
        }
        ready_ = false;
        armed_ = false;
        if (pollResult_ < 0 || fill().hasError)
        {
            close();
            return false;
        }
        for (;;)
        {
            Message m;
            const got = takeMessage(m);
            if (got.hasError)
            {
                close();
                return false;
            }
            if (!got.value)
                break;
            auto p = m.parse();
            handler(p);
        }
        // Not armed again now is retried by the next call.
        if (wanted_ !is null)
            cast(void) arm(*wanted_);
        return fd_ >= 0;
    }

    /// Whether a poll the loop holds is outstanding.
    bool isArmed() const @safe pure nothrow @nogc => armed_ && !ready_;

    private static void onReady(void* context, ref Completion completion) nothrow @nogc
    {
        auto c = cast(Connection*) context;
        c.ready_ = true;
        c.pollResult_ = completion.res;
    }

    // Cancels the loop's poll, unless it completed already. Not from inside
    // a completion callback: the loop cannot wait on itself there.
    private void disarm() @trusted nothrow
    {
        if (armed_ && !ready_ && loop_ !is null)
            cast(void) loop_.cancelAndWait(poll_);
        armed_ = ready_ = false;
        loop_ = wanted_ = null;
        self_ = null;
    }

    // The next whole message in the received bytes, if there is one.
    private DBusResult!bool takeMessage(out Message m) @trusted nothrow
    {
        const pending = rx_[][rxStart_ .. $];
        const length = messageLength(pending);
        if (length == size_t.max)
            return failure!bool("the bus sent a malformed message");
        if (length == 0 || length > pending.length)
        {
            // Unread bytes move to the front once nothing before them is.
            if (rxStart_ > 0)
            {
                foreach (i, b; pending)
                    rx_[i] = b;
                rx_.length = pending.length;
                rxStart_ = 0;
            }
            return ok!DBusError(false);
        }
        m.bytes.reserve(length);
        foreach (b; pending[0 .. length])
            m.bytes ~= b;
        rxStart_ += length;
        if (!m.parse().ok)
            return failure!bool("the bus sent a malformed message");
        return ok!DBusError(true);
    }

    // Reads what the socket holds without blocking.
    private DBusResult!void fill() @trusted nothrow
    {
        import core.stdc.errno : EAGAIN, EINTR, errno, EWOULDBLOCK;
        import core.sys.posix.sys.socket : recv;

        enum MSG_DONTWAIT = 0x40; // Linux; druntime does not declare it
        ubyte[4096] chunk;
        for (;;)
        {
            const n = recv(fd_, chunk.ptr, chunk.length, MSG_DONTWAIT);
            if (n > 0)
            {
                if (rx_.length + n > maxMessageLength * 2)
                    return failure!void("the bus sent more than a message can hold");
                foreach (b; chunk[0 .. n])
                    rx_ ~= b;
                if (n < chunk.length)
                    return ok!DBusError();
                continue;
            }
            if (n == 0)
                return failure!void("the bus closed the connection");
            const code = errno;
            if (code == EINTR)
                continue;
            if (code == EAGAIN || code == EWOULDBLOCK)
                return ok!DBusError();
            return failure!void("reading from the bus failed", code);
        }
    }

    // One `\r\n`-ended line of the authentication exchange.
    private DBusResult!(const(char)[]) readLine(MonoTime deadline) return @trusted nothrow
    {
        for (;;)
        {
            const bytes = rx_[];
            foreach (i; 1 .. bytes.length)
                if (bytes[i - 1] == '\r' && bytes[i] == '\n')
                {
                    // The line stays in `rx_` until the binary protocol
                    // starts, and is dropped then.
                    rxStart_ = i + 1;
                    return ok!DBusError(cast(const(char)[]) bytes[0 .. i - 1]);
                }
            if (bytes.length > 512)
                return failure!(const(char)[])("the bus's authentication line is too long");
            const waited = waitReadable(deadline);
            if (waited.hasError)
                return failure!(const(char)[])(waited.error.what, waited.error.code);
            const read = fill();
            if (read.hasError)
                return failure!(const(char)[])(read.error.what, read.error.code);
        }
    }

    private DBusResult!void waitReadable(MonoTime deadline) @trusted nothrow
    {
        import core.stdc.errno : EINTR, errno;
        import core.sys.posix.poll : poll, pollfd, POLLIN;

        for (;;)
        {
            const left = deadline - MonoTime.currTime;
            if (left <= Duration.zero)
                return failure!void("the bus did not answer in time");
            auto p = pollfd(fd_, POLLIN, 0);
            const r = poll(&p, 1, cast(int) left.total!"msecs" + 1);
            if (r > 0)
                return ok!DBusError();
            if (r < 0 && errno != EINTR)
                return failure!void("waiting for the bus failed", errno);
        }
    }

    private DBusResult!void writeAll(scope const(ubyte)[] bytes, MonoTime deadline)
        @trusted nothrow
    {
        import core.stdc.errno : EAGAIN, EINTR, errno, EWOULDBLOCK;
        import core.sys.posix.poll : poll, pollfd, POLLOUT;
        import core.sys.posix.sys.socket : send_ = send;

        enum MSG_NOSIGNAL = 0x4000, MSG_DONTWAIT = 0x40; // Linux
        while (bytes.length)
        {
            const n = send_(fd_, bytes.ptr, bytes.length, MSG_DONTWAIT | MSG_NOSIGNAL);
            if (n > 0)
            {
                bytes = bytes[n .. $];
                continue;
            }
            const code = errno;
            if (code == EINTR)
                continue;
            if (code != EAGAIN && code != EWOULDBLOCK)
                return failure!void("writing to the bus failed", code);
            const left = deadline - MonoTime.currTime;
            if (left <= Duration.zero)
                return failure!void("the bus did not take the message in time");
            auto p = pollfd(fd_, POLLOUT, 0);
            poll(&p, 1, cast(int) left.total!"msecs" + 1);
        }
        return ok!DBusError();
    }
}

private auto move(T)(ref T value) @trusted
{
    import core.lifetime : move_ = move;

    return move_(value);
}

version (unittest)
{
    // One end of a socket pair for the connection, the other for a test
    // playing the bus: what the bus says is written before it is asked.
    private struct FakeBus
    {
        int client = -1, bus = -1;
        uint serial;

        static FakeBus make() @trusted
        {
            import core.sys.posix.sys.socket : AF_UNIX, SOCK_STREAM, socketpair;

            int[2] fds;
            assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
            return FakeBus(fds[0], fds[1]);
        }

        void say(scope const(ubyte)[] bytes) @trusted
        {
            import core.sys.posix.unistd : write;

            assert(write(bus, bytes.ptr, bytes.length) == bytes.length);
        }

        void reply(MessageType type, uint replySerial, string signature,
            scope void delegate(ref Writer) @safe body_ = null, string errorName = null) @safe
        {
            Writer b;
            if (body_ !is null)
                body_(b);
            Writer m;
            encodeMessage(m, Header(type: type, serial: ++serial, replySerial: replySerial,
                sender: "org.freedesktop.DBus", errorName: errorName, signature: signature),
                b.data);
            say(m.data);
        }

        void signal(string member) @safe
        {
            Writer m;
            encodeMessage(m, Header(type: MessageType.signal, serial: ++serial,
                path: "/org/freedesktop/portal/desktop",
                iface: "org.freedesktop.portal.Settings", member: member), null);
            say(m.data);
        }

        // Everything the connection has written so far.
        ubyte[] heard() @trusted
        {
            import core.sys.posix.sys.socket : recv;

            ubyte[] all;
            ubyte[1024] chunk;
            for (;;)
            {
                const n = recv(bus, chunk.ptr, chunk.length, 0x40 /* MSG_DONTWAIT */);
                if (n <= 0)
                    return all;
                all ~= chunk[0 .. n];
            }
        }

        void close() @trusted
        {
            import core.sys.posix.unistd : close_ = close;

            close_(bus);
        }
    }

    private void welcome(ref FakeBus bus) @safe
    {
        bus.say(cast(const(ubyte)[]) "OK 0123456789abcdef0123456789abcdef\r\n");
    }
}

@("dbus.connection.authenticatesAndSaysHello")
@system unittest
{
    auto bus = FakeBus.make();
    scope (exit)
        bus.close();
    welcome(bus);
    bus.reply(MessageType.methodReturn, 1, "s", (ref Writer w) { w.str(":1.7"); });

    Connection c;
    const opened = Connection.adopt(c, bus.client);
    assert(!opened.hasError, opened.hasError ? opened.error.what : null);
    assert(c.uniqueName == ":1.7");

    const heard = bus.heard();
    assert(heard[0] == 0, "a NUL first");
    const text = cast(const(char)[]) heard;
    size_t begin;
    foreach (i; 0 .. text.length - 7)
        if (text[i .. i + 7] == "BEGIN\r\n")
        {
            begin = i + 7;
            break;
        }
    assert(text[1 .. 15] == "AUTH EXTERNAL " && begin > 0);
    const hello = parseMessage(heard[begin .. $]);
    assert(hello.ok && hello.header.member == "Hello" && hello.header.serial == 1);
    assert(hello.header.destination == "org.freedesktop.DBus");
}

@("dbus.connection.aSignalWhileACallWaitsIsServicedAfter")
@system unittest
{
    auto bus = FakeBus.make();
    scope (exit)
        bus.close();
    welcome(bus);
    bus.signal("SettingChanged"); // before Hello's reply
    bus.reply(MessageType.methodReturn, 1, "s", (ref Writer w) { w.str(":1.8"); });
    Connection c;
    assert(!Connection.adopt(c, bus.client).hasError);

    const(char)[][4] members;
    size_t seen;
    assert(c.service((ref Parsed p) nothrow { members[seen++] = p.header.member.idup; }));
    assert(seen == 1 && members[0] == "SettingChanged");
}

@("dbus.connection.anErrorReplyAndATimeout")
@system unittest
{
    auto bus = FakeBus.make();
    scope (exit)
        bus.close();
    welcome(bus);
    bus.reply(MessageType.methodReturn, 1, "s", (ref Writer w) { w.str(":1.9"); });
    Connection c;
    assert(!Connection.adopt(c, bus.client).hasError);

    bus.reply(MessageType.error, 2, "s", (ref Writer w) { w.str("no such key"); },
        "org.freedesktop.portal.Error.NotFound");
    auto failed = c.call(Header(destination: "org.freedesktop.portal.Desktop",
        path: "/org/freedesktop/portal/desktop", iface: "org.freedesktop.portal.Settings",
        member: "ReadOne"), null);
    assert(!failed.hasError);
    const p = failed.value.parse();
    assert(p.header.type == MessageType.error
        && p.header.errorName == "org.freedesktop.portal.Error.NotFound");

    auto silent = c.call(Header(destination: "a.b", path: "/", member: "Nothing"), null,
        30.msecs);
    assert(silent.hasError && silent.error.what == "the bus did not answer in time");
}

@("dbus.connection.refusedAuthentication")
@system unittest
{
    auto bus = FakeBus.make();
    scope (exit)
        bus.close();
    bus.say(cast(const(ubyte)[]) "REJECTED EXTERNAL\r\n");
    Connection c;
    const opened = Connection.adopt(c, bus.client);
    assert(opened.hasError && opened.error.what == "the bus refused EXTERNAL authentication");
}

@("dbus.connection.liveSessionBus")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    Connection c;
    const opened = Connection.openSession(c);
    if (opened.hasError)
        return skipTest("no session bus: " ~ opened.error.what);
    assert(c.uniqueName.length > 1 && c.uniqueName[0] == ':');
    auto id = c.call(Header(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
        iface: "org.freedesktop.DBus", member: "GetId"), null);
    assert(!id.hasError);
    auto p = id.value.parse();
    assert(p.header.type == MessageType.methodReturn && p.body.str().length == 32);
}
