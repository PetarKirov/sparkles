/**
The asdf engine — libmir's original fast JSON library: SSE4.2-accelerated
parsing into a compact cache-oriented binary document (mir-ion's
predecessor). The module stem is `asdf_json` because a module named `asdf`
would clash with the dependency's own package module.
*/
module sparkles.wired_bench.engines.asdf_json;

version (BenchAsdf):

import asdf.asdf : Asdf;
import asdf.jsonparser : parseJson;
import asdf.serialization : deserialize;

import sparkles.wired_bench.fingerprint : Fingerprint;
import sparkles.wired_bench.twitter : Twitter, TwitterStats, statsOf;

/// Adapter over asdf's `parseJson` and its binary `Asdf` document.
struct AsdfEngine
{
    enum name = "asdf";
    enum notes = "numbers stay textual in the tape (decoded on access)";

    private Asdf doc;
    private string rendered;

    /// Full parse into the compact `Asdf` representation.
    void parse(const(char)[] text)
    {
        doc = parseJson(text);
    }

    /// Drops the held document.
    void freeDoc()
    {
        doc = Asdf.init;
        rendered = null;
    }

    /// The held document as minified JSON.
    const(char)[] serialize()
    {
        import std.conv : to;

        rendered = doc.to!string;
        return rendered;
    }

    /// Structural fingerprint of the held document.
    Fingerprint fingerprint()
    {
        Fingerprint f;
        accumulateAsdf(doc, f);
        return f;
    }

    /// Typed decode through the binary tape.
    void decodeTwitter(const(char)[] text)
    {
        twitter = deserialize!Twitter(text);
    }

    /// Checksum of the held decoded document.
    TwitterStats twitterStats() const @safe pure nothrow @nogc
    {
        return statsOf(twitter);
    }

    private Twitter twitter;
}

/// Accumulates one `Asdf` subtree into `f`.
private void accumulateAsdf(Asdf v, ref Fingerprint f)
{
    final switch (v.kind)
    {
        case Asdf.Kind.null_:
            f.nulls++;
            break;
        case Asdf.Kind.true_:
            f.trues++;
            break;
        case Asdf.Kind.false_:
            f.falses++;
            break;
        case Asdf.Kind.number:
            f.numbers++;
            f.numberSum += v.get!double(double.nan);
            break;
        case Asdf.Kind.string:
            f.strings++;
            f.stringBytes += v.get!(const(char)[])(null).length;
            break;
        case Asdf.Kind.array:
            f.arrays++;
            foreach (e; v.byElement)
            {
                f.arrayElems++;
                accumulateAsdf(e, f);
            }
            break;
        case Asdf.Kind.object:
            f.objects++;
            foreach (kv; v.byKeyValue)
            {
                f.objectMembers++;
                f.keyBytes += kv.key.length;
                accumulateAsdf(kv.value, f);
            }
            break;
    }
}

@("AsdfEngine.parseSerializeRoundTrip")
unittest
{
    AsdfEngine e;
    e.parse(`{"a": [1, true, "x", 2.5, null]}`);

    const f = e.fingerprint();
    assert(f.numbers == 2 && f.trues == 1 && f.strings == 1 && f.nulls == 1);
    assert(f.arrays == 1 && f.arrayElems == 5);
    assert(f.objects == 1 && f.objectMembers == 1 && f.keyBytes == 1);
    assert(f.numberSum == 3.5);

    assert(e.serialize == `{"a":[1,true,"x",2.5,null]}`);
    e.freeDoc();
}
