/// `sparkles:nix` — embed the Nix evaluator in D.
///
/// Open a store, evaluate Nix expressions and flakes, and extract typed
/// values, by binding Nix's stable C API. Two layers:
///
/// $(UL
///   $(LI `sparkles.nix.c` — raw ImportC bindings (the real Nix C headers,
///        compiled directly, so layouts never drift from upstream).)
///   $(LI the high-level wrappers re-exported here — RAII handles,
///        `Expected`-based errors, output-range string bridging.)
/// )
///
/// See $(LINK2 ../../docs/specs/nix/SPEC.md, the specification).
module sparkles.nix;

public import sparkles.nix.c;
