/// Streaming detection of OSC color queries (OSC 4/10/11/12 with a `?` spec)
/// in the child → terminal pty byte stream.
///
/// libghostty-vt parses OSC color operations and applies set/reset requests
/// to its color state, but silently drops query requests (its stream handler
/// ignores them), so the emulator has to answer queries itself. core.d feeds
/// every pty chunk through an `OscScanner` and replies to the queries this
/// module extracts the way xterm and Ghostty do — programs rely on this to
/// adapt to the terminal's theme (e.g. yazi queries OSC 11 to pick its light
/// or dark flavor).
module sparkles.terminal_view.osc_query;

import sparkles.base.buffer : UniqueBuffer;

/// Streaming scanner for OSC sequences. Tracks just enough state to extract
/// complete OSC payloads even when a sequence is split across read() chunks.
/// Payloads longer than the limit (e.g. OSC 52 clipboard writes) are marked
/// overflowed and must be ignored. The limit accommodates all 256 palette queries.
struct OscScanner
{
    enum State : ubyte { ground, esc, osc, oscEsc }
    enum maxPayloadLength = 4096;
    State state;
    bool overflowed;
    bool endedWithBel; /// sequence terminator: BEL (true) or ESC \ (false)
    UniqueBuffer!(char, 48) payload;
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
            if (sc.payload.length < OscScanner.maxPayloadLength)
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
    foreach (i; 0 .. OscScanner.maxPayloadLength + 1)
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

/// Parse a complete OSC payload, appending every queried dynamic color code
/// (10–12) or palette index (OSC 4) to `codes`. Returns the OSC command, or zero
/// for unsupported/malformed commands. OSC 4 uses index/spec pairs; dynamic
/// colors advance the code for every spec. Set specs are skipped because the
/// VT engine applies them before the caller answers these queries.
@safe nothrow @nogc
int oscColorQueryCodes(scope const(char)[] payload, ref UniqueBuffer!(int, 4) codes)
{
    const command = decimalColorCode(takeColorField(payload));
    if (command == 4)
    {
        while (payload.length)
        {
            const index = decimalColorCode(takeColorField(payload));
            const spec = takeColorField(payload);
            if (index >= 0 && index <= 255 && spec == "?")
                codes ~= index;
        }
    }
    else if (command >= 10 && command <= 12)
    {
        int code = command;
        while (payload.length && code <= 12)
        {
            if (takeColorField(payload) == "?")
                codes ~= code;
            code++;
        }
    }
    else
        return 0;
    return command;
}

private const(char)[] takeColorField(return scope ref const(char)[] payload) @safe nothrow @nogc
{
    size_t end;
    while (end < payload.length && payload[end] != ';')
        end++;
    const field = payload[0 .. end];
    payload = payload[end < payload.length ? end + 1 : end .. $];
    return field;
}

private int decimalColorCode(scope const(char)[] field) @safe pure nothrow @nogc
{
    if (!field.length)
        return -1;
    int value;
    foreach (b; field)
    {
        if (b < '0' || b > '9' || value > 255)
            return -1;
        value = value * 10 + b - '0';
    }
    return value;
}

///
@("oscColorQueryCodes.singleQuery")
@safe nothrow @nogc
unittest
{
    UniqueBuffer!(int, 4) codes;
    oscColorQueryCodes("11;?", codes);
    assert(codes[] == [11]);
}

@("oscColorQueryCodes.multiSpecAdvancesCode")
@safe nothrow @nogc
unittest
{
    UniqueBuffer!(int, 4) codes;
    oscColorQueryCodes("10;?;?;?", codes);
    assert(codes[] == [10, 11, 12]);
}

@("oscColorQueryCodes.setSpecSkipped")
@safe nothrow @nogc
unittest
{
    UniqueBuffer!(int, 4) codes;
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
    UniqueBuffer!(int, 4) codes;
    oscColorQueryCodes("52;c;?", codes); // clipboard: not a color query
    oscColorQueryCodes("2;title", codes); // title set
    oscColorQueryCodes("?", codes); // no code at all
    oscColorQueryCodes("12;?;?", codes); // second spec would be 13: dropped
    assert(codes[] == [12]);
}

@("oscColorQueryCodes.palettePairsAndInvalidIndices")
@safe nothrow @nogc
unittest
{
    UniqueBuffer!(int, 4) codes;
    assert(oscColorQueryCodes("4;0;?;1;#ff0000;255;?;256;?;-1;?;x;?;99999999999999999;?;17;?;3", codes) == 4);
    assert(codes[] == [0, 255, 17]);
}

@("oscColorQueryCodes.fragmentedPaletteBatch")
@safe nothrow @nogc
unittest
{
    OscScanner sc;
    UniqueBuffer!(int, 4) codes;
    foreach (chunk; ["\x1b]4;0;?;1;#123", "456;2;?;255;", "?\x1b", "\\"])
    {
        foreach (b; chunk)
        {
            if (oscScanByte(sc, b))
            {
                assert(!sc.overflowed);
                assert(!sc.endedWithBel);
                assert(oscColorQueryCodes(sc.payload[], codes) == 4);
            }
        }
    }
    assert(codes[] == [0, 2, 255]);
}

@("oscColorQueryCodes.fullPaletteBatch")
@safe nothrow @nogc
unittest
{
    OscScanner sc;
    foreach (b; "\x1b]4")
        oscScanByte(sc, b);
    foreach (index; 0 .. 256)
    {
        char[6] pair = [';', cast(char)('0' + index / 100),
            cast(char)('0' + index / 10 % 10), cast(char)('0' + index % 10),
            ';', '?'];
        foreach (b; pair[])
            oscScanByte(sc, b);
    }
    assert(oscScanByte(sc, '\x07'));
    assert(!sc.overflowed);
    UniqueBuffer!(int, 4) codes;
    assert(oscColorQueryCodes(sc.payload[], codes) == 4);
    assert(codes.length == 256);
    foreach (index, code; codes[])
        assert(code == index);
}

@("oscColorQueryCodes.effectivePaletteRepliesBeforeDA1")
@system nothrow @nogc
unittest
{
    import core.sys.posix.unistd : pipe, close, read;
    import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;
    import sparkles.ghostty.c;
    import sparkles.terminal_view.core : CoreState, feedPtyChunk,
        effect_write_pty, effect_device_attributes;

    int[2] fds;
    assert(pipe(fds) == 0);
    scope (exit)
    {
        close(fds[0]);
        close(fds[1]);
    }
    assert(fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0);
    CoreState s;
    GhosttyTerminalOptions options = { cols: 20, rows: 5 };
    assert(ghostty_terminal_new(null, &s.terminal, options) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(s.terminal);
    s.pty_fd = fds[1];
    s.effects_ctx.pty_fd = fds[1];
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_USERDATA,
        cast(const(void)*) &s.effects_ctx);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
        cast(const(void)*) &effect_write_pty);
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
        cast(const(void)*) &effect_device_attributes);

    feedPtyChunk(s, "\x1b]4;7;#123456;7;");
    feedPtyChunk(s, "?\x1b");
    feedPtyChunk(s, "\\\x1b]4;8;#abcdef;8;?\x07\x1b[c");
    char[256] reply;
    const count = read(fds[0], reply.ptr, reply.length);
    enum expected = "\x1b]4;7;rgb:1212/3434/5656\x1b\\"
        ~ "\x1b]4;8;rgb:abab/cdcd/efef\x07";
    assert(count > expected.length);
    assert(reply[0 .. expected.length] == expected);
    assert(reply[expected.length .. expected.length + 3] == "\x1b[?");
    assert(reply[count - 1] == 'c');
}
