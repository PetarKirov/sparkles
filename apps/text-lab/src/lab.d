/**
The text lab: one specimen of everything the canvas draws text with — weights
and styles, digits and punctuation, scripts, combining marks, CJK, emoji and
their sequences, icons, box drawing — on a dark panel and a light one, with
the canvas's text-rendering settings switched live and a loupe that shows
the window's pixels exactly as they were composited: what the pointer is
over in one panel, magnified to fill the other, with a crosshair (`x`) on
the pixel it aims at while a mouse hovers or a finger is down.

The layout holds from a phone held upright (about 49 cells) to a desktop
window: a three-row header — the status and a Settings button, each row
of it a third of a 48 dp touch target — then both panels, their text
wrapped beside a narrow label column. Settings open as a sheet of
three-row segmented buttons: from the bottom on a narrow window, beside the
panels on a wide one, so the text stays in view as it changes. Every
setting also has its key.

The settings reach the canvas through the host's `textRendering` and `loupe`
errands, probed by introspection: on a host without them the specimen still
draws, and the header says the settings are not available.
*/
module lab;

import std.format : format;

import sparkles.base.term_color : RgbColor;
import sparkles.base.term_control : PointerShape;
import sparkles.base.term_style : TextAttr, UnderlineStyle;
import sparkles.base.text.grapheme : fitCells, visibleWidth;
import sparkles.input : Event, isEndOfInput, Key, KeyEvent, match, PointerAction, PointerEvent;
import sparkles.ui.geometry : Insets, Point, Rect, Size;
import sparkles.ui.style : BorderStyle, BoxBorder, Visual;
import sparkles.ui.widget : Builder, WidgetKind, WidgetTree;
import sparkles.ui_vulkan.painter : rgba;
import sparkles.ui_vulkan.text_rendering : Compositing, Hinting, Loupe, TextRendering;

/// The specimen, line by line: what each line shows, and the text.
immutable string[2][] specimen = [
    ["Latin", "The quick brown fox jumps over the lazy dog."],
    ["Shapes", "Hamburgefontsiv  il1I|  oO0  rn m  cl d  ,.;:'\""],
    ["Digits", "0123456789  +-*/=<>  ()[]{}  @#$%^&  ~`_\\"],
    ["Code", "-> => != === <= >= :: |> <| /* */ // www 0x1F"],
    ["Accents", "café naïve façade Ångström Øresund ŁÓDŹ ẞ"],
    ["Scripts", "Ωμέγα αβγδ  Привет мир  Tiếng Việt  Ğğ İı Şş"],
    ["Combining", "é ä ñ ô ç  Z̵̀a͓ḻg͔o"],
    ["CJK", "漢字 かな カナ 한국어 中文字体"],
    ["Emoji", "😀 😎 ❤️ ❤ ✨ 👍 👍🏽 🎉 🚀"],
    ["Sequences", "👩‍💻 👨‍👩‍👧 🇧🇬 1️⃣ #️⃣ ❤️‍🔥"],
    ["Icons", "       "],
    ["Symbols", "←→↑↓ ⇐⇒ ✓✗ ∑∫√∞≈≠ ±×÷ °§¶ ©®™ ½¾"],
    ["Box", "┌─┬─┐ ╔═╦═╗ ╭─╮ │ ├┼┤ ░▒▓█ ▁▂▃▄▅▆▇ ⣿⠿⠛"],
];

/// The header's rows: one 48 dp touch target at 16 dp cells.
enum int headerRows = 3;
/// Windows this many cells wide and wider open the settings beside the
/// panels; narrower ones, from the bottom (about 600 dp at 8 dp cells).
enum int sideSheetMinWidth = 90;
/// The side sheet's width in cells (360 dp).
enum int sideSheetWidth = 45;
/// The specimen's label column, in cells.
enum int labelWidth = 10;
/// The smallest pixel size the font steps down to so the panels fit.
enum int minFitPx = 8;

/// The lab's state.
struct Lab
{
    TextRendering settings;       /// what the canvas is asked to do
    Loupe loupe = Loupe(shown: true, sourceWidth: 40, sourceHeight: 24, scale: 8);
    string shotPath;              /// capture the first full frame here, then quit
    /// Where `p` saves a screenshot: the working directory when empty.
    string screenshotDir;
    /// Whether the settings sheet is open.
    bool sheetOpen;
    /// Whether lines cross at the pointer while it hovers or a finger is
    /// down: what the loupe magnifies, aimed to the pixel.
    bool crosshair;
    private int framesToShot = 3; // the font atlas and the window settle first
    private Point pointer = Point(-1, -1);
    private bool pointing; // a mouse hovers, or a finger is down
    private bool sentSettings;
    private bool userSized; // `+` or `-` was pressed: the size is theirs
    private PointerShape shape_ = PointerShape.default_;
    // What the last frame laid out, for a tap or click: the Settings
    // button, the sheet, and the sheet's buttons.
    private Rect settingsButton_;
    private Rect sheet_;
    private Button[] buttons_;

