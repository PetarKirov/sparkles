# `sparkles:versions` — Delivery Plan

_Audience: contributors implementing the library. This document is
execution-only — milestones, the dynamic-workflow orchestration that
builds them, verification, and deferrals. For the desired-state
specification, read [SPEC.md](./SPEC.md); for design history and
prior-art justification, read [RATIONALE.md](./RATIONALE.md); for the
per-scheme catalogue, read [PRESETS.md](./PRESETS.md)._

The library is a set of hand-written, per-ecosystem version **structs**
conforming to compile-time concepts — a required `isVersion!T` plus an
orthogonal optional capability vocabulary — with generic algorithms
(`Ranges!V`, VERS interop, purl dispatch) layered as fallback/fast-path
shells over those capabilities. The milestones below build that surface
bottom-up; each one is realised as a single dynamic-workflow invocation.

## 1. Milestone overview

| #      | Deliverable                                                                                                                 | Depends on |
| ------ | --------------------------------------------------------------------------------------------------------------------------- | ---------- |
| **M1** | Foundation (traits, parse-error types, salvaged internals) + ten version schemes including the `Generic` void-hook baseline | —          |
| **M2** | `Ranges!V` set-algebra + per-scheme native range parsers + prerelease-in-range policy                                       | M1         |
| **M3** | VERS URI interop (`parseVersUri`/`formatVersUri`) + per-scheme constraint mapping + compile-time scheme registry            | M1, M2     |
| **M4** | purl parser + `schemeForPurlType` / `parsePurlVersion` dispatch + non-identity purl→scheme table                            | M1         |
| **M5** | `AnyVersion`/`AnyRange` sum types + `compareAny` + README rewrite + DDoc polish                                             | M1–M4      |
| **M6** | Documentation rewrite (SPEC, RATIONALE, PRESETS, PLAN)                                                                      | M1–M5      |

M1 is the bulk of the work. M2/M4 are independent of each other (both
depend only on M1); M3 layers on top of M2; M5 integrates everything; M6
documents the shipped state.

## 2. Per-milestone detail

Each milestone's _outcome_ is the relevant SPEC sections compiling,
passing their unit tests, and documented per
[AGENTS.md](../../guidelines/AGENTS.md). The detail below is execution-focused —
which files ship and in what dependency order — and does not re-specify
the API; follow the linked SPEC sections for behaviour.

### M1 — Foundation + ten schemes

