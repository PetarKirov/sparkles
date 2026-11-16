/**
Families for a font picker and the document font's controls
(`docs/specs/font/discovery.md` FTD47–FTD51).

A catalog lists faces; a picker lists families. $(LREF collectFamilies)
groups a catalog's records into $(LREF FontFamily) values: the family's
name, whether it is monospace, the real member each of the four styles
resolves to (matching under FTD27 with synthesis off, so a member is real or
absent, never faked), and the `wght` and `opsz` axes its regular member
declares. $(LREF DocumentFont) holds the settings a code editor offers over
one family, with static bounds; $(LREF fontControls) reports which of them a
family supports, so an application can show the rest as unavailable rather
than hide that it cannot honour them. Nothing here renders, and nothing
allocates.
*/
module sparkles.font.families;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.metadata : Description, Label, Range;

import sparkles.font.catalog : Catalog, SourceKind;
import sparkles.font.cmap : CodepointRange;
import sparkles.font.errors : Tag;
import sparkles.font.face : Face;
import sparkles.font.face_record : FaceRecord, StringRef;
import sparkles.font.instance : UserCoordinate;
import sparkles.font.layout : features, LayoutTable;
import sparkles.font.matching : fixedOne, matchFont, MatchRequest, StyleRequest;
import sparkles.font.tables : Spacing;

/// The four members a code font's text draws in (FTD47).
enum FamilyStyle : ubyte
{
    regular,
    bold,
    italic,
    boldItalic,
}

/// The member of a family that realizes one style (FTD47).
struct StyleFace
{
    @safe pure nothrow @nogc:

    /// The record's index in the catalog; `uint.max` when the family has no such member.
    uint record = uint.max;
    /// The variable-axis coordinates realizing the style (`wght` 700 for a variable bold).
    UserCoordinate[4] coordinates;
    ubyte coordinateCount;

    /// Whether the family has a real member for the style.
    bool present() const scope => record != uint.max;

    /// The coordinates as a slice.
    const(UserCoordinate)[] userCoordinates() const return => coordinates[0 .. coordinateCount];
}

/// A variable axis a family declares, in user units (F16.16).
struct DeclaredAxis
{
    @safe pure nothrow @nogc:

    bool declared;
    int minValue, defaultValue, maxValue;

    /// `value` (F16.16) clamped into the axis.
    int clamp(int value) const scope
        => value < minValue ? minValue : value > maxValue ? maxValue : value;
}

/// A family as a picker lists it (FTD47–FTD49).
struct FontFamily
{
    @safe pure nothrow @nogc:

    /// The family name, in the catalog's storage.
    StringRef name;
    /// The real member of each style, indexed by `FamilyStyle`.
    StyleFace[4] styles;
    /**
    The regular member draws code (FTD48): its advances are one width, or two
    (a CJK face's half and full widths), and it covers the ASCII letters and
    digits, so a symbol or emoji face of one advance is not offered.
    */
    bool monospace;
    /// The regular member's `wght` and `opsz` axes (FTD49).
    DeclaredAxis weight, opticalSize;
    /// Whether any member is a variable face.
    bool variable;

    /// The member realizing `style`.
    ref const(StyleFace) opIndex(FamilyStyle style) const return => styles[style];
}

