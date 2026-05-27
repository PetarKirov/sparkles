# `sparkles:versions` — Delivery Plan

_Audience: contributors implementing the library. This is a milestone
outline; for the desired-state specification, see
[SPEC.md](./SPEC.md). For design history and open questions, see
[RATIONALE.md](./RATIONALE.md)._

## Context

`sparkles:versions` is a DbI versioning library replacing the existing
`sparkles:semver` sub-package. The redesign is driven by the need to
support multiple versioning schemes from a single engine; the bit-
packed core is a derived efficiency, not the primary motivator. See
[SPEC §1](./SPEC.md#1-overview) for the library's identity and
[RATIONALE §1](./RATIONALE.md#1-why-this-redesign) for the motivation
in full.

## Milestones

Numbered for sequencing only; each milestone's _outcome_ is the
relevant SPEC sections compiling, passing their unit tests, and
documented per [AGENTS.md](../../../AGENTS.md).

1. **DbI vocabulary + engine scaffolding.**
   Implement `Component`, `InternalFlag`, `GetCoreType`, and the
   `Version(Layout)` engine struct with its CTFE validation.
   Delivers [SPEC §3](./SPEC.md#3-dbi-vocabulary) and
   [SPEC §4](./SPEC.md#4-the-versionlayout-engine).
   _Dependencies:_ none.

2. **Operations.**
   `opCmp`, `toString`, `truncateTo!"name"()`. Engine-only at this
   stage; concrete layouts arrive in milestone 3.
   Delivers [SPEC §6](./SPEC.md#6-operations).
   _Dependencies:_ milestone 1.

3. **Concrete layouts.**
   `SemVerLayout`, `DmdLayout`, `DmdOptimized`, `TinyLayout` with the
   per-layout `toString` / `parse` hooks the engine requires.
   Delivers [SPEC §7](./SPEC.md#7-concrete-layouts).
   _Dependencies:_ milestones 1, 2.

4. **Parser.**
   Generic `Version!Layout.parse(string, SemVerParseMode)` with width-
   aware numeric reading, layout-supplied custom parsers, and the
   existing `Expected`-based error API.
   Delivers [SPEC §8](./SPEC.md#8-parser).
   _Dependencies:_ milestones 1, 3.

5. **Migration from `sparkles:semver`.**
   Move source from `libs/semver/src/sparkles/semver/` to
   `libs/versions/src/sparkles/versions/`. Update sub-package SDL,
   bump dub version to `0.3.0`. Remove the old `sparkles:semver`
   sub-package outright; downstream callers update `dependency` and
   `import` lines in a single step.
   Delivers [SPEC §2](./SPEC.md#2-package-and-module-layout) and
   [SPEC §10](./SPEC.md#10-public-api-surface).
   _Dependencies:_ milestones 1–4.

6. **(Optional) SSO string optimisation.**
   Add `SsoString` and swap the baseline `string` slots on
   `SemVerLayout` and `DmdLayout` for it. The engine, parser, and
   `opCmp` are unchanged — the slot interface is satisfied by both
   `string` and `SsoString`.
   Delivers [SPEC §9](./SPEC.md#9-optional-sso-string).
   _Dependencies:_ milestones 3, 4.
   _Optional in the engineering sense:_ may ship after milestone 7.

7. **Tests and docs.**
   - Per-public-function `@(name) @safe pure nothrow @nogc` unit
     tests per AGENTS.md.
   - Layout-coverage tests: `TinyLayout` exercising the void-hook
     path; `SemVerLayout` vs `DmdLayout` proving the
     same-storage-different-format DbI demonstration; `DmdOptimized`
     round-tripping `2.111.0` / `beta.N` / `rc.M` and rejecting
     `alpha.1` (reserved phase code); a one-component `EvilLayout`
     proving the degenerate baseline.
   - `README.md` runnable examples per layout, verified by
     `nix run .#ci -- --verify`.
   - DDoc per `docs/guidelines/ddoc.md`.
     _Dependencies:_ all earlier milestones whose surface area the
     tests cover (typically 1–5).

## Out-of-scope deferrals

- **`core.int128.Cent` support.** No 16-byte layouts in the first
  release. Reintroduce when a concrete consumer needs it.
- **`SsoString` for a second consumer.** If `core_cli` or another
  sub-package gains a use case, lift `SsoString` out of
  `sparkles.versions` into `sparkles.core_cli`. Defer until then.
- **Branch rename.** The git branch stays `feat/version` (singular)
  through this work; renaming a checked-out branch mid-stream is
  needless churn.

See [RATIONALE §5](./RATIONALE.md#5-open-questions) for unresolved
design questions that may inform later milestones.
