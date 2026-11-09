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
    pushKeyboardMode = "\x1b[>13u", /// Push Kitty flags 1|4|8 (disambiguate + alternate keys + all keys as CSI u).
    popKeyboardMode  = "\x1b[<u",   /// Pop progressive keyboard enhancement mode.
}

/// Named DEC private modes; $(LREF writeModeSet)/$(LREF writeModeReset) cover
/// any of them without dedicated constants. The fixed spellings most callers
/// need are pre-rendered in $(LREF CtlSeq).
enum DecMode : ushort
{
    autowrap       = 7,    /// Autowrap (DECAWM); reset so a full-width last cell can't wrap.
    mouseButtons   = 1000, /// Mouse button press/release reporting.
    mouseDrag      = 1002, /// Mouse motion reporting while a button is held.
    mouseAnyMotion = 1003, /// Mouse motion reporting regardless of buttons (hover).
    focusReporting = 1004, /// Focus in/out reports (`CSI I` / `CSI O`).
    mouseSgr       = 1006, /// SGR extended mouse coordinate encoding.
    altScreen      = 1049, /// Alternate screen buffer.
    bracketedPaste = 2004, /// Bracketed paste.
    syncOutput     = 2026, /// Synchronized output (atomic frame flush).
    unicodeCore    = 2027, /// Grapheme-cluster width handling.
    colorScheme    = 2031, /// Light/dark color-scheme update reports.
    inBandResize   = 2048, /// In-band resize notifications.
}

/// Terminal pointer shapes (xterm OSC 22, the CSS `cursor` keywords —
/// kitty, ghostty, wezterm and foot honor them, others ignore the OSC).
/// `default_` restores the terminal's own pointer.
enum PointerShape : string
{
    default_ = "default",   /// the terminal's normal pointer
    text     = "text",      /// the I-beam over selectable text
    pointer  = "pointer",   /// the link hand
    ewResize = "ew-resize", /// horizontal resize (a vertical divider)
    nsResize = "ns-resize", /// vertical resize (a horizontal divider)
    grab     = "grab",      /// an open hand (draggable content)
    grabbing = "grabbing",  /// a closed hand (a drag in progress)
    nwseResize = "nwse-resize", /// diagonal resize: a top-left or bottom-right corner
    neswResize = "nesw-resize", /// diagonal resize: a top-right or bottom-left corner
}

/// The text cursor's shape. On a terminal each is a DECSCUSR blinking form
/// ($(LREF textCursorShapeParam)), so the terminal blinks it as its user set.
enum CursorShape : ubyte
{
    bar,       /// a thin vertical bar before the cell: where text is inserted
    block,     /// the whole cell
    underline, /// a line under the cell
}

/// The DECSCUSR parameter of `shape`, blinking: `CSI Ps SP q`.
int textCursorShapeParam(CursorShape shape) @safe pure nothrow @nogc
{
    final switch (shape)
    {
        case CursorShape.block: return 1;
        case CursorShape.underline: return 3;
        case CursorShape.bar: return 5;
    }
}

/**
Where, and whether, a frame shows the platform's text cursor (`HST20`): a cell
of the frame, counted from 0, and its shape. `visible` false hides it.
*/
struct TextCursor
{
    bool visible; ///
    int x;        /// column
    int y;        /// row
    CursorShape shape; ///
}

/// Writes the sequences that show `c` after a frame's cells were written —
/// position, shape, show — or hide it, into `w`.
void writeTextCursor(Writer)(ref Writer w, in TextCursor c)
{
    import sparkles.base.text.writers : writeText;

    if (!c.visible)
    {
        w.writeText(i"\x1b[?25l");
        return;
    }
    w.writeText(i"\x1b[$(c.y + 1);$(c.x + 1)H\x1b[$(textCursorShapeParam(c.shape)) q\x1b[?25h");
}

///
@("term_control.writeTextCursor")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : checkWriter;

    checkWriter!((ref b) => b.writeTextCursor(TextCursor(true, 4, 0, CursorShape.bar)))(
        "\x1b[1;5H\x1b[5 q\x1b[?25h");
    checkWriter!((ref b) => b.writeTextCursor(TextCursor.init))("\x1b[?25l");
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

/// Emit several DEC private modes as one composite set/reset
/// (`CSI ? m1;m2;… h|l`), CTFE-collapsed into a single `put` — the composed
/// counterpart of the one-mode overload above.
void writeEscapeSeq(DecMode[] modes, bool set, Writer)(ref Writer w)
if (modes.length > 0)
{
    enum string seq = () {
        import std.conv : to;

        string s = "\x1b[?";
        foreach (i, m; modes)
            s ~= (i ? ";" : "") ~ (cast(uint) m).to!string;
        return s ~ (set ? "h" : "l");
    }();
    put(w, seq);
}

/// Emit an xterm OSC 22 pointer-shape set, CTFE-collapsed into a single
/// `put` (see $(LREF PointerShape); unsupporting terminals ignore the OSC).
void writeEscapeSeq(PointerShape shape, Writer)(ref Writer w)
{
    enum string seq = "\x1b]22;" ~ cast(string) shape ~ "\x1b\\";
    put(w, seq);
}

/// Enable/disable SGR mouse reporting — button press/release, drag motion,
/// and the SGR extended coordinate encoding — in a single `put`. With
/// `motion`, any-event tracking replaces drag-only, so bare pointer motion
/// reports too (hover affordances — e.g. a resize cursor over a divider).
void writeMouseTracking(Writer)(ref Writer w, bool on, bool motion = false)
{
    with (DecMode) if (motion)
    {
        if (on)
            writeEscapeSeq!([mouseButtons, mouseAnyMotion, mouseSgr], true)(w);
        else
            writeEscapeSeq!([mouseButtons, mouseAnyMotion, mouseSgr], false)(w);
    }
    else
    {
        if (on)
            writeEscapeSeq!([mouseButtons, mouseDrag, mouseSgr], true)(w);
        else
            writeEscapeSeq!([mouseButtons, mouseDrag, mouseSgr], false)(w);
    }
}

/// Set the terminal's pointer shape from a runtime keyword (the CTFE
/// $(LREF writeEscapeSeq) overload covers the static spellings).
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
    import sparkles.base.buffer : SharedBuffer;

    SharedBuffer!(char, 64) b;
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
    import sparkles.base.buffer : SharedBuffer;

    SharedBuffer!(char, 16) b;
    writeCursorUp(b, 0);
    writeCursorDown(b, 0);
    assert(b[].length == 0);
}

@("termControl.modes.matchCtlSeqSpellings")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : SharedBuffer;

    // The pre-rendered CtlSeq spellings and the DecMode writers must agree.
    SharedBuffer!(char, 32) b;
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
    import sparkles.base.buffer : SharedBuffer;

    SharedBuffer!(char, 32) b;
    // Fixed CtlSeq → its literal in one put.
    writeEscapeSeq!(CtlSeq.hideCursor)(b);
    assert(b[] == "\x1b[?25l");
    assert(cast(string) CtlSeq.pushKeyboardMode == "\x1b[>13u");

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
    b.clear();
    writeEscapeSeq!([DecMode.mouseButtons, DecMode.mouseSgr], true)(b);
    assert(b[] == "\x1b[?1000;1006h");

    // Pointer shape (OSC 22): the CTFE enum spelling and the runtime one.
    b.clear();
    writeEscapeSeq!(PointerShape.ewResize)(b);
    assert(b[] == "\x1b]22;ew-resize\x1b\\");
    b.clear();
    writePointerShape(b, "ns-resize");
    assert(b[] == "\x1b]22;ns-resize\x1b\\");
}
