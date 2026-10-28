/**
The conflict view (`CFV2`–`CFV4`): a conflict-markered file shown as its
plain text and its conflicts, each conflict as aligned ours · base · theirs
columns, and resolved in place.

The file's text lives in the toolkit's editor, so every resolution is an
edit of it and undoable before the save (`CFV4`). Picking ours, theirs or
both replaces a conflict, markers and all. Editing it freely (the editor's
`EDU3`) leaves the marker lines read-only, so a hand edit changes a side
and a pick still resolves the conflict. A save writes the file once no
conflict remains.
*/
module sparkles.doc_view.conflict_view;

import sparkles.base.buffer : SharedBuffer;
import sparkles.diff.alignment : AlignedRow, alignSides;
import sparkles.diff.conflict : ConflictDoc, ConflictRegion, parseConflicts, RegionKind;
import sparkles.diff.model : Span;
import sparkles.input.events : KeyEvent;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.command : EditCommand, EditKind;
import sparkles.ui.editor.field : EditorField, FieldResult;
import sparkles.ui.editor.keys : EditorTarget;
import sparkles.ui.editor.selection : EditRange, SelectionSet;
import sparkles.ui.editor.state : EditorOptions, ReadOnlySpan;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;

/// How a conflict is resolved (`CFV4`).
enum Pick : ubyte
{
    ours,
    theirs,
    /// Ours, then theirs.
    both,
    /// Theirs, then ours.
    bothReversed,
}

/// A conflicted file being resolved.
struct ConflictSession
{
    /// The file it is written to.
    string path;
    /// The file's text, as resolved so far; its edits are the picks.
    EditorField result;
    /// The text as of the last edit, and its regions.
    string text;
    /// ditto
    ConflictDoc doc;
    /// The conflict in view, counted among the conflicts that remain.
    size_t current;
    /// Free editing: the editor has the keyboard.
    bool editing;

    /// Opens `text`, the conflicted file at `path`.
    static ConflictSession open(string path, string text, EditorTarget target) @safe
    {
        ConflictSession s;
        s.path = path;
        s.result = EditorField.make(text, EditorOptions.init, target);
        s.reparse();
        return s;
    }

    /// How many conflicts remain (`CFV3`).
    size_t remaining() const @safe pure nothrow @nogc => doc.conflicts;

    /// The conflict in view, or `null` when none remains.
    const(ConflictRegion)* currentConflict() const return @safe pure nothrow @nogc
    {
        size_t k;
        foreach (ref r; doc.regions[])
            if (r.kind == RegionKind.conflict && k++ == current)
                return &r;
        return null;
    }

    /// Moves to the next or previous conflict (`CFV3`); `false` at either end.
    bool move(int delta) @safe pure nothrow @nogc
    {
        const target = cast(long) current + delta;
        if (target < 0 || target >= cast(long) remaining)
            return false;
        current = cast(size_t) target;
        return true;
    }

    /**
    Resolves the conflict in view as `pick` says (`CFV4`): one edit of the
    file's text, undoable like any other. `false` when no conflict remains.
    */
    bool pick(Pick p) @safe
    {
        const r = currentConflict();
        if (r is null)
            return false;
        const ours = doc.slice(r.ours), theirs = doc.slice(r.theirs);
        string replacement;
        final switch (p)
        {
            case Pick.ours: replacement = ours.idup; break;
            case Pick.theirs: replacement = theirs.idup; break;
            case Pick.both: replacement = (ours ~ theirs).idup; break;
            case Pick.bothReversed: replacement = (theirs ~ ours).idup; break;
        }
        // The pick is the app's edit, not the reviewer's typing: the markers'
        // protection is for hand edits, and lifts for it.
        result.state.readOnly = typeof(result.state.readOnly).init;
        result.state.selection = SelectionSet.single(EditRange(r.whole.start, r.whole.end));
        cast(void) result.insert(replacement);
        if (current > 0 && current >= remainingAfterEdit())
            --current;
        reparse();
        return true;
    }

