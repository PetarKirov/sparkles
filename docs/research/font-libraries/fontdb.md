# fontdb (Rust)

A deliberately small, in-memory font _database_. It holds one `FaceInfo` per
face, loads them from files, directories or bytes, scans a fixed list of
system directories, and answers a CSS Fonts Level 3 style query with a single
`ID`. It does no per-codepoint fallback, keeps no cache on disk, and does not
call any system API.

| Field            | Value                                                                                                       |
| ---------------- | ----------------------------------------------------------------------------------------------------------- |
| Language         | Rust (edition 2018, `rust-version = "1.71"`, `no_std` + `alloc` without the `std` feature)                  |
| License          | MIT ([`LICENSE`][license])                                                                                  |
| Repository       | [`RazrFalcon/fontdb`][repo]                                                                                 |
| Documentation    | [`README.md`][readme], crate docs at the top of [`src/lib.rs`][lib]; [`CHANGELOG.md`][changelog]            |
| Version at pin   | `0.24.0` ([`Cargo.toml`][cargo]); deps `slotmap`, `tinyvec`, `log`, optional `memmap2`, `fontconfig-parser` |
| Category         | font database/discovery                                                                                     |
| Layer(s) covered | discover · match (no fallback, no parse beyond `name`/`OS/2`/`post`, no shape, no raster)                   |
| Pinned revision  | `ecb707e6096b59146b750f66a32c125a43515192` (2026-07-29)                                                     |

## Overview

### What it solves

