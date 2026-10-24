/**
Edits as values: a change set maps texts of one length to texts of another.

A change set is a sequence of sections covering its source: each retains `n`
bytes, or replaces `n` bytes with inserted text (a deletion inserts nothing,
an insertion replaces nothing). Adjacent sections of the same kind are merged,
so every edit has exactly one representation. The inserted texts of all
sections are kept, in order, in one `Text`.

Specification: `docs/specs/text-buffer/SPEC.md` §4 (TXB-CHG1–7).
*/
module sparkles.text_buffer.change_set;

import sparkles.text_buffer.node : Scratch;
import sparkles.text_buffer.storage : Growable, RcArray;
import sparkles.text_buffer.summary : Affinity;
import sparkles.text_buffer.text : Text;

/// One edit in source coordinates: replace `[from, to)` with `inserted`.
struct Edit
{
    size_t from;
    size_t to;
    Text inserted;

    this(size_t from, size_t to, Text inserted) @safe pure nothrow @nogc
    {
        this.from = from;
        this.to = to;
        this.inserted = inserted;
    }

    this(size_t from, size_t to, scope const(char)[] inserted) @safe pure nothrow @nogc
    {
        this(from, to, Text(inserted));
    }
}

/// Why `ChangeSet.of` rejected its edits.
enum ChangeSetStatus : ubyte
{
    ok,
    /// An edit had `from > to` or reached past the source.
    invalidEdit,
}

/// A replaced range in source (`a`) and result (`b`) coordinates.
struct TouchedRange
{
    size_t fromA;
    size_t toA;
    size_t fromB;
    size_t toB;
}

/// Where `mapPosTracking` put a position, and whether its bytes were deleted.
struct MappedPosition
{
    size_t position;
    /// The position lay strictly inside deleted bytes.
    bool deleted;
}

private struct Section
{
    size_t length;
    size_t inserted;
    bool kept;
}

/// An edit from texts of `sourceLength` bytes to texts of `resultLength`.
struct ChangeSet
{
    private RcArray!Section sections;
    private Text inserts;
    private size_t source;
    private size_t result;

    /// Copying shares the sections and the inserted text.
    this(ref scope const ChangeSet other) @safe pure nothrow @nogc
    {
        sections = other.sections;
        inserts = other.inserts;
        source = other.source;
        result = other.result;
    }

    /// ditto
    this(ref scope const ChangeSet other) const @safe pure nothrow @nogc
    {
        sections = other.sections;
        inserts = other.inserts;
        source = other.source;
        result = other.result;
    }

    /// The identity change set on texts of `length` bytes.
    static ChangeSet identity(size_t length) @safe pure nothrow @nogc
    {
        Builder builder;
        builder.keep(length);
        return builder.finish();
    }

    /**
    The change set made of `edits`, given in any order in source coordinates.

    Edits whose replaced ranges overlap, or that touch a range strictly inside
    another, form one group that replaces the union of their ranges with their
    inserted texts concatenated in order of `from` (ties in the order given).
    Insertions at one position outside any range appear in the order given.
    On success `changes` is overwritten, releasing what it held; on
    `invalidEdit` it is left as it was.
    */
    static ChangeSetStatus of(size_t sourceLength, scope const(Edit)[] edits,
        ref ChangeSet changes) @safe pure nothrow @nogc
    {
        foreach (ref edit; edits)
            if (edit.from > edit.to || edit.to > sourceLength)
                return ChangeSetStatus.invalidEdit;
        auto storage = Scratch!size_t(2 * edits.length);
        auto order = storage.slice[0 .. edits.length];
        foreach (i; 0 .. edits.length)
            order[i] = i;
        stableSortByFrom(edits, order, storage.slice[edits.length .. $]);

        Builder builder;
        size_t position;
        size_t i;
        while (i < order.length)
        {
            const start = edits[order[i]].from;
            size_t end = edits[order[i]].to;
            size_t j = i + 1;
            // Group every edit that starts inside the group's range. One that
            // starts exactly at its end only touches it; the merge of
            // adjacent replace sections makes the two forms the same.
            while (j < order.length && edits[order[j]].from < end)
            {
                if (edits[order[j]].to > end)
                    end = edits[order[j]].to;
                ++j;
            }
            builder.keep(start - position);
            builder.replace(end - start, Text.init);
            foreach (k; i .. j)
                builder.insert(edits[order[k]].inserted);
            position = end;
            i = j;
        }
        builder.keep(sourceLength - position);
        changes = builder.finish();
        assert(changes.source == sourceLength);
        return ChangeSetStatus.ok;
    }

    /// Length of the texts this change set applies to.
    size_t sourceLength() const scope @safe pure nothrow @nogc => source;