/**
The catalog's families, in ASCII-folded name order, appended to `into`
(FTD47–FTD49). Each family's styles are matched with synthesis off: bold is
present only for a member of weight 600 or more, italic only for an italic
member or one slanted forward. Costs O(F · m) for `F` families of at most
`m` records; allocates only `into`'s storage.
*/
void collectFamilies(ref const Catalog catalog, ref UniqueBuffer!FontFamily into) @safe nothrow @nogc
{
    // `eachFamily` hands the name out; the family is kept by its first record's name reference.
    catalog.eachFamily((scope const(char)[] name, uint first) {
        FontFamily f;
        f.name = catalog.records[first].family;
        foreach (i, ref s; f.styles)
            s = styleFace(catalog, f.name, cast(FamilyStyle) i);
        if (!f.styles[FamilyStyle.regular].present)
            return;
        const regular = catalog.records[f.styles[FamilyStyle.regular].record];
        f.monospace = regular.spacingKnown && regular.spacing != Spacing.proportional
            && coversAsciiAlphanumerics(catalog, regular);
        foreach (axis; catalog.pools.axesOf(regular))
        {
            if (axis.tag == Tag("wght"))
                f.weight = DeclaredAxis(true, axis.minValue, axis.defaultValue, axis.maxValue);
            else if (axis.tag == Tag("opsz"))
                f.opticalSize = DeclaredAxis(true, axis.minValue, axis.defaultValue, axis.maxValue);
        }
        foreach (s; f.styles)
            if (s.present)
                f.variable |= catalog.records[s.record].axes.count != 0;
        into.put(f);
    });
}

/// Whether `r` covers `0`–`9`, `A`–`Z` and `a`–`z`.
private bool coversAsciiAlphanumerics(ref const Catalog catalog, in FaceRecord r) @safe pure nothrow @nogc
{
    static immutable CodepointRange[3] wanted = [
        CodepointRange('0', '9'), CodepointRange('A', 'Z'), CodepointRange('a', 'z')];
    foreach (range; wanted)
        foreach (dchar cp; range.first .. range.last + 1)
            if (!catalog.pools.covers(r, cp))
                return false;
    return true;
}

/// The member of `family` realizing `style`, or an absent one (FTD47).
private StyleFace styleFace(ref const Catalog catalog, StringRef family, FamilyStyle style)
    @safe pure nothrow @nogc
{
    const bold = style == FamilyStyle.bold || style == FamilyStyle.boldItalic;
    const slanted = style == FamilyStyle.italic || style == FamilyStyle.boldItalic;
    const(char[])[1] names = [catalog.text(family)];
    scope MatchRequest request;
    request.families = names[];
    request.weight = (bold ? 700 : 400) * fixedOne;
    request.style = slanted ? StyleRequest.italic : StyleRequest.normal;
    request.synthesizeWeight = false;
    request.synthesizeStyle = false;
    const m = matchFont(catalog, request);
    StyleFace face;
    if (m.hasError || !m.value.found)
        return face;
    const match = m.value;
    if (bold && match.weight < 600 * fixedOne)
        return face;
    const forward = match.italic != 0 || match.oblique > 0;
    // Regular is whatever the family has nearest; bold and the slanted styles must be real.
    if (slanted ? !forward : bold && forward)
        return face;
    face.record = match.record;
    face.coordinates = match.coordinates;
    face.coordinateCount = match.coordinateCount;
    return face;
}

/**
Where record `record`'s bytes are, written to `w`: the source directory and
the record's identity joined by `/`, or the identity alone for a platform
source, which lists absolute paths. A memory source has no path and writes
nothing; the return says whether a path was written.
*/
bool writeRecordPath(Writer)(ref const Catalog catalog, uint record, ref Writer w)
{
    import std.range.primitives : put;

    const r = catalog.records[record];
    const source = catalog.sources[r.source];
    if (source.kind == SourceKind.memory)
        return false;
    if (source.kind != SourceKind.platform)
    {
        const dir = catalog.text(source.path);
        put(w, dir);
        if (dir.length && dir[$ - 1] != '/')
            put(w, '/');
    }
    put(w, catalog.text(r.identity));
    return true;
}

/// Whether a face's `GSUB` turns ligatures on, as the controls report it (FTD50).
enum LigatureSupport : ubyte
{
    /// The face's bytes have not been read; the catalog records no features.
    unknown,
    /// Neither `liga`, `calt` nor `dlig` in the default or Latin language system.
    none,
    /// The face declares at least one of them.
    declared,
}

