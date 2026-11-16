/++
PROTOTYPE (#452): `parseDubManifest` behind Nix's `builtins.wasm`, WASI mode.

The evaluator runs `_start` with `argv[1]` the decimal `ValueId` of the
argument, a string holding `dub.sdl` text; the result, the typed recipe as an
attribute set, goes back through `return_to_nix`. Host interface:
DeterminateSystems/nix-src `doc/manual/source/protocols/wasm.md`.
+/
module app;

import std.traits : FieldNameTuple, Unqual;

import sparkles.build_primitives.dub_manifest : DubManifest, parseDubManifest;
import sparkles.wired.sdl : OwnedSdlExtras;

alias ValueId = uint;

/// One `make_attrset` entry.
struct NixAttr
{
    uint namePtr;
    uint nameLen;
    ValueId value;
}

extern (C) @system nothrow @nogc
{
    void panic(uint ptr, uint len);
    uint get_type(ValueId value);
    ValueId make_string(uint ptr, uint len);
    uint copy_string(ValueId value, uint ptr, uint maxLen);
    ValueId make_bool(int b);
    ValueId make_list(uint ptr, uint len);
    ValueId make_attrset(uint ptr, uint len);
    void return_to_nix(ValueId value);
}

uint addr(T)(T* p) @trusted => cast(uint) cast(size_t) p;

noreturn fail(scope const(char)[] message) @trusted
{
    panic(addr(message.ptr), cast(uint) message.length);
    assert(0);
}

/// The Nix spelling of a D field: `version_` → `version`.
enum nixName(string field) = field[$ - 1] == '_' ? field[0 .. $ - 1] : field;

ValueId toNix(T)(ref const T value) @trusted
{
    alias U = Unqual!T;
    static if (is(U : const(char)[]))
        return make_string(addr(value.ptr), cast(uint) value.length);
    else static if (is(U == bool))
        return make_bool(value);
    else static if (is(U == E[], E))
    {
        auto ids = new ValueId[value.length];
        foreach (i, ref e; value)
            ids[i] = toNix(e);
        return make_list(addr(ids.ptr), cast(uint) ids.length);
    }
    else static if (is(U == struct))
    {
        NixAttr[FieldNameTuple!U.length] attrs;
        uint n;
        static foreach (field; FieldNameTuple!U)
            static if (!is(typeof(__traits(getMember, U, field)) == OwnedSdlExtras))
            {{
                static immutable string name = nixName!field;
                attrs[n++] = NixAttr(addr(name.ptr), cast(uint) name.length,
                    toNix(__traits(getMember, value, field)));
            }}
        return make_attrset(addr(attrs.ptr), n);
    }
    else
        static assert(0, "no Nix form for " ~ T.stringof);
}

int main(string[] args) @trusted
{
    import std.conv : to;

    if (args.length < 2)
        fail("spk-dub-manifest: expected the argument's ValueId in argv[1]");
    const arg = args[1].to!ValueId;
    if (get_type(arg) != 4)
        fail("spk-dub-manifest: the argument must be a string of dub.sdl text");

    const length = copy_string(arg, 0, 0);
    auto text = new char[length];
    if (length)
        copy_string(arg, addr(text.ptr), length);

    auto parsed = parseDubManifest(text, "dub.sdl");
    if (parsed.hasError)
    {
        import std.conv : text_ = text;
        fail(text_("spk-dub-manifest: ", parsed.error));
    }
    return_to_nix(toNix(parsed.value));
    return 0;
}
