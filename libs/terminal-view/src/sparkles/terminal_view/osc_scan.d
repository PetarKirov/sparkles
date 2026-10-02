/**
The OSC payloads the VT engine leaves to its host (`TPR2`, `TPR4`, `TPR8`,
`TPR20`, `TPR21`): titles and icon strings, OSC 7 working directories,
OSC 9 / 777 / 99 notifications and OSC 52 clipboard operations.

libghostty-vt recognizes these sequences but exposes only the title as data
([protocols](../../../../../docs/specs/terminal/protocols.md)), so the host
reads the complete payloads its own $(REF OscScanner,
sparkles,terminal_view,osc_query) extracts, and parses them here. Everything
in this module is pure and allocation-free: a payload is attacker-controlled
text, so each parser bounds what it keeps and drops what it cannot validate
rather than failing.

The expected values in the tests are transcribed from the authorities —
XTerm Control Sequences (OSC 0/1/2/7/52), kitty's desktop-notifications
protocol (OSC 99), iTerm2's OSC 9 and rxvt-unicode's `777;notify` — not
produced by an encoder of ours.
*/
module sparkles.terminal_view.osc_scan;

import sparkles.base.text.utf8 : utf8SequenceLength;

@safe:

/// Byte caps on attacker-controlled text (`TPR2`, `TPR8`, `TPR20`).
enum size_t maxTitleBytes = 256;
/// ditto — an icon is one grapheme cluster; this bounds a long ZWJ sequence.
enum size_t maxIconBytes = 32;
/// ditto
enum size_t maxNotifyTitleBytes = 256;
/// ditto
enum size_t maxNotifyBodyBytes = 1024;
/// ditto — decoded bytes of one OSC 52 write.
enum size_t maxClipboardBytes = 1024 * 1024;
/// The kitty notification identifier we keep (`[a-zA-Z0-9_\-+.]`).
enum size_t maxNotifyIdBytes = 64;

// ── sanitizing ──────────────────────────────────────────────────────────────

/**
Appends the printable part of `raw` to `dst[len .. $]`, advancing `len`:
ill-formed UTF-8 and every C0 control, DEL and C1 control (U+0080–U+009F)
are dropped, and copying stops at the first code point that does not fit —
truncation happens at a code-point boundary, never inside a sequence.
Returns `false` when something was cut off for lack of room.
*/
bool appendSanitized(scope const(char)[] raw, scope char[] dst, ref size_t len)
    pure nothrow @nogc
{
    size_t i;
    while (i < raw.length)
    {
        const c = raw[i];
        size_t n = 1;
        if (c >= 0x80)
        {
            n = utf8SequenceLength(raw, i);
            if (n == 0)
            {
                ++i; // ill-formed: drop the byte
                continue;
            }
            // U+0080–U+009F are C1 controls, encoded C2 80 … C2 9F.
            if (n == 2 && c == 0xC2 && raw[i + 1] <= 0x9F)
            {
                i += 2;
                continue;
            }
        }
        else if (c < 0x20 || c == 0x7F)
        {
            ++i;
            continue;
        }
        if (len + n > dst.length)
            return false;
        dst[len .. len + n] = raw[i .. i + n];
        len += n;
        i += n;
    }
    return true;
}

/// `raw` as a pane title (`TPR2`): sanitized, at most 256 bytes. Returns
/// the length written to `dst`.
size_t sanitizeTitle(scope const(char)[] raw, ref char[maxTitleBytes] dst)
    pure nothrow @nogc
{
    size_t len;
    appendSanitized(raw, dst[], len);
    return len;
}

///
@("osc_scan.sanitizeTitle.controlsRemoved")
pure nothrow @nogc unittest
{
    char[maxTitleBytes] t;
    // ESC, BEL, DEL and a C1 CSI (U+009B) are attacker bytes, not text.
    const n = sanitizeTitle("a\x1b[31mb\x07c\x7fd\u009Be\tf", t);
    assert(t[0 .. n] == "a[31mbcdef");
}

