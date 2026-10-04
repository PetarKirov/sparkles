---
status: draft
owner: sparkles:wired
reviewed: 2026-10-04
---

# `sparkles.wired.config` — Oracles and evidence

This page owns the verification strategy and evidence ledger for the
[resolver](./SPEC.md) and [inspection](./inspection.md). Test and driver names are
proposed until the ledger cites their actual execution. Publication checks do not
certify resolution, ownership, rendering, or app behavior.

## 1. First-slice oracle

The oracle is a manually calculated table over identified definitions, not the
production merge routine. A small reference model enumerates each option's
submitted definitions, finds its minimum priority, and either selects the sole
atomic definition or records the exact conflict set. It cannot call production
selection, merge, or provenance helpers to compute expected answers.

| Input definitions for `viewer.tabWidth`                    | Expected result                                            |
| ---------------------------------------------------------- | ---------------------------------------------------------- |
| built-in `(4, 1500)` only                                  | value 4; built-in contributes                              |
| built-in `(4, 1500)`, user `(8, 1000)`                     | value 8; built-in overridden                               |
| built-in `(4, 1500)`, user `(8, 1000)`, project `(4, 500)` | value 4; project contributes despite equality with default |
| user `(8, 1000)`, project `(4, 1000)`                      | conflict; both references retained; no effective value     |
| user `(4, 1000)`, project `(4, 1000)`                      | conflict under WCFG10's local policy                       |
| user absent, project explicitly zero at 500                | value 0; no user definition                                |

Each row is evaluated under every source-submission permutation. For conflicts,
compare canonical identities, not incidental diagnostic prose. Known-bad models
that choose the last writer, choose the highest numerical priority, or deduplicate
equal scalar values must fail these fixtures.

First-slice boundary cases include priorities 0 and `uint.max`, order
`int.min`/`int.max`, empty/non-null and null strings, repeated identities, nested
field initializers differing from a section type's initializer, and failed
submission with state unchanged. The default priority 1500 is stimulus metadata,
not a hidden oracle assumption.

For a positive-width validation policy applied after selection, submit a decodable
user value 0 at priority 1000 and project value 8 at priority 500. Expected: value
8 succeeds; user 0 remains retained as overridden, without selected-value
validation. Reverse those priorities: selected 0 produces a structured validation
failure with its option/source, no complete configuration, and retained project
8 marked overridden. Decode-time validity remains a separate admission condition.
A known-bad model validating every retained value must fail the first case.

### Presence and ownership

Use a schema with true/zero/string defaults and decode empty and explicit-at-default
sparse documents. For nullable payloads, exercise absence, explicit null, and
explicit value independently; if the sparse representation collapses any pair,
nullable support is blocked until presence is repaired.

Snapshot lifetime checks submit owned or borrowed string/list/map storage through
the declared forms, mutate the original, end the decode buffer lifetime, and
inspect every retained definition afterward. Instrument payload ownership to
reject double destruction and retained dangling references. This is stronger than
copying one struct containing aliased mutable slices.

## 2. Composition traces

### Lists and lines

With no external definitions, a `listOf` option initialized to `["bundle"]`
resolves to that list with its built-in definition contributing. An `attrsOf`
option initialized to `{a: 1}` likewise resolves to that map with built-in
contributors at its keys. Repeat with explicitly empty initializers to ensure
composed defaults are retained even when the resulting collection is empty.

Definitions of `grammarPaths`:

```text
built-in: priority=1500, order=0,   value=["bundle"]
user:     priority=1000, order=20,  value=["user-a", "user-b"]
project:  priority=500,  order=10,  value=["project"]
```

Expected: `["project"]`; both other definitions remain overridden. Then assign
all three priority 1000: expected `["bundle", "project", "user-a", "user-b"]`.
Changing arrival order does not change that result. Setting orders equal uses
stable source identity and source-local identity as the tie break; the fixture
states those identities explicitly.

For `lines`, manually derive `"a" + "\n" + "" + "\n" + "b\n"` as
`"a\n\nb\n"`. Verify empty definitions, embedded newline preservation, and no
extra trailing newline. Lists preserve duplicate elements; they are not sets.

### Map selection and key recursion

