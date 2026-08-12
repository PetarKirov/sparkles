/**
Everything the gallery knows, as $(B one value).

Every field is a Regular value advanced by transformation — `s.focus =
s.focus.next(order)`, never `s.focus.moveNext()` — because that is what the
toolkit's state level is for (`docs/specs/ui/state-machines.md`) and what makes
the recorded tests able to script an event sequence and then assert on the
result. A page never owns state; it reads this and returns a subtree.

Hit ids are allocated from named bases rather than ad-hoc constants, so two
regions cannot mint the same id and a page's ids do not renumber when another
page grows.
*/
module state;

import sparkles.input : InputCapabilities;
import sparkles.ui.geometry : Size;
import sparkles.ui.components.scroll_view : ScrollbarAnim, ScrollView;
import sparkles.ui.components.dock : DockContainer;
import sparkles.ui.components.tree_view : TreeViewState;
import sparkles.ui.state : CaptureState, DisclosureState, FocusState,
    HoverState, PressState, Selection, SplitState, Timeline;
import sparkles.ui.theme : Theme;
import sparkles.ui.themes : builtinThemes;
import sparkles.ui.widget : Alignment, Visibility;
import sparkles.ui.wrap : TextWrap;
import sparkles.ui_app.backend : Backend;

@safe:

/**
The built-in themes in a $(B fixed order), by their canonical names.

`builtinThemes` is an associative array carrying alias spellings
(`tokyonight` beside `tokyo-night`), so it is neither ordered nor one entry per
theme — and a browser that cycles with `]` needs both. This is the catalog's
ordering, stated once.
*/
static immutable string[] themeNames = [
    "one-dark-pro", "dracula", "nord", "monokai",
    "github-dark", "github-light", "github-dark-dimmed",
    "tokyo-night", "solarized-dark", "solarized-light",
    "catppuccin-mocha", "catppuccin-macchiato", "catppuccin-frappe",
    "catppuccin-latte", "gruvbox-dark-hard", "gruvbox-light-hard",
    "ayu-dark", "ayu-light", "ayu-mirage",
    "rose-pine", "rose-pine-moon", "rose-pine-dawn",
    "night-owl", "night-owl-light", "everforest-dark", "everforest-light",
    "synthwave-84", "kanagawa-wave", "vesper", "poimandres",
    "min-dark", "min-light", "material-theme-darker", "material-theme-lighter",
    "dark-plus", "light-plus",
];

/// Which half of the shell the keyboard is driving. Tab moves between them, so
/// a terminal with no mouse reaches everything.
enum Region : ubyte
{
    nav,     /// the page list
    content, /// the page itself
}

/**
Hit-id bases, one per region that mints ids.

Spread far enough apart that a region can grow without colliding, and non-zero
throughout — `hitId == 0` means "not hit-testable" in the toolkit, so a base of
zero would silently disarm a whole region.
*/
enum size_t hitNav = 1000;      /// the sidebar's page rows: `hitNav + pageIndex`
enum size_t hitTheme = 3000;    /// the theme browser's rows
enum size_t hitTabs = 4000;     /// the components page's tab strip
enum size_t hitActions = 5000;  /// the components page's action bar
enum size_t hitTree = 6000;     /// the tree page's rows
enum size_t hitContentBar = 7000; /// the shell's content-pane scrollbar
enum size_t hitDemoBar = 7100;    /// the Scrolling page's specimen bar
enum size_t hitChromeBar = 7200;  /// the Components page's live scroll view
enum size_t hitInspBar = 7300;    /// the inspector panel's scrollbar
enum size_t hitSplit = 8000;    /// the split page's divider
enum size_t hitDock = 8100;     /// the dock page's live container
enum size_t hitMachines = 9000; /// the state-machine page's tiles
enum size_t hitTermActions = 10000; /// the Terminal page's action bar (3 ids)
enum size_t hitTermBar = 10050;     /// the terminal pane's scrollback bar
/**
The Terminal page's pane (`+ 0`) and its per-tab $(B lanes): select is
`hitTerminal + 2·id`, close is `hitTerminal + 2·id + 1`. Tab ids mint
monotonically forever, so this base is the $(B last) one and owns everything
above it — with the old layout the 101st spawn would have collided with the
action bar. Ids start at 1, so the `+ 0` slot can never name a tab.
*/
enum size_t hitTerminal = 10100;

