/** Shared owned picker prompt, ranked selection, and scrolling. */
module sparkles.ui.components.picker;

import sparkles.fuzzy : CandidateId, RankedResult, FuzzyError;
import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.components.scroll_view : ScrollView;
import sparkles.ui.editor.field : EditorField, FieldResult, FieldSetup, serveClipboard;

/**
The picker's prompt: the toolkit's editor (`EDU4`) in single-line mode,
capped at `Capacity` bytes, with a fixed copy of its text so the search
path reads the query without allocating (`PIK6`).
*/
struct PickerPrompt(size_t Capacity = 256)
if (Capacity > 0)
{
    /// The editor; refreshes `text` through `sync` after every edit.
    EditorField field;
    /// The prompt's key table and clipboard, applied each time it starts.
    FieldSetup setup;
    private char[Capacity] mirror = void;
    private size_t length_;
    bool active;

    const(char)[] text() const return scope @trusted pure nothrow @nogc
        => mirror[0 .. length_];
    size_t length() const @safe pure nothrow @nogc => length_;

    void start() @safe pure nothrow @nogc
    {
        field = setup.singleLine();
        field.state.options.maxLength = Capacity;
        length_ = 0;
        active = true;
    }

    /// One key for the prompt's editor; `handled` is `false` for a key it
    /// declines, `changed` when the query changed.
    FieldResult key(in KeyEvent event) @safe pure nothrow
        => synced(field.key(event));

    /// Text typed or pasted at once; `true` when the query changed.
    bool insert(scope const(char)[] text, bool paste = false) @safe pure nothrow
        => synced(field.insert(text, paste)).changed;


    /// Scalar input uses the same owned editor as keyboard and paste input.
    bool type(dchar value) @safe pure nothrow
    {
        import sparkles.base.text.utf : encodeScalar;
        if (value < 0x20 || value == 0x7F) return false;
        char[4] encoded = void;
        const count = encodeScalar(value, encoded[]).written;
        return count != 0 && insert(encoded[0 .. count]);
    }

    /// Backspace removes one editor grapheme, including its combining marks.
    bool erase() @safe pure nothrow => key(KeyEvent(Key.backspace)).changed;

    /// Do the clipboard work the prompt asked for (`EDY5`); `true` when a
    /// paste changed the query.
    bool serve(Clipboard)(in Clipboard clipboard)
        => synced(serveClipboard(field, clipboard)).changed;

    void accept() @safe pure nothrow @nogc
    {
        active = false;
    }

    void cancel() @safe pure nothrow @nogc
    {
        start();
        active = false;
    }

    private FieldResult synced(FieldResult result) @safe pure nothrow @nogc
    {
        if (result.changed)
        {
            length_ = field.state.text.length;
            field.state.text.copyTo(0, length_, mirror[0 .. length_]);
        }
        return result;
    }
}

/// Selected row's inspectable score terms for a backend debug panel.
struct PickerDebugScore
{
    bool present;
    RankedResult result;
}

