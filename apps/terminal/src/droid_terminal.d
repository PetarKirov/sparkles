/**
The terminal as an Android app: the workspace's tabs and splits
(`workspace_host`), plus the touch and window behavior a phone needs
(docs/specs/terminal/android.md).

$(LIST
    * The panes follow the $(B content rect) — the window minus the system
        bars and the soft keyboard — so the prompt stays above the keyboard,
        and the extra-keys row (`NOD10`) sits between the two.
    * Touch is routed as gestures, never as raylib's emulated mouse: a tap
        focuses the pane under it and raises the soft keyboard (`NOD8`) or
        presses an extra key, a drag scrolls the pane it began in (or becomes
        wheel reports when the application tracks the mouse), a pinch resizes
        the font. Positions arrive in pixels (`PointerUnit.pixels`): the key
        row is not on the cell grid.
    * The screen oracle (`NOD14`) writes the focused pane's text for on-device
        tests when they ask for it.
)
*/
module droid_terminal;

version (Android):

import core.time : Duration, msecs;

import extra_keys : ExtraKey, ExtraKeyKind, Latch;
import sparkles.base.term_color : RgbColor;
import sparkles.input : Event, GestureEvent, Gesture, Key, KeyAction, KeyEvent,
    match, PasteEvent, PointerAction, PointerEvent, WheelEvent;
import sparkles.raylib_text.font_set : FontSet;
import sparkles.terminal_view.component : ColorOverrides, TerminalView, TerminalViewOptions;
import sparkles.ui.geometry : Rect;
import sparkles.ui.layout : Frame;
import sparkles.ui.widget : WidgetTree;

import chrome : ChromeTheme;
import droid_platform : DroidPlatform;
import key_router : KeyRouter, paintGuide, Route;
import touch_guide : TouchGuide;
import keymap : KeyCommand, TermCommand, TermContext;
import screen_oracle : ScreenOracle;
import settings_load : LoadedConfig;
import workspace_host : WorkspaceHost;

/// The whole-surface Android component.
struct DroidTerminal
{
    WorkspaceHost host;
    ScreenOracle oracle;
    /// Notifications, the system scheme, the autofill spike (`droid_platform`).
    DroidPlatform platform;

    /// The options the first pane switches to when its program ends — the
    /// login that follows the installer (`NOD7`, `TSS4`: a respawn of the same
    /// pane).
    TerminalViewOptions next;
    /// ditto
    bool hasNext;

    /// The configuration's part of every pane's options: colours, policy,
    /// scrollback (`loadSettings` keeps it current).
    TerminalViewOptions base;

    /// The extra-keys layout, rows top to bottom (`extra_keys.extraKeysFrom`).
    ExtraKey[][] keys;
    /// `~/.termux`, the compatibility layer below the config file (`NOD10`,
    /// `NOD11`, `TCF3`).
    string termuxDir;
    /// `config.json` (`TCF2`); `loadSettings` resolves it over `termuxDir`, at
    /// start and on `termux-reload-settings`.
    string configPath;
    /// The configuration in effect.
    LoadedConfig config;
    /// Every key goes through the terminal's table first (`TKM1`).
    KeyRouter router;
    /// The chrome's colours: the terminal scheme's foreground and background
    /// (D17).
    RgbColor chromeFg = RgbColor(0xcd, 0xd6, 0xf4);
    /// ditto
    RgbColor chromeBg = RgbColor(0x1e, 0x1e, 0x2e);
    /// The divider and focus-mark colours.
    RgbColor divider = RgbColor(0x45, 0x47, 0x5a);
    /// ditto
    RgbColor accent = RgbColor(0x89, 0xb4, 0xfa);
    /// Where the workspace is saved (`TSS14`); empty: not saved.
    string statePath;

