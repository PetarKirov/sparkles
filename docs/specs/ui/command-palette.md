---
status: accepted
owner: sparkles:ui
reviewed: 2026-11-06
---

# Command palette

## Abstract

The shared command palette presents application commands as a searchable list
on every interactive backend. Its state owns query, selection and invocation
identity; it emits commands and focus requests for its host to perform. The
palette and Lantern use the same application command policy, so searching for
a command and following its shortcut cannot disagree about the action or its
availability.

## Introduction

A key guide helps users browse related commands, while a palette helps users
find a command by name. Both must know which actions can run, which document
they act on and which shortcuts are effective. Independent command lists drift
when modes, documents or bindings change.

The palette separates deterministic behavior from host effects. Opening records
an opaque invocation target and return-focus identity. Its query field takes
keyboard focus without becoming the target of the selected document command.
The host supplies command policy and performs the emitted effects. Neither
windowing nor an application's document types enter the state model.
The invocation target stays fixed for an opening; acceptance checks its live
availability again, and old session events cannot act on a later opening.

This contract owns palette behavior, not application command meanings or
keyboard normalization. [Keymap and Lantern](./keymap.md) own bindings and the
guide. [The editor application](../editor/SPEC.md#3-commands-palette-and-key-guide)
requires a palette alongside that guide. Delivery progress and evidence live
in [the editor plan](../editor/PLAN.md) and
[verification page](../editor/testing.md#2-command-palette-tdd).

## Contract at a glance

1. Commands are identified by operation and argument, independently of shortcut.
2. Invocation targets and query focus are distinct identities.
3. An opening has a nonzero session ticket; old tickets cannot close or execute
   commands in a later opening.
4. The palette emits effects; it performs no document, clipboard, focus, clock
   or platform I/O.
5. Explicit capacity/validation failure preserves the last usable state.

## 1. Lifecycle

**PAL1: Open and cancel.** Opening **must** return a fresh nonzero ticket and
record the invocation target and return-focus identity. Cancellation of the
active ticket **must** close that opening and emit its recorded invocation
without a command. The host validates the requested focus and selects a valid
fallback surface if the origin no longer exists.

**PAL2: Old and duplicate events.** Cancellation or acceptance for a closed or
different session **must** produce no execution or focus effect. Opening a
second session **must** invalidate the first. Session-counter exhaustion
**must** reject another opening without wrapping to an earlier ticket or
destroying the active session.

## 2. Command policy and bounded storage

**PAL3: Identity and availability.** A command identity **must** include its
operation and argument. Shortcut bindings are references to identities, not
the only command catalog: commands without shortcuts remain discoverable.
The caller supplies one live availability policy used by dispatch and both
discovery frontends. Query-field focus **must not** replace the captured
invocation target. Acceptance revalidates that target and command.

**PAL4: Capacity rejection.** Catalog and query capacities **must** be explicit
positive bounds. The initial integration uses at most 512 commands and 256
UTF-8 query bytes; callers may select different compile-time bounds. Every
admitted catalog command **must** be reachable in the result list. Oversized
catalogs, duplicate command identities, invalid UTF-8 queries and oversized
query replacements **must** fail explicitly and preserve the prior catalog,
query, selection and session. Results **must not** be silently truncated to a
viewport-sized subset.

Label admission **must** honor the shared matcher's byte and Unicode-analysis
limits in the case policies used by palette queries. The default engine
permits at most 4,096 label bytes and a normalization segment of 64 units.
A label outside these limits **must** be rejected before replacing usable
catalog/results state, even if it is valid UTF-8 and its command is unavailable
in the immediate context.

Catalog metadata **must** retain immutable labels independently of the caller's
mutable descriptor-array storage. Returned view slices are borrowed until the
next mutating palette call; hosts retain no such slices across mutations.
Successful catalog replacement invalidates old result indices until a search
with a fresh context publishes replacement rows; the selected command's
identity is retained for that publication. Acceptance during this interval
emits no command.
Emitted command/focus identities own their values and remain valid after the
palette closes. Synchronous bounded matching is the initial mechanism; any
asynchronous adapter must also tag query/catalog revisions and reject stale
results before publication.

**PAL5: Discovery and acceptance.** Query edits **must** use shared fuzzy
matching with witness highlighting and deterministic tie ordering. Effective
shortcut labels **must** follow shared keymap resolution, including shadowing
and command arguments. Context/catalog changes retain selection by identity
when available, otherwise select a valid result. Empty-result acceptance
**must** emit no command. Successful acceptance **must** close the opening and
emit exactly one command identity and invocation target.

**PAL6: Touch activation.** On a pointer that cannot hover, a press on a
row **must not** activate it. A drag that travels the slop vertically, and
more vertically than sideways, **must** pan the result list and activate
nothing. Only a release within the slop of its press **may** activate the
row under it, or dismiss the palette on its close box or outside it.

## 3. Verification boundaries

Lifecycle tests observe opening/closing, tickets and effects; discovery tests
observe available identities, ranking and labels; integration tests observe
the shared view's focus, rows and activation on recording, TUI and Vulkan.
These three interfaces were owner-approved in the editor requirements review.
Tests **must** be added as individual red→green behavior slices. No private
storage assertion substitutes for an observable lifecycle or command effect.
