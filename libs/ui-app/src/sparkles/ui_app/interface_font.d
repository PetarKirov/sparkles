/**
The interface face's choice and sizes (design-system `GLY10`), shared by the
raylib and the native arm: which family chrome text draws in, the type steps'
sizes in drawing units, and how far the steps shrink so the interface face's
x-height is the cell font's when they follow it.

Renderer-free: the raylib arm loads the family into `UiFonts`, the native arm
binds it to the Vulkan canvas, and both size it here.
*/
module sparkles.ui_app.interface_font;

import sparkles.appearance.types : SystemAppearance;
import sparkles.ui.style : TypeStep, typeStepDp;

/// The number of steps on the type scale.
enum int interfaceSteps = TypeStep.max + 1;

/**
The interface family a run asks for unless `--ui-font` or the desktop says
otherwise: the bundled Roboto on Android, else a preference list of the
common desktop sans faces, ending in fontconfig's own `sans-serif`. The list
matters where fonts come from `--font-dir` (no font database to ask), and
fontconfig takes its first installed family.
*/
version (Android)
    enum string defaultUiFontFamily = "Roboto";
else
    enum string defaultUiFontFamily =
        "Inter,Adwaita Sans,Cantarell,Noto Sans,Roboto,DejaVu Sans,Liberation Sans,"
        ~ "Helvetica Neue,Segoe UI,sans-serif";

/// What `--ui-font` takes to keep chrome in the cell font.
enum string noUiFont = "none";

/**
The family the interface face resolves from: `requested` (`--ui-font`) when
given — empty for `none` — else the desktop's interface font where it names
one (`org.gnome.desktop.interface font-name`, through the settings portal),
else $(LREF defaultUiFontFamily).
*/
string uiFontFamilyOf(string requested, in SystemAppearance desktop) @safe pure nothrow
{
    if (requested == noUiFont)
        return null;
    if (requested.length)
        return requested;
    if (desktop.hasFont && desktop.font.family[].length)
        return desktop.font.family[].idup ~ "," ~ defaultUiFontFamily;
    return defaultUiFontFamily;
}

///
@("ui_app.interface_font.uiFontFamilyOf")
@safe pure nothrow unittest
{
    import sparkles.appearance.types : parseFontDescription;

    SystemAppearance none;
    assert(uiFontFamilyOf("", none) == defaultUiFontFamily);
    assert(uiFontFamilyOf("Inter", none) == "Inter", "the option wins");
    assert(uiFontFamilyOf(noUiFont, none) is null, "`none`: chrome in the cell font");

    SystemAppearance gnome;
    gnome.font = parseFontDescription("Adwaita Sans 11");
    gnome.hasFont = true;
    assert(uiFontFamilyOf("", gnome) == "Adwaita Sans," ~ defaultUiFontFamily,
        "the desktop's, then the list where it is not installed");
    assert(uiFontFamilyOf("Cantarell", gnome) == "Cantarell");
}

/**
The interface steps' sizes in drawing units: `dp` each at `uiScale`, or —
`cellFontPx` non-zero — the body step at the cell font's size and every other
step in its proportion to the body's.
*/
int[interfaceSteps] uiStepSizes(float uiScale, int cellFontPx = 0) @safe pure nothrow @nogc
{
    const scale = cellFontPx > 0 ? cellFontPx / cast(float) typeStepDp(TypeStep.body) : uiScale;
    int[interfaceSteps] sizes;
    foreach (i, ref s; sizes)
        s = uiStepPx(typeStepDp(cast(TypeStep) i), scale);
    return sizes;
}

@("ui_app.gui_setup.uiStepSizes.followTheCellFont")
@safe pure nothrow @nogc
unittest
{
    const dp = uiStepSizes(2.75f);
    assert(dp[TypeStep.body] == 39 && dp[TypeStep.title] == 47, "14 and 17 dp at 440 dpi");
    const cell = uiStepSizes(2.75f, cellFontPx: 28);
    assert(cell[TypeStep.body] == 28, "the body step is the cell font's size");
    assert(cell[TypeStep.title] == 34 && cell[TypeStep.caption] == 24, "the rest in proportion");
}

/// A type step of `dp` density-independent px at `scale`, in whole drawing units.
int uiStepPx(int dp, float scale) @safe pure nothrow @nogc
{
    const px = cast(int)(dp * scale + 0.5f);
    return px < 1 ? 1 : px;
}

@("ui_app.gui_setup.uiStepPx")
@safe pure nothrow @nogc
unittest
{
    assert(uiStepPx(14, 1) == 14);
    assert(uiStepPx(17, 2.75f) == 47, "a 440 dpi phone");
    assert(uiStepPx(12, 0) == 1);
}

