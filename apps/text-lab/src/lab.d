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
import sparkles.base.buffer : UniqueBuffer;
import font_settings : LabSettings;
import lab_controls : LabControls;
import unicode_samples : Showcase, unicodeSamples;
import specimen_paragraph : fitSpecimenItem, SpecimenParagraph;
import sparkles.font.cluster_shaping : ClusterDirection;
import std.algorithm.sorting : sort;


import sparkles.base.term_color : RgbColor;
import sparkles.base.term_control : PointerShape;
import sparkles.base.term_style : TextAttr, UnderlineStyle;
import sparkles.base.text.grapheme : fitCells, visibleWidth;
import sparkles.input : Event, Gesture, GestureEvent, isEndOfInput, Key, KeyAction, KeyEvent, match, PointerAction, PointerEvent, WheelEvent;
import sparkles.ui.geometry : Insets, Point, Rect, Size;
import sparkles.ui.style : BorderStyle, BoxBorder, Palette, Slot, Visual;
import sparkles.ui.widget : Builder, WidgetKind, WidgetTree;
import sparkles.ui_vulkan.painter : GlyphInspection, rgba;
import sparkles.ui_vulkan.coverage_geometry : CoverageMode, CoverageWork;
import sparkles.ui_vulkan.text_rendering : Compositing, Hinting, Loupe, TextRendering;

/// The specimen, line by line: what each line shows, and the text.
immutable string[2][] specimen = () {
    immutable(string[2])[] result;
    foreach (sample; unicodeSamples)
        if (sample.group == Showcase.overview)
        {
            immutable(string[2]) pair = [sample.label, sample.text];
            result ~= pair;
        }
    return result.idup;
}();


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

/// Reproducible render and font-changing workloads, without interaction noise.
enum SweepMode { all, render, size, weight, axes }

private void sweepSettings(ref LabSettings settings, SweepMode mode, double fraction)
    @safe pure nothrow @nogc
{
    if (mode == SweepMode.all || mode == SweepMode.size)
        settings.font.size = 8 + 24 * fraction;
    if (mode == SweepMode.all || mode == SweepMode.axes || mode == SweepMode.weight)
        foreach (ref axis; settings.axes)
            if (mode != SweepMode.weight || axis.tag == 0x77676874)
                axis.value = axis.minimum + (axis.maximum - axis.minimum) * fraction;
}

/// A frozen redraw and a weight-only sweep preserve unrelated settings.
@("text_lab.sweepSettings.isolatesWorkloads")
@safe unittest
{
    import font_settings : AxisSetting;
    LabSettings settings;
    settings.axes = [AxisSetting(tag: 0x77676874, minimum: 100, maximum: 900, value: 400),
        AxisSetting(tag: 0x77647468, minimum: 50, maximum: 200, value: 100)];
    const size = settings.font.size;
    sweepSettings(settings, SweepMode.render, 1);
    assert(settings.font.size == size && settings.axes[0].value == 400);
    sweepSettings(settings, SweepMode.weight, 1);
    assert(settings.font.size == size && settings.axes[0].value == 900 && settings.axes[1].value == 100);
    sweepSettings(settings, SweepMode.size, 0.5);
    assert(settings.font.size == 20 && settings.axes[1].value == 100);
    sweepSettings(settings, SweepMode.axes, 1);
    assert(settings.font.size == 20 && settings.axes[1].value == 200);
}

/// The lab's state.
struct Lab
{

    LabSettings model; /// the sole subject of the generated settings sheet
    /// Compatibility access to the specimen's rendering settings.
    ref inout(TextRendering) settings() inout return @safe pure nothrow @nogc => model.rendering;
    /// The loupe's settings, shared with its generated controls.
    ref inout(Loupe) loupe() inout return @safe pure nothrow @nogc => model.loupe;
    /// CLI configuration for asynchronous font discovery.
    bool discoverFonts;
    string[] fontDirectories;
    string fontCache;
    string fontVariations;
    string fontSpecification;
    bool pickerAtStart;
    uint sweepFrames; /// deterministic size/axis sweep; zero disables it
    SweepMode sweepMode; /// which font settings change during a sweep
    uint rasterWorkers = 2; /// coverage workers, including a serial comparison
    CoverageMode coverageMode; /// opt-in coverage comparison
    string coverageReport; /// optional CSV experiment output
    private ulong paintedFrames;
    private SpecimenLayout specimenLayout;
    private uint swept;
    private LabControls controls;
    private double pinchPosition = -1;
    private double pinchAppliedSize = -1;
    /// A rejected runtime/CLI font request, reported by the entry point.
    string fontError() const @safe => controls is null ? null : controls.error;

