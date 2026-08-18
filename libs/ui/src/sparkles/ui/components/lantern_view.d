/**
lantern's panel, as a widget tree (`LTN5`–`LTN8`).

$(MREF sparkles,ui,lantern) decides $(I what) is pending; this decides what
that looks like. Nothing here draws: it appends a subtree to a
$(REF Builder, sparkles,ui,widget), which each backend already knows how to
paint — so a GUI, a TUI and (for a static cheat sheet) HTML get one panel
rather than three that drift.

$(B The layout is which-key's, and it is the interesting part.) A binding set
is a list, but a list rendered as one tall column wastes a wide window and
scrolls when it should not. So the items are packed into $(I boxes) — as many
side-by-side columns as the width affords — filled top-to-bottom, one box at a
time. Widening the window reflows to more, shorter columns; narrowing collapses
back toward one. `boxesFillTheWidth` pins the arithmetic.

$(B Text is borrowed, never built.) A `Widget`'s text must outlive the tree, and
this module allocates nothing, so labels are written into a caller-owned arena
$(I first) and sliced $(I after) — never interleaved. A `SmallBuffer` can move
when it grows, so a slice taken before a later append is a dangling one; the
two-pass shape is what makes that impossible rather than merely unlikely, and it
is the same span-into-an-arena discipline $(MREF sparkles,diff) uses.

$(B The item type is structural.) $(LREF viewLantern) reads three things from
an item — `path[depth]` (a $(REF Chord, sparkles,ui,keymap)), `desc`, and
`group` — so it accepts any $(REF Binding, sparkles,ui,keymap) instantiation
without caring which command or scope enums parameterise it.
*/
module sparkles.ui.components.lantern_view;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.input.events : Key;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind;

import sparkles.ui.keymap : Chord, ShiftReq;

/**
Where the panel sits.

which-key ships three presets; sparkles ships the two whose difference is
real. Both anchor to the bottom, because that is the edge a reader is least
likely to be reading.
*/
enum Placement : ubyte
{
    /// Full width along the bottom edge, no border — which-key's `classic`.
    /// Covers the most rows but reflows into the most columns, so a large
    /// binding set stays on one screen.
    classic,
    /// A bordered panel in the bottom-right corner — which-key's `helix`.
    /// Covers less of the document; better when the set is small or the
    /// document is what you are actually reading.
    helix,
}

/// How the panel is spaced. Separate from $(LREF Placement) because a user may
/// want either placement at either density.
struct LanternStyle
{
    int minBoxWidth = 20;   /// narrowest a column may be, before spacing
    int boxSpacing = 3;     /// cells between columns
    int maxRows = 12;       /// tallest the panel may grow before it scrolls
    Insets padding = Insets(1, 2, 1, 2);
    dchar separator = '→';  /// between a key and its label
    dchar groupMark = '+';  /// prefixed to a prefix node's label
}

/// The arena panel labels are written into. Owned by the caller and reused
/// across frames, so a redraw allocates nothing.
alias LabelArena = SmallBuffer!(char, 2048);

/// A label's position in a $(LREF LabelArena). Recorded rather than sliced
/// because the arena may move while it is still being filled.
private struct Span
{
    uint start;
    uint length;
}

/// The panel's computed shape — how many columns of how many rows, and how
/// wide. Derived once and used for both the tree and any hit-testing, so the
/// two cannot disagree about where a row is.
struct BoxLayout
{
    int boxes = 1;  /// side-by-side columns
    int rows = 1;   /// rows per column
    int width = 20; /// each column's width in cells, spacing excluded

    /// How many items the panel can show at once. A binding set larger than
    /// this scrolls — it is never silently truncated, which is the failure
    /// mode a fixed row cap invites and which no assertion would catch,
    /// because a shorter panel looks exactly like a smaller keymap.
    int capacity() const @safe pure nothrow @nogc => boxes * rows;
}

/**
Packs `count` items into the widest arrangement `avail` cells allow.

which-key's `view.lua` arithmetic: fit as many `width`-cell columns as there is
room for, then divide the items among them. `rows` is at least two, so a
one-item panel is not a single floating line, and at most
$(LREF LanternStyle.maxRows).
*/
BoxLayout packBoxes(int count, int avail, int contentWidth,
    in LanternStyle st = LanternStyle.init) @safe pure nothrow @nogc
{
    BoxLayout l;
    if (count <= 0 || avail <= 0)
        return l;

    l.width = contentWidth < st.minBoxWidth ? st.minBoxWidth : contentWidth;
    const stride = l.width + st.boxSpacing;
    l.boxes = stride > 0 ? avail / stride : 1;
    if (l.boxes < 1)
        l.boxes = 1;
    if (l.boxes > count)
        l.boxes = count;

    l.rows = (count + l.boxes - 1) / l.boxes;
    if (l.rows < 2)
        l.rows = 2;
    if (l.rows > st.maxRows)
        l.rows = st.maxRows;
    return l;
}

