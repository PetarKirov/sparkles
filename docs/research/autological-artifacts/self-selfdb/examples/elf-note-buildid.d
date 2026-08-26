#!/usr/bin/env dub
/+ dub.sdl:
    name "autological_elf_note_buildid"
    targetPath "build"
    platforms "linux"
    lflags "--build-id"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Reflexivity with no query engine: a program reading its own provenance out of
 * its own image.
 *
 * This is the weakest interesting point on the reflexivity axis, and it is worth
 * having precisely because it is *already deployed everywhere*. Every ELF
 * toolchain on Linux emits a `PT_NOTE` segment; `ld --build-id` puts a hash of
 * the linked image in an `NT_GNU_BUILD_ID` note inside it; and `debuginfod`
 * turns that hash into a network-resolvable key for the separated debug info.
 * The artifact carries a stable name for itself, and nothing had to change
 * about the format for that to be true.
 *
 * The program opens `/proc/self/exe` — its own bytes, as the running kernel
 * resolved them — walks the program headers to every `PT_NOTE` segment, and
 * decodes each note: `n_namesz`, `n_descsz`, `n_type`, then the 4-byte-aligned
 * name and descriptor. It reports the build-id, the ABI-tag note (which encodes
 * the minimum kernel version the image was linked for), and any vendor notes it
 * finds, such as Fedora's `.note.package` JSON.
 *
 * The catalog's point: this is a **stream-scanned, out-of-band-resolved** index.
 * Notes are found by walking a table, the payload they name lives somewhere else
 * entirely, and the toolchain maintains the correspondence by convention. That
 * is the arrangement thesis 2 says formats without self-description accrete —
 * and comparing the code below with a `SELECT` against a `notes` table is the
 * cheapest possible statement of what a schema would buy.
 *
 * Note also which path is being read: under `binfmt_misc`, `/proc/self/exe`
 * names the *interpreter*, not the file that was executed. That is the exact
 * problem `binfmt-magic-match.d` documents and SELF has to work around.
 *
 * Companions:
 *   docs/research/autological-artifacts/embedded-provenance.md
 *   docs/research/autological-artifacts/debug-info-and-indexes.md
 *   docs/research/autological-artifacts/binfmt-misc.md
 *
 * Run with: `dub run --single elf-note-buildid.d [FILE]`
 *
 * The recipe passes `lflags "--build-id"` deliberately: a build-id is a *link
 * option*, not a property of the format, and a toolchain that does not ask for
 * one produces an image that cannot name itself. That opt-in is itself the
 * evidence — self-description here is a convention the toolchain may decline.
 *
 * Portability: Linux + ELF only (`platforms "linux"` in the recipe). If the
 * image carries no notes — a stripped or `--build-id=none` link — the program
 * prints a `SKIP:` line and exits 0 rather than failing.
 */
module autological_elf_note_buildid;

import std.algorithm : filter, map;
import std.array : array;
import std.ascii : isPrintable;
import std.conv : text;
import std.file : exists, read;
import std.stdio : writefln, writeln;

/// `p_type` values this program cares about.
enum uint ptNote = 4;

/// The note types the GNU toolchain defines under the `GNU` name.
enum uint ntGnuAbiTag = 1;
enum uint ntGnuBuildId = 3;
enum uint ntGnuPropertyType0 = 5;

/// One decoded ELF note.
struct Note
{
    string name;
    uint type;
    const(ubyte)[] desc;
    string segment; // which PT_NOTE it came from, for reporting
}

/// Reads a little-endian unsigned integer of `T` at `offset`.
T le(T)(in ubyte[] b, size_t offset) @safe pure nothrow @nogc
in (offset + T.sizeof <= b.length, "read past end of image")
{
    T v;
    foreach (i; 0 .. T.sizeof)
        v |= T(b[offset + i]) << (8 * i);
    return v;
}

/// Rounds `n` up to the next multiple of 4, as the note format requires.
size_t align4(size_t n) @safe pure nothrow @nogc => (n + 3) & ~size_t(3);

/++
Walks every `PT_NOTE` segment and decodes the notes inside.

Only 64-bit little-endian ELF is handled; that is what the recipe's
`platforms "linux"` plus a modern toolchain produces, and widening it would add
byte-order plumbing without adding an argument.
+/
Note[] readNotes(in ubyte[] img) @safe pure
{
    if (img.length < 64 || img[0 .. 4] != [0x7f, 'E', 'L', 'F'])
        throw new Exception("not an ELF image");
    if (img[4] != 2 || img[5] != 1)
        throw new Exception("only 64-bit little-endian ELF is decoded here");

    const phoff = le!ulong(img, 0x20);
    const phentsize = le!ushort(img, 0x36);
    const phnum = le!ushort(img, 0x38);

    Note[] notes;
    foreach (i; 0 .. phnum)
    {
        const ph = cast(size_t)(phoff + i * phentsize);
        if (le!uint(img, ph) != ptNote)
            continue;

        const offset = cast(size_t) le!ulong(img, ph + 0x08);
        const filesz = cast(size_t) le!ulong(img, ph + 0x20);
        const label = "PT_NOTE[" ~ i.text ~ "] @0x" ~ offsetHex(offset);

        size_t cursor = offset;
        const end = offset + filesz;
        while (cursor + 12 <= end)
        {
            const namesz = le!uint(img, cursor);
            const descsz = le!uint(img, cursor + 4);
            const type = le!uint(img, cursor + 8);
            const nameAt = cursor + 12;
            const descAt = nameAt + align4(namesz);
            if (descAt + descsz > end)
                break;

            // `n_namesz` counts the terminating NUL; drop it for display.
            const nameBytes = img[nameAt .. nameAt + (namesz ? namesz - 1 : 0)];
            notes ~= Note(cast(string) nameBytes.idup, type,
                img[descAt .. descAt + descsz].idup, label);
            cursor = descAt + align4(descsz);
        }
    }
    return notes;
}

