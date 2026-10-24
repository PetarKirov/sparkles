/**
Generated tests for `History` against an explicit list of versions (testing.md,
"History is checked against an explicit list of versions"). Every committed
text is kept; navigation must land on the entry its rule names, and the change
set it returns must turn the old current text into that entry.
*/
module sparkles.text_buffer.history_test;

version (unittest):

import core.time : Duration, MonoTime, msecs;

import sparkles.text_buffer.change_set : ChangeSet, ChangeSetStatus, Edit;
import sparkles.text_buffer.change_set_test : bytesOf;
import sparkles.text_buffer.history : History, HistoryStatus;
import sparkles.text_buffer.node : liveNodes;
import sparkles.text_buffer.text : Text;
import sparkles.text_buffer.text_test : Xorshift, randomBytes;

/// One version in the model; `id` is also the state the history records.
struct Version
{
    size_t parent;
    char[] text;
    long time;
    size_t redo = size_t.max;
    size_t children;
}

MonoTime at(long milliseconds) @safe pure nothrow @nogc => MonoTime.zero + milliseconds.msecs;

/// A random edit of `text` and its inverse.
void randomChange(ref Xorshift random, in Text text, ref ChangeSet changes, ref ChangeSet inverse)
    @safe pure nothrow
{
    const from = random.next(text.length + 1);
    const to = from + random.next(text.length - from + 1 < 6 ? text.length - from + 1 : 6);
    const Edit[1] edit = [Edit(from, to, randomBytes(random, random.next(3)))];
    assert(ChangeSet.of(text.length, edit[], changes) == ChangeSetStatus.ok);
    inverse = changes.invert(text);
}

@("History.model.randomNavigation")
@safe pure nothrow
unittest
{
    foreach (seed; [1UL, 2, 3, 4])
    {
        auto random = Xorshift(0x5DEECE66D * seed);
        Version[] model = [Version(size_t.max, "seed text".dup, 0)];
        size_t current;
        long newest;
        auto text = Text("seed text");
        auto history = History!size_t(0, text.length, at(0));
        foreach (step; 0 .. 300)
        {
            const op = random.next(9);
            // Timestamps sometimes step back: they must be clamped (TXB-HIS6).
            const long stamp = newest + cast(long) random.next(40) - 10;
            void land(size_t target, in ChangeSet changes, size_t state)
            {
                text = changes.apply(text);
                current = target;
                assert(text == model[current].text, "travel landed on the wrong text");
                assert(state == current, "travel restored the wrong state");
            }
            if (op <= 2) // commit
            {
                ChangeSet changes, inverse;
                randomChange(random, text, changes, inverse);
                const id = model.length;
                const clamped = stamp < newest ? newest : stamp;
                newest = clamped;
                model ~= Version(current, bytesOf(changes.apply(text)), clamped);
                model[current].redo = id;
                ++model[current].children;
                history.commit(changes, inverse, current, id, at(stamp));
                text = changes.apply(text);
                current = id;
            }
            else if (op == 3) // undo
            {
                const step_ = history.undo();
                if (current == 0)
                {
                    assert(step_.status == HistoryStatus.nothingToUndo);
                    continue;
                }
                const parent = model[current].parent;
                model[parent].redo = current;
                land(parent, step_.changes, step_.state);
            }
            else if (op == 4) // redo
            {
                const step_ = history.redo();
                if (model[current].redo == size_t.max)
                {
                    assert(step_.status == HistoryStatus.nothingToRedo);
                    continue;
                }
                land(model[current].redo, step_.changes, step_.state);
            }
            else if (op == 5) // amend
            {
                ChangeSet changes, inverse;
                randomChange(random, text, changes, inverse);
                const result = history.amend(changes, inverse, current, at(stamp));
                if (current == 0 || model[current].children)
                {
                    assert(result == HistoryStatus.notAmendable);
                    continue;
                }
                assert(result == HistoryStatus.ok);
                text = changes.apply(text);
                model[current].text = bytesOf(text);
                const clamped = stamp < newest ? newest : stamp;
                newest = clamped;
                model[current].time = clamped;
            }
            else if (op == 6) // earlier/later by steps
            {
                const steps = random.next(5);
                const back = random.next(2) == 0;
                const target = back ? (steps < current ? current - steps : 0)
                    : (current + steps < model.length ? current + steps : model.length - 1);
                const travel = back ? history.earlier(steps) : history.later(steps);
                setRedoAlongPath(model, current, target);
                land(target, travel.changes, travel.state);
            }
            else // earlier/later by time
            {
                const span = random.next(60);
                const back = op == 7;
                // Smallest stamp at least `span` back, first created on a
                // tie; or largest stamp at most `span` ahead, last created.
                size_t target = current;
                foreach (i; 0 .. model.length)
                {
                    const t = model[i].time;
                    const best = model[target].time;
                    if (back ? t >= model[current].time - cast(long) span
                            && (t < best || (t == best && i < target))
                        : t <= model[current].time + cast(long) span
                            && (t > best || (t == best && i > target)))
                        target = i;
                }
                const travel = back ? history.earlier(span.msecs) : history.later(span.msecs);
                setRedoAlongPath(model, current, target);
                land(target, travel.changes, travel.state);
            }
            assert(history.currentIndex == current && history.length == model.length);
        }
    }
}

