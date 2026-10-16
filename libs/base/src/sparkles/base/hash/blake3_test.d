/**
Conformance tests for `sparkles.base.hash.blake3`: the official test vectors
on every backend, and every backend against the portable one on random
inputs, split points, counters and output offsets.
*/
module sparkles.base.hash.blake3_test;

version (unittest):

import std.meta : AliasSeq;

import sparkles.base.hash.blake3;
import sparkles.base.hash.blake3_vectors;
import sparkles.test_runner.attributes : benchmark;

private:

// Every backend except `automatic`, which resolves to one of them.
enum concreteBackendNames = [__traits(allMembers, Blake3Backend)][1 .. $];

// The vectors' input: the bytes 0, 1, ..., 250 repeated.
static immutable ubyte[102_400] vectorInput = () {
    ubyte[102_400] bytes;
    foreach (i, ref b; bytes)
        b = cast(ubyte) (i % 251);
    return bytes;
}();

ubyte[131] fromHex(string hex) @safe pure nothrow @nogc
in (hex.length == 262)
{
    static ubyte nibble(char c) @safe pure nothrow @nogc =>
        cast(ubyte) (c <= '9' ? c - '0' : c - 'a' + 10);
    ubyte[131] bytes;
    foreach (i, ref b; bytes)
        b = cast(ubyte) (nibble(hex[2 * i]) << 4 | nibble(hex[2 * i + 1]));
    return bytes;
}

// A deterministic xorshift64 stream.
struct Rng
{
    ulong state;

    ulong next() @safe pure nothrow @nogc
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }

    void fill(scope ubyte[] bytes) @safe pure nothrow @nogc
    {
        foreach (ref b; bytes)
            b = cast(ubyte) next();
    }
}

void requireSupported(Blake3Backend backend) @safe pure nothrow @nogc
{
    import sparkles.test_runner.skip : skipTest;

    if (!isSupported(backend))
        skipTest("backend not supported by this build or CPU");
}

// Checks the full 131-byte outputs of one mode on one backend, both from a
// single `put` and from input fed in uneven pieces.
void checkVectorMode(Blake3 hasher, size_t inputLength, string expectedHex)
    @safe pure nothrow @nogc
{
    const expected = fromHex(expectedHex);
    const input = vectorInput[0 .. inputLength];

    auto whole = hasher;
    whole.put(input);
    ubyte[131] output;
    whole.finishXof(output[]);
    assert(output == expected);
    assert(whole.finish() == expected[0 .. 32]);

    // Every suffix of the output, read with a seek.
    static immutable size_t[] seeks = [1, 31, 63, 64, 65, 130];
    foreach (seek; seeks)
    {
        ubyte[131] tail;
        whole.finishXof(tail[0 .. 131 - seek], seek);
        assert(tail[0 .. 131 - seek] == expected[seek .. $]);
    }

    auto pieces = hasher;
    size_t offset;
    size_t step = 1;
    while (offset < input.length)
    {
        const end = offset + step < input.length ? offset + step : input.length;
        pieces.put(input[offset .. end]);
        offset = end;
        step = step * 3 + 1;
    }
    assert(pieces.finish() == expected[0 .. 32]);
}

