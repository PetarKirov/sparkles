/**
hue's keyboard policy as $(B data) (`KEY1`–`KEY4`).

The GUI decided what a key meant with ~45 `IsKeyPressed(KEY_X)` calls scattered
through a 400-line stretch of the frame loop, each carrying its own share of the
context — is the tree focused, is an input mode open, is a fold sequence armed.
That was untestable by construction: `gui.d` has no unittests and cannot get any,
because every one of those decisions is entangled with a live window. Collapsing
them into $(LREF commandFor) — one pure function over an explicit
$(LREF KeyContext) — made the policy checkable, and that is what let the frame
loop be converted against a fixed oracle rather than rewritten with nothing to
check it.

$(B A function is not enough, though.) It answers "what does this key do here"
and nothing else. Two things need the other direction — $(I which keys are
available here):

$(UL
    $(LI $(B lantern) (`docs/specs/ui/keymap.md`), the key guide, is an
    enumeration of the binding set. It cannot be honest about a policy it
    cannot read.)
    $(LI $(B configuration) (`CFG6`) says "configuration replaces the
    hardcoded table with a loaded one" — and there was no table to overlay.)
)

So the policy is now $(LREF hueBindings), an `immutable` table, and
$(LREF commandFor) is a lookup over it while $(LREF bindingsAt) is the
enumeration. One declaration, read both ways.

$(B The table is ordered, and the order is the policy.) Precedence used to live
in the shape of an `if`/`else` chain: an armed fold sequence claims letters that
otherwise toggle things, a Ctrl chord resolves before the plain letter, a focused
tree claims `j` before the viewer does. That ordering is preserved exactly — as
$(LREF Scope_), whose declaration order $(I is) the resolution order, and whose
$(REF terminalScope, sparkles,ui,keymap)-marked scopes are the ones that used
to `return` rather than fall through.

$(B This is hue's policy; the machinery is the framework's.) Which key does
what, and which context gates it, is exactly the application's business. The
vocabulary ($(REF Chord, sparkles,ui,keymap)), the matching rules, and the
resolution algorithm live in $(MREF sparkles,ui,keymap); this module supplies
the payloads — $(LREF Command), $(LREF Scope_), $(LREF KeyContext), the table —
and binds them together so every hue call site reads the policy through one
door and no site can pass a different table by accident.
*/
module keymap;

import sparkles.input.events : Key, KeyEvent;

import ui_keymap = sparkles.ui.keymap;
public import sparkles.ui.keymap : acceptsTyped, Chord, chord, chordRange,
    hidesLaterScopes, matches, maxPathLength, ModeReq, normalise, ResolveKind,
    sameKey, ShiftReq, terminalScope;

/// hue's binding row, resolution result, and resolved command — the framework
/// types instantiated with hue's payloads.
alias Binding = ui_keymap.Binding!(Command, Scope_);
/// ditto
alias Resolution = ui_keymap.Resolution!Command;
/// ditto
alias KeyCommand = ui_keymap.KeyCommand!Command;

/// Which input surface owns the keyboard. `search` and `gotoLine` are the
/// two line-editing modes; everything else is `normal`.
enum InputMode : ubyte
{
    normal,
    search,
    gotoLine,
}

/**
Everything outside the key itself that changes what the key means.

Explicit and flat on purpose: this is the entire set of facts the keymap may
consult, so a reader can see what a binding depends on without tracing the
frame loop, and a test can construct any situation directly.

The `const` members are the framework's context hooks
($(MREF sparkles,ui,keymap)): `reachable`/`scopeActive` gate the scopes,
`bits` feeds a row's `require`/`forbid`, and `editing` answers
$(REF ModeReq, sparkles,ui,keymap).
*/
struct KeyContext
{
    InputMode mode;      /// which surface owns the keyboard
    bool treeFocused;    /// the explorer pane holds focus
    bool treeVisible;    /// the explorer pane is shown at all
    bool hasMatches;     /// a search produced matches (enables n / N)
    bool hasDocSet;      /// a multi-document set is loaded (enables [ / ] / i)
    /// a multi-file diff session is showing (`DVG1`: `[`/`]` walk its files,
    /// and the `z` family folds files rather than syntax ranges)
    bool hasDiffSession;
    bool showPreview;    /// the decorated preview is showing (search is raw-only)
    /// the format preview is showing (`<`/`>` nudge its ruler; `FMV`)
    bool formatPreviewActive;
    /// a DSV grid is showing (`/` filters it, `Shift-R` resets — `DSB`)
    bool hasDsvGrid;
    /// The fuzzy picker is open (`PIK1`): a modal surface, expressed as
    /// context gating (`FOC4`) — while set, only the `always` and `picker*`
    /// scopes are reachable, which is the whole modality mechanism.
    bool pickerActive;
    /// Which picker pane owns the keyboard while the picker is open — a
    /// `ScopeFocus!Scope_` value the host carries (`FOC2`).
    Scope_ pickerFocus = Scope_.pickerInput;
    /// The tree-sitter inspector pane holds the keyboard (its hosts route
    /// by pane, so only the inspector's own resolution sets this).
    bool inspectorFocused;

@safe pure nothrow @nogc const:

    /// Whether a line editor owns the keyboard, for `ModeReq`.
    bool editing() => mode != InputMode.normal;

    /// The context's facts as $(LREF CtxFlag) bits.
    ubyte bits()
    {
        ubyte b;
        if (hasMatches)     b |= CtxFlag.hasMatches;
        if (hasDocSet)      b |= CtxFlag.hasDocSet;
        if (hasDiffSession) b |= CtxFlag.hasDiffSession;
        if (showPreview)    b |= CtxFlag.showPreview;
        if (formatPreviewActive) b |= CtxFlag.formatPreviewActive;
        if (hasDsvGrid)     b |= CtxFlag.hasDsvGrid;
        if (pickerActive)   b |= CtxFlag.pickerActive;
        return b;
    }

    /**
    Whether `s` applies here for reasons that do not depend on the key.

    Every scope but $(LREF Scope_.ctrl) is gated purely by context, which is
    what lets $(LREF bindingsAt) enumerate without a key in hand. `ctrl` is
    the exception — it is gated by the keystroke itself — and its rows carry
    that in their chords, so listing them unconditionally is correct.
    */
    bool reachable(Scope_ s)
    {
        final switch (s)
        {
            case Scope_.always:  return true;
            case Scope_.input:   return mode != InputMode.normal;
            case Scope_.pickerInput:
                return pickerActive && pickerFocus == Scope_.pickerInput;
            case Scope_.pickerList:
                return pickerActive && pickerFocus == Scope_.pickerList;
            case Scope_.pickerPreview:
                return pickerActive && pickerFocus == Scope_.pickerPreview;
            case Scope_.picker:  return pickerActive;
            case Scope_.inspector: return inspectorFocused;
            case Scope_.ctrl:    return !pickerActive && !inspectorFocused;
            case Scope_.tree:    return !pickerActive && !inspectorFocused
                && treeFocused && treeVisible;
            case Scope_.viewer:  return !pickerActive && !inspectorFocused
                && !(treeFocused && treeVisible);
            case Scope_.shared_: return !pickerActive && !inspectorFocused;
        }
    }

    /// Whether `s` applies at all — the conditions the old `if` chain tested
    /// before entering each of its blocks.
    bool scopeActive(Scope_ s, in KeyEvent k)
        => s == Scope_.ctrl
            ? (!pickerActive && !inspectorFocused
                && k.mods.ctrl && k.key == Key.char_)
            : reachable(s);
}

/**
What the application should do. `none` means "this key is not bound here" —
never "do nothing quietly", which is why the frame loop can fall through to
its remaining non-keyboard work without a special case.

Names describe the $(I effect), not the key, so a rebinding changes one table
row rather than every reader's mental model.
*/
enum Command : ubyte
{
    none,