/**
Whether `face` declares `liga`, `calt` or `dlig` for the `DFLT` or `latn`
script's default language system (FTD50); an unreadable or absent `GSUB` is
`none`. Costs O(features of two language systems).
*/
LigatureSupport ligatureSupport(scope const Face face) @safe pure nothrow @nogc
{
    static immutable Tag[2] scripts = [Tag("DFLT"), Tag("latn")];
    foreach (script; scripts)
    {
        auto list = features(face, LayoutTable.gsub, script, Tag.init);
        if (list.hasError)
            continue;
        foreach (i; 0 .. list.value.length)
        {
            const f = list.value[i];
            if (f.hasValue && (f.value.tag == Tag("liga") || f.value.tag == Tag("calt")
                    || f.value.tag == Tag("dlig")))
                return LigatureSupport.declared;
        }
    }
    return LigatureSupport.none;
}

/**
The document font: what a code editor sets over one family (FTD51). The
bounds are static; `weight` and `opticalSize` mean something only for a
family declaring the axis, and $(LREF fitTo) narrows them to it. Document
and interface typography are separate values: nothing here reads or sets
the interface font.
*/
struct DocumentFont
{
    @safe pure nothrow @nogc:

    /// The family name; empty for the application's default monospace face.
    @Label("Family") string family;
    /// The em size, in pixels.
    @Label("Size") @Range(6, 72, 1) float size = 14;
    /// Whether `liga`, `calt` and `dlig` apply.
    @Label("Ligatures") bool ligatures = true;
    /// The line's height, a multiple of the font's own line height.
    @Label("Line height") @Range(1.0, 2.5, 0.05) float lineHeight = 1.2;
    /// Extra space after each cell, in pixels.
    @Label("Letter spacing") @Range(-2, 4, 0.1) float letterSpacing = 0;
    /// The regular and italic members' `wght`, where the family declares it.
    @Label("Weight") @Range(1, 1000, 1) float weight = 400;
    /// `opsz`, where declared; 0 follows `size`, as CSS's `font-optical-sizing: auto` does.
    @Label("Optical size") @Description("0 follows the size") @Range(0, 144, 0.5) float opticalSize = 0;

    /// The bounds this type declares.
    enum float minSize = 6, maxSize = 72;
    enum float minLineHeight = 1.0, maxLineHeight = 2.5;
    enum float minLetterSpacing = -2, maxLetterSpacing = 4;
    enum float minWeight = 1, maxWeight = 1000;
    enum float maxOpticalSize = 144;

    /// Every field inside its static bounds; a NaN takes the field's default.
    DocumentFont clamped() const return scope
    {
        DocumentFont d = this;
        d.size = bound(size, minSize, maxSize, DocumentFont.init.size);
        d.lineHeight = bound(lineHeight, minLineHeight, maxLineHeight, DocumentFont.init.lineHeight);
        d.letterSpacing = bound(letterSpacing, minLetterSpacing, maxLetterSpacing, 0);
        d.weight = bound(weight, minWeight, maxWeight, DocumentFont.init.weight);
        d.opticalSize = bound(opticalSize, 0, maxOpticalSize, 0);
        return d;
    }

    /// `clamped`, with `weight` and a set `opticalSize` inside `controls`' declared axes.
    DocumentFont fitTo(in FontControls controls) const return scope
    {
        DocumentFont d = clamped();
        if (controls.weightAxis.declared)
            d.weight = bound(d.weight, toFloat(controls.weightAxis.minValue),
                toFloat(controls.weightAxis.maxValue), toFloat(controls.weightAxis.defaultValue));
        if (controls.opticalSizeAxis.declared && d.opticalSize != 0)
            d.opticalSize = bound(d.opticalSize, toFloat(controls.opticalSizeAxis.minValue),
                toFloat(controls.opticalSizeAxis.maxValue), 0);
        return d;
    }
}

private float bound(float v, float lo, float hi, float otherwise) @safe pure nothrow @nogc
    => v != v ? otherwise : v < lo ? lo : v > hi ? hi : v;

