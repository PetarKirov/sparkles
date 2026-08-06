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

import diff_session : DiffSession, FileChange, SessionEntry, statusGlyph;
import document : DiffSides;
import sparkles.diff.model : Degradation, DiffDoc, FileEntry, Hunk, Row,
    RowKind, Span;
import sparkles.twoslash.overlay : planTwoslash, TwoslashPlan;
import sparkles.twoslash.protocol : TwoslashReturn;
import sparkles.twoslash.render_widgets : decorateCodeRow;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;

/// View options — deliberately small in V1.
struct DiffViewOptions
{
    /// Render the dual old/new line-number gutter.
    bool lineNumbers = true;
    /// `DVS4`/`DVG3`: the session entry for the file being rendered. Supplies
    /// the header's status marker and add/remove counts, whether the file is
    /// collapsed, and any per-file error (`DVS5`). Left at `init` by callers
    /// that have no session, which renders the plain path-only header.
    SessionEntry entry;
    /// `DVG1`: this file is the session's selected one — the header marks it,
    /// so a reviewer can see where the cursor is without a separate pane.
    bool selected;
    /// `DVG1`: the `Widget.key` stamped on this file's container, so a host
    /// resolves its laid-out row through `keyedRects` ($(LREF diffFileKey)).
    /// Zero leaves the container unkeyed.
    size_t fileKey;
    /// `DVN2`: fold hunks classified formatting-only into a one-line dimmed
    /// badge. Demote, never hide — the badge says how many rows it stands for
    /// and the reviewer can always expand.
    bool foldFormattingOnly = true;
    /// `DVT1`: the per-side type payloads for this file. Each attaches only
    /// when its `code` is byte-identical to that side's diff text — see
    /// $(LREF anchors) — so a decoration can never land on the wrong token.
    TypeOverlay oldTypes, newTypes;
    /// Per-side syntax-styled lines (`DVM5` composition): index = 0-based
    /// source line; each line's spans concatenate to exactly the line text
    /// (the `highlightedFenceRenderer` contract). The view keeps the spans'
    /// resolved syntax foregrounds and layers the diff row/emphasis tints
    /// as slot backgrounds — the delta two-streams recipe. Null (or a line
    /// whose spans don't cover its text) falls back to plain rows.
    TextSpan[][] oldStyled;
    TextSpan[][] newStyled;
}

/**
`DVT1`: one side's resolved-type payload, ready to decorate diff rows.

The **anchoring contract** lives here rather than at the call site, because it
is the property that makes the whole feature safe: an overlay's offsets index
the text the analyzer saw, so attaching it to a row of a *different* text
would put underlines and popups on the wrong tokens. `attach` is the only way
to build a live overlay, and it refuses unless the payload's `code` is
byte-identical to the side text the rows come from. A refusal is not an error
— that side simply renders without types, exactly as it does today.

Byte-identity is the right test rather than, say, a line count: the extractor
runs the notation parser, so a D file containing a literal `// ^?` or a
`---cut---` comment yields a `code` that legitimately differs from its source.
*/
struct TypeOverlay
{
    private TwoslashReturn _tw;
    private TwoslashPlan _plan;
    private bool _live;

    /// Builds an overlay for `sideText`, or an inert one when the payload
    /// does not describe exactly that text.
    static TypeOverlay attach(TwoslashReturn tw, scope const(char)[] sideText) @safe
    {
        TypeOverlay o;
        if (tw.code.length == 0 || sideText.length == 0 || tw.code != sideText)
            return o;
        o._tw = tw;
        o._plan = planTwoslash(tw);
        o._live = true;
        return o;
    }

    /// Whether this overlay decorates anything (`false` ⇒ plain rows).
    bool live() const @safe pure nothrow @nogc => _live;

    /// The payload, for a host resolving a hover to a node.
    ref const(TwoslashReturn) payload() const return @safe pure nothrow @nogc
        => _tw;
}

/// `DVT1`: one file's two overlays, parallel to `DiffDoc.files` — the same
/// by-index pairing `DiffSides` and the session already use, so a host that
/// resolves "file 3" once resolves it for every channel.
struct FileTypes
{
    TypeOverlay old_;
    TypeOverlay new_;
}

/// The `(lang, text) → styled lines` renderer a host supplies for `DVM5`
/// composition (the `highlightedFenceRenderer` shape).
alias SideRenderer = TextSpan[][] delegate(const(char)[] lang, const(char)[] body_) @safe;

