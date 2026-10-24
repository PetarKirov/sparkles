# `sparkles:text-buffer`

`sparkles:text-buffer` holds editable text as persistent values. A `Text` is
a balanced tree of small UTF-8 chunks whose nodes cache byte, scalar, UTF-16
and line counts. Copying one is a single atomic increment, and every edit
returns a new text that shares all untouched structure with the old one. So
an editor can keep every version for undo, hand a snapshot to a background
highlighter, and compare two versions cheaply.

Edits are values too. A `ChangeSet` can be applied, inverted, composed, and
used to move positions to where they belong after the edit. A `History`
keeps a branching tree of change sets for undo. The package allocates
without the garbage collector, every operation is `@safe pure nothrow
@nogc`, and it depends only on `sparkles:base`.

## Documentation

- [Tutorial: edit a text and undo it](./tutorial/getting-started.md)
- [Reference: `Text`, `ChangeSet` and `History`](./reference/api.md)
- [Explanation: the tree, its chunks and its costs](./explanation/design.md)

The [specification](../../specs/text-buffer/SPEC.md) is normative and the
[delivery plan](../../specs/text-buffer/PLAN.md) records what is delivered.
The editing component built on it is specified in
[the editor specification](../../specs/ui/editor.md).
