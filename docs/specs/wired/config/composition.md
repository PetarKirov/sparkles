---
status: draft
owner: sparkles:wired
reviewed: 2026-10-05
---

# Configuration composition — Collections and submodules

## Abstract

`sparkles:wired` combines selected collection definitions without losing their
supplied-member intent or their sources. Lists preserve an explicit ordering,
maps resolve overlapping entries through typed policies, and submodules resolve
members independently. The resulting snapshot explains both whole submitted
values and the branches that produced effective values or failures. Capturing
supplied values into private storage, finite schemas, and explicit content and
record budgets keep composition separate from file discovery, lazy evaluation,
and application-specific merge engines.

## Introduction

Several sources can extend a search path or contribute entries to a configuration
map. A list requires meaningful order, while a map requires a rule for overlapping
keys. A nested object can omit one member and explicitly set another to its default.
These are different statements of intent, even when ordinary decoding produces
the same initialized D value.

Priority selection alone does not settle those cases. A whole map excluded at its
parent option cannot contribute a stronger child definition afterward. A selected
map can contain a [configuration submodule](../../../glossary.md#config-submodule),
whose declared member options resolve independently, and one conflicting member
must not hide successful members elsewhere. Retaining only the combined container
loses both supplied presence and the location of each contribution.

The approach extends the retained-definition model with typed
[definition projections](../../../glossary.md#config-projection): borrowed views
valid during a visit to the live snapshot, located by an original member/key/index
route before effective reordering. Composition resolves those views using the
schema's typed policies, keeps failures addressable, and exposes ordinary D values
only for successfully resolved branches. Declared
[option patterns](../../../glossary.md#config-option-pattern) describe member
addresses with repeated collection segments, distinguishing submodule members
from ordinary collection data. Inspection obtains both from the same snapshot,
without inferring provenance from an effective array index.

The schema is the D aggregate declaration, its field initializers, and policy
attributes. Finite schemas exclude recursive type graphs and reference cycles.
Content budgets count logical value/text bytes, while record budgets count
retained items; exhaustion is a structured failure, not a partial successful
snapshot. Exact units and transitions belong to the contracts below.

This page owns finite, eager collection/submodule resolution in `sparkles:wired`.
It extends the [scalar interface](./scalar-resolution.md), not a second builder or
configuration framework. Custom ownership/conversion hooks, lazy evaluation,
recursive type graphs, keybinding subtree operations, and app source discovery
remain outside this contract. The [inspection contract](./inspection.md) owns
presentation and documentation links; it does not implement composition.

Sections 1–6 specify policies, presence, projections, transitions, and accounting.
[testing.md](./testing.md) owns independent traces and feasibility observations;
[decisions.md](./decisions.md) owns local choices and remaining blockers;
[PLAN.md](./PLAN.md) owns delivery progress. All interfaces named here are proposed,
unimplemented symbols.

## 1. Contract at a glance

1. Priority selects definitions before composition; order never substitutes for it.
2. Supplied-member presence accompanies original typed collection payloads.
3. Excluded parent definitions cannot re-enter through child overrides.
4. A projection retains its parent definition and original branch identity.
5. Failed parents have no effective native value; successful descendants remain inspectable.
6. Capture owns the complete supported value graph; transfer does not clone it.
7. Synthesized values and derived records have explicit budgets and rollback rules.

Normative keywords follow [BCP 14](https://www.rfc-editor.org/info/bcp14).
WCFG38–WCFG51 extend existing IDs. WCFG8–WCFG16 remain authoritative for the
selection, merge, ordering, and provenance laws; this page fixes their concrete
collection interface and resource model.

## 2. Typed policies and supported payloads

**WCFG38: Composition policy declarations.** The schema **must** express policies
through typed field UDAs: `ConfigMerge!Atomic`, `ConfigMerge!(ListOf!P)`,
`ConfigMerge!(AttrsOf!P)`, `ConfigMerge!Lines`, `ConfigMerge!Submodule`, and
`ConfigMerge!(NullOr!P)`. It **must** reject incompatible value/policy pairs,
duplicate annotations, and conflicts with an explicit type-level section marker
at compilation, naming the original member and schema type.

These spellings refine the illustrative policy names in [SPEC §4](./SPEC.md#_4-selection-and-uda-directed-composition).
They do not denote shipped code. Unannotated collections remain atomic. Ownership
walking through an atomic container is structural capture, not option composition.
Section markers apply at option/submodule policy sites. Ownership-only descent
inside an atomic container does not reinterpret nested members as options or
apply their composition/check UDAs; a `Submodule` policy admits those declarations.

| Policy      | Supported shape                                                                           | Equal-priority behavior                                                                                                                     |
| ----------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `Atomic`    | C1 scalar, finite plain struct, dynamic/static array, or map with supported payload graph | Multiple selected definitions conflict; a sole value is captured as one option                                                              |
| `ListOf!P`  | Dynamic array of values compatible with `P`                                               | Concatenate definitions in WCFG11 order; each element is a separate instance of `P`, not merged with its neighbors                          |
| `AttrsOf!P` | Map with string or supported integral-enum keys and values compatible with `P`            | Select at the map option, union eligible keys, then resolve each common key through `P`                                                     |
| `Lines`     | String                                                                                    | Ordered verbatim join with one separating newline                                                                                           |
| `Submodule` | Finite plain struct with compatible member policies                                       | Resolve supplied child definitions independently with section-priority inheritance                                                          |
| `NullOr!P`  | One `Nullable!V` wrapper with `V` compatible with `P`                                     | A sole selected null resolves null; multiple selected definitions containing any null conflict; all non-null selections resolve through `P` |

Supported payload graphs contain C1 primitives/strings, those containers, supported
nullable wrappers, and finite plain structs. A plain struct has only supported
value fields and no user-defined ownership, copy, assignment, or destruction
semantics. Methods and descriptive UDAs do not themselves introduce ownership.
Pointers, classes, arbitrary ranges, `Optional`/`Ternary`, immediate nested-null-aware
wrappers, cyclic type graphs, and custom wire conversion/ownership remain excluded.
A fixed-length array is atomic data, never a variable-length `ListOf` result.

**WCFG39: Presence through collections.** `ConfigInput!T` and its owned capsule
**must** retain a typed, schema-derived presence projection alongside original
payloads for submodules inside lists, maps, or nullable values. Typed full-value
construction **must** mark all relevant members supplied; sparse construction and
JSON decoding **must** preserve explicit member presence. Ignored native payload
fields **must not** be copied, validated, or reported as supplied values.

A collection slot has `supplied`, original typed `value`, and generated `presence`.
The presence shape follows source array positions, canonical typed map keys, and
original struct members. It is not a second user declaration of fields. A full
value helper constructs that shape; a sparse helper accepts an explicit compatible
shape. Missing or extra presence/metadata entries, incompatible shapes, and an
explicit override for an absent member are admission errors. Section-wide
priority on an absent section remains valid and inert under WCFG37.

`DefinitionMetadata!T` preserves root priority/order/local-ID/location overrides.
Within a collection submodule, generated branch metadata permits priority, order,
location, and section inheritance, but not a new source or independently submitted
local ID. The containing root definition supplies that identity. Distinct root
local IDs already permit one source to submit several independently identified
maps/lists. Branch metadata cannot select a child of an excluded root definition.

For nullable container payloads, wrapper nullness and backing-storage nullness
remain distinct typed states. Plain JSON arrays/maps reject JSON null; `NullOr`
uses original nullable decoding. JSON empty arrays/maps preserve logical emptiness,
not an assertion about their backing allocation. Typed capture and `copyConfig`
preserve the supplied native null-versus-non-null-empty state where applicable.

## 3. Canonical scope and native decoding

**WCFG40: Original-site collection decoding.** The JSON input adapter **must**
enumerate original object occurrences before materializing maps or assigning
struct fields, reject duplicate canonical supplied members/typed keys, and carry
the original enclosing field/type/key/value wire-policy site through recursive
leaf decoding. It **must not** substitute public root-subtree decoding or a
serialize/reparse pass for that site context.

`WireName`, `WireCase`, `WireRepr`, strict unknown-member policy, and optional
present-invalid rejection retain the C1 policy rules. `WireConvert` and optional
`onInvalid: useDefault` remain excluded. Known duplicates fail even if their values
agree or their root definition would lose priority. Explicit unknown-member ignore
can skip unknown struct members, but cannot suppress duplicate known members or
map keys. String and enum keys use the original resolved key policy; canonical
wire spellings are byte-compared, not ordered by native AA iteration.

The shipped arena preserves duplicate occurrences and typed decoding can overwrite
them. Its public `fromJSON!V(JsonValue)` starts at `V`'s root policy, while the
native context-aware decoder is private. C1/C2 therefore need an internal original
schema-site decoder seam, with field-site dispatch and converter exclusion checked
before use. This is an implementation prerequisite, not an available public API.

**WCFG41: Key-collision timing.** Schema admission **must** prove canonical
key-spelling injectivity over distinct valid typed keys at each original policy
site: identity spelling for strings and an exhaustive original-policy enum-domain
check. A noninjective enum-key schema **must** fail compilation before creating
any builder, even if prospective definitions are singleton maps or one would lose
priority. Aliases equal as typed keys are one equivalence class, not distinct keys.

Within a submitted map, the input adapter **must** reject two occurrences decoding
to the same typed key before AA assignment. Across different accepted definitions,
equal typed keys are normal merge targets, not duplicate submissions. Sharing a
wire spelling **must not** merge distinct typed keys; schema admission has already
excluded that ambiguity independently of priorities and submitted contents.

A failure identifies the root option, supplied key spellings/locations when
available, and original key policy. No typed AA assignment may erase the evidence
before that check. Enum schema aliases denote the same typed key and require the
same duplicate detection; undeclared enum keys fail domain admission.

### Patterns and branch locators

A declared option pattern has original member segments plus typed repeated
list/map segments. Its canonical text uses `[<index>]` and `[<key>]`, which are
not accepted runtime property-address syntax. For example,
`plugins[<index>].enabled` describes repeated declared submodule members; actual
instances use `plugins[0].enabled`. A literal map key `<key>` uses a quoted runtime
segment and cannot become a pattern by string substitution.

**WCFG42: Typed branch identity.** The snapshot **must** distinguish declared
option patterns, canonical active addresses, and original
[source branch locators](../../../glossary.md#config-branch-locator).
A source projection **must** identify `(parent DefinitionRef, original locator)`;
its identity **must not** depend on an effective concatenated index. Pattern
resolution and branch lookup **must** use the shared schema/address vocabulary,
with runtime paths as values, not one template instantiation per path.

Direct submodule leaves and repeated submodule member leaves are declared options.
Plain array elements and atomic/map value data are inspection branches, not
independent declared options. `visitOption`/report exact-option selection accepts
actual instances of declared patterns; data-only requests identify their owning
option. Parent definition inspection retains the complete submitted payload and
presence, including branches absent from the effective result.

## 4. Resolution and provenance

**WCFG43: Parent selection before child resolution.** An `AttrsOf` or `ListOf`
option **must** select its root definitions before deriving eligible branch
inputs. Child priority overrides **must** affect only descendants of eligible
roots. Overridden parents remain inspectable, with an enclosing-scope override
reason on their projected children; a stronger child priority cannot resurrect
an excluded map/list.

Each list element is resolved from its one owning source occurrence plus its
submodule defaults; elements from different roots are never paired by index.
Maps union eligible keys, then resolve overlapping entries through the value
policy. `Lines` and list order follow WCFG11 exactly. Null backing containers
have no entries; they do not mean an unset definition or a nullable null wrapper.

A sole selected container preserves its native null/empty state when no branch
normalization is required. A merge of two or more selected lists/maps **must**
produce a non-null normalized container even when it has zero entries; conflicting
nullable wrapper nulls are handled before this rule. A single sparse submodule
container requiring default/member normalization uses the same non-null result
rule. This defines one observable state rather than depending on `~`, `.dup`, or
AA allocation accidents.

**WCFG44: Submodule defaults.** Direct sections **must** retain C1's defaults from
the initialized enclosing subject. Newly introduced list/map submodule instances,
and non-null submodules under a `NullOr` site without a selected built-in payload,
**must** derive member defaults from the underlying declared struct initializer,
unwrapping nullable policy layers by type rather than reading a null wrapper's
payload. They **must not** inherit an excluded lower-priority container/wrapper
entry. A selected non-null built-in container or wrapper member already represents
its built-in default and **must not** receive a duplicate equal-priority initializer.
Selected null wrappers **must not** instantiate child branches or fallback
definitions. Prototype validity is checked by type even when the enclosing
initialized wrapper is null.

Generated fallback definitions use the reserved built-in source and creation's
built-in priority/order. Their identity combines the declared option pattern,
actual instance locator, and reserved initializer identity, with a tagged generated
kind distinct from submitted root identities. They count against definition/payload
budgets during resolution. Prototype primitive-domain validity is checked at
creation; selected-value checks run only after branch selection/composition.

**WCFG45: Checks and complete branch failures.** Composition **must** resolve all
eligible branches before applying a container's `ConfigCheck` to its merged native
candidate. Failed descendants **must** suppress that ancestor check, and **must**
leave the ancestor without an effective native value. Successfully resolved
siblings **must** remain inspectable. A completed merge rejected by its own check
**must** report `invalidMergedValue` with the original check code/detail and all
selected contributor references.

Scalar atomic statuses/dispositions retain C1 meanings. A selected nonatomic root
definition has disposition `selected`; its branch projections independently expose
`overridden`, `contributing`, `conflicting`, or `invalid`. The root cannot truthfully
be assigned one child's disposition when different children have different outcomes.
Parents with failed descendants expose `unresolvedChildren` and canonical failed
branch references. No failure is repaired by a losing definition or fabricated
complete configuration.

**WCFG46: Inspectable projections.** `visitBranch`, `visitBranchDefinitions`, and
`visitBranches` **must** provide scope-bound typed views of original/present and
effective branch values, selected priorities, projection/contributor references,
source locations, declared patterns, and failures. Parent `visitDefinition` **must**
continue to expose the original root payload and presence; it **must not** replace
it with a filtered or merged container.

These proposed methods extend the same snapshot owner and checked-handle rules,
not another retained UI tree. A projection view borrows its parent storage;
`ContributionRef` is an owner-checked opaque reference to retained projection
metadata. Branch enumeration uses struct declaration order, effective list order,
and canonical map-key byte order. Semantic failure addresses use canonical byte
order, independent of that presentation order.

## 5. Ownership, operations, and rollback

**WCFG47: Supported-graph capture.** Borrowed capture and `copyConfig` **must**
recursively own supported arrays, maps, keys, strings, and plain struct fields,
including submodule presence/metadata. Capturing only an outer slice/AA or owning
one enclosing struct **must not** be treated as deep capture. Later caller changes
or destruction **must not** affect retained data or an independently copied config.
Creation captures supported mutable initializer graphs under the same ownership
law; borrowing a shared AA/array initializer is not private built-in storage.

Internal immutable sharing is permitted only when lifetime and read-only isolation
are guaranteed; it does not change logical charges. Mutable pointer alias identity
is not a configuration value contract. Owned-input submission and builder/snapshot
transfer retain C1's no-hidden-clone guarantees. Creating a synthesized outer list,
map, or line buffer may allocate; it does not justify cloning already owned nested
payload graphs. Independent mutable `copyConfig` remains an explicit deep-copy
operation.

**WCFG48: Composition rollback.** Invalid metadata/domain, duplicate identity,
spelling collisions, overflow, limit exhaustion, or detectable allocation failure
**must** preserve the collecting builder and rejected owned input as in C1.
Resolution **must** preflight/retain every generated default, branch record,
contribution, normalized candidate, and semantic diagnostic before publishing its
complete snapshot; operational failure **must** publish none of that partial result.

`setLimits` remains the recovery operation. Immutable source identity transfers
with the retained set. An internal failing-allocator seam exercises source capture,
synthesized containers, fallback defaults, canonical key/path storage, diagnostics,
and copying. It does not change production logic under `version(unittest)`.

## 6. Collection accounting and gates

C1 defaults for sources, definitions, payload bytes, options, and depth remain in
force. `maxOptions` counts declared non-section option patterns, including a
composing root collection and each declared repeated submodule member pattern,
not the number of runtime keys or array positions. For `tools: AttrsOf!Submodule`
whose value has `width` and `enabled`, it counts `tools` and both repeated member
patterns once. Root and generated fallback definitions share `maxDefinitions`.

**WCFG49: Additional record limits.** `ConfigLimits` **must** add positive
`uint` limits `maxValueNodes = 262_144`, `maxResolvedRecords = 65_536`, and
`maxContributions = 262_144`. Exact equality **must** fit; widened arithmetic and
failure precedence **must** follow WCFG34. These defaults are local headroom policy,
not a claim about arbitrary document sizes or RSS.

A value node is a scalar, nullable wrapper, container, or plain struct occurrence
visited in retained supplied payloads or a normalized candidate; repeated aliases
count by occurrence. Unsupplied submodule fields do not become source value nodes.
Resolved records include root options and materialized inspection/semantic branches.
A contribution record is one retained `(resolved record, source projection or
generated fallback)` relationship; it is not a copy of the value. Root definition
rows already count as definitions. Depth counts original member, map-key, and
array-index hops; nullable unwrapping adds no hop. Finite schema potential depth is
checked at creation, including empty-container element types.

**WCFG50: Logical collection charges.** Payload accounting **must** recursively
apply the following rules, independent of physical aliasing or allocation layout.
It **must** distinguish original definition charges, normalized-candidate charges,
canonical metadata, and diagnostics rather than silently dropping one category.

- C1 scalar, string, and nullable charges retain WCFG33's rules.
- A dynamic array/map adds one state tag byte plus its supplied element/key/value
  charges; length/capacity fields are record overhead. A fixed array has no state
  tag and charges each element. A plain struct adds no tag and charges present
  source members or all normalized candidate members.
- Every source definition's supplied graph is charged separately. Explicitly null
  and non-null-empty typed containers each charge their state tag, not each other's
  value contents. Map keys are payload, charged per entry, even if interned physically.
- Root `Lines` charges string bytes like C1; its synthesized text includes separating
  newline bytes. A synthesized collection/native candidate is charged once per
  maximal normalized value graph, with nested branch views not charged again.
  Completed candidates rejected by a container check still incur the same logical
  normalization charge; storage optimization does not change admissibility.
- Each distinct retained canonical active/pattern path and key-spelling string is
  charged once by exact bytes. An already charged schema path is not charged again.
  Source branch indices/key references are record metadata, not copied path strings.
- Generated fallback definitions charge their values per instance, just like other
  definitions. A normalized graph is a separate category from its source/fallback
  definitions; sharing does not remove either logical charge.
- Identity/source detail and validation diagnostics retain C1's charges. Presence
  bits, numeric metadata, handles, counters, and container/allocator overhead remain
  excluded; value/record limits bound their count, not their physical byte size.

Detached capsules use these same source graph/path/identity rules, but have no
registered sources, generated defaults, resolved records, normalized candidates,
contribution records, or resolution diagnostics. Their new counters for those
absent categories are zero. Builder admission ignores the capsule's limit policy,
charges only newly retained metadata plus supplied graph, and consumes the capsule
only at successful commit. Native parsing/transient storage cost is separate; no
retained-content limit is advertised as a total decoder-memory or input-size cap.

**WCFG51: Collection evidence.** Acceptance **must** cover the independent traces
in [testing.md](./testing.md), source permutations and retained-definition groupings,
full/sparse presence, null/empty and nested ownership, exact candidate/path/default
accounting, original-site codec/duplicate admission, mixed branch failures, and
real allocator rollback. A finite hand-written clone or an existing owner move
**must not** be reported as conformance of this resolver.

The original-policy codec seam and the projection/presence interfaces require
bounded implementation experiments before C2 relies on them. Custom conversion
and ownership accounting remain a separately gated extension of Q1; Q2 still owns
keybinding-specific semantics. This contract neither implements lazy modules nor
silently substitutes generic map composition for subtree claims or reserved chords.
