# Approach 2: a mixin-based markup DSL — `mixin(markup!q{ … })`

A CTFE parser (`markup.d`, ~700 lines) turns a JSX/Flutter-like token-string
markup into D statements that drive a Clay-style top-down open/close builder
(`ui_sketch.d`, rewritten top-down from the original). `app.d` ports the whole
Stats pane, `explorerView`, `rejected()`, dump, dispatch; `app_bad.d` drops one
`mapMsg`. The original demo is [`../ui-api-demo/`](../ui-api-demo/app.d); `probes/` holds
the scratch files used for the findings below.

## Files

| File                                                         | What                                                                                                                                                                                                 |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `markup.d`                                                   | lexer + recursive-descent generator, all CTFE; `markup!q{}` (statements), `fragment!q{}` (an expression), `markupSource!q{}` (debug: the generated text)                                             |
| `ui_sketch.d`                                                | top-down builder: `Opened` (closes in `~this`), env stack, fit size at close, call-site ids, compile-time message scopes (`@emits!M`, `on!(Expected)`, `MsgTag!M`), runtime walk kept as cross-check |
| `app.d` / `app_bad.d`                                        | the demo / the variant missing a `mapMsg`                                                                                                                                                            |
| `probes/probe{1,2,3}.d`                                      | `__traits(getLocation)` and `#line` inside string mixins                                                                                                                                             |
| `probes/diag_*.d`, `probes/neg/*.d`                          | deliberate errors (type error in an attribute, markup syntax, missing key, wrong message)                                                                                                            |
| `probes/bench.sh`, `probes/gen_stress.sh`, `probes/expand.d` | compile-time cost (`stress_*.d`, `expanded_200.d` are generated)                                                                                                                                     |
| `probes/dc.sh`                                               | `-o-` type-check of a set of files against `sparkles:base` sources                                                                                                                                   |

## The syntax

All D tokens, balanced braces, so it lives in `q{}`:

```
nodes    := node*
node     := 'if' '(' expr ')' block ('else' (node-if | block))?
          | 'foreach' '(' decl ';' range ';' 'key' ':' expr ')' block   // key is mandatory
          | 'auto' ident '=' '{' nodes '}' ';'                          // a fragment variable
          | ident ('(' args? ')')? (block | ';')                        // an element
```

