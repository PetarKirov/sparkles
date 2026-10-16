/**
BLAKE3: a fast cryptographic hash with keyed, key-derivation and
extendable-output modes, after the
$(LINK2 https://github.com/BLAKE3-team/BLAKE3-specs/blob/ea51a3ac997288bf690ee82ac9cfc8b3e0e60f2a/blake3.pdf, BLAKE3 specification).

The one-shot functions ($(LREF blake3), $(LREF blake3Keyed),
$(LREF blake3DeriveKey)) cover whole inputs; the $(LREF Blake3) hasher is an
output range for streamed input and produces any number of output bytes.
Nothing allocates: the hasher's chaining-value stack is a fixed array sized
for the largest input BLAKE3 defines (2$(SUPERSCRIPT 64) bytes).

The tree layout follows the official C implementation: whole subtrees are
hashed several chunks at a time, so a backend that compresses many chunks in
parallel speeds up large inputs without changing a byte of the output.

$(LREF Blake3Backend) names the implementations: the portable one compiled
everywhere, and the SIMD ones a build provides (LDC on x86_64 and AArch64).
*/
module sparkles.base.hash.blake3;

import core.bitop : bsr, popcnt, ror;

@safe pure nothrow @nogc:

/// Bytes in a default BLAKE3 digest.
enum size_t blake3OutLength = 32;
/// Bytes in a keyed-mode key.
enum size_t blake3KeyLength = 32;
/// Bytes in one compression block.
enum size_t blake3BlockLength = 64;
/// Bytes in one chunk, the leaf of the hash tree.
enum size_t blake3ChunkLength = 1024;

/// Domain-separation flags (BLAKE3 spec §2.1).
package(sparkles.base.hash) enum : ubyte
{
    chunkStart = 1 << 0,
    chunkEnd = 1 << 1,
    parentFlag = 1 << 2,
    rootFlag = 1 << 3,
    keyedHashFlag = 1 << 4,
    deriveKeyContextFlag = 1 << 5,
    deriveKeyMaterialFlag = 1 << 6,
}

/// The initialization vector, shared with SHA-256.
package(sparkles.base.hash) static immutable uint[8] blake3Iv = [
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];

/// The message word order of each of the seven rounds: the identity, then
/// the spec's fixed permutation applied once more per round.
package(sparkles.base.hash) enum ubyte[16][7] blake3MessageSchedule = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8],
    [3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1],
    [10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6],
    [12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4],
    [9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7],
    [11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13],
];

// Depth of a tree over 2^64 bytes of 1 KiB chunks.
private enum size_t maxDepth = 54;
// The widest backend hashes 16 chunks at once; the tree code never splits
// into fewer than two subtrees.
private enum size_t maxSimdDegree = 16;

/**
A BLAKE3 implementation. Every backend produces identical output; they
differ only in speed and in where they can run.
*/
enum Blake3Backend : ubyte
{
    /// The fastest backend this CPU supports, chosen on each call.
    automatic,
    /// Plain D, one block at a time. Always available, and the only backend
    /// in CTFE and DMD builds.
    portable,
}

/**
The fastest backend this build and CPU support. `pure`: the CPU's features
are fixed for the life of the process, read from immutable data initialized
at startup; in CTFE it is always `portable`.
*/
Blake3Backend bestBlake3Backend()
{
    if (__ctfe)
        return Blake3Backend.portable;
    return Blake3Backend.portable;
}

/// Whether `backend` can run in this build on this CPU. `automatic` and
/// `portable` always can.
bool isSupported(Blake3Backend backend)
{
    final switch (backend)
    {
        case Blake3Backend.automatic:
        case Blake3Backend.portable:
            return true;
    }
}

///
@("blake3.isSupported.portable")
@safe pure nothrow @nogc
unittest
{
    assert(isSupported(Blake3Backend.portable));
    assert(isSupported(bestBlake3Backend));
}

/// The digest of `input`: BLAKE3's default 32-byte output.
ubyte[32] blake3(scope const(ubyte)[] input)
{
    Blake3 hasher;
    hasher.put(input);
    return hasher.finish();
}

/// ditto
ubyte[32] blake3(scope const(char)[] input) => blake3(cast(const(ubyte)[]) input);

