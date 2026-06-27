/**
 * Shared helper for subprocess-based oracles: run a command, feed one input line
 * per item on stdin, and collect the integer printed on each stdout line. Used
 * by the kitty (Layer 3) and rust unicode-width (Layer 9) oracles — each is "a
 * program that reads hex lines and prints a width per line".
 *
 * stdin/stdout are routed through temp files rather than live pipes: a layer may
 * feed hundreds of thousands of lines (the per-code-point sweep), which would
 * deadlock a write-all-then-read pipe once both kernel buffers fill.
 */
module sparkles.text_conformance.subprocess;

import std.algorithm : map, filter;
import std.array : array;
import std.conv : to;
import std.file : remove, tempDir, write;
import std.path : buildPath;
import std.process : spawnProcess, thisProcessID, wait;
import std.stdio : File;
import std.string : lineSplitter, strip;

private shared size_t _seq;

/// Feed `inputLines` to `cmd` on stdin (one per line) and return the integer on
/// each non-blank stdout line, in order.
int[] runIntPipe(const(string)[] cmd, const(string)[] inputLines)
{
    import core.atomic : atomicOp;
    const tag = thisProcessID.to!string ~ "-" ~ atomicOp!"+="(_seq, 1).to!string;
    const inPath = buildPath(tempDir, "tc-subproc-" ~ tag ~ ".in");
    const outPath = buildPath(tempDir, "tc-subproc-" ~ tag ~ ".out");
    static void tryRemove(string p) nothrow
    {
        try { remove(p); } catch (Exception) {}
    }
    scope (exit) { tryRemove(inPath); tryRemove(outPath); }

    {
        auto inF = File(inPath, "w");
        foreach (line; inputLines)
            inF.writeln(line);
    }

    auto outF = File(outPath, "w");
    auto pid = spawnProcess(cmd, File(inPath, "r"), outF);
    wait(pid);
    outF.close();

    return File(outPath)
        .byLineCopy
        .map!strip
        .filter!(t => t.length > 0)
        .map!(t => t.to!int)
        .array;
}
