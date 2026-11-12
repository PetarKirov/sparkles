/** Discover claimable recovery archives without touching document originals. */
module session_discovery;

import session_archive : readSessionGeneration, sessionGenerationOfName;
import session_directory : DirectoryIssueKind, SessionDirectory;
import session_record : SessionRecord;
import std.algorithm.sorting : sort;
import std.file : dirEntries, SpanMode;
import std.path : baseName;
import editor_document : Document;
import document_text : DocumentBytes, encodeDocument;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.selection : EditRange, SelectionSet;
import sparkles.ui.editor.state : ReadOnlySpan;
import document_files : readRegularBytes, saveAtomic, SaveAuthorization, SaveReceipt;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.expected : Expected, err;
import sparkles.base.text.writers : writeIntegerPadded;
import std.path : buildPath;

/// An immutable record plus the exclusive lease held while its restore offer is outstanding.
final class RecoveryOffer
{
    private SessionDirectory directory;
    private SessionRecord record_;
    private Document[] documents;

    private this(SessionDirectory directory, SessionRecord record) @safe pure nothrow
    {
        this.directory = directory;
        record_ = record;
        foreach (stored; record.tabs)
        {
            auto tab = new Document(stored.id, stored.name, stored.content);
            tab.path = stored.path;
            if (stored.savedContent != stored.content) tab.saved = Text(stored.savedContent);
            tab.bom = stored.bom;
            tab.predominant = stored.predominant;
            if (stored.path.length)
                tab.savedBytes = encodeDocument(DocumentBytes(stored.savedContent, stored.bom, stored.predominant));
            tab.language = stored.language;
            const lines = tab.field.state.text.lineCount;
            tab.firstLine = stored.firstLine >= lines ? lines - 1 : cast(size_t) stored.firstLine;
            tab.followCaret = false;
            tab.durabilityWarning = stored.durabilityWarning;
            EditRange[] ranges;
            foreach (range; stored.selections)
                ranges ~= EditRange(cast(size_t) range.anchor, cast(size_t) range.head, range.affinity,
                    range.goal >= size_t.max ? EditRange.noGoal : cast(size_t) range.goal);
            tab.field.state.selection = SelectionSet.of(ranges, cast(size_t) stored.primary);
            foreach (span; stored.readOnly)
                tab.field.state.readOnly.put(ReadOnlySpan(cast(size_t) span.start, cast(size_t) span.end));
            documents ~= tab;
        }
    }

    string path() const @safe pure nothrow @nogc => directory.path;
    const(SessionRecord) record() const @safe pure nothrow @nogc => record_;
    size_t documentCount() const @safe pure nothrow @nogc => documents.length;
    Document document(size_t index) @safe pure nothrow @nogc
        in (index < documents.length) => documents[index];
    void close() @safe nothrow @nogc { directory.close(); }

    /**
    Worker-only retirement after a new archive durably includes this offer.
    The marker names this exact source generation; source records remain
    intact. Retrying a valid marker re-syncs its replacement before acknowledgment.
    Invalid existing markers are preserved rather than overwritten.
    */
    Expected!SaveReceipt retire() @safe nothrow
    {
        if (!directory.owned) return err!SaveReceipt("The restored archive lease is unavailable.");
        const marker = markerBytes(record_.generation);
        const path = markerPath(directory.path, record_.generation);
        const existing = readRegularBytes(path, 256);
        if (existing.hasValue && existing.value != marker)
            return err!SaveReceipt("A damaged recovery adoption marker was preserved.");
        try
        {
            return saveAtomic(path, marker, existing.hasValue
                ? SaveAuthorization.replaceConfirmed : SaveAuthorization.createOnly);
        }
        catch (Exception) { return err!SaveReceipt("The restored archive could not be retired."); }
    }
}

private string markerBytes(ulong generation) @safe pure nothrow
{
    UniqueBuffer!(char, 64) token;
    token ~= "SPARKLES-EDITOR-ADOPTED/1\n";
    writeIntegerPadded!10(token, generation, 20);
    token ~= '\n';
    return token[].idup;
}

private string markerPath(string directory, ulong generation) @safe pure nothrow
{
    UniqueBuffer!(char, 64) name;
    name ~= "adopted-";
    writeIntegerPadded!10(name, generation, 20);
    return buildPath(directory, name[].idup);
}

