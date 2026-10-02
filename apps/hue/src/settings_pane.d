/**
hue's mount of the shared settings pane (`SET*`):
$(REF SettingsPane, sparkles,ui,components,settings_pane) — the component the
terminal mounts too (terminal `TSP1`) — with its keys resolved through hue's
own keymap (the `settings` scope, terminal + hiding, and the `input` scope for
the string-leaf line editor), and hue's live-apply bits.

Semantics (user-decided): $(B live-apply + explicit save). Every committed
edit mutates the running config immediately through the property tree's
generated dispatch (validated, refusable, undoable); a Save writes the
$(B file draft) through the config core's sparse writer; closing without
saving keeps the session's runtime state and persists nothing. The `CFG11`
rule is the component's: only touched paths reach the file.
*/
module settings_pane;

import sparkles.input.events : KeyEvent;

public import sparkles.ui.components.settings_pane : ApplyRule,
    SettingsCommand, SettingsGeometry, settingsGeometryFor, SettingsResult;
import sparkles.ui.components.settings_pane : UiSettingsPane = SettingsPane;

import keymap : Command, commandFor, InputMode, KeyContext;

/// What a committed edit obliges a hue host to do now — the bits of
/// `SettingsResult.apply` hue's `ApplyRule` table speaks in.
enum ApplyMask : uint
{
    none = 0,
    theme = 1,  /// theme / background changed — re-resolve and repaint
    font = 2,   /// a font face or size changed — GUI reloads, TUI ignores
    layout = 4, /// pane geometry changed — re-arrange the dock
}

/// The pane over `T` with hue's keys.
alias SettingsPaneT(T) = UiSettingsPane!(T, hueSettingsCommand);

/// The context hue's keymap resolves against while the pane is open.
KeyContext keyContext(P)(in P pane)
    => KeyContext(settingsActive: true,
        mode: pane.textEditing ? InputMode.settingsText : InputMode.normal);

