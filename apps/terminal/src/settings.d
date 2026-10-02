/**
The configuration schema (`TCF1`, docs/specs/terminal/config.md): one D
aggregate, `TerminalConfig`, whose JSON form is what `sparkles:wired` makes of
it. A field's name, type and default are declared here and nowhere else — the
config file, `terminal config show`, the starter file and the settings page
all reflect this declaration.

Sections are in the order a user meets them; the settings page shows fields
in declaration order (`TSP7`), so reordering a struct reorders the page.

Enum members are wire vocabulary (wired serialises them by name). A value
spelled with a keyword (`auto`) carries a `@WireName` instead of leaking an
underscore into every config file.

NOTE: no module-level `@safe:` — wired's decode/encode infers `@system` for
aggregates, and the templates instantiated against this schema must stay free
to infer.
*/
module settings;

import sparkles.metadata : Description, Label, Range;
import sparkles.wired.overlay : WireSection;
import sparkles.wired.policy : WireName;

import extra_keys : defaultExtraKeysSpec;

// ─────────────────────────────────────────────────────────────────────────────
// Closed domains.
// ─────────────────────────────────────────────────────────────────────────────

/// `TCF7`: when the extra-keys row shows.
enum ExtraKeysVisibility : ubyte
{
    /// While the soft keyboard is shown; hidden with a hardware keyboard.
    @WireName("auto") automatic,
    /// Always.
    always,
    /// Never.
    never,
}

/// `TSS1`: what a pane does when its program exits.
enum OnExit : ubyte
{
    /// Close on status 0, prompt otherwise.
    promptOnFailure,
    /// Always prompt (rerun, shell, close).
    prompt,
    /// Always close.
    close,
    /// Keep the screen with a status line.
    hold,
}

/// `TPR5`: what a tap (or long-press) on a link does.
enum LinkAction : ubyte
{
    /// Highlight it and confirm before opening.
    confirm,
    /// Open at once.
    open,
    /// Nothing: the gesture falls through.
    off,
}

/// `TPR19`: when a paste is confirmed first.
enum PasteConfirm : ubyte
{
    /// A paste containing a line break, outside bracketed paste.
    multiline,
    /// Every paste.
    always,
    /// Never.
    never,
}

/// `TPR21`: how an OSC 52 clipboard read is answered.
enum ClipboardRead : ubyte
{
    /// Ask: once, always for this pane, or deny.
    ask,
    /// Answer.
    allow,
    /// Answer nothing.
    deny,
}

/// `TPR9`: when a notification becomes a system notification.
enum NotifyWhen : ubyte
{
    /// Only when its pane is not being seen.
    unseen,
    /// Always.
    always,
    /// Never (the log still records it).
    never,
}

/// `TCF9`: how buttons and menu items are labelled.
enum ButtonLabels : ubyte
{
    /// Icon and text.
    iconText,
    /// Text only.
    text,
    /// Icon only (the text stays the accessible name).
    icon,
}

/// `TCF10`: how confirmations over a pane are presented.
enum OverlayStyle : ubyte
{
    /// A card anchored at its subject (a sheet when no place fits).
    anchored,
    /// A bottom sheet.
    sheet,
}

/// `TCF11`: the touch selection menu.
enum SelectionMenu : ubyte
{
    /// A bottom sheet with a swipeable action row.
    sheet,
    /// An anchored card of labelled actions.
    card,
    /// An anchored pill of icon-only actions.
    compact,
}

/// `TCF12`: what opens the tab and pane tree.
enum TabsOpener : ubyte
{
    /// The pill on a phone in portrait, the rail otherwise.
    @WireName("auto") automatic,
    /// A pill naming the current tab.
    pill,
    /// A rail of tab icons.
    rail,
}

/// `TCF13`: how panes are marked and labelled.
enum PaneChrome : ubyte
{
    /// No chrome; a pane's header shows on hover or tap.
    reveal,
    /// A one-line header on every pane.
    header,
    /// A frame with the title in its border.
    framed,
}

/// `TDV2`: where a file opened from a pane appears.
enum OpenTarget : ubyte
{
    /// A new tab.
    tab,
    /// A split to the right of the requesting pane.
    splitRight,
    /// A split below it.
    splitDown,
    /// The platform's own handler.
    external,
}

// ─────────────────────────────────────────────────────────────────────────────
// Platform defaults (declared once, here).
// ─────────────────────────────────────────────────────────────────────────────

