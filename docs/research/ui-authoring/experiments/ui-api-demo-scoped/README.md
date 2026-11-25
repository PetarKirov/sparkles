# Approach 1 — plain D, Clay-style top-down scoped construction

`with (ui.column(gap: 1)) { … }` opens an element (appended to the node buffer,
pushed on the open stack, its env pushed); the block builds the children; the
non-copyable handle's `~this() scope` closes it, computing the fit size from
its children right there and popping env and the message scope. Leaves are
plain calls (`ui.label(text: …)`); `if`/`foreach`/early `return` are plain D.

Files: `ui_sketch.d` (the builder), `app.d` (Stats pane, explorer, subtree
demos, `rejected()`, `main`), `dub.sdl`, `probes/site_probe.d`,
`probes/with_probe.d`, `probes/mustuse_probe.d`.

## Commands

From the repository root (stock compilers suffice: nothing here is a lazy
variadic):

```bash
D=docs/research/ui-authoring/experiments/ui-api-demo-scoped
nix develop -c bash -c "cd $D && dub run --compiler=dmd  -c app --skip-registry=all"
nix develop -c bash -c "cd $D && dub run --compiler=ldc2 -c app --skip-registry=all"
# compile-time message check: both FAIL to compile, by design
nix develop -c bash -c "cd $D && dub build --compiler=dmd -c bad    --skip-registry=all"
nix develop -c bash -c "cd $D && dub build --compiler=dmd -c bad-on --skip-registry=all"
# the one hole left for run time
nix develop -c bash -c "cd $D && dub run --compiler=dmd -c bad-runtime --skip-registry=all"
# release-ish: debug diagnostics compiled out
nix develop -c bash -c "cd $D && dub run --compiler=ldc2 -c app -b checked --skip-registry=all"
# probes
nix develop -c bash -c "cd $D/probes && dmd -preview=in -preview=dip1000 -run site_probe.d && ldc2 -preview=in -preview=dip1000 -run site_probe.d"
```

Compilers: DMD v2.115.0-master, LDC 1.43.0 (frontend 2.113). DMD 2.112 cannot
parse the `with (auto stats = …)` declaration; the sparkles dev shell's DMD is
2.115 from `a53596375` on. `-c app` output
is byte-identical on both (diffed). Every component function (`statsPane`,
`explorerView`, `subtrees`, `identityMistakes`, `rejected`) is
`@safe pure nothrow @nogc`; templates (`card`, `cardOf`, `keyedList`, the
primitives) infer.

## Output (`-c app`, DMD and LDC identical)

Dump columns: kind, text, fit size `w×h` (computed at close), `#` = top 16
bits of the id, `key`/`occN` = disambiguator, `[density]` the env an element's
children were built under, `disabled`, `[msg]`.

