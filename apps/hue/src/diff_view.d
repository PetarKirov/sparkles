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

import diff_session : AnchoredThread, DiffSession, FileChange, SessionEntry,
    SessionHeader, statusGlyph;
import document : DiffSides;
import sparkles.diff.model : Degradation, DiffDoc, FileEntry, Hunk, Row,
    RowKind, Span;
import sparkles.twoslash.overlay : planTwoslash, TwoslashPlan;
import sparkles.twoslash.protocol : TwoslashReturn;
import sparkles.twoslash.render_widgets : decorateCodeRow;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;

/// `DVL3`: which layout a file renders in.
enum DiffLayout : ubyte
{
    /// One column, old and new interleaved (`DVL1`).
    unified,
    /// Two panes, rows aligned by the pairing pass (`DVL2`).
    split,
}

/// View options — deliberately small in V1.
struct DiffViewOptions
{
    /// `DVL3`: the layout to render. `split` degrades to `unified` below
    /// $(LREF minSplitWidth) — see `viewDiffDoc`.
    DiffLayout layout;
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
    /// `DVG2`: expand every unchanged region. Needs `sideText` — a patch does
    /// not carry the lines it elided, so there is nothing to expand it with.
    bool expandContext;
    /// `DVG2`: the document-global gap indices the reviewer expanded one at a
    /// time. Consulted when `expandContext` is off, so "expand this one" and
    /// "expand everything" are independent rather than one overriding the
    /// other.
    const(bool)[] expandedGaps;
    /// `DVG2`: the file's new-side text, when the host has it — the source the
    /// expanded lines are read from.
    const(char)[] sideText;
    /// `DVN2`: fold hunks classified formatting-only into a one-line dimmed
    /// badge. Demote, never hide — the badge says how many rows it stands for
    /// and the reviewer can always expand.
    bool foldFormattingOnly = true;
    /// `DPR3`/`DCM2`: this file's review conversations. Each renders as a
    /// block under the row it is anchored to; a resolved one folds to a
    /// single line, because a settled argument is context, not a task.
    const(AnchoredThread)[] threads;
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

/**
`DVL3`: the narrowest pane a split layout is worth showing in.

Below this, two panes of ~30 columns each wrap every line into an unreadable
ribbon, and a unified view of the same diff is strictly better — so the split
request degrades rather than being honored into uselessness (the
`git-split-diffs` behaviour). Stated as a constant rather than hidden in a
comparison so the threshold is one named thing a reader can find.
*/
enum int minSplitWidth = 80;

/// One aligned display row of a split layout: indices into the hunk's rows,
/// or `-1` for a filler cell opposite an unmatched line.
struct SplitRow
{
    int old_ = -1;
    int new_ = -1;
}

/**
`DVL2`: aligns a hunk's rows into side-by-side pairs.

The pairing pass (`DVM2`) already decided which removed line corresponds to
which added line; this walks the rows in emission order and turns those
decisions into display rows. A removed line with a pair sits opposite it; one
without gets a filler, and so does an added line nobody claimed.

Pure and index-only — no widgets, no text — so the alignment can be tested for
what it is: a correspondence between rows.
*/
SplitRow[] alignSplitRows(const(Row)[] rows) @safe
{
    auto consumed = new bool[](rows.length);
    SplitRow[] out_;
    foreach (i, ref row; rows)
    {
        final switch (row.kind) with (RowKind)
        {
            case context:
                out_ ~= SplitRow(cast(int) i, cast(int) i);
                break;
            case removed:
                if (row.pair >= 0 && cast(size_t) row.pair < rows.length)
                {
                    consumed[cast(size_t) row.pair] = true;
                    out_ ~= SplitRow(cast(int) i, row.pair);
                }
                else
                    out_ ~= SplitRow(cast(int) i, -1);
                break;
            case added:
                if (!consumed[i])
                    out_ ~= SplitRow(-1, cast(int) i);
                break;
        }
    }
    return out_;
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
    FileTypes[] types = null, int widthCols = 0) @safe
{
    // `DVL3`: honor the split request only where it is readable. Two panes of
    // thirty columns wrap every line into a ribbon, and a unified view of the
    // same diff is strictly better — so a narrow pane degrades rather than
    // obeying into uselessness. `widthCols == 0` means "the caller did not
    // say", which is the static sinks: they lay out at their own width and
    // are not being asked to second-guess it.
    if (opt.layout == DiffLayout.split && widthCols != 0
        && widthCols < minSplitWidth)
        opt.layout = DiffLayout.unified;

    auto b = Builder();
    auto files = new uint[](0);
    // `DPR2`: a session that has a header renders it above its files — the
    // description through hue's own markdown view, which is the dogfooding
    // the spec asks for and the reason a PR body's tables and fences look
    // like every other document hue draws.
    if (session.header.present)
        files ~= sessionHeader(b, session.header, render, opt);
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
        // `DVG2`: the new side's full text, when the host has it — what an
        // expanded unchanged region is read from.
        if (fi < sides.length)
            fopt.sideText = sides[fi].newText;
        // `DPR3`: the conversations on THIS file, by path — the session holds
        // them all, and a collapsed file renders none.
        if (!fopt.entry.collapsed && session.threads.length)
            fopt.threads = threadsFor(session.threads,
                doc.pathText(doc.files[fi].newPath),
                doc.pathText(doc.files[fi].oldPath));
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
    auto root = b.container(WidgetKind.column, files, gap: 1);
    if (opt.layout == DiffLayout.split)
        root = grown(b, root);
    return b.finish(root);
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
    const hunks = doc.fileHunks(file);
    // Gap indices are document-global, like hunk keys, so a host resolves
    // "the gap the cursor is in" without knowing which file it belongs to.
    size_t gapIndex = file.hunksStart;
    foreach (gi, ref hunk; hunks)
    {
        // `DVG2`: the unchanged region between this hunk and the previous one
        // (or the start of the file). The context window hid it; say how much
        // it hid, and show it when asked.
        const prevEnd = gi == 0 ? 1u : hunks[gi - 1].newStart + hunks[gi - 1].newCount;
        if (hunk.newStart > prevEnd)
            rows ~= keyed(b, contextGap(b, prevEnd, hunk.newStart - prevEnd,
                gutterWidth, opt, gapIndex), opt.fileKey ? diffGapKey(gapIndex) : 0);
        ++gapIndex;

        const key = opt.fileKey ? diffHunkKey(hi) : 0;
        ++hi;
        uint node;
        if ((hunk.formattingOnly || hunk.reordered) && opt.foldFormattingOnly)
            node = foldedHunk(b, doc, hunk);
        else if (opt.layout == DiffLayout.split)
            node = viewHunkSplit(b, doc, hunk, gutterWidth, opt);
        else
            node = viewHunk(b, doc, hunk, gutterWidth, opt);
        rows ~= keyed(b, node, key);
    }

    // And the region after the last hunk, when the side text says there is
    // one — the model itself has no idea how long the file is.
    if (hunks.length != 0 && opt.sideText.length != 0)
    {
        const last = hunks[$ - 1];
        const after = last.newStart + last.newCount;
        const total = cast(uint) countLines(opt.sideText);
        if (total >= after)
            rows ~= keyed(b, contextGap(b, after, total - after + 1,
                gutterWidth, opt, gapIndex),
                opt.fileKey ? diffGapKey(gapIndex) : 0);
    }

    auto fileCol = b.container(WidgetKind.column, rows, gap: 1);
    if (opt.layout == DiffLayout.split)
        fileCol = grown(b, fileCol);
    return keyed(b, fileCol, opt.fileKey);
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

/// `true` for a key produced by $(LREF diffHunkKey) — and not a gap key.
bool isDiffHunkKey(size_t key) @safe pure nothrow @nogc
    => key >= diffHunkKeyBase && key < diffGapKeyBase;

/// The document-global hunk index a hunk key names — $(LREF diffHunkKey)
/// read back, so a laid-out row resolves to the model element it came from.
size_t diffHunkIndexOf(size_t key) @safe pure nothrow @nogc
in (isDiffHunkKey(key))
    => key - diffHunkKeyBase;

/// `DVG2`: the key an unchanged-region band carries, in a third id space above
/// the hunk keys — so one `keyedRects` sweep locates files, hunks and gaps
/// without any of them having to know about the others.
enum size_t diffGapKeyBase = size_t.max / 4 * 3 + 1;

/// ditto
size_t diffGapKey(size_t gapIndex) @safe pure nothrow @nogc
    => diffGapKeyBase + gapIndex;

/// `true` for a key produced by $(LREF diffGapKey).
bool isDiffGapKey(size_t key) @safe pure nothrow @nogc => key >= diffGapKeyBase;

/// Marks a node as filling its parent's remaining width.
private uint grown(ref Builder b, uint node) @safe
{
    b.nodes[node].width = SizeSpec.grow();
    return node;
}

/**
Marks a node as exactly half its parent's width — one pane of a split layout.

`percent(50)` rather than `grow`: the layout hands a grower its natural width
PLUS a share of the leftover, so two `grow` halves whose contents differ in
length end up different widths and the panes stop lining up. A split view whose
divider wanders with the text is worse than no split view.
*/
private uint halfWidth(ref Builder b, uint node) @safe
{
    b.nodes[node].width = SizeSpec(SizeSpec.Kind.percent, 50);
    return node;
}

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

/// The threads belonging to one file. Matched on either path so a rename
/// does not orphan a conversation written before it.
private const(AnchoredThread)[] threadsFor(
    return scope const(AnchoredThread)[] all, scope const(char)[] newPath,
    scope const(char)[] oldPath) @safe
{
    const(AnchoredThread)[] mine;
    foreach (ref t; all)
        if (t.path == newPath || t.path == oldPath)
            mine ~= t;
    return mine;
}

/// Does this thread hang on this row? A thread on the old side anchors to a
/// removed or context row's old line; one on the new side to an added or
/// context row's new line.
private bool anchoredHere(in AnchoredThread t, in Row row) @safe pure nothrow @nogc
{
    if (t.line == 0)
        return false; // outdated: no line to hang on
    return t.oldSide ? row.oldLine == t.line : row.newLine == t.line;
}

/**
`DPR3`/`DCM2`: one review conversation, rendered under its anchor line.

A resolved thread folds to a single line. That is not tidiness — an
unresolved conversation is a thing the reviewer must act on, and rendering a
settled argument at the same weight buries the live one. The badge still says
who and how many, so nothing is hidden, only demoted; the same
demote-never-hide contract `DVN2` holds for noise.

Indented to the code's column so the conversation reads as belonging to that
line rather than to the file.
*/
private uint threadBlock(ref Builder b, in AnchoredThread t, int gutterWidth,
    in DiffViewOptions opt) @safe
{
    import sparkles.syntax.md.render_widgets : MdViewOptions, viewMarkdownInto;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.style : TextStyle;

    const pad = gutterWidth > 0 ? gutterWidth + 2 : 2;
    auto indent = new char[](pad);
    indent[] = ' ';

    if (t.resolved)
    {
        const who = t.comments.length ? t.comments[0].author : "someone";
        return b.add(Widget(kind: WidgetKind.rich, spans: [
            TextSpan(indent.idup, slot: Slot.gutter),
            TextSpan(text("✓ resolved — ", t.comments.length,
                t.comments.length == 1 ? " comment by " : " comments, from ",
                who), slot: Slot.muted),
        ]));
    }

    auto rows = new uint[](0);
    foreach (i, ref c; t.comments)
    {
        TextSpan[] head = [TextSpan(indent.idup, slot: Slot.gutter)];
        head ~= TextSpan(i == 0 ? "▌ " : "│ ", slot: Slot.chromeAccent);
        head ~= TextSpan(c.author.idup, slot: Slot.chromeAccent,
            textStyle: TextStyle(bold: true));
        if (c.when.length)
            head ~= TextSpan("  " ~ c.when.idup, slot: Slot.muted);
        if (t.outdated && i == 0)
            head ~= TextSpan("  (outdated)", slot: Slot.muted);
        rows ~= b.add(Widget(kind: WidgetKind.rich, spans: head));

        if (c.body_.root.children.length)
        {
            // Indented by PADDING, not by a prefix span: a comment body wraps,
            // and a prefix only ever lands on the first row — leaving the rest
            // hanging out at the code's own column, which reads as code.
            MdViewOptions mopt;
            rows ~= b.add(Widget(kind: WidgetKind.column,
                children: [viewMarkdownInto(b, c.body_, mopt)],
                padding: Insets(0, 0, 0, pad + 2)));
        }
    }
    return b.container(WidgetKind.column, rows);
}

/**
`DPR2`: the session header — what this change is, then its description.

Two rows and a document: a title line, a metadata line naming the state,
author and the branches involved, and the description rendered through
`viewMarkdownInto`. The fence renderer the diff already carries for `DVM5`
composition is exactly the shape the markdown view wants for its fences, so a
code block inside a PR description is highlighted by the same pipeline that
highlights the diff below it.
*/
private uint sessionHeader(ref Builder b, const SessionHeader h,
    SideRenderer render, in DiffViewOptions opt) @safe
{
    import sparkles.syntax.md.render_widgets : MdViewOptions, viewMarkdownInto;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.style : TextStyle;

    auto rows = new uint[](0);
    if (h.title.length)
        rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [
            TextSpan(h.title.idup, Slot.chromeAccent, TextStyle(bold: true)),
        ]));

