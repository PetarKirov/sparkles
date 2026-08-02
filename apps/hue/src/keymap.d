/**
hue's keyboard policy as a $(B pure function) (`IXB7` groundwork).

The GUI decides what a key means with ~45 `IsKeyPressed(KEY_X)` calls scattered
through a 400-line stretch of the frame loop, each carrying its own share of the
context — is the tree focused, is an input mode open, is a fold sequence armed.
That is untestable by construction: `gui.d` has no unittests and cannot get any,
because every one of those decisions is entangled with a live window.

This module is the decision alone: $(LREF commandFor) maps a
$(REF KeyEvent, sparkles,input,events) plus an explicit $(LREF KeyContext) onto
a $(LREF Command). No raylib, no window, no mutable app state — so the whole
keymap is checkable in a unittest, which is what makes converting the frame loop
to consume events (`IXB7`) a mechanical change against a fixed oracle rather
than a rewrite with nothing to check it.

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
    bool foldArmed;      /// a `z` fold sequence is waiting for its next key
    bool hasMatches;     /// a search produced matches (enables n / N)
    bool hasDocSet;      /// a multi-document set is loaded (enables [ / ] / i)
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
    toggleAnsiCopy,        /// `y`
    toggleTableCopy,       /// `t`
    startSearch,           /// `/`
    startGoto,             /// `g`
    foldArm,               /// `z` — arms the fold sequence below

    // The armed fold sequence (`FLD5`). `foldLevel` carries 1–9 in
    // $(LREF KeyCommand.arg).
    foldToggle, foldClose, foldOpen, foldOpenAll, foldCloseAll,
    foldLevel,
}

/// A resolved command plus its argument (only `foldLevel` uses one: the
/// nesting level 1–9). A struct rather than nine enum members, so the fold
/// family stays one row in the table and one case at the call site.
struct KeyCommand
{
    Command cmd;
    ubyte arg;
}

/**
The keymap. Returns $(LREF Command.none) when `k` is not bound in `ctx`.

Ordering mirrors the frame loop's own precedence, which is load-bearing: an
armed fold sequence claims letters that otherwise toggle things, and an open
input mode claims Enter/Escape/Backspace before anything else sees them.
*/
KeyCommand commandFor(in KeyEvent k, in KeyContext ctx)
{
    // F11 outranks every mode — you can always leave fullscreen.
    if (k.key == Key.f11)
        return KeyCommand(Command.toggleFullscreen);

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
    if (k.key == Key.escape || k.key == Key.back)
    {
        if (ctx.mode != InputMode.normal)
            return KeyCommand(Command.inputCancel);
        return KeyCommand(k.key == Key.back ? Command.dismiss : Command.none);
    }

    // A line-editing mode owns the keyboard while it is open.
    if (ctx.mode != InputMode.normal)
    {
        switch (k.key)
        {
            case Key.backspace: return KeyCommand(Command.inputBackspace);
            case Key.enter:     return KeyCommand(Command.inputAccept);
            default:            return KeyCommand(Command.none);
        }
    }

    // An armed `z` claims the next key (and only for the viewer — the tree
    // has no folds), so `c`/`o`/`r` mean fold operations rather than their
    // normal-mode meanings.
    if (ctx.foldArmed)
    {
        if (k.key == Key.char_)
            switch (k.ch)
            {
                case 'a', 'z': return KeyCommand(Command.foldToggle);
                case 'c':      return KeyCommand(Command.foldClose);
                case 'o':      return KeyCommand(Command.foldOpen);
                case 'r':      return KeyCommand(Command.foldOpenAll);
                case 'm':      return KeyCommand(Command.foldCloseAll);
                case '1': .. case '9':
                    return KeyCommand(Command.foldLevel,
                        cast(ubyte)(k.ch - '0'));
                default: break;
            }
        return KeyCommand(Command.none); // an unrecognised key just disarms
    }

    // Ctrl-chorded bindings, before the plain-letter table claims the letter.
    if (k.mods.ctrl && k.key == Key.char_)
        switch (k.ch)
        {
            case 'c': return KeyCommand(Command.copySelection);
            case '=', '+': return KeyCommand(Command.fontBigger);
            case '-': return KeyCommand(Command.fontSmaller);
            default: return KeyCommand(Command.none);
        }

    // The explorer pane's own keys, while it is focused AND shown.
    if (ctx.treeFocused && ctx.treeVisible)
    {
        switch (k.key)
        {
            case Key.down:  return KeyCommand(Command.treeDown);
            case Key.up:    return KeyCommand(Command.treeUp);
            case Key.home:  return KeyCommand(Command.treeHome);
            case Key.end:   return KeyCommand(Command.treeEnd);
            case Key.enter: return KeyCommand(Command.treeActivate);
            default: break;
        }
        if (k.key == Key.char_)
            switch (k.ch)
            {
                case 'j': return KeyCommand(Command.treeDown);
                case 'k': return KeyCommand(Command.treeUp);
                case 'l': return KeyCommand(Command.treeActivate);
                case 'r': return KeyCommand(k.mods.shift
                    ? Command.treeReroot : Command.treeRefresh);
                case 'i': if (k.mods.shift)
                    return KeyCommand(Command.treeToggleIgnored);
                    break;
                case 'u': return KeyCommand(Command.treeParent);
                case ']': return KeyCommand(Command.treeNextChange);
                case '[': return KeyCommand(Command.treePrevChange);
                case 'c': return KeyCommand(Command.treeCloseAll);
                case 'h': return KeyCommand(k.mods.shift
                    ? Command.treeToggleHidden : Command.treeCollapseOrUp);
                case '/': return KeyCommand(Command.treeFilter);
                case 'e': return KeyCommand(Command.toggleExplorer);
                default: break;
            }
        // Fall through to the shared normal-mode table below: the theme
        // arrows, Tab, and the copy-mode toggles work with either pane
        // focused, exactly as the frame loop has them.
    }
    else
    {
        // Viewer scrolling — the same keys the tree uses for its rows.
        switch (k.key)
        {
            case Key.down: return KeyCommand(Command.viewDown);
            case Key.up:   return KeyCommand(Command.viewUp);
            case Key.home: return KeyCommand(Command.viewHome);
            case Key.end:  return KeyCommand(Command.viewEnd);
            default: break;
        }
        if (k.key == Key.char_)
            switch (k.ch)
            {
                case 'j': return KeyCommand(Command.viewDown);
                case 'k': return KeyCommand(Command.viewUp);
                case 'l': return KeyCommand(Command.toggleLineNumbers);
                case 'c': return KeyCommand(Command.toggleCodeLineNumbers);
                case 'z': return KeyCommand(Command.foldArm);
                case 'g': return KeyCommand(Command.startGoto);
                case '/': return ctx.showPreview
                    ? KeyCommand(Command.none)  // search is raw-view only
                    : KeyCommand(Command.startSearch);
                case '[': return ctx.hasDocSet
                    ? KeyCommand(Command.setPrev) : KeyCommand(Command.none);
                case ']': return ctx.hasDocSet
                    ? KeyCommand(Command.setNext) : KeyCommand(Command.none);
                default: break;
            }
    }

    // Shared by both panes.
    switch (k.key)
    {
        case Key.pageDown: return KeyCommand(Command.viewPageDown);
        case Key.pageUp:   return KeyCommand(Command.viewPageUp);
        case Key.right:    return KeyCommand(Command.themeNext);
        case Key.left:     return KeyCommand(Command.themePrev);
        case Key.tab:      return KeyCommand(Command.toggleView);
        default: break;
    }
    if (k.key == Key.char_)
        switch (k.ch)
        {
            case 'e': return KeyCommand(Command.toggleExplorer);
            case 'y': return KeyCommand(Command.toggleAnsiCopy);
            case 't': return KeyCommand(Command.toggleTableCopy);
            case 'n': return ctx.hasMatches
                ? KeyCommand(k.mods.shift ? Command.matchPrev : Command.matchNext)
                : KeyCommand(Command.none);
            case 'i': return ctx.hasDocSet
                ? KeyCommand(Command.setIndex) : KeyCommand(Command.none);
            default: break;
        }

    return KeyCommand(Command.none);
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

    // F11 outranks everything — you can always leave fullscreen.
    assert(nk(Key.f11, search).cmd == Command.toggleFullscreen);
    assert(nk(Key.f11, KeyContext(foldArmed: true)).cmd == Command.toggleFullscreen);
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

@("keymap.foldSequenceClaimsItsKeys")
@safe pure nothrow @nogc
unittest
{
    assert(ch('z').cmd == Command.foldArm);

    auto armed = KeyContext(foldArmed: true);
    assert(ch('a', armed).cmd == Command.foldToggle);
    assert(ch('z', armed).cmd == Command.foldToggle);
    assert(ch('o', armed).cmd == Command.foldOpen);
    assert(ch('m', armed).cmd == Command.foldCloseAll);

    // While armed, `c` and `r` mean folds — NOT their normal-mode meanings.
    // This is the precedence the frame loop encodes by ordering; here it is
    // asserted.
    assert(ch('c', armed).cmd == Command.foldClose);
    assert(ch('c').cmd == Command.toggleCodeLineNumbers);
    assert(ch('r', armed).cmd == Command.foldOpenAll);

    // z1–z9 carry the level as an argument rather than nine enum members.
    assert(ch('1', armed) == KeyCommand(Command.foldLevel, 1));
    assert(ch('9', armed) == KeyCommand(Command.foldLevel, 9));
    assert(ch('0', armed).cmd == Command.none, "no level 0");

    // An unrecognised key resolves to nothing (the caller disarms).
    assert(ch('q', armed).cmd == Command.none);
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

@("keymap.sharedBindingsWorkFromEitherPane")
@safe pure nothrow @nogc
unittest
{
    auto tree = KeyContext(treeFocused: true, treeVisible: true);

    // The theme arrows, Tab and the copy-mode toggles are deliberately NOT
    // pane-scoped — the frame loop has them outside the focus branch, and
    // that is preserved here.
    foreach (ctx; [KeyContext.init, tree])
    {
        assert(nk(Key.right, ctx).cmd == Command.themeNext);
        assert(nk(Key.left, ctx).cmd == Command.themePrev);
        assert(nk(Key.tab, ctx).cmd == Command.toggleView);
        assert(nk(Key.pageDown, ctx).cmd == Command.viewPageDown);
        assert(ch('y', ctx).cmd == Command.toggleAnsiCopy);
        assert(ch('t', ctx).cmd == Command.toggleTableCopy);
        assert(ch('e', ctx).cmd == Command.toggleExplorer);
    }
}

@("keymap.unboundKeysResolveToNone")
@safe pure nothrow @nogc
unittest
{
    // The default answer is `none`, so the frame loop needs no catch-all.
    assert(ch('q').cmd == Command.none);
    assert(ch('!').cmd == Command.none);
    assert(nk(Key.f5).cmd == Command.none);
    assert(nk(Key.none).cmd == Command.none);
    assert(commandFor(KeyEvent.init, KeyContext.init).cmd == Command.none);
}
