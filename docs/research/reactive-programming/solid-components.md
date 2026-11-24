# Solid 2.0 components and rendering (TypeScript)

The authoring layer above Solid 2.0's signals: components that run once, a compiler that lowers JSX to template clones plus one reactive binding per dynamic hole, control flow written as ordinary components that own their child scopes, and a twelve-operation host contract (`@solidjs/universal`, two of them optional) that lets the same output drive a non-DOM tree.

| Field             | Value                                                                                                                                                                                                                                                                                    |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript; JSX or TSRX source compiled by [`@solidjs/babel-plugin`][babel-readme] or the Rust/Oxc [`@solidjs/compiler`][compiler-readme]; compiler-free authoring through [`@solidjs/h`][h-readme] and [`@solidjs/html`][html-readme]                                                   |
| License           | MIT ([`LICENSE`][license])                                                                                                                                                                                                                                                               |
| Repository        | [solidjs/solid][repo]: [`packages/solid`][pkg-solid], [`packages/web`][pkg-web], [`packages/universal`][pkg-universal], [`packages/babel-plugin`][pkg-babel], [`packages/compiler`][pkg-compiler], [`packages/h`][pkg-h], [`packages/html`][pkg-html], [`packages/element`][pkg-element] |
| Documentation     | [Components and JSX][docs-cj] (solid-docs `v2-rebuild`) · RFCs [03 control flow][rfc03], [07 DOM][rfc07], [09 TypeScript/JSX][rfc09] · [`MIGRATION.md`][migration] · [TSRX frontend notes][tsrx-notes]                                                                                   |
| Category          | compiled fine-grained rendering: no virtual DOM, no re-render; reactivity is attached per expression                                                                                                                                                                                     |
| Versions surveyed | `solid-js@2.0.3`, `@solidjs/web@2.0.3`, `@solidjs/universal@2.0.3`, `@solidjs/babel-plugin@2.0.2`, `@solidjs/compiler@2.0.2`, `@solidjs/h@2.0.2`, `@solidjs/html@2.0.1` (commit `68406c2`, 2026-11-19); solid-docs at `c32486f`; `solid-js@1.9.15` for 1.x                               |
| Core abstraction  | a component is a plain function called once under `untrack`; what it returns is a value (a node, an array, or an accessor) that `insert` binds to a parent through a render effect                                                                                                       |

> [!NOTE]
> This page is the companion of [Solid 2.0 signals][signals-page], which covers the graph underneath: ownership, memos, effects, async, batching. It does not repeat them; where a rendering mechanism rests on a signals rule, it links to the section that states the rule. Everything here was read from source at the pinned commit; behaviour named only in docs is marked as such.

---

## Overview

### What it solves

A UI framework built on fine-grained signals still has to answer four questions the graph does not: what a "component" is when nothing re-runs it, which parts of a template are reactive, how a list or a branch creates and destroys the subtrees under it, and how the result reaches a concrete node tree. Solid's answer is that the component disappears at runtime and the compiler does the bookkeeping. The 2.0 docs open the components page with the rule everything else follows from ([`components-and-jsx.mdx`][docs-cj-intro]):

> _"A Solid component is a function that runs once. It sets up state, returns JSX, and is not called again for the life of the component."_

and on what JSX becomes ([`components-and-jsx.mdx`][docs-cj-exec]):

> _"Solid compiles JSX into renderer operations. […] There is no virtual DOM value that Solid repeatedly rebuilds and compares."_

### Design philosophy

1. **The reactivity boundary is the expression, not the component.** _"Each JSX expression the component returns is its own tracking scope with its own dependencies"_ ([`components-and-jsx.mdx`][docs-cj-exec]). A change re-runs one binding; the function that created it never runs again. This is the inverse of [Jetpack Compose][compose], where the recomposition scope is a composable function.
2. **Let the compiler decide what is static.** _"A heuristic wraps expressions that contain function calls or property access; simple literals and variables stay unwrapped"_ ([babel-plugin `README.md`][babel-readme-heuristic]). Static markup goes into a cloned template; only holes get runtime work.
3. **Control flow is library code.** `For`, `Show`, `Switch`, `Loading` and `Errored` are components in [`flow.ts`][flow] built from memos and `mapArray`; the runtime has no special node kind for them.
4. **The renderer is swappable.** `solid-js` owns the component model; `@solidjs/web`, `@solidjs/h` and custom renderers own their JSX types ([RFC 09][rfc09-summary]), and `@solidjs/universal` exposes the host operations so that _"Solid [can] render to different platforms like native mobile and desktop, canvas or WebGL, or even the terminal"_ ([universal `README.md`][u-readme-intro]).

---

## The component model

### A component is a call, not a node

The compiler emits `createComponent(Comp, props)` for every capitalized tag ([`isComponent`][babel-iscomponent]: an uppercase first letter, a dotted name, or a non-letter first character). In production that call is one line ([`component.ts`][component-create]):

<!-- prettier-ignore -->
```ts
// packages/solid/src/client/component.ts — createComponent (production path)
return untrack(() => Comp(props || ({} as T)));
```

There is no component instance, no owner, no lifecycle record: the function runs untracked, so reads in its body subscribe nothing, and whatever primitives it creates attach to the _caller's_ current owner. Dev and observe builds wrap the call in `observedComponent`, a transparent `createRoot` that carries the component's label so diagnostics can print `<TodoRow>`; its doc comment is explicit that _"The prod build never calls this"_ ([`core.ts`][observed]). 1.x had the same shape ([`component.ts` at 1.9.15][v1-component]).

Because the body is untracked, a top-level read freezes its value. 2.0 makes that loud: _"reading reactive values at the top level of a component body (including destructuring props) will warn"_ ([`MIGRATION.md`][migration-toplevel]) with `STRICT_READ_UNTRACKED` ([RFC 08][rfc08-strict]).

### Props are getters

A literal attribute becomes a data property of the props object; an expression the heuristic calls dynamic becomes a getter, so the read happens wherever the child reads `props.x`, inside the child's tracking scope. From the universal fixture ([input][fx-uc-in], [output][fx-uc-out]):

<!-- prettier-ignore -->
```jsx
// packages/babel-plugin/test/__universal_fixtures__/components/code.js
const template2 = (
  <Child
    name="Jake"
    dynamic={state.data}
    stale={/*@static*/ state.data}
    handleClick={clickHandler}
    hyphen-ated={state.data}
    ref={el => (e = el)}
  />
);
```

<!-- prettier-ignore -->
```js
// …/components/output.js
const template2 = _$createComponent(Child, {
  name: "Jake",
  get dynamic() {
    return state.data;
  },
  stale: state.data,
  handleClick: clickHandler,
  get "hyphen-ated"() {
    return state.data;
  },
  ref: el => (e = el)
});
```

`children` follows the same rule: `<Child><div /></Child>` compiles to `get children() { return _$createElement("div"); }` ([output][fx-uc-children]), so _"Non-expression children evaluate lazily on access"_ ([babel-plugin `README.md`][babel-readme-components]). The props object is therefore an ordinary object, not a proxy. Proxies appear only when props are combined: `merge(...)` and `omit(...)` return live views (a `Proxy` where the platform supports one, a getter-forwarding copy otherwise), whose reads _"go to the source that owns the key (a getter runs there, a data property is read live)"_ ([`merge`][merge], [`omit`][omit]).

