# Text Sizing Testing

Status: **proposed acceptance strategy; all feature evidence unverified**.
The [UI contract](./text-sizing.md) owns TSZ1-TSZ16; the
[base wire/text contract](../base/text/sizing.md) owns TSW1-TSW6.
This page assigns falsifiers and evidence, not new normative behavior.
Requirement IDs below refer to those owning contracts. Decoder tolerance
expectations remain gated on the TSW4 decision; strict encoder policy is settled.

Follow the [specification guideline](../../guidelines/spec-docs.md) and distinguish
the evidence classes in [research validation][validation]. No tests below are
claimed implemented or executed, no terminal conformance is claimed, and no
performance budget has been measured. Proposed test homes name intended production
boundaries, not existing sizing APIs or discovered tests.

## Requirement Matrix

Paths below are repository-relative. Module names without paths use the package's
`src/sparkles/<package>/` directory, with hyphens converted to underscores.
Every row describes **proposed tests**, including additions to existing modules.
Expected values must not call the production sizing, layout, or damage helpers.

| ID    | Concrete falsifier                                                                                                                                                                                | Proposed actual test home                                                                                          | Independent oracle                                                                   |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| TSZ1  | Equivalent rational sizes differ; fractional ink shrinks allocation or arithmetic overflows silently.                                                                                             | `libs/ui`, new `text_sizing.d`                                                                                     | Hand-derived rational cases below; bounded integer enumeration.                      |
| TSZ2  | A bold-only child resets size, or explicit child 2x under parent 3x becomes 6x.                                                                                                                   | `libs/ui`, `style.d` and `layout.d`                                                                                | Literal inheritance tree: inherit 3x, override 2x, reset 1x.                         |
| TSZ3  | Ordinary text packs automatically, or one explicit block splits at a guessed grapheme column.                                                                                                     | `libs/ui`, new `text_sizing.d`, `wrap.d`                                                                           | Author-declared atomic intervals and literal widths, not proportional division.      |
| TSZ4  | Measurement fits a line whose emitted occupied rectangles exceed its width; hit geometry differs.                                                                                                 | `libs/ui`, `layout.d`, `display_list.d`                                                                            | Manually tabulated rectangles shared as data across public boundaries.               |
| TSZ5  | Unsupported output loses text, changes reserved footprint at paint time, or paints packed logical text instead of author fallback.                                                                | `libs/ui`, new `text_sizing.d`; `libs/ui-tui` adapter tests                                                        | Separate logical-source, visible-fallback, and occupied-rectangle literals.          |
| TSZ6  | Default 1x text starts at the top of a 3-row line; enum ordinals serialize center as bottom.                                                                                                      | `libs/ui`, `layout.d`; `libs/ui-tui` adapter mapping tests; `libs/base`, new `text/sizing.d` wire-value tests only | Row table below; `start, center, end` maps to wire `0, 2, 1`.                        |
| TSZ7  | A partially clipped TUI object emits or remains pointer-targetable; GUI paints outside its scissor.                                                                                               | `libs/ui`, `display_list.d`; `libs/ui-tui` and `libs/ui-raylib` adapter tests                                      | Four-edge rectangle intersections; receiver state and pixel masks.                   |
| TSZ8  | Continuation rows duplicate copy text; Up/Down moves one physical row inside a tall visual line.                                                                                                  | `libs/ui`, `state.d`, `focus.d`                                                                                    | Literal source-byte/caret tables and visual-line adjacency.                          |
| TSZ9  | Entering edit expands every packed run, places a caret before layout, or repacks when the caret merely exits the run.                                                                             | `libs/ui`, `state.d`; `libs/ui-app`, `record.d`                                                                    | Reviewed event trace with run identity and layout/caret ordering.                    |
| TSZ10 | Invalid metadata or exhausted storage leaves partial output, dangling owners, or stale geometry.                                                                                                  | `libs/ui`, new `text_sizing.d`; `libs/tui` retained-screen tests                                                   | Fault schedule, sentinel writer, and before/after ownership snapshots.               |
| TSZ11 | One text-bearing widget ignores inherited size or measures differently from equivalent rich text.                                                                                                 | `libs/ui`, `widget.d`, `components/`; `apps/ui-gallery/src/registry.d`                                             | Exhaustive widget inventory, each with explicit expected bounds and text.            |
| TSZ12 | Width-only support becomes scaling, unrelated keys disappear, or a late CPR changes another session.                                                                                              | `libs/ui-app`, `tui_loop.d`, `event_source.d`; `libs/tui` input tests                                              | Scripted byte/deadline transcript and external receiver displacement.                |
| TSZ13 | Shrink/remove leaves continuations; erasing one owner damages an unrestored neighbor.                                                                                                             | `libs/tui` grid/screen tests; `libs/ui-tui` adapter tests                                                          | Old/new ownership closure by hand plus Kitty full-versus-diff replay.                |
| TSZ14 | GPU/HTML changes global font size, clips decorations incorrectly, or disagrees on allocation.                                                                                                     | `libs/ui-raylib` adapter tests; `libs/ui`, `interp/html.d`                                                         | Cell-to-pixel calculations, browser bounds, and independent image masks.             |
| TSZ15 | hue AUTO enables unsupported sizing; explicit on collapses footprint; off retains enlarged layout.                                                                                                | `apps/hue/src/`, proposed `text_sizing_tests.d`                                                                    | Policy truth table through actual GUI/TUI/ANSI/HTML consumer paths.                  |
| TSZ16 | OSC parsing succeeds but no sized screen object or usable embedding geometry exists.                                                                                                              | `libs/ghostty`, proposed `text_sizing_tests.d`; `libs/terminal-view`                                               | Pinned negative receiver case, then complete stream-to-screen/export replay.         |
| TSW1  | The strict writer accepts invalid domains or fractions, overflows, or emits noncanonical metadata.                                                                                                | `libs/base`, new `text/sizing.d`                                                                                   | Literal accepted/rejected writer vectors and canonical output bytes.                 |
| TSW2  | C0/C1, DEL, malformed UTF-8, or oversized payload escapes validation.                                                                                                                             | `libs/base`, new `text/sizing.d`                                                                                   | Exhaustive forbidden scalars and byte-count boundary fixtures.                       |
| TSW3  | Validation writes an OSC prefix before failing, or valid framing/SGR/OSC 8 composition is wrong.                                                                                                  | `libs/base`, new `text/sizing.d`                                                                                   | Handwritten wire bytes and a sentinel output range.                                  |
| TSW4  | Strip/width/source operations lose payload text or equate advance with ink bounds; duplicate/unknown-key decoding violates the accepted tolerance, precedence, or invalid-unit diagnostic policy. | `libs/base`, new `text/sizing.d`, `text/ansi.d`, `text/width.d`, `text/analysis.d`                                 | Literal source/geometry vectors and decoder fixtures pinned after the TSW4 decision. |
| TSW5  | Wrap/clip splits an explicit block, a grapheme, or a control frame; tiny widths never progress.                                                                                                   | `libs/base`, `text/wrap.d`                                                                                         | Enumerated legal boundaries and bounded progress counterexamples.                    |
| TSW6  | Importing the base sizing facility pulls in UI, terminal session, or shaping dependencies.                                                                                                        | `libs/base/examples/`, proposed `text-sizing.d`; `libs/base/dub.sdl` dependency audit                              | Standalone base-only compile and independently inspected dependency graph.           |

