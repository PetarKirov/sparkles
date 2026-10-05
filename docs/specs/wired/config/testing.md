---
status: draft
owner: sparkles:wired
reviewed: 2026-10-05
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

For `enum Mode : int { enabled = 1 }`, a supported schema with its enum field
initialized to `cast(Mode) 9` must fail builder creation with `invalidValue` naming
that option and publish no builder. Initializing it to `Mode.enabled` succeeds
under sufficient limits. Separately, creation accepts domain-valid int default 0
with a positive-width `ConfigCheck`: resolving without stronger input returns
`invalidSelectedValue`, while a stronger valid width 8 overrides the default and
resolves successfully. This separates built-in domain admission from selected
validation and rejects a model that allows invalid defaults to be rescued later.

### Presence and ownership

Use separate `DefinitionSlot!V` presence and original-policy payload decoding.
Fixtures must distinguish absence, explicit-at-default false/zero/empty values,
explicit nullable null, and explicit nullable value. A renamed field must decode
under its wire name while preserving its D-member option address; metadata on an
absent field is rejected. The existing sparse transform is not this adapter.

Snapshot lifetime checks submit borrowed and owned scalar/string storage through
the specified forms, mutate the original, destroy the parsed document/capsule,
and inspect every retained definition afterward. Count ownership events to reject
double destruction and ensure a rejected owned submission retains its capsule.
Require the move-only and scope-escape negative compile probes against the actual
public interface. Collection lifetime cases belong to C2.

### Section metadata oracle

For marked section `viewer`, source default priority 1000, supplied `width=8`,
absent `enabled`, and section priority override 500, only the submitted
`viewer.width` definition receives priority 500. No source definition is created
for `viewer.enabled`; its built-in remains present. An explicit width priority
250 wins over the section override. An explicitly supplied priority override on
absent `enabled` rejects the submission, but inherited section priority does not.

With nested `viewer.advanced.zoom`, an outer override 500 and nearest section
override 300 give supplied zoom priority 300; an explicit zoom override 250 wins.
A priority override on a wholly absent or empty section is accepted with zero
submitted definitions. A section child named `priority` uses its distinct
`members.priority` metadata node, without colliding with the section's priority.
Repeat borrowed, captured/owned, and decoded input forms. These priority integers
change neither option identity nor payload-byte charges.

### Operation and exact-accounting oracle

Detached capture/decode of supplied int `width=8`, with no metadata overrides,
charges path 5 plus payload 4: limit 8 rejects, limit 9 accepts. Explicit local ID
`value` adds 5: limit 13 rejects, 14 accepts. An empty input charges path 5 only,
zero sources and definitions, one option and depth 1. It must not invent built-ins
or materialize omitted source metadata. Capture and JSON decoding have identical
boundary results. After transfer, the capsule is consumed and builder admission
uses its own limit; paths already present in the builder are not charged again.

For schema `struct C { int width = 4; }`, creation charges one source, one option,
one definition, depth 1, and 28 logical bytes: `$builtin` (8), `initializer` (11),
path `width` (5), int payload (4). Register source `u` with detail `file`: 5 bytes
more, total 33. Submit `width=8` with default local ID `value`: 5 identity bytes
and 4 value bytes more, total 42. At byte limit 42 this succeeds exactly; another
definition with local ID `other` would charge 9 more and must fail unchanged.
Reusing `value` must instead fail as a duplicate definition, before budget checks.

Lowering `setLimits` below 42 fails without changing the old policy; increasing
the byte limit to 51 admits the distinct definition. Registering another `u`
fails as duplicate source. Equal source detail with a distinct ID is valid.
Identity lengths 0/1025 fail; lengths 1/1024 pass if other budgets allow them.
Use raw IDs `a`, `aa`, `0x7f`, `0x80`, `0xff` and verify byte equality and order.

Choose a failing positive-width check with code `positive` (8 bytes), empty detail,
and a sole selected width 0. At retained byte count 42 and byte limit 42, resolution
cannot retain that diagnostic: it fails operationally and leaves the builder
collecting. Raise the limit to 50: resolution returns a complete semantic-failure
snapshot and consumes the builder. `copyConfig` fails as `notFullyResolved`;
another `resolve` on the consumed builder fails as `invalidState`.

