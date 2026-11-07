/** The backend-independent editor application. */
module editor_app;

import std.conv : text;
import core.time : MonoTime, msecs;
import sparkles.input : CompositionEvent, EndOfInput, Event, KeyAction, KeyEvent,
    match, PasteEvent, PointerAction, PointerButton, PointerEvent, WheelEvent;
import sparkles.text_buffer.text : Text;
import sparkles.ui.command_palette : PaletteChoice, PaletteEffect, PaletteEffectKind, PaletteInvocation, PaletteStatus;
import sparkles.ui.command_palette_input : PaletteInput;
import sparkles.ui.components.command_palette : PaletteViewOptions, viewCommandPalette;
import sparkles.ui.components.editor : editorView, EditorViewOptions, scrollToPrimary;
import sparkles.ui.components.lantern_view : BoxLayout, LabelArena, viewLantern;
import sparkles.ui.editor.field : EditorField, forwardClipboard;
import sparkles.ui.editor.command : EditCommand, EditKind;
import sparkles.ui.components.controls : chip, ControlSize;
import sparkles.ui.editor.keys : commandOf, EditorAction, EditorTarget, windowTarget;
import sparkles.ui.geometry : Insets, Point, SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.keymap : bindingsAt;
import sparkles.ui.lantern : LanternState, step, StepKind;
import sparkles.ui.style : Slot;
import sparkles.ui.theme_catalog : canonicalThemeNames;
import sparkles.ui.command_palette : PaletteEntry;
import sparkles.ui.state : hitAt, hoverTargets, HoverTarget, sourceOffsetAt;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.host : canReadClipboard, withPreedit;
import sparkles.ui_app.run_app : AppTheme;
import sparkles.ui_app.gui_options : GuiOptions, resolveTheme;
import sparkles.ui_app.run_app : appThemeOf;
import sparkles.source_view.editor : highlightedEditorLine, syntaxWindow;
import sparkles.source_view.highlight_session : HighlightSession;
import sparkles.syntax.label : LabelSet;
import sparkles.syntax.theme : ResolvedTheme, resolveSyntaxTheme = resolveTheme;
import sparkles.ui.editor.state : ReadOnlySpan;
import commands : Command, CommandBinding, CommandContext, CommandId, commandBindings, commandCatalog;
import examples : Example, exampleText;
import document_text : decodeDocument, DocumentBytes, encodeDocument, enterEnding;
import sparkles.syntax.ts.registry : canonicalLanguageOfPath;
import sparkles.ui.editor.state : EditorState;
import sparkles.ui.editor.selection : SelectionSet;
import document_io : DocumentIo, FileOperation;
import document_files : SaveAuthorization;
import std.path : absolutePath, baseName;

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

private class SaveIntent
{
    ulong document;
    string path;
    Text revision;
    bool bom;
}

private enum Dialog : ubyte { none, openPath, savePath, dirtyClose }

/// A tab owns its reference-counted field; arrays contain tab references, never Text values.
class Document
{
    ulong id;
    string name;
    EditorField field;
    Text saved;
    size_t firstLine;
    bool followCaret = true;
    string language = "text";
    bool bom;
    string predominant = "\n";
    string path, savedBytes;
    bool saving;
    string durabilityWarning;

    this(ulong id, string name, string content = "") @safe pure nothrow
    {
        this.id = id;
        this.name = name;
        field = EditorField.make(content);
        saved = field.state.text;
    }

    bool dirty() const @safe pure nothrow @nogc => field.state.text != saved;

    /// Exact file bytes; the envelope is separate from the editable text.
    string encodedBytes() const @safe pure nothrow
        => encodeDocument(DocumentBytes(field.text, bom, predominant));
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
    string captureError;
    string lastOpenError;
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
    private HighlightSession highlighting;
    private ResolvedTheme syntaxTheme;
    string themeName;
    private bool choosingTheme;
    private string themeBeforePreview;
    private AppTheme themeBefore;
    private ResolvedTheme syntaxBefore;
    private string[] themeNames;
    private DocumentIo files;
    private ulong[ulong] openOrigins;
    private SaveIntent[ulong] saves;
    private SaveIntent replacement;
    private string replacementWarning;
    private Dialog dialog;
    private EditorField pathInput;
    private ulong dialogEpoch;
    private ulong pasteDialog;
    private ulong closingDocument;
    private bool exiting;
    Command startupCommand;

    bool filesBusy() const scope @safe pure nothrow @nogc => files !is null && files.busy;

    /// Capture one revision before asynchronous destination inspection.
    bool saveTo(string path) @safe
    {
        ensureInitialized();
        if (saves.length || replacement !is null)
        {
            status = "Resolve the pending save before saving again.";
            return false;
        }
        try { path = absolutePath(path); }
        catch (Exception) { status = "The destination path could not be resolved."; return false; }
        foreach (tab; tabs)
            if (tab.id != document.id && tab.path == path)
            {
                status = "That destination is already open in another tab.";
                return false;
            }
        foreach (intent; saves)
            if (intent.path == path)
            {
                status = "Another save is already using that destination.";
                return false;
            }
        auto intent = new SaveIntent;
        intent.document = document.id;
        intent.path = path;
        intent.revision = document.field.state.text;
        intent.bom = document.bom;
        if (files is null) files = new DocumentIo;
        const request = files.probe(path, intent.revision, intent.bom, intent.document,
            document.savedBytes, document.path == path);
        if (request.hasError) { status = request.error; return false; }
        document.saving = true;
        saves[request.value.value] = intent;
        status = "Checking destination…";
        return true;
    }

    bool overwritePending() const scope @safe pure nothrow @nogc => replacement !is null;

    /// Consent applies to this captured revision and destination only.
    void resolveOverwrite(bool accepted) @safe
    {
        if (replacement is null) return;
        auto intent = replacement;
        replacement = null;
        ++dialogEpoch;
        if (accepted) submitSave(intent, SaveAuthorization.replaceConfirmed);
        else
        {
            foreach (tab; tabs) if (tab.id == intent.document) tab.saving = false;
            closingDocument = 0;
            exiting = false;
            status = "Save cancelled; the destination was not changed.";
        }
    }

