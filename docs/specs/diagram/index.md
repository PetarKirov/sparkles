---
status: accepted
owner: sparkles:diagram
reviewed: 2026-08-08
---

# `apps/diagram` — Overview

## Abstract

`sparkles:diagram` is a diagram board in the style of draw.io: boxes, groups,
labels and orthogonal arrows on an unbounded canvas, viewed through a camera
that pans and zooms toward the pointer, with a minimap and a right-click menu.
It runs unchanged in a terminal and in a desktop window, and its source names
neither. The board exists to test whether the Sparkles interface stack can
carry an application unlike the ones it was built for. A camera, a world
coordinate space and an infinite surface are things no earlier Sparkles
application needed.

## Introduction

The Sparkles interface stack makes one central promise: an application never
names the surface it draws on. The [toolkit](../ui/index.md), `sparkles:ui`,
reduces an interface to a [display list](../../glossary.md#display-list) of
drawing operations, and the [application host](../ui-app/index.md),
`sparkles:ui-app`, picks a terminal or a window backend at run time and
replays that list onto it. The applications that shaped the stack share a
structure, though. hue is a document viewer and the terminal emulator is a
grid of character [cells](../../glossary.md#cell). Both lay out a bounded page
in screen space, so neither tests the promise on an application whose content
lives somewhere else.

A board does. Its boxes live in an unbounded world, a camera maps that world
onto the screen, and the mapping changes with every pan and zoom. The two
targets also disagree about what zoom can mean. A terminal cell cannot be
subdivided, so a terminal can only zoom by doublings, while a mouse wheel,
trackpad or touchscreen in a window expects continuous zoom. A hit test has to
agree with the paint on both, or a click lands on a box the user cannot see
there. If the host, the toolkit and the input vocabulary can express this
application without a backend name anywhere in its source, the promise holds
beyond the shapes that motivated it.

The board is a display-list application rather than a widget tree. Freeform
world content has no expression in box layout, so the board's render functions
emit drawing operations directly, and the toolbar, status line and menus
follow in the same stream so that z-order is append order. All board state
lives in one value that plain functions read and update, so every behavior is
testable as scripted input against a recording host, with no terminal or
window.

Magnification is split like a floating-point number. An integer exponent, a
power of two, counts world cells per screen cell and is all the
world-to-screen mapping reads. A mantissa scales only how many pixels a cell is
drawn with, and only a window ever moves it. Paint and hit test therefore both
work in whole cells, and a window converts the pointer from pixels to cells at
the drawn size, so the two agree on either target.

These pages specify the application: its package boundary, the camera, the
world model, interaction, rendering, the grid backdrop, and the settings pane.
The toolkit, the host and the input vocabulary have their own specifications,
and the grid backdrop's reusable core belongs to the toolkit. Saving and
loading diagrams, undo of board edits, freehand drawing, diagonal connectors,
resize handles, edge labels and nested groups are out of scope. The board
exercises the stack; it does not compete with full diagram editors.

The sections below explain the [zoom design](#zoom-is-per-target-by-design)
and how the board [sits on the stack](#how-it-sits-on-the-stack).
[Feature requirements](./feature-requirements.md) holds every requirement,
grouped by the prefixes in the [ID scheme](#id-scheme), and lists the full
non-goals. The [delivery plan](./PLAN.md) holds the commit series, their
gates and their progress. The board is the third phase of the
[ui-app plan](../ui-app/PLAN.md#phase-3).

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
| `sparkles:base`   | `SharedBuffer` world columns and frame ops — the steady-state `@nogc` path                                                                  |

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

| Area  | Meaning                                                     |
| ----- | ----------------------------------------------------------- |
| `DIA` | architecture, package graph, backend isolation              |
| `CAM` | the camera: world↔screen mapping, zoom, pan, minimap math   |
| `WLD` | the world: ECS columns, entities, groups, edges, labels     |
| `IXN` | interaction: tools, capture, menus, bindings                |
| `RND` | rendering: the op streams, culling, glyph choices           |
| `GRD` | the grid backdrop: subdivisions, mark kinds, stripe brushes |
| `SET` | the settings pane: the property tree over the live config   |

Status scheme identical to the
[`sparkles:ui` scheme](../ui/index.md#status-scheme).
