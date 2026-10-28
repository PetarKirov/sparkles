---
status: accepted
owner: sparkles:base
reviewed: 2026-10-27
---

# `sparkles.base.text.edits` — Text edits

## Abstract

`sparkles:base` describes a change to a text as a list of byte-range
replacements, validates that list, streams the edited text into any writer,
and maps positions from the original into the result. It is the one edit
vocabulary that formatters, structured-document editors and language-server
responses share, and it works without the garbage collector.

## Introduction

Several tools change text they did not write: the D formatter reports its
output as edits so an editor can apply them without losing the cursor; the
SDL editor ([lossless editing](../../wired/sdl/editing.md)) rewrites only
the bytes a recipe change touches; a language server answers with edits. Each
needs the same three things — a range and its replacement, a guarantee that
the ranges do not collide, and a way to carry an offset across the change —
and today the formatter owns a private copy that allocates its result.

The approach is a value type pairing a `TextSpan` (`sparkles.base.text.span`) with
borrowed replacement text, plus functions over sorted lists of them. The
replacement text is borrowed, not owned: the producer keeps it alive in its
own buffer, so a list of edits costs one small record per change and no
copies.

Out of scope: computing edits from two texts (the formatter's line diff
stays in `sparkles:diff` and `sparkles:dmd-fmt`), line/character
coordinates for a protocol (a language server converts at its boundary with
a line index), and collaborative merging of concurrent edit lists.

## Contract at a glance

| ID   | Obligation                                                               |
| ---- | ------------------------------------------------------------------------ |
| TXE1 | A list is valid only if sorted by start, in bounds, and non-overlapping  |
| TXE2 | Writing a valid list emits the source with exactly those ranges replaced |
| TXE3 | Insertions at one offset apply in list order                             |
| TXE4 | Offset mapping is monotonic and clamps inside a replaced range           |
| TXE5 | Every operation is `@safe pure nothrow @nogc` over a caller's writer     |

## 1. Requirements

A `TextEdit` is a `TextSpan` range of the original text and a borrowed
replacement. An empty range is an insertion; an empty replacement is a
deletion.

**TXE1 — Validation.** A list is valid when every range is a valid span
within the source length, starts are non-decreasing, each range ends no
later than the next one starts, and at one start every insertion precedes
the non-empty range that starts there. So an insertion before `[x, y)` is
listed before it, and an insertion at `y` after it. Validation reports the
first offending pair by index. _Violation:_ a list accepted with an overlap,
an out-of-bounds range, or an insertion listed after a range starting at
its offset.

**TXE2 — Application.** Writing a valid list emits, in order, the source
before the first range, its replacement, the source between ranges, and so
on, then the source after the last range. Nothing else is emitted.
_Oracle:_ a reference implementation by concatenation, compared over
generated lists. _Violation:_ any output byte that differs.

**TXE3 — Same-offset insertions.** Several empty ranges at one offset are
valid and apply in list order; an empty range at the start or end of a
non-empty range is not an overlap, and applies before or after it as TXE1
orders it. _Violation:_ reordered insertions.

**TXE4 — Offset mapping.** Mapping an original offset yields the
corresponding result offset: offsets before a range shift by the
accumulated length change; an offset inside a replaced range maps to the
same distance into its replacement, clamped to the replacement's end. At
an offset where insertions apply, the position lands after all of them by
default — the behaviour of the formatter's `mapCursor` today, whose tests
pin it — and before them when the caller asks. The mapping is monotonic.
_Violation:_ two offsets whose images invert their order, or a default that
differs from `mapCursor` on its tests.

**TXE5 — Attributes.** Validation, application into any output range that
is itself `@safe pure nothrow @nogc`, and mapping carry those attributes;
application infers attributes from the writer. _Oracle:_ a `@safe pure
nothrow @nogc` test over a non-GC buffer. A `@betterC` test is not the
oracle: extraction compiles one module, and `TextSpan`'s members live in
another.

## 2. Consumers

- `sparkles:dmd-fmt` replaces its private `TextEdit` (`start`/`end` as `uint`,
  GC-owned `newText`) with this type; its `applyEdits` and `mapCursor`
  become calls to TXE2 and TXE4. Its line-diff computation stays.
- `sparkles:wired`'s SDL editor resolves every operation to these edits.
- `apps/ci`'s in-tree dependency rewrite moves onto the SDL editor and so
  onto these edits.

## 3. Delivery

This page is owned by `sparkles:base` and delivered as one slice: the type,
TXE1–TXE5 with their oracles, and dmd-fmt's migration, in which dmd-fmt's
tests pass unchanged. It is scheduled as the first half of the SDL
backend's [S12](../../wired/sdl/PLAN.md), its first consumer; it does not
depend on any other part of that plan, and the base text
[delivery plan](./PLAN.md) does not track it.