    // Always available, whatever owns the keyboard.
    toggleFullscreen,
    dismiss, /// Escape, or Android's system Back

    // The two line-editing modes.
    inputBackspace,
    inputAccept,
    inputCancel,

    // The explorer pane, while it holds focus.
    treeDown, treeUp, treeHome, treeEnd,
    treePageDown, treePageUp,
    treeActivate,
    treeRefresh,       /// `r`
    treeReroot,        /// `Shift-R` — re-root at the selection
    treeToggleIgnored, /// `Shift-I`
    treeParent,        /// `u` — re-root at the parent
    treeNextChange,    /// `]`
    treePrevChange,    /// `[`
    treeCloseAll,      /// `c`
    treeToggleHidden,  /// `Shift-H`
    treeCollapseOrUp,  /// `h`
    treeFilter,        /// `/` while the tree is focused

    // The document viewer.
    viewDown, viewUp, viewHome, viewEnd,
    viewPageDown, viewPageUp,

    // Available in normal mode regardless of which pane has focus.
    toggleExplorer,        /// `e`
    toggleInspector,       /// `<leader>vi` — the tree-sitter inspector pane
    themeNext, themePrev,  /// `→` / `←`
    fontBigger, fontSmaller, /// `Ctrl-=` / `Ctrl--`
    matchNext, matchPrev,  /// `n` / `Shift-N`
    setNext, setPrev,      /// `]` / `[` over a document set
    setIndex,              /// `i` — back to the set's index view
    toggleView,            /// `Tab`
    copySelection,         /// `Ctrl-C`
    toggleLineNumbers,     /// `l`
    toggleCodeLineNumbers, /// `c`
    toggleAnsiCopy,        /// `<leader>uy`
    toggleFormatPreview,   /// `<leader>vf` — the in-memory format preview
    formatterNext,         /// `<leader>vF` — cycle the preview's formatter
    formatWidthNarrower,   /// `<` while the preview is active
    formatWidthWider,      /// `>` — same clamp as the ruler drag (`RUL5`)
    toggleTableCopy,       /// `t`
    startSearch,           /// `/`
    startGoto,             /// `gl`
    dsvFilter,             /// `/` over a DSV grid — the filter bar (`DSF1`)
    dsvReset,              /// `Shift-R` — back to the pristine grid (`DSB2`)
    lanternAll,            /// `<leader>?` — list every binding live here
    pickerFiles,           /// `<leader>ff` — the fuzzy file picker
    quit,                  /// `q` — leave the viewer
    viewTop, viewBottom,   /// `gg` / `G`
    toggleHoverRegions,    /// Enter — open a twoslash signature's collapsed runs
    cycleHoverPopup,       /// `p` — step through the twoslash hover popups

    // The `z` fold prefix (`FLD5`). `foldLevel` carries 1–9 in
    // $(LREF KeyCommand.arg).
    foldToggle, foldClose, foldOpen, foldOpenAll, foldCloseAll,
    foldLevel,

    // The diff session (`DVG1`/`DVG3`), when one is showing. `[`/`]` and the
    // `z` family are re-pointed at files rather than getting keys of their
    // own: to a reviewer the changed-file list IS the set being walked, and a
    // file IS the thing that folds.
    diffNextFile, diffPrevFile,
    diffNextHunk, diffPrevHunk,        /// `}` / `{`
    diffToggleFile,
    diffCollapseAll, diffExpandAll,
    diffToggleFormatting,              /// `zn` — the formatting-only hunks
    diffToggleLayout,                  /// `s` — unified ⇄ split
    diffToggleStructural,              /// `S` — word ⇄ grammar-token emphasis
    diffToggleContext,                 /// `zx` — every hidden unchanged region
    diffToggleGap,                     /// `+` — just the one in view

    // Horizontal scrolling (`IXB2`'s missing half): content wider than the
    // pane had a bar to drag and nothing else, which over SSH on a phone is
    // not a scrollbar but a dare.
    viewScrollLeft,                    /// `zh` / `Shift-←`
    viewScrollRight,                   /// `zl` / `Shift-→`
    viewScrollHome,                    /// `Shift-Home` — back to the left edge
    viewScrollEnd,                     /// `Shift-End` — out to the right edge

    // The write surface (`DST2`/`DST4`), over a worktree diff only.
    diffStage,                         /// `space` — stage the hunk in view
    diffUnstage,                       /// `u` — take it back out of the index
    diffDiscard,                       /// `Shift-X` — throw the change away

    // The fuzzy picker's modal surface (`PKL7`): its keys are table rows so
    // the guide can list them (`PKL3`), gated on `pickerActive` + pane focus.
    // Only the hosts' picker branch answers these; every other dispatch
    // carries empty arms (`KEY11`).
    pickerClose, pickerAccept, pickerErase,
    pickerUp, pickerDown, pickerPageUp, pickerPageDown,
    pickerTop, pickerBottom,
    pickerFocusNext, pickerFocusPrev,  /// `Tab` / `Shift-Tab` cycle the panes
    pickerToggleScore,                 /// `Ctrl-S` — `PKR4`'s debug view
    pickerPreviewDown, pickerPreviewUp, /// `Ctrl-D`/`Ctrl-U` — scroll the preview

    // The tree-sitter inspector pane, while it holds focus (`INS*`) — the
    // same pattern: table rows in a focused scope, one pane dispatch.
    inspDown, inspUp, inspPageDown, inspPageUp, inspHome, inspEnd,
    inspCollapse, inspExpand, inspActivate,
    inspClose,           /// `q` / `Escape` — close and return the focus
    inspToggleAnonymous, /// `a` — show/hide anonymous nodes
    inspTogglePick,      /// `s` — DevTools' pick-from-source mode
}

/**
Which surface a binding belongs to — $(B and, by declaration order, when it is
resolved).

This is the `if`/`else` chain `commandFor` used to be, turned into data. Reading
top to bottom gives the old precedence: the always-available keys, then an open
input mode, then Ctrl chords, then whichever pane has focus, then the keys both
panes share. The markers carry what the chain expressed by `return`ing: while a
line-editing mode is open a letter is $(I text) and must not reach a command
(so `input` is terminal $(I and) hides the scopes below it), and a Ctrl'd
letter resolves as a chord or not at all (terminal, but its chords are the
only keys it swallows, so the scopes below stay listable).
*/
enum Scope_ : ubyte
{
    always,  /// resolves in every context (fullscreen, dismiss)
    /// a line-editing mode owns the keyboard
    @terminalScope @hidesLaterScopes input,
    /// the picker's prompt pane holds its focus (no rows of its own — a
    /// printable is prompt text; the member exists as a `ScopeFocus` target)
    pickerInput,
    pickerList,    /// the picker's result list holds its focus (`j`/`k`/`g`/`G`)
    pickerPreview, /// the picker's preview pane holds its focus (keys forward)
    /// every picker pane (`PIK1`): terminal $(I and) hiding, because the
    /// picker is modal — an unmatched key is the prompt's (or the preview's),
    /// never a command below, and the guide must not list what cannot fire
    @terminalScope @hidesLaterScopes picker,
    /// the tree-sitter inspector pane, while it holds focus: it consumes
    /// every key it is routed (its hosts route by pane), so it is terminal
    /// and hides the scopes below from the guide
    @terminalScope @hidesLaterScopes inspector,
    /// a Ctrl chord, before the plain letter is considered
    @terminalScope ctrl,
    tree,    /// the explorer pane, while focused and shown
    viewer,  /// the document viewer (i.e. not the above)
    shared_, /// available from either pane
}

/// Which $(LREF KeyContext) facts a binding may require or forbid, as bits so a
/// row states its gate inline instead of the caller filtering afterwards.
enum CtxFlag : ubyte
{
    hasMatches     = 1 << 0,
    hasDocSet      = 1 << 1,
    hasDiffSession = 1 << 2,
    showPreview    = 1 << 3,
    formatPreviewActive = 1 << 4,
    hasDsvGrid     = 1 << 5,
    pickerActive   = 1 << 6,
}

