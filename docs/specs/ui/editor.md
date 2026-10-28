---
status: draft
owner: sparkles:ui
reviewed: 2026-10-21
---

# `sparkles:ui` editor — Specification

## Abstract

The `sparkles:ui` editor is the toolkit's one editable-text component: the
search box, the filter field, the setting value and the multi-line comment
composer are all the same component, configured as single- or multi-line
and with or without protected regions. Its behaviour
is a pure function from the current state and one command to the next
state, so every terminal and window backend edits text identically and
every behaviour is testable without a display. It moves and deletes by
whole grapheme clusters, supports several cursors at once, keeps a
branching undo history, honours Readline's editing keys alongside each
platform's native shortcuts, and shows input-method composition in place.

## Introduction

Every interactive application asks the user to type something: a search
query, a filter, a file name, a setting's value, a node's label. When each
application implements its own field, the fields drift apart: Backspace
removes a byte in one, a code point in another and a grapheme in a third;
one accepts ASCII only; another cannot move the caret, select, paste, or
show text an input method is still composing. Users then meet a different
editor in every box, and richer editing surfaces — inline diff editing, a
comment composer, conflict resolution — have nothing to build on. §8 lists
the fields this component replaces.

An editor that is correct everywhere has to settle several questions that
these fields each answered implicitly. What is one step of the caret when a
flag emoji is four code points? What is a word to `Ctrl-W` when the field
holds a path? Which keys belong to the field and which to the application
around it, when `Ctrl-A` means "start of line" to Readline but "select all"
to a Windows text box? What does undo restore when three cursors typed at
once? What does the field show while a Japanese input method has
unconverted text?

The editor answers them once, in a model that knows nothing of how it is
drawn, as the toolkit's [principles](./principles.md) require of every
interaction (`PRN7`–`PRN9`). Its state holds the text, as an immutable
value from [`sparkles:text-buffer`](../text-buffer/SPEC.md) whose versions
share structure; a set of selection ranges, one of them _primary_ (the one
the view follows); a branching history of edits; and any composition in
progress. A host translates input into editing commands through an
ordinary [keymap](./keymap.md); the editor's step function turns a state
and a command into the next state plus a short list of requests for the
host, such as "write this to the clipboard". The step reads no clock,
clipboard or layout: the time, the visual line structure and any pasted
text arrive as inputs. A view renders the state on every backend through
the toolkit's shared drawing pipeline. Killed text — Readline's term for
text deleted by a word or line kill — goes to a _kill ring_ that later
yanks can reinsert, separate from the system clipboard.

