# Edit a text and undo it

Add `sparkles:text-buffer` as a DUB dependency. Build a text from bytes and
edit it; each edit returns a new text and leaves the old one as it was:

```d
import sparkles.text_buffer;

auto text = Text("hello world");
auto louder = text.replace(0, 5, "HELLO");
assert(louder == "HELLO world");
assert(text == "hello world"); // unchanged: both share the chunk " world"
```

An editor with several cursors describes one command as a change set: one
edit per cursor, all in the coordinates of the text the command saw.
`ChangeSet.of` accepts the edits in any order and merges overlapping ones:

```d
const Edit[2] edits = [Edit(11, 11, "!"), Edit(0, 0, "> ")];
ChangeSet changes;
assert(ChangeSet.of(text.length, edits[], changes) == ChangeSetStatus.ok);
auto edited = changes.apply(text);
assert(edited == "> hello world!");
```

The change set also moves positions. A caret at the end of `world` (offset 11) sits exactly where `!` was inserted, so its affinity decides whether it
stays before the insertion or moves past it:

```d
assert(changes.mapPos(11, Affinity.before) == 13);
assert(changes.mapPos(11, Affinity.after) == 14);
```

To undo, record each change set and its inverse in a `History`. The state
type is yours; an editor stores its selection there. Here it is the caret:

```d
import core.time : MonoTime;

auto history = History!size_t(11, text.length);
history.commit(changes, changes.invert(text), 11, 14, MonoTime.currTime);

auto undo = history.undo();
assert(undo.changes.apply(edited) == text && undo.state == 11);
auto redo = history.redo();
assert(redo.changes.apply(text) == edited && redo.state == 14);
```

Undoing and then committing a different edit starts a branch: the undone
revision is kept, and `history.earlier(1)` or `history.earlier(5.seconds)`
reaches it again.

Next, read [the reference](../reference/api.md) for every operation, or
[the explanation](../explanation/design.md) for why copying is cheap.
