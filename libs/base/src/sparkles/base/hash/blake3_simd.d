/**
Internal SIMD kernels for `sparkles.base.hash.blake3` (LDC on x86_64 and
AArch64; other builds compile only the portable code).

Two shapes, after the C reference. `hashManyLanes` compresses `lanes` inputs
at once, one input per vector lane: each of the sixteen state words is a
vector holding that word of every input, with messages transposed on load and
chaining values on store. This is where large inputs spend their time.
`compressRows` compresses one block with the state's four rows as vectors,
for the chunk and parent compressions the tree cannot batch.

Both are written once over LLVM's generic vector type and instantiated per
target (`@target`); LLVM picks the instructions, including byte shuffles or
`vprord` for the rotations.
*/
module sparkles.base.hash.blake3_simd;

version (LDC)
{
    version (X86_64)
        version = blake3X86;
    else version (AArch64)
        version = blake3Neon;
}

version (blake3X86)
    version = blake3Simd;
else version (blake3Neon)
    version = blake3Simd;

version (blake3Simd):

import ldc.attributes : target;
import ldc.simd : loadUnaligned, storeUnaligned;

import sparkles.base.hash.blake3 : blake3Iv, blake3MessageSchedule;

package(sparkles.base.hash):

version (blake3X86)
{
    /// `@target` strings of the x86_64 backends. LLVM 18 splits 512-bit
    /// registers (`evex512`) from the AVX-512 instruction set.
    enum targetSse41 = "sse4.1";
    /// ditto
    enum targetAvx2 = "avx2";
    /// ditto
    enum targetAvx512 = "avx2,avx512f,avx512vl,evex512";
}
else version (blake3Neon)
{
    /// NEON is baseline on AArch64.
    enum targetNeon = "neon";
}

/**
Hashes `lanes` inputs of `blocks` blocks each, input `i` at
`input[i * blocks * 64 ..]`, into `lanes` chaining values in `output`.
Input `i` uses counter `counter + i` when `incrementCounter`, else `counter`.
*/
void hashManyLanes(size_t lanes, string tgt)(scope const(ubyte)[] input, size_t blocks,
    in uint[8] key, ulong counter, bool incrementCounter, ubyte flags,
    ubyte flagsStart, ubyte flagsEnd, scope ubyte[] output)
    @target(tgt)
in (blocks > 0 && input.length >= lanes * blocks * 64 && output.length >= lanes * 32)
{
    alias V = __vector(uint[lanes]);

    V[8] h;
    static foreach (i; 0 .. 8)
        h[i] = key[i];
    V counterLow, counterHigh;
    {
        uint[lanes] low, high;
        foreach (lane; 0 .. lanes)
        {
            const c = counter + (incrementCounter ? lane : 0);
            low[lane] = cast(uint) c;
            high[lane] = cast(uint) (c >> 32);
        }
        counterLow.array = low;
        counterHigh.array = high;
    }

    const stride = blocks * 64;
    uint blockFlags = flags | flagsStart;
    foreach (block; 0 .. blocks)
    {
        if (block + 1 == blocks)
            blockFlags |= flagsEnd;

        V[16] m = void;
        loadMessage!(lanes, tgt)(input, stride, block * 64, m);

        V[16] v = void;
        static foreach (i; 0 .. 8)
            v[i] = h[i];
        static foreach (i; 0 .. 4)
            v[8 + i] = blake3Iv[i];
        v[12] = counterLow;
        v[13] = counterHigh;
        v[14] = 64;
        v[15] = blockFlags;

        static foreach (r; 0 .. 7)
        {{
            enum s = blake3MessageSchedule[r];
            // Each half-step runs on all four columns (then diagonals) before
            // the next, as the C kernels do, so the four G functions overlap.
            roundHalf!(tgt, 0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15)(v,
                m[s[0]], m[s[1]], m[s[2]], m[s[3]], m[s[4]], m[s[5]], m[s[6]], m[s[7]]);
            roundHalf!(tgt, 0, 5, 10, 15, 1, 6, 11, 12, 2, 7, 8, 13, 3, 4, 9, 14)(v,
                m[s[8]], m[s[9]], m[s[10]], m[s[11]], m[s[12]], m[s[13]], m[s[14]], m[s[15]]);
        }}

        static foreach (i; 0 .. 8)
            h[i] = v[i] ^ v[i + 8];
        blockFlags = flags;
    }

    storeChainingValues!(lanes, tgt)(h, output);
}

