#!/usr/bin/env dub
/+ dub.sdl:
    name "font_libraries_font_scan_timing"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * How long does describing every font on a machine take? For each file
 * (`.ttf`, `.otf`, and every face of a `.ttc`/`.otc` collection) this reads
 * what a font catalog records per face — the table directory, the family name
 * from `name`, the weight class from `OS/2`, and the code-point coverage of
 * the best Unicode `cmap` subtable as a range count — through `mmap`, so only
 * the pages those tables live on are touched.
 *
 * It times one serial pass, a second serial pass, and two passes over a
 * `std.parallelism` pool. The first pass is cold only for files no process has
 * read since boot: eviction needs root (and on ZFS the ARC ignores
 * `posix_fadvise`), so the program does not try.
 *
 * Spike S1 of docs/specs/font/PLAN.md; decision FTX8 in
 * docs/specs/font/decisions.md records the result.
 *
 * Run with: dub run --single font-scan-timing.d [-- list-of-paths.txt]
 *
 * Font resolution: the argument names a file with one font path per line;
 * without it the program asks `fc-list : file`. If neither yields a font, it
 * prints a `SKIP:` line and exits 0 so CI stays green.
 */
module font_libraries_font_scan_timing;

import core.sys.posix.fcntl : open, O_RDONLY;
import core.sys.posix.sys.mman : MAP_FAILED, MAP_PRIVATE, mmap, munmap, PROT_READ;
import core.sys.posix.sys.stat : fstat, stat_t;
import core.sys.posix.unistd : close;
import std.algorithm : count, endsWith, filter, joiner, map, sort, sum, uniq;
import std.array : array, split;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, readText;
import std.parallelism : parallel;
import std.process : execute;
import std.range : walkLength;
import std.stdio : writefln, writeln;
import std.string : lineSplitter, strip, toStringz;

/// What a catalog keeps per face.
struct FaceRecord
{
    string family;
    uint weightClass;
    uint codepoints, ranges;
    bool hasCmap;
}

uint u16(const(ubyte)[] d, size_t o) @safe pure nothrow @nogc
    => o + 2 <= d.length ? (d[o] << 8) | d[o + 1] : 0;

uint u32(const(ubyte)[] d, size_t o) @safe pure nothrow @nogc
    => o + 4 <= d.length
        ? (uint(d[o]) << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3] : 0;

/// The table `tag` of the face whose directory starts at `dir`, or `null`.
const(ubyte)[] table(const(ubyte)[] d, size_t dir, string tag) @safe pure nothrow @nogc
{
    const t = (uint(tag[0]) << 24) | (tag[1] << 16) | (tag[2] << 8) | tag[3];
    foreach (i; 0 .. u16(d, dir + 4))
    {
        const r = dir + 12 + i * 16;
        if (u32(d, r) != t)
            continue;
        const off = size_t(u32(d, r + 8)), len = size_t(u32(d, r + 12));
        return off + len <= d.length ? d[off .. off + len] : null;
    }
    return null;
}

/// Counts the code points and ranges of the best Unicode subtable:
/// format 12 (full repertoire) over format 4 (BMP).
void readCoverage(const(ubyte)[] cmap, ref FaceRecord rec) @safe pure nothrow @nogc
{
    size_t best;
    int bestScore;
    foreach (i; 0 .. u16(cmap, 2))
    {
        const platform = u16(cmap, 4 + i * 8), encoding = u16(cmap, 6 + i * 8);
        const off = u32(cmap, 8 + i * 8), format = u16(cmap, off);
        const unicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10));
        const score = !unicode ? 0 : format == 12 ? 2 : format == 4 ? 1 : 0;
        if (score > bestScore)
        {
            bestScore = score;
            best = off;
        }
    }
    rec.hasCmap = bestScore > 0;
    uint next = uint.max;
    void add(uint lo, uint hi)
    {
        rec.codepoints += hi - lo + 1;
        if (lo != next)
            ++rec.ranges;
        next = hi + 1;
    }
    if (bestScore == 1)
    {
        const segX2 = u16(cmap, best + 6);
        foreach (s; 0 .. segX2 / 2)
        {
            const end = u16(cmap, best + 14 + s * 2), start = u16(cmap, best + 16 + segX2 + s * 2);
            if (start <= end && start != 0xFFFF)
                add(start, end);
        }
    }
    else if (bestScore == 2)
        foreach (g; 0 .. u32(cmap, best + 12))
        {
            const lo = u32(cmap, best + 16 + g * 12), hi = u32(cmap, best + 20 + g * 12);
            if (lo <= hi && hi <= 0x10FFFF)
                add(lo, hi);
        }
}