    TextSpan[] meta;
    if (h.state.length)
        meta ~= TextSpan(h.state.idup, stateSlot(h.state));
    if (h.author.length)
        meta ~= TextSpan(text(meta.length ? "  " : "", "by ", h.author),
            slot: Slot.muted);
    if (h.headRef.length || h.baseRef.length)
        meta ~= TextSpan(text(meta.length ? "  " : "", h.headRef, " → ",
            h.baseRef), slot: Slot.muted);
    if (meta.length)
        rows ~= b.add(Widget(kind: WidgetKind.rich, spans: meta));

    if (h.description.root.children.length)
    {
        MdViewOptions mopt;
        if (render !is null)
            mopt.fenceRenderer = (const(char)[] lang, const(char)[] body_)
                => render(lang, body_);
        rows ~= viewMarkdownInto(b, h.description, mopt);
    }
    return b.container(WidgetKind.column, rows, gap: 0);
}

/// The state word's colour: a merged or open PR reads as its diff tint, a
/// closed one as muted — the same vocabulary the rows below it use.
private Slot stateSlot(scope const(char)[] state) @safe pure nothrow @nogc
{
    switch (state)
    {
        case "merged": return Slot.diffEmphAdded;
        case "open":   return Slot.diffAdded;
        case "draft":  return Slot.muted;
        default:       return Slot.diffRemoved;
    }
}