Move that failed snapshot and inspect `OptionView.diagnostic`: code `positive`,
empty detail, canonical path `width`, winning priority and selected definition/
source handles must remain available after the builder is consumed. Repeat with
detail `must exceed zero` (16 bytes) and enough diagnostic budget; the original
text is retrieved from the moved-to snapshot, not regenerated by running the check.
Its `notFullyResolved` result identifies `width` for the same inspection path.

Resolve a valid snapshot, move it, and use saved owner-bound handles with the
moved-to owner. Wrong-owner/invalid handles must not call the visitor. An escaped
view must fail compilation in safe code; callers must not move/destroy during an
active visitor. Enumerate options in declaration order and sources/definitions in
the explicitly specified byte/priority order, not insertion order.

Save the `SourceRef` returned by registration, move the collecting builder, and
submit through that saved handle on the moved-to builder. Resolve successfully,
destroy both builder wrappers, move the snapshot, then inspect the original source
with the same handle. The moved-from/consumed wrappers reject stateful operations
as `invalidState`. After an operationally failed resolution, an empty submission
through the saved handle succeeds on the still-collecting builder; it commits no
definitions and does not alter the later semantic result.

For successful `copyConfig`, submit dynamically captured ordinary and nullable
strings, including nullable null and ordinary null versus non-null-empty states.
Resolve, copy, then destroy the snapshot and its original capture/document owners
through the real freeing storage adapter. The copied configuration must retain
every exact value/state afterward. This falsifies shallow copying of snapshot-owned
string headers; the oracle does not forbid sharing genuinely static immutable data.

Resolve a single snapshot with schema declaration order `clash`, `bad`, `good`.
Built-ins use priority 1500; source `u` at 1000 supplies clash 11, bad 0, good 8,
and source `p` at 1000 supplies only clash 12. The bad option's positive-width
check rejects 0 with original code/detail. With sufficient diagnostic budget,
the snapshot must expose conflict at clash, invalid-selected-value at bad, and
effective good 8, retaining all seven definitions with their exact dispositions.
`copyConfig` returns `notFullyResolved` with failed addresses `bad`, `clash` in
canonical order rather than schema order. Inspect both failures' source/definition
handles and original validation text. A resolver stopping after its first semantic
failure must fail this oracle even if single-option conflict/check cases pass.

Keep an opaque handle after destroying its snapshot, create another owner, and
verify that the old handle cannot pass the new owner's check even if the allocator
reuses an address. Compare definition identities, not physical handle indices,
across permutation fixtures.

At each allocation site in the real storage seam, inject a detectable failure:
registration, borrowed capture, owned submission, resolution, and `copyConfig`.
Assert the specified ownership and logical counters, not merely any returned error.
This is the production operation under a failing allocator adapter, not a mock
that returns the desired result. Repeat successful transfer paths and verify that
resolution and owned submission do not clone the retained payload graph.

Test `used=7, added=1, limit=8` (success), `8/0/8` (success), `8/1/8`
(`limitExceeded`), and `ulong.max-1` plus 1/2 (success / `arithmeticOverflow` at
limit `ulong.max`). Count limits compare widened totals, so `uint.max+1` is
`limitExceeded`, not a wrapped count. Budgets include overridden/default payloads
and diagnostic text. Test a multi-option batch whose final option exceeds a limit:
none of its definitions commit. Set any configured limit to zero: `invalidLimits`.

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

Ordering fixtures hold priority equal and exercise orders `-10`, `0`, and `10`,
then equal orders with source identities `a`, `aa`, and `b`. Expected ordering is
ascending signed order, then `a` before `aa` before `b`. Repeat with equal source
identity and different source-local identities, and with raw identity bytes
`0x7f`, `0x80`, and `0xff`; unsigned-byte ordering puts them in that order. These
fixtures distinguish descending order, locale comparison, and signed-char bugs.

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

### Nested presence, scope, and default oracle

Use `Entry { int width = 4; bool enabled = true; }` as an `AttrsOf!Submodule`
value. The root built-in map is empty at priority 1500. Source `u` at 1000
supplies `{"k":{"width":8}}`; source `p` at 1000 supplies
`{"k":{"enabled":false}}`. Expected effective `k` is width 8 from `u` and enabled
false from `p`. Generated type-initializer definitions remain overridden.
Root definition rendering must preserve each original sparse body; it must not
claim `u` supplied enabled or `p` supplied width.

