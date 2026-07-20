# `sparkles:base` prettyPrint — Delivery Plan

_Audience: contributors implementing the extension model. This document is
execution-only — milestones, verification, and risks. For the desired-state
specification read [SPEC.md](./SPEC.md); for the extension idiom read the
[Design by Introspection guidelines](../../../guidelines/design-by-introspection-01-guidelines.md)._

The work generalizes `prettyPrint`'s latent `Hook` policy (today only a
stateless source-URI writer) into a full DbI shell-with-hooks, adds built-in
rendering for the standard tagged-union types, and lands Nix value rendering as
the first non-trivial consumer. Each milestone ends green: it compiles,
`dub test :base` (and from M4, `dub test :nix` in the devshell) passes, and
the **byte-identical-when-no-hook** contract (SPEC §6.4) holds — guarded by a
regression test added in M1.

## 1. Milestone overview

| #      | Deliverable                                                                                             | Depends on |
| ------ | ------------------------------------------------------------------------------------------------------- | ---------- |
| **M0** | The SPEC + this PLAN — reviewed before any code                                                         | —          |
| **M1** | `PrettyPrinter` object + render hook + `prettyPrintTo` + `printNested`, config detemplate, inline guard | M0         |
| **M2** | Composition (`CombineRenderHooks`) + advanced field-override + event hooks                              | M1         |
| **M3** | Built-in `SumType`/`Algebraic`/`Variant`/`union` + `SumTypeStyle`                                       | M0 (indep) |
| **M4** | `sparkles:nix` `NixRenderHook` (lazy, error-tolerant) + path OSC8 links                                 | M1         |
| **M5** | Version-gated Nix source-location links + `nix-eval` demo rewire                                        | M4         |

M1 is the load-bearing milestone (the dispatch change + compatibility
contract). M3 is independent of the hooks and may land in any order. M4–M5
consume M1 from `sparkles:nix`.

**Executable-spec discipline.** The SPEC follows the
[`sparkles.base.text` standard](../text/index.md): each section earns a runnable
`#!/usr/bin/env dub` + `[Output]` snippet that executes the real library, verified
by `verify-md-examples`. Because the API is unbuilt at M0, the SPEC's code blocks
start **illustrative**; **as each milestone lands the code, convert its sections'
snippets to executable, CI-verified examples** — M1 → §1 (overview) + §4 (built-in
rendering) + the render-hook / `prettyPrintTo` examples; M3 → §5 (sum/union/variant);
M4 → §8.3 (Nix). A milestone is not done until its sections' examples run green.

## 2. Per-milestone detail

### M0 — Spec

Author `SPEC.md` (done) + this `PLAN.md`, matching the house style of
`docs/specs/{versions,nix}/`. **Reviewed before implementation.** Lives under the
existing `docs/specs/base/` area (alongside `base/text/`); no code yet.

### M1 — The PrettyPrinter object + core hooks (the heart)

In `libs/base/src/sparkles/base/prettyprint.d`:

1. **Reify the shell.** Turn the free-function renderer into a
   `struct PrettyPrinter(Writer, Hook = NullHook)` owning the wrapped writer,
   `PrettyPrintOptions opt`, and a **mutable `Hook hook` field**; make it an output
   range (`put`); move the current dispatch body into a non-`const`
   `printImpl(T)(in T, ushort depth)`; add `print` / `printNested` methods. The
   existing front-door free functions become thin wrappers that construct a
   `PrettyPrinter` and call `.print` — **keeping the baseline names and order**:
   `writePretty(ref Writer w, in T value, [auto ref Hook hook,] opt)` (writer-first,
   the `write*` family) returns the writer, and `prettyPrint(in T value, opt)`
   returns a string. This preserves the hookless call sites (e.g. the `check`
   helper's `writePretty(buf, value, opts)`) verbatim.
2. **Capability traits.** Add public `template hasRenderHook(Hook, T, Printer)`
   (staged: no `canRender` → `!canRender!T` → probe `render`) and
   `hasPrettyPrintTo(T, Printer)`, mirroring `hasWriteSourceUri`.
3. **Dispatch.** Wrap the existing dispatch body in a trailing `else`; prepend
   (after the depth guard) the render hook (`hasRenderHook` →
   `hook.render(value, this, depth)`) then the `prettyPrintTo` primitive
   (`hasPrettyPrintTo` → `value.prettyPrintTo(this, depth)`).
4. **Detemplate the config.** Remove `PrettyPrintOptions`' `SourceUriHook` param;
   move the URI-scheme capability onto the printer's `Hook` (`writeTypeName` reads
   `Hook.writeSourceUri`). Migrate the ~25 `PrettyPrintOptions!void(...)` /
   `PrettyPrintOptions!(SchemeHook!"…")(...)` call sites — across `libs/base`'s
   tests + `examples/prettyprint.d`, the OSC tests, and downstream consumers like
   `libs/core-cli`'s `box.d`: `!void` → drop the arg; a scheme hook → pass it as
   the printer/free-fn `hook`. **Output unchanged** (the byte-identical contract is
   about output, not source).
