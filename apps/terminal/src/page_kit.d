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

import sparkles.ui.glyphs : ActionIcon, iconText;
import sparkles.input.events : Key, KeyEvent;
import sparkles.base.text.grapheme : visibleWidth;
import sparkles.ui.geometry : Constraints, Insets, Point, Rect, SizeSpec;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.style : Decoration, FontRole, Slot, TextStyle, TypeStep;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

import chrome : button, chromeLayout, squareCols;
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
                    query = query[0 .. queryPrefixWithoutLastGrapheme(query)];
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
    import sparkles.base.text.utf : encodeScalar, isUnicodeScalar;

    if (c < 0x20 || c == 0x7F || !isUnicodeScalar(c))
        return null;
    char[4] buf;
    const encoded = encodeScalar(c, buf[]);
    return buf[0 .. encoded.written].idup;
}

/// Byte prefix before the final owned grapheme. Malformed bytes are individual
/// editing units and hard boundaries, so a backspace always makes progress.
size_t queryPrefixWithoutLastGrapheme(scope const(char)[] query)
    @safe pure nothrow @nogc
{
    import sparkles.base.text.grapheme : GraphemeBreakState;
    import sparkles.base.text.tokens : byUtfToken;
    import sparkles.base.text.utf : UtfMode, UtfTokenKind;

    GraphemeBreakState breaks;
    size_t last;
    foreach (token; byUtfToken(query, UtfMode.opaque))
    {
        if (token.kind == UtfTokenKind.opaqueByte)
        {
            last = token.start;
            breaks.reset();
        }
        else if (breaks.push(token.scalar))
            last = token.start;
    }
    return last;
}

// ─────────────────────────────────────────────────────────────────────────────
// Pieces.
// ─────────────────────────────────────────────────────────────────────────────

/**
The header band (mockups C1, LG1, N2): Back, the title, then `actions` at the
right — each a button made by the caller. Every page shares it, Settings
included (`backHit` is its own Back).
*/
uint header(ref Builder b, string title, in SurfaceContext ctx, uint[] actions = null,
    size_t backHit = PageHit.back) @safe
{
    const back = button(b, "←", "Back", ButtonLabels.icon, backHit,
        minRows: ctx.targetRows, minCols: squareCols(ctx.targetRows, ctx.cellW, ctx.cellH));
    // The title spans the bar's rows, so the face centres it on the buttons:
    // given the two rows its step measures, it sat in the top two of three.
    // It takes the room left, a long breadcrumb clipped at the actions.
    const name = b.add(Widget(kind: WidgetKind.text, text: title, slot: Slot.textPrimary,
        textStyle: TextStyle(bold: true, fontRole: FontRole.ui, typeStep: TypeStep.title),
        width: SizeSpec.grow(), clipX: true,
        height: ctx.targetRows > 1 ? SizeSpec.fixed(ctx.targetRows) : SizeSpec.fit_));
    return b.add(Widget(
        kind: WidgetKind.row,
        children: [back, name] ~ actions,
        gap: 1,
        alignY: Alignment.center,
        width: SizeSpec.grow(),
        // Fixed: a page whose body grows (Settings) reclaims overflow from
        // whatever is not, and squeezed the bar to a row under its filter.
        height: SizeSpec.fixed(ctx.targetRows > 1 ? ctx.targetRows : 1),
        // A cell in at both ends: Back sat on the screen's edge while the
        // actions kept a margin.
        padding: Insets(0, 1, 0, 1),
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
        slot: Slot.textPrimary, alignX: Alignment.center, width: SizeSpec.grow(),
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
    int rows = 1, size_t hitId = PageHit.search) @safe
{
    const mark = iconText(ActionIcon.search) ~ " ";
    const shown = query.length ? mark ~ query ~ (focused ? "▏" : "")
        : focused ? mark ~ "▏" : mark ~ placeholder;
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
        hitId: hitId,
        slot: focused ? Slot.surfaceSunken : Slot.surfaceRaised,
        paintBackground: true,
        decoration: Decoration(borderRadius: 6),
    ));
}

/**
$(LREF searchField) on its own row, a cell in from either side: the one
search row every surface shares — the logs, the tab tree, the key guide.

`inBand`: the row closes a sheet or a panel, whose band already pads the
sides — the field lines up with the rows above it, and a cell below keeps it
off the band's edge.
*/
uint searchRow(ref Builder b, string query, bool focused, string placeholder,
    int rows = 1, size_t hitId = PageHit.search, bool inBand = false) @safe
    => b.add(Widget(kind: WidgetKind.panel,
        children: [searchField(b, query, focused, placeholder, rows, hitId)],
        width: SizeSpec.grow(), padding: inBand ? Insets(0, 0, 1, 0) : Insets(0, 1, 0, 1)));

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