```
── tree ──
root  31×23  #ee70 [comfortable]
  column  31×23  #5789 [comfortable]
    label "members: 2"  10×1  #a150
    column  31×4  #9d6f [compact] disabled
      mapMsg  31×4  #5097 [compact] disabled
        column  31×4  #29e8 [compact] disabled
          row  31×1  #6d13 [compact] disabled
            label "Stats"  5×1  #e4a7 disabled
            toggle "hash on edit"  16×1  #cd53 disabled [msg]
            numberField "ms"  6×1  #a867 disabled [msg]
          label "computing… (query ab)"  21×1  #4670 disabled
          keyValue "NarHash"  19×1  #fa28 key disabled [msg]
          keyValue "castore"  15×1  #940d key disabled [msg]
    mapMsg  31×9  #32c2 [comfortable]
      column  31×9  #17b8 [comfortable]
        row  31×1  #9dda [comfortable]
          label "Stats"  5×1  #c0c4
          toggle "hash on edit"  16×1  #1b85 [msg]
          numberField "ms"  6×1  #b26c [msg]
        label "computing… (query ab)"  21×1  #c605
        keyValue "NarHash"  19×1  #3f6e key [msg]
        keyValue "castore"  15×1  #d2d8 key [msg]
        label "click a name to copy it"  23×1  #5c8d
    mapMsg  31×9  #0101 [comfortable]
      memo  31×9  #4990 [comfortable] memoKey #ba82
        column  31×9  #0ceb [comfortable]
          row  31×1  #d66f [comfortable]
            label "Stats"  5×1  #3d0c
            toggle "hash on edit"  16×1  #5f37 [msg]
            numberField "ms"  6×1  #9e02 [msg]
          label "computing… (query ab)"  21×1  #0fba
          keyValue "NarHash"  19×1  #6499 key [msg]
          keyValue "castore"  15×1  #4d31 key [msg]
          label "click a name to copy it"  23×1  #8e08
── diagnostics ──
messages type-check: at compile time (every `ui.on` is checked against its `Ui!Msg`)
── events ──
update: stats ▸ toggle hash-on-edit
update: stats ▸ debounce = 500 ms
update: stats ▸ copy castore
── subtrees as values (wide = true) ──
root  30×19  #ee70 [comfortable]
  column  12×2  #8005 [comfortable]
    label "(a) delegate"  12×1  #adbe
    label "ab"  2×1  #9313
  column  10×2  #0b9a [comfortable]
    label "(a') alias"  10×1  #87d1
    label "ab"  2×1  #8c1d
  row  22×3  #e7b8 [comfortable]
    column  19×3  #4629 key [comfortable]
      keyValue "NarHash"  19×1  #9685 key [msg]
      keyValue "castore"  15×1  #8a89 key [msg]
      fragment  8×1  #adca [comfortable]
        label "recorded"  8×1  #67a4
    column  0×0  #5478 key [comfortable]
  column  30×10  #b1bc [comfortable]
    label "(b) value form"  14×1  #1f0b
    column  30×9  #836c [comfortable]
      row  30×1  #7904 [comfortable]
        label "Stats"  5×1  #56c4
        toggle "hash on edit"  16×1  #a2ea [msg]
        numberField "ms"  5×1  #a936 [msg]
      label "computing… (query ab)"  21×1  #fe53
      keyValue "NarHash"  19×1  #9687 key [msg]
      keyValue "castore"  15×1  #6dd5 key [msg]
      label "click a name to copy it"  23×1  #ecc5
  column  11×2  #fd77 [comfortable]
    row  11×1  #d2ea key [comfortable]
      label "sha256-q2v…"  11×1  #b7c6
    row  7×1  #cb40 key [comfortable]
      label "b3:9f1…"  7×1  #6ca4
  ids: rows' castore #8a89, recorded #67a4
── subtrees as values (wide = false) ──
root  30×19  #ee70 [comfortable]
  column  12×2  #8005 [comfortable]
    label "(a) delegate"  12×1  #adbe
    label "ab"  2×1  #9313
  column  10×2  #0b9a [comfortable]
    label "(a') alias"  10×1  #87d1
    label "ab"  2×1  #8c1d
  row  22×3  #e7b8 [comfortable]
    column  0×0  #4629 key [comfortable]
    column  19×3  #5478 key [comfortable]
      keyValue "NarHash"  19×1  #a535 key [msg]
      keyValue "castore"  15×1  #c504 key [msg]
      fragment  8×1  #a51e [comfortable]
        label "recorded"  8×1  #2af7
  column  30×10  #b1bc [comfortable]
    label "(b) value form"  14×1  #1f0b
    column  30×9  #836c [comfortable]
      row  30×1  #7904 [comfortable]
        label "Stats"  5×1  #56c4
        toggle "hash on edit"  16×1  #a2ea [msg]
        numberField "ms"  5×1  #a936 [msg]
      label "computing… (query ab)"  21×1  #fe53
      keyValue "NarHash"  19×1  #9687 key [msg]
      keyValue "castore"  15×1  #6dd5 key [msg]
      label "click a name to copy it"  23×1  #ecc5
  column  11×2  #fd77 [comfortable]
    row  11×1  #d2ea key [comfortable]
      label "sha256-q2v…"  11×1  #b7c6
    row  7×1  #cb40 key [comfortable]
      label "b3:9f1…"  7×1  #6ca4
  ids: rows' castore #c504, recorded #2af7
── identity mistakes ──
root  7×4  #ee70 [comfortable]
  column  7×2  #ab3f [comfortable]
    label "NarHash"  7×1  #c9fc
    label "castore"  7×1  #86b5 occ1
  fragment  4×1  #1372 [comfortable]
    label "once"  4×1  #eb8c
  column  5×1  #d5ae [compact]
    fragment  5×1  #15eb [comfortable]
      label "early"  5×1  #6d38
  ! repeatWithoutKey at app.d:176 under column at app.d:174
  ! subtreeAttachedTwice at app.d:179
  ! attachedUnderOtherEnv at app.d:183 under column at app.d:182
  ! subtreeNeverAttached at app.d:185
```

`-c bad-runtime` (DMD and LDC):

```
── diagnostics ──
  ! messageUnderWrongMapMsg at app.d:85 under column at app.d:60 (scope expects SumType!(ToggleHash, SetDebounce, CopyName), got SumType!(SumType!(ToggleHash, SetDebounce, CopyName), Quit))
messages type-check: at compile time (every `ui.on` is checked against its `Ui!Msg`)
```