    private bool modal() const scope @safe pure nothrow @nogc
        => dialog != Dialog.none || replacement !is null;

    private void beginPath(Dialog requested) @safe
    {
        if (saves.length)
        {
            status = "Wait for the pending destination check or save to finish.";
            return;
        }
        if (commands.palette.active) commands.palette.cancel(commands.palette.snapshot.ticket);
        endPicker(false);
        document.field.run(EditCommand.of(EditKind.blur), MonoTime.currTime);
        lantern.reset();
        dialog = requested;
        ++dialogEpoch;
        pathInput = EditorField.singleLine(requested == Dialog.savePath ? document.path : "", target);
        pathInput.run(EditCommand.of(EditKind.selectAll), MonoTime.currTime);
        status = null;
    }

    private void showDirtyClose(ulong id) @safe
    {
        foreach (i, tab; tabs) if (tab.id == id) activeTab = i;
        if (commands.palette.active) commands.palette.cancel(commands.palette.snapshot.ticket);
        endPicker(false);
        lantern.reset();
        document.field.run(EditCommand.of(EditKind.blur), MonoTime.currTime);
        closingDocument = id;
        dialog = Dialog.dirtyClose;
        ++dialogEpoch;
    }

    private void removeDocument(ulong id) @safe
    {
        foreach (i, tab; tabs) if (tab.id == id)
        {
            tabs = tabs[0 .. i] ~ tabs[i + 1 .. $];
            if (activeTab > i) --activeTab;
            else if (activeTab >= tabs.length) activeTab = tabs.length ? tabs.length - 1 : 0;
            break;
        }
    }

    private void continueExit() @safe
    {
        foreach (tab; tabs)
            if (tab.dirty || tab.durabilityWarning.length)
            {
                showDirtyClose(tab.id);
                return;
            }
        quitRequested = true;
    }

    private void requestClose(bool all) @safe
    {
        if (filesBusy)
        {
            status = "Wait for pending file operations before closing.";
            return;
        }
        exiting = all;
        if (all) continueExit();
        else if (document.dirty || document.durabilityWarning.length) showDirtyClose(document.id);
        else removeDocument(document.id);
    }

    /// Native window closure uses the same policy as the Quit command.
    void closeRequested(H)(ref H host)
    {
        if (pathDialog) execute(CommandId(Command.cancel));
        if (dialog == Dialog.dirtyClose) exiting = true;
        else if (replacement !is null)
        {
            closingDocument = replacement.document;
            exiting = true;
        }
        else execute(CommandId(Command.quit));
        if (quitRequested) host.quit();
    }

    private void finishClose(ulong id) @safe
    {
        if (closingDocument != id) return;
        removeDocument(id);
        closingDocument = 0;
        dialog = Dialog.none;
        ++dialogEpoch;
        if (exiting) continueExit();
    }

    private void submitSave(SaveIntent intent, SaveAuthorization authorization) @safe
    {
        const request = files.save(intent.path, intent.revision, intent.bom, intent.document, authorization);
        if (request.hasError)
        {
            foreach (tab; tabs) if (tab.id == intent.document) tab.saving = false;
            status = request.error;
            if (closingDocument == intent.document) showDirtyClose(intent.document);
            return;
        }
        saves[request.value.value] = intent;
        status = "Saving…";
    }

    /// Open asynchronously; a pending read never replaces an edited buffer.
    bool openPath(string path) @safe
    {
        ensureInitialized();
        try { path = absolutePath(path); }
        catch (Exception) { status = "The document path could not be resolved."; return false; }
        foreach (i, tab; tabs)
            if (tab.path == path)
            {
                activeTab = i;
                return true;
            }
        if (files is null) files = new DocumentIo;
        const request = files.open(path);
        if (request.hasError) { status = request.error; return false; }
        openOrigins[request.value.value] = document.id;
        return true;
    }