The getter/data split is also visible at runtime. `isStatic(props, key)` (exported from `solid-js`) reports whether the caller wrote a literal, because _"the compiler encodes a literal at the call site (`as="button"`) as a data property and an expression […] as a getter"_ ([`isStatic`][is-static]); a library can then skip a computation for a literal prop.

### The reactivity boundary is the expression

Compiled output makes the boundary concrete. The README's benchmark row ([babel-plugin `README.md`][babel-readme-example]) destructures `item` (so `item` is static for that row), reads `selected()` (a signal) and `item.label` (a property access):

<!-- prettier-ignore -->
```js
// packages/babel-plugin/README.md — compiled output (excerpt; comments added)
_$insert(_el$2, itemId); // static: assigned once
_el$4._$$click = e => select(item, e); // handler: assigned once, never wrapped
_$insert(_el$4, () => item.label); // dynamic: one render effect
_$effect(
  () => selected(), // compute: tracked
  _v$ => _$className(_el$, itemId === _v$ ? "danger" : "") // apply: untracked DOM write
);
```

Each `insert(..., () => …)` and `effect(compute, apply)` is a [render effect][signals-flush] on the signals graph: its compute half tracks, its apply half writes the node. When `selected()` changes, only the `className` write re-runs; `view` itself is gone.

---

## The compile step

### Templates and holes

For the DOM target, each element subtree becomes one `template(html)` call hoisted to module scope. At runtime `template` parses the HTML once and returns a function that clones it (`cloneNode(true)`, or `importNode` for templates holding custom elements) ([`template`][web-template]). The compiled code then walks to the nodes that carry dynamic parts with `firstChild`/`nextSibling` chains and calls `insert(parent, value, marker)` for each child hole. From [`textInterpolation`][fx-text-in] ([output][fx-text-out]):

<!-- prettier-ignore -->
```js
// <span>Hello {name}</span>
var _tmpl$ = /*#__PURE__*/ _$template(`<span>Hello `);
var _el$4 = _tmpl$();
_$insert(_el$4, name, null);

// let value = "World"; <span>Hello {value + "!"}</span>
_tmpl$0 = /*#__PURE__*/ _$template(`<span>Hello World!`);
```

The second case shows constant folding: `getStaticExpression` asks Babel to `evaluate()` a child expression and inlines a string or number result into the template ([`utils.ts`][babel-static-expr]). Adjacent holes get `<!>` comment markers in the template so each `insert` has an anchor (`_tmpl$4 = template('<span> <!>')` in the same fixture).

### Static versus dynamic: the heuristic

`isDynamic` ([`utils.ts`][babel-isdynamic]) is purely syntactic. An expression is dynamic if it is, or contains outside a nested function, a call (including optional and tagged-template calls and `import()`), a member access (except on a namespace import), an optional member access, a spread, an `in` test, or — where JSX counts — a nested JSX element. Functions are never dynamic; a leading `/*@static*/` comment (the configurable `staticMarker`) forces static ([babel-plugin `README.md`][babel-readme-static]). An identifier is static. The [`attributeExpressions`][fx-attr-in] fixture shows the split on two otherwise identical attributes ([output][fx-attr-out]):

<!-- prettier-ignore -->
```js
// <div textContent={rowId} />  and  <div textContent={row.label} />
_el$5.textContent = rowId;
_$effect(
  () => row.label,
  _v$ => {
    _el$7.data = _v$;
  }
);
```

Child holes are more forgiving than attributes. `insert` checks `typeof accessor !== "function"` at runtime and treats a function value as reactive ([`insert`][web-insert]), so `{count}` with `count` a signal getter still updates; `textContent={count}` assigns the function itself.

### One effect per template

When an element group has several dynamic attributes, the compiler merges them into one effect whose compute returns an object and whose apply diffs each field against the previous run. From the same fixture ([input][fx-attr-in-group], [output][fx-attr-out-group]):

<!-- prettier-ignore -->
```js
// <input value={s()} min={min()} max={max()} … /> <input checked={s2()} min={min()} max={max()} … />
// (attributeExpressions/output.js, compute object joined onto one line)
_$effect(
  () => ({ e: s(), t: min(), a: max(), o: s2(), i: min(), n: max(), s: _$heldRead() }),
  ({ e, t, a, o, i, n, s }, _p$) => {
    (e !== _p$?.e || !s) && (_el$24.value = e ?? "");
    t !== _p$?.t && _$setAttribute(_el$24, "min", t);
    a !== _p$?.a && _$setAttribute(_el$24, "max", a);
    (o !== _p$?.o || !s) && (_el$25.checked = o);
    i !== _p$?.i && _$setAttribute(_el$25, "min", i);
    n !== _p$?.n && _$setAttribute(_el$25, "max", n);
  }
);
```

RFC 07 gives the reason and the cost: stateful properties _"share the template's grouped effect (one effect per template keeps rows cheap), so when `class={cls()}` on the same element — or on any element in that template — changes, the effect re-runs and writes `value` again"_ ([RFC 07][rfc07-forms]). `heldRead()` is the hook into the signals hold machinery that stops a re-run from writing a held value back over typed text.

### Conditionals are memoized

A ternary or `&&` whose branches are dynamic and whose test is dynamic is rewritten so the test runs in its own memo, coerced to boolean ([`transformCondition`][babel-condition]). From [`conditionalExpressions`][fx-cond-in] ([output][fx-cond-out]):

<!-- prettier-ignore -->
```js
// <div>{state.dynamic ? good() : bad}</div>
_$insert(
  _el$6,
  (() => {
    var _c$ = _$memo(() => !!state.dynamic);
    return () => (_c$() ? good() : bad);
  })()
);
```

The memo is what makes a branch stable. The hole's render effect owns whatever its compute creates, and a re-run disposes the previous run's children ([signals: lifetime and ownership][signals-lifetime]); without the boolean memo, a truthy-to-truthy change of `state.dynamic` would re-run the branch and rebuild it. The `wrapConditionals` option (default on) controls this ([babel-plugin `README.md`][babel-readme-config]).

### The compiler knows some components

Two features tie the compiler to specific component names. `builtIns` auto-imports `For`, `Show`, `Switch`, `Match`, `Loading`, `Reveal`, `Portal`, `Repeat`, `Dynamic` and `Errored` from `moduleName` when they appear in JSX ([babel-plugin `README.md`][babel-readme-builtins]). And in production builds `lowerShow` replaces a `<Show>` imported from `solid-js` or `@solidjs/web` with the memoized ternary it would render, _"minus the component call, the props object with its getters, and two of its three memos"_, when the `when` expression is safe to read twice ([`lower-show.ts`][lower-show]; [fixture output][fx-lowershow-out]). Dev builds keep the component.

### Runtime primitives the output calls