## Arithmetic And Placement

### Width declaration versus packing

Start with normal-size `U+1F408` as one grapheme whose client width is two.
On a width-capable target, expect one `w=2` packet without author packing opt-in,
without a packed fallback requirement, and without a packed edit-session state.
At scale two the same `w=2` declares four columns, not two. A sequence
of independently addressable non-ASCII graphemes must retain separate owners even
if their sizes/styles match. Contrast this with an explicitly fitted multi-grapheme
run: it has one atomic owner and the TSZ9 session lifecycle.

Add a simulated receiver whose Unicode width differs from the client: explicit
declarations must keep client allocation authoritative. For a receiver lacking
explicit width, assert unverified allocation reporting and the M0-selected
resynchronization policy rather than falsely claiming physical geometry parity.
Low-level `w=0` measurement tests prove only the declared local model.

Treat the `cellsOf` codepoint replacement as a prerequisite, not a test-local
workaround: exercise public measurement, wraps, display operations, caret/source
maps, and terminal output on the same ordinary-size CJK/combining/ZWJ corpus.
Failure at size one blocks M2 even if scaled ASCII examples pass.

### Canonical wire syntax

Wire fixtures must use colon-separated `key=value` pairs. Reject or never produce
`s:2:w:2`; accept the field syntax of `s=2:w=2`. For a trusted ASCII payload `A`,
the writer's literal expected packet is `\x1b]66;s=2:w=2;A\x1b\\`.
With active ink alignment, use a vector such as
`\x1b]66;s=2:w=2:n=1:d=2:h=2:v=1;A\x1b\\`.
Without an active fraction, valid nondefault `h`/`v` must disappear from canonical
output; invalid values must fail before the first writer call. Reduce equivalent
active fractions. Writer goldens use the local TSW1 order; receiver comparisons
test geometry/semantics and do not require Kitty's serialization order to match.

