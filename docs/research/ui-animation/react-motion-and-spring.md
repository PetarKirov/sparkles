# Motion and React Spring (React)

React's two dominant animation libraries, both of which move per-frame values out of React's render: Motion (formerly Framer Motion) pairs declarative `animate`/`exit` targets with a FLIP layout engine that snapshots the DOM in `getSnapshotBeforeUpdate` and re-measures in a microtask after commit, while React Spring makes every value a spring integrated in its own `requestAnimationFrame` loop and keeps leaving items alive by diffing key sets.

| Field                    | Value                                                                                                                                                                                                                                                                                                                           |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | TypeScript (React 18/19 bindings; Motion's engine, `motion-dom`, is framework-free)                                                                                                                                                                                                                                             |
| License                  | MIT ([Motion `LICENSE.md`][m-license]; [React Spring `LICENSE`][rs-license])                                                                                                                                                                                                                                                    |
| Repository               | [motiondivision/motion][m-repo]: [`packages/motion-dom`][m-dom], [`packages/framer-motion`][m-fm]; [pmndrs/react-spring][rs-repo]: [`packages/core`][rs-core], [`packages/rafz`][rs-rafz], [`packages/animated`][rs-animated]                                                                                                   |
| Documentation            | [motion.dev/docs][m-docs] · [react-spring.dev/docs][rs-docs] (its MDX sources live in the repository under `docs/app/routes`)                                                                                                                                                                                                   |
| Category                 | declarative-target components over mutable, React-external animated values; Motion adds measured layout projection, React Spring is physics-first                                                                                                                                                                               |
| Versions surveyed        | Motion **14.14.0** (`motion` and `framer-motion` packages) at commit `1fa0e14` (2026-11-24); React Spring **11.0.0-beta.3** (`main`) at commit `f005007` (2026-11-26)                                                                                                                                                           |
| Animation state lives in | mutable value objects outside React state — Motion's `MotionValue`s, owned by a per-element `VisualElement` and, for layout, a per-element projection node; React Spring's `SpringValue`s grouped by a `Controller`. Presence state (which keyed children are exiting) lives in React state inside `AnimatePresence` / the hook |

> [!NOTE]
> This page reads both libraries for two questions in [`sparkles:ui`][ui-authoring]: where a layout animation takes its _before_ and _after_ geometry in a framework that re-renders by description (UI-Q9, [PR #775][pr775]), and how a child removed from the description keeps painting until its exit finishes (UI-Q10). The platform primitives Motion compiles down to are on [Web Animations][web-animations] and [CSS Transitions and Animations][css-anim]; the same questions for a retained UI toolkit are on [SwiftUI][swiftui] and [Core Animation][core-animation]. Vocabulary is defined on [Concepts][concepts]. Every source link is pinned to the commits above.

---

## Overview

### What it solves

React re-runs a component function to produce a new element tree, then reconciles and commits it to the DOM. Driving an animation through that cycle — `setState` sixty times a second — re-renders and re-reconciles a subtree per frame, and React has no notion of a removed child that should stay on screen, nor of where an element _was_ before a commit moved it. Both libraries solve the first problem the same way: the animated value is a mutable object that writes to the DOM node directly. Motion's docs say so in one line: _"Changes to the motion value will update the DOM without triggering a React re-render"_ ([Motion values][m-docs-mv]); React Spring's: _"during the process of wrapping the element in the `animated` HOC we attach a `ref` to the element. We are then able to directly change the DOM node imperatively"_ ([`docs.concepts.animated-elements.mdx`][rs-doc-animated]).

They then diverge. Motion attacks the other two problems — layout and exit — with a projection engine and `AnimatePresence`; React Spring stays a value-animation library and provides presence through keyed hooks (`useTransition`, superseded on `main` by `usePresenceList`/`usePresence`).

### Design philosophy

- **Motion: declare the target, the engine picks the means.** _"When values passed to `animate` change, the element will automatically animate to that value"_ ([Animation][m-docs-anim]); physical values default to springs, others to tweens, and values the browser can composite run as Web Animations. Layout changes are animated by measurement, not by declaring geometry: _"Motion performs all layout animations using the CSS `transform` property for the highest possible performance"_ ([Layout animations][m-docs-layout]).
- **React Spring: physics, not curves.** The config docs quote Andy Matuschak: _"Animation APIs parameterized by duration and curve are fundamentally opposed to continuous, fluid interactivity."_ and add _"Springs don’t have a defined curve or a set duration"_ ([`docs.advanced.config.mdx`][rs-doc-why]). Durations exist (`config.duration` + `easing`), but the default is a `tension`/`friction` spring.
- **Both: React renders the description once; a frame loop owns the rest.** Each library has its own batched `requestAnimationFrame` loop that reads, integrates and writes outside React, and calls back into React only at lifecycle boundaries (an exit finished, a leave expired).

---

## How it works

### Motion: `motion.div`, `VisualElement` and `MotionValue`

A `motion.div` renders a plain `div` plus a `VisualElement` (the per-element animation node) created in `useVisualElement`. Its `initial`/`animate`/`exit`/`whileHover` props are declarative targets; on each commit `animationState.animateChanges()` diffs them against the previous render's and starts animations for changed keys ([`use-visual-element.ts`][m-use-ve]):

```tsx
<motion.div
  initial={{ opacity: 0, y: 20 }}
  animate={{ opacity: 1, y: 0 }}
  exit={{ opacity: 0 }}
  transition={{ type: 'spring', stiffness: 300, damping: 30 }}
/>
```

Every animated key is a `MotionValue` — _"used to track the state and velocity of motion values"_ ([`value/index.ts`][m-mv-class]). `set` updates the value and notifies subscribers; the `VisualElement` subscribes and, rather than re-rendering, queues a write and asks its node to be flushed in the frame loop's `render` step (`MotionNode.requestFlush`, [`MotionNode.ts`][m-requestflush]). Only one animation drives a value at a time: `run` calls `this.stop()` first ([`value/index.ts`][m-mv-start]). User-held values come from `useMotionValue` (a `useConstant`, so a stable object across renders; it only forces re-renders in Framer's static canvas mode, [`use-motion-value.ts`][m-use-mv]), `useTransform` (a derived value) and `useSpring` (a value that springs toward its source, [`use-spring.ts`][m-use-spring]).

The frame loop, `frame`, is a batcher over `requestAnimationFrame` with fixed steps `setup → read → resolveKeyframes → preUpdate → update → preRender → render → postRender` ([`order.ts`][m-order]); each step runs every callback queued for it, then the next, so all DOM reads in a frame precede all writes. The loop re-books itself only while some step asked to keep running ([`batcher.ts`][m-batcher]). A second batcher with the same steps runs on `queueMicrotask` ([`microtask.ts`][m-microtask]) — the layout engine uses it to run between React's commit and the browser's paint.

### Motion: the hybrid engine

Each value animation is started by `startValueAnimation` ([`multi-value.ts`][m-multivalue-vel]). A value whose name is in `acceleratedValues` — `opacity`, `clipPath`, `filter`, `transform` — on an `HTMLElement`/`SVGElement`, with no `onUpdate` callback and no custom mixer, is played as a Web Animation; the list's comment explains why colours are excluded: _"WAAPI mixes them in sRGB, but JS animations (and the sampler that estimates a WAAPI value on interrupt) mix them in linear color space, so interrupting one would visibly jump"_ ([`accelerated-values.ts`][m-accel-values]; gate in [`supports/waapi.ts`][m-supports-waapi]). Everything else is a `JSAnimation` stepped in the frame loop. A spring sent to WAAPI is serialised by its own `toString`, which samples the generator into a CSS `linear()` easing ([`spring.ts`][m-spring-tostring]) — the spring is precomputed, so a WAAPI spring must start from a known velocity.

### Motion: layout projection

A `motion` element with `layout` (or `layoutId`) gets a projection node; nodes form a tree mirroring the DOM ancestry of projecting elements. The measurement protocol is driven from a class component, `MeasureLayout`, precisely because it needs React's pre-commit hook — `getSnapshotBeforeUpdate` has no hooks equivalent:

| React phase                                       | Motion call                                                                           | What happens                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| render (user code)                                | nothing                                                                               | `MeasureLayout.render` returns `null`; components never see geometry                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| commit, before DOM mutation                       | `getSnapshotBeforeUpdate` → `projection.willUpdate()` ([source][m-gsbu])              | marks the node and its ancestors layout-dirty, starts a root update, and calls `updateSnapshot()`, which measures the **old** DOM with `getBoundingClientRect` (via `measurePageBox`, [`measure.ts`][m-measure-util]), removes the element's current transform by calculation, and records the in-flight velocity of the running layout animation in the snapshot ([`willUpdate`][m-willupdate], [`updateSnapshot`][m-updatesnapshot]). Skipped unless `layoutDependency` changed or is `undefined`, or presence changed |
| commit, after DOM mutation (`componentDidUpdate`) | `projection.root.didUpdate()` ([source][m-cdu])                                       | schedules `update()` with `microtask.read` — once per root per commit ([`didUpdate`][m-didupdate])                                                                                                                                                                                                                                                                                                                                                                                                                       |
| microtask after commit, before paint              | root `update()` ([source][m-update])                                                  | _write_: `resetTransformStyle` on every dirty node; _read_: `updateLayout` measures the **new** layout (`measure(false)`, [`updateLayout`][m-updatelayout]); _write_: `notifyLayoutUpdate` computes the delta from snapshot to layout and starts the animation ([`notifyLayoutUpdate`][m-notify]); then `flushFrame()` applies the first projected frame synchronously — _"Ideally we could leave this to the following requestAnimationFrame but this seems to leave a flash of incorrectly styled content"_            |
| every following frame                             | `startAnimation` → a `JSAnimation` of a progress value 0→1000 ([source][m-startanim]) | `mixTargetDelta(progress)` interpolates the target box; `calcProjection` turns target vs. layout into a `translate`/`scale` delta per axis; the `render` step writes `transform` built by `buildProjectionTransform`                                                                                                                                                                                                                                                                                                     |

So the element is laid out at its **new** position from the commit on, and painted at its **old** one by an inverse transform that decays to identity — FLIP, with "First" taken inside React's commit before mutation and "Last" in a microtask after it. Because the progress animation has an `onUpdate`, it fails the WAAPI gate and is stepped in JS every frame; the compositor only composites the resulting `transform`.

Two corrections make a scaled box look right. **Children**: a child's projection divides its translation by the accumulated `treeScale` of projecting ancestors and counter-scales, so it is not stretched by its parent's `scale()` ([`buildProjectionTransform`][m-projtransform]) — and a child with `layout` of its own animates relative to its parent's box. **Styles**: `borderRadius` and `boxShadow` are rewritten each frame by _scale correctors_; border radius is expressed as a percentage of the current target box, _"to reduce paints"_ ([`scale-border-radius.ts`][m-borderradius], [`default-scale-correctors.ts`][m-correctors]). The docs state the precondition: _"Motion automatically corrects for scale distortion on these properties, but they must be set on the element via `style`"_ ([Layout animations][m-docs-layout]).

**Shared layout.** `layoutId` registers a node in a per-id stack on the root. When a new element with the same `layoutId` mounts as another unmounts (or is relegated), the new lead's `resumeFrom` is the old one, and `notifyLayoutUpdate` animates from the _old element's snapshot_ to the new element's layout — _"If the original component is still on the page when the new one enters, they will automatically crossfade"_ ([Layout animations][m-docs-layout]; [`switchLayoutId`][m-switchlayoutid]). **`LayoutGroup`** puts nodes in a `nodeGroup`: when any member fires `willUpdate`, every other member snapshots too, so siblings in separate React subtrees that re-render independently still animate together ([`group.ts`][m-group]).

### Motion: `AnimatePresence`

`AnimatePresence` keeps two pieces of React state, `diffedChildren` and `renderedChildren`. On a render where the present children differ, it walks the previously _rendered_ children and splices any whose `key` is no longer present back into the list, right after the child they followed, then re-renders ([`AnimatePresence/index.tsx`][m-ap-diff]). Each child is wrapped in a `PresenceChild` that publishes `isPresent` through `PresenceContext`. A removed child is therefore **the retained React element from its last present render**, still mounted, still a live component — but with frozen props: _"When a component has been removed from the React tree, its props can no longer be updated"_, hence the `custom` prop ([AnimatePresence][m-docs-ap]).

When `isPresent` flips to `false`, the exit feature calls `animationState.setActive("exit", true)` and, when that promise resolves, `onExitComplete(id)` ([`exit.ts`][m-exit]); custom components do the same by hand with `usePresence()`, which returns `[false, safeToRemove]` ([`use-presence.ts`][m-usepresence]). When every exiting key has reported, `AnimatePresence` re-diffs with the exiting children dropped ([source][m-ap-render]). Modes: `sync` (exit and enter together), `wait` (render only the exiting children until they finish), and `popLayout`, where `PopChild` — again a class component using `getSnapshotBeforeUpdate` — measures the exiting element's offset box and injects a `position: absolute` rule so siblings reflow immediately ([`PopChild.tsx`][m-popchild-measure]). An exiting element is also made `inert` ([source][m-popchild-inert]). Layout-projected exits are coordinated with `MeasureLayout`: presence change forces a snapshot, and `relegate()` hands a shared-layout exit to the next stack member.

### React Spring: `SpringValue`, `Controller` and hooks

`useSpring(props)` creates a `Controller` holding one `SpringValue` per key and returns the values (an `animated.div` takes them as `style`). `useSprings` is n controllers, `useTrail` n controllers with staggered delays, `useChain(refs, timeSteps, timeFrame)` starts several `SpringRef`s in sequence ([`useChain.ts`][rs-usechain]). The imperative surface is the same objects: `api.start({ to })`, `SpringValue.set`, `SpringRef`.

`animated(Component)` attaches a `PropsObserver` to the values it was given; a `change` event schedules `raf.write(update)`, and `update` calls the target's `applyAnimatedValues(instance, values)` — on the web target, a direct style write — falling back to `forceUpdate()` only when the native write fails ([`withAnimated.tsx`][rs-withanimated], [`PropsObserver`][rs-propsobserver]).

`SpringValue.advance(dt)` integrates each numeric component with explicit Euler in 1 ms sub-steps ([source][rs-advance]):

```ts
// packages/core/src/SpringValue.ts — spring branch of advance()
const springForce = -config.tension * 0.000001 * (position - to);
const dampingForce = -config.friction * 0.001 * velocity;
const acceleration = (springForce + dampingForce) / config.mass; // pt/ms^2
velocity = velocity + acceleration * step; // pt/ms
position = position + velocity * step;
```

`config` takes `tension`/`friction`/`mass` (presets `default: { tension: 170, friction: 26 }`, `gentle`, `wobbly`, `stiff`, `slow`, `molasses`, [`constants.ts`][rs-presets]), or `frequency`/`damping` from which tension and friction are derived ([`AnimationConfig.ts`][rs-freq]), or `duration` + `easing` (a tween), or `decay` (inertia). Optional `bounce` and `clamp` change what happens at the target.

### React Spring: the frame loop and `Globals`

`rafz` is a tiny scheduler with `update`, `write`, `onStart`, `onFrame`, `onFinish` queues, flushed in that order each tick; `dt` is clamped to 64 ms ([`rafz/src/index.ts`][rs-rafz-update]). `raf.frameLoop` is `'always'` (book native `requestAnimationFrame` while work is pending) or `'demand'` (never book; the host calls `raf.advance()` and is told via `onDemand` when work arrives — how `@react-spring/three` lets react-three-fiber own the render loop, [source][rs-rafz-demand]). The loop stops itself when no task is pending. `Globals.assign` sets process-wide knobs: `now`, `requestAnimationFrame`, `frameLoop`, `skipAnimation`, `onDemand` ([`globals.ts`][rs-globals]). With `skipAnimation`, `SpringValue._start` jumps to the goal and _"avoids the frameloop"_ ([source][rs-skip]).

### React Spring: presence

`useTransition(items, { keys, from, enter, update, leave })` gives each key a `TransitionState` with a `Controller` and a phase from `TransitionPhase` — `mount`, `enter`, `update`, `leave` ([`TransitionPhase.ts`][rs-phase]). Each render maps old transitions to new indices by key, inserts new keys with phase `mount`, and **re-inserts removed keys next to their old neighbour** while `leave` is configured ([`useTransition.tsx`][rs-ut-reuse]); the phase machine moves `mount→enter`, a present key to `update`, a missing key to `leave`, and a leaving key that reappears back to `enter` ([source][rs-ut-phase]). When a leaving controller goes idle, the transition is marked `expired` and a `forceUpdate()` re-renders without it ([source][rs-ut-expire]). The leaving item is retained as **data** (`t.item`), and the user's render function is called again for it each render with the leave springs.

On `main`, both are deprecated — _"`useTransition` and `<Transition>` are deprecated. Use `usePresenceList` for lists and `usePresence` for a single element shown by a boolean"_ ([`docs.components.use-transition.mdx`][rs-doc-ut]) — and the diff is now a separate pure function, `diffPresence(prev, items, keys, opts)`, returning the next entry list, a per-key change map (`mount | enter | update | leave`) and the keys held back by `mode: 'wait'` ([`presenceDiff.ts`][rs-presencediff]).

---

## Analysis

### Where animation state lives

Both libraries put animation state in mutable objects that React does not see: Motion's `MotionValue` (current value, previous frame value, timestamps for velocity, the one driving animation) owned by a `VisualElement`, plus — for layout — a projection node holding `snapshot`, `layout`, `target`, deltas and `treeScale`; React Spring's `SpringValue` with an `Animation` record (`fromValues`, `toValues`, per-component `AnimatedValue` nodes carrying `lastPosition`, `lastVelocity`, `elapsedTime`). These objects are identity-keyed by the React fiber that created them (`useConstant`/`useRef`). Presence state — which keys are exiting and whether they have finished — is ordinary React state inside `AnimatePresence` (`renderedChildren`, `exitComplete`) or the presence hook (`TransitionState[]` in a ref).

### Declaring an animation

**Motion** is declarative and implicit at the component level: `animate={…}` is a target, and changing it between renders animates; `initial`, `exit` and gesture props (`whileHover`, `whileInView`) are additional targets selected by state; `variants` name targets and propagate through the tree. Layout is implicit in the strongest sense — `layout` declares no target at all, and any commit that moves the box animates. The imperative layer is `MotionValue.set`, `animate(value, target, transition)` and `useAnimate`. **React Spring** is declarative-target too (`useSpring({ opacity: on ? 1 : 0 })` retargets when the prop changes), but its idiom leans imperative: `useSpring(() => ({…}))` returns an `api` and animations start from event handlers via `api.start`, never touching render. Neither library has a CSS-transition-style "animate whatever changed" for arbitrary props; only keys named in a target animate.

### Time and the clock

Both own a `requestAnimationFrame` loop and stamp a frame with one timestamp. Motion's `time.now()` returns the frame timestamp while a frame is processing and otherwise caches `performance.now()` for the rest of the synchronous task (_"Ensures that time measurements remain consistent within a synchronous context"_, [`sync-time.ts`][m-synctime]); `MotionGlobalConfig.useManualTiming` replaces wall time with a caller-set `frameData.timestamp`, and then _"every animation runs in JS where processFrame can drive it"_ because WAAPI animations run on the browser's clock ([`supports/waapi.ts`][m-supports-waapi], [`global-config.ts`][m-globalconfig]). WAAPI-accelerated values therefore run on the document timeline, not Motion's — a second clock that Motion samples on interrupt. Scroll-linked values (`useScroll`) are `MotionValue`s fed by scroll events, and a WAAPI-played animation can be attached to a native `ScrollTimeline` instead of the document timeline ([`NativeAnimation.attachTimeline`][m-attachtimeline]). React Spring's `rafz` uses `performance.now()` (replaceable through `Globals.assign({ now })`) and integrates by `dt`, clamped to 64 ms per frame; in `'demand'` mode the host owns the clock entirely.

### Interruption and retargeting

**Motion** preserves velocity on interruption for value animations: a new animation reads `value.getVelocity()` (per second, from the last two frames, zero if the last update is older than 30 ms) unless the transition supplies `velocity` ([`multi-value.ts`][m-multivalue-vel], [`getVelocity`][m-getvelocity]), and a running JS spring can be `retarget`ed in place, keeping its resolved physics and taking the new velocity as its initial condition ([`spring.ts`][m-spring-retarget]). Duration-based springs deliberately drop it: _"A duration spring must end exactly at its duration, and it's settled from rest by then. Inherited velocity could leave it still moving, so it starts from rest"_ ([source][m-spring-inherit]). A value playing on WAAPI cannot be retargeted in place; Motion estimates its current value with a JS sampler on interrupt (the reason colours are kept off WAAPI, [`accelerated-values.ts`][m-accel-values]) and starts a new animation from there. **Layout animations** carry velocity across commits: `updateSnapshot` stores the running animation's per-edge velocity (and the `x`/`y` motion values' velocity) _in the snapshot_, and the next layout animation's springs start from it ([`updateSnapshot`][m-updatesnapshot], [`setAnimationOrigin`][m-setorigin]). The snapshot records both the measured (visual) box and a layout box with the element's own transform removed by calculation ([`measure`][m-measure]), so an interrupted layout animation can start from where the element visibly is.

**React Spring** keeps velocity by construction: each `AnimatedValue` holds `lastVelocity`, which `reset()` clears only if the previous animation had finished (`if (done) this.lastVelocity = null`, [`AnimatedValue.ts`][rs-animatedvalue-reset]), so a mid-flight goal change continues integrating from the current position and velocity. An explicit `config.velocity` is zeroed on each new `to`/`from` unless `decay` is set, to avoid wiping fling momentum ([source][rs-velocity-reset]). A mid-flight retarget fires `onStart` again and not `onRest`. Neither library composes animations additively on one value; one animation owns a value at a time.

### Curves and springs

**Motion** defaults to springs for physical values (`x`, `scale`, layout) and tweens for others (_"Physical properties like `x` or `scale` are animated with spring physics"_, [Animation][m-docs-anim]). Its spring is solved analytically (under-, critically and over-damped closed forms, [`spring.ts`][m-spring-file]) and accepts two parametrisations: `stiffness`/`damping`/`mass`, or `duration`/`visualDuration` + `bounce`, where `bounce` maps to a damping ratio _"as SwiftUI does"_ ([source][m-spring-bounce]); explicit physics overrides duration/bounce. Tweens take `duration` + `ease` (cubic béziers, named curves, or `linear()` on WAAPI), and `inertia` handles flings. **React Spring** integrates numerically (1 ms explicit Euler) with `tension`/`friction`/`mass` or `frequency`/`damping`, settling when `|v|` falls below `restVelocity` and `|to − x|` below `precision`; `duration` switches the value to an eased tween; `decay` decelerates exponentially. Neither exposes the curve of a spring ahead of time except Motion's WAAPI path, which bakes it into `linear()`.

### Layout animation

**Motion**: FLIP via transform, user-invisible. _First_ is measured in React's commit phase **before DOM mutation** (`getSnapshotBeforeUpdate` → `willUpdate` → `updateSnapshot`); _Last_ in a **microtask after `componentDidUpdate`** (`didUpdate` → `microtask.read` → `update()` → `updateLayout`), after transforms are reset so the true layout box is read; _Invert/Play_ runs as a **JS animation in Motion's frame loop**, written as `transform` in the `render` step and composited by the browser ([table above](#motion-layout-projection)). It needs the previous geometry, and gets it by measuring the DOM synchronously before React mutates it — not from a retained layout store; a second, forced-layout read follows after mutation, batched across all dirty nodes (all resets, then all reads, then all writes). Shared-element transitions (`layoutId`) take _First_ from a different element's snapshot. The cost model is a forced synchronous layout per commit that touches a layout node, and a main-thread write per frame for the duration.

**React Spring** has no layout animation. Geometry can be animated only as ordinary values (`width`, `height`, `x`), typically after measuring with `useResize`/a `ResizeObserver` ([`useResize.ts`][rs-useresize]) — the user brings both endpoints, and runs the measurement in user code.

### Enter and exit

**Motion** retains the removed **React element** (its last-present description), keeps it mounted under a `PresenceChild` with `isPresent: false`, runs its `exit` target, and removes it when every `motion`/`usePresence` descendant has called back; the component still executes on re-render but cannot receive new props. Enter is `initial` → `animate` on mount; `AnimatePresence initial={false}` suppresses it for first-render children. A child that returns before its exit finishes is re-entered with the same component instance. **React Spring** retains the removed **data item** with its key and controller and re-invokes the user's render function for it each render with `leave` springs, until the controller is idle; `diffPresence` makes this a pure function of `(previous entries, items, keys)` — a set difference over keys, the leaving entries spliced after their old neighbour. Both libraries require stable keys for this, and both offer `wait`.

### Scheduling, reduced motion and testing

Both loops run only while work is pending: Motion's batcher books the next frame only if a step was flagged `keepAlive` ([`batcher.ts`][m-batcher]); `rafz` stops when `pendingCount` reaches zero. **Reduced motion** differs in scope. Motion's `MotionConfig reducedMotion="user" | "always" | "never"` sets `VisualElement.shouldReduceMotion` from a `matchMedia` listener ([`VisualElement.ts`][m-ve-reduced], [`use-reduced-motion-config.ts`][m-rm-config]), and then only _positional_ keys — `width`, `height`, `top`/`left`/`right`/`bottom` and transforms ([`keys-position.ts`][m-positional]) — are made instant (`{ type: false }`, [`visual-element-target.ts`][m-rm-apply]); _"while preserving the animation of other values like opacity and backgroundColor"_ ([Accessibility][m-docs-a11y]). `useReducedMotion()` exposes the raw preference. React Spring's `useReducedMotion()` subscribes to `(prefers-reduced-motion)` and sets the global `skipAnimation`, which makes **every** animation jump to its goal ([`useReducedMotion.ts`][rs-usereduced]). **Testing**: Motion's `MotionGlobalConfig` has `skipAnimations`, `instantAnimations` and `useManualTiming` (drive frames by hand) ([`global-config.ts`][m-globalconfig]); React Spring's testing guide prescribes `Globals.assign({ skipAnimation: true })` ([`docs.guides.testing.mdx`][rs-doc-testing]), and its own suite uses a vendored `mock-raf` ([`packages/mock-raf`][rs-mockraf]) plus `frameLoop: 'demand'` and `raf.advance()`.

### Lessons for sparkles:ui

- **Motion's FLIP needs a pre-mutation hook that sparkles does not need.** Motion reaches into `getSnapshotBeforeUpdate` because the DOM is the only record of last frame's geometry. The `sparkles:ui` element store already holds last frame's committed rects keyed by identity, so _First_ is a read, not a measurement, and _Last_ is this frame's layout output; the inversion belongs after layout, before paint (UI-Q9). No component code needs the geometry.
- **Projection is a post-layout paint transform, and it has cost centres to copy deliberately:** child counter-scaling by accumulated `treeScale`, per-property scale correctors (border radius as a percentage of the animated box, shadows), and velocity stored _with the snapshot_ so an interrupted layout animation keeps its momentum. All of this is pure arithmetic over two rects and a velocity — expressible as `@nogc` store data.
- **Two exit models, and React Spring's fits better.** Motion keeps a stale description alive (frozen props, still-running component); React Spring keeps the _data_ and re-runs the user's builder with a `leave` phase. The latter maps onto a store-driven closing state (UI-Q10): the store remembers `(key, phase, progress)` for an identity that left the set, and the component is asked to build it once more in its closing phase — `diffPresence` is literally the identity-set difference sparkles already computes for lifecycle.
- **Velocity on retarget is cheap when the integrator owns `lastVelocity`.** React Spring's per-node `lastVelocity`, cleared only when an animation finished, is the minimal state; Motion's analytic springs need velocity estimated from two samples and must special-case precomputed (WAAPI) curves.
- **Reduced motion should be per-property-class, not global.** Motion's split (disable positional motion, keep opacity/colour) is more useful than React Spring's global skip; a deterministic clock for tests (`useManualTiming`, `frameLoop: 'demand'` + `advance`) is the same idea as a host-owned frame clock.

---

## Strengths

- Both move per-frame work off React's render entirely; the description is rebuilt only when targets change.
- Motion's layout animation needs no geometry from the author, handles nesting (scale correction), shared elements (`layoutId`) and cross-subtree coordination (`LayoutGroup`), and preserves velocity across interrupted layout changes.
- Motion's hybrid engine offloads `transform`/`opacity`/`filter`/`clipPath` to WAAPI and the compositor when nothing needs per-frame JS.
- React Spring's physics is simple, stateful and always interruptible with momentum; `frameLoop: 'demand'` lets another renderer own the clock.
- React Spring's `diffPresence` is a pure, testable key-set diff.

## Weaknesses

- Motion's layout engine depends on class-component lifecycles and forced synchronous layout reads in every relevant commit; it is tightly coupled to React's commit ordering and to the DOM as the geometry store.
- Layout animations are JS-stepped transforms (the progress value has an `onUpdate`), so they stall with the main thread even though they only write `transform`.
- `AnimatePresence` children cannot receive new props while exiting (`custom` is the workaround); exits require stable keys on _direct_ children.
- React Spring has no layout/FLIP support; geometry animation is user-measured.
- React Spring's `skipAnimation` is a process-wide flag — reduced motion and test mode are all-or-nothing.

---

## Key design decisions and trade-offs

| Decision                                                                              | Rationale                                                                 | Trade-off                                                                                                    |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Animated values are mutable objects that write the DOM directly                       | avoids a React render per frame                                           | values are invisible to React; reading them in render is a stale snapshot                                    |
| Motion: snapshot in `getSnapshotBeforeUpdate`, re-measure in a microtask after commit | the DOM before mutation is the only place last frame's geometry exists    | a forced layout per commit; class-component dependency; ordering coupled to React's commit                   |
| Motion: animate layout as an inverse `transform`, with scale correctors               | `transform` is compositor-cheap; no relayout per frame                    | distortion of children and radii must be corrected per frame in JS; corrected styles must be set via `style` |
| Motion: WAAPI for accelerated values, JS for the rest                                 | off-main-thread playback when possible                                    | two clocks; springs on WAAPI are precomputed `linear()` curves and must be sampled on interrupt              |
| Motion: retain the removed React element until exit completes                         | the exiting subtree keeps its components, refs and effects                | frozen props; exit coordination through context callbacks                                                    |
| React Spring: physics-first, Euler-integrated springs                                 | continuous retargeting with momentum, no duration to reconcile            | no closed form, so no compositor offload or precomputed curve                                                |
| React Spring: retain the data item, re-run the render function                        | the leaving element is still described by user code, with a `leave` phase | user code must handle being called for an item no longer in `items`                                          |
| React Spring: global `Globals` (`skipAnimation`, `frameLoop`)                         | one switch for tests, reduced motion and host-driven loops                | process-wide; cannot reduce motion per subtree                                                               |

---

## Sources

- Motion source at [`1fa0e14`][m-repo]: [`MeasureLayout.tsx`][m-measurelayout], [`create-projection-node.ts`][m-projnode], [`styles/transform.ts`][m-projtransform], [`scale-border-radius.ts`][m-borderradius], [`group.ts`][m-group], [`frameloop/`][m-frameloop], [`value/index.ts`][m-mv-class], [`generators/spring.ts`][m-spring-file], [`waapi/supports/waapi.ts`][m-supports-waapi], [`AnimatePresence/`][m-ap-dir].
- Motion documentation: [Layout animations][m-docs-layout], [AnimatePresence][m-docs-ap], [Motion values][m-docs-mv], [Animation][m-docs-anim], [Accessibility][m-docs-a11y]; [_Framer Motion is now independent, introducing Motion_][m-blog] (2024-11-12).
- React Spring source at [`f005007`][rs-repo]: [`SpringValue.ts`][rs-springvalue], [`AnimatedValue.ts`][rs-animatedvalue-reset], [`rafz`][rs-rafz-update], [`globals.ts`][rs-globals], [`useTransition.tsx`][rs-ut-reuse], [`presenceDiff.ts`][rs-presencediff], [`withAnimated.tsx`][rs-withanimated].
- React Spring documentation: [react-spring.dev/docs][rs-docs] and its MDX sources ([config][rs-doc-why], [animated elements][rs-doc-animated], [`useTransition`][rs-doc-ut], [testing][rs-doc-testing]).
- Related pages: [Web Animations][web-animations], [CSS Transitions and Animations][css-anim], [SwiftUI][swiftui], [Core Animation][core-animation], [Svelte][svelte], [Concepts][concepts].

<!-- References -->

[pr775]: https://github.com/PetarKirov/sparkles/pull/775
[ui-authoring]: ../ui-authoring/index.md
[web-animations]: ./web-animations.md
[css-anim]: ./css-transitions-and-animations.md
[swiftui]: ./swiftui.md
[core-animation]: ./core-animation.md
[concepts]: ./concepts.md
[svelte]: ./svelte.md
[m-repo]: https://github.com/motiondivision/motion/tree/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc
[m-license]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/LICENSE.md
[m-dom]: https://github.com/motiondivision/motion/tree/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom
[m-fm]: https://github.com/motiondivision/motion/tree/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion
[m-docs]: https://motion.dev/docs
[m-docs-mv]: https://motion.dev/docs/react-motion-value
[m-docs-anim]: https://motion.dev/docs/react-animation
[m-docs-layout]: https://motion.dev/docs/react-layout-animations
[m-docs-ap]: https://motion.dev/docs/react-animate-presence
[m-docs-a11y]: https://motion.dev/docs/react-accessibility
[m-blog]: https://motion.dev/blog/framer-motion-is-now-independent-introducing-motion
[m-use-ve]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/motion/utils/use-visual-element.ts#L141-L187
[m-mv-class]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/value/index.ts#L89-L94
[m-mv-start]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/value/index.ts#L532-L566
[m-getvelocity]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/value/index.ts#L492-L519
[m-requestflush]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/node/MotionNode.ts#L408-L418
[m-use-mv]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/value/use-motion-value.ts#L25-L39
[m-use-spring]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/value/use-spring.ts#L33-L54
[m-frameloop]: https://github.com/motiondivision/motion/tree/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/frameloop
[m-order]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/frameloop/order.ts#L3-L12
[m-batcher]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/frameloop/batcher.ts#L46-L87
[m-microtask]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/frameloop/microtask.ts#L1-L9
[m-synctime]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/frameloop/sync-time.ts#L10-L34
[m-globalconfig]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-utils/src/global-config.ts#L1-L7
[m-multivalue-vel]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/animate/multi-value.ts#L426-L429
[m-accel-values]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/waapi/utils/accelerated-values.ts#L1-L13
[m-supports-waapi]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/waapi/supports/waapi.ts#L23-L46
[m-spring-file]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/generators/spring.ts
[m-spring-bounce]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/generators/spring.ts#L42-L50
[m-spring-inherit]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/generators/spring.ts#L305-L312
[m-spring-retarget]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/generators/spring.ts#L462-L476
[m-spring-tostring]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/generators/spring.ts#L496-L510
[m-measurelayout]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/motion/features/layout/MeasureLayout.tsx
[m-gsbu]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/motion/features/layout/MeasureLayout.tsx#L148-L200
[m-cdu]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/motion/features/layout/MeasureLayout.tsx#L202-L214
[m-switchlayoutid]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/motion/features/layout/MeasureLayout.tsx#L54-L106
[m-projnode]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts
[m-willupdate]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts#L928-L999
[m-update]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts#L1007-L1090
[m-didupdate]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts#L1094-L1099
[m-updatesnapshot]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts#L1203-L1257
[m-updatelayout]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts#L1259-L1298
[m-setorigin]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts#L1981-L2100
[m-startanim]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts#L2230-L2260
[m-notify]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts#L2888-L2960
[m-measure-util]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/utils/measure.ts#L8-L31
[m-projtransform]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/styles/transform.ts#L5-L60
[m-borderradius]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/styles/scale-border-radius.ts#L10-L42
[m-correctors]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/styles/default-scale-correctors.ts#L6-L15
[m-group]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/group.ts#L9-L40
[m-ap-dir]: https://github.com/motiondivision/motion/tree/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/components/AnimatePresence
[m-ap-diff]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/components/AnimatePresence/index.tsx#L88-L189
[m-ap-render]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/components/AnimatePresence/index.tsx#L208-L274
[m-usepresence]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/components/AnimatePresence/use-presence.ts
[m-popchild-measure]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/components/AnimatePresence/PopChild.tsx#L82-L120
[m-popchild-inert]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/components/AnimatePresence/PopChild.tsx#L172-L212
[m-exit]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/motion/features/animation/exit.ts#L14-L75
[m-ve-reduced]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/render/VisualElement.ts#L433-L443
[m-rm-config]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/framer-motion/src/utils/reduced-motion/use-reduced-motion-config.ts#L7-L18
[m-positional]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/render/utils/keys-position.ts#L3-L12
[m-attachtimeline]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/NativeAnimation.ts#L262-L280
[m-measure]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/projection/node/create-projection-node.ts#L1358-L1381
[m-rm-apply]: https://github.com/motiondivision/motion/blob/1fa0e141f7b3f0a4eea258d5debc7dfbe5af6ffc/packages/motion-dom/src/animation/interfaces/visual-element-target.ts#L154-L169
[rs-repo]: https://github.com/pmndrs/react-spring/tree/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd
[rs-license]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/LICENSE
[rs-core]: https://github.com/pmndrs/react-spring/tree/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core
[rs-rafz]: https://github.com/pmndrs/react-spring/tree/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/rafz
[rs-animated]: https://github.com/pmndrs/react-spring/tree/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/animated
[rs-docs]: https://www.react-spring.dev/docs
[rs-doc-why]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/docs/app/routes/docs.advanced.config.mdx#L205-L212
[rs-doc-animated]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/docs/app/routes/docs.concepts.animated-elements.mdx#L325-L331
[rs-doc-ut]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/docs/app/routes/docs.components.use-transition.mdx#L20-L25
[rs-doc-testing]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/docs/app/routes/docs.guides.testing.mdx#L130-L136
[rs-springvalue]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/SpringValue.ts
[rs-advance]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/SpringValue.ts#L291-L342
[rs-velocity-reset]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/SpringValue.ts#L710-L719
[rs-skip]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/SpringValue.ts#L1011-L1012
[rs-animatedvalue-reset]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/animated/src/AnimatedValue.ts#L50-L60
[rs-presets]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/constants.ts
[rs-freq]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/AnimationConfig.ts#L191-L198
[rs-rafz-update]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/rafz/src/index.ts#L162-L201
[rs-rafz-demand]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/rafz/src/index.ts#L99-L160
[rs-globals]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/shared/src/globals.ts#L39-L78
[rs-withanimated]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/animated/src/withAnimated.tsx#L48-L68
[rs-propsobserver]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/animated/src/withAnimated.tsx#L104-L114
[rs-usechain]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/hooks/useChain.ts#L17-L50
[rs-phase]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/TransitionPhase.ts#L1-L10
[rs-ut-reuse]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/hooks/useTransition.tsx#L189-L231
[rs-ut-phase]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/hooks/useTransition.tsx#L256-L282
[rs-ut-expire]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/hooks/useTransition.tsx#L349-L381
[rs-presencediff]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/presenceDiff.ts#L32-L92
[rs-useresize]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/core/src/hooks/useResize.ts
[rs-usereduced]: https://github.com/pmndrs/react-spring/blob/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/shared/src/hooks/useReducedMotion.ts#L13-L27
[rs-mockraf]: https://github.com/pmndrs/react-spring/tree/f005007bef2c67e95abc6b2f03e3d5a9e2b3bdcd/packages/mock-raf
