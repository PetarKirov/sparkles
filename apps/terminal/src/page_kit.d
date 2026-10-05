/**
What the terminal's pages share (docs/specs/terminal/pages.md, design.md): a
page is a `surfaces.Surface` placed over the whole pane area, with a header
(back, title, actions), an optional search field, and a body that scrolls.

$(LIST
    * $(LREF Page) — the base: the header's back button, scrolling by key
        (arrows, PgUp/PgDn, Home/End) and by the wheel (which arrives as
        arrows), and the search field's editing (`/` focuses it, typing fills
        it, Esc or Enter leaves it). The keyboard contract is `Surface.key`'s:
        a page declines Ctrl/Alt/Super chords (the leader stays the
        terminal's), and declines `q`, Esc and Enter while no field is
        focused, so the overlay rows close and confirm it (`KBD1`).
    * $(LREF PageServices) — what a page may ask of the application: the
        clipboard, the share sheet, opening a link, a toast, a pane.
    * Pieces: $(LREF header), $(LREF chip), $(LREF searchField),
        $(LREF scrolled) and $(LREF viewportRows).
)
*/
module page_kit;

import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.geometry : Constraints, Insets, Point, Rect, SizeSpec;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.style : Decoration, FontRole, Slot, TextStyle, TypeStep;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

import chrome : button;
import settings : ButtonLabels;
import surfaces : Placement, Surface, SurfaceContext;

/// What a page may ask of the application. Every member may be null: the
/// page then leaves the action out.
struct PageServices
{
    /// Put `text` on the clipboard.
    void delegate(string text) copy;
    /// Hand `text` to the platform's share sheet (Android `ACTION_SEND`).
    void delegate(string text) share;
    /// Open `uri` — only a scheme the link allow-list admits (`TPR6`).
    void delegate(string uri) openUri;
    /// Show a toast.
    void delegate(string text) toast;
    /// Select pane `id`'s tab and focus it; false when it has closed.
    bool delegate(ulong id) focusPane;
    /// Whether pane `id` is still open.
    bool delegate(ulong id) paneOpen;
    /// The page changed without input (the log's tail): paint the next frame.
    void delegate() @safe repaint;
}

/// The hit ids every page shares; a page's own start at $(LREF firstOwnHit).
enum PageHit : size_t
{
    none,
    back = 0x9A6E_0001,
    search,
}

/// ditto
enum size_t firstOwnHit = 0x9A6E_0100;

/**
The base of every page: header, scrolling, search editing. A page builds its
body in `buildPage`, answers its own hits in `onHit` and its own keys in
`onKey`.
*/
abstract class Page : Surface
{
    protected PageServices services;
    /// The first body row shown, in cells (`scrolled` clamps it).
    protected int scroll;
    /// The search text, and whether the field has the keyboard.
    protected string query;
    /// ditto
    protected bool searching;
    /// The body's height in rows, as the last build laid it out.
    protected int viewRows = 10;

    /// The body's height in rows, as the last build laid it out.
    final int bodyRows() const @safe pure nothrow @nogc => viewRows;

    this(PageServices services) @safe pure nothrow @nogc
    {
        this.services = services;
    }

    /// The page's tree, at most `cols` wide and the area's height tall.
    abstract WidgetTree buildPage(in SurfaceContext ctx, int cols, int rows) @safe;
    /// A hit on one of the page's own ids; true when the page is done.
    abstract bool onHit(size_t id) @system;
    /// A key the base did not take (no field focused); true when used.
    bool onKey(in KeyEvent k) @system => false;
    /// Whether the page has a search field (`/` focuses it).
    bool hasSearch() const @safe pure nothrow @nogc => false;
    /// The search text changed.
    void queryChanged() @safe {}
    /// The body scrolled by `rows` (positive: down, towards the end).
    void scrolled(int rows) @safe
    {
        scroll += rows;
        if (scroll < 0)
            scroll = 0;
    }

    final WidgetTree build(in SurfaceContext ctx, int cols) @safe
        => buildPage(ctx, cols, ctx.cellH > 0 ? ctx.area.height / ctx.cellH : 24);

    Placement placement() const @safe => Placement.page;

    final bool activate(size_t id) @system
    {
        switch (id)
        {
            case PageHit.back:
                return true;
            case PageHit.search:
                searching = true;
                return false;
            default:
                searching = false;
                return onHit(id);
        }
    }

    bool confirm() @system => false;
    void cancel() @system {}

