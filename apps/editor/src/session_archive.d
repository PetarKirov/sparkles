/** Immutable session-generation files, written only by background storage work. */
module session_archive;

import session_record : decodeSession, encodeSession, SessionRecord, SessionSelection, SessionTab;
import document_files : readRegularBytes, saveAtomic, SaveReceipt;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.cstring : hasInteriorNul;
import sparkles.base.text.writers : writeIntegerPadded;
import std.path : buildPath;

private enum size_t maximumGenerationBytes = 512 * 1024 * 1024;

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
