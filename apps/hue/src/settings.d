/**
The configuration schema (`CFG1`): `HueConfig` is a plain D aggregate, and
JSON is its surface via `sparkles:wired` — there is no second place where a
field's name, type or default is written. Adding a setting is adding a field.

Three consumers read this one declaration:

$(LIST
    * the config file layering (`settings_load.d`), which decodes each layer
        into the derived sparse overlay (`settings_overlay.d`) and merges;
    * `hue config show/write/save` (`settings_io.d`), whose origin listing,
        commented starter file and sparse rewrite all render from it;
    * the settings pane, whose `PropertyTree!HueConfig` reads the
        `@Label`/`@Doc`/`@Range` metadata this module attaches — `@Doc`
        doubles as the starter file's comment text, `@Range` as the pane's
        edit bounds.
)

Defaults are the field initialisers — `HueConfig.init` IS the defaults layer
(`CFG2`), and every value here matches what the code hard-coded before the
schema existed, so introducing the file changed no behavior.

Enum-typed fields serialize by member name (wired's default), so the member
identifiers below are wire vocabulary: never spell one `auto_` — a keyword
dodge would leak the underscore into every config file (use `detect`).

NOTE: no module-level `@safe:` — wired's decode/encode walk infers `@system`
for aggregates, and the serde templates instantiated against this schema must
stay free to infer.
*/
module settings;

import sparkles.ui.property_tree : Doc, Label, Range;

import ansi_model : BackgroundMode;
import diff_structural : StructuralPolicy;
import diff_view : DiffLayout;
import viewer_model : ScrollAnchorMode;

import sparkles.diff.normalize : WhitespaceMode;
import sparkles.ui.components.lantern_view : Placement;
import sparkles.ui_app.gui_options : defaultFontSizePoints, defaultGuiFont,
    defaultGuiFontFamily, defaultTheme, defaultWindowCols, defaultWindowRows,
    uiuaCodepointMap;

// ─────────────────────────────────────────────────────────────────────────────
// Marker UDAs the layering machinery keys on.
// ─────────────────────────────────────────────────────────────────────────────

/// Marks a struct-typed field as a config section: the derived sparse overlay
/// (`settings_overlay.d`) recurses into it instead of treating it as a leaf.
enum ConfigSection;

/**
Marks a list-valued field whose layers $(B compose) instead of override
(`CFG14`, `CFG20`): a higher layer's entries are searched $(B first), then the
lower layers', then the built-in default — so a user can shadow a bundled
grammar with a newer build of it. Scalar fields follow `CFG2`'s
higher-layer-wins rule; this is the documented exception.
*/
enum Compose;

// ─────────────────────────────────────────────────────────────────────────────
// New closed-domain enums (CLI strings become members; wire name = identifier).
// ─────────────────────────────────────────────────────────────────────────────

/// `CFG5`: what an interactive view opens as for a markdown document.
enum DefaultView : ubyte
{
    /// The decorated markdown preview.
    preview,
    /// Highlighted raw source.
    raw,
}

/// `CFG5`: how a selection over a ` ```ansi ` block copies (`--ansi-copy`).
enum AnsiCopyMode : ubyte
{
    /// Escape sequences included, verbatim.
    raw,
    /// ANSI-stripped plain text.
    strip,
}

/// `CFG5`: how a table grid selection copies (`--table-copy`). The CLI spells
/// the first member `auto`; the wire name is the honest `detect`.
enum TableCopyMode : ubyte
{
    /// Source for DSV documents, TSV otherwise.
    detect,
    /// Tab-separated values.
    tsv,
    /// A markdown table.
    markdown,
    /// The DSV dialect's own source text.
    source,
}

// ─────────────────────────────────────────────────────────────────────────────
// CFG3 — appearance.
// ─────────────────────────────────────────────────────────────────────────────

/// ditto
@ConfigSection
struct Fonts
{
    @Doc("GUI font preference list, fontconfig-style: first match wins.")
    string family = defaultGuiFont;

    @Doc("Family for the bold face.")
    string bold = defaultGuiFontFamily;

    @Doc("Family for the italic face.")
    string italic = defaultGuiFontFamily;

