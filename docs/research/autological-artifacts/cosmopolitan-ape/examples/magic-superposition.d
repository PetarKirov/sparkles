#!/usr/bin/env dub
/+ dub.sdl:
    name "autological_magic_superposition"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * "Who decides what the file is?" — answered by running every recognizer at once.
 *
 * Format dispatch is usually described one consumer at a time: the kernel checks
 * `\x7fELF`, the shell checks `#!`, a ZIP reader scans backwards for `PK\x05\x06`.
 * A polyglot exists because those checks are **independent predicates over the
 * same bytes**, and nothing arbitrates between them. This program makes that
 * concrete by implementing a small recognizer set and reporting *every* format
 * that claims a given buffer, rather than the first one — which is what a `file(1)`
 * style tool reports, and why `file(1)` is a poor guide to what will actually run.
 *
 * The recognizers are deliberately written the way real dispatchers write them:
 *
 *   - `ELF`, `PNG`, `PDF`, `MZ`, `#!`  — fixed magic at a fixed offset (the
 *     `binfmt_misc` model: magic + mask + offset; see `binfmt-magic-match.d`).
 *   - `ZIP`                            — signature *scanned for*, from the tail.
 *   - `Mach-O` fat binary              — big-endian magic, so it collides with
 *     nothing little-endian at the same offset.
 *   - `SQLite`/`SELF`                  — header magic at 0 plus an
 *     `application_id` at byte 68 (see `../../self-selfdb/examples/sqlite-header-probe.d`).
 *
 * It then runs them over four buffers, ending with a synthesized Actually
 * Portable Executable prologue: the bytes `MZqFpD='` that are simultaneously a
 * DOS/PE `MZ` signature and the start of a POSIX shell assignment, which is the
 * trick at the heart of Cosmopolitan's `ape/ape.S`.
 *
 * The output table is the point: read down a column and you are reading the set
 * of runtimes that will accept one byte stream.
 *
 * Companions:
 *   docs/research/autological-artifacts/cosmopolitan-ape/index.md
 *   docs/research/autological-artifacts/binfmt-misc.md
 *   docs/research/autological-artifacts/polyglot-craft.md
 *
 * Run with: `dub run --single magic-superposition.d`
 *
 * Portability: pure `std`, no I/O beyond stdout. Runs identically everywhere.
 */
module autological_magic_superposition;

import std.algorithm : canFind, filter, map;
import std.array : array, join;
import std.conv : text;
import std.stdio : writefln, writeln;
import std.string : representation;

/++
One recognizer, in the shape every real dispatcher uses.

`offset` + `magic` + `mask` is exactly the `binfmt_misc` registration triple; a
`mask` of all-`0xff` bytes means "match literally". `scanned` marks a recognizer
whose signature is *searched for* rather than found at a fixed offset — the
structural property that separates ZIP from ELF, and the one that makes
suffix-parasitism possible.
+/
struct Recognizer
{
    string name;
    size_t offset;
    immutable(ubyte)[] magic;
    immutable(ubyte)[] mask; // empty == literal match
    bool scanned; // search the whole buffer instead of testing `offset`
    string dispatcher; // who acts on this recognition
}

/// True when `magic` (under `mask`) matches `buf` at `at`.
bool matchesAt(in ubyte[] buf, size_t at, in ubyte[] magic, in ubyte[] mask) @safe pure nothrow @nogc
{
    if (at + magic.length > buf.length)
        return false;
    foreach (i, m; magic)
    {
        const maskByte = mask.length ? mask[i] : 0xff;
        if ((buf[at + i] & maskByte) != (m & maskByte))
            return false;
    }
    return true;
}

/// True when `r` claims `buf`.
bool claims(in Recognizer r, in ubyte[] buf) @safe pure nothrow @nogc
{
    if (!r.scanned)
        return matchesAt(buf, r.offset, r.magic, r.mask);
    // A scanned signature is looked for from the end, because that is where a
    // footer-anchored format puts it and where a trailing-comment-tolerant
    // reader must start.
    if (buf.length < r.magic.length)
        return false;
    for (ptrdiff_t i = cast(ptrdiff_t)(buf.length - r.magic.length); i >= 0; i--)
        if (matchesAt(buf, i, r.magic, r.mask))
            return true;
    return false;
}

