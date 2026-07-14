# Theatre.js (TypeScript)

A sequencing/keyframe toolkit plus a GUI studio that animates the declared
properties of _any_ JavaScript object — a tweening-and-editor building block that
emits interpolated values and delegates **all** rendering to its host, **not** a
renderer of its own.

| Field           | Value                                                                                                                                                           |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | TypeScript (runs in the browser; also usable server-side/headless as a value source)                                                                            |
| License         | [Apache-2.0][license-apache] for [`@theatre/core`][npm-core] / [`@theatre/r3f`][npm-r3f]; **[AGPL-3.0-only][license-agpl]** for [`@theatre/studio`][npm-studio] |
| Repository      | [`theatre-js/theatre`][repo] (Yarn monorepo, ~12.5k stars; last pushed Aug 14 2024)                                                                             |
| Documentation   | [theatrejs.com/docs/latest][docs]                                                                                                                               |
| Category        | Keyframe/sequence animation runtime + visual timeline editor (renderer-agnostic value layer)                                                                    |
| First release   | [`@theatre/core`][npm-core] `0.4.0-dev.1` (Jun 25 2021); first stable `0.4.0` (Sep 20 2021)                                                                     |
| Latest release  | `0.7.2` (May 19 2024) for `@theatre/core`, `@theatre/studio`, `@theatre/r3f`                                                                                    |
| What it renders | **Nothing.** It emits interpolated prop values through `object.onValuesChange(cb)`; the host (Three.js/WebGL, DOM/CSS, `<canvas>`) does every pixel             |
| Editor          | **Theatre Studio** ([`@theatre/studio`][npm-studio]) — an in-browser visual keyframe/timeline editor, `studio.initialize()`, tree-shaken out of production      |

> [!NOTE]
> This page is grounded in the official docs ([theatrejs.com/docs/latest][docs])
> and the source tree at [`theatre-js/theatre`][repo] (`main`; package versions
> pinned to `0.7.2` on npm). Theatre.js produces **no pixels of its own** — it is
> a value-sequencing layer — so no `ci`-compiled D probe reproduces "its output."
> The catalog's dependency-free probes ([`rate-functions.d`][rate-functions],
> [`bezier-eval.d`][bezier-eval], [`affine-transform.d`][affine-transform],
> [`frame-capture.d`][frame-capture]) reimplement the shared math (easing curves,
> Bézier bases, affine composition, readback checksum) that a _host_ renderer
> driven by Theatre.js relies on — Theatre.js itself only touches the easing/lerp
> half.

---

## Overview

### What it solves

Theatre.js targets **high-fidelity, hand-tuned motion design authored on a
timeline** rather than in imperative render code. Its own README states the scope
plainly ([`README.md`][repo]):

> _"Theatre.js is an animation library for high-fidelity motion graphics. It is
> designed to help you express detailed animation, enabling you to create
> intricate movement, and convey nuance."_

The problem it owns is the one every code-only engine in this survey (Manim,
Motion Canvas, Remotion) leaves to the author: **placing and shaping keyframes
by eye**. Instead of computing an animation from a script, you declare the
properties you want to drive, then **scrub a playhead and set keyframes in a
visual editor** — Theatre Studio — while the library interpolates between them
and pushes the results into your code every frame. It deliberately supplies only
the timeline, the keyframes, the interpolation, and the GUI; it never decides
what a shape is or how to draw one.

The complementary problem it solves is **framework neutrality**: the same
sequencing core drives Three.js, the DOM, a `<canvas>`, or plain variables. The
docs overview states ([overview][docs]):

> _"Theatre.js works with any front-end library or framework."_

### Design philosophy

The project frames itself less as a library than as a **design tool that erases
role boundaries** ([overview][docs]):

> _"Theatre.js is a design tool in the making. We aim to blur the line between
> designer/developer, author/consumer, and artist/scientist."_