    string shotPath;              /// capture the first full frame here, then quit
    /// Where `p` saves a screenshot: the working directory when empty.
    string screenshotDir;
    /// Whether the settings sheet is open.
    bool sheetOpen;
    /// Whether lines cross at the pointer while it hovers or a finger is
    /// down: what the loupe magnifies, aimed to the pixel.
    ref inout(bool) crosshair() inout return @safe pure nothrow @nogc => model.crosshair;
    private int framesToShot = 3; // the font atlas and the window settle first
    private Point pointer = Point(-1, -1);
    private bool pointing; // a mouse hovers, or a finger is down
    private bool inspectionActive;
    private GlyphInspection inspected;
    private string inspectedSource, inspectedSample;
    private bool sentSettings;
    /// Waits for font workers before the host releases drawing resources.
    void shutdown(H)(ref H h)
    {
        if (controls !is null) controls.stop();
        if (coverageReport.length && specimenLayout !is null)
        {
            import std.stdio : File;
            auto file = File(coverageReport, "w");
            file.writeln("frame,mode,prepare_worker_ns,flatten_worker_ns,pack_worker_ns,raster_worker_ns,caller_ns,attempted_glyphs,edges,texels,band_stride_sum,geometry_glyphs,fallback_glyphs,published_glyphs");
            foreach (sample; specimenLayout.coverageWork[])
            {
                const work = sample.work;
                file.writefln("%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s", sample.frame, coverageMode,
                    work.prepareNs, work.flattenNs, work.packNs, work.rasterNs, work.batchNs,
                    work.glyphs, work.edges, work.texels, work.bandStrideSum,
                    work.geometryGlyphs, work.fallbackGlyphs, work.publishedGlyphs);
            }
        }
        static if (__traits(hasMember, H, "frameStatistics"))
            if (sweepFrames)
            {
                import std.stdio : stderr;
                const stats = h.frameStatistics;
                const latency = h.specimenLatencyStatistics;
                stderr.writefln("text-lab sweep: %s updates; CPU p50 %.3f p95 %.3f p99 %.3f worst %.3f ms; "
                    ~ "request-to-submit %s/%s over 16.67ms; observed display %s, deadline misses %s",
                    swept, stats.p50.total!"nsecs" / 1e6, stats.p95.total!"nsecs" / 1e6,
                    stats.p99.total!"nsecs" / 1e6, stats.slowest.total!"nsecs" / 1e6,
                    latency.submissionDeadlineMisses, latency.submitted, latency.shown, latency.shownDeadlineMisses);
            }
    }

    private bool userSized; // `+` or `-` was pressed: the size is theirs
    private bool settled; // the panels held the specimen once: the size stays
    private PointerShape shape_ = PointerShape.default_;
    // What the last frame laid out, for a tap or click: the Settings
    // button, the sheet, and the sheet's buttons.
    private Rect settingsButton_;
    private Rect fontButton_;
    private Rect sheet_;


