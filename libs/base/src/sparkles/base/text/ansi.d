/**
 * ANSI / VT escape-sequence scanning and active-state tracking.
 *
 * This module owns the single escape grammar used across the text package: a
 * `@nogc` scanner (`escapeLength`), a lazy tokenizer (`byAnsiToken`) splitting a
 * byte stream into visible-text and escape spans, and two small state machines
 * (`SgrState`, `OscLinkState`) that accumulate the *active* SGR style and OSC 8
 * hyperlink so they can be re-emitted after a wrap break (so styling and links
 * survive a line split rather than bleeding onto borders or dropping).
 *
 * The scanner is deliberately a little more permissive than any single terminal:
 * its only jobs are "how many bytes is this escape" and "don't count it as
 * width", so it accepts the whole CSI / OSC / DCS / SOS / PM / APC / nF family.
 */
module sparkles.base.text.ansi;

import std.range.primitives : put;

// ─────────────────────────────────────────────────────────────────────────────
// Escape scanner
// ─────────────────────────────────────────────────────────────────────────────

/// Length in bytes of the escape sequence beginning at `s[0]` (which must be
/// ESC, `\x1b`). Handles CSI (`\x1b[` … final `0x40`-`0x7e`), OSC (`\x1b]` …),
/// the string sequences DCS/SOS/PM/APC (`\x1bP`/`X`/`^`/`_` …), and two-byte
/// `nF`/`Fe` escapes. String sequences end at BEL (`\x07`) or ST (`\x1b\\`);
/// unterminated sequences and a lone trailing ESC consume the rest of the input.
size_t escapeLength(in char[] s) @safe pure nothrow @nogc
in (s.length >= 1 && s[0] == '\x1b')
{
    if (s.length < 2)
        return 1;

    switch (s[1])
    {
    case '[': // CSI: params/intermediates 0x20-0x3f, then a final byte 0x40-0x7e
        size_t j = 2;
        while (j < s.length && !(s[j] >= 0x40 && s[j] <= 0x7e))
            j++;
        return j < s.length ? j + 1 : s.length;

    case ']': // OSC
    case 'P': // DCS
    case 'X': // SOS
    case '^': // PM
    case '_': // APC
        return stringSeqLength(s, 2);

    default:
        if (s[1] >= 0x20 && s[1] <= 0x2f) // nF: intermediate bytes then a final 0x30-0x7e
        {
            size_t j = 2;
            while (j < s.length && s[j] >= 0x20 && s[j] <= 0x2f)
                j++;
            return j < s.length ? j + 1 : s.length;
        }
        return 2; // two-byte Fe/Fs/Fp escape
    }
}

/// Scan a string-terminated sequence (OSC/DCS/…) starting at `start`, returning
/// the length through its BEL or ST terminator (or the whole input if none).
private size_t stringSeqLength(in char[] s, size_t start) @safe pure nothrow @nogc
{
    size_t j = start;
    while (j < s.length)
    {
        if (s[j] == '\x07')
            return j + 1;
        if (s[j] == '\x1b' && j + 1 < s.length && s[j + 1] == '\\')
            return j + 2;
        j++;
    }
    return s.length;
}

@("ansi.escapeLength.csi")
@safe pure nothrow @nogc unittest
{
    assert(escapeLength("\x1b[1mX") == 4);
    assert(escapeLength("\x1b[0;31mX") == 7);
    assert(escapeLength("\x1b[m") == 3);
    assert(escapeLength("\x1b[38;2;1;2;3mX") == 13);
}

@("ansi.escapeLength.osc")
@safe pure nothrow @nogc unittest
{
    assert(escapeLength("\x1b]8;;u\x07X") == 7);          // BEL terminator
    assert(escapeLength("\x1b]8;;u\x1b\\X") == 8);        // ST terminator
    assert(escapeLength("\x1b]0;title\x07") == 10);       // OSC other than 8
    assert(escapeLength("\x1b]8;;unterminated") == 17);   // unterminated ⇒ rest
}

@("ansi.escapeLength.stringSeqs")
@safe pure nothrow @nogc unittest
{
    assert(escapeLength("\x1bP1$r0m\x1b\\Z") == 9);       // DCS to ST
    assert(escapeLength("\x1b_payload\x1b\\Z") == 11);    // APC to ST
}

@("ansi.escapeLength.shortAndTwoByte")
@safe pure nothrow @nogc unittest
{
    assert(escapeLength("\x1b") == 1);                    // lone ESC
    assert(escapeLength("\x1b(B") == 3);                  // nF charset designation
    assert(escapeLength("\x1bMx") == 2);                  // two-byte (reverse index)
}

