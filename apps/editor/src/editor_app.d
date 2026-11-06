/** The backend-independent editor application. */
module editor_app;

import std.conv : text;
import sparkles.input : CompositionEvent, EndOfInput, Event, KeyAction, KeyEvent,
    match, PasteEvent, PointerAction, PointerButton, PointerEvent, WheelEvent;
import sparkles.text_buffer.text : Text;
import sparkles.ui.command_palette : PaletteChoice, PaletteEffect, PaletteEffectKind, PaletteInvocation, PaletteStatus;
import sparkles.ui.command_palette_input : PaletteInput;
import sparkles.ui.components.command_palette : PaletteViewOptions, viewCommandPalette;
import sparkles.ui.components.editor : editorView, EditorViewOptions, scrollToPrimary;
import sparkles.ui.components.lantern_view : BoxLayout, LabelArena, viewLantern;
import sparkles.ui.editor.field : EditorField, forwardClipboard;
import sparkles.ui.editor.command : EditCommand;
import sparkles.ui.editor.keys : commandOf, EditorAction, EditorTarget, windowTarget;
import sparkles.ui.geometry : Insets, Point, SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.keymap : bindingsAt;
import sparkles.ui.lantern : LanternState, step, StepKind;
import sparkles.ui.style : Slot;
import sparkles.ui.state : hitAt, hoverTargets, HoverTarget, sourceOffsetAt;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.host : canReadClipboard, withPreedit;
import sparkles.ui_app.run_app : AppTheme;
import commands;

private class DisplayedFrame
{
    const WidgetTree tree;
    const Frame[] frames;

    this(const WidgetTree tree, const Frame[] frames) @safe pure nothrow
    {
        this.tree = tree;
        this.frames = frames;
    }
}

/// A tab owns its reference-counted field; arrays contain tab references, never Text values.
class Document
{
    ulong id;
    string name;
    EditorField field;
    Text saved;
    size_t firstLine;
    bool followCaret = true;

    this(ulong id, string name, string content = "") @safe pure nothrow
    {
        this.id = id;
        this.name = name;
        field = EditorField.make(content);
        saved = field.state.text;
    }

    bool dirty() const @safe pure nothrow @nogc => field.state.text != saved;
}

/// Thin shared-widget component, instantiated by recording, TUI and Vulkan hosts.
struct EditorApp
{
    AppTheme theme;
    PaletteInput!(Command, 128) commands;
    bool inspector;
    bool quitRequested;
    string status;
    string shotPath;
    private int shotCountdown = 3;
    private Document[] tabs;
    private size_t activeTab;
    private ulong nextId = 1;
    private CommandBinding[] bindings;
    private EditorTarget target = EditorTarget.terminal;
    private LanternState lantern;
    private LabelArena guideLabels;
    private char[] pasteBytes;
    private bool collectingPaste;
    private uint pasteRequest;
    private ulong pasteDocument, pastePalette;
    private DisplayedFrame displayed;
    private HoverTarget[] hits;
    private const(PaletteChoice!Command)[] paletteChoices;
    private bool selecting;
    private size_t selectionAnchor;
    private enum size_t tabHitBase = 0x7400_0000;

    /// Retain the committed frame for event routing; no second layout/hit model.
    void paint(H)(ref H host, const WidgetTree tree, const Frame[] frames)
    {
        displayed = new DisplayedFrame(tree, frames);
        hits = hoverTargets(tree, frames);
    }

    private void pointer(in PointerEvent pointer) @safe
    {
        if (pointer.action == PointerAction.release || pointer.action == PointerAction.leave)
        {
            selecting = false;
            return;
        }
        if (pointer.action != PointerAction.press && pointer.action != PointerAction.drag) return;
        if (pointer.button != PointerButton.left && pointer.action != PointerAction.drag) return;
        const hit = hits.hitAt(pointer.pos.x, pointer.pos.y);
        if (commands.palette.active)
        {
            const base = PaletteViewOptions.init.hitBase;
            if (pointer.action == PointerAction.press && hit >= base && hit - base < paletteChoices.length)
                apply(commands.palette.activate(paletteChoices[hit - base], context));
            return;
        }
        if (hit >= tabHitBase && hit - tabHitBase < tabs.length)
        {
            if (pointer.action == PointerAction.press) activeTab = hit - tabHitBase;
            return;
        }
        if (displayed is null) return;
        const offset = sourceOffsetAt(displayed.tree, displayed.frames,
            Point(cast(int) pointer.pos.x, cast(int) pointer.pos.y));
        if (offset < 0 || cast(size_t) offset > document.field.state.text.length) return;
        const at = cast(size_t) offset;
        if (pointer.action == PointerAction.press)
        {
            selectionAnchor = pointer.mods.shift ? document.field.state.selection.primary.anchor : at;
            selecting = true;
        }
        if (selecting) document.field.run(EditCommand.setRange(selectionAnchor, at));
    }

