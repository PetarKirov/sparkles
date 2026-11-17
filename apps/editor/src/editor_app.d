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
import sparkles.ui.components.scroll_body : ScrollBody, scrollSeconds;
import sparkles.ui.components.editor : DragSelection, drawIndentGuides, editorLineSpans, editorView, EditorViewOptions, markSpans, PaintedRow, PaintedRows, TextMark, visualRows;
import sparkles.ui.components.history_view : HistoryViewOptions, travelHistory = travelTo, viewHistory;
import sparkles.ui.components.gutter : blankCell, GutterCell, GutterChannel, lineNumberCell, lineNumberWidth, withGutterCells;
import sparkles.ui.editor.presentation : bracketMarks, CaretPosition, matchMarks, trailingWhitespaceMarks;
import std.array : Appender, appender;
import sparkles.ui.components.find_bar : FindBarHits, FindBarViewOptions, findBarRows, viewFindBar;
import sparkles.ui.editor.search : FindBar;
import document_font : DocumentFontService;
import sparkles.ui_app.specimen_font : SpecimenFontRequest;
import sparkles.ui.components.settings_pane : SettingsGeometry, settingsGeometryFor, SettingsPane;
import sparkles.ui.editor.search : MatchRange, SearchBudget, replaceAll, replaceCurrent, selectAllMatches, selectNextMatch;
import commands : FindOption;
import settings : choose, EditorSettings, fromSession, IndentChoice, PresentationToggle, toggle, toSession;
import sparkles.ui.editor.line_edit : IndentOptions, lineCommentToken;
import sparkles.ui.editor.context : CaretTarget;
import sparkles.text_buffer.summary : Affinity;
import sparkles.ui.editor.layout : LayoutContext, ParagraphLayout, RowIndex, scrollRows, scrollToCaret;
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
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.host : canReadClipboard, withPreedit;
import sparkles.ui_app.run_app : AppTheme;
import sparkles.ui_app.gui_options : GuiOptions, resolveTheme;
import sparkles.ui_app.run_app : appThemeOf;
import sparkles.source_view.editor : highlightedEditorLine, syntaxWindow;
import sparkles.source_view.highlight_session : HighlightSession;
import sparkles.source_view.language_catalog : LanguageCatalog;
import sparkles.syntax.label : LabelSet;
import sparkles.syntax.theme : ResolvedTheme, resolveSyntaxTheme = resolveTheme;
import sparkles.ui.editor.state : ReadOnlySpan;
import commands : Command, CommandBinding, CommandContext, CommandId, commandBindings, commandCatalog;
import examples : Example, exampleText;
import sparkles.base.text.envelope : decodeEnvelope, enterEnding, lineEndingText;
public import editor_document : Document;
import sparkles.syntax.ts.registry : canonicalLanguageOfPath, GrammarRegistry;
import sparkles.ui.editor.state : EditorState;
import sparkles.ui.editor.selection : SelectionSet;
import document_io : DocumentIo, FileOperation;
import document_files : SaveAuthorization;
import std.path : absolutePath, baseName;
import session_runtime : RecoverySession;

private class DisplayedFrame
{
    const WidgetTree tree;
    const Frame[] frames;
    ulong document;
    ulong dialogEpoch;
    Text source;
    Text pathSource;
    ulong[] tabs;
    /// The document's drawn rows and the wrap they were laid out at.
    PaintedRows painted;

    /// The painted rows, top to bottom.
    inout(PaintedRow)[] rows() inout @safe pure nothrow @nogc => painted.rows;
    /// The wrap width the rows were laid out at.
    size_t wrapCells() const @safe pure nothrow @nogc => painted.wrapCells;

    this(const WidgetTree tree, const Frame[] frames, Document document) @safe pure nothrow
    {
        this.tree = tree;
        this.frames = frames;
        if (document !is null)
        {
            this.document = document.id;
            source = Text(document.field.state.text);
        }
    }
}

/// Deliberate exit waits for the latest session to become durable and retains saved tabs.
@("editor.app.exitFlushesSession")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import session_archive : readSessionGeneration;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui.geometry : Size;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    EditorApp app;
    app.enableRecovery(buildPath(fixture.dir, "sessions"), fixture.dir);
    assert(app.openBytes("saved", "saved contents"));
    app.execute(CommandId(Command.quit));
    assert(!app.quitRequested);
    RecordingHost host;
    host.size = Size(80, 28);
    const deadline = MonoTime.currTime + 3.seconds;
    while (!app.quitRequested && MonoTime.currTime < deadline)
    {
        cast(void) app.view(host);
        (() @trusted => Thread.yield())();
    }
    assert(app.quitRequested && host.quitRequested);
    const record = readSessionGeneration(app.recovery.directoryPath, app.recovery.durableGeneration);
    assert(record.hasValue && record.value.tabs[$ - 1].content == "saved contents");
}

private class SaveIntent
{
    ulong document;
    string path;
    Text revision;
    bool bom;
}

private struct ClipboardRead
{
    ulong document, palette, dialog;
    uint request;
    /// The find bar's epoch and field (`2 * epoch + replacement`); 0 for none.
    ulong find;
}

/// Closing a requester invalidates its reply even when the next tab reuses the local number.
@("editor.app.clipboardReplyAfterCloseIsIgnored")
@safe unittest
{
    import sparkles.input : NoEvent, pasteChunks;
    import sparkles.ui_app.record : RecordingHost;
    EditorApp app;
    RecordingHost host;
    app.handle(host, Event(NoEvent()));
    app.execute(CommandId(Command.edit, EditorAction.paste));
    app.handle(host, Event(NoEvent()));
    const closedRequest = host.clipboardReads[0];
    app.execute(CommandId(Command.closeTab));
    app.handle(host, Event(NoEvent()));
    app.execute(CommandId(Command.edit, EditorAction.paste));
    app.handle(host, Event(NoEvent()));
    const currentRequest = host.clipboardReads[1];
    pasteChunks("closed owner", (in Event event) { app.handle(host, event); }, closedRequest);
    assert(app.document.field.empty);
    pasteChunks("current owner", (in Event event) { app.handle(host, event); }, currentRequest);
    assert(app.document.field.text == "current owner");
}

/// A late document reply cannot become the Save As field's clipboard answer.
@("editor.app.clipboardCannotCrossIntoPathDialog")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("This native path/clipboard scenario currently exercises Linux.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import sparkles.input : Key, Mods, NoEvent, pasteChunks;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui.geometry : Size;
    import std.path : buildPath;
    import std.file : exists, readText;
    auto fixture = TmpFS.create();
    const destination = buildPath(fixture.dir, "right.txt");
    const wrong = buildPath(fixture.dir, "wrong.txt");
    EditorApp app;
    RecordingHost host;
    host.backend = Backend.gui;
    host.size = Size(80, 28);
    cast(void) app.view(host);
    app.handle(host, Event(NoEvent()));
    app.document.field.insert("payload");
    app.execute(CommandId(Command.edit, EditorAction.paste));
    app.handle(host, Event(NoEvent()));
    const documentRequest = host.clipboardReads[0];
    app.execute(CommandId(Command.saveAs));
    app.handle(host, Event(KeyEvent(Key.char_, 'v', Mods(ctrl: true))));
    assert(host.clipboardReads.length == 2);
    const pathRequest = host.clipboardReads[1];
    pasteChunks(wrong, (in Event event) { app.handle(host, event); }, documentRequest);
    pasteChunks(destination, (in Event event) { app.handle(host, event); }, pathRequest);
    app.execute(CommandId(Command.confirm));
    const deadline = MonoTime.currTime + 3.seconds;
    while (app.filesBusy && MonoTime.currTime < deadline)
    {
        app.pollDocuments();
        (() @trusted => Thread.yield())();
    }
    assert(!app.filesBusy && (() @trusted => exists(destination))());
    assert((() @trusted => readText(destination))() == "payload");
    assert(!(() @trusted => exists(wrong))() && app.document.field.text == "payload");
}

/// Delayed clipboard answers retain the requesting tab even when another tab also asks to paste.
@("editor.app.clipboardRepliesKeepTheirOwner")
@safe unittest
{
    import sparkles.input : NoEvent, pasteChunks;
    import sparkles.ui_app.record : RecordingHost;
    EditorApp app;
    RecordingHost host;
    app.handle(host, Event(NoEvent()));
    auto first = app.document;
    app.execute(CommandId(Command.edit, EditorAction.paste));
    app.handle(host, Event(NoEvent()));
    assert(host.clipboardReads.length == 1);
    const requestA = host.clipboardReads[0];
    app.execute(CommandId(Command.newTab));
    app.handle(host, Event(NoEvent()));
    auto second = app.document;
    app.execute(CommandId(Command.edit, EditorAction.paste));
    app.handle(host, Event(NoEvent()));
    assert(host.clipboardReads.length == 2);
    const requestB = host.clipboardReads[1];
    pasteChunks("from A", (in Event event) { app.handle(host, event); }, requestA);
    assert(first.field.text == "from A" && second.field.empty && app.document is second);
    pasteChunks("from B", (in Event event) { app.handle(host, event); }, requestB);
    assert(first.field.text == "from A" && second.field.text == "from B");
    pasteChunks("old reply", (in Event event) { app.handle(host, event); }, requestA);
    assert(first.field.text == "from A" && second.field.text == "from B");
}

/// Without an interactive surface, a failed final checkpoint is returned to the CLI.
@("editor.app.hostTeardownReportsRecoveryFailure")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui_app.record : RecordingHost;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    EditorApp app;
    app.enableRecovery(buildPath(fixture.dir, "outside"), buildPath(fixture.dir, "root"));
    app.document.field.insert("retained contents");
    RecordingHost host;
    app.shutdown(host);
    assert(app.recoveryShutdownError.length && app.document.field.text == "retained contents");
}

/// Nonvetoable host teardown checkpoints edits that have not reached another view pass.
@("editor.app.hostTeardownFlushesLatestEdits")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import session_discovery : discoverSessions;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui_app.record : RecordingHost;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    const base = buildPath(fixture.dir, "sessions");
    EditorApp app;
    app.enableRecovery(base, fixture.dir);
    app.document.field.insert("last moment");
    RecordingHost host;
    app.shutdown(host);
    auto catalog = discoverSessions(base);
    scope (exit) foreach (offer; catalog.offers) offer.close();
    assert(catalog.offers.length == 1 && catalog.offers[0].record.tabs[0].content == "last moment");
}

/// A restored duplicate becomes an unsaved copy and cannot overwrite another open tab.
@("editor.app.restoreDuplicatePathIsCopy")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import session_directory : SessionDirectory;
    import session_archive : appendSessionGeneration;
    import session_record : SessionRecord, SessionTab, SessionSelection;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui.geometry : Size;
    import std.path : buildPath;
    import std.file : readText;
    auto fixture = TmpFS.create();
    const path = fixture.writeFile("disk");
    const base = buildPath(fixture.dir, "sessions");
    auto old = SessionDirectory.create(base, fixture.dir);
    assert(old.hasValue);
    SessionRecord record;
    record.generation = 1;
    record.active = 7;
    record.tabs = [SessionTab(id: 7, path: path, name: "recovered", content: "recovered draft",
        savedContent: "disk", selections: [SessionSelection(0, 0)])];
    assert(appendSessionGeneration(old.value.path, record).hasValue);
    old.value.close();
    EditorApp app;
    app.enableRecovery(base, fixture.dir);
    assert(app.openPath(path));
    RecordingHost host;
    host.size = Size(80, 28);
    const deadline = MonoTime.currTime + 3.seconds;
    while ((app.filesBusy || !app.recovery.discoveryComplete) && MonoTime.currTime < deadline)
    {
        cast(void) app.view(host);
        (() @trusted => Thread.yield())();
    }
    auto current = app.document;
    current.field.insert("local ");
    app.execute(CommandId(Command.restoreSession));
    app.execute(CommandId(Command.confirm));
    assert(app.tabCount == 2 && app.document.path.length == 0 && app.document.dirty);
    assert(app.document.field.text == "recovered draft" && current.field.text == "local disk");
    assert(current.path == path && !app.saveTo(path));
    assert((() @trusted => readText(path))() == "disk");
}

