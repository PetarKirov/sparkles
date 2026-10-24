/**
Generated tests for `ChangeSet` (testing.md, "Change-set laws are checked
against the model"). Each law is evaluated by applying change sets to texts
and comparing with a byte array, never by comparing change sets with each
other.
*/
module sparkles.text_buffer.change_set_test;

version (unittest):

import sparkles.text_buffer.change_set : ChangeSet, ChangeSetStatus, Edit, TouchedRange;
import sparkles.text_buffer.summary : Affinity;
import sparkles.text_buffer.text : Text;
import sparkles.text_buffer.text_test : Xorshift, randomBytes;

/// Bytes of `text`, for comparing with a model.
char[] bytesOf(in Text text) @safe pure nothrow
{
    auto result = new char[text.length];
    text.copyTo(0, text.length, result);
    return result;
}

/// Disjoint edits in random order, and the model's result of applying them.
struct Generated
{
    Edit[] edits;
    char[] result;
    /// Per source position, the model's mapping under each affinity.
    size_t[] before;
    size_t[] after;
    bool[] deleted;
}

Generated generate(ref Xorshift random, const(char)[] source) @safe pure nothrow
{
    // Disjoint ranges left to right, at least one retained byte apart.
    struct Raw { size_t from, to; char[] inserted; size_t start; }
    Raw[] raw;
    size_t position;
    while (position <= source.length && raw.length < 6)
    {
        const from = position + random.next(source.length - position + 1);
        const room = source.length - from + 1;
        const to = from + random.next(room < 8 ? room : 8);
        raw ~= Raw(from, to, randomBytes(random, random.next(3)));
        position = to + 1 + random.next(4);
        if (random.next(3) == 0)
            break;
    }

    Generated g;
    size_t a;
    foreach (ref r; raw)
    {
        g.result ~= source[a .. r.from];
        r.start = g.result.length;
        g.result ~= r.inserted;
        a = r.to;
    }
    g.result ~= source[a .. $];

    // Mapping: inside or at an edge of an edit, its insertion's start or
    // end; elsewhere, shifted by the net change of the edits before.
    g.before = new size_t[source.length + 1];
    g.after = new size_t[source.length + 1];
    g.deleted = new bool[source.length + 1];
    foreach (p; 0 .. source.length + 1)
    {
        long shift;
        bool mapped;
        foreach (r; raw)
        {
            if (p >= r.from && p <= r.to)
            {
                g.before[p] = r.start;
                g.after[p] = r.start + r.inserted.length;
                g.deleted[p] = p > r.from && p < r.to;
                mapped = true;
                break;
            }
            if (r.to < p)
                shift += cast(long) r.inserted.length - cast(long)(r.to - r.from);
        }
        if (!mapped)
            g.before[p] = g.after[p] = cast(size_t)(p + shift);
    }

    foreach (i; 0 .. raw.length)
    {
        const j = random.next(raw.length);
        auto t = raw[i];
        raw[i] = raw[j];
        raw[j] = t;
    }
    foreach (r; raw)
        g.edits ~= Edit(r.from, r.to, r.inserted);
    return g;
}

/// Retained-run positions: `p` touched by no edit.
bool untouched(in ChangeSet c, size_t p) @safe pure nothrow @nogc
{
    foreach (r; c.touched)
        if (p >= r.fromA && p <= r.toA)
            return false;
    return true;
}

