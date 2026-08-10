/**
The Terminal page: real shells inside the catalog — the `TVW7` embedding
proof, VSCode-shaped.

A pane beside a $(B vertical) list of terminals (a horizontal strip overflows
by the third tab; VSCode's panel lists them on the right for the same
reason), a button (and `n`) to spawn more, and the pane itself $(B laid out
like any other widget) — the actual cells arrive in the component's draw
phase, which finds the pane's rect by its key. The page stays a pure view
over state: spawning a pty is a side effect no page is allowed, so the page
raises request flags and the shell's frame glue performs them.

Widths are state-computed `fixed` values, like every page's: inside the
shell's scroll viewport a child lays out at its $(B natural) width, so a
`grow` pane collapses to the widest label beside it — the catalog found
that one live, as a terminal that refused to widen with its window.

Keyboard capture is the page's one inversion: with a terminal $(B focused),
every key belongs to the shell inside it — `q`, `Tab`, arrows, `Ctrl+C` —
and the gallery keeps only the release chord and the scrollback keys
(`Shift+PgUp`/`Shift+PgDn`, the emulator convention). That routing lives in
`gallery.d`; here it is only displayed.
*/
module pages.terminal_page;

import std.conv : text, to;

import sparkles.base.text.width : truncateField;
import sparkles.input : Key, KeyEvent, PointerEvent;
import sparkles.ui.components.chrome : actionBar;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;

import kit;
import scrollbars;
import state : GalleryState, hitTerminal, hitTermActions, hitTermBar,
    keyTermPane, maxTerms;

@safe:

/// ditto
static immutable string[] keys = [
    "n new", "x close", "h/l tab", "⏎ focus", "⇧PgUp history", "ctrl+] leave",
];

/// The pane's own hit id. Tab lanes start at `+ 2` (ids start at 1), so the
/// `+ 0` slot is the pane's alone.
enum size_t hitPane = hitTerminal;

/// A tab's select lane: pressing it activates the tab. Unbounded upward —
/// `hitTerminal` is the last base for exactly this reason.
size_t tabHit(uint id) @safe pure nothrow @nogc => hitTerminal + 2 * id;

/// A tab's close lane — the hover ✕.
size_t closeHit(uint id) @safe pure nothrow @nogc => tabHit(id) + 1;

/// Whether `id` is this page's own chrome — the shell keeps a focused
/// terminal's capture across presses on these, and drops it for anything else.
bool ownsId(size_t id) @safe pure nothrow @nogc
    => (id >= hitTermActions && id < hitTermActions + 3)
    || id == hitTermBar || id >= hitTerminal;

/// The chrome rows the page spends beyond the pane: heading, spacer, action
/// bar, spacer, status line.
private enum int chromeRows = 6;

/// The full tab table's width, borders included.
private enum int listWidth = 18;

/// The label cells inside the table: width less the border pair, the padding
/// pair, and the always-reserved ✕ column with its gap — reserved so a label
/// does not reflow the moment the pointer reveals the close button.
private enum int labelCells = listWidth - 2 - 2 - 2;

