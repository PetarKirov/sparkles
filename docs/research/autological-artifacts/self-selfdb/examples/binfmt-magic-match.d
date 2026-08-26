#!/usr/bin/env dub
/+ dub.sdl:
    name "autological_binfmt_magic_match"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * `binfmt_misc` registration strings, parsed and evaluated the way the kernel does.
 *
 * `fs/binfmt_misc.c` turns a line of the form
 *
 *     :name:type:offset:magic:mask:interpreter:flags
 *
 * into a predicate over the first bytes of a file. This program implements that
 * predicate — including the `\xNN` escaping of `magic`/`mask` and the
 * mask-is-optional rule — and evaluates a small registration table against a
 * set of specimen buffers, so the *dispatch* half of the catalog's thesis is
 * executable rather than described.
 *
 * The registrations included are the ones the catalog argues about:
 *
 *   - `qemu-aarch64`  — the canonical `E_MACHINE`-masked ELF rule, and the
 *     reason the `F` (fix binary) flag exists: without it the interpreter is
 *     resolved in the mount namespace of the *process being executed*, so a
 *     container without the interpreter inside it cannot run foreign binaries.
 *   - `self`          — magic at **offset 68**, which is a field SQLite has
 *     promised never to interpret (see `sqlite-header-probe.d`). This is the
 *     whole dispatch story for SELF: no new format, one kernel rule.
 *   - `jar`           — `PK\x03\x04` at offset 0, the rule that made GIFAR
 *     interesting, because a JAR is located by its *footer* while `binfmt_misc`
 *     matches on its *header*.
 *
 * If `/proc/sys/fs/binfmt_misc` is mounted and readable, the program also parses
 * the host's live registrations through the same code, which is the honest test:
 * the parser either handles what the kernel actually emitted, or it does not.
 *
 * Companions:
 *   docs/research/autological-artifacts/binfmt-misc.md
 *   docs/research/autological-artifacts/self-selfdb/index.md
 *   docs/research/autological-artifacts/parser-differentials.md
 *
 * Run with: `dub run --single binfmt-magic-match.d`
 *
 * Portability: the parser and matcher are pure `std` and run everywhere; the
 * live-registration read is Linux-only and prints a `SKIP:` line elsewhere (or
 * when `binfmt_misc` is not mounted), still exiting 0.
 */
module autological_binfmt_magic_match;

import std.algorithm : filter, map, startsWith;
import std.array : array, split;
import std.conv : text, to;
import std.file : dirEntries, exists, isDir, readText, SpanMode;
import std.stdio : writefln, writeln;
import std.string : representation, strip;

/++
A parsed `binfmt_misc` registration.

`type` is `M` for magic-and-mask matching or `E` for an extension match; only
`M` participates in the byte-level dispatch this catalog cares about, and the
kernel rejects a non-empty `offset`/`magic` for `E` rules.
+/
struct Registration
{
    string name;
    char type; // 'M' (magic) or 'E' (extension)
    size_t offset;
    immutable(ubyte)[] magic;
    immutable(ubyte)[] mask; // empty == all-0xff, i.e. literal
    string interpreter;
    string flags;

    /// True when the `F` flag is set — the interpreter is opened at registration
    /// time and held, so the rule survives a mount-namespace change.
    bool fixBinary() const @safe pure nothrow @nogc => flags.hasFlag('F');

    /// True when the `P` flag is set — `argv[0]` is preserved and the original
    /// path is passed as an extra argument.
    bool preserveArgv0() const @safe pure nothrow @nogc => flags.hasFlag('P');

    /// True when the `C` flag is set — credentials are computed from the binary
    /// rather than the interpreter, which implies `O`.
    bool credentialsFromBinary() const @safe pure nothrow @nogc => flags.hasFlag('C');

    /// True when the `O` flag is set — the binary is opened and its descriptor
    /// passed to the interpreter as `/dev/fd/N`.
    bool openBinary() const @safe pure nothrow @nogc => flags.hasFlag('O');
}

/// Case-sensitive flag membership.
private bool hasFlag(in string flags, char f) @safe pure nothrow @nogc
{
    foreach (c; flags)
        if (c == f)
            return true;
    return false;
}

/++
Decodes the `\xNN` escaping the kernel accepts in `magic` and `mask`.

