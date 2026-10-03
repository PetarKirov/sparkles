# Text sizing

**Design state:** agreed architecture and behavior from the post-research design
review, September 15, 2026. **Delivery state:** not implemented by this document.
The explicitly listed M0 decisions remain open; they block their dependent APIs.

This is the cross-stack integration contract for sized text. Each requirement names
its owning package; consumers reference that requirement rather than restating it.
The [base wire contract][wire] owns protocol parsing and emission. The
[delivery plan][plan] owns sequencing and progress; the [verification plan][tests]
owns falsifying scenarios and evidence. The merged [research][research] is evidence,
not a competing normative contract.

## Scope and completion

The first producer release must support rational-sized text through base utilities,
the widget tree, controls and editors, tables, trees, gutters and virtualization,
terminal and Raylib backends, gallery examples, and hue's Markdown headings. An
integer-only demonstration or display-text-only implementation is an intermediate
slice, not completion. Existing [editor prerequisites][editor] remain prerequisites;
this document does not claim a full editor already exists.

Receiving OSC 66 in Sparkles Terminal, embedded terminal panes, and hue ANSI fences
is a separate delivery branch. Work proceeds upstream-first in Ghostty, with a
maintained pinned fork when necessary. Its completion must not block producer
support on capable external terminals.

General proportional typography, bidi/shaping implementation, pixel-identical fonts,
automatic compact packing, and a native-pixel layout profile are not included.
Existing source text must not be silently discarded to work around these limits.

## Ownership and dependencies

In this table, `A -> B` means A consumes B's contract; it does not add a new package.

| Owner                      | Owned obligation                                                | Direction                                               |
| -------------------------- | --------------------------------------------------------------- | ------------------------------------------------------- |
| `base.text`                | Wire metadata, safe payload, semantic terminal-text units       | No UI, terminal engine, font or event-loop dependency   |
| `base.term_caps`           | Capability vocabulary and pure evidence resolution              | Session supplies observations                           |
| `ui`                       | Requested styles, shared layout, source geometry, editing state | `ui -> base`                                            |
| `tui`                      | Retained terminal picture and wire serialization                | `tui -> base`; no widget dependency required            |
| `ui-tui`                   | Display-list projection, session-owned capability exchange      | `ui-tui -> ui, tui`                                     |
| `raylib-text`, `ui-raylib` | Rasterization and geometry-to-pixel adapter                     | `ui-raylib -> ui, raylib-text`                          |
| `ui-app`                   | Runtime profile and host wiring                                 | Host supplies observations, not an independent measurer |
| `source-view`, hue         | Heading policy and configuration                                | Consumer policy above shared UI layout                  |
| Ghostty, `terminal-view`   | Incoming VT ownership and screen projection                     | VT execution precedes the D rendering adapter           |

Applications choose presentation and edit-session boundaries. Layout owns derived
geometry, not application text. Backends own device caches and output state. No
backend may independently reinterpret source bytes to reconstruct a competing layout.

## Values and geometry

### TSZ1: Exact portable rational sizes

**Owner: `ui`.** A requested size is a positive exact rational relative to the host
base font. The initial public domain must be finite, documented, exactly encodable
by the chosen portable profile, and include useful fractions such as `1/2`, `5/4`,
`3/2`, and integer scales. Invalid or unrepresentable requests must produce a
structured failure before replacing live layout; silent quantization is forbidden.

The wire can express a ratio as `s*n/d` in multiple ways with different occupied
heights. M0 must choose and enumerate one canonical allocation profile before the
size API lands. Do not equate mathematical representability with a unique footprint.
Reduction, overflow checks, equal-ratio equality, maximum dimensions, and the
existing `fontScale` percentage migration are part of that gate.

### TSZ2: Absolute inheritance and explicit reset

**Owner: `ui`.** An unspecified size inherits from its text context. An explicit
`3/2` always means 1.5 times the base font, even inside a size-two parent. Explicit
`1` resets to normal. Overrides of bold, color, link, or another independent
property must preserve inherited size. Default-value equality must not stand in
for per-property inheritance. Resolve style before measurement.

### TSZ3: Explicit packing only

**Owner: `ui`.** Ordinary text must allocate independently addressable graphemes
according to the portable profile. An application may explicitly request fitted
text with an atomic declared footprint. Automatic packing based on neighboring
styles, terminal capability, or available width is forbidden.

