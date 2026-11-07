/** Versioned, integrity-checked editor session records. */
module session_record;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.hash : blake3;
import sparkles.base.text.cstring : hasInteriorNul;
import sparkles.base.text.utf8 : validateUtf8;
import sparkles.base.text.seek : isGraphemeBoundary;
import sparkles.wired.json : fromJSON, toJSON;
import sparkles.wired.policy : WireStrict;
import sparkles.text_buffer.summary : Affinity;

/// Byte positions, boundary affinity and a portable vertical-goal sentinel.
@WireStrict
struct SessionSelection
{
    ulong anchor, head;
    Affinity affinity;
    ulong goal = ulong.max;
}

/// Protected byte interval, independent of the platform's size_t width.
@WireStrict
struct SessionSpan { ulong start, end; }

/// Owned strings are serialized on a worker, separately from persistent Text snapshots.
@WireStrict
struct SessionTab
{
    ulong id;
    string name, path, language = "text";
    bool bom;
    string predominant = "\n";
    string content, savedContent;
    SessionSelection[] selections;
    ulong primary, firstLine;
    SessionSpan[] readOnly;
    string durabilityWarning;
}

/// One coherent session generation, including its accepted theme and active document.
@WireStrict
struct SessionRecord
{
    ulong generation;
    ulong active;
    string theme;
    SessionTab[] tabs;
}

private enum header = "SPARKLES-EDITOR-SESSION/2\n";
private enum digestLength = 32;

/// Encode one generation with a format version and BLAKE3 payload integrity.
Expected!string encodeSession(in SessionRecord record) @safe nothrow
{
    if (auto error = invalidRecord(record)) return err!string(error);
    const payload = (() @trusted => toJSON(record))();
    if (payload.hasError) return err!string("The session could not be encoded.");
    if (payload.value.length > size_t.max - header.length - digestLength)
        return err!string("The session is too large to encode.");
    const digest = blake3(payload.value[]);
    auto bytes = new char[header.length + digestLength + payload.value.length];
    bytes[0 .. header.length] = header;
    foreach (i, byte_; digest) bytes[header.length + i] = cast(char) byte_;
    bytes[header.length + digestLength .. $] = payload.value[];
    return ok((() @trusted => cast(string) bytes)());
}

/// Refuse unsupported, truncated or corrupt records without changing their stored bytes.
Expected!SessionRecord decodeSession(string bytes) @safe nothrow
{
    if (bytes.length < header.length + digestLength || bytes[0 .. header.length] != header)
        return err!SessionRecord("The session version is unsupported or its header is incomplete.");
    const payload = bytes[header.length + digestLength .. $];
    const digest = blake3(payload);
    foreach (i, byte_; digest)
        if (cast(ubyte) bytes[header.length + i] != byte_)
            return err!SessionRecord("The session checksum does not match; the record was preserved.");
    auto record = (() @trusted => fromJSON!SessionRecord(payload))();
    if (record.hasError) return err!SessionRecord("The session payload is invalid; the record was preserved.");
    if (auto error = invalidRecord(record.value)) return err!SessionRecord(error);
    return ok(record.value);
}