/// Element keys (`Widget.key`) for state that must survive a rebuild.
enum size_t keyContentScroll = 101; ///
enum size_t keyNavScroll = 102;     ///
enum size_t keyTermPane = 103;      /// the Terminal page's pane rect, for `paint`
enum size_t keyInspScroll = 104;    /// the inspector panel's viewport

/// The Layout page's live knobs.
struct LayoutDemo
{
    int widthMode;      /// 0 fit · 1 grow · 2 fixed · 3 percent
    int fixedCells = 12; /// the `fixed`/`percent` value
    Alignment alignX;   ///
    Alignment alignY;   ///
    int gap = 1;        ///
    int padding = 1;    ///
    Visibility third;   /// the third band's visibility — hidden vs collapsed
}

/// The Text page's live knobs.
struct TextDemo
{
    int width = 34;         /// the wrap column
    TextWrap wrap = TextWrap.greedy; /// highlighted mode (all three are shown)
    int hangIndent = 2;     ///
}

/// The Tracks page's live knobs.
struct TracksDemo
{
    size_t preset;  /// index into the page's own spec presets
    int avail = 48; /// the width the tracks are resolved against
}

/// The Tree page's live state: the shared interaction layer
/// (`sparkles.ui.components.tree_view`), keyed by the arena index — the demo
/// tree is static, so the index IS the node's identity.
struct TreeDemo
{
    TreeViewState!uint tv; ///
    alias tv this;         /// ditto
}

/// The state-machine page's live tiles.
struct MachinesDemo
{
    Selection!int selection;    ///
    Timeline pulse;             ///
    CaptureState capture;       ///
    DisclosureState!size_t folds; ///
}

/// The most terminal tabs the page will hold at once.
enum size_t maxTerms = 8;

/**
One terminal tab, as the $(B page) sees it: identity, liveness, label. The
`TerminalView` instance itself lives outside this value — it is non-copyable
and pointer-pinned — keyed by `id`, which is minted once and never reused, so
a tab's hit id (`hitTerminal + id`) survives its neighbours closing.
*/
struct TermTab
{
    uint id;             /// stable identity; 0 = empty slot
    bool exited;         /// the shell ended (held per the exit policy)
    int exitStatus = -1; /// meaningful once `exited`
    char[24] label = ' '; /// OSC title, truncated — else "shell N"
    ubyte labelLen;      ///

    /// The label as text.
    const(char)[] labelText() const scope return pure nothrow @nogc
        => label[0 .. labelLen];

    /// Overwrites the label, truncating at the buffer.
    void setLabel(scope const(char)[] text) scope pure nothrow @nogc
    {
        const n = text.length < label.length ? text.length : label.length;
        label[0 .. n] = text[0 .. n];
        labelLen = cast(ubyte) n;
    }
}

/**
The Terminal page's tab strip, VSCode-shaped: spawn appends and activates,
close compacts $(B without renumbering identities), and the keyboard-capture
flag decides whether the shell or the pty owns the keys. Spawning itself —
a pty, a process — cannot happen here (pages are pure views over state), so
the page raises `spawnRequested`/`closeRequested` and the component's frame
glue consumes them.
*/
struct TermsState
{
    TermTab[maxTerms] tabs; ///
    size_t count;           /// `tabs[0 .. count]` are present
    size_t active;          /// index into the live prefix
    bool focused;           /// exclusive keyboard capture is on
    bool keepExited;        /// the exit-policy toggle: hold clean exits too
    uint nextId = 1;        /// monotonic — ids are never reused
    bool spawnRequested;    /// the page asked for a new terminal
    int closeRequested = -1; /// tab index to close, -1 for none
    ushort paneCols;        /// the pane rect at the last paint, in cells —
    ushort paneRows;        /// next frame's grid follow reads it
    ushort paneX;           /// …and its origin, for pane-relative pointer
    ushort paneY;           /// forwarding (the wheel has no frames in hand)
    long sbTotal;           /// the active tab's scrollback: history + screen,
    long sbLen;             /// the viewport's rows,
    long sbOffset;          /// and its offset — mirrored so the page can draw