    /// Length of the texts it produces.
    size_t resultLength() const scope @safe pure nothrow @nogc => result;

    /// Whether it changes nothing.
    bool empty() const scope @safe pure nothrow @nogc
    {
        foreach (section; sections[])
            if (!section.kept)
                return false;
        return true;
    }

    /// The text this change set makes of `text`, whose length must be
    /// `sourceLength`.
    Text apply(in Text text) const scope @safe pure nothrow @nogc
    in (text.length == source, "a change set applies only to texts of its source length")
    {
        Text output;
        size_t position;
        size_t inserted;
        foreach (section; sections[])
        {
            if (section.kept)
                output = output.append(text.slice(position, position + section.length));
            else
            {
                output = output.append(inserts.slice(inserted, inserted + section.inserted));
                inserted += section.inserted;
            }
            position += section.length;
        }
        return output;
    }

    /// The change set that maps `apply(source)` back to `source`.
    ChangeSet invert(in Text sourceText) const scope @safe pure nothrow @nogc
    in (sourceText.length == source)
    {
        Builder builder;
        size_t position;
        foreach (section; sections[])
        {
            if (section.kept)
                builder.keep(section.length);
            else
            {
                builder.replace(section.inserted,
                    sourceText.slice(position, position + section.length));
            }
            position += section.length;
        }
        return builder.finish();
    }

    /// The change set equal to applying this one and then `next`.
    ChangeSet compose(in ChangeSet next) const scope @safe pure nothrow @nogc
    in (result == next.source, "composed change sets must meet in length")
    {
        auto a = Items(this);
        auto b = Items(next);
        Builder builder;
        while (true)
        {
            if (b.kind == Kind.insert)
            {
                builder.insert(next.inserts.slice(b.offset, b.offset + b.remaining));
                b.advance(b.remaining);
                continue;
            }
            if (a.kind == Kind.remove)
            {
                builder.replace(a.remaining, Text.init);
                a.advance(a.remaining);
                continue;
            }
            if (a.kind == Kind.end || b.kind == Kind.end)
            {
                assert(a.kind == Kind.end && b.kind == Kind.end, "lengths disagree");
                break;
            }
            const k = a.remaining < b.remaining ? a.remaining : b.remaining;
            if (a.kind == Kind.keep && b.kind == Kind.keep)
                builder.keep(k);
            else if (a.kind == Kind.keep) // and b removes
                builder.replace(k, Text.init);
            else if (b.kind == Kind.keep) // a inserted what b keeps
                builder.insert(inserts.slice(a.offset, a.offset + k));
            // else: a inserted what b removes
            a.advance(k);
            b.advance(k);
        }
        return builder.finish();
    }

    /**
    Where source position `p` lands in the result. Inside a retained run it
    moves by the net length change before it. Inside or at either edge of a
    replaced range, including the single position of an insertion, it lands
    at the start of the inserted text under `before` and its end under `after`.
    */
    size_t mapPos(size_t p, Affinity affinity = Affinity.before) const scope
        @safe pure nothrow @nogc
        => mapPosTracking(p, affinity).position;

    /// `mapPos`, also reporting whether `p` lay strictly inside deleted bytes.
    MappedPosition mapPosTracking(size_t p, Affinity affinity = Affinity.before) const scope
        @safe pure nothrow @nogc
    in (p <= source, "position is outside the source")
    {
        size_t a;
        size_t b;
        foreach (section; sections[])
        {
            if (section.kept)
            {
                if (p < a + section.length)
                    return MappedPosition(b + (p - a));
                b += section.length;
            }
            else
            {
                if (p <= a + section.length)
                    return MappedPosition(affinity == Affinity.before ? b : b + section.inserted,
                        p > a && p < a + section.length);
                b += section.inserted;
            }
            a += section.length;
        }
        return MappedPosition(b);
    }

    /// The replaced ranges, in order, in both coordinate systems.
    TouchedRanges touched() const scope @safe pure nothrow @nogc
        => TouchedRanges(sections);

    /// Equal sections and equal inserted text.
    bool opEquals(in ChangeSet other) const scope @safe pure nothrow @nogc
        => source == other.source && result == other.result
            && sections == other.sections && inserts == other.inserts;
}

/// The replaced ranges of a change set.
struct TouchedRanges
{
    // A reference to the change set's sections, so the slice below stays
    // alive for as long as the range does.
    private RcArray!Section owner;
    private const(Section)[] sections;
    private size_t a;
    private size_t b;

    private this(ref scope const RcArray!Section sections) @safe pure nothrow @nogc
    {
        owner = sections;
        this.sections = unscoped(owner[]);
        skipKept();
    }