/**
`hashMany` on one target: the widest kernel in `widths` while enough inputs
remain, then the narrower ones, then single inputs through `compressRows`.
*/
void hashManySimd(string tgt, widths...)(scope const(ubyte)[] input, size_t count,
    size_t blocks, in uint[8] key, ulong counter, bool incrementCounter, ubyte flags,
    ubyte flagsStart, ubyte flagsEnd, scope ubyte[] output)
{
    const stride = blocks * 64;
    static foreach (lanes; widths)
    {
        while (count >= lanes)
        {
            hashManyLanes!(lanes, tgt)(input, blocks, key, counter, incrementCounter,
                flags, flagsStart, flagsEnd, output);
            input = input[lanes * stride .. $];
            output = output[lanes * 32 .. $];
            if (incrementCounter)
                counter += lanes;
            count -= lanes;
        }
    }
    foreach (i; 0 .. count)
    {
        uint[8] cv = key;
        uint blockFlags = flags | flagsStart;
        foreach (block; 0 .. blocks)
        {
            if (block + 1 == blocks)
                blockFlags |= flagsEnd;
            compressRowsInPlace!tgt(cv, input[i * stride + block * 64 .. i * stride + block * 64 + 64],
                64, counter, cast(ubyte) blockFlags);
            blockFlags = flags;
        }
        foreach (w, word; cv)
            storeWord(output, i * 32 + w * 4, word);
        if (incrementCounter)
            counter += 1;
    }
}

/**
Compresses one block for the row layout (`compress_in_place`): the new
chaining value replaces `cv`.
*/
void compressRowsInPlace(string tgt)(ref uint[8] cv, scope const(ubyte)[] block,
    ubyte blockLength, ulong counter, ubyte flags)
    @target(tgt)
in (block.length == 64)
{
    alias V = __vector(uint[4]);
    V[4] rows;
    compressRows!tgt(rows, cv, block, blockLength, counter, flags);
    V low = rows[0] ^ rows[2];
    V high = rows[1] ^ rows[3];
    cv[0 .. 4] = low.array;
    cv[4 .. 8] = high.array;
}

/// Compresses one block into 64 bytes of extended output (`compress_xof`).
void compressRowsXof(string tgt)(in uint[8] cv, scope const(ubyte)[] block,
    ubyte blockLength, ulong counter, ubyte flags, ref ubyte[64] output)
    @target(tgt)
in (block.length == 64)
{
    alias V = __vector(uint[4]);
    V[4] rows;
    compressRows!tgt(rows, cv, block, blockLength, counter, flags);
    V cvLow, cvHigh;
    cvLow.array = cv[0 .. 4];
    cvHigh.array = cv[4 .. 8];
    const V[4] words = [rows[0] ^ rows[2], rows[1] ^ rows[3], rows[2] ^ cvLow, rows[3] ^ cvHigh];
    static foreach (i; 0 .. 4)
        storeVector!(V, tgt)(words[i], output[], i * 16);
}

private:

// One G function (BLAKE3 spec §2.2) on the lanes of four state vectors.
pragma(inline, true)
void g(string tgt, V)(ref V a, ref V b, ref V c, ref V d, ref const V x, ref const V y)
    @target(tgt)
{
    a = a + b + x;
    xorRotate!(16, tgt)(d, a);
    c = c + d;
    xorRotate!(12, tgt)(b, c);
    a = a + b + y;
    xorRotate!(8, tgt)(d, a);
    c = c + d;
    xorRotate!(7, tgt)(b, c);
}