/// Travel down to `target` makes each ancestor's redo child the path's next step.
void setRedoAlongPath(Version[] model, size_t from, size_t target) @safe pure nothrow
{
    bool[] ancestorOfFrom = new bool[model.length];
    for (size_t i = from; i != size_t.max; i = model[i].parent)
        ancestorOfFrom[i] = true;
    for (size_t i = target; i != size_t.max && !ancestorOfFrom[i]; i = model[i].parent)
        model[model[i].parent].redo = i;
}

/// Undo then edit starts a branch; the undone revision stays reachable.
@("History.commit.keepsBranches")
@safe pure nothrow
unittest
{
    auto text = Text("abc");
    auto history = History!int(0, text.length);
    ChangeSet first, firstInverse, second, secondInverse;
    const Edit[1] e1 = [Edit(3, 3, "d")];
    assert(ChangeSet.of(3, e1[], first) == ChangeSetStatus.ok);
    firstInverse = first.invert(text);
    history.commit(first, firstInverse, 0, 1, at(1));
    text = first.apply(text);
    const undone = history.undo();
    text = undone.changes.apply(text);
    assert(text == "abc" && undone.state == 0);
    const Edit[1] e2 = [Edit(0, 0, "x")];
    assert(ChangeSet.of(3, e2[], second) == ChangeSetStatus.ok);
    secondInverse = second.invert(text);
    history.commit(second, secondInverse, 0, 2, at(2));
    text = second.apply(text);
    assert(text == "xabc" && history.length == 3);
    // The first branch is still there, one step back in creation order.
    const back = history.earlier(1);
    text = back.changes.apply(text);
    assert(text == "abcd" && back.state == 1);
}

/// Pruning removes the oldest childless revisions, then reroots
/// (TXB-HIS5), and every remaining revision keeps its text.
@("History.prune.oldestLeavesThenReroot")
@safe pure nothrow
unittest
{
    auto random = Xorshift(99);
    auto text = Text("prune me");
    auto history = History!size_t(0, text.length);
    char[][] texts = ["prune me".dup];
    // A trunk of 6 commits with a side branch of 2 off revision 2.
    void commitOne(size_t id)
    {
        ChangeSet changes, inverse;
        randomChange(random, text, changes, inverse);
        history.commit(changes, inverse, history.currentIndex, id, at(cast(long) id));
        text = changes.apply(text);
        texts ~= bytesOf(text);
    }
    foreach (id; 1 .. 4)
        commitOne(id); // 1, 2, 3 on the trunk
    foreach (_; 0 .. 2)
        text = history.undo().changes.apply(text); // back to 1
    foreach (id; 4 .. 6)
        commitOne(id); // 4, 5 branch from 1
    text = history.earlier(2).changes.apply(text); // to 3, the trunk tip
    assert(history.state == 3);
    commitOne(6);
    commitOne(7); // 6, 7 continue the trunk; current is 7

    // Childless and not current, oldest first: 5, then 4 (now childless).
    assert(history.prune(6) == 2);
    assert(history.length == 6);
    // Then reroot along the path 0 → 1 → 2 → 3 → 6 → 7.
    assert(history.prune(3) == 3);
    assert(history.length == 3 && history.state == 7);
    // Every remaining revision is 3, 6 or 7, with its own text.
    foreach (expected; [3, 6, 7])
    {
        const travel = history.earlier(history.currentIndex);
        text = travel.changes.apply(text);
        // earlier(all) lands on the new root; walk forward to `expected`.
        foreach (_; 0 .. [3: 0, 6: 1, 7: 2][expected])
            text = history.later(1).changes.apply(text);
        assert(history.state == expected && text == texts[expected]);
    }
    assert(!history.canUndo || history.currentIndex != 0);
    history.earlier(10);
    assert(history.undo().status == HistoryStatus.nothingToUndo, "the new root has no parent");
}

