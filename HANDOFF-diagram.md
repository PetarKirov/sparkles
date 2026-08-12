# Handoff — `apps/diagram`, phase 3 of the ui-app plan

You are picking up **`apps/diagram`**, the draw.io-style board that exists to
stress the `sparkles:ui-app` abstraction. Phases 0–2 are shipped and merged:
`libs/ui-app` is complete, and both `apps/terminal` and `apps/hue` now run on
the host. This app is the third and last phase, and its point is stated in its
own spec: hue is a document viewer and terminal is a cell renderer, so neither
has a camera, a world coordinate space, or an infinite surface. If this app can
be built with **no backend name appearing anywhere under `apps/diagram/`**, the
stack's central claim holds for an application shaped like none of its
predecessors.

## Read these first, in this order

| Document                                                                                   | Why                                                                                     |
| ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| [`docs/specs/diagram/index.md`](docs/specs/diagram/index.md)                               | what the app is, how it sits on the stack, and the **zoom design note** (read that one) |
| [`docs/specs/diagram/feature-requirements.md`](docs/specs/diagram/feature-requirements.md) | the requirement tree: `DIA`, `CAM`, `WLD`, `IXN`, `RND` — with per-row status           |
| [`docs/specs/diagram/PLAN.md`](docs/specs/diagram/PLAN.md)                                 | the two commit series, their order, and the acceptance gates                            |
| [`docs/specs/ui-app/feature-requirements.md`](docs/specs/ui-app/feature-requirements.md)   | the host contract you are building against: `HST1`–`HST19`, `TST1`                      |
| [`AGENTS.md`](AGENTS.md)                                                                   | repo conventions — build, test, commit scopes, the pre-commit hooks that will bite      |

## Where it stands

Branch **`feat/diagram-mvp`**, rebased on `origin/main`, not yet pushed.
`dub test :diagram` = **63+ passed** on ldc2 and dmd.

| Step          | State                                                                              |
| ------------- | ---------------------------------------------------------------------------------- |
| **D1.1–D1.5** | shipped — Series 1 MVP board                                                       |
| **D2.1**      | shipped — context menu, Delete, full Esc dismissal chain (`IXN5`/`IXN6`)           |
| **D2.2**      | shipped — Group/Ungroup (menu + `g`/`u`)                                           |
| **D2.3**      | shipped — label edit over fixed buffer (LineEditState contract)                    |
| **D2.4**      | shipped — orthogonal box-drawing connectors (`RND3`)                               |
| **D2.5**      | shipped — fit-all / minimap / keyboard polish already in D1.4; session sweep added |

`src/` today: `app.d`, `diagram_app.d`, `camera.d`, `world.d`, `systems/input.d`,
`systems/render.d`. Phase 3 Series 1–2 are complete.

## The five things that will save you a day

**1. `WLD4` is why the tests are easy.** Every piece of interaction state — the
tool, the capture owner, the drag, the selection, the menu, the label edit —
lives in `World` alongside the board. A scripted session drives events through
`runAppRecorded` and then inspects **one struct**. Keep it that way; the moment
a system keeps a little state of its own, the sessions stop being assertions
about the app and start being assertions about a system.

**2. Zoom is per-target, and the note explains why.** Read
[Zoom is per-target by design](docs/specs/diagram/index.md#zoom-is-per-target-by-design)
before touching the camera. Short version: magnification is an exponent
(octaves, in cells, both targets) plus a mantissa (how large a cell is _drawn_,
window only). **The cell mapping never reads the mantissa** — that invariant is
what keeps a hit test and a paint in agreement, and it is easy to break by
"helpfully" folding the scale into `worldToScreen`. The first draft got this
wrong in the other direction (it forced the terminal's resolution floor onto the
window); the note keeps the wrong argument next to its correction because it is
an easy mistake to repeat.

**3. Pointer positions arrive in the unit you ask for (`HST18`).** Set
`RunConfig.pointerUnit = PointerUnit.pixels` for the GUI board and use
`Camera.pixelToCell`; leave it at `cells` and the terminal path works unchanged.
`apps/hue`'s `gui.d` is the worked example of the pixels choice.

**4. The host has more than `view`/`handle`.** Before hand-rolling anything,
check whether it is already an errand: `h.clipboard`, `h.pointerShape`,
`h.title`, `h.wakeIn` (`HST16`), `h.spawnDaemon`/`h.wake` (`HST15`),
`h.fontSizePx`/`h.fontSize` (`HST14`), `h.modifiers` (`HST17`), and the
`setup` phase (`HST19`) for anything that must run once after the surface
exists. hue's migration added most of these because it needed them; you
probably do too.

**5. `DIA2` is a manual gate, run it at every step.**

```bash
rg -n "ui_tui|ui_raylib|sparkles\.tui|import raylib" apps/diagram/
```

It must find nothing but its own description in `dub.sdl`. Record the result in
the PR — the check is deliberately not automated, and that decision is recorded
in the ui-app plan.

## Verification

```bash
nix develop -c dub test :diagram                     # and: DC=dmd dub test :diagram
nix develop -c dub build :diagram
nix develop -c dub build :diagram -c no-gui          # the raylib-free closure
nix develop -c dub run :diagram -- --tui
nix develop -c dub run :diagram -- --gui --window-width 120 --window-height 40
```

Every commit must be green on its own, and both compilers must pass — several
things in this repo compile on one and not the other.

## Conventions worth stating explicitly

- **Commit as you go**, one logical change per commit, conventional scope
  (`feat(diagram.camera): …`). Do not batch.
- **Multi-commit PRs.** Single-commit PRs strain CI; land a milestone, not a
  line.
- **Stacked PRs via `gh stack`** when the work splits into dependent series.
- The pre-commit hooks will reformat markdown (prettier) and reject
  non-multiple-of-4 indentation in D (editorconfig-checker), including inside
  continuation lines of a `=>` body. Expect one reformat round per docs commit.

## What is genuinely undecided

These are yours to settle; the spec states the requirement, not the mechanism.

- **How the input system splits a wheel notch** between mantissa and exponent
  near the clamps, and what a pinch ratio maps to on a touchscreen.
- **Whether the minimap scrub uses capture** or re-picks per motion event
  (`IXN1` says a capture owner holds the drag; the minimap is the one case
  where re-picking is also defensible).
- **The grid's zoom-aware density** (`RND4`) — at what magnification the grid
  changes step, and whether it fades or thins.
- **`TST3`'s op-stream half.** hue could not close it (it emits no draw
  operations at all — its frame is cells), and this app _does_ emit them, so it
  is the natural place to finish: one scripted session through `runRecorded` and
  through `runTui` inside a pty, comparing streams. Worth doing here rather than
  inventing a synthetic component for it.