// Four independent G functions on the state vectors `v`, interleaved step by
// step; the template arguments are each one's (a, b, c, d) state indices.
pragma(inline, true)
void roundHalf(string tgt, size_t a0, size_t b0, size_t c0, size_t d0,
    size_t a1, size_t b1, size_t c1, size_t d1,
    size_t a2, size_t b2, size_t c2, size_t d2,
    size_t a3, size_t b3, size_t c3, size_t d3, V)(ref V[16] v,
    ref const V x0, ref const V y0, ref const V x1, ref const V y1,
    ref const V x2, ref const V y2, ref const V x3, ref const V y3)
    @target(tgt)
{
    v[a0] = v[a0] + v[b0] + x0;
    v[a1] = v[a1] + v[b1] + x1;
    v[a2] = v[a2] + v[b2] + x2;
    v[a3] = v[a3] + v[b3] + x3;
    xorRotate!(16, tgt)(v[d0], v[a0]);
    xorRotate!(16, tgt)(v[d1], v[a1]);
    xorRotate!(16, tgt)(v[d2], v[a2]);
    xorRotate!(16, tgt)(v[d3], v[a3]);
    v[c0] = v[c0] + v[d0];
    v[c1] = v[c1] + v[d1];
    v[c2] = v[c2] + v[d2];
    v[c3] = v[c3] + v[d3];
    xorRotate!(12, tgt)(v[b0], v[c0]);
    xorRotate!(12, tgt)(v[b1], v[c1]);
    xorRotate!(12, tgt)(v[b2], v[c2]);
    xorRotate!(12, tgt)(v[b3], v[c3]);
    v[a0] = v[a0] + v[b0] + y0;
    v[a1] = v[a1] + v[b1] + y1;
    v[a2] = v[a2] + v[b2] + y2;
    v[a3] = v[a3] + v[b3] + y3;
    xorRotate!(8, tgt)(v[d0], v[a0]);
    xorRotate!(8, tgt)(v[d1], v[a1]);
    xorRotate!(8, tgt)(v[d2], v[a2]);
    xorRotate!(8, tgt)(v[d3], v[a3]);
    v[c0] = v[c0] + v[d0];
    v[c1] = v[c1] + v[d1];
    v[c2] = v[c2] + v[d2];
    v[c3] = v[c3] + v[d3];
    xorRotate!(7, tgt)(v[b0], v[c0]);
    xorRotate!(7, tgt)(v[b1], v[c1]);
    xorRotate!(7, tgt)(v[b2], v[c2]);
    xorRotate!(7, tgt)(v[b3], v[c3]);
}

// `x = (x ^ y) >>> n`. Vectors pass by reference: LDC cannot pass a 512-bit
// rvalue to a non-inlined callee (its baseline ABI wants an address).
// LLVM recognizes the shift pair as a funnel shift and lowers it to the
// target's best rotation: a byte shuffle for 16 and 8 (SSSE3/AVX2, NEON
// `rev32`/`tbl`), `vprord` with AVX-512 VL.
pragma(inline, true)
void xorRotate(uint n, string tgt, V)(ref V x, ref const V y) @target(tgt)
{
    const t = x ^ y;
    x = (t >> n) | (t << (32 - n));
}

// Bounded unaligned vector I/O. As in `sparkles.base.text.simd_io`, the
// vector crosses the `@trusted` lambda through memory, never as a return
// value, so the lambda's baseline ABI cannot disagree with its caller's.
pragma(inline, true)
V loadVector(V, string tgt)(scope const(ubyte)[] source, size_t offset) @target(tgt)
in (offset <= source.length && source.length - offset >= V.sizeof)
{
    V result = void;
    (() @trusted {
        result = loadUnaligned!V(cast(const(uint)*) (source.ptr + offset));
    })();
    return result;
}

