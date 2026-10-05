/**
The selection's own chrome (docs/specs/terminal/selection.md): the menu that
acts on a selection and, on a touch screen, the two handles that move its
ends.

$(LIST
    * $(LREF ActionMenu) — one surface in four presentations: the bottom
        sheet with a swipeable action row (mockup S2), the anchored card
        (B1), the compact icon pill (B4) — `ui.selectionMenu` chooses
        (`TCF11`) — and the desktop's right-click menu (X1, `TSE7`). Which
        actions show is $(LREF touchActions) / $(LREF desktopActions): an
        item that cannot act is hidden, not disabled (`TSE5`).
    * $(LREF placeCard) — the card's placement (`TSE6`): above the
        selection, flipped below it, slid inside the pane, never over the
        selection or its handles; no position means a sheet. A sheet that
        would hide the selection lifts the pane's content above it.
    * $(LREF SelectionUi) — the controller an embedder drives: a long-press
        selects (`TSE1`), a handle drag moves an end and scrolls at the edges
        (`TSE3`), a tap or a scroll elsewhere follows `TSE4`, and the menu's
        actions run through it.
)

The selection model itself — anchors, words, text — is
`sparkles.terminal_view.selection`; nothing here reads the grid.
*/
module selection_menu;

import sparkles.input.events : Key, KeyAction, KeyEvent;
import sparkles.terminal_view.component : TerminalView;
import sparkles.terminal_view.selection : Granularity, SelectionBounds, SelectionEnd;
import sparkles.ui.components.dock : PaneId;
import sparkles.ui.geometry : Insets, Point, Rect, SizeSpec;
import sparkles.ui.style : Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import chrome : Layer, label, place, Place;
import settings : ButtonLabels, SelectionMenu;
import surfaces : Placement, SelfPlaced, Surface, SurfaceContext;

// ─────────────────────────────────────────────────────────────────────────────
// The actions.
// ─────────────────────────────────────────────────────────────────────────────

/// What a selection menu offers (`TSE5`, `TSE7`).
enum MenuAction : ubyte
{
    copy,
    paste,
    selectAll,
    openUrl,
    share,
    find,
    run,
    autofill,
    more,
}

/// An action's icon, its label, and the short label a narrow item shows.
struct ActionLook
{
    string icon, label, shortLabel;
}

/// The mockups' icons and words (S2, B1, X1).
immutable ActionLook[MenuAction.max + 1] looks = [
    MenuAction.copy: ActionLook("⧉", "Copy", "Copy"),
    MenuAction.paste: ActionLook("⎘", "Paste", "Paste"),
    MenuAction.selectAll: ActionLook("▣", "Select all", "All"),
    MenuAction.openUrl: ActionLook("⇗", "Open URL", "Open"),
    MenuAction.share: ActionLook("↗", "Share", "Share"),
    MenuAction.find: ActionLook("⌕", "Find in scrollback", "Find"),
    MenuAction.run: ActionLook("❯", "Run in a new pane", "Run"),
    MenuAction.autofill: ActionLook("⚿", "Autofill password", "Autofill"),
    MenuAction.more: ActionLook("⋯", "More", "More"),
];

/// What decides which actions a menu shows.
struct MenuFacts
{
    /// The selection's length in code points; 0: nothing selected.
    size_t chars;
    /// How many lines it spans.
    size_t lines = 1;
    /// The clipboard holds text.
    bool canPaste;
    /// The one link that is, or is in, the selection — when it may be
    /// opened (`TPR6`); null for none, several, or a refused scheme.
    string link;
    /// Android's share sheet (`ACTION_SEND`) is there.
    bool canShare;
    /// An autofill service is enabled and the input field exists (`TSE8`).
    bool canAutofill;
}

/// The longest selection Run will take as a command.
enum maxRunLength = 1024;

/// The touch menu's actions, in order (`TSE5`); Autofill is not among them —
/// the sheet shows it as a row of its own.
MenuAction[] touchActions(in MenuFacts f) @safe pure nothrow
{
    MenuAction[] a;
    const sel = f.chars > 0;
    if (sel)
        a ~= MenuAction.copy;
    if (f.canPaste)
        a ~= MenuAction.paste;
    a ~= MenuAction.selectAll;
    if (sel && f.link.length)
        a ~= MenuAction.openUrl;
    if (sel && f.canShare)
        a ~= MenuAction.share;
    if (sel && f.lines == 1)
        a ~= MenuAction.find;
    if (sel && f.lines == 1 && f.chars <= maxRunLength)
        a ~= MenuAction.run;
    return a;
}

/**
The desktop's right-click menu (`TSE7`, mockup X1), in groups: Copy, Paste,
Select all; Find in scrollback, Run in a new pane; then More, holding the
rest (Open URL) — never Share or Autofill.
*/
MenuAction[][] desktopActions(in MenuFacts f) @safe pure nothrow
{
    MenuFacts d = f;
    d.canShare = false;
    const all = touchActions(d);
    MenuAction[][] groups = [[], [], []];
    foreach (x; all)
        final switch (x)
        {
            case MenuAction.copy, MenuAction.paste, MenuAction.selectAll:
                groups[0] ~= x;
                break;
            case MenuAction.find, MenuAction.run:
                groups[1] ~= x;
                break;
            case MenuAction.openUrl:
                groups[2] ~= x;
                break;
            case MenuAction.share, MenuAction.autofill, MenuAction.more:
                break;
        }
    return groups;
}

///
@("selection_menu.actions.hiddenNotDisabled")
@safe pure nothrow unittest
{
    with (MenuAction)
    {
        // A word, a clipboard with text, on a phone with a share sheet.
        auto f = MenuFacts(chars: 23, canPaste: true, canShare: true);
        assert(touchActions(f) == [copy, paste, selectAll, share, find, run]);
        // A long-press on blank cells: Paste (and Select all) only (`TSE1`).
        assert(touchActions(MenuFacts(canPaste: true)) == [paste, selectAll]);
        // Several lines: no Find, no Run; an openable link adds Open URL.
        f.lines = 3;
        f.link = "https://ex.org";
        assert(touchActions(f) == [copy, paste, selectAll, openUrl, share]);
        // The desktop: no Share, in X1's groups, Open URL under More.
        f.lines = 1;
        assert(desktopActions(f) == [[copy, paste, selectAll], [find, run], [openUrl]]);
    }
}

/// The selection described for the menu's first line: "23 characters
/// selected", "3 lines selected", "Nothing selected".
string describe(in MenuFacts f) @safe pure nothrow
{
    import std.conv : to;

    if (f.chars == 0)
        return "Nothing selected";
    if (f.lines > 1)
        return f.lines.to!string ~ " lines selected";
    return f.chars.to!string ~ (f.chars == 1 ? " character selected" : " characters selected");
}

/// Counts what `describe` needs: code points and lines of `text`.
MenuFacts measure(scope const(char)[] text) @safe pure nothrow @nogc
{
    MenuFacts f;
    foreach (c; text)
    {
        f.chars += (c & 0xC0) != 0x80;
        f.lines += c == '\n';
    }
    return f;
}

///
@("selection_menu.describe.charactersOrLines")
@safe pure nothrow unittest
{
    assert(describe(measure("feat/terminal/workspace")) == "23 characters selected");
    assert(describe(measure("a\nb\nc")) == "3 lines selected");
    assert(describe(measure("é")) == "1 character selected");
    assert(describe(MenuFacts.init) == "Nothing selected");
}

/**
The one link a selection is or contains — `hyperlinks` (the OSC 8 targets
under it) when there are any, else the URLs detected in `text` — or null
for none or several (`TSE5`: Open URL wants exactly one).
*/
string singleLink(scope const string[] hyperlinks, size_t hyperlinkCount, string text) @safe pure nothrow
{
    import sparkles.terminal_view.selection : urlSpan;

    if (hyperlinkCount)
        return hyperlinkCount == 1 && hyperlinks.length ? hyperlinks[0] : null;
    string found;
    size_t count;
    size_t from;
    foreach (i; 0 .. text.length + 1)
    {
        if (i < text.length && text[i] != '\n')
            continue;
        const line = text[from .. i];
        from = i + 1;
        dchar[] cells;
        size_t[] offsets;
        size_t j;
        while (j < line.length)
        {
            offsets ~= j;
            cells ~= decodeOne(line, j);
        }
        offsets ~= line.length;
        size_t col;
        while (col < cells.length)
        {
            size_t lo, hi;
            if (urlSpan(cells, col, lo, hi))
            {
                const url = line[offsets[lo] .. offsets[hi + 1]];
                if (url != found)
                {
                    found = url;
                    count++;
                }
                col = hi + 1;
            }
            else
                col++;
        }
    }
    return count == 1 ? found : null;
}