At map option `tools`, user defines `{a: 1, b: 2}` at priority 1000 and project
defines `{a: 3}` at 500. Expected: `{a: 3}`; `b` is not inherited from the losing
map. At equal priority 1000, scalar-valued maps conflict at `tools.a`, while
`tools.b` resolves to 2. A map whose value policy is `listOf` concatenates the
selected lists for a common key in declared order instead of conflicting.

Exercise quoted keys containing dots, brackets, quotes, backslashes, non-ASCII,
and the empty string; canonical wire-key collisions must fail. Map enumeration
order must not change results or report rows.

### Sections and defaults

For a section with child options `viewer.tabWidth` and `viewer.lineNumbers`, user
sets tab width at 1000; project sets line numbers at 500. Each child resolves
independently; a missing child in a stronger source erases nothing. A section-wide
priority override is inherited unless a supplied child has an explicit override.

Use a containing field initialized to `Viewer(tabWidth: 8)` while `Viewer.init`
has tab width 4. The built-in definition is 8. This catches accidental default
generation from the nested type instead of the initialized subject.

### Algebra oracle

Enumerate small identified definition sets with up to three sources, two priorities,
two keys, and two values. Compare all submission permutations and groupings that
retain original metadata. Check successful results and canonical conflict sets.
Recursively test only policies claiming commutativity/associativity; list and
`lines` order is checked against the explicit ordering tuple, not against a
false commutativity promise.

## 3. Risk-driven acceptance matrix

| Obligations          | Falsifying scenario / independent observation                                                                                               | Evidence class                                |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| WCFG1–3              | Add one field once; generated defaults/storage follow; unsupported UDA/type fails with option context; resolver imports no host             | Compiler + source review                      |
| WCFG4–6              | Empty vs explicit false/zero/null; enclosing initializer; boundary priority/order; duplicate identity                                       | Model + codec integration                     |
| WCFG7, WCFG17        | Mutate/free caller payload; inspect retained definitions; conflicting snapshot has no full config                                           | Ownership + runtime driver                    |
| WCFG8–10, WCFG14     | Scalar table, winning/overridden validation pair, and all source permutations reject last-writer/high-priority/equality/validate-all models | Exhaustive small model                        |
| WCFG11–13, WCFG15–16 | Hand-derived list/lines/map/section traces; contributor identities and grouped-definition invariance                                        | Model + actual resolver driver                |
| WCFG18–21            | Conflict, validation failure, exhaustion at N-1/N/N+1; caller state unchanged; exhaustion is not complete diagnosis                         | Fault injection + boundary                    |
| WCFG22–23            | Actual app startup/report share loaded values; explicit-at-default CLI; sparse save excludes untouched env/CLI                              | App integration                               |
| WCFG24, WCI12        | Synthetic secret in effective/overridden/conflicting definitions is absent from stdout/stderr; resolution unchanged                         | Security boundary                             |
| WCI1–5               | Three columns, all definitions, exact option selection, changed ancestor closure, filtered conflict still fails                             | Report + CLI integration                      |
| WCI6                 | Run actual command without display/PTY; compare config bytes before/after; diagnostics only on stderr                                       | Native CLI                                    |
| WCI7–9               | Hidden/false-ShowIf fields inspectable but not editable; typed null/string/enum/map values; collection provenance                           | UI + compiler                                 |
| WCI10–11             | Unicode widths, long paths/values, wrapped guide continuations, too-small width, visible incomplete limits                                  | Byte/width oracle + visual smoke              |
| WCI13–15             | Hyperlinks with color disabled; no links with capability disabled; existing docs anchors; wrapped links don't cover borders                 | ANSI state scan + built docs + terminal smoke |

The width oracle strips escape spans and independently measures the chosen Unicode
fixtures' known cell widths; it does not calculate expected layout with the table
renderer. The OSC oracle scans open/close events at padding and cell boundaries.
Fixtures include a colorless hyperlink-capable sink and a color-capable sink with
hyperlinks disabled. Mutations that omit an OSC close or print a raw ESC-containing
source detail must be caught.

Definition records have their own limit tests; value prettyprint cuts do not excuse
dropped definition rows. Sources and values are attacker-controlled terminal
inputs. Use synthetic secrets and URIs, not developer credentials or private paths.

## 4. Actual-consumer gates and limitations

