/// Streaming detection of OSC color queries (OSC 10/11/12 with a `?` spec)
/// in the child → terminal pty byte stream.
///
/// libghostty-vt parses OSC color operations and applies set/reset requests
/// to its color state, but silently drops query requests (its stream handler
/// ignores them), so the emulator has to answer queries itself. app.d feeds
/// every pty chunk through an `OscScanner` and replies to the queries this
/// module extracts the way xterm and Ghostty do — programs rely on this to
/// adapt to the terminal's theme (e.g. yazi queries OSC 11 to pick its light
/// or dark flavor).
module osc_query;

import sparkles.base.smallbuffer : SmallBuffer;

/// Streaming scanner for OSC sequences. Tracks just enough state to extract
/// complete OSC payloads even when a sequence is split across read() chunks.
/// Payloads longer than the buffer (e.g. OSC 52 clipboard writes) are marked
/// overflowed and must be ignored by the caller — color queries are short.
struct OscScanner
{
    enum State : ubyte { ground, esc, osc, oscEsc }
    State state;
    bool overflowed;
    bool endedWithBel; /// sequence terminator: BEL (true) or ESC \ (false)
    SmallBuffer!(char, 48) payload;
}

/// Advance the scanner by one byte. Returns true when an OSC sequence just
/// terminated (`payload`/`endedWithBel` describe it); the caller answers any
/// color queries it contains.
@safe nothrow @nogc
bool oscScanByte(ref OscScanner sc, char b)
{
    final switch (sc.state)
    {
        case OscScanner.State.ground:
            if (b == 0x1b) sc.state = OscScanner.State.esc;
            return false;
        case OscScanner.State.esc:
            if (b == ']')
            {
                sc.state = OscScanner.State.osc;
                sc.payload.clear();
                sc.overflowed = false;
            }
            else if (b != 0x1b) // ESC ESC restarts; anything else: not an OSC
                sc.state = OscScanner.State.ground;
            return false;
        case OscScanner.State.osc:
            if (b == 0x07)
            {
                sc.state = OscScanner.State.ground;
                sc.endedWithBel = true;
                return true;
            }
            if (b == 0x1b)
            {
                sc.state = OscScanner.State.oscEsc;
                return false;
            }
            if (sc.payload.length < 48)
                sc.payload ~= b;
            else
                sc.overflowed = true;
            return false;
        case OscScanner.State.oscEsc:
            if (b == '\\') // ST
            {
                sc.state = OscScanner.State.ground;
                sc.endedWithBel = false;
                return true;
            }
            // Any other byte after ESC aborts the OSC and starts a new escape
            // sequence; reprocess it in the `esc` state.
            sc.state = OscScanner.State.esc;
            return oscScanByte(sc, b);
    }
}

///
@("oscScanByte.query.belTerminator")
@safe nothrow @nogc
unittest
{
    OscScanner sc;
    bool done;
    foreach (b; "\x1b]11;?")
        done = oscScanByte(sc, b);
    assert(!done);
    assert(oscScanByte(sc, '\x07'));
    assert(sc.endedWithBel);
    assert(!sc.overflowed);
    assert(sc.payload[] == "11;?");
}

@("oscScanByte.query.stTerminator")
@safe nothrow @nogc
unittest
{
    OscScanner sc;
    foreach (b; "\x1b]10;?\x1b")
        assert(!oscScanByte(sc, b));
    assert(oscScanByte(sc, '\\'));
    assert(!sc.endedWithBel);
    assert(sc.payload[] == "10;?");
}

@("oscScanByte.query.splitAcrossChunks")
@safe nothrow @nogc
unittest
{
    OscScanner sc;
    foreach (b; "\x1b]1") // chunk 1 ends mid-sequence
        assert(!oscScanByte(sc, b));
    bool done;
    foreach (b; "1;?\x07") // chunk 2 completes it
        done = oscScanByte(sc, b);
    assert(done);
    assert(sc.payload[] == "11;?");
}

@("oscScanByte.abortedByNewEscape")
@safe nothrow @nogc
unittest
{
    OscScanner sc;
    // ESC inside an OSC aborts it; the following bytes start a fresh OSC.
    bool done;
    foreach (b; "\x1b]52;c;Zm9v\x1b\x1b]11;?")
        done = oscScanByte(sc, b);
    assert(!done);
    assert(oscScanByte(sc, '\x07'));
    assert(sc.payload[] == "11;?");
}

@("oscScanByte.overflow")
@safe nothrow @nogc
unittest
{
    OscScanner sc;
    foreach (b; "\x1b]52;c;")
        oscScanByte(sc, b);
    foreach (i; 0 .. 100)
        oscScanByte(sc, 'A');
    assert(oscScanByte(sc, '\x07'));
    assert(sc.overflowed);
    // The next sequence resets the overflow state.
    foreach (b; "\x1b]11;?")
        oscScanByte(sc, b);
    assert(oscScanByte(sc, '\x07'));
    assert(!sc.overflowed);
    assert(sc.payload[] == "11;?");
}

/// Parse a complete OSC payload, appending the color code of every `?` query
/// spec to `codes`. Follows xterm semantics: the first parameter is the color
/// code and each further `;`-separated spec applies to the next code in
/// sequence, so `10;?;?` queries the foreground (10) and then the background
/// (11). Only the dynamic colors 10–12 are supported; set/reset specs are
/// skipped — the library already applied them when the bytes were fed to it.
@safe nothrow @nogc
void oscColorQueryCodes(scope const(char)[] payload, ref SmallBuffer!(int, 4) codes)
{
    int code = 0;
    size_t i = 0;
    while (i < payload.length && payload[i] >= '0' && payload[i] <= '9')
    {
        code = code * 10 + (payload[i] - '0');
        i++;
    }
    if (i == 0 || i >= payload.length || payload[i] != ';' || code < 10 || code > 12)
        return;

    while (i < payload.length && code <= 12)
    {
        i++; // skip ';'
        const start = i;
        while (i < payload.length && payload[i] != ';')
            i++;
        if (payload[start .. i] == "?")
            codes ~= code;
        code++;
    }
}

///
@("oscColorQueryCodes.singleQuery")
@safe nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) codes;
    oscColorQueryCodes("11;?", codes);
    assert(codes[] == [11]);
}

@("oscColorQueryCodes.multiSpecAdvancesCode")
@safe nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) codes;
    oscColorQueryCodes("10;?;?;?", codes);
    assert(codes[] == [10, 11, 12]);
}

@("oscColorQueryCodes.setSpecSkipped")
@safe nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) codes;
    oscColorQueryCodes("10;#ff0000;?", codes); // set fg, query bg
    assert(codes[] == [11]);

    codes.clear();
    oscColorQueryCodes("11;#000000", codes); // pure set: nothing to answer
    assert(codes.length == 0);
}

@("oscColorQueryCodes.unsupportedCodesIgnored")
@safe nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) codes;
    oscColorQueryCodes("4;1;?", codes); // palette query: unsupported
    oscColorQueryCodes("52;c;?", codes); // clipboard: not a color query
    oscColorQueryCodes("2;title", codes); // title set
    oscColorQueryCodes("?", codes); // no code at all
    oscColorQueryCodes("12;?;?", codes); // second spec would be 13: dropped
    assert(codes[] == [12]);
}