    /// The extra-keys row was swiped away; a swipe up from the bottom edge
    /// brings it back (`TCF7`). Not persisted.
    private bool rowDismissed;
    private bool guideWasShown;
    private int defaultFontPx;
    private Latch latch;
    private bool keyboardShown;
    private float pinchBase = 0; // the font size a pinch started from
    private Geometry lastGeometry;
    private FontSet* fonts; // the host's, for the key row's labels
    private int cellW = 1, cellH = 1;
    private KeyCommand pendingCommand; // picked in the touch guide
    private bool hasPending;

    @disable this(this);

    /// Every pane's GPU resources belong to this live host session.
    void shutdown(H)(ref H h) @system
    {
        save();
        host.pool.closeAll();
    }

    /// The frame's pre-render half: lay the panes out in the content rect,
    /// drive every pane, and decide whether to draw.
    WidgetTree view(H)(ref H h)
    {
        import am_server : takeReloadRequest;

        if (takeReloadRequest())
            loadSettings();

        auto c = h.canvas;
        fonts = c.fonts;
        cellW = fonts.cellW() > 0 ? fonts.cellW() : 1;
        cellH = fonts.cellH() > 0 ? fonts.cellH() : 1;
        {
            import sparkles.android.activity : dpToPx;

            // Buttons are touch targets: 48 dp, in whole rows (`TOK7`).
            host.theme.targetRows = (dpToPx(48) + cellH - 1) / cellH;
        }
        if (defaultFontPx == 0)
            defaultFontPx = h.fontSizePx;

        // The installer's pty ended: the login takes the pane over in place
        // (`TSS4`) — the installer's output stays above a separator.
        if (hasNext)
            if (auto tv = host.focusedView())
                if (tv.s.childExited)
                {
                    tv.opts.program = next.program;
                    tv.opts.argv = next.argv;
                    tv.opts.env = next.env;
                    tv.opts.cwd = next.cwd;
                    if (tv.respawn(h))
                        hasNext = false;
                }

        if (hasPending)
        {
            hasPending = false;
            run(h, pendingCommand);
        }
        router.unseenNotifications = host.notifications.unseen; // `TPG11`
        router.tick((cast(long)(h.frameSeconds * 1000)).msecs);
        const wait = router.untilShown;
        if (wait != Duration.max)
            static if (__traits(compiles, h.wakeIn(wait)))
                h.wakeIn(wait);
        noteGuide();

        const g = geometry(h);
        // The key row moves with the keyboard even when the panes' cell grid
        // does not change (a sub-cell difference): repaint it anyway.
        if (g != lastGeometry)
        {
            lastGeometry = g;
            host.invalidate();
        }
        {
            import raylib : GetScreenHeight, GetScreenWidth;

            host.phonePortrait = GetScreenHeight() > GetScreenWidth();
        }
        host.frame(h, paneArea(g));
        if (auto tv = host.focusedView())
            if (platform.frame(*tv))
            {
                import cli : viewOptionsFrom;

                string[] reported; // by `loadSettings` already
                useColors(viewOptionsFrom(config.effective, platform.systemDark, reported).colors);
            }
        if (host.takeDirty())
            save();
        if (auto tv = host.focusedView())
            oracle.frame(*tv, keyLabels());
        return WidgetTree.init;
    }

    /// Keys go to the terminal, through any latched modifier; touch becomes
    /// gestures here.
    void handle(H)(ref H h, in Event e)
    {
        e.match!(
            (in KeyEvent k) { sendKey(h, k); },
            (in PointerEvent p) { onPointer(h, p); },
            (in WheelEvent w) { onWheel(h, w); },
            (in GestureEvent g) { onGesture(h, g); },
            (in PasteEvent p) {
                if (auto tv = host.focusedView())
                    tv.onPaste(p);
            },
            (in _) {},
        );
    }

    /// The panes, the guide over their bottom rows, then the key row.
    void paint(H)(ref H h, in WidgetTree, in Frame[])
    {
        const g = geometry(h);
        host.paint(h, paneArea(g), divider, accent);
        paintGuide(h, router, context, g.paneCols, g.paneRows, 0, g.top, chromeFg, chromeBg);
        paintKeys(g);
    }

