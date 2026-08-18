/**
The gallery's keyboard policy as $(B data) — one table, read both ways.

The shell used to describe its keymap three times: an `onKey` waterfall in
`gallery.d`, a hand-maintained help table in the overlay, and per-page
`keys` prose in the registry — with nothing keeping the three consistent.
This module is the one declaration
($(REF Binding, sparkles,ui,keymap) rows over the gallery's own command and
scope enums): `commandFor` resolves keys, `bindingsAt` feeds the help panel
and the status bar, and a collision is a test failure instead of a source
read.

$(B Scopes are the routing.) Declaration order is precedence
(`docs/specs/ui/keymap.md` `KEY2`): the help overlay is a modal scope
(`FOC4` — while it shows, `reachable` answers `false` for everything below,
so `q` closes the overlay instead of quitting); each interactive page has a
scope reachable only while it shows $(I and) the keyboard is in the content
region (the old "page gets first refusal" rule, now row order); the shell's
own keys sit last. The terminal pane's capture is not a scope at all — it is
a $(REF KeyGrab, sparkles,ui,focus) checked before resolution, with the
release chords and the scrollback pass-through as data.
*/
module keymap;

import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.focus : GrabPolicy;
import ui_keymap = sparkles.ui.keymap;
public import sparkles.ui.keymap : Chord, chord, chordRange,
    hidesLaterScopes, maxPathLength, ModeReq, ResolveKind, sameKey, ShiftReq,
    terminalScope;

/// The gallery's binding row, resolution result, and resolved command.
alias Binding = ui_keymap.Binding!(GalleryCommand, GalleryScope);
/// ditto
alias Resolution = ui_keymap.Resolution!GalleryCommand;
/// ditto
alias KeyCommand = ui_keymap.KeyCommand!GalleryCommand;

/// What the gallery should do. `none` means "not bound here". Names describe
/// the effect; the page prefix names the only page whose dispatch answers it.
enum GalleryCommand : ubyte
{
    none,

    // The shell.
    quit,
    showHelp, helpClose,
    regionToggle,      /// `Tab` — page list ⇄ page
    enterContent,      /// `Enter` / `Space` from the list
    moveDown, moveUp,  /// within the focused region
    pagePrev, pageNext,
    pageJump,          /// `1`–`9`, `0` — the row's ranged arg names the page
    scrollPageUp, scrollPageDown, scrollHome, scrollEnd,
    themeNext, themePrev,
    toggleNavPin,      /// `\` — show the page list on a narrow terminal
    toggleInspector,   /// `|` — dumpTree of the showing page

    // The Layout page.
    layoutWidthMode, layoutAlignX, layoutAlignY, layoutGap, layoutPadding,
    layoutThird, layoutGrow, layoutShrink,

    // The Tracks page.
    tracksPreset, tracksGrow, tracksShrink,

    // The Text page.
    textGrow, textShrink, textHang,

    // The Components page.
    compTabPrev, compTabNext,
    compAction,        /// `1`–`4` — the ranged arg names the action row
    compScrollDown, compScrollUp,

    // The Tree page.
    treeDown, treeUp, treeExpand, treeCollapse, treeActivate,
    treeOpenAll, treeCloseAll,

    // The Table page.
    tablePreset, tableRowRules, tableStubCol,
    tableScrollLeft, tableScrollRight, tableScrollUp, tableScrollDown,

    // The Scrolling page.
    scrollNext, scrollPrev, scrollNextPage, scrollPrevPage,
    scrollTop, scrollBottom,

    // The State (machines) page.
    machAnchor, machExtend, machFocusNext, machFocusPrev,
    machFoldToggle, machFoldPolarity, machPulse,

    // The Split page.
    splitShrink, splitGrow,

    // The Dock page.
    dockShrink, dockGrow, dockTabPrev, dockTabNext, dockFocusNext,
    dockWest, dockEast, dockNorth, dockSouth, dockReset,

    // The Terminal page.
    termNew, termClose, termPrev, termNext, termKeepExited, termFocus,
}