    /// Prepares the font request. The generated sheet is drawn as an overlay
    /// after custom specimen painting, through the ordinary widget pipeline.
    WidgetTree view(H)(ref H h)
    {

        if (controls is null)
        {
            controls = new LabControls(&model);
            controls.discovery = discoverFonts;
            controls.directories = fontDirectories;
            controls.cache = fontCache;
            controls.variation = fontVariations;
            controls.startupSpec = fontSpecification;
            if (pickerAtStart) controls.openPicker();
        }
        if (sweepFrames && model.font.path.length && !controls.loading)
        {
            if (swept >= sweepFrames) h.quit();
            else
            {
                const phase = swept % 120;
                const fraction = (phase < 60 ? phase : 120 - phase) / 60.0;
                sweepSettings(model, sweepMode, fraction);
                ++swept;
                h.requestFrame();
            }
        }
        controls.frame(h);
        if (fontVariations.length && fontError.length) { h.quit(); return WidgetTree.init; }
        // `--shot`: a few frames for the atlas and the window to settle, then
        // the capture, then out — on a host that cannot capture too, which
        // otherwise asks for frames forever.
        if (shotPath.length && !controls.loading)
        {
            if (fontError.length) { h.quit(); return WidgetTree.init; }
            --framesToShot;
            static if (__traits(hasMember, H, "screenshot"))
                if (framesToShot == 0)
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
        inspected = GlyphInspection.init;
        inspectedSource = inspectedSample = null;
        ++paintedFrames;
        static if (offersSettings!H)
        {
            if (!sentSettings)
            {
                static if (__traits(hasMember, H, "specimenTextRendering"))
                    h.specimenTextRendering(settings);
                else h.textRendering(settings);
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
        // row short. That is the opening size; once it fits, a window the
        // user then drags smaller keeps its font, which would otherwise only
        // ever shrink.
        if (!discoverFonts && !userSized && !settled)
        {
            if (fits(size, model.samples.group))
                settled = true;
            else if (h.fontSizePx > minFitPx)
            {
                h.fontSize(h.fontSizePx - 1);
                h.requestFrame();
            }
        }
        sheet_ = Rect.init;
        static if (offersSettings!H)
            if (controls !is null) sheet_ = controls.overlayBounds(size, sheetOpen);
        const half = (size.height - headerRows) / 2;
        panel(h, canvas, Rect(0, headerRows, size.width, half), dark);
        panel(h, canvas, Rect(0, headerRows + half, size.width, size.height - headerRows - half), light);
        // Read frame-local diagnostics after drawing, then paint each header
        // line once. Fallback telemetry must not replace the settings hints.
        header(h, canvas, size.width);
        static if (__traits(compiles, canvas.fillPx(0, 0, 1, 1, rgba(accent, 255))))
            if (crosshair && pointing)
                drawCrosshair(h, canvas);

        static if (offersSettings!H)

            if (controls !is null)
            {
                controls.draw(canvas, size, sheetOpen, framePalette());
                sheet_ = controls.bounds;
            }
        drawGlyphTooltip(h, canvas);

    }

    private void header(H, C)(ref H h, C canvas, int width)
    {
        canvas.fillRect(Rect(0, 0, width, headerRows), Visual(bg: headerBg, hasBg: true));
        static if (offersSettings!H)
        {
            enum buttonWidth = 24;
            settingsButton_ = Rect(width - 12, 0, 12, headerRows);
            fontButton_ = Rect(width - 24, 0, 12, headerRows);
            const first = format("text lab · %s · %s", discoverFonts ? format("%.3f pt", model.font.size)
                : format("%spx", h.fontSizePx),
                loupe.shown ? format("loupe ×%s", loupe.scale) : "loupe off");
            static if (__traits(hasMember, H, "specimenFallbackGlyphs"))
                const second = format("compositing %s %.2f · † fallback %s / grid %s",
                    settings.compositing, settings.contrast, h.specimenFallbackGlyphs, h.specimenGridFallbacks);
            else
                const second = format("compositing %s %.2f", settings.compositing, settings.contrast);
            const hint = controls !is null && controls.error.length ? controls.error
                : controls !is null && controls.fallbackWarning.length ? controls.fallbackWarning
                : format("hinting %s · shaping %s · f Fonts · F12 stable UI", settings.hinting, settings.shaping ? "on" : "off");
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
        {
            button(canvas, fontButton_, "f  Fonts", controls !is null && controls.picker.active);
            button(canvas, settingsButton_, "≡ Settings", sheetOpen);
        }
    }

    // Whether both panels hold the whole specimen at `size`.
    private static bool fits(in Size size, Showcase group = Showcase.overview)
    {
        const half = (size.height - headerRows) / 2;
        int rows;
        foreach (line; specimenPages[cast(size_t) group])
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
    private void panel(H, C)(ref H h, C canvas, in Rect r, in Theme t)
    {
        const lines = specimenPages[cast(size_t) model.samples.group];
        const visible = visiblePanel(r, sheet_);
        if (visible.width <= 0 || visible.height <= 0) return;
        canvas.fillRect(r, Visual(bg: t.bg, hasBg: true));
        static if (__traits(compiles, h.beginSpecimen(), h.specimenCellHeight,
                canvas.naturalTextPx("", 0, 0, rgba(t.fg, 255))))
        {
            if (discoverFonts && h.specimenFontReady)
            {
                specimenPanel(h, canvas, r, visible, t);
                return;
            }
        }
        const textX = r.x + 1 + labelWidth, textWidth = r.width - labelWidth - 2;
        const label = Visual(fg: t.label, bg: t.bg, hasBg: true);
        int y = r.y;
        foreach (line; lines[model.samples.firstRow - 1 < lines.length ? model.samples.firstRow - 1 : 0 .. $])
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

    // Labels retain the UI font; specimen text uses independent em metrics.
    private void specimenPanel(H, C)(ref H h, C canvas, in Rect r, in Rect visible, in Theme t)
    {
        const lines = specimenPages[cast(size_t) model.samples.group];
        import std.algorithm.comparison : max;

        const cw = h.cellWidth, ch = h.cellHeight;
        const left = (r.x + labelWidth + 1) * cw;
        const width = max(1, (r.width - labelWidth - 2) * cw);
        const rowHeight = max(ch, h.specimenCellHeight);
        int y = r.y * ch - cast(int) model.samples.wrappedOffset * rowHeight;
        const bottom = visible.bottom * ch;
        const right = visible.right * cw;
        canvas.pushClip(visible);
        scope (exit) canvas.popClip();
        if (specimenLayout is null) specimenLayout = new SpecimenLayout;
        specimenLayout.tokens.clear(false);
        specimenLayout.lines.clear(false);
        if (!h.beginSpecimen()) return;
        static if (__traits(compiles, canvas.beginGlyphPreparation(rasterWorkers, coverageMode, coverageReport.length != 0), canvas.finishGlyphPreparation()))
            canvas.beginGlyphPreparation(rasterWorkers, coverageMode, coverageReport.length != 0);
        else static if (__traits(compiles, canvas.beginGlyphPreparation(rasterWorkers), canvas.finishGlyphPreparation()))
            canvas.beginGlyphPreparation(rasterWorkers);
        foreach (index, line; lines)
        {
            if (index + 1 < model.samples.firstRow) continue;
            if (y >= bottom) break;
            const lineY = y;
            const first = specimenLayout.tokens.length;
            int pen;
            foreach (run; line.runs)
            {

                auto paragraph = specimenLayout.paragraph(run.text);
                foreach (item; paragraph.items)
                {
                    const bold = (run.style & TextAttr.bold.bits) != 0;
                    const italic = (run.style & TextAttr.italic.bits) != 0;
                    auto measure = (string token) => model.font.cellGrid && item.direction != ClusterDirection.rtl
                        ? cast(int) visibleWidth(token) * h.specimenCellWidth
                        : canvas.naturalTextWidthPx(token, bold, italic, item.direction);
                    auto rest = item;
                    while (rest.text.length)
                    {
                        const fitted = fitSpecimenItem(rest, width, measure);
                        const token = fitted.text;
                        const advance = measure(token);
                        if (pen && pen + advance > width)
                        {
                            pen = 0;
                            y += rowHeight;
                        }
                        if (y >= bottom) break;
                        if (!pen && item.space) break;
                        specimenLayout.tokens ~= PlacedToken(token, pen, y, advance, run.style,
                            run.underline, run.colour, item.direction, fitted.start, fitted.end);
                        pen += advance;
                        rest.text = rest.text[token.length .. $];
                        rest.start = fitted.end;
                    }
                    if (y >= bottom) break;
                }
                if (y >= bottom) break;
            }

            if (line.runs.length == 1)
            {
                auto paragraph = specimenLayout.paragraph(line.runs[0].text);
                auto tokens = specimenLayout.tokens[][first .. $];
                size_t begin;
                while (begin < tokens.length)
                {
                    size_t end = begin + 1;
                    while (end < tokens.length && tokens[end].y == tokens[begin].y) ++end;
                    auto row = tokens[begin .. end];
                    const logicalStart = row[0].start, logicalEnd = row[$ - 1].end;
                    const positions = paragraph.positions(logicalStart, logicalEnd);
                    int total;
                    foreach (ref token; row)
                    {
                        token.visual = size_t.max;
                        foreach (position; positions[token.start - logicalStart .. token.end - logicalStart])
                            if (position < token.visual) token.visual = position;
                        total += token.advance;
                    }
                    row.sort!((a, b) => a.visual < b.visual);
                    int x = paragraph.rightAligned && total < width ? width - total : 0;
                    foreach (ref token; row) { token.pen = x; x += token.advance; }
                    begin = end;
                }
            }
            specimenLayout.lines ~= PlacedLine(index, lineY, first, specimenLayout.tokens.length);
            y += rowHeight;
        }
        h.endSpecimen();
        static if (is(typeof(canvas.finishGlyphPreparation()) : CoverageWork))
        {
            const work = canvas.finishGlyphPreparation();
            if (coverageReport.length)
            {
                // Both panels contribute to one frame row. Bound diagnostics
                // during interactive sessions as well as finite sweeps.
                auto rows = specimenLayout.coverageWork[];
                if (rows.length && rows[$ - 1].frame == paintedFrames - 1)
                    rows[$ - 1].work.add(work);
                else if (rows.length < 65_536)
                    specimenLayout.coverageWork ~= CoverageSample(paintedFrames - 1, work);
            }
        }
        else static if (__traits(compiles, canvas.finishGlyphPreparation()))
            canvas.finishGlyphPreparation();
        foreach (line; specimenLayout.lines[])
        {
            const label = lines[line.index].label;
            canvas.labelPx(label, (r.x + 1) * cw, line.y, rgba(t.label, 255), rgba(t.bg, 255));
            const fallbacksBefore = h.specimenFallbackGlyphs + h.specimenGridFallbacks;
            if (!h.beginSpecimen()) break;
            foreach (token; specimenLayout.tokens[][line.first .. line.end])
            {
                const x = left + token.pen;
                const ink = rgba(t.ink(token.colour), 255), ground = rgba(t.bg, 255);
                if (model.font.cellGrid && token.direction != ClusterDirection.rtl)
                    canvas.labelPx(token.text, x, token.y, ink, ground);
                else
                    cast(void) canvas.naturalTextPx(token.text, x, token.y, ink, ground,
                        (token.style & TextAttr.bold.bits) != 0, (token.style & TextAttr.italic.bits) != 0, token.direction);
                if (token.underline != UnderlineStyle.none)
                    canvas.fillPx(x, token.y + rowHeight - 2, token.advance, 1, ink);
                if (token.style & TextAttr.strikethrough.bits)
                    canvas.fillPx(x, token.y + rowHeight / 2, token.advance, 1, ink);
                static if (__traits(compiles, canvas.inspectTextPx(token.text, 0.0)))
                    if (inspectionActive && pointer.x >= x && pointer.x < x + token.advance
                        && pointer.y >= token.y && pointer.y < token.y + rowHeight
                        && visible.contains(Point(pointer.x / cw, pointer.y / ch)))
                    {
                        inspected = canvas.inspectTextPx(token.text, cast(double)(pointer.x - x),
                            (token.style & TextAttr.bold.bits) != 0,
                            (token.style & TextAttr.italic.bits) != 0, token.direction,
                            model.font.cellGrid && token.direction != ClusterDirection.rtl);
                        if (inspected.found && inspected.start < inspected.end && inspected.end <= token.text.length)
                        {
                            inspectedSource = token.text[inspected.start .. inspected.end].idup;
                            inspectedSample = label;
                        }
                    }
            }
            h.endSpecimen();
            if (h.specimenFallbackGlyphs + h.specimenGridFallbacks > fallbacksBefore)
                canvas.labelPx(clip(label ~ " †", labelWidth), (r.x + 1) * cw, line.y,
                    rgba(t.label, 255), rgba(t.bg, 255));
        }
    }

    private void drawGlyphTooltip(H, C)(ref H h, C canvas)
    {
        if (!inspectionActive || !inspected.found || !inspectedSource.length
            || controls !is null && controls.picker.active) return;
        import glyph_tooltip : glyphTooltipLines;
        const lines = glyphTooltipLines(inspectedSource, inspectedSample, inspected);
        int width;
        foreach (line; lines)
        {
            const length = cast(int) visibleWidth(line);
            if (length > width) width = length;
        }
        const room = sheetOpen && h.size.width >= sideSheetMinWidth ? sheet_.x : h.size.width;
        width = width + 2 < room ? width + 2 : room;
        const height = cast(int) lines.length + 2;
        if (width < 4 || h.size.height < height + headerRows) return;
        const cell = cellOf(h, pointer);
        int x = cell.x + 2, y = cell.y + 2;
        if (x + width > room) x = room - width;
        if (y + height > h.size.height) y = cell.y - height - 1;
        if (y < headerRows) y = headerRows;
        const box = Rect(x, y, width, height);
        canvas.fillRect(box, Visual(fg: ink, bg: headerBg, hasBg: true,
            border: BoxBorder(width: Insets.all(1), style: BorderStyle.solid, color: accent)));
        foreach (i, line; lines)
            canvas.textRun(Point(x + 1, y + 1 + cast(int)i), clip(line, width - 2),
                Visual(fg: ink, bg: headerBg, hasBg: true));
    }

    // A three-row button: a bordered box, its label centred on the middle row.
    private static void button(C)(C canvas, in Rect r, string label, bool selected)
    {
        const bg = selected ? selectedBg : buttonBg;
        canvas.fillRect(r, Visual(bg: bg, hasBg: true, border: BoxBorder(width: Insets(1, 1, 1, 1),
            style: BorderStyle.solid, color: selected ? accent : edge)));
        centred(canvas, r, label, Visual(fg: ink, bg: bg, hasBg: true));
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
        if (sheetOpen && !side || controls !is null && controls.picker.active)
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
    or a drag, over the panels moves the loupe; pinch zooms font size.
    */
    void handle(H)(ref H h, in Event e)
    {

        if (isEndOfInput(e)) return h.quit();
        if (controls !is null)
        {
            enum pixels = __traits(hasMember, H, "cellWidth");
            if (controls.handle(h, e, sheetOpen, pixels))
            {
                inspectionActive = false;
                changed(h);
                return;
            }
        }

        e.match!(
            (in KeyEvent k) {
                if (k.action == KeyAction.release) return;
                if (k.key == Key.escape || k.key == Key.back)
                {
                    if (sheetOpen)
                        return toggleSheet(h);
                    if (k.key == Key.back)
                        return h.quit();
                    return;
                }

                if (k.key == Key.pageUp || k.key == Key.pageDown)
                {
                    const count = specimenPages[cast(size_t) model.samples.group].length;
                    if (k.key == Key.pageUp && model.samples.firstRow > 1) --model.samples.firstRow;
                    if (k.key == Key.pageDown && model.samples.firstRow < count) ++model.samples.firstRow;
                    changed(h);
                    return;
                }
                command(h, k.ch);
            },
            (in PointerEvent p) {
                if (p.action == PointerAction.leave) inspectionActive = false;
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
                    if (fontButton_.contains(cell) && controls !is null)
                    {
                        controls.openPicker();
                        h.requestFrame();
                        return;
                    }
                    if (settingsButton_.contains(cell))
                        return toggleSheet(h);
                    if (sheetOpen && sheet_.contains(cell)) return;
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
                {
                    inspectionActive = false;
                    return;
                }
                pointer = p.pos;
                pointing = true;
                inspectionActive = true;
                h.requestFrame();
            },
            (in WheelEvent w) {
                const cell = cellOf(h, w.pos);
                if (cell.y < headerRows || (sheetOpen && sheet_.contains(cell)))
                    return;
                pointer = w.pos;
                pointing = true;
                h.requestFrame();
            },
            (in GestureEvent g) {
                onGesture(h, g);
            },
            (in _) {},
        );
    }

    private void onGesture(H)(ref H h, in GestureEvent g)
    {
        import std.math : isFinite;

        if (g.gesture != Gesture.pinch)
            return;
        inspectionActive = false;
        if (controls !is null && (controls.picker.active || controls.capturing))
            return;
        if (!g.scale.isFinite || g.scale <= 0.0f || (g.scale == 1.0f && g.deltaPx == 0.0f))
            return;

        pointing = false;
        userSized = true;

        if (sheetOpen && controls !is null)
            cast(void) controls.sections.cancel(controls.pane);

        auto before = model;
        before.axes = before.axes.dup;

        // Map physical finger separation delta directly into the slider's domain fraction.
        // A gesture span of 900px provides a comfortable two-thumb spread across the full range.
        const double gestureSpanPx = 900.0;
        double du;
        if (g.deltaPx != 0.0f)
            du = g.deltaPx / gestureSpanPx;
        else
        {
            if (g.scale <= 0.05f)
                du = -1.0;
            else if (g.scale >= 2.0f)
                du = 1.0;
            else
                du = (g.scale - 1.0) * 0.5;
        }

        if (discoverFonts)
        {
            import std.math : isFinite;
            import sparkles.ui.components.range_slider : SliderDomain;

            enum fontDomain = SliderDomain(4.0, 144.0, 0.125, 18.0, 0.50, 0.05);

            if (pinchPosition < 0 || !pinchPosition.isFinite
                || pinchAppliedSize != model.font.size)
                pinchPosition = fontDomain.fractionOf(model.font.size);

            pinchPosition += du;
            if (pinchPosition < 0.0) pinchPosition = 0.0;
            if (pinchPosition > 1.0) pinchPosition = 1.0;

            double newSize = fontDomain.valueOf(pinchPosition);
            if (newSize < 4.0)
                newSize = 4.0;
            if (newSize > 144.0)
                newSize = 144.0;

            pinchAppliedSize = newSize;

            if (newSize != model.font.size)
            {
                model.font.size = newSize;
                if (controls !is null)
                    controls.externalEdit(before);
                changed(h);
            }
        }
        else
        {
            import std.math : isFinite, round;
            import sparkles.ui.components.range_slider : SliderDomain;

            // Match the legacy keyboard shortcut's lower bound. minFitPx is
            // the automatic fitting floor, not the explicit size limit.
            const fontDomain = SliderDomain(6.0, 144.0, 1.0, 18.0, 0.50, 0.05);

            if (pinchPosition < 0 || !pinchPosition.isFinite
                || pinchAppliedSize != h.fontSizePx)
                pinchPosition = fontDomain.fractionOf(h.fontSizePx);

            pinchPosition += du;
            if (pinchPosition < 0.0) pinchPosition = 0.0;
            if (pinchPosition > 1.0) pinchPosition = 1.0;

            int px = cast(int) round(fontDomain.valueOf(pinchPosition));
            if (px < 6)
                px = 6;
            if (px > 144)
                px = 144;

            pinchAppliedSize = px;

            if (px != h.fontSizePx)
            {
                h.fontSize(px);
                changed(h);
            }
        }
    }

    // Whether `cell` is on a control: Settings, or a button of the open sheet.
    private bool overButton(Point cell) const
    {
        if (settingsButton_.contains(cell) || fontButton_.contains(cell))
            return true;
        if (sheetOpen && sheet_.contains(cell)) return true;
        return false;
    }

    private void toggleSheet(H)(ref H h)
    {
        inspectionActive = false;
        if (sheetOpen && controls !is null) cast(void) controls.sections.cancel(controls.pane);
        sheetOpen = !sheetOpen;
        h.requestFrame();
    }

    // The cell under `at`: the pointer is in pixels where the host reports
    // cell sizes, in cells where it does not.
    // The pixels right of the last whole column and below the last whole
    // row belong to the last cell: the sheet reaches the window's edge, and
    // the strip beside it is the sheet's, not the panels'.
    private static Point cellOf(H)(ref H h, Point at)
    {
        import std.algorithm.comparison : max, min;

        static if (__traits(hasMember, H, "cellWidth"))
        {
            const size = h.size;
            return Point(min(at.x / max(h.cellWidth, 1), max(size.width - 1, 0)),
                min(at.y / max(h.cellHeight, 1), max(size.height - 1, 0)));
        }
        else
            return at;
    }

    private void command(H)(ref H h, dchar ch)
    {
        auto before = model;
        before.axes = before.axes.dup;
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


            case 'n', 'N':
                enum count = __traits(allMembers, Showcase).length;
                model.samples.group = cast(Showcase)((cast(size_t) model.samples.group + (ch == 'N' ? count - 1 : 1)) % count);
                model.samples.firstRow = 1;
                model.samples.wrappedOffset = 0;
                break;
            case 'f':
                if (controls !is null) controls.openPicker();
                break;
            case '+', '=':
                userSized = true;
                if (discoverFonts) model.font.size = model.font.size < 143.25 ? model.font.size + 0.75 : 144;
                else h.fontSize(h.fontSizePx + 1);
                break;
            case '-':
                userSized = true;
                if (discoverFonts) model.font.size = model.font.size > 4.75 ? model.font.size - 0.75 : 4;
                else h.fontSize(h.fontSizePx > 6 ? h.fontSizePx - 1 : 6);
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
        if (controls !is null) controls.externalEdit(before);
        changed(h);
    }

    // Before the frame that shows them: `paint` runs after the frame has
    // begun, which would leave part of it in the old settings.
    private void changed(H)(ref H h)
    {
        static if (offersSettings!H)
        {
            static if (__traits(hasMember, H, "specimenTextRendering"))
                h.specimenTextRendering(settings);
            else h.textRendering(settings);
        }
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

/// The window frame's colours where the host draws it (GNOME): the header's.
Palette framePalette() @safe pure nothrow @nogc
{
    import sparkles.base.term_color : Color;
    import sparkles.ui.style : defaultTwoslashPalette;

    auto p = defaultTwoslashPalette();
    p.bg[Slot.surface] = Color.fromRgb(sheetBg);
    p.bg[Slot.inherit] = Color.fromRgb(sheetBg);
    p.fg[Slot.inherit] = Color.fromRgb(ink);
    p.bg[Slot.surfaceRaised] = Color.fromRgb(buttonBg);
    p.bg[Slot.surfaceSunken] = Color.fromRgb(headerBg);
    p.fg[Slot.textPrimary] = Color.fromRgb(ink);
    p.fg[Slot.textSecondary] = Color.fromRgb(muted);
    p.bg[Slot.chrome] = Color.fromRgb(headerBg);
    p.fg[Slot.chrome] = Color.fromRgb(ink);
    return p;
}

/// A panel's colours.
// Trim only when the opaque sheet covers a complete edge. Keeping the panel's
// original rectangle for layout prevents opening a sheet from reflowing text.
private Rect visiblePanel(Rect panel, Rect overlay) @safe pure nothrow @nogc
{
    import std.algorithm.comparison : max, min;

    if (overlay.width <= 0 || overlay.height <= 0) return panel;
    if (overlay.x <= panel.x && overlay.right >= panel.right
        && overlay.y < panel.bottom && overlay.bottom >= panel.bottom)
        panel.size.height = max(0, min(panel.bottom, overlay.y) - panel.y);
    else if (overlay.y <= panel.y && overlay.bottom >= panel.bottom
        && overlay.x < panel.right && overlay.right >= panel.right)
        panel.size.width = max(0, min(panel.right, overlay.x) - panel.x);
    return panel;
}

/// Edge sheets cull work without altering the logical panel's wrapping width.
@("text_lab.visiblePanel.opaqueEdges")
@safe pure nothrow @nogc unittest
{
    const panel = Rect(0, 3, 49, 24);
    assert(visiblePanel(panel, Rect(0, 18, 49, 32)) == Rect(0, 3, 49, 15));
    assert(visiblePanel(panel, Rect(0, 3, 49, 47)).height == 0);
    assert(visiblePanel(panel, Rect(30, 3, 19, 47)) == Rect(0, 3, 30, 24));
    assert(visiblePanel(panel, Rect(12, 10, 20, 10)) == panel);
    assert(visiblePanel(panel, Rect.init) == panel);
}

private final class SpecimenLayout
{
    private SpecimenParagraph[string] paragraphs;
    SpecimenParagraph paragraph(string text) @safe
    {
        if (auto p = text in paragraphs) return *p;
        auto p = new SpecimenParagraph(text);
        paragraphs[text] = p;
        return p;
    }
    UniqueBuffer!PlacedToken tokens;
    UniqueBuffer!PlacedLine lines;
    UniqueBuffer!CoverageSample coverageWork;
}

private struct CoverageSample
{
    ulong frame;
    CoverageWork work;
}

private struct PlacedToken
{
    string text;
    int pen, y, advance;
    ushort style;
    UnderlineStyle underline;
    ubyte colour;
    ClusterDirection direction;
    size_t start, end, visual;
}

private struct PlacedLine
{
    size_t index;
    int y;
    size_t first, end;
}

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

private immutable Line[][] specimenPages = () {
    immutable(Line)[][] result;
    foreach (group; 0 .. __traits(allMembers, Showcase).length)
    {
        Line[] all;
        foreach (row; unicodeSamples)
            if (cast(size_t) row.group == group)
                all ~= Line(row.label, [Run(row.text)]);
        if (group == cast(size_t) Showcase.overview)
        {
            all ~= Line("Styles", [Run("regular "), Run("bold", TextAttr.bold.bits), Run(" "),
                Run("italic", TextAttr.italic.bits), Run(" "),
                Run("bold italic", cast(ushort)(TextAttr.bold.bits | TextAttr.italic.bits)), Run(" "),
                Run("underline", 0, UnderlineStyle.single), Run(" "), Run("strike", TextAttr.strikethrough.bits)]);
            all ~= Line("Colour", [Run("red", 0, UnderlineStyle.none, 1), Run(" "),
                Run("green", 0, UnderlineStyle.none, 2), Run(" "),
                Run("blue — thin strokes on colour: illegible, minimum, Mississippi", 0, UnderlineStyle.none, 3)]);
        }
        result ~= all.idup;
    }
    return result.idup;
}();

private immutable Line[] lines = specimenPages[Showcase.overview];

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

version (unittest)
{
    import sparkles.input : charEvent;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : runAppRecorded;
}

@("text_lab.aShotEndsOnAHostThatCannotCapture")
@system unittest
{
    // The recorder has no `screenshot`, like the terminal arm: the shot's
    // countdown still runs out and the lab quits instead of asking for
    // frames forever.
    Lab lab;
    lab.shotPath = "never-written.png";
    const rec = runAppRecorded(lab, RunConfig.init, []);
    assert(rec.quitRequested && rec.frames.length < 10);
}

@("text_lab.theIconsAreNerdFontCodePoints")
@safe unittest
{
    import std.algorithm : count, filter;
    import std.utf : byDchar;

    // Each icon is a private-use code point, which a font's character map
    // and nothing else gives meaning to; a pass through a tool that drops
    // them leaves only spaces.
    foreach (line; specimen)
        if (line[0] == "Icons")
        {
            auto icons = line[1].byDchar.filter!(c => c != ' ');
            assert(icons.save.count == 8);
            foreach (c; icons)
                assert(c >= 0xE000 && c <= 0xF8FF);
            return;
        }
    assert(false, "the specimen has an Icons line");
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

@("text_lab.pinchZoomsTheFontSize")
@system unittest
{
    // Pinch gesture increases and decreases specimen font size when discoverFonts is true
    Lab lab;
    lab.discoverFonts = true;
    lab.model.font.size = 12.0;

    // Zoom in (pinch out, scale > 1)
    cast(void) runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(Gesture.pinch, Point(0, 0), 1.25f)),
    ]);
    assert(lab.model.font.size > 12.0, "pinch out increases font size");
    const zoomedIn = lab.model.font.size;

    // Zoom out (pinch in, scale < 1)
    cast(void) runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(Gesture.pinch, Point(0, 0), 0.8f)),
    ]);
    assert(lab.model.font.size < zoomedIn, "pinch in decreases font size");
}

/// Small physical movements accumulate before the displayed size is snapped.
@("text_lab.pinchSmallPhysicalStepsAccumulate")
@system unittest
{
    foreach (discover; [false, true])
    {
        Lab lab;
        lab.discoverFonts = discover;
        lab.model.font.size = 12;
        SettingsHost host;
        host.fontSize(12);
        foreach (_; 0 .. 100)
            lab.handle(host, Event(GestureEvent(gesture: Gesture.pinch, deltaPx: 1.0f)));
        assert(discover ? lab.model.font.size > 12 : host.fontSizePx > 12);
        foreach (_; 0 .. 100)
            lab.handle(host, Event(GestureEvent(gesture: Gesture.pinch, deltaPx: -1.0f)));
        assert(discover ? lab.model.font.size == 12 : host.fontSizePx == 12);
    }
}

/// Scale-only and mixed events never reverse an outward pinch.
@("text_lab.pinchScaleFallbackStaysMonotonic")
@system unittest
{
    foreach (discover; [false, true])
    {
        Lab lab;
        lab.discoverFonts = discover;
        lab.model.font.size = 8;
        SettingsHost host;
        host.fontSize(8);
        double previous = 8;
        foreach (i; 0 .. 100)
        {
            const gesture = i % 3 == 0
                ? GestureEvent(gesture: Gesture.pinch, deltaPx: 1.0f)
                : GestureEvent(gesture: Gesture.pinch, scale: 1.02f);
            lab.handle(host, Event(gesture));
            const size = discover ? lab.model.font.size : host.fontSizePx;
            assert(size >= previous);
            previous = size;
        }
        assert(previous > 8);
    }
}

/// Pinching inward at the keyboard minimum must not increase the size.
@("text_lab.pinchLegacyKeyboardMinimum")
@system unittest
{
    Lab lab;
    SettingsHost host;
    host.fontSize(6);
    lab.handle(host, Event(GestureEvent(gesture: Gesture.pinch, deltaPx: -1.0f)));
    assert(host.fontSizePx == 6);
}

/// An external size adjustment replaces the pinch baseline, even below one pixel.
@("text_lab.pinchShortcutResynchronizesBaseline")
@system unittest
{
    Lab lab;
    lab.discoverFonts = true;
    lab.model.font.size = 12;
    SettingsHost host;
    lab.handle(host, Event(GestureEvent(gesture: Gesture.pinch, deltaPx: 50.0f)));
    lab.handle(host, Event(KeyEvent(Key.char_, '+')));
    const before = lab.model.font.size;
    lab.handle(host, Event(GestureEvent(gesture: Gesture.pinch, deltaPx: 1.0f)));
    assert(lab.model.font.size >= before);
    foreach (_; 0 .. 10)
        lab.handle(host, Event(GestureEvent(gesture: Gesture.pinch, deltaPx: 1.0f)));
    assert(lab.model.font.size > before);
}

@("text_lab.pinchPhysicalDeltaTracksSliderDomain")
@system unittest
{
    Lab lab;
    lab.discoverFonts = true;
    lab.model.font.size = 12.0;

    // Moving fingers apart by 50px increases size within reading range
    cast(void) runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(gesture: Gesture.pinch, deltaPx: 50.0f)),
    ]);
    assert(lab.model.font.size > 12.0 && lab.model.font.size < 18.0, "moderate delta stays in reading range");
    const expanded = lab.model.font.size;

    // Moving fingers back by 50px returns exactly to starting size (zero hysteresis)
    cast(void) runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(gesture: Gesture.pinch, deltaPx: -50.0f)),
    ]);
    assert(lab.model.font.size == 12.0, "symmetric delta restores initial size exactly");

    // Large delta sweeps into the headline range
    cast(void) runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(gesture: Gesture.pinch, deltaPx: 500.0f)),
    ]);
    assert(lab.model.font.size > 50.0, "large delta sweeps into headline range");
}