    /**
    Re-resolve the configuration (`TCF2`, `TCF8`): the defaults, `~/.termux`
    and `config.json`, applied to what can change live — the extra-keys row,
    every pane's colour scheme and protocol policy, and the options of panes
    not yet started. Every warning goes to the log (`TCF4`).
    */
    void loadSettings()
    {
        import cli : viewOptionsFrom;
        import extra_keys : extraKeysFromLayout;
        import settings_load : loadTerminalConfig;
        import sparkles.base.logger : warning;

        config = loadTerminalConfig(configPath, termuxDir);
        string[] warnings = config.warnings;
        keys = extraKeysFromLayout(config.effective.extraKeys.layout, warnings);
        // The system's scheme (`TPR13`); `view` follows it changing.
        base = viewOptionsFrom(config.effective, systemDark: platform.systemDark, warnings);
        foreach (id, tv; host.pool)
        {
            tv.opts.policy = base.policy;
            tv.opts.scrollbackLimit = base.scrollbackLimit;
        }
        useColors(base.colors);
        next.policy = base.policy;
        next.scrollbackLimit = base.scrollbackLimit;
        host.onExit = config.effective.behaviour.onExit;
        host.labels = config.effective.ui.buttonLabels;
        host.overlayStyle = config.effective.ui.overlayStyle;
        host.notificationsConfig = config.effective.notifications;
        host.tabsOpener = config.effective.ui.tabsOpener;
        host.paneChrome = config.effective.ui.paneChrome;
        host.linkTap = config.effective.links.tap;
        host.linkLongPress = config.effective.links.longPress;
        host.linkSchemes = config.effective.links.schemes.dup;
        host.touch = true;
        router.configure(config.effective, warnings);
        foreach (w; warnings)
            warning(i"$(w)");
        host.invalidate();
    }

    /**
    Install `colors` — the active scheme's (`activeScheme`) — on every pane,
    the panes still to open and the chrome, and make the scheme they belong
    to the one the panes report (`TPR13`, `TPR14`: `CSI ? 996 n`, and mode
    2031's unsolicited report when it changed).
    */
    private void useColors(in ColorOverrides colors)
    {
        import sparkles.terminal_view.protocols : ColorScheme;

        const dark = !config.effective.appearance.followSystem || platform.systemDark;
        foreach (id, tv; host.pool)
            tv.setColorScheme(dark ? ColorScheme.dark : ColorScheme.light, colors);
        base.colors = colors;
        next.colors = colors;
        if (colors.hasForeground)
            chromeFg = colors.foreground;
        if (colors.hasBackground)
            chromeBg = colors.background;
        const rows = host.theme.targetRows;
        host.theme = ChromeTheme.of(chromeFg, chromeBg);
        host.theme.targetRows = rows;
        host.invalidate();
    }

    private TermContext context() const => TermContext(overlayOpen: host.surfaces.modal, promptOpen: host.promptOpen);

    /// The panes' area, in pixels: the content rect above the key row.
    private Rect paneArea(in Geometry g) const
        => Rect(0, g.top, g.paneCols * cellW, g.paneRows * cellH);

    // ── keys ────────────────────────────────────────────────────────────────

    /// The row's labels, space-separated, one row per line (the oracle's
    /// `keys.txt`).
    private string keyLabels() const
    {
        import std.algorithm.iteration : map;
        import std.array : join;

        return keys.map!(row => row.map!(k => k.label).join(" ")).join("\n");
    }

    private void sendKey(H)(ref H h, in KeyEvent k)
    {
        const before = latch.any;
        auto chord = latch.apply(k);
        if (before != latch.any)
            host.invalidate(); // the released latch's highlight goes
        // A surface with a search field types first (`TKM4`).
        if (host.surfaces.modal && host.surfaces.key(chord))
        {
            noteGuide();
            return;
        }
        const r = router.route(chord, context);
        final switch (r.route)
        {
            case Route.program:
                // Under a surface nothing typed reaches a pane (`TKM4`).
                if (!host.surfaces.modal)
                    host.forward(h, chord);
                break;
            case Route.consumed:
                break;
            case Route.execute:
                run(h, r.command);
                break;
        }
        noteGuide();
    }

