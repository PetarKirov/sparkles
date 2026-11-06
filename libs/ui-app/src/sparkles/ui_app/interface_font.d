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