    private void receivePaste(in PasteEvent chunk) @safe
    {
        if (!collectingPaste || chunk.request != pasteRequest)
        {
            pasteBytes.length = 0;
            collectingPaste = true;
            pasteRequest = chunk.request;
            pasteDocument = document.id;
            pastePalette = commands.palette.active ? commands.palette.snapshot.ticket.value : 0;
        }
        pasteBytes ~= chunk.text[];
        if (!chunk.last) return;
        collectingPaste = false;
        scope (exit) pasteBytes.length = 0;
        if (document.id != pasteDocument
            || (commands.palette.active ? commands.palette.snapshot.ticket.value : 0) != pastePalette)
        {
            status = "Paste cancelled because its input target changed.";
            return;
        }
        if (pastePalette)
            apply(commands.paste(pasteBytes, pasteRequest, context));
        else
            document.field.paste(pasteBytes, pasteRequest);
        document.followCaret = true;
    }

    /// The active document, lazily creating an untitled tab.
    Document document() @safe
    {
        ensureInitialized();
        return tabs[activeTab];
    }

    size_t tabCount() const @safe pure nothrow @nogc => tabs.length;

    CommandContext context() @safe => CommandContext(document.id, bindings);

    private void ensureInitialized() @safe
    {
        if (tabs.length) return;
        tabs ~= new Document(nextId++, "Untitled");
        configure(EditorTarget.terminal);
    }

    private void configure(EditorTarget selected) @safe
    {
        target = selected;
        bindings = commandBindings(target);
        const result = commands.palette.catalog(commandCatalog(bindings));
        assert(result == PaletteStatus.ok);
        if (commands.palette.active)
        {
            const refreshed = commands.palette.search(commands.palette.snapshot.ticket,
                commands.query.text, CommandContext(tabs[activeTab].id, bindings));
            assert(refreshed == PaletteStatus.ok);
        }
        foreach (tab; tabs) tab.field.target = target;
    }

    /// One dispatcher receives keyboard, palette and future menu/touch commands.
    void execute(CommandId id) @safe
    {
        ensureInitialized();
        if (!context.available(id, document.id)) return;
        final switch (id.operation)
        {
        case Command.none: break;
        case Command.palette:
            commands.open(PaletteInvocation(document.id, document.id), context);
            commands.query.target = target;
            break;
        case Command.guide: break;
        case Command.newTab:
            tabs ~= new Document(nextId++, text("Untitled ", nextId - 1));
            activeTab = tabs.length - 1;
            document.field.target = target;
            break;
        case Command.nextTab: activeTab = (activeTab + 1) % tabs.length; break;
        case Command.previousTab: activeTab = (activeTab + tabs.length - 1) % tabs.length; break;
        case Command.inspector: inspector = !inspector; break;
        case Command.edit:
            if (id.argument <= EditorAction.max)
                document.field.run(commandOf(cast(EditorAction) id.argument));
            break;
        case Command.quit:
            bool dirty;
            foreach (tab; tabs) dirty |= tab.dirty;
            if (dirty) status = "Unsaved changes: save or discard before closing.";
            else quitRequested = true;
            break;
        }
    }

    private void apply(PaletteEffect!Command effect) @safe
    {
        if (effect.kind == PaletteEffectKind.execute)
        {
            if (effect.invocation.target != document.id)
            {
                status = "The command's document is no longer active.";
                return;
            }
            execute(effect.command);
        }
        else if (effect.status != PaletteStatus.ok)
            status = text("Command query: ", effect.status);
    }

    /// Route modal query input first, then the shared key guide, then text insertion.
    void handleKey(in KeyEvent key) @safe
    {
        ensureInitialized();
        if (key.action == KeyAction.release) return;
        if (commands.palette.active)
        {
            apply(commands.key(key, context));
            return;
        }
        document.followCaret = true;
        const resolved = step(lantern, bindings, key, context);
        if (resolved.kind == StepKind.execute)
            execute(CommandId(resolved.cmd.cmd, resolved.cmd.arg));
        else if (resolved.kind == StepKind.unbound)
            document.field.key(key);
    }

