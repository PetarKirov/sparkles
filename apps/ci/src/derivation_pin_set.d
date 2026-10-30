/**
The pin set as values: the flake's `legacyPackages.<system>.pinTargets`
(`nix/pin-targets.nix`, TC24) expanded across Sparkles' hosts, the selectors
that filter it, the cache's pins that fall outside it, and the narinfo URLs
that prove an output is cached (TC23).

Nothing here runs a command or touches the network: the launcher evaluates
the set and talks to Cachix, then hands the answers to these functions.
*/
module derivation_pin_set;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : all, canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.format : format;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.string : representation;

import expected : Expected, err, ok;

import sparkles.base.text.writers : formatted, writeBytes;

/// The hosts whose pin set the cache holds, in expansion order (TC21).
immutable string[] pinSystems = ["x86_64-linux", "aarch64-darwin", "aarch64-linux"];

/// The Cachix cache's storage limit; the pinned closures must fit beside CI's
/// working set (TC24's rationale).
enum ulong cacheCapBytes = 10UL << 30;

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
out path. Entries come out sorted by name. Anything else is an error, never
an empty set: an empty set would mark every pin of `system` for deletion.
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

/// `https://app.cachix.org/api/v1/cache/<cache>/pin`: list (GET) the cache's pins.
string pinsUrl(string cache) @safe pure nothrow =>
    "https://app.cachix.org/api/v1/cache/" ~ cache ~ "/pin";

/// `…/pin/<name>`: delete (DELETE) one pin.
string pinUrl(string cache, string pinName) @safe pure nothrow =>
    pinsUrl(cache) ~ "/" ~ pinName;

/// Pin names from the Cachix pin list (an array of objects with a `name`), sorted.
Expected!(string[], string) parsePinList(string json) @safe
{
    JSONValue root;
    try
        root = parseJSON(json);
    catch (JSONException e)
        return err!(string[])("the pin list is not JSON: " ~ e.msg);
    if (root.type != JSONType.array)
        return err!(string[])("the pin list is not an array");

    string[] names;
    foreach (entry; (() @trusted => root.array)())
    {
        if (entry.type != JSONType.object || "name" !in entry || entry["name"].type != JSONType.string)
            return err!(string[])("a pin has no name");
        names ~= entry["name"].str;
    }
    return ok(names.sort.release);
}

@("pinSet.parsePinList.names")
@safe
unittest
{
    const listed = parsePinList(
        `[{"name":"ts-grammars-aarch64-linux","keep":{"contents":1,"tag":"Revisions"}},`
        ~ `{"name":"harfbuzz-x86_64-linux"}]`);
    assert(listed.value == ["harfbuzz-x86_64-linux", "ts-grammars-aarch64-linux"]);
    assert(parsePinList(`[]`).value.length == 0);
    assert(parsePinList(`{"error":"no"}`).hasError);
    assert(parsePinList(`[{"keep":1}]`).hasError);
}

/**
The cache's pins that `set` does not name, sorted: what TC24 says the cache
must not hold. `set` is the whole expansion, never a selection — a run that
pins one system must not delete the other systems' pins.
*/
string[] stalePins(in string[] cachePins, in Target[] set) @safe pure nothrow
{
    bool[string] wanted;
    foreach (target; set)
        wanted[target.pinName] = true;
    string[] stale;
    foreach (pin; cachePins)
        if (pin !in wanted)
            stale ~= pin;
    stale.sort();
    return stale;
}

@("pinSet.stalePins.outsideTheSet")
@safe pure nothrow
unittest
{
    const set = sampleSet();
    assert(stalePins([
        "toolchain-dub-x86_64-linux", "skia-sparkles-x86_64-linux",
        "nix-c-api-aarch64-darwin", "toolchain-ldc-vulkan-aarch64-darwin",
    ], set) == ["nix-c-api-aarch64-darwin", "toolchain-dub-x86_64-linux"]);
    assert(stalePins(set.map!(t => t.pinName).array, set).length == 0, "the set itself is never stale");
    assert(stalePins(["skia-sparkles-aarch64-linux"], set) == ["skia-sparkles-aarch64-linux"],
        "an entry pinned for a system the set leaves it out of is stale");
}

/// Nix's base-32 alphabet (no `e`, `o`, `t`, `u`).
private enum nixBase32 = "0123456789abcdfghijklmnpqrsvwxyz";

/**
`<cacheUri>/<hash>.narinfo` for `storePath`, the URL a substituter asks; it
exists exactly when the cache holds the path. `cacheUri` has no trailing `/`.
*/
Expected!(string, string) narinfoUrl(string cacheUri, string storePath) @safe pure
{
    enum prefix = "/nix/store/";
    enum hashLength = 32;
    if (!storePath.startsWith(prefix))
        return err!string("not a store path: " ~ storePath);
    const base = storePath[prefix.length .. $];
    if (base.length <= hashLength || base[hashLength] != '-'
        || !base[0 .. hashLength].representation.all!(c => nixBase32.canFind(c)))
        return err!string("not a store path: " ~ storePath);
    return ok(cacheUri ~ "/" ~ base[0 .. hashLength] ~ ".narinfo");
}

@("pinSet.narinfoUrl.hashOnly")
@safe pure
unittest
{
    enum uri = "https://sparkles.cachix.org";
    assert(narinfoUrl(uri, "/nix/store/45iz365bm9kwm02x4ll7njn7vfqphq8h-dmd-2.112.1").value
        == "https://sparkles.cachix.org/45iz365bm9kwm02x4ll7njn7vfqphq8h.narinfo");
    assert(narinfoUrl(uri, "/nix/store/45iz365bm9kwm02x4ll7njn7vfqphq8h-dmd/bin/dmd").value
        == "https://sparkles.cachix.org/45iz365bm9kwm02x4ll7njn7vfqphq8h.narinfo",
        "a path inside an output names that output");
    assert(narinfoUrl(uri, "/tmp/45iz365bm9kwm02x4ll7njn7vfqphq8h-dmd").hasError);
    assert(narinfoUrl(uri, "/nix/store/short-dmd").hasError);
    assert(narinfoUrl(uri, "/nix/store/45iz365bm9kwm02x4ll7njn7vfqphq8e-dmd").hasError,
        "e is not in Nix's base-32 alphabet");
}

/// The cache URI substituters use: `https://<cache>.cachix.org`.
string cacheUri(string cache) @safe pure nothrow => "https://" ~ cache ~ ".cachix.org";

/// `7.2GiB of the 10.0GiB cap (72%)`: pinned bytes beside the cache's limit.
string capReport(ulong bytes, ulong cap = cacheCapBytes) @safe pure
in (cap > 0)
{
    return format("%s of the %s cap (%d%%)",
        formatted!writeBytes(bytes), formatted!writeBytes(cap), bytes * 100 / cap);
}

@("pinSet.capReport.percent")
@safe
unittest
{
    assert(capReport(0) == "0B of the 10.0GiB cap (0%)");
    assert(capReport(cacheCapBytes / 2) == "5.0GiB of the 10.0GiB cap (50%)");
    assert(capReport(cacheCapBytes + cacheCapBytes / 4) == "12.5GiB of the 10.0GiB cap (125%)");
}
