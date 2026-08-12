# Grounding ledger — Compiler switches

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`. Locators under
`$REPOS/dlang/dlang.org/changelog/`.

## Preview → default table

| #   | Claim (short)                                  | Type | Versions claimed | Source                                                                                                       | Status |
| --- | ---------------------------------------------- | ---- | ---------------- | ------------------------------------------------------------------------------------------------------------ | ------ |
| 1   | `-preview`/`-revert` replace ad-hoc `-dipNNNN` | fact | [2.085]          | `2.085.0.dd` § `preview-flags`                                                                               | ✓      |
| 2   | `intpromote` default                           | fact | [2.099]          | `2.099.0.dd` § `fix16997` “`-preview=intpromote` … set by default”                                           | ✓      |
| 3   | `intpromote` intro as preview                  | fact | [2.085]          | `2.085.0.dd` § `preview-flags` list (`-preview=intpromote`)                                                  | ✓      |
| 4   | `dtorfields` default                           | fact | [2.098]          | `2.098.0.dd` § `dtorfileds` (typo in slug) “enabled by default”                                              | ✓      |
| 5   | `dtorfields` intro                             | fact | [2.083]          | `2.083.0.dd` `transition=dtorfields`; also listed as `-preview=dtorfields` in `2.085.0.dd` § `preview-flags` | ≈      |
| 6   | `markdown` default                             | fact | [2.094]          | `2.094.0.dd` § `markdown-default`                                                                            | ✓      |
| 7   | `markdown` intro as preview                    | fact | [2.085]          | `2.085.0.dd` § `preview-flags` (`-preview=markdown`)                                                         | ✓      |
| 8   | `shortenedMethods` default                     | fact | [2.101]          | `2.101.0.dd` § `dmd.shortenedMethodsEnabled`                                                                 | ✓      |
| 9   | `shortenedMethods` preview                     | fact | [2.096]          | `2.096.0.dd` § `shortfunctions`                                                                              | ✓      |
| 10  | `dip25` default (errors)                       | fact | [2.103]          | `2.103.0.dd` § `dmd.dip25-default`                                                                           | ✓      |
| 11  | `dip25` deprecations by default                | fact | [2.092]          | `2.092.0.dd` § `dip25`                                                                                       | ✓      |
| 12  | `dip1000` deprecations by default              | fact | [2.101]          | `2.101.0.dd` § `dmd.dip1000_deprecation_warnings`                                                            | ✓      |
| 13  | `bitfields` default                            | fact | [2.112]          | `2.112.0.dd` § `dmd.bitfields`                                                                               | ✓      |
| 14  | `bitfields` preview                            | fact | [2.101]          | `2.101.0.dd` § `dmd.bitfields`                                                                               | ✓      |

## Opt-in previews (prose)

| #   | Claim                                                                          | Type    | Versions | Source / note                                                           | Status |
| --- | ------------------------------------------------------------------------------ | ------- | -------- | ----------------------------------------------------------------------- | ------ |
| 15  | Repo baseline: `in` + `dip1000`                                                | opinion | —        | Sparkles `AGENTS.md` / package `dub.sdl`                                | ◯      |
| 16  | Worth opting: `fixImmutableConv`, `systemVariables`, `safer`, `nosharedaccess` | fact    | various  | Each has a named `-preview=` entry (see memory-safety / shared ledgers) | ✓      |
| 17  | No language edition shipped through 2.112; editions referenced from [2.109]    | fact    | [2.109]  | `2.109.0.dd` “next edition” entries; no edition ship through 2.112      | ≈      |

## Diagnostics / build switches

| #   | Claim                                          | Type    | Versions | Source                                       | Status |
| --- | ---------------------------------------------- | ------- | -------- | -------------------------------------------- | ------ |
| 18  | `-verrors=context`                             | fact    | [2.085]  | `2.085.0.dd` § `error-context`               | ✓      |
| 19  | `-checkaction=context`                         | fact    | [2.085]  | `2.085.0.dd` (checkaction=context examples)  | ✓      |
| 20  | `-checkaction=D\|C\|halt`                      | fact    | [2.084]  | `2.084.0.dd` § `checkaction`                 | ✓      |
| 21  | `-check=` fine-grained                         | fact    | [2.084]  | `2.084.0.dd` Option list `check=[assert\|…]` | ✓      |
| 22  | `-verrors=spec`                                | fact    | [2.072]  | `2.072.0.dd` § `dash_verrors_spec`           | ✓      |
| 23  | `-boundscheck=safeonly`                        | fact    | [2.066]  | `2.066.0.dd` § `boundscheck`                 | ✓      |
| 24  | `-i` include-imports                           | fact    | [2.079]  | `2.079.0.dd` § `includeimports`              | ✓      |
| 25  | `-vasm`                                        | fact    | [2.099]  | `2.099.0.dd` § `disasm`                      | ✓      |
| 26  | `-ftime-trace`                                 | fact    | [2.111]  | `2.111.0.dd` § `dmd.ftime-trace`             | ✓      |
| 27  | `-oq`                                          | fact    | [2.111]  | `2.111.0.dd` § `dmd.oq-compiler-switch`      | ✓      |
| 28  | Demangled linker errors                        | fact    | [2.109]  | `2.109.0.dd` (linker demangle prose)         | ≈      |
| 29  | `-vgc`                                         | fact    | [2.066]  | `2.066.0.dd` § `vgc-switch`                  | ✓      |
| 30  | `-profile=gc`                                  | fact    | [2.068]  | `2.068.0.dd` § `profile-gc`                  | ✓      |
| 31  | `-lowmem`                                      | fact    | [2.086]  | `2.086.0.dd` § `lowmem`                      | ✓      |
| 32  | `-nothrow`                                     | fact    | [2.106]  | `2.106.0.dd` § `dmd.fix24084`                | ✓      |
| 33  | `-target=<triple>`                             | fact    | [2.098]  | `2.098.0.dd` § `target`                      | ✓      |
| 34  | Unittest flags `-checkaction=context -allinst` | opinion | —        | Repo policy                                  | ◯      |
