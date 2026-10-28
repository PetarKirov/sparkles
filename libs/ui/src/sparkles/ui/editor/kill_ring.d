/**
Readline's kill ring (`EDY1`): a short, bounded history of killed text that
only the editor reads, separate from the system clipboard.

An entry holds one part per range of the kill that made it, each a `Text`
slice of the document, so a kill of any size is shared rather than copied
and is never truncated. One ring serves every editor of a host session; the
host owns it and passes it to the step by value.

Specification: `docs/specs/ui/editor.md` §5.
*/
module sparkles.ui.editor.kill_ring;

import sparkles.base.buffer : SharedBuffer;
import sparkles.text_buffer.text : Text;

/// The most entries a ring can be configured to keep.
enum size_t maxKillRingSize = 32;

/// One kill: its parts, one per range, stored end to end.
struct KillEntry
{
    private Text joined;
    private SharedBuffer!(size_t, 2) ends;

@safe pure nothrow @nogc:

    /// An entry of one part per text in `parts`.
    static KillEntry of(scope const(Text)[] parts)
    {
        KillEntry entry;
        foreach (ref part; parts)
        {
            entry.joined = entry.joined.append(part);
            entry.ends.put(entry.joined.length);
        }
        return entry;
    }

    /// Number of parts.
    size_t parts() const scope => ends.length;

    /// Part `i`.
    Text part(size_t i) const scope
    in (i < parts)
        => joined.slice(i ? ends[i - 1] : 0, ends[i]);

    /// The parts joined by LF (`EDY4`, when parts and ranges differ in number).
    Text joinedByLine() const scope
    {
        Text result;
        foreach (i; 0 .. parts)
        {
            if (i)
                result = result.append(Text("\n"));
            result = result.append(part(i));
        }
        return result;
    }

    /// This entry with each part extended by `more`'s matching part: after it
    /// for a forward kill, before it for a backward one (`EDY2`).
    KillEntry extended(in KillEntry more, bool backward) const scope
    in (more.parts == parts)
    {
        KillEntry result;
        foreach (i; 0 .. parts)
        {
            const merged = backward ? more.part(i).append(part(i)) : part(i).append(more.part(i));
            result.joined = result.joined.append(merged);
            result.ends.put(result.joined.length);
        }
        return result;
    }

    bool opEquals(in KillEntry other) const scope
        => joined == other.joined && ends[] == other.ends[];
}

/// The ring: at most `size` entries, the oldest dropped when full.
struct KillRing
{
    private KillEntry[maxKillRingSize] entries;
    private size_t count;
    private size_t newestAt;
    /// How many entries the ring keeps; Readline keeps 10.
    size_t size = 10;

@safe pure nothrow @nogc:

    /// Number of entries.
    size_t length() const scope => count;

    bool empty() const scope => count == 0;

    /// The entry `age` kills back; 0 is the newest. Cycles past the oldest.
    ref const(KillEntry) at(size_t age) const return
    in (count)
        => entries[(newestAt + maxKillRingSize - age % count) % maxKillRingSize];

    /// Add `entry` as the newest; returns whether the oldest was dropped.
    bool push(KillEntry entry) scope
    {
        const capacity = size < 1 ? 1 : size > maxKillRingSize ? maxKillRingSize : size;
        newestAt = count ? (newestAt + 1) % maxKillRingSize : 0;
        // Keep the live entries contiguous before newestAt by trimming from
        // the oldest end when the configured size is reached.
        entries[newestAt] = entry;
        if (count < capacity)
        {
            ++count;
            return false;
        }
        return true;
    }

    /// Replace the newest entry.
    void replaceNewest(KillEntry entry) scope
    in (count)
    {
        entries[newestAt] = entry;
    }
}

///
@("editor.killRing.boundedAndCycling")
@safe pure nothrow @nogc
unittest
{
    KillRing ring;
    ring.size = 3;
    foreach (i, word; ["one", "two", "three", "four"])
    {
        const Text[1] parts = [Text(word)];
        const dropped = ring.push(KillEntry.of(parts[]));
        assert(dropped == (i == 3));
    }
    assert(ring.length == 3);
    assert(ring.at(0).part(0) == "four");
    assert(ring.at(2).part(0) == "two");
    assert(ring.at(3).part(0) == "four", "yank-pop cycles");

    const Text[2] two = [Text("ab"), Text("cd")];
    const Text[2] more = [Text("X"), Text("Y")];
    const entry = KillEntry.of(two[]);
    const forward = entry.extended(KillEntry.of(more[]), false);
    assert(forward.part(0) == "abX" && forward.part(1) == "cdY");
    const backward = entry.extended(KillEntry.of(more[]), true);
    assert(backward.part(0) == "Xab" && backward.joinedByLine == "Xab\nYcd");
}
