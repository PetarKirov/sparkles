# `sparkles:ui` primitives: pure (box + text) vs hybrid, and custom layouts

This prototype answers two design questions over the decided lazy-variadic,
children-stack builder
([`../ui-api-demo-lazy/bench/src/lazystack.d`](../ui-api-demo-lazy/bench/src/lazystack.d)):

1. Should the builder have only two primitives, `box` and `text` (**pure**), or
   should it keep a few more primitives for widgets that are hot or
   semantically special (**hybrid**)?
2. How does a widget author give a new widget its own layout?

**The answers in brief.**

- **Go pure.** Measured on every axis, the hybrid primitives buy nothing that
  a config struct on `box` or `text` can't, and the per-node cost is the same.
  The semantics a backend or test sees come out byte-identical; `libs/ui`'s
  own `WidgetKind` is already in effect pure.
- **Make the layout protocol (a) the extension mechanism.** Add paint-only
  leaves (c) for the non-interactive ink. Build-time placement (b) and
  anchored fractions (d) stay as conveniences or are rejected.

Everything is `@safe pure nothrow @nogc`, built with compilers carrying the
`scope` lazy-variadic closure fix (branch `build/scope-lazy-variadic-toolchain`
at `a42bf923`, see the commands below). DMD and LDC give identical results.

## What was built

Files:

