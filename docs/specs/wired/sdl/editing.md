---
status: accepted
owner: sparkles:wired
reviewed: 2026-10-27
---

# `sparkles.wired.sdl` — Lossless editing

## Abstract

`sparkles:wired` edits SDL documents in place. A caller selects nodes,
values and attributes through the parsed document, states the change, and
gets back the original text with only the affected bytes rewritten: comments,
quoting, blank lines, indentation and line endings elsewhere survive exactly.
Every edit is confined to the range its operation names and is checked by
re-parsing, so a tool built on it cannot quietly reformat or corrupt a file
it was asked to touch.

## Introduction

Repository tooling edits `dub.sdl` recipes and the recipes embedded in
single-file D programs: it normalizes managed build types, inserts a missing
`checked` build type, rewrites in-tree dependency versions to paths, and
patches test fixtures. People own these files. They keep comments in them,
group settings deliberately, and review every diff. A tool that rewrites a
whole file to change one line produces a diff nobody can review.

The SDL backend's writer is semantic by design ([SPEC §9](./SPEC.md#9-canonical-semantic-writer)):
it emits a canonical spelling and drops comments and layout. So every
editing tool in the repository grew its own text surgery — regular
expressions that assume a closing brace sits in column zero, substring tests
that a comment also satisfies, a global `strip` that rewrites trailing
whitespace. Each one is a small parser with its own bugs, and none of them
can say what it guarantees.

This page specifies one editing layer instead. Its central idea is that an
edit is a set of byte-range replacements over the unchanged source,
computed from the parsed document's exact spans and rendered through the
canonical scalar writer. Because the parser already records where every
node, value and attribute is, the editor never re-derives structure from
text; because it only replaces ranges, everything it does not name is
preserved by construction. The replacement-range primitive itself is not
SDL-specific and is owned by `sparkles:base`
([text edits](../../base/text/edits.md)), shared with the D formatter.