| Primitive                                                       | Where                              | Role                                                                                                                                         |
| --------------------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `template(html, flag?)`                                         | [`client.ts`][web-template]        | parse once, clone per instance                                                                                                               |
| `insert(parent, accessor, marker?, init?, options?)`            | [`client.ts`][web-insert]          | bind a child hole: a non-function value is inserted once; a function gets a render effect, and a function _returned_ by it gets a nested one |
| `effect(compute, apply, options?)`                              | [`render.ts`][web-effect]          | `createRenderEffect` with `{ transparent: true, sync: true }`: one attribute binding or one grouped template effect                          |
| `memo(fn)`                                                      | [`render.ts`][web-memo]            | `createMemo(fn, { sync: true })`: condition memos                                                                                            |
| `createComponent(Comp, props, name?, loc?)`                     | [`component.ts`][component-create] | the untracked call above; `name`/`loc` only under `sourceNames`                                                                              |
| `mergeProps(...)`, `spread(node, props, skipChildren)`          | [`client.ts`][web-exports]         | `{...props}` on components and elements: one props effect plus one children `insert`                                                         |
| `setAttribute`, `className`, `style`, `setProperty`, `addEvent` | [`client.ts`][web-exports]         | the write helpers an apply half calls                                                                                                        |
| `delegateEvents(names)`                                         | [`client.ts`][web-delegate]        | declares which event names the module needs delegated                                                                                        |
| `ref(() => value, el)`, `applyRef(value, el)`                   | [`client.ts`][web-ref]             | resolve a ref value untracked and call it (or each entry of a nested array) with the element                                                 |