/// hue's keymap, read as the pane's vocabulary: the `settings` scope at rest,
/// the `input` scope while the line editor owns the keyboard.
SettingsCommand hueSettingsCommand(in KeyEvent k, bool textEditing) @safe
{
    const ctx = KeyContext(settingsActive: true,
        mode: textEditing ? InputMode.settingsText : InputMode.normal);
    switch (commandFor(k, ctx).cmd)
    {
        case Command.settingsClose: return SettingsCommand.close;
        case Command.settingsDown: return SettingsCommand.down;
        case Command.settingsUp: return SettingsCommand.up;
        case Command.settingsPageDown: return SettingsCommand.pageDown;
        case Command.settingsPageUp: return SettingsCommand.pageUp;
        case Command.settingsHome: return SettingsCommand.home;
        case Command.settingsEnd: return SettingsCommand.end;
        case Command.settingsExpand: return SettingsCommand.expand;
        case Command.settingsCollapse: return SettingsCommand.collapse;
        case Command.settingsActivate: return SettingsCommand.activate;
        case Command.settingsInc: return SettingsCommand.inc;
        case Command.settingsDec: return SettingsCommand.dec;
        case Command.settingsPreview: return SettingsCommand.preview;
        case Command.settingsUndo: return SettingsCommand.undo;
        case Command.settingsRedo: return SettingsCommand.redo;
        case Command.settingsFilter: return SettingsCommand.filter;
        case Command.settingsMatchNext: return SettingsCommand.matchNext;
        case Command.settingsMatchPrev: return SettingsCommand.matchPrev;
        case Command.settingsReveal: return SettingsCommand.reveal;
        case Command.settingsOpenAll: return SettingsCommand.openAll;
        case Command.settingsCloseAll: return SettingsCommand.closeAll;
        case Command.settingsReset: return SettingsCommand.reset;
        case Command.settingsSave: return SettingsCommand.save;
        case Command.inputAccept: return SettingsCommand.textAccept;
        case Command.inputCancel: return SettingsCommand.textCancel;
        case Command.inputBackspace: return SettingsCommand.textBackspace;
        default: return SettingsCommand.none;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — the component against a fixture subject, keys resolved through
// hue's real keymap (the settings scope), no host and no window.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import core.time : Duration;

    import sparkles.base.term_control : PointerShape;
    import sparkles.input.events : Event, Key, Mods, Point, PointerAction,
        PointerButton, PointerEvent, WheelEvent;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.property_tree : Doc, Range, readOnly;

    private enum FixMode : ubyte
    {
        alpha,
        beta,
        gamma,
    }

    private struct FixNested
    {
        @Range(0, 10, 1) int depth = 3;
    }

    private struct Fixture
    {
        bool dark = true;
        @Range(6, 72, 1) int size = 18;
        @Doc("blend") @Range(0, 1, 0.1) double opacity = 0.5;
        FixMode mode = FixMode.alpha;
        string name = "start";
        @readOnly int locked = 7;
        FixNested nested;
    }

    private KeyEvent kch(dchar c, Mods m = Mods()) @safe pure nothrow @nogc
        => KeyEvent(Key.char_, c, m);
    private KeyEvent knk(Key k) @safe pure nothrow @nogc => KeyEvent(k, 0);

    /// Puts the selection on the row whose node path is `path`.
    private void selectPath(P)(ref P p, string path)
    {
        foreach (i, ref const r; p.tv.rows)
            if (p.tree.data.nodes[r.node].value.path == path)
            {
                p.tv.sel = cast(long) i;
                p.tv.clamp();
                return;
            }
        assert(false, "no visible row for " ~ path);
    }
}

@("settings_pane.editMirrorsDraftAndDirty")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);
    assert(p.active && !p.dirty);

    // Toggle the bool through the real key path.
    selectPath(p, "dark");
    cast(void) p.handleKey(kch('+'));
    assert(cfg.dark == false, "live-apply: the subject changed");
    assert(p.fileDraft.dark == false, "the commit mirrored into the draft");
    assert(p.dirty);
    assert(p.touched == ["dark"]);

    // Step the ranged int; the @Range step is 1.
    selectPath(p, "size");
    cast(void) p.handleKey(kch('+'));
    assert(cfg.size == 19);
    assert(p.fileDraft.size == 19);

    // Undo follows into the draft — undoing back to the seed clears dirty.
    cast(void) p.handleKey(kch('u'));
    assert(cfg.size == 18 && p.fileDraft.size == 18);
    cast(void) p.handleKey(kch('u'));
    assert(cfg.dark == true && p.fileDraft.dark == true);
    assert(!p.dirty, "undone to the saved seed");

    // Redo replays and re-dirties.
    cast(void) p.handleKey(kch('u', Mods(shift: true)));
    assert(cfg.dark == false && p.dirty);
}

@("settings_pane.refusalAndEnumAndModal")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);

    // @readOnly refuses inline; nothing changes, nothing touched.
    selectPath(p, "locked");
    cast(void) p.handleKey(kch('+'));
    assert(cfg.locked == 7);
    assert(p.edits.refusalFor("locked").refused);
    assert(p.touched.length == 0);

    // Enter cycles an enum exactly like `+`.
    selectPath(p, "mode");
    cast(void) p.handleKey(knk(Key.enter));
    assert(cfg.mode == FixMode.beta);
    cast(void) p.handleKey(kch('-'));
    assert(cfg.mode == FixMode.alpha);

    // A modal surface swallows unbound keys; the subject is untouched.
    const before = *cfg;
    const r = p.handleKey(kch('!'));
    assert(r.kind == SettingsResult.Kind.consumed);
    assert(*cfg == before);

    // Escape closes; runtime state (the enum cycle above) is kept.
    const closed = p.handleKey(knk(Key.escape));
    assert(closed.kind == SettingsResult.Kind.closed && !p.active);
    assert(cfg.mode == FixMode.alpha);
}