/**
Which surface a binding belongs to — and, by declaration order, when it is
resolved. The page scopes sit before `shell`, which $(I is) the old "page
gets first refusal in the content region" rule; `help` is modal.
*/
enum GalleryScope : ubyte
{
    /// resolves in every context; empty today (`resolveAlways`'s scope)
    always,
    /// the `?` overlay: modal — it swallows what it does not answer
    @terminalScope @hidesLaterScopes help,
    pageLayout,
    pageTracks,
    pageText,
    pageComponents,
    pageTree,
    pageTable,
    pageScrolling,
    pageMachines,
    pageSplit,
    pageDock,
    pageTerminal,
    shell, /// both regions, after the showing page declined
}

/**
Everything outside the key that changes what it means, plus the framework's
context hooks. `pageScope` is the showing page's scope
($(REF Page.scope_, registry)) — `GalleryScope.always` when the page has no
keys.
*/
struct GalleryContext
{
    GalleryScope pageScope = GalleryScope.always;
    bool contentRegion; /// the keyboard is in the content region
    bool helpShown;     /// the `?` overlay is up (modal, `FOC4`)

@safe pure nothrow @nogc const:

    bool reachable(GalleryScope s)
    {
        if (s == GalleryScope.always)
            return true;
        if (s == GalleryScope.help)
            return helpShown;
        if (s == GalleryScope.shell)
            return !helpShown;
        return !helpShown && contentRegion && s == pageScope;
    }
}

/// The framework's row builders with the gallery's command type pinned.
private alias bind = ui_keymap.bind;

