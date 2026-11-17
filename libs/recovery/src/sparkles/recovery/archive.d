/**
Numbered immutable generation files in a recovery archive.

A generation is one opaque payload under a canonical name: 20 decimal digits
and the layout's suffix (`00000000000000000007.session`). An append never
replaces a file: it is a create-only atomic write through the capability VFS
that syncs the directory (VFO9), so an earlier generation stays readable
until a newer one is durably acknowledged. Reads accept only a regular file,
never through a link (VFO12). Pruning keeps the newest valid generations at
or below an acknowledged cutoff and leaves damaged, unsupported, linked and
newer entries alone. A retirement marker records that a generation was
adopted elsewhere without touching its bytes.
*/
module sparkles.recovery.archive;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.cstring : hasInteriorNul;
import sparkles.base.text.readers : readInteger;
import sparkles.base.text.writers : writeIntegerPadded;
import sparkles.recovery.directory : LeasedDirectory;

version (Posix)
{
    import sparkles.base.vfs : AtomicDisposition, AtomicMode, CreateDefault, ErrorKind, OpKind,
        ResolvePolicy, Rights, ambientAuthority, openRoot;
    import sparkles.event_horizon.sys.vfs : BlockingVfs;
}

/// How an archive names its files, and how large a generation may be.
struct ArchiveLayout
{
    /// Follows a generation's 20 digits.
    string suffix = ".generation";
    /// Precedes a retired generation's 20 digits.
    string markerPrefix = "retired-";
    /// The first line of a retirement marker.
    string markerTag = "SPARKLES-RECOVERY-RETIRED/1";
    /// The largest payload an append writes or a read admits.
    size_t maximumBytes = 512 * 1024 * 1024;
}

/// A committed write; durability is acknowledged separately.
struct WriteReceipt
{
    bool durable;   /// the directory sync after the commit succeeded
    string warning; /// what the caller should tell its user, if anything
}

/// The generation a canonical name holds, or zero for any other entry.
ulong generationOf(in ArchiveLayout layout, scope const(char)[] name) @safe pure nothrow @nogc
{
    if (name.length != 20 + layout.suffix.length || name[20 .. $] != layout.suffix) return 0;
    const(char)[] digits = name[0 .. 20];
    const parsed = readInteger!ulong(digits);
    return parsed.hasValue && digits.length == 0 ? parsed.value : 0;
}

/// Only canonical positive names count, the whole `ulong` range included.
@("recovery.archive.generationNames")
@safe pure nothrow @nogc unittest
{
    const layout = ArchiveLayout(".session");
    assert(generationOf(layout, "00000000000000000001.session") == 1);
    assert(generationOf(layout, "18446744073709551615.session") == ulong.max);
    foreach (name; ["00000000000000000000.session", "18446744073709551616.session",
        "00000000000000000001.session.bak", "0000000000000000000x.session",
        "+0000000000000000001.session", "00000000000000000001.generation", "notes.txt"])
        assert(generationOf(layout, name) == 0);
}

/// The canonical file name of `generation`.
string generationName(in ArchiveLayout layout, ulong generation) @safe pure nothrow
{
    UniqueBuffer!(char, 64) name;
    writeIntegerPadded!10(name, generation, 20);
    return name[].idup ~ layout.suffix;
}

/**
Append `bytes` as `generation`, never replacing a file. The caller supplies an
existing private directory whose creation is already durable, and retains
earlier durable generations until this one is acknowledged durable.
*/
Expected!WriteReceipt appendGeneration(string directory, ulong generation, scope const(char)[] bytes,
    in ArchiveLayout layout = ArchiveLayout.init) @safe nothrow
{
    if (!directory.length || directory.hasInteriorNul)
        return err!WriteReceipt("The recovery directory is invalid.");
    if (!generation) return err!WriteReceipt("Recovery generations must be positive.");
    if (bytes.length > layout.maximumBytes)
        return err!WriteReceipt("The recovery generation exceeds the archive's byte limit.");
    try return writeNew(directory, generationName(layout, generation), bytes, false);
    catch (Exception) return err!WriteReceipt("The recovery generation could not be written.");
}

/// The payload of `generation`, read only from a regular file.
Expected!string readGeneration(string directory, ulong generation,
    in ArchiveLayout layout = ArchiveLayout.init) @safe nothrow
{
    if (!directory.length || directory.hasInteriorNul)
        return err!string("The recovery directory is invalid.");
    if (!generation) return err!string("Recovery generations must be positive.");
    try return readRegular(directory, generationName(layout, generation), layout.maximumBytes);
    catch (Exception) return err!string("The recovery generation could not be read.");
}