| file                    | what                                                                                                                                                                                                                                                                                                                              |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/uicore.d`          | The builder core, grown from `lazystack.d`; details below the table.                                                                                                                                                                                                                                                              |
| `src/widgets_common.d`  | Composites both libraries share: `column`, `row`, `label`, `formRow`, `numberField`, `keyValue`, `button`.                                                                                                                                                                                                                        |
| `src/widgets_pure.d`    | `toggle`, `textInput`, `scrollView`, `virtualList`, written as box + text composites.                                                                                                                                                                                                                                             |
| `src/widgets_hybrid.d`  | The same four signatures, over core primitives.                                                                                                                                                                                                                                                                                   |
| `src/views.inc`         | The app: the Stats pane, plus a settings page (8 toggles and 8 number fields in a scroll view, a text field, 3 buttons, and a 1000-row virtual list of `keyValue`s). It is mixed **verbatim** into `views_pure.d` and `views_hybrid.d`.                                                                                           |
| `src/layouts.d`         | The custom layouts. Mechanism (a): `ClockLayout`, `TimelineLayout`, `CalendarLayout`. (c): `ClockFace`, `CalendarGrid`, `ClockPainted`. (b): `clockBuilt` (`layoutBuilder`) and `clockLagged` (last frame's bounds). (d): `clockAnchored`. Also their views, `timelineView` and `calendarView`, and the `eventColumn` comparison. |
| `src/tests.d`           | 14 tests: pure and hybrid on the same app, and exact coordinates for every layout.                                                                                                                                                                                                                                                |
| `src/bench.d`           | `@benchmark` cases over build, layout, and build + layout.                                                                                                                                                                                                                                                                        |
| `src/demo.d`, `-c demo` | Prints node counts, trees, semantics and the clock as text (`out/demo-*.txt`).                                                                                                                                                                                                                                                    |
| `src/rawbuf.d`          | `RawBuffer` and the bump text store, from the lazy demo's `benchtext.d`. The frame tables are bare malloc'd arrays here: a layout pass indexes them heavily, and `HeapBuffer`'s outlined `ensureUniqueStorage` cost 6–8 ns per node there (the lazy demo's README, "Hot layout fields").                                          |
| `out/`, `results/`      | Captured outputs: demo, tests, stock-compiler errors, bench tables and JSON.                                                                                                                                                                                                                                                      |

What `src/uicore.d` adds to `lazystack.d`:

- **One `box`**, with Clay-style sub-config structs as named attributes:
  - `Lay`: direction (`column`, `row`, `stack`, `anchor`), gap, padding,
    `fit`/`grow`/`fixed`/`percent` sizing, and alignment.
  - `Scroll`, `Floating` (with an x attach point) and `border`.
  - A background slot, `Sem` (role, checked, value, focusable, merge), and
    `label`, `onPress` and `custom: CustomLayout`.
  - `data: LayoutData`, which is per-child parent data.
- **`text`**: the one leaf that is measured and wraps (one cell per code
  point, breaking at any of them).
- The **`image`** and **`custom`** (paint-only) escape hatches, and
  **`layoutBuilder`**.
- **A layout pass** (`layOut`), run top-down after the build:
  - It computes integer-exact `grow` shares, alignment, height-for-width
    (`heightFor`), scroll offsets, and floating and anchored children.
  - It calls custom `measure` and `arrange` functions.
- **The frame after layout**: paint to a draw list, `hitTest`, `pressTarget`
  (the press bubbles to the nearest ancestor with a message), `roleOf`,
  `labelOf`, `checkedOf`, `find(role, label)`, `focusOrder`, the `semantics`
  tree, and `dispatch` through `mapMsg`.
- **An identity-keyed `ElementStore`** (a stub): views read it through
  `peekId`/`peekState`, and the host writes it with `commitStore`.
- **The hybrid primitives**: four core kinds (`toggle`, `textInput`,
  `scrollView`, `virtualList`). Every core site that dispatches on them is
  marked `HYBRID`.

Commands, from the repository root, in the development shell of branch
`build/scope-lazy-variadic-toolchain` (its compilers carry the fix for
[dlang/dmd#22885](https://github.com/dlang/dmd/issues/22885)), or with
compilers patched the same way:

```bash
D=docs/research/ui-authoring/experiments/ui-primitives
nix develop -c bash -c "cd $D && dub test --compiler=ldc2 --skip-registry=all"          # 14 passed (out/test-ldc.txt)
nix develop -c bash -c "cd $D && dub test --compiler=dmd  --skip-registry=all"          # 14 passed (out/test-dmd.txt)
nix develop -c bash -c "cd $D && dub run -c demo --compiler=ldc2 --skip-registry=all"   # out/demo-ldc.txt
nix develop -c bash -c "cd $D && dub run -c demo --compiler=dmd  --skip-registry=all"   # out/demo-dmd.txt, byte-identical
nix develop -c bash -c "cd $D && dub test -b bench --compiler=ldc2 --skip-registry=all && ./build/ui-primitives-test-unittest --bench --perf --group-by=view,pass"
#   … and the same with --compiler=dmd (results/dmd-1.txt); results/ldc-2.txt is a repeat run
```

### Compiler errors and limitations hit

- **Stock DMD 2.115 and LDC 1.43 reject the prototype.** Measured from the
  main checkout's shell at `8a231bbe` (`out/stock-compilers.txt`): every view
  and layout with a child slot fails with "`@nogc` yet allocates closure for
  `…()` with the GC". Each compiler reports 20 distinct errors, 18 of them closure
  allocations (the file keeps the first 14 lines). The frontend fix is still load-bearing.
- **dip1000 rejected the `LayoutCtx` hand-off** ("scope variable `ctx`
  assigned to non-scope anonymous parameter"). `LayoutCtx` holds a `Ui*` to
  the `ref this`. The fix was `scope ref LayoutCtx` in `ArrangeFn` and in
  every `arrange`, plus `scope` (`heightFor`) and `return scope` (`ints`) on
  its methods.
- **A member shadows a UFCS free function of the same name.** `Ui.layout(w, h)`
  (the pass) made `ui.layout(ClockLayout(…))` resolve to the member and fail,
  so the pass is now `layOut`.
- **`package` reaches nothing between top-level modules.** `UiRange`'s
  fields and `virtualListOpen` had to become public; a real package layout
  would fix this.
- **`auto ui = r.ui` gives a `Ui*`, and UFCS `ui.box(…)` doesn't dereference
  it.** The list composites use `ref ui = *r.ui;`. The tests use
  `ref ui = *new Ui;` for the same reason.
- **A bug of mine in `keep`.** `arena.extend(n)[at - arena.length .. $]` reads
  `arena.length` after `extend` has grown it. The fix computes the padding
  first.
- **The first pure `scrollView` didn't scroll.** It put `Scroll(y)` on a row,
  and a row scrolls along x. The demo output showed it. The fix is a scrolled
  column whose thumb floats at the right edge, which needed Clay's attach
  points (`Floating.attachX`).
- **Mechanism (c) can't name text.** A painter has no text store, so
  `DrawOp.lit` carries static text; a painter's labels must be literals or
  data that outlives the frame.
- **Exact coordinates need integer trigonometry.** `sin(π/6)` is
  `0.49999999999999994` in `double`, so `round(9·sin 30°)` comes out 4. The
  clock uses an integer sin/cos table at 30° steps (×10 000). A gauge with
  arbitrary angles would need a fixed rounding rule, or tests with a
  tolerance.
- **Text measurement is a stub.** One cell per code point, wrapping at any
  code point. Height-for-width is exact for `text`, custom `measure`s and
  columns; a row reports its fit height.
- **The dev shell installs git hooks in the repository it is entered from.**
  The first command here ran from the sparkles checkout and re-ran its
  `prek` installer on `.git/hooks/pre-commit`. That is the same generator
  that checkout's own shell runs, and no tracked file changed. The later runs
  entered the shell from a scratch directory outside any repository ("`.git`
  not found; skipping installation").
- **Bench.** `benchCase` (main-checkout API) worked as the lazy bench used
  it, with each case's state on the heap plus the `keepAlive` roots. The
  table prints sub-10 µs medians as whole µs, so compare the precise
  `instr/iter` column for the small cases.

## Research summary (pinned)

Commits:

| repository | commit                                                                            |
| ---------- | --------------------------------------------------------------------------------- |
| Flutter    | `9584c6713b324636289d067944a46fd6b49df14b`, `packages/flutter/lib/src/…`          |
| androidx   | `296313a488a01c84ddcb0801d4efee640a14070c`, `compose/ui/ui/src/commonMain/…/ui/…` |
| Clay       | `e6cc36941ab2af5d81107617039d6f527a1c660b`                                        |
| sparkles   | `8a231bbeb4c91094a4d5d5a469d24b43ee609b1b`, `docs/research/ui-layout/`            |

To make a permalink, use
`https://github.com/$org/$repo/blob/$sha/$path#L$n`.

