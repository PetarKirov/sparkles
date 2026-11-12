---
status: draft
owner: fileset-explorer
reviewed: 2026-11-09
---

# Fileset explorer

The fileset explorer is an application for writing a fileset and seeing what it
selects as it is written. A query typed into an editor is resolved against a
directory after every edit, and the members it selects are drawn as a tree,
beside the resolution's numbers, the help, and the same fileset translated into
other build systems' notations. It is built on the fileset library of
[`sparkles:build-primitives`](../build-primitives/filesets/SPEC.md), the
toolkit's [editor](../ui/editor.md), [tree view](../hue/tree-view.md) and
[dock](../ui/containers.md#dock-container-dck), and the markdown view of
`sparkles:source-view`.

This contract owns the query language (§2), the explorer's screen (§3), its
help and the runnable blocks of its tutorial (§4), the code generators (§5),
and its Android build (§6).
Two obligations belong to libraries it uses and are specified there: the host's
text cursor ([`HST20`](../ui-app/feature-requirements.md)), and the fileset
leaves for a list of paths, a file's own name and its kind
([`FSV6`, `FSV7`](../build-primitives/filesets/SPEC.md)).
The choices behind it are recorded in [decisions](./decisions.md), the evidence
in [testing](./testing.md), and the delivery order in the [plan](./PLAN.md).

## 1. Invariants

1. **One meaning.** A query means one set of files beneath a root, the set the
   fileset library resolves it to. The tree, the numbers, a tutorial's expected
   result and every generated translation describe that set and no other.
2. **Exact or refused.** A translation into another notation either selects
   exactly the same files on every tree, or is refused with a reason. No
   translation is approximate.
3. **Typing is never lost.** An edit that does not parse, or a root that
   cannot be read, leaves the last good result on screen beside the error; the
   editor's text is never rewritten by the explorer.

## 2. The query language (`FXL`)

A query is text. Whitespace, including newlines, separates tokens and is
otherwise insignificant.

**`FXL1` — Leaves.** A query's leaves **must** be paths and calls. A _path_ is
a run of _pieces_ written with no whitespace between them:

- a _bare piece_, a glob with the fileset library's syntax
  ([`FSG1`](../build-primitives/filesets/SPEC.md#5-matching-fsg)): `*`, `**`,
  `?`, `[…]` and `{a,b}`, a `\` escaping only a glob metacharacter (`*`, `?`,
  `[`, `]`, `{`, `}`, `,`, `!` or `\`); it holds no whitespace, `(`, `)` or `"`,
  and a `,` only inside braces;
- a _quoted piece_, `"…"`, which is literal: no byte in it is a
  metacharacter; inside it `\"` is a quote and `\\` a backslash, and every
  other byte is itself.

A path is relative to the fileset root, as a Nix path is: `src` is the root's
`src`, at no other depth, and `**/README.md` is every `README.md`. A leading
`./` is allowed and means nothing; a leading `/` is an error. A path that names
a directory selects every file beneath it. A path does not begin with `#` (a
comment) or `!`.

A _call_ is a name and its arguments in parentheses. `all()`, `none()`,
`exec()` (executable regular files), `gitignored()` (the files git's ignore
rules exclude) and `gitTracked()` (the files in git's index) take none; a
name not followed by `(` is a path. _Detection:_ `a-b/*.d`, `"#foo#"`,
`"my notes"/*.md` and `"say \"hi\""` each parse to one path of the expected
text; `"[draft].md"` matches only a file of that name; `README.md` matches the
root's and not `docs/README.md`; `/src` fails; `all` is the path `all`.

**`FXL2` — Comments.** A `#` where a token could begin **must** start a comment
that runs to the end of its line. A `#` inside a path is part of it.
_Detection:_ `a#b` is one path; `a #b` is the path `a`; `"#b"` is a path; a
query whose every line is a comment selects nothing.

**`FXL3` — Operators.** `|` is union, `&` intersection and `-` difference; `&`
binds tighter than `|` and `-`. A run of `|` or a run of `-` reads left to
right, but `|` and `-` side by side **must** be grouped by parentheses: a query
mixing them without is an error at the second operator. An operator is a token
on its own, so it must be separated from a bare piece by whitespace or a
parenthesis. _Detection:_ `a | b & c` groups as `a | (b & c)`; `a - b - c` as
`(a - b) - c`; `a | b - c` fails at the `-`; `a-b` is one path.

**`FXL4` — Function forms.** The parser **must** accept `unions(e, …)` with at
least one argument, `intersection(e, e)` and `difference(e, e)`, meaning the
same as the operators, and `fileFilter(p)`, the files whose predicate `p`
holds. A predicate is `hasExt(x)`, `name == n`, `name != n`, `type == t` or
`type != t`, with `t` `regular` or `symlink`, or `p && p`, `p || p`, `!p` and
parentheses over these. An argument is a path's text: bare, a glob over the
file's name or extension; quoted, literal. _Detection:_
`difference(unions(a, b), c)` and `(a | b) - c` resolve to the same members on
every fixture tree; `fileFilter(hasExt(d) && name != x.d)` selects the `.d`
files but `x.d` at every depth; `name == *_test.d` selects the tests, and
`name == "*_test.d"` only a file of that name.

**`FXL5` — `gitTracked()` needs a work tree.** A query calling `gitTracked()`
whose root is not inside a git work tree **must** fail with
`not a git work tree`, and select nothing, as `lib.fileset.gitTracked` throws.
_Detection:_ the same query succeeds in a fresh repository and fails in a plain
directory.

**`FXL6` — Errors have a place.** A query that does not parse **must** report
one error with a message and the byte offset it is about, including a glob's
own syntax errors: an unclosed `[` or `{`, an empty class or alternative, an
unmatched `}`, and an escape of a byte that is no metacharacter. _Detection:_
`(a | b` reports at its end; `a | [b` at the `[`; `unions()` at the `)`;
`a\ b` at the `\`.

**`FXL7` — A query has a canonical form.** Every query that parses has one
rendering, with comments dropped, function forms written as operators where an
operator exists, parentheses only where precedence needs them, and each path
written bare, quoting only the runs a bare piece cannot hold; it parses to the
same fileset. _Detection:_ the canonical form of every corpus query parses,
and resolves to the same members as the query.

**`FXL8` — The grammar is the parser's.** The tree-sitter grammar `fileset`
**must** accept exactly the queries the parser accepts, and give every token
the same kind: a path's literal text, bare or quoted; a glob metacharacter; an
escape; an operator; a function; a predicate; a comment; punctuation. Glob
metacharacters are `*`, `**`, `?`, a whole `[…]` class, and a brace group's
`{`, `,` and `}` — the alternatives between them are literal text.
_Detection:_ over a corpus of valid and invalid queries, the grammar's tree has
an error exactly when the parser fails, and on every byte of every token of a
query that parses, its highlight capture is the parser's token kind.

**`FXL9` — A bare call name hints.** A path whose whole text is the name of a
call without arguments (`all`, `none`, `exec`, `gitignored`, `gitTracked`) and
that matches nothing **must** say, where the result is shown, that the call is
written with parentheses. _Detection:_ the query `all` on a tree with no file
named `all` resolves to no members and its result line suggests `all()`.

## 3. The screen (`FXU`)

The screen is a title line, the query editor, a dock and a key hint line. The
dock holds the member tree on the left and, on the right, one tabbed group of
_Stats_, _Help_ and _Export_.

**`FXU1` — Live resolution.** Every edit that changes the query's text **must**
re-parse and, when it parses, re-resolve it and redraw the tree, the stats and
the export from the new result in the same frame. _Detection:_ in a recorded
run, the frame after a keystroke shows the new member count.

**`FXU2` — The editor is multi-line.** Enter inserts a newline; Tab and
Shift+Tab move focus between the editor and the dock; Ctrl+Enter leaves the
editor for the tree. The editor's height follows its lines up to a third of the
screen, and scrolls to keep the caret in view.

**`FXU3` — The caret is the terminal's.** While the editor has focus, the
caret **must** be drawn with the host's text cursor
([`HST20`](../ui-app/feature-requirements.md)) at the caret's cell, as a bar,
and no character of the query moves when the caret does: a terminal's cursor,
or on a window — raylib's and the native Vulkan host's alike, Android's
among them — a bar the host paints over the frame. When the editor loses
focus the cursor is hidden. _Detection:_ moving the caret left and right in a
recorded run leaves every glyph of the query line in its cell, and the
recording's cursor follows it.

**`FXU4` — Highlighting.** The query **must** be drawn with each token in its
kind's slot — the kinds `FXL8` makes the grammar's and the parser's alike — and
an error's bytes, or the bytes the Export tab's target refused, in the error
slot, without moving a character. _Detection:_ the spans of a query's line have
each token's kind's slot, and join to the line's text.

**`FXU5` — The two columns are alike.** Side by side, the tree and the
right tab group **must** each take half the width, the rule between them
aside, whichever tab shows: switching between Stats, Help and Export moves
nothing. A line wider than its half is clipped, or, in the Export tab,
scrolls across (`FXU22`). _Detection:_ at 100 and at 160 columns, the tree's
pane and the right group's are within a column of each other in width, the
same with each tab showing.

**`FXU6` — The tree is the members.** The tree's leaves **must** be the
resolved members and its inner nodes only the directories on the way to them,
each file showing its kind and size and each directory its member count and
total size, right-aligned at the row's end. Each directory lists its
directories, then its files, each by name. Disclosure is kept by path across
queries. _Detection:_ the tree's leaf paths equal the resolution's members,
`src/…` before `README.md`; a directory closed by the user stays closed after
an edit that keeps it.

**`FXU9` — Hue's tree: icons and connectors.** Each tree row **must** show
hue's file-type icon
([`XPL6`](../hue/tree-view.md#explorer-workspace-integration-xpl)): the Nerd
glyph and brand colour of its name's type, the open or closed folder glyph for
a directory in place of the disclosure marker, and the generic file glyph
otherwise. The table is one, in the toolkit, shared with hue. Its depth
**must** be drawn with hue's connectors, `├─`, `└─` and `│`, in every layout:
in the touch layout, whose rows are taller than a line, the `│` lines **must**
run on through the cells above and below each row's text, so they join from
row to row. _Detection:_ a recorded tree row of `x.md`, `dub.sdl` and a closed
directory carries the same glyph and colour as hue's explorer gives it; a
recorded touch frame's tree has `├─` before a row with later siblings and `│`
in the cells between two of them.

**`FXU7` — The help keeps the tree in view.** F1 **must** make the Help tab the
active tab of the right group, and F1 or Escape in it go back to the tab that
was active; the member tree is not hidden by it. _Detection:_ a recorded frame
after F1 shows the tree pane and the help's first heading.

**`FXU8` — Without a terminal, one frame.** When standard input or output is not
a terminal and `--gui` is not given, or `--render-plain` is, the explorer
**must** print one frame as text after the keys of `--keys`, and exit 0. CI's
example and app runs use it.

**`FXU26` — One window arm.** The explorer's window **must** be the native arm
on the desktop as on Android (`FXA1`): `sparkles:wsi` windows drawn by
`sparkles:ui-vulkan`, its command line taking the toolkit's window and font
options and the native window's own (`--window-system`, `--appearance`,
`--debug`) as flat flags. _Detection:_ `--help` lists `--window-system` and
`--debug`; `fileset-explorer --gui --debug frames=60` opens a native window,
presents 60 frames and exits 0.

**`FXU10` — Touch, and scrolling with momentum.** A tap **must** do what a click
does: on a tab of the right group it shows that tab's pane, on the Export
tab's ◀, ▶, glob mode or copy it does what `T`, `t`, `g` or `y` does, and
above the dock it focuses the query and, on a phone, asks for the soft
keyboard. The tree, the help and the Export code **must** scroll by the
distance a finger moves them, fraction of a row included, keep coasting on a
lifted finger's speed until it decays, and ease a wheel notch three rows on,
where the target can show part of a row — every window, the native one on
Android included, whose host **must** declare that it paints a fraction of a
cell (`subCellScroll`); on a terminal every scroll lands on a whole row at
once. Scrolling **must not** move the tree's cursor, and a key
that moves the cursor out of view **must** bring the view to it. _Detection:_
recorded taps switch the tabs and step the Export target; a precise scroll of
2.5 rows leaves the tree at 2.5 with its cursor on the first row; a notch
reaches 3 over several frames; the recogniser's fling tail moves the tree as
far as its events add up to; the native host's target declares
`subCellScroll`.

**`FXU11` — A touch layout.** On a target without hover, a touch screen, or with
`--touch`, the explorer **must** draw its touch layout: an app bar with the
title and the root; the query as a filled, rounded field with no border or
caption, its canonical form or error under it; a row of chips that insert the
operators, `**`, a string and a comment at the caret, and clear the query; the
right group's tabs as a segmented control; and no key hints. Every tap target
— a chip, a segment, an Export control — **must** be at least 48 dp tall
([`TOK11`](../design-system/SPEC.md)). The tree's rows are a dense list:
each **must** be at least 32 dp tall, and no taller than the fewest whole
cells that reach it. _Detection:_ a recorded touch frame has no `╭` and no key
hint, its tree rows are the dense list's height apart, and tapping `|` inserts
`|` at the caret.

**`FXU12` — Tablet and phone.** The touch layout **must** put the tree beside
the right group when the screen is at least as wide as two 48-column panes,
and the tree above it otherwise. _Detection:_ at 140×40 cells the tree and the
segments share their top row; at 60×60 the segments are below the tree.

**`FXU13` — Touch in the panes.** On the touch layout a tap on a directory
**must** open or close it, the tree's header **must** offer expanding and
collapsing every directory, the Stats tab **must** offer computing the ids of a
fileset too large to do it live, and the Export tab **must** choose the Nix glob
mode with a segmented control. Back **must** leave the help, then a tutorial's
tree, and only then quit (`INP13`). _Detection:_ recorded taps open and close a
directory, collapse and expand all, compute the ids and select `expand`.

**`FXU14` — Scrollbars.** The tree, the help and the Export code **must** each
draw an overlay scrollbar at their right edge when their content is taller than
their view: the thumb's length is the view's share of the content and its place
the view's position, a fraction of a cell included. On the touch layout the
bar fades out once the view stops and back in when it moves. With a pointer, a
press on the bar's column puts the thumb under the pointer, and dragging moves
the view with it. _Detection:_ a recorded frame of a long tree has a scrollbar
leaf whose content and viewport are the tree's and its view's heights in cells;
a recorded press and drag down the tree's bar scrolls the tree to its end.

**`FXU15` — The pointer over the editor.** With a pointer, the pointer **must**
be the text I-beam over the query editor, a hand over a tab, a chip or a button,
and the platform's default elsewhere; a click in the editor puts the caret at
the character under it. That holds for a mouse or touchpad on Android too,
where the pointer icon is resolved by the window's views: a hover **must**
reach them as well as the application. _Detection:_ recorded moves over the
query, a tab and the tree ask the host for `text`, `pointer` and `default`; a
click on the query's fifth column, past its two-cell prompt, puts the caret
before its third character.

**`FXU16` — Density.** The explorer **must** open with a 12-point cell font, a
third under the toolkit's default, on the desktop and on Android; `--font-size`
overrides it. _Detection:_ the command line's and the Android entry's options
carry 12 points.

**`FXU17` — Pills.** A chip and a segment on the touch layout **must** be drawn
32 dp tall in the middle of their 48 dp target, their label centred in them,
with room above and below it as well as beside it. A selected segment is drawn
inside its group's outline, as far from the outline's sides as from its top
and bottom. _Detection:_ every chip's box in a recorded touch frame is its
target's height and asks to be drawn at 32 dp.

**`FXU18` — Taps reach their pane.** A tap in the dock **must** go to the pane
under it, whichever pane an earlier tap went to. _Detection:_ recorded taps on
Stats, then on a directory, close the directory, and a tap on Stats after one
on the tree leaves the tree as it was.

**`FXU19` — The cheat sheet tries its snippets.** Each snippet in the cheat
sheet's Write column **must** be followed by a ▶; a tap on it, or on the
snippet, **must** put the snippet into the editor, a `\|` in it as `|`, and
resolve it against the directory, the help staying where it is. _Detection:_
the cheat sheet's snippets include `*.d`, `a | b` and `p || q` and none of
the keys table; a recorded tap on the ▶ after `src/*.d` makes it the query.

**`FXU20` — A long export scrolls as the rest do.** The Export code **must**
be highlighted once for each export, not each frame, and a frame **must**
build only the lines in view, so a fling over a long export runs at the frame
rate the tree's and the help's do. _Detection:_ a frame of a 300-line export
builds rows for no more lines than the view is tall, and its scroll still
spans every line.

**`FXU21` — The editor's clipboard.** In a window, the editor **must** take a
window's copy, cut and paste chords, and a paste **must** read the system
clipboard through the host ([`INP25`](../ui/input.md)),
the answer going in at the caret; on Android a soft keyboard's cursor keys,
its jumps to either end and its Select All **must** move and select in the
query as a hardware keyboard's keys do. _Detection:_ a recorded Ctrl+V in a
window asks the host for one clipboard read, and that read's answer is
inserted at the caret.

**`FXU22` — A wide export scrolls across.** A line of the Export code wider
than the pane **must** scroll across by a finger's or a trackpad's horizontal
motion, or a wheel's with Shift, under a header that stays; a snapshot's
paths and a long call **must** be written one to a line in the Nix
target. _Detection:_ a recorded horizontal pan over a 200-column export
moves its lines 30 columns and leaves the header; a union of eight paths is
written a path a line.

A code fence on a pixel target **must** be one surface from its top rule to
its bottom rule, rounded at its corners and stopping at its side rules, rather
than whole cells under its body; a background under a solid border **must**
stop at the border's lines.

A border caption drawn over its rule **must** mask the rule under it, on a
pixel target as on a terminal.

**`FXU23` — Export's controls beside the tabs.** On the touch layout, the
Export tab's target buttons, Nix's glob mode and Copy **must** share the row of
the Stats, Help and Export segments when that row has room for them in its half
(`FXU5`), the glob modes labelled `shim`, `expand`, `refuse` where `glob shim`
alone would not fit; on a screen too narrow for that, they stay at the head of
the pane. _Detection:_ at 140×40
with Export showing, ◀, the target, ▶, the three glob modes and Copy are on the
segments' row, and a tap on `expand` there selects it; at 60×60 the glob modes
are below the segments.

**`FXU24` — A code fence's frame is even, its badges on it.** On a pixel
target a code fence's border **must** be drawn as wide on its sides as on its
top and bottom, through the middle of its top and bottom rows as its glyphs
are, and its background **must** fill its rounded corners up to the border
with no gap. Its language label and a try block's ▶ **must** each be a rounded
badge centred on the top line, filled with the page's colour, so the line stops
at their outlines; the ▶ **must** be at the right end, read "▶ try it", and be
outlined in the success colour, unlike the label. _Detection:_ the fence painted
offscreen has a border of one width on all four sides, no background-coloured
pixel outside its border, and none of the page's under its top corners inside
it; the label and the ▶ are each in a rounded rectangle of the top row, left
and right, the ▶'s outlined in another colour; inside the ▶'s, on the line and
below it, is the page's colour.

**`FXU25` — A help fence scrolls across.** A fence in the help whose lines
are wider than its box **must** scroll them across under a finger or trackpad
moving more across than down, or a wheel turned with Shift, over it, its
frame and badges included, the page staying where it is. The axis is the
gesture's, chosen as it begins and kept to its end: a swipe begun across does
not hand itself to the page where the finger wavers. _Detection:_ at 140×40
the help's first fence shows `nix run github` and not the line's end; after a
finger moves 40 columns across over it, it shows the end and not the start,
and the help has not scrolled; a swipe begun across on the fence's top row,
whose later moves are more down than across, moves the fence and not the
page.

## 4. Help and runnable blocks (`FXT`)

The help is one markdown page, `docs/apps/fileset-explorer/index.md`, published
with the docs and compiled into the explorer, and drawn with the markdown view of
`sparkles:source-view`. Its tutorial is made of _try blocks_.

**`FXT1` — The try block.** A try block is a VitePress custom container:

````md
::: try fileset {tree=tutorial}

```fileset
src/**/*.d - **/*_test.d  # sources only
```

```tree
src/
├─ app.d
└─ lib.d
```

:::
````

The container's first word after `try` names a _runner_; `{…}` holds `key=value`
attributes for it. Its first fence is the input; an optional second fence is the
expected result. The markdown model of `sparkles:syntax` **must** parse it into
one node holding the runner, the attributes and both fences; a malformed one
(no runner, prose inside, no closer) stays the blocks it was made of. The HTML
renderer writes it as `<div class="try" data-runner="…">`, and the docs site,
whose container plugin knows no `try`, turns it into a card.

**`FXT2` — Try beside copy.** The markdown view **must** draw a ▶ affordance in
the input fence's header beside the copy affordance, when its host registered a
runner of that name, and none otherwise. Activating it calls the runner.

**`FXT3` — Runners.** A runner is named, and given the input text and the
attributes; its result is a widget tree the view draws under the block. A
runner of the host may also act on the host: the explorer's `fileset` runner
**must** replace the editor's text with the input and resolve it against the
tree the `tree` attribute names (or the open directory when there is none), so
the member tree shows the result; under the block it draws the members as
`lib.fileset.trace` lists them, checked against the expected fence.

**`FXT4` — Named trees.** A fence whose language is `tree-literal` and whose
info string carries `{#name}` declares a tree in the
[tree-literal format](../build-primitives/filesets/SPEC.md) under `name`, for the
page that holds it. A try block's `tree=name` resolves against it in memory; the
explorer's header then says `tutorial tree` and Escape returns to the
directory. _Detection:_ a try block naming an undeclared tree reports it under
the block.

**`FXT5` — The tutorial is checked.** For every try block of the help with an
expected-result fence, the runner's result rendered as text **must** equal that
fence. _Detection:_ the app's test runs every block; editing a fence breaks it.

## 5. Code generators (`FXE`)

A generator translates a query into another system's notation. Generators are a
library, `sparkles.build_primitives.fileset.emit`, used by the explorer's Export
tab and by `fileset-explorer --emit <target>`.

**`FXE1` — Exact or refused.** For a query `q` and a target `t`, a generator
**must** return either code that makes `t` select exactly `q`'s members on every
tree under the stated conditions of its target, or a refusal naming the
construct `t` cannot express, its byte span in the query, and why. _Detection:_
each target's oracle test (§[testing](./testing.md)).

**`FXE2` — Normalization first.** Before deciding, a generator **must** rewrite
the query by meaning-preserving rules: unions and intersections flattened,
`a - (b | c)` into `(a - b) - c`, `a & b` of an anchored literal directory and a
glob into one glob, `none` and `all` simplified away. A query is refused only
when its normalized form is outside the target's grammar.

**`FXE3` — Nix.** The `nix` target emits a `lib.fileset.toSource` expression
whose `root` is the explorer's directory. Unions, intersections and differences
map to `lib.fileset.unions`, `intersection` and `difference`; `fileFilter`
predicates map to `lib.fileset.fileFilter` over `file.name`, `file.type` and
`file.hasExt`; `gitTracked` to `lib.fileset.gitTracked`. A glob is translated
by the _glob mode_:

| Mode             | A glob becomes                                                                                                                         |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `shim` (default) | a call of `glob`, a function the output defines in a `let`, which walks the root with `builtins.readDir` and matches the glob's regex  |
| `expand`         | `lib.fileset.unions` of the paths it matches in the open directory now; the header names it as a snapshot                              |
| `refuse`         | `fs.maybeMissing` of the path when the glob is a literal anchored path; otherwise a refusal (a name pattern also selects directories') |

Before its mode, a glob that names files at any depth, `**/` then a name with
no `/` (`**/*.md`, `**/*.{md,json}`, `**/*_test.d`), or the same beneath an
anchored literal directory (`src/**/*.d`), **must** be emitted as
`lib.fileset.fileFilter` over the root or that directory: `*.ext` as
`file.hasExt`, several as `builtins.any file.hasExt [ … ]`, a literal name as
`file.name ==` and any other name as `builtins.match` on it. A glob also
selects the files of a directory it matches, which `fileFilter` never sees,
so the rewrite is made only when no directory in the open directory matches
the glob, and the directory filtered exists there (decision X17).

`exec` **must** be refused in every mode, because evaluation cannot see the
executable bit. `gitignored` **must** be emitted as the root minus
`gitTracked()` only when the open directory is a git work tree with no untracked,
unignored file and no tracked, ignored one; otherwise refused.

**`FXE4` — git pathspec.** The `git-pathspec` target emits a
`git ls-files --cached --others --` command with `:(glob)` and
`:(exclude,glob)` pathspecs, braces expanded, selecting the members among the
files git lists. It accepts a normalized query of the form
`(g1 | … | gn) - (h1 | … | hm)` of globs; `gitTracked()` alone, or intersected
with such a form, adds no pathspec and drops `--others`. A `fileFilter` by name
is refused, since a pathspec also matches a directory's contents. Git matches
an exclude against paths shorn of the includes' common literal directory, so an
exclude that floats (unanchored, or led by `**`) carries that directory, which
every included path has.

**`FXE5` — gitignore.** The `gitignore` target emits a `.gitignore` that, in a
repository holding exactly the root's files, leaves exactly the members
unignored: `*` first, then each rule of the query's decision list, a `!pattern`
to keep or a `pattern` to drop, last match winning, and `!*/` last, so a file
beneath a dropped directory can still be kept. It accepts what `rsync` accepts
(`FXE6`).

**`FXE6` — rsync.** The `rsync` target emits a filter file for
`rsync -r --prune-empty-dirs --filter='merge FILE'`, rules first-match-wins:
`+ */` first, so every directory is entered, then the decision list, then
`- *`. The decision list accepts `D ::= g | D | g | g | D | D - g`, where `g`
is a glob, a `fileFilter` by name, or a union of them: a union with a glob puts
an include ahead of the rest, a difference an exclude. A glob is written as the
path and everything beneath it, and, because rsync's `**` needs the slashes
around it, also without each `**` segment. Intersections `FXE2` does not fold,
and differences whose right side is no glob, are refused.

**`FXE7` — tar.** The `tar` target emits a GNU `tar -c` command line: the paths
to archive are named literally, and the excluded globs as `--exclude=PATTERN`
with `--anchored` or `--no-anchored` as each needs and
`--no-wildcards-match-slash`. It accepts `(p1 | … | pn) - (h1 | … | hm)` where
every `p` is `all`, a literal anchored path or `d/**`, and every `h` a glob
without `**` (but a trailing one), not restricted to directories; tar's exclude
also takes a directory's contents, as a glob does.

**`FXE8` — Cargo.** The `cargo` target emits a `[package]` `include` array of
gitignore-style patterns. Cargo ignores `exclude` beside `include`, and
packages `Cargo.toml` and the `README.md`, `README.txt` or `README` it finds
whatever `include` says; so it accepts a union of globs, without `fileFilter`
by name, and refuses one that leaves out such a file the root has.

**`FXE9` — Bazel.** The `bazel` target emits
`glob(include = […], exclude = […], exclude_directories = 1)`. It accepts the
form of `FXE4`, braces expanded, and a `fileFilter` by name (a Bazel pattern
matches whole file paths); it refuses `?` and character classes, which Bazel's
glob lacks. It holds for a root that is one Bazel package (no `BUILD` file
beneath it).

**`FXE10` — dub.** dub's own globs list directories as source files, and its
`excludedSourceFiles` globs miss, so no dub glob is exact: the `dub` target
emits the members as `sourceFiles`, a snapshot, with no `sourcePaths` or
`importPaths`. It refuses when a member is a file dub hands the linker
instead (`.o`, `.obj`, `.a`, `.lib`, `.so`, `.dylib`, `.dll`, `.res`, `.def`).

**`FXE11` — The command line.** `fileset-explorer --emit <target> --query Q`
**must** print the code and exit 0, or print the refusal and the refused text
to standard error and exit 2; a target or mode it does not know, or a query
that does not resolve, exits 1. `--nix-globs=shim|expand|refuse` selects
`FXE3`'s mode.

**`FXE12` — The Export tab.** The Export tab **must** show the selected target's
code for the current query, highlighted when a grammar for the target exists, or
its refusal with the refused span marked in the editor, and offer copying it.
The target and the Nix glob mode are chosen in the tab.

## 6. On Android (`FXA`)

**`FXA1` — An APK.** The explorer **must** build as an Android application:
its `android` dub configuration, a shared library on the native window arm
(`sparkles:wsi`, drawn by `sparkles:ui-vulkan`), with no terminal stack, packed
with its grammar parsers into an APK. _Detection:_ `nix build
.#fileset-explorer-apk` succeeds, and the APK launches on a device.

**`FXA2` — The repository is the root.** The APK **must** carry the sparkles
repository's tracked files, except dot-entries, which Android's asset packer
drops, and the explorer **must** open on them as its fileset root, extracted
into the app's data directory on the first launch and again when they change.
`gitTracked()` fails there, as outside any work tree (`FXL5`). _Detection:_ on a
device, the default query lists the repository's markdown files and recipes.

**`FXA3` — Highlighting on the device.** The query, the help and the Export
code **must** be highlighted on Android as on the desktop, from parsers loaded
by name from the application's libraries and queries extracted with the
assets. _Detection:_ on a device, the help renders as markdown, not as its
text.

## 7. Surface

Non-normative: where the parts live.

| Requirements          | Where                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FXL1`–`FXL7`, `FXL9` | `sparkles.build_primitives.fileset.query` (`parseQuery`, `compileQuery`, `canonical`, `gitTrackedPaths`)                                                                                                                                                                                                                                                                                                                                             |
| `FXL8`                | `nix/packages/tree-sitter-fileset/` (`grammar.js`, `queries/highlights.scm`)                                                                                                                                                                                                                                                                                                                                                                         |
| `FXU1`–`FXU8`         | `apps/fileset-explorer` (`explorer.d`, `evaluate.d`, `member_tree.d`, `render.d`)                                                                                                                                                                                                                                                                                                                                                                    |
| `FXU9`                | `sparkles.ui.components.file_icons` (`fileIcon`, `folderGlyph`), shared with hue's explorer                                                                                                                                                                                                                                                                                                                                                          |
| `FXU10`–`FXU24`       | `apps/fileset-explorer` (`explorer.d`, `launch.d`); `sparkles.ui.components.scroll_body` (`ScrollBody`); `sparkles.source_view.markdown` (`MdViewOptions.codeActionGlyph`); `sparkles.ui.pixel_geometry` (`fillInsideBorder`, `insideGlyphFrame`, `insetSpan`); `sparkles.wsi.platform.android`; `sparkles.ui_app.native_loop` (`paintTextCursor`); `sparkles.android.ime_diff` (`moveOf`); `sparkles.build_primitives.fileset.emit.nix` (`nixCall`) |
| `FXU26`               | `apps/fileset-explorer` (`dub.sdl`, `app.d`, `launch.d`); `sparkles.ui_app.gui_options` (`GuiOptions`, `NativeOptions`)                                                                                                                                                                                                                                                                                                                              |
| `FXA1`–`FXA3`         | `apps/fileset-explorer/src/android_entry.d`, `nix/packages/android/fileset-explorer.nix`                                                                                                                                                                                                                                                                                                                                                             |
| `FXT1`, `FXT2`        | `sparkles.syntax.md.model` (`MdBlockKind.tryBlock`), `sparkles.source_view.markdown` (`tryRunners`)                                                                                                                                                                                                                                                                                                                                                  |
| `FXT3`–`FXT5`         | `apps/fileset-explorer` (`help.d`)                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `FXE1`–`FXE10`        | `sparkles.build_primitives.fileset.emit` (`emit`; `ir`, `nix`, `lists`)                                                                                                                                                                                                                                                                                                                                                                              |
| `FXE11`, `FXE12`      | `apps/fileset-explorer` (`app.d`, `export_tab.d`)                                                                                                                                                                                                                                                                                                                                                                                                    |