/// `DVN2`: a demoted hunk, folded to one dimmed line that says what it is
/// standing in for. The count is rows, not hunks, because that is what the
/// reviewer is deciding whether to read.
///
/// The verdict is named, not generalized: `DVN7`'s reorder is not formatting,
/// and a reviewer told "formatting only" about a sorted import block has been
/// told something false about their code.
private uint foldedHunk(ref Builder b, const ref DiffDoc doc, in Hunk hunk) @safe
{
    uint changed;
    foreach (ref row; doc.hunkRows(hunk))
        if (row.kind != RowKind.context)
            ++changed;
    return b.add(Widget(kind: WidgetKind.rich, spans: [
        TextSpan(text("@@ -", hunk.oldStart, " +", hunk.newStart, " @@  "),
            slot: Slot.muted),
        TextSpan(text(hunk.reordered ? "reordered — " : "formatting only — ",
            changed, changed == 1 ? " row hidden" : " rows hidden"),
            slot: Slot.muted),
    ]));
}

/**
`DVG2`: an unchanged region — folded to a band that says how many lines it
stands for, or expanded into those lines.

The band is the honest form of a context window: the reviewer can see that
something was elided and how much, which a silent jump in line numbers does
not convey. Expansion reads from the side text rather than re-running the
diff, because these lines are unchanged by definition — the same on both
sides — so there is nothing to recompute.

Without a side text the band still renders but cannot expand: a patch does not
carry the lines it elided, and pretending otherwise would mean inventing them.
*/
private uint contextGap(ref Builder b, uint firstLine, uint count,
    int gutterWidth, DiffViewOptions opt, size_t gapIndex) @safe
{
    if (count == 0)
        return b.add(Widget(kind: WidgetKind.text, text: ""));

    const expandedHere = gapIndex < opt.expandedGaps.length
        && opt.expandedGaps[gapIndex];
    if ((!opt.expandContext && !expandedHere) || opt.sideText.length == 0)
        return b.add(Widget(kind: WidgetKind.rich, spans: [
            TextSpan(text("⋯ ", count,
                count == 1 ? " unchanged line" : " unchanged lines"),
                slot: Slot.muted),
        ]));

    auto rows = new uint[](0);
    foreach (n; firstLine .. firstLine + count)
    {
        const line = lineOf(opt.sideText, n);
        if (line is null)
            break;
        TextSpan[] spans;
        if (gutterWidth > 0)
            spans ~= TextSpan(bothGutterText(n, gutterWidth), slot: Slot.gutter);
        spans ~= TextSpan("  ");
        spans ~= TextSpan(line);
        rows ~= b.add(Widget(kind: WidgetKind.rich, spans: spans));
    }
    if (rows.length == 0)
        return b.add(Widget(kind: WidgetKind.text, text: ""));
    return b.container(WidgetKind.column, rows);
}