    /// No widgets: the header, panels and sheet are painted in `paint`,
    /// which also lays out what a tap can hit.
    WidgetTree view(H)(ref H h)
    {
        // `--shot`: a few frames for the atlas and the window to settle, then
        // the capture, then out.
        if (shotPath.length)
        {
            static if (__traits(hasMember, H, "screenshot"))
                if (--framesToShot == 0)
                    h.screenshot(shotPath);
            if (framesToShot < -2)
                h.quit();
            h.requestFrame();
        }
        auto b = Builder();
        return b.finish(b.container(WidgetKind.column, (uint[]).init));
    }

    /// The header, both panels below it, and the sheet when it is open.
    void paint(H)(ref H h, in WidgetTree, in Frame[])
    {
        static if (offersSettings!H)
        {
            if (!sentSettings)
            {
                h.textRendering(settings);
                sentSettings = true;
            }
            placeLoupe(h);
        }
        // The host's own canvas: the native host hands out a pointer, a
        // recorder its field, which a copy would record into instead.
        static if (is(typeof(h.canvas()) == C*, C))
            auto canvas = h.canvas();
        else
            auto canvas = &h.canvas;
        const size = h.size;
        // Until the user picks a size, the font steps down a pixel a frame
        // until both panels hold the whole specimen: a phone's 12 pt is a
        // row short.
        if (!userSized && h.fontSizePx > minFitPx && !fits(size))
        {
            h.fontSize(h.fontSizePx - 1);
            h.requestFrame();
        }
        header(h, canvas, size.width);
        const half = (size.height - headerRows) / 2;
        panel(canvas, Rect(0, headerRows, size.width, half), dark);
        panel(canvas, Rect(0, headerRows + half, size.width, size.height - headerRows - half), light);
        static if (__traits(compiles, canvas.fillPx(0, 0, 1, 1, rgba(accent, 255))))
            if (crosshair && pointing)
                drawCrosshair(h, canvas);
        buttons_ = null;
        sheet_ = Rect.init;
        static if (offersSettings!H)
            if (sheetOpen)
                sheet(h, canvas, size);
    }

    private void header(H, C)(ref H h, C canvas, int width)
    {
        canvas.fillRect(Rect(0, 0, width, headerRows), Visual(bg: headerBg, hasBg: true));
        static if (offersSettings!H)
        {
            enum buttonWidth = 12;
            settingsButton_ = Rect(width - buttonWidth, 0, buttonWidth, headerRows);
            const first = format("text lab · %spx · %s", h.fontSizePx,
                loupe.shown ? format("loupe ×%s", loupe.scale) : "loupe off");
            const second = format("compositing %s %.2f", settings.compositing, settings.contrast);
            const hint = format("hinting %s · shaping %s", settings.hinting, settings.shaping ? "on" : "off");
        }
        else
        {
            enum buttonWidth = 0;
            const first = format("text lab · %spx", h.fontSizePx);
            const second = "this host draws text its own way:";
            const hint = "the settings need the Vulkan arm (--gui)";
        }
        const room = width - buttonWidth - 2;
        canvas.textRun(Point(1, 0), clip(first, room), Visual(fg: ink, bg: headerBg, hasBg: true));
        canvas.textRun(Point(1, 1), clip(second, room), Visual(fg: muted, bg: headerBg, hasBg: true));
        canvas.textRun(Point(1, 2), clip(hint, room), Visual(fg: muted, bg: headerBg, hasBg: true));
        static if (offersSettings!H)
            button(canvas, settingsButton_, "≡ Settings", sheetOpen);
    }

    // Whether both panels hold the whole specimen at `size`.
    private static bool fits(in Size size)
    {
        const half = (size.height - headerRows) / 2;
        int rows;
        foreach (line; lines)
        {
            int r = 1;
            foreach (p; wrap(line.runs, size.width - labelWidth - 2))
                r = p.row + 1 > r ? p.row + 1 : r;
            rows += r;
        }
        return rows <= half;
    }

    // A panel: each specimen line's label in a narrow column, its text wrapped
    // beside it.
    private void panel(C)(C canvas, in Rect r, in Theme t)
    {
        canvas.fillRect(r, Visual(bg: t.bg, hasBg: true));
        const textX = r.x + 1 + labelWidth, textWidth = r.width - labelWidth - 2;
        const label = Visual(fg: t.label, bg: t.bg, hasBg: true);
        int y = r.y;
        foreach (line; lines)
        {
            if (y >= r.y + r.height)
                break;
            canvas.textRun(Point(r.x + 1, y), line.label, label);
            int rows = 1;
            foreach (p; wrap(line.runs, textWidth))
            {
                if (y + p.row >= r.y + r.height)
                    break;
                const run = line.runs[p.run];
                canvas.textRun(Point(textX + p.col, y + p.row), p.text, Visual(fg: t.ink(run.colour),
                    bg: t.bg, hasBg: true, styleBits: run.style, underline: run.underline));
                rows = p.row + 1 > rows ? p.row + 1 : rows;
            }
            y += rows;
        }
    }