@("osc_scan.sanitizeTitle.truncatesAtACodePoint")
pure nothrow @nogc unittest
{
    char[maxTitleBytes] t;
    // 255 ASCII bytes then a 2-byte 'é': it does not fit, so it is dropped
    // whole rather than split.
    char[300] raw = 'a';
    raw[255 .. 257] = "é";
    assert(sanitizeTitle(raw[0 .. 257], t) == 255);

    // A 1 MiB payload costs one bounded pass and keeps exactly the cap.
    static immutable char[1024 * 1024] huge = 'x';
    assert(sanitizeTitle(huge[], t) == maxTitleBytes);
}

@("osc_scan.sanitizeTitle.illFormedUtf8Dropped")
pure nothrow @nogc unittest
{
    char[maxTitleBytes] t;
    const n = sanitizeTitle("ok\xff\xc3(\xe2\x82done", t);
    assert(t[0 .. n] == "ok(done");
}

/**
`raw` as a pane icon (`TPR2`, `D21`): sanitized, then only its first grapheme
cluster, and only if that cluster is at most two cells wide. Returns the
length written to `dst` (0: no icon).
*/
size_t sanitizeIcon(scope const(char)[] raw, ref char[maxIconBytes] dst)
    pure nothrow @nogc
{
    import sparkles.base.text.grapheme : byGraphemeCluster;

    char[maxTitleBytes] clean;
    size_t cleanLen;
    appendSanitized(raw[0 .. raw.length < 4 * maxTitleBytes ? raw.length : 4 * maxTitleBytes],
        clean[], cleanLen);
    auto clusters = byGraphemeCluster(clean[0 .. cleanLen]);
    if (clusters.empty)
        return 0;
    const first = clusters.front;
    if (first.isEscape || first.width > 2 || first.slice.length > dst.length)
        return 0;
    dst[0 .. first.slice.length] = first.slice[];
    return first.slice.length;
}

///
@("osc_scan.sanitizeIcon.firstClusterOnly")
pure nothrow @nogc unittest
{
    char[maxIconBytes] i;
    assert(i[0 .. sanitizeIcon("🦀 rust", i)] == "🦀");
    // A ZWJ family is one cluster: kept whole.
    assert(i[0 .. sanitizeIcon("👨‍👩‍👧x", i)] == "👨‍👩‍👧");
    assert(i[0 .. sanitizeIcon("\x1b\x07vim", i)] == "v");
    assert(sanitizeIcon("", i) == 0);
    assert(sanitizeIcon("\x01\x02", i) == 0);
}

// ── classification ──────────────────────────────────────────────────────────

/// The OSC command number leading `payload` (`"52;c;…"` → 52), or `-1`.
int oscCommand(scope const(char)[] payload) pure nothrow @nogc
{
    int value;
    size_t i;
    for (; i < payload.length && payload[i] != ';'; ++i)
    {
        const b = payload[i];
        if (b < '0' || b > '9' || value > 100_000)
            return -1;
        value = value * 10 + (b - '0');
    }
    return i == 0 ? -1 : value;
}

/// The payload after the command number and its `;` (empty if none).
const(char)[] oscArgs(return scope const(char)[] payload) pure nothrow @nogc
{
    foreach (i, b; payload)
        if (b == ';')
            return payload[i + 1 .. $];
    return null;
}

@("osc_scan.oscCommand")
pure nothrow @nogc unittest
{
    assert(oscCommand("52;c;?") == 52);
    assert(oscCommand("0;title") == 0);
    assert(oscCommand("777;notify;a;b") == 777);
    assert(oscCommand("1") == 1);
    assert(oscCommand(";x") == -1);
    assert(oscCommand("L;x") == -1);
    assert(oscArgs("2;a;b") == "a;b");
    assert(oscArgs("2").length == 0);
}

// ── OSC 7 ───────────────────────────────────────────────────────────────────

