// The diff widget view (`DVL1`/`DVL4`-unified): one `sparkles:diff`
// `DiffDoc` folded into a `sparkles:ui` widget tree that every sink paints —
// the same view→layout→display-list pipeline as `viewMarkdown`. V1 renders
// the unified layout: a dual line-number gutter, `+`/`-`/` ` markers, row
// tints from the diff `Slot`s layered as span backgrounds, and delta-style
// two-tier emphasis for the word-refined segments (`DVL6`).
//
// The diff model is a flat `@nogc` arena (`DVM8`): rows and spans resolve
// through the `DiffDoc` accessors (`rowText`/`rowEmph`/…), and this view is
// the GC boundary — widget text is sliced from the document's backing texts,
// which the owning `Document` keeps alive.
//
// Per-side syntax-highlight composition (`DVM5`) plugs in through
// `DiffViewOptions.styledLine` later — the fence-renderer precedent — so the
// view's structure does not change when the colors arrive. Lives in
// `apps/hue` for now (the sinks are all here); promotable to a render lib
// when an external consumer appears.
module diff_view;

import std.conv : text;

import sparkles.diff.model : Degradation, DiffDoc, FileEntry, Hunk, Row,
    RowKind, Span;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;

/// View options — deliberately small in V1.
struct DiffViewOptions
{
    /// Render the dual old/new line-number gutter.
    bool lineNumbers = true;
}

/// A whole document (all its files), one column — the one-shot form every
/// sink calls.
WidgetTree viewDiffDoc(const ref DiffDoc doc, DiffViewOptions opt = DiffViewOptions.init) @safe
{
    auto b = Builder();
    auto files = new uint[](0);
    foreach (fi; 0 .. doc.files.length)
        files ~= viewDiffInto(b, doc, doc.files[fi], opt);
    if (files.length == 0)
        files ~= b.add(Widget(kind: WidgetKind.text, text: "(empty diff)",
            slot: Slot.muted));
    return b.finish(b.container(WidgetKind.column, files, gap: 1));
}

/// One file's view appended to `b` (the `viewMarkdownInto` shape).
uint viewDiffInto(ref Builder b, const ref DiffDoc doc, in FileEntry file,
    DiffViewOptions opt = DiffViewOptions.init) @safe
{
    auto rows = new uint[](0);

    rows ~= fileHeader(b, doc, file);

    if (file.degraded == Degradation.fileTooLarge)
        rows ~= noticeRow(b, "(file too large — diff not computed)");
    else if (file.degraded == Degradation.editDistanceCapped)
        rows ~= noticeRow(b, "(edit distance capped — changed region shown whole)");

    if (file.binary)
        rows ~= noticeRow(b, "(binary files differ)");
    else if (file.hunksCount == 0 && file.degraded == Degradation.none)
        rows ~= noticeRow(b, "(no changes)");

    const gutterWidth = opt.lineNumbers ? gutterDigits(doc, file) : 0;
    foreach (ref hunk; doc.fileHunks(file))
        rows ~= viewHunk(b, doc, hunk, gutterWidth);

    return b.container(WidgetKind.column, rows, gap: 1);
}

private uint fileHeader(ref Builder b, const ref DiffDoc doc, in FileEntry file) @safe
{
    const oldPath = doc.pathText(file.oldPath);
    const newPath = doc.pathText(file.newPath);
    const(char)[] title = oldPath == newPath || newPath.length == 0
        ? oldPath
        : text(oldPath, " → ", newPath);
    return b.add(Widget(kind: WidgetKind.text, text: title, slot: Slot.chromeAccent));
}

private uint noticeRow(ref Builder b, string message) @safe
    => b.add(Widget(kind: WidgetKind.text, text: message, slot: Slot.muted));

private uint viewHunk(ref Builder b, const ref DiffDoc doc, in Hunk hunk,
    int gutterWidth) @safe
{
    auto rows = new uint[](0);
    rows.reserve(hunk.rowsCount + 1);

    // The hunk header, rendered as its own tinted band.
    rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [
        TextSpan(text("@@ -", hunk.oldStart, ",", hunk.oldCount,
            " +", hunk.newStart, ",", hunk.newCount, " @@"),
            slot: Slot.diffHunk, paintBackground: true),
    ]));

    foreach (ref row; doc.hunkRows(hunk))
        rows ~= viewRow(b, doc, row, gutterWidth);

    return b.container(WidgetKind.column, rows);
}

private uint viewRow(ref Builder b, const ref DiffDoc doc, in Row row,
    int gutterWidth) @safe
{
    TextSpan[] spans;

    if (gutterWidth > 0)
        spans ~= TextSpan(gutterText(row, gutterWidth), slot: Slot.gutter);

    const rowText = doc.rowText(row);
    const emph = doc.rowEmph(row);
    final switch (row.kind)
    {
    case RowKind.context:
        spans ~= TextSpan("  ");
        spans ~= contentSpans(rowText, emph, Slot.inherit, Slot.inherit, false);
        break;
    case RowKind.removed:
        spans ~= TextSpan("- ", slot: Slot.diffRemoved, paintBackground: true);
        spans ~= contentSpans(rowText, emph, Slot.diffRemoved,
            Slot.diffEmphRemoved, true);
        break;
    case RowKind.added:
        spans ~= TextSpan("+ ", slot: Slot.diffAdded, paintBackground: true);
        spans ~= contentSpans(rowText, emph, Slot.diffAdded,
            Slot.diffEmphAdded, true);
        break;
    }
    return b.add(Widget(kind: WidgetKind.rich, spans: spans));
}

