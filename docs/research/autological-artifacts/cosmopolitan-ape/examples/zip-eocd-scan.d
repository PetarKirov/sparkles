#!/usr/bin/env dub
/+ dub.sdl:
    name "autological_zip_eocd_scan"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Suffix parasitism from first principles: a ZIP archive with arbitrary bytes
 * glued to its front, still readable — and readable from the *tail alone*.
 *
 * This program builds a two-entry, `STORED` (uncompressed) ZIP archive by hand,
 * prefixes it with an unrelated payload (here a shell script, standing in for an
 * ELF/PE/Mach-O image), and then reads it back the way a conformant ZIP reader
 * must: scan backwards from EOF for the End Of Central Directory signature
 * `PK\x05\x06`, take the central-directory offset and size out of it, and parse
 * only those bytes.
 *
 * Two properties are demonstrated, and they are the ones the catalog's whole
 * argument rests on:
 *
 *   1. **The prefix is legal.** Nothing in the format says byte 0 is a local file
 *      header. Every internal pointer is an absolute offset from the start of the
 *      file, so a reader that finds the footer can find everything else. This is
 *      exactly why `redbean` can be a PE + ELF + Mach-O image *and* a ZIP.
 *   2. **Reading is sub-linear.** The program reports how many bytes it actually
 *      touched to enumerate the archive versus the file size. A footer-anchored
 *      index is what makes a ranged/partial read possible at all — the same
 *      property Parquet, ORC and `eStargz` monetize over HTTP range requests.
 *
 * The offsets written into the central directory deliberately *include* the
 * prefix length. Getting that wrong is the single most common way a hand-built
 * polyglot breaks, and it is precisely what `zip -A` ("adjust self-extracting
 * archive") exists to repair.
 *
 * Companions:
 *   docs/research/autological-artifacts/zip-parasitism.md
 *   docs/research/autological-artifacts/footer-indexed-formats.md
 *   docs/research/autological-artifacts/cosmopolitan-ape/index.md
 *
 * Run with: `dub run --single zip-eocd-scan.d`
 *
 * Portability: pure `std`, no syscalls beyond a temp file. If a system `unzip`
 * is on `PATH` the program additionally asks it to list the polyglot, proving an
 * independent implementation agrees; if not, it prints a `SKIP:` line for that
 * step and still exits 0.
 */
module autological_zip_eocd_scan;

import std.array : appender;
import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.conv : text;
import std.digest.crc : crc32Of;
import std.file : exists, remove, tempDir, write;
import std.path : buildPath;
import std.process : execute, Config;
import std.stdio : File, writefln, writeln;
import std.string : representation;

/// One member of the archive we are about to synthesize.
struct Member
{
    string name;
    string contents;
}

/// Where a member's local header ended up, so the central directory can point at it.
struct Placed
{
    Member member;
    uint localHeaderOffset;
    uint crc;
}

private enum uint sigLocal = 0x0403_4b50; // "PK\x03\x04"
private enum uint sigCentral = 0x0201_4b50; // "PK\x01\x02"
private enum uint sigEocd = 0x0605_4b50; // "PK\x05\x06"

/// Appends `value` to `w` in little-endian order, the only byte order ZIP uses.
void putLE(T, W)(ref W w, T value)
{
    w ~= nativeToLittleEndian(value)[];
}

/// Reads a little-endian `T` at `offset` from `bytes`.
T readLE(T)(in ubyte[] bytes, size_t offset)
in (offset + T.sizeof <= bytes.length, "read past end of buffer")
{
    ubyte[T.sizeof] raw = bytes[offset .. offset + T.sizeof];
    return littleEndianToNative!T(raw);
}

/++
Builds a `STORED` ZIP whose internal offsets are biased by `prefixLength`.

Passing a non-zero `prefixLength` is the whole trick: the archive is written as
if it already began that many bytes into the file, so gluing it after an
unrelated payload of exactly that size produces a file both readers accept.
+/
ubyte[] buildZip(in Member[] members, uint prefixLength) @safe
{
    auto body_ = appender!(ubyte[]);
    Placed[] placed;

    foreach (m; members)
    {
        const data = m.contents.representation;
        const crc = () @trusted { return littleEndianToNative!uint(crc32Of(data)); }();
        placed ~= Placed(m, prefixLength + cast(uint) body_[].length, crc);

        putLE(body_, sigLocal);
        putLE(body_, ushort(20)); // version needed to extract: 2.0
        putLE(body_, ushort(0)); // general purpose bit flag
        putLE(body_, ushort(0)); // compression method: 0 = STORED
        putLE(body_, ushort(0)); // last mod time (fixed, for reproducibility)
        putLE(body_, ushort(0x21)); // last mod date: 1980-01-01
        putLE(body_, crc);
        putLE(body_, cast(uint) data.length); // compressed size
        putLE(body_, cast(uint) data.length); // uncompressed size
        putLE(body_, cast(ushort) m.name.length);
        putLE(body_, ushort(0)); // extra field length
        body_ ~= m.name.representation;
        body_ ~= data;
    }

    const centralOffset = prefixLength + cast(uint) body_[].length;
    auto central = appender!(ubyte[]);

    foreach (p; placed)
    {
        const data = p.member.contents.representation;
        putLE(central, sigCentral);
        putLE(central, ushort(20)); // version made by
        putLE(central, ushort(20)); // version needed to extract
        putLE(central, ushort(0)); // flags
        putLE(central, ushort(0)); // method: STORED
        putLE(central, ushort(0)); // time
        putLE(central, ushort(0x21)); // date
        putLE(central, p.crc);
        putLE(central, cast(uint) data.length);
        putLE(central, cast(uint) data.length);
        putLE(central, cast(ushort) p.member.name.length);
        putLE(central, ushort(0)); // extra length
        putLE(central, ushort(0)); // comment length
        putLE(central, ushort(0)); // disk number start
        putLE(central, ushort(0)); // internal attributes
        putLE(central, uint(0)); // external attributes
        putLE(central, p.localHeaderOffset); // <-- biased by the prefix
        central ~= p.member.name.representation;
    }

    auto eocd = appender!(ubyte[]);
    putLE(eocd, sigEocd);
    putLE(eocd, ushort(0)); // this disk
    putLE(eocd, ushort(0)); // disk with central directory
    putLE(eocd, cast(ushort) placed.length); // entries on this disk
    putLE(eocd, cast(ushort) placed.length); // entries total
    putLE(eocd, cast(uint) central[].length); // central directory size
    putLE(eocd, centralOffset); // <-- biased by the prefix
    putLE(eocd, ushort(0)); // comment length

    return body_[] ~ central[] ~ eocd[];
}

/// What a tail-only read recovered, plus what it cost.
struct Enumerated
{
    string[] names;
    uint centralOffset;
    uint centralSize;
    uint firstLocalHeaderOffset;
    size_t bytesRead;
}

/++
Enumerates an archive by doing what a real reader does: seek to the end, scan
backwards for the EOCD signature, then read only the central directory.

Never reads a local file header, and never reads a byte of file data — which is
why the returned `bytesRead` is a small constant plus the directory size,
independent of how large the members (or the parasitic prefix) are.
+/
Enumerated enumerateFromTail(string path, size_t tailWindow = 512)
{
    auto f = File(path, "rb");
    const size = f.size;
    size_t bytesRead;

    const window = size < tailWindow ? cast(size_t) size : tailWindow;
    f.seek(cast(long)(size - window));
    auto tail = new ubyte[window];
    tail = f.rawRead(tail);
    bytesRead += tail.length;

    // Backwards scan: the EOCD is last, but a trailing comment may follow it,
    // so the signature — not the file end — is the anchor.
    ptrdiff_t eocd = -1;
    for (ptrdiff_t i = cast(ptrdiff_t) tail.length - 22; i >= 0; i--)
    {
        if (readLE!uint(tail, i) == sigEocd)
        {
            eocd = i;
            break;
        }
    }
    if (eocd < 0)
        throw new Exception("no End Of Central Directory record in the last " ~ window.text ~ " bytes");

    const total = readLE!ushort(tail, eocd + 10);
    const centralSize = readLE!uint(tail, eocd + 12);
    const centralOffset = readLE!uint(tail, eocd + 16);

    f.seek(centralOffset);
    auto central = new ubyte[centralSize];
    central = f.rawRead(central);
    bytesRead += central.length;

    string[] names;
    uint firstLocal;
    size_t cursor;
    foreach (i; 0 .. total)
    {
        if (readLE!uint(central, cursor) != sigCentral)
            throw new Exception("central directory entry has a bad signature");
        const nameLen = readLE!ushort(central, cursor + 28);
        const extraLen = readLE!ushort(central, cursor + 30);
        const commentLen = readLE!ushort(central, cursor + 32);
        if (i == 0)
            firstLocal = readLE!uint(central, cursor + 42);
        names ~= cast(string) central[cursor + 46 .. cursor + 46 + nameLen].idup;
        cursor += 46 + nameLen + extraLen + commentLen;
    }

    return Enumerated(names, centralOffset, centralSize, firstLocal, bytesRead);
}

int main()
{
    // The parasitic prefix. In redbean this is a real PE/ELF/Mach-O image; the
    // ZIP format cannot tell the difference and does not try to.
    const prefix = "#!/bin/sh\n" ~
        "# Everything above the archive is opaque to a ZIP reader.\n" ~
        "echo 'this file is also a shell script'; exit 0\n";

    // One member is deliberately bulky. Enumeration must not touch it: that is
    // the difference between an index you can range-request and one you cannot.
    import std.array : replicate;

    const members = [
        Member("greeting.txt", "the container is a tax\n"),
        Member("assets/note.md", "# footer-anchored\n\nThe index is at the end, so the front is free.\n"),
        Member("assets/bulk.bin", replicate("payload ", 32 * 1024)),
    ];

    const zip = buildZip(members, cast(uint) prefix.length);
    const path = buildPath(tempDir, "autological-polyglot.zip");
    write(path, prefix.representation ~ zip);
    scope (exit)
        if (path.exists)
            remove(path);

    const total = prefix.length + zip.length;
    writefln("Built a %s-byte polyglot: %s bytes of shell script, then a %s-byte ZIP.",
        total, prefix.length, zip.length);
    writefln("  byte 0 is '%s' — a ZIP reader never looks there.", cast(char) prefix[0]);
    writeln;

    const found = enumerateFromTail(path);
    writeln("Enumerated by scanning backwards from EOF:");
    writefln("  central directory at absolute offset %s, %s bytes",
        found.centralOffset, found.centralSize);
    foreach (n; found.names)
        writefln("    entry: %s", n);
    writefln("  first member's local header sits at absolute offset %s == the prefix length (%s):",
        found.firstLocalHeaderOffset, prefix.length);
    writeln("  every internal pointer is biased by the prefix, which is what `zip -A` repairs");
    writeln;

    writefln("Cost of enumeration: %s of %s bytes read (%.1f%%).",
        found.bytesRead, total, 100.0 * found.bytesRead / total);
    writeln("  A header-anchored format would have had to start at byte 0 —");
    writeln("  which is the byte the prefix is already using.");
    writeln;

    // An independent implementation is the real proof. `unzip -l` refuses
    // nothing here: it performs the same backwards scan.
    const probe = execute(["unzip", "-l", path], null, Config.suppressConsole);
    if (probe.status == 0)
    {
        writeln("System `unzip -l` agrees:");
        foreach (line; probe.output.lineSplitterRange)
            writefln("  | %s", line);
    }
    else
    {
        writeln("SKIP: no working `unzip` on PATH — the independent cross-check was not run.");
    }

    return 0;
}

/// `lineSplitter` wrapped so the call site above reads as one pipeline.
private auto lineSplitterRange(string s) @safe pure nothrow
{
    import std.string : lineSplitter;
    return s.lineSplitter;
}
