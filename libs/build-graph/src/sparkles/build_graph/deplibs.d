/**
The libraries an object names through `pragma(lib)` (build-graph SPEC BGK9).

On ELF, LDC records each `pragma(lib, "<name>")` in the object's
`.deplibs` section (`SHT_LLVM_DEPENDENT_LIBRARIES`), as NUL-terminated
names, and the linker resolves each as it resolves `-l<name>`. A link's
declared key covers where each resolved to, so the names are read from its
inputs, objects and archives alike, once those exist.
*/
module sparkles.build_graph.deplibs;

/// `SHT_LLVM_DEPENDENT_LIBRARIES`.
enum uint shtDependentLibraries = 0x6fff4c04;

/**
The names `file`'s `.deplibs` sections hold, in order and without repeats:
an ELF64 little-endian object's own, or those of each object member of an
`ar` archive. Anything else, and anything malformed, names none.
*/
string[] dependentLibraries(scope const(ubyte)[] file) @safe pure nothrow
{
    string[] names;
    void add(string name)
    {
        foreach (n; names)
            if (n == name)
                return;
        names ~= name;
    }
    if (file.length >= 8 && file[0 .. 8] == cast(const(ubyte)[]) "!<arch>\n")
    {
        size_t at = 8;
        while (at + 60 <= file.length)
        {
            const header = file[at .. at + 60];
            const size = decimal(header[48 .. 58]);
            at += 60;
            if (size > file.length - at)
                break;
            // The symbol table (`/`) and the long-name table (`//`) hold no
            // object; every other member is one.
            if (header[0] != '/' || (header[1] != ' ' && header[1] != '/'))
                foreach (n; objectLibraries(file[at .. at + size]))
                    add(n);
            at += size + (size & 1);
        }
        return names;
    }
    foreach (n; objectLibraries(file))
        add(n);
    return names;
}

private string[] objectLibraries(scope const(ubyte)[] o) @safe pure nothrow
{
    // ELF64, little-endian.
    if (o.length < 64 || o[0 .. 4] != cast(const(ubyte)[]) "\x7fELF" || o[4] != 2 || o[5] != 1)
        return null;
    const shoff = le!ulong(o, 0x28);
    const shentsize = le!ushort(o, 0x3a);
    const shnum = le!ushort(o, 0x3c);
    if (shentsize < 64 || shoff > o.length || shnum > (o.length - shoff) / shentsize)
        return null;
    string[] names;
    foreach (i; 0 .. shnum)
    {
        const h = shoff + i * shentsize;
        if (le!uint(o, h + 4) != shtDependentLibraries)
            continue;
        const offset = le!ulong(o, h + 0x18);
        const size = le!ulong(o, h + 0x20);
        if (offset > o.length || size > o.length - offset)
            continue;
        size_t start = cast(size_t) offset;
        const end = cast(size_t)(offset + size);
        foreach (j; start .. end)
            if (o[j] == 0)
            {
                if (j > start)
                    names ~= cast(string) o[start .. j].idup;
                start = j + 1;
            }
    }
    return names;
}

private T le(T)(scope const(ubyte)[] b, size_t at) @safe pure nothrow @nogc
{
    T v;
    if (at + T.sizeof > b.length)
        return 0;
    foreach (k; 0 .. T.sizeof)
        v |= cast(T)(cast(T) b[at + k] << (8 * k));
    return v;
}

// An `ar` header's decimal field, space-padded.
private size_t decimal(scope const(ubyte)[] field) @safe pure nothrow @nogc
{
    size_t n;
    foreach (c; field)
    {
        if (c < '0' || c > '9')
            break;
        n = n * 10 + (c - '0');
    }
    return n;
}

///
@("build_graph.deplibs.dependentLibraries")
@safe pure nothrow unittest
{
    // A minimal ELF64 object: its header, a `.deplibs` section's bytes, and
    // two section headers (the null one and the `.deplibs` one).
    ubyte[] elf = new ubyte[64];
    elf[0 .. 4] = cast(const(ubyte)[]) "\x7fELF";
    elf[4] = 2;
    elf[5] = 1;
    const data = cast(const(ubyte)[]) "z\0ws2_32\0z\0";
    const dataAt = elf.length;
    elf ~= data;
    while (elf.length % 8)
        elf ~= 0;
    const shoff = elf.length;
    elf ~= new ubyte[128];
    void put(T)(size_t at, T v)
    {
        foreach (k; 0 .. T.sizeof)
            elf[at + k] = cast(ubyte)(v >> (8 * k));
    }
    put!ulong(0x28, shoff);
    put!ushort(0x3a, 64);
    put!ushort(0x3c, 2);
    put!uint(shoff + 64 + 4, shtDependentLibraries);
    put!ulong(shoff + 64 + 0x18, dataAt);
    put!ulong(shoff + 64 + 0x20, data.length);
    assert(dependentLibraries(elf) == ["z", "ws2_32"]);

    // The same object as an archive's member, after a symbol table.
    string field(string s, size_t width)
    {
        while (s.length < width)
            s ~= ' ';
        return s;
    }
    string sizeOf(size_t n)
    {
        string s;
        do
            s = cast(char)('0' + n % 10) ~ s;
        while ((n /= 10) != 0);
        return s;
    }
    ubyte[] ar = cast(ubyte[]) "!<arch>\n".dup;
    ar ~= cast(const(ubyte)[]) (field("/", 48) ~ field("4", 10) ~ "`\n");
    ar ~= [0, 0, 0, 0];
    ar ~= cast(const(ubyte)[]) (field("m.o/", 48) ~ field(sizeOf(elf.length), 10) ~ "`\n");
    ar ~= elf;
    assert(dependentLibraries(ar) == ["z", "ws2_32"]);

    assert(dependentLibraries(cast(const(ubyte)[]) "not an object") is null);
    assert(dependentLibraries(elf[0 .. 70]) is null); // its section headers cut off
}