/**
A face's x-height per unit of its ascender-to-descender span — the size
both arms draw a face at — from its `OS/2` `sxHeight`, or the top of its `x`
where `OS/2` records none; 0 where the face cannot be measured.
*/
float xHeightPerSpan(scope const(ubyte)[] bytes) @safe nothrow
{
    import sparkles.base.unique : makeUnique;
    import sparkles.font : charMap, glyphBounds, hhea, instance, InstanceSize, openFace, os2,
        PointWorkspace, Ppem;

    auto face = openFace(bytes);
    if (face.hasError)
        return 0;
    const hh = hhea(face.value);
    const span = hh.hasValue ? long(hh.value.ascender) - hh.value.descender : 0;
    if (span <= 0)
        return 0;
    const o = os2(face.value);
    if (o.hasValue && o.value.hasXHeight && o.value.sxHeight > 0)
        return o.value.sxHeight / cast(float) span;
    // An older `OS/2`: the top of the `x`, in font units (as 1/65,536ths).
    auto cmap = charMap(face.value);
    auto inst = instance(face.value, InstanceSize.pixels(Ppem.fromInteger(16).value), null);
    auto points = makeUnique!PointWorkspace();
    if (cmap.hasError || inst.hasError || points.empty)
        return 0;
    const gid = cmap.value.glyph('x');
    if (gid == 0)
        return 0;
    const b = glyphBounds(inst.value, gid, *points);
    return b.hasValue && b.value.present && b.value.yMax > 0
        ? b.value.yMax / (65_536.0f * span) : 0;
}

/**
The interface face's x-height over the cell font's, each per unit of size,
clamped as the raylib arm's `UiFonts` clamps it (0.7–1.3, then at least 1,
so a face with a smaller x-height never grows past the cell): what
`xHeightMatched` shrinks the steps by when they follow the cell font. 1 where
either face records no x-height.
*/
float xHeightRatio(scope const(ubyte)[] interfaceFace, scope const(ubyte)[] cellFace) @safe nothrow
{
    const u = xHeightPerSpan(interfaceFace), cell = xHeightPerSpan(cellFace);
    if (u <= 0 || cell <= 0)
        return 1.0f;
    const r = u / cell;
    const clamped = r < 0.7f ? 0.7f : r > 1.3f ? 1.3f : r;
    return clamped < 1.0f ? 1.0f : clamped;
}

@("ui_app.interface_font.xHeightRatio")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;

    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    const mono = cast(const(ubyte)[]) read(dir.buildPath("DejaVuSansMono.ttf"));
    const sans = cast(const(ubyte)[]) read(dir.buildPath("NotoSans.ttf"));
    const m = xHeightPerSpan(mono), s = xHeightPerSpan(sans);
    import std.conv : text;
    assert(m > 0.3 && m < 0.6 && s > 0.3 && s < 0.6, text("an x-height is about half the line: ", m, " ", s));
    const r = xHeightRatio(sans, mono);
    assert(r >= 1 && r <= 1.3);
    assert(xHeightRatio(sans, sans) == 1);
    assert(xHeightRatio(null, mono) == 1, "unmeasured: no shrink by it");
}

/**
The text measurer for a target that draws interface runs in a face of its
own (`LAY5`, design-system `GLY10`) — the native arm's Vulkan canvas: a cell
font run is as wide as its cells; an interface run (`FontRole.ui`,
`FontRole.docs`) as wide as `faces` draws it at its type step, rounded up to
whole cells, and as many rows as that step's glyph box needs. A `uiMono` run,
which the canvas draws in the cell font, and any run where `faces` has no
face at its step, keeps the cell font's extent. So layout, the display list
and the canvas agree on every run.

`Faces` answers `interfaceWidthPx(text, step, bold)` — pixels, negative
where it has no face at `step` — and `interfaceStep(step)`, whose `present`
and `size` (the glyph box, in pixels) describe the face. Not `active`, it is
the cell measure.
*/
struct InterfaceMeasure(Faces)
{
    import sparkles.base.text.grapheme : visibleWidth;
    import sparkles.ui.geometry : Size;
    import sparkles.ui.pixel_geometry : cellsCeil;
    import sparkles.ui.style : FontRole, TextStyle, uiStepOf;

    Faces faces;  /// the interface faces
    bool active;  /// whether runs are measured in `faces`; off: cell metrics only
    int cellW = 1; /// one cell's width, in the faces' pixels
    int cellH = 1; /// one cell's height, in the same pixels

    /// Advances add, and kerning never takes back a whole glyph, so a prefix
    /// never measures wider than its run: the wrap solver's linear search.
    enum bool monotonePrefixes = true;

    /// The cell font's width of `s`.
    int width(scope const(char)[] s) const @safe pure nothrow @nogc
        => cast(int) visibleWidth(s);

    /**
    A complete-brush cursor (`isIncrementalTextMeasure`): a rich run's
    cumulative extent after each whole-grapheme chunk, in one pass over it —
    without it the layout measures every prefix of the run again. Chunks are
    measured apart, so kerning across their seams is not counted: a kerned
    pair split by a seam measures by its letters' own advances, which for
    the usual (tightening) kerning is a little wider than the canvas draws.
    */
    BrushMetrics brushMetrics(in TextStyle style)
        => BrushMetrics(faces, faceStep(style), style.bold, cellW);

    /// ditto
    static struct BrushMetrics
    {
        private Faces faces;
        private int step; // -1: the cell font
        private bool bold;
        private int cellW;
        private double pixels = 0;
        private int cells;

