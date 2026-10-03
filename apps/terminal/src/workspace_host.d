/**
The live half of the workspace (`TSS1`, `TSS3`, `TSS6`–`TSS10`, `TSS14`): the
panes behind the ids `workspace.Workspace` holds, driven every frame.

Every live pane is pumped every frame, shown or not, so a background tab's
program keeps running (`TSS7`). A shown pane is sized to its cell rect and
painted at its pixel rect; the pointer is polled by the pane under it (or the
one a drag started in), relative to that pane (`TSS9`). An exited pane follows
`behaviour.onExit` (`TSS1`): it closes, or stays with its exit prompt — Enter
runs the command again, Esc the user's shell, Ctrl+C closes it (`TSS2`,
`TSS3`).

The embedding component (desktop window, Android activity) supplies the pane
area each frame, the options a new pane starts with ($(LREF
WorkspaceHost.paneOptions)), and the keys; it keeps the binding table.
*/
module workspace_host;

import sparkles.base.term_color : RgbColor;
import sparkles.doc_view.pane : chromeTheme, DocViewEnv, DocViewPane, PaneKey;
import sparkles.terminal_view.component : TerminalView, TerminalViewOptions;
import sparkles.terminal_view.input : ExitBehavior;
import sparkles.terminal_view.pool : TerminalPool;
import sparkles.ui.components.dock : DockAxis, DockFrames, DividerFrame, PaneId;
import sparkles.ui.geometry : Rect;

import std.datetime.systime : Clock, SysTime;

import std.algorithm.comparison : min;

import chrome : ChromeTheme, Layer, paintLayer, place, Place;
import opener : OpenerHit, pillBand, rail, usesPill;
import pane_chrome : PaneBox, paneBoxes, paneFrame, paneHeader, paneToolbar, ToolAction,
    toolHit;
import tab_tree : TabTree, TreePane, TreeTab;
import confirmations : ClipboardRead, PasteConfirm;
import sparkles.terminal_view.notification_log : NotificationLog, NotificationRoute;
import sparkles.terminal_view.osc_scan : Notification;
import sparkles.terminal_view.protocols : PasteConfirmRequest;
import keymap : KeyCommand, TermCommand;
import settings : ButtonLabels, LinkAction, NotificationsConfig, OnExit, OpenTarget,
    OverlayStyle, PaneChrome, TabsOpener;
import links : canOpen, LinkConfirm, openUri, schemeOf;
import surfaces : SurfaceContext, Surfaces;
import workspace : dividerAt, dividerClamp, Direction, maxPanesPerTab, maxTabs, PaneSpec,
    Placement, Refusal, restored, saved, SavedWorkspace, Workspace;

/// What a pane does when its program has exited (`TSS1`).
enum ExitAction : ubyte
{
    close,  /// close the pane
    prompt, /// keep it with the exit prompt
    hold,   /// keep it with a status line and no actions
}

/**
`behaviour.onExit` for one exit. A pane whose program was given explicitly
always prompts, as in zellij; a signal death (status 128 + n) is a failure.
*/
ExitAction exitActionFor(OnExit policy, bool explicitCommand, int status) @safe pure nothrow @nogc
{
    if (explicitCommand && policy != OnExit.hold)
        return ExitAction.prompt;
    final switch (policy)
    {
        case OnExit.promptOnFailure:
            return status == 0 ? ExitAction.close : ExitAction.prompt;
        case OnExit.prompt:
            return ExitAction.prompt;
        case OnExit.close:
            return ExitAction.close;
        case OnExit.hold:
            return ExitAction.hold;
    }
}

/// The direction a resize command moves the focused pane's border (`TSS8`).
private Direction resizeDirection(TermCommand c) @safe pure nothrow @nogc
    => c == TermCommand.resizeLeft ? Direction.left : c == TermCommand.resizeRight
        ? Direction.right : c == TermCommand.resizeUp ? Direction.up : Direction.down;

/// Where `open.target` puts an opened file; `external` never reaches the
/// workspace (the request is declined first) and maps to a tab.
Placement placementFor(OpenTarget t) @safe pure nothrow @nogc
{
    final switch (t)
    {
        case OpenTarget.tab:
        case OpenTarget.external:
            return Placement.tab;
        case OpenTarget.splitRight:
            return Placement.splitRight;
        case OpenTarget.splitDown:
            return Placement.splitDown;
    }
}

/// The panes, their model, and the per-frame drive.
struct WorkspaceHost
{
    Workspace ws;
    TerminalPool!(maxTabs * maxPanesPerTab) pool;
    /// `behaviour.onExit`.
    OnExit onExit = OnExit.promptOnFailure;
    /**
    The options a pane starts with: the configuration's (colours, policy,
    scrollback) plus what `spec` runs — its command (null: the user's shell,
    `TSS4`) in its directory. Set by the embedder.
    */
    TerminalViewOptions delegate(in PaneSpec spec, bool shell) @system paneOptions;
    /// The last refusal, for the embedder's toast (`TSS6`); cleared on read.
    string notice;
    /// The chrome's colours (D17) and button labels (`TCF9`); the embedder
    /// keeps them current.
    ChromeTheme theme;
    /// ditto
    ButtonLabels labels;
    /// `ui.overlayStyle`: confirmations anchored or as sheets (`TCF10`).
    OverlayStyle overlayStyle;
    /// What shows over the panes: confirmations, menus, pages and toasts.
    Surfaces surfaces;
    /// Poll the mouse for the pane under it (the desktop). A touch embedder
    /// turns it off and routes its gestures itself (`tapPane`, the wheel).
    bool pollPointer = true;
    /// `ui.tabsOpener` and `ui.paneChrome` (`TCF12`, `TCF13`).
    TabsOpener tabsOpener;
    /// ditto
    PaneChrome paneChrome;
    /// A phone held upright: `auto` opens the tree from a pill (`TCF12`). A
    /// touch screen also puts search fields at the bottom (`TSS13`).
    bool phonePortrait;
    /// ditto
    bool touch;
    /// The key that opens the tree, shown beside the pill on the desktop.
    string treeHint;
    /// `links.tap`, `links.longPress` and `links.schemes` (`TPR5`, `TPR6`).
    LinkAction linkTap = LinkAction.confirm;
    /// ditto
    LinkAction linkLongPress = LinkAction.off;
    /// ditto
    string[] linkSchemes;
    /// The focused pane's accent corner, in pixels: its arms and their
    /// thickness. A dense screen sets them from dp (16 and 3); 0 keeps the
    /// cell-sized default (`TSS11`, `ACC4`).
    int cornerPx, cornerThickPx;
    /// Every pane's notifications, in one log (`TPG9`), and the config's
    /// `notifications` section its page groups by (`TPG18`).
    NotificationLog notifications;
    /// ditto
    NotificationsConfig notificationsConfig;

    // This frame's geometry, for `paint` and the hit tests.
    private PaneBox[] boxes;
    private DividerFrame[] dividers; // in cells, beside `dividerRects`
    private Rect[] dividerRects;
    private ptrdiff_t dragging = -1; // the divider being dragged (`TSS10`)
    private int dragPos; // where it would land, in cells along its axis
    private Rect panesArea;
    private Layer openerLayer;
    private Layer[] paneChromeLayers;
    private Layer toolbarLayer;
    private PaneId revealed; // the pane whose toolbar shows (`reveal`)
    private int cellW = 1, cellH = 1;