/**
The gallery's keyboard policy. Rows are grouped by scope; within a scope the
keys are disjoint, so order never decides an outcome here.
*/
immutable Binding[] galleryBindings = [
    // ── help (modal): everything underneath is inert until it closes ─────
    bind(GalleryScope.help, chord(Key.escape), GalleryCommand.helpClose,
        "close"),
    bind(GalleryScope.help, chord(Key.back), GalleryCommand.helpClose,
        "close"),
    bind(GalleryScope.help, chord(Key.enter), GalleryCommand.helpClose,
        "close"),
    bind(GalleryScope.help, chord('?'), GalleryCommand.helpClose, "close"),
    bind(GalleryScope.help, chord('q'), GalleryCommand.helpClose, "close"),

    // ── the Layout page ──────────────────────────────────────────────────
    bind(GalleryScope.pageLayout, chord('w'), GalleryCommand.layoutWidthMode,
        "width mode"),
    bind(GalleryScope.pageLayout, chord('a', ShiftReq.no),
        GalleryCommand.layoutAlignX, "align x"),
    bind(GalleryScope.pageLayout, chord('a', ShiftReq.yes),
        GalleryCommand.layoutAlignY, "align y"),
    bind(GalleryScope.pageLayout, chord('g'), GalleryCommand.layoutGap, "gap"),
    bind(GalleryScope.pageLayout, chord('p'), GalleryCommand.layoutPadding,
        "padding"),
    bind(GalleryScope.pageLayout, chord('v'), GalleryCommand.layoutThird,
        "third's visibility"),
    bind(GalleryScope.pageLayout, chord('+'), GalleryCommand.layoutGrow,
        "wider"),
    bind(GalleryScope.pageLayout, chord('='), GalleryCommand.layoutGrow,
        "wider"),
    bind(GalleryScope.pageLayout, chord('-'), GalleryCommand.layoutShrink,
        "narrower"),

    // ── the Tracks page ──────────────────────────────────────────────────
    bind(GalleryScope.pageTracks, chord('t'), GalleryCommand.tracksPreset,
        "next preset"),
    bind(GalleryScope.pageTracks, chord('+'), GalleryCommand.tracksGrow,
        "wider"),
    bind(GalleryScope.pageTracks, chord('='), GalleryCommand.tracksGrow,
        "wider"),
    bind(GalleryScope.pageTracks, chord('-'), GalleryCommand.tracksShrink,
        "narrower"),

    // ── the Text page ────────────────────────────────────────────────────
    bind(GalleryScope.pageText, chord('+'), GalleryCommand.textGrow, "wider"),
    bind(GalleryScope.pageText, chord('='), GalleryCommand.textGrow, "wider"),
    bind(GalleryScope.pageText, chord('-'), GalleryCommand.textShrink,
        "narrower"),
    bind(GalleryScope.pageText, chord('h'), GalleryCommand.textHang,
        "hang indent"),

    // ── the Components page ──────────────────────────────────────────────
    bind(GalleryScope.pageComponents, chord(Key.left),
        GalleryCommand.compTabPrev, "prev tab"),
    bind(GalleryScope.pageComponents, chord(Key.right),
        GalleryCommand.compTabNext, "next tab"),
    bind(GalleryScope.pageComponents, chordRange('1', '4'),
        GalleryCommand.compAction, "action row", arg: 1),
    bind(GalleryScope.pageComponents, chord('n'), GalleryCommand.compScrollDown,
        "scroll down"),
    bind(GalleryScope.pageComponents, chord('p'), GalleryCommand.compScrollUp,
        "scroll up"),

    // ── the Tree page ────────────────────────────────────────────────────
    bind(GalleryScope.pageTree, chord(Key.down), GalleryCommand.treeDown,
        "down"),
    bind(GalleryScope.pageTree, chord(Key.up), GalleryCommand.treeUp, "up"),
    bind(GalleryScope.pageTree, chord(Key.right), GalleryCommand.treeExpand,
        "expand"),
    bind(GalleryScope.pageTree, chord(Key.left), GalleryCommand.treeCollapse,
        "collapse / up"),
    bind(GalleryScope.pageTree, chord(Key.enter), GalleryCommand.treeActivate,
        "toggle"),
    bind(GalleryScope.pageTree, chord('o', ShiftReq.yes),
        GalleryCommand.treeOpenAll, "open all"),
    bind(GalleryScope.pageTree, chord('c', ShiftReq.yes),
        GalleryCommand.treeCloseAll, "close all"),

    // ── the Table page ───────────────────────────────────────────────────
    bind(GalleryScope.pageTable, chord('g'), GalleryCommand.tablePreset,
        "glyphs"),
    bind(GalleryScope.pageTable, chord('r'), GalleryCommand.tableRowRules,
        "row rules"),
    bind(GalleryScope.pageTable, chord('s'), GalleryCommand.tableStubCol,
        "stub col"),
    // NOT `[`/`]`, though those are the conventional pair: the shell owns
    // them catalog-wide for the theme, and since a page's keys also fire
    // from the nav region (the shell's fallback rung), an advertised
    // binding has to mean the same thing wherever the keyboard happens to
    // be — the Dock page's `,`/`.` rule. `<`/`>` are `,`/`.`'s shifted
    // siblings, so the two scroll axes read as one family.
    bind(GalleryScope.pageTable, chord('<'),
        GalleryCommand.tableScrollLeft, "cols left"),
    bind(GalleryScope.pageTable, chord('>'),
        GalleryCommand.tableScrollRight, "cols right"),
    bind(GalleryScope.pageTable, chord(','), GalleryCommand.tableScrollUp,
        "rows up"),
    bind(GalleryScope.pageTable, chord('.'), GalleryCommand.tableScrollDown,
        "rows down"),

    // ── the Scrolling page ───────────────────────────────────────────────
    bind(GalleryScope.pageScrolling, chord('n', ShiftReq.no),
        GalleryCommand.scrollNext, "down"),
    bind(GalleryScope.pageScrolling, chord('p', ShiftReq.no),
        GalleryCommand.scrollPrev, "up"),
    bind(GalleryScope.pageScrolling, chord('n', ShiftReq.yes),
        GalleryCommand.scrollNextPage, "page down"),
    bind(GalleryScope.pageScrolling, chord('p', ShiftReq.yes),
        GalleryCommand.scrollPrevPage, "page up"),
    bind(GalleryScope.pageScrolling, chord('g', ShiftReq.no),
        GalleryCommand.scrollTop, "top"),
    bind(GalleryScope.pageScrolling, chord('g', ShiftReq.yes),
        GalleryCommand.scrollBottom, "bottom"),

    // ── the State page ───────────────────────────────────────────────────
    bind(GalleryScope.pageMachines, chord('a'), GalleryCommand.machAnchor,
        "anchor selection"),
    bind(GalleryScope.pageMachines, chord('e'), GalleryCommand.machExtend,
        "extend selection"),
    bind(GalleryScope.pageMachines, chord('f', ShiftReq.no),
        GalleryCommand.machFocusNext, "focus next"),
    bind(GalleryScope.pageMachines, chord('f', ShiftReq.yes),
        GalleryCommand.machFocusPrev, "focus prev"),
    bind(GalleryScope.pageMachines, chord('d', ShiftReq.no),
        GalleryCommand.machFoldToggle, "toggle fold"),
    bind(GalleryScope.pageMachines, chord('d', ShiftReq.yes),
        GalleryCommand.machFoldPolarity, "fold polarity"),
    bind(GalleryScope.pageMachines, chord('p'), GalleryCommand.machPulse,
        "pulse"),

    // ── the Split page ───────────────────────────────────────────────────
    bind(GalleryScope.pageSplit, chord(Key.left), GalleryCommand.splitShrink,
        "narrower"),
    bind(GalleryScope.pageSplit, chord(Key.right), GalleryCommand.splitGrow,
        "wider"),

    // ── the Dock page ────────────────────────────────────────────────────
    bind(GalleryScope.pageDock, chord('h'), GalleryCommand.dockShrink,
        "narrower"),
    bind(GalleryScope.pageDock, chord('l'), GalleryCommand.dockGrow, "wider"),
    // `,`/`.`, NOT the conventional `[`/`]`: the shell owns that pair
    // catalog-wide for the theme, so a page binding it would act on the page
    // in the content region and cycle themes in the nav one. A binding the
    // status bar advertises has to mean the same thing wherever the keyboard
    // happens to be.
    bind(GalleryScope.pageDock, chord(','), GalleryCommand.dockTabPrev,
        "prev tab"),
    bind(GalleryScope.pageDock, chord('.'), GalleryCommand.dockTabNext,
        "next tab"),
    bind(GalleryScope.pageDock, chord('f'), GalleryCommand.dockFocusNext,
        "focus next pane"),
    bind(GalleryScope.pageDock, chord('w'), GalleryCommand.dockWest,
        "dock west"),
    bind(GalleryScope.pageDock, chord('e'), GalleryCommand.dockEast,
        "dock east"),
    bind(GalleryScope.pageDock, chord('n'), GalleryCommand.dockNorth,
        "dock north"),
    bind(GalleryScope.pageDock, chord('s'), GalleryCommand.dockSouth,
        "dock south"),
    bind(GalleryScope.pageDock, chord('r'), GalleryCommand.dockReset,
        "reset layout"),

    // ── the Terminal page ────────────────────────────────────────────────
    bind(GalleryScope.pageTerminal, chord('n'), GalleryCommand.termNew,
        "new shell"),
    bind(GalleryScope.pageTerminal, chord('x'), GalleryCommand.termClose,
        "close shell"),
    bind(GalleryScope.pageTerminal, chord('h'), GalleryCommand.termPrev,
        "prev tab"),
    bind(GalleryScope.pageTerminal, chord('l'), GalleryCommand.termNext,
        "next tab"),
    bind(GalleryScope.pageTerminal, chord('e'), GalleryCommand.termKeepExited,
        "keep exited"),
    bind(GalleryScope.pageTerminal, chord(Key.enter), GalleryCommand.termFocus,
        "focus the shell"),

    // ── the shell ────────────────────────────────────────────────────────
    bind(GalleryScope.shell, chord(Key.escape), GalleryCommand.quit, "quit"),
    bind(GalleryScope.shell, chord(Key.back), GalleryCommand.quit, "quit"),
    bind(GalleryScope.shell, chord('q'), GalleryCommand.quit, "quit"),
    bind(GalleryScope.shell, chord('?'), GalleryCommand.showHelp, "keys"),
    // Two regions, so forward and backward are the same move; Shift-Tab is
    // accepted because a reader who knows the convention will press it.
    bind(GalleryScope.shell, chord(Key.tab), GalleryCommand.regionToggle,
        "page list / page"),
    bind(GalleryScope.shell, chord(Key.enter), GalleryCommand.enterContent,
        "to the page"),
    bind(GalleryScope.shell, chord(' '), GalleryCommand.enterContent,
        "to the page"),
    bind(GalleryScope.shell, chord(Key.down), GalleryCommand.moveDown, "down"),
    bind(GalleryScope.shell, chord('j'), GalleryCommand.moveDown, "down"),
    bind(GalleryScope.shell, chord(Key.up), GalleryCommand.moveUp, "up"),
    bind(GalleryScope.shell, chord('k'), GalleryCommand.moveUp, "up"),
    bind(GalleryScope.shell, chord(Key.left), GalleryCommand.pagePrev,
        "prev page"),
    bind(GalleryScope.shell, chord(Key.right), GalleryCommand.pageNext,
        "next page"),
    bind(GalleryScope.shell, chordRange('1', '9'), GalleryCommand.pageJump,
        "page 1-9", arg: 1),
    bind(GalleryScope.shell, chord('0'), GalleryCommand.pageJump, "page 10",
        arg: 10),
    bind(GalleryScope.shell, chord(Key.pageUp), GalleryCommand.scrollPageUp,
        "scroll up"),
    bind(GalleryScope.shell, chord(Key.pageDown),
        GalleryCommand.scrollPageDown, "scroll down"),
    bind(GalleryScope.shell, chord(Key.home), GalleryCommand.scrollHome,
        "top"),
    bind(GalleryScope.shell, chord(Key.end), GalleryCommand.scrollEnd,
        "bottom"),
    bind(GalleryScope.shell, chord(']'), GalleryCommand.themeNext,
        "next theme"),
    bind(GalleryScope.shell, chord('['), GalleryCommand.themePrev,
        "prev theme"),
    bind(GalleryScope.shell, chord('\\'), GalleryCommand.toggleNavPin,
        "pin the page list"),
    bind(GalleryScope.shell, chord('|'), GalleryCommand.toggleInspector,
        "inspector"),
];