C1/C2 use the real resolver through a throwaway D driver; tests alone are not the
smoke proof. C3 views the actual composed property/table report. C4/C5 launch real
commands with isolated config directories and controlled project/env inputs.
Record compiler, build mode, command, discovered test count, source revision or
explicit dirty-tree snapshot, and output artifact. Missing toolchains, unavailable
terminal link activation, or unrun app paths remain explicit gaps.

Windows/macOS/Android source discovery remains app-owned. A Linux headless report
does not certify those platform loaders. Cross-platform discovery parity is not
claimed by the pure resolver suite. Lazy configurations, cyclic objects, reactive
reloads, and automatic save behavior are outside the first target; evidence for
finite eager resolution cannot certify them.

## 5. Evidence ledger

All implementation requirements are **unverified** until their named acceptance
scenarios run. No tests or implementation modules are delivered by this spec PR.
The entries below are scoped observations, not requirement-conformance claims.

| Record                         | Scope and observation                                                                                                                                              | Result / remaining gap                                                                                                   |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| B1 — source baseline           | Tree based on `d43f88a39191eaaa3c743f02a2b9dd49ef059442`: `wired.overlay` supplies sparse forms and last-origin merge; `wired.config_file` supplies flat reporting | Source observed; no definition retention or priority resolver claimed                                                    |
| B2 — hue baseline              | Before spec authoring, `dub run :hue -- config show --changed` then `apps/hue/build/hue config show`, Linux/LDC debug build                                        | Commands succeeded; flat output and `keys={}` observed. Does not verify this draft's resolver/report                     |
| B3 — terminal/diagram baseline | Read-only source inspection of settings loaders, app dispatch, and diagram grid adapter in the same base tree                                                      | Terminal has headless flat reporting; diagram lacks definition origins/subcommands. Neither app executed for this record |

### Review and publication

The following records cover the documentation-only dirty-tree snapshot based on
`d43f88a39191eaaa3c743f02a2b9dd49ef059442`, reviewed on 2026-10-04. They establish
C0 review/publication evidence only, not implementation acceptance.

- **R1 — opening cold read: fixed.** An independent reader received only the
  front matter, abstract, and introduction of the resolver and inspection pages.
  Its first read requested clarity on final dispositions versus intermediate
  traces, priority versus order, decoding ownership, noninteractive definition
  expansion, redaction enforcement, canonical identity, and combined/conflict
  columns. The openings were revised to state each explicitly. A second
  opening-only read reported no remaining comprehension mismatch. This checks
  comprehension, not algorithm correctness; owner acceptance remains open.
- **R2 — semantic review: fixed.** A separate reviewer found that WCFG5 omitted
  explicit composed-collection defaults and that C1's oracle did not reject
  validation of overridden values. WCFG5 now covers every independently resolved
  option; defaults-only list/map/empty cases and winning-versus-overridden
  validation scenarios were added to the oracle and matrix. The reviewer re-read
  the affected final sections and reported both findings fixed, with no remaining
  blocker there. Q1–Q4 remain scoped implementation prerequisites, not passed gates.
- **P1 — publication checks: passed.** The repository-hook Prettier 3.8.3
  formatter/checker passed for the five spec pages, sidebar, and glossary.
  Separate `dub run :ci` invocations passed `--check-docs-sidebar` (1617 pages),
  `--check-glossary` (70 entries, 109 links), and `--check-spec-evidence`
  (2775 citations across 191 spec files). The initial sidebar attempt failed
  because the new pages were untracked; staging them resolved that prerequisite.
  `yarn exec prettier` was unavailable, so the publication plan uses the existing
  repository formatter hook instead of adding a dependency.
- **P2 — full site build: passed with environment repair.** `yarn docs:build`
  first exhausted Node's 4 GiB heap. A 16 GiB retry encountered the aborted
  build's transient `node_modules/vue` link into a Yarn ZIP path. Removing only
  that generated link and running
  `NODE_OPTIONS=--max-old-space-size=16384 yarn docs:build` completed generation,
  client/server compilation, and page rendering. Syntax-language fallback and
  bundle-size warnings remain visible; no exclusions or check policies changed.
- **P3 — rendered surface: observed.** A Chromium preview opened all five new
  routes, visually checked the resolver and inspection openings, found all five
  sidebar targets, and followed the definition glossary link to its existing
  anchor. Generated resolver heading IDs matched the glossary authority links.
  This verifies published document navigation, not the proposed config commands.