/**
The local path an OSC 7 report names (`TPR4`), or `0` when it names none we
accept. libghostty stores the raw value of OSC 7 (`file://host/path`) and of
the bare-path forms (ConEmu `OSC 9;9`, iTerm2 `CurrentDir`): a `file:` URI is
accepted only when its host is empty, `localhost` or `localHost`, and its
path is percent-decoded; a bare value only when it is an absolute path.
Whether the path exists is the caller's check — this is pure. Returns the
length written to `dst`; a path longer than `dst`, one containing NUL or a
control byte, or a malformed escape is rejected.
*/
size_t parseWorkingDirectory(scope const(char)[] raw, scope const(char)[] localHost,
    scope char[] dst) pure nothrow @nogc
{
    import sparkles.base.text.percent : decodePercent;

    scope const(char)[] path = raw;
    enum scheme = "file://";
    if (raw.length >= scheme.length && raw[0 .. scheme.length] == scheme)
    {
        const rest = raw[scheme.length .. $];
        size_t slash;
        while (slash < rest.length && rest[slash] != '/')
            ++slash;
        const host = rest[0 .. slash];
        if (host.length && host != "localhost" && host != localHost)
            return 0;
        path = raw[scheme.length + slash .. $];
    }
    if (path.length == 0 || path[0] != '/')
        return 0;

    static struct Sink
    {
        char[] dst;
        size_t len;
        bool bad;
        void put(ubyte b) pure nothrow @nogc
        {
            if (b < 0x20 || b == 0x7F || len == dst.length)
            {
                bad = true;
                return;
            }
            dst[len++] = cast(char) b;
        }
    }

    auto sink = Sink(dst);
    if (decodePercent(sink, path).hasError || sink.bad)
        return 0;
    return sink.len;
}

///
@("osc_scan.parseWorkingDirectory.xtermForms")
pure nothrow @nogc unittest
{
    char[256] p;
    // The form shells emit (vte.sh's `__vte_osc7`, fish, zsh's chpwd hooks).
    assert(p[0 .. parseWorkingDirectory("file://box/home/me/src", "box", p)]
        == "/home/me/src");
    assert(p[0 .. parseWorkingDirectory("file:///tmp/a%20b", "box", p)] == "/tmp/a b");
    assert(p[0 .. parseWorkingDirectory("file://localhost/etc", "box", p)] == "/etc");
    // ConEmu / iTerm2 bare paths.
    assert(p[0 .. parseWorkingDirectory("/var/log", "box", p)] == "/var/log");
}

@("osc_scan.parseWorkingDirectory.foreignOrMalformedIgnored")
pure nothrow @nogc unittest
{
    char[256] p;
    assert(parseWorkingDirectory("file://elsewhere/home/me", "box", p) == 0);
    assert(parseWorkingDirectory("relative/path", "box", p) == 0);
    assert(parseWorkingDirectory("file://box", "box", p) == 0);
    assert(parseWorkingDirectory("file:///bad%2", "box", p) == 0);
    assert(parseWorkingDirectory("file:///nul%00here", "box", p) == 0);
    assert(parseWorkingDirectory("", "box", p) == 0);
    char[4] tiny;
    assert(parseWorkingDirectory("/long/path", "box", tiny) == 0);
}

// ── notifications ───────────────────────────────────────────────────────────

/// Which protocol a notification arrived by (`TPR8`, `TPG9`).
enum NotificationProtocol : ubyte
{
    osc9,   /// iTerm2's bare-text OSC 9
    osc777, /// rxvt-unicode's `777;notify;title;body`
    osc99,  /// kitty's desktop-notifications protocol
}

/**
One notification a program raised (`TPR8`): sanitized and capped text,
inline — a pointer-free value an event queue can hold by copy.
*/
struct Notification
{
    NotificationProtocol protocol;
    private char[maxNotifyTitleBytes] _title = 0;
    private char[maxNotifyBodyBytes] _body = 0;
    private char[maxNotifyIdBytes] _id = 0;
    private ushort _titleLen, _bodyLen;
    private ubyte _idLen;

    /// The title (empty for OSC 9, which carries a body only).
    const(char)[] title() const return pure nothrow @nogc => _title[0 .. _titleLen];
    /// The body.
    const(char)[] body() const return pure nothrow @nogc => _body[0 .. _bodyLen];
    /// The kitty `i=` identifier, empty when none was given.
    const(char)[] id() const return pure nothrow @nogc => _id[0 .. _idLen];

