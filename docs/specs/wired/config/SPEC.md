---
status: draft
owner: sparkles:wired
reviewed: 2026-10-05
---

# `sparkles.wired.config` — Definition resolution

## Abstract

`sparkles:wired` resolves application configuration from independently supplied
settings while retaining enough information to explain every result. Each
setting declares how equally preferred values combine; numerical priorities
select the definitions eligible to contribute. The same typed schema supplies
compiled defaults, input that distinguishes absent settings from supplied values,
merge rules, and inspection addresses. Conflicts are explicit results rather than
accidental consequences of file-loading order. Applications choose sources and
precedence, while a shared presentation reports effective values and each
definition's final contribution or override status.

## Introduction

A desktop or command-line application receives preferences from compiled
defaults, machine-wide files, user files, project files, environment variables,
and explicit arguments. A reader needs to know why a setting has its value, not
merely which files were read. A project can intentionally set a boolean to its
compiled default, and several sources can intentionally extend the same list.
Neither case can be reconstructed by comparing the final value with defaults.
A typed schema is the D value declaration with field initializers and policy
attributes, rather than a parallel document schema.

An ordered overwrite fold records the last writer, but it cannot explain an
assembled value, retain overridden definitions, or distinguish a legitimate
combination from an equal-precedence conflict. Treating every collection as a
replacement loses extensions; concatenating every collection ignores intent.
Loading order alone makes independently supplied settings difficult to reason
about and test.