///
@("blake3.blake3.oneShot")
@safe pure nothrow @nogc
unittest
{
    const digest = blake3("abc");
    assert(digest[0 .. 4] == [0x64, 0x37, 0xb3, 0xac]);
}

/// The keyed-mode digest of `input`: a MAC or PRF under the 32-byte `key`.
ubyte[32] blake3Keyed(in ubyte[32] key, scope const(ubyte)[] input)
{
    auto hasher = Blake3.keyed(key);
    hasher.put(input);
    return hasher.finish();
}

/// ditto
ubyte[32] blake3Keyed(in ubyte[32] key, scope const(char)[] input) =>
    blake3Keyed(key, cast(const(ubyte)[]) input);

///
@("blake3.blake3Keyed.differsFromPlain")
@safe pure nothrow @nogc
unittest
{
    ubyte[32] key = 7;
    assert(blake3Keyed(key, "message") != blake3("message"));
    assert(blake3Keyed(key, "message") == blake3Keyed(key, "message"));
}

/**
A 32-byte key derived from `keyMaterial` for the application-specific
`context`. The context should be a hardcoded, globally unique string such
as `"example.com 2026-10-16 session tokens v1"`, never a secret or a
per-call value.
*/
ubyte[32] blake3DeriveKey(scope const(char)[] context, scope const(ubyte)[] keyMaterial)
{
    auto hasher = Blake3.deriveKey(context);
    hasher.put(keyMaterial);
    return hasher.finish();
}

///
@("blake3.blake3DeriveKey.contextSeparates")
@safe pure nothrow @nogc
unittest
{
    static immutable ubyte[4] secret = [1, 2, 3, 4];
    assert(blake3DeriveKey("app 2026 a", secret) != blake3DeriveKey("app 2026 b", secret));
}

/**
A streaming BLAKE3 hasher: an output range of `ubyte` and byte or `char`
slices. `Blake3.init` hashes in the default mode; $(LREF Blake3.keyed) and
$(LREF Blake3.deriveKey) start the other two.

$(LREF Blake3.finish) and $(LREF Blake3.finishXof) do not consume the state,
so more input may follow and a later `finish` covers all of it. The type
also satisfies `std.digest.isDigest`.
*/
struct Blake3
{
@safe pure nothrow @nogc:
    private uint[8] key_ = blake3Iv;
    private ChunkState chunk_;
    private ubyte cvStackLength_;
    private Blake3Backend backend_;
    // The lazily merged chaining-value stack holds one entry more than the
    // tree's depth (C reference, `BLAKE3_MAX_DEPTH + 1`).
    private ubyte[32][maxDepth + 1] cvStack_;

    /// A default-mode hasher on a chosen backend, which must be supported.
    static Blake3 withBackend(Blake3Backend backend)
    in (isSupported(backend))
    {
        Blake3 hasher;
        hasher.backend_ = backend;
        return hasher;
    }

    /// A keyed-mode hasher: a MAC or PRF under the 32-byte `key`.
    static Blake3 keyed(in ubyte[32] key, Blake3Backend backend = Blake3Backend.automatic)
    in (isSupported(backend))
    {
        uint[8] words;
        loadWords(key[], words);
        return Blake3(words, keyedHashFlag, backend);
    }

    /**
    A key-derivation hasher: the input that follows is the key material, the
    output the derived key. See $(LREF blake3DeriveKey) about `context`.
    */
    static Blake3 deriveKey(scope const(char)[] context,
        Blake3Backend backend = Blake3Backend.automatic)
    in (isSupported(backend))
    {
        auto contextHasher = Blake3(blake3Iv, deriveKeyContextFlag, backend);
        contextHasher.put(context);
        const contextKey = contextHasher.finish();
        uint[8] words;
        loadWords(contextKey[], words);
        return Blake3(words, deriveKeyMaterialFlag, backend);
    }

    private this(in uint[8] key, ubyte flags, Blake3Backend backend)
    {
        key_ = key;
        chunk_ = ChunkState(key, 0, flags);
        backend_ = backend;
    }

    /// The backend this hasher was given (`automatic` unless chosen).
    Blake3Backend backend() const => backend_;

    /// Forgets all input, keeping the mode and key.
    void reset()
    {
        chunk_ = ChunkState(key_, 0, chunk_.flags);
        cvStackLength_ = 0;
    }