    /// Whether any tab exists / another one fits.
    bool any() const scope pure nothrow @nogc => count > 0;
    /// ditto
    bool full() const scope pure nothrow @nogc => count >= maxTerms;

    /// Appends and activates a tab, minting its identity. Returns the new
    /// tab's id, or 0 when the strip is full.
    uint spawn() scope pure nothrow @nogc
    {
        if (full)
            return 0;
        auto t = TermTab(id: nextId++);
        char[16] buf = void;
        const n = labelOf(buf, "shell ", t.id);
        t.setLabel(buf[0 .. n]);
        tabs[count] = t;
        active = count;
        count++;
        return t.id;
    }

    /// Removes the tab at `i`, compacting the prefix — every surviving tab
    /// keeps its id (and so its hit id). The active tab follows its slot;
    /// closing the last tab drops keyboard capture with it.
    void close(size_t i) scope pure nothrow @nogc
    {
        if (i >= count)
            return;
        foreach (j; i .. count - 1)
            tabs[j] = tabs[j + 1];
        count--;
        tabs[count] = TermTab.init;
        if (active > i || active >= count)
            active = active > 0 ? active - 1 : 0;
        if (count == 0)
            focused = false;
    }

    /// Moves the active tab by `dir` (±1), wrapping.
    void cycle(int dir) scope pure nothrow @nogc
    {
        if (count < 2)
            return;
        active = (active + count + (dir < 0 ? count - 1 : 1)) % count;
    }
}

private size_t labelOf(scope char[] buf, string prefix, uint n) @safe pure nothrow @nogc
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeInteger;

    SmallBuffer!(char, 24) w;
    w ~= prefix;
    writeInteger(w, n);
    const len = w[].length < buf.length ? w[].length : buf.length;
    buf[0 .. len] = w[][0 .. len];
    return len;
}

/// The whole application, as one value.
struct GalleryState
{
    // ── navigation ──────────────────────────────────────────────────────────
    size_t page;      /// index into `registry.pages`
    Region region = Region.nav; /// which half the keyboard drives
    bool helpOpen;    /// the `?` overlay
    bool inspectorOpen; /// the `|` side panel — the showing page, inspected
    /// The inspector panel's tree state: disclosure (default: everything
    /// open — the dump-it-all spirit) + the click-selected row, keyed by
    /// the inspected tree's arena index.
    TreeViewState!uint insp = TreeViewState!uint(
        DisclosureState!uint.allOpen);

    // ── theming ─────────────────────────────────────────────────────────────
    size_t themeIndex = 7; /// `tokyo-night` — the shared default (`CLI3`)

    // ── shared machines ─────────────────────────────────────────────────────
    FocusState focus;    ///
    HoverState hover;    ///
    PressState press;    ///
    CaptureState capture; ///
    /// The page's height at the last measurement, so a key handler — which has
    /// no builder — can clamp against the same number the thumb came from.
    int contentRows;
    Timeline toast;      /// the transient "theme: nord" notice
    string toastText;    /// ditto
    bool hasFrameClock;  /// ditto — see `toastConfigFor`

