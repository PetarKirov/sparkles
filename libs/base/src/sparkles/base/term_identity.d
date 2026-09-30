/++
What a terminal is known to do, by the name it answers `XTVERSION` with
(design-system `CAP3`, D42): the rows no query answers — clickable links
(OSC 8), clipboard writes (OSC 52), desktop notifications (OSC 99 / 9 / 777)
and the pointer shape (OSC 22).

Each claim is a row of $(LREF knownTerminals): a terminal, the feature, the
first version that does it, and the source line that does it. A terminal is
matched by the name it gives itself, never by `$TERM` or `$TERM_PROGRAM`, which
a shell, an `ssh` hop or a multiplexer can carry from somewhere else; one that
does not answer (Alacritty) or is not listed gets none of these rows. A
multiplexer answers with its own name, so its rows are the multiplexer's.
+/
module sparkles.base.term_identity;

import sparkles.base.term_caps : TermCaps;

@safe pure nothrow @nogc:

/// A version as `XTVERSION` spells it: up to four numeric parts, a trailing
/// letter counted as one more (`3.6a` is `3.6.1`).
struct TerminalVersion
{
    uint[4] parts; /// most significant first
    ubyte count;   /// how many of `parts` were given

    @safe pure nothrow @nogc:

    /// Whether this version is `min` or later; a part missing on either side
    /// counts as `0`.
    bool atLeast(in TerminalVersion min) const
    {
        foreach (k; 0 .. parts.length)
            if (parts[k] != min.parts[k])
                return parts[k] > min.parts[k];
        return true;
    }
}

/// The name and version in an `XTVERSION` answer.
struct TerminalName
{
    const(char)[] name;      /// as the terminal spells it (`XTerm`, `kitty`)
    TerminalVersion version_; /// what follows it

    @safe pure nothrow @nogc:

    /// Whether the terminal called itself `n`, in any case.
    bool isNamed(in char[] n) const scope
    {
        if (name.length != n.length)
            return false;
        foreach (k, c; name)
            if (lower(c) != lower(n[k]))
                return false;
        return true;
    }
}

/**
Splits an `XTVERSION` answer into the terminal's name and version. The
measured spellings are `name(version)` (kitty, foot, XTerm, zellij) and
`name version` (Ghostty, tmux).
*/
TerminalName parseXtversion(return scope const(char)[] answer)
{
    size_t k;
    while (k < answer.length && answer[k] != '(' && answer[k] != ' ')
        ++k;
    return TerminalName(answer[0 .. k], parseVersion(answer[k < answer.length ? k + 1 : k .. $]));
}

/// A version as `XTVERSION` spells it: digits separated by dots, a trailing
/// letter one more part, anything after that ignored (`1.25.0)`, `3.6a`).
TerminalVersion parseVersion(in char[] spelled)
{
    TerminalName r;
    foreach (c; spelled)
    {
        if (r.version_.count == r.version_.parts.length)
            break;
        if (c >= '0' && c <= '9')
        {
            if (r.version_.count == 0)
                r.version_.count = 1;
            auto p = &r.version_.parts[r.version_.count - 1];
            *p = *p * 10 + (c - '0');
        }
        else if (c == '.')
            ++r.version_.count;
        else if (lower(c) >= 'a' && lower(c) <= 'z' && r.version_.count > 0)
        {
            ++r.version_.count;
            r.version_.parts[r.version_.count - 1] = lower(c) - 'a' + 1;
            break;
        }
        else if (r.version_.count > 0)
            break;
    }
    return r.version_;
}

private char lower(char c) => c >= 'A' && c <= 'Z' ? cast(char)(c + ('a' - 'A')) : c;