    /// `std.digest` spelling of $(LREF reset).
    void start() => reset();

    /// Absorbs `input`: a slice, or bytes listed one by one.
    void put(scope const(ubyte)[] input...)
    {
        if (input.length == 0)
            return;
        const backend = resolve(backend_);

        // Complete a partially filled chunk first.
        if (chunk_.length > 0)
        {
            const take = min(blake3ChunkLength - chunk_.length, input.length);
            chunk_.update(backend, input[0 .. take]);
            input = input[take .. $];
            if (input.length == 0)
                return;
            ubyte[32] cv = chunk_.output.chainingValue(backend);
            pushCv(backend, cv, chunk_.chunkCounter);
            chunk_ = ChunkState(key_, chunk_.chunkCounter + 1, chunk_.flags);
        }

        // Hash whole subtrees at once while more than one chunk remains: each
        // is the largest power-of-two run of chunks that both fits in the
        // input and starts on a boundary of its own size.
        while (input.length > blake3ChunkLength)
        {
            ulong subtreeLength = roundDownToPowerOf2(input.length);
            const countSoFar = chunk_.chunkCounter * blake3ChunkLength;
            while (((subtreeLength - 1) & countSoFar) != 0)
                subtreeLength /= 2;
            const subtreeChunks = subtreeLength / blake3ChunkLength;
            const subtree = input[0 .. cast(size_t) subtreeLength];
            if (subtreeLength <= blake3ChunkLength)
            {
                auto state = ChunkState(key_, chunk_.chunkCounter, chunk_.flags);
                state.update(backend, subtree);
                ubyte[32] cv = state.output.chainingValue(backend);
                pushCv(backend, cv, state.chunkCounter);
            }
            else
            {
                ubyte[64] pair;
                compressSubtreeToParentNode(backend, subtree, key_,
                    chunk_.chunkCounter, chunk_.flags, pair);
                pushCv(backend, pair[0 .. 32], chunk_.chunkCounter);
                pushCv(backend, pair[32 .. 64], chunk_.chunkCounter + subtreeChunks / 2);
            }
            chunk_.chunkCounter += subtreeChunks;
            input = input[cast(size_t) subtreeLength .. $];
        }

        // At most one chunk remains: buffer it, and merge every subtree the
        // chunk count now completes. The last chunk is never merged here, as
        // only `finish` knows whether it is the root.
        if (input.length > 0)
        {
            chunk_.update(backend, input);
            mergeCvStack(backend, chunk_.chunkCounter);
        }
    }

    /// ditto
    void put(scope const(char)[] input) => put(cast(const(ubyte)[]) input);

    /// The default 32-byte digest of everything put so far.
    ubyte[32] finish() const
    {
        ubyte[32] digest;
        finishXof(digest[]);
        return digest;
    }

    /**
    Fills `output` with the extended output starting at byte `seek`. Its
    first 32 bytes from `seek` 0 are the digest; any prefix of a longer
    output equals the shorter output.
    */
    void finishXof(scope ubyte[] output, ulong seek = 0) const
    {
        if (output.length == 0)
            return;
        const backend = resolve(backend_);
        rootOutput(backend).rootBytes(backend, seek, output);
    }

    private Output rootOutput(Blake3Backend backend) const
    {
        if (cvStackLength_ == 0)
            return chunk_.output;

        // With a partial chunk, it is the right child of the stack's last
        // entry; with none, the stack's top two entries are the last parent.
        Output output;
        size_t remaining;
        if (chunk_.length > 0)
        {
            remaining = cvStackLength_;
            output = chunk_.output;
        }
        else
        {
            remaining = cvStackLength_ - 2;
            ubyte[64] block;
            block[0 .. 32] = cvStack_[remaining];
            block[32 .. 64] = cvStack_[remaining + 1];
            output = parentOutput(block, key_, chunk_.flags);
        }
        while (remaining > 0)
        {
            remaining -= 1;
            ubyte[64] block;
            block[0 .. 32] = cvStack_[remaining];
            block[32 .. 64] = output.chainingValue(backend);
            output = parentOutput(block, key_, chunk_.flags);
        }
        return output;
    }

