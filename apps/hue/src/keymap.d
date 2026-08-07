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
    $(LI $(B lantern) (`docs/specs/hue/lantern.md`), the key guide, is an
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
$(LREF terminal) scopes are the ones that used to `return` rather than fall
through.

$(B This is hue's policy, not the framework's.) Which key does what, and which
context gates it, is exactly the application's business — the dividing line the
extraction work has held throughout. What belongs to `sparkles:input` is the
$(I vocabulary) the key arrives in.
*/
module keymap;

import sparkles.input.events : Key, KeyEvent;

@safe pure nothrow @nogc:

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
    toggleTableCopy,       /// `t`
    startSearch,           /// `/`
    startGoto,             /// `gl`
    lanternAll,            /// `<leader>?` — list every binding live here
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
}

/// A resolved command plus its argument (only `foldLevel` uses one: the
/// nesting level 1–9). A struct rather than nine enum members, so the fold
/// family stays one row in the table and one case at the call site.
struct KeyCommand
{
    Command cmd;
    ubyte arg;
}

// ---------------------------------------------------------------------------
// The binding table's vocabulary.
// ---------------------------------------------------------------------------

/**
Whether a binding cares about Shift.

Three states rather than a `bool`, because hue's bindings genuinely want all
three and conflating them loses a distinction the old chain expressed by
$(I where) it tested `mods.shift`. `j` scrolls down whether or not Shift is
held ($(LREF ignore)); `r` refreshes only unshifted and `R` re-roots only
shifted ($(LREF no)/$(LREF yes)). A two-state encoding would need the shifted
row to be checked first and would silently break if the table were reordered —
this one does not depend on order at all.
*/
enum ShiftReq : ubyte
{
    ignore, /// Shift is not part of the binding
    no,     /// binds only when Shift is $(I not) held
    yes,    /// binds only when Shift $(I is) held
}

/**
One key in a binding's path.

`chEnd` makes a contiguous code-point range one row: `z1`–`z9` is a single
binding whose $(LREF KeyCommand.arg) is derived from which key landed, so the
fold family stays one table row and one lantern item — which is also the
spelling `CFG6` already proposed (`"1-9": "foldLevel"`).
*/
struct Chord
{
    Key key = Key.none;
    dchar ch = 0;    /// the code point, when `key == Key.char_`
    dchar chEnd = 0; /// inclusive range end; `0` for a single code point
    ShiftReq shift;
    bool ctrl;
    bool alt;
}

/// A `char_` chord.
Chord chord(dchar ch, ShiftReq shift = ShiftReq.ignore)
    => Chord(key: Key.char_, ch: ch, shift: shift);

/// A named-key chord.
Chord chord(Key key, ShiftReq shift = ShiftReq.ignore)
    => Chord(key: key, shift: shift);

/// A `char_` chord spanning `lo`..`hi` inclusive.
Chord chordRange(dchar lo, dchar hi) => Chord(key: Key.char_, ch: lo, chEnd: hi);

/**
Which surface a binding belongs to — $(B and, by declaration order, when it is
resolved).

This is the `if`/`else` chain `commandFor` used to be, turned into data. Reading
top to bottom gives the old precedence: the always-available keys, then an open
input mode, then an armed fold sequence (diff-flavoured first), then Ctrl
chords, then whichever pane has focus, then the keys both panes share.
*/
enum Scope_ : ubyte
{
    always,  /// resolves in every context (fullscreen, dismiss)
    input,   /// a line-editing mode owns the keyboard
    ctrl,    /// a Ctrl chord, before the plain letter is considered
    tree,    /// the explorer pane, while focused and shown
    viewer,  /// the document viewer (i.e. not the above)
    shared_, /// available from either pane
}

/**
Whether an active scope stops resolution.

A terminal scope is one the old chain `return`ed from: while a line-editing mode
is open, a letter is $(I text) and must not reach a command. The pane scopes are
deliberately not terminal — that is what lets `Tab` and the theme arrows work
with either pane focused.
*/
bool terminal(Scope_ s) => s == Scope_.input || s == Scope_.ctrl;

/// Which $(LREF KeyContext) facts a binding may require or forbid, as bits so a
/// row states its gate inline instead of the caller filtering afterwards.
enum CtxFlag : ubyte
{
    hasMatches     = 1 << 0,
    hasDocSet      = 1 << 1,
    hasDiffSession = 1 << 2,
    showPreview    = 1 << 3,
}

