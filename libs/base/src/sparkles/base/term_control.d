/++
Terminal control-sequence emission: cursor movement, erase, screen modes.

The non-SGR counterpart of `sparkles.base.term_style` (which deliberately covers
only styling). Sequences are hardcoded — no terminfo — following the modern
no-terminfo consensus surveyed in `docs/research/tui-libraries/` (libvaxis's
`ctlseqs` model); fixed sequences are `enum` strings ($(LREF CtlSeq)), and
parameterized ones are `@nogc` writer functions per the `writers.d` idiom.

Emission only: whether a terminal *interprets* these is the caller's decision,
gated by `sparkles.base.term_caps` (piped output should never see them).
Parsing/tokenizing escapes lives in `sparkles.base.text.ansi`.
+/
module sparkles.base.term_control;

import std.range.primitives : put;

import sparkles.base.text.writers : writeInteger;

/// Fixed control sequences for redraw-in-place and screen management.
enum CtlSeq : string
{
    csi            = "\x1b[",      /// Control Sequence Introducer.
    carriageReturn = "\r",         /// Return to column 0 (redraw the current line).
    eraseLine      = "\x1b[2K",    /// Erase the entire current line (EL 2).
    eraseToEnd     = "\x1b[0K",    /// Erase from the cursor to end of line (EL 0).
    eraseDisplay   = "\x1b[2J",    /// Erase the entire screen (ED 2).
    eraseBelow     = "\x1b[0J",    /// Erase from the cursor to end of screen (ED 0).
    cursorHome     = "\x1b[H",     /// Move the cursor to (1, 1).
    hideCursor     = "\x1b[?25l",  /// Hide the cursor.
    showCursor     = "\x1b[?25h",  /// Show the cursor.
    enterAltScreen = "\x1b[?1049h", /// Switch to the alternate screen buffer.
    exitAltScreen  = "\x1b[?1049l", /// Return to the primary screen buffer.
    syncBegin      = "\x1b[?2026h", /// Begin synchronized output (DEC 2026).
    syncEnd        = "\x1b[?2026l", /// End synchronized output — flush the frame.
}

/// Named DEC private modes; $(LREF writeModeSet)/$(LREF writeModeReset) cover
/// any of them without dedicated constants. The fixed spellings most callers
/// need are pre-rendered in $(LREF CtlSeq).
enum DecMode : ushort
{
    autowrap       = 7,    /// Autowrap (DECAWM); reset so a full-width last cell can't wrap.
    altScreen      = 1049, /// Alternate screen buffer.
    bracketedPaste = 2004, /// Bracketed paste.
    syncOutput     = 2026, /// Synchronized output (atomic frame flush).
    unicodeCore    = 2027, /// Grapheme-cluster width handling.
    colorScheme    = 2031, /// Light/dark color-scheme update reports.
    inBandResize   = 2048, /// In-band resize notifications.
}

// Every writer below emits nothing for a zero argument: CSI treats a missing/0
// parameter as 1, so "move by 0" must not become "move by 1".

/// Emit `CSI n A` — cursor up `n` rows.
void writeCursorUp(Writer)(ref Writer w, uint n)
{
    if (n == 0)
        return;
    put(w, CtlSeq.csi);
    writeInteger(w, n);
    put(w, 'A');
}

/// Emit `CSI n B` — cursor down `n` rows.
void writeCursorDown(Writer)(ref Writer w, uint n)
{
    if (n == 0)
        return;
    put(w, CtlSeq.csi);
    writeInteger(w, n);
    put(w, 'B');
}

/// Emit `CSI col G` — cursor to (1-based) column `col` of the current row.
void writeCursorColumn(Writer)(ref Writer w, uint col)
in (col >= 1, "terminal columns are 1-based")
{
    put(w, CtlSeq.csi);
    writeInteger(w, col);
    put(w, 'G');
}

/// Emit `CSI row ; col H` (CUP) — cursor to the (1-based) cell.
void writeCursorTo(Writer)(ref Writer w, uint row, uint col)
in (row >= 1 && col >= 1, "terminal cells are 1-based")
{
    put(w, CtlSeq.csi);
    writeInteger(w, row);
    put(w, ';');
    writeInteger(w, col);
    put(w, 'H');
}

/// Emit `CSI ? m h` — set a DEC private mode.
void writeModeSet(Writer)(ref Writer w, DecMode m)
{
    put(w, CtlSeq.csi);
    put(w, '?');
    writeInteger(w, cast(uint) m);
    put(w, 'h');
}

/// Emit `CSI ? m l` — reset a DEC private mode.
void writeModeReset(Writer)(ref Writer w, DecMode m)
{
    put(w, CtlSeq.csi);
    put(w, '?');
    writeInteger(w, cast(uint) m);
    put(w, 'l');
}

