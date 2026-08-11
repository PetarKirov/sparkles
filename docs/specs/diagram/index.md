# `apps/diagram` — Overview

_**Status:** proposed · **Date:** 2026-08-08 · **Scope:** the planned
`apps/diagram` application: a draw.io-style board — infinite canvas, camera pan,
wheel zoom, minimap, create/select/group/label, orthogonal connectors, context
menu — built on `sparkles:ui-app` with **zero** backend imports._

This is [phase 3 of the ui-app plan](../ui-app/PLAN.md#phase-3): the application
that exists to **stress the abstraction**. hue is a document viewer and terminal
is a cell renderer; neither has a camera, a world coordinate space, or an
infinite surface. If the host, the toolkit and the input vocabulary can express
this app without one backend name appearing under `apps/diagram/`, the stack's
central claim — an application never names a canvas — holds for an application
shaped like none of its authors' previous ones.

## What it is

Freeform boxes on an unbounded world grid. A camera maps world cells to screen
cells; the wheel zooms toward the pointer, smoothly in a window and by octaves
in a terminal (see [Zoom is per-target](#zoom-is-per-target-by-design)); the
middle button (or Space+drag, or the keyboard) pans. A minimap overlays the
corner — content fit, camera frustum, click-to-jump, drag-to-scrub. Boxes are created
with a rect tool, selected by click or marquee, moved (group-aware), labeled
inline, connected with orthogonal box-drawing arrows, and managed through a
right-click context menu. `f` fits all content; `q`/Esc quits.

## How it sits on the stack

| Layer             | What diagram uses it for                                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `sparkles:ui-app` | `runApp` (`HST10`) — one call; backend pick, window/font/theme CLI (`GuiCliFields`), the frame loop, the recording target for every test    |
| `sparkles:ui`     | `DrawOp` as the board's render vocabulary; `Slot`/theme for color; `CaptureState`/`PressState`/`HoverState`/`LineEditState` for interaction |
| `sparkles:input`  | the event vocabulary — pointer, wheel, key press/release levels, capability-gated bindings (`INP16`)                                        |
| `sparkles:base`   | `SmallBuffer` world columns and frame ops — the steady-state `@nogc` path                                                                   |

The board is a **display-list application**, not a widget tree: freeform
world-space content has no box-flow expression, so the render systems emit
`DrawOp`s directly (the host's second render level) and the component's draw
phase ([`HST13`](../ui-app/feature-requirements.md#the-host-contract-hst))
replays them onto whichever canvas the run opened, via the toolkit's immediate
interpreter. Chrome (toolbar, status, menu) rides in the same op stream, after
the board, so z-order is append order.

## Zoom is per-target by design

The first draft made zoom a **discrete power of two on both targets**, arguing
that a terminal cell cannot be subdivided so a fractional scale would round
differently in a window and the two would disagree about what is under the
pointer.

That argument was wrong, and worth writing down because it is an easy one to
repeat. It conflates _the targets must agree_ with _the targets must be
identical_. They are two viewports onto one world: what has to agree is the
**world**, and the hit test **on each target**. Nothing required the window to
inherit the terminal's resolution floor — and a board is exactly the kind of
application where it must not, because a mouse wheel, a trackpad and a
touchscreen all expect continuous zoom, and a staircase of doublings is a poor
experience on every one of them.

**The resolution:** magnification is an exponent and a mantissa, for the same
reason a float is.

| Part                      | Unit                                         | Who moves it    |
| ------------------------- | -------------------------------------------- | --------------- |
| exponent (`zoom`)         | octaves of world cells per cell              | both targets    |
| mantissa (`scalePercent`) | how large a cell is **drawn**, `[100, 200)`% | the window only |

A terminal pins the mantissa at 100 and zooms by octaves, which is all an
indivisible cell can express — claiming finer would be a lie the renderer could
not honour. A window moves the mantissa by a ratio per wheel notch or pinch and
carries into the exponent when it leaves the octave, so what the user sees is
continuous.

**The cell mapping never reads the mantissa.** That is what makes this safe
rather than a compromise: `worldToScreen`/`screenToWorld` stay integer cell
arithmetic, so a hit test and a paint agree exactly on either target. The
mantissa reaches the screen only where sub-cell resolution genuinely exists —
the pixel size the board's canvas is built at (`RaylibCanvas` takes its cell
size per instance, so the board scales while the chrome does not), and the
pixel pointer positions [`HST18`](../ui-app/feature-requirements.md#the-host-contract-hst)
already provides.

One consequence to keep: the mantissa is an integer percentage, so a zoom-in /
zoom-out round trip drifts slightly downward. That is why `IXN4` gives the
keyboard a `0` — a reset is the only thing that restores an exact
magnification, and carrying a rational to avoid it would mean rounding at every
read instead of once per notch.

## Documentation map

| Page                                              | What it covers                                                                                                    |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                          | what the app is · why it exists · how it sits on the stack                                                        |
| [Feature requirements](./feature-requirements.md) | the requirement tree: architecture (`DIA`), camera (`CAM`), world (`WLD`), interaction (`IXN`), rendering (`RND`) |
| [Delivery plan](./PLAN.md)                        | the two commit series, their order, and the acceptance gates                                                      |

## ID scheme

`<AREA><n>`, unique within this tree:

| Area  | Meaning                                                   |
| ----- | --------------------------------------------------------- |
| `DIA` | architecture, package graph, backend isolation            |
| `CAM` | the camera: world↔screen mapping, zoom, pan, minimap math |
| `WLD` | the world: ECS columns, entities, groups, edges, labels   |
| `IXN` | interaction: tools, capture, menus, bindings              |
| `RND` | rendering: the op streams, culling, glyph choices         |

Status scheme identical to the
[`sparkles:ui` scheme](../ui/index.md#status-scheme).
