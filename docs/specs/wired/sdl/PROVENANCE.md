# `sparkles.wired.sdl` — Provenance manifest

This manifest records the evidence corpus for the SDL backend before any
upstream-derived implementation or fixture is imported. The normative target
remains [`SPEC.md`](./SPEC.md); these sources provide compatibility evidence,
not an architecture to copy.

## Pinned Revision

The grounding checkout is
[`dlang/dub@5efed360e1c9342453bc5dd19339c75981526d83`](https://github.com/dlang/dub/tree/5efed360e1c9342453bc5dd19339c75981526d83),
the revision used by the repository's installed DUB toolchain. It identifies
itself as `v1.42.0-beta.1-7-g5efed360` and bundles SDLang-D sources. Their
embedded version labels disagree, so the DUB revision, not a reconstructed
SDLang-D version number, is the compatibility identity.

The package-level license texts that cover adapted or ported material are
recorded in [`libs/wired/THIRD_PARTY_NOTICES.md`](../../../../libs/wired/THIRD_PARTY_NOTICES.md).

## Source Inventory

| Upstream path                                                                                                                                                         | Evidence used by the SDL backend                                                                                            |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| [`source/dub/internal/sdlang/lexer.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/sdlang/lexer.d)                 | UTF-8 BOM handling, comments, continuations, identifiers, scalar tokenization, and lexical rejection cases                  |
| [`source/dub/internal/sdlang/parser.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/sdlang/parser.d)               | Tag grammar, attributes, child blocks, anonymous tags, terminators, and parser regressions                                  |
| [`source/dub/internal/sdlang/token.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/sdlang/token.d)                 | Scalar-kind vocabulary and semantic scalar spellings                                                                        |
| [`source/dub/internal/sdlang/ast.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/sdlang/ast.d)                     | Ordered values, repeatable namespaced attributes/tags, semantic writing, and lookup behaviour                               |
| [`source/dub/internal/sdlang/exception.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/sdlang/exception.d)         | Source-location and failure-class evidence                                                                                  |
| [`source/dub/internal/sdlang/symbol.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/sdlang/symbol.d)               | Parser symbol vocabulary                                                                                                    |
| [`source/dub/internal/sdlang/util.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/sdlang/util.d)                   | Locations, date/time helpers, and shared lexical utilities                                                                  |
| [`source/dub/internal/sdlang/package.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/sdlang/package.d)             | Bundled version, authorship, and zlib/libpng provenance                                                                     |
| [`source/dub/recipe/sdl.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/recipe/sdl.d)                                       | Real-world DUB recipes: positional values, repeated tags, attributes, namespaces, nested settings, and semantic round trips |
| [`source/dub/internal/configy/attributes.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/configy/attributes.d)     | Typed field metadata and override evidence                                                                                  |
| [`source/dub/internal/configy/backend/node.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/configy/backend/node.d) | Format-neutral node boundaries, source locations, and structural kinds                                                      |
| [`source/dub/internal/configy/read.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/configy/read.d)                 | Typed structural filling, defaults, strict unknown handling, hooks, and validation                                          |
| [`source/dub/internal/configy/easy.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/configy/easy.d)                 | Text/file convenience-boundary evidence                                                                                     |
| [`source/dub/internal/configy/exceptions.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/configy/exceptions.d)     | Typed conversion and path-error evidence                                                                                    |
| [`source/dub/internal/configy/fieldref.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/configy/fieldref.d)         | Compile-time field resolution                                                                                               |
| [`source/dub/internal/configy/utils.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/configy/utils.d)               | Name and scalar conversion helpers                                                                                          |
| [`source/dub/internal/configy/backend/yaml.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/configy/backend/yaml.d) | Concrete adapter evidence only; no YAML-shaped SDL mapping is permitted                                                     |
| [`source/dub/internal/configy/dub_test.d`](https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/internal/configy/dub_test.d)         | DUB-specific typed parsing fixtures                                                                                         |

## Comparative Implementation

SDLite at
[`b33048bf2d0c6b5df1b3b4b18e6cd83cb2f7aa81`](https://github.com/s-ludwig/sdlite/tree/b33048bf2d0c6b5df1b3b4b18e6cd83cb2f7aa81)
is comparative architectural evidence for borrowed forward-range tokens,
checkpoint/rollback around date lookahead, deferred scalar decoding, and pooled
document construction. It is not a conformance source: that revision omits
character and decimal semantics, has no BOM support, and accepts a materially
different SDL subset.

No SDLite code or fixture is currently adapted or ported. If that changes, this
manifest must name the source path and classification, and
`libs/wired/THIRD_PARTY_NOTICES.md` must gain SDLite's MIT notice before the
derived material lands.

## Fixture Classification

Every SDL test that is not wholly original names its upstream path, the full
revision, and one of these classes in its test comment. The S10 audit found
exactly the following non-original material; every other SDL test is original.

| Material                                                     | Classification                  | Tests                                                                                                                           |
| ------------------------------------------------------------ | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Pinned DUB recipe snapshot (`dub.sdl` @ `5efed360`)          | Direct copy (unmodified)        | `sdl.lexer.pinnedDubRecipeSnapshot`, `sdl.reader.allInTreeAndPinnedDubRecipes`, `sdl.writer.laws.dubCorpusRoundTrip`            |
| Lexer case selection from `sdlang/lexer.d`                   | Adapted                         | `sdl.lexer.sparklesVsPinnedDubContinuation`, `sdl.lexer.pinnedDubTemporalCompatibility`, `sdl.lexer.pinnedDubCorpusRegressions` |
| Recipe shapes from `recipe/sdl.d`                            | Adapted                         | `sdl.reader.pinnedDubRecipeSemanticSnapshot`                                                                                    |
| String literals in the `unittest` blocks of the five modules | Not imported: read at test time | `sdl.conformance.pinnedDub`, through `libs/wired/test/sdl_dub_oracle.d`                                                         |

The direct copy is byte-exact; provenance and license identification sit beside
it in `libs/wired/src/sparkles/wired/sdl/fixtures/README.md`, with the MIT
notice retained in `THIRD_PARTY_NOTICES.md`. Adapted tests rewrite a selected
case against `Expected`, stable error codes, and spans; no upstream test body
is reproduced. If later work adds an altered direct port, the destination file
must say that it is altered from the named upstream path, retain the applicable
notice, and update this table before the port lands.

No Configy fixture was adapted: the typed default, strictness, hook, and path
tests are original, derived from the specification. SDLite remains comparative
evidence only.

## Audit Rule

The `dub-sdl-src` flake input pins the same revision for the process-isolated
`sdl.conformance.pinnedDub` test. Its helper, `libs/wired/test/sdl_dub_oracle.d`,
is original Sparkles code. It compiles the unmodified upstream production lexer
and parser, and at compile time reads every string literal inside a `unittest`
block of `sdlang/lexer.d`, `sdlang/parser.d`, `sdlang/ast.d`, `sdlang/token.d`,
and `recipe/sdl.d` from that checkout, letting the compiler evaluate each
literal's escapes. Those literals are inputs only: nothing is copied into this
repository, and the expected outcome of each comes from running DUB itself, not
from upstream's assertions. The test compares lexer acceptance, token kinds,
scalar payloads, parser acceptance, and the parsed tree under `sdlDubCompat`,
and recipe-profile acceptance and trees under `sdlDubRecipe`. It is not part of
the library import closure.

The pinned upstream `sdlangUnittest` mode cannot compile: several
`DateTimeFrac` fixtures omit the constructor's required fraction argument. The
corpus test therefore runs upstream's inputs through the production
implementation instead of upstream's assertions. DUB's negative clock keeps a
negative fraction (`-34:65:77.123` is second 43 less 0.123 s); the oracle
borrows one second to report the same instant in normalized form.

S10 audits every adapted or ported fixture against this manifest. An upstream-
inspired test without a path, full revision, and classification is incomplete;
a copied source body without the applicable notice is a release blocker.