/// Emit a fixed $(LREF CtlSeq) in a single `put`. Because `seq` is a compile-time
/// parameter this is just `put(w, cast(string) seq)` — but writing
/// `writeEscapeSeq!(CtlSeq.hideCursor)(w)` keeps call sites uniform with the
/// parameterized overload below, whose whole point is CTFE-collapsing a multi-part
/// sequence into one `put`.
void writeEscapeSeq(CtlSeq seq, Writer)(ref Writer w)
{
    put(w, cast(string) seq);
}

/// Emit a DEC private-mode set/reset (`CSI ? mode h|l`) in a **single** `put`:
/// because `mode`/`set` are compile-time, the whole sequence is assembled by CTFE
/// into one string constant, rather than the several `put`s ($(D CSI), digits,
/// `h`/`l`) that the runtime $(LREF writeModeSet)/$(LREF writeModeReset) emit.
void writeEscapeSeq(DecMode mode, bool set, Writer)(ref Writer w)
{
    import std.conv : to;

    enum string seq = "\x1b[?" ~ (cast(uint) mode).to!string ~ (set ? "h" : "l");
    put(w, seq);
}

/// Enable/disable SGR mouse reporting — button press/release (1000), drag (1002),
/// and the SGR extended coordinate encoding (1006) — in a single `put`. With
/// `motion`, any-event tracking (1003) replaces 1002, so bare pointer motion
/// reports too (hover affordances — e.g. a resize cursor over a divider).
void writeMouseTracking(Writer)(ref Writer w, bool on, bool motion = false)
{
    if (motion)
        put(w, on ? "\x1b[?1000;1003;1006h" : "\x1b[?1000;1003;1006l");
    else
        put(w, on ? "\x1b[?1000;1002;1006h" : "\x1b[?1000;1002;1006l");
}

/// Set the terminal's pointer shape (xterm OSC 22; kitty, ghostty, wezterm
/// and foot honor it, others ignore it): a CSS cursor keyword — `default`,
/// `ew-resize`, `pointer`, `text`, … An empty/`default` shape restores the
/// terminal's own choice.
void writePointerShape(Writer)(ref Writer w, scope const(char)[] shape)
{
    put(w, "\x1b]22;");
    put(w, shape);
    put(w, "\x1b\\");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("termControl.writeCursor.sequences")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) b;
    writeCursorUp(b, 3);
    assert(b[] == "\x1b[3A");

    b.clear();
    writeCursorDown(b, 12);
    assert(b[] == "\x1b[12B");

    b.clear();
    writeCursorColumn(b, 1);
    assert(b[] == "\x1b[1G");

    b.clear();
    writeCursorTo(b, 5, 40);
    assert(b[] == "\x1b[5;40H");
}

@("termControl.writeCursor.zeroEmitsNothing")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 16) b;
    writeCursorUp(b, 0);
    writeCursorDown(b, 0);
    assert(b[].length == 0);
}

@("termControl.modes.matchCtlSeqSpellings")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // The pre-rendered CtlSeq spellings and the DecMode writers must agree.
    SmallBuffer!(char, 32) b;
    writeModeSet(b, DecMode.syncOutput);
    assert(b[] == CtlSeq.syncBegin);

    b.clear();
    writeModeReset(b, DecMode.syncOutput);
    assert(b[] == CtlSeq.syncEnd);

    b.clear();
    writeModeSet(b, DecMode.altScreen);
    assert(b[] == CtlSeq.enterAltScreen);

    b.clear();
    writeModeReset(b, DecMode.bracketedPaste);
    assert(b[] == "\x1b[?2004l");
}

@("termControl.writeEscapeSeq.compileTime")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) b;
    // Fixed CtlSeq → its literal in one put.
    writeEscapeSeq!(CtlSeq.hideCursor)(b);
    assert(b[] == "\x1b[?25l");

    // DEC mode set/reset assembled at compile time; must match the runtime writers.
    b.clear();
    writeEscapeSeq!(DecMode.autowrap, false)(b);
    assert(b[] == "\x1b[?7l");
    b.clear();
    writeEscapeSeq!(DecMode.syncOutput, true)(b);
    assert(b[] == CtlSeq.syncBegin);

    // Composite SGR-mouse enable/disable.
    b.clear();
    writeMouseTracking(b, true);
    assert(b[] == "\x1b[?1000;1002;1006h");
    b.clear();
    writeMouseTracking(b, false);
    assert(b[] == "\x1b[?1000;1002;1006l");
    b.clear();
    writeMouseTracking(b, true, motion: true);
    assert(b[] == "\x1b[?1000;1003;1006h");

    // Pointer shape (OSC 22).
    b.clear();
    writePointerShape(b, "ew-resize");
    assert(b[] == "\x1b]22;ew-resize\x1b\\");
}
