---
status: draft
owner: sparkles:wired
reviewed: 2026-10-16
---

# `sparkles.wired.flat` — Open issues

Questions the [Flat specification](./SPEC.md) leaves unresolved, each with the
requirements it affects, the work it blocks in [PLAN.md](./PLAN.md), and a
leaning where there is one. Resolve an issue by folding the decision into the
specification and deleting its entry here.

## O1 — The byte source

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
alignment the source guarantees.

**Leaning:** a `sparkles.base` mapped-file and asset handle whose `bytes()` is
`return scope`, specified before FL4 starts.

## O2 — The content key

**Affects:** `WFL43`, `WFL49`. **Blocks:** FL4.

The header reserves 32 bytes for the content hash of a file's inputs, supplied
by the caller. The startup slice keys its caches by that hash. Which hash
function, and which library provides it, is the consumer's decision; a BLAKE3
implementation for `sparkles:base` is in progress on its own branch and is not
part of this specification. Flat treats the key as opaque bytes.

## O3 — `@WireCheck` is not delivered

**Affects:** `WFL28`, and the `ItemVariationData` description of `WFL42`.
**Blocks:** FL2.

Cross-field checks reuse `@WireCheck` from the expressiveness specification,
which has no implementation. If it has not landed when FL2 starts, FL2 delivers
the attribute and its `bool` and `string` result forms in the shared policy
module, as expressiveness §6.4 specifies, rather than a Flat-private check.

## O4 — fontTools is not in the dev shell

**Affects:** FL2 oracles. **Blocks:** FL2 acceptance.

HarfBuzz is in the dev shell and reachable through `sparkles:font-oracle`, but
it exposes neither raw Coverage contents nor raw delta rows. fontTools' `ttx`
dumps do. Either fontTools joins `devPackages` and the goldens are regenerated
by a test, or a committed command produces them once and the dumps are
committed with the fonts' content hashes.

**Leaning:** commit the goldens and the command; CI then needs no Python.

## O5 — Accessors on a validated view

**Affects:** `WFL21`, `WFL23`.

Every accessor returns `FlatResult`, even after a successful `validateFlat`.
That is safe under `WFL10` but verbose for consumers such as the catalog,
which validate once at open. A validated view type whose accessors return plain
values would have to choose what to do when, against `WFL23`'s guarantee, a
read fails because the caller broke `WFL10`; any choice short of an error value
reintroduces a failure from data that is not a value. Options: (A) keep
results everywhere; (B) plain accessors that return `.init` and set a sticky
error flag on the view; (C) plain accessors whose failure is a `RangeError`,
accepting it as a consequence of a caller contract breach.

**Leaning:** (A) for FL1–FL3, revisited with FL4's consumer code in hand.

## O6 — No big-endian host

**Affects:** `WFL16`, `WFL17`.

Every Sparkles target is little-endian. The in-place path for big-endian
descriptions, and the swapped path for little-endian ones, run only on a
big-endian host, which no CI runner provides. The forced host-endian parameter
of `WFL7` tests the selection logic on one machine. A QEMU user-mode run of a
big-endian target (for example `s390x`) would close the gap if LDC can target
it from the dev shell; until then the evidence for those two branches stays
`partial`.

## O7 — Default validation limits

**Affects:** `WFL24`.

The defaults of `FlatLimits.maxDepth` and the traversal budget's multiple of
the input length are unset. Cap'n Proto's C++ implementation defaults to a
pointer depth of 64. OpenType nests at most a handful of offsets on the paths
in the acceptance set, but `COLR` paint graphs nest deeper. The values need a
measurement over the bundled fonts' deepest real paths before FL2's gate.

## O8 — Evolution of arena formats

**Affects:** `WFL43`, `WFL44`.

An arena file whose version or layout digest differs is rejected and rebuilt.
That suits caches keyed by content and built in the same Nix build as their
reader. A format that must be read by an older or newer reader, such as a file
shipped separately from the app, would need additive tail fields under a minor
version, in the manner of OpenType's version-dependent tails. No such consumer
exists, so the specification excludes it.

## O9 — Sub-byte fields across boundaries

**Affects:** `WFL27`.

`@FlatBits` names bit ranges inside one unsigned integer leaf, which covers
OpenType's packed flags. cerealed's `@Bits!N` packs consecutive fields of any
bit width across byte boundaries, as some network protocols require. Flat does
not support that; a protocol consumer would need a separate design for
bit-granular offsets.

## O10 — Alias-carrying attributes through the shared schema

**Affects:** `WFL2`, `WFL6`. **Blocks:** the FL1 layout design.

`WFL2` requires the layout to be derived from `wireSchemaOf!(Flat, T)`. The
schema preserves unrecognized attributes as strings, a type name and a CTFE
spelling of the value. A count rule or selector that names a function
(`@FlatCount!(narrowCount, …)`) or a check lambda cannot be recovered from a
string. The base library already meets this with `@WireConvert`, which the
policy table leaves out and the walk re-reads from the declaration. FL1
starts with a spike that answers whether Flat can do the same, re-reading
attributes from the declaration that a schema node names, without a parallel
reflection of the type; if not, the shared schema gains a typed slot for
format annotations first.
