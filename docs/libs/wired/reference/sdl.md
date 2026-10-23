# SDL API reference

Everything below is exported by `sparkles.wired.sdl`. Each group links to
the [SDL specification](../../../specs/wired/sdl/SPEC.md) section that
defines it. Every function returns `SdlExpected!T`
(`Expected!(T, SdlError)`) instead of throwing.

## Typed values

| Function                                                      | Does                                                            |
| ------------------------------------------------------------- | --------------------------------------------------------------- |
| `fromSDL!(T, config = sdlFull)(text, sourceName = null)`      | Parses under `config`, then decodes a `T`.                      |
| `fromSDL!(T, Sink, config = sdlFull)(text, sink, sourceName)` | The same, putting every independent failure into `sink`.        |
| `fromSDL!T(node)`, `fromSDL!(T, Sink)(node, sink)`            | Decodes a `T` from a node of a document you keep alive.         |
| `toSDL(value)`                                                | Canonical text of `value`, as an `SdlString`.                   |
| `writeSDL(value, writer)`                                     | The same text into any character output range.                  |
| `readSDLFile!T(path)`, `writeSDLFile(value, path)`            | File versions; writes are atomic (temporary file, then rename). |

`T` may be `Decoded!U`, which also records which fields the input supplied.
`isWireRoundTrippable!(Sdl, T)` is true when `fromSDL!T(toSDL(v)) == v`
holds for every value. See [SPEC §6](../../../specs/wired/sdl/SPEC.md#_6-typed-mapping-and-repetitions)
and [§11](../../../specs/wired/sdl/SPEC.md#_11-reader-writer-and-file-apis).

## Field roles

| UDA                                           | Field reads                                  |
| --------------------------------------------- | -------------------------------------------- |
| `@SdlTagValue(n)`                             | positional value `n` (an array: from `n` on) |
| `@SdlAttribute()`                             | the attribute of the field's name            |
| `@SdlChild()` (the default)                   | the child tag of the field's name            |
| `@SdlTagName()`, `@SdlTagNamespace()`         | the containing tag's own name or namespace   |
| `@SdlExtra()` on `SdlExtras`/`OwnedSdlExtras` | every occurrence no other field claimed      |

Names come from `@WireName!Sdl` (a `:` sets the namespace) or the case
policy. The shared policies (`@WireOptional`, `@WireDefault`, `@WireAlias`,
`@WireCheck`, `@WireAs`, `@WireConvert`, `@WireStrict`) apply as for JSON.
See [SPEC §5](../../../specs/wired/sdl/SPEC.md#_5-typed-sdl-roles) and
[§8](../../../specs/wired/sdl/SPEC.md#_8-unknown-fields-and-passthrough).

## Documents

| Name                                          | Is                                                                   |
| --------------------------------------------- | -------------------------------------------------------------------- |
| `parseSdlDocument!config(text, sourceName)`   | An owning `SdlDocument` in source order.                             |
| `validateSDL!config(text, sourceName)`        | Whether `text` parses, without keeping a document.                   |
| `writeSdlDocument(document, writer, options)` | The document's canonical text.                                       |
| `SdlNode`                                     | A tag: `qualifiedName`, `byValue`, `byAttribute`, `byChild`, `span`. |
| `SdlScalar`                                   | One value: `kind`, then the payload accessor for that kind.          |
| `SdlNameQuery`                                | A name to filter `byChild`/`byAttribute`, optionally any namespace.  |
| `SdlSpan`, `SdlPosition`                      | Byte offset, line, and column of a source range.                     |

See [SPEC §4](../../../specs/wired/sdl/SPEC.md#_4-ordered-arena-document).

## Profiles

`sdlFull`, `sdlDubCompat`, and `sdlDubRecipe` are the predefined
`SdlParserConfig` values; a custom one enables scalar families
(`SdlScalarFeatures`) and syntax (`SdlSyntaxFeatures`) one by one. See
[SPEC §3.1](../../../specs/wired/sdl/SPEC.md#_3-1-compile-time-dialects).

## Errors

`SdlError` carries a `stage`, a stable `code`, the source name and `span`,
`rolePath` (the place in the SDL text) and `valuePath` (the place in the D
value), and a `reason`; `toString` renders all of it. A failed union decode
lists each variant's error in `variants`. See
[SPEC §7](../../../specs/wired/sdl/SPEC.md#_7-errors-and-source-context).

## Lower levels

`lexSDL!config(text)` yields `SdlToken`s; `decodeSdlScalar` decodes a
scalar token; `writeSdlScalar` writes one scalar canonically. See
[SPEC §11](../../../specs/wired/sdl/SPEC.md#_11-reader-writer-and-file-apis).