Raise `p`'s enclosing map priority to 1100 while giving its enabled child override 0. Expected enabled is built-in true: the losing parent cannot re-enter through
the stronger child. Equal winning parents with different width definitions
conflict at `tools["k"].width`, while a sole enabled definition resolves. The
entry/root expose `unresolvedChildren`, no native effective parent, and every
successful child and conflicting projection remains inspectable. A root check
that would reject a fabricated parent must not replace or hide the child failure.

For a selected built-in map initialized with `k.width = 8`, do not synthesize a
second equal-priority width 4 definition. For a stronger sparse external `k`
definition omitting width, derive width 4 from `Entry.init`, not the excluded
built-in entry's width 8. Repeat direct-section field initialization (width 8)
to distinguish its enclosing-root default rule from introduced dynamic instances.

For a null-initialized `Nullable!Entry` with `NullOr!Submodule`, a stronger supplied
non-null `{}` creates an instance whose width defaults to 4 from underlying
`Entry.init`; it does not read the null wrapper's payload. Repeat as a value of
`AttrsOf!(NullOr!Submodule)`. A selected null wrapper creates no children or fallback
records. A selected non-null built-in wrapper holding width 8 suppresses a duplicate
width 4 initializer; if that wrapper loses to a stronger sparse non-null `{}`,
width 4 applies, not the discarded 8.

For distinct enum keys `A` and `B` whose original key policy maps both to `k`,
two prospective singleton maps `{A:1}` and `{B:2}` cannot bypass key injectivity.
The schema fails compilation before builder creation at equal priorities and
when one prospective map would lose. Enum aliases equal as typed keys are not
distinct keys; duplicate occurrences within one document still fail before
AA assignment, while equal typed keys across separate accepted definitions are
the intended merge target.

List elements from different root definitions remain separate occurrences; a
source original index 0 can become effective index 2 without changing its parent
definition/original locator. Pattern `plugins[<index>].enabled` resolves actual
member instances, while a plain atomic element `paths[0]` is not an independent
declared option. Literal key `<key>` must never be mistaken for a map pattern.

### Container state, nullable policy, and ownership oracle

Atomic sole null-backed, non-null-empty, and nonempty containers preserve their
typed state through capture, ownership moves and independent copying. A merge of
two empty lists/maps produces the specified non-null normalized empty state;
it must not depend on `.dup` or AA iteration. `NullOr` distinguishes missing input,
selected null wrapper, present wrapper with null backing, and supplied non-null
empty payload. Two selected definitions containing any wrapper null conflict;
two selected non-null lists merge through `ListOf`.

Mutate nested caller array elements, map values, mutable struct fields, and map
membership after borrowed capture. Destroy caller/document/capsule owners and
inspect retained source payload/presence, then copy the successful config and
destroy its snapshot. Copied values stay exact and mutable independently of both
snapshot and another copy. Include non-null-empty arrays/maps; an outer `.dup`
model must fail the ownership and state cases. Generated fallback/default storage
must obey the same independence as ordinary source payloads.

### Collection accounting oracle

For one `paths: ListOf!Atomic` field initialized to a null-backed empty array,
creation charges `$builtin` 8, `initializer` 11, path 5, and container tag 1:
25 bytes. Register `u` with detail `file`: total 30. Submit `["a","bb"]` at
priority 1000/order 0: graph 4 plus first local ID `value` 5, total 39.
Register `p` with detail `repo`: total 44. Submit `["ccc"]` at 1000/order 10:
graph 4, with `value` already interned, total 48.

Resolution produces `["a","bb","ccc"]`. Its normalized graph adds tag 1 plus six
string bytes, total 55; three new active paths `paths[0]`, `paths[1]`, `paths[2]`
add eight bytes each, total 79. Counts are three sources, three root definitions,
one declared option pattern, ten value nodes (six source plus four normalized),
four resolved records (root plus three elements), and five contribution
relationships (two at root, one at each element). Limits 78/79 and count limits
one below/equal/one above must distinguish unchanged operational failure from a
complete snapshot. The detached first input charges path 5 plus source graph 4,
not built-ins, normalized values or runtime paths.