    /// `Surface.key`: see the module's keyboard contract.
    final bool key(in KeyEvent k) @system
    {
        import sparkles.input.events : KeyAction;

        if (k.action == KeyAction.release || k.mods.ctrl || k.mods.alt || k.mods.super_)
            return false;
        if (searching)
            return editQuery(k);
        switch (k.key)
        {
            case Key.up:
                scrolled(-1);
                return true;
            case Key.down:
                scrolled(1);
                return true;
            case Key.pageUp:
                scrolled(-(viewRows > 2 ? viewRows - 1 : 1));
                return true;
            case Key.pageDown:
                scrolled(viewRows > 2 ? viewRows - 1 : 1);
                return true;
            case Key.home:
                scrolled(-int.max / 2);
                return true;
            case Key.end:
                scrolled(int.max / 2);
                return true;
            case Key.char_:
                if (k.ch == '/' && hasSearch)
                {
                    searching = true;
                    return true;
                }
                return onKey(k);
            default:
                return onKey(k);
        }
    }

    /// Typing into the focused field: text, Backspace; Esc and Enter leave it.
    private bool editQuery(in KeyEvent k) @safe
    {
        switch (k.key)
        {
            case Key.escape:
            case Key.enter:
            case Key.back:
                searching = false;
                return true;
            case Key.backspace:
                if (query.length)
                {
                    size_t n = query.length - 1;
                    while (n > 0 && (query[n] & 0xC0) == 0x80)
                        n--;
                    query = query[0 .. n];
                    queryChanged();
                }
                return true;
            case Key.char_:
                const t = k.text.length ? k.text.idup : encodeChar(k.ch);
                if (t.length)
                {
                    query ~= t;
                    queryChanged();
                }
                return true;
            default:
                return false;
        }
    }

    /// Lets a test or an embedder put text in the field.
    final void setQuery(string q) @safe
    {
        query = q;
        queryChanged();
    }
}

/// `c` as UTF-8; empty for a control character or an invalid code point.
private string encodeChar(dchar c) @safe pure nothrow
{
    import std.utf : encode, isValidDchar;

    if (c < 0x20 || c == 0x7F || !isValidDchar(c))
        return null;
    char[4] buf;
    const n = (() @trusted {
        try
            return encode(buf, c);
        catch (Exception)
            return 0;
    })();
    return buf[0 .. n].idup;
}

// ─────────────────────────────────────────────────────────────────────────────
// Pieces.
// ─────────────────────────────────────────────────────────────────────────────

/**
The header band (mockups C1, LG1, N2): Back, the title, then `actions` at the
right — each a button made by the caller.
*/
uint header(ref Builder b, string title, in SurfaceContext ctx, uint[] actions = null) @safe
{
    const back = button(b, "←", "Back", ButtonLabels.icon, PageHit.back,
        minRows: ctx.targetRows);
    const name = b.add(Widget(kind: WidgetKind.text, text: title, slot: Slot.textPrimary,
        textStyle: TextStyle(bold: true, fontRole: FontRole.ui, typeStep: TypeStep.title)));
    const spacer = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    return b.add(Widget(
        kind: WidgetKind.row,
        children: [back, name, spacer] ~ actions,
        gap: 1,
        alignY: Alignment.center,
        width: SizeSpec.grow(),
        padding: Insets(0, 1, 0, 0),
        slot: Slot.surfaceSunken,
        paintBackground: true,
    ));
}

/**
A toggle chip: `✓ label` on, `○ label` off — the mark, not the colour alone,
says which (`ACC3`). `hitId` makes it a target; `rows` its height (`TOK7`),
while the chip is drawn 32 dp tall in it (`TOK11`). The label is a name, in the
interface face.
*/
uint chip(ref Builder b, string label, bool on, size_t hitId, int rows = 1) @safe
{
    // On: the selection's fill under primary text — accent-coloured text on
    // a grey mix read poorly on the tablet.
    const text = b.add(Widget(kind: WidgetKind.text, text: (on ? "✓ " : "○ ") ~ label,
        slot: Slot.textPrimary,
        textStyle: TextStyle(bold: on, fontRole: FontRole.ui, typeStep: TypeStep.label)));
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [text],
        padding: Insets(0, 1, 0, 1),
        height: rows > 1 ? SizeSpec.fixed(rows) : SizeSpec.fit_,
        alignY: Alignment.center,
        hitId: hitId,
        slot: on ? Slot.selection : Slot.surfaceRaised,
        paintBackground: true,
        decoration: Decoration(borderRadius: 16, drawHeight: 32),
    ));
}

