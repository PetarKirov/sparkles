---
status: draft
owner: sparkles:wired
reviewed: 2026-10-05
---

# Scalar configuration resolution — Interface and ownership

## Abstract

`sparkles:wired` resolves finite scalar configuration schemas into an owned result
that preserves every accepted definition. Submission distinguishes absence from
explicit null, validates identities, and rejects a whole submission when its
resource budget cannot admit it. A move-only builder transfers retained storage
into a read-only snapshot without copying all definitions again. Semantic failures
remain inspectable, while operational failures preserve the builder for retry.
The interface separates borrowed inspection from an independently owned copy of
the successful effective configuration.

## Introduction

A configuration loader can decode a file into temporary storage, then discard that
storage before an application inspects its settings. Retaining references to the
decode buffer would make the report unsafe. Copying a struct does not solve the
problem when its strings or collections still refer to someone else's memory.
The caller also needs to know whether a failed submission changed the accumulated
configuration and whether a conflicting result can be inspected without starting
the application.

Presence is a separate problem from payload lifetime. A missing setting supplies
nothing, while a present nullable setting can deliberately supply null. A derived
nullable overlay cannot stand in for both channels: wired rejects nested
null-aware wrappers, and the existing overlay transform does not preserve every
field's wire-name policy. The input representation must keep presence outside the
original typed payload and decode through that payload's original schema policy.
The library supplies a presence-aware JSON input adapter; hosts choose decoding
policy and may instead submit already typed presence-bearing values.

This interface separates a borrowed input value, an owned input capsule, an
accumulating builder, and a read-only resolution result. Borrowed submission
captures value content once; an owned capsule can transfer that content without a
second copy. Resolution transfers the builder's retained storage only after a
complete result has been constructed. The same result exposes successful options
and located semantic failures, rather than substituting defaults for failed options.

This page owns the scalar/string subset of the
[definition resolver](./SPEC.md), including source identity, schema admission,
submission, snapshot lifetime, and resource accounting. Nested sections group
independent scalar options; list/map composition, custom ownership-bearing values,
reactive updates, persistence, and UI rendering are outside this subset. Those
excluded shapes are rejected, not silently filtered from an application schema.

Sections 1–6 define types, operations, ownership, failure outcomes, and limits.
[testing.md](./testing.md) owns the independent traces and feasibility evidence;
[PLAN.md](./PLAN.md) owns the C1 delivery gate. Proposed identifiers are specified
interface names, not claims that implementation symbols exist.

## 1. Contract at a glance

1. Presence is independent of the typed payload and its default value.
2. Identities are exact byte strings, not paths, locale text, or arrival indices.
3. Every rejected operation preserves logical retained state and input ownership.
4. Successful owned submission and resolution transfer storage without deep copying.
5. A semantically failed snapshot is complete and inspectable, but has no complete configuration.
6. Views borrow the snapshot; an owning configuration copy is an explicit operation.
7. Admission budgets count logical content deterministically, not allocator capacity or RSS.

