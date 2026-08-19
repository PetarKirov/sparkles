#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_type_only_instantiation"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// [`type-only-instantiation.d`](./type-only-instantiation.d) — is the CTFE limit about RECURSION, or about PATH-PARAMETERISED
/// INSTANTIATION? Same walk, type-only template parameters, evaluated at CTFE.
module property_tree_type_only_instantiation;

import std.traits : FieldNameTuple, Fields, isAggregateType, isPointer,
    isSomeString, PointerTarget;

struct Row { string path; string type; int depth; bool cut; }

/// Type-only template parameter; depth/prefix are RUNTIME (hence CTFE) values.
Row[] plan(T)(string prefix, int depth, int maxDepth) pure nothrow
{
    Row[] rows;
    static foreach (i, name; FieldNameTuple!T)
    {{
        alias F = Fields!T[i];
        static if (isPointer!F && isAggregateType!(PointerTarget!F))
            alias Target = PointerTarget!F;
        else
            alias Target = F;
        enum leaf = isSomeString!Target || !isAggregateType!Target;
        const path = prefix.length ? prefix ~ "." ~ name : name;
        static if (leaf)
            rows ~= Row(path, F.stringof, depth, false);
        else
        {
            const cut = depth + 1 >= maxDepth;
            rows ~= Row(path, F.stringof, depth, cut);
            if (!cut)
                rows ~= plan!Target(path, depth + 1, maxDepth);
        }
    }}
    return rows;
}

struct Vec2 { float x = 0, y = 0; }
struct Material { string name; Vec2 offset; }
struct Node { string label; Vec2 position; Material material; Node* parent; }

enum manifest = plan!Node("", 0, 3);   // ← evaluated at COMPILE TIME

void main()
{
    import std.stdio : writefln;
    writefln("CTFE manifest for a CYCLIC type: %s rows, %s cuts",
        manifest.length, () { int n; foreach (r; manifest) n += r.cut; return n; }());
    foreach (r; manifest)
        writefln("%*s%s : %s%s", r.depth * 2, "", r.path, r.type, r.cut ? "  ⋯" : "");
}
