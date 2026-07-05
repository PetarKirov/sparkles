/**
Shared plumbing for the shim-backed foreign engines: `jb_fingerprint` →
`Fingerprint` conversion and error-string extraction.
*/
module sparkles.wired_bench.engines.shim_support;

version (BenchCpp) version = BenchShim;
version (BenchRust) version = BenchShim;

version (BenchShim):

import sparkles.bench_shim : jb_fingerprint;
import sparkles.wired_bench.fingerprint : Fingerprint;

/// The D-side fingerprint of a shim-computed one (explicit field copies —
/// the two structs share the field set, not necessarily the layout).
package(sparkles.wired_bench) Fingerprint toFingerprint(in jb_fingerprint c)
    @safe pure nothrow @nogc
{
    Fingerprint f;
    f.nulls = c.nulls;
    f.trues = c.trues;
    f.falses = c.falses;
    f.numbers = c.numbers;
    f.strings = c.strings;
    f.arrays = c.arrays;
    f.objects = c.objects;
    f.arrayElems = c.array_elems;
    f.objectMembers = c.object_members;
    f.stringBytes = c.string_bytes;
    f.keyBytes = c.key_bytes;
    f.numberSum = c.number_sum;
    return f;
}

/// A GC copy of a context-owned error message (valid only until the next
/// shim call, hence the copy).
package(sparkles.wired_bench) string shimError(scope const(char)* msg) @trusted pure
{
    import std.string : fromStringz;

    return msg is null ? "unknown shim error" : msg.fromStringz.idup;
}
