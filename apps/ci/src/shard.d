/++
Deterministic work partitioning behind `ci --shard I/N`.

A CI provider parallelises a long step by running the same command on several
runners, each told which slice of the work it owns. For that to be sound the
slice has to be the same on every runner for a given input, so that the N
shards together cover the input exactly once; balanced by $(I cost) rather
than by count, because a four-way split that lands `base` and `hue` on one
runner has shortened nothing; and indifferent to the number of items, so that a
package added tomorrow lands in some shard without anyone editing a list.

$(LIST
    * $(LREF Shard) names a slice: index `i` of `n`, 1-based as written on the
        command line, parsed by $(LREF parseShard).
    * $(LREF assignShards) is the partition: longest-processing-time-first
        greedy — each item, heaviest first, goes to the currently lightest bin.
        That is within 4/3 of the optimal makespan and, more to the point,
        a pure function of the weights.
    * $(LREF shardOf) applies it to a list and returns the selected shard's
        items in their original order, so a sharded run reads like the
        unsharded one with rows removed.
)

The weights are a caller's business — measured seconds for a test package, an
example count for a markdown file — and only their ratios matter.
+/
module shard;

import std.algorithm : map;
import std.array : array;
import std.conv : to;

import expected : Expected, ok, err;

/// A `--shard I/N` selection: shard `index` of `count`, both 1-based.
/// `Shard.init` is the whole input (1 of 1).
struct Shard
{
    uint index = 1;
    uint count = 1;

    /// Whether this selection leaves anything out.
    bool active() const @safe pure nothrow @nogc => count > 1;

    /// `I/N`, as on the command line.
    void toString(Writer)(ref Writer w) const
    {
        import sparkles.base.text.writers : writeInteger;

        w.writeInteger(index);
        w.put('/');
        w.writeInteger(count);
    }
}

@("shard.Shard.default")
@safe pure nothrow @nogc
unittest
{
    assert(!Shard.init.active);
    assert(Shard(1, 1).index == 1);
    assert(Shard(2, 4).active);
}

@("shard.Shard.toString")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkToString;

    checkToString(Shard(2, 4), "2/4");
    checkToString(Shard.init, "1/1");
}

/**
Parses a `--shard` argument.

`I/N` with `1 ≤ I ≤ N`; an empty spec is the whole input. Anything else is an
error naming what was wrong, since a typo here silently testing a quarter of
the tree is the failure mode this exists to prevent.
*/
Expected!(Shard, string) parseShard(string spec) @safe pure
{
    import std.string : indexOf, strip;

    const s = spec.strip;
    if (s.length == 0)
        return ok!string(Shard.init);

    const slash = s.indexOf('/');
    if (slash <= 0 || slash == s.length - 1)
        return err!Shard("--shard expects I/N (e.g. 2/4), got '" ~ spec ~ "'");

    uint index, count;
    try
    {
        index = s[0 .. slash].to!uint;
        count = s[slash + 1 .. $].to!uint;
    }
    catch (Exception)
    {
        return err!Shard("--shard expects two positive integers I/N, got '" ~ spec ~ "'");
    }

    if (count == 0)
        return err!Shard("--shard: the shard count must be at least 1, got '" ~ spec ~ "'");
    if (index == 0 || index > count)
        return err!Shard("--shard: the index must be between 1 and " ~ count.to!string
            ~ ", got '" ~ spec ~ "'");
    return ok!string(Shard(index, count));
}

@("shard.parseShard.accepts")
@safe pure
unittest
{
    assert(parseShard("").value == Shard.init);
    assert(parseShard("1/1").value == Shard(1, 1));
    assert(parseShard("2/4").value == Shard(2, 4));
    assert(parseShard(" 4/4 ").value == Shard(4, 4));
}

@("shard.parseShard.rejects")
@safe
unittest
{
    import std.algorithm : canFind;

    foreach (bad; ["2", "/4", "2/", "0/4", "5/4", "a/b", "2/0", "-1/4", "2/4/8"])
        assert(parseShard(bad).hasError, bad);
    assert(parseShard("5/4").error.canFind("between 1 and 4"));
    assert(parseShard("x/2").error.canFind("positive integers"));
}