    // The settings, as rows of three-row segmented buttons: a bottom sheet
    // over a scrim on a narrow window, a side sheet beside the panels on a
    // wide one.
    private void sheet(H, C)(ref H h, C canvas, in Size size)
    {
        const side = size.width >= sideSheetMinWidth;
        enum contentRows = 42;
        const avail = size.height - headerRows;
        sheet_ = side ? Rect(size.width - sideSheetWidth, headerRows, sideSheetWidth, avail)
            : Rect(0, size.height - (contentRows < avail ? contentRows : avail), size.width,
                contentRows < avail ? contentRows : avail);
        if (!side)
            canvas.fillRect(Rect(0, headerRows, size.width, avail),
                Visual(bg: RgbColor(0, 0, 0), bgAlpha: 140, hasBg: true));
        canvas.fillRect(sheet_, Visual(bg: sheetBg, hasBg: true, border: BoxBorder(
            width: side ? Insets(0, 0, 0, 1) : Insets(1, 0, 0, 0), style: BorderStyle.solid, color: edge)));

        const x = sheet_.x + 2, w = sheet_.width - 4;
        int y = sheet_.y + 1;
        canvas.textRun(Point(x, y), "Text rendering", Visual(fg: ink, bg: sheetBg, hasBg: true));
        const closes = "Esc closes";
        canvas.textRun(Point(x + w - cast(int) closes.length, y), closes, Visual(fg: muted, bg: sheetBg, hasBg: true));
        y += 2;

        void group(string title, Segment[] segments)
        {
            if (y + 4 > sheet_.y + sheet_.height)
                return;
            canvas.textRun(Point(x, y), title, Visual(fg: muted, bg: sheetBg, hasBg: true));
            int fixed, flexible;
            foreach (s; segments)
                s.width ? (fixed += s.width) : ++flexible;
            const gaps = cast(int) segments.length - 1;
            const share = flexible ? (w - fixed - gaps) / flexible : 0;
            int at = x;
            foreach (i, s; segments)
            {
                const last = i + 1 == segments.length;
                const sw = last ? x + w - at : s.width ? s.width : share;
                const r = Rect(at, y + 1, sw, 3);
                if (s.act.kind == ActKind.none)
                    value(canvas, r, s.label);
                else
                {
                    button(canvas, r, s.label, s.selected);
                    buttons_ ~= Button(r, s.act);
                }
                at += sw + 1;
            }
            y += 5;
        }

        group("c  Compositing", [
            Segment("gamma", Act(ActKind.compositing, Compositing.gamma), settings.compositing == Compositing.gamma),
            Segment("linear", Act(ActKind.compositing, Compositing.linear), settings.compositing == Compositing.linear),
            Segment("corrected", Act(ActKind.compositing, Compositing.linearCorrected),
                settings.compositing == Compositing.linearCorrected),
        ]);
        group("[ ]  Contrast", [
            Segment("−", Act(ActKind.key, '['), false, 8),
            Segment(format("%.2f", settings.contrast)),
            Segment("+", Act(ActKind.key, ']'), false, 8),
        ]);
        group("h  Hinting", [
            Segment("none", Act(ActKind.hinting, Hinting.none), settings.hinting == Hinting.none),
            Segment("light", Act(ActKind.hinting, Hinting.light), settings.hinting == Hinting.light),
        ]);
        group("s  Shaping", [
            Segment("off", Act(ActKind.shaping, 0), !settings.shaping),
            Segment("on", Act(ActKind.shaping, 1), settings.shaping),
        ]);
        group("m 1-4  Loupe", [
            Segment("off", Act(ActKind.key, 'm'), !loupe.shown),
            Segment("×4", Act(ActKind.key, '1'), loupe.shown && loupe.scale == 4),
            Segment("×6", Act(ActKind.key, '2'), loupe.shown && loupe.scale == 6),
            Segment("×8", Act(ActKind.key, '3'), loupe.shown && loupe.scale == 8),
            Segment("×12", Act(ActKind.key, '4'), loupe.shown && loupe.scale == 12),
        ]);
        group("x  Crosshair", [
            Segment("off", Act(ActKind.key, 'x'), !crosshair),
            Segment("on", Act(ActKind.key, 'x'), crosshair),
        ]);
        group("+ -  Size", [
            Segment("A−", Act(ActKind.key, '-'), false, 8),
            Segment(format("%s px", h.fontSizePx)),
            Segment("A+", Act(ActKind.key, '+'), false, 8),
        ]);
        if (y + 3 <= sheet_.y + sheet_.height)
        {
            const half = (w - 1) / 2;
            const shot = Rect(x, y, half, 3), quit = Rect(x + half + 1, y, w - half - 1, 3);
            button(canvas, shot, "p  Screenshot", false);
            button(canvas, quit, "q  Quit", false);
            buttons_ ~= Button(shot, Act(ActKind.key, 'p'));
            buttons_ ~= Button(quit, Act(ActKind.key, 'q'));
        }
    }

