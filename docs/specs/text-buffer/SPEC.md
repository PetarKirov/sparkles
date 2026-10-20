---
status: draft
owner: sparkles:text-buffer
reviewed: 2026-10-21
---

# `sparkles:text-buffer` — Specification

## Abstract

`sparkles:text-buffer` holds editable text as persistent values. A text is
a balanced tree of small UTF-8 chunks whose nodes cache sums such as byte,
line and UTF-16 counts, so locating a line or converting a position takes
logarithmic time however large the text grows. Copying a text is constant
time and every edit returns a new text that shares all untouched structure
with the old one, so an editor can keep every past version for undo, hand a
snapshot to a background highlighter, and compare two versions cheaply. The
package also describes edits as values that can be applied, inverted,
composed and used to move positions, and keeps a branching undo history
over them. It allocates without the garbage collector and depends only on
`sparkles:base`.

## Introduction

An editor's state changes on every keystroke, yet much of the program wants
to look at that state without being disturbed by the next keystroke: undo
needs the text as it was, a syntax highlighter or a differ reads a version
while the user keeps typing, and a test wants to compare the state before
and after a command. The cheapest way to satisfy all of them is to make
each version of the text a value that never changes once built. Building a
whole new string per keystroke makes that value cost proportional to the
document; a mutable buffer avoids the cost but takes away the values.