/// A whole document (all its files), one column — the one-shot form every
/// sink calls. With `sides` + `render`, each file whose side texts are known
/// is re-highlighted and composed (`DVM5`); files with empty sides render
/// plain.
WidgetTree viewDiffDoc(const ref DiffDoc doc, DiffViewOptions opt = DiffViewOptions.init,
    const(DiffSides)[] sides = null, SideRenderer render = null,
    const DiffSession session = DiffSession.init,
    FileTypes[] types = null) @safe
{
    auto b = Builder();
    auto files = new uint[](0);
    foreach (fi; 0 .. doc.files.length)
    {
        auto fopt = opt;
        // Entries are parallel to `doc.files`, as are the side texts — one
        // index names the model, the session and the sources alike.
        if (fi < session.entries.length)
        {
            fopt.entry = session.entries[fi];
            fopt.selected = !session.empty && fi == session.index;
            fopt.fileKey = diffFileKey(fi);
        }
        // A collapsed file renders its header only, so re-highlighting its
        // sides would be work nobody sees.
        if (render !is null && !fopt.entry.collapsed && fi < sides.length
            && (sides[fi].oldText.length || sides[fi].newText.length))
        {
            fopt.oldStyled = render(sides[fi].lang, sides[fi].oldText);
            fopt.newStyled = render(sides[fi].lang, sides[fi].newText);
        }
        // `DVT1`: the file's per-side type overlays, already anchored (or
        // refused) by whoever attached them.
        if (!fopt.entry.collapsed && fi < types.length)
        {
            fopt.oldTypes = types[fi].old_;
            fopt.newTypes = types[fi].new_;
        }
        files ~= viewDiffInto(b, doc, doc.files[fi], fopt);
    }
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

    rows ~= fileHeader(b, doc, file, opt);

    // `DVS5`: a file whose sources could not be read reports why, in band,
    // and the rest of the session renders regardless.
    if (opt.entry.error.length)
        rows ~= noticeRow(b, opt.entry.error);

    if (file.degraded == Degradation.fileTooLarge)
        rows ~= noticeRow(b, "(file too large — diff not computed)");
    else if (file.degraded == Degradation.editDistanceCapped)
        rows ~= noticeRow(b, "(edit distance capped — changed region shown whole)");

    if (file.binary)
        rows ~= noticeRow(b, "(binary files differ)");
    else if (file.hunksCount == 0 && file.degraded == Degradation.none)
        rows ~= noticeRow(b, "(no changes)");

    if (opt.entry.collapsed)
    {
        // `DVG3`: the header stays, the hunks go — with a count, so a folded
        // file still says how much it is hiding.
        if (file.hunksCount != 0)
            rows ~= noticeRow(b, text("(", file.hunksCount,
                file.hunksCount == 1 ? " hunk collapsed)" : " hunks collapsed)"));
        return b.container(WidgetKind.column, rows, gap: 1);
    }

    const gutterWidth = opt.lineNumbers ? gutterDigits(doc, file) : 0;
    // Hunk keys are the document-global hunk index, so "next hunk" is one
    // ordering over the whole session rather than per file (`DVG1`).
    uint hi = file.hunksStart;
    foreach (ref hunk; doc.fileHunks(file))
    {
        const key = opt.fileKey ? diffHunkKey(hi) : 0;
        ++hi;
        rows ~= keyed(b, hunk.formattingOnly && opt.foldFormattingOnly
            ? foldedHunk(b, doc, hunk)
            : viewHunk(b, doc, hunk, gutterWidth, opt), key);
    }

    return keyed(b, b.container(WidgetKind.column, rows, gap: 1), opt.fileKey);
}

/// `DVG1`: the widget key a file's container carries, so a host can find the
/// file's laid-out row through `keyedRects` instead of re-deriving the tree's
/// shape. Zero (the `keyedRects` "unkeyed" value) means the caller supplied no
/// session, so nothing is stamped.
size_t diffFileKey(size_t fileIndex) @safe pure nothrow @nogc => fileIndex + 1;

/// `DVG1`: the key a hunk's container carries. A disjoint id space above the
/// file keys (the `fenceHitBase`/`foldHitBase` precedent), so one `keyedRects`
/// sweep answers both "where is file 3" and "where is the next hunk".
enum size_t diffHunkKeyBase = size_t.max / 2 + 1;