For `tools: AttrsOf!Submodule` with `Entry { int width = 4; }`, declared paths
are `tools` (5) and `tools[<key>].width` (18). Empty built-in root charges tag 1
plus both paths and built-in identities: 43 bytes. Register `u/file`: 48.
Supply `{"k":{}}`: map tag 1/key 1, first `value` identity 5 and canonical key
spelling 1, total 56. Resolution adds fallback int 4 and active paths
`tools["k"]` (10), `tools["k"].width` (16): 86. Normalized map/key/struct/width
graph adds 6: 92. Empty child presence must not charge a supplied width 4.
There are two sources, three definitions including the generated fallback, two
declared patterns, nine source/default/normalized value nodes, three resolved
records, and three contribution relationships. Nested views do not double-charge
the normalized parent graph.

Exercise `Lines` newline-byte charges, fixed arrays without a container-state tag,
nullable wrapper tags, ignored submodule fields with large unowned payloads,
shared source-key/identity/path text roles, failed merged checks, and multiple
independently failing branches. Inject allocation failure at generated defaults,
canonical paths/spellings, projections, normalized graphs and diagnostic storage.
Operational failure must not consume any owner or publish partial records.

### Report seam and privacy oracle

At flat hard floor 47, all content widths meet `[12,13,12]`; at 46 the proposed
checked layout returns `widthTooSmall` before any stdout byte. Repeat a nested
row with its computed guide width and a taller adjacent source cell. Guides
remain outside links, continue on blank physical lines, and emit the branch
marker once per logical row.
Known widths 46 and zero refuse before stdout for redirected sinks too; a host
marking width unknown selects 120. Geometry uses the base-owned cell extent and
shared style/source plans, not physical units or a report-owned wrapping solver.

Direct/nested/map-key enums must print original wire spelling `"turbo"`, not
`Mode.fastPath`, in inline and multiline paths. Nullable wrapper null prints
`null`, present-null backing prints `value(null)`, and non-null empty containers
remain empty. Supplied-member presence includes explicit-at-default fields and
excludes absent fields. Literal text `...` is not a structured cut.

Exercise exact item/depth/value-byte/source-byte/label-byte boundaries with quote,
UTF-8 and control escaping; no whole omitted suffix is scanned or escaped before
returning a cut. A 16 MiB borrowed source detail must not be copied per row before
its report text cap. Every cut is visible/incomplete; redacted values incur no
formatting walk. A root map not itself sensitive but containing a sensitive
declared child must not leak that child through its parent effective/definition
cell, validator detail, or conflict snippet; non-sensitive child rows remain
independently inspectable.

For the linked label `alpha beta 世界 é` followed by an explicit newline and
`next label`, expected generated table guides/padding/frame/source/value/newline
bytes are all unlinked. Compare visible text as a separate observation, not the
sole oracle. Test accepted URI lengths 506 and rejected 507, actual missing
fragment IDs independently of URI syntax, and output capabilities with hyperlinks
on/color off and hyperlinks off/color on. Snapshot failure remains unfiltered;
mixed incomplete/diagnostic/load/write outcomes obey WCI21's precedence.

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
| WCFG25–27            | Exact supported-type matrix, original field rename/policy, nullable three-state input, byte-ID limits and reserved source                   | Compiler + codec integration                  |
| WCFG28–32            | Operation/state and 28/33/42/50/51-byte traces, failed owned submission, complete semantic failure versus operational rollback              | Actual resolver + fault injection             |
| WCFG33–36            | Default limits, widened/overflow arithmetic, scope/copy rejection, allocator-failure seam, transfer without cloning                         | Boundary + compiler + runtime driver          |
| WCFG37               | Nearest section priority, explicit leaf precedence, absent/empty section, metadata member-name collision, all input forms                   | Metadata + actual resolver                    |
| WCFG38–42            | Policy/type errors, source presence through nullable/list/map, original-site decoding and duplicate keys, exact patterns/locators           | Compiler + codec + actual resolver            |
| WCFG43–46            | Excluded-parent child override, dynamic defaults, selected-built-in suppression, mixed child failures and original root definition views    | Independent model + typed visits              |
| WCFG47–51            | Deep capture/copy, null/empty reconstruction, 25/48/79 and 43/56/92-byte traces, widened counters and allocation-failure rollback           | Ownership + boundary + real storage           |
| WCI16–20             | Supplied/nullable/enum formatting, hard floors/guides, bounded escaped cells, precise structured cuts and nested redaction                  | Typed fixture + width/byte oracle             |
| WCI21–24             | Mixed exit precedence, canonical pattern targets, real missing HTML ID, URI506/507 and mandatory-break link containment                     | CLI + built-docs + ANSI state                 |

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

### Follow-up clarification review

