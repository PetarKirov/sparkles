/++
The memory interface every Sparkles WebAssembly module exports
(docs/specs/toolchain/wasm-modules.md, `TCM5`): a scratch buffer the host
writes input to and reads output from, and the grapheme segmentation both the
cell explorer and the table playground lay text out with.

Addresses are byte offsets into the module's exported `memory`. The exports
exist only in a WASI build; the functions they call are ordinary D, tested
natively like any other.
+/
module sparkles.base.wasm;

import sparkles.base.text.grapheme : byGraphemeCluster;

/// The scratch buffer's size in bytes: `TCM5` asks for at least 256 KiB.
enum size_t bufferCapacity = 256 * 1024;

/++
Writes one `(byteOffset, byteLength, cellWidth)` triple per grapheme cluster
or escape sequence of `text` into `triples`, three values per unit.

Returns: the number of units, or `-1` when they do not fit in
`triples.length / 3` slots; what was written is then undefined.
+/
int segmentInto(scope const(char)[] text, scope uint[] triples) @safe pure nothrow @nogc
{
    const slots = triples.length / 3;
    size_t n;
    uint offset;
    foreach (unit; text.byGraphemeCluster)
    {
        if (n == slots)
            return -1;
        const length = cast(uint) unit.slice.length;
        triples[n * 3] = offset;
        triples[n * 3 + 1] = length;
        triples[n * 3 + 2] = cast(uint) unit.width;
        offset += length;
        ++n;
    }
    return cast(int) n;
}

///
@("wasm.segmentInto.clustersAndEscapes")
@safe pure nothrow @nogc
unittest
{
    uint[12] triples;
    // A combining sequence, a wide character and an escape sequence.
    assert(segmentInto("é漢\x1b[1mx", triples[]) == 4);
    assert(triples == [0, 3, 1, 3, 3, 2, 6, 4, 0, 10, 1, 1]);
}

@("wasm.segmentInto.tooSmall")
@safe pure nothrow @nogc
unittest
{
    uint[6] triples;
    assert(segmentInto("abc", triples[]) == -1);
    assert(segmentInto("ab", triples[]) == 2);
    assert(segmentInto("", triples[0 .. 0]) == 0);
}

/++
Whether the host's input range `[inPtr, inPtr + inLen)` and output range
`[outPtr, outPtr + outLen)` both lie within `memoryBytes` and do not overlap
(`TCM5`). An empty range overlaps nothing.
+/
bool validRanges(ulong memoryBytes, uint inPtr, uint inLen, uint outPtr, uint outLen)
    @safe pure nothrow @nogc
{
    const inEnd = ulong(inPtr) + inLen, outEnd = ulong(outPtr) + outLen;
    if (inEnd > memoryBytes || outEnd > memoryBytes)
        return false;
    return inLen == 0 || outLen == 0 || inEnd <= outPtr || outEnd <= inPtr;
}

///
@("wasm.validRanges")
@safe pure nothrow @nogc
unittest
{
    enum memory = 65_536;
    assert(validRanges(memory, 0, 100, 100, 100));
    assert(validRanges(memory, 200, 100, 0, 200));
    assert(!validRanges(memory, 0, 101, 100, 100), "overlap");
    assert(!validRanges(memory, 150, 10, 100, 100), "input inside output");
    assert(!validRanges(memory, 0, 10, 65_530, 7), "past the end of memory");
    assert(!validRanges(memory, uint.max, 2, 0, 0), "a range that wraps");
    assert(validRanges(memory, 10, 0, 0, 100), "an empty range overlaps nothing");
}

version (WASI)
{
    private __gshared ubyte[bufferCapacity] buffer;

    /// The size of the module's linear memory, in bytes.
    ulong memoryBytes() @trusted nothrow @nogc
    {
        import ldc.intrinsics : llvm_wasm_memory_size;

        return ulong(llvm_wasm_memory_size(0)) * 65_536;
    }

    /// The `len` bytes at address `ptr` of the module's memory.
    T[] hostSlice(T)(uint ptr, uint len) @system nothrow @nogc
        => (cast(T*) cast(size_t) ptr)[0 .. len];

    /// Address of the scratch buffer (`TCM5`).
    extern (C) export uint spk_buf_ptr() @trusted nothrow @nogc
        => cast(uint) cast(size_t) buffer.ptr;

    /// Size of the scratch buffer, in bytes (`TCM5`).
    extern (C) export uint spk_buf_cap() @safe nothrow @nogc
        => cast(uint) buffer.length;

    /++
    Segments the `len` UTF-8 bytes at `ptr` into `outCap` triple slots at
    `outPtr` (`TCM5`; $(LREF segmentInto)). Returns `-1` also for ranges
    outside memory or overlapping each other.
    +/
    extern (C) export int spk_segment(uint ptr, uint len, uint outPtr, uint outCap)
        @system nothrow @nogc
    {
        if (outCap > uint.max / 12 || !validRanges(memoryBytes, ptr, len, outPtr, outCap * 12))
            return -1;
        return segmentInto(hostSlice!char(ptr, len), hostSlice!uint(outPtr, outCap * 3));
    }
}