    /// Appends sanitized text to the title/body, within the caps.
    void appendTitle(scope const(char)[] s) pure nothrow @nogc
    {
        size_t l = _titleLen;
        appendSanitized(s, _title[], l);
        _titleLen = cast(ushort) l;
    }

    /// ditto
    void appendBody(scope const(char)[] s) pure nothrow @nogc
    {
        size_t l = _bodyLen;
        appendSanitized(s, _body[], l);
        _bodyLen = cast(ushort) l;
    }

    private void setId(scope const(char)[] s) pure nothrow @nogc
    {
        _idLen = cast(ubyte) s.length;
        _id[0 .. s.length] = s[];
    }

    /// A notification with neither title nor body is not one.
    bool empty() const pure nothrow @nogc => _titleLen == 0 && _bodyLen == 0;
}

/// What a notification OSC asked of the terminal.
enum NotifyOutcome : ubyte
{
    none,  /// nothing to show (unsupported, malformed, a chunk still open, ConEmu)
    ready, /// `out` holds a complete notification
    query, /// a kitty `p=?` support query; answer with $(LREF writeKittyQueryReply)
}

/**
Kitty's chunked notifications (`d=0` … `d=1`, joined by `i=`), assembled
across OSC sequences. At most `slots` notifications may be open at once; a
new one beyond that evicts the oldest, so a program cannot grow this state.
*/
struct KittyNotifyAssembler
{
    enum slots = 4;
    private Notification[slots] open;
    private bool[slots] used;
    private ulong[slots] age;
    private ulong clock;

    private size_t slotFor(scope const(char)[] id) pure nothrow @nogc
    {
        foreach (i; 0 .. slots)
            if (used[i] && open[i].id == id)
                return i;
        size_t pick = 0;
        foreach (i; 0 .. slots)
        {
            if (!used[i])
            {
                pick = i;
                break;
            }
            if (age[i] < age[pick])
                pick = i;
        }
        open[pick] = Notification.init;
        open[pick].protocol = NotificationProtocol.osc99;
        open[pick].setId(id);
        used[pick] = true;
        age[pick] = ++clock;
        return pick;
    }
}

private bool isIdentifier(scope const(char)[] s) pure nothrow @nogc
{
    if (s.length > maxNotifyIdBytes)
        return false;
    foreach (c; s)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '+' || c == '.'))
            return false;
    return true;
}

/**
Base64-decodes `text` (RFC 4648, padding optional at the end as kitty's
chunking allows) into `dst`; `-1` when it is not valid base64 or does not
fit. Returns the decoded length.
*/
ptrdiff_t decodeBase64Lenient(scope const(char)[] text, scope ubyte[] dst)
    pure nothrow @nogc
{
    import sparkles.base.text.base_codecs : decodeBase64;

    static struct Sink
    {
        ubyte[] dst;
        size_t len;
        bool full;
        void put(ubyte b) pure nothrow @nogc
        {
            if (len == dst.length)
            {
                full = true;
                return;
            }
            dst[len++] = b;
        }
    }

    auto sink = Sink(dst);
    // Missing padding is legal at a chunk's end; restore it so the strict
    // RFC 4648 decoder can check everything else.
    const pad = (4 - text.length % 4) % 4;
    if (pad == 3)
        return -1;
    bool ok;
    if (pad == 0)
        ok = !decodeBase64(sink, text).hasError;
    else
    {
        // Decode the whole groups, then the padded tail.
        const whole = text.length - (4 - pad);
        char[4] tail = '=';
        tail[0 .. 4 - pad] = text[whole .. $];
        ok = !decodeBase64(sink, text[0 .. whole]).hasError
            && !decodeBase64(sink, tail[]).hasError;
    }
    return ok && !sink.full ? cast(ptrdiff_t) sink.len : -1;
}