// ---------------------------------------------------------------------------
// Resolution — the framework's algorithms bound to the gallery's table.
// ---------------------------------------------------------------------------

/// $(REF commandFor, sparkles,ui,keymap) over $(LREF galleryBindings).
KeyCommand commandFor(in KeyEvent raw, in GalleryContext ctx)
    @safe pure nothrow @nogc
    => ui_keymap.commandFor(galleryBindings, raw, ctx);

/// $(REF bindingsAt, sparkles,ui,keymap) over $(LREF galleryBindings).
void bindingsAt(Sink)(ref Sink sink, in GalleryContext ctx,
    scope const Chord[] prefix = null)
{
    ui_keymap.bindingsAt(sink, galleryBindings, ctx, prefix);
}

// ---------------------------------------------------------------------------
// The terminal pane's keyboard grab (`FOC3`) — routing as data.
// ---------------------------------------------------------------------------

/**
The capture-release chords: `Ctrl+]` (GS, 0x1d — a byte legacy terminal
input delivers unambiguously) or VSCode's `` Ctrl+` `` (which some terminals
cannot send at all — the reason there are two). The one binding a focused
terminal never receives; the emulator-convention scrollback keys pass
through.
*/
immutable Chord[] grabRelease = [
    Chord(key: Key.char_, ch: ']', ctrl: true),
    Chord(key: Key.char_, ch: '`', ctrl: true),
];