The approach is to retain each supplied value as a
[configuration definition](../../../glossary.md#config-definition), with its
source, numerical priority, and explicit ordering information. The least
numerical priority selects the eligible definitions of a
[configuration option](../../../glossary.md#config-option). Ordering positions
equally preferred values only when combination depends on order; it does not
select eligibility. The schema chooses whether those definitions conflict,
concatenate, or recursively combine. Retained inputs and their final dispositions
explain the result; an execution trace of intermediate merge steps is not required.

This contract owns the typed, synchronous, I/O-free configuration resolver in
`sparkles:wired`; `sparkles.wired.config` is a proposed module family, not a new
package. Applications discover sources, choose decoding policy, use library input
adapters or submit typed definitions, and report conversion failures. They own
priority assignment and startup decisions; the UI library owns presentation.
File writing, reactive evaluation, arbitrary executable configuration, Nix
expression evaluation, and a lazy module evaluator are outside this scope.

Sections 1–7 define the resolver contract, failure model, and compatibility
seams. [Scalar resolution](./scalar-resolution.md) specifies the concrete
scalar/string interface, identity, ownership, and budgets.
[Composition](./composition.md) specifies collection/submodule presence, projections,
native decoding, and additional resource accounting.
[Inspection](./inspection.md) owns the shared report contract in `sparkles:ui`.
[PLAN.md](./PLAN.md) owns delivery order and progress; [testing.md](./testing.md)
owns oracles and evidence; [decisions.md](./decisions.md) owns consequential
choices and explicitly blocked work.

## 1. Contract at a glance

1. One schema declares option names, types, and built-in default values; UDAs select how definitions compose.
2. Leaving an option out supplies no definition; explicitly setting it supplies a definition even when its value equals the built-in default.
3. Lower numerical priority wins before equal-priority merging begins.
4. Source arrival order is not an implicit conflict resolver or list order.
5. All accepted definitions survive resolution, including overridden definitions.
6. Conflicts have no fabricated effective value and do not overwrite caller state.
7. The resolver performs no I/O and depends on no UI, CLI, or application package.
8. Effective-value and all-definitions reports describe one resolution snapshot.

Normative keywords are bold and lowercase, with the meanings of
[BCP 14](https://www.rfc-editor.org/info/bcp14). This is a draft contract;
implementation evidence is recorded separately in [testing.md](./testing.md).

## 2. Scope, vocabulary, and ownership

The resolver target is synchronous resolution of finite D struct schemas,
scalars, strings, dynamic lists, associative maps, and nested sections, consumed
by hue, terminal, and diagram. Strings are scalar unless a UDA selects `lines`.
Arrays are atomic option values unless their option selects list composition.
Pointers, classes, cyclic subjects, arbitrary ranges, sum-variant merging, and
lazy evaluation are excluded from the resolver target. Unsupported schema
shapes fail at compilation rather than becoming opaque successful merges.

The shared vocabulary is defined once in the
[glossary](../../../glossary.md):
[configuration option](../../../glossary.md#config-option),
[configuration source](../../../glossary.md#config-source),
[configuration definition](../../../glossary.md#config-definition),
[definition priority](../../../glossary.md#config-priority), and
[resolution snapshot](../../../glossary.md#config-snapshot).

Package arrows below mean “imports or links against,” not delivery order:

```text
apps/hue, apps/terminal, apps/diagram
  -> sparkles:ui inspection -> sparkles:wired config -> sparkles:base
  -> sparkles:core-cli discovery and command parsing
```

**WCFG1: Single schema.** The resolver **must** derive option addresses, typed
definition storage, and compiled defaults from the resolved schema. An
application **must not** repeat the schema's field list or default values in a
parallel configuration or provenance declaration.

**WCFG2: Policy ownership.** The resolver **must** accept sources and definitions
as explicit inputs and **must not** discover files, read environment variables,
parse process arguments, log diagnostics, write files, or start a host. Source
kind **must not** determine definition priority inside the resolver.

**WCFG3: Supported shapes.** Instantiating an unsupported shape or an incompatible
composition UDA **must** fail compilation with the schema type and option named.
Ordinary malformed external values **must not** be treated as programmer assertions.

The resolver reuses wired's schema and sparse-presence mechanisms. This contract
does not require an unverified reified-schema feature from the
[expressiveness specification](../expressiveness/SPEC.md); the resolver uses
facilities verified in the tree, with one shared walk per concrete type.

## 3. Sources and definitions

A source has a stable caller-supplied identity, a category, and diagnostic detail.
Categories distinguish built-in default, system file, user file, project file,
environment, command line, and application-specific inputs such as terminal's
Termux compatibility input. A path or environment-variable name is source detail,
not a precedence rule. Two sources with different identities can name the same
file; the host is responsible for deciding whether those are distinct submissions.

A definition contains a typed value, a source reference, priority, order, a
source-local identity, and an optional located origin within its source.
Priority and order are independent: priority selects eligibility, while order
positions selected definitions for noncommutative merges.

**WCFG4: Presence.** Importing a sparse source **must** create a definition for each
present option and none for an absent option. Explicit `false`, zero, empty
collections, null-capable values, and values equal to compiled defaults **must**
remain distinguishable from absence where the declared codec supports them.

The sparse envelope and a nullable option payload are separate concepts.
[Scalar resolution](./scalar-resolution.md#_3-input-and-operation-interface)
requires a presence slot outside the original payload and original-policy leaf
decoding. Nested `Nullable` overlays are rejected by wired, and the existing
`Mapped` transform loses field rename metadata; it is not the JSON input decoder
for this contract. [Presence evidence](./testing.md#scalar-readiness-feasibility)
records both failures and the separate-slot proof.

**WCFG5: Defaults.** Every independently resolved option, including composed
lists, maps, and `lines`, **must** receive a built-in definition from its field
initializer, with default priority 1500. Nested sections **must** distribute
initialized child defaults from the enclosing value, including a field initializer
that differs from the section type's initializer. Hosts **may** explicitly select
another built-in priority.

**WCFG6: Definition metadata.** Priority **must** be an unsigned 32-bit integer;
order **must** be a signed 32-bit integer. Hosts **must** supply stable source and
source-local identities, and the resolver **must** reject duplicate identities
within a submitted definition set without dropping or multiplying a definition.
A source's default priority/order **must** be materialized onto each definition;
per-option overrides **must** affect only their named definitions.

Definition identity is the tuple `(source identity, canonical option address,
source-local identity)`. Priority values need no arithmetic transformation;
comparison uses their full range. An ordinary host default priority of 1000 is
an example, not a rule binding every app. Per-definition overrides are typed
host inputs, not reserved keys inserted into existing JSON documents.

The scalar interface fixes the identity representation, reserved built-in ID,
length bounds, canonical member addresses, and owner-bound handle rules in
[WCFG26](./scalar-resolution.md#addresses-and-identities).

**WCFG7: Submission ownership.** A successful submission **must** transfer owned
payload storage or take an independent snapshot of borrowed payloads. Mutating or
freeing the caller's input after submission **must not** change retained values.
A rejected submission **must** preserve both the accumulated set and caller
ownership. The public interface **must** state which submission form it uses.

## 4. Selection and UDA-directed composition

### 4.1 Selection

**WCFG8: Minimum-priority selection.** For each atomic option, resolution **must**
select exactly the definitions whose priority equals the minimum priority present
for that option. Higher numerical priorities **must** remain retained as
overridden, and **must not** participate in merging or validation of the selected
value. Decoding validation happens before submission and is not bypassed by this rule.

**WCFG9: Explicit composition.** Option composition **must** be selected through
compile-time schema UDAs and typed policies, with no runtime string registry.
Unannotated scalar and collection options **must** use atomic conflict semantics;
collection type alone **must not** opt an option into composition.

The following policy names are illustrative vocabulary, not shipped symbols:

| Policy       | Accepted values                                   | Equal-priority result                                                    |
| ------------ | ------------------------------------------------- | ------------------------------------------------------------------------ |
| `atomic`     | Supported scalar or atomic collection             | One definition succeeds; two or more conflict                            |
| `listOf(P)`  | Dynamic list with supported element policy `P`    | Ordered concatenation; elements are not merged with neighboring elements |
| `attrsOf(P)` | Associative map with supported key representation | Key union; overlapping keys resolve using `P`                            |
| `lines`      | String                                            | Ordered join with one newline between supplied strings                   |
| `submodule`  | Nested typed section                              | Each declared child option resolves independently                        |

**WCFG10: Atomic conflicts.** Two or more selected definitions of an atomic option
**must** produce a conflict containing all selected definitions, even when the
values compare equal. Equality **must not** silently deduplicate independently
submitted intent.

_Rationale:_ Equal-priority definitions from distinct sources retain distinct
intent. Treating them as conflicting exposes overlaps rather than silently
collapsing them. This is a local policy, not a claim of exact NixOS compatibility.

**WCFG11: Ordered lists and lines.** Selected list or `lines` definitions **must**
be ordered by `(order, source identity, source-local identity)`, using ascending
signed numerical order followed by ascending lexicographical unsigned-byte
comparison of source identity and source-local identity, independent of submission
order. A byte prefix sorts before its longer extension.
Lists **must** preserve each definition's internal element order. `lines`
**must** preserve each supplied string verbatim and insert exactly one newline
between definitions, including empty strings; it **must not** normalize existing
newlines or add an extra trailing newline.

**WCFG12: Recursive maps.** An `attrsOf(P)` option **must** select its winning
priority at the map option before forming the union of keys. Each selected map's
entries **must** inherit its definition metadata; overlapping keys **must**
resolve through `P`, with conflicts addressed to the key. Map keys **must** have
an injective canonical wire spelling, and inspection **must** order them by that
spelling's bytes. Colliding spellings **must** produce a structured error.

**WCFG13: Nested sections.** A `submodule` section **must** distribute source
presence and inherited metadata to child definitions before child priority
selection. An absent child **must not** erase another source's child. A
section-wide priority override **must** supply inherited priority only; an
explicit child override takes precedence within that submitted source.

The distinction between maps and sections is intentional: a winning `attrsOf`
map can replace the lower-priority key set, whereas independently declared child
options of a section can have different winning priorities. An empty section
supplies no child definitions; an explicitly empty atomic map or list supplies
one definition. See the worked traces in [testing.md](./testing.md).

Terminal's draft [profile contract](../../terminal/profiles.md#_2-values-and-configuration)
requires dynamic per-ID, per-field resolution that preserves weaker contributions
to unrelated objects. Direct whole-map selection under `WCFG12` does not meet that
consumer requirement. A separately specified generic distribution policy is a
delivery prerequisite; this paragraph does not change `attrsOf` semantics or claim
that policy exists.

### 4.2 Algebra and provenance

**WCFG14: Permutation invariance.** Reordering submission of the same identified
definition set **must** preserve resolved values, contributors, overridden
statuses, and canonical conflict sets. Diagnostics **must** use canonical option
and definition ordering rather than arrival order.

**WCFG15: Conditional merge laws.** Policies designated commutative and associative
**must** preserve results or canonical conflicts under permutation and regrouping
of their retained definitions. A recursively composed map or section **must**
claim those laws only when every nested policy satisfies them. List and `lines`
concatenation **must not** be described as commutative.

Regrouping means grouping retained definitions without discarding their metadata,
not resolving intermediate groups into values and submitting those values again.
Such an intermediate value has lost priority and provenance and is not an
equivalent input. Lazy maps/submodules require a separate demand and error-timing
contract before they enter scope.

**WCFG16: Contributor provenance.** Every resolved option **must** reference all
selected contributing definitions, not merely the last source. Expanded elements
of an atomic array **must** identify their owning option's provenance. Elements
of concatenated lists **must** identify the contributing definition that supplied
them. Recursive map keys **must** retain the contributors for their own results.

## 5. Resolution snapshots and failures

**WCFG17: Snapshot consistency.** Resolution **must** produce a caller-owned,
immutable-by-interface snapshot of retained definitions, per-option dispositions,
resolved values, and conflicts. Inspection **must** consume that snapshot without
rerunning discovery or resolution. The interface **must** document aliasing and
lifetime rules and **must not** retain pointers into a temporary decode buffer.

**WCFG18: Conflict result.** A conflict **must** contain its canonical option
address, the winning priority, all conflicting definition references, and the
composition policy. An unresolved option **must not** contain a substituted
default or last-writer effective value. Successfully resolved options **must**
remain inspectable in the same snapshot; a complete resolved configuration
**must** be unavailable while any option remains unresolved.

**WCFG19: No implicit commit.** Resolution and inspection **must not** mutate a
running configuration or save file. Applications choose whether a failed load
prevents startup or whether rejected external definitions are excluded before a
separate resolution; any exclusion **must** remain visible as an app-owned located
diagnostic rather than being labeled an overridden accepted definition.

**WCFG20: Failure categories.** Invalid input metadata, duplicate identity,
unsupported runtime key spelling, invalid selected values, composition conflict,
and resource exhaustion **must** have distinguishable structured outcomes. A
custom typed validation policy **must** return a located failure rather than
throwing for malformed external input; conflict accumulation **must not** conceal
exhaustion as a complete conflict set.

The public resolver surface is synchronous and uses explicit result values.
No allocation-free or `@nogc` promise is inferred from that choice. Templates infer
attributes; non-template functions follow the repository's explicit safety rules.

**WCFG21: Limits.** The caller **must** be able to set positive limits for retained
definition count, retained payload bytes, recursion depth, and generated option
records. Exceeding a limit **must** return exhaustion with the limit named and
**must not** publish a truncated snapshot as complete. The scalar interface
**must** follow [WCFG33–WCFG34](./scalar-resolution.md#_6-limits-and-accounting):
shared retained metadata is charged once, definition payloads are charged per
definition independently of physical sharing, and allocator/container overhead is
excluded. These are logical-content limits, not an RSS guarantee.

Scalar and supported finite collection accounting are specified by their concrete
interface pages; [WCFG49–WCFG50](./composition.md#_6-collection-accounting-and-gates)
extend scalar logical charges to derived records and normalized graphs. Custom
conversion/ownership remains gated by [Q1](./decisions.md#q1-storage-and-default-limits).
Specified limits and feasible primitives are not collection-conformance evidence.

## 6. Integration and compatibility

WCFG22 and WCFG23 are integration obligations owned by the shared configuration
integration contract, not requirements that the resolver can satisfy alone.
Application maintainers enforce them at cutover; app specifications own source
profiles, malformed-source policy, and persistence details and link here rather
than duplicating these obligations. The existing IDs and section anchor remain
stable.

**WCFG22: Shared startup resolution.** Each migrated app's normal startup and
`config show` **must** obtain configuration from the same host-independent loader
and resolver. Only explicitly supplied environment/CLI settings **must** become
definitions; parser-initialized option defaults **must not** masquerade as explicit
CLI input.

Existing [hue CFG2/CFG10](../../hue/config.md) and
[terminal TCF2/TCF5](../../terminal/config.md) define app discovery and inspection.
The resolver does not add a system or project layer to an app merely because
its source vocabulary supports that category. The existing
[property-tree contract](../../ui/property-tree.md) owns tree addressing,
disclosure, metadata, and edit safety; this effort owns only the additional
read-only inspection profile specified in [inspection.md](./inspection.md).

**WCFG23: Clean configuration cutover.** App migrations **must** remove the
obsolete configuration-specific last-writer and composition paths once startup,
inspection, and settings persistence consume this definition-resolution model. Generic
`wired.overlay` users outside that cutover **must not** be silently changed.
Sparse persistence **must** retain only deliberate user edits and **must not**
write an effective snapshot containing environment or CLI definitions.

Hue grammar paths and other `WireCompose` options require explicit priority and
order choices: unlike a prepend fold, this resolver composes only selected
equal-priority definitions. Defaults retained at a weaker priority do not
contribute to a stronger winning list. The host can assign equal priorities to
sources intentionally extending that option, with separate order metadata.

Diagram's grid document is not its settings-pane struct. Its aliases, presets,
brush representations, live counts, and palette overrides require a typed
compatibility adapter that emits sparse definitions; the old and adapted document
must have the same accepted values and effects. That wire adapter is not a second
merge engine. Its migration gate is [Q3](./decisions.md#q3-diagram-wire-adapter).

Keybindings have an application-semantic merge after file decoding. Their actual
active table, unbindings, subtree claims, and rejected reserved chords require a
typed inspection projection with recorded contributors; an overlay entry count
is not the active binding table. [Q2](./decisions.md#q2-keybinding-composition)
blocks that migration, not scalar resolver implementation.

## 7. Trust and publication boundaries

Config documents, source details, values, and documentation metadata are inputs
that can appear in terminal output. The resolver evaluates no configuration code
and resolves no documentation URL over the network. Hosts own secret-field
classification and supply synthetic credentials for diagnostics tests.

**WCFG24: Diagnostic ownership.** The shared model **must** preserve source detail
and option identity without logging them. Public reporting **must** honor explicit
host redaction for sensitive options in both effective and all-definition modes;
redaction **must not** change resolution or expose values through conflict text.
Source identities **must not** require embedding a secret value.

Documentation-only publication establishes navigation and contract review, not
resolver conformance. The evidence ledger distinguishes source observations,
publication checks, feasibility experiments, and acceptance suites.