// ─────────────────────────────────────────────────────────────────────────────
// Token range
// ─────────────────────────────────────────────────────────────────────────────

/// One token from `byAnsiToken`: a maximal run of visible text, or one escape.
struct AnsiToken
{
    const(char)[] slice; /// The token's bytes (a slice of the input).
    bool isEscape;       /// True for an escape sequence, false for visible text.
}

/// Lazy forward range splitting `s` into alternating text / escape tokens.
struct AnsiTokenRange
{
    private const(char)[] _rest;
    private AnsiToken _front;
    private bool _empty;

    private this(return scope const(char)[] s) @safe pure nothrow @nogc
    {
        _rest = s;
        popFront();
    }

    /// Range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _empty;

    /// ditto
    AnsiToken front() const return scope @safe pure nothrow @nogc => _front;

    /// ditto
    void popFront() scope @safe pure nothrow @nogc
    {
        if (_rest.length == 0)
        {
            _empty = true;
            _front = AnsiToken.init;
            return;
        }
        if (_rest[0] == '\x1b')
        {
            const n = escapeLength(_rest);
            _front = AnsiToken(_rest[0 .. n], true);
            _rest = _rest[n .. $];
        }
        else
        {
            size_t j = 0;
            while (j < _rest.length && _rest[j] != '\x1b')
                j++;
            _front = AnsiToken(_rest[0 .. j], false);
            _rest = _rest[j .. $];
        }
    }
}

/// Iterate `s` as alternating visible-text and escape tokens.
AnsiTokenRange byAnsiToken(return scope const(char)[] s) @safe pure nothrow @nogc
{
    return AnsiTokenRange(s);
}

@("ansi.byAnsiToken.splitsTextAndEscapes")
@safe pure nothrow @nogc unittest
{
    auto r = "a\x1b[1mb\x1b[0m".byAnsiToken;
    assert(!r.empty && r.front == AnsiToken("a", false));
    r.popFront;
    assert(r.front == AnsiToken("\x1b[1m", true));
    r.popFront;
    assert(r.front == AnsiToken("b", false));
    r.popFront;
    assert(r.front == AnsiToken("\x1b[0m", true));
    r.popFront;
    assert(r.empty);
}

// ─────────────────────────────────────────────────────────────────────────────
// SGR state
// ─────────────────────────────────────────────────────────────────────────────

private enum SgrAttr : ubyte
{
    bold          = 1 << 0,
    dim           = 1 << 1,
    italic        = 1 << 2,
    underline     = 1 << 3,
    blink         = 1 << 4,
    inverse       = 1 << 5,
    hidden        = 1 << 6,
    strikethrough = 1 << 7,
}

/// Accumulates the *active* SGR style across a run of `\x1b[…m` sequences so it
/// can be re-emitted after a wrap break. Tracks boolean attributes plus the
/// foreground / background / underline colors verbatim (so 256-color and
/// truecolor are reproduced faithfully). Not a full SGR interpreter — unknown
/// parameters are ignored, which is safe for re-emission.
struct SgrState
{
    private ubyte _attrs;
    private char[32] _fg = void; private ubyte _fgLen;
    private char[32] _bg = void; private ubyte _bgLen;
    private char[32] _ul = void; private ubyte _ulLen; // underline color (58/59)

    /// True if any attribute or color is currently set.
    bool active() const @safe pure nothrow @nogc
        => _attrs != 0 || _fgLen != 0 || _bgLen != 0 || _ulLen != 0;

    /// Reset to the default (unstyled) state.
    void clear() @safe pure nothrow @nogc
    {
        _attrs = 0;
        _fgLen = _bgLen = _ulLen = 0;
    }