`-b checked`: the identity-mistakes frame prints only
`! subtreeNeverAttached` (the other checks are `debug`-only); `castore`
still gets `occ1`, i.e. a distinct id.

## 1. The message check is compile time

`Ui(Msg)` is the builder typed by the message its user sends. Every `Ui!M`
is exactly one `UiState` field (static-asserted), so
`with (auto stats = ui.mapMsg!liftStats)` returns a `MapScope!StatsMsg` that
`alias this`-es to the _same_ builder retyped as `ref Ui!StatsMsg` (one
`@trusted` pointer cast). Then:

- `ui.on(v)` static-asserts `is(V == Msg)`; `ui.on!fn` asserts
  `ReturnType!fn == Msg`; `mapMsg!fn` asserts `ReturnType!fn == Msg`.
- A pane declares `void statsPane(ref Ui!StatsMsg ui, …)`, so calling it
  without the `mapMsg` is a plain type error.
- `Subtree!Msg` (recorded subtrees) is typed too, so it attaches only under
  the same message type.

`-c bad` (the eager pane without `mapMsg`), DMD and LDC:

```
app.d(72,22): Error: none of the overloads of `statsPane` are callable using argument types `(Ui!(SumType!(SumType!(ToggleHash, SetDebounce, CopyName), Quit)), const(Stats), const(IdsView))`
app.d(30,6):        Candidates are: `app.statsPane(ref Ui!(SumType!(ToggleHash, SetDebounce, CopyName)) ui, in Stats s, in IdsView ids)`
app.d-mixin-54(54,6):                        `statsPane(Args...)(Args args)` … must satisfy one of the following constraints: … `!imported!"ui_sketch".isUi!(Args[0])`
```

`-c bad-on` (a `StatsMsg` sent straight from the explorer):

```
ui_sketch.d(532,9): Error: static assert:  "`ui.on` sends a `SumType!(ToggleHash, SetDebounce, CopyName)` where this `Ui` sends `SumType!(SumType!(ToggleHash, SetDebounce, CopyName), Quit)`: build the composite under `ui.mapMsg!((SumType!(ToggleHash, SetDebounce, CopyName) m) => SumType!(SumType!(ToggleHash, SetDebounce, CopyName), Quit)(m))`"
app.d(82,49):        instantiated from here: `on!(SumType!(ToggleHash, SetDebounce, CopyName))`
```

The one hole: inside a `mapMsg` scope the _outer_ `ui` (`Ui!ExplorerMsg`) is
still in scope, and its `on` type-checks while the node lands under a
`StatsMsg → ExplorerMsg` map. That is caught at run time: `UiState.msgKey`
tracks the innermost open `mapMsg`, and a debug build reports
`messageUnderWrongMapMsg` from `on` (`-c bad-runtime`). `dispatch` keeps its
assertions as a backstop. So: **compile time for everything written
against the `Ui!M` a component was handed; run time (debug) for misuse of
an outer handle.**

`with` scopes cannot themselves carry a static type to an unqualified
`ui.on`: `with` only adds member lookup, and a with-object member named `ui`
is an error (see Limitations). The type has to travel in the variable —
hence `with (auto stats = …) statsPane(stats, …)`.

## 2. Identity

`id = mix(parent.id, hash(file, line), key-hash | occurrence count)`.
Primitives take `string file = __FILE__, size_t line = __LINE__` and
`K key = null` (any hashable type, deduced through the named argument:
`key: r.name`). Occurrence = number of earlier siblings from the same call
site — so an `if` elsewhere never shifts an id; only a repeated call site
(a `foreach`) does, and a debug build reports that:
`! repeatWithoutKey at app.d:176 under column at app.d:174`. An explicit
`key: i` is the positional opt-in (`mapByIndex`). Duplicate keys are
reported too.

A composite reused under one parent (two `card`s) would repeat its inner
call sites; `card` forwards its own `file`/`line` to its outer column, so
identity is the card's call site. That is one parameter pair per reusable
composite.

### Probes (`probes/site_probe.d`), both compilers