Three commitments follow from that stance. First, **the editor is a
first-class, co-designed half** — not a debugging aid but the intended authoring
surface, which is why it ships as a distinct package under a copyleft
(**[AGPL-3.0][license-agpl]**) license while the runtime is permissive
([Apache-2.0][license-apache]). Second, **the runtime is a pure value source**:
`@theatre/core` computes interpolated values from a saved keyframe state and hands
them to you, with **zero rendering assumptions**, so it composes with any host.
Third, **animation state is data, not code** — a project's keyframes serialize to
a JSON blob that the editor exports and the runtime replays, which is what lets
the editor be stripped from production entirely.

---

## How it works

The core hierarchy is **`Project` → `Sheet` → Sheet `object`**. You get a project
by name, carve it into sheets, declare a sheet object with a **typed prop schema**,
and subscribe to its interpolated values. The canonical Three.js walkthrough
([with THREE.js][with-three]) shows every step.

A **project** is the top-level unit; [`getProject`][manual-projects] is
idempotent by name and optionally seeded with an exported `state` JSON:

```ts
import { getProject, types } from '@theatre/core';

// dev-only editor; tree-shaken out of production (see below)
import studio from '@theatre/studio';
studio.initialize();

const project = getProject('THREE.js x Theatre.js', { state: projectState });
```

