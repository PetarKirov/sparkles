#!/usr/bin/env dub
/+ dub.sdl:
    name "static_init"
    dependency "sparkles:base" path="../../.."
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

module static_init_example;

import core.thread : Thread;
import std.stdio : writeln;

import sparkles.base.static_init : staticVar, StaticBlock;

/// CRC-32 (IEEE) lookup table, built once at startup.
uint[256] buildCrcTable() pure
{
    uint[256] table;
    foreach (uint n, ref entry; table)
    {
        uint c = n;
        foreach (_; 0 .. 8)
            c = c & 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        entry = c;
    }
    return table;
}

mixin(staticVar!q{ immutable uint[256] crcTable = buildCrcTable(); });

mixin StaticBlock!q{
    immutable size_t nonZeroEntries = countNonZero(crcTable[]); // reads the line above
    string[] threadLog = ["started"];                          // one per thread
    __gshared size_t threadsSeen = 1;
};

size_t countNonZero(in uint[] xs) pure
{
    size_t n;
    foreach (x; xs)
        n += x != 0;
    return n;
}

uint crc32(in ubyte[] data)
{
    uint c = ~0u;
    foreach (b; data)
        c = crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    return ~c;
}

void main()
{
    threadLog ~= "main ran";
    new Thread({
        threadLog ~= "worker ran";
        writeln("worker log: ", threadLog);
    }).start.join;

    writeln("main log:   ", threadLog);
    writeln("non-zero:   ", nonZeroEntries);
    writeln("crc32:      ", crc32(cast(const(ubyte)[]) "123456789"));
    assert(crc32(cast(const(ubyte)[]) "123456789") == 0xCBF43926);
    assert(threadsSeen == 1);
}
