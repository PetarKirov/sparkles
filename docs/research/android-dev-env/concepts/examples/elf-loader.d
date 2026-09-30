#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-elf-loader"
    platforms "linux"
    targetPath "build"
+/
/**
 * Read an actual ELF's PT_INTERP without executing it.
 * Evidence for ../index.md#canonical-store-and-elf-abi.
 * Defaults to this executable; pass a Linux or Android ELF as the argument.
 */
module elf_loader;

import std.file : read;
import std.stdio : writeln;
import std.exception : enforce;

ulong number(const(ubyte)[] bytes, size_t offset, size_t count, bool little)
{
    enforce(offset <= bytes.length && count <= bytes.length - offset, "truncated ELF");
    ulong result;
    foreach (i; 0 .. count)
        result |= cast(ulong) bytes[offset + i] << (8 * (little ? i : count - i - 1));
    return result;
}

string interpreter(const(ubyte)[] bytes)
{
    enforce(bytes.length >= 52 && bytes[0 .. 4] == [0x7f, 'E', 'L', 'F'], "not an ELF");
    enforce(bytes[4] == 1 || bytes[4] == 2, "unsupported ELF class");
    enforce(bytes[5] == 1 || bytes[5] == 2, "unsupported ELF byte order");
    const wide = bytes[4] == 2;
    const little = bytes[5] == 1;
    const table = number(bytes, wide ? 32 : 28, wide ? 8 : 4, little);
    const stride = number(bytes, wide ? 54 : 42, 2, little);
    const count = number(bytes, wide ? 56 : 44, 2, little);
    enforce(stride >= (wide ? 56 : 32), "invalid ELF program header stride");
    foreach (i; 0 .. count)
    {
        enforce(table <= bytes.length && i <= (bytes.length - table) / stride, "truncated program headers");
        const entry = cast(size_t) (table + i * stride);
        if (number(bytes, entry, 4, little) != 3) // PT_INTERP
            continue;
        const offset = number(bytes, entry + (wide ? 8 : 4), wide ? 8 : 4, little);
        const length = number(bytes, entry + (wide ? 32 : 16), wide ? 8 : 4, little);
        enforce(offset <= bytes.length && length <= bytes.length - offset && length > 0,
            "truncated ELF interpreter");
        const value = bytes[cast(size_t) offset .. cast(size_t) (offset + length)];
        enforce(value[$ - 1] == 0, "unterminated ELF interpreter");
        return cast(string) value[0 .. $ - 1].idup;
    }
    return null;
}

void main(string[] args)
{
    const path = args.length > 1 ? args[1] : "/proc/self/exe";
    const loader = interpreter(cast(ubyte[]) read(path));
    writeln("ELF: ", path);
    writeln("PT_INTERP: ", loader.length ? loader : "none (no dynamic interpreter)");
    writeln("An ELF's directory does not change its embedded interpreter path.");
}