private dchar decodeOne(scope const(char)[] s, ref size_t i) @safe pure nothrow @nogc
{
    import sparkles.base.text.utf : decodeFirstUtf8;

    size_t n = 1;
    while (i + n < s.length && (s[i + n] & 0xC0) == 0x80)
        n++;
    const c = decodeFirstUtf8(s[i .. i + n]);
    i += n;
    return c;
}

///
@("selection_menu.singleLink.exactlyOne")
@safe pure nothrow unittest
{
    assert(singleLink(null, 0, "see https://ex.org/a.") == "https://ex.org/a");
    assert(singleLink(null, 0, "https://a.b https://c.d") is null, "two: no Open URL");
    assert(singleLink(null, 0, "no link here") is null);
    assert(singleLink(["https://target"], 1, "https://text") == "https://target",
        "an OSC 8 link opens its URI, never its text (`TPR6`)");
    assert(singleLink(["a", "b"], 2, "") is null);
}

// ─────────────────────────────────────────────────────────────────────────────
// Placement (`TSE6`).
// ─────────────────────────────────────────────────────────────────────────────

private bool overlaps(in Rect a, in Rect b) @safe pure nothrow @nogc
    => a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0
        && a.x < b.x + b.width && b.x < a.x + a.width
        && a.y < b.y + b.height && b.y < a.y + a.height;

private bool inside(in Rect r, in Rect area) @safe pure nothrow @nogc
    => r.x >= area.x && r.y >= area.y
        && r.x + r.width <= area.x + area.width && r.y + r.height <= area.y + area.height;

/**
Where a `w` × `h` card goes (`TSE6`): above `subject` — below first with
`preferBelow` — and flipped to the other side when there is no room there;
its start edge at the subject's, slid back inside `area`; never over the
subject or any of `avoid` (the handles). `area` already excludes the soft
keyboard and the extra-keys row, so the card stays clear of both. False
when no position fits: that occurrence is a sheet (B3).
*/
bool placeCard(int w, int h, in Rect area, in Rect subject, scope const Rect[] avoid,
    bool preferBelow, out Point at) @safe pure nothrow @nogc
{
    if (w > area.width || h > area.height)
        return false;
    // The side below clears the handles too: they hang under the text.
    int belowY = subject.y + subject.height;
    foreach (ref r; avoid)
        if (r.y + r.height > belowY && r.y < belowY + h && r.x < subject.x + subject.width + w)
            belowY = r.y + r.height;
    int aboveY = subject.y - h;
    foreach (ref r; avoid)
        if (r.y < subject.y && r.y < aboveY + h)
            aboveY = r.y - h;
    const int[2] ys = preferBelow ? [belowY, aboveY] : [aboveY, belowY];

    int x = subject.x;
    if (x + w > area.x + area.width)
        x = area.x + area.width - w;
    if (x < area.x)
        x = area.x;
    foreach (y; ys)
    {
        const card = Rect(x, y, w, h);
        if (!inside(card, area) || overlaps(card, subject))
            continue;
        bool clear = true;
        foreach (ref r; avoid)
            clear &= !overlaps(card, r);
        if (clear)
        {
            at = Point(x, y);
            return true;
        }
    }
    return false;
}

///
@("selection_menu.placeCard.flipSlideInsetsAndFallback")
@safe pure nothrow @nogc unittest
{
    // A 400×600 pane; the keyboard and the extra keys are below it, so the
    // area's bottom is their inset.
    const area = Rect(0, 100, 400, 600);
    Point at;

    // Room above: the card sits above the selection, at its start.
    const sel = Rect(60, 500, 120, 20);
    const Rect[2] handles = [Rect(40, 520, 20, 20), Rect(180, 520, 20, 20)];
    assert(placeCard(200, 50, area, sel, handles, false, at));
    assert(at == Point(60, 450));

    // Near the top: flipped below — under the handles, not over them.
    const top = Rect(60, 110, 120, 20);
    const Rect[2] topHandles = [Rect(40, 130, 20, 20), Rect(180, 130, 20, 20)];
    assert(placeCard(200, 50, area, top, topHandles, false, at));
    assert(at.y == 150, "below the handles");

    // Near the right edge: slid back inside the pane.
    assert(placeCard(200, 50, area, Rect(350, 500, 40, 20), null, false, at));
    assert(at.x == 200 && at.y == 450);

    // The keyboard inset: a selection on the last rows above it, with no
    // room below, flips above; with none above either — a selection taller
    // than the room around it — there is no place: a sheet.
    const shortArea = Rect(0, 100, 400, 200);
    assert(placeCard(200, 50, shortArea, Rect(0, 260, 100, 20), null, true, at));
    assert(at.y == 210, "preferred below, but the keyboard is there: above");
    assert(!placeCard(200, 50, shortArea, Rect(0, 120, 400, 160), null, false, at));

    // The desktop's menu prefers below.
    assert(placeCard(200, 50, area, sel, null, true, at) && at.y == 520);
}

/**
How many rows the content must rise so a selection whose last row ends at
`selectionBottom` (its handle included) sits above a sheet whose top is at
`sheetTop` — `cellH` pixels a row (`TSE6`, B2). 0 when it already does.
*/
int liftFor(int selectionBottom, int sheetTop, int cellH) @safe pure nothrow @nogc
    => selectionBottom <= sheetTop || cellH <= 0 ? 0
        : (selectionBottom - sheetTop + cellH - 1) / cellH;

///
@("selection_menu.liftFor.keepsTheSelectionAboveTheSheet")
@safe pure nothrow @nogc unittest
{
    assert(liftFor(300, 400, 20) == 0);
    assert(liftFor(400, 400, 20) == 0);
    assert(liftFor(401, 400, 20) == 1);
    assert(liftFor(470, 400, 20) == 4);
}

// ─────────────────────────────────────────────────────────────────────────────
// The menu.
// ─────────────────────────────────────────────────────────────────────────────

/// How a menu is shown.
enum Presentation : ubyte
{
    sheet, /// S2: along the pane's bottom, the action row swipes
    card, /// B1: anchored, labelled actions
    compact, /// B4: anchored, icon-only actions
    context, /// X1: the desktop's right-click menu
}

/// `ui.selectionMenu` resolved (`TCF14`, D47): `auto` is the anchored card on
/// a large screen, where a full-width sheet puts the actions far from the
/// selection, and the sheet on a phone.
SelectionMenu menuStyle(SelectionMenu setting, bool largeScreen) @safe pure nothrow @nogc
    => setting != SelectionMenu.automatic ? setting
        : largeScreen ? SelectionMenu.card : SelectionMenu.sheet;

@("selection_menu.menuStyle.autoByScreen")
@safe pure nothrow @nogc unittest
{
    assert(menuStyle(SelectionMenu.automatic, largeScreen: true) == SelectionMenu.card);
    assert(menuStyle(SelectionMenu.automatic, largeScreen: false) == SelectionMenu.sheet);
    assert(menuStyle(SelectionMenu.compact, largeScreen: true) == SelectionMenu.compact);
    assert(menuStyle(SelectionMenu.sheet, largeScreen: true) == SelectionMenu.sheet);
}

/// What the menu acts through: the embedder's side.
interface MenuHost
{
    /// Runs `a` on the selection.
    void perform(MenuAction a) @system;
    /// The menu closed, however (an action, Esc, Back, a tap outside).
    void menuClosed() @system;
    /// Show a transient note.
    void note(string text) @safe;
}