    /// Takes back the last pick or edit (`CFV4`); `false` with none.
    bool undo() @safe
    {
        const r = result.run(EditCommand.of(EditKind.undo));
        reparse();
        return r.changed;
    }

    /**
    Gives the editor the keyboard, the marker lines read-only (`EDU3`), the
    caret at the conflict in view.
    */
    void edit() @safe
    {
        editing = true;
        protectMarkers();
        if (const r = currentConflict())
            result.state.selection = SelectionSet.caret(r.ours.start);
    }

    /// One key while editing; Escape gives the keyboard back.
    FieldResult key(in KeyEvent k) @safe
    {
        auto r = result.key(k);
        if (r.cancelled)
            editing = false;
        if (r.changed)
        {
            reparse();
            protectMarkers();
        }
        return r;
    }

    /**
    Writes the resolved file through `write`, which reports a failure as a
    message. Refused while a conflict remains.
    */
    string save(scope string delegate(string path, string text) @safe write) @safe
    {
        import std.conv : text_ = text;

        if (remaining)
            return text_(remaining, remaining == 1 ? " conflict remains" : " conflicts remain");
        return write(path, text);
    }

    private size_t remainingAfterEdit() @safe pure nothrow
        => parseConflicts(result.text).conflicts;

    private void reparse() @safe
    {
        text = result.text;
        doc = parseConflicts(text);
        if (current >= remaining && remaining)
            current = remaining - 1;
    }

    /// Every marker line read-only, so a hand edit cannot break a conflict's
    /// shape (`EDT10`).
    private void protectMarkers() @safe
    {
        typeof(result.state.readOnly) spans;
        foreach (ref r; doc.regions[])
        {
            if (r.kind != RegionKind.conflict)
                continue;
            spans.put(ReadOnlySpan(r.whole.start, r.ours.start)); // <<<<<<<
            if (r.hasBase)
            {
                spans.put(ReadOnlySpan(r.ours.end, r.base.start)); // |||||||
                spans.put(ReadOnlySpan(r.base.end, r.theirs.start)); // =======
            }
            else
                spans.put(ReadOnlySpan(r.ours.end, r.theirs.start)); // =======
            spans.put(ReadOnlySpan(r.theirs.end, r.whole.end)); // >>>>>>>
        }
        result.state.readOnly = spans;
    }
}

/// Below this many columns the three panes stack (`CFV2`, the `DVL3` analog).
enum int minThreeWayWidth = 90;

/// The lines of `s`, without their breaks.
private const(char)[][] linesOf(const(char)[] s) @safe pure nothrow
{
    const(char)[][] lines;
    size_t start;
    foreach (i, c; s)
        if (c == '\n')
        {
            lines ~= s[start .. i];
            start = i + 1;
        }
    if (start < s.length)
        lines ~= s[start .. $];
    return lines;
}

/**
The conflict view (`CFV2`, `CFV3`): a header with the count that remains;
the plain text, long runs folded to their count; each conflict under a
line naming its sides, as aligned ours · base · theirs columns, stacked
below `minThreeWayWidth`. While editing, the whole file in the editor, its
markers drawn read-only (`EDR5`).
*/
WidgetTree viewConflict(const ref ConflictSession s, int widthCols, string hint = null) @safe
{
    import sparkles.ui.components.editor : editorView, EditorViewOptions;
    import std.conv : text;

    Builder b;
    uint[] rows;
    const remaining = s.remaining;
    rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [
        TextSpan(s.path, slot: Slot.chromeAccent),
        TextSpan(remaining ? text("  ", remaining, remaining == 1 ? " conflict" : " conflicts",
            " remaining") : "  resolved — save to write it", slot: Slot.muted),
    ]));
    if (hint.length)
        rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [TextSpan(hint, slot: Slot.muted)]));

    if (s.editing)
    {
        EditorViewOptions eopt;
        rows ~= editorView(b, s.result.state, eopt);
    }
    else
    {
        size_t k;
        foreach (ref r; s.doc.regions[])
        {
            if (r.kind == RegionKind.plain)
                rows ~= plainRows(b, s.doc.slice(r.whole), r.line);
            else
                rows ~= conflictBlock(b, s.doc, r, k, remaining, k == s.current, widthCols);
            k += r.kind == RegionKind.conflict;
        }
    }
    const root = b.add(Widget(kind: WidgetKind.column, children: rows, width: SizeSpec.grow()));
    return b.finish(root);
}