static foreach (name; concreteBackendNames)
{
    @("blake3.vectors." ~ name)
    @safe pure nothrow @nogc
    unittest
    {
        enum backend = __traits(getMember, Blake3Backend, name);
        requireSupported(backend);
        ubyte[32] key = cast(const(ubyte)[]) blake3VectorKey;
        foreach (v; blake3Vectors)
        {
            checkVectorMode(Blake3.withBackend(backend), v.inputLength, v.hash);
            checkVectorMode(Blake3.keyed(key, backend), v.inputLength, v.keyedHash);
            checkVectorMode(Blake3.deriveKey(blake3VectorContext, backend),
                v.inputLength, v.deriveKey);
        }
    }

    @("blake3.differential." ~ name)
    @safe pure nothrow
    unittest
    {
        enum backend = __traits(getMember, Blake3Backend, name);
        requireSupported(backend);
        static immutable size_t[] lengths = [
            0, 1, 63, 64, 65, 127, 128, 129, 1023, 1024, 1025, 2047, 2048,
            2049, 3072, 3073, 4095, 4096, 4097, 8191, 8192, 8193, 15 * 1024 + 1,
            16 * 1024, 16 * 1024 + 1, 17 * 1024, 31_744, 32 * 1024 + 7,
            65_536, 102_400, 1 << 20, (1 << 20) + 1023 * 3,
        ];
        auto rng = Rng(0x9E37_79B9_7F4A_7C15);
        auto data = new ubyte[](lengths[$ - 1]);
        rng.fill(data);
        ubyte[32] key;
        rng.fill(key[]);

        foreach (length; lengths)
        {
            const input = data[0 .. length];
            static foreach (makeHasher; AliasSeq!(
                (Blake3Backend b) => Blake3.withBackend(b),
                (Blake3Backend b) => Blake3.keyed(key, b),
                (Blake3Backend b) => Blake3.deriveKey("sparkles blake3 test", b),
            ))
            {{
                auto reference = makeHasher(Blake3Backend.portable);
                reference.put(input);
                auto subject = makeHasher(backend);
                subject.put(input);
                assert(subject.finish() == reference.finish());

                // Output blocks far past 2^32 exercise the counter's high word.
                ubyte[300] expectedXof, actualXof;
                const seek = (ulong(1) << 38) - 70;
                reference.finishXof(expectedXof[], seek);
                subject.finishXof(actualXof[], seek);
                assert(actualXof == expectedXof);

                // Random split points.
                foreach (trial; 0 .. 3)
                {
                    auto streamed = makeHasher(backend);
                    size_t offset;
                    while (offset < input.length)
                    {
                        const remaining = input.length - offset;
                        const take = trial == 0 ? 1 + rng.next() % 97
                            : 1 + rng.next() % (remaining < 40_000 ? remaining : 40_000);
                        const end = offset + (take < remaining ? take : remaining);
                        streamed.put(input[offset .. end]);
                        offset = end;
                        if (length > 70_000 && trial == 0)
                            break; // byte-trickling 1 MiB costs too long
                    }
                    if (offset == input.length)
                        assert(streamed.finish() == reference.finish());
                }
            }}
        }
    }

    @("blake3.hashMany." ~ name)
    @safe pure nothrow
    unittest
    {
        import sparkles.base.hash.blake3 : hashMany, hashManyPortable;

        enum backend = __traits(getMember, Blake3Backend, name);
        requireSupported(backend);
        auto rng = Rng(0xD1B5_4A32_D192_ED03);
        auto input = new ubyte[](40 * 1024);
        rng.fill(input);
        uint[8] key;
        foreach (ref word; key)
            word = cast(uint) rng.next();

        // Chunks (16 blocks, incrementing counters) and parents (1 block,
        // fixed counter), for every count around each SIMD width, with
        // counters that carry into the high word mid-batch.
        foreach (blocks; [1, 2, 16])
            foreach (count; 0 .. 40)
                foreach (counter; [0UL, 0xFFFF_FFFAUL, (1UL << 40) + 3])
                    foreach (increment; [false, true])
                    {
                        ubyte[40 * 32] expected, actual;
                        hashManyPortable(input, count, blocks, key, counter,
                            increment, 3, 1, 2, expected[]);
                        hashMany(backend, input, count, blocks, key, counter,
                            increment, 3, 1, 2, actual[]);
                        assert(actual == expected);
                    }
    }

    @("blake3.compress." ~ name)
    @safe pure nothrow @nogc
    unittest
    {
        import sparkles.base.hash.blake3 : compressInPlace, compressPortable,
            compressXof;

        enum backend = __traits(getMember, Blake3Backend, name);
        requireSupported(backend);
        auto rng = Rng(0x2545_F491_4F6C_DD1D);
        foreach (trial; 0 .. 200)
        {
            ubyte[64] block;
            rng.fill(block[]);
            uint[8] cv;
            foreach (ref word; cv)
                word = cast(uint) rng.next();
            const counter = rng.next() >> (trial % 64);
            const blockLength = cast(ubyte) (rng.next() % 65);
            const flags = cast(ubyte) (rng.next() & 0x7F);

            uint[8] expected = cv, actual = cv;
            compressPortable(expected, block[], blockLength, counter, flags);
            compressInPlace(backend, actual, block[], blockLength, counter, flags);
            assert(actual == expected);

            ubyte[64] xof;
            compressXof(backend, cv, block[], blockLength, counter, flags, xof);
            ubyte[64] xofPortable;
            compressXof(Blake3Backend.portable, cv, block[], blockLength, counter,
                flags, xofPortable);
            assert(xof == xofPortable);
        }
    }
}