**Width declaration is not packing.** An ordinary non-ASCII grapheme may need
`w=2` even at normal size. When TSZ12's protocol emission policy permits OSC 66
and the terminal is explicit-width-capable, the UI producer
must declare each such grapheme's allocated width with nonzero `w`, preserving
one object per independently addressable grapheme. This is automatic backend
lowering, not an author-requested fitted run; it must not require packed fallback
text or trigger packed editing behavior. ASCII may use the ordinary/natural-width
fast path where segmentation and advance are known to agree. Multi-grapheme
fitting remains explicit opt-in. Zero-width attachments must stay with their
owning grapheme rather than becoming empty explicit-width objects.

Here, "ordinary" or "natural" UI text describes how the client chooses allocation;
it does not require wire `w=0`. The base wire API still permits that protocol mode,
but local measurement of arbitrary non-ASCII `w=0` payloads is not proof that a
receiver using different Unicode tables agrees.

This lowering applies to ordinary non-ASCII text in the UI terminal rendering
paths, not just explicitly enlarged widgets or hue headings. Disabling heading
presentation does not disable width declarations. The separate protocol-off
policy in TSZ12 disables them even if support was previously detected. This
requirement does not turn base writers or unrelated plain/ANSI formatting APIs
into automatic protocol emitters.

A packed payload is not a sequence of independently positioned characters merely
because its source contains several graphemes. Wrapping, clipping, and retained
damage must honor the declared atomicity. M0 must settle which packed style forms
are representable: SGR or hyperlink changes cannot be embedded inside an OSC payload.
An unsupported packed style combination must be rejected, not silently subdivided.

### TSZ4: Shared layout authority

**Owner: `ui`.** For equal text, resolved style, viewport in base cells, and
presentation/editing state, all targets must use the same advances, footprints,
wrapped visual lines, line heights, and source geometry. Capability-dependent ink
fallback does not independently remeasure the document.

Replacing the codepoint-counting `cellsOf` authority is a blocking prerequisite,
not a later typography enhancement. M2 must reconcile `geometry.d`, `CellMeasure`,
wrapping, display-list placement, and interaction with the base grapheme/width
policy before accepting sized layout. The existing `DEF7`/`FNT6` and `LAY5` gaps
are tracked in the [plan][plan]; ordinary-size CJK, combining and joined-emoji
cases must pass too. This does not require general font shaping.

The frame must own or explicitly borrow a layout result whose lifetime covers
display-list construction and interaction. Its source references identify a text
revision. Changes to text, size, wrapping width, alignment, or edit state invalidate
the corresponding geometry. Stale input must not be applied to a different source
revision using an old frame. Speculative measurement must not mutate committed layout.

### TSZ5: Footprint-preserving fallback

**Owner: `ui`; painted by adapters.** Once sized presentation is enabled, an
unsupported target must preserve its requested occupied geometry and paint ordinary
text within it. It must not collapse the line height or concatenate fallback text
with unscaled advances. Copy and logical export retain the original content.

Packed authors must supply an ordinary-text fallback that fits the declared
footprint, or an author-owned mechanism that supplies one for the current content.
Missing, stale, or non-fitting fallback is a validation failure, not permission to
truncate, expand layout, or overwrite neighbors. Complete text remains available to
logical copy even when visible fallback differs. Fallback placement and wrapping
within the box must be specified in M0 and share the normal alignment vocabulary.

Fallback remains a projection of the same atomic packed owner and source revision.
Visible fallback glyph boundaries do not establish internal source offsets.

Preserved client geometry is not a claim that arbitrary unsupported receivers
share its Unicode tables. When explicit width is unavailable, the adapter must
expose that allocation is unverified rather than infer support from ordinary
text output. M0 must define width-mismatch handling and cursor resynchronization
for that fallback before acceptance. No terminal-side mismatch may silently
change the shared layout or be reported as proven physical occupancy parity.

### TSZ6: Shared alignment vocabulary

**Owner: `ui`.** Reuse the existing `Alignment` enum, with separate settings for
line placement and horizontal/vertical ink placement:

| Setting                  | Default           | Aligned object                         |
| ------------------------ | ----------------- | -------------------------------------- |
| Line vertical alignment  | `Alignment.end`   | Run footprints within each visual line |
| Ink vertical alignment   | `Alignment.end`   | Fractional ink within its footprint    |
| Ink horizontal alignment | `Alignment.start` | Ink within its allocated width         |

