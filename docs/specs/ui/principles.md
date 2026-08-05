# `sparkles:ui` architectural principles — Requirements (`PRN`)

_**Status:** binding · **Date:** 2026-08-05 · **Scope:** the architectural rules
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

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Status  | Traces to                                                        |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------- |
| PRN1 | Every collection of related parts must have a **Whole** object that defines the structure's invariants and provides its interface. For a mutable value-like Whole, copies must be logically disjoint; immutable sharing, explicit borrowing, or exclusive ownership are permitted only when that policy is visible in the type. A struct merely containing mutable slices is not by itself an owner. Loose peer variables, or several arrays related only by convention, are not a data structure. | partial | [data-structures](../../research/sean-parent/data-structures.md) |
| PRN2 | Relationships must be represented in preference order **Value > Identity (index/handle) > Reference (pointer) > Container**. Where an index is used, the container that resolves it must be identifiable from the type, and each index must carry exactly one meaning.                                                                                                                                                                                                                             | partial | [relationships](../../research/sean-parent/relationships.md)     |
| PRN3 | Relationships must be **explicit** — modelled as data the code can run algorithms over — rather than implicit in pointers or recursion buried inside element types. Hierarchy is a flat arena with index links, not nodes containing nodes.                                                                                                                                                                                                                                                        | full    | `widget.d` `WidgetTree`                                          |
| PRN4 | Struct-of-arrays is permitted and often preferred, **provided one Whole owns or explicitly borrows the arrays together**, declares its copy/alias policy under `PRN1`, and holds their correspondence invariant (equal lengths, index alignment) as a checked invariant. Parallel arrays with no owner are forbidden.                                                                                                                                                                              | partial | `PRN1`; [contracts](../../research/sean-parent/contracts.md)     |

> [!NOTE]
> `PRN2` and `PRN4` are narrower than they may look, and deliberately so. The
> catalog _itself_ writes `size_t parent_index = npos` and _itself_ stores
> components in parallel arrays. Sentinel indices and struct-of-arrays are not
> the defect; the absence of an owner, and one encoding carrying several
> meanings, are.

## Values & states (`PRN5`–`PRN7`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Status  | Traces to                                                                                                        |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------- |
| PRN5 | **Illegal semantic states must be unrepresentable.** A record whose fields are meaningful only for some value of a `kind` tag must be a sum type instead. The sum guarantees that only the active payload exists and makes handling exhaustive; it does **not** by itself make `==` total — every alternative must separately meet `PRN6`.                                                                                                                                                                 | partial | [human-interface](../../research/sean-parent/human-interface.md); [safety](../../research/sean-parent/safety.md) |
| PRN6 | UI objects that claim **value semantics** — props, state-machine values, presentation-free models and mutable Wholes — must be Regular: `==` is total and substitutive, and copies are independent. Borrowed immutable views must declare their equality and lifetime semantics. Handlers, delegates, resource handles and other non-comparable payloads stay outside the compared value and are addressed by identity or an explicit owner instead. A partially Regular type cannot be compared honestly. | partial | [regular-types](../../research/sean-parent/regular-types.md)                                                     |
| PRN7 | Per-frame **state transitions** must be transformations — pure `step(state, input) -> state` functions — with a thin action layer that assigns the result. Other derived work may be a pure projection `T -> U`; painting, native input and I/O are explicit action boundaries. Mutating closures over shared local state are not an acceptable substitute for a transition.                                                                                                                               | partial | [local-reasoning](../../research/sean-parent/local-reasoning.md)                                                 |

## Interface honesty (`PRN8`–`PRN9`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Status  | Traces to                                                                                                                          |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| PRN8 | A semantic behavior must have **one backend-independent definition** wherever a target declares that capability. Backends may paint and measure differently, translate native input into the shared vocabulary, and report declared degradation; they must not duplicate the semantic state or transition. Independently-written semantic implementations of one concept are forbidden — _correctness does not compose_, and divergent behavior makes the interface lie about the same state. | partial | [local-reasoning](../../research/sean-parent/local-reasoning.md); [human-interface](../../research/sean-parent/human-interface.md) |
| PRN9 | Semantic view state must be a **presentation-free model queried by the view**, never a second opinion cached in a backend. The same model serves every target. Device caches — glyph atlases, the prior terminal grid, native input edges — are permitted when they contain no semantic state and are derived or invalidated from explicit inputs. This property-model discipline is what makes "same model, different UIs" true.                                                             | partial | [human-interface](../../research/sean-parent/human-interface.md)                                                                   |