/// The framework's row builders, with hue's command type pinned so the table
/// below needs no explicit instantiations.
private alias bind = ui_keymap.bind;

/// ditto
private Binding group(Scope_ scope_, Chord a, string name,
    ubyte require = 0, ubyte forbid = 0) @safe pure nothrow @nogc
    => ui_keymap.group!Command(scope_, a, name, require, forbid);

/// ditto
private Binding group(Scope_ scope_, Chord a, Chord b_, string name,
    ubyte require = 0, ubyte forbid = 0) @safe pure nothrow @nogc
    => ui_keymap.group!Command(scope_, a, b_, name, require, forbid);

/// The leader key (`LMP1`). `<space>` because that is the muscle memory the
/// LazyVim-shaped map this table is growing into is built on.
enum leader = ' ';

/**
hue's keyboard policy.

Row order within a scope decides which of two overlapping rows wins, and it is
load-bearing in exactly one place: a diff session's `[`/`]` outrank a document
set's on the same keys, because to a reviewer the changed-file list $(I is) the
set being walked (`DVG1`). Everywhere else the rows are disjoint.
*/
immutable Binding[] hueBindings = [
    // ── always ───────────────────────────────────────────────────────────
    // F11 outranks every mode — you can always leave fullscreen.
    bind(Scope_.always, chord(Key.f11), Command.toggleFullscreen, "toggle fullscreen"),
    // Escape and Back both cancel an open input mode. In NORMAL mode they
    // differ, and the difference is deliberate rather than an oversight to
    // tidy up here: Android's Back runs the dismiss chain (close the
    // explorer, else leave), while desktop Escape does nothing today.
    //
    // `sparkles.input.isDismiss` already declares the two the same platform
    // spelling, so unifying them is probably right — but this module is the
    // oracle a mechanical conversion is checked against, and an oracle that
    // quietly disagrees with the code it describes is worse than none. The
    // unification belongs in its own commit, where it can be reviewed as the
    // behaviour change it is.
    bind(Scope_.always, chord(Key.escape), Command.inputCancel, "cancel",
        mode: ModeReq.editing),
    bind(Scope_.always, chord(Key.back), Command.inputCancel, "cancel",
        mode: ModeReq.editing),
    // The picker claims Back as close (`pickerClose` below); the dismiss
    // chain must not also fire under the modal.
    bind(Scope_.always, chord(Key.back), Command.dismiss, "back",
        mode: ModeReq.normal, forbid: CtxFlag.pickerActive),

    // ── input (terminal: a letter is text while typing) ───────────────────
    bind(Scope_.input, chord(Key.backspace), Command.inputBackspace, "erase"),
    bind(Scope_.input, chord(Key.enter), Command.inputAccept, "accept"),

    // ── ctrl (terminal) ──────────────────────────────────────────────────
    bind(Scope_.ctrl, Chord(key: Key.char_, ch: 'c', ctrl: true),
        Command.copySelection, "copy selection"),
    bind(Scope_.ctrl, Chord(key: Key.char_, ch: '=', ctrl: true),
        Command.fontBigger, "bigger font"),
    bind(Scope_.ctrl, Chord(key: Key.char_, ch: '+', ctrl: true),
        Command.fontBigger, "bigger font"),
    bind(Scope_.ctrl, Chord(key: Key.char_, ch: '-', ctrl: true),
        Command.fontSmaller, "smaller font"),

    // ── tree ─────────────────────────────────────────────────────────────
    bind(Scope_.tree, chord(Key.down), Command.treeDown, "down"),
    bind(Scope_.tree, chord(Key.up), Command.treeUp, "up"),
    bind(Scope_.tree, chord(Key.home), Command.treeHome, "first row"),
    bind(Scope_.tree, chord(Key.end), Command.treeEnd, "last row"),
    bind(Scope_.tree, chord(Key.enter), Command.treeActivate, "open"),
    bind(Scope_.tree, chord(Key.right), Command.treeActivate, "open"),
    bind(Scope_.tree, chord(Key.left), Command.treeCollapseOrUp, "collapse / up"),
    bind(Scope_.tree, chord(Key.pageDown), Command.treePageDown, "page down"),
    bind(Scope_.tree, chord(Key.pageUp), Command.treePageUp, "page up"),
    group(Scope_.tree, chord('g', ShiftReq.no), "goto"),
    bind(Scope_.tree, chord('g', ShiftReq.no), chord('g'), Command.treeHome,
        "first row"),
    bind(Scope_.tree, chord('g', ShiftReq.yes), Command.treeEnd, "last row"),
    bind(Scope_.tree, chord('j'), Command.treeDown, "down"),
    bind(Scope_.tree, chord('k'), Command.treeUp, "up"),
    bind(Scope_.tree, chord('l'), Command.treeActivate, "open"),
    bind(Scope_.tree, chord('r', ShiftReq.yes), Command.treeReroot, "re-root here"),
    bind(Scope_.tree, chord('r', ShiftReq.no), Command.treeRefresh, "refresh"),
    bind(Scope_.tree, chord('i', ShiftReq.yes), Command.treeToggleIgnored,
        "toggle ignored files"),
    bind(Scope_.tree, chord('u'), Command.treeParent, "re-root at parent"),
    bind(Scope_.tree, chord(']'), Command.treeNextChange, "next change"),
    bind(Scope_.tree, chord('['), Command.treePrevChange, "prev change"),
    bind(Scope_.tree, chord('c'), Command.treeCloseAll, "close all"),
    bind(Scope_.tree, chord('h', ShiftReq.yes), Command.treeToggleHidden,
        "toggle hidden files"),
    bind(Scope_.tree, chord('h', ShiftReq.no), Command.treeCollapseOrUp, "collapse / up"),
    bind(Scope_.tree, chord('/'), Command.treeFilter, "filter"),
    bind(Scope_.tree, chord('e'), Command.toggleExplorer, "toggle explorer"),

    // ── viewer ───────────────────────────────────────────────────────────
    bind(Scope_.viewer, chord(Key.down), Command.viewDown, "down"),
    bind(Scope_.viewer, chord(Key.up), Command.viewUp, "up"),
    bind(Scope_.viewer, chord(Key.home, ShiftReq.no), Command.viewHome, "top"),
    bind(Scope_.viewer, chord(Key.end, ShiftReq.no), Command.viewEnd, "bottom"),
    bind(Scope_.viewer, chord('j'), Command.viewDown, "down"),
    bind(Scope_.viewer, chord('k'), Command.viewUp, "up"),
    bind(Scope_.viewer, chord('l'), Command.toggleLineNumbers, "line numbers"),
    bind(Scope_.viewer, chord('c'), Command.toggleCodeLineNumbers, "code line numbers"),
    // The ruler nudge shares the drag's clamp (`RUL5`); gated so `<`/`>`
    // stay free elsewhere. `[`/`]` are set/diff navigation — not these.
    bind(Scope_.viewer, chord('<'), Command.formatWidthNarrower, "ruler narrower",
        require: CtxFlag.formatPreviewActive),
    bind(Scope_.viewer, chord('>'), Command.formatWidthWider, "ruler wider",
        require: CtxFlag.formatPreviewActive),
    // `ShiftReq.no` on the group, so `Shift-G` below is reachable rather than
    // being absorbed by a shift-agnostic prefix.
    group(Scope_.viewer, chord('g', ShiftReq.no), "goto"),
    bind(Scope_.viewer, chord('g', ShiftReq.no), chord('g'), Command.viewTop, "top"),
    bind(Scope_.viewer, chord('g', ShiftReq.no), chord('l'), Command.startGoto,
        "go to line"),
    bind(Scope_.viewer, chord('g', ShiftReq.yes), Command.viewBottom, "bottom"),
    // Enter and `p` drive the twoslash overlay: the TUI has no pointer to name
    // a signature run, so Enter opens the popup whole and `p` steps between
    // them. Both were TUI-only; binding them here is what lets the GUI grow
    // the same affordance instead of a second spelling of it.
    bind(Scope_.viewer, chord(Key.enter), Command.toggleHoverRegions,
        "expand signature"),
    bind(Scope_.viewer, chord('p'), Command.cycleHoverPopup, "next popup"),

    // `z` — the fold prefix. Over a diff session the family folds FILES
    // (`DVG3`): same vocabulary, the unit that view actually has. The CST
    // fold ranges a source view exposes do not exist there, which is also why
    // the levels are `forbid`den under a session rather than merely unlisted.
    group(Scope_.viewer, chord('z'), "fold"),
    bind(Scope_.viewer, chord('z'), chord('a'), Command.diffToggleFile,
        "toggle file", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('z'), Command.diffToggleFile,
        "toggle file", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('c'), Command.diffToggleFile,
        "collapse file", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('o'), Command.diffToggleFile,
        "expand file", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('r'), Command.diffExpandAll,
        "expand all files", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('m'), Command.diffCollapseAll,
        "collapse all files", require: CtxFlag.hasDiffSession),
    // `DVN2`'s formatting-only hunks and `DVG2`'s hidden context join the
    // family: both are "things this view can hide", which is what `z` means.
    bind(Scope_.viewer, chord('z'), chord('n'), Command.diffToggleFormatting,
        "formatting-only hunks", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('x'), Command.diffToggleContext,
        "unchanged context", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('a'), Command.foldToggle,
        "toggle fold", forbid: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('z'), Command.foldToggle,
        "toggle fold", forbid: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('c'), Command.foldClose,
        "close fold", forbid: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('o'), Command.foldOpen,
        "open fold", forbid: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('r'), Command.foldOpenAll,
        "open all folds", forbid: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chord('m'), Command.foldCloseAll,
        "close all folds", forbid: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('z'), chordRange('1', '9'), Command.foldLevel,
        "fold level", forbid: CtxFlag.hasDiffSession, arg: 1),
    // Search is raw-view only, so `/` is unbound under a preview — which
    // frees it for the DSV grid's filter bar (`DSF1`); `Shift-R` resets the
    // projection (`DSB2`).
    bind(Scope_.viewer, chord('/'), Command.startSearch, "search",
        forbid: CtxFlag.showPreview),
    bind(Scope_.viewer, chord('/'), Command.dsvFilter, "filter rows",
        require: CtxFlag.hasDsvGrid),
    bind(Scope_.viewer, chord('r', ShiftReq.yes), Command.dsvReset,
        "reset sort/filter", require: CtxFlag.hasDsvGrid),
    // A diff session claims the bracket pair ahead of a document set: its
    // changed-file list is the set a reviewer is walking (`DVG1`). This pair
    // of rows is the one place order within a scope decides the outcome.
    bind(Scope_.viewer, chord('['), Command.diffPrevFile, "prev file",
        require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('['), Command.setPrev, "prev document",
        require: CtxFlag.hasDocSet),
    bind(Scope_.viewer, chord(']'), Command.diffNextFile, "next file",
        require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord(']'), Command.setNext, "next document",
        require: CtxFlag.hasDocSet),
    // `{`/`}` step hunk to hunk — vim's paragraph motion, which is what a
    // hunk is to a reviewer moving through a file.
    bind(Scope_.viewer, chord('{'), Command.diffPrevHunk, "prev hunk",
        require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('}'), Command.diffNextHunk, "next hunk",
        require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('s', ShiftReq.no), Command.diffToggleLayout,
        "unified / split", require: CtxFlag.hasDiffSession),
    // `DVN3`'s view is NOT part of the `z` family: `z` means "things this
    // view can hide", and this hides nothing — it re-reads the same rows with
    // the grammar's token boundaries. Next to `s` because both answer "how do
    // I want to look at this diff".
    bind(Scope_.viewer, chord('s', ShiftReq.yes), Command.diffToggleStructural,
        "word / token emphasis", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('+'), Command.diffToggleGap,
        "expand this gap", require: CtxFlag.hasDiffSession),
    // `DST2`: staging keys, lazygit's spelling. They are bound whenever a
    // session is showing; whether THIS session can be staged is a property of
    // the document, and the command reports that in the reviewer's own terms
    // rather than the key silently doing nothing.
    bind(Scope_.viewer, chord(' '), Command.diffStage,
        "stage this hunk", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('u'), Command.diffUnstage,
        "unstage this hunk", require: CtxFlag.hasDiffSession),
    bind(Scope_.viewer, chord('x', ShiftReq.yes), Command.diffDiscard,
        "discard this hunk", require: CtxFlag.hasDiffSession),

    // Horizontal scrolling, in vim's own spelling — `zh`/`zl` mean exactly
    // this there, and they sit in the `z` family without colliding with the
    // fold letters or the diff ones. The shifted arrows are the same thing
    // for a reader who has not learned the prefix: plain `←`/`→` cycle
    // themes, so the modifier is what distinguishes them.
    bind(Scope_.viewer, chord('z'), chord('h'), Command.viewScrollLeft,
        "scroll left"),
    bind(Scope_.viewer, chord('z'), chord('l'), Command.viewScrollRight,
        "scroll right"),
    bind(Scope_.viewer, chord(Key.left, ShiftReq.yes), Command.viewScrollLeft,
        "scroll left"),
    bind(Scope_.viewer, chord(Key.right, ShiftReq.yes), Command.viewScrollRight,
        "scroll right"),
    bind(Scope_.viewer, chord(Key.home, ShiftReq.yes), Command.viewScrollHome,
        "back to the left edge"),
    bind(Scope_.viewer, chord(Key.end, ShiftReq.yes), Command.viewScrollEnd,
        "out to the right edge"),

    // ── shared ───────────────────────────────────────────────────────────
    bind(Scope_.shared_, chord(Key.pageDown), Command.viewPageDown, "page down"),
    bind(Scope_.shared_, chord(Key.pageUp), Command.viewPageUp, "page up"),
    bind(Scope_.shared_, chord(Key.right), Command.themeNext, "next theme"),
    bind(Scope_.shared_, chord(Key.left), Command.themePrev, "prev theme"),
    bind(Scope_.shared_, chord(Key.tab), Command.toggleView, "plain / syntax / preview"),
    bind(Scope_.shared_, chord('e'), Command.toggleExplorer, "toggle explorer"),
    bind(Scope_.shared_, chord('y'), Command.copySelection, "copy selection"),
    bind(Scope_.shared_, chord('q'), Command.quit, "quit"),
    bind(Scope_.shared_, chord('t'), Command.toggleTableCopy, "table copy mode"),
    bind(Scope_.shared_, chord('n', ShiftReq.no), Command.matchNext, "next match",
        require: CtxFlag.hasMatches),
    bind(Scope_.shared_, chord('n', ShiftReq.yes), Command.matchPrev, "prev match",
        require: CtxFlag.hasMatches),
    bind(Scope_.shared_, chord('i'), Command.setIndex, "document index",
        require: CtxFlag.hasDocSet),

    // ── the leader tree (`LMP`) ──────────────────────────────────────────
    // Only commands that already exist are bound here. The map's remaining
    // branches (`s` search, `g` git, `/` grep) are specced and land with the
    // picker's later sources; reserving their letters now is what keeps the
    // map from being rearranged under users later.
    group(Scope_.shared_, chord(leader), "leader"),
    bind(Scope_.shared_, chord(leader), chord('e'), Command.toggleExplorer,
        "toggle explorer"),
    // `reveal` is what opens the panel: the guide consumes the row itself
    // (`LTN11`), so `lanternAll`'s dispatch arms stay empty in both hosts.
    bind(Scope_.shared_, chord(leader), chord('?'), Command.lanternAll,
        "all bindings", reveal: true),

    // `LMP7`: the find branch. `ff` opens the fuzzy file picker (`PKS1`);
    // its siblings (`fr` recent, `fg` git files) land with their sources.
    group(Scope_.shared_, chord(leader), chord('f'), "file/find"),
    bind(Scope_.shared_, chord(leader), chord('f'), chord('f'),
        Command.pickerFiles, "find files"),

    group(Scope_.shared_, chord(leader), chord('v'), "view"),
    bind(Scope_.shared_, chord(leader), chord('v'), chord('r'),
        Command.toggleView, "plain / syntax / preview"),
    bind(Scope_.shared_, chord(leader), chord('v'), chord('n'),
        Command.toggleLineNumbers, "line numbers"),
    bind(Scope_.shared_, chord(leader), chord('v'), chord('c'),
        Command.toggleCodeLineNumbers, "code line numbers"),
    bind(Scope_.shared_, chord(leader), chord('v'), chord('i'),
        Command.toggleInspector, "tree-sitter inspector"),
    // Lowercase + ShiftReq, never `'F'` (`normalise` folds capitals).
    bind(Scope_.shared_, chord(leader), chord('v'), chord('f', ShiftReq.no),
        Command.toggleFormatPreview, "format preview"),
    bind(Scope_.shared_, chord(leader), chord('v'), chord('f', ShiftReq.yes),
        Command.formatterNext, "next formatter"),

    group(Scope_.shared_, chord(leader), chord('u'), "ui"),
    // Spelled lowercase + `ShiftReq.yes`, never `'T'`: `normalise` folds a
    // capital to its lowercase plus Shift, so an uppercase row would be
    // unreachable. `keymap.tableIsSpelledInNormalisedForm` pins that.
    bind(Scope_.shared_, chord(leader), chord('u'), chord('t', ShiftReq.no),
        Command.themeNext, "next theme"),
    bind(Scope_.shared_, chord(leader), chord('u'), chord('t', ShiftReq.yes),
        Command.themePrev, "prev theme"),
    bind(Scope_.shared_, chord(leader), chord('u'), chord('y'),
        Command.toggleAnsiCopy, "ansi copy mode"),
    bind(Scope_.shared_, chord(leader), chord('u'), chord('b'),
        Command.toggleTableCopy, "table copy mode"),
    bind(Scope_.shared_, chord(leader), chord('u'), chord('+'),
        Command.fontBigger, "bigger font"),
    bind(Scope_.shared_, chord(leader), chord('u'), chord('-'),
        Command.fontSmaller, "smaller font"),

    group(Scope_.shared_, chord(leader), chord('d'), "diff",
        require: CtxFlag.hasDiffSession),
    bind(Scope_.shared_, chord(leader), chord('d'), chord('n'),
        Command.diffNextFile, "next file", require: CtxFlag.hasDiffSession),
    bind(Scope_.shared_, chord(leader), chord('d'), chord('p'),
        Command.diffPrevFile, "prev file", require: CtxFlag.hasDiffSession),
    bind(Scope_.shared_, chord(leader), chord('d'), chord('f'),
        Command.diffToggleFile, "toggle file", require: CtxFlag.hasDiffSession),

    // ── the fuzzy picker's modal surface (`PKL7`) ────────────────────────
    // Reachable only while the picker is open; the `picker` scope covers
    // every pane, the focused-pane scopes add their own keys, and an
    // unmatched key falls to the host — prompt text in the input pane, a
    // forwarded key in the preview.
    bind(Scope_.pickerList, chord('j'), Command.pickerDown, "down"),
    bind(Scope_.pickerList, chord('k'), Command.pickerUp, "up"),
    bind(Scope_.pickerList, chord('g', ShiftReq.no), Command.pickerTop,
        "first row"),
    bind(Scope_.pickerList, chord('g', ShiftReq.yes), Command.pickerBottom,
        "last row"),
    bind(Scope_.picker, chord(Key.escape), Command.pickerClose, "close"),
    bind(Scope_.picker, chord(Key.back), Command.pickerClose, "close"),
    bind(Scope_.picker, chord(Key.enter), Command.pickerAccept, "open file"),
    bind(Scope_.picker, chord(Key.backspace), Command.pickerErase, "erase"),
    bind(Scope_.picker, chord(Key.tab, ShiftReq.no), Command.pickerFocusNext,
        "next pane"),
    bind(Scope_.picker, chord(Key.tab, ShiftReq.yes), Command.pickerFocusPrev,
        "prev pane"),
    bind(Scope_.picker, chord(Key.up), Command.pickerUp, "up"),
    bind(Scope_.picker, chord(Key.down), Command.pickerDown, "down"),
    bind(Scope_.picker, chord(Key.pageUp), Command.pickerPageUp, "page up"),
    bind(Scope_.picker, chord(Key.pageDown), Command.pickerPageDown,
        "page down"),
    bind(Scope_.picker, Chord(key: Key.char_, ch: 's', ctrl: true),
        Command.pickerToggleScore, "score breakdown"),
    bind(Scope_.picker, Chord(key: Key.char_, ch: 'd', ctrl: true),
        Command.pickerPreviewDown, "scroll preview down"),
    bind(Scope_.picker, Chord(key: Key.char_, ch: 'u', ctrl: true),
        Command.pickerPreviewUp, "scroll preview up"),

    // ── the tree-sitter inspector pane (`INS`) ───────────────────────────
    bind(Scope_.inspector, chord(Key.down), Command.inspDown, "down"),
    bind(Scope_.inspector, chord('j'), Command.inspDown, "down"),
    bind(Scope_.inspector, chord(Key.up), Command.inspUp, "up"),
    bind(Scope_.inspector, chord('k'), Command.inspUp, "up"),
    bind(Scope_.inspector, chord(Key.pageDown), Command.inspPageDown,
        "page down"),
    bind(Scope_.inspector, chord(Key.pageUp), Command.inspPageUp, "page up"),
    bind(Scope_.inspector, chord(Key.home), Command.inspHome, "first node"),
    bind(Scope_.inspector, chord('g', ShiftReq.no), Command.inspHome,
        "first node"),
    bind(Scope_.inspector, chord(Key.end), Command.inspEnd, "last node"),
    bind(Scope_.inspector, chord('g', ShiftReq.yes), Command.inspEnd,
        "last node"),
    bind(Scope_.inspector, chord(Key.left), Command.inspCollapse,
        "collapse / up"),
    bind(Scope_.inspector, chord('h'), Command.inspCollapse, "collapse / up"),
    bind(Scope_.inspector, chord(Key.right), Command.inspExpand, "expand"),
    bind(Scope_.inspector, chord('l'), Command.inspExpand, "expand"),
    bind(Scope_.inspector, chord(Key.enter), Command.inspActivate,
        "toggle node"),
    bind(Scope_.inspector, chord(Key.escape), Command.inspClose, "close"),
    bind(Scope_.inspector, chord('q'), Command.inspClose, "close"),
    bind(Scope_.inspector, chord('a'), Command.inspToggleAnonymous,
        "anonymous nodes"),
    bind(Scope_.inspector, chord('s'), Command.inspTogglePick,
        "pick from source"),
];

