#!/usr/bin/env dub
/+ dub.sdl:
    name "fts_ngram_selectivity"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * How much does an n-gram index actually narrow the candidate set?
 *
 * `PKM6` defers a bigram content index "until the grep source's scale justifies
 * it", and `theory/succinct-indexes.md` argues n-gram indexes and self-indexes
 * answer different questions. This example supplies the missing number: for a
 * corpus of code-shaped documents, what fraction survives a 2-gram filter, and
 * what fraction survives a 3-gram filter, for queries of realistic length?
 *
 * The corpus is GENERATED DETERMINISTICALLY here rather than read from the
 * working tree, per the catalog's measurement protocol: numbers quoted in prose
 * must not drift with every commit. The generator is a fixed LCG, so this
 * program prints the same table on every machine and every run.
 *
 * Backs `trigram-indexes/index.md` and thesis T2.
 */
module fts_ngram_selectivity;

import std.stdio : writefln, writeln;

@safe:

enum docCount = 2000;
enum docBytes = 4096;

/// A fixed linear congruential generator — reproducible, and not `Math.random`.
struct Lcg
{
    private ulong s;
    uint next() pure nothrow @nogc
    {
        s = s * 6364136223846793005UL + 1442695040888963407UL;
        return cast(uint)(s >> 33);
    }
    uint upto(uint n) pure nothrow @nogc => next() % n;
}

/// Identifier fragments, so the generated text has code-like byte statistics
/// (skewed, lots of `e`/`t`/`_`, few `q`/`z`) rather than uniform noise.
static immutable string[] fragments = [
    "parse", "buffer", "search", "index", "match", "line", "file", "path",
    "query", "token", "state", "value", "count", "offset", "length", "result",
    "handle", "render", "encode", "decode", "config", "filter", "cursor",
    "window", "thread", "stream", "commit", "branch", "record", "column",
];

static immutable string[] connectors = ["_", ".", "(", ") ", " = ", "; ", "\n    ", ", "];

/// Builds one document.
string makeDoc(ref Lcg rng) pure nothrow
{
    char[] buf;
    buf.reserve(docBytes + 64);
    while (buf.length < docBytes)
    {
        buf ~= fragments[rng.upto(cast(uint) fragments.length)];
        buf ~= connectors[rng.upto(cast(uint) connectors.length)];
    }
    return buf.idup;
}

/// A presence-only n-gram index: for each document, the set of n-grams it
/// contains. Stored as sorted unique keys per document, which is the shape a
/// posting list inverts.
uint[] gramsOf(scope const(char)[] doc, size_t n) pure nothrow
{
    bool[uint] seen;
    if (doc.length < n)
        return null;
    foreach (i; 0 .. doc.length - n + 1)
    {
        uint key;
        foreach (j; 0 .. n)
            key = (key << 8) | cast(ubyte) doc[i + j];
        seen[key] = true;
    }
    return seen.keys;
}

/// Candidate documents for `needle`: those containing every one of its n-grams.
size_t candidates(in bool[uint][] docGrams, scope const(char)[] needle, size_t n) pure nothrow
{
    if (needle.length < n)
        return docGrams.length; // no obligation extractable — a full scan
    uint[] want;
    foreach (i; 0 .. needle.length - n + 1)
    {
        uint key;
        foreach (j; 0 .. n)
            key = (key << 8) | cast(ubyte) needle[i + j];
        want ~= key;
    }

    size_t hits;
    outer: foreach (ref g; docGrams)
    {
        foreach (k; want)
            if (k !in g)
                continue outer;
        ++hits;
    }
    return hits;
}

/// Documents that really contain `needle` — the verification an index defers.
size_t truePositives(in string[] docs, scope const(char)[] needle) pure nothrow
{
    import std.string : indexOf;

    size_t n;
    foreach (d; docs)
        if (d.indexOf(needle) >= 0)
            ++n;
    return n;
}

void main()
{
    auto rng = Lcg(0x5EED_1234_9ABC_DEF0);
    string[] docs;
    docs.reserve(docCount);
    foreach (_; 0 .. docCount)
        docs ~= makeDoc(rng);

    bool[uint][] bi, tri;
    bi.reserve(docCount);
    tri.reserve(docCount);
    foreach (d; docs)
    {
        bool[uint] b, t;
        foreach (k; gramsOf(d, 2))
            b[k] = true;
        foreach (k; gramsOf(d, 3))
            t[k] = true;
        bi ~= b;
        tri ~= t;
    }

    size_t biKeys, triKeys;
    foreach (ref g; bi)
        biKeys += g.length;
    foreach (ref g; tri)
        triKeys += g.length;

    writefln("corpus: %s documents x ~%s bytes (deterministic LCG, seed fixed)",
        docCount, docBytes);
    writefln("index size: %s bigram postings, %s trigram postings (%.1fx)",
        biKeys, triKeys, cast(double) triKeys / biKeys);
    writeln();
    writefln("%-22s %8s %10s %10s %10s %10s", "query", "true", "2-gram", "2-gram FP",
        "3-gram", "3-gram FP");

    static immutable string[] queries = [
        "parse", "buffer_index", "search(", "zqx", "encode.column",
        "th", "render_window_offset",
    ];

    foreach (q; queries)
    {
        const truth = truePositives(docs, q);
        const c2 = candidates(bi, q, 2);
        const c3 = candidates(tri, q, 3);
        writefln("%-22s %8s %10s %9.1f%% %10s %9.1f%%", q, truth, c2,
            c2 == 0 ? 0.0 : 100.0 * (c2 - truth) / c2, c3,
            c3 == 0 ? 0.0 : 100.0 * (c3 - truth) / c3);
        assert(c2 >= truth, "a 2-gram filter must not lose a true positive");
        assert(c3 >= truth, "a 3-gram filter must not lose a true positive");
        assert(c3 <= c2 || q.length < 3, "3-grams must be at least as selective");
    }

    writeln("\nCaveat: this corpus is generated from a 30-word fragment vocabulary,",
        " so its\nn-gram distribution is far flatter than real source. Treat the",
        " SHAPE as the finding\n(trigrams narrow compound queries by an order of",
        " magnitude; short queries extract\nno obligation at all), not the",
        " absolute percentages.\n");
    writeln("Reading: 'FP' is the share of candidates the index admits that do",
        " NOT contain the\nquery — the work a scanner must then throw away.",
        " A query shorter than n has no\nextractable obligation and degenerates",
        " to a full scan (see 'th').");
}
