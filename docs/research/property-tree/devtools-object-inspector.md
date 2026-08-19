# Chrome DevTools object inspector (TypeScript / DevTools front end)

The only subject inspecting a **live, foreign, cyclic** value graph it does not own — across a process boundary — where every expansion is a protocol round trip and no walk is ever automatic.

|                        |                                                                |
| ---------------------- | -------------------------------------------------------------- |
| **Language / toolkit** | TypeScript / DevTools front end (`TreeOutline`)                |
| **License**            | BSD-3-Clause                                                   |
| **Repository**         | [`ChromeDevTools/devtools-frontend`][repo]                     |
| **Revision read**      | [`788f6469`][rev]                                              |
| **Category**           | Remote handles; lazy per-expansion fetch                       |
| **Metadata source**    | the CDP `Runtime.getProperties` reply — descriptors, not types |
| **Undo**               | none (edits are `Runtime.callFunctionOn` evaluations)          |

## Overview

### What it solves

Showing a JavaScript value the inspector cannot hold: it lives in another process, it changes
under you, it is routinely cyclic (`window.window`), its "fields" may be getters with side
effects, and an array may have a million elements. Every hard case this survey treats as an
edge case is the normal case here.

### Design philosophy

The front end never has the object — only an id for it. `RemoteObject.objectId`
([`RemoteObject.ts:179`][objectid]) is the handle; properties arrive as `RemoteObjectProperty`
descriptors ([`:661`][property]) carrying `enumerable`, `writable`, `isOwn`, `wasThrown`,
`symbol`, `synthetic`, `getter`, `setter`. Expansion is `getOwnProperties` /
`getAllProperties` ([`:195`][getprops]), i.e. a round trip; collapse can release the handle
(`releaseObject`, [`:568`][release]).

## Model & addressing

**Handle plus path.** The tree element is `ObjectPropertyTreeElement`
([`ObjectPropertiesSection.ts:1969`][treeelement]) over a `RemoteObjectProperty`, and each
property exposes `path()` ([`:2306`][path]) — a dotted route from the root used for
persistence-free identity (which properties were expanded, which were edited).

Two consequences no in-process subject has:

- **Identity is owned by the other side.** A `objectId` is valid until released or until the
  execution context is destroyed; the inspector is holding a lease, not a pointer.
- **Nothing is ever fully known.** The tree cannot be flattened, counted or searched exhaustively
  without asking the page — so every "how many rows?" question the type-driven subjects answer
  statically is unanswerable here in principle.

## Recursion

**Descent is per expansion, and expansion is I/O.** `onpopulate` clears and refetches children
([`:2187`][onpopulate]); `onexpand`/`oncollapse` record the state on the node
([`:2206`][onexpand]).

Three bounds keep a hostile graph presentable:

| Bound                                      | Value                          | Effect                                                                                   |
| ------------------------------------------ | ------------------------------ | ---------------------------------------------------------------------------------------- |
| `InitialVisibleChildrenLimit`              | 200 ([`:1670`][limit])         | beyond it, a **"show all"** button rather than more rows ([`:2173`][showall])            |
| `ArrayGroupingTreeElement.bucketThreshold` | 100 ([`:2528`][thresholds])    | an array longer than this is grouped into `[from … to]` buckets ([`:2450`][bucketlabel]) |
| `sparseIterationThreshold`                 | 250000 ([`:2529`][thresholds]) | above it, ranges are computed without iterating every index                              |