/// The typographic family (name ID 16), else the family (ID 1), Windows platform.
string familyName(const(ubyte)[] name) @safe pure
{
    const strings = u16(name, 4);
    string found;
    foreach (i; 0 .. u16(name, 2))
    {
        const r = 6 + i * 12, id = u16(name, r + 6);
        if (u16(name, r) != 3 || (id != 1 && id != 16))
            continue;
        const start = strings + u16(name, r + 10), len = u16(name, r + 8);
        if (start + len > name.length)
            continue;
        wchar[] utf16;
        foreach (k; 0 .. len / 2)
            utf16 ~= cast(wchar) u16(name, start + k * 2);
        found = utf16.to!string;
        if (id == 16)
            break;
    }
    return found;
}

FaceRecord[] describe(const(ubyte)[] d) @safe pure
{
    size_t[] dirs = u32(d, 0) == 0x74746366 // 'ttcf'
        ? (size_t n) { size_t[] r; foreach (i; 0 .. n) r ~= u32(d, 12 + i * 4); return r; }(u32(d, 8))
        : [size_t(0)];
    FaceRecord[] faces;
    foreach (dir; dirs)
    {
        FaceRecord rec;
        readCoverage(table(d, dir, "cmap"), rec);
        rec.family = familyName(table(d, dir, "name"));
        rec.weightClass = u16(table(d, dir, "OS/2"), 4);
        faces ~= rec;
    }
    return faces;
}

FaceRecord[] scanFile(string path) @trusted
{
    const fd = open(path.toStringz, O_RDONLY);
    if (fd < 0)
        return null;
    scope (exit) close(fd);
    stat_t st;
    if (fstat(fd, &st) != 0 || st.st_size < 12)
        return null;
    auto p = mmap(null, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED)
        return null;
    scope (exit) munmap(p, st.st_size);
    return describe((cast(const(ubyte)*) p)[0 .. st.st_size]);
}

void pass(string label, string[] paths, bool pooled)
{
    auto records = new FaceRecord[][](paths.length);
    auto sw = StopWatch(AutoStart.yes);
    if (pooled)
        foreach (i, path; paths.parallel(4))
            records[i] = scanFile(path);
    else
        foreach (i, path; paths)
            records[i] = scanFile(path);
    const ms = sw.peek.total!"usecs" / 1000.0;
    auto faces = records.joiner.array;
    writefln("%-16s %5d files  %5d faces  %8.1f ms  %6.1f us/file  %4d families  %d code points",
        label, paths.length, faces.length, ms, ms * 1000 / paths.length,
        faces.map!(f => f.family).array.sort.uniq.walkLength,
        faces.map!(f => ulong(f.codepoints)).sum);
}

string[] fontPaths(string[] args)
{
    string listing;
    if (args.length > 1 && exists(args[1]))
        listing = readText(args[1]);
    else
        try
        {
            auto r = execute(["fc-list", ":", "file"]);
            if (r.status == 0)
                listing = r.output;
        }
        catch (Exception) {}
    return listing.lineSplitter
        .map!(l => l.split(":")[0].strip)
        .filter!(p => p.endsWith(".ttf", ".otf", ".ttc", ".otc") && exists(p))
        .array.sort.uniq.array;
}

int main(string[] args)
{
    auto paths = fontPaths(args);
    if (!paths.length)
    {
        writeln("SKIP: no font files found (pass a list, or install fontconfig)");
        return 0;
    }
    pass("first, serial", paths, false);
    pass("warm, serial", paths, false);
    pass("warm, 4 workers", paths, true);
    pass("warm, 4 workers", paths, true);
    return 0;
}