// ---------------------------------------------------------------------------
// Resolution — the framework's algorithms bound to hue's table.
// ---------------------------------------------------------------------------

/// $(REF resolve, sparkles,ui,keymap) over $(LREF hueBindings).
Resolution resolve(scope const Chord[] prefix, in KeyEvent raw,
    in KeyContext ctx) @safe pure nothrow @nogc
    => ui_keymap.resolve(hueBindings, prefix, raw, ctx);

/// $(REF commandFor, sparkles,ui,keymap) over $(LREF hueBindings).
KeyCommand commandFor(in KeyEvent raw, in KeyContext ctx)
    @safe pure nothrow @nogc
    => ui_keymap.commandFor(hueBindings, raw, ctx);

/// $(REF resolveAlways, sparkles,ui,keymap) over $(LREF hueBindings).
Resolution resolveAlways(in KeyEvent raw, in KeyContext ctx)
    @safe pure nothrow @nogc
    => ui_keymap.resolveAlways(hueBindings, raw, ctx);

/// $(REF bindingsAt, sparkles,ui,keymap) over $(LREF hueBindings).
void bindingsAt(Sink)(ref Sink sink, in KeyContext ctx,
    scope const Chord[] prefix = null)
{
    ui_keymap.bindingsAt(sink, hueBindings, ctx, prefix);
}

