# `sparkles:ui` architectural principles — Requirements (`PRN`)

_**Status:** binding · **Date:** 2026-07-29 · **Scope:** the architectural rules
`sparkles:ui` and its consumers are held to, each traced to its source in the
[Sean Parent research catalog](../../research/sean-parent/index.md)._

These are not style preferences. They are the rules that make a single widget
tree renderable to three backends without the per-backend divergence the toolkit
exists to remove — and each one names a concrete failure the codebase has
actually exhibited.

## Design & rationale

The catalog's central claim is that **complexity is anything that prevents local
reasoning**, and that the dominant source of it is the _incidental data
structure_ — "a data structure where there is no object representing the
structure as a whole". A UI is unusually prone to this: view state accretes as
loose locals, hierarchy hides inside element types, and every backend grows its
own copy of a concept.

A second claim is specific to interfaces: **the UI must not lie.** A button that
looks enabled must work; a state shown must be true. The mechanism is one state
object queried many times, never several independent predicates that can
disagree — which is exactly what happens when three backends each model
selection their own way.

## Ownership & structure (`PRN1`–`PRN4`)

| ID   | Requirement                                                                                                                                                                                                                                                            | Status  | Traces to                                                        |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------- |
| PRN1 | Every collection of parts must be owned by a **Whole** object that defines the structure's invariants and provides its interface. Loose peer variables, or several arrays related only by convention, are not a data structure.                                        | partial | [data-structures](../../research/sean-parent/data-structures.md) |
| PRN2 | Relationships must be represented in preference order **Value > Identity (index/handle) > Reference (pointer) > Container**. Where an index is used, the container that resolves it must be identifiable from the type, and each index must carry exactly one meaning. | partial | [relationships](../../research/sean-parent/relationships.md)     |
| PRN3 | Relationships must be **explicit** — modelled as data the code can run algorithms over — rather than implicit in pointers or recursion buried inside element types. Hierarchy is a flat arena with index links, not nodes containing nodes.                            | full    | `widget.d` `WidgetTree`                                          |
| PRN4 | Struct-of-arrays is permitted and often preferred, **provided a Whole owns the arrays together and holds their correspondence invariant** (equal lengths, index alignment) as a checked class invariant. Parallel arrays with no owner are forbidden.                  | partial | `PRN1`; `contracts.md` `in`/`invariant`                          |

> [!NOTE]
> `PRN2` and `PRN4` are narrower than they may look, and deliberately so. The
> catalog _itself_ writes `size_t parent_index = npos` and _itself_ stores
> components in parallel arrays. Sentinel indices and struct-of-arrays are not
> the defect; the absence of an owner, and one encoding carrying several
> meanings, are.

## Values & states (`PRN5`–`PRN7`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                   | Status      | Traces to                                                                                                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------- |
| PRN5 | **Illegal states must be unrepresentable.** A record whose fields are meaningful only for some value of a `kind` tag must be a sum type instead. This is a hard requirement, not a preference: it is also what makes `==` total, which `PRN6` depends on.                                                     | not started | [human-interface](../../research/sean-parent/human-interface.md); [safety](../../research/sean-parent/safety.md) |
| PRN6 | Widget **props must be Regular** — total, structural `==`, copy-independent — so equality is meaningful. Handlers, delegates and other non-comparable payloads must be excluded from the compared value and addressed by identity instead. A type that is only partially Regular cannot be compared honestly. | not started | [regular-types](../../research/sean-parent/regular-types.md)                                                     |
| PRN7 | Per-frame work must be expressed as **transformations** — pure `f: T -> T` — with a thin action layer that assigns results. Mutating closures over shared local state are not an acceptable substitute.                                                                                                       | not started | [local-reasoning](../../research/sean-parent/local-reasoning.md)                                                 |

## Interface honesty (`PRN8`–`PRN9`)

