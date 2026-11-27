# Approach 2 — top-down from expressions: lazy variadic children

`ui.column(gap: 1, children: a, b, c)` keeps the agreed UI-Q2 expression
surface, but `children` is a D lazy variadic parameter:

```d
Node column(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, bool disabled = false,
    EnvOverride env = EnvOverride.init, NamedOnly _children = NamedOnly.init,
    scope ChildFn[] children...) @safe pure nothrow @nogc
alias ChildFn = Node delegate() @safe pure nothrow @nogc;
```

The compiler wraps each child expression in a delegate literal. The parent
opens (appends its record, links it under the innermost open element, pushes
it and its env), evaluates each child delegate in order, closes (fit size from
the children, Clay's `CloseElement`), pops. Identity = `mix(parent id,
argument position)`; `mapKeyed` rows mix in their key. A ternary with
`Node.none` keeps every later sibling's position.

Files:

- `ui_sketch.d` — the builder (`Ui`, primitives, `mapKeyed`/`mapByIndex`,
  `on`, `mapMsg`, `memo`, dump/diagnostics/dispatch).
- `app.d` — Stats pane, `explorerView`, `card`/`memberList`/`subtrees`
  (subtrees as values), `misplaced` (the hazard), `rejected()`, `main`.
- `probes/typed_node.d` — can a typed `Node!M` make the message check
  compile-time?
- `bench/` — the build-cost benchmark (own dub package): `src/insideout.d`,
  `src/scoped.d` (bench copies of the two other sketches), `src/views_*.d`,
  `src/bench.d`, `results/` (the runner's tables, `results/tables.md`).
- `bench/clay/` — the Clay builder (ImportC); `clay.h` is fetched, not
  committed (see "Clay (ImportC)" below).
- `treehash.d`, `benchtext.d` — shared by the bench (checksum formula; bench
  text store and `RawBuffer`).
- `out/` — captured outputs.

The runs used two wrappers for the patched compilers and the benchmark's
JSON output (`--bench-json`), with a Python script that turned it into
`results/tables.md`; none of the three is kept here. The `lazy-split` and
`lazy-soa` builders were generated once from `lazystack.d` by a throwaway
script and are kept as generated.

## Compilers

> [!IMPORTANT]
> The `@nogc` views need a D frontend in which a `scope` lazy variadic array
> of delegates allocates no closure: the fix for
> [dlang/dmd#22885](https://github.com/dlang/dmd/issues/22885), carried by the
> sparkles toolchain forks as UD8 (DMD) and UL20 (LDC). The flake lock that
> builds those compilers is on branch `build/scope-lazy-variadic-toolchain`;
> until it is merged, use that branch's development shell, or compilers
> patched the same way. Stock DMD 2.115 and LDC 1.43 reject the port (below).

The measurements below were taken with an earlier patch of the same
frontend check (a lazy variadic argument's delegate literals got
`tookAddressOf = 0`). That patch was unsound — it also cleared the closure of
a callee that stores its delegates — and the toolchain carries a corrected
fix. Under it the views still allocate no closure; the numbers were not
re-measured with it.

| compiler                             | notes                                                                                                                                                             |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| patched DMD 2.115.0-master           | the dev shell DMD's druntime and Phobos                                                                                                                           |
| patched LDC 1.43.0                   | linked as the dev shell's LDC does: static druntime/Phobos by default, so a build type's explicit `--link-defaultlib-shared` (the `bench` type has it) still wins |
| stock DMD 2.115.0-master, LDC 1.43.0 | **reject the port** (below)                                                                                                                                       |

### Stock compilers reject it (the fix is load-bearing)

`dub build --compiler=dmd -c app` and `--compiler=ldc2`, identical text on both
(`out/stock-dmd.txt`, `out/stock-ldc.txt`):

```
app.d(30,6): Error: function `app.statsPane` is `@nogc` yet allocates closure for `statsPane()` with the GC
app.d(58,6): Error: function `app.explorerView` is `@nogc` yet allocates closure for `explorerView()` with the GC
app.d(86,10): Error: function `app.badOrGood` is `@nogc` yet allocates closure for `badOrGood()` with the GC
app.d(94,6): Error: function `app.card` is `@nogc` yet allocates closure for `card()` with the GC
app.d(101,6): Error: function `app.memberList` is `@nogc` yet allocates closure for `memberList()` with the GC
app.d(105,6): Error: function `app.subtrees` is `@nogc` yet allocates closure for `subtrees()` with the GC
app.d(127,6): Error: function `app.misplaced` is `@nogc` yet allocates closure for `misplaced()` with the GC
```

Every view with a child slot fails. Without `@nogc` it would compile and
GC-allocate a closure per view call per frame. (`../lazy-variadic/min.d`
also fails on stock LDC, passes on the patched one.)

## Commands

From the repository root, in a development shell whose compilers carry the
fix (above):

```bash
D=docs/research/ui-authoring/experiments/ui-api-demo-lazy
nix develop -c bash -c "cd $D && dub run --compiler=dmd  -c app --skip-registry=all"
nix develop -c bash -c "cd $D && dub run --compiler=ldc2 -c app --skip-registry=all"
nix develop -c bash -c "cd $D && dub run --compiler=ldc2 -c bad --skip-registry=all"
nix develop -c bash -c "cd $D && dub run --compiler=ldc2 -c app -b checked --skip-registry=all"   # debug checks compiled out
nix develop -c bash -c "cd $D/probes && dmd -preview=dip1000 -o- typed_node.d"
# Clay's header, for the benchmark and bench/clay (git-ignored there):
curl -fL -o $D/bench/clay/clay.h https://raw.githubusercontent.com/nicbarker/clay/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h
# benchmark (`@benchCases`, case structs; configurations: unittest = HeapBuffer, unittest-rawbuf, unittest-nocache)
nix develop -c bash -c "cd $D/bench && dub test -b bench --compiler=ldc2 --skip-registry=all && ./build/ui-build-bench-test-unittest --bench --perf --group-by=size"
nix develop -c bash -c "cd $D/bench && dub test -b bench -c unittest-rawbuf --compiler=ldc2 --skip-registry=all && ./build/ui-build-bench-test-unittest-rawbuf --bench --perf --group-by=size"
# … and the same with --compiler=dmd
nix develop -c bash -c "cd $D/bench/clay && dub run -b bench -c smoke --compiler=ldc2 --skip-registry=all"
```

`-c app` output is byte-identical on patched DMD and LDC (`out/app-dmd.txt`,
`out/app-ldc.txt`); so is `-c bad`.

## The Stats pane as authored

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

Identical to the inside-out version except: lowercase names, `children:`
before a comma list instead of `[ … ]`. Note the attribute expression
`gap: ui.env.density …` is evaluated _eagerly_ (it is an ordinary argument),
so it reads the env of the slot the column sits in; the children's
`ui.env.density` reads the env after the column opened.

## explorerView: what the three old placements become

```d
Node explorerView(ref Ui ui, in Model m) @safe pure nothrow @nogc
    => ui.column(children:
        ui.label(slot: Slot.heading, text: ui.text(i"members: $(m.ids.rows.length)")),
        ui.column(env: ui.env.withDensity(Density.compact), disabled: m.tutorial, children:
            ui.mapMsg!liftStats(statsPane(ui, m.stats, m.ids)),
        ),
        ui.mapMsg!liftStats(statsPane(ui, m.stats, m.ids)),
        ui.mapMsg!liftStats(ui.memo!statsPane(m.stats, m.ids)),
    );
