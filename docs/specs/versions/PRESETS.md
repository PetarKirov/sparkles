# `sparkles.versions.presets` — Real-World Layout Catalogue

_Audience: contributors using or extending the preset layouts.
This document maps real-world versioning schemes to the `Layout`
type that handles each, names the new layouts the module
introduces, and records the provenance of every example string.
For the engine specification, see [SPEC.md](./SPEC.md); for delivery
order, see [PLAN.md](./PLAN.md); for design history, see
[RATIONALE.md](./RATIONALE.md)._

## 1. Overview

```d
import sparkles.versions.presets;

auto ubuntu = CalVerYYMM.parse("24.04.1", ParseMode.strict).value;
auto vim    = Vim       .parse("9.1.0400", ParseMode.strict).value;
auto rust   = SemVer    .parse("1.78.0",   ParseMode.strict).value;
```

The module ships layouts mapped to versioning schemes used by 25+
widely-deployed projects. Most are aliases or near-aliases of the
engine's core `SemVerLayout`; three introduce new static
`@Component.printWidth` configurations. None require engine changes
— they are direct evidence that the DbI design admits real-world
schemes through layout authoring alone.

Source material — the raw analyst catalogue of 50 products and the
engine capabilities each scheme exercises — is inlined as an
appendix in [§8](#8-source-material-appendix). Part 1 (items 1–25)
is the 64-bit fast-path compatible subset covered by this module;
part 2 (items 26–50) is deferred (see §5).

## 2. Coverage table

The 23 in-scope entries from part 1. Two more (Go, Python) are
deferred; see §5.

| #   | Product      | Example      | Layout                 | Mode      | Notes                                                     |
| --- | ------------ | ------------ | ---------------------- | --------- | --------------------------------------------------------- |
| 1   | Node.js      | `20.13.1`    | `SemVerLayout`         | strict    |                                                           |
| 2   | Rust         | `1.78.0`     | `SemVerLayout`         | strict    |                                                           |
| 3   | Kubernetes   | `1.30.0`     | `SemVerLayout`         | strict    |                                                           |
| 4   | Angular      | `17.3.0`     | `SemVerLayout`         | strict    |                                                           |
| 5   | React        | `18.3.1`     | `SemVerLayout`         | strict    |                                                           |
| 8   | Ubuntu       | `24.04.1`    | `CalVerYYMMLayout`     | strict    | `printWidth: 2` on minor                                  |
| 9   | Arch Linux   | `2024.05.01` | `CalVerYYYYMMDDLayout` | strict    | `printWidth: 2` on minor and patch; year ≤ 32767          |
| 10  | Linux Kernel | `6.8.9`      | `SemVerLayout`         | strict    |                                                           |
| 11  | PostgreSQL   | `16.3`       | `SemVerLayout`         | **loose** | loose mode infills patch = 0                              |
| 12  | Docker       | `26.1.1`     | `SemVerLayout`         | strict    | classified as CalVer in §8.1 but minor = 1 unpadded       |
| 13  | Git          | `2.45.1`     | `SemVerLayout`         | strict    |                                                           |
| 14  | PHP          | `8.3.7`      | `SemVerLayout`         | strict    |                                                           |
| 15  | Ruby         | `3.3.1`      | `SemVerLayout`         | strict    |                                                           |
| 16  | Nginx        | `1.26.0`     | `SemVerLayout`         | strict    | even/odd minor convention is policy, not format           |
| 17  | Apache HTTP  | `2.4.59`     | `SemVerLayout`         | strict    |                                                           |
| 18  | Redis        | `7.2.4`      | `SemVerLayout`         | strict    |                                                           |
| 19  | MongoDB      | `7.0.8`      | `SemVerLayout`         | strict    |                                                           |
| 20  | SQLite       | `3.45.3`     | `SemVerLayout`         | strict    |                                                           |
| 21  | cURL         | `8.7.1`      | `SemVerLayout`         | strict    |                                                           |
| 22  | FFmpeg       | `7.0.1`      | `SemVerLayout`         | strict    |                                                           |
| 23  | Vim          | `9.1.0400`   | `VimLayout`            | strict    | `printWidth: 4` on patch                                  |
| 24  | Dlang (DMD)  | `2.079.0`    | `DmdLayout`            | strict    | `printWidth: 3` on minor (per SPEC §7.2)                  |
| 25  | macOS        | `14.5.1`     | `SemVerLayout`         | strict    | consumer-facing version, not the internal build (`23F79`) |

## 3. New layouts introduced by this module

All three share the SemVer bitfield shape — `stableFlag:1, patch:24,
minor:24, major:15` — and the engine's `opCmp` / `toString` /
`truncateTo`. They differ only in static `@Component.printWidth`.

All three presets re-use `semVerPrereleaseSlot` and `semVerBuildSlot`
from `sparkles.versions.semver_rules` — they happen to follow SemVer's
prerelease/build conventions, so the same SlotValidator and
SlotComparator function pointers apply.

### 3.1 `CalVerYYMMLayout`

```d
struct CalVerYYMMLayout
{
    mixin layoutBody!(
        InternalFlag,                            bool,  "stableFlag", 1,
        Component(printOrder: 2),                ulong, "patch",     24,
        Component(printOrder: 1, printWidth: 2), ulong, "minor",     24,
        Component(printOrder: 0),                ulong, "major",     15,
    );

    static immutable StringSlot[] stringSlots = [
        semVerPrereleaseSlot,
        semVerBuildSlot,
    ];
}
```

Validates with Ubuntu `24.04.1` (year=24, month=04, patch=1). Year
fits well within 15 bits; the layout works through year 32767 if
ever reused.

### 3.2 `CalVerYYYYMMDDLayout`

Same shape as 3.1 but with `printWidth: 2` on both minor and patch:

```d
mixin layoutBody!(
    InternalFlag,                            bool,  "stableFlag", 1,
    Component(printOrder: 2, printWidth: 2), ulong, "patch",     24,
    Component(printOrder: 1, printWidth: 2), ulong, "minor",     24,
    Component(printOrder: 0),                ulong, "major",     15,
);
```

Validates with Arch Linux `2024.05.01`. Year ≤ 32767 covers
calendar use until year 32767.

### 3.3 `VimLayout`

Same shape but with `printWidth: 4` on patch:

```d
mixin layoutBody!(
    InternalFlag,                            bool,  "stableFlag", 1,
    Component(printOrder: 2, printWidth: 4), ulong, "patch",     24,
    Component(printOrder: 1),                ulong, "minor",     24,
    Component(printOrder: 0),                ulong, "major",     15,
);
```

Validates with Vim `9.1.0400`. Patch fits well within 24 bits (max
16,777,215) — Vim's running patch counter is currently in the
hundreds, with millennia of headroom.

## 4. Existing layouts re-used by presets

- **`SemVerLayout`** — strict SemVer 2.0.0. Covers 19 part-1
  entries directly (entries 1–5, 10, 12–22, 25) plus PostgreSQL
  (entry 11) via `ParseMode.loose` for the missing patch.
- **`DmdLayout`** (with `printWidth: 3` on minor per SPEC §7.2) —
  covers Dlang `2.079.0` (entry 24). The same layout handles
  contemporary DMD versions like `2.111.0` without padding.

## 5. Deferred from this module

### 5.1 Bucket F — pseudo-SemVer with hyphenless prerelease

Catalogued entries 6 (Go) and 7 (Python) both feature alphanumeric
prerelease segments without the SemVer `-` separator. Both
catalogued example strings are **wrong-format** as written, per
provenance check (§6); the corrected forms are:

| #   | Product        | Catalogued (wrong) | Real-world form           |
| --- | -------------- | ------------------ | ------------------------- |
| 6   | Go             | `1.22.3rc1`        | `go1.22rc1` or `go1.22.3` |
| 7   | Python         | `3.12.3a1`         | `3.13.0a1`                |
| 35  | OpenSSL legacy | `1.1.1w`           | `1.1.1w` (real)           |
| 36  | OpenSSH        | `9.7p1`            | `9.7p1` (real)            |
| 37  | Unity          | `2023.2.1f1`       | `2023.2.1f1` (real)       |

Supporting these requires the parser to invoke a layout-supplied
custom tokeniser at the numeric→alphanumeric boundary (a per-layout
`parse` hook, already a documented engine extension point — see
SPEC §8 item 6). The implementation is its own design problem and
will land as a follow-up milestone using the corrected example
strings above for tests.

### 5.2 Part 2 — capabilities beyond the 64-bit fast path

The 25 entries in [§8.2](#82-part-2--deferred-schemes)
require one or more of:

- **128-bit core (`Cent`)** for 4-part versions: Windows
  `10.0.19045.3324`, Chrome `125.0.6422.60`, .NET Assemblies
  `8.0.0.0`, MS Office `16.0.14326.20404`, Visual Studio
  `17.8.34309.116`. (RATIONALE §4.2 dropped `Cent` from the first
  release.)
- **Non-power-of-two layout sizes**: Eclipse IDE `2024-03`
  (2 components), Maya `2025` (1 component). (RATIONALE §4.5
  restricts layouts to 1/2/4/8 bytes.)
- **Pure-alphanumeric fallback** — versions that bypass the
  bit-packed core entirely: iOS `21F79`, macOS internal `23F79`,
  Android `UP1A.231005.007`.
- **Epoch / dist-tag prefixes**: Debian `1:1.2.3-4+deb12u1`,
  RPM `1.0-1.el9.x86_64`. Would need a new UDA for an epoch
  component above major.
- **Prefix stripping**: JetBrains `IU-241.14494.240`, X11
  `X11R6.8.2`.

Each is a structural decision tracked in
[RATIONALE §5](./RATIONALE.md#5-open-questions). The
catalogue is retained for reference and as the test corpus for any
future milestone that admits these schemes.

Two part-2 entries are themselves wrong-format as catalogued:

- Entry 29 Java `21.0.1.2` — modern Java uses 3-part + build
  (`21.0.1+12`).
- Entry 50 Safari `17.4.1.1` — ships as `17.4.1` (optionally with
  a WebKit suffix `(19618.x.x.x)`).

Two more are _plausible but not exact_:

- Entry 27 Visual Studio `17.8.34309.116` — format matches the
  scheme but the exact build number was not confirmed against a
  primary source.
- Entry 48 OpenZFS `2.2.3-1` — the upstream git tag is
  `zfs-2.2.3`; the `-1` is distro-packaging suffix.

## 6. Provenance

Every catalogued example was fact-checked against an authoritative
source (project releases / git tags / official changelogs / OCI
registries) before being baked into this catalogue. The verdict
table for all 50 entries in the source-material catalogue (§8):

| #   | Product            | Claimed example     | Verdict            | Authoritative example (if different) | Source                                                                      |
| --- | ------------------ | ------------------- | ------------------ | ------------------------------------ | --------------------------------------------------------------------------- |
| 1   | Node.js            | `20.13.1`           | confirmed          |                                      | github.com/nodejs/node releases                                             |
| 2   | Rust               | `1.78.0`            | confirmed          |                                      | blog.rust-lang.org 2024-05-02                                               |
| 3   | Kubernetes         | `1.30.0`            | confirmed          |                                      | github.com/kubernetes/kubernetes                                            |
| 4   | Angular            | `17.3.0`            | confirmed          |                                      | github.com/angular/angular releases                                         |
| 5   | React              | `18.3.1`            | confirmed          |                                      | github.com/facebook/react releases                                          |
| 6   | Go                 | `1.22.3rc1`         | wrong-format       | `go1.22rc1` or `go1.22.3`            | go.dev/dl                                                                   |
| 7   | Python             | `3.12.3a1`          | wrong-format       | `3.13.0a1`                           | python.org/downloads                                                        |
| 8   | Ubuntu             | `24.04.1`           | confirmed          |                                      | ubuntu.com 24.04.1 LTS Aug 2024                                             |
| 9   | Arch Linux         | `2024.05.01`        | confirmed          |                                      | archlinux.org/releng/releases                                               |
| 10  | Linux Kernel       | `6.8.9`             | confirmed          |                                      | kernel.org                                                                  |
| 11  | PostgreSQL         | `16.3`              | confirmed          |                                      | postgresql.org release notes                                                |
| 12  | Docker             | `26.1.1`            | confirmed          |                                      | github.com/moby/moby releases                                               |
| 13  | Git                | `2.45.1`            | confirmed          |                                      | github.com/git/git tags                                                     |
| 14  | PHP                | `8.3.7`             | confirmed          |                                      | php.net/downloads                                                           |
| 15  | Ruby               | `3.3.1`             | confirmed          |                                      | ruby-lang.org news                                                          |
| 16  | Nginx              | `1.26.0`            | confirmed          |                                      | nginx.org/en/CHANGES                                                        |
| 17  | Apache HTTP        | `2.4.59`            | confirmed          |                                      | httpd.apache.org                                                            |
| 18  | Redis              | `7.2.4`             | confirmed          |                                      | github.com/redis/redis releases                                             |
| 19  | MongoDB            | `7.0.8`             | confirmed          |                                      | github.com/mongodb/mongo                                                    |
| 20  | SQLite             | `3.45.3`            | confirmed          |                                      | sqlite.org/changes.html                                                     |
| 21  | cURL               | `8.7.1`             | confirmed          |                                      | curl.se/changes.html                                                        |
| 22  | FFmpeg             | `7.0.1`             | confirmed          |                                      | ffmpeg.org/download                                                         |
| 23  | Vim                | `9.1.0400`          | confirmed          |                                      | github.com/vim/vim (patch 9.1.0400, GUI test CI fix)                        |
| 24  | Dlang (DMD)        | `2.079.0`           | confirmed          |                                      | dlang.org/changelog/2.079.0                                                 |
| 25  | macOS              | `14.5.1`            | confirmed          |                                      | support.apple.com                                                           |
| 26  | Windows            | `10.0.19045.3324`   | confirmed          |                                      | KB5029244, Aug 2023                                                         |
| 27  | Visual Studio      | `17.8.34309.116`    | plausible          |                                      | learn.microsoft.com VS2022 history                                          |
| 28  | Google Chrome      | `125.0.6422.60`     | confirmed          |                                      | chromereleases.google                                                       |
| 29  | Java (Modern)      | `21.0.1.2`          | wrong-format       | `21.0.1+12` (3-part + build)         | openjdk.org/projects/jdk/21                                                 |
| 30  | Microsoft Office   | `16.0.14326.20404`  | confirmed          |                                      | learn.microsoft.com officeupdates (v2108)                                   |
| 31  | .NET Assemblies    | `8.0.0.0`           | confirmed          |                                      | learn.microsoft.com .NET 8                                                  |
| 32  | MuseScore          | `4.2.1-240230937`   | confirmed          |                                      | github.com/musescore/MuseScore releases                                     |
| 33  | TeX                | `3.14159265`        | confirmed          |                                      | tug.org (Knuth π-convergent)                                                |
| 34  | Metafont           | `2.7182818`         | confirmed          |                                      | tug.org (Knuth e-convergent)                                                |
| 35  | OpenSSL            | `1.1.1w`            | confirmed          |                                      | openssl.org/news Sep 2023                                                   |
| 36  | OpenSSH            | `9.7p1`             | confirmed          |                                      | openssh.com/releasenotes                                                    |
| 37  | Unity              | `2023.2.1f1`        | confirmed          |                                      | unity.com/releases/editor/whats-new/2023.2.1f1                              |
| 38  | Perl (Legacy)      | `5.004_05`          | confirmed          |                                      | metacpan.org perl history                                                   |
| 39  | Debian Packages    | `1:1.2.3-4+deb12u1` | confirmed (format) |                                      | Debian Policy 5.6.12                                                        |
| 40  | RPM Packages       | `1.0-1.el9.x86_64`  | confirmed (format) |                                      | Fedora packaging guidelines                                                 |
| 41  | Unreal Engine      | `5.3.2-27405482`    | confirmed          |                                      | issues.unrealengine.com (`UE5-Release-5.3-CL-27405482`)                     |
| 42  | Eclipse IDE        | `2024-03`           | confirmed          |                                      | eclipse.org/downloads/packages                                              |
| 43  | JetBrains IntelliJ | `IU-241.14494.240`  | confirmed          |                                      | intellij-support.jetbrains.com (`2024.1`, Mar 28 2024)                      |
| 44  | X11                | `X11R6.8.2`         | confirmed          |                                      | x.org/releases (Feb 2005)                                                   |
| 45  | Apple iOS Builds   | `21F79`             | confirmed          |                                      | developer.apple.com/news/releases (iOS 17.5)                                |
| 46  | macOS Builds       | `23F79`             | confirmed          |                                      | ipsw.dev/build/23F79 (macOS 14.5)                                           |
| 47  | Android Builds     | `UP1A.231005.007`   | confirmed          |                                      | source.android.com (`android-14.0.0_r1`)                                    |
| 48  | OpenZFS            | `2.2.3-1`           | plausible          |                                      | github.com/openzfs/zfs/releases/tag/zfs-2.2.3 (upstream tag is `zfs-2.2.3`) |
| 49  | AutoDesk Maya      | `2025`              | confirmed          |                                      | autodesk.com/products/maya                                                  |
| 50  | Safari             | `17.4.1.1`          | wrong-format       | `17.4.1`                             | support.apple.com/en-us/120888                                              |

In summary: 23/25 part-1 entries are exact confirmations; 23/25
part-2 entries are exact or format-confirmations. Four part-2
entries (#27, #29, #48, #50) are _plausible_ or _wrong-format_;
they affect deferred work only.

## 7. Adding a new preset

To add a layout for a new versioning scheme:

1. Define the `Layout` struct in
   `libs/versions/src/sparkles/versions/presets.d` per SPEC §3
   (bitfields, `@Component` UDAs, optional `@InternalFlag`,
   optional string slots).
2. Public-import it from the module.
3. Add a `@("presets.<LayoutName>.<scenario>") @safe pure nothrow
@nogc unittest` block parsing the real-world example string and
   asserting `parsed.toString` either round-trips verbatim or
   emits a documented normalised form.
4. Update §2 (coverage table) and §6 (provenance) of this document
   with the new entry and an authoritative source link.

## 8. Source-material appendix

The raw analyst catalogue, inlined verbatim. The notes column is
the analyst's commentary about what each entry would exercise in
the DbI engine — it predates several design decisions (e.g.
references to `@WidthTracker` and `SEMANTIC_MASK`, both of which we
dropped per [RATIONALE §4.1](./RATIONALE.md#41-static-componentprintwidth-instead-of-runtime-width-tracker-bits)).
Treat the notes as historical context, not as current engine
vocabulary; the canonical mapping is §2 above and the verdicts in
§6.

### 8.1 Part 1 — 64-bit fast-path compatible

<!-- prettier-ignore-start -->

| #   | Product            | Scheme Type            | Example         | Analyst notes                                                                                            |
| --- | ------------------ | ---------------------- | --------------- | -------------------------------------------------------------------------------------------------------- |
| 1   | Node.js            | Strict SemVer          | `20.13.1`       | Baseline: validates standard 15/24/24 bitpacking and strict equality.                                    |
| 2   | Rust               | Strict SemVer          | `1.78.0`        | Baseline: validates standard 3-part layout.                                                              |
| 3   | Kubernetes         | Strict SemVer          | `1.30.0`        | Baseline: validates standard 3-part layout.                                                              |
| 4   | Angular            | Strict SemVer          | `17.3.0`        | Baseline: validates standard 3-part layout.                                                              |
| 5   | React              | Strict SemVer          | `18.3.1`        | Baseline: validates standard 3-part layout.                                                              |
| 6   | Go                 | Pseudo-SemVer          | `1.22.3rc1`     | Parser test: lacks standard hyphen. Parser must detect `rc1`, push to string slot, set stable bit.       |
| 7   | Python             | PEP 440                | `3.12.3a1`      | Parser test: lacks standard hyphen. Parser must split `a1` into the string slot.                         |
| 8   | Ubuntu             | CalVer (YY.MM.Patch)   | `24.04.1`       | Width test: validates `@Component(printWidth: 2)` on minor to preserve the `04`.                         |
| 9   | Arch Linux         | CalVer (YYYY.MM.DD)    | `2024.05.01`    | Width test: 2024 fits 15-bit major; preserves leading zeroes on minor and patch.                         |
| 10  | Linux Kernel       | Strict 3-Part          | `6.8.9`         | Baseline: validates standard layout.                                                                     |
| 11  | PostgreSQL         | 2-Part                 | `16.3`          | Truncation test: parser implicitly sets patch = 0 in loose mode. Validates `truncateTo!"minor"`.         |
| 12  | Docker             | CalVer (YY.MM.Patch)   | `26.1.1`        | Baseline: validates standard layout (minor not zero-padded in this example).                             |
| 13  | Git                | Strict 3-Part          | `2.45.1`        | Baseline: validates standard layout.                                                                     |
| 14  | PHP                | Strict 3-Part          | `8.3.7`         | Baseline: validates standard layout.                                                                     |
| 15  | Ruby               | Strict 3-Part          | `3.3.1`         | Baseline: validates standard layout.                                                                     |
| 16  | Nginx              | Even/Odd Minor         | `1.26.0`        | Baseline: validates standard layout. (Stable/dev distinguished by minor parity — policy, not format.)    |
| 17  | Apache HTTP        | Strict 3-Part          | `2.4.59`        | Baseline: validates standard layout.                                                                     |
| 18  | Redis              | Strict SemVer          | `7.2.4`         | Baseline: validates standard layout.                                                                     |
| 19  | MongoDB            | Strict 3-Part          | `7.0.8`         | Baseline: validates standard layout.                                                                     |
| 20  | SQLite             | Strict 3-Part          | `3.45.3`        | Baseline: validates standard layout.                                                                     |
| 21  | cURL               | Strict 3-Part          | `8.7.1`         | Baseline: validates standard layout.                                                                     |
| 22  | FFmpeg             | Strict 3-Part          | `7.0.1`         | Baseline: validates standard layout.                                                                     |
| 23  | Vim                | 3-Part Zero-Padded     | `9.1.0400`      | Width test: validates 4-digit zero-padded patch via `@Component(printWidth: 4)`.                         |
| 24  | Dlang (DMD)        | Zero-Padded Minor      | `2.079.0`       | Width test: 3-digit zero-padded minor via `@Component(printWidth: 3)`. `2.079.0` and `2.111.0` coexist.  |
| 25  | macOS              | Strict 3-Part          | `14.5.1`        | Baseline: validates standard layout (consumer-facing version).                                           |

<!-- prettier-ignore-end -->

### 8.2 Part 2 — deferred schemes

These 25 schemes require engine capabilities not currently shipped
(see [§5.2](#52-part-2--capabilities-beyond-the-64-bit-fast-path)).
Retained for reference and as the future test corpus.

<!-- prettier-ignore-start -->

| #   | Product            | Scheme Type            | Example                    | Analyst notes                                                                                              |
| --- | ------------------ | ---------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 26  | Windows            | 4-Part Heavyweight     | `10.0.19045.3324`          | 128-bit test: requires `Cent` layout. Validates `core.int128.ult` / `ugt` intrinsic comparisons.           |
| 27  | Visual Studio      | 4-Part Heavyweight     | `17.8.34309.116`           | 128-bit test: requires `Cent`. Validates parsing 4 distinct integers.                                      |
| 28  | Google Chrome      | 4-Part Heavyweight     | `125.0.6422.60`            | 128-bit test: requires `Cent`.                                                                             |
| 29  | Java (Modern)      | 4-Part Semantic        | `21.0.1.2`                 | 128-bit test: requires `Cent`. Maps to Feature.Interim.Update.Patch. (Actual modern form: `21.0.1+12`.)    |
| 30  | Microsoft Office   | 4-Part Heavyweight     | `16.0.14326.20404`         | 128-bit test: requires `Cent`.                                                                             |
| 31  | .NET Assemblies    | 4-Part Heavyweight     | `8.0.0.0`                  | 128-bit test: requires `Cent`. Maps to Major.Minor.Build.Revision.                                         |
| 32  | MuseScore          | Massive Build Int      | `4.2.1-240230937`          | Bit-width test: the build number exceeds a 24-bit limit. Requires allocating 32 bits to the 4th component. |
| 33  | TeX                | Infinite Precision     | `3.14159265`               | Bit-width test: minor component exceeds 20 bits. Requires bumping the minor bitfield to `uint:32` in Cent. |
| 34  | Metafont           | Infinite Precision     | `2.7182818`                | Bit-width test: same as TeX. Validates massive single-component bitfields.                                 |
| 35  | OpenSSL (Legacy)   | Alphanumeric Patch     | `1.1.1w`                   | String-slot parser test: fails integer parsing. Parser must strip `w`, push to slot, set stable flag.      |
| 36  | OpenSSH            | Portable Suffix        | `9.7p1`                    | String-slot parser test: `p1` acts as a pre-release without a hyphen. Validates parser fallback.           |
| 37  | Unity              | Alphanumeric Glue      | `2023.2.1f1`               | String-slot parser test: `f1` denotes a final release. Validates custom string-splitting before bitpack.   |
| 38  | Perl (Legacy)      | Underscore Delimit     | `5.004_05`                 | Delimiter test: validates parser capability to accept `_` as a valid component boundary.                   |
| 39  | Debian Packages    | Epoch Prefix           | `1:1.2.3-4+deb12u1`        | Epoch test: requires a 4th leading bitfield for epoch. Validates 128-bit layout where epoch is MSB.        |
| 40  | RPM Packages       | Dist Tags              | `1.0-1.el9.x86_64`         | SSO capacity test: validates dual 24-byte string slots holding `el9.x86_64` inline.                        |
| 41  | Unreal Engine      | Internal 5-Part        | `5.3.2-27405482`           | 128-bit test: 4-part layout where the 4th component is a massive build integer.                            |
| 42  | Eclipse IDE        | Date Only              | `2024-03`                  | Layout override test: requires a 2-component layout (Major.Minor). Engine must not mandate Patch.          |
| 43  | JetBrains IntelliJ | Prefix Alphanumeric    | `IU-241.14494.240`         | Prefix-stripping test: parser discards non-semantic `IU-` before passing to the DbI engine.                |
| 44  | X11                | Prefix Alphanumeric    | `X11R6.8.2`                | Prefix-stripping test: parser must strip `X11R` before processing standard integers.                       |
| 45  | Apple iOS Builds   | Pure Alphanumeric      | `21F79`                    | Non-numeric test: fails standard DbI. Validates bypass of bit-packed core; entirely string-stored.         |
| 46  | macOS Builds       | Pure Alphanumeric      | `23F79`                    | Non-numeric test: fails standard DbI. Falls back to string-only storage.                                   |
| 47  | Android Builds     | Pure Alphanumeric      | `UP1A.231005.007`          | Non-numeric test: fails standard DbI. Falls back to string-only storage.                                   |
| 48  | OpenZFS            | Release Suffix         | `2.2.3-1`                  | Ambiguity test: looks like a SemVer prerelease but is a stable release iteration. Needs custom UDA.        |
| 49  | AutoDesk Maya      | Year Only              | `2025`                     | Layout override test: requires a 1-component layout (Major). Engine scales down to `ubyte` or `ushort`.    |
| 50  | Safari             | 4-Part Mac Schema      | `17.4.1.1`                 | 128-bit test: requires `Cent`. Validates Apple's occasional 4th-component security updates.                |

<!-- prettier-ignore-end -->
