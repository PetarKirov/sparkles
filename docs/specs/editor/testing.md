---
status: accepted
owner: sparkles:editor
reviewed: 2026-11-05
---

# Editor application — Verification

This page defines acceptance evidence for the [application contract](./SPEC.md).
It separates shared state-machine tests, app/adapter integration, live native
input, screenshots and performance. One class cannot substitute for another.
Milestone progress belongs only to [PLAN.md](./PLAN.md).

## 1. Required configurations

| Target           | Required observations                                                                                                                                               | Limits to record                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Desktop Vulkan   | File/tab flow, clipboard, shared palette and guide, rendered Unicode, live IME, safe save/recovery, workload measurements                                           | Window system, refresh rate, fonts, driver and IME                                |
| Android Vulkan   | Equivalent editing operations without hardware keys; system document access, open-with intents, touch handles, keyboard/insets, live preedit, interruption recovery | OS/API, provider/grants, IME, rotation, safe insets and device capabilities       |
| TUI              | Same editing effects, command discovery, configurable bindings, clipboard when offered, file/session flow and settings                                              | Terminal capabilities, reserved keys, color/glyph and composition limitations     |
| Recording host   | Deterministic command and app flows, focus and effect assertions                                                                                                    | Does not establish actual pixels, live clipboard/IME or storage-provider behavior |
| Raylib, optional | Additional consumer of shared contracts                                                                                                                             | Does not close any Vulkan production gate                                         |

Android acceptance includes Xiaomi 2107113SG / SM8350, Xiaomi 25091RP04G /
SM8750P tablet, and Moto e13 / T606. Record actual serial, OS, orientation and
surface dimensions at execution time. Missing device access leaves that
configuration unverified; it is not an automatic waiver.

## 2. Command-palette TDD

The owner approved three public test interfaces before implementation:

1. **State transitions:** open/query/navigation/accept/cancel events produce
   observable state and emitted command identities. Test the interface used
   by adapters, not private fields or allocation strategy.
2. **Command discovery:** context plus query yields reachable ranked command
   descriptors, matched text and shortcut labels. Compare identities and
   arguments against an independently enumerated small catalog.
3. **View integration:** the same state produces selectable rows, focus and
   activation through the shared widget view on recording, TUI and Vulkan.

Use one failing behavior followed by its minimal passing implementation per
cycle. Record red and green invocations and verify a nonzero matching-test
count. Do not write an entire suite against an imagined API before exercising
one behavior. Code storage, match scoring and row layout are implementation
details unless the public contract makes them observable.

| Contract  | Initial state and stimulus                                                                       | Expected observation / independent oracle                                                                                                                     |
| --------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EAP8–EAP9 | Small catalog with two arguments for one operation, a shadowed shortcut and an unbound command   | Manually listed command identities survive; context changes availability; discovery agrees with effective shared key resolution                               |
| EAP10     | Open, edit query, navigate, cancel                                                               | No command effect, document unchanged, previous focus restored                                                                                                |
| EAP10     | Empty catalog or no query matches; press accept                                                  | Empty state remains safe; zero command effects                                                                                                                |
| EAP10     | Select a result, change context so it becomes unavailable, accept                                | Invalid command does not execute; list/selection reflects the changed context                                                                                 |
| EAP10     | Open from document A, focus the query, switch to B, then close A and accept an A-editing command | Query is not an invocation target; switching does not retarget to B; closing A invalidates its command. On palette closure, focus returns to a valid surface. |
| EAP10     | Accept an available result, then repeat the old acceptance event                                 | One command+arguments emitted, palette closed; no duplicate effect                                                                                            |
| EAP10     | Older search completion follows a newer query result                                             | Newer result survives; selected identity is preserved only if still present                                                                                   |
| EAP10     | Consumer retains a view while later query storage grows                                          | View text remains valid under the declared lifetime; no dangling slices                                                                                       |
| EAP11     | Type a document space; separately open a modified leader and tap a guide group/command           | Space inserts; guide activation dispatches the same command as its keyboard path                                                                              |

Ranking tests reuse `sparkles:fuzzy`'s contract rather than recomputing its
scoring algorithm. Palette tests add their own known ordering for ties and
stable command identity. Capacity exhaustion, cancellation and ownership
tests follow the explicit limits chosen before P implementation.

## 3. Unicode and input oracles

The baseline corpus includes Latin NFC/NFD and stacked marks; Greek/Cyrillic;
Arabic joining, Hebrew marks and mixed Latin/RTL digits/brackets; Devanagari,
Bengali, Tamil, Telugu and Sinhala; Thai, Lao, Khmer, Myanmar and Tibetan;
CJK kana/dakuten, Hangul composed/decomposed, BMP and supplementary Han;
historic supplementary scripts; text/emoji selectors, modifiers, ZWJ, flags,
keycaps and tag sequences. Private-use icons are font-specific fixtures.
The [text-lab inventory](../../libs/ui-app/reference/unicode-showcase.md)
provides representative source strings, not proof of editor conformance.

For EAP17–EAP18, independently worked short paragraphs specify logical byte
offsets, grapheme boundaries, visual caret order, affinities and selection
rectangles. Replay insertion/deletion, Left/Right, word motion, wrapped
Up/Down and Home/End, hit-testing and selection through resize/font changes.
Assert that edits affect the intended source ranges and rendered geometry
agrees. Supplement these with the published Unicode vectors used by the
owning base text tests; do not derive expectations from the layout under test.

For EAP19, reuse terminal touch scenarios as stimuli: long-press, handle
capture, finger-anchor offset, crossed endpoints, edge scroll, keyboard
insets, menu placement, release and cancellation on focus/surface loss.
Compare expected selected text and capture/effects through each consumer's
adapter. Terminal cell coordinates are not an oracle for editor byte offsets.

For EAP20, replay composition updates and clipboard responses through model
and recording adapters, then use real input methods on desktop and Android.
Observe visible preedit, marked ranges, cancellation, replacement and one
committed undo revision; verify candidate placement, focus changes and keyboard
dismissal. Report unsupported terminal composition explicitly. Conversion
tests and screenshots of committed text cannot establish live preedit.

Vertical writing, Egyptian quadrant composition and exhaustive Unicode/font
coverage are excluded. A font's missing glyph is distinguished from a text
decoding, fallback, shaping or navigation defect; unsupported variants are
reported without silently weakening the editing corpus.

## 4. Application and storage scenarios

| Obligations | Falsifying scenario and expected result                                                                                                                                                                                                                                                                                                                                           |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EAP1–EAP3   | Build the app through required hosts; inspect package dependencies; run help/version, malformed CLI and log-level cases. No app imports from shared mechanisms or backend key-switch copies; errors are CLI errors.                                                                                                                                                               |
| EAP4–EAP7   | Edit two tabs with several selections, branch undo and switch back. Assert text, selections/history and scroll remain independent; test protected text, indentation, comments and valid/invalid replace patterns.                                                                                                                                                                 |
| EAP12–EAP13 | Select/compose/edit on a highlighted line, then deliver stale highlight results after another edit or tab closure. Text and syntax/decorations stay correct; cancelled workers retain borrows until completion.                                                                                                                                                                   |
| EAP14–EAP16 | Preview several themes and cancel, then accept one and restart; change fonts and available axes through generated settings. Preview changes neither document nor undo; only declared controls appear and UI font stays stable.                                                                                                                                                    |
| EAP21       | Byte fixtures with BOM/no BOM and LF/CRLF/mixed endings; no-op save, localized edits, Enter, deletion/join, paste, replacement and undo. Compare exact bytes against manually specified fixtures after Q7's insertion policy is accepted. Refuse invalid UTF-8, FIFO and unsupported input without replacing active text.                                                         |
| EAP22–EAP23 | Edit while an earlier revision saves; inject permission/full-storage/write/replace failures and an external modification, including a write between validation and commit. Conditional writes reject the conflict; nonconditional replacement requires informed authorization or another destination. Dirty state follows the saved revision and failures preserve text/recovery. |
| EAP24       | Real Android document open/create, open-with, cancelled picker, revoked grant and unavailable provider. URI identities retain provider semantics; examples require no broad filesystem permission.                                                                                                                                                                                |
| EAP25–EAP26 | Save/Discard/Cancel through dirty close and multi-tab exit; interrupt immediately before/after durable-revision acknowledgment and between edit/checkpoint; fill recovery storage during an edit; corrupt/truncate one record and restart. Assert Q8's accepted loss/failure policy, no unrelated discard and no implicit writes to originals.                                    |
| EAP27–EAP28 | Inspect and export diagnostics with sentinel private text/path/preedit. Default export omits sentinels; capture either meets readiness for the named sample/settings or reports failure.                                                                                                                                                                                          |