/// A plain run: its lines, the middle of a long one folded to a count.
private uint[] plainRows(ref Builder b, const(char)[] run, uint firstLine) @safe
{
    import std.conv : text;

    enum keep = 3;
    const lines = linesOf(run);
    uint[] rows;
    foreach (i, l; lines)
    {
        if (lines.length > 2 * keep + 1 && i == keep)
        {
            rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [TextSpan(
                text("   ⋯ ", lines.length - 2 * keep, " unchanged lines"), slot: Slot.muted)]));
            continue;
        }
        if (lines.length > 2 * keep + 1 && i > keep && i < lines.length - keep)
            continue;
        rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [
            TextSpan(text(firstLine + i, " ").rightAligned(6), slot: Slot.muted),
            TextSpan(l),
        ]));
    }
    return rows;
}

/// `s` right-aligned in `width` columns.
private string rightAligned(string s, size_t width) @safe pure nothrow
{
    import std.array : replicate;

    return s.length >= width ? s : replicate(" ", width - s.length) ~ s;
}

/// One conflict: a line naming it and its sides, then the sides aligned.
private uint conflictBlock(ref Builder b, const ref ConflictDoc doc, const ref ConflictRegion r,
    size_t index, size_t count, bool current, int widthCols) @safe
{
    import std.conv : text;

    const base = r.hasBase ? doc.slice(r.base) : null;
    uint[] rows = [b.add(Widget(kind: WidgetKind.rich, spans: [
        TextSpan(current ? "▶ " : "  ", slot: Slot.chromeAccent),
        TextSpan(text("conflict ", index + 1, "/", count), slot: Slot.warn),
        TextSpan(text("  ours: ", doc.slice(r.oursLabel), "  ·  theirs: ",
            doc.slice(r.theirsLabel)), slot: Slot.muted),
    ]))];

    // `DVM2`'s N-way pairing: ours and theirs against the base, or against
    // ours where the style kept no base.
    const reference = r.hasBase ? base : doc.slice(r.ours);
    const(char[])[2] sides = [doc.slice(r.ours), doc.slice(r.theirs)];
    SharedBuffer!(AlignedRow, 16) aligned;
    alignSides(reference, sides[], aligned);
    const refLines = linesOf(reference), oursLines = linesOf(sides[0]), theirLines = linesOf(sides[1]);

    static const(char)[] at(const(const(char)[])[] lines, int i) @safe pure nothrow @nogc
        => i >= 0 && i < lines.length ? lines[i] : null;

    if (widthCols >= minThreeWayWidth)
    {
        foreach (ref row; aligned[])
        {
            uint[] cells = [cell(b, at(oursLines, row.at[1]), Slot.diffAdded, row.at[1] < 0)];
            if (r.hasBase)
                cells ~= cell(b, at(refLines, row.at[0]), Slot.muted, row.at[0] < 0);
            cells ~= cell(b, at(theirLines, row.at[2]), Slot.diffRemoved, row.at[2] < 0);
            rows ~= b.add(Widget(kind: WidgetKind.row, children: cells, width: SizeSpec.grow()));
        }
    }
    else
    {
        // Narrow: one side after another, each named.
        rows ~= stacked(b, "ours", oursLines, Slot.diffAdded);
        if (r.hasBase)
            rows ~= stacked(b, "base", refLines, Slot.muted);
        rows ~= stacked(b, "theirs", theirLines, Slot.diffRemoved);
    }
    return b.add(Widget(kind: WidgetKind.column, children: rows, width: SizeSpec.grow()));
}