/// The 1-based `n`th line of `text` without its newline, or `null` past the
/// end. Scans; the gaps a reviewer expands are few and short-lived.
private const(char)[] lineOf(const(char)[] text, uint n) @safe pure nothrow @nogc
{
    if (n == 0)
        return null;
    size_t start;
    uint line = 1;
    foreach (i, c; text)
    {
        if (c != '\n')
            continue;
        if (line == n)
            return text[start .. i];
        ++line;
        start = i + 1;
    }
    return line == n && start < text.length ? text[start .. $] : null;
}

/// Physical lines in `text` (an unterminated last line counts).
private size_t countLines(const(char)[] text) @safe pure nothrow @nogc
{
    if (text.length == 0)
        return 0;
    size_t n;
    foreach (c; text)
        if (c == '\n')
            ++n;
    return text[$ - 1] == '\n' ? n : n + 1;
}

/// An expanded context line's gutter: the same number on both sides, since an
/// unchanged line has the same position in each.
private const(char)[] bothGutterText(uint n, int width) @safe
{
    auto digits = text(n);
    auto s = new char[](width + 1);
    s[] = ' ';
    const half = width / 2;
    const start = digits.length >= cast(size_t) half
        ? 0 : cast(size_t) half - digits.length;
    foreach (i, c; digits)
        if (start + i < cast(size_t) half)
            s[start + i] = c;
    foreach (i, c; digits)
        if (half + 1 + i < cast(size_t) width)
            s[half + 1 + i] = c;
    return s;
}