Pure-Rust text stacks need "give me the face for `font-family: Fira Code;
font-weight: 600`" without linking fontconfig, CoreText or DirectWrite.
`fontdb` is that piece. Among the catalog subjects,
[`cosmic-text`](./cosmic-text.md) consumes it: it pins `fontdb = { version = "0.24",
default-features = false }` and layers its own fallback lists on top. The
whole crate is 2 919 lines of Rust. Of those, 1 383 are [`src/lib.rs`][lib]
and about 1 500 are a vendored parser subset under `src/ttf_parser/`. Since
0.24.0 it "no longer depends on `ttf-parser`. It vendors a minimal subset
instead" ([`CHANGELOG.md`][changelog]). The subset is "just enough of the
original crate to parse font table records, the `name` table and parts of the
`OS/2` table" ([`src/ttf_parser/mod.rs`][ttfp-mod]).

### Design philosophy

The non-goals carry the design:

> - Advanced font properties querying.
>   The database provides only storage and matching capabilities.
>   For font properties querying you can use [ttf-parser].
> - A font fallback mechanism.
>   This library can be used to implement a font fallback mechanism, but it doesn't implement one.
> - Application's global database.
>   The database doesn't use `static`, therefore it's up to the caller where it should be stored.
> - Font types support other than TrueType.
>
> — [`README.md`][readme]

The doc comment on `load_system_fonts` states the discovery stance outright:
"System fonts loading is a surprisingly complicated task, mostly unsolvable
without interacting with system libraries. And since `fontdb` tries to be
small and portable, this method will simply scan some predefined directories"
([`src/lib.rs`][lib]).

## How it works

```rust
pub struct Database {
    faces: SlotMap<InnerId, FaceInfo>,
    family_serif: String,
    family_sans_serif: String,
    family_cursive: String,
    family_fantasy: String,
    family_monospace: String,
}
```

— [`src/lib.rs`][lib]

Loading a face parses only three tables. `parse_face_info` runs
`RawFace::parse(data, index)`, then `parse_names` reads the typographic family
(name ID 16), falling back to family (ID 1) and moving `en-US` to the front. It
also reads the PostScript name (ID 6). `parse_os2` reads `usWeightClass`,
`usWidthClass` and the style bits. `parse_post` is a hand-written two-field
read: `isFixedPitch` (the "u32 at offset 12 is non-zero") becomes
`monospaced`, and a non-zero `italicAngle` upgrades `Style::Normal` to
`Italic`. A face with no usable family name fails with
`LoadError::UnnamedFont` and is logged and skipped.

The resulting record is:

| `FaceInfo` field   | Source                                                                                          |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| `id: ID`           | `slotmap` key, assigned on insert                                                               |
| `source: Source`   | `Binary(Arc<dyn AsRef<[u8]> + Send + Sync>)`, `File(PathBuf)`, or `SharedFile(PathBuf, Arc<…>)` |
| `index: u32`       | face index within a collection                                                                  |
| `families`         | `Vec<(String, Language)>`, from name ID 16 or 1, `en-US` first                                  |
| `post_script_name` | name ID 6                                                                                       |
| `style`            | `Normal` / `Italic` / `Oblique` from `OS/2`, upgraded by `post.italicAngle`                     |
| `weight`           | `Weight(u16)`, from `OS/2` `usWeightClass`                                                      |
| `stretch`          | `Stretch`, from `OS/2` `usWidthClass`                                                           |
| `monospaced`       | `post.isFixedPitch`                                                                             |

That is the entire index. There is no coverage set, no `fvar` axis range, no
Unicode or code-page ranges, and no PANOSE.

## Analysis spine

### 1. Layering and ownership

One layer, the database. `Database` owns a `SlotMap` of `FaceInfo`, so `ID`s
are generational. The `ID` docs warn that a stale ID returns `None`, and that
an ID from another database is not detected: "Since `Database` is not
global/unique, we cannot guarantee that a specific ID is actually from the same
db instance. This is up to the caller" ([`src/lib.rs`][lib]).

Bytes are not held for file sources. `Source::File` stores only the path. The
file is mmapped during loading and again inside every `with_face_data` call,
and is unmapped afterwards. The README's safety note gives the reasoning: "The
library relies on memory-mapped files, which is inherently unsafe. But since we
do not keep the files open it should be perfectly safe." To keep a mapping
alive, a caller uses `unsafe fn make_shared_face_data(id)`. That converts every
face from the same path to `Source::SharedFile` and returns the
`Arc<dyn AsRef<[u8]> + Send + Sync>`. `make_face_data_unshared` reverses it.

Thread-safety is plain Rust. `Database` is `Clone` and has no interior
mutability, so callers share `&Database` or wrap it in a lock. The error model
is lossy. `load_font_file` returns `io::Error`, while `load_fonts_dir` and
`load_system_fonts` return nothing and `log::warn!` each malformed face.

### 2. Face loading and table access

| Entry point                | Behavior                                                                                                                    |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `load_font_data(Vec<u8>)`  | wraps in `Source::Binary(Arc)`; every face of a collection                                                                  |
| `load_font_source(Source)` | returns `TinyVec<[ID; 8]>` of the faces added                                                                               |
| `load_font_file(path)`     | mmap (or `fs::read` without the `memmap` feature), all faces                                                                |
| `load_fonts_dir(dir)`      | recursive; extensions `ttf`/`ttc`/`otf`/`otc` in either case; symlinks canonicalized and de-duplicated through a `seen` set |
| `push_face_info(FaceInfo)` | inserts a caller-built record without parsing, so metadata can be overridden                                                |
| `remove_face(id)`          | drops one face                                                                                                              |

Collections are expanded eagerly: `fonts_in_collection` gives the count and
each index becomes its own `FaceInfo` sharing one `Source`. Nothing else in
the file is read at load time. There is no raw table access through the
database. `with_face_data(id, |data: &[u8], index: u32| …)` hands the whole
file to a closure, and the caller parses it with another library. Formats
outside TrueType/OpenType are rejected by extension. WOFF, WOFF2, `.dfont` and
Type 1 never enter.

### 3. Shaping

**Absent.** The database knows nothing about glyphs or features.

### 4. Variation and instances

**Absent, and this is a matching bug, not just a missing feature.** A variable
font is indexed as one `FaceInfo` carrying its default instance's
`usWeightClass`. `query` therefore cannot pick a `wght=700` instance of a
variable family, and it may prefer a static bold in another face over the
variable font's own range. `fvar` named instances are not expanded into
records. fontconfig does expand them, and scores axis ranges with
`FcCompareRange` ([`./fontconfig.md`](./fontconfig.md)).

### 5. Rasterization and outlines

**Absent.**

### 6. Metrics and measurement

**Absent.** Only the classification bits are kept: weight, width, style and
`monospaced`. Even `monospaced` comes from the `post.isFixedPitch` flag rather
than from advances, so a font that lies in `post` is misclassified.

### 7. Discovery, matching and fallback

**Enumeration** happens in `load_system_fonts`, which scans fixed directories
per platform:

| Platform    | Directories                                                                                                                                                                                                                                                                   |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Windows     | `%SYSTEMROOT%\Fonts` (else `C:\Windows\Fonts\`), `%USERPROFILE%\AppData\Local\Microsoft\Windows\Fonts`, `…\Roaming\…\Fonts`                                                                                                                                                   |
| macOS / iOS | `/Library/Fonts`, `/System/Library/Fonts`, `/System/Library/AssetsV2/com_apple_MobileAsset_Font*`, `/Network/Library/Fonts`, `~/Library/Fonts`                                                                                                                                |
| Linux / BSD | with the `fontconfig` feature, the `<dir>` entries of `$FONTCONFIG_FILE` or `$XDG_CONFIG_HOME/fontconfig/fonts.conf` (else `/etc/fonts/local.conf`) plus `/etc/fonts/fonts.conf`; if none, `/usr/share/fonts/`, `/usr/local/share/fonts/`, `~/.fonts`, `~/.local/share/fonts` |
| Redox       | `/ui/fonts`                                                                                                                                                                                                                                                                   |
| Android     | **nothing**: the Linux arm excludes `target_os = "android"` and no Android arm exists                                                                                                                                                                                         |

On Linux, `fontconfig-parser` reads the XML configuration only. It does not
read fontconfig's binary cache or apply `<match>` edits. The one thing taken
from the rules is each `<alias>`'s first `prefer`, else `accept`, else
`default` entry, which becomes the generic family through
`set_serif_family`, `set_sans_serif_family`, `set_monospace_family`,
`set_cursive_family` and `set_fantasy_family`. The `Cargo.toml` comment says
the feature "Must be enabled for NixOS, otherwise no fonts will be loaded".
Without fontconfig the generic defaults are hard-coded Windows names, such as
`monospace` meaning "Courier New".

**Matching** goes through `query(&Query { families, weight, stretch, style })`.
The method walks `families` in order. For each family it resolves the generic
name, collects every face whose `families` list contains that string, and runs
`find_best_match`. The comment on that function cites "CSS Fonts 3 §5.2
font-style-matching", "Based on servo/font-kit". The spec's step 4 reads:

> 'font-stretch' is tried first. If the matching set contains faces with width
> values matching the 'font-stretch' value, faces with other width values are
> removed from the matching set.
>
> — [CSS Fonts Module Level 3, §5.2][css-fonts-3]

The function implements step 4a (stretch, nearest narrower when the request is
at or below normal, else nearer wider), then 4b (style preference lists such as
`Italic → Oblique → Normal`), then 4c (weight). It skips 4d (size). For weight,
the spec says "If the desired weight is 400, 500 is checked first … If the
desired weight is 500, 400 is checked first". `fontdb` generalizes this to a
450 cutoff, with the comment "The spec doesn't say what to do if the weight is
between 400 and 500 exclusive, so we just use 450 as the cutoff". The first
survivor wins.

Family matching is exact and case-sensitive string equality (`family.0 ==
name`), checked against every localized family name. There is no
normalization, no PostScript-name or full-name lookup, and no fuzzy matching.

**Fallback.** The spec continues: "If no matching face exists or the matched
face does not contain a glyph for the character to be rendered, the next
family name is selected … If there are no more font families to be evaluated
and no matching face has been found, then the user agent performs a system
font fallback procedure" ([§5.2][css-fonts-3]). `fontdb` implements only the
"no matching face" half. It never checks glyph coverage because it never reads
`cmap`, and it has no system fallback. `query` returns `None`, and the caller
iterates `faces()` with its own coverage test.

**Comparison with fontconfig.** fontconfig scores every font against every
property in a priority-ordered `double score[PRI_END]` vector
([`./fontconfig.md`](./fontconfig.md)). That vector includes `lang` coverage,
charset and variable ranges, and `FcFontSort` returns a whole ordered fallback
list. `fontdb` instead runs a lexicographic filter over only four properties,
returns one face, and has no notion of language or coverage. A filter is
faster and easier to reason about, but it cannot rank fallback candidates.

## What it teaches `sparkles:font`

- **A face index is a small Regular record, separate from the bytes.**
  `FaceInfo { source, index, families, postScriptName, style, weight, stretch,
monospaced }` is the right shape for a D value type in a dense array with
  generational IDs, which is what `slotmap` gives `fontdb`. `sparkles:font`
  should add a coverage bitmap, axis ranges and `OS/2` Unicode ranges, which
  `fontdb` omits.
- **Borrow on demand: `withFaceData(id, (scope const(ubyte)[] data, uint
index) => …)`.** The closure form maps naturally onto `scope` under
  `-preview=dip1000`, and a separate opt-in "pin this mapping" call covers
  long-lived faces.
- **Implement CSS §5.2 step 4 literally, then add the parts `fontdb` skips.**
  Those parts are coverage-aware step 5, variable-axis ranges in steps 4a–4c,
  and an explicit system fallback hook. The 450 weight cutoff is a documented
  gap in the spec worth copying.
- **Directory scanning is not discovery.** `fontdb` returns nothing on
  Android, ignores fontconfig's cache and rules, and defaults `monospace` to
  Courier New. `sparkles:font` needs a native backend per platform (fontconfig,
  CoreText, Android `/system/fonts` plus `fonts.xml`), with the scan only as
  the last resort.
- **Loading must report, not log.** Malformed faces should come back as
  `Expected` diagnostics that an inspector can display.

## Strengths

- Tiny, `no_std`-capable, with zero system dependencies; indexes about 1 900
  faces in roughly 20 ms with a hot disk cache, per the crate docs.
- Generational IDs and a closure-scoped data borrow make lifetime errors hard.
- The matching algorithm is a readable transcription of a published spec.
- `push_face_info` lets an application override broken font metadata.

## Weaknesses

- No per-codepoint fallback, no coverage data and no language awareness.
- Variable fonts are classified by their default instance only.
- No Android support, and Linux support depends on the fontconfig XML config
  without its rules or cache.
- Family matching is exact-string only, so a query for "Fira Code Retina" or
  a full name fails.
- Errors become log lines, so callers cannot tell why a font is missing.
- `monospaced` trusts `post.isFixedPitch`.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                             | Trade-off                                                         |
| ----------------------------------------------- | ----------------------------------------------------- | ----------------------------------------------------------------- |
| Scan directories instead of calling system APIs | Small and portable, with no FFI                       | Misses Android, fontconfig rules, downloadable or activated fonts |
| Parse only `name`, `OS/2`, `post`               | Fast indexing; parser vendored (about 1.5 KLOC)       | No coverage, axes or metrics in the index                         |
| `Source::File` keeps only the path              | No open file handles, so mmap safety is easy to argue | A new mmap on every `with_face_data` call                         |
| CSS §5.2 lexicographic filter                   | Matches web expectations; deterministic               | One answer only, with no ranked fallback list                     |
| Generic families as five settable strings       | Simple override; fontconfig aliases feed it           | No per-language generics; Windows defaults elsewhere              |
| No global or static database                    | Caller controls placement and lifetime                | Every consumer wires up its own sharing                           |
| `SlotMap` IDs                                   | Stable across removals; stale IDs are detected        | Cross-database IDs are not detected                               |

## Sources

All repository paths verified at the pinned revision with `git cat-file -e`.

- **Crate** — [`README.md`][readme], [`src/lib.rs`][lib], [`Cargo.toml`][cargo],
  [`CHANGELOG.md`][changelog].
- **Vendored parser** — [`src/ttf_parser/mod.rs`][ttfp-mod],
  [`src/ttf_parser/os2.rs`][ttfp-os2], [`src/ttf_parser/name.rs`][ttfp-name].
- **Specification** — [CSS Fonts Module Level 3, §5.2 Matching font styles][css-fonts-3]
  (W3C Recommendation, 2018-09-20).
- Siblings: [`./fontconfig.md`](./fontconfig.md), [`./font-kit.md`](./font-kit.md),
  [`./cosmic-text.md`](./cosmic-text.md), [`./ttf-parser.md`](./ttf-parser.md).

<!-- References -->

[repo]: https://github.com/RazrFalcon/fontdb
[license]: https://github.com/RazrFalcon/fontdb/blob/ecb707e6096b59146b750f66a32c125a43515192/LICENSE
[readme]: https://github.com/RazrFalcon/fontdb/blob/ecb707e6096b59146b750f66a32c125a43515192/README.md
[lib]: https://github.com/RazrFalcon/fontdb/blob/ecb707e6096b59146b750f66a32c125a43515192/src/lib.rs
[cargo]: https://github.com/RazrFalcon/fontdb/blob/ecb707e6096b59146b750f66a32c125a43515192/Cargo.toml
[changelog]: https://github.com/RazrFalcon/fontdb/blob/ecb707e6096b59146b750f66a32c125a43515192/CHANGELOG.md
[ttfp-mod]: https://github.com/RazrFalcon/fontdb/blob/ecb707e6096b59146b750f66a32c125a43515192/src/ttf_parser/mod.rs
[ttfp-os2]: https://github.com/RazrFalcon/fontdb/blob/ecb707e6096b59146b750f66a32c125a43515192/src/ttf_parser/os2.rs
[ttfp-name]: https://github.com/RazrFalcon/fontdb/blob/ecb707e6096b59146b750f66a32c125a43515192/src/ttf_parser/name.rs
[css-fonts-3]: https://www.w3.org/TR/2018/REC-css-fonts-3-20180920/#font-style-matching
