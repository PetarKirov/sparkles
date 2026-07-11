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

| Page      | Ledger                         | ⚠   | Wave |
| --------- | ------------------------------ | --- | ---- |
| effect-ts | [effect-ts.md](./effect-ts.md) | —   | W1   |
| quill     | [quill.md](./quill.md)         | —   | W1   |
| doobie    | [doobie.md](./doobie.md)       | —   | W1   |
| skunk     | [skunk.md](./skunk.md)         | —   | W1   |
| slick     | [slick.md](./slick.md)         | —   | W1   |
| ecto      | [ecto.md](./ecto.md)           | —   | W1   |

## Master discrepancy register

Union of all `⚠` rows, populated as each batch lands.

| #   | Page | Claim | Correction | Source | Fixed? |
| --- | ---- | ----- | ---------- | ------ | ------ |
| —   | —    | —     | —          | —      | —      |

_(No batches grounded yet.)_