`start`, `center`, and `end` mean top/center/bottom vertically and left/center/right
horizontally. This does not add bidi logical-start semantics. For a line containing
heights one, two, and three, bottom alignment places their tops at rows two, one,
and zero. Top alignment places all at row zero. Line height is the maximum occupied
height, not the average or the ink height.

Keep `Alignment`'s existing zero/default value and container `alignX`/`alignY`
behavior unchanged. Move its definition into an appropriate UI geometry module
and publicly re-export it through `ui.widget`: style, wrapping, and canvas
contracts must share it without importing the widget model that consumes them.
This is intra-UI layering, not a requirement for base or `tui` to import UI.
Do not introduce a second semantically identical UI enum or a base-to-UI dependency.
New line and vertical-ink fields must explicitly initialize to `Alignment.end`;
D's enum default initialization would instead select `start`.

Wire conversion must be explicit: UI `start/center/end` maps to OSC values `0/2/1`,
not an integer cast. Center rounding for odd free cell space must be settled in M0
against existing layout conventions. Pixel rounding belongs to painting and must
not change cell geometry. No portable typographic-baseline guarantee is made.

## Visibility, input, and editing

### TSZ7: Whole-object terminal clipping

**Owner: `ui-tui`; visibility projection shared with interaction.** Only objects
fully contained in the effective terminal clip may be emitted. A partially clipped
object is omitted without relayout. Ordinary text is atomic per grapheme; explicit
packed text is atomic per fitted run. Nested clips and occluding layers must not
leave a partly visible object emitting outside the final allowed region.

Omitted objects must not create pointer-hit targets in invisible areas. Existing
logical selections and copy semantics remain source-based; omission does not erase
the content. GUI may scissor ink while preserving the same layout. Disabling
terminal wrapping is not clipping and is not an implementation of this requirement.

This also applies at normal size: a two-column CJK or emoji grapheme straddling
a table or pane edge is omitted whole, not truncated into a half-glyph or emitted
past the clip. That is an intentional visible change to any existing partial
normal-size painting behavior. Protocol-off fallback retains this logical
clipping rule; it does not restore partial-object writes. M4 must test and document
the change for ordinary text as well as enlarged and packed content.

### TSZ8: One source and caret geometry

**Owner: `ui`.** All occupied rows of ordinary sized text resolve to the same source
owner. Selection and copying must not duplicate content for continuation rows.
Synthetic icons/padding must remain distinguishable from source bytes. Hit testing
must use final clips and z-order; link hit rectangles follow their run footprints,
not automatically the full line's unused space.

Hits on packed text or its fallback identify the packed run, not an inferred
internal source position. Internal editing positions are resolved only after TSZ9
expansion and layout; fallback glyph positions are not a source-coordinate map.

Up/Down navigation must move between wrapped visual lines, preserving preferred
horizontal cell position. Continuation rows are not extra lines or caret stops.
Horizontal movement must use valid grapheme boundaries. Caret rendering, scroll
visibility, and input-method placement on targets that support it must derive from
the same resolved position, not backend-specific width walks.

### TSZ9: Packed edit-session lifecycle

**Owner: `ui` editing state; session commands owned by the application.** Editing
entry must expand only the targeted packed run. Re-layout must occur before an
internal caret position is established. Do not estimate internal glyph positions
from the packed rectangle and carry that guess into editing.

| Current state    | Trigger                                            | Required transition                                             |
| ---------------- | -------------------------------------------------- | --------------------------------------------------------------- |
| Packed           | Editor focus elsewhere                             | Remain packed                                                   |
| Packed           | Editing enters this run                            | Activate stable run identity, expand, lay out, then place caret |
| Expanded session | Edit, wrap, scroll, tree rebuild, caret leaves run | Remain expanded                                                 |
| Expanded session | Commit or explicit leave-editing-mode              | Validate current content/fallback and then repack               |
| Expanded session | Validation failure                                 | Preserve content and expanded representation; report failure    |

The session must survive virtualization and frame reconstruction. Source selections
and scroll anchoring must survive expansion/repacking through stable source
identity. Caret boundary crossings alone must never end the session. Repeated
activation of an active session must not expand it twice or reset its selection.

This table does not define commit-on-blur, cancellation rollback, pointer-entry
caret choice after reflow, multiple concurrent sessions, or forced disposal of an
invalid session. M0 must settle those with the editor contract before M2d. Failure
must never silently destroy edits, repack stale fallback, or block teardown without
an explicit application-visible resolution path.