    /// Publish only completed worker-prepared text; preserve the user's active-tab choice.
    void pollDocuments() @safe
    {
        if (files is null) return;
        foreach (result; files.poll())
        {
            ulong ticket = result.ticket.value;
            if (result.operation != FileOperation.open)
            {
                auto found = ticket in saves;
                if (found is null) continue;
                auto intent = *found;
                saves.remove(ticket);
                if (result.error.length)
                {
                    foreach (tab; tabs) if (tab.id == intent.document) tab.saving = false;
                    status = result.path ~ ": " ~ result.error;
                    if (closingDocument == intent.document) showDirtyClose(intent.document);
                }
                else if (result.operation == FileOperation.probe)
                {
                    if (result.destinationExists)
                    {
                        if (commands.palette.active) commands.palette.cancel(commands.palette.snapshot.ticket);
                        endPicker(false);
                        lantern.reset();
                        document.field.run(EditCommand.of(EditKind.blur), MonoTime.currTime);
                        foreach (i, tab; tabs) if (tab.id == intent.document) activeTab = i;
                        ++dialogEpoch;
                        replacement = intent;
                        replacementWarning = (result.externalChange ? "The destination differs from the saved version. " : "")
                            ~ "Replacing this file cannot check for concurrent changes atomically. "
                            ~ "Another writer's changes after this check may be overwritten. Replace this time?";
                        status = null;
                    }
                    else submitSave(intent, SaveAuthorization.createOnly);
                }
                else
                {
                    foreach (tab; tabs) if (tab.id == intent.document)
                    {
                        tab.saved = Text(result.revision);
                        tab.savedBytes = result.bytes;
                        tab.path = result.path;
                        tab.name = baseName(result.path);
                        tab.saving = false;
                        tab.durabilityWarning = result.receipt.durable ? null : result.receipt.warning;
                    }
                    status = (result.receipt.durable ? "Saved." : "Written, but durability is unconfirmed.")
                        ~ (result.receipt.warning.length ? " " ~ result.receipt.warning : "");
                    if (closingDocument == intent.document)
                    {
                        bool ready;
                        foreach (tab; tabs) if (tab.id == intent.document)
                            ready = !tab.dirty && !tab.durabilityWarning.length;
                        if (ready) finishClose(intent.document);
                        else showDirtyClose(intent.document);
                    }
                }
                continue;
            }
            ulong origin;
            if (const found = ticket in openOrigins) origin = *found;
            openOrigins.remove(ticket);
            if (result.error.length)
            {
                lastOpenError = result.path ~ ": " ~ result.error;
                status = lastOpenError;
                if (shotPath.length) captureError = lastOpenError;
                continue;
            }
            const activate = document.id == origin && !modal && !commands.palette.active && !lantern.active && !lantern.shown;
            bool duplicate;
            foreach (i, tab; tabs)
                if (tab.path == result.path)
                {
                    if (activate) activeTab = i;
                    duplicate = true;
                    break;
                }
            if (duplicate) continue;
            auto opened = new Document(nextId++, baseName(result.path));
            opened.field.state = EditorState.create(Text(result.revision));
            opened.field.state.selection = SelectionSet.caret(0);
            opened.field.target = target;
            opened.saved = Text(result.revision);
            opened.path = result.path;
            opened.savedBytes = result.bytes;
            opened.bom = result.decoded.bom;
            opened.predominant = result.decoded.predominant;
            opened.language = canonicalLanguageOfPath(result.path);
            if (opened.language == "txt" || opened.language == "log") opened.language = "text";
            if (activate && tabs.length == 1 && tabs[0].field.empty && !tabs[0].dirty && !tabs[0].path.length
                && tabs[0].name == "Untitled" && !tabs[0].saving
                && tabs[0].field.state.history.length == 1
                && !tabs[0].field.state.composition.active && !tabs[0].field.state.record.pendingRequest)
                tabs[0] = opened;
            else
            {
                tabs ~= opened;
                if (activate) activeTab = tabs.length - 1;
            }
            status = null;
        }
    }

    /// Stop application-owned workers even when opening the rendering host fails.
    void dispose() @safe nothrow
    {
        if (files !is null) files.shutdown();
        if (highlighting !is null) highlighting.shutdown();
    }

    /// The selected theme is a reversible preview until the palette emits acceptance.
    void previewPicker() @safe
    {
        if (!choosingTheme || !commands.palette.active || !commands.palette.rowCount) return;
        const choice = commands.palette.row(commands.palette.snapshot.selection).command;
        if (choice.operation == Command.selectTheme && choice.argument < themeNames.length
            && themeName != themeNames[cast(size_t) choice.argument])
            useTheme(themeNames[cast(size_t) choice.argument]);
    }

    private void endPicker(bool accepted) @safe
    {
        if (!choosingTheme) return;
        if (!accepted)
        {
            theme = themeBefore;
            syntaxTheme = syntaxBefore;
            themeName = themeBeforePreview;
        }
        choosingTheme = false;
        const result = commands.palette.catalog(commandCatalog(bindings));
        assert(result == PaletteStatus.ok);
    }

    /// Resolve syntax and chrome through the same library theme.
    bool useTheme(string name) @safe
    {
        const options = GuiOptions(theme: name);
        const resolved = resolveTheme(options);
        if (resolved.hasError) return false;
        theme = appThemeOf(options);
        syntaxTheme = resolveSyntaxTheme(*resolved.value, LabelSet.standard());
        themeName = name;
        return true;
    }

