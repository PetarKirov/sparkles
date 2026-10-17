/**
`sparkles.base.hash.blake3` against the official C implementation
(`libblake3`, which picks its own SIMD level at runtime).

---
dub test --root=libs/base/bench/blake3 -b bench -- -i blake3_bench.agree
dub test --root=libs/base/bench/blake3 -b bench -- --bench \
    -i blake3_bench.throughput --group-by=size
---
*/
module sparkles.blake3_bench.compare;

import std.conv : to;

import sparkles.base.hash.blake3;
import sparkles.blake3_bench.c : blake3_hasher, blake3_hasher_finalize,
    blake3_hasher_init, blake3_hasher_init_derive_key, blake3_hasher_init_keyed,
    blake3_hasher_update, blake3_version;
import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, benchProvenance, blackBox, Metric, Unit;

private:

// The C reference's one-shot hash.
ubyte[32] cBlake3(scope const(ubyte)[] input) @trusted nothrow @nogc
{
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, input.ptr, input.length);
    ubyte[32] digest;
    blake3_hasher_finalize(&hasher, digest.ptr, digest.length);
    return digest;
}

ubyte[32] dBlake3(Blake3Backend backend, scope const(ubyte)[] input) @safe pure nothrow @nogc
{
    auto hasher = Blake3.withBackend(backend);
    hasher.put(input);
    return hasher.finish();
}

ubyte[] randomBytes(size_t length, ulong seed) @safe pure nothrow
{
    auto bytes = new ubyte[](length);
    foreach (ref b; bytes)
    {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        b = cast(ubyte) seed;
    }
    return bytes;
}

enum backendNames = [__traits(allMembers, Blake3Backend)][1 .. $];

@("blake3_bench.agree")
@system unittest
{
    auto data = randomBytes(3 << 20, 0x5EED);
    static immutable size_t[] lengths = [
        0, 1, 64, 1023, 1024, 1025, 4097, 65_536, 100_000, 1 << 20, (3 << 20) - 1,
    ];
    foreach (length; lengths)
    {
        const input = data[0 .. length];
        const expected = cBlake3(input);
        static foreach (name; backendNames)
        {{
            enum backend = __traits(getMember, Blake3Backend, name);
            if (isSupported(backend))
                assert(dBlake3(backend, input) == expected, name ~ " at " ~ length.to!string);
        }}

        // Keyed and key-derivation modes, with a long extended output.
        ubyte[32] key = data[1000 .. 1032];
        blake3_hasher keyed, derived;
        blake3_hasher_init_keyed(&keyed, key.ptr);
        blake3_hasher_update(&keyed, input.ptr, input.length);
        blake3_hasher_init_derive_key(&derived, "sparkles blake3 bench context");
        blake3_hasher_update(&derived, input.ptr, input.length);
        ubyte[1000] cKeyed, cDerived, dKeyed, dDerived;
        blake3_hasher_finalize(&keyed, cKeyed.ptr, cKeyed.length);
        blake3_hasher_finalize(&derived, cDerived.ptr, cDerived.length);
        auto dKeyedHasher = Blake3.keyed(key);
        dKeyedHasher.put(input);
        dKeyedHasher.finishXof(dKeyed[]);
        auto dDerivedHasher = Blake3.deriveKey("sparkles blake3 bench context");
        dDerivedHasher.put(input);
        dDerivedHasher.finishXof(dDerived[]);
        assert(dKeyed == cKeyed);
        assert(dDerived == cDerived);
    }
}

// Each case's state lives on the heap: cases run after the test body returns.
final class Row
{
    Blake3Backend backend;
    bool reference; // the C implementation instead of `backend`
    ubyte[] input;
    ubyte[32] expected;

    this(Blake3Backend backend, bool reference, size_t size) @system
    {
        this.backend = backend;
        this.reference = reference;
        input = randomBytes(size, size + 1);
        expected = cBlake3(input);
    }

    ubyte[32] timed() @system
    {
        return reference ? cBlake3(blackBox(input)) : dBlake3(backend, blackBox(input));
    }

    void after(ref ubyte[32] digest) @safe
    {
        if (digest != expected)
            throw new Exception("digest differs from the C reference's");
    }
}

void register(string name, Blake3Backend backend, bool reference, string sizeLabel, size_t size)
    @system
{
    auto row = new Row(backend, reference, size);
    benchCase(
        name: name,
        labels: ["size": sizeLabel],
        timed: &row.timed,
        after: &row.after,
        metrics: [Metric(Unit("B"), size, Metric.Mode.rate)]);
}

@("blake3_bench.throughput")
@benchmark @system
unittest
{
    import std.string : fromStringz;

    benchProvenance("C reference: libblake3 " ~ blake3_version().fromStringz.idup
        ~ " (runtime SIMD dispatch)");
    static immutable sizes = [
        Size("1KiB", 1 << 10), Size("64KiB", 1 << 16), Size("1MiB", 1 << 20),
    ];
    foreach (size; sizes)
    {
        register("C libblake3", Blake3Backend.automatic, true, size.label, size.bytes);
        static foreach (name; backendNames)
        {{
            enum backend = __traits(getMember, Blake3Backend, name);
            if (isSupported(backend))
                register("D " ~ name, backend, false, size.label, size.bytes);
        }}
    }
}

struct Size
{
    string label;
    size_t bytes;
}
