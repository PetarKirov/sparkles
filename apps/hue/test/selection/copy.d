/**
BDD integration tests for selection copy (`SEL4` / `TSL2`).

Tests that `Ctrl+C` (and its various producer encodings) reliably copies the
selected source text across both TUI and GUI modes via a shared test body.
*/
module test.selection.copy;

version (unittest):

import std.algorithm.searching : canFind;

import sparkles.input.events : Event, Key, KeyAction, KeyEvent, Mods, Point,
    PointerAction, PointerButton, PointerEvent;
import sparkles.syntax : LabelSet, MdBlock, MdBlockKind, MdDoc, MdInline,
    MdInlineKind, Span;
import sparkles.ui.theme : Theme;
import sparkles.ui.themes : builtinDark;

import gui_preview : PreviewModel;
import gui_state : Regime, SelectionDrag;
import keymap : Command, InputMode, KeyContext;
import lantern : LanternState, step, StepKind;
import tui : PreviewTui;
import viewer_model : ViewerModel;

/// Common interface adapter for TUI mode.
struct TuiModeAdapter
{
    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    PreviewTui t;
    string clip;
    bool clipReady;

    void open(string text)
    {
        auto doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
            MdBlock(kind: MdBlockKind.paragraph, inlines: [
                MdInline(kind: MdInlineKind.text, span: Span(0, text.length))]),
        ]), text);

        t.title = "sample.md";
        t.source = text;
        t.model = PreviewModel(present: true, doc: doc);
        t.labels = LabelSet.standard();
        t.names = names[];
        t.themes = themes[];
        t.vm.showPreview = true;
        t.resize(80, 24);
        t.relayout();
    }

    void select(long minOffset, long maxOffset)
    {
        // Left-press at row 1 (content row) selects the line
        t.handle(Event(PointerEvent(action: PointerAction.press,
            button: PointerButton.left, pos: Point(1, 1))));
    }

    bool sendKey(in KeyEvent k)
    {
        const handled = t.handle(Event(k));
        const c = t.takeClipboard();
        if (c.length > 0)
        {
            clip = c.dup;
            clipReady = true;
        }
        return handled;
    }

    string clipboard() const => clip;
}

/// Common interface adapter for GUI mode.
struct GuiModeAdapter
{
    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    ViewerModel vm;
    SelectionDrag drag;
    LanternState lantern;
    string clip;
    bool clipReady;

    void open(string text)
    {
        auto doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
            MdBlock(kind: MdBlockKind.paragraph, inlines: [
                MdInline(kind: MdInlineKind.text, span: Span(0, text.length))]),
        ]), text);

        vm.title = "sample.md";
        vm.source = text;
        vm.preview = PreviewModel(present: true, doc: doc);
        vm.labels = LabelSet.standard();
        vm.names = names[];
        vm.themes = themes[];
        vm.showPreview = true;
        vm.relayout(80);
    }

    void select(long minOffset, long maxOffset)
    {
        drag.regime = Regime.text;
        drag.anchorLo = minOffset;
        drag.anchorHi = minOffset;
        drag.headLo = maxOffset;
        drag.headHi = maxOffset;
    }

    bool sendKey(in KeyEvent k)
    {
        const ctx = KeyContext(mode: InputMode.normal);
        const st = step(lantern, k, ctx);
        if (st.kind == StepKind.execute && st.cmd.cmd == Command.copySelection)
        {
            if (drag.regime == Regime.text && drag.selMax() > drag.selMin()
                && drag.selMax() <= vm.source.length)
            {
                clip = vm.source[cast(size_t) drag.selMin() .. cast(size_t) drag.selMax()].dup;
                clipReady = true;
            }
            return true;
        }
        return false;
    }

    string clipboard() const => clip;
}

/// Replayable test body for selection copy across producers (`SEL4` / `TSL2`).
void testSelectionCopyAcrossProducers(Mode)()
{
    static immutable string sample = "Hello, world! Selection copy test line.";

    // The different spellings Ctrl+C and Cmd+C arrive in across backends and producers:
    KeyEvent[6] copySpellings = [
        // 1. Synthesized / standard normalized KeyEvent (Ctrl+C)
        KeyEvent(Key.char_, 'c', Mods(ctrl: true)),
        // 2. POSIX terminal raw control byte (0x03)
        KeyEvent(Key.char_, '\x03'),
        // 3. Physical key layout with unshifted codepoint (raylib full keyboard)
        KeyEvent(Key.char_, 0, Mods(ctrl: true), KeyAction.press, 'c'),
        // 4. Uppercase unshifted codepoint
        KeyEvent(Key.char_, 0, Mods(ctrl: true), KeyAction.press, 'C'),
        // 5. macOS Cmd+C (super_ modifier, e.g. from CSI u over SSH)
        KeyEvent(Key.char_, 'c', Mods(super_: true)),
        // 6. macOS Cmd+C with unshifted codepoint
        KeyEvent(Key.char_, 0, Mods(super_: true), KeyAction.press, 'c'),
    ];

    foreach (k; copySpellings)
    {
        Mode mode;
        mode.open(sample);
        mode.select(0, 13);
        mode.sendKey(k);
        assert(mode.clipReady, "copySelection was not triggered for copy event");
        assert(mode.clipboard.canFind("Hello, world!"),
            "Clipboard did not contain the expected selected text");
    }
}

@("selection.copy.tui")
unittest
{
    testSelectionCopyAcrossProducers!TuiModeAdapter();
}

@("selection.copy.gui")
unittest
{
    testSelectionCopyAcrossProducers!GuiModeAdapter();
}

@("selection.copy.notificationBox")
unittest
{
    import core.time : msecs;
    import sparkles.ui_tui : Grid;

    TuiModeAdapter adapter;
    adapter.open("Hello notification test!");
    adapter.select(0, 5);
    adapter.sendKey(KeyEvent(Key.char_, 'c', Mods(ctrl: true)));

    assert(adapter.clipReady);
    assert(adapter.t.toastVisible, "toast should be visible after copying");

    Grid g;
    g.resize(80, 24);
    adapter.t.paint(g);

    // Verify top-right notification box contains border and "Copied to clipboard"
    bool foundTopBorder = false;
    bool foundMessage = false;
    bool foundBottomBorder = false;
    foreach (y; 0 .. 5)
    {
        string rowText;
        foreach (x; 40 .. 80)
            rowText ~= g[cast(ushort) x, cast(ushort) y].grapheme;
        if (rowText.canFind("┌") && rowText.canFind("┐"))
            foundTopBorder = true;
        if (rowText.canFind("Copied to clipboard") && rowText.canFind("✓"))
            foundMessage = true;
        if (rowText.canFind("└") && rowText.canFind("┘"))
            foundBottomBorder = true;
    }
    assert(foundTopBorder, "Notification box top border was not found near top right");
    assert(foundMessage, "Notification box content with 'Copied to clipboard' was not found near top right");
    assert(foundBottomBorder, "Notification box bottom border was not found near top right");

    // Advance toast past hold duration
    adapter.t.tickToast(2000.msecs);
    assert(!adapter.t.toastVisible, "toast should expire after its duration");
}