| Probe                                                                       | Compiles             | Resolves to                                                    |
| --------------------------------------------------------------------------- | -------------------- | -------------------------------------------------------------- |
| P1 `string file = __FILE__, size_t line = __LINE__`                         | yes                  | **caller** (file, line)                                        |
| P2 `Site s = Site(__FILE__, __LINE__, 0)` (tokens nested in a default expr) | yes                  | **caller** (file, line)                                        |
| P9 `Here h = Here.make()` where `make` has `__LINE__` defaults              | yes                  | **caller** (file, line)                                        |
| P6 template value param `size_t line = __LINE__`                            | yes                  | caller line; one instantiation per call site                   |
| P3 default template alias `alias tag = () {}` + `getLocation`               | yes                  | **declaration** (14:21), same for every call                   |
| P4 explicit lambda `p4!({})()` + `__traits(getLocation, tag)`               | yes                  | **caller, with column** (59:24, 59:56; two on one line differ) |
| P5 lambda in a runtime default arg, `getLocation(__traits(parent, {}))`     | DMD yes / **LDC no** | callee (26:18)                                                 |
| P7 `getLocation(__traits(parent, {}))` in the callee                        | yes                  | callee                                                         |
| P8 `__FUNCTION__`/`__MODULE__` defaults                                     | yes                  | caller function name, no position                              |
| P10 `getLocation` of a runtime lambda argument's type                       | no                   | —                                                              |
| P11/P12 string mixin at the call site                                       | yes                  | `file-mixin-N`, column relative to the mixin (always 1)        |

LDC's P5 error: `Error: cannot inline default argument `(*function () pure
nothrow @nogc @safe => Site("site_probe.d", 26LU, 18LU))()``.

So a **column** is only obtainable by writing a lambda at the call site
(`ui.label!({})(…)`) — noise plus one template instance per call. Not used.
Consequence: two keyless calls of one primitive on **one line** under one
parent share a site and trip `repeatWithoutKey`. A free side effect: an
alias slot (`cardOf!((ref u) {…})`) _does_ have a column-precise location
(`__traits(getLocation, content)`), should slots ever want it.

## 3. Subtrees as values (the important part)

`ui.place(x)` places, where the caller stands, anything that is a subtree:
a value form (`.build(ref Ui!Msg)`), a callable `(ref Ui!Msg)`, or a recorded
`Subtree!Msg`. A slot parameter is therefore just `auto ref C content`
(`card(ui, title:, content:)` in `app.d`). Demo: `subtrees()` frames with
`wide = true/false`.