    /// Feed one escape token. No-op unless it is an SGR (`\x1b[…m`) sequence.
    void apply(in char[] seq) @safe pure nothrow @nogc
    {
        // Must be CSI ending in 'm'.
        if (seq.length < 3 || seq[0] != '\x1b' || seq[1] != '[' || seq[$ - 1] != 'm')
            return;

        const params = seq[2 .. $ - 1];
        if (params.length == 0) // ESC[m == ESC[0m
        {
            clear();
            return;
        }

        size_t cur = 0;
        size_t s, e;
        while (nextToken(params, cur, s, e))
        {
            const code = tokenInt(params[s .. e]);
            switch (code)
            {
            case 0:  clear(); break;
            case 1:  _attrs |= SgrAttr.bold; break;
            case 2:  _attrs |= SgrAttr.dim; break;
            case 3:  _attrs |= SgrAttr.italic; break;
            case 4:
            case 21: _attrs |= SgrAttr.underline; break;
            case 5:
            case 6:  _attrs |= SgrAttr.blink; break;
            case 7:  _attrs |= SgrAttr.inverse; break;
            case 8:  _attrs |= SgrAttr.hidden; break;
            case 9:  _attrs |= SgrAttr.strikethrough; break;
            case 22: _attrs &= ~cast(ubyte)(SgrAttr.bold | SgrAttr.dim); break;
            case 23: _attrs &= ~cast(ubyte) SgrAttr.italic; break;
            case 24: _attrs &= ~cast(ubyte) SgrAttr.underline; break;
            case 25: _attrs &= ~cast(ubyte) SgrAttr.blink; break;
            case 27: _attrs &= ~cast(ubyte) SgrAttr.inverse; break;
            case 28: _attrs &= ~cast(ubyte) SgrAttr.hidden; break;
            case 29: _attrs &= ~cast(ubyte) SgrAttr.strikethrough; break;
            case 39: _fgLen = 0; break;
            case 49: _bgLen = 0; break;
            case 59: _ulLen = 0; break;
            case 38: setColorSpan(params, _fg, _fgLen, s, e, cur); break;
            case 48: setColorSpan(params, _bg, _bgLen, s, e, cur); break;
            case 58: setColorSpan(params, _ul, _ulLen, s, e, cur); break;
            default:
                if ((code >= 30 && code <= 37) || (code >= 90 && code <= 97))
                    setSpan(_fg, _fgLen, params[s .. e]);
                else if ((code >= 40 && code <= 47) || (code >= 100 && code <= 107))
                    setSpan(_bg, _bgLen, params[s .. e]);
                break;
            }
        }
    }

    /// Emit a single `\x1b[…m` re-establishing the active style (nothing if
    /// inactive). Used at the start of a continuation line.
    void emit(Writer)(ref Writer w) const
    {
        if (!active)
            return;

        put(w, "\x1b[");
        bool first = true;
        void sep() { if (!first) put(w, ';'); first = false; }

        static immutable ubyte[8] bits = [
            SgrAttr.bold, SgrAttr.dim, SgrAttr.italic, SgrAttr.underline,
            SgrAttr.blink, SgrAttr.inverse, SgrAttr.hidden, SgrAttr.strikethrough,
        ];
        static immutable char[8] onCode = ['1', '2', '3', '4', '5', '7', '8', '9'];
        foreach (i, bit; bits)
            if (_attrs & bit)
            {
                sep();
                put(w, onCode[i]);
            }
        if (_fgLen) { sep(); put(w, _fg[0 .. _fgLen]); }
        if (_bgLen) { sep(); put(w, _bg[0 .. _bgLen]); }
        if (_ulLen) { sep(); put(w, _ul[0 .. _ulLen]); }
        put(w, 'm');
    }
}

/// Write a full SGR reset (`\x1b[0m`) to `w`. Used at the end of a line before
/// padding/border so the active style cannot bleed past the visible content.
void writeSgrReset(Writer)(ref Writer w)
{
    put(w, "\x1b[0m");
}

private void setSpan(ref char[32] dst, ref ubyte len, in char[] src) @safe pure nothrow @nogc
{
    const n = src.length > dst.length ? dst.length : src.length;
    dst[0 .. n] = src[0 .. n];
    len = cast(ubyte) n;
}

/// Capture an extended color (`38`/`48`/`58` …) verbatim into `dst`. The leading
/// token `params[s..e]` is the `38`/`48`/`58`; in colon form (`38:2:r:g:b`) the
/// whole color is that one token, in semicolon form (`38;2;r;g;b`) it spans the
/// following selector + value tokens, which are consumed from `cur`.
private void setColorSpan(in char[] params, ref char[32] dst, ref ubyte len,
    size_t s, size_t e, ref size_t cur) @safe pure nothrow @nogc
{
    // Colon form: the color lives entirely inside this one `;`-token.
    foreach (c; params[s .. e])
        if (c == ':')
        {
            setSpan(dst, len, params[s .. e]);
            return;
        }

    // Semicolon form: read the color-space selector, then its value tokens.
    size_t s2, e2;
    if (!nextToken(params, cur, s2, e2))
    {
        setSpan(dst, len, params[s .. e]);
        return;
    }
    const sel = tokenInt(params[s2 .. e2]);
    size_t spanEnd = e2;
    const extra = sel == 5 ? 1 : sel == 2 ? 3 : 0;
    foreach (_; 0 .. extra)
    {
        size_t s3, e3;
        if (!nextToken(params, cur, s3, e3))
            break;
        spanEnd = e3;
    }
    setSpan(dst, len, params[s .. spanEnd]);
}