// The longest prefix of `s` within `cols` cells, whole graphemes only.
private inout(char)[] prefixCells(inout(char)[] s, long cols) @safe pure nothrow
{
    import grapheme = sparkles.base.text.grapheme;

    return cols <= 0 ? s[0 .. 0] : s[0 .. grapheme.fitCells(s, cast(size_t) cols).bytes];
}

/**
`s` within `cols` cells: itself when it fits, else cut with a `…` in the last
cell — a line that runs off the page says so rather than stopping mid-word.
*/
string fitCells(string s, int cols) @safe pure nothrow
{
    if (cols <= 0 || visibleWidth(s) <= cols)
        return s;
    return prefixCells(s, cols - 1) ~ "…";
}

///
@("page_kit.fitCells.cutsWithAnEllipsis")
@safe pure nothrow unittest
{
    assert(fitCells("short", 10) == "short");
    assert(fitCells("FONT: Data loaded successfully", 10) == "FONT: Dat…");
    assert(visibleWidth(fitCells("ééééééé", 4)) == 4);
}

/**
`s` with every unbroken run longer than `cols` cells — a package name, a
path — split across lines at `cols`: the wrap breaks only at spaces, so such
a run overflowed its column and was cut at the screen's edge.
*/
string breakLong(string s, int cols) @safe pure nothrow
{
    import std.array : appender;

    if (cols <= 0 || visibleWidth(s) <= cols)
        return s;
    auto r = appender!string;
    size_t i;
    while (i < s.length)
    {
        size_t j = i;
        while (j < s.length && s[j] != ' ')
            j++;
        auto word = s[i .. j];
        while (visibleWidth(word) > cols)
        {
            const head = prefixCells(word, cols);
            r ~= head;
            r ~= '\n';
            word = word[head.length .. $];
        }
        r ~= word;
        if (j < s.length)
            r ~= ' ';
        i = j + 1;
    }
    return r[];
}

///
@("page_kit.breakLong.splitsARunTooLongForItsColumn")
@safe pure nothrow unittest
{
    assert(breakLong("0.1.0", 8) == "0.1.0");
    assert(breakLong("dev.petar_kirov.sparkles", 10) == "dev.petar_\nkirov.spar\nkles");
    assert(breakLong("a dev.petar_kirov b", 10) == "a dev.petar_\nkirov b");
}

/// A value, a path or a log line, in the cell font, wrapping to the room it
/// is given.
uint codeText(ref Builder b, const(char)[] text, Slot slot = Slot.code) @safe
    => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot, wrap: TextWrap.greedy,
        textStyle: TextStyle(fontRole: FontRole.uiMono, typeStep: TypeStep.body)));

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
    const frames = chromeLayout(tree, Constraints(maxW: cols, maxH: rows));
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
    const frames = chromeLayout(tree, Constraints(maxW: cols, maxH: rows));
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

@("page_kit.Page.backspaceRemovesCompleteGraphemesAndMalformedBytes")
@system unittest
{
    auto p = new Lines(1);
    assert(p.key(KeyEvent(Key.char_, '/')));
    foreach (q; ["qa\u0301", "q\U0001F469\u200D\U0001F4BB",
        "q\U0001F1FA\U0001F1F8", "q\u0915\u094D\u0937"])
    {
        p.setQuery(q);
        assert(p.key(KeyEvent(Key.backspace)));
        assert(p.query == "q", "backspace leaves no trailing cluster fragment");
    }
    p.setQuery("q\xE1\x80");
    assert(p.key(KeyEvent(Key.backspace)));
    assert(p.query == "q\xE1", "one malformed byte is one editing unit");
    assert(p.key(KeyEvent(Key.backspace)));
    assert(p.query == "q");
    p.setQuery("q\x80\u0301");
    assert(p.key(KeyEvent(Key.backspace)));
    assert(p.query == "q\x80", "a malformed byte cannot acquire a combining mark");
    assert(p.key(KeyEvent(Key.backspace)));
    assert(p.query == "q");
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

@("page_kit.header.keepsItsRowsInAGrowingColumn")
@safe unittest
{
    // Settings: the header over a body that grows. The header keeps its
    // three rows; the body takes what is left.
    SurfaceContext ctx;
    ctx.cellW = ctx.cellH = 1;
    ctx.targetRows = 3;
    Builder b;
    const head = header(b, "Settings", ctx);
    const body_ = b.add(Widget(kind: WidgetKind.column, height: SizeSpec.grow(),
        children: [b.add(Widget(kind: WidgetKind.box, height: SizeSpec.fixed(40)))]));
    const root = b.add(Widget(kind: WidgetKind.column, children: [head, body_],
        width: SizeSpec.fixed(40), height: SizeSpec.fixed(20)));
    auto t = b.finish(root);
    const f = chromeLayout(t, Constraints(maxW: 40, maxH: 20));
    assert(f[head].rect.height == 3 && f[body_].rect.y == 3);
}
