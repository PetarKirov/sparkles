/// `sparkles:nix` — embed the Nix evaluator in D.
///
/// Open a store, evaluate Nix expressions and flakes, and extract typed
/// values, by binding Nix's stable C API. Two layers:
///
/// $(UL
///   $(LI the high-level wrappers re-exported here — RAII handles,
///        `Expected`-based errors (`NixResult!T`), and a $(D NixSession)
///        facade for the common path.)
///   $(LI `sparkles.nix.c` — raw ImportC bindings (the real Nix C headers,
///        compiled directly). $(B Not) re-exported here, to avoid clashing the
///        C `Store`/`EvalState`/`Value` types with the wrappers; `import
///        sparkles.nix.c;` explicitly for raw access.)
/// )
///
/// ---
/// import sparkles.nix;
///
/// auto nix = NixSession.open().value;
/// auto v   = nix.eval("1 + 2").value;
/// assert(nix.requireInt(v).value == 3);
/// ---
///
/// See $(LINK2 ../../docs/specs/nix/SPEC.md, the specification).
module sparkles.nix;

public import sparkles.nix.error;
public import sparkles.nix.library;
public import sparkles.nix.value;
public import sparkles.nix.store;
public import sparkles.nix.eval;
public import sparkles.nix.flake;
public import sparkles.nix.session;