    // A three-row button: a bordered box, its label centred on the middle row.
    private static void button(C)(C canvas, in Rect r, string label, bool selected)
    {
        const bg = selected ? selectedBg : buttonBg;
        canvas.fillRect(r, Visual(bg: bg, hasBg: true, border: BoxBorder(width: Insets(1, 1, 1, 1),
            style: BorderStyle.solid, color: selected ? accent : edge)));
        centred(canvas, r, label, Visual(fg: ink, bg: bg, hasBg: true));
    }

    // A value between two buttons: a quiet box, its text centred.
    private static void value(C)(C canvas, in Rect r, string text)
    {
        canvas.fillRect(r, Visual(bg: sheetBg, hasBg: true, border: BoxBorder(width: Insets(1, 1, 1, 1),
            style: BorderStyle.solid, color: buttonBg)));
        centred(canvas, r, text, Visual(fg: ink, bg: sheetBg, hasBg: true));
    }

    private static void centred(C)(C canvas, in Rect r, string text, in Visual v)
    {
        const shown = clip(text, r.width - 2);
        const w = cast(int) visibleWidth(shown);
        canvas.textRun(Point(r.x + (r.width - w) / 2, r.y + r.height / 2), shown, v);
    }

    // The loupe magnifies the pixels around the pointer into the whole of
    // the other panel — the light one for a pointer over the dark, the dark
    // one otherwise — so it is as large as the window allows and never hides
    // what it shows. Its source is that panel's size over the zoom, kept
    // inside the panel the pointer is over. Clear of an open side sheet; a
    // bottom sheet covers the panels, and the loupe hides under it.
    private void placeLoupe(H)(ref H h)
    {
        const px = h.pixels, size = h.size, cw = h.cellWidth, ch = h.cellHeight;
        if (pointer.x < 0)
            pointer = Point(px.width / 4, px.height / 3);
        Loupe l = loupe;
        const side = size.width >= sideSheetMinWidth;
        if (sheetOpen && !side)
            l.shown = false;
        const room = sheetOpen && side ? (size.width - sideSheetWidth) * cw : px.width;
        const half = (size.height - headerRows) / 2;
        const darkTop = headerRows * ch, lightTop = (headerRows + half) * ch;
        const overDark = pointer.y < lightTop;
        // The panels' pixel rows: the dark one's, then the light one's, which
        // ends at the window's last whole cell.
        const sourceTop = overDark ? darkTop : lightTop;
        const sourceBottom = overDark ? lightTop : size.height * ch;
        const destTop = overDark ? lightTop : darkTop;
        const destBottom = overDark ? size.height * ch : lightTop;
        enum margin = 8;
        const s = l.scale > 0 ? l.scale : 1;
        // A wide window (a tablet) gives it half the width, on the pointer's
        // side, straight above or below what it magnifies.
        const halfWidth = side && room >= 2 * px.width / 3;
        const width = halfWidth ? room / 2 : room;
        const left = halfWidth && pointer.x >= room / 2 ? room / 2 : 0;
        l.sourceWidth = (width - 2 * margin) / s;
        l.sourceHeight = (destBottom - destTop - 2 * margin) / s;
        static int clamp(int v, int lo, int hi) => v < lo ? lo : v > hi ? hi : v;
        l.sourceX = clamp(pointer.x - l.sourceWidth / 2, 0, room - l.sourceWidth);
        l.sourceY = clamp(pointer.y - l.sourceHeight / 2, sourceTop, sourceBottom - l.sourceHeight);
        l.x = left + margin;
        l.y = destTop + margin;
        h.loupe(l);
    }

    // Lines through the pointer across the panels, broken around the pixel it
    // aims at, so the loupe shows that pixel exactly as it was drawn.
    private void drawCrosshair(H, C)(ref H h, C canvas)
    {
        const cw = h.cellWidth, ch = h.cellHeight, size = h.size;
        const room = sheetOpen && size.width >= sideSheetMinWidth ? (size.width - sideSheetWidth) * cw
            : h.pixels.width;
        const top = headerRows * ch, bottom = size.height * ch;
        enum gap = 3;
        const c = rgba(accent, 200);
        const x = pointer.x, y = pointer.y;
        if (x - gap > 0)
            canvas.fillPx(0, y, x - gap, 1, c);
        if (x + gap + 1 < room)
            canvas.fillPx(x + gap + 1, y, room - x - gap - 1, 1, c);
        if (y - gap > top)
            canvas.fillPx(x, top, 1, y - gap - top, c);
        if (y + gap + 1 < bottom)
            canvas.fillPx(x, y + gap + 1, 1, bottom - y - gap - 1, c);
    }

    /// Points the loupe at pixel `p`, as the pointer would.
    void pointAt(Point p) @safe pure nothrow @nogc
    {
        pointer = p;
    }