Storage tests require an independent reference record of revisions and commit
outcomes. A round trip through the same encoder/decoder is insufficient for
file fidelity. Fault injection must assert forbidden writes did not happen,
not merely that some error was returned. Real Android-provider evidence is
required in addition to injected adapters.

## 5. Responsiveness and integrity

For EAP29–EAP30, run ASCII code, mixed Unicode and long-line workloads at
1 MiB and 10 MiB, plus a single 1 MiB line. Include cold open, sustained
typing, selection, scrolling, undo/redo, regex search and highlighting
backpressure. Measure an idle viewport to detect whole-document rebuilding.
Preserve deterministic workload seeds and operation counts.

Report cold-open time, memory/peak retained storage, input-to-submit and
observed input-to-display separately, CPU/GPU frame p50/p95/p99, deadline
miss counts, sample duration and refresh mode. Use assertion-preserving
shipping builds under the [build policy](../../guidelines/build-settings.md)
and [profiling guide](../../guidelines/benchmarking-and-profiling.md).
Log setup and font/catalog costs separately from warmed interaction.

A 120 Hz report must use an 8.33 ms budget and distinguish supported refresh
from achieved presentation. No fixed percentile or latency threshold is
inferred from the target: the workload experiment selects explicit thresholds
before an optimization can claim acceptance. Responsiveness failures remain
open evidence, not justification to remove the long-line workload.

Independent review covers high-risk state/lifetime, layout, IME and storage
changes and their final repairs. Review test discovery, fixture changes,
assertion/tolerance changes, `version(unittest)` paths and native build flags.
Missing tests, unavailable devices and skipped runs are not passes.

## 6. Evidence ledger