The universal target replaces `template` and the DOM helpers with `createElement`, `createTextNode`, `insertNode` and `setProp` ([below](#the-universal-renderer-contract)).

### Two compilers, one corpus

`@solidjs/compiler` is a native Oxc port and _"the default in `vite-plugin-solid`"_; the Babel plugin is _"the JavaScript fallback"_ ([babel-plugin `README.md`][babel-readme]). The Rust tests read the Babel fixtures directly and classify each one's parity ([`babel-fixtures.test.js`][compiler-parity]). Both accept a second syntax: **TSRX** (TypeScript Render Extensions), an external draft language ([specification snapshot][tsrx-spec], _"Draft / June 7, 2026"_) whose `@if`/`@for … @empty`/`@switch`/`@try … @pending … @catch` blocks desugar to `Show`, `For`, `Switch`/`Match`, `Loading` and `Errored` before the shared JSX lowering runs ([TSRX frontend notes][tsrx-notes-lowering]; [babel-plugin `README.md`][babel-readme-tsrx]). It is marked experimental and adds no runtime concept: the lowering table maps every construct to an existing component.

---

## Authoring without a compiler: `h` and `html`

Both packages trade the compiler's static analysis for a runtime convention. The `h` README is blunt: it _"cannot leverage anything in the way of analysis, so it requires manual wrapping of expressions"_ ([`@solidjs/h` README][h-readme-cost]).

**What is lost.** No static/dynamic split, so the author marks every reactive expression by wrapping it in a function (`h("div", { id: () => props.id }, () => firstName() + lastName())`). No variable-assignment refs (`ref={el}`), only callbacks. No grouped template effects: `@solidjs/html` routes the props of every element that has any through the general `spread` path ([`renderChildren`][html-render]), and `h` uses `spread` whenever any prop is dynamic and `assign` otherwise ([`materialize`][h-materialize]). `h` also cannot hoist templates; `html` recovers that part by parsing each `TemplateStringsArray` once into a cached AST plus a `<template>` element and cloning it per call ([`getCachedRoot`][html-cache]).

**How reactivity is reconstructed: function arity.** The convention is _a zero-argument function is a reactive value; a function with parameters is a callback_. `h` turns every zero-arity function prop of a component into a getter and wraps higher-arity callbacks so the `h` thunks they return materialize at the call site ([`componentProps`][h-props]); on elements, zero-arity function values become getters except `ref` and `on[A-Z]…` handlers ([`materialize`][h-materialize]). `html` applies the same rule through `applyGetter` ([`tagged-jsx.ts`][html-getter]). The consequence is documented as a caveat: an event handler on a _component_ must declare its event parameter, or it becomes a getter that runs when the child reads it ([h README][h-readme-diffs]; [html README][html-readme-diffs]).

**Thunks stand in for lazy children.** `h(...)` returns a tagged thunk (`$ELEMENT`) that builds its node under `untrack` only when consumed, which is how `h` reproduces JSX's lazy `get children()` ([`h`][h-fn]). The README warns that wrapping it once more (`render(() => h(App), el)`) _"adds one function too many"_: the renderer then treats the inner thunk as a reactive expression and re-creates the component whenever its output changes ([h README][h-readme-render]).

> [!IMPORTANT]
> Both compiler-free forms are DOM-only at this commit: `hyperscript.ts` and `tagged-jsx.ts` import `insert`, `spread`, `createComponent` and the element tables from `@solidjs/web` ([`hyperscript.ts`][h-src], [`tagged-jsx.ts`][html-src]). A custom renderer built on `@solidjs/universal` has no compiler-free authoring path.

---

## The universal renderer contract

### Host operations

`createRenderer(options)` takes the host's node operations and returns the runtime the `generate: "universal"` compiler output imports ([universal `README.md`][u-readme-example]). The full option interface ([`universal.ts`][u-options]):

<!-- prettier-ignore -->
```ts
// packages/universal/src/universal.ts — RendererOptions
export interface RendererOptions<NodeType> {
  createElement(tag: string, staticProps?: Record<string, unknown>): NodeType;
  createTextNode(value: string): NodeType;
  createSentinel?(): NodeType;
  replaceText(textNode: NodeType, value: string): void;
  isTextNode(node: NodeType): boolean;
  setProperty<T>(node: NodeType, name: string, value: T, prev?: T): void;
  insertNode(parent: NodeType, node: NodeType, anchor?: NodeType): void;
  removeNode(parent: NodeType, node: NodeType): void;
  cleanupNodes?(parent: NodeType, nodes: NodeType[]): void;
  getParentNode(node: NodeType): NodeType | undefined;
  getFirstChild(node: NodeType): NodeType | undefined;
  getNextSibling(node: NodeType): NodeType | undefined;
}
```

| Operation                               | Called by                                                                                                                                  | Contract notes                                                                                                                             |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `createElement(tag, staticProps?)`      | compiled output                                                                                                                            | `staticProps` carries the literal props the compiler batched (`_$createElement("div", { textContent: rowId })`, [fixture][fx-ua-out])      |
| `createTextNode(value)`                 | compiled output; `normalize` for string/number children ([source][u-insexpr])                                                              | text leaves                                                                                                                                |
| `createSentinel?()`                     | `insert` for an empty multi-child region ([source][u-insert])                                                                              | defaults to `createTextNode("")`; holds the region's slot among siblings                                                                   |
| `replaceText(textNode, value)`          | `insertExpression`, text-to-text update ([source][u-insexpr])                                                                              | applied to `getFirstChild(parent)`                                                                                                         |
| `isTextNode(node)`                      | nothing                                                                                                                                    | required by the type and destructured in `createRenderer` ([source][u-create]), but no call site in `universal.ts` at this commit          |
| `setProperty(node, name, value, prev?)` | `setProp` in compiled effects; `spread`'s apply half, which also calls it with `undefined` for a key that disappeared ([source][u-spread]) | every attribute, event handler, `style` and `class` goes through it; the host interprets names (the README example lowercases `on*` names) |
| `insertNode(parent, node, anchor?)`     | compiled output, `insertExpression`, `reconcileArrays` ([source][u-reconcile])                                                             | `anchor` undefined means append                                                                                                            |
| `removeNode(parent, node)`              | `cleanChildren`, `reconcileArrays`                                                                                                         | detach only; disposal of reactive state is the owner tree's job                                                                            |
| `cleanupNodes?(parent, nodes)`          | the disposer `render` returns ([source][u-render])                                                                                         | default removes each node still under `parent`                                                                                             |
| `getParentNode(node)`                   | `reconcileArrays` liveness check, `cleanChildren`                                                                                          | identity comparison against the parent                                                                                                     |
| `getFirstChild(node)`                   | text replacement, single-child replacement, `render`'s mount bookkeeping                                                                   |                                                                                                                                            |
| `getNextSibling(node)`                  | `reconcileArrays` anchor computation                                                                                                       |                                                                                                                                            |

The contract is a mutable, ordered child list with stable node identity, plus a property setter that receives the previous value. Nothing in it is DOM-specific: no event model, no namespace, no template, no layout.

### What `createRenderer` returns

`render`, `effect`, `memo`, `createComponent`, `createElement`, `createTextNode`, `insertNode`, `insert`, `spread`, `setProp`, `mergeProps`, `applyRef` and `ref` ([`Renderer`][u-renderer]). `effect` and `memo` are the same sync render effect and sync memo the web runtime uses ([source][u-effect]); `createComponent` and `mergeProps` are re-exported from `solid-js`. `insert` follows the web algorithm: a function accessor gets a render effect, a function returned from it gets an inner effect (scheduled into the effect phase after the first run), and the apply half calls `insertExpression`, which replaces text, cleans children, or reconciles arrays ([`insert`][u-insert]). `render` mounts through `insert` with `{ schedule: true }` and drains with `flush()`, so a top-level async read holds the first commit the same way it does on the web ([universal `README.md`][u-readme-intro]). The README also tells the host to re-export `For`, `Repeat`, `Show`, `Switch`, `Match`, `Errored`, `Loading` and `Reveal` from `solid-js`, which work unchanged because they are renderer-neutral ([universal `README.md`][u-readme-example]).

### What the output looks like

Universal output has no templates: every element is a `createElement` call, every static child an `insertNode`, every dynamic attribute an `effect` whose apply calls `setProp` with the previous value. From the [`attributeExpressions`][fx-ua-out] universal fixture:

<!-- prettier-ignore -->
```js
var _el$5 = _$createElement("div"),
  _el$6 = _$createElement("div", { textContent: rowId }),
  _el$7 = _$createElement("div"),
  _el$8 = _$createElement("div", { innerHTML: "<div/>" });
_$insertNode(_el$5, _el$6);
_$insertNode(_el$5, _el$7);
_$insertNode(_el$5, _el$8);
_$spread(_el$5, () => getProps("test"), true);
_$effect(
  () => row.label,
  (_v$, _$p) => {
    _$setProp(_el$7, "textContent", _v$, _$p);
  }
);
```

A host also supplies its own JSX types (`jsx-runtime`/`jsx-dev-runtime` entries describing its intrinsic elements); the README ships a minimal template ([universal `README.md`][u-readme-ts]). `generate: "dynamic"` mixes the two outputs, routing a configured set of tags to the DOM renderer ([compiler `README.md`][compiler-readme-dynamic]).

### What a universal host does not get

- **No event delegation.** Delegation, `delegateEvents` and the `_$$click` handler slots are `@solidjs/web` code; the universal compiler emits no event handling ([`universal/element.ts`][babel-universal-el]), so `onClick` reaches `setProperty` as a function-valued prop.
- **No template cloning.** Every instance runs the full `createElement`/`insertNode` sequence.
- **A different list diff.** Universal `reconcileArrays` is the classic prefix/suffix/end-swap/map loop ([source][u-reconcile]); the web one ([`reconcile.ts`][web-reconcile]) adds `moveBefore`, slot ownership tags and an index-stamp map.
- **No hydration and no compiler-free authoring** (see [above](#authoring-without-a-compiler-h-and-html)).

---

## Control flow as components

Every control-flow component returns an accessor (a memo, or a function over one) that `insert` binds like any other dynamic child. What it creates inside that memo's run is owned by the run, so the [signals ownership rule][signals-lifetime] — a re-run disposes the previous run's children — is the whole disposal mechanism.

### `Show`, `Switch`/`Match`: one memo per decision

`Show` builds three memos ([`flow.ts`][flow-show]): `conditionValue` reads `props.when`; `condition` wraps it with `equals: (a, b) => !a === !b`, so it only changes when truthiness flips; and the output memo reads `condition()` and, when truthy, calls the children. Non-keyed, a truthy-to-truthy change of `when` therefore does not re-run the output memo, and the child stays mounted while its accessor (`u()`) reads the new value. `keyed` drops the boolean memo, so any identity change of `when` re-runs the output memo, disposes the old branch, and mounts a new one with the raw value. The function-child form is detected by arity, `typeof child === "function" && child.length > 0`, and called under `untrack`. `Switch` resolves its children with `children()`, chains one condition memo per `Match` so later matches read `undefined` once an earlier one wins, and picks the first truthy one ([`flow.ts`][flow-switch]); `Match` itself just returns its props ([`flow.ts`][flow-match]).

### `For`: two reconciliations

`For` is a thin wrapper that, on first read (at creation while hydrating), calls `mapArray(() => props.each, props.children, options)` under its own owner ([`flow.ts`][flow-for]). Its options are read once: `{ keyed: props.keyed }` is captured at creation, which is why RFC 03 says to _"avoid dynamic boolean `keyed` values with function children"_ ([RFC 03][rfc03-for]). The three modes ([RFC 03][rfc03-for], [`mapArray`][map-array]):

| `keyed`         | Row identity | Callback receives                 | Per-row signals                                                  |
| --------------- | ------------ | --------------------------------- | ---------------------------------------------------------------- |
| absent / `true` | item `===`   | raw `item`, `index` accessor      | an index signal only if the callback declares an index parameter |
| `false`         | position     | `item` accessor, numeric `index`  | an item signal per row (the 1.x `Index`)                         |
| `(item) => key` | `key(item)`  | `item` accessor, `index` accessor | item and index signals                                           |

Reconciliation happens twice, at two levels.

1. **Data level, `mapArray`** ([`updateKeyedRows`][map-update]). Each row is mapped under a fresh `createOwner()`. A pass skips the common prefix and suffix (writing a changed item into its row signal in the accessor modes), returns early with the _same_ mapped array if nothing moved, tries a bounded small-move fast path on large windows, and otherwise builds a `Map` from key to new positions over the changed window, carries matched rows (mapping, owner, row and index signals) to their new slots, creates new rows under new owners, and disposes the owners of rows that left. Passes are staged: a mapper that throws (for example `NotReadyError` from an async read) disposes only the owners that pass created and leaves the previous state intact for the retry ([`map.ts`][map-abort]). A fresh `_mappings` array identity is the change signal downstream.
2. **Node level, `insert` → `reconcileArrays`.** The mapped array is an array of nodes, and `insertExpression` diffs it against the nodes currently in the parent: a _"slightly modified version of"_ WebReflection's udomdiff ([`reconcile.ts`][web-reconcile-origin]) with prefix/suffix skipping, end swaps, and a map fallback that uses an index stamp on each new node; on the web it moves connected nodes with `moveBefore()` where available so focus survives ([`reconcile.ts`][web-reconcile]).

Rows that survive keep their owner, so their effects and DOM are untouched; a removed row's owner is disposed, which runs its cleanups and drops its effects. 1.x used the same `mapArray`/`indexArray` split behind `For`/`Index` ([`flow.ts` at 1.9.15][v1-flow]).

`Repeat` skips the data diff altogether: `repeat(count, map, { from })` keeps one owner per index in a window, disposes indexes leaving `[from, from + count)` and creates new ones, and hands each row a plain number ([`map.ts`][map-repeat], [`flow.ts`][flow-repeat]). RFC 03 positions it for store-backed lists, where _"the index is just a stable lookup key; reactivity comes from the store reads"_ ([RFC 03][rfc03-repeat]).

> [!NOTE]
> `documentation/proposals/keyed-list-driver.md` describes a compiler-stamped list driver that bypasses `mapArray`. It is headed _"PROPOSAL ONLY. Nothing in this document is implemented"_ ([proposal][kld]), and the experimental driver it builds on was removed in the 2.0.0 release: _"the insert `$ll` seam stripped"_, `driveList`/`rowProof` deleted ([babel-plugin `CHANGELOG.md`][babel-changelog-driver]). No `$ll`, `driveList` or `rowProof` remains in any package source at this commit.

### `Loading`, `Errored`, `Reveal`

These three are one-line components over signals primitives: `createLoadingBoundary(() => props.children, () => props.fallback, { on })`, `createErrorBoundary(() => props.children, (err, reset) => …)` and `createRevealOrder` ([`flow.ts`][flow-errored], [`flow.ts`][flow-loading], [`flow.ts`][flow-reveal]). Their semantics — `NotReadyError` propagation, holds, error status — belong to the graph and are covered in [signals: async computations][signals-async] and [signals: errors][signals-errors]. One rendering detail: the `Loading` doc comment states that the children _"are not re-created; they stay alive behind the fallback"_ ([`flow.ts`][flow-loading]).

---

## Props, children, refs, context, events and lifecycle

| Area      | 2.0 mechanism                                                                                                                                                                                                                                                                                                                                      | Change from 1.x                                                                                                                                                                                 |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Props     | getters on a plain object; `merge(...sources)` and `omit(props, ...keys)` return live views ([`merge`][merge], [`omit`][omit])                                                                                                                                                                                                                     | `mergeProps` → `merge`, where _"`undefined` is treated as a real value (it overrides)"_; `splitProps` → `omit`, which returns only the rest ([`MIGRATION.md`][migration-props])                 |
| Children  | `props.children` is a getter that builds nodes when read; `children(fn)` resolves it in two lazy memos and adds `toArray()` ([`children`][children])                                                                                                                                                                                               | same API; the 2.0 memos are `lazy` ([`children` at 1.9.15][v1-children] used eager memos)                                                                                                       |
| Refs      | `ref={el}` assigns, `ref={fn}` calls, `ref={[a, b]}` flattens and calls each; the callback runs untracked through `runRefCallback` ([`ref`][web-ref], [`runRefCallback`][run-ref]); before insertion, so `el.isConnected` is `false` ([RFC 07][rfc07-refs])                                                                                        | _"ref callbacks are now **unowned**"_; `use:` directives become ref factories with an owned setup half and an unowned apply half ([`MIGRATION.md`][migration-refs])                             |
| Context   | `createContext` returns a provider component; its two lazy memos `setContext` on their first pass, and `useContext` reads the owner chain ([`createContext`][context])                                                                                                                                                                             | `<Ctx.Provider value>` → `<Ctx value>`; a default-less context returns `T` and throws `ContextNotFoundError` when missing ([`MIGRATION.md`][migration-context])                                 |
| Events    | `onX` (uppercase after `on`) only; delegated handlers are stored on the node as `_$$click` (+ `_$$clickData` for the `[handler, data]` form) and served by one listener per name on the render root, which walks from the target up to the root ([`eventHandler`][web-event-handler], [delegated list][web-events]); others use `addEventListener` | delegation moved from `document` to each render root; lowercase `onclick` is now an attribute; `on:`/`oncapture:` removed, native options go through a ref ([`MIGRATION.md`][migration-events]) |
| Lifecycle | `onSettled(fn)` runs after the current activity settles and may return a cleanup bound to the owner ([`onSettled`][on-settled]); `onCleanup` unchanged ([`onCleanup`][on-cleanup]); effects are split compute/apply ([signals][signals-page])                                                                                                      | `onMount` → `onSettled` ([`MIGRATION.md`][migration-onmount]); 1.x `onMount` was `createEffect(() => untrack(fn))` ([`signal.ts` at 1.9.15][v1-onmount])                                        |

Event handlers are never wrapped. The [`eventExpressions`][fx-event-in] fixture assigns each handler once ([output][fx-event-out]), and RFC 08 states it as a rule: _"An event handler is bound once, where its element is created, so the expression on `onClick={…}` […] is not reactive"_ ([RFC 08][rfc08-strict]).

<!-- prettier-ignore -->
```js
// <button onChange={() => …}>  <button onClick={() => …}>  <button onClick={[fn, rowId]}>
_el$2.addEventListener("change", () => console.log("bound"));
_el$7._$$click = () => console.log("delegated");
_el$8._$$click = id => console.log("delegated", id);
_el$8._$$clickData = rowId;
```

> [!WARNING]
> `MIGRATION.md` says _"`getOwner()` is `null` inside"_ a ref callback ([`MIGRATION.md`][migration-refs]). The code path read here — `ref` → `runRefCallback` → `untrack` — does not reset the owner; it sets a ref-callback depth that dev builds check, so `onCleanup` and primitive creation there throw `CLEANUP_IN_FORBIDDEN_SCOPE` / `PRIMITIVE_IN_EFFECT_CALLBACK` ([`runRefCallback`][run-ref], [`onCleanup`][on-cleanup], [docs][docs-cj-refs]). Whether `getOwner()` literally returns `null` was not verified.

`@solidjs/element` shows the props mechanism from the other side, where a host drives a component: `customElement(tag, defaults, Comp)` turns each declared prop into a signal behind a getter/setter and writes it from the element's property-changed callback ([`createProps`][element-props]), then renders into the shadow root under a root it disposes on release ([`withSolid`][element-with]).

---

## What 2.0 renamed or removed for authoring

| 1.x                                                | 2.0                                                                     | Source                              |
| -------------------------------------------------- | ----------------------------------------------------------------------- | ----------------------------------- |
| `solid-js/web`, `/h`, `/html`, `/universal`        | `@solidjs/web`, `@solidjs/h`, `@solidjs/html`, `@solidjs/universal`     | [`MIGRATION.md`][migration-renames] |
| `JSX` namespace and `jsx-runtime` in `solid-js`    | renderer-owned; `Element` from `solid-js` for neutral APIs              | [RFC 09][rfc09-removals]            |
| `mergeProps` / `splitProps`                        | `merge` / `omit`                                                        | [`MIGRATION.md`][migration-renames] |
| `Index`                                            | `For keyed={false}`                                                     | [RFC 03][rfc03-removals]            |
| `Suspense` / `SuspenseList` / `ErrorBoundary`      | `Loading` / `Reveal` / `Errored`                                        | [RFC 03][rfc03-removals]            |
| `createDynamic(source, props)`                     | `dynamic(source)` factory; `<Dynamic>` kept but deprecated              | [RFC 03][rfc03-removals]            |
| —                                                  | `Repeat` (new)                                                          | [RFC 03][rfc03-repeat]              |
| `onMount`                                          | `onSettled`                                                             | [`MIGRATION.md`][migration-renames] |
| `Context.Provider`                                 | the context is the provider                                             | [`MIGRATION.md`][migration-context] |
| `use:` directives                                  | `ref` directive factories, ref arrays                                   | [RFC 07][rfc07-removals]            |
| `classList`, `attr:`, `bool:`, `on:`, `oncapture:` | `class` object/array; standard attribute model; camelCase events + refs | [RFC 07][rfc07-removals]            |
| `/*@once*/`                                        | removed; `untrack` in JavaScript or a `default*` DOM prop               | [`MIGRATION.md`][migration-once]    |
| nested `createRoot` detached                       | owned by its parent; `runWithOwner(null, …)` to detach                  | [`MIGRATION.md`][migration-root]    |

---

## Known pain points and limitations

1. **Destructuring or top-level reads freeze props.** The getter only tracks if it is called inside a tracking scope. The docs' pitfall box: _"Change the quantity in the parent and the `Avoid` versions keep showing the first value"_ ([`components-and-jsx.mdx`][docs-cj-pitfall]). 2.0 adds the dev warning `STRICT_READ_UNTRACKED` and tells authors, and coding agents by name, not to silence it with `untrack` ([RFC 08][rfc08-strict]).
2. **The heuristic is syntax, not types.** An identifier is static, so `textContent={rowId}` is written once even if `rowId` is a getter function, while `{rowId}` as a child updates because `insert` checks `typeof` at runtime ([fixture][fx-attr-out], [`insert`][web-insert]). The escape hatch for the other direction is `/*@static*/`, which survives in both compilers even though `/*@once*/` was removed from the public model and the migration guide says _"do not look for a marker-based replacement"_ ([babel-plugin `README.md`][babel-readme-static], [`MIGRATION.md`][migration-once]).
3. **Handlers are bound once.** `onClick={selected() ? save : cancel}` reads `selected()` at creation; only dev builds warn ([RFC 08][rfc08-strict]).
4. **Reading `props.children` twice builds twice.** It is a getter that creates nodes. `Repeat` reads it once per row because _"a second read would build the row's nodes (and run its refs) twice"_ (`#4296`, [`flow.ts`][flow-repeat]); the `children()` helper exists to memoize the read.
5. **Arity carries meaning.** `Show`/`Match` treat a function child as a callback only if `child.length > 0` ([`flow.ts`][flow-show]); `h`/`html` treat any zero-arity function prop as a getter, so `onClick={() => …}` on a component silently becomes a getter ([h README][h-readme-diffs]).
6. **Grouped effects re-write siblings.** A change to any dynamic attribute in a template re-runs its grouped effect, which re-writes stateful properties such as `value`; inputs are _"not strictly controlled"_ and the recommended pattern is a draft signal ([RFC 07][rfc07-forms]).
7. **Identity keying punishes fresh objects.** A refetch that returns new objects for the same records rebuilds every row ([`components-and-jsx.mdx`][docs-cj-problems]); the attribution engine flags it as `UNSTABLE_LIST_IDENTITY`, whose RFC text suggests `<For by="id">` — a prop `For` does not have at this commit ([RFC 08][rfc08-list], [`For`][flow-for]).
8. **Spread order is not guaranteed** _"given independent binding updates"_ ([babel-plugin `README.md`][babel-readme-spread]), and a props getter _"is defined only for a read through its own object"_: copying its descriptor elsewhere and reading it there is unsupported ([`merge`][merge]).
9. **The compiler is coupled to library names.** Auto-imported `builtIns` and the production `lowerShow` pass recognize `Show` by import source ([`lower-show.ts`][lower-show]); a user component with the same role gets neither.
10. **Custom renderers are second-class.** Only the README documents `@solidjs/universal` (solid-docs mentions it only as a moved import path, [migration page][docs-migration]); it lacks delegation, templates, hydration and compiler-free authoring, and its list diff lags the web one.

---

## Strengths

- **No per-component runtime cost.** In production a component is one untracked function call; only bindings and control-flow memos exist at runtime.
- **Updates touch exactly what changed.** A binding re-runs one compute and one targeted write; a list update keeps row owners and moves nodes.
- **Control flow is ordinary code.** `For`, `Show`, `Loading` are a few dozen lines over `mapArray` and memos; a host renderer gets them for free.
- **A small, honest host contract.** Twelve node operations, all structural; everything above them is shared.
- **Compiled output is readable and testable.** Fixture pairs pin the lowering, and two compilers are held to the same corpus.

## Weaknesses

- **The rules depend on where a read happens**, which the source does not show: `props.x` in JSX tracks, the same expression one line above does not.
- **Syntactic heuristics** decide static versus dynamic, with an attribute/child asymmetry and a comment-marker escape hatch.
- **JavaScript-specific conventions** carry meaning: getters, function arity, `typeof` checks on values, proxies for prop views.
- **The non-DOM path is thin**: no delegation, no template cloning, no hydration, no compiler-free authoring, sparse documentation.
- **Compiler and library are coupled** through auto-imports and the `Show` lowering.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                | Trade-off                                                                                                  |
| ----------------------------------------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| Component runs once, untracked, with no instance            | Zero overhead per component; reactivity lives in bindings                | Top-level reads and destructuring freeze values; needs a dev warning to teach                              |
| Dynamic props as getters on a plain object                  | The read happens in the consumer's tracking scope; literals cost nothing | Getter semantics leak (copying descriptors, double reads of `children`); combining props needs proxy views |
| Syntactic static/dynamic heuristic                          | Decided at compile time without type information                         | Identifiers are assumed static; `/*@static*/` marker needed for the reverse case                           |
| One render effect per hole, one grouped effect per template | Few graph nodes per row; diffing inside the apply half                   | Any attribute change re-runs the group and re-writes stateful properties                                   |
| Conditions memoized to booleans                             | Branches survive value churn under per-run ownership                     | Extra memos per conditional; the compiler rewrites user expressions                                        |
| Control flow as components over `mapArray`/memos            | One mechanism (ownership per run) disposes everything                    | Callback shape varies by mode (`keyed`), detected partly by arity                                          |
| Two-level list reconciliation                               | Data diff preserves owners; node diff minimizes moves                    | Two passes and two maps per structural change; keying by identity rebuilds fresh objects                   |
| Host contract of structural node operations                 | Any retained tree can host Solid                                         | Everything DOM-specific (events, templates, hydration) must be rebuilt by the host or is absent            |

---

## Lessons for a D UI toolkit

The question this survey feeds is what Solid-style authoring would look like over a D, non-DOM toolkit such as [`sparkles:ui`][sparkles-ui]. Two caveats from the [signals page][signals-immediate] carry over: Solid's guarantees assume a _retained_ node tree whose writers are render effects, and `sparkles:ui` today rebuilds `view() → layout()` per frame.

| Mechanism                                                                     | Transfers?                                                                                                         | Depends on a JS feature                                                                                                                                                 |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Component = function called once under `untrack`, no instance                 | yes, directly                                                                                                      | none                                                                                                                                                                    |
| Binding per hole: `effect(compute, apply(value, prev))`; grouped per template | yes; maps onto a render-effect queue drained before layout                                                         | **closures everywhere**: every hole is a closure over node handles; in `@nogc` D each needs an explicit context (struct + function)                                     |
| Props as lazy reads at the consumer                                           | yes, better typed: a props struct whose dynamic fields are `Accessor!T` makes the static/dynamic split a type fact | **getters** hide the call, which is the root of the destructuring pitfall; **proxies** for `merge`/`omit` views (D: struct composition or `opDispatch` at compile time) |
| Static/dynamic decision at compile time                                       | yes, and decidable by type through Design by Introspection instead of syntax                                       | the JSX compiler itself; the arity/`typeof` conventions of `h`/`html` are JS runtime substitutes                                                                        |
| The universal host contract (12 structural operations)                        | yes, the most portable piece: a widget-tree backend implements create/insert/remove/sibling/setProperty            | none beyond stable node identity and `prev`-aware setters                                                                                                               |
| Two-level list reconciliation (keyed owners, then node moves)                 | yes; needs a hash map on keys and node identity                                                                    | **GC**: removed rows' closures and nodes are reclaimed by the collector; explicit disposal only runs cleanups                                                           |
| Control flow as components owning one child scope per memo run                | yes; needs the signals owner tree                                                                                  | none                                                                                                                                                                    |
| Two-phase directives (owned setup, unowned apply), ref arrays                 | yes                                                                                                                | none                                                                                                                                                                    |
| Context on the owner chain                                                    | yes                                                                                                                | none                                                                                                                                                                    |
| Root-owned event delegation                                                   | as a pattern: hit-test once at the root, walk up the node parent chain, call a per-node handler slot               | the DOM event model (`composedPath`, `stopPropagation`)                                                                                                                 |
| Template cloning                                                              | partially: prebuilt static subtrees copied per instance                                                            | the DOM's `<template>`/`cloneNode`                                                                                                                                      |

---

## Sources

- [solidjs/solid at `solid-js@2.0.3`][repo] · [`LICENSE`][license]
- Component model: [`component.ts` — `createComponent`][component-create] · [`core.ts` — `observedComponent`][observed], [`createContext`][context], [`children`][children] · [`store/utils.ts` — `merge`][merge], [`omit`][omit], [`isStatic`][is-static] · [`signals.ts` — `onSettled`][on-settled], [`onCleanup`][on-cleanup] · [`core.ts` — `runRefCallback`][run-ref]
- Control flow: [`flow.ts`][flow] ([`For`][flow-for], [`Repeat`][flow-repeat], [`Show`][flow-show], [`Switch`][flow-switch], [`Match`][flow-match], [`Errored`][flow-errored], [`Loading`][flow-loading], [`Reveal`][flow-reveal]) · [`map.ts` — `mapArray`][map-array], [`updateKeyedRows`][map-update], [`repeat`][map-repeat] · [keyed-list driver proposal][kld]
- Web runtime: [`client.ts` — `render`][web-render], [`template`][web-template], [`delegateEvents`][web-delegate], [`eventHandler`][web-event-handler], [`ref`][web-ref], [`insert`][web-insert] · [`render.ts` — `effect`][web-effect], [`memo`][web-memo] · [`reconcile.ts`][web-reconcile] · [`constants.ts` — delegated events][web-events]
- Universal: [`universal.ts`][u-src] · [`README.md`][u-readme-example] · [test renderer][u-test]
- Compiler: [babel-plugin `README.md`][babel-readme] · [`utils.ts` — `isDynamic`][babel-isdynamic], [`transformCondition`][babel-condition] · [`lower-show.ts`][lower-show] · [`CHANGELOG.md`][babel-changelog-driver] · [compiler `README.md`][compiler-readme] · [parity test][compiler-parity]
- Fixtures: [`textInterpolation`][fx-text-out] · [`attributeExpressions`][fx-attr-out] · [`conditionalExpressions`][fx-cond-out] · [`eventExpressions`][fx-event-out] · [`lowerShow`][fx-lowershow-out] · universal [`components`][fx-uc-out], [`attributeExpressions`][fx-ua-out]
- No-compiler forms: [`hyperscript.ts`][h-src] · [`@solidjs/h` README][h-readme] · [`tagged-jsx.ts`][html-src] · [`@solidjs/html` README][html-readme] · [`@solidjs/element`][element-props]
- RFCs and guides: [03 control flow][rfc03-for] · [07 DOM][rfc07-forms] · [08 dev diagnostics][rfc08-strict] · [09 TypeScript/JSX][rfc09-summary] · [`MIGRATION.md`][migration] · TSRX [frontend notes][tsrx-notes] and [specification snapshot][tsrx-spec]
- solid-docs at `c32486f`: [Components and JSX][docs-cj] · [Migrating from 1.x][docs-migration]
- 1.x comparison (`solid-js@1.9.15`): [`component.ts`][v1-component] · [`flow.ts`][v1-flow] · [`signal.ts` — `onMount`][v1-onmount], [`children`][v1-children]
- Related: [Solid 2.0 signals][signals-page] · [Jetpack Compose][compose] · [Reactive programming survey][index-umbrella] · [`sparkles:ui`][sparkles-ui]

<!-- References -->

[repo]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1
[license]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/LICENSE
[pkg-solid]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid
[pkg-web]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web
[pkg-universal]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal
[pkg-babel]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin
[pkg-compiler]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/compiler
[pkg-h]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/h
[pkg-html]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/html
[pkg-element]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/element
[component-create]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/component.ts#L74-L104
[observed]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/core.ts#L234-L334
[context]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/core.ts#L131-L193
[children]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/core.ts#L199-L232
[merge]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/store/utils.ts#L946-L980
[omit]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/store/utils.ts#L1098-L1160
[is-static]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/store/utils.ts#L245-L273
[on-settled]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/signals.ts#L1203-L1236
[on-cleanup]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/signals.ts#L95-L115
[run-ref]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/core.ts#L1570-L1601
[flow]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/flow.ts
[flow-for]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/flow.ts#L65-L111
[flow-repeat]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/flow.ts#L128-L148
[flow-show]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/flow.ts#L168-L263
[flow-switch]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/flow.ts#L286-L357
[flow-match]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/flow.ts#L402-L421
[flow-errored]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/flow.ts#L442-L464
[flow-loading]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/flow.ts#L466-L541
[flow-reveal]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/solid/src/client/flow.ts#L589-L594
[map-array]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/map.ts#L20-L108
[map-abort]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/map.ts#L112-L120
[map-update]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/map.ts#L397-L704
[map-repeat]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/map.ts#L706-L834
[kld]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/proposals/keyed-list-driver.md#L1-L37
[web-render]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/client.ts#L380-L457
[web-template]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/client.ts#L521-L540
[web-delegate]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/client.ts#L541-L618
[web-event-handler]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/client.ts#L3139-L3225
[web-ref]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/client.ts#L1483-L1504
[web-insert]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/client.ts#L1736-L1847
[web-exports]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/client.ts#L716-L1500
[web-effect]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/render.ts#L37-L84
[web-memo]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/render.ts#L86-L96
[web-reconcile]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/reconcile.ts#L1-L159
[web-events]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/constants.ts#L53-L77
[u-src]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts
[u-options]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts#L28-L41
[u-renderer]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts#L56-L91
[u-effect]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts#L93-L105
[u-create]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts#L118-L133
[u-insert]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts#L134-L183
[u-insexpr]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts#L185-L237
[u-reconcile]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts#L239-L348
[u-spread]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts#L375-L491
[u-render]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/src/universal.ts#L576-L614
[u-readme-intro]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/README.md#L1-L5
[u-readme-example]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/README.md#L47-L107
[u-readme-ts]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/README.md#L121-L174
[u-test]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/universal/test/custom.js
[babel-readme]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/README.md#L1-L9
[babel-readme-heuristic]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/README.md#L13-L15
[babel-readme-example]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/README.md#L17-L74
[babel-readme-config]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/README.md#L159-L164
[babel-readme-builtins]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/README.md#L173-L178
[babel-readme-static]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/README.md#L187-L192
[babel-readme-tsrx]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/README.md#L289-L316
[babel-readme-spread]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/README.md#L355-L361
[babel-readme-components]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/README.md#L363-L381
[babel-iscomponent]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/src/shared/utils.ts#L128-L134
[babel-isdynamic]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/src/shared/utils.ts#L158-L259
[babel-static-expr]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/src/shared/utils.ts#L261-L275
[babel-condition]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/src/shared/utils.ts#L525-L621
[babel-universal-el]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/src/universal/element.ts
[babel-changelog-driver]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/CHANGELOG.md#L108
[lower-show]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/src/shared/lower-show.ts#L5-L27
[compiler-readme]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/compiler/README.md
[compiler-readme-dynamic]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/compiler/README.md#L62-L80
[compiler-parity]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/compiler/__tests__/babel-fixtures.test.js#L1-L33
[fx-text-in]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/textInterpolation/code.js#L7-L59
[fx-text-out]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/textInterpolation/output.js#L4-L32
[fx-attr-in]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/attributeExpressions/code.js#L28-L34
[fx-attr-out]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/attributeExpressions/output.js#L152-L166
[fx-attr-in-group]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/attributeExpressions/code.js#L114-L119
[fx-attr-out-group]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/attributeExpressions/output.js#L263-L288
[fx-cond-in]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/conditionalExpressions/code.js#L1-L11
[fx-cond-out]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/conditionalExpressions/output.js#L8-L40
[fx-event-in]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/eventExpressions/code.js#L11-L24
[fx-event-out]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/eventExpressions/output.js#L32-L43
[fx-lowershow-out]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__dom_fixtures__/lowerShow/output.js#L29-L53
[fx-uc-in]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__universal_fixtures__/components/code.js#L30-L39
[fx-uc-out]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__universal_fixtures__/components/output.js#L104-L115
[fx-uc-children]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__universal_fixtures__/components/output.js#L116-L125
[fx-ua-out]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/babel-plugin/test/__universal_fixtures__/attributeExpressions/output.js#L68-L86
[h-src]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/h/src/hyperscript.ts#L1-L11
[h-fn]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/h/src/hyperscript.ts#L16-L28
[h-props]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/h/src/hyperscript.ts#L84-L127
[h-materialize]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/h/src/hyperscript.ts#L129-L210
[h-readme]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/h/README.md
[h-readme-cost]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/h/README.md#L18
[h-readme-render]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/h/README.md#L20-L24
[h-readme-diffs]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/h/README.md#L62-L129
[html-src]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/html/src/tagged-jsx.ts#L18-L31
[html-cache]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/html/src/tagged-jsx.ts#L76-L103
[html-render]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/html/src/tagged-jsx.ts#L172-L244
[html-getter]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/html/src/tagged-jsx.ts#L291-L314
[html-readme]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/html/README.md
[html-readme-diffs]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/html/README.md#L79-L134
[element-props]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/element/src/index.ts#L14-L28
[element-with]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/element/src/index.ts#L42-L92
[rfc03-for]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/03-control-flow.md#L20-L54
[rfc03-repeat]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/03-control-flow.md#L56-L82
[rfc03-removals]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/03-control-flow.md#L434-L448
[rfc07-refs]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/07-dom.md#L66-L98
[rfc07-forms]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/07-dom.md#L142-L170
[rfc07-removals]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/07-dom.md#L229-L238
[rfc08-strict]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/08-dev-diagnostics.md#L394-L439
[rfc08-list]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/08-dev-diagnostics.md#L649-L653
[rfc09-summary]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/09-typescript-jsx.md#L7-L33
[rfc09-removals]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/09-typescript-jsx.md#L95-L103
[migration]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md
[migration-root]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md#L203-L223
[migration-onmount]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md#L186-L201
[migration-toplevel]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md#L229-L256
[migration-once]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md#L276-L306
[migration-props]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md#L425-L448
[migration-events]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md#L574-L618
[migration-refs]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md#L620-L700
[migration-context]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md#L712-L748
[migration-renames]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md#L1052-L1100
[tsrx-notes]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/tsrx/frontend-notes.md
[tsrx-notes-lowering]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/tsrx/frontend-notes.md#L78-L119
[tsrx-spec]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/tsrx/tsrx-specification-snapshot.md#L1-L26
[v1-component]: https://github.com/solidjs/solid/blob/a252c783b709e84e1e650a774d6cb52af7624ce7/packages/solid/src/render/component.ts#L97-L114
[v1-flow]: https://github.com/solidjs/solid/blob/a252c783b709e84e1e650a774d6cb52af7624ce7/packages/solid/src/render/flow.ts#L34-L82
[v1-onmount]: https://github.com/solidjs/solid/blob/a252c783b709e84e1e650a774d6cb52af7624ce7/packages/solid/src/reactive/signal.ts#L998-L1006
[v1-children]: https://github.com/solidjs/solid/blob/a252c783b709e84e1e650a774d6cb52af7624ce7/packages/solid/src/reactive/signal.ts#L1242-L1252
[docs-cj]: https://github.com/solidjs/solid-docs/blob/c32486fb8e61a75d698648064822d54777d77138/src/routes/(2)concepts/(1)components-and-jsx.mdx
[docs-cj-intro]: https://github.com/solidjs/solid-docs/blob/c32486fb8e61a75d698648064822d54777d77138/src/routes/(2)concepts/(1)components-and-jsx.mdx#L7-L10
[docs-cj-exec]: https://github.com/solidjs/solid-docs/blob/c32486fb8e61a75d698648064822d54777d77138/src/routes/(2)concepts/(1)components-and-jsx.mdx#L13-L25
[docs-cj-pitfall]: https://github.com/solidjs/solid-docs/blob/c32486fb8e61a75d698648064822d54777d77138/src/routes/(2)concepts/(1)components-and-jsx.mdx#L81-L103
[docs-cj-refs]: https://github.com/solidjs/solid-docs/blob/c32486fb8e61a75d698648064822d54777d77138/src/routes/(2)concepts/(1)components-and-jsx.mdx#L182-L187
[docs-cj-problems]: https://github.com/solidjs/solid-docs/blob/c32486fb8e61a75d698648064822d54777d77138/src/routes/(2)concepts/(1)components-and-jsx.mdx#L574-L578
[docs-migration]: https://github.com/solidjs/solid-docs/blob/c32486fb8e61a75d698648064822d54777d77138/src/routes/(6)migration/(0)from-solid-1.mdx#L62-L67
[web-reconcile-origin]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/web/src/reconcile.ts#L1-L3
[signals-page]: ./solid-signals.md
[signals-flush]: ./solid-signals.md#the-flush-microtask-heap-then-two-effect-queues
[signals-async]: ./solid-signals.md#async-computations-flights-notreadyerror-holds
[signals-errors]: ./solid-signals.md#errors-and-completion
[signals-lifetime]: ./solid-signals.md#lifetime-and-ownership
[signals-immediate]: ./solid-signals.md#the-worked-pipeline
[compose]: ./jetpack-compose.md
[index-umbrella]: ./index.md
[sparkles-ui]: ../../libs/ui/index.md