    /// The same event vocabulary reaches every rendering host.
    void handle(H)(ref H host, in Event event)
    {
        ensureInitialized();
        document.field.context.clipboardRead = canReadClipboard!H;
        document.field.context.clipboardWrite = __traits(compiles, host.clipboard(""));
        commands.query.context.clipboardRead = canReadClipboard!H;
        commands.query.context.clipboardWrite = __traits(compiles, host.clipboard(""));
        event.match!(
            (in KeyEvent key) { handleKey(key); },
            (in PasteEvent paste) { receivePaste(paste); },
            (in PointerEvent pointer) { this.pointer(pointer); },
            (in CompositionEvent update) {
                withPreedit(host, update, (scope const(char)[] preedit) {
                    if (commands.palette.active) commands.query.compose(update, preedit);
                    else document.field.compose(update, preedit);
                });
            },
            (in WheelEvent wheel) {
                const wanted = cast(long) document.firstLine + wheel.dy;
                document.firstLine = wanted < 0 ? 0 : cast(size_t) wanted;
                document.followCaret = false;
            },
            (in EndOfInput _) { execute(CommandId(Command.quit)); },
            (in _) {});
        forwardClipboard(document.field, host);
        forwardClipboard(commands.query, host);
        if (quitRequested) host.quit();
    }

    /// One tree renders the tab strip, active field, command frontends and inspector.
    WidgetTree view(H)(ref H host)
    {
        ensureInitialized();
        if (shotPath.length)
        {
            static if (__traits(hasMember, H, "screenshot"))
            {
                if (--shotCountdown == 0) host.screenshot(shotPath);
                if (shotCountdown < -2) host.quit();
                host.requestFrame();
            }
            else
            {
                status = "Screenshots are unavailable on this host.";
                host.quit();
            }
        }
        const selectedTarget = host.backend == Backend.gui ? windowTarget : EditorTarget.terminal;
        if (selectedTarget != target) configure(selectedTarget);
        Builder b;
        uint[] children;
        children ~= b.add(Widget(kind: WidgetKind.text,
            text: "Sparkles Editor  •  Ctrl+Shift+P commands  •  F1 keys  •  F12 inspector",
            slot: Slot.docs, height: SizeSpec.fixed(1), padding: Insets(0, 1, 0, 1)));
        uint[] tabNodes;
        foreach (i, tab; tabs)
            tabNodes ~= b.add(Widget(kind: WidgetKind.text,
                text: tab.name ~ (tab.dirty ? " •" : ""),
                hitId: tabHitBase + i,
                slot: i == activeTab ? Slot.selection : Slot.muted,
                padding: Insets(0, 1, 0, 1), paintBackground: true));
        children ~= b.add(Widget(kind: WidgetKind.row, children: tabNodes, height: SizeSpec.fixed(1)));
        if (commands.palette.active)
        {
            const reserved = inspector ? 12 : 11;
            const rows = host.size.height > reserved + 3
                ? cast(size_t)(host.size.height - reserved) / 3 : 1;
            const paletteView = viewCommandPalette(b, commands.palette, commands.query.state, context,
                PaletteViewOptions(visibleRows: rows));
            paletteChoices = paletteView.choices;
            children ~= paletteView.root;
        }
        else
        {
            const visible = host.size.height > 5 ? cast(size_t) host.size.height - 5 : 1;
            const count = document.field.state.text.lineCount;
            if (document.firstLine >= count) document.firstLine = count ? count - 1 : 0;
            if (document.followCaret)
                document.firstLine = scrollToPrimary(document.field.state, document.firstLine, visible);
            const field = editorView(b, document.field.state, EditorViewOptions(
                firstLine: document.firstLine, visibleLines: visible, placeholder: "Start typing…"));
            b.nodes[field].height = SizeSpec.grow();
            children ~= field;
        }
        if (lantern.shown)
        {
            import sparkles.base.buffer : SharedBuffer;
            SharedBuffer!(CommandBinding, 128) items;
            bindingsAt(items, bindings, context, lantern.pending[]);
            BoxLayout boxes;
            children ~= viewLantern(b, guideLabels, items[], lantern.pending.length,
                host.size.width, boxes);
        }
        if (inspector)
            children ~= b.add(Widget(kind: WidgetKind.text, slot: Slot.info,
                text: text("bytes ", document.field.state.text.length, "  selections ",
                    document.field.state.selection.ranges.length, "  composition ",
                    document.field.state.composition.active)));
        if (status.length) children ~= b.add(Widget(kind: WidgetKind.text, text: status, slot: Slot.warn));
        children ~= b.add(Widget(kind: WidgetKind.text, text: "UTF-8  •  " ~ (document.dirty ? "Modified" : "Saved"),
            slot: Slot.muted, height: SizeSpec.fixed(1)));
        return b.finish(b.add(Widget(kind: WidgetKind.column, children: children,
            width: SizeSpec.grow(), height: SizeSpec.grow(), padding: Insets(1, 1, 1, 1))));
    }
}

