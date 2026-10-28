/**
The text lab: one specimen of everything the canvas draws text with — weights
and styles, digits and punctuation, scripts, combining marks, CJK, emoji and
their sequences, icons, box drawing — on a dark panel and a light one, with
the canvas's text-rendering settings switched live and a loupe that shows
the window's pixels exactly as they were composited.

The settings reach the canvas through the host's `textRendering` and `loupe`
errands, probed by introspection: on a host without them the specimen still
draws, and the header says the settings are not available.
*/
module lab;

import std.format : format;

import sparkles.base.term_color : RgbColor;
import sparkles.base.term_style : TextAttr, UnderlineStyle;
import sparkles.input : Event, isEndOfInput, KeyEvent, match, PointerAction, PointerEvent;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.style : Slot, Visual;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui_vulkan.text_rendering : Compositing, Hinting, Loupe, TextRendering;

/// The specimen, line by line: what each line shows, and the text.
immutable string[2][] specimen = [
    ["Latin", "The quick brown fox jumps over the lazy dog."],
    ["Shapes", "Hamburgefontsiv  il1I|  oO0  rn m  cl d  ,.;:'\""],
    ["Digits", "0123456789  +-*/=<>  ()[]{}  @#$%^&  ~`_\\"],
    ["Code", "-> => != === <= >= :: |> <| /* */ // www 0x1F"],
    ["Accents", "café naïve façade Ångström Øresund ŁÓDŹ ẞ"],
    ["Scripts", "Ωμέγα αβγδ  Привет мир  Tiếng Việt  Ğğ İı Şş"],
    ["Combining", "é ä ñ ô ç  Z̵̀a͓ḻg͔o"],
    ["CJK", "漢字 かな カナ 한국어 中文字体"],
    ["Emoji", "😀 😎 ❤️ ❤ ✨ 👍 👍🏽 🎉 🚀"],
    ["Sequences", "👩‍💻 👨‍👩‍👧 🇧🇬 1️⃣ #️⃣ ❤️‍🔥"],
    ["Icons", "       "],
    ["Symbols", "←→↑↓ ⇐⇒ ✓✗ ∑∫√∞≈≠ ±×÷ °§¶ ©®™ ½¾"],
    ["Box", "┌─┬─┐ ╔═╦═╗ ╭─╮ │ ├┼┤ ░▒▓█ ▁▂▃▄▅▆▇ ⣿⠿⠛"],
];

/// The lab's state.
struct Lab
{
    TextRendering settings;       /// what the canvas is asked to do
    Loupe loupe = Loupe(shown: true, sourceWidth: 40, sourceHeight: 24, scale: 8);
    string shotPath;              /// capture the first full frame here, then quit
    private int framesToShot = 3; // the font atlas and the window settle first
    private Point pointer = Point(-1, -1);
    private bool sentSettings;

