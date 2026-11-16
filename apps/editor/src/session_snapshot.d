/** Captured document state: persistent text stays chunked until worker serialization. */
module session_snapshot;

import editor_document : Document;
import session_record : SessionRecord, SessionSelection, SessionSettings, SessionSpan, SessionTab;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.selection : EditRange;
import sparkles.ui.editor.state : ReadOnlySpan;

private final class CapturedTab
{
    ulong id;
    string name, path, language, predominant, durabilityWarning;
    bool bom;
    size_t firstLine;
    Text content, saved;
    EditRange[] ranges;
    size_t primary;
    ReadOnlySpan[] readOnly;

    this(Document source) @safe pure nothrow
    {
        id = source.id;
        name = source.name;
        path = source.path;
        language = source.language;
        predominant = source.predominant;
        durabilityWarning = source.durabilityWarning;
        bom = source.bom;
        firstLine = source.firstLine;
        content = source.field.state.text;
        saved = source.saved;
        ranges = source.field.state.selection.ranges.dup;
        primary = source.field.state.selection.primaryIndex;
        readOnly = source.field.state.readOnly[].dup;
    }

    bool matches(Document source) const @safe pure nothrow @nogc
        => id == source.id && name == source.name && path == source.path
            && language == source.language && predominant == source.predominant
            && durabilityWarning == source.durabilityWarning && bom == source.bom
            && firstLine == source.firstLine && content == source.field.state.text
            && saved == source.saved && primary == source.field.state.selection.primaryIndex
            && ranges == source.field.state.selection.ranges && readOnly == source.field.state.readOnly[];

    SessionTab record() const @safe pure nothrow
    {
        SessionTab result;
        result.id = id;
        result.name = name;
        result.path = path;
        result.language = language;
        result.predominant = predominant;
        result.durabilityWarning = durabilityWarning;
        result.bom = bom;
        result.firstLine = firstLine;
        result.content = copyBytes(content);
        result.savedContent = saved == content ? result.content : copyBytes(saved);
        result.primary = primary;
        foreach (range; ranges)
            result.selections ~= SessionSelection(range.anchor, range.head, range.affinity,
                range.goal == EditRange.noGoal ? ulong.max : range.goal);
        foreach (span; readOnly)
            result.readOnly ~= SessionSpan(span.start, span.end);
        return result;
    }
}

/**
A sealed session capture. Creation retains persistent text and copies only
selection/constraint metadata; it never flattens document contents. GC arrays
hold class references or numeric metadata, never reference-counted Text values.
Call record only on the storage worker.
*/
final class SessionSnapshot
{
    private CapturedTab[] tabs;
    private ulong revision_, active;
    private string theme;
    private SessionSettings settings;

    private this(scope Document[] documents, ulong active, string theme, ulong revision,
        SessionSettings settings) @safe pure nothrow
    in (revision != 0)
    {
        this.active = active;
        this.theme = theme;
        this.settings = settings;
        revision_ = revision;
        foreach (document; documents) tabs ~= new CapturedTab(document);
    }

    /// Retain a coherent revision on the application thread.
    static SessionSnapshot capture(scope Document[] documents, ulong active, string theme, ulong revision,
        SessionSettings settings = SessionSettings.init) @safe pure nothrow
        => new SessionSnapshot(documents, active, theme, revision, settings);

    ulong revision() const @safe pure nothrow @nogc => revision_;

    /// Compare borrowed current state without flattening or allocating.
    bool matches(scope Document[] documents, ulong active, string theme,
        in SessionSettings settings = SessionSettings.init) const @safe pure nothrow @nogc
    {
        if (this.active != active || this.theme != theme || this.settings != settings || tabs.length != documents.length) return false;
        foreach (i, tab; tabs) if (!tab.matches(documents[i])) return false;
        return true;
    }

    /// Flatten a captured state on the worker, giving its immutable file generation.
    SessionRecord record(ulong generation) const @safe pure nothrow
    {
        SessionRecord result;
        result.generation = generation;
        result.active = active;
        result.theme = theme;
        result.settings = settings;
        foreach (tab; tabs) result.tabs ~= tab.record();
        return result;
    }
}

private string copyBytes(in Text content) @safe pure nothrow
{
    auto bytes = new char[content.length];
    content.copyTo(0, bytes.length, bytes);
    return (() @trusted => cast(string) bytes)();
}

/// Later document edits cannot alter a captured recovery revision or its constraints.
@("editor.sessionSnapshot.retainsCapturedState")
@safe unittest
{
    import editor_document : Document;
    import sparkles.text_buffer.summary : Affinity;
    import sparkles.ui.editor.selection : EditRange, SelectionSet;
    import sparkles.ui.editor.state : ReadOnlySpan;
    auto document = new Document(7, "draft", "original\r\n");
    document.field.insert("edit");
    document.field.state.selection = SelectionSet.single(EditRange(3, 1, Affinity.after, 9));
    document.field.state.readOnly.put(ReadOnlySpan(0, 2));
    document.field.state.readOnly.put(ReadOnlySpan(4, 6));
    document.durabilityWarning = "directory sync unconfirmed";
    Document[] documents = [document];
    auto snapshot = SessionSnapshot.capture(documents, 7, "github-dark", 42);
    assert(snapshot.matches(documents, 7, "github-dark"));
    document.field.state.readOnly.clear();
    document.field.insert("later");
    document.durabilityWarning = null;
    assert(!snapshot.matches(documents, 7, "github-dark"));
    const record = snapshot.record(9);
    assert(snapshot.revision == 42 && record.generation == 9 && record.active == 7);
    assert(record.tabs[0].content == "original\r\nedit" && record.tabs[0].savedContent == "original\r\n");
    assert(record.tabs[0].selections[0].anchor == 3 && record.tabs[0].selections[0].head == 1);
    assert(record.tabs[0].selections[0].affinity == Affinity.after && record.tabs[0].selections[0].goal == 9);
    assert(record.tabs[0].readOnly.length == 2 && record.tabs[0].readOnly[0].end == 2);
    assert(record.tabs[0].durabilityWarning == "directory sync unconfirmed");
}
