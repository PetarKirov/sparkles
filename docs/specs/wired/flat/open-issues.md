---
status: draft
owner: sparkles:wired
reviewed: 2026-10-16
---

# `sparkles.wired.flat` — Open issues

Questions the [Flat specification](./SPEC.md) leaves unresolved, each with the
requirements it affects, the work it blocks in [PLAN.md](./PLAN.md), and a
leaning where there is one. Resolve an issue by folding the decision into the
specification and deleting its entry here; numbers are not reused.

## O1: The byte source

**Affects:** `WFL9`, `WFL10`. **Blocks:** FL4.

Flat reads a caller-owned `const(ubyte)[]` and never obtains bytes. Its first
consumer needs a source that maps a file read-only on Linux and macOS, and
returns an uncompressed Android asset's buffer through `AAsset_getBuffer`,
with the lifetime of the slice tied to an owning handle that unmaps or closes
on destruction. `sparkles:base` has no such source. It needs its own
specification in `sparkles:base`, covering: read-only private mappings, so
that `WFL10`'s "bytes do not change" holds for files not rewritten in place;
what happens when another process truncates a mapped file (`SIGBUS` is outside
any D-level contract, so the consumer's writer must replace files atomically by
rename); compressed assets, whose buffer is a decompressed copy; and the
alignment the source guarantees, which for an uncompressed asset is that of
its offset in the package (`WFL45`).

**Leaning:** a `sparkles.base` mapped-file and asset handle whose `bytes()` is
`return scope`, specified before FL4 starts.

## O2: The content key

**Affects:** `WFL43`, `WFL49`. **Blocks:** FL4.

The header reserves 32 bytes for the content hash of a file's inputs, supplied
by the caller. The startup slice keys its caches by that hash. Which hash
function, and which library provides it, is the consumer's decision; a BLAKE3
implementation for `sparkles:base` is separate work, outside this
specification. Flat treats the key as opaque bytes.

## O3: `@WireCheck` is not delivered

**Affects:** `WFL28`, and the `ItemVariationData` description of `WFL42`.
**Blocks:** FL2.

Cross-field checks reuse `@WireCheck` from the expressiveness specification,
which has no implementation. If it has not landed when FL2 starts, FL2 delivers
the attribute and its `bool` and `string` result forms in the shared policy
module, as expressiveness §6.4 specifies, rather than a Flat-private check.

## O4: fontTools is not in the dev shell

**Affects:** FL2 oracles. **Blocks:** FL2 acceptance.

HarfBuzz is in the dev shell and reachable through `sparkles:font-oracle`, but
it exposes neither raw Coverage contents nor raw delta rows. fontTools' `ttx`
dumps do. Either fontTools joins `devPackages` and the goldens are regenerated
by a test, or a committed command produces them once and the dumps are
committed with the fonts' content hashes.

**Leaning:** commit the goldens and the command; CI then needs no Python.

## O5: Plain results after validation

**Affects:** `WFL21`, `WFL23`, `WFL55`.

Reads of a view's fixed part return plain values (`WFL55`), but reads that
reach bytes opening did not check return `FlatResult` even after a successful
`validateFlat`: conditional fields, offsets, array elements and restricted
leaves. That is safe under `WFL10` but verbose for consumers such as the
catalog, which validate once. A validated view whose remaining reads return
plain values would have to choose what to do when a read fails because the
caller broke `WFL10`; any choice short of an error value reintroduces a failure
from data that is not a value. Options: (A) keep results for those reads;
(B) plain values that are `.init` on failure, with a sticky error flag on the
view; (C) plain values whose failure is a `RangeError`, as the consequence of a
caller contract breach.

**Leaning:** (A) for FL1–FL3, revisited with FL4's consumer code in hand.

## O6: No big-endian host

**Affects:** `WFL16`, `WFL17`.

