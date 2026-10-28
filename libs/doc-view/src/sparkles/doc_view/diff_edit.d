/**
Inline editing of a diff's new side (`DST5`, the editor's `EDU1`).

When a diff session's new side is a file on disk (`DiffSession.editable`),
its text opens in the toolkit's editor and the file's diff is computed
again against the fixed old side as it is edited, so a reviewer fixes what
they read where they read it, as in Meld's live panes. Nothing reaches the
disk until an explicit save, and nothing is staged by one (`DST6`).

Re-diffing follows typing at once for a small file. A large one waits
until typing pauses, and so does syntax highlighting, which is never run
on the keystroke path (the editor's `EDR3`): the rows draw plain first and
the styled ones replace them when the edit settles.
*/
module sparkles.doc_view.diff_edit;

import core.time : Duration, MonoTime, msecs;

import sparkles.diff.engine : diffText;
import sparkles.diff.model : DiffDoc, DiffOptions;
import sparkles.input.events : CompositionEvent, KeyEvent;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.field : EditorField, FieldResult;
import sparkles.ui.editor.keys : EditorTarget;
import sparkles.ui.editor.selection : SelectionSet;
import sparkles.ui.editor.state : EditorOptions, EditorState;

/// A file of a diff session whose new side is being edited.
struct DiffEdit
{
    /// The session entry being edited.
    size_t entry;
    /// The file the new side is, as written by a save.
    string path;
    /// The paths the diff names its sides by.
    string oldPath, newPath;
    /// The fixed old side.
    string oldText;
    /// The file's text as last read or saved.
    string savedText;
    /// The new side, being edited.
    EditorField field;
    /// The edited text as of the last diff, and that diff.
    string text;
    /// ditto
    DiffDoc doc;
    /// Syntax highlighting matches `text` (`EDR3`).
    bool styled = true;

    private Text saved_;
    private MonoTime changedAt_;
    private bool rediffPending_;
    private DiffOptions options_;

    /// Below this many bytes, every edit re-diffs at once.
    enum size_t rediffAtOnceBelow = 64 * 1024;
    /// How long typing must pause before a large file re-diffs and the
    /// edited text is highlighted again.
    enum Duration settle = 150.msecs;

    /**
    Opens `newText`, the file at `path`, for editing against `oldText`, the
    caret at the start of 1-based line `caretLine` of the new side.
    */
    static DiffEdit open(size_t entry, string path, string oldPath, string newPath,
        string oldText, string newText, EditorTarget target, size_t caretLine = 1,
        DiffOptions options = DiffOptions.init) @safe
    {
        DiffEdit e;
        e.entry = entry;
        e.path = path;
        e.oldPath = oldPath;
        e.newPath = newPath;
        e.oldText = oldText;
        e.savedText = newText;
        e.options_ = options;
        e.saved_ = Text(newText);
        e.field = EditorField.make(newText, EditorOptions.init, target);
        const lines = e.field.state.text.lineCount;
        const line = caretLine == 0 ? 0 : (caretLine > lines ? lines : caretLine) - 1;
        e.field.state.selection = SelectionSet.caret(e.field.state.text.lineStart(line));
        e.rediff();
        return e;
    }

    /// The edits have not been saved.
    bool dirty() const @safe pure nothrow @nogc => field.state.text != saved_;

    /// The editor's state, for a view that draws the caret over the rows.
    ref const(EditorState) state() const return @safe pure nothrow @nogc => field.state;

    /// The 1-based new-side line of the primary caret.
    size_t caretLine() const @safe pure nothrow @nogc
        => field.state.text.lineOf(field.state.selection.primary.head) + 1;

    /// One key for the editor; the diff follows the edit (`EDR4`).
    FieldResult key(in KeyEvent k, MonoTime now = MonoTime.currTime) @safe
        => followed(field.key(k, now), now);

    /// A paste, or the answer to the editor's clipboard read (`EDI4`, `EDY5`).
    FieldResult paste(scope const(char)[] text, uint request, MonoTime now = MonoTime.currTime)
        @safe
        => followed(field.paste(text, request, now), now);

    /// Does the clipboard work the editor asked for (`EDY5`); a paste it
    /// answers is an edit like any other.
    FieldResult serve(Clipboard)(in Clipboard clipboard, MonoTime now = MonoTime.currTime)
    {
        import sparkles.ui.editor.field : serveClipboard;

        return followed(serveClipboard(field, clipboard), now);
    }

