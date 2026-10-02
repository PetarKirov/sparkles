/** Internal bounded vector I/O with target-consistent vector return ABI. */
module sparkles.base.text.simd_io;

version (LDC)
    version (X86_64)
        version = textSimdX86;

version (textSimdX86)
{
    import ldc.attributes : target;
    import ldc.simd : loadUnaligned;

    // A baseline trusted lambda returning a wide vector has a different ABI
    // from its AVX caller without inlining. Keep the vector return targeted;
    // the trusted pointer operation communicates through a captured reference.
    package V loadVector(V, T)(scope const(T)[] source, size_t offset)
        @target(V.sizeof == 64 ? "avx512f,avx512bw,avx512vl,evex512" : V.sizeof == 32 ? "avx2" : "sse2")
    if (is(typeof(V.init.array)) && T.sizeof == typeof(V.init.array[0]).sizeof)
    in (offset <= source.length && source.length - offset >= V.sizeof / T.sizeof)
    {
        alias Element = typeof(V.init.array[0]);
        V result = void;
        (() @trusted {
            result = loadUnaligned!V(cast(const(Element)*) (source.ptr + offset));
        })();
        return result;
    }
}