    // Merges completed subtrees: after `totalChunks` chunks the stack holds
    // one entry per set bit of the count (the spec's lazy-merge invariant).
    private void mergeCvStack(Blake3Backend backend, ulong totalChunks)
    {
        const postMergeLength = popcnt(totalChunks);
        while (cvStackLength_ > postMergeLength)
        {
            ubyte[64] block;
            block[0 .. 32] = cvStack_[cvStackLength_ - 2];
            block[32 .. 64] = cvStack_[cvStackLength_ - 1];
            cvStack_[cvStackLength_ - 2] =
                parentOutput(block, key_, chunk_.flags).chainingValue(backend);
            cvStackLength_ -= 1;
        }
    }

    private void pushCv(Blake3Backend backend, scope const(ubyte)[] cv, ulong chunkCounter)
    in (cv.length == 32)
    {
        mergeCvStack(backend, chunkCounter);
        cvStack_[cvStackLength_] = cv[0 .. 32];
        cvStackLength_ += 1;
    }
}

///
@("blake3.Blake3.streaming")
@safe pure nothrow @nogc
unittest
{
    Blake3 hasher;
    hasher.put("hello, ");
    hasher.put("world");
    assert(hasher.finish() == blake3("hello, world"));

    // An extended output starts with the digest.
    ubyte[100] longer;
    hasher.finishXof(longer[]);
    assert(longer[0 .. 32] == hasher.finish());

    // Seeking reads the same stream from an offset.
    ubyte[10] tail;
    hasher.finishXof(tail[], seek: 90);
    assert(tail == longer[90 .. 100]);
}

///
@("blake3.Blake3.outputRange")
@safe pure nothrow @nogc
unittest
{
    import std.range.primitives : isOutputRange, put;

    static assert(isOutputRange!(Blake3, ubyte));
    static assert(isOutputRange!(Blake3, const(ubyte)[]));
    Blake3 hasher;
    put(hasher, cast(ubyte) 'a');
    put(hasher, "bc");
    assert(hasher.finish() == blake3("abc"));
}

///
@("blake3.Blake3.isDigest")
@safe unittest
{
    import std.digest : digest, isDigest;

    static assert(isDigest!Blake3);
    assert(digest!Blake3("abc") == blake3("abc"));
}

///
@("blake3.Blake3.keyedAndDeriveKey")
@safe pure nothrow @nogc
unittest
{
    ubyte[32] key = 42;
    auto mac = Blake3.keyed(key);
    mac.put("message");
    assert(mac.finish() == blake3Keyed(key, "message"));

    auto kdf = Blake3.deriveKey("sparkles 2026-10-16 example");
    kdf.put("input key material");
    assert(kdf.finish() == blake3DeriveKey("sparkles 2026-10-16 example",
        cast(const(ubyte)[]) "input key material"));
}

///
@("blake3.blake3.ctfe")
@safe pure nothrow @nogc
unittest
{
    enum digest = blake3("abc");
    static assert(digest == blake3("abc"));
    static assert(digest[0 .. 4] == [0x64, 0x37, 0xb3, 0xac]);
}

// ---------------------------------------------------------------------------
// Tree internals (the C reference's blake3.c).
// ---------------------------------------------------------------------------

private Blake3Backend resolve(Blake3Backend backend) =>
    backend == Blake3Backend.automatic ? bestBlake3Backend : backend;

// The number of inputs a backend's `hashMany` compresses in parallel.
private size_t simdDegree(Blake3Backend backend)
{
    final switch (backend)
    {
        case Blake3Backend.automatic:
            return simdDegree(resolve(backend));
        case Blake3Backend.portable:
            return 1;
    }
}

private size_t min(size_t a, size_t b) => a < b ? a : b;

private ulong roundDownToPowerOf2(ulong x) => 1UL << bsr(x | 1);

private void loadWords(scope const(ubyte)[] bytes, ref uint[8] words)
in (bytes.length == 32)
{
    foreach (i, ref word; words)
        word = load32(bytes, i * 4);
}

private uint load32(scope const(ubyte)[] bytes, size_t offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16)
    | (bytes[offset + 3] << 24);

private void store32(scope ubyte[] bytes, size_t offset, uint word)
{
    bytes[offset] = cast(ubyte) word;
    bytes[offset + 1] = cast(ubyte) (word >> 8);
    bytes[offset + 2] = cast(ubyte) (word >> 16);
    bytes[offset + 3] = cast(ubyte) (word >> 24);
}

