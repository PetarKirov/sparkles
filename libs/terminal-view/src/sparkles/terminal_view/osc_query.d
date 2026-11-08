/// Streaming detection of OSC sequences in the child → terminal pty byte
/// stream, for the host-side observers of the OSCs libghostty-vt hands no data
/// out for (`sparkles.terminal_view.protocols`). core.d feeds every pty chunk
/// through an `OscScanner`, splitting the libghostty-vt feed at each complete
/// sequence. (The OSC 4/10/11/12 color queries libghostty-vt answers itself.)
module sparkles.terminal_view.osc_query;

import sparkles.base.buffer : UniqueBuffer;

/// Streaming scanner for OSC sequences. Tracks just enough state to extract
/// complete OSC payloads even when a sequence is split across read() chunks.
/// Payloads longer than their command's limit are marked overflowed and must
/// be ignored. The default limit accommodates all 256 palette queries; a
/// kitty notification chunk (OSC 99) may carry 4096 encoded bytes plus its
/// metadata, and an OSC 52 clipboard write up to 1 MiB decoded (`TPR20`).
struct OscScanner
{
    enum State : ubyte { ground, esc, osc, oscEsc }
    enum maxPayloadLength = 4096;
    /// ditto — OSC 99: a 4096-byte encoded chunk and its metadata.
    enum maxNotificationPayloadLength = 8192;
    /// ditto — OSC 52: `52;`, up to twelve selection letters, `;`, then the
    /// base64 of 1 MiB.
    enum maxClipboardPayloadLength = 3 + 12 + 1 + (1024 * 1024 + 2) / 3 * 4;
    State state;
    bool overflowed;
    bool endedWithBel; /// sequence terminator: BEL (true) or ESC \ (false)
    UniqueBuffer!(char, 48) payload;

    /// The cap for the payload collected so far, by its command prefix.
    size_t limit() const scope @safe pure nothrow @nogc
    {
        const p = payload[];
        if (p.length >= 3 && p[0] == '5' && p[1] == '2' && p[2] == ';')
            return maxClipboardPayloadLength;
        if (p.length >= 3 && p[0] == '9' && p[1] == '9' && p[2] == ';')
            return maxNotificationPayloadLength;
        return maxPayloadLength;
    }
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
            if (sc.payload.length < OscScanner.maxPayloadLength
                || sc.payload.length < sc.limit)
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
    foreach (b; "\x1b]2;")
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

@("oscScanByte.limitFollowsTheCommand")
@safe nothrow @nogc
unittest
{
    // OSC 52 may carry 1 MiB decoded: its base64 fits; one byte more does not.
    OscScanner sc;
    foreach (b; "\x1b]52;c;")
        oscScanByte(sc, b);
    foreach (i; 0 .. (1024 * 1024 + 2) / 3 * 4)
        oscScanByte(sc, 'A');
    assert(oscScanByte(sc, '\x07'));
    assert(!sc.overflowed);
    assert(sc.payload.length == 5 + (1024 * 1024 + 2) / 3 * 4);

    foreach (b; "\x1b]52;cpqs01234567;")
        oscScanByte(sc, b);
    foreach (i; 0 .. (1024 * 1024 + 2) / 3 * 4 + 1)
        oscScanByte(sc, 'A');
    assert(oscScanByte(sc, '\x07'));
    assert(sc.overflowed);

    // OSC 99 chunks: 4096 encoded bytes and their metadata.
    foreach (b; "\x1b]99;i=1:e=1;")
        oscScanByte(sc, b);
    foreach (i; 0 .. 4096)
        oscScanByte(sc, 'A');
    assert(oscScanByte(sc, '\x07'));
    assert(!sc.overflowed);
}

// libghostty-vt answers palette queries from the effective palette (an
// override earlier in the same OSC applies first), in stream order — before
// the DA1 reply that yazi stops reading at — with the query's terminator.
@("feedPtyChunk.colorQueriesReplyBeforeDA1")
@system nothrow @nogc
unittest
{
    import core.sys.posix.unistd : pipe, close, read;
    import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;
    import sparkles.ghostty;
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
    assert(newTerminal(&s.terminal, 20, 5) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(s.terminal);
    s.pty_fd = fds[1];
    s.effects_ctx.pty_fd = fds[1];
    ghostty_terminal_set(s.terminal, GHOSTTY_TERMINAL_OPT_USERDATA,
        cast(const(void)*) &s.effects_ctx);
    s.terminal.setEffect!GHOSTTY_TERMINAL_OPT_WRITE_PTY(&effect_write_pty);
    s.terminal.setEffect!GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES(&effect_device_attributes);

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