/// The hunk header, rendered as its own tinted band — shared by both layouts.
private uint hunkHeader(ref Builder b, in Hunk hunk) @safe
    => b.add(Widget(kind: WidgetKind.rich, spans: [
        TextSpan(text("@@ -", hunk.oldStart, ",", hunk.oldCount,
            " +", hunk.newStart, ",", hunk.newCount, " @@"),
            slot: Slot.diffHunk, paintBackground: true),
    ]));

private uint noticeRow(ref Builder b, string message) @safe
    => b.add(Widget(kind: WidgetKind.text, text: message, slot: Slot.muted));

/// `DVL2`: one hunk as two aligned panes.
private uint viewHunkSplit(ref Builder b, const ref DiffDoc doc, in Hunk hunk,
    int gutterWidth, DiffViewOptions opt) @safe
{
    auto rows = new uint[](0);
    rows ~= hunkHeader(b, hunk);

    const hunkRows = doc.hunkRows(hunk);
    foreach (pair; alignSplitRows(hunkRows))
    {
        const left = splitHalf(b, doc, hunkRows, pair.old_, true,
            gutterWidth, opt);
        const right = splitHalf(b, doc, hunkRows, pair.new_, false,
            gutterWidth, opt);
        // The row itself must fill the pane, or its two `grow` halves have no
        // remaining space to divide and both shrink-wrap their text.
        // The row fills the pane; its two halves each take exactly 50% of it.
        rows ~= grown(b, b.container(WidgetKind.row, [left, right]));
    }
    // Every container between the panes and the viewport must fill the width,
    // or `percent(50)` resolves against a shrink-wrapped ancestor and the
    // halves collapse back onto their text.
    return grown(b, b.container(WidgetKind.column, rows));
}

/**
One side of one aligned row: the line-number gutter, the marker, and the text
with its tint — or a filler when this side has no line.

The filler is a tinted empty box rather than blank space, because the reader
needs to see that the OTHER side gained or lost a line; blank space would read
as "unchanged and short".
*/
private uint splitHalf(ref Builder b, const ref DiffDoc doc,
    const(Row)[] hunkRows, int idx, bool oldSide, int gutterWidth,
    DiffViewOptions opt) @safe
{
    if (idx < 0)
    {
        const filler = b.add(Widget(kind: WidgetKind.box, slot: Slot.diffFill,
            paintBackground: true, width: SizeSpec.grow(), height: SizeSpec.fixed(1)));
        return halfWidth(b, b.container(WidgetKind.column, [filler]));
    }

    const row = hunkRows[cast(size_t) idx];
    TextSpan[] spans;
    if (gutterWidth > 0)
        spans ~= TextSpan(halfGutterText(row, oldSide, gutterWidth),
            slot: Slot.gutter);

    const rowText = doc.rowText(row);
    const emph = doc.rowEmph(row);
    const styled = row.kind == RowKind.added
        ? styledLine(opt.newStyled, row.newLine)
        : styledLine(opt.oldStyled, row.oldLine);

    final switch (row.kind) with (RowKind)
    {
        case context:
            spans ~= TextSpan("  ");
            spans ~= composedSpans(styled, rowText, emph, Slot.inherit,
                Slot.inherit, false);
            break;
        case removed:
            spans ~= TextSpan("- ", slot: Slot.diffRemoved, paintBackground: true);
            spans ~= composedSpans(styled, rowText, emph, Slot.diffRemoved,
                Slot.diffEmphRemoved, true);
            break;
        case added:
            spans ~= TextSpan("+ ", slot: Slot.diffAdded, paintBackground: true);
            spans ~= composedSpans(styled, rowText, emph, Slot.diffAdded,
                Slot.diffEmphAdded, true);
            break;
    }
    const text = b.add(Widget(kind: WidgetKind.rich, spans: spans));
    return halfWidth(b, b.container(WidgetKind.column, [text]));
}

/// The one side's line number, right-aligned in `width` cells.
private const(char)[] halfGutterText(in Row row, bool oldSide, int width) @safe
{
    const n = oldSide ? row.oldLine : row.newLine;
    auto s = new char[](width + 1);
    s[] = ' ';
    if (n != 0)
    {
        auto digits = text(n);
        const start = digits.length >= cast(size_t) width
            ? 0 : cast(size_t) width - digits.length;
        foreach (i, c; digits)
            if (start + i < cast(size_t) width)
                s[start + i] = c;
    }
    return s;
}