    /// An input method's composition (`EDI3`).
    FieldResult compose(in CompositionEvent update, scope const(char)[] preedit,
        MonoTime now = MonoTime.currTime) @safe
        => followed(field.compose(update, preedit, now), now);

    /**
    Catches up with the edits once typing has paused: re-diffs a large file
    and marks the text for highlighting again. Returns whether the view must
    rebuild.
    */
    bool tick(MonoTime now = MonoTime.currTime) @safe
    {
        if (now - changedAt_ < settle)
            return false;
        bool redraw;
        if (rediffPending_)
        {
            rediff();
            redraw = true;
        }
        if (!styled)
        {
            styled = true;
            redraw = true;
        }
        return redraw;
    }

    /**
    Writes the edited text to `path` through `write`, which reports a failure
    as a message. Returns that message, or `null` once saved.
    */
    string save(scope string delegate(string path, string text) @safe write) @safe
    {
        if (rediffPending_)
            rediff();
        else
            text = field.text;
        if (const error = write(path, text))
            return error;
        savedText = text;
        saved_ = field.state.text;
        return null;
    }

    private FieldResult followed(FieldResult r, MonoTime now) @safe
    {
        if (!r.changed)
            return r;
        styled = false;
        changedAt_ = now;
        if (field.state.text.length < rediffAtOnceBelow)
            rediff();
        else
            rediffPending_ = true;
        return r;
    }

    private void rediff() @safe
    {
        text = field.text;
        doc = diffText(oldText, text, oldPath, newPath, options_);
        rediffPending_ = false;
    }
}

/**
Writes `text` to `path` atomically: a sibling file, then a rename over the
original, so a failed write never leaves half a file. Returns the failure,
or `null`.
*/
string writeFileAtomically(string path, string text) @safe
{
    import std.exception : collectExceptionMsg;
    import std.file : remove, rename, write;

    const temporary = path ~ ".hue-save";
    if (const failure = collectExceptionMsg(write(temporary, text)))
        return failure;
    if (const failure = collectExceptionMsg(rename(temporary, path)))
    {
        cast(void) collectExceptionMsg(remove(temporary));
        return failure;
    }
    return null;
}

version (unittest)
{
    import sparkles.diff.model : RowKind;
    import sparkles.input.events : Key, Mods;

    private size_t added(in DiffDoc doc) @safe
    {
        size_t n;
        foreach (ref row; doc.rows[])
            n += row.kind == RowKind.added;
        return n;
    }
}

@("diff_edit.DiffEdit.rediffsAsItIsEdited")
@safe unittest
{
    // `DST5`: an edit re-diffs the file against the fixed side at once.
    auto e = DiffEdit.open(0, "f.txt", "f.txt", "f.txt", "a\nb\n", "a\nb\n",
        EditorTarget.window, caretLine: 2);
    assert(e.doc.files.length == 1 && added(e.doc) == 0, "no change yet");
    assert(e.caretLine == 2 && !e.dirty);
    e.key(KeyEvent(Key.char_, 'x'));
    assert(e.text == "a\nxb\n" && added(e.doc) == 1 && e.dirty);
    assert(!e.styled, "highlighting waits for the edit to settle (`EDR3`)");
    assert(e.tick(MonoTime.currTime + DiffEdit.settle * 2) && e.styled);
}

@("diff_edit.DiffEdit.savesThroughItsWriter")
@safe unittest
{
    auto e = DiffEdit.open(0, "dir/f.txt", "f.txt", "f.txt", "a\n", "a\n", EditorTarget.window);
    e.key(KeyEvent(Key.char_, 'z'));
    string written, at;
    assert(e.save((string path, string text) { at = path; written = text; return cast(string) null; }) is null);
    assert(at == "dir/f.txt" && written == "za\n" && !e.dirty);
    assert(e.save((string p, string t) => "disk full") == "disk full",
        "a failed write is reported, never ignored");
}

@("diff_edit.writeFileAtomically.replacesTheFile")
@system unittest
{
    import std.file : readText, remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir, "hue-diff-edit-save.txt");
    write(path, "old");
    scope (exit)
        remove(path);
    assert(writeFileAtomically(path, "new") is null);
    assert(readText(path) == "new");
    assert(writeFileAtomically(buildPath(tempDir, "no-such-dir", "f"), "x") !is null);
}