/// Content width thresholds: the full table above, the one-cell numeric mini
/// list below — the list only vanishes when even one cell would starve the
/// pane (the defect this replaces: it vanished with cells to spare).
private enum int listMinContent = 48;
/// ditto
private enum int miniMinContent = 24;

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;

    uint[] body_;
    body_ ~= heading(b, "Terminal · a shell as a widget");
    body_ ~= spacer(b);

    body_ ~= actionBar(b, [
        "+ new",
        "✕ close",
        s.terms.keepExited ? "hold: all" : "hold: fail",
    ], hitTermActions, s.press);
    body_ ~= spacer(b);

    const paneRows = paneHeight(s);
    if (s.terms.any)
    {
        // The pane, its scrollback bar, and the terminal list — explicit
        // widths that sum to the pane's (see the module header for why
        // `grow` cannot do this here). The bar column is always reserved,
        // like the shell's own gutter: content that reflowed sideways the
        // moment history crossed the viewport would be worse than one
        // blank column.
        const listW = w >= listMinContent ? listWidth
            : w >= miniMinContent ? 1 : 0;
        const groupW = w - listW;
        const paneW = groupW - 2 - gutterCells;

        // The terminal and its scrollback bar are ONE instrument, so one
        // border wraps the pair — which also aligns the bar's track with the
        // cell grid it scrolls (a bar beside a self-bordered pane overhung it
        // by the border row at each end). The keyed pane box is borderless:
        // its rect IS the cell grid, no inset.
        uint[] across;
        const paneBox = b.add(Widget(
            kind: WidgetKind.box,
            key: keyTermPane,
            hitId: hitPane,
            width: SizeSpec.fixed(paneW),
            height: SizeSpec.fixed(paneRows - 2),
        ));
        // The scrollback bar: the same living bar as every other in the
        // catalog — grabbable, capture-arbitrated, hover-expanding — over
        // the terminal's own numbers. The machine's offset is reconciled
        // with ghostty's each frame by the shell.
        const bar = verticalBar(b, s.termView, termBarGeometry(s), hitTermBar);
        across ~= b.add(Widget(
            kind: WidgetKind.row,
            children: [paneBox, bar],
            width: SizeSpec.fixed(groupW),
            height: SizeSpec.fixed(paneRows),
            padding: intoAll(1),
            decoration: Decoration(borderWidth: intoAll(1),
                borderStyle: BorderStyle.solid,
                borderSlot: s.terms.focused ? Slot.chromeFocused : Slot.border),
        ));
        if (listW == listWidth)
            across ~= termTable(b, s, paneRows);
        else if (listW == 1)
            across ~= termMini(b, s, paneRows);

        body_ ~= b.add(Widget(
            kind: WidgetKind.row,
            children: across,
            width: SizeSpec.fixed(w),
            height: SizeSpec.fixed(paneRows),
        ));
        // The grid size leads the status line, as emulators do on resize.
        body_ ~= label(b, text(s.terms.paneCols, "×", s.terms.paneRows, " · ",
            s.terms.focused
            ? "the shell has the keyboard — ctrl+] (or ctrl+`) gives it back"
            : "⏎ or click the pane to type into the shell"), Slot.muted);
    }
    else
    {
        // The section panel pads two cells a side; the paragraphs wrap inside.
        const inner = w > 14 ? w - 6 : 8;
        body_ ~= section(b, "no terminal yet", [
            para(b, "Press n (or + new) to spawn your shell on a pty. The "
                ~ "emulator is sparkles:terminal-view — libghostty under a "
                ~ "component — and this pane is its first embedding: sized by "
                ~ "layout, painted through the host's draw phase, keyed like "
                ~ "any other widget.", inner),
            spacer(b),
            para(b, "The keyboard is complete, including Ctrl chords; the "
                ~ "wheel and Shift+PgUp/PgDn walk the scrollback. Mouse "
                ~ "inside the pane (selection, links) waits on the "
                ~ "mouse-event conversion.", inner),
        ]);
    }

    return column(b, body_);
}

/// What the scrollback bar scrolls over: the terminal's own numbers, mirrored
/// into state by the frame glue (a pure page cannot ask the instance), the
/// track being the pane's height.
BarGeometry termBarGeometry(in GalleryState s)
    => BarGeometry(
        content: s.terms.sbTotal,
        viewport: s.terms.sbLen,
        track: paneHeight(s) - 2, // inside the group's border
    );

/**
The scrollback bar's pointer handling — grab, track jump, drag — through the
same machine as every bar in the catalog. The machine moves `s.termView`; the
shell's frame glue turns that intent into a ghostty viewport delta, because
the terminal owns the real offset.
*/
bool handlePointer(ref GalleryState s, in PointerEvent p, in WidgetTree tree,
    in Frame[] frames)
    => driveVertical(s.termView, s.capture, capTermBar, p,
        rectOf(tree, frames, hitTermBar), termBarGeometry(s));

/// Eases the bar's hover-expand width. The shell owns the clock.
void step(ref GalleryState s, int dtMs)
{
    easeVertical(s.termView, s.caps, dtMs / 1000.0f);
}