@("blake3.automatic.matchesBest")
@safe pure nothrow @nogc
unittest
{
    assert(isSupported(bestBlake3Backend));
    auto automatic = Blake3.init;
    auto best = Blake3.withBackend(bestBlake3Backend);
    automatic.put(vectorInput[]);
    best.put(vectorInput[]);
    assert(automatic.finish() == best.finish());
}

@("blake3.Blake3.resetKeepsMode")
@safe pure nothrow @nogc
unittest
{
    ubyte[32] key = 9;
    auto hasher = Blake3.keyed(key);
    hasher.put("discarded");
    hasher.reset();
    hasher.put("kept");
    assert(hasher.finish() == blake3Keyed(key, "kept"));
}

@("blake3.Blake3.finishThenContinue")
@safe pure nothrow @nogc
unittest
{
    Blake3 hasher;
    hasher.put(vectorInput[0 .. 5000]);
    const early = hasher.finish();
    assert(early == blake3(vectorInput[0 .. 5000]));
    hasher.put(vectorInput[5000 .. 9000]);
    assert(hasher.finish() == blake3(vectorInput[0 .. 9000]));
}

// Throughput of each backend on one input size: `dub test :base -b bench --
// --bench -i blake3.bench --group-by=size`. A case runs after its test body
// returns, so its state lives on the heap, not in a closure frame.
final class ThroughputCase
{
    Blake3Backend backend;
    ubyte[] input;
    ubyte[32] expected;

    this(Blake3Backend backend, size_t size) @safe
    {
        this.backend = backend;
        input = new ubyte[](size);
        Rng(size).fill(input);
        expected = blake3With(Blake3Backend.portable, input);
    }

    ubyte[32] timed() @safe
    {
        import sparkles.test_runner.bench : blackBox;

        return blake3With(backend, blackBox(input));
    }

    void after(ref ubyte[32] digest) @safe
    {
        if (digest != expected)
            throw new Exception("digest differs from the portable backend's");
    }
}

void registerThroughput(Blake3Backend backend, string sizeLabel, size_t size) @safe
{
    import std.conv : to;
    import sparkles.test_runner.bench : benchCase, Metric, Unit;

    auto c = new ThroughputCase(backend, size);
    benchCase(
        name: backend.to!string,
        labels: ["size": sizeLabel],
        timed: &c.timed,
        after: &c.after,
        metrics: [Metric(Unit("B"), size, Metric.Mode.rate)]);
}


ubyte[32] blake3With(Blake3Backend backend, scope const(ubyte)[] input) @safe pure nothrow @nogc
{
    auto hasher = Blake3.withBackend(backend);
    hasher.put(input);
    return hasher.finish();
}

@("blake3.bench.throughput")
@benchmark @safe
unittest
{
    static foreach (name; concreteBackendNames)
    {{
        enum backend = __traits(getMember, Blake3Backend, name);
        if (isSupported(backend))
        {
            registerThroughput(backend, "1KiB", 1 << 10);
            registerThroughput(backend, "64KiB", 1 << 16);
            registerThroughput(backend, "1MiB", 1 << 20);
        }
    }}
}
