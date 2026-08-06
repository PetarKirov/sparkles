// The diff **session** (`DVS4`): a multi-file diff as an ordered changed-file
// list with per-file status and stats — the `SourceSet` analog for diffs, and
// the substrate every sink consumes.
//
// The split is deliberate. `sparkles:diff`'s `DiffDoc` is the `@nogc` model of
// what changed; a session is what a *reviewer* navigates: an ordered list with
// a status per file, add/remove counts, a collapse flag, and a per-file error
// slot (`DVS5`) so one unreadable side degrades that entry instead of the
// whole session. Both interactive sinks navigate it (`DVG1`/`DVG3`) and the
// static sinks render it fully expanded — one value, four sinks, exactly as
// `SourceSet` works for documents.
//
// Entries are parallel to `DiffDoc.files` by index, which is also how
// `Document.diffSides` is indexed — so the session, the model and the side
// texts all agree on "file number 3" with no lookup.
module diff_session;

import std.conv : text;

import sparkles.diff.model : DiffDoc, FileEntry, RowKind;

/// What happened to a file, as a reviewer names it.
enum FileChange : ubyte
{
    modified, /// both sides exist
    added,    /// no old side
    removed,  /// no new side
    renamed,  /// both sides exist under different paths
}

/// One changed file in a session.
struct SessionEntry
{
    string oldPath;
    string newPath;
    /// Display name: the path, or `old → new` for a rename.
    string display;
    FileChange change;
    bool binary;
    uint hunks;
    uint added;   /// added rows
    uint removed; /// removed rows
    /// `DVG3`: the file's hunks are hidden (the header still renders).
    bool collapsed;
    /// `DVS5`: why this file could not be shown — rendered in-band under the
    /// header, leaving the rest of the session intact. Empty when fine.
    string error;
}

/**
An ordered set of changed files plus the selected one. Mirrors
`source_set.SourceSet`'s navigation surface deliberately: the two are the same
idea over different content, and the keymap should not have to care which is
under the cursor.
*/
struct DiffSession
{
    SessionEntry[] entries;
    size_t index; /// the selected entry (always < `entries.length` when non-empty)

@safe pure nothrow @nogc:

    /// `true` when nothing changed.
    bool empty() const scope => entries.length == 0;

    /// The number of changed files.
    size_t length() const scope => entries.length;

    /// The selected file.
    ref const(SessionEntry) current() const return scope
    in (!empty)
        => entries[index];

    /// ditto
    ref SessionEntry currentMut() return scope
    in (!empty)
        => entries[index];

    /// `true` iff a previous/next file exists (no wraparound — the ends are
    /// where a reviewer expects to stop).
    bool hasPrev() const scope => !empty && index > 0;
    /// ditto
    bool hasNext() const scope => !empty && index + 1 < entries.length;

    /// Moves the selection by `delta`, clamping at both ends. Returns `true`
    /// iff the selection actually changed.
    bool move(int delta) scope
    {
        if (empty)
            return false;
        const long want = cast(long) index + delta;
        const size_t clamped = want < 0 ? 0
            : (want >= cast(long) entries.length ? entries.length - 1 : cast(size_t) want);
        const changed = clamped != index;
        index = clamped;
        return changed;
    }

    /// Total added/removed rows across the session (the summary line).
    uint totalAdded() const scope
    {
        uint n;
        foreach (ref e; entries)
            n += e.added;
        return n;
    }

    /// ditto
    uint totalRemoved() const scope
    {
        uint n;
        foreach (ref e; entries)
            n += e.removed;
        return n;
    }
}

/// The git-style path spelling for "this side does not exist".
private enum devNull = "/dev/null";

/**
Builds a session from a parsed or computed diff. Pure over the model: no
filesystem, no git — which is what makes the classification testable from a
patch literal.
*/
DiffSession buildDiffSession(const ref DiffDoc doc) @safe
{
    SessionEntry[] entries;
    entries.reserve(doc.files.length);
    foreach (fi; 0 .. doc.files.length)
        entries ~= entryFor(doc, doc.files[fi]);
    return DiffSession(entries: entries);
}

private SessionEntry entryFor(const ref DiffDoc doc, in FileEntry file) @safe
{
    const oldPath = doc.pathText(file.oldPath).idup;
    const newPath = doc.pathText(file.newPath).idup;

    SessionEntry e = {
        oldPath: oldPath, newPath: newPath,
        change: classify(oldPath, newPath),
        binary: file.binary, hunks: file.hunksCount,
    };
    e.display = e.change == FileChange.renamed
        ? text(oldPath, " → ", newPath)
        : (e.change == FileChange.removed ? oldPath : newPath);

    foreach (ref hunk; doc.fileHunks(file))
        foreach (ref row; doc.hunkRows(hunk))
            final switch (row.kind) with (RowKind)
            {
                case added:   ++e.added;   break;
                case removed: ++e.removed; break;
                case context: break;
            }
    return e;
}

