module sparkles.utf_bench.engines;

import sparkles.utf_bench.reference : Conversion, firstInvalid8, to16, to8;

struct Scalar
{
    enum name = "scalar-d";
    enum contract = "bounded-fail-before-write";
    static string implementation() { return "independent-byte-scalar"; }
    static string revision() { return "package-source"; }
    static size_t invalid(scope const(char)[] input) { return firstInvalid8(input); }
    static bool valid(scope const(char)[] input) { return firstInvalid8(input) == input.length; }
    static Conversion convert16(scope const(char)[] input, scope wchar[] output) { return to16(input, output); }
    static Conversion convert8(scope const(wchar)[] input, scope char[] output) { return to8(input, output); }
}

struct Sparkles
{
    enum name = "sparkles";
    enum contract = "bounded-fail-before-write";
    static string implementation() { return "native-d"; }
    static string revision() { return "worktree-source"; }
    static size_t invalid(scope const(char)[] input)
    {
        import sparkles.base.text.utf8 : indexOfInvalidUtf8;
        return indexOfInvalidUtf8(input);
    }
    static bool valid(scope const(char)[] input)
    {
        import sparkles.base.text.utf8 : validateUtf8;
        return !validateUtf8(input).hasError;
    }
    static Conversion convert16(scope const(char)[] input, scope wchar[] output)
    {
        import sparkles.base.text.utf16 : utf8ToUtf16;
        auto result = utf8ToUtf16(input, output);
        return result.hasError ? Conversion(false, result.error.offset) : Conversion(true, result.value);
    }
    static Conversion convert8(scope const(wchar)[] input, scope char[] output)
    {
        import sparkles.base.text.utf16 : utf16ToUtf8;
        auto result = utf16ToUtf8(input, output);
        return result.hasError ? Conversion(false, result.error.offset) : Conversion(true, result.value);
    }
}

version (UtfBenchSimdutf)
{
    extern(C) @system nothrow @nogc
    {
        const(char)* utf_bench_simdutf_revision();
        const(char)* utf_bench_simdutf_implementation();
        size_t utf_bench_simdutf_invalid(const(char)* input, size_t length);
        int utf_bench_simdutf_valid(const(char)* input, size_t length);
        int utf_bench_simdutf_to16(const(char)* input, size_t length, wchar* output, size_t* count);
        int utf_bench_simdutf_to8(const(wchar)* input, size_t length, char* output, size_t* count);
    }

    struct Simdutf
    {
        enum name = "simdutf";
        enum contract = "unbounded-may-write-prefix-on-failure";
        static string implementation()
        {
            import std.string : fromStringz;
            return utf_bench_simdutf_implementation().fromStringz.idup;
        }
        static string revision()
        {
            import std.string : fromStringz;
            return utf_bench_simdutf_revision().fromStringz.idup;
        }
        static size_t invalid(scope const(char)[] input) { return utf_bench_simdutf_invalid(input.ptr, input.length); }
        static bool valid(scope const(char)[] input) { return utf_bench_simdutf_valid(input.ptr, input.length) != 0; }
        static Conversion convert16(scope const(char)[] input, scope wchar[] output)
        {
            size_t count;
            const valid = utf_bench_simdutf_to16(input.ptr, input.length, output.ptr, &count) != 0;
            return Conversion(valid, count);
        }
        static Conversion convert8(scope const(wchar)[] input, scope char[] output)
        {
            size_t count;
            const valid = utf_bench_simdutf_to8(input.ptr, input.length, output.ptr, &count) != 0;
            return Conversion(valid, count);
        }
    }
}

version (UtfBenchRust)
{
    extern(C) @system nothrow @nogc
    {
        size_t utf_bench_rust_invalid(const(char)* input, size_t length);
        int utf_bench_rust_valid(const(char)* input, size_t length);
        size_t utf_bench_xutf_width(const(char)* input, size_t length);
        size_t utf_bench_xutf_boundaries(const(char)* input, size_t length, size_t* ends, size_t capacity);
    }
    struct Simdutf8
    {
        enum name = "simdutf8";
        enum contract = "compat-first-invalid-basic-bool-full-scan";
        static string implementation() { return "rust-runtime-dispatch"; }
        static string revision() { return "641d57f313df57354246d2b68d4778c092e076c3"; }
        static size_t invalid(scope const(char)[] input) { return utf_bench_rust_invalid(input.ptr, input.length); }
        static bool valid(scope const(char)[] input) { return utf_bench_rust_valid(input.ptr, input.length) != 0; }
    }
}
