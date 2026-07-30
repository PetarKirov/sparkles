# `sparkles:dmd-lsp` — Feature Specification

_**Status:** in design/implementation (branch `feat/dmd-twoslash`) ·
**Date:** 2026-07-30 · **Scope:** the D-native twoslash backend — the
`sparkles:dmd-lsp` semantic core (`libs/dmd-lsp`), the twoslash analyzer
`sparkles:twoslash-d` (`libs/twoslash-d`), the batch extractor
`apps/twoslash-extract`, and the seam changes they require in
`libs/twoslash-protocol` and `apps/hue`._

`sparkles:dmd-lsp` is a reusable **DMD-as-a-library semantic core**: it runs the
real DMD frontend over an in-memory D buffer (parse → full semantic) and answers
positional queries — diagnostics, resolved-type-at-position ("hover"),
per-identifier semantic classification, and (later) completions. Its first
consumer is the **D-native twoslash backend** ([issue
#124](https://github.com/PetarKirov/sparkles/issues/124)): a batch-mode
extractor that turns an annotated D sample into a `.twoslash.json` node payload
rendered by the already-shipped `sparkles:twoslash` render side and `apps/hue`.
Longer term it is the seed of a real D language server (issue #124's D4).

This spec is a **traceable feature inventory** in the style of
[`docs/specs/hue/`](../hue/index.md): every requirement carries an ID, a status,
and a trace; the status and ID conventions are the hue spec's
([status scheme](../hue/index.md#status-scheme) ·
[ID scheme](../hue/index.md#id-scheme)).

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

**Coordinate contract.** DMD reports **1-based line / 1-based UTF-8-code-unit
column**; the notation parser, `sparkles:syntax`, and the node model use **byte
offsets** into the display code. `sparkles:twoslash-d` converts at the seam via
`sparkles.base.text.lineindex`, and node positions are two-phase: built as
`start`/`length` in full-source bytes, remapped through the cut map, then
resolved to `line`/`character` against the post-cut display code.

## Documentation map

| Page                                              | What it covers                                                                                                                                                     |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Overview** (this page)                          | what `sparkles:dmd-lsp` is · architecture · why the fork · milestones · module coverage                                                                            |
| [Feature requirements](./feature-requirements.md) | the requirement inventory: build & pinning (`BLD`), semantic core (`COR`), type oracle (`TIP`), ddoc (`DOC`), analyzer (`NTN`), extractor (`EXT`)                  |
| [DDoc test plan](./ddoc.md)                       | the whole DDoc language as a traceable test matrix (`DDC1`–`DDC84`), grounded in `spec/ddoc.dd`; supersedes `DOC3` as the requirement of record for ddoc rendering |
| [Dub-project context](./project.md)               | analyzing files that belong to a real project (`PRJ`): recipe discovery, `dub describe`, the translation to `AnalyzerConfig`, and the viewer path that consumes it |

## Milestones

The commit-level execution plan; each lands green on its own. Track A has no
DMD dependency; Track B needs the fork pin.

| Milestone | Track | Scope                                                                                       | Status                                                                 |
| --------- | ----- | ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| L0        | A     | This spec                                                                                   | full (`bd21a054`)                                                      |
| L1        | A     | `sparkles.base.text.lineindex` — byte ↔ line/col                                            | full (`34369c9c`)                                                      |
| L2        | A     | Extract `libs/twoslash-protocol`; add `language` + `offsetEncoding` (`NTN4`)                | full (`a0626e09`)                                                      |
| L3        | A     | Parameterize the popup/highlight language in `overlay.d` + hue (`EXT5`)                     | full (`1344c42b`)                                                      |
| L4        | A     | `sparkles:twoslash-d` notation parser (`NTN1`–`NTN3`)                                       | full (`f8c9a846`)                                                      |
| L5        | B     | Fork branch `dmdserver-dub` + pin + `dmd-import-paths` nix plumbing (`BLD1`–`BLD4`)         | full (`acef0edd`)                                                      |
| L6        | B     | `sparkles:dmd-lsp` analysis core + diagnostics (`COR1`–`COR6`)                              | full (`ec71308d`)                                                      |
| L7        | B     | `semvisitor.d` port — tips, identifier types (`TIP1`–`TIP3`, `DOC1`)                        | full (`032f3b35`)                                                      |
| L8        | B     | `twoslash-d` node assembly + emit + golden fixtures (`NTN2`, `DOC2`)                        | full (`618e98a0`)                                                      |
| L9        | B     | `apps/twoslash-extract` CLI (`EXT1`–`EXT4`)                                                 | full (`5aa94285`)                                                      |
| L10       | B     | hue showcase fixtures; reconcile [hue/twoslash.md](../hue/twoslash.md) `NOT`/`DMD` statuses | partial (corpus `67c04784`; spec reconciliation pending)               |
| L11       | B     | Diátaxis docs (`docs/libs/dmd-lsp/`, `docs/libs/twoslash-d/`) + `AGENTS.md` rows            | not started                                                            |
| L12       | —     | _(follow-up)_ `apps/ci` twoslash verification (`@errors:` glob via `{{_}}`)                 | not started                                                            |
| L13       | B     | [Dub-project context](./project.md) (`PRJ1`–`PRJ11`) + `twoslash-extract --dub`             | full (`95a85f51`, `59e623ff`); viewer path `PRJ12`–`PRJ16` not started |

Issue #124's D3 (completions, references) and D4 (JSON-RPC LSP server) are
follow-on milestones behind the same core.

## Module coverage (planned)

| Source                                                         | Requirements                                   |
| -------------------------------------------------------------- | ---------------------------------------------- |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/init.d` + `options.d`       | `COR2`, `COR5` (port of `dmdinit.d`)           |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/errors.d`                   | `COR3` (port of `dmderrors.d`)                 |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/analysis.d`                 | `COR1`, `COR6` (port of `semanalysis.d`)       |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/visitor.d` + `support.d`    | `TIP1`–`TIP3`, `DOC1` (port of `semvisitor.d`) |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/api.d` + `testing.d`        | the facade; `COR2`, test gating                |
| `libs/twoslash-d/src/sparkles/twoslash_d/notation.d`           | `NTN1`–`NTN2`                                  |
| `libs/twoslash-d/src/sparkles/twoslash_d/analyze.d` + `emit.d` | `NTN3`–`NTN4`, `DOC2`–`DOC3`                   |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/ddoc.d`                     | `DOC3`; the [`DDC`](./ddoc.md) matrix          |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/project.d`                  | [`PRJ1`–`PRJ9`](./project.md)                  |
| `apps/twoslash-extract/src/app.d`                              | `EXT1`–`EXT4`, `EXT6`; `PRJ10`–`PRJ11`         |
| `libs/twoslash-protocol/` (extracted) + `apps/hue/src/app.d`   | `NTN4`, `EXT5`                                 |
| `nix/packages/dmd-import-paths.nix` + `nix/dub-lock.json`      | `BLD2`–`BLD3`                                  |

→ [Feature requirements](./feature-requirements.md) ·
[hue twoslash surface](../hue/twoslash.md) ·
[render-side spec](../twoslash/SPEC.md)