/// ditto
immutable Chord[] grabPassthrough = [
    chord(Key.pageUp, ShiftReq.yes),
    chord(Key.pageDown, ShiftReq.yes),
];

/// ditto — `static immutable` rather than `enum`, so a use borrows the two
/// tables instead of re-materialising them (which would allocate in `@nogc`
/// callers).
static immutable GrabPolicy terminalGrabPolicy =
    GrabPolicy(grabRelease, grabPassthrough);

/**
Producer normalisation for the grab (`KEY7`'s spirit): the raw GS control
byte — however the input layer spelled it — and a Ctrl chord whose shifted
`ch` obscured the base key both become the canonical `Ctrl+]` / `` Ctrl+` ``
spelling, so the policy's chords match every producer.
*/
KeyEvent normaliseGrabKey(in KeyEvent raw) @safe pure nothrow @nogc
{
    KeyEvent k = raw;
    if (k.ch == '\x1d' || k.text == "\x1d")
    {
        k.key = Key.char_;
        k.ch = ']';
        k.mods.ctrl = true;
    }
    else if (k.mods.ctrl && (k.unshifted == ']' || k.unshifted == '`'))
        k.ch = k.unshifted;
    return k;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input.events : Mods;

    KeyCommand ch(dchar c, GalleryContext ctx = GalleryContext.init,
        Mods m = Mods()) @safe pure nothrow @nogc
        => commandFor(KeyEvent(Key.char_, c, m), ctx);
    KeyCommand nk(Key k, GalleryContext ctx = GalleryContext.init,
        Mods m = Mods()) @safe pure nothrow @nogc
        => commandFor(KeyEvent(k, 0, m), ctx);
}