// ---------------------------------------------------------------------------
// Tests — the oracle IXB7 converts against.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input.events : Mods;

    KeyCommand ch(dchar c, KeyContext ctx = KeyContext.init, Mods m = Mods())
        @safe pure nothrow @nogc
        => commandFor(KeyEvent(Key.char_, c, m), ctx);
    KeyCommand nk(Key k, KeyContext ctx = KeyContext.init, Mods m = Mods())
        @safe pure nothrow @nogc
        => commandFor(KeyEvent(k, 0, m), ctx);
}

@("keymap.tableIsSpelledInNormalisedForm")
@safe pure nothrow @nogc
unittest
{
    // `normalise` folds `A` to `a` + Shift before anything is compared, so a
    // row spelling an uppercase letter is dead on arrival — it matches no
    // event that can ever reach it. That is a silent failure: the binding
    // simply never fires, and only a test that looks for it will say so.
    // (`<leader>uT` shipped in exactly this shape for one edit.)
    foreach (ref b; hueBindings)
        foreach (i; 0 .. b.depth)
        {
            const c = b.path[i];
            assert(!(c.key == Key.char_ && c.ch >= 'A' && c.ch <= 'Z'),
                "spell a shifted letter lowercase + ShiftReq.yes");
            assert(!(c.chEnd != 0 && c.chEnd < c.ch),
                "a chord range must not run backwards");
        }
}

