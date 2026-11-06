---
status: accepted
owner: sparkles:editor
reviewed: 2026-11-05
---

# Editor application — Decisions

The owner accepted these scope choices in requirements rounds Q1–Q22 on
2026-11-05. The [contract](./SPEC.md) owns obligations, the
[plan](./PLAN.md) owns progress and [testing](./testing.md) owns evidence.
Acceptance of a choice does not establish feasibility or implementation.

## 1. Practical editor over shared mechanisms

**Decision EAD1 — accepted.** Build a usable editor with an optional inspection
surface, rather than a disconnected collection of editing demos. One active
document pane with tabs keeps focus, selection and dirty-document policy
understandable. Split panes, project navigation, LSP and plugins are excluded.

The alternative was a lab-only surface with disposable samples. Real files,
save failures, recovery and platform input provide stronger pressure on the
shared libraries. This choice increases host/storage work; those obligations
remain explicit rather than being treated as presentation details.

**Decision EAD2 — accepted.** Vulkan is the production window path, with
desktop, Android and TUI required. Raylib may exercise backend independence
but is not a production prerequisite. Standard `core-cli`/`ui-app` startup,
logging and stamped identity avoid another app-specific framework.

**Decision EAD3 — accepted.** Reuse the UI editor/text buffer, source-view
highlighting, shared themes and generated property settings. Extract useful
Hue mechanisms when needed by the editor; do not undertake a whole-Hue
rewrite. Revisit extraction scope only when an actual second consumer or
dependency restriction makes the shared interface insufficient.

## 2. Two command-discovery frontends

**Decision EAD4 — accepted.** The fuzzy command palette belongs to `libs/ui`
alongside the which-key-inspired Lantern guide. Both consume shared command
policy and configurable bindings. Operation plus arguments identifies an
action; shortcut identity alone does not. The palette must include unbound
commands, so enumerating raw bindings is insufficient as its only catalog.

An independent app-specific palette would duplicate context gates, shortcut
labels and discovery semantics. Existing `Binding`, `bindingsAt`, `LanternState`
and shared picker state supply reusable mechanisms. The
[shared palette contract](../ui/command-palette.md) settles Q1's initial
identity/storage rules: operation plus a 64-bit argument, opaque invocation
target and return-focus IDs, session tickets, immutable labels retained by
value, and explicit rejection above compile-time catalog/query bounds. The
initial editor integration uses 512 commands and 256 query bytes. Acceptance
rechecks live availability against the captured target. Shortcut integration
must still demonstrate agreement with effective keymap resolution before P
closes.

The owner approved TDD through three public interfaces: state transitions,
command discovery and shared view integration. The first implementation cycle
starts with one public lifecycle behavior, not an entire speculative suite.

## 3. Shared layout, touch and real platform behavior

**Decision EAD5 — accepted.** One shared layout supplies visual bidi carets,
wrapped navigation, hit-testing, drawing and input-method positioning. A
renderer-specific movement patch would create disagreement about document
positions. Logical word/document semantics remain those of the shared editor.

**Decision EAD6 — accepted.** Reuse terminal touch-selection behavior through
shared extraction. `apps/terminal/src/selection_menu.d` contains handle
geometry, menu placement and edge-scroll behavior as well as a terminal-bound
controller. `SelectionUi` depends on terminal/workspace types; moving it
wholesale into the editor is not reuse. Shared geometry/gesture behavior takes
layout/end-point information and effects; terminal and editor adapters retain
their own selection models and application actions.

**Decision EAD7 — accepted.** Real native composition and Android system
document access are required. Composition conversion tests do not establish
live CJK input, and provider URIs do not imply filesystem save semantics.
Host/platform improvements are within scope. The feasibility questions below
bound their design before integration, without waiving the requirements.

**Decision EAD8 — accepted.** Preserve UTF-8 file fidelity, dirty text and
recovery across failures. Atomic replacement and conditional conflict checks
depend on the adapter. A weaker provider guarantee must be disclosed, not
presented as equivalent to desktop atomic replacement. Recovery is local
session behavior; synchronization and collaborative conflict merging are
excluded.