A **sheet** groups objects that animate together and owns exactly one
**sequence** ([Sheets][manual-sheets]: _"Sheets contain one or more Objects, that
can be animated together."_):

```ts
const sheet = project.sheet('Animated scene');
```

A **sheet object** is a named bag of **typed, animatable props** declared with the
[`types`][manual-prop-types] combinators — here a [`types.compound`][manual-prop-types]
grouping three [`types.number`][manual-prop-types]s, each with a display `range`:

```ts
const torusKnotObj = sheet.object('Torus Knot', {
  rotation: types.compound({
    x: types.number(mesh.rotation.x, { range: [-2, 2] }),
    y: types.number(mesh.rotation.y, { range: [-2, 2] }),
    z: types.number(mesh.rotation.z, { range: [-2, 2] }),
  }),
});
```

Finally, `object.onValuesChange(cb)` is the **entire hand-off to your renderer**:
Theatre.js interpolates the keyframed props and calls back with plain values,
which you write into whatever host you like ([with THREE.js][with-three]):

```ts
torusKnotObj.onValuesChange(values => {
  const { x, y, z } = values.rotation;
  mesh.rotation.set(x * Math.PI, y * Math.PI, z * Math.PI);
});
```

The split across two packages is the crux: [`@theatre/core`][npm-core] is the
runtime (`getProject`, `types`, `onValuesChange`, sequence playback);
[`@theatre/studio`][npm-studio] is the editor, imported and `initialize()`d
**only in development** and removed by the bundler for production (see
[Interactivity, preview & authoring](#interactivity-preview--authoring)). The
reactive value machinery underneath both lives in a separate internal package,
[`@theatre/dataverse`][dataverse] (pointers + derivations), but consumers only
ever touch the `core`/`studio` surface above.

---

## Object & scene model

> [!IMPORTANT]
> **Theatre.js has no geometry scene graph, no [`Mobject`][mobject], no vector
> paths.** Its "objects" are not drawable shapes — they are named collections of
> **typed scalar/compound props to animate**. This is the first and biggest
> absence: where Manim's object model _is_ the drawing (a retained tree of
> Béziers), Theatre.js's object model is a **property schema over things it never
> sees**.

The hierarchy is deliberately shallow and non-geometric:

| Level          | Role                                                                                                                                               | API                           |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| `Project`      | Top-level container; holds the saved keyframe **state**. _"All your work in Theatre.js is organized into Projects."_ ([Projects][manual-projects]) | `getProject(name, { state })` |
| `Sheet`        | Groups objects animated together; owns one `sequence`; supports **instances** (`sheet(name, id)`)                                                  | `project.sheet(name, id?)`    |
| Sheet `object` | A named prop bag: _"These Sheet Objects have a matching prop for all the properties we want to animate."_ ([Objects][manual-objects])              | `sheet.object(name, props)`   |
| prop           | A leaf value with a **type** and an initial value (`number`, `string`, `rgba`, `compound`, …)                                                      | `types.number(0, opts)` etc.  |

The objects page is explicit that an object stands in for _something the host
owns_ ([Objects][manual-objects]):

> _"Everything on the page or in the scene is represented by a Theatre.js Sheet
> Object. These Sheet Objects have a matching prop for all the properties we want
> to animate for an object in our scene."_

An object can back _"THREE.js objects, DOM elements, or virtual objects"_ —
because Theatre.js never inspects the target, only its prop schema. Objects are
addressed by **namespaced keys** (e.g. `"Basics / Boxes / box-0"`), and sheet
**instances** (`project.sheet('Button', 'Submit')` vs `('Button', 'Cancel')`)
reuse one animation definition to drive many targets independently
([Sheets][manual-sheets]). There is no parent/child transform tree, no
[submobject family][mobject], no [affine model][affine-transform] — spatial
composition (nesting, transforms, camera) is entirely the host's job. The
[`affine-transform.d`][affine-transform] probe's composition facts belong to
whatever renderer consumes the values, not to Theatre.js.

## Animation & timing model

This is Theatre.js's **entire reason to exist**, and the one axis where it is a
full participant rather than a delegator. Its execution model is the survey's
**GUI-timeline / keyframe** model ([execution models][execution-models]): each
[`Sheet`][manual-sheets] owns a **`Sequence`** with a **playhead** — `sequence.position`,
a time in seconds — and animated props carry **keyframes** placed on that
timeline. Playing the sequence sweeps the playhead; between adjacent keyframes the
runtime **interpolates** ([lerp][interpolation]) each prop and fires
`onValuesChange`. Keyframes are authored in the editor, not in code
([Sequences][manual-sequences]): _"Removing keyframes is as easy as right-clicking
on them and selecting the 'Delete' option."_

The shape of the motion between two keyframes is a **per-segment easing curve**,
edited with a tween editor that is CSS-like by design ([Sequences][manual-sequences]):

> _"The tween editor can be used to apply timing functions that control the speed
> curve of the transition between the two keyframes. These are very similar to the
> `transition-timing-functions` in CSS."_

Each segment is thus a **cubic-Bézier timing function** — the same
[rate-function / easing][rate-func] reshaping the [`rate-functions.d`][rate-functions]
probe tabulates, applied _per keyframe pair_ rather than per whole animation. This
is a sharper contrast with Manim than it first appears: Manim wraps a **whole
`play()` call** in one `rate_func` and builds larger animations from a
**combinator algebra** (`AnimationGroup`, `Succession`, `lag_ratio`; see
[animation composition][composition]); Theatre.js has **no such combinators** —
"composition" is just where you drop keyframes on a shared timeline and which
easing curve you draw between them. Staggering that Manim expresses as
`lag_ratio` is expressed here as offset keyframe positions on the track.

Playback is driven with [`sheet.sequence.play(conf)`][manual-sequences], whose
`conf` mirrors CSS animation controls — `rate` (speed multiplier, default `1`),
`range` (`{ from, to }` in the timeline), `iterationCount` (default `1`, may be
`Infinity`), and `direction` (`'normal'` | `'reverse'` | `'alternate'` |
`'alternateReverse'`); the call returns a promise that resolves `true` on natural
completion or `false` if interrupted by `sequence.pause()`
([Sequences][manual-sequences]):

```ts
sheet.sequence.play({ iterationCount: Infinity, direction: 'alternate' });
```

Because `sequence.position` is settable, you can also **scrub programmatically**
(bind it to scroll, a slider, or audio time) — the runtime recomputes all prop
values from the new playhead with no notion of "current frame index." There is no
[`ValueTracker`/updater][updaters] machinery to bolt on: driving a value _is_ the
whole model, and `onValuesChange` is the reactive push. What Manim reaches for
with `add_updater` and `always_redraw`, Theatre.js gets structurally from the
sequence → `onValuesChange` pipeline.

## Rendering backend & rasterization

> [!WARNING]
> **Theatre.js has no rendering backend and no rasterizer — this axis is entirely
> an absence.** It never fills a path, strokes a line, allocates a framebuffer, or
> touches a GPU. There is no [Cairo/CPU-vector][cpu-gpu] oracle and no
> [GPU stencil-and-cover][cpu-gpu] path because there is **no drawing at all**.

Everything the survey files under [rasterization][rasterization] happens **in the
host**. When `onValuesChange` hands you `{ x, y, z }`, _you_ call
`mesh.rotation.set(...)` and _Three.js/WebGL_ rasterizes; or you set
`div.style.left` and the **browser** composites; or you paint a `<canvas>` and the
**Canvas2D implementation** rasterizes. Theatre.js is agnostic to all of it, which
is precisely the _"works with any front-end library or framework"_ ([overview][docs])
promise.

The [color model][color-gamma] concern is likewise the host's. Theatre.js offers a
[`types.rgba`][manual-prop-types] prop that it will **interpolate as four
components**, but it has no opinion on premultiplied alpha, sRGB vs linear space,
or gamma-correct compositing — it lerps the channel numbers and the consumer
decides how to interpret and blend them. Whether that blend is gamma-correct
(the [color-model-and-gamma][color-gamma] pitfall) is determined wholly by the
renderer the values flow into. [Anti-aliasing][rasterization], [MSAA][rasterization],
and driver reproducibility ([CPU-vs-GPU][cpu-gpu]) are simply out of scope.

## Typesetting & text

> [!IMPORTANT]
> **No typesetting, no text layout, no glyph handling — another clean absence.**
> Theatre.js has no [glyph-outline extraction][glyph-outline], no
> [LaTeX-to-SVG][glyph-outline] pipeline, no [HarfBuzz/Pango shaping][text-shaping],
> and no font model of any kind.

A [`types.string`][manual-prop-types] prop exists, but it is an **animatable
string value**, not typeset text: Theatre.js will keyframe and interpolate it as a
value and hand it back via `onValuesChange`. What that string _becomes_ — a DOM
text node the browser shapes with HarfBuzz, a Three.js text mesh, a `<canvas>`
`fillText` call, a LaTeX-compiled equation — is entirely the host's doing. There
is nothing analogous to Manim's `dvisvgm` route or Motion Canvas's in-process
MathJax `Latex` node. If you want animated math or morphable glyph contours, you
render them in the host and animate the host's parameters (opacity, position,
progress) through a Theatre.js object. The [glyph-outline][glyph-outline] and
[text-shaping][text-shaping] concepts have **no representation** in this engine.

## Output & encoding

> [!WARNING]
> **Theatre.js is not a video tool. It has no encoder, no frame-capture path, no
> muxer, and no headless render-to-file mode.** The
> [frame-capture / readback][readback] and [codec / muxing / pixel-format][codec-muxing]
> concerns are **absent** — there is nothing to read back because Theatre.js
> renders nothing.

Its only "output" is **project state as JSON** — the saved keyframes, not pixels.
The editor exports it and the runtime replays it ([Projects][manual-projects]):

> _"This state is stored as a JSON object in `localStorage` when the studio is
> open and can be exported as a JSON file."_

```ts
import projectState from './state.json';
const project = getProject('My Project', { state: projectState });
```

Producing a **video** is therefore a host-and-toolchain problem entirely outside
Theatre.js. To capture frames deterministically you would drive `sequence.position`
in a headless host (e.g. a WebGL context under a browser automation harness),
read that host back ([readback][readback]), and pipe the frames to an external
encoder ([codec/muxing][codec-muxing]) — none of which Theatre.js provides,
recommends, or ships. Where Manim community pipes RGBA to `ffmpeg`/PyAV and Motion
Canvas has an `@motion-canvas/ffmpeg` exporter, Theatre.js has **no export
pipeline at all**: it is a live/runtime animation driver, not a batch renderer.

## Interactivity, preview & authoring

This is the axis where Theatre.js is **strongest** — the timeline editor is the
product. **Theatre Studio** is the in-browser visual authoring surface
([Studio][manual-studio]):

> _"The Studio is Theatre.js' editor that you can use at development to edit your
> scene, tweak values and create animations."_

It renders only when explicitly started — _"The Studio is only shown if
`studio.initialize` is called"_ ([Studio][manual-studio]) — and provides a
**scrubbable timeline with a playhead**, per-object **keyframe tracks**, a
**details panel** for nudging live prop values (bounded by each prop's `range`
guide), and the **tween editor** for drawing per-segment
[cubic-Bézier easing curves][rate-func]. Real-time editing is the whole point:
drag a value, set a keyframe, move the playhead, watch the host update through
`onValuesChange`.

The signature production concern is that **the editor is excluded from shipped
builds**. `@theatre/studio` is imported and initialized behind an environment
guard so the bundler tree-shakes it away ([with React Three Fiber][with-r3f]):

```ts
// Vite
if (import.meta.env.DEV) {
  studio.initialize();
  studio.extend(extension);
}
// Create-React-App
if (process.env.NODE_ENV === 'development') {
  studio.initialize();
  studio.extend(extension);
}
```

The docs make the tree-shaking explicit ([with React Three Fiber][with-r3f]):

> _"We can also achieve the last step without manually editing the code every
> time by using environment-checks and relying on our bundler's tree-shaking
> feature."_

Going to production is then just: _"1. Make sure that we have the latest project
state exported to a JSON file and passed to `getProject`. 2. Remove
`studio.initialize` and `studio.extend`."_ ([with React Three Fiber][with-r3f]).
The AGPL-licensed editor thus never reaches end users; only the Apache-licensed
runtime and a JSON state file do.

## Extensibility & API surface

The surface is small and cleanly two-layered:

- **Runtime vs editor split** — [`@theatre/core`][npm-core]
  (`getProject`/`sheet`/`object`/`types`/`sequence`/`onValuesChange`) carries all
  playback and value logic with no editor and no rendering; [`@theatre/studio`][npm-studio]
  is the optional, dev-only authoring UI. The reactive value core is factored out
  again into [`@theatre/dataverse`][dataverse].
- **Prop-type system** — the [`types`][manual-prop-types] combinators are the
  extension point for _what_ can be animated: `types.number(v, { range, nudgeMultiplier })`,
  `types.string`, `types.boolean`, `types.stringLiteral` (enumerated choices),
  `types.rgba` (color), `types.image` (asset refs, since `0.6.0`), and
  `types.compound({...})` to group props into a nested structure. The docs note a
  number's `range` is presentational — _"opts.range is just a visual guide, not a
  validation rule"_ ([Prop types][manual-prop-types]).
- **`studio.extend(extension)`** — custom editor panes/toolbars plug into the
  Studio via an extension API (used above alongside `studio.initialize()`).
- **Integrations** — [`@theatre/r3f`][npm-r3f] is the marquee one:
  _"A Theatre.js extension for THREE.js with React Three Fiber"_ ([r3f README][r3f-readme]).
  It exposes an `editable as e` HOC (`<e.mesh theatreKey="..." />`) and a
  `PerspectiveCamera` with `makeDefault`, so R3F objects become Theatre.js objects
  declaratively. `@theatre/theatric` offers a hook-first React API over the same
  core.
- **Host-agnostic by construction** — because the only contract is "declare typed
  props, receive interpolated values," _any_ target (WebGL, DOM/CSS, `<canvas>`,
  audio params, plain variables) is drivable with no adapter beyond an
  `onValuesChange` handler.