/// The canonical generations in `directory`, newest first; links are skipped.
Expected!(ulong[]) listGenerations(string directory, in ArchiveLayout layout = ArchiveLayout.init)
    @safe nothrow
{
    import std.algorithm.sorting : sort;
    import std.file : dirEntries, SpanMode;
    import std.path : baseName;

    ulong[] generations;
    try
    {
        foreach (entry; dirEntries(directory, SpanMode.shallow, false))
        {
            if (entry.isSymlink) continue;
            if (const generation = generationOf(layout, baseName(entry.name))) generations ~= generation;
        }
    }
    catch (Exception) return err!(ulong[])("Recovery generations could not be listed.");
    generations.sort!"a > b";
    return ok(generations);
}

/// Best-effort retirement results; a failure keeps the file and revokes nothing newer.
struct ArchiveCleanup
{
    ulong[] removed; /// generations deleted
    string[] issues; /// what was kept and why
}

/**
Keep the `keep` newest valid generations at or below `durableThrough`, and
remove older valid ones. `validate` returns null for a valid payload and the
issue otherwise; damaged, unreadable, linked and newer entries stay. The
caller holds the lease throughout, on a worker. A removal may reappear after
an interruption without affecting the newer durable records.
*/
ArchiveCleanup pruneArchive(LeasedDirectory directory, ulong durableThrough, in ArchiveLayout layout,
    scope string delegate(ulong generation, string bytes) @safe nothrow validate = null,
    size_t keep = 2) @safe nothrow
{
    import std.file : dirEntries, remove, SpanMode;
    import std.path : baseName, buildPath;
    import std.algorithm.sorting : sort;

    ArchiveCleanup report;
    if (directory is null || !directory.owned)
    {
        report.issues ~= "Recovery cleanup requires an owned archive.";
        return report;
    }
    if (!durableThrough) return report;
    ulong[] generations;
    try
    {
        foreach (entry; dirEntries(directory.path, SpanMode.shallow, false))
        {
            const generation = generationOf(layout, baseName(entry.name));
            if (!generation || generation > durableThrough) continue;
            if (entry.isSymlink)
            {
                report.issues ~= "A symbolic recovery entry was preserved.";
                continue;
            }
            generations ~= generation;
        }
    }
    catch (Exception)
    {
        report.issues ~= "Recovery generations could not be listed for cleanup.";
        return report;
    }
    generations.sort!"a > b";
    size_t kept;
    foreach (generation; generations)
    {
        auto bytes = readGeneration(directory.path, generation, layout);
        if (bytes.hasError) { report.issues ~= bytes.error; continue; }
        if (validate !is null)
            if (const issue = validate(generation, bytes.value)) { report.issues ~= issue; continue; }
        if (kept < keep) { ++kept; continue; }
        try
        {
            (() @trusted { remove(buildPath(directory.path, generationName(layout, generation))); })();
            report.removed ~= generation;
        }
        catch (Exception) { report.issues ~= "An older recovery generation could not be removed."; }
    }
    return report;
}

/// Whether a generation has a retirement marker.
enum Retirement : ubyte
{
    none,    /// no marker
    retired, /// a valid marker for this generation
    damaged, /// a marker that is not this generation's
}

/// The retirement state of `generation` in `directory`.
Retirement retirementOf(string directory, ulong generation, in ArchiveLayout layout = ArchiveLayout.init)
    @safe nothrow
{
    try
    {
        const marker = readRegular(directory, markerName(layout, generation), 256);
        if (marker.hasError) return Retirement.none;
        return marker.value == markerBytes(layout, generation) ? Retirement.retired : Retirement.damaged;
    }
    catch (Exception) return Retirement.none;
}

/**
Record that `generation` was adopted by another archive: the marker names
this exact generation, and the generation's bytes stay. Retrying over a
valid marker rewrites it, so the acknowledgment is synced again; a damaged
marker is kept and reported.
*/
Expected!WriteReceipt retire(LeasedDirectory directory, ulong generation,
    in ArchiveLayout layout = ArchiveLayout.init) @safe nothrow
{
    if (directory is null || !directory.owned)
        return err!WriteReceipt("The restored archive lease is unavailable.");
    const state = retirementOf(directory.path, generation, layout);
    if (state == Retirement.damaged)
        return err!WriteReceipt("A damaged recovery adoption marker was preserved.");
    try return writeNew(directory.path, markerName(layout, generation), markerBytes(layout, generation),
        state == Retirement.retired);
    catch (Exception) return err!WriteReceipt("The restored archive could not be retired.");
}