    @Doc("Family for the bold-italic face.")
    @Label("bold italic")
    string boldItalic = defaultGuiFontFamily;

    @Doc("Font size in points; resolved against the display's real density.")
    @Range(6, 72, 1)
    int size = defaultFontSizePoints;

    @Doc("Codepoint-routing entries: RANGE[,RANGE...]=FAMILY per element.")
    @Label("codepoint map")
    string[] codepointMap = [uiuaCodepointMap];

    @Doc("Extra directories to search for font files.")
    @Label("font directories")
    string[] fontDir;
}

/// ditto
@ConfigSection
struct Window
{
    @Doc("Initial window width, in cells of the loaded font.")
    @Range(20, 500, 1)
    int width = defaultWindowCols;

    @Doc("Initial window height, in cells of the loaded font.")
    @Range(10, 200, 1)
    int height = defaultWindowRows;
}

/// `CFG3`: theme, background mode, the font faces, the window.
@ConfigSection
struct Appearance
{
    @Doc("Colour theme, by name (see `hue theme --list`).")
    string theme = defaultTheme;

    @Doc("How the theme background paints in a terminal: noBackground, spans, or full.")
    BackgroundMode background = BackgroundMode.full;

    @Doc("Group the theme cycle by light/dark.")
    @Label("group themes")
    bool groupThemes = true;

    Fonts fonts;
    Window window;
}

// ─────────────────────────────────────────────────────────────────────────────
// CFG4 — panes.
// ─────────────────────────────────────────────────────────────────────────────

/// ditto
@ConfigSection
struct TreePane
{
    @Doc("Explorer pane width in cells.")
    @Range(12, 120, 1)
    int width = 32;

    @Doc("Explorer glob(s) to always show.")
    string[] include;

    @Doc("Explorer glob(s) to hide.")
    string[] exclude;
}

/// ditto
@ConfigSection
struct ViewerPane
{
    @Doc("Show the file line-number gutter.")
    @Label("line numbers")
    bool lineNumbers = true;

    @Doc("GUI: number the lines inside each code block.")
    @Label("code line numbers")
    bool codeLineNumbers = true;

    @Doc("Gutter channels: 'all', 'none', or a comma-separated list of numbers, icons, coverage.")
    string gutter = "all";

    @Doc("Tab stops in the raw source view: a tab advances to the next multiple of this many columns.")
    @Label("tab width")
    @Range(1, 16, 1)
    int tabWidth = 4;

    @Doc("Render whitespace visibly in the raw view, vim's 'list' style.")
    @Label("list whitespace")
    bool listWhitespace = false;

    @Doc("Code-block line overflow: 'scroll', 'wrap', or 'wrap-at:N'.")
    @Label("code overflow")
    string codeOverflow = "scroll";

    @Doc("A code block taller than this many lines gets a fixed-height viewport (-1 auto, 0 disables).")
    @Label("code max lines")
    @Range(-1, 10_000, 1)
    int codeMaxLines = -1;

    @Doc("Table overflow: 'scroll', 'wrap', or 'wrap-at:N'.")
    @Label("table overflow")
    string tableOverflow = "scroll";

    @Doc("A table taller than this many interior lines gets a fixed-height viewport (-1 auto, 0 disables).")
    @Label("table max lines")
    @Range(-1, 10_000, 1)
    int tableMaxLines = -1;
}

/// `CFG4`: the explorer tree and the document viewer.
@ConfigSection
struct Panes
{
    TreePane tree;
    ViewerPane viewer;

    @Doc("Inspector pane width in cells.")
    @Label("inspector width")
    @Range(20, 120, 1)
    int inspectorWidth = 40;
}

// ─────────────────────────────────────────────────────────────────────────────
// CFG5 / CFG14 / CFG21 — behaviour.
// ─────────────────────────────────────────────────────────────────────────────

/// ditto
@ConfigSection
struct Behaviour
{
    @Doc("What an interactive view opens as for markdown: preview or raw.")
    @Label("default view")
    DefaultView defaultView = DefaultView.preview;

    @Doc("How a selection over an ansi block copies: raw or strip.")
    @Label("ansi copy")
    AnsiCopyMode ansiCopy = AnsiCopyMode.raw;

