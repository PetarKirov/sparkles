# Jane Street Incremental (OCaml)

A production self-adjusting-computation library: a dynamic dependency graph of pure values, fed by `Var`s, read through `Observer`s, and brought up to date only when the program calls `stabilize`, which recomputes the necessary, stale nodes once each, in height order.

| Field             | Value                                                                                                                                                                                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language          | OCaml (`ocaml >= 5.1.0` per [`incremental.opam`][opam]); also compiled to JavaScript for Bonsai                                                                                                                                      |
| License           | MIT, "Copyright (c) 2008--2026 Jane Street Group, LLC" ([`LICENSE.md`][license])                                                                                                                                                     |
| Repository        | [janestreet/incremental][repo]                                                                                                                                                                                                       |
| Documentation     | The interface file [`src/incremental_intf.ml`][intf] (the [`README.org`][readme] calls it the detailed documentation); the eight-part tutorial under [`doc/`][doc-index]; [Introducing Incremental][blog] (Yaron Minsky, 2015-07-18) |
| Category          | Self-adjusting computation: an explicitly stabilised, height-ordered, glitch-free value graph with dynamic structure (`bind`)                                                                                                        |
| Versions surveyed | `master` at `371fc83a75dc` (2026-11-03; last tagged changelog entry `v0.17.0`, [`CHANGES.md`][changes]); related: Salsa `0.28.6` at `d114d0e9b4be` (2026-11-23), Bonsai at `3a02b5736fcb` (2026-11-03)                               |
| Core abstraction  | Three types: `Var.t` (input, `set`), `Incr.t` (derived node, `map`/`bind`), `Observer.t` (sink, keeps its node alive); plus `stabilize` (the propagation step) and `Clock` (virtual time as graph input)                             |

> [!NOTE]
> Incremental is the odd one out in this survey: it has **no streams, no events, no
> asynchrony and no cancellation**. It is a pure value graph. It is here because its
> driving loop (mutate inputs, then one explicit batched propagation step, then read the
> sinks) is exactly the shape of a frame-ticked UI, and because its `Clock` puts virtual
> time _inside_ the graph. Its absences are findings, recorded under each spine heading.
> `Incr_map` lives in the separate `janestreet/incr_map` repository, which was **not**
> cloned; it is described here only through the in-tree tutorial ([`part3-map.mdx`][doc-map]).

---

## Overview

### What it solves

The [`README.org`][readme] names three uses: _"Building large calculations (of the kind you
might build into a spreadsheet) that can react efficiently to changing data"_,
_"Constructing views in GUI applications that can incorporate new data efficiently"_, and
_"Computing derived data while guaranteeing that the derived data stays in sync with the
source data"_. The lineage is explicit: it is _"inspired by the work of Umut Acar et. al.
on self-adjusting computations"_. Minsky's launch post calls a self-adjusting computation
_"a fancy spreadsheet"_ ([Introducing Incremental][blog]).

The tutorial is blunt that this is an optimisation tool and nothing else
([`part1-preliminaries.mdx`][doc-p1]):

> _"At its core, Incremental is an optimization tool. If you're not trying to solve a
> performance problem, you probably shouldn't be using it."_

### Design philosophy

1. **A pure computation, incrementalised.** _"The mental model you should bring to writing
   an Incremental computation is that of optimizing a pure computation over pure data"_
   ([`part4-pitfalls.mdx`][doc-p4]). Effects inside `map`/`bind` are actively discouraged
   because which nodes run on a given stabilisation is deliberately unpredictable.
2. **Propagation is explicit.** _"Incremental doesn't compute [z] every time [x] and [y]
   change. Rather, one must explicitly tell incremental when one wants [z] (and all other
   observed values) to be brought up to date, by calling [stabilize]"_ ([`incremental_intf.ml`][intf]).
3. **Only observed work happens.** _"[stabilize] ensures that all necessary nodes have
   correct values; it will not compute unnecessary nodes"_ ([`incremental_intf.ml`][intf]),
   where a node is _necessary_ iff a path leads from it to an observed node.
4. **Not free.** _"Incremental is fast, but it isn't super fast. In particular, it's largely
   not compatible with zero-alloc approaches"_ ([`part1-preliminaries.mdx`][doc-p1]); a node
   is _"a record of 27 fields, meaning that the record alone is 216 bytes"_ and firing one
   costs _"somewhere between 50ns-150ns"_ ([`part7-optimization.mdx`][doc-p7]).

---

## How it works

An instance is minted by a **generative functor**; every node, variable, observer, scope
and clock of that instance carries its type ([`incremental_intf.ml`][intf]):

```ocaml
module Inc : Incremental.S = Incremental.Make ()
open Inc

let x = Var.create 13
let y = Var.create 17
let z = map2 (Var.watch x) (Var.watch y) ~f:(fun x y -> x + y)
let z_o = observe z

let () =
  stabilize ();
  assert (Observer.value_exn z_o = 30);
  Var.set x 19;
  stabilize ();
  assert (Observer.value_exn z_o = 36)
```