/**
Writes `c`'s display label into `arena`.

Named keys get their glyph, modifiers their prefix, and a ranged chord its
`1-9` form — which is the point of keeping the range one row: it is one line on
the panel too.
*/
private Span writeKeyLabel(ref LabelArena arena, in Chord c)
    @safe nothrow @nogc
{
    const start = cast(uint) arena.length;

    if (c.ctrl)
        arena ~= "C-";
    if (c.alt)
        arena ~= "M-";
    if (c.shift == ShiftReq.yes)
        arena ~= "S-";

    if (c.key == Key.char_)
    {
        appendChar(arena, c.ch);
        if (c.chEnd)
        {
            arena ~= '-';
            appendChar(arena, c.chEnd);
        }
    }
    else
        arena ~= namedKeyLabel(c.key);

    return Span(start, cast(uint)(arena.length - start));
}

/// A printable code point's panel spelling. Space and the control-ish keys get
/// a visible glyph, because a blank cell reads as "no binding".
private void appendChar(ref LabelArena arena, dchar ch) @safe nothrow @nogc
{
    if (ch == ' ')
    {
        // A word, like the arrows below: a leader is the one key a whole map
        // hangs off, and `␣` renders as an underscore in several fonts.
        arena ~= "Space";
        return;
    }
    if (ch < 0x80)
    {
        arena ~= cast(char) ch;
        return;
    }
    // Most tables' code points are ASCII; encode anything else so a
    // configured binding cannot render as mojibake.
    char[4] buf;
    size_t n;
    if (ch < 0x800)
    {
        buf[0] = cast(char)(0xC0 | (ch >> 6));
        buf[1] = cast(char)(0x80 | (ch & 0x3F));
        n = 2;
    }
    else if (ch < 0x1_0000)
    {
        buf[0] = cast(char)(0xE0 | (ch >> 12));
        buf[1] = cast(char)(0x80 | ((ch >> 6) & 0x3F));
        buf[2] = cast(char)(0x80 | (ch & 0x3F));
        n = 3;
    }
    else
    {
        buf[0] = cast(char)(0xF0 | (ch >> 18));
        buf[1] = cast(char)(0x80 | ((ch >> 12) & 0x3F));
        buf[2] = cast(char)(0x80 | ((ch >> 6) & 0x3F));
        buf[3] = cast(char)(0x80 | (ch & 0x3F));
        n = 4;
    }
    arena ~= buf[0 .. n];
}

/// ditto, for the named keys.
private string namedKeyLabel(Key k) @safe pure nothrow @nogc
{
    final switch (k)
    {
        case Key.none:      return "?";
        case Key.char_:     return "?";
        // Spelled out, not as glyphs: the separator is itself an
        // arrow, and "→ → next theme" asks a reader to tell two
        // arrows apart by role. `Home`/`End`/`PgUp` are words for
        // the same reason.
        case Key.up:        return "Up";
        case Key.down:      return "Down";
        case Key.left:      return "Left";
        case Key.right:     return "Right";
        case Key.home:      return "Home";
        case Key.end:       return "End";
        case Key.pageUp:    return "PgUp";
        case Key.pageDown:  return "PgDn";
        case Key.insert:    return "Ins";
        case Key.delete_:   return "Del";
        case Key.enter:     return "↵";
        case Key.tab:       return "⇥";
        case Key.backspace: return "⌫";
        case Key.escape:    return "Esc";
        case Key.f1:        return "F1";
        case Key.f2:        return "F2";
        case Key.f3:        return "F3";
        case Key.f4:        return "F4";
        case Key.f5:        return "F5";
        case Key.f6:        return "F6";
        case Key.f7:        return "F7";
        case Key.f8:        return "F8";
        case Key.f9:        return "F9";
        case Key.f10:       return "F10";
        case Key.f11:       return "F11";
        case Key.f12:       return "F12";
        case Key.back:      return "Back";
        case Key.menu:      return "Menu";
    }
}