/// `ctx`'s facts as $(LREF CtxFlag) bits.
ubyte ctxBits(in KeyContext ctx)
{
    ubyte b;
    if (ctx.hasMatches)     b |= CtxFlag.hasMatches;
    if (ctx.hasDocSet)      b |= CtxFlag.hasDocSet;
    if (ctx.hasDiffSession) b |= CtxFlag.hasDiffSession;
    if (ctx.showPreview)    b |= CtxFlag.showPreview;
    return b;
}

/// Which input mode a binding applies in. Only Escape and the platform Back key
/// need this: they mean different things while typing than they do at rest.
enum ModeReq : ubyte
{
    any,
    normal,  /// only outside a line-editing mode
    editing, /// only inside one
}

/// The longest binding path the table may hold — enough for the leader tree
/// (`<leader> f f`). Inline, so a `Binding` carries no indirection.
enum maxPathLength = 3;

/**
One row of $(LREF hueBindings): a key path, what it does, and where it applies.

`desc` and `group` exist for $(LREF bindingsAt)'s readers — the guide renders
them, and a non-empty `group` marks the row as a prefix node rather than a
command. They are `string` literals, so a row costs no allocation to read.
*/
struct Binding
{
    Chord[maxPathLength] path;
    ubyte depth = 1; /// how many of `path` are used
    Scope_ scope_;
    Command cmd;
    ubyte arg;       /// for a ranged chord, the value the range's first key maps to
    ubyte require;   /// $(LREF CtxFlag) bits that must all be set
    ubyte forbid;    /// $(LREF CtxFlag) bits that must all be clear
    ModeReq mode;
    string desc;     /// what it does, for the guide
    /// Non-empty ⇒ a prefix node (`"fold"`), not a command. Stored bare: the
    /// panel adds the `+` marker, and a name carrying one renders `++fold`.
    string group;
}

/// Builds a one-chord row. Optional arguments are named at every call site, so
/// the table below reads as a table rather than as positional noise.
private Binding bind(Scope_ scope_, Chord a, Command cmd, string desc,
    ubyte require = 0, ubyte forbid = 0, ModeReq mode = ModeReq.any, ubyte arg = 0)
{
    Binding b;
    b.path[0] = a;
    b.depth = 1;
    b.scope_ = scope_;
    b.cmd = cmd;
    b.desc = desc;
    b.require = require;
    b.forbid = forbid;
    b.mode = mode;
    b.arg = arg;
    return b;
}

/// ditto, for a two-chord path (`z c`, `<leader> e`).
private Binding bind(Scope_ scope_, Chord a, Chord b_, Command cmd, string desc,
    ubyte require = 0, ubyte forbid = 0, ubyte arg = 0)
{
    Binding b = bind(scope_, a, cmd, desc, require, forbid, ModeReq.any, arg);
    b.path[1] = b_;
    b.depth = 2;
    return b;
}

/// ditto, for a three-chord path (`<leader> v r`).
private Binding bind(Scope_ scope_, Chord a, Chord b_, Chord c_, Command cmd,
    string desc, ubyte require = 0, ubyte forbid = 0)
{
    Binding b = bind(scope_, a, b_, cmd, desc, require, forbid);
    b.path[2] = c_;
    b.depth = 3;
    return b;
}

/**
Builds a $(B prefix node) — a key that opens a group rather than running a
command.

A group row carries no `cmd`; it exists so the path is nameable and so the
guide has something to label the key with. Declare one before its children:
resolution does not require it (a deeper row makes its own prefix descendable),
but $(LREF bindingsAt) lists whichever row it meets first, and the group's
`+name` is the better label.
*/
private Binding group(Scope_ scope_, Chord a, string name,
    ubyte require = 0, ubyte forbid = 0)
{
    Binding b = bind(scope_, a, Command.none, name, require, forbid);
    b.group = name;
    return b;
}