private void storeWords(in uint[8] words, scope ubyte[] bytes)
in (bytes.length >= 32)
{
    foreach (i, word; words)
        store32(bytes, i * 4, word);
}

// The inputs of one compression whose result is not yet decided: a chunk's
// last block or a parent node, compressed either for a chaining value or,
// with ROOT, for output bytes.
private struct Output
{
@safe pure nothrow @nogc:
    uint[8] inputCv;
    ulong counter;
    ubyte[64] block;
    ubyte blockLength;
    ubyte flags;

    ubyte[32] chainingValue(Blake3Backend backend) const
    {
        uint[8] cv = inputCv;
        compressInPlace(backend, cv, block, blockLength, counter, flags);
        ubyte[32] bytes;
        storeWords(cv, bytes[]);
        return bytes;
    }

    void rootBytes(Blake3Backend backend, ulong seek, scope ubyte[] output) const
    {
        ulong blockCounter = seek / 64;
        size_t offset = cast(size_t) (seek % 64);
        ubyte[64] wide;
        while (output.length > 0)
        {
            compressXof(backend, inputCv, block, blockLength, blockCounter,
                cast(ubyte) (flags | rootFlag), wide);
            const take = min(64 - offset, output.length);
            output[0 .. take] = wide[offset .. offset + take];
            output = output[take .. $];
            offset = 0;
            blockCounter += 1;
        }
    }
}

private Output parentOutput(in ubyte[64] block, in uint[8] key, ubyte flags) =>
    Output(key, 0, block, 64, cast(ubyte) (flags | parentFlag));

private struct ChunkState
{
@safe pure nothrow @nogc:
    uint[8] cv = blake3Iv;
    ulong chunkCounter;
    ubyte[64] buffer;
    ubyte bufferLength;
    ubyte blocksCompressed;
    ubyte flags;

    this(in uint[8] key, ulong chunkCounter, ubyte flags)
    {
        cv = key;
        this.chunkCounter = chunkCounter;
        this.flags = flags;
    }

    size_t length() const => 64 * size_t(blocksCompressed) + bufferLength;

    ubyte startFlag() const => blocksCompressed == 0 ? chunkStart : 0;

    size_t fillBuffer(scope const(ubyte)[] input)
    {
        const take = min(64 - bufferLength, input.length);
        buffer[bufferLength .. bufferLength + take] = input[0 .. take];
        bufferLength += cast(ubyte) take;
        return take;
    }

    // Compresses every full block that is not the chunk's last; the last
    // stays buffered, as only the output decides its flags.
    void update(Blake3Backend backend, scope const(ubyte)[] input)
    {
        if (bufferLength > 0)
        {
            input = input[fillBuffer(input) .. $];
            if (input.length > 0)
            {
                compressInPlace(backend, cv, buffer, 64, chunkCounter,
                    cast(ubyte) (flags | startFlag));
                blocksCompressed += 1;
                bufferLength = 0;
                buffer[] = 0;
            }
        }
        while (input.length > 64)
        {
            compressInPlace(backend, cv, input[0 .. 64], 64, chunkCounter,
                cast(ubyte) (flags | startFlag));
            blocksCompressed += 1;
            input = input[64 .. $];
        }
        fillBuffer(input);
    }

    Output output() const =>
        Output(cv, chunkCounter, buffer, bufferLength,
            cast(ubyte) (flags | startFlag | chunkEnd));
}

// Hashes the whole chunks of `input` (at most `simdDegree` of them, plus a
// partial last chunk) into consecutive chaining values; returns their count.
private size_t compressChunksParallel(Blake3Backend backend, scope const(ubyte)[] input,
    in uint[8] key, ulong chunkCounter, ubyte flags, scope ubyte[] output)
in (input.length > 0 && input.length <= maxSimdDegree * blake3ChunkLength)
{
    const chunks = input.length / blake3ChunkLength;
    hashMany(backend, input, chunks, blake3ChunkLength / 64, key, chunkCounter,
        true, flags, chunkStart, chunkEnd, output);
    if (input.length == chunks * blake3ChunkLength)
        return chunks;
    auto state = ChunkState(key, chunkCounter + chunks, flags);
    state.update(backend, input[chunks * blake3ChunkLength .. $]);
    output[chunks * 32 .. chunks * 32 + 32] = state.output.chainingValue(backend);
    return chunks + 1;
}

