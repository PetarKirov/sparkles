/**
The terminal as an Android app: `TerminalView` embedded as a pane, plus the
touch and window behavior a phone needs (docs/specs/terminal/android.md).

$(LIST
    * The pane follows the $(B content rect) — the window minus the system
        bars and the soft keyboard — so the prompt stays above the keyboard,
        and the extra-keys row (`NOD10`) sits between the two.
    * Touch is routed as gestures, never as raylib's emulated mouse: a tap
        raises the soft keyboard (`NOD8`) or presses an extra key, a drag
        scrolls (or becomes wheel reports when the application tracks the
        mouse), a pinch resizes the font. Positions arrive in pixels
        (`PointerUnit.pixels`): the key row is not on the cell grid.
    * The screen oracle (`NOD14`) writes the terminal's text for on-device
        tests when they ask for it.
)
*/
module droid_terminal;

version (Android):

import extra_keys : ExtraKey, ExtraKeyKind, Latch;
import sparkles.input : Event, GestureEvent, Gesture, Key, KeyAction, KeyEvent,
    match, PointerAction, PointerEvent, WheelEvent;
import sparkles.terminal_view.component : TerminalView, TerminalViewOptions;
import sparkles.ui.layout : Frame;
import sparkles.ui.widget : WidgetTree;

import screen_oracle : ScreenOracle;

/// The whole-surface Android component.
struct DroidTerminal
{
    TerminalView tv;
    ScreenOracle oracle;

    /// The session that replaces the current one when it ends — the login
    /// that follows the installer (`NOD7`). Unset, an ended session holds.
    TerminalViewOptions next;
    /// ditto
    bool hasNext;

    /// The extra-keys layout, rows top to bottom (`extra_keys.extraKeysFrom`).
    ExtraKey[][] keys;
    /// `~/.termux`, where the layout and the colour scheme live (`NOD10`,
    /// `NOD11`); `loadSettings` reads it, at start and on
    /// `termux-reload-settings`.
    string termuxDir;
    private Latch latch;
    private bool keyboardShown;
    private float pinchBase = 0; // the font size a pinch started from
    private Geometry lastGeometry;

    @disable this(this);