### Line and ink placement

Use zero-based cell coordinates. For three one-cell graphemes at 1x, 2x, 3x,
horizontal origins are `0, 1, 3`, widths `1, 2, 3`, total width `6`, and line
height `3`. For a visual line starting at row `10`, derive these values by hand:

| Alignment          | 1x occupied rows | 2x occupied rows | 3x occupied rows | Next visual line |
| ------------------ | ---------------- | ---------------- | ---------------- | ---------------- |
| Explicit top/start | 10               | 10-11            | 10-12            | 13               |
| Default end        | 12               | 11-12            | 10-12            | 13               |

TSZ6 defaults are line alignment `end`, `inkY=end`, `inkX=start`. Test each
independently: line placement moves the allocation; ink alignment moves ink inside
it. Serialize `Alignment.start/center/end` through an explicit `0/2/1` map for
both axes, never by casting enum ordinals.
Test this UI-to-wire conversion in `ui-tui`; base tests protocol values only and
must not import UI `Alignment`.

For natural one-cell text with `s=2:n=3:d=4`, ink scale is exactly `3/2`, but
allocation remains `2 x 2`. For `s=1:n=1:d=2`, half-size ink still occupies
`1 x 1`. For explicit `s=3:w=2:n=1:d=2`, allocation is `6 x 3`, advance is
`6`, and ink scale is `3/2`. Include equivalent fractions, empty text, wide
graphemes, inactive fractions, maximum valid fields, and overflow rejection.

One `w=1` half-size block containing `ab` is atomic. Dividing its width by two
does not establish either source character's visual position. Contrast it with
two natural half-size objects and two separately authored explicit objects;
equal total width must not erase their different ownership or wrap boundaries.
Retain the [mdfried counterexample][validation]: six natural-width-two scalars,
scale `2`, fraction `5/6`, width budget `20`; a naive prewrap budget of `12`
accepts them although the per-scalar explicit allocation consumes `24` columns.

The user screenshot's raw 2x and 3x cases need a separate receiver fixture:
emit at the original row, verify horizontal advance stays on that row, then
write on the next row through the covered rectangle and observe Kitty's skip.
Record original bytes and cursor coordinates with the screenshot before blessing
a golden. This is not an oracle for UI default bottom alignment: UI deliberately
positions differently sized runs at different rows, then advances by line height.

## Fallback And Interaction

Run the same scenario with full, width-only, unknown, timed-out, and disabled
support. Preserve requested footprint where TSZ5 requires it; choose visible
fallback before layout, not by silently shrinking an emitted object. For packed
logical source `ab` and authored one-cell fallback `X`, assert visible text `X`,
copy text `ab` exactly once, and the independently specified reserved rectangle.
Synthetic labels, decorations, padding, and continuation cells add no source bytes.
With unequal fallback/source lengths, test pointer hits, links, and selections
against the same atomic run owner and source revision. Visible fallback boundaries
must not become internal source offsets or caret stops. Editing entry identifies
the run, expands it, and lays out before resolving an internal caret; the precise
post-expansion pointer-entry choice remains an M0-reviewed TSZ9 gate before M2d.