/// Explicit restore merges into the current session without replacing edits made during discovery.
@("editor.app.restoreKeepsCurrentEdits")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import session_directory : SessionDirectory;
    import session_archive : appendSessionGeneration;
    import session_record : SessionRecord, SessionTab, SessionSelection;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui.geometry : Size;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    const base = buildPath(fixture.dir, "sessions");
    auto old = SessionDirectory.create(base, fixture.dir);
    assert(old.hasValue);
    SessionRecord record;
    record.generation = 1;
    record.active = 7;
    record.theme = "github-dark";
    record.tabs = [SessionTab(id: 7, name: "recovered", content: "recovered draft",
        savedContent: "disk", selections: [SessionSelection(0, 0)])];
    assert(appendSessionGeneration(old.value.path, record).hasValue);
    old.value.close();
    EditorApp app;
    app.enableRecovery(base, fixture.dir);
    assert(app.openBytes("current", "current text"));
    app.document.field.run(EditCommand.setRange(0, 0), MonoTime.currTime);
    app.document.field.insert("new ");
    auto current = app.document;
    const count = app.tabCount;
    RecordingHost host;
    host.size = Size(80, 28);
    const deadline = MonoTime.currTime + 3.seconds;
    while (!app.recovery.discoveryComplete && MonoTime.currTime < deadline)
    {
        cast(void) app.view(host);
        (() @trusted => Thread.yield())();
    }
    assert(app.document is current && current.field.text == "new current text");
    app.execute(CommandId(Command.restoreSession));
    app.execute(CommandId(Command.cancel));
    assert(app.document is current && app.tabCount == count && app.recovery.offerCount == 1);
    app.execute(CommandId(Command.restoreSession));
    app.execute(CommandId(Command.confirm));
    assert(app.tabCount == count + 1 && app.document.id != 7 && app.document !is current);
    assert(app.document.field.text == "recovered draft" && app.document.dirty);
    assert(current.field.text == "new current text" && current.dirty && app.themeName == "github-dark");
    assert(app.recovery.offerCount == 0 && app.recovery.pending);
}

/// Recovery failures keep exit cancellable; an explicit failure decision alone permits bypass.
@("editor.app.failedRecoveryExitIsCancellable")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import core.thread : Thread;
    import core.time : seconds;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui.geometry : Size;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    EditorApp app;
    // A path outside the supplied platform namespace is a genuine bootstrap failure.
    app.enableRecovery(buildPath(fixture.dir, "outside"), buildPath(fixture.dir, "root"));
    assert(app.openBytes("saved", "retained contents"));
    app.execute(CommandId(Command.quit));
    app.execute(CommandId(Command.discard));
    assert(!app.quitRequested, "A pending checkpoint cannot be silently bypassed.");
    RecordingHost host;
    host.size = Size(80, 28);
    const deadline = MonoTime.currTime + 3.seconds;
    while (!app.recovery.error.length && MonoTime.currTime < deadline)
    {
        cast(void) app.view(host);
        (() @trusted => Thread.yield())();
    }
    assert(app.recovery.error.length && !app.quitRequested);
    app.execute(CommandId(Command.cancel));
    assert(!app.quitRequested && app.document.field.text == "retained contents");
    app.execute(CommandId(Command.quit));
    cast(void) app.view(host);
    app.execute(CommandId(Command.confirm));
    app.execute(CommandId(Command.discard));
    assert(!app.quitRequested, "A queued action cannot reuse the failure decision after Retry.");
    cast(void) app.view(host);
    app.execute(CommandId(Command.discard));
    assert(app.quitRequested);
    app.shutdown(host);
    assert(!app.recoveryShutdownError.length,
        "An explicit Exit without recovery decision must not become a CLI failure afterward.");
}

/**
The visual rows before each line of `document` (`EAP17`, `EAP29`), counted
once per text and wrap width: a steady frame reuses them, and a line short
enough to be one row is counted without a layout.
*/
private ref RowIndex rowIndex(Document document) @safe
{
    document.rows.refresh(document.field.context, document.field.state.text);
    return document.rows;
}

private enum Dialog : ubyte { none, openPath, savePath, dirtyClose, recoveryClose, restoreOffer }

/// Thin shared-widget component, instantiated by recording, TUI and Vulkan hosts.
struct EditorApp
{
    // The app owns its workers (files, highlighting, language discovery,
    // recovery): its one owner stops them when it goes out of scope.
    @disable this(this);
    ~this() @safe nothrow { dispose(); }

    AppTheme theme;
    PaletteInput!(Command, 512) commands;
    bool inspector;
    /// Every setting the pane edits (EAP15): presentation and indentation.
    EditorSettings settings;
    /// The settings pane, generated from `settings` (EAP15); it holds the keyboard while open.
    SettingsPane!EditorSettings settingsPane;
    private int[2] lastSize = [80, 24];
    // The status bar's column, for the text and caret it was counted at.
    private CaretPosition caretPosition;
    /// The find and replace bar (EAP5, EAP7).
    FindBar finder;
    bool quitRequested;
    string status;
    string shotPath;
    string captureError;
    string recoveryShutdownError;
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
    private ClipboardRead pasteOwner;
    private ClipboardRead[uint] clipboardReads;
    private uint nextClipboardRead;
    private HighlightSession highlighting;
    private ResolvedTheme syntaxTheme;
    string themeName;
    private bool choosingTheme;
    private string themeBeforePreview;
    private AppTheme themeBefore;
    private ResolvedTheme syntaxBefore;
    private string[] themeNames;
    private LanguageCatalog languageCatalog;
    private string[] languageNames;
    private bool choosingLanguage;
    // The font picker (EAP16): monospace families unless `allFamilies`.
    private bool choosingFont, allFamilies;
    private string[] fontNames;
    private DocumentFontService fonts;
    private DocumentIo files;
    private ulong[ulong] openOrigins;
    private SaveIntent[ulong] saves;
    private SaveIntent replacement;
    private string replacementWarning;
    private Dialog dialog;
    private EditorField pathInput;
    private ulong dialogEpoch;
    private ulong closingDocument;
    private bool exiting;
    private RecoverySession recovery;
    private bool recoveryExit;
    private bool recoveryFailureShown;
    private bool skipRecoveryFlush;
    Command startupCommand;

    /// Enable recovery only with an explicitly supplied platform state namespace.
    void enableRecovery(string base, string durableRoot) @safe nothrow
    {
        if (recovery is null) recovery = new RecoverySession(base, durableRoot);
    }

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

    private void showRestoreOffer() @safe
    {
        if (filesBusy) { status = "Wait for pending file operations before restoring."; return; }
        if (commands.palette.active) commands.palette.cancel(commands.palette.snapshot.ticket);
        endPicker(false);
        document.field.run(EditCommand.of(EditKind.blur), MonoTime.currTime);
        lantern.reset();
        dialog = Dialog.restoreOffer;
        ++dialogEpoch;
    }

    private void acceptRestoreOffer() @safe
    {
        if (recovery is null || !recovery.offerCount) return;
        auto offered = recovery.offer(0);
        const restoredActive = offered.record.active;
        const restoredTheme = offered.record.theme;
        settings = fromSession(offered.record.settings);
        if (replaceableUntitled) removeDocument(tabs[0].id);
        foreach (i; 0 .. offered.documentCount)
        {
            auto restored = offered.document(i);
            const selected = restored.id == restoredActive;
            foreach (tab; tabs)
                if (restored.path.length && tab.path == restored.path)
                {
                    restored.path = null;
                    restored.savedBytes = null;
                    restored.saved = Text.init;
                    restored.name ~= " (recovered copy)";
                    break;
                }
            restored.id = nextId++;
            restored.field.target = target;
            tabs ~= restored;
            if (selected) activeTab = tabs.length - 1;
        }
        dialog = Dialog.none;
        ++dialogEpoch;
        status = restoredTheme.length && !useTheme(restoredTheme)
            ? "The recovered theme is unavailable; the current theme was retained." : "Restored previous session.";
        observeRecovery();
        recovery.consumeOffer(0);
    }

    private bool replaceableUntitled() const scope @safe pure nothrow @nogc
        => tabs.length == 1 && tabs[0].field.empty && !tabs[0].dirty && !tabs[0].path.length
            && tabs[0].name == "Untitled" && !tabs[0].saving
            && tabs[0].field.state.history.length == 1
            && !tabs[0].field.state.composition.active && !tabs[0].field.state.record.pendingRequest;

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
        if (recovery is null) quitRequested = true;
        else
        {
            selecting = false;
            recoveryExit = true;
            recoveryFailureShown = false;
            dialog = Dialog.recoveryClose;
            ++dialogEpoch;
            observeRecovery();
            recovery.flush();
        }
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

