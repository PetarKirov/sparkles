---
status: accepted
owner: sparkles:dmd-lsp
reviewed: 2026-07-30
---

# `sparkles:dmd-lsp` — Feature Specification

## Abstract

`sparkles:dmd-lsp` runs the D reference compiler's own frontend as a library
over an in-memory source buffer and answers questions about the result: which
diagnostics the compiler reports, what type and documentation the symbol at a
position resolves to, what kind of symbol each identifier names, which names
can complete a position, and where a symbol is declared. The answers come from the compiler's full semantic
analysis, so they agree with what a build concludes, through templates, mixins
and compile-time evaluation. A file can be analyzed in the context of its dub
project, and as the LDC compiler or a GPU device compile sees it. Its
consumers draw compiler-verified type overlays over D code in documentation
and in the hue code viewer.

## Introduction

Tools that show D code, from documentation pages to a code viewer, are more
useful when they show what the compiler concluded: the type an `auto`
declaration inferred, the overload a call resolved to, the error a line
provokes, the documentation of the symbol under the cursor. The
[Twoslash](https://github.com/twoslashes/twoslash) convention captures this
for a code sample. Comments in the sample ask the compiler questions, and a
renderer draws the answers over the code. Sparkles renders such overlays with
[`sparkles:twoslash`](../twoslash/SPEC.md) in HTML, terminals and windows; it
needs a producer that answers the questions for D.

Answering them correctly takes the compiler's whole semantic analysis. D's
types depend on template instantiation, compile-time function evaluation,
string mixins and conditional compilation, so a parser-level tool guesses
exactly where the language is most interesting, and a reimplementation of the
semantics falls behind the language. The reference frontend links as a
library, but in its mainline form it cannot map a source position back to the
symbol it resolved to. It also lowers constructs such as `foreach` into
compiler temporaries that would leak into the answers, and its global mutable
state assumes one compilation per process. Finally, a file from a real project
analyzed on its own is wrong in a way that looks like a defect in the source:
every import of a sibling module becomes an error.

The package therefore builds on a fork of the frontend made for the language
server of the VisualD IDE, which records which declaration each expression
resolved to and skips the lowering; the build pins that fork by commit. Each
analysis is one full semantic pass over an in-memory module. Every query is
then answered from the same analyzed tree, without running the compiler again.
Diagnostics are captured as structured records through the frontend's own
hook, never parsed out of rendered text. Documentation comments are rendered by
the compiler's own DDoc engine, steered to emit CommonMark rather than HTML.
Context a file does not carry comes from outside it: dub's own description of
the enclosing project supplies import paths, version identifiers and flags, and
a [target profile](../../glossary.md#target-profile) tells the frontend to
analyze the code as LDC or a GPU device compile would.

Two layers stack on the core. `sparkles:twoslash-d` parses the question
notation in a [sample](../../glossary.md#analysis-sample) or in a file of a dub
project, drives the core, and assembles the positioned answers that Twoslash
calls nodes; it is the only layer that knows both the compiler and the overlay
format. The `twoslash-extract` tool writes those nodes to a payload file,
giving each input a process of its own so that no compiler state carries over
between analyses. It can also stay resident for a viewer, answering one
tooltip at a time from its single analysis. The core knows nothing of
Twoslash, and the render side never imports the core.

This specification covers the core, the analyzer, the extractor, and the
changes they require in the shared Twoslash protocol package and in hue.
Drawing overlays belongs to `sparkles:twoslash`, and hue's presentation of them
to the [hue Twoslash surface](../hue/twoslash.md). The core stops after
semantic analysis and generates no machine code. Each session analyzes once,
and sessions in one process run strictly one after another; since tearing the
frontend down leaves some of its state behind, isolation between analyses
comes from a process per analysis. It does not read dub
recipes itself, because dub resolves its own configurations and dependencies
and a second implementation would drift. It is not a language server: serving
an editor over the Language Server Protocol, with find-references and
incremental re-analysis, lies outside this contract, although the core is
shaped so that a server can grow around it.

[Design sources](#design-sources) lists the issues and specifications this one
builds on. [Architecture](#architecture) gives the layers, their coupling
rules, the reasons for the fork, and the coordinate contract between the
compiler's line-and-column positions and the renderer's byte offsets. The
requirements live in [Feature requirements](./feature-requirements.md); each
carries an ID, a status and a trace, under the
[status](../hue/index.md#status-scheme) and [ID](../hue/index.md#id-scheme)
conventions of the hue specification. Three pages specify one concern each:
[DDoc test plan](./ddoc.md) the documentation renderer,
[Dub-project context](./project.md) analysis inside a real project, and
[Target profiles & device code](./targets.md) analysis as LDC and as GPU
code. [Milestones](#milestones) records delivery, and
[Module coverage](#module-coverage) maps requirements to source files.

## Design sources

| Source                                                    | What it contributes                                                                                                                        |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| [#120](https://github.com/PetarKirov/sparkles/issues/120) | The twoslash umbrella: layer separation, the four-query backend contract, notation grammar (§3), the DMD-as-a-library decision (§4)        |
| [#124](https://github.com/PetarKirov/sparkles/issues/124) | The backend plan of record: extract a clean non-COM core from VisualD `dmdserver`; D1–D3 milestones; known costs                           |
| [hue/twoslash.md](../hue/twoslash.md)                     | The hue surface (`TWM`/`TWO`/`TWH`) and the notation-grammar inventory (`NOT1`–`NOT8`); its `DMD1`–`DMD4` rows are superseded by this spec |
| [twoslash/SPEC.md](../twoslash/SPEC.md)                   | The shipped render side; the node model this backend feeds (treated there as opaque input)                                                 |

## Architecture

Four layers, strictly separated; the shipped render side is unchanged except at
the marked seams:

```
dmd:frontend       rainers/dmd@dmdserver fork as a dub git dependency
                   (versions: LanguageServer NoBackend GC MARS)
      │
libs/dmd-lsp       sparkles:dmd-lsp — semantic core (BLD/COR/TIP/DOC1)
                   no twoslash knowledge; ported from VisualD vdc/dmdserver
      │
libs/twoslash-d    sparkles:twoslash-d — the analyzer (NTN/DOC2):
                   notation parser → drive dmd-lsp → assemble nodes → emit JSON
      │
apps/twoslash-extract   batch CLI (EXT); ONE analysis per process
      │
*.twoslash.json    {code, nodes, language: "d", offsetEncoding: "utf-8"}
      │
libs/twoslash{,-protocol} + apps/hue    shipped render side (seam: NTN4/EXT5)
```

Coupling rules: the render side never imports `dmd-lsp`; `dmd-lsp` never
imports the twoslash protocol; only `twoslash-d` knows both.

**Why the fork, not mainline `dmd.frontend`.** Mainline has the diagnostic
hooks (`diagnosticHandler`, `fatalErrorHandler`, `ErrorSink`) but cannot map a
source position back to a resolved symbol: it lacks the
`resolvedTo`/`saveOriginal` back-pointers, `Module.loadModuleHandler`,
`prettyPrintSymbolHandler`, `IdentifierAtLoc` fine-grained locations, and the
`needsCodegen = false` lowering suppression (mainline lowers `foreach` into
`__key`/`__limit` temporaries that would leak into hovers). The fork carries all
of these behind `version (LanguageServer)` (+1684/−656 over 65 files) and sits
at the **same frontend VERSION as mainline** (`v2.113.0-beta.1`).

**Frontend-only source closure.** `NoBackend` excludes native assembler
implementations and the compiler driver's C preprocessor from the library
recipe, not merely from dispatch. Coverage registration must not retain
references into the excluded native backend or linker. ImportC continues through
`global.preprocess`, installed by the real preprocessor in `sparkles:dmd-lsp`;
the full compiler package retains its native implementations.

**Coordinate contract.** DMD reports **1-based line / 1-based UTF-8-code-unit
column**; the notation parser, `sparkles:syntax`, and the node model use **byte
offsets** into the display code. `sparkles:twoslash-d` converts at the seam via
`sparkles.base.text.lineindex`, and node positions are two-phase: built as
`start`/`length` in full-source bytes, remapped through the cut map, then
resolved to `line`/`character` against the post-cut display code.

## Documentation map

| Page                                              | What it covers                                                                                                                                                                                                 |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                          | abstract and introduction · design sources · architecture · milestones · module coverage                                                                                                                       |
| [Feature requirements](./feature-requirements.md) | the requirement inventory: build & pinning (`BLD`), semantic core (`COR`), type oracle (`TIP`), ddoc (`DOC`), analyzer (`NTN`), extractor (`EXT`)                                                              |
| [DDoc test plan](./ddoc.md)                       | the whole DDoc language as a traceable test matrix (`DDC1`–`DDC84`), grounded in `spec/ddoc.dd`; supersedes `DOC3` as the requirement of record for ddoc rendering                                             |
| [Dub-project context](./project.md)               | analyzing files that belong to a real project (`PRJ`): recipe discovery, `dub describe`, the translation to `AnalyzerConfig`, and the viewer path that consumes it                                             |
| [Target profiles & device code](./targets.md)     | analyzing as LDC and as the dcompute LDC's device compile (`TGT`): the frontend profile, LDC's runtime, `@compute` shader modules, LDC's device-code rules, and merging a module's host and device diagnostics |

## Milestones

The commit-level execution plan; each lands green on its own. Track A has no
DMD dependency; Track B needs the fork pin.

| Milestone | Track | Scope                                                                                                                                   | Status                                                            |
| --------- | ----- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| L0        | A     | This spec                                                                                                                               | full (`bd21a054`)                                                 |
| L1        | A     | `sparkles.base.text.lineindex` — byte ↔ line/col                                                                                        | full (`34369c9c`)                                                 |
| L2        | A     | Extract `libs/twoslash-protocol`; add `language` + `offsetEncoding` (`NTN4`)                                                            | full (`a0626e09`)                                                 |
| L3        | A     | Parameterize the popup/highlight language in `overlay.d` + hue (`EXT5`)                                                                 | full (`1344c42b`)                                                 |
| L4        | A     | `sparkles:twoslash-d` notation parser (`NTN1`–`NTN3`)                                                                                   | full (`f8c9a846`)                                                 |
| L5        | B     | Fork branch `dmdserver-dub` + pin + `dmd-import-paths` nix plumbing (`BLD1`–`BLD4`)                                                     | full (`acef0edd`)                                                 |
| L6        | B     | `sparkles:dmd-lsp` analysis core + diagnostics (`COR1`–`COR6`)                                                                          | full (`ec71308d`)                                                 |
| L7        | B     | `semvisitor.d` port — tips, identifier types (`TIP1`–`TIP3`, `DOC1`)                                                                    | full (`032f3b35`)                                                 |
| L8        | B     | `twoslash-d` node assembly + emit + golden fixtures (`NTN2`, `DOC2`)                                                                    | full (`618e98a0`)                                                 |
| L9        | B     | `apps/twoslash-extract` CLI (`EXT1`–`EXT4`)                                                                                             | full (`5aa94285`)                                                 |
| L10       | B     | hue showcase fixtures; reconcile [hue/twoslash.md](../hue/twoslash.md) `NOT`/`DMD` statuses                                             | partial (corpus `67c04784`; spec reconciliation pending)          |
| L11       | B     | Diátaxis docs (`docs/libs/dmd-lsp/`, `docs/libs/twoslash-d/`) + `AGENTS.md` rows                                                        | not started                                                       |
| L12       | —     | _(follow-up)_ `apps/ci` twoslash verification (`@errors:` glob via <code v-pre>{{_}}</code>)                                            | not started                                                       |
| L13       | B     | [Dub-project context](./project.md) (`PRJ1`–`PRJ11`) + `twoslash-extract --dub`                                                         | full (`95a85f51`, `59e623ff`); viewer path `PRJ12`–`PRJ16` in L25 |
| L14       | B     | Fork `+ls.2` (public ddoc machinery) + pin bump                                                                                         | full (`69e0dfbd`)                                                 |
| L15       | B     | DDoc → CommonMark translator ([test plan](./ddoc.md))                                                                                   | full (`d7a33164`)                                                 |
| L16       | B     | ddoc tags on nodes + per-param hover docs                                                                                               | full (`49da12f5`)                                                 |
| L17       | A/B   | `^^^` highlights · `^\|` completions · `@filename:` multi-file (`TIP4`, `NTN`)                                                          | full (`114d49c0`, `32520ca0`, `2cc273ff`)                         |
| L18       | —     | Corpus to 36 samples (380 nodes)                                                                                                        | full (`cea792ca`)                                                 |
| L19       | A     | DDoc test plan page ([ddoc.md](./ddoc.md), `DDC1`–`DDC84`)                                                                              | full (`be5c0100`)                                                 |
| L20       | —     | Defect: dub-describe subpackage fallback (`PRJ7`)                                                                                       | full (`0dfc3168`)                                                 |
| L21       | —     | Single-walk tip collector: eager 175.8 s → **5.8 s** on `expressionsem.d` (30×)                                                         | full (`c8c76b93`)                                                 |
| L22       | —     | Lazy payloads + `--serve` oracle (0.6 ms tips) + `ResidentProcess`                                                                      | full (`0549eef6`)                                                 |
| L23       | —     | Always-on hover underlines (`Slot.hoverUnderline`)                                                                                      | full (`12038f7e`)                                                 |
| L24       | —     | Slim node encoding (eager 10.1 MB/767 KB gz, lazy 6.7 MB/465 KB gz)                                                                     | full (`08eacbb1`)                                                 |
| L25       | —     | hue live D types (`PRJ12`–`PRJ16`, hue `LIV*`)                                                                                          | full (`d3d1d7a8`)                                                 |
| L26       | B     | Imported-symbol ddoc (`DOC4`) + fork `+ls.3` (complete `typeInfoExp`)                                                                   | full                                                              |
| L27       | —     | Tooltip markdown defects: ddoc indentation read as code, unterminated fence                                                             | full                                                              |
| L28       | B     | GFM tables + numbered lists; `ditto`; documented unittests as labelled examples; fork `+ls.4` (unittest bodies outside the root module) | full                                                              |
| L29       | B     | Target profiles: LDC predefines + LLVM vector model (fork `+ls.5`), LDC runtime (`TGT1`–`TGT4`)                                         | full                                                              |
| L30       | B     | `@compute` detection + the dub device configuration (`TGT5`, `TGT6`)                                                                    | full                                                              |
| L31       | B     | LDC's device-code rules + `@fragment` interface checks (`TGT7`, `TGT8`)                                                                 | full                                                              |
| L32       | —     | Host + device diagnostics merged in one payload; `twoslash-extract --side` (`TGT9`)                                                     | full                                                              |

Of issue #124's D3, completions are delivered (L17, `TIP4`); references, and
D4 (a JSON-RPC LSP server), lie outside this specification and would build on
the same core.

## Module coverage

| Source                                                              | Requirements                                                |
| ------------------------------------------------------------------- | ----------------------------------------------------------- |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/init_.d` + `options.d`           | `COR2`, `COR5`, `COR6`, `TGT1`–`TGT4` (port of `dmdinit.d`) |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/diag.d`                          | `COR3` (port of `dmderrors.d`)                              |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/api.d` + `testing.d`             | the facade; `COR1`, `COR2`, `COR6`, `TIP4`, test gating     |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/cpreprocess.d`                   | `COR7`                                                      |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/visitor.d` + `support.d`         | `TIP1`–`TIP4`, `DOC1`, `DOC4` (port of `semvisitor.d`)      |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/signature.d`                     | `TIP5`                                                      |
| `libs/twoslash-d/src/sparkles/twoslash_d/notation.d`                | `NTN1`–`NTN2`                                               |
| `libs/twoslash-d/src/sparkles/twoslash_d/analyze.d` + `emit.d`      | `NTN3`–`NTN4`, `DOC2`–`DOC3`                                |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/ddoc.d`                          | `DOC3`; the [`DDC`](./ddoc.md) matrix                       |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/project.d` + `recipe.d`          | [`PRJ1`–`PRJ9`, `PRJ17`–`PRJ18`](./project.md)              |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/device.d` + `dcompute.d`         | [`TGT5`–`TGT8`](./targets.md)                               |
| `libs/twoslash-d/src/sparkles/twoslash_d/merge.d`                   | [`TGT9`](./targets.md)                                      |
| `apps/twoslash-extract/src/app.d`                                   | `EXT1`–`EXT4`, `EXT6`–`EXT7`; `PRJ10`–`PRJ11`; `TGT9`       |
| `libs/twoslash-protocol/` + `libs/twoslash/` + `apps/hue/src/app.d` | `NTN4`, `EXT5`                                              |
| `nix/packages/dmd-import-paths.nix` + `nix/dub-lock.json`           | `BLD2`–`BLD3`                                               |

→ [Feature requirements](./feature-requirements.md) ·
[hue twoslash surface](../hue/twoslash.md) ·
[render-side spec](../twoslash/SPEC.md)
