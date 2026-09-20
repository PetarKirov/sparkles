# Text Sizing Delivery Plan

This page owns delivery order and progress, not normative behavior. The owning
contract is [Text Sizing](./text-sizing.md) (`TSZ1` through `TSZ16`); independent
oracles, scenarios, and the single evidence ledger belong to
[Text Sizing Testing](./text-sizing-testing.md). Base wire/text obligations belong
to [Base Text Sizing](../base/text/sizing.md) (`TSW1` through `TSW6`). These companion
documents record the agreement; their existence is not implementation evidence.

The [research proposal](../../research/tui-libraries/text-sizing/sparkles-proposal.md)
and [source baseline](../../research/tui-libraries/text-sizing/sparkles-baseline.md)
are inputs, not authority. Follow [specification guidance](../../guidelines/spec-docs.md).
No sizing feature is implemented or verified by this plan. No new commits are
claimed. Paths below are repository-relative unless linked; new files are labeled.

## Scope and Decisions

The user accepted producer-first delivery, not producer-only scope. Completion
includes every text-bearing widget, editors, tables, trees, gutters, virtualization,
host integration, GUI, TUI, static ANSI, both HTML paths, hue, and receiving VT.
Receiver implementation is deferred to M6, not removed from acceptance.
Bidi, general proportional shaping, and ligatures are separate work.

Carry these accepted choices into the owning contracts; do not reopen them through
an implementation shortcut or copy research defaults over them:

- Exact portable rational sizes belong in the first release, not an integer-only tier.
- Sizes are absolute inherited values, with an explicit normal-size reset.
- Independent graphemes are the default; packing requires explicit author opt-in.
  On capable terminals, non-ASCII text requires explicit per-grapheme `w` width
  declarations, including at normal size. These preserve independent graphemes;
  they are not opt-in multi-grapheme packing. Without width-protocol support,
  default Unicode output has a weaker fallback contract: M0 must declare how
  client/terminal width mismatches are handled, not promise exact parity.
- Measurement, paint, source mapping, selection, and input share cell geometry.
- Unsupported rendering keeps the requested footprint and uses normal-size ink;
  a packed author supplies a fitting fallback. It does not silently collapse layout.
- Reuse `Alignment.start/center/end`; defaults are line alignment `end`, `inkY`
  `end`, and `inkX` `start`. Move the enum unconditionally to UI geometry with a
  public re-export from widget, so style/canvas/wrap need not import widget.
  This is intra-UI layering, not a need for base or tui to import the enum.
  Initialize line-alignment and `inkY` fields explicitly to `Alignment.end`;
  the enum's zero value remains `start`.
- Omit partially clipped TUI objects and exclude their pointer hits; GUI uses
  scissoring. Test raster edges, not merely display-list clip commands.
- Entering editing in a packed run expands that specific run, then lays out, then
  places the caret. It stays expanded for the explicit session, including when the
  caret crosses a run boundary. Repacking is attempted on explicit commit or leaving
  edit mode; invalid fit/fallback keeps it expanded pending validation, without
  truncation or stale fallback. Focus transitions need an explicit failure trace.
- Up/down follows visual lines, not covered continuation rows or source-line counts.
- Hue defaults to capability-sensitive `AUTO`; explicit on preserves unsupported
  footprints, while off selects normal size. Capability is not a terminal-name guess.
- Ghostty work is upstream-first, with a maintained fork if needed, covering desktop
  and Android. Producer milestones do not wait for receiver availability.

The bounded numeric domain, rational canonicalization, final rounding rules, and
numeric resource/performance budgets remain M0 decisions. No limit or rounding
formula in an API sketch is accepted by this plan.

## Ownership and Inventory

Package arrows mean imports: UI and producer adapters depend on base text
mechanisms; base never depends on UI. Host and application policy consumes UI
geometry. Terminal-view consumes Ghostty state; it does not add a competing OSC
parser. Delivery arrows below are gates, not additional package dependencies.

