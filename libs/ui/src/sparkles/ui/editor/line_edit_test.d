/**
Example tests for indentation, auto-indent and line comments (`EDC12`,
`EDC13`) through the editor step.
*/
module sparkles.ui.editor.line_edit_test;

version (unittest):

import sparkles.ui.editor.command : EditKind;
import sparkles.ui.editor.effect : EffectKind, NoopReason;
import sparkles.ui.editor.line_edit : IndentOptions;
import sparkles.ui.editor.state : EditorOptions, ReadOnlySpan;
import sparkles.ui.editor.testing : Harness;

alias K = EditKind;

EditorOptions spaces(ubyte width) @safe pure nothrow @nogc
{
    EditorOptions options;
    options.indent = IndentOptions(useTabs: false, width: width);
    return options;
}

EditorOptions commenting(string token) @safe pure nothrow @nogc
{
    EditorOptions options;
    options.lineComment = token;
    return options;
}

/// Tab inserts spaces to the next stop of the configured width.
@("editor.indent.spacesToTheNextStop")
@safe pure nothrow
unittest
{
    foreach (width, expected; [2: "ab  |c", 4: "ab  |c", 8: "ab      |c"])
    {
        auto h = Harness("ab|c", spaces(cast(ubyte) width));
        h(K.insertTab);
        assert(h.shown == expected, expected);
    }
    auto start = Harness("|x", spaces(8));
    start(K.insertTab);
    assert(start.shown == "        |x");
    // A tab already on the line counts to its stop.
    auto afterTab = Harness("\ta|", spaces(4));
    afterTab(K.insertTab);
    assert(afterTab.shown == "\ta   |");
}

/// Tabs mode, the default, inserts one tab and replaces a one-line selection.
@("editor.indent.tabsMode")
@safe pure nothrow
unittest
{
    auto h = Harness("a|b");
    h(K.insertTab);
    assert(h.shown == "a\t|b");
    auto replaced = Harness("a[bc]d");
    replaced(K.insertTab);
    assert(replaced.shown == "a\t|d");
}

/// Each caret indents to its own column's stop, in one revision.
@("editor.indent.multipleCarets")
@safe pure nothrow
unittest
{
    auto h = Harness("a|\nabc|", spaces(4));
    h(K.insertTab);
    assert(h.shown == "a   |\nabc |");
    h(K.undo);
    assert(h.shown == "a|\nabc|");
}

/// A selection over several lines indents and outdents each touched line;
/// empty lines stay empty and the selection keeps covering the lines.
@("editor.indent.multiLineIndentOutdent")
@safe pure nothrow
unittest
{
    auto h = Harness("[ab\ncd\n\nef]", spaces(4));
    h(K.insertTab);
    assert(h.shown == "[    ab\n    cd\n\n    ef]");
    h(K.outdent);
    assert(h.shown == "[ab\ncd\n\nef]");

    auto tabs = Harness("[a\n\tb]");
    tabs(K.insertTab);
    assert(tabs.shown == "[\ta\n\t\tb]");
    tabs(K.outdent)(K.outdent);
    assert(tabs.shown == "[a\nb]");

    // A range ending at a line's start does not touch that line.
    auto whole = Harness("[a\nb\n]c", spaces(2));
    whole(K.insertTab);
    assert(whole.shown == "[  a\n  b\n]c");
}

/// Outdent removes one tab or the spaces back to the previous stop, from the
/// caret's line too.
@("editor.indent.outdentToThePreviousStop")
@safe pure nothrow
unittest
{
    auto h = Harness("      a|", spaces(4));
    h(K.outdent);
    assert(h.shown == "    a|");
    h(K.outdent);
    assert(h.shown == "a|");
    h(K.outdent);
    assert(h.effects.first(EffectKind.noop).reason == NoopReason.nothingToDo);
    auto mixed = Harness("\t  x|", spaces(4));
    mixed(K.outdent);
    assert(mixed.shown == "  x|");
    // Without tabInserts the key belongs to the application.
    EditorOptions focus;
    focus.tabInserts = false;
    auto field = Harness("\tx|", focus);
    field(K.outdent);
    assert(field.shown == "\tx|");
}

/// Auto-indent repeats the line's blanks exactly, spaces and tabs mixed, for
/// every caret; a caret inside the indentation repeats only what precedes it.
@("editor.indent.autoIndentPreservesMixedBlanks")
@safe pure nothrow
unittest
{
    EditorOptions options;
    options.indent.autoIndent = true;
    auto h = Harness("\t  x|", options);
    h(K.insertNewline);
    assert(h.shown == "\t  x\n\t  |");
    auto inside = Harness("  |  x", options);
    inside(K.insertNewline);
    assert(inside.shown == "  \n  |  x");
    auto carets = Harness("\ta|\n  b|", options);
    carets(K.insertNewline);
    assert(carets.shown == "\ta\n\t|\n  b\n  |");
    carets(K.undo);
    assert(carets.shown == "\ta|\n  b|", "one undo step");
    // Off by default: Enter inserts LF alone.
    auto plain = Harness("  a|");
    plain(K.insertNewline);
    assert(plain.shown == "  a\n|");
}