    // ── page-local ──────────────────────────────────────────────────────────
    LayoutDemo layoutDemo;   ///
    TextDemo textDemo;       ///
    TracksDemo tracksDemo;   ///
    TreeDemo treeDemo;       ///
    MachinesDemo machines;   ///
    SplitState split = SplitState(24); ///
    /// The Dock page's live container: a sidebar beside a tabbed group of
    /// two documents. Its own, so dragging a tab here cannot disturb the
    /// shell's own panes.
    DockContainer dock;
    size_t themeListTop;     /// first visible row of the theme browser
    size_t componentsTab;    /// the Components page's active tab
    size_t componentsAction = size_t.max; /// …and its last activated segment
    /// The Scrolling page's own viewport — a second `ScrollView` over a
    /// second document, so a reader can grab one without the other moving.
    ScrollView demoView = ScrollView(
        vAnim: ScrollbarAnim(percent: 0), hAnim: ScrollbarAnim(percent: 0));
    /// The Components page's live `scrollView` specimen — the third one, for
    /// the same reason the Scrolling page has its own.
    ScrollView chromeView = ScrollView(
        vAnim: ScrollbarAnim(percent: 0), hAnim: ScrollbarAnim(percent: 0));
    /**
    The terminal pane's scrollback bar. The machine gives the bar its grab,
    capture arbitration and hover-expand easing — but ghostty owns the real
    offset, so each frame the shell applies this machine's intent as a
    viewport delta and mirrors the truth back (`syncTerminals`).
    */
    ScrollView termView = ScrollView(
        vAnim: ScrollbarAnim(percent: 0), hAnim: ScrollbarAnim(percent: 0));
    /// The panel body's height at the last measurement — `contentRows`'s twin,
    /// for the same reason: the clamp and the thumb must share one number.
    int inspectorRows;
    TermsState terms;        /// the Terminal page's tab strip
    /// `--term-tab-glyphs`: the mini tab list's position glyphs, one grapheme
    /// per position. Empty = the circled-number series (or ASCII digits when
    /// the theme says no unicode).
    string termTabGlyphs;

    // ── what the dock arranged ──────────────────────────────────────────────
    /**
    The side panes' widths $(B as arranged) — the dock container owns the
    extents (and their drag), the shell mirrors them here each frame so the
    pages' pure views can read a width without knowing a dock exists. They
    start at the nominal widths and keep their last value while a pane is
    hidden, so a pane comes back at the width it was dragged to.
    */
    int navCols = navWidth;
    /// ditto
    int inspCols = inspectorWidth;

    // ── what the host told us ───────────────────────────────────────────────
    Size surface = Size(80, 24); ///
    Backend backend;             ///
    InputCapabilities caps;      ///

    /// The theme every slot on every page resolves against.
    ref immutable(Theme) theme() const scope
        => builtinThemes[themeNames[themeIndex]];

    /// The active theme's name, for the header.
    string themeName() const scope => themeNames[themeIndex];

    /// `true` iff the target can hover — the one predicate that gates every
    /// pointer-only affordance. Consulted where an affordance is $(I drawn), so
    /// a bar that is not drawn is automatically not hit-testable.
    bool pointerAffordances() const scope => caps.hover;

    /// The content pane's height in rows, given the shell's chrome. One
    /// definition, because the scroll clamp and the viewport must agree.
    int contentHeight() const scope
    {
        const h = surface.height - shellChromeRows;
        return h > 1 ? h : 1;
    }

    /**
    Whether the page list is showing.

    Below the threshold the sidebar is more than a third of the surface and the
    catalog becomes unreadable, so it yields — the pages are still reachable by
    `←`/`→` and by number, which is why hiding it costs nothing. A reader who
    wants it back on a narrow terminal presses `n`.

    The inspector panel counts against the width: on a surface that cannot
    carry both, the sidebar yields first — the panel was asked for explicitly
    just now, the sidebar merely defaults on. A pin still outranks the panel.
    */
    bool navVisible() const scope
        => navPinned || surface.width
            - (inspectorVisible ? inspectorWidth + 1 : 0) >= navMinSurface;

    /// ditto — `n` forces the sidebar on regardless of width.
    bool navPinned;

    /**
    Whether the inspector panel is showing: toggled open $(B and) wide enough.

    The same yield-below-a-threshold shape as the sidebar, and the two resolve
    without circularity because the panel defers to the $(I pin), not to
    `navVisible`: an explicitly pinned sidebar keeps its cells and the panel
    waits for a wider surface.
    */
    bool inspectorVisible() const scope
        => inspectorOpen && surface.width
            - (navPinned ? navWidth + 1 : 0) >= inspectorMinSurface;

    /**
    The content pane's width: the surface less the sidebar, the inspector
    panel, the gaps beside them, and the scroll gutter.

    The gutter is subtracted $(B whether or not) a scrollbar is showing. A pane
    that widened when its content happened to fit would reflow every paragraph
    the moment a page crossed the scroll threshold — text jumping sideways as
    you scroll into it is worse than one permanently unused column.
    */
    int contentWidth() const scope
    {
        const w = surface.width - (navVisible ? navCols + 1 : 0)
            - (inspectorVisible ? inspCols + 1 : 0) - scrollGutter;
        return w > 8 ? w : 8;
    }
}