5. **Inline guard.** Gate the single-line attempts in
   `printAA`/`printRange`/`printAggregate` with `static if (!anyChildRenderedByHook!(Hook, T))`
   (the inline collapser measures with a hookless sub-printer; skip it when a child
   type is hook-rendered). Inert for `NullHook`.
6. **Stateful hooks need no tricks.** The mutable-printer model means a hook stores
   its session as a plain field and `render` (non-`const`) mutates it directly
   (SPEC §6.5) — exercised by a test hook holding external state.

Tests (`@("prettyPrint.*")`, `version(unittest)` stand-in types):
`prettyPrintTo.money`/`.color` (pure), `renderHook.stateful.tagged`,
`renderHook.override.string.redaction` (pure), `embedding.hookFieldsInStruct`,
`compile.detection` (positive/negative/signature-mismatch `static assert`s),
`hook.coexist.sourceUriAndRender`, and the mandatory **`hook.void.baseline`**
(pure, `NullHook`) proving byte-identical legacy output. The pure ones carry
`@safe pure nothrow @nogc`; impure-hook ones are plain `unittest`.

### M2 — Composition + advanced hooks

1. `CombineRenderHooks!(Hooks...)` — store each sub-hook; `canRender!T` = OR;
   `render` = first matching sub-hook (first-wins); forward `writeSourceUri`
   from the first provider. Test `combine.firstWins`.
2. **Field-override hook.** In `printAggregate`, per field, probe
   `hasRenderField!(Hook, T, member)` → `hook.renderField!(T, member)(field, this, …)`.
   Test `field.redact`.
3. **Event hooks.** In `printAggregate` and the pointer branch, probe `hasOnEnter`
   → `if (hook.onEnter(value, this, depth)) return; scope(exit) hook.onLeave(value);`.
   Test `event.cycle`. Mark both advanced/unstable in DDoc.

### M3 — Built-in sum/union/variant (independent)

Insert branches before the struct/class branch:

1. Import-free detection: `isSumType` (scoped `import std.sumtype`), `isVariant`
   (`__traits(hasMember,T,"AllowedTypes")` + `.type`/`.hasValue` probes),
   `is(T == union)`.
2. `enum SumTypeStyle { activeType, declaredType, valueOnly }` + the
   `PrettyPrintOptions.sumTypeStyle` field (default `activeType`).
3. Renderers: SumType via `match`; bounded `Algebraic` via `peek` over
   `AllowedTypes` (uninitialized → `<empty>`); unbounded `Variant` best-effort;
   raw `union` → names+declared-types only, **no member read**.
4. Attribute discipline: SumType/union tests carry the full
   `@safe pure nothrow @nogc` UDA (prove no regression); Variant tests are plain
   `unittest` (TypeInfo/`peek` are impure/`@system`).

Tests `@("prettyPrint.{sumtype,variant,union}.*")` incl. **union-with-pointer**
(passing under `@safe` is the proof it never dereferences).

### M4 — Nix consumer (`sparkles:nix`)

New `libs/nix/src/sparkles/nix/pretty.d`, re-exported from `package.d`
(**`git add` before any flake build**):

1. `NixRenderHook` holding `EvalState` as a **plain mutable field** (no address
   trick — SPEC §6.5); `canRender!T = is(immutable T == immutable Value)`;
   non-`const` `render(T, P)(in T, ref P p, ushort)` = the lazy, error-tolerant,
   Nix-surface-syntax walk (SPEC §8.3), recursing via `p.printNested`. Helpers:
   `isNixIdentifier`, a Nix string escaper.
2. Always-on path/store-path → `file://` OSC8 links (behind `useOscLinks`).
3. Convenience `prettyPrintNixValue` / `toPrettyString` building a
   `PrettyPrinter!(Writer, NixRenderHook)` and calling `print`.

Tests `@("nix.pretty.*")` (`@system`, `dummy://` store, in the devshell):
scalars + escaping, empty/nested collections, inline↔multiline, `maxItems`
truncation, `maxDepth` placeholder (assert no over-depth forcing),
**error-sibling** (`{ ok=1; bad=throw "boom"; }`), attr-name quoting, colors
on/off, an OSC8 path link, `isNixIdentifier` (pure), and **`nix.pretty.embedding`**
(a `Value` field inside a plain D struct renders via the hook through the
built-in aggregate path).

