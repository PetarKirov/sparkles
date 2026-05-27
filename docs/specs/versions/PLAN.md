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
   Generic `Version!Layout.parse(string, ParseMode)` with width-
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

8. **Real-world preset layouts.**
   Implement `sparkles.versions.presets` covering the part-1
   catalogue of real-world versioning schemes. Adds three new
   layouts (`CalVerYYMMLayout`, `CalVerYYYYMMDDLayout`, `VimLayout`)
   and re-uses `SemVerLayout` + `DmdLayout` for the rest. Includes
   unit tests that parse each catalogued example string (Node.js
   `20.13.1`, Ubuntu `24.04.1`, Vim `9.1.0400`, Dlang `2.079.0`,
   …) and exercise `opCmp`, `toString`, `truncateTo` per layout.
   The per-product mapping, provenance record, and the raw analyst
   source-material catalogue are all in [PRESETS.md](./PRESETS.md).
   Delivers [SPEC §7.5](./SPEC.md#75-real-world-preset-layouts).
   _Dependencies:_ milestones 3, 4. _Optional in the engineering
   sense:_ may ship after milestone 7, since it does not block the
   engine's correctness.

## Out-of-scope deferrals

- **`core.int128.Cent` support.** No 16-byte layouts in the first
  release. Reintroduce when a concrete consumer needs it. Several
  part-2 catalogue schemes (Windows, Chrome, .NET Assemblies, Java,
  Office, Safari, Unreal) would need this — see
  [PRESETS.md §5](./PRESETS.md#5-deferred-from-this-module).
- **Pseudo-SemVer with hyphenless prerelease.** Go (`go1.22rc1`),
  Python (`3.13.0a1`), Unity (`2023.2.1f1`), OpenSSL legacy
  (`1.1.1w`), OpenSSH (`9.7p1`) all need layout-supplied custom
  tokenisers for the numeric→alphanumeric boundary. Tracked as a
  follow-up milestone in
  [PRESETS.md §5](./PRESETS.md#5-deferred-from-this-module).
- **Part-2 catalogue schemes** (entries 26–50). Beyond `Cent` and
  hyphenless-prerelease, these schemes need non-power-of-two
  layouts (Eclipse `2024-03`, Maya `2025`), pure-alphanumeric
  fallback (iOS `21F79`, macOS `23F79`, Android `UP1A.231005.007`),
  and epoch-prefix UDAs (Debian `1:1.2.3-4+deb12u1`). Each is its
  own structural decision; see
  [RATIONALE §5](./RATIONALE.md#5-open-questions).
- **`SsoString` for a second consumer.** If `core_cli` or another
  sub-package gains a use case, lift `SsoString` out of
  `sparkles.versions` into `sparkles.core_cli`. Defer until then.
- **Branch rename.** The git branch stays `feat/version` (singular)
  through this work; renaming a checked-out branch mid-stream is
  needless churn.

See [RATIONALE §5](./RATIONALE.md#5-open-questions) for unresolved
design questions that may inform later milestones.