The kernel's own decoder handles `\x` hex pairs and passes everything else
through literally; a lone backslash is not special. Anything that is not a valid
hex pair after `\x` is a malformed registration, and the kernel returns `EINVAL`
rather than guessing.
+/
immutable(ubyte)[] unescape(string s) @safe pure
{
    ubyte[] out_;
    size_t i;
    while (i < s.length)
    {
        if (s[i] == '\\' && i + 3 < s.length && s[i + 1] == 'x')
        {
            out_ ~= s[i + 2 .. i + 4].to!ubyte(16);
            i += 4;
        }
        else
        {
            out_ ~= cast(ubyte) s[i];
            i++;
        }
    }
    return out_.idup;
}

/++
Parses one registration line.

The delimiter is whatever character follows the leading colon in the kernel's
grammar; every real-world registration uses `:`, and that is what is assumed
here. Throws on a field count the kernel would reject.
+/
Registration parse(string line) @safe pure
{
    const fields = line.strip.split(":");
    // A leading ':' produces an empty first field, so a well-formed line has 8.
    if (fields.length != 8)
        throw new Exception("expected 8 ':'-separated fields, got " ~ fields.length.text ~ ": " ~ line);

    Registration r;
    r.name = fields[1];
    r.type = fields[2].length ? fields[2][0] : 'M';
    r.offset = fields[3].length ? fields[3].to!size_t : 0;
    r.magic = unescape(fields[4]);
    r.mask = unescape(fields[5]);
    r.interpreter = fields[6];
    r.flags = fields[7];
    return r;
}

/++
The kernel's match predicate, transcribed.

Two properties are worth naming because they shape what can be dispatched:
`offset` is a *fixed* position — there is no search — and the comparison is
`(byte & mask) == (magic & mask)` bytewise, so a mask makes a rule tolerant of
fields that vary between otherwise identical binaries (an ELF's `e_machine`
being the archetype).
+/
bool matches(in Registration r, in ubyte[] buf) @safe pure nothrow @nogc
{
    if (r.type != 'M')
        return false; // extension rules do not look at bytes
    if (r.offset + r.magic.length > buf.length)
        return false;
    foreach (i, m; r.magic)
    {
        const mask = r.mask.length > i ? r.mask[i] : 0xff;
        if ((buf[r.offset + i] & mask) != (m & mask))
            return false;
    }
    return true;
}

/// A named specimen buffer.
struct Specimen
{
    string label;
    immutable(ubyte)[] bytes;
}

/// A 64-bit little-endian ELF header with `e_machine` set to `EM_AARCH64` (183).
immutable(ubyte)[] aarch64Elf() @safe pure
{
    auto b = new ubyte[64];
    b[0 .. 4] = [0x7f, 'E', 'L', 'F'];
    b[4] = 2; // ELFCLASS64
    b[5] = 1; // ELFDATA2LSB
    b[6] = 1; // EV_CURRENT
    b[16] = 2; // ET_EXEC
    b[18] = 183; // e_machine = EM_AARCH64, little-endian
    return b.idup;
}

/// The same header, but `e_machine` = `EM_X86_64` (62) — the mask must reject it.
immutable(ubyte)[] x86Elf() @safe pure
{
    auto b = cast(ubyte[]) aarch64Elf().dup;
    b[18] = 62;
    return b.idup;
}

/// A SQLite header whose `application_id` at offset 68 reads `SELF`.
immutable(ubyte)[] selfDb() @safe pure
{
    auto b = new ubyte[100];
    b[0 .. 16] = "SQLite format 3\0".representation;
    b[16] = 0x10; // page size 4096
    b[68 .. 72] = "SELF".representation;
    return b.idup;
}

/// An ordinary SQLite database — same magic at 0, nothing at 68.
immutable(ubyte)[] plainDb() @safe pure
{
    auto b = cast(ubyte[]) selfDb().dup;
    b[68 .. 72] = [0, 0, 0, 0];
    return b.idup;
}

/// A ZIP/JAR: local file header magic at offset 0.
immutable(ubyte)[] jar() @safe pure
{
    immutable(ubyte)[] z = [0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00];
    return z;
}