/// Prepared restore tabs preserve the saved-byte baseline, selections and protected intervals.
@("editor.sessionDiscovery.preparesEditingState")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import session_archive : appendSessionGeneration;
    import session_record : SessionTab, SessionSelection, SessionSpan;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.text_buffer.summary : Affinity;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    const base = buildPath(fixture.dir, "sessions");
    auto old = SessionDirectory.create(base, fixture.dir);
    assert(old.hasValue);
    SessionRecord record;
    record.generation = 1;
    record.active = 7;
    record.theme = "github-dark";
    record.tabs = [SessionTab(id: 7, name: "draft.d", path: buildPath(fixture.dir, "original.d"),
        content: "edited\r\nsecond\r\nthird", savedContent: "disk", bom: true,
        predominant: "\r\n", firstLine: 2, language: "d",
        durabilityWarning: "unconfirmed directory sync", readOnly: [SessionSpan(0, 1)],
        selections: [SessionSelection(1, 3, Affinity.after, 9)])];
    assert(appendSessionGeneration(old.value.path, record).hasValue);
    old.value.close();
    auto catalog = discoverSessions(base);
    scope (exit) foreach (offer; catalog.offers) offer.close();
    assert(catalog.offers.length == 1);
    auto offer = catalog.offers[0];
    auto tab = offer.document(0);
    assert(tab.field.text == "edited\r\nsecond\r\nthird" && tab.dirty);
    assert(tab.savedBytes == "\xEF\xBB\xBFdisk" && tab.bom && tab.predominant == "\r\n");
    assert(tab.firstLine == 2 && !tab.followCaret && tab.language == "d");
    const range = tab.field.state.selection.primary;
    assert(range.anchor == 1 && range.head == 3 && range.affinity == Affinity.after && range.goal == 9);
    assert(tab.field.state.readOnly.length == 1 && tab.field.state.readOnly[0].end == 1);
    assert(tab.durabilityWarning == "unconfirmed directory sync");
}

/// Claimable offers and nonfatal warnings; damaged and unsupported files remain untouched.
struct RecoveryCatalog
{
    RecoveryOffer[] offers;
    string[] issues;
}

/**
Run on a CPU worker. Scan only immediate archive directories, skip active
owners, and offer each archive's newest valid nonempty session. Older valid
generations can recover from damaged or unsupported later records. The caller
must explicitly close every offered lease after deciding what to restore.
*/
RecoveryCatalog discoverSessions(string base) @safe nothrow
{
    RecoveryCatalog catalog;
    try
    {
        foreach (entry; dirEntries(base, SpanMode.shallow, false))
        {
            if (entry.isSymlink || !entry.isDir) continue;
            auto claimed = SessionDirectory.claim(entry.name);
            if (claimed.hasError)
            {
                if (claimed.error.kind == DirectoryIssueKind.unavailable)
                    catalog.issues ~= claimed.error.message;
                continue;
            }
            bool retained;
            scope (exit) if (!retained) claimed.value.close();
            ulong[] generations;
            foreach (file; dirEntries(entry.name, SpanMode.shallow, false))
            {
                if (file.isSymlink) continue;
                const generation = sessionGenerationOfName(baseName(file.name));
                if (generation) generations ~= generation;
            }
            generations.sort!"a > b";
            foreach (generation; generations)
            {
                auto found = readSessionGeneration(entry.name, generation);
                if (found.hasError) { catalog.issues ~= found.error; continue; }
                const marker = readRegularBytes(markerPath(entry.name, generation), 256);
                if (marker.hasValue && marker.value == markerBytes(generation)) break;
                if (marker.hasValue)
                    catalog.issues ~= "A damaged recovery adoption marker was preserved.";
                // A valid empty session is a deliberate empty state, not a reason
                // to resurrect tabs from an older generation.
                if (found.value.tabs.length)
                {
                    catalog.offers ~= new RecoveryOffer(claimed.value, found.value);
                    retained = true;
                }
                break;
            }
        }
    }
    catch (Exception) { catalog.issues ~= "Some recovery archives could not be listed."; }
    return catalog;
}

/// A damaged latest generation falls back to valid older contents; active owners are skipped.
@("editor.sessionDiscovery.fallbackAndActiveOwner")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import session_directory : SessionDirectory;
    import session_archive : appendSessionGeneration;
    import session_record : SessionRecord, SessionTab, SessionSelection;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    import std.file : write, readText;
    auto fixture = TmpFS.create();
    const base = buildPath(fixture.dir, "sessions");
    auto abandoned = SessionDirectory.create(base, fixture.dir);
    auto active = SessionDirectory.create(base, fixture.dir);
    assert(abandoned.hasValue && active.hasValue);
    scope (exit) active.value.close();
    const source = fixture.writeFile("unchanged original");
    SessionRecord record;
    record.active = 7;
    record.generation = 1;
    record.tabs = [SessionTab(id: 7, name: "draft", path: source,
        content: "recovered draft", savedContent: "unchanged original",
        selections: [SessionSelection(0, 0)])];
    assert(appendSessionGeneration(abandoned.value.path, record).hasValue);
    assert(appendSessionGeneration(active.value.path, record).hasValue);
    record.generation = 2;
    assert(appendSessionGeneration(abandoned.value.path, record).hasValue);
    const damagedPath = buildPath(abandoned.value.path, "00000000000000000002.session");
    (() @trusted { write(damagedPath, "damaged generation"); })();
    abandoned.value.close();
    auto catalog = discoverSessions(base);
    scope (exit) foreach (offer; catalog.offers) offer.close();
    assert(catalog.offers.length == 1 && catalog.issues.length == 1);
    assert(catalog.offers[0].record.generation == 1);
    assert(catalog.offers[0].record.tabs[0].content == "recovered draft");
    assert((() @trusted => readText(damagedPath))() == "damaged generation");
    assert((() @trusted => readText(source))() == "unchanged original");
}
