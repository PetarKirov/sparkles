#!/usr/bin/env dub
/+ dub.sdl:
    name "check_sync_fast_path"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Oracle 11 of `docs/specs/base/sync/testing.md`: in the `checked` build, the
uncontended `lock` and `unlock` of `Mutex` and `LockBits` compile to one
atomic read–modify–write and a branch, with no call, on x86-64 and arm64
(SYM2, DS12).

The tool compiles a probe of the four operations with LDC for both targets,
as assembly, and checks that each has a path from its entry to a return that
performs exactly one atomic read–modify–write and no call. The pin's
thread-local access is position-independent code here — a TLS-descriptor or
`__tls_get_addr` sequence — which the linker relaxes to a thread-pointer
offset in an executable, so it is not counted as a call. Run it from the
repository root:

    dub run --single --temp-build libs/base/tools/check-sync-fast-path.d
*/
module check_sync_fast_path;

import std.algorithm : canFind, countUntil, endsWith, splitter, startsWith;
import std.array : array, join;
import std.file : readText, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writefln, writeln;
import std.string : lineSplitter, strip;

enum probe = q{
module sync_fast_path_probe;

import sparkles.base.sync : LockBits, Mutex;

extern (C) void probeMutexLock(Mutex* m) @safe nothrow @nogc { m.lock(); }
extern (C) void probeMutexUnlock(Mutex* m) @safe nothrow @nogc { m.unlock(); }

alias Bits = LockBits!(uint, 1, 2, 4);
extern (C) void probeBitsLock(shared(uint)* w) @safe nothrow @nogc { Bits.lock(*w); }
extern (C) void probeBitsUnlock(shared(uint)* w) @safe nothrow @nogc { Bits.unlock(*w); }
};

struct Target
{
    string triple;
    /// Mnemonics that perform an atomic read–modify–write: x86's `lock`
    /// prefix; arm64's LSE `cas*`/`ldadd*`/`swp*`, or the load-exclusive that
    /// opens a load-linked/store-conditional loop.
    string[] atomics;
    string[] calls;
}

immutable Target[] targets = [
    Target("x86_64-unknown-linux-gnu", ["lock"], ["call", "callq"]),
    Target("aarch64-unknown-linux-gnu", ["cas", "casa", "casl", "casal", "casb", "casab",
        "caslb", "casalb", "ldaxr", "ldxr", "ldaxrb", "ldxrb", "swp", "ldadd"], ["bl", "blr"]),
];

int main()
{
    const dir = tempDir;
    const src = buildPath(dir, "sync_fast_path_probe.d");
    write(src, probe);
    bool ok = true;
    foreach (t; targets)
    {
        const asmFile = buildPath(dir, "sync_fast_path_probe." ~ t.triple ~ ".s");
        // -linkonce-templates as base builds: Mutex's members are template
        // instances, emitted where they are used and so inlinable there.
        const r = execute(["ldc2", "-mtriple=" ~ t.triple, "-O", "-g", "-linkonce-templates",
            "-preview=in", "-preview=dip1000", "-Ilibs/base/src", "-output-s", "-of=" ~ asmFile,
            "-c", src]);
        if (r.status != 0)
        {
            writeln(r.output);
            return 1;
        }
        const text = readText(asmFile);
        foreach (fn; ["probeMutexLock", "probeMutexUnlock", "probeBitsLock", "probeBitsUnlock"])
        {
            const blocks = parseBlocks(text, fn);
            auto seen = new bool[blocks.length];
            const pass = blocks.length && fastPath(blocks, t, 0, 0, 0, seen);
            ok &= pass;
            writefln("%-26s %-17s %s", t.triple, fn,
                pass ? "ok: one atomic and no call on the path to its return" : "FAIL");
            if (!pass)
                foreach (b; blocks)
                    writeln(b.label, ":\n\t", b.lines.join("\n\t"));
        }
    }
    return ok ? 0 : 1;
}

struct Block
{
    string label;
    string[] lines;
}

/// The basic blocks of `fn`, up to the end of its body.
Block[] parseBlocks(string text, string fn)
{
    Block[] blocks;
    bool inside;
    foreach (line; text.lineSplitter)
    {
        const s = line.strip;
        if (!inside)
        {
            if (line.startsWith(fn ~ ":"))
            {
                inside = true;
                blocks ~= Block(fn);
            }
            continue;
        }
        if (s.startsWith(".Lfunc_end"))
            break;
        if (s.endsWith(":") && s.startsWith(".L"))
        {
            blocks ~= Block(s[0 .. $ - 1].idup);
            continue;
        }
        if (s.length == 0 || s.startsWith(".") || s.startsWith("#") || s.startsWith("//"))
            continue;
        blocks[$ - 1].lines ~= s.idup;
    }
    return blocks;
}

/// Whether `line` belongs to a thread-local variable's access sequence.
bool isTlsAccess(string line)
    => line.canFind("__tls_get_addr") || line.canFind("tlsdesc") || line.canFind("TLSGD")
        || line.canFind(":tprel") || line.canFind("tpidr_el0");

string mnemonic(string line) => line.splitter!(c => c == ' ' || c == '\t').front;

/**
Whether some path from block `i` to a return performs exactly one atomic
read–modify–write and no call, given the counts so far. A loop's back edge
is never taken twice, so a load-linked/store-conditional loop counts once.
*/
bool fastPath(const Block[] blocks, ref const Target t, size_t i, uint atomics, uint calls, bool[] seen)
{
    if (i >= blocks.length || seen[i])
        return false;
    seen[i] = true;
    scope (exit)
        seen[i] = false;
    bool tlsCall; // the next indirect call is a TLS descriptor's resolver
    foreach (l; blocks[i].lines)
    {
        const ins = mnemonic(l);
        if (t.atomics.canFind(ins))
            ++atomics;
        if (l.canFind(":tlsdesc"))
            tlsCall = true;
        if (t.calls.canFind(ins) && !isTlsAccess(l) && !(tlsCall && ins == "blr"))
            ++calls;
        if (ins == "blr")
            tlsCall = false;
        if (ins.startsWith("ret"))
            return atomics == 1 && calls == 0;
        if (isBranch(ins))
        {
            const parts = l.splitter!(c => c == ' ' || c == '\t' || c == ',').array;
            const target = parts[$ - 1];
            const j = blocks.countUntil!(b => b.label == target);
            if (j >= 0 && fastPath(blocks, t, j, atomics, calls, seen))
                return true;
            if (ins == "jmp" || ins == "b")
                return false;
        }
    }
    return fastPath(blocks, t, i + 1, atomics, calls, seen);
}

bool isBranch(string ins)
    => ins.startsWith("j") || ins.startsWith("b.") || ins == "b" || ins == "cbz"
        || ins == "cbnz" || ins == "tbz" || ins == "tbnz";
