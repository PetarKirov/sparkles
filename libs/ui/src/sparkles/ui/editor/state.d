/**
The editor's state (`EDT1`): a Regular value advanced only by `step`.

Specification: `docs/specs/ui/editor.md` §2.
*/
module sparkles.ui.editor.state;

import core.time : Duration, MonoTime, msecs;

import sparkles.base.buffer : SharedBuffer;
import sparkles.input.events : CompositionRun, maxCompositionRuns;
import sparkles.text_buffer.history : History;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.command : EditKind;
import sparkles.ui.editor.selection : EditRange, SelectionSet;

/// How an editor behaves.
struct EditorOptions
{
    /// The state never holds a line break; Enter submits (`EDT8`).
    bool singleLine;
    /// `insertTab` inserts a tab; otherwise it does nothing and the key
    /// falls through to the application, which moves focus.
    bool tabInserts = true;
    /// Typed insertions and one-grapheme deletions closer than this coalesce
    /// into one undo step (`EDT6`).
    Duration coalesceInterval = 500.msecs;
    /// Typed and inserted text is accepted only when every scalar passes;
    /// `null` accepts everything (`EDU4`: a go-to-line field takes digits).
    bool function(dchar) @safe pure nothrow @nogc accepts;
    /// The most bytes the text may hold; 0 is unbounded. An insertion,
    /// paste or yank that would exceed it is refused whole.
    size_t maxLength;
}

/// A protected range of the text (`EDT10`).
struct ReadOnlySpan
{
    size_t start;
    size_t end;
}

/**
What the step remembers about the commands before this one: enough to
coalesce typing (`EDT6`), join consecutive kills (`EDY2`), cycle yanks
(`EDY3`) and match a clipboard answer to its request (`EDY5`).
*/
struct CommandRecord
{
    /// The previous command's kind and direction.
    EditKind last;
    byte lastDirection;
    /// The previous command was an edit that a like edit may join, and the
    /// ranges and time it left.
    bool coalescible;
    SelectionSet afterEdit;
    MonoTime lastEditTime;
    /// Ranges of the current kill run, or 0 outside one.
    size_t killRun;
    /// The spans the last yank inserted, and how many kills back it was.
    SharedBuffer!(EditRange, 2) yanked;
    size_t yankAge;
    /// The clipboard read awaiting its answer, or 0; the next number to use.
    uint pendingRequest;
    uint nextRequest = 1;
}

/**
An input method's composition in progress (`EDI3`): shown in place of each
range and not part of the text until committed. The preedit is a copy; the
event that carried it names text only until the host's next poll.
*/
struct Composition
{
    /// The preedit; empty when no composition is in progress.
    Text preedit;
    /// The preedit cursor, in bytes from its start.
    size_t cursor;
    /// The preedit's styled runs, in bytes from its start.
    CompositionRun[maxCompositionRuns] runs;
    /// ditto
    ubyte runCount;

    /// A composition is in progress.
    bool active() const scope @safe pure nothrow @nogc => preedit.length != 0;

    /// The styled runs.
    const(CompositionRun)[] styled() const return @safe pure nothrow @nogc
        => runs[0 .. runCount];
}

/// The editor's whole state.
struct EditorState
{
    Text text;
    SelectionSet selection;
    History!SelectionSet history;
    SharedBuffer!(ReadOnlySpan, 1) readOnly;
    Composition composition;
    EditorOptions options;
    CommandRecord record;

    /// A state holding `text` with a caret at its end.
    static EditorState create(Text text, EditorOptions options = EditorOptions.init,
        MonoTime time = MonoTime.init) @safe pure nothrow @nogc
    {
        EditorState state;
        state.text = text;
        state.options = options;
        state.selection = SelectionSet.caret(text.length);
        state.history = History!SelectionSet(state.selection, text.length, time);
        return state;
    }

    /// ditto
    static EditorState create(scope const(char)[] text,
        EditorOptions options = EditorOptions.init, MonoTime time = MonoTime.init)
        @safe pure nothrow @nogc
        => create(Text(text), options, time);
}
