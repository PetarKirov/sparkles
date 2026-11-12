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