## Determinism, caching & performance

Theatre.js is **deterministic in the strong sense the survey wants**: the mapping
from `sequence.position` (the playhead) and the saved keyframe **state** to the
prop values delivered by `onValuesChange` is a **pure function of the playhead** —
seek to the same position and you get identical values every run. This satisfies
the [deterministic-frame-sampling][deterministic] prerequisite _for the value
layer_. But the survey's determinism concern is ultimately about **pixels**, and
Theatre.js emits none; whether the final frames are bit-reproducible is entirely a
property of the [host renderer][cpu-gpu] (a Canvas2D/WebGL host is not
bit-identical across drivers; a CPU-vector host could be). Theatre.js removes one
source of nondeterminism (the animation math) and delegates the rest.

> [!NOTE]
> **No [content-hash / partial-movie caching][content-hash] — because there is no
> render to cache.** Manim community hashes each `play()` call and reuses a cached
> partial movie file; that optimization is meaningless here, since Theatre.js
> never produces a movie. Its "cache" is the **JSON state file** (authoring output
> reused as runtime input) plus the internal [`@theatre/dataverse`][dataverse]
> derivation graph, which memoizes computed values until a dependency changes — a
> _within-frame_ compute cache, not a _cross-run render_ cache. The
> [`frame-capture.d`][frame-capture] checksum a render cache would key on has no
> analog on the Theatre.js side of the boundary.