| Owner                  | Existing files to inspect/change in its slice                                                                                                                                   |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Base semantics         | `libs/base/src/sparkles/base/text/{ansi,grapheme,width,wrap}.d`; `libs/core-cli/src/sparkles/core_cli/term_unstyle.d`                                                           |
| UI geometry/style      | `libs/ui/src/sparkles/ui/{geometry,style,theme,widget,wrap,layout,canvas,display_list,state}.d`                                                                                 |
| Host                   | `libs/ui-app/src/sparkles/ui_app/{run_app,host,record,gui_loop,tui_loop}.d`                                                                                                     |
| Producers              | `libs/ui-raylib/src/sparkles/ui_raylib/raylib_canvas.d`; `libs/raylib-text/src/sparkles/raylib_text/{draw,font_set}.d`; `libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d`         |
| Retained/static output | `libs/tui/src/sparkles/tui/{cell,render}.d`; `libs/ui/src/sparkles/ui/interp/{immediate,cells,html,html_semantic}.d`                                                            |
| Application consumers  | `libs/source-view/src/sparkles/source_view/{code,markdown}.d`; `libs/twoslash/src/sparkles/twoslash/render_widgets.d`; `apps/hue/src/{settings,cli,viewer_model,app,gui,tui}.d` |
| Receiver               | `libs/ghostty/src/sparkles/ghostty/c.c`; `libs/terminal-view/src/sparkles/terminal_view/{component,core,cell_paint}.d`; `apps/hue/src/{gui_ansi,ansi_model}.d`                  |
| Dependency builds      | `flake.nix`, `flake.lock`, `nix/packages/libghostty-vt.nix`, `nix/packages/android/libghostty-vt.nix`                                                                           |

The current `WidgetKind` has text, rich, and glyph leaves, not an implemented
editor. `TextStyle`, `Visual`, and `Ink` (in
`libs/ui/src/sparkles/ui/canvas.d`) already transport percentage
`fontScale`; HTML and twoslash consume it. `CellMeasure` and `Frame` are existing
integration points, not evidence of resolved sized-run support.