/// ditto, for a nested group (`<leader> v`).
private Binding group(Scope_ scope_, Chord a, Chord b_, string name,
    ubyte require = 0, ubyte forbid = 0)
{
    Binding b = bind(scope_, a, b_, Command.none, name, require, forbid);
    b.group = name;
    return b;
}

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
    bind(Scope_.always, chord(Key.back), Command.dismiss, "back",
        mode: ModeReq.normal),

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
    bind(Scope_.viewer, chord(Key.home), Command.viewHome, "top"),
    bind(Scope_.viewer, chord(Key.end), Command.viewEnd, "bottom"),
    bind(Scope_.viewer, chord('j'), Command.viewDown, "down"),
    bind(Scope_.viewer, chord('k'), Command.viewUp, "up"),
    bind(Scope_.viewer, chord('l'), Command.toggleLineNumbers, "line numbers"),
    bind(Scope_.viewer, chord('c'), Command.toggleCodeLineNumbers, "code line numbers"),
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
    // Search is raw-view only, so `/` is unbound under a preview.
    bind(Scope_.viewer, chord('/'), Command.startSearch, "search",
        forbid: CtxFlag.showPreview),
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

    // ── shared ───────────────────────────────────────────────────────────
    bind(Scope_.shared_, chord(Key.pageDown), Command.viewPageDown, "page down"),
    bind(Scope_.shared_, chord(Key.pageUp), Command.viewPageUp, "page up"),
    bind(Scope_.shared_, chord(Key.right), Command.themeNext, "next theme"),
    bind(Scope_.shared_, chord(Key.left), Command.themePrev, "prev theme"),
    bind(Scope_.shared_, chord(Key.tab), Command.toggleView, "raw / preview"),
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
    // branches (`f` find, `s` search, `g` git, `/` grep) are specced and land
    // with the picker; reserving their letters now is what keeps the map from
    // being rearranged under users later.
    group(Scope_.shared_, chord(leader), "leader"),
    bind(Scope_.shared_, chord(leader), chord('e'), Command.toggleExplorer,
        "toggle explorer"),
    bind(Scope_.shared_, chord(leader), chord('?'), Command.lanternAll,
        "all bindings"),

    group(Scope_.shared_, chord(leader), chord('v'), "view"),
    bind(Scope_.shared_, chord(leader), chord('v'), chord('r'),
        Command.toggleView, "raw / preview"),
    bind(Scope_.shared_, chord(leader), chord('v'), chord('n'),
        Command.toggleLineNumbers, "line numbers"),
    bind(Scope_.shared_, chord(leader), chord('v'), chord('c'),
        Command.toggleCodeLineNumbers, "code line numbers"),

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
];

// ---------------------------------------------------------------------------
// Resolution.
// ---------------------------------------------------------------------------

/**
Whether `k` is the key `c` names, ignoring context.

$(B A modifier a chord does not name is ignored, not required to be absent.)
`Ctrl-Up` scrolls the viewer because `Up` binds scrolling and says nothing about
Ctrl — which is what the `if` chain did, since its Ctrl block only ever guarded
`char_` keys. Requiring equality instead would silently unbind every chorded
arrow and page key.

That is safe for letters precisely because $(LREF Scope_.ctrl) is
$(LREF terminal): a Ctrl'd letter resolves there or nowhere, so it can never
reach a plain-letter row that happens to ignore Ctrl.
*/
bool matches(in Chord c, in KeyEvent k)
{
    if (c.ctrl && !k.mods.ctrl)
        return false;
    if (c.alt && !k.mods.alt)
        return false;
    final switch (c.shift)
    {
        case ShiftReq.ignore: break;
        case ShiftReq.no:  if (k.mods.shift) return false; break;
        case ShiftReq.yes: if (!k.mods.shift) return false; break;
    }
    if (c.key != k.key)
        return false;
    if (c.key != Key.char_)
        return true;
    return c.chEnd ? (k.ch >= c.ch && k.ch <= c.chEnd) : k.ch == c.ch;
}

/// Whether two chords name the same key — path comparison, no live event.
/// Exact, including `shift`: `g` and `Shift-G` are different bindings and must
/// both be listed, so the guide's de-duplication must not conflate them.
bool sameKey(in Chord a, in Chord b)
    => a.key == b.key && a.ch == b.ch && a.chEnd == b.chEnd
    && a.shift == b.shift && a.ctrl == b.ctrl && a.alt == b.alt;

/**
Whether a table chord accepts a chord already typed — prefix comparison.

Deliberately $(I not) $(LREF sameKey). A pending chord records what the user
actually pressed (Shift held or not); a table row may be shift-agnostic
($(LREF ShiftReq.ignore)), in which case it accepts either. Comparing those
exactly would make every prefix under a shift-agnostic row unreachable.

The case that forced this: `g` opens the goto group while `Shift-G` jumps to
the bottom. The group row has to be `ShiftReq.no` so `G` is not swallowed by
it — and then a typed `g`, which records `ShiftReq.no`, has to still match it.
*/
bool acceptsTyped(in Chord table, in Chord typed)
    => table.key == typed.key && table.ch == typed.ch
    && table.ctrl == typed.ctrl && table.alt == typed.alt
    && (table.shift == ShiftReq.ignore || table.shift == typed.shift);