@("osc_scan.decodeBase64Lenient")
pure nothrow @nogc unittest
{
    ubyte[16] b;
    assert(decodeBase64Lenient("aGVsbG8=", b) == 5 && b[0 .. 5] == "hello");
    assert(decodeBase64Lenient("aGVsbG8", b) == 5 && b[0 .. 5] == "hello");
    assert(decodeBase64Lenient("", b) == 0);
    assert(decodeBase64Lenient("a", b) == -1);
    assert(decodeBase64Lenient("a$==", b) == -1);
    ubyte[2] small;
    assert(decodeBase64Lenient("aGVsbG8=", small) == -1);
}

/**
Parses one notification OSC payload — `9;…`, `777;…` or `99;…` — into
`out_` (`TPR8`). OSC 9 whose first field is a number is ConEmu's family
(progress, sleep, working directory) and is not a notification. A kitty
chunk with `d=0` is held in `kitty` until its `d=1` chunk; payload types
other than `title` and `body` (icons, buttons, `close`, `alive`) and
unknown keys are ignored, and an `e=1` chunk that is not valid base64 is
dropped. A complete notification with no title takes its body as title, as
the kitty spec displays it; one with neither is not raised.
*/
NotifyOutcome parseNotification(scope const(char)[] payload, ref KittyNotifyAssembler kitty,
    out Notification out_) pure nothrow @nogc
{
    const command = oscCommand(payload);
    const args = oscArgs(payload);
    switch (command)
    {
        case 9:
        {
            size_t f;
            while (f < args.length && args[f] >= '0' && args[f] <= '9')
                ++f;
            if (f > 0 && (f == args.length || args[f] == ';'))
                return NotifyOutcome.none; // ConEmu: OSC 9;<n>[;…]
            out_.protocol = NotificationProtocol.osc9;
            out_.appendBody(args);
            return out_.empty ? NotifyOutcome.none : NotifyOutcome.ready;
        }
        case 777:
        {
            enum ext = "notify;";
            if (args.length < ext.length || args[0 .. ext.length] != ext)
                return NotifyOutcome.none;
            const rest = args[ext.length .. $];
            size_t t;
            while (t < rest.length && rest[t] != ';')
                ++t;
            if (t == rest.length)
                return NotifyOutcome.none; // no title separator
            out_.protocol = NotificationProtocol.osc777;
            out_.appendTitle(rest[0 .. t]);
            out_.appendBody(rest[t + 1 .. $]);
            return out_.empty ? NotifyOutcome.none : NotifyOutcome.ready;
        }
        case 99:
            return parseKitty(args, kitty, out_);
        default:
            return NotifyOutcome.none;
    }
}

private NotifyOutcome parseKitty(scope const(char)[] args, ref KittyNotifyAssembler kitty,
    out Notification out_) pure nothrow @nogc
{
    size_t m;
    while (m < args.length && args[m] != ';')
        ++m;
    if (m == args.length)
        return NotifyOutcome.none; // the two semicolons are mandatory
    const meta = args[0 .. m];
    const data = args[m + 1 .. $];

    scope const(char)[] id;
    bool done = true, encoded = false;
    enum Payload { title, body, query, other }
    Payload kind = Payload.title;

    size_t i;
    while (i <= meta.length)
    {
        size_t j = i;
        while (j < meta.length && meta[j] != ':')
            ++j;
        const kvStart = i;
        const kv = meta[kvStart .. j];
        i = j + 1;
        if (kv.length < 2 || kv[1] != '=')
            continue;
        const v = kv[2 .. $];
        switch (kv[0])
        {
            case 'i':
                if (!isIdentifier(v))
                    return NotifyOutcome.none;
                id = meta[kvStart + 2 .. j]; // `v`, sliced from the longer-lived `meta`
                break;
            case 'd':
                done = v != "0";
                break;
            case 'e':
                encoded = v == "1";
                break;
            case 'p':
                kind = v == "title" ? Payload.title : v == "body" ? Payload.body
                    : v == "?" ? Payload.query : Payload.other;
                break;
            default:
                break; // unknown or unsupported keys are ignored
        }
    }

    if (kind == Payload.query)
    {
        out_.protocol = NotificationProtocol.osc99;
        out_.setId(id);
        return NotifyOutcome.query;
    }
    if (kind == Payload.other)
        return NotifyOutcome.none;

    const slot = kitty.slotFor(id);
    ubyte[maxNotifyBodyBytes * 4] decoded;
    scope const(char)[] text = data;
    if (encoded)
    {
        const len = decodeBase64Lenient(data, decoded[]);
        if (len < 0)
            text = null; // invalid base64: this chunk is dropped
        else
            text = cast(const(char)[]) decoded[0 .. len];
    }
    if (kind == Payload.title)
        kitty.open[slot].appendTitle(text);
    else
        kitty.open[slot].appendBody(text);

    if (!done)
        return NotifyOutcome.none;
    out_ = kitty.open[slot];
    kitty.used[slot] = false;
    if (out_.title.length == 0 && out_.body.length)
    {
        Notification moved;
        moved.protocol = out_.protocol;
        moved.setId(out_.id);
        moved.appendTitle(out_.body);
        out_ = moved;
    }
    return out_.empty ? NotifyOutcome.none : NotifyOutcome.ready;
}