private float toFloat(int fixed) @safe pure nothrow @nogc => fixed / cast(float) fixedOne;

private int toFixed(float v) @safe pure nothrow @nogc => cast(int)(v * fixedOne + (v < 0 ? -0.5f : 0.5f));

/// One control the document font offers (FTD51).
enum FontControl : ubyte
{
    size,
    lineHeight,
    letterSpacing,
    bold,
    italic,
    boldItalic,
    ligatures,
    weight,
    opticalSize,
}

/// Whether a control applies to a family (FTD51).
enum ControlState : ubyte
{
    /// The family honours it.
    available,
    /// The family cannot: show it, disabled, with why.
    unsupported,
    /// Not known until the face is read (ligatures before `ligatureSupport`).
    unknown,
}

/// What a family supports of the document font's controls (FTD51).
struct FontControls
{
    @safe pure nothrow @nogc:

    /// Real members, indexed by `FamilyStyle`.
    bool[4] styles;
    LigatureSupport ligatures;
    DeclaredAxis weightAxis, opticalSizeAxis;

    /// The state of `control`: size, line height and letter spacing always apply.
    ControlState state(FontControl control) const scope
    {
        final switch (control)
        {
            case FontControl.size:
            case FontControl.lineHeight:
            case FontControl.letterSpacing:
                return ControlState.available;
            case FontControl.bold:
                return styles[FamilyStyle.bold] ? ControlState.available : ControlState.unsupported;
            case FontControl.italic:
                return styles[FamilyStyle.italic] ? ControlState.available : ControlState.unsupported;
            case FontControl.boldItalic:
                return styles[FamilyStyle.boldItalic] ? ControlState.available : ControlState.unsupported;
            case FontControl.ligatures:
                return ligatures == LigatureSupport.declared ? ControlState.available
                    : ligatures == LigatureSupport.none ? ControlState.unsupported : ControlState.unknown;
            case FontControl.weight:
                return weightAxis.declared ? ControlState.available : ControlState.unsupported;
            case FontControl.opticalSize:
                return opticalSizeAxis.declared ? ControlState.available : ControlState.unsupported;
        }
    }

    /// Whether `control` is shown enabled.
    bool supports(FontControl control) const scope => state(control) == ControlState.available;
}

/// What `family` supports, with `ligatures` from `ligatureSupport` once its face is read (FTD51).
FontControls fontControls(in FontFamily family, LigatureSupport ligatures = LigatureSupport.unknown)
    @safe pure nothrow @nogc
{
    FontControls c;
    foreach (i, s; family.styles)
        c.styles[i] = s.present;
    c.ligatures = ligatures;
    c.weightAxis = family.weight;
    c.opticalSizeAxis = family.opticalSize;
    return c;
}

/**
The user coordinates of `style`'s member under `font` (FTD51), written into
`into`; returns how many. The member's own coordinates come first (a
variable bold's `wght` 700, an `ital` 1); then, where the family declares
the axis, the regular and italic members take `font.weight` as `wght`, and
every member takes `opsz` from `font.opticalSize`, or from `font.size` when
that is 0. Each value is clamped into its axis.
*/
size_t instanceCoordinates(in FontFamily family, FamilyStyle style, in DocumentFont font,
    ref UserCoordinate[6] into) @safe pure nothrow @nogc
{
    const member = family.styles[style];
    size_t n;
    void set(Tag tag, int value)
    {
        foreach (ref c; into[0 .. n])
            if (c.tag == tag)
            {
                c.value = value;
                return;
            }
        into[n++] = UserCoordinate(tag, value);
    }

    foreach (c; member.userCoordinates)
        set(c.tag, c.value);
    const d = font.clamped();
    const upright = style == FamilyStyle.regular || style == FamilyStyle.italic;
    if (family.weight.declared && upright)
        set(Tag("wght"), family.weight.clamp(toFixed(d.weight)));
    if (family.opticalSize.declared)
        set(Tag("opsz"), family.opticalSize.clamp(toFixed(d.opticalSize != 0 ? d.opticalSize : d.size)));
    return n;
}

