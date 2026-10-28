/**
The editor's default keys (`EDK1`–`EDK5`): one table per target, binding
chords to named editor actions through the toolkit keymap, so every row is
rebindable (`KEY12`) and listed by the key guide.

Rows are matched in order and a chord ignores the modifiers it does not
name (`KEY9`), so each Shift-extending variant precedes its plain row.

Specification: `docs/specs/ui/editor.md` §4.
*/
module sparkles.ui.editor.keys;

import sparkles.input.events : Key, KeyAction, KeyEvent, ShiftReq, TextId, chord;
import sparkles.ui.editor.command : Boundary, EditCommand, EditKind;
import sparkles.ui.keymap : Binding, bind, commandFor;

/// What a key does in an editor; `commandOf` turns it into a command.
enum EditorAction : ubyte
{
    none,
    graphemeBack, graphemeForward, wordBack, wordForward,
    lineStart, lineEnd, lineUp, lineDown, pageUp, pageDown,
    documentStart, documentEnd,
    selectGraphemeBack, selectGraphemeForward, selectWordBack, selectWordForward,
    selectLineStart, selectLineEnd, selectLineUp, selectLineDown,
    selectPageUp, selectPageDown, selectDocumentStart, selectDocumentEnd,
    deleteBack, deleteForward, killWordBack, killWordForward, killBlankWordBack,
    killLineStart, killLineEnd, yank, yankPop,
    newline, tab, escape,
    selectAll, copy, cut, paste, undo, redo, earlier, later,
    addNextOccurrence, cursorAbove, cursorBelow, splitIntoLines,
}

/// The editor's one keymap scope.
enum EditorScope : ubyte
{
    editor,
}

/// Which default table applies (`EDK3`).
enum EditorTarget : ubyte
{
    /// A terminal: Readline keys, and `KBD3`'s reserved keys stay unbound.
    terminal,
    /// A window on macOS: `Cmd` chords.
    macWindow,
    /// A window on Linux or Windows: `Ctrl` chords; `Ctrl-A` selects all.
    window,
}

alias EditorBinding = Binding!(EditorAction, EditorScope);

/// The command an action runs.
EditCommand commandOf(EditorAction action) @safe pure nothrow @nogc
{
    alias A = EditorAction;
    alias C = EditCommand;
    final switch (action)
    {
    case A.none: return C.init;
    case A.graphemeBack: return C.grapheme(-1);
    case A.graphemeForward: return C.grapheme(1);
    case A.wordBack: return C.word(-1);
    case A.wordForward: return C.word(1);
    case A.lineStart: return C.lineBoundary(Boundary.start);
    case A.lineEnd: return C.lineBoundary(Boundary.end);
    case A.lineUp: return C.line(-1);
    case A.lineDown: return C.line(1);
    case A.pageUp: return C.page(-1);
    case A.pageDown: return C.page(1);
    case A.documentStart: return C.document(Boundary.start);
    case A.documentEnd: return C.document(Boundary.end);
    case A.selectGraphemeBack: return C.grapheme(-1, true);
    case A.selectGraphemeForward: return C.grapheme(1, true);
    case A.selectWordBack: return C.word(-1, true);
    case A.selectWordForward: return C.word(1, true);
    case A.selectLineStart: return C.lineBoundary(Boundary.start, true);
    case A.selectLineEnd: return C.lineBoundary(Boundary.end, true);
    case A.selectLineUp: return C.line(-1, true);
    case A.selectLineDown: return C.line(1, true);
    case A.selectPageUp: return C.page(-1, true);
    case A.selectPageDown: return C.page(1, true);
    case A.selectDocumentStart: return C.document(Boundary.start, true);
    case A.selectDocumentEnd: return C.document(Boundary.end, true);
    case A.deleteBack: return C.deleteGrapheme(-1);
    case A.deleteForward: return C.deleteGrapheme(1);
    case A.killWordBack: return C.killWord(-1);
    case A.killWordForward: return C.killWord(1);
    case A.killBlankWordBack: return C.of(EditKind.killBlankWord);
    case A.killLineStart: return C.killToLineBoundary(Boundary.start);
    case A.killLineEnd: return C.killToLineBoundary(Boundary.end);
    case A.yank: return C.of(EditKind.yank);
    case A.yankPop: return C.of(EditKind.yankPop);
    case A.newline: return C.of(EditKind.insertNewline);
    case A.tab: return C.of(EditKind.insertTab);
    case A.escape: return C.of(EditKind.escape);
    case A.selectAll: return C.of(EditKind.selectAll);
    case A.copy: return C.of(EditKind.copy);
    case A.cut: return C.of(EditKind.cut);
    case A.paste: return C.of(EditKind.paste);
    case A.undo: return C.of(EditKind.undo);
    case A.redo: return C.of(EditKind.redo);
    case A.earlier: return C.earlier(1);
    case A.later: return C.later(1);
    case A.addNextOccurrence: return C.of(EditKind.addNextOccurrence);
    case A.cursorAbove: return C.cursorVertical(-1);
    case A.cursorBelow: return C.cursorVertical(1);
    case A.splitIntoLines: return C.of(EditKind.splitIntoLines);
    }
}

