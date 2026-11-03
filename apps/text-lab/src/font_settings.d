/** The generated lab settings, including runtime-shaped variable axes. */
module font_settings;

import std.conv : to;
import std.math : isFinite, round;
import std.string : split, strip;

import sparkles.font : axes, Face, name, Tag, UserCoordinate;
import sparkles.ui.property_tree : EditValue, hidden, Label, NumericInput,
    PreferredInput, Range, readOnly, Section, ShowIf;
import sparkles.ui_vulkan.text_rendering : Loupe, TextRendering;

/// One declared axis. Bounds/defaults are consumed by PropertyTree's dispatch.
struct AxisSetting
{
    @hidden uint tag;
    @hidden string title;
    @hidden double minimum, initial, maximum;
    @hidden bool visible = true;
    @hidden bool hiddenAxis;
    @ShowIf("visible") @PreferredInput(NumericInput.slider) double value;
    @hidden bool automatic;

    /// Stable identity survives reordering and is used by generated edit paths.
    ulong propElementKey() const @safe pure nothrow @nogc => tag;
    /// Runtime range applies equally to widgets, edits, undo and redo.
    Range propRange(string field) const @safe pure nothrow @nogc
        => field == "value" ? Range(minimum, maximum, 0)
            : Range(double.nan, double.nan);
    /// Reset means the font's declared default, rather than double.init.
    EditValue propDefault(string field) const @safe pure nothrow @nogc
        => field == "value" ? EditValue.of(initial) : EditValue.init;
    /// The font's label and four-character axis tag.
    string propLabel(string field) const @safe pure nothrow @nogc
        => field == "value" ? title : null;
    /// Automatic optical size remains visible but cannot be edited manually.
    bool propReadOnly(string field) const @safe pure nothrow @nogc
        => field == "value" && automatic;
}

/// Font controls; size is em size in points, independent of the UI cell grid.
struct FontSettings
{
    @hidden string path;
    @hidden uint index;
    @Label("Font") @readOnly string face = "Startup font";
    @Label("Size (pt)") @Range(4, 144, 0.25)
    @PreferredInput(NumericInput.slider) double size = 12;
    @Label("UI follows specimen") bool uiFollows;
    @Label("Cell-grid specimen") bool cellGrid;
    @Label("Family sibling styles") bool familyStyles;
    @Label("Automatic optical size") bool automaticOpticalSize;
    @Label("Show hidden axes") bool showHiddenAxes;
}

/// One subject for the generated sheet. No configuration file is required.
struct LabSettings
{
    @Section("Font") FontSettings font;
    @Section("Variable axes") AxisSetting[] axes;
    @Section("Rendering") TextRendering rendering;
    @Section("Loupe") Loupe loupe = Loupe(shown: true, sourceWidth: 40, sourceHeight: 24, scale: 8);
    @Label("Crosshair") bool crosshair;

    /// Effective coordinates; automatic opsz is displayed in the subject too.
    UserCoordinate[] coordinates() @safe
    {
        UserCoordinate[] result;
        foreach (ref a; axes)
        {
            a.visible = !a.hiddenAxis || font.showHiddenAxes;
            a.automatic = font.automaticOpticalSize && a.tag == Tag("opsz").value;
            if (font.automaticOpticalSize && a.tag == Tag("opsz").value)
                a.value = font.size < a.minimum ? a.minimum : font.size > a.maximum ? a.maximum : font.size;
            result ~= UserCoordinate(Tag(a.tag), cast(int) round(a.value * 65_536));
        }
        return result;
    }
}