@("keymap.bindingsAtEnumeratesWhatWouldFire")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // The property that makes the table worth having: whatever `bindingsAt`
    // lists, `resolve` actually does. Anything weaker and the guide is a
    // second description of the policy, free to drift from it — which is the
    // defect this whole change exists to remove.
    //
    // Checked at every level, not just the root: a leader tree is exactly
    // where a listing and its behaviour could quietly disagree.
    static void checkLevel(scope const Chord[] prefix, in KeyContext ctx,
        int depthLeft)
    {
        SmallBuffer!(Binding, 128) listed;
        bindingsAt(listed, ctx, prefix);

        foreach (ref b; listed[])
        {
            // A ranged row is listed once but fires for each key in the range;
            // check its first key, which is the one the guide labels.
            const c = b.path[prefix.length];
            const ev = KeyEvent(c.key, c.ch, Mods(ctrl: c.ctrl, alt: c.alt,
                shift: c.shift == ShiftReq.yes));
            const r = resolve(prefix, ev, ctx);

            const isLeaf = b.depth == prefix.length + 1 && b.group.length == 0;
            if (isLeaf)
                assert(r.kind == ResolveKind.command && r.cmd == b.cmd,
                    "a listed command must be the one that fires");
            else
            {
                assert(r.kind == ResolveKind.group,
                    "a listed prefix must actually descend");
                if (depthLeft > 0)
                {
                    Chord[maxPathLength] next;
                    next[0 .. prefix.length] = prefix[];
                    next[prefix.length] = c;
                    checkLevel(next[0 .. prefix.length + 1], ctx, depthLeft - 1);
                }
            }
        }

        // …and nothing is listed twice: a key bound in both `tree` and
        // `shared_` appears once, as the row that would win.
        foreach (i, ref a; listed[])
            foreach (j, ref b; listed[])
                assert(i == j
                    || !sameKey(a.path[prefix.length], b.path[prefix.length]),
                    "a shadowed duplicate must not be listed");
    }

    foreach (ubyte bits; 0 .. 64)
    {
        const ctx = KeyContext(
            treeFocused:    (bits & 1) != 0,
            treeVisible:    (bits & 2) != 0,
            hasMatches:     (bits & 4) != 0,
            hasDocSet:      (bits & 8) != 0,
            hasDiffSession: (bits & 16) != 0,
            showPreview:    (bits & 32) != 0,
        );
        checkLevel(null, ctx, maxPathLength);
    }

    // The picker's modal contexts, per focused pane: the listing/behaviour
    // agreement must hold there too, or the guide would lie inside the modal.
    static immutable Scope_[3] panes =
        [Scope_.pickerInput, Scope_.pickerList, Scope_.pickerPreview];
    foreach (pane; panes)
        checkLevel(null,
            KeyContext(pickerActive: true, pickerFocus: pane), maxPathLength);
}

@("keymap.modesClaimTheKeyboard")
@safe pure nothrow @nogc
unittest
{
    // An open input mode takes Enter/Escape/Backspace before anything else,
    // and swallows the letters that would otherwise be commands.
    auto search = KeyContext(mode: InputMode.search);
    assert(nk(Key.enter, search).cmd == Command.inputAccept);
    assert(nk(Key.backspace, search).cmd == Command.inputBackspace);
    assert(nk(Key.escape, search).cmd == Command.inputCancel);
    assert(ch('e', search).cmd == Command.none, "a letter is text while typing");
    assert(ch('y', search).cmd == Command.none);

    // In NORMAL mode the two diverge, and this pins today's behaviour rather
    // than the behaviour that would be nicer: Android's Back runs the dismiss
    // chain, desktop Escape is unbound. `isDismiss` says they should agree;
    // making them agree is a behaviour change and belongs in its own commit,
    // not smuggled into the oracle a conversion is checked against.
    assert(nk(Key.back).cmd == Command.dismiss);
    assert(nk(Key.escape).cmd == Command.none);
    assert(nk(Key.back, search).cmd == Command.inputCancel);

    // F11 outranks everything — you can always leave fullscreen. That it also
    // outranks a half-typed key sequence is `lantern`'s to assert, since the
    // sequence lives there now.
    assert(nk(Key.f11, search).cmd == Command.toggleFullscreen);
}

@("keymap.focusSelectsThePane")
@safe pure nothrow @nogc
unittest
{
    auto tree = KeyContext(treeFocused: true, treeVisible: true);
    const view = KeyContext.init;

    // The SAME keys drive whichever pane has focus — the property that makes
    // this a context function rather than two disjoint tables.
    assert(ch('j', tree).cmd == Command.treeDown);
    assert(ch('j', view).cmd == Command.viewDown);
    assert(nk(Key.home, tree).cmd == Command.treeHome);
    assert(nk(Key.home, view).cmd == Command.viewHome);

    // …and where they diverge, they diverge completely: `l` opens a tree row
    // but toggles the viewer's gutter.
    assert(ch('l', tree).cmd == Command.treeActivate);
    assert(ch('l', view).cmd == Command.toggleLineNumbers);
    assert(ch('c', tree).cmd == Command.treeCloseAll);
    assert(ch('c', view).cmd == Command.toggleCodeLineNumbers);

    // A focused-but-hidden tree is not a thing the tree table may claim.
    auto hidden = KeyContext(treeFocused: true, treeVisible: false);
    assert(ch('j', hidden).cmd == Command.viewDown);
}

@("keymap.shiftIsPartOfTheBinding")
@safe pure nothrow @nogc
unittest
{
    auto tree = KeyContext(treeFocused: true, treeVisible: true);
    const shift = Mods(shift: true);

    assert(ch('r', tree).cmd == Command.treeRefresh);
    assert(ch('r', tree, shift).cmd == Command.treeReroot);
    assert(ch('h', tree).cmd == Command.treeCollapseOrUp);
    assert(ch('h', tree, shift).cmd == Command.treeToggleHidden);
    // Shift-I toggles ignored files; plain `i` is not a tree binding at all
    // (it belongs to the document set).
    assert(ch('i', tree, shift).cmd == Command.treeToggleIgnored);
    assert(ch('i', tree).cmd == Command.none);
}

