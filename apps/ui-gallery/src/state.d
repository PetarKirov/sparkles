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
import sparkles.ui.scroll_view : ScrollbarAnim, ScrollView;
import sparkles.ui.state : CaptureState, DisclosureState, FocusState,
    HoverState, PressState, ScrollState, Selection, SplitState, Timeline;
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
enum size_t hitSplit = 8000;    /// the split page's divider
enum size_t hitMachines = 9000; /// the state-machine page's tiles

/// Element keys (`Widget.key`) for state that must survive a rebuild.
enum size_t keyContentScroll = 101; ///
enum size_t keyNavScroll = 102;     ///

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

/// The Tree page's live state.
struct TreeDemo
{
    uint selected = 1;                 /// the selected node's arena index
    DisclosureState!uint open;         /// which nodes are expanded
}

/// The state-machine page's live tiles.
struct MachinesDemo
{
    Selection!int selection;    ///
    Timeline pulse;             ///
    CaptureState capture;       ///
    DisclosureState!size_t folds; ///
}

/// The whole application, as one value.
struct GalleryState
{
    // ── navigation ──────────────────────────────────────────────────────────
    size_t page;      /// index into `registry.pages`
    size_t lastPage;  /// the page the Inspector dumps (the previously viewed one)
    Region region = Region.nav; /// which half the keyboard drives
    bool helpOpen;    /// the `?` overlay

    // ── theming ─────────────────────────────────────────────────────────────
    size_t themeIndex = 7; /// `tokyo-night` — the shared default (`CLI3`)

    // ── shared machines ─────────────────────────────────────────────────────
    FocusState focus;    ///
    HoverState hover;    ///
    PressState press;    ///
    CaptureState capture; ///
    /**
    The content pane's scrolling, whole.

    A `ScrollView` rather than a `ScrollState`: the offset is the least of what
    a scrollbar is, and an application that keeps only the offset has silently
    given up the grab, the hover, the capture arbitration and the easing. The
    animation starts at the idle width rather than the type's px-shaped default
    of four.
    */
    ScrollView contentView = ScrollView(
        vAnim: ScrollbarAnim(1.0f), hAnim: ScrollbarAnim(1.0f));
    /// The page's height at the last measurement, so a key handler — which has
    /// no builder — can clamp against the same number the thumb came from.
    int contentRows;
    ScrollState navScroll;     ///
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
    size_t themeListTop;     /// first visible row of the theme browser
    size_t componentsTab;    /// the Components page's active tab
    size_t componentsAction = size_t.max; /// …and its last activated segment
    /// The Scrolling page's own viewport — a second `ScrollView` over a
    /// second document, so a reader can grab one without the other moving.
    ScrollView demoView = ScrollView(
        vAnim: ScrollbarAnim(1.0f), hAnim: ScrollbarAnim(1.0f));
    int inspectorLines = 40; /// how much of a dump the Inspector builds

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
    */
    bool navVisible() const scope
        => navPinned || surface.width >= navMinSurface;

    /// ditto — `n` forces the sidebar on regardless of width.
    bool navPinned;

    /**
    The content pane's width: the surface less the sidebar, the gap between
    them, and the scroll gutter.

    The gutter is subtracted $(B whether or not) a scrollbar is showing. A pane
    that widened when its content happened to fit would reflow every paragraph
    the moment a page crossed the scroll threshold — text jumping sideways as
    you scroll into it is worse than one permanently unused column.
    */
    int contentWidth() const scope
    {
        const w = surface.width - (navVisible ? navWidth + 1 : 0) - scrollGutter;
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
        hitTree, hitContentBar, hitDemoBar, hitSplit, hitMachines];
    foreach (i, b; bases)
    {
        assert(b != 0);
        if (i > 0)
            assert(b > bases[i - 1]);
    }
}