At normal size, place a two-column CJK/emoji grapheme across each horizontal
table/pane clip boundary. Assert whole-object omission, no partial packet or
out-of-bounds ink, and no pointer target for the omitted object. Repeat under
protocol-off fallback: logical clipping is unchanged. Include ordinary text just
inside the edge to prove the clip is not over-conservative by a whole column.

Enumerate pointer positions over every covered row, gaps, overlapping popups,
negative origins, nested clips, and all four clip edges. Partially clipped TUI
objects retain layout but are omitted from output and pointer targets; GUI ink
uses scissoring. Check source selection separately from visible hit eligibility.
Caret and selection tests include combining/ZWJ text, wide graphemes, wrapping,
and Up/Down between visual lines of unequal physical height.

Proposed TSZ9 trace: enter editing a specific packed run, expand that run, complete
layout, then resolve its caret. Move the caret outside and back without repacking;
other packed runs stay packed. Expansion lasts until commit or leaving edit mode.
Focus loss, cancel, and invalid author-fallback snapshot behavior are **proposed
acceptance gates requiring a reviewed state table**, not accepted details here.
The UI/editor owner must settle whether each event leaves edit mode and how source,
fallback, selection, and the last valid snapshot are retained or restored before
those traces become goldens. Do not infer cancellation policy from caret exit.

TSZ11 requires an inventory of **all** text-bearing widgets, not just labels and
headings: inputs/editors, placeholders, buttons, toggles, list/tree/table cells,
tabs, menus, tooltips, property fields, gutters, status text, and component labels.
Exercise plain/rich equivalence, inheritance, explicit reset, focus, resize, and
fallback through the public host. Extend the inventory when widget kinds change.

## Session And Receiver Gates

Proposed probe tests own one output session and an explicit request lifetime.
Inject startup CPR, expected replies, duplicates, stale/late replies, every byte
split, timeout, cancellation, ordinary keys, and modified F3/CPR ambiguities.
Compare the surviving key stream byte-for-byte and assert safe cleanup of cursor,
screen, and terminal modes on success and every failure. A parser recognizing OSC
66 or CPR never establishes a capability, and one session's result cannot leak.

Use independent width and scaling stimuli. Preserve the [presenterm][presenterm]
false-positive fixture: foot prints both unsupported sizing payload spaces normally;
their combined displacement can look like integer scaling. Width-only foot must
remain width-only. Cursor displacement alone does not prove fractional ink quality.
For hue, AUTO follows actual capability; explicit on preserves requested geometry
with fallback where needed; off uses normal sizing. Check overrides as well as
theme defaults so title paths cannot bypass policy.

Cross protocol policy with heading presentation independently. With positive
width evidence and headings disabled, ordinary non-ASCII UI text still emits
per-grapheme `w` in automatic protocol mode. With protocol-off, neither probes
nor display packets contain OSC 66, even after capabilities were cached or when
heading presentation is explicitly enabled. Explicit enable preserves footprints
using fallback; automatic headings resolve to ordinary presentation while protocol
use is blocked. Exercise live policy transitions through retained invalidation,
not only cold startup. Base wire writer and incoming VT decoding are separate
contracts and are not implicitly disabled by this host policy.

For a request requiring integer scale but no fractional mode, enumerate the 54
combinations of two protocol policies, three heading presentation modes, and
independent three-state width/integer-scale observations. This is the integer-only
resolution submatrix, not a complete rational-capability matrix.
Derive literal expected effective states, heading footprint selection, fallback
selection, and allowed wire features from TSZ12's gate, ink aggregation, and heading
table. Unknown
and unsupported must remain distinguishable in the resolved state even when both
select the same visible fallback. Off blocks both features despite cached support.
In particular, pin automatic protocol plus enabled headings for every support pair:
unsupported/unknown scaling preserves the requested footprint, and supported
scaling selects sized presentation. Also pin automatic headings with width-only
support: ordinary heading layout, with permitted per-grapheme width declarations.
Packets using multiple features must satisfy every feature gate; width permission
alone must never authorize scale or fractions.