/// Where the selection is on screen, in pixels: what a card avoids and a
/// sheet keeps clear (`TSE6`). Set by the controller every frame.
struct SelectionGeometry
{
    /// The selection's bounding box (its visible rows).
    Rect box;
    /// The handles' drawings (empty when off screen or on the desktop).
    Rect[2] handles;
    /// The lowest pixel the selection and its end handle reach, as painted
    /// (lifted by `lift` rows).
    int bottom;
    /// The pane's top and cell height, for the sheet's lift.
    int paneTop, cellH = 1;
    /// What the content is lifted by now.
    int lift;
}

private enum size_t hitBase = 0x5E10;
private enum size_t hitFirst = hitBase + 0x100; // a swiped row's first item

private MenuAction actionOf(size_t id) @safe pure nothrow @nogc
    => cast(MenuAction)(id - hitBase);

/// The selection menu, in any presentation (`TSE5`, `TSE7`).
final class ActionMenu : Surface, SelfPlaced
{
    MenuHost host;
    MenuFacts facts;
    /// The asked-for presentation; a card that fits nowhere shows as a sheet.
    Presentation asked;
    /// Where the selection is (the controller keeps it current).
    SelectionGeometry geo;
    /// The pointer that opened a desktop menu.
    Point pointer;
    /// Shortcut hints by action (`TCF9`: shown in every label mode).
    string[MenuAction.max + 1] shortcuts;
    /// Called with the rows the content must rise above a sheet (`TSE6`).
    void delegate(int rows) @safe lift;

    private MenuAction[] actions; // the touch row, or the desktop's flat list
    private MenuAction[][] groups; // the desktop's groups
    private MenuAction[] rest; // what More lists
    private bool showingMore;
    private size_t first; // the sheet row's first visible item
    private size_t visible; // how many items the sheet row shows whole
    private size_t focus; // the desktop's highlighted item
    private Presentation shown;
    private bool fellBack;
    private int liftShown;
    /// The layer as last placed (the controller's swipe needs the row).
    Layer layer;

    this(MenuHost host, MenuFacts facts, Presentation asked) @safe
    {
        this.host = host;
        this.facts = facts;
        this.asked = asked;
        shown = asked;
        if (asked == Presentation.context)
        {
            groups = desktopActions(facts);
            if (groups[2].length)
                groups[2] = [MenuAction.more];
            rest = desktopActions(facts)[2];
            foreach (g; groups)
                actions ~= g;
        }
        else
            actions = touchActions(facts);
    }

    /// Whether the sheet's action row is showing `More`'s list instead.
    bool listing() const @safe pure nothrow @nogc => showingMore;

    /// The presentation shown this frame.
    Presentation presentation() const @safe pure nothrow @nogc => shown;

    /// Swipes the sheet's action row by `items` (negative: back).
    void swipe(int items) @safe pure nothrow @nogc
    {
        const total = actions.length + (rowOverflows ? 1 : 0);
        const last = total > visible ? total - visible : 0;
        long f = cast(long) first + items;
        first = f < 0 ? 0 : f > last ? last : cast(size_t) f;
    }

    private bool rowOverflows; // the row does not fit: it ends in More

    // ── Surface ─────────────────────────────────────────────────────────

    WidgetTree build(in SurfaceContext ctx, int cols) @safe
        => buildAs(shown, ctx, cols);

    Placement placement() const @safe
        => shown == Presentation.sheet ? Placement.sheet : Placement.anchored;

    bool activate(size_t id) @system
    {
        if (id < hitBase || id > hitBase + MenuAction.max)
            return false;
        const a = actionOf(id);
        if (a == MenuAction.more)
        {
            showingMore = true;
            focus = 0;
            return false;
        }
        host.perform(a);
        host.menuClosed();
        return true;
    }

    bool confirm() @system
    {
        const list = current;
        return list.length ? activate(hitBase + list[focus < list.length ? focus : 0]) : false;
    }

    void cancel() @system
    {
        host.menuClosed();
    }

    bool key(in KeyEvent k) @system
    {
        const list = current;
        if (!list.length || k.action == KeyAction.release)
            return false;
        switch (k.key)
        {
            case Key.up, Key.left:
                focus = focus == 0 ? list.length - 1 : focus - 1;
                return true;
            case Key.down, Key.right:
                focus = (focus + 1) % list.length;
                return true;
            default:
                return false;
        }
    }

    private const(MenuAction)[] current() const @safe pure nothrow
        => showingMore ? rest : actions;

    // ── placement ───────────────────────────────────────────────────────

    Layer placeIn(in SurfaceContext ctx) @safe
    {
        const cols = ctx.area.width / ctx.cellW, rows = ctx.area.height / ctx.cellH;
        Layer l;
        if (asked == Presentation.card || asked == Presentation.compact
            || asked == Presentation.context)
        {
            shown = asked;
            auto probe = .place(buildAs(asked, ctx, cols), cols, rows, 0, 0,
                ctx.cellW, ctx.cellH, Place.top);
            const w = probe.bounds.width * ctx.cellW, h = probe.bounds.height * ctx.cellH;
            Point at;
            Rect subject = geo.box;
            if (asked == Presentation.context && (subject.width == 0 || !overlapsPointer(subject)))
                subject = Rect(pointer.x, pointer.y, 1, ctx.cellH);
            if (placeCard(w, h, ctx.area, subject, geo.handles[], asked == Presentation.context, at)
                || (asked == Presentation.context && clampAt(w, h, ctx.area, pointer, at)))
            {
                probe.x = at.x;
                probe.y = at.y;
                applyLift(0);
                fellBack = false;
                return layer = probe;
            }
            shown = Presentation.sheet; // no room for a card: this once a sheet (B3)
            fellBack = true;
        }
        l = .place(buildAs(Presentation.sheet, ctx, cols), cols, rows, ctx.area.x, ctx.area.y,
            ctx.cellW, ctx.cellH, Place.bottom);
        // The sheet must not hide the selection: the content rises (B2).
        applyLift(liftFor(geo.bottom + geo.lift * geo.cellH, l.y, geo.cellH));
        return layer = l;
    }

    private bool overlapsPointer(in Rect r) const @safe pure nothrow @nogc
        => pointer.x >= r.x && pointer.x < r.x + r.width
            && pointer.y >= r.y && pointer.y < r.y + r.height;

    private static bool clampAt(int w, int h, in Rect area, Point p, out Point at)
        @safe pure nothrow @nogc
    {
        int x = p.x, y = p.y;
        if (x + w > area.x + area.width)
            x = area.x + area.width - w;
        if (y + h > area.y + area.height)
            y = p.y - h;
        if (x < area.x)
            x = area.x;
        if (y < area.y)
            y = area.y;
        at = Point(x, y);
        return w <= area.width && h <= area.height;
    }

    private void applyLift(int rows) @safe
    {
        if (rows == liftShown)
            return;
        import std.conv : to;

        if (rows > liftShown && rows > 0)
            host.note("Lifted " ~ rows.to!string ~ (rows == 1 ? " line" : " lines")
                ~ " to show the selection");
        liftShown = rows;
        if (lift !is null)
            lift(rows);
    }

    // ── the trees ───────────────────────────────────────────────────────

    private WidgetTree buildAs(Presentation p, in SurfaceContext ctx, int cols) @safe
    {
        final switch (p)
        {
            case Presentation.sheet:
                return buildSheet(ctx, cols);
            case Presentation.card:
            case Presentation.compact:
                return buildCard(ctx, p == Presentation.compact);
            case Presentation.context:
                return buildContext(ctx);
        }
    }

    /// A row item of the sheet or the card: icon over label, a touch target.
    private uint item(ref Builder b, MenuAction a, in SurfaceContext ctx, int width,
        bool iconOnly, bool cut = false) @safe
    {
        const look = looks[a];
        const mode = iconOnly ? ButtonLabels.icon : ctx.labels;
        const slot = cut ? Slot.muted : a == MenuAction.copy ? Slot.accentPrimary
            : a == MenuAction.more ? Slot.muted : Slot.textPrimary;
        const style = TextStyle(bold: a == MenuAction.copy);
        uint[] lines;
        if (mode != ButtonLabels.text)
            lines ~= b.add(Widget(kind: WidgetKind.text, text: look.icon, slot: slot, textStyle: style));
        if (mode != ButtonLabels.icon)
            lines ~= b.add(Widget(kind: WidgetKind.text, text: look.shortLabel, slot: slot,
                textStyle: style));
        const tall = ctx.targetRows > lines.length ? ctx.targetRows : cast(int) lines.length;
        return b.add(Widget(
            kind: WidgetKind.panel,
            children: [b.add(Widget(kind: WidgetKind.column, children: lines,
                alignX: Alignment.center))],
            width: width > 0 ? SizeSpec.fixed(width) : SizeSpec.fit_,
            height: SizeSpec.fixed(tall),
            padding: Insets(0, 1, 0, 1),
            alignX: Alignment.center,
            alignY: Alignment.center,
            hitId: cut ? 0 : hitBase + a,
        ));
    }

