/// Flake support: settings, references, locking, and output evaluation.
///
/// The flow mirrors `nix-bindings-flake`: configure `FetchersSettings` +
/// `FlakeSettings`, attach the flake settings to an `EvalStateBuilder` via
/// $(LREF flakes), parse a `FlakeReference`, lock it into a `LockedFlake`, then
/// evaluate its outputs to a `Value`. Flakes require the `flakes` experimental
/// feature (`setSetting("experimental-features", "flakes")`).
///
/// See $(LINK2 ../../../../docs/specs/nix/SPEC.md, SPEC §10).
module sparkles.nix.flake;

import std.string : toStringz;
import std.typecons : RefCounted, RefCountedAutoInitialize, Tuple, tuple;

import nc = sparkles.nix.c;
import sparkles.nix.error;
import sparkles.nix.strings;
import sparkles.nix.value : Value;
import sparkles.nix.eval : EvalState, EvalStateBuilder;
import sparkles.nix.library : initNix;

/// Reusable reference-counted-handle boilerplate: a `Payload` owning one C
/// pointer (freed once via `freeFn`), an `_rc`, a package `ptr` accessor, and a
/// private `wrap` factory.
private mixin template CHandle(CType, alias freeFn)
{
    private static struct Payload
    {
        CType* ptr;
        @disable this(this);
        ~this() @trusted nothrow @nogc
        {
            if (ptr !is null)
                freeFn(ptr);
        }
    }

    private RefCounted!(Payload, RefCountedAutoInitialize.no) _rc;

    package CType* ptr() @trusted nothrow @nogc => _rc.ptr;

    private static typeof(this) wrap(CType* p) @trusted
    {
        typeof(this) h;
        h._rc = RefCounted!(Payload, RefCountedAutoInitialize.no)(p);
        return h;
    }
}

/// Shared fetcher settings (`nix_fetchers_settings`).
struct FetchersSettings
{
    mixin CHandle!(nc.nix_fetchers_settings, nc.nix_fetchers_settings_free);

    static NixResult!FetchersSettings create() @trusted
    {
        auto i = initNix();
        if (i.hasError)
            return nixErr!FetchersSettings(i.error);
        auto ctx = NixContext.create();
        auto r = checkCall!(nc.nix_fetchers_settings_new)(ctx);
        if (r.hasError)
            return nixErr!FetchersSettings(r.error);
        return nixOk(wrap(r.value));
    }
}

/// Flake settings (`nix_flake_settings`).
struct FlakeSettings
{
    mixin CHandle!(nc.nix_flake_settings, nc.nix_flake_settings_free);

    static NixResult!FlakeSettings create() @trusted
    {
        auto i = initNix();
        if (i.hasError)
            return nixErr!FlakeSettings(i.error);
        auto ctx = NixContext.create();
        auto r = checkCall!(nc.nix_flake_settings_new)(ctx);
        if (r.hasError)
            return nixErr!FlakeSettings(r.error);
        return nixOk(wrap(r.value));
    }
}

/// Attaches `settings` to a builder so the evaluator gets `builtins.getFlake`
/// etc. UFCS extension (call on an lvalue builder before `build`):
/// ---
/// auto b = EvalStateBuilder.create(store);
/// b.flakes(flakeSettings);
/// auto es = b.build();
/// ---
ref EvalStateBuilder flakes(return ref EvalStateBuilder builder, ref FlakeSettings settings) @trusted
{
    auto ctx = NixContext.create();
    auto r = checkCall!(nc.nix_flake_settings_add_to_eval_state_builder)(ctx, settings.ptr, builder
            .rawBuilder);
    if (r.hasError)
        builder._error = r.error; // sticky; surfaced at build()
    return builder;
}

/// Flags controlling flake-reference parsing (`nix_flake_reference_parse_flags`).
struct FlakeReferenceParseFlags
{
    mixin CHandle!(nc.nix_flake_reference_parse_flags, nc.nix_flake_reference_parse_flags_free);

    static NixResult!FlakeReferenceParseFlags create(ref FlakeSettings settings) @trusted
    {
        auto ctx = NixContext.create();
        auto r = checkCall!(nc.nix_flake_reference_parse_flags_new)(ctx, settings.ptr);
        if (r.hasError)
            return nixErr!FlakeReferenceParseFlags(r.error);
        return nixOk(wrap(r.value));
    }

    /// Sets the base directory for resolving relative flake references.
    NixResult!void baseDirectory(in char[] dir) @trusted
    {
        auto ctx = NixContext.create();
        return checkCall!(nc.nix_flake_reference_parse_flags_set_base_directory)(ctx, ptr, dir.ptr, dir
                .length);
    }
}

/// A parsed flake reference (`nix_flake_reference`).
struct FlakeReference
{
    mixin CHandle!(nc.nix_flake_reference, nc.nix_flake_reference_free);