private uint viewHunk(ref Builder b, const ref DiffDoc doc, in Hunk hunk,
    int gutterWidth, DiffViewOptions opt) @safe
{
    auto rows = new uint[](0);
    rows.reserve(hunk.rowsCount + 1);

    rows ~= hunkHeader(b, hunk);

    foreach (ref row; doc.hunkRows(hunk))
    {
        rows ~= viewRow(b, doc, row, gutterWidth, opt);
        // `DPR3`: the conversation goes UNDER the line it is about, the way
        // a reviewer reads it — not in a margin, and not in a separate pane
        // where the code it refers to is no longer on screen.
        foreach (ref t; opt.threads)
            if (anchoredHere(t, row))
                rows ~= threadBlock(b, t, gutterWidth, opt);
    }

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
    import sparkles.ui.geometry : SizeSpec;
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

@("diff_view.reordered.foldsUnderItsOwnName")
@safe unittest
{
    // `DVN7`: a permuted commutative container folds like formatting noise
    // but must not be LABELLED formatting — the reviewer would be told
    // something false about their code. Same fold, different sentence.
    enum before = "b\na\n";
    enum after = "a\nb\n";
    auto doc = diffText(before, after, "t.d", "t.d");
    auto hunk = doc.hunks[0];
    hunk.reordered = true; // stamped by `document.classifyStructural`
    doc.hunks[0] = hunk;

    DiffViewOptions opt; // foldFormattingOnly defaults on
    auto b = Builder();
    auto tree = b.finish(viewDiffInto(b, doc, doc.files[0], opt));

    bool sawBadge;
    foreach (ref n; tree.nodes)
        foreach (sp; n.spans)
        {
            if (sp.text.length >= 10 && sp.text[0 .. 10] == "reordered ")
                sawBadge = true;
            assert(sp.text.length < 16 || sp.text[0 .. 16] != "formatting only ",
                "a reorder is not formatting");
        }
    assert(sawBadge, "the fold names the verdict it actually reached");
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

@("diff_view.alignSplitRows.pairsFillersAndOrder")
@safe unittest
{
    // Alignment is a correspondence between rows, so it is tested as one —
    // indices only, no widgets, no text.
    // A block of `-a -b +A +B` where a↔A and b↔B: two aligned rows.
    Row[] rows = [
        Row(RowKind.removed, 1, 0, Span(0, 1), 2),
        Row(RowKind.removed, 2, 0, Span(0, 1), 3),
        Row(RowKind.added, 0, 1, Span(0, 1), 0),
        Row(RowKind.added, 0, 2, Span(0, 1), 1),
    ];
    auto aligned = alignSplitRows(rows);
    assert(aligned.length == 2);
    assert(aligned[0] == SplitRow(0, 2));
    assert(aligned[1] == SplitRow(1, 3));

    // An unpaired removal gets a filler opposite it, and an unpaired addition
    // gets one on the other side — the reader must see that a line was gained
    // or lost, which blank space would not convey.
    Row[] uneven = [
        Row(RowKind.context, 1, 1, Span(0, 1), -1),
        Row(RowKind.removed, 2, 0, Span(0, 1), -1),
        Row(RowKind.added, 0, 2, Span(0, 1), -1),
    ];
    auto a2 = alignSplitRows(uneven);
    assert(a2.length == 3);
    assert(a2[0] == SplitRow(0, 0), "context occupies both sides");
    assert(a2[1] == SplitRow(1, -1), "removal opposite a filler");
    assert(a2[2] == SplitRow(-1, 2), "addition opposite a filler");

    // A paired addition is never emitted twice — once as its partner's right
    // half, and again on its own.
    Row[] paired = [
        Row(RowKind.removed, 1, 0, Span(0, 1), 1),
        Row(RowKind.added, 0, 1, Span(0, 1), 0),
    ];
    assert(alignSplitRows(paired).length == 1);
}

@("diff_view.splitLayout.rendersTwoPanesAndDegradesWhenNarrow")
@safe unittest
{
    auto doc = diffText("alpha\nbeta\n", "alpha\nBETA\n", "t.txt", "t.txt");

    DiffViewOptions opt;
    opt.layout = DiffLayout.split;
    auto wide = viewDiffDoc(doc, opt, null, null, DiffSession.init, null, 120);

    // The split layout puts each aligned row in a `row` container of two
    // halves that are each exactly 50% wide. `percent`, not `grow`: a grower
    // gets its natural width PLUS a share of the leftover, so two `grow`
    // halves with different content end up different widths and the divider
    // wanders down the page.
    static bool isHalf(in WidgetTree t, uint idx)
        => t.nodes[idx].width.kind == SizeSpec.Kind.percent
            && t.nodes[idx].width.value == 50;

    size_t splitRows;
    foreach (ref n; wide.nodes)
        if (n.kind == WidgetKind.row && n.children.length == 2
            && isHalf(wide, n.children[0]) && isHalf(wide, n.children[1]))
            ++splitRows;
    assert(splitRows >= 2, "aligned rows render as two equal panes");

    // `DVL3`: below the threshold the same request renders unified instead —
    // two 30-column panes would wrap every line into a ribbon.
    auto narrow = viewDiffDoc(doc, opt, null, null, DiffSession.init, null, 40);
    size_t narrowSplitRows;
    foreach (ref n; narrow.nodes)
        if (n.kind == WidgetKind.row && n.children.length == 2
            && isHalf(narrow, n.children[0]))
            ++narrowSplitRows;
    assert(narrowSplitRows == 0, "a narrow pane degrades to unified");

    // Width 0 means "the caller did not say" — the static sinks, which lay
    // out at their own width and are not asking to be second-guessed.
    auto unsized = viewDiffDoc(doc, opt, null, null, DiffSession.init, null, 0);
    size_t unsizedSplitRows;
    foreach (ref n; unsized.nodes)
        if (n.kind == WidgetKind.row && n.children.length == 2
            && isHalf(unsized, n.children[0]))
            ++unsizedSplitRows;
    assert(unsizedSplitRows >= 2, "no width given, no degradation");
}

@("diff_view.contextGap.bandCountsAndExpandsFromTheSideText")
@safe unittest
{
    // Two changes far apart, so the context window leaves a real gap between
    // the hunks — the region a reviewer cannot see and is not told about
    // unless the view says so.
    string oldText, newText;
    foreach (i; 1 .. 31)
    {
        const line = text("line ", i, "\n");
        oldText ~= line;
        newText ~= (i == 2 || i == 28) ? text("CHANGED ", i, "\n") : line;
    }
    auto doc = diffText(oldText, newText, "f.txt", "f.txt");
    assert(doc.files[0].hunksCount == 2, "precondition: two separate hunks");

    // Folded: a band saying how many lines it stands for.
    DiffViewOptions opt;
    auto b = Builder();
    auto folded = b.finish(viewDiffInto(b, doc, doc.files[0], opt));
    const(char)[] band;
    foreach (ref n; folded.nodes)
        foreach (sp; n.spans)
            if (sp.text.length >= 4 && sp.text[0 .. 4] == "⋯ ")
                band = sp.text;
    assert(band.length, "the hidden region announces itself");
    // Hunks cover lines 1-5 and 25-30 at three lines of context, so the gap
    // is 6..24 — nineteen lines, and the band must say exactly that.
    assert(band == "⋯ 19 unchanged lines", band);

    // Expanded: the lines themselves, read from the side text.
    DiffViewOptions ex;
    ex.expandContext = true;
    ex.sideText = newText;
    auto b2 = Builder();
    auto shown = b2.finish(viewDiffInto(b2, doc, doc.files[0], ex));
    bool sawHidden;
    foreach (ref n; shown.nodes)
        foreach (sp; n.spans)
            if (sp.text == "line 15")
                sawHidden = true;
    assert(sawHidden, "a line only the gap could supply is now on screen");

    // Without a side text there is nothing to expand WITH — a patch does not
    // carry the lines it elided, and the band must not pretend otherwise.
    DiffViewOptions noText;
    noText.expandContext = true;
    auto b3 = Builder();
    auto stillFolded = b3.finish(viewDiffInto(b3, doc, doc.files[0], noText));
    bool leaked;
    foreach (ref n; stillFolded.nodes)
        foreach (sp; n.spans)
            if (sp.text == "line 15")
                leaked = true;
    assert(!leaked, "no side text, no expansion");
}

@("diff_view.sessionHeader.rendersThePrAboveItsFiles")
@safe unittest
{
    import diff_session : buildDiffSession;
    import sparkles.syntax.md.model : MdBlock, MdBlockKind, MdDoc, MdInline,
        MdInlineKind, Span;

    auto doc = diffText("a\n", "b\n", "f.txt", "f.txt");
    auto session = buildDiffSession(doc);

    enum body_ = "why this change";
    MdDoc description = {
        source: body_,
        root: MdBlock(kind: MdBlockKind.document, children: [
            MdBlock(kind: MdBlockKind.paragraph, span: Span(0, body_.length),
                inlines: [MdInline(kind: MdInlineKind.text,
                    span: Span(0, body_.length))]),
        ]),
    };
    session.header = SessionHeader(present: true, title: "feat: a thing",
        state: "open", author: "someone", baseRef: "main", headRef: "topic",
        description: description);

    auto tree = viewDiffDoc(doc, DiffViewOptions.init, null, null, session);

    const(char)[] all;
    foreach (ref n; tree.nodes)
    {
        all ~= n.text;
        foreach (sp; n.spans)
            all ~= sp.text;
    }

    import std.algorithm.searching : canFind;

    assert(all.canFind("feat: a thing"), "the title leads");
    assert(all.canFind("open") && all.canFind("someone"));
    assert(all.canFind("topic") && all.canFind("main"),
        "which branch is going where is metadata a reviewer needs");
    // The description goes through the markdown view, not a raw dump.
    assert(all.canFind("why this change"));

    // A session without a header renders exactly as before.
    auto plain = viewDiffDoc(doc, DiffViewOptions.init, null, null,
        buildDiffSession(doc));
    const(char)[] plainText;
    foreach (ref n; plain.nodes)
    {
        plainText ~= n.text;
        foreach (sp; n.spans)
            plainText ~= sp.text;
    }
    assert(!plainText.canFind("feat: a thing"));
}

@("diff_view.threads.anchorUnderTheirLineAndFoldWhenResolved")
@safe unittest
{
    import diff_session : AnchoredThread, buildDiffSession, ThreadComment;
    import sparkles.syntax.md.model : MdBlock, MdBlockKind, MdDoc, MdInline,
        MdInlineKind, Span;

    static MdDoc prose(string text) @safe
    {
        MdDoc d = {
            source: text,
            root: MdBlock(kind: MdBlockKind.document, children: [
                MdBlock(kind: MdBlockKind.paragraph, span: Span(0, text.length),
                    inlines: [MdInline(kind: MdInlineKind.text,
                        span: Span(0, text.length))]),
            ]),
        };
        return d;
    }

    auto doc = diffText("one\ntwo\nthree\n", "one\nTWO\nthree\n", "f.d", "f.d");
    auto session = buildDiffSession(doc);
    session.threads = [
        AnchoredThread(path: "f.d", line: 2, resolved: false,
            comments: [ThreadComment("reviewer", "2026-08-07",
                prose("this needs a why"))]),
        AnchoredThread(path: "f.d", line: 3, resolved: true,
            comments: [ThreadComment("reviewer", "2026-08-06",
                prose("settled long ago"))]),
    ];

    auto tree = viewDiffDoc(doc, DiffViewOptions.init, null, null, session);

    const(char)[] all;
    size_t threadRow = size_t.max, anchorRow = size_t.max;
    foreach (i, ref n; tree.nodes)
    {
        const(char)[] row = n.text;
        foreach (sp; n.spans)
            row ~= sp.text;
        all ~= row;

        import std.algorithm.searching : canFind;

        if (row.canFind("this needs a why"))
            threadRow = i;
        if (row.canFind("TWO"))
            anchorRow = i;
    }

    import std.algorithm.searching : canFind;

    assert(threadRow != size_t.max, "an unresolved thread renders its comments");
    assert(anchorRow != size_t.max && anchorRow < threadRow,
        "the conversation goes UNDER the line it is about");
    assert(all.canFind("reviewer") && all.canFind("2026-08-07"));

    // A resolved thread demotes to one line: still there, no longer shouting.
    assert(!all.canFind("settled long ago"), "a resolved body folds away");
    assert(all.canFind("resolved"), "but the badge says it exists");

    // Threads belong to their own file: another path's conversations are not
    // borrowed by this one.
    session.threads[0].path = "other.d";
    auto elsewhere = viewDiffDoc(doc, DiffViewOptions.init, null, null, session);
    const(char)[] other;
    foreach (ref n; elsewhere.nodes)
        foreach (sp; n.spans)
            other ~= sp.text;
    assert(!other.canFind("this needs a why"));
}

@("diff_view.threads.anOutdatedThreadHasNoLineToHangOn")
@safe unittest
{
    import diff_session : AnchoredThread, buildDiffSession, ThreadComment;

    // GitHub reports an outdated thread with a null line, which decodes to
    // zero. Zero must not match row 0 of anything — it means "nowhere".
    auto doc = diffText("a\n", "b\n", "f.d", "f.d");
    auto session = buildDiffSession(doc);
    session.threads = [AnchoredThread(path: "f.d", line: 0, outdated: true,
        comments: [ThreadComment("reviewer", "2026-08-01")])];

    auto tree = viewDiffDoc(doc, DiffViewOptions.init, null, null, session);
    const(char)[] all;
    foreach (ref n; tree.nodes)
        foreach (sp; n.spans)
            all ~= sp.text;

    import std.algorithm.searching : canFind;

    assert(!all.canFind("reviewer"),
        "a thread with no line anchors nowhere rather than at the top");
}