| ID   | Requirement                                                                                                                                                                                                                                                                                              | Status      | Traces to                                                                                                                          |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| PRN8 | A behavior must have **one definition shared by every backend**, with backends differing only in how they paint it. Independently-written per-backend implementations of one concept are forbidden — _correctness does not compose_, and divergent behavior is the interface lying about the same state. | not started | [local-reasoning](../../research/sean-parent/local-reasoning.md); [human-interface](../../research/sean-parent/human-interface.md) |
| PRN9 | View state must be a **presentation-free model queried by the view**, never derived state cached in a backend. The same model must serve every target — this is the property-model discipline and it is the reason the toolkit can claim "same model, different UIs".                                    | not started | [human-interface](../../research/sean-parent/human-interface.md)                                                                   |

## Discipline (`PRN10`–`PRN12`)

| ID    | Requirement                                                                                                                                                                                                                                               | Status  | Traces to                                                                                                            |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------- |
| PRN10 | Repeated logic must be **lifted into a named algorithm** with stated requirements, guarantees and complexity — not left as an inline loop repeated per call site. Per-frame inner loops may stay raw, but must be named functions with a stated contract. | partial | [algorithms](../../research/sean-parent/algorithms.md); [cpp-seasoning](../../research/sean-parent/cpp-seasoning.md) |
| PRN11 | Invariants and preconditions must be expressed as **narrow contracts** in `in`/`out`/`invariant` blocks (compiled out in release), and the lifted pure algorithms of `PRN10` must be covered by **property-based tests** rather than examples alone.      | partial | [contracts](../../research/sean-parent/contracts.md)                                                                 |
| PRN12 | Runtime polymorphism in the widget representation must **not** use heap-allocating type erasure. A closed sum type over an arena is the required shape — it also delivers `PRN5`'s exhaustiveness and `PRN6`'s total equality.                            | partial | [value-semantics](../../research/sean-parent/value-semantics.md)                                                     |

> [!NOTE]
> `PRN12` is the catalog agreeing with itself: type erasure is recommended for
> small interfaces, and explicitly _not_ recommended where no-heap performance is
> critical or the interface is large. A per-frame widget tree is both.

## Known violations being retired

These are the concrete defects the requirements above were written against. Each
is owned by a migration milestone in [migration.md](./migration.md).

| Violation                                                                                    | Rule breached  |
| -------------------------------------------------------------------------------------------- | -------------- |
| A frame loop holding ~40 peer locals and mutating closures, with no view-state object        | `PRN1`, `PRN7` |
| Records reaching into arrays owned by other objects via sentinel indices with three meanings | `PRN2`         |
| A tagged record whose own documentation says only the `kind`-named fields carry meaning      | `PRN5`         |
| Parallel arrays declared in several places with no owner and no length invariant             | `PRN4`         |
| One visual concept implemented separately per backend, with divergent behavior               | `PRN8`         |
| One interaction (selection) modelled three incompatible ways                                 | `PRN8`, `PRN9` |
| Transient state as bare counters advanced by hand at each call site                          | `PRN5`, `PRN7` |

## Module coverage

These requirements are cross-cutting: they bind every module in `libs/ui`,
`libs/input`, the backend adapters, and any consumer building a widget tree.
Per-module tracing lives in the sibling specs; this page is the rule set they
share.

## Relationship to existing specs

| Piece                                                      | Role                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------ |
| [Sean Parent catalog](../../research/sean-parent/index.md) | the evidence base these rules are drawn from                 |
| [widgets.md](./widgets.md) `WGT`/`VMD`                     | where `PRN5`, `PRN6`, `PRN9` and `PRN12` are discharged      |
| [state-machines.md](./state-machines.md) `STM`             | where `PRN7` and `PRN9` are discharged                       |
| [backends.md](./backends.md) `TGT`                         | where `PRN8` is enforced — one definition, per-backend paint |
| [Code style](../../guidelines/code-style.md)               | the D-level conventions these rules sit above                |

→ [Overview](./index.md) · [Layout](./layout.md) · [Widgets](./widgets.md) · [Migration](./migration.md)