/// Dropping a history releases every node it held (TXB-OWN1).
@("History.release.everyNodeFreed")
@safe pure nothrow @nogc
unittest
{
    size_t baseline;
    debug baseline = liveNodes;
    {
        auto text = Text("some text to edit a few times");
        auto history = History!int(0, text.length);
        foreach (int i; 0 .. 20)
        {
            ChangeSet changes;
            const Edit[1] edit = [Edit(i % text.length, i % text.length, "+")];
            assert(ChangeSet.of(text.length, edit[], changes) == ChangeSetStatus.ok);
            history.commit(changes, changes.invert(text), i, i + 1, MonoTime.zero);
            text = changes.apply(text);
            if (i % 5 == 4)
                text = history.undo().changes.apply(text);
        }
        auto copy = history; // shares revisions until one changes
        copy.undo();
        history.prune(4);
    }
    size_t live;
    debug live = liveNodes;
    assert(live == baseline, "a node outlived its history");
}

/// The operations compile with the full attribute set (TXB-OWN5).
@("History.attributes")
@safe pure nothrow @nogc
unittest
{
    auto text = Text("ab");
    auto history = History!int(7, text.length);
    ChangeSet changes;
    const Edit[1] edit = [Edit(1, 1, "X")];
    assert(ChangeSet.of(2, edit[], changes) == ChangeSetStatus.ok);
    history.commit(changes, changes.invert(text), 7, 8, MonoTime.zero);
    assert(history.amend(ChangeSet.identity(3), ChangeSet.identity(3), 9, MonoTime.zero)
        == HistoryStatus.ok);
    assert(history.undo().state == 7 && history.redo().state == 9);
    assert(history.earlier(1).ok && history.later(1.msecs).ok);
}

/// After an amend restamps an older revision, travelling by time still moves
/// in time: `later` never lands on an older stamp, `earlier` on a newer one.
@("History.travelByTime.afterAmend")
@safe pure nothrow
unittest
{
    auto random = Xorshift(5);
    auto text = Text("abc");
    auto history = History!size_t(0, text.length, at(0));
    ChangeSet changes, inverse;
    randomChange(random, text, changes, inverse);
    history.commit(changes, inverse, 0, 1, at(1)); // r1 at t=1
    text = changes.apply(text);
    text = history.undo().changes.apply(text);
    randomChange(random, text, changes, inverse);
    history.commit(changes, inverse, 0, 2, at(2)); // r2 at t=2
    text = changes.apply(text);
    text = history.earlier(1).changes.apply(text); // to r1
    assert(history.state == 1);
    randomChange(random, text, changes, inverse);
    assert(history.amend(changes, inverse, 11, at(10)) == HistoryStatus.ok); // r1 now t=10
    text = changes.apply(text);

    text = history.later(Duration.zero).changes.apply(text);
    assert(history.state == 11, "later(0) from the newest stamp stays put");
    text = history.later(1).changes.apply(text); // to r2 (t=2)
    assert(history.state == 2);
    text = history.earlier(Duration.zero).changes.apply(text);
    assert(history.state == 2, "earlier(0) never moves to a newer stamp");
    text = history.earlier(2.msecs).changes.apply(text);
    assert(history.state == 0, "the root at t=0 is the smallest stamp within 2 ms");
}

/// Committing to a history that a copy still shares keeps its storage
/// proportional to its revisions, however many times it happens.
@("History.copyOnWrite.boundedGrowth")
@safe pure nothrow @nogc
unittest
{
    auto text = Text("x");
    auto history = History!int(0, text.length);
    foreach (int i; 0 .. 64)
    {
        const shared_ = history; // a copy that still shares the revisions
        ChangeSet changes;
        const Edit[1] edit = [Edit(0, 0, "+")];
        assert(ChangeSet.of(text.length, edit[], changes) == ChangeSetStatus.ok);
        history.commit(changes, changes.invert(text), i, i + 1, MonoTime.zero);
        text = changes.apply(text);
    }
    assert(history.length == 65);
}