| Scope / requirements                | Checked source                                                                            | Check and result                                                                                                                                       | Remaining gap                                                                                          |
| ----------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| Requirements agreement, EAP1–EAP30  | Owner discussion Q1–Q22, 2026-11-05                                                       | Scope and command-palette test interfaces explicitly accepted                                                                                          | This is design authority, not implementation evidence                                                  |
| Existing integration baseline       | `02c2176e2e`                                                                              | Source inspection of UI editor/context/components, source-view code presentation, UI keymap/Lantern, terminal selection/menu and Android input adapter | No end-to-end app conformance claimed; see [decision blockers](./decisions.md#4-open-design-questions) |
| Opening comprehension               | Dirty six-file docs snapshot on `feat/editor-showcase`, based on `02c2176e2e`, 2026-11-05 | Fresh agent received only front matter, abstract and introduction; reread confirmed scope/ownership/tab/recovery clarifications                        | Comprehension review only; detailed contract checked separately                                        |
| Contract semantic review            | Same dirty docs snapshot, final requirement repairs reread on 2026-11-05                  | Independent read-only review found five policy gaps; final pass found no new material contradiction after dispositions below                           | Layout, storage and recovery policy blockers remain open; implementation unverified                    |
| Publication                         | Final docs worktree, 2026-11-06                                                           | Formatter and all applicable pre-commit checks pass; full site renderer passes, 2,791 HTML pages                                                       | Initial heap/Plug’n’Play failures and local remedy recorded below; implementation remains unverified   |
| Application conformance, EAP1–EAP30 | No app implementation                                                                     | Not run                                                                                                                                                | All implementation evidence unverified                                                                 |

Add results here with source revision or explicit dirty snapshot, command,
configuration, counts, artifacts and limits. Baseline inspection and owner
agreement do not upgrade application requirements to verified.

### Specification review dispositions

| Finding                                                                                 | Disposition                    | Contract / validation                                                                                                                                  |
| --------------------------------------------------------------------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Modal query focus could hide commands or redirect document edits                        | Fixed                          | EAP10 distinguishes invocation target from query focus; switching/closing targets has an explicit trace in §2                                          |
| Check/write race contradicted no-silent-overwrite on nonconditional providers           | Fixed                          | EAP23 requires operation-specific informed authorization or another destination; §4 injects a write between check and commit                           |
| Recovery had no durable-revision acknowledgment or loss boundary                        | Fixed in part; deferred policy | EAP26 distinguishes durable and edited revisions; Q8 blocks R implementation on owner-accepted loss/failure policy; §4 tests acknowledgment boundaries |
| Bidi collapse/extension/RTL Home/End policy could silently override shared UI semantics | Deferred with gate             | Q2 blocks U implementation until the owning UI contract and independent traces settle these cases                                                      |
| Mixed-ending fidelity omitted Enter/paste/replacement/join policy                       | Deferred with gate             | Q7 blocks file-fidelity implementation until owner policy and byte fixtures cover insertion/deletion and undo                                          |

The cold read clarified one pane versus split views, the shared editor's
package identity, the scope of recovery and TUI capability differences.
Recovering unsaved text/positions does not imply serializing branching undo
history across restarts; persistent undo history is not a requirement.

### Publication validation

On 2026-11-06, the final worktree passed formatting, EditorConfig, sidebar,
glossary, spec evidence, local/network links, pinned URLs and applicable
example checks. The in-tree CI tool checked 1,872 Markdown pages and
resolved 4,382 spec citations; these checks establish publication integrity,
not application conformance.

The initial `yarn docs:build` exhausted Node's default 4 GiB heap. A larger
heap retry completed source generation but encountered VitePress's
Plug’n’Play Vue symlink failure. With the generated assets retained, a local
`YARN_NODE_LINKER=node-modules yarn install --immutable` followed by
`YARN_NODE_LINKER=node-modules NODE_OPTIONS=--max-old-space-size=8192 yarn exec vitepress build docs`
passed in 208.85 seconds and generated all four editor pages. The local
install did not change committed Yarn configuration or lockfiles. Generated
source-listing dependency-selection edits were removed from the worktree.

### Palette core checkpoint — 2026-11-06

Checked dirty implementation snapshot on `feat/editor-showcase`, based on
`b5ea7fddd` over `755e1b9101`, core source blob
`b038f36ded098cec5900cc8a5dc1f9c6670c1a6c`. Eleven public-behavior tests in
`ui.command_palette.*` were developed as separate red→green slices: lifecycle,
catalog ownership/capacity, availability-filtered fuzzy ranking, acceptance,
navigation, invalidation, catalog replacement and witness/rejected-query behavior.
Review regressions additionally cover byte/normalization admission and all
512 default command slots under the worker stack budget.

`dub test :ui --compiler=ldc2 --skip-registry=all` passed 807 tests.
`dub run --single libs/ui/examples/command-palette.d --compiler=ldc2 -b checked --skip-registry=all`
printed `save on target 42`. The initial search crashed in a large stack
initializer through buffer growth; a debugger located the call and in-place
`base.Unique` initialization fixed the same public search test. The signed
navigation and stale catalog-index regressions were each observed failing
before correction.

A fresh cold read and bounded independent core review were followed by a
repair rereview. The admission finding was fixed with failing byte-length and
normalization-segment cases before preflight validation was added. The default
512-entry search first exceeded the 384 KiB worker budget; moving ranking and
output scratch into the heap owner made the same test pass. The final review
reported no remaining concrete core findings. The reviewer inspected code;
test execution counts are the implementer's recorded results.

These results cover core state/discovery only. Shared view/focus adapters,
effective shortcut agreement, native/TUI rendering and application integration
remain unverified and keep P open. No device, IME or performance result is
claimed by these tests.

### Shared palette frontend checkpoint — 2026-11-06

On the worktree based on `c3b3b8199`, the full `sparkles:ui` test suite passes
816 tests. New public-interface checks cover stamped activation, concrete
effective shortcuts, query keyboard lifecycle, composition before acceptance,
capacity refusal, rejected-edit effects, witness/query rendering and initial
preedit visibility. The shortcut-prefix, composition interception, hidden
preedit and rejected-edit-effect regressions were observed failing before
their repairs.

An independent read-only review reproduced four frontend defects with small
external harnesses. A repair review confirmed all four fixes and identified
one new rollback-effects inconsistency; the final regression clears effects
for a query edit that was refused. The review's bounded scope does not prove
backend hit routing or geometry parity. Native/TUI application replay, focus
restoration and live IME remain acceptance gates for P/U.

### Initial application shell — 2026-11-06

The new `apps/editor` package passes seven app/document tests, covering tabs,
palette dispatch, host key-table initialization, a chunked paste as one undo
revision, pointer placement from displayed frames, header/tab separation and
initial UTF-8/BOM/ending policy. These tests do not establish storage fidelity
or full editor conformance. The paste and native-startup/layout regressions
were each observed failing before their fixes.

The desktop application builds with `dub build :editor -b checked
--compiler=ldc2 --skip-registry=all`. Help/version run, and desktop Vulkan
captures show both the field/inspector and populated palette. An interactive
pseudo-terminal launch renders the shell and exits on a Kitty-encoded Ctrl+Q.
This is a TUI smoke check, not behavioral parity or performance evidence.
The Nix package enables stamping; the directly built executable reports the
expected unstamped `dev` version. Nix artifact/stamp validation remains open.

The shell refuses dirty exit pending Save/Discard/Cancel integration. Real
files, examples, highlighted presentation, generated settings, recovery,
Unicode layout and native IME still have open delivery gates.

### Background syntax and theme checkpoint — 2026-11-06

`sparkles:source-view` passes 54 tests, including source-addressed syntax under
selection/preedit, indexed window clipping, a 16,384-token dense line, latest
document/revision publication and a real D grammar through the worker path.
An independent read-only review found quadratic token intersection on the
frame thread; a monotonic syntax cursor repaired it, and the repair review
reported no further findings in its bounded ownership/publication scope.
Copy/setup/flatten cancellation timing remains unmeasured.

The editor's eight tests pass with background highlighting, editable examples
and theme preview/cancel/accept. The UI suite passes 818 tests, including
canonical theme discovery and clipboard request generations. A checked native
capture of the code example shows syntax and editor caret together. Running
outside a configured grammar environment correctly reports unavailable
highlighting; the successful capture used the native development shell's
grammar bundle. Generated settings, language discovery and complete Unicode
layout/IME remain unverified.

### Document insertion policy — 2026-11-06

The shared UI suite passes 822 tests after adding per-selection insertion.
Tests cover one undo transaction, length admission, protected spans,
composition-first coordinates and exception safety. An independent review
reproduced document loss from a throwing policy. `stepInPlace` now keeps the
move path for nonthrowing providers and publishes a copied step only on
success for throwing providers; the failing regression and independent repair
probe confirm text, selection and history survive. The checked example prints
`aAbcB` and then `abc` after one undo.

The editor's nine app/document tests pass, including Enter at two carets on
different line-ending conventions and exact BOM/mixed-ending bytes after
undo. Invalid UTF-8 leaves the active tab unchanged. A checked native build
also passes. This proves the in-memory admission/insertion envelope, not
desktop save atomicity, Android providers or recovery durability.

### Native storage primitives — 2026-11-06

The native POSIX adapter reads regular descriptors with `O_NONBLOCK` before
checking their type, so a FIFO does not trap a reader waiting for its writer.
Tests cover exact input bytes, bounded admission, directory/FIFO refusal,
ordinary permission preservation, symlink destination refusal and two
competing creators producing one complete winner.

Save writes a private temporary in the retained destination directory,
syncs/closes it, then commits through no-replace `linkat` for a new destination
or consent-gated `renameat` for replacement. A receipt distinguishes commit
from acknowledged directory durability. The event-horizon worker retains
captured text revisions, validates UTF-8/builds persistent text off-frame,
limits outstanding jobs to eight and delivers const results after completion.
The app/storage suite passed 15 tests before the CLI-open integration.

The checked [fault probe](../../../apps/editor/tools/storage-fault-probe.d)
and [fault runner](../../../apps/editor/tools/storage-faults.d) passed real
Linux syscall injection at all six stages: write (`ENOSPC`), temporary sync
(`EIO`), temporary close (`EIO`), replacement (`EACCES`), no-replace creation
(`EEXIST`) and directory sync (`EIO`). Every pre-commit failure asserts that
the original destination is unchanged or a new destination absent. Directory
sync failure asserts committed replacement bytes with `durable == false`.
The runner derives the temporary-close ordinal from a decoded baseline trace
and checks that the injected failure reached that descriptor.

An independent review found no storage/worker ownership defect in these
paths. Metadata comparison does not establish an atomic read snapshot under
concurrent in-place writers. Shutdown joins running filesystem calls and
retains completed receipts for polling after shutdown. The app still resolves
outstanding save acknowledgments before normal teardown.
Crash/power-loss durability, Save/Discard/Cancel UI and Android-provider
semantics remain open gates; syscall injection does not replace those tests.

The integrated app suite passes 17 tests, including real-file open with a
worker-prepared text root, preserved dirty tabs, failed UTF-8 admission and
retained palette targets. Checked desktop CLI checks reject nonexistent and
invalid-UTF-8 operands with exit status 1 before starting the rendering host;
an independent review identified and prompted the startup/runtime-error split.
A native capture of `document_text.d` confirms real-file text and syntax reach
the pane. Interactive open failures remain recoverable status messages.

### Native save workflow — 2026-11-07

The editor suite passes 21 tests. Save As accepts a path through the shared
single-line editor without inserting it into the document. Save captures a
text revision before background destination inspection; a completion records
that revision while later edits remain dirty. Existing destinations require
an operation-specific decision disclosing the validation/replacement race.
Tests cancel without modifying the destination, then change the destination
after inspection and explicitly authorize replacement of that captured
revision. Another tab cannot receive the decision. Dialog pointer actions
carry an opening generation, and the disclosure wraps at the available width.
Directory-durability warnings persist separately from transient status.

Open, Save, Save As and dialog actions use the common command table. The
theme prefix uses F4, preserving terminal Ctrl+K editing. App inputs now pass
monotonic timestamps to the editor; a regression test verifies that typing
separated by a one-second pause undoes as two groups. Native window-close
interception, dirty-close decisions, recovery and Android providers remain
open; these tests do not establish those capabilities.

### Dirty-close decisions and native close policy — 2026-11-07

The editor suite passes 24 tests, including per-document Cancel/Discard,
Save before exit with a captured-revision receipt, and failed Save retaining
dirty text and returning to a cancellable decision. Exit approval reached
from a worker completion is forwarded to the host from the next view.
Closing waits for pending file operations; successful writes with unconfirmed
durability return to the decision and retain a persistent warning.

The shared `requestAppClose` policy test proves deferred approval and the
immediate-close default for ordinary components. The Vulkan host routes both
its client-frame close action and window-system close event through this
policy. The editor hook uses its Quit command's Save/Discard/Cancel workflow.
The full host suite passes 148 tests in the native development shell. An
initial run outside the shell failed four existing font-fixture environment
assertions; the configured rerun passes them.

The checked [native close probe](../../../apps/editor/tools/native-close-probe.d)
starts its own Xvfb server and launches the real Vulkan editor. It inserts a
character, sends `WM_DELETE_WINDOW`, verifies the process remains alive,
cancels with Escape, requests close again and explicitly discards with D.
The editor exits successfully only after Discard. This exercises X11 event
translation and the live host loop. Repeat it after building the editor:

```sh
dub run --single apps/editor/tools/native-close-probe.d -b checked
```

Regressions also verify that overwrite consent returns to its captured tab
after a tab switch during inspection, that a repeated Enter cannot accept a
new decision, and that startup palette input adopts native editing keys.
The checked close-policy example prints `close deferred` then `close approved`.
Client-frame pointer-close, Wayland and Android lifecycle acceptance remain
separate from the X11 probe.

Recovery/session storage, abrupt interruption, native close during unavailable
surface startup, and Android provider guarantees remain open gates. The legacy
raylib host retains its old native-close behavior.

### Argon adversarial review follow-up — 2026-11-07

An `agy` review using `gemini-4-argon-medium` identified destructive modified
shortcut fallthrough, replacement of an empty tab with live save/history
ownership, loss of native key policy after closing the last tab, and ignored
native close requests during another decision. Regression tests reproduced
each issue before its fix. All 28 editor tests now pass. Modal modifiers use
the keymap's terminal-scope mechanism, so they still reach path-field editing
without reaching plain-letter Discard. Empty-tab replacement checks history,
save, composition and clipboard ownership. Reinitialization preserves the
host's selected editor target. Native close cancels transient path input or
promotes a pending tab/save decision to whole-application exit.

The review also identified misleading durability presentation and lost cleanup
warnings. A committed revision still records written bytes, while the status
now says Written with unconfirmed durability rather than Saved; the persistent
warning continues to block implicit close. Successful saves retain cleanup
warnings in status. Symlink and unreadable/over-limit destination refusal
remain conservative failures that preserve the document; no weaker write is
silently attempted when inspection fails.

The first review stopped producing output without a final report and was
interrupted. A second invocation with a five-minute limit returned the concrete
findings above. This review covers the file/close checkpoint, not the remaining
recovery, provider, Unicode or workload acceptance gates.

### Session record format groundwork — 2026-11-07

The editor suite passes 31 tests. `session_record.d` uses the shared wired
JSON codec behind a versioned header and a BLAKE3 digest of the payload.
Round-trip fixtures preserve Unicode text, BOM and mixed-ending metadata,
saved baselines, directed selections, the active document and theme. Writer
and reader validation refuse duplicate/zero document identities, missing
active documents, invalid primary selections, non-UTF-8 caret boundaries and
NUL-containing native paths. Tests reject every truncated prefix and every
single-byte corruption of a valid record. UTF-8 validation and hashing use
the existing SIMD-capable base implementations.

This is format groundwork only: the application does not yet write recovery
checkpoints, restore sessions, acknowledge durable recovery generations or
meet the one-second checkpoint gate. Background immutable-generation storage,
checkpoint scheduling, restart/error decisions and orderly-exit flushing
remain required before EAP26 can be accepted.

### Immutable recovery archive primitives — 2026-11-07

The editor suite passes 32 tests. `session_archive.d` appends immutable,
positive, numbered generations and refuses duplicate-generation replacement.
Reads validate the record digest, schema and generation/file identity. Both
writer and reader enforce the same 512 MiB encoded-record limit. The caller
must provide a private directory whose creation is already durable; archive
initialization, active-instance ownership and discovery are not yet wired.

The existing syscall-fault suite now passes eight cases. New recovery cases
inject temporary `fsync` failure before the second generation commits, and
directory `fsync` failure after it commits. Both assert that the earlier
generation still contains its original dirty text and that the source
document was not changed. The latter also verifies a committed second
generation with an unconfirmed-durability receipt. These tests establish the
archive primitives' ordering; they do not establish app checkpoint cadence,
power-loss behavior, restore decisions or session flushing at exit.

### Recovery directory ownership groundwork — 2026-11-07

The editor suite passes 34 tests. `SessionDirectory` creates a private archive
and syncs its ancestor chain up to an explicitly supplied, already durable
platform namespace root. It refuses paths outside that root. A restricted
ancestor fixture proves that initialization needs no read access above the
root, as required for Android's private storage. This is a Linux filesystem
test; it does not establish Android device acceptance.

Directory `flock` leases distinguish active owners from claimable archives;
creation and claim serialize against the registry directory. The checked
[owner probe](../../../apps/editor/tools/recovery-owner-probe.d) launches a
separate owner process, writes and acknowledges a dirty generation, verifies
that another process cannot claim it, kills only that probe-owned process,
and reclaims/reloads its dirty text. The original document remains unchanged.
Repeat it with `dub run --single apps/editor/tools/recovery-owner-probe.d -b checked`.
This tests process interruption after a filesystem acknowledgment; power-loss,
application scheduling, startup offers and orderly-exit integration remain open.

The document model now lives in `editor_document.d`, independently of the UI
component, which re-exports it for callers. The record's editing-state format
is version 2: it additionally preserves boundary affinity, vertical goal
columns, protected intervals and native-save durability warnings. Unknown
fields are refused, and the earlier version-1 prototype is reported as
unsupported and preserved. No application recovery writer used that prototype.
Round trips cover the richer metadata; caret validation also refuses positions
inside combining sequences or CRLF graphemes. All 34 editor tests pass.

### Captured sessions and background checkpoint writer — 2026-11-12

The editor suite passes 37 tests. `SessionSnapshot` retains persistent text
roots and copies selection/constraint metadata without flattening document
contents. Its sealed capture remains unchanged after later document edits;
serialization into the record happens on the CPU worker. GC arrays contain
class references or numeric metadata, never reference-counted Text values.

`CheckpointWriter` keeps one running write and one latest desired snapshot.
Tests drive continuous edits every 10 ms and verify submission at the original
250 ms deadline. An older receipt advances the durable revision without
claiming later input; explicit flush submits the latest state. The writer
tracks observation revisions separately from immutable file generations,
retains failures until a successful durable receipt, and exposes overdue
updates without claiming a hardware latency guarantee. Shutdown drains
accepted work and publishes receipts before releasing the directory lease;
newer unsubmitted input still requires explicit flush.

The checked [checkpoint probe](../../../apps/editor/tools/checkpoint-fault-probe.d)
and [fault runner](../../../apps/editor/tools/checkpoint-faults.d) inject a real
directory `fsync` failure in the writer thread. Generation 4 remains committed
but unconfirmed, durable revision 3 remains acknowledged, and retry of the
same observation uses generation 5 before acknowledging revision 4. The
verifier associates split unfinished/resumed strace lines by thread and checks
that the injected operation names the archive directory. An Argon Medium
adversarial review reported no confirmed findings in this bounded worker and
snapshot scope.

Application wiring, archive retention, startup recovery offers, exit flushing
and actual one-second/device acceptance remain open. The app does not yet
enable checkpoint writes to user state directories.

### Acknowledged-generation retention — 2026-11-13

The editor suite passes 39 tests. Archive cleanup retains the two newest valid
generations at or below a supplied durable cutoff. It preserves corrupt,
unsupported, symlinked and newer unacknowledged entries. A fixture with five
generations and a damaged second generation verifies that only the oldest
valid acknowledged record is removed. Canonical filename tests reject
unrelated entries and integer overflow. Deletion is best effort: reappearing
older files after interruption cannot invalidate the newer durable records.
Cleanup requires an owned directory lease; scheduling it away from the
rendering thread remains part of application integration.

### Application recovery service and exit flushing — 2026-11-13

The editor suite passes 42 tests. `RecoverySession` initializes its private
archive on a maintenance worker, retains edits observed during initialization
and submits the newest captured state to `CheckpointWriter`. Retention runs
on the maintenance worker independently of serialization. Shutdown joins
maintenance before closing the checkpoint writer's archive lease.

An explicitly configured `EditorApp` displays current and durable recovery
revisions and a persistent failure/overdue warning. Deliberate exit waits
for the captured session's durable receipt. A real initialization failure
leaves exit cancellable and offers Retry or Exit without recovery; bypass is
unavailable until the failure decision has been presented. Tests verify
successful exit flush, failure cancellation and explicit bypass. Saving a
dirty file during whole-application exit now retains its saved tab for the
session, while explicit Discard still removes the chosen document.
An Argon Medium review prompted explicit successful-initialization/error
guards on exit and invalidation of the displayed failure decision after
Retry; a queued Discard cannot reuse that decision before another frame.

This is recording-host and native-filesystem evidence. CLI startup does not
yet enable user-state writes: startup discovery/restore offers must be wired
first. Abrupt rendering-host teardown, Android lifecycle behavior and the
one-second latency bound on actual devices remain acceptance gates.

### Background discovery and prepared restore state — 2026-11-13

The editor suite passes 45 tests, and the checked Vulkan build succeeds.
Discovery scans immediate archive directories on the maintenance worker,
skips live owners and holds a lease for every outstanding offer. A second
application instance cannot offer the same leased archive. A damaged newest
generation falls back to the newest valid older one without changing either
the damaged file or the source document. A valid empty generation prevents
resurrection of older tabs.

Restore offers prepare document objects on the worker, preserving saved-byte
baselines, BOM/line-ending conventions, selection affinity and goal columns,
scroll positions, protected intervals, language and durability warnings.
Tests verify these independently specified values. Application offer controls
and adoption ordering remain open; CLI user-state writes remain disabled.

### Recovery adoption ordering — 2026-11-13

The editor suite passes 46 tests. Accepted offers remain leased until a new
archive durably acknowledges the captured restored state. Only then does a
maintenance job install an exact-generation adoption marker. The marker is
itself synced before retirement is acknowledged; retry re-syncs an existing
valid marker. Damaged markers and every original generation remain intact.
Unknown or damaged markers cannot silently suppress an offer.

A before-deadline interruption leaves the source archive offer available on
restart. After a successful new checkpoint and adoption, discovery offers
only the destination archive, with the restored bytes; the source generation
is still readable. Adoption failures remain visible and retryable. Application
Restore controls and CLI startup wiring remain open.
The requested additional Argon Medium adoption review could not run because
`agy` returned `RESOURCE_EXHAUSTED` (individual quota). It remains outstanding;
the earlier runtime review does not cover adoption markers.

### Native restore controls and desktop startup — 2026-11-13

The editor suite passes 48 tests. Restore is reachable through the common
command policy, palette, F4 R guide path and a three-row touch control.
Cancelling leaves current edits and the offer intact. Accepting merges
prepared tabs under fresh identities, retains edits made during discovery,
and converts a duplicate open path into an unsaved copy. Tests verify that
the copy cannot save over the other open tab and that disk bytes are unchanged.
The viewport reserves rows for recovery controls and warnings.

Desktop CLI startup now enables recovery under
`$XDG_STATE_HOME/sparkles/editor` (fallback `$HOME/.local/state/sparkles/editor`).
`--state-dir` selects a registry; `--no-session` disables session access.
Screenshot runs omit recovery unless a state directory was explicitly supplied.
CLI help and the checked Vulkan build pass.

The expanded [native probe](../../../apps/editor/tools/native-close-probe.d)
uses a private Xvfb server and temporary registry. It types `a`, observes a
valid checkpoint, kills only its own editor process with SIGKILL, starts a new
instance, accepts Restore through F4 R and Enter, then types `b`. A new valid
checkpoint contains `ab`, proving the real controls restored both text and
caret. Native close defers dirty closure; Escape retains the draft; explicit
Discard flushes the retained session state and exits with status zero. This
is process-interruption evidence, not a power-loss or Android acceptance test.

That probe exposed hit testing of an empty final view after asynchronous
quit. `hoverTargets` now returns no targets for an empty tree; its focused
tests and all 823 UI tests pass, and the live round trip succeeds afterward.
Argon Medium's adoption/full-flow review remains blocked by its quota.
TUI EOF, nonvetoable host teardown, Android lifecycle, recovery resource
bounds and actual one-second/device latency remain open.

### Terminal close policy and host teardown — 2026-11-13

The editor suite passes 50 tests. Its shutdown hook captures edits that have
not reached another view pass, attempts a final checkpoint, and returns
unrecoverable checkpoint failure to the CLI when no interactive surface is
available. An explicit Exit without recovery decision is retained through
shutdown and does not become a later CLI failure. Tests cover both success
and initialization failure without changing the source text.

Ungrabbed terminal Ctrl+C now uses the same optional application close hook
as native closure. The real [PTY probe](../../../apps/editor/tools/tui-close-probe.d)
verifies dirty-close deferral, Escape cancellation and Ctrl+Q/Discard with a
clean exit. This probe first exposed terminal software flow control swallowing
Ctrl+Q and Ctrl+S. A private-PTY regression also caught CR translation and
high-byte stripping. Raw terminal setup now preserves those input bytes and
restores original termios flags on closure. All 49 TUI tests, including the
new byte/restore test and existing PTY integrations, pass.

All 148 host tests pass. The checked Vulkan build and native SIGKILL/Restore/
dirty-close probe pass with the new shutdown path. These tests cover orderly
host return and live terminal interrupts; they cannot run a shutdown hook
after SIGKILL or prove Android activity destruction or power-loss durability.
Recovery resource bounds, device latency and the quota-blocked Argon review
remain open.

### Desktop checkpoint cadence and Nix artifact — 2026-11-13

The checked [cadence probe](../../../apps/editor/tools/recovery-cadence.d)
attempts edits every 8 ms for two seconds, then flushes the latest revision.
On an AMD Ryzen 9 7940HX / x86-64 host with a ZFS temporary filesystem,
the [captured results](./results/2026-11-13-recovery-cadence-before.csv) show
maximum observed ages of the oldest unacknowledged state of 276 ms (1 MiB,
80-column lines), 319 ms (10 MiB, 80-column lines) and 500 ms (1 MiB single
line), with zero overdue samples. The process's cumulative peak RSS across
all three sequential fixtures was 255,672 KiB. Reproduce with
`dub run --single apps/editor/tools/recovery-cadence.d -b checked`.

The long line permitted only 16 edits in two seconds: maximum insertion time
was 121 ms, compared with below 0.1 ms on the regular-line fixtures. A 499 Hz
user-space perf profile of `--single-line` identifies per-grapheme text-tree
lookups/copies and width/boundary scans in `LogicalContext.columnOf`, called
for the IME caret rectangle after edits. This is an unresolved editor latency
finding, not checkpoint-write latency or renderer/FPS evidence. The probe
does not draw frames or establish Android or archive-count resource bounds.

`nix build .#editor --no-link` succeeds at `addd8d7a9`. The installed
`editor --version` emits stamped JSON identifying `sparkles:editor`, version
0.1.0, build type `checked`, commit `addd8d7`, and `dirty: false`, together
with dependency component versions.

### Complete cluster widths and bulk caret-column queries — 2026-11-13

The profile led to two shared editor fixes. Width measurement now reads the
complete borrowed cluster rather than copying at most 32 bytes: a variation
selector after forty combining marks still determines the cluster's width.
Logical column/position queries iterate text chunks and reuse the base
library's printable-ASCII classifier, including its guarded AVX2/SSE2 paths
on x86. They finalize safe ASCII runs in bulk while leaving the last starter
for the owned Unicode grapheme and presentation rules. Other targets retain
the classifier's scalar fallback. Literal escape bytes retain editor-text
semantics, and an ASCII keycap starter remains joined to its selectors.

The same host/filesystem's [after results](./results/2026-11-13-recovery-cadence-after.csv)
show the 1 MiB single-line maximum edit time falling from 121,065 to 1,044 µs;
227 edits completed instead of 16. Maximum observed ages of unacknowledged
state were 276, 323 and 274 ms across the three workloads, with zero overdue
samples. Cumulative process peak RSS was 255,880 KiB. The optional
`--edit-budget-us=8000` guard fails before this change and passes afterward.
It is an explicit local CPU budget, not a timing test imposed on every CI host.

All 826 UI tests, 50 editor tests and 21 selected base grapheme tests pass;
the checked Vulkan build succeeds. These measurements cover editing and
checkpoint modules; full app drawing, bidi/wrapped layout, device acceptance
and recovery archive-count bounds remain required.

### Clipboard request ownership — 2026-11-13

The editor suite passes 53 tests and the UI suite passes 827 tests; the
checked Vulkan build succeeds. Outgoing clipboard reads now receive distinct
app-wide identities retaining the original document, palette ticket or dialog
epoch and field-local request. Replies are translated back before reaching
the field. Tests verify delayed replies to two tabs, a closed requester, a
duplicate stale reply and document/path-dialog ID collisions. The Save As
fixture writes only the intended path and preserves the document contents.

The shared field helper accepts an optional request mapper and supports
declining a read without leaving a valid pending answer. Existing callers
retain identity mapping. Tracking is bounded to 64 live reads and identities
are never reused within the app lifetime; inability to track a read is surfaced.

Inspection confirms that Vulkan currently offers clipboard writes but lacks
a read errand. Recording-host read scenarios therefore establish owner policy,
not native clipboard acceptance. Native read plumbing and a delayed X11
provider scenario are the next input slice; Wayland/Android parity also remains
required.

### Native clipboard delivery — 2026-11-13

The Vulkan host now offers asynchronous clipboard reads and one increasing
request namespace shared by its input consumers. Eight independently retained
transfers are bounded to 16 MiB each; only complete valid UTF-8 is delivered.
Malformed, oversized or failed transfers complete without inserting a prefix
and expose a diagnostic without clipboard contents. Teardown cancels sink
references before releasing their buffers. Offers received during initial
window configuration remain available to the application.

The checked Vulkan build passes, alongside 151 host tests, 828 UI tests and
53 editor tests. Adapter tests cover reversed completion order, malformed and
oversized payloads, capacity rejection and cancellation. The shared input
helper test checks host-wide identities across independent fields and rejects
answers after synchronous read failure.

The private X11 provider in
`dub run --single apps/editor/tools/native-close-probe.d -- --clipboard`
holds two real selection requests and answers the second before the first.
The resulting durable checkpoint contains `from A` and `from B` in their
respective tabs; the process then completes explicit discard/exit with status
zero. This proves the native read path as well as app ownership. Transfer
timeouts, provider withdrawal/reuse, Wayland and Android acceptance remain
separate input gates; a stalled provider currently occupies one bounded slot.

### Palette command context — 2026-11-13

Global theme acceptance now uses the same availability policy as palette
discovery rather than rejecting every command after a tab change. A regression
first reproduced a preview that looked accepted but reverted on the next
palette opening. The repaired flow accepts the theme and restores the command
catalog. Save, Save As, tab closure and editing remain bound to the captured
document; switching tabs before accepting Save As cannot open a path dialog
for the new document. All 55 editor tests pass.

### Installed language discovery and manual overrides — 2026-11-13

The language picker uses the shared command policy through F4 L or Choose
language in the palette. Registry discovery runs on an event-horizon worker
in `sparkles.source_view.language_catalog.LanguageCatalog`. It uses the same
parser/query search precedence as highlighting and also understands the
soname layout's extracted queries. No parser library is loaded for listing.
Discovery rejects more than 511 names or 8,192 scanned entries instead of
silently truncating the catalog; filesystem failures remain visible.

Plain text is immediately available. Installing the completed registry
catalog preserves the opening ticket and the typed query. Acceptance changes
only the captured tab's language; cancellation, file contents, saved baseline
and line endings are unchanged. The inspector includes the selected language.
The shared palette now uses the specified 512-entry capacity and search
prompts that identify the current catalog.

All 57 editor, 56 source-view and 125 syntax tests pass, as do the two selected
shared palette-view tests. Registry fixtures check sorting/deduplication,
first-parser query precedence, missing parser/query files, soname discovery
and explicit capacity failure. App tests cover accept/cancel and a query
entered before real bundle discovery completes. The source-view README's
runnable example verifies successfully. The checked native build succeeds;
an Xvfb Vulkan `--example code --languages --shot` capture shows installed
language rows and the explicit Plain text choice. This is desktop input/view
evidence; Android packaging and IME/provider acceptance remain open.

### Displayed frame ownership — 2026-11-13

Three app regressions first reproduced stale pointer routing through an old
rendered frame. A document edit could move the caret using older source
offsets; closing an earlier tab could make a visible tab target the wrong
document; opening Save As could route an old document click into the new path
input. A further phase reproduced stale path offsets after typing between
frames.

Paint now retains the displayed document identity, source snapshot, tab IDs,
dialog epoch and path snapshot alongside its actual widget tree and frames.
Document/path source hits require matching bytes, dialog transitions reject
older hits, and tab activation resolves the displayed ID among live tabs.
A freshly painted document remains selectable. All 60 editor tests pass.
These checks preserve the current logical-line renderer's ownership boundary;
shared bidi/wrapped layout, preedit geometry and live IME acceptance remain
open under U.

### X11 withdrawn-provider isolation — 2026-11-13

The private-provider regression first checkpointed `xSTALE PROVIDER` in the
replacement tab: a late `SelectionNotify` reused the newer sink's property.
The X11 backend now gives each wire conversion a private requestor window
and keeps wire slots separate from generational sink IDs. Cancellation
releases sink references immediately; remaining packets are discarded.
Capacity pressure can retire canceled requestor windows without evicting a
live read or allowing late packets to name its replacement.

Expanding the scenario to eight provider changes exposed permanent wire-slot
exhaustion; the repaired scenario reaches the ninth read, rejects two old
replies and checkpoints only the current provider's text. A focused own-copy
probe also exposed queued requests to retired windows and older ownership-loss
notifications invalidating a newer accepted offer. Both paths now preserve
the current transfer without protocol errors.

All 66 WSI tests pass and the checked editor build succeeds. The native
`x11-clipboard-probe.d` passes all four shared clipboard properties with
32 MiB `INCR` streaming, then nine cancellations followed by a successful
own-clipboard read. The editor's `--clipboard-withdrawal`, `--clipboard` and
default SIGKILL/Restore/dirty-close probes all pass on private X11 servers.
The focused lane is independently runnable from the
[X11 clipboard reference](../../libs/wsi/reference/x11-clipboard.md).

An attempted full X11 hosted smoke stopped at its outside-pointer-release
assertion before reaching clipboard checks. Its unrelated pointer/IME lanes
are not counted as passing here. Wayland/Android input and full editor layout
acceptance remain open; these X11 checks make no device performance claim.

### Shared visual-motion context boundary — 2026-11-14

The generic editor stepper now consumes optional `horizontalCaret` and
`lineBoundaryCaret` queries returning a `CaretTarget` with source byte position
and affinity. Contexts without those queries retain the existing logical
grapheme, selection-collapse and smart-Home behavior. The stepper keeps the
logical anchor on extension and preserves a visual query's returned affinity.

Two tests first failed under logical-only movement, then passed through the
new queries. A fixed layout for the Hebrew run in `ab אב` requires visual
Right from byte 5 to byte 3, visual collapse and extension from the existing
logical anchor. A wholly RTL `אב` row requires Home at logical EOF (byte 4)
and End at byte zero. These are worked source/visual examples at the generic
step seam, not output derived from the implementation under test.

All 830 UI tests and 60 editor tests pass, and the checked Vulkan build
succeeds. The runnable `visual-carets.d` example prints Home byte 4 and End
byte 0 for the fixed RTL row. This is preparation for U:
`EditorField` still embeds `LogicalContext`, and real-font layout, wrapped
row/vertical affinity, shared rendered geometry, touch and live IME remain
unimplemented acceptance work. It does not establish bidi rendering in the app.

### Cell-grid paragraph layout and shared row geometry — 2026-11-14

`sparkles.ui.editor.layout` lays out each logical line as one bidi
paragraph on the toolkit's cell grid. Base supplies UAX #9 paragraph and
line levels, UAX #14 opportunities, grapheme boundaries and cluster widths;
the layout wraps greedily, lets white space hang and orders each row's
clusters with L2. `LayoutContext` answers every editor query from it.
Vertical motion now resolves the head's row with its affinity and accepts
`caretColumn`/`caretAt`, so a caret at a soft wrap keeps its drawn row.

Worked examples, independent of the implementation's output, fix the
expected answers. `ab אב` draws Bet before Alef with clusters at bytes
0, 1, 2, 5, 3. Byte 3 is stop 3 with `before` and stop 5 with `after`; EOF
draws at Bet's left edge. Visual Right from byte 2 visits (3, before),
(5, after), (3, after), then stops at the row's edge; Left returns through
(5, before), (7, before) and (2, after). In `א 12` the digits keep their
order left of Alef. `א(ב)` mirrors both brackets; `a(b)` mirrors none.
`aaa bbb ccc` at 7 cells wraps after the second space, and `世界世界` at
5 cells wraps by cells. `aaa bbb\nc` at 4 cells crosses the soft wrap
without resting twice on byte 4, and the logical break lands at byte 8 after.
An RTL row's Home and End are bytes 4 and 0; an LTR row keeps smart Home.

`visualRows` projects a line's logical, highlighted or selected spans onto
those rows, drawing carets at their affinity's stop. In the application,
`EditorFieldOf!LayoutContext` drives documents. The view wraps at the host
width less the caret cell, scrolls by visual rows and records drawn rows with
the wrap width. Pointer placement resolves through `layoutColumn` and
`caretAt`, after the existing revision check and a wrap-width check. App
tests click column 2 of the second wrapped row (byte 19) and then move Up to
byte 2. They draw `ab אב` as `▏ab בא`, resolve drawn cell 5 to byte 5, and
move visually Right to byte 3.

These results establish cell-grid bidi/wrapping for the editor's drawing,
hit-testing and motion. They do not establish shaped proportional flow,
cross-cluster Arabic joining in the GPU renderer or live IME placement.
Real-font device acceptance and touch handles also remain open. Cluster
order, not a fixture image, is the oracle: no screenshot is claimed.

### Independent layout review and repairs — 2026-11-14

A fresh read-only `agy` session (Argon Medium, plan mode) reviewed commits
`80f7f5223` and `7659d4d10` and reported thirteen findings. Each was
re-derived from the code before repair; each repair has a regression test
named `editor.layout.review.*`, `editor.view.visualRows.compositionHidesSelection`
or `editor.step.layoutRows.killAndAddCursor`.

Confirmed and repaired: the IME area aborted on a scroll origin past
deleted lines; X9-removed clusters (ZWSP, word joiner) split right-to-left
runs; a lone CR, NEL or U+2029 inside a line disabled bidi for the line, so
each paragraph separator now ends a separately resolved paragraph; no click
could reach the logical end of `ab אב`, so a click now takes the clicked
cluster's side of an ambiguous stop. Backward selections collapsed to the
wrong edge. Held Right bounced between an LTR and an RTL line, so crossing
lines now follows document order. A row after a soft break could exceed the
width. A preedit over a selection shifted hits by the hidden text. Kill-line
and add-cursor ignored the caret's wrapped or RTL row, and the IME area
ignored affinity. The wheel scrolled logical lines, and the wrap width
ignored the root padding. Scrolling and the IME area laid out every line to
a distant caret and now lay out at most a viewport. Smart Home left an
all-blank row and reported a no-op as motion.

Policy, not defect: End on a mixed LTR row goes to the visual right edge
(EAD9), not the logical end, and Shift+Right extension follows visual stops
from the fixed logical anchor. A byte at a bidi soft wrap may be visited at
two distinct cells; the doc comment that claimed otherwise was corrected.
The plan's claim that the app uses IME rectangles was an overstatement: the
area is computed but not yet delivered to the host.

855 UI and 62 editor tests pass after the repairs.

### Caret area delivery to the window system — 2026-11-14

The caret's drawn cell now reaches the window system. After each paint the
editor computes the primary caret's cell from the painted rows. It uses the
layout column, the inserted cells before it and a preedit's cursor, then
calls the host's `textInputArea`. The native host converts cells to device
pixels from the cells' origin, and the Wayland backend sends
text-input-v3's `set_cursor_rectangle` in surface-local units. It resends
the rectangle with each `enable` on text-input focus. The app test
`editor.app.textInputAreaFollowsDrawnCaret` checks the reported cell after
the bidi stop in `ab אב` and after `に` inside a preedit. The editor asks
for text input once, and again only after the text is tapped. This is
plumbing evidence; candidate placement with a live input method on GNOME
and Android remains the EAP20 gate.

### First Android device run — 2026-11-14

`nix build .#editor-apk-debug` packages the editor's `android` configuration
(native Vulkan arm, no terminal) with the desktop bundle's faces. On the
Xiaomi Pad 8 Pro (`15006456`, Android, landscape), the editor launches as a
NativeActivity with tabs, the layout-backed field and the Unicode example;
right-to-left lines draw in visual order.

The first run found three device defects, each repaired. Android sets no
`HOME`, so the recovery namespace root was `/`, which SELinux denies
(`avc: denied { read } … name="/"` once a second). The entry now sets `HOME`
to the app's private directory. Recovery publication then failed: the app
sandbox denies `link` on `app_data_file` (`avc: denied { link }`), which the
create-only commit used. `saveAtomic` now commits with
`renameat2(RENAME_NOREPLACE)`, which is equally atomic and refuses
replacement, and keeps `linkat` only where the flag is unsupported. The
existing competing-creator and fault tests pass through the new path. After
reinstalling, the device reports "Recovery revision 1 / 1", writes
`files/sessions/<id>/…01.session` and logs no link denial.

Hebrew, Indic, Thai and CJK lines drew nothing, on the desktop as well as
the device: the native cell font consulted only three fallback faces. It now
appends every regular face of the font sources, memory-mapped: the
`--font-dir` faces, or fontconfig's `monospace` order. Desktop and device
captures then draw every line of the Unicode example. Proportional
script faces draw narrower than their cells; per-script monospace selection
and sizing remain with generated fonts (plan item 2).

This is a launch, rendering and recovery-write check. Live IME on Android,
touch handles, keyboard insets with a soft keyboard (the tablet's keyboard
cover registers a hardware keyboard) and provider documents remain open.

### Live desktop input method on GNOME Wayland — 2026-11-14

The checked Vulkan editor ran on the owner's GNOME Wayland session with
`WAYLAND_DEBUG=client`; IBus served text-input-v3. Keys were injected with
`ydotool` only while the protocol log showed `wl_keyboard.enter` on the
editor's surface. Excerpts from the client log:

- typing `ab ` sent `set_cursor_rectangle(40|50|60, 138, 10, 24)`: one
  10-pixel cell right per character, at the drawn caret;
- IBus Unicode entry (Ctrl+Shift+U, `5d0`) delivered
  `preedit_string("u5", 2, 2)`, `("u5d", 3, 3)`, `("u5d0", 4, 4)`. The
  editor answered with rectangles at x 80, 90 and 100, following the
  preedit's cursor;
- Space delivered `commit_string("א")` and an empty preedit. The next
  rectangle was x 60, the visual left edge of the right-to-left letter,
  where the logical end after it is drawn;
- a second entry (`5d1`) cancelled with Escape delivered an empty preedit
  and no `commit_string`, and the rectangle returned to x 60.

This establishes live preedit update, commit, cancellation and caret
rectangle delivery through a real input method on desktop Wayland. GNOME
denies Shell screenshots to this client, so no screen image was captured.
Candidate-window placement needs a candidate-producing engine; this session
has US and Bulgarian layouts only. Pinyin/Anthy candidates, X11 (no XIM
client exists) and Android's live IME remain open under EAP20.

### The caret as the host's cursor — 2026-11-15

Moving the caret moved text: the inline `▏` glyph took a cell, so every
character after the caret shifted by one as it moved. The document field
now uses the host's text cursor (ui-app `HST20`, adopted from `feat/fsx`):
no glyph is inserted and spans are not cut at the caret, and the caret's
row carries the drawn column in `caretColumn`. The terminal places its own
cursor there with the user's shape and blink, and the native arm paints a
bar in the theme's caret colour. A secondary caret marks its grapheme as a
block, and wrapping no longer reserves a column for the caret.

`editor.app.caretMovesNoCharacter` steps visual Right through `abc אב`
and the next line. Every frame draws byte-identical text, and the cursor
column walks 0 to 6 through the right-to-left pair.
`editor.view.visualRows.hostCursor` checks the projection: no glyph, the
primary column, a secondary block. A native Vulkan capture of `hello world`
shows the bar over the first cell, with the text starting at the row's
left edge. The IME rectangle now reads the same column as the drawn cursor.

### Code-editor presentation — 2026-11-16

The document pane now draws the `EAP5` presentation, each part behind its
own `View` command in the palette (`PresentationSettings`): a line-number
gutter (the shared `withGutterCells` strip, the caret's number in the
primary text slot), the caret's line on the raised surface, indentation
guides at each stop of a line's leading spaces, the bracket at the caret
and its partner (an unmatched one in the error slot), and trailing
whitespace other than the run the caret is typing. The status bar names the
caret's line and grapheme column, the selection count and the language.

The library carries the reusable parts: `markSpans` paints source ranges
over plain or highlighted spans and keeps syntax ink and selections
(`editor.view.markSpans`); `drawIndentGuides` replaces only leading spaces
with a one-cell glyph, so no text moves and hits are unchanged
(`editor.view.indentGuides`); `matchingBracket` matches by nesting within a
byte budget and reports a scan that ran out as undecided
(`editor.presentation.matchingBracket`); `trailingWhitespace` excludes a
CRLF's carriage return (`editor.presentation.trailingWhitespace`).
`editor.app.codePresentation` draws all five parts, then turns each off and
checks the text is unchanged and the gutter's cells are gone. Brackets are
matched by bytes, not syntax: one inside a string or comment counts.

### Undo-history inspector — 2026-11-16

The inspector (F12, or the Inspect chip) lists the active document's undo
tree beside its counters: up to six revisions in creation order around the
current one, each naming the revision it was made from, its text length and
whether it is a branch point, indented by depth. A press on a row travels
there with the shared editor's `earlier`/`later`, so the move is an
ordinary history step; a row drawn for another document is ignored. The
tree comes from text-buffer's `History.revision` (`TXB-HIS7`).
`editor.app.undoInspector` types, undoes and types again, checks the
listed rows name the branch point, then presses the abandoned revision and
gets its text back.

### Indentation, auto-indent and line comments — 2026-11-16

The shared editor's indentation options, auto-indent and line comments
(ui `EDC12`, `EDC13`) are applied to the active document before each
command and frame (`EditingSettings`): spaces by default at width 4, with
palette commands for tabs, widths 2/4/8 and auto-indent. Enter goes through
`newlineEach`, so the document's line-break convention and the line's
leading blanks arrive as one undo step. The comment token comes from the
document's language and follows a manual override; a language without one
(Markdown, plain text) leaves the command a no-op. Indentation guides use
the chosen width. `editor.app.indentationAndComments` indents, keeps the
indent across Enter, comments and uncomments a D line, switches to tabs and
checks a Markdown document is unchanged by the comment command.

### Find and replace — 2026-11-16

A find bar (Ctrl+F, or F4 F in a terminal, where Ctrl+F stays Readline's)
and its replace row (Ctrl+H, F4 H) sit above the document. Both fields are
shared single-line editors; while the bar is open it holds the keyboard
(the `find` scope; document keys are not reachable), application commands
still work, and Escape returns the keyboard to the document. The switches
`.*`, `Aa` and `W` (Alt+R, Alt+C, Alt+W) choose regular-expression,
case-sensitive and whole-word matching. Enter and Shift+Enter (also F3 and
Shift+F3 from the document) select the next or previous match, wrapping;
on the replacement field Enter replaces and moves on; Ctrl+Alt+Enter
replaces every match as one undo step; Alt+Enter selects every match as
multiple carets and closes the bar. Matches are painted as marks, counted
as `2 of 5`, and a pattern error is shown in place of the count, leaving
the text unchanged. Matching, the work bounds and replacement are the
shared `sparkles.ui.editor.search` (ui `EDS1`–`EDS6`); the bar recomputes
only when the text, query or a switch changes, within the default search
budget, and reports a truncated result as `10000+`. A clipboard reply
reaches a bar field only while that bar (its epoch) and field are current.

`editor.findBar.refresh` covers the cached result and its summary.
`editor.app.findAndReplace` types a query into the bar, checks both matches
are painted, steps with Enter, switches to the replacement with Tab,
replaces all, undoes once to restore both, checks an invalid regular
expression edits nothing, and returns the keyboard with Escape.

### Generated settings, persisted with the session — 2026-11-16

The settings pane (Ctrl+, or F4 , in a terminal; also in the palette) is the
shared `SettingsPane` over one subject, `EditorSettings`, so its rows,
labels, bounds and edit history come from `PropertyTree` rather than a
hand-drawn form: the View section is `PresentationSettings`, the Editing
section `EditingSettings` (indentation width bounded to 1–16). Edits apply
to the running editor at once, and the palette's View and Editing commands
change the same values. While open the pane holds the keyboard, pointer and
paste; Escape returns them to the document. Font controls join this
subject with the font catalog (plan item 2).

The accepted settings are part of the recovery session (`EAP26`): session
records are now version 3, carrying `SessionSettings`, and bind their
header into the BLAKE3 digest, so a damaged version byte cannot pass a
version 3 record off as version 2. Version 2 records still decode, with the
shipped settings, and a width outside 1–16 is refused. Restoring a session
restores its settings.

`editor.settings.generatedTree` checks the generated sections and that an
out-of-bounds width is refused; `editor.settings.sessionRoundTrip` that the
stored form converts exactly and the shipped defaults agree;
`editor.sessionRecord.settingsAndVersion2` the round trip, the version 2
upgrade and the width bound (the existing every-byte corruption test now
also covers the header); `editor.app.generatedSettings` opens the pane,
toggles line numbers from it, closes it and types into the document.

### One host cursor, in the focused field — 2026-11-16

The palette's query, the Open/Save path field and the find bar's fields now
use the host's cursor too (`PaletteViewOptions.hostCursor`; an empty field's
placeholder puts it at column 0 with no glyph), so no text moves with the
caret anywhere in the app. Each frame carries one cursor: the document's
rows carry their caret column only while the document has the keyboard,
and the input-method caret area follows the same rule.
`editor.app.fieldsUseTheHostCursor` opens the palette and the path dialog,
types into each, and checks the tree holds no `▏` glyph and exactly one
cursor, at the focused field's column.

### Document workloads — 2026-11-16

`editor.workload.documents` (`dub test :editor -b bench -- --bench -i
editor.workload`) opens a 1 MiB and a 10 MiB source file and a 1 MiB single
line through the real app on the recording host (120×40 cells), and times
each phase separately: opening, the first frame, the median of 15 steady
frames, an edit in the middle with its frame, and a find-next with its
frame. Its first run exposed whole-document work on every frame: the
scroll extent laid out every paragraph, the viewport's row index every
line above it, the draw loop bypassed the layout cache, and the status bar
walked the caret's line by grapheme. Fixed: rows before each line are
counted once per text and wrap width (`rowPrefix`), a line that provably
fits one row is counted without a layout, the draw loop reads the layout
cache and projects only the rows on screen, and the column is counted once
per text and caret. Wall milliseconds, `bench` build, this x86_64 host:

| Document       | Open | First frame | Steady frame | Edit + frame | Find + frame |
| -------------- | ---: | ----------: | -----------: | -----------: | -----------: |
| 1 MiB source   | 11.5 |         7.5 |         0.59 |          6.2 |         10.3 |
| 10 MiB source  | 58.7 |        49.2 |         0.61 |         50.2 |         10.1 |
| 1 MiB one line |  6.4 |       530.4 |         0.85 |        293.0 |        168.6 |

Before the fixes the 1 MiB file's steady frame took 1964 ms and the 10 MiB
file's 19 339 ms (debug build). What remains is per-edit work: an edit
recounts every line's rows (about 50 ms at 10 MiB), and an edit in a 1 MiB
line lays out and highlights the whole paragraph again (about 0.3 s). Both
miss a 120 Hz frame; incremental row counts and windowed span production
are the next steps, and no 120 Hz claim is made. Input latency,
presentation and GPU time on a device are measured separately.

### Document font: choice, controls and persistence — 2026-11-16

The document font is a setting (`DocumentFont` from `sparkles.font.families`:
family, size, ligatures, line height, letter spacing, weight and optical
size, each bounded) in the generated settings pane and the recovery
session, and `--document-font FAMILY` sets it at startup. "Choose document
font" lists the default face and the discovered monospace families through
the palette's fuzzy ranking; "Choose document font (all families)" is the
explicit show-all. Discovery and loading run on `FontLibrary`'s workers
(`DocumentFontService`); the chosen family's real regular, bold and italic
members are loaded and the inspector names what it lacks ("no italic, no
weight axis"), so unsupported controls are visible.

Not yet delivered: drawing the document in that face. A headless capture
(Xvfb, lavapipe) with `--document-font "DejaVu Sans Mono"` loaded the
family, and the document's pixels matched the default capture exactly. The
native host draws a specimen face only inside a scope an application opens
in its own paint, at its own cell size; the editor draws through the
widget tree on the interface's cell grid. The service therefore stops at
loading and says so ("loaded, not yet drawn"), and the host is not asked to
prepare a face nothing draws with. Drawing a widget subtree in the document
face with its own cell metrics is a ui/ui-app change, tracked in plan
item 2. Outside the development shell, platform discovery found no
families on this NixOS host (fontconfig is loaded at run time); the Nix
package needs fontconfig on its library path before that capture can be
repeated from the package.

`editor.documentFont.unsupported` checks the visible list of missing
controls; `editor.documentFont.discoverAndLoad` discovers families, loads a
monospace one, does not reload it, and reports an unknown family;
`editor.app.fontPicker` picks a family and then the default face again;
`editor.settings.sessionRoundTrip` now covers the font fields.

### Unicode corpus through the app — 2026-11-16

`editor.app.unicodeCorpusReplay` opens one line per §3 corpus category
(Latin NFC/NFD and stacked marks; Greek and Cyrillic; Arabic with digits and
brackets; Hebrew with marks; Devanagari, Bengali, Tamil, Telugu, Sinhala;
Thai, Lao, Khmer, Myanmar, Tibetan; kana with dakuten, Hangul, BMP and
supplementary Han; historic supplementary scripts; emoji presentation,
modifiers, ZWJ, flags, keycaps and a tag sequence) in the real app, at one
row and wrapped at 12 cells. Its oracle is base's grapheme segmentation of
the raw bytes, not the layout under test: every source byte is drawn
exactly once across the rows; walking Right and Left from the line's start
stops only on grapheme boundaries and reaches all of them, except that a
line with right-to-left text may skip a boundary at a direction-run edge,
where visual movement collapses two logical offsets into one stop (EAD9);
and inserting at each boundary changes exactly that boundary and one undo
restores the line. Font coverage is not part of this oracle: a missing
glyph is a font fixture, not a navigation defect.