|                                   | (a) lambda slot                                                                                                  | (b) value form                                     | (c) record, then attach                                               |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- | --------------------------------------------------------------------- |
| call site                         | `card(ui, title: "x", content: (ref Ui!StatsMsg u) { … })`; alias: `cardOf!((ref u) { … })(ui, title: "x")`      | `const pane = statsPane(s, ids); … ui.place(pane)` | `auto t = ui.record!((ref u) { … }); … ui.place(t)`                   |
| `@safe pure nothrow @nogc` caller | yes: a `scope` delegate (or one passed to a template's `auto ref` param) allocates no closure; alias form infers | yes                                                | yes                                                                   |
| parameter inference               | delegate slot needs `(ref Ui!M u)` spelled out; untyped `(ref u)` does **not** compile there; alias slot infers  | n/a                                                | alias, infers                                                         |
| store in a variable               | `scope rows = (ref Ui!StatsMsg u) { … };`                                                                        | yes (POD `Part`, holds copies of the args)         | yes (`Subtree!M`, move-only)                                          |
| place in one of two places        | yes (`if (wide) …place(rows) else …`)                                                                            | yes                                                | yes                                                                   |
| sees the env where placed         | **yes** (built at placement)                                                                                     | **yes**                                            | **no** — built at `record`; debug reports `attachedUnderOtherEnv`     |
| message type                      | checked at compile time (parameter type `Ui!M`)                                                                  | yes (`build(ref Ui!M)`)                            | yes (`Subtree!M`)                                                     |
| identity                          | call sites inside the lambda + placement parent                                                                  | sites inside the composite + placement parent      | re-derived at `attach` (`reidentify`): same rule as building in place |
| misuse caught                     | —                                                                                                                | —                                                  | attached twice / never attached (debug; "never" also in `checked`)    |

What `componentForm` becomes: the same mixin, now producing `Part!(fn, Args)`
whose `build(ref Ui!M)` calls `fn(ui, args)` _where it is placed_. It is no
longer a deferral mechanism — no `place` thunk, no argument arena, no
`@trusted` lifetime contract — only a way to hold "a pane with these
arguments" as a value. (a) covers most cases more cheaply; (b) is what you
want when the value must be POD/comparable (memo keys, storing in a model).

Identity under re-placement, measured: the `castore` row placed under the
`left` column is `#8a89` and under `right` `#c504` (wide=true vs false
in the output). In every form, moving a subtree to another parent changes its
identity (state would be lost), exactly as in React; preserving it would need
a global key (`GlobalKey`-style), not implemented.

A list whose rows a caller supplies:
`keyedList!(r => r.name, (ref u, in r) => u.label(text: r.value))(ui, rows)`;
the list owns the keys.

## 4. Stats pane + explorer: what each placement became

- **deferred** → a plain call inside `with (ui.column(env: compact,
disabled: m.tutorial))`: the column has already pushed its env when the
  pane runs (`[compact] disabled` all the way down, and no hint label).
- **eager** → the same plain call under the caller's env (comfortable).
- **memo** → `stats.memo!statsPane(m.stats, m.ids)`: a `memo` element keyed by
  `hashOf` the arguments and the env (`memoKey`), then the pane built under
  it. A real host would compare `memoKey` with last frame's at the same id
  and splice last frame's nodes — i.e. mechanism (c) across frames. It
  static-asserts the composite is `pure`.
- **conditionals** → plain `if`; **lists** → plain `foreach` with `key:`.
- Fit sizes are computed at close (row = sum + gaps / max; column the
  converse; text = code points), e.g. comfortable pane 31×9, compact 31×4.
- `dispatch` walks parent links through `mapMsg` nodes as before; the three
  `update:` lines match the original demo.

## Limitations and compiler errors hit

1. **`with` member shadowing a local is an error** (so a handle cannot expose
   the retyped builder as `ui`):
   `Error: with symbol `with_probe.Handle!int.ui`is shadowing local symbol`with_probe.shadow.ui``.
   Hence `with (auto stats = ui.mapMsg!lift) statsPane(stats, …)` (a `with`
   declaration — accepted by DMD 2.115 and LDC 1.43). The `alias this` also
   means any local named like a `Ui` member (`text`, `env`, `on`, `label`, …)
   used in that block is a shadowing _error_ (loud, not silent).
2. **Method template + local alias lambda = dual context.** `ui.record!(…)`
   as a method gave
   `Deprecation: function `app.subtrees.record!(…)` function requires a dual-context, which is deprecated`
   and `Error: function `app.subtrees`is`@nogc`yet allocates closure for`subtrees()` with the GC`.
   So `record` is a free function (UFCS keeps `ui.record!(…)()`), and alias
   slot composites (`cardOf`) must be free functions.
3. **dip1000 in `~this() scope`**: restoring a `string` field
   (`st.msgName = savedMsgName`) failed: `Error: assigning scope variable `this`to non-scope`(*this.st).msgName`is not allowed in a`@safe` function`.
   Fixed by restoring only a `ulong` key and recovering names from the tree.
4. Untyped `(ref u) { … }` cannot go to a runtime delegate/`auto ref C`
   slot (no type to infer against) — `rejected()` asserts it.
5. `ui.column();` as a bare statement would open and immediately close an
   empty column. `@mustuse` on the handles rejects it:
   `Error: ignored value of `@mustuse`type`ui_sketch.Opened`; prepend a `cast(void)` if intentional`.
6. No column in identity (see probes) → same-line repeats need a key.
7. One frame per `Ui` (no reset); `@trusted` is confined to `state()` (taking
   `&st` for a handle), `MapScope.inner` (the retyping cast), `keep` and the
   erased message thunks.

## Pros / cons

Pros

- Context just works: no deferred phase, no `place` thunk, no argument arena
  or `@trusted` lifetime contract for composites; `ui.env` read anywhere is
  the resolved env.
- Plain D control flow: `if`, `foreach`, early `return`; no `Node.none`, no
  `toUi(ui).mapKeyed`.
- The message check moved from an end-of-frame walk to **compile time**,
  with a precise run-time backstop for the one hole.
- Fit size is fused into close (Clay), one pass.
- Subtrees as values remain available through three forms with one `place`
  entry point; (a)/(b) are built where placed, so they see the right env.

Cons

- A view is statements; "a subtree value" is a _function_ (lambda or `Part`),
  not built data. Only (c) is built data, and it reintroduces the inside-out
  env problem (reported, not prevented).
- `with (auto stats = ui.mapMsg!lift)` is a new name per scope, and the outer
  `ui` stays visible (run-time check only).
- Delegate slots need the parameter type spelled out; alias slots force
  free-function composites and per-lambda instantiations.
- Identity is line-granular; reusable composites must forward
  `file`/`line` to their outer element, or two uses under one parent collide.
- Forgetting `with` is caught only thanks to `@mustuse`; forgetting the braces
  on a multi-statement `with` body (only the first statement nests) is not.
- `Ui!Msg` makes every generic helper a template over `M`.
