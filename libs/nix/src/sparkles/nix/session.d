/// The `NixSession` convenience facade.
///
/// Bundles the common "evaluate some expressions" setup — `initNix` + a `Store`
/// + an `EvalState` — behind one handle, and forwards the frequently used value
/// operations. Everything happens on the calling thread (SPEC §6.3).
///
/// See $(LINK2 ../../../../docs/specs/nix/SPEC.md, SPEC §11).
module sparkles.nix.session;

import std.typecons : Nullable;

import sparkles.nix.error;
import sparkles.nix.value : Value, ValueType;
import sparkles.nix.store : Store, StorePath;
import sparkles.nix.eval : EvalState, RealisedString;

/// A batteries-included evaluator: store + eval state on the calling thread.
struct NixSession
{
    private EvalState _es;

    /// Opens a session. `storeUri` defaults to the in-memory `"dummy://"` store
    /// (no daemon needed); pass `""`/`null` for the default store.
    static NixResult!NixSession open(in char[] storeUri = "dummy://",
        scope const(char[])[] lookupPath = null)
    {
        auto store = Store.open(storeUri);
        if (store.hasError)
            return nixErr!NixSession(store.error);
        auto es = EvalState.create(store.value, lookupPath);
        if (es.hasError)
            return nixErr!NixSession(es.error);
        NixSession s;
        s._es = es.value;
        return nixOk(s);
    }

    /// The underlying evaluator, for the full value API.
    ref EvalState evalState() return => _es;

    /// The session's store.
    Store store() => _es.store;

    // --- forwarded operations --------------------------------------------

    /// ditto
    NixResult!Value eval(in char[] expr, in char[] path = "<string>") => _es.eval(expr, path);
    /// ditto
    NixResult!ValueType valueType(in Value v) => _es.valueType(v);
    /// ditto
    NixResult!long requireInt(in Value v) => _es.requireInt(v);
    /// ditto
    NixResult!double requireFloat(in Value v) => _es.requireFloat(v);
    /// ditto
    NixResult!bool requireBool(in Value v) => _es.requireBool(v);
    /// ditto
    NixResult!string requireString(in Value v) => _es.requireString(v);
    /// ditto
    NixResult!string requirePath(in Value v) => _es.requirePath(v);
    /// ditto
    NixResult!(Value[]) requireList(in Value v) => _es.requireList(v);
    /// ditto
    NixResult!(string[]) attrNames(in Value v) => _es.attrNames(v);
    /// ditto
    NixResult!Value requireAttr(in Value v, in char[] name) => _es.requireAttr(v, name);
    /// ditto
    NixResult!(Nullable!Value) requireAttrOpt(in Value v, in char[] name) => _es.requireAttrOpt(v, name);
}

@("nix.session.evalAndExtract")
@system
unittest
{
    auto opened = NixSession.open();
    assert(opened.hasValue, opened.hasError ? opened.error.message : "");
    auto nix = opened.value;

    assert(nix.requireInt(nix.eval("1 + 2").value).value == 3);
    assert(nix.requireString(nix.eval(`"x" + "y"`).value).value == "xy");

    auto attrs = nix.eval(`{ a = 1; b = 2; }`).value;
    assert(nix.attrNames(attrs).value == ["a", "b"]);
    assert(nix.requireInt(nix.requireAttr(attrs, "b").value).value == 2);
}
