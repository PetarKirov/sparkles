#!/usr/bin/env dub
/+ dub.sdl:
    name "autological_sqlite_header_probe"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The 100-byte header that lets a database be an executable.
 *
 * SQLite reserves the first 100 bytes of every database file for a fixed-layout
 * header, and two of its fields are what make the SELF format possible at all:
 *
 *   - **`application_id`**, a 4-byte big-endian integer at **offset 68**. SQLite
 *     itself never interprets it; the documentation's stated purpose is to let
 *     `file(1)`-style tools identify *which application's* database this is. A
 *     `binfmt_misc` registration with `offset=68` and a 4-byte magic therefore
 *     dispatches on a field the storage engine has promised not to touch.
 *   - **`page_size`** at offset 16, big-endian, which decides whether segment
 *     BLOBs can ever be page-aligned — the crux of the lost-`mmap` problem.
 *
 * This program decodes the header of whatever files are passed on the command
 * line, and — with no arguments — of a synthesized SELF header plus the local
 * SQLite databases it can find, so it is useful with or without a corpus.
 *
 * The `Reserved space at end of each page` field (offset 20) is decoded too,
 * because it is the one the "segments in SQLite's reserved region" repair
 * candidate would have to use, and seeing it default to `0` makes the size of
 * that proposal concrete.
 *
 * Companions:
 *   docs/research/autological-artifacts/self-selfdb/index.md
 *   docs/research/autological-artifacts/sqlite-application-file-format.md
 *   docs/research/autological-artifacts/binfmt-misc.md
 *
 * Run with: `dub run --single sqlite-header-probe.d [FILE...]`
 *
 * Portability: pure `std`. Files that are not SQLite databases are reported as
 * such rather than treated as an error, so the program always exits 0.
 */
module autological_sqlite_header_probe;

import std.algorithm : filter, map;
import std.array : array;
import std.conv : text;
import std.file : exists, isFile, read;
import std.stdio : writefln, writeln;
import std.string : representation;

/// The header magic every SQLite 3 database opens with, `NUL` included.
enum string sqliteMagic = "SQLite format 3\0";

/++
The subset of the 100-byte header this catalog cares about.

Offsets are from the SQLite file-format documentation; every multi-byte integer
in the header is **big-endian**, which is worth stating because the rest of the
formats in this tree (ZIP, ELF, PE) are little-endian, and a polyglot has to
keep both straight.
+/
struct SqliteHeader
{
    ushort pageSizeRaw; // offset 16; 1 means 65536
    ubyte writeVersion; // offset 18; 1 = legacy, 2 = WAL
    ubyte readVersion; // offset 19
    ubyte reservedPerPage; // offset 20
    uint changeCounter; // offset 24
    uint sizeInPages; // offset 28
    uint schemaCookie; // offset 40
    uint textEncoding; // offset 56; 1 = UTF-8, 2 = UTF-16le, 3 = UTF-16be
    uint userVersion; // offset 60
    uint applicationId; // offset 68
    uint sqliteVersionNumber; // offset 96

    /// The real page size, resolving the documented `1 == 65536` escape.
    uint pageSize() const @safe pure nothrow @nogc
        => pageSizeRaw == 1 ? 65_536 : pageSizeRaw;

    /// `application_id` rendered as the four ASCII bytes tools usually put there.
    string applicationTag() const @safe pure
    {
        char[4] tag;
        foreach (i; 0 .. 4)
        {
            const b = cast(ubyte)(applicationId >> (8 * (3 - i)));
            tag[i] = (b >= 0x20 && b < 0x7f) ? cast(char) b : '.';
        }
        return tag.idup;
    }
}

/// Reads a big-endian `uint` at `offset`.
uint beU32(in ubyte[] b, size_t offset) @safe pure nothrow @nogc
in (offset + 4 <= b.length)
    => (uint(b[offset]) << 24) | (uint(b[offset + 1]) << 16)
        | (uint(b[offset + 2]) << 8) | uint(b[offset + 3]);

/// Reads a big-endian `ushort` at `offset`.
ushort beU16(in ubyte[] b, size_t offset) @safe pure nothrow @nogc
in (offset + 2 <= b.length)
    => cast(ushort)((ushort(b[offset]) << 8) | b[offset + 1]);

/// True when `b` opens with the SQLite 3 header magic.
bool isSqlite(in ubyte[] b) @safe pure nothrow @nogc
    => b.length >= 100 && b[0 .. 16] == sqliteMagic.representation;