```

- **deferred** (`ui.place(statsPane(m.stats, m.ids))` + `componentForm`) →
  a plain call. The pane is a lazy child, evaluated after the compact,
  `disabled` column opened: the dump shows it `[compact] disabled`, with no
  hint label (structure chosen from env).
- **eager** → the same plain call, under the caller's comfortable env. The
  distinction is gone: there is one way to call a composite.
- **memo** (`ui.place(memo(…))`) → `ui.memo!statsPane(args)`: a `memo`
  element keyed by `hashOf(env)` ⊕ the arguments, the composite as its one
  child. A real host would compare the key with last frame's element of the
  same id and splice the old subtree.

`componentForm`, `Composite`, `place`, the argument arena's `@trusted` copy
of composite arguments, and the deferred `expand` pass are all deleted. (The
arena remains only for constant message bytes, as in every version.)

## Output (`-c app`, patched DMD = patched LDC)

`@N` = argument position, `#xxxx` = top 16 bits of the id, `[density]` = env
the children saw.

```
── tree ──
column  31×23  @0 #642b [comfortable]
  label "members: 2"  10×1  @0 #af27
  column  31×4  @1 #efce [compact] disabled
    mapMsg  31×4  @0 #f31d [compact] disabled
      column  31×4  @0 #3a23 [compact] disabled
        row  31×1  @0 #a1f5 [compact] disabled
          label "Stats"  5×1  @0 #2d7e disabled
          toggle "hash on edit"  16×1  @1 #6e26 disabled [msg]
          numberField "ms"  6×1  @2 #aece disabled [msg]
        label "computing… (query ab)"  21×1  @1 #e29d disabled
        keyValue "NarHash"  19×1  @2 #dd06 key disabled [msg]
        keyValue "castore"  15×1  @2 #6939 key disabled [msg]
  mapMsg  31×9  @2 #2dd7 [comfortable]
    column  31×9  @0 #4d65 [comfortable]
      row  31×1  @0 #0a08 [comfortable]
        label "Stats"  5×1  @0 #7162
        toggle "hash on edit"  16×1  @1 #b4a9 [msg]
        numberField "ms"  6×1  @2 #f550 [msg]
      label "computing… (query ab)"  21×1  @1 #c960
      keyValue "NarHash"  19×1  @2 #2099 key [msg]
      keyValue "castore"  15×1  @2 #f10e key [msg]
      label "click a name to copy it"  23×1  @3 #4572
  mapMsg  31×9  @3 #6e7f [comfortable]
    memo  31×9  @0 #5939 [comfortable] memoKey #ba82
      column  31×9  @0 #fe2e [comfortable]
        … (same as above)
── diagnostics ──
messages type-check: true (checked at each `ui.on`, at run time)
── events ──
update: stats ▸ toggle hash-on-edit
update: stats ▸ debounce = 500 ms
update: stats ▸ copy castore
```

The keyed rows sit directly under the pane's column (no fragment node):
`mapKeyed` splices its rows into the one argument position (`@2`) it
occupies, so for layout they are the column's own children (as in Clay). The
"click a name" label keeps `@3` whether or not `computing` shows.

### Subtrees as values (`subtrees`, `wide = true` / `false`)

```d
Node card(ref Ui ui, string title, scope ChildFn content) @safe pure nothrow @nogc
    => ui.column(gap: 0, children: ui.label(slot: Slot.heading, text: title), content());

Node memberList(ref Ui ui, in IdsView ids,
    scope Node delegate(in MemberRow) @safe pure nothrow @nogc row) @safe pure nothrow @nogc
    => ui.column(children: ids.rows.toUi(ui).mapKeyed!(r => r.name, r => row(r)));

Node subtrees(ref Ui ui, in IdsView ids, bool wide) @safe pure nothrow @nogc
{
    scope ChildFn names = () => ui.column(children:
        ids.rows.toUi(ui).mapKeyed!(r => r.name, r => ui.label(text: r.name)));
    return ui.column(gap: 1, children:
        card(ui, title: "(a) inline content", content: () => ui.label(text: ids.query)),
        card(ui, title: "(b) stored content", content: names),
        ui.row(gap: 3, children:
            ui.column(children: ui.label(text: "left"), wide ? names() : Node.none),
            ui.column(env: ui.env.withDensity(Density.compact), children:
                ui.label(text: "right"), wide ? Node.none : names()),
        ),
        memberList(ui, ids, (in MemberRow r) => ui.label(text: r.value)),
    );
}
```

A subtree-as-value is a `scope ChildFn` — a builder, not a built tree. It is
built _where it is placed_, under that place's env (`wide = false` shows the
stored `names` under the compact right column, `[compact]`). It can be placed
twice (here: in the card and in the row); each placement is a separate build
with its own ids. The `card`'s `content` parameter is an ordinary `scope`
delegate; `() => …` at the call site needs no `@nogc` workaround (that part
compiles on stock compilers too — it is not lazy).

### The hazard (`misplaced`)

```d
Node misplaced(ref Ui ui) @safe pure nothrow @nogc
{
    auto early = ui.label(text: "early"); // built now, before the column
    return ui.column(env: ui.env.withDensity(Density.compact), children:
        ui.label(text: "a"), early);
}
```