/// CRLF documents: line edits keep the CR LF, and generic Enter stays LF.
@("editor.indent.crlfDocuments")
@safe pure nothrow
unittest
{
    auto h = Harness("[  a\r\n  b]", spaces(2));
    h(K.insertTab);
    assert(h.shown == "[    a\r\n    b]");
    h(K.outdent)(K.outdent);
    assert(h.shown == "[a\r\nb]");
    EditorOptions options;
    options.indent.autoIndent = true;
    auto enter = Harness("  a|\r\nb", options);
    enter(K.insertNewline);
    assert(enter.shown == "  a\n  |\r\nb");
    auto commented = Harness("[a\r\n  b]", commenting("#"));
    commented(K.toggleLineComment);
    assert(commented.shown == "[# a\r\n#   b]");
    commented(K.toggleLineComment);
    assert(commented.shown == "[a\r\n  b]");
}

/// Commenting inserts the token at the smallest indentation; toggling again
/// restores the text exactly. Blank lines are left alone.
@("editor.comment.roundTrip")
@safe pure nothrow
unittest
{
    const original = "[  a\n    b\n\n   \n  c]";
    auto h = Harness(original, commenting("//"));
    h(K.toggleLineComment);
    assert(h.shown == "[  // a\n  //   b\n\n   \n  // c]");
    h(K.toggleLineComment);
    assert(h.shown == original);
    // A caret comments its own line and moves with the text.
    auto caret = Harness("x\n  y|", commenting("--"));
    caret(K.toggleLineComment);
    assert(caret.shown == "x\n  -- y|");
    caret(K.toggleLineComment);
    assert(caret.shown == "x\n  y|");
}

/// Mixed commented and uncommented lines are all commented; a comment without
/// the space after its token uncomments too.
@("editor.comment.mixedLines")
@safe pure nothrow
unittest
{
    auto h = Harness("[// a\nb]", commenting("//"));
    h(K.toggleLineComment);
    assert(h.shown == "[// // a\n// b]");
    h(K.toggleLineComment);
    assert(h.shown == "[// a\nb]");
    auto tight = Harness("[//a\n  //b]", commenting("//"));
    tight(K.toggleLineComment);
    assert(tight.shown == "[a\n  b]");
    auto blank = Harness("[\n  \n]", commenting("//"));
    blank(K.toggleLineComment);
    assert(blank.effects.first(EffectKind.noop).reason == NoopReason.nothingToDo);
}

/// Every caret's line toggles in one revision, and undo restores the text
/// and the ranges in one step.
@("editor.comment.multipleCaretsUndoInOneStep")
@safe pure nothrow
unittest
{
    auto h = Harness("a|\nb\nc|", commenting("#"));
    h(K.toggleLineComment);
    assert(h.shown == "# a|\nb\n# c|");
    assert(h.effects.has(EffectKind.changed));
    h(K.undo);
    assert(h.shown == "a|\nb\nc|");
    h(K.redo);
    assert(h.shown == "# a|\nb\n# c|");
}

/// Without a token the command is unavailable: a reported no-op.
@("editor.comment.noToken")
@safe pure nothrow
unittest
{
    auto h = Harness("a|");
    h(K.toggleLineComment);
    assert(h.shown == "a|");
    assert(h.effects.first(EffectKind.noop).reason == NoopReason.noLineComment);
}

/// A line edit touching a protected line is refused whole; other lines edit.
@("editor.indent.protectedLinesRefuseTheEdit")
@safe pure nothrow
unittest
{
    auto h = Harness("[ro\nab]", commenting("//"));
    h.state.readOnly.put(ReadOnlySpan(0, 2));
    h(K.toggleLineComment);
    assert(h.shown == "[ro\nab]" && h.effects.has(EffectKind.rejectedReadOnly));
    h(K.insertTab);
    assert(h.shown == "[ro\nab]" && h.effects.has(EffectKind.rejectedReadOnly));
    // A protected span ending at a line's break leaves the next line free.
    auto next = Harness("ro\nab|", commenting("//"));
    next.state.readOnly.put(ReadOnlySpan(0, 3));
    next(K.toggleLineComment);
    assert(next.shown == "ro\n// ab|");
    next(K.undo);
    assert(next.shown == "ro\nab|");
}