    private WidgetTree buildSheet(in SurfaceContext ctx, int cols) @safe
    {
        Builder b;
        uint[] body_;
        const title = describe(facts) ~ (fellBack ? " · no room for a card, shown as a sheet" : "");
        body_ ~= label(b, title, Slot.muted);

        if (showingMore)
        {
            foreach (a; rest)
                body_ ~= wide(b, a, ctx);
        }
        else
        {
            // Items at a fixed width; the row is cut at the pane's edge so the
            // last visible item shows cut off — the row reads as scrollable
            // without a page indicator (`TSE5`).
            enum itemW = 9;
            const room = cols - 2;
            visible = room / itemW > 0 ? room / itemW : 1;
            rowOverflows = actions.length > visible;
            const MenuAction[] row = actions ~ (rowOverflows ? [MenuAction.more] : []);
            if (first + visible > row.length)
                first = row.length > visible ? row.length - visible : 0;
            uint[] items;
            foreach (i, a; row[first .. $])
            {
                if (i < visible)
                    items ~= item(b, a, ctx, itemW, false);
                else
                {
                    const left = room - cast(int)(visible * itemW);
                    if (left >= 2)
                        items ~= item(b, a, ctx, left, false, cut: true);
                    break;
                }
            }
            // More lists what the row does not show whole.
            rest = null;
            foreach (i, a; row)
                if ((i < first || i >= first + visible) && a != MenuAction.more)
                    rest ~= a;
            body_ ~= b.add(Widget(kind: WidgetKind.row, children: items));
            if (facts.canAutofill)
                body_ ~= wide(b, MenuAction.autofill, ctx);
        }
        return b.finish(b.add(Widget(
            kind: WidgetKind.panel,
            children: [b.add(Widget(kind: WidgetKind.column, children: body_, gap: 0))],
            padding: Insets(0, 1, 0, 1),
            width: SizeSpec.grow(),
            slot: Slot.surfaceRaised,
            paintBackground: true,
            decoration: Decoration(borderWidth: Insets(1, 0, 0, 0), borderRadius: 12),
        )));
    }

    /// A full-width row: Autofill under the sheet's actions, More's list.
    private uint wide(ref Builder b, MenuAction a, in SurfaceContext ctx) @safe
    {
        import chrome : button;

        const look = looks[a];
        const btn = button(b, look.icon, look.label, ctx.labels, hitBase + a,
            minRows: ctx.targetRows);
        b.nodes[btn].width = SizeSpec.grow();
        return btn;
    }

    private WidgetTree buildCard(in SurfaceContext ctx, bool compact) @safe
    {
        Builder b;
        // B1/B4: Copy, Paste, All, Find and More; the rest under More.
        static immutable MenuAction[] primary = [MenuAction.copy, MenuAction.paste,
            MenuAction.selectAll, MenuAction.find];
        MenuAction[] row;
        rest = null;
        foreach (a; actions)
            if (primaryHas(primary, a))
                row ~= a;
            else
                rest ~= a;
        if (facts.canAutofill)
            rest ~= MenuAction.autofill;
        if (showingMore)
        {
            uint[] list;
            foreach (a; rest)
                list ~= wide(b, a, ctx);
            return b.finish(cardPanel(b, b.add(Widget(kind: WidgetKind.column, children: list)),
                compact));
        }
        if (rest.length)
            row ~= MenuAction.more;
        uint[] items;
        foreach (a; row)
            items ~= item(b, a, ctx, compact ? 0 : 8, compact);
        return b.finish(cardPanel(b, b.add(Widget(kind: WidgetKind.row, children: items)),
            compact));
    }

    private static bool primaryHas(scope const MenuAction[] p, MenuAction a) @safe pure nothrow @nogc
    {
        foreach (x; p)
            if (x == a)
                return true;
        return false;
    }

    private uint cardPanel(ref Builder b, uint content, bool compact) @safe
        => b.add(Widget(
            kind: WidgetKind.panel,
            children: [content],
            slot: Slot.surfaceRaised,
            paintBackground: true,
            decoration: Decoration(borderWidth: Insets(1, 1, 1, 1),
                borderRadius: compact ? 22 : 10, shadow: true),
        ));

    private WidgetTree buildContext(in SurfaceContext ctx) @safe
    {
        Builder b;
        const menuW = 30;
        uint[] list;
        const groupsShown = showingMore ? [rest] : groups;
        size_t index;
        foreach (gi, g; groupsShown)
            foreach (i, a; g)
            {
                const look = looks[a];
                const focused = index++ == focus;
                string caption;
                final switch (ctx.labels)
                {
                    case ButtonLabels.iconText:
                        caption = look.icon ~ " " ~ look.label;
                        break;
                    case ButtonLabels.text:
                        caption = look.label;
                        break;
                    case ButtonLabels.icon:
                        caption = look.icon;
                        break;
                }
                const hint = a == MenuAction.more ? "▸" : shortcuts[a];
                const text = focused ? Slot.inherit : Slot.textPrimary;
                list ~= b.add(Widget(
                    kind: WidgetKind.panel,
                    children: [b.add(Widget(kind: WidgetKind.row, width: SizeSpec.grow(), children: [
                        b.add(Widget(kind: WidgetKind.text, text: caption, slot: text)),
                        b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow())),
                        b.add(Widget(kind: WidgetKind.text, text: hint,
                            slot: focused ? text : Slot.muted)),
                    ]))],
                    width: SizeSpec.fixed(menuW),
                    padding: Insets(0, 1, 0, 1),
                    hitId: hitBase + a,
                    slot: focused ? Slot.chromeFocused : Slot.surfaceRaised,
                    paintBackground: focused,
                    // A rule between X1's groups.
                    decoration: Decoration(borderWidth: Insets(i == 0 && gi > 0 ? 1 : 0, 0, 0, 0)),
                ));
            }
        if (!list.length)
            list ~= label(b, "Nothing to do here", Slot.muted);
        return b.finish(b.add(Widget(
            kind: WidgetKind.panel,
            children: [b.add(Widget(kind: WidgetKind.column, children: list))],
            slot: Slot.surfaceRaised,
            paintBackground: true,
            decoration: Decoration(borderWidth: Insets(1, 1, 1, 1), borderRadius: 6, shadow: true),
        )));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The controller.
// ─────────────────────────────────────────────────────────────────────────────

/// What the platform offers the menu; an unset member is an action the
/// platform does not have (hidden, `TSE5`).
struct SelectionPlatform
{
    /// A touch screen: handles, the long-press and the touch menu; else the
    /// desktop's right-click menu (`TCF11`).
    bool touch;
    /// The clipboard holds text (Paste shows); unset: assume it does.
    bool delegate() @system clipboardHasText;
    /// Android's share sheet (`ACTION_SEND`).
    void delegate(string text) @system share;
    /// Whether an autofill service would answer (`TSE8`), and the request.
    bool delegate() @system canAutofill;
    /// ditto
    void delegate() @system autofill;
}

/// Where a handle is: its drawing and the point of the text it marks.
struct Handle
{
    /// The drawing: a droplet under the cell, pointing at its corner.
    Rect drawing;
    /// The centre of the cell it marks (what a drag moves).
    Point anchor;
    /// The tracked end it moves.
    SelectionEnd end;
    /// Whether it is on screen.
    bool shown;
}

