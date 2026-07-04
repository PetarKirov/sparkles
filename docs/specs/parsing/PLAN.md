# `sparkles:parsing` — Delivery Plan

_Audience: contributors implementing the toolkit. Execution-only — milestones, dependencies,
verification, deferrals. For the design rationale and prior-art justification read the
[proposal](./index.md); for the evidence base read the
[parsing survey](../../research/parsing/index.md)._

> [!NOTE]
> **Status: proposal.** This is a milestoned _plan_ for a library that does not exist yet.
> It is deliberately incremental: each milestone is independently useful, builds bottom-up on
> the existing [`sparkles.base.text`](https://github.com/PetarKirov/sparkles/blob/main/libs/base/src/sparkles/base/text/package.d)
> substrate, and can stop early — Sparkles gets value at M2 (combinators + Pratt) without
> ever needing M4. Nothing here should be built ahead of a real in-repo client that needs it.

## 1. Milestone overview

| #      | Deliverable                                                                                              | Prior art                   | Depends on |
| ------ | -------------------------------------------------------------------------------------------------------- | --------------------------- | ---------- |
| **M0** | `ParseResult!T` + the leaf-parser convention over `base.text.readers` (formalise the existing idiom)     | [nom] · in-tree             | —          |
| **M1** | Ordered-choice combinators (`seq`/`alt`/`many`/`opt`/`sepBy`/`map` + predicates), attribute-inferring    | [PEG][peg] · [nom]/[winnow] | M0         |
| **M2** | [Pratt][pratt] expression engine (binding-power loop); **first client:** version-constraint grammar      | [pratt][pratt]              | M0, M1     |
| **M3** | Error posture: fail-fast default + opt-in `cut` + opt-in [chumsky]-style recovery (partial + error list) | [flatparse] · [chumsky]     | M0–M2      |
| **M4** | _(deferred)_ Optional lossless/CST view — only if a re-serializable-tree client appears                  | [red-green][incremental]    | M1–M3      |

M0 formalises what [`parseSemVerShaped`][v-parsing] already does implicitly. M1 is the bulk.
M2 is where Sparkles first gains something it lacks today (a reusable constraint parser). M3
is a per-client policy, not new core. M4 is deferred and may never be built.

## 2. Per-milestone detail

Each milestone's outcome is: the relevant modules compiling `@safe pure nothrow @nogc` where
the leaf parsers allow, unit-tested (silly, feature modules — not `package.d`), a runnable
`[Output]` README example, and DDoc per [AGENTS.md](../../guidelines/AGENTS.md). All new code
lives in a new `libs/parsing/` sub-package (mirroring the eight existing ones) or, if it stays
small, under `libs/base/src/sparkles/base/text/` beside the readers it extends — decide at M0.

### M0 — core result + leaf convention

- Define `ParseResult!T` as `Expected!(T, ParseError, NoGcHook)` (alias the existing
  `ParseExpected!T` from [`errors.d`][base-text]) and the parser shape
  `ParseResult!T delegate(ref scope const(char)[])` / a `Parser` concept (`isParser!P`).
- Wrap the [`readers.d`][base-text] primitives (`readInteger`, `skipSpaces`, `tryConsume`,
  `readUntil`) as canonical leaf parsers; confirm advance-on-success semantics are uniform.
- **No new parsing power** — this is the vocabulary M1 composes.

### M1 — ordered-choice combinators

- `seq(p...)`, `alt(p...)` / `choice` (first-match [PEG][peg] ordered choice), `many`/`many1`,
  `opt`, `sepBy`/`sepBy1`, `map`/`mapErr`, `peek`, `notFollowedBy`. Let attributes **infer**
  (do not force `@safe`/`@nogc` on the templates — see [AGENTS § safety attributes](../../guidelines/AGENTS.md#safety-attributes--annotate-non-templates-infer-on-templates)).
- Accumulate into `SmallBuffer`, never `appender`; **no memoization**.
- Verify a `()`-returning validator allocates nothing (a `@nogc` unittest is the proof).

### M2 — Pratt engine + first real client

- A table-free binding-power loop (`prattParse!(prefix, infix)`) per [pratt-precedence][pratt].
- **First client:** re-express a version-constraint grammar (node-semver-style `>=1.2 <2.0 || ^3`)
  with M1 combinators + M2 Pratt, and validate it against the existing
  [`sparkles.versions`](https://github.com/PetarKirov/sparkles/blob/main/libs/versions/src/sparkles/versions/parsing.d)
  range parsers (same accept/reject set). This is the milestone that proves the toolkit earns
  its place.

### M3 — error posture

- Fail-fast is the default (an `err` short-circuits). Add `cut(p)` (commit — a failure after
  `cut` is unrecoverable, the [flatparse]/[nom] error vs failure split). Add an opt-in
  recovering combinator that returns `(partial value, ParseError[])` for user-facing grammars,
  modelled on [chumsky]'s `ParseResult`. Recovery is opt-in per parser, never global.

### M4 — deferred: lossless view

- Only if a client needs a re-serializable CST (e.g. a config formatter): a lossless node type
  that records byte spans + trivia, borrowing the [red-green][incremental] position-free-node
  idea. Do **not** build speculatively.

## 3. Verification

- **Per milestone:** `dub test :parsing` (or `:base`) green; a `@nogc` unittest proving the
  zero-allocation property (M0/M1); the M2 client matching `sparkles.versions`' accept/reject
  set on a shared corpus; a runnable README `[Output]` example verified by
  `nix run .#ci -- --verify`.
- **Idiom conformance:** `@safe pure nothrow @nogc` on leaf/non-template code; attributes
  inferred on combinator templates; `Expected` (no exceptions in the `@nogc` path); tests in
  feature modules, not `package.d` (the silly gotcha).
- **Docs:** the toolkit gets a `docs/libs/parsing/` Diátaxis tree when it lands; this
  `docs/specs/parsing/` pair (proposal + plan) becomes its design-history reference.

## 4. Deferrals / non-goals

Per the [proposal §4](./index.md#4-non-goals-and-why): no SIMD by default (use [mir-ion]/[asdf]
if a megabyte-JSON need appears), no incremental/query machinery (Sparkles parses once), no
CTFE grammar DSL à la [Pegged] (hand-written RD is the survey's evidence-backed default). This
plan builds the small `@nogc` combinator + Pratt layer that D lacks
([the gap](../../research/parsing/d-landscape.md#synthesis--the-gap-sparkles-fills)) — nothing more.

<!-- References -->

[survey]: ../../research/parsing/index.md
[comparison]: ../../research/parsing/comparison.md
[peg]: ../../research/parsing/theory/peg-packrat.md
[pratt]: ../../research/parsing/theory/pratt-precedence.md
[incremental]: ../../research/parsing/theory/incremental.md
[nom]: ../../research/parsing/rust-nom.md
[winnow]: ../../research/parsing/rust-winnow.md
[flatparse]: ../../research/parsing/haskell-flatparse.md
[chumsky]: ../../research/parsing/rust-chumsky.md
[mir-ion]: ../../research/parsing/d-landscape.md
[asdf]: ../../research/parsing/d-landscape.md
[Pegged]: ../../research/parsing/d-landscape.md
[base-text]: https://github.com/PetarKirov/sparkles/blob/main/libs/base/src/sparkles/base/text/package.d
[v-parsing]: https://github.com/PetarKirov/sparkles/blob/main/libs/versions/src/sparkles/versions/schemes/semver.d
