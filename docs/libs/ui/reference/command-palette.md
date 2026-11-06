# Command-palette state

`sparkles.ui.command_palette` owns palette lifecycle, command metadata, fuzzy
ranking and selection independently of a window or terminal. The host supplies
live command availability and performs emitted command and focus effects.

Declare an application command enum whose initial value means no command.
`PaletteCommand!Cmd` combines an operation with its 64-bit argument; two
arguments for the same operation are different commands. `PaletteEntry!Cmd`
adds immutable label/group text and can describe commands without shortcuts.

`CommandPalette!(Cmd, Capacity, QueryBytes)` defaults to 512 commands and 256
UTF-8 query bytes. `catalog` copies descriptor values and rejects excess
capacity, duplicate identities and empty/invalid command identities without
replacing the installed catalog. Retained immutable text must remain valid;
mutating the caller's descriptor array does not change the installed values.
Admission checks the shared matcher's byte and Unicode-analysis limits before
installation, including both default query case policies. Oversized labels or
normalization segments return `capacityExceeded` without clearing usable rows.
Successful replacement invalidates the old ranked rows. Search again with a
fresh context before accepting; selection is restored by command identity
when it remains available. Failed replacement leaves the old ranking usable.

`open(PaletteInvocation(target, focus))` returns a nonzero session ticket.
Supply that ticket to search, navigation, acceptance and cancellation. Older
session tickets cannot act on a newer opening. The target identifies the
originating document/surface; it is separate from the palette query field's
keyboard focus. `cancel` requests restoration of the recorded focus. The host
checks whether it still exists and chooses a valid fallback when necessary.

`search(ticket, query, context)` uses `context.available(command, target)` for
the captured invocation target. The context's hooks are generic and determine
the inferred attributes; pure, nonthrowing, allocation-free hooks retain those
attributes on the search path. Shared fuzzy matching supplies ranking, and
shared picker state preserves selected identity between successful searches.
The matcher and ranking workspace is allocated once through `base.Unique` and
reused, including ranking/output arrays at the default 512-command capacity.

`highlights(row, ranges)` writes the fuzzy engine's authoritative UTF-8 label
ranges into caller-owned storage. `query` exposes the last accepted query;
rejected queries preserve it and its results. Borrowed query/catalog views
must not outlive the next mutating palette call or a move/destruction of the
palette. The matcher owner makes the palette move-only; keep it at a stable
address while borrowing views.

Read ranked descriptors through `rowCount` and `row(index)`, and move selection
with `move(ticket, delta)`. `accept(ticket, context)` rechecks live availability
and emits an `execute` effect containing the operation, argument and invocation.
The host dispatches the effect; the palette never calls an application action.
A successful acceptance closes the opening, so repeating it emits no command.

`snapshot` exposes value-only selection/session state. `choice(row)` captures
the command identity, session ticket and result revision; `activate(choice,
context)` refuses actions from an older opening or ranking. Retain choices
with the displayed tree so a delayed pointer release cannot activate a
replacement result at the same row index.

`sparkles.ui.command_palette_input.PaletteInput` combines the palette with a
shared single-line `EditorField`. It routes typing, Up/Down, Enter and Escape,
preserves the invocation target while the query owns focus, and rolls back
query edits when matching rejects them. Its query field exposes ordinary
clipboard/composition state for the host to serve.

`sparkles.ui.components.command_palette.viewCommandPalette` builds the shared
widget tree, including the query editor, witness highlights and touch-sized
rows. It returns stamped choices parallel to visible result hit IDs. Pass a
context with `shortcut(command, target)` to display effective shortcuts.
`sparkles.ui.command_bindings.effectiveCommandShortcut` discovers those paths
by checking the real key resolver, including shadowing and ranged arguments.
Format the returned path for the target; depth zero means no effective binding.

Run the [display-independent example](../../../../libs/ui/examples/command-palette.d):

```bash
dub run --single libs/ui/examples/command-palette.d
```

It selects Save from a small catalog and prints `save on target 42`. A host
integration must additionally serve clipboard/composition, route hit actions,
validate restored focus and dispatch command effects. Required behavior is specified in the
[shared palette contract](../../../specs/ui/command-palette.md); delivery and
unverified integration gates are tracked in the
[editor plan](../../../specs/editor/PLAN.md).
