#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_sumtype_variants"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The variant-switch problem, in D terms.
 *
 * Backs [../comparison.md](../comparison.md) § _polymorphic and sum-typed
 * values_. The sharpest evidence in the survey is
 * [`bevy-inspector-egui`](../bevy-inspector-egui.md): switching a Rust enum to
 * another variant means **constructing** that variant, so the library asks the
 * type registry whether every field of the candidate variant has a
 * `ReflectDefault` and _greys out the entries it cannot build_
 * (`variant_constructable`, `crates/bevy-inspector-egui/src/reflect_inspector/mod.rs:1885`).
 *
 * D moves that question twice, and this program measures both moves:
 *
 *   1. **Constructability is nearly free.** Every type has `.init`, so a picker
 *      almost never has to grey an entry out. The exception is an author's
 *      explicit `@disable this()`, which removes `T()` while leaving `T.init`
 *      readable — so "can I display it?" and "can I switch to it?" stay two
 *      questions, just with a much rarer gap between them.
 *   2. **The safety verdict, not the construction, is what bites.** Phobos'
 *      `SumType.opAssign` is `@system` whenever _some other_ member type has
 *      indirections, because overwriting the payload can invalidate a reference
 *      into it (`std/sumtype.d`, `unsafeToOverwrite`). A variant picker over an
 *      arbitrary `SumType` therefore cannot be `@safe` — the switch needs a
 *      `@trusted` seam whose precondition is that no one holds a pointer into
 *      the old payload, which is exactly the invariant a retained node model
 *      full of pointers-to-fields would break.
 *
 * The table this prints is the per-variant answer to all three questions.
 *
 * Run: `dub run --single sumtype-variants.d`
 */
module property_tree_sumtype_variants;

import std.stdio : writefln, writeln;
import std.sumtype : match, SumType;
import std.traits : FieldNameTuple;

@safe:

// --- the subject -----------------------------------------------------------

struct Solid
{
    string color = "#808080";
    float roughness = 0.5;
}

struct Gradient
{
    string from = "#000000";
    string to = "#ffffff";
    int stops = 2;
}

/// A variant whose author forbade default construction.
struct Textured
{
    string path;
    @disable this();
    this(string p) pure nothrow @nogc { path = p; }
}

/// Variants with no indirections at all — the one case Phobos can overwrite
/// safely, and only when every *other* member is equally plain.
struct Hidden
{
    ubyte alpha;
}

struct Flat
{
    int width, height;
}

alias Fill = SumType!(Solid, Gradient, Textured);
alias PlainFill = SumType!(Hidden, Flat);

// --- the picker's three questions ------------------------------------------

/// Can a picker offer this variant as a blank slate? `.init` always exists;
/// `T()` does not.
enum bool isBlankConstructable(T) = __traits(compiles, { T v = T(); });

/// Can the switch itself be written in `@safe` code?
enum bool isSafelyAssignable(S, T) = __traits(compiles, () @safe {
    S s = T.init;
    S other = S.init;
    other = T.init;
});

/// The rows this variant contributes, known at compile time.
string[] variantRows(T)() pure nothrow
{
    string[] rows;
    static foreach (name; FieldNameTuple!T)
        rows ~= name;
    return rows;
}

/// Perform the switch. The `@trusted` block is the seam the safety verdict
/// forces; its precondition is that nothing holds a reference into the payload.
void switchTo(S, T)(ref S value, T fresh) @trusted
{
    value = fresh;
}

void main()
{
    writeln("Fill = SumType!(Solid, Gradient, Textured)");
    writeln();
    writeln("variant     blank?  @safe switch?  rows");
    static foreach (T; Fill.Types)
        writefln("%-11s %-7s %-14s %s", T.stringof,
            isBlankConstructable!T ? "yes" : "no",
            isSafelyAssignable!(Fill, T) ? "yes" : "no",
            variantRows!T());

    writeln();
    writefln("a sum of indirection-free variants is @safe to switch: %s",
        isSafelyAssignable!(PlainFill, Hidden) ? "yes" : "no");

    writeln();
    // A switch is a whole-value replacement: the old variant's rows do not
    // migrate, and no per-field state can be carried across by the component.
    Fill fill = Solid("#ff0000", 0.2);
    writefln("before: rows=%s", rowsOf(fill));
    switchTo(fill, Gradient.init); // what a picker does on "choose Gradient"
    writefln("after:  rows=%s", rowsOf(fill));

    writeln();
    // `.init` stays readable even for the variant a picker must not offer blank.
    writefln("Textured.init.path is null: %s", Textured.init.path is null);
}

string[] rowsOf(in Fill fill)
    => fill.match!(
        (ref const Solid _) => variantRows!Solid(),
        (ref const Gradient _) => variantRows!Gradient(),
        (ref const Textured _) => variantRows!Textured());