    /// The host shuts workers down before releasing document snapshots.
    void shutdown(H)(ref H host)
    {
        dispose();
    }
    private DisplayedFrame displayed;
    private HoverTarget[] hits;
    private const(PaletteChoice!Command)[] paletteChoices;
    private bool selecting;
    private ulong selectingDocument;
    private size_t selectionAnchor;
    private enum size_t tabHitBase = 0x7400_0000;
    private enum size_t dialogConfirmHit = 0x7500_0000, dialogCancelHit = 0x7500_0001;
    private enum size_t dialogDiscardHit = 0x7600_0000;

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
        if (pointer.action == PointerAction.drag && selectingDocument != document.id)
        {
            selecting = false;
            return;
        }
        if (pointer.button != PointerButton.left && pointer.action != PointerAction.drag) return;
        const hit = hits.hitAt(pointer.pos.x, pointer.pos.y);
        if (modal)
        {
            if (pointer.action == PointerAction.press)
            {
                if (hit == dialogConfirmHit + 2 * dialogEpoch) execute(CommandId(Command.confirm));
                else if (hit == dialogCancelHit + 2 * dialogEpoch) execute(CommandId(Command.cancel));
                else if (hit == dialogDiscardHit + dialogEpoch) execute(CommandId(Command.discard));
                else if (pathDialog && displayed !is null)
                {
                    const offset = sourceOffsetAt(displayed.tree, displayed.frames,
                        Point(cast(int) pointer.pos.x, cast(int) pointer.pos.y));
                    if (offset >= 0 && cast(size_t) offset <= pathInput.state.text.length)
                        pathInput.run(EditCommand.setRange(cast(size_t) offset, cast(size_t) offset), MonoTime.currTime);
                }
            }
            return;
        }
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
            selectingDocument = document.id;
        }
        if (selecting) document.field.run(EditCommand.setRange(selectionAnchor, at), MonoTime.currTime);
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
            pasteDialog = pathDialog ? dialogEpoch : 0;
        }
        pasteBytes ~= chunk.text[];
        if (!chunk.last) return;
        collectingPaste = false;
        scope (exit) pasteBytes.length = 0;
        if (document.id != pasteDocument || pasteDialog != (pathDialog ? dialogEpoch : 0)
            || (commands.palette.active ? commands.palette.snapshot.ticket.value : 0) != pastePalette)
        {
            status = "Paste cancelled because its input target changed.";
            return;
        }
        if (pasteDialog) pathInput.paste(pasteBytes, pasteRequest, MonoTime.currTime);
        else if (modal) return;
        else if (pastePalette)
            apply(commands.paste(pasteBytes, pasteRequest, context, MonoTime.currTime));
        else
            document.field.paste(pasteBytes, pasteRequest, MonoTime.currTime);
        document.followCaret = true;
    }

    /// The active document, lazily creating an untitled tab.
    Document document() @safe
    {
        ensureInitialized();
        return tabs[activeTab];
    }

    size_t tabCount() const @safe pure nothrow @nogc => tabs.length;

    private bool pathDialog() const scope @safe pure nothrow @nogc
        => dialog == Dialog.openPath || dialog == Dialog.savePath;

    CommandContext context() @safe => CommandContext(document.id, bindings, modal, dialog == Dialog.dirtyClose);

    /// Admit bytes before replacing any active state; unsupported UTF-8 leaves every tab intact.
    bool openBytes(string name, string bytes) @safe
    {
        const decoded = decodeDocument(bytes);
        if (decoded.hasError) { status = decoded.error; return false; }
        ensureInitialized();
        const id = nextId++;
        auto opened = new Document(id, name, decoded.value.content);
        opened.bom = decoded.value.bom;
        opened.predominant = decoded.value.predominant;
        opened.language = canonicalLanguageOfPath(name);
        if (opened.language == "txt" || opened.language == "log") opened.language = "text";
        opened.field.target = target;
        tabs ~= opened;
        activeTab = tabs.length - 1;
        return true;
    }

    private void ensureInitialized() @safe
    {
        if (tabs.length) return;
        tabs ~= new Document(nextId++, "Untitled");
        configure(target);
    }

    private void configure(EditorTarget selected) @safe
    {
        target = selected;
        commands.query.target = target;
        pathInput.target = target;
        bindings = commandBindings(target);
        if (!choosingTheme)
        {
            const result = commands.palette.catalog(commandCatalog(bindings));
            assert(result == PaletteStatus.ok);
        }
        if (commands.palette.active)
        {
            const refreshed = commands.palette.search(commands.palette.snapshot.ticket,
                commands.query.text, CommandContext(tabs[activeTab].id, bindings));
            assert(refreshed == PaletteStatus.ok);
        }
        foreach (tab; tabs) tab.field.target = target;
    }

    /// One dispatcher receives keyboard, palette and future menu/touch commands.
    void execute(CommandId id, MonoTime now = MonoTime.currTime) @safe
    {
        ensureInitialized();
        if (!context.available(id, document.id)) return;
        final switch (id.operation)
        {
        case Command.none: break;
        case Command.open: beginPath(Dialog.openPath); break;
        case Command.saveAs: beginPath(Dialog.savePath); break;
        case Command.save:
            if (document.path.length) saveTo(document.path);
            else beginPath(Dialog.savePath);
            break;
        case Command.confirm:
            if (replacement !is null) resolveOverwrite(true);
            else if (dialog == Dialog.dirtyClose)
            {
                dialog = Dialog.none;
                ++dialogEpoch;
                if (document.path.length)
                {
                    if (!saveTo(document.path)) showDirtyClose(closingDocument);
                }
                else beginPath(Dialog.savePath);
            }
            else if (pathDialog)
            {
                const requested = dialog;
                const path = pathInput.text;
                if (!path.length) { status = "Enter a destination path."; break; }
                dialog = Dialog.none;
                ++dialogEpoch;
                if (requested == Dialog.openPath) openPath(path);
                else if (!saveTo(path) && closingDocument) showDirtyClose(closingDocument);
            }
            break;
        case Command.cancel:
            if (replacement !is null) resolveOverwrite(false);
            dialog = Dialog.none;
            closingDocument = 0;
            exiting = false;
            ++dialogEpoch;
            pathInput.run(EditCommand.of(EditKind.blur), now);
            break;
        case Command.closeTab: requestClose(false); break;
        case Command.discard: finishClose(closingDocument); break;
        case Command.palette:
            endPicker(false);
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
        case Command.themes:
            themeNames = canonicalThemeNames();
            themeBeforePreview = themeName.length ? themeName : GuiOptions.init.theme;
            themeBefore = theme;
            syntaxBefore = syntaxTheme;
            choosingTheme = true;
            PaletteEntry!Command[] entries;
            foreach (i, name; themeNames)
                entries ~= PaletteEntry!Command(CommandId(Command.selectTheme, i), name, "Theme");
            const result = commands.palette.catalog(entries);
            assert(result == PaletteStatus.ok);
            commands.open(PaletteInvocation(document.id, document.id), context);
            commands.query.target = target;
            foreach (row; 0 .. commands.palette.rowCount)
            {
                const candidate = commands.palette.row(row).command;
                if (candidate.argument < themeNames.length
                    && themeNames[cast(size_t) candidate.argument] == themeName)
                {
                    commands.palette.move(commands.palette.snapshot.ticket,
                        cast(long) row - cast(long) commands.palette.snapshot.selection);
                    break;
                }
            }
            break;
        case Command.selectTheme:
            if (id.argument < themeNames.length) useTheme(themeNames[cast(size_t) id.argument]);
            break;
        case Command.toggleTheme:
            useTheme(themeName == "github-light" ? "github-dark" : "github-light");
            break;
        case Command.example:
            if (id.argument > Example.max || id.argument == Example.none) break;
            const example = cast(Example) id.argument;
            const number = nextId++;
            tabs ~= new Document(number, example == Example.code ? "example.d" : "Unicode example",
                exampleText(example));
            activeTab = tabs.length - 1;
            document.field.target = target;
            if (example == Example.code) document.language = "d";
            if (example == Example.protectedText)
            {
                document.name = "Protected text";
                document.field.state.readOnly.put(ReadOnlySpan(0, document.field.state.text.lineEnd(0)));
            }
            break;
        case Command.edit:
            if (id.argument <= EditorAction.max)
            {
                if (id.argument == EditorAction.newline)
                {
                    const predominant = document.predominant;
                    document.field.insertEach((in Text current, size_t position)
                        => enterEnding(current, position, predominant), now);
                }
                else document.field.run(commandOf(cast(EditorAction) id.argument), now);
            }
            break;
        case Command.quit: requestClose(true); break;
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
            const wasChoosing = choosingTheme;
            execute(effect.command);
            if (wasChoosing) endPicker(true);
        }
        else if (effect.kind == PaletteEffectKind.cancelled) endPicker(false);
        else if (effect.status != PaletteStatus.ok)
            status = text("Command query: ", effect.status);
    }

    /// Route modal query input first, then the shared key guide, then text insertion.
    void handleKey(in KeyEvent key, MonoTime now = MonoTime.currTime) @safe
    {
        ensureInitialized();
        if (key.action == KeyAction.release) return;
        if (pathDialog && pathInput.state.composition.active)
        {
            pathInput.key(key, now);
            return;
        }
        if (commands.palette.active)
        {
            apply(commands.key(key, context, now));
            previewPicker();
            return;
        }
        document.followCaret = true;
        const resolved = step(lantern, bindings, key, context);
        if (resolved.kind == StepKind.execute)
        {
            if (key.action == KeyAction.repeat && modal) return;
            execute(CommandId(resolved.cmd.cmd, resolved.cmd.arg), now);
        }
        else if (resolved.kind == StepKind.unbound)
        {
            if (pathDialog) pathInput.key(key, now);
            else if (!modal) document.field.key(key, now);
        }
    }

    /// The same event vocabulary reaches every rendering host.
    void handle(H)(ref H host, in Event event)
    {
        ensureInitialized();
        document.field.context.clipboardRead = canReadClipboard!H;
        document.field.context.clipboardWrite = __traits(compiles, host.clipboard(""));
        commands.query.context.clipboardRead = canReadClipboard!H;
        commands.query.context.clipboardWrite = __traits(compiles, host.clipboard(""));
        pathInput.context.clipboardRead = canReadClipboard!H;
        pathInput.context.clipboardWrite = __traits(compiles, host.clipboard(""));
        event.match!(
            (in KeyEvent key) { handleKey(key); },
            (in PasteEvent paste) { receivePaste(paste); },
            (in PointerEvent pointer) { this.pointer(pointer); },
            (in CompositionEvent update) {
                withPreedit(host, update, (scope const(char)[] preedit) {
                    if (pathDialog) pathInput.compose(update, preedit, MonoTime.currTime);
                    else if (modal) return;
                    else if (commands.palette.active) commands.query.compose(update, preedit, MonoTime.currTime);
                    else document.field.compose(update, preedit, MonoTime.currTime);
                });
            },
            (in WheelEvent wheel) {
                const wanted = cast(long) document.firstLine + wheel.dy;
                document.firstLine = wanted < 0 ? 0 : cast(size_t) wanted;
                document.followCaret = false;
            },
            (in EndOfInput _) { closeRequested(host); },
            (in _) {});
        forwardClipboard(document.field, host);
        forwardClipboard(commands.query, host);
        forwardClipboard(pathInput, host);
        if (quitRequested) host.quit();
    }

    /// One tree renders the tab strip, active field, command frontends and inspector.
    WidgetTree view(H)(ref H host)
    {
        ensureInitialized();
        pollDocuments();
        if (quitRequested)
        {
            host.quit();
            return WidgetTree.init;
        }
        if (filesBusy) host.wakeIn(8.msecs);
        if (!filesBusy && startupCommand != Command.none)
        {
            const command = startupCommand;
            startupCommand = Command.none;
            execute(CommandId(command));
        }
        if (shotPath.length && captureError.length)
        {
            host.quit();
            return WidgetTree.init;
        }
        if (highlighting is null) highlighting = new HighlightSession;
        highlighting.request(document.field.state.text, document.language, document.id);
        highlighting.poll();
        previewPicker();
        if (highlighting.busy) host.wakeIn(8.msecs);
        if (shotPath.length && !highlighting.busy && !filesBusy)
        {
            if (highlighting.error.length)
            {
                captureError = highlighting.error;
                host.quit();
                return WidgetTree.init;
            }
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
        if (modal)
        {
            children ~= b.add(Widget(kind: WidgetKind.text, text: replacement !is null
                ? "Replace existing file: " ~ replacement.path
                : dialog == Dialog.dirtyClose ? "Close " ~ document.name ~ ": Save, Discard or Cancel?"
                : dialog == Dialog.openPath ? "Open file" : "Save as", slot: Slot.info,
                wrap: TextWrap.greedy));
            if (replacement !is null)
                children ~= b.add(Widget(kind: WidgetKind.text, text: replacementWarning,
                    wrap: TextWrap.greedy, slot: Slot.warn));
            if (pathDialog)
                children ~= editorView(b, pathInput.state, EditorViewOptions(visibleLines: 1, placeholder: "Path…"));
            uint[] actions;
            actions ~= chip(b, replacement !is null ? "Replace this time"
                : dialog == Dialog.dirtyClose ? "Save" : "Enter: confirm", dialogConfirmHit + 2 * dialogEpoch,
                false, ControlSize(rows: 3));
            if (dialog == Dialog.dirtyClose)
                actions ~= chip(b, "Discard", dialogDiscardHit + dialogEpoch, false, ControlSize(rows: 3));
            actions ~= chip(b, "Esc: cancel", dialogCancelHit + 2 * dialogEpoch, false, ControlSize(rows: 3));
            children ~= b.add(Widget(kind: WidgetKind.row, children: actions, height: SizeSpec.fixed(3)));
            children ~= b.add(Widget(kind: WidgetKind.text, height: SizeSpec.grow()));
        }
        else if (commands.palette.active)
        {
            const reserved = inspector ? 12 : 11;
            const rows = host.size.height > reserved + 3
                ? cast(size_t)(host.size.height - reserved) / 3 : 1;
            const paletteView = viewCommandPalette(b, commands.palette, commands.query.state, context,
                PaletteViewOptions(visibleRows: rows,
                    title: choosingTheme ? "Themes • Enter accepts • Esc cancels" : "Commands"));
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
            const options = EditorViewOptions(firstLine: document.firstLine,
                visibleLines: visible, placeholder: "Start typing…");
            const syntax = highlighting.snapshot(document.field.state.text, document.language, document.id);
            uint field;
            if (syntax !is null && syntax.spans.length)
            {
                uint[] rows;
                const stop = document.firstLine + visible < count ? document.firstLine + visible : count;
                foreach (line; document.firstLine .. stop)
                {
                    const start = document.field.state.text.lineStart(line);
                    const end = document.field.state.text.lineEnd(line);
                    const ink = syntaxWindow(syntax.source, syntax.spans, start, end, syntaxTheme, theme.pageFg);
                    rows ~= b.add(Widget(kind: WidgetKind.rich, width: SizeSpec.grow(),
                        spans: highlightedEditorLine(document.field.state, line, ink, options)));
                }
                field = b.add(Widget(kind: WidgetKind.column, children: rows, width: SizeSpec.grow()));
            }
            else field = editorView(b, document.field.state, options);
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
                    document.field.state.composition.active, "  highlighting ",
                    highlighting.busy ? "pending" : highlighting.error.length ? highlighting.error : "ready")));
        if (status.length) children ~= b.add(Widget(kind: WidgetKind.text, text: status, slot: Slot.warn));
        if (document.durabilityWarning.length)
            children ~= b.add(Widget(kind: WidgetKind.text, text: "Durability warning: " ~ document.durabilityWarning, slot: Slot.warn));
        children ~= b.add(Widget(kind: WidgetKind.text, text: "UTF-8  •  "
            ~ (document.dirty ? "Modified" : document.durabilityWarning.length ? "Written" : "Saved")
            ~ (document.durabilityWarning.length ? " • durability unconfirmed" : ""),
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
    import sparkles.input : Key;
    import sparkles.ui.editor.keys : windowCommandMods;
    EditorApp app;
    app.execute(CommandId(Command.palette));
    assert(app.commands.palette.rowCount > 0);
    RecordingHost host;
    host.backend = Backend.gui;
    scope (exit) app.shutdown(host);
    app.view(host);
    assert(app.commands.palette.active && app.commands.palette.rowCount > 0);
    app.commands.insert("ab", app.context);
    app.handleKey(KeyEvent(Key.char_, 'a', windowCommandMods));
    app.handleKey(KeyEvent(Key.char_, 'x'));
    assert(app.commands.query.text == "x", "Startup input adopts the native host's editing keys.");
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

/// A completed save acknowledges only the captured revision, preserving newer edits.
@("editor.app.saveAcknowledgesCapturedRevision")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    import std.file : readText;
    auto fixture = TmpFS.create();
    const path = buildPath(fixture.dir, "captured.txt");
    EditorApp app;
    scope (exit) app.dispose();
    app.document.field.insert("first");
    assert(app.saveTo(path));
    app.document.field.insert(" later");
    const until = MonoTime.currTime + 3.seconds;
    while (app.filesBusy && MonoTime.currTime < until)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    assert(!app.filesBusy);
    assert((() @trusted => readText(path))() == "first");
    assert(app.document.path == path && app.document.field.text == "first later" && app.document.dirty);
    assert(app.document.saved == Text("first"));
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
    scope (exit) app.shutdown(host);
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
    scope (exit) app.shutdown(host);
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

/// Theme search previews without editing the document; Escape restores and Enter accepts.
@("editor.app.themePreviewCancelAndAccept")
@safe unittest
{
    import sparkles.input : Key;
    EditorApp app;
    assert(app.useTheme("github-dark"));
    app.document.field.setText("untouched");
    app.execute(CommandId(Command.themes));
    app.commands.insert("github-light", app.context);
    app.previewPicker();
    assert(app.themeName == "github-light" && app.document.field.text == "untouched");
    app.handleKey(KeyEvent(Key.escape));
    assert(app.themeName == "github-dark" && !app.commands.palette.active);
    app.execute(CommandId(Command.themes));
    app.commands.insert("github-light", app.context);
    app.previewPicker();
    app.handleKey(KeyEvent(Key.enter));
    assert(app.themeName == "github-light" && !app.commands.palette.active);
    assert(app.document.field.text == "untouched");
}

/// Enter honors each selected line's convention; undo restores the exact BOM/mixed-ending bytes.
@("editor.app.mixedEndingEnterAndUndo")
@safe unittest
{
    import sparkles.ui.editor.selection : EditRange, SelectionSet;
    EditorApp app;
    assert(app.openBytes("mixed.txt", "\xef\xbb\xbfa\r\nb\nc\r\n"));
    EditRange[2] ranges = [EditRange.caret(1), EditRange.caret(4)];
    app.document.field.state.selection = SelectionSet.of(ranges[], 0);
    app.execute(CommandId(Command.edit, EditorAction.newline));
    assert(app.document.encodedBytes == "\xef\xbb\xbfa\r\n\r\nb\n\nc\r\n");
    app.execute(CommandId(Command.edit, EditorAction.undo));
    assert(app.document.encodedBytes == "\xef\xbb\xbfa\r\nb\nc\r\n");
    assert(!app.openBytes("invalid.txt", "\xff"));
    assert(app.document.encodedBytes == "\xef\xbb\xbfa\r\nb\nc\r\n");
}

/// Opening a real file preserves dirty tabs; invalid UTF-8 cannot replace the active buffer.
@("editor.app.backgroundFileOpenPreservesOtherTabs")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import core.thread : Thread;
    import core.time : MonoTime, seconds;
    import sparkles.test_utils.tmpfs : TmpFS;
    auto fixture = TmpFS.create();
    const path = fixture.writeFile("\xef\xbb\xbfdisk\r\n");
    EditorApp app;
    scope (exit) app.dispose();
    app.document.field.insert("unsaved");
    const original = app.document.id;
    assert(app.openPath(path));
    const until = MonoTime.currTime + 3.seconds;
    while (app.filesBusy && MonoTime.currTime < until)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    assert(!app.filesBusy && app.document.id != original);
    assert(app.document.encodedBytes == "\xef\xbb\xbfdisk\r\n" && !app.document.dirty);
    assert(app.document.field.state.selection.primary.head == 0);
    app.execute(CommandId(Command.previousTab));
    assert(app.document.id == original && app.document.field.text == "unsaved" && app.document.dirty);
    const bad = fixture.writeFile("\xff");
    assert(app.openPath(bad));
    const badUntil = MonoTime.currTime + 3.seconds;
    while (app.filesBusy && MonoTime.currTime < badUntil)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    assert(!app.filesBusy && app.document.id == original && app.document.field.text == "unsaved");
    assert(app.status.length);
}

/// An asynchronous read cannot change the document captured by an open palette.
@("editor.app.backgroundOpenDoesNotStealPaletteTarget")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import core.thread : Thread;
    import core.time : MonoTime, seconds;
    import sparkles.test_utils.tmpfs : TmpFS;
    auto fixture = TmpFS.create();
    const path = fixture.writeFile("opened in the background");
    EditorApp app;
    scope (exit) app.dispose();
    const origin = app.document.id;
    assert(app.openPath(path));
    app.execute(CommandId(Command.palette));
    const until = MonoTime.currTime + 3.seconds;
    while (app.filesBusy && MonoTime.currTime < until)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    assert(!app.filesBusy && app.tabCount == 2 && app.document.id == origin);
    assert(app.commands.palette.active && app.commands.palette.snapshot.invocation.target == origin);
}

