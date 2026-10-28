/**
The editor's command vocabulary (`EDC1`–`EDC11`).

Commands are named by effect, not by key, so any key table can bind them
(`KEY11`). A command is a small pointer-free value: text arrives as a
`TextId` into the host's input text pool, so a command can sit in a key
table, an event queue or a recording and be compared with `==`.

Specification: `docs/specs/ui/editor.md` §3.
*/
module sparkles.ui.editor.command;

import sparkles.input.events : CompositionEvent, TextId;

/// What a command does.
enum EditKind : ubyte
{
    none,
    // EDC1
    insertText,
    insertNewline,
    insertTab,
    // EDC2
    moveGrapheme,
    deleteGrapheme,
    // EDC3
    moveWord,
    killWord,
    killBlankWord,
    // EDC4
    moveLineBoundary,
    killToLineBoundary,
    // EDC5
    moveLine,
    movePage,
    moveDocument,
    // EDC6
    selectAll,
    selectWord,
    selectLine,
    collapseToPrimary,
    setRange,
    // EDC7
    addNextOccurrence,
    skipOccurrence,
    selectAllOccurrences,
    addCursorVertical,
    splitIntoLines,
    addRangeAt,
    removeRangeAt,
    columnSelect,
    // EDC8
    undo,
    redo,
    earlier,
    later,
    // EDC9
    yank,
    yankPop,
    copy,
    cut,
    paste,
    pasteAnswer,
    // EDC10
    compose,
    commitComposition,
    // EDC11
    submit,
    cancel,
    /// Escape (`EDK2`): cancel composition, else collapse to the primary
    /// range, else cancel the field.
    escape,
    /// The editor lost focus: a pending clipboard answer will be dropped.
    blur,
}

/// Which end of a line or the document.
enum Boundary : ubyte
{
    start,
    end,
}

/// One editing command.
struct EditCommand
{
    EditKind kind;
    /// -1 backward, +1 forward, for directional commands.
    byte direction;
    /// Move the head and keep the anchor.
    bool extend;
    Boundary boundary;
    /// `insertText` came from a paste: never coalesced, line breaks become
    /// spaces in single-line mode.
    bool paste;
    /// Positions or counts: `setRange` anchor and head, `addRangeAt` and
    /// `removeRangeAt` position, `columnSelect` from and to, `earlier` and
    /// `later` steps.
    size_t a;
    size_t b;
    /// `pasteAnswer`: the clipboard request answered.
    uint request;
    /// `insertText`, `pasteAnswer`, `compose`, `commitComposition`: the text.
    TextId text;
    /// `compose`: the preedit's cursor and styled runs (its text is `text`).
    CompositionEvent composition;

@safe pure nothrow @nogc:

    static EditCommand of(EditKind kind) => EditCommand(kind);

    static EditCommand insert(TextId text, bool paste = false)
        => EditCommand(EditKind.insertText, paste: paste, text: text);

    static EditCommand grapheme(int direction, bool extend = false)
        => EditCommand(EditKind.moveGrapheme, cast(byte) direction, extend);

    static EditCommand deleteGrapheme(int direction)
        => EditCommand(EditKind.deleteGrapheme, cast(byte) direction);

    static EditCommand word(int direction, bool extend = false)
        => EditCommand(EditKind.moveWord, cast(byte) direction, extend);

    static EditCommand killWord(int direction)
        => EditCommand(EditKind.killWord, cast(byte) direction);

    static EditCommand lineBoundary(Boundary boundary, bool extend = false)
        => EditCommand(EditKind.moveLineBoundary, extend: extend, boundary: boundary);

    static EditCommand killToLineBoundary(Boundary boundary)
        => EditCommand(EditKind.killToLineBoundary, boundary: boundary);

    static EditCommand line(int direction, bool extend = false)
        => EditCommand(EditKind.moveLine, cast(byte) direction, extend);

    static EditCommand page(int direction, bool extend = false)
        => EditCommand(EditKind.movePage, cast(byte) direction, extend);

    static EditCommand document(Boundary boundary, bool extend = false)
        => EditCommand(EditKind.moveDocument, extend: extend, boundary: boundary);

    static EditCommand setRange(size_t anchor, size_t head)
        => EditCommand(EditKind.setRange, a: anchor, b: head);

    static EditCommand cursorVertical(int direction)
        => EditCommand(EditKind.addCursorVertical, cast(byte) direction);

    static EditCommand addRangeAt(size_t position) => EditCommand(EditKind.addRangeAt, a: position);

    static EditCommand removeRangeAt(size_t position)
        => EditCommand(EditKind.removeRangeAt, a: position);

    static EditCommand columnSelect(size_t from, size_t to)
        => EditCommand(EditKind.columnSelect, a: from, b: to);

    static EditCommand earlier(size_t steps) => EditCommand(EditKind.earlier, a: steps);

    static EditCommand later(size_t steps) => EditCommand(EditKind.later, a: steps);

    static EditCommand pasteAnswer(uint request, TextId text)
        => EditCommand(EditKind.pasteAnswer, request: request, text: text);

    static EditCommand compose(in CompositionEvent update)
        => EditCommand(EditKind.compose, text: update.preedit, composition: update);

    static EditCommand commitComposition(TextId text)
        => EditCommand(EditKind.commitComposition, text: text);
}