/// The default table for `target`.
immutable(EditorBinding)[] editorBindings(EditorTarget target) @safe pure nothrow @nogc
{
    final switch (target)
    {
    case EditorTarget.terminal: return terminalTable;
    case EditorTarget.macWindow: return macTable;
    case EditorTarget.window: return windowTable;
    }
}

/**
The editor's command for `key`, or `false` when the editor declines it and
the key falls through to the application (`EDK5`). A printable key with no
command modifier becomes `insertText` of the text it produced (`EDI1`),
interned in `pool`.
*/
bool editorCommand(Pool)(in KeyEvent key, EditorTarget target, ref Pool pool,
    out EditCommand command)
{
    import sparkles.base.text.utf : encodeScalar;

    if (key.action == KeyAction.release)
        return false;
    const resolved = commandFor(editorBindings(target), key, NoContext.init);
    if (resolved.cmd != EditorAction.none)
    {
        command = commandOf(resolved.cmd);
        return true;
    }
    if (key.key != Key.char_ || key.mods.ctrl || key.mods.alt || key.mods.super_)
        return false;
    char[4] scalar;
    const text = key.text.length ? key.text : scalar[0 .. encodeScalar(key.ch, scalar[]).written];
    if (text.length == 0)
        return false;
    auto id = pool.intern(text);
    if (!id.hasValue)
        return false;
    command = EditCommand.insert(id.value);
    return true;
}


/// The table for a window on the platform this binary runs on.
version (OSX)
    enum EditorTarget windowTarget = EditorTarget.macWindow;
else
    enum EditorTarget windowTarget = EditorTarget.window;

/// Whether `target`'s default table binds `key` (`EDK5`): a host that hands
/// chords back to the application asks this first.
bool editorBinds(in KeyEvent key, EditorTarget target) @safe pure nothrow
    => commandFor(editorBindings(target), key, NoContext.init).cmd != EditorAction.none;

private:

struct NoContext
{
}

alias A = EditorAction;

/// Rows for a motion: the Shift variant extends, then the plain one.
void motion(ref EditorBinding[] rows, Key key, bool ctrl, bool alt, bool super_,
    A plain, A extending, string desc) @safe pure nothrow
{
    auto shifted = chord(key, ShiftReq.yes);
    shifted.ctrl = ctrl;
    shifted.alt = alt;
    shifted.super_ = super_;
    rows ~= bind(EditorScope.editor, shifted, extending, desc ~ ", extending");
    auto base = chord(key);
    base.ctrl = ctrl;
    base.alt = alt;
    base.super_ = super_;
    rows ~= bind(EditorScope.editor, base, plain, desc);
}