private string invalidRecord(in SessionRecord record) @safe pure nothrow
{
    if (validateUtf8(record.theme).hasError) return "The session theme is not valid UTF-8.";
    bool[ulong] ids;
    bool active = record.tabs.length == 0 && record.active == 0;
    foreach (ref tab; record.tabs)
    {
        if (!tab.id || tab.id in ids) return "The session has invalid or repeated document identities.";
        ids[tab.id] = true;
        active |= tab.id == record.active;
        if (tab.path.hasInteriorNul) return "A session document path contains a NUL byte.";
        foreach (value; [tab.name, tab.path, tab.language, tab.content, tab.savedContent, tab.durabilityWarning])
            if (validateUtf8(value).hasError) return "A session document is not valid UTF-8.";
        if (tab.predominant != "\n" && tab.predominant != "\r\n")
            return "A session document has an invalid newline convention.";
        if (!tab.selections.length || tab.primary >= tab.selections.length)
            return "A session document has no valid primary selection.";
        foreach (selection; tab.selections)
        {
            if (selection.affinity != Affinity.before && selection.affinity != Affinity.after)
                return "A session selection has an invalid boundary affinity.";
            foreach (position; [selection.anchor, selection.head])
                if (!validPosition(tab.content, position)
                    || !isGraphemeBoundary(tab.content, cast(size_t) position))
                    return "A session selection is outside a grapheme boundary.";
        }
        foreach (span; tab.readOnly)
            if (span.start > span.end || !validPosition(tab.content, span.start)
                || !validPosition(tab.content, span.end))
                return "A session protected interval is outside a UTF-8 boundary.";
    }
    return active ? null : "The session active document does not exist.";
}

private bool validPosition(string content, ulong position) @safe pure nothrow @nogc
    => position <= content.length && (position == content.length
        || (cast(ubyte) content[cast(size_t) position] & 0xc0) != 0x80);

/// Unicode, line envelopes, selection direction and saved baselines survive recovery encoding.
@("editor.sessionRecord.exactRoundTrip")
@safe nothrow unittest
{
    import sparkles.text_buffer.summary : Affinity;
    SessionRecord original;
    original.generation = 42;
    original.active = 7;
    original.theme = "github-dark";
    original.tabs = [SessionTab(id: 7, name: "日本語.txt", path: "/sample/日本語.txt",
        bom: true, predominant: "\r\n", content: "a\r\n日本語\nb", savedContent: "a\r\nb",
        selections: [SessionSelection(6, 3, Affinity.after, 9)], firstLine: 1,
        readOnly: [SessionSpan(0, 3)], durabilityWarning: "directory sync unconfirmed")];
    const encoded = encodeSession(original);
    assert(encoded.hasValue);
    const decoded = decodeSession(encoded.value);
    assert(decoded.hasValue && decoded.value == original);
}

/// Invalid document identities and caret bytes never enter a recovery checkpoint.
@("editor.sessionRecord.rejectsInvalidMetadata")
@safe nothrow unittest
{
    foreach (which; 0 .. 9)
    {
        SessionRecord record;
        record.active = 7;
        record.tabs = [SessionTab(id: 7, name: "sample", content: "é",
            selections: [SessionSelection(0, 2)])];
        final switch (which)
        {
        case 0: record.tabs[0].selections[0].head = 1; break;
        case 1: record.active = 8; break;
        case 2: record.tabs ~= record.tabs[0]; break;
        case 3: record.tabs[0].id = 0; break;
        case 4: record.tabs[0].primary = 1; break;
        case 5: record.tabs[0].path = "/tmp/bad\0path"; break;
        case 6:
            record.tabs[0].content = "e\u0301";
            record.tabs[0].selections[0].head = 1;
            break;
        case 7:
            record.tabs[0].content = "\r\n";
            record.tabs[0].selections[0].head = 1;
            break;
        case 8: record.tabs[0].readOnly = [SessionSpan(0, 1)]; break;
        }
        assert(encodeSession(record).hasError);
    }
}

/// Every truncated prefix and every one-byte corruption is refused.
@("editor.sessionRecord.rejectsTruncationAndCorruption")
@safe nothrow unittest
{
    SessionRecord record;
    record.generation = 9;
    const encoded = encodeSession(record);
    assert(encoded.hasValue);
    foreach (length; 0 .. encoded.value.length)
        assert(decodeSession(encoded.value[0 .. length]).hasError);
    foreach (i; 0 .. encoded.value.length)
    {
        auto corrupted = encoded.value.dup;
        corrupted[i] = cast(char)(cast(ubyte) corrupted[i] ^ 1);
        assert(decodeSession(corrupted.idup).hasError);
    }
    assert(decodeSession(encoded.value).hasValue);
}