- Primitives (`column`, `row`, `label`, `toggle`, `numberField`, `keyValue`) become
  `ui.label(Site(<ct constant>), slot: …, text: …)`; containers become
  `{ auto __e = ui.column(Site(…), gap: …); children }` (Clay's open/close; `~this` closes).
- Attribute values are spliced **verbatim** (caller's scope, locals visible), with four rewrites:
  `name: i"…"` → `name: ui.text(i"…")`; `ui.on(m)` → `ui.on!(Scope)(m)`; `ui.on!fn` →
  `ui.on!(Scope, fn)`; `name: { markup }` / `name: (params) { markup }` → a `scope` delegate (a fragment).
- `mapMsg(fn) { … }`, `memo(deps: x) { … }`, `embed(fragment, args…)` are built in.
- Any other name is a component: `statsPane(s: …, ids: …)` → `statsPane(ui, s: …, ids: …)`
  inside an identity scope; a trailing block becomes a `children:` fragment (`indent { … }`).
- Named-only attributes stay enforced twice: the generator refuses `label(Slot.dim, "x")`,
  and the primitives keep the private `NamedOnly` sentinel after `Site`.

### The Stats pane, as authored

```d
@emits!StatsMsg
void statsPane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
{
    mixin(markup!q{
        column(gap: ui.env.density == Density.compact ? 0 : 1) {
            row(gap: 2) {
                label(slot: Slot.heading, text: "Stats");
                toggle(on: s.hashOnEdit, label: "hash on edit",
                    onPress: ui.on(StatsMsg(ToggleHash())));
                numberField(value: s.debounceMs, unit: "ms",
                    onChange: ui.on!((int v) => StatsMsg(SetDebounce(v))));
            }
            if (ids.computing) {
                label(slot: Slot.dim, text: i"computing… (query $(ids.query))");
            }
            foreach (r; ids.rows; key: r.name) {
                keyValue(name: r.name, value: r.value,
                    onPress: ui.on(StatsMsg(CopyName(r.name))));
            }
            // Structure chosen from context: only the comfortable layout shows a hint.
            if (ui.env.density == Density.comfortable) {
                label(slot: Slot.dim, text: "click a name to copy it");
            }
        }
    });
}
```

`explorerView` is the same shape: `column { label(…); column(env: ui.env.withDensity(Density.compact),
disabled: m.tutorial) { mapMsg((StatsMsg sm) => ExplorerMsg(sm)) { statsPane(s: m.stats, ids: m.ids); } } … }`.
No deferred/value-form composites, no `componentForm`, no `ui.place`, no `Node.none`, no `mapKeyed`:
top-down construction makes `env` visible to children at open, so the compact pane is simply built compact.

### What it generates (`markupSource!` of the Stats pane body; glue ends the previous line so attributes keep their line _and_ column)

```d
{ struct __mk1_anchor1 {} alias __mk1_M0 = EmitsOf!(EnclosingComponent!__mk1_anchor1);{ auto __mk1_e2 = ui.column(Site(18371814903897551763UL),
               gap: ui.env.density == Density.compact ? 0 : 1);{ auto __mk1_e3 = ui.row(Site(2131733090082291077UL),
                gap: 2);ui.label(Site(16787697276416113934UL),
                      slot: Slot.heading, text: "Stats 1");ui.toggle(Site(2790459084588168475UL),
                       on: s.hashOnEdit, label: "hash on edit", onPress: ui.on!(__mk1_M0)(StatsMsg(ToggleHash())));…
            if (ids.computing){ui.label(Site(4399503489185447757UL),slot: Slot.dim, text:ui.text( i"computing… (query $(ids.query))"));}
            foreach( r; ids.rows) { auto __mk1_k4 = ui.keyed(Site(14956991087457233651UL), r.name);ui.keyValue(…);}
```

## Commands

From the repository root (stock compilers suffice):

```bash
D=docs/research/ui-authoring/experiments/ui-api-demo-markup
nix develop -c bash -c "cd $D && dub run --compiler=dmd  -c app --skip-registry=all"
nix develop -c bash -c "cd $D && dub run --compiler=ldc2 -c app --skip-registry=all"
nix develop -c bash -c "cd $D && dub run --compiler=dmd  -c bad --skip-registry=all"   # fails to compile, by design
nix develop -c bash -c "cd $D && dub run --compiler=ldc2 -c bad --skip-registry=all"   # ditto
nix develop -c bash -c "cd $D && probes/dc.sh dmd probes/diag_type.d app.d ui_sketch.d markup.d"
# compile-time cost: write the stress files first (generated, not committed)
nix develop -c bash -c "cd $D && for n in 1 50 200; do probes/gen_stress.sh \$n; done && probes/bench.sh"
```

`bench.sh` needs GNU `time` on `PATH`. It compares against the inside-out
sketch in [`../ui-api-demo/`](../ui-api-demo/app.d), of which this
experiment's original kept a copy (`orig/`, identical, not kept here).
`probes/expanded_200.d` (the 200-copy stress file with every markup
pre-expanded) was produced with `probes/expand.d`'s `pragma(msg, …)` output
and is not committed either.

Toolchain: DMD v2.115.0-master, LDC 1.43.0 (sparkles dev shell).

## Output (`-c app`; byte-identical on DMD and LDC, ids included)

The dump shows kind, text, fit size (computed at close), the density the
element was built under, flags, and a 16-bit fold of its 64-bit id.

```
── tree ──
column 31×33 (built under density comfortable)  #84b9
  label "members: 2" 10×1  #b5d7
  column 31×4 (built under density compact) disabled env:compact  #0e97
    mapMsg 31×4  #46d8
      column 31×4 (built under density compact)  #0e74
        row 31×1 (built under density compact)  #f254
          label "Stats" 5×1  #0cd9
          toggle "hash on edit" 16×1 [msg]  #acf9
          numberField "ms" 6×1 [msg]  #8121
        label "computing… (query ab)" 21×1  #1329
        keyValue "NarHash" 20×1 [msg] key  #b61c
        keyValue "castore" 16×1 [msg] key  #51c0
  mapMsg 31×9  #757b
    column 31×9 (built under density comfortable)  #b215
      row 31×1 (built under density comfortable)  #7d51
        label "Stats" 5×1  #7b4a
        toggle "hash on edit" 16×1 [msg]  #fcc9
        numberField "ms" 6×1 [msg]  #6171
      label "computing… (query ab)" 21×1  #e9fd
      keyValue "NarHash" 20×1 [msg] key  #d68c
      keyValue "castore" 16×1 [msg] key  #1c4a
      label "click a name to copy it" 23×1  #ec41
  mapMsg 31×9  #dfb0
    memo 31×9  #fb61
      column 31×9 (built under density comfortable)  #6255
        row 31×1 (built under density comfortable)  #5e10
          label "Stats" 5×1  #0d8a
          toggle "hash on edit" 16×1 [msg]  #028e
          numberField "ms" 6×1 [msg]  #8a8a
        label "computing… (query ab)" 21×1  #8595
        keyValue "NarHash" 20×1 [msg] key  #e2dd
        keyValue "castore" 16×1 [msg] key  #0576
        label "click a name to copy it" 23×1  #15e6
  column 18×10 (built under density comfortable)  #3ce7
    column 9×3 (built under density comfortable)  #c42c
      label "┌ Query" 7×1  #5737
      label "query: ab" 9×1  #7138
      keyValue "quit" 7×1 [msg]  #f19c
    row 15×1 (built under density comfortable)  #84dd
      label "busy:" 5×1  #3e46
      label "query: ab" 9×1  #4e81
    mapMsg 13×2  #d2b7
      column 13×2 (built under density comfortable)  #a086
        keyValue "NarHash" 13×1 [msg] key  #96e0
        keyValue "castore" 13×1 [msg] key  #4418
    row 18×1 (built under density comfortable)  #192d
      label "│" 1×1  #46d3
      label "nested children" 15×1  #8a81
messages type-check: compile time (runtime walk agrees: true)
ids unique: true
── events ──
update: stats ▸ toggle hash-on-edit
update: stats ▸ debounce = 500 ms
update: stats ▸ copy castore
update: quit
```

(After the dump the current `app.d` also prints `ids stable under if: true`: a
second frame with `computing = false` drops the `computing…` label, and the
`castore` row keeps its id.) Sizes check out: the compact pane is `row 1 +
computing 1 + 2 rows = 4` with gap 0; the comfortable one 5 children + 4 gaps
= 9; the root 1 + 4 + 9 + 9 + 10 = 33.

## Findings

### 1. Identity: compile-time call-site ids work; `getLocation` adds nothing here

The generator knows each element's exact `file:line:column` at CTFE
(`markup(string src, string file = __FILE__, size_t line = __LINE__)` — the
defaults are evaluated at the `markup!` instantiation site, and the line inside
the markup is counted by the lexer). Each element gets `Site(fnv("app.d:62:17"))`
as a literal; at runtime `id = mix(enclosingScopeId, site)`, where the enclosing
scope is the open element, a component placement (`ui.enter(site)`), or a keyed
row (`ui.keyed(site, hashOf(key))`). So: `if` never shifts a sibling's id
(verified: `ids stable under if: true`); the same component placed three times
gets three ids; `foreach` rows are keyed; all 53 ids in the frame are unique.

`__traits(getLocation, sym)` inside a string mixin (probe1/probe3, both compilers):

| what                                                    | result                                                                                 |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `mixin("struct A1 {}")` on line 18                      | `("probe1.d-mixin-18", 18, 1)`                                                         |
| `mixin("\n\nstruct A2 {}")` on line 20                  | `("probe1.d-mixin-20", 22, 1)` — true line, _generated_ column, pseudo file name       |
| a local struct, parent query                            | `__traits(parent, S)` = the function; inside a delegate literal, `__dgliteral_L33_C14` |
| `__FUNCTION__` in a delegate literal's _parameter list_ | empty string (`mixin(__FUNCTION__)` → "expression expected, not `End of File`")        |
| `#line 100 "app.d"` inside a mixin on line L            | reports **`100 + 2·(L−1)`** (see bug below)                                            |

So a per-element anchor symbol would report `app.d-mixin-L`, the right line,
and the column of the _generated_ text — strictly less than the generator
already knows. The one place an anchor symbol _is_ load-bearing is the message
scope: each markup declares `struct __mkL_anchorN {}` and walks
`__traits(parent, …)` (skipping `__dgliteral`/`__lambda`) to the enclosing
component to read its `@emits!M`. For `fragment!q{}` (an expression, which
cannot declare a symbol) the anchor lives in a lambda inside `typeof(...)` in
the delegate's parameter list.

Caveats: ids depend on `__FILE__` as passed on the command line and on line
numbers, so they are stable across frames of one binary, not across edits;
`mixin(` and `markup!q{` must be on the same line (the line map is relative to
the `mixin` keyword's line, the `__LINE__` default to `markup`'s).

**DMD bug found** (also in LDC 1.43, shared frontend): `#line N` inside a
string mixin is off by `2·(L−1)` (L = the mixin's line). Cause:
`dmd/location.d` `BaseLoc.addSubstitution` stores
`line - lines.length + startLine - 2`; for a file `startLine == 1` this is
right, for a mixin `startLine == L` and the substituted line is then
`(i + startLine) + delta` = `N + 2L − 2`. The delta should be
`line - lines.length - startLine`. `#line` rejects negative/over-`int.max`
numbers, so compensation cannot reach lines `< 2L−1`. **Workaround used:** no
`#line` at all — the generator never emits a newline in glue, only newlines to
advance to the next spliced token's line, so line `k` of the mixin text _is_
markup line `k`, and diagnostics report the real source line (under the file
name `app.d-mixin-L`).

### 2. Subtrees as values: yes, as `scope` delegates (`@nogc`, no closure allocation)

All of these are in `app.d` (`valueDemos`, `card`, `memberList`, `indent`) and run:

```d
// outside markup, an expression:
scope status = mixin(fragment!q{ label(slot: Slot.dim, text: i"query: $(m.ids.query)"); });

mixin(markup!q{
    column(gap: 1) {
        auto quit = { keyValue(name: "quit", value: "q", onPress: ui.on(ExplorerMsg(Quit()))); };
        card(title: "Query", body: { embed(status); embed(quit); });          // a composite receiving a body
        if (m.ids.computing) { row(gap: 1) { label(text: "busy:"); embed(status); } }
        else { embed(status); }                                                // one value, two places
        mapMsg((StatsMsg sm) => ExplorerMsg(sm)) {
            memberList(rows: m.ids.rows, row: (in MemberRow r) {               // caller-supplied row builder
                keyValue(name: r.name, value: "copy", onPress: ui.on(StatsMsg(CopyName(r.name))));
            });
        }
        indent { label(text: "nested children"); }                             // trailing block → children:
    }
});

void card(F)(ref Ui ui, string title, scope F body) @safe pure nothrow @nogc
{
    mixin(markup!q{ column(gap: 0) { label(slot: Slot.heading, text: i"┌ $(title)"); embed(body); } });
}
```

A fragment is `void delegate(ref Ui, MsgTag!M[, args]) @safe pure nothrow @nogc`,
declared `scope`, so it may capture locals and `in` parameters without a GC
closure (the components stay `@nogc`). It is a _deferred builder_, not a built
tree: it runs where it is `embed`ded, so it sees that place's `env` and gets that
place's identity (two `embed(status)` → two ids). Limits, honestly: a fragment
cannot outlive the frame or be returned from a function (scope); receivers are
templates over `F` (`card(F)`); there is no "inspect/transform a built subtree"
— it is a value of _code_, not of nodes.

### 3. Message types: a compile-time error, not a runtime check

The generator sees the `mapMsg` nesting statically: each scope is a local
`alias __mkL_Mn`, the root one read from the component's `@emits!M`. It
rewrites every `ui.on(…)` to `ui.on!(Scope)(…)`, emits a `static assert` that
each `mapMsg`'s result type equals its parent's scope, and that every placed
component's `@emits` equals the scope (components without `@emits` are
_transparent_: they may not send, and fragments passed through them keep the
type of where they were written — `MsgTag!M` in the delegate's type). `frame!(ExplorerMsg, explorerView)`
checks the root. So `-c bad` no longer builds (DMD and LDC print the same):

```
app_bad.d-mixin-129(141,3): Error: static assert:  "markup: `statsPane` sends SumType!(ToggleHash, SetDebounce, CopyName), but here SumType!(SumType!(ToggleHash, SetDebounce, CopyName), Quit) is expected: wrap it in mapMsg(…)"
```

Line 141 is the `statsPane(...)` element. The runtime walk of the old sketch is
kept and prints `runtime walk agrees: true`. Holes: outside markup, `ui.on` has
no deducible `Expected` and does not compile — but hand-written
`ui.on!StatsMsg(…)` can lie; and the type names are `SumType!(…)` spelled out
(`.stringof` of an alias is its target), which is noisy.

`rejected()` asserts (each case also checked individually in `probes/neg/`,
with the error it produces): `foreach` without key; a StatsMsg handler at
ExplorerMsg scope; `statsPane` placed without `mapMsg`; a `mapMsg` lifting to
the wrong type; positional attributes; a leaf with children; a capturing payload
lambda (`&applyErased` becomes a delegate, not a function pointer); a fragment
written under ExplorerMsg embedded under StatsMsg, directly and through `card`;
bare `ui.on(…)` outside markup; a positional attribute after `Site`. A
control case asserts the correct spellings compile. (Each case is a template
instance `probe!src(…)` — a `{ … }` lambda in `__traits(compiles)` cannot
capture `in` parameters in a `@nogc` function: "cannot access variable `ids` in
frame of function", which would have made every negative pass vacuously.)

### 4. Diagnostics (DMD and LDC print identical text)

Type error inside an attribute (`probes/diag_type.d`: `value: s.hashOnEdit ~ 1` on line 11, `r.nme` on line 14):

```
probes/diag_type.d-mixin-8(11): Error: incompatible types for `(cast(int)s.hashOnEdit) ~ (1)`: both operands are of type `int`
                        value: s.hashOnEdit ~ 1, unit: "ms",
                                            ^
probes/diag_type.d-mixin-8(14): Error: no property `nme` for type `const(MemberRow)`
                         name: r.nme, value: r.value);}}}
                                ^
app.d(10):        did you mean `name`?
```

Right line; the echoed line is the _generated_ one, but because glue goes at the
end of the previous line, attributes sit in their source columns (until a
rewrite such as `ui.text(` or `!(Scope)` shifts the rest of that line).
`-mixin-8` in the file name is the only tell. Markup syntax error (missing `;`, line 10):

```
probes/diag_syntax.d-mixin-8(10): Error: static assert:  "markup: expected `{` or `;` after element `label`"
static assert(0, "markup: expected `{` or `;` after element `label`");
```

Missing key: `…-mixin-8(10): Error: static assert: "markup: a `foreach`in markup needs a key:`foreach (r; rows; key: r.name)` (rows are identified by key, not position)"`.
Wrong message in a handler — the error points into `ui_sketch.d` with an
"instantiated from here" at the right markup line:

```
ui_sketch.d(574): Error: static assert:  "markup: this handler sends SumType!(SumType!(…), Quit), but its scope expects SumType!(ToggleHash, SetDebounce, CopyName): wrap it in mapMsg(…)"
probes/diag_msg.d-mixin-8(11):        instantiated from here: `on!(SumType!(…), SumType!(…))`
                onPress: ui.on!(__mk8_M0)(ExplorerMsg(Quit())));}}
```

Generator errors stop at the first one (one `static assert(0, …)`), there is no recovery.

### 5. Compile-time cost

The app's own compile step (deps prebuilt), best of 5 (`probes/bench.sh`):

|                                                              | DMD `-o-`        | DMD `-c`         | LDC `-o-`        | LDC `-c` (debug) |
| ------------------------------------------------------------ | ---------------- | ---------------- | ---------------- | ---------------- |
| original demo                                                | 0.20 s / 141 MiB | 0.26 s / 164 MiB | 0.22 s / 209 MiB | 0.75 s / 265 MiB |
| markup demo (more content: 8 markups + 10 `rejected` probes) | 0.23 s / 148 MiB | 0.29 s / 172 MiB | 0.27 s / 217 MiB | 0.74 s / 276 MiB |

Scaling (`-o-`, N copies of the Stats-pane markup, each its own component):

| N                                             | DMD              | LDC              |
| --------------------------------------------- | ---------------- | ---------------- |
| 1                                             | 0.24 s / 149 MiB | 0.30 s / 215 MiB |
| 50                                            | 0.48 s / 215 MiB | 0.59 s / 285 MiB |
| 200                                           | 1.22 s / 418 MiB | 1.38 s / 496 MiB |
| 200, pre-expanded (the generated D pasted in) | 0.34 s / 199 MiB | 0.43 s / 268 MiB |

So **~4.5 ms and ~1.1 MiB of CTFE per Stats-pane-sized markup**, about 80% of
the cost: the CTFE interpreter, not the generated code. Fine for an app with
tens of components, noticeable at hundreds; the generator was not optimised
(string `~=`, a `Tok[]` per markup).

### 6. Tooling: what is lost

- Inside `q{}` there is no completion, go-to-definition, hover, rename or
  `dfmt`/`dmd-fmt` formatting (editors show a token string; serve-d sees a
  string literal). Highlighting survives (token strings are highlighted as code
  in most editors).
- Errors carry a `file-mixin-L` file name; IDE problem matchers that parse
  `file(line,col)` may not jump to them.
- Debuggers step through generated lines that are the source lines, but the
  file is the pseudo-file `app.d-mixin-L` (no source to show unless `-mixin=` is used).
- The DSL is a second language: its grammar, its error messages, its rewrites
  (`ui.on` is recognised _textually_: `auto u = &ui; u.on(…)` is not rewritten,
  and then fails to compile — no silent hole, but a confusing error).

## Every compiler error/limitation hit

1. `#line` in a string mixin is off by `2·(L−1)` (DMD 2.115 / LDC 1.43 frontend bug, `BaseLoc.addSubstitution`). Worked around by line-aligned emission.
2. `__FUNCTION__` is empty in a delegate literal's parameter list: `app.d-mixin-91-mixin-91(91,1): Error: expression expected, not End of File`. Worked around with an anchor struct inside a `typeof(() { … }())`.
3. `__traits(compiles, { mixin(…); })` in a `@nogc` function with `in` parameters: `function app.rejected.__lambda_L… cannot access variable ids in frame of function app.rejected` — every negative would pass vacuously. Worked around with a template `probe!src`.
4. `.stringof` of a message alias prints the full `SumType!(…)`; messages are noisy.
5. `mixin(` and `markup!q{` must share a line (otherwise every reported line is off by the difference).
6. Shadowing was not a problem: a fragment delegate's `ui` parameter may shadow the component's `ui` (nested functions may shadow); `body` is a usable parameter name.

## Pros / cons

Pros

- Reads like JSX/Flutter; the Stats pane is shorter than the inside-out version and has no workarounds (`Node.none`, `mapKeyed`, value forms, `place`, `componentForm`).
- Top-down: `env` is known at open, so context-dependent structure is plain `if`.
- Identity is a compile-time constant per element; `if` cannot shift siblings; keys are mandatory _in the grammar_.
- **The message type check is a compile-time error** at the offending line, because the generator sees `mapMsg` nesting.
- Attribute expressions are ordinary D in the caller's scope; IES works (`text: i"… $(x)"`).
- Subtrees as values exist (`scope` fragments, `@nogc`), with their message type in their type.
- Everything stays `@safe pure nothrow @nogc`; both compilers; identical output.

Cons

- A second language with its own parser to maintain; one-error-and-stop diagnostics; the CTFE cost (~4.5 ms per pane).
- No IDE support inside `q{}`; `file-mixin-L` file names; columns drift after a rewrite on a line.
- Fragments are code values, scoped to the frame, and receivers must be templates; no built-subtree values.
- The `ui.on` rewrite is textual; message names print as raw `SumType!(…)`.
- Ids depend on file path and line numbers (stable per binary, not across edits).
- Relies on a frontend bug being _avoided_ (`#line`); a fix upstream would allow true `app.d(line,col)` locations.