/**
The two handles for `b` in a pane at pixel (`ox`, `oy`), `rows` rows of
`cw` × `ch` cells, its content lifted `lift` rows; each drawing `size`
pixels square (`TSE3`, S2): the start's hangs left of its cell's bottom-left
corner, the end's right of its bottom-right.
*/
Handle[2] handlesOf(in SelectionBounds b, int ox, int oy, int rows, int cw, int ch, int lift,
    int size) @safe pure nothrow @nogc
{
    Handle[2] h;
    if (!b.any)
        return h;
    const r0 = b.firstRow - lift, r1 = b.lastRow - lift;
    const x0 = ox + b.firstCol * cw, x1 = ox + (b.lastCol + 1) * cw;
    h[0] = Handle(Rect(x0 - size, oy + (r0 + 1) * ch, size, size),
        Point(x0 + cw / 2, oy + r0 * ch + ch / 2), b.firstEnd, r0 >= 0 && r0 < rows);
    h[1] = Handle(Rect(x1, oy + (r1 + 1) * ch, size, size),
        Point(x1 - cw / 2, oy + r1 * ch + ch / 2), b.lastEnd, r1 >= 0 && r1 < rows);
    return h;
}

///
@("selection_menu.handlesOf.hangUnderTheEnds")
@safe pure nothrow @nogc unittest
{
    SelectionBounds b = {any: true, firstCol: 2, firstRow: 1, lastCol: 5, lastRow: 1};
    const h = handlesOf(b, 100, 200, 10, 10, 20, 0, 16);
    assert(h[0].drawing == Rect(104, 240, 16, 16) && h[0].anchor == Point(125, 230));
    assert(h[1].drawing == Rect(160, 240, 16, 16) && h[1].anchor == Point(155, 230));
    assert(h[0].shown && h[1].shown && h[0].end == SelectionEnd.start);
    // Lifted two rows, the start scrolled out of view.
    const l = handlesOf(b, 100, 200, 10, 10, 20, 2, 16);
    assert(!l[0].shown && !l[1].shown);
}

/**
How many rows a handle dragged `overshoot` pixels past the edge row scrolls
in `dt` seconds (`TSE3`): proportional to the overshoot, bounded; under
reduced motion one row at a time. `carry` keeps the fraction.
*/
int edgeScroll(int overshoot, int cellH, double dt, bool reducedMotion, ref double carry)
    @safe pure nothrow @nogc
{
    if (overshoot <= 0 || cellH <= 0)
    {
        carry = 0;
        return 0;
    }
    // Rows a second: 4 at the edge, 4 more per cell beyond it, at most 40;
    // reduced motion: 4 a second, a row at a time.
    double rate = reducedMotion ? 4 : 4 + 4.0 * overshoot / cellH;
    if (rate > 40)
        rate = 40;
    carry += rate * dt;
    const n = cast(int) carry;
    carry -= n;
    return reducedMotion && n > 1 ? 1 : n;
}

///
@("selection_menu.edgeScroll.proportionalAndBounded")
@safe pure nothrow @nogc unittest
{
    double carry = 0;
    assert(edgeScroll(0, 20, 1, false, carry) == 0);
    assert(edgeScroll(10, 20, 1, false, carry) == 6, "half a cell past: 6 rows a second");
    assert(edgeScroll(400, 20, 1, false, carry) == 40, "bounded");
    assert(edgeScroll(400, 20, 1, true, carry) == 1, "reduced motion: a row at a time");
    carry = 0;
    int rows;
    foreach (_; 0 .. 10)
        rows += edgeScroll(20, 20, 0.05, false, carry);
    assert(rows == 4, "fractions carry over frames");
}

import workspace_host : WorkspaceHost;

/**
The selection's chrome for one workspace: the long-press, the handles and
their drags, the menu and its actions (`TSE1`–`TSE7`). One instance per
embedder, at a fixed address (the menu points back at it).
*/
struct SelectionUi
{
    SelectionPlatform platform;
    /// `ui.selectionMenu` (`TCF11`).
    SelectionMenu style;
    /// A large screen — a tablet (`TCF14`): `auto` means the card there.
    bool largeScreen;
    /// The shortcut hints of the desktop menu (`TCF9`).
    string[MenuAction.max + 1] shortcuts;
    /// A handle's drawing and its touch target, in pixels (`TSE3`: the
    /// target at least 48 dp, larger than the drawing).
    int handlePx = 20, targetPx = 48;
    /// `ACC5`: edge scrolling steps a row at a time.
    bool reducedMotion;

    private WorkspaceHost* host;
    private PaneId pane;
    private ActionMenu menu;
    private Bridge bridge;
    private bool reopen;
    private string menuText, menuLink;
    private Handle[2] handles;
    // The contact (raw touch, `contact`).
    private bool down, onHandle, onMenu, dragging;
    private SelectionEnd dragEnd;
    private Point grab;
    private int swipeX0, swiped;
    private double carry = 0;
    // What to put on the clipboard at the next frame (the host's errand).
    private string pendingCopy;
    private bool copyPending;

    @disable this(this);

    /// The pane the selection is in, or null.
    TerminalView* view() @safe pure nothrow @nogc
        => host is null || pane == 0 ? null : host.pool.byId(pane);

    /// Whether the menu is up.
    bool menuShown() const @safe pure nothrow @nogc => menu !is null;

    /// Whether a handle is being dragged.
    bool draggingHandle() const @safe pure nothrow @nogc => dragging;

    // ── gestures ────────────────────────────────────────────────────────

    /**
    A long-press at pixel `p` of the pane area `area` (`TSE1`): selects the
    word — a URL whole — under it and shows the handles and the menu; on
    blank cells the menu offers what needs no selection. True when it was
    on a pane.
    */
    bool longPress(ref WorkspaceHost h, in Rect area, int cw, int ch, Point p) @system
    {
        host = &h;
        if (dragging)
            return true; // held still on a handle: still its drag
        int left, top;
        const id = h.paneAt(p.x, p.y, left, top);
        if (id == 0)
            return false;
        if (auto old = view())
            if (pane != id)
                old.clearSelection();
        pane = id;
        cast(void) h.ws.focusPane(id);
        auto tv = view();
        if (tv is null)
            return false;
        const col = (p.x - left) / cw, row = (p.y - top) / ch + tv.contentLift;
        cast(void) tv.selectAt(col, row, Granularity.word);
        showMenu();
        return true;
    }

    /**
    A tap no surface took (`TSE4`): on a handle or on the selection it shows
    the menu again; elsewhere it clears the selection and is not consumed
    (it still focuses and raises the keyboard). True when consumed.
    */
    bool tap(Point p) @system
    {
        auto tv = view();
        if (onHandle)
        {
            onHandle = false;
            if (tv !is null && tv.hasSelection)
                showMenu();
            return true;
        }
        if (tv is null || !tv.hasSelection)
            return false;
        if (selectionHit(p))
        {
            showMenu();
            return true;
        }
        tv.clearSelection();
        return false;
    }

    /**
    A drag that began at `began` (`TSE4`): one that began on a handle or on
    the menu is theirs (never a scroll); any other scrolls and keeps the
    selection, and dismisses the menu (`TSE6`). True when swallowed.
    */
    bool wheel(Point began) @system
    {
        if (onHandle || dragging || onMenu)
            return true;
        if (menu !is null)
            dismiss();
        return false;
    }

    /**
    The raw contact, every frame (a phone): `isDown` and where. A contact
    that begins on a handle drags it — cell by cell, the ends free to cross,
    the scrollback scrolling while it is held at the pane's top or bottom
    edge (`TSE3`); one that begins on the sheet's action row swipes it.
    */
    void contact(bool isDown, Point at, double dt, int cw, int ch) @system
    {
        auto tv = view();
        if (isDown && !down)
        {
            onHandle = onMenu = false;
            swipeX0 = at.x;
            swiped = 0;
            if (menu !is null && menu.layer.contains(at.x, at.y))
                onMenu = true;
            else if (tv !is null && tv.hasSelection)
                foreach (ref hd; handles)
                    if (hd.shown && near(hd, at))
                    {
                        onHandle = dragging = true;
                        dragEnd = hd.end;
                        grab = Point(at.x - hd.anchor.x, at.y - hd.anchor.y);
                        carry = 0;
                        if (menu !is null)
                        {
                            // The menu returns when the drag ends; the content
                            // stays where the finger found it.
                            keepLift = true;
                            dismiss();
                            keepLift = false;
                        }
                        break;
                    }
        }
        if (isDown && dragging && tv !is null)
            dragTo(*tv, Point(at.x - grab.x, at.y - grab.y), dt, cw, ch);
        if (isDown && onMenu && menu !is null && menu.presentation == Presentation.sheet)
        {
            const items = -(at.x - swipeX0) / (9 * (cw > 0 ? cw : 1));
            if (items != swiped)
            {
                menu.swipe(items - swiped);
                swiped = items;
                host.surfaces.changed = true;
            }
        }
        if (!isDown && down && dragging)
        {
            dragging = false;
            if (tv !is null && tv.hasSelection)
                showMenu();
        }
        down = isDown;
    }