Production editors resolve this in one of two ways, compared in
[decisions](./decisions.md#txd-1): a gap buffer or piece table that mutates
in place and logs inverse operations for undo, or a persistent tree whose
versions share structure. Editors built around immutable state — CodeMirror
6, Zed, Helix and xi-editor — use the persistent tree, and each caches
per-node sums so that "which line holds byte 40 000" or "how many UTF-16
units precede this position" is answered by descending the tree rather than
scanning it.

This package takes that approach. A [summary tree](../../glossary.md#summary-tree)
of chunks, each a bounded number of bytes, stores the text; each internal node
stores, beside each child, the sum of that child's measures. Nodes are
reference-counted and never modified once a text refers to them, so copying a text increments
one count and an edit copies only the nodes on the path to the change. An
edit is described independently of any text, as a _change set_ that says
which byte ranges of the old text are kept, deleted or replaced. A change
set applied to the text it was made for yields the new text; inverted
against that text it yields the edit that undoes it; and it maps any old
position to its new place, with an _affinity_ deciding which side of an
insertion the position lands on. The undo history is a tree of such change
sets, so undoing and then editing creates a branch instead of discarding the
undone work.

The package does not know about cursors, selections, keys, grapheme
clusters or display. Selections and editing commands belong to the
[editor model](../ui/editor.md) in `sparkles:ui`, which is built on this
package. Unicode segmentation, including the grapheme and word
boundaries an editor moves by, belongs to
[`sparkles:base`'s text contract](../base/text/SPEC.md#4-segmentation-and-unicode-algorithms),
which reads a text through the chunk access this package provides (§3).
Collaborative editing — merging concurrent edits from several replicas —
is out of scope: positions can be mapped through a change set, but one
change set is never transformed against another.

Sections 1–2 define vocabulary and the text value, §3 chunk and position
access, §4 change sets, §5 the history tree, and §6 ownership, threading
and resource limits. [The delivery plan](./PLAN.md) is the sole milestone
tracker, [testing](./testing.md) defines the oracles and records evidence,
and [decisions](./decisions.md) records the alternatives considered.

## Contract at a glance

1. A text is a [Regular](../../glossary.md#regular-type) value: copies are independent, `==` compares
   contents, and copying is O(1).
2. A text's contents never change; every operation that "modifies" a text
   returns a new one and leaves its argument intact.
3. Every operation is `@safe nothrow @nogc` and weakly `pure`, and stays within the
   stated complexity bounds; allocation failure is fatal, as it is for
   `sparkles.base` buffers.
4. A chunk boundary never falls inside a well-formed UTF-8 sequence, and
   malformed bytes are kept exactly as given.
5. A position is a byte offset. Converting another unit into a point
   inside a well-formed UTF-8 sequence, and mapping a position that sits
   exactly where an insertion happens, each take an explicit affinity.
6. A change set applies to any text of its source length; applying it to
   a text of another length is a programmer error. Applying a change set to
   a text and then its inverse, computed against that same text, yields
   that text exactly.
7. History never discards a branch implicitly; pruning is an explicit
   operation with a stated bound.

## 1. Vocabulary

Normative **must**, **must not**, **should**, **should not** and **may**
carry [BCP 14](https://www.rfc-editor.org/info/bcp14) meanings.
Requirement IDs beginning `TXB-` belong to this specification. API names
are proposed shapes; the implementation settles D naming without weakening
an operation.

A _text_ is a finite byte sequence, normally UTF-8. A _position_ is a byte
offset in `[0, length]`, naming the gap before the byte at that index. A
_chunk_ is a contiguous run of a text's bytes stored in one leaf. A
_measure_ is a quantity defined for every byte sequence and additive under
concatenation, such as byte count or line-feed count; a node's _summary_ is
the tuple of its measures. A _line_ is a maximal run of bytes not containing
U+000A LINE FEED; a text with _k_ line feeds has _k_ + 1 lines, numbered
from 0. A line's _end_ is the position before its terminating line feed,
or before the U+000D CARRIAGE RETURN when one immediately precedes that
line feed, so a line end is never between CR and LF. _Affinity_ is `before` or `after`: the side of an ambiguous boundary
a position belongs to, as in [the base text maps](../base/text/SPEC.md#62-typed-coordinates-and-affinity).

## 2. The text value

**TXB-TEXT1: Value semantics.** A `Text` **must** be a Regular value
([`PRN6`](../ui/principles.md)): copying, assignment and destruction are
defined; two texts compare equal exactly when their byte sequences are
equal; and no operation on one copy is observable through another. Copying
**must** be O(1) and allocation-free.

**TXB-TEXT2: Persistence.** `replace(text, from, to, inserted)`, `slice`,
`append` and their derivatives **must** return a new text and leave every
argument unchanged. A result **must** share every subtree of its arguments
that the operation did not have to rewrite.

_Rationale:_ Sharing is what makes keeping every version affordable. A
correct implementation that copies whole texts would pass a functional test
and fail the purpose, so testing measures sharing directly (TXB-TEXT6).

**TXB-TEXT3: Chunk boundaries.** No chunk boundary **may** fall between the
bytes of a well-formed UTF-8 sequence, or between a U+000D CARRIAGE RETURN
and a following U+000A LINE FEED. Malformed bytes **must** be stored
unchanged; each one is a boundary candidate on its own. Every chunk except
a text's only chunk **must** hold between `minChunk` and `maxChunk` bytes,
where `minChunk` ≥ 8 and `maxChunk` ≥ 2 × `minChunk`, so a legal cut
always exists in any window of `minChunk` bytes (a UTF-8 sequence spans at
most 4 bytes and CR LF 2).

_Rationale:_ Keeping sequences whole lets every leaf be decoded on its own,
and keeping CR LF whole means no line-feed count or grapheme step sees a
pair split by storage. Graphemes may still span chunks; segmentation
handles that through §3 rather than through chunking.

**TXB-TEXT4: Summaries.** Every node **must** carry, for its whole subtree,
at least: bytes, Unicode scalars, UTF-16 code units, line feeds, and the
byte length of the last line. Malformed input **must** count as the
replacement characters [`TXT-UTF2`](../base/text/SPEC.md#2-encoding-operations-and-progress)
would produce: one scalar and one UTF-16 unit per maximal subpart. Summaries **must** equal the measures of the
subtree's bytes; a mismatch is a broken invariant, not a recoverable error.

**TXB-TEXT5: Complexity.** For a text of _n_ bytes, `replace`, `slice`,
`append`, and conversion between any two summary coordinates **must** be
O(log _n_) node visits plus O(`maxChunk`) bytes scanned inside one chunk.
Tree height **must** stay O(log _n_) with a fan-out between `minFanout` and
`maxFanout` per internal node, the root excepted.

**TXB-TEXT6: Sharing bound.** An edit that replaces a range of _m_ bytes
with _k_ bytes **must** allocate O(log _n_ + (_m_ + _k_) / `minChunk`) new
nodes; every other node of the result is shared with the source.

**TXB-TEXT7: Equality.** `==` **must** return `true` without reading bytes
when both operands share a root, and **must** skip shared subtrees that
occupy the same byte range in both operands.

## 3. Chunks, positions and conversion

**TXB-POS1: Chunk iteration in both directions.** A text **must** expose
its chunks as borrowed `const(char)[]` slices in either direction, starting
from the chunk containing any position, with each chunk's start position.
A borrowed slice **must not** outlive the text it came from
(`-preview=dip1000` enforced). Starting a walk **must** cost O(log _n_)
and each further step O(1) amortized.

_Rationale:_ This is the chunked-source capability the base text steppers
consume ([`TXT-SEG8`](../base/text/SPEC.md#43-boundaries-from-an-arbitrary-position)),
so grapheme and word motion work on a text without copying it or adding a
dependency from `sparkles:base` to this package.

**TXB-POS2: Coordinate conversion.** A text **must** convert between byte
position, scalar index, UTF-16 index and (line, byte-in-line) for every
valid input, and report an error value for an out-of-range input.
Converting a scalar or UTF-16 index that falls inside a sequence's
encoding, or a byte position inside a sequence, **must** take an affinity
and snap to that side's boundary.

**TXB-POS3: Lines.** A text **must** answer `lineCount`, the start and end
position of line _i_, and the line containing a position, within the
TXB-TEXT5 bounds. A position equal to a line's end belongs to that line.

## 4. Change sets

A change set describes an edit from texts of one length to texts of
another. It is a sequence of sections over the source, each either
_retain n bytes_ or _replace n bytes with an inserted text_ (a deletion
inserts the empty text, an insertion replaces 0 bytes), covering the whole
source. Adjacent sections of the same kind are merged, so each edit has
exactly one representation.

**TXB-CHG1: Construction.** `ChangeSet.of(sourceLength, edits)` **must**
accept edits `(from, to, inserted)` in source coordinates, in any order.
Edits whose replaced ranges overlap or touch a range strictly inside
another **must** form one group: the group replaces the union of their
ranges with their inserted texts concatenated in order of `from`, ties in
the order given. Insertions at the same position outside any replaced
range **must** appear in the order given. An edit with `from > to` or
outside `[0, sourceLength]` **must** be rejected with an error value.

_Rationale:_ A multi-cursor command produces one edit per range, all in the
coordinates of the text the command saw. Two cursors whose word kills
overlap must delete the union once, not fail or delete twice.

**TXB-CHG2: Apply.** `apply(text)` **must** require `text.length ==
sourceLength` (a contract) and return the edited text in
O(_s_ × log _n_ + inserted bytes) for _s_ sections.

**TXB-CHG3: Invert.** `invert(source)` **must** return the change set that
maps `apply(source)` back to `source`: `invert(c, t).apply(c.apply(t)) ==
t` for every `c` and every `t` of `c`'s source length.

**TXB-CHG4: Compose.** For `a` from length _L₀_ to _L₁_ and `b` from _L₁_
to _L₂_, `a.compose(b)` **must** satisfy `a.compose(b).apply(t) ==
b.apply(a.apply(t))` for every `t` of length _L₀_.

**TXB-CHG5: Position mapping.** `mapPos(p, affinity)` **must** map a source
position to the result: a position inside a retained run moves by the net
length change before it; a position strictly inside a replaced range maps
to the start of the replacement under `before` and its end under `after`;
a position at either edge of a replaced range, including the single
position of a pure insertion, maps to the start of the inserted text under
`before` and its end under `after`. A `trackDeletion` mode **must**
additionally report whether the position lay strictly inside deleted bytes.

**TXB-CHG6: Mapping composes away from edits.** For every `a`, `b` and
affinity `s`, and every position `p` that lies inside a retained run of
`a` and whose image `a.mapPos(p, s)` lies inside a retained run of `b`,
`a.compose(b).mapPos(p, s) == b.mapPos(a.mapPos(p, s), s)`.

_Rationale:_ Composition forgets how an edit was split: deleting [2, 5) and
then inserting at 2 composes to the same change set as inserting at 2 and
then deleting the next three source bytes, yet the two map position 5
differently. The law holds exactly where no edit touches the position.

**TXB-CHG7: Touched ranges.** A change set **must** enumerate its replaced
ranges in both source and result coordinates, in order. This is the
"changed range" signal a consumer re-highlights or re-diffs from.

## 5. The history tree

The history is a tree of revisions, generic over a caller-supplied state
type `S` (an editor stores its selection). The root is the text the history
was created with. Every other revision records the change set from its
parent, that change set's inverse, the caller's state before and after the
edit, and a timestamp. Exactly one revision is _current_. A history is a
Regular value; copying one **must** be O(1), its revisions shared until
either copy changes.

**TXB-HIS1: Commit.** `commit(change, inverse, before, after, time)`
**must** add a child of the current revision, make it current, and make it
its parent's _redo child_. Existing children **must** be kept.

**TXB-HIS2: Undo and redo.** `undo` **must** return the current revision's
inverse and its `before` state and make the parent current; at the root it
**must** return `nothingToUndo` and change nothing. `redo` **must** return
the redo child's change set and its `after` state and make it current;
with no child it **must** return `nothingToRedo` and change nothing.

**TXB-HIS3: Amend.** `amend(change, inverse, after, time)` **must** fold an
edit into the current revision: its change set becomes the composition of
the old one and `change`, its inverse the composition of `inverse` and the
old inverse, its `after` state and timestamp the new ones, and its
`before` state is kept. At the root, or when the current revision has
children, it **must** return `notAmendable` and change nothing.

_Rationale:_ Coalescing typing into one undo step is the editor's policy;
the history only needs an operation that extends the newest step.

**TXB-HIS4: Chronological travel.** `earlier(steps)` and `later(steps)`
**must** move that many revisions back or forward in creation order,
regardless of branch, clamped to the oldest and newest. `earlier(d)`
**must** move to the earliest revision whose timestamp is at least the
current timestamp minus `d`, and `later(d)` to the latest revision whose
timestamp is at most the current timestamp plus `d`; ties go to creation
order. Each **must** return the change set that turns the current text
into the target's text, composed through their lowest common ancestor, and
the target's `after` state (the root's is the state the history was
created with).

**TXB-HIS5: Pruning.** The history **must** retain every revision until
`prune(maxRevisions)` is called. Pruning **must** repeatedly remove the
oldest revision that has no children and is not current, then, if still
over the bound, reroot at the oldest revision on the path to the current
one, and **must** return how many revisions it removed. No revision is
ever left without its parent.

**TXB-HIS6: Time is an input.** The history **must not** read a clock.
Timestamps are supplied by the caller; a timestamp earlier than the newest
one recorded **must** be treated as equal to it, so a clock that steps back
cannot break travel.

## 6. Ownership, threading and limits

**TXB-OWN1: Deterministic release.** Nodes **must** be reference-counted
and released, recursively, when the last text, change set or history entry
holding them is destroyed. Release of a deep tree **must not** recurse
deeper than the tree height.

**TXB-OWN2: Sharing across threads.** A text, change set or history **may**
be handed to another thread through an explicit transfer operation.
Reference counts **must** be `shared` fields updated by atomic operations
inside `@trusted` code, so copies on different threads may be created and
destroyed concurrently. Node contents are written only while a node is
being built and never after a text refers to it. A `Text` is never
`immutable`: copying a `const Text` updates a count. Concurrent access to
one variable is the caller's to synchronize, as for any value.

**TXB-OWN5: Attributes.** Every operation **must** be `@safe nothrow
@nogc` and weakly `pure`: it reads and writes nothing but its arguments
and the nodes reachable from them. Strong purity is not claimed, because a
call whose arguments are all `const` still updates counts.

**TXB-OWN3: Allocation.** Nodes **must** be allocated outside the garbage
collector. Allocation failure **must** follow `sparkles.base.buffer`'s
policy for its growth operations; it is never reported as a partial edit.

**TXB-OWN4: Size limits.** A text's length **must** be representable in
`size_t`, and the summaries' counters **must not** overflow for any text
whose bytes fit in memory. A `Text` value **must** be at most two pointers
in size.

## 7. Requirements and evidence

| ID        | Requirement                     | Status      | Traces to                    |
| --------- | ------------------------------- | ----------- | ---------------------------- |
| TXB-TEXT1 | value semantics                 | not started | proposed `Text`              |
| TXB-TEXT2 | persistence                     | not started | proposed `Text.replace`      |
| TXB-TEXT3 | chunk boundaries                | not started | proposed chunker             |
| TXB-TEXT4 | summaries                       | not started | proposed `TextSummary`       |
| TXB-TEXT5 | complexity                      | not started | proposed tree                |
| TXB-TEXT6 | sharing bound                   | not started | proposed node counters       |
| TXB-TEXT7 | equality                        | not started | proposed `Text.opEquals`     |
| TXB-POS1  | chunk iteration both directions | not started | proposed `Text.chunksFrom`   |
| TXB-POS2  | coordinate conversion           | not started | proposed `Text.convert`      |
| TXB-POS3  | lines                           | not started | proposed `Text.line`         |
| TXB-CHG1  | change-set construction         | not started | proposed `ChangeSet.of`      |
| TXB-CHG2  | apply                           | not started | proposed `ChangeSet.apply`   |
| TXB-CHG3  | invert                          | not started | proposed `ChangeSet.invert`  |
| TXB-CHG4  | compose                         | not started | proposed `ChangeSet.compose` |
| TXB-CHG5  | position mapping                | not started | proposed `ChangeSet.mapPos`  |
| TXB-CHG6  | mapping composes                | not started | proposed `ChangeSet.mapPos`  |
| TXB-CHG7  | touched ranges                  | not started | proposed `ChangeSet.touched` |
| TXB-HIS1  | commit keeps branches           | not started | proposed `History.commit`    |
| TXB-HIS2  | undo and redo                   | not started | proposed `History.undo`      |
| TXB-HIS3  | amend                           | not started | proposed `History.amend`     |
| TXB-HIS4  | chronological travel            | not started | proposed `History.earlier`   |
| TXB-HIS5  | pruning                         | not started | proposed `History.prune`     |
| TXB-HIS6  | time is an input                | not started | proposed `History`           |
| TXB-OWN1  | deterministic release           | not started | proposed node refcount       |
| TXB-OWN2  | sharing across threads          | not started | proposed atomic refcount     |
| TXB-OWN3  | allocation                      | not started | proposed node allocator      |
| TXB-OWN4  | size limits                     | not started | proposed `Text`              |
| TXB-OWN5  | attributes                      | not started | proposed `Text`              |

The falsifying scenarios and oracles for each row are in
[testing](./testing.md).