immutable Recognizer[] recognizers = [
    Recognizer("ELF", 0, [0x7f, 'E', 'L', 'F'], null, false, "kernel — fs/binfmt_elf.c"),
    Recognizer("PE/MZ", 0, ['M', 'Z'], null, false, "Windows loader / UEFI firmware"),
    Recognizer("shell script", 0, ['#', '!'], null, false, "kernel — fs/binfmt_script.c"),
    Recognizer("sh (no shebang)", 0, ['M', 'Z', 'q', 'F', 'p', 'D', '=', '\''], null, false,
        "POSIX shell — falls back to sh(1) on ENOEXEC"),
    Recognizer("Mach-O fat", 0, [0xca, 0xfe, 0xba, 0xbe], null, false, "XNU — fatfile.c"),
    Recognizer("PNG", 0, [0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a], null, false, "image consumer"),
    Recognizer("PDF", 0, ['%', 'P', 'D', 'F', '-'], null, false, "PDF reader (tolerates a prefix)"),
    Recognizer("SQLite 3", 0, "SQLite format 3\0".representation, null, false, "SQLite library"),
    Recognizer("SELF (SQLite app id)", 68, [0x53, 0x45, 0x4c, 0x46], null, false,
        "kernel — binfmt_misc, magic at offset 68"),
    Recognizer("ZIP", 0, [0x50, 0x4b, 0x05, 0x06], null, true, "ZIP reader — backwards EOCD scan"),
];

/// A named buffer to run the whole recognizer set against.
struct Specimen
{
    string label;
    immutable(ubyte)[] bytes;
    string note;
}

/++
The APE prologue, abbreviated.

Cosmopolitan's real `ape/ape.S` opens with `MZqFpD='` followed by a shell
program. To DOS/PE that is the `MZ` signature and a `e_cblp`/`e_cp` field pair;
to a POSIX shell that received `ENOEXEC` from `execve` it is the start of a
variable assignment, and the shell re-runs the file as a script. Two loaders,
one prefix, no shared bytes wasted.
+/
immutable(ubyte)[] apePrologue() @safe pure
{
    return ("MZqFpD='\n" ~
        "if [ x\"$1\" = x--assimilate ]; then\n" ~
        "  exec \"$0.ape\" \"$@\"\n" ~
        "fi\n" ~
        "'\n").representation ~
        // ...and, much later in the same file, a ZIP central directory + EOCD.
        emptyEocd;
}

/// A well-formed, entry-less End Of Central Directory record.
private immutable(ubyte)[] emptyEocd() @safe pure nothrow
{
    immutable(ubyte)[] eocd = [0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    return eocd;
}

int main()
{
    const specimens = [
        Specimen("plain ELF", elfHeader,
            "one claim — the ordinary case"),
        Specimen("shell script", "#!/bin/sh\necho hi\n".representation,
            "one claim — dispatched by fs/binfmt_script.c"),
        Specimen("SELF database", selfHeader(),
            "two claims — a SQLite file that binfmt_misc also recognizes"),
        Specimen("APE prologue", apePrologue(),
            "three claims — the superposition, deliberately constructed"),
    ];

    writeln("Every recognizer, run against every specimen. A column with more than");
    writeln("one mark is a byte stream in superposition.");
    writeln;

    // Header row.
    writefln("%-24s | %s", "recognizer",
        specimens.map!(s => format4(s.label)).join(" "));
    writefln("%-24s-+-%s", "------------------------",
        specimens.map!(_ => "----------------").join("-"));

    foreach (r; recognizers)
    {
        const marks = specimens
            .map!(s => format4(claims(r, s.bytes) ? "  ✓" : "   "))
            .join(" ");
        writefln("%-24s | %s", r.name, marks);
    }

    writeln;
    foreach (s; specimens)
    {
        const hits = recognizers.filter!(r => claims(r, s.bytes)).map!(r => r.name).array;
        writefln("%s: %s claim(s) — %s", s.label, hits.length, hits.join(", "));
        writefln("    %s", s.note);
    }

    writeln;
    writeln("Dispatchers, by who is holding the bytes:");
    foreach (r; recognizers.filter!(r => claims(r, apePrologue())))
        writefln("  %-24s -> %s", r.name, r.dispatcher);

    writeln;
    writeln("Note the shape of the disagreement: the fixed-offset recognizers all");
    writeln("read byte 0, and the scanned one reads the tail. A format that anchors");
    writeln("its index at neither end has nothing left to share.");

    return 0;
}

/// The first eight bytes of any 64-bit little-endian ELF image.
immutable(ubyte)[] elfHeader() @safe pure nothrow
{
    immutable(ubyte)[] e = [0x7f, 'E', 'L', 'F', 2, 1, 1, 0];
    return e;
}

/// A minimal SQLite header carrying `SELF` in the `application_id` field.
immutable(ubyte)[] selfHeader() @safe pure
{
    auto h = new ubyte[100];
    h[0 .. 16] = "SQLite format 3\0".representation;
    h[16] = 0x10;
    h[17] = 0x00; // page size 4096, big-endian
    h[68 .. 72] = "SELF".representation; // application_id
    return h.idup;
}

/// Pads a cell to a fixed width so the table columns line up.
string format4(string s) @safe pure
{
    import std.array : replicate;
    import std.utf : count;

    enum width = 16;
    const len = s.count;
    return len >= width ? s : s ~ " ".replicate(width - len);
}
