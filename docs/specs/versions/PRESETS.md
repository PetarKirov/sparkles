# `sparkles:versions` — Scheme Catalogue and Provenance

_Audience: contributors using or extending the shipped version schemes.
This document is the per-scheme catalogue: it records each scheme's
declared capabilities, real-world example strings, ordering rules and
edge cases, native-range grammar, and the authoritative source every
example was checked against. For the desired-state specification of the
traits and generic algorithms, see [SPEC.md](./SPEC.md); for delivery
order, see [PLAN.md](./PLAN.md); for design history and prior-art
justification, see [RATIONALE.md](./RATIONALE.md)._

## 1. Overview

This catalogue documents each shipped scheme: its purl `type`,
real-world example strings, ordering rules and edge cases, native-range
grammar, the capabilities it declares, and the authoritative source
every example was checked against. For the concepts these schemes
conform to ([`isVersion!T`](./SPEC.md#3-the-version-concept),
[`isVersionScheme!S`](./SPEC.md#6-the-scheme-concept)) and the capability
traits, see [SPEC.md](./SPEC.md).

```d
import sparkles.versions.schemes.semver : SemVer;
import sparkles.versions.schemes.pypi   : PypiVersion;
import sparkles.versions.schemes.deb    : DebianVersion;

auto rust   = SemVer      .parse("1.78.0").value;
auto python = PypiVersion .parse("3.13.0a1").value;
auto apt    = DebianVersion.parse("2:4.13.1-0ubuntu0.16.04.1.1~").value;
```

Eleven schemes ship: `semver` is the SemVer 2.0.0 reference (it also
drives most package managers at the value level); six are D-internal
compact encodings; three (`pypi`, `maven`, `deb`) are _structural_ —
their ordering cannot be reduced to an integer key; and `generic` is the
opaque baseline.

## 2. Capabilities

The at-a-glance capability matrix — which scheme provides `hasOrderKey`,
`supportsPrerelease`, `hasComponents`, `hasBuildMetadata`,
`supportsNativeRange`, and `supportsLooseParse` — is in
[SPEC §8](./SPEC.md#8-shipped-schemes); the trait semantics are in
[SPEC §3.2](./SPEC.md#32-optional-capability-vocabulary) and
[§6.2](./SPEC.md#62-optional-scheme-capabilities). This catalogue records
the per-scheme detail behind each cell (§3) — in particular, why the
three structural schemes (`pypi`, `maven`, `deb`) omit `orderKey`, and
why the calendar schemes have `hasComponents` but not the
caret/tilde-enabling `hasSemVerComponents`.

## 3. Per-scheme catalogue

Each subsection records: the purl `type` string, real-world example
strings, ordering rules and edge cases, the declared capabilities (and,
for structural schemes, _why_ `orderKey` is omitted), parse modes, the
native-range grammar where applicable, and provenance.

### 3.1 `semver` — `SemVer` (Semantic Versioning 2.0.0)

- **purl type:** `semver`. The same value grammar drives `npm`,
  `cargo`, `gem`, `composer`, `golang`, `hex`, `conan`, `nginx`,
  `mozilla`, and `github` — those purl types map to this scheme via the
  [purl→scheme table](./SPEC.md#10-purl-interop) while keeping their
  own native-range dialects.
- **Examples:** `20.13.1` (Node.js), `1.78.0` (Rust), `1.30.0`
  (Kubernetes), `17.3.0` (Angular), `18.3.1` (React), `6.8.9` (Linux),
  `2.45.1` (Git), `8.3.7` (PHP), `3.3.1` (Ruby), `1.26.0` (Nginx),
  `2.4.59` (Apache httpd), `7.2.4` (Redis), `7.0.8` (MongoDB), `3.45.3`
  (SQLite), `8.7.1` (cURL), `7.0.1` (FFmpeg), `14.5.1` (macOS), `26.1.1`
  (Docker). With prerelease/build: `1.0.0-rc.1`, `1.0.0-alpha.1+build.5`.
- **Ordering (SemVer §11):** compare `major`, then `minor`, then
  `patch` numerically; a version _with_ a prerelease has **lower**
  precedence than the same `major.minor.patch` without one
  (`1.0.0-alpha < 1.0.0`); prerelease identifiers compare per SemVer
  §11.4 (numeric identifiers numerically, alphanumeric lexically,
  numeric < alphanumeric, more fields wins on a shared prefix); build
  metadata (`+…`) is **ignored** in ordering (SemVer §10).
- **Edge cases:** `major` dominates everything —
  `2.0.0-alpha > 1.999.999`. Leading zeroes in numeric identifiers are
  rejected in strict mode.
- **Capabilities:** `orderKey` yes — the
  `major:minor:patch:has-no-prerelease` shape packs into a `ulong`
  with the stable-flag at the LSB, so unsigned compare reproduces SemVer
  precedence up to the prerelease-identifier tiebreak (equal keys fall
  through to the full `opCmp`). `prerelease` yes, `components` yes,
  `build` yes. `nativeRange` yes (node-semver grammar). `loose` yes.
- **Parse modes:** _strict_ follows SemVer 2.0.0 exactly. _loose_
  additionally accepts a leading `v` (`v1.2.3`) and partial versions
  (`1`, `1.2`), infilling missing components with `0` — this is how
  PostgreSQL `16.3` round-trips.
- **Native range grammar (node-semver subset):** caret `^1.2.0`, tilde
  `~1.2.0`, wildcard `1.2.x` / `1.*`, hyphen `1.2.0 - 1.5.0`, union
  `||`, AND-by-space `>=1.2.0 <2.0.0`, plain comparators
  `>` `>=` `<` `<=` `=`. Prerelease-in-range follows the node-semver
  rule (a prerelease satisfies a comparator only when some comparator in
  the same set names a prerelease of the same `major.minor.patch`).
- **Provenance:** [semver.org 2.0.0](https://semver.org/spec/v2.0.0.html);
  node-semver grammar at
  [github.com/npm/node-semver](https://github.com/npm/node-semver).
  Example strings checked against upstream releases
  (nodejs/node, rust-lang, kubernetes, git, php, etc.).

### 3.2 `dmd` — `Dmd` (D compiler internal)

- **purl type:** none (D-internal; not published to a package registry).
- **Examples:** `2.111.0`, `2.079.0`. The minor field is printed
  zero-padded to **3 digits** (`079`), while values ≥ 100 print at their
  natural width (`111`).
- **Ordering:** standard 3-component numeric compare with SemVer-style
  prerelease tiebreak; the zero-padding is a _formatting_ property only
  and does not affect ordering (`2.079.0` and a hypothetical `2.79.0`
  would compare equal numerically — but the parser only admits the
  3-digit form).
- **Capabilities:** `orderKey` yes, `prerelease` yes, `components` yes.
  `build` **no** (DMD releases carry no build metadata). `nativeRange`
  yes — SemVer-shaped, so it inherits the SemVer/npm range grammar.
  `loose` yes.
- **Parse modes:** _strict_ requires the 3-digit minor; _loose_ relaxes
  the leading-`v` and partial-version rules as for `semver`.
- **Provenance:** [dlang.org/changelog](https://dlang.org/changelog/)
  (`2.079.0` and `2.111.0` release notes).

### 3.3 `dmd_compact` — `DmdCompact` (4-byte bitfield encoding)

- **purl type:** none (D-internal compact storage).
- **Examples:** `2.111.0`, `2.111.0-beta.2`, `2.111.0-rc.3`.
- **Encoding:** a 4-byte packed integer. The prerelease is encoded as a
  2-bit _phase_ (`beta` < `rc` < stable) plus a small number, exploiting
  the fact that DMD prereleases follow the constrained grammar `beta.N`
  / `rc.N`. Because the `(phase, num)` pair sits just below the stable
  marker in the packed integer, a single unsigned compare yields
  `2.111.0-beta.N < 2.111.0-rc.M < 2.111.0`.
- **Ordering:** entirely via the packed integer; the phase encoding is
  monotone by construction.
- **Capabilities:** `orderKey` yes — the 4-byte packed integer _is_ the
  order key, so `OrderKeyType!DmdCompact` is `uint`. `prerelease` yes,
  `components` yes. `build` **no**. `nativeRange` yes (SemVer-shaped).
  `loose` **no** — the compact encoding admits only the exact canonical
  forms it can represent, so there is no lenient parse.
- **Edge cases:** the reserved 4th phase code is rejected by the parser;
  prerelease numbers beyond the encodable range are a parse error rather
  than a silent truncation.
- **Provenance:** DMD prerelease tags on
  [github.com/dlang/dmd/releases](https://github.com/dlang/dmd/releases)
  (`v2.111.0-beta.1`, `v2.111.0-rc.1`, …).

### 3.4 `tiny` — `Tiny` (4-byte, no prerelease)

- **purl type:** none (internal storage-sensitive use).
- **Examples:** `7.8.9`.
- **Ordering:** three numeric components packed into 4 bytes; plain
  unsigned compare.
- **Capabilities:** `orderKey` yes — the three components pack into 4
  bytes, so `OrderKeyType!Tiny` is `uint`. `components` yes. `prerelease`
  **no**, `build` **no**. `nativeRange` yes (SemVer-shaped grammar over
  the three components). `loose` yes (partial versions infill with `0`).
- **Provenance:** internal; no external ecosystem. The example exercises
  the no-prerelease, no-build packed path.

### 3.5 `calver_yymm` — `CalVerYYMM` (Ubuntu-style CalVer)

- **purl type:** none (calendar scheme; Ubuntu does not publish a purl
  type for the distro version itself).
- **Examples:** `24.04.1` (Ubuntu 24.04.1 LTS). The month is printed
  zero-padded to **2 digits** (`04`).
- **Ordering:** numeric compare on `(year, month, patch)` — chronological
  because the fields are most-significant-first.
- **Capabilities:** `orderKey` yes. `components` yes — declared honestly
  as `["year","month","patch"]`, so `hasComponents` holds (it gets
  generic compare and `truncateTo!"month"`) but `hasSemVerComponents` does
  **not** (a calendar version has no caret/tilde). `prerelease` **no**,
  `build` **no**. `nativeRange` yes. `loose` yes.
- **Edge cases:** the 2-digit month is a formatting width, not a range
  constraint — `24.4.1` is not accepted in strict mode because the
  canonical form pads the month.
- **Provenance:** [ubuntu.com](https://ubuntu.com/) point-release
  announcements (24.04.1 LTS, August 2024).

### 3.6 `calver_yyyymmdd` — `CalVerYYYYMMDD` (Arch-style CalVer)

- **purl type:** none (calendar scheme).
- **Examples:** `2024.05.01` (Arch Linux monthly ISO). Both month and
  day print zero-padded to **2 digits**.
- **Ordering:** numeric compare on `(year, month, day)`.
- **Capabilities:** `orderKey` yes. `components` yes — declared as
  `["year","month","day"]`; `hasComponents` holds, `hasSemVerComponents`
  does **not** (no caret/tilde for a date version). `prerelease` **no**,
  `build` **no**. `nativeRange` yes. `loose` yes.
- **Provenance:**
  [archlinux.org/releng/releases](https://archlinux.org/releng/releases/)
  (monthly ISO snapshots).

### 3.7 `vim` — `VimVer` (4-digit zero-padded patch)

- **purl type:** none (Vim's patch scheme is project-specific).
- **Examples:** `9.1.0400` (Vim patch 9.1.0400). The patch field prints
  zero-padded to **4 digits**.
- **Ordering:** numeric compare on `(major, minor, patch)`.
- **Capabilities:** `orderKey` yes, `components` yes. `prerelease`
  **no**, `build` **no**. `nativeRange` yes. `loose` yes.
- **Edge cases:** the 4-digit patch is a formatting width; Vim's running
  patch counter has millennia of headroom in the packed field.
- **Provenance:** [github.com/vim/vim](https://github.com/vim/vim)
  release tags (patch `9.1.0400`).

### 3.8 `pypi` — `PypiVersion` (PEP 440) — structural, no `orderKey`

- **purl type:** `pypi`.
- **Examples:** `3.13.0a1` (alpha), `1.0.0.post1` (post-release),
  `2.0.0.dev1` (dev-release), `1.0.0+local` (local version label),
  `1!2.0.0` (explicit epoch 1).
- **Ordering (PEP 440):** compare lexicographically by **structured
  segments** in this order: `epoch`, the `release` tuple (numeric,
  zero-padded to equal length), then the pre/post/dev ranking, then the
  local version. Within a release, the segment classes sort:

  ```
  1.dev0 < 1.0.dev456 < 1.0a1 < 1.0a2.dev456 < 1.0a12 < 1.0b1
        < 1.0b2 < 1.0rc1 < 1.0 < 1.0.post456 < 1.0.15 < 1.1.dev1
  ```

  Key facts: a **dev** release sorts _before_ a pre-release of the same
  version; a **post** release sorts _after_ the final release; a
  **local** version (`+local`) sorts _after_ the same public version,
  and a numeric local segment outranks a lexicographic one. An explicit
  **epoch** dominates everything (`1!1.0 > 1.0`).

- **Why `orderKey` is omitted:** the comparison is genuinely
  _structural_. The release tuple is unbounded in length, the
  pre/post/dev ranking is a small enum _crossed with_ an unbounded
  number, and the local version is an arbitrary dot-separated mix of
  numeric and lexicographic segments. There is no fixed-width integer
  whose unsigned compare reproduces this order, so `pypi` declares no
  `hasOrderKey` primitive and its `opCmp` walks the structure. Generic
  `sort` and `Ranges!PypiVersion` therefore use the comparison-based
  fallback path — exactly the contract the DbI design guarantees.
- **Capabilities:** `prerelease` yes (`isPrerelease` true for
  `aN`/`bN`/`rcN`/`.devN`), `components` yes (the `release` tuple
  exposes `major`/`minor`/`patch`). `build` **no** — the local version
  participates in ordering, so it is _not_ SemVer-style build metadata.
  `orderKey` **no**. `nativeRange` yes. `loose` yes (PEP 440
  normalisation: case-folding, `v`-prefix stripping, separator
  canonicalisation `1.0-a1` → `1.0a1`).
- **Native range grammar (PEP 440 specifier set):** comma-separated AND
  of clauses using `==`, `!=`, `<`, `<=`, `>`, `>=`, `~=` (compatible
  release), and `===` (arbitrary equality). `~=1.4.5` means
  `>=1.4.5, ==1.4.*`. Trailing `.*` wildcards are supported on `==`/`!=`.
- **Provenance:**
  [PEP 440 / packaging.python.org version specifiers](https://packaging.python.org/en/latest/specifications/version-specifiers/)
  (canonical ordering example verified verbatim). Example strings
  checked against [python.org/downloads](https://www.python.org/downloads/)
  (CPython `3.13.0a1`).

### 3.9 `maven` — `MavenVersion` (ComparableVersion) — structural, no `orderKey`

- **purl type:** `maven`.
- **Examples:** `1.0`, `1.0-SNAPSHOT`, `1.0-alpha-1`, `1.0-rc1`,
  `1.0-1`.
- **Ordering (Maven `ComparableVersion`):** the string is tokenised at
  `.`, `-`, `_`, and digit↔letter transitions; trailing "null" tokens
  (`0`, empty, `final`, `ga`, `release`) are trimmed so that
  `1.0.0 == 1`. Numeric tokens compare numerically; qualifier tokens
  compare by the fixed rank:

  ```
  alpha < beta < milestone < rc (= cr) < snapshot < ""(= ga = final = release) < sp
  ```

  Hence `1.0-alpha-1 < 1.0-beta-1 < 1.0-milestone-1 < 1.0-rc1 <
1.0-SNAPSHOT < 1.0 < 1.0-sp1`. Comparison is **case-insensitive**
  (`1.0-RC1 == 1.0-rc1`), and `alpha`/`beta`/`milestone` may be
  abbreviated `a`/`b`/`m` when directly followed by a number.

- **Why `orderKey` is omitted:** like PyPI, the order is structural —
  an unbounded alternation of numeric and qualifier tokens with the "ga
  beats snapshot beats pre-release" rule and trailing-null trimming. No
  fixed-width integer key reproduces it, so `maven` declares no
  `hasOrderKey` and `opCmp` compares token lists.
- **Capabilities:** `prerelease` yes (the qualifier rank below the
  empty/`ga` release). `components` **no** — `MavenVersion` declares no
  `components` list because its token model has no fixed ordered set of
  numeric fields (the token count and kinds vary per value), and the
  trait is all-or-nothing so a sometimes-available prefix does not
  qualify. `build` **no**, `orderKey` **no**. `nativeRange` yes
  (interval notation, below). `loose` **no** — `ComparableVersion`
  already accepts essentially anything, so there is no separate lenient
  mode.
- **Native range grammar (Maven version requirements):** bracket
  interval notation — `[1.0]` (exactly), `(,1.0]` (≤), `[1.2,1.3]`
  (closed), `[1.0,2.0)` (half-open), `[1.5,)` (≥), and unions via
  comma-separated intervals `(,1.0],[1.2,)`. Caveat preserved from the
  spec: because `2.0-rc1 < 2.0`, `[1.0,2.0)` _includes_ `2.0-rc1`.
- **Provenance:**
  [maven.apache.org POM version order specification](https://maven.apache.org/pom.html#version-order-specification)
  and the `maven-artifact` `ComparableVersion` test corpus.

### 3.10 `deb` — `DebianVersion` (dpkg) — structural, no `orderKey`

- **purl type:** `deb`.
- **Examples:** `1.2.3-4` (upstream `1.2.3`, Debian revision `4`),
  `2:4.13.1-0ubuntu0.16.04.1.1~` (epoch 2, upstream `4.13.1`, an Ubuntu
  security revision ending in `~`).
- **Structure:** `[epoch:]upstream_version[-debian_revision]`. The epoch
  is an optional unsigned integer (default `0`) compared first; then the
  upstream version; then the Debian revision.
- **Ordering (dpkg algorithm):** epoch numerically first; then upstream
  and revision are each compared left-to-right by alternating
  _non-digit_ and _digit_ runs. In a non-digit run, all letters sort
  before all non-letters, and the **tilde `~` sorts before everything —
  even the end of the string**, so `1.0~beta1 < 1.0` and
  `~~ < ~~a < ~ < "" < a`. In a digit run, leading zeroes are ignored
  and an empty run counts as `0`.
- **Why `orderKey` is omitted:** the dpkg algorithm is the canonical
  example of a _non-packable_ order — the `~`-before-empty rule alone
  defeats any fixed-width integer key (a shorter string can sort _after_
  a longer one that ends in `~`). `deb` declares no `hasOrderKey`; its
  `opCmp` implements the dpkg two-phase walk directly.
- **Capabilities:** `nativeRange` yes (dpkg relations). `prerelease`
  **no** (the `~` mechanism subsumes it but is not exposed as an
  `isPrerelease` boolean), `components` **no** (the upstream version is
  free-form, not a guaranteed triple), `build` **no**, `orderKey`
  **no**, `loose` **no** (dpkg parsing is already permissive; there is
  no stricter mode to relax from).
- **Native range grammar (dpkg relations):** the comparison relations
  `>=`, `<=`, `<<` (strictly less), `>>` (strictly greater), `=`, each
  followed by a version, as used in `dpkg --compare-versions` and
  `Depends:` fields (e.g. `>= 2.0`, `<< 3.0`).
- **Provenance:**
  [Debian Policy §5.6.12 (version)](https://www.debian.org/doc/debian-policy/ch-controlfields.html#version)
  and the `dpkg --compare-versions` algorithm (`~`-ordering example
  verified verbatim).

### 3.11 `generic` — `Generic` (void-hook baseline)

- **purl type:** `generic`.
- **Examples:** any opaque string — `"build-2024-05-30"`,
  `"r1234"`, `"snapshot-xyz"`.
- **Ordering:** plain lexicographic (code-point) comparison of the raw
  string. No structure is parsed.
- **Capabilities:** **none.** `orderKey` no, `prerelease` no,
  `components` no, `build` no, `nativeRange` no, `loose` no. This is the
  mandated [void-hook baseline](./SPEC.md#8-shipped-schemes):
  it provides only the required `isVersion!T` surface (`opCmp` +
  `toString`) and therefore exercises every generic algorithm's
  fallback path — comparison-based `sort`, comparison-based
  `Ranges!Generic`, and the "no native range, exact versions only"
  branch of the VERS/purl layers.
- **Parse:** `parse` always succeeds (any string is a valid `Generic`);
  there is no `parseLoose` or `parseNativeRange`.
- **Provenance:** none required — it is a structural baseline, not an
  ecosystem mapping.

## 4. Adding a new scheme

A scheme is just a struct conforming to
[`isVersionScheme!S`](./SPEC.md#6-the-scheme-concept).
To add one:

1. **Create the module** `schemes/<purl_type>.d` (named for the purl
   `type` where one exists, else a descriptive `snake_case` name) and
   write the required surface — `opCmp`, `opEquals`, `toHash`,
   `toString`, plus `purlType`, `alias Version`, and `static parse`. The
   exact signatures are in
   [SPEC §3.1](./SPEC.md#31-required-surface--isversiont) and
   [§6.1](./SPEC.md#61-required-surface--isversionschemes).

2. **Declare only the optional capabilities the ecosystem has** — any of
   `orderKey`, `components`, `isPrerelease`, `build`, `parseLoose`,
   `parseNativeRange` (semantics in
   [SPEC §3.2](./SPEC.md#32-optional-capability-vocabulary) /
   [§6.2](./SPEC.md#62-optional-scheme-capabilities)). Expose `orderKey`
   only when the order packs monotonically into an unsigned integer;
   structural schemes like `pypi`/`maven`/`deb` must not. Absence is
   never an error — the generic algorithms fall back.

3. **Assert conformance at module scope:**

   ```d
   static assert(isVersion!MyScheme && isVersionScheme!MyScheme);
   ```

   Any regression in the required surface becomes a compile-time
   failure.

4. **Register the scheme.** Public-import it from
   `schemes/package.d`, add it to the
   [`AnyVersion`/`AnyRange`](./SPEC.md#11-anyversion--anyrange)
   sum types, and — when the purl `type` differs from the scheme name —
   add the mapping to the
   [purl→scheme table](./SPEC.md#10-purl-interop).

5. **Add tests.** A round-trip test per real-world example
   (`parse(s).value.toString == s`, or the documented normalised form),
   an ascending-order test asserting the ordering edge cases, and — if
   the scheme declares `orderKey` — an equivalence test cross-checking
   `orderKey` against the `opCmp` reference. Add the new row to the
   capability matrix in [SPEC §8](./SPEC.md#8-shipped-schemes) and a §3
   per-scheme section here, citing the authoritative source.

## 5. Deferred schemes

These are catalogued for the test corpus but **not shipped**. The
corrected real-world example strings are recorded here so future
implementers do not copy the wrong forms (several appeared mangled in
the original analyst catalogue).

### 5.1 Bucket F — hyphenless pseudo-SemVer

Versions whose alphanumeric prerelease segment lacks the SemVer `-`
separator. Supporting them needs a per-scheme custom tokeniser at the
numeric→alphanumeric boundary, which is its own design problem.

| Ecosystem      | Wrong form (do not use) | Correct real-world form   | Note                                             |
| -------------- | ----------------------- | ------------------------- | ------------------------------------------------ |
| Go             | `1.22.3rc1`             | `go1.22rc1` or `go1.22.3` | `go` prefix; prerelease glued without a hyphen   |
| Python (alt)   | `3.12.3a1`              | `3.13.0a1`                | covered by `pypi`; listed here as the glued form |
| OpenSSL legacy | —                       | `1.1.1w`                  | single-letter patch suffix                       |
| OpenSSH        | —                       | `9.7p1`                   | `pN` portable suffix, no hyphen                  |
| Unity          | —                       | `2023.2.1f1`              | `fN` "final" glue suffix                         |

### 5.2 Part-2 heavyweight schemes

Schemes needing wider cores, 4+ components, or pure-alphanumeric
fallback. Tracked in
[RATIONALE — open questions](./RATIONALE.md#6-open-questions).

**Note — 4-component arity is no longer a design blocker.** With the
list-based [`components`](./SPEC.md#32-optional-capability-vocabulary)
capability, the 4-part schemes below (.NET, Windows, Chrome) are now
directly _expressible_ — each declares
`["major","minor","build","revision"]` and packs into a `ulong`
`orderKey`. They remain unshipped only on implementation bandwidth
(parser + native-range grammar per ecosystem), not on a missing
abstraction. Java's `21.0.1+12` and Android's pure-alphanumeric
`UP1A.231005.007` still need, respectively, build-metadata-aware parsing
and a no-numeric-core fallback.

| Ecosystem       | Correct real-world form | Note                                          |
| --------------- | ----------------------- | --------------------------------------------- |
| Java (modern)   | `21.0.1+12`             | 3-part + build; **not** the 4-part `21.0.1.2` |
| .NET assemblies | `8.0.0.0`               | 4-part `Major.Minor.Build.Revision`           |
| Windows         | `10.0.19045.3324`       | 4-part heavyweight                            |
| Google Chrome   | `125.0.6422.60`         | 4-part heavyweight                            |
| Android builds  | `UP1A.231005.007`       | pure-alphanumeric; bypasses any numeric core  |

## 6. Provenance appendix

Every example string baked into this catalogue was checked against an
authoritative source before inclusion. The structural-ordering rules
for the three non-packable schemes were verified verbatim against their
canonical specifications.

| Scheme                | What was verified                                 | Source                                                                                                                                                                |
| --------------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `semver`              | 2.0.0 grammar + §11 ordering; npm range grammar   | [semver.org/spec/v2.0.0](https://semver.org/spec/v2.0.0.html); [node-semver](https://github.com/npm/node-semver)                                                      |
| `dmd` / `dmd_compact` | `2.079.0`, `2.111.0`, beta/rc prerelease tags     | [dlang.org/changelog](https://dlang.org/changelog/); [dlang/dmd releases](https://github.com/dlang/dmd/releases)                                                      |
| `tiny`                | packed no-prerelease path                         | internal                                                                                                                                                              |
| `calver_yymm`         | Ubuntu `24.04.1` LTS point release                | [ubuntu.com](https://ubuntu.com/)                                                                                                                                     |
| `calver_yyyymmdd`     | Arch `2024.05.01` monthly ISO                     | [archlinux.org/releng/releases](https://archlinux.org/releng/releases/)                                                                                               |
| `vim`                 | patch `9.1.0400`                                  | [github.com/vim/vim](https://github.com/vim/vim)                                                                                                                      |
| `pypi`                | PEP 440 ordering example (verbatim); `3.13.0a1`   | [packaging.python.org version specifiers](https://packaging.python.org/en/latest/specifications/version-specifiers/); [python.org](https://www.python.org/downloads/) |
| `maven`               | qualifier order + interval notation (verbatim)    | [maven.apache.org POM version order](https://maven.apache.org/pom.html#version-order-specification)                                                                   |
| `deb`                 | dpkg `~`-ordering rule (verbatim); epoch/revision | [Debian Policy §5.6.12](https://www.debian.org/doc/debian-policy/ch-controlfields.html#version)                                                                       |
| `generic`             | structural baseline; no ecosystem                 | n/a                                                                                                                                                                   |

---

→ [SPEC.md](./SPEC.md) — desired-state specification (traits, `Ranges!V`, VERS, purl)
→ [PLAN.md](./PLAN.md) — delivery milestones