/// Read the next `;`-separated token's `[start, end)` from `params`, advancing
/// `cur` past the separator. Returns false once the params are exhausted.
private bool nextToken(in char[] params, ref size_t cur, out size_t start, out size_t end)
    @safe pure nothrow @nogc
{
    if (cur > params.length)
        return false;
    start = cur;
    while (cur < params.length && params[cur] != ';')
        cur++;
    end = cur;
    cur++; // step over the ';' (or past the end on the final token)
    return true;
}

/// Integer value of a token (leading digits; non-digits terminate). Empty ⇒ 0.
private int tokenInt(in char[] tok) @safe pure nothrow @nogc
{
    int v = 0;
    foreach (c; tok)
    {
        if (c < '0' || c > '9')
            break;
        v = v * 10 + (c - '0');
    }
    return v;
}

@("ansi.SgrState.basicReEmit")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    SgrState st;
    st.apply("\x1b[1m");
    st.apply("\x1b[31m");
    checkWriter!((ref b) { st.emit(b); })("\x1b[1;31m");
}

@("ansi.SgrState.resetClears")
@safe pure nothrow @nogc unittest
{
    SgrState st;
    st.apply("\x1b[1;31m");
    assert(st.active);
    st.apply("\x1b[0m");
    assert(!st.active);
}

@("ansi.SgrState.truecolorVerbatim")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    SgrState st;
    st.apply("\x1b[38;2;10;20;30m");
    st.apply("\x1b[48;5;200m");
    checkWriter!((ref b) { st.emit(b); })("\x1b[38;2;10;20;30;48;5;200m");
}

@("ansi.SgrState.defaultColorResets")
@safe pure nothrow @nogc unittest
{
    SgrState st;
    st.apply("\x1b[31m");
    st.apply("\x1b[39m"); // default fg
    assert(!st.active);
}

// ─────────────────────────────────────────────────────────────────────────────
// OSC 8 hyperlink state
// ─────────────────────────────────────────────────────────────────────────────

/// Tracks the *active* OSC 8 hyperlink so it can be closed before a wrap newline
/// and re-opened on the continuation line. The open sequence is copied into an
/// inline buffer (a self-contained value type, safe to snapshot — no slice into
/// the input); a close (`\x1b]8;;…`) clears it. Open sequences longer than the
/// buffer are ignored (treated as no active link).
struct OscLinkState
{
    private char[512] _buf = void;
    private size_t _len;

    /// True if a hyperlink is currently open.
    bool active() const @safe pure nothrow @nogc => _len != 0;

    /// Clear the active link.
    void clear() @safe pure nothrow @nogc { _len = 0; }

    /// Feed one escape token. No-op unless it is an OSC 8 sequence; an OSC 8 with
    /// a non-empty URI opens (records) a link, an empty URI closes it.
    void apply(in char[] seq) @safe pure nothrow @nogc
    {
        if (seq.length < 4 || seq[0] != '\x1b' || seq[1] != ']'
            || seq[2] != '8' || seq[3] != ';')
            return;

        // Strip the terminator (BEL or ST) to read params;uri.
        size_t termLen;
        if (seq[$ - 1] == '\x07')
            termLen = 1;
        else if (seq.length >= 2 && seq[$ - 2] == '\x1b' && seq[$ - 1] == '\\')
            termLen = 2;
        else
            termLen = 0;

        const content = seq[4 .. $ - termLen]; // "params;uri"
        size_t semi = 0;
        while (semi < content.length && content[semi] != ';')
            semi++;
        const uriEmpty = semi + 1 >= content.length;
        if (uriEmpty || seq.length > _buf.length)
            _len = 0;            // close (or too long to record)
        else
        {
            _buf[0 .. seq.length] = seq[]; // open: record verbatim for re-emit
            _len = seq.length;
        }
    }

    /// Re-open the active link (emit its recorded open sequence), if any.
    void reopen(Writer)(ref Writer w) const
    {
        if (active)
            put(w, _buf[0 .. _len]);
    }

    /// Emit an OSC 8 close (`\x1b]8;;\x07`), if a link is active.
    void writeClose(Writer)(ref Writer w) const
    {
        if (active)
            put(w, "\x1b]8;;\x07");
    }
}

@("ansi.OscLinkState.openClose")
@safe pure nothrow @nogc unittest
{
    OscLinkState st;
    st.apply("\x1b]8;;https://example.com\x07");
    assert(st.active);
    st.apply("\x1b]8;;\x07"); // close
    assert(!st.active);
}

@("ansi.OscLinkState.reopenVerbatim")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    OscLinkState st;
    st.apply("\x1b]8;id=x;https://example.com\x1b\\");
    checkWriter!((ref b) { st.reopen(b); })("\x1b]8;id=x;https://example.com\x1b\\");
    checkWriter!((ref b) { st.writeClose(b); })("\x1b]8;;\x07");
}