@("term_identity.parseXtversion.measured")
@safe pure nothrow @nogc
unittest
{
    // The corpus terminals' own answers.
    auto k = parseXtversion("kitty(0.48.2)");
    assert(k.isNamed("kitty") && k.version_.count == 3 && k.version_.parts[0 .. 3] == [0, 48, 2]);
    auto g = parseXtversion("ghostty 1.3.1");
    assert(g.isNamed("Ghostty") && g.version_.parts[0 .. 3] == [1, 3, 1]);
    assert(parseXtversion("foot(1.25.0)").version_.parts[0 .. 3] == [1, 25, 0]);
    auto x = parseXtversion("XTerm(403)");
    assert(x.isNamed("xterm") && x.version_.count == 1 && x.version_.parts[0] == 403);
    auto t = parseXtversion("tmux 3.6a");
    assert(t.isNamed("tmux") && t.version_.count == 3 && t.version_.parts[0 .. 3] == [3, 6, 1]);
    assert(parseXtversion("Zellij(4501)").version_.parts[0] == 4501);
    // Nothing answered: no name, no version.
    const none = parseXtversion("");
    assert(none.name.length == 0 && none.version_.count == 0);
}

@("term_identity.TerminalVersion.atLeast")
@safe pure nothrow @nogc
unittest
{
    const v = parseXtversion("tmux 3.6a").version_;
    assert(v.atLeast(parseXtversion("tmux 3.6").version_));
    assert(v.atLeast(parseXtversion("tmux 3.6a").version_));
    assert(!v.atLeast(parseXtversion("tmux 3.6b").version_));
    assert(!v.atLeast(parseXtversion("tmux 3.7").version_));
    assert(parseXtversion("kitty(0.48.2)").version_.atLeast(parseXtversion("kitty(0.19)").version_));
}

/// The rows no query answers, by the `OutputCapabilities` field each sets.
enum KnownFeature : ubyte
{
    hyperlinks,    /// OSC 8 links, made clickable
    clipboard,     /// OSC 52 clipboard writes, on by default
    notifications, /// OSC 99, OSC 9 or OSC 777 desktop notifications
    pointerShape,  /// OSC 22 pointer shapes
}

static foreach (m; __traits(allMembers, KnownFeature))
    static assert(__traits(hasMember, TermCaps, m),
        "`" ~ m ~ "` is not an `OutputCapabilities` field");

/// One claim: `terminal`, from version `since` on, does `feature` in its
/// default configuration — and `source` is the line that does it, at the
/// tag of the version measured.
struct KnownTerminalRow
{
    string terminal;     /// the name its `XTVERSION` answer gives
    KnownFeature feature; /// what it does
    string since;        /// the first version that does it, spelled as `XTVERSION` spells it
    string source;       /// a pinned link to the code that does it
}

private enum kitty = "https://github.com/kovidgoyal/kitty/blob/2cb1d95c3accadd536bd66ba6bda044973440177/";
private enum foot = "https://codeberg.org/dnkl/foot/src/commit/b44a62724cd51c7fecdfd9d1b41a3691b11a4c27/";
private enum ghostty = "https://github.com/ghostty-org/ghostty/blob/332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28/";
private enum xterm = "https://github.com/ThomasDickey/xterm-snapshots/blob/1b8146571535adeee117fc4db331a4b44eda74a9/";

