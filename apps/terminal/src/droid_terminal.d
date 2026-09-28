/**
The terminal as an Android app: `TerminalView` embedded as a pane, plus the
touch and window behavior a phone needs (docs/specs/terminal/android.md).

$(LIST
    * The pane follows the $(B content rect) — the window minus the system
        bars and the soft keyboard — so the prompt stays above the keyboard.
    * Touch is routed as gestures, never as raylib's emulated mouse: a tap
        raises the soft keyboard (`NOD8`), a drag scrolls (or becomes wheel
        reports when the application tracks the mouse), a pinch resizes the
        font.
    * The screen oracle (`NOD14`) writes the terminal's text for on-device
        tests when they ask for it.
)
*/
module droid_terminal;

version (Android):

import sparkles.input : Event, GestureEvent, Gesture, KeyEvent, match,
    PointerAction, PointerEvent, WheelEvent;
import sparkles.terminal_view.component : TerminalView;
import sparkles.ui.layout : Frame;
import sparkles.ui.widget : WidgetTree;

import screen_oracle : ScreenOracle;

/// The whole-surface Android component.
struct DroidTerminal
{
    TerminalView tv;
    ScreenOracle oracle;

    private float pinchBase = 0; // the font size a pinch started from

    @disable this(this);

    /// The frame's pre-render half: size the pane to the content rect, drain
    /// the pty, and decide whether to draw. See `TerminalView.frame`.
    WidgetTree view(H)(ref H h)
    {
        const pane = paneCells(h);
        tv.frame(h, pane.cols, pane.rows);
        oracle.frame(tv);
        return WidgetTree.init;
    }

    /// Keys go to the terminal as they are; touch becomes gestures here.
    void handle(H)(ref H h, in Event e)
    {
        e.match!(
            (in PointerEvent p) { onPointer(p); },
            (in WheelEvent w) { onWheel(w); },
            (in GestureEvent g) { onGesture(h, g); },
            (in _) { tv.handle(h, e); },
        );
    }

    /// The per-cell paint, into the pane under the status bar.
    void paint(H)(ref H h, in WidgetTree, in Frame[])
    {
        const pane = paneCells(h);
        tv.paintPanePx(h, 0, contentTopPx(), pane.cols * tv.s.cellWidth,
            pane.rows * tv.s.cellHeight);
    }

    // ── touch ───────────────────────────────────────────────────────────────

    private void onPointer(in PointerEvent p)
    {
        import sparkles.android.soft_input : showSoftKeyboard;

        // On a touch target a press/release pair IS a tap: the recogniser
        // turns a moving contact into wheel steps instead (`touchGestures`).
        if (p.action == PointerAction.press)
            pinchBase = 0; // a new contact re-bases the next pinch
        else if (p.action == PointerAction.release)
            showSoftKeyboard();
    }

    private void onWheel(in WheelEvent w)
    {
        // An application tracking the mouse gets wheel reports (a pager, an
        // editor); otherwise the drag walks the scrollback.
        if (!tv.sendWheel(w.dy, w.pos.x, w.pos.y))
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

    private static struct PaneCells
    {
        int cols, rows;
    }

    /// The pane in cells: the content rect's size over the cell size; the
    /// whole window until the framework has reported a content rect.
    private PaneCells paneCells(H)(ref H h)
    {
        import raylib : GetScreenHeight, GetScreenWidth;
        import sparkles.android.activity : contentRect;

        const cw = tv.s.cellWidth > 0 ? tv.s.cellWidth : 1;
        const ch = tv.s.cellHeight > 0 ? tv.s.cellHeight : 1;
        const r = contentRect();
        const w = r.right > r.left ? r.right - r.left : GetScreenWidth();
        const hgt = r.bottom > r.top ? r.bottom - r.top : GetScreenHeight();
        // Before `open` the cell size is unknown: the host's grid is the
        // right answer then, and `frame` opens the terminal at it.
        if (tv.s.cellWidth <= 0)
            return PaneCells(h.size.width, h.size.height);
        return PaneCells(w / cw > 0 ? w / cw : 1, hgt / ch > 0 ? hgt / ch : 1);
    }

    private static int contentTopPx() @system
    {
        import sparkles.android.activity : contentRect;

        const r = contentRect();
        return r.bottom > r.top ? r.top : 0;
    }
}