Replaces the deleted DbI engine (`engine.d`, `parser.d`, `layouts.d`,
`presets.d`, `semver_rules.d` — `Version!Layout`, `layoutBody`,
`LayoutDescriptor`, `@Component`/`@InternalFlag`/`@StringSlot`, and the
descriptor-walking parser) with the concept-based surface from
[SPEC §3 (The Version concept)](./SPEC.md#3-the-version-concept),
[SPEC §4 (The Range concept)](./SPEC.md#4-the-range-concept), and
[SPEC §6 (The Scheme concept)](./SPEC.md#6-the-scheme-concept).

**core_cli prelude** — foundation primitives are generic, so they live in
a new `sparkles.core_cli.text` package, **not** in a `versions/_internal`.
Done as four **atomic commits**, each building green (`dub test :core-cli`)
before the next:

1. **Refactor `text_writers` → `text.writers`.** Move
   `text_writers.d` → `text/writers.d`
   (`module sparkles.core_cli.text.writers;`), add a `text/package.d`
   (`module sparkles.core_cli.text;`) re-exporting the package's modules,
   and update the importers (`logger`, `prettyprint`, `styled_template`).
   Pure move — no behaviour change.
2. **Add `writeIntegerPadded(w, val, minDigits)`** to `text.writers`, and
   refactor `logger.writePadded2` onto it (it already hand-rolls the same
   logic).
3. **Add `sparkles.core_cli.text.errors`** — the **generic**
   `ParseError {code, offset}`, `ParseErrorCode`,
   `ParseExpected!T = Expected!(T, ParseError, NoGcHook)`. Add the
   `expected` dependency to `core-cli`'s `dub.sdl`.
4. **Add `sparkles.core_cli.text.readers`** — `readInteger`, `skipWhile`,
   `tryConsume`/`tryConsumeAny`, `readUntil` — slice-advance
   (`ref scope const(char)[]`), `@safe pure nothrow @nogc`. `readInteger`
   returns `ParseExpected!T` and is constrained `if (isUnsigned!T)`.

**Salvage into versions** (move, do not rewrite):

- `ParseMode` → `sparkles.versions.parsing` (re-exports the core_cli
  parse types). The old `ParseError`/`ParseErrorCode`/`ParseExpected` are
  superseded by the generic core_cli versions above — not salvaged.
- `compareSemVerPrerelease`, `validateIdentifierList`, `IdentifierKind`
  → `package`-scoped in `schemes/semver.d`, reused by `schemes/dmd.d`
  (and any other SemVer-shaped scheme).
- `putPaddedNumber` → superseded by `core_cli.text.writers.writeIntegerPadded`.
- `checkParse`/`checkRoundTrip`/`checkRejects`/`checkAscending`
  → `sparkles.versions.testing` (`version(unittest)`).

**Write:**

- `traits.d` — `isVersion!T`, `isVersionRange!R`, `isVersionScheme!S`,
  and the optional capability vocabulary (`hasOrderKey`,
  `supportsPrerelease`, `hasComponents`, `hasBuildMetadata`,
  `supportsNativeRange`, `supportsLooseParse`), with unit tests asserting
  conformance against every shipped scheme.
- The ten scheme structs under `schemes/`:

  | Module                    | Struct           | purl type      | Capabilities beyond `isVersion`         |
  | ------------------------- | ---------------- | -------------- | --------------------------------------- |
  | `schemes.generic`         | `Generic`        | `generic`      | **none** (void-hook baseline)           |
  | `schemes.semver`          | `SemVer`         | `semver`       | orderKey, prerelease, components, build |
  | `schemes.dmd`             | `Dmd`            | _(D-internal)_ | orderKey, prerelease, components        |
  | `schemes.dmd_compact`     | `DmdCompact`     | _(D-internal)_ | orderKey, prerelease, components        |
  | `schemes.tiny`            | `Tiny`           | _(internal)_   | orderKey, components                    |
  | `schemes.calver_yymm`     | `CalVerYYMM`     | _(internal)_   | orderKey, components                    |
  | `schemes.calver_yyyymmdd` | `CalVerYYYYMMDD` | _(internal)_   | orderKey, components                    |
  | `schemes.vim`             | `VimVer`         | _(internal)_   | orderKey, components                    |
  | `schemes.pypi`            | `PypiVersion`    | `pypi`         | prerelease, components                  |
  | `schemes.maven`           | `MavenVersion`   | `maven`        | prerelease                              |
  | `schemes.deb`             | `DebianVersion`  | `deb`          | prerelease                              |

  SemVer is the reference scheme, written first. Dmd / DmdCompact / Tiny
  / CalVer\* / Vim port their compare-and-format logic directly from the
  old layout structs (no generation). PyPI / Maven / Debian are new:
  each implements `opCmp`, `toString`, `parse`, a stubbed
  `parseNativeRange` (filled in M2), and a real-world fixture test.

- `schemes/package.d` + root `package.d` re-exports; `dub.sdl` source
  paths updated.

Each scheme module ends with
`static assert(isVersion!ThisStruct && isVersionScheme!ThisStruct);`, so
any conformance regression is a compile error. The `Generic` scheme is
an opaque lexicographic string compare declaring **zero** optional
capabilities — it exists to exercise every generic algorithm's fallback
path.

**Key files:** core_cli `text/{writers,readers,errors}.d` +
`text/package.d`; versions `traits.d`, `parsing.d`, all eleven
`schemes/*.d`, `schemes/package.d`, `package.d`, `testing.d`.

### M2 — `Ranges!V` + native range parsers

Implements the [Range concept](./SPEC.md#4-the-range-concept) and the
generic [operations](./SPEC.md#5-operations) over it, plus the per-scheme
native range grammars.

- `ranges.d` — `Ranges!V`, the concrete sorted, disjoint interval set
  per [SPEC §4.2](./SPEC.md#4-the-range-concept). Implements the full
  method surface and bound representation specified there; no API is
  re-listed here.
- `parseNativeRange` additions per non-trivial scheme, implementing each
  ecosystem's grammar as catalogued in [PRESETS §3](./PRESETS.md). The
  six SemVer-shaped internal schemes inherit the SemVer grammar.
- Prerelease-in-range policy encoded and tested per scheme, gated on the
  `supportsPrerelease` capability (the node-semver convention specified
  in [SPEC §5.2](./SPEC.md#5-operations)).

**Key files:** `ranges.d`, the `parseNativeRange` additions to each
scheme, a `Ranges!V` property-test module.

### M3 — VERS URI interop

Implements [SPEC §9 (VERS interop)](./SPEC.md#9-vers-interop).

- `vers.d` — `VersUri`, `parseVersUri`, `formatVersUri` handling the URI
  surface only (ASCII-only, lowercase scheme, sort + dedupe
  constraints), plus the static-dispatch `parseVersAs!Scheme` template
  and runtime `parseVersAny` over `AnyRange`.
- Per scheme: `fromVersConstraint` (segment → `Range`) and
  `toVersConstraint` (`Range` → segment), with the native-operator →
  VERS-operator map as per-scheme static data, gated on
  `supportsNativeRange`.
- `schemes/package.d` gains the CTFE registry keyed by `purlType`.

**Key files:** `vers.d`, the constraint methods on each scheme, the
registry in `schemes/package.d`.

### M4 — pURL parser + `AnyVersion`/`AnyRange` + runtime dispatch

Implements [SPEC §10 (pURL interop)](./SPEC.md#10-purl-interop) and
[SPEC §11 (`AnyVersion` / `AnyRange`)](./SPEC.md#11-anyversion--anyrange).
The sum types were pulled forward from M5 because the runtime dispatch
entry points (`parsePurlVersion`, and the M3-deferred `parseVersAny`)
return them — so M4 ships them rather than stubbing.

- `any.d` — `AnyVersion`/`AnyRange` `SumType`s over all eleven schemes
  (derived from the registry scheme list) and `compareAny` returning
  `Nullable!int` (null when schemes differ).
- `purl.d` — `PackageUrl`, `parsePurl` (parse only; we consume purls, we
  do not mint them); `purlTypeToSchemeName` (the non-identity
  purl-type→scheme map, e.g. npm/cargo/.../`packagist` → `semver`); and
  `parsePurlVersion` returning `AnyVersion`.
- `parseVersAny` (in `vers.d`) — runtime VERS dispatch → `AnyRange`,
  closing the M3 deferral.

**Key files:** `any.d`, `purl.d`, `parseVersAny` in `vers.d`,
`schemes/registry.d`.

### M5 — README + DDoc

Brings the public surface to release quality (the `AnyVersion`/`AnyRange`
sum types landed in M4).

- README rewrite from "DbI engine" to "ecosystem-aware version library",
  with three runnable examples: per-ecosystem parse-and-compare; parse a
  `vers:` URI and test satisfaction; parse a purl, dispatch on type,
  parse the version, check against a range.
- DDoc on every public symbol per
  [`docs/guidelines/ddoc.md`](../../guidelines/ddoc.md).

**Key files:** `README.md`, DDoc across all public modules.

### M6 — Documentation rewrite

Rewrites all four docs to the shipped design (this is one of them).
SPEC is rebuilt around the three concepts, the per-scheme module
convention, `Ranges!V`, VERS, and purl; RATIONALE replaces the
DbI-engine narrative with the pubgrub/univers/Aether prior-art findings;
PRESETS retargets to per-scheme notes (capabilities, edge cases,
provenance, how to add a scheme); PLAN becomes this M1–M6 outline. The
`source-material/` catalogues are inputs and stay untouched.

**Key files:** `docs/specs/versions/{SPEC,RATIONALE,PRESETS,PLAN}.md`.

## 3. Execution via dynamic workflows

Each milestone is implemented as **one `Workflow` invocation**, run in
sequence so the result of one informs the next. Within a milestone,
agents fan out over independent units of work — one module each — and
converge through a serial build-and-fix loop.

### Cross-cutting conventions (all milestones)

- **No worktree isolation.** Fan-out agents write _disjoint_ files (one
  module each), so parallel writes never conflict. The only serialised
  work is the build/test loop, which runs the compiler and must be a
  single agent at a time.
- **Schema-validated agent output.** Every agent that yields structured
  data — file manifests, build-error reports, conformance verdicts,
  review findings — returns a JSON-schema-validated object, so the
  orchestrator branches on data, not prose.
- **Serial build-fix convergence loop.** After each fan-out, a `while`
  loop spawns one build agent per turn that runs
  `nix develop -c dub test :versions`, captures the first error cluster
  into a schema, fixes it, and repeats until green or the iteration cap
  is hit (then it reports residual errors back to the orchestrator).
  Schemes share one dub build and cannot compile in isolation, so the
  write-phase agents do **not** build — this loop is the single compile
  authority after the fan-out barrier.
- **Adversarial verification on the hard schemes.** PyPI (PEP 440),
  Maven (qualifier order), and Debian (epoch/upstream/revision) each get
  an independent skeptic that tries to _refute_ the comparison logic
  against authoritative test vectors (PEP 440 spec examples,
  `dpkg --compare-versions` rules, Maven `ComparableVersion` ordering)
  before the scheme is accepted. The seven SemVer-shaped schemes get a
  single-vote review.
- **Completeness critic.** M1 and M6 end with an agent asking "what's
  missing — a scheme without a conformance assert, a public symbol
  without DDoc, a doc with a stale `layoutBody` reference?" and feeds the
  answer into a final fix round.

### WF-M1 — `foundation-and-schemes`

```
phase('Foundation')          // parallel barrier — disjoint files
  ├─ delete the DbI engine surface; salvage parse_error.d
  ├─ salvage _internal/{identifier_rules,compare_semver,format,test_helpers}.d
  ├─ write traits.d (isVersion / isVersionRange / isVersionScheme + capabilities)
  └─ write ranges.d skeleton (type + isVersion-satisfying surface)
phase('Schemes')             // pipeline over the 10 scheme modules
  stage 1 write:   one agent per scheme → schemes/<purlType>.d + conformance
                   static assert + real-world round-trip tests
  stage 2 review:  adversarial correctness review (3 hard schemes get the
                   refute-skeptic; 7 SemVer-shaped + Generic get 1 vote)
phase('Integrate')           // single agent
  └─ schemes/package.d + root package.d re-exports + dub.sdl source paths
phase('Build & fix')         // serial while-loop, single build agent per turn
phase('Completeness')        // single critic agent
```

### WF-M2 — `ranges-and-native-parsers`

```
phase('Ranges')        complete Ranges!V set-algebra + property tests
                       (De Morgan, idempotence, absorption, subset/disjoint)
phase('Native parsers') pipeline over {semver/npm, maven, pypi, deb}:
                       write parseNativeRange → review. The 6 internal
                       SemVer-shaped schemes inherit the SemVer grammar.
phase('Prerelease policy') encode + test the node-semver
                       prerelease-in-range rule per scheme
phase('Build & fix')   serial loop
phase('Verify laws')   adversarial: confirm property tests are not vacuous
```

### WF-M3 — `vers-interop`

```
phase('VERS URI')      vers.d parser + emitter (ASCII/lowercase/sort/dedupe)
phase('Constraints')   pipeline per scheme: from/toVersConstraint + operator map
phase('Registry')      CTFE purlType→module registry in schemes/package.d
phase('Fixtures')      extract round-trip corpus from
                       /home/petar/code/repos/univers/tests/data
phase('Build & fix')   serial loop
phase('Round-trip')    adversarial: native → Range → VERS → Range equality
```

### WF-M4 — `purl-dispatch`

```
phase('purl parser')   purl.d (type/namespace/name/version/qualifiers/subpath)
phase('Dispatch')      schemeForPurlType template + parsePurlVersion → AnyVersion
                       + non-identity purl→scheme mapping table
phase('Conformance')   official purl-spec test suite if vendored, else curated
phase('Build & fix')   serial loop
```

### WF-M5 — `any-and-polish`

```
phase('Sum types')     any.d (AnyVersion/AnyRange + compareAny → Nullable!int)
phase('README')        rewrite README with 3 runnable examples
phase('DDoc')          parallel: one agent per public module adds DDoc
phase('Verify')        serial loop: nix run .#ci -- --verify --files README.md
```

### WF-M6 — `docs-rewrite`

```
phase('Rewrite')       parallel barrier — 4 disjoint files:
                       SPEC.md, RATIONALE.md, PRESETS.md, PLAN.md
phase('Consistency')   critic: zero remaining references to layoutBody /
                       LayoutDescriptor / Version!Layout / StringSlot in any
                       .md or .d under docs/specs/versions or libs/versions
```

## 4. Verification

Per milestone:

1. **M1.** `nix develop -c dub test :versions` exits 0. Each scheme
   module carries `static assert(isVersion!ThisStruct &&
isVersionScheme!ThisStruct);`, so any conformance regression is a
   compile-time failure. Each scheme has at least one parse-and-round-trip
   test (`checkRoundTrip!Scheme("real-world-string")`). The real-world
   catalogue from [PRESETS.md](./PRESETS.md) — Python `3.13.0a1`, Maven
   `1.0-SNAPSHOT`, Debian `2:4.13.1-0ubuntu0.16.04.1.1~`, and the rest —
   is exercised end-to-end.

2. **M2.** A property-test module asserts the set-algebra laws for
   `Ranges!V` over hand-constructed intervals: De Morgan, idempotence,
   absorption, and the `subsetOf`/`isDisjoint` consistency laws. Each
   scheme's `parseNativeRange` round-trips a small real-world corpus
   (npm `^1.2.0`, Maven `[1.0,2.0)`, PEP 440 `>=1.2.4,<2`, Debian
   `>= 2.0, << 3.0`). The prerelease-in-range rule is tested for each
   `supportsPrerelease` scheme.

3. **M3.** Round-trip property test per scheme:
   `parseNativeRange(s) ⟶ toVersConstraint ⟶ fromVersConstraint`
   produces an equal `Range`. The VERS URI parser round-trips a corpus
   pulled from univers's `tests/data/` (verbatim where semantics match).

4. **M4.** A test parses `pkg:pypi/[email protected]`,
   `pkg:npm/[email protected]`, `pkg:deb/debian/[email protected]`, and
   `pkg:maven/org.apache.commons/[email protected]`, and checks that
   each version is parsed by the dispatched scheme. The official
   purl-spec test suite (vendored or fetched at CI time) runs end-to-end
   if available; otherwise a curated subset.

5. **M5.** `nix run .#ci -- --verify --files README.md` passes for the
   three runnable examples. `dub build :versions` succeeds in release
   configuration and the documented public API matches the produced
   symbol surface (verified via a `-Xf=docs.json` introspection check).

6. **M6.** All four docs rewritten; no remaining references to
   `layoutBody`, `LayoutDescriptor`, `Version!Layout`, or `StringSlot`
   in any `.md` or `.d` file under `docs/specs/versions/` or
   `libs/versions/`.

### Capability-matrix coverage

Beyond the per-milestone checks, the test suite verifies each optional
primitive **individually**:

- `hasOrderKey` — present on SemVer-shaped schemes, absent on `Generic`,
  PyPI, Maven, Debian; covered by static `static assert` checks both
  ways. Where present, an **orderKey-vs-opCmp equivalence test** asserts
  `sign(a.orderKey <=> b.orderKey) == sign(a <=> b)` whenever the keys
  differ, across the scheme's example corpus.
- `supportsPrerelease` — exercised by the prerelease-in-range tests and a
  direct `isPrerelease` assertion per scheme that provides it.
- `hasComponents` — exercised by the caret/tilde operator tests in M2.
- `hasBuildMetadata` — exercised by a build-aware compare test on SemVer.
- `supportsNativeRange` / `supportsLooseParse` — the VERS and loose-parse
  paths static-if on these, and tests cover both the present and absent
  branches (the `Generic` baseline provides neither and must still
  compile through every generic algorithm).

## 5. Out-of-scope deferrals

- **Dependency solving.** The library ships `Ranges!V` and the
  set-algebra; it does not ship a pubgrub-style solver. A resolver would
  import `sparkles.versions` and define its own `DependencyProvider` —
  that is a separate library.
- **Mutation helpers.** `bump(releaseType)`, `inc`, "next prerelease",
  `with` builders. The library survey found these rare (3 of 13
  libraries) and not part of the abstract `Version` contract. Deferred
  until a real consumer needs them.
- **Cross-scheme total order.** `compareAny` returns `Nullable!int`;
  there is no universal total order across schemes (Repology's
  `libversion` is the only precedent and is explicitly best-effort).
  Same policy as univers and the VERS spec.
- **Runtime scheme registration.** All built-in schemes are
  compile-time-known. A user can add their own scheme by writing a struct
  conforming to `isVersionScheme!T`, but the registry does not accept
  runtime-installed plugins.
- **SSO strings.** The `string`-backed prerelease/build slots stay plain
  GC `string`s. A small-string-optimised `SsoString` drop-in is deferred
  until a measured allocation cost justifies it.
- **Bucket-F pseudo-SemVer.** Hyphenless-prerelease schemes (Go
  `go1.22rc1`, Unity `2023.2.1f1`, OpenSSL `1.1.1w`, OpenSSH `9.7p1`)
  need bespoke numeric→alphanumeric tokenisers; they are not in the M1
  ten. PyPI's `3.13.0a1` is the one such form that ships, handled by the
  dedicated `PypiVersion` parser rather than a generic tokeniser.
- **Part-2 heavyweight schemes.** The part-2 catalogue (entries 26–50:
  Eclipse `2024-03`, Maya `2025`, iOS `21F79`, Android
  `UP1A.231005.007`, …) needs non-power-of-two encodings and
  pure-alphanumeric fallbacks. Each is its own structural decision and is
  out of scope for this rewrite.

---

→ [SPEC.md](./SPEC.md) — desired-state specification
→ [RATIONALE.md](./RATIONALE.md) — design history, prior art, open questions