@("keymap.shiftedLettersNormaliseAcrossProducers")
@safe pure nothrow @nogc
unittest
{
    auto tree = KeyContext(treeFocused: true, treeVisible: true);

    // The three spellings a real producer may use for Shift-R, all resolving
    // to one command. Found by WIRING this: raylib's `GetCharPressed` returns
    // the shifted character, so a table matching only lowercase+shift would
    // have silently missed every capital.
    assert(ch('r', tree, Mods(shift: true)).cmd == Command.treeReroot); // synthesised
    assert(ch('R', tree, Mods(shift: true)).cmd == Command.treeReroot); // raylib
    assert(ch('R', tree).cmd == Command.treeReroot);                    // bare capital

    // …and the unshifted key still means the other thing.
    assert(ch('r', tree).cmd == Command.treeRefresh);

    // Normalisation must not invent a shift for keys that never had one.
    assert(ch('j', tree).cmd == Command.treeDown);
    assert(ch('J', tree).cmd == Command.treeDown, "shift-j is still down");
}

@("keymap.ctrlChordsOutrankTheLetter")
@safe pure nothrow @nogc
unittest
{
    const ctrl = Mods(ctrl: true);
    // Ctrl-C copies; plain `c` toggles code line numbers. Resolving the chord
    // first is what keeps them from colliding.
    assert(ch('c', KeyContext.init, ctrl).cmd == Command.copySelection);
    assert(ch('c').cmd == Command.toggleCodeLineNumbers);
    assert(ch('=', KeyContext.init, ctrl).cmd == Command.fontBigger);
    assert(ch('-', KeyContext.init, ctrl).cmd == Command.fontSmaller);
    // An unbound chord is not silently the plain binding.
    assert(ch('y', KeyContext.init, ctrl).cmd == Command.none);
}

@("keymap.foldSequenceIsAPrefixNotACommand")
@safe pure nothrow @nogc
unittest
{
    // `z` used to be a command (`foldArm`) that set a flag the next call read
    // back. It is a prefix node now, so it has no answer in a vocabulary that
    // only knows commands — the sequence lives in `lantern`, and
    // `lantern.foldLevelsCarryTheirArgument` and friends assert the same
    // outcomes the flag produced.
    assert(resolve(null, KeyEvent(Key.char_, 'z'), KeyContext.init).kind
        == ResolveKind.group);
    assert(ch('z').cmd == Command.none, "…and so is not a command to a flat caller");

    // What the prefix leads to is still resolvable directly, which is what
    // lets the guide list it without simulating keystrokes.
    const Chord[1] z = [chord('z')];
    assert(resolve(z, KeyEvent(Key.char_, 'c'), KeyContext.init)
        == Resolution(ResolveKind.command, Command.foldClose));
    assert(resolve(z, KeyEvent(Key.char_, '3'), KeyContext.init)
        == Resolution(ResolveKind.command, Command.foldLevel, 3));
    assert(resolve(z, KeyEvent(Key.char_, '0'), KeyContext.init).kind
        == ResolveKind.none, "no level 0");

    // And `c` outside the sequence still means what it always did — the
    // precedence the frame loop encoded by ordering, now by path.
    assert(ch('c').cmd == Command.toggleCodeLineNumbers);
}

@("keymap.leaderFindFilesOpensThePicker")
@safe pure nothrow @nogc
unittest
{
    // `<leader>` and `<leader>f` are prefix nodes; `<leader>ff` is the
    // picker command (`LMP7`/`PKS1`) — from either pane, both being
    // `shared_` rows.
    const Chord[1] l = [chord(leader)];
    const Chord[2] lf = [chord(leader), chord('f')];
    assert(resolve(null, KeyEvent(Key.char_, leader), KeyContext.init).kind
        == ResolveKind.group);
    assert(resolve(l, KeyEvent(Key.char_, 'f'), KeyContext.init).kind
        == ResolveKind.group);
    assert(resolve(lf, KeyEvent(Key.char_, 'f'), KeyContext.init)
        == Resolution(ResolveKind.command, Command.pickerFiles));
    const tree = KeyContext(treeFocused: true, treeVisible: true);
    assert(resolve(lf, KeyEvent(Key.char_, 'f'), tree)
        == Resolution(ResolveKind.command, Command.pickerFiles));
}

@("keymap.contextGatesTheOptionalBindings")
@safe pure nothrow @nogc
unittest
{
    // n/N need matches; [ ] i need a document set. Without them the key is
    // unbound rather than a no-op command the caller must filter.
    assert(ch('n').cmd == Command.none);
    assert(ch('n', KeyContext(hasMatches: true)).cmd == Command.matchNext);
    assert(ch('n', KeyContext(hasMatches: true), Mods(shift: true)).cmd
        == Command.matchPrev);

    assert(ch(']').cmd == Command.none);
    auto set = KeyContext(hasDocSet: true);
    assert(ch(']', set).cmd == Command.setNext);
    assert(ch('[', set).cmd == Command.setPrev);
    assert(ch('i', set).cmd == Command.setIndex);

    // Search is raw-view only, so `/` is unbound under a preview.
    assert(ch('/').cmd == Command.startSearch);
    assert(ch('/', KeyContext(showPreview: true)).cmd == Command.none);
    // …but the tree's filter is not affected by the preview.
    assert(ch('/', KeyContext(treeFocused: true, treeVisible: true,
        showPreview: true)).cmd == Command.treeFilter);
}

@("keymap.diffSessionClaimsBracketsAndTheFoldFamily")
@safe pure nothrow @nogc
unittest
{
    // `DVG1`: over a diff session the brackets walk changed FILES.
    auto diff = KeyContext(hasDiffSession: true);
    assert(ch(']', diff).cmd == Command.diffNextFile);
    assert(ch('[', diff).cmd == Command.diffPrevFile);

    // A diff session outranks a document set on the same keys: the file list
    // is what the reviewer is walking.
    auto both = KeyContext(hasDocSet: true, hasDiffSession: true);
    assert(ch(']', both).cmd == Command.diffNextFile);
    assert(ch(']', KeyContext(hasDocSet: true)).cmd == Command.setNext);

    // `DVG3`: the `z` family folds files, not syntax ranges — the diff view
    // has no CST fold ranges for the other meaning to act on.
    const Chord[1] z = [chord('z')];
    assert(resolve(z, KeyEvent(Key.char_, 'a'), diff).cmd == Command.diffToggleFile);
    assert(resolve(z, KeyEvent(Key.char_, 'c'), diff).cmd == Command.diffToggleFile);
    assert(resolve(z, KeyEvent(Key.char_, 'm'), diff).cmd == Command.diffCollapseAll);
    assert(resolve(z, KeyEvent(Key.char_, 'r'), diff).cmd == Command.diffExpandAll);
    // `DVN2`'s noise fold and `DVG2`'s context join the same family.
    assert(resolve(z, KeyEvent(Key.char_, 'n'), diff).cmd
        == Command.diffToggleFormatting);
    assert(resolve(z, KeyEvent(Key.char_, 'x'), diff).cmd
        == Command.diffToggleContext);
    assert(resolve(z, KeyEvent(Key.char_, 'n'), KeyContext.init).kind
        == ResolveKind.none, "no session, no noise to fold");
    assert(resolve(z, KeyEvent(Key.char_, 'x'), KeyContext.init).kind
        == ResolveKind.none);
    // Levels are meaningless over a flat file list, so they stay unbound.
    assert(resolve(z, KeyEvent(Key.char_, '3'), diff).kind == ResolveKind.none);
    // Without a session the same keys keep their syntax-fold meanings.
    assert(resolve(z, KeyEvent(Key.char_, 'm'), KeyContext.init).cmd
        == Command.foldCloseAll);

    // Hunk motions exist only over a session — there is nothing to step
    // through otherwise, so the keys stay unbound rather than no-ops.
    assert(ch('s', diff).cmd == Command.diffToggleLayout);
    // `DVN3`'s view rides the shifted `s`: same question ("how am I reading
    // this diff"), so it stays out of the `z` fold family, which means
    // hiding. Both spellings the two backends produce must resolve.
    assert(ch('s', diff, Mods(shift: true)).cmd == Command.diffToggleStructural);
    assert(ch('S', diff, Mods(shift: true)).cmd == Command.diffToggleStructural);
    assert(ch('S').cmd == Command.none, "no session, no emphasis to swap");
    assert(ch('+', diff).cmd == Command.diffToggleGap);
    assert(ch('+').cmd == Command.none);
    assert(ch('s').cmd == Command.none, "no session, no layout to toggle");
    assert(ch('}', diff).cmd == Command.diffNextHunk);
    assert(ch('{', diff).cmd == Command.diffPrevHunk);
    assert(ch('}').cmd == Command.none && ch('{').cmd == Command.none);
}

