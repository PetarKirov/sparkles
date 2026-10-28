/**
Test support for the editor: build a state from marked text, run commands,
and show the result as marked text.

In marked text `|` is a caret, and `[` and `]` are a range's anchor and
head, so `a[bc]` selects `bc` forward and `a]bc[` backward. The `n`-th `[`
pairs with the `n`-th `]`. A `*` right after a marker makes that range
primary; otherwise the last range is.
*/
module sparkles.ui.editor.testing;

version (unittest):

import core.time : MonoTime, msecs;

import sparkles.base.pool.text_pool : TextPool;
import sparkles.input.events : InputTextTag, TextId;
import sparkles.ui.editor.command : EditCommand, EditKind;
import sparkles.ui.editor.context : LogicalContext;
import sparkles.ui.editor.effect : EditEffects;
import sparkles.ui.editor.kill_ring : KillRing;
import sparkles.ui.editor.selection : EditRange, SelectionSet;
import sparkles.ui.editor.state : EditorOptions, EditorState;
import sparkles.ui.editor.step : stepInPlace;
import sparkles.text_buffer.text : Text;

/// The host's input text pool, as a test needs it.
alias TestPool = TextPool!(InputTextTag, 16, 4096);

/// A state from marked text.
EditorState parse(string marked, EditorOptions options = EditorOptions.init) @safe pure nothrow
{
    char[] plain;
    size_t[] carets, anchors, heads;
    size_t primaryMarker = size_t.max; // index into the order of markers
    size_t markerCount;
    size_t[] markerRange;
    for (size_t i; i < marked.length; ++i)
    {
        const ch = marked[i];
        if (ch == '|' || ch == '[' || ch == ']')
        {
            if (ch == '|')
                carets ~= plain.length;
            else if (ch == '[')
                anchors ~= plain.length;
            else
                heads ~= plain.length;
            if (i + 1 < marked.length && marked[i + 1] == '*')
            {
                primaryMarker = ch == '|' ? carets.length - 1 + 1000 : (ch == '[' ? anchors.length - 1 : heads.length - 1);
                ++i;
            }
            continue;
        }
        plain ~= ch;
    }
    assert(anchors.length == heads.length, "unpaired [ ]");
    EditRange[] ranges;
    size_t primary = size_t.max;
    foreach (k, a; anchors)
    {
        if (primaryMarker == k)
            primary = ranges.length;
        ranges ~= EditRange(a, heads[k]);
    }
    foreach (k, c; carets)
    {
        if (primaryMarker == k + 1000)
            primary = ranges.length;
        ranges ~= EditRange.caret(c);
    }
    auto state = EditorState.create(Text(plain), options);
    if (ranges.length)
    {
        // The primary is the marked one, else the last in text order.
        size_t last;
        foreach (i, r; ranges)
            if (r.start >= ranges[last].start)
                last = i;
        state.selection = SelectionSet.of(ranges, primary == size_t.max ? last : primary);
        state.history = typeof(state.history)(state.selection, state.text.length);
    }
    return state;
}

/// Marked text of a state; the primary is not marked.
string show(in EditorState state) @safe pure nothrow
{
    auto bytes = new char[state.text.length];
    state.text.copyTo(0, bytes.length, bytes);
    string result;
    foreach (p; 0 .. bytes.length + 1)
    {
        foreach (r; state.selection.ranges)
        {
            if (r.empty && r.head == p)
                result ~= '|';
            else if (!r.empty && r.anchor == p && !r.forward)
                result ~= '[';
        }
        foreach (r; state.selection.ranges)
            if (!r.empty && r.head == p)
                result ~= ']';
        foreach (r; state.selection.ranges)
            if (!r.empty && r.anchor == p && r.forward)
                result ~= '[';
        if (p < bytes.length)
            result ~= bytes[p];
    }
    return result;
}

/// A state, a kill ring, a text pool and a clock, stepped together.
struct Harness
{
    EditorState state;
    KillRing ring;
    TestPool* pool;
    LogicalContext context;
    EditEffects effects;

    this(string marked, EditorOptions options = EditorOptions.init) @safe pure nothrow
    {
        state = parse(marked, options);
        pool = new TestPool;
    }

    /// Run `command`; the clock then advances by `gap` milliseconds.
    ref Harness run(EditCommand command, long gap = 1000) return @safe pure nothrow
    {
        effects = stepInPlace(state, ring, *pool, command, context);
        context.now += gap.msecs;
        if (command.text.valid)
            cast(void) pool.release(command.text); // the step copied what it needed
        return this;
    }

    /// The id of `text` in the pool.
    TextId intern(string text) @safe pure nothrow
    {
        auto id = pool.intern(text);
        assert(id.hasValue);
        return id.value;
    }

    /// Type `text` as one insertion, with `gap` milliseconds after it.
    ref Harness type(string text, long gap = 1000) return @safe pure nothrow
        => run(EditCommand.insert(intern(text)), gap);

    /// Paste `text` straight in, as a terminal's bracketed paste arrives.
    ref Harness pasted(string text) return @safe pure nothrow
        => run(EditCommand.insert(intern(text), true));

    ref Harness opCall(EditKind kind) return @safe pure nothrow => run(EditCommand.of(kind));

    string shown() const @safe pure nothrow => show(state);
}
