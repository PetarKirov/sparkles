# SQL & ORM survey — grounding ledger

Claim-by-claim source verification of every page under `docs/research/sql/`. Each survey
page has a `<page>.md` ledger; every material assertion is checked against a **local**
primary artifact — a repository pinned in [`_sources.md`](./_sources.md). Web is
fallback-only (release dates, download counts, adoption). This tree is internal QA
evidence — excluded from the VitePress build (`srcExclude`) and from lychee.

> Not published research. Do not link to it from the survey pages.

## Status legend

| Mark | Meaning                                                                                |
| ---- | -------------------------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact (locator recorded)                           |
| `⚠`  | Discrepancy — wrong/misattributed/fabricated; correction recorded + applied to the doc |
| `◯`  | Not locally groundable — editorial/opinion, or source unobtainable (fallback named)    |

**Types:** `quote` · `fact` (date/author/license/attribution) · `figure` (number/version) ·
`behavior` (library does X) · `exposition` (standard knowledge) · `opinion`.

## Per-page ledgers

Populated as each wave lands. Waves: **W1** effects core · **W2** Haskell typed cluster ·
**W3** typed builders / thin · **W4** full ORMs · **W5** raw / baseline · **W6** synthesis.

| Page      | Ledger                         | Claims | ✓   | ⚠   | Wave |
| --------- | ------------------------------ | ------ | --- | --- | ---- |
| effect-ts | [effect-ts.md](./effect-ts.md) | 59     | 57  | 0   | W1   |
| quill     | [quill.md](./quill.md)         | 52     | 47  | 0   | W1   |
| doobie    | [doobie.md](./doobie.md)       | 64     | 58  | 0   | W1   |
| skunk     | [skunk.md](./skunk.md)         | 56     | 53  | 0   | W1   |
| slick     | [slick.md](./slick.md)         | 56     | 53  | 1   | W1   |
| ecto      | [ecto.md](./ecto.md)           | 72     | 69  | 1   | W1   |

## Master discrepancy register

Union of all `⚠` rows, populated as each batch lands. The non-`✓` remainder is `◯`
(web-attested release dates / versions on a `--depth 1` clone, or editorial) — recorded
per page.

| #   | Page       | Claim                                                                   | Correction                                                                                                                                   | Source                               | Fixed? |
| --- | ---------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ | ------ |
| R1  | (concepts) | Landscape table grouped `Ecto` under "Effect-system SQL / effect value" | `Ecto` is eager, blocking tagged-tuple `Repo` calls over BEAM processes — not an effect value; regrouped as "Functional data mapper (eager)" | `elixir/ecto` `lib/ecto.ex`          | ✓ W1   |
| R2  | (index)    | Slick framed as "`DBIO` run to a `Future`" (Slick 3)                    | pinned checkout is in-development **Slick 4** with an effect-polymorphic runner (`IO`/`Future`/ZIO facades); catalog + taxonomy updated      | `scala/slick` `slick/Database.scala` | ✓ W1   |

### Batch 1 (wave 1 — effects-first core, 2026-07-12)

Six pages grounded at authoring time against the pinned local checkouts
([`_sources.md`](./_sources.md)): [effect-ts](./effect-ts.md), [quill](./quill.md),
[doobie](./doobie.md), [skunk](./skunk.md), [slick](./slick.md), [ecto](./ecto.md).
**Zero substantive page discrepancies** — every material blockquote copy-paste-matches the
source tree. Two _survey-level_ corrections were caught during authoring and applied to the
shared pages (R1, R2 above) rather than left in a deep-dive. The `◯` remainder per page is
the web-attested set only: first-release years, latest version numbers, docs-site URLs.
Licenses confirmed from each `LICENSE`: Effect TS **MIT**, Quill **Apache-2.0**, doobie
**MIT**, skunk **MIT**, Slick **BSD-2-Clause**, Ecto **Apache-2.0**.