private string markerBytes(in ArchiveLayout layout, ulong generation) @safe pure nothrow
{
    UniqueBuffer!(char, 64) token;
    writeIntegerPadded!10(token, generation, 20);
    return layout.markerTag ~ "\n" ~ token[].idup ~ "\n";
}

private string markerName(in ArchiveLayout layout, ulong generation) @safe pure nothrow
{
    UniqueBuffer!(char, 64) digits;
    writeIntegerPadded!10(digits, generation, 20);
    return layout.markerPrefix ~ digits[].idup;
}

/*
The one write: a create-only (or, for a marker being re-acknowledged, a
replacing) atomic write, private to the owner, that syncs the directory.
*/
private Expected!WriteReceipt writeNew(string directory, string name, scope const(char)[] bytes,
    bool replace) @safe nothrow
{
    version (Posix)
    {
        enum Rights rights = cast(Rights)(Rights.create | Rights.write | Rights.rename);
        auto dir = openRoot!rights(new BlockingVfs, directory, ambientAuthority(),
            ResolvePolicy.init, CreateDefault.ownerOnly);
        if (dir.hasError) return err!WriteReceipt("The recovery directory could not be opened.");
        enum create = AtomicMode(AtomicDisposition.createNew, syncDirectory: true);
        enum replacing = AtomicMode(AtomicDisposition.replace, syncDirectory: true);
        auto written = replace ? dir.value.writeFileAtomic!replacing(name, bytes)
            : dir.value.writeFileAtomic!create(name, bytes);
        if (written.hasError)
        {
            if (written.error.kind == ErrorKind.exists && written.error.op != OpKind.openAt)
                return err!WriteReceipt("The recovery file already exists and was not replaced.");
            return err!WriteReceipt("The recovery file could not be written.");
        }
        WriteReceipt receipt;
        receipt.durable = written.value.directorySynced;
        if (written.value.temporaryLeft)
            receipt.warning = "The recovery file was written, but its private temporary could not be removed.";
        if (!receipt.durable)
            receipt.warning = "The recovery file was written, but directory durability could not be acknowledged.";
        return ok(receipt);
    }
    else return err!WriteReceipt("Recovery storage is unavailable on this platform.");
}

private Expected!string readRegular(string directory, string name, size_t maximum) @safe nothrow
{
    version (Posix)
    {
        import std.array : appender;

        auto dir = openRoot!(Rights.read)(new BlockingVfs, directory, ambientAuthority());
        if (dir.hasError) return err!string("The recovery directory could not be opened.");
        auto sink = appender!(ubyte[]);
        const read = dir.value.readFile(name, sink, maximum);
        if (read.hasError)
        {
            const e = read.error;
            if (e.kind == ErrorKind.notFound) return err!string("The recovery file does not exist.");
            if (e.kind == ErrorKind.bufferTooSmall)
                return err!string("The recovery file exceeds the archive's byte limit.");
            if (e.kind == ErrorKind.symlinkRefused || e.kind == ErrorKind.isADirectory
                || e.context == "not a regular file")
                return err!string("The recovery entry is not a regular file.");
            return err!string("The recovery file could not be read.");
        }
        // The appender's array is this call's alone.
        return ok((() @trusted => cast(string) sink[])());
    }
    else return err!string("Recovery storage is unavailable on this platform.");
}

/// A refused duplicate leaves the earlier generation, and a newer one does not replace it.
@("recovery.archive.generationsNeverReplaceEarlierOnes")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery storage needs the POSIX VFS backend.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    auto fixture = TmpFS.create();
    const first = appendGeneration(fixture.dir, 1, "dirty");
    assert(first.hasValue && first.value.durable);
    assert(appendGeneration(fixture.dir, 2, "newer").value.durable);
    assert(appendGeneration(fixture.dir, 1, "must not replace").error
        == "The recovery file already exists and was not replaced.");
    assert(readGeneration(fixture.dir, 1).value == "dirty");
    assert(readGeneration(fixture.dir, 2).value == "newer");
    assert(listGenerations(fixture.dir).value == [2, 1]);
    assert(appendGeneration(fixture.dir, 0, "x").hasError);
    assert(appendGeneration(fixture.dir, 3, "too long", ArchiveLayout(maximumBytes: 4)).hasError);
}

