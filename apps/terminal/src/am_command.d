/**
The `am` requests nix-on-droid's Android-integration tools send
(docs/specs/terminal/android.md, `NOD13`), decoded. Termux runs a full `am`
inside its Java process; this app has none, so it recognises the handful of
commands `termux-am`, `termux-open`, `termux-open-url`, `termux-wake-lock`,
`termux-wake-unlock`, `termux-reload-settings` and `termux-setup-storage`
send, and refuses the rest with a message. Pure, and host-tested; the socket
and the JNI calls are `am_server.d`'s.

The wire format is termux-am-socket's: the client sends its argv as one
string, each word quoted by bash's `printf %q`, and shuts down its write side;
the server answers `<exit code>\0<stdout>\0<stderr>\0`.
*/
module am_command;

/**
Split a `printf %q`-quoted command line back into words: backslash escapes,
single and double quotes, and `$'…'` ANSI-C quoting (which `%q` uses for
control characters). `false` on an unterminated quote.
*/
bool unquoteShellWords(const(char)[] s, out string[] words) @safe pure
{
    char[] cur;
    bool inWord;
    size_t i;
    void end()
    {
        if (inWord)
            words ~= cur.idup;
        cur = null;
        inWord = false;
    }

    while (i < s.length)
    {
        const c = s[i];
        if (c == ' ' || c == '\t' || c == '\n')
        {
            end();
            ++i;
            continue;
        }
        inWord = true;
        if (c == '\\')
        {
            if (i + 1 < s.length)
                cur ~= s[i + 1];
            i += 2;
        }
        else if (c == '\'')
        {
            const close = indexFrom(s, '\'', i + 1);
            if (close < 0)
                return false;
            cur ~= s[i + 1 .. close];
            i = close + 1;
        }
        else if (c == '"')
        {
            ++i;
            for (;;)
            {
                if (i >= s.length)
                    return false;
                if (s[i] == '"')
                    break;
                if (s[i] == '\\' && i + 1 < s.length
                    && (s[i + 1] == '"' || s[i + 1] == '\\' || s[i + 1] == '$' || s[i + 1] == '`'))
                    ++i;
                cur ~= s[i++];
            }
            ++i;
        }
        else if (c == '$' && i + 1 < s.length && s[i + 1] == '\'')
        {
            i += 2;
            for (;;)
            {
                if (i >= s.length)
                    return false;
                if (s[i] == '\'')
                    break;
                if (s[i] == '\\' && i + 1 < s.length)
                {
                    const e = s[i + 1];
                    i += 2;
                    switch (e)
                    {
                        case 'n': cur ~= '\n'; break;
                        case 't': cur ~= '\t'; break;
                        case 'r': cur ~= '\r'; break;
                        case 'e', 'E': cur ~= '\x1b'; break;
                        case 'a': cur ~= '\a'; break;
                        case 'b': cur ~= '\b'; break;
                        case 'x':
                            uint v;
                            size_t n;
                            while (n < 2 && i < s.length && hexValue(s[i]) >= 0)
                            {
                                v = v * 16 + hexValue(s[i]);
                                ++i;
                                ++n;
                            }
                            cur ~= cast(char) v;
                            break;
                        default:
                            if (e >= '0' && e <= '7')
                            {
                                uint v = e - '0';
                                size_t n = 1;
                                while (n < 3 && i < s.length && s[i] >= '0' && s[i] <= '7')
                                {
                                    v = v * 8 + (s[i] - '0');
                                    ++i;
                                    ++n;
                                }
                                cur ~= cast(char) v;
                            }
                            else
                                cur ~= e; // \\ \' \" and anything else: itself
                    }
                }
                else
                    cur ~= s[i++];
            }
            ++i;
        }
        else
            cur ~= s[i++];
    }
    end();
    return true;
}

