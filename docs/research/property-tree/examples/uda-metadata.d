#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_uda_metadata"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * What a UDA metadata channel can and cannot answer before the frame.
 *
 * Backs [../comparison.md](../comparison.md) § _metadata_ and § _conditional
 * visibility_. Every surveyed library carries per-field metadata beside the
 * type — [.NET attributes](../winforms-propertygrid.md) (`[Category]`,
 * `[Browsable]`, `[Editor]`), [Godot's](../godot-inspector.md) `PropertyInfo`
 * hint/hint_string/usage triple,
 * [Unreal's](../unreal-details-panel.md) `UPROPERTY(meta=…)` string map, and
 * [`InspectorOptions`](../bevy-inspector-egui.md) in a type registry. Three of
 * those four are **runtime** tables, so a condition can be an arbitrary
 * expression evaluated per frame; Godot's `_validate_property` rewrites the
 * usage flags on every rebuild.
 *
 * D's UDAs are the compile-time member of that family, and this program shows
 * the resulting split:
 *
 *   * **Static metadata** (label, group, range, hidden) is a compile-time
 *     constant, so the row's shape can be a manifest constant like the descent
 *     in [`reflect-descent.d`](./reflect-descent.d).
 *   * **A condition over the value** ("show `stops` only for a gradient") cannot
 *     be, so it must be carried _as data_ — here a function pointer in the UDA
 *     evaluated against the live subject. That is the whole seam: a UDA can hold
 *     a predicate, but somebody must run it per frame, and the answer changes the
 *     row set, not just a row's style.
 *
 * Run: `dub run --single uda-metadata.d`
 */
module property_tree_uda_metadata;

import std.stdio : writefln, writeln;
import std.traits : FieldNameTuple, Fields, getUDAs, hasUDA;

@safe:

// --- the metadata vocabulary, as UDAs ---------------------------------------

struct Label { string text; }
struct Group { string name; }
struct Range { double min, max; }
struct Hidden {}
/// A condition over the whole subject, carried as data because it cannot be a
/// compile-time constant.
struct ShowIf { bool function(const scope void*) @safe pure nothrow test; }

// --- the subject ------------------------------------------------------------

enum FillKind { solid, gradient }

struct FillSettings
{
    @Label("Fill kind") @Group("Appearance")
    FillKind kind;

    @Label("Colour") @Group("Appearance")
    string color = "#808080";

    @Label("Stops") @Group("Appearance") @Range(2, 16)
    @ShowIf(&isGradient)
    int stops = 2;

    @Hidden
    ulong revision;
}

private bool isGradient(const scope void* subject) @safe pure nothrow
{
    // The predicate is written against the subject type it belongs to; the
    // component only ever sees `bool function(...)`.
    return (() @trusted => (cast(const FillSettings*) subject).kind)()
        == FillKind.gradient;
}

// --- what the component can compute, and when -------------------------------

struct RowPlan
{
    string field;
    string label;
    string group;
    string range;    /// empty when unconstrained
    bool conditional; /// visibility depends on the live value
}

/// Everything derivable from the type alone. Runs in CTFE.
RowPlan[] planRows(T)() pure nothrow
{
    RowPlan[] plan;
    static foreach (i, name; FieldNameTuple!T)
    {{
        alias member = __traits(getMember, T, name);
        static if (!hasUDA!(member, Hidden))
        {
            alias labels = getUDAs!(member, Label);
            alias groups = getUDAs!(member, Group);
            alias ranges = getUDAs!(member, Range);

            static if (labels.length) enum label = labels[0].text; else enum label = name;
            static if (groups.length) enum group = groups[0].name; else enum group = "";
            static if (ranges.length) enum range = rangeText(ranges[0]); else enum range = "";

            plan ~= RowPlan(name, label, group, range, hasUDA!(member, ShowIf));
        }
    }}
    return plan;
}

private string rangeText(Range r) pure
{
    import std.conv : text;
    return text("[", r.min, " … ", r.max, "]");
}

/// The rows actually visible for a given value. Needs the subject; runs per frame.
string[] visibleRows(T)(ref const T subject) @trusted
{
    string[] visible;
    static foreach (name; FieldNameTuple!T)
    {{
        alias member = __traits(getMember, T, name);
        static if (!hasUDA!(member, Hidden))
        {
            enum conds = getUDAs!(member, ShowIf);
            static if (conds.length)
            {
                if (conds[0].test(cast(const void*) &subject))
                    visible ~= name;
            }
            else
                visible ~= name;
        }
    }}
    return visible;
}

void main()
{
    enum plan = planRows!FillSettings(); // a compile-time constant

    writeln("field    label        group        range        conditional");
    foreach (r; plan)
        writefln("%-8s %-12s %-12s %-12s %s", r.field, r.label, r.group,
            r.range.length ? r.range : "-", r.conditional ? "yes" : "no");

    writeln();
    writefln("`revision` is absent from the plan: %s",
        !hasField(plan, "revision"));

    writeln();
    FillSettings s;
    writefln("kind=%s  visible=%s", s.kind, visibleRows(s));
    s.kind = FillKind.gradient;
    writefln("kind=%s  visible=%s", s.kind, visibleRows(s));
}

private bool hasField(in RowPlan[] plan, string name) pure nothrow @nogc
{
    foreach (r; plan)
        if (r.field == name)
            return true;
    return false;
}
