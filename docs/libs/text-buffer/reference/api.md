# `sparkles:text-buffer` reference

Every operation below is `@safe pure nothrow @nogc`. Positions are byte
offsets in `[0, length]`; a position names the gap before the byte at that
index. Out-of-range positions passed to slicing, replacing or line queries
are programmer errors (contracts); the coordinate conversions report them as
values instead.

## `Text`

Module `sparkles.text_buffer.text`. A Regular value one pointer in size.

| Member                                                                   | Result                                                                                            |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| `Text(const(char)[] bytes)`                                              | A text holding a copy of `bytes`. `Text.init` is empty.                                           |
| `length`, `empty`, `summary`                                             | Byte length; whether it is 0; the `TextSummary` of the whole text.                                |
| `replace(from, to, inserted)`                                            | A new text with `[from, to)` replaced by a `Text` or a byte slice.                                |
| `slice(from, to)`, `append(other)`, `~`                                  | A new text of bytes `[from, to)`; the concatenation.                                              |
| `==`                                                                     | Byte equality with a `Text` or a slice; shared subtrees at one offset are skipped.                |
| `chunks(from = 0)`, `chunksBackward(before)`                             | Ranges of `SourceChunk` from the chunk holding a position; a range holds a reference to the text. |
| `chunkAt(offset)`                                                        | The chunk holding `offset`; with `length`, this makes `Text` an `isChunkedSource`.                |
| `copyTo(from, to, destination)`, `toString(writer)`, `byteAt(position)`  | The bytes, copied out or written to an output range.                                              |
| `snap(position, affinity)`                                               | `position` moved out of a scalar or malformed subpart, to its start or end.                       |
| `scalarIndexOf`, `utf16IndexOf`, `pointOf` (position, affinity)          | Scalars or UTF-16 units before a position; its (line, column).                                    |
| `positionOfScalar(i)`, `positionOfUtf16(i, affinity)`, `positionOfPoint` | The position of a scalar index, a UTF-16 index, or a `LinePoint`.                                 |
| `lineCount`, `lineStart(i)`, `lineEnd(i)`, `lineOf(position)`            | Lines: `lineEnd` is before the LF, or before the CR of CR LF; a line's end belongs to it.         |

A conversion returns a `Conversion` (`value`, `status`): `exact`, `snapped`
when the input fell inside a unit and moved by its affinity, or `outOfRange`.
`pointOf` returns a `PointConversion` holding a `LinePoint`.

Malformed UTF-8 is stored unchanged and counted as `UtfMode.replacement`
reads it: one scalar and one UTF-16 unit per maximal subpart.

## `TextSummary`

Module `sparkles.text_buffer.summary`. The measures of a byte sequence:
`bytes`, `scalars`, `utf16`, `lineFeeds` and `lastLineBytes`. `a ~ b` is the
summary of the concatenation. `measure(bytes)` computes one. `Affinity` is
`before` or `after`.

## `ChangeSet`

Module `sparkles.text_buffer.change_set`. An edit from texts of
`sourceLength` bytes to texts of `resultLength`.

| Member                                  | Result                                                                                                 |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `ChangeSet.of(sourceLength, edits, c)`  | `ChangeSetStatus.ok`, or `invalidEdit` when an `Edit(from, to, inserted)` is inverted or out of range. |
| `ChangeSet.identity(length)`            | The change set that keeps everything.                                                                  |
| `apply(text)`                           | The edited text; `text.length` must be `sourceLength`.                                                 |
| `invert(source)`                        | The change set mapping `apply(source)` back to `source`.                                               |
| `compose(next)`                         | The change set equal to this one followed by `next`.                                                   |
| `mapPos(p, affinity)`, `mapPosTracking` | Where `p` lands; at or inside a replaced range, the insertion's start (`before`) or end (`after`).     |
| `touched`                               | A range of `TouchedRange`: each replaced range in source (`fromA`, `toA`) and result (`fromB`, `toB`). |
| `empty`, `==`                           | Whether it changes nothing; equality of sections and inserted text.                                    |

`of` groups edits whose ranges overlap, or that fall strictly inside
another's range: the group replaces the union of their ranges with their
insertions in order of `from`, ties in the order given.

## `History!S`

Module `sparkles.text_buffer.history`. A tree of revisions; `S` is the
caller's state and must copy in `@safe` code. Timestamps are `MonoTime`
inputs; one earlier than the newest is treated as equal to it.

| Member                                                  | Result                                                                                           |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `History!S(initial, length, time)`                      | A history whose root is a text of `length` bytes in state `initial`.                             |
| `commit(changes, inverse, before, after, time)`         | Adds a child of the current revision and makes it current; other children are kept.              |
| `undo()`, `redo()`                                      | A `HistoryStep!S`: the change set to apply and the state to restore, or a status saying why not. |
| `amend(changes, inverse, after, time)`                  | Folds an edit into a childless current revision; `notAmendable` otherwise.                       |
| `earlier(steps)`, `later(steps)`                        | Travel in creation order across branches, clamped.                                               |
| `earlier(span)`, `later(span)`                          | Travel to the smallest stamp at most `span` back, or the largest at most `span` ahead.           |
| `prune(maxRevisions)`                                   | Removes the oldest childless revisions, then reroots; returns how many it removed.               |
| `length`, `currentIndex`, `canUndo`, `canRedo`, `state` | The revision count, the current index in creation order, and the current state.                  |
