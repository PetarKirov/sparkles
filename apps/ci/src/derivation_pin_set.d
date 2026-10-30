/**
The pin set as values: the flake's `legacyPackages.<system>.pinTargets`
(`nix/pin-targets.nix`, TC24) expanded across Sparkles' hosts, and the
selectors that filter it.

Nothing here runs a command or touches the network: the launcher evaluates
the set, then hands the answers to these functions.
*/
module derivation_pin_set;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.format : format;
import std.json : JSONException, JSONType, JSONValue, parseJSON;

import expected : Expected, err, ok;

/// The hosts whose pin set the cache holds, in expansion order (TC21).
immutable string[] pinSystems = ["x86_64-linux", "aarch64-darwin", "aarch64-linux"];

/// One `pinTargets` entry for one system, pinned as `<name>-<system>`.
struct Target
{
    string name;
    string system;
    string outPath; /// From evaluation; empty when not evaluated.

    /// The cache's pin name.
    string pinName() const @safe pure nothrow => name ~ "-" ~ system;

    /// The flake installable that builds this entry.
    string installable() const @safe pure nothrow =>
        ".#legacyPackages." ~ system ~ ".pinTargets." ~ name;
}

@("pinSet.Target.pinNameAndInstallable")
@safe pure nothrow
unittest
{
    const target = Target(name: "toolchain-dmd", system: "x86_64-linux");
    assert(target.pinName == "toolchain-dmd-x86_64-linux");
    assert(target.installable == ".#legacyPackages.x86_64-linux.pinTargets.toolchain-dmd");
}

/// Argv that evaluates every entry's out path for `system` as one JSON object.
string[] pinSetEvalArgs(string system) @safe pure nothrow => [
    "nix", "eval", "--json", ".#legacyPackages." ~ system ~ ".pinTargets",
    "--apply", "builtins.mapAttrs (_: drv: drv.outPath)",
];

/**
The targets of one system from `nix eval` output: an object from pin name to
out path. Entries come out sorted by name. Anything else is an error, and so
is an empty set.
*/
Expected!(Target[], string) parsePinSet(string system, string json) @safe
{
    JSONValue root;
    try
        root = parseJSON(json);
    catch (JSONException e)
        return err!(Target[])(format("pinTargets for %s is not JSON: %s", system, e.msg));
    if (root.type != JSONType.object)
        return err!(Target[])(format("pinTargets for %s is not an object", system));

    Target[] targets;
    foreach (name, value; (() @trusted => root.object)())
    {
        if (value.type != JSONType.string || !value.str.startsWith("/nix/store/"))
            return err!(Target[])(format("pinTargets.%s for %s has no store path", name, system));
        targets ~= Target(name: name, system: system, outPath: value.str);
    }
    if (targets.length == 0)
        return err!(Target[])(format("pinTargets for %s is empty", system));
    targets.sort!((a, b) => a.name < b.name);
    return ok(targets);
}

@("pinSet.parsePinSet.sortedAndStrict")
@safe
unittest
{
    const parsed = parsePinSet("aarch64-linux",
        `{"ts-grammars":"/nix/store/b-ts","harfbuzz":"/nix/store/a-hb"}`);
    assert(parsed.hasValue);
    assert(parsed.value == [
        Target("harfbuzz", "aarch64-linux", "/nix/store/a-hb"),
        Target("ts-grammars", "aarch64-linux", "/nix/store/b-ts"),
    ]);

    assert(parsePinSet("x86_64-linux", `{}`).hasError, "an empty set is not a set");
    assert(parsePinSet("x86_64-linux", `[]`).hasError);
    assert(parsePinSet("x86_64-linux", `{"a":1}`).hasError);
    assert(parsePinSet("x86_64-linux", `{"a":"relative"}`).hasError);
    assert(parsePinSet("x86_64-linux", `error: attribute missing`).hasError);
}

/// The whole set: system-major in $(LREF pinSystems) order, by name within a system.
Target[] expandPinSet(Target[][] perSystem) @safe pure nothrow => perSystem.join;

/// What a name says about its entry: the `toolchain-` prefix, the `-android` suffix.
enum Category : ubyte
{
    toolchain = 1,
    android = 2,
    library = 4,
}

/// The categories `name` belongs to. `toolchain-ldc-android` is both a
/// toolchain and an Android entry; a name with neither mark is a library.
ubyte categoriesOf(string name) @safe pure nothrow @nogc
{
    ubyte categories;
    if (name.startsWith("toolchain-"))
        categories |= Category.toolchain;
    if (name.endsWith("-android"))
        categories |= Category.android;
    return categories ? categories : Category.library;
}

