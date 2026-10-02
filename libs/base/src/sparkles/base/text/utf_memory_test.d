/** Protected-page regression coverage for bounded UTF validation and conversion. */
module sparkles.base.text.utf_memory_test;

version (unittest)
version (linux)
{
    import core.sys.posix.sys.mman : mmap, mprotect, munmap, MAP_FAILED,
        MAP_PRIVATE, MAP_ANON, PROT_NONE, PROT_READ, PROT_WRITE;
    import core.sys.posix.unistd : sysconf, _SC_PAGESIZE;
    import std.typecons : Yes;
    import std.utf : encode;
    import sparkles.base.text.utf8 : indexOfInvalidUtf8;
    import sparkles.base.text.utf16 : utf8ToUtf16, utf16ToUtf8,
        utf8ToUtf16z, utf16ToUtf8z, UtfConversionErrorCode;

    @("utf.memory.protectedPageTransactions")
    @system nothrow @nogc
    unittest
    {
        const page = cast(size_t) sysconf(_SC_PAGESIZE);
        assert(page >= 4096);
        auto memory = mmap(null, page * 12, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        assert(memory != MAP_FAILED);
        scope(exit) assert(munmap(memory, page * 12) == 0);
        auto p = cast(ubyte*) memory;
        foreach (i; 0 .. 4)
            assert(mprotect(p + (i * 3 + 1) * page, page, PROT_READ | PROT_WRITE) == 0);
        // Each input/output ends immediately before an inaccessible page. All
        // lengths are distinct; a final ASCII scalar fills incomplete tails.
        static immutable dchar[] scalars = ['A', '\u00E9', '\u03BB', '\u4E16',
            '\U0001F600', '\u0301', '\uFE0F', '\U0001F1E6', '\u1100', '\u1161', '\u200D'];
        foreach (n; 0 .. 513)
        {
            auto source = (cast(char*) (p + page * 2) - n)[0 .. n];
            wchar[1024] reference = void;
            size_t bytes, units, lastStart;
            for (size_t i = n % scalars.length; bytes < n; ++i)
            {
                char[4] a = void;
                wchar[2] b = void;
                dchar cp = scalars[i % scalars.length];
                auto na = encode!(Yes.useReplacementDchar)(a, cp);
                if (na > n - bytes)
                {
                    cp = 'a';
                    na = encode!(Yes.useReplacementDchar)(a, cp);
                }
                const nb = encode!(Yes.useReplacementDchar)(b, cp);
                lastStart = bytes;
                source[bytes .. bytes + na] = a[0 .. na];
                reference[units .. units + nb] = b[0 .. nb];
                bytes += na;
                units += nb;
            }
            assert(indexOfInvalidUtf8(source) == n);
            auto destination = (cast(wchar*) (p + page * 8) - units)[0 .. units];
            auto result = utf8ToUtf16(source, destination);
            assert(result.hasValue && result.value == units);
            assert(destination == reference[0 .. units]);
            auto terminated = (cast(wchar*) (p + page * 8) - units - 1)[0 .. units + 1];
            auto z = utf8ToUtf16z(source, terminated);
            assert(z.hasValue && z.value == units && terminated[units] == 0);
            assert(terminated[0 .. units] == reference[0 .. units]);
            if (units != 0)
            {
                destination[] = 0xA5A5;
                auto small = utf8ToUtf16(source, destination[1 .. $]);
                assert(small.hasError && small.error.code == UtfConversionErrorCode.insufficientSpace);
                foreach (v; destination) assert(v == 0xA5A5);
                source[$ - 1] = cast(char) 0xFF;
                assert(indexOfInvalidUtf8(source) == lastStart);
                auto invalid = utf8ToUtf16(source, destination);
                assert(invalid.hasError && invalid.error.code == UtfConversionErrorCode.invalidUtf8
                    && invalid.error.offset == lastStart);
                foreach (v; destination) assert(v == 0xA5A5);
            }
        }
        foreach (n; 0 .. 513)
        {
            auto source = (cast(wchar*) (p + page * 5) - n)[0 .. n];
            char[2048] reference = void;
            size_t bytes, units, lastStart;
            for (size_t i = n % scalars.length; units < n; ++i)
            {
                char[4] a = void;
                wchar[2] b = void;
                dchar cp = scalars[i % scalars.length];
                auto nb = encode!(Yes.useReplacementDchar)(b, cp);
                if (nb > n - units)
                {
                    cp = 'a';
                    nb = encode!(Yes.useReplacementDchar)(b, cp);
                }
                const na = encode!(Yes.useReplacementDchar)(a, cp);
                lastStart = units;
                source[units .. units + nb] = b[0 .. nb];
                reference[bytes .. bytes + na] = a[0 .. na];
                bytes += na;
                units += nb;
            }
            auto destination = (cast(char*) (p + page * 11) - bytes)[0 .. bytes];
            auto result = utf16ToUtf8(source, destination);
            assert(result.hasValue && result.value == bytes);
            assert(destination == reference[0 .. bytes]);
            auto terminated = (cast(char*) (p + page * 11) - bytes - 1)[0 .. bytes + 1];
            auto z = utf16ToUtf8z(source, terminated);
            assert(z.hasValue && z.value == bytes && terminated[bytes] == 0);
            assert(terminated[0 .. bytes] == reference[0 .. bytes]);
            if (bytes != 0)
            {
                destination[] = cast(char) 0xA5;
                auto small = utf16ToUtf8(source, destination[1 .. $]);
                assert(small.hasError && small.error.code == UtfConversionErrorCode.insufficientSpace);
                foreach (v; destination) assert(v == cast(char) 0xA5);
                source[$ - 1] = 0xD800;
                auto invalid = utf16ToUtf8(source, destination);
                assert(invalid.hasError && invalid.error.code == UtfConversionErrorCode.invalidUtf16
                    && invalid.error.offset == lastStart);
                foreach (v; destination) assert(v == cast(char) 0xA5);
            }
        }
    }
}