@("text_lab.pinchZoomsTheHostFontSizeWhenNotDiscoveringFonts")
@system unittest
{
    // On a host without font discovery, pinch adjusts host fontSizePx
    Lab lab;
    lab.discoverFonts = false;

    auto rec = runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(Gesture.pinch, Point(0, 0), 1.25f)),
    ]);
    assert(rec.fontSizePx > 18, "pinch out increases host font size");
    const zoomedIn = rec.fontSizePx;

    rec = runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(Gesture.pinch, Point(0, 0), 0.8f)),
    ]);
    assert(rec.fontSizePx < zoomedIn, "pinch in decreases host font size");
}

@("text_lab.pinchClampsFontSizeWithinBounds")
@system unittest
{
    Lab lab;
    lab.discoverFonts = true;
    lab.model.font.size = 140.0;

    // Zoom in beyond max 144
    cast(void) runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(Gesture.pinch, Point(0, 0), 2.0f)),
    ]);
    assert(lab.model.font.size == 144.0, "font size clamped at max 144");

    // Zoom out beyond min 4
    cast(void) runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(Gesture.pinch, Point(0, 0), 0.01f)),
    ]);
    assert(lab.model.font.size == 4.0, "font size clamped at min 4");
}

@("text_lab.pinchIgnoredWhenPickerActive")
@system unittest
{
    Lab lab;
    lab.discoverFonts = true;
    lab.pickerAtStart = true;
    lab.model.font.size = 12.0;

    cast(void) runAppRecorded(lab, RunConfig.init, [
        Event(GestureEvent(Gesture.pinch, Point(0, 0), 1.5f)),
    ]);
    assert(lab.model.font.size == 12.0, "pinch is ignored while font picker is active");
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


/// Frame-local fallback counts do not overwrite the settings hint line.
@("text_lab.headerHintsAreNotOverpaintedByFallbackCounts")
@system unittest
{
    import sparkles.ui.canvas : OpKind;
    import std.algorithm.searching : startsWith;

    struct Host
    {
        SettingsHost settingsHost;
        alias settingsHost this;
        uint specimenFallbackGlyphs = 2, specimenGridFallbacks = 1;
    }
    Lab lab;
    lab.discoverFonts = true;
    Host host;
    host.rec.size = Size(100, 60);
    scope (exit) lab.shutdown(host);
    const tree = lab.view(host);
    lab.paint(host, tree, null);
    size_t hints;
    foreach (op; host.rec.canvas.ops)
        if (op.kind == OpKind.textRun && op.rect.x == 1 && op.rect.y == 2)
        {
            assert(op.text.startsWith("hinting"), "fallback telemetry must not replace the hint line");
            ++hints;
        }
    assert(hints == 1);
}

/// The generated sheet remains a bottom sheet on phones and a side sheet on desktops.
@("text_lab.theGeneratedSheetUsesResponsivePlacement")
@system unittest
{
    Lab lab;
    SettingsHost h;
    h.rec.size = Size(49, 51);
    lab.sheetOpen = true;
    auto tree = lab.view(h);
    lab.paint(h, tree, null);
    assert(lab.sheet_.width == 49 && lab.sheet_.y > headerRows);
    assert(lab.controls.tree.nodes.length);
    h.rec.size = Size(100, 78);
    lab.paint(h, tree, null);
    assert(lab.sheet_.x == 100 - sideSheetWidth && lab.sheet_.y == headerRows);
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

    lab.controls.openPicker();
    frame();
    assert(!h.shownLoupe.shown, "the loupe must not cover picker results");
}

@("text_lab.theFontStepsDownUntilThePanelsHoldTheSpecimen")
@system unittest
{
    // A phone's 49×51 cells hold one row fewer than the wrapped specimen
    // needs: the font steps down a pixel; a tablet's 100×78 needs none;
    // once it fits, shrinking the window shrinks nothing; and once the user
    // picks a size, it is theirs.
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
    h.rec.size = Size(30, 20);
    lab.paint(h, tree, null);
    assert(h.rec.fontSizeRequests == [17], "a window dragged smaller keeps its font");
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

@("text_lab.everySizeDraws")
@system unittest
{
    // A window the user drags down to nothing — no columns, no rows, or one
    // of each — is still drawn: GNOME leaves the frame to the client, and
    // the title bar takes rows from the content first.
    foreach (size; [Size(0, 0), Size(0, 40), Size(80, 0), Size(1, 1), Size(3, 2), Size(12, 1)])
    {
        Lab lab;
        SettingsHost h;
        h.rec.size = size;
        auto tree = lab.view(h);
        lab.paint(h, tree, null);
        lab.loupe.shown = true;
        lab.paint(h, tree, null);
    }
}

@("text_lab.theStripPastTheLastCellIsTheLastCell")
@safe pure nothrow @nogc unittest
{
    // A 747 px window of 11 px cells is 67 columns and 10 px more: those
    // pixels are the last column's, so the open sheet beside them keeps
    // the pointer from aiming the loupe there.
    static struct Cells
    {
        Size size = Size(67, 30);
        int cellWidth = 11, cellHeight = 20;
    }
    Cells h;
    assert(Lab.cellOf(h, Point(740, 605)) == Point(66, 29));
    assert(Lab.cellOf(h, Point(725, 580)) == Point(65, 29));
    assert(Lab.cellOf(h, Point(0, 0)) == Point(0, 0));
}
