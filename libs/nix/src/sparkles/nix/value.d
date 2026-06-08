/// The `Value` handle and `ValueType` discriminant.
///
/// A `nix_value*` is garbage-collected by Nix with a C-side reference count
/// layered on top. $(LREF Value) is a thin handle that participates in that
/// count: copying increfs (retain), destruction decrefs (release) — so it
/// behaves like a `shared_ptr`. The operations that read or build values
/// (extraction, construction, calls) need an `EvalState` and therefore live in
/// `sparkles.nix.eval`; this module is just the handle and its type tag.
///
/// See $(LINK2 ../../../../docs/specs/nix/SPEC.md, SPEC §9).
module sparkles.nix.value;

import sparkles.nix.c;

/// Clean D mirror of the C `ValueType` enum (the `NIX_TYPE_*` constants). The
/// integer values match the C ABI declaration order.
enum ValueType : int
{
    thunk     = 0,  /// unevaluated expression (the only mutable state)
    integer   = 1,  /// 64-bit signed integer (`NIX_TYPE_INT`)
    float_    = 2,  /// IEEE-754 double
    boolean   = 3,  /// boolean
    string_   = 4,  /// string with context (may be arbitrary bytes)
    path      = 5,  /// filesystem path
    null_     = 6,  /// null
    attrs     = 7,  /// attribute set
    list      = 8,  /// list
    function_ = 9,  /// function (lambda or builtin)
    external  = 10, /// external value
    failed    = 11, /// evaluation failed (sentinel)
}

/// Maps a raw C `nix_get_type` result to a $(LREF ValueType). Unknown future
/// values fall back to `ValueType.failed`.
ValueType toValueType(int raw) @safe pure nothrow @nogc
{
    if (raw < ValueType.thunk || raw > ValueType.failed)
        return ValueType.failed;
    return cast(ValueType) raw;
}

/// A reference-counted handle to a Nix value (or thunk).
///
/// Copyable: each copy increfs and each destruction decrefs (refcount errors
/// are swallowed — the only failure mode is a leak, so copy/destruction stay
/// `nothrow`). The handle does not encode its owning `EvalState`'s lifetime in
/// the type; the Nix GC keeps the value alive while any handle references it,
/// but you must not use a `Value` after its `EvalState` is gone.
struct Value
{
    private nix_value* _raw;

    /// Adopt an already-owned reference (e.g. a freshly allocated value, or one
    /// returned by a getter/eval call that already charged you a refcount). No
    /// incref; decref on destruction.
    package static Value adopt(nix_value* p) @safe nothrow @nogc
    {
        Value v;
        v._raw = p;
        return v;
    }

    /// Retain a borrowed reference (e.g. a primop argument owned by Nix):
    /// increfs now, decrefs on destruction.
    package static Value retain(nix_value* p) @trusted nothrow @nogc
    {
        if (p !is null)
            cast(void) nix_value_incref(null, p);
        Value v;
        v._raw = p;
        return v;
    }

    /// The underlying C pointer (for `eval`/`flake` operations). `const` with
    /// a const-cast: the Nix C API takes `nix_value*` (ImportC drops the header
    /// `const`), and "reading" a value may force a thunk in place — logically
    /// const from the handle's perspective, like Rust's `unsafe raw_ptr(&self)`.
    package nix_value* raw() const @trusted nothrow @nogc return scope
        => cast(nix_value*) _raw;

    this(this) @trusted nothrow @nogc
    {
        if (_raw !is null)
            cast(void) nix_value_incref(null, _raw);
    }

    ~this() @trusted nothrow @nogc
    {
        if (_raw !is null)
            cast(void) nix_value_decref(null, _raw);
        _raw = null;
    }

    /// True when this handle holds no value.
    bool isNull() const @safe pure nothrow @nogc => _raw is null;

    /// The value's current type, WITHOUT forcing — a still-unevaluated value
    /// reports `ValueType.thunk`. Use `EvalState.valueType` to force first.
    ValueType type() const @trusted nothrow @nogc
    {
        if (_raw is null)
            return ValueType.thunk;
        // ImportC drops the `const` on nix_get_type's parameter, so cast it
        // away — nix_get_type does not mutate the value.
        return toValueType(cast(int) nix_get_type(null, cast(nix_value*) _raw));
    }
}