/// A row for a letter chord.
void letter(ref EditorBinding[] rows, dchar ch, bool ctrl, bool alt, bool super_, A action,
    string desc, ShiftReq shift = ShiftReq.ignore) @safe pure nothrow
{
    auto c = chord(ch, shift);
    c.ctrl = ctrl;
    c.alt = alt;
    c.super_ = super_;
    rows ~= bind(EditorScope.editor, c, action, desc);
}

/// A row for a named key.
void named(ref EditorBinding[] rows, Key key, bool ctrl, bool alt, bool super_, A action,
    string desc, ShiftReq shift = ShiftReq.ignore) @safe pure nothrow
{
    auto c = chord(key, shift);
    c.ctrl = ctrl;
    c.alt = alt;
    c.super_ = super_;
    rows ~= bind(EditorScope.editor, c, action, desc);
}

EditorBinding[] build(EditorTarget target) @safe pure nothrow
{
    const mac = target == EditorTarget.macWindow;
    const terminal = target == EditorTarget.terminal;
    const window = target == EditorTarget.window;
    EditorBinding[] rows;

    // Platform chords (EDK3) come first: they carry more modifiers than the
    // Readline and common rows they would otherwise be shadowed by.
    if (mac)
    {
        letter(rows, 'z', false, false, true, A.redo, "redo", ShiftReq.yes);
        letter(rows, 'z', false, false, true, A.undo, "undo");
        letter(rows, 'a', false, false, true, A.selectAll, "select all");
        letter(rows, 'c', false, false, true, A.copy, "copy");
        letter(rows, 'x', false, false, true, A.cut, "cut");
        letter(rows, 'v', false, false, true, A.paste, "paste");
        letter(rows, 'd', false, false, true, A.addNextOccurrence, "add next occurrence");
        named(rows, Key.up, false, true, true, A.cursorAbove, "add cursor above");
        named(rows, Key.down, false, true, true, A.cursorBelow, "add cursor below");
        motion(rows, Key.left, false, false, true, A.lineStart, A.selectLineStart, "line start");
        motion(rows, Key.right, false, false, true, A.lineEnd, A.selectLineEnd, "line end");
        motion(rows, Key.up, false, false, true, A.documentStart, A.selectDocumentStart,
            "document start");
        motion(rows, Key.down, false, false, true, A.documentEnd, A.selectDocumentEnd,
            "document end");
        motion(rows, Key.left, false, true, false, A.wordBack, A.selectWordBack, "word back");
        motion(rows, Key.right, false, true, false, A.wordForward, A.selectWordForward,
            "word forward");
    }
    if (window)
    {
        letter(rows, 'z', true, false, false, A.redo, "redo", ShiftReq.yes);
        letter(rows, 'z', true, false, false, A.undo, "undo");
        letter(rows, 'a', true, false, false, A.selectAll, "select all");
        letter(rows, 'c', true, false, false, A.copy, "copy");
        letter(rows, 'x', true, false, false, A.cut, "cut");
        letter(rows, 'v', true, false, false, A.paste, "paste");
        letter(rows, 'd', true, false, false, A.addNextOccurrence, "add next occurrence");
        named(rows, Key.backspace, true, false, false, A.killWordBack, "kill word back");
    }
    if (!mac)
    {
        named(rows, Key.up, false, true, false, A.cursorAbove, "add cursor above", ShiftReq.yes);
        named(rows, Key.down, false, true, false, A.cursorBelow, "add cursor below", ShiftReq.yes);
        motion(rows, Key.home, true, false, false, A.documentStart, A.selectDocumentStart,
            "document start");
        motion(rows, Key.end, true, false, false, A.documentEnd, A.selectDocumentEnd,
            "document end");
        motion(rows, Key.left, true, false, false, A.wordBack, A.selectWordBack, "word back");
        motion(rows, Key.right, true, false, false, A.wordForward, A.selectWordForward,
            "word forward");
    }
    if (terminal)
    {
        motion(rows, Key.left, false, true, false, A.wordBack, A.selectWordBack, "word back");
        motion(rows, Key.right, false, true, false, A.wordForward, A.selectWordForward,
            "word forward");
        letter(rows, '_', true, false, false, A.undo, "undo");
        letter(rows, '/', true, false, false, A.undo, "undo"); // the same byte, 0x1F
        letter(rows, '_', false, true, false, A.redo, "redo");
        letter(rows, 'a', true, false, false, A.selectAll, "select all", ShiftReq.yes);
        letter(rows, 'd', true, false, false, A.deleteForward, "delete forward");
    }
    letter(rows, 'i', false, true, false, A.splitIntoLines, "split into lines", ShiftReq.yes);
    letter(rows, 'u', false, true, false, A.later, "later", ShiftReq.yes);
    letter(rows, 'u', false, true, false, A.earlier, "earlier");

    // The Readline subset (EDK1); in a window off macOS, Ctrl-A was taken
    // by select all above.
    if (!window)
        letter(rows, 'a', true, false, false, A.lineStart, "line start");
    letter(rows, 'e', true, false, false, A.lineEnd, "line end");
    letter(rows, 'b', true, false, false, A.graphemeBack, "back");
    letter(rows, 'f', true, false, false, A.graphemeForward, "forward");
    letter(rows, 'u', true, false, false, A.killLineStart, "kill to line start");
    letter(rows, 'k', true, false, false, A.killLineEnd, "kill to line end");
    letter(rows, 'w', true, false, false, A.killBlankWordBack, "kill word back to blank");
    letter(rows, 'b', false, true, false, A.wordBack, "word back");
    letter(rows, 'f', false, true, false, A.wordForward, "word forward");
    named(rows, Key.backspace, false, true, false, A.killWordBack, "kill word back");
    letter(rows, 'd', false, true, false, A.killWordForward, "kill word forward");
    letter(rows, 'h', true, false, false, A.deleteBack, "delete back");
    letter(rows, 'y', true, false, false, A.yank, "yank");
    letter(rows, 'y', false, true, false, A.yankPop, "yank pop");

    // The common keys (EDK2).
    motion(rows, Key.left, false, false, false, A.graphemeBack, A.selectGraphemeBack, "back");
    motion(rows, Key.right, false, false, false, A.graphemeForward, A.selectGraphemeForward,
        "forward");
    motion(rows, Key.up, false, false, false, A.lineUp, A.selectLineUp, "line up");
    motion(rows, Key.down, false, false, false, A.lineDown, A.selectLineDown, "line down");
    motion(rows, Key.home, false, false, false, A.lineStart, A.selectLineStart, "line start");
    motion(rows, Key.end, false, false, false, A.lineEnd, A.selectLineEnd, "line end");
    motion(rows, Key.pageUp, false, false, false, A.pageUp, A.selectPageUp, "page up");
    motion(rows, Key.pageDown, false, false, false, A.pageDown, A.selectPageDown, "page down");
    named(rows, Key.backspace, false, false, false, A.deleteBack, "delete back");
    named(rows, Key.delete_, false, false, false, A.deleteForward, "delete forward");
    named(rows, Key.enter, false, false, false, A.newline, "newline");
    named(rows, Key.tab, false, false, false, A.tab, "tab");
    named(rows, Key.escape, false, false, false, A.escape, "escape");
    return rows;
}

