# Inside-out: the UI-Q1–UI-Q6 sketch

The first compile-and-run sketch of the `sparkles:ui` authoring API, as the
decisions UI-Q1 to UI-Q6 agreed it (see the [study](../../index.md)). Nothing
lays out or paints: the builder records nodes, text and messages in the
frame's tables, so the demo shows what the API means — the order things are
built in, which context a deferred composite sees, and how a message finds its
way to `update`.

Views are expressions, and D evaluates arguments first, so the tree is built
**inside-out**: `ui.Column(gap: 1, children: [ … ])` receives children that
already exist.

```d
Node statsPane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
    => ui.Column(gap: ui.env.density == Density.compact ? 0 : 1, children: [
        ui.Row(gap: 2, children: [ … ]),
        ids.computing
            ? ui.Label(slot: Slot.dim, text: ui.text(i"computing… (query $(ids.query))"))
            : Node.none,
        ids.rows.toUi(ui).mapKeyed!(r => r.name, r => ui.KeyValue(…)),
        …
    ]);

mixin(componentForm!"statsPane");   // the value form: statsPane(args) without a `Ui`
```

## Files

| File          | What                                                                                                                                                                                     |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ui_sketch.d` | the builder: `Node`, `Node.none`, `Env`, `TextPool`-interned text, erased `MsgRef`s, `mapKeyed`/`mapByIndex`, `mapMsg`, `Composite`, `componentForm`, `memo`, `place`, dump and dispatch |
| `app.d`       | the Stats pane, `explorerView` placing it three ways (deferred, eager, memo), `rejected()` (what the API refuses), `main`                                                                |
| `app_bad.d`   | `app.d` with the eager pane's `mapMsg` dropped                                                                                                                                           |

The tables are `sparkles:base` building blocks, each chosen by its
specification: `HeapBuffer!(T, Storage.unique)` for nodes, child lists and
messages; a `TextPool` for text; an `InlineBuffer` scratch for `ui.text`; an
`InSituRegion` arena for composite arguments and constant messages. `struct Ui`
says why each fits.

## How context reaches a composite

A child is built before its parent exists, so it cannot see the parent's
context (density, `disabled`). A composite whose structure depends on it is
**deferred**: `componentForm` generates a value form holding its arguments,
and `ui.place` copies them into the frame arena and records a `deferred` node.
After the tree is built, an `expand` pass builds each deferred composite
top-down under the context its ancestors resolved. The copy is `@trusted`:
sound only because `frame` runs every deferred thunk before it returns, while
the model the arguments point into is still alive.

`rejected()` asserts, at compile time, that positional attributes, an IES as
one named argument, a bare range or Phobos `map` as a child, a capturing
payload lambda, placing a non-composite and placing an impure composite are
all refused.

## Commands

From the repository root (stock compilers suffice):

```bash
D=docs/research/ui-authoring/experiments/ui-api-demo
nix develop -c bash -c "cd $D && dub run --compiler=dmd  -c app --skip-registry=all"
nix develop -c bash -c "cd $D && dub run --compiler=ldc2 -c app --skip-registry=all"
nix develop -c bash -c "cd $D && dub run --compiler=dmd  -c bad --skip-registry=all"   # the message walk reports false
```

## Output (`-c app`, DMD and LDC identical)

```
── tree ──
deferred (built under density comfortable)
  column
    label "members: 2"
    column disabled env:compact
      mapMsg
        deferred (built under density compact)
          column
            row
              label "Stats"
              toggle "hash on edit" [msg]
              numberField "ms" [msg]
            label "computing… (query ab)"
            fragment
              keyValue "NarHash" [msg] key
              keyValue "castore" [msg] key
            none
    mapMsg
      column
        row
          label "Stats"
          toggle "hash on edit" [msg]
          numberField "ms" [msg]
        label "computing… (query ab)"
        fragment
          keyValue "NarHash" [msg] key
          keyValue "castore" [msg] key
        label "click a name to copy it"
    mapMsg
      deferred (built under density comfortable)
        column
          row
            label "Stats"
            toggle "hash on edit" [msg]
            numberField "ms" [msg]
          label "computing… (query ab)"
          fragment
            keyValue "NarHash" [msg] key
            keyValue "castore" [msg] key
          label "click a name to copy it"
messages type-check: true
── events ──
update: stats ▸ toggle hash-on-edit
update: stats ▸ debounce = 500 ms
update: stats ▸ copy castore
```

The first `deferred` pane is built under `compact` (no hint label, no gaps);
the eager one under the caller's `comfortable`. `-c bad` prints the same tree
with `messages type-check: false`: the end-of-frame walk finds a `StatsMsg` where the explorer expects an `ExplorerMsg`.

## Superseded

UI-Q7 replaced the deferred composites with lazy variadic children built
top-down; see [`../ui-api-demo-lazy/`](../ui-api-demo-lazy/README.md) and the
study's [comparison](../../index.md#the-alternatives). The benchmark's
inside-out builder ([`../ui-api-demo-lazy/bench/src/insideout.d`](../ui-api-demo-lazy/bench/src/insideout.d))
is a copy of this one with fit sizes added.