**Decision EAD9 — accepted, 2026-11-06.** The owner selected visual Left/Right
collapse, fixed-anchor Shift extension and visual left/right Home/End on all
wrapped rows. Logical word/document operations keep their semantics. This
settles Q2's selection policy; the shared layout/context interface still needs
feasibility evidence.

**Decision EAD10 — accepted, 2026-11-06.** Enter follows the current line's
ending, then the document's predominant ending, then LF. Paste/replacement
preserve supplied endings; untouched mixed endings remain intact. This settles
Q7. Convention-aware Enter uses generic inserted text rather than redefining
the shared editor's LF command.

**Decision EAD11 — accepted, 2026-11-06.** Dirty-buffer recovery checkpoints
complete within one second after edits, with a separately visible durable
revision. Storage failure permits continued editing with a persistent warning;
orderly exit flushes or asks how to proceed. This settles Q8's loss/failure
policy without claiming that unacknowledged edits are already durable.

## 4. Open design questions

These questions concern engineering choices, not permission to omit accepted
features. The owning implementer resolves each with the bounded experiment
and records the decision before closing the affected delivery gate.

| Question                                                                                                                                                                                                       | Owner / affected obligations                                                 | Resolution point                                                                                                     |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Q1: What descriptor exposes unbound commands, invocation targets, context and operation+argument identity while sharing effective keymap policy? What are query/result storage limits and exhaustion outcomes? | `sparkles:ui`; EAP8–EAP11                                                    | Core identity/storage resolved in EAD4; effective-keymap and shared-view proof remain P acceptance gates             |
| Q2: What shared layout/context API represents visual affinity, soft wraps and revision identity?                                                                                                               | `sparkles:ui`, text/font layout and rendering owners; EAP17–EAP19            | Movement/collapse policy accepted in EAD9; layout API and hand-derived traces remain U gates                         |
| Q3: What host/platform changes deliver live composition and candidate geometry on the actual desktop and Android input methods?                                                                                | `sparkles:ui-app`, `sparkles:wsi`, Android adapter; EAP20                    | Real-IME experiment before claiming native composition                                                               |
| Q4: Which storage operations provide conditional replacement, atomicity and grant retention? What is the race behavior where no conditional write exists?                                                      | Editor storage policy and platform adapter; EAP21–EAP26                      | Adapter experiment before F; recovery format/commit ordering before R                                                |
| Q5: Which work, queue, history/recovery and regex limits bound resource use and cancellation latency for the agreed workloads?                                                                                 | Shared editor, syntax/search and app owners; EAP7, EAP13, EAP26, EAP29–EAP30 | Resource/workload experiment before respective limits are shipped; measured thresholds before performance acceptance |
| Q6: Which shared highlighted-line and decoration interface preserves syntax under selections/preedit while virtualizing long documents?                                                                        | `sparkles:source-view`, `sparkles:ui`; EAP12–EAP13, EAP17, EAP29             | Highlighting/layout experiment before H; validate Hue's affected consumers                                           |
| Q7: How is the accepted newline convention implemented without changing generic LF insertion?                                                                                                                  | Editor document policy and shared editor owner; EAP7, EAP21                  | Policy accepted in EAD10; byte fixtures must cover insertion and undo, not just no-op saves                          |
| Q8: How are one-second checkpoints scheduled and acknowledged during continuous editing?                                                                                                                       | Application owner and storage adapter; EAP26                                 | Policy accepted in EAD11; report durable revision and test interruption before/after acknowledgment                  |

The source inspection at baseline `02c2176e2e` found logical-line field
contexts, separately generated code/editor spans, terminal-specific touch
controllers and Android committed-text input without a live preedit path.
These observations identify integration risks, not accepted algorithms or
claims that every target has the same limitation. Recheck the code before
resolving each question.