    @Doc("How a table grid selection copies: detect, tsv, markdown, or source.")
    @Label("table copy")
    TableCopyMode tableCopy = TableCopyMode.detect;

    @Doc("What a re-layout keeps at the top of the pane: segment or line.")
    @Label("scroll anchor")
    ScrollAnchorMode scrollAnchor = ScrollAnchorMode.segment;

    @Doc("Live D type overlays in the interactive views.")
    @Label("live types")
    bool liveTypes = true;

    @Doc("Additional tree-sitter grammar directories, searched before the environment's and the bundle (CFG14: layers compose).")
    @Label("grammar paths")
    @Compose
    string[] grammarPaths;

    @Doc("Default output directory for `hue gallery`.")
    @Label("gallery output")
    string galleryOut;
}

// ─────────────────────────────────────────────────────────────────────────────
// CFG15 — diff.
// ─────────────────────────────────────────────────────────────────────────────

/// ditto
@ConfigSection
struct DiffSettings
{
    @Doc("Diff layout: unified or split.")
    DiffLayout layout = DiffLayout.unified;

    @Doc("Whitespace difference mode: exact, trailing, change, or all.")
    @Label("ignore whitespace")
    WhitespaceMode ignoreWhitespace = WhitespaceMode.exact;

    @Doc("Grammar-aware structural diff: off, automatic, on, or view.")
    StructuralPolicy structural = StructuralPolicy.automatic;

    @Doc("Diff rendered markdown documents instead of raw source.")
    bool preview = false;

    @Doc("Context lines around each hunk.")
    @Range(0, 32, 1)
    int context = 3;

    @Doc("Similarity floor for pairing a removed line with an added one (0..1).")
    @Label("pair similarity")
    @Range(0, 1, 0.05)
    double minPairSimilarity = 0.4;

    @Doc("Myers scale guard: give up on line diffs beyond this edit distance.")
    @Label("max edit distance")
    @Range(64, 65_536, 64)
    int maxEditDistance = 1024;
}

// ─────────────────────────────────────────────────────────────────────────────
// CFG18 — lantern (the which-key guide).
// ─────────────────────────────────────────────────────────────────────────────

/// ditto
@ConfigSection
struct LanternSettings
{
    @Doc("Show the key guide at all.")
    bool enabled = true;

    @Doc("Milliseconds a prefix must dwell before the guide reveals — the difference between a guide that teaches and one that interrupts.")
    @Label("delay (ms)")
    @Range(0, 5000, 50)
    int delayMs = 200;

    @Doc("Guide placement: classic (full-width bottom) or helix (bottom-right panel).")
    Placement placement = Placement.classic;

    @Doc("Leader key chord (empty = the compiled default, space).")
    string leader;
}

// ─────────────────────────────────────────────────────────────────────────────
// CFG19 — picker.
// ─────────────────────────────────────────────────────────────────────────────

/// ditto
@ConfigSection
struct PickerSettings
{
    @Doc("Visible result rows (also the ranking top-K capacity).")
    @Range(4, 64, 1)
    int rows = 16;

    @Doc("Per-frame search budget in milliseconds.")
    @Label("step budget (ms)")
    @Range(1, 33, 1)
    int stepBudgetMs = 4;

    @Doc("Preview load debounce in milliseconds.")
    @Label("load delay (ms)")
    @Range(0, 2000, 25)
    int loadDelayMs = 150;

    @Doc("Dwell before expensive preview overlays engage, in milliseconds.")
    @Label("overlay delay (ms)")
    @Range(0, 10_000, 100)
    int overlayDelayMs = 2000;

    @Doc("Frecency store location (empty = the state-dir default; the store is machine-managed, the setting exists to relocate it).")
    @Label("frecency path")
    string frecencyPath;
}

// ─────────────────────────────────────────────────────────────────────────────
// CFG20 — format preview.
// ─────────────────────────────────────────────────────────────────────────────

/// One opt-in external formatter (`FPR4`'s trust boundary): named, scoped to
/// languages, spawned with exactly this argv.
struct ExternalFormatter
{
    @Doc("Registry name the --formatter flag selects.")
    string name;