Every Sparkles target is little-endian. The in-place path for big-endian
descriptions, and the swapped path for little-endian ones, run only on a
big-endian host, which no CI runner provides. The forced host-endian parameter
of `WFL7` tests the trait's answer on one machine, but `native` follows the
actual host and does not exist for a foreign order (`WFL16`), so no test on a
little-endian machine compiles it. A QEMU user-mode run of a big-endian target
(for example `s390x`) would close the gap if LDC can target it from the dev
shell; until then the evidence for those two branches stays `partial`.

## O7: Provisional validation limits

**Affects:** `WFL24`. **Blocks:** FL2 acceptance.

The defaults, a depth of 64 and a traversal budget of 64 times the region
length clamped to between 16,384 and 2^30 − 1, are HarfBuzz's sanitizer limits
and are not measured for Flat. Flat charges a shared target at every visit,
and `GSUB` and `GPOS` share Coverage tables heavily, so the budget may reject
valid fonts; `COLR` paint graphs may nest deeper than the acceptance set.
FL2's gate runs `validateFlat` with the defaults over every bundled font's
`GSUB`, `GPOS`, `GDEF` and `HVAR` and records the largest charge and depth. If
a table fails, either the factor rises or shared targets are charged once per
validation, which needs a bounded visited set.

## O8: Evolution of arena formats

**Affects:** `WFL43`, `WFL44`, `WFL54`.

An arena file whose version or layout digest differs is rejected and rebuilt,
and a layout pin makes a changed layout a compile error until the version is
bumped. That suits caches keyed by content and built in the same Nix build as
their reader. A format that must be read by an older or newer reader, such as a
file shipped separately from the app, would need additive tail fields under a
minor version, in the manner of OpenType's version-dependent tails. No such
consumer exists, so the specification excludes it.

## O9: Sub-byte fields and stream codecs

**Affects:** `WFL27`, scope.

`@FlatBits` names bit ranges inside one unsigned integer leaf, which covers
OpenType's packed flags. cerealed's `@Bits!N` packs consecutive fields of any
bit width across byte boundaries, as some network protocols require. cerealed
also encodes D values whose size lives only in the stream: slices behind a
length prefix, strings, nested variable values. Flat does neither; its values
are records read in place. Both are excluded from every milestone; a consumer
that needs either brings a separate design.

## O10: Alias-carrying attributes through the shared schema

**Affects:** `WFL2`, `WFL4`, `WFL6`. **Blocks:** FL0 acceptance.

`WFL2` requires the layout to walk `T` in lockstep with the node indices of
`wireSchemaOf!(Flat, T)`. The schema has no offsets or sizes, and it preserves
unrecognized attributes only as strings, a type name and a CTFE spelling of
the value, so a count rule that names a function
(`@FlatCount!(narrowCount, …)`) or a check lambda cannot be recovered from it.
The JSON and SDL codecs already walk the D type beside the schema's node
indices, and the base library re-reads the alias-carrying `@WireConvert` from
the declaration. Two further facts bear on `WFL4`: `wireSchemaOf` rejects a
pointer field with its own `static assert` ("unsupported schema type") that
names no field path, and its field enumeration drops a nested struct's context
pointer without comment. Flat's checks therefore run before the schema is
built.

**Spike result (2026-10-17): feasible.** The FL0 spike, recorded with its
evidence in [PLAN.md](./PLAN.md#fl0-specification-review-and-the-o10-spike),
walked natural, packed, dynamic-tailed and nested records in lockstep with
`wireSchemaOf!(Flat, T)` on LDC 1.42.0 and DMD 2.112.1, with no change to
`sparkles:wired`. It reached and called a function alias through the field's
own attributes, and Flat's check reported the pointer field and the context
pointer with their paths before the schema builder could. Two points carry into
FL1: pair fields with schema children by ordinal, not by wire key; and treat
the context-pointer rejection as Flat's, since the schema hides it. `Offset`
targets, unions, recursion and cross-compiles were not covered. The issue
closes when the owner accepts FL0.