The interface explains the functor: _"Since [Incremental.Make] is a generative functor,
the type system enforces that different applications of the functor deal with disjoint sets
of incrementals."_ Under the functor sits a non-functor form in which every type carries an
explicit **state witness** `'w`: `type ('a, 'w) t`, `('a, 'w) Var.t`, `'w State.t`, and
`State.create : ?max_height_allowed:int -> unit -> (module S)` returns the witness as a
first-class module. `S_gen` is _"a specialization of the interface of [Incremental], with:
the ['w] state_witness type parameter removed [and] the [State.t] argument removed"_;
[`incremental.ml`][incr-ml] builds it as `Make_with_config (C) ()` with a fresh
`type state_witness` and `let t = create_internal …`, and `module Make () = Make_with_config (Config.Default ()) ()`.

**Stabilisation** is a heap walk ([`incremental_intf.ml`][intf]):

> _"[stabilize] repeats the following steps until the heap becomes empty: 1. remove from the
> recompute heap a node with the smallest height 2. recompute that node 3. if the node's
> value changes, then add its parents to the heap."_

The heap is _"implemented with an array whose length is the max height"_, bounded by
`max_height_allowed` (default 128). Three invariants carry correctness: `p` is in `c`'s
parents iff `c` is in `p`'s children and `p` is necessary; `p` is in the recompute heap iff
`p` is necessary and stale; a parent's height exceeds every child's. In
[`state.ml`][state], `stabilize` is `stabilize_start` (add new observers, unlink disallowed
ones), `recompute_first_node_that_is_necessary` until the heap is empty, then
`stabilize_end`, which bumps `stabilization_num`, applies `Var.set`s made during the
stabilisation, and only then runs on-update handlers (status `Running_on_update_handlers`).

**`bind` reshapes the graph.** `bind ta ~f` _"returns a node [tb] such that whenever the
value of [ta] changes, the implementation calls [f] to obtain a node (possibly with an
arbitrary DAG below it)"_. Every node created inside `f` records its `created_in` scope;
heights force the left-hand side to stabilise before anything on the right; and when the
left-hand side changes, _"stabilization 'invalidates' all the nodes that depend on it"_.
`bind` is implemented with a hidden `Bind_lhs_change` node whose cutoff is `Cutoff.never`
([`state.ml`][state]). `invalidate_node` drops the node's value, disconnects its children,
**removes its timer alarm** (`At`, `At_intervals`, `Step_function`) and recurses into the
scopes of nested binds. That last detail is what makes debounce work (see
[Time and scheduling](#time-and-scheduling)).

The [seven-implementations talk][talk] (Minsky; date not shown on the page, **unverified**)
recounts how the design got here. Its versions run from a two-pass propagator with
finalizer-based reference counts (v1), through timestamp topological order, explicit
observers, specialised `map` vs `bind`, and "pseudo heights" in place of a heap, to v7
("observers replace finalizers") and v8, where closure-based "poor man's objects" became
GADTs (`Kind.t` today) and the result was _"suddenly massively better"_.

---

## Evaluation model

- **Push, scoped by demand.** Changes are pushed from set variables to parents, but only
  through necessary nodes. Unnecessary nodes are not computed at all: _"If the resulting
  incrementals are not necessary then the function will not be called"_ ([`incremental_intf.ml`][intf]).
  Demand is structural (an observer exists), not per-read. Contrast
  [Adapton](#adapton-demand-driven-incremental-computation), where demand is the read itself.
- **Batched, never synchronous.** `Var.set` only records a value and enqueues the watch
  node (`set_var_while_not_stabilizing` in [`state.ml`][state]); nothing recomputes until
  `stabilize`. A `set` during stabilisation _"will behave as if [set] was called after
  stabilization finished"_.
- **Glitch-free by construction.** Height ordering plus "recompute each node at most once"
  means no node ever sees a mix of old and new inputs within one stabilisation.
- **Hot, eager inside the necessary set.** There is no cold/hot distinction because there
  are no subscriptions to replay; a node either is necessary (kept current) or is not
  (stale and unlinked).
- **Change = cutoff says so.** Default cutoff is `phys_equal`; `set_cutoff` replaces it
  (`Cutoff.of_equal`, `of_compare`, `always`, `never`, `poly_equal`). A cut-off value
  _"will remain as [old_value] ([new_value] is discarded)"_.
- **Incremental stepping.** `Expert.do_one_step_of_stabilize` splits a stabilisation into
  steps (`Keep_going` / `Done`), a ready-made frame-budgeting hook.

## Composition

The combinator set is small and value-oriented ([`incremental_intf.ml`][intf]):
`const`/`return`; `map`, `map2` … `map15`; `bind`, `bind2` … `bind4`; `join`; `if_`;
`freeze`; `depend_on`; `necessary_if_alive`; `both`; `all`; `for_all`/`exists`;
`array_fold`; `reduce_balanced` (O(min(n, k log n))); `unordered_array_fold` and `sum`
(work proportional to changed inputs, via `F_inverse` or `Update`); `memoize_fun`,
`lazy_from_fun`; `Scope.current`/`Scope.within`. There is no `filter`, `merge`, `scan`,
`debounce`, `zip`-of-events: with no event type those have nothing to act on. Collections
are incrementalised by separate data-structure libraries, chiefly `Incr_map`
(`mapi`, `mapi'`, `filter_mapi`, `unordered_fold`, …, [`part3-map.mdx`][doc-map]), whose
work is _"proportional to the number of changes to the map"_ ([`part4-pitfalls.mdx`][doc-p4]).

The cost guidance is the main compositional rule. `bind` _"can be significantly more
expensive than [map] during stabilization, because, when its left-hand side changes, it
requires modification of the incremental DAG, while [map] simply flows values along the
DAG"_ ([`incremental_intf.ml`][intf]). The tutorial goes further: _"`bind` can make sense in
two cases"_: a small right-hand side, or a rarely changing left-hand side; _"Using `bind`
in other cases is almost always a mistake"_, and `return` is _"a dead giveaway"_ of a
non-incremental graph ([`part4-pitfalls.mdx`][doc-p4]).

### API structure and naming

**Source / transform / sink split, by module.** Sources are submodules that own mutation:
`Var` (`create`, `set`, `watch`, `value`, `latest_value`, `replace`) and `Clock` (`create`,
`advance_clock`, `watch_now`, `at`, `after`, `at_intervals`, `step_function`, `snapshot`).
Transforms are **top-level functions** of the instance (`Inc.map`, `Inc.bind`, `Inc.if_`).
Sinks are `observe` plus the `Observer` submodule (`value`, `value_exn`, `on_update_exn`,
`disallow_future_use`). The driver, `stabilize`, is top-level too. `Var.watch` is the
one-way door from source to graph (_"For a given [t], all calls to [watch t] return the same
incremental"_), so a `Var.t` is never itself an `Incr.t`: input and derived node are
different types, as are derived node and sink. The tutorial calls this a three-part
architecture: _"variables, which constitute the inputs to the computation, incrementals
which correspond to the intermediate stages of the computation, and observers, which are
nodes from which you can read the output"_ ([`part1-preliminaries.mdx`][doc-p1]).

**State threading rule.** In the witness form, a function takes `'w State.t` exactly when it
has no input node to take the state from: `const`, `return`, `Var.create`, `array_fold`,
`all`, `sum`, `Clock.create`, `stabilize`, `Expert.Node.create`. Everything that consumes a
node reads `state` from it. The functor form hides even that.

**Variant families.** These conventions are Jane Street-wide, and Incremental follows them
uniformly:

| Pattern             | Examples                                                      | Meaning                                                                                    |
| ------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Arity suffix        | `map2` … `map15`, `bind2` … `bind4`                           | One node for N inputs, cheaper than nesting `both` ([`incremental_intf.ml`][intf])         |
| `_exn` suffix       | `Observer.value_exn`, `on_update_exn`                         | Raises; the plain name returns `Or_error.t`                                                |
| Prime               | `Incr_map.mapi'`, Bonsai `Edge.on_change'`                    | Same operation, richer callback (inner function is itself incremental; gets the old value) |
| `opt_` prefix       | `opt_sum`, `opt_unordered_array_fold`                         | Option-lifted: `Some` iff every input is `Some`                                            |
| Trailing underscore | `if_ ~then_ ~else_`, `freeze ?when_`, `advance_clock ~to_`    | Keyword avoidance, kept even for labels                                                    |
| Submodule tiers     | `Expert`, `Private`, `For_analyzer`, `Let_syntax.Open_on_rhs` | Escape hatch, internal, tooling, names in scope on a `let%map` right-hand side             |

**User-defined operators.** The ordinary way is a plain function over `'a Inc.t` built from
`map`/`bind`, or a functor over `Incremental.S` (`module Incr_map = Incr_map.Make (Incr)`,
[`part4-pitfalls.mdx`][doc-p4]). When a node must react to _which_ child changed, there is
`Expert`: `Expert.Node.create (fun () -> …)`, `Expert.Dependency.create ?on_change child`,
`add_dependency`, `remove_dependency`, `make_stale`, `invalidate`. The interface warns:
_"A low-level, experimental interface to incremental. … It comes at the cost that it's much
harder to use right"_ ([`incremental_intf.ml`][intf]).

**Regrets and renames.** From [`CHANGES.md`][changes] and the docs:

- `113.33.00` made invalidation optional (`bind_lhs_change_should_invalidate_rhs` in
  `Make_with_config`), with the implementation _"rescope[s] nodes created on rhs"_ instead.
  The default (invalidate) stayed, but the semantics became a configuration knob.
- `113.43.00` added `Let_syntax` as _"a nice alternative to the `mapN` functions"_; the
  interface then has to warn that `let%map … and …` _"is less efficient than using [map3],
  [map4], etc., as the latter produces fewer intermediate nodes"_. Sugar and efficiency
  diverged.
- `observe_no_finalization` exists because finalizer-backed `observe` is not portable; the
  interface itself says _"it is preferable to disable observers using [disallow_future_use]"_.
  The talk's v7 removed per-node finalizers entirely.
- The `map` doc comment still says _"[map2], [map3], ..., [map9]"_ while the signature goes
  to `map15`: a stale comment in the canonical doc.
- Bonsai, built on Incremental, _"Rewrote entire bonsai API. The new version is inside of the
  `Bonsai.Cont` namespace"_ (v0.17.0), keeping the old arrow-style API as
  `src/arrow_deprecated/` ([`bonsai_arrow_deprecated.mli`][bonsai-arrow]), and renamed
  `Bonsai.Cont.yoink` to `peek` ([Bonsai `CHANGES.md`][bonsai-changes]).

## Time and scheduling

There is **no scheduler**: one thread calls `stabilize` when it chooses. Tutorial guidance
on cadence ([`part7-optimization.mdx`][doc-p7]): _"Stabilizations, on the other hand, are
nearly free. A single stabilization where there's nothing to be done takes under 100ns"_;
yet batching still pays, and _"the choice of when stabilizations are done is global across
the entire incremental graph … something that you choose at an application level, when you
construct the loop that drives stabilization."_ This loop _is_ a frame tick.

**Time is a graph input.** `Clock` is _"a timing-wheel-based clock … One must explicitly call
[advance_clock] to change incremental's clock; there is no implicit call based on the passage
of time"_ ([`incremental_intf.ml`][intf]). `Clock.at clock t` is a `Before_or_after.t`
incremental; `after clock span` is `at clock (now + span)`; `at_intervals` fires with cutoff
`never`; `step_function` walks a time-keyed list; `snapshot` freezes a value at a time;
`watch_now` exists but the tutorial steers away from it because _"`now` is always changing"_
([`part5-time.mdx`][doc-p5]). In [`state.ml`][state], `advance_clock` sets the hidden
`clock.now` var, fires past alarms, converts each fired `At` node to `Const After` and
`make_stale`s it. As with `Var.set`, nothing is visible until the next `stabilize`.

**Debounce is not an operator, it is a `bind` over a timer.** Placing `Clock.after` on the
right-hand side of a `bind` on the query gives restart semantics for free. Each new query
invalidates the old right-hand side, and `invalidate_node` runs
`| At at -> remove_alarm at.clock at.alarm` ([`state.ml`][state]). The test suite pins this
with `is_invalidated_on_bind_rhs (fun _ -> Clock.after clock (sec 1.))`
([`test_incremental.ml`][test]). The duration is just another input: put the interval `Var`
in the same `bind` and changing it restarts the timer with the new span. The span is
measured from the change, not from the original keystroke.

> [!WARNING]
> `if_` does **not** cancel a timer. Switching branches makes the old branch _unnecessary_,
> and `became_unnecessary` neither invalidates the node nor removes its alarm
> ([`state.ml`][state]). The alarm can fire while the branch is unobserved, so re-enabling
> it reveals an already-expired debounce. Gate with `bind` (which invalidates), not `if_`.

`Clock` exposes no "next alarm time" (only `now`, `alarm_precision`, `timing_wheel_length`),
so a host that wants to sleep until the next timer (our `wakeIn`) cannot ask the graph.
It must tick at a fixed rate, or track deadlines itself.

## Concurrency and cancellation

**Not applicable, and deliberately so.** Incremental is single-threaded state with no
`Deferred`, no threads, no async node kind. A computation cannot suspend; a long `map`
blocks `stabilize`. Latest-wins exists only as _graph_ latest-wins: when a `bind`'s
left-hand side changes, the old right-hand side is invalidated and never recomputed:
_"It would be both wasteful and wrong to recompute any of those 'invalid' nodes"_
([`incremental_intf.ml`][intf]). That is cancellation of **pending recomputation**, not of
running work. CPU-bound or asynchronous work must leave the graph: an on-update handler
starts it elsewhere, and its result re-enters through `Var.set`. Cancelling that work and
waiting for it to finish is entirely the host's problem.

Bonsai fills part of this gap with an `Effect` type and kernel components, but its
concurrency combinator is not latest-wins. `One_at_a_time.effect` _"ensures that only one
instance of it is running at a time. If another instance of the effect is already running,
then [Busy] is returned instead"_ ([`bonsai_kernel_one_at_a_time.mli`][bonsai-oaat]). That is
reject-newest, the opposite policy. See [Salsa](#salsa-rust) for the library in this cluster
that does cancel running work.

## Errors and completion

There is no completion: a graph lives until its observers go. User functions are supposed to
be total: _"User functions given to incremental should never raise any exceptions: doing so
will cause all future calls to [stabilize] to raise"_ ([`incremental_intf.ml`][intf]). In
[`state.ml`][state], an exception during `stabilize` moves the state to
`Stabilize_previously_raised raised_exn`, and `set_var` thereafter raises `"cannot set var --
stabilization previously raised"`. A failure is **fatal to the whole instance**, with no
per-node error channel. Errors as values are the user's job (`Or_error.t` inside the node
type). On the read side, `Observer.value` returns `Or_error.t` for "not yet stabilised",
"mid-stabilisation", "disallowed" or "invalid", and `value_exn` raises.

## State and sharing

Every node is a shared value cell: _"The graph is a DAG rather than a tree because
incremental values can be shared"_. Fan-out is free: any number of parents may read a node,
and it computes once per stabilisation. Conflation is total and implicit. Ten `Var.set`s
between stabilisations are one change, and `Var.value` versus `Var.latest_value` exposes the
mid-stabilisation distinction. Cutoffs are the dedup mechanism, and their physical-equality
default is the library's most documented trap: in one tutorial example the computation
_"has been horrifically de-optimized"_ because `Map.comparator_s` allocates a fresh value
each time ([`part4-pitfalls.mdx`][doc-p4]). `freeze` makes a node constant after a
predicate holds. `incr_memoize` (v0.16.0) keeps old bind right-hand sides alive for reuse
([`CHANGES.md`][changes]).

## Lifetime and ownership

Liveness is **observation**. Incremental keeps pointers from nodes to children, from necessary
nodes to necessary parents, and from observers to nodes: _"So, all necessary nodes are kept
alive"_ ([`incremental_intf.ml`][intf]). Dropping an observer (explicitly via
`disallow_future_use`, or through its GC finalizer) takes effect at the next stabilisation,
which unlinks the now-unnecessary subgraph, _"essentially a form of ref-counting"_. Ownership
of _created_ nodes is the bind scope: nodes made on a `bind` right-hand side die with it, and
closures that build nodes must carry their scope (`Scope.within`, `lazy_from_fun`) or they
attach to the wrong bind. `Var.create ~use_current_scope:true` lets an input die with its
scope, so an `on_update … Invalidated` handler can tear down the external feeder. On-update
handlers pin their observer: _"If an observer has on-update handlers, calling
[disallow_future_use] is the only way to have it removed."_ The scope tree is the closest
analogue of structured lifetimes, but nothing in it can _run_.

## Testing

Determinism is the default: no threads, no wall clock. A test creates a `Clock` at
`Time_ns.epoch`, advances it by hand and stabilises ([`test_incremental.ml`][test]):

```ocaml
let clock = Clock.create ~start:Time_ns.epoch () in
let o = observe (Clock.after clock (sec 1.)) in
let show () = stabilize_ [%here]; print_s [%sexp (value o : Before_or_after.t)] in
show ();
[%expect {| Before |}];
Clock.advance_clock_by clock (sec 1.);
show ();
[%expect {| After |}]
```

Debounce reset is tested by invalidation, not by sleeping. `Incremental_debug` reruns the same
code with assertions on; `save_dot`/`For_analyzer` dump the graph; constant-time counters
(`num_nodes_recomputed`, `num_nodes_changed`, …) let a test assert _how much_ work happened.
Bonsai builds whole-app tests on the same discipline (`Handle.show_diff`, [Bonsai `README.md`][bonsai-readme]).

## The worked pipeline

Incremental can express the debounce, the runtime interval and the toggle entirely in the
graph. The hash cannot live there, so it runs in Async's thread pool and re-enters through a
`Var`. Sketch (not compiled; Core/Async names as in Jane Street's public libraries):

```ocaml
module Incr = Incremental.Make ()
open Incr.Let_syntax

let clock      = Incr.Clock.create ~start:(Time_ns.now ()) ()
let query_v    = Incr.Var.create ""
let interval_v = Incr.Var.create (Time_ns.Span.of_int_ms 300)
let enabled_v  = Incr.Var.create true
let result_v   = Incr.Var.create (None : (string * Hash.t) option)

(* [Some q] once [interval] has elapsed since [q] or [interval] last changed. *)
let debounced : string option Incr.t =
  let%bind enabled = Incr.Var.watch enabled_v in           (* bind, not if_: invalidates *)
  if not enabled then return None
  else
    let%bind query = Incr.Var.watch query_v
    and interval = Incr.Var.watch interval_v in             (* bind2: one restart node *)
    match%map Incr.Clock.after clock interval with
    | Before -> None
    | After -> Some query

let shown =                                                 (* drop stale results *)
  let%map d = debounced and r = Incr.Var.watch result_v in
  match d, r with
  | Some q, Some (q', h) when String.equal q q' -> Some h
  | _ -> None

(* The sink side: start/cancel work outside the graph. *)
let in_flight : (string * bool Atomic.t) option ref = ref None
let () =
  Incr.Observer.on_update_exn (Incr.observe debounced) ~f:(fun u ->
    Option.iter !in_flight ~f:(fun (_, c) -> Atomic.set c true);   (* cancel previous *)
    in_flight := None;
    match u with
    | Initialized (Some q) | Changed (_, Some q) ->
      let cancelled = Atomic.make false in
      in_flight := Some (q, cancelled);
      don't_wait_for (
        let%map h = In_thread.run (fun () -> hash_file_set q ~cancelled) in
        if not (Atomic.get cancelled) then Incr.Var.set result_v (Some (q, h)))
    | _ -> ())

let shown_o = Incr.observe shown

(* The frame: inputs, time, one stabilisation, render. *)
let frame ~events =
  List.iter events ~f:apply_ui_event;          (* Var.set query_v / interval_v / enabled_v *)
  Incr.Clock.advance_clock clock ~to_:(Time_ns.now ());
  Incr.stabilize ();
  render (Incr.Observer.value_exn shown_o)
```

**Trace.**

1. _Keystroke during debounce._ `Var.set query_v "ab"` records the value. At the next
   frame's `stabilize`, the inner `bind2` left-hand side changes: the old `After` node is
   invalidated and its alarm removed; a new `Clock.after` is created at `now + interval`.
   `debounced` recomputes to `None`, which is `phys_equal` to the previous `None`
   (an immediate), so the cutoff stops propagation and no handler runs.
2. _Keystroke during hash._ `debounced` was `Some "ab"`. The new query makes it `None`, so the
   handler gets `Changed (Some "ab", None)`, sets the old job's flag and clears `in_flight`.
   The worker thread keeps running until `hash_file_set` polls `cancelled`. Nothing waits for
   it: there is no join, and the thread-pool slot stays busy. The late result is dropped by
   the flag check. Even if it slipped through, `shown` compares query strings.
3. _Interval change._ `interval_v` is on the same `bind2` left-hand side, so the timer
   restarts with the new span from _now_. If the debounce had already fired, `debounced`
   goes `Some q` → `None` → (after `interval`) `Some q` again. The handler cancels the
   finished-or-running hash and later **re-hashes the same query**. Avoiding that needs a
   `last_hashed` check in the handler; the graph cannot express it.
4. _Toggle off._ The outer `bind` left-hand side changes; `invalidate_nodes_created_on_rhs`
   recurses through the inner bind and removes the pending alarm. `debounced` becomes
   `None`; the handler cancels the in-flight hash. Had the gate been `if_`, the timer would
   have survived (see the warning under [Time and scheduling](#time-and-scheduling)).

**Fit for a per-frame UI.** The fit is the best in the survey: one `stabilize` per frame,
inputs `Var.set` from the event phase, time advanced once per frame, and a glitch-free
snapshot to render from. The misfits sit at the edges. There is no way to learn when the
next alarm is due, so the frame cannot sleep exactly until it (`wakeIn`). Async work and its
cancellation live outside the model. The graph's node cost (216 bytes, 50 to 150 ns per
firing) argues for coarse nodes, a few per widget rather than per value.

---

## Related designs

### Adapton (demand-driven incremental computation)

Adapton (Hammer, Khoo, Hicks and Foster; _Adapton: Composable, Demand-Driven Incremental
Computation_, PLDI 2014, Edinburgh, DOI `10.1145/2594291.2594324`) attacks the case
Incremental's observers handle structurally. The abstract presents _"λCDDIC, a core calculus
that applies a demand-driven semantics to incremental computation"_ ([paper page][adapton-page]).
Its argument is that eager change propagation recomputes outputs nobody is demanding, and
treats a program as one indivisible unit. Adapton's answer is a demanded computation graph:
changing an input only _dirties_ dependents, and work happens when a thunk is _forced_, so an
unread result costs nothing (abstract summarised via [the authors' page][adapton-page]; the
full paper PDF was not retrieved). Against Incremental: Adapton is pull (demand per read);
Incremental is push within a statically demanded set. The [parsing survey's incremental
page][parsing-incr] covers the same family from the parser side.

### Salsa (Rust)

Salsa is rust-analyzer's query engine. Its model is Incremental's loop with the outer loop
explicit: _"Salsa separates out the 'incremental computation' (the function `your_program`)
from some outer loop that is defining the inputs"_ and _"The mutation of inputs always happens
outside of `your_program`"_ ([`book/src/overview.md`][salsa-overview]). Queries are pulled and
memoised per revision. A recomputed query whose value did not change is _backdated_
(_"we can compare the two values to see that, while the dependencies to M may have changed,
the result of the query function did not"_, [`backdate.md`][salsa-backdate]): Salsa's cutoff.

Unlike Incremental, Salsa runs queries **concurrently and cancels them**, and this is our
latest-wins inside a query engine. A write needs `&mut` access to the shared `Zalsa`:
_"Whenever the user attempts to do an `&mut` operation, such as modifying an input field,
Salsa must first cancel any parallel handles and wait for those threads to finish"_
([`database_and_runtime.md`][salsa-runtime]). `cancel_others` in [`storage.rs`][salsa-storage]
_"Sets cancellation flag and blocks until all other workers with access to this storage have
completed"_. It waits on a condvar until the handle count drops to 1, then takes `Arc::get_mut`.
That is **cancel-and-join**, enforced by the borrow checker. Running queries notice at their
next query call or an explicit checkpoint ([`zalsa.rs`][salsa-zalsa]):

```rust
pub(crate) fn unwind_if_revision_cancelled(&self, zalsa_local: &ZalsaLocal) {
    self.event(&|| crate::Event::new(crate::EventKind::WillCheckCancellation));
    if zalsa_local.should_trigger_local_cancellation() {
        zalsa_local.unwind_cancelled();
    }
    if self.runtime().load_cancellation_flag() {
        zalsa_local.unwind_pending_write();
    }
}
```

The unwinding is a panic payload, `Cancelled::{Local, PendingWrite, PropagatedPanic}`, thrown
with `panic::resume_unwind` (_"We use resume and not panic here to avoid running the panic
hook"_) and caught at the boundary by `Cancelled::catch` ([`cancelled.rs`][salsa-cancelled]).
`Database::unwind_if_revision_cancelled` is public so _"query implementations that perform
potentially expensive computations"_ can poll it ([`database.rs`][salsa-database]). This is
our CPU-bound hash's cooperative checkpoint. The docs also warn that a writer holding a
second handle on the same thread deadlocks: join-on-cancel's characteristic hazard. Per-handle
`CancellationToken`s (`Cancelled::Local`, [`tests/cancellation_token.rs`][salsa-cancel-test])
add targeted cancellation beside the global revision bump.

### Bonsai (UI on Incremental)

Bonsai is _"a UI library for building performant, reactive web applications in OCaml, partly
inspired by Elm"_, used for _"almost all web applications inside Jane Street"_; its
_"Incrementalization inside the framework means that values don't get recomputed until
necessary"_ ([`README.md`][bonsai-readme]). It is what Incremental needs to be a UI: an
`Effect` type, a frame driver, and the timing operators Incremental lacks, in
[`cont.mli`][bonsai-cont]: `Clock.approx_now ~tick_every`, `Clock.every` with an explicit
`when_to_start_next_effect` policy (four variants for overlap), `Clock.sleep`/`until` as
effects, and `Edge.on_change`, whose callback is _"invoked at most once per frame and will be
called with the latest value"_ (per-frame conflation, stated as API). Rate limiting is a
kernel component, `effect_throttle` (leading and trailing edge) and `value_throttle`
([`bonsai_kernel_throttle.mli`][bonsai-throttle]), not a graph primitive.

---

## Strengths

- Exact, documented semantics for "what one propagation step sees": height order, at most one
  recompute per node, cutoffs; glitch-free without transactions or locks.
- Explicit `stabilize` maps one-to-one onto a frame tick, with a stepping variant for budgets.
- Virtual time is part of the graph: deterministic tests by `advance_clock`, and timers die with
  their bind scope, so restart-style debounce falls out of `bind`.
- Liveness by observation: unobserved subgraphs cost nothing and are unlinked automatically.
- A disciplined, uniform naming system (`_exn`, prime, `opt_`, arity suffixes, `Expert`) that
  carries across Jane Street's libraries.
- Unusually candid documentation of costs and pitfalls (node size, firing cost, `bind`/`return`
  misuse, `phys_equal` traps).

## Weaknesses

- No async, no events, no cancellation of running work; the parts of our pipeline that need
  them sit outside the model and are hand-wired.
- One exception poisons the instance permanently; no per-node error channel.
- `phys_equal` default cutoff makes incrementality depend on allocation identity.
- `if_` versus `bind` differ in whether timers survive: correct in the implementation, invisible
  in the types.
- No query for the next alarm time, so hosts cannot sleep precisely.
- Heavy nodes (216 bytes, 50 to 150 ns to fire), not zero-alloc; fine-grained use is slower than none.
- Scope capture is manual (`Scope.within`, `lazy_from_fun`); getting it wrong misattaches nodes.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                                        | Trade-off                                                                      |
| --------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Explicit `stabilize`                          | Batch many `Var.set`s; one consistent snapshot; caller chooses cadence           | Reads between stabilisations are stale; cadence is global, not per computation |
| Three types (`Var` / `Incr.t` / `Observer`)   | Inputs mutate, nodes derive, observers own liveness, enforced by type            | Extra `watch`/`observe` ceremony                                               |
| Generative functor plus `'w` witness          | Disjoint worlds cannot be mixed, checked statically                              | Two API shapes to document; state threading in the witness form                |
| Liveness by observers (finalizers optional)   | Only needed work runs; GC-independent teardown via `disallow_future_use`         | Forgotten observers leak work; finalizer timing is non-deterministic           |
| Height-ordered recompute heap, max height 128 | Glitch-freedom and at-most-once with O(1) bucket ops                             | Deep graphs need `set_max_height_allowed`; `bind` triggers height adjustment   |
| `bind` with scope invalidation                | Dynamic structure without recomputing dead subgraphs; timers cancelled with them | `bind` is the expensive operator; scope capture is manual                      |
| `phys_equal` default cutoff                   | O(1), never wrong in the "changed" direction                                     | Spurious recomputation on fresh allocations                                    |
| `Clock` inside the graph, advanced by hand    | Determinism, testability, timers as values                                       | Host must drive time; cannot ask for next deadline                             |
| No async / effects in the core                | Keeps the model pure and the guarantees simple                                   | Every UI layer (Bonsai) rebuilds effects, edges, throttling on top             |
| Exceptions are fatal to the instance          | Never observe a half-updated graph                                               | No recovery or per-node error values                                           |

## Sources

- [janestreet/incremental — repository][repo] · [`README.org`][readme] · [`CHANGES.md`][changes] · [`LICENSE.md`][license] · [`incremental.opam`][opam]
- [`src/incremental_intf.ml` — the documented interface][intf]
- [`src/incremental.ml` — `Make`, `Make_with_config`][incr-ml] · [`src/state.ml` — stabilisation, `bind`, invalidation, `Clock`][state]
- [`src/cutoff.ml`][cutoff-ml] · [`src/expert.ml`][expert-ml] · [`src/observer.ml`][observer-ml]
- Tutorial: [index][doc-index] · [Part 1 — preliminaries][doc-p1] · [Part 2 — bind][doc-p2] · [Part 3 — `Incr_map`][doc-map] · [Part 4 — pitfalls][doc-p4] · [Part 5 — time][doc-p5] · [Part 7 — optimisation][doc-p7]
- [`test/test_incremental.ml` — clock tests][test] · [`step_function/…/incremental_step_function.mli`][stepfn] · [`memoize/src/incr_memoize.mli`][memoize]
- [Introducing Incremental — Yaron Minsky, Jane Street blog, 2015-07-18][blog] · [Seven Implementations of Incremental — Yaron Minsky, Jane Street tech talk][talk]
- Adapton: [paper page (UMD)][adapton-page] · [Adapton project page][adapton-home]
- Salsa: [`src/cancelled.rs`][salsa-cancelled] · [`src/storage.rs`][salsa-storage] · [`src/zalsa.rs`][salsa-zalsa] · [`src/database.rs`][salsa-database] · [`src/zalsa_local.rs`][salsa-local] · [`book/src/overview.md`][salsa-overview] · [`database_and_runtime.md`][salsa-runtime] · [`backdate.md`][salsa-backdate] · [`tests/cancellation_token.rs`][salsa-cancel-test]
- Bonsai: [`README.md`][bonsai-readme] · [`CHANGES.md`][bonsai-changes] · [`src/cont.mli`][bonsai-cont] · [`bonsai_kernel_throttle.mli`][bonsai-throttle] · [`bonsai_kernel_one_at_a_time.mli`][bonsai-oaat] · [`bonsai_arrow_deprecated.mli`][bonsai-arrow]
- Related in this survey: [Sodium][sodium] · [Solid signals][solid] · [TC39 signals][tc39] · [Elm][elm] · [Jetpack Compose][compose] · [Reflex][reflex] · [RxJS][rxjs] · [Kotlin Flow][kotlin-flow] · [Concepts][concepts] · [Comparison][comparison] · [Index][index]

<!-- References -->

[repo]: https://github.com/janestreet/incremental
[readme]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/README.org
[changes]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/CHANGES.md
[license]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/LICENSE.md
[opam]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/incremental.opam
[intf]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/src/incremental_intf.ml
[incr-ml]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/src/incremental.ml
[state]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/src/state.ml
[cutoff-ml]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/src/cutoff.ml
[expert-ml]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/src/expert.ml
[observer-ml]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/src/observer.ml
[doc-index]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/doc/index.mdx
[doc-p1]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/doc/part1-preliminaries.mdx
[doc-p2]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/doc/part2-dynamic.mdx
[doc-map]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/doc/part3-map.mdx
[doc-p4]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/doc/part4-pitfalls.mdx
[doc-p5]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/doc/part5-time.mdx
[doc-p7]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/doc/part7-optimization.mdx
[test]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/test/test_incremental.ml
[stepfn]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/step_function/src/incremental_step_function.mli
[memoize]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/memoize/src/incr_memoize.mli
[blog]: https://blog.janestreet.com/introducing-incremental/
[talk]: https://www.janestreet.com/tech-talks/seven-implementations-of-incremental/
[adapton-page]: https://www.cs.umd.edu/~mwh/papers/hammer13adapton.html
[adapton-home]: http://web.archive.org/web/20260508002558/http://www.cs.umd.edu/%7Ehammer/adapton/
[salsa-cancelled]: https://github.com/salsa-rs/salsa/blob/d114d0e9b4be578a458b99d10c38ea72a67c33d1/src/cancelled.rs
[salsa-storage]: https://github.com/salsa-rs/salsa/blob/d114d0e9b4be578a458b99d10c38ea72a67c33d1/src/storage.rs
[salsa-zalsa]: https://github.com/salsa-rs/salsa/blob/d114d0e9b4be578a458b99d10c38ea72a67c33d1/src/zalsa.rs
[salsa-database]: https://github.com/salsa-rs/salsa/blob/d114d0e9b4be578a458b99d10c38ea72a67c33d1/src/database.rs
[salsa-local]: https://github.com/salsa-rs/salsa/blob/d114d0e9b4be578a458b99d10c38ea72a67c33d1/src/zalsa_local.rs
[salsa-overview]: https://github.com/salsa-rs/salsa/blob/d114d0e9b4be578a458b99d10c38ea72a67c33d1/book/src/overview.md
[salsa-runtime]: https://github.com/salsa-rs/salsa/blob/d114d0e9b4be578a458b99d10c38ea72a67c33d1/book/src/plumbing/database_and_runtime.md
[salsa-backdate]: https://github.com/salsa-rs/salsa/blob/d114d0e9b4be578a458b99d10c38ea72a67c33d1/book/src/plumbing/terminology/backdate.md
[salsa-cancel-test]: https://github.com/salsa-rs/salsa/blob/d114d0e9b4be578a458b99d10c38ea72a67c33d1/tests/cancellation_token.rs
[bonsai-readme]: https://github.com/janestreet/bonsai/blob/3a02b5736fcb4aace7a973bec0ad17dc046afdfe/README.md
[bonsai-changes]: https://github.com/janestreet/bonsai/blob/3a02b5736fcb4aace7a973bec0ad17dc046afdfe/CHANGES.md
[bonsai-cont]: https://github.com/janestreet/bonsai/blob/3a02b5736fcb4aace7a973bec0ad17dc046afdfe/src/cont.mli
[bonsai-throttle]: https://github.com/janestreet/bonsai/blob/3a02b5736fcb4aace7a973bec0ad17dc046afdfe/bonsai_kernel_components/throttle/bonsai_kernel_throttle.mli
[bonsai-oaat]: https://github.com/janestreet/bonsai/blob/3a02b5736fcb4aace7a973bec0ad17dc046afdfe/bonsai_kernel_components/one_at_a_time/bonsai_kernel_one_at_a_time.mli
[bonsai-arrow]: https://github.com/janestreet/bonsai/blob/3a02b5736fcb4aace7a973bec0ad17dc046afdfe/src/arrow_deprecated/bonsai_arrow_deprecated.mli
[parsing-incr]: ../parsing/theory/incremental.md
[sodium]: ./sodium.md
[solid]: ./solid-signals.md
[tc39]: ./tc39-signals.md
[elm]: ./elm.md
[compose]: ./jetpack-compose.md
[reflex]: ./reflex.md
[rxjs]: ./rxjs.md
[kotlin-flow]: ./kotlin-flow.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