    /**
    Keys switch the settings, Esc or Back closes the sheet; a tap or click
    on Settings opens it and on a button does what it says; pointer motion,
    or a drag, over the panels moves the loupe.
    */
    void handle(H)(ref H h, in Event e)
    {
        if (isEndOfInput(e))
            return h.quit();
        e.match!(
            (in KeyEvent k) {
                if (k.key == Key.escape || k.key == Key.back)
                {
                    if (sheetOpen)
                        return toggleSheet(h);
                    if (k.key == Key.back)
                        return h.quit();
                    return;
                }
                command(h, k.ch);
            },
            (in PointerEvent p) {
                const cell = cellOf(h, p.pos);
                // A hand over what a click does something to, the arrow elsewhere
                // (a mouse or stylus pointer; on Android 7+ too).
                const shape = overButton(cell) ? PointerShape.pointer : PointerShape.default_;
                if (shape != shape_)
                {
                    shape_ = shape;
                    h.pointerShape(shape);
                }
                if (p.action == PointerAction.press)
                {
                    if (settingsButton_.contains(cell))
                        return toggleSheet(h);
                    if (sheetOpen && sheet_.contains(cell))
                    {
                        foreach (b; buttons_)
                            if (b.rect.contains(cell))
                                return apply(h, b.act);
                        return;
                    }
                    // A tap on the scrim closes a bottom sheet.
                    if (sheetOpen && sheet_.width == h.size.width)
                        return toggleSheet(h);
                }
                if (p.action == PointerAction.release || p.action == PointerAction.leave)
                {
                    if (pointing)
                        h.requestFrame();
                    pointing = false;
                    return;
                }
                // Only the panels aim the loupe: not the header, not the sheet.
                if (cell.y < headerRows || (sheetOpen && sheet_.contains(cell)))
                    return;
                pointer = p.pos;
                pointing = true;
                h.requestFrame();
            },
            (in _) {},
        );
    }

    // Whether `cell` is on a control: Settings, or a button of the open sheet.
    private bool overButton(Point cell) const
    {
        if (settingsButton_.contains(cell))
            return true;
        if (sheetOpen)
            foreach (b; buttons_)
                if (b.rect.contains(cell))
                    return true;
        return false;
    }

    private void toggleSheet(H)(ref H h)
    {
        sheetOpen = !sheetOpen;
        h.requestFrame();
    }

    // The cell under `at`: the pointer is in pixels where the host reports
    // cell sizes, in cells where it does not.
    private static Point cellOf(H)(ref H h, Point at)
    {
        static if (__traits(hasMember, H, "cellWidth"))
            return Point(at.x / (h.cellWidth > 0 ? h.cellWidth : 1), at.y / (h.cellHeight > 0 ? h.cellHeight : 1));
        else
            return at;
    }

    private void apply(H)(ref H h, in Act act)
    {
        final switch (act.kind)
        {
            case ActKind.none:
                return;
            case ActKind.key:
                return command(h, cast(dchar) act.value);
            case ActKind.compositing:
                settings.compositing = cast(Compositing) act.value;
                break;
            case ActKind.hinting:
                settings.hinting = cast(Hinting) act.value;
                break;
            case ActKind.shaping:
                settings.shaping = act.value != 0;
                break;
        }
        changed(h);
    }

    private void command(H)(ref H h, dchar ch)
    {
        switch (ch)
        {
            case 'q':
                return h.quit();
            case 'c':
                settings.compositing = cast(Compositing)((settings.compositing + 1) % (Compositing.max + 1));
                break;
            case '[':
                settings.contrast = settings.contrast > 0.05f ? settings.contrast - 0.05f : 0;
                break;
            case ']':
                settings.contrast = settings.contrast < 0.95f ? settings.contrast + 0.05f : 1;
                break;
            case 'h':
                settings.hinting = settings.hinting == Hinting.none ? Hinting.light : Hinting.none;
                break;
            case 's':
                settings.shaping = !settings.shaping;
                break;
            case 'm':
                loupe.shown = !loupe.shown;
                break;
            case 'x':
                crosshair = !crosshair;
                break;
            case '1': .. case '4':
                static immutable int[4] scales = [4, 6, 8, 12];
                loupe.scale = scales[ch - '1'];
                loupe.shown = true;
                break;
            case '+', '=':
                userSized = true;
                h.fontSize(h.fontSizePx + 1);
                break;
            case '-':
                userSized = true;
                h.fontSize(h.fontSizePx > 6 ? h.fontSizePx - 1 : 6);
                break;
            case 'p':
                static if (__traits(hasMember, H, "screenshot"))
                {
                    import std.path : buildPath;

                    h.screenshot(screenshotDir.length ? buildPath(screenshotDir, "text-lab.png") : "text-lab.png");
                }
                break;
            default:
                return;
        }
        changed(h);
    }

    // Before the frame that shows them: `paint` runs after the frame has
    // begun, which would leave part of it in the old settings.
    private void changed(H)(ref H h)
    {
        static if (offersSettings!H)
            h.textRendering(settings);
        h.requestFrame();
    }
}

import sparkles.ui.layout : Frame;