    private void finishClose(ulong id, bool discarded = true) @safe
    {
        if (closingDocument != id) return;
        if (!exiting || discarded) removeDocument(id);
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
                        if (ready) finishClose(intent.document, false);
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
            if (activate && replaceableUntitled)
                tabs[0] = opened;
            else
            {
                tabs ~= opened;
                if (activate) activeTab = tabs.length - 1;
            }
            status = null;
        }
    }

    /// Stop application-owned workers; the destructor does so too. Idempotent:
    /// a worker stopped here is released, so a later call does nothing.
    void dispose() @safe nothrow
    {
        if (files !is null) { files.shutdown(); files = null; }
        if (highlighting !is null) { highlighting.shutdown(); highlighting = null; }
        if (languageCatalog !is null) { languageCatalog.shutdown(); languageCatalog = null; }
        if (recovery !is null) { recovery.shutdown(); recovery = null; }
        if (fonts !is null)
        {
            try fonts.stop();
            catch (Exception) {} // a failed join leaves nothing for the caller to do
            fonts = null;
        }
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
        if (!choosingTheme && !choosingLanguage && !choosingFont) return;
        if (choosingTheme && !accepted)
        {
            theme = themeBefore;
            syntaxTheme = syntaxBefore;
            themeName = themeBeforePreview;
        }
        choosingTheme = false;
        choosingLanguage = false;
        choosingFont = false;
        const result = commands.palette.catalog(commandCatalog(bindings));
        assert(result == PaletteStatus.ok);
    }

    /// The font picker's rows: the default face, then the listed families (`EAP16`).
    private void installFonts() @safe
    {
        fontNames = fonts is null ? null : fonts.familyNames(allFamilies);
        PaletteEntry!Command[] entries = [PaletteEntry!Command(CommandId(Command.selectFont, 0),
            "Default document font", "Font")];
        // The palette holds a bounded catalog: list what fits and say so,
        // rather than refuse the whole list.
        enum size_t capacity = 511;
        foreach (index, name; fontNames)
        {
            if (entries.length > capacity) break;
            entries ~= PaletteEntry!Command(CommandId(Command.selectFont, index + 1), name,
                allFamilies ? "Font" : "Monospace font");
        }
        if (fontNames.length > capacity)
            status = text("Listing the first ", capacity, " of ", fontNames.length,
                " families; set --document-font for another.");
        if (commands.palette.catalog(entries) != PaletteStatus.ok)
        {
            status = "The font list could not be shown.";
            return;
        }
        if (commands.palette.active)
        {
            const searched = commands.palette.search(commands.palette.snapshot.ticket,
                commands.query.text, context);
            assert(searched == PaletteStatus.ok);
        }
    }

    private void installLanguages() @safe
    {
        languageNames = ["text"];
        if (languageCatalog !is null && languageCatalog.ready)
        {
            foreach (name; languageCatalog.names)
                if (name != "text") languageNames ~= name;
            if (languageCatalog.error.length) status = languageCatalog.error;
        }
        PaletteEntry!Command[] entries;
        foreach (index, name; languageNames)
            entries ~= PaletteEntry!Command(CommandId(Command.selectLanguage, index),
                name == "text" ? "Plain text" : name, "Language");
        const result = commands.palette.catalog(entries);
        assert(result == PaletteStatus.ok);
        if (commands.palette.active)
        {
            const searched = commands.palette.search(commands.palette.snapshot.ticket,
                commands.query.text, context);
            assert(searched == PaletteStatus.ok);
        }
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
        scope (exit) dispose();
        if (recovery is null || recovery.closed || skipRecoveryFlush) return;
        observeRecovery();
        recovery.flush();
        while (recovery.pending)
        {
            recovery.poll();
            if (recovery.error.length && !recovery.busy) break;
            if (recovery.pending)
            {
                import core.thread : Thread;
                (() @trusted { Thread.sleep(1.msecs); })();
            }
        }
        recoveryShutdownError = recovery.error;
    }
    private DisplayedFrame displayed;
    /// The rows the last view drew, for the frame `paint` retains.
    private PaintedRows shownRows;
    /// Whether text input has been asked for since the text was last tapped.
    private bool keyboardAsked;
    private HoverTarget[] hits;
    private const(PaletteChoice!Command)[] paletteChoices;
    /// A press on the document began a selection that drags extend (`EAP17`).
    private DragSelection drag;
    private ref bool selecting() return @safe pure nothrow @nogc => drag.active;
    private ulong selectingDocument;
    private ScrollBody paletteScroll;
    private size_t paletteLastSelection = size_t.max, paletteLastRowCount = size_t.max;
    private bool paletteTouching, palettePanning;
    private PointerEvent paletteTouchPress;
    private bool editorTouching, editorPanning;
    private PointerEvent editorTouchPress;
    private enum size_t tabHitBase = 0x7400_0000;
    private enum size_t dialogConfirmHit = 0x7500_0000, dialogCancelHit = 0x7500_0001;
    private enum size_t dialogDiscardHit = 0x7600_0000;
    private enum size_t restoreHit = 0x7800_0000;
    private enum size_t paletteHit = 0x7900_0000;
    private enum size_t newTabHit = 0x7900_0001;
    private enum size_t saveHit = 0x7900_0002;
    private enum size_t inspectorHit = 0x7900_0003;
    private enum size_t paletteCloseHit = 0x7900_0004;
    // One hit per undo revision the inspector lists, by creation index (EAP6).
    private enum size_t undoHitBase = 0x7A00_0000, undoHitLimit = 0x7B00_0000;
    // The find bar's controls: a command per hit, `findHitBase + Command`.
    private enum size_t findHitBase = 0x7C00_0000, findOptionHitBase = 0x7C01_0000, findFieldHit = 0x7C02_0000;

    /// Retain the committed frame for event routing; no second layout/hit model.
    void paint(H)(ref H host, const WidgetTree tree, const Frame[] frames)
    {
        displayed = new DisplayedFrame(tree, frames,
            recoveryExit || !tabs.length ? null : tabs[activeTab]);
        foreach (tab; tabs) displayed.tabs ~= tab.id;
        displayed.dialogEpoch = dialogEpoch;
        if (pathDialog) displayed.pathSource = Text(pathInput.state.text);
        displayed.painted = shownRows;
        hits = hoverTargets(tree, frames);
        static if (__traits(hasMember, H, "textInputArea"))
        {
            int[4] area;
            if (!modal && !commands.palette.active && !finding && drawnCaretArea(area))
                host.textInputArea(area[0], area[1], area[2], area[3]);
        }
    }

    /**
    The find bar (`EAP5`, `EAP7`): the query with its switches, its match
    summary and Previous/Next/Close, and, when replacing, the replacement
    with Replace and All (`viewFindBar`). Each control's hit is a command,
    `findHitBase + Command`; the focused field shows the host's cursor.
    */
    private uint findBar(ref Builder b) @safe
    {
        const primary = document.field.state.selection.primary;
        const hits = FindBarHits(previous: findHitBase + Command.findPrevious, next: findHitBase + Command.findNext,
            close: findHitBase + Command.closeFind, replaceOne: findHitBase + Command.replaceOne,
            replaceAll: findHitBase + Command.replaceAll, optionBase: findOptionHitBase,
            queryField: findFieldHit, replacementField: findFieldHit + 1);
        return viewFindBar(b, finder, primary.start, primary.end, FindBarViewOptions(hits: hits));
    }

    /// The tree nodes of the document rows last painted, top to bottom.
    size_t[] paintedRowNodes() const @safe pure nothrow
    {
        size_t[] nodes;
        if (displayed !is null) foreach (shown; displayed.rows) nodes ~= shown.node;
        return nodes;
    }

    /**
    Whether the settings pane holds the keyboard and the frame. A dialog (a
    dirty close, say) closes it, so the decision is seen and answered. The
    pane is re-pointed at `settings` on each use: the app can be moved, so a
    pointer kept from `open` could be stale.
    */
    private bool settingsOpen() @safe
    {
        if (!settingsPane.active) return false;
        if (modal)
        {
            (() @trusted => settingsPane.close())();
            return false;
        }
        (() @trusted { settingsPane.subject = &settings; })(); // this app's field, current for this call
        return true;
    }

    /// The settings pane's size for the last frame's window.
    private SettingsGeometry settingsGeometry() const @safe pure nothrow @nogc
        => settingsGeometryFor(lastSize[0], lastSize[1]);

    /// The find bar's seed: the primary selection when it is one short line.
    private string findSeed() @safe
    {
        const primary = document.field.state.selection.primary;
        if (primary.empty || primary.end - primary.start > 256) return null;
        auto bytes = new char[primary.end - primary.start];
        document.field.state.text.copyTo(primary.start, primary.end, bytes);
        foreach (c; bytes) if (c == '\n' || c == '\r') return null;
        return (() @trusted => cast(string) bytes)();
    }

    /// The find bar's matches on `[start, end]`, painted as marks (`EAP5`).
    private void findMarks(size_t start, size_t end, ref Appender!(TextMark[]) marks) @safe
    {
        if (finder.open && finder.pattern.valid) matchMarks(marks, finder.result.matches, start, end);
    }

    /**
    Give the active document the app's indentation and its language's line
    comment (`EAP7`): applied before each command and frame, so a language
    override or a settings change reaches the next keystroke.
    */
    private void applyEditing() @safe
    {
        auto options = &document.field.state.options;
        options.indent = IndentOptions(useTabs: settings.editing.useTabs, width: settings.editing.indentWidth,
            autoIndent: settings.editing.autoIndent);
        options.lineComment = lineCommentToken(document.language);
    }

    /**
    Travel the active document's history to revision `index` in creation
    order (`EAP6`), through the shared editor's `earlier`/`later`, so the
    move is one ordinary history step. An index past the history is ignored.
    */
    void travelTo(size_t index) @safe
    {
        travelHistory(document.field, index, MonoTime.currTime);
    }

    /**
    The inspector's undo tree (`EAP6`, `viewHistory`): up to `limit`
    revisions in creation order around the current one; revision `i`'s row
    is hit `undoHitBase + i`, and a press travels there.
    */
    private uint[] undoRows(ref Builder b, size_t limit) @safe
        => viewHistory(b, document.field.state.history, HistoryViewOptions(limit: limit, hitBase: undoHitBase,
            hint: "Alt+U earlier, Alt+Shift+U later; select one to travel"));

    /**
    The status bar's position (`EAP5`): the primary caret's 1-based line and
    grapheme column, the selection count when several, and the language.
    */
    private string statusPosition() @safe
    {
        const state = &document.field.state;
        caretPosition.refresh(state.text, state.selection.primary.head);
        const line = caretPosition.line, column = caretPosition.column;
        const ranges = state.selection.ranges.length;
        return text("Ln ", line, ", Col ", column,
            ranges > 1 ? text("  •  ", ranges, " selections") : "",
            "  •  ", document.language.length && document.language != "text" ? document.language : "Plain text");
    }

    /**
    The marks every visible line shares (`EAP5`): the bracket at the primary
    caret and its partner, or an unmatched one in the error slot.
    */
    private TextMark[] documentMarks() @safe
    {
        auto marks = appender!(TextMark[]);
        if (settings.view.bracketMatching) bracketMarks(marks, document.field.state);
        return marks[];
    }

    /// The primary caret's drawn cell in the window, from the rows just
    /// painted (`EDI6`, `EAP20`, `PaintedRows.caretCell`); `false` when the
    /// caret's row is not on screen.
    private bool drawnCaretArea(out int[4] area) @safe
        => displayed !is null && displayed.painted.caretCell(displayed.frames, area);

    private void pointer(H)(ref H host, in PointerEvent pointer) @safe
    {
        int cw = 1, ch = 1;
        static if (__traits(hasMember, H, "cellWidth"))
            if (host.backend == Backend.gui) { cw = host.cellWidth; ch = host.cellHeight; }
        if (cw < 1) cw = 1;
        if (ch < 1) ch = 1;
        bool touch = false;
        static if (__traits(hasMember, H, "capabilities")) touch = !host.capabilities.hover;
        const float fx = pointer.pos.x / cast(float) cw;
        const float fy = pointer.pos.y / cast(float) ch;
        const point = Point(pointer.pos.x / cw, pointer.pos.y / ch);
        const slop = (cw > ch ? cw : ch) / 4 + 1;

        if (touch && commands.palette.active && paletteTouching && pointer.pointerId == paletteTouchPress.pointerId)
        {
            if (pointer.action == PointerAction.leave)
            {
                paletteTouching = palettePanning = false;
                paletteScroll.cancelDrag();
                return;
            }
            const dx = pointer.pos.x - paletteTouchPress.pos.x;
            const dy = pointer.pos.y - paletteTouchPress.pos.y;
            const ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
            if (!palettePanning && ay >= slop && ay > ax) palettePanning = true;
            if (palettePanning)
            {
                paletteScroll.dragTo(pointer.pos.y / cast(double) ch, scrollSeconds());
                if (pointer.action == PointerAction.release)
                {
                    paletteScroll.endDrag(scrollSeconds());
                    paletteTouching = palettePanning = false;
                }
                return;
            }
            if (pointer.action == PointerAction.release)
            {
                paletteTouching = palettePanning = false;
                paletteScroll.cancelDrag();
                if (ax < slop && ay < slop)
                {
                    const hit = hits.hitAt(fx, fy);
                    const base = PaletteViewOptions.init.hitBase;
                    if (hit >= base && hit - base < paletteChoices.length)
                        apply(commands.palette.activate(paletteChoices[hit - base], context));
                    else if (hit == paletteCloseHit || hit == paletteHit || hit == 0)
                        commands.palette.cancel(commands.palette.snapshot.ticket);
                }
                return;
            }
            return;
        }
        if (touch && editorTouching && pointer.pointerId == editorTouchPress.pointerId)
        {
            if (pointer.action == PointerAction.leave)
            {
                editorTouching = editorPanning = false;
                document.scroll.cancelDrag();
                return;
            }
            const dx = pointer.pos.x - editorTouchPress.pos.x;
            const dy = pointer.pos.y - editorTouchPress.pos.y;
            const ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
            if (!editorPanning && ay >= slop && ay > ax)
            {
                editorPanning = true;
                document.followCaret = false;
                document.scroll.motion.instant = false;
            }
            if (editorPanning)
            {
                document.scroll.dragTo(pointer.pos.y / cast(double) ch, scrollSeconds());
                if (pointer.action == PointerAction.release)
                {
                    document.scroll.endDrag(scrollSeconds());
                    editorTouching = editorPanning = false;
                }
                return;
            }
            if (pointer.action == PointerAction.release)
            {
                editorTouching = editorPanning = false;
                document.scroll.cancelDrag();
                if (ax < slop && ay < slop)
                    placeCaretAt(point, pointer.mods.shift, true);
                return;
            }
            return;
        }

        if (pointer.action == PointerAction.release || pointer.action == PointerAction.leave)
        {
            selecting = false;
            return;
        }
        if (pointer.action != PointerAction.press && pointer.action != PointerAction.drag) return;
        if (recoveryExit && pointer.action != PointerAction.press) return;
        if (pointer.action == PointerAction.drag && selectingDocument != document.id)
        {
            selecting = false;
            return;
        }
        if (pointer.button != PointerButton.left && pointer.action != PointerAction.drag) return;
        if (displayed is null || displayed.dialogEpoch != dialogEpoch)
        {
            selecting = false;
            return;
        }
        const hit = hits.hitAt(fx, fy);
        if (modal)
        {
            if (pointer.action == PointerAction.press)
            {
                if (hit == dialogConfirmHit + 2 * dialogEpoch) execute(CommandId(Command.confirm));
                else if (hit == dialogCancelHit + 2 * dialogEpoch) execute(CommandId(Command.cancel));
                else if (hit == dialogDiscardHit + dialogEpoch) execute(CommandId(Command.discard));
                else if (pathDialog && displayed.pathSource == pathInput.state.text)
                {
                    const offset = sourceOffsetAt(displayed.tree, displayed.frames, point);
                    if (offset >= 0 && cast(size_t) offset <= pathInput.state.text.length)
                        pathInput.run(EditCommand.setRange(cast(size_t) offset, cast(size_t) offset), MonoTime.currTime);
                }
            }
            return;
        }
        if (commands.palette.active)
        {
            if (touch && pointer.action == PointerAction.press)
            {
                paletteTouching = true;
                palettePanning = false;
                paletteTouchPress = pointer;
                paletteScroll.touch = true;
                paletteScroll.motion.instant = false;
                paletteScroll.beginDrag(pointer.pos.y / cast(double) ch, scrollSeconds());
                return;
            }
            const base = PaletteViewOptions.init.hitBase;
            if (pointer.action == PointerAction.press)
            {
                if (hit >= base && hit - base < paletteChoices.length)
                    apply(commands.palette.activate(paletteChoices[hit - base], context));
                else if (hit == paletteCloseHit || hit == paletteHit || hit == 0)
                    commands.palette.cancel(commands.palette.snapshot.ticket);
            }
            return;
        }
        if (hit == paletteHit)
        {
            if (pointer.action == PointerAction.press) execute(CommandId(Command.palette));
            return;
        }
        if (hit == newTabHit)
        {
            if (pointer.action == PointerAction.press) execute(CommandId(Command.newTab));
            return;
        }
        if (hit == saveHit)
        {
            if (pointer.action == PointerAction.press) execute(CommandId(Command.save));
            return;
        }
        if (hit == inspectorHit)
        {
            if (pointer.action == PointerAction.press) execute(CommandId(Command.inspector));
            return;
        }
        if (hit >= findHitBase && hit < findHitBase + 0x1_0000 && hit - findHitBase <= Command.max)
        {
            if (pointer.action == PointerAction.press && finder.open)
                execute(CommandId(cast(Command)(hit - findHitBase)));
            return;
        }
        if (hit >= findOptionHitBase && hit <= findOptionHitBase + FindOption.max)
        {
            if (pointer.action == PointerAction.press && finder.open)
                execute(CommandId(Command.findOption, cast(ubyte)(hit - findOptionHitBase)));
            return;
        }
        if (hit == findFieldHit || hit == findFieldHit + 1)
        {
            if (pointer.action == PointerAction.press && finder.open)
                finder.onReplacement = hit == findFieldHit + 1 && finder.replacing;
            return;
        }
        if (hit >= undoHitBase && hit < undoHitLimit)
        {
            // The listed revisions belong to the document they were drawn for.
            if (pointer.action == PointerAction.press && displayed !is null && displayed.document == document.id)
                travelTo(hit - undoHitBase);
            return;
        }
        if (hit == restoreHit)
        {
            if (pointer.action == PointerAction.press) execute(CommandId(Command.restoreSession));
            return;
        }
        if (displayed !is null && hit >= tabHitBase && hit - tabHitBase < displayed.tabs.length)
        {
            if (pointer.action == PointerAction.press)
                foreach (index, tab; tabs)
                    if (tab.id == displayed.tabs[hit - tabHitBase]) { activeTab = index; break; }
            return;
        }
        if (displayed is null) return;
        // The drawn rows answer only for the revision and wrap they were laid out at (EAP17).
        if (displayed.document != document.id || displayed.source != document.field.state.text
            || displayed.wrapCells != document.field.context.options.wrapCells)
        {
            selecting = false;
            return;
        }
        if (touch && pointer.action == PointerAction.press)
        {
            editorTouching = true;
            editorPanning = false;
            editorTouchPress = pointer;
            document.scroll.touch = true;
            document.scroll.motion.instant = false;
            document.scroll.beginDrag(pointer.pos.y / cast(double) ch, scrollSeconds());
            return;
        }
        placeCaretAt(point, pointer.mods.shift, pointer.action == PointerAction.press);
    }

    private void placeCaretAt(Point point, bool shift, bool press) @safe
    {
        // A press must land on a row; a drag beyond the rows follows the nearest one.
        CaretTarget at;
        if (!displayed.painted.caretAtPoint(document.field.context, document.field.state.text,
            displayed.frames, point, press, at))
            return;
        if (press)
        {
            drag.press(document.field.state, at, shift);
            keyboardAsked = false;
            selectingDocument = document.id;
        }
        drag.moveTo(document.field, at, MonoTime.currTime);
    }

    private void receivePaste(in PasteEvent chunk) @safe
    {
        if (chunk.request && !(chunk.request in clipboardReads))
        {
            if (collectingPaste && pasteRequest == chunk.request)
            {
                collectingPaste = false;
                pasteBytes.length = 0;
            }
            return;
        }
        if (!collectingPaste || chunk.request != pasteRequest)
        {
            if (collectingPaste && pasteRequest) clipboardReads.remove(pasteRequest);
            pasteBytes.length = 0;
            collectingPaste = true;
            pasteRequest = chunk.request;
            pasteOwner = chunk.request ? clipboardReads[chunk.request]
                : ClipboardRead(document.id,
                    commands.palette.active ? commands.palette.snapshot.ticket.value : 0,
                    pathDialog ? dialogEpoch : 0, 0,
                    !pathDialog && !commands.palette.active && finding ? 2 * finder.epoch + finder.onReplacement : 0);
        }
        if (!clipboardOwnerValid(pasteOwner))
        {
            if (pasteRequest) clipboardReads.remove(pasteRequest);
            collectingPaste = false;
            pasteBytes.length = 0;
            status = "Paste cancelled because its input target changed.";
            return;
        }
        pasteBytes ~= chunk.text[];
        if (!chunk.last) return;
        collectingPaste = false;
        scope (exit)
        {
            pasteBytes.length = 0;
            if (pasteRequest) clipboardReads.remove(pasteRequest);
        }
        if (pasteOwner.dialog) pathInput.paste(pasteBytes, pasteOwner.request, MonoTime.currTime);
        else if (pasteOwner.find)
            (pasteOwner.find & 1 ? finder.replacement : finder.query).paste(pasteBytes, pasteOwner.request, MonoTime.currTime);
        else if (pasteOwner.palette)
            apply(commands.paste(pasteBytes, pasteOwner.request, context, MonoTime.currTime));
        else
            foreach (tab; tabs) if (tab.id == pasteOwner.document)
            {
                tab.field.paste(pasteBytes, pasteOwner.request, MonoTime.currTime);
                tab.followCaret = true;
                break;
            }
    }

    private bool clipboardOwnerValid(in ClipboardRead owner) @safe
    {
        if (owner.dialog)
            return pathDialog && owner.dialog == dialogEpoch && owner.document == document.id
                && (!owner.request || owner.request == pathInput.state.record.pendingRequest);
        if (owner.find)
        {
            auto field = owner.find & 1 ? &finder.replacement : &finder.query;
            return finding && owner.find / 2 == finder.epoch && owner.document == document.id
                && (!owner.request || owner.request == field.state.record.pendingRequest);
        }
        if (owner.palette)
            return commands.palette.active && owner.palette == commands.palette.snapshot.ticket.value
                && (!owner.request || owner.request == commands.query.state.record.pendingRequest);
        if (!owner.request && (modal || commands.palette.active || document.id != owner.document)) return false;
        foreach (tab; tabs) if (tab.id == owner.document)
            return !owner.request || owner.request == tab.field.state.record.pendingRequest;
        return false;
    }

    private uint routeClipboard(H)(ref H host, ClipboardRead owner, uint request)
    {
        owner.request = request;
        if (!clipboardOwnerValid(owner)) return 0;
        uint[64] stale;
        size_t count;
        foreach (ticket, pending; clipboardReads)
            if (!clipboardOwnerValid(pending)) stale[count++] = ticket;
        foreach (ticket; stale[0 .. count]) clipboardReads.remove(ticket);
        if (clipboardReads.length == stale.length)
        {
            status = "The clipboard request could not be tracked; retry after pending reads finish.";
            return 0;
        }
        uint ticket;
        static if (__traits(compiles, host.allocateClipboardRequest()))
            ticket = host.allocateClipboardRequest();
        else if (nextClipboardRead != uint.max) ticket = ++nextClipboardRead;
        if (!ticket) { status = "Clipboard request identities are exhausted."; return 0; }
        clipboardReads[ticket] = owner;
        return ticket;
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

    /// The find bar holds the keyboard: open, with no dialog or palette over it.
    private bool finding() const scope @safe pure nothrow @nogc
        => finder.open && !modal && !commands.palette.active;

    CommandContext context() @safe => CommandContext(recoveryExit ? 0 : document.id,
        bindings, modal, dialog == Dialog.dirtyClose || dialog == Dialog.recoveryClose,
        // Find commands stay available from the palette over an open bar;
        // the bar takes keys only while it, not the palette, has focus.
        recovery !is null && recovery.offerCount != 0, finder.open && !modal);

    private void observeRecovery() @safe nothrow
    {
        if (recovery is null) return;
        recovery.observe(tabs, tabs.length ? tabs[activeTab].id : 0,
            choosingTheme ? themeBeforePreview : themeName, MonoTime.currTime, toSession(settings));
    }

    /// Admit bytes before replacing any active state; unsupported UTF-8 leaves every tab intact.
    bool openBytes(string name, string bytes) @safe
    {
        const decoded = decodeEnvelope(bytes);
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
        if (!choosingTheme && !choosingLanguage)
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
        if (!recoveryExit) ensureInitialized();
        if (!context.available(id, recoveryExit ? 0 : document.id)) return;
        if (!recoveryExit) applyEditing();
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
            if (dialog == Dialog.recoveryClose)
            {
                recoveryFailureShown = false;
                ++dialogEpoch;
                recovery.flush(now);
            }
            else if (dialog == Dialog.restoreOffer) acceptRestoreOffer();
            else if (replacement !is null) resolveOverwrite(true);
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
            if (recoveryExit)
            {
                recoveryExit = false;
                recovery.resume();
            }
            if (replacement !is null) resolveOverwrite(false);
            dialog = Dialog.none;
            closingDocument = 0;
            exiting = false;
            ++dialogEpoch;
            pathInput.run(EditCommand.of(EditKind.blur), now);
            break;
        case Command.closeTab: requestClose(false); break;
        case Command.restoreSession: showRestoreOffer(); break;
        case Command.discard:
            if (dialog == Dialog.recoveryClose)
            {
                if (recoveryFailureShown && recovery.error.length)
                {
                    skipRecoveryFlush = true;
                    quitRequested = true;
                }
            }
            else finishClose(closingDocument);
            break;
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
        case Command.presentation:
            if (id.argument <= PresentationToggle.max) settings.view.toggle(cast(PresentationToggle) id.argument);
            break;
        case Command.settings:
            settingsPane.fileLayer = "the session";
            // The pane keeps a pointer to `settings`, a field of this non-copyable
            // app that outlives the pane it also owns.
            (() @trusted => settingsPane.open(&settings, settings, settingsGeometry()))();
            break;
        case Command.find:
        case Command.replace:
            finder.show(id.operation == Command.replace, findSeed(), target);
            break;
        case Command.findNext:
        case Command.findPrevious:
            if (!finder.query.text.length) { finder.show(false, findSeed(), target); break; }
            // On the replacement field, Enter replaces and moves on.
            if (finder.open && finder.onReplacement && finder.replacing && id.operation == Command.findNext)
            {
                execute(CommandId(Command.replaceOne), now);
                break;
            }
            finder.refresh(document.field.state.text, document.id);
            if (!finder.pattern.valid) { status = finder.pattern.error; break; }
            const step = selectNextMatch(document.field.state, finder.pattern,
                id.operation == Command.findNext ? 1 : -1, now);
            status = step.error.length ? step.error : !step.found ? "No results."
                : step.wrapped ? "Search wrapped." : null;
            document.followCaret = true;
            break;
        case Command.closeFind: finder.close(); break;
        case Command.findOption:
            if (id.argument <= FindOption.max) finder.toggle(cast(FindOption) id.argument);
            break;
        case Command.findFocus:
            if (finder.replacing) finder.onReplacement = !finder.onReplacement;
            break;
        case Command.replaceOne:
        case Command.replaceAll:
            finder.refresh(document.field.state.text, document.id);
            if (!finder.pattern.valid) { status = finder.pattern.error; break; }
            const replaced = id.operation == Command.replaceAll
                ? replaceAll(document.field.state, finder.pattern, finder.replacement.text, SearchBudget.unbounded, now)
                : replaceCurrent(document.field.state, finder.pattern, finder.replacement.text, now);
            status = replaced.error.length ? replaced.error
                : text("Replaced ", replaced.replaced, replaced.replaced == 1 ? " match" : " matches",
                    replaced.skippedProtected ? text("; ", replaced.skippedProtected, " in protected text kept") : "",
                    replaced.truncated ? "; more remain" : "", ".");
            document.followCaret = true;
            break;
        case Command.selectMatches:
            finder.refresh(document.field.state.text, document.id);
            if (!finder.pattern.valid) { status = finder.pattern.error; break; }
            const selected = selectAllMatches(document.field.state, finder.pattern, SearchBudget.unbounded, now);
            status = selected.error.length ? selected.error
                : !selected.matches.length ? "No results." : null;
            if (selected.matches.length) finder.close(); // the selections are the document's to edit
            document.followCaret = true;
            break;
        case Command.indentation:
            if (id.argument <= IndentChoice.max) settings.editing.choose(cast(IndentChoice) id.argument);
            applyEditing();
            break;
        case Command.languages:
            endPicker(false);
            choosingLanguage = true;
            if (languageCatalog is null)
                languageCatalog = new LanguageCatalog(GrammarRegistry.fromEnvironment());
            installLanguages();
            commands.open(PaletteInvocation(document.id, document.id), context);
            commands.query.target = target;
            break;
        case Command.fonts:
        case Command.allFonts:
            endPicker(false);
            choosingFont = true;
            allFamilies = id.operation == Command.allFonts;
            if (fonts is null) fonts = new DocumentFontService;
            fonts.start();
            installFonts();
            commands.open(PaletteInvocation(document.id, document.id), context);
            commands.query.target = target;
            break;
        case Command.selectFont:
            if (id.argument == 0) settings.font.family = null;
            else if (id.argument <= fontNames.length) settings.font.family = fontNames[cast(size_t) id.argument - 1];
            break;
        case Command.selectLanguage:
            if (id.argument < languageNames.length)
                document.language = languageNames[cast(size_t) id.argument];
            break;
        case Command.themes:
            endPicker(false);
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
                    document.field.newlineEach((in Text current, size_t position)
                        => lineEndingText(enterEnding(current, position, predominant)), now);
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
            if (!context.available(effect.command, effect.invocation.target))
            {
                endPicker(false);
                status = "The command is no longer available in this context.";
                return;
            }
            const wasChoosing = choosingTheme || choosingLanguage || choosingFont;
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
        if (!recoveryExit) ensureInitialized();
        if (key.action == KeyAction.release) return;
        if (settingsOpen())
        {
            (() @trusted => cast(void) settingsPane.handleKey(key))();
            return;
        }
        if (pathDialog && pathInput.state.composition.active)
        {
            pathInput.key(key, now);
            return;
        }
        if (finding && finder.focused.state.composition.active)
        {
            finder.focused.key(key, now);
            return;
        }
        if (commands.palette.active)
        {
            apply(commands.key(key, context, now));
            previewPicker();
            return;
        }
        if (!recoveryExit) document.followCaret = true;
        const resolved = step(lantern, bindings, key, context);
        if (resolved.kind == StepKind.execute)
        {
            if (key.action == KeyAction.repeat && modal) return;
            execute(CommandId(resolved.cmd.cmd, resolved.cmd.arg), now);
        }
        else if (resolved.kind == StepKind.unbound)
        {
            if (pathDialog) pathInput.key(key, now);
            else if (finding) finder.focused.key(key, now);
            else if (!modal) document.field.key(key, now);
        }
    }

    /// The same event vocabulary reaches every rendering host.
    void handle(H)(ref H host, in Event event)
    {
        if (recoveryExit)
        {
            event.match!((in KeyEvent key) { handleKey(key); },
                (in PointerEvent pointer) { this.pointer(host, pointer); }, (in _) {});
            if (quitRequested) host.quit();
            return;
        }
        ensureInitialized();
        document.field.context.clipboardRead = canReadClipboard!H;
        document.field.context.clipboardWrite = __traits(compiles, host.clipboard(""));
        commands.query.context.clipboardRead = canReadClipboard!H;
        commands.query.context.clipboardWrite = __traits(compiles, host.clipboard(""));
        pathInput.context.clipboardRead = canReadClipboard!H;
        finder.query.context.clipboardRead = canReadClipboard!H;
        finder.query.context.clipboardWrite = __traits(compiles, host.clipboard(""));
        finder.replacement.context.clipboardRead = canReadClipboard!H;
        finder.replacement.context.clipboardWrite = __traits(compiles, host.clipboard(""));
        if (settingsOpen())
        {
            event.match!(
                (in KeyEvent key) { handleKey(key); },
                (in PasteEvent paste) { (() @trusted => cast(void) settingsPane.handlePaste(paste.text[]))(); },
                (in EndOfInput _) { closeRequested(host); },
                (in PointerEvent p) {
                    // The pane hits in cells; a window reports pixels.
                    int cw = 1, ch = 1;
                    static if (__traits(hasMember, H, "cellWidth"))
                        if (host.backend == Backend.gui) { cw = host.cellWidth; ch = host.cellHeight; }
                    PointerEvent cells = p;
                    cells.pos = Point(p.pos.x / (cw > 0 ? cw : 1), p.pos.y / (ch > 0 ? ch : 1));
                    (() @trusted => cast(void) settingsPane.handleOverlay(Event(cells), settingsGeometry()))();
                },
                (in _) { (() @trusted => cast(void) settingsPane.handleOverlay(event, settingsGeometry()))(); });
            if (quitRequested) host.quit();
            return;
        }
        event.match!(
            (in KeyEvent key) { handleKey(key); },
            (in PasteEvent paste) { receivePaste(paste); },
            (in PointerEvent pointer) { this.pointer(host, pointer); },
            (in CompositionEvent update) {
                withPreedit(host, update, (scope const(char)[] preedit) {
                    if (pathDialog) pathInput.compose(update, preedit, MonoTime.currTime);
                    else if (modal) return;
                    else if (commands.palette.active) commands.query.compose(update, preedit, MonoTime.currTime);
                    else if (finding) finder.focused.compose(update, preedit, MonoTime.currTime);
                    else document.field.compose(update, preedit, MonoTime.currTime);
                });
            },
            (in WheelEvent wheel) {
                if (commands.palette.active)
                {
                    paletteScroll.motion.instant = host.backend != Backend.gui;
                    paletteScroll.scroll(wheel, scrollSeconds());
                    return;
                }
                if (modal) return;
                document.followCaret = false;
                document.scroll.motion.instant = host.backend != Backend.gui;
                document.scroll.scroll(wheel, scrollSeconds());
            },
            (in EndOfInput _) { closeRequested(host); },
            (in _) {});
        forwardClipboard(document.field, host,
            (uint request) => routeClipboard(host, ClipboardRead(document: document.id), request));
        forwardClipboard(commands.query, host,
            (uint request) => commands.palette.active ? routeClipboard(host, ClipboardRead(document.id,
                commands.palette.snapshot.ticket.value), request) : 0u);
        forwardClipboard(pathInput, host,
            (uint request) => pathDialog ? routeClipboard(host, ClipboardRead(document.id, 0, dialogEpoch), request) : 0u);
        forwardClipboard(finder.query, host,
            (uint request) => finding && !finder.onReplacement
                ? routeClipboard(host, ClipboardRead(document.id, 0, 0, 0, 2 * finder.epoch), request) : 0u);
        forwardClipboard(finder.replacement, host,
            (uint request) => finding && finder.onReplacement
                ? routeClipboard(host, ClipboardRead(document.id, 0, 0, 0, 2 * finder.epoch + 1), request) : 0u);
        static if (__traits(compiles, host.takeClipboardError()))
            if (const error = host.takeClipboardError()) status = error;
        if (quitRequested) host.quit();
    }

    /// One tree renders the tab strip, active field, command frontends and inspector.
    WidgetTree view(H)(ref H host)
    {
        if (!recoveryExit) ensureInitialized();
        pollDocuments();
        if (languageCatalog !is null)
        {
            if (languageCatalog.poll() && choosingLanguage && commands.palette.active) installLanguages();
            if (languageCatalog.busy) host.wakeIn(8.msecs);
        }
        if (recovery !is null)
        {
            recovery.poll();
            if (recoveryExit && recovery.ready && recovery.durableGeneration
                && !recovery.pending && !recovery.error.length) quitRequested = true;
            const delay = recovery.nextPoll(MonoTime.currTime);
            if (delay != typeof(delay).max) host.wakeIn(delay);
        }
        if (quitRequested)
        {
            host.quit();
            return WidgetTree.init;
        }
        if (recoveryExit)
        {
            recoveryFailureShown = recovery.error.length != 0;
            Builder closing;
            uint[] rows;
            rows ~= closing.add(Widget(kind: WidgetKind.text, text: recovery.error.length
                ? "Recovery failed: " ~ recovery.error : "Finishing the recovery checkpoint…", slot: Slot.warn,
                wrap: TextWrap.greedy));
            uint[] actions;
            if (recovery.error.length)
            {
                actions ~= chip(closing, "Retry", dialogConfirmHit + 2 * dialogEpoch, false, ControlSize(rows: 3));
                actions ~= chip(closing, "Exit without recovery", dialogDiscardHit + dialogEpoch, false, ControlSize(rows: 3));
            }
            actions ~= chip(closing, "Esc: cancel exit", dialogCancelHit + 2 * dialogEpoch, false, ControlSize(rows: 3));
            rows ~= closing.add(Widget(kind: WidgetKind.row, children: actions));
            return closing.finish(closing.add(Widget(kind: WidgetKind.column, children: rows)));
        }
        lastSize = [host.size.width, host.size.height];
        if (settingsOpen()) return (() @trusted => settingsPane.buildView(settingsGeometry()))();
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
        // The document font reaches a host that can draw one (EAP16); the
        // interface font is the host's and does not change.
        static if (__traits(hasMember, H, "specimenFont"))
        {
            if (fonts is null) fonts = new DocumentFontService;
            if (settings.font.family.length) fonts.start();
        }
        if (fonts !is null)
        {
            const wasReady = fonts.familyNames(true).length != 0;
            SpecimenFontRequest request;
            // The family is resolved and loaded, which validates it and reports its
            // controls. Drawing the document in it needs a widget scope with its own
            // cell metrics (plan item 2), so the request is not handed to the host.
            cast(void) fonts.poll(settings.font, request);
            if (!wasReady && choosingFont && commands.palette.active && fonts.familyNames(true).length)
                installFonts();
            if (fonts.busy) host.wakeIn(16.msecs);
        }
        applyEditing();
        if (highlighting is null) highlighting = new HighlightSession;
        highlighting.request(document.field.state.text, document.language, document.id);
        highlighting.poll();
        previewPicker();
        if (highlighting.busy) host.wakeIn(8.msecs);
        if (shotPath.length && !highlighting.busy && !filesBusy
            && (languageCatalog is null || !languageCatalog.busy) && (fonts is null || !fonts.busy))
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
        // Text input (a soft keyboard) is asked for once, and again only when
        // the text is tapped: a keyboard the user dismissed stays down (EAP20).
        static if (__traits(hasMember, H, "textInput"))
            if (!keyboardAsked)
            {
                keyboardAsked = true;
                host.textInput(true);
            }
        const selectedTarget = host.backend == Backend.gui ? windowTarget : EditorTarget.terminal;
        if (selectedTarget != target) configure(selectedTarget);
        const recoveryWarning = recovery !is null
            && (recovery.error.length != 0 || recovery.overdue(MonoTime.currTime));
        version (Android) enum bool mobileUi = true;
        else enum bool mobileUi = false;
        const headerRows = mobileUi ? 3 : 1;
        const tabRows = mobileUi ? 2 : 1;
        enum size_t undoLimit = 6;
        const historyLength = document.field.state.history.length;
        const undoListed = inspector ? (historyLength < undoLimit ? historyLength : undoLimit) : 0;
        const extraRows = (inspector ? 3 + cast(int) undoListed : 0) + (status.length ? 1 : 0)
            + (document.durabilityWarning.length ? 1 : 0)
            + (recovery is null ? 0 : 1 + (recoveryWarning ? 1 : 0)
                + (recovery.notice.length ? 1 : 0) + (recovery.offerCount && !modal ? 3 : 0));
        Builder b;
        uint[] children;
        uint[] headerItems;
        headerItems ~= b.add(Widget(kind: WidgetKind.text,
            text: "Sparkles Editor", slot: Slot.docs, width: SizeSpec.grow()));
        if (mobileUi)
        {
            headerItems ~= chip(b, "Commands", paletteHit, commands.palette.active, ControlSize(rows: 3));
            headerItems ~= chip(b, "+ Tab", newTabHit, false, ControlSize(rows: 3));
            headerItems ~= chip(b, "Save", saveHit, false, ControlSize(rows: 3));
            headerItems ~= chip(b, "Inspect", inspectorHit, inspector, ControlSize(rows: 3));
        }
        else
        {
            headerItems ~= b.add(Widget(kind: WidgetKind.text, text: "Commands (Ctrl+Shift+P)",
                hitId: paletteHit, slot: commands.palette.active ? Slot.selection : Slot.docs,
                padding: Insets(0, 1, 0, 1)));
            headerItems ~= b.add(Widget(kind: WidgetKind.text, text: "+ Tab",
                hitId: newTabHit, slot: Slot.docs, padding: Insets(0, 1, 0, 1)));
            headerItems ~= b.add(Widget(kind: WidgetKind.text, text: "Save",
                hitId: saveHit, slot: Slot.docs, padding: Insets(0, 1, 0, 1)));
            headerItems ~= b.add(Widget(kind: WidgetKind.text, text: "Inspect (F12)",
                hitId: inspectorHit, slot: inspector ? Slot.selection : Slot.docs,
                padding: Insets(0, 1, 0, 1)));
        }
        children ~= b.add(Widget(kind: WidgetKind.row, children: headerItems, gap: 1,
            alignY: Alignment.center, height: SizeSpec.fixed(headerRows),
            padding: Insets(0, 1, 0, 1)));
        uint[] tabNodes;
        foreach (i, tab; tabs)
            tabNodes ~= b.add(Widget(kind: WidgetKind.text,
                text: tab.name ~ (tab.dirty ? " •" : ""),
                hitId: tabHitBase + i,
                slot: i == activeTab ? Slot.selection : Slot.muted,
                height: SizeSpec.fixed(tabRows),
                padding: Insets(0, 1, 0, 1), paintBackground: true));
        children ~= b.add(Widget(kind: WidgetKind.row, children: tabNodes, gap: mobileUi ? 1 : 0,
            alignY: Alignment.center, height: SizeSpec.fixed(tabRows)));
        if (modal)
        {
            children ~= b.add(Widget(kind: WidgetKind.text, text: replacement !is null
                ? "Replace existing file: " ~ replacement.path
                : dialog == Dialog.restoreOffer ? text("Restore ", recovery.offer(0).documentCount,
                    " tabs from the previous session?")
                : dialog == Dialog.dirtyClose ? "Close " ~ document.name ~ ": Save, Discard or Cancel?"
                : dialog == Dialog.openPath ? "Open file" : "Save as", slot: Slot.info,
                wrap: TextWrap.greedy));
            if (replacement !is null)
                children ~= b.add(Widget(kind: WidgetKind.text, text: replacementWarning,
                    wrap: TextWrap.greedy, slot: Slot.warn));
            if (pathDialog)
                children ~= editorView(b, pathInput.state, EditorViewOptions(visibleLines: 1, placeholder: "Path…",
                    hostCursor: true));
            uint[] actions;
            actions ~= chip(b, replacement !is null ? "Replace this time"
                : dialog == Dialog.restoreOffer ? "Restore tabs"
                : dialog == Dialog.dirtyClose ? "Save" : "Enter: confirm", dialogConfirmHit + 2 * dialogEpoch,
                false, ControlSize(rows: 3));
            if (dialog == Dialog.dirtyClose)
                actions ~= chip(b, "Discard", dialogDiscardHit + dialogEpoch, false, ControlSize(rows: 3));
            actions ~= chip(b, "Esc: cancel", dialogCancelHit + 2 * dialogEpoch, false, ControlSize(rows: 3));
            children ~= b.add(Widget(kind: WidgetKind.row, children: actions, height: SizeSpec.fixed(3)));
            children ~= b.add(Widget(kind: WidgetKind.text, height: SizeSpec.grow()));
        }
        else
        {
            int paletteHeight;
            if (commands.palette.active)
            {
                const int paletteRowHeight = mobileUi ? 2 : 1;
                const size_t maxPaletteRows = mobileUi ? 6 : 8;
                const chromeReserved = headerRows + tabRows + 5 + extraRows;
                const availRows = host.size.height > chromeReserved + paletteRowHeight
                    ? cast(size_t)(host.size.height - chromeReserved) / paletteRowHeight : 1;
                const rows = availRows < maxPaletteRows ? availRows : maxPaletteRows;
                const int availWidth = host.size.width > 4 ? host.size.width - 2 : host.size.width;
                const int paletteWidth = availWidth > 68 ? 68 : availWidth;
                paletteScroll.content = cast(long) commands.palette.rowCount * paletteRowHeight;
                paletteScroll.viewport = cast(long) rows * paletteRowHeight;
                paletteScroll.motion.instant = host.backend != Backend.gui;
                static if (__traits(hasMember, H, "frameSeconds"))
                    if (paletteScroll.animate(host.frameSeconds)) host.requestFrame();
                const sel = commands.palette.snapshot.selection;
                const rowCount = commands.palette.rowCount;
                if (sel != paletteLastSelection || rowCount != paletteLastRowCount)
                {
                    paletteLastSelection = sel;
                    paletteLastRowCount = rowCount;
                    const double selTop = cast(double) sel * paletteRowHeight;
                    const double selBottom = selTop + paletteRowHeight;
                    if (selTop < paletteScroll.motion.pos)
                        paletteScroll.motion.jumpTo(selTop, paletteScroll.limit);
                    else if (selBottom > paletteScroll.motion.pos + paletteScroll.viewport)
                        paletteScroll.motion.jumpTo(selBottom - paletteScroll.viewport, paletteScroll.limit);
                }
                const paletteView = viewCommandPalette(b, commands.palette, commands.query.state, context,
                    PaletteViewOptions(visibleRows: rows, rowHeight: paletteRowHeight,
                        closeHit: paletteCloseHit, compact: true, maxWidth: paletteWidth,
                        smoothScroll: true, hostCursor: true,
                        scrollWhole: paletteScroll.motion.whole,
                        scrollFrac: paletteScroll.motion.frac,
                        placeholder: choosingTheme ? "Search themes" : choosingLanguage ? "Search languages"
                            : choosingFont ? "Search font families" : "Search commands",
                        title: choosingTheme ? "Themes"
                            : choosingLanguage ? languageCatalog.busy ? "Listing languages…" : "Languages"
                            : choosingFont ? fonts.busy && !fontNames.length ? "Listing fonts…"
                                : allFamilies ? "All font families" : "Monospace fonts"
                            : "Commands"));
                paletteChoices = paletteView.choices;
                children ~= b.add(Widget(kind: WidgetKind.column, children: [paletteView.root],
                    width: SizeSpec.grow(), alignX: Alignment.center));
                const shownRowsCount = paletteView.choices.length < rows ? paletteView.choices.length : rows;
                const shownCount = shownRowsCount ? shownRowsCount : 1;
                paletteHeight = 2 + cast(int) shownCount * paletteRowHeight;
            }
            int findRows;
            if (finder.open)
            {
                finder.refresh(document.field.state.text, document.id);
                children ~= findBar(b);
                findRows = findBarRows(finder);
            }
            const reserved = headerRows + tabRows + 3 + extraRows + paletteHeight + findRows;
            const visible = host.size.height > reserved ? cast(size_t) host.size.height - reserved : 1;
            const count = document.field.state.text.lineCount;
            // Rows wrap at the field's width: the window less the root's padding
            // and the line-number gutter (EAP5). The caret is the host's cursor
            // (HST20) and takes no cell of its own.
            const digits = cast(size_t) lineNumberWidth(count);
            const gutterCells = settings.view.lineNumbers ? digits + 1 : 0;
            const width = host.size.width > 10 + gutterCells ? cast(size_t) host.size.width - 2 - gutterCells : 8;
            auto context = &document.field.context;
            context.options.wrapCells = width;
            context.viewportLines = visible;
            if (document.firstLine >= count) document.firstLine = count ? count - 1 : 0;
            const text = document.field.state.text;
            const totalRows = rowIndex(document).total;
            document.scroll.content = totalRows;
            document.scroll.viewport = cast(long) visible;
            document.scroll.motion.instant = host.backend != Backend.gui;
            if (document.followCaret)
            {
                const primary = document.field.state.selection.primary;
                scrollToCaret(*context, text, CaretTarget(primary.head, primary.affinity),
                    visible, document.firstLine, document.firstRow);
                document.syncedVisualRow = rowIndex(document).rowOf(document.firstLine, document.firstRow);
                document.scroll.motion.jumpTo(cast(double) document.syncedVisualRow, document.scroll.limit);
            }
            else
            {
                static if (__traits(hasMember, H, "frameSeconds"))
                    if (document.scroll.animate(host.frameSeconds)) host.requestFrame();
                const long targetRow = cast(long) document.scroll.motion.whole;
                const long delta = targetRow - document.syncedVisualRow;
                if (delta != 0)
                {
                    scrollRows(*context, text, delta, document.firstLine, document.firstRow);
                    document.syncedVisualRow = rowIndex(document).rowOf(document.firstLine, document.firstRow);
                    if (document.syncedVisualRow != targetRow)
                        document.scroll.motion.jumpTo(cast(double) document.syncedVisualRow, document.scroll.limit);
                }
            }
            // No empty rows below the end while rows above are hidden: when the
            // view grows (a keyboard or palette leaves), the top moves up to fill it.
            const overshoot = document.syncedVisualRow + cast(long) visible - totalRows;
            if (overshoot > 0 && document.syncedVisualRow > 0)
            {
                scrollRows(*context, text, -(overshoot < document.syncedVisualRow ? overshoot : document.syncedVisualRow),
                    document.firstLine, document.firstRow);
                document.syncedVisualRow = rowIndex(document).rowOf(document.firstLine, document.firstRow);
                document.scroll.motion.jumpTo(cast(double) document.syncedVisualRow, document.scroll.limit);
            }
            context.originLine = document.firstLine;
            context.originRow = document.firstRow;
            // One host cursor per frame: the document's only while it has the keyboard.
            const documentFocused = !finding && !commands.palette.active;
            const options = EditorViewOptions(firstLine: document.firstLine,
                visibleLines: visible, placeholder: "Start typing…", hostCursor: true,
                caretVisible: documentFocused);
            const syntax = highlighting.snapshot(text, document.language, document.id);
            uint field;
            shownRows = PaintedRows.of(text, width);
            if (text.length || document.field.state.composition.active)
            {
                uint[] rows;
                const size_t renderLimit = visible + 1;
                const selection = document.field.state.selection;
                const caretLine = text.lineOf(selection.primary.head);
                const composing = document.field.state.composition.active;
                const globalMarks = documentMarks();
                auto channels = [GutterChannel(id: "lines", width: cast(int) digits)];
                for (size_t line = document.firstLine; line < count && rows.length < renderLimit; ++line)
                {
                    const start = text.lineStart(line);
                    const end = text.lineEnd(line);
                    const plain = syntax !is null && syntax.spans.length
                        ? highlightedEditorLine(document.field.state, line,
                            syntaxWindow(syntax.source, syntax.spans, start, end, syntaxTheme, theme.pageFg), options)
                        : editorLineSpans(document.field.state, line, options);
                    auto marks = appender(globalMarks.dup);
                    findMarks(start, end, marks);
                    if (settings.view.trailingWhitespace)
                        trailingWhitespaceMarks(marks, document.field.state, line);
                    const logical = marks[].length ? markSpans(plain, marks[]) : plain;
                    const layout = context.paragraph(text, line);
                    const current = settings.view.currentLine && line == caretLine && !composing
                        && selection.ranges.length == 1 && selection.primary.empty;
                    const fromRow = line == document.firstLine ? document.firstRow : 0;
                    foreach (row; visualRows(logical, layout, document.field.state, fromRow, renderLimit - rows.length))
                    {
                        if (line == document.firstLine && row.row < document.firstRow) continue;
                        if (rows.length == renderLimit) break;
                        if (settings.view.indentGuides) drawIndentGuides(row, layout, settings.editing.indentWidth);
                        const node = b.add(Widget(kind: WidgetKind.rich, width: SizeSpec.grow(),
                            height: SizeSpec.fixed(1), spans: row.spans, wrap: TextWrap.none,
                            caretColumn: documentFocused ? row.caretColumn : -1,
                            slot: current ? Slot.surfaceRaised : Slot.inherit,
                            paintBackground: current));
                        shownRows.add(node, line, row);
                        if (settings.view.lineNumbers)
                        {
                            auto cell = new GutterCell[1];
                            cell[0] = row.row == 0
                                ? lineNumberCell(line, cast(int) digits,
                                    line == caretLine ? Slot.textPrimary : Slot.gutter)
                                : blankCell(cast(int) digits);
                            rows ~= withGutterCells(b, channels, cell, node);
                        }
                        else rows ~= node;
                    }
                }
                field = b.add(Widget(kind: WidgetKind.column, children: rows, width: SizeSpec.grow(),
                    height: SizeSpec.fixed(cast(int) visible), clipY: true,
                    childOffsetFracY: document.followCaret ? 0.0f : document.scroll.motion.frac));
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
                    document.field.state.composition.active, "  language ", document.language, "  highlighting ",
                    highlighting.busy ? "pending" : highlighting.error.length ? highlighting.error : "ready")));
        if (inspector)
            children ~= b.add(Widget(kind: WidgetKind.text, slot: Slot.info,
                text: host.backend == Backend.gui
                    ? "Font: " ~ (fonts is null ? "Default document font" : fonts.state)
                    : "Font: a terminal draws with its own font; the document font applies in a window"));
        if (inspector) children ~= undoRows(b, undoLimit);
        if (status.length) children ~= b.add(Widget(kind: WidgetKind.text, text: status, slot: Slot.warn));
        if (document.durabilityWarning.length)
            children ~= b.add(Widget(kind: WidgetKind.text, text: "Durability warning: " ~ document.durabilityWarning, slot: Slot.warn));
        if (recovery !is null)
        {
            observeRecovery();
            const delay = recovery.nextPoll(MonoTime.currTime);
            if (delay != typeof(delay).max) host.wakeIn(delay);
            children ~= b.add(Widget(kind: WidgetKind.text, slot: Slot.muted,
                text: text("Recovery revision ", recovery.durableRevision, " / ", recovery.currentRevision)));
            if (recoveryWarning)
                children ~= b.add(Widget(kind: WidgetKind.text, slot: Slot.warn,
                    text: "Recovery warning: " ~ (recovery.error.length ? recovery.error : "checkpoint exceeds one second")));
            if (recovery.notice.length)
                children ~= b.add(Widget(kind: WidgetKind.text, slot: Slot.warn, text: "Recovery notice: " ~ recovery.notice));
            if (recovery.offerCount && !modal)
                children ~= chip(b, text("Previous session available (", recovery.offerCount,
                    ") • F4 R: restore"), restoreHit, false, ControlSize(rows: 3));
        }
        children ~= b.add(Widget(kind: WidgetKind.text, text: statusPosition() ~ "  •  UTF-8  •  "
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

/// A displayed source ledger cannot move the caret after its document revision changes.
@("editor.app.pointerRejectsChangedRevision")
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
    Point point;
    bool found;
    foreach (i, node; frame.tree.nodes)
        if (node.kind == WidgetKind.rich && node.spans.length && node.spans[0].text == "abc")
        {
            const origin = frame.frames[i].rect.origin;
            point = Point(origin.x + 1, origin.y);
            found = true;
        }
    assert(found);
    app.document.field.insert("X");
    app.handle(host, Event(PointerEvent(PointerAction.press, PointerButton.left, point)));
    assert(app.document.field.state.selection.primary.head == 4);
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    app.handle(host, Event(PointerEvent(PointerAction.press, PointerButton.left, point)));
    assert(app.document.field.state.selection.primary.head == 1);
}

/// A long line draws as wrapped rows; a click on a later row and Up/Down follow those rows (EAP17).
@("editor.app.wrappedRowsShareLayout")
@safe unittest
{
    import sparkles.input : Point, PointerAction, PointerButton, PointerEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.geometry : Size;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui.editor.command : EditCommand;
    EditorApp app;
    // At 22 columns, rows wrap at 18 cells (the padding and the two-cell line-number
    // gutter aside; the caret is the host's): "alpha beta gamma " and "delta epsilon".
    app.document.field.setText("alpha beta gamma delta epsilon");
    app.document.field.run(EditCommand.setRange(0, 0));
    RecordingHost host;
    host.size = Size(22, 24);
    FrameSnapshot frame;
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    assert(app.displayed.rows.length == 2 && app.displayed.wrapCells == 18);
    const second = frame.frames[app.displayed.rows[1].node].rect.origin;
    app.handle(host, Event(PointerEvent(PointerAction.press, PointerButton.left, Point(second.x + 2, second.y))));
    assert(app.document.field.state.selection.primary.head == 19, "column 2 of the second row");
    app.document.field.run(EditCommand.line(-1));
    assert(app.document.field.state.selection.primary.head == 2, "Up keeps the column on the first row");
}

/// RTL text draws in visual order; a click resolves through the same layout (EAP17, EAP18).
@("editor.app.rtlRowHits")
@safe unittest
{
    import sparkles.input : Point, PointerAction, PointerButton, PointerEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui.editor.command : EditCommand;
    EditorApp app;
    app.document.field.setText("ab אב");
    app.document.field.run(EditCommand.setRange(0, 0));
    RecordingHost host;
    FrameSnapshot frame;
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    assert(app.displayed.rows.length == 1);
    const node = app.displayed.rows[0].node;
    string drawn;
    foreach (span; frame.tree.nodes[node].spans) drawn ~= span.text;
    assert(drawn == "ab בא", drawn);
    // Drawn cell 4 is Alef: its left edge, between Bet and Alef. The caret takes no cell.
    const origin = frame.frames[node].rect.origin;
    app.handle(host, Event(PointerEvent(PointerAction.press, PointerButton.left, Point(origin.x + 4, origin.y))));
    assert(app.document.field.state.selection.primary.head == 5);
    // Visual Right from there crosses Alef, logically backwards to byte 3.
    app.document.field.run(EditCommand.grapheme(1));
    assert(app.document.field.state.selection.primary.head == 3);
}

/// The host learns the caret's drawn cell: after the bidi stop, and at a preedit's cursor (EAP20).
@("editor.app.textInputAreaFollowsDrawnCaret")
@safe unittest
{
    import sparkles.input : CompositionEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.editor.selection : EditRange, SelectionSet;
    import sparkles.ui.style : defaultTwoslashPalette;
    EditorApp app;
    app.document.field.setText("ab אב");
    app.document.field.state.selection = SelectionSet.single(EditRange(3, 3, Affinity.after));
    RecordingHost host;
    FrameSnapshot frame;
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    const node = app.displayed.rows[0].node;
    const origin = frame.frames[node].rect.origin;
    // Drawn `ab בא`: the host's cursor at cell 5, right of Alef.
    assert(host.textInputAreas.length && host.textInputAreas[$ - 1] == [origin.x + 5, origin.y, 1, 1]);

    // A preedit `にほ` at byte 0 with its cursor after `に`: two cells in.
    app.document.field.state.selection = SelectionSet.caret(0);
    app.document.field.compose(CompositionEvent.init, "にほ");
    app.document.field.state.composition.cursor = 3;
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    const row = frame.frames[app.displayed.rows[0].node].rect.origin;
    assert(host.textInputAreas[$ - 1] == [row.x + 2, row.y, 1, 1], "after に");
}

/// Moving the caret moves no character: every frame draws the same text, and
/// only the host's cursor (HST20) changes column (EAP17).
@("editor.app.caretMovesNoCharacter")
@safe unittest
{
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.editor.command : EditCommand;
    import sparkles.ui.style : defaultTwoslashPalette;
    EditorApp app;
    app.document.field.setText("abc אב\nxyz");
    app.document.field.run(EditCommand.setRange(0, 0));
    RecordingHost host;
    FrameSnapshot frame;
    string first;
    int[] columns;
    foreach (step; 0 .. 7)
    {
        presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
        app.paint(host, frame.tree, frame.frames);
        string drawn;
        foreach (shown; app.displayed.rows)
        {
            foreach (span; frame.tree.nodes[shown.node].spans) drawn ~= span.text;
            drawn ~= "\n";
            if (shown.caretColumn >= 0) columns ~= shown.caretColumn;
        }
        if (step == 0) first = drawn;
        assert(drawn == first, "the caret moved a character: " ~ drawn);
        app.document.field.run(EditCommand.grapheme(1));
    }
    // Visual Right through `abc אב`: a b c, the space, then the RTL pair
    // from its left, then on to the next line.
    assert(columns == [0, 1, 2, 3, 4, 5, 6], "the cursor walks the cells");
}

/// The pane draws line numbers, the current line, guides, brackets and trailing
/// whitespace; each switch hides its part and moves no text (EAP5).
@("editor.app.codePresentation")
@safe unittest
{
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.editor.command : EditCommand;
    import sparkles.ui.style : defaultTwoslashPalette;
    import std.algorithm : canFind;
    EditorApp app;
    app.document.field.setText("f(a) \n    g();\nh");
    app.document.field.run(EditCommand.setRange(1, 1)); // at `(`
    RecordingHost host;
    FrameSnapshot frame;
    string[] drawn;
    Slot[][] slots;
    void present()
    {
        presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
        app.paint(host, frame.tree, frame.frames);
        drawn = null;
        slots = null;
        foreach (shown; app.displayed.rows)
        {
            string row;
            Slot[] rowSlots;
            foreach (span; frame.tree.nodes[shown.node].spans)
            {
                row ~= span.text;
                rowSlots ~= span.slot;
            }
            drawn ~= row;
            slots ~= rowSlots;
        }
    }
    present();
    assert(drawn == ["f(a) ", "│   g();", "h"], drawn[0]);
    assert(slots[0].canFind(Slot.highlight) && slots[0].canFind(Slot.diffRemoved));
    const current = app.displayed.rows[0].node;
    assert(frame.tree.nodes[current].paintBackground && frame.tree.nodes[current].slot == Slot.surfaceRaised);
    bool numbered(string label)
    {
        foreach (node; frame.tree.nodes)
            if (node.kind == WidgetKind.text && node.text == label) return true;
        return false;
    }
    assert(numbered("1") && numbered("2") && numbered("3"));
    assert(app.statusPosition() == "Ln 1, Col 2  •  Plain text");
    const x = frame.frames[current].rect.origin.x;
    foreach (which; [PresentationToggle.lineNumbers, PresentationToggle.currentLine,
        PresentationToggle.indentGuides, PresentationToggle.bracketMatching,
        PresentationToggle.trailingWhitespace])
        app.execute(CommandId(Command.presentation, which));
    present();
    assert(drawn == ["f(a) ", "    g();", "h"]);
    foreach (row; slots)
        assert(!row.canFind(Slot.highlight) && !row.canFind(Slot.diffRemoved));
    assert(!numbered("1") && !frame.tree.nodes[app.displayed.rows[0].node].paintBackground);
    assert(frame.frames[app.displayed.rows[0].node].rect.origin.x == x - 2, "the gutter's two cells are gone");
}

/// The inspector lists the undo tree, a branch point included, and a press on
/// an abandoned revision brings its text back (EAP6).
@("editor.app.undoInspector")
@safe unittest
{
    import core.time : seconds;
    import sparkles.input : Point, PointerAction, PointerButton, PointerEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.editor.command : EditCommand;
    import sparkles.ui.style : defaultTwoslashPalette;
    EditorApp app;
    auto at = MonoTime.currTime;
    app.document.field.insert("abc", false, at);
    app.document.field.run(EditCommand.of(EditKind.undo), at + 2.seconds);
    app.document.field.insert("xy", false, at + 4.seconds);
    assert(app.document.field.text == "xy");
    app.execute(CommandId(Command.inspector));
    RecordingHost host;
    FrameSnapshot frame;
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    string[] listed;
    size_t abandoned = size_t.max;
    foreach (i, node; frame.tree.nodes)
        if (node.hitId >= EditorApp.undoHitBase && node.hitId < EditorApp.undoHitLimit)
        {
            listed ~= node.text.idup;
            if (node.hitId == EditorApp.undoHitBase + 1) abandoned = i;
        }
    assert(listed == ["○ root  0 B  ⑂ 2 branches", "○ #1 from root  3 B", "● #2 from root  2 B"], listed[0]);
    const origin = frame.frames[abandoned].rect.origin;
    app.handle(host, Event(PointerEvent(PointerAction.press, PointerButton.left, Point(origin.x, origin.y))));
    assert(app.document.field.text == "abc", "the abandoned branch is back");
    assert(app.document.field.state.history.currentIndex == 1);
}

/// The app's indentation reaches the editor: Tab indents with spaces, Enter
/// keeps the line's indent, the language's comment toggles, and a setting
/// change applies to the next keystroke (EAP7).
@("editor.app.indentationAndComments")
@safe unittest
{
    import sparkles.ui.editor.command : EditCommand;
    EditorApp app;
    app.document.field.setText("x");
    app.document.field.run(EditCommand.setRange(0, 0));
    app.document.language = "d";
    void act(EditorAction action) { app.execute(CommandId(Command.edit, action)); }
    act(EditorAction.tab);
    assert(app.document.field.text == "    x");
    app.document.field.run(EditCommand.setRange(5, 5));
    act(EditorAction.newline);
    assert(app.document.field.text == "    x\n    ", "Enter keeps the indent");
    app.document.field.insert("y");
    act(EditorAction.toggleLineComment);
    assert(app.document.field.text == "    x\n    // y");
    act(EditorAction.toggleLineComment);
    assert(app.document.field.text == "    x\n    y");
    app.execute(CommandId(Command.indentation, IndentChoice.tabs));
    app.document.field.run(EditCommand.setRange(0, 0));
    act(EditorAction.tab);
    assert(app.document.field.text == "\t    x\n    y");
    app.document.language = "markdown";
    act(EditorAction.toggleLineComment);
    assert(app.document.field.text == "\t    x\n    y", "no comment syntax, no change");
}

/// The find bar takes the keyboard, paints and steps through matches, replaces
/// in one undo step, reports a bad pattern without editing, and gives the
/// keyboard back on Escape (EAP5, EAP7).
@("editor.app.findAndReplace")
@safe unittest
{
    import sparkles.input : charEvent, Key, keyEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.editor.command : EditCommand, EditKind;
    import sparkles.ui.style : defaultTwoslashPalette;
    import std.algorithm : canFind;
    EditorApp app;
    RecordingHost host;
    FrameSnapshot frame;
    app.document.field.setText("cat cot\ncat");
    app.document.field.run(EditCommand.setRange(0, 0));
    void type(string s) { foreach (dchar c; s) app.handle(host, charEvent(c)); }
    void present()
    {
        presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
        app.paint(host, frame.tree, frame.frames);
    }
    app.execute(CommandId(Command.replace));
    type("cat");
    assert(app.finder.query.text == "cat" && app.document.field.text == "cat cot\ncat", "keys reach the bar");
    present();
    size_t painted;
    foreach (shown; app.displayed.rows)
        foreach (span; frame.tree.nodes[shown.node].spans)
            painted += span.slot == Slot.highlight;
    assert(painted == 2, "both matches are painted");
    app.handle(host, keyEvent(Key.enter));
    auto primary = app.document.field.state.selection.primary;
    assert(primary.start == 0 && primary.end == 3);
    app.handle(host, keyEvent(Key.enter));
    primary = app.document.field.state.selection.primary;
    assert(primary.start == 8 && primary.end == 11, "Enter steps to the next match");
    present();
    bool shown(string label)
    {
        foreach (node; frame.tree.nodes) if (node.text == label) return true;
        return false;
    }
    assert(shown("2 of 2"));
    app.handle(host, keyEvent(Key.tab));
    type("dog");
    assert(app.finder.replacement.text == "dog");
    app.execute(CommandId(Command.replaceAll));
    assert(app.document.field.text == "dog cot\ndog" && app.status == "Replaced 2 matches.");
    app.document.field.run(EditCommand.of(EditKind.undo));
    assert(app.document.field.text == "cat cot\ncat", "one undo step restores both");
    app.execute(CommandId(Command.findOption, FindOption.regex));
    app.finder.query.setText("c(");
    app.execute(CommandId(Command.replaceAll));
    assert(app.document.field.text == "cat cot\ncat" && app.status.length, "a bad pattern edits nothing");
    app.handle(host, keyEvent(Key.escape));
    assert(!app.finder.open);
    type("!");
    assert(app.document.field.text.canFind("!"), "the document has the keyboard again");
}

/// The palette's query and the path field draw no caret glyph: the host's
/// cursor stands in the focused field alone, so no text moves (HST20).
@("editor.app.fieldsUseTheHostCursor")
@safe unittest
{
    import sparkles.input : charEvent, Key, keyEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.style : defaultTwoslashPalette;
    import std.algorithm : canFind;
    EditorApp app;
    RecordingHost host;
    FrameSnapshot frame;
    int[] cursors()
    {
        presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
        int[] result;
        foreach (node; frame.tree.nodes)
        {
            foreach (span; node.spans) assert(!span.text.canFind("▏"), "a caret glyph moved text");
            if (node.caretColumn >= 0) result ~= node.caretColumn;
        }
        return result;
    }
    app.execute(CommandId(Command.palette));
    assert(cursors() == [0], "the empty query's cursor, and not the document's");
    foreach (dchar c; "sav") app.handle(host, charEvent(c));
    assert(cursors() == [3]);
    app.handle(host, keyEvent(Key.escape));
    app.execute(CommandId(Command.open));
    foreach (dchar c; "/tmp/x") app.handle(host, charEvent(c));
    assert(cursors() == [6], "the path field has the only cursor");
}

/// The font picker lists the default face and the discovered monospace
/// families, and choosing one sets the document font, not the interface's (EAP16).
@("editor.app.fontPicker")
@safe unittest
{
    import core.time : seconds;
    import sparkles.input : Key, keyEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.test_runner.skip : skipTest;
    auto app = new EditorApp;
    scope (exit) destroy(*app);
    RecordingHost host;
    FrameSnapshot frame;
    app.execute(CommandId(Command.fonts));
    assert(app.commands.palette.active && app.commands.palette.rowCount == 1, "the default face first");
    const deadline = MonoTime.currTime + 20.seconds;
    while (app.commands.palette.rowCount == 1 && MonoTime.currTime < deadline)
        presentApp(*app, host, AppTheme(defaultTwoslashPalette()), frame);
    if (app.commands.palette.rowCount == 1) skipTest("no monospace font family is installed here");
    app.handle(host, keyEvent(Key.down));
    app.handle(host, keyEvent(Key.enter));
    assert(!app.commands.palette.active && app.settings.font.family.length, "a family was chosen");
    app.execute(CommandId(Command.fonts));
    app.handle(host, keyEvent(Key.enter));
    assert(!app.settings.font.family.length, "the first row restores the default face");
}

/// Review repairs: "Replace this match" runs from the palette over an open
/// bar, and a dirty close while the settings pane is open shows its decision.
@("editor.app.reviewRepairs")
@safe unittest
{
    import sparkles.input : EndOfInput, Event;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.editor.command : EditCommand;
    import sparkles.ui.style : defaultTwoslashPalette;
    auto app = new EditorApp;
    scope (exit) destroy(*app);
    RecordingHost host;
    app.document.field.setText("cat cat");
    app.document.field.run(EditCommand.setRange(0, 3));
    app.execute(CommandId(Command.replace));
    app.finder.replacement.setText("dog");
    app.execute(CommandId(Command.palette));
    assert(app.context.available(CommandId(Command.replaceOne), app.document.id));
    app.execute(CommandId(Command.replaceOne));
    assert(app.document.field.text == "dog cat");

    app.execute(CommandId(Command.closeFind));
    app.execute(CommandId(Command.settings));
    assert(app.settingsPane.active);
    app.handle(host, Event(EndOfInput.init));
    FrameSnapshot frame;
    presentApp(*app, host, AppTheme(defaultTwoslashPalette()), frame);
    assert(!app.settingsPane.active && app.modal, "the dirty-close decision is shown");
}

/// When the view grows (a soft keyboard leaves), rows hidden above move back
/// in rather than leave empty rows below the end (found on a phone).
@("editor.app.growingViewFillsFromAbove")
@safe unittest
{
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.editor.command : EditCommand;
    import sparkles.ui.style : defaultTwoslashPalette;
    auto app = new EditorApp;
    scope (exit) destroy(*app);
    app.document.field.setText("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");
    app.document.field.run(EditCommand.setRange(app.document.field.state.text.length,
        app.document.field.state.text.length));
    RecordingHost host;
    host.size.height = 9; // three document rows
    FrameSnapshot frame;
    presentApp(*app, host, AppTheme(defaultTwoslashPalette()), frame);
    assert(app.document.firstLine > 0, "the caret's line scrolled into view");
    host.size.height = 40;
    presentApp(*app, host, AppTheme(defaultTwoslashPalette()), frame);
    assert(app.document.firstLine == 0, "the grown view shows the whole document");
}

/// The settings pane is generated from the settings subject, edits them live
/// within their bounds, and gives the keyboard back when it closes (EAP15).
@("editor.app.generatedSettings")
@safe unittest
{
    import sparkles.input : charEvent, Key, keyEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.style : defaultTwoslashPalette;
    EditorApp app;
    RecordingHost host;
    FrameSnapshot frame;
    bool drawn(string label)
    {
        presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
        foreach (node; frame.tree.nodes)
        {
            if (node.text == label) return true;
            foreach (span; node.spans) if (span.text == label) return true;
        }
        return false;
    }
    app.execute(CommandId(Command.settings));
    assert(app.settingsPane.active);
    assert(drawn("View") && drawn("Editing"), "the subject's sections are the pane's rows");
    // Open the View section and toggle its first row: the running settings change at once.
    app.handle(host, keyEvent(Key.right));
    app.handle(host, keyEvent(Key.down));
    assert(drawn("Line numbers"));
    app.handle(host, keyEvent(Key.enter));
    assert(!app.settings.view.lineNumbers, "the pane edits the live subject");
    app.handle(host, keyEvent(Key.escape));
    app.handle(host, keyEvent(Key.escape));
    assert(!app.settingsPane.active);
    app.handle(host, charEvent('x'));
    assert(app.document.field.text == "x", "the document has the keyboard again");
}

/// A displayed tab names its document even if an earlier tab closes before repaint.
@("editor.app.pointerRetainsTabIdentity")
@safe unittest
{
    import sparkles.input : Point, PointerAction, PointerButton, PointerEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.style : defaultTwoslashPalette;
    EditorApp app;
    assert(app.openBytes("bravo", "B"));
    const bravo = app.document.id;
    assert(app.openBytes("charlie", "C"));
    RecordingHost host;
    FrameSnapshot frame;
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    Point point;
    bool found;
    foreach (i, node; frame.tree.nodes)
        if (node.text == "bravo")
        {
            const origin = frame.frames[i].rect.origin;
            point = Point(origin.x + 1, origin.y);
            found = true;
        }
    assert(found);
    app.execute(CommandId(Command.previousTab));
    app.execute(CommandId(Command.previousTab));
    app.execute(CommandId(Command.closeTab));
    app.execute(CommandId(Command.nextTab));
    assert(app.document.id != bravo);
    app.handle(host, Event(PointerEvent(PointerAction.press, PointerButton.left, point)));
    assert(app.document.id == bravo && app.document.field.text == "B");
}

/// An old document frame cannot place a caret inside a newly opened path input.
@("editor.app.pointerCannotCrossIntoNewDialog")
@safe unittest
{
    import sparkles.input : Key, Point, PointerAction, PointerButton, PointerEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : FrameSnapshot, presentApp;
    import sparkles.ui.style : defaultTwoslashPalette;
    EditorApp app;
    app.document.field.setText("abc");
    RecordingHost host;
    FrameSnapshot frame;
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    Point point;
    bool found;
    foreach (i, node; frame.tree.nodes)
        if (node.kind == WidgetKind.rich && node.spans.length && node.spans[0].text == "abc")
        {
            const origin = frame.frames[i].rect.origin;
            point = Point(origin.x + 1, origin.y);
            found = true;
        }
    assert(found);
    app.execute(CommandId(Command.saveAs));
    foreach (c; "abc") app.handleKey(KeyEvent(Key.char_, c));
    app.handle(host, Event(PointerEvent(PointerAction.press, PointerButton.left, point)));
    app.handleKey(KeyEvent(Key.char_, 'd'));
    auto tree = app.view(host);
    bool unchangedCaret;
    foreach (node; tree.nodes)
        foreach (span; node.spans) unchangedCaret |= span.text == "abcd";
    assert(unchangedCaret && app.document.field.text == "abc");
    presentApp(app, host, AppTheme(defaultTwoslashPalette()), frame);
    app.paint(host, frame.tree, frame.frames);
    found = false;
    foreach (i, node; frame.tree.nodes)
        if (node.kind == WidgetKind.rich && node.spans.length && node.spans[0].text == "abcd")
        {
            const origin = frame.frames[i].rect.origin;
            point = Point(origin.x + 1, origin.y);
            found = true;
        }
    assert(found);
    app.handleKey(KeyEvent(Key.char_, 'e'));
    app.handle(host, Event(PointerEvent(PointerAction.press, PointerButton.left, point)));
    app.handleKey(KeyEvent(Key.char_, 'f'));
    tree = app.view(host);
    unchangedCaret = false;
    foreach (node; tree.nodes)
        foreach (span; node.spans) unchangedCaret |= span.text == "abcdef";
    assert(unchangedCaret);
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

/// A global theme choice survives tab changes and returns to the command catalog.
@("editor.app.globalThemeAcceptAcrossTabs")
@safe unittest
{
    import sparkles.input : Key;
    EditorApp app;
    assert(app.useTheme("github-dark"));
    app.execute(CommandId(Command.themes));
    app.commands.insert("github-light", app.context);
    app.previewPicker();
    app.execute(CommandId(Command.newTab));
    app.handleKey(KeyEvent(Key.enter));
    assert(app.themeName == "github-light" && !app.commands.palette.active);
    app.execute(CommandId(Command.palette));
    app.commands.insert("Toggle inspector", app.context);
    app.handleKey(KeyEvent(Key.enter));
    assert(app.inspector && app.themeName == "github-light");
}

/// Save As cannot migrate from the palette's captured tab to a newly active tab.
@("editor.app.paletteSaveRetainsDocumentContext")
@safe unittest
{
    import sparkles.input : Key;
    EditorApp app;
    app.document.field.insert("original");
    app.execute(CommandId(Command.palette));
    app.commands.insert("Save as", app.context);
    app.execute(CommandId(Command.newTab));
    app.handleKey(KeyEvent(Key.enter));
    assert(app.commands.palette.active && !app.pathDialog);
    assert(app.document.field.empty && app.status.length);
    app.handleKey(KeyEvent(Key.escape));
    app.execute(CommandId(Command.previousTab));
    assert(app.document.field.text == "original");
}

/// Language selection changes highlighting policy without changing document bytes or dirty state.
@("editor.app.languagePickerAcceptAndCancel")
@safe unittest
{
    import sparkles.input : Key;
    EditorApp app;
    assert(app.openBytes("sample.d", "int value = 1;\r\n"));
    assert(app.document.language == "d");
    app.handleKey(KeyEvent(Key.f4));
    app.handleKey(KeyEvent(Key.char_, 'l'));
    assert(app.commands.palette.active);
    app.commands.insert("Plain text", app.context);
    app.handleKey(KeyEvent(Key.escape));
    assert(app.document.language == "d");
    app.execute(CommandId(Command.languages));
    app.commands.insert("Plain text", app.context);
    app.handleKey(KeyEvent(Key.enter));
    assert(app.document.language == "text" && !app.commands.palette.active);
    assert(app.document.encodedBytes == "int value = 1;\r\n" && !app.document.dirty);
    app.execute(CommandId(Command.newTab));
    app.execute(CommandId(Command.previousTab));
    assert(app.document.language == "text");
}

/// Background registry discovery preserves an already typed query before selection.
@("editor.app.languageDiscoveryPreservesQuery")
@safe unittest
{
    import core.thread : Thread;
    import core.time : seconds;
    import std.process : environment;
    import std.file : exists;
    import sparkles.input : Key;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui.geometry : Size;
    import sparkles.test_runner.skip : skipTest;
    const bundle = environment.get("SPARKLES_TS_GRAMMAR_PATH", "");
    if (!bundle.length) skipTest("SPARKLES_TS_GRAMMAR_PATH is unset; enter the development shell.");
    foreach (root; GrammarRegistry.fromSearchPath(bundle).dirs) assert(root.exists);
    EditorApp app;
    assert(app.openBytes("data.unknown", "{\"value\": 1}\n"));
    app.execute(CommandId(Command.languages));
    app.commands.insert("json", app.context);
    RecordingHost host;
    host.size = Size(80, 28);
    const deadline = MonoTime.currTime + 3.seconds;
    while (!app.commands.palette.rowCount && MonoTime.currTime < deadline)
    {
        cast(void) app.view(host);
        (() @trusted => Thread.yield())();
    }
    assert(app.commands.query.text == "json" && app.commands.palette.rowCount);
    assert(app.commands.palette.row(0).label == "json");
    app.handleKey(KeyEvent(Key.enter));
    assert(app.document.language == "json" && !app.document.dirty);
    assert(app.document.field.text == "{\"value\": 1}\n");
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
        // Heap-owned: two apps on one test stack exceed its watermark.
        auto app = new EditorApp;
        scope (exit) destroy(*app);
        RecordingHost host;
        app.execute(CommandId(command));
        app.closeRequested(host);
        assert(app.quitRequested && host.quitRequested);
    }
    EditorApp app;
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
    assert(app.tabCount == 1 && app.document.path == path && !app.document.dirty,
        "Saving during whole-application exit retains the saved tab for the session.");
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