```
── hazard: a Node built outside a children slot ──
label "early"  5×1  @0 #642b
column  1×1  @0 #642b [compact]
  label "a"  1×1  @0 #af27
  ! slotAlreadyTaken: column #642b opened in a slot already taken by label "early" #642b, built outside a children slot
  ! childBuiltOutsideSlot: label "early" #642b was passed as child @1 of column #642b but built before it opened
```

`early` is built under whatever was open (the frame's root slot), lands as a
sibling _before_ the column, not compact, and the column's second slot only
returns its old handle. It type-checks (`rejected()` asserts that it
compiles). The debug check is two-part: each slot is "armed" before its
delegate runs and the first `open` consumes it (a second open in one slot →
`slotAlreadyTaken`), and a slot that returns a node with an index below the
node count at slot start → `childBuiltOutsideSlot`. Both are `debug`-only;
`-b checked` prints the misplaced tree without diagnostics.

### `bad` (missing `mapMsg` on the eager pane)

```
── diagnostics ──
  ! messageTypeMismatch: row #4d65 sends SumType!(ToggleHash, SetDebounce, CopyName) where SumType!(SumType!(ToggleHash, SetDebounce, CopyName), Quit) is expected
  ! messageTypeMismatch: row #4d65 sends SumType!(ToggleHash, SetDebounce, CopyName) where …
  ! messageTypeMismatch: column #2dd7 sends SumType!(ToggleHash, SetDebounce, CopyName) where …
  ! messageTypeMismatch: column #2dd7 sends SumType!(ToggleHash, SetDebounce, CopyName) where …
messages type-check: false (checked at each `ui.on`, at run time)
```

The check runs **at `ui.on` time** (the enclosing `mapMsg` is open, because
the pane is a lazy child of it), not in an end-of-frame walk. It is **run
time (debug) only**: `ui` is one untyped `Ui`, and the child expression
`statsPane(ui, …)` is written with the outer `ui`, so nothing at compile time
knows it sits under a `mapMsg`. The node named is the _open parent_ (`row`,
`column`), because `ui.on(…)` is an argument of the toggle and runs before
the toggle opens — a debug build could carry the call site instead.

**Typed `Node!M` (probe `probes/typed_node.d`, both patched compilers):**

```
IFTI infers M through a lazy variadic: false
explicit M accepts a NoMsg label next to an A sender: false
explicit M, lifted pane accepted: true, unlifted pane rejected: true
```

It works only if every container names `M` explicitly (`ui.column!StatsMsg(…)`)
and every leaf is typed too (a message-free `label` cannot be a `Node!NoMsg`
that converts to every `Node!M`). Not cheap, so not adopted. The scoped
prototype's `Ui!Msg` retyping gets the compile-time check because the
_builder_ carries the type; here the builder is shared by every child
expression.

### `rejected()`

All `static assert`s pass on both patched compilers:

- named-only attributes: `ui.label(Slot.dim, "x")`;
- `children:` is required: `ui.column(ui.label(…))` hits the first
  sentinel; `ui.row(gap: 2, ui.label(…))` hits `_children`, the second
  sentinel placed right before the variadic (without it, a positional after
  the last named attribute fills `children` silently);
- IES as a single named argument; a bare range as a child; Phobos `map` over
  `toUi`; a non-`Node` child (`42`);
- a capturing payload lambda in `ui.on!`;
- an impure composite as a child (the slot's delegate type is `pure`) and
  `ui.memo!impurePane`;
- storing a `scope ChildFn` beyond its scope (dip1000);
- and, _not_ rejected: `(Node early) => ui.column(children: early)` — the
  hazard.

## Compiler errors and limitations hit

- Stock DMD/LDC: the closure error above, on every view.
- `mapKeyed` as a `Ui` method template taking local lambdas by alias would
  need a dual context; it is a free function (same as the scoped prototype's
  `record`).
- `file.ptr` is rejected in `@safe` (bench's scoped file-hash cache): used
  `file !is lastFile` (slice identity) instead.
- Bench: `dub test` needs `targetType "library"` (otherwise
  `register.d(17,9): static assert: "Couldn't find 'dub_test_root'"`).
- Bench, DMD: `-checkaction=context` left `_d_assert_fail!(int)` and
  `!(const ulong)` unemitted → `ld.lld: error: undefined symbol`; the DMD
  bench uses plain asserts (`-allinst` only).
- Bench: `sparkles.base.pool.text_pool.TextPool.compact` keeps a
  `uint[slots]` on the stack; at 2^19 slots that is 2 MiB per `intern`
  frame, and the runner's worker stack overflows (`SIGSEGV`). The bench uses a
  bump text store (`benchtext.d`) in all three builders.
- Bench: **registered `benchCase` closures are not GC roots in the runner**.
  With hundreds of MiB allocated between registration and measurement, a
  collection freed them and every case crashed with SIGSEGV ("worker crashed
  … killed by signal 11 while measuring this case"). Fixed by keeping the
  closures' context pointers in a `__gshared` array (`keepAlive` in
  `bench.d`). That worked, for another reason than the one given: the cases
  were always visible to the collector. LDC 1.43's frontend inferred
  `benchCase`'s `timed` and `after` parameters `scope`, so the caller kept the
  frame their closures point into on the stack, dead by the time the runner
  measured; storing the pointers is an escape the analysis sees.
  Fixed in `sparkles:test-harness` on branch `fix/base-bench-findings`
  (`f800ebdf8`), recorded there as test-runner open issue O14.

## Benchmark

Three builders, same views (Stats pane with N `keyValue` rows; a binary tree
of nested panels, each `column{label, toggle, row{panel, panel}}`), same
node records' content, the same fit computation (inside-out: in `add`,
treating a `mapKeyed` fragment as transparent), the same messages and texts.
Every case is verified on every iteration in `after` (untimed): node count +
pre-order checksum of (kind, w, h, child count) must equal the lazy builder's
reference, and the three builders agree on every tree before registration.
`benchCase` per-call timing; the `Ui` is heap-owned and `reset()` (untimed)
between iterations. Inputs and results go through `blackBox`. Build type
`bench` (asserts live), `-enable-cross-module-inlining -linkonce-templates`
on LDC (the views are in their own modules, as an app's would be).

Bench-only changes to the copied sketches (all three get the same):
capacities (8 MiB argument arena), `BumpTextPool` instead of `TextPool`
(stack, above), `reset()`, `checksum()`. To the inside-out copy: `w`/`h` and
`fit`. To the scoped copy: the sibling scan in `identify` runs for a keyed
node only in debug builds (it is the duplicate-key diagnostic; the prototype
always ran it, O(siblings) per node, i.e. quadratic for 100 000 rows), and
the call-site file hash is cached by slice identity (`unittest-nocache`
restores per-node `fnv(__FILE__)`).

The inside-out builder skips its deferred `expand` walk (no deferred
composites in these views) but keeps its inherent costs: children collected
into a `UniqueBuffer!(Node, 16)` (heap beyond 16 rows) and copied into `kids`.

Host: AMD Ryzen 9 7940HX, load average 4–6 during the runs (other jobs).
LDC rows were run twice (both shown, `a/b`), they agree within ~3 %.

### Per node, LDC (patched), `HeapBuffer` as the prototypes use it

ns/node (run 1/run 2) — (instructions/node, IPC)

| size        |  nodes |             inside-out |          lazy-variadic |            scoped-with |
| ----------- | -----: | ---------------------: | ---------------------: | ---------------------: |
| rows=10     |     17 | 37.7/37.1 (1038, 1.70) | 54.8/56.0 (1410, 2.00) | 75.5/76.6 (1930, 2.37) |
| rows=1000   |   1007 | 43.1/41.7 (1035, 4.82) | 65.6/64.3 (1435, 4.63) | 84.9/82.5 (1856, 4.70) |
| rows=100000 | 100007 | 45.1/46.3 (1031, 4.89) | 66.4/66.8 (1435, 4.73) | 85.0/84.8 (1855, 4.65) |
| depth=4     |    108 |  27.9/27.7 (669, 3.42) |  41.5/41.6 (946, 3.58) | 62.5/61.8 (1448, 3.91) |
| depth=9     |   3580 |  27.4/27.9 (641, 4.94) |  44.3/44.2 (920, 4.57) | 66.6/66.4 (1414, 4.59) |
| depth=14    | 114684 |  27.5/29.0 (640, 5.05) |  43.2/44.3 (919, 4.56) | 66.5/66.0 (1413, 4.75) |

### Per node, LDC (patched), `RawBuf` (bare malloc'd tables in all three)

| size        |  nodes |            inside-out |         lazy-variadic |           scoped-with |
| ----------- | -----: | --------------------: | --------------------: | --------------------: |
| rows=10     |     17 | 30.1/31.2 (790, 1.34) | 39.5/41.2 (868, 1.40) | 50.1/50.1 (960, 1.43) |
| rows=1000   |   1007 | 38.8/40.0 (819, 4.18) | 51.4/50.5 (872, 3.39) | 58.5/58.4 (938, 3.23) |
| rows=100000 | 100007 | 42.6/42.7 (816, 4.03) | 53.0/53.2 (872, 3.47) | 64.8/64.3 (937, 3.06) |
| depth=4     |    108 | 14.9/15.4 (316, 2.24) | 25.5/25.4 (344, 1.72) | 30.2/30.1 (421, 1.95) |
| depth=9     |   3580 | 15.3/15.5 (284, 3.45) | 26.5/26.5 (313, 2.45) | 31.3/31.1 (386, 2.54) |
| depth=14    | 114684 | 15.8/15.7 (283, 3.85) | 25.2/25.3 (312, 2.54) | 31.5/31.0 (385, 2.42) |

### Per node, patched DMD (one run each)

| size        | inside-out HB |      lazy HB |    scoped HB | inside-out Raw |     lazy Raw |   scoped Raw |
| ----------- | ------------: | -----------: | -----------: | -------------: | -----------: | -----------: |
| rows=10     |  103.7 (1748) | 130.2 (2015) | 153.3 (2690) |    79.6 (1220) | 102.0 (1386) |  93.1 (1445) |
| rows=1000   |  120.5 (1839) | 150.4 (2084) | 167.0 (2645) |    91.5 (1298) | 117.0 (1404) |  98.8 (1406) |
| rows=100000 |  127.5 (1836) | 156.7 (2085) | 176.9 (2644) |    98.7 (1295) | 122.3 (1405) | 106.6 (1406) |
| depth=4     |   70.8 (1062) |  93.3 (1397) | 116.1 (1983) |     41.6 (507) |   56.9 (701) |   64.2 (745) |
| depth=9     |   73.1 (1034) |  95.7 (1373) | 118.3 (1944) |     42.5 (474) |   58.4 (669) |   61.9 (707) |
| depth=14    |   78.0 (1033) |  99.1 (1372) | 122.8 (1943) |     44.2 (474) |   58.2 (668) |   60.4 (706) |

Scoped with the prototype's uncached `fnv(__FILE__)` per node (LDC,
HeapBuffer): 86–91 ns/node for the Stats pane (+1–6 ns), 71–75 for panels
(+8): see `bench/results/ldc-nocache-1.txt`.

Raw tables: `bench/results/*.txt`; per-node
tables: `bench/results/tables.md`.

### Where the difference goes

- **Delegate calls are not the cost on LDC.** In the LDC binary the child
  delegates are devirtualised from the constant array literal and almost all
  inlined: `views_lazy.panel` contains no indirect call — only direct calls to
  `open`/`close`, two recursive `panel` calls and two outlined delegate
  literals called _directly_; `mapKeyed`'s per-row `() => row(e)` is inlined
  (its only calls are `keyValue` and `on`). On DMD they are real indirect
  calls: `container` is not inlined and calls each child through the array,
  `mapKeyed` calls the row through `call *%r12` — which is why lazy is the
  slowest DMD builder once the buffer overhead is removed (RawBuf, Stats
  rows).
- With RawBuf, lazy executes only **+29 (panels) / +56 (rows)
  instructions/node** over inside-out (+10 %/+7 %) but takes **+10 ns/node**
  (+60 % panels, +25 % rows) at a lower IPC (2.5 vs 3.9; 3.5 vs 4.0). The
  profile puts it in `Ui.open` (not inlined; the top lazy symbol): a top-down
  `open` appends a 160-byte record and then _updates two earlier records_
  (`nodes[parent].lastChild/childCount`, `nodes[lastChild].nextSibling`),
  and the id is a serial chain through the parent's id; `close` walks the
  children again for the fit. Inside-out writes each record once, with all
  children known. Scoped does the same as lazy plus the site hash and the
  sibling scan, and its records are 184 bytes (lazy 160, inside-out 136).
- **`HeapBuffer`'s mutable `opIndex` is expensive**: with `Storage.unique`
  it still calls `ensureUniqueStorage` (outlined, computes
  `roundedCapacity`) on every access. The linked top-down builders index the
  node table several times per node, so the HeapBuffer tables cost lazy
  ~+610 and scoped ~+1030 instr/node in the panel tree vs ~+360 for inside-out.
  That is a `sparkles.base.buffer` fix (skip `ensureUniqueStorage` for
  `unique` storage, or hoist a `T[]` view in the builder), not a property of
  any API; RawBuf shows the builders' own cost.
  (Fixed since, as BUF16: mutable access on unique storage no longer
  checks uniqueness. The tables here predate the fix.)
- What dominates everywhere is per-leaf work shared by all three: text
  interning, `ui.on` (SumType construction + `InSituRegion.allocate` + an
  array copy with `-checkaction` conformance checks): ~800 instr/node for a
  `keyValue` row on every builder.

Summary: on LDC the lazy-variadic builder costs ~1.25–1.6× the inside-out one
per node (≈ +10 ns) and is ~1.2–1.5× faster than the scoped `with` builder;
on DMD it is ~1.25–1.3× inside-out with HeapBuffer, and slower than scoped
once buffers are raw (unInlined delegate calls).

## Pros and cons

Compared with **inside-out** (the original `ui-api-demo`):

- \+ Same expression surface (`=>` views, ternary + `Node.none`, `mapKeyed`,
  `mapMsg!fn(child)`), but children see their ancestors' env: no
  `componentForm`, no value forms, no `place`, no argument arena for
  composites, no `@trusted` "the frame outlives the arguments" contract, no
  deferred `expand` pass. One way to call a composite.
- \+ Fit size computed at close with the children already linked; no
  `UniqueBuffer` collecting rows, no `kids` copy.
- \+ The message check happens at `ui.on` (no end-of-frame walk), naming
  where it happened.
- − Needs the compiler patch for `@nogc` (stock DMD/LDC: closure error;
  without `@nogc` a GC closure per view call).
- − The hazard: any `Node` expression _outside_ a slot (a local in a view
  body, a helper called for its value) builds immediately, in the wrong
  place, and type-checks. Only a debug check catches it. Inside-out had no
  such mode: building was always "now".
- − ~1.3–1.6× build cost per node (LDC); more on DMD where the delegates are
  not inlined.
- − `children:` must be required by a second sentinel, or a positional after
  the last attribute silently becomes a child.

Compared with **scoped `with`**:

- \+ Views stay expressions: `=>` bodies, ternaries, composites returning
  `Node`; a subtree as a value is a `scope ChildFn` you can store, pass
  (`card(content:)`), and place in one of two places — the owner's main
  concern with `with`.
- \+ Identity by argument position needs no `__FILE__`/`__LINE__` (or
  `getLocation`) per call: no site hash, no occurrence counting, no repeated-
  site diagnostics; keyed lists are explicit. Cheaper (≈ 0.65–0.82× scoped's
  cost per node on LDC).
- \+ No `@mustuse` / non-copyable handle rules to learn; nothing can be
  "opened and forgotten".
- − The message-type check is run time only. Scoped retypes the builder per
  `mapMsg` scope (`Ui!StatsMsg`) and rejects a missing `mapMsg` at compile
  time; the lazy children all share one untyped `ui`, and a typed `Node!M`
  needs explicit `!M` on every container (probe).
- − Plain `if`/`foreach`/early `return` inside a view are not available in
  an expression; you get ternaries + `Node.none` and `mapKeyed`/`mapByIndex`
  (which is the agreed UI-Q2 style anyway).
- − The misplaced-`Node` hazard has no analogue in scoped (there everything
  is a statement under an explicit open scope).
- − Depends on a compiler patch; scoped works on stock compilers.

## Children stack (`bench/src/lazystack.d`, builder `lazy-stack`)

The lazy-variadic builder with Clay's children stack instead of linked
children. Per element:

- `open` appends the record once and pushes `OpenRec{node, pendingBase, id}`;
  a child's id reads its parent's id from the open stack, never its record.
- A closed element pushes `Pending{node, w, h}` on the children stack. The
  parent's `close` reduces its contiguous run for the fit size, copies the
  indices into the `kids` table (`kidStart`, `childCount`), and pops the run:
  no earlier record is updated, no sibling chain is walked.
- A leaf appends and pushes `Pending` directly (no open/close round trip).
- `NodeRec` 160 → 152 bytes (`firstChild/lastChild/nextSibling` → `kidStart`).
- `open`/`close`/`leaf` are `pragma(inline, true)`; without it they stay
  outlined and panels cost +5–7 ns/node more (`results/stack-ldc-*.txt`).

Every run asserts the four builders produce identical trees before
registering (node count + checksum), and `after` re-checks every iteration.

ns/node (instructions/node, IPC), patched LDC, `-b bench`, load avg ~3:

| size        | inside-out HB |     lazy HB | **lazy-stack HB** | inside-out Raw |   lazy Raw | **lazy-stack Raw** |
| ----------- | ------------: | ----------: | ----------------: | -------------: | ---------: | -----------------: |
| rows=10     |   36.5 (1040) | 59.5 (1410) |    **34.8 (964)** |     31.2 (790) | 40.7 (869) |     **33.0 (825)** |
| rows=1000   |   42.4 (1035) | 65.8 (1435) |    **39.9 (905)** |     40.3 (820) | 50.8 (872) |     **40.7 (786)** |
| rows=100000 |   48.8 (1031) | 68.1 (1435) |    **42.3 (904)** |     45.8 (816) | 53.5 (872) |     **42.0 (785)** |
| depth=4     |    27.4 (669) |  43.6 (946) |    **28.9 (606)** |     15.0 (316) | 25.9 (345) |     **20.8 (375)** |
| depth=9     |    28.2 (641) |  44.6 (920) |    **29.9 (576)** |     15.2 (284) | 24.8 (313) |     **20.8 (343)** |
| depth=14    |    27.3 (640) |  45.4 (919) |    **30.4 (575)** |     15.8 (283) | 25.3 (312) |     **21.0 (342)** |

(`results/stack-inline-ldc-1.txt`, `results/stack-inline-ldc-rawbuf-1.txt`;
the non-inlined runs `stack-ldc-{1,2}`, `stack-ldc-rawbuf-{1,2}` agree within ~3 %.)

The Stats pane (leaf-heavy) is now at or below inside-out (−5 to −13 % with
HeapBuffer); the container-heavy panel tree is +5–11 % with HeapBuffer and
+35 % (≈ +5 ns) on raw tables, where it runs ~20 % more instructions: the
remaining cost is per _container_ (open-stack push, the run copy into `kids`,
the env save/restore), half of the panel tree's nodes. The hottest
instructions in `leaf` are the two 64-byte stores of the 152-byte record —
the record size, shared by every builder, is the next lever (hot layout
fields in SoA, as `layout-fit-bench` recommends).

## Hot layout fields out of the record (`lazysplit.d`, `lazysoa.d`)

Two copies of the children-stack builder (generated from `lazystack.d` by
a throwaway script), differing only in where the layout fields (parent, kid
range, gap, kind, fit size, position) live:

- `lazy-split`: one `FrameBuf!Hot` of 36-byte records beside a 136-byte cold
  `NodeRec` (hot/cold split).
- `lazy-soa`: one `FrameBuf` per field (9 arrays), same cold record.
- `lazy-stack` (AoS) keeps everything in its 160-byte record (x, y added).

A new `place` pass (one sweep in node order: each container positions its
children from their fit sizes and its gap) measures what a layout pass gains;
it's timed on a built tree, and `after` checks the positions hash against
`lazy-stack`'s. Build rows are checked as before. Patched LDC, `-b bench`,
one run (`results/soa-ldc-1.txt`, `results/soa-ldc-rawbuf-1.txt`).

ns/node (instructions/node):

| pass       | size        |  inside-out | lazy-stack (AoS) | lazy-split |    lazy-soa |
| ---------- | ----------- | ----------: | ---------------: | ---------: | ----------: |
| build, HB  | rows=1000   | 42.4 (1035) |       39.4 (907) | 42.0 (969) | 59.6 (1432) |
| build, HB  | rows=100000 | 45.1 (1031) |       40.0 (906) | 42.4 (968) | 61.5 (1430) |
| build, HB  | depth=9     |  27.1 (641) |       29.2 (578) | 31.8 (651) | 55.9 (1217) |
| build, HB  | depth=14    |  26.7 (640) |       29.2 (578) | 32.8 (650) | 57.3 (1216) |
| build, Raw | rows=1000   |  39.8 (819) |       39.4 (788) | 40.3 (802) |  42.0 (853) |
| build, Raw | rows=100000 |  42.0 (816) |       40.3 (787) | 41.2 (801) |  44.5 (852) |
| build, Raw | depth=9     |  15.0 (284) |       19.6 (346) | 20.0 (363) |  22.2 (426) |
| build, Raw | depth=14    |  15.7 (283) |       20.5 (345) | 20.6 (362) |  26.7 (425) |
| place, HB  | rows=100000 |           — |       6.37 (145) |  1.01 (20) |   0.85 (24) |
| place, HB  | depth=14    |           — |       8.36 (189) |  1.43 (27) |   1.95 (36) |
| place, Raw | rows=1000   |           — |        1.23 (28) |  1.00 (24) |   1.05 (27) |
| place, Raw | rows=100000 |           — |        2.03 (24) |  1.05 (20) |   1.10 (23) |
| place, Raw | depth=9     |           — |        1.79 (30) |  1.23 (28) |   1.54 (36) |
| place, Raw | depth=14    |           — |        2.16 (29) |  1.41 (27) |   1.80 (35) |

- The build doesn't get faster: it writes every field either way. Split costs
  +0–1 ns/node on raw tables; pure SoA +2–6 (nine append streams), and with
  `HeapBuffer` +17–28, because every append and `setFit` index pays the
  outlined `ensureUniqueStorage` (being fixed in `sparkles.base.buffer`).
- The layout pass does: on raw tables split is 1.3–1.9× faster than AoS
  (35–48 % less time at 10^5 nodes, where the 160-byte records stream through
  cache; same instruction count, higher IPC). With `HeapBuffer` the AoS pass
  is 6–8 ns/node (145–189 instr) — almost all `ensureUniqueStorage` on
  `nodes[c]` — against ~1 for split/SoA, which index raw slices.
- Pure SoA loses to split in `place`: each child's update touches four arrays
  (w or h, x, y and the loop's reads), i.e. four cache lines where the split
  record needs one. The access pattern is per node, all fields — a hot
  _record_, not per-field arrays.

## Clay (ImportC) (`bench/clay/`, builders `clay-build`, `clay-full`, `clay-side`)

The same two views built with [Clay](https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b) (C,
single header, rev e6cc369, v0.14; `bench/clay/clay.h` is fetched verbatim
at that revision, see [Commands](#commands)),
compiled by ImportC — the D compiler's own C front end — on LDC and DMD, and
called from D. Files: `clay_impl.c` (the ImportC shim, imported as module
`clay_impl` and compiled as a source), `clayui.d` (the D face),
`views_clay.d`, `bench_clay.d` (its own `@benchmark` test,
`ui.build.clay`, so `bench.d` is untouched; `dub.sdl` gains one `importPaths`
and one `sourceFiles` line), and a standalone `dub.sdl` with `smoke.d` (trees
equal, first-frame timings; `-c smoke`) and `loop.d` (`perf stat` driver,
`-c loop`).

### ImportC issues and fixes (nothing in clay.h edited)

1. **SIMD headers.** GCC 16's `<emmintrin.h>`/`<mmintrin.h>` declare 2/4/8-byte
   `vector_size` typedefs, which ImportC rejects on both compilers ("vector
   type `__vector(int[2])` is not supported on this platform").
   Fix: `#define CLAY_DISABLE_SIMD`. It only switches `Clay__HashData` (the
   text-measure cache key) and `Clay__MemCmp` to scalar loops, and neither runs
   for the elements this bench declares.
2. **LDC only: "no init symbol for zero-initialized struct" (fatal).** Clay's
   `CLAY(id, { })` / `CLAY_AUTO_ID()` expand to
   `Clay__ConfigureOpenElement((Wrapper){ { } }.wrapped)`. The frontend folds the
   all-default compound literal to `Clay_ElementDeclaration.init`, and LDC's
   codegen (`gen/llvmhelpers.cpp`, `DtoSymbolAddress`) has no init symbol for a
   zero-init struct. Reduced:
   `typedef struct { Inner wrapped; } W; void h(void) { g((W){ { } }.wrapped); }`.
   DMD compiles it; `(Inner){ }` alone and assigning to a local first both work
   on LDC. Only Clay's debug view (2 sites) hits it. Fix: include clay.h once
   (declarations), then, before the `CLAY_IMPLEMENTATION` include, redefine
   `CLAY__CONFIG_WRAPPER` to unwrap through a tiny `static inline` function per
   wrapper type. Same semantics. (An LDC bug worth fixing in the fork.)
3. `#pragma attribute(push, nogc, nothrow)` around both includes, so the
   views stay `nothrow @nogc`. No `pure`: Clay's context is a global.

Not ImportC, but a Clay limit: **an element's child count is a `uint16_t`**
(`Clay__LayoutElementChildren.length`). The `rows=100000` column (100 003
children) wraps to 34 467 and its fit size and child list are wrong, so Clay
has no `rows=100000` case.

### Matching the trees

- Containers: `Clay__OpenElement(); Clay__ConfigureOpenElement(decl)` with FIT
  sizing (Clay's default), no padding, `childGap` = gap, `layoutDirection`
  `TOP_TO_BOTTOM` (column) / `LEFT_TO_RIGHT` (row); `Clay__CloseElement()` when
  the D `with` scope ends (`with (ui.column(gap: 1)) { … }`, a struct whose
  destructor closes — the C macro's `for` latch). Clay's fit at close is ours:
  column w = max child w, h = Σ child h + gap·(n−1); row the converse.
- Leaves: elements with FIXED w × 1 sizing, the width computed in D with the
  same `cells`/`digits` the sketches use (label = cells; toggle = cells + 4;
  numberField = digits + 1 + unit cells; keyValue = name + 1 + value), and a
  background colour so each leaf emits one RECTANGLE render command at
  `Clay_EndLayout`. Not text elements: a text element is a leaf of the same
  shape, but its width comes from the measure callback _per word_ (the cache
  splits on spaces), so a label could match, while a toggle's +4, a number
  field's digits or a key-value pair's two texts cannot without extra child
  elements, i.e. a different tree. Fixed boxes reproduce every size exactly.
- Ids: auto ids (`Clay__HashNumber(sibling index, parent id)`) everywhere; each
  `keyValue` row is `Clay__OpenElementWithId(Clay__HashString(name,
Clay_GetOpenElementId()))` = `CLAY(CLAY_SID_LOCAL(name), …)`.
- Density, which the sketches read from `ui.env`, is a field of the `ClayUi`;
  the "computing…" label is formatted into a scratch with `writeText`, as
  `ui.text` does.
- The checksum walks Clay's own storage: `context->layoutElements.internalArray[i]`
  from index 1 (index 0 is Clay's `Clay__RootContainer`, the only structural
  difference: our root is its single child), `dimensions` (set by
  `Clay__CloseElement`), `children.elements[0 .. children.length]` (indices
  into `layoutElementChildren`, valid once the element closed) and the kind,
  carried in the declaration's `userData`. Same (kind, w, h, child count)
  pre-order hash and count as the reference; checked before registering and in
  every `after`, both after the build and after `Clay_EndLayout` (which leaves
  the fit sizes alone: the root is 1e9 × 1e9, so nothing shrinks or is culled).
- `depth=14`: Clay reports 88 duplicate ids per frame — its 32-bit auto ids
  (one-at-a-time hash of sibling index and parent id) collide among 114 684
  elements; Clay resolves them (the later element replaces the earlier in the
  hash map) and the layout is unaffected.

### The cases

- `clay-build`: `Clay_BeginLayout` + declaring every element (fit at close).
  `Clay_EndLayout` runs untimed in `after`, so Clay's cross-frame state (hash
  map generations) evolves as in a real frame loop.
- `clay-full`: the same plus `Clay_EndLayout` timed (final sizing passes,
  positions, render commands).
- `clay-side`: `clay-build` plus the per-leaf side work the sketches do and
  Clay does not: every text interned into a `BumpTextPool` and every `ui.on`
  copied into an `InSituRegion` + message table, as `lazystack.Ui.on` does
  (`ClayUi!true`; the tables are `FrameBuf`, so RawBuf applies to them).
  Not reproduced: env/disabled propagation and the debug diagnostics (off in
  `-b bench` anyway).

### Per node, patched LDC, `-b bench`

ns/node, run 1/run 2 (instructions/node, IPC). Load average ~2–3.
`results/clay-ldc-{1,2}.txt`, `results/clay-ldc-rawbuf-{1,2}.txt`.

`HeapBuffer` config:

| size        |  nodes |            clay-build |                clay-full |              clay-side |            lazy-stack |             inside-out |
| ----------- | -----: | --------------------: | -----------------------: | ---------------------: | --------------------: | ---------------------: |
| rows=10     |     17 | 58.9/59.5 (854, 1.16) |   99.1/99.6 (1593, 1.67) | 73.7/74.2 (1119, 1.39) | 34.2/34.2 (966, 1.58) | 35.9/36.5 (1040, 1.66) |
| rows=1000   |   1007 | 62.1/61.6 (679, 2.18) |   99.5/99.8 (1284, 2.63) | 79.2/79.7 (1049, 2.69) | 38.0/37.9 (907, 4.81) | 43.8/42.2 (1035, 4.80) |
| rows=100000 | 100007 |                     — |                        — |                      — | 39.7/40.5 (906, 4.82) | 47.0/46.8 (1031, 4.70) |
| depth=4     |    108 | 52.4/53.9 (517, 1.58) |   87.6/90.4 (1219, 2.45) |  57.5/58.8 (625, 1.79) | 27.5/28.4 (608, 3.04) |  26.9/29.0 (669, 3.30) |
| depth=9     |   3580 | 55.8/57.3 (482, 1.72) | 100.7/102.0 (1175, 2.39) |  61.8/61.6 (590, 1.93) | 28.9/28.7 (578, 4.25) |  28.7/27.8 (641, 4.71) |
| depth=14    | 114684 | 80.6/72.6 (481, 1.33) | 244.3/237.1 (1175, 0.96) |  78.6/78.3 (589, 1.50) | 28.6/28.8 (577, 4.24) |  27.8/27.7 (640, 4.77) |

`RawBuf` config (Clay itself is unaffected; only `clay-side`'s tables and the
sketches change):

| size        |  nodes |            clay-build |                clay-full |              clay-side |            lazy-stack |            inside-out |
| ----------- | -----: | --------------------: | -----------------------: | ---------------------: | --------------------: | --------------------: |
| rows=10     |     17 | 58.9/58.9 (854, 1.16) |   96.7/96.7 (1592, 1.67) | 80.7/80.8 (1153, 1.38) | 31.8/31.2 (828, 1.40) | 30.1/30.1 (789, 1.35) |
| rows=1000   |   1007 | 61.5/63.0 (679, 2.19) |  98.7/101.4 (1284, 2.60) | 86.7/87.1 (1108, 2.58) | 38.7/39.4 (788, 4.11) | 39.6/40.7 (820, 4.14) |
| rows=100000 | 100007 |                     — |                        — |                      — | 41.3/41.4 (787, 4.08) | 44.3/44.2 (816, 3.87) |
| depth=4     |    108 | 53.1/52.6 (516, 1.57) |   87.6/89.5 (1219, 2.42) |  50.9/51.9 (597, 1.86) | 18.9/19.0 (377, 2.32) | 14.5/14.6 (316, 2.30) |
| depth=9     |   3580 | 58.4/58.0 (482, 1.74) | 103.0/103.0 (1175, 2.39) |  56.3/56.3 (562, 1.99) | 20.0/19.9 (346, 3.58) | 14.8/15.0 (284, 3.66) |
| depth=14    | 114684 | 74.5/74.9 (481, 1.22) | 248.1/255.2 (1175, 0.92) |  85.5/76.1 (561, 1.42) | 20.0/20.2 (345, 3.25) | 15.4/15.4 (283, 3.94) |

(`clay-side` ≤ `clay-build` at depth 4/9 RawBuf is within run-to-run and code
layout noise: its side work is ~+80–110 instr/node there.)

Patched DMD (smoke test only, `bench/clay -c smoke`): Clay builds and every
tree matches; steady frames (build + end) cost ~260–290 ns/node — DMD's
backend compiles the C too.

First frame vs steady state (LDC, `smoke.d`, fresh context, ns/node, build /
end): the first frame costs 200–380 ns/node to build (`depth=4` 225,
`rows=1000` 206, `depth=14` 244) and 60–190 to end — page faults on the
freshly malloc'd arena (Clay sizes everything for `maxElementCount`: 0.8 MiB
for 1 024 elements, 80 MiB for 114 700) and every id inserted into the hash
map. From the second frame on it is steady (53–61 build, 35–50 end; 71 / 170
at depth 14).

### Why Clay is slower here

Clay's build runs **fewer instructions per node than lazy-stack with
HeapBuffer** in the panel tree (482 vs 578; on raw tables lazy-stack runs
346, side work included), yet takes **~2× the time (55 vs 29 ns/node) at less
than half the IPC (1.7 vs 4.2)**. `perf stat` on `loop.d` (panels depth 9,
20 000 frames, build only, per node):

| per node                                      | clay-build | lazy-stack (HB) |
| --------------------------------------------- | ---------: | --------------: |
| cycles                                        |        303 |             132 |
| instructions                                  |        475 |             567 |
| store-to-load forwards (`ls_stlf`)            |         53 |              17 |
| failed forwards (`ls_bad_status2.stli_other`) |         34 |              13 |
| L1d load misses                               |        8.7 |             3.5 |
| integer divides (`ex_div_count`)              |        1.0 |               0 |

Where it goes (`perf record`/`perf annotate`; in `clay-build` the samples are
`Clay__AddHashMapItem` > `Clay__CloseElement` > `Clay__ConfigureOpenElementPtr`

> `Clay__OpenElement`; the D views themselves are a few %):

- **Big records moved by value.** `Clay_LayoutElement` is 312 bytes (lazy-stack
  152), `Clay_ElementDeclaration` 272. Per element: a 312-byte zeroed local
  copied into `layoutElements` (`Clay_LayoutElementArray_Add` takes it by
  value), the 272-byte declaration built, passed by value and copied again into
  `config` (this is what the `CLAY(…)` macro does too), an 88-byte hash-map item
  built and copied, plus the id string and clip-id arrays — ~1.3 KB written per
  element, mostly in 64-byte AVX-512 stores (`vmovups %zmm0`, the hottest lines
  in `Clay__OpenElement` and `Clay__ConfigureOpenElementPtr`). Re-reading those
  just-stored structs at different widths is what the 34 failed
  store-to-load forwards per node are.
- **A hash map insert per element**, which none of the sketches do (they only
  compute ids). `Clay__AddHashMapItem` takes `elementId % capacity` (a `divl`
  on a runtime capacity: the one divide per node), then walks the bucket's
  chain of 88-byte items at a random index — the L1 misses, and at
  `depth=14` (80 MiB of arena) L2/L3 misses: build 75 ns/node, end 240.
  The hottest instruction (43 % of its samples) is the 32-byte reload of the
  by-value `Clay_ElementId` argument right after the store into the item.
- **Pointer-chasing through the global context.** Nothing inlines across the
  C boundary (each Clay entry point is a call into a separately compiled
  module), and every call starts from `Clay__currentContext`:
  `openLayoutElementStack.internalArray[length - 1]` → `layoutElements[...]`,
  again in Configure, Close and the parent lookup in Open; `ConfigureOpenElement`
  also re-tests floating/clip/transition/aspect-ratio/percent configs each time.
  A C caller compiling its layout in the implementation's TU might get some
  of this inlined.
- **`Clay_EndLayout` costs ~0.8× the build again** (`clay-full` − `clay-build`
  ≈ 38–45 ns/node and 600–700 instr/node, 165 ns at `depth=14`; `Clay__CalculateFinalLayout` and
  `Clay__SizeContainersAlongAxis` are the top two symbols of the whole Clay
  run): a BFS per axis over every element, a DFS for positions with a hash
  lookup per element to store its bounding box, and one render command
  (88 bytes) per leaf. The sketches have no equivalent yet (`bench.d`'s
  `place` pass is the nearest).

What Clay skips that the sketches do: the message table (`ui.on`: SumType
copy, arena allocation, table append), text interning, env/disabled
propagation. `clay-side` adds the first two: +15–18 ns and +370 instr/node for
a key-value row (two texts and a message each), +2–6 ns and +110 instr/node
in the panel tree. Even with none of it, Clay's build is 1.6× (rows) to 1.9×
(panels) lazy-stack's, which does all of it; with it, 2.1× / 2.1×.

Takeaways for `sparkles:ui`: the children stack is what Clay gets right (and
what `lazy-stack` took from it); its per-element cost is the 312-byte
all-features record, the by-value declaration copies and the per-element hash
map insert — the "hot layout fields out of the record" direction
(`lazysplit.d`) is the opposite trade, and an id→element map, if needed,
belongs after the frame, not in `open`.