/**
The tab table, full mode: an outer border, an inner rule between rows, and a
row background distinct from the page (the `chip`/`selection`/`chromeFocused`
washes composite over the theme's own background, so every theme keeps its
cast — `surface` would not). Selection is background + bold, not a marker
glyph: the nav sidebar's "▸" survives a colourless terminal, but this list
trades that for the row reading as one object, by explicit request.

Whether a row is hot considers $(B both) of its lanes — the ✕ sits inside the
row, and hovering it must not un-hover the row it closes.
*/
private uint termTable(ref Builder b, in GalleryState s, int paneRows)
{
    // The rows sit ADJACENT — a cell-tall separator reads as a gap, not a
    // rule, on the GPU arm's hairline metrics. Zebra washes divide them
    // instead, the same on both arms.
    uint[] rows;
    foreach (i; 0 .. s.terms.count)
        rows ~= termRow(b, s, i);
    const inner = b.add(Widget(
        kind: WidgetKind.column,
        children: rows,
        width: SizeSpec.grow(),
    ));
    return b.add(Widget(
        kind: WidgetKind.column,
        children: [inner],
        width: SizeSpec.fixed(listWidth),
        height: SizeSpec.fixed(paneRows),
        clipX: true,
        clipY: true,
        padding: intoSymmetric(1, 1),
        decoration: Decoration(borderWidth: intoAll(1),
            borderStyle: BorderStyle.solid, borderSlot: Slot.border),
    ));
}

/// One tab row: a grapheme-safe truncated label, a filler so the background
/// spans the table, and the ✕ column — reserved always, revealed on hover.
private uint termRow(ref Builder b, in GalleryState s, size_t i)
{
    const t = s.terms.tabs[i];
    const active = i == s.terms.active;
    const hot = s.pointerAffordances
        && (s.hover.isHot(tabHit(t.id)) || s.hover.isHot(closeHit(t.id)));

    const caption = truncateField(
        t.labelText.idup ~ (t.exited ? text(" (", t.exitStatus, ")") : ""),
        labelCells);
    uint[] children;
    children ~= b.add(Widget(
        kind: WidgetKind.text,
        text: caption,
        slot: active ? Slot.chromeAccent : t.exited ? Slot.muted : Slot.chrome,
        textStyle: TextStyle(bold: active),
    ));
    children ~= b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    if (hot)
        children ~= b.add(Widget(
            kind: WidgetKind.text,
            text: "✕",
            hitId: closeHit(t.id),
            slot: Slot.error,
        ));
    else
        children ~= b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(1)));

    return b.add(Widget(
        kind: WidgetKind.row,
        children: children,
        width: SizeSpec.grow(),
        hitId: tabHit(t.id),
        paintBackground: true,
        // Adjacent rows divide by wash: zebra when idle, selection under the
        // pointer, the accent wash + bold for the active tab.
        slot: active ? Slot.chromeFocused : hot ? Slot.selection
            : (i % 2 == 1 ? Slot.chrome : Slot.chip),
        gap: 1,
    ));
}

/**
The one-cell mini list: each tab is a position glyph whose cell $(B becomes)
the close button on hover — the node's hit id follows its face, so a click
does exactly what the glyph shows. Selection here is keyboard-only (`h`/`l`),
by explicit request.
*/
private uint termMini(ref Builder b, in GalleryState s, int paneRows)
{
    uint[] rows;
    foreach (i; 0 .. s.terms.count)
    {
        const t = s.terms.tabs[i];
        const active = i == s.terms.active;
        const hot = s.pointerAffordances
            && (s.hover.isHot(tabHit(t.id)) || s.hover.isHot(closeHit(t.id)));
        rows ~= b.add(Widget(
            kind: WidgetKind.text,
            text: hot ? "✕" : positionGlyph(s, i + 1),
            hitId: hot ? closeHit(t.id) : tabHit(t.id),
            paintBackground: true,
            slot: active ? Slot.chromeFocused : hot ? Slot.selection : Slot.chip,
            textStyle: TextStyle(bold: active),
        ));
    }
    return b.add(Widget(
        kind: WidgetKind.column,
        children: rows,
        width: SizeSpec.fixed(1),
        height: SizeSpec.fixed(paneRows),
        clipY: true,
    ));
}

/**
Position `n`'s mini-list glyph: the `--term-tab-glyphs` override's n-th code
point when one exists, else the circled-number series, else ASCII digits when
the theme forgoes unicode.
*/
string positionGlyph(in GalleryState s, size_t n)
{
    if (s.termTabGlyphs.length)
    {
        import std.utf : stride;

        size_t i = 0, pos = 1;
        while (i < s.termTabGlyphs.length)
        {
            const len = stride(s.termTabGlyphs, i);
            if (pos == n)
                return s.termTabGlyphs[i .. i + len].idup; // dip1000: `s` is scope
            i += len;
            pos++;
        }
        // An override shorter than the tab count falls through to the default.
    }
    if (!s.theme.glyphs.unicode)
        return n <= 9 ? [cast(char)('0' + n)].idup : "#";
    return circledNumber(n).to!string;
}