    private bool near(in Handle hd, Point at) const @safe pure nothrow @nogc
    {
        const cx = hd.drawing.x + hd.drawing.width / 2, cy = hd.drawing.y + hd.drawing.height / 2;
        const r = targetPx / 2;
        return at.x >= cx - r && at.x < cx + r && at.y >= cy - r && at.y < cy + r;
    }

    private void dragTo(ref TerminalView tv, Point p, double dt, int cw, int ch) @system
    {
        const o = tv.paneOrigin;
        const rows = tv.s.rows;
        const topEdge = o.y + ch, bottomEdge = o.y + (rows - 1) * ch;
        if (p.y < topEdge)
            tv.scrollViewport(-edgeScroll(topEdge - p.y, ch, dt, reducedMotion, carry));
        else if (p.y >= bottomEdge)
            tv.scrollViewport(edgeScroll(p.y - bottomEdge + 1, ch, dt, reducedMotion, carry));
        else
            carry = 0;
        cast(void) tv.moveSelectionEnd(dragEnd, (p.x - o.x) / cw,
            (p.y < o.y ? 0 : (p.y - o.y) / ch) + tv.contentLift);
    }

    /// Whether pixel `p` is on the selection's visible text.
    private bool selectionHit(Point p) @system
    {
        auto tv = view();
        if (tv is null)
            return false;
        const b = tv.selectionBounds;
        const o = tv.paneOrigin;
        const cw = tv.s.cellWidth, ch = tv.s.cellHeight;
        if (!b.any || cw <= 0 || ch <= 0)
            return false;
        const col = (p.x - o.x) / cw, row = (p.y - o.y) / ch + tv.contentLift;
        if (row < b.firstRow || row > b.lastRow)
            return false;
        if (b.rectangular || b.firstRow == b.lastRow)
            return col >= b.firstCol && col <= b.lastCol;
        return (row > b.firstRow || col >= b.firstCol) && (row < b.lastRow || col <= b.lastCol);
    }

    /**
    A right-click at `p` on the desktop (`TSE7`, mockup X1): the menu at the
    pointer, clear of the selection. Not when the program tracks the mouse
    and Shift is not held — the click is the program's. True when shown.
    */
    bool rightClick(ref WorkspaceHost h, in Rect area, int cw, int ch, Point p, bool shift) @system
    {
        host = &h;
        int left, top;
        const id = h.paneAt(p.x, p.y, left, top);
        if (id == 0)
            return false;
        auto tv = h.pool.byId(id);
        if (tv is null || (tv.mouseTracking && !shift))
            return false;
        if (pane != id)
            if (auto old = view())
                old.clearSelection();
        pane = id;
        cast(void) h.ws.focusPane(id);
        pointer = p;
        // A right-click on a link, off the selection, offers the link's actions
        // (`TPR7`): the link becomes the selection.
        if (!selectionHit(p))
        {
            import sparkles.terminal_view.component : LinkSpan;

            LinkSpan link;
            const col = (p.x - left) / cw, row = (p.y - top) / ch;
            if (tv.linkAt(col, row, link) && tv.selectAt(link.startCol, link.row, Granularity.character))
                cast(void) tv.moveSelectionEnd(SelectionEnd.end, link.endCol, link.row);
        }
        showMenu();
        return true;
    }

    private Point pointer;

    // ── the menu ────────────────────────────────────────────────────────

    /// Shows the menu for the selection as it is now (replacing one shown).
    void showMenu() @system
    {
        auto tv = view();
        if (tv is null || host is null)
            return;
        if (menu !is null)
            dismiss();
        if (bridge is null)
            bridge = new Bridge(&this);

        menuText = tv.selectionText();
        MenuFacts f = menuText.length ? measure(menuText) : MenuFacts.init;
        f.canPaste = platform.clipboardHasText is null || platform.clipboardHasText();
        string[2] links;
        const n = tv.selectionHyperlinks(links[]);
        menuLink = singleLink(links[0 .. n < 2 ? n : 2], n, menuText);
        // Open URL only through the allow-list (`TPR6`): another scheme gets
        // Copy and Share, no Open.
        {
            import links : canOpen;

            version (Android)
                enum android = true;
            else
                enum android = false;
            if (menuLink.length && !canOpen(menuLink, host.linkSchemes, android))
                menuLink = null;
        }
        f.link = menuLink;
        f.canShare = platform.share !is null;
        f.canAutofill = platform.canAutofill !is null && platform.canAutofill();

        const p = !platform.touch ? Presentation.context
            : menuStyle(style, largeScreen) == SelectionMenu.card ? Presentation.card
            : menuStyle(style, largeScreen) == SelectionMenu.compact ? Presentation.compact
            : Presentation.sheet;
        menu = new ActionMenu(bridge, f, p);
        menu.shortcuts = shortcuts;
        menu.liftShown = tv.contentLift; // already said, when a drag kept it
        menu.pointer = pointer;
        menu.lift = (int rows) { liftTo(rows); };
        updateGeometry();
        host.surfaces.push(menu);
    }

    private void liftTo(int rows) @safe
    {
        if (auto tv = view())
            tv.liftContent(rows);
        if (host !is null)
            host.invalidate();
    }

    /// Closes the menu, if it is on top; the selection stays.
    void dismiss() @system
    {
        if (menu is null || host is null)
            return;
        if (host.surfaces.stack.length && host.surfaces.stack[$ - 1] is menu)
            host.surfaces.cancel(); // `menuClosed` follows
        else
            menuClosed();
    }

    private void menuClosed() @system
    {
        menu = null;
        if (!keepLift)
            liftTo(0);
    }

    private bool keepLift;

    private void perform(MenuAction a) @system
    {
        import std.conv : to;

        auto tv = view();
        if (tv is null)
            return;
        final switch (a)
        {
            case MenuAction.copy:
                pendingCopy = menuText;
                copyPending = true;
                tv.clearSelection();
                host.surfaces.toast("Copied " ~ describe(measure(menuText))
                    .replaceSelected);
                break;
            case MenuAction.paste:
                tv.clearSelection();
                tv.pasteClipboard();
                break;
            case MenuAction.selectAll:
                if (tv.selectAll())
                    reopen = true;
                break;
            case MenuAction.openUrl:
                if (menuLink.length)
                    host.open(menuLink);
                break;
            case MenuAction.share:
                if (platform.share !is null)
                    platform.share(menuText);
                break;
            case MenuAction.find:
                const r = tv.findSelection();
                host.surfaces.toast(r.total == 0 ? "Not found"
                    : r.total == 1 ? "The only match"
                    : "Match " ~ r.index.to!string ~ " of " ~ r.total.to!string);
                reopen = r.total > 0;
                break;
            case MenuAction.run:
                tv.clearSelection();
                cast(void) host.runInNewPane(menuText);
                break;
            case MenuAction.autofill:
                if (platform.autofill !is null)
                    platform.autofill();
                break;
            case MenuAction.more:
                break;
        }
    }

    // ── the embedders ───────────────────────────────────────────────────

    /// The desktop's setup: the right-click menu (X1) with the table's copy
    /// and paste chords, the clipboard read through raylib.
    void useDesktop(in TerminalConfig c, scope const Binding[] table) @system
    {
        platform.touch = false;
        platform.clipboardHasText = () {
            import raylib : GetClipboardText;

            const t = GetClipboardText();
            return t !is null && *t != 0;
        };
        style = c.ui.selectionMenu;
        shortcuts = shortcutsFrom(table);
    }