### Flutter

- **The `RenderBox` protocol.**
  - `layout(Constraints, {parentUsesSize})` calls `performLayout()`, which
    "must call [layout] on each of your children" (`rendering/object.dart:2810`,
    `:2998-3017`).
  - The relayout boundary is
    `!parentUsesSize || sizedByParent || constraints.isTight || parent == null`
    (`object.dart:2863`).
  - Intrinsics "can result in O(N²) behavior" (`box.dart:1642`).
- **`MultiChildLayoutDelegate`** (`rendering/custom_layout.dart`).
  - Its members are `getSize(BoxConstraints) => constraints.biggest`,
    `performLayout(Size)` and `shouldRelayout` (`:282-297`).
  - Inside `performLayout` it calls `layoutChild(id, constraints)` "exactly
    once" per child (`:145-161`) and `positionChild(id, offset)`.
  - Its own size "cannot depend on layout properties of the children", so it
    never implements intrinsics (`:36-40`).
  - Children are identified by `LayoutId`, which is parent data
    (`widgets/basic.dart:2612`).
- **`Flow` / `FlowDelegate`** places children with transforms at paint time,
  "skipping layout", and can even skip build (`rendering/flow.dart:165-173`).
  Hit testing replays the paint order backwards with each child's transform
  (`:428-445`).
- **`CustomPainter`** is `paint(Canvas, Size)`, `shouldRepaint`,
  `hitTest(Offset)` and `semanticsBuilder` (`rendering/custom_paint.dart:206-286`).
  It is paint-only, over a size layout already decided.
- **`LayoutBuilder`** "defers its building until layout"
  (`widgets/layout_builder.dart:48`).
  - It runs through `invokeLayoutCallback`, which "disables a number of
    assertions" (`rendering/object.dart:3025-3035`).
  - Intrinsics are refused because they "would require running the layout
    callback speculatively" (`layout_builder.dart:478-480`).
- **Hit testing** walks children from last to first, offset by
  `BoxParentData.offset` (`box.dart:3359-3376`).

### Jetpack Compose (androidx clone)

- **`MeasurePolicy`.** `MeasureScope.measure(measurables, constraints): MeasureResult`
  (`layout/MeasurePolicy.kt:88-91`), with "no measurement negotiation"
  (`:69-71`).
  - A `Measurable` "can only be measured once inside a layout pass"
    (`layout/Measurable.kt:27-30`).
  - Children are placed with `layout(w, h) { placeable.placeRelative(x, y) }`
    (`layout/MeasureScope.kt:47`, `Placeable.kt:231`).
  - Children are positional, or keyed through `Modifier.layoutId`
    (`layout/LayoutId.kt:34`).
- **`SubcomposeLayout`** composes _during measure_:
  `subcompose(slotId, content): List<Measurable>`
  (`layout/SubcomposeLayout.kt:172`).
  - Slot ids must be stable across remeasures (`:159-163`).
  - Its intrinsics are "not supported" (`:1008-1011`).
  - `BoxWithConstraints` and the lazy lists are built on it.

### SwiftUI `Layout` (closed source; repo catalog `swiftui.md`)

- `sizeThatFits(proposal:subviews:cache:)` and
  `placeSubviews(in:proposal:subviews:cache:)` (`swiftui.md:441-457`).
- A child may be probed several times, so there is no measure-once rule, and
  an explicit `Cache` is what keeps it O(n) (`:127-132`, `:498-502`).
- `LayoutValueKey` carries per-child parameters (`:696-720`).
- Before iOS 16 the only option was `GeometryReader`, which builds during
  layout (`:436`).

### Clay (`clay.h`)

- **Floating elements.** `Clay_FloatingElementConfig{offset, expand, parentId,
zIndex, attachPoints, pointerCaptureMode, attachTo, clipTo}` (`:484-513`).
  Each floating element becomes its own layout root (`:2123-2160`).
- **Custom elements.** `Clay_CustomElementConfig{void* customData}`
  (`:521-525`) has **no** measure or arrange hook. It is sized like a box and
  emits a `CUSTOM` render command (`:3040-3054`); in other words it is
  mechanism (c).
- **Layout passes.** Widths, then text wrapping, then heights, then
  positions, all inside `Clay__CalculateFinalLayout` (`:2573-2727`).
- **No available size during declaration.** Views read last frame's boxes
  with `Clay_GetElementData(id)` (`:755-759`). Hit testing is also against
  last frame's boxes (`:4084-4160`), so `Clay_Hovered()` is one frame stale.
  This is mechanism (b).

### The sparkles catalog (`docs/research/ui-layout/`)

- `index.md#by-measure--arrange-protocol` is the taxonomy.
- Catalog lessons: `jetpack-compose.md#lessons-for-sparkles` (`:839`) proposes
  a 64-bit `Constraints` POD and opt-in multi-pass layout;
  `swiftui.md#lessons-for-sparkles` (`:805`) proposes separate size and place
  phases plus a cache.