    /// Runs one of the terminal's commands.
    private void run(H)(ref H h, KeyCommand c)
    {
        if (host.run(h, c, Rect(0, 0, lastGeometry.paneCols, lastGeometry.paneRows)))
        {
            host.invalidate();
            return;
        }
        final switch (c.cmd)
        {
            case TermCommand.none:
            case TermCommand.showGuide: // the guide consumes its own row
                break;
            case TermCommand.dismiss:
                if (host.surfaces.modal)
                    host.surfaces.cancel();
                else
                    router.closeGuide();
                break;
            case TermCommand.confirm:
                host.surfaces.confirm();
                break;
            case TermCommand.copy:
                if (auto tv = host.focusedView())
                    cast(void) tv.copy(h);
                break;
            case TermCommand.paste:
                if (auto tv = host.focusedView())
                    tv.pasteClipboard();
                break;
            case TermCommand.fontLarger:
                h.fontSize(h.fontSizePx + 2);
                break;
            case TermCommand.fontSmaller:
                if (h.fontSizePx > 8)
                    h.fontSize(h.fontSizePx - 2);
                break;
            case TermCommand.fontReset:
                if (defaultFontPx > 0)
                    h.fontSize(defaultFontPx);
                break;
            case TermCommand.toggleExtraKeys:
                rowDismissed = !rowDismissed;
                host.invalidate();
                break;
            // The workspace's own, answered above.
            case TermCommand.newTab, TermCommand.closeTab, TermCommand.nextTab,
                TermCommand.prevTab, TermCommand.goToTab, TermCommand.splitRight,
                TermCommand.splitDown, TermCommand.focusLeft, TermCommand.focusRight,
                TermCommand.focusUp, TermCommand.focusDown, TermCommand.zoomPane,
                TermCommand.closePane, TermCommand.promptRerun, TermCommand.promptShell,
                TermCommand.promptClose, TermCommand.tabTree, TermCommand.openAbout,
                TermCommand.openLogs, TermCommand.openNotifications:
                break;
        }
    }

    /// The guide appearing or closing repaints the panes under it.
    private void noteGuide()
    {
        if (router.lantern.shown != guideWasShown)
        {
            guideWasShown = router.lantern.shown;
            host.invalidate();
        }
    }

    private void pressExtraKey(H)(ref H h, in ExtraKey key)
    {
        final switch (key.kind)
        {
            case ExtraKeyKind.modifier:
                latch.toggle(key.key);
                host.invalidate();
                return;
            case ExtraKeyKind.menu:
                // The touch guide at the leader (`TKM6`, `TKM7`): what it picks
                // runs on the next frame, where the host is at hand.
                auto self = &this;
                host.surfaces.push(new TouchGuide(router.table, context, router.leader,
                    (KeyCommand c) { self.pendingCommand = c; self.hasPending = true; }));
                host.invalidate();
                return;
            case ExtraKeyKind.keyboard:
                toggleKeyboard();
                return;
            case ExtraKeyKind.key:
                KeyEvent ke;
                ke.key = key.key;
                strike(h, ke);
                return;
            case ExtraKeyKind.text:
                import std.utf : decodeFront;

                KeyEvent ke;
                ke.key = Key.char_;
                ke.text = key.text;
                string t = key.text;
                if (t.length)
                {
                    const c = decodeFront(t);
                    if (t.length == 0)
                        ke.unshifted = c; // one character: a key of its own
                }
                strike(h, ke);
                return;
        }
    }

    /// A press and its release, as a physical key delivers them (the
    /// terminal-grade keyboard reports releases; kitty mode encodes them).
    private void strike(H)(ref H h, KeyEvent ke)
    {
        ke.action = KeyAction.press;
        sendKey(h, ke);
        ke.action = KeyAction.release;
        ke.text = null;
        host.forward(h, ke);
    }