static immutable EditorBinding[] terminalTable = build(EditorTarget.terminal);
static immutable EditorBinding[] macTable = build(EditorTarget.macWindow);
static immutable EditorBinding[] windowTable = build(EditorTarget.window);

version (unittest)
{
    import sparkles.input.events : Mods;
    import sparkles.ui.editor.testing : TestPool;

    EditorAction actionOf(EditorTarget target, KeyEvent key) @safe pure nothrow
        => commandFor(editorBindings(target), key, NoContext.init).cmd;

    KeyEvent ctrl(dchar ch) @safe pure nothrow @nogc => KeyEvent(Key.char_, ch, Mods(ctrl: true));
    KeyEvent alt(dchar ch) @safe pure nothrow @nogc => KeyEvent(Key.char_, ch, Mods(alt: true));
    KeyEvent cmd(dchar ch) @safe pure nothrow @nogc => KeyEvent(Key.char_, ch, Mods(super_: true));
    KeyEvent key(Key k, Mods m = Mods.init) @safe pure nothrow @nogc => KeyEvent(k, 0, m);
}

/// EDK1: the Readline subset on every target, `Ctrl-A` excepted in a window
/// off macOS.
@("editor.keys.readlineEverywhere")
@safe pure nothrow
unittest
{
    foreach (target; [EditorTarget.terminal, EditorTarget.macWindow, EditorTarget.window])
    {
        assert(actionOf(target, ctrl('e')) == A.lineEnd);
        assert(actionOf(target, ctrl('b')) == A.graphemeBack);
        assert(actionOf(target, ctrl('f')) == A.graphemeForward);
        assert(actionOf(target, ctrl('u')) == A.killLineStart);
        assert(actionOf(target, ctrl('k')) == A.killLineEnd);
        assert(actionOf(target, ctrl('w')) == A.killBlankWordBack);
        assert(actionOf(target, alt('b')) == A.wordBack);
        assert(actionOf(target, alt('f')) == A.wordForward);
        assert(actionOf(target, key(Key.backspace, Mods(alt: true))) == A.killWordBack);
        assert(actionOf(target, alt('d')) == A.killWordForward);
        assert(actionOf(target, ctrl('h')) == A.deleteBack);
        assert(actionOf(target, ctrl('y')) == A.yank);
        assert(actionOf(target, alt('y')) == A.yankPop);
        assert(actionOf(target, ctrl('a')) == (target == EditorTarget.window
            ? A.selectAll : A.lineStart));
    }
}