- `clay.md:106` notes that Clay uses floating elements instead of absolute
  positioning, and has no grid.
- `css-grid.md` covers the grid track model. `layout.md` `LAY9` already
  requires a 1-D track sizer.

**Synthesis.** Every framework converges on two steps:
`measure(constraints, children) → size`, then `arrange → child offsets`.
Children are addressed by position or by key, and per-child data travels as
parent data. Paint-only hatches (`CustomPainter`, Clay `CUSTOM`, `Flow`)
never touch layout. Building during layout (`LayoutBuilder`,
`SubcomposeLayout`, `GeometryReader`) costs intrinsics, assertions, and
rebuild-on-constraint churn. Clay avoids it by accepting one frame of lag.

## Question 1: pure vs hybrid

### What `libs/ui` really needs

`sparkles.ui.widget.WidgetKind` is
`box, text, rich, glyph, image, line, scrollbar` plus the containers
`row, column, stack, panel, popup`.

- **Every interactive widget there is already a composite.**
  `components/controls.d` `toggleSwitch` is a track `box` holding a knob
  `box`, carrying a `hitId`. Segmented controls, steppers, the tree, tabs and
  the command palette are composites too.
- **The only semantically special leaf is `scrollbar`.** It carries content
  units, and each pixel backend resolves it into its own bar (`WGT10`).
  `rich` and `glyph` are text variants, and `line` is paint.
- **The kind switches** live in `display_list.d` (a `final switch` per node),
  `layout.d` (row vs column, and text measurement for `text`/`rich`) and
  `interp/html_semantic.d` (the tag from the kind).
- **No backend emits roles today.** `popup.md` `MDL10` states it, and the TUI
  spec makes accessibility a non-goal. So nothing in the tree yet needs a
  `toggle` _kind_ for semantics: it needs a role field.

The hybrid set I tried is what the brief floated, and what a native-widget
backend would most plausibly want:

- `textInput`: IME, caret and selection belong to the platform.
- `scrollView`: clip, offset and the bar (`LAY7`/`LAY17`, the `scrollbar`
  leaf).
- `virtualList`: the visible-range arithmetic in the core.
- `toggle`: a hot path, with 8 per settings page.

### The toggle, authored both ways

```d
// pure (widgets_pure.d): a composite of three boxes and a text
Node toggle(ref Ui ui, NamedOnly _ = NamedOnly.init, bool on = false,
    scope const(char)[] label = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.row, gap: 1),
        sem: Sem(role: Role.switch_, checked: on ? Checked.on : Checked.off, focusable: true, merge: true),
        onPress: onPress, children:
        ui.box(layout: Lay(dir: Dir.row, w: Sizing.fixed(4), h: Sizing.fixed(ui.env.controlRows),
                alignX: on ? Align.end : Align.start),
            bg: on ? Slot.controlOn : Slot.sunken, children:
            ui.box(layout: Lay(w: Sizing.fixed(2), h: Sizing.grow), bg: Slot.knob)),
        ui.text(text: label));

// hybrid (widgets_hybrid.d): one core leaf …
Node toggle(ref Ui ui, NamedOnly _ = NamedOnly.init, bool on = false,
    scope const(char)[] label = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.toggleLeaf(on, label, onPress);
// … plus, in uicore.d: `Kind.toggle`, its fit size in `toggleLeaf`, its paint
// in `paintNode`, its role in `roleOf`, its label in `labelOf`, its checked
// state in `checkedOf`, its focusability in `focusableAt`, and its
// non-descent in `semFrom`.
```

The app code is identical: `views.inc` is mixed into both. A new widget an
app writes is the pure kind in both libraries, because the app can't add a
core kind. For example `keyValue`:

```d
Node keyValue(ref Ui ui, NamedOnly _ = NamedOnly.init, scope const(char)[] name = null,
    scope const(char)[] value = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.row, gap: 1), sem: Sem(role: Role.button, merge: true),
        onPress: onPress, children: ui.text(text: name), ui.text(text: value, slot: Slot.dim));
```

### Comparison