Performance-wise the runtime is intentionally light: it maintains a reactive
pointer/derivation graph and fires callbacks, so cost scales with the number of
animated props and subscribers, not with any drawing. The heavy work — geometry,
rasterization, encoding — is always the host's, so Theatre.js's own footprint in a
production bundle is just the Apache-licensed `@theatre/core` runtime plus the
state JSON.

---

## Strengths

- **Best-in-class visual keyframe authoring.** Theatre Studio's scrubbable
  timeline, per-segment [cubic-Bézier easing][rate-func] tween editor, and live
  value nudging make hand-tuned motion far easier than any code-only engine in
  this survey.
- **Truly renderer-agnostic.** The "declare typed props → receive interpolated
  values" contract drives Three.js, the DOM, `<canvas>`, audio, or plain
  variables with no rendering assumptions — _"works with any front-end library or
  framework."_
- **Animation-as-data.** Keyframes serialize to JSON; the editor exports it and
  the runtime replays it, giving a clean dev-authoring / prod-replay split.
- **Editor is free in production.** The dev-only `@theatre/studio` is tree-shaken
  out; production ships only the small Apache-licensed runtime and a state file.
- **Rich, extensible prop-type system** (`number` with `range`/`nudgeMultiplier`,
  `compound`, `rgba`, `stringLiteral`, `image`, …) plus `studio.extend` and
  first-party integrations (`@theatre/r3f`, `@theatre/theatric`).