version (Android)
    /// The font the APK bundles (falling back to Android's own monospace).
    enum defaultFontFamily = "FiraCodeNerdFontMono";
else
    /// fontconfig's monospace on the desktop.
    enum defaultFontFamily = "monospace";

// ─────────────────────────────────────────────────────────────────────────────
// Sections.
// ─────────────────────────────────────────────────────────────────────────────

/// ditto
@WireSection
struct FontConfig
{
    @Description("Font path, family name or fontconfig-style preference list.")
    string family = defaultFontFamily;

    @Description("Font size in points.")
    @Range(6, 72, 1)
    int size = 13;

    @Description("Family for the bold face; empty derives it from the primary.")
    string bold;

    @Description("Family for the italic face; empty derives it from the primary.")
    string italic;

    @Description("Family for the bold-italic face; empty derives it from the primary.")
    @Label("bold italic")
    string boldItalic;

    @Description("Codepoint routes: RANGE[,RANGE...]=FAMILY per entry.")
    @Label("codepoint map")
    string[] codepointMap;

    @Description("Directories searched for fonts instead of fontconfig.")
    @Label("font directories")
    string[] fontDir;
}

/// One colour scheme: `#rrggbb` (or `#rgb`) strings; an empty entry keeps the
/// emulator's own colour for that slot.
@WireSection
struct SchemeColors
{
    @Description("Default text colour.")
    string foreground;

    @Description("Default background colour.")
    string background;

    @Description("Cursor colour.")
    string cursor;

    @Description("The 16-colour palette, color0 to color15.")
    string[] palette;
}

/// The built-in dark scheme (Catppuccin Mocha).
enum SchemeColors builtinDark = SchemeColors(
    foreground: "#cdd6f4",
    background: "#1e1e2e",
    cursor: "#f5e0dc",
    palette: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7",
        "#94e2d5", "#bac2de", "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
        "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"],
);

/// The built-in light scheme (Catppuccin Latte).
enum SchemeColors builtinLight = SchemeColors(
    foreground: "#4c4f69",
    background: "#eff1f5",
    cursor: "#dc8a78",
    palette: ["#5c5f77", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb",
        "#179299", "#acb0be", "#6c6f85", "#d20f39", "#40a02b", "#df8e1d",
        "#1e66f5", "#ea76cb", "#179299", "#bcc0cc"],
);

/// ditto
@WireSection
struct ColorsConfig
{
    @Description("The scheme used while the system is dark.")
    SchemeColors dark = builtinDark;

    @Description("The scheme used while the system is light.")
    SchemeColors light = builtinLight;
}

/// ditto
@WireSection
struct Appearance
{
    FontConfig font;
    ColorsConfig colors;

    @Description("Switch between the dark and light schemes with the system.")
    @Label("follow system")
    bool followSystem = true;

    @Description("A built-in theme for the app's own chrome; empty derives it from the terminal colours.")
    @Label("chrome theme")
    string chromeTheme;
}

/// ditto
@WireSection
struct ExtraKeysConfig
{
    @Description("When the extra-keys row shows: auto, always or never.")
    ExtraKeysVisibility visible = ExtraKeysVisibility.automatic;

    @Description("The rows of keys, in Termux's extra-keys syntax.")
    string layout = defaultExtraKeysSpec;
}

/// ditto
@WireSection
struct Behaviour
{
    @Description("What a pane does when its program exits.")
    @Label("on exit")
    OnExit onExit = OnExit.promptOnFailure;

    @Description("Scrollback lines kept per pane; -1 keeps everything, 0 none.")
    @Range(-1, 10_000_000, 1000)
    long scrollback = -1;

    @Description("Reopen the last session's tabs, splits and directories at start.")
    bool restore = true;
}

/// ditto
@WireSection
struct LinksConfig
{
    @Description("What a tap on a link does: confirm, open or off.")
    LinkAction tap = LinkAction.confirm;

    @Description("What a long-press on a link does: confirm, open or off (off selects).")
    @Label("long press")
    LinkAction longPress = LinkAction.off;

    @Description("URI schemes Open may launch, beyond http, https and mailto.")
    string[] schemes;
}

/// ditto
@WireSection
struct PasteConfig
{
    @Description("When a paste is confirmed first: multiline, always or never.")
    PasteConfirm confirm = PasteConfirm.multiline;
}

