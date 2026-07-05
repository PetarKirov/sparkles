/**
The mir-ion engine — the D ecosystem's high-performance serialization stack
(`@nogc`, SIMD-accelerated, compile-time introspection). DOM parsing goes
through `JsonAlgebraic`, mir's JSON variant type.
*/
module sparkles.wired_bench.engines.mir_ion;

version (BenchMirIon):

import mir.algebraic : visit;
import mir.algebraic_alias.json : JsonAlgebraic, StringMap;
import mir.deser.json : deserializeJson;
import mir.ser.json : serializeJson;

import sparkles.wired_bench.fingerprint : Fingerprint;
import sparkles.wired_bench.twitter : Twitter, TwitterStats, statsOf;

/// Adapter over `mir.deser.json` / `mir.ser.json` with a `JsonAlgebraic` DOM.
struct MirIonEngine
{
    enum name = "mir-ion";

    private JsonAlgebraic doc;
    private string rendered;

    /// Full DOM parse into a `JsonAlgebraic` tree.
    void parse(const(char)[] text)
    {
        doc = deserializeJson!JsonAlgebraic(text);
    }

    /// Drops the held document.
    void freeDoc()
    {
        doc = null;
        rendered = null;
    }

    /// The held document as minified JSON.
    const(char)[] serialize()
    {
        rendered = serializeJson(doc);
        return rendered;
    }

    /// Structural fingerprint of the held document.
    Fingerprint fingerprint()
    {
        Fingerprint f;
        accumulateMir(doc, f);
        return f;
    }

    /// Typed decode straight into the target struct (mir's signature path).
    void decodeTwitter(const(char)[] text)
    {
        twitter = deserializeJson!Twitter(text);
    }

    /// Checksum of the held decoded document.
    TwitterStats twitterStats() const @safe pure nothrow @nogc
    {
        return statsOf(twitter);
    }

    private Twitter twitter;
}

/// Accumulates one `JsonAlgebraic` subtree into `f`.
private void accumulateMir(in JsonAlgebraic v, ref Fingerprint f)
{
    v.visit!(
        (typeof(null)) { f.nulls++; },
        (bool b) {
            if (b)
                f.trues++;
            else
                f.falses++;
        },
        (long n) { f.numbers++; f.numberSum += n; },
        (double n) { f.numbers++; f.numberSum += n; },
        (const(char)[] s) { f.strings++; f.stringBytes += s.length; },
        (const JsonAlgebraic[] a) {
            f.arrays++;
            f.arrayElems += a.length;
            foreach (const ref e; a)
                accumulateMir(e, f);
        },
        (const StringMap!JsonAlgebraic o) {
            f.objects++;
            f.objectMembers += o.length;
            foreach (i, key; o.keys)
            {
                f.keyBytes += key.length;
                accumulateMir(o.values[i], f);
            }
        },
    );
}

@("MirIonEngine.parseSerializeRoundTrip")
unittest
{
    MirIonEngine e;
    e.parse(`{"a": [1, true, "x", 2.5, null]}`);

    const f = e.fingerprint();
    assert(f.numbers == 2 && f.trues == 1 && f.strings == 1 && f.nulls == 1);
    assert(f.arrays == 1 && f.arrayElems == 5);
    assert(f.objects == 1 && f.objectMembers == 1 && f.keyBytes == 1);
    assert(f.numberSum == 3.5);

    assert(e.serialize == `{"a":[1,true,"x",2.5,null]}`);
    e.freeDoc();
}
