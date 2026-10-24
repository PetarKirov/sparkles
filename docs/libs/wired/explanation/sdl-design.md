# How the SDL backend is designed

This page explains why `sparkles.wired.sdl` is shaped the way it is. For
what it does, see the [reference](../reference/sdl.md); for the exact
contract, the [specification](../../../specs/wired/sdl/SPEC.md).

## Three channels, so roles are explicit

A JSON object has one place to put a member. An SDL tag has three:
positional values, attributes, and child tags, and the same name may
appear in more than one. `name "x"` and `tag name="x"` say different
things. So the backend cannot guess where a field lives; each field
carries a role (`@SdlTagValue`, `@SdlAttribute`, or a child), and an
unmarked field defaults to a child tag because a plain struct then reads
naturally as a tag with children.

Roles are ordinary data in the shared `wired` schema, beside the names,
defaults, checks, and converters the JSON codec uses. One schema serves
both formats: a struct can be read from JSON and from SDL, and the
SDL-only annotations simply have no effect under JSON. An impossible role,
such as an attribute holding a struct, is rejected when the schema is
built, at compile time, with the field named in the message.

## Order and repetition are data

SDL documents repeat things: several `dependency` tags, several `authors`
values, the same attribute twice. The document keeps every occurrence in
source order, in flat arenas rather than a tree of objects, and never folds
repeated names into a map. The typed decoder follows the same rule: a
singular field that appears twice is an error, never "last one wins",
because silently dropping a value is the kind of bug a configuration
format should not have.

## Profiles: one grammar, chosen at compile time

DUB's bundled SDL parser is the most widely deployed SDL reader in the D
ecosystem, and it does not follow the SDL language exactly. Rather than
picking one behaviour, the backend makes the dialect a compile-time
`SdlParserConfig`. `sdlFull` is the deterministic language; `sdlDubCompat`
reproduces DUB at a pinned revision; `sdlDubRecipe` narrows that to the
scalars recipes use. Because the profile is a template argument, a disabled
scalar family is not just rejected but absent from the binary: a recipe
reader never links the floating-point or date decoders.

`sdlDubCompat` is held to DUB by a differential test. It compiles DUB's
unmodified parser, runs every string literal from DUB's own SDL test code
through both implementations, and compares tokens, values, and parsed
trees. When the two disagree, the compatibility profile is wrong by
definition.

## A semantic writer, not a formatter

The writer emits one canonical spelling for each document: values, then
attributes, then children; double-quoted strings; four-space indentation;
LF newlines. It does not preserve comments, quote style, or layout. That
makes output deterministic, so a value written twice gives identical bytes
and a written file diffs cleanly, and it makes the round-trip laws simple:
parsing the output gives the same document, and writing it again gives the
same bytes.

The canonical form targets `sdlFull`. A string holding U+2028 or U+2029 is
written unescaped, because SDL has no escape for them, and DUB rejects
those characters inside double quotes. A document meant for DUB spells such
a string as a raw `` `…` `` string, which DUB keeps verbatim.

## Borrowed views, owned results

Parsing allocates a document that owns all its bytes; nodes, values, and
attributes are small views into it. Views are cheap to copy and never
allocate, and `-preview=dip1000` stops one from outliving its document:
`root()` is bound to the document object itself.

Typed results are owned. Decoding copies every string and byte payload a
field declares, so a decoded struct does not depend on the text or the
document. The one exception is a choice you make: an `@SdlExtra` field of
type `SdlExtras` keeps views into the document, for tools that decode and
re-emit without copying. `OwnedSdlExtras` copies instead, and the text
overloads of `fromSDL`, whose document is temporary, require it.

## Errors are values with two paths

No function throws. Every failure is an `SdlError` value with a stable code,
the source span, and two paths to the same place: `rolePath` in SDL terms
(`.worker[1]@threads`) for the person editing the file, and `valuePath` in D
terms (`.workers[1].threads`) for the program handling it. With an error
sink, decoding continues past independent failures, so one pass reports
every mistake in a file.