@("pinSet.categoriesOf.prefixAndSuffix")
@safe pure nothrow @nogc
unittest
{
    assert(categoriesOf("toolchain-dmd") == Category.toolchain);
    assert(categoriesOf("raylib-android") == Category.android);
    assert(categoriesOf("toolchain-ldc-android") == (Category.toolchain | Category.android));
    assert(categoriesOf("skia-sparkles") == Category.library);
    assert(categoriesOf("my-toolchain-android-x") == Category.library);
}

/**
Which targets a run touches. Each list narrows the set; an empty one does not.
Categories combine as a union, so `--toolchains --android` selects both.
*/
struct Selection
{
    ubyte categories; /// `Category` bits; 0 selects every category.
    string[] names; /// Entry names (`toolchain-dmd`), not pin names.
    string[] systems;

    bool selects(in Target target) const scope @safe pure nothrow
    {
        if (categories && !(categoriesOf(target.name) & categories))
            return false;
        if (names.length && !names.canFind(target.name))
            return false;
        return systems.length == 0 || systems.canFind(target.system);
    }
}

/**
The targets of `set` that `selection` keeps, in set order. A name or system
the set does not contain is an error, and so is a selection that matches
nothing: neither may pin or check nothing and report success.
*/
Expected!(Target[], string) selectTargets(Target[] set, in Selection selection) @safe pure
{
    foreach (name; selection.names)
        if (!set.canFind!(target => target.name == name))
            return err!(Target[])(format("'%s' is not in the pin set", name));
    foreach (system; selection.systems)
        if (!pinSystems.canFind(system))
            return err!(Target[])(format("'%s' is not one of the pinned systems %-(%s, %)", system, pinSystems));
    auto chosen = set.filter!(target => selection.selects(target)).array;
    if (chosen.length == 0)
        return err!(Target[])("the selection matches no pin-set entry");
    return ok(chosen);
}

version (unittest) private Target[] sampleSet() @safe pure nothrow => [
    Target("skia-sparkles", "x86_64-linux"),
    Target("toolchain-dmd", "x86_64-linux"),
    Target("toolchain-ldc-android", "x86_64-linux"),
    Target("raylib-android", "x86_64-linux"),
    Target("skia-sparkles", "aarch64-darwin"),
    Target("toolchain-ldc-vulkan", "aarch64-darwin"),
];

@("pinSet.expandPinSet.systemMajor")
@safe pure nothrow
unittest
{
    Target[][] perSystem = [
        [Target("a", "x86_64-linux"), Target("b", "x86_64-linux")],
        [Target("a", "aarch64-darwin")],
    ];
    assert(expandPinSet(perSystem).map!(t => t.pinName).array
        == ["a-x86_64-linux", "b-x86_64-linux", "a-aarch64-darwin"]);
}

@("pinSet.selectTargets.filters")
@safe
unittest
{
    auto set = sampleSet();
    string[] pins(Selection selection) => selectTargets(set, selection).value.map!(t => t.pinName).array;

    assert(pins(Selection.init).length == set.length, "no selector selects the whole set");
    assert(pins(Selection(categories: Category.toolchain)) == [
        "toolchain-dmd-x86_64-linux", "toolchain-ldc-android-x86_64-linux",
        "toolchain-ldc-vulkan-aarch64-darwin",
    ]);
    assert(pins(Selection(categories: Category.android)) == [
        "toolchain-ldc-android-x86_64-linux", "raylib-android-x86_64-linux",
    ]);
    assert(pins(Selection(categories: Category.library)) == [
        "skia-sparkles-x86_64-linux", "skia-sparkles-aarch64-darwin",
    ]);
    assert(pins(Selection(categories: Category.toolchain | Category.android)).length == 4,
        "categories are a union, and an entry in two of them appears once");
    assert(pins(Selection(names: ["skia-sparkles"], systems: ["aarch64-darwin"]))
        == ["skia-sparkles-aarch64-darwin"]);
    assert(selectTargets(set, Selection(categories: Category.android, systems: ["aarch64-darwin"])).hasError,
        "a selection that matches nothing cannot pass vacuously");

    const typo = selectTargets(set, Selection(names: ["skia"]));
    assert(typo.hasError && typo.error == "'skia' is not in the pin set");
    assert(selectTargets(set, Selection(systems: ["x86_64-darwin"])).hasError);
}