| aspect                                | pure                                                                                                                                                                                                                              | hybrid                                                                                                                                                                   |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **authoring a library widget**        | One expression over `box`/`text` and its config (toggle: 9 lines). Interaction state comes from `ui.peekState` (the id the outer box is about to get).                                                                            | A one-line wrapper, plus a core kind with 8–14 dispatch sites. For the four widgets: 13 `HYBRID` sites, 4 kinds, about 120 core lines (`grep HYBRID src/uicore.d`).      |
| **an app's new widget**               | Same tools as the library: first-class.                                                                                                                                                                                           | Composite only; a second class next to the core kinds.                                                                                                                   |
| **semantics**                         | Declared on the outer box: `Sem(role, checked, value, focusable, merge)`, label explicit or merged from the first text descendant.                                                                                                | Implied by the kind (`roleOf`/`labelOf`/`checkedOf` switch on it); composites still declare `Sem`.                                                                       |
| **what a backend or test sees**       | The semantics trees of the settings page are byte-identical (`primitives.settings.sameSemantics`, 35 nodes; `out/demo-*.txt`).                                                                                                    | Same.                                                                                                                                                                    |
| **hit testing and routing**           | A click lands on the deepest node (the knob box), and `pressTarget` bubbles to the nearest ancestor with a message, the outer toggle box (`findToggleAndPress`). Clips are honoured (`scrollViewScrollsAndClips`).                | The click lands on the leaf itself; no bubbling needed. Same result.                                                                                                     |
| **focus**                             | `Sem.focusable`, in tree order. Same Tab order of 20 (`focusOrder`).                                                                                                                                                              | Kind-implied for toggle/textInput, declared elsewhere. Same order.                                                                                                       |
| **theming and context**               | Sizes and slots chosen _in the view_ from `ui.env` (`controlRows`, density) and semantic `Slot`s, resolved by the palette. A theme can restyle by slot; a backend can't substitute a native control without recognising the role. | The look is the backend's (`paintNode`'s `Kind.toggle` case): a native switch is natural, but every backend must draw every kind, and a cell and a pixel target diverge. |
| **testing**                           | `ui.find(Role.switch_, "Word wrap")`, then `checkedOf`, `rectOf`, `pressTarget`, `dispatch`                                                                                                                                       | identical calls (same test body, `static foreach` over both)                                                                                                             |
| **node count**: Stats pane, 1000 rows | 3012                                                                                                                                                                                                                              | 3009 (−3: one toggle)                                                                                                                                                    |
| **node count**: settings page         | 135                                                                                                                                                                                                                               | 106 (−29: 8 toggles × 3, text input 1, scroll view 2, list spacers 2)                                                                                                    |
| **build**, LDC                        | Stats 98 µs (1.66 M instr); settings 5 µs (74.3 k)                                                                                                                                                                                | Stats 99–102 µs (1.66 M); settings 3 µs (57.9 k)                                                                                                                         |
| **layout**, LDC                       | Stats 27 µs (621 k); settings ~1 µs (33.4 k)                                                                                                                                                                                      | Stats 26–27 µs (620 k); settings 0.93 µs (25.4 k)                                                                                                                        |
| **build + layout**, LDC               | Stats 124–131 µs; settings 6 µs (103.8 k)                                                                                                                                                                                         | Stats 125–130 µs; settings 4 µs (80.0 k)                                                                                                                                 |
| **build + layout**, DMD               | Stats 291 µs; settings 13 µs (145 k)                                                                                                                                                                                              | Stats 290 µs; settings 10 µs (113 k)                                                                                                                                     |
| **per node**                          | Settings build+layout: 769 instr/node                                                                                                                                                                                             | 755 instr/node                                                                                                                                                           |

The bench runs were `-b bench`, `--perf`, patched compilers, on a 32-core
host at load average 3–5, two LDC runs and one DMD run (`results/*.txt`).
The per-node cost is the same. Pure spends 27 % more nodes on a widget-heavy
page, which is +24 k instructions, or **≈ 2 µs per frame** on LDC. On the
data-heavy Stats pane (3012 nodes) the difference is in the noise.

**Recommendation: pure.**

1. The perf case for hybrid is 2 µs on a 20-control page, and none on data.
2. The semantics a backend or test sees are identical, and an app's widget
   is first-class only in pure.
3. Each hybrid kind costs a dozen core dispatch sites, which is exactly the
   "adding a kind silently skips a backend" risk `WGT3` names.
4. What the hybrid kinds _really_ carry is data, not behaviour, and it fits
   on the two primitives as config:
   - the caret belongs on `text` (`caret:`, as `Widget.caretColumn` already
     is);
   - clip and offset belong on `box` (`Scroll`);
   - the role and checked state belong in `Sem`.

**The caveat for `textInput`.** A native or IME-backed text field is a
_platform_ object. Keep it a pure composite, and let the backend recognise
`Role.textField` plus the caret config to attach an IME, rather than making
it a kind. If one primitive must be kept, it is the scrollbar-like semantic
leaf `libs/ui` already has, expressible as `custom` + `Sem`.

## Question 2: custom layouts

### The constraints, and what the core provides

- Views are pure and `@nogc`, and no closure survives the frame. A layout is
  therefore a **POD struct with `static` functions**, erased by
  `ui.layout(L(…))` into `MeasureFn`/`ArrangeFn` function pointers. Its
  fields are the params, copied into the frame arena exactly like a
  `MsgRef`'s payload. This is SwiftUI's shape: the layout is a value.
- A child carries **`LayoutData`** (4 ints of parent data, the analogue of
  `LayoutId`/`LayoutValueKey`).
- `arrange(in L, Size inner, scope Child[] kids, scope ref LayoutCtx ctx)`
  receives each child's measured fit size and data. It writes back
  `x, y, w, h`, relative to the content box. `measure(in L, Constraints,
kids)` is optional (design by introspection; without it the box fills what
  it is given, Flutter's `getSize`).
- `LayoutCtx` offers `heightFor(i, w)` (height-for-width, `LAY4`) and one
  scratch `int[]` per call.
- `measure` runs at close, and only if an axis is `fit`. It runs again
  top-down with `Constraints(maxW)` from `heightFor` when the parent's width
  is known.

Children are measured once, at close, like Compose: there is no
negotiation. Their own subtrees are laid out with the size `arrange` gave
them.

### The clock in every mechanism

```d
// (a) layout protocol + (c) a paint layer — RECOMMENDED
struct ClockLayout
{
    int inset = 1;

    static void arrange(in ClockLayout p, Size inner, scope Child[] kids, scope ref LayoutCtx ctx)
        @safe pure nothrow @nogc
    {
        int k;
        foreach (ref c; kids)
        {
            if (c.isFill)
            {
                c.x = 0;
                c.y = 0;
                c.w = inner.w;
                c.h = inner.h;
                continue;
            }
            const pt = hourPoint(k++ % 12, inner.w, inner.h, p.inset);
            c.x = pt[0] - c.w / 2;
            c.y = pt[1] - c.h / 2;
        }
    }
}

Node clockFace(ref Ui ui, NamedOnly _ = NamedOnly.init, int hour = 0, int minute = 0,
    Sizing w = Sizing.fixed(21), Sizing h = Sizing.fixed(21)) @safe pure nothrow @nogc
    => ui.box(layout: Lay(w: w, h: h), custom: ui.layout(ClockLayout(inset: 1)),
        sem: Sem(role: Role.clock), label: "clock", children:
        ui.custom(paint: ui.painter(ClockFace(hour, minute)), data: fill),
        hourLabels[].toUi(ui).mapByIndex!(l => ui.text(text: l)));

// (c) alone: the whole face painted; labels are draw commands, not nodes
struct ClockPainted
{
    int inset = 1;
    static void paint(in ClockPainted p, Rect r, ref DrawList list) @safe pure nothrow @nogc
    {
        foreach (k; 0 .. 12)
        {
            const pt = hourPoint(k, r.w, r.h, p.inset);
            const w = cast(int) cells(hourLabels[k]);
            list.ops ~= DrawOp(OpKind.text, Slot.body, r.x + pt[0] - w / 2, r.y + pt[1], w, 1, lit: hourLabels[k]);
        }
    }
}

// (b) build-time placement: floating labels at positions the view computes
private Node clockLabels(ref Ui ui, int w, int h, int inset) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.stack, w: Sizing.grow, h: Sizing.grow), children:
        hourIndex[].toUi(ui).mapByIndex!(k => ui.text(text: hourLabels[k],
            floating: Floating(active: true,
                x: cast(short) (hourPoint(k, w, h, inset)[0] - cast(int) cells(hourLabels[k]) / 2),
                y: cast(short) hourPoint(k, w, h, inset)[1]))));
//   (b')  size known by building during layout
private Node clockBuild(ref Ui ui, in ClockParams p, Size avail) @safe pure nothrow @nogc
    => clockLabels(ui, avail.w, avail.h, p.inset);
Node clockBuilt(ref Ui ui) @safe pure nothrow @nogc
    => ui.layoutBuilder!clockBuild(params: ClockParams(1),
        layout: Lay(w: Sizing.fixed(21), h: Sizing.fixed(21)), sem: Sem(role: Role.clock));
//   (b)   size from last frame, Clay-style
Node clockLagged(ref Ui ui, NamedOnly _ = NamedOnly.init, Sizing w = Sizing.fixed(21),
    Sizing h = Sizing.fixed(21)) @safe pure nothrow @nogc
    => clockLaggedAt(ui, ui.peekState, w, h);   // box(...){ clockLabels(ui, s.lastW, s.lastH, 1) }

// (d) anchored placement: a built-in `Dir.anchor`; the view maps data to fractions
Node clockAnchored(ref Ui ui) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.anchor, w: Sizing.fixed(21), h: Sizing.fixed(21)),
        sem: Sem(role: Role.clock), label: "clock", children:
        hourIndex[].toUi(ui).mapByIndex!(k => ui.text(text: hourLabels[k],
            data: anchorAt(5000 + divRound(sin30[k] * anchorRadius, 10_000),
                5000 - divRound(cos30[k] * anchorRadius, 10_000)))));
```

**The expected positions, worked by hand** for a 21×21 face (centre 10,10,
radius `min(w, h)/2 − 1 = 9`, sin/cos ×10 000, halves rounded away from
zero, label top-left = centre − width/2):

| label | 12  | 1    | 2    | 3     | 4     | 5     | 6     | 7    | 8    | 9    | 10  | 11  |
| ----- | --- | ---- | ---- | ----- | ----- | ----- | ----- | ---- | ---- | ---- | --- | --- |
| x, y  | 9,1 | 15,2 | 18,5 | 19,10 | 18,15 | 15,18 | 10,19 | 5,18 | 2,15 | 1,10 | 1,5 | 4,2 |

(a), (c), (b′) and (b) on its second frame all assert this table
(`layouts.clock.*`). The (c) paint layer's hands at 3:00 go from 10,10 to
14,10 and to 10,2. The (d) clock gives 12 at (10,0), 3 at (19,10), 6 at
(10,19) and 9 at (0,10): fractions of the box round differently, and a
"radius = min(w, h)/2 − inset" isn't expressible as a fraction (a non-square
box makes an ellipse).

```
|         12          |
|    11         1     |
| 10               2  |
| 9                 3 |   (rows 0–20 of out/demo-ldc.txt, blank rows elided)
|  8               4  |
|     7         5     |
|          6          |
```

### The timeline and the calendar, end to end in (a)

- **`TimelineLayout{t0, t1, laneHeight, laneGap}`.** Each child's data is
  `a = start`, `b = end`, sorted by start. Its x is `(start − t0)·W/(t1 −
t0)`.
  - An event **occupies `max(time span, measured width)`**, and goes in the
    first lane whose end is ≤ x.
  - `measure` returns `lanes × laneHeight`, so the timeline's height is
    measured.
  - In the test, the 10-cell "long label" at t=12 pushes event `d` (t=16)
    into lane 2. A data-only lane assignment would put `d` in lane 0, over
    the label.
  - The test asserts every rect, and that a press on the label's tail
    (20,0) reaches `OpenEvent(12)` (`layouts.timeline.lanes`).
- **`CalendarLayout{days, dayStart, dayEnd, rowsPerHour}`.** Each child's
  data is `(day, start, end)`, sorted by (day, start).
  - Events split into clusters of transitively overlapping ones; each event
    takes the first free column, and the day's width is split exactly
    between the cluster's columns.
  - A `fill` child (`CalendarGrid`, mechanism c) paints the hour lines.
  - The test: Standup 9–10 → (0,3,5,2); Review 9:30–11 → (5,4,5,3); Pairing
    10:30–11:30 → (0,6,5,2), back in column 0; Lunch → (0,9,10,2); Tuesday's
    Planning → (10,3,10,2).
  - The event titles wrap in their columns: "Standup" becomes 5×2.
  - The week's height is measured at 24 rows.
  - Events keep their ids when an earlier one is removed
    (`layouts.calendar.overlapColumns`, `keyedIdentity`).

### The cost: (a) next to a built-in column of the same events

LDC, `-b bench`; DMD in brackets:

| case                              | nodes  | build                        | layout                      | build + layout      |
| --------------------------------- | ------ | ---------------------------- | --------------------------- | ------------------- |
| timeline, 10⁴ events, (a)         | 20 001 | 736–756 µs, 12.33 M (1.6 ms) | 309–313 µs, 6.12 M (619 µs) | 1.0–1.1 ms (2.2 ms) |
| the same events in a column       | 20 001 | 694–708 µs, 11.52 M (1.5 ms) | 214–220 µs, 4.54 M (418 µs) | 918–933 µs (1.9 ms) |
| calendar, 200 events, 7 days, (a) | 411    | 15–16 µs, 242 k (31 µs)      | ~6 µs, 121 k (12 µs)        | 21–22 µs (43 µs)    |
| the same events in a column       | 401    | 14 µs, 234 k (31 µs)         | ~4 µs, 94.5 k (9 µs)        | 17–19 µs (40 µs)    |

The (a) timeline's layout costs +158 instructions per event (+79 per node) over the column.
It runs the lane stacking twice per frame, once in `measure` (via
`heightFor`, because its height is `fit`) and once in `arrange`. A third run,
at close, accounts for the +0.8 M in its build. Each run is a linear scan
over the open lanes (an estimated ~18 here; not instrumented).

A measure cache keyed on `(node, maxW)` (`LAY13`), or SwiftUI-style layout
state carried from `measure` to `arrange`, would remove two of the three
runs. Even without one, a 10⁴-event timeline lays out in 0.3 ms.

### The mechanisms compared

**(a) Layout protocol.**

- **Authoring:** a POD struct with `arrange` (and `measure`); its children
  are ordinary children.
- **Hit testing:** children have real rects; the same `hitTest` and
  `pressTarget` work (timeline test).
- **Identity:** children have the parent id plus their position or key,
  unchanged (`keyedIdentity`).
- **Semantics:** each child declares its own `Sem`; the layout box has a
  role.
- **Incremental cost:**
  - `memo` on the box works unchanged, because the params are POD and
    hashable.
  - Virtualisation is the view's job: build only the events in [t0, t1). But
    lanes then depend on which events are visible, so stable lanes need lane
    assignment in the model.
  - Children are measured once; `arrange` is O(n).
- **What the core must provide:**
  - an `ext` slot per box holding two function pointers and an arena offset;
  - per-child `LayoutData`;
  - the `Child` scratch array, `LayoutCtx` (`heightFor`, scratch), and a
    measure-at-close hook;
  - about 70 core lines.
- **Pure vs hybrid:** not a primitive in either; it is `box` config.

**(b) Build-time placement with floating children.** Positions are computed
in the view and the children float. In both variants each child is a normal
node, so hit testing and semantics work, but the view must measure the
labels itself (`cells`), so this only works where the view can measure.

- **(b′) `layoutBuilder`**, building during layout:
  - Frame-correct.
  - **It breaks the single top-down build**: nodes are appended after the
    main build, so pre-order no longer equals node order. `buildDeferred`
    re-opens the stack mid-layout; `memo` and a node-order layout sweep
    (`place`) can't see the subtree, and the env and message scope must be
    restored by hand.
  - Intrinsics are impossible, as in Flutter.
- **(b) last frame's size**, Clay-style:
  - Wrong on frame one (the test asserts it), and one frame late on every
    resize.
  - Needs the store write-back.
- **What the core must provide:** `Floating`, the element store's last-frame
  size, and `buildDeferred` with a re-entrant open stack.
- **Pure vs hybrid:** fine in pure (floating is `box` config).

**(c) Paint-only.**

- **Authoring:** a POD painter struct with `paint(in P, Rect, ref DrawList)`.
- **Hit testing:** one target for the whole leaf; it would need a `hit` fn
  returning a part.
- **Identity:** the leaf only.
- **Semantics:** the leaf's own; its parts are invisible to a11y and to
  tests (`paintOnly`: 1 node, 12 ops).
- **Incremental cost:** cheapest, because it needs no nodes.
- **What the core must provide:** a `Painter` (function pointer + params),
  `custom` leaves, and static text in draw ops.
- **Pure vs hybrid:** it is the `custom` escape hatch itself.

**(d) Anchored fractions (`Dir.anchor`).**

- **Authoring:** the view maps data to fractions; no user code runs in
  layout.
- **Hit testing, identity and semantics:** real nodes, as for (a).
- **Incremental cost:** cheap: one affine step per child.
- **What the core must provide:** one `Dir` and 6 core lines.
- **Pure vs hybrid:** `box` config.

(d) can't stack lanes by measured width, can't split columns by overlap
after measuring, and can't use a min(w, h) radius. It is fine for chart
axes, ticks and gauges.

**Recommendation: (a) as the extension mechanism, with (c) for ink, and (d)
as an optional convenience.**

- **(a)** is the only mechanism that places children from their _measured_
  sizes, which is what lane stacking and wrapping titles need. It keeps
  children real nodes, so hit testing, semantics, identity and `memo` come
  for free. It respects the single top-down build and the no-closures rule,
  because a layout is just function pointers over POD.
- **(c)** paints the non-interactive ink (axes, gridlines, the gauge arc,
  the clock hands) behind real text nodes, as a `fill` child.
- **(d)** is optional: a convenience for charts and gauges.
- **Reject (b′) `layoutBuilder`** for the core, because it breaks
  build-then-layout.
- **Keep (b) last-frame bounds** only for what must decide _what to build_
  from a size, like virtual lists. Even there, the virtual list here needs
  only the viewport height and offset from the store, and never per-child
  layout.

The other examples:

- **Gauge:** a (c) arc and needle painter, with label nodes in an (a) radial
  layout like the clock's.
- **Chart:** a (c) axis and bar painter; an (a) layout places tick labels at
  `f(value)` and drops ones that collide using their measured widths.
- **Flow/wrap:** an (a) layout over the fit widths, with `measure` returning
  the wrapped height via `Constraints.maxW`.
- **Grid:** belongs as a built-in, `LAY9`'s 1-D track sizer applied per
  axis. The protocol could host it, but a grid is common enough to be core.

## Open questions

1. **The measure cache / layout state.** Should `measure` be able to hand
   `arrange` its result (SwiftUI's `Cache`), or should the core cache
   `(node, maxW) → size` (`LAY13`)? Either removes the timeline's duplicate
   lane passes.
2. **`arrange` can't relayout a child at a different width** except through
   `heightFor`. Should it get `ctx.measureChild(i, Constraints)` returning
   both axes, Flutter's `layoutChild` (once per child)? `heightFor` is the
   minimum.
3. **Sorted-input contracts.** The timeline and calendar `assert`-require
   sorted children. Should the core offer a sorted-index scratch, or must
   models keep data sorted?
4. **Fixed lane and column caps.** `maxLanes = 64` and `maxColumns = 32` live
   on the stack. A frame-arena scratch with growth is better, but the
   one-`ints`-per-call rule exists because `RawBuffer` growth would
   invalidate earlier slices.
5. **The text field's accessible name.** The text field's caption is a
   sibling `formRow` text. A "labelled-by" relation, or a `formRow` that
   merges into its control, is needed for either library.
6. **`merge` takes the _first_ text descendant.** `keyValue` exposes only
   its name. Should merge concatenate (Flutter's `MergeSemantics` does)?
7. **Should hit testing use this frame's layout or last frame's?** Here it is
   this frame's, after layout, which is correct but means input is handled
   after layout. Clay's last-frame model is simpler for a host loop.
8. **`Floating` has an x attach point only**, and no z-sorting beyond
   "floating after flow". A popup needs Clay's full attach points, z-index
   and clip-to.
9. **Native widgets in pure.** How does a backend substitute a native switch
   or text field for a composite? By role plus config (`Role.textField` +
   `caret`), with the composite's children ignored. That needs a "replaced by
   backend" contract per role.