/// Reads every declared axis, including custom tags and the hidden flag.
AxisSetting[] axisSettings(in Face face) @safe
{
    AxisSetting[] result;
    const names = name(face);
    foreach (entry; axes(face))
    {
        if (entry.hasError)
            continue;
        const a = entry.value;
        string label;
        int best = -1;
        if (names.hasValue)
            foreach (n; names.value.records)
            {
                if (n.hasError || n.value.nameID != a.axisNameID)
                    continue;
                const record = n.value;
                // Deterministic English preference, then Unicode, then the
                // first decodable record. The tag always remains visible.
                const priority = record.languageID == 0x409 ? 3 : record.platformID == 0 ? 2 : 1;
                if (priority <= best)
                    continue;
                const count = record.decodedLength;
                if (count.hasError || count.value > 4096)
                    continue;
                auto buffer = new char[count.value];
                const decoded = record.decode(buffer);
                if (decoded.hasValue)
                {
                    label = decoded.value.idup;
                    best = priority;
                }
            }
        const chars = a.axisTag.chars;
        const tag = chars[].idup;
        if (!label.length)
            label = tag;
        else
            label ~= " (" ~ tag ~ ")";
        result ~= AxisSetting(a.axisTag.value, label, a.minValue / 65_536.0,
            a.defaultValue / 65_536.0, a.maxValue / 65_536.0,
            (a.flags & 1) == 0, (a.flags & 1) != 0, a.defaultValue / 65_536.0);
    }
    return result;
}

/// Parses explicit axis coordinates, rejecting unknown tags and bad domains.
string applyVariations(ref AxisSetting[] settings, string specification) @safe
{
    if (!specification.length)
        return null;
    bool[uint] seen;
    auto candidate = settings.dup;
    foreach (part; specification.split(","))
    {
        const pair = part.split("=");
        if (pair.length != 2 || pair[0].strip.length != 4)
            return "--font-variation takes TAG=VALUE pairs separated by commas";
        const tag = Tag(pair[0].strip).value;
        if (tag in seen)
            return "duplicate variation axis: " ~ pair[0];
        seen[tag] = true;
        double value;
        try value = pair[1].strip.to!double;
        catch (Exception) return "invalid variation value: " ~ pair[1];
        bool found;
        foreach (ref a; candidate)
            if (a.tag == tag)
            {
                found = true;
                if (!value.isFinite || value < a.minimum || value > a.maximum)
                    return "variation outside the font's axis range: " ~ pair[0];
                a.value = value;
            }
        if (!found)
            return "font does not declare axis: " ~ pair[0];
    }
    settings = candidate;
    return null;
}

/// Custom axes obey their own ranges, and malformed input is rejected.
@("text_lab.axes.customTagsAndValidation")
@safe unittest
{
    AxisSetting[] values = [AxisSetting(Tag("HGHT").value, "Height", 0, 0, 100, true, false, 0)];
    assert(applyVariations(values, "HGHT=25") is null && values[0].value == 25);
    foreach (bad; ["wght=400", "HGHT=101", "HGHT=nan", "HGHT=", "HGHT=2,HGHT=3", "H=2"])
    {
        assert(applyVariations(values, bad).length, bad);
        assert(values[0].value == 25, "invalid arguments must not partially change axes");
    }
    assert(applyVariations(values, "HGHT=50,wght=400").length);
    assert(values[0].value == 25);
}

/// Runtime bounds, defaults and hidden axes are shared by presentation and edits.
@("text_lab.axes.runtimeBoundsDefaultsAndVisibility")
@system unittest
{
    import sparkles.ui.components.settings_pane : SettingsPane;

    LabSettings model;
    model.axes = [AxisSetting(Tag("HGHT").value, "Height", -10, 2.5, 10, true, false, 2.5),
        AxisSetting(Tag("opsz").value, "Optical", 6, 12, 72, false, true, 12)];
    SettingsPane!LabSettings pane;
    pane.open(&model, model);
    pane.tv.open = typeof(pane.tv.open).allOpen;
    pane.refresh();
    string path;
    foreach (ref const node; pane.tree.data.nodes)
    {
        if (node.value.label == "Height") path = node.value.path;
        assert(node.value.label != "Optical");
    }
    assert(path.length);
    cast(void) pane.setAt(path, EditValue.of(9.0));
    assert(model.axes[0].value == 9);
    cast(void) pane.setAt(path, EditValue.of(11.0));
    assert(model.axes[0].value == 9 && pane.edits.refusalFor(path).refused);
    cast(void) pane.resetAt(path);
    assert(model.axes[0].value == 2.5);
    model.font.showHiddenAxes = true;
    model.font.automaticOpticalSize = true;
    model.font.size = 30;
    const coords = model.coordinates();
    assert(coords.length == 2 && model.axes[1].visible && model.axes[1].value == 30);
    pane.refresh();
    bool optical;
    foreach (ref const node; pane.tree.data.nodes) optical |= node.value.label == "Optical";
    assert(optical);
}