@("settings_pane.textEditorFlow")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);

    // Enter on a string leaf opens the line editor seeded with the value.
    selectPath(p, "name");
    cast(void) p.handleKey(knk(Key.enter));
    assert(p.textEditing && p.textPath == "name" && p.textBuf == "start");
    assert(p.keyContext().mode == InputMode.settingsText);

    // Typed printables append; Backspace pops a code point; letters that
    // are commands at rest (j, u, s) are text here.
    cast(void) p.handleKey(kch('-'));
    cast(void) p.handleKey(kch('j'));
    cast(void) p.handleKey(knk(Key.backspace));
    cast(void) p.handleKey(kch('u'));
    cast(void) p.handleKey(kch('s'));
    assert(p.textBuf == "start-us", p.textBuf);

    // Enter commits through the validated dispatch: subject, draft, history.
    cast(void) p.handleKey(knk(Key.enter));
    assert(!p.textEditing);
    assert(cfg.name == "start-us");
    assert(p.fileDraft.name == "start-us");
    assert(p.edits.undo.length == 1);

    // Escape cancels without a write.
    cast(void) p.handleKey(knk(Key.enter));
    cast(void) p.handleKey(kch('x'));
    cast(void) p.handleKey(knk(Key.escape));
    assert(!p.textEditing && cfg.name == "start-us");
}

@("settings_pane.saveCapturesTheCfg11Rule")
@system unittest
{
    // The launch situation CFG11 protects: a CLI flag set size=99 (visible
    // in the running config), while the user FILE said 18 — the seed.
    auto cfg = new Fixture;
    cfg.size = 99;
    Fixture fileValue; // size = 18

    SettingsPaneT!Fixture p;
    Fixture savedDraft;
    const(string)[] savedTouched;
    bool saved;
    p.doSave = (ref const Fixture draft, const(string)[] touched) {
        savedDraft = draft;
        savedTouched = touched.dup;
        saved = true;
        return null;
    };
    p.open(cfg, fileValue);

    // The user toggles dark but never touches size.
    selectPath(p, "dark");
    cast(void) p.handleKey(kch('+'));

    const r = p.handleKey(kch('s'));
    assert(r.kind == SettingsResult.Kind.saved && saved);
    assert(savedTouched == ["dark"]);
    assert(savedDraft.dark == false, "the toggled value");
    assert(savedDraft.size == 18,
        "the FILE's value — the CLI's 99 was never baked in");
    assert(!p.dirty && p.status == "saved");

    // A refused save surfaces and keeps dirty. (Not size: stepping from
    // the CLI's out-of-range 99 is itself refused by @Range — correctly.)
    selectPath(p, "opacity");
    cast(void) p.handleKey(kch('+'));
    p.doSave = (ref const Fixture d, const(string)[] t) {
        return "config.json carries comments hue would destroy";
    };
    const r2 = p.handleKey(kch('s'));
    assert(r2.kind == SettingsResult.Kind.consumed);
    assert(p.dirty && p.status.length && p.status != "saved");
}

@("settings_pane.applyMaskAndPreview")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.applyRules = [
        ApplyRule("dark", ApplyMask.theme),
        ApplyRule("nested.", ApplyMask.layout),
    ];
    p.open(cfg, Fixture.init);

    selectPath(p, "dark");
    assert(p.handleKey(kch('+')).apply == ApplyMask.theme);
    selectPath(p, "size");
    assert(p.handleKey(kch('+')).apply == ApplyMask.none);

    // A preview drag: mutations live, ONE history entry and ONE apply on
    // the commit boundary (PRT19).
    selectPath(p, "opacity");
    cast(void) p.handleKey(kch('v'));
    assert(p.previewing);
    cast(void) p.handleKey(kch('+'));
    cast(void) p.handleKey(kch('+'));
    assert(cfg.opacity > 0.65 && cfg.opacity < 0.75, "previews mutate live");
    const undoBefore = p.edits.undo.length;
    cast(void) p.handleKey(kch('v'));
    assert(!p.previewing);
    assert(p.edits.undo.length == undoBefore + 1, "one entry per drag");
    assert(p.fileDraft.opacity == cfg.opacity, "the drag reached the draft");
}