    private void toggleKeyboard()
    {
        import sparkles.android.soft_input : hideSoftKeyboard, showSoftKeyboard;

        if (keyboardShown)
            hideSoftKeyboard();
        else
            showSoftKeyboard();
        keyboardShown = !keyboardShown;
    }

    private void paintKeys(in Geometry g)
    {
        import raylib : Color, DrawRectangle;
        import sparkles.raylib_text.draw : drawText;
        import sparkles.raylib_text.style : TextStyle;
        import std.utf : count;

        if (keys.length == 0 || g.keysHeight == 0 || fonts is null)
            return;
        DrawRectangle(0, g.keysTop, g.width, g.keysHeight, Color(0x24, 0x27, 0x3a, 255));
        foreach (r, row; keys)
        {
            if (row.length == 0)
                continue;
            const y = g.keysTop + cast(int) r * g.keyHeight;
            foreach (i, key; row)
            {
                const x0 = cast(int)(i * g.width / row.length);
                const x1 = cast(int)((i + 1) * g.width / row.length);
                const lit = key.kind == ExtraKeyKind.modifier && latch.isOn(key.key);
                if (lit)
                    DrawRectangle(x0 + 2, y + 2, x1 - x0 - 4, g.keyHeight - 4,
                        Color(0x8a, 0xad, 0xf4, 255));
                const cols = cast(int) count(key.label);
                const tx = x0 + (x1 - x0 - cols * cellW) / 2;
                const ty = y + (g.keyHeight - cellH) / 2;
                drawText(*fonts, key.label, tx, ty, TextStyle.init,
                    lit ? RgbColor(0x1e, 0x20, 0x30) : RgbColor(0xca, 0xd3, 0xf5));
            }
        }
    }

    // ── touch ───────────────────────────────────────────────────────────────

    private void onPointer(H)(ref H h, in PointerEvent p)
    {
        import sparkles.android.soft_input : showSoftKeyboard;

        if (p.action == PointerAction.press)
        {
            pinchBase = 0; // a new contact re-bases the next pinch
            return;
        }
        if (p.action != PointerAction.release)
            return;

        // On a touch target a press/release pair IS a tap: the recogniser
        // turns a moving contact into wheel steps instead (`touchGestures`).
        const g = geometry(h);
        if (g.keyHeight > 0 && p.pos.y >= g.keysTop && p.pos.y < g.keysTop + g.keysHeight)
        {
            const r = (p.pos.y - g.keysTop) / g.keyHeight;
            if (r < keys.length && keys[r].length)
            {
                const i = p.pos.x * cast(int) keys[r].length / (g.width > 0 ? g.width : 1);
                if (i >= 0 && i < keys[r].length)
                    pressExtraKey(h, keys[r][i]);
            }
            return;
        }
        // An exit prompt takes its own taps (`TSS2`).
        if (host.tap(h, p.pos.x, p.pos.y))
            return;
        // A link takes a tap per `links.tap` (`TPR5`).
        if (host.tapLink(p.pos.x, p.pos.y, longPress: false))
            return;
        // A tap on a pane focuses it (`TSS9`), shows its toolbar under `reveal`
        // (`TSS11`) and asks for the keyboard.
        cast(void) host.tapPane(p.pos.x, p.pos.y);
        showSoftKeyboard();
        keyboardShown = true;
    }

    private void onWheel(H)(ref H h, in WheelEvent w)
    {
        const g = geometry(h);
        if (swipeKeyRow(g, w))
            return;
        // Under a page the drag scrolls it (finger up: towards the end).
        if (host.scrollSurface(w.dy))
            return;
        // The pane the drag began in: an application tracking the mouse gets
        // wheel reports (a pager, an editor); otherwise the drag walks its
        // scrollback.
        int left, top;
        const id = host.paneAt(w.pos.x, w.pos.y, left, top);
        auto tv = id ? host.pool.byId(id) : host.focusedView();
        if (tv is null)
            return;
        if (!tv.sendWheel(w.dy, (w.pos.x - left) / cellW, (w.pos.y - top) / cellH))
            tv.scrollViewport(w.dy);
    }

