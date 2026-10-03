/**
Internal bounded AVX-512 UTF conversion emission after transactional preflight.

The byte-position/compaction approach follows the algorithm family described
by Clausecker and Lemire, https://arxiv.org/abs/2212.05098 (2023). This module
is independently implemented: its payload equations follow the Unicode
encoding definitions; it contains no copied source or conversion tables.

UTF-8 emits at sequence-end positions, plus the penultimate position for a
surrogate pair. UTF-16 materializes four candidate bytes per scalar and deletes
unused bytes with compression. Register compression followed by masked stores
writes exactly the selected lanes without slow memory-form compaction.
*/
module sparkles.base.text.utf16_emit;

version (LDC)
    version (X86_64)
        version = textSimdX86;

version (textSimdX86)
{
    import core.bitop : popcnt;
    import ldc.attributes : target;
    import ldc.llvmasm : __ir_pure, __irEx_pure;
    import ldc.simd : equalMask, greaterMask, shufflevector, storeUnaligned;
    import sparkles.base.text.simd_caps : hasAvx512Vbmi2;
    import sparkles.base.text.simd_io : loadVector;

    private alias B32 = __vector(ubyte[32]);
    private alias B64 = __vector(ubyte[64]);
    private alias W16 = __vector(ushort[16]);
    private alias W32 = __vector(ushort[32]);
    private alias D16 = __vector(uint[16]);

    package bool hasCompaction() @safe pure nothrow @nogc => hasAvx512Vbmi2;

    package struct EmittedPrefix
    {
        size_t consumed;
        size_t written;
    }

    // Preflight has validated source and proved destination capacity. Loads
    // nevertheless stay within source, and all stores have exact lane masks.
    package EmittedPrefix emitUtf8(scope const(char)[] source,
        scope wchar[] destination)
        @target("avx512f,avx512bw,avx512vl,avx512vbmi2,evex512") @safe pure nothrow @nogc
    {
        size_t si, di;
        const ushort[32] lanePositions = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
            16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31];
        const W32 positions = cast(W32) lanePositions;
        while (source.length - si >= 33)
        {
            const input = loadVector!B32(source, si);
            B32 nonAsciiMask = cast(B32) greaterMask!B32(input, B32(0x7F));
            if (byteBits32(nonAsciiMask) == 0)
                break;
            B32 twoByteMask = cast(B32) greaterMask!B32(B32(0xE0), input)
                & nonAsciiMask;
            if (byteBits32(twoByteMask) == uint.max)
            {
                // Validated, boundary-aligned bytes in 80..DF alternate
                // two-byte leads and continuations. Decode sixteen pairs
                // directly; neither compaction nor surrogate work is needed.
                assert(destination.length - di >= 16);
                const pairs = cast(W16) input;
                const value = ((pairs & W16(0x1F)) << 6)
                    | ((pairs >> 8) & W16(0x3F));
                (() @trusted => storeUnaligned!W16(value,
                    cast(ushort*) destination.ptr + di))();
                si += 32;
                di += 16;
                continue;
            }
            const next = loadVector!B32(source, si + 1);
            // Keep the next iteration at a sequence boundary. At most three
            // bytes are deferred, so zero-extension below never needs carry.
            size_t consumed = 32;
            while ((cast(ubyte) source[si + consumed] & 0xC0) == 0x80)
                --consumed;
            const B32 zero = 0;
            const p1 = shufflevector!(B32,
                32, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
                15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30)(input, zero);
            const p2 = shufflevector!(B32,
                32, 32, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
                14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29)(input, zero);
            const p3 = shufflevector!(B32,
                32, 32, 32, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
                13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28)(input, zero);
            const cur = widenBytes(input);
            const prev1 = widenBytes(p1);
            const prev2 = widenBytes(p2);
            const prev3 = widenBytes(p3);
            const ascii = cast(W32) greaterMask!W32(W32(0x80), cur);
            const two = cast(W32) greaterMask!W32(prev1, W32(0xBF));
            const three = cast(W32) greaterMask!W32(prev2, W32(0xDF));
            const four = cast(W32) greaterMask!W32(prev3, W32(0xEF));
            const pairHead = cast(W32) greaterMask!W32(prev2, W32(0xEF));
            W32 value = cast(W32)(cur & W32(0x3F));
            value |= (prev1 & W32(0x3F)) << 6;
            const value2 = ((prev1 & W32(0x1F)) << 6) | (cur & W32(0x3F));
            value = (two & value2) | (~two & value);
            const value3 = value | ((prev2 & W32(0xF)) << 12);
            value = (three & value3) | (~three & value);
            value = (ascii & cur) | (~ascii & value);
            const lowSurrogate = W32(0xDC00) | ((prev1 & W32(0xF)) << 6)
                | (cur & W32(0x3F));
            value = (four & lowSurrogate) | (~four & value);
            // U = ((lead&7)<<18)|((second&63)<<12)|((third&63)<<6)|...
            // high = D800 + ((U-10000)>>10), evaluated at the third byte.
            const highSurrogate = W32(0xD7C0) + ((prev2 & W32(7)) << 8)
                + ((prev1 & W32(0x3F)) << 2) + ((cur & W32(0x3F)) >> 4);
            value = (pairHead & highSurrogate) | (~pairHead & value);
            const end = ~cast(W32) equalMask!W32(widenBytes(next) & W32(0xC0), W32(0x80));
            const active = cast(W32) greaterMask!W32(W32(cast(ushort) consumed), positions);
            const keep = (end | pairHead) & active;
            const written = popcnt(wordBits(keep));
            assert(destination.length - di >= written);
            (() @trusted => compressWords(value, keep, cast(uint) written,
                cast(ushort*) destination.ptr + di))();
            si += consumed;
            di += written;
        }
        return EmittedPrefix(consumed: si, written: di);
    }

    package EmittedPrefix emitUtf16(scope const(wchar)[] source,
        scope char[] destination)
        @target("avx512f,avx512bw,avx512vl,avx512vbmi2,evex512") @safe pure nothrow @nogc
    {
        size_t si, di;
        const D16 positions = cast(D16) [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
        while (source.length - si >= 17)
        {
            if (source.length - si >= 32 && source[si] >= 0x80 && source[si] < 0x800)
            {
                const small = loadVector!W32(source, si);
                W32 twoByteMask = cast(W32)(greaterMask!W32(W32(0x800), small)
                    & greaterMask!W32(small, W32(0x7F)));
                if (wordBits(twoByteMask) == uint.max)
                {
                    assert(destination.length - di >= 64);
                    const bytes = (small >> 6) | W32(0xC0)
                        | (((small & W32(0x3F)) | W32(0x80)) << 8);
                    (() @trusted => storeUnaligned!W32(bytes,
                        cast(ushort*) (destination.ptr + di)))();
                    si += 32;
                    di += 64;
                    continue;
                }
            }
            const input = loadVector!W16(source, si);
            if (source[si] < 0x80)
            {
                W16 nonAsciiMask = cast(W16) greaterMask!W16(input, W16(0x7F));
                if (wordBits16(nonAsciiMask) == 0)
                    break;
            }
            const next = loadVector!W16(source, si + 1);
            const units = widenWords(input);
            const following = widenWords(next);
            if (source[si] >= 0x800)
            {
                W16 threeByteMask = cast(W16) greaterMask!W16(input, W16(0x7FF));
                W16 surrogateMask = cast(W16) equalMask!W16(
                    input & W16(0xF800), W16(0xD800));
                if (wordBits16(threeByteMask) == ushort.max && wordBits16(surrogateMask) == 0)
                {
                    assert(destination.length - di >= 48);
                    const bytes = (units >> 12) | D16(0xE0)
                        | ((((units >> 6) & D16(0x3F)) | D16(0x80)) << 8)
                        | (((units & D16(0x3F)) | D16(0x80)) << 16);
                    B64 values = cast(B64) bytes;
                    B64 keep = cast(B64) D16(0x010101);
                    (() @trusted => compressBytes(values, keep, 48,
                        cast(ubyte*) destination.ptr + di))();
                    si += 16;
                    di += 48;
                    continue;
                }
            }
            const heads = cast(D16) equalMask!D16(units & D16(0xFC00), D16(0xD800));
            const tails = cast(D16) equalMask!D16(units & D16(0xFC00), D16(0xDC00));
            const consumed = (source[si + 15] & 0xFC00) == 0xD800 ? 15 : 16;
            const paired = D16(0x10000) + ((units - D16(0xD800)) << 10)
                + (following - D16(0xDC00));
            const scalar = (heads & paired) | (~heads & units);
            const ascii = cast(D16) greaterMask!D16(D16(0x80), scalar);
            const below800 = cast(D16) greaterMask!D16(D16(0x800), scalar);
            const below10000 = cast(D16) greaterMask!D16(D16(0x10000), scalar);
            const last = (scalar & D16(0x3F)) | D16(0x80);
            const middle = ((scalar >> 6) & D16(0x3F)) | D16(0x80);
            const upper = ((scalar >> 12) & D16(0x3F)) | D16(0x80);
            const two = (scalar >> 6) | D16(0xC0) | (last << 8);
            const three = (scalar >> 12) | D16(0xE0) | (middle << 8) | (last << 16);
            const four = (scalar >> 18) | D16(0xF0) | (upper << 8) | (middle << 16) | (last << 24);
            D16 bytes = cast(D16)((below10000 & three) | (~below10000 & four));
            bytes = (below800 & two) | (~below800 & bytes);
            bytes = (ascii & scalar) | (~ascii & bytes);
            D16 keep = cast(D16)((below10000 & D16(0x010101))
                | (~below10000 & D16(0x01010101)));
            keep = (below800 & D16(0x0101)) | (~below800 & keep);
            keep = (ascii & D16(1)) | (~ascii & keep);
            keep &= ~tails & cast(D16) greaterMask!D16(D16(consumed), positions);
            // Name wide-vector arguments for LDC's indirect baseline ABI.
            B64 byteMask = cast(B64) keep;
            B64 byteValues = cast(B64) bytes;
            const written = popcnt(byteBits(byteMask));
            assert(destination.length - di >= written);
            (() @trusted => compressBytes(byteValues, byteMask, cast(uint) written,
                cast(ubyte*) destination.ptr + di))();
            si += consumed;
            di += written;
        }
        return EmittedPrefix(consumed: si, written: di);
    }

    // Baseline trusted lambdas do not inherit their parent's ISA target.
    // Pass vectors by reference: vectorcall lowers by-value wide arguments
    // differently with and without AVX-512 on Windows. Pointer/scalar
    // arguments keep this boundary stable even without inlining.
    @target("avx512f,avx512bw,avx512vl,avx512vbmi2,evex512")
    private void compressWords(ref const W32 value, ref const W32 keep,
        uint count, ushort* destination)
        @system pure nothrow @nogc => compressWordsImpl(value, keep, count, destination);

    @target("avx512f,avx512bw,avx512vl,avx512vbmi2,evex512")
    private void compressBytes(ref const B64 value, ref const B64 keep,
        uint count, ubyte* destination)
        @system pure nothrow @nogc => compressBytesImpl(value, keep, count, destination);

    private alias widenBytes = __ir_pure!(
        "%r = zext <32 x i8> %0 to <32 x i16>\nret <32 x i16> %r", W32, B32);
    private alias widenWords = __ir_pure!(
        "%r = zext <16 x i16> %0 to <16 x i32>\nret <16 x i32> %r", D16, W16);
    private alias byteBits32 = __ir_pure!(
        "%m = icmp ne <32 x i8> %0, zeroinitializer\n%b = bitcast <32 x i1> %m to i32\nret i32 %b", uint, B32);
    private alias wordBits16 = __ir_pure!(
        "%m = icmp ne <16 x i16> %0, zeroinitializer\n%b = bitcast <16 x i1> %m to i16\nret i16 %b", ushort, W16);
    private alias wordBits = __ir_pure!(
        "%m = icmp ne <32 x i16> %0, zeroinitializer\n%b = bitcast <32 x i1> %m to i32\nret i32 %b", uint, W32);
    private alias byteBits = __ir_pure!(
        "%m = icmp ne <64 x i8> %0, zeroinitializer\n%b = bitcast <64 x i1> %m to i64\nret i64 %b", ulong, B64);
    private alias compressWordsImpl = __irEx_pure!(
        "declare <32 x i16> @llvm.x86.avx512.mask.compress.v32i16(<32 x i16>, <32 x i16>, <32 x i1>)\n"
        ~ "declare void @llvm.masked.store.v32i16.p0(<32 x i16>, ptr, i32, <32 x i1>)",
        "%m = icmp ne <32 x i16> %1, zeroinitializer\n"
        ~ "%packed = call <32 x i16> @llvm.x86.avx512.mask.compress.v32i16(<32 x i16> %0, <32 x i16> zeroinitializer, <32 x i1> %m)\n"
        ~ "%count16 = trunc i32 %2 to i16\n"
        ~ "%count = insertelement <32 x i16> poison, i16 %count16, i32 0\n"
        ~ "%counts = shufflevector <32 x i16> %count, <32 x i16> poison, <32 x i32> zeroinitializer\n"
        ~ "%store = icmp ult <32 x i16> <i16 0, i16 1, i16 2, i16 3, i16 4, i16 5, i16 6, i16 7, i16 8, i16 9, i16 10, i16 11, i16 12, i16 13, i16 14, i16 15, i16 16, i16 17, i16 18, i16 19, i16 20, i16 21, i16 22, i16 23, i16 24, i16 25, i16 26, i16 27, i16 28, i16 29, i16 30, i16 31>, %counts\n"
        ~ "call void @llvm.masked.store.v32i16.p0(<32 x i16> %packed, ptr %3, i32 1, <32 x i1> %store)",
        "", void, W32, W32, uint, ushort*);
    private alias compressBytesImpl = __irEx_pure!(
        "declare <64 x i8> @llvm.x86.avx512.mask.compress.v64i8(<64 x i8>, <64 x i8>, <64 x i1>)\n"
        ~ "declare void @llvm.masked.store.v64i8.p0(<64 x i8>, ptr, i32, <64 x i1>)",
        "%count8 = trunc i32 %2 to i8\n%m = icmp ne <64 x i8> %1, zeroinitializer\n"
        ~ "%packed = call <64 x i8> @llvm.x86.avx512.mask.compress.v64i8(<64 x i8> %0, <64 x i8> zeroinitializer, <64 x i1> %m)\n"
        ~ "%count = insertelement <64 x i8> poison, i8 %count8, i32 0\n"
        ~ "%counts = shufflevector <64 x i8> %count, <64 x i8> poison, <64 x i32> zeroinitializer\n"
        ~ "%store = icmp ult <64 x i8> <i8 0, i8 1, i8 2, i8 3, i8 4, i8 5, i8 6, i8 7, i8 8, i8 9, i8 10, i8 11, i8 12, i8 13, i8 14, i8 15, i8 16, i8 17, i8 18, i8 19, i8 20, i8 21, i8 22, i8 23, i8 24, i8 25, i8 26, i8 27, i8 28, i8 29, i8 30, i8 31, i8 32, i8 33, i8 34, i8 35, i8 36, i8 37, i8 38, i8 39, i8 40, i8 41, i8 42, i8 43, i8 44, i8 45, i8 46, i8 47, i8 48, i8 49, i8 50, i8 51, i8 52, i8 53, i8 54, i8 55, i8 56, i8 57, i8 58, i8 59, i8 60, i8 61, i8 62, i8 63>, %counts\n"
        ~ "call void @llvm.masked.store.v64i8.p0(<64 x i8> %packed, ptr %3, i32 1, <64 x i1> %store)",
        "", void, B64, B64, uint, ubyte*);
}
