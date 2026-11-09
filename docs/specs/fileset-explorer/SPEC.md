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
help and the runnable blocks of its tutorial (§4), and the code generators (§5).
Two obligations belong to libraries it uses and are specified there: the host's
text cursor ([`HST20`](../ui-app/feature-requirements.md)) and the explicit
path-list leaf of a fileset ([`FSV6`](../build-primitives/filesets/SPEC.md)).
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

**`FXL1` — Leaves.** A query's leaves **must** be:

- a _glob_, with the fileset library's syntax and meaning
  ([`FSG1`](../build-primitives/filesets/SPEC.md#5-matching-fsg)): `*`, `**`, `?`,
  `[…]`, `{a,b}`, `\` escapes, `.gitignore`'s anchoring, and a matched directory
  selecting every file beneath it;
- a _string_, `"…"`, which is a glob whose text may contain any character;
  inside it `\"` is a quote and `\\` a backslash, and every other byte is
  itself;
- a keyword: `all`, `none`, `exec` (executable regular files), `gitignored`
  (the files git's ignore rules exclude) or `gitTracked` (the files in git's
  index).

A bare glob is a run of bytes containing no whitespace, no `(`, `)`, `,` or
`"`, that is not a keyword. _Detection:_ `a-b/*.d`, `"#foo#"`, `"a b"` and
`"say \"hi\""` each parse to one glob of the expected text.

**`FXL2` — Comments.** A `#` where a token could begin **must** start a comment
that runs to the end of its line. A `#` inside a bare glob or a string is part
of it. _Detection:_ `a#b` is one glob; `a #b` is the glob `a`; `"#b"` is a glob;
a query whose every line is a comment selects nothing.

**`FXL3` — Operators.** `|` is union, `&` intersection and `-` difference;
`&` binds tighter than `|` and `-`, which are equal and left-associative, and
parentheses group. An operator is a token on its own, so it must be separated
from a bare glob by whitespace or a parenthesis. _Detection:_ `a | b & c - d`
groups as `(a | (b & c)) - d`; `a-b` is one glob.

**`FXL4` — Function forms.** The parser **must** accept `unions(e, …)` with at
least one argument, `intersection(e, e)` and `difference(e, e)`, meaning the
same as the operators, and `fileFilter(p)`, the files whose predicate `p`
holds. A predicate is `hasExt("x")`, `name == "n"`, `type == "regular"` or
`type == "symlink"`, or `p && p`, `p || p`, `!p` and parentheses over these.
_Detection:_ `difference(unions(a, b), c)` and `(a | b) - c` resolve to the
same members on every fixture tree; `fileFilter(hasExt("d") && !name == "x.d")`
selects the `.d` files but `x.d` at every depth.

**`FXL5` — `gitTracked` needs a work tree.** A query containing `gitTracked`
whose root is not inside a git work tree **must** fail with
`not a git work tree`, and select nothing, as `lib.fileset.gitTracked` throws.
_Detection:_ the same query succeeds in a fresh repository and fails in a plain
directory.

**`FXL6` — Errors have a place.** A query that does not parse **must** report
one error with a message and the byte offset it is about, including errors
inside a glob, whose offset is the glob's own plus the library's. _Detection:_
`(a | b` reports at its end; `a | [b` at the `[`; `unions()` at the `)`.

**`FXL7` — A query has a canonical form.** Every query that parses has one
rendering, with comments dropped, function forms written as operators where an
operator exists, and parentheses only where precedence needs them; it parses to
the same fileset. _Detection:_ the canonical form of every corpus query parses,
and resolves to the same members as the query.

**`FXL8` — The grammar is the parser's.** The tree-sitter grammar `fileset`
**must** accept exactly the queries the parser accepts, and give every token
the same kind (glob, string, keyword, operator, function, predicate, comment,
punctuation). _Detection:_ over the corpus of `fileset_query.corpus`, valid
and invalid, the grammar has an error node exactly where the parser fails, and
the highlight captures equal the parser's token kinds byte for byte.

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
and no character of the query moves when the caret does. When the editor loses
focus the cursor is hidden. _Detection:_ moving the caret left and right in a
recorded run leaves every glyph of the query line in its cell, and the
recording's cursor follows it.

**`FXU4` — Highlighting.** The query **must** be drawn with the token kinds of
`FXL8` in the theme's syntax slots, as the grammar's highlight query assigns
them, and an error's span in the error slot. _Detection:_ a recorded frame of a
query with every token kind has each kind's span in its slot.

**`FXU5` — The right column fits its content.** The Stats tab **must** be as
wide as its widest line, ids included, when the tree's widest row still fits
beside it; otherwise the tree keeps at least half the width and the stats
column is clipped. _Detection:_ at 160 columns the full castore id is shown; at
80 the tree keeps 40.

**`FXU6` — The tree is the members.** The tree's leaves **must** be the
resolved members and its inner nodes only the directories on the way to them,
each file showing its kind and size and each directory its member count and
total size. Disclosure is kept by path across queries. _Detection:_ the tree's
leaf paths equal the resolution's members; a directory closed by the user stays
closed after an edit that keeps it.

**`FXU9` — File-type icons.** Each tree row **must** show hue's file-type icon
([`XPL6`](../hue/tree-view.md#explorer-workspace-integration-xpl)): the Nerd
glyph and brand colour of its name's type, the open or closed folder glyph for
a directory in place of the disclosure marker, and the generic file glyph
otherwise. The table is one, in the toolkit, shared with hue. _Detection:_ a
recorded tree row of `x.md`, `dub.sdl` and a closed directory carries the same
glyph and colour as hue's explorer gives it.

**`FXU7` — The help keeps the tree in view.** F1 **must** make the Help tab the
active tab of the right group, and F1 or Escape in it go back to the tab that
was active; the member tree is not hidden by it. _Detection:_ a recorded frame
after F1 shows the tree pane and the help's first heading.

**`FXU8` — Without a terminal, one frame.** When standard input or output is not
a terminal, or `--render-plain` is given, the explorer **must** print one frame
as text after the keys of `--keys`, and exit 0. CI's example and app runs use
it.

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
one node holding the runner, the attributes and both fences, and a page without
the container type registered **must** still render it as a plain container.

**`FXT2` — Try beside copy.** The markdown view **must** draw a ▶ affordance in
the input fence's header beside the copy affordance, when its host registered a
runner of that name, and none otherwise. Activating it calls the runner.

**`FXT3` — Runners.** A runner is named, and given the input text and the
attributes; it returns a widget tree that the view draws under the block. A
runner of the host may also act on the host: the explorer's `fileset` runner
**must** replace the editor's text with the input, resolve it against the tree
the `tree` attribute names (or the open directory when there is none), and
return the member tree.

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

| Mode             | A glob becomes                                                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `shim` (default) | a call of `glob`, a function the output defines in a `let`, which walks the root with `builtins.readDir` and matches the glob's regex |
| `expand`         | `lib.fileset.unions` of the paths it matches in the open directory now, marked in a comment as a snapshot                             |
| `refuse`         | a path or `fileFilter` when the glob is a literal path or a pure name/extension pattern; otherwise a refusal                          |

In the `shim` mode `exec` **must** be refused, because evaluation cannot see
the executable bit, and `gitignored` **must** be emitted as the files under the
root minus `gitTracked` only when the open directory is a git work tree with no
untracked, unignored files; otherwise refused. The case-insensitive policy is
refused in every mode.

**`FXE4` — git pathspec.** The `git-pathspec` target emits arguments for
`git ls-files --cached --others --`, with `:(glob)` and `:(exclude,glob)`
magic, selecting the members among the files git lists. It accepts a
normalized query of the form `(g1 | … | gn) - (h1 | … | hm)` of globs, braces
expanded into separate pathspecs; `gitTracked` alone, or intersected with such a
form, adds no pathspec and drops `--others`. Anything else is refused.

**`FXE5` — gitignore.** The `gitignore` target emits a `.gitignore` that, in a
repository holding exactly the root's files, leaves exactly the members
unignored: `/*` and `!*/` first, then for each rule of a decision list built
from the query, a `!pattern` to keep or a `pattern` to drop, last match
winning. It accepts the queries the `rsync` target accepts (`FXE6`).

**`FXE6` — rsync.** The `rsync` target emits a filter file for
`rsync -r --filter='merge FILE' --prune-empty-dirs`, rules first-match-wins.
It accepts the decision-list grammar
`D ::= glob | D | glob | glob | D | D - glob`, where a glob may also be a union
of globs: a union with a glob prepends an include, and a difference prepends an
exclude; the list ends with `+ */` and `- *`. Intersections other than those
`FXE2` folds, and differences whose right side is not a glob, are refused.

**`FXE7` — tar.** The `tar` target emits a GNU `tar -c` command line: members to
include are named as literal paths, and excluded ones as `--exclude=PATTERN`
(with `--anchored` and `--wildcards-match-slash` set as each pattern needs).
It accepts `(p1 | … | pn) - (h1 | … | hm)` where every `p` is a literal path or a
directory glob `d/**`.

**`FXE8` — Cargo.** The `cargo` target emits a `[package]` `include` array of
gitignore-style patterns. Cargo ignores `exclude` when `include` is present and
always adds `Cargo.toml`, so it accepts a union of globs, and refuses a query
that leaves out `Cargo.toml` when the root has one.

**`FXE9` — Bazel.** The `bazel` target emits
`glob(include = […], exclude = […], exclude_directories = 1)`. It accepts the
form of `FXE4` with braces expanded, refuses globs with character classes, and
holds only for a root that is one Bazel package (no `BUILD` file beneath it).

**`FXE10` — dub.** The `dub` target emits SDLang for a package: no
`sourcePaths` or `importPaths`, `sourceFiles` the included globs and
`excludedSourceFiles` the excluded ones. It accepts the form of `FXE4`.

**`FXE11` — The command line.** `fileset-explorer --emit <target> --query Q`
**must** print the code and exit 0, or print the refusal to standard error and
exit 2. `--nix-globs=shim|expand|refuse` selects `FXE3`'s mode.

**`FXE12` — The Export tab.** The Export tab **must** show the selected target's
code for the current query, highlighted when a grammar for the target exists, or
its refusal with the refused span marked in the editor, and offer copying it.
The target and the Nix glob mode are chosen in the tab.

## 6. Surface

Non-normative: where the parts live.

| Requirements     | Where                                                                                           |
| ---------------- | ----------------------------------------------------------------------------------------------- |
| `FXL1`–`FXL7`    | `sparkles.build_primitives.fileset.query` (`parseQuery`, `QueryNode`, `canonical`, `toFileset`) |
| `FXL8`           | `nix/packages/tree-sitter-fileset/` (`grammar.js`, `queries/highlights.scm`)                    |
| `FXU1`–`FXU8`    | `apps/fileset-explorer` (`explorer.d`, `stats.d`, `query_editor.d`)                             |
| `FXU9`           | `sparkles.ui.components.file_icons` (`fileIcon`, `folderIcon`), shared with hue's explorer      |
| `FXT1`, `FXT2`   | `sparkles.syntax.md.model` (`MdKind.tryBlock`), `sparkles.source_view.markdown`                 |
| `FXT3`–`FXT5`    | `apps/fileset-explorer` (`help.d`, `runners.d`)                                                 |
| `FXE1`–`FXE10`   | `sparkles.build_primitives.fileset.emit` (`emit`, one module per target)                        |
| `FXE11`, `FXE12` | `apps/fileset-explorer` (`app.d`, `export_tab.d`)                                               |