@("ChangeSet.model.applyInvertComposeMap")
@safe pure nothrow
unittest
{
    auto random = Xorshift(0xA5A5_5A5A_1234_5678);
    foreach (round; 0 .. 150)
    {
        const source = randomBytes(random, random.next(10));
        const text = Text(source);
        auto first = generate(random, source);
        ChangeSet a;
        assert(ChangeSet.of(source.length, first.edits, a) == ChangeSetStatus.ok);
        assert(a.sourceLength == source.length && a.resultLength == first.result.length);

        // TXB-CHG2: apply.
        const applied = a.apply(text);
        assert(applied == first.result);
        applied.checkInvariants();

        // TXB-CHG3: invert, against the same source.
        assert(a.invert(text).apply(applied) == source);

        // TXB-CHG5: mapping at every position, both affinities.
        foreach (p; 0 .. source.length + 1)
        {
            assert(a.mapPos(p, Affinity.before) == first.before[p]);
            assert(a.mapPos(p, Affinity.after) == first.after[p]);
            assert(a.mapPosTracking(p).deleted == first.deleted[p]);
        }

        // TXB-CHG7: touched ranges cover exactly the bytes that differ.
        size_t retainedA, retainedB;
        foreach (r; a.touched)
        {
            assert(r.fromA >= retainedA && r.fromB - retainedB == r.fromA - retainedA);
            assert(source[retainedA .. r.fromA] == first.result[retainedB .. r.fromB]);
            retainedA = r.toA;
            retainedB = r.toB;
        }
        assert(source[retainedA .. $] == first.result[retainedB .. $]);

        // TXB-CHG4 and TXB-CHG6: compose with a second edit of the result.
        auto second = generate(random, first.result);
        ChangeSet b;
        assert(ChangeSet.of(first.result.length, second.edits, b) == ChangeSetStatus.ok);
        const composed = a.compose(b);
        assert(composed.apply(text) == second.result);
        assert(composed.apply(text) == b.apply(a.apply(text)));
        foreach (p; 0 .. source.length + 1)
            foreach (affinity; [Affinity.before, Affinity.after])
                if (untouched(a, p) && untouched(b, a.mapPos(p, affinity)))
                    assert(composed.mapPos(p, affinity) == b.mapPos(a.mapPos(p, affinity), affinity));

        // Composition with the identity and with the inverse.
        assert(a.compose(ChangeSet.identity(a.resultLength)) == a);
        assert(ChangeSet.identity(a.sourceLength).compose(a) == a);
        assert(a.compose(a.invert(text)).apply(text) == source);
    }
}

/// Overlapping and same-position edits from several cursors (TXB-CHG1).
@("ChangeSet.of.unionSemantics")
@safe pure nothrow
unittest
{
    const text = Text("one two three");
    ChangeSet c;
    // Two word kills that overlap delete the union once.
    assert(ChangeSet.of(text.length, [Edit(4, 8, ""), Edit(6, 13, "")], c) == ChangeSetStatus.ok);
    assert(c.apply(text) == "one ");
    // Overlapping replacements concatenate their insertions in order of `from`.
    assert(ChangeSet.of(text.length, [Edit(6, 13, "B"), Edit(4, 8, "A")], c) == ChangeSetStatus.ok);
    assert(c.apply(text) == "one AB");
    // An insertion strictly inside a replaced range joins its group.
    assert(ChangeSet.of(text.length, [Edit(4, 7, "X"), Edit(5, 5, "y")], c) == ChangeSetStatus.ok);
    assert(c.apply(text) == "one Xy three");
    // Insertions at one position keep the order given.
    assert(ChangeSet.of(text.length, [Edit(3, 3, "1"), Edit(3, 3, "2"), Edit(3, 3, "3")], c)
        == ChangeSetStatus.ok);
    assert(c.apply(text) == "one123 two three");
    // A deletion and an insertion at its start: ties in the order given.
    assert(ChangeSet.of(text.length, [Edit(4, 7, "T"), Edit(4, 4, "<")], c) == ChangeSetStatus.ok);
    assert(c.apply(text) == "one T< three");
    // Invalid edits are rejected.
    assert(ChangeSet.of(text.length, [Edit(5, 4, "")], c) == ChangeSetStatus.invalidEdit);
    assert(ChangeSet.of(text.length, [Edit(3, 14, "")], c) == ChangeSetStatus.invalidEdit);
}