### TSZ10: Bounded ownership and failure

**Owners: each allocating layer; translated at its API boundary.** Validate hostile
bytes and dimensions as errors, not assertions. Configurable memory/work limits,
overflow checks, and diagnostic results must distinguish invalid size, invalid
payload, invalid fallback, exhausted resources, and unknown/unsupported capability.
Concrete error names remain API design work.

Failure to build a replacement frame must preserve the last committed frame and
its source-version relationship, or enter an explicit invalidated/error state.
It must not publish partially built ownership. Output transport failure invalidates
the retained mirror until a verified recovery/full repaint; bytes already written
cannot be rolled back. Diagnostics must not log document payloads by default.

### TSZ11: All text widgets

**Owner: `ui`, component owners.** No existing text-bearing widget family is silently
normal-size-only at producer completion. The audit includes text/rich/glyph nodes,
labels/buttons, single/multiline editors, tables, trees, gutters, overlays, and
virtualized content. Every family must either consume shared layout directly or
prove equivalent geometry through an adapter. Editor prerequisites are tracked
explicitly, not waived because display-only demos work.

## Backends and applications

### TSZ12: Session-owned capability resolution

**Owners: `base.term_caps`, `tui`/`ui-tui`, `ui-app`.** Preserve separate observations
for explicit width, integer scaling, and required fraction/alignment modes, and
distinguish unknown from unsupported. Parsing
a command, terminal branding, or image support is not positive scaling evidence.
The session owning input performs probes with one bounded deadline, contextual
reply matching, cleanup, and preservation of unrelated input. Late or unrelated
CPRs must not mutate resolved support.

Protocol emission policy is distinct from heading presentation and observed
capability. Its normal automatic mode permits width declarations only after
positive explicit-width evidence, and scale/fraction use only with the required
support. The host must expose an explicit protocol-off policy through its public
configuration; final option names belong to M0. Protocol-off must emit neither
OSC 66 probes nor OSC 66 display packets, including normal-size per-grapheme
`w` declarations, regardless of cached capability or explicit heading enablement.
It does not prevent unrelated terminal queries or erase/cursor operations.

The following feature gate, aggregation rule, and heading table compose; they are
not sampled end-to-end scenarios.
Observed support uses exactly `unknown`, `unsupported`, or `supported`, recorded
independently for each feature. "Width only" in the examples describes positive
width support without permission for the requested ink features, not another
observation state or implicit evidence about fractions.
Unknown means evidence is unresolved, including timeout; it is not a negative
observation. Additional fraction-mode requirements must use the same gate rather
than infer support from integer cursor displacement alone.

**Fraction evidence acquisition is an unresolved M0 gate owned by the capability
and backend maintainers.** The pinned protocol's detection sequence tests explicit
width and integer scale using CPR; it supplies no fractional-rendering query.
Fraction support must initially remain `unknown`; neither a successful integer
probe nor an unchanged fractional cursor advance promotes it to `supported`.
M0 must select an evidence source and define how it is acquired and bound to the
active target/session: for example, a validated implementation declaration for an
in-process backend, or independently verified compatibility evidence with reliable
target identification for an external terminal. These are candidate mechanisms,
not accepted brand heuristics or a claim that such identification already exists.

The decision must define evidence provenance, supported fraction/alignment modes,
cache lifetime and invalidation, failure/timeout outcomes, and protocol-off behavior.
Any active acquisition must obey the same bounded input-owner lifecycle as other
probes. M4 implements the accepted source; M5 must exercise it through real
rational-size consumers before producer completion. If no sound source is available
for a target, fractional requests retain unknown-support fallback there. That is
not permission to claim rational rendering proved by integer-only tests.

First apply this gate independently to each required protocol feature:

| Protocol policy | Observed support        | Effective state | Permission and evidence                                                                                   |
| --------------- | ----------------------- | --------------- | --------------------------------------------------------------------------------------------------------- |
| Off             | Any of the three states | `blocked`       | No sizing probes or OSC 66 packets, even with cached positive evidence; retain the observation separately |
| Automatic       | `unknown`               | `unknown`       | No display use of this feature; any probe/retry must remain bounded under the session lifecycle           |
| Automatic       | `unsupported`           | `unsupported`   | No display use of this feature; do not describe negative evidence as a pending probe                      |
| Automatic       | `supported`             | `supported`     | Display use is permitted subject to payload, placement, and other required-feature checks                 |