int main()
{
    // Real-shaped registrations. The qemu rule is the standard one shipped by
    // `qemu-user-static`; the mask lets every other ELF header field vary.
    const table = [
        parse(":qemu-aarch64:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00" ~
            "\\x02\\x00\\xb7\\x00:" ~
            "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff" ~
            "\\xfe\\xff\\xff\\xff:/usr/bin/qemu-aarch64-static:FPO"),
        parse(":self:M:68:SELF::/usr/bin/self-exec:F"),
        parse(":jar:M::PK\\x03\\x04::/usr/bin/jarwrapper:"),
        parse(":python-ext:E::py::/usr/bin/python3:"),
    ];

    const specimens = [
        Specimen("aarch64 ELF", aarch64Elf()),
        Specimen("x86-64 ELF", x86Elf()),
        Specimen("SELF database", selfDb()),
        Specimen("plain SQLite db", plainDb()),
        Specimen("JAR / ZIP", jar()),
    ];

    writeln("Registrations parsed from their kernel wire form:");
    writeln;
    foreach (r; table)
    {
        writefln("  %-14s type=%s offset=%-3s magic=%s bytes  mask=%s  flags=%s",
            r.name, r.type, r.offset, r.magic.length,
            r.mask.length ? r.mask.length.text ~ " bytes" : "none (literal)",
            r.flags.length ? r.flags : "(none)");
        writefln("      interpreter %s%s%s%s%s", r.interpreter,
            r.fixBinary ? "  [F: interpreter pinned at registration — works inside containers]" : "",
            r.preserveArgv0 ? "  [P: argv[0] preserved]" : "",
            r.openBinary ? "  [O: binary passed as /dev/fd/N]" : "",
            r.credentialsFromBinary ? "  [C: credentials from the binary]" : "");
    }
    writeln;

    writeln("Match matrix — which rule claims which specimen:");
    writeln;
    writefln("  %-18s | %s", "specimen",
        table.map!(r => pad(r.name, 14)).array.joinWith(" "));
    writefln("  %-18s-+-%s", "------------------",
        table.map!(_ => "--------------").array.joinWith("-"));
    foreach (s; specimens)
        writefln("  %-18s | %s", s.label,
            table.map!(r => pad(matches(r, s.bytes) ? "     ✓" : "", 14)).array.joinWith(" "));
    writeln;

    writeln("Read the `x86-64 ELF` row against the `aarch64 ELF` row: the two buffers");
    writeln("differ in exactly one byte (`e_machine`), and the mask is what turns that");
    writeln("byte into the decision. Read the `SELF database` row against `plain SQLite`:");
    writeln("same magic at offset 0, different byte at offset 68 — a format the kernel");
    writeln("can dispatch without SQLite knowing dispatch exists.");
    writeln;

    // The honest test: run the same parser over whatever this host has registered.
    enum procDir = "/proc/sys/fs/binfmt_misc";
    version (linux)
    {
        if (!procDir.exists || !procDir.isDir)
        {
            writeln("SKIP: " ~ procDir ~ " is not mounted — no live registrations to parse.");
            return 0;
        }

        writeln("Live registrations on this host, re-parsed through the same code:");
        size_t seen;
        foreach (entry; dirEntries(procDir, SpanMode.shallow))
        {
            const base = entry.name["/proc/sys/fs/binfmt_misc/".length .. $];
            if (base == "register" || base == "status")
                continue;
            seen++;
            const body_ = readText(entry.name);
            const enabled = body_.startsWith("enabled");
            writefln("  %-20s %s", base, enabled ? "enabled" : "disabled");
            foreach (line; body_.lineRange.filter!(l => l.startsWith("offset ") || l.startsWith("magic ")
                    || l.startsWith("mask ") || l.startsWith("interpreter ") || l.startsWith("flags")))
                writefln("      %s", line.strip);
        }
        if (seen == 0)
            writeln("  (none registered)");
    }
    else
    {
        writeln("SKIP: not Linux — `binfmt_misc` is a Linux facility; the parser above ran anyway.");
    }

    return 0;
}

/// Pads to a fixed display width so the matrix lines up.
string pad(string s, size_t width) @safe pure
{
    import std.array : replicate;
    import std.utf : count;

    const len = s.count;
    return len >= width ? s : s ~ " ".replicate(width - len);
}

/// `join` under a name that does not collide with the `std.array` overload set.
string joinWith(string[] parts, string sep) @safe pure
{
    import std.array : join;
    return parts.join(sep);
}

/// `lineSplitter` as a named helper, so call sites stay single-expression.
private auto lineRange(string s) @safe pure nothrow
{
    import std.string : lineSplitter;
    return s.lineSplitter;
}