/// The widest key label and the widest description among `items`, which is
/// what a column has to be able to hold.
private void measure(B)(scope const(B)[] items, size_t depth,
    ref LabelArena arena, out int keyWidth, out int descWidth)
{
    const mark = arena.length;
    foreach (ref b; items)
    {
        const s = writeKeyLabel(arena, b.path[depth]);
        const w = cast(int) displayWidth(arena[][s.start .. s.start + s.length]);
        if (w > keyWidth)
            keyWidth = w;
        const d = cast(int) b.desc.length + (b.group.length ? 1 : 0);
        if (d > descWidth)
            descWidth = d;
    }
    arena.length = mark; // measurement is not storage
}

/// Cells a UTF-8 label occupies. One per code point: the panel's own labels
/// are ASCII plus a handful of BMP arrows; a true width table is a host
/// concern.
private size_t displayWidth(scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t n;
    foreach (c; s)
        if ((c & 0xC0) != 0x80)
            ++n;
    return n;
}

/**
Builds the panel.

`items` is what $(REF bindingsAt, sparkles,ui,keymap) listed, `depth` the
number of chords already typed (so the label comes from the right chord of
each path), and `arena` a caller-owned buffer this fills with the labels the
tree borrows.

Returns the subtree's root index. `layout` reports the shape that was used, so
a caller can hit-test rows against the same arithmetic rather than re-deriving
it.
*/
uint viewLantern(B)(ref Builder b, ref LabelArena arena,
    scope const(B)[] items, size_t depth, int availWidth,
    out BoxLayout layout, Placement placement = Placement.classic,
    in LanternStyle st = LanternStyle.init, size_t hitBase = 0, int scroll = 0)
{
    // ── pass 1: every label into the arena, positions recorded ───────────
    arena.clear();
    int keyWidth, descWidth;
    measure(items, depth, arena, keyWidth, descWidth);

    const inner = availWidth - st.padding.left - st.padding.right;
    layout = packBoxes(cast(int) items.length,
        placement == Placement.helix ? st.minBoxWidth + st.boxSpacing : inner,
        keyWidth + 3 + descWidth, st);

    // Show the window starting at `scroll`, clamped so the last page is full
    // rather than mostly blank.
    const total = cast(int) items.length;
    int first = scroll;
    if (first > total - layout.capacity)
        first = total - layout.capacity;
    if (first < 0)
        first = 0;

    SmallBuffer!(Span, 64) keys, descs;
    foreach (ref item; items)
    {
        keys ~= writeKeyLabel(arena, item.path[depth]);
        const start = cast(uint) arena.length;
        if (item.group.length)
            appendChar(arena, st.groupMark);
        arena ~= item.desc;
        descs ~= Span(start, cast(uint)(arena.length - start));
    }

    // ── pass 2: the tree, slicing an arena that no longer moves ──────────
    const(char)[] label(in Span s) => arena[][s.start .. s.start + s.length];

    SmallBuffer!(uint, 32) rows;
    foreach (r; 0 .. layout.rows)
    {
        SmallBuffer!(uint, 8) cells;
        foreach (col; 0 .. layout.boxes)
        {
            const i = first + col * layout.rows + r;
            if (i >= total)
                continue;
            cells ~= itemCell(b, label(keys[i]), label(descs[i]),
                items[i].group.length != 0, keyWidth, layout.width, st,
                hitBase == 0 ? 0 : hitBase + i);
        }
        if (cells.length == 0)
            continue;
        rows ~= b.add(Widget(
            kind: WidgetKind.row,
            children: cells[].dup,
            gap: st.boxSpacing,
        ));
    }

    // The rows go in an explicit `column`, because a `popup` is a STACK — it
    // gives every child the same origin. Handing it the rows directly painted
    // the whole panel onto one line, which is what
    // `columnsDoNotOverlap` now catches.
    const stack = b.add(Widget(
        kind: WidgetKind.column,
        children: rows[].dup,
    ));
    return b.add(Widget(
        kind: WidgetKind.popup,
        children: [stack],
        slot: Slot.surface,
        paintBackground: true,
        padding: st.padding,
        width: placement == Placement.classic
            ? SizeSpec.grow() : SizeSpec.fit_,
    ));
}

/// One `key → label` cell, key right-aligned in its own fixed column so the
/// separators line up down the panel — the container's `LAY8` alignment does
/// it, not hand-padded strings.
private uint itemCell(ref Builder b, const(char)[] key, const(char)[] desc,
    bool isGroup, int keyWidth, int cellWidth, in LanternStyle st,
    size_t hitId) @safe
{
    const k = b.add(Widget(
        kind: WidgetKind.text,
        text: key,
        slot: Slot.chromeAccent,
        width: SizeSpec.fixed(keyWidth),
        alignX: Alignment.end,
    ));
    const sepBuf = separatorText(st.separator);
    const sep = b.add(Widget(
        kind: WidgetKind.text,
        text: sepBuf,
        slot: Slot.muted,
    ));
    const d = b.add(Widget(
        kind: WidgetKind.text,
        text: desc,
        // A group reads as a destination, a command as an action; the palette
        // is what tells them apart at a glance, so the panel does not need a
        // second marker beyond the `+`.
        slot: isGroup ? Slot.chromeAccent : Slot.docs,
        width: SizeSpec.grow(),
    ));
    return b.add(Widget(
        kind: WidgetKind.row,
        children: [k, sep, d],
        width: SizeSpec.fixed(cellWidth),
        gap: 1,
        hitId: hitId,
    ));
}