/**
The circled-number series: ⓪, ①–⑳, ㉑–㉟, ㊱–㊿ — three Unicode runs that
LOOK contiguous and are not.

Width caveat, stated once: ⓪–⑳ are East-Asian-$(B Ambiguous) — one cell under
this repository's rule (and most terminals') — but ㉑–㊿ are East-Asian-$(B
Wide), two cells. Positions past 20 are unreachable while `maxTerms` is 8; a
cap past 20 must widen the mini column or fall back to ASCII there.
*/
dchar circledNumber(size_t n) @safe pure nothrow @nogc
{
    if (n == 0)
        return '⓪';
    if (n <= 20)
        return cast(dchar)(0x2460 + n - 1);
    if (n <= 35)
        return cast(dchar)(0x3251 + n - 21);
    if (n <= 50)
        return cast(dchar)(0x32B1 + n - 36);
    return '#';
}

/// The pane's height: whatever the content pane has, less this page's own
/// chrome — clamped so a hostile surface still lays out.
int paneHeight(in GalleryState s)
{
    const h = s.contentHeight - chromeRows;
    return h > 2 ? h : 2;
}

private auto intoAll(int n) pure nothrow @nogc
{
    import sparkles.ui.geometry : Insets;

    return Insets.all(n);
}

private auto intoSymmetric(int v, int h) pure nothrow @nogc
{
    import sparkles.ui.geometry : Insets;

    return Insets.symmetric(v, h);
}


/// ditto — offered keys only while the keyboard is in the content region and
/// no terminal is focused (capture is intercepted upstream in `gallery.d`).
bool handleKey(ref GalleryState s, in KeyEvent k)
{
    if (k.ch == 'n')
    {
        if (!s.terms.full)
            s.terms.spawnRequested = true;
        return true;
    }
    if (k.ch == 'x')
    {
        if (s.terms.any)
            s.terms.closeRequested = cast(int) s.terms.active;
        return true;
    }
    if (k.ch == 'h')
    {
        s.terms.cycle(-1);
        return true;
    }
    if (k.ch == 'l')
    {
        s.terms.cycle(1);
        return true;
    }
    if (k.ch == 'e')
    {
        s.terms.keepExited = !s.terms.keepExited;
        return true;
    }
    if (k.key == Key.enter && s.terms.any)
    {
        s.terms.focused = true;
        return true;
    }
    return false;
}

/// ditto
bool handleActivate(ref GalleryState s, size_t id)
{
    if (id == hitPane)
    {
        if (s.terms.any)
            s.terms.focused = true;
        return true;
    }
    if (id > hitTerminal)
    {
        // A tab lane, by identity: even offset selects, odd closes. The find
        // is by minted id, so a press resolved against last frame's tree
        // lands on the same tab after a neighbour closed.
        const offset = id - hitTerminal;
        const tabId = offset / 2;
        const isClose = (offset & 1) == 1;
        foreach (i; 0 .. s.terms.count)
            if (s.terms.tabs[i].id == tabId)
            {
                if (isClose)
                    s.terms.closeRequested = cast(int) i;
                else
                    s.terms.active = i;
                return true;
            }
        return true; // one of ours, even if the tab just closed under it
    }
    if (id == hitTermActions + 0)
    {
        if (!s.terms.full)
            s.terms.spawnRequested = true;
        return true;
    }
    if (id == hitTermActions + 1)
    {
        if (s.terms.any)
            s.terms.closeRequested = cast(int) s.terms.active;
        return true;
    }
    if (id == hitTermActions + 2)
    {
        s.terms.keepExited = !s.terms.keepExited;
        return true;
    }
    return false;
}

