# UI Component Authoring

How `sparkles:ui` components are written: an expression-based, JSX- or
Flutter-like surface with the feel of a per-frame pure function (functional,
immediate-mode) over a retained foundation, and the order in which that surface
builds the frame's tree. The study is a set of compile-and-run experiments, not
a survey of other frameworks: seven builders over the same views, the compiler
behaviour each depends on, and their measured cost. The prior art they draw on
is catalogued elsewhere — [Solid's components][solid-components],
[Flutter][flutter] and [Jetpack Compose][compose] in the reactive-programming
catalog, [Clay][clay-layout] in the layout catalog, and
[immediate mode at scale][imlv] in the virtualization catalog.

This study answers seven questions:

1. **What does a component look like, and what is it allowed to do?** — the
   [decisions](#decisions), UI-Q1 to UI-Q8.
2. **Which authoring surfaces were tried, and what does each one cost the
   author?** — the [master catalog](#master-catalog) and the
   [comparison of the alternatives](#the-alternatives).
3. **In what order is the tree built, and how is identity derived?** — the
   [taxonomy](#taxonomy) and [lazy variadic children](#lazy-variadic-children-ui-q7).
4. **What does each builder cost per node, and where does the time go?** —
   [build cost](#build-cost).
5. **Is a fit size computed at close cheaper than a separate pass, and does a
   structure-of-arrays or SIMD layout change that?** — [the fit pass](#the-fit-pass).
6. **Which primitives does the builder need, and how does a widget get a
   layout of its own?** — [primitives and custom layouts](#primitives-and-custom-layouts-ui-q8).
7. **Which compiler and tooling defects did the experiments hit?** —
   [defects found](#defects-found).

The decisions are specified as requirements in
[`sparkles:ui` component authoring](../../specs/ui/authoring.md) (`AUT`).

**Last reviewed:** November 26, 2026

> [!NOTE]
> Every experiment is a dub package or a single-file program under
> [`experiments/`](./experiments/ui-api-demo-lazy/README.md), with its own
> README holding the commands, the full output and the raw tables. None of
> them is a root `subPackage`, a standalone example the `ci` helper runs, or a
> page of this site: they are kept as evidence, built by hand. The
> [lazy-variadic](#lazy-variadic-children-ui-q7) experiments need the
> toolchain described in [the requirement](#the-compiler-requirement).

---

## The question

`sparkles:ui` wants the authoring model of an immediate-mode toolkit — a view
is a function of the application's state, called every frame, with no widget
objects to create, mutate or tear down — on top of the retained structures a
large view cannot do without: a measure cache, a height index for
virtualisation, an identity-keyed store for presentation state
([immediate mode at scale][imlv] measures why). Two choices follow, and they
interact:

- **The surface.** A view written as one expression, nested like JSX or a
  Flutter widget tree (`ui.column(children: …)`), or as statements under scopes
  (`with (ui.column()) { … }`), or in a markup language of its own.
- **The build order.** _Inside-out_: D evaluates arguments before the call, so
  children are built before the parent that holds them, and a parent's context
  (density, `disabled`, the message mapping in force) is unknown while they are
  built. _Top-down_: the parent opens first, sets context, and closes after its
  children, as [Clay][clay-layout]'s `CLAY()` macro does — which in D needs the
  children to be deferred, as scopes, delegates or generated code.

The experiments ran the same views through each combination: the file-set
explorer's Stats pane (a heading row, a toggle, a number field, a conditional
status line, a keyed list of members, a density-dependent hint) placed three
ways under an explorer root; and, for the benchmark, the same pane with up to
10⁵ rows and a binary tree of nested panels up to 114 684 nodes.

---

## Decisions

The owner's design sessions settled the model in eight decisions. They are
recorded here as decided; the experiments below are the evidence for the last
three.

| Id    | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Evidence                                                                                         |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| UI-Q1 | Components are pure per-frame functions over `const` state. Cells are read at the edges. Memoisation never changes output. Lifecycle is a per-frame set difference of identities. Handlers yield messages.                                                                                                                                                                                                                                                                                                                                                | [Solid][solid-components], [Flutter][flutter]                                                    |
| UI-Q2 | Attributes are named-only, enforced by a leading `NamedOnly` sentinel; children go in `children:`; `Node.none` keeps its slot, so the siblings after it keep their identity; lists go through `toUi(ui).mapKeyed!(key, row)` or `mapByIndex`; text is `ui.text(i"…")`, interned into a `TextPool`.                                                                                                                                                                                                                                                        | [`ui-api-demo`][x-insideout-readme]                                                              |
| UI-Q3 | Virtualisation runs over a retained tree and height index.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [immediate mode at scale][imlv]                                                                  |
| UI-Q4 | Messages are erased `MsgRef`s made by `ui.on`; a subtree's messages are lifted by `ui.mapMsg!`; dispatch runs against the last frame's tree.                                                                                                                                                                                                                                                                                                                                                                                                              | [`ui-api-demo`][x-insideout-readme]                                                              |
| UI-Q5 | Domain state lives in the application; presentation state machines live in an identity-keyed element store; there are no hooks.                                                                                                                                                                                                                                                                                                                                                                                                                           | [Flutter][flutter], [Compose][compose]                                                           |
| UI-Q6 | Composites that need their parent's context are deferred: a value form (`componentForm`) and `ui.place`. **Superseded by UI-Q7.**                                                                                                                                                                                                                                                                                                                                                                                                                         | [`ui-api-demo`][x-insideout-readme]                                                              |
| UI-Q7 | Children are D lazy variadics, `scope Node delegate() @safe pure nothrow @nogc[] children...`, built top-down with a Clay-style children stack. Identity is the parent's id mixed with the argument position, and the key in keyed lists. A subtree as a value is a `scope` delegate. It requires the frontend fix for `scope` lazy variadic closures ([the requirement](#the-compiler-requirement)).                                                                                                                                                     | [`ui-api-demo-lazy`][x-lazy], [build cost](#build-cost)                                          |
| UI-Q8 | The primitive set is pure: `box` and `text`, plus the `image` and `custom` escape hatches; there are no hybrid widget primitives. A widget such as a toggle is a composite of boxes and text that declares its semantics (`Sem`: role, checked, focusable, merge). A custom layout is `box(custom: ui.layout(Params))`, where `Params` is plain data with static `measure` (constraints → size) and `arrange` (positions each child from its fit size and its `LayoutData`); non-interactive ink is a paint-only leaf, `ui.custom(paint: ui.painter(P))`. | [`ui-primitives`][x-prim], [primitives and custom layouts](#primitives-and-custom-layouts-ui-q8) |

**Deferred:** the hot/cold split of the layout record (`lazy-split`). It is
re-benchmarked and decided once `libs/ui` and the rest of the codebase are
migrated to the new builder, because the layout passes may change
substantially from what these experiments model. Pure per-field structure of
arrays (`lazy-soa`) measured slower than the split and is not a candidate.

### What UI-Q7 changes

Against UI-Q2 to UI-Q6 as the inside-out sketch implemented them:

- **It keeps the UI-Q2 expression surface.** Views stay `=>` expressions with
  ternaries and `Node.none`, `mapKeyed`, `mapMsg!fn(child)`; only the brackets
  go (`children: a, b, c` instead of `children: [a, b, c]`).
- **It removes the deferred machinery.** No `componentForm`, no `Composite`,
  no `ui.place`, no argument arena for composites and no `@trusted` contract
  that "the frame outlives the arguments" ([`ui-api-demo/ui_sketch.d`][x-insideout-sketch],
  `place`). There is one way to call a composite: `statsPane(ui, …)` inside a
  compact column is built compact, because the column has opened when its lazy
  child runs.
- **It moves the message check** from an end-of-frame walk to `ui.on`, while
  the enclosing `mapMsg` is open: still run time, debug builds only, but at the
  node that sends.
- **A subtree as a value is a `scope` delegate** (`scope ChildFn names = () =>
…`), built where it is placed, under that place's context, with that place's
  identity.
- **The parent opens, pushes context, evaluates its children in order,
  computes its fit size at close** from the children stack's contiguous run,
  copies the run into a children table and pops it.

---

## Master catalog

One row per experiment. "Order" is the build order; "message check" says when
a subtree sending the wrong message type is caught.

| Experiment                                        | Surface                                                                                                 | Order                                        | Message check                                            | Subtree as value                          | Compiler          | Link                         |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | -------------------------------------------- | -------------------------------------------------------- | ----------------------------------------- | ----------------- | ---------------------------- |
| **Inside-out** (`ui-api-demo`)                    | expressions, `children: [ … ]`; value forms + `ui.place` for context                                    | inside-out, deferred `expand`                | end-of-frame walk (run time)                             | value form (`Composite`), POD             | stock             | [README][x-insideout-readme] |
| **Clay scope probe** (`clay-style`)               | `with (ui.column(…)) { … }`, a handle closing in `~this() scope`                                        | top-down                                     | —                                                        | —                                         | stock             | [README][x-claystyle]        |
| **Scoped `with`** (`ui-api-demo-scoped`)          | statements under `with`; `Ui!M` typed by its message                                                    | top-down                                     | **compile time** (run-time backstop for an outer handle) | lambda slot, value form, recorded subtree | stock (DMD 2.115) | [README][x-scoped]           |
| **Markup DSL** (`ui-api-demo-markup`)             | `mixin(markup!q{ column { … } })`, a CTFE parser                                                        | top-down                                     | **compile time**, at the markup line                     | `scope` fragment delegate                 | stock (DMD 2.115) | [README][x-markup]           |
| **Lazy-variadic probes** (`lazy-variadic`)        | `ui.column(children: a, b)` over lazy variadics                                                         | top-down                                     | —                                                        | `scope` delegate                          | **fixed**         | [README][x-lazyprobe]        |
| **Lazy variadic** (`ui-api-demo-lazy`)            | the UI-Q2 expressions, children lazy                                                                    | top-down, linked children                    | at `ui.on` (run time, debug)                             | `scope` delegate                          | **fixed**         | [README][x-lazy]             |
| **Lazy + children stack** (`lazy-stack`)          | as above                                                                                                | top-down, children stack                     | at `ui.on` (run time, debug)                             | `scope` delegate                          | **fixed**         | [`lazystack.d`][x-lazystack] |
| **Lazy + split / SoA** (`lazy-split`, `lazy-soa`) | as above                                                                                                | top-down, children stack                     | as above                                                 | as above                                  | **fixed**         | [`lazysplit.d`][x-lazysplit] |
| **Clay** via ImportC (`bench/clay`)               | `with (ui.column(…)) { … }` over `Clay__OpenElement`/`Clay__CloseElement`                               | top-down, children stack                     | none (Clay has no messages)                              | —                                         | stock             | [`clayui.d`][x-clayui]       |
| **Fit-pass benchmark** (`layout-fit-bench`)       | a replayed event stream (no surface)                                                                    | fused vs separate fit                        | —                                                        | —                                         | stock             | [README][x-fit]              |
| **Primitives** (`ui-primitives`)                  | the UI-Q7 surface over `box`/`text` (pure) or with four widget kinds (hybrid); custom layouts four ways | top-down, children stack, then a layout pass | at `ui.on` (run time, debug)                             | `scope` delegate                          | **fixed**         | [README][x-prim]             |

---

## Taxonomy

### By build order

| Order                                | How the parent's context reaches children                                                                                        | Experiments                                                     |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Inside-out                           | It does not: children are built first. Context-dependent composites are deferred (`ui.place`) and built by a later `expand` pass | [inside-out][x-insideout-readme]                                |
| Top-down, scope per element          | The scope opens before its body runs; a destructor closes                                                                        | [scoped `with`][x-scoped], [Clay probe][x-claystyle], Clay      |
| Top-down, generated statements       | The generator emits the same open/close around each element                                                                      | [markup][x-markup]                                              |
| Top-down, children as lazy arguments | The callee opens, then calls each child delegate                                                                                 | [lazy variadic][x-lazy], `lazy-stack`, `lazy-split`, `lazy-soa` |

### By identity scheme

| Scheme                                                 | Shifts on an `if` elsewhere?                        | Cost per node                           | Experiments                |
| ------------------------------------------------------ | --------------------------------------------------- | --------------------------------------- | -------------------------- |
| Parent id × argument position (× key in a keyed list)  | no: `Node.none` keeps the slot                      | one mix                                 | [lazy][x-lazy], inside-out |
| Parent id × hash of `__FILE__`/`__LINE__` × occurrence | no; a repeated call site (a `foreach`) needs `key:` | a site hash plus a sibling scan (debug) | [scoped `with`][x-scoped]  |
| Parent id × compile-time `file:line:column` constant   | no; keys are mandatory in the grammar               | one mix                                 | [markup][x-markup]         |
| Clay: 32-bit hash of sibling index and parent id       | yes: an inserted sibling renumbers the rest         | a hash-map insert per element           | Clay                       |

`__traits(getLocation)` and default-argument `__LINE__` give the caller's line
but never its column; only a lambda written at the call site carries a column,
so the scoped builder's identity is line-granular
([`site_probe.d`][x-siteprobe], scoped README § 2).

### By when a wrong message type is caught

| When                         | Mechanism                                                                                        | Experiments           |
| ---------------------------- | ------------------------------------------------------------------------------------------------ | --------------------- |
| Compile time                 | the builder carries the message type (`Ui!StatsMsg`), or the generator sees the `mapMsg` nesting | scoped `with`, markup |
| Run time, at `ui.on` (debug) | the open `mapMsg` scope's key is compared with the sent type                                     | lazy variadic         |
| Run time, end of frame       | a walk over the built tree                                                                       | inside-out            |

A typed `Node!M` would move the lazy builder's check to compile time only if
every container names `M` (`ui.column!StatsMsg(…)`) and every leaf is typed:
IFTI does not infer `M` through a lazy variadic
([`typed_node.d`][x-typednode]). It was not adopted.

---

## The alternatives

### Inside-out (UI-Q2–UI-Q6)

[`ui-api-demo`][x-insideout-readme]. The surface the decisions first agreed:
`ui.Column(gap: 1, children: [ … ])`, everything an expression.

- **For:** the plainest D — every call builds its node now; one record write
  per node with all children known, the cheapest builder measured (below);
  nothing can be built in the wrong place.
- **Against:** a child cannot see its parent's context, so a composite whose
  structure depends on it must be written twice (`componentForm` generates the
  value form) and placed through `ui.place`, which copies its arguments into
  the frame arena under a `@trusted` contract that the frame outlives them;
  an extra `expand` pass builds the deferred composites; two ways to call
  every composite; the message check is an end-of-frame walk.

### Lazy variadic, linked children

[`ui-api-demo-lazy`][x-lazy]. The UI-Q2 surface with `children` a `scope`
lazy variadic: the compiler wraps each argument in a delegate literal, and the
callee opens, evaluates, closes.

- **For:** keeps the expression surface, removes every deferred mechanism
  ([what UI-Q7 changes](#what-ui-q7-changes)); identity needs no call-site
  information; a subtree value is a `scope` delegate that can be stored,
  passed (`card(content:)`) and placed in one of two places.
- **Against:** `@nogc` needs the [compiler fix](#the-compiler-requirement); a
  `Node` expression outside a children slot (a local in a view body) builds
  immediately, in the wrong place, and type-checks — only a debug check
  (`slotAlreadyTaken`, `childBuiltOutsideSlot`) reports it; `children:` must be
  required by a second sentinel just before the variadic, or a positional
  argument after the last attribute silently becomes a child; linked children
  update two earlier records per node, ~1.3–1.6× inside-out's cost.

### Lazy variadic + children stack (UI-Q7)

[`lazystack.d`][x-lazystack]. The same surface over Clay's children stack: a
closed child pushes `Pending{node, w, h}`; the parent's `close` reduces its
contiguous run for the fit size, copies the indices into a `kids` table and
pops. No earlier record is updated; a leaf appends and pushes without an
open/close round trip; the record shrinks from 160 to 152 bytes.

- **For:** everything the linked variant gives, at or below inside-out's cost
  on leaf-heavy trees (−5 to −13 % with `HeapBuffer`).
- **Against:** still ~+5 ns/node over inside-out on container-heavy trees with
  plain arrays — the per-container open-stack push, run copy and context
  save/restore; `open`/`close`/`leaf` must be `pragma(inline, true)` or the
  panel tree costs another 5–7 ns/node.

### Lazy + hot/cold split, lazy + SoA

[`lazysplit.d`][x-lazysplit], [`lazysoa.d`][x-lazysoa]. The children-stack
builder with the layout fields (parent, kid range, gap, kind, fit size,
position) moved out of the record: one 36-byte hot record beside a 136-byte
cold one (`lazy-split`), or one array per field (`lazy-soa`). A `place` pass —
each container positions its children from their fit sizes and gap — measures
what a later layout pass gains.

- **Split, for:** the `place` pass runs 1.3–1.9× faster than over the
  152-byte record on plain arrays; the build costs at most +1 ns/node.
- **SoA, against:** nine append streams cost +2–6 ns/node to build, and in
  `place` each child touches four arrays where the split record needs one cache
  line: the access pattern is per node, all fields — a hot _record_.
- **Status:** [deferred](#decisions).

### Scoped `with`

[`ui-api-demo-scoped`][x-scoped]. `with (ui.column(gap: 1)) { … }` opens an
element; the non-copyable handle's `~this() scope` closes it, computing the fit
size from its children. The first probe, [`clay-style/scoped2.d`][x-scoped2],
showed that Clay's open/close maps onto D this way, early `return` included.

- **For:** plain D control flow (`if`, `foreach`, early `return`) with no
  `Node.none` or `mapKeyed`; the message check at **compile time**, because
  `with (auto stats = ui.mapMsg!liftStats)` yields the builder retyped as
  `Ui!StatsMsg` and a pane declares `ref Ui!StatsMsg`; works on stock
  compilers.
- **Against:** a view is statements, so a subtree value is a function (a
  lambda slot, a value form) or a recorded subtree that re-creates the
  inside-out context problem; identity from `__FILE__`/`__LINE__` is
  line-granular, so reusable composites forward `file`/`line` and two keyless
  calls on one line collide; `ui.column();` alone opens and closes an empty
  element unless `@mustuse` rejects it, and a multi-statement `with` body
  without braces nests only its first statement; the outer `ui` stays visible
  inside a `mapMsg` scope (a run-time check); every generic helper becomes a
  template over `M`; the most expensive builder measured.

### Markup DSL

[`ui-api-demo-markup`][x-markup]. `mixin(markup!q{ column(gap: 1) { label(…); } })`:
a ~700-line CTFE lexer and recursive-descent generator emitting the scoped
builder's statements, attribute expressions spliced verbatim.

- **For:** reads like JSX; `if`/`foreach` (with a mandatory `key:`) in the
  grammar; ids are compile-time `file:line:column` constants; the message type
  is checked at **compile time** at the offending markup line, because the
  generator sees the `mapMsg` nesting; `@safe pure nothrow @nogc` throughout.
- **Against:** a second language to maintain, stopping at its first error;
  no completion, navigation, rename or formatting inside `q{}`; errors name a
  `file-mixin-L` pseudo-file; ~4.5 ms and ~1.1 MiB of CTFE per Stats-pane-sized
  markup (200 panes: 1.22 s with DMD against 0.34 s pre-expanded); the `ui.on`
  rewrite is textual; it depends on _avoiding_ a frontend bug in `#line`
  ([defects](#defects-found)).

### Clay

[`bench/clay/`][x-clayui]. Clay itself ([`clay.h`][clay-h] at `e6cc369`),
compiled by ImportC and driven from D through a `with` scope whose destructor
calls `Clay__CloseElement`, building the same trees with fixed-size leaves.

- **For:** the children stack (what `lazy-stack` took from it) and a fit size
  computed at close ([`Clay__CloseElement`][clay-close]).
- **Against, measured:** ~2× `lazy-stack`'s time per node for _fewer_
  instructions (482 against 578 in the panel tree), at under half the IPC
  (1.7 against 4.2): 312-byte [`Clay_LayoutElement`][clay-element] records and
  272-byte declarations copied by value, ~1.3 KB written per element, 34
  failed store-to-load forwards per node, and a hash-map insert per element
  ([`Clay__AddHashMapItem`][clay-hashmap]: a divide and a random bucket walk).
  `Clay_EndLayout` costs ~0.8× the build again. Its child count is a
  `uint16_t` and its auto ids are 32-bit ([defects](#defects-found)). Nothing
  inlines across the C boundary; it has no messages, text interning or context
  propagation to pay for.

---

## Lazy variadic children (UI-Q7)

The Stats pane as the decided surface writes it
([`ui-api-demo-lazy/app.d`][x-lazy-app]):

```d
Node statsPane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
    => ui.column(gap: ui.env.density == Density.compact ? 0 : 1, children:
        ui.row(gap: 2, children:
            ui.label(slot: Slot.heading, text: "Stats"),
            ui.toggle(on: s.hashOnEdit, label: "hash on edit",
                onPress: ui.on(StatsMsg(ToggleHash()))),
            ui.numberField(value: s.debounceMs, unit: "ms",
                onChange: ui.on!((int v) => StatsMsg(SetDebounce(v)))),
        ),
        ids.computing
            ? ui.label(slot: Slot.dim, text: ui.text(i"computing… (query $(ids.query))"))
            : Node.none,
        ids.rows
            .toUi(ui)
            .mapKeyed!(
                r => r.name,
                r => ui.keyValue(name: r.name, value: r.value,
                    onPress: ui.on(StatsMsg(CopyName(r.name)))),
            ),
        ui.env.density == Density.comfortable
            ? ui.label(slot: Slot.dim, text: "click a name to copy it")
            : Node.none,
    );
```

The primitive behind it ([`ui-api-demo-lazy/ui_sketch.d`][x-lazy-sketch]):

```d
alias ChildFn = Node delegate() @safe pure nothrow @nogc;
Node column(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, bool disabled = false,
    EnvOverride env = EnvOverride.init, NamedOnly _children = NamedOnly.init,
    scope ChildFn[] children...) @safe pure nothrow @nogc
```

An attribute expression (`gap: ui.env.density …`) is an ordinary argument,
evaluated before the column opens, so it reads the context of the slot the
column sits in; the children read the context after it opened. `mapKeyed`
splices its rows into the one argument position it occupies, so for layout the
rows are the column's own children, as in Clay. The dump of
[`out/app-ldc.txt`][x-lazy-out] shows the pane under the compact column built
`[compact] disabled`, without the hint label, and every later sibling keeping
its argument position whether or not `computing` shows.

### The compiler requirement

> [!IMPORTANT]
> The lazy-variadic code needs a D frontend in which a `scope` lazy variadic
> array of delegates allocates no closure in its caller. That is the fix for
> [dlang/dmd#22885][dmd-22885], carried by the sparkles DMD and LDC forks as
> UD8 and UL20 and tracked in `docs/specs/toolchain/upstreaming.md` on branch
> `build/scope-lazy-variadic-toolchain`, whose flake lock builds both
> compilers. Until that branch is merged, build these experiments in its
> development shell, or with compilers patched the same way.

The D specification's own [best practice][spec-lazy-variadic] says that
`scope` on a lazy variadic array prevents the closure; stock DMD 2.115 and
LDC 1.43 allocate one anyway, so every view with a child slot fails `@nogc`
([`out/stock-ldc.txt`][x-lazy-stock]):

```text
app.d(30,6): Error: function `app.statsPane` is `@nogc` yet allocates closure for `statsPane()` with the GC
```

Without `@nogc` it compiles and allocates a closure per view call per frame.
[`lazy-variadic/min.d`][x-min] reduces it to five lines.

---

## Build cost

The benchmark ([`ui-api-demo-lazy/bench/`][x-bench]) builds the same two views
with every builder — the Stats pane with N `keyValue` rows (`rows=N`, 7 + N
nodes) and a binary tree of panels, each `column{label, toggle,
row{panel, panel}}` (`depth=D`) — with the same node contents, fit computation,
messages and texts. Every iteration is verified untimed: node count and a
pre-order checksum of (kind, w, h, child count) must equal the reference, and
the builders agree on every tree before the cases register.

- **Machine:** AMD Ryzen 9 7940HX (Zen 4), Linux 6.18; not isolated, load
  average 2–6 from other jobs during the runs.
- **Compiler:** LDC 1.43 with the lazy-variadic patch (and patched DMD 2.115
  for the DMD rows), `-enable-cross-module-inlining -linkonce-templates`, the
  views in their own modules as an application's would be.
- **Build type:** `bench` — optimised, `-mcpu=native -O3`, **assertions
  live**.
- **Runs:** the `sparkles:test-runner` `benchCase` per-call timing, median per
  iteration with perf counters; the first LDC tables were run twice (both
  shown as `run1/run2`, agreeing within ~3 %), the children-stack, split/SoA
  and DMD tables once, the Clay tables twice.
- **Two table configurations:** `HeapBuffer` (the node tables as the
  prototypes use them, `sparkles.base.buffer`'s `HeapBuffer!(T,
Storage.unique)`), and `RawBuf` (bare `malloc`'d arrays in every builder),
  which shows each builder's own cost.

> [!WARNING]
> The `HeapBuffer` columns predate the `HeapBuffer` mutable-access fix on
> branch `fix/base-bench-findings` (`913b992f4`): every mutable `opIndex` went
> through an outlined `ensureUniqueStorage` even for `Storage.unique`. The
> top-down builders index the node table several times per node, so the
> HeapBuffer columns overstate them (lazy ~+610 and scoped ~+1030 instr/node in
> the panel tree, against ~+360 for inside-out). Re-measure once it lands; the
> `RawBuf` columns are unaffected.

### Inside-out, lazy linked, scoped `with`

ns/node `run1/run2` (instructions/node), patched LDC
([`results/tables.md`][x-tables]):

| size        |   nodes |    inside-out HB | lazy-variadic HB |   scoped-with HB |  inside-out Raw | lazy-variadic Raw | scoped-with Raw |
| ----------- | ------: | ---------------: | ---------------: | ---------------: | --------------: | ----------------: | --------------: |
| rows=10     |      17 | 37.7/37.1 (1038) | 54.8/56.0 (1410) | 75.5/76.6 (1930) | 30.1/31.2 (790) |   39.5/41.2 (868) | 50.1/50.1 (960) |
| rows=1000   |    1007 | 43.1/41.7 (1035) | 65.6/64.3 (1435) | 84.9/82.5 (1856) | 38.8/40.0 (819) |   51.4/50.5 (872) | 58.5/58.4 (938) |
| rows=100000 | 100 007 | 45.1/46.3 (1031) | 66.4/66.8 (1435) | 85.0/84.8 (1855) | 42.6/42.7 (816) |   53.0/53.2 (872) | 64.8/64.3 (937) |
| depth=4     |     108 |  27.9/27.7 (669) |  41.5/41.6 (946) | 62.5/61.8 (1448) | 14.9/15.4 (316) |   25.5/25.4 (344) | 30.2/30.1 (421) |
| depth=9     |    3580 |  27.4/27.9 (641) |  44.3/44.2 (920) | 66.6/66.4 (1414) | 15.3/15.5 (284) |   26.5/26.5 (313) | 31.3/31.1 (386) |
| depth=14    | 114 684 |  27.5/29.0 (640) |  43.2/44.3 (919) | 66.5/66.0 (1413) | 15.8/15.7 (283) |   25.2/25.3 (312) | 31.5/31.0 (385) |

On patched DMD (one run) every builder costs 2–3× more, and the lazy builder
loses its LDC advantage over scoped once the buffers are raw (rows=100000:
inside-out 98.7, lazy 122.3, scoped 106.6 ns/node): DMD does not inline the
child delegates, so they stay indirect calls. On LDC they are devirtualised
from the constant array literal and almost all inlined; the cost is the
top-down `open`, which appends a 160-byte record and updates two earlier ones.

### Children stack

One run, patched LDC ([`results/stack-inline-ldc-1.txt`][x-stack-hb],
[`…-rawbuf-1.txt`][x-stack-raw]):

| size        | inside-out HB |     lazy HB | **lazy-stack HB** | inside-out Raw |   lazy Raw | **lazy-stack Raw** |
| ----------- | ------------: | ----------: | ----------------: | -------------: | ---------: | -----------------: |
| rows=10     |   36.5 (1040) | 59.5 (1410) |    **34.8 (964)** |     31.2 (790) | 40.7 (869) |     **33.0 (825)** |
| rows=1000   |   42.4 (1035) | 65.8 (1435) |    **39.9 (905)** |     40.3 (820) | 50.8 (872) |     **40.7 (786)** |
| rows=100000 |   48.8 (1031) | 68.1 (1435) |    **42.3 (904)** |     45.8 (816) | 53.5 (872) |     **42.0 (785)** |
| depth=4     |    27.4 (669) |  43.6 (946) |    **28.9 (606)** |     15.0 (316) | 25.9 (345) |     **20.8 (375)** |
| depth=9     |    28.2 (641) |  44.6 (920) |    **29.9 (576)** |     15.2 (284) | 24.8 (313) |     **20.8 (343)** |
| depth=14    |    27.3 (640) |  45.4 (919) |    **30.4 (575)** |     15.8 (283) | 25.3 (312) |     **21.0 (342)** |

### Split and SoA, and the `place` pass

One run, patched LDC ([`results/soa-ldc-1.txt`][x-soa-hb],
[`…-rawbuf-1.txt`][x-soa-raw]); `place` is timed on a built tree and checked
against `lazy-stack`'s positions:

| pass       | size        |  inside-out | lazy-stack (AoS) | lazy-split |    lazy-soa |
| ---------- | ----------- | ----------: | ---------------: | ---------: | ----------: |
| build, HB  | rows=100000 | 45.1 (1031) |       40.0 (906) | 42.4 (968) | 61.5 (1430) |
| build, HB  | depth=14    |  26.7 (640) |       29.2 (578) | 32.8 (650) | 57.3 (1216) |
| build, Raw | rows=100000 |  42.0 (816) |       40.3 (787) | 41.2 (801) |  44.5 (852) |
| build, Raw | depth=14    |  15.7 (283) |       20.5 (345) | 20.6 (362) |  26.7 (425) |
| place, HB  | rows=100000 |           — |       6.37 (145) |  1.01 (20) |   0.85 (24) |
| place, HB  | depth=14    |           — |       8.36 (189) |  1.43 (27) |   1.95 (36) |
| place, Raw | rows=100000 |           — |        2.03 (24) |  1.05 (20) |   1.10 (23) |
| place, Raw | depth=14    |           — |        2.16 (29) |  1.41 (27) |   1.80 (35) |

The AoS `place` pass with `HeapBuffer` is almost all `ensureUniqueStorage` on
`nodes[c]` (the warning above); split and SoA index raw slices.

### Clay

ns/node `run1/run2` (instructions/node), patched LDC, `HeapBuffer`
configuration ([`results/clay-ldc-1.txt`][x-clay-1]). `clay-build` is
`Clay_BeginLayout` plus every element; `clay-full` adds `Clay_EndLayout`;
`clay-side` adds the per-leaf work Clay does not do (text interning and the
`ui.on` message table). Clay has no `rows=100000` case: its child count wraps.

| size      |   nodes |      clay-build |          clay-full |        clay-side |      lazy-stack |       inside-out |
| --------- | ------: | --------------: | -----------------: | ---------------: | --------------: | ---------------: |
| rows=10   |      17 | 58.9/59.5 (854) |   99.1/99.6 (1593) | 73.7/74.2 (1119) | 34.2/34.2 (966) | 35.9/36.5 (1040) |
| rows=1000 |    1007 | 62.1/61.6 (679) |   99.5/99.8 (1284) | 79.2/79.7 (1049) | 38.0/37.9 (907) | 43.8/42.2 (1035) |
| depth=4   |     108 | 52.4/53.9 (517) |   87.6/90.4 (1219) |  57.5/58.8 (625) | 27.5/28.4 (608) |  26.9/29.0 (669) |
| depth=9   |    3580 | 55.8/57.3 (482) | 100.7/102.0 (1175) |  61.8/61.6 (590) | 28.9/28.7 (578) |  28.7/27.8 (641) |
| depth=14  | 114 684 | 80.6/72.6 (481) | 244.3/237.1 (1175) |  78.6/78.3 (589) | 28.6/28.8 (577) |  27.8/27.7 (640) |

`perf stat` on the panel tree (depth 9, 20 000 frames, build only, per node):
Clay 303 cycles and 475 instructions against `lazy-stack`'s 132 and 567, 53
store-to-load forwards against 17 (34 failed against 13), 8.7 L1d load misses
against 3.5, one integer divide against none. The first frame costs 200–380
ns/node to build (page faults on an arena sized for `maxElementCount`, 80 MiB
for 114 700 elements, and every id inserted into the hash map); steady frames
follow from the second on.

### What remains

- **Per container.** On plain arrays `lazy-stack` is still ~+5 ns/node over
  inside-out in the container-heavy panel tree (21.0 against 15.8 at depth 14,
  ~20 % more instructions): the open-stack push, the run copy into `kids`, and
  the context save and restore, for half of that tree's nodes.
- **The record.** The hottest instructions in `leaf` are the two 64-byte
  stores of the 152-byte record, which every builder shares: the lever the
  deferred split decision pulls.
- **Per leaf, shared by all.** Text interning and `ui.on` (a `SumType`
  construction, an `InSituRegion.allocate` and an array copy) cost ~800
  instructions for a `keyValue` row in every builder and dominate the
  leaf-heavy tree.

---

## The fit pass

Clay computes each element's fit size while the tree is built, at close. The
[fit-pass benchmark][x-fit] ([`fitbench.d`][x-fitbench]) asks whether building
first and then running a separate bottom-up pass — over only the hot layout
fields (SoA), perhaps with SIMD — is cheaper end to end. Every variant replays
the same pre-order event stream (`list`: a five-deep list of rows; `panels`:
random nested panels with fan-out mostly 2–8 and ~10 % of nodes holding
50–1000 children) into a reused buffer of 64-, 128- or 328-byte records (328
bytes is today's `Widget`), and every variant's checksum over the float bits
agrees.

- **Machine:** AMD Ryzen 9 7940HX, pinned to one core (`taskset -c 4`),
  desktop otherwise idle (load ~2).
- **Compiler and build:** stock LDC 1.43 (`-O3 -mcpu=native -release
-boundscheck=off`) and DMD 2.115 (`-O -release -inline -boundscheck=off`):
  measurement builds whose correctness check is the checksum.
- **Runs:** 3 warm-up repetitions, then the median of 31 (LDC) or 21 (DMD)
  full frames, counters from an in-process `perf_event_open` group.

ns/node, LDC, median; `total` is build + fit, the separate pass alone in
parentheses ([`summary-ldc.md`][x-fit-summary]):

| shape  |   N | record | fused-aos | sep-aos (pass) | fused-soa | sep-soa (pass) | level-soa (reduce) | rest-aos | rest-soa |
| ------ | --: | -----: | --------: | -------------: | --------: | -------------: | -----------------: | -------: | -------: |
| list   | 10⁴ |   64 B |      3.49 |    4.41 (1.79) |      4.19 |    5.06 (1.79) |        9.45 (0.90) |     2.79 |     2.65 |
| list   | 10⁴ |  328 B |      6.26 |    7.74 (2.29) |      7.58 |    7.83 (1.75) |       11.95 (0.95) |     5.14 |     2.62 |
| list   | 10⁶ |  328 B |     28.99 |  38.68 (10.57) |     26.80 |   28.02 (2.07) |       32.40 (1.07) |    29.67 |     4.77 |
| panels | 10⁴ |   64 B |      3.42 |    4.97 (2.54) |      4.01 |    5.70 (2.46) |       10.13 (1.22) |     3.10 |     2.91 |
| panels | 10⁴ |  328 B |      6.38 |    8.19 (2.72) |      6.83 |    8.47 (2.43) |       13.05 (1.20) |     4.87 |     2.90 |
| panels | 10⁶ |  328 B |     28.20 |  41.56 (14.49) |     25.82 |   29.27 (3.82) |       38.34 (2.89) |    32.43 |     6.33 |

`rest-*` is the remaining Clay-style passes (grow along x, grow along y,
positions) measured alone. The README holds all 24 configurations and the
counters; rows near the L3 size (10⁵ × 328 B) move by ±20 % between runs.

1. **Fusing the fit into close saves 0.7–1.8 ns/node** in cache, 17–30 % of
   build + fit, for AoS and SoA alike. The separate sweep costs 1.7–2.5
   ns/node, bound by the load → add/max → store chain into the parent; fusion
   adds 0.7–1.0 ns/node to the build. At 10⁴ nodes that is 10–15 µs per frame.
2. **SoA does not make a separate pass as cheap as fusion.** In cache
   `sep-soa` is 1.4–2.4 ns/node slower than `fused-aos`; SoA wins only once the
   fat records leave the cache (from 10⁶ nodes at 64 B, 10⁵ at 328 B).
3. **`fused-soa` keeps nearly all of the fusion win** — within 0.4–1.3
   ns/node of `fused-aos` in cache, and the fastest variant beyond it.
4. **SIMD does not pay.** `level-soa` (a depth counting sort so siblings are
   contiguous, a vectorised per-parent reduction, a scatter back) loses by 4–6
   ns/node: the sort, gather and scatter alone cost more than the scalar sweep,
   the scatter conflicts by construction (every sibling targets one parent),
   and a typical fan-out of 2–4 leaves the lanes empty.
5. **The layout of the data matters more for the top-down passes.** On fat
   AoS records the grow and position passes cost 10–32 ns/node once the
   records leave the cache, against 3.5–6.3 on SoA, a 3–6× factor against
   fusion's ~1.3×. This is the case for keeping hot layout fields out of the
   record, and why the split was measured — and why it waits for the real
   layout passes.

Clay itself fuses only the first estimate:
[`Clay__CalculateFinalLayout`][clay-final] always runs a separate bottom-up
DFS that recomputes heights after text wrapping, and its close re-reads each
child through a child-index buffer rather than keeping accumulators. DMD's
build is 2–3× slower than LDC's, its fit pass about the same.

---

## Primitives and custom layouts (UI-Q8)

The [primitives prototype][x-prim] grows the children-stack builder into a
small toolkit ([`uicore.d`][x-prim-core]: one `box` with Clay-style config
structs, the measured `text` leaf, `image`, paint-only `custom`, a top-down
layout pass, hit testing, semantics and dispatch) and asks two questions of
it. The same application — the Stats pane and a settings page of 8 toggles, 8
number fields, a text field, 3 buttons and a 1000-row virtual list — is mixed
verbatim into two widget libraries: **pure**, where every widget is a
composite of boxes and text, and **hybrid**, where `toggle`, `textInput`,
`scrollView` and `virtualList` are core kinds.

- **Machine and build:** a 32-core host at load average 3–5; `-b bench`
  (assertions live) with `--perf`, the patched LDC 1.43 and DMD 2.115 of
  [the requirement](#the-compiler-requirement); two LDC runs and one DMD run.
  DMD and LDC print byte-identical demo output.
- **Tests:** 14, on both compilers ([`tests.d`][x-prim-tests]): the pure and
  hybrid settings pages, and every custom layout's coordinates worked by hand.

**Pure against hybrid.** The per-node cost is the same; pure spends more
nodes on a widget-heavy page and nothing measurable on a data-heavy one.

| measure, LDC                     |       pure |     hybrid |
| -------------------------------- | ---------: | ---------: |
| nodes, settings page             |        135 |        106 |
| nodes, Stats pane with 1000 rows |       3012 |       3009 |
| build + layout, settings page    |       6 µs |       4 µs |
| build + layout, Stats pane       | 124–131 µs | 125–130 µs |
| instructions per node, settings  |        769 |        755 |

The semantics trees a backend or a test sees are byte-identical (35 nodes;
`primitives.settings.sameSemantics`), the Tab order is the same, and a press
on a toggle's knob bubbles to the toggle's own box. Each hybrid kind costs a
dozen dispatch sites in the core — 13 for the four kinds, about 120 lines —
which is the "adding a kind silently skips a backend" risk
[`WGT3`](../../specs/ui/widgets.md) names, and an application's own widget can
only ever be a composite. What the hybrid kinds carry is data, and it fits on
the two primitives: the caret on `text`, clip and offset on `box`, role and
checked state in `Sem`.

**Custom layouts.** A clock face, a timeline of lane-stacked events and a
week calendar with overlap columns ([`layouts.d`][x-prim-layouts]) were each
written four ways:

| mechanism                                                                               | places children from their measured size | children are real nodes | verdict                                             |
| --------------------------------------------------------------------------------------- | ---------------------------------------- | ----------------------- | --------------------------------------------------- |
| (a) layout protocol: static `measure`/`arrange` over plain-data params                  | yes                                      | yes                     | **adopted**, the extension point                    |
| (b) build-time placement with floating children (`layoutBuilder`, or last frame's size) | no: the view measures                    | yes                     | rejected: breaks build-then-layout, or lags a frame |
| (c) paint-only leaf: `paint(in P, Rect, ref DrawList)`                                  | —                                        | no: one node            | **adopted**, for ink                                |
| (d) anchored fractions (`Dir.anchor`)                                                   | no                                       | yes                     | optional convenience                                |

Only (a) stacks timeline lanes by measured label width and wraps calendar
titles in their columns; it keeps hit testing, identity, semantics and `memo`
unchanged, because a layout is two function pointers over plain data copied
into the frame. A 10⁴-event timeline lays out in 309–313 µs against
214–220 µs for the same events in a plain column (+79 instructions per node),
because the lane stacking runs in `measure`, again in `arrange` and once more
at close; a measure cache ([`LAY13`](../../specs/ui/layout.md)) would remove
two of the three runs. The README lists the open questions the prototype
leaves (measure-to-arrange state, relayout of a child at another width,
sorted-input contracts, native widgets behind a role).

---

## Defects found

| Defect                                                                                                                                                                                                                                                                                                                                                                                                                                      | Where it is tracked                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| A `scope` lazy variadic array of delegates still allocates a closure in the caller, so `@nogc` views fail. The first patch (clear the closure of every lazy variadic argument) was unsound: every typesafe variadic array is implicitly `scope` for its stack-built array only, so it also dropped the closure of a callee that legally stores its delegates, and `scope` is not transitive, so a `@safe` callee could still store `xs[0]`. | [dlang/dmd#22885][dmd-22885]; UD8/UL20 in `docs/specs/toolchain/upstreaming.md` on `build/scope-lazy-variadic-toolchain` |
| DMD's `-inline` makes a delegate literal (a `lazy` argument included) read a member of a struct temporary after the temporary's destructor ran.                                                                                                                                                                                                                                                                                             | `upstreaming.md` § the UD8 pull request, on the same branch; no upstream issue yet                                       |
| `#line N` inside a string mixin on line L reports line `N + 2·(L−1)`: `BaseLoc.addSubstitution` in `dmd/location.d` subtracts the mixin's start line where it should add it. The markup generator avoids `#line` entirely.                                                                                                                                                                                                                  | Untracked; found by [`probe1.d`][x-probe1] (markup README § 1)                                                           |
| LDC's ImportC: an all-default compound literal of a wrapper struct, unwrapped and passed by value (Clay's [`CLAY__CONFIG_WRAPPER`][clay-wrapper]), is folded to `T.init` and codegen fails with "no init symbol for zero-initialized struct". DMD compiles it.                                                                                                                                                                              | Untracked; worked around in [`clay_impl.c`][x-clayimpl]                                                                  |
| LDC 1.43's frontend inferred `benchCase`'s `timed` and `after` parameters `scope`, missing their escape into the case's closures, so the frame they captured stayed on the stack and was dead when the runner measured (a use-after-return, first misread as the cases not being GC roots).                                                                                                                                                 | Fixed on `fix/base-bench-findings` (`f800ebdf8`); test-runner open issue O14 on that branch                              |
| Clay's element child count is a `uint16_t` ([`Clay__LayoutElementChildren`][clay-children]): 100 003 children wrap to 34 467. Its auto ids are 32-bit hashes of sibling index and parent id ([`Clay__HashNumber`][clay-hashnumber]): 88 collisions per frame among 114 684 elements, resolved by the later element replacing the earlier.                                                                                                   | Untracked upstream; the reason Clay has no `rows=100000` case                                                            |

Smaller limits, each with its workaround, are in the READMEs: `with` symbols
may not shadow a local; a method template taking a local lambda by alias needs
a dual context (so `mapKeyed` and `record` are free functions); `__FUNCTION__`
is empty in a delegate literal's parameter list; DMD 2.115 leaves
`_d_assert_fail` instances unemitted under `-checkaction=context`; and
`TextPool.compact`'s capacity-sized stack array overflowed a test worker's
stack at 2¹⁹ slots (fixed on `fix/base-bench-findings`, `dbf273c98`).

The primitives prototype adds three: a member function shadows a UFCS free
function of the same name (`Ui.layout` hid `ui.layout(Params)`, so the pass is
`layOut`); dip1000 rejects handing a context that points at `ref this` to a
layout's `arrange` unless the parameter is `scope ref`; and `package`
visibility reaches nothing between top-level modules
([README][x-prim], "Compiler errors and limitations hit").

---

## Milestones

| Date (2026) | Step                                                                                                            |
| ----------- | --------------------------------------------------------------------------------------------------------------- |
| May 20      | Clay `e6cc369`, the revision every Clay reference here reads                                                    |
| November 24 | Inside-out sketch of UI-Q1–UI-Q6 (`ui-api-demo`)                                                                |
| November 24 | Scoped `with` probe and builder; markup DSL; fit-pass benchmark                                                 |
| November 24 | Lazy-variadic probes find the closure bug; the lazy-variadic port and the first three-builder benchmark         |
| November 25 | Children stack (`lazy-stack`), split and SoA layouts with the `place` pass, Clay through ImportC; UI-Q7 decided |
| November 25 | Primitives prototype (`ui-primitives`): pure against hybrid primitives, four custom-layout mechanisms           |
| November 26 | UI-Q8 decided: pure primitives, the layout protocol and paint-only leaves                                       |
| _pending_   | The split decision, after `libs/ui` is migrated to the new builder                                              |

---

## Quick navigation

- **I am migrating `libs/ui` to the decided builder.** [Decisions](#decisions)
  → [what UI-Q7 changes](#what-ui-q7-changes) →
  [`lazystack.d`][x-lazystack] (the builder) → [what remains](#what-remains).
- **I want to know why not statements or markup.** [Scoped `with`](#scoped-with)
  and [markup DSL](#markup-dsl), then their READMEs ([scoped][x-scoped],
  [markup][x-markup]) for the full diagnostics.
- **I am designing the layout passes.** [The fit pass](#the-fit-pass) →
  [split and SoA](#split-and-soa-and-the-place-pass) →
  [Clay][clay-layout] in the layout catalog.
- **I am writing a widget or a custom layout.** [Primitives and custom
  layouts](#primitives-and-custom-layouts-ui-q8) → [`layouts.d`][x-prim-layouts]
  (the clock, timeline and calendar) → the [prototype README][x-prim].
- **I am working on the compiler forks.** [The requirement](#the-compiler-requirement)
  → [defects found](#defects-found) → [`lazy-variadic/`][x-lazyprobe].

---

## Sources

- Experiments, all under `experiments/`:
  [`ui-api-demo`][x-insideout-readme] (inside-out),
  [`clay-style`][x-claystyle], [`ui-api-demo-scoped`][x-scoped],
  [`ui-api-demo-markup`][x-markup], [`lazy-variadic`][x-lazyprobe],
  [`ui-api-demo-lazy`][x-lazy] with [`bench/`][x-bench] and its
  [`results/`][x-tables], [`layout-fit-bench`][x-fit] and
  [`ui-primitives`][x-prim].
- Clay at `e6cc36941ab2af5d81107617039d6f527a1c660b`: [`clay.h`][clay-h]
  ([`CLAY__CONFIG_WRAPPER`][clay-wrapper], [`Clay__LayoutElementChildren`][clay-children],
  [`Clay_LayoutElement`][clay-element], [`Clay__HashNumber`][clay-hashnumber],
  [`Clay__AddHashMapItem`][clay-hashmap], [`Clay__CloseElement`][clay-close],
  [`Clay__CalculateFinalLayout`][clay-final]).
- D: [lazy variadic functions][spec-lazy-variadic] in the language
  specification; [dlang/dmd#22885][dmd-22885].
- Related catalogs: [Solid 2.0 components][solid-components],
  [Flutter][flutter], [Jetpack Compose][compose], [Clay layout][clay-layout],
  [immediate mode at scale][imlv].

<!-- References -->

[solid-components]: ../reactive-programming/solid-components.md
[flutter]: ../reactive-programming/flutter.md
[compose]: ../reactive-programming/jetpack-compose.md
[clay-layout]: ../ui-layout/clay.md
[imlv]: ../ui-virtualization/immediate-mode-large-views.md
[x-insideout-readme]: ./experiments/ui-api-demo/README.md
[x-insideout-readme]: ./experiments/ui-api-demo/README.md
[x-insideout-sketch]: ./experiments/ui-api-demo/ui_sketch.d
[x-claystyle]: ./experiments/clay-style/README.md
[x-scoped2]: ./experiments/clay-style/scoped2.d
[x-scoped]: ./experiments/ui-api-demo-scoped/README.md
[x-siteprobe]: ./experiments/ui-api-demo-scoped/probes/site_probe.d
[x-markup]: ./experiments/ui-api-demo-markup/README.md
[x-probe1]: ./experiments/ui-api-demo-markup/probes/probe1.d
[x-lazyprobe]: ./experiments/lazy-variadic/README.md
[x-min]: ./experiments/lazy-variadic/min.d
[x-lazy]: ./experiments/ui-api-demo-lazy/README.md
[x-lazy-app]: ./experiments/ui-api-demo-lazy/app.d
[x-lazy-sketch]: ./experiments/ui-api-demo-lazy/ui_sketch.d
[x-lazy-out]: ./experiments/ui-api-demo-lazy/out/app-ldc.txt
[x-lazy-stock]: ./experiments/ui-api-demo-lazy/out/stock-ldc.txt
[x-typednode]: ./experiments/ui-api-demo-lazy/probes/typed_node.d
[x-bench]: ./experiments/ui-api-demo-lazy/bench/src/bench.d
[x-lazystack]: ./experiments/ui-api-demo-lazy/bench/src/lazystack.d
[x-lazysplit]: ./experiments/ui-api-demo-lazy/bench/src/lazysplit.d
[x-lazysoa]: ./experiments/ui-api-demo-lazy/bench/src/lazysoa.d
[x-clayui]: ./experiments/ui-api-demo-lazy/bench/clay/clayui.d
[x-clayimpl]: ./experiments/ui-api-demo-lazy/bench/clay/clay_impl.c
[x-tables]: ./experiments/ui-api-demo-lazy/bench/results/tables.md
[x-stack-hb]: ./experiments/ui-api-demo-lazy/bench/results/stack-inline-ldc-1.txt
[x-stack-raw]: ./experiments/ui-api-demo-lazy/bench/results/stack-inline-ldc-rawbuf-1.txt
[x-soa-hb]: ./experiments/ui-api-demo-lazy/bench/results/soa-ldc-1.txt
[x-soa-raw]: ./experiments/ui-api-demo-lazy/bench/results/soa-ldc-rawbuf-1.txt
[x-clay-1]: ./experiments/ui-api-demo-lazy/bench/results/clay-ldc-1.txt
[x-fit]: ./experiments/layout-fit-bench/README.md
[x-fitbench]: ./experiments/layout-fit-bench/fitbench.d
[x-fit-summary]: ./experiments/layout-fit-bench/summary-ldc.md
[x-prim]: ./experiments/ui-primitives/README.md
[x-prim-core]: ./experiments/ui-primitives/src/uicore.d
[x-prim-layouts]: ./experiments/ui-primitives/src/layouts.d
[x-prim-tests]: ./experiments/ui-primitives/src/tests.d
[x-prim-results]: ./experiments/ui-primitives/results/ldc-1.txt
[clay-h]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h
[clay-wrapper]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L160
[clay-children]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L1207-L1210
[clay-element]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L1212-L1229
[clay-hashnumber]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L1424
[clay-hashmap]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L1784
[clay-close]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L1867
[clay-final]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L2573
[dmd-22885]: https://github.com/dlang/dmd/issues/22885
[spec-lazy-variadic]: https://dlang.org/spec/function.html#lazy_variadic_functions
