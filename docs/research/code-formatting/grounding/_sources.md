# Sources — local artifacts for `docs/research/code-formatting/`

Every claim in this tree is checked against an artifact listed here. `$REPOS = /home/petar/code/repos`;
`$PAPERS = $REPOS/papers/code-formatting`.

**Acquisition:** 17 of the 20 cited primaries obtained (2026-08-15); 3 paywalled with no located
preprint. 18 source trees pinned. `pdftotext -layout` extractions of every held paper live in
`$PAPERS/txt/` and are the basis for the `(txt Lnn)` locators used throughout the ledgers.

---

## Papers — `$PAPERS/`

| Artifact                                                                  | Paper                                                                        | Extraction quality                                                                                                      |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `oppen-1980-prettyprinting-toplas.pdf`                                    | Oppen 1980, TOPLAS 2(4)                                                      | ⚠ **OCR-degraded** — intra-word spacing in §§4, 8; abstract and §§1–2 clean                                             |
| `hughes-1995-design-pretty-printing-library-afp.pdf`                      | Hughes 1995, LNCS 925                                                        | ❌ **No usable text layer** — Type 3 subset fonts, mojibake. Quotes read from 130 dpi `pdftoppm` renderings of pp. 1, 3 |
| `wadler-1998-prettier-printer.pdf`                                        | Wadler, _The Fun of Programming_                                             | ✅ clean                                                                                                                |
| `lindig-2000-strictly-pretty.pdf`                                         | Lindig 2000                                                                  | ✅ clean                                                                                                                |
| `chitil-2005-pretty-printing-lazy-dequeues-toplas.pdf`                    | Chitil 2005, TOPLAS 27(1)                                                    | ✅ clean                                                                                                                |
| `chitil-2006-pretty-printing-delimited-continuations-techreport.pdf`      | Chitil 2006, Kent TR 4-06                                                    | ✅ clean                                                                                                                |
| `swierstra-chitil-2009-linear-bounded-functional-pretty-printing-jfp.pdf` | Swierstra & Chitil, JFP 19(1)                                                | ✅ clean                                                                                                                |
| `bernardy-2017-pretty-but-not-greedy-printer-icfp.pdf`                    | Bernardy 2017, PACM PL 1(ICFP)                                               | ✅ clean                                                                                                                |
| `yelland-2016-new-approach-optimal-code-formatting-google.pdf`            | Yelland 2016 (`rfmt`)                                                        | ✅ clean                                                                                                                |
| `porncharoenwase-2023-pretty-expressive-printer-oopsla.pdf`               | Porncharoenwase, Pombrio & Torlak 2023 (arXiv 2310.01530, "with Appendices") | ✅ clean                                                                                                                |
| `geirsson-2016-scalafmt-thesis-epfl.pdf`                                  | Geirsson 2016, MSc thesis, EPFL                                              | ✅ clean                                                                                                                |
| `vandenbrand-visser-1996-generation-formatters-box-toplas.pdf`            | van den Brand & Visser 1996, TOSEM 5(1)                                      | ⚠ **OCR-degraded** — broken words throughout; quoted regions verified against the PDF                                   |
| `dejonge-visser-2011-layout-preservation-refactoring-sle.pdf`             | de Jonge & Visser 2011, SLE 2011                                             | ✅ clean                                                                                                                |
| `buse-weimer-2010-learning-metric-code-readability-tse.pdf`               | Buse & Weimer 2010, TSE 36(4)                                                | ✅ clean (via Wayback)                                                                                                  |
| `posnett-2011-simpler-model-software-readability-msr.pdf`                 | Posnett, Hindle & Devanbu 2011, MSR                                          | ✅ clean                                                                                                                |
| `scalabrino-2018-comprehensive-model-code-readability-jsep.pdf`           | Scalabrino et al. 2018, JSEP 30(6)                                           | ✅ clean                                                                                                                |
| `mi-2021-data-augmentation-code-readability-ist.pdf`                      | Mi et al. 2021 (obtained as the nearest available from the same group)       | ✅ clean                                                                                                                |

### Not obtained

| Paper                                                                                                                    | Why                                | Consequence                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------ | ---------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Podkopaev & Boulytchev, _Polynomial-Time Optimal Pretty-Printing Combinators with Choice_, PSI 2014 / LNCS 8974 (2015)   | Springer-only; no preprint located | All claims via `apep23` §2 and Table 1 — 🌐 in [`theory-optimality`](./theory-optimality.md) rows 20, 23 |
| Mi, Keung, Xiao, Mensah & Gao, _Improving code readability classification using convolutional neural networks_, IST 2018 | Elsevier paywall                   | 🌐 in [`readability-evidence`](./readability-evidence.md)                                                |
| Mi, Hao, Ou & Ma, _Towards using visual, semantic and structural features…_, JSS 2022                                    | Elsevier paywall                   | 🌐, as above                                                                                             |

> [!NOTE]
> **Title/author check.** The brief that commissioned this survey cited "Mi, Keung, Xiao, Mensah &
> Gao (2022)". That author set matches the **2018** ConvNet paper; the 2022 JSS paper is by Mi,
> Hao, Ou & Ma. Both are recorded above and neither was obtained.

---

## Source repos — pinned to reviewed HEAD