@("ui_gallery.pages.terminalKeysDriveTheModel")
@safe unittest
{
    GalleryState s;

    // `n` requests a spawn; the request is a flag, not a pty — pages are
    // pure views and the shell's frame glue owns the side effect.
    assert(handleKey(s, KeyEvent(Key.char_, 'n')));
    assert(s.terms.spawnRequested);

    // With tabs present, h/l cycle, x aims a close at the active slot, and
    // Enter hands the keyboard to the shell in the pane.
    s.terms.spawnRequested = false;
    cast(void) s.terms.spawn();
    cast(void) s.terms.spawn();
    assert(handleKey(s, KeyEvent(Key.char_, 'h')));
    assert(s.terms.active == 0);
    assert(handleKey(s, KeyEvent(Key.char_, 'x')));
    assert(s.terms.closeRequested == 0);
    assert(handleKey(s, KeyEvent(Key.enter)));
    assert(s.terms.focused);

    assert(handleKey(s, KeyEvent(Key.char_, 'e')));
    assert(s.terms.keepExited);

    assert(!handleKey(s, KeyEvent(Key.char_, 'z')), "unclaimed keys fall through");
}

@("ui_gallery.pages.terminalActivationMapsLanesByIdentity")
@safe unittest
{
    GalleryState s;
    const id1 = s.terms.spawn();
    const id2 = s.terms.spawn();
    cast(void) id1;

    // Closing the first tab must not redirect a press aimed at the second:
    // the hit id carries the identity, not the slot.
    s.terms.close(0);
    assert(handleActivate(s, tabHit(id2)));
    assert(s.terms.tabs[s.terms.active].id == id2);

    // The close lane aims at the same tab's slot.
    assert(handleActivate(s, closeHit(id2)));
    assert(s.terms.closeRequested == cast(int) s.terms.active);
    s.terms.closeRequested = -1;

    // The action bar: spawn, close, and the hold toggle.
    assert(handleActivate(s, hitTermActions + 0));
    assert(s.terms.spawnRequested);
    assert(handleActivate(s, hitTermActions + 1));
    assert(s.terms.closeRequested == cast(int) s.terms.active);
    assert(handleActivate(s, hitTermActions + 2));
    assert(s.terms.keepExited);

    // The pane focuses; foreign ids fall through.
    assert(handleActivate(s, hitPane));
    assert(s.terms.focused);
    assert(!handleActivate(s, 1));
}

@("ui_gallery.pages.terminalHitLanesNeverCollide")
@safe pure nothrow @nogc unittest
{
    // Two unbounded id streams from one base: they must interleave without
    // touching each other, the pane, or the action bar — for ANY minted id,
    // not just the first eight (ids are never reused, so they grow forever;
    // the old single-lane layout collided with the actions at id 100).
    foreach (id; 1 .. 201)
    {
        const t = tabHit(cast(uint) id);
        const c = closeHit(cast(uint) id);
        assert(t != c);
        assert(t > hitPane && c > hitPane);
        assert(t >= hitTermActions + 3 && c >= hitTermActions + 3);
        assert(ownsId(t) && ownsId(c));
    }
    assert(ownsId(hitPane) && ownsId(hitTermActions));
    assert(!ownsId(0) && !ownsId(1));
}

@("ui_gallery.pages.terminalLabelsTruncateByCellsNotBytes")
@safe unittest
{
    import std.utf : validate;
    import sparkles.base.text.grapheme : visibleWidth;
    import sparkles.ui.geometry : Constraints, Size;
    import sparkles.ui.layout : layout;

    // The defect this pins: the old list sliced the caption at a BYTE count,
    // so a multibyte title lost extra characters — and could be cut mid
    // code point, poisoning the tree with invalid UTF-8.
    GalleryState s;
    s.surface = Size(100, 30);
    cast(void) s.terms.spawn();
    s.terms.tabs[0].setLabel("héllo wörld ünïcodé täb");

    auto b = Builder();
    auto tree = b.finish(view(b, s));
    cast(void) layout(tree, Constraints(maxW: s.contentWidth));

    bool found;
    foreach (ref n; tree.nodes)
        if (n.kind == WidgetKind.text && n.text.length > 4
            && n.text[$ - 3 .. $] == "…")
        {
            validate(n.text);
            assert(visibleWidth(n.text) <= labelCells,
                "a caption wider than its column");
            found = true;
        }
    assert(found, "the long label must render truncated with an ellipsis");
}