    /**
    The desktop's per-frame half (`TSE7`), before the workspace's frame: a
    right-click on a pane opens the menu at the pointer — Shift lets it
    through a program that tracks the mouse.
    */
    void pollDesktop(H)(ref H h, ref WorkspaceHost ws, in Rect area) @system
    {
        import raylib : GetMousePosition, IsKeyDown, IsMouseButtonPressed, KeyboardKey,
            MouseButton;

        frame(h, ws);
        if (!IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_RIGHT))
            return;
        auto c = h.canvas;
        const cw = c.fonts.cellW() > 0 ? c.fonts.cellW() : 1;
        const ch = c.fonts.cellH() > 0 ? c.fonts.cellH() : 1;
        const m = GetMousePosition();
        const shift = IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT) || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT);
        cast(void) rightClick(ws, area, cw, ch, Point(cast(int) m.x, cast(int) m.y), shift);
    }

    version (Android)
    {
        /// Android's setup: the touch menu as `ui.selectionMenu` says, the
        /// share sheet, the clipboard and autofill; 48 dp handle targets.
        void useAndroid(in TerminalConfig c) @system
        {
            import sparkles.android.activity : dpToPx;

            platform.touch = true;
            platform.clipboardHasText = () {
                import sparkles.android.clipboard : getClipboardText;

                return getClipboardText().length > 0;
            };
            platform.share = (string text) {
                import sparkles.android.intents : shareText;
                import sparkles.base.logger : warning;

                if (const err = shareText(text))
                    warning(i"terminal: share: $(err)");
            };
            platform.canAutofill = () {
                import sparkles.android.autofill : autofillAvailable;

                return autofillAvailable();
            };
            platform.autofill = () {
                import sparkles.android.autofill : requestPasswordAutofill;

                if (host !is null)
                    host.surfaces.toast(requestPasswordAutofill()
                        ? "Pick a password to type into the program"
                        : "Autofill is not available");
            };
            {
                import sparkles.android.autofill : autofillAvailable;

                cast(void) autofillAvailable(); // the first answer, early
            }
            style = c.ui.selectionMenu;
            {
                import sparkles.android.activity : isLarge = largeScreen;

                largeScreen = isLarge();
            }
            handlePx = dpToPx(20);
            targetPx = dpToPx(48);
        }

        /// The phone's per-frame half, before the workspace's frame: the
        /// raw contact (handle drags, the row's swipe) and `frame`.
        void pollTouch(H)(ref H h, ref WorkspaceHost ws) @system
        {
            import raylib : GetTouchPointCount, GetTouchPosition;

            frame(h, ws);
            const n = GetTouchPointCount();
            const p = n > 0 ? GetTouchPosition(0) : typeof(GetTouchPosition(0)).init;
            const cw = h.canvas.fonts.cellW(), ch = h.canvas.fonts.cellH();
            contact(n == 1, Point(cast(int) p.x, cast(int) p.y), h.frameSeconds,
                cw > 0 ? cw : 1, ch > 0 ? ch : 1);
            if (dragging || down && onMenu)
                ws.invalidate();
        }
    }

    // ── the frame ───────────────────────────────────────────────────────

    /**
    The per-frame half, before the workspace's frame: the clipboard errand,
    the menu after an action that keeps it (Select all, Find), and the
    selection's geometry for the menu's placement and the handles.
    */
    void frame(H)(ref H h, ref WorkspaceHost ws) @system
    {
        host = &ws;
        if (copyPending)
        {
            copyPending = false;
            static if (__traits(compiles, h.clipboard(pendingCopy)))
                h.clipboard(pendingCopy);
            pendingCopy = null;
        }
        auto tv = view();
        if (tv is null)
        {
            pane = 0;
            if (menu !is null)
                dismiss();
            handles = (Handle[2]).init;
            return;
        }
        if (reopen)
        {
            reopen = false;
            showMenu();
            // The selection moved (Find, Select all): the menu goes to it.
            if (menu !is null && menu.geo.box.width > 0)
                menu.pointer = pointer = Point(menu.geo.box.x, menu.geo.box.y);
        }
        // The program cleared the text away: the menu goes with it.
        if (menu !is null && menu.facts.chars > 0 && !tv.hasSelection)
            dismiss();
        updateGeometry();
    }

    private void updateGeometry() @system
    {
        auto tv = view();
        if (tv is null)
            return;
        const b = tv.selectionBounds;
        const o = tv.paneOrigin;
        const cw = tv.s.cellWidth, ch = tv.s.cellHeight;
        const rows = tv.s.rows, cols = tv.s.cols;
        const lift = tv.contentLift;
        handles = platform.touch ? handlesOf(b, o.x, o.y, rows, cw, ch, lift, handlePx)
            : (Handle[2]).init;
        // A handle at the pane's edge stays on it (a selection ending in the
        // last column).
        foreach (ref hd; handles)
        {
            const right = o.x + cols * cw;
            int x = hd.drawing.x;
            if (x + hd.drawing.width > right)
                x = right - hd.drawing.width;
            if (x < o.x)
                x = o.x;
            hd.drawing = Rect(x, hd.drawing.y, hd.drawing.width, hd.drawing.height);
        }
        if (menu is null)
            return;
        SelectionGeometry g;
        g.paneTop = o.y;
        g.cellH = ch;
        g.lift = lift;
        if (b.any)
        {
            int r0 = b.firstRow - lift, r1 = b.lastRow - lift;
            r0 = r0 < 0 ? 0 : r0;
            r1 = r1 >= rows ? rows - 1 : r1;
            if (r1 >= r0)
            {
                const single = r0 == r1 && b.firstRow == b.lastRow;
                const x0 = single || b.rectangular ? b.firstCol : 0;
                const x1 = single || b.rectangular ? b.lastCol + 1 : cols;
                g.box = Rect(o.x + x0 * cw, o.y + r0 * ch, (x1 - x0) * cw, (r1 - r0 + 1) * ch);
            }
            // Only an end on screen is kept above a sheet: one scrolled out of
            // view lifts nothing.
            if (b.lastRow - lift >= 0 && b.lastRow - lift < rows)
                g.bottom = o.y + (b.lastRow - lift + 1) * ch + (platform.touch ? handlePx : 0);
        }
        foreach (i, ref hd; handles)
            g.handles[i] = hd.shown ? hd.drawing : Rect.init;
        menu.geo = g;
    }

    /// Paints the handles (a phone), in `accent`.
    void paint(RgbColor accent) @system
    {
        import raylib : Color, DrawCircle, DrawRectangle;

        auto tv = view();
        if (!platform.touch || tv is null || !tv.hasSelection)
            return;
        const c = Color(accent.r, accent.g, accent.b, 255);
        foreach (i, ref hd; handles)
        {
            if (!hd.shown)
                continue;
            const r = hd.drawing.width / 2;
            const cx = hd.drawing.x + r, cy = hd.drawing.y + r;
            DrawCircle(cx, cy, r, c);
            // The square corner that points at the text: top-right for the
            // start's droplet, top-left for the end's (S2).
            DrawRectangle(i == 0 ? cx : hd.drawing.x, hd.drawing.y, r, r, c);
        }
    }
}

import sparkles.base.term_color : RgbColor;
import keymap : Binding, leaderMark, TermCommand, TermScope;
import settings : TerminalConfig;

/// The copy and paste chords of `table`, spelled as the desktop menu shows
/// them (X1, `TCF9`): `Ctrl+Shift+C`.
string[MenuAction.max + 1] shortcutsFrom(scope const Binding[] table) @safe
{
    import sparkles.ui.keymap_config : ChordPathOf, unparseChordPathAs;

    string[MenuAction.max + 1] s;
    foreach (ref b; table)
    {
        if (b.group.length || b.depth != 1 || b.scope_ != TermScope.pane)
            continue;
        const a = b.cmd == TermCommand.copy ? MenuAction.copy
            : b.cmd == TermCommand.paste ? MenuAction.paste : MenuAction.more;
        if (a == MenuAction.more || s[a].length)
            continue;
        ChordPathOf!leaderMark one;
        one.path[0] = b.path[0];
        s[a] = keyLabel(unparseChordPathAs!leaderMark(one));
    }
    return s;
}