///
@("am_command.unquoteShellWords")
@safe pure unittest
{
    string[] w;
    // What `printf '%q ' start -a android.intent.action.VIEW -d 'https://x/?a=1&b=2'` gives.
    assert(unquoteShellWords(`start -a android.intent.action.VIEW -d https://x/\?a=1\&b=2 `, w));
    assert(w == ["start", "-a", "android.intent.action.VIEW", "-d", "https://x/?a=1&b=2"]);

    assert(unquoteShellWords(`-d /sdcard/My\ File.txt 'it''s' "a \"b\""`, w));
    assert(w == ["-d", "/sdcard/My File.txt", "its", `a "b"`]);

    assert(unquoteShellWords(`$'line\nbreak' $'\x41\101'`, w));
    assert(w == ["line\nbreak", "AA"]);

    assert(unquoteShellWords("", w) && w.length == 0);
    assert(!unquoteShellWords(`'open`, w));
}

private ptrdiff_t indexFrom(const(char)[] s, char c, size_t from) @safe pure nothrow @nogc
{
    foreach (j; from .. s.length)
        if (s[j] == c)
            return j;
    return -1;
}

private int hexValue(char c) @safe pure nothrow @nogc
    => c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10
        : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;

/// An `am` command line, parsed as far as the tools use it.
struct AmCommand
{
    string verb; /// `start`, `broadcast`, `startservice`, ...
    string action; /// `-a`
    string data; /// `-d`
    string mimeType; /// `-t`
    string component; /// `-n`, or a bare trailing package name
    string[string] stringExtras; /// `--es key value`
    bool[string] boolExtras; /// `--ez key value`
}

/// Parse `am`'s argv (after unquoting). Unknown options are skipped with
/// their argument when they take one (`--user N`, `-f N`, `--ei k v`, ...).
AmCommand parseAmCommand(const string[] args) @safe pure
{
    AmCommand c;
    if (args.length == 0)
        return c;
    c.verb = args[0];
    size_t i = 1;
    string next()
    {
        return i < args.length ? args[i++] : null;
    }

    while (i < args.length)
    {
        const a = args[i++];
        switch (a)
        {
            case "-a": c.action = next(); break;
            case "-d": c.data = next(); break;
            case "-t": c.mimeType = next(); break;
            case "-n": c.component = next(); break;
            case "--es":
                const k = next();
                c.stringExtras[k] = next();
                break;
            case "--ez":
                const k = next();
                c.boolExtras[k] = next() == "true";
                break;
            case "--user", "-f", "-c", "-p":
                cast(void) next();
                break;
            case "--ei", "--el", "--ef", "--eu", "--ecn", "--esa", "--eia":
                cast(void) next();
                cast(void) next();
                break;
            default:
                if (a.length && a[0] != '-')
                    c.component = a; // `am broadcast ... <package>`
        }
    }
    return c;
}

/// What the app should do for an `am` request.
enum AmRequestKind
{
    openUrl, /// `am start -a VIEW -d <url>`, or `termux-open <url>`
    openFile, /// `termux-open <file>` — needs a ContentProvider; refused
    reloadSettings, /// `termux-reload-settings`
    setupStorage, /// `termux-setup-storage`
    wakeLock, /// `termux-wake-lock`
    wakeUnlock, /// `termux-wake-unlock`
    unsupported,
}

/// A classified request.
struct AmRequest
{
    AmRequestKind kind;
    string target; /// the URL or file (`openUrl`/`openFile`)
    string mimeType;
    bool chooser; /// `termux-open --chooser`
}

/// Map a parsed command onto what this app implements.
AmRequest classify(const AmCommand c) @safe pure
{
    import std.algorithm.searching : endsWith, startsWith;

    AmRequest r;
    if (c.verb == "startservice")
    {
        r.kind = c.action.endsWith("service_wake_lock") ? AmRequestKind.wakeLock
            : c.action.endsWith("service_wake_unlock") ? AmRequestKind.wakeUnlock
            : AmRequestKind.unsupported;
        return r;
    }
    if (c.verb == "broadcast" && c.action.endsWith(".app.reload_style"))
    {
        // The extra's key carries the package the tools were built for
        // (`<package>.app.reload_style`), like the action does.
        r.kind = AmRequestKind.reloadSettings;
        foreach (key, value; c.stringExtras)
            if (key.endsWith(".app.reload_style") && value == "storage")
                r.kind = AmRequestKind.setupStorage;
        return r;
    }
    if (c.verb == "broadcast" && c.component.endsWith("TermuxOpenReceiver"))
    {
        r.target = c.data;
        r.kind = isUrl(c.data) ? AmRequestKind.openUrl : AmRequestKind.openFile;
        if (auto t = "content-type" in c.stringExtras)
            r.mimeType = *t;
        if (auto ch = "chooser" in c.boolExtras)
            r.chooser = *ch;
        return r;
    }
    if (c.verb == "start" && c.action == "android.intent.action.VIEW" && isUrl(c.data))
    {
        r.kind = AmRequestKind.openUrl;
        r.target = c.data;
        r.mimeType = c.mimeType;
        return r;
    }
    r.kind = AmRequestKind.unsupported;
    return r;
}