## Discipline (`PRN10`–`PRN12`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                     | Status  | Traces to                                                                                                                     |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------- |
| PRN10 | A loop is **raw** when it appears inside a function whose purpose is broader than the algorithm the loop implements. Such loops, and repeated logic generally, must be lifted into one named algorithm with stated requirements, guarantees and complexity. A per-frame inner loop may remain inside that named algorithm; it is not raw once the function's whole purpose and contract are the loop's operation.               | partial | [algorithms](../../research/sean-parent/algorithms.md); [cpp-seasoning](../../research/sean-parent/cpp-seasoning.md)          |
| PRN11 | Internal programmer obligations must be expressed as **narrow contracts** in `in`/`out`/`invariant` blocks — preconditions, postconditions and invariants, compiled out in release. Invalid user, terminal, network or file input is runtime validation and must not be hidden in a release-elided contract. The lifted pure algorithms of `PRN10` must be covered by **property-based tests** in addition to focused examples. | partial | [contracts](../../research/sean-parent/contracts.md)                                                                          |
| PRN12 | The widget representation is a finite, **closed sum type over a flat arena**, not a class hierarchy or heap-allocating type erasure. This is a Sparkles decision: the closed vocabulary makes backend handling exhaustive and preserves the steady-state no-allocation path. The sum supplies `PRN5`'s active-payload and exhaustiveness guarantees; total equality still requires every alternative to satisfy `PRN6`.         | partial | [value-semantics](../../research/sean-parent/value-semantics.md); [`WGT3`](./widgets.md); [`NFR2`](./feature-requirements.md) |

> [!NOTE]
> `PRN12` is a project decision made with the catalog's trade-offs in view, not a
> rejection of type erasure in general. Parent's value-semantic erasure is the
> right shape for open, small interfaces and can use a small-buffer optimization.
> The widget payload is different: its vocabulary is deliberately closed, every
> backend must handle every alternative, and `NFR2` requires a steady-state
> no-allocation path. Those local constraints select the sum.

## Known failures and open gaps

These are the concrete defects the requirements above were written against.
Open gaps have canonical issue entries; resolved cases remain here as regression
rationale rather than as untracked work.

| Violation                                                                                    | Rule breached   | Tracking                                         |
| -------------------------------------------------------------------------------------------- | --------------- | ------------------------------------------------ |
| A frame loop holding peer state groups and mutating closures, with no GUI-state Whole        | `PRN1`, `PRN7`  | [`HUE-O1`](../hue/open-issues.md#hue-o1)         |
| A value-like Whole containing mutable slices whose default copies alias                      | `PRN1`, `PRN6`  | [`UI-O1`](./open-issues.md#ui-o1)                |
| Records reaching into arrays owned by other objects via sentinel indices with three meanings | `PRN2`          | historical migration failure                     |
| A tagged record whose own documentation says only the `kind`-named fields carry meaning      | `PRN5`, `PRN12` | [`UI-O2`](./open-issues.md#ui-o2)                |
| Parallel arrays declared in several places with no owner and no length invariant             | `PRN4`          | historical migration failure                     |
| One semantic behavior implemented separately per backend, with divergent results             | `PRN8`          | resolved by `MIG12`; retained as regression case |
| One interaction (selection) modelled three incompatible ways                                 | `PRN8`, `PRN9`  | resolved by `STM3`; retained as regression case  |
| Transient state as bare counters advanced by hand at each call site                          | `PRN5`, `PRN7`  | resolved by `STM6`; retained as regression case  |

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
| [backends.md](./backends.md) `TGT`                         | where `PRN8` is enforced — shared semantics, adapted targets |
| [Open issues](./open-issues.md)                            | implementation gaps deliberately deferred by this docs pass  |
| [Code style](../../guidelines/code-style.md)               | the D-level conventions these rules sit above                |

→ [Overview](./index.md) · [Layout](./layout.md) · [Widgets](./widgets.md) · [Migration](./migration.md)