/// The rows the shell's own chrome occupies: header, footer, and the blank
/// separator between the body and the footer.
enum int shellChromeRows = 3;

/// The sidebar's width in cells.
enum int navWidth = 22;

/// The columns reserved beside the content for the scrollbar: the bar itself
/// and one cell of separation. Always reserved — see `GalleryState.contentWidth`.
enum int scrollGutter = 2;

/// The narrowest surface that still carries the sidebar. Below it the list
/// yields the width — see `GalleryState.navVisible`.
enum int navMinSurface = 60;

/// The inspector panel's width in cells — `navWidth`'s opposite number, sized
/// for a dump line rather than a page title.
enum int inspectorWidth = 42;

/// The narrowest surface (after a pinned sidebar's cells) that still carries
/// the inspector panel — see `GalleryState.inspectorVisible`. At exactly this
/// width the content pane keeps 15 cells, which is cramped but legible.
/// (The visibility thresholds stay in terms of the $(B nominal) widths even
/// though the dock lets a reader drag the real ones — a threshold that moved
/// with the drag would make a pane vanish by being widened.)
enum int inspectorMinSurface = 60;

/// The dock's drag floors: no divider drag squeezes a pane below these.
enum int navMinCols = 12;
/// ditto — the page keeps a readable column whatever the side panes do.
enum int contentMinCols = 24;
/// ditto
enum int inspMinCols = 24;

/**
How long a toast holds — which depends on whether the target has a frame clock.

A window paces frames and can time the notice out. A terminal wakes on input
and reports `frameSeconds == 0`, so a timed hold there would never elapse and
the toast would stay up forever. `holdUntilDismissed` is the machine's own name
for that case: the next event ends it. One notice, two targets, no timer
invented for the target that has none.
*/
Timeline.Config toastConfigFor(bool hasFrameClock) @safe pure nothrow @nogc
    => hasFrameClock
        ? Timeline.Config(holdMs: 1500)
        : Timeline.Config(holdUntilDismissed: true);

@("ui_gallery.state.themeNamesAreCanonicalAndComplete")
@safe unittest
{
    // Every name resolves, and none is an alias spelling of another entry —
    // a browser that cycled through aliases would show `tokyo-night` twice.
    assert(themeNames.length == 36);
    bool[string] seen;
    foreach (n; themeNames)
    {
        const t = n in builtinThemes;
        assert(t !is null, "themeNames must name a built-in: " ~ n);
        assert(t.name !in seen, "a theme appears twice: " ~ t.name);
        seen[t.name] = true;
    }
}

@("ui_gallery.state.defaultThemeMatchesTheSharedDefault")
@safe unittest
{
    // The gallery starts on the same theme every other application does
    // (`CLI3`), so `--theme` with no argument is not a surprise.
    import sparkles.ui_app.gui_options : defaultTheme;

    const s = GalleryState.init;
    assert(s.themeName == defaultTheme);
    assert(s.theme.name == "tokyo-night");
}

@("ui_gallery.state.paneGeometryIsClampedNotNegative")
@safe unittest
{
    // A terminal can be smaller than the chrome. The panes must stay positive
    // rather than handing the layout engine a negative extent.
    GalleryState s;
    s.surface = Size(10, 2);
    assert(s.contentHeight >= 1);
    assert(s.contentWidth >= 8);

    s.surface = Size(120, 40);
    assert(s.contentHeight == 40 - shellChromeRows);
    assert(s.contentWidth == 120 - navWidth - 1 - scrollGutter);
}

