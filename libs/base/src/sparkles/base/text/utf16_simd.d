/**
Internal UTF-8/UTF-16 bulk sizing and ASCII conversion. SSE2 is baseline on
x86-64; other architectures and compilers use the caller's scalar path.
Complete bounded blocks validate/count UTF-16 or count already-validated
UTF-8. ASCII widening/narrowing has scalar tails; non-ASCII conversion stays
in the caller. No padding, overstores, or allocation.
*/
module sparkles.base.text.utf16_simd;

version (LDC)
    version (X86_64)
        version = textSimdX86;

version (textSimdX86)
{
    import core.bitop : popcnt;
    import ldc.attributes : target;
    import ldc.gccbuiltins_x86 : __builtin_ia32_packuswb128,
        __builtin_ia32_pmovmskb128;
    import ldc.simd : equalMask, greaterMask, shufflevector, storeUnaligned;
    import ldc.llvmasm : __ir_pure;

    import sparkles.base.text.simd_caps : hasAvx512Bw;
    import sparkles.base.text.simd_io : loadVector;

    private alias Bytes = __vector(ubyte[16]);
    private alias SignedBytes = __vector(byte[16]);
    private alias Words = __vector(ushort[8]);
    private alias SignedWords = __vector(short[8]);

    package size_t asciiUtf8Prefix(scope const(char)[] source, bool rejectNul)
        @target("sse2") @safe pure nothrow @nogc
    {
        size_t i;
        while (source.length - i >= 16)
        {
            const input = loadVector!Bytes(source, i);
            if (!asciiBytes(input, rejectNul))
                break;
            i += 16;
        }
        // Refine a rejected block to its first non-ASCII/NUL unit so the
        // caller does not repeatedly probe overlapping mixed blocks.
        while (i < source.length && source[i] < 0x80
            && (!rejectNul || source[i] != 0))
            ++i;
        return i;
    }

    package size_t asciiUtf16Prefix(scope const(wchar)[] source, bool rejectNul)
        @target("sse2") @safe pure nothrow @nogc
    {
        size_t i;
        while (source.length - i >= 16)
        {
            const low = loadVector!Words(source, i);
            const high = loadVector!Words(source, i + 8);
            if (!asciiWords(low, high, rejectNul))
                break;
            i += 16;
        }
        while (i < source.length && source[i] < 0x80
            && (!rejectNul || source[i] != 0))
            ++i;
        return i;
    }

    package size_t widenAsciiUtf8(scope const(char)[] source,
        scope wchar[] destination) @target("sse2") @safe pure nothrow @nogc
    {
        size_t i;
        while (source.length - i >= 16 && destination.length - i >= 16)
        {
            const input = loadVector!Bytes(source, i);
            if (!asciiBytes(input, false))
                break;
            const Bytes zero = 0;
            const low = cast(Words) shufflevector!(Bytes,
                0, 16, 1, 16, 2, 16, 3, 16, 4, 16, 5, 16, 6, 16, 7, 16)(input, zero);
            const high = cast(Words) shufflevector!(Bytes,
                8, 16, 9, 16, 10, 16, 11, 16, 12, 16, 13, 16, 14, 16, 15, 16)(input, zero);
            (() @trusted {
                storeUnaligned!Words(low, cast(ushort*) destination.ptr + i);
                storeUnaligned!Words(high, cast(ushort*) destination.ptr + i + 8);
            })();
            i += 16;
        }
        while (i < source.length && i < destination.length && source[i] < 0x80)
        {
            destination[i] = cast(wchar) source[i];
            ++i;
        }
        return i;
    }

    package size_t narrowAsciiUtf16(scope const(wchar)[] source,
        scope char[] destination) @target("sse2") @safe pure nothrow @nogc
    {
        size_t i;
        while (source.length - i >= 16 && destination.length - i >= 16)
        {
            const low = loadVector!Words(source, i);
            const high = loadVector!Words(source, i + 8);
            if (!asciiWords(low, high, false))
                break;
            const packed = __builtin_ia32_packuswb128(
                cast(SignedWords) low, cast(SignedWords) high);
            (() @trusted => storeUnaligned!SignedBytes(
                packed, cast(byte*) destination.ptr + i))();
            i += 16;
        }
        while (i < source.length && i < destination.length && source[i] < 0x80)
        {
            destination[i] = cast(char) source[i];
            ++i;
        }
        return i;
    }

    package struct MeasuredPrefix
    {
        size_t consumed;
        size_t required;
    }

    // Source is already validated and ends at a UTF-8 sequence boundary.
    // Count one unit per non-continuation byte, plus one per four-byte lead.
    package MeasuredPrefix countUtf8Units(scope const(char)[] source, bool rejectNul)
        @target("sse2") @safe pure nothrow @nogc
    {
        size_t i;
        size_t units;
        if (source.length >= 64 && hasAvx512Bw)
        {
            const measured = countUtf8Wide(source, rejectNul);
            i = measured.consumed;
            units = measured.required;
        }
        while (source.length - i >= 16)
        {
            const input = loadVector!Bytes(source, i);
            if (rejectNul && __builtin_ia32_pmovmskb128(
                    equalMask!Bytes(input, Bytes(0))) != 0)
                break;
            const continuation = greaterMask!SignedBytes(
                SignedBytes(-64), cast(SignedBytes) input);
            const supplementary = equalMask!Bytes(input & Bytes(0xF8), Bytes(0xF0));
            units += 16 - popcnt(cast(uint) __builtin_ia32_pmovmskb128(continuation))
                + popcnt(cast(uint) __builtin_ia32_pmovmskb128(supplementary));
            i += 16;
        }
        while (i < source.length && (!rejectNul || source[i] != 0))
        {
            const b = cast(ubyte) source[i++];
            if ((b & 0xC0) != 0x80)
                units += b >= 0xF0 ? 2 : 1;
        }
        return MeasuredPrefix(consumed: i, required: units);
    }

    // A block begins at a scalar boundary. Two mask bits represent each word:
    // low-surrogate positions must exactly match high-surrogate positions
    // shifted by one word. A final high surrogate is deferred, never consumed.
    package MeasuredPrefix measureUtf16Prefix(scope const(wchar)[] source, bool rejectNul)
        @target("sse2") @safe pure nothrow @nogc
    {
        size_t i;
        size_t bytes;
        if (source.length >= 32 && hasAvx512Bw)
        {
            const measured = measureUtf16Wide(source, rejectNul);
            i = measured.consumed;
            bytes = measured.required;
        }
        while (source.length - i >= 16)
        {
            const low = loadVector!Words(source, i);
            const high = loadVector!Words(source, i + 8);
            if (rejectNul && (wordMask(equalMask!Words(low, Words(0)))
                    | wordMask(equalMask!Words(high, Words(0)))) != 0)
                break;
            const heads = wordMask(equalMask!Words(low & Words(0xFC00), Words(0xD800)))
                | (wordMask(equalMask!Words(high & Words(0xFC00), Words(0xD800))) << 16);
            const tails = wordMask(equalMask!Words(low & Words(0xFC00), Words(0xDC00)))
                | (wordMask(equalMask!Words(high & Words(0xFC00), Words(0xDC00))) << 16);
            if (tails != (heads << 2))
                break;
            const ascii = wordMask(equalMask!Words(low & Words(0xFF80), Words(0)))
                | (wordMask(equalMask!Words(high & Words(0xFF80), Words(0))) << 16);
            const below800 = wordMask(equalMask!Words(low & Words(0xF800), Words(0)))
                | (wordMask(equalMask!Words(high & Words(0xF800), Words(0))) << 16);
            const deferred = (heads >> 30) != 0;
            bytes += 48 - popcnt(ascii) / 2 - popcnt(below800) / 2 - popcnt(tails)
                - (deferred ? 3 : 0);
            i += deferred ? 15 : 16;
        }
        return MeasuredPrefix(consumed: i, required: bytes);
    }

    private alias WideBytes = __vector(ubyte[64]);
    private alias WideWords = __vector(ushort[32]);
    private alias wideByteBits = __ir_pure!(
        "%m = icmp ne <64 x i8> %0, zeroinitializer\n"
        ~ "%b = bitcast <64 x i1> %m to i64\nret i64 %b", ulong, WideBytes);
    private alias wideWordBits = __ir_pure!(
        "%m = icmp ne <32 x i16> %0, zeroinitializer\n"
        ~ "%b = bitcast <32 x i1> %m to i32\nret i32 %b", uint, WideWords);

    private MeasuredPrefix countUtf8Wide(scope const(char)[] source, bool rejectNul)
        @target("avx512f,avx512bw") @safe pure nothrow @nogc
    {
        size_t i, units;
        while (source.length - i >= 64)
        {
            const input = loadVector!WideBytes(source, i);
            WideBytes zeros = cast(WideBytes) equalMask!WideBytes(input, WideBytes(0));
            if (rejectNul && wideByteBits(zeros) != 0)
                break;
            WideBytes continuation = cast(WideBytes) equalMask!WideBytes(
                input & WideBytes(0xC0), WideBytes(0x80));
            WideBytes supplementary = cast(WideBytes) equalMask!WideBytes(
                input & WideBytes(0xF8), WideBytes(0xF0));
            units += 64 - popcnt(wideByteBits(continuation))
                + popcnt(wideByteBits(supplementary));
            i += 64;
        }
        return MeasuredPrefix(consumed: i, required: units);
    }

    private MeasuredPrefix measureUtf16Wide(scope const(wchar)[] source, bool rejectNul)
        @target("avx512f,avx512bw") @safe pure nothrow @nogc
    {
        size_t i, bytes;
        while (source.length - i >= 32)
        {
            const input = loadVector!WideWords(source, i);
            WideWords zeros = cast(WideWords) equalMask!WideWords(input, WideWords(0));
            if (rejectNul && wideWordBits(zeros) != 0)
                break;
            WideWords headMask = cast(WideWords) equalMask!WideWords(
                input & WideWords(0xFC00), WideWords(0xD800));
            WideWords tailMask = cast(WideWords) equalMask!WideWords(
                input & WideWords(0xFC00), WideWords(0xDC00));
            const heads = wideWordBits(headMask);
            const tails = wideWordBits(tailMask);
            if (tails != (heads << 1))
                break;
            WideWords ascii = cast(WideWords) equalMask!WideWords(
                input & WideWords(0xFF80), WideWords(0));
            WideWords below800 = cast(WideWords) equalMask!WideWords(
                input & WideWords(0xF800), WideWords(0));
            const deferred = (heads >> 31) != 0;
            bytes += 96 - popcnt(wideWordBits(ascii)) - popcnt(wideWordBits(below800))
                - 2 * popcnt(tails) - (deferred ? 3 : 0);
            i += deferred ? 31 : 32;
        }
        return MeasuredPrefix(consumed: i, required: bytes);
    }

    private uint wordMask(__vector(short[8]) words) @target("sse2") @safe pure nothrow @nogc =>
        cast(uint) __builtin_ia32_pmovmskb128(cast(SignedBytes) words);

    private bool asciiBytes(Bytes input, bool rejectNul)
        @target("sse2") @safe pure nothrow @nogc
    {
        if (__builtin_ia32_pmovmskb128(cast(SignedBytes) input) != 0)
            return false;
        return !rejectNul
            || __builtin_ia32_pmovmskb128(equalMask!Bytes(input, Bytes(0))) == 0;
    }

    private bool asciiWords(Words low, Words high, bool rejectNul)
        @target("sse2") @safe pure nothrow @nogc
    {
        // All bits above bit 6 must be zero, not merely the signed word bit.
        const outsideAscii = (low | high) & Words(0xFF80);
        if (__builtin_ia32_pmovmskb128(cast(SignedBytes)
                equalMask!Words(outsideAscii, Words(0))) != 0xFFFF)
            return false;
        return !rejectNul
            || __builtin_ia32_pmovmskb128(cast(SignedBytes)
                (equalMask!Words(low, Words(0))
                    | equalMask!Words(high, Words(0)))) == 0;
    }
}