// Hashes pairs of chaining values into parents; an odd last one passes
// through. Returns the number of chaining values written.
private size_t compressParentsParallel(Blake3Backend backend, scope const(ubyte)[] childCvs,
    size_t count, in uint[8] key, ubyte flags, scope ubyte[] output)
in (count >= 2 && count <= 2 * maxSimdDegree)
{
    const parents = count / 2;
    hashMany(backend, childCvs, parents, 1, key, 0, false,
        cast(ubyte) (flags | parentFlag), 0, 0, output);
    if (count == 2 * parents)
        return parents;
    output[parents * 32 .. parents * 32 + 32] = childCvs[2 * parents * 32 .. 2 * parents * 32 + 32];
    return parents + 1;
}

// Reduces a subtree to at most `max(simdDegree, 2)` chaining values, so the
// parents of each level are hashed in parallel too. Recursion depth is
// logarithmic in the input length.
private size_t compressSubtreeWide(Blake3Backend backend, scope const(ubyte)[] input,
    in uint[8] key, ulong chunkCounter, ubyte flags, scope ubyte[] output)
{
    if (input.length <= simdDegree(backend) * blake3ChunkLength)
        return compressChunksParallel(backend, input, key, chunkCounter, flags, output);

    // The left subtree is the largest power-of-two number of whole chunks
    // that leaves at least one byte for the right.
    const leftLength = cast(size_t) roundDownToPowerOf2((input.length - 1) / blake3ChunkLength)
        * blake3ChunkLength;
    const rightChunkCounter = chunkCounter + leftLength / blake3ChunkLength;

    ubyte[2 * maxSimdDegree * 32] cvArray;
    size_t degree = simdDegree(backend);
    // A degree-1 left subtree of more than one chunk still yields two.
    if (leftLength > blake3ChunkLength && degree == 1)
        degree = 2;
    const leftCount = compressSubtreeWide(backend, input[0 .. leftLength], key,
        chunkCounter, flags, cvArray[]);
    const rightCount = compressSubtreeWide(backend, input[leftLength .. $], key,
        rightChunkCounter, flags, cvArray[degree * 32 .. $]);

    // A single left value means a two-chunk subtree: return both children
    // rather than their parent, which may turn out to be the root.
    if (leftCount == 1)
    {
        output[0 .. 64] = cvArray[0 .. 64];
        return 2;
    }
    return compressParentsParallel(backend, cvArray[], leftCount + rightCount, key, flags, output);
}

// Hashes a subtree of more than one chunk down to its root's two children.
private void compressSubtreeToParentNode(Blake3Backend backend, scope const(ubyte)[] input,
    in uint[8] key, ulong chunkCounter, ubyte flags, ref ubyte[64] output)
in (input.length > blake3ChunkLength)
{
    ubyte[maxSimdDegree * 32] cvArray;
    size_t count = compressSubtreeWide(backend, input, key, chunkCounter, flags, cvArray[]);
    ubyte[maxSimdDegree * 32 / 2] parents;
    while (count > 2)
    {
        count = compressParentsParallel(backend, cvArray[], count, key, flags, parents[]);
        cvArray[0 .. count * 32] = parents[0 .. count * 32];
    }
    output = cvArray[0 .. 64];
}

// ---------------------------------------------------------------------------
// Backend dispatch and the portable compression function.
// ---------------------------------------------------------------------------

package(sparkles.base.hash) void compressInPlace(Blake3Backend backend, ref uint[8] cv,
    scope const(ubyte)[] block, ubyte blockLength, ulong counter, ubyte flags)
in (block.length == 64)
{
    compressPortable(cv, block, blockLength, counter, flags);
}

package(sparkles.base.hash) void compressXof(Blake3Backend backend, in uint[8] cv,
    scope const(ubyte)[] block, ubyte blockLength, ulong counter, ubyte flags,
    ref ubyte[64] output)
in (block.length == 64)
{
    uint[16] state;
    compressPre(state, cv, block, blockLength, counter, flags);
    static foreach (i; 0 .. 8)
    {
        store32(output[], i * 4, state[i] ^ state[i + 8]);
        store32(output[], 32 + i * 4, state[i + 8] ^ cv[i]);
    }
}

