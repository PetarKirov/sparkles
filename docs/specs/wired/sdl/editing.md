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

An **open document** keeps a host, its parsed document and its node
handles across a sequence of commits ([§9](#9-open-documents-and-node-handles)),
and re-parses only the part of the host an edit touched
([§10](#10-incremental-re-parse)). A **selector** names the nodes an
operation targets by a DQL path and filter ([§3.2](#3-2-path-selection)).
Out of scope: a concrete syntax tree with editable trivia objects. The
canonical writer stays the way to produce a document from a typed value.

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
| SDE11 | A node handle names the same node across commits until an operation replaces that node       |
| SDE12 | A handle whose node was replaced is reported stale, never re-aimed at another node           |
| SDE13 | A failed commit leaves the host, the document and every handle as they were                  |
| SDE14 | An incremental re-parse produces exactly the document a full re-parse would                  |
| SDE15 | An edit the incremental reader cannot localize falls back to a full re-parse                 |
| SDS1  | A selector's path is a DQL path, and a malformed one is rejected at its offset               |
| SDS2  | A path selects nodes or attributes by name-and-index child steps, in document order          |
| SDS3  | A filter is a DQL expression evaluated with each selected node as its subject                |
| SDS4  | Path-only selection is `@safe pure nothrow @nogc` and allocates nothing                      |
| SDS5  | Editor operations accept a selection and apply once per target                               |

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
| set a node's values         | from its first value to its last, or the point after its name when it has none                                                                                                                  | the canonical spellings, space-separated                                                                   |
| insert an attribute         | the point after the node's last value, attribute or name                                                                                                                                        | ` name=value`, whatever attributes of that name exist                                                      |
| replace a node              | the node's extent when it is alone on its lines; else from its first byte through its last token                                                                                                | the fragment, re-indented; at an inline node, one single-line node                                         |
| update from a typed value   | the union of the ranges of the operations above that it resolves to                                                                                                                             | the operations that make the node decode as the value (§3.1)                                               |

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

### 3.1 Typed write-back

`updateSDL(editor, node, value)` encodes `value` canonically and walks `node`
beside the encoding, field by field of the schema. `node` is the root or any
node that decodes as the value's type; its own name is the caller's choice
and is not compared.

- **Values and attributes.** Positional values that differ become one value
  replacement. A field's attributes pair by position and change in place, or
  are removed and inserted when their count changes.
- **Aggregate sequences** pair by identity: an element's name and positional
  values (`configuration "lib"`, `dependency "a"`). Each new element takes
  the first unpaired old element of the same identity. Of those pairs, the
  longest run that is in the same relative order in both keeps its nodes and
  is updated recursively. Between two kept pairs, the remaining old and new
  elements pair by position and change in place, so a changed identity keeps
  its comments. Surplus old elements are removed with their attached
  comments. Surplus new ones are inserted after the last node left in place
  before them; when there is none, after the sibling just above the next
  kept element and its comments; when the field has no element left, they
  are appended.
- **Reordering** is not a move. The longest run keeps its bytes; an element
  outside it is written canonically at its new place and its old node is
  removed with its attached comments.
- **Other children.** A map pairs by key. A scalar child — a union among
  them, since SDL unions are scalar (SPEC §6) — changes its values in
  place; another non-aggregate child that differs is replaced whole. An
  aggregate whose name is data (`@SdlTagName`, `@SdlTagNamespace`) is a
  different node when that name changes, and is replaced whole.
- **Scalar sequences** compare their values flattened across occurrences,
  since the typed value keeps no boundary between them.

Surplus new children of a node without a block are appended in one block.
Members the schema does not claim are never touched, a name spelled through
an alias is kept, and scalars compare by canonical spelling, so `` `a` ``
stays `` `a` `` when the value is `"a"`.

### 3.2 Path selection

A caller can select the targets of an operation with a path instead of
nested child loops. The path uses the
[DQL path grammar](../../dql/SPEC.md#_2-1-path-addressing-grammar), and an
optional [DQL](../../dql/SPEC.md) filter expression narrows what it selects,
so the repository has one query language rather than one per format.

**SDS1 — The path is a DQL path.** A path follows the
[DQL path grammar](../../dql/SPEC.md#_2-1-path-addressing-grammar), read by
`sparkles.dql.path`: identifier segments, quoted segments (`["my.tool"]`,
JSON-escaped), and `[Digits]` indexes. A segment's decoded text names an SDL
qualified name, split at its first `:` into namespace and local name
(`["ns:my.tool"]` too), and matches that name exactly (an unprefixed segment
matches only unnamespaced names, as `byChild` does). An index follows a
segment and counts, from zero, the nodes of that name under one parent; a
segment takes at most one, and a path at most sixteen segments. A malformed
path — an empty segment, an index before any segment or after another index,
non-digits or an overflowing number inside `[]`, an empty `[]`, an
unterminated string or a bad escape in a quoted segment, a seventeenth
segment — is rejected with the byte offset of the fault, and nothing is
selected. _Oracle:_ a table of accepted and rejected paths with their
offsets. _Violation:_ a malformed path that selects, or a well-formed one
rejected.

**SDS2 — A path selects by child steps.** From a start node (the root, for
a document), a node selection of n segments yields, in document order, every
node reached by n child steps, where each step keeps the children whose name
the segment names and, when it carries an index k, only the k-th of them. An
index past the last match selects nothing. An attribute selection treats its
last segment as an attribute name instead, with its index counting that
node's attributes of the name, and yields attributes in document order. An
SDL name that is not a DQL identifier — `my.tool`, say — is addressed by a
quoted segment: `build["my.tool"].dependency`. _Oracle:_ over every
repository recipe and a fixture with dotted tag and attribute names, every
name path present to depth three, with and without an index, written as DQL
prints it (quoting where needed), against nested `byChild` and `byAttribute`
loops. _Violation:_ a missing, extra or reordered target.

**SDS3 — A filter is DQL over the selected node.** The filter is parsed
by `parseDql` and evaluated by `evalDql` with each selected node — for an
attribute selection, the node that holds the attribute — as the subject. A
path in the filter is zero or more child steps, each taking the first child
of its name or, with an index, the k-th, followed by a leaf: `values[i]`,
the node's i-th value, or an attribute name, its first attribute of that
name; quoted segments work here too (`["dflags.ldc"] == null`). A bare
identifier (a DQL category) holds when the node has a child at that path. Strings compare as text, booleans as `bool`, integers as `long`,
and floats and decimals as `double`; an absent target, or an SDL `null`, is
`== null`. A target of another kind (a character, binary, date or
duration) is not null and fails every comparison and match, and so does a
malformed leaf (`values` without an index, an index on an attribute name).
_Oracle:_ over every repository recipe, a fixed set of filters against the
hand-written predicates they spell. _Violation:_ a node kept or dropped
against its predicate.

**SDS4 — Path-only selection allocates nothing.** Reading a path and
walking a selection without a filter is `@safe pure nothrow @nogc`, holds a
borrowed path and a cursor per segment, and visits only the children of the
nodes each step keeps. A filter allocates while it is parsed (the DQL
engine's pools and compiled matchers); evaluating it allocates only where
DQL's own evaluation does (`regexMatch`). _Oracle:_ a `@nogc` unittest.
_Violation:_ an allocation or attribute failure in that test.

**SDS5 — Operations take selections.** `remove`, `removeAttribute`,
`replaceAttribute` and `setAttribute` also accept a range of the targets they
take, and apply the one operation to each in order. The edits are those of
the single-target operations, so SDE1 to SDE3 apply to each, and two targets
whose ranges overlap are `editConflict`. _Oracle:_ a range call and the loop
of single calls write the same output. _Violation:_ different output.

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
- **Regression:** an `apps/ci` audit (`ci --check-adhoc-sdl`) reads D
  sources outside `libs/wired/src/sparkles/wired/sdl/`,
  `libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d`, the
  audit itself, and test code (`unittest` blocks and `version (unittest)`
  code). A string literal, or a string constant (`enum`, `immutable`,
  `const` or `static`, at any scope, initialized from literals, other names,
  `~` and array brackets only — not a call's result), is _marked_ when it
  contains `dub.sdl:`, `+/`, `buildType`,
  `configuration "`, `dependency "`, `subPackage`, `dflags`, `lflags`,
  `sparkles:test-runner` or `test-runner/src`. The audit flags a marked
  operand of:
  - a call of `canFind`, `indexOf`, `startsWith`, `endsWith`, `replace`,
    `split`, `splitter`, `lineSplitter`, `matchFirst`, `matchAll`, `regex`,
    `ctRegex` or `tryConsume`, in its arguments or UFCS receiver;
  - a comparison: `==`, `!=`, or a `case` label of a `switch`;
  - a concatenation, `~` or `~=`, which builds SDL text — when the operand
    holds recipe syntax, not only a marker in prose: `dub.sdl:`,
    `configuration "` or `dependency "`; a line starting, after its
    indentation, with `+/` or with a key marker followed by a space, `"`,
    `{`, `\`, `-` or nothing; the quoted `"sparkles:test-runner`; or
    `test-runner/src`.

  Markers are read in a literal's value, its escapes decoded, so
  `"dependency \""` holds `dependency "`.

  A call or comparison whose _subject_ — another argument or the receiver,
  the other operand, the `switch` expression — is decoded is typed work and
  is not flagged. A subject is decoded when it reads a member of the typed
  models (`name`, `localName`, `qualifiedName`, `namespace_`, `stringValue`,
  `byValue`, `byChild`, `byAttribute`, `valuesOf`, `object`, `str`,
  `array`), or when its root is a `foreach` variable, a lambda parameter or
  an initialized local bound from such a read in an enclosing block. The
  markers name recipe forms only: a bare `test-runner` is also a commit
  scope, an executable name and a stack frame, so only its dependency name
  and source-include path count.

  The audit does not read text formatted by `format`, `text` or an
  interpolated sequence; the completeness re-inventory covers those.

Hits that are not SDL work go on an allowlist kept beside the audit, each
with the reason it was reviewed and why the rule cannot tell it apart.

_Violation:_ an unmigrated row, an unrecorded site found by the
re-inventory, or an audit hit.

**SDE10 — Replacement text is stable.** An edit records its replacement
as an offset and length into the editor's buffer, and becomes a borrowed
slice only while writing; growing the buffer or moving the editor never
invalidates an edit made earlier. _Oracle:_ a test that makes enough edits
to force several buffer growths, moves the editor, and writes.
_Violation:_ output containing stale or reallocated text.

## 5. Interface

`sparkles.wired.sdl.editor` delivers this contract;
`sparkles.wired.sdl.embedded` locates, renders and parses embedded recipes.

```d
struct SdlEditor(SdlParserConfig config = sdlFull, DocumentAllocator = Mallocator)
{
    /// `host` is the document's source, or the D program it was rendered from.
    this(return scope ref const SdlDocument!DocumentAllocator document,
        return scope const(char)[] host);

    bool ok() const;                 // no operation has failed yet
    void replaceValue(SdlNode node, size_t index, in SdlScalar value);
    void replaceAttribute(SdlAttributeView attribute, SdlQualifiedName name, in SdlScalar value);
    void setAttribute(SdlNode node, SdlQualifiedName name, in SdlScalar value);
    void removeAttribute(SdlAttributeView attribute);
    void insertBefore(SdlNode sibling, scope const(char)[] fragment);
    void insertAfter(SdlNode sibling, scope const(char)[] fragment);
    void append(SdlNode parent, scope const(char)[] fragment); // root: end of the content
    void remove(SdlNode node, SdlAttachedComments comments = SdlAttachedComments.keep);
    void replaceBody(SdlNode node, scope const(char)[] fragment);
    void replaceRegion(TextSpan region, scope const(char)[] text);
    void setValues(SdlNode node, scope const SdlScalar[] values);
    void insertAttribute(SdlNode node, SdlQualifiedName name, in SdlScalar value);
    void replaceNode(SdlNode node, scope const(char)[] fragment);

    /// Renders, re-parses with `allocator` (SDE2), then copies to `writer`;
    /// nothing on failure.
    SdlExpected!void write(Writer, Allocator)(ref Writer writer, ref Allocator allocator);
}

auto sdlEditor(SdlParserConfig config = sdlFull, DocumentAllocator)(
    ref const SdlDocument!DocumentAllocator document, const(char)[] host);

// sparkles.wired.sdl.typed_edit — §3.1
void updateSDL(T, Editor)(ref Editor editor, SdlNode node, const ref T value);

// sparkles.wired.sdl.open_document — §9
alias SdlNodeHandle = Handle!SdlNodeTag;
struct SdlOpenDocument(SdlParserConfig config = sdlFull, Allocator = Mallocator)
{
    SdlExpected!void open(const(char)[] host, const(char)[] sourceName = null,
        SdlHostKind kind = SdlHostKind.recipe);
    ref const(SdlDocument!Allocator) document() const;
    const(char)[] host() const;
    PoolResult!SdlNodeHandle handleOf(SdlNode node);     // issued once per node
    PoolResult!SdlNode node(in SdlNodeHandle handle) const; // stale once replaced
    auto editor();                                       // an SdlEditor to commit
    SdlExpected!void commit(ref SdlEditor!(config, Allocator) editor);
}

// sparkles.wired.sdl.select (sub-package sparkles:wired-sdl-select) — §3.2;
// the editor's remove, removeAttribute,
// replaceAttribute and setAttribute also take a range of their targets.
struct SdlPath
{
    static Expected!(SdlPath, DqlParseError) parse(const(char)[] text); // borrows text
    SdlNodeSelection nodes(SdlNode start) const;                         // @nogc
    SdlAttributeSelection!SdlNodeSelection attributes(SdlNode start) const;
}
struct SdlSelector
{
    static Expected!(SdlSelector, SdlSelectorError) parse(const(char)[] path,
        const(char)[] filter = null);
    SdlSelectedNodes nodes(SdlNode start);
    SdlAttributeSelection!SdlSelectedNodes attributes(SdlNode start);
}
struct SdlNodeResolver { SdlNode node; /* the DQL host-resolver protocol */ }

SdlEmbeddedRecipe locateEmbeddedRecipe(const(char)[] host);   // content, close, isJson, found
bool hasEmbeddedRecipeHeader(const(char)[] head);             // the header alone
void writeEmbeddedRendering(Writer)(ref Writer writer, const(char)[] host, in SdlEmbeddedRecipe recipe);
SdlEmbeddedParse!Allocator parseEmbeddedSdlDocument(SdlParserConfig config = sdlDubRecipe,
    Allocator = Mallocator)(const(char)[] host, const(char)[] sourceName = null);
```

`config` is the profile the document was parsed with, which the editor needs
to re-parse fragments and its result. The constructor checks that the host's
bytes are the document's source or, for an embedded recipe, that the
rendering of the host is; otherwise every operation fails with
`editTargetMissing`. Each operation records its first failure in the
editor; `write` reports it. Selection uses the document API — filtered
child and attribute ranges, `SdlNameQuery`, extents and comment spans — or a
path selector (§3.2), whose query language is DQL's.

Writing checks SDE2 by re-parsing the output under `config` and comparing its
node count with the count the operations imply (a region replacement makes
that count unknown, and only the parse is checked); the reference model of
SDE2's oracle — the full semantic comparison — runs in the tests.

## 6. Failure behaviour

Every failure is an `SdlError` of stage `edit` with a stable code, the source
name, the span of the operation that failed and its number in the reason;
nothing is written. The codes added are:

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

**Re-inventory, 2026-10-27 (S15 gate).** An independent reviewer swept the
repository again — D sources, tests and tools, and the Nix, shell, workflow
and docs tooling — after the migration. Every row below is migrated, and the
audit's allowlist reasons are accurate. It found one site the table lacked:
the SDL benchmark's dataset generator
(`libs/wired/bench/runtime/tools/gen-sdl-datasets.d`), which renamed each
recipe's `name` line by its text prefix. It now copies each recipe's bytes
into the concatenated dataset unread, so it does no SDL work. Outside the
table, `sparkles.build_primitives.dub_recipe` is a second, smaller recipe
model built on the document API and the embedded-recipe parser, and its
readers (`dmd-lsp`, `hue`, `apps/ci`) go through it; no shell, Python,
TypeScript, workflow or docs tooling parses or edits SDL.

**Audit completeness, 2026-11-06 (S19).** Reading concatenations and
comparisons found no unmigrated site. It found three operands its rule
cannot tell from SDL work, now on the allowlist with their reasons: the
managed region that `standardize-build-settings` hands to the editor and
compares byte for byte, the twoslash `@dflags` directive keyword, and the
benchmark dataset generator's `subPackage { … }` wrapper. The six earlier
entries are covered by the rule, and `standardize-build-settings` now
matches legacy settings by content.

| Site                                                                       | Today                                                                                                                                                                                                  | Moves to                                                                                                                                                                                                                                                                       |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `apps/ci/tools/standardize-build-settings.d` (`normalize`)                 | regex removal of the managed region, a legacy three-line comment, and eight named `buildType` blocks; a line filter dropping four legacy `dflags`/`lflags` settings; `strip`, then the region appended | replace or remove the region by its marker comments; remove the legacy comment's lines; remove `buildType` and setting nodes matched by name, values and attributes outside the region and outside `buildType`/`configuration "offline"`; append the region at the end of root |
| `apps/ci/tools/add-checked-buildtype.d`                                    | substring detection; `+/` search; re-indented text insertion                                                                                                                                           | schema read for detection; append at the end of root                                                                                                                                                                                                                           |
| `apps/ci/src/dub_deps.d` (`writeInTreeDeps`)                               | parses with wired; splices `version="*"` into `path="…"` by hand                                                                                                                                       | replace an attribute                                                                                                                                                                                                                                                           |
| `apps/ci/src/app.d` (`integratesTestRunner`)                               | `canFind("test-runner")` over the whole recipe, comments included                                                                                                                                      | schema read of dependencies and source paths in every scope                                                                                                                                                                                                                    |
| `apps/ci/src/app.d` (`isDubSingleFileBlock`, `parseStandaloneExampleSpec`) | line-prefix detection of `/+ dub.sdl:` and `+/`                                                                                                                                                        | the shared embedded-recipe locator                                                                                                                                                                                                                                             |
| `libs/build-primitives/…/dub_recipe.d` (`isSingleFileDubPackage`)          | 4 KiB head scan duplicating the embedded-recipe header test                                                                                                                                            | the shared locator's header-only mode                                                                                                                                                                                                                                          |
| `apps/shader-compile/src/toolchain_tests.d` fixtures                       | text append and string replace on a recipe                                                                                                                                                             | append; replace an attribute (its edit of `dub.selections.json` is JSON and stays)                                                                                                                                                                                             |

The migrated `standardize-build-settings` no longer strips the whole file:
its output differs from today's only in bytes the old tool rewrote without
being asked, and the S15 fixtures pin those differences.

**Accepted exception — Nix evaluation.** `nix/packages/build-sparkles-app.nix`
and `nix/packages/examples.nix` read recipes with regular expressions and
hand brace matching during evaluation, where D cannot run; so do the Nix
files that call their readers (`ui-shaders.nix`, `default.nix`,
`android-dev-env-probe.nix`, `android/build-d-android-tests.nix`, and
`android/examples.nix`, which runs the dependency pattern over a whole `.d`
example, its comments and strings included). They are outside
SDE9 by decision (2026-10-24): a generated index or import-from-derivation
was judged not worth its cost. A recipe construct those readers misread is a
Nix bug to fix in Nix, and this table is the record that the exception
exists.

Not SDL work, and so outside SDE9: byte hashing of recipes (shader-compile
stamps, CI cache keys), existence checks, path-pattern hook filters, and the
syntax highlighter's injection of the SDL grammar.

## 8. Deferred capabilities

None remain. Path selectors, persistent node handles and incremental
re-parse were delivered ahead of their entry conditions: see
[§3.2](#3-2-path-selection), [§9](#9-open-documents-and-node-handles) and
[§10](#10-incremental-re-parse).

## 9. Open documents and node handles

An `SdlOpenDocument` owns a copy of a host — a recipe, or a D program that
embeds one — the document parsed from it, and a growable slot table
([pool POOL19](../../base/pool.md#3-1-the-heap-slot-table)) of **node
handles**. A caller asks for a node's handle (`handleOf`), edits through an
`SdlEditor` the open document lends (`editor`), and **commits** the editor:
the edited host is rendered and re-parsed as `write` does, and on success it
replaces the host and the document, and every handle is carried over to the
new document or retired. Handles are issued lazily, so a document that never
asks for one pays for no table.

A node keeps its **identity** across a commit unless an operation of that
commit replaces it. The operations replace:

| Operation                                                         | Nodes it replaces                                                     |
| ----------------------------------------------------------------- | --------------------------------------------------------------------- |
| `replaceNode(n, …)`, `remove(n, …)`                               | `n` and every node below it                                           |
| `replaceBody(n, …)`                                               | every node below `n`; `n` itself keeps its identity                   |
| `replaceRegion(r, …)`                                             | every node whose span shares a byte with `r`, and every node below it |
| value and attribute operations, `setValues`, insertions, `append` | none; an inserted node is new and has no handle until one is asked    |

`updateSDL` is built from these operations, so it replaces exactly the nodes
its `replaceNode` and `replaceBody` calls name. Attributes and values have no
handles; they are reached through their node.

A surviving node's counterpart in the new document is found by its
**anchor**, the first byte of its span (its name, or its first value when it
is anonymous), carried through the commit's edits by `mapOffset` with
`afterInsertions` bias: it is the new node whose span starts at the mapped
anchor, provided its qualified name is unchanged. The root always maps to the
root.

**SDE11 — Handles follow their node.** A handle issued for a node resolves,
after any number of successful commits, to that node's counterpart, as long
as no commit replaced it. _Oracle:_ a property test that issues a handle for
every node of every repository recipe, commits random value, attribute,
insertion, removal and body edits, and after each commit checks every handle
against a model that labels each node with a unique value; plus hand cases
for an insertion before an unindented node, an anonymous node whose first
value is replaced, and `replaceBody`. _Violation:_ a live handle that
resolves to a different node, or a surviving node's handle that does not
resolve.

**SDE12 — Replaced nodes go stale.** After a commit, resolving the handle of
a node that commit replaced, or whose anchor no longer starts a node of the
same name, returns `PoolError.stale`, and `handleOf` for a node that took its
place issues a new handle. `Handle.init` and a handle beyond the table return
`PoolError.invalid`. _Oracle:_ the SDE11 test's removals and replacements,
and a `replaceRegion` over a node. _Violation:_ a replaced node's handle that
resolves.

**SDE13 — Failed commits change nothing.** A commit whose editor failed, or
whose result does not re-parse (SDE2), returns the error and leaves the host,
the document and every handle unchanged. _Oracle:_ a test that commits a
conflicting edit set and an invalid fragment between two good commits.
_Violation:_ any observable change after a failed commit.

Handles are local to the open document that issued them, as pool handles are
to their table (POOL7): resolving one open document's handle through another
is not detected.

## 10. Incremental re-parse

Writing and committing both re-parse the edited host (SDE2). For a large host
and a small edit, a full re-parse costs the whole host while the edit costs a
line, so the reader re-parses only a **region** around the edits and splices
it into a copy of the old document:

1. Take the deepest node whose block interior contains every edit. The
   interior runs from the end of the node's `{` to the start of its `}`, and
   for the root it is the content. The node's `}` must start its line after
   only spaces and tabs; otherwise the node's parent is taken instead.
2. Of that node's children, a child is **affected** when its extent shares a
   byte or an end point with an edit. The region runs from the end of the last
   unaffected child before them (or the interior start) to the start of the
   first unaffected child after them (or the interior end). It is widened by
   one child on either side until each bounding child is alone on its lines,
   so that the region starts and ends at a line boundary.
3. The reader lexes and parses the region's new text at the node's depth.
   It copies the old document's cells before and after the region, shifting
   every offset after it by the edits' length change and re-slicing names and
   payloads into the new document's source and pool. Comments and line starts
   are spliced the same way, and the child index is rebuilt.

**SDE14 — Incremental equals full.** The document an incremental re-parse
produces equals, field for field, the full parse of the same text: each node's
name, spans, extent, braces, terminator, `aloneOnLines`, depth and children;
each value and attribute, payloads included; the comments; the line table;
and the content. _Oracle:_ a property test over every repository recipe and a
generated deep, wide document that applies random edits — to values and
attributes, insertions, removals, body and region replacements, including ones
that open comments or strings, or add braces — and compares the two
documents. It is mutation-checked by a test that perturbs one spliced offset
and expects the comparison to fail. _Violation:_ any differing field.

**SDE15 — Unlocalizable edits fall back.** The region's parse is used only
when all of the following hold:

- its new text parses at the node's depth;
- every top-level node in it ends with a real terminator, not the end of
  input, unless the region ends the content;
- its new text still ends with a newline followed by only spaces and tabs,
  unless the region ends the content;
- no newline sequence was joined across its start, as when a CR comes
  before it and an LF now comes after.

Otherwise the whole host is re-parsed, and that parse's result or error is
the one reported. This covers an edit that opens a block comment or a
multi-line string, a line continuation into the next node, a brace that
changes the nesting, and invalid UTF-8. _Oracle:_ the SDE14 property test
counts both paths and requires each to occur, and the error for each failing
edit set equals the full parse's. _Violation:_ an error that differs from the
full parse's, or a localized result that differs (SDE14).

The `sdl.commit` benchmark row
([performance SDP1](./performance.md#1-measurement)) commits one small edit
at a time to an open document and reports retired instructions per input
byte, so the gain shows against the full re-parse it replaces.
