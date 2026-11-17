/++
The Nix module's answer to one call (docs/specs/wired/wasm/SPEC.md §2): the
argument read, the recipe decoded by `parseDubRecipeText`, and the result
built as Nix values.

The conversion is generic over a $(I host), the evaluator's value
operations: the module's own host calls `builtins.wasm`'s imports
($(MREF sparkles, dub_manifest_nix, wasm_host)), and
$(MREF sparkles, dub_manifest_nix, tree_host) keeps the values in memory, so
the same code runs natively in tests and in the oracle the Nix check
compares the module with. A host provides:

$(UL
    $(LI `Value`, a value handle, with `Value.init` meaning "no value";)
    $(LI `kindOf(v)`, the value's $(LREF NixKind);)
    $(LI `stringOf(v)`, a string's bytes;)
    $(LI `attrOf(set, name)`, an attribute, or `Value.init` when absent;)
    $(LI `string_`, `bool_`, `int_`, `list` and `attrs`, which make values.)
)
+/
module sparkles.dub_manifest_nix.convert;

import std.traits : FieldNameTuple, Unqual;

import sparkles.build_primitives.dub_manifest : DubManifest, parseDubRecipeText;
import sparkles.wired.sdl : OwnedSdlExtras, SdlError;

/// A Nix value's type, numbered as `builtins.wasm`'s `get_type` reports it.
enum NixKind : uint
{
    int_ = 1, ///
    float_ = 2, ///
    bool_ = 3, ///
    string_ = 4, ///
    path = 5, ///
    null_ = 6, ///
    attrs = 7, ///
    list = 8, ///
    function_ = 9, ///
}

/// What one call returns: its result, or, when the argument breaks the
/// calling convention, the fault to report instead (WW5 reserves `panic`
/// for that alone).
struct Response(Value)
{
    Value value; /// the result, when `fault` is empty
    string fault; /// what was wrong with the argument
}

/++
Answers one call: `argument` is the recipe text, or `{ text; name ? "dub.sdl"; }`
(WW3). A recipe that decodes becomes `{ recipe = …; }` (WW4); one that does
not, `{ error = { name; line; column; code; message; }; }` (WW5).
+/
Response!(Host.Value) respond(Host, V)(ref Host host, V argument)
if (is(V : Host.Value))
{
    alias R = Response!(Host.Value);
    const(char)[] text;
    string name = "dub.sdl";

    switch (host.kindOf(argument))
    {
    case NixKind.string_:
        text = host.stringOf(argument);
        break;
    case NixKind.attrs:
        const t = host.attrOf(argument, "text");
        if (t == Host.Value.init || host.kindOf(t) != NixKind.string_)
            return R(Host.Value.init, "the argument's `text` must be a string");
        text = host.stringOf(t);
        const n = host.attrOf(argument, "name");
        if (n != Host.Value.init)
        {
            if (host.kindOf(n) != NixKind.string_)
                return R(Host.Value.init, "the argument's `name` must be a string");
            name = host.stringOf(n).idup;
        }
        break;
    default:
        return R(Host.Value.init,
            "the argument must be the recipe text or { text; name ? \"dub.sdl\"; }");
    }

    auto parsed = parseDubRecipeText(text, name);
    if (parsed.hasError)
        return R(single(host, "error", errorValue(host, parsed.error, name)));
    return R(single(host, "recipe", toNix(host, parsed.value)));
}

/// `{ <name> = <value>; }`.
Host.Value single(Host, V)(ref Host host, string name, V value)
if (is(V : Host.Value))
{
    const(char)[][1] names = [name];
    Host.Value[1] values = [value];
    return host.attrs(names[], values[]);
}

/// `{ name; line; column; code; message; }` for `error`, its message without
/// the `name(line:column): ` prefix the fields already carry.
Host.Value errorValue(Host)(ref Host host, ref const SdlError error, string name)
{
    import std.algorithm.searching : startsWith;
    import std.conv : text, to;

    const rendered = error.toString();
    const prefix = text(error.sourceName[], "(", error.startPosition.line, ":",
        error.startPosition.column, "): ");
    const message = error.sourceName.length && rendered.startsWith(prefix)
        ? rendered[prefix.length .. $] : rendered;

    const(char)[][5] names = ["name", "line", "column", "code", "message"];
    Host.Value[5] values = [
        host.string_(name),
        host.int_(error.startPosition.line),
        host.int_(error.startPosition.column),
        host.string_(error.code.to!string),
        host.string_(message),
    ];
    return host.attrs(names[], values[]);
}

/// The Nix spelling of a D field: `version_` → `version`.
enum nixName(string field) = field[$ - 1] == '_' ? field[0 .. $ - 1] : field;

/// Whether `value` is empty: an empty string or list, `false`, or an aggregate
/// whose fields are all empty. An empty field is left out of its attribute
/// set, and Nix reads it with an `or` default (WW4).
bool isEmpty(T)(ref const T value)
{
    alias U = Unqual!T;
    static if (is(U == bool))
        return !value;
    else static if (is(U == E[], E))
        return value.length == 0;
    else static if (is(U == struct))
    {
        static foreach (field; FieldNameTuple!U)
            static if (!is(typeof(__traits(getMember, U, field)) == OwnedSdlExtras))
                if (!isEmpty(__traits(getMember, value, field)))
                    return false;
        return true;
    }
    else
        static assert(0, "no Nix form for " ~ T.stringof);
}

/// `value` as a Nix value (WW4): an aggregate as an attribute set without its
/// empty fields, an array as a list, a string as a string, a `bool` as a
/// Boolean. The schema's catch-all for unknown directives is never emitted.
Host.Value toNix(Host, T)(ref Host host, ref const T value)
{
    alias U = Unqual!T;
    static if (is(U : const(char)[]))
        return host.string_(value);
    else static if (is(U == bool))
        return host.bool_(value);
    else static if (is(U == E[], E))
    {
        // Recipes' lists are short: a stack buffer serves them without the GC.
        Host.Value[64] small = void;
        Host.Value[] items = value.length <= small.length
            ? small[0 .. value.length] : new Host.Value[value.length];
        foreach (i, ref e; value)
            items[i] = toNix(host, e);
        return host.list(items);
    }
    else static if (is(U == struct))
    {
        enum fields = FieldNameTuple!U.length;
        const(char)[][fields] names;
        Host.Value[fields] values;
        size_t n;
        static foreach (field; FieldNameTuple!U)
            static if (!is(typeof(__traits(getMember, U, field)) == OwnedSdlExtras))
                if (!isEmpty(__traits(getMember, value, field)))
                {
                    names[n] = nixName!field;
                    values[n++] = toNix(host, __traits(getMember, value, field));
                }
        return host.attrs(names[0 .. n], values[0 .. n]);
    }
    else
        static assert(0, "no Nix form for " ~ T.stringof);
}

version (unittest) import sparkles.dub_manifest_nix.tree_host : TreeHost;

@("dub_manifest_nix.respond.recipe")
@safe unittest
{
    TreeHost host;
    const arg = host.string_("name \"x\"\ndependency \"sparkles:base\" path=\"../..\"\n"
        ~ "configuration \"library\" {\n    targetType \"library\"\n}\n");
    const r = respond(host, arg);
    assert(r.fault is null);
    assert(host.json(r.value) == `{"recipe":{"configurations":[{"name":"library",`
        ~ `"targetType":"library"}],"dependencies":[{"name":"sparkles:base","path":"../.."}],`
        ~ `"name":"x"}}`, host.json(r.value));
}

@("dub_manifest_nix.respond.namesChooseTheFormat")
@safe unittest
{
    TreeHost host;
    const(char)[][2] names = ["text", "name"];

    TreeHost.Value[2] json = [host.string_(`{"name": "j", "targetType": "library"}`),
        host.string_("libs/x/dub.json")];
    assert(host.json(respond(host, host.attrs(names[], json[])).value)
        == `{"recipe":{"name":"j","targetType":"library"}}`);

    TreeHost.Value[2] embedded = [host.string_("#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"e\"\n+/\n"),
        host.string_("examples/e.d")];
    assert(host.json(respond(host, host.attrs(names[], embedded[])).value)
        == `{"recipe":{"name":"e"}}`);
}

@("dub_manifest_nix.respond.errorsAreValues")
@safe unittest
{
    TreeHost host;
    const(char)[][2] names = ["text", "name"];
    TreeHost.Value[2] fields = [host.string_("name \"x\"\ntargetTyp \"library\"\n"),
        host.string_("libs/x/dub.sdl")];
    const r = respond(host, host.attrs(names[], fields[]));
    assert(r.fault is null);
    assert(host.json(r.value) == `{"error":{"code":"unknownMember","column":1,"line":2,`
        ~ "\"message\":\"Cannot decode a DUB recipe: unknown directive `targetTyp`\","
        ~ `"name":"libs/x/dub.sdl"}}`, host.json(r.value));

    // Lexing and parsing fail as values too.
    assert(host.json(respond(host, host.string_("name \"x")).value)[0 .. 10] == `{"error":{`);
    assert(host.json(respond(host, host.string_("name \"x\" {\n")).value)[0 .. 10] == `{"error":{`);
}

@("dub_manifest_nix.respond.faults")
@safe unittest
{
    TreeHost host;
    assert(respond(host, host.int_(1)).fault.length);
    const(char)[][1] name = ["name"];
    TreeHost.Value[1] value = [host.string_("dub.sdl")];
    assert(respond(host, host.attrs(name[], value[])).fault.length, "no text");
    const(char)[][2] names = ["text", "name"];
    TreeHost.Value[2] values = [host.string_(""), host.int_(3)];
    assert(respond(host, host.attrs(names[], values[])).fault.length, "a non-string name");
}

@("dub_manifest_nix.toNix.omitsEmptyFields")
@safe unittest
{
    TreeHost host;
    DubManifest m;
    assert(host.json(toNix(host, m)) == "{}");
    m.name = "n";
    m.authors = ["a", "b"];
    assert(host.json(toNix(host, m)) == `{"authors":["a","b"],"name":"n"}`);
}
