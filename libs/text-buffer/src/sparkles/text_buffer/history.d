/**
A branching undo history: a tree of revisions over change sets.

The root is the text the history was created with. Every other revision
records the change set from its parent, that change set's inverse, the
caller's state before and after the edit (an editor stores its selection),
and a timestamp. Undoing and then editing starts a branch rather than
discarding the undone work; `earlier` and `later` travel in creation order
across branches.

Specification: `docs/specs/text-buffer/SPEC.md` §5 (TXB-HIS1–6).
*/
module sparkles.text_buffer.history;

import core.time : Duration, MonoTime;

import sparkles.text_buffer.change_set : ChangeSet;
import sparkles.text_buffer.node : Scratch;
import sparkles.text_buffer.storage : CowVector;

/// What a history operation did.
enum HistoryStatus : ubyte
{
    ok,
    /// `undo` at the root: nothing changed.
    nothingToUndo,
    /// `redo` with no child: nothing changed.
    nothingToRedo,
    /// `amend` at the root, or of a revision with children: nothing changed.
    notAmendable,
}

/// The change set that turns the old current text into the new one, and the
/// state to restore with it.
struct HistoryStep(S)
{
    HistoryStatus status;
    ChangeSet changes;
    S state;

    bool ok() const scope => status == HistoryStatus.ok;
}

private enum size_t none = size_t.max;

private struct Revision(S)
{
    size_t parent = none;
    size_t redoChild = none;
    size_t children;
    ChangeSet changes;
    ChangeSet inverse;
    S before;
    S after;
    MonoTime time;
    /// Distance from the root, kept so travel finds a common ancestor
    /// without walking to the root.
    size_t depth;
}

/**
A tree of revisions with one current revision. `S` is the caller's state,
restored on travel; it must be copyable in `@safe` code.

A history is a Regular value: copying one is O(1), and copies share their
revisions until one of them changes. It never reads a clock: timestamps are
inputs, and one earlier than the newest recorded counts as equal to it.
*/
struct History(S)
{
    static assert(__traits(compiles, () @safe { S a = S.init; S b = a; }),
        "History needs a state type that copies in @safe code");

    private CowVector!(Revision!S) revisions;
    private size_t current;
    private MonoTime newest;

    /// A history whose root is a text of `length` bytes in state `initial`.
    this(S initial, size_t length, MonoTime time = MonoTime.init)
    {
        Revision!S root;
        root.changes = ChangeSet.identity(length);
        root.inverse = ChangeSet.identity(length);
        root.before = initial;
        root.after = initial;
        root.time = time;
        newest = time;
        revisions.put(root);
    }

    /// Number of revisions, the root included.
    size_t length() const scope => revisions.length ? revisions.length : 1;

    /// The current revision's index in creation order; the root is 0.
    size_t currentIndex() const scope => current;

    /// Whether `undo` would move.
    bool canUndo() const scope => current != 0;

    /// Whether `redo` would move.
    bool canRedo() const scope => revisions.length && revisions[][current].redoChild != none;

    /// The state recorded after the current revision.
    S state() const scope => revisions.length ? revisions[][current].after : S.init;

    /// TXB-HIS1: add `changes` as a new child of the current revision, which
    /// becomes the redo child of its parent. Other children are kept.
    void commit(in ChangeSet changes, in ChangeSet inverse, S before, S after, MonoTime time)
    in (changes.sourceLength == textLength(current), "the change set does not start at this revision")
    {
        ensureRoot();
        Revision!S revision;
        revision.parent = current;
        revision.depth = revisions.length ? revisions[][current].depth + 1 : 1;
        revision.changes = ChangeSet(changes);
        revision.inverse = ChangeSet(inverse);
        revision.before = before;
        revision.after = after;
        revision.time = clamp(time);
        const index = revisions.length;
        revisions.put(revision);
        auto all = revisions.mutable;
        all[current].redoChild = index;
        ++all[current].children;
        current = index;
    }

    /// TXB-HIS2: step to the parent, returning the inverse and the state from
    /// before the undone edit.
    HistoryStep!S undo()
    {
        if (current == 0)
            return HistoryStep!S(HistoryStatus.nothingToUndo);
        const all = revisions[];
        const index = current;
        const parent = all[index].parent;
        // Commit and downward travel keep a parent's redo child on the
        // revision below it that is or leads to the current one.
        assert(all[parent].redoChild == index, "redo child left the current path");
        current = parent;
        ChangeSet inverse = all[index].inverse;
        S state = all[index].before;
        return HistoryStep!S(HistoryStatus.ok, inverse, state);
    }