/// A URL another app can open by itself (a scheme other than `file`).
bool isUrl(const(char)[] s) @safe pure nothrow @nogc
{
    import std.ascii : isAlpha, isAlphaNum;

    if (s.length < 3 || !s[0].isAlpha)
        return false;
    foreach (i, c; s)
    {
        if (c == ':')
            return i > 0 && s[0 .. i] != "file";
        if (!(c.isAlphaNum || c == '+' || c == '-' || c == '.'))
            return false;
    }
    return false;
}

///
@("am_command.classify")
@safe pure unittest
{
    AmRequest req(string line)
    {
        string[] w;
        assert(unquoteShellWords(line, w));
        return classify(parseAmCommand(w));
    }

    // The exact shapes nix-on-droid's patched termux-tools send.
    auto open = req(`broadcast --user 0 -a android.intent.action.VIEW -n com.termux/com.termux.app.TermuxOpenReceiver --es content-type image/png --ez chooser true -d /data/f.png`);
    assert(open.kind == AmRequestKind.openFile && open.target == "/data/f.png");
    assert(open.mimeType == "image/png" && open.chooser);

    auto link = req(`broadcast --user 0 -a android.intent.action.VIEW -n com.termux/com.termux.app.TermuxOpenReceiver -d https://nixos.org`);
    assert(link.kind == AmRequestKind.openUrl && link.target == "https://nixos.org");

    assert(req(`start --user 0 -a android.intent.action.VIEW -d https://nixos.org`).kind == AmRequestKind.openUrl);
    assert(req(`startservice --user 0 -a com.termux.service_wake_lock dev.sparkles.nix/com.termux.app.TermuxService`).kind == AmRequestKind.wakeLock);
    assert(req(`startservice --user 0 -a com.termux.service_wake_unlock dev.sparkles.nix/com.termux.app.TermuxService`).kind == AmRequestKind.wakeUnlock);
    assert(req(`broadcast --user 0 -a dev.sparkles.nix.app.reload_style dev.sparkles.nix`).kind == AmRequestKind.reloadSettings);
    assert(req(`broadcast --user 0 --es com.termux.app.reload_style storage -a dev.sparkles.nix.app.reload_style dev.sparkles.nix`).kind == AmRequestKind.setupStorage);
    // Verbatim from the script nix-on-droid builds for dev.sparkles.nix.
    assert(req(`broadcast --user 0 --es dev.sparkles.nix.app.reload_style storage -a dev.sparkles.nix.app.reload_style dev.sparkles.nix`).kind == AmRequestKind.setupStorage);
    assert(req(`force-stop com.example`).kind == AmRequestKind.unsupported);
    assert(req(`start -a android.intent.action.VIEW -d file:///x`).kind == AmRequestKind.unsupported);
}

/// The reply termux-am-socket expects: `<code>\0<stdout>\0<stderr>\0`.
string amReply(int code, string stdout_, string stderr_) @safe pure
{
    import std.conv : to;

    return code.to!string ~ "\0" ~ stdout_ ~ "\0" ~ stderr_ ~ "\0";
}

///
@("am_command.amReply")
@safe pure unittest
{
    assert(amReply(0, "", "") == "0\0\0\0");
    assert(amReply(1, "", "no\n") == "1\0\0no\n\0");
}
