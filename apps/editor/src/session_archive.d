/**
The editor's session generations: its record schema over `sparkles:recovery`'s
numbered immutable archive. The layout keeps the names archives already on
disk use (`<20 digits>.session`, `adopted-<20 digits>`).
*/
module session_archive;

import session_record : decodeSession, encodeSession, SessionRecord, SessionSelection, SessionTab;
import sparkles.base.expected : Expected, err, ok;
import sparkles.recovery.archive : appendGeneration, ArchiveCleanup, ArchiveLayout, generationOf,
    pruneArchive, readGeneration, WriteReceipt;
import sparkles.recovery.directory : LeasedDirectory;
import std.path : buildPath;

/// Where and how the editor's archive keeps its generations and adoption markers.
enum ArchiveLayout sessionLayout = ArchiveLayout(".session", "adopted-", "SPARKLES-EDITOR-ADOPTED/1");

/// Recognize a canonical positive generation filename; zero means an unrelated entry.
ulong sessionGenerationOfName(scope const(char)[] name) @safe pure nothrow @nogc
    => generationOf(sessionLayout, name);

/// Keep the two newest valid records at or below the acknowledged cutoff (`pruneArchive`).
ArchiveCleanup pruneSessionArchive(LeasedDirectory directory, ulong durableThrough) @safe nothrow
    => pruneArchive(directory, durableThrough, sessionLayout, (ulong g, string b) => validSession(g, b));

/// A payload is valid when it decodes to the generation its name says.
string validSession(ulong generation, string bytes) @safe nothrow
{
    auto record = decodeSession(bytes);
    if (record.hasError) return record.error;
    if (record.value.generation != generation)
        return "The recovery generation does not match its file identity.";
    return null;
}

/**
Append a positive generation without ever replacing a previous checkpoint.
The caller supplies an existing private directory whose creation is already
durable. A successful receipt acknowledges the file commit and separately
reports directory durability.
*/
Expected!WriteReceipt appendSessionGeneration(string directory, in SessionRecord record) @safe nothrow
{
    if (!record.generation) return err!WriteReceipt("Recovery generations must be positive.");
    auto encoded = encodeSession(record);
    if (encoded.hasError) return err!WriteReceipt(encoded.error);
    return appendGeneration(directory, record.generation, encoded.value, sessionLayout);
}

/// Validate the complete immutable record and its identity before returning recovered contents.
Expected!SessionRecord readSessionGeneration(string directory, ulong generation) @safe nothrow
{
    auto bytes = readGeneration(directory, generation, sessionLayout);
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
    import sparkles.recovery.directory : SessionDirectory = LeasedDirectory;
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