    /// What every viewer pane shares (`TDV5`): grammars and the loader.
    /// Made on the first viewer, by `makeDocEnv` when the embedder supplies
    /// one (Android's asset reader), else from the environment.
    DocViewEnv* docEnv;
    /// ditto
    DocViewEnv* delegate() @system makeDocEnv;
    /// Where an opened file appears (`open.target`, `TDV2`).
    Placement openPlacement = Placement.tab;
    /// The credits document the `showCredits` command opens (`TPG15`):
    /// beside the executable on the desktop, `asset:credits/terminal.md` on
    /// Android; empty when the build bundles none.
    string creditsPath;
    /// The chrome's colours, which viewer panes wear (`TDV7`).
    RgbColor viewerFg = RgbColor(0xcd, 0xd6, 0xf4);
    /// ditto
    RgbColor viewerBg = RgbColor(0x1e, 0x1e, 0x2e);

    private DocViewPane*[PaneId] viewers; // the viewer panes, by id
    private float wheelRest = 0; // the polled wheel's fractional rows
    private bool[PaneId] prompting; // exited panes that keep their prompt
    private bool[PaneId] expanded; // prompts whose status line is open
    private SysTime[PaneId] started, ended; // when each program ran
    private Layer[PaneId] banners; // the exit prompts, placed this frame
    private int[PaneId] bannerScroll; // how far each expanded command is scrolled
    private bool[PaneId] restoredCommand; // explicit commands not yet re-run
    private PaneId pointerOwner; // the pane a drag started in
    private string shownTitle;
    private bool dirty; // a structural change not yet saved
    private bool repaint = true; // the arrangement changed: every pane redraws
    private PaneId lastFocused;
    private string pendingClipboard; // an OSC 52 write, set by the next frame
    private bool clipboardPending;

    @disable this(this);

    // ── reading ─────────────────────────────────────────────────────────

    /// The focused pane's instance, or null.
    TerminalView* focusedView() @safe pure nothrow @nogc => pool.byId(ws.focused);

    /// Whether the focused pane shows its exit prompt (the `prompt` key scope).
    bool promptOpen() const @safe pure nothrow @nogc
    {
        const f = ws.focused;
        return f != 0 && (f in prompting) !is null && prompting[f];
    }

    /// Whether a structural change happened since the last $(LREF takeDirty).
    bool takeDirty() @safe pure nothrow @nogc
    {
        const d = dirty;
        dirty = false;
        return d;
    }

    // ── panes ───────────────────────────────────────────────────────────

    /// Opens the first tab: `command` (null: the shell) in `cwd`. False when
    /// the pane could not be created.
    bool start(string cwd, string command) @system
    {
        Refusal why;
        const id = ws.newTab(cwd, command, why);
        return id != 0 && create(id);
    }

    /// Re-creates a saved workspace (`TSS14`): fresh shells in each pane's
    /// directory; a pane that ran an explicit command comes back at its exit
    /// prompt instead of running it. False when nothing usable was saved.
    bool restore(SavedWorkspace s) @system
    {
        auto w = restored(s);
        if (w.empty)
            return false;
        ws = w;
        foreach (ref spec; ws.panes)
        {
            if (spec.command.length)
                restoredCommand[spec.id] = true;
            if (!create(spec.id))
                return false;
        }
        return true;
    }

    /// The saved form, for restore.
    SavedWorkspace snapshot() @system
    {
        refreshCwds();
        return saved(ws);
    }

    /**
    Each pane's directory, where its program does not report one with OSC 7
    (`TPR4`): read from the shell's own `/proc` entry. Bash as most
    distributions ship it never sends OSC 7, and without this a restored pane
    or a new split started in the home directory rather than where the shell
    was (`TSS14`, `TSS8`).

    $(B Desktop Linux only.) On Android the pane's process is proot, which
    emulates `chdir`: its `/proc` entry never moves, and one spawned without a
    directory reads `/` — saving that put restored panes in `/`. There OSC 7
    is the only source; elsewhere too.
    */
    void refreshCwds() @system
    {
        version (Android) {}
        else version (linux)
        {
            import std.conv : text;
            import std.file : readLink;

            foreach (id, tv; pool)
            {
                if ((id in osc7) !is null || tv.s.child <= 0 || tv.s.childExited)
                    continue;
                try
                {
                    const dir = readLink(text("/proc/", tv.s.child, "/cwd"));
                    if (auto s = ws.spec(id))
                        if (s.cwd != dir)
                            ws.setCwd(id, dir);
                }
                catch (Exception) {} // the shell went: keep the last known
            }
        }
    }

    private bool[PaneId] osc7; // panes whose program reports its directory

    private bool create(PaneId id) @system
    {
        const spec = ws.spec(id);
        assert(spec !is null);
        if (spec.isDocument)
            return createViewer(id, spec.document);
        TerminalViewOptions o = paneOptions !is null
            ? paneOptions(*spec, spec.command.length == 0 || (id in restoredCommand) !is null)
            : TerminalViewOptions.init;
        if (auto rc = id in restoredCommand)
        {
            // Restore shows the command it ran, at its prompt, without running
            // it: Enter re-runs it (`TSS14`).
            o.program = "/bin/sh";
            o.argv = restoredArgv(spec.command);
            o.shellCommand = null;
        }
        // The workspace owns the exit policy and the window: a pane never
        // quits the application or retitles the window itself.
        o.exitBehavior = ExitBehavior.hold;
        o.builtinChords = false;
        o.internalScrollbar = true;
        o.embedded = true;
        auto self = &this;
        // Every protocol event reaches the log at `trace` — "debug" in the
        // log page (`TPG7`). What a program put on the clipboard is logged by
        // size only: it may be a password (`TPG6`).
        import sparkles.base.logger : trace;

        o.hooks.titleChanged = (scope const(char)[] t) { trace(i"pane $(id): title \"$(t)\""); };
        // What the pane asks of the user (`TPR19`, `TPR21`) goes on the
        // surface stack; what it says goes in a toast (`TPR9`, `TPR20`).
        auto inner = o.hooks.notify;
        o.hooks.notify = (in Notification n, NotificationRoute route) {
            import std.conv : to;

            const what = n.title.length ? n.title : n.body;
            trace(i"pane $(id): notification \"$(what)\" ($(route.to!string))");
            if (route == NotificationRoute.toast)
                self.surfaces.toast(n.title.length ? n.title.idup ~ ": " ~ n.body.idup
                    : n.body.idup);
            if (inner !is null)
                inner(n, route);
        };
        o.hooks.pasteConfirm = (in PasteConfirmRequest r) {
            trace(i"pane $(id): paste of $(r.lines) lines held for confirmation");
            if (auto tv = self.pool.byId(id))
                self.surfaces.push(new PasteConfirm(tv, r.lines, r.text.idup));
        };
        o.hooks.clipboardReadRequest = () {
            trace(i"pane $(id): OSC 52 clipboard read requested");
            if (auto tv = self.pool.byId(id))
                self.surfaces.push(new ClipboardRead(tv, self.programName(id),
                    self.paneWhere(id)));
        };
        o.hooks.clipboardWrite = (scope const(char)[] text) {
            trace(i"pane $(id): OSC 52 clipboard write, $(text.length) bytes");
            self.pendingClipboard = text.idup;
            self.clipboardPending = true;
            self.surfaces.toast("Copied by " ~ self.programName(id));
        };
        // Ctrl+click on a link (`TPR7`), through the allow-list (`TPR6`).
        o.hooks.openLink = (scope const(char)[] uri) {
            trace(i"pane $(id): open $(uri)");
            self.open(uri.idup);
        };
        o.hooks.cwdChanged = (scope const(char)[] p) {
            trace(i"pane $(id): directory $(p)");
            self.osc7[id] = true;
            self.ws.setCwd(id, p.idup);
            self.dirty = true;
        };
        // One log for every pane, each entry naming its pane (`TPG9`, `TPG10`).
        o.notificationLog = &notifications;
        o.notificationSource = id;
        o.hooks.tabTitle = () => self.tabTitle(id);
        auto tv = pool.create(id, o);
        if (tv is null)
        {
            ws.close(id);
            notice = "too many panes";
            return false;
        }
        started[id] = Clock.currTime;
        dirty = true;
        return true;
    }

