/++
Asking the terminal what it can do (design-system `CAP3`, the plan's M7), one
row at a time. This is the `images` row: which image protocol the terminal
answers for.

The battery is one write — the kitty graphics query, then primary DA as the
fence. Terminals answer in order, so the DA1 reply proves the graphics query
was either answered or never will be, and a terminal that answers nothing is
bounded by the caller's timeout. The replies come back on the input stream,
interleaved with whatever the user typed meanwhile; $(LREF splitImageReplies)
takes the replies out and returns the rest, so the typed keys are replayed to
the input decoder rather than lost.

The answers mean, per the capability case study's measurements:

$(UL
    $(LI a kitty graphics reply of `OK` — the terminal (or a multiplexer that
        relays to one) draws kitty images. A round trip, so it is believed
        under a multiplexer too: zellij answers it `OK` only when its host
        can.)
    $(LI DA1 listing attribute `4` — sixel. $(I Not) believed under a
        multiplexer (`CAP7`, design-system D33): tmux lists it inside Ghostty,
        which draws no sixel.)
)
+/
module sparkles.tui.probe;

import sparkles.base.term_caps : ImageProtocol;

/// The `images` battery: kitty's graphics query (a 1×1 RGB image, id 31, that
/// is queried and never stored), fenced by primary DA.
enum string imageQuery = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c";

/// What the `images` battery was answered with.
struct ImageReplies
{
    bool kitty;  /// the graphics query was answered `OK`
    bool sixel;  /// DA1 listed attribute `4`
    bool fenced; /// DA1 arrived: every earlier reply is in

    /**
    The protocol these answers declare — kitty first, since it is the one the
    toolkit draws; sixel only when the replies are the terminal's own, not a
    multiplexer's.
    */
    ImageProtocol protocol(bool multiplexer) const @safe pure nothrow @nogc
        => kitty ? ImageProtocol.kitty
            : sixel && !multiplexer ? ImageProtocol.sixel
            : ImageProtocol.none;
}

/**
Splits what arrived on the input stream into the battery's replies and
everything else. The replies are the kitty graphics reply (`ESC _ G … ESC \`)
and primary DA (`ESC [ ? … c`); every other byte — a key typed during the
probe, a reply this row does not ask for — is appended to `rest`, in order,
for the input decoder.

Idempotent over a growing buffer: call it on everything read so far; a reply
cut off at the end is left in `rest` and `fenced` stays false.
*/
ImageReplies splitImageReplies(in ubyte[] bytes, ref ubyte[] rest) @safe pure nothrow
{
    ImageReplies r;
    size_t i;
    while (i < bytes.length)
    {
        const at = bytes[i .. $];
        if (startsWith(at, "\x1b_G"))
        {
            const end = find(at, "\x1b\\");
            if (end == size_t.max)
                break; // cut off: the rest is still arriving
            const body_ = at[3 .. end];
            if (find(body_, "i=31") != size_t.max && find(body_, ";OK") != size_t.max)
                r.kitty = true;
            i += end + 2;
            continue;
        }
        if (startsWith(at, "\x1b[?"))
        {
            // Parameters, then a final byte: `c` is DA1; anything else is
            // some other reply, and is the decoder's.
            size_t j = 3;
            while (j < at.length && ((at[j] >= '0' && at[j] <= '9') || at[j] == ';'))
                ++j;
            if (j == at.length)
                break; // cut off
            if (at[j] == 'c')
            {
                r.sixel = listsAttribute(at[3 .. j], '4');
                r.fenced = true;
                i += j + 1;
                continue;
            }
        }
        rest ~= bytes[i];
        ++i;
    }
    rest ~= bytes[i .. $];
    return r;
}

private bool startsWith(in ubyte[] s, string prefix) @safe pure nothrow @nogc
    => s.length >= prefix.length && s[0 .. prefix.length] == cast(const(ubyte)[]) prefix;

private size_t find(in ubyte[] s, string needle) @safe pure nothrow @nogc
{
    if (s.length < needle.length)
        return size_t.max;
    foreach (k; 0 .. s.length - needle.length + 1)
        if (s[k .. k + needle.length] == cast(const(ubyte)[]) needle)
            return k;
    return size_t.max;
}

// Whether DA1's `params` list `attribute` after the class (the first one).
private bool listsAttribute(in ubyte[] params, char attribute) @safe pure nothrow @nogc
{
    size_t start, field;
    foreach (k; 0 .. params.length + 1)
        if (k == params.length || params[k] == ';')
        {
            if (field++ > 0 && k - start == 1 && params[start] == attribute)
                return true;
            start = k + 1;
        }
    return false;
}

@("tui.probe.images.kittyAndTheFence")
@safe pure nothrow unittest
{
    // Ghostty's measured replies (the case study's matrix): the graphics
    // query answered, DA1 without sixel.
    ubyte[] rest;
    const r = splitImageReplies(cast(const(ubyte)[]) "\x1b_Gi=31;OK\x1b\\\x1b[?62;22;52c", rest);
    assert(r.kitty && !r.sixel && r.fenced && rest.length == 0);
    assert(r.protocol(false) == ImageProtocol.kitty);
}

@("tui.probe.images.sixelIsTheTerminalsOwnOnly")
@safe pure nothrow unittest
{
    // foot: no kitty reply, DA1 lists 4.
    ubyte[] rest;
    const foot = splitImageReplies(cast(const(ubyte)[]) "\x1b[?62;4;22;28;52c", rest);
    assert(!foot.kitty && foot.sixel && foot.fenced);
    assert(foot.protocol(false) == ImageProtocol.sixel);
    // tmux lists 4 whatever its host draws: under a multiplexer it is not
    // believed (`CAP7`).
    const tmux = splitImageReplies(cast(const(ubyte)[]) "\x1b[?1;2;4c", rest);
    assert(tmux.protocol(true) == ImageProtocol.none);
    // The class is not an attribute: VT132's `4;…` is no sixel.
    assert(!splitImageReplies(cast(const(ubyte)[]) "\x1b[?4;6c", rest).sixel);
}

@("tui.probe.images.typedKeysSurvive")
@safe pure nothrow unittest
{
    // A key typed during the probe, a refusal, and an unrelated reply are
    // all the decoder's — in the order they arrived.
    ubyte[] rest;
    const r = splitImageReplies(cast(const(ubyte)[])
        "j\x1b_Gi=31;ENOTSUPPORTED:no\x1b\\k\x1b[?0u\x1b[?62c", rest);
    assert(!r.kitty && r.fenced);
    assert(rest == cast(const(ubyte)[]) "jk\x1b[?0u");
}

@("tui.probe.images.aCutOffReplyWaits")
@safe pure nothrow unittest
{
    // The fence has not arrived: not fenced, and the partial bytes are kept
    // for the next, longer read to parse again.
    ubyte[] rest;
    const r = splitImageReplies(cast(const(ubyte)[]) "\x1b_Gi=31;OK\x1b\\\x1b[?62;2", rest);
    assert(r.kitty && !r.fenced);
    assert(rest == cast(const(ubyte)[]) "\x1b[?62;2");
}