- **R3 — supplied prose/precision review: fixed in this branch.** Timeless
  resolver wording replaces implementation-phase wording; C1 scope remains in
  the delivery plan. WCFG10's local-policy explanation is a labeled rationale,
  WCFG11 explicitly defines ascending signed/unsigned-byte comparison and prefix
  ordering, and WCFG22/WCFG23 are classified as integration-owned obligations
  without renumbering them. Identity representation is resolved with C1 readiness;
  selected-map spelling-collision timing remains a C2 refinement, not an editorial
  change or a claim of NixOS interoperability.

### Scalar readiness feasibility

**Scope:** source revision `53db91dfa334cea9c3109abd7e440c3a84aee832`, plus
throwaway D probe drivers; Linux x86-64, LDC 1.42.0 / DMD frontend 2.112.1, debug
build with assertions live. These are bounded language/codec/schema experiments,
not tests of an implemented configuration resolver.

| Question / experiment                                                            | Observed result                                             | Decision / limitation                                                      |
| -------------------------------------------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------------- |
| Decode `{}` and explicit false/zero/empty into sparse scalar fields              | Absence and supplied values stayed distinct                 | Reuse presence mechanism only where faithful                               |
| Instantiate sparse decoding for a `Nullable!int` field                           | Compilation rejected nested null-aware wrappers             | Use separate presence outside original payload                             |
| Decode original nullable leaf into a boolean-presence slot                       | Missing, supplied null, and supplied 7 stayed distinct      | Original leaf codec can serve the presence adapter                         |
| Decode a `@WireName(\"theme-name\")` field via original schema and via `Mapped`  | Original schema honored rename; mapped sparse field did not | Preserve original field policy; no blind sparse decode                     |
| Decode ordinary string from JSON null                                            | Decode error                                                | Nullable and string payload rules remain distinct                          |
| Enclosing section field initialized to width 8, nested type initialized to 4     | Enclosing default remained 8                                | Generate defaults from the initialized root                                |
| Capture mutable `abc` with immutable ownership, mutate caller, then move capsule | Captured `abc` unchanged; move preserved payload pointer    | Copy once at borrowed capture; transfer thereafter                         |
| Copy disabled owner or leak scoped text/nullable text under DIP1000              | Negative compile probes rejected all three                  | Feasible building blocks; actual visitor interface remains acceptance gate |
| Sort prefix and high-byte IDs with unsigned comparison                           | `a, aa, 7f, 80, ff`                                         | Raw identity ordering is independent of locale/UTF                         |
| Subtraction-boundary model at N-1/N/N+1 and ulong boundary                       | Exact fit accepted; next addition rejected without wrapping | Supports checked accounting; not production rollback evidence              |

The drivers ran as `dub run --single .c1-probes/<driver>.d --compiler=ldc2`;
the final borrowed-view driver explicitly enabled `-preview=in` and
`-preview=dip1000`. Driver sources were throwaway and removed after recording the
observations. Reproduce the presence experiment with `Sparse` over a nullable
field as a negative instantiation, then a separate `(supplied, Nullable!int)` slot
whose payload is decoded by `fromJSON!(Nullable!int)`. The ownership experiment
uses an `@disable this(this)` wrapper, one `idup`, and `std.algorithm.mutation.move`;
it compares payload pointers before/after the move and mutates the original buffer.
The arithmetic model checks `added <= limit - used`; the production acceptance
oracle additionally distinguishes arithmetic overflow from a representable limit.

For workload sizing, a type-only `FieldNameTuple` walk visited initialized app
subjects, recursed through structs, treated collections as excluded leaf-shaped
fields, summed scalar `sizeof` or string byte lengths, and counted full member-path
bytes and root-relative member hops. This does not claim that whole app schemas
are accepted by the scalar resolver or measure collection payloads/allocator cost.

| Subject         | Leaf-shaped fields | Scalar fields | Excluded collection fields | Scalar default bytes | Path bytes | Depth |
| --------------- | ------------------ | ------------- | -------------------------- | -------------------- | ---------- | ----- |
| HueConfig       | 108                | 98            | 10                         | 607                  | 2169       | 3     |
| TerminalConfig  | 43                 | 35            | 8                          | 195                  | 861        | 4     |
| DiagramSettings | 23                 | 19            | 4                          | 37                   | 527        | 3     |