    /// The header, as widgets; the panels are painted in `paint`.
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
        auto status = b.add(Widget(kind: WidgetKind.text, text: statusLine(h), slot: Slot.code));
        auto keys = b.add(Widget(kind: WidgetKind.text, slot: Slot.muted,
            text: "c compositing   [ ] contrast   h hinting   s shaping   m loupe   1-4 loupe zoom"
                ~ "   + - size   p screenshot   q quit"));
        return b.finish(b.container(WidgetKind.column, [status, keys]));
    }

    private string statusLine(H)(ref H h)
    {
        static if (offersSettings!H)
            return format("text lab — %spx — compositing %s (contrast %.2f) — hinting %s — shaping %s — loupe %s×%s",
                h.fontSizePx, settings.compositing, settings.contrast, settings.hinting,
                settings.shaping ? "on" : "off", loupe.shown ? "" : "off ", loupe.scale);
        else
            return format("text lab — %spx — this host draws text its own way: the settings need the Vulkan arm (--gui)",
                h.fontSizePx);
    }

    /// The specimen on a dark panel and a light one, below the header.
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
        const size = h.size;
        const half = (size.height - 3) / 2;
        panel(h, Rect(0, 3, size.width, half), RgbColor(0x1e, 0x1e, 0x2e), RgbColor(0xcd, 0xd6, 0xf4),
            RgbColor(0xf3, 0x8b, 0xa8), RgbColor(0xa6, 0xe3, 0xa1), RgbColor(0x89, 0xb4, 0xfa));
        panel(h, Rect(0, 3 + half, size.width, size.height - 3 - half), RgbColor(0xfa, 0xfa, 0xf7),
            RgbColor(0x1f, 0x23, 0x28), RgbColor(0xc0, 0x1c, 0x28), RgbColor(0x1a, 0x7f, 0x37),
            RgbColor(0x09, 0x69, 0xda));
    }

    private void panel(H)(ref H h, in Rect r, RgbColor bg, RgbColor fg, RgbColor red, RgbColor green,
        RgbColor blue)
    {
        // The host's own canvas: the native host hands out a pointer, a
        // recorder its field, which a copy would record into instead.
        static if (is(typeof(h.canvas()) == C*, C))
            auto canvas = h.canvas();
        else
            auto canvas = &h.canvas;
        canvas.fillRect(r, Visual(bg: bg, hasBg: true));
        Visual ink(RgbColor c, ushort style = 0, UnderlineStyle underline = UnderlineStyle.none)
            => Visual(fg: c, bg: bg, hasBg: true, styleBits: style, underline: underline);
        int y = r.y + 1;
        void line(int x, string text, in Visual v)
        {
            if (y < r.y + r.height)
                canvas.textRun(Point(x, y), text, v);
        }
        const label = ink(RgbColor(cast(ubyte)((fg.r + bg.r) / 2), cast(ubyte)((fg.g + bg.g) / 2),
            cast(ubyte)((fg.b + bg.b) / 2)));
        foreach (row; specimen)
        {
            line(2, row[0], label);
            line(13, row[1], ink(fg));
            ++y;
        }
        // Styles and colours: what the cell font's faces and the ink do.
        line(2, "Styles", label);
        int x = 13;
        foreach (s; [["regular", "0"], ["bold", "1"], ["italic", "2"], ["bold italic", "3"]])
        {
            const bits = cast(ushort)((s[1] == "1" || s[1] == "3" ? TextAttr.bold.bits : 0)
                | (s[1] == "2" || s[1] == "3" ? TextAttr.italic.bits : 0));
            line(x, s[0], ink(fg, bits));
            x += cast(int) s[0].length + 2;
        }
        line(x, "underline", ink(fg, 0, UnderlineStyle.single));
        x += 11;
        line(x, "strike", ink(fg, TextAttr.strikethrough.bits));
        ++y;
        line(2, "Colour", label);
        line(13, "red", ink(red));
        line(17, "green", ink(green));
        line(23, "blue", ink(blue));
        line(28, "— thin strokes on colour: illegible, minimum, Mississippi", ink(blue));
    }

    // The loupe follows the pointer, magnifying the pixels around it into
    // the panel's top-right corner, or its top-left when the pointer is there.
    private void placeLoupe(H)(ref H h)
    {
        if (pointer.x < 0)
        {
            const px = h.pixels;
            pointer = Point(px.width / 4, px.height / 3);
        }
        const px = h.pixels;
        Loupe l = loupe;
        l.sourceX = pointer.x - l.sourceWidth / 2;
        l.sourceY = pointer.y - l.sourceHeight / 2;
        const w = l.sourceWidth * l.scale, top = 3 * h.cellHeight;
        l.x = pointer.x > px.width / 2 ? 8 : px.width - w - 8;
        l.y = top + 8;
        h.loupe(l);
    }

    /// Points the loupe at pixel `p`, as the pointer would.
    void pointAt(Point p) @safe pure nothrow @nogc
    {
        pointer = p;
    }

    /// Keys switch the settings; pointer motion moves the loupe.
    void handle(H)(ref H h, in Event e)
    {
        if (isEndOfInput(e))
            return h.quit();
        e.match!(
            (in KeyEvent k) { key(h, k); },
            (in PointerEvent p) {
                if (p.action == PointerAction.move || p.action == PointerAction.press)
                {
                    pointer = p.pos;
                    h.requestFrame();
                }
            },
            (in _) {},
        );
    }

    private void key(H)(ref H h, in KeyEvent k)
    {
        switch (k.ch)
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
            case '1': .. case '4':
                static immutable int[4] scales = [4, 6, 8, 12];
                loupe.scale = scales[k.ch - '1'];
                break;
            case '+', '=':
                h.fontSize(h.fontSizePx + 1);
                break;
            case '-':
                h.fontSize(h.fontSizePx > 6 ? h.fontSizePx - 1 : 6);
                break;
            case 'p':
                static if (__traits(hasMember, H, "screenshot"))
                    h.screenshot("text-lab.png");
                break;
            default:
                return;
        }
        // Before the frame that shows them: `paint` runs after the header
        // has drawn, which would leave it in the old settings.
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
    assert(!lab.loupe.shown && lab.loupe.scale == 6, "m hides the loupe, 2 picks its zoom");
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