// Hashes `count` inputs of `blocks` blocks each, laid out back to back in
// `input`, into `count` chaining values in `output`. Input `i` uses counter
// `counter + i` when `incrementCounter` (chunks), else `counter` (parents).
package(sparkles.base.hash) void hashMany(Blake3Backend backend, scope const(ubyte)[] input,
    size_t count, size_t blocks, in uint[8] key, ulong counter, bool incrementCounter,
    ubyte flags, ubyte flagsStart, ubyte flagsEnd, scope ubyte[] output)
in (input.length >= count * blocks * 64 && output.length >= count * 32)
{
    hashManyPortable(input, count, blocks, key, counter, incrementCounter,
        flags, flagsStart, flagsEnd, output);
}

package(sparkles.base.hash) void hashManyPortable(scope const(ubyte)[] input,
    size_t count, size_t blocks, in uint[8] key, ulong counter, bool incrementCounter,
    ubyte flags, ubyte flagsStart, ubyte flagsEnd, scope ubyte[] output)
{
    const stride = blocks * 64;
    foreach (i; 0 .. count)
    {
        uint[8] cv = key;
        uint blockFlags = flags | flagsStart;
        foreach (b; 0 .. blocks)
        {
            if (b + 1 == blocks)
                blockFlags |= flagsEnd;
            const offset = i * stride + b * 64;
            compressPortable(cv, input[offset .. offset + 64], 64, counter, cast(ubyte) blockFlags);
            blockFlags = flags;
        }
        storeWords(cv, output[i * 32 .. i * 32 + 32]);
        if (incrementCounter)
            counter += 1;
    }
}

package(sparkles.base.hash) void compressPortable(ref uint[8] cv,
    scope const(ubyte)[] block, ubyte blockLength, ulong counter, ubyte flags)
{
    uint[16] state;
    compressPre(state, cv, block, blockLength, counter, flags);
    static foreach (i; 0 .. 8)
        cv[i] = state[i] ^ state[i + 8];
}

private void compressPre(ref uint[16] state, in uint[8] cv, scope const(ubyte)[] block,
    ubyte blockLength, ulong counter, ubyte flags)
in (block.length == 64)
{
    const ubyte[64] bytes = block[0 .. 64];
    uint[16] m;
    static foreach (i; 0 .. 16)
        m[i] = bytes[4 * i] | (bytes[4 * i + 1] << 8) | (bytes[4 * i + 2] << 16)
            | (bytes[4 * i + 3] << 24);
    state[0 .. 8] = cv;
    state[8 .. 12] = blake3Iv[0 .. 4];
    state[12] = cast(uint) counter;
    state[13] = cast(uint) (counter >> 32);
    state[14] = blockLength;
    state[15] = flags;
    static foreach (r; 0 .. 7)
    {{
        enum s = blake3MessageSchedule[r];
        // Columns, then diagonals.
        g!(0, 4, 8, 12)(state, m[s[0]], m[s[1]]);
        g!(1, 5, 9, 13)(state, m[s[2]], m[s[3]]);
        g!(2, 6, 10, 14)(state, m[s[4]], m[s[5]]);
        g!(3, 7, 11, 15)(state, m[s[6]], m[s[7]]);
        g!(0, 5, 10, 15)(state, m[s[8]], m[s[9]]);
        g!(1, 6, 11, 12)(state, m[s[10]], m[s[11]]);
        g!(2, 7, 8, 13)(state, m[s[12]], m[s[13]]);
        g!(3, 4, 9, 14)(state, m[s[14]], m[s[15]]);
    }}
}

pragma(inline, true)
private void g(size_t a, size_t b, size_t c, size_t d)(ref uint[16] s, uint x, uint y)
{
    s[a] = s[a] + s[b] + x;
    s[d] = ror(s[d] ^ s[a], 16);
    s[c] = s[c] + s[d];
    s[b] = ror(s[b] ^ s[c], 12);
    s[a] = s[a] + s[b] + y;
    s[d] = ror(s[d] ^ s[a], 8);
    s[c] = s[c] + s[d];
    s[b] = ror(s[b] ^ s[c], 7);
}