/**
Writes kitty's answer to a `p=?` support query: the identifier echoed, the
payload types we implement (`title`, `body`) and `o=always` (we do not
implement the occasion key, which the spec requires saying so), closed with
the query's terminator.
*/
void writeKittyQueryReply(Writer)(ref Writer w, scope const(char)[] id, bool endedWithBel)
{
    import std.range.primitives : put;

    put(w, "\x1b]99;i=");
    put(w, id.length ? id : "0");
    put(w, ":p=?;p=title,body:o=always");
    put(w, endedWithBel ? "\x07" : "\x1b\\");
}

// Fixtures transcribed from the authorities. OSC 9: iTerm2's
// `ESC ] 9 ; message ST`. OSC 777: urxvt's `777;notify;title;body` as
// Ghostty's rxvt_extension parser takes it. OSC 99: kitty's
// desktop-notifications.rst, its own examples.

@("osc_scan.parseNotification.osc9BareText")
pure nothrow @nogc unittest
{
    KittyNotifyAssembler k;
    Notification n;
    assert(parseNotification("9;Build finished", k, n) == NotifyOutcome.ready);
    assert(n.protocol == NotificationProtocol.osc9);
    assert(n.title == "" && n.body == "Build finished");
    // Text that merely starts with a digit is still text.
    assert(parseNotification("9;42 tests passed", k, n) == NotifyOutcome.ready);
    assert(n.body == "42 tests passed");
}

@("osc_scan.parseNotification.osc9ConEmuIsNotANotification")
pure nothrow @nogc unittest
{
    KittyNotifyAssembler k;
    Notification n;
    assert(parseNotification("9;4;1;50", k, n) == NotifyOutcome.none); // progress
    assert(parseNotification("9;9;/home/me", k, n) == NotifyOutcome.none); // cwd
    assert(parseNotification("9;1", k, n) == NotifyOutcome.none); // sleep
    assert(parseNotification("9;", k, n) == NotifyOutcome.none);
}

@("osc_scan.parseNotification.osc777")
pure nothrow @nogc unittest
{
    KittyNotifyAssembler k;
    Notification n;
    assert(parseNotification("777;notify;Title;Body", k, n) == NotifyOutcome.ready);
    assert(n.protocol == NotificationProtocol.osc777);
    assert(n.title == "Title" && n.body == "Body");
    // The body is the rest, semicolons included.
    assert(parseNotification("777;notify;T;a;b", k, n) == NotifyOutcome.ready);
    assert(n.body == "a;b");
    assert(parseNotification("777;preexec;x", k, n) == NotifyOutcome.none);
    assert(parseNotification("777;notify;no-body-separator", k, n) == NotifyOutcome.none);
}

