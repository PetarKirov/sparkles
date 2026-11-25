# Clay's open/close in D: the scope probe

Two single-file probes of whether [Clay][clay]'s element macro — `CLAY(…) { … }`,
a `for` latch that opens an element, runs the block and closes it — maps onto
D. They are the first step of the [scoped `with` builder](../ui-api-demo-scoped/README.md)
and of the Clay bench's D face ([`clayui.d`](../ui-api-demo-lazy/bench/clay/clayui.d)).

| File        | What                                                                                                                                                               |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `scoped2.d` | `with (ui.column(gap: 1)) { … }`: `column` opens and returns a non-copyable `Opened` handle whose `~this() scope` closes, restoring the context the element pushed |
| `scoped.d`  | the earlier `foreach (_; ui.column(…)) { … }` form, an `opApply` that runs the body once and then closes, even on `break`                                          |

`scoped2.d` shows the three things the scoped design rests on: the context an
element sets (`compact`) is known before any child is built; plain `if`,
`foreach` and early `return` work inside the body; and an early `return`
from two levels down still closes both elements (depth 0 after each frame).

## Commands

From the repository root:

```bash
nix develop -c bash -c 'cd docs/research/ui-authoring/experiments/clay-style && dmd -preview=in -preview=dip1000 -run scoped2.d'
```

```
(LLLL(c))  depth after: 0
(LL(cc)L)  depth after: 0
```

`L` is a label built under the default context, `c` one built under
`compact`; `(` and `)` are an element opening and closing.

`scoped.d` no longer compiles with DMD 2.115 and is kept as the form that was
dropped: nesting two `foreach (_; …)` bodies is now an error (the inner `_`
shadows the outer one, a deprecation in DMD 2.112), and its `@safe` `main`
passes a slice of the stack-allocated `Ui` to `writeln`, which
`-preview=dip1000` rejects. `with` needs neither a loop variable nor a body
delegate, which is why the scoped builder uses it.

<!-- References -->

[clay]: https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b