/**
Assigns every item to one of `count` bins so the heaviest bin is as light as
the greedy rule allows.

Items are visited heaviest first (ties by original position), each landing in
the lightest bin so far (ties by lowest bin number). The result is the 0-based
bin index per item, in input order.

Params:
    weights = one non-negative cost per item; only ratios matter
    count = number of bins, at least 1

Returns: `bin[i]` for every `i`, each in `0 .. count`
*/
uint[] assignShards(in size_t[] weights, uint count) @safe pure nothrow
in (count >= 1, "at least one shard")
{
    auto load = new ulong[count];
    auto bin = new uint[weights.length];
    auto placed = new bool[weights.length];
    // Heaviest unplaced item next, the earliest on a tie — a selection rather
    // than a library sort so the order is a plain function of the input (and
    // the loop stays `nothrow`); the inputs are dozens of items, not millions.
    foreach (_; 0 .. weights.length)
    {
        size_t i = size_t.max;
        foreach (j, w; weights)
            if (!placed[j] && (i == size_t.max || w > weights[i]))
                i = j;
        placed[i] = true;

        uint lightest = 0;
        foreach (b; 1 .. count)
            if (load[b] < load[lightest])
                lightest = b;
        bin[i] = lightest;
        load[lightest] += weights[i];
    }
    return bin;
}

@("shard.assignShards.balancesByWeight")
@safe pure nothrow
unittest
{
    // Heaviest first to the lightest bin: 10 → bin 0; 7 → bin 1 (empty);
    // 3 → bin 1 (7 < 10); 2 → bin 0 (10 = 10, the lower bin wins the tie).
    assert(assignShards([10, 7, 3, 2], 2) == [0, 1, 1, 0]);

    // The count-balanced split would put [10, 7] together; the weight-balanced
    // one does not.
    const bins = assignShards([10, 7, 1, 1, 1, 1], 2);
    assert(bins[0] != bins[1]);

    // More bins than items: each item alone, the rest empty.
    assert(assignShards([5, 3], 4) == [0, 1]);

    // Nothing to place.
    assert(assignShards([], 3).length == 0);
}

@("shard.assignShards.isDeterministicAndStable")
@safe pure nothrow
unittest
{
    const w = [4UL, 4, 4, 4, 4];
    // Equal weights round-robin in input order, and the same input gives the
    // same answer every time.
    assert(assignShards(w, 3) == [0, 1, 2, 0, 1]);
    assert(assignShards(w, 3) == assignShards(w, 3));
}

@("shard.assignShards.coversEveryItemOnce")
@safe pure nothrow
unittest
{
    const w = [654UL, 164, 91, 91, 69, 67, 66, 65, 54, 43, 39, 33, 31, 31, 31, 30,
        20, 20, 19, 16, 14, 14, 12, 12, 12, 11, 11, 11, 11, 9, 9, 7, 6, 6, 6,
        5, 5, 5, 5, 5, 4, 3, 3, 2, 2, 1, 2, 1];
    const bins = assignShards(w, 4);
    assert(bins.length == w.length);
    size_t[4] n;
    ulong[4] load;
    foreach (i, b; bins)
    {
        assert(b < 4);
        n[b]++;
        load[b] += w[i];
    }
    assert(n[0] + n[1] + n[2] + n[3] == w.length);
    // The outlier gets a bin of its own; the rest share the remainder evenly.
    assert(n[bins[0]] == 1);
    foreach (b; 0 .. 4)
        if (b != bins[0])
            assert(load[b] >= 380 && load[b] <= 440, "unbalanced");
}

/**
The items of shard `s`, in their original order.

`weight` is evaluated once per item; `Shard.init` returns the input unchanged
(no copy, no reordering).
*/
T[] shardOf(alias weight, T)(T[] items, Shard s)
in (s.count >= 1 && s.index >= 1 && s.index <= s.count, "a parsed Shard")
{
    if (!s.active)
        return items;

    const weights = items.map!(item => cast(size_t) weight(item)).array;
    const bins = assignShards(weights, s.count);
    T[] mine;
    foreach (i, item; items)
        if (bins[i] == s.index - 1)
            mine ~= item;
    return mine;
}

@("shard.shardOf.keepsInputOrderAndPartitions")
@safe pure nothrow
unittest
{
    static struct Item
    {
        string name;
        size_t cost;
    }

    auto items = [Item("a", 10), Item("b", 7), Item("c", 3), Item("d", 2)];
    // From assignShards above: a, d → shard 1; b, c → shard 2.
    assert(shardOf!(i => i.cost)(items, Shard(1, 2)) == [Item("a", 10), Item("d", 2)]);
    assert(shardOf!(i => i.cost)(items, Shard(2, 2)) == [Item("b", 7), Item("c", 3)]);

    // 1/1 is the identity, aliasing the input.
    assert(shardOf!(i => i.cost)(items, Shard.init) is items);

    // Every shard of one input together covers it exactly once; a shard may
    // legitimately be empty when there are more shards than items.
    size_t all;
    foreach (n; 1 .. 6)
    {
        all = 0;
        foreach (i; 1 .. n + 1)
            all += shardOf!(i => i.cost)(items, Shard(cast(uint) i, cast(uint) n)).length;
        assert(all == items.length);
    }
    assert(shardOf!(i => i.cost)(items, Shard(5, 5)).length == 0);
}