    private static const(char)*[] restoredArgv(string command) @system
    {
        import std.string : toStringz;

        const script = "printf '%s\\n' \"$1\"; exit 0";
        return ["-sh".ptr, "-c".ptr, script.toStringz, "-sh".ptr, command.toStringz, null];
    }

    // A viewer pane for `path` (`TDV5`). A file that cannot be shown still
    // makes the pane — restore shows where the file went, as a located error.
    private bool createViewer(PaneId id, string path) @system
    {
        if (docEnv is null)
        {
            import sparkles.syntax : GrammarRegistry;

            docEnv = makeDocEnv !is null ? makeDocEnv()
                : DocViewEnv.create(GrammarRegistry.fromEnvironment());
        }
        auto p = new DocViewPane;
        cast(void) p.open(docEnv, path, chromeTheme(viewerFg, viewerBg));
        viewers[id] = p;
        dirty = true;
        return true;
    }

    /**
    Opens `path` in a viewer pane per `openPlacement`, beside `from` — the
    pane whose program asked, 0 when unknown (`TDV2`) — and focuses it. False
    with `notice` set when the workspace refused.
    */
    bool openDocument(string path, PaneId from) @system
    {
        Refusal why;
        const id = ws.openDocument(path, openPlacement, from, why);
        if (!id)
        {
            notice = why == Refusal.tooManyTabs ? "at most 32 tabs"
                : why == Refusal.tooManyPanes ? "at most 16 panes in a tab" : "cannot open " ~ path;
            return false;
        }
        repaint = true;
        return create(id);
    }

    /// The viewer pane `id`, or null when it is a terminal pane.
    DocViewPane* viewer(PaneId id) @safe pure nothrow @nogc
    {
        if (auto p = id in viewers)
            return *p;
        return null;
    }

    /// Re-themes every viewer pane to the chrome's colours (`TDV7`).
    void setViewerColors(RgbColor fg, RgbColor bg) @system
    {
        if (fg == viewerFg && bg == viewerBg)
            return;
        viewerFg = fg;
        viewerBg = bg;
        foreach (p; viewers)
            p.setTheme(chromeTheme(fg, bg));
        repaint = true;
    }

    /// Scrolls viewer pane `id` by `rows` (a touch drag); false when `id` is
    /// not a viewer, so the caller scrolls a terminal pane instead.
    bool scrollViewer(PaneId id, long rows) @system
    {
        auto p = viewer(id);
        if (p is null)
            return false;
        if (p.scrollBy(rows))
            repaint = true;
        return true;
    }

    /**
    Opens what programs asked for since the last frame (`TDV1`): each request
    beside the pane its process descends from, answered so the requesting
    command can return (`TDV3`).
    */
    private void takeOpenRequests() @system
    {
        version (Posix)
        {
            import open_request : answerOpen, paneOfProcess, takeRequests = takeOpenRequests;

            foreach (r; takeRequests())
            {
                const from = cast(PaneId) paneOfProcess(r.pid, (int pid) {
                    foreach (id, tv; pool)
                        if (tv.s.child == pid)
                            return cast(ulong) id;
                    return 0UL;
                });
                const ok = openDocument(r.path, from);
                answerOpen(r.id, ok, ok ? null : notice);
            }
        }
    }

    /**
    Tells the user about configuration problems once (`TCF4`): one toast for
    the warnings not reported before, naming the first and counting the rest;
    each is in the log in full. A reload that repeats a known problem stays
    quiet, a new one speaks again.
    */
    void reportConfigWarnings(in string[] warnings) @safe
    {
        import core.time : seconds;
        import std.conv : text;

        string first;
        size_t fresh;
        foreach (w; warnings)
            if (w !in reportedWarnings)
            {
                reportedWarnings[w] = true;
                if (fresh++ == 0)
                    first = toastForm(w);
            }
        if (fresh)
            surfaces.toast(fresh == 1 ? first
                : text(first, " (and ", fresh - 1, " more in the log)"), 6.seconds);
    }

    private bool[string] reportedWarnings;

    // A warning as a toast says it: the log line's `config: /abs/path/x.json:`
    // becomes `x.json:` — the path is in the log, and on a phone it would be
    // all the toast had room for.
    private static string toastForm(string w) @safe pure
    {
        import std.algorithm.searching : findSplit, startsWith;
        import std.path : baseName;

        if (w.startsWith("config: "))
            w = w["config: ".length .. $];
        if (w.startsWith("/"))
            if (auto parts = w.findSplit(": "))
                return baseName(parts[0]) ~ ": " ~ parts[2];
        return w;
    }

    /// Closes pane `id`: its program is hung up, its tab closes with it when
    /// it was the last.
    void closePane(PaneId id) @system
    {
        if (auto p = id in viewers)
        {
            (*p).release();
            viewers.remove(id);
        }
        pool.closeFor(id);
        prompting.remove(id);
        expanded.remove(id);
        bannerScroll.remove(id);
        osc7.remove(id);
        started.remove(id);
        ended.remove(id);
        banners.remove(id);
        restoredCommand.remove(id);
        ws.close(id);
        dirty = true;
    }

    // ── the frame ───────────────────────────────────────────────────────