/// Retention keeps the newest valid generations and leaves damaged and newer ones alone.
@("recovery.archive.retentionPreservesUnconfirmedAndCorrupt")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.conv : text;
    import std.file : readText, write;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    auto directory = LeasedDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
    assert(directory.hasValue);
    scope (exit) directory.value.close();
    const path = directory.value.path;
    foreach (generation; 1UL .. 6UL)
        assert(appendGeneration(path, generation, text("valid ", generation)).hasValue);
    (() @trusted { write(buildPath(path, generationName(ArchiveLayout.init, 2)), "damaged"); })();
    string validate(ulong generation, string bytes) @safe nothrow
    {
        try return bytes == text("valid ", generation) ? null : "A damaged recovery generation was preserved.";
        catch (Exception) return "unreachable";
    }
    const report = pruneArchive(directory.value, 4, ArchiveLayout.init, &validate);
    assert(report.removed == [1] && report.issues.length == 1);
    assert(readGeneration(path, 1).hasError);
    foreach (generation; 3UL .. 6UL) assert(readGeneration(path, generation).hasValue);
    assert((() @trusted => readText(buildPath(path, generationName(ArchiveLayout.init, 2))))() == "damaged");
}

/// A retirement marker names one generation; a damaged one is kept, and the bytes stay.
@("recovery.archive.retirementMarkers")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.file : write;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    auto directory = LeasedDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
    assert(directory.hasValue);
    scope (exit) directory.value.close();
    const path = directory.value.path;
    assert(appendGeneration(path, 1, "recovered").hasValue);
    assert(retirementOf(path, 1) == Retirement.none);
    assert(retire(directory.value, 1).value.durable);
    assert(retirementOf(path, 1) == Retirement.retired);
    assert(retire(directory.value, 1).value.durable, "a retry re-acknowledges the marker");
    assert(readGeneration(path, 1).value == "recovered");
    (() @trusted { write(buildPath(path, "retired-00000000000000000002"), "other"); })();
    assert(retirementOf(path, 2) == Retirement.damaged);
    assert(retire(directory.value, 2).error == "A damaged recovery adoption marker was preserved.");
}

/// An archive this process now holds, and its generations newest first.
struct ClaimedArchive
{
    LeasedDirectory directory; /// close it once its restore is decided
    ulong[] generations;       ///
}

/// What `claimArchives` found.
struct ArchiveScan
{
    ClaimedArchive[] archives; ///
    string[] issues;           /// nonfatal: archives that could not be inspected
}

/**
Claim every abandoned archive directly under `base`, on a worker. Links and
other entries are skipped, and so are archives another live owner holds. The
caller closes every returned lease.
*/
ArchiveScan claimArchives(string base, in ArchiveLayout layout = ArchiveLayout.init) @safe nothrow
{
    import sparkles.recovery.directory : DirectoryIssueKind;
    import std.file : dirEntries, SpanMode;

    ArchiveScan scan;
    try
    {
        foreach (entry; dirEntries(base, SpanMode.shallow, false))
        {
            if (entry.isSymlink || !entry.isDir) continue;
            auto claimed = LeasedDirectory.claim(entry.name);
            if (claimed.hasError)
            {
                if (claimed.error.kind == DirectoryIssueKind.unavailable)
                    scan.issues ~= claimed.error.message;
                continue;
            }
            auto generations = listGenerations(claimed.value.path, layout);
            if (generations.hasError)
            {
                scan.issues ~= generations.error;
                claimed.value.close();
                continue;
            }
            scan.archives ~= ClaimedArchive(claimed.value, generations.value);
        }
    }
    catch (Exception) scan.issues ~= "Some recovery archives could not be listed.";
    return scan;
}

/// Abandoned archives are claimed with their generations; a live owner's is skipped.
@("recovery.archive.claimAbandonedArchives")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    const base = buildPath(fixture.dir, "archives");
    auto abandoned = LeasedDirectory.create(base, fixture.dir);
    auto active = LeasedDirectory.create(base, fixture.dir);
    assert(abandoned.hasValue && active.hasValue);
    scope (exit) active.value.close();
    assert(appendGeneration(abandoned.value.path, 1, "one").hasValue);
    assert(appendGeneration(abandoned.value.path, 2, "two").hasValue);
    assert(appendGeneration(active.value.path, 1, "busy").hasValue);
    const path = abandoned.value.path;
    abandoned.value.close();
    auto scan = claimArchives(base);
    scope (exit) foreach (archive; scan.archives) archive.directory.close();
    assert(scan.archives.length == 1 && !scan.issues.length);
    assert(scan.archives[0].directory.path == path && scan.archives[0].generations == [2, 1]);
}