/// ditto
@WireSection
struct Osc52Config
{
    @Description("Let programs set the clipboard (OSC 52).")
    bool write = true;

    @Description("Whether programs may read the clipboard: ask, allow or deny.")
    ClipboardRead read = ClipboardRead.ask;
}

/// ditto
@WireSection
struct ClipboardConfig
{
    @Label("OSC 52")
    Osc52Config osc52;
}

/// One grouping rule of the notification log (`TPG18`): the first rule whose
/// set fields all match assigns its group.
struct NotificationGroupRule
{
    @Description("Foreground program names, separated by |.")
    string app;

    @Description("A working-directory glob.")
    string cwd;

    @Description("A tab-title glob.")
    string tab;

    @Description("The group a matching notification falls in.")
    string group;
}

/// ditto
@WireSection
struct NotificationsConfig
{
    @Description("Turn program notifications (OSC 9, 99, 777) into toasts and system notifications.")
    bool enabled = true;

    @Description("When a notification reaches the system: unseen, always or never.")
    NotifyWhen when = NotifyWhen.unseen;

    @Description("The notification log's grouping rules, first match wins.")
    NotificationGroupRule[] groups;
}

/// ditto
@WireSection
struct LanternConfig
{
    @Description("Show the key guide while a chord sequence is pending.")
    bool enabled = true;

    @Description("Milliseconds before the guide appears; 0 shows it at once.")
    @Label("delay (ms)")
    @Range(0, 5000, 50)
    int delayMs = 400;

    @Description("The chord that opens the guide on the desktop.")
    string leader = "ctrl+shift+space";
}

/// ditto
@WireSection
struct UiConfig
{
    @Description("How buttons are labelled: iconText, text or icon.")
    @Label("button labels")
    ButtonLabels buttonLabels = ButtonLabels.iconText;

    @Description("Confirmations as an anchored card or a bottom sheet.")
    @Label("overlay style")
    OverlayStyle overlayStyle = OverlayStyle.anchored;

    @Description("The touch selection menu: sheet, card or compact.")
    @Label("selection menu")
    SelectionMenu selectionMenu = SelectionMenu.sheet;

    @Description("What opens the tab and pane tree: auto, pill or rail.")
    @Label("tabs opener")
    TabsOpener tabsOpener = TabsOpener.automatic;

    @Description("How panes are marked: reveal, header or framed.")
    @Label("pane chrome")
    PaneChrome paneChrome = PaneChrome.reveal;
}

/// ditto
@WireSection
struct OpenConfig
{
    @Description("Where a file opened from a pane appears: tab, splitRight, splitDown or external.")
    OpenTarget target = OpenTarget.tab;

    @Description("Answer xdg-open in the terminal's sessions (desktop).")
    bool intercept = true;
}

/// The whole configuration (`TCF1`). `TerminalConfig.init` is the defaults
/// layer.
struct TerminalConfig
{
    Appearance appearance;
    @Label("extra keys")
    ExtraKeysConfig extraKeys;
    Behaviour behaviour;
    LinksConfig links;
    PasteConfig paste;
    ClipboardConfig clipboard;
    NotificationsConfig notifications;
    LanternConfig lantern;
    @Label("interface")
    UiConfig ui;
    @Label("opening files")
    OpenConfig open;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("settings.TerminalConfig.roundTripsThroughWired")
@system unittest
{
    import sparkles.wired.json : fromJSON, toJSON;

    auto text = toJSON(TerminalConfig.init);
    assert(!text.hasError, text.error.toString);
    auto back = fromJSON!TerminalConfig(text.value[]);
    assert(!back.hasError, back.error.toString);
    assert(back.value == TerminalConfig.init);
}

@("settings.TerminalConfig.keywordMembersKeepTheirSpelling")
@system unittest
{
    import std.algorithm.searching : canFind;

    import sparkles.wired.json : fromJSON, toJSON;

    auto text = toJSON(TerminalConfig.init);
    assert(text.value[].canFind(`"visible":"auto"`), text.value[]);
    assert(text.value[].canFind(`"tabsOpener":"auto"`), text.value[]);

    auto r = fromJSON!ExtraKeysConfig(`{"visible":"never","layout":"[]"}`);
    assert(!r.hasError, r.error.toString);
    assert(r.value.visible == ExtraKeysVisibility.never);
}