/// EDK2: the common keys, and Shift extends every motion.
@("editor.keys.commonAndShift")
@safe pure nothrow
unittest
{
    foreach (target; [EditorTarget.terminal, EditorTarget.macWindow, EditorTarget.window])
    {
        assert(actionOf(target, key(Key.left)) == A.graphemeBack);
        assert(actionOf(target, key(Key.left, Mods(shift: true))) == A.selectGraphemeBack);
        assert(actionOf(target, key(Key.home, Mods(shift: true))) == A.selectLineStart);
        assert(actionOf(target, key(Key.pageDown)) == A.pageDown);
        assert(actionOf(target, key(Key.backspace)) == A.deleteBack);
        assert(actionOf(target, key(Key.delete_)) == A.deleteForward);
        assert(actionOf(target, key(Key.enter)) == A.newline);
        assert(actionOf(target, key(Key.escape)) == A.escape);
    }
    assert(actionOf(EditorTarget.window, key(Key.left, Mods(ctrl: true, shift: true)))
        == A.selectWordBack);
    assert(actionOf(EditorTarget.macWindow, key(Key.right, Mods(alt: true, shift: true)))
        == A.selectWordForward);
}

/// EDK3: each platform's chords, as the owner decided EDQ1–EDQ3.
@("editor.keys.platformLayer")
@safe pure nothrow
unittest
{
    alias T = EditorTarget;
    // macOS
    assert(actionOf(T.macWindow, cmd('a')) == A.selectAll);
    assert(actionOf(T.macWindow, cmd('c')) == A.copy);
    assert(actionOf(T.macWindow, cmd('z')) == A.undo);
    assert(actionOf(T.macWindow, cmd('Z')) == A.redo);
    assert(actionOf(T.macWindow, cmd('d')) == A.addNextOccurrence);
    assert(actionOf(T.macWindow, key(Key.left, Mods(super_: true))) == A.lineStart);
    assert(actionOf(T.macWindow, key(Key.up, Mods(alt: true, super_: true))) == A.cursorAbove);
    // Linux and Windows, windowed
    assert(actionOf(T.window, ctrl('c')) == A.copy);
    assert(actionOf(T.window, ctrl('v')) == A.paste);
    assert(actionOf(T.window, ctrl('z')) == A.undo);
    assert(actionOf(T.window, ctrl('Z')) == A.redo);
    assert(actionOf(T.window, ctrl('d')) == A.addNextOccurrence);
    assert(actionOf(T.window, key(Key.backspace, Mods(ctrl: true))) == A.killWordBack);
    assert(actionOf(T.window, key(Key.down, Mods(alt: true, shift: true))) == A.cursorBelow);
    assert(actionOf(T.window, key(Key.up, Mods(ctrl: true, alt: true))) == A.lineUp,
        "Ctrl-Alt-Up stays GNOME's");
    // Terminal
    assert(actionOf(T.terminal, ctrl('_')) == A.undo);
    assert(actionOf(T.terminal, alt('_')) == A.redo);
    assert(actionOf(T.terminal, ctrl('d')) == A.deleteForward);
    assert(actionOf(T.terminal, key(Key.left, Mods(alt: true))) == A.wordBack);
    assert(actionOf(T.terminal, key(Key.left, Mods(ctrl: true))) == A.wordBack);
    assert(actionOf(T.terminal, key(Key.up, Mods(alt: true, shift: true))) == A.cursorAbove);
    foreach (target; [T.terminal, T.macWindow, T.window])
    {
        assert(actionOf(target, KeyEvent(Key.char_, 'I', Mods(alt: true))) == A.splitIntoLines);
        assert(actionOf(target, alt('u')) == A.earlier);
        assert(actionOf(target, alt('U')) == A.later);
    }
}