    /// TXB-HIS2: step to the redo child.
    HistoryStep!S redo()
    {
        if (!canRedo)
            return HistoryStep!S(HistoryStatus.nothingToRedo);
        const child = revisions[][current].redoChild;
        current = child;
        ChangeSet changes = revisions[][child].changes;
        S state = revisions[][child].after;
        return HistoryStep!S(HistoryStatus.ok, changes, state);
    }

    /// TXB-HIS3: fold an edit into the current revision, which must be a
    /// childless non-root. Its `before` state is kept.
    HistoryStatus amend(in ChangeSet changes, in ChangeSet inverse, S after, MonoTime time)
    {
        if (current == 0 || revisions[][current].children != 0)
            return HistoryStatus.notAmendable;
        auto all = revisions.mutable;
        auto revision = &all[current];
        assert(changes.sourceLength == revision.changes.resultLength);
        revision.changes = revision.changes.compose(changes);
        revision.inverse = inverse.compose(revision.inverse);
        revision.after = after;
        revision.time = clamp(time);
        return HistoryStatus.ok;
    }

    /// TXB-HIS4: move `steps` revisions back in creation order, clamped.
    HistoryStep!S earlier(size_t steps) => travel(steps < current ? current - steps : 0);

    /// TXB-HIS4: move `steps` revisions forward in creation order, clamped.
    HistoryStep!S later(size_t steps)
    {
        const last = length - 1;
        return travel(steps < last - current ? current + steps : last);
    }

    /// TXB-HIS4: move to the revision with the smallest timestamp that is at
    /// least `span` before the current one's; among equal timestamps, the
    /// first created. Amending restamps a revision, so this is chosen by
    /// time, not by position in creation order.
    HistoryStep!S earlier(Duration span)
    {
        const limit = timeOf(current) - span;
        size_t best = current;
        foreach (i; 0 .. length)
            if (timeOf(i) >= limit
                && (timeOf(i) < timeOf(best) || (timeOf(i) == timeOf(best) && i < best)))
                best = i;
        return travel(best);
    }

    /// TXB-HIS4: move to the revision with the largest timestamp that is at
    /// most `span` after the current one's; among equal timestamps, the last
    /// created.
    HistoryStep!S later(Duration span)
    {
        const limit = timeOf(current) + span;
        size_t best = current;
        foreach (i; 0 .. length)
            if (timeOf(i) <= limit
                && (timeOf(i) > timeOf(best) || (timeOf(i) == timeOf(best) && i > best)))
                best = i;
        return travel(best);
    }

    /**
    TXB-HIS5: shrink to at most `maxRevisions` (at least 1). Repeatedly
    removes the oldest revision that has no children and is not current;
    then, while still over the bound, makes the root's child on the path to
    the current revision the new root. Returns how many were removed.
    O(n log n) for n revisions.
    */
    size_t prune(size_t maxRevisions)
    {
        if (maxRevisions == 0)
            maxRevisions = 1;
        if (revisions.length <= maxRevisions)
            return 0;
        auto all = revisions.mutable;
        const n = all.length;
        auto flagStorage = Scratch!bool(2 * n);
        auto removed = flagStorage.slice[0 .. n];
        auto lostRedo = flagStorage.slice[n .. $];
        removed[] = false;
        lostRedo[] = false;
        size_t count = n;

        // Oldest childless revision first. Removing one can leave its parent
        // childless, and the parent is older, so it joins the heap.
        auto heapStorage = Scratch!size_t(n);
        auto heap = MinHeap(heapStorage.slice);
        foreach (i; 1 .. n)
            if (i != current && all[i].children == 0)
                heap.push(i);
        while (count > maxRevisions && !heap.empty)
        {
            const victim = heap.pop();
            removed[victim] = true;
            --count;
            const parent = all[victim].parent;
            if (--all[parent].children == 0 && parent != 0 && parent != current)
                heap.push(parent);
            if (all[parent].redoChild == victim)
                lostRedo[parent] = true;
        }
        // A parent whose redo child went redoes into its newest remaining one.
        foreach (i; 0 .. n)
            if (!removed[i] && all[i].parent != none && lostRedo[all[i].parent])
                all[all[i].parent].redoChild = i;
        foreach (i; 0 .. n)
            if (lostRedo[i] && all[i].children == 0)
                all[i].redoChild = none;

        // Only the path from the root to the current revision is left: drop
        // its oldest revisions, making the next one the root.
        if (count > maxRevisions)
        {
            assert(count == all[current].depth + 1, "only the current path should remain");
            auto pathStorage = Scratch!size_t(count);
            auto path = pathStorage.slice;
            size_t at = count;
            for (size_t i = current; i != none; i = all[i].parent)
                path[--at] = i;
            size_t first;
            while (count > maxRevisions)
            {
                removed[path[first++]] = true;
                --count;
            }
            auto root = &all[path[first]];
            const length = root.changes.resultLength;
            root.changes = ChangeSet.identity(length);
            root.inverse = ChangeSet.identity(length);
            root.before = root.after;
            root.parent = none;
        }

        auto mapStorage = Scratch!size_t(n);
        auto map = mapStorage.slice;
        CowVector!(Revision!S) kept;
        foreach (i; 0 .. n)
            if (!removed[i])
            {
                map[i] = kept.length;
                kept.put(all[i]);
            }
        // Parents precede their children, so depths follow in one pass.
        auto remapped = kept.mutable;
        foreach (ref revision; remapped)
        {
            if (revision.parent != none)
            {
                revision.parent = map[revision.parent];
                revision.depth = remapped[revision.parent].depth + 1;
            }
            else
                revision.depth = 0;
            if (revision.redoChild != none)
                revision.redoChild = map[revision.redoChild];
        }
        current = map[current];
        revisions = kept;
        return n - count;
    }

private:

    void ensureRoot()
    {
        if (revisions.length == 0)
        {
            Revision!S root;
            root.changes = ChangeSet.identity(0);
            root.inverse = ChangeSet.identity(0);
            revisions.put(root);
        }
    }

    MonoTime clamp(MonoTime time)
    {
        if (time < newest)
            time = newest;
        newest = time;
        return time;
    }

    MonoTime timeOf(size_t i) const scope => revisions.length ? revisions[][i].time : MonoTime.init;

    size_t textLength(size_t i) const scope
        => revisions.length ? revisions[][i].changes.resultLength : 0;

    size_t depthOf(size_t i) const scope => revisions[][i].depth;

    /// Move to `target`, composing up to the common ancestor and back down.
    HistoryStep!S travel(size_t target)
    {
        ensureRoot();
        auto changes = ChangeSet.identity(textLength(current));
        // Climb from both ends to their lowest common ancestor.
        size_t up = current;
        size_t down = target;
        size_t upDepth = depthOf(up);
        size_t downDepth = depthOf(down);
        auto pathStorage = Scratch!size_t(downDepth + upDepth);
        auto path = pathStorage.slice;
        size_t pathLength;
        while (upDepth > downDepth)
        {
            changes = changes.compose(revisions[][up].inverse);
            up = revisions[][up].parent;
            --upDepth;
        }
        while (downDepth > upDepth)
        {
            path[pathLength++] = down;
            down = revisions[][down].parent;
            --downDepth;
        }
        while (up != down)
        {
            changes = changes.compose(revisions[][up].inverse);
            up = revisions[][up].parent;
            path[pathLength++] = down;
            down = revisions[][down].parent;
        }
        auto all = revisions.mutable;
        foreach_reverse (i; 0 .. pathLength)
        {
            changes = changes.compose(all[path[i]].changes);
            all[all[path[i]].parent].redoChild = path[i];
        }
        current = target;
        return HistoryStep!S(HistoryStatus.ok, changes, all[target].after);
    }
}

/// A binary min-heap of revision indices in caller storage.
private struct MinHeap
{
    size_t[] items;
    size_t length;

    bool empty() const scope @safe pure nothrow @nogc => length == 0;

    void push(size_t value) scope @safe pure nothrow @nogc
    {
        size_t i = length++;
        items[i] = value;
        while (i && items[(i - 1) / 2] > items[i])
        {
            swap(i, (i - 1) / 2);
            i = (i - 1) / 2;
        }
    }

    size_t pop() scope @safe pure nothrow @nogc
    {
        const top = items[0];
        items[0] = items[--length];
        size_t i;
        while (true)
        {
            const left = 2 * i + 1;
            const right = left + 1;
            size_t smallest = i;
            if (left < length && items[left] < items[smallest])
                smallest = left;
            if (right < length && items[right] < items[smallest])
                smallest = right;
            if (smallest == i)
                return top;
            swap(i, smallest);
            i = smallest;
        }
    }

    private void swap(size_t a, size_t b) scope @safe pure nothrow @nogc
    {
        const t = items[a];
        items[a] = items[b];
        items[b] = t;
    }
}