    @Doc("Languages this formatter handles.")
    string[] languages;

    @Doc("Command line; the source arrives on stdin, the result on stdout.")
    string[] argv;
}

/// ditto
@ConfigSection
struct FormatSettings
{
    @Doc("Start interactive views in the in-memory format preview.")
    bool preview = false;

    @Doc("Ruler column for the format preview (0 = discover from .editorconfig).")
    @Range(0, 300, 1)
    int width = 0;

    @Doc("Preferred formatter name; a miss lists the candidates.")
    string formatter;

    @Doc("Opt-in external formatter table (CFG20: layers compose).")
    @Compose
    ExternalFormatter[] external;
}

// ─────────────────────────────────────────────────────────────────────────────
// Timing / scroll / limits — the hard-coded-constant sections (tier 2/3).
// ─────────────────────────────────────────────────────────────────────────────

/// Cadences and animation durations the code previously hard-coded.
@ConfigSection
struct TimingSettings
{
    @Doc("Live-types oracle poll tick, in milliseconds.")
    @Label("live tick (ms)")
    @Range(8, 200, 1)
    int liveTickMs = 33;

    @Doc("GUI frame-rate target.")
    @Label("target fps")
    @Range(1, 240, 5)
    int targetFps = 60;

    @Doc("Copy-flash hold, in milliseconds.")
    @Label("copy flash (ms)")
    @Range(0, 10_000, 100)
    int copyFlashMs = 1200;

    @Doc("Toast hold, in milliseconds.")
    @Label("toast (ms)")
    @Range(0, 10_000, 100)
    int toastMs = 1600;

    @Doc("Hover-underline fade-in, in milliseconds.")
    @Label("hover fade (ms)")
    @Range(0, 5000, 50)
    int hoverFadeMs = 300;

    @Doc("Frames a resize must settle before the expensive relayout runs.")
    @Label("resize debounce (frames)")
    @Range(0, 60, 1)
    int resizeDebounceFrames = 4;

    @Doc("Git status cache lifetime, in seconds.")
    @Label("git status ttl (s)")
    @Range(1, 300, 1)
    int gitStatusTtlSecs = 5;
}

/// Scroll, wheel and pointer-gesture behavior.
@ConfigSection
struct ScrollSettings
{
    @Doc("Horizontal cells per keystroke scroll.")
    @Label("horizontal step")
    @Range(1, 40, 1)
    int hScrollStep = 8;

    @Doc("Lines per mouse-wheel notch.")
    @Label("wheel lines")
    @Range(1, 10, 1)
    int wheelLinesPerNotch = 3;

    @Doc("Cells from a pane edge where a drag starts autoscrolling.")
    @Label("autoscroll band")
    @Range(1, 10, 1)
    int autoScrollBand = 3;

    @Doc("Peak autoscroll rate, in rows per second.")
    @Label("autoscroll rate")
    @Range(10, 240, 10)
    int autoScrollRate = 60;

    @Doc("Cells a dock-divider drag must travel before it engages.")
    @Label("drag threshold")
    @Range(0, 10, 1)
    int dragThreshold = 2;

    @Doc("Touch slop in pixels: movement below this stays a tap.")
    @Label("touch slop (px)")
    @Range(2, 48, 1)
    int gestureSlopPx = 12;

    @Doc("Long-press threshold, in milliseconds.")
    @Label("long press (ms)")
    @Range(100, 2000, 50)
    int longPressMs = 500;
}

/// Scale guards: ceilings that keep degenerate inputs from freezing a view.
@ConfigSection
struct LimitsSettings
{
    @Doc("Structural diff: per-side ceiling in KiB before it degrades to line diff.")
    @Label("structural max side (KiB)")
    @Range(64, 8192, 64)
    int structuralMaxSideKiB = 512;

    @Doc("Structural diff: token ceiling per side.")
    @Label("structural max tokens")
    @Range(10_000, 2_000_000, 10_000)
    int structuralMaxTokens = 200_000;

    @Doc("Structural diff: tree depth ceiling.")
    @Label("structural max depth")
    @Range(32, 4096, 32)
    int structuralMaxDepth = 512;

