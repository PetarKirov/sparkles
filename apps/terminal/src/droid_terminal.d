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

import autofill_chip : AutofillChip;
import chrome : ChromeTheme;
import droid_platform : DroidPlatform;
import key_router : KeyRouter, paintGuide, Route;
import touch_guide : TouchGuide;
import keymap : KeyCommand, TermCommand, TermContext;
import screen_oracle : ScreenOracle;
import selection_menu : SelectionUi;
import settings_load : LoadedConfig;
import settings_page : SettingsPage;
import settings_store : TerminalSettingsStore;
import workspace_host : WorkspaceHost;

/// The whole-surface Android component.
struct DroidTerminal
{
    WorkspaceHost host;
    ScreenOracle oracle;
    /// Notifications, the system scheme, the autofill spike (`droid_platform`).
    DroidPlatform platform;
    /// Long-press selection, its handles and its menu (`TSE1`–`TSE6`).
    SelectionUi selection;
    /// The Autofill chip at a password prompt (`TSE10`).
    AutofillChip chip;

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
    private SettingsPage settingsPage; // the open page, for the keyboard
    private int startFontPt; // the configured size the window opened at
    private bool fontPending; // the page changed the font size

    private bool windowFocused = true; // last frame's, for the save on leaving
    private bool dividerGesture; // this contact began on a divider (`TSS10`)
    private bool dividerGestureHeld; // a finger was down last frame

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
            host.cornerPx = dpToPx(16);
            host.cornerThickPx = dpToPx(3);
        }
        if (defaultFontPx == 0) // the first frame
        {
            import sparkles.android.activity : showStatusBar;

            defaultFontPx = h.fontSizePx;
            // raylib opens the window fullscreen; the status bar gives the
            // system's own overlays (HyperOS's multitasking handle) a band of
            // their own, as Termux has (D48).
            showStatusBar();
        }

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

        if (chip.frame(host.focusedView()))
            host.invalidate();
        const g = geometry(h);
        chip.place(host.labels, host.theme.targetRows,
            Rect(0, g.keysTop - g.chipHeight, g.width, g.chipHeight), cellW, cellH);
        // The key row moves with the keyboard even when the panes' cell grid
        // does not change (a sub-cell difference): repaint it anyway.
        if (g != lastGeometry)
        {
            lastGeometry = g;
            host.invalidate();
        }
        {
            import raylib : GetScreenHeight, GetScreenWidth;

            import sparkles.android.activity : largeScreen;

            // A tablet keeps the rail in portrait too (`TCF14`, D47).
            host.phonePortrait = GetScreenHeight() > GetScreenWidth() && !largeScreen();
        }
        selection.reducedMotion = platform.reducedMotion; // `ACC5`, `TSE3`
        // A finger on a divider resizes the split (`TSS10`); that contact,
        // its fling included, is then the divider's, not the panes'.
        {
            import raylib : GetTouchPointCount, GetTouchPosition;
            import sparkles.android.activity : dpToPx;

            const n = GetTouchPointCount();
            const p = n > 0 ? GetTouchPosition(0) : typeof(GetTouchPosition(0)).init;
            if (host.touchDivider(cast(int) p.x, cast(int) p.y, n == 1, dpToPx(16)))
                dividerGesture = true;
            else if (n > 0 && !host.draggingDivider && !dividerGestureHeld)
                dividerGesture = false; // a new contact elsewhere
            dividerGestureHeld = n > 0;
        }
        if (dividerGesture)
            selection.frame(h, host);
        else
            selection.pollTouch(h, host);
        host.frame(h, paneArea(g));
        settingsFrame(h);
        if (auto tv = host.focusedView())
            if (platform.frame(*tv))
            {
                import cli : viewOptionsFrom;

                string[] reported; // by `loadSettings` already
                useColors(viewOptionsFrom(config.effective, platform.systemDark, reported).colors);
            }
        if (host.takeDirty())
            save();
        // Leaving the foreground saves too (`TSS14`): a phone may kill the app
        // there without a shutdown, and the directories the shells moved to
        // (`refreshCwds`) mark nothing dirty.
        {
            import raylib : IsWindowFocused;

            const focusedNow = IsWindowFocused();
            if (windowFocused && !focusedNow)
                save();
            windowFocused = focusedNow;
        }
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
        // Surfaces lay out in the faces that draw them (`GLY10`).
        static if (__traits(hasMember, H, "textMeasure"))
        {
            import std.functional : toDelegate;
            import chrome : ChromeMeasure, useChromeMeasure;
            import sparkles.ui.style : TextStyle;

            static typeof(h.textMeasure()) gm;
            static int width(scope const(char)[] s, in TextStyle st) @safe => gm.width(s, st);
            static int rows(in TextStyle st) @safe => gm.rows(st);
            gm = h.textMeasure();
            useChromeMeasure(ChromeMeasure(toDelegate(&width), toDelegate(&rows)));
        }
        const g = geometry(h);
        // The handles and the chip mark the panes; a page or a menu covers
        // them (`TSE3`, `TSE10`).
        host.paint(h, paneArea(g), divider, accent, withSurfaces: false);
        selection.paint(accent);
        chip.paint(h, host.theme);
        host.paintSurfaces(h);
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
        import settings_load : loadTerminalConfig;

        config = loadTerminalConfig(configPath, termuxDir);
        if (startFontPt == 0)
            startFontPt = config.effective.appearance.font.size;
        applyConfig(config.warnings);
    }

    /// Applies `config.effective` to the running app: at load, and after each
    /// settings-page edit (`TCF8`, `TSP2`).
    private void applyConfig(string[] warnings)
    {
        import cli : viewOptionsFrom;
        import extra_keys : extraKeysFromLayout;
        import sparkles.base.logger : warning;

        keys =extraKeysFromLayout(config.effective.extraKeys.layout, warnings);
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
        selection.useAndroid(config.effective);
        router.configure(config.effective, warnings);
        foreach (w; warnings)
            warning(i"$(w)");
        host.reportConfigWarnings(warnings);
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
            case TermCommand.openSettings:
                openSettings();
                break;
            // The workspace's own, answered above.
            case TermCommand.newTab, TermCommand.closeTab, TermCommand.nextTab,
                TermCommand.prevTab, TermCommand.goToTab, TermCommand.splitRight,
                TermCommand.splitDown, TermCommand.focusLeft, TermCommand.focusRight,
                TermCommand.focusUp, TermCommand.focusDown, TermCommand.resizeLeft,
                TermCommand.resizeRight, TermCommand.resizeUp, TermCommand.resizeDown,
                TermCommand.zoomPane,
                TermCommand.closePane, TermCommand.promptRerun, TermCommand.promptShell,
                TermCommand.promptClose, TermCommand.tabTree, TermCommand.openAbout,
                TermCommand.openLogs, TermCommand.openNotifications, TermCommand.showCredits:
                break;
        }
    }

    /// Opens the settings page, full-screen (`TSP6`).
    private void openSettings()
    {
        auto store = new TerminalSettingsStore;
        *store = TerminalSettingsStore.from(config);
        auto self = &this;
        settingsPage = new SettingsPage(store, (uint mask) {
            // The running value is the page's; apply it like a reload.
            self.config.effective = store.resolved;
            self.config.fileValue = store.fileValue;
            self.config.fileOverlay = store.fileOverlay;
            self.applyConfig(null);
            import settings_store : TerminalApply;

            if (mask & TerminalApply.font)
                self.fontPending = true;
        });
        host.surfaces.push(settingsPage);
        router.closeGuide();
    }

    /// The page's per-frame asks: the soft keyboard for a text field, a
    /// font size it changed.
    private void settingsFrame(H)(ref H h)
    {
        import sparkles.android.soft_input : showSoftKeyboard;

        if (settingsPage !is null)
        {
            if (settingsPage.wantsKeyboard)
            {
                settingsPage.wantsKeyboard = false;
                showSoftKeyboard();
                keyboardShown = true;
            }
            if (settingsPage.closed)
                settingsPage = null;
        }
        if (fontPending && startFontPt > 0 && defaultFontPx > 0)
        {
            fontPending = false;
            h.fontSize(defaultFontPx * config.effective.appearance.font.size / startFontPt);
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
                openTouchGuide();
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

    /// The touch guide at the leader (`TKM6`, `TKM7`), from `MENU` or the
    /// opener's `⋯` (`TSS16`): what it picks runs on the next frame, where
    /// the host is at hand.
    private void openTouchGuide()
    {
        import sparkles.android.soft_input : hideSoftKeyboard;

        // The guide is navigation first: the soft keyboard goes, or a phone
        // in landscape leaves it two rows (`TPG19`). Its search field brings
        // the keyboard back.
        hideSoftKeyboard();
        auto self = &this;
        auto guide = new TouchGuide(router.table, context, router.leader,
            (KeyCommand c) { self.pendingCommand = c; self.hasPending = true; });
        guide.onSearch = () {
            import sparkles.android.soft_input : showSoftKeyboard;

            cast(void) showSoftKeyboard();
        };
        host.surfaces.push(guide);
        host.invalidate();
    }

    private void onPointer(H)(ref H h, in PointerEvent p)
    {
        import sparkles.android.soft_input : showSoftKeyboard;

        if (p.action == PointerAction.press)
        {
            pinchBase = 0; // a new contact re-bases the next pinch
            return;
        }
        if (dividerGesture) // a divider's drag ends without a tap (`TSS10`)
            return;
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
        if (chip.tap(p.pos.x, p.pos.y))
            return;
        // The chrome takes its own taps: an exit prompt (`TSS2`), the opener
        // — whose `⋯` opens the guide (`TSS16`).
        if (host.tap(h, p.pos.x, p.pos.y))
        {
            if (host.takeGuideRequest())
                openTouchGuide();
            return;
        }
        // A tap on the selection or a handle shows its menu; elsewhere it
        // clears it and goes on (`TSE4`).
        if (selection.tap(p.pos))
        {
            host.invalidate();
            return;
        }
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
        if (dividerGesture) // the divider's drag (`TSS10`)
            return;
        const g = geometry(h);
        if (swipeKeyRow(g, w))
            return;
        if (selection.wheel(w.pos)) // a handle's or the menu's drag (`TSE4`)
            return;
        // Under a page the drag scrolls it (finger up: towards the end).
        if (host.scrollSurface(w.dy))
            return;
        // The pane the drag began in: an application tracking the mouse gets
        // wheel reports (a pager, an editor); otherwise the drag walks its
        // scrollback.
        int left, top;
        const id = host.paneAt(w.pos.x, w.pos.y, left, top);
        // An expanded exit prompt scrolls its command (`TSS2`).
        if (host.scrollBanner(w.pos.x, w.pos.y, w.dy))
            return;
        // A viewer pane scrolls its document (`TDV6`).
        if (host.scrollViewer(id ? id : host.ws.focused, w.dy))
            return;
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
        if (dividerGesture) // a held divider is no long-press (`TSS10`)
            return;
        // A long-press on a link, per `links.longPress` (`TPR5`); off by default,
        // when the long-press selects (`TSE1`).
        if (g.gesture == Gesture.longPress)
        {
            if (host.tapLink(g.pos.x, g.pos.y, longPress: true))
                return;
            if (selection.longPress(host, paneArea(geometry(h)), cellW, cellH, g.pos))
                host.invalidate();
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
        int chipHeight; // the Autofill chip's band, above the key row
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
        // A key is a touch target: 48 dp (`TOK7`), two cells at the least —
        // two cells alone were 35 dp at 440 dpi. Unless that leaves the
        // terminal fewer than 8 rows (a phone in landscape with the keyboard
        // up kept none): then two cells, as before.
        {
            import sparkles.android.activity : dpToPx;

            const twoCells = cellH * 2;
            int target = dpToPx(48) > twoCells ? dpToPx(48) : twoCells;
            const n = cast(int) keys.length;
            if ((bottom - g.top - n * target) / cellH < 8)
                target = twoCells;
            g.keyHeight = shown && keys.length ? target : 0;
        }
        g.keysHeight = cast(int) keys.length * g.keyHeight;
        g.chipHeight = chip.height(cellH, host.theme.targetRows);
        const paneHeight = bottom - g.top - g.keysHeight - g.chipHeight;
        g.paneCols = g.width / cellW > 0 ? g.width / cellW : 1;
        g.paneRows = paneHeight / cellH > 0 ? paneHeight / cellH : 1;
        g.keysTop = bottom - g.keysHeight;
        return g;
    }
}
