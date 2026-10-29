/// Nix library lifecycle, version, and global settings.
///
/// $(B Threading & GC model.) The Nix C API exposes no thread-registration
/// function. $(LREF initNix) (via `nix_libexpr_init` → `nix::initGC`) registers
/// the calling thread with the Boehm GC and there is no public way to register
/// another. Therefore: call $(LREF initNix) and perform $(I all) evaluation —
/// building the `EvalState`, evaluating, forcing, and reading every `Value` —
/// on the $(I same thread). This still supports a dedicated, large-stack
/// evaluation thread (as nixops4/devenv use): just call `initNix` on that
/// thread. Reference-counting (`Value` copy/destroy) is thread-safe; only
/// evaluation is thread-confined.
///
/// See $(LINK2 ../../../../docs/specs/nix/SPEC.md, SPEC §6).
module sparkles.nix.library;

import std.string : toStringz;

import sparkles.test_runner.attributes : serial, ThreadAffinity;
import sparkles.base.sync.mutex : Mutex;
import sparkles.nix.c;
import sparkles.nix.error;
import sparkles.nix.strings;

private __gshared Mutex _libMutex;
private __gshared bool _initDone;
private __gshared bool _initOk;
private __gshared NixError _initError;

/// Initializes the Nix library (util → store → expr, including the GC), once
/// per process. Idempotent and thread-safe; the first call's result is cached
/// and returned by every subsequent call. Must run before opening a `Store` or
/// building an `EvalState`.
NixResult!void initNix() @trusted
{
    auto held = _libMutex.guard();

    if (!_initDone)
    {
        auto ctx = NixContext.create();
        auto r = checkCall!nix_libexpr_init(ctx);
        _initDone = true;
        _initOk = !r.hasError;
        if (r.hasError)
            _initError = r.error;
    }
    return _initOk ? nixOk() : nixErr!void(_initError);
}

/// The version of the linked libnix, e.g. `"2.35.0"`.
///
/// Wraps `nix_version_get`, which returns a static, NUL-terminated C string and
/// never fails (it needs no prior initialization).
string nixVersion() @trusted nothrow
{
    import core.stdc.string : strlen;

    const(char)* p = nix_version_get();
    if (p is null)
        return null;
    return p[0 .. strlen(p)].idup;
}

/// Sets a global Nix setting (`nix_setting_set`). Prefix `key` with `extra-` to
/// append rather than replace. Settings are process-global mutable state with
/// no internal locking, so this is serialized and intended for single-threaded
/// startup configuration (e.g. enabling experimental features). Settings only
/// affect `EvalState`s built afterwards.
///
/// ---
/// setSetting("experimental-features", "flakes");
/// ---
NixResult!void setSetting(in char[] key, in char[] value) @trusted
{
    auto held = _libMutex.guard();

    auto ctx = NixContext.create();
    const keyZ = key.toStringz;
    const valZ = value.toStringz;
    return checkCall!nix_setting_set(ctx, keyZ, valZ);
}

/// Reads a global Nix setting (`nix_setting_get`). Returns a `NixError` with
/// code `NixErrCode.key` if the setting is unknown.
NixResult!string getSetting(in char[] key) @trusted
{
    auto held = _libMutex.guard();

    auto ctx = NixContext.create();
    const keyZ = key.toStringz;
    return collectString(ctx, (cb, ud) => nix_setting_get(ctx.ptr, keyZ, cb, ud));
}

@("nix.library.nixVersion.nonEmpty")
@serial(threadAffinity: ThreadAffinity.mainThread) @system
unittest
{
    const v = nixVersion();
    assert(v.length > 0, "nix_version_get returned an empty version string");
}

@("nix.library.initNix.idempotent")
@serial(threadAffinity: ThreadAffinity.mainThread) @system
unittest
{
    // Idempotent: the second call returns the cached result.
    auto r1 = initNix();
    auto r2 = initNix();
    assert(!r1.hasError, "initNix failed: " ~ (r1.hasError ? r1.error.message : ""));
    assert(!r2.hasError);
}

@("nix.library.setting.roundTrip")
@serial(threadAffinity: ThreadAffinity.mainThread) @system
unittest
{
    auto init = initNix();
    assert(!init.hasError);

    // A known setting round-trips; an unknown one yields NixErrCode.key.
    auto set = setSetting("experimental-features", "flakes");
    assert(!set.hasError, set.hasError ? set.error.message : "");

    auto missing = getSetting("this-setting-does-not-exist");
    assert(missing.hasError);
    assert(missing.error.code == NixErrCode.key);
}