        /// Appends one or more complete graphemes; the run's extent so far,
        /// in whole cells.
        int append(scope const(char)[] text)
        {
            const px = step < 0 ? -1 : faces.interfaceWidthPx(text, step, bold);
            if (px < 0)
                cells += cast(int) visibleWidth(text);
            else
                pixels += px;
            return cells + cellsCeil(cast(float) pixels, cellW);
        }
    }

    /// The width of `s` in `style`, in whole cells.
    int width(scope const(char)[] s, in TextStyle style)
    {
        const step = faceStep(style);
        if (step < 0)
            return cast(int) visibleWidth(s);
        const px = faces.interfaceWidthPx(s, step, style.bold);
        return px < 0 ? cast(int) visibleWidth(s) : cellsCeil(cast(float) px, cellW);
    }

    /// The rows one line in `style` occupies: as many as its glyph box needs.
    int rows(in TextStyle style)
    {
        const step = faceStep(style);
        if (step < 0)
            return 1;
        const s = faces.interfaceStep(step);
        const n = s.present ? cellsCeil(s.size, cellH) : 1;
        return n < 1 ? 1 : n;
    }

    /// The image cell size, so `IMG2` images lay out as on the canvas.
    Size cellPixels() const @safe pure nothrow @nogc => Size(cellW, cellH);

    // The type step `style` draws in an interface face at, or -1 for the
    // cell font.
    private int faceStep(in TextStyle style) const @safe pure nothrow @nogc
        => !active || style.fontRole == FontRole.uiMono ? -1
            : uiStepOf(style.fontRole, style.typeStep, style.fontScale);
}

version (unittest)
{
    // An interface face of a 14 px box (16 px at the title step), `i` 3 px
    // and every other character 7 px; none at the caption step.
    private struct FakeFaces
    {
        static struct Step
        {
            bool present;
            int size;
        }

        double interfaceWidthPx(scope const(char)[] text, int step, bool bold) @safe pure nothrow @nogc
        {
            if (step == TypeStep.caption)
                return -1;
            double px = 0;
            foreach (c; text)
                px += c == 'i' ? 3 : bold ? 8 : 7;
            return px;
        }

        Step interfaceStep(int step) const @safe pure nothrow @nogc
            => step == TypeStep.caption ? Step.init : Step(true, step == TypeStep.title ? 30 : 14);
    }
}

///
@("ui_app.interface_font.InterfaceMeasure")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.layout : isStyledTextMeasure, monotoneMeasurePrefixes;
    import sparkles.ui.style : FontRole, TextStyle;

    static assert(isStyledTextMeasure!(InterfaceMeasure!FakeFaces));
    static assert(monotoneMeasurePrefixes!(InterfaceMeasure!FakeFaces));

    FakeFaces faces;
    auto m = InterfaceMeasure!FakeFaces(faces, true, cellW: 10, cellH: 20);
    const ui = TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.body);
    // By the face's advances, rounded up to cells: 7 + 3 + 3 = 13 px, two cells.
    assert(m.width("Wii", ui) == 2 && m.width("WWWW", ui) == 3);
    TextStyle bold = ui;
    bold.bold = true;
    assert(m.width("WWWWW", bold) == 4, "the bold face's advances");
    assert(m.rows(ui) == 1);
    const title = TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.title);
    assert(m.rows(title) == 2, "a 30 px box takes two 20 px rows");
    // Docs runs draw in the interface face too; uiMono and code in the cells.
    assert(m.width("Wii", TextStyle(fontRole: FontRole.docs)) == 2);
    assert(m.width("Wii", TextStyle(fontRole: FontRole.uiMono)) == 3);
    assert(m.width("Wii", TextStyle.init) == 3);
    // A step without a face keeps the cell font's extent.
    const caption = TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.caption);
    assert(m.width("Wii", caption) == 3 && m.rows(caption) == 1);
    // No faces: the cell measure.
    auto cells = InterfaceMeasure!FakeFaces(faces, false, 10, 20);
    assert(cells.width("Wii") == 3 && cells.width("Wii", ui) == 3);
}

@("ui_app.interface_font.InterfaceMeasure.brushMetrics")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.layout : isIncrementalTextMeasure;
    import sparkles.ui.style : FontRole, TextStyle;

    static assert(isIncrementalTextMeasure!(InterfaceMeasure!FakeFaces));
    FakeFaces faces;
    auto m = InterfaceMeasure!FakeFaces(faces, true, cellW: 10, cellH: 20);
    const ui = TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.body);
    // The run's extent so far, rounded once: 7, 10, 13 px.
    auto run = m.brushMetrics(ui);
    assert(run.append("W") == 1 && run.append("i") == 1 && run.append("i") == 2);
    assert(m.width("Wii", ui) == 2, "the whole run, as the cursor ended");
    // In the cells where the run has no face.
    auto mono = m.brushMetrics(TextStyle(fontRole: FontRole.uiMono));
    assert(mono.append("W") == 1 && mono.append("ii") == 3);
    auto off = InterfaceMeasure!FakeFaces(faces, false, 10, 20).brushMetrics(ui);
    assert(off.append("Wii") == 3);
}