@("ui_gallery.state.inspectorAndSidebarShareTheWidthWithoutOverflow")
@safe unittest
{
    // The two side panels resolve against each other without circularity, and
    // in every combination the content pane keeps a positive width — the
    // overflow this rules out: pin + panel on a narrow surface pushing the
    // body row past the right edge.
    GalleryState s;
    s.inspectorOpen = true;

    // Wide: both show.
    s.surface = Size(120, 40);
    assert(s.navVisible && s.inspectorVisible);
    assert(s.contentWidth == 120 - (navWidth + 1) - (inspectorWidth + 1)
        - scrollGutter);

    // The conventional terminal: the panel shows and the sidebar yields to it.
    s.surface = Size(80, 24);
    assert(s.inspectorVisible && !s.navVisible);
    assert(s.contentWidth == 80 - (inspectorWidth + 1) - scrollGutter);

    // A pinned sidebar outranks the panel.
    s.navPinned = true;
    assert(s.navVisible && !s.inspectorVisible);
    s.navPinned = false;

    // Below the threshold the panel yields entirely; toggled "open" is kept,
    // so widening the surface brings it back without another keypress.
    s.surface = Size(50, 24);
    assert(!s.inspectorVisible && s.inspectorOpen);
}

@("ui_gallery.state.terms.idsAreMonotonicAndNeverReused")
@safe pure nothrow @nogc unittest
{
    // Closing a tab must not renumber the rest — hit ids are hitTerminal +
    // id, and a press resolved against last frame's tree must land on the
    // same tab this frame.
    TermsState t;
    assert(t.spawn() == 1 && t.spawn() == 2 && t.spawn() == 3);
    assert(t.count == 3 && t.active == 2);

    t.close(0);
    assert(t.count == 2);
    assert(t.tabs[0].id == 2 && t.tabs[1].id == 3, "surviving ids unchanged");

    // A fresh spawn continues the sequence — id 1 is spent forever.
    assert(t.spawn() == 4);
}

@("ui_gallery.state.terms.activeFollowsItsTabAcrossCloses")
@safe pure nothrow @nogc unittest
{
    TermsState t;
    cast(void) t.spawn();
    cast(void) t.spawn();
    cast(void) t.spawn();

    // Closing before the active slot shifts it left with its tab…
    t.active = 1;
    t.close(0);
    assert(t.active == 0 && t.tabs[t.active].id == 2);

    // …and closing the last tab clamps rather than dangles.
    t.active = 1;
    t.close(1);
    assert(t.active == 0 && t.count == 1);

    // The last close drops keyboard capture with the tab it was aimed at.
    t.focused = true;
    t.close(0);
    assert(t.count == 0 && !t.focused);
}

@("ui_gallery.state.terms.spawnFillsAndStopsAtTheCap")
@safe pure nothrow @nogc unittest
{
    TermsState t;
    foreach (i; 0 .. maxTerms)
        assert(t.spawn() != 0);
    assert(t.full);
    assert(t.spawn() == 0, "a full strip refuses, not overwrites");
    assert(t.tabs[0].labelText == "shell 1");
    assert(t.tabs[maxTerms - 1].labelText[0 .. 6] == "shell ");
}

@("ui_gallery.state.terms.cycleWraps")
@safe pure nothrow @nogc unittest
{
    TermsState t;
    cast(void) t.spawn();
    cast(void) t.spawn();
    cast(void) t.spawn();
    t.active = 2;
    t.cycle(1);
    assert(t.active == 0, "forward wraps");
    t.cycle(-1);
    assert(t.active == 2, "backward wraps");
    t.close(1);
    t.close(1);
    t.cycle(1);
    assert(t.active == 0, "a single tab does not move");
}

@("ui_gallery.state.hitBasesDoNotCollide")
@safe pure nothrow @nogc unittest
{
    // Every base is non-zero (zero means "not hit-testable") and they are
    // ordered with room to grow — an overlap would let a press on one region
    // activate an affordance in another.
    // Ascending, non-zero, and never equal. The gap is a thousand except
    // between the two scrollbars, which are a hundred apart because they are
    // one kind of thing and neither will ever mint more than one id.
    static immutable size_t[] bases = [hitNav, hitTheme, hitTabs, hitActions,
        hitTree, hitContentBar, hitDemoBar, hitChromeBar, hitInspBar, hitSplit,
        hitMachines, hitTermActions, hitTermBar, hitTerminal];
    foreach (i, b; bases)
    {
        assert(b != 0);
        if (i > 0)
            assert(b > bases[i - 1]);
    }
}
