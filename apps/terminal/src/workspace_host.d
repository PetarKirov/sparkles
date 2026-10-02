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
import sparkles.terminal_view.component : TerminalView, TerminalViewOptions;
import sparkles.terminal_view.input : ExitBehavior;
import sparkles.terminal_view.pool : TerminalPool;
import sparkles.ui.components.dock : DockAxis, DockFrames, PaneId;
import sparkles.ui.geometry : Rect;

import std.datetime.systime : Clock, SysTime;

import chrome : ChromeTheme, Layer, paintLayer;
import keymap : KeyCommand, TermCommand;
import settings : ButtonLabels, OnExit;
import workspace : Direction, maxPanesPerTab, maxTabs, PaneSpec, Refusal, restored,
    saved, SavedWorkspace, Workspace;

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
    /// Poll the mouse for the pane under it (the desktop). A touch embedder
    /// turns it off and routes its gestures itself (`focusAt`, the wheel).
    bool pollPointer = true;

    private bool[PaneId] prompting; // exited panes that keep their prompt
    private bool[PaneId] expanded; // prompts whose status line is open
    private SysTime[PaneId] started, ended; // when each program ran
    private Layer[PaneId] banners; // the exit prompts, placed this frame
    private bool[PaneId] restoredCommand; // explicit commands not yet re-run
    private PaneId pointerOwner; // the pane a drag started in
    private string shownTitle;
    private bool dirty; // a structural change not yet saved
    private bool repaint = true; // the arrangement changed: every pane redraws
    private PaneId lastFocused;

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
    SavedWorkspace snapshot() const @safe => saved(ws);

    private bool create(PaneId id) @system
    {
        const spec = ws.spec(id);
        assert(spec !is null);
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
        o.hooks.titleChanged = (scope const(char)[] _) {};
        o.hooks.cwdChanged = (scope const(char)[] p) { self.ws.setCwd(id, p.idup); self.dirty = true; };
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

    /// Closes pane `id`: its program is hung up, its tab closes with it when
    /// it was the last.
    void closePane(PaneId id) @system
    {
        pool.closeFor(id);
        prompting.remove(id);
        expanded.remove(id);
        started.remove(id);
        ended.remove(id);
        banners.remove(id);
        restoredCommand.remove(id);
        ws.close(id);
        dirty = true;
    }

    // ── the frame ───────────────────────────────────────────────────────

    /**
    Drives every pane for one frame within `area` (window pixels): opens new
    panes at their size, resizes, pumps all of them, applies the exit policy,
    and keeps the window title on the focused pane's.
    */
    void frame(H)(ref H h, in Rect area) @system
    {
        import raylib : GetMousePosition, IsMouseButtonDown, IsMouseButtonPressed,
            MouseButton;

        auto c = h.canvas;
        const cw = c.fonts.cellW() > 0 ? c.fonts.cellW() : 1;
        const ch = c.fonts.cellH() > 0 ? c.fonts.cellH() : 1;
        DockFrames f;
        ws.frames(Rect(0, 0, area.width / cw, area.height / ch), f);

        // The pointer belongs to the pane under it — or, during a drag, to the
        // pane the drag began in (`TSS9`). A press there also focuses it.
        static if (__traits(compiles, GetMousePosition()))
        if (pollPointer)
        {
            const m = GetMousePosition();
            const leftDown = IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT);
            PaneId under;
            foreach (ref p; f.panes)
            {
                const px = area.x + p.rect.x * cw, py = area.y + p.rect.y * ch;
                if (m.x >= px && m.x < px + p.rect.width * cw
                    && m.y >= py && m.y < py + p.rect.height * ch)
                    under = p.pane;
            }
            if (!leftDown)
                pointerOwner = under;
            // A click on an exit prompt is the prompt's, not the pane's.
            if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT)
                && tap(h, cast(int) m.x, cast(int) m.y))
                under = pointerOwner = 0;
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
            Rect r;
            bool shown;
            foreach (ref p; f.panes)
                if (p.pane == id)
                {
                    r = p.rect;
                    shown = true;
                }
            tv.opts.visible = shown;
            tv.opts.pollMouse = pollPointer && shown && id == pointerOwner;
            if (shown)
                any |= tv.frame(h, r.width > 0 ? r.width : 1, r.height > 0 ? r.height : 1);
            else if (tv.s.terminal !is null)
            {
                tv.pump();
                tv.deliverEvents(h);
            }
        }

        applyExits();
        placeBanners(area, cw, ch, f);
        // One pane changed: the whole window repaints (panes share it); none:
        // the last frame stays up (`HST6`).
        if (!any && !repaint)
            h.skipFrame();
        if (auto tv = focusedView())
        {
            const t = tv.title;
            if (t != shownTitle)
            {
                shownTitle = t.idup;
                static if (__traits(compiles, h.title(t)))
                    h.title(t.length ? t : "sparkles:terminal");
            }
        }
    }

    /// Paints every shown pane at its pixel rect, then the dividers and, with
    /// more than one pane, the focused pane's corner mark (the `reveal` chrome,
    /// `TSS11`).
    void paint(H)(ref H h, in Rect area, RgbColor divider, RgbColor accent) @system
    {
        import raylib : Color, DrawRectangle;

        auto c = h.canvas;
        const cw = c.fonts.cellW() > 0 ? c.fonts.cellW() : 1;
        const ch = c.fonts.cellH() > 0 ? c.fonts.cellH() : 1;
        DockFrames f;
        ws.frames(Rect(0, 0, area.width / cw, area.height / ch), f);

        foreach (ref p; f.panes)
            if (auto tv = pool.byId(p.pane))
                tv.paintPanePx(h, area.x + p.rect.x * cw, area.y + p.rect.y * ch,
                    p.rect.width * cw, p.rect.height * ch);

        foreach (ref l; banners)
            paintLayer(h, l, theme);

        static Color rgb(RgbColor x) => Color(x.r, x.g, x.b, 255);
        foreach (ref d; f.dividers)
            DrawRectangle(area.x + d.rect.x * cw, area.y + d.rect.y * ch,
                d.rect.width * cw, d.rect.height * ch, rgb(divider));
        if (f.panes.length > 1)
            foreach (ref p; f.panes)
                if (p.pane == ws.focused)
                {
                    const x = area.x + p.rect.x * cw, y = area.y + p.rect.y * ch;
                    const len = ch > 6 ? ch : 6, w = 3;
                    DrawRectangle(x, y, len, w, rgb(accent));
                    DrawRectangle(x, y, w, len, rgb(accent));
                }
    }

    /**
    Lays out the exit prompt of every shown pane that keeps one, along the
    pane's bottom (`TSS2`, mockup E1).
    */
    private void placeBanners(in Rect area, int cw, int ch, in DockFrames f) @system
    {
        import chrome : place, Place;
        import exit_banner : exitBanner, ExitInfo;

        banners = null;
        foreach (ref p; f.panes)
        {
            const kept = p.pane in prompting;
            auto tv = pool.byId(p.pane);
            if (kept is null || tv is null)
                continue;
            const spec = ws.spec(p.pane);
            ExitInfo info;
            info.status = tv.s.childStatus;
            info.command = spec !is null && spec.command.length ? spec.command : shellName();
            info.cwd = spec !is null ? spec.cwd : null;
            if (auto s = p.pane in started)
                info.started = *s;
            if (auto e = p.pane in ended)
                info.ended = *e;
            const open = (p.pane in expanded) !is null;
            banners[p.pane] = place(exitBanner(info, open, *kept, labels),
                p.rect.width, p.rect.height, area.x + p.rect.x * cw, area.y + p.rect.y * ch,
                cw, ch, Place.bottom);
        }
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
    The pane at pixel (`x`, `y`) of `area` with cells `cw` × `ch`, and its
    top-left in pixels; 0 when there is none.
    */
    PaneId paneAt(in Rect area, int cw, int ch, int x, int y, out int left, out int top) const @safe
    {
        DockFrames f;
        ws.frames(Rect(0, 0, area.width / cw, area.height / ch), f);
        foreach (ref p; f.panes)
        {
            const px = area.x + p.rect.x * cw, py = area.y + p.rect.y * ch;
            if (x >= px && x < px + p.rect.width * cw && y >= py && y < py + p.rect.height * ch)
            {
                left = px;
                top = py;
                return p.pane;
            }
        }
        return 0;
    }

    // ── input ───────────────────────────────────────────────────────────

    /// A key the table left to the program: to the focused pane, unless its
    /// program is gone (`TKM2`).
    void forward(H)(ref H h, in KeyEvent k) @system
    {
        import sparkles.input : Event;

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
        Refusal why;
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
                cast(void) ws.focusToward(Direction.left, cellArea);
                break;
            case TermCommand.focusRight:
                cast(void) ws.focusToward(Direction.right, cellArea);
                break;
            case TermCommand.focusUp:
                cast(void) ws.focusToward(Direction.up, cellArea);
                break;
            case TermCommand.focusDown:
                cast(void) ws.focusToward(Direction.down, cellArea);
                break;
            case TermCommand.zoomPane:
                ws.toggleZoom();
                break;
            case TermCommand.closePane:
            case TermCommand.promptClose:
                closePane(ws.focused);
                break;
            case TermCommand.promptRerun:
            case TermCommand.promptShell:
                respawnFocused(h, c.cmd == TermCommand.promptShell);
                break;
            case TermCommand.none:
            case TermCommand.copy:
            case TermCommand.paste:
            case TermCommand.fontLarger:
            case TermCommand.fontSmaller:
            case TermCommand.fontReset:
            case TermCommand.showGuide:
            case TermCommand.toggleExtraKeys:
            case TermCommand.dismiss:
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
        dirty = true;
        return true;
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