///
@("families.documentFont.clamped")
@safe pure nothrow @nogc
unittest
{
    DocumentFont d;
    d.size = 200;
    d.lineHeight = 0.5;
    d.letterSpacing = float.nan;
    d.weight = -3;
    d.opticalSize = 1_000;
    const c = d.clamped();
    assert(c.size == 72 && c.lineHeight == 1.0 && c.letterSpacing == 0 && c.weight == 1);
    assert(c.opticalSize == 144 && c.ligatures && DocumentFont.init.clamped() == DocumentFont.init);
}

///
@("families.documentFont.fitTo")
@safe pure nothrow @nogc
unittest
{
    FontControls controls;
    controls.weightAxis = DeclaredAxis(true, 300 * fixedOne, 400 * fixedOne, 700 * fixedOne);
    controls.opticalSizeAxis = DeclaredAxis(true, 8 * fixedOne, 12 * fixedOne, 60 * fixedOne);
    DocumentFont d;
    d.weight = 900;
    d.opticalSize = 4;
    const f = d.fitTo(controls);
    assert(f.weight == 700 && f.opticalSize == 8);
    d.opticalSize = 0;
    assert(d.fitTo(controls).opticalSize == 0, "0 keeps following the size");
    assert(d.fitTo(FontControls.init).weight == 900, "no axis, no narrowing");
}

///
@("families.controls.state")
@safe pure nothrow @nogc
unittest
{
    FontFamily family;
    family.styles[FamilyStyle.regular].record = 0;
    family.styles[FamilyStyle.bold].record = 1;
    auto c = fontControls(family);
    assert(c.supports(FontControl.size) && c.supports(FontControl.lineHeight)
        && c.supports(FontControl.letterSpacing) && c.supports(FontControl.bold));
    assert(c.state(FontControl.italic) == ControlState.unsupported
        && c.state(FontControl.weight) == ControlState.unsupported
        && c.state(FontControl.opticalSize) == ControlState.unsupported);
    assert(c.state(FontControl.ligatures) == ControlState.unknown);
    assert(fontControls(family, LigatureSupport.none).state(FontControl.ligatures) == ControlState.unsupported);
    family.weight.declared = true;
    assert(fontControls(family, LigatureSupport.declared).supports(FontControl.weight)
        && fontControls(family, LigatureSupport.declared).supports(FontControl.ligatures));
}

///
@("families.instanceCoordinates")
@safe pure nothrow @nogc
unittest
{
    FontFamily family;
    family.weight = DeclaredAxis(true, 100 * fixedOne, 400 * fixedOne, 900 * fixedOne);
    family.opticalSize = DeclaredAxis(true, 8 * fixedOne, 14 * fixedOne, 32 * fixedOne);
    family.styles[FamilyStyle.bold].coordinates[0] = UserCoordinate(Tag("wght"), 700 * fixedOne);
    family.styles[FamilyStyle.bold].coordinateCount = 1;
    DocumentFont d;
    d.weight = 350;
    d.size = 40;
    UserCoordinate[6] c;
    assert(instanceCoordinates(family, FamilyStyle.regular, d, c) == 2);
    assert(c[0] == UserCoordinate(Tag("wght"), 350 * fixedOne) && c[1] == UserCoordinate(Tag("opsz"), 32 * fixedOne));
    assert(instanceCoordinates(family, FamilyStyle.bold, d, c) == 2);
    assert(c[0] == UserCoordinate(Tag("wght"), 700 * fixedOne), "bold keeps its member's weight");
    d.opticalSize = 10;
    assert(instanceCoordinates(family, FamilyStyle.italic, d, c) == 2 && c[1].value == 10 * fixedOne);
    assert(instanceCoordinates(FontFamily.init, FamilyStyle.regular, d, c) == 0, "static family: no coordinates");
}
