/**
Internal bounded SIMD UTF-8 validation. Every returned prefix ends at a
sequence boundary; the scalar caller resolves a rejected block's exact offset.
No padding, speculative out-of-slice load, or runtime allocation is required.
*/
module sparkles.base.text.utf8_simd;

version (LDC)
    version (X86_64)
        version = textSimdX86;

version (textSimdX86)
{
    import core.cpuid : avx2;

    import ldc.attributes : target;
    import ldc.gccbuiltins_x86 : __builtin_ia32_pmovmskb128,
        __builtin_ia32_pmovmskb256, __builtin_ia32_pshufb256;
    import ldc.simd : equalMask, greaterMask, loadUnaligned, shufflevector;

    // The JSON mode is an internal cross-library seam: stop before quotes,
    // escapes and controls while validating the same loaded bytes once.
    package(sparkles) size_t validatedUtf8Prefix(bool stringBody = false)(
        scope const(char)[] s) @safe pure nothrow @nogc
    {
        return avx2() ? validateBlocks!(32, stringBody)(s)
            : validateBlocks!(16, stringBody)(s);
    }

    // Carry the preceding three bytes across full blocks. Only exits refine
    // the accepted prefix back to a sequence boundary; the hot loop neither
    // overlaps loads nor walks trailing continuation bytes.
    private size_t validateBlocks(size_t lanes, bool stringBody = false)(
        scope const(char)[] s)
        @target(lanes == 32 ? "avx2" : "sse2") @safe pure nothrow @nogc
    {
        alias V = __vector(ubyte[lanes]);
        alias S = __vector(byte[lanes]);
        size_t i;
        V previous = 0;
        uint previousMask;
        static if (!stringBody)
        {
            // One initial ASCII sweep, not four speculative loads on every
            // multilingual block. Reduce four vectors before testing a mask.
            while (s.length - i >= lanes * 4)
            {
                V combined = 0;
                V last;
                static foreach (block; 0 .. 4)
                {{
                    const bytes = (() @trusted =>
                        loadUnaligned!V(cast(const(ubyte)*) s.ptr + i + block * lanes))();
                    combined |= bytes;
                    last = bytes;
                }}
                if (mask(cast(S) combined) != 0)
                    break;
                previous = last;
                i += lanes * 4;
            }
        }
        while (s.length - i >= lanes)
        {
            const input = (() @trusted => loadUnaligned!V(cast(const(ubyte)*) s.ptr + i))();
            static if (stringBody)
            {
                const stops = equalMask!V(input, V('"'))
                    | equalMask!V(input, V('\\'))
                    | greaterMask!V(V(0x20), input);
                if (mask(stops) != 0)
                    return sequenceBoundaryBefore(s, i);
            }
            const inputMask = mask(cast(S) input);
            // The last three previous bytes being ASCII proves that no
            // continuation is pending. Otherwise validate even an ASCII block.
            if ((inputMask | (previousMask >> (lanes - 3))) == 0)
            {
                previous = input;
                previousMask = inputMask;
                i += lanes;
                continue;
            }
            const p1 = preceding!1(input, previous);
            const p2 = preceding!2(input, previous);
            const p3 = preceding!3(input, previous);
            S bad;
            static if (lanes == 32)
                bad = lookupPairErrors(input, p1, p2, p3);
            else
            {
                const cont = greaterMask!S(S(-64), cast(S) input);
                const expected = equalMask!V(p1 & V(0xC0), V(0xC0))
                    | equalMask!V(p2 & V(0xE0), V(0xE0))
                    | equalMask!V(p3 & V(0xF8), V(0xF0));
                bad = cont ^ expected;
                bad |= equalMask!V(input & V(0xFE), V(0xC0))
                    | greaterMask!V(input, V(0xF4));
                bad |= equalMask!V(p1, V(0xE0)) & greaterMask!V(V(0xA0), input);
                bad |= equalMask!V(p1, V(0xED)) & greaterMask!V(input, V(0x9F));
                bad |= equalMask!V(p1, V(0xF0)) & greaterMask!V(V(0x90), input);
                bad |= equalMask!V(p1, V(0xF4)) & greaterMask!V(input, V(0x8F));
            }
            if (mask(bad) != 0)
                return sequenceBoundaryBefore(s, i);
            previous = input;
            previousMask = inputMask;
            i += lanes;
        }
        return sequenceBoundaryBefore(s, i);
    }

    private size_t sequenceBoundaryBefore(scope const(char)[] s, size_t end)
        @safe pure nothrow @nogc
    {
        if (end == 0 || s[end - 1] < 0x80)
            return end;
        size_t lead = end - 1;
        while (s[lead] < 0xC0)
            --lead;
        const length = s[lead] < 0xE0 ? 2 : s[lead] < 0xF0 ? 3 : 4;
        return end - lead < length ? lead : end;
    }

    private uint mask(S)(S v)
        @target(S.sizeof == 32 ? "avx2" : "sse2") @safe pure nothrow @nogc
    {
        static if (S.sizeof == 32)
            return cast(uint) __builtin_ia32_pmovmskb256(v);
        else
            return cast(uint) __builtin_ia32_pmovmskb128(v);
    }

    private V preceding(size_t count, V)(V input, V previous)
    {
        import std.meta : AliasSeq;
        template Indices(size_t index = 0)
        {
            static if (index == V.sizeof)
                alias Indices = AliasSeq!();
            else
                alias Indices = AliasSeq!(index < count ? 2 * V.sizeof - count + index : index - count,
                    Indices!(index + 1));
        }
        return shufflevector!(V, Indices!())(input, previous);
    }

    // Independently derive the three nibble classifications from UTF-8's
    // adjacent-byte constraints (Keiser/Lemire, arXiv:2010.03090, lookup4).
    // Bits 0..6 denote pair errors; bit 7 denotes two continuations, which
    // must coincide with a third/fourth position implied by earlier leads.
    private ubyte previousHigh(ubyte n) @safe pure nothrow @nogc =>
        cast(ubyte)(n < 8 ? 0x02 : n < 12 ? 0x80
            : n == 12 ? 0x05 : n == 13 ? 0x01 : n == 14 ? 0x19 : 0x61);

    private ubyte previousLow(ubyte n) @safe pure nothrow @nogc =>
        cast(ubyte)(0x83 | (n < 2 ? 0x04 : 0) | (n == 0 ? 0x28 : 0)
            | (n == 13 ? 0x10 : 0) | (n == 4 ? 0x40 : 0));

    private ubyte currentHigh(ubyte n) @safe pure nothrow @nogc =>
        cast(ubyte)(n < 8 || n >= 12 ? 0x01
            : 0x86 | (n < 10 ? 0x08 : 0x10)
                | (n == 8 ? 0x20 : 0x40));

    private ubyte[32] nibbleTable(alias classify)()
    {
        ubyte[32] table;
        foreach (i, ref value; table)
            value = classify(cast(ubyte)(i & 15));
        return table;
    }

    pragma(inline, true)
    private __vector(byte[32]) lookupPairErrors()(
        __vector(ubyte[32]) input, __vector(ubyte[32]) p1,
        __vector(ubyte[32]) p2, __vector(ubyte[32]) p3)
        @target("avx2") @safe pure nothrow @nogc
    {
        alias V = __vector(ubyte[32]);
        alias S = __vector(byte[32]);
        alias W = __vector(ushort[16]);
        enum highTable = nibbleTable!previousHigh();
        enum lowTable = nibbleTable!previousLow();
        enum inputTable = nibbleTable!currentHigh();
        const V high = highTable;
        const V low = lowTable;
        const V current = inputTable;
        const high1 = cast(V)(cast(W) p1 >> 4) & V(0x0F);
        const high0 = cast(V)(cast(W) input >> 4) & V(0x0F);
        const pairs = __builtin_ia32_pshufb256(cast(S) high, cast(S) high1)
            & __builtin_ia32_pshufb256(cast(S) low, cast(S)(p1 & V(0x0F)))
            & __builtin_ia32_pshufb256(cast(S) current, cast(S) high0);
        const expected = (equalMask!V(p2 & V(0xE0), V(0xE0))
            | equalMask!V(p3 & V(0xF8), V(0xF0))) & S(cast(byte) 0x80);
        const errors = (pairs ^ expected) | greaterMask!V(input, V(0xF4));
        return ~equalMask!V(cast(V) errors, V(0));
    }

    @("utf8.simd.blockBoundaries")
    @safe pure nothrow @nogc
    unittest
    {
        import sparkles.base.text.utf8 : utf8SequenceLength;

        size_t scalarOffset(scope const(char)[] input)
        {
            size_t i;
            while (i < input.length)
            {
                const n = input[i] < 0x80 ? 1 : utf8SequenceLength(input, i);
                if (n == 0)
                    return i;
                i += n;
            }
            return i;
        }

        // Every alignment, all byte values, truncations and malformed second
        // bytes exercise both the block boundary and exact scalar refinement.
        foreach (text; ["\u00E9", "\u4E16", "\U0001F600", "a\u0301"])
        {
            foreach (offset; 0 .. 64)
            {
                char[128] storage;
                storage[] = 'x';
                storage[offset .. offset + text.length] = text[];
                foreach (length; offset .. offset + text.length + 34)
                {
                    const input = storage[0 .. length];
                    const expected = scalarOffset(input);
                    const sse = validateBlocks!16(input);
                    assert(sse + scalarOffset(input[sse .. $]) == expected);
                    if (avx2())
                    {
                        const avx = validateBlocks!32(input);
                        assert(avx + scalarOffset(input[avx .. $]) == expected);
                    }
                }
                foreach (position; offset .. offset + text.length)
                {
                    const original = storage[position];
                    foreach (value; 0 .. 256)
                    {
                        storage[position] = cast(char) value;
                        const input = storage[];
                        const expected = scalarOffset(input);
                        const sse = validateBlocks!16(input);
                        assert(sse + scalarOffset(input[sse .. $]) == expected);
                        if (avx2())
                        {
                            const avx = validateBlocks!32(input);
                            assert(avx + scalarOffset(input[avx .. $]) == expected);
                        }
                    }
                    storage[position] = original;
                }
            }
        }
    }
}