/**
What each terminal that names itself is known to do, read from its source at
the version the design system's `O5` corpus measured (kitty 0.48.2, foot
1.25.0, Ghostty 1.3.1, XTerm 403), with the first version from its changelog.

Left out on purpose:
$(LIST
    * XTerm's OSC 52: supported, but `SetSelection` is in its default
        `disallowedWindowOps` — off unless the user turns it on;
    * the multiplexers: tmux forwards links only where the host has its
        `hyperlinks` feature and drops OSC 52 by default (`set-clipboard
        external`); zellij forwards links, clipboard writes and
        notifications to a host it cannot vouch for. What reaches the screen
        is the host's to say, and through a multiplexer the host does not
        answer (`CAP7`, D33);
    * Alacritty: it draws links and takes clipboard writes, but answers no
        `XTVERSION` to be found by.
)
*/
static immutable KnownTerminalRow[] knownTerminals = [
    KnownTerminalRow("kitty", KnownFeature.hyperlinks, "0.19.0", kitty ~ "kitty/vt-parser.c#L535"),
    KnownTerminalRow("kitty", KnownFeature.clipboard, "0.10.0", kitty ~ "kitty/vt-parser.c#L566"),
    KnownTerminalRow("kitty", KnownFeature.notifications, "0.19.0", kitty ~ "kitty/vt-parser.c#L538"),
    KnownTerminalRow("kitty", KnownFeature.pointerShape, "0.31.0", kitty ~ "kitty/window.py#L1615"),
    KnownTerminalRow("foot", KnownFeature.hyperlinks, "1.7.0", foot ~ "osc.c#L1375"),
    KnownTerminalRow("foot", KnownFeature.clipboard, "0.9.0", foot ~ "osc.c#L1503"),
    KnownTerminalRow("foot", KnownFeature.notifications, "1.6.0", foot ~ "osc.c#L1701"),
    KnownTerminalRow("foot", KnownFeature.pointerShape, "1.12.0", foot ~ "osc.c#L1496"),
    KnownTerminalRow("ghostty", KnownFeature.hyperlinks, "1.0.0", ghostty ~ "src/terminal/osc.zig#L730"),
    KnownTerminalRow("ghostty", KnownFeature.clipboard, "1.0.0", ghostty ~ "src/terminal/osc.zig#L738"),
    KnownTerminalRow("ghostty", KnownFeature.notifications, "1.0.0", ghostty ~ "src/terminal/osc.zig#L732"),
    KnownTerminalRow("ghostty", KnownFeature.pointerShape, "1.0.0", ghostty ~ "src/terminal/osc.zig#L736"),
    KnownTerminalRow("XTerm", KnownFeature.pointerShape, "367", xterm ~ "misc.c#L4288"),
];

/**
Sets the rows of $(LREF knownTerminals) the terminal answering `xtversion`
earns; the rest are left as they were. Nothing is claimed for a terminal
that did not answer or is not listed.
*/
void applyKnownTerminal(ref TermCaps t, in char[] xtversion)
{
    const who = parseXtversion(xtversion);
    if (who.name.length == 0)
        return;
    foreach (ref row; knownTerminals)
        if (who.isNamed(row.terminal) && who.version_.atLeast(parseVersion(row.since)))
            static foreach (m; __traits(allMembers, KnownFeature))
                if (row.feature == __traits(getMember, KnownFeature, m))
                    __traits(getMember, t, m) = true;
}

@("term_identity.applyKnownTerminal.measured")
@safe pure nothrow @nogc
unittest
{
    // The corpus terminals' answers, and what each earns.
    static TermCaps of(string answer)
    {
        TermCaps t;
        applyKnownTerminal(t, answer);
        return t;
    }
    const k = of("kitty(0.48.2)");
    assert(k.hyperlinks && k.clipboard && k.notifications && k.pointerShape);
    const g = of("ghostty 1.3.1");
    assert(g.hyperlinks && g.clipboard && g.notifications && g.pointerShape);
    const f = of("foot(1.25.0)");
    assert(f.hyperlinks && f.clipboard && f.notifications && f.pointerShape);
    // XTerm sets pointer shapes; its OSC 52 is off by default, and it has
    // no links or notifications.
    const x = of("XTerm(403)");
    assert(x.pointerShape && !x.hyperlinks && !x.clipboard && !x.notifications);
    // Multiplexers, and a terminal that said nothing: no claims.
    foreach (none; ["tmux 3.6a", "Zellij(4501)", ""])
    {
        const n = of(none);
        assert(!n.hyperlinks && !n.clipboard && !n.notifications && !n.pointerShape);
    }
    // A version before the feature: kitty 0.30 has no pointer shapes yet.
    const old = of("kitty(0.30.1)");
    assert(old.hyperlinks && !old.pointerShape);
}

@("term_identity.knownTerminals.wellFormed")
@safe pure nothrow @nogc
unittest
{
    // Every row names a terminal, parses its version, and links to a pinned
    // commit's line.
    foreach (ref row; knownTerminals)
    {
        assert(row.terminal.length && parseVersion(row.since).count > 0);
        bool pinned;
        foreach (k; 0 .. row.source.length > 40 ? row.source.length - 40 : 0)
        {
            bool hex = true;
            foreach (c; row.source[k .. k + 40])
                hex &= (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            pinned |= hex;
        }
        assert(pinned && row.source[$ - 4 .. $] != ".zig");
    }
}