The editor does not segment Unicode, store text, or render glyphs. Grapheme
and word boundaries come from
[`sparkles:base`](../base/text/SPEC.md#43-boundaries-from-an-arbitrary-position),
storage and undo from the text buffer, and caret geometry from the
toolkit's layout. It is not an editor application: buffers, files, saving
and language services are the concern of whatever embeds it. Collaborative
editing is out of scope ([text-buffer TXD-6](../text-buffer/decisions.md#txd-6)).

Section 1 defines vocabulary; §2 the state and step; §3 the command
vocabulary; §4 the default keys; §5 the kill ring and clipboard; §6 input
and composition; §7 the view; §8 consumers and migration; §9 decisions.
[Milestones](#milestones) are at the end of this page. The
[keyboard specification's `KBD5`](../design-system/keyboard.md) requires
the Readline keys this editor provides.

## Contract at a glance

1. The editor's state is a [Regular](../../glossary.md#regular-type) value
   advanced only by its step function; the step is pure, deterministic, and
   reads no clock, clipboard or layout.
2. Every range endpoint is a grapheme-cluster boundary of the current text
   after every step.
3. There is always at least one range; ranges are sorted and never overlap,
   and exactly one is primary. A range may be empty: that is a caret.
4. Every command acts on every range; a command that cannot apply anywhere
   changes nothing but its record of the last command, and returns a
   no-op effect with the reason.
5. Undo restores both the text and the ranges; an edit made after an undo
   starts a branch, and no revision is discarded except by explicit
   pruning.
6. One command vocabulary serves every backend; keys bind to commands,
   never to behaviour.
7. Composition text is shown but is not part of the text until committed.

## 1. Vocabulary

Requirement IDs on this page use the prefixes `EDT` (model), `EDC`
(commands), `EDK` (keys), `EDY` (kill ring and clipboard), `EDI` (input),
`EDR` (view) and `EDU` (consumers). Normative keywords carry
[BCP 14](https://www.rfc-editor.org/info/bcp14) meanings.

A _position_ is a byte offset into the text, as in
[`sparkles:text-buffer`](../text-buffer/SPEC.md#1-vocabulary). A _range_ is
an `anchor` and a `head` position plus an affinity; the head is where the
caret is drawn, and a range whose anchor equals its head is a _cursor_. A
range's _goal column_ is the horizontal position, in the layout's unit,
that vertical motion tries to keep. The _primary_ range is the one the view
scrolls to and composition anchors at. A _visual line_ is one line of the
laid-out text after wrapping. A _kill_ is a deletion whose text is saved
for later yanking; a _yank_ inserts saved text.

## 2. The state and its step

**EDT1: The state is a value.** `EditorState` **must** be a Regular value
([`PRN6`](./principles.md)) holding exactly: the text; the selection set;
the history ([`TXB-HIS`](../text-buffer/SPEC.md#5-the-history-tree), with
the selection set as its caller state); the composition, absent or present,
with its preedit held as a text value; the read-only spans; the editor
options; and the _command record_. The command record holds the kind of the
last command, the end of the current kill run, the ranges the last yank
inserted, the time of the last edit, and the number of the pending
clipboard request. Copying a state **must** be O(number of ranges).

**EDT2: One step.** The only transition **must** be
`step(state, ring, texts, command, context) → (state, ring, effects)`,
`@safe nothrow` and weakly `pure`. `ring` is the session's kill ring (§5),
taken and returned by value; `texts` is the host's text pool, read-only,
which resolves the `TextId`s a command carries; `context` supplies the
current time, the active width profile, the viewport height in visual
lines, and the visual-line query of EDT7; `effects` is the list of
requests in EDT9. A step given equal state, ring and command, texts that
resolve the command's ids to equal bytes, and contexts whose queries answer
equally **must** return equal results.

**EDT3: Grapheme boundaries.** After every step, every range endpoint
**must** be a grapheme boundary of the new text, as defined by
[`TXT-SEG7`](../base/text/SPEC.md#43-boundaries-from-an-arbitrary-position).
A position supplied by a command (a pointer hit), or an endpoint that
another range's edit left inside a cluster, that is not a boundary
**must** snap by the range's affinity: `before` to the previous boundary,
`after` to the next.

**EDT4: Normalized selection set.** After every step the ranges **must** be
sorted by start, at least one **must** exist, and none **may** overlap
another. Two ranges **must** merge into one spanning both when they share
any position other than a single common endpoint of two non-empty ranges:
overlapping ranges, equal carets, and a caret inside or at an edge of a
non-empty range all merge. The merged range keeps the later range's
direction and is primary if either was.

**EDT5: Every range, one change.** A command that edits **must** compute
one edit per range in the coordinates of the text it received and combine
them into one change set
([`TXB-CHG1`](../text-buffer/SPEC.md#4-change-sets)), then map every
range through it. A command that changes neither the text nor the ranges
**must** return the state unchanged except for its command record, and the
`noop` effect with the reason.

**EDT6: Coalescing.** An edit **must** amend the current history revision
([`TXB-HIS3`](../text-buffer/SPEC.md#5-the-history-tree)) instead of
committing a new one exactly when: it and the previous command are both
typed insertions, or both deletions of one grapheme in the same direction;
the previous command was the last edit (the command record shows nothing
in between, no-ops included); every range starts where the previous edit
left it; and less than `coalesceInterval` (default 500 ms) separates them
by the context's time. Pastes, yanks, kills, composition commits and
multi-grapheme deletions **must** each commit their own revision; a
`yankPop` amends its yank's revision.

**EDT7: Visual lines are a query.** Commands that depend on layout
(vertical motion, line start and end in a wrapped line, adding a cursor
above or below, pointer hits) **must** obtain visual-line structure from
`context`: the visual line containing a position, its start and end, and
the position nearest a column on a given visual line. The query is a
compile-time interface whose functions are `pure`. A context with no
layout **must** answer with logical lines (whose ends exclude CR before LF,
[`TXB-POS3`](../text-buffer/SPEC.md#3-chunks-positions-and-conversion))
and the active width profile's cell columns, which is exactly the terminal
behaviour.

**EDT8: Single-line mode.** With `singleLine` set, the state **must** never
contain a line feed or carriage return: `insertNewline` **must** produce
the `submit` effect instead of an edit, and inserted, pasted or yanked text
**must** first be distributed over ranges (EDY4) and then have each line
break (CR LF, LF, CR) in each part replaced by one space. Every other
command behaves as in multi-line mode.

**EDT9: Effects.** The step **must** report, never perform, everything
outside the state: `noop(reason)` (nothing applied, with why: nothing to
do, capability absent, nothing to undo), `rejectedReadOnly`, `changed`
(with the change set's touched ranges,
[`TXB-CHG7`](../text-buffer/SPEC.md#4-change-sets)), `submit`, `cancel`,
`writeClipboard(text)`, `readClipboard(request)`, `cancelComposition`,
`killRingFull`, `scrollToPrimary`, and `imeArea(rect)` (EDI6). The host
performs them; the step **must not** depend on whether it did.

**EDT10: Read-only spans.** A state **may** carry protected ranges, mapped
through every change with their start's affinity `after` and their end's
`before`, so text inserted at either edge is editable. An edit that would
change bytes inside a protected range **must** be dropped for that editor
range only, and the step **must** report `rejectedReadOnly` if any edit was
dropped. Motion and selection ignore protected ranges.

## 3. Commands

The command vocabulary is a closed sum type. Commands are named by effect,
not by key, so any key table can bind them ([`KEY11`](./keymap.md)). A
command carrying text carries a `TextId` from the host's text pool
([`INP24`](./input.md)), so the type stays pointer-free and safe to assign
([`INP21`](./input.md)). Every motion command has an extending variant that
moves the head and keeps the anchor.

**EDC1: Insertion.** `insertText(id)` **must** replace every range with the
text; `insertNewline` and `insertTab` **must** insert LF and a tab (or
submit and move focus, per the options). `insertText` with a multi-line
text and as many ranges as lines **must** insert one line per range
(EDY4).

**EDC2: Character motion and deletion.** `moveGrapheme(±1)` and
`deleteGrapheme(±1)` **must** step one grapheme cluster. Moving a non-empty
range collapses it to its start or end instead. Deleting with a non-empty
range deletes the range.

**EDC3: Word motion and deletion.** `moveWord(±1)` **must** skip every
segment that is not of kind `word`, then one `word` segment
([`TXT-SEG9`](../base/text/SPEC.md#43-boundaries-from-an-arbitrary-position)),
as Readline's `forward-word` does: from the start of `foo/bar` it stops
after `foo`, then after `bar`. `killWord(±1)` **must** kill the same span. `killBlankWord(-1)` **must**
kill back over trailing whitespace and then one blank-delimited run.

**EDC4: Line motion and kills.** `moveLineBoundary(start|end)` **must** go
to the visual line's start or end (EDT7); repeating `start` at the start
toggles to the first non-blank position. `killToLineBoundary(start|end)`
**must** kill to that boundary, or the line break itself when the range is
already there.

**EDC5: Vertical and document motion.** `moveLine(±1)` **must** move by
one visual line, keeping the goal column; `movePage(±1)` by the viewport
height the context reports; `moveDocument(start|end)` to 0 or the text's
end. In single-line mode vertical motion **must** produce `noop`.

**EDC6: Selection.** `selectAll`, `selectWord`, `selectLine`,
`collapseToPrimary` (several ranges become the primary; one non-empty range
becomes a cursor at its head), and `setRanges(ranges, primary)` for pointer
input **must** exist.

**EDC7: Multiple cursors.** These **must** exist:
`addNextOccurrence` (if any range is a caret, every caret first selects
its word; otherwise the first match of the primary range's text that
starts after the last range and is not already selected, wrapping to the
start, becomes a new range and the primary; with no such match it produces
`noop`; a primary that is a whole word matches whole words only),
`skipOccurrence`, `selectAllOccurrences`, `addCursorVertical(±1)` (a range
on the adjacent visual line at the same goal column, skipping lines too
short to reach it), `splitIntoLines` (each range becomes one range per
line it covers), `addRangeAt(pos)` / `removeRangeAt(pos)`, and
`columnSelect(fromPos, toPos)` (one range per visual line between them,
spanning the same columns).

**EDC8: History.** `undo`, `redo`, `earlier(n)` and `later(n)` **must**
apply the corresponding history operation
([`TXB-HIS2`](../text-buffer/SPEC.md#5-the-history-tree),
[`TXB-HIS4`](../text-buffer/SPEC.md#5-the-history-tree)) and set the
ranges it returns: `undo` restores the ranges from before the undone
revision, `redo` those from after the redone one, and `earlier`/`later`
those from after the target revision. A composition in progress **must**
be committed first.

**EDC9: Kill ring and clipboard.** `yank`, `yankPop`, `copy`, `cut` and
`paste` **must** behave as §5 requires.

**EDC10: Composition.** `compose(update)` and `commitComposition(id)`
**must** behave as §6 requires.

**EDC11: Field control.** `submit` and `cancel` **must** produce the
corresponding effect and change nothing else. `cancel` during composition
**must** instead discard the composition and produce `cancelComposition`,
so the host tells the input method.

## 4. Keys

Keys bind to commands through the toolkit keymap; the default table below
is the binding every application starts from, and every row is rebindable
through configuration ([`KEY12`](./keymap.md)). Bindings apply only while
an editor has focus (EDI2).

**EDK1: The Readline subset everywhere.** On every backend and platform the
default table **must** bind: `Ctrl-A`/`Ctrl-E` line start/end,
`Ctrl-B`/`Ctrl-F` grapheme back/forward, `Ctrl-U`/`Ctrl-K` kill to line
start/end, `Ctrl-W` kill blank-delimited word back, `Alt-B`/`Alt-F` word
back/forward, `Alt-Backspace`/`Alt-D` kill word back/forward, `Ctrl-H`
delete back, `Ctrl-Y` yank and `Alt-Y` yank-pop
([`KBD5`](../design-system/keyboard.md)). One exception follows the
platform: in a window on Linux or Windows, `Ctrl-A` selects all, as every
other text field there does, and line start is `Home` (EDK3, ED-D2). In a
terminal, `Ctrl-D` deletes forward, as Readline's `delete-char` does.

**EDK2: The common keys.** Arrows, `Home`/`End`, `PageUp`/`PageDown`,
`Backspace`/`Delete`, `Enter` and `Tab` **must** keep their conventional
meanings, `Shift` **must** turn every motion into its extending variant,
and `Escape` **must** cancel composition, else collapse to the primary
range, else cancel the field.

**EDK3: The platform layer.** In addition to EDK1, the default table
**must** bind each platform's native chords:

| Command              | macOS                   | Linux and Windows, windowed | Terminal                     |
| -------------------- | ----------------------- | --------------------------- | ---------------------------- |
| select all           | `Cmd-A`                 | `Ctrl-A`                    | `Ctrl-Shift-A` where encoded |
| copy / cut / paste   | `Cmd-C`/`Cmd-X`/`Cmd-V` | `Ctrl-C`/`Ctrl-X`/`Ctrl-V`  | the terminal's own paste     |
| undo / redo          | `Cmd-Z`/`Cmd-Shift-Z`   | `Ctrl-Z`/`Ctrl-Shift-Z`     | `Ctrl-_` / `Alt-_`           |
| word motion          | `Opt-Left`/`Opt-Right`  | `Ctrl-Left`/`Ctrl-Right`    | both                         |
| line start / end     | `Cmd-Left`/`Cmd-Right`  | `Home`/`End`                | `Home`/`End`                 |
| kill word back       | `Opt-Backspace`         | `Ctrl-Backspace`            | `Alt-Backspace`              |
| delete forward       | `Delete`                | `Delete`                    | `Delete`, `Ctrl-D`           |
| add next occurrence  | `Cmd-D`                 | `Ctrl-D`                    | unbound; rebind (`KEY12`)    |
| cursor above / below | `Opt-Cmd-Up`/`Down`     | `Alt-Shift-Up`/`Down`       | `Alt-Shift-Up`/`Down`        |
| split into lines     | `Shift-Opt-I`           | `Shift-Alt-I`               | `Shift-Alt-I`                |
| add / remove cursor  | `Opt-click`             | `Alt-click`                 | `Alt-click`                  |
| column select        | `Opt-drag`              | `Alt-drag`                  | `Alt-drag`                   |
| earlier / later      | `Alt-U` / `Alt-Shift-U` | `Alt-U` / `Alt-Shift-U`     | `Alt-U` / `Alt-Shift-U`      |

**EDK4: Reserved keys stay reserved in terminals.** In a terminal, the default table
**must not** bind `Ctrl-C`, `Ctrl-Z`, `Ctrl-S`, `Ctrl-Q` or `Ctrl-\`
([`KBD3`](../design-system/keyboard.md)); the terminal column above
already avoids them. `Ctrl-I` and `Ctrl-M` **must** be `Tab` and `Enter`
unless the terminal disambiguates them ([`KBD5`](../design-system/keyboard.md)).

**EDK5: A chord the editor declines reaches the application.** A key the
editor's table does not bind **must** fall through to the application's
keymap, and a printable key with no command modifier **must** become
`insertText`.

## 5. Kill ring and clipboard

The kill ring is Readline's: a short, bounded history of killed text that
only the editor reads. The system clipboard is separate and is touched only
by copy, cut and paste. One kill ring serves every editor of a host
session; it is an explicit value the host owns and passes to the step,
never global state.

**EDY1: The ring.** A `KillRing` **must** be a Regular value holding at
most `killRingSize` entries (default 10, Readline's
[fixed size](https://git.savannah.gnu.org/cgit/readline.git/tree/kill.c?id=f95e81428a77b37d83e56c0c7099956e8a7adfc8#n59)),
dropping the oldest when full. An entry holds one part per range, each part
a [text](../text-buffer/SPEC.md#2-the-text-value) value, so a kill of any
size is stored by sharing the killed slice of the document without copying
it and never truncated.

**EDY2: Consecutive kills join.** A kill **must** extend the newest entry
instead of adding one when the command record shows the previous command
was a kill by the same editor and the number of ranges is unchanged; a
forward kill appends to each part and a backward kill prepends. Each part
is the text its range deleted after merging (EDT4). Any other command,
no-ops included, ends the run.

**EDY3: Yank and yank-pop.** `yank` **must** insert the newest entry
(distributed by EDY4) and record the inserted ranges. `yankPop` **must**,
only when the previous command was `yank` or `yankPop`, replace the
recorded ranges with the next older entry, cycling, amending the yank's
revision; otherwise it **must** produce `noop`.

**EDY4: Distribution over ranges.** A multi-part entry, or a pasted text
split on line breaks after dropping one trailing line break, whose number
of parts equals the number of ranges **must** give the _i_-th part to the
_i_-th range. Otherwise every range **must** receive the whole text: a
pasted text as its original bytes, an entry as its parts joined by LF.

**EDY5: The system clipboard.** `copy` and `cut` **must** produce
`writeClipboard` with the ranges' texts joined by LF (`cut` also deletes
them). `paste` **must** produce `readClipboard` with a new request number,
recorded in the command record, and change nothing. The host answers with
the clipboard text tagged with that number ([`INP25`](./input.md)); the
answer **must** be inserted, as its own revision, only if its number is
the recorded one and the editor has kept focus since, and dropped
otherwise.

## 6. Input and composition

**EDI1: Typed text.** A key event that produced text and carries no
command modifier **must** reach the editor as `insertText` of that text,
taken from the event's inline text ([`INP15`](./input.md)) rather than its
single code point, so a dead key's or an input method's multi-scalar result
arrives whole.

**EDI2: Focus routes input.** While an editor has focus
([`STM7`](./state-machines.md)), key, paste and composition events go to
it first; only what it declines reaches the application (EDK5), and the
key guide stays inert ([`LTN12`](./keymap.md)).

**EDI3: Composition is shown, not inserted.** `compose(update)` **must**
record a composition holding a copy of the preedit text (the event's id
stops resolving at the next poll), its cursor, and its styled segments,
anchored at each range; while it is present the text **must
not** change, and the view shows the preedit in place of each range.
`commitComposition(id)` **must** replace every range with the committed
text as one revision; an empty update **must** end the composition with no
edit. A command other than composition, motion within the preedit, or
`cancel` **must** first commit the preedit as typed.

_Rationale:_ A browser editor such as CodeMirror writes preedit into the
document because `contenteditable` already did
([evidence](https://github.com/codemirror/view/blob/fbff59ba004d80d8c914f64c42586387b08706ac/src/domchange.ts#L215-L296)).
A native host has a real preedit channel, so keeping preedit out of the
text keeps undo, read-only spans and change notifications free of
half-composed text.

**EDI4: Pasted text.** A run of `PasteEvent` chunks ([`INP21`](./input.md))
**must** reach the editor as one `insertText` tagged as a paste, never as
keys; in single-line mode its line breaks become spaces (EDT8).

**EDI5: Degradation is explicit.** A backend that cannot deliver
composition, read the clipboard, or show a soft keyboard **must** declare
it ([`INP6`](./input.md)); the affected command **must** produce
`noop(capabilityAbsent)`, which the view shows, never failing silently.

**EDI6: The input method follows the caret.** After every step that moves
the primary range or changes composition, the editor **must** produce
`imeArea` with the primary caret's rectangle in the layout's unit, which
the host forwards to the platform (`SDL_SetTextInputArea`, the wsi text
input area) so candidate windows appear at the caret.

**EDI7: Native window events reach the editor.** A pure conversion in
`sparkles:ui-app` **must** turn a `sparkles:wsi` `TextCommittedEvent` into
a key event's inline text or an `insertText`, and a `CompositionEvent` into
an input `CompositionEvent`, re-interning its text into the host's pool
with `retain` ([`POOL18`](../base/pool.md)). The conversion **must** be
tested over recorded wsi events from each platform backend, independently
of any live window.

**EDI8: SDL composition.** The SDL3 backend **must** emit `CompositionEvent`
from `SDL_EVENT_TEXT_EDITING`, deliver committed text from
`SDL_EVENT_TEXT_INPUT`, start and stop text input with editor focus, and
apply `imeArea`.

**EDI9: Android soft keyboard.** Focusing an editor **must** show the soft
keyboard and losing focus hide it; its text joins the same event stream.
Until a backend delivers it, that backend's editors declare the capability
absent (EDI5).

## 7. The view

**EDR1: One view everywhere.** `view(state, theme) → Widget` **must**
render the text, every caret, every selection, the composition and
read-only spans through the standard pipeline on every backend. Carets use
the `caret` slot and blink with [`STM6`](./state-machines.md) `Timeline`;
selections use the selection tint; composition segments are underlined
(`underline`), highlighted (`selected`), underlined twice (`converted`) or
plain (`none`), as the event marks them.

**EDR2: Geometry comes from layout.** Caret and selection geometry **must**
come from the toolkit's layout of the text, and the same layout **must**
answer the step's visual-line queries (EDT7), so the caret is drawn where
motion believes it is. The viewport **must** follow the primary caret on
`scrollToPrimary`.

**EDR3: Highlighting does not block typing.** An editor **may** carry
syntax highlighting, re-run from the `changed` effect off the keystroke
path ([`NFR8`](../hue/feature-requirements.md)); the plain text is drawn
first and the styled text swapped in when ready.

**EDR4: Change surface.** The consumer **must** receive the `changed`
effect with the touched ranges on every edit, so a diff pane re-diffs and a
composer validates without polling.

**EDR5: Editable regions look editable.** An editable region and its
read-only spans **must** be visually distinct through theme slots, alike on
every backend.

## 8. Consumers and migration

**EDU1: Diff inline editing.** The worktree side of a diff pane
([`DST5`](../hue/diff-view.md)) edits through the editor; save is explicit;
re-diff runs from EDR4.

**EDU2: Comment composer and suggestions.** Multi-line comment authoring
and the suggestion editor over the anchored lines
([`DCM3`](../hue/diff-view.md)).

**EDU3: Conflict resolution.** Free editing of the conflict result with the
markers as read-only spans while picking ([`CFV4`](../hue/diff-view.md),
EDT10).

**EDU4: Every existing field migrates.** Each text field in the repository
**must** use the editor, in single-line mode where it is one, and the
types that implemented them **must** be removed:

| Field                                                                | Implemented by today                             |
| -------------------------------------------------------------------- | ------------------------------------------------ |
| tree-view filters (hue explorer, settings panes, gallery, diagram)   | `LineEditState` in `sparkles.ui.state`           |
| hue document search, go-to-line, data filter (windowed and terminal) | `InputState` in `apps/hue/src/input_line.d`      |
| hue file and grep picker prompt                                      | `PickerPrompt` in `apps/hue/src/picker.d`        |
| settings-pane value editor                                           | a private buffer in `components/settings_pane.d` |
| terminal page search, tab tree, touch guide                          | `queryPrefixWithoutLastGrapheme` in `page_kit.d` |
| document-viewer search                                               | a private buffer in `doc_view/pane.d`            |
| diagram node label                                                   | a fixed buffer in `apps/diagram/src/world.d`     |

A field that accepted only digits (go-to-line) **must** filter
`insertText` through a caller-supplied predicate rather than keep its own
editor.

## 9. Decisions {#decisions}

**ED-D1: Two definitions of a word.** Readline kills with `Ctrl-W` back to
whitespace
([`rl_unix_word_rubout`](https://git.savannah.gnu.org/cgit/readline.git/tree/kill.c?id=f95e81428a77b37d83e56c0c7099956e8a7adfc8#n307))
but moves over alphanumeric words with `Alt-B`/`Alt-F`. The editor keeps
both (EDC3), defined once in base (`TXT-SEG9`): as in a shell, `Ctrl-W`
removes a whole path back to the previous space, while `Alt-Backspace`
removes one component. Words are UAX #29's, not Readline's runs of
alphanumerics, so `foo.bar` and `e.g.` are one word each: `.` between
letters is MidNumLet and joins them.

**ED-D2: Readline keys plus a platform layer.** The Readline keys are bound
on every target, and native platform chords beside them (EDK3), so one
application has one editor wherever it runs. Where the two collide, the
platform wins in a window and Readline in a terminal: `Ctrl-A` selects all
in a window on Linux or Windows and moves to line start in a terminal and
on macOS, whose text fields already treat it as line start; `Ctrl-D` adds
the next occurrence in a window and deletes forward in a terminal. The
owner chose this split ([EDQ2, EDQ3](#resolved-questions)): a window user
expects the platform's select-all, and a shell user expects Readline.

**ED-D3: Several cursors from the start.** The selection is a set of ranges
with a primary one, as in CodeMirror, Helix, Kakoune and Zed, and every
command is written for _n_ ranges. Adding cursors later would rewrite every
command.

**ED-D4: A kill ring beside the clipboard.** Readline's kills would
otherwise overwrite the clipboard on every `Ctrl-W`. The ring holds text
values that share the killed slices of the document, so a kill costs no
copy and is never truncated; the host session owns it (EDY1). A fixed
`TextPool` was considered and rejected: it bounds the size of a kill.

**ED-D5: Text payloads are pool ids.** Commands and input events carry
`TextId`s so that they stay pointer-free sum types; the text buffer itself
holds counted pointers ([text-buffer TXD-2](../text-buffer/decisions.md#txd-2)).

**ED-D6: A branching history.** Undo never loses work
([text-buffer TXD-3](../text-buffer/decisions.md#txd-3)); `earlier`/`later`
reach abandoned branches.

### Resolved questions

- **EDQ1 — terminal undo and redo keys.** `Ctrl-Z` is reserved in a
  terminal and Readline has no redo. Decided: `Ctrl-_` undoes, as in
  Readline, and `Alt-_` redoes.
- **EDQ2 — `Ctrl-D`.** Readline deletes forward with it; VS Code adds the
  next occurrence. Decided: delete forward in a terminal, add the next
  occurrence in a window (`Cmd-D` on macOS). Add-next-occurrence is unbound
  in a terminal and reachable by rebinding.
- **EDQ3 — desktop conflicts.** GNOME takes `Ctrl-Alt-Up`/`Down` for
  workspace switching. Decided: adding a cursor above or below is
  `Alt-Shift-Up`/`Down` off macOS, and `Ctrl-A` selects all in a window on
  Linux and Windows (ED-D2).

## Requirements and evidence

| ID                     | Requirement                   | Status      | Traces to                                                                                                                                                                                                                                                                                                                                                                                                               |
| ---------------------- | ----------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EDT1                   | the state is a value          | full        | `EditorState`; tests `editor.oracle.invariants`, `editor.history.coalescingAndBranches`                                                                                                                                                                                                                                                                                                                                 |
| EDT2                   | one step                      | full        | `step`, `stepInPlace`, `isTextSource`, `isEditContext`; test `editor.oracle.referenceEditor`                                                                                                                                                                                                                                                                                                                            |
| EDT3                   | grapheme boundaries           | full        | `step`; tests `editor.oracle.invariants`, `editor.grapheme.wholeClusters`                                                                                                                                                                                                                                                                                                                                               |
| EDT4                   | normalized selection set      | full        | `SelectionSet`; tests `editor.selection.normalize`, `editor.normalize.afterEdit`, `editor.oracle.invariants`                                                                                                                                                                                                                                                                                                            |
| EDT5                   | every range, one change       | full        | `step`; tests `editor.insert.everyRange`, `editor.oracle.multiCursorMatchesOneAtATime`                                                                                                                                                                                                                                                                                                                                  |
| EDT6                   | coalescing                    | full        | `step`; test `editor.history.coalescingAndBranches`                                                                                                                                                                                                                                                                                                                                                                     |
| EDT7                   | visual lines are a query      | full        | `isEditContext`, `LogicalContext`; tests `editor.context.logicalLines`, `editor.vertical.goalColumn`                                                                                                                                                                                                                                                                                                                    |
| EDT8                   | single-line mode              | full        | `EditorOptions`; test `editor.singleLine`                                                                                                                                                                                                                                                                                                                                                                               |
| EDT9                   | effects                       | partial     | `EditEffect`, `EditEffects`; the IME-area effect arrives with composition (E2)                                                                                                                                                                                                                                                                                                                                          |
| EDT10                  | read-only spans               | full        | `ReadOnlySpan`; test `editor.readOnly.spans`                                                                                                                                                                                                                                                                                                                                                                            |
| EDC1–EDC9              | commands                      | full        | `EditCommand`, `EditKind`; tests `editor.word.motionAndKill`, `editor.killBlankWord.wholePath`, `editor.lineBoundary.toggleAndKillBreak`, `editor.selection.commands`, `editor.multi.addNextOccurrence`, `editor.multi.verticalSplitAndColumns`, `editor.history.coalescingAndBranches`                                                                                                                                 |
| EDC10                  | composition                   | not started | E2: `compose`, `commitComposition` produce `noop(capabilityAbsent)` until then                                                                                                                                                                                                                                                                                                                                          |
| EDC11                  | field control                 | full        | `EditKind.escape`; test `editor.fieldControl`                                                                                                                                                                                                                                                                                                                                                                           |
| EDK1–EDK5              | default keys                  | full        | `editorBindings`, `editorCommand`, `editorBinds`, `windowTarget`; tests `editor.keys.readlineEverywhere`, `editor.keys.platformLayer`, `editor.keys.reservedInTerminals`, `editor.keys.typedTextAndDecline`                                                                                                                                                                                                             |
| EDY1–EDY4              | kill ring                     | full        | `KillRing`, `KillEntry`; tests `editor.killRing.boundedAndCycling`, `editor.killRing.joinYankAndPop`, `editor.paste.distribution`                                                                                                                                                                                                                                                                                       |
| EDY5                   | the system clipboard          | full        | `EditKind.paste`, `LogicalContext.clipboardRead`, `LogicalContext.clipboardWrite`, `serveClipboard`, `forwardClipboard`, `FieldSetup`; tests `editor.clipboard.requestAndAnswer`, `editor.clipboard.absentIsExplicit`, `editor.clipboard.cutWithoutWriterKeepsText`, `editor.field.serveClipboard`, `editor.field.forwardClipboard`. Hosts: hue's window, the terminal app's pages and viewer, the diagram, the gallery |
| EDI1, EDI2             | typed text, focus routing     | full        | `editorCommand`; the migrated fields' hosts route a focused field's keys first                                                                                                                                                                                                                                                                                                                                          |
| EDI4                   | pasted text                   | full        | `EditorField.insert`; `TreeViewState.filterPaste`, `InputState.paste`, `QueryField.paste`, `Pasteable`                                                                                                                                                                                                                                                                                                                  |
| EDI5                   | degradation is explicit       | full        | `NoopReason.capabilityAbsent`; test `editor.clipboard.absentIsExplicit`                                                                                                                                                                                                                                                                                                                                                 |
| EDI3, EDI6–EDI8        | composition and the IME       | not started | E2                                                                                                                                                                                                                                                                                                                                                                                                                      |
| EDI9                   | Android soft keyboard         | not started | E4                                                                                                                                                                                                                                                                                                                                                                                                                      |
| EDR1, EDR2, EDR4, EDR5 | the view                      | full        | `editorView`, `editorLineSpans`, `scrollToPrimary`, `EffectKind.changed`; tests `editor.view.spans`, `editor.view.readOnlyDistinct`, `editor.view.sourceRanges`, `editor.view.scrollToPrimary`; composition in EDR1 arrives with E2                                                                                                                                                                                     |
| EDR3                   | highlighting off the key path | not started | E3                                                                                                                                                                                                                                                                                                                                                                                                                      |
| EDU1–EDU3              | write-wave consumers          | not started | E3                                                                                                                                                                                                                                                                                                                                                                                                                      |
| EDU4                   | every existing field migrates | full        | `EditorField`; `TreeViewState.filterKey`, `InputState.key`, `PickerPrompt.key`, `SettingsPane.handlePaste`, `QueryField`, `editKey`; the line-edit state it replaced is removed                                                                                                                                                                                                                                         |

### Oracles

The model is tested with strings alone, at three levels.

- **A reference editor over a plain string** implements EDC1–EDC9 for one
  cursor in the most direct way, sharing no code with the editor. Random
  command sequences on random texts (mixed scripts, emoji sequences, CR LF,
  malformed bytes) must leave both in the same text and range.
- **Multi-cursor commands are checked against one-cursor runs**: for
  commands whose ranges do not interact, _n_ cursors must produce the same
  result as applying the command at each cursor in turn, from the end of
  the text backwards.
- **Invariants after every generated step**: EDT3, EDT4, single-line
  (EDT8), and `undo` followed by `redo` restoring text and ranges.

Readline behaviour is pinned by example tests transcribed from Readline's
own source at the pinned revision; the keys are pinned by a table test of
the default bindings per platform. Generated tests follow the seeded
pattern of `libs/diff/src/sparkles/diff/myers.d`.

## Milestones

| Milestone | Scope                                                                                                                      | Status      | Requirements                                                                                                                             |
| --------- | -------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| E0        | Base steppers and the text buffer                                                                                          | delivered   | [`TXT-SEG7`–`9`](../base/text/PLAN.md), [TB0–TB3](../text-buffer/PLAN.md)                                                                |
| E1        | The model, commands, kill ring, clipboard read, default keys, the view on every backend, and every existing field migrated | partial     | EDT1–EDT10, EDC1–EDC11, EDK1–EDK5, EDY1–EDY5, EDI1, EDI2, EDI4, EDI5, EDR1, EDR2, EDR4, EDR5, EDU4, `INP25`, a target-aware `KBD3` check |
| E2        | Composition, the SDL3 IME, the wsi conversion, input-method placement                                                      | not started | EDI3, EDI6, EDI7, EDI8, `INP24`, composition in EDR1                                                                                     |
| E3        | Write-wave consumers                                                                                                       | not started | EDU1–EDU3, EDR3                                                                                                                          |
| E4        | Android soft keyboard                                                                                                      | not started | EDI9                                                                                                                                     |

E0 to E2 are delivered as one stack of pull requests after this
specification is accepted. Live composition on native wsi windows arrives
with the host's native configurations ([ui-app P4](../ui-app/PLAN.md));
EDI7 is satisfied by the tested conversion alone.

## Relationship to other specifications

| Specification                                                                   | Role                                             |
| ------------------------------------------------------------------------------- | ------------------------------------------------ |
| [text-buffer](../text-buffer/SPEC.md)                                           | text storage, change sets, the history tree      |
| [base text §4.3](../base/text/SPEC.md#43-boundaries-from-an-arbitrary-position) | grapheme and word boundaries from any position   |
| [principles](./principles.md) `PRN6`–`PRN8`                                     | Regular values, pure transitions, one definition |
| [state machines](./state-machines.md) `STM6`/`STM7`                             | caret blink, focus                               |
| [input](./input.md) `INP15`/`INP21`/`INP24`/`INP25`                             | key text, pastes, composition, clipboard reads   |
| [keymap](./keymap.md) `KEY11`/`KEY12`/`LTN12`                                   | binding and configuration                        |
| [keyboard](../design-system/keyboard.md) `KBD3`/`KBD5`                          | reserved keys; the Readline obligation           |
| [hue diff view](../hue/diff-view.md) `DST5`/`DCM3`/`CFV4`                       | the write wave                                   |

→ [Overview](./index.md) · [State machines](./state-machines.md) · [Widgets](./widgets.md) · [Text buffer](../text-buffer/SPEC.md)
