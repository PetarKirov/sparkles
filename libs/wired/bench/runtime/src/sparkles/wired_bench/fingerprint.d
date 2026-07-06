/**
Cross-engine structural fingerprints.

Every engine must reproduce the same `Fingerprint` for a dataset as the
`std.json` reference walk before its timings are trusted — the harness's
defense against an engine silently parsing differently (lossy numbers,
skipped members, wrong unescaping). Counters are compared exactly;
`numberSum` uses a relative tolerance because floating-point addition is not
associative and object iteration order differs between engines (`std.json`
walks an unordered associative array, most engines walk in document order).
*/
module sparkles.wired_bench.fingerprint;

import std.json : JSONType, JSONValue, parseJSON;
import std.math : fabs, fmax, isFinite;

/// Structural summary of one parsed JSON document.
struct Fingerprint
{
    ulong nulls;         /// number of `null` values
    ulong trues;         /// number of `true` values
    ulong falses;        /// number of `false` values
    ulong numbers;       /// numbers of any kind (engines disagree on int-vs-float)
    ulong strings;       /// value-position strings
    ulong arrays;        /// array values
    ulong objects;       /// object values
    ulong arrayElems;    /// summed lengths of all arrays
    ulong objectMembers; /// summed member counts of all objects
    ulong stringBytes;   /// decoded (unescaped) UTF-8 bytes of value strings
    ulong keyBytes;      /// decoded UTF-8 bytes of object keys
    double numberSum = 0; /// sum of every number as `double`

    /// Whether the two fingerprints agree: counters exactly, `numberSum`
    /// within relative tolerance.
    bool matches(in Fingerprint other) const @safe pure nothrow @nogc
    {
        static foreach (i, T; typeof(Fingerprint.init.tupleof))
            static if (is(T == ulong))
                if (this.tupleof[i] != other.tupleof[i])
                    return false;
        return approxSum(numberSum, other.numberSum);
    }
}

/// Whether two number sums agree within relative tolerance.
private bool approxSum(double a, double b) @safe pure nothrow @nogc
{
    if (!a.isFinite || !b.isFinite)
        return false;
    return fabs(a - b) <= 1e-9 * fmax(fabs(a), fabs(b)) + 1e-12;
}

/// A human-readable field-by-field mismatch summary (empty when matching).
string diffFingerprints(in Fingerprint expected, in Fingerprint actual) @safe pure
{
    import std.conv : to;

    string s;
    static foreach (i, T; typeof(Fingerprint.init.tupleof))
        static if (is(T == ulong))
            if (expected.tupleof[i] != actual.tupleof[i])
                s ~= "\n    " ~ __traits(identifier, Fingerprint.tupleof[i])
                    ~ ": expected " ~ expected.tupleof[i].to!string
                    ~ ", got " ~ actual.tupleof[i].to!string;
    if (!approxSum(expected.numberSum, actual.numberSum))
        s ~= "\n    numberSum: expected " ~ expected.numberSum.to!string
            ~ ", got " ~ actual.numberSum.to!string;
    return s;
}

/// The reference fingerprint of a dataset: a `std.json` parse + walk.
Fingerprint referenceFingerprint(const(char)[] text) @safe
{
    const doc = parseJSON(text);
    Fingerprint f;
    accumulate(doc, f);
    return f;
}

/// Accumulates one `JSONValue` subtree into `f`.
void accumulate(const ref JSONValue v, ref Fingerprint f) @safe
{
    final switch (v.type)
    {
        case JSONType.null_:
            f.nulls++;
            break;
        case JSONType.true_:
            f.trues++;
            break;
        case JSONType.false_:
            f.falses++;
            break;
        case JSONType.integer:
            f.numbers++;
            f.numberSum += v.integer;
            break;
        case JSONType.uinteger:
            f.numbers++;
            f.numberSum += v.uinteger;
            break;
        case JSONType.float_:
            f.numbers++;
            f.numberSum += v.floating;
            break;
        case JSONType.string:
            f.strings++;
            f.stringBytes += v.str.length;
            break;
        case JSONType.array:
            f.arrays++;
            f.arrayElems += v.arrayNoRef.length;
            foreach (const ref e; v.arrayNoRef)
                accumulate(e, f);
            break;
        case JSONType.object:
            f.objects++;
            f.objectMembers += v.objectNoRef.length;
            foreach (key, const ref e; v.objectNoRef)
            {
                f.keyBytes += key.length;
                accumulate(e, f);
            }
            break;
    }
}

@("fingerprint.referenceFingerprint.smallDoc")
@safe unittest
{
    const f = referenceFingerprint(
        `{"a": [1, 2.5, "x\n", true, false, null], "b": {}}`);
    assert(f.nulls == 1 && f.trues == 1 && f.falses == 1);
    assert(f.numbers == 2);
    assert(f.strings == 1 && f.stringBytes == 2); // "x\n" decodes to 2 bytes
    assert(f.arrays == 1 && f.arrayElems == 6);
    assert(f.objects == 2 && f.objectMembers == 2);
    assert(f.keyBytes == 2);
    assert(f.numberSum == 3.5);
}

@("fingerprint.matches.toleranceAndDiff")
@safe pure unittest
{
    Fingerprint a, b;
    a.numbers = b.numbers = 3;
    a.numberSum = 1.0;
    b.numberSum = 1.0 + 1e-13;
    assert(a.matches(b));

    b.strings = 1;
    assert(!a.matches(b));
    assert(diffFingerprints(a, b).length > 0);
}
