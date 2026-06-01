# Add a new scheme

You want to teach the library a version dialect it does not yet ship.
There is nothing to subclass and no engine to configure: a scheme is
just a plain struct that conforms to `isVersionScheme!S`. Provide the
two-member required surface, declare only the optional capabilities your
ecosystem actually has, assert conformance, register it, and add tests.

This guide gives the recipe. For the exact concept definitions see the
[concepts reference](../reference/concepts.md); for the catalogue
conventions (capability-matrix row, provenance) see the
[scheme catalogue](../reference/schemes.md); the normative signatures
are in [SPEC §3.1](../../../specs/versions/SPEC.md#31-required-surface--isversiont)
and [§6.1](../../../specs/versions/SPEC.md#61-required-surface--isversionschemes).

## 1. Write the required surface

Create `schemes/<purl_type>.d`, named for the purl `type` where one
exists, else a descriptive `snake_case` name. The struct is both the
version _value_ and the scheme _handle_: it carries the instance
`opCmp` / `toString` of a version and the static `purlType` / `parse` of
a scheme.

The required members are a three-way `opCmp` and an output-range
`toString` (this is `isVersion!S`), plus `purlType`, `alias Version`,
and `static parse` (this is `isVersionScheme!S`). Provide `opEquals` and
`toHash` consistent with `opCmp` so versions work as keys and under
`==`:

```d
module sparkles.versions.schemes.myscheme;

import sparkles.versions.parsing : ParseExpected;
import sparkles.versions.ranges  : Ranges;

struct MyScheme
{
    // ... fields holding the parsed version ...

    // Required version surface (isVersion!S).
    int  opCmp(in MyScheme other) const @safe pure nothrow @nogc;
    bool opEquals(in MyScheme other) const @safe pure nothrow @nogc;
    size_t toHash() const @safe pure nothrow @nogc;
    void toString(W)(ref W sink) const;   // writes into an output range

    // Required scheme surface (isVersionScheme!S).
    alias Version = MyScheme;              // usually the struct itself
    alias Range   = Ranges!MyScheme;
    enum string purlType = "myscheme";     // non-empty pURL type string

    static ParseExpected!MyScheme parse(string s) @safe pure nothrow;
}
```

`opCmp` must be a total order over every value the parser admits, and
`toString` must round-trip — `parse(s).value.toString` reproduces `s`
(or its documented normalised form).

## 2. Declare only the capabilities the ecosystem has

Each optional capability is an independently-detectable trait. Add a
member only when the capability holds for _every_ value of the type
(the all-or-nothing rule), and only when its fast path agrees with the
required-surface fallback (the equivalence rule). Both rules are
explained in [the design](../explanation/design.md#the-required--optional-split).

- `orderKey` — an unsigned-integer key (`ubyte` … `ulong`). Declare it
  **only when the order packs monotonically into an unsigned integer**.
  Structural schemes whose order does not pack — `pypi`, `maven`, `deb` —
  must **not** declare it; their `opCmp` does the full structural walk
  and `sort` falls back to comparison sorting. Absence is never an error.
- `components` — an `enum string[] components` of named unsigned fields,
  most-significant first. Begin it with `["major","minor","patch"]` only
  if `^`/`~` genuinely apply; a calendar scheme declares
  `["year","month","day"]` instead, so it correctly gets no caret.
- `isPrerelease` (a `bool` property), `build` (a `const(char)[]`
  property) — declare when the ecosystem has those notions.
- `parseLoose`, `parseNativeRange` — the scheme-level optional parsers;
  add them when the ecosystem has compatibility forms or a native range
  grammar. The VERS and pURL layers `static if` on these.

The detection rules and behavioural impact of each are in
[SPEC §3.2](../../../specs/versions/SPEC.md#32-optional-capability-vocabulary)
and [§6.2](../../../specs/versions/SPEC.md#62-optional-scheme-capabilities).

## 3. Assert conformance at module scope

End the module with a compile-time check so any regression in the
required surface becomes a build failure rather than a silent capability
loss:

```d
static assert(isVersion!MyScheme && isVersionScheme!MyScheme);
```

## 4. Register the scheme

1. Public-import the module from `schemes/package.d`.
2. Add the scheme to the `AnyVersion` and `AnyRange` sum types so it
   participates in `compareAny` and the scheme-agnostic layers.
3. If the purl `type` differs from the scheme name — for instance many
   purl types map onto `SemVer` — add the mapping to the purl→scheme
   table. A scheme with no published purl type still declares a
   synthetic, scheme-named `purlType` to satisfy the concept, but it is
   _not_ added to that registry, so an incoming `pkg:...` never resolves
   to an internal scheme.

## 5. Add tests

- **Round-trip per real-world example.** For each example string `s`,
  assert `parse(s).value.toString == s` (or the documented normalised
  form). Take the examples from authoritative sources and record the
  provenance, matching the catalogue convention.
- **Ascending order.** Build a list that exercises the scheme's ordering
  edge cases, sort it, and assert the expected sequence.
- **`orderKey` vs `opCmp` equivalence** — _only if you declared
  `orderKey`._ Cross-check the packed key against the `opCmp` reference
  across the corpus: `sign(a.orderKey <=> b.orderKey) == sign(order(a, b))`
  whenever the keys differ.

Finally, add the new row to the capability matrix and a per-scheme
section in the [scheme catalogue](../reference/schemes.md), citing the
authoritative source for every example.

## Notes

- **No new required members.** The bar of two required members is held
  deliberately high; everything else is opt-in. If you find yourself
  wanting a third mandatory member, that is a signal it belongs in the
  optional vocabulary instead — see
  [the design](../explanation/design.md#the-required--optional-split).
- **The baseline.** `Generic` is the scheme with _no_ optional
  capabilities; if your scheme is opaque, model it on `Generic` and you
  exercise every fallback path for free.