@("keymap.sharedBindingsWorkFromEitherPane")
@safe pure nothrow @nogc
unittest
{
    auto tree = KeyContext(treeFocused: true, treeVisible: true);

    // Tab, the copy keys and the explorer toggle are deliberately NOT
    // pane-scoped — the frame loop has them outside the focus branch, and
    // that is preserved here.
    foreach (ctx; [KeyContext.init, tree])
    {
        assert(nk(Key.tab, ctx).cmd == Command.toggleView);
        assert(ch('y', ctx).cmd == Command.copySelection);
        assert(ch('t', ctx).cmd == Command.toggleTableCopy);
        assert(ch('e', ctx).cmd == Command.toggleExplorer);
    }

    // The arrows ARE pane-scoped, and this is a deliberate change: a focused
    // tree navigates with ←/→ (open a row, collapse it) the way every tree
    // does, which the terminal explorer already did and the window did not.
    // Theme cycling loses the arrows while the tree has focus and keeps them
    // in the viewer, plus `<leader>ut`/`<leader>uT` from anywhere.
    assert(nk(Key.right, KeyContext.init).cmd == Command.themeNext);
    assert(nk(Key.left, KeyContext.init).cmd == Command.themePrev);
    assert(nk(Key.right, tree).cmd == Command.treeActivate);
    assert(nk(Key.left, tree).cmd == Command.treeCollapseOrUp);

    // Paging likewise: whichever pane has focus pages its own rows.
    assert(nk(Key.pageDown, KeyContext.init).cmd == Command.viewPageDown);
    assert(nk(Key.pageDown, tree).cmd == Command.treePageDown);
}

@("keymap.unboundKeysResolveToNone")
@safe pure nothrow @nogc
unittest
{
    // The default answer is `none`, so the frame loop needs no catch-all.
    // (`q` used to be here; it quits now, in both backends.)
    assert(ch('w').cmd == Command.none);
    assert(ch('!').cmd == Command.none);
    assert(nk(Key.f5).cmd == Command.none);
    assert(nk(Key.none).cmd == Command.none);
    assert(commandFor(KeyEvent.init, KeyContext.init).cmd == Command.none);
}

@("keymap.pickerScopesAreModalAndFocusRouted")
@safe pure nothrow @nogc
unittest
{
    // While the picker is open (`PIK1`), only the always + picker scopes are
    // reachable — modality as context gating (`FOC4`), not a second filter.
    auto pk = KeyContext(pickerActive: true); // prompt pane holds focus
    assert(nk(Key.escape, pk).cmd == Command.pickerClose);
    assert(nk(Key.back, pk).cmd == Command.pickerClose,
        "Back closes the picker; the dismiss chain must not also fire");
    assert(nk(Key.enter, pk).cmd == Command.pickerAccept);
    assert(nk(Key.backspace, pk).cmd == Command.pickerErase);
    assert(nk(Key.tab, pk).cmd == Command.pickerFocusNext);
    assert(nk(Key.tab, pk, Mods(shift: true)).cmd == Command.pickerFocusPrev);
    assert(nk(Key.down, pk).cmd == Command.pickerDown);
    assert(nk(Key.pageDown, pk).cmd == Command.pickerPageDown);

    // A letter is prompt text, and nothing below the modal can fire.
    assert(ch('j', pk).cmd == Command.none);
    assert(ch('q', pk).cmd == Command.none, "quit is unreachable under it");
    assert(ch('e', pk).cmd == Command.none);
    assert(ch('c', pk, Mods(ctrl: true)).cmd == Command.none,
        "the ctrl scope is gated off while the picker is open");
    assert(ch('s', pk, Mods(ctrl: true)).cmd == Command.pickerToggleScore);
    assert(ch('d', pk, Mods(ctrl: true)).cmd == Command.pickerPreviewDown);

    // The focused pane adds its keys: the list navigates with letters…
    auto lst = KeyContext(pickerActive: true, pickerFocus: Scope_.pickerList);
    assert(ch('j', lst).cmd == Command.pickerDown);
    assert(ch('k', lst).cmd == Command.pickerUp);
    assert(ch('g', lst).cmd == Command.pickerTop);
    assert(ch('G', lst).cmd == Command.pickerBottom);

    // …while the preview resolves only the shared picker keys — everything
    // else is unbound so the host forwards it to the document pane.
    auto pv = KeyContext(pickerActive: true,
        pickerFocus: Scope_.pickerPreview);
    assert(ch('j', pv).cmd == Command.none);
    assert(nk(Key.enter, pv).cmd == Command.pickerAccept);
    assert(nk(Key.escape, pv).cmd == Command.pickerClose);

    // The always scope still outranks the modal (`LTN10`'s doctrine): a
    // half-typed anything can never trap you in a fullscreen window.
    assert(nk(Key.f11, pk).cmd == Command.toggleFullscreen);
}

@("keymap.horizontalScrollHasKeysNotJustAScrollbar")
@safe pure nothrow @nogc
unittest
{
    auto view = KeyContext.init;
    auto diff = KeyContext(hasDiffSession: true);

    // vim's own spelling, and it must survive the `z` family's two shapes:
    // the fold letters without a session, the file letters with one.
    static immutable Chord[1] zPrefix = [chord('z')];
    const z = zPrefix[];
    assert(resolve(z, KeyEvent(Key.char_, 'h'), view).cmd
        == Command.viewScrollLeft);
    assert(resolve(z, KeyEvent(Key.char_, 'l'), view).cmd
        == Command.viewScrollRight);
    assert(resolve(z, KeyEvent(Key.char_, 'h'), diff).cmd
        == Command.viewScrollLeft, "a diff scrolls sideways too — its tables "
        ~ "are the widest content hue renders");

    // The shifted arrows, for a reader who has not learned the prefix. Plain
    // arrows still cycle themes, which is what the modifier distinguishes.
    const shift = Mods(shift: true);
    assert(nk(Key.left, view, shift).cmd == Command.viewScrollLeft);
    assert(nk(Key.right, view, shift).cmd == Command.viewScrollRight);
    assert(nk(Key.left, view).cmd == Command.themePrev);
    assert(nk(Key.right, view).cmd == Command.themeNext);

    // `Home` was matching with or without Shift, so the shifted spelling had
    // to be taken off it before it could mean anything else.
    assert(nk(Key.home, view).cmd == Command.viewHome);
    assert(nk(Key.home, view, shift).cmd == Command.viewScrollHome);
    assert(nk(Key.end, view).cmd == Command.viewEnd);
    assert(nk(Key.end, view, shift).cmd == Command.viewScrollEnd);
}