/// ditto
size_t diffHunkKey(size_t hunkIndex) @safe pure nothrow @nogc
    => diffHunkKeyBase + hunkIndex;

/// `true` for a key produced by $(LREF diffHunkKey).
bool isDiffHunkKey(size_t key) @safe pure nothrow @nogc => key >= diffHunkKeyBase;

private uint keyed(ref Builder b, uint node, size_t key) @safe
{
    if (key != 0)
        b.nodes[node].key = key;
    return node;
}

/// The per-file header: a fold marker, the status letter, the display path,
/// and the add/remove counts — everything a reviewer scanning a multi-file
/// diff reads before deciding to look (`DVS4`).
private uint fileHeader(ref Builder b, const ref DiffDoc doc, in FileEntry file,
    DiffViewOptions opt) @safe
{
    const(char)[] title = opt.entry.display.length
        ? opt.entry.display
        : pathTitle(doc, file);

    TextSpan[] spans;
    if (opt.selected)
        spans ~= TextSpan("▸ ", slot: Slot.chromeFocused);
    if (opt.entry.display.length)
    {
        spans ~= TextSpan(opt.entry.collapsed ? "▸ " : "▾ ", slot: Slot.muted);
        spans ~= TextSpan(text(statusGlyph(opt.entry.change), " "),
            slot: statusSlot(opt.entry.change));
    }
    spans ~= TextSpan(title, slot: Slot.chromeAccent);
    if (opt.entry.added || opt.entry.removed)
    {
        spans ~= TextSpan("  ");
        spans ~= TextSpan(text("+", opt.entry.added), slot: Slot.diffAdded);
        spans ~= TextSpan(" ");
        spans ~= TextSpan(text("−", opt.entry.removed), slot: Slot.diffRemoved);
    }
    return b.add(Widget(kind: WidgetKind.rich, spans: spans));
}

/// The path-only title used when no session entry is available.
private const(char)[] pathTitle(const ref DiffDoc doc, in FileEntry file) @safe
{
    const oldPath = doc.pathText(file.oldPath);
    const newPath = doc.pathText(file.newPath);
    return oldPath == newPath || newPath.length == 0
        ? oldPath
        : text(oldPath, " → ", newPath);
}

/// The status letter's color: added/removed reuse the row tints (as
/// foregrounds), so one vocabulary covers the header and the rows.
private Slot statusSlot(FileChange c) @safe pure nothrow @nogc
{
    final switch (c) with (FileChange)
    {
        case added:    return Slot.diffAdded;
        case removed:  return Slot.diffRemoved;
        case modified:
        case renamed:  return Slot.chromeAccent;
    }
}

/// `DVN2`: a formatting-only hunk, folded to one dimmed line that says what
/// it is standing in for. The count is rows, not hunks, because that is what
/// the reviewer is deciding whether to read.
private uint foldedHunk(ref Builder b, const ref DiffDoc doc, in Hunk hunk) @safe
{
    uint changed;
    foreach (ref row; doc.hunkRows(hunk))
        if (row.kind != RowKind.context)
            ++changed;
    return b.add(Widget(kind: WidgetKind.rich, spans: [
        TextSpan(text("@@ -", hunk.oldStart, " +", hunk.newStart, " @@  "),
            slot: Slot.muted),
        TextSpan(text("formatting only — ", changed,
            changed == 1 ? " row hidden" : " rows hidden"), slot: Slot.muted),
    ]));
}

private uint noticeRow(ref Builder b, string message) @safe
    => b.add(Widget(kind: WidgetKind.text, text: message, slot: Slot.muted));

private uint viewHunk(ref Builder b, const ref DiffDoc doc, in Hunk hunk,
    int gutterWidth, DiffViewOptions opt) @safe
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
        rows ~= viewRow(b, doc, row, gutterWidth, opt);

    return b.container(WidgetKind.column, rows);
}