/// Typing separated by the configured pause remains independently undoable.
@("editor.app.typingPauseSeparatesUndo")
@safe unittest
{
    import core.time : MonoTime, seconds;
    import sparkles.input : Key;
    EditorApp app;
    const start = MonoTime.currTime;
    app.handleKey(KeyEvent(Key.char_, 'a'), start);
    app.handleKey(KeyEvent(Key.char_, 'b'), start + 1.seconds);
    app.execute(CommandId(Command.edit, EditorAction.undo));
    assert(app.document.field.text == "a");
    app.execute(CommandId(Command.edit, EditorAction.undo));
    assert(app.document.field.empty);
}

/// Save As accepts path input without inserting it into the document.
@("editor.app.saveAsKeyboardFlow")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import sparkles.input : charEvent, Key;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    import std.file : readText;
    auto fixture = TmpFS.create();
    const path = buildPath(fixture.dir, "from-dialog.txt");
    EditorApp app;
    scope (exit) app.dispose();
    app.document.field.insert("document");
    app.execute(CommandId(Command.saveAs));
    foreach (c; path) app.handleKey(KeyEvent(Key.char_, c));
    app.handleKey(KeyEvent(Key.enter));
    const until = MonoTime.currTime + 3.seconds;
    while (app.filesBusy && MonoTime.currTime < until)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    assert(!app.filesBusy && app.document.field.text == "document" && !app.document.dirty);
    assert((() @trusted => readText(path))() == "document");
}

