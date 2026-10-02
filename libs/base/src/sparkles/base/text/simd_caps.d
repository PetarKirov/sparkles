/** Internal immutable SIMD capabilities, including OS extended-register state. */
module sparkles.base.text.simd_caps;

version (LDC)
    version (X86_64)
        version = textSimdX86;

version (textSimdX86)
{
    package immutable bool hasAvx512Bw;
    package immutable bool hasAvx512Vbmi2;

    shared static this()
    {
        const capabilities = detectCapabilities();
        hasAvx512Bw = (capabilities & 1) != 0;
        hasAvx512Vbmi2 = (capabilities & 2) != 0;
    }

    private uint detectCapabilities() @safe nothrow @nogc
    {
        uint a, b, c, d;
        (() @trusted {
            asm pure nothrow @nogc
            {
                "cpuid" : "=a" (a), "=b" (b), "=c" (c), "=d" (d) : "a" (0);
            }
        })();
        if (a < 7)
            return 0;
        (() @trusted {
            asm pure nothrow @nogc
            {
                "cpuid" : "=a" (a), "=b" (b), "=c" (c), "=d" (d) : "a" (1);
            }
        })();
        if ((c & ((1u << 27) | (1u << 28))) != ((1u << 27) | (1u << 28)))
            return 0;
        // XMM, YMM, opmask, ZMM_Hi256 and Hi16_ZMM state must all be enabled.
        (() @trusted {
            asm pure nothrow @nogc
            {
                "xgetbv" : "=a" (a), "=d" (d) : "c" (0);
            }
        })();
        if ((a & 0xE6) != 0xE6)
            return 0;
        (() @trusted {
            asm pure nothrow @nogc
            {
                "cpuid" : "=a" (a), "=b" (b), "=c" (c), "=d" (d) : "a" (7), "c" (0);
            }
        })();
        if ((b & ((1u << 16) | (1u << 30))) != ((1u << 16) | (1u << 30)))
            return 0;
        return 1 | ((c & (1u << 6)) != 0 ? 2 : 0);
    }
}