private uint viewRow(ref Builder b, const ref DiffDoc doc, in Row row,
    int gutterWidth, DiffViewOptions opt) @safe
{
    TextSpan[] spans;

    if (gutterWidth > 0)
        spans ~= TextSpan(gutterText(row, gutterWidth), slot: Slot.gutter);

    const rowText = doc.rowText(row);
    const emph = doc.rowEmph(row);
    // The side's syntax-styled line, when the host supplied one (`DVM5`).
    const styled = row.kind == RowKind.added
        ? styledLine(opt.newStyled, row.newLine)
        : styledLine(opt.oldStyled, row.oldLine);
    final switch (row.kind)
    {
    case RowKind.context:
        spans ~= TextSpan("  ");
        spans ~= composedSpans(styled, rowText, emph, Slot.inherit,
            Slot.inherit, false);
        break;
    case RowKind.removed:
        spans ~= TextSpan("- ", slot: Slot.diffRemoved, paintBackground: true);
        spans ~= composedSpans(styled, rowText, emph, Slot.diffRemoved,
            Slot.diffEmphRemoved, true);
        break;
    case RowKind.added:
        spans ~= TextSpan("+ ", slot: Slot.diffAdded, paintBackground: true);
        spans ~= composedSpans(styled, rowText, emph, Slot.diffAdded,
            Slot.diffEmphAdded, true);
        break;
    }
    const code = b.add(Widget(kind: WidgetKind.rich, spans: spans));

    // `DVT1`: the side's type overlay decorates this row. The row's own
    // chrome — the gutter plus the two-cell marker — sits left of the code,
    // so the decorations shift right by exactly that much; getting this
    // wrong is the difference between an underline on a token and one two
    // cells off it, which is why the offset is passed rather than assumed.
    const side = row.kind == RowKind.added ? opt.newTypes : opt.oldTypes;
    if (!side.live)
        return code;
    const line = row.kind == RowKind.added ? row.newLine : row.oldLine;
    if (line == 0)
        return code;
    return decorateCodeRow(b, code, side.payload, side._plan, line - 1,
        gutterWidth + 2);
}

/// The 1-based `line`'s styled spans, or null when unavailable.
private const(TextSpan)[] styledLine(const(TextSpan[])[] styled, uint line) @safe
    => line != 0 && line <= styled.length ? styled[line - 1] : null;

/// Composition (`DVM5`): when a styled line covering the row text exists,
/// split its spans at the emphasis boundaries — syntax foreground kept, the
/// diff tint layered as the slot background; otherwise the plain path.
private TextSpan[] composedSpans(const(TextSpan)[] styled, const(char)[] rowText,
    const(Span)[] emph, Slot base, Slot emphSlot, bool tint) @safe
{
    if (styled is null || !covers(styled, rowText))
        return contentSpans(rowText, emph, base, emphSlot, tint);

    TextSpan[] spans;
    size_t pos = 0; // row-relative offset of the current styled span
    foreach (ref sp; styled)
    {
        size_t local = 0;
        while (local < sp.text.length)
        {
            immutable at = pos + local;
            // Longest run from `at` with a single emphasis verdict.
            immutable inEmph = insideEmph(emph, at);
            size_t end = sp.text.length;
            foreach (e; emph)
            {
                if (e.start > at && e.start - pos < end)
                    end = e.start - pos;
                if (e.end > at && e.end - pos < end && at >= e.start)
                    end = e.end - pos;
            }
            if (end <= local)
                end = local + 1;
            TextSpan piece = cast(TextSpan) sp;
            piece.text = sp.text[local .. end];
            piece.slot = inEmph ? emphSlot : base;
            piece.paintBackground = tint && piece.slot != Slot.inherit;
            spans ~= piece;
            local = end;
        }
        pos += sp.text.length;
    }
    if (spans.length == 0)
        spans ~= segment(rowText, base, tint);
    return spans;
}

private bool insideEmph(const(Span)[] emph, size_t at) @safe pure nothrow @nogc
{
    foreach (e; emph)
        if (at >= e.start && at < e.end)
            return true;
    return false;
}