/// The change kind implied by a file's two path spellings.
FileChange classify(scope const(char)[] oldPath, scope const(char)[] newPath)
    @safe pure nothrow @nogc
{
    const noOld = oldPath.length == 0 || oldPath == devNull;
    const noNew = newPath.length == 0 || newPath == devNull;
    if (noOld && !noNew)
        return FileChange.added;
    if (noNew && !noOld)
        return FileChange.removed;
    return oldPath == newPath ? FileChange.modified : FileChange.renamed;
}

/// The one-character status marker, matching the explorer's `GitStatus`
/// vocabulary so a changed-files tree and a diff header read the same.
char statusGlyph(FileChange c) @safe pure nothrow @nogc
{
    final switch (c) with (FileChange)
    {
        case modified: return 'M';
        case added:    return 'A';
        case removed:  return 'D';
        case renamed:  return 'R';
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("diff_session.classify.pathSpellings")
@safe pure nothrow @nogc
unittest
{
    assert(classify("a.d", "a.d") == FileChange.modified);
    assert(classify("/dev/null", "new.d") == FileChange.added);
    assert(classify("old.d", "/dev/null") == FileChange.removed);
    assert(classify("old.d", "new.d") == FileChange.renamed);
    // An absent spelling is as good as `/dev/null` — the parser leaves the
    // span empty for a header a patch omits.
    assert(classify("", "new.d") == FileChange.added);
    assert(classify("old.d", "") == FileChange.removed);
    // Both missing is not a rename to nowhere: nothing to say, call it
    // modified rather than invent a status.
    assert(classify("", "") == FileChange.modified);
}

@("diff_session.statusGlyph.coversEveryKind")
@safe pure nothrow @nogc
unittest
{
    // A `final switch` over the enum: adding a kind without a glyph is a
    // compile error, which is the point of asserting the whole set here.
    assert(statusGlyph(FileChange.modified) == 'M');
    assert(statusGlyph(FileChange.added) == 'A');
    assert(statusGlyph(FileChange.removed) == 'D');
    assert(statusGlyph(FileChange.renamed) == 'R');
}

@("diff_session.buildDiffSession.statusesAndCounts")
@safe unittest
{
    import sparkles.diff : parsePatch;

    // Three files, three statuses, in patch order.
    enum patch =
        "--- a/keep.d\n+++ b/keep.d\n@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n" ~
        "--- /dev/null\n+++ b/new.d\n@@ -0,0 +1,2 @@\n+alpha\n+beta\n" ~
        "--- a/gone.d\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-bye\n";

    auto res = parsePatch(patch);
    assert(!res.hasError);
    const dd = res.value;
    auto session = buildDiffSession(dd);

    assert(session.length == 3 && !session.empty);
    assert(session.entries[0].change == FileChange.modified);
    assert(session.entries[0].display == "keep.d");
    assert(session.entries[0].added == 1 && session.entries[0].removed == 1);
    assert(session.entries[0].hunks == 1);

    assert(session.entries[1].change == FileChange.added);
    assert(session.entries[1].display == "new.d");
    assert(session.entries[1].added == 2 && session.entries[1].removed == 0);

    assert(session.entries[2].change == FileChange.removed);
    // A removed file displays the path it had, not the `/dev/null` it became.
    assert(session.entries[2].display == "gone.d");
    assert(session.entries[2].added == 0 && session.entries[2].removed == 1);

    assert(session.totalAdded == 3 && session.totalRemoved == 2);
    // Entries are parallel to the model's files, which is what lets the view
    // pair an entry with its side texts by index alone.
    assert(session.length == dd.files.length);
}

@("diff_session.buildDiffSession.renameDisplaysBothPaths")
@safe unittest
{
    import sparkles.diff : parsePatch;

    enum patch = "--- a/old/name.d\n+++ b/new/name.d\n@@ -1 +1 @@\n-x\n+y\n";
    const dd = parsePatch(patch).value;
    auto session = buildDiffSession(dd);
    assert(session.entries[0].change == FileChange.renamed);
    assert(session.entries[0].display == "old/name.d → new/name.d");
}

@("diff_session.move.clampsAndReportsChange")
@safe pure nothrow
unittest
{
    auto s = DiffSession(entries: [
        SessionEntry(display: "a"), SessionEntry(display: "b"),
        SessionEntry(display: "c"),
    ]);
    assert(s.current.display == "a" && !s.hasPrev && s.hasNext);
    assert(s.move(1) && s.current.display == "b");
    assert(s.move(5) && s.current.display == "c", "clamps to the last file");
    assert(!s.move(1), "no wraparound at the end");
    assert(s.move(-9) && s.index == 0);
    assert(!s.move(-1) && !s.hasPrev);

    // Collapse is per entry, so it survives navigation.
    s.currentMut.collapsed = true;
    assert(s.move(1) && !s.current.collapsed);
    assert(s.move(-1) && s.current.collapsed);

    DiffSession none;
    assert(none.empty && !none.move(1) && !none.hasPrev && !none.hasNext);
    assert(none.totalAdded == 0 && none.totalRemoved == 0);
}