pragma(inline, true)
void storeVector(V, string tgt)(V value, scope ubyte[] target_, size_t offset) @target(tgt)
in (offset <= target_.length && target_.length - offset >= V.sizeof)
{
    (() @trusted {
        storeUnaligned!V(value, cast(uint*) (target_.ptr + offset));
    })();
}

// Loads block `offset` of each lane's input and transposes it: `m[w]` holds
// message word `w` of every lane. Each lane's 64-byte block is
// `16 / lanes` vectors; each group of `lanes` such vectors is one square
// transpose.
pragma(inline, true)
void loadMessage(size_t lanes, string tgt, V)(scope const(ubyte)[] input, size_t stride,
    size_t offset, ref V[16] m)
    @target(tgt)
{
    static foreach (group; 0 .. 16 / lanes)
    {{
        V[lanes] rows = void;
        static foreach (lane; 0 .. lanes)
            rows[lane] = loadVector!(V, tgt)(input, lane * stride + offset + group * V.sizeof);
        transpose!(lanes, tgt)(rows);
        static foreach (w; 0 .. lanes)
            m[group * lanes + w] = rows[w];
    }}
}

// Writes lane `i`'s eight words of `h` to `output[i * 32 .. i * 32 + 32]`.
pragma(inline, true)
void storeChainingValues(size_t lanes, string tgt, V)(ref V[8] h, scope ubyte[] output)
    @target(tgt)
{
    static if (lanes == 4 || lanes == 8)
    {
        // Square transposes: four words per 4-lane row (two halves), or all
        // eight per 8-lane row.
        static foreach (half; 0 .. 8 / lanes)
        {{
            V[lanes] rows = h[half * lanes .. half * lanes + lanes];
            transpose!(lanes, tgt)(rows);
            static foreach (lane; 0 .. lanes)
                storeVector!(V, tgt)(rows[lane], output, lane * 32 + half * V.sizeof);
        }}
    }
    else
    {
        // Sixteen lanes of eight words: pad to a square with zero rows and
        // write the first half of each transposed row.
        V[lanes] rows = 0;
        rows[0 .. 8] = h;
        transpose!(lanes, tgt)(rows);
        static foreach (lane; 0 .. lanes)
        {{
            ubyte[V.sizeof] row = void;
            storeVector!(V, tgt)(rows[lane], row[], 0);
            output[lane * 32 .. lane * 32 + 32] = row[0 .. 32];
        }}
    }
}

pragma(inline, true)
void storeWord(scope ubyte[] output, size_t offset, uint word) @safe pure nothrow @nogc
{
    output[offset] = cast(ubyte) word;
    output[offset + 1] = cast(ubyte) (word >> 8);
    output[offset + 2] = cast(ubyte) (word >> 16);
    output[offset + 3] = cast(ubyte) (word >> 24);
}

// Transposes a square matrix of `n` rows of `n` lanes in place by block
// swaps: at width `b` (1, 2, 4, …), every `b`×`b` block above the diagonal
// of a `2b`-aligned block trades places with its mirror below. Each swap of
// two rows is two two-source shuffles.
pragma(inline, true)
void transpose(size_t n, string tgt, V)(ref V[n] rows) @target(tgt)
{
    static foreach (shift; 0 .. log2(n))
    {{
        enum b = size_t(1) << shift;
        static foreach (i; 0 .. n)
        {
            static if ((i & b) == 0)
            {{
                const low = shuffle!(swapMask(n, b, false), tgt)(rows[i], rows[i + b]);
                const high = shuffle!(swapMask(n, b, true), tgt)(rows[i], rows[i + b]);
                rows[i] = low;
                rows[i + b] = high;
            }}
        }
    }}
}