/// `ctrl+shift+c` → `Ctrl+Shift+C`.
string keyLabel(string canonical) @safe pure
{
    import std.algorithm.searching : startsWith;
    import std.uni : toUpper;

    string s = canonical, out_;
    foreach (mod; ["ctrl+", "alt+", "shift+", "super+"])
        if (s.startsWith(mod) && s.length > mod.length)
        {
            out_ ~= mod[0 .. 1].toUpper ~ mod[1 .. $];
            s = s[mod.length .. $];
        }
    return out_ ~ (s.length == 1 ? s.toUpper : s.length ? s[0 .. 1].toUpper ~ s[1 .. $] : s);
}

///
@("selection_menu.shortcutsFrom.theTablesChords")
@safe unittest
{
    import keymap : defaultBindings;

    const s = shortcutsFrom(defaultBindings);
    assert(s[MenuAction.copy] == "Ctrl+Shift+C" && s[MenuAction.paste] == "Ctrl+Shift+V");
    assert(s[MenuAction.find] is null, "no binding, no hint");
    assert(keyLabel("ctrl+pageup") == "Ctrl+Pageup");
}

private string replaceSelected(string s) @safe pure nothrow
{
    enum tail = " selected";
    return s.length > tail.length && s[$ - tail.length .. $] == tail ? s[0 .. $ - tail.length] : s;
}

/// The menu's way back into the controller.
private final class Bridge : MenuHost
{
    private SelectionUi* ui;

    this(SelectionUi* ui) @safe pure nothrow @nogc
    {
        this.ui = ui;
    }

    void perform(MenuAction a) @system => ui.perform(a);
    void menuClosed() @system => ui.menuClosed();
    void note(string text) @safe
    {
        if (ui.host !is null)
            ui.host.surfaces.toast(text);
    }
}

version (unittest)
{
    private final class Recorder : MenuHost
    {
        MenuAction[] done;
        bool closed;
        string[] notes;

        void perform(MenuAction a) @system { done ~= a; }
        void menuClosed() @system { closed = true; }
        void note(string text) @safe { notes ~= text; }
    }

    private size_t[] hitIds(in Layer l) @safe pure nothrow
    {
        size_t[] ids;
        foreach (ref t; l.hits)
            ids ~= t.hitId;
        return ids;
    }

    private bool shows(in Layer l, string text) @safe pure nothrow
    {
        foreach (ref n; l.tree.nodes)
            if (n.text == text)
                return true;
        return false;
    }
}

@("selection_menu.ActionMenu.sheetRowSwipesAndEndsInMore")
@system unittest
{
    // A phone-sized pane: 40 columns, 2-row touch targets.
    SurfaceContext ctx = {area: Rect(0, 0, 400, 600), cellW: 10, cellH: 20, targetRows: 2,
        labels: ButtonLabels.iconText};
    auto r = new Recorder;
    auto m = new ActionMenu(r, MenuFacts(chars: 23, canPaste: true, canShare: true,
        canAutofill: true), Presentation.sheet);
    const l = m.placeIn(ctx);
    assert(l.y + l.bounds.height * 20 == 600, "along the bottom");
    assert(shows(l, "23 characters selected"));
    // 38 columns of row: four whole items and a cut one, which hits nothing.
    const ids = hitIds(l);
    assert(ids[0 .. 4] == [hitBase + MenuAction.copy, hitBase + MenuAction.paste,
        hitBase + MenuAction.selectAll, hitBase + MenuAction.share]);
    assert(shows(l, "Find"), "the fifth item shows, cut off");
    // Autofill is a row of its own.
    assert(ids[$ - 1] == hitBase + MenuAction.autofill);

    // Swiped to the end: the row ends in More, which lists what is hidden.
    m.swipe(10);
    const end = m.placeIn(ctx);
    assert(hitIds(end)[0 .. 4] == [hitBase + MenuAction.share, hitBase + MenuAction.find,
        hitBase + MenuAction.run, hitBase + MenuAction.more]);
    assert(!m.activate(hitBase + MenuAction.more) && m.listing, "More opens its list");
    const more = m.placeIn(ctx);
    assert(shows(more, "Copy") && shows(more, "Select all") && !shows(more, "Share"),
        "the items swiped out of view");

    // An action runs and closes the menu.
    assert(m.activate(hitBase + MenuAction.copy));
    assert(r.done == [MenuAction.copy] && r.closed);
}

@("selection_menu.ActionMenu.cardAnchorsOrFallsBackToASheet")
@system unittest
{
    SurfaceContext ctx = {area: Rect(0, 0, 400, 600), cellW: 10, cellH: 20, targetRows: 2};
    auto r = new Recorder;
    auto m = new ActionMenu(r, MenuFacts(chars: 4, canPaste: true, canShare: true),
        Presentation.card);
    m.geo.box = Rect(60, 400, 40, 20);
    m.geo.handles = [Rect(40, 420, 20, 20), Rect(100, 420, 20, 20)];
    m.geo.bottom = 440;
    m.geo.cellH = 20;
    const card = m.placeIn(ctx);
    assert(m.presentation == Presentation.card);
    assert(card.y + card.bounds.height * 20 <= 400, "above the selection, not over it");
    // B1: Copy, Paste, All, Find, then More holding Share and Run.
    assert(hitIds(card) == [hitBase + MenuAction.copy, hitBase + MenuAction.paste,
        hitBase + MenuAction.selectAll, hitBase + MenuAction.find, hitBase + MenuAction.more]);

    // A selection filling the pane: no room for a card — a sheet (B3), and
    // the content rises so the selection's end stays above it (B2).
    int lifted = -1;
    m.lift = (int rows) { lifted = rows; };
    m.geo.box = Rect(0, 40, 400, 520);
    m.geo.handles = [Rect.init, Rect(380, 560, 20, 20)];
    m.geo.bottom = 580;
    const sheet = m.placeIn(ctx);
    assert(m.presentation == Presentation.sheet);
    assert(shows(sheet, "4 characters selected · no room for a card, shown as a sheet"));
    assert(lifted > 0 && 580 - lifted * 20 <= sheet.y, "the end handle above the sheet");
    assert(r.notes.length == 1, "and a note says so");
    // The next frame sees the content lifted: the lift holds, no second note.
    const first = lifted;
    m.geo.lift = lifted;
    m.geo.bottom = 580 - lifted * 20;
    cast(void) m.placeIn(ctx);
    assert(lifted == first && r.notes.length == 1);

    // Compact: icon-only.
    auto c = new ActionMenu(r, MenuFacts(chars: 4), Presentation.compact);
    c.geo.box = Rect(60, 400, 40, 20);
    c.geo.cellH = 20;
    const pill = c.placeIn(ctx);
    assert(shows(pill, "⧉") && !shows(pill, "Copy"));
}

@("selection_menu.ActionMenu.desktopMenuGroupsShortcutsAndKeys")
@system unittest
{
    SurfaceContext ctx = {area: Rect(0, 0, 960, 560), cellW: 10, cellH: 20};
    auto r = new Recorder;
    auto m = new ActionMenu(r, MenuFacts(chars: 8, canPaste: true, link: "https://ex.org"),
        Presentation.context);
    m.shortcuts[MenuAction.copy] = "Ctrl+Shift+C";
    m.pointer = Point(240, 170);
    m.geo.box = Rect(100, 160, 230, 20);
    const l = m.placeIn(ctx);
    assert(l.y >= 180, "below the selection's row");
    assert(shows(l, "⧉ Copy") && shows(l, "Ctrl+Shift+C"));
    assert(hitIds(l) == [hitBase + MenuAction.copy, hitBase + MenuAction.paste,
        hitBase + MenuAction.selectAll, hitBase + MenuAction.find, hitBase + MenuAction.run,
        hitBase + MenuAction.more]);
    // Arrow keys move the highlight; Enter runs it.
    KeyEvent down;
    down.key = Key.down;
    assert(m.key(down));
    assert(m.confirm() && r.done == [MenuAction.paste]);
}