    /// `TCF7`: a downward swipe on the row hides it; an upward swipe from the
    /// bottom edge brings it back. A drag reports where it began (`pos`) and
    /// its direction (`dy` > 0: the finger moved up).
    private bool swipeKeyRow(in Geometry g, in WheelEvent w)
    {
        const bottom = g.keysTop + g.keysHeight;
        if (!rowDismissed && g.keysHeight > 0 && w.dy < 0
            && w.pos.y >= g.keysTop && w.pos.y < bottom)
        {
            rowDismissed = true;
            host.invalidate();
            return true;
        }
        const edge = 2 * cellH;
        if (rowDismissed && w.dy > 0 && w.pos.y >= bottom - edge)
        {
            rowDismissed = false;
            host.invalidate();
            return true;
        }
        return false;
    }

    private void onGesture(H)(ref H h, in GestureEvent g)
    {
        // A long-press on a link, per `links.longPress` (`TPR5`); off by default,
        // when the long-press selects (`TSE1`).
        if (g.gesture == Gesture.longPress)
        {
            cast(void) host.tapLink(g.pos.x, g.pos.y, longPress: true);
            return;
        }
        if (g.gesture != Gesture.pinch)
            return;
        if (pinchBase <= 0)
            pinchBase = h.fontSizePx;
        const px = cast(int)(pinchBase * g.scale + 0.5f);
        if (px >= 8 && px <= 96 && px != h.fontSizePx)
            h.fontSize(px);
    }

    /// Writes the workspace for the next start (`TSS14`); everything closed
    /// removes it. A failure is logged.
    private void save()
    {
        import std.file : exists, mkdirRecurse, remove;
        import std.path : dirName;

        import sparkles.base.logger : warning;
        import sparkles.wired.json : writeJSONFile;

        if (!statePath.length)
            return;
        try
        {
            if (host.ws.empty)
            {
                if (statePath.exists)
                    remove(statePath);
                return;
            }
            mkdirRecurse(statePath.dirName);
        }
        catch (Exception e)
        {
            warning(i"workspace: $(statePath): $(e.msg)");
            return;
        }
        auto r = writeJSONFile(host.snapshot, statePath);
        if (r.hasError)
            warning(i"workspace: not saved: $(r.error.toString)");
    }

    // ── geometry ────────────────────────────────────────────────────────────

    /// The frame's layout, in pixels: the content rect, the panes at its top
    /// (whole cells), the key row filling the rest down to the keyboard.
    private static struct Geometry
    {
        int top, width, paneCols, paneRows;
        int keysTop, keysHeight, keyHeight;
    }

    private Geometry geometry(H)(ref H h)
    {
        import raylib : GetScreenHeight, GetScreenWidth;
        import sparkles.android.activity : contentRect, hardwareKeyboardAttached;

        import extra_keys : extraKeysShown;

        Geometry g;
        const r = contentRect();
        const valid = r.bottom > r.top && r.right > r.left;
        g.top = valid ? r.top : 0;
        g.width = valid ? r.right - r.left : GetScreenWidth();
        const bottom = valid ? r.bottom : GetScreenHeight();

        // The soft keyboard is not reported to native code; the content rect
        // shrinking by more than a system bar is it.
        const screenHeight = GetScreenHeight();
        const softKeyboard = valid && screenHeight - r.bottom > screenHeight / 6;
        const shown = extraKeysShown(config.effective.extraKeys.visible, softKeyboard,
            hardwareKeyboardAttached(), rowDismissed);
        g.keyHeight = shown && keys.length ? cellH * 2 : 0;
        g.keysHeight = cast(int) keys.length * g.keyHeight;
        const paneHeight = bottom - g.top - g.keysHeight;
        g.paneCols = g.width / cellW > 0 ? g.width / cellW : 1;
        g.paneRows = paneHeight / cellH > 0 ? paneHeight / cellH : 1;
        g.keysTop = bottom - g.keysHeight;
        return g;
    }
}