/// Whether `s` applies at all in `ctx` — the conditions the old `if` chain
/// tested before entering each of its blocks.
bool active(Scope_ s, in KeyContext ctx, in KeyEvent k)
    => s == Scope_.ctrl
        ? (k.mods.ctrl && k.key == Key.char_)
        : reachable(s, ctx);

/**
Whether `s` applies in `ctx` for reasons that do not depend on the key.

Every scope but $(LREF Scope_.ctrl) is gated purely by context, which is what
lets $(LREF bindingsAt) enumerate without a key in hand. `ctrl` is the
exception — it is gated by the keystroke itself — and its rows carry that in
their chords, so listing them unconditionally is correct.
*/
bool reachable(Scope_ s, in KeyContext ctx)
{
    final switch (s)
    {
        case Scope_.always:  return true;
        case Scope_.input:   return ctx.mode != InputMode.normal;
        case Scope_.ctrl:    return true;
        case Scope_.tree:    return ctx.treeFocused && ctx.treeVisible;
        case Scope_.viewer:  return !(ctx.treeFocused && ctx.treeVisible);
        case Scope_.shared_: return true;
    }
}

/**
Whether an active scope hides every later scope from $(LREF bindingsAt).

Narrower than $(LREF terminal), and the difference is the whole reason both
exist. `input` swallows $(I every) key while it is active, so nothing below it
is reachable and listing it would be a lie. $(LREF Scope_.ctrl) is terminal
during resolution but swallows only Ctrl'd letters — which are exactly its own
rows — so the plain letters below it stay reachable and must still be listed.
*/
private bool hidesLaterScopes(Scope_ s) => s == Scope_.input;

/// Whether `b`'s context gates are satisfied — the `hasMatches`/`hasDocSet`/…
/// conditions, plus the input-mode requirement Escape and Back need.
private bool gated(in Binding b, in KeyContext ctx)
{
    const bits = ctxBits(ctx);
    if ((bits & b.require) != b.require)
        return false;
    if (bits & b.forbid)
        return false;
    final switch (b.mode)
    {
        case ModeReq.any:     return true;
        case ModeReq.normal:  return ctx.mode == InputMode.normal;
        case ModeReq.editing: return ctx.mode != InputMode.normal;
    }
}

/**
Normalises a key event so one table row covers every producer's spelling of it.

Producers disagree about how a shifted letter arrives. raylib's
`GetCharPressed` yields the SHIFTED character ('R') and separately reports
`shift`; a terminal may send 'R' with no modifier at all; a synthesised event
may send 'r' + shift. All three mean one keystroke, so normalise here — once —
rather than spelling both cases in every table row, or asking each producer to
normalise, which is how producers drift apart again.
*/
KeyEvent normalise(in KeyEvent raw)
{
    KeyEvent k = raw;
    if (k.key == Key.char_ && k.ch >= 'A' && k.ch <= 'Z')
    {
        k.ch += 'a' - 'A';
        k.mods.shift = true;
    }
    return k;
}

/// What a key resolved to under a prefix.
enum ResolveKind : ubyte
{
    none,    /// not bound here
    group,   /// a prefix node — more keys are expected
    command, /// a command, ready to run
}

/// ditto
struct Resolution
{
    ResolveKind kind;
    Command cmd;
    ubyte arg;
}

