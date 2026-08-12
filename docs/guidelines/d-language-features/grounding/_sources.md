# Grounding sources — local-artifact map

> Not published. Do not link to it from the guide.

Lookup table for claim-by-claim verification of
`docs/guidelines/d-language-features/index.md` against the local `dlang.org`
changelog tree. Prefer local `.dd` files over web HTML.

`$REPOS` = `/home/petar/code/repos`.

## Primary pin

| Item          | Value                                                                     |
| ------------- | ------------------------------------------------------------------------- |
| Repo          | `$REPOS/dlang/dlang.org`                                                  |
| Full SHA      | `351dd6d91bfed604b473c4dedd4b5fdf262c3629`                                |
| As of         | 2026-08-07 (commit: Publish 2.113.0 rc.1)                                 |
| Reviewed      | 2026-08-12                                                                |
| Path          | `changelog/`                                                              |
| Files used    | `2.060.dd` … `2.112.0.dd` (patch `.1` only when a claim is about a patch) |
| Public mirror | https://dlang.org/changelog/ (reader-facing links in `index.md` only)     |

**Guide ceiling:** published guide stops at **2.112**. This pin also contains
`2.112.1.dd` and `2.113.0_pre.dd` — do **not** silently extend the guide to 2.113
without an explicit edit of `index.md`'s upper bound.

### Filename quirks

| Pattern               | Examples                                                     |
| --------------------- | ------------------------------------------------------------ |
| Early (no `.0`)       | `2.060.dd`, `2.061.dd`, `2.063.dd`, `2.064.dd`               |
| From ~2.065           | `2.065.0.dd`, `2.066.0.dd`, …                                |
| Guide reference links | `[2.066]` → `2.066.0.html` (public); local file `2.066.0.dd` |

### Locator convention

```text
# Preferred
changelog/2.111.0.dd § dmd.auto-ref-local

# Optional line pin (at the recorded SHA)
changelog/2.111.0.dd:80
```

Changelog structure: TOC uses `$(RELATIVE_LINK2 slug, …)`; body sections use
`$(LNAME2 slug, …)` or `$(LEGACY_LNAME2 …)`.

Do **not** re-fetch dlang.org HTML for verification when the local `.dd` is present.

## Secondaries

| Secondary                 | Path / URL                                                                    | Use when                                                                                              |
| ------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| DIPs                      | `$REPOS/dlang/DIPs` @ `f6af5870f0304be81c59fe19bafda799124f4cfc` (2026-07-15) | Changelog only names/links a DIP                                                                      |
| D language specification  | https://dlang.org/spec/spec.html (🌐 if needed)                               | DIP text has drifted (notably DIP1000)                                                                |
| Deprecated features table | https://dlang.org/deprecate.html                                              | “Still legal legacy” vs removed/deprecated forms                                                      |
| dmd git history           | `$REPOS/dlang/dmd`                                                            | Feature landed without a release-note until later (e.g. named arguments in 2.103, changelog at 2.108) |

## Repo policy (not changelog-groundable)

Sparkles baseline flags and house rules are `◯` against:

- `docs/guidelines/AGENTS.md` (§ Preview flags, safety attributes, `@nogc` primitives)
- Per-package `dub.sdl` `dflags` (`-preview=in`, `-preview=dip1000`)

## Acquisition notes

- Local clone was present at review; no web fetch of changelog HTML was required
  for the primary pass.
- Early releases (≤2.062) are sparse: features may appear only in `$(COMMENT)`
  Bugzilla lists or as “newly introduced” wording in the _next_ release — mark
  `≈` and name the locator.