/// Existing files remain intact until consent, including a change after the check.
@("editor.app.overwriteDecisionAndCapturedRevision")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.input : Key;
    import std.file : readText, write;
    auto fixture = TmpFS.create();
    const path = fixture.writeFile("external");
    EditorApp app;
    scope (exit) app.dispose();
    app.document.field.insert("captured");
    foreach (accept; [false, true])
    {
        const savedDocument = app.document.id;
        assert(app.saveTo(path));
        app.execute(CommandId(Command.newTab));
        const until = MonoTime.currTime + 3.seconds;
        while (app.filesBusy && MonoTime.currTime < until)
        {
            app.pollDocuments();
            (() @trusted => Thread.yield())();
        }
        assert(!app.filesBusy && app.overwritePending);
        assert(app.document.id == savedDocument, "Overwrite consent must show its captured document.");
        assert(app.document.saving);
        app.handleKey(KeyEvent(Key.enter, action: KeyAction.repeat));
        assert(app.overwritePending && !app.filesBusy, "A held Enter cannot authorize a newly opened overwrite decision.");
        assert((() @trusted => readText(path))() == "external");
        const original = app.document.id;
        app.execute(CommandId(Command.newTab));
        assert(app.document.id == original, "Overwrite consent holds focus on its captured operation.");
        if (accept)
        {
            (() @trusted { write(path, "changed after validation"); })();
            app.document.field.insert(" later");
        }
        app.execute(CommandId(accept ? Command.confirm : Command.cancel));
        const saveUntil = MonoTime.currTime + 3.seconds;
        while (app.filesBusy && MonoTime.currTime < saveUntil)
        {
            app.pollDocuments();
            (() @trusted => Thread.yield())();
        }
        assert(!app.filesBusy && !app.overwritePending && !app.document.saving);
        assert((() @trusted => readText(path))() == (accept ? "captured" : "external"));
        assert(app.document.dirty);
    }
    assert(app.document.saved == Text("captured") && app.document.field.text == "captured later");
}