@("osc_scan.parseNotification.kittySimpleAndChunked")
pure nothrow @nogc unittest
{
    KittyNotifyAssembler k;
    Notification n;
    // `printf '\x1b]99;;Hello world\x1b\\'`
    assert(parseNotification("99;;Hello world", k, n) == NotifyOutcome.ready);
    assert(n.protocol == NotificationProtocol.osc99 && n.title == "Hello world");

    // `\x1b]99;i=1:d=0;Hello world\x1b\\` then `\x1b]99;i=1:p=body;This is cool\x1b\\`
    assert(parseNotification("99;i=1:d=0;Hello world", k, n) == NotifyOutcome.none);
    assert(parseNotification("99;i=1:p=body;This is cool", k, n) == NotifyOutcome.ready);
    assert(n.title == "Hello world" && n.body == "This is cool" && n.id == "1");

    // Title chunks concatenate.
    assert(parseNotification("99;i=x:d=0;Hel", k, n) == NotifyOutcome.none);
    assert(parseNotification("99;i=x:d=0;lo", k, n) == NotifyOutcome.none);
    assert(parseNotification("99;i=x;", k, n) == NotifyOutcome.ready);
    assert(n.title == "Hello");
}

@("osc_scan.parseNotification.kittyBase64AndHostileInput")
pure nothrow @nogc unittest
{
    KittyNotifyAssembler k;
    Notification n;
    // e=1: base64 of "Hi\nthere" — decoded, then the newline (a control)
    // removed, as for any payload.
    assert(parseNotification("99;e=1;SGkKdGhlcmU=", k, n) == NotifyOutcome.ready);
    assert(n.title == "Hithere");
    // Invalid base64 is dropped, not shown raw.
    assert(parseNotification("99;e=1;not*base64", k, n) == NotifyOutcome.none);
    // Unsupported payload types and keys are ignored, not errors.
    assert(parseNotification("99;i=a:p=icon:e=1;iVBORw0K", k, n) == NotifyOutcome.none);
    assert(parseNotification("99;i=a:p=buttons;Yes No", k, n) == NotifyOutcome.none);
    assert(parseNotification("99;i=a:p=close;", k, n) == NotifyOutcome.none);
    assert(parseNotification("99;u=2:s=c2lsZW50:z=9;Urgent", k, n) == NotifyOutcome.ready);
    assert(n.title == "Urgent");
    // Missing the second semicolon: malformed.
    assert(parseNotification("99;Hello", k, n) == NotifyOutcome.none);
    // An identifier outside the allowed set.
    assert(parseNotification("99;i=a b;x", k, n) == NotifyOutcome.none);
}

@("osc_scan.parseNotification.capsAndEviction")
pure nothrow @nogc unittest
{
    KittyNotifyAssembler k;
    Notification n;
    static immutable char[5000] long_ = 'b';
    static immutable payload = "777;notify;" ~ long_[0 .. 300] ~ ";" ~ long_[];
    assert(parseNotification(payload, k, n) == NotifyOutcome.ready);
    assert(n.title.length == maxNotifyTitleBytes && n.body.length == maxNotifyBodyBytes);

    // Five open chunked notifications: the oldest is evicted, so its final
    // chunk starts afresh.
    static foreach (id; ["a", "b", "c", "d", "e"])
        assert(parseNotification("99;d=0:i=" ~ id ~ ";" ~ id, k, n) == NotifyOutcome.none);
    assert(parseNotification("99;i=a;", k, n) == NotifyOutcome.none, "a was evicted");
    assert(parseNotification("99;i=e;", k, n) == NotifyOutcome.ready);
    assert(n.title == "e");
}

@("osc_scan.parseNotification.kittyQuery")
@safe pure nothrow unittest
{
    import std.array : appender;

    KittyNotifyAssembler k;
    Notification n;
    // `<OSC> 99 ; i=<some identifier> : p=? ; <terminator>`
    assert(parseNotification("99;i=xyz:p=?;", k, n) == NotifyOutcome.query);
    auto w = appender!string;
    writeKittyQueryReply(w, n.id, false);
    assert(w[] == "\x1b]99;i=xyz:p=?;p=title,body:o=always\x1b\\");
}

// ── OSC 52 ──────────────────────────────────────────────────────────────────