/// Decodes the header fields this catalog reads.
SqliteHeader decode(in ubyte[] b) @safe pure nothrow @nogc
in (isSqlite(b))
{
    SqliteHeader h;
    h.pageSizeRaw = beU16(b, 16);
    h.writeVersion = b[18];
    h.readVersion = b[19];
    h.reservedPerPage = b[20];
    h.changeCounter = beU32(b, 24);
    h.sizeInPages = beU32(b, 28);
    h.schemaCookie = beU32(b, 40);
    h.textEncoding = beU32(b, 56);
    h.userVersion = beU32(b, 60);
    h.applicationId = beU32(b, 68);
    h.sqliteVersionNumber = beU32(b, 96);
    return h;
}

/// Renders one decoded header as the catalog wants to read it.
void report(string label, in SqliteHeader h) @safe
{
    writefln("%s", label);
    writefln("  page size (off 16)          %s bytes%s", h.pageSize,
        h.pageSize >= 4096 ? "  (>= a 4 KiB VM page — alignment is at least possible)"
            : "  (< a 4 KiB VM page — a page-aligned BLOB cannot fit one VM page)");
    writefln("  write/read version (18/19)  %s / %s%s", h.writeVersion, h.readVersion,
        h.writeVersion == 2 ? "  (WAL)" : "  (rollback journal)");
    writefln("  reserved per page (off 20)  %s bytes%s", h.reservedPerPage,
        h.reservedPerPage == 0 ? "  (the region a 'segments in reserved space' design would claim)" : "");
    writefln("  change counter (off 24)     %s", h.changeCounter);
    writefln("  size in pages (off 28)      %s  => %s bytes of database",
        h.sizeInPages, ulong(h.sizeInPages) * h.pageSize);
    writefln("  text encoding (off 56)      %s (%s)", h.textEncoding, encodingName(h.textEncoding));
    writefln("  user_version (off 60)       %s", h.userVersion);
    writefln("  application_id (off 68)     0x%08x  '%s'%s", h.applicationId, h.applicationTag,
        h.applicationId == 0 ? "  (unset — no binfmt_misc handle)"
            : "  <-- the 4 bytes binfmt_misc can match on at offset 68");
    writefln("  sqlite_version (off 96)     %s", h.sqliteVersionNumber);
    writeln;
}

/// Maps the documented text-encoding constants to names.
string encodingName(uint e) @safe pure nothrow @nogc
{
    switch (e)
    {
    case 0:
        return "unset";
    case 1:
        return "UTF-8";
    case 2:
        return "UTF-16le";
    case 3:
        return "UTF-16be";
    default:
        return "invalid";
    }
}

/++
Synthesizes the header a SELF-style artifact would carry.

Nothing here is guesswork about SELF's internals: it is the *minimum* a file
needs so that (a) SQLite opens it and (b) a `binfmt_misc` rule keyed on
`offset=68, magic=SELF` selects an interpreter for it.
+/
immutable(ubyte)[] synthesize() @safe pure
{
    auto h = new ubyte[100];
    h[0 .. 16] = sqliteMagic.representation;
    h[16] = 0x10;
    h[17] = 0x00; // page_size = 4096
    h[18] = 1; // write version: legacy rollback journal
    h[19] = 1; // read version
    h[20] = 0; // reserved space per page
    h[28] = 0;
    h[31] = 4; // size in pages = 4
    h[56 + 3] = 1; // text encoding = UTF-8
    h[68 .. 72] = "SELF".representation; // application_id
    return h.idup;
}

int main(string[] args)
{
    writeln("SQLite header probe — offset 68 is the byte that makes a database dispatchable.");
    writeln;

    report("synthesized SELF-style header (not read from disk)", decode(synthesize()));

    auto candidates = args.length > 1
        ? args[1 .. $]
        : ["/var/lib/dbus/machine-id.sqlite", "test.db"].filter!exists.array;

    if (candidates.length == 0)
    {
        writeln("SKIP: no database files given or found locally — pass paths as arguments");
        writeln("      to decode real headers (e.g. any *.sqlite / *.db on this machine).");
        return 0;
    }

    foreach (path; candidates)
    {
        if (!path.exists || !path.isFile)
        {
            writefln("%s: not a readable file — skipped", path);
            continue;
        }
        const bytes = cast(ubyte[]) read(path, 100);
        if (!isSqlite(bytes))
        {
            writefln("%s: not a SQLite database (first 16 bytes are not the header magic)", path);
            writeln;
            continue;
        }
        report(path, decode(bytes));
    }

    return 0;
}
