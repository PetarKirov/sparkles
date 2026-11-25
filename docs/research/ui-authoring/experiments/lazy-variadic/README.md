# Lazy variadic children: the probes

Can `ui.column(gap: 1, children: a, b, c)` build top-down — the parent opening
before its children run — when every child is a plain expression? D's
[lazy variadic functions][spec] say yes: a parameter
`scope Node delegate() @safe pure nothrow @nogc[] children...` makes the
compiler wrap each argument in a delegate literal, which the callee calls when
it chooses. These probes established that the surface works, and found that
`@nogc` callers cannot use it on stock compilers: the `scope` that the
specification says prevents a closure does not. This led to the fix tracked as
[dlang/dmd#22885][issue] and to the [lazy-variadic port](../ui-api-demo-lazy/README.md).

> [!IMPORTANT]
> Except as the failing case, these probes need a D frontend with the fix for
> `scope` lazy variadic closures ([dlang/dmd#22885][issue]), carried by the
> sparkles toolchain forks (UD8 for DMD, UL20 for LDC). The flake lock that
> builds them is on branch `build/scope-lazy-variadic-toolchain`; until it is
> merged, use that branch's development shell, or compilers patched the same
> way.

| File          | What                                                                                                                                                                                                                                    |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `min.d`       | the reduction: `sum(scope int delegate() @safe pure nothrow @nogc[] xs...)` called from `@nogc` functions with captured locals, a `ref` parameter and a nested call, beside a plain `scope lazy` parameter                              |
| `probe.d`     | the UI surface: `column`/`label` primitives, context set at open, argument position as identity, named `children:` followed by more positionals, attributes out of declaration order, and a subtree held as a `scope` delegate (`card`) |
| `flat.d`      | one call with a ternary child and `none`                                                                                                                                                                                                |
| `nested.d`    | a lazy child that is itself a lazy-variadic call                                                                                                                                                                                        |
| `nestedptr.d` | the same through a `Ui*`, to rule out the `ref` parameter as the cause                                                                                                                                                                  |
| `base.inc`    | the shared prefix of `probe.d`, `flat.d`, `nested.d` and `nestedptr.d` (each file repeats it)                                                                                                                                           |

## Commands

From the repository root, in a development shell whose compilers carry the
fix:

```bash
nix develop -c bash -c 'cd docs/research/ui-authoring/experiments/lazy-variadic && dmd -preview=in -preview=dip1000 -run probe.d'
nix develop -c bash -c 'cd docs/research/ui-authoring/experiments/lazy-variadic && for f in min flat nested nestedptr; do ldc2 -preview=in -preview=dip1000 -o- $f.d; done'
```

`probe.d` prints, for each call, the order elements opened (`(`), closed
(`)`) and labels were built (`L` under the default context, `c` under
`compact`):

```
pane(ui, true, 2)    (LL(cc)L)
pane(ui, false, 2)   (L(cc)L)
named(ui)            (LL)
reordered(ui)        (c)
bare(ui)             (L)
usesCard(ui)         (L(c))
```

`pane(ui, false, 2)` drops the `computing` label through `none`, and the
labels after it keep their argument positions.

## On stock compilers

Stock DMD 2.112 and LDC 1.43 reject all five files (stock DMD 2.115 rejects
the port's views the same way, `../ui-api-demo-lazy/out/stock-dmd.txt`): every
`@nogc` function that passes an argument reading a local or parameter fails with

```
min.d(3): Error: function `min.g` is `@nogc` yet allocates closure for `g()` with the GC
min.d(3):        delegate `int() => a` closes over variable `a`
```

The plain `scope lazy int` parameter in `min.d` (`m`) compiles: only the
variadic form allocates. Without `@nogc` the code compiles, and allocates a GC
closure per call.

<!-- References -->

[spec]: https://dlang.org/spec/function.html#lazy_variadic_functions
[issue]: https://github.com/dlang/dmd/issues/22885
