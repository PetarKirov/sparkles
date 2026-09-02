# `sparkles.wired.sdl` — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Each S-milestone is independently green:
the repository builds, `dub test :wired` passes, formatting is clean, and no
later milestone is needed to make an earlier commit valid. S-numbers are local
to the SDL backend and do not replace the base M- or expressiveness E-series._

## Dependency spine

The syntax/document engine is independent of typed serialization and may land
first. The typed backend starts only after expressiveness E1 supplies
`wireSchemaOf!(F, T)`, open format annotations, and schema references, and E2
supplies the shared walker seam. If those milestones have evolved, S5 first
adapts this plan to their shipped public contracts; it does not create an SDL
shadow schema.

Every milestone includes focused `@safe`/`@system` test annotations, negative
tests for its rejected shapes, and public DDoc for newly exposed symbols. New
files are staged before Nix-based checks so the flake can see them.

## S0 — Provenance and fixture manifest

Record the exact DUB revision used for grounding, inventory the relevant files
under `source/dub/internal/sdlang/`, `source/dub/recipe/sdl.d`, and
`source/dub/internal/configy/`, and classify each planned fixture as original,
adapted, or directly ported. Add the required SDLang zlib/libpng and DUB/Configy
MIT notices before importing any upstream-derived test body.

Gate: a reviewable fixture/provenance manifest; repository license tooling (if
present) passes; no implementation code yet. Original sparkles tests remain
under the repository license, while adapted/ported cases name source path and
revision in comments.

## S1 — Scalar model and canonical scalar writer

Add `sdl.document` scalar types (`SdlScalarKind`, date-time/zone payloads,
qualified names, positions/spans) and the canonical scalar emitter from SPEC
§3.4/§9. Reuse format-neutral integer, float, UTF-8, and Base64 primitives where
they already exist; add them to `sparkles:base` only when genuinely reusable.

Gate: one test matrix covering every scalar kind, boundary integers, signed
zero, shortest finite floats, string/character escapes, Base64, date/time zone
forms, duration fractions, and non-finite rejection. Every emitted scalar
re-parses in a temporary scalar harness and retains kind and value. The module
builds without the parser or typed codec.

## S2 — Complete lexer

Implement the compile-time `SdlParserConfig`/feature sets and the `sdlFull`,
`sdlDubCompat`, and `sdlDubRecipe` profiles before the scanner kernels. Add
UTF-8/BOM handling, identifiers and keywords, punctuation, terminators, all
scalar tokens, comments, logical-line continuation, and token spans. The lexer
is a forward range over borrowed source and returns structured `SdlError` values
rather than throwing. Scalar decoding is deferred until a consumer requests the
token value; disabled families reject as `unsupportedFeature` without
instantiating their conversion kernels.

Gate: SPEC §3 lexical conformance tests under `sdlFull`; malformed
escape/suffix/Base64/BOM and unterminated-comment cases;
CR/LF/CRLF/U+2028/U+2029 location pins; Unicode name tests; and differential
fixture outcomes under `sdlDubCompat` against the pinned DUB lexer. The
`sdlDubRecipe` profile parses the pinned DUB recipe snapshot and every in-tree
`dub.sdl`, while rejecting each disabled scalar family with its whole candidate
span. Compile-time availability checks and linked-symbol probes prove binary,
numeric, character, and temporal kernels are absent from a recipe-profile
artifact. A fuzz smoke test runs each named profile and proves arbitrary bytes
either tokenize or return an error without crash, hang, or out-of-bounds access.

## S3 — Parser and ordered arena

Implement the grammar and allocator-backed `SdlDocument`/borrowed views. Store
nodes in preorder and retain separate ordered extents for values, attributes,
and children. Add qualified-name-filtering ranges that retain all repetitions.

Gate: SPEC §4 arena invariants; anonymous-tag and child-block grammar failures;
duplicate attribute and child preservation; namespace separation; deep nesting
bounded by `SdlParserConfig.maxDepth`; allocator lifecycle/leak checks; DIP1000
compile tests preventing views from escaping their document. Representative
DUB `recipe/sdl.d` fixtures parse into expected semantic snapshots.

## S4 — Document writer and laws

Add `writeSdlDocument`, indentation options, `validateSDL`, and canonical full
document emission. This milestone is document-only and does not depend on the
wired schema.