/// Whether host `H` takes the canvas's text-rendering settings and a loupe.
enum bool offersSettings(H) = __traits(compiles, (ref H h) {
    h.textRendering(TextRendering.init);
    h.loupe(Loupe.init);
});

// ── the palette ─────────────────────────────────────────────────────────────

private enum RgbColor headerBg = RgbColor(0x11, 0x11, 0x1b);
private enum RgbColor sheetBg = RgbColor(0x18, 0x18, 0x25);
private enum RgbColor buttonBg = RgbColor(0x31, 0x32, 0x44);
private enum RgbColor selectedBg = RgbColor(0x45, 0x47, 0x5a);
private enum RgbColor edge = RgbColor(0x58, 0x5b, 0x70);
private enum RgbColor accent = RgbColor(0x89, 0xb4, 0xfa);
private enum RgbColor ink = RgbColor(0xcd, 0xd6, 0xf4);
private enum RgbColor muted = RgbColor(0x93, 0x99, 0xb2);

/// A panel's colours.
private struct Theme
{
    RgbColor bg, fg, label, red, green, blue;

    RgbColor ink(ubyte colour) const @safe pure nothrow @nogc
        => colour == 1 ? red : colour == 2 ? green : colour == 3 ? blue : fg;
}

private immutable Theme dark = Theme(RgbColor(0x1e, 0x1e, 0x2e), RgbColor(0xcd, 0xd6, 0xf4),
    RgbColor(0x8a, 0x8f, 0xa8), RgbColor(0xf3, 0x8b, 0xa8), RgbColor(0xa6, 0xe3, 0xa1),
    RgbColor(0x89, 0xb4, 0xfa));
private immutable Theme light = Theme(RgbColor(0xfa, 0xfa, 0xf7), RgbColor(0x1f, 0x23, 0x28),
    RgbColor(0x6a, 0x6e, 0x73), RgbColor(0xc0, 0x1c, 0x28), RgbColor(0x1a, 0x7f, 0x37),
    RgbColor(0x09, 0x69, 0xda));

// ── the specimen, as styled runs ────────────────────────────────────────────

/// Text in one style: its attributes, and its colour (0 the panel's ink,
/// then red, green and blue).
private struct Run
{
    string text;
    ushort style;
    UnderlineStyle underline;
    ubyte colour;
}

/// A specimen line: its label and its runs.
private struct Line
{
    string label;
    immutable(Run)[] runs;
}

private immutable Line[] lines = () {
    Line[] all;
    foreach (row; specimen)
        all ~= Line(row[0], [Run(row[1])]);
    all ~= Line("Styles", [Run("regular "), Run("bold", TextAttr.bold.bits), Run(" "),
        Run("italic", TextAttr.italic.bits), Run(" "),
        Run("bold italic", cast(ushort)(TextAttr.bold.bits | TextAttr.italic.bits)), Run(" "),
        Run("underline", 0, UnderlineStyle.single), Run(" "), Run("strike", TextAttr.strikethrough.bits)]);
    all ~= Line("Colour", [Run("red", 0, UnderlineStyle.none, 1), Run(" "),
        Run("green", 0, UnderlineStyle.none, 2), Run(" "),
        Run("blue — thin strokes on colour: illegible, minimum, Mississippi", 0, UnderlineStyle.none, 3)]);
    return all.idup;
}();

/// Where a piece of a run landed when wrapped: its row and column, its text,
/// and which run it is from.
private struct Piece
{
    int row, col;
    string text;
    size_t run;
}

/**
Lays `runs` out on rows `width` cells wide: a word moves to the next row
when it does not fit on this one, and a word wider than a row is split
between grapheme clusters — never inside one, so an emoji sequence or a
letter and its marks stay whole. Spaces only advance; none starts a row.
*/
private Piece[] wrap(in Run[] runs, int width)
{
    Piece[] pieces;
    int row, col;
    foreach (r, run; runs)
    {
        string rest = run.text;
        while (rest.length)
        {
            const space = rest[0] == ' ';
            size_t n;
            while (n < rest.length && (rest[n] == ' ') == space)
                ++n;
            string token = rest[0 .. n];
            rest = rest[n .. $];
            if (space)
            {
                if (col == 0)
                    continue;
                if (col + cast(int) n >= width)
                {
                    ++row;
                    col = 0;
                }
                else
                    col += cast(int) n;
                continue;
            }
            int w = cast(int) visibleWidth(token);
            if (col > 0 && col + w > width)
            {
                ++row;
                col = 0;
            }
            while (w > width - col && width > 0)
            {
                const fit = fitCells(token, width - col);
                if (fit.bytes == 0)
                {
                    if (col == 0)
                        break; // one cluster wider than a row: it overhangs
                    ++row;
                    col = 0;
                    continue;
                }
                pieces ~= Piece(row, col, token[0 .. fit.bytes], r);
                token = token[fit.bytes .. $];
                ++row;
                col = 0;
                w = cast(int) visibleWidth(token);
            }
            if (token.length)
            {
                pieces ~= Piece(row, col, token, r);
                col += w;
            }
        }
    }
    return pieces;
}