Out of scope: a concrete syntax tree with editable trivia objects,
incremental re-parsing, and edit sessions whose node handles survive
across commits (see [§8](#8-deferred-capabilities)). The canonical writer
stays the way to produce a document from a typed value.

## Contract at a glance

| ID    | Obligation                                                                                   |
| ----- | -------------------------------------------------------------------------------------------- |
| SDE1  | Every changed byte lies inside the range the operation names for its target                  |
| SDE2  | The output re-parses under the same profile, and each target has its new meaning             |
| SDE3  | Overlapping or out-of-bounds edits are rejected, never merged                                |
| SDE4  | Inserted text takes the host's newline sequence and the anchor's indentation                 |
| SDE5  | Removal follows the node's extent, so neighbours on the same line or block survive           |
| SDE6  | Comments are addressable as spans, so a comment-delimited region is a first-class range      |
| SDE7  | Embedded-recipe edits apply to the host file and leave DUB and the D compiler agreeing       |
| SDE8  | Editing allocates only through the editor's buffers and the caller's allocator; `@safe pure` |
| SDE9  | Every in-repository SDL edit, read and detection goes through this layer or the schema       |
| SDE10 | Replacement text survives the editor growing or moving                                       |

## 1. Model

An editor borrows a parsed `SdlDocument`, which owns a copy of its source
([performance SDP3](./performance.md)), and the **host text** the edits
apply to. For a recipe file the host is that source. For a recipe embedded
in a D program it is the whole program, and the document was parsed from a
rendering of it that has the same length and the same offsets
([SDE7](#4-requirements)). The editor accumulates edits; it never mutates
the document or the host. Each operation resolves, when it is made, to one
or more [`TextEdit`](../../base/text/edits.md) replacements of host byte
ranges, ordered as base text edits require.

Writing first renders the edited host into an editor-owned buffer,
re-parses it (SDE2), and only then copies it to the caller's writer; on any
failure nothing reaches the writer. The document, the host and the edit set
stay unchanged, so a caller may write the same set twice or discard it.

Operations name views of the original document. An operation whose range
overlaps one made earlier in the same set is a conflict (SDE3), not a
silent no-op.

## 2. Layout the parser records

Lossless editing needs layout the semantic document does not keep today.
The parser records, as byte spans:

- for every node, its **extent**: the bytes that belong to it and to
  nothing else (below);
- for every node with a child block, the offsets of its `{` and `}`;
- every comment, with its kind (line or block), in source order.

Every extent lies inside the document's **content**: the source after any
byte-order mark, and for an embedded recipe the bytes after `dub.sdl:` and
before the closing `+/`. Whatever the rules below say, an extent is clipped
to the content.

A node is **alone on its lines** when no other node's tokens and no `{` or
`}` of an enclosing node share a line with it. Then its extent is whole
lines: from the first byte of its first line through the logical newline
that ends its terminator's line, trailing comment included. Otherwise its
extent is **inline**, and never crosses a `{` or `}` the node does not own
or another node:

- it starts at the end of the preceding terminator (or of the enclosing
  block's opening terminator) — or, for a node that starts its line, at the
  node's first byte, after the line's indentation;
- it ends after its own terminator when that is a `;`, taking the spaces
  and tabs that follow when the node started its line; and just before its
  terminator when that is the line's newline, which the line still needs.

So in `a 1; b 2⏎` the extent of `a` is `a 1; ` and removing it leaves
`b 2⏎`; the extent of `b` is ` b 2`, and removing it leaves `a 1;⏎`. In
`a {; b 1; }` the extent of `b` is ` b 1;`, leaving `a {; }`.

Leading comments are not part of an extent. An operation may opt in to
treating the **attached comments** of a node — the maximal run of
comment-only lines directly above it, with no blank line between — as part
of its range.

Recording layout must not change any parse result, error, position, or
round-trip law of the semantic document.

## 3. Operations

The set is the union of what the repository's editors do
([§7](#7-migration-coverage)), not a general tree API. The range column is
normative: it is what SDE1 checks.

| Operation                   | Range it may change                                                                                                                                                                             | Resolves to                                                                                                |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| replace a value             | the value's span                                                                                                                                                                                | the canonical spelling of the new scalar                                                                   |
| replace an attribute        | the attribute's span                                                                                                                                                                            | `name=value`, with a new name and/or value; the separator before it is untouched                           |
| set an attribute            | an existing singular attribute's span; otherwise the point after the node's last value or attribute, or after its name if it has none                                                           | replace in place, or insert ` name=value`; a name held by more than one attribute is `editAmbiguousTarget` |
| remove an attribute         | the attribute's span and the spaces and tabs before it on its line; when a `\` continuation separates it from the previous token, also that `\`, the spaces and tabs before it, and its newline | deletion; a comment between the `\` and the attribute makes it `editUnsupportedLayout`                     |
| insert child nodes          | one point: the start of a whole-line sibling's extent, its end, or the start of a block's `}` line (the end of the content for the root); for an inline anchor, its extent's end or start       | the fragment, re-indented and separated (SDE4)                                                             |
| append to a node            | for a node with a block, as inserting before its `}` line; for one without, the point after its last value, attribute or name, before any trailing comment and its terminator                   | without a block: ` {`, a newline, the fragment, a newline, the node's indentation and `}`                  |
| remove a node               | the node's extent, plus its attached comments when asked, plus the one blank line or newline SDE5 names                                                                                         | deletion                                                                                                   |
| replace a node's block body | the bytes strictly between its `{` terminator and the start of its `}` line                                                                                                                     | the fragment, re-indented                                                                                  |
| replace a region            | a span of the content the caller derives from the document, such as the lines from one comment through another (a managed region)                                                               | the caller's text                                                                                          |

Fragments are SDL source text, not typed values. The editor parses a
fragment under the document's profile and rejects it unless it is a
sequence of whole nodes; comments in it are kept. At an inline anchor (an
inline sibling, or a block whose `}` shares a line with content) a fragment
must be a single node without a child block, and is inserted on that line
with a `; ` separator; anything else there is `editUnsupportedLayout`.
Re-indentation prefixes only the lines that begin outside a string or a
continued line, so multi-line backtick strings and `\` continuations keep
their bytes. Values and attributes are rendered with the canonical scalar
writer; a caller with a typed value renders it with `writeSDL` first.

Set-style operations are idempotent: setting an attribute to the value it
already has produces no edit.

## 4. Requirements

**SDE1 — Edits stay in their range.** For every operation, every byte
that differs between host and output lies inside the range §3 gives for its
target, and the bytes the operation was asked to change do change.
_Oracle:_ hand-annotated fixtures that list each operation's expected range
(CRLF, lone CR, U+2028, no final newline, a byte-order mark, tabs,
`;`-separated nodes, one-line blocks, comments in every position, embedded
recipes with `+/` on the last recipe line), and a property test over the
repository's recipes that compares host and output byte by byte against the
union of the resolved targets' ranges. _Violation:_ a differing byte
outside every target's range.

**SDE2 — The result means what was asked.** The output parses under the
source's profile; every target has its new value, name or absence; and
every node outside the targets' subtrees is semantically equal to its
counterpart in the source. Writing performs this check and returns
`editResultInvalid` instead of output when it fails. _Oracle:_ in tests, a
reference model that applies the operation to the conformance suite's
normalized tree, compared with the output's normalized tree. _Violation:_ a
parse failure, a target without its new meaning, or a changed bystander.

**SDE3 — Conflicts are errors.** Two resolved ranges that overlap, or a
range outside the content, make the edit set fail with `editConflict`
naming both operations. An insertion at the start or end of another
operation's range is not an overlap: it applies before or after that range
respectively, and insertions at one point apply in the order they were
made. _Violation:_ output produced from a conflicting set.

**SDE4 — Newlines and indentation follow the host.** Inserted lines are
separated from the surrounding bytes by newlines: one before the text
when the insertion point is not at a line start, and one after it unless
the point is the end of a host that has no final newline. So appending to
`name "x"⏎` gives `name "x"⏎`, the text and a newline; appending to a file
`name "x"` without a final newline gives `name "x"`, a newline and the
text, still without one; and appending to the recipe line `name "x" +/`,
whose content ends after the space, gives `name "x" `, a newline, the text,
a newline and `+/`. The newline
used is the one that ends the anchor's line in the host; where that line
has none, the nearest preceding line's; else `\n`. Inserted lines are
indented like the anchor sibling; in a block with no children, like the
parent plus one level, where a level is the document's first indentation
step, else four spaces. Nothing outside the inserted text changes its
newline or indentation. _Violation:_ a mixed-newline result from a
single-style host, a joined line, a gained final newline, or a mis-indented
line.

**SDE5 — Removal follows the extent.** Removing a node deletes exactly its
extent (and its attached comments when asked). When the extent was whole
lines and a blank line both precedes and follows it, the preceding blank
line goes too, so no double blank line remains. When the removed node was
the last thing in a host without a final newline, the newline before it
goes instead of the one after, so the host gains none. Both extra
deletions are part of the operation's range (§3). _Violation:_ a removed
neighbour, a residual terminator or indentation, or a gained final newline.

**SDE6 — Comments are addressable.** The document exposes every comment
the lexer consumed as a span in source order with its kind and text, so a
caller finds a marker comment without scanning the text. _Violation:_ a
consumed comment the document does not report.

**SDE7 — Embedded recipes edit the host.** The recipe of a single-file
package is parsed from a rendering of the host that has the same length,
keeps every logical newline sequence (`\n`, `\r`, `\r\n`, U+2028, U+2029)
byte for byte, and blanks every other byte outside the recipe to a space;
edits apply to the host. DUB takes the recipe to end at the first `+/`
(DUB `source/dub/dub.d:603`), while the D compiler nests `/+ +/`. After
writing, the editor re-locates the recipe in the output: its first `+/`
must be where the original one maps under the edits (TXE4), and the number
of `/+` sequences inside it — counting any formed across an edit's boundary
— must be unchanged. Otherwise the write fails with `editFragmentInvalid`.
_Violation:_ a host that DUB and the D compiler read differently, or whose
recipe DUB reads differently from the intended result.

**SDE8 — Allocation discipline.** Resolving and writing is `@safe pure`.
The rendered output and replacement text live in editor-owned buffers; the
re-parse uses the allocator the caller passes to `write`; nothing else
allocates. _Oracle:_ a `@safe pure nothrow @nogc` test over a non-GC writer
and allocator.

**SDE9 — No ad-hoc SDL remains.** Every D site in the repository that
reads, edits or detects SDL goes through this layer, the document API, or
the `dub.sdl` schema (`sparkles.build_primitives.dub_manifest`). Byte
hashing and existence checks are not SDL work. The oracle has two parts:

- **Completeness:** each [§7](#7-migration-coverage) row is migrated, and
  the S15 gate re-runs the repository inventory with an independent
  reviewer, recording the result in §7.
- **Regression:** an `apps/ci` audit flags, in D sources outside
  `libs/wired/src/sparkles/wired/sdl/`,
  `libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d` and
  `unittest` blocks, any call of `canFind`, `indexOf`, `startsWith`,
  `endsWith`, `replace`, `split`, `splitter`, `lineSplitter`, `matchFirst`,
  `matchAll`, `regex` or `ctRegex` whose argument is a string literal, or a
  module-level string constant, containing `dub.sdl:`, `+/`, `buildType`,
  `configuration "`, `dependency "`, `subPackage`, `dflags`, `lflags` or
  `test-runner`.

Hits that are not SDL work — a test runner matching its own name in a
stack frame, the `dub.json` reader's `dflags-` keys — go on an allowlist
kept beside the audit, each with the reason it was reviewed.

_Violation:_ an unmigrated row, an unrecorded site found by the
re-inventory, or an audit hit.

**SDE10 — Replacement text is stable.** An edit records its replacement
as an offset and length into the editor's buffer, and becomes a borrowed
slice only while writing; growing the buffer or moving the editor never
invalidates an edit made earlier. _Oracle:_ a test that makes enough edits
to force several buffer growths, moves the editor, and writes.
_Violation:_ output containing stale or reallocated text.

## 5. Interface

Names are provisional; the contract above is what binds.

```d
struct SdlEditor(Document)
{
    /// `host` is the document's source, or the D program it was rendered from.
    this(return scope ref const Document document, return scope const(char)[] host);

    void replaceValue(SdlNode node, size_t index, SdlScalar value);
    void replaceAttribute(SdlAttributeView attribute, SdlQualifiedName name, SdlScalar value);
    void setAttribute(SdlNode node, SdlQualifiedName name, SdlScalar value);
    void removeAttribute(SdlAttributeView attribute);
    void insertBefore(SdlNode sibling, scope const(char)[] fragment);
    void insertAfter(SdlNode sibling, scope const(char)[] fragment);
    void append(SdlNode parent, scope const(char)[] fragment); // root: end of the content
    void remove(SdlNode node, SdlAttachedComments comments = SdlAttachedComments.keep);
    void replaceBody(SdlNode node, scope const(char)[] fragment);
    void replaceRegion(TextSpan region, scope const(char)[] text);

    /// Renders, re-parses with `allocator` (SDE2), then copies to `writer`;
    /// nothing on failure.
    SdlExpected!void write(Writer, Allocator)(ref Writer writer, ref Allocator allocator);
}
```

The constructor checks that the host's bytes are the document's source
or, for an embedded recipe, that the rendering of the host is; otherwise every operation fails with `editTargetMissing`. Each
operation records its first failure in the editor; `write` reports it.
Selection uses the existing document API — filtered child and attribute
ranges, `SdlNameQuery`, and comment spans — so the editor adds no query
language.

## 6. Failure behaviour

Every failure is an `SdlError` with a stable code, the source name, and the
span of the operation that failed; nothing is written. The codes added are:

- `editConflict` (SDE3);
- `editAmbiguousTarget` (a set on a repeated attribute);
- `editUnsupportedLayout` (an inline anchor given more than one node or a
  block, or an attribute removal across a commented continuation);
- `editFragmentInvalid` (a fragment that is not whole nodes, or an embedded
  recipe SDE7 rejects);
- `editTargetMissing` (a view from another document, or a host that does
  not match it);
- `editResultInvalid` (SDE2's check failed — an editor defect, reported
  rather than written).

## 7. Migration coverage

Each site below states its operation through the shared API after
migration. The inventory was taken on 2026-10-24 at `ef61d5b66` and checked
by an independent review.

| Site                                                                       | Today                                                                                                                                                                                                  | Moves to                                                                                                                                                                                                                                                        |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/ci/tools/standardize-build-settings.d` (`normalize`)                 | regex removal of the managed region, a legacy three-line comment, and eight named `buildType` blocks; a line filter dropping four legacy `dflags`/`lflags` settings; `strip`, then the region appended | replace or remove the region by its marker comments; remove the legacy comment's lines; remove `buildType` and setting nodes matched by full content outside the region and outside `buildType`/`configuration "offline"`; append the region at the end of root |
| `apps/ci/tools/add-checked-buildtype.d`                                    | substring detection; `+/` search; re-indented text insertion                                                                                                                                           | schema read for detection; append at the end of root                                                                                                                                                                                                            |
| `apps/ci/src/dub_deps.d` (`writeInTreeDeps`)                               | parses with wired; splices `version="*"` into `path="…"` by hand                                                                                                                                       | replace an attribute                                                                                                                                                                                                                                            |
| `apps/ci/src/app.d` (`integratesTestRunner`)                               | `canFind("test-runner")` over the whole recipe, comments included                                                                                                                                      | schema read of dependencies and source paths in every scope                                                                                                                                                                                                     |
| `apps/ci/src/app.d` (`isDubSingleFileBlock`, `parseStandaloneExampleSpec`) | line-prefix detection of `/+ dub.sdl:` and `+/`                                                                                                                                                        | the shared embedded-recipe locator                                                                                                                                                                                                                              |
| `libs/build-primitives/…/dub_recipe.d` (`isSingleFileDubPackage`)          | 4 KiB head scan duplicating the embedded-recipe header test                                                                                                                                            | the shared locator's header-only mode                                                                                                                                                                                                                           |
| `apps/shader-compile/src/toolchain_tests.d` fixtures                       | text append and string replace on a recipe                                                                                                                                                             | append; replace an attribute (its edit of `dub.selections.json` is JSON and stays)                                                                                                                                                                              |

The migrated `standardize-build-settings` no longer strips the whole file:
its output differs from today's only in bytes the old tool rewrote without
being asked, and the S15 fixtures pin those differences.

**Accepted exception — Nix evaluation.** `nix/packages/build-sparkles-app.nix`
and `nix/packages/examples.nix` read recipes with regular expressions and
hand brace matching during evaluation, where D cannot run. They are outside
SDE9 by decision (2026-10-24): a generated index or import-from-derivation
was judged not worth its cost. A recipe construct those readers misread is a
Nix bug to fix in Nix, and this table is the record that the exception
exists.

Not SDL work, and so outside SDE9: byte hashing of recipes (shader-compile
stamps, CI cache keys), existence checks, path-pattern hook filters, and the
syntax highlighter's injection of the SDL grammar.

## 8. Deferred capabilities

- **Persistent node handles** across commits, for an interactive editor or
  a language server. Entry condition: a consumer that keeps a document open
  across edits. It would build on generational handles from `sparkles.base.pool`,
  which first needs a heap-backed slot table there.
- **Path selectors** (the DQL path grammar as a node query). Entry
  condition: a second consumer whose selection is not a name-and-value
  filter.
- **Incremental re-parse** of an edited range. Entry condition: a
  measurement showing whole-document re-parse dominates an edit workload.