    /// The frame's pre-render half: size the pane to the content rect, drain
    /// the pty, and decide whether to draw. See `TerminalView.frame`.
    WidgetTree view(H)(ref H h)
    {
        // The installer's pty ended: the login session takes the pane over.
        // A fresh component, not a re-`open` of the old one — no scrollback,
        // overlay or exit bookkeeping of the installer's may leak into it.
        if (hasNext && tv.s.childExited)
        {
            tv.close();
            tv = TerminalView.init;
            tv.opts = next;
            hasNext = false;
        }

        import am_server : takeReloadRequest;

        if (takeReloadRequest())
            loadSettings();

        const g = geometry(h);
        // The key row moves with the keyboard even when the pane's cell grid
        // does not change (a sub-cell difference): repaint it anyway.
        if (g != lastGeometry)
        {
            lastGeometry = g;
            tv.invalidate();
        }
        tv.frame(h, g.paneCols, g.paneRows);
        oracle.frame(tv);
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
            (in _) { tv.handle(h, e); },
        );
    }

    /// The per-cell paint into the pane, then the key row under it.
    void paint(H)(ref H h, in WidgetTree, in Frame[])
    {
        const g = geometry(h);
        tv.paintPanePx(h, 0, g.top, g.paneCols * tv.s.cellWidth,
            g.paneRows * tv.s.cellHeight);
        paintKeys(g);
    }

    /**
    (Re)read `~/.termux`: the extra-keys layout, and the colour scheme for the
    running session and the one that follows it. A missing file means the
    defaults — deleting `colors.properties` and reloading restores them.
    */
    void loadSettings()
    {
        import extra_keys : extraKeysFrom;
        import termux_config : parseTermuxColors;

        keys = extraKeysFrom(readSetting("termux.properties"));
        const colors = parseTermuxColors(readSetting("colors.properties"));
        tv.recolor(colors);
        next.colors = colors;
        tv.invalidate();
    }

    private string readSetting(string name)
    {
        import std.file : exists, readText;
        import std.path : buildPath;
        import sparkles.base.logger : warning;

        if (termuxDir.length == 0)
            return "";
        const path = buildPath(termuxDir, name);
        try
            return path.exists ? readText(path) : "";
        catch (Exception e)
        {
            warning(i"terminal: unreadable $(path): $(e.msg)");
            return "";
        }
    }

    // ── keys ────────────────────────────────────────────────────────────────

    private void sendKey(H)(ref H h, in KeyEvent k)
    {
        const before = latch.any;
        auto chord = latch.apply(k);
        if (before != latch.any)
            tv.invalidate(); // the released latch's highlight goes
        tv.handle(h, Event(chord));
    }

    private void pressExtraKey(H)(ref H h, in ExtraKey key)
    {
        final switch (key.kind)
        {
            case ExtraKeyKind.modifier:
                latch.toggle(key.key);
                tv.invalidate();
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
        tv.handle(h, Event(ke));
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
        import sparkles.base.term_color : RgbColor;
        import sparkles.raylib_text.draw : drawText;
        import sparkles.raylib_text.style : TextStyle;
        import std.utf : count;

        if (keys.length == 0 || tv.s.fonts is null)
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
                const tx = x0 + (x1 - x0 - cols * tv.s.cellWidth) / 2;
                const ty = y + (g.keyHeight - tv.s.cellHeight) / 2;
                drawText(*tv.s.fonts, key.label, tx, ty, TextStyle.init,
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
        showSoftKeyboard();
        keyboardShown = true;
    }

    private void onWheel(H)(ref H h, in WheelEvent w)
    {
        const g = geometry(h);
        const cw = tv.s.cellWidth > 0 ? tv.s.cellWidth : 1;
        const ch = tv.s.cellHeight > 0 ? tv.s.cellHeight : 1;
        // An application tracking the mouse gets wheel reports (a pager, an
        // editor); otherwise the drag walks the scrollback.
        if (!tv.sendWheel(w.dy, w.pos.x / cw, (w.pos.y - g.top) / ch))
            tv.scrollViewport(w.dy);
    }

    private void onGesture(H)(ref H h, in GestureEvent g)
    {
        if (g.gesture != Gesture.pinch)
            return;
        if (pinchBase <= 0)
            pinchBase = h.fontSizePx;
        const px = cast(int)(pinchBase * g.scale + 0.5f);
        if (px >= 8 && px <= 96 && px != h.fontSizePx)
            h.fontSize(px);
    }

    // ── geometry ────────────────────────────────────────────────────────────

    /// The frame's layout, in pixels: the content rect, the pane at its top
    /// (whole cells), the key row filling the rest down to the keyboard.
    private static struct Geometry
    {
        int top, width, paneCols, paneRows;
        int keysTop, keysHeight, keyHeight;
    }

    private Geometry geometry(H)(ref H h)
    {
        import raylib : GetScreenHeight, GetScreenWidth;
        import sparkles.android.activity : contentRect;

        Geometry g;
        const r = contentRect();
        const valid = r.bottom > r.top && r.right > r.left;
        g.top = valid ? r.top : 0;
        g.width = valid ? r.right - r.left : GetScreenWidth();
        const bottom = valid ? r.bottom : GetScreenHeight();

        // Before `open` the cell size is unknown: the host's grid is the right
        // answer then, and `frame` opens the terminal at it.
        if (tv.s.cellWidth <= 0 || tv.s.cellHeight <= 0)
        {
            g.paneCols = h.size.width;
            g.paneRows = h.size.height;
            return g;
        }
        g.keyHeight = keys.length ? tv.s.cellHeight * 2 : 0;
        g.keysHeight = cast(int) keys.length * g.keyHeight;
        const paneHeight = bottom - g.top - g.keysHeight;
        g.paneCols = g.width / tv.s.cellWidth > 0 ? g.width / tv.s.cellWidth : 1;
        g.paneRows = paneHeight / tv.s.cellHeight > 0 ? paneHeight / tv.s.cellHeight : 1;
        g.keysTop = bottom - g.keysHeight;
        return g;
    }
}