@("ui_gallery.pages.terminalMiniModeAppearsBelowTheBreakpoint")
@safe unittest
{
    import sparkles.ui.geometry : Constraints, Size;
    import sparkles.ui.layout : layout;

    static bool hasText(in GalleryState s, string wanted)
    {
        auto b = Builder();
        // The sweep's shape: build + layout, then walk the nodes. The state
        // is passed straight through rather than copied — `view` takes it
        // `in`, and a copy here would only ask whether the whole state is
        // copyable, which is not what this test is about.
        auto tree = b.finish(view(b, s));
        cast(void) layout(tree, Constraints(maxW: s.contentWidth));
        foreach (ref n; tree.nodes)
            if (n.kind == WidgetKind.text && n.text == wanted)
                return true;
        return false;
    }

    GalleryState s;
    cast(void) s.terms.spawn();
    cast(void) s.terms.spawn();

    // Wide: the full table shows labels, no numeric cells.
    s.surface = Size(100, 30);
    assert(!hasText(s, "①"));

    // Narrow: the mini list replaces it — position glyphs, not labels.
    s.surface = Size(45, 24);
    assert(hasText(s, "①") && hasText(s, "②"));

    // The override wins, one code point per position.
    s.termTabGlyphs = "ab";
    assert(hasText(s, "a") && hasText(s, "b"));
}

@("ui_gallery.pages.terminalScrollbackBarIsGrabbable")
@safe unittest
{
    import sparkles.input : PointerAction, PointerButton;
    import sparkles.ui.geometry : Constraints, Point, Size;
    import sparkles.ui.layout : layout;

    // The bar is the same living machine as every other in the catalog: a
    // press on its track jumps the offset. Ghostty's numbers arrive via the
    // frame glue's mirror; the test sets them as the mirror would.
    GalleryState s;
    s.surface = Size(100, 30);
    cast(void) s.terms.spawn();
    s.terms.sbTotal = 200;
    s.terms.sbLen = 15;
    s.terms.sbOffset = 185; // pinned at the bottom, as a live shell is
    s.termView.v = s.termView.v.scrolledTo(185);

    auto b = Builder();
    auto tree = b.finish(view(b, s));
    auto frames = layout(tree, Constraints(maxW: s.contentWidth));
    const bar = rectOf(tree, frames, hitTermBar);
    assert(bar.width > 0, "the bar must be laid out and hit-testable");

    // Press near the top of the track: the thumb's leading edge jumps there.
    const p = PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(bar.x + bar.width / 2, bar.y));
    assert(handlePointer(s, p, tree, frames));
    assert(s.termView.v.offset < 185, "the grab moved the machine");
}

@("ui_gallery.pages.terminalCircledNumberRangeSeams")
@safe pure nothrow @nogc unittest
{
    // Three Unicode runs that look contiguous and are not — each seam pinned.
    assert(circledNumber(0) == '⓪');
    assert(circledNumber(1) == '①');
    assert(circledNumber(20) == '⑳');
    assert(circledNumber(21) == '㉑');
    assert(circledNumber(35) == '㉟');
    assert(circledNumber(36) == '㊱');
    assert(circledNumber(50) == '㊿');
    assert(circledNumber(51) == '#');
}

@("ui_gallery.pages.terminalPaneFollowsTheSurfaceWidth")
@safe unittest
{
    import sparkles.ui.geometry : Constraints, Size;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : keyedRects;
    import state : keyTermPane;

    // The live defect this pins: inside the shell's scroll viewport a child
    // lays out at its NATURAL width, so a `grow` pane collapsed to the
    // widest label beside it and a widened window left the terminal at its
    // spawn width. The pane's width is a state-computed fixed value now,
    // and it must track the surface.
    int paneWidthAt(int surface)
    {
        GalleryState s;
        s.surface = Size(surface, 30);
        cast(void) s.terms.spawn();
        auto b = Builder();
        auto tree = b.finish(view(b, s));
        // The page subtree alone, at its natural width — the scroll
        // viewport's situation, which is where the collapse happened.
        auto frames = layout(tree, Constraints(maxW: s.contentWidth));
        foreach (kr; keyedRects(tree, frames))
            if (kr.key == keyTermPane)
                return kr.rect.width;
        assert(0, "the pane lost its key");
    }

    const at90 = paneWidthAt(90);
    const at130 = paneWidthAt(130);
    assert(at130 > at90 + 30, "the pane must widen with the surface");
}