    /**
    Drives every pane for one frame within `area` (window pixels): lays out
    the opener and the panes with their chrome, opens new panes at their size,
    resizes, pumps all of them, applies the exit policy, and keeps the window
    title on the focused pane's.
    */
    void frame(H)(ref H h, in Rect area) @system
    {
        import raylib : GetMousePosition, IsMouseButtonDown, IsMouseButtonPressed,
            MouseButton;
        import core.time : msecs;

        // Files programs asked to open (`TDV1`) become panes before the layout
        // is read; a quarter-second wake bounds how long a request waits on an
        // idle window.
        takeOpenRequests();
        static if (__traits(compiles, h.wakeIn(250.msecs)))
            h.wakeIn(250.msecs);

        auto c = h.canvas;
        cellW = c.fonts.cellW() > 0 ? c.fonts.cellW() : 1;
        cellH = c.fonts.cellH() > 0 ? c.fonts.cellH() : 1;
        layout(area);

        // The pointer belongs to the pane under it — or, during a drag, to the
        // pane the drag began in (`TSS9`). A press there also focuses it.
        static if (__traits(compiles, GetMousePosition()))
        if (pollPointer)
        {
            const m = GetMousePosition();
            const mx = cast(int) m.x, my = cast(int) m.y;
            const leftDown = IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT);
            PaneId under;
            foreach (ref b; boxes)
                if (contains(b.content, mx, my))
                    under = b.id;
            // `reveal`: a pane's toolbar shows while the pointer is at its top
            // or on the toolbar itself (`TSS11`).
            if (paneChrome == PaneChrome.reveal && !leftDown)
            {
                PaneId top;
                foreach (ref b; boxes)
                    if (contains(Rect(b.outer.x, b.outer.y, b.outer.width, 2 * cellH), mx, my))
                        top = b.id;
                if (top != revealed && !(revealed && toolbarLayer.contains(mx, my)))
                {
                    revealed = top;
                    repaint = true;
                }
            }
            dragDivider(mx, my, leftDown, IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT));
            if (dragging >= 0)
                under = pointerOwner = 0;
            if (!leftDown)
                pointerOwner = under;
            // A click on the chrome is the chrome's, not the pane's.
            if (dragging < 0 && IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT)
                && tap(h, mx, my))
                under = pointerOwner = 0;
            // A viewer pane scrolls with the wheel over it; a terminal pane
            // polls its own (`pollMouse`).
            if (auto v = surfaces.modal ? null : viewer(under))
            {
                import raylib : GetMouseWheelMove;

                wheelRest -= GetMouseWheelMove() * 3;
                const rows = cast(long) wheelRest;
                wheelRest -= rows;
                if (v.scrollBy(rows))
                    repaint = true;
            }
            if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT) && under)
            {
                pointerOwner = under;
                if (under != ws.focused)
                    cast(void) ws.focusPane(under);
            }
        }

        bool any = repaint || dirty || ws.focused != lastFocused;
        repaint = false;
        lastFocused = ws.focused;
        foreach (id, tv; pool)
        {
            const b = boxOf(id);
            tv.opts.visible = b !is null;
            tv.opts.pollMouse = pollPointer && b !is null && id == pointerOwner
                && !surfaces.modal;
            if (b !is null)
                any |= tv.frame(h, b.cols, b.rows);
            else if (tv.s.terminal !is null)
            {
                tv.pump();
                tv.deliverEvents(h);
            }
        }

        // A viewer reloads its file when it changed on disk (`TDV8`).
        foreach (id, p; viewers)
            any |= p.poll() || p.needsPaint;

        applyExits();
        placeChrome();
        placeBanners();
        placeSurfaces(area);
        if (clipboardPending)
        {
            clipboardPending = false;
            static if (__traits(compiles, h.clipboard(pendingClipboard)))
                h.clipboard(pendingClipboard);
        }
        if (surfaces.expire() || surfaces.changed)
        {
            surfaces.changed = false;
            repaint = true;
        }
        if (surfaces.toasts.length)
            static if (__traits(compiles, h.wakeIn(surfaces.nextExpiry)))
                h.wakeIn(surfaces.nextExpiry);
        // A page may show what changes without input (the log's tail).
        if (surfaces.modal)
            static if (__traits(compiles, h.wakeIn(surfaces.nextExpiry)))
            {
                import core.time : msecs;

                h.wakeIn(500.msecs);
            }
        // One pane changed: the whole window repaints (panes share it); none:
        // the last frame stays up (`HST6`).
        if (!any && !repaint)
            h.skipFrame();
        const(char)[] t;
        if (auto tv = focusedView())
            t = tv.title;
        else if (auto v = viewer(ws.focused))
            t = v.title;
        if (t != shownTitle)
        {
            shownTitle = t.idup;
            static if (__traits(compiles, h.title(t)))
                h.title(t.length ? t : "sparkles:terminal");
        }
    }

    /// The pill band or the rail, the panes' area, and where the tree opens
    /// (`TSS13`); the panes' boxes in it (`TSS11`).
    private void layout(in Rect area) @system
    {
        const pill = usesPill(tabsOpener, phonePortrait);
        const rows = theme.targetRows > 2 ? theme.targetRows : 2;
        Rect openerRect;
        Rect panelRect;
        if (pill)
        {
            openerRect = Rect(area.x, area.y, area.width, rows * cellH);
            panesArea = Rect(area.x, area.y + rows * cellH, area.width, area.height - rows * cellH);
            const inset = touch ? cellW : 0;
            const wide = touch ? panesArea.width - 2 * inset : min(panesArea.width, 44 * cellW);
            panelRect = Rect(panesArea.x + inset, panesArea.y, wide, panesArea.height);
            openerLayer = place(pillBand(treeTabs(), rows, touch, treeHint, guide: touch),
                area.width / cellW, rows, area.x, area.y, cellW, cellH, Place.top);
        }
        else
        {
            const railCols = (rows * cellH + cellW - 1) / cellW;
            openerRect = Rect(area.x, area.y, railCols * cellW, area.height);
            panesArea = Rect(area.x + railCols * cellW, area.y, area.width - railCols * cellW,
                area.height);
            panelRect = Rect(panesArea.x, panesArea.y, min(panesArea.width, 36 * cellW),
                panesArea.height);
            openerLayer = place(rail(treeTabs(), railCols, area.height / cellH, rows, guide: touch),
                railCols, area.height / cellH, area.x, area.y, cellW, cellH, Place.top);
        }
        this.panelRect = panelRect;

        DockFrames f;
        ws.frames(Rect(0, 0, panesArea.width / cellW, panesArea.height / cellH), f);
        boxes = paneBoxes(f, panesArea, cellW, cellH, paneChrome, ws.focused);
        dividers = f.dividers.dup;
        dividerRects.length = 0;
        foreach (ref d; f.dividers)
            dividerRects ~= Rect(panesArea.x + d.rect.x * cellW, panesArea.y + d.rect.y * cellH,
                d.rect.width * cellW, d.rect.height * cellH);
    }

    /**
    The touch half of a divider drag (`TSS10`), for an embedder that polls
    the raw contact (`pollPointer` off): `down` while one finger is on the
    screen at (`x`, `y`), `slop` the target's widening (a finger: about
    16 dp). True while a divider is held — the embedder then keeps the
    contact from scrolling or tapping the panes.
    */
    bool touchDivider(int x, int y, bool down, int slop) @safe
    {
        const pressed = down && !touchWasDown;
        touchWasDown = down;
        // A lifted finger has no position: the drag ends where it was last.
        if (down)
        {
            touchX = x;
            touchY = y;
        }
        else
        {
            x = touchX;
            y = touchY;
        }
        if (dragging < 0 && !pressed)
            return false;
        dragDivider(x, y, down, pressed, slop);
        return dragging >= 0;
    }

    /// Whether the opener's `⋯` was tapped since the last call: the embedder
    /// opens its touch guide (`TSS16`), as it does for `MENU`.
    bool takeGuideRequest() @safe pure nothrow @nogc
    {
        const r = guideRequested;
        guideRequested = false;
        return r;
    }

    private bool guideRequested;

    /// Whether a divider is held (`TSS10`).
    bool draggingDivider() const @safe pure nothrow @nogc => dragging >= 0;

    private bool touchWasDown;
    private int touchX, touchY; // the last contact while down

    /**
    A divider drag (`TSS10`): a press on a divider (or within a few pixels of
    it) picks it up, moving shows where it would land, and the release
    resizes the split — once, so each program sees one settled size rather
    than one per frame. `slop` widens the divider's target: a few pixels for
    a mouse, a finger's width on a touch screen.
    */
    private void dragDivider(int mx, int my, bool down, bool pressed, int slop = 4) @safe
    {
        int along(in DividerFrame d) const => d.axis == DockAxis.horizontal
            ? (mx - panesArea.x) / cellW : (my - panesArea.y) / cellH;

        if (dragging < 0)
        {
            if (!pressed)
                return;
            foreach (i, r; dividerRects)
                if (contains(Rect(r.x - slop, r.y - slop, r.width + 2 * slop,
                    r.height + 2 * slop), mx, my))
                {
                    dragging = i;
                    const d = dividers[i];
                    dragPos = dividerAt(d);
                    return;
                }
            return;
        }
        const d = dividers[dragging];
        const pos = dividerClamp(d, along(d));
        if (pos != dragPos)
        {
            dragPos = pos;
            repaint = true;
        }
        if (down)
            return;
        dragging = -1;
        if (ws.moveDivider(d, pos))
            repaint = dirty = true;
    }

    private Rect panelRect; // where the tree opens

    /// Pane `id`'s box this frame, or null when it is not shown.
    private const(PaneBox)* boxOf(PaneId id) const @safe pure nothrow @nogc
    {
        foreach (ref b; boxes)
            if (b.id == id)
                return &b;
        return null;
    }

    private static bool contains(in Rect r, int x, int y) @safe pure nothrow @nogc
        => x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;

    /// The headers, frames and the revealed toolbar (`TSS11`).
    private void placeChrome() @system
    {
        paneChromeLayers.length = 0;
        toolbarLayer = Layer.init;
        foreach (ref b; boxes)
        {
            const cols = b.outer.width / cellW, rows = b.outer.height / cellH;
            final switch (paneChrome)
            {
                case PaneChrome.reveal:
                    if (b.id == revealed)
                        toolbarLayer = place(paneToolbar(b.id, paneTitle(b.id), paneDetail(b.id),
                            labels, theme.targetRows, cols), cols, rows, b.outer.x, b.outer.y,
                            cellW, cellH, Place.top);
                    break;
                case PaneChrome.header:
                    paneChromeLayers ~= place(paneHeader(paneTitle(b.id), paneDetail(b.id),
                        b.focused, cols), cols, 1, b.outer.x, b.outer.y, cellW, cellH, Place.top);
                    break;
                case PaneChrome.framed:
                    paneChromeLayers ~= place(paneFrame(paneTitle(b.id), b.focused, cols, rows),
                        cols, rows, b.outer.x, b.outer.y, cellW, cellH, Place.top);
                    break;
            }
        }
    }

    /// What a pane is called: the user's pin, the program's title, the program.
    string paneTitle(PaneId id) @system
    {
        if (auto s = ws.spec(id))
            if (s.titlePin.length)
                return s.titlePin;
        if (auto v = viewer(id))
            return v.title.idup;
        if (auto tv = pool.byId(id))
            if (tv.title.length)
                return tv.title.idup;
        return programName(id);
    }

    /// The line under a pane's title: how it ended, or where it is.
    private string paneDetail(PaneId id) @system
    {
        import std.conv : text;

        if (auto tv = pool.byId(id))
            if (tv.s.childExited && tv.s.childReaped)
                return tv.s.childStatus == 0 ? "exited" : text("exited ", tv.s.childStatus);
        if (auto s = ws.spec(id))
            return homeShortened(s.cwd);
        return null;
    }

    private static string homeShortened(string path) @safe
    {
        import std.process : environment;

        const home = environment.get("HOME");
        if (home.length && path.length >= home.length && path[0 .. home.length] == home)
            return "~" ~ path[home.length .. $];
        return path;
    }

    /// The tabs and panes, as the opener and the tree show them (`TSS12`).
    TreeTab[] treeTabs() @system
    {
        TreeTab[] tabs;
        foreach (ti, ref t; ws.tabs)
        {
            TreeTab tab;
            tab.current = ti == ws.current;
            foreach (id; ws.panesOf(ti))
            {
                TreePane p;
                p.id = id;
                p.title = paneTitle(id);
                auto tv = pool.byId(id);
                p.icon = tv !is null && tv.icon.length ? tv.icon.idup : "❯";
                p.detail = paneDetail(id);
                p.focused = tab.current && id == ws.focused;
                p.failed = tv !is null && tv.s.childExited && tv.s.childStatus != 0;
                // Unseen notifications mark the pane and count on its tab (`TPG11`).
                const unseen = notifications.unseenFrom(id);
                p.unread = unseen != 0;
                tab.unread += unseen;
                tab.panes ~= p;
            }
            const lead = t.focused ? t.focused : (tab.panes.length ? tab.panes[0].id : 0);
            tab.title = t.titlePin.length ? t.titlePin : lead ? paneTitle(lead) : "tab";
            foreach (ref p; tab.panes)
                if (p.id == lead)
                    tab.icon = p.icon;
            tabs ~= tab;
        }
        return tabs;
    }

    /// Opens `uri` if its scheme is allowed (`TPR6`); otherwise says why not.
    void open(string uri) @system
    {
        version (Android)
            enum android = true;
        else
            enum android = false;
        if (canOpen(uri, linkSchemes, android))
            openUri(uri);
        else
            surfaces.toast("Not opened: " ~ (schemeOf(uri).length ? schemeOf(uri) : "this")
                ~ " links are not in links.schemes");
    }

    /**
    A tap (or, `longPress`, a long-press) at pixel (`x`, `y`) on a link: what
    `links.tap` or `links.longPress` says (`TPR5`) — the confirmation
    (L1/L2), opening at once, or nothing (the gesture falls through). True
    when the link took the gesture.
    */
    bool tapLink(int x, int y, bool longPress) @system
    {
        import sparkles.terminal_view.component : LinkSpan;

        const action = longPress ? linkLongPress : linkTap;
        if (action == LinkAction.off)
            return false;
        int left, top;
        const id = paneAt(x, y, left, top);
        auto tv = id ? pool.byId(id) : null;
        LinkSpan link;
        if (tv is null || !tv.linkAt((x - left) / cellW, (y - top) / cellH, link))
            return false;
        if (action == LinkAction.open)
        {
            open(link.uri);
            return true;
        }
        version (Android)
            enum android = true;
        else
            enum android = false;
        const where = Rect(left + link.startCol * cellW, top + link.row * cellH,
            (link.endCol - link.startCol + 1) * cellW, cellH);
        const spec = ws.spec(id);
        auto self = &this;
        surfaces.push(new LinkConfirm(link.uri, link.hyperlink,
            canOpen(link.uri, linkSchemes, android), android,
            spec !is null ? homeShortened(spec.cwd) : null, where, (string text) {
                self.pendingClipboard = text;
                self.clipboardPending = true;
                self.surfaces.toast("Copied");
            }));
        repaint = true;
        return true;
    }

    /// Opens the tree of tabs and panes (`TSS12`), or closes it when open.
    void toggleTree() @system
    {
        if (surfaces.stack.length && cast(TabTree) surfaces.stack[$ - 1] !is null)
        {
            surfaces.cancel();
            return;
        }
        auto self = &this;
        surfaces.push(new TabTree(() => self.treeTabs(), (size_t tab, PaneId pane) {
            if (pane)
                cast(void) self.ws.focusPane(pane);
            else
                cast(void) self.ws.selectTab(tab);
            self.repaint = true;
        }, () {
            Refusal why;
            self.refreshCwds();
            const from = self.ws.spec(self.ws.focused);
            const id = self.ws.newTab(from !is null ? from.cwd : null, null, why);
            if (id)
                cast(void) self.create(id);
            self.repaint = true;
        }));
    }

    /**
    Paints the opener, every shown pane at its box, the dividers, the panes'
    chrome, the exit prompts and — unless `withSurfaces` is false — the
    surfaces. An embedder that draws over the panes itself (the selection's
    handles, the Autofill chip) passes false and calls $(LREF paintSurfaces)
    after, so a page or a menu stays on top of them.
    */
    void paint(H)(ref H h, in Rect, RgbColor divider, RgbColor accent,
        bool withSurfaces = true) @system
    {
        import raylib : Color, DrawRectangle;

        static Color rgb(RgbColor x) => Color(x.r, x.g, x.b, 255);

        paintLayer(h, openerLayer, theme);
        auto canvas = h.canvas;
        foreach (ref b; boxes)
            if (auto tv = pool.byId(b.id))
                tv.paintPanePx(h, b.content.x, b.content.y, b.content.width, b.content.height);
            else if (auto v = viewer(b.id))
                v.paint(canvas, b.content.x, b.content.y, b.content.width, b.content.height,
                    focused: b.focused);
        foreach (ref d; dividerRects)
            DrawRectangle(d.x, d.y, d.width, d.height, rgb(divider));
        // Where a dragged divider would land.
        if (dragging >= 0)
        {
            const d = dividers[dragging];
            if (d.axis == DockAxis.horizontal)
                DrawRectangle(panesArea.x + dragPos * cellW + cellW / 2 - 1,
                    panesArea.y + d.rect.y * cellH, 3, d.rect.height * cellH, rgb(accent));
            else
                DrawRectangle(panesArea.x + d.rect.x * cellW,
                    panesArea.y + dragPos * cellH + cellH / 2 - 1, d.rect.width * cellW, 3,
                    rgb(accent));
        }
        foreach (ref l; paneChromeLayers)
            paintLayer(h, l, theme);
        // `reveal`: the focused pane's accent corner, with more than one pane.
        if (paneChrome == PaneChrome.reveal && boxes.length > 1)
            foreach (ref b; boxes)
                if (b.focused)
                {
                    const len = cornerPx > cellH ? cornerPx : cellH > 6 ? cellH : 6;
                    const w = cornerThickPx > 3 ? cornerThickPx : 3;
                    DrawRectangle(b.outer.x, b.outer.y, len, w, rgb(accent));
                    DrawRectangle(b.outer.x, b.outer.y, w, len, rgb(accent));
                }
        foreach (ref l; banners)
            paintLayer(h, l, theme);
        paintLayer(h, toolbarLayer, theme);
        if (withSurfaces)
            paintSurfaces(h);
    }

    /// ditto — the toasts, then the surface stack, bottom to top.
    void paintSurfaces(H)(ref H h) @system => surfaces.paint(h, theme);

    /**
    Lays out the exit prompt of every shown pane that keeps one, along the
    bottom of its content (`TSS2`, mockup E1).
    */
    private void placeBanners() @system
    {
        import exit_banner : exitBanner, ExitInfo;

        banners = null;
        foreach (ref b; boxes)
        {
            const kept = b.id in prompting;
            auto tv = pool.byId(b.id);
            if (kept is null || tv is null)
                continue;
            const spec = ws.spec(b.id);
            ExitInfo info;
            info.status = tv.s.childStatus;
            info.command = spec !is null && spec.command.length ? spec.command : shellName();
            info.cwd = spec !is null ? spec.cwd : null;
            if (auto s = b.id in started)
                info.started = *s;
            if (auto e = b.id in ended)
                info.ended = *e;
            const open = (b.id in expanded) !is null;
            // The command wraps across the pane and takes at most half of it;
            // a longer one scrolls (`TSS2`).
            import exit_banner : commandLines, commandScroll;

            const wrapCols = b.cols - 2;
            const commandRows = b.rows / 2 - 3 > 3 ? b.rows / 2 - 3 : 3;
            const scroll = cast(int) commandScroll(commandLines(info.command, wrapCols).length,
                commandRows, bannerScroll.get(b.id, 0));
            bannerScroll[b.id] = scroll;
            banners[b.id] = place(exitBanner(info, open, *kept, labels, theme.targetRows,
                wrapCols, commandRows, scroll),
                b.cols, b.rows, b.content.x, b.content.y, cellW, cellH, Place.bottom);
        }
    }

    /**
    Lays out the surfaces for this frame; a confirmation anchors at the
    focused pane's cursor line (`TCF10`), the tree in its panel (`TSS13`).
    */
    private void placeSurfaces(in Rect area) @system
    {
        SurfaceContext ctx = {area: panesArea, cellW: cellW, cellH: cellH, labels: labels,
            style: overlayStyle, targetRows: theme.targetRows, touch: touch,
            panelArea: panelRect};
        if (auto tv = focusedView())
            if (auto b = boxOf(ws.focused))
            {
                const c = tv.cursor;
                if (c.inViewport)
                    ctx.subject = Rect(b.content.x, b.content.y + c.y * cellH, b.content.width,
                        cellH);
            }
        surfaces.place(ctx);
    }

    /// Who is running in pane `id`: its foreground program, else its title.
    private string programName(PaneId id) @system
    {
        auto tv = pool.byId(id);
        if (tv is null)
            return "a program";
        const p = tv.foregroundProcessName;
        return p.length ? p.idup : tv.title.length ? tv.title.idup : "a program";
    }

    /// "Tab 'nvim', pane 2" — where pane `id` is, for a confirmation.
    private string paneWhere(PaneId id) @system
    {
        import std.conv : text;

        const t = ws.tabOf(id);
        if (t == size_t.max)
            return "A pane";
        const panes = ws.panesOf(t);
        size_t n = 1;
        foreach (i, p; panes)
            if (p == id)
                n = i + 1;
        return text("Tab \"", tabTitle(id), "\", pane ", n);
    }

    /// The title of the tab pane `id` is in: its pinned title, else its first
    /// pane's program.
    private string tabTitle(PaneId id) @system
    {
        const t = ws.tabOf(id);
        if (t == size_t.max)
            return null;
        return ws.tabs[t].titlePin.length ? ws.tabs[t].titlePin : programName(ws.panesOf(t)[0]);
    }

    /**
    A wheel or a drag of `rows` (positive: down) at window pixel (`x`, `y`):
    over an expanded exit prompt, its command scrolls (`TSS2`). False when the
    point is on no expanded prompt — the pane's then.
    */
    bool scrollBanner(int x, int y, int rows) @safe
    {
        foreach (id, ref l; banners)
            if ((id in expanded) !is null && l.contains(x, y))
            {
                bannerScroll[id] = bannerScroll.get(id, 0) + rows;
                repaint = true; // `placeBanners` clamps it next frame
                return true;
            }
        return false;
    }

    /**
    A wheel or a drag of `rows` (positive: towards the end) while a surface
    is modal: the top one scrolls, as by that many arrow keys. False when no
    surface is shown — the panes' then.
    */
    bool scrollSurface(int rows) @system
    {
        import sparkles.input.events : Key;

        if (!surfaces.modal)
            return false;
        // A `Scrollable` surface scrolls itself; any other, as by arrow keys.
        if (!surfaces.topScrolls)
            foreach (_; 0 .. rows < 0 ? -rows : rows)
                cast(void) surfaces.key(KeyEvent(rows < 0 ? Key.up : Key.down));
        else
            cast(void) surfaces.scroll(rows);
        repaint = true;
        return true;
    }

    /// Puts `text` on the clipboard with the next frame (a page's Copy).
    void setClipboard(string text) @safe pure nothrow @nogc
    {
        pendingClipboard = text;
        clipboardPending = true;
    }

    /// The user's shell, by name, for a pane that ran no command.
    private static string shellName() @safe
    {
        import std.path : baseName;
        import std.process : environment;

        const sh = environment.get("SHELL");
        return sh.length ? sh.baseName : "shell";
    }

    /**
    A tap or click at pixel (`x`, `y`): true when an exit prompt took it —
    its status line expands or collapses, its buttons re-run, start the
    shell or close the pane (`TSS2`, `TSS3`).
    */
    bool tap(H)(ref H h, int x, int y) @system
    {
        import exit_banner : ExitHit;

        if (surfaces.tap(x, y))
        {
            repaint = true;
            // The tap may be the last event for a while: draw what it changed.
            static if (__traits(compiles, h.requestFrame()))
                h.requestFrame();
            return true;
        }
        // The opener: the tree, a tab, a new tab (`TSS13`).
        if (openerLayer.contains(x, y))
        {
            const hit = openerLayer.hitAt(x, y);
            if (hit == OpenerHit.tree)
                toggleTree();
            else if (hit == OpenerHit.newTab)
                cast(void) run(h, KeyCommand(TermCommand.newTab), Rect.init);
            else if (hit == OpenerHit.guide)
                guideRequested = true; // the embedder opens it (`TSS16`)
            else if (hit >= OpenerHit.tab0 && hit < OpenerHit.tab0 + ws.tabs.length)
                cast(void) ws.selectTab(hit - OpenerHit.tab0);
            repaint = true;
            return true;
        }
        // A revealed pane's toolbar: split, zoom, close (`TSS11`).
        if (toolbarLayer.contains(x, y))
        {
            const hit = toolbarLayer.hitAt(x, y);
            if (hit >= toolHit)
            {
                const pane = cast(PaneId)((hit - toolHit) / 4);
                cast(void) ws.focusPane(pane);
                final switch (cast(ToolAction)((hit - toolHit) % 4))
                {
                    case ToolAction.split:
                        cast(void) run(h, KeyCommand(TermCommand.splitRight), Rect.init);
                        break;
                    case ToolAction.zoom:
                        ws.toggleZoom();
                        break;
                    case ToolAction.close:
                        closePane(pane);
                        break;
                }
                revealed = 0;
            }
            repaint = true;
            return true;
        }
        foreach (id, ref l; banners)
        {
            if (!l.contains(x, y))
                continue;
            const hit = l.hitAt(x, y);
            cast(void) ws.focusPane(id);
            switch (hit)
            {
                case ExitHit.toggle:
                    if (id in expanded)
                        expanded.remove(id);
                    else
                        expanded[id] = true;
                    break;
                case ExitHit.rerun:
                    respawnFocused(h, false);
                    break;
                case ExitHit.shell:
                    respawnFocused(h, true);
                    break;
                case ExitHit.close:
                    closePane(id);
                    break;
                default:
                    break;
            }
            repaint = true;
            return true;
        }
        return false;
    }

    /// The exit policy, for every pane whose program has exited and been
    /// reaped since the last frame (`TSS1`).
    private void applyExits() @system
    {
        PaneId[] closing;
        foreach (id, tv; pool)
        {
            if (!tv.s.childExited || !tv.s.childReaped || (id in prompting) !is null)
                continue;
            const spec = ws.spec(id);
            const explicit = spec !is null && spec.command.length > 0;
            final switch (exitActionFor(onExit, explicit || (id in restoredCommand) !is null,
                tv.s.childStatus))
            {
                case ExitAction.close:
                    closing ~= id;
                    break;
                case ExitAction.prompt:
                    prompting[id] = true;
                    tv.s.embedderOwnsExit = true;
                    ended[id] = Clock.currTime;
                    repaint = true;
                    break;
                case ExitAction.hold:
                    prompting[id] = false;
                    tv.s.embedderOwnsExit = true;
                    ended[id] = Clock.currTime;
                    repaint = true;
                    break;
            }
        }
        foreach (id; closing)
            closePane(id);
    }

    /// Repaint every shown pane on the next frame (the chrome around them
    /// changed).
    void invalidate() @safe pure nothrow @nogc
    {
        repaint = true;
    }

    /**
    The pane whose content is at pixel (`x`, `y`) this frame, and its
    content's top-left in pixels; 0 when there is none.
    */
    PaneId paneAt(int x, int y, out int left, out int top) const @safe
    {
        foreach (ref b; boxes)
            if (contains(b.outer, x, y))
            {
                left = b.content.x;
                top = b.content.y;
                return b.id;
            }
        return 0;
    }

    /**
    A tap on a pane (touch): it is focused and, under `reveal`, its toolbar
    shows until the next tap elsewhere (`TSS9`, `TSS11`). Returns the pane.
    */
    PaneId tapPane(int x, int y) @safe
    {
        int left, top;
        const id = paneAt(x, y, left, top);
        if (id && id != ws.focused)
            cast(void) ws.focusPane(id);
        if (paneChrome == PaneChrome.reveal)
            revealed = revealed == id ? 0 : id;
        repaint = true;
        return id;
    }

    // ── input ───────────────────────────────────────────────────────────

    /// A key the table left to the program: to the focused pane, unless its
    /// program is gone (`TKM2`).
    void forward(H)(ref H h, in KeyEvent k) @system
    {
        import sparkles.input : Event;

        // A viewer pane has no program: its keys are the viewer's, and
        // `q`/`Esc` close it (`TDV6`).
        if (auto v = viewer(ws.focused))
        {
            final switch (v.key(k))
            {
                case PaneKey.ignored:
                    break;
                case PaneKey.handled:
                    repaint = true;
                    break;
                case PaneKey.close:
                    closePane(ws.focused);
                    repaint = true;
                    break;
            }
            return;
        }
        if (auto tv = focusedView())
            if (!tv.s.childExited)
                tv.handle(h, Event(k));
    }

    /**
    Runs a workspace command; false when `c` is not one. `area` is the pane
    area in cells, for directional focus.
    */
    bool run(H)(ref H h, KeyCommand c, in Rect cellArea) @system
    {
        refreshCwds(); // a new pane starts where the focused shell is
        Refusal why;
        // Geometry in the cells the panes are laid out in (`layout`): the
        // caller's area includes the opener, and a resize measured there
        // would fix the wrong extent.
        const panes = panesArea.width > 0
            ? Rect(0, 0, panesArea.width / cellW, panesArea.height / cellH) : cellArea;
        final switch (c.cmd)
        {
            case TermCommand.newTab:
                const from = ws.spec(ws.focused);
                const id = ws.newTab(from !is null ? from.cwd : null, null, why);
                if (id)
                    cast(void) create(id);
                break;
            case TermCommand.closeTab:
                foreach (id; ws.panesOf(ws.current))
                    closePane(id);
                break;
            case TermCommand.nextTab:
                cast(void) ws.cycleTab(1);
                break;
            case TermCommand.prevTab:
                cast(void) ws.cycleTab(-1);
                break;
            case TermCommand.goToTab:
                cast(void) ws.selectTab(c.arg);
                break;
            case TermCommand.splitRight:
            case TermCommand.splitDown:
                const id = ws.split(c.cmd == TermCommand.splitRight
                    ? DockAxis.horizontal : DockAxis.vertical, why);
                if (id)
                    cast(void) create(id);
                break;
            case TermCommand.focusLeft:
                cast(void) ws.focusToward(Direction.left, panes);
                break;
            case TermCommand.focusRight:
                cast(void) ws.focusToward(Direction.right, panes);
                break;
            case TermCommand.focusUp:
                cast(void) ws.focusToward(Direction.up, panes);
                break;
            case TermCommand.focusDown:
                cast(void) ws.focusToward(Direction.down, panes);
                break;
            case TermCommand.resizeLeft:
            case TermCommand.resizeRight:
            case TermCommand.resizeUp:
            case TermCommand.resizeDown:
                if (ws.resizeToward(resizeDirection(c.cmd), panes))
                    repaint = dirty = true;
                break;
            case TermCommand.zoomPane:
                ws.toggleZoom();
                break;
            case TermCommand.tabTree:
                toggleTree();
                break;
            case TermCommand.closePane:
            case TermCommand.promptClose:
                closePane(ws.focused);
                break;
            case TermCommand.promptRerun:
            case TermCommand.promptShell:
                respawnFocused(h, c.cmd == TermCommand.promptShell);
                break;
            case TermCommand.openAbout:
            case TermCommand.openLogs:
            case TermCommand.openNotifications:
                import pages : openPage;

                openPage(this, c.cmd);
                return true;
            case TermCommand.showCredits:
                // `TPG15`/`TDV10`: the credits are a document like any other,
                // in a tab of their own.
                if (creditsPath.length)
                {
                    const id = ws.openDocument(creditsPath, Placement.tab, 0, why);
                    if (id)
                        cast(void) create(id);
                }
                else
                    notice = "no credits bundled with this build";
                break;
            case TermCommand.none:
            case TermCommand.copy:
            case TermCommand.paste:
            case TermCommand.fontLarger:
            case TermCommand.fontSmaller:
            case TermCommand.fontReset:
            case TermCommand.showGuide:
            case TermCommand.openSettings:
            case TermCommand.toggleExtraKeys:
            case TermCommand.dismiss:
            case TermCommand.confirm:
                return false;
        }
        final switch (why)
        {
            case Refusal.none:
            case Refusal.nothing:
                break;
            case Refusal.tooManyTabs:
                notice = "at most 32 tabs";
                break;
            case Refusal.tooManyPanes:
                notice = "at most 16 panes in a tab";
                break;
        }
        if (notice.length)
        {
            surfaces.toast(notice);
            notice = null;
        }
        dirty = true;
        return true;
    }

    /// Runs `command` in a new pane split from the focused one — the
    /// selection menu's Run (`TSE5`); false, with a toast, when none opens.
    bool runInNewPane(string command) @system
    {
        Refusal why;
        const id = ws.split(DockAxis.vertical, why);
        if (id == 0)
        {
            surfaces.toast(why == Refusal.tooManyPanes ? "at most 16 panes in a tab"
                : "no pane to split");
            return false;
        }
        ws.spec(id).command = command;
        dirty = true;
        return create(id);
    }

    /// Enter: the same command again; Esc (`shell`): the user's shell in the
    /// pane's last directory (`TSS3`, `TSS4`). A failed start keeps the prompt.
    private void respawnFocused(H)(ref H h, bool shell) @system
    {
        const id = ws.focused;
        auto tv = pool.byId(id);
        if (tv is null || !promptOpen)
            return;
        auto spec = ws.spec(id);
        if (shell)
            spec.command = null;
        restoredCommand.remove(id);
        if (paneOptions !is null)
        {
            auto o = paneOptions(*spec, shell);
            tv.opts.program = o.program;
            tv.opts.argv = o.argv;
            tv.opts.env = o.env;
            tv.opts.cwd = o.cwd;
            tv.opts.shellCommand = o.shellCommand;
        }
        if (tv.respawn(h))
        {
            prompting.remove(id);
            expanded.remove(id);
            ended.remove(id);
            banners.remove(id);
            started[id] = Clock.currTime;
            tv.s.embedderOwnsExit = false;
            repaint = true;
        }
    }
}

