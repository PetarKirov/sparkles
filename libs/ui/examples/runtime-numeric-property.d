#!/usr/bin/env dub
/+ dub.sdl:
    name "runtime_numeric_property"
    targetPath "build"
    dependency "sparkles:ui" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
module runtime_numeric_property;

import std.stdio : writeln;
import sparkles.ui.components.tree_view : TreeViewState;
import sparkles.ui.property_tree : EditValue, hidden, NumericInput,
    PreferredInput, PropertyTree, Range;

struct Weight
{
    @hidden double minimum = 100, maximum = 700, initial = 350;
    @PreferredInput(NumericInput.slider) double value = 350;

    Range propRange(string field) const @safe pure nothrow @nogc
        => field == "value" ? Range(minimum, maximum, 1)
            : Range(double.nan, double.nan);
    EditValue propDefault(string field) const @safe pure nothrow @nogc
        => field == "value" ? EditValue.of(initial) : EditValue.init;
}

void main()
{
    Weight weight;
    PropertyTree!Weight tree;
    TreeViewState!string view;
    tree.rebuild(weight, view);
    const node = tree.data.nodes[0].value;
    writeln(node.label, ": ", node.lo, "..", node.hi);
}