/// The separator as a borrowable string. The default is `immutable`, so the
/// common case needs no storage at all.
private const(char)[] separatorText(dchar sep) @safe pure nothrow @nogc
{
    return sep == '→' ? "→" : sep == '➜' ? "➜" : sep == '>' ? ">" : "→";
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

version (UiKeymapFixtures)
{
    import sparkles.ui.keymap : bind, chord, group, TestBinding, TestCommand,
        TestScope;

    // Long enough that a list of these outgrows the arena's inline storage,
    // so the grow-survival test exercises at least one real move.
    enum longDesc = "a deliberately long description that pads the arena well "
        ~ "past what a short label would, so growth is forced, not assumed";

    immutable TestBinding[] manyBindings = () {
        TestBinding[] r;
        r ~= group!TestCommand(TestScope.shared_, chord('z'), "fold things");
        r ~= bind(TestScope.shared_, chord('/'), TestCommand.next, "search");
        foreach (c; 'a' .. 'z')
            r ~= bind(TestScope.shared_, chord(c), TestCommand.down, longDesc);
        r ~= bind(TestScope.shared_, chord('.'), TestCommand.down, "the last one");
        return r;
    }();
}

@("ui.lantern_view.boxesFillTheWidth")
@safe pure nothrow @nogc
unittest
{
    LanternStyle st;
    // A wide window packs many short columns; the same set in a narrow one
    // collapses toward a single tall column. That reflow is the whole reason
    // the panel is laid out rather than listed.
    const wide = packBoxes(20, 200, 20, st);
    assert(wide.boxes > 4 && wide.rows * wide.boxes >= 20);

    const narrow = packBoxes(20, 24, 20, st);
    assert(narrow.boxes == 1 && narrow.rows >= 12 - 1);

    // Never zero columns, however cramped — a panel with no column is not a
    // narrower panel, it is a crash waiting for the row loop.
    assert(packBoxes(5, 1, 40, st).boxes == 1);
    assert(packBoxes(0, 100, 20, st).boxes == 1, "…and an empty set is still valid");

    // Never more columns than items, or trailing columns render empty.
    assert(packBoxes(3, 500, 10, st).boxes == 3);

    // A one-item panel is two rows tall, not a single floating line.
    assert(packBoxes(1, 500, 10, st).rows == 2);
}

@("ui.lantern_view.keyLabelsAreReadable")
@safe nothrow @nogc
unittest
{
    import sparkles.ui.keymap : Chord, chordRange;

    LabelArena a;

    const(char)[] lbl(in Chord c)
    {
        a.clear();
        const s = writeKeyLabel(a, c);
        return a[][s.start .. s.start + s.length];
    }

    assert(lbl(chord('j')) == "j");
    assert(lbl(chord('r', ShiftReq.yes)) == "S-r");
    assert(lbl(Chord(key: Key.char_, ch: 'c', ctrl: true)) == "C-c");
    assert(lbl(chord(Key.enter)) == "↵");
    assert(lbl(chord(Key.backspace)) == "⌫");

    // A ranged chord is one line, as it is one row — the reason `chEnd`
    // exists rather than nine near-identical bindings.
    assert(lbl(chordRange('1', '9')) == "1-9");

    // A leader must be visible. A blank cell reads as "no binding", which
    // is exactly wrong for the one key a whole map hangs off.
    assert(lbl(chord(' ')) == "Space");
}

@("ui.lantern_view.everyLabelSurvivesTheArenaGrowing")
@safe
unittest
{
    // The property the two-pass shape exists for. A `SmallBuffer` moves when
    // it outgrows its inline storage, so a slice taken before a later append
    // dangles — and the failure is SILENT: the tree renders another item's
    // text, or mojibake, with nothing to assert against. Building the labels
    // to completion first and slicing afterwards makes it impossible.
    //
    // The fixture's descriptions are sized to exceed the arena's inline
    // capacity, so this exercises at least one grow rather than assuming one.
    const items = manyBindings;
    assert(items.length * longDesc.length > 2048,
        "the fixture must be big enough to force a grow");

    LabelArena arena;
    Builder b;
    BoxLayout layout;
    const root = viewLantern(b, arena, items, 0, 120, layout);
    auto tree = b.finish(root);

    const shown = layout.capacity < cast(int) items.length
        ? layout.capacity : cast(int) items.length;

    // The two ends of the arena are what matter: the first label was written
    // before any grow, the last after every one of them. If a slice went
    // stale, it is the early ones that point into the freed block.
    bool sawFirst, sawLastShown;
    size_t texts;
    foreach (ref w; tree.nodes)
    {
        if (w.kind != WidgetKind.text)
            continue;
        ++texts;
        assert(w.text.length > 0, "a blank cell reads as an unbound key");
        // A prefix node renders marked, so compare against the tail — the
        // part that came from the binding rather than from the panel.
        if (w.text.length >= items[0].desc.length
            && w.text[$ - items[0].desc.length .. $] == items[0].desc)
            sawFirst = true;
        const last = items[shown - 1].desc;
        if (w.text.length >= last.length && w.text[$ - last.length .. $] == last)
            sawLastShown = true;
    }
    assert(texts >= shown * 2, "a key and a label per shown item");
    assert(sawFirst, "the label written before every grow must survive");
    assert(sawLastShown, "…and so must the one written after them");

    // Scrolling reaches the rest. The panel showing fewer rows than the set
    // has is fine; the panel making the remainder unreachable is not.
    if (layout.capacity < cast(int) items.length)
    {
        Builder b2;
        LabelArena arena2;
        BoxLayout l2;
        const r2 = viewLantern(b2, arena2, items, 0, 120, l2,
            Placement.classic, LanternStyle.init, 0, cast(int) items.length);
        auto t2 = b2.finish(r2);
        bool sawLast;
        foreach (ref w; t2.nodes)
            if (w.kind == WidgetKind.text
                && w.text == items[items.length - 1].desc)
                sawLast = true;
        assert(sawLast, "the last binding must be reachable by scrolling");
    }
}

@("ui.lantern_view.columnsDoNotOverlap")
@safe
unittest
{
    import sparkles.ui.layout : layout;

    // Found by looking at the thing: the first panel painted every column at
    // the same origin, so eight bindings rendered as one unreadable smear.
    // Overlap is invisible to every test that only asks what the labels SAY,
    // which is why this one asks where they LAND.
    LabelArena arena;
    Builder b;
    BoxLayout box;
    const root = viewLantern(b, arena, manyBindings, 0, 400, box);
    auto tree = b.finish(root);
    auto frames = layout(tree);
    assert(box.boxes > 1, "the fixture must be wide enough to have columns");

    // An item cell is a row of exactly three TEXT leaves. Checking only the
    // child count would also match a final row that happens to hold three
    // cells, which reads as an overlap against its own children.
    bool isCell(size_t idx)
    {
        const w = tree.nodes[idx];
        if (w.kind != WidgetKind.row || w.children.length != 3)
            return false;
        foreach (c; w.children)
            if (tree.nodes[c].kind != WidgetKind.text)
                return false;
        return true;
    }

    foreach (i, ref w; tree.nodes)
    {
        if (!isCell(i))
            continue;
        const r = frames[i].rect;
        assert(r.width > 0, "a zero-width cell paints on top of its neighbour");
        foreach (j, ref v; tree.nodes)
        {
            if (j <= i || !isCell(j))
                continue;
            const s = frames[j].rect;
            if (r.y != s.y)
                continue; // different rows may share an x
            assert(r.x + r.width <= s.x || s.x + s.width <= r.x,
                "two cells on one row must not overlap");
        }
    }
}

@("ui.lantern_view.groupsAreMarkedAndCommandsAreNot")
@safe
unittest
{
    LabelArena arena;
    Builder b;
    BoxLayout layout;
    const root = viewLantern(b, arena, manyBindings, 0, 120, layout);
    auto tree = b.finish(root);

    // A prefix's label carries the `+` that tells a reader more keys follow —
    // the one thing distinguishing "this runs something" from "this opens a
    // menu" before you press it.
    bool sawGroup, sawPlain;
    foreach (ref w; tree.nodes)
    {
        if (w.kind != WidgetKind.text || w.text.length == 0)
            continue;
        if (w.text[0] == '+')
            sawGroup = true;
        else if (w.text == "search")
            sawPlain = true;
    }
    assert(sawGroup, "a prefix node must be marked");
    assert(sawPlain, "…and a command must not be");
}