/// A recording replays editing, tab switching and palette commands through one app.
@("editor.app.editTabsAndPalette")
@safe unittest
{
    import sparkles.input : charEvent, Key;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : runAppRecorded;
    EditorApp app;
    auto recording = runAppRecorded(app, RunConfig.init, [charEvent('x')]);
    assert(app.document.field.text == "x");
    assert(recording.frames.length >= 1);
    app.execute(CommandId(Command.newTab));
    assert(app.tabCount == 2 && app.document.field.empty);
    app.execute(CommandId(Command.previousTab));
    assert(app.document.field.text == "x");
    app.execute(CommandId(Command.palette));
    assert(app.commands.palette.active);
    app.commands.insert("Toggle inspector", app.context);
    app.handleKey(KeyEvent(Key.enter));
    assert(app.inspector && !app.commands.palette.active);
    assert(app.document.field.text == "x");
}

/// Selecting a native key table on the first frame retains startup palette results.
@("editor.app.startupPaletteSurvivesHostSetup")
@safe unittest
{
    import sparkles.ui_app.record : RecordingHost;
    EditorApp app;
    app.execute(CommandId(Command.palette));
    assert(app.commands.palette.rowCount > 0);
    RecordingHost host;
    host.backend = Backend.gui;
    app.view(host);
    assert(app.commands.palette.active && app.commands.palette.rowCount > 0);
}

/// Chunked transport is one paste and one undo revision, including clipboard answers.
@("editor.app.chunkedPasteIsOneEdit")
@safe unittest
{
    import sparkles.input : pasteChunks;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : runAppRecorded;
    enum content = "0123456789" ~ "abcdefghij";
    string value;
    foreach (i; 0 .. 100) value ~= content;
    Event[] script;
    pasteChunks(value, (in Event event) { script ~= event; });
    assert(script.length > 1);
    EditorApp app;
    runAppRecorded(app, RunConfig.init, script);
    assert(app.document.field.text == value);
    app.execute(CommandId(Command.edit, EditorAction.undo));
    assert(app.document.field.empty);
}

/// Pointer placement uses the displayed source ledger; tab and palette hits share the same frames.
@("editor.app.pointerUsesDisplayedFrames")
@safe unittest
{
    import sparkles.input : Point, PointerAction, PointerButton, PointerEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.style : defaultTwoslashPalette;
    EditorApp app;
    app.document.field.setText("abc");
    RecordingHost host;
    FrameSnapshot frame;
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    bool placed;
    foreach (i, node; frame.tree.nodes)
        if (node.kind == WidgetKind.rich && node.spans.length && node.spans[0].text == "abc")
        {
            const origin = frame.frames[i].rect.origin;
            app.handle(host, Event(PointerEvent(PointerAction.press, PointerButton.left,
                Point(origin.x + 1, origin.y))));
            assert(app.document.field.state.selection.primary.head == 1);
            placed = true;
        }
    assert(placed);
}

/// A full palette reserves the tab strip and header rather than collapsing their rows.
@("editor.app.paletteKeepsChromeSeparate")
@safe unittest
{
    import sparkles.ui.geometry : Size;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    EditorApp app;
    app.execute(CommandId(Command.palette));
    RecordingHost host;
    host.size = Size(80, 28);
    FrameSnapshot snapshot;
    presentApp(app, host, AppTheme.init, snapshot);
    int headerBottom, tabTop;
    foreach (i, node; snapshot.tree.nodes)
    {
        if (node.text.length >= 15 && node.text[0 .. 15] == "Sparkles Editor")
        {
            assert(snapshot.frames[i].rect.height >= 1);
            headerBottom = snapshot.frames[i].rect.bottom;
        }
        if (node.text == "Untitled") tabTop = snapshot.frames[i].rect.y;
    }
    assert(tabTop >= headerBottom && headerBottom > 0);
}
