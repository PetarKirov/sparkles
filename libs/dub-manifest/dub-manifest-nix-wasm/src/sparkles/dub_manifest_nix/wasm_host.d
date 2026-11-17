/++
The host of $(MREF sparkles, dub_manifest_nix, convert) inside the module:
the `env` imports `builtins.wasm` provides (Determinate Nix's Wasm host
interface, pinned in docs/specs/wired/wasm/SPEC.md §2). A value is the
evaluator's `ValueId`; `0` is "no value".
+/
module sparkles.dub_manifest_nix.wasm_host;

version (WASI):

import sparkles.dub_manifest_nix.convert : NixKind;

private extern (C) @system nothrow @nogc
{
    void panic(uint ptr, uint len);
    uint get_type(uint value);
    uint make_string(uint ptr, uint len);
    uint copy_string(uint value, uint ptr, uint maxLen);
    uint make_bool(int b);
    uint make_int(long n);
    uint make_list(uint ptr, uint len);
    uint make_attrset(uint ptr, uint len);
    uint get_attr(uint value, uint ptr, uint len);
    void return_to_nix(uint value);
}

// One `make_attrset` entry.
private struct NixAttr
{
    uint namePtr;
    uint nameLen;
    uint value;
}

private uint addr(T)(const(T)* p) @trusted => cast(uint) cast(size_t) p;

/// The evaluator, through the module's imports.
struct WasmHost
{
    alias Value = uint;

    NixKind kindOf(Value v) @trusted => cast(NixKind) get_type(v); ///

    /// A string's bytes, copied into the module's memory.
    const(char)[] stringOf(Value v) @trusted
    {
        const length = copy_string(v, 0, 0);
        auto bytes = new char[length];
        if (length)
            copy_string(v, addr(bytes.ptr), length);
        return bytes;
    }

    Value attrOf(Value set, scope const(char)[] name) @trusted
        => get_attr(set, addr(name.ptr), cast(uint) name.length); ///

    Value string_(scope const(char)[] s) @trusted
        => make_string(addr(s.ptr), cast(uint) s.length); ///
    Value bool_(bool b) @trusted => make_bool(b); ///
    Value int_(long i) @trusted => make_int(i); ///
    Value list(scope const(Value)[] items) @trusted
        => make_list(addr(items.ptr), cast(uint) items.length); ///

    /// An attribute set; the evaluator copies the names and values.
    Value attrs(scope const(char)[][] names, scope const(Value)[] values) @trusted
    {
        NixAttr[64] small = void;
        NixAttr[] entries = names.length <= small.length
            ? small[0 .. names.length] : new NixAttr[names.length];
        foreach (i, n; names)
            entries[i] = NixAttr(addr(n.ptr), cast(uint) n.length, values[i]);
        return make_attrset(addr(entries.ptr), cast(uint) entries.length);
    }
}

/// Ends the call with `value` as its result.
noreturn returnToNix(uint value) @trusted
{
    return_to_nix(value);
    assert(0, "return_to_nix returned");
}

/// Aborts the evaluation with `message`: the calling convention was broken.
noreturn fail(scope const(char)[] message) @trusted
{
    panic(addr(message.ptr), cast(uint) message.length);
    assert(0, "panic returned");
}
