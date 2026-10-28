/**
Selection ranges and the normalized selection set (`EDT4`).

A range has an `anchor` that stays and a `head` that moves; the head is
where the caret is drawn, and a range whose anchor equals its head is a
caret. A selection set holds at least one range, sorted, never overlapping,
with exactly one primary.

Specification: `docs/specs/ui/editor.md` §1–2.
*/
module sparkles.ui.editor.selection;

import sparkles.base.buffer : SharedBuffer;
import sparkles.text_buffer.summary : Affinity;

/// One selection range.
struct EditRange
{
    size_t anchor;
    size_t head;
    /// The side of an ambiguous boundary the head belongs to.
    Affinity affinity;
    /// Goal column for vertical motion, in the layout's unit, or `noGoal`.
    size_t goal = noGoal;

    /// No goal column is set.
    enum size_t noGoal = size_t.max;

@safe pure nothrow @nogc:

    /// A caret at `at`.
    static EditRange caret(size_t at) => EditRange(at, at);

    size_t start() const scope => anchor < head ? anchor : head;
    size_t end() const scope => anchor < head ? head : anchor;
    bool empty() const scope => anchor == head;
    /// Whether the head is at or after the anchor.
    bool forward() const scope => anchor <= head;

    /// The range spanning `[start, end)` in this range's direction.
    EditRange spanning(size_t start, size_t end) const scope
        => forward ? EditRange(start, end, affinity) : EditRange(end, start, affinity);
}

/// A range and whether it is the primary one, while building a set.
private struct Marked
{
    EditRange range;
    bool primary;
}

/**
The editor's ranges: at least one, sorted by start, none overlapping, one
primary. Copying is O(1) until one copy changes (`SharedBuffer`).
*/
struct SelectionSet
{
    private SharedBuffer!(EditRange, 2) ranges_;
    private size_t primary_;

@safe pure nothrow @nogc:

    /// A single caret at `at`.
    static SelectionSet caret(size_t at)
    {
        SelectionSet set;
        set.ranges_.put(EditRange.caret(at));
        return set;
    }

    /// A single range.
    static SelectionSet single(EditRange range)
    {
        SelectionSet set;
        set.ranges_.put(range);
        return set;
    }

    /**
    The normalized set of `ranges`, `primary` naming the primary one among
    them. Ranges are sorted by start, stably; two merge into one spanning both
    when they share any position other than the single common endpoint of
    two non-empty ranges. A merged range keeps the later range's direction
    and is primary if either was. An empty `ranges` gives a caret at 0.
    */
    static SelectionSet of(scope const(EditRange)[] ranges, size_t primary)
    in (ranges.length == 0 || primary < ranges.length)
    {
        if (ranges.length == 0)
            return caret(0);
        SharedBuffer!(Marked, 4) marked;
        foreach (i, r; ranges)
            marked.put(Marked(r, i == primary));
        auto all = marked[];
        // Insertion sort: stable, and selections are short.
        foreach (i; 1 .. all.length)
        {
            const item = all[i];
            size_t j = i;
            while (j > 0 && all[j - 1].range.start > item.range.start)
            {
                all[j] = all[j - 1];
                --j;
            }
            all[j] = item;
        }
        SelectionSet set;
        Marked current = all[0];
        foreach (next; all[1 .. $])
        {
            const a = current.range;
            const b = next.range;
            const touching = b.start < a.end
                || (b.start == a.end && (a.empty || b.empty));
            if (touching)
            {
                const start = a.start;
                const end = a.end > b.end ? a.end : b.end;
                current = Marked(b.spanning(start, end), current.primary || next.primary);
                continue;
            }
            set.push(current);
            current = next;
        }
        set.push(current);
        return set;
    }

    private void push(Marked m)
    {
        if (m.primary)
            primary_ = ranges_.length;
        ranges_.put(m.range);
    }

    /// The ranges, sorted.
    const(EditRange)[] ranges() const return scope
        => ranges_.length ? ranges_[] : defaultRanges[];

    /// Number of ranges, at least 1.
    size_t length() const scope => ranges_.length ? ranges_.length : 1;

    /// Index of the primary range.
    size_t primaryIndex() const scope => primary_;

    /// The primary range.
    EditRange primary() const scope => ranges[primary_];

    bool opEquals(in SelectionSet other) const scope
        => primary_ == other.primary_ && ranges == other.ranges;
}

private static immutable EditRange[1] defaultRanges = [EditRange.caret(0)];

///
@("editor.selection.normalize")
@safe pure nothrow @nogc
unittest
{
    // Unsorted input is sorted; the primary follows its range.
    const EditRange[3] input = [EditRange(9, 12), EditRange.caret(2), EditRange(5, 6)];
    const s = SelectionSet.of(input[], 0);
    assert(s.length == 3 && s.ranges[0] == EditRange.caret(2) && s.primaryIndex == 2);

    // Overlap merges, keeping the later range's direction.
    const EditRange[2] overlap = [EditRange(1, 5), EditRange(8, 3)];
    const m = SelectionSet.of(overlap[], 1);
    assert(m.length == 1 && m.ranges[0] == EditRange(8, 1) && m.primaryIndex == 0);

    // Two non-empty ranges sharing one endpoint stay apart; a caret there merges.
    const EditRange[2] adjacent = [EditRange(1, 3), EditRange(3, 6)];
    assert(SelectionSet.of(adjacent[], 0).length == 2);
    const EditRange[2] caretAtEdge = [EditRange(1, 3), EditRange.caret(3)];
    assert(SelectionSet.of(caretAtEdge[], 1).length == 1);
    const EditRange[2] equalCarets = [EditRange.caret(4), EditRange.caret(4)];
    assert(SelectionSet.of(equalCarets[], 1).length == 1);

    const EditRange[1] origin = [EditRange.caret(0)];
    assert(SelectionSet.init.ranges == origin[]);
}