/** Prompt, globally ranked rows, selection, and scroll — no canvas state. */
struct PickerState(size_t Capacity = 64, size_t PromptCapacity = 256)
if (Capacity > 0 && PromptCapacity > 0)
{
    PickerPrompt!PromptCapacity prompt;
    private RankedResult[Capacity] rows_ = void;
    private size_t rowCount_;
    size_t selection;
    ulong generation;
    /// Candidates admitted so far this generation (grows while `searching`).
    size_t matchedTotal;
    /// The corpus size the generation searched — the `332/2350` denominator.
    size_t corpusTotal;
    bool active;
    bool searching;
    bool showScoreDebug;
    FuzzyError error;

    /**
    How many rows the list paints at once.

    Separate from `Capacity`, which is how many ranked results are KEPT.
    They were the same number while every source was a file picker, where a
    handful of top hits answer the question. A grep query does not work that
    way — the interesting hit is routinely the twentieth — so the ranking is
    kept deeper than the viewport and the list scrolls through it, rather
    than the ranking being truncated to what happens to fit.
    */
    size_t viewRows = 16;
    private size_t firstRow_;

    /**
    The list's scroll machines (`PKL8`, `SCV1`).

    A `ScrollView`, not a bare offset: the first version of this carried a
    `size_t` and painted a decorative string, which made it the SEVENTH site
    to assemble a scrollbar by convention in a codebase that had just
    finished collapsing six into one component. The machine owns the parts
    that are easy to get wrong on the eighth try — press-on-thumb grabs in
    place while press-on-track jumps, the grab owns the pointer until
    release, hover is a state, and the offset clamps in exactly one place.

    Only the horizontal axis is driven today; the list's vertical movement
    is a SELECTION (`firstRow_` follows it), not a scroll offset.
    */
    ScrollView scroll;

    /// The list's horizontal offset, in cells — the machine's, surfaced
    /// under the name the view reads.
    size_t hOffset() const @safe pure nothrow @nogc
        => scroll.h.offset < 0 ? 0 : cast(size_t) scroll.h.offset;
    /// The widest painted row, in cells — the extent the bar describes.
    /// Published by the view, which is the only thing that knows how wide a
    /// row rendered.
    size_t contentCols;
    /// Cells the list can show at once, set by the host from the geometry.
    size_t viewCols = 40;

    /// Whether any painted row is wider than the panel.
    bool hOverflows() const @safe pure nothrow @nogc
        => contentCols > viewCols;

    /**
    Scroll the list vertically to put `first` at the top (`PKL8`).

    Used by the vertical bar, which is the one input that moves the VIEW
    without moving the cursor. The selection is then pulled into the visible
    window rather than left behind it: a picker whose highlighted row is off
    screen has lost the reader's place, and Enter would open something they
    cannot see.
    */
    bool scrollRowsTo(long first) @safe pure nothrow @nogc
    {
        if (rowCount_ == 0)
            return false;
        const win = viewRows == 0 ? 1 : viewRows;
        const maxFirst = rowCount_ > win ? rowCount_ - win : 0;
        auto next = first < 0 ? 0 : first;
        if (next > cast(long) maxFirst)
            next = cast(long) maxFirst;
        if (cast(size_t) next == firstRow_)
            return false;
        firstRow_ = cast(size_t) next;
        if (selection < firstRow_)
            selection = firstRow_;
        else if (selection >= firstRow_ + win)
            selection = firstRow_ + win - 1;
        return true;
    }

    /**
    A new query: the list starts at the top (`PIK10`).

    Editing the prompt makes a different ranking, and the row that was
    selected is not the row the reader is now asking about — the first hit
    is. Preserving the selection across an edit is right only while the
    QUERY is unchanged (a partial page growing under the cursor), which is
    why this is the prompt's business rather than `publish`'s.
    */
    void restartSelection() @safe pure nothrow @nogc
    {
        selection = 0;
        firstRow_ = 0;
        scroll.h = scroll.h.scrolledTo(0);
    }

    /**
    Scroll the list sideways, clamped to the widest row.

    Returns `false` when there is nothing to scroll, so a host can leave the
    key unhandled rather than repaint for nothing — the same contract
    `ViewerModel.scrollHorizontal` has.
    */
    bool scrollHorizontal(long delta) @safe pure nothrow @nogc
    {
        if (delta == 0 || !hOverflows)
            return false;
        const next = ScrollView.clampOffset(scroll.h.offset + delta,
            contentCols, viewCols);
        if (next == scroll.h.offset)
            return false;
        scroll.h = scroll.h.scrolledTo(next);
        return true;
    }

    /// The whole kept ranking, deeper than the viewport.
    const(RankedResult)[] rows() const return scope @trusted pure nothrow @nogc
        => rows_[0 .. rowCount_];
    size_t rowCount() const @safe pure nothrow @nogc => rowCount_;

    /// Index of the first painted row — the list's scroll offset.
    size_t firstRow() const @safe pure nothrow @nogc => firstRow_;

    /// The painted window: what the view iterates. Its indices are
    /// window-relative, so a caller adds `firstRow` to compare against
    /// `selection`.
    const(RankedResult)[] visible() const return scope @trusted pure nothrow @nogc
    {
        const win = viewRows == 0 ? 1 : viewRows;
        const stop = firstRow_ + win < rowCount_ ? firstRow_ + win : rowCount_;
        return firstRow_ < stop ? rows_[firstRow_ .. stop] : null;
    }

    /// Keep the selection inside the painted window, and the window inside
    /// the ranking. Called wherever either can move.
    private void clampScroll() @safe pure nothrow @nogc
    {
        if (rowCount_ == 0)
        {
            firstRow_ = 0;
            return;
        }
        const win = viewRows == 0 ? 1 : viewRows;
        if (selection < firstRow_)
            firstRow_ = selection;
        else if (selection >= firstRow_ + win)
            firstRow_ = selection - win + 1;
        const maxFirst = rowCount_ > win ? rowCount_ - win : 0;
        if (firstRow_ > maxFirst)
            firstRow_ = maxFirst;
    }

    void open() @safe pure nothrow @nogc
    {
        prompt.start();
        rowCount_ = 0;
        selection = 0;
        firstRow_ = 0;
        scroll = ScrollView.init;
        contentCols = 0;
        matchedTotal = 0;
        corpusTotal = 0;
        error = FuzzyError.init;
        active = true;
        searching = false;
    }

    void close() @safe pure nothrow @nogc
    {
        prompt.accept();
        active = false;
        searching = false;
    }

    void moveSelection(long delta) @safe pure nothrow @nogc
    {
        if (rowCount_ == 0)
        {
            selection = 0;
            return;
        }
        const wanted = cast(long) selection + delta;
        selection = wanted < 0 ? 0
            : wanted >= cast(long) rowCount_ ? rowCount_ - 1
            : cast(size_t) wanted;
        clampScroll();
    }

    void toggleScoreDebug() @safe pure nothrow @nogc
    {
        showScoreDebug = !showScoreDebug;
    }

    PickerDebugScore debugScore() const @safe pure nothrow @nogc
    {
        PickerDebugScore result;
        if (showScoreDebug && selection < rowCount_)
        {
            result.present = true;
            result.result = rows_[selection];
        }
        return result;
    }

    size_t selectedCorpusIndex() const @safe pure nothrow @nogc
        => selection < rowCount_ ? rows_[selection].corpusIndex : size_t.max;

public:
    void publish(scope const(RankedResult)[] values, ulong newGeneration,
        bool stillSearching) @safe pure nothrow @nogc
    {
        CandidateId selected;
        bool preserve = selection < rowCount_;
        if (preserve)
            selected = rows_[selection].id;
        rowCount_ = values.length < Capacity ? values.length : Capacity;
        foreach (i; 0 .. rowCount_)
            rows_[i] = values[i];
        // A new generation is a different set of rows, so a sideways offset
        // carried over from the last query would point into text that is no
        // longer there. Compared BEFORE the assignment, or the test is
        // trivially false and the offset never resets.
        if (generation != newGeneration)
            scroll.h = scroll.h.scrolledTo(0);
        generation = newGeneration;
        searching = stillSearching;
        error = FuzzyError.init;
        if (rowCount_ == 0)
            selection = 0;
        else if (preserve)
        {
            selection = 0;
            foreach (i; 0 .. rowCount_)
                if (rows_[i].id == selected)
                {
                    selection = i;
                    break;
                }
        }
        else if (selection >= rowCount_)
            selection = rowCount_ - 1;
        clampScroll();
    }
}

/// Prompt editing preserves UTF-8; publication preserves the selected identity.
@("ui.picker.promptAndSelection")
@safe pure nothrow unittest
{
    PickerPrompt!8 prompt;
    prompt.start();
    assert(prompt.type('a') && prompt.type('€'));
    assert(prompt.text == "a€" && prompt.erase() && prompt.text == "a");
    assert(!prompt.type('\n'));

    PickerState!4 state;
    state.open();
    RankedResult[2] rows;
    rows[0].id.low = 1;
    rows[0].corpusIndex = 8;
    rows[1].id.low = 2;
    rows[1].corpusIndex = 12;
    state.publish(rows, 1, false);
    state.moveSelection(1);
    assert(state.selectedCorpusIndex == 12);
    auto first = rows[0];
    rows[0] = rows[1];
    rows[1] = first;
    state.publish(rows, 2, false);
    assert(state.selection == 0 && state.selectedCorpusIndex == 12);
    state.close();
    assert(!state.active && !state.prompt.active);
}