// Lane `j` of the upper row keeps its own element where bit `b` of `j` is
// clear and takes the lower row's `j - b` otherwise; the lower row mirrors.
int[] swapMask(size_t n, size_t b, bool high) @safe pure nothrow
{
    int[] mask = new int[](n);
    foreach (j; 0 .. n)
    {
        const inUpperBlock = (j & b) == 0;
        if (high)
            mask[j] = cast(int) (inUpperBlock ? j + b : n + j);
        else
            mask[j] = cast(int) (inUpperBlock ? j : n + j - b);
    }
    return mask;
}

size_t log2(size_t n) @safe pure nothrow @nogc
{
    size_t result;
    while ((size_t(1) << result) < n)
        result += 1;
    return result;
}

// The row-layout compression: rows 0..3 of the 4×4 state as vectors. The
// diagonal step rotates rows 1..3 so the diagonals line up as columns. Each
// round's message vectors gather their words from the four loaded message
// vectors with constant shuffles.
pragma(inline, true)
void compressRows(string tgt, V)(ref V[4] rows, in uint[8] cv, scope const(ubyte)[] block,
    ubyte blockLength, ulong counter, ubyte flags)
    @target(tgt)
{
    rows[0].array = cv[0 .. 4];
    rows[1].array = cv[4 .. 8];
    rows[2].array = blake3Iv[0 .. 4];
    const uint[4] tail = [cast(uint) counter, cast(uint) (counter >> 32), blockLength, flags];
    rows[3].array = tail;

    V[4] m;
    static foreach (i; 0 .. 4)
        m[i] = loadVector!(V, tgt)(block, i * 16);

    static foreach (r; 0 .. 7)
    {{
        enum s = blake3MessageSchedule[r];
        const x0 = gather!(tgt, s[0], s[2], s[4], s[6])(m);
        const y0 = gather!(tgt, s[1], s[3], s[5], s[7])(m);
        g!tgt(rows[0], rows[1], rows[2], rows[3], x0, y0);
        rows[1] = shuffle!([1, 2, 3, 0], tgt)(rows[1], rows[1]);
        rows[2] = shuffle!([2, 3, 0, 1], tgt)(rows[2], rows[2]);
        rows[3] = shuffle!([3, 0, 1, 2], tgt)(rows[3], rows[3]);
        const x1 = gather!(tgt, s[8], s[10], s[12], s[14])(m);
        const y1 = gather!(tgt, s[9], s[11], s[13], s[15])(m);
        g!tgt(rows[0], rows[1], rows[2], rows[3], x1, y1);
        rows[1] = shuffle!([3, 0, 1, 2], tgt)(rows[1], rows[1]);
        rows[2] = shuffle!([2, 3, 0, 1], tgt)(rows[2], rows[2]);
        rows[3] = shuffle!([1, 2, 3, 0], tgt)(rows[3], rows[3]);
    }}
}

// Message words `w0..w3` (each 0..15) as one vector, from the four vectors
// holding words 0..3, 4..7, 8..11 and 12..15. LLVM folds the lane moves
// into shuffles.
pragma(inline, true)
V gather(string tgt, size_t w0, size_t w1, size_t w2, size_t w3, V)(ref const V[4] m)
    @target(tgt)
{
    V result = void;
    static foreach (lane, w; [w0, w1, w2, w3])
        result[lane] = m[w / 4][w % 4];
    return result;
}

// A two-source shuffle: lane `i` of the result is lane `mask[i]` of `a ~ b`.
// `ldc.simd.shufflevector` is inline IR that LDC re-parses at each call, at a
// cost that grows with the module (seconds per kernel when `sparkles:base`
// compiles as one unit for `dub test`). Calling it from this one wrapper per
// mask parses each mask once; the wrapper itself always inlines.
pragma(inline, true)
V shuffle(int[] mask, string tgt, V)(ref const V a, ref const V b) @target(tgt)
{
    import ldc.simd : shufflevector;
    import std.meta : aliasSeqOf;

    return shufflevector!(V, aliasSeqOf!mask)(a, b);
}