### M5 — Source locations + demo

1. **Version-gated wrappers** in `eval.d` under `version(NixSourceLocations)`:
   `struct SourcePos { string file; uint line; uint column; }` and
   `positionOf`/`attrPosByName`/`attrPosByIdx` calling `nix_value_get_pos` /
   `nix_get_attr_pos_byname` / `nix_get_attr_pos_byidx` and reading the returned
   `{file,line,column}` attrset (or `null`). `sourceLocationOf` gets two
   `version`-gated bodies (real vs always-`null`); the renderer calls it
   unconditionally and, when non-null, links text via a runtime
   `file://path#Lline` URI.
2. **dub.** Add an opt-in `configuration "library-source-locations"`
   (`versions "NixSourceLocations"`) to `libs/nix/dub.sdl`, mirrored in
   `apps/nix-eval/dub.sdl`. Source-location unittests are
   `version(NixSourceLocations)`-gated.
3. **Demo.** Rewire `apps/nix-eval/src/app.d`: delete the local `renderValue`,
   call `prettyPrintNixValue` in `runExpr`/`runFlake`; add `--no-color`,
   `--depth N`, `--links`; default `useColors` to `isatty(STDOUT_FILENO)`;
   update `usage()`.

## 3. Verification checklist

- [ ] `dub test :base` green, including `prettyPrint.hook.void.baseline`
      (byte-identical legacy output) and the existing 23 tests unchanged.
- [ ] `static assert` detection tests cover positive / negative /
      signature-mismatch for each capability trait.
- [ ] `union`-with-pointer test passes under `@safe` (proves no member deref).
- [ ] `dub test :nix -- -i "nix.pretty"` green in `nix develop`; error-sibling
      and `maxDepth`-no-force tests pass.
- [ ] `dub build :nix-eval` builds; demo renders int/list/attrs nix-repl-style,
      `«error»` on a throwing attr, colors auto-off when piped.
- [ ] `version(NixSourceLocations)` build compiles against a patched Nix and its
      gated tests pass; stock-Nix builds skip them.
- [ ] Each landed milestone's SPEC sections carry runnable `[Output]` examples
      that pass `nix run .#ci -- --verify` (the executable-spec standard).
- [ ] New files `git add`-ed before any `nix develop`/flake build.
- [ ] Atomic commits per AGENTS.md: `docs(base)` spec, then `feat(base)`
      per milestone, then `feat(nix)`/`feat(nix-eval)`.

## 4. Workflow orchestration

M1's printer-object refactor + dispatch change is sequential — do it inline,
tests first (it gates everything). M2's combinator and the two advanced hooks are
independent and can be fanned out (one agent each) with a shared
compatibility-regression gate. M3 is fully independent and parallelizable with
M1/M2. M4's renderer is one cohesive unit; its many test cases can be authored in
parallel once the hook compiles. Review each milestone's tests before stacking the
next.

## 5. Risks & open decisions

- **Backward-compatibility regression** — the main risk, now two-fold: the
  free-function → `PrettyPrinter`-object refactor, and the `PrettyPrintOptions`
  detemplate (migrating ~25 `!void`/`!(SchemeHook…)` call sites). Mitigated by the
  `hook.void.baseline` test and keeping the dispatch chain verbatim inside the
  trailing `else`. Run the full `:base` suite after M1; the contract is
  identical **output**, not identical source.
- **`-allinst` + impure `render`** — an unstaged `hasRenderHook` would
  semantically analyze `render` for every type. Mitigated by staging the trait
  (check `canRender!T` before probing `render`).
- **Inline-layout hook erasure** — the single-line collapser measures with a
  hookless (`NullHook`) sub-printer. Mitigated by the `anyChildRenderedByHook`
  guard (skip inline when a child type is hook-rendered). Verify no width-related
  diffs under `NullHook`.
- **`SumTypeStyle` default** — set to `activeType`; configurable. Revisit if the
  `int(42)` tag on scalar alternatives proves noisy in practice.
- **Nix source-location API not yet upstream** — `version(NixSourceLocations)`
  stays off until the flake `nix` input points at the patched fork; the code is
  dormant and unbuilt on stock Nix. Record the symbol set in
  [[nix-c-api-binding-facts]] once landed.
- **Editor-scheme runtime links** — runtime positions link via `file://` only;
  reusing the `source_uri.d` scheme table for runtime positions is deferred.