Every display packet needs permission for every feature it uses: nonzero `w`
requires explicit-width permission, `s > 1` requires integer-scaling permission,
and an active `n/d` requires permission for its fraction/alignment mode. Width-only
packets may be emitted when width is permitted even if ink features are unknown or
unsupported. No packet may use a denied feature. Off suppresses probes and display
packets for every feature. The first table covers all six policy/support
combinations for each feature and preserves the reason permission was denied.

**Aggregate requested ink support before choosing heading presentation.** The
canonical profile selected in M0 determines a request's required ink-feature set:
include integer scaling when `s > 1`, and the relevant fraction/alignment support
when `n/d` is active. An integer request must not depend on unused fraction support.
For automatic activation of a heading preset, take the union of ink features needed
by its configured sizes; do not activate a rational preset from integer support
alone. Aggregate the gated states as follows, preserving the individual states
alongside the result for diagnostics:

1. Protocol-off gives `blocked`, regardless of observations or the feature set.
2. Otherwise, any required `unsupported` feature gives `unsupported`.
3. Otherwise, any required `unknown` feature gives `unknown`.
4. Otherwise all required features are supported and the result is `supported`;
   an empty ink-feature set also gives `supported` under automatic protocol policy.

For example, a profile using `s=2:n=3:d=4` with integer support but unknown
fraction support resolves to `unknown`, not `supported`. A profile with one
unsupported requirement and another unknown one resolves to `unsupported`, while
retaining both observations. Width permission remains separate from this ink
aggregate: missing it invokes TSZ5's unverified-allocation path rather than silently
changing the agreed heading activation policy. Actual packets still need permission
for every feature they use, including `w`.

Then resolve heading layout using the aggregate requested ink support:

| Heading presentation | Aggregate requested ink support        | Layout and paint                                                                                                                                             |
| -------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Disabled             | Any of the four effective states       | Ordinary heading layout; independently permitted width declarations still apply                                                                              |
| Enabled              | `supported`                            | Requested sized footprints and supported sized ink; without width permission, apply [TSZ5's unverified-allocation rule](#tsz5-footprint-preserving-fallback) |
| Enabled              | `blocked`, `unknown`, or `unsupported` | Preserve requested sized footprints with TSZ5 fallback; preserve the distinct denial state from the first table                                              |
| Automatic            | `supported`                            | Activate the sized-heading preset; without width permission, apply [TSZ5's unverified-allocation rule](#tsz5-footprint-preserving-fallback)                  |
| Automatic            | `blocked`                              | Ordinary heading presentation; no OSC 66 because protocol policy is off                                                                                      |
| Automatic            | `unknown`                              | Ordinary heading presentation while required ink evidence is unresolved; permitted width declarations may still apply                                        |
| Automatic            | `unsupported`                          | Ordinary heading presentation because a required ink feature is unsupported; permitted width declarations may still apply                                    |

The grouped enabled row has intentionally identical layout/fallback behavior for
three distinct denial states; it does not merge their observations or probe state.
The gate and aggregation are total for any fixed required-feature set, and the
heading table covers all presentation/aggregate-state combinations. The earlier
54-case matrix covers only requests needing integer scaling and no fraction mode;
it is not exhaustive for rational requests. The [verification plan][tests] also
enumerates fractional feature observations and required-feature sets. Acquisition,
mode coverage and temporal probe behavior require separate evidence beyond these
finite resolution tables. In every case, enabled headings preserve requested
footprints when required ink support is unknown or unsupported, as with protocol-off.

In the supported-ink rows, missing width permission is not clean physical
geometry evidence. Non-ASCII `s` output without explicit `w` leaves its advance
to the receiver's Unicode policy. Preserve the shared client footprint, expose
unverified allocation, and apply M0's accepted width-mismatch/resynchronization
policy before accepting that output path under TSZ5. The table does not authorize
bypassing width permission or assuming that `w=0` restores authoritative advance.

For hue automatic presentation, a scaling capability blocked by protocol-off is
not usable capability. Explicit presentation enablement does not override the
protocol-off safety policy. Changing emission policy invalidates retained paint
state and applies the existing TSZ5 fallback; application policy may separately
change automatic heading layout. Base's explicit wire writer remains policy-free,
and incoming VT decoding is not disabled by a producer emission policy.

Capability changes invalidate paint decisions and retained state. They only cause
document relayout when application presentation policy changes, not when an already
enabled size falls back under TSZ5. Startup resolution, partial replies, resize
during probing, fraction-evidence acquisition/invalidation, and retry timing are
bounded-state-machine work in M0/M4/M5.

### TSZ13: Retained multicell rendering

**Owner: `tui`; projected by `ui-tui`.** Each covered cell must resolve to exactly
one live object owner; no overlap or orphan continuation may be published. Equality
must include text, footprint, scale, alignment, style, and link meaning, not arena
IDs that may be reused. Ownership persists when an anchor is unchanged.

Damage must close over intersecting old and new footprints. Erase affected old
objects before painting replacements, restore all affected cells, and emit target
anchors once. Never serialize continuation cells as ordinary text. Full paint and
incremental paint must converge to the same independently observed terminal state.
Hardware scrolling across sized content stays disabled until object-aware evidence
proves safety. Storage design must meet measured ordinary-text budgets, including
normal-size CJK-heavy and emoji-heavy frames with mandatory width declarations
enabled. Those are ordinary workloads, not rare oversized-text exceptions.
Explicit wire width does not itself require exceptional storage: an existing
one/two-column owner representation may remain the fast path when it expresses
all required semantics. Compare metadata, allocations, output bytes and frame CPU
with protocol lowering both enabled and off before choosing a side-arena design.

Absolute cursor positioning alone does not make a write into an old lower-row
continuation safe: the receiver can displace that write past the multicell,
independently of DECAWM. Erase intersecting old objects with an independently
verified operation such as ECH before emitting replacement text there; blanks
written as ordinary text are not an equivalent clearing operation. Include this
producer hazard in full-versus-incremental receiver replay.

Before emitting an object, preflight its complete footprint against the current
screen, effective pane clip, and active scrolling-region constraints. A receiver
can discard an object larger than its screen, or wrap, backtrack, or scroll one
that does not fit at its anchor. Such output must not be recorded as successfully
painted. Suppress non-fitting objects under TSZ7 without removing logical content.
On resize, invalidate the retained picture and recompute visibility/ownership;
the terminal may already have lost a previously fitting object. A later growth
must repaint newly fitting objects from logical content rather than assume their
old anchors remain on screen.

### TSZ14: GPU, HTML, and secondary output

**Owners: `ui-raylib`, `raylib-text`, UI interpreters.** Render resolved ink inside
shared footprints without globally resizing the font set for each widget. Backend
font metrics may position ink but must not independently reflow the shared layout.
Cache sizes and fallback faces within measured resource limits; invalidate on base
font/DPI changes and preserve the established pending-atlas-update lifecycle.

The secondary cell/ANSI interpreter must preserve the same geometry as live TUI.
HTML cell-layout output must not rescale parent `ch`/`lh` geometry accidentally.
Semantic HTML may use browser-native layout only as an explicitly distinct export
contract; it is not evidence of shared cell-layout parity.

### TSZ15: Hue heading activation

**Owners: `source-view`, hue.** Provide automatic, enabled, and disabled presentation
policies. Automatic is the hue default: activate sized headings on a scaling-capable
target; unknown, width-only, and unsupported terminal targets use ordinary headings.
Enabled requests sized footprints everywhere with TSZ5 fallback. Disabled uses
ordinary heading layout. GUI capability refers to an actually implemented renderer,
not a terminal probe. Redirected ANSI cannot assume the eventual receiver's support.

Automatic activation is an intentional presentation-policy difference and therefore
may change geometry across capabilities. Equal enabled presentation must still
satisfy TSZ4/TSZ5. Live policy changes preserve source selections, folds and anchors.
Per-level presets/overrides must retain inline styles, links, icons, bands, hanging
indents and gutters. Exact preset values and final CLI/config names require M5
specimens, not a guessed six-level scale table. Cover GUI, TUI, one-shot ANSI and
defined HTML exports.

### TSZ16: Independent receiver delivery

**Owners: Ghostty integration and `terminal-view`.** Implement incoming protocol
execution in the VT engine before projecting sizing into D painters. Raw OSC text
starts at the current cursor row; its horizontal advance does not advance to the
bottom of its footprint. A receiver must implement the protocol's continuation,
erase, edit, scrollback, reflow and selection semantics, not UI bottom alignment.

The user's raw-output demonstration of 2x and 3x text with a following newline is
a receiver test seed: following-row text skips lower-row occupancy. It is not a
widget alignment policy. C render metadata, dirty reporting, both terminal-view
painters, copy/hover/cursor behavior, and bounded ANSI-fence decoding must preserve
this distinction. Raw fence passthrough and out-of-band paint overlays are forbidden.

Use an upstream-oriented Ghostty fork with matching headers/libraries on desktop
and Android until upstream can provide the contract. The researched revisions
remain parser-only; a version bump alone is not receiver completion.

## Decision record and supersession

| Agreed choice                         | Alternative rejected                          | Reason                                                             |
| ------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------ |
| Producers first                       | Gate all output on Ghostty                    | Useful external-terminal/GUI delivery is independent               |
| Exact rationals in first release      | Integer-only release or silent rounding       | Useful fractional typography with observable representability      |
| Explicit packing                      | Automatically pack style runs                 | Stable ownership and honest internal geometry                      |
| Shared cells and preserved fallback   | Backend-native reflow                         | Stable structure for equal enabled presentation                    |
| Bottom footprints; shared `Alignment` | Baseline promise or dedicated enums           | Implementable portable geometry without duplicate vocabulary       |
| Specific-run editing expansion        | Atomic-only editing or whole-editor expansion | Editable content without unrelated reflow                          |
| Explicit-session repacking            | Repack at caret boundary                      | Avoid navigation-induced layout oscillation                        |
| All widgets                           | Display-only exceptions                       | Feature works through actual interaction surfaces                  |
| Hue automatic activation              | Opt-in default everywhere                     | Progressive activation; explicit enable still preserves footprints |

These choices supersede conflicting recommendations in the earlier
[research proposal][old-proposal], especially normal-size relayout fallback,
integer-first release scope, opt-in hue defaults, and atomic-only packed editing.
That document remains historical research. No requirement here is marked delivered
merely because its design was agreed. See [M0 gates and milestones][plan] and
[requirement-to-evidence traceability][tests].

## Module coverage

These are planned obligations, not claims of implementation. Existing modules
are named relative to their package's `src/sparkles/` directory; new storage/API
modules remain M0 design choices. The [plan][plan] contains the full consumer
inventory and [verification][tests] maps each ID to independent falsifiers.

| Package and module area                                                            | Requirements                   | Implementation status |
| ---------------------------------------------------------------------------------- | ------------------------------ | --------------------- |
| `ui/geometry.d`, `ui/style.d`, `ui/theme.d`, `ui/widget.d`                         | TSZ1-TSZ6                      | not started           |
| `ui/wrap.d`, `ui/layout.d`, `ui/display_list.d`, `ui/canvas.d`                     | TSZ3-TSZ8, TSZ10               | not started           |
| `ui/state.d`, text-input components and planned editor                             | TSZ8-TSZ11                     | not started           |
| `ui/components/` tables, trees, gutters, controls and virtualization               | TSZ4-TSZ11                     | not started           |
| `base/term_caps.d`, `tui/input.d`, `tui/terminal.d`, `ui_tui/session.d`, `ui_app/` | TSZ12                          | not started           |
| `tui/cell.d`, `tui/render.d`, `ui_tui/grid_canvas.d`                               | TSZ3, TSZ5, TSZ7, TSZ10, TSZ13 | not started           |
| `raylib_text/draw.d`, `raylib_text/font_set.d`, `ui_raylib/raylib_canvas.d`        | TSZ4-TSZ7, TSZ14               | not started           |
| `ui/interp/cells.d`, `ui/interp/html.d`, `ui/interp/html_semantic.d`               | TSZ4-TSZ7, TSZ14               | not started           |
| `source_view/markdown.d`, hue policy and viewer modules                            | TSZ15                          | not started           |
| Ghostty integration, `terminal_view/`, hue `gui_ansi.d`/`ansi_model.d`             | TSZ16                          | not started           |

Base's wire and display-unit module obligations are owned by [TSW1-TSW6][wire],
not duplicated in this table as new UI implementations.

<!-- References -->

[wire]: ../base/text/sizing.md
[plan]: ./text-sizing-plan.md
[tests]: ./text-sizing-testing.md
[research]: ../../research/tui-libraries/text-sizing/index.md
[old-proposal]: ../../research/tui-libraries/text-sizing/sparkles-proposal.md
[editor]: ./editor.md