/// What an OSC 52 payload asks (`TPR20`, `TPR21`).
enum ClipboardOp : ubyte
{
    invalid, /// malformed, or a write whose data is not valid base64
    write,   /// set the clipboard to the decoded data
    read,    /// `?`: report the clipboard
}

/**
Parses `52;Pc;Pd` after XTerm Control Sequences ("Manipulate Selection
Data"): `Pc` is filtered to the selection letters `cpqs01234567` (each once,
in order), defaulting to `s0` when empty, and written to `selectors`; `Pd`
is `?` (a read) or base64 data, decoded into `data` (a write). Data that is
not valid base64 is `invalid` — where xterm would clear the selection, this
terminal ignores it (`TPR20`). `dataLen` receives the decoded length.
*/
ClipboardOp parseClipboard(scope const(char)[] payload, ref char[12] selectors,
    out size_t selectorsLen, scope ubyte[] data, out size_t dataLen) pure nothrow @nogc
{
    if (oscCommand(payload) != 52)
        return ClipboardOp.invalid;
    const args = oscArgs(payload);
    size_t sep;
    while (sep < args.length && args[sep] != ';')
        ++sep;
    if (sep == args.length)
        return ClipboardOp.invalid;
    static immutable string known = "cpqs01234567";
    foreach (c; sep ? args[0 .. sep] : "s0")
    {
        bool isKnown, seen;
        foreach (k; known)
            isKnown |= k == c;
        foreach (s; selectors[0 .. selectorsLen])
            seen |= s == c;
        if (isKnown && !seen)
            selectors[selectorsLen++] = c;
    }
    const pd = args[sep + 1 .. $];
    if (pd == "?")
        return ClipboardOp.read;
    const len = decodeBase64Lenient(pd, data);
    if (len < 0)
        return ClipboardOp.invalid;
    dataLen = cast(size_t) len;
    return ClipboardOp.write;
}

///
@("osc_scan.parseClipboard.xtermForms")
pure nothrow @nogc unittest
{
    char[12] sel;
    size_t selLen, dataLen;
    ubyte[64] data;
    // `printf '\e]52;c;%s\a' "$(printf hello | base64)"`
    assert(parseClipboard("52;c;aGVsbG8=", sel, selLen, data, dataLen) == ClipboardOp.write);
    assert(sel[0 .. selLen] == "c" && data[0 .. dataLen] == "hello");
    assert(parseClipboard("52;c;?", sel, selLen, data, dataLen) == ClipboardOp.read);
    assert(sel[0 .. selLen] == "c");
    // An empty Pc means `s0`; unknown letters are dropped, repeats collapse.
    assert(parseClipboard("52;;?", sel, selLen, data, dataLen) == ClipboardOp.read);
    assert(sel[0 .. selLen] == "s0");
    assert(parseClipboard("52;cxcp;?", sel, selLen, data, dataLen) == ClipboardOp.read);
    assert(sel[0 .. selLen] == "cp");
    // Empty data is a valid (empty) write.
    assert(parseClipboard("52;c;", sel, selLen, data, dataLen) == ClipboardOp.write);
    assert(dataLen == 0);
}

@("osc_scan.parseClipboard.invalidIgnored")
pure nothrow @nogc unittest
{
    char[12] sel;
    size_t selLen, dataLen;
    ubyte[8] data;
    assert(parseClipboard("52;c;!!!!", sel, selLen, data, dataLen) == ClipboardOp.invalid);
    assert(parseClipboard("52;c", sel, selLen, data, dataLen) == ClipboardOp.invalid);
    assert(parseClipboard("2;c;aGk=", sel, selLen, data, dataLen) == ClipboardOp.invalid);
    // Larger than the caller's cap: invalid, never truncated.
    assert(parseClipboard("52;c;aGVsbG8gd29ybGQ=", sel, selLen, data, dataLen)
        == ClipboardOp.invalid);
}

/// The base64 length of the largest OSC 52 write we accept.
enum size_t maxClipboardBase64 = (maxClipboardBytes + 2) / 3 * 4;