/**
The search field on its own row (`TPG8`): the query and a caret while it has
the keyboard, else the query, else `placeholder` — muted.
*/
uint searchField(ref Builder b, string query, bool focused, string placeholder,
    int rows = 1) @safe
{
    const shown = query.length ? "⌕ " ~ query ~ (focused ? "▏" : "")
        : focused ? "⌕ ▏" : "⌕ " ~ placeholder;
    // The placeholder is a sentence; what the user types stays in the cell
    // font, as any typed value does.
    const typed = query.length || focused;
    const text = b.add(Widget(kind: WidgetKind.text, text: shown,
        slot: typed ? Slot.textPrimary : Slot.muted,
        textStyle: typed ? TextStyle.init : TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.body)));
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [text],
        padding: Insets(0, 1, 0, 1),
        width: SizeSpec.grow(),
        height: rows > 1 ? SizeSpec.fixed(rows) : SizeSpec.fit_,
        alignY: Alignment.center,
        hitId: PageHit.search,
        slot: focused ? Slot.surfaceSunken : Slot.surfaceRaised,
        paintBackground: true,
        decoration: Decoration(borderRadius: 6),
    ));
}

/**
A sentence or a paragraph, in the interface face (design-system `GLY10`),
wrapping to the room it is given. A value, a path or a log line is a
$(LREF codeText) instead.
*/
uint prose(ref Builder b, const(char)[] text, Slot slot = Slot.textPrimary,
    bool bold = false) @safe
    => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot,
        textStyle: TextStyle(bold: bold, fontRole: FontRole.ui, typeStep: TypeStep.body),
        wrap: TextWrap.greedy));

/// A value, a path or a log line, in the cell font, wrapping to the room it
/// is given.
uint codeText(ref Builder b, const(char)[] text, Slot slot = Slot.code) @safe
    => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot, wrap: TextWrap.greedy));

/// A column of `children` (the page: header, controls, body, footer) filling
/// the area.
uint pageColumn(ref Builder b, uint[] children) @safe
    => b.add(Widget(
        kind: WidgetKind.column,
        children: children,
        width: SizeSpec.grow(),
        height: SizeSpec.grow(),
        slot: Slot.surfaceBase,
        paintBackground: true,
    ));

/**
The rows a page's body gets: the area's `rows` less what the chrome above
(`top`) and below (`bottom`) takes, measured by laying the page out with an
empty body. The chrome stays in `b`, to be reused by $(LREF finishPage).
*/
int bodyRowsFor(ref Builder b, uint[] top, uint[] bottom, int cols, int rows) @safe
{
    Builder probe;
    probe.nodes = b.nodes.dup;
    const empty = probe.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow(),
        height: SizeSpec.grow()));
    auto tree = probe.finish(pageColumn(probe, top ~ empty ~ bottom));
    const frames = layout(tree, Constraints(maxW: cols, maxH: rows));
    const h = frames[empty].rect.height;
    return h > 0 ? h : 1;
}

/**
Finishes a page: `top`, a viewport `bodyRows` tall over `content`, then
`bottom`. The viewport is clipped and scrolled `scroll` rows down — clamped
here so the content's last row is at most the viewport's last, and moved so
node `reveal` (when not `uint.max`) is wholly in view: a selection followed
by the keyboard.
*/
WidgetTree finishPage(ref Builder b, uint[] top, uint content, uint[] bottom, int bodyRows,
    ref int scroll, int cols, int rows, uint reveal = uint.max) @safe
{
    const view = b.add(Widget(
        kind: WidgetKind.panel,
        children: [content],
        width: SizeSpec.grow(),
        height: SizeSpec.fixed(bodyRows),
        padding: Insets(0, 1, 0, 1),
        clipX: true,
        clipY: true,
    ));
    auto tree = b.finish(pageColumn(b, top ~ view ~ bottom));
    const frames = layout(tree, Constraints(maxW: cols, maxH: rows));
    const contentTop = frames[content].rect.y;
    if (reveal != uint.max && reveal < frames.length)
    {
        const r = frames[reveal].rect;
        const y0 = r.y - contentTop, y1 = y0 + r.height;
        if (y0 < scroll)
            scroll = y0;
        else if (y1 > scroll + bodyRows)
            scroll = y1 - bodyRows;
    }
    scroll = clampScroll(scroll, bodyRows, frames[content].rect.height);
    tree.nodes[view].childOffset = Point(0, scroll);
    return tree;
}