@("ui_gallery.keymap.pagesGetFirstRefusalInTheContentRegion")
@safe pure nothrow @nogc
unittest
{
    // The Components page claims the arrows ahead of page switching — but
    // only while it shows and the keyboard is in the content region. The
    // arrows are the one deliberate shadow family: readers expect them to
    // be region-local, where a shadowed PRINTABLE would contradict what the
    // status bar advertises (the Dock and Table pages' `,`/`.`-family rows
    // exist to avoid exactly that).
    const comp = GalleryContext(pageScope: GalleryScope.pageComponents,
        contentRegion: true);
    assert(nk(Key.right, comp).cmd == GalleryCommand.compTabNext);
    assert(nk(Key.left, comp).cmd == GalleryCommand.compTabPrev);

    const compNav = GalleryContext(pageScope: GalleryScope.pageComponents);
    assert(nk(Key.right, compNav).cmd == GalleryCommand.pageNext,
        "in the nav region the shell keeps the key");
    assert(nk(Key.right).cmd == GalleryCommand.pageNext,
        "…and a page with no scope never shadows it");

    // A page scope never reaches across pages.
    const text = GalleryContext(pageScope: GalleryScope.pageText,
        contentRegion: true);
    assert(ch('t', text).cmd == GalleryCommand.none);
}

@("ui_gallery.keymap.helpIsModal")
@safe pure nothrow @nogc
unittest
{
    const help = GalleryContext(pageScope: GalleryScope.pageDock,
        contentRegion: true, helpShown: true);
    assert(ch('q', help).cmd == GalleryCommand.helpClose,
        "q closes the overlay instead of quitting");
    assert(nk(Key.escape, help).cmd == GalleryCommand.helpClose);
    assert(ch('?', help).cmd == GalleryCommand.helpClose);
    assert(ch(']', help).cmd == GalleryCommand.none,
        "everything underneath is inert until it closes");
    assert(nk(Key.tab, help).cmd == GalleryCommand.none);
}

@("ui_gallery.keymap.rangedRowsCarryTheirTarget")
@safe pure nothrow @nogc
unittest
{
    assert(ch('1') == KeyCommand(GalleryCommand.pageJump, 1));
    assert(ch('9') == KeyCommand(GalleryCommand.pageJump, 9));
    assert(ch('0') == KeyCommand(GalleryCommand.pageJump, 10));

    const comp = GalleryContext(pageScope: GalleryScope.pageComponents,
        contentRegion: true);
    assert(ch('3', comp) == KeyCommand(GalleryCommand.compAction, 3));
    assert(ch('7', comp) == KeyCommand(GalleryCommand.pageJump, 7),
        "past the page's range the shell's jump still fires");
}