[`cellsOf`](../../../libs/ui/src/sparkles/ui/geometry.d) currently counts UTF-8
lead bytes, one column per codepoint; its module documentation explicitly defers
grapheme width to hue's [DEF7](../hue/feature-requirements.md) and
[FNT6](../hue/gui.md#font-fnt). Reconcile those older contracts as a blocking
prerequisite, reusing base `grapheme.d`/`width.d`, not adding a separate shaping
dependency. This applies at normal size as well as every requested size.
Also reconcile [LAY5](./layout.md)'s injected grapheme-correct measurement and
[MIG5](./migration.md)'s shared width-authority migration with this delivery gate.

| Prerequisite                                       | Inventory and closure gate                                                                                                                                                                                                           |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Grapheme geometry (`DEF7`/`FNT6`)                  | M0 inventories `cellsOf` callers and independent codepoint/byte width and inverse-position walks, including app-owned passes; M2a0 closes the shared base-grapheme policy before layout/selection can claim correctness at any size. |
| Editor E0/E1                                       | M0 inventories input/editor consumers; editor delivery blocks M2d and full `TSZ9`/`TSZ11` closure.                                                                                                                                   |
| Width declarations and unsupported mismatch policy | M0 distinguishes per-grapheme `w` from packing, records capability requirements and the weaker unsupported Unicode fallback; M1/M4 verify the wire and producer behavior.                                                            |

For `TSZ11`, M0 records every text producer and every independent width/row walk;
M2/M5 close this inventory with tests, not a claim that primitive support is enough:

- Leaf text/rich/glyph nodes, wrapping, inline links, decorations, synthetic text.
- `components/{header,box,chrome,dock,lantern_view,inspector,property_view}.d`:
  labels, menus, tabs, prompts, tooltips, and property values built from leaves.
- `components/{meter,progress,tasklist,live,demo}.d`: dynamic/status text.
- `components/table/{layout,render,widgets,grid}.d`: measurement, cell/header
  heights, alignment, borders, row indexing, and writer as well as widget output.
- `components/{tree,tree_model,tree_view,tree_widget}.d`: indentation, expanders,
  labels, selection, and variable-height visible-row indexing.
- `components/{gutter,scroll_view}.d`: coverage, scroll anchors, clipping, and
  virtualization; distinguish source rows, visual lines, and covered cell rows.
- Source-view code/markdown, twoslash overlays, gallery pages, and hue's gutter
  prepass and final layout; include app-owned measurement passes.
- Single-line inputs and multiline editors: [editor E0/E1](./editor.md) are
  prerequisites, not present APIs. The proposed `components/editor.d` remains a
  new-file target owned by that work. Property-view's `needs EDT` is not an editor.

## Milestone Tracker

Every substep below is not started, using the [UI inventory status scheme](./index.md).
Each is a PR-sized delivery unit; split further
by widget family or adapter when necessary, preserving independently green builds.
Write a failing test locally, then land its implementation with it, never an
intentionally red milestone. Partial producer delivery is not full `TSZ11` closure.

| Stage                                   | Prerequisites                                                | Obligations exercised                         | Status      |
| --------------------------------------- | ------------------------------------------------------------ | --------------------------------------------- | ----------- |
| M0 Contract and spikes                  | Source inventory and accepted user choices                   | All TSZ/TSW contracts; first-slice oracles    | not started |
| M1 Base semantics and demos             | M0 numeric/wire decisions                                    | TSW1-TSW6; TSZ1, TSZ3, TSZ5, TSZ10 boundaries | not started |
| M2 Shared geometry and widgets          | M1; DEF7/FNT6 closure in M2a0; editor E0/E1 for edit substep | TSZ1-TSZ11                                    | not started |
| M3 Raylib and HTML producers            | M2 geometry; M0 raster budgets                               | TSZ4-TSZ8, TSZ10, TSZ11, TSZ14                | not started |
| M4 Retained TUI and capability          | M2; M1 safe emission; accepted M0f evidence mechanism        | TSZ3-TSZ8, TSZ10-TSZ13                        | not started |
| M5 Source-view, hue, all-widget closure | M2-M4; editor prerequisites                                  | TSZ1-TSZ15                                    | not started |
| M6 Receiver and final acceptance        | M0 receiver feasibility; producer gates                      | TSZ16; regression of TSZ1-TSZ15 and TSW1-TSW6 | not started |

### M0: Contracts and Bounded Spikes

**Owner:** UI/base contract authors, backend maintainers, Ghostty integration owner.
**Prerequisite:** revalidate the inspected source baseline against the working tree.

1. M0a: Finish the separate normative and testing documents. Map `TSZ1` sizes,
   `TSZ2` inheritance, `TSZ3` packing, `TSZ4` shared geometry, `TSZ5` fallback,
   `TSZ6` alignment, `TSZ7` clipping, `TSZ8` source/caret, `TSZ9` edit session,
   `TSZ10` resource/error, `TSZ11` all widgets, `TSZ12` capability, `TSZ13` retained,
   `TSZ14` raylib/HTML, `TSZ15` hue, and `TSZ16` receiver to falsifying scenarios.
   Base authors define `TSW1`-`TSW6` in their owner document, not this tracker.
   Inventory `cellsOf` and every independent width/source-position walk, and
   reconcile `DEF7`/`FNT6` with the base-grapheme prerequisite. Specify mandatory
   non-ASCII per-grapheme width declarations on capable terminals separately from
   author-opt-in packing. Declare the unsupported Unicode width-mismatch policy
   and its weaker guarantees before approving default-output scenarios.
2. M0b: Run a bounded D arithmetic/wire spike: enumerate candidate rational domains,
   equivalent encodings, boundary dimensions, packed versus independent advances,
   overflow, and host-width differences against hand-derived protocol vectors.
   Decide representability, canonicalization, and rounding only after agreement
   across portable arithmetic and target wire encodings. A negative result blocks
   M1's API freeze, not permission to ship integers alone.
3. M0c: Audit all `fontScale` declarations, constructors, conversions, theme metrics,
   HTML output, twoslash settings, and public callers. Choose and document an exact
   migration and compatibility policy for real consumers; do not introduce a second
   unsynchronized size authority or silently reinterpret existing percentages.
   Define inherit/reset and alignment relocation compile tests before M2.
4. M0d: Benchmark ordinary ASCII, CJK-heavy and emoji-heavy normal-size frames,
   rational/packed runs, large clusters, overlapping footprints, scroll-heavy
   virtualization, and edit/repack churn. Compare automatic width lowering with
   protocol-off on full-paint, unchanged-frame, mutation, and scrolling workloads.
   Record hardware,
   compiler, checked/debug mode, workload sizes, setup costs, and baselines in the
   testing ledger. Accept numerical CPU/allocation/output-byte, metadata-memory,
   atlas/texture, and latency budgets before storage/cache choices. Set hard payload,
   footprint, arithmetic, and work limits with structured failure ownership.
5. M0e: In parallel, probe Ghostty dispatch, persistent storage, and C render-state
   exposure at pinned and candidate revisions. Seek upstream implementation first;
   scope a maintainable fork and desktop/Android build experiment if unavailable.
   Record the decision and blocker, not just parser recognition or a pin bump.
6. M0f: Resolve the TSZ12 fractional-mode evidence source. Standard OSC 66 CPR
   detection has no fraction probe. Capability/backend maintainers must run a
   bounded feasibility experiment for acquisition and trustworthy target binding,
   not invent a positive state from integer displacement. Evaluate independently
   verified in-process implementation declarations and external-terminal evidence
   with reliable identity; record negative results where that binding is unavailable.
   Select provenance, fraction/alignment coverage, cache invalidation, deadlines,
   and protocol-off behavior. Unknown remains unknown until accepted evidence exists.

**Exit:** reviewed success/failure/boundary traces in the testing companion cover
first-slice TSW obligations and `TSZ1/3/5/10`. Numeric and API decisions are accepted;
resource budgets are numerical, reproducible, and not invented target claims.
The grapheme prerequisite inventory and `DEF7`/`FNT6` reconciliation have owners;
the no-width-protocol mismatch policy is accepted without blanket parity claims.
The fractional evidence mechanism and its failure traces are accepted before M4
capability implementation; a missing source remains a named target limitation and
blocks any claim of fractional rendering on that target. M5 must exercise actual
rational consumers, not close this gate with integer-only demonstrations.
If M0f finds sound evidence only for in-process renderers, rational rendering can
initially activate only there; external TUI targets retain unknown-fraction fallback
(or ordinary headings in AUTO). Record that first-release consequence explicitly
with M0f's outcome, without relabeling the rational API as integer-only delivery.
Receiver feasibility has an owner and upstream/fork path; failure blocks M6 only.
No prototype counts as production delivery.

### M1: Base Semantics and Runnable Demos

**Owner:** base text and core-cli maintainers. **Prerequisite:** M0a-M0d accepted.

1. M1a: Add the semantic sizing module (new `libs/base/src/sparkles/base/text/sizing.d`)
   over `ansi.d` framing. Implement the accepted exact domain, safe emission,
   validated payload recognition, and original-byte spans. Keep unknown OSC opaque;
   keep SGR/OSC 8 outside packets and reject embedded terminal-control injection.
2. M1b: Integrate `grapheme.d`, `width.d`, `wrap.d`, and `term_unstyle.d` in a
   compile-green slice. Preserve atomic packed units and source identity through
   wrapping, truncation, and plain export; never split packets to satisfy limits.
3. M1c: Add base-only runnable examples under `libs/base/examples/` for rational
   independent text, explicit packing, and footprint-preserving fallback. Add user
   docs under `docs/libs/base/`; name new demo files when the API is accepted.

**Exit:** `dub build :base`, `dub test :base`, and `dub test :core-cli` pass with
nonzero sizing-test discovery. Build/run the new demos in checked mode. TSW1-TSW6
fixtures include unsafe/malformed UTF-8 and controls, empty/oversize input, overflow,
Unicode clusters, packet boundaries, fallback fit, and synthetic/source distinction.
Use independently expected bytes/widths, not only encoder-decoder round trips.
No terminal receiver or UI layout claim is made by this gate.

### M2: One Geometry Authority and Every Widget Family

**Owner:** UI layout/state and host maintainers. **Prerequisite:** M1; E0/E1 and the
M0-reviewed TSZ9 session state table for M2d, including exit, cancellation, and
post-expansion pointer-entry policy.

1. M2a0: Close the blocking `cellsOf` codepoint prerequisite using base grapheme
   segmentation/width and source-byte boundaries. Reconcile `DEF7`/`FNT6`; migrate
   the M0 inventory's forward-width and inverse cell-to-source walks together.
   This is shared cell geometry, not bidi, ligatures, or a shaping dependency.
   Prove normal-size CJK, combining, and ZWJ geometry before sized layout/selection.
2. M2a: Migrate `style.d`, `theme.d`, `canvas.d`, and public size callers per M0c.
   Move `Alignment` from `widget.d` to `geometry.d`, retaining its public widget
   re-export unconditionally to keep style/canvas/wrap independent of widget.
   Explicitly initialize line alignment and `inkY` to `Alignment.end`, not the
   zero-valued `start`. Add per-property absolute inheritance/reset tests and compile probes
   for both import paths; do not couple base wire metadata to UI types (`TSZ1/2/6`).
3. M2b: After M2a0, extend `layout.d`/`Frame` and `wrap.d` with resolved lines/runs, footprints,
   source clusters, and effective clips. Make `display_list.d` and `state.d` consume
   them rather than reconstructing widths. Thread the same policy through host
   `presentApp`, recording, immediate output, and app-owned passes (`TSZ3`-`TSZ8`).
4. M2c: Migrate the inventory in family-sized PRs: leaves/chrome, tables, trees,
   then gutters/scrolling/virtualization. Test row heights, indices, alignment,
   source anchors, copy, and offscreen-to-visible transitions at each step.
   Each family closes its measurement, paint, and hit-test paths (`TSZ4/7/8/11`).
5. M2d: After [editor E0/E1](./editor.md), integrate session-owned packed expansion
   and visual-line navigation. Test keyboard/pointer entry: identify the run,
   expand, relayout, then locate the caret. Keep other runs packed. Test insert,
   delete, paste, undo/redo, boundary crossing, commit, and focus/edit-mode exit.
   Failed fit/fallback validation leaves current text expanded and pending; test
   retry and ensure neither truncation nor stale fallback is displayed (`TSZ8/9/10`).

**Exit:** `dub test :ui` and `dub test :ui-app` pass, including recording-host
scenarios with normal, rational, packed, and unsupported requests. Hand-derived
geometry proves paint/hits/selection/copy share results; omitted TUI objects have
no pointer targets. M2a0 must close the codepoint prerequisite and reconcile
`DEF7`/`FNT6` before layout/selection claims at any size: normal CJK, combining,
and ZWJ cases prove the shared grapheme geometry. Capable-terminal tests include
per-grapheme width declarations; unsupported tests exercise M0's declared
mismatch policy, not assumed exact terminal parity.
M2d remains not started if the editor prerequisites are absent; leaf success cannot
close `TSZ9` or `TSZ11`. Backend realization follows without another layout oracle.

### M3: Raylib, HTML, and Gallery

**Owner:** raylib-text/UI-raylib, HTML interpreter, and gallery maintainers.
**Prerequisite:** M2 resolved geometry and M0 raster/resource budgets.

1. M3a: Adapt `raylib_canvas.d` and `draw.d` to resolved advances, alignment,
   decorations, and backgrounds without globally resizing `FontSet` base cells.
   Bound atlas/cache growth in `font_set.d`, preserving pending-glyph flush behavior.
2. M3b: Update `interp/html.d` and `html_semantic.d`; identify exact cell placement
   versus semantic browser reflow claims. Test base-relative CSS dimensions to
   prevent descendant `ch`/`lh` sizing from multiplying geometry twice.
3. M3c: Add a sizing gallery page under `apps/ui-gallery/src/pages/` (new file),
   register it in `registry.d`, and extend UI user docs. Include independent and
   packed rational text, fallback, mixed styles, selection, and nested clipping.

**Exit:** `dub test :raylib-text`, `dub test :ui-raylib`, `dub test :ui`, and
`dub test :ui-gallery` plus checked gallery builds pass. `TSZ14` evidence includes
real raster-edge clipping on all four edges, DPI, bold/italic/fallback faces,
atlas exhaustion, and browser geometry/source-order checks for both HTML modes.
Recording geometry alone does not satisfy pixel or browser gates. Compare M0
memory/latency budgets and normal-text baselines (`TSZ4`-`TSZ8`, `TSZ10/11`).

### M4: Retained TUI, Static ANSI, and Capability

**Owner:** tui/UI-tui, base terminal capability, and host lifecycle maintainers.
**Prerequisite:** M1 wire safety, M2 geometry, and M0f's accepted evidence mechanism
and failure traces; no Ghostty receiver prerequisite.

1. M4a: Extend `cell.d`/`render.d` with bounded exceptional-run ownership/storage
   while retaining ordinary ASCII and one/two-column grapheme fast paths where
   their semantics suffice. A per-grapheme wire `w` declaration need not force
   exceptional side-arena storage; prove normal-size CJK/emoji budgets under
   automatic lowering as well as protocol-off. Compare semantic contents across
   arenas; compute damage closure over old and new footprints. Preclear stale
   coverage with verified positioned/styled ECH before replacement writes or
   repainting owners: a write into an old owner's covered lower row is displaced
   past that owner even with DECAWM disabled. Absolute cursor positioning alone
   does not make it safe.
2. M4b: Integrate `grid_canvas.d` and `interp/cells.d`, including static ANSI.
   Never emit continuation text, truncate long clusters, or split packed owners.
   Omit partial TUI objects consistently with hit geometry, including normal-size
   wide graphemes at table/pane edges. Record this visible change rather than
   inheriting partial-glyph behavior from the old renderer. Initially disable
   hardware scrolling whenever affected old/new frames contain sized objects.
   Preflight each footprint against the current screen and active margins before
   emission; oversized blocks can be discarded by the receiver. On resize,
   recompute fit, clipping, and damage, including exposed old owners and coverage;
   do not assume that a previously emitted owner survived the resize.
3. M4c: Extend `libs/base/src/sparkles/base/term_caps.d` and the existing tui input/
   host lifecycle for bounded, correlated capability probing. No competing stdin
   reader. Add a public protocol-off policy separate from heading enablement;
   suppress both sizing probes and every OSC 66 display packet despite cached
   support. Test ordinary CJK output with headings disabled under automatic and
   off policies, plus explicit heading enablement with protocol-off fallback.
   Test timeout, late replies, multiplexers, and state restoration.
   Implement M0f's accepted fraction evidence acquisition and target/session binding;
   test provenance, invalidation and absent evidence separately from integer CPR.
   Capability changes invalidate paint decisions and retained state; invalidate
   document layout and corresponding input geometry only when application
   presentation policy changes, such as hue AUTO activation. Test explicit-on
   geometry stability separately from AUTO relayout.

**Exit:** `dub test :tui`, `dub test :ui-tui`, `dub test :ui`, and `dub test :ui-app`
pass. Independent byte replays cover `TSZ13` deletion, movement, overlapping owners,
arena reuse, style/link-only changes, and ordinary/tall transitions. Include
lower-row replacement traces proving ECH precedes writes, screen/margin boundary
preflight, and resize recomputation of exposed old owners. `TSZ12` needs
real supported/unsupported terminal probes as well as deterministic lifecycle tests.
Test `TSZ3`-`TSZ8` clipping/fallback and `TSZ10/11` long-run/virtualization limits;
measure dirty amplification, output bytes, and disabled-scroll cost against M0.

### M5: Source-View, Hue, and Producer Closure

**Owner:** source-view/twoslash and hue maintainers. **Prerequisite:** M2-M4 and editors.

1. M5a: Extend markdown heading options and rich-span policy in `markdown.d`;
   migrate code and twoslash consumers. Test icons, inline code, links, emphasis,
   folded faces/chips, bands, hanging indents, and gutters without synthetic copy.
2. M5b: Wire `settings.d`/`cli.d` precedence and persistence through `viewer_model.d`,
   `app.d`, `gui.d`, and `tui.d`. Use one sizing policy for gutter prepass and final
   layout. Verify AUTO/on/off and live changes while selection/folds/anchors persist.
   Exercise a rational heading preset through M0f's real evidence source, including
   integer-supported/fraction-unknown fallback and invalidated target identity.
3. M5c: Close every M0 inventory row with named tests, including editor sessions,
   tables, trees, and virtualized variable-height content. Exercise actual host GUI,
   TUI, static ANSI, and both HTML paths; update UI user docs and examples.

**Exit:** `dub test :source-view`, `dub test :twoslash`, `dub test :hue`, and checked
hue builds for supported configurations pass. `TSZ15` uses end-to-end config and
live-invalidation scenarios; `TSZ1`-`TSZ14` regression evidence spans the full
inventory. Editors are a required gate, not an optional demonstration. Receiving
terminal panes and decoded ANSI fences remain explicitly unverified until M6.

### M6: Ghostty Receiver and Final Acceptance

**Owner:** Ghostty integration, terminal-view, hue fence, and Nix maintainers.
**Prerequisite:** M0e upstream/fork feasibility and accepted receiver contracts.

1. M6a: Implement upstream-first VT dispatch/storage/advance, erase/overwrite,
   scrolling, resize/reflow, scrollback, selection, dirty closure, and C metadata.
   Integrate the accepted upstream revision or maintained fork through the shared
   Ghostty input and matching ImportC headers; build desktop and Android archives.
2. M6b: Consume receiver metadata in terminal-view `component.d`, `core.d`, and
   `cell_paint.d`. Verify pixel and terminal-in-terminal paths, cursor, hover,
   selection/copy, combining clusters, and unsupported receiving-sink fallback.
3. M6c: Update hue `gui_ansi.d`/`ansi_model.d` to retain sized owners and bounded
   dimensions. Test tall text without LF and explicit cursor motion; never rewrite
   opaque packets during newline normalization or infer dimensions from byte counts.

**Exit:** `TSZ16` requires incoming-byte tests through real VT storage, C extraction,
both painters, and fence consumers, not hand-authored render metadata. Run
`dub test :ghostty`, `dub test :terminal-view`, `dub test :hue`, checked desktop
terminal/hue builds, and `nix build .#hue-apk`; record Android runtime evidence
separately from cross-compilation. Rerun producer/base suites and M0 budgets.

## Evidence and Handoff

Keep results only in the testing companion: requirement, revision/dirty snapshot,
command, discovered/executed counts, configuration, artifact, result, and gap.
Skips and unavailable environments leave required gates unmet. Independent review
checks final contracts, implementation, oracle independence, and test integrity.
Publication validation is separate: formatter, `dub run :ci -- --check-docs-sidebar`,
and `NODE_OPTIONS=--max-old-space-size=12288 npm run docs:build`.
Next executable action is M0a contract/scenario reconciliation, followed by M0b's
bounded arithmetic spike; all implementation milestones remain not started.