- **Deterministic value layer** — playhead → values is a pure function, removing
  the animation math as a source of nondeterminism.

## Weaknesses

- **Renders nothing.** No rasterizer, no geometry, no scene graph — you must bring
  a host renderer and wire every prop through `onValuesChange` yourself.
- **No object/geometry model.** Objects are prop bags, not shapes; there is no
  [`Mobject`][mobject]/[VMobject][vmobject] equivalent, no transforms, no morphing
  of paths — spatial structure is 100% the host's.
- **No typesetting or text.** No [glyph-outline extraction][glyph-outline], no
  LaTeX, no [shaping][text-shaping]; `types.string` is a value, not typeset text.
- **No video output.** No [frame capture/readback][readback], no
  [encoder/muxer][codec-muxing]; exporting a movie is an external toolchain
  problem Theatre.js does not address.
- **No composition combinator algebra.** No `AnimationGroup`/`Succession`/
  `lag_ratio` ([composition][composition]); sequencing is manual keyframe
  placement on a timeline.
- **Editor is AGPL-3.0.** [`@theatre/studio`][license-agpl] is copyleft; teams
  that vendor or modify the editor must weigh its terms (the runtime is
  permissive, so shipped apps are unaffected).
- **Pre-1.0 and quiet.** Latest `0.7.2` (May 2024); the repo's last push is
  Aug 2024 — API stability and momentum are open questions.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                     | Trade-off                                                                             |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Value-only core; delegate **all** rendering to the host      | Works with any framework; keeps the runtime tiny and unopinionated            | No object/geometry/text/pixel model — the developer must supply and wire a renderer   |