Five dense scalar sources for the largest measured subject represent 490
definitions and 3035 scalar value bytes, before metadata; this motivates headroom,
not an upper bound on user settings. The default policy and exact accounting are
specified in [scalar-resolution.md](./scalar-resolution.md#_6-limits-and-accounting).

Probe setup failures were preserved as limitations of the attempted harness:
one-line SDL blocks were rejected, single-file recipes disallowed `importPaths`,
and missing imported app objects caused linker errors. Multiline SDL, compiler
import paths, separate `-i=module` flags, and explicit module declarations corrected
the harness. The nested-nullable compilation failure was retained as a genuine
negative codec result, not suppressed. No production behavior or test gate changed.

### C1 readiness review

- **R4 — opening cold read: fixed.** The scalar abstract was qualified to retain
  accepted definitions and copy only successful effective configuration. Both
  introductions now distinguish the library's presence-aware input adapter from
  app-owned decoding policy and typed submission. An opening-only re-read found no
  remaining comprehension mismatch.
- **R5 — ownership/failure and policy/accounting review: fixed.** Two independent
  reviewers identified missing selected-validation diagnostic access and undefined
  detached-capsule charges. The interface now exposes scoped original diagnostics
  through option inspection, and distinguishes 9/14-byte capsules from
  28/33/42/50/51-byte builder/snapshot accounting. The oracles include moved
  diagnostic retrieval, explicit/omitted metadata, empty capsules, transfer-policy
  independence, and stale-owner handles. Both reviewers re-read the repaired
  sections and found no remaining blocker in their assigned C1 scopes. Actual
  resolver lifetime enforcement and allocator rollback remain unverified.
- **P4 — C1 readiness publication: passed.** For the documentation delta over
  `53db91dfa334cea9c3109abd7e440c3a84aee832`, Prettier and editorconfig checks
  passed, sidebar validation checked 1619 pages, glossary validation checked 70
  entries/113 links, and spec-evidence validation resolved 2867 citations across
  193 spec files. The full site build passed with the 16 GiB Node heap. Chromium
  rendered the scalar interface opening and limits table, verified the registered
  sidebar target and heading IDs, followed the root-spec link to the scalar page,
  and opened the feasibility anchor/census. The wrapped root link required a real
  client-rectangle hit point because the browser helper's union-box center hit
  surrounding text; no document or validation policy was changed to hide that
  automation limitation. These are publication results, not resolver conformance.
- **R6 — local C1 continuation review: fixed.** Two read-only reviewers examined
  the branch delta from `origin/main`, based on local commit `5eb2a1f3b`, and the
  repaired documentation snapshot on 2026-10-05. The policy review identified
  missing section-priority metadata and primitive-domain validation at built-in
  creation. WCFG37 now exposes section inheritance with explicit leaf precedence
  and inert absent sections; WCFG28 and the creation outcome reject invalid enum
  initializers before publishing a builder. Independent metadata/default oracles
  cover both cases without rerunning the historical codec probes.
  The lifetime review identified unspecified registered-source handle validity
  across resolution and missing successful-copy/mixed-outcome acceptance cases.
  WCFG29 now transfers retained-set identity through builder and snapshot moves;
  the oracles preserve a registration handle across resolution, inspect independent
  copied strings after freeing owners, and retain all seven definitions in a
  conflict/invalid/resolved snapshot. Both reviewers re-read the repaired sections
  and reported no remaining concrete C1 discrepancy in their assigned scopes.
  Manual accounting still gives capsule totals 9/14 and builder/snapshot totals
  28/33/42/50/51; this is contract review, not implementation conformance.
- **P5 — continuation publication: passed.** The repaired documentation snapshot
  based on `5eb2a1f3b` passed Prettier/editorconfig checks and separate in-tree CI
  sidebar (1619 pages), glossary (70 entries/113 links), and spec-evidence
  (2867 citations/193 spec files) checks. The full
  `NODE_OPTIONS=--max-old-space-size=16384 yarn docs:build` completed generation,
  bundle compilation, and page rendering. Chromium opened the scalar operation
  section, visually checked WCFG37 and its metadata wrapper, verified the sidebar
  target, and opened the section-metadata oracle and fixed-review record. Syntax
  highlighting fallback/bundle-size warnings remain visible; no policy exclusions
  changed. Historical feasibility probes were not rerun; resolver conformance
  remains unverified.

### Collection and inspection feasibility

**Scope:** production-source tree at C1 tip `776389a12`, plus throwaway D drivers;
Linux x86-64, LDC 1.42.0, debug/assertions-live single-file runs. No configuration
resolver, generated capture, or report seam is implemented by these experiments.

| Experiment                                                                                                         | Observed result                                                                                   | Decision / evidence limit                                                                             |
| ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Original nested list/map/struct decode; mutate source text, destroy parsed document, force GC, move `Unique` owner | Exact nested content remained; enclosing/array/tag addresses stayed identical across move         | Native codec/owner primitives are feasible; `Unique` alone is not deep borrowed capture               |
| Finite hand-written recursive capture; mutate caller inner list, tags, AA entry and membership                     | Captured values stayed exact and new caller key did not appear                                    | Demonstrates finite language construction, not generated schema/capture or allocator rollback         |
| Duplicate-preserving arena versus typed map                                                                        | `objectGet("k")` decoded first 1; native typed AA retained later 2                                | Detect canonical duplicates before AA materialization; parser has no duplicate-key policy knob        |
| Field-targeted enum key/value case in enclosing schema versus public subtree root                                  | Whole original schema decoded; public subtree entry failed after losing site policy               | Internal original-site decoder seam is required; no field-policy shortcut claimed                     |
| Empty array/AA native `.dup`                                                                                       | Non-null-empty source became null-backed; null AA `.rehash` remained null                         | Plain clone is insufficient to preserve typed backing state                                           |
| Explicit empty-array storage and finite empty-AA reconstruction                                                    | Null and non-null-empty captures remained distinct                                                | Positive representation primitive only; no config definitions created or production strategy accepted |
| Struct field map initializer with entry width 8                                                                    | Initialized root and `T.init` both retained width 8                                               | The enclosing-map/default-versus-type-default oracle is representable in D                            |
| Existing enum prettyprint versus wired names                                                                       | `Mode.fastPath` versus `turbo`                                                                    | Generic recursive enum policy extension remains required                                              |
| Real table budgets 12, 46, 47, 60                                                                                  | Widest lines 14, 46, 47, 52 respectively                                                          | Shipped soft floors do not prove checked report hard floors; small-width overflow observed            |
| Ordinary and 506-byte OSC URI with soft and mandatory label breaks                                                 | Visible parity true; one linked newline, four linked frame bytes, source/value token flags false  | Label isolation fails despite fitting saved-link state                                                |
| 507-byte URI (513-byte opening)                                                                                    | Saved state inactive; two linked newlines/eight linked frame bytes; source/value token flags true | URI bound and shared mandatory-break repair are distinct requirements                                 |

The collection commands were `dub run --single .c2-probes/collection-ownership.d
--compiler=ldc2`, with separate `empty-storage.d` and `map-default.d` runs under
the same flags. The standalone inspection seam driver used the real
`drawTable`/`TableProps`, `prettyPrint`, `wireNames`, `visibleWidth`, and
`OscLinkState` through ordinary base/UI/wired dependencies, without `-unittest`.
It ran as `dub run --single <inspection-seam-probe.d> --compiler=ldc2`; the driver
path is an experiment artifact, not a shipped repository example.

The independent OSC scanner recorded active state per visible byte. The observed
normal-URI output reopened before `世界 é`, then kept the link open across its
hard newline, padding/borders, and the next line's leading frame, finally closing
after `next label`. The 506-byte URI behaved the same. For URI507, the opening
length 513 exceeded `OscLinkState`'s 512-byte saved buffer, and adjacent source/value
tokens also became linked. Legitimate label spaces and generated padding require
recorded-byte inspection; token/visible-text parity alone is not proof of isolation.

Reproduction criteria and blocked shared seams are in
[inspection §9](./inspection.md#_9-evidence-and-bounded-feasibility-questions)
and Q6/Q7. Probe sources are throwaway and removed after recording evidence.
Historical scalar nested-nullable/Mapped-policy failures were not rerun. No
baseline failure was suppressed, no validation exclusion was expanded, and no
runtime conformance milestone is passed by these primitive experiments.

### Composition and inspection contract review

- **R7 — opening cold read: fixed.** An independent opening-only reader requested
  clarity on private capture/borrow duration, submodules and original routes,
  repeated option patterns, logical byte versus record budgets, finite schemas,
  and the D declaration's role. The openings now state those concepts or link
  their defining glossary entries; a second restricted read reported no remaining
  comprehension discrepancy. Interface details stay in the body.
- **R8 — composition semantics/accounting: fixed.** A separate reviewer found
  missing defaults beneath non-null nullable submodules and a cross-definition
  key-spelling ambiguity. WCFG44 now derives underlying struct prototypes by type,
  instantiates no children for selected nulls, and suppresses duplicate selected
  built-in defaults. WCFG41 rejects a noninjective key schema before builder
  creation, distinguishing equal typed-key merge targets from distinct colliding
  keys regardless of prospective priorities. Worked nullable and singleton-map
  oracles cover both. Re-review found both fixes sound; the two accounting traces
  and stated node/record/contribution counts were independently consistent.
- **R9 — inspection/privacy/layout: reviewed.** Another read-only reviewer checked
  WCI1–24, typed presence/null/enum formatting, bounded cells, hard floors/guides,
  nested metadata-only redaction, diagnostics, exit precedence, pattern manifests,
  and known OSC baseline failures. It found no actionable contradiction in its
  assigned scope. Unimplemented shared seams and actual app-page gates remain
  explicitly blocked, not passed; no production probes/tests were rerun by reviewers.
- **P6 — composition/inspection publication: passed.** On the documentation
  snapshot based on `776389a12`, Prettier/editorconfig passed; separate in-tree CI
  checks validated 1620 sidebar pages, 74 glossary entries/117 links, and 2867
  evidence citations across 194 spec files. The full 16 GiB-heap docs build
  completed source/example generation, bundle compilation and page rendering.
  Chromium visually checked the composition opening and inspection width/
  continuation section, verified the new pattern/glossary links and section IDs,
  and opened the actual collection/inspection evidence anchor. This is document
  publication evidence only; the known native table OSC failure and every
  proposed runtime seam remain unverified for conformance.
- **R10 — fresh-main wrapping ownership: fixed.** After C1 merged, the follow-up
  rebased onto `463008dd6`, whose base wrapping contract owns cell dimensions,
  source/style plans, and checked materialization. Report geometry now uses that
  base-owned cell extent with unknown width separate from known zero. Review found
  WCI10 still implied all redirected output used 120 while WCI18 honored explicit
  widths; both clauses and the oracle now honor known redirected 0/46 as
  `widthTooSmall`, and select 120 only for unknown width. Re-review confirmed the
  code fence, checked conversion, style owner, and table cell/frame exclusions
  agree with WRAP-UNIT3/WRAP-STYLE1. No runtime repair or conformance is claimed.

### C1 scalar implementation

On `feat/wired-config-scalar`, Linux x86-64, both
`dub test :wired --compiler=ldc2 -- -v` and
`dub test :wired --compiler=dmd -- -v` passed **243 tests, zero failures**.
The implementation lives in `sparkles.wired.config.core` and
`sparkles.wired.config.json`; consumer acceptance cases live in
`sparkles.wired.config.acceptance`.

The cases exercise minimum-priority permutations, equal-value conflicts,
section priorities and enclosing initializers, scalar representation boundaries,
explicit null/empty values, overridden enum-domain rejection, selected checks,
mixed semantic outcomes, byte identities, stale handles and owner transfers,
exact capsule/builder accounting, and real allocation-failure rollback during
capture, registration, both submission forms, resolution, and independent copy.
Positive immediate-read controls and negative escaping-slice controls enforce
borrowed string, nullable-string, identity, source-detail, and diagnostic lifetimes
under DIP1000. Opaque scoped value accessors replace payload pointers: immutable
string aliases through pointer indirection did not enforce the required lifetime.

JSON cases retain original renaming/section/unknown-member policy, distinguish
absence from explicit default/null, reject unsupported policies at compile time,
and check duplicate ordering and error locations. Locating an error after 65,536
nested ignored arrays runs with bounded locator storage rather than recursion
through arbitrary input.

`dub run --single libs/wired/examples/scalar-config.d --compiler=ldc2 -b checked`
printed `tabWidth=8`, then reported a priority-1000 conflict with definitions
16 and 8 conflicting and the priority-1500 definition 4 overridden. The driver
also asserts failed full-config copying and unchanged caller input.
`dub add-local .` followed by `dub run :ci -- --verify --files README.md` passed
all 19 examples, including the scalar example's output `8`.

Independent storage/lifetime and decoder reviews found no remaining
evidence-backed defect after repairing scoped access and bounded error location.
These are local implementation results, not CI or C2–C5 delivery claims.