/// Cancel retains focus; Discard authorizes only the requested dirty document.
@("editor.app.closeDecisionsArePerDocument")
@safe unittest
{
    EditorApp app;
    app.document.field.insert("keep A");
    const first = app.document.id;
    app.execute(CommandId(Command.newTab));
    app.document.field.insert("close B");
    const second = app.document.id;
    app.execute(CommandId(Command.closeTab));
    assert(app.tabCount == 2 && !app.quitRequested);
    app.execute(CommandId(Command.cancel));
    assert(app.document.id == second && app.document.field.text == "close B");
    app.execute(CommandId(Command.closeTab));
    app.execute(CommandId(Command.discard));
    assert(app.tabCount == 1 && app.document.id == first && app.document.field.text == "keep A");
    app.execute(CommandId(Command.quit));
    app.execute(CommandId(Command.cancel));
    assert(!app.quitRequested && app.document.id == first && app.document.field.text == "keep A");
    app.execute(CommandId(Command.quit));
    app.execute(CommandId(Command.discard));
    assert(app.quitRequested);
}

/// Modified shortcuts cannot fall through to plain-letter destructive decisions.
@("editor.app.modifiedKeysCannotDiscard")
@safe unittest
{
    import sparkles.input : Key, Mods;
    EditorApp app;
    app.document.field.insert("keep this");
    const id = app.document.id;
    app.execute(CommandId(Command.closeTab));
    foreach (mods; [Mods(ctrl: true), Mods(alt: true), Mods(super_: true), Mods(shift: true)])
    {
        app.handleKey(KeyEvent(Key.char_, 'd', mods));
        assert(app.tabCount == 1 && app.document.id == id && app.document.field.text == "keep this");
    }
    app.execute(CommandId(Command.cancel));
    assert(app.document.field.text == "keep this");
}