@("ui_gallery.keymap.noPageMayClaimTheShellsLifelines")
@safe pure nothrow @nogc
unittest
{
    import std.traits : EnumMembers;

    // `Tab`, quit and the help key must always work — a page that could
    // claim them could strand a reader inside itself. The check `Page.keys`
    // prose never had: asserted over the table, for every page scope.
    static immutable Chord[4] lifelines =
        [chord(Key.tab), chord(Key.escape), chord('q'), chord('?')];
    foreach (ref b; galleryBindings)
    {
        if (b.scope_ == GalleryScope.help || b.scope_ == GalleryScope.shell)
            continue;
        foreach (ref life; lifelines)
            assert(!sameKey(b.path[0], life),
                "a page scope claims a shell lifeline");
    }
}

@("ui_gallery.keymap.grabChordsMatchEveryProducerSpelling")
@safe pure nothrow @nogc
unittest
{
    import sparkles.input.events : Mods;
    import sparkles.ui.focus : checkGrab, GrabVerdict, KeyGrab;

    // The four spellings one release chord arrives in.
    KeyEvent[4] spellings = [
        KeyEvent(Key.char_, ']', Mods(ctrl: true)),
        KeyEvent(Key.char_, '\x1d'),
        KeyEvent(Key.char_, 0, Mods(ctrl: true), unshifted: ']'),
        KeyEvent(Key.char_, '`', Mods(ctrl: true)),
    ];
    foreach (raw; spellings)
    {
        KeyGrab g;
        g.take(1);
        assert(checkGrab(g, normaliseGrabKey(raw), terminalGrabPolicy)
            == GrabVerdict.released, "every spelling releases");
    }

    // Scrollback passes through; anything else is the pty's.
    KeyGrab g;
    g.take(1);
    assert(checkGrab(g, normaliseGrabKey(
        KeyEvent(Key.pageUp, 0, Mods(shift: true))), terminalGrabPolicy)
        == GrabVerdict.passthrough);
    assert(checkGrab(g, normaliseGrabKey(KeyEvent(Key.char_, 'q')),
        terminalGrabPolicy) == GrabVerdict.forward);
    assert(g.active);
}

@("ui_gallery.keymap.bindingsAtEnumeratesWhatWouldFire")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.input.events : Mods;
    import std.traits : EnumMembers;

    // Whatever the help panel or the status bar lists, `commandFor` does —
    // for every page scope, both regions, and under the modal.
    static void check(in GalleryContext ctx)
    {
        SmallBuffer!(Binding, 128) listed;
        bindingsAt(listed, ctx);
        foreach (ref b; listed[])
        {
            // A ranged row may be partially shadowed by a narrower range in
            // an earlier scope (the Components page's `1-4` inside the
            // shell's `1-9`), so the property is: some key in the listed
            // range fires this command — a listed row is never fully dead.
            const c = b.path[0];
            const last = c.chEnd ? c.chEnd : c.ch;
            bool fires;
            foreach (dchar key; c.ch .. last + 1)
            {
                const r = commandFor(KeyEvent(c.key, key, Mods(ctrl: c.ctrl,
                    alt: c.alt, shift: c.shift == ShiftReq.yes)), ctx);
                if (r.cmd == b.cmd)
                {
                    fires = true;
                    break;
                }
            }
            assert(fires, "a listed binding must be what fires");
        }
        foreach (i, ref a; listed[])
            foreach (j, ref b; listed[])
                assert(i == j || !sameKey(a.path[0], b.path[0]),
                    "a shadowed duplicate must not be listed");
    }

    foreach (scope_; EnumMembers!GalleryScope)
    {
        check(GalleryContext(pageScope: scope_, contentRegion: true));
        check(GalleryContext(pageScope: scope_));
    }
    check(GalleryContext(helpShown: true));
}