// `text`'s whole-cluster prefix that fits in `cells`.
private string clip(string text, int cells)
    => cells <= 0 ? null : text[0 .. fitCells(text, cells).bytes];

// ── the sheet's controls ────────────────────────────────────────────────────

private enum ActKind : ubyte
{
    none,        // a value shown between buttons
    key,         // what the key `value` does
    compositing, // the compositing `value`
    hinting,     // the hinting `value`
    shaping,     // shaping off (0) or on
}

/// What a button does.
private struct Act
{
    ActKind kind;
    int value;
}

/// A segment of a settings row: its label, what it does (`none`: a value
/// shown, not a button), whether it is the current choice, and a fixed width
/// in cells (0: an equal share of the rest).
private struct Segment
{
    string label;
    Act act;
    bool selected;
    int width;
}

/// A button the last frame drew, for hit testing.
private struct Button
{
    Rect rect;
    Act act;
}

version (unittest)
{
    import sparkles.input : charEvent;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : runAppRecorded;
}

@("text_lab.keysSwitchTheSettings")
@system unittest
{
    Lab lab;
    const before = lab.settings;
    cast(void) runAppRecorded(lab, RunConfig.init, [charEvent('c'), charEvent('h'), charEvent('s'),
        charEvent(']'), charEvent('m'), charEvent('2')]);
    assert(lab.settings.compositing != before.compositing, "c cycles the compositing");
    assert(lab.settings.hinting != before.hinting, "h toggles hinting");
    assert(lab.settings.shaping != before.shaping, "s toggles shaping");
    assert(lab.settings.contrast > before.contrast, "] raises the contrast");
    assert(lab.loupe.shown && lab.loupe.scale == 6, "m hides the loupe, 2 shows it at ×6");
}

@("text_lab.aHostWithoutTheSettingsStillDrawsTheSpecimen")
@system unittest
{
    // The recorder has no text-rendering errands: the header says so, and
    // the specimen is still painted on its canvas.
    static assert(!offersSettings!RecordingHost);
    Lab lab;
    auto rec = runAppRecorded(lab, RunConfig.init, []);
    assert(rec.canvas.ops.length > specimen.length, "both panels' lines were drawn");
}

@("text_lab.wrap.movesWordsAndSplitsOnlyBetweenClusters")
@system unittest
{
    assert(wrap([Run("ab cde f")], 5) == [Piece(0, 0, "ab", 0), Piece(1, 0, "cde", 0), Piece(1, 4, "f", 0)]);
    assert(wrap([Run("abcdefgh")], 3) == [Piece(0, 0, "abc", 0), Piece(1, 0, "def", 0), Piece(2, 0, "gh", 0)]);
    // Wide clusters: two cells each, never cut in half.
    assert(wrap([Run("漢字漢")], 3) == [Piece(0, 0, "漢", 0), Piece(1, 0, "字", 0), Piece(2, 0, "漢", 0)]);
    // A run boundary is not a word boundary, and spaces begin no row.
    assert(wrap([Run("red"), Run(" "), Run("green")], 5) == [Piece(0, 0, "red", 0), Piece(1, 0, "green", 2)]);
}

/// A host with the settings errands, over the recorder, to drive the sheet.
version (unittest) private struct SettingsHost
{
    RecordingHost rec;
    alias rec this;
    TextRendering rendering;
    Loupe shownLoupe;

    void textRendering(in TextRendering t) { rendering = t; }
    void loupe(in Loupe l) { shownLoupe = l; }
    Size pixels() const => Size(rec.size.width, rec.size.height);
    int cellWidth() const => 1;
    int cellHeight() const => 1;
}

@("text_lab.theSheetOpensAndItsButtonsSet")
@system unittest
{
    import sparkles.ui.widget : WidgetTree;

    // Narrow (a phone, 49 cells): Settings opens a bottom sheet; its
    // hinting `none` button sets the hinting; Back closes it.
    Lab lab;
    SettingsHost h;
    h.rec.size = Size(49, 51);
    void frame()
    {
        auto tree = lab.view(h);
        lab.paint(h, tree, null);
    }

    frame();
    const settings = lab.settingsButton_;
    assert(settings.height == headerRows && settings.x + settings.width == 49);
    lab.handle(h, Event(PointerEvent(action: PointerAction.press, pos: Point(settings.x + 1, 1))));
    assert(lab.sheetOpen);
    frame();
    assert(lab.sheet_.width == 49 && lab.sheet_.y > headerRows, "a bottom sheet");
    Rect none;
    foreach (b; lab.buttons_)
        if (b.act == Act(ActKind.hinting, Hinting.none))
            none = b.rect;
    assert(none.height == 3, "every button is a 48 dp target");
    lab.handle(h, Event(PointerEvent(action: PointerAction.press, pos: Point(none.x + 1, none.y + 1))));
    assert(lab.settings.hinting == Hinting.none && h.rendering.hinting == Hinting.none);
    lab.handle(h, Event(KeyEvent(key: Key.back)));
    assert(!lab.sheetOpen, "Back closes the sheet");

    // Wide (a tablet, 100 cells): the sheet opens beside the panels.
    h.rec.size = Size(100, 78);
    lab.sheetOpen = true;
    frame();
    assert(lab.sheet_.x == 100 - sideSheetWidth && lab.sheet_.y == headerRows, "a side sheet");
    assert(h.shownLoupe.x + h.shownLoupe.sourceWidth * h.shownLoupe.scale <= lab.sheet_.x,
        "the loupe stays clear of it");
}

