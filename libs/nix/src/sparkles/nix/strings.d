/// Bridging the Nix C "string return" convention to D output ranges.
///
/// Nix never hands out owned strings: a function that yields a string takes a
/// `nix_get_string_callback` plus a `void*` cookie and invokes the callback
/// once with a borrowed, possibly non-NUL-terminated `(start, n)` buffer. This
/// module turns that into a `put` into any output range — the same move
/// `core_cli` makes for `prettyPrint`/`toString`.
///
/// See $(LINK2 ../../../../docs/specs/nix/SPEC.md, SPEC §5).
module sparkles.nix.strings;

import sparkles.nix.c;
import sparkles.nix.error;

/// `extern(C)` trampoline matching `nix_get_string_callback`: recovers the
/// output range of type `W` from `userData` and `put`s the borrowed slice.
/// One instantiation per writer type. `nothrow` — never let a D exception
/// escape across the C boundary.
extern (C) void stringSinkCallback(W)(const(char)* start, uint n, void* userData) nothrow
{
    import std.range.primitives : put;

    if (start is null || n == 0)
        return;
    auto w = cast(W*) userData;
    try
        put(*w, start[0 .. n]);
    catch (Exception)
    {
        // An output range that throws on append is misuse; swallow rather than
        // unwind into Nix's C++ `catch(...)`.
    }
}

/// A closure that invokes a specific string-returning C function with the
/// supplied callback + cookie (capturing the context and any other args). A
/// concrete delegate type (rather than a template) so call sites can write an
/// untyped lambda `(cb, ud) => …` and have the parameter types inferred.
alias StringFn = nix_err delegate(nix_get_string_callback cb, void* userData);

/// Drive a string-returning C function into `writer`, e.g.
/// ---
/// collectStringInto(ctx, w, (cb, ud) => nix_get_string(ctx.ptr, v, cb, ud));
/// ---
/// Returns the context's error state after the call.
NixResult!void collectStringInto(W)(ref NixContext ctx, ref W writer, scope StringFn call)
{
    auto cb = cast(nix_get_string_callback)&stringSinkCallback!W;
    cast(void) call(cb, cast(void*)&writer);
    return ctx.check();
}

/// Convenience over $(LREF collectStringInto): collect into a fresh GC string.
NixResult!string collectString(ref NixContext ctx, scope StringFn call)
{
    import std.array : appender;

    auto w = appender!(char[]);
    auto r = collectStringInto(ctx, w, call);
    if (r.hasError)
        return nixErr!string(r.error);
    return nixOk(cast(string) w[]);
}