import sparkles.input : KeyEvent;

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("workspace_host.exitActionFor.thePolicy")
@safe pure nothrow @nogc unittest
{
    // `TSS1`: the default closes a clean exit and prompts after a failure or a
    // signal; an explicit command always prompts; `hold` never acts.
    assert(exitActionFor(OnExit.promptOnFailure, false, 0) == ExitAction.close);
    assert(exitActionFor(OnExit.promptOnFailure, false, 1) == ExitAction.prompt);
    assert(exitActionFor(OnExit.promptOnFailure, false, 128 + 9) == ExitAction.prompt);
    assert(exitActionFor(OnExit.close, false, 1) == ExitAction.close);
    assert(exitActionFor(OnExit.prompt, false, 0) == ExitAction.prompt);
    assert(exitActionFor(OnExit.close, true, 0) == ExitAction.prompt);
    assert(exitActionFor(OnExit.hold, true, 1) == ExitAction.hold);
}

@("workspace_host.reportConfigWarnings.onceEach")
@system unittest
{
    auto h = new WorkspaceHost;
    h.reportConfigWarnings(["config.json:4:27: tabWidth", "config.json:5:19: paths[1]"]);
    assert(h.surfaces.toasts.length == 1);
    assert(h.surfaces.toasts[0].text == "config.json:4:27: tabWidth (and 1 more in the log)");

    // A reload with the same problems is quiet; a new one speaks.
    h.reportConfigWarnings(["config.json:4:27: tabWidth", "config.json:5:19: paths[1]"]);
    assert(h.surfaces.toasts.length == 1);
    h.reportConfigWarnings(["config.json:2:3: font"]);
    assert(h.surfaces.toasts.length == 2 && h.surfaces.toasts[1].text == "config.json:2:3: font");

    // The toast names the file, not its path; the log keeps the path.
    h.reportConfigWarnings(["config: /home/u/.config/sparkles-terminal/config.json: bad"]);
    assert(h.surfaces.toasts[2].text == "config.json: bad");
}