    bool empty() const scope @safe pure nothrow @nogc => sections.length == 0;

    TouchedRange front() const scope @safe pure nothrow @nogc
        => TouchedRange(a, a + sections[0].length, b, b + sections[0].inserted);

    void popFront() scope @safe pure nothrow @nogc
    {
        a += sections[0].length;
        b += sections[0].inserted;
        sections = sections[1 .. $];
        skipKept();
    }

    private void skipKept() scope @safe pure nothrow @nogc
    {
        while (sections.length && sections[0].kept)
        {
            a += sections[0].length;
            b += sections[0].length;
            sections = sections[1 .. $];
        }
    }
}

private:

/// Accumulates sections, merging neighbours of the same kind.
struct Builder
{
    Growable!Section sections;
    Text inserts;
    size_t source;
    size_t result;

    void keep(size_t n) @safe pure nothrow @nogc
    {
        if (n == 0)
            return;
        auto all = sections[];
        if (all.length && all[$ - 1].kept)
            all[$ - 1].length += n;
        else
            sections.put(Section(n, 0, true));
        source += n;
        result += n;
    }

    void replace(size_t removed, in Text text) @safe pure nothrow @nogc
    {
        if (removed == 0 && text.length == 0)
            return;
        auto all = sections[];
        if (all.length && !all[$ - 1].kept)
        {
            all[$ - 1].length += removed;
            all[$ - 1].inserted += text.length;
        }
        else
            sections.put(Section(removed, text.length, false));
        inserts = inserts.append(text);
        source += removed;
        result += text.length;
    }

    void insert(in Text text) @safe pure nothrow @nogc => replace(0, text);

    ChangeSet finish() @safe pure nothrow @nogc
    {
        ChangeSet changes;
        changes.sections = sections.freeze();
        changes.inserts = inserts;
        changes.source = source;
        changes.result = result;
        return changes;
    }
}

enum Kind : ubyte
{
    keep,
    remove,
    insert,
    end,
}

/// A change set read as keep, remove and insert items, consumed piecewise.
struct Items
{
    const(Section)[] sections;
    Kind kind;
    size_t remaining;
    /// Offset of the current insert into the change set's inserted text.
    size_t offset;

    this(return scope const ref ChangeSet changes) @safe pure nothrow @nogc
    {
        sections = changes.sections[];
        load();
    }

    void advance(size_t n) scope @safe pure nothrow @nogc
    {
        remaining -= n;
        if (kind == Kind.insert)
            offset += n;
        if (remaining == 0)
            next();
    }

    private void load() scope @safe pure nothrow @nogc
    {
        while (sections.length)
        {
            const s = sections[0];
            if (s.kept)
            {
                kind = Kind.keep;
                remaining = s.length;
                return;
            }
            if (s.length)
            {
                kind = Kind.remove;
                remaining = s.length;
                return;
            }
            if (s.inserted)
            {
                kind = Kind.insert;
                remaining = s.inserted;
                return;
            }
            sections = sections[1 .. $];
        }
        kind = Kind.end;
        remaining = 0;
    }

    private void next() scope @safe pure nothrow @nogc
    {
        // A replace section is a removal followed by an insertion.
        if (kind == Kind.remove && sections[0].inserted)
        {
            kind = Kind.insert;
            remaining = sections[0].inserted;
            return;
        }
        sections = sections[1 .. $];
        load();
    }
}

/// Stable merge sort of `order` (indices into `edits`) by `from`.
void stableSortByFrom(scope const(Edit)[] edits, scope size_t[] order, scope size_t[] buffer)
    @safe pure nothrow @nogc
{
    for (size_t width = 1; width < order.length; width *= 2)
    {
        for (size_t lo = 0; lo < order.length; lo += 2 * width)
        {
            const mid = lo + width < order.length ? lo + width : order.length;
            const hi = lo + 2 * width < order.length ? lo + 2 * width : order.length;
            size_t i = lo, j = mid, k = lo;
            while (i < mid && j < hi)
                buffer[k++] = edits[order[j]].from < edits[order[i]].from ? order[j++] : order[i++];
            while (i < mid)
                buffer[k++] = order[i++];
            while (j < hi)
                buffer[k++] = order[j++];
        }
        order[] = buffer[0 .. order.length];
    }
}

/// The sections of an array the caller holds a reference to; dip1000 cannot
/// see that the range's own `owner` field keeps them alive.
const(Section)[] unscoped(scope const(Section)[] sections) @trusted pure nothrow @nogc
    => (cast(const(Section)*) cast(size_t) sections.ptr)[0 .. sections.length];