    @Doc("Format preview cache budget, in MiB.")
    @Label("format cache (MiB)")
    @Range(1, 512, 1)
    int formatCacheMiB = 32;

    @Doc("DSV grid: per-column width cap in cells.")
    @Label("dsv column cap")
    @Range(8, 512, 8)
    int dsvColumnCapCells = 64;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reserved sections.
// ─────────────────────────────────────────────────────────────────────────────

/// `CFG16` (tier 3): the host → forge-adapter map and per-forge token sources.
@ConfigSection
struct ForgeSettings
{
}

/// `CFG6`: the user keybinding overlay. Filled by `keymap_config.d`; an empty
/// struct decodes `{}` cleanly until then.
@ConfigSection
struct KeysSettings
{
}

// ─────────────────────────────────────────────────────────────────────────────
// The root.
// ─────────────────────────────────────────────────────────────────────────────

/// `CFG1`: the whole of hue's persistent configuration, one aggregate.
struct HueConfig
{
    Appearance appearance;
    Panes panes;
    Behaviour behaviour;

    DiffSettings diff;
    LanternSettings lantern;
    PickerSettings picker;
    FormatSettings format;
    TimingSettings timing;
    ScrollSettings scroll;
    LimitsSettings limits;
    ForgeSettings forges;
    KeysSettings keys;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests. `@system`: wired's native decode walk infers `@system` for a
// recursive aggregate (the arena view is pointer-based).
// ─────────────────────────────────────────────────────────────────────────────

@("settings.HueConfig.jsonRoundTrip")
@system unittest
{
    import sparkles.wired.json : fromJSON, toJSON;

    HueConfig c;
    c.appearance.theme = "builtin-dark";
    c.appearance.background = BackgroundMode.spans;
    c.appearance.fonts.size = 13;
    c.panes.tree.exclude = ["result", "result-*"];
    c.panes.viewer.tabWidth = 8;
    c.behaviour.tableCopy = TableCopyMode.markdown;
    c.behaviour.grammarPaths = ["/opt/grammars"];
    c.diff.layout = DiffLayout.split;
    c.diff.minPairSimilarity = 0.55;
    c.lantern.placement = Placement.helix;
    c.format.external = [ExternalFormatter("dfmt", ["d"], ["dfmt", "--stdin"])];
    c.timing.targetFps = 120;

    auto text = toJSON(c);
    assert(!text.hasError);
    auto back = fromJSON!HueConfig(text.value[]);
    assert(!back.hasError, back.error.toString);
    assert(back.value == c);
}

@("settings.enums.wireNamesRoundTrip")
@system unittest
{
    import std.meta : AliasSeq;
    import sparkles.wired.json : fromJSON, toJSON;

    // Every enum member's wire spelling must round-trip: these identifiers
    // are config-file vocabulary, and a keyword-dodging member name (`auto_`)
    // would leak its underscore into every user's file. The reused enums'
    // spellings are pinned here too, because a rename there is silently a
    // config-format break.
    static foreach (E; AliasSeq!(BackgroundMode, DefaultView, AnsiCopyMode,
        TableCopyMode, StructuralPolicy, DiffLayout, WhitespaceMode,
        ScrollAnchorMode, Placement))
    {
        static foreach (m; __traits(allMembers, E))
        {{
            enum v = __traits(getMember, E, m);
            auto text = toJSON(v);
            assert(!text.hasError);
            assert(text.value[] == '"' ~ m ~ '"',
                E.stringof ~ "." ~ m ~ " spelled " ~ text.value[].idup);
            assert(fromJSON!E(text.value[]).value == v);
        }}
    }
}

@("settings.HueConfig.unknownKeysTolerated")
@system unittest
{
    import sparkles.wired.json : fromJSON, toJSON;

    // Forward compatibility: an older hue reading a newer config ignores the
    // keys it does not know.
    HueConfig c;
    auto full = toJSON(c);
    assert(!full.hasError);
    auto text = full.value[].idup;
    // Splice an unknown key into the root object.
    auto spliced = `{"futureSection":{"x":1},` ~ text[1 .. $];
    auto back = fromJSON!HueConfig(spliced);
    assert(!back.hasError, back.error.toString);
    assert(back.value == c);
}