/// An empty tab remains owned while history or an outstanding save depends on it.
@("editor.app.backgroundOpenRetainsEmptyTabOwnership")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    const path = fixture.writeFile("opened");
    foreach (saving; [false, true])
    {
        EditorApp app;
        scope (exit) app.dispose();
        const original = app.document.id;
        if (!saving)
        {
            app.document.field.insert("undoable");
            app.execute(CommandId(Command.edit, EditorAction.undo));
        }
        assert(app.openPath(path));
        if (saving) assert(app.saveTo(buildPath(fixture.dir, "saved-empty.txt")));
        const until = MonoTime.currTime + 3.seconds;
        while (app.filesBusy && MonoTime.currTime < until)
        {
            app.pollDocuments();
            (() @trusted => Thread.yield())();
        }
        assert(!app.filesBusy && app.tabCount == 2);
        app.execute(CommandId(Command.previousTab));
        assert(app.document.id == original);
        if (!saving)
        {
            app.execute(CommandId(Command.edit, EditorAction.redo));
            assert(app.document.field.text == "undoable");
        }
        else assert(app.document.path == buildPath(fixture.dir, "saved-empty.txt") && !app.document.saving);
    }
}

/// Closing the last native tab preserves editing policy before another frame.
@("editor.app.lastNativeTabRetainsKeyboardPolicy")
@safe unittest
{
    import sparkles.input : Key, Mods;
    import sparkles.ui_app.record : RecordingHost;
    EditorApp app;
    scope (exit) app.dispose();
    RecordingHost host;
    host.backend = Backend.gui;
    cast(void) app.view(host);
    app.execute(CommandId(Command.closeTab));
    app.document.field.insert("keep this");
    app.handleKey(KeyEvent(Key.char_, 'w', Mods(ctrl: true)));
    assert(app.document.field.text == "keep this", "Native Close must not become terminal kill-word.");
    app.execute(CommandId(Command.cancel));
}

/// Native close cancels path input and promotes a tab-close decision to whole-app exit.
@("editor.app.nativeCloseResolvesExistingModal")
@safe unittest
{
    import sparkles.ui_app.record : RecordingHost;
    foreach (command; [Command.open, Command.saveAs])
    {
        EditorApp app;
        RecordingHost host;
        app.execute(CommandId(command));
        app.closeRequested(host);
        assert(app.quitRequested && host.quitRequested);
    }
    EditorApp app;
    scope (exit) app.dispose();
    RecordingHost host;
    app.document.field.insert("keep A");
    app.execute(CommandId(Command.newTab));
    app.document.field.insert("close B");
    app.execute(CommandId(Command.closeTab));
    app.closeRequested(host);
    app.execute(CommandId(Command.discard));
    assert(!app.quitRequested && app.document.field.text == "keep A");
    app.execute(CommandId(Command.discard));
    cast(void) app.view(host);
    assert(app.quitRequested && host.quitRequested);
}

/// Saving during exit waits for its receipt and asks the host to quit on completion.
@("editor.app.saveBeforeExitWaitsForReceipt")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui.geometry : Size;
    import std.file : readText;
    auto fixture = TmpFS.create();
    const path = fixture.writeFile("disk");
    EditorApp app;
    scope (exit) app.dispose();
    assert(app.openPath(path));
    const until = MonoTime.currTime + 3.seconds;
    while (app.filesBusy && MonoTime.currTime < until)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    app.document.field.insert("new ");
    app.execute(CommandId(Command.quit));
    app.execute(CommandId(Command.confirm));
    assert(app.filesBusy && !app.quitRequested);
    while (app.filesBusy && MonoTime.currTime < until)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    assert(app.overwritePending && !app.quitRequested);
    app.execute(CommandId(Command.confirm));
    RecordingHost host;
    host.size = Size(80, 28);
    while (app.filesBusy && MonoTime.currTime < until)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    cast(void) app.view(host);
    assert(app.quitRequested && host.quitRequested);
    assert((() @trusted => readText(path))() == "new disk");
}

/// A failed close-time save retains dirty text and returns to a cancellable decision.
@("editor.app.failedSaveCannotCloseDirtyDocument")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import sparkles.input : Key;
    import sparkles.test_utils.tmpfs : TmpFS;
    auto fixture = TmpFS.create();
    EditorApp app;
    scope (exit) app.dispose();
    app.document.field.insert("must survive");
    const id = app.document.id;
    app.execute(CommandId(Command.quit));
    app.execute(CommandId(Command.confirm));
    foreach (c; fixture.dir) app.handleKey(KeyEvent(Key.char_, c));
    app.handleKey(KeyEvent(Key.enter));
    const until = MonoTime.currTime + 3.seconds;
    while (app.filesBusy && MonoTime.currTime < until)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    assert(!app.filesBusy && !app.quitRequested && app.document.id == id && app.document.dirty);
    assert(app.document.field.text == "must survive" && app.status.length);
    app.execute(CommandId(Command.cancel));
    assert(!app.quitRequested && app.document.id == id && app.document.field.text == "must survive");
}