/// `scroll` clamped so the content's last row is at most the viewport's
/// last.
int clampScroll(int scroll, int viewHeight, int contentHeight) @safe pure nothrow @nogc
{
    const most = contentHeight - viewHeight;
    return scroll > most ? (most > 0 ? most : 0) : scroll < 0 ? 0 : scroll;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    /// A page of `lines` one-row lines, with a search field.
    private final class Lines : Page
    {
        int lines;
        size_t hit;
        string[] queries;

        this(int lines) @safe
        {
            super(PageServices.init);
            this.lines = lines;
        }

        override WidgetTree buildPage(in SurfaceContext ctx, int cols, int rows) @safe
        {
            import chrome : column, label;

            Builder b;
            uint[] items;
            foreach (i; 0 .. lines)
                items ~= label(b, "line");
            const body_ = column(b, items);
            uint[] top = [header(b, "Lines", ctx), searchField(b, query, searching, "search")];
            viewRows = bodyRowsFor(b, top, null, cols, rows);
            return finishPage(b, top, body_, null, viewRows, scroll, cols, rows);
        }

        override bool onHit(size_t id) @system
        {
            hit = id;
            return false;
        }

        override bool hasSearch() const @safe pure nothrow @nogc => true;
        override void queryChanged() @safe { queries ~= query; }
    }
}

@("page_kit.Page.keysFollowTheContract")
@system unittest
{
    import sparkles.input.events : Mods;

    auto p = new Lines(3);
    // Unfocused: q, Esc and Enter are the overlay rows', chords the leader's.
    assert(!p.key(KeyEvent(Key.char_, 'q')));
    assert(!p.key(KeyEvent(Key.escape)));
    assert(!p.key(KeyEvent(Key.enter)));
    assert(!p.key(KeyEvent(Key.char_, ' ', Mods(ctrl: true, shift: true))));
    // `/` focuses the field; then q is text, Esc leaves the field.
    assert(p.key(KeyEvent(Key.char_, '/')));
    assert(p.key(KeyEvent(Key.char_, 'q')));
    assert(p.key(KeyEvent(Key.char_, 'é')));
    assert(p.query == "qé");
    assert(p.key(KeyEvent(Key.backspace)));
    assert(p.query == "q" && p.queries == ["q", "qé", "q"]);
    assert(p.key(KeyEvent(Key.escape)));
    assert(!p.searching && p.query == "q", "leaving the field keeps the query");
    assert(!p.key(KeyEvent(Key.escape)), "a second Esc closes the page");
}

@("page_kit.Page.scrollIsClamped")
@system unittest
{
    import chrome : place, Place;

    SurfaceContext ctx;
    ctx.cellW = ctx.cellH = 1;
    ctx.area = Rect(0, 0, 80, 12);
    auto p = new Lines(30);
    // 12 rows: the header and the field take one each, the body ten.
    cast(void) p.build(ctx, 40);
    assert(p.viewRows == 10);
    assert(p.key(KeyEvent(Key.end)));
    cast(void) p.build(ctx, 40);
    assert(p.scroll == 20, "the last line is the body's last row");
    assert(p.key(KeyEvent(Key.pageUp)));
    cast(void) p.build(ctx, 40);
    assert(p.scroll == 11);
    assert(p.key(KeyEvent(Key.home)));
    cast(void) p.build(ctx, 40);
    assert(p.scroll == 0);
}

@("page_kit.Page.backAndSearchHits")
@system unittest
{
    import chrome : place, Place;

    SurfaceContext ctx;
    ctx.cellW = ctx.cellH = 1;
    ctx.area = Rect(0, 0, 80, 8);
    auto p = new Lines(2);
    const l = place(p.build(ctx, 30), 30, 8, 0, 0, 1, 1, Place.top);
    // The back button is the header's first cell; the field fills row 1.
    assert(l.hitAt(1, 0) == PageHit.back);
    assert(l.hitAt(10, 1) == PageHit.search);
    assert(p.activate(PageHit.back), "Back closes the page");
    assert(!p.activate(PageHit.search) && p.searching);
}

@("page_kit.chip.markNotColourAlone")
@safe unittest
{
    import std.algorithm.searching : canFind;

    Builder b;
    const on = chip(b, "info", true, 7);
    const off = chip(b, "debug", false, 8);
    auto t = b.finish(b.add(Widget(kind: WidgetKind.row, children: [on, off])));
    bool sawOn, sawOff;
    foreach (ref n; t.nodes)
    {
        sawOn |= n.text == "✓ info";
        sawOff |= n.text == "○ debug";
    }
    assert(sawOn && sawOff);
}