Bucketing is itself recursive — a bucket of 100 000 elements contains buckets — so an array of
any size presents as a fixed handful of rows. That is a different answer from [Godot's][godot]
pagination (a window with page controls): a **hierarchy of ranges**, navigable by expansion
rather than by paging.

### Cycles

There is no cycle guard, and none is needed: **no walk is automatic**. A cyclic graph is
expanded one level per click, each level a fresh fetch, so `window.window.window…` is finite
work per interaction and terminates when the reader stops — the position [Godot][godot] and
[WinForms][winforms] take by accident, here as an explicit consequence of the protocol.
Compare [Unity's][unity] visited set and [rjsf's][rjsf] cycle tag: both are needed precisely
because those subjects have a walk (expand-all; schema resolution) that runs without a human.
DevTools has neither.

**Getters are not invoked.** A property backed by a getter renders as an invoke affordance, and
the call happens only when clicked (`invokeGetter`, [`:859`][invokegetter], wired to a click at
[`:1742`][gettersclick]). Reading a value can be a side effect, so the inspector refuses to
read it on the reader's behalf — the strongest statement in the corpus that _displaying_ and
_evaluating_ are different acts. Nothing in Tier 1 distinguishes them: every other subject
calls the getter to paint the row.

## Editing & mutation

- **Dispatch** — by the descriptor and the value's remote `type`/`subtype`, not by a type
  registry: primitives get an editable text form, objects get expanders, functions get links to
  source, DOM nodes get element links.
- **Mutation** — an edit is compiled into an assignment evaluated **in the page**
  (`callFunctionOn`), so the write is a remote side effect. There is no transaction and no undo;
  the console log is the audit trail.
- **Commit** — on Enter/blur of the inline editor; a failed evaluation surfaces as a thrown
  value (`wasThrown` on the descriptor).
- **Change notification** — none, deliberately. The displayed value is a snapshot from the last
  fetch; the corpus's other subjects re-read every frame or subscribe. Here re-reading is a
  network cost, so the tree goes stale by design and refreshes on re-expansion.

## Type coverage

- **Collections** — the bucket hierarchy above, plus `Map`/`Set` entries as synthetic
  `[[Entries]]` groups.
- **Polymorphic values** — read-only inspection, so no picker; the runtime type is shown as a
  prefix and the internal `[[Prototype]]` is a child row.
- **Optional / unset** — `undefined` vs absent vs `null` are all distinct and shown distinctly;
  non-enumerable and own-vs-inherited are rendered differently (dimmed / grouped).
- **Opaque values** — nothing is opaque, but everything may be _unavailable_: a released handle,
  a destroyed context, a getter that throws (`wasThrown`), or an object too large to preview.
  The renderer has a state for each.

## Presentation & control

- **Grouping** — own vs inherited, enumerable vs not, internal slots (`[[Prototype]]`,
  `[[Entries]]`), and index buckets.
- **Conditional visibility** — descriptor-driven (`enumerable`, `isOwn`, `private`, `symbol`).
- **Search / filter** — a filter box over the currently _materialised_ rows only; the graph
  cannot be searched exhaustively because it is not held.
- **Escape hatches** — custom formatters (`CustomPreviewComponent`), the page's own
  `devtoolsFormatters` hook, and the console REPL as the ultimate one.
- **Virtualization** — the `TreeOutline` renders materialised rows; the real bound is the fetch
  limits above, which are cheaper than virtualization because unfetched rows do not exist.

## Strengths

- Handles a graph that is foreign, live, cyclic and unbounded, without owning any of it.
- Bounds by fetch policy (200 / 100 / 250 000) rather than by rendering policy.
- Distinguishes displaying from evaluating: getters stay uninvoked until asked.
- Rich descriptor vocabulary (own, enumerable, private, symbol, synthetic, thrown) surfaced as
  presentation.
- Recursive bucketing makes any array size a constant number of rows.

## Weaknesses

- Values go stale; there is no live binding.
- Editing is a remote evaluation with no undo and no validation.
- Identity is a lease that can be revoked (context destroyed) — every operation must handle
  the object having vanished.
- Search is limited to what has already been fetched.

## Key design decisions and trade-offs

| Decision                             | Rationale                                                    | Trade-off                                                                 |
| ------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Handles, never values                | The graph lives in another process and may be huge or cyclic | Everything is async; the row set is never fully known                     |
| Expansion = fetch                    | Cost is proportional to what the reader opens                | Stale data between expansions; no live updates                            |
| Fetch-time limits (200 / bucket 100) | A hostile object cannot flood the UI                         | The reader sees a truncated truth and must ask for more                   |
| Recursive index buckets              | Any array length becomes a few rows                          | An element's row is several clicks deep                                   |
| Getters never auto-invoked           | Reading must not cause side effects                          | The reader sees "(...)" rather than a value until they ask                |
| No cycle guard                       | No automatic walk exists to guard                            | Any future "expand all" feature would need one — as [Unity's][unity] does |

## Sources

All line numbers are at [`788f6469`][rev].

- [`front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts`][treeelement] — tree elements, `onpopulate`, visible-children limit, array bucketing, getter invocation
- [`front_end/core/sdk/RemoteObject.ts`][objectid] — `objectId`, `RemoteObjectProperty` descriptors, `getOwnProperties`/`getAllProperties`, `releaseObject`

<!-- References -->

[repo]: https://github.com/ChromeDevTools/devtools-frontend
[rev]: https://github.com/ChromeDevTools/devtools-frontend/tree/788f6469296bf2420bd95bb6d73d28a21439f345
[objectid]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/core/sdk/RemoteObject.ts#L179
[property]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/core/sdk/RemoteObject.ts#L661
[getprops]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/core/sdk/RemoteObject.ts#L195
[release]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/core/sdk/RemoteObject.ts#L568
[treeelement]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L1969
[path]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L2306
[onpopulate]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L2187
[onexpand]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L2206
[limit]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L1670
[showall]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L2173
[thresholds]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L2528
[bucketlabel]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L2450
[invokegetter]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L859
[gettersclick]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L1742
[godot]: ./godot-inspector.md
[winforms]: ./winforms-propertygrid.md
[unity]: ./unity-serializedproperty.md
[rjsf]: ./react-jsonschema-form.md
