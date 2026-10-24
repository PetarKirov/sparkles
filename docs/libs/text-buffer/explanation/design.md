# The tree, its chunks and its costs

## Why a persistent tree

An editor's state changes on every keystroke, but much of a program wants to
read a version without the next keystroke disturbing it: undo needs the text
as it was, a highlighter reads a snapshot while the user types, and a test
compares the state before and after a command. Making every version an
immutable value satisfies all three. Copying the bytes per keystroke makes
that cost proportional to the document. A mutable gap buffer avoids the cost
but loses the values. A persistent tree keeps both: an edit copies only the
nodes on the path to the change, and everything else is shared. CodeMirror 6,
Zed, Helix and xi-editor all store text this way;
[the decisions](../../../specs/text-buffer/decisions.md) record the comparison.

## The shape

Leaves hold chunks of `minChunk` to `maxChunk` bytes (128 and 512), apart
from a text's only chunk. Internal nodes hold 6 to 12 children, apart from
the root, and every leaf is at the same depth. Each node caches the summary
of its subtree, so a byte, scalar, UTF-16 or line position is found by
descending one path. Tests build with 8–24 byte chunks and fan-out 3–6,
which makes a few hundred bytes several levels deep.

A chunk boundary never splits a scalar, a malformed maximal subpart, or a CR
LF pair. That keeps each chunk decodable on its own and makes every summary
the plain sum of its children's. Grapheme clusters may still span chunks;
`sparkles.base.text.seek` reads across them through `chunkAt`.

## What an edit costs

`replace` is two slices and two appends. A slice reuses every whole subtree
inside its range, and rebuilds the two chunks at each end so the new edge
chunks are long enough. An append rebuilds the two chunks at the seam, the
only place a sequence or CR LF can newly join, then joins the trees B-tree
style: the shorter one is attached at its height on the taller one's spine,
and nodes are split upward when they overflow. A slice folds its covering
subtrees towards their tallest, so the joins cost a logarithmic number of
nodes in total. A test bounds the nodes each random edit allocates.

## Ownership

Nodes come from `pureMalloc`. Their counts are `shared` and atomic, so
copies of one text may be made and dropped on different threads. A node is
written only while it is built. The last reference frees it, recursing only
as deep as the tree. Change sets keep their sections in a counted array and
their inserted text in one `Text`. A history keeps its revisions in a
copy-on-write vector, so copying it is O(1) until one copy changes.
