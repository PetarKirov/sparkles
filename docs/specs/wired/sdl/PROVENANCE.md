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

Every SDL test added after S0 must identify one of these classes in its test
comment when the source is not wholly original.

| Fixture family                                                              | Classification                                      | Planned use                                                                                                                                                                                                                   |
| --------------------------------------------------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scalar-kind and canonical-writer matrix                                     | Original                                            | Derived from `SPEC.md` §§3.4 and 9; covers every scalar kind, boundaries, signed zero, escapes, Base64, civil time, zones, duration fractions, and non-finite rejection                                                       |
| Lexer acceptance/rejection matrix                                           | Adapted                                             | Cases selected from `sdlang/lexer.d`, rewritten against `Expected`, stable error codes, and byte spans; each test cites the upstream path and revision                                                                        |
| Parser regression cases for SDLang-D issues 16 and 31                       | Direct port if retained verbatim; otherwise adapted | Pins the anonymous/numeric parser regressions from `sdlang/parser.d`; direct ports carry an in-file zlib/libpng notice                                                                                                        |
| Ordered arena and repeated-name fixtures                                    | Adapted                                             | Semantic shapes selected from `sdlang/ast.d`, rewritten for flat arenas and borrowed ranges                                                                                                                                   |
| DUB recipe semantic snapshots                                               | Adapted                                             | Reduced cases selected from `recipe/sdl.d` for authors, dependencies, configurations, platform attributes, namespaces, and nested settings                                                                                    |
| Pinned DUB recipe snapshot (`dub.sdl` @ `5efed360`)                         | Direct copy (unmodified)                            | Byte-exact `sdlDubRecipe` compatibility corpus; provenance and license identification sit beside the file in `libs/wired/src/sparkles/wired/sdl/fixtures/README.md`, with the MIT notice retained in `THIRD_PARTY_NOTICES.md` |
| Typed defaults, strictness, hooks, and source paths                         | Adapted                                             | Behavioural cases selected from `configy/read.d` and `configy/dub_test.d`, expressed through wired policies rather than Configy's class interface                                                                             |
| Error-code, allocator, lifetime, fuzz-smoke, and generated round-trip tests | Original                                            | Derived from the sparkles SDL specification and implementation invariants                                                                                                                                                     |

The pinned DUB recipe snapshot is the only direct copy, and it is byte-exact
(unaltered) upstream material with its notice retained. If implementation work
later adds an altered direct port, the destination file must say that it is
altered from the named upstream path, retain the applicable notice, and update
this table before the port lands.

## Audit Rule

S10 audits every adapted or ported fixture against this manifest. An upstream-
inspired test without a path, full revision, and classification is incomplete;
a copied source body without the applicable notice is a release blocker.