For each fixed required-ink set in the canonical profile, enumerate all 162
combinations of policy (2), presentation (3), width observation (3), integer-scale
observation (3), and fraction-mode observation (3). Cover the empty set, integer
only, fraction only, and integer plus fraction; unused observations must not change
the result. For example, integer-supported/fraction-unknown resolves to `unknown`
for `s=2:n=3:d=4`, but fraction-unknown must not disable a plain integer request.
Pin aggregate precedence `blocked`, then required `unsupported`, then required
`unknown`, then `supported`; preserve every constituent observation for diagnostics.
Test preset feature unions so an integer heading cannot mask another heading's
fraction requirement during AUTO activation. Width remains independently gated:
it cannot repair denied ink support, and absent width permission still requires
the TSZ5 unverified-allocation path for otherwise supported non-ASCII sizing.
If M0f distinguishes multiple fraction/alignment modes, extend feature-set cases
to each required mode; the 162 count describes one fraction-mode input only.
Evidence acquisition and temporal probe transitions remain separate scenarios.

M0f must supply the fraction-evidence acquisition experiment and reviewed expected
states before its capability tests can close. Assert that standard width/integer
CPR success alone leaves fractional support `unknown`; fractional cursor advance
alone is also insufficient. Exercise the chosen evidence source through the actual
adapter, with provenance and target/session binding, accepted fraction/alignment
coverage, expired or mismatched identity, missing evidence, and protocol-off.
For an integer-supported target with fraction evidence absent, a fractional request
must use the unknown branch: enabled headings preserve footprints with fallback,
while automatic activation must not claim that the requested fraction is supported.
Include independent rendering evidence for claimed fractional modes and M5's real
consumer path. No unimplemented query or assumed terminal brand supplies a fixture's
positive state merely because the resolver accepts a boolean.

For supported scaling with width `unknown` or `unsupported`, test non-ASCII output
against a receiver with deliberately different natural-width rules. If M0's policy
permits natural-width scaled output, require TSZ5's unverified-allocation diagnostic
and its accepted resynchronization handling; client rectangles must remain stable.
Do not accept correct ASCII displacement as proof of non-ASCII physical parity.
Policy `blocked` still forbids every OSC packet, regardless of positive observations;
the composed table must not emit an explicit `w` without width permission.

Replay **actual Sparkles bytes**, not reconstructed commands, through the pinned
[Kitty receiver][kitty]. Compare old-frame plus incremental update with a fresh
full paint at identical dimensions: text, ownership, cursor, and neighbors must
agree. Also compare against hand-derived occupancy so shared producer bugs cannot
make both paths falsely pass. Grow, shrink, move, remove, change only scale, and
overwrite lower continuations; construct chained intersections requiring damage
closure over both old and new owners. Verify erase-before-repaint and anchors only.

Make lower-row displacement a producer regression, not only a receiver test:
first paint a 2-by-2 object, then replace its lower row with ordinary text using
absolute cursor placement. The accepted producer stream must erase the old object
before writing replacement text. An intentionally naive control stream that only
moves the cursor and writes demonstrates the receiver skipping past occupancy.
Test DECAWM both on and off and restore neighbors affected by erasure.

Test objects wider/taller than the screen, footprints crossing the active scroll
region, and an anchor that would cause right-edge backtracking or bottom-edge
scrolling. Assert suppression before emission and no false painted-state entry.
Resize a fitting object to a too-small viewport, then grow again: logical content
survives, old retained state is invalidated, and newly fitting objects are emitted
again even if the receiver discarded them on shrink.

Cover ECH/EL/ED/ICH/DCH/IL/DL, margins, DECAWM, scrollback origins, alternate screen,
narrow resize/reflow, selection/copy, SGR/OSC 8, and graphics-placeholder neighbors.
Fragment transport at every byte boundary. Use [foot][foot] as a real width-only
oracle, not as a substitute for Kitty's multirow receiver. Keep external oracle
code external and record its license, revision, configuration, and harness command.