| Repo                           | Path                                | Pinned SHA                                 | As of                       | Clone depth                           |
| ------------------------------ | ----------------------------------- | ------------------------------------------ | --------------------------- | ------------------------------------- |
| prettier                       | `$REPOS/typescript/prettier`        | `414e453ae9034866d93eea456b430aa52140371b` | 2026-08-13                  | full                                  |
| rustfmt                        | `$REPOS/rust/rustfmt`               | `320de2e6d44f3190ea7cc73772e67a2ae86f5e71` | 2026-08-14                  | full                                  |
| llvm-project                   | `$REPOS/llvm-project`               | `73802c2e9d102a4fb646bc039754779fca3ea476` | 2026-06-04                  | **depth 1**                           |
| dfmt                           | `$REPOS/dlang/dlang-community/dfmt` | `c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76` | 2026-05-30 (`v0.15.2-5-g…`) | full                                  |
| go                             | `$REPOS/go/go`                      | `015343854b5d9e2829481df30dbcae2ca6682d25` | 2026-06-01                  | full                                  |
| zig                            | `$REPOS/zig/zig`                    | `1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa` | 2026-06-02 (tag `0.16.0`)   | full                                  |
| roslyn                         | `$REPOS/dotnet/roslyn`              | `e42c3902b0c0f922771e06b5222dadee92fb0e2e` | 2026-07-02                  | full                                  |
| sdc (`sdfmt`)                  | `$REPOS/dlang/sdc`                  | `611d70adcfcba0afbeae546bc8a5c52d655add69` | 2026-03-16 (tag `0.0.15`)   | full                                  |
| rust (for `rustc_ast_pretty`)  | `$REPOS/rust/rust`                  | `3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21` | 2026-05-22                  | full                                  |
| rust-analyzer                  | `$REPOS/rust/rust-analyzer`         | `3033d4fac8aab3f1725aa9c9d6293436aeceb0a5` | 2026-07-02                  | full                                  |
| ocaml (for `stdlib/format.ml`) | `$REPOS/ocaml/ocaml`                | `ddb608abde9cd4787a24c825e07352dfa73fd717` | 2026-06-02                  | full                                  |
| dart_style                     | `$REPOS/dart/dart_style`            | `3b1f30e3a0b568281f72320bcb248a2f0cd8ce79` | 2026-08-13                  | **depth 1**                           |
| topiary                        | `$REPOS/rust/topiary`               | `a307aee6787602e51087c54f867976949feae383` | 2026-08-13                  | **depth 1**                           |
| ocamlformat                    | `$REPOS/ocaml/ocamlformat`          | `20c4543119c82a51c2f3a9bf81620a7f31fe0e50` | 2026-07-30                  | **depth 1**                           |
| swift-format                   | `$REPOS/swift/swift-format`         | `4be9f3a16d429df692694ab17744b1014b0ac7af` | 2026-08-06                  | **depth 1**                           |
| black                          | `$REPOS/python/black`               | `74371e2041a3120a049ced8f1cab0e7a6bc8ecd3` | 2026-08-06                  | **depth 1**                           |
| dprint                         | `$REPOS/rust/dprint`                | `350f31d737b4f1ebb9bafdd9eecbfb1d0a427eec` | 2026-08-04                  | **depth 1**                           |
| biome                          | `$REPOS/rust/biome`                 | `3e8c4887c4ef87df45f56aafa4fbc5f497dae42f` | 2026-08-15                  | **depth 1**                           |
| ruff                           | `$REPOS/rust/ruff`                  | `3b067a163e58614fd022c24f1274404a0f386179` | 2026-08-14                  | **depth 1**                           |
| scalafmt                       | `$REPOS/scala/scalafmt`             | `d425e5652aa0a01460aad1ca2726eb7fd397378b` | 2026-08-11                  | **depth 1** — **cloned but NOT read** |
| google-java-format             | `$REPOS/java/google-java-format`    | `b291d957157c737ee6ac9574c1ea9c8c0ec077c2` | 2026-08-13                  | **depth 1**                           |

> [!WARNING]
> **Depth-1 clones cannot date their own history.** This is why two milestone rows in
> [`theory/index.md`](../theory/index.md#milestones) (clang-format 2013, dart_style 3.0.0 2024)
> are flagged `*` as unsourced. Refetch with history to upgrade them.

> [!WARNING]
> **`$REPOS/scala/scalafmt` was cloned but never read.** All scalafmt claims in this tree come from
> [Geirsson's 2016 thesis][geirsson] and describe the tool **as designed in 2016**. See
> [`theory-cost-and-search`](./theory-cost-and-search.md) D-CS1.

### The D substrate

| Artifact                                                 | Pin                                                                                     | Read                                                                                                                   |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `dmd:frontend` (the `dmdserver-dub` LanguageServer fork) | `ea88375142644d2dc7755089357acdfdd69c6620`, `git+https://github.com/PetarKirov/dmd.git` | `~/.dub/packages/dmd/ea883751…/dmd/compiler/src/dmd/{lexer,tokens,location}.d`                                         |
| `sparkles` (this repo)                                   | `557ccfc11709507ecfbd50991b5afe1dbffd4686`                                              | `libs/dmd-lsp/`, `libs/twoslash/src/sparkles/twoslash/signature_layout.d`, `libs/base/src/sparkles/base/prettyprint.d` |

### Not cloned, and cited anyway

`astyle`, `uncrustify` — characterized from general knowledge in
[`long-tail.md`](../long-tail.md#astyle-uncrustify-and-the-pre-ast-generation), flagged 🌐 in the
doc and in [its ledger](./long-tail.md). Verify or remove.

Ruby's `prettyprint` — 🌐 in [`theory-oppen`](./theory-oppen.md) row 29.

<!-- References -->

[geirsson]: https://geirsson.com/assets/olafur.geirsson-scalafmt-thesis.pdf
