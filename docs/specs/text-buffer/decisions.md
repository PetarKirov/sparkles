---
status: draft
owner: sparkles:text-buffer
reviewed: 2026-10-21
---

# `sparkles:text-buffer` — Decisions

Each decision records its question, the alternatives, the evidence, the
choice and when to revisit it. The project owner made the choices in a
design review on 2026-10-20/21; the evidence below was gathered from
upstream sources pinned to the commits named in each link.

## TXD-1: A persistent summary tree now {#txd-1}

**Question.** What represents an editable text?

**Alternatives.**

| Structure                            | Used by                                                                                                                                                                                                                                                                               | Edit cost       | Versions                      |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- | ----------------------------- |
| Flat string                          | Readline, GTK `Entry`, Qt `QLineEdit`                                                                                                                                                                                                                                                 | O(_n_)          | whole copies                  |
| Gap buffer                           | Emacs                                                                                                                                                                                                                                                                                 | O(1) at the gap | inverse-operation log         |
| Array of shared lines                | [Kakoune](https://github.com/mawww/kakoune/blob/4d4ee86c2d039c2a5f29f109e7e59105d2073046/src/buffer.hh)                                                                                                                                                                               | O(line + lines) | lines shared between versions |
| Piece tree                           | [VS Code](https://github.com/microsoft/vscode/blob/3c8529100dd6bb8b146dbceeec3e639f1c8ec8e6/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts)                                                                                                                          | O(log _n_)      | snapshots copy the piece list |
| Persistent line tree                 | [CodeMirror 6](https://github.com/codemirror/state/blob/9c801279cb83011e6f92af778f4443406e8f1200/src/text.ts#L1-L7) (32 lines per leaf)                                                                                                                                               | O(log _n_)      | shared subtrees               |
| Persistent chunk tree with summaries | [Zed `SumTree`](https://github.com/zed-industries/zed/blob/fae8a354829e56bf5615fedfa8cdfecb124550c4/crates/sum_tree/src/sum_tree.rs#L206-L213), [ropey](https://github.com/cessen/ropey/blob/1992665990964e5eee68a42a1aed2bd7abcfda87/src/tree/node_children.rs#L519-L525), xi `rope` | O(log _n_)      | O(1) copies, shared subtrees  |

**Evidence.** Every editor in the table that keeps immutable versions uses a
persistent tree. Zed stores each child's summary in its parent, so a seek
never visits a child it skips
([node layout](https://github.com/zed-industries/zed/blob/fae8a354829e56bf5615fedfa8cdfecb124550c4/crates/sum_tree/src/sum_tree.rs#L1268-L1281)),
and converts positions inside a chunk with bitmaps
([chunk](https://github.com/zed-industries/zed/blob/fae8a354829e56bf5615fedfa8cdfecb124550c4/crates/rope/src/chunk.rs#L16-L33)).
CodeMirror indexes by lines only, so a single long line is one string and
positions inside it are found by scanning
([`lineInner`](https://github.com/codemirror/state/blob/9c801279cb83011e6f92af778f4443406e8f1200/src/text.ts#L37-L48)).

**Choice.** A chunk tree with cached summaries (TXB-TEXT1 to TXB-TEXT6),
built now rather than starting from a flat string.

**Trade-offs.** It costs more to build than a string, and every consumer
today edits short fields. In exchange the editor never changes
representation when a large-buffer consumer arrives (hue's diff write wave,
[`EDU1`](../ui/editor.md)), and versions are cheap from the first commit.

**Revisit when** a measured workload shows the per-node overhead dominating
short-field editing.

## TXD-2: Reference-counted nodes, not pool handles {#txd-2}

**Question.** How are shared, immutable nodes owned?

**Alternatives.** Garbage-collected immutable nodes; atomic reference counts
on the nodes, as `Arc` in Zed and ropey; nodes in a
[`sparkles.base.pool`](../base/pool.md) linked by generational handles,
with counts kept by an owning session; an arena per document.

**Evidence.** Zed mutates through `Arc::make_mut`, copying a node only when
it is shared
([`update_last_recursive`](https://github.com/zed-industries/zed/blob/fae8a354829e56bf5615fedfa8cdfecb124550c4/crates/sum_tree/src/sum_tree.rs#L634-L676)),
so an edit copies one path. `base.pool` deliberately excludes reference
counting and growable storage ([pool §7](../base/pool.md#7-outside-this-contract)):
with handles, a text would be a root plus the pool that resolves it, so
reading, comparing and copying it would need the pool.

**Choice.** Atomic reference counts on nodes allocated outside the garbage
collector (TXB-OWN1 to TXB-OWN3). A text stays self-contained and Regular
by construction. `base.pool` is used at the edges, where its handles keep
event values pointer-free: insertion payloads and composition text in
`sparkles:input` events ([editor decisions](../ui/editor.md#decisions)).
The editor's kill ring holds texts, which share the killed slices.

**Trade-offs.** Counts cost an atomic operation per copy and destruction,
and a text holds pointers, so a `SumType` containing one is `@system` to
assign ([`INP21`](../ui/input.md)). Editing commands therefore carry
`TextId`s, never texts.

## TXD-3: A history tree, not a stack {#txd-3}

**Question.** What happens to undone edits when the user edits again?

**Alternatives.** A linear stack that discards the redo branch on a new
edit, as
[CodeMirror](https://github.com/codemirror/commands/blob/5b9bac974f2c4af3e20b045adef949667872ecad/src/history.ts#L336)
and Zed do; a tree that keeps it, as
[Helix](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/history.rs#L7-L66)
and Kakoune do.

**Evidence.** Helix keeps revisions in creation order with a parent and a
most-recent child; undo follows the parent, redo the most recent child, and
`earlier`/`later` walk creation order across branches through the lowest
common ancestor
([`jump_to`](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/history.rs#L183-L224)).
Because versions share structure (TXD-1), keeping a branch costs only its
change sets.

**Choice.** A tree with Helix's navigation (TXB-HIS1 to TXB-HIS5), plus an
explicit amend for coalescing and explicit pruning.

## TXD-4: Byte positions {#txd-4}

**Question.** Which unit does a position count?

**Alternatives.** UTF-16 units, as CodeMirror inherits from JavaScript;
Unicode scalars, as ropey and Helix; bytes, as Zed and Kakoune.

**Choice.** Bytes. The base text contract, the wrapping maps and every
renderer in the repository address UTF-8 by byte, and summaries make the
other units one conversion away (TXB-POS2) for the platform APIs that need
them (UTF-16 for IME surrounding text on Windows and Android).

## TXD-5: What summaries cache {#txd-5}

**Question.** Which measures does a node carry?

**Evidence.** Zed caches bytes, scalars, UTF-16, lines and longest row
([`TextSummary`](https://github.com/zed-industries/zed/blob/fae8a354829e56bf5615fedfa8cdfecb124550c4/crates/rope/src/rope.rs#L1279-L1302));
ropey caches bytes, scalars, surrogates and line breaks. Neither caches
graphemes: a grapheme's extent depends on context across chunk seams.

**Choice.** Bytes, scalars, UTF-16 units, line feeds and last-line length
(TXB-TEXT4). Grapheme and cell measures stay derived, from the base text
steppers over chunk iteration (TXB-POS1), because they depend on the
Unicode version and the width profile, which a stored summary would freeze.

## TXD-6: No rebasing of change sets {#txd-6}

**Question.** Does a change set rebase over a concurrent change set, as
CodeMirror's
[`map`](https://github.com/codemirror/state/blob/9c801279cb83011e6f92af778f4443406e8f1200/src/change.ts#L240-L251)
does?

**Choice.** No. Multi-cursor edits are built in one coordinate system
(TXB-CHG1), so nothing in a single-writer editor needs operational
transformation; Helix leaves the same operation unimplemented. Positions
still map (TXB-CHG5).

**Revisit when** collaborative editing or edits from a background producer
(a formatter) must merge with typing.