The [Ghostty study][ghostty] pins `0c2a290d3a3e2a599be3a43435d778a5896667ee` as
parser-present/receiver-absent source evidence, not an executed negative test.
Propose a version-pinned negative replay proving no sizing screen mutation and
no positive capability. A future TSZ16 completion gate separately requires stream
execution, owned multicells, cursor/edit/erase/scroll/reflow behavior, C-exported
geometry and lifetime, selection/copy, terminal-view painting, and ANSI-fence
integration. Parser round trips or a custom large-font painter cannot satisfy it.

## Safety, Resources, And Performance

Proposed base vectors cover BEL/ST, incomplete framing and recovery, 4095/4096/4097
payload bytes, every forbidden scalar, valid multibyte continuation bytes, malformed
UTF-8, duplicate/unknown fields, and adjacent commands. Invalid input must not emit
a prefix. Test downstream writer failure separately: do not promise rollback of
bytes already accepted by an arbitrary writer. Inject exhaustion at each ownership
and layout allocation, checking the contract's error and retained-state outcome.

M0 must establish numeric budgets **before the performance gate is enabled**.
Record workload sizes, toolchain/hardware, baseline revision, samples, and accepted
thresholds for cell bytes, allocations, unchanged-frame CPU, diff bytes, scroll/churn
CPU, damage expansion, atlas memory, and resize/font-reload costs. None are measured
here. Compare ordinary text before/after as well as mixed-size adversarial workloads;
separate cold setup from warm frames. GPU tests vary DPI, base fonts, fractions,
decorations and atlas pressure; HTML checks bounds and logical text in a real browser.

Ordinary-text budgets must include ASCII-only, CJK-heavy, emoji-heavy, and mixed
normal-size documents, not just enlarged or packed runs. Measure automatic
per-grapheme width lowering against protocol-off for full paint, unchanged frames,
edits, resize, and scroll-heavy tables/virtualized panes. Record output-byte growth,
owner/continuation storage, side-arena allocations, retained comparison cost and
CPU independently. Do not hide mandatory normal-size lowering costs in a rare
multicell benchmark or require exceptional allocation solely because wire `w` is
present. Acceptance thresholds remain the measured M0 decision.

## Execution And Evidence

Place proposed D tests in discoverable feature modules, never only `package.d`.
Use named string UDAs and explicit `@safe` or `@system`; use
`@safe pure nothrow @nogc` for pure geometry where feasible, not `@trusted unittest`.
Import special runner attributes unconditionally and verify discovery/execution
counts. Environment-dependent checks use `skipTest(reason)` from
`sparkles.test_runner.skip`, not early return; required skipped gates remain unmet.

Add reusable library demonstrations under `libs/*/examples/` and register them
with the repository CI example selection when implemented. Base-only byte examples
can run without a terminal; real terminal/PTY/browser tests need explicit jobs and
prerequisites. Printing bytes or skipping unavailable receivers is not conformance.
Use debug builds for unit tests and `checked` for shipped example/build artifacts,
never `release` as a way to discard assertions.

Publication commands, to run from the repository root; these are instructions,
not recorded results:

```bash
dub run :ci -- --check-docs-sidebar
NODE_OPTIONS=--max-old-space-size=12288 npm run docs:build
```

Also run the Markdown formatter/checker. Publication remains distinct from feature
acceptance. Record future evidence with IDs, revision/dirty snapshot,
command and counts, terminal/multiplexer/font/dimensions or GPU/browser setup,
artifact, result, and residual gap. Retain failures and minimized random seeds;
label evidence unverified, partial, or verified only for the configuration checked.

[validation]: ../../research/tui-libraries/text-sizing/validation.md
[kitty]: ../../research/tui-libraries/text-sizing/kitty.md
[foot]: ../../research/tui-libraries/text-sizing/foot.md
[ghostty]: ../../research/tui-libraries/text-sizing/ghostty.md
[presenterm]: ../../research/tui-libraries/text-sizing/presenterm.md