/// The row's text split at its emphasis spans: base segments carry the row
/// tint, emphasized segments the stronger tier (`DVL6`).
private TextSpan[] contentSpans(const(char)[] rowText, const(Span)[] emph,
    Slot base, Slot emphSlot, bool tint) @safe
{
    TextSpan[] spans;
    size_t pos = 0;
    foreach (s; emph)
    {
        if (s.start > pos)
            spans ~= segment(rowText[pos .. s.start], base, tint);
        const end = s.end <= rowText.length ? s.end : rowText.length;
        if (end > s.start)
            spans ~= segment(rowText[s.start .. end], emphSlot, tint);
        pos = end;
    }
    if (pos < rowText.length)
        spans ~= segment(rowText[pos .. $], base, tint);
    if (spans.length == 0)
        spans ~= segment(rowText, base, tint);
    return spans;
}

private TextSpan segment(const(char)[] text_, Slot slot, bool tint) @safe
    => TextSpan(text_, slot: slot, paintBackground: tint && slot != Slot.inherit);

/// `"<old> <new> "` — both numbers right-aligned to `width` digits; an absent
/// side renders as spaces.
private const(char)[] gutterText(in Row row, int width) @safe
{
    auto buf = new char[](2 * width + 2);
    buf[] = ' ';
    writeNum(buf[0 .. width], row.oldLine);
    writeNum(buf[width + 1 .. 2 * width + 1], row.newLine);
    return buf;
}

private void writeNum(char[] slot, uint value) @safe pure nothrow @nogc
{
    if (value == 0)
        return;
    size_t i = slot.length;
    while (value != 0 && i > 0)
    {
        slot[--i] = cast(char)('0' + value % 10);
        value /= 10;
    }
}

private int gutterDigits(const ref DiffDoc doc, in FileEntry file) @safe pure nothrow @nogc
{
    uint maxLine = 1;
    foreach (ref hunk; doc.fileHunks(file))
    {
        const oldEnd = hunk.oldStart + hunk.oldCount;
        const newEnd = hunk.newStart + hunk.newCount;
        if (oldEnd > maxLine)
            maxLine = oldEnd;
        if (newEnd > maxLine)
            maxLine = newEnd;
    }
    int digits = 1;
    while (maxLine >= 10)
    {
        maxLine /= 10;
        digits++;
    }
    return digits;
}

version (unittest)
{
    import sparkles.diff : diffText;
}

@("diff_view.viewDiffDoc.structure")
@safe unittest
{
    auto doc = diffText("one\ntwo\nthree\n", "one\n2\nthree\n", "x.txt", "x.txt");
    auto tree = viewDiffDoc(doc);

    // Root column: one file column; file column: header + one hunk column.
    assert(tree.rootNode.kind == WidgetKind.column);
    assert(tree.rootNode.children.length == 1);
    const fileCol = tree.nodes[tree.rootNode.children[0]];
    assert(fileCol.children.length == 2);
    assert(tree.nodes[fileCol.children[0]].text == "x.txt");

    const hunkCol = tree.nodes[fileCol.children[1]];
    assert(hunkCol.kind == WidgetKind.column);
    // Hunk header + 4 rows (ctx, -, +, ctx).
    assert(hunkCol.children.length == 5);
    const header = tree.nodes[hunkCol.children[0]];
    assert(header.spans[0].slot == Slot.diffHunk);
    assert(header.spans[0].text == "@@ -1,3 +1,3 @@");

    const removed = tree.nodes[hunkCol.children[2]];
    assert(removed.spans[1].text == "- ");
    assert(removed.spans[1].slot == Slot.diffRemoved);
}

@("diff_view.viewDiffDoc.emph-two-tier")
@safe unittest
{
    auto doc = diffText("int a = compute(x, y);\n", "int a = compute(x, z);\n");
    auto tree = viewDiffDoc(doc);

    // Find the removed row and check the emphasized segment carries the
    // stronger tier while the rest keeps the base tint.
    bool sawEmph = false;
    foreach (ref node; tree.nodes)
        if (node.kind == WidgetKind.rich)
            foreach (s; node.spans)
                if (s.slot == Slot.diffEmphRemoved)
                {
                    assert(s.text == "y");
                    assert(s.paintBackground);
                    sawEmph = true;
                }
    assert(sawEmph);
}

@("diff_view.viewDiffDoc.gutter-alignment")
@safe unittest
{
    auto doc = diffText("a\nb\nc\n", "a\nB\nc\n");
    auto tree = viewDiffDoc(doc);
    // Gutter of the first context row: old 1, new 1, width 1 → "1 1 ".
    foreach (ref node; tree.nodes)
        if (node.kind == WidgetKind.rich && node.spans.length == 3
            && node.spans[2].text == "a")
        {
            assert(node.spans[0].slot == Slot.gutter);
            assert(node.spans[0].text == "1 1 ");
            return;
        }
    assert(false, "context row not found");
}

@("diff_view.viewDiffDoc.empty-and-binary")
@safe unittest
{
    auto same = diffText("x\n", "x\n");
    auto tree = viewDiffDoc(same);
    const fileCol = tree.nodes[tree.rootNode.children[0]];
    assert(tree.nodes[fileCol.children[1]].text == "(no changes)");

    DiffDoc bin;
    FileEntry entry;
    entry.oldPath = bin.internPath("a.png");
    entry.newPath = bin.internPath("a.png");
    entry.binary = true;
    bin.files ~= entry;
    auto btree = viewDiffDoc(bin);
    const binCol = btree.nodes[btree.rootNode.children[0]];
    assert(btree.nodes[binCol.children[1]].text == "(binary files differ)");
}