/// Composition forgets how an edit was split, so mapping does not compose at
/// a touched position (the TXB-CHG6 rationale).
@("ChangeSet.mapPos.composeOnlyAwayFromEdits")
@safe pure nothrow @nogc
unittest
{
    ChangeSet remove, insert, insertFirst, removeAfter;
    const Edit[1] r = [Edit(2, 5, "")];
    const Edit[1] i = [Edit(2, 2, "xyz")];
    assert(ChangeSet.of(8, r[], remove) == ChangeSetStatus.ok);
    assert(ChangeSet.of(5, i[], insert) == ChangeSetStatus.ok);
    const Edit[1] i2 = [Edit(2, 2, "xyz")];
    const Edit[1] r2 = [Edit(5, 8, "")];
    assert(ChangeSet.of(8, i2[], insertFirst) == ChangeSetStatus.ok);
    assert(ChangeSet.of(11, r2[], removeAfter) == ChangeSetStatus.ok);
    const one = remove.compose(insert);
    const two = insertFirst.compose(removeAfter);
    assert(one == two, "both compose to replacing [2, 5) with xyz");
    // Position 5 maps differently through the two splits.
    assert(insert.mapPos(remove.mapPos(5, Affinity.after), Affinity.after) == 5);
    assert(removeAfter.mapPos(insertFirst.mapPos(5, Affinity.after), Affinity.after) == 5);
    assert(insert.mapPos(remove.mapPos(5, Affinity.before), Affinity.before) == 2);
    assert(removeAfter.mapPos(insertFirst.mapPos(5, Affinity.before), Affinity.before) == 5);
}

/// The full attribute set (TXB-OWN5).
@("ChangeSet.attributes")
@safe pure nothrow @nogc
unittest
{
    const text = Text("hello world");
    const Edit[2] edits = [Edit(0, 5, "HELLO"), Edit(11, 11, "!")];
    ChangeSet c;
    assert(ChangeSet.of(text.length, edits[], c) == ChangeSetStatus.ok);
    assert(c.apply(text) == "HELLO world!");
    assert(c.invert(text).apply(c.apply(text)) == text);
    size_t count;
    foreach (range; c.touched)
        ++count;
    assert(count == 2 && !c.empty && ChangeSet.identity(3).empty);
}

/// `touched` owns a reference to the sections it walks.
@("ChangeSet.touched.outlivesReassignment")
@safe pure nothrow @nogc
unittest
{
    ChangeSet c;
    const Edit[2] edits = [Edit(1, 2, "x"), Edit(4, 4, "yz")];
    assert(ChangeSet.of(6, edits[], c) == ChangeSetStatus.ok);
    auto ranges = c.touched;
    c = ChangeSet.init;
    TouchedRange[2] seen;
    size_t n;
    foreach (r; ranges)
        seen[n++] = r;
    assert(n == 2 && seen[0] == TouchedRange(1, 2, 1, 2) && seen[1] == TouchedRange(4, 4, 4, 6));
}

/// Building into a variable that already holds a change set releases it.
@("ChangeSet.of.releasesOverwritten")
@safe pure nothrow @nogc
unittest
{
    import sparkles.text_buffer.node : liveNodes;

    size_t baseline;
    debug baseline = liveNodes;
    {
        ChangeSet c;
        const Edit[1] first = [Edit(0, 0, "an insertion long enough for two chunks")];
        const Edit[1] second = [Edit(0, 0, "another insertion, also long enough")];
        assert(ChangeSet.of(4, first[], c) == ChangeSetStatus.ok);
        assert(ChangeSet.of(4, second[], c) == ChangeSetStatus.ok);
        const Edit[1] bad = [Edit(3, 9, "")];
        assert(ChangeSet.of(4, bad[], c) == ChangeSetStatus.invalidEdit);
        assert(c.apply(Text("text")) == "another insertion, also long enoughtext");
    }
    size_t live;
    debug live = liveNodes;
    assert(live == baseline, "an overwritten change set leaked");
}