@("settings_pane.filterFlowAndGolden")
@system unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.ui.components.property_view : propertyText;

    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);

    // `/` opens the filter; typed keys are the query; Down still navigates.
    cast(void) p.handleKey(kch('/'));
    assert(p.tv.searching);
    cast(void) p.handleKey(kch('o'));
    cast(void) p.handleKey(kch('p'));
    cast(void) p.handleKey(kch('a'));
    assert(p.tv.filterQuery == "opa");
    assert(p.tree.searching && p.tree.matchCount >= 1);
    cast(void) p.handleKey(knk(Key.down));

    // Escape restores the base projection.
    cast(void) p.handleKey(knk(Key.escape));
    assert(!p.tv.searching);

    // The plain-text twin renders the same rows both canvases paint — the
    // affordances the pane relies on are visible in it.
    const textView = propertyText(p.tree.data, p.tv.rows, p.tv, p.edits);
    assert(textView.canFind("dark"), textView);
    assert(textView.canFind("[x]") || textView.canFind("[ ]"), textView);
    assert(textView.canFind("⏎ edit") || textView.canFind("needs EDT")
        || textView.canFind("start-us") || textView.canFind("start"),
        textView);
}

@("settings_pane.scrollMachineRoutesTheOverlay")
@system unittest
{
    import core.time : msecs;
    import sparkles.ui.widget : WidgetKind;

    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);
    const g = SettingsGeometry(60, 12); // a short pane: the bar is live
    p.resize(g);
    // Open the nested section so the rows outgrow the window.
    selectPath(p, "nested");
    cast(void) p.handleKey(knk(Key.right));
    assert(p.tv.rows.length > p.tv.bodyRows, "content outgrows the window");

    // The built view carries the semantic scrollbar leaf — the same
    // machine-driven bar every tree view paints.
    auto view = p.buildView(g);
    bool sawBar;
    foreach (ref const n; view.nodes)
        sawBar |= n.kind == WidgetKind.scrollbar;
    assert(sawBar);

    // A wheel notch scrolls the viewport and leaves the cursor behind.
    p.tv.selHome();
    p.tv.clamp();
    const selBefore = p.tv.sel;
    WheelEvent w;
    w.dy = 1;
    cast(void) p.handleOverlay(Event(w), g);
    assert(p.tv.top > 0, "a notch scrolls (3 rows, clamped)");
    assert(p.tv.sel == selBefore, "…and leaves the cursor behind");
    p.tv.selHome();
    p.tv.clamp(); // re-couple: the later halves assert against row 0

    // A press on the bar's gutter is a grab, never a row click: the frame
    // routes it to the machine, the selection stays, and the drag scrolls.
    auto frames = layout(view, Constraints(maxW: g.panelCols));
    const area = SettingsPaneT!Fixture.treeArea(view, frames);
    const fr = p.tv.scrollFrame();
    const barX = area.x + fr.vTrack.x;
    PointerEvent press;
    press.action = PointerAction.press;
    press.button = PointerButton.left;
    press.pos = Point(barX, area.y + fr.vTrack.y);
    cast(void) p.handleOverlay(Event(press), g);
    assert(p.tv.sel == 0, "a bar press never selects a row");
    assert(p.tv.sb.dragging || p.tv.sb.hovered, "the machine owns the bar");
    PointerEvent release = press;
    release.action = PointerAction.release;
    cast(void) p.handleOverlay(Event(release), g);

    // The easing advances through the host tick — the animation the hue
    // explorer's bars run on.
    PointerEvent hover;
    hover.action = PointerAction.move;
    hover.pos = Point(barX, area.y + fr.vTrack.y + 1);
    cast(void) p.handleOverlay(Event(hover), g);
    const pctBefore = p.tv.scroll.vAnim.percent;
    p.tickAnims(50.msecs);
    assert(p.tv.scroll.vAnim.percent >= pctBefore,
        "the hover-expand easing ticks");

    // Over the bar the machine wants ns-resize — the hosts report it as
    // the frame's pointer shape, like every other bar in the app.
    assert(p.pointerShape() == PointerShape.nsResize);
    PointerEvent away = hover;
    away.pos = Point(area.x + 2, area.y + 2);
    cast(void) p.handleOverlay(Event(away), g);
    assert(p.pointerShape() == PointerShape.default_,
        "off the bar the shape returns to default");

    // A press on a row selects it; pressing the selected row activates.
    PointerEvent rowPress = press;
    rowPress.pos = Point(area.x + fr.content.x + 1, area.y + fr.content.y);
    cast(void) p.handleOverlay(Event(rowPress), g);
    assert(p.tv.sel == p.tv.top, "the pressed row is selected");
}