/// EDK4 and KBD3: the terminal table binds no reserved key; a window's may.
@("editor.keys.reservedInTerminals")
@safe pure nothrow
unittest
{
    import sparkles.ui.keymap_universal : KeyTarget, firstReserved;

    assert(firstReserved(editorBindings(EditorTarget.terminal)) == size_t.max);
    assert(firstReserved(editorBindings(EditorTarget.window)) != size_t.max,
        "Ctrl-C copies in a window");
    assert(firstReserved(editorBindings(EditorTarget.window), KeyTarget.window) == size_t.max);
    assert(actionOf(EditorTarget.terminal, ctrl('c')) == A.none);
    assert(actionOf(EditorTarget.terminal, ctrl('z')) == A.none);
}

/// EDK5 and EDI1: a printable key with no command modifier inserts its text,
/// a dead key's multi-scalar result whole; an unbound chord is declined.
@("editor.keys.typedTextAndDecline")
@safe pure nothrow
unittest
{
    auto pool = new TestPool;
    EditCommand c;
    assert(editorCommand(KeyEvent(Key.char_, 'x'), EditorTarget.terminal, *pool, c));
    assert(c.kind == EditKind.insertText);
    pool.withText(c.text, (scope const(char)[] s) { assert(s == "x"); });
    KeyEvent composed = KeyEvent(Key.char_, 'e');
    composed.text = "é";
    assert(editorCommand(composed, EditorTarget.window, *pool, c));
    pool.withText(c.text, (scope const(char)[] s) { assert(s == "é"); });
    assert(!editorCommand(ctrl('g'), EditorTarget.terminal, *pool, c), "unbound: falls through");
    assert(!editorCommand(KeyEvent(Key.char_, 'x', Mods.init, KeyAction.release),
        EditorTarget.window, *pool, c));
    assert(editorCommand(ctrl('w'), EditorTarget.terminal, *pool, c)
        && c.kind == EditKind.killBlankWord);
}