/// Lowercase hex, for offsets in labels.
string offsetHex(size_t v) @safe pure
{
    import std.format : format;
    return format("%x", v);
}

/// Hex-encodes a descriptor, which is how a build-id is universally written.
string hex(in ubyte[] b) @safe pure
{
    import std.format : format;

    char[] s;
    foreach (x; b)
        s ~= format("%02x", x);
    return s.idup;
}

/// Renders a descriptor as text when it plausibly is text (Fedora's `.note.package`).
string asTextIfPrintable(in ubyte[] b) @safe pure
{
    foreach (c; b)
        if (c != 0 && !(cast(char) c).isPrintable)
            return null;
    char[] s;
    foreach (c; b)
        if (c != 0)
            s ~= cast(char) c;
    return s.idup;
}

/// Names the well-known GNU note types.
string typeName(string owner, uint type) @safe pure nothrow @nogc
{
    if (owner != "GNU")
        return "vendor-defined";
    switch (type)
    {
    case ntGnuAbiTag:
        return "NT_GNU_ABI_TAG";
    case ntGnuBuildId:
        return "NT_GNU_BUILD_ID";
    case ntGnuPropertyType0:
        return "NT_GNU_PROPERTY_TYPE_0";
    default:
        return "GNU (other)";
    }
}

/// Decodes the ABI-tag descriptor: OS id plus a minimum kernel version triple.
string abiTag(in ubyte[] desc) @safe pure
{
    if (desc.length < 16)
        return "(malformed)";
    static immutable os = ["Linux", "GNU/Hurd", "Solaris", "FreeBSD"];
    const id = le!uint(desc, 0);
    const name = id < os.length ? os[id] : "OS " ~ id.text;
    return name ~ " " ~ le!uint(desc, 4).text ~ "." ~ le!uint(desc, 8).text
        ~ "." ~ le!uint(desc, 12).text ~ " or later";
}

int main(string[] args)
{
    // `/proc/self/exe` is the artifact interrogating itself: the kernel's own
    // answer to "which file am I running?".
    const path = args.length > 1 ? args[1] : "/proc/self/exe";
    if (!path.exists)
    {
        writefln("SKIP: %s does not exist on this host.", path);
        return 0;
    }

    const img = cast(ubyte[]) read(path);
    writefln("Reading %s (%s bytes).", path, img.length);
    writeln;

    const notes = readNotes(img);
    if (notes.length == 0)
    {
        writeln("SKIP: this image carries no PT_NOTE segments (stripped, or linked");
        writeln("      with --build-id=none) — nothing to decode.");
        return 0;
    }

    writefln("%s note(s) across %s PT_NOTE segment(s):", notes.length,
        notes.map!(n => n.segment).array.distinctCount);
    writeln;

    foreach (n; notes)
    {
        writefln("  owner %-12s type 0x%02x  %-24s desc %s bytes   [%s]",
            "'" ~ n.name ~ "'", n.type, typeName(n.name, n.type), n.desc.length, n.segment);

        if (n.name == "GNU" && n.type == ntGnuBuildId)
        {
            const id = hex(n.desc);
            writefln("      build-id: %s", id);
            writefln("      debuginfod key: /buildid/%s/debuginfo", id);
            writeln("      -> the artifact names itself; the payload it names lives elsewhere.");
        }
        else if (n.name == "GNU" && n.type == ntGnuAbiTag)
        {
            writefln("      ABI tag: %s", abiTag(n.desc));
        }
        else if (const t = asTextIfPrintable(n.desc))
        {
            writefln("      text descriptor: %s", t);
        }
    }

    writeln;
    writeln("Everything above was found by walking a table and matching a name string.");
    writeln("There is no index of notes, no type registry in the file, and no way to");
    writeln("ask 'which notes are there?' without parsing all of them. That is what a");
    writeln("format without a schema costs, and what a `notes` table would replace.");

    return 0;
}

/// Counts distinct strings without sorting the caller's data.
size_t distinctCount(in string[] xs) @safe pure
{
    bool[string] seen;
    foreach (x; xs)
        seen[x] = true;
    return seen.length;
}