Gate: golden canonical output for comments, raw/regular strings, boolean
aliases, semicolon terminators, namespaces, repetitions, anonymous tags, and
nested blocks. Property tests enforce both SPEC §10 document laws over generated
bounded documents. Parse-write-parse is also checked against the attributed DUB
fixture corpus. Writer failures leave the caller's error channel structured and
pathed.

## S5 — SDL schema annotations and typed role validation

Add `Sdl`, the six typed role UDAs, and the SDL projection in
`wireSchemaOf!(Sdl, T)`. Resolve default-child roles, qualified
`@WireName!Sdl`, shared case/alias/default/optional/converter/check metadata,
positional extents, dynamic name/namespace fields, and unknown policy into the
schema once.

Gate: compile-time schema snapshots for every role and composition; role UDA
values survive in open annotations; JSON schemas for the same types are
unchanged. Negative compile fixtures cover duplicate positions, a variadic value
not last, aggregate attributes, invalid names, duplicate identity fields,
root-only violations, conflicting strict/extras policy, and every other SPEC
§5.2 shape error. Diagnostics contain type, field, role, and expected shape.

## S6 — Typed decode

Implement `fromSDL!T(SdlNode)` and text `fromSDL!T` as the SDL leaf adapter over
the shared schema walk. Cover scalars, enums, null-aware values, static/dynamic
sequences, AAs, aggregates, conversions, checks, defaults, presence, and union
representations approved in the SDL schema annotation.

Gate: one fixture exercises all three channels in one aggregate; positional and
repeated-order tests; exact static-array lengths; duplicate singular child and
AA-key rejection; missing required role diagnostics; enum/name/case policy;
converter/check errors retaining source spans; `Decoded!T` presence bits; union
success and per-variant failure. Existing JSON tests and byte output remain
unchanged.

## S7 — Typed encode and canonical output

Implement `writeSDL` and `toSDL` through the same schema walk. Declaration order
governs fields, input order governs sequences, and canonical key order governs
AAs. Encode checks and converters run in the shared order.

Gate: typed goldens for DUB-shaped recipes (multiple `authors`, repeated
`configuration`, positional dependency names, attributes, namespaces, and child
settings); writer-template tests with a `Buffer`; deterministic AA output;
all schema-supported scalar kinds; encode errors with role paths. Property tests
enforce `fromSDL!T(toSDL(value)) == value` for types accepted by
`isWireRoundTrippable!(Sdl, T)`.

## S8 — Unknown fields and exact repetition preservation

Implement ignore, `@WireStrict!Sdl`, `@SdlExtra`, borrowed/owned `SdlExtras`,
ordinal merge on encode, and collision detection. Accumulating decode uses the
shared error-sink protocol.

Gate: unknown positional values, namespaced duplicate attributes, and mixed
repeated children each pass ignore/forbid/preserve tests; preserved extras
survive typed decode-encode-decode with channel order intact; collisions fail at
the extra occurrence's role path; strict accumulation reports all unknowns;
borrowed-extra lifetime checks compile under DIP1000.

## S9 — File helpers and operational errors

Add `readSDLFile` and `writeSDLFile`: source-name propagation, recursive parent
directory creation, same-directory temporary files, atomic replacement, final
newline, cleanup, and stage-specific errors.

Gate: temporary-filesystem tests for successful nested writes, read/parse/decode
source context, encode/write/rename failures, unchanged existing targets after
failure, no orphan temporary file on handled failure, and exact canonical bytes.
Platform-specific atomic-replace limitations are tested or explicitly skipped
with `skipTest`, never silently returned as passes.

## S10 — Conformance, attribution audit, and documentation handoff

Run the full attributed DUB scalar/parser/recipe fixture corpus, fuzz/regression
seeds, typed properties, and all wired tests. Audit public imports, DDoc, source
attributes, allocator ownership, and every copied/adapted test's notice. Add
library Diátaxis documentation only in a separate documentation change; this
milestone does not alter this spec's sidebar.

Gate:

- `dub test :wired` is green in debug mode;
- `dub build :wired -b checked` is green with assertions live;
- all document and typed round-trip laws pass;
- JSON conformance and byte goldens are unchanged;
- formatting and repository hooks are clean;
- the license/provenance manifest has no unclassified imported fixture;
- a final API grep matches SPEC §2/§11 and exposes no DUB internal type.

The SDL backend is complete only after S10. Performance optimization follows as
separate measured work and may not weaken source spans, ordering, scalar-kind
fidelity, error structure, or any round-trip law.