| `Project → Sheet → object` of **typed props**, not shapes    | A minimal, serializable schema over things Theatre.js never inspects          | No scene graph, transforms, or morphing; spatial composition is the host's job        |
| GUI-timeline / keyframe execution with a scrubbable playhead | Hand-tuned motion design; author by eye, scrub `sequence.position` at runtime | No code-level combinator algebra (`lag_ratio`, `Succession`); staggering is manual    |
| Per-segment cubic-Bézier easing (CSS-like tween editor)      | Fine-grained, visually-editable speed curves between keyframes                | Easing lives in editor state, not in source; reviewability differs from code          |
| Split runtime (Apache-2.0) vs editor (AGPL-3.0) packages     | Editor is a first-class product; permissive runtime for shipped apps          | Copyleft editor complicates vendoring/forking Studio; two licenses to reason about    |
| Editor excluded from production via env-guard tree-shaking   | Zero editor weight in prod; authoring output reduced to a JSON state file     | Requires bundler discipline; forgetting the guard ships (and exposes) the AGPL editor |
| Animation state as exported JSON, replayed by `getProject`   | Clean dev-authoring / prod-replay boundary; state is diffable data            | Not human-authored; hand-editing keyframe JSON is impractical vs code-defined motion  |
| `onValuesChange` push as the sole host hand-off              | One uniform, framework-neutral integration point                              | Every target property needs a hand-written subscriber; no automatic binding           |

---

## Sources

Primary sources (docs pinned to the live `latest` site unless noted; source and
licenses from [`theatre-js/theatre`][repo] `main`; versions from npm `0.7.2`):

- [Docs overview][docs] — the _"design tool in the making … blur the line"_
  philosophy and the _"works with any front-end library or framework"_ scope.
- [`README.md`][repo] — _"an animation library for high-fidelity motion graphics."_
- [Getting started — with THREE.js][with-three] — the `getProject` → `sheet` →
  `sheet.object(types.compound(...))` → `onValuesChange` walkthrough and
  `studio.initialize()`.
- [Getting started — with React Three Fiber][with-r3f] — the production
  tree-shaking pattern (`import.meta.env.DEV` / `process.env.NODE_ENV`), the
  "export state + remove studio" checklist.
- [Manual — Projects][manual-projects] — _"All your work … is organized into
  Projects,"_ `getProject`, JSON state export/import.
- [Manual — Sheets][manual-sheets] — _"Sheets contain one or more Objects …,"_
  `project.sheet`, `sheet.sequence`, sheet instances.
- [Manual — Objects][manual-objects] — _"Everything … is represented by a Theatre.js
  Sheet Object,"_ `sheet.object`, `onValuesChange` delivering interpolated values.