private bool covers(const(TextSpan)[] styled, const(char)[] rowText) @safe pure nothrow @nogc
{
    size_t total = 0;
    foreach (ref sp; styled)
        total += sp.text.length;
    return total == rowText.length;
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


@("diff_view.composedSpans.syntax-under-tints")
@safe unittest
{
    import sparkles.base.term_color : RgbColor;

    // DVM5: a styled line (two syntax spans) composed with one emphasis
    // span — syntax foregrounds survive, the diff tint layers as slots,
    // and the split happens exactly at the emphasis boundaries.
    auto doc = diffText("int x = a;\n", "int x = b;\n", "t.d", "t.d");
    DiffViewOptions opt;
    // Hand-built styled lines: "int " keyword-colored, rest plain.
    const kw = RgbColor(0xff, 0x00, 0x00);
    opt.oldStyled = [[
        TextSpan("int ", fg: kw, hasFg: true),
        TextSpan("x = a;"),
    ]];
    opt.newStyled = [[
        TextSpan("int ", fg: kw, hasFg: true),
        TextSpan("x = b;"),
    ]];
    auto tree = viewDiffDoc(doc, opt);

    bool sawStyledEmph = false, sawStyledBase = false;
    foreach (ref node; tree.nodes)
        if (node.kind == WidgetKind.rich)
            foreach (sp; node.spans)
            {
                if (sp.slot == Slot.diffEmphRemoved)
                {
                    assert(sp.text == "a", "emphasis split at the changed token");
                    sawStyledEmph = true;
                }
                if (sp.text == "int " && sp.hasFg && sp.fg == kw
                    && (sp.slot == Slot.diffRemoved || sp.slot == Slot.diffAdded))
                {
                    assert(sp.paintBackground, "diff tint layered under syntax fg");
                    sawStyledBase = true;
                }
            }
    assert(sawStyledEmph && sawStyledBase);
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
    // Without a session the header is the path alone (one span, no status
    // marker and no counts) — the shape every static caller still gets.
    const fileHead = tree.nodes[fileCol.children[0]];
    assert(fileHead.spans.length == 1 && fileHead.spans[0].text == "x.txt");

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

@("diff_view.viewDiffDoc.sessionHeaderStatusAndCounts")
@safe unittest
{
    import diff_session : buildDiffSession;
    import sparkles.diff : parsePatch;

    enum patch =
        "--- a/keep.d\n+++ b/keep.d\n@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n" ~
        "--- /dev/null\n+++ b/new.d\n@@ -0,0 +1 @@\n+alpha\n";
    const doc = parsePatch(patch).value;
    auto session = buildDiffSession(doc);

    auto tree = viewDiffDoc(doc, DiffViewOptions.init, null, null, session);
    const first = tree.nodes[tree.rootNode.children[0]];
    const header = tree.nodes[first.children[0]];

    // Selected file, expanded, modified, with its counts — the whole header
    // vocabulary in one row.
    assert(header.spans[0].text == "▸ ", "the selected file is marked");
    assert(header.spans[1].text == "▾ ", "an expanded file points down");
    assert(header.spans[2].text == "M ");
    assert(header.spans[3].text == "keep.d");
    assert(header.spans[5].text == "+1" && header.spans[7].text == "−1");

    // The added file is neither selected nor 'M'.
    const second = tree.nodes[tree.rootNode.children[1]];
    const addedHeader = tree.nodes[second.children[0]];
    assert(addedHeader.spans[0].text == "▾ ", "not selected: no cursor mark");
    assert(addedHeader.spans[1].text == "A ");
    assert(addedHeader.spans[2].text == "new.d");

    // Each file container carries its key, so a host finds its row without
    // knowing the tree's shape.
    assert(first.key == diffFileKey(0) && second.key == diffFileKey(1));
}

@("diff_view.viewDiffDoc.collapsedFileAndPerFileError")
@safe unittest
{
    import diff_session : buildDiffSession;
    import sparkles.diff : parsePatch;

    enum patch = "--- a/x.d\n+++ b/x.d\n@@ -1,2 +1,2 @@\n a\n-b\n+c\n";
    const doc = parsePatch(patch).value;
    auto session = buildDiffSession(doc);
    session.entries[0].collapsed = true;
    session.entries[0].error = "(old side unavailable)";

    auto tree = viewDiffDoc(doc, DiffViewOptions.init, null, null, session);
    const file = tree.nodes[tree.rootNode.children[0]];
    const header = tree.nodes[file.children[0]];
    assert(header.spans[1].text == "▸ ", "a collapsed file points right");

    // `DVS5`: the error is in band, under the header, and the rest renders.
    assert(tree.nodes[file.children[1]].text == "(old side unavailable)");
    // `DVG3`: the hunks are gone, replaced by a count of what is hidden.
    assert(tree.nodes[file.children[2]].text == "(1 hunk collapsed)");
    assert(file.children.length == 3, "no hunk rows survive a collapse");
}

@("diff_view.typeOverlay.anchorsOnlyOnIdenticalText")
@safe unittest
{
    import sparkles.twoslash.protocol : Node, NodeType;

    enum side = "int x;\nint y;\n";
    TwoslashReturn tw = {
        code: side,
        nodes: [Node(type: NodeType.hover, start: 4, length: 1, line: 0,
            character: 4)],
    };

    assert(TypeOverlay.attach(tw, side).live, "identical text anchors");

    // The contract's whole point: anything else refuses rather than
    // decorating the wrong tokens.
    assert(!TypeOverlay.attach(tw, "int x;\nint z;\n").live,
        "same shape, different content");
    assert(!TypeOverlay.attach(tw, "int x;\n").live, "a prefix is not the text");
    assert(!TypeOverlay.attach(tw, side ~ "\n").live, "nor is a superset");
    assert(!TypeOverlay.attach(tw, null).live);
    assert(!TypeOverlay.attach(TwoslashReturn.init, side).live,
        "an empty payload has nothing to anchor");
    // A payload whose `code` the notation parser rewrote (a `---cut---` in a
    // real file) is exactly the case this refuses — the offsets are honest
    // about the post-cut text, which is not what the diff rows show.
    TwoslashReturn cut = { code: "int y;\n", nodes: tw.nodes };
    assert(!TypeOverlay.attach(cut, side).live);
}

@("diff_view.typeOverlay.decoratesTheMatchingSideOnly")
@safe unittest
{
    import sparkles.twoslash.protocol : Node, NodeType;
    import sparkles.ui.style : Slot;

    // One changed line: the old side gets a hover span, the new side none.
    enum oldText = "int a;\nint b;\n";
    enum newText = "int a;\nint c;\n";
    auto doc = diffText(oldText, newText, "t.d", "t.d");

    TwoslashReturn oldTw = {
        code: oldText,
        nodes: [Node(type: NodeType.hover, start: 4, length: 1, line: 0,
            character: 4)],
    };

    DiffViewOptions opt;
    opt.oldTypes = TypeOverlay.attach(oldTw, oldText);
    opt.newTypes = TypeOverlay.attach(oldTw, newText); // refused: wrong text
    assert(opt.oldTypes.live && !opt.newTypes.live);

    auto b = Builder();
    const fileNode = viewDiffInto(b, doc, doc.files[0], opt);
    auto tree = b.finish(fileNode);

    // The decorated row became a stack (underline beneath the code); count
    // how many rows carry a hover underline.
    size_t underlines;
    foreach (ref n; tree.nodes)
        if (n.slot == Slot.hoverUnderline)
            ++underlines;
    assert(underlines == 1, "exactly the one anchored span decorates");
}

@("diff_view.formattingOnly.foldsToABadgeAndExpandsBack")
@safe unittest
{
    import sparkles.diff : classifyHunks, DiffOptions;

    // A hunk whose every changed row is re-padding: the reviewer should get
    // one dimmed line, not eight rows of noise.
    enum before = "| a | b |\n| c | d |\n";
    enum after = "| a   | b |\n| c   | d |\n";
    auto doc = diffText(before, after, "t.md", "t.md");
    classifyHunks(doc);
    assert(doc.hunks[0].formattingOnly, "precondition: the engine classified it");

    DiffViewOptions opt; // foldFormattingOnly defaults on
    auto b = Builder();
    auto tree = b.finish(viewDiffInto(b, doc, doc.files[0], opt));

    // The folded hunk is one rich row saying what it stands for — and the
    // count is rows, because that is what the reviewer is deciding to read.
    bool sawBadge;
    foreach (ref n; tree.nodes)
        foreach (sp; n.spans)
            if (sp.text.length >= 16 && sp.text[0 .. 16] == "formatting only ")
            {
                sawBadge = true;
                assert(sp.slot == Slot.muted, "demoted, not shouted");
            }
    assert(sawBadge, "a formatting-only hunk folds to its badge");

    // Demote, never hide: expanding shows every row again.
    DiffViewOptions shown;
    shown.foldFormattingOnly = false;
    auto b2 = Builder();
    auto full = b2.finish(viewDiffInto(b2, doc, doc.files[0], shown));
    assert(full.nodes.length > tree.nodes.length,
        "the rows come back when asked for");

    size_t tinted;
    foreach (ref n; full.nodes)
        foreach (sp; n.spans)
            if (sp.slot == Slot.diffAdded || sp.slot == Slot.diffRemoved)
                ++tinted;
    assert(tinted > 0, "and they render as ordinary diff rows");
}
