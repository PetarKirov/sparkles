/** Immutable session-generation files, written only by background storage work. */
module session_archive;

import session_record : decodeSession, encodeSession, SessionRecord, SessionSelection, SessionTab;
import document_files : readRegularBytes, saveAtomic, SaveReceipt;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.cstring : hasInteriorNul;
import sparkles.base.text.writers : writeIntegerPadded;
import sparkles.base.text.readers : readInteger;
import session_directory : SessionDirectory;
import std.algorithm.sorting : sort;
import std.file : dirEntries, remove, SpanMode;
import std.path : baseName, buildPath;

private enum size_t maximumGenerationBytes = 512 * 1024 * 1024;

/// Recognize a canonical positive generation filename; zero means an unrelated entry.
ulong sessionGenerationOfName(scope const(char)[] name) @safe pure nothrow @nogc
{
    if (name.length != 28 || name[20 .. $] != ".session") return 0;
    const(char)[] digits = name[0 .. 20];
    const parsed = readInteger!ulong(digits);
    return parsed.hasValue && digits.length == 0 ? parsed.value : 0;
}

/// Cleanup considers only canonical positive names, including the full uint64 range.
@("editor.sessionArchive.generationNames")
@safe pure nothrow @nogc unittest
{
    assert(sessionGenerationOfName("00000000000000000001.session") == 1);
    assert(sessionGenerationOfName("18446744073709551615.session") == ulong.max);
    foreach (name; ["00000000000000000000.session", "18446744073709551616.session",
        "00000000000000000001.session.bak", "0000000000000000000x.session",
        "+0000000000000000001.session", "notes.txt"])
        assert(sessionGenerationOfName(name) == 0);
}

/// Best-effort retirement results; failures preserve files and do not revoke a newer acknowledgment.
struct ArchiveCleanup
{
    ulong[] removed;
    string[] issues;
}

/**
Keep the two newest valid generations at or below the acknowledged cutoff.
Corrupt, unsupported, symlinked and newer entries remain untouched. The
caller keeps the exclusive directory lease throughout this worker operation.
Removal is best effort: a deletion may reappear after interruption without
affecting the newer durable records.
*/
ArchiveCleanup pruneSessionArchive(SessionDirectory directory, ulong durableThrough) @safe nothrow
{
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
            const generation = sessionGenerationOfName(baseName(entry.name));
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
        auto record = readSessionGeneration(directory.path, generation);
        if (record.hasError) { report.issues ~= record.error; continue; }
        if (kept < 2) { ++kept; continue; }
        try
        {
            (() @trusted { remove(generationPath(directory.path, generation)); })();
            report.removed ~= generation;
        }
        catch (Exception) { report.issues ~= "An older recovery generation could not be removed."; }
    }
    return report;
}

private string generationPath(string directory, ulong generation) @safe pure nothrow
{
    UniqueBuffer!(char, 64) name;
    writeIntegerPadded!10(name, generation, 20);
    name ~= ".session";
    return buildPath(directory, name[].idup);
}

/**
Append a positive generation without ever replacing a previous checkpoint.
The caller supplies an existing private directory whose creation is already
durable. A successful receipt acknowledges the file commit and separately
reports directory durability. The caller must retain prior durable files
until a newer generation receives a durable acknowledgment.
*/
Expected!SaveReceipt appendSessionGeneration(string directory, in SessionRecord record) @safe nothrow
{
    if (!directory.length || directory.hasInteriorNul)
        return err!SaveReceipt("The recovery directory is invalid.");
    if (!record.generation) return err!SaveReceipt("Recovery generations must be positive.");
    auto encoded = encodeSession(record);
    if (encoded.hasError) return err!SaveReceipt(encoded.error);
    if (encoded.value.length > maximumGenerationBytes)
        return err!SaveReceipt("The recovery generation exceeds the archive's byte limit.");
    try { return saveAtomic(generationPath(directory, record.generation), encoded.value); }
    catch (Exception) { return err!SaveReceipt("The recovery generation could not be written."); }
}

/// Validate the complete immutable record and its identity before returning recovered contents.
Expected!SessionRecord readSessionGeneration(string directory, ulong generation) @safe nothrow
{
    if (!directory.length || directory.hasInteriorNul)
        return err!SessionRecord("The recovery directory is invalid.");
    if (!generation) return err!SessionRecord("Recovery generations must be positive.");
    auto bytes = readRegularBytes(generationPath(directory, generation), maximumGenerationBytes);
    if (bytes.hasError) return err!SessionRecord(bytes.error);
    auto record = decodeSession(bytes.value);
    if (record.hasError) return record;
    if (record.value.generation != generation)
        return err!SessionRecord("The recovery generation does not match its file identity.");
    return ok(record.value);
}

/// A newer generation and a refused duplicate leave earlier dirty contents recoverable.
@("editor.sessionArchive.generationsNeverReplaceEarlierRecovery")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX archive adapter is not available.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.file : readText;
    auto fixture = TmpFS.create();
    const source = fixture.writeFile("disk");
    SessionRecord record;
    record.generation = 1;
    record.active = 7;
    record.tabs = [SessionTab(id: 7, path: source, name: "draft", content: "dirty\r\n",
        savedContent: "disk", selections: [SessionSelection(0, 0)])];
    const first = appendSessionGeneration(fixture.dir, record);
    assert(first.hasValue && first.value.durable);
    record.generation = 2;
    record.tabs[0].content = "newer\r\n";
    const second = appendSessionGeneration(fixture.dir, record);
    assert(second.hasValue && second.value.durable);
    record.generation = 1;
    assert(appendSessionGeneration(fixture.dir, record).hasError);
    const old = readSessionGeneration(fixture.dir, 1);
    const latest = readSessionGeneration(fixture.dir, 2);
    assert(old.hasValue && old.value.tabs[0].content == "dirty\r\n");
    assert(latest.hasValue && latest.value.tabs[0].content == "newer\r\n");
    assert((() @trusted => readText(source))() == "disk");
}

/// Retention preserves damaged and future generations while bounding older valid files.
@("editor.sessionArchive.retentionPreservesUnconfirmedAndCorrupt")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native recovery archive currently requires Linux.");
    }
    import session_directory : SessionDirectory;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.conv : text;
    import std.file : write;
    auto fixture = TmpFS.create();
    auto directory = SessionDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
    assert(directory.hasValue);
    scope (exit) directory.value.close();
    SessionRecord record;
    record.active = 7;
    record.tabs = [SessionTab(id: 7, name: "draft", selections: [SessionSelection(0, 0)])];
    foreach (generation; 1UL .. 6UL)
    {
        record.generation = generation;
        record.tabs[0].content = text(generation);
        assert(appendSessionGeneration(directory.value.path, record).hasValue);
    }
    (() @trusted { write(buildPath(directory.value.path, "00000000000000000002.session"), "damaged"); })();
    const report = pruneSessionArchive(directory.value, 4);
    assert(report.removed.length == 1 && report.removed[0] == 1 && report.issues.length == 1);
    assert(readSessionGeneration(directory.value.path, 1).hasError);
    assert(readSessionGeneration(directory.value.path, 3).hasValue);
    assert(readSessionGeneration(directory.value.path, 4).hasValue);
    assert(readSessionGeneration(directory.value.path, 5).hasValue);
    import std.file : readText;
    assert((() @trusted => readText(buildPath(directory.value.path, "00000000000000000002.session")))() == "damaged");
}