Normative keywords follow [BCP 14](https://www.rfc-editor.org/info/bcp14).
WCFG25–WCFG37 extend the existing IDs; WCFG1–WCFG24 retain their meanings except
for the explicit scalar accounting refinement in WCFG21.

## 2. Types, addresses, and metadata

### Supported schema

**WCFG25: Scalar schema admission.** The scalar resolver **must** support the
following finite schema shapes and **must** reject excluded shapes at compilation
with the original schema type and member path. It **must not** admit a supported
projection by silently dropping unsupported fields.

| Shape                                                              | Contract                                                                                                                                                                                               |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `bool`                                                             | Preserve true/false exactly                                                                                                                                                                            |
| `byte`, `ubyte`, `short`, `ushort`, `int`, `uint`, `long`, `ulong` | Preserve signedness and width; no narrowing during submission                                                                                                                                          |
| `float`, `double`                                                  | Preserve the stored representation, including signed zero and typed-input NaN payloads; JSON input follows wired's numeric rules                                                                       |
| Enum with a supported integral base                                | Preserve the enum type; typed submission rejects undeclared member values before selection; JSON uses original wire policies                                                                           |
| `string`                                                           | Preserve bytes and null-versus-non-null-empty state; JSON null is rejected by the ordinary string codec                                                                                                |
| `Nullable!V` for one supported non-null-aware scalar `V`           | Distinguish missing definition, explicit nullable null, and explicit value                                                                                                                             |
| Finite struct section                                              | Recurse only when explicitly marked as a section/submodule                                                                                                                                             |
| Empty root/section                                                 | Valid; creates no leaf options for that section                                                                                                                                                        |
| Excluded                                                           | `real`, complex/imaginary numbers, character scalars, wide strings, string-based enums, arrays/maps, pointers/classes, custom value/conversion ownership, nested nullable wrappers, and cyclic schemas |

`size_t` and other aliases are supported when their underlying type is in the table.
All-zero/default bit patterns are not presence indicators. Editor UDAs such as
`@Range` do not silently become resolver validation policies.

`ConfigMerge!Atomic` and `ConfigMerge!Submodule` are typed field UDAs, written as
`@(ConfigMerge!Atomic())` and `@(ConfigMerge!Submodule())`. An unannotated supported
scalar is atomic. `@WireSection` on a section type remains a compatible explicit
submodule marker. An atomic annotation conflicting with that marker, duplicate
merge annotations, a submodule annotation on a scalar, or a collection policy in
this subset is a compile-time error. The merge ladder has no string registry.

`ConfigCheck!predicate` is an optional field UDA. Exactly one is permitted per
scalar option. It receives the sole selected payload as `in V` and returns a
`ValidationResult`: accepted, or rejected with a nonempty stable code and optional
detail text. The predicate must be `@safe pure nothrow`, deterministic, and must
not mutate the subject or consult a source. Returned diagnostic text is captured
into the snapshot's owned storage and budget. Type incompatibility or duplicate
checks fail compilation; no predicate runs for an overridden or conflicting option.

### Addresses and identities

**WCFG26: Identity representation.** `SourceId` and `LocalId` **must** wrap nonempty
immutable byte sequences of at most 1024 bytes, compared for equality by length and
exact bytes. The resolver **must not** apply UTF normalization, case folding,
locale comparison, or filename canonicalization to identities.

Borrowed identity inputs are `scope const(ubyte)[]`; retained identity views are
`scope const(ubyte)[]` tied to their owner. Invalid UTF-8 and control bytes are valid
identity data and are escaped by presentation, never executed. Source detail is
separate diagnostic text and does not determine equality or ordering.

Canonical option addresses use the original D schema member names, joined with
`.` through sections, in the property-tree grammar. Wire renames select document
keys, not option identity. Display labels are never addresses. Compiler-emitted
canonical addresses are immutable and unique; runtime path inputs must match
exactly. Wire policies must reject ambiguous document spellings before admission.

Definition identity remains `(SourceId, canonical option address, LocalId)`.
`LocalId` defaults to byte string `value` for submitted options and `initializer`
for built-in definitions. Distinct local IDs allow one registered source to submit
several definitions for an option; resubmitting the same identity is an error.
`SourceRef`/`DefinitionRef` are checked opaque owner-bound handles. Their numeric
storage indices are not semantic identity and need not match across permutations.
Owner identity must not be only a reusable storage address: a handle retained after
owner destruction cannot become valid for a later owner through allocator reuse.
Handle validity checks never dereference a retired owner's payload storage.

## 3. Input and operation interface

`ConfigInput!T` derives one `DefinitionSlot!V` per leaf and nested input sections.
A slot has `supplied` and the original typed `V` payload. Payload contents of an
unsupplied slot are ignored, not copied or validated. `DefinitionMetadata!T`
derives optional leaf overrides of priority, order, local ID, and source location,
and a `SectionDefinitionMetadata!S` node for each section. Each section node has
optional `priority` and a `members` metadata tree derived from its original child
fields; the wrapper keeps policy metadata separate from child member names.

**WCFG37: Section priority metadata.** The scalar metadata interface **must**
represent section-wide priority overrides required by WCFG13. For each supplied
leaf, its explicit priority override **must** win; otherwise the nearest enclosing
section override **must** win, falling back to the registered source default.
Inherited section metadata **must not** create definitions for absent leaves.

An explicit leaf metadata override for an absent leaf is rejected. A section
priority override on an empty or entirely absent section is valid but inert; it
does not become an override on each absent child. Section priority is fixed-width
record metadata, not a separate source, definition, option, or payload-byte charge.
Order, local ID, and source location remain source/leaf metadata, not section
overrides. For section `viewer`, the section override is
`metadata.viewer.priority`; a child field named `priority` has its independent
leaf override at `metadata.viewer.members.priority.priority`. Canonical option
addresses remain original schema member paths, without these metadata wrappers.

**WCFG27: Original-policy decoding.** `decodeConfigInput!T` **must** determine
presence from supplied document members and decode present leaves through their
original field/type wire policies, not by decoding `Sparse!T` or the slot struct
as a document. It **must** reject duplicate canonical options even when different
wire spellings name them, and **must** retain absence/null/value distinctions.

The JSON adapter accepts text or a borrowed parsed root and metadata plus explicit
capsule limits, performs no file I/O, and returns an `OwnedConfigInput!T`, a located
decode error, or an operational capture error. Successful payloads outlive the
parsed document.
It reuses the native wired schema/leaf decoding walk with enclosing field policy;
it does not serialize subtrees and parse them again.
Unknown-member behavior is an explicit decoder option using wired's existing
policy, not an implicit source of definitions. A requested wire policy unsupported
by this subset is a compile-time error, not a silent fallback.

The scalar JSON adapter supports `WireName`, `WireCase`, and `WireRepr` under their
original JSON field/type policies, plus `WireStrict` for unknown members.
`WireOptional` with `onInvalid: reject` is accepted but never creates a definition
for a missing member; its encoding skip rule is irrelevant to input presence.
`WireOptional` with `onInvalid: useDefault` and `WireConvert` are excluded here and
must be diagnosed at compilation. Other format-scoped policies are ignored exactly
as wired's JSON policy resolution ignores them. `ConfigDecodeOptions` fixes
`unknownMembers` to `reject` by default or explicit `ignore`; `WireStrict` always
requires rejection. Native parser options remain explicit decoder inputs.

`OwnedConfigInput!T` is move-only with private payload storage. It is manufactured
by successful `decodeConfigInput` or `captureInput` from a borrowed `ConfigInput`.
No public constructor accepts an arbitrary owning claim over aliased mutable data.
Capturing strings preserves their null/empty state; source locations and identities
are captured too. A caller cannot retrieve mutable interior slices from a capsule.

The following table specifies proposed operations, not runnable declarations.
All failure outcomes are explicit result values. Methods accepting views borrow
only for the duration of the call; ownership moves only at the success point.

| Operation                                            | Input and success                                                                                                                                                           | Rejection / state                                                                                                            |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `ConfigBuilder!T.create`                             | Positive `ConfigLimits`, optional built-in priority/order; validates primitive domains and creates collecting builder with built-in source and initialized leaf definitions | Invalid limits, located `invalidValue` for a built-in, schema budget exhaustion, or allocation failure; no builder published |
| `registerSource`                                     | Borrowed source ID, kind, detail, default priority/order; returns owner-bound `SourceRef` after capture                                                                     | Duplicate/reserved ID, invalid metadata, limit or allocation failure; builder unchanged                                      |
| `setLimits`                                          | Collecting builder and positive limits sufficient for all retained content/schema; atomically replaces budget policy                                                        | Invalid limits or any limit below current usage; values, counters, handles, and prior policy unchanged                       |
| `captureInput`                                       | Borrowed typed input and metadata, limits for the detached capsule; returns independently owned capsule                                                                     | Invalid metadata, budget or allocation failure; caller input unchanged                                                       |
| `submitBorrowed`                                     | Registered source, borrowed typed input and metadata; captures present values and commits whole definition set                                                              | Any invalid/duplicate definition, budget or allocation failure; no definitions committed                                     |
| `submitOwned`                                        | Registered source and `ref OwnedConfigInput!T`; preflights and transfers present values/metadata                                                                            | Same rejection rules; capsule and builder unchanged                                                                          |
| `resolve`                                            | Collecting builder; returns complete `ConfigSnapshot!T`, including semantic failures, and marks builder consumed                                                            | Limit, arithmetic overflow, or allocation failure; builder still collecting, no partial snapshot                             |
| `visitOption` / `visitDefinition`                    | Snapshot, exact option address or owner-bound definition handle, typed sink; borrows original typed value and status/contributors                                           | Unknown option, wrong owner, invalid handle/state; does not call sink                                                        |
| `visitOptions` / `visitDefinitions` / `visitSources` | Snapshot and typed sink; visits all option records, an option's definition records, or source records in specified order                                                    | Invalid snapshot or option; does not call sink                                                                               |
| `visitSource`                                        | Snapshot and its source handle; borrows source record                                                                                                                       | Wrong owner, invalid handle/state; does not call sink                                                                        |
| `copyConfig`                                         | Fully resolved snapshot; returns independent `T` preserving field values, with owning copies of non-static string data                                                      | Semantic failures or allocation failure; snapshot unchanged                                                                  |

`OptionView!V` retains the original schema type identity and exposes the canonical
path, atomic policy, status, priority, and definition/contributor handles.
Its effective payload and `DefinitionView!V.value` use opaque inline
`ConfigValueView!V` records with `hasValue` and a scoped `get` accessor, not public
pointers to slice headers. Strings read as `const(char)[]`; nullable payloads use
`ConfigNullableValueView!N` with `isNull` and scoped `get`. Other supported scalars
retain their original value type. Private storage and `copyConfig` retain `V`.

This read projection is required for lifetime safety: an immutable string header
can escape D's `scope` checks, and a public pointer-to-slice indirection can lose
the nested borrow relation even with const bytes. Scoped direct accessors preserve
that relation without claiming independent immutable/GC lifetime. Source detail,
validation code/detail, and byte identities follow the same borrow discipline;
diagnostics use an inline `ConfigDiagnosticView` with `hasValue`/scoped `get`.
No string bytes are cloned to construct any of these views.

`DefinitionView!V` exposes identity/source, priority/order/location, disposition,
and original supplied value through that borrowed projection. Sources enumerate
by ascending source-ID bytes, options by schema declaration order, and each option's
definitions by `(priority, order, SourceId, LocalId)`; selected contributor handles
retain that order. Failed-address ordering remains canonical-address byte order.

An invalid selected option additionally exposes a scoped `ValidationFailureView`
through `OptionView.diagnostic`: canonical option, selected definition/source
handles, winning priority, source location when supplied, and the original check
code/detail. It is null for resolved/conflict options; a conflict's selected
definition handles and priority are already available in the option view.
`notFullyResolved` exposes failed option addresses in canonical byte order; each
can be inspected with `visitOption`, without a duplicated payload/error list.

Source registration is unique, not idempotent: registering the same ID twice fails
even if its detail is equal. The reserved built-in source ID is `$builtin`, kind
built-in, detail empty; callers cannot register that ID or kind. Creation supplies
its definitions at priority 1500/order 0 unless explicitly overridden. An empty
root still registers the built-in source. Source kind contributes no precedence.

`setLimits` permits explicit recovery from a budget failure without changing any
definition, source default, or identity. It is not an operation for changing
configuration values. A caller can instead destroy the collecting builder; retry
is permitted, not required to succeed without changing resource conditions.

Unknown JSON syntax/member failures occur before submission and return no capsule;
app policy chooses exclusions. No accepted definition is relabeled a decode error.
Per-definition source location is optional. When present, byte offset is zero-based
and line/column are one-based positive integers; the resolver does not reopen a
file to verify them. Location values are not addresses or identity components.

**WCFG28: Atomic admission.** Registration and each submission **must** preflight
identities, all present values/metadata, and all applicable budgets before committing
logical state. Failure **must** leave logical records/counters and caller ownership
unchanged; a successful owned submission **must** leave its capsule empty/consumed.

Creation **must** validate the primitive domain of every built-in definition before
publishing a builder. An undeclared enum initializer **must** return `invalidValue`
with the canonical option address and publish no builder, regardless of whether a
stronger source could override that default. A domain-valid initializer rejected
by `ConfigCheck` **must** remain admissible at creation; its check runs only if it
is the sole selected definition during resolution.

An empty submission is valid and commits no definitions; owned submission still
consumes its capsule. Primitive domain validation, such as invalid enum values,
happens at admission for every present definition. Schema `ConfigCheck` predicates
run only during selected-value resolution. Metadata defaults are materialized at
submission; later sources cannot retroactively change earlier definitions.

## 4. Lifecycle and borrowing

**WCFG29: Resolution transition.** A successful `resolve` **must** transfer retained
storage into one move-only snapshot without deep-copying the complete definition
set, and **must** consume the builder even when the snapshot contains conflicts
or selected-value validation failures. Operational failure **must** leave the
builder collecting and retryable with all original definitions retained.

The owner identity of retained source/definition storage **must** transfer from
builder to snapshot. A `SourceRef` returned by `registerSource` **must** remain
valid for `visitSource` on the resulting snapshot, including a semantically failed
snapshot; the consumed builder **must** reject further operations as `invalidState`.
Operational failure **must** preserve that handle's validity with the collecting
builder. Moving the builder or snapshot transfers this same retained-set identity,
not a new identity derived from the wrapper's address.

```text
create -> collecting --register/submit success--> collecting
                    --register/submit rejection--> collecting, unchanged
                    --resolve operational failure--> collecting, unchanged
                    --resolve complete outcome--> consumed + snapshot
```

A consumed/moved-from builder returns `invalidState` for every stateful operation;
it does not behave as a freshly empty builder. Resolving it twice is invalid.
Creating another builder is explicit. There is no sealed intermediate state,
concurrent mutation protocol, or incremental snapshot update in this interface.

**WCFG30: Read-only snapshot views.** Snapshot inspection **must** expose only
borrowed `const` typed values/records, with lifetimes tied to the live snapshot,
and **must not** permit mutable interior aliases. Moving or destroying a snapshot
**must** invalidate outstanding views; its handle owner identity **must** transfer
with the storage so saved handles can be used with the moved-to snapshot.

Views do not become independently owned because a struct or slice header was
copied. Visitor records are `scope ref const` values with the borrowed payload
projection above and return `void`; they must not be stored outside the call.
Safe DIP1000 negative controls must reject const-slice escapes, not merely fail
because a const slice cannot be assigned to an immutable string. Callers must not
move or destroy an
owner during its active visitor; this is a programmer precondition, not an
external-input failure. Callers needing independent configuration use `copyConfig`;
callers needing provenance keep the snapshot alive. Copying immutable static data
can be avoided, but borrowed external buffers cannot be assumed static or owned.
A typed sink is selected through a template seam, not an allocated delegate per
option or a `void*` callback. Successful inspection is independent of discovery.

## 5. Semantic and operational results

**WCFG31: Selection before checking.** Atomic resolution **must** select minimum
priority, form the equal-priority conflict if more than one definition is selected,
and otherwise run the option's `ConfigCheck` on the sole selected payload. It
**must not** validate overridden payloads with that selected-value predicate or
use a losing valid definition to replace a selected invalid one.

Each definition has exactly one disposition: `overridden`, `contributing`,
`conflicting`, or `invalid` (the sole selected definition rejected by its check).
Each option is `resolved`, `conflict`, or `invalidSelectedValue`. An unresolved
option has no effective value accessor. With no submitted definition, the built-in
is selected and checked. No implicit copy or equality check deduplicates intent.

**WCFG32: Failure completeness.** A complete snapshot **must** retain every
accepted definition and all option semantic failures; `copyConfig` **must** fail
while any option is unresolved. Failure to retain all dispositions, diagnostics,
or records within the operational limits **must** return an operational error
instead of publishing an incomplete snapshot.

Operational errors distinguish `invalidState`, `invalidLimits`, `invalidMetadata`,
`invalidValue`, `unknownSource`, `wrongOwner`, `unknownOption`, `invalidHandle`,
`duplicateSource`, `duplicateDefinition`, `limitExceeded`, `arithmeticOverflow`,
and `allocationFailed`. `copyConfig` reports `notFullyResolved` with references to
the snapshot's semantic failures rather than an allocated duplicate error list.
Limit errors name the limit and requested/used amounts; errors avoid allocating an
unbounded message to report exhausted storage. Recoverable allocator failure means
a detectable allocator failure, not recovery from process termination by the OS.

Failure precedence is fixed for repeatable diagnostics: state/owner validity,
limit-parameter validity, metadata/domain validity, duplicate identities, then
accounting overflow/budget checks in the limit declaration order below, then
allocation. Within an input batch, the earliest canonical option
address wins equal-category admission failures. No arrival-dependent diagnostic
sorting is permitted for a completed snapshot. Spare capacity may grow on a failed
operation, but logical contents and counters do not change; no spare-capacity
pointer is a public handle.

## 6. Limits and accounting

**WCFG33: Scalar resource defaults.** The scalar interface **must** use the following
positive configurable defaults, include built-in records in the budgets, and
check additions before overflow. A count equal to its limit **must** succeed when
all other preconditions hold; exceeding any limit **must** fail unchanged.

| Limit (validation order) | Unit / type                                  | Default             | Charged content                                             |
| ------------------------ | -------------------------------------------- | ------------------- | ----------------------------------------------------------- |
| `maxSources`             | source records / `uint`                      | 1024                | Registered sources, including built-in                      |
| `maxDefinitions`         | definition records / `uint`                  | 65,536              | Every present definition, including overridden and built-in |
| `maxPayloadBytes`        | logical bytes / `ulong`                      | 16,777,216 (16 MiB) | Values and retained text under the rules below              |
| `maxOptions`             | independently resolved leaf records / `uint` | 4096                | Schema leaves; sections are not option records              |
| `maxDepth`               | member hops from root / `uint`               | 32                  | Root is 0; a direct leaf is 1                               |

Identity length 1–1024 bytes is metadata validity, not a separate configurable
limit. Limits are checked at creation for defaults/schema, at registration and
submission for additions, and during resolution for retained diagnostics. No
option can escape the definition limit by having a weaker priority.

Scalar payload accounting is deterministic and independent of allocator layout:

- A bool/integer/float/enum definition charges the declared value type's `sizeof`.
- A string definition charges its byte length; null and non-null empty charge zero
  but remain distinct in the value representation.
- A `Nullable!V` definition charges one tag byte plus the payload charge when not
  null. The submission-presence bit is record overhead, not a second payload tag.
- Every definition's payload is charged separately, even if immutable storage is
  internally shared. This avoids alias- or interning-dependent admission.
- Canonical leaf paths are charged once per schema. Retained identity strings are
  interned by exact bytes and charged once per distinct identity byte string.
- Each registered source's detail is charged once. Each retained validation
  diagnostic's code/detail is charged once per failed option. Source-local
  locations contain only fixed-width numeric metadata and are record overhead.
- Priority/order fields, handles, padding, container/allocator overhead, retained
  unused capacity, and temporary decoder/clone buffers are excluded. These are
  logical-content limits, not a peak-memory or RSS guarantee.

Detached capsules use the same positive limit fields but different usage:
`maxSources` usage is zero, with no registered or built-in source; options/depth
are the complete declared scalar schema; definitions are supplied slots only.
Their payload budget includes each canonical schema leaf path once, supplied
payloads, and explicitly supplied local IDs interned once. No source detail,
built-in value/ID, validation diagnostic, or omitted default local ID is charged.
Priority/order/default local ID are materialized at submission, not capture.
For a one-field `width` input holding int 8 with no overrides, capsule usage is
one option, one definition, depth 1, and 9 bytes (path 5 plus value 4); explicitly
supplying local ID `value` raises that to 14. An empty input still charges its
schema paths but no definitions. Capture and decode use these identical rules.

After transfer the capsule's limits do not become builder policy; admission uses
the builder's current limits and computes only newly retained content. Existing
paths/identity intern entries are not charged twice. Capsule counters become
empty/consumed on success, and stay unchanged on rejection. Temporary simultaneous
capsule/builder ownership is not a combined RSS budget.

**WCFG34: Overflow and diagnostic budgets.** Accounting **must** first reject an
addition exceeding `ulong.max - used` as `arithmeticOverflow`, then reject a
representable addition exceeding `limit - used` as `limitExceeded`. Count totals
**must** be computed in `ulong` before comparison with their `uint` limits; if
retaining validation text exhausts the budget, resolution **must** retain the
collecting builder rather than dropping text or publishing a partial snapshot.

A diagnostic-free conflict refers to its retained option/definition/source records
rather than duplicating their values into error strings. Error-category codes and
limit names are bounded static vocabulary. These rules bound retained content;
implementation work and allocator-overhead measurements remain acceptance evidence,
not unsupported performance promises.

The storage implementation must provide an internal allocator seam so a failing
adapter can exercise real capture, submission, resolution, and copying operations.
The seam is not a public per-node callback, and production behavior must not switch
on `version(unittest)` merely to manufacture a failure result.

The [schema census](./testing.md#scalar-readiness-feasibility) measured at most 108
leaf-shaped fields, depth 4, and 607 scalar default bytes in the three app subjects.
Collections were counted but excluded from scalar payload measurement. The defaults
are local headroom policy, not measured maxima for arbitrary user documents; C2
collection/custom-value accounting remains independently gated.

**WCFG35: No hidden cloning.** Builder-to-snapshot and owned-input-to-builder
success paths **must** transfer retained storage; they **must not** clone it simply
to create read-only views. Borrowed capture and `copyConfig` **must** be explicit
copying operations, and immutable internal sharing **must not** change accounting,
observable ownership, or mutation independence.

**WCFG36: Interface evidence.** Acceptance **must** include compile-time rejection
of copied move-only owners and escaping snapshot views, runtime mutation/lifetime
checks for borrowed capture, boundary/overflow and allocator-failure injection,
and an actual scalar conflict-inspection driver. Feasibility of separate presence
and a move operation **must not** be reported as conformance of an unimplemented
resolver.