    /// Parses `"<flakeref>[#<fragment>]"`, returning the reference and the
    /// fragment string (`nix_flake_reference_and_fragment_from_string`).
    static NixResult!(Tuple!(FlakeReference, string)) parse(
        ref FetchersSettings fetch, ref FlakeSettings flake,
        ref FlakeReferenceParseFlags flags, in char[] reference) @trusted
    {
        import std.array : appender;

        alias R = Tuple!(FlakeReference, string);
        auto ctx = NixContext.create();
        nc.nix_flake_reference* outRef = null;
        auto frag = appender!(char[]);
        auto cb = cast(nc.nix_get_string_callback)&stringSinkCallback!(typeof(frag));

        cast(void) nc.nix_flake_reference_and_fragment_from_string(
            ctx.ptr, fetch.ptr, flake.ptr, flags.ptr,
            reference.ptr, reference.length, &outRef, cb, cast(void*)&frag);
        auto chk = ctx.check();
        if (chk.hasError)
            return nixErr!R(chk.error);
        return nixOk(tuple(wrap(outRef), cast(string) frag[]));
    }
}

/// Flags controlling how a flake is locked (`nix_flake_lock_flags`).
struct FlakeLockFlags
{
    mixin CHandle!(nc.nix_flake_lock_flags, nc.nix_flake_lock_flags_free);

    static NixResult!FlakeLockFlags create(ref FlakeSettings settings) @trusted
    {
        auto ctx = NixContext.create();
        auto r = checkCall!(nc.nix_flake_lock_flags_new)(ctx, settings.ptr);
        if (r.hasError)
            return nixErr!FlakeLockFlags(r.error);
        return nixOk(wrap(r.value));
    }

    /// Fail if the lock file is not up to date.
    NixResult!void modeCheck() @trusted
    {
        auto ctx = NixContext.create();
        return checkCall!(nc.nix_flake_lock_flags_set_mode_check)(ctx, ptr);
    }

    /// Update the lock in memory only (never write it to disk).
    NixResult!void modeVirtual() @trusted
    {
        auto ctx = NixContext.create();
        return checkCall!(nc.nix_flake_lock_flags_set_mode_virtual)(ctx, ptr);
    }

    /// Update and write the lock file on disk as needed (the default).
    NixResult!void modeWriteAsNeeded() @trusted
    {
        auto ctx = NixContext.create();
        return checkCall!(nc.nix_flake_lock_flags_set_mode_write_as_needed)(ctx, ptr);
    }
}

/// A locked flake (`nix_locked_flake`).
struct LockedFlake
{
    mixin CHandle!(nc.nix_locked_flake, nc.nix_locked_flake_free);

    /// Locks `reference` (`nix_flake_lock`).
    static NixResult!LockedFlake lock(
        ref FetchersSettings fetch, ref FlakeSettings flake, ref EvalState state,
        ref FlakeLockFlags flags, ref FlakeReference reference) @trusted
    {
        auto ctx = NixContext.create();
        auto r = checkCall!(nc.nix_flake_lock)(ctx, fetch.ptr, flake.ptr, state.st, flags.ptr,
            reference.ptr);
        if (r.hasError)
            return nixErr!LockedFlake(r.error);
        return nixOk(wrap(r.value));
    }

    /// The flake's `outputs` attribute set, as a `Value`
    /// (`nix_locked_flake_get_output_attrs`).
    NixResult!Value outputs(ref FlakeSettings flake, ref EvalState state) @trusted
    {
        auto ctx = NixContext.create();
        auto r = checkCall!(nc.nix_locked_flake_get_output_attrs)(ctx, flake.ptr, state.st, ptr);
        if (r.hasError)
            return nixErr!Value(r.error);
        return nixOk(Value.adopt(r.value));
    }
}

@("nix.flake.parseAndBuild")
@system
unittest
{
    import sparkles.nix.store : Store;
    import sparkles.nix.library : setSetting;

    auto exp = setSetting("experimental-features", "flakes");
    assert(!exp.hasError, exp.hasError ? exp.error.message : "");

    auto store = Store.open("dummy://").value;
    auto fetch = FetchersSettings.create();
    assert(fetch.hasValue, fetch.hasError ? fetch.error.message : "");
    auto flake = FlakeSettings.create();
    assert(flake.hasValue, flake.hasError ? flake.error.message : "");

    // A flakes-enabled evaluator exposes builtins.getFlake.
    auto b = EvalStateBuilder.create(store);
    b.flakes(flake.value);
    auto es = b.build();
    assert(!es.hasError, es.hasError ? es.error.message : "");

    // Parsing splits off the #fragment via the string callback.
    auto pf = FlakeReferenceParseFlags.create(flake.value).value;
    auto parsed = FlakeReference.parse(fetch.value, flake.value, pf, "github:NixOS/nixpkgs#hello");
    assert(parsed.hasValue, parsed.hasError ? parsed.error.message : "");
    assert(parsed.value[1] == "hello");
}
