/// The Nix store: `Store` and `StorePath`.
///
/// `Store` is a shared, reference-counted handle (so an `EvalState` can keep
/// the store it was built from alive). `StorePath` is a single-owner handle
/// that deep-clones on copy via the C clone function.
///
/// See $(LINK2 ../../../../docs/specs/nix/SPEC.md, SPEC §7).
module sparkles.nix.store;

import std.string : toStringz;
import std.typecons : RefCounted, RefCountedAutoInitialize;

import sparkles.nix.c;
import sparkles.nix.c : CStore = Store, CStorePath = StorePath;
import sparkles.nix.error;
import sparkles.nix.strings;
import sparkles.nix.library : initNix;

/// A reference-counted handle to an open Nix store.
struct Store
{
    private static struct Payload
    {
        CStore* ptr;
        @disable this(this);
        ~this() @trusted nothrow @nogc
        {
            if (ptr !is null)
                nix_store_free(ptr);
        }
    }

    private RefCounted!(Payload, RefCountedAutoInitialize.no) _rc;

    /// Opens a store. A null/empty `uri` opens the default store; `"dummy://"`
    /// opens an in-memory store that needs no daemon (ideal for pure
    /// evaluation). `params` are optional backend key=value parameters.
    static NixResult!Store open(in char[] uri = null, in string[string] params = null) @trusted
    {
        auto initR = initNix();
        if (initR.hasError)
            return nixErr!Store(initR.error);

        auto ctx = NixContext.create();
        const uriZ = uri.length ? uri.toStringz : null;

        // Marshal params into the C `const char***` — a null-terminated array of
        // {key, value} string pairs. Each layer must outlive the C call.
        const(char)*[2][] pairs;
        const(char)**[] rows;
        foreach (k, v; params)
        {
            pairs ~= [k.toStringz, v.toStringz];
        }
        foreach (ref pair; pairs)
            rows ~= pair.ptr;
        rows ~= null; // terminator
        auto paramsPtr = params.length ? rows.ptr : null;

        auto r = checkCall!nix_store_open(ctx, uriZ, cast(const(char)***) paramsPtr);
        if (r.hasError)
            return nixErr!Store(r.error);

        Store s;
        s._rc = RefCounted!(Payload, RefCountedAutoInitialize.no)(r.value);
        return nixOk(s);
    }

    package CStore* ptr() @trusted nothrow @nogc => _rc.ptr;

    /// The store's URI (`nix_store_get_uri`).
    NixResult!string uri() @trusted
    {
        auto ctx = NixContext.create();
        auto self = ptr;
        return collectString(ctx, (cb, ud) => nix_store_get_uri(ctx.ptr, self, cb, ud));
    }

    /// The store directory, e.g. `/nix/store` (`nix_store_get_storedir`).
    NixResult!string storeDir() @trusted
    {
        auto ctx = NixContext.create();
        auto self = ptr;
        return collectString(ctx, (cb, ud) => nix_store_get_storedir(ctx.ptr, self, cb, ud));
    }

    /// The store's Nix version, or empty if it has none (`nix_store_get_version`).
    NixResult!string storeVersion() @trusted
    {
        auto ctx = NixContext.create();
        auto self = ptr;
        return collectString(ctx, (cb, ud) => nix_store_get_version(ctx.ptr, self, cb, ud));
    }

    /// Parses a store path string (which must include the store dir).
    NixResult!StorePath parsePath(in char[] path) @trusted
    {
        auto ctx = NixContext.create();
        const pathZ = path.toStringz;
        auto r = checkCall!nix_store_parse_path(ctx, ptr, pathZ);
        if (r.hasError)
            return nixErr!StorePath(r.error);
        return nixOk(StorePath.adopt(r.value));
    }

    /// Whether `p` is a valid path in this store (`nix_store_is_valid_path`).
    NixResult!bool isValidPath(in StorePath p) @trusted
    {
        auto ctx = NixContext.create();
        auto r = checkCall!nix_store_is_valid_path(ctx, ptr, p.raw);
        if (r.hasError)
            return nixErr!bool(r.error);
        return nixOk(r.value);
    }
}

/// A single-owner handle to a Nix store path. Deep-clones on copy.
struct StorePath
{
    private CStorePath* _raw;

    package static StorePath adopt(CStorePath* p) @safe nothrow @nogc
    {
        StorePath sp;
        sp._raw = p;
        return sp;
    }

    package CStorePath* raw() const @trusted nothrow @nogc return scope
        => cast(CStorePath*) _raw;

    this(this) @trusted nothrow @nogc
    {
        if (_raw !is null)
            _raw = nix_store_path_clone(_raw);
    }

    ~this() @trusted nothrow @nogc
    {
        if (_raw !is null)
            nix_store_path_free(_raw);
        _raw = null;
    }

    /// True when this handle holds no path.
    bool isNull() const @safe pure nothrow @nogc => _raw is null;

    /// The path's name part, e.g. `hello-2.12.1` (`nix_store_path_name`). This C
    /// function takes no context and invokes the callback directly.
    string name() @trusted
    {
        import std.array : appender;

        if (_raw is null)
            return null;
        auto w = appender!(char[]);
        auto cb = cast(nix_get_string_callback)&stringSinkCallback!(typeof(w));
        nix_store_path_name(_raw, cb, cast(void*)&w);
        return cast(string) w[];
    }
}

@("nix.store.open.dummy")
@system
unittest
{
    auto opened = Store.open("dummy://");
    assert(!opened.hasError, opened.hasError ? opened.error.message : "");
    auto store = opened.value;

    auto uri = store.uri();
    assert(uri.hasValue, uri.hasError ? uri.error.message : "");
    assert(uri.value.length > 0);
}