- [Manual — Sequences][manual-sequences] — playhead/`sequence.position`, keyframes,
  the CSS-like tween editor (_"very similar to the `transition-timing-functions` in
  CSS"_), `sheet.sequence.play(conf)`.
- [Manual — Prop types][manual-prop-types] — `types.number`/`compound`/`rgba`/
  `stringLiteral`/`image`, `range` as a _"visual guide, not a validation rule."_
- [Manual — Studio][manual-studio] — _"the editor you can use at development … The
  Studio is only shown if `studio.initialize` is called."_
- [`@theatre/r3f` README][r3f-readme] — _"A Theatre.js extension for THREE.js with
  React Three Fiber."_
- Licenses: [`LICENSE` (Apache-2.0)][license-apache] · [`packages/studio/LICENSE`
  (AGPL-3.0)][license-agpl]; npm `license` fields confirm
  [`@theatre/core`][npm-core] Apache-2.0, [`@theatre/studio`][npm-studio]
  AGPL-3.0-only, [`@theatre/r3f`][npm-r3f] Apache-2.0.
- Internal reactive core: [`@theatre/dataverse`][dataverse] (pointers/derivations).

<!-- References -->

<!-- External: Theatre.js docs (live) + source/licenses on main + npm 0.7.2 -->

[repo]: https://github.com/theatre-js/theatre
[license-apache]: https://github.com/theatre-js/theatre/blob/6ea82b938ea49609489f6377ded693ccc6ee8f5b/LICENSE
[license-agpl]: https://github.com/theatre-js/theatre/blob/6ea82b938ea49609489f6377ded693ccc6ee8f5b/packages/studio/LICENSE
[dataverse]: https://github.com/theatre-js/theatre/tree/6ea82b938ea49609489f6377ded693ccc6ee8f5b/packages/dataverse
[r3f-readme]: https://github.com/theatre-js/theatre/blob/6ea82b938ea49609489f6377ded693ccc6ee8f5b/packages/r3f/README.md
[npm-core]: https://www.npmjs.com/package/@theatre/core
[npm-studio]: https://www.npmjs.com/package/@theatre/studio
[npm-r3f]: https://www.npmjs.com/package/@theatre/r3f
[docs]: https://www.theatrejs.com/docs/latest
[with-three]: https://www.theatrejs.com/docs/latest/getting-started/with-three-js
[with-r3f]: https://www.theatrejs.com/docs/0.5/getting-started/with-react-three-fiber
[manual-projects]: https://www.theatrejs.com/docs/latest/manual/projects
[manual-sheets]: https://www.theatrejs.com/docs/latest/manual/sheets
[manual-objects]: https://www.theatrejs.com/docs/latest/manual/objects
[manual-sequences]: https://www.theatrejs.com/docs/latest/manual/sequences
[manual-prop-types]: https://www.theatrejs.com/docs/latest/manual/prop-types
[manual-studio]: https://www.theatrejs.com/docs/latest/manual/Studio

<!-- Cross-links into the shared concepts glossary -->

[mobject]: ./concepts.md#mobject-and-the-scene-graph
[vmobject]: ./concepts.md#vmobject-and-vector-geometry
[interpolation]: ./concepts.md#interpolation-and-lerp
[rate-func]: ./concepts.md#rate-function-and-easing
[composition]: ./concepts.md#animation-composition
[execution-models]: ./concepts.md#execution-models
[retained]: ./concepts.md#retained-vs-immediate-mode
[updaters]: ./concepts.md#updaters-and-valuetracker
[rasterization]: ./concepts.md#rasterization
[cpu-gpu]: ./concepts.md#cpu-vector-vs-gpu-vector-rendering
[color-gamma]: ./concepts.md#color-model-and-gamma
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[text-shaping]: ./concepts.md#text-shaping
[readback]: ./concepts.md#frame-capture-and-readback
[codec-muxing]: ./concepts.md#codec-muxing-and-pixel-format
[deterministic]: ./concepts.md#deterministic-frame-sampling
[content-hash]: ./concepts.md#content-hash-caching

<!-- Runnable probes (checked via the ignoreDeadLinks /\.d$/ rule) -->

[bezier-eval]: ./examples/bezier-eval.d
[rate-functions]: ./examples/rate-functions.d
[affine-transform]: ./examples/affine-transform.d
[frame-capture]: ./examples/frame-capture.d
