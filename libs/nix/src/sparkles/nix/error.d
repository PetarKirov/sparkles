/// Error handling for the Nix C API.
///
/// Every Nix C function reports failure out-of-band through a
/// `nix_c_context*` passed as its first argument, not through its return
/// value. This module wraps that channel in idiomatic D: a value-type
/// $(LREF NixError) (code + message), an `Expected`-based $(LREF NixResult),
/// the RAII $(LREF NixContext), and the $(LREF checkCall) helper that every
/// wrapper method funnels its C calls through.
///
/// See $(LINK2 ../../../../docs/specs/nix/SPEC.md, SPEC §4).
module sparkles.nix.error;

import sparkles.nix.c;
import expected : Expected, ok, err;

/// Mirror of the C `nix_err` enum as a clean D enum, so consumers never
/// touch the enum-scoped raw names. Values match the C ABI exactly.
enum NixErrCode : int
{
    ok          = 0,    /// `NIX_OK` — no error
    unknown     = -1,   /// `NIX_ERR_UNKNOWN` — a non-`nix::Error` C++ exception
    overflow    = -2,   /// `NIX_ERR_OVERFLOW`
    key         = -3,   /// `NIX_ERR_KEY` — unknown setting / missing attr / out-of-bounds index
    nixError    = -4,   /// `NIX_ERR_NIX_ERROR` — a `nix::Error` (evaluation/build failure)
    recoverable = -5,   /// `NIX_ERR_RECOVERABLE` — a transient primop failure

    // Wrapper-synthetic codes (positive, never returned by the C API):
    typeMismatch = 1,   /// a value had a type other than the one requested
}

/// A captured Nix error: the $(LREF NixErrCode) plus a copy of the message.
///
/// The C `nix_err_msg` pointer is borrowed (valid only until the next Nix
/// call), so the message is copied into a GC `string` immediately. The
/// high-level layer is GC-using by design (SPEC §12), so this is consistent.
struct NixError
{
    NixErrCode code;    /// the machine-readable error kind
    string message;     /// human-readable detail, copied out of the borrowed C pointer

    /// Renders as `"<code>: <message>"`.
    void toString(W)(ref W w) const
    {
        import std.conv : to;
        w.put(code.to!string);
        w.put(": ");
        w.put(message);
    }
}

/// The result type of every fallible wrapper operation: either a `T` or a
/// $(LREF NixError).
alias NixResult(T) = Expected!(T, NixError);

/// Constructs a successful $(LREF NixResult) carrying `value`.
NixResult!T nixOk(T)(T value) => ok!NixError(value);

/// ditto — success with no payload (`NixResult!void`).
NixResult!void nixOk() => ok!NixError();

/// Constructs a failed $(LREF NixResult)`!T` carrying `error`.
NixResult!T nixErr(T)(NixError error) => err!T(error);

/// RAII wrapper over `nix_c_context*` plus the call/check helpers.
///
/// A context carries no meaningful state between calls — every C function
/// resets it on entry, and $(LREF check) clears it after capturing an error —
/// so it is safe to reuse. Each `Store`/`EvalState` caches one to avoid
/// per-call allocation. Move-only.
struct NixContext
{
    private nix_c_context* _ctx;

    @disable this(this);

    /// Allocates a fresh context. Asserts on allocation failure (a tiny
    /// allocation failing is unrecoverable, mirroring nix-bindings-rust).
    static NixContext create() @trusted
    {
        auto c = nix_c_context_create();
        assert(c !is null, "nix_c_context_create returned null (out of memory)");
        return NixContext(c);
    }

    private this(nix_c_context* c) @safe pure nothrow @nogc { _ctx = c; }

    ~this() @trusted nothrow @nogc
    {
        if (_ctx !is null)
            nix_c_context_free(_ctx);
        _ctx = null;
    }

    /// The raw pointer, for `checkCall` and direct C calls.
    nix_c_context* ptr() @safe pure nothrow @nogc return => _ctx;

    /// Resets the context's error state.
    void clearErr() @trusted nothrow @nogc
    {
        nix_clear_err(_ctx);
    }

    /// Reads the current error code; on a non-OK code, copies the message out
    /// into a $(LREF NixError) and clears the context. Returns `NixResult!void`.
    /// (Not `nothrow`: it copies the message into a GC string and constructs an
    /// `Expected`, neither of which the GC-using wrapper layer keeps `nothrow`.)
    NixResult!void check() @trusted
    {
        const code = cast(NixErrCode) cast(int) nix_err_code(_ctx);
        if (code == NixErrCode.ok)
            return nixOk();

        uint n;
        const(char)* msg = nix_err_msg(null, _ctx, &n);
        string message = (msg is null) ? "(no message)" : msg[0 .. n].idup;
        nix_clear_err(_ctx);
        return nixErr!void(NixError(code, message));
    }
}

/// Invokes a Nix C function with `ctx` spliced in as its first argument, then
/// checks the context for an error.
///
/// - For `nix_err`-returning calls (the common case) the redundant return
///   code is discarded and the result is `NixResult!void`.
/// - For value/pointer-returning calls the result is `NixResult!R` carrying
///   the return value on success.
///
/// ---
/// auto store = checkCall!nix_store_open(ctx, uriZ, params);  // NixResult!(Store*)
/// checkCall!nix_value_force(ctx, state, v).orElseThrow;       // NixResult!void
/// ---
template checkCall(alias fn)
{
    auto checkCall(Args...)(ref NixContext ctx, auto ref Args args)
    {
        alias R = typeof(fn(ctx.ptr, args));
        static if (is(R == void) || is(R == nix_err))
        {
            cast(void) fn(ctx.ptr, args);
            return ctx.check();
        }
        else
        {
            R ret = fn(ctx.ptr, args);
            auto c = ctx.check();
            if (c.hasError)
                return nixErr!R(c.error);
            return nixOk(ret);
        }
    }
}

/// Like $(LREF checkCall), but maps the `NIX_ERR_KEY` "not found" code to a
/// null `Nullable` rather than an error. Backs optional attribute lookups.
/// Always used with value/pointer-returning C functions.
template checkCallOptKey(alias fn)
{
    import std.typecons : Nullable, nullable;

    auto checkCallOptKey(Args...)(ref NixContext ctx, auto ref Args args)
    {
        alias R = typeof(fn(ctx.ptr, args));
        static assert(!is(R == void) && !is(R == nix_err),
            "checkCallOptKey is for value-returning C functions");

        R ret = fn(ctx.ptr, args);
        const code = cast(NixErrCode) cast(int) nix_err_code(ctx.ptr);
        if (code == NixErrCode.key)
        {
            ctx.clearErr();
            return nixOk(Nullable!R.init);
        }
        auto c = ctx.check();
        if (c.hasError)
            return nixErr!(Nullable!R)(c.error);
        return nixOk(ret.nullable);
    }
}