/// One pane's cell of an aligned row: its line, or a filler.
private uint cell(ref Builder b, const(char)[] line, Slot slot, bool filler) @safe
{
    import sparkles.ui.geometry : SizeSpec;

    return b.add(Widget(kind: WidgetKind.rich,
        spans: [TextSpan(filler ? "" : line.idup, slot: filler ? Slot.inherit : slot)],
        slot: filler ? Slot.surfaceSunken : Slot.inherit, paintBackground: filler,
        width: SizeSpec.percent(r3)));
}

private enum r3 = 33;

/// A narrow layout's side: its name, then its lines.
private uint[] stacked(ref Builder b, string name, const(const(char)[])[] lines, Slot slot) @safe
{
    uint[] rows = [b.add(Widget(kind: WidgetKind.rich, spans: [TextSpan(name, slot: Slot.muted)]))];
    foreach (l; lines)
        rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [TextSpan("  " ~ l.idup, slot: slot)]));
    return rows;
}

@("conflict_view.ConflictSession.picksAreUndoableEdits")
@safe unittest
{
    enum text = "a\n<<<<<<< ours\nb\n=======\nc\n>>>>>>> theirs\nd\n"
        ~ "<<<<<<< ours\ne\n=======\nf\n>>>>>>> theirs\n";
    auto s = ConflictSession.open("f.txt", text, EditorTarget.terminal);
    assert(s.remaining == 2 && s.current == 0);
    assert(s.save((string p, string t) => cast(string) null) == "2 conflicts remain");
    assert(s.pick(Pick.both) && s.remaining == 1);
    assert(s.text == "a\nb\nc\nd\n<<<<<<< ours\ne\n=======\nf\n>>>>>>> theirs\n");
    assert(s.undo() && s.remaining == 2, "a pick is undoable");
    assert(s.pick(Pick.theirs) && s.pick(Pick.ours) && s.remaining == 0);
    assert(s.text == "a\nc\nd\ne\n");
    string written;
    assert(s.save((string p, string t) { written = t; return cast(string) null; }) is null);
    assert(written == "a\nc\nd\ne\n");
}

@("conflict_view.ConflictSession.handEditsKeepTheMarkers")
@safe unittest
{
    import sparkles.input.events : Key;

    // `EDU3`: editing freely changes a side; the markers stay read-only.
    auto s = ConflictSession.open("f.txt", "<<<<<<< o\nb\n=======\nc\n>>>>>>> t\n",
        EditorTarget.terminal);
    s.edit();
    assert(s.editing);
    s.key(KeyEvent(Key.char_, 'X')); // the caret is at ours' start
    assert(s.text == "<<<<<<< o\nXb\n=======\nc\n>>>>>>> t\n");
    s.result.state.selection = SelectionSet.caret(0);
    s.key(KeyEvent(Key.delete_));
    assert(s.text.length && s.text[0] == '<', "a marker line cannot be deleted");
    s.key(KeyEvent(Key.escape));
    assert(!s.editing && s.pick(Pick.ours) && s.text == "Xb\n");
}

@("conflict_view.viewConflict.countAndThreeColumns")
@safe unittest
{
    enum text = "a\n<<<<<<< HEAD\nint x = 1;\n||||||| base\nint x = 0;\n"
        ~ "=======\nint x = 2;\n>>>>>>> feature\nz\n";
    auto s = ConflictSession.open("f.d", text, EditorTarget.terminal);
    auto wide = viewConflict(s, 120);
    string all;
    size_t threeCells;
    foreach (ref n; wide.nodes)
    {
        foreach (ref sp; n.spans)
            all ~= sp.text;
        threeCells += n.kind == WidgetKind.row && n.children.length == 3;
    }
    import std.algorithm.searching : canFind;

    assert(all.canFind("1 conflict remaining") && all.canFind("conflict 1/1"));
    assert(all.canFind("ours: HEAD") && all.canFind("theirs: feature"));
    assert(threeCells == 1, "ours · base · theirs on one aligned row");
    auto narrow = viewConflict(s, 60);
    size_t rowsOfThree;
    foreach (ref n; narrow.nodes)
        rowsOfThree += n.kind == WidgetKind.row && n.children.length == 3;
    assert(rowsOfThree == 0, "narrow panes stack");
}