/**
Resolves `raw` against the table, given the chords already typed.

A lookup over $(LREF hueBindings), walking $(LREF Scope_) in declaration order.
That order mirrors the frame loop's own precedence, which is load-bearing: a
Ctrl chord resolves before the plain letter, an open input mode claims
Enter/Escape/Backspace before anything else sees them, and a focused tree claims
`j` before the viewer does. An active $(LREF terminal) scope ends the search
whether or not it matched.

A key resolves to $(LREF ResolveKind.group) when the row it matched has more
chords after this one — so a prefix is descendable whether or not anyone wrote
an explicit $(LREF group) row for it. That is what keeps the table's shape and
its behaviour from being able to disagree.
*/
Resolution resolve(scope const Chord[] prefix, in KeyEvent raw, in KeyContext ctx)
{
    const k = normalise(raw);
    const depth = prefix.length;

    static foreach (s; __traits(allMembers, Scope_))
    {{
        enum sc = __traits(getMember, Scope_, s);
        if (active(sc, ctx, k))
        {
            foreach (ref b; hueBindings)
            {
                if (b.scope_ != sc || b.depth <= depth || !gated(b, ctx))
                    continue;
                bool under = true;
                foreach (i, ref p; prefix)
                    if (!acceptsTyped(b.path[i], p))
                    {
                        under = false;
                        break;
                    }
                if (!under || !matches(b.path[depth], k))
                    continue;
                if (b.depth > depth + 1)
                    return Resolution(ResolveKind.group);
                if (b.group.length)
                    return Resolution(ResolveKind.group);
                const arg = b.path[depth].chEnd
                    ? cast(ubyte)(b.arg + (k.ch - b.path[depth].ch))
                    : b.arg;
                return Resolution(ResolveKind.command, b.cmd, arg);
            }
            if (terminal(sc))
                return Resolution(ResolveKind.none);
        }
    }}
    return Resolution(ResolveKind.none);
}

/**
The keymap, for a caller with no pending prefix.

Returns $(LREF Command.none) both when `k` is unbound and when it opens a
group — a caller using this entry point has nowhere to put the pending chord,
so a prefix key is simply not a command to it. Drive
$(REF step, lantern) instead to reach anything behind a prefix.
*/
KeyCommand commandFor(in KeyEvent raw, in KeyContext ctx)
{
    const r = resolve(null, raw, ctx);
    return r.kind == ResolveKind.command
        ? KeyCommand(r.cmd, r.arg) : KeyCommand(Command.none);
}

/// Resolves only the always-available bindings — the ones that outrank a
/// pending prefix, so Escape and fullscreen keep working mid-sequence.
Resolution resolveAlways(in KeyEvent raw, in KeyContext ctx)
{
    const k = normalise(raw);
    foreach (ref b; hueBindings)
    {
        if (b.scope_ != Scope_.always || b.depth != 1 || !gated(b, ctx))
            continue;
        if (matches(b.path[0], k))
            return Resolution(ResolveKind.command, b.cmd, b.arg);
    }
    return Resolution(ResolveKind.none);
}

/**
The other direction: which bindings are reachable in `ctx`.

$(LREF commandFor) answers "what does this key do"; this answers "which keys are
available", which is what the guide renders and what a `--show-config`-style
dump would list. Rows are written to `sink` in resolution order, so the first
row for a given key is the one that would actually fire — a shadowed duplicate
(the same key bound in both `tree` and `shared_`) is dropped rather than listed
twice.

`sink` must accept `~=` and be readable by index — a
$(REF SmallBuffer, sparkles,base,smallbuffer) is the intended argument, and
the whole walk allocates nothing.
*/
void bindingsAt(Sink)(ref Sink sink, in KeyContext ctx, scope const Chord[] prefix = null)
{
    static foreach (s; __traits(allMembers, Scope_))
    {{
        enum sc = __traits(getMember, Scope_, s);
        if (reachable(sc, ctx))
        {
            foreach (ref b; hueBindings)
            {
                if (b.scope_ != sc || b.depth <= prefix.length || !gated(b, ctx))
                    continue;
                bool underPrefix = true;
                foreach (i, ref p; prefix)
                    if (!acceptsTyped(b.path[i], p))
                    {
                        underPrefix = false;
                        break;
                    }
                if (!underPrefix)
                    continue;
                const next = b.path[prefix.length];
                bool shadowed;
                foreach (ref seen; sink[])
                    if (sameKey(seen.path[prefix.length], next))
                    {
                        shadowed = true;
                        break;
                    }
                if (!shadowed)
                    sink ~= b;
            }
            if (hidesLaterScopes(sc))
                return;
        }
    }}
}

// ---------------------------------------------------------------------------
// Tests — the oracle IXB7 converts against.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input.events : Mods;

    KeyCommand ch(dchar c, KeyContext ctx = KeyContext.init, Mods m = Mods())
        => commandFor(KeyEvent(Key.char_, c, m), ctx);
    KeyCommand nk(Key k, KeyContext ctx = KeyContext.init, Mods m = Mods())
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

    foreach (ubyte bits; 0 .. 32)
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