@("text_lab.theLoupeFillsTheOtherPanel")
@system unittest
{
    // A phone's 49×51 cells, one pixel each here: the panels are rows 3–26
    // (dark) and 27–50 (light). What the pointer is over in one is magnified
    // across the whole width of the other, never over itself.
    Lab lab;
    SettingsHost h;
    h.rec.size = Size(49, 51);
    void frame()
    {
        auto tree = lab.view(h);
        lab.paint(h, tree, null);
    }

    lab.pointAt(Point(12, 17)); // over the dark panel
    frame();
    auto l = h.shownLoupe;
    assert(l.y >= 27 && l.y + l.sourceHeight * l.scale <= 51, "drawn in the light panel");
    assert(l.sourceY >= 3 && l.sourceY + l.sourceHeight <= 27, "taken from the dark one");
    assert(l.x == 8 && l.x + l.sourceWidth * l.scale > 49 - 8 - l.scale, "as wide as the window allows");

    lab.pointAt(Point(10, 40)); // over the light panel
    frame();
    l = h.shownLoupe;
    assert(l.y >= 3 && l.y + l.sourceHeight * l.scale <= 27, "drawn in the dark panel");
    assert(l.sourceY >= 27, "taken from the light one");

    // The crosshair is an option, `x`, shown while pointing.
    lab.handle(h, Event(KeyEvent(ch: 'x')));
    assert(lab.crosshair);
    lab.handle(h, Event(PointerEvent(action: PointerAction.press, pos: Point(20, 30))));
    assert(lab.pointing && lab.pointer == Point(20, 30));
    lab.handle(h, Event(PointerEvent(action: PointerAction.release, pos: Point(20, 30))));
    assert(!lab.pointing, "a lifted finger hides it");
    lab.handle(h, Event(PointerEvent(action: PointerAction.press, pos: Point(20, 1))));
    assert(lab.pointer == Point(20, 30), "the header does not aim the loupe");

    // A tablet (100 cells): half the width, on the pointer's side.
    h.rec.size = Size(100, 78);
    lab.pointAt(Point(20, 20));
    frame();
    l = h.shownLoupe;
    assert(l.x == 8 && l.sourceWidth * l.scale <= 50 - 16, "the left half, under the pointer");
    lab.pointAt(Point(80, 20));
    frame();
    l = h.shownLoupe;
    assert(l.x == 58 && l.x + l.sourceWidth * l.scale <= 100 - 8, "the right half");
}

@("text_lab.theFontStepsDownUntilThePanelsHoldTheSpecimen")
@system unittest
{
    // A phone's 49×51 cells hold one row fewer than the wrapped specimen
    // needs: the font steps down a pixel; a tablet's 100×78 needs none; and
    // once the user picks a size, it is theirs.
    assert(!Lab.fits(Size(49, 51)) && Lab.fits(Size(49, 53)) && Lab.fits(Size(100, 78)));
    Lab lab;
    SettingsHost h;
    h.rec.size = Size(49, 51);
    auto tree = lab.view(h);
    lab.paint(h, tree, null);
    assert(h.rec.fontSizeRequests == [17]);
    h.rec.size = Size(100, 78);
    lab.paint(h, tree, null);
    assert(h.rec.fontSizeRequests == [17], "it fits: nothing more");
    lab.handle(h, Event(KeyEvent(ch: '+')));
    h.rec.size = Size(49, 51);
    lab.paint(h, tree, null);
    assert(h.rec.fontSizeRequests == [17, 18], "after `+`, the size is the user's");
}

@("text_lab.aHandOverControls")
@system unittest
{
    // A pointer over Settings shows a hand, and the arrow again off it — the
    // shape asked for once per change.
    Lab lab;
    SettingsHost h;
    h.rec.size = Size(49, 51);
    auto tree = lab.view(h);
    lab.paint(h, tree, null);
    const s = lab.settingsButton_;
    lab.handle(h, Event(PointerEvent(action: PointerAction.move, pos: Point(s.x + 1, 1))));
    lab.handle(h, Event(PointerEvent(action: PointerAction.move, pos: Point(s.x + 2, 1))));
    lab.handle(h, Event(PointerEvent(action: PointerAction.move, pos: Point(5, 20))));
    assert(h.rec.shapes == [PointerShape.pointer, PointerShape.default_]);
}
