# Reproducible Builds archive canonicalization

Not a scheme but a decade-long field report: what it actually costs to retrofit
a canonical form onto TAR, ZIP, `ar`, cpio and gzip after the fact — and the
enumerated list of things that retrofit provably cannot reach.

|                    |                                                                                                                 |
| ------------------ | --------------------------------------------------------------------------------------------------------------- |
| **Ecosystem**      | Debian, Fedora, openSUSE, Arch, Tails, Bitcoin Core, F-Droid — everyone who ships an archive                    |
| **Level 1**        | **borrowed** — whatever TAR/ZIP/`ar`/cpio serialization the producer already emits                              |
| **Level 2**        | whole file, usually through a compressor the normalizer does not re-run                                         |
| **Node model**     | the host format's, minus whatever a flag or a normalizer can be persuaded to zero                               |
| **Entry ordering** | producer-chosen; `--sort=name` (GNU tar ≥ 1.28) and an in-archive re-sort (ZIP) are the only levers             |
| **Digest**         | **none of its own** — the digest is whoever consumes the archive ([OCI][oci], a distro's `.deb`, a `sha256sum`) |
| **Documentation**  | [`reproducible-builds.org/docs/archives/`][rb-archives], [the `SOURCE_DATE_EPOCH` specification][sde-spec]      |
| **Implementation** | [`strip-nondeterminism`][snd-repo] 1.15.1, [GNU tar § 8.4][gnutar-repro]                                        |

## Overview

### What it solves

Every other subject in this catalog got to choose its serialization. This one
did not. Debian cannot reissue its `.deb` format as [NAR][nar], so the problem
became: given a format with no canonical form, how close to one can flags,
environment and post-processing get you?

The tool built for the residue states the shape of the compromise in its own
`README` ([`strip-nondeterminism`][snd-readme]):

> `File::StripNondeterminism` is a Perl module for stripping bits of
> nondeterministic information, such as timestamps and file system order, from
> files such as gzipped files, ZIP archives, and Jar files. It can be used as a
> post-processing step to make a build reproducible, when the build process
> itself cannot be made deterministic.

"When the build process itself cannot be made deterministic" is the admission
that matters. A canonical-by-construction format has no post-processing step,
because there is no residue to strip.

### Design philosophy

The target property is deliberately weaker than canonicity, and GNU tar's
manual defines it precisely ([§ 8.4 Making tar Archives More
Reproducible][gnutar-repro]):

> We call an archive _reproducible_, if an archive created from the same set of
> input files with the same command line options is byte-to-byte equivalent to
> the original one.
>
> However, two archives created by GNU tar from two sets of input files
> normally might differ even if the input files have the same contents and GNU
> tar was invoked the same way on both sets of input. This can happen if the
> inputs have different modification dates or other metadata, or if the input
> directories' entries are in different orders.

Read the quantifiers. **Reproducibility is indexed by the producer and its
options**; canonicity is indexed by the tree alone. `tar` promises only that
_this_ tar, with _these_ flags, on _this_ content, repeats itself — which is
exactly the guarantee [OCI layer digests][oci] rest on and exactly why they do
not hold across builders. The [NAR][nar] rationale's objection ("given an FSO,
there can be many different serialisations") is not answered by any amount of
flag discipline; it is only narrowed.

The project's own framing of the residue is the second half of the philosophy
([`stripping_unreproducible_information.md`][rb-strip]):

> Metadata like file ownership, permissions, or even unimportant data stored by
> some formats can introduce variability.

Note the word _unimportant_. The retrofit's whole method is to identify fields
that the consumer does not need and overwrite them with a constant — the same
move [NAR][nar] and [git][git] make by **not having the fields at all**.

## How it works

Three layers, applied in this order, each catching what the previous one missed.

**1. A single clock.** `SOURCE_DATE_EPOCH` replaces "now" everywhere, and the
specification is written in RFC 2119 terms ([the specification][sde-spec]):

> A UNIX timestamp, defined as the number of seconds, excluding leap seconds,
> since `01 Jan 1970 00:00:00 UTC`. […] The value MUST be reproducible
> (deterministic) across different executions of the build, depending only on
> the source code. […] Build processes MUST use this variable for embedded
> timestamps in place of the "current" date and time.

Plus the rule that makes it usable on trees that legitimately carry older
times — **clamping**, not flattening:

> Where build processes embed timestamps that are not "current", but are
> nevertheless still specific to one execution of the build process, they MUST
> use a timestamp no later than the value of this variable. This is often called
> "timestamp clamping".

**2. Producer flags.** The canonical `tar` invocation, quoted from the project's
archive-metadata page ([`archives.md`][rb-archives]):

```bash
# requires GNU Tar 1.28+
tar --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 --group=0 --numeric-owner \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -cf product.tar build
```

GNU tar's own list adds two that the web page leaves implicit — `--format=posix`
and `--mode='go+u,go-w'` — and one that no flag can express, because it is
ambient state ([§ 8.4][gnutar-repro]):

> you can run GNU tar in the C locale with some or all of the following
> options

`ar` has its own single-flag answer (binutils' deterministic mode, `ARFLAGS=Dcvr`),
and the reproducible-builds page records exactly where it stops
([`archives.md`][rb-archives]):

> GNU `ar` and other tools from binutils have a _deterministic mode_ which will
> use zero for UIDs, GIDs, timestamps, and use consistent file modes for all
> files. […] Another option is post-processing with strip-nondeterminism or
> `objcopy`[.] […] **The above does not fix file ordering.**

**3. A post-hoc normalizer**, for producers that will not take flags.
`strip-nondeterminism` dispatches on extension plus `file(1)` output, and its
handler table ([`StripNondeterminism.pm`][snd-main]) is an empirical census of
what the ecosystem found worth fixing:

```perl
our %KNOWN_HANDLERS = (
    ar      => 0,
    bflt    => 1,
    cpio    => 1,
    gettext => 1,
    gzip    => 1,
    jar     => 1,
    javadoc => 1,
    jmod    => 1,
    uimage  => 1,
    png     => 1,
    pyzip   => 1,
    javaproperties => 1,
    zip     => 1,
);
```

Two facts are legible in that table alone. **There is no `tar` handler** — tar
is fixed at production time or not at all, because a tar stream is
unstructured enough that rewriting it is rewriting it. And **`ar` is the one
handler disabled by default** (`=> 0`), because binutils' deterministic mode
made it redundant; its header comment records the reversal
([`ar.pm`][snd-ar]):

> This handler was originally removed in late 2018 as binutils was deemed to be
> reproducible […] However, it was re-introduced in late 2019 […] in order to
> support "not just 'older' toolchains, it's also about 'other' toolchains".

The module's `init()` is one line of policy and worth naming, because it is a
whole class of bug closed globally ([`StripNondeterminism.pm`][snd-main]):

```perl
sub init() {
    $ENV{'TZ'} = 'UTC';
    tzset();
}
```

### Dimension 1 — node model

**Borrowed, then narrowed.** There is no model of its own; there is the host
format's model with selected fields pinned to constants. The pinning is
uniform across handlers and lands on the same two values [git][git] uses:

```perl
# zip.pm — Unix attributes, collapsed to the executable bit
$member->unixFileAttributes(
    ($member->unixFileAttributes() & oct(100)) ? oct(755) : oct(644));
```

```perl
# ar.pm — mtime, uid, gid, mode, in the fixed-width 60-byte header
syswrite $fh, sprintf("%-12d", $File::StripNondeterminism::canonical_time // 0);
syswrite $fh, sprintf("%-6d", 0);   # owner
syswrite $fh, sprintf("%-6d", 0);   # group
syswrite $fh, sprintf("%-8o", ($file_mode & oct(100)) ? oct(755) : oct(644));
```

So the _effective_ model after normalization is close to [NAR's][fso] — name,
bytes, one executable bit — but it is reached by overwriting fields rather than
by not having them, which means every new producer, format variant and extra
field is a fresh chance to reintroduce one.

### Dimension 2 — canonical form and ordering

**The dimension the retrofit fails hardest.** Ordering is the producer's, and
only two of the surveyed formats can be re-ordered at all:

- **TAR** — `--sort=name`, "sort filenames in a locale independent manner"
  ([`archives.md`][rb-archives]), available only from GNU tar 1.28. Older tar
  and non-GNU tar need `find … | LC_ALL=C sort -z | tar --no-recursion --null -T -`.
  There is no post-hoc fix: `strip-nondeterminism` has no tar handler.
- **ZIP** — re-sorted _in place_ by removing and re-adding every member
  ([`zip.pm`][snd-zip]):

  ```perl
  my @filenames = sort $filename_cmp $zip->memberNames();
  for my $filename (@filenames) {
      my $member = $zip->removeMember($filename);
      $zip->addMember($member);
      ...
  }
  ```

  The comparator is pluggable, and the `jar` handler supplies its own because
  the format demands a non-lexicographic prefix — `META-INF/` then
  `META-INF/MANIFEST.MF` first, everything else by `cmp` ([`jar.pm`][snd-jar]).
  **That is a fifth entry ordering**, beside the four the [index][index]
  already counts.

- **`ar`** — not reorderable. The page says so outright: "The above does not
  fix file ordering" ([`archives.md`][rb-archives]). `strip-nondeterminism`'s
  handler seeks through members in place and never moves one.
- **cpio** — order is whatever was piped in; the handler rewrites `mtime` only
  ([`cpio.pm`][snd-cpio]).

And ZIP has a structural ambiguity no ordering flag can close, because the
format specifies two orders and explicitly permits them to disagree
([APPNOTE.TXT § 4.4.1.3][appnote]):

> The entries in the central directory MAY NOT necessarily be in the same order
> that files appear in the .ZIP file.

A canonical ZIP would have to pin both, and the specification blesses the
divergence.

### Dimension 3 — level-1 composition

**Absent.** This is a genuine hole, not an omission: the retrofit is defined
over a flat sequence of archive members, and no subject in it has a subtree
value. `strip-nondeterminism` does recurse — a JAR's members are extracted to a
temporary file, normalized by the handler their own type selects, and written
back ([`zip.pm`][snd-zip], `normalize_member`), and the `jar` handler recurses
into nested `.jar` members. But that recursion produces no intermediate
digest, nothing is cached, and a one-file change means re-normalizing and
re-hashing the whole archive. Compare [git's][git] `O(depth)`.

The consequence for consumers is the [OCI][oci] one: a normalized tarball is
still a single opaque blob to whatever hashes it.

### Dimension 4 — level-2 granularity

**Whole file, and the compressor is out of reach.** The gzip handler rewrites
the 10-byte RFC 1952 header — clearing `FNAME` and `FHCRC`, clamping `MTIME` —
and then copies the DEFLATE stream through byte for byte
([`gzip.pm`][snd-gzip]):

```perl
my $new_flg = $flg;
$new_flg &= ~FNAME;   # Don't include filename
$new_flg &= ~FHCRC;   # Don't include header CRC
```

It never recompresses, so **compression level, zlib version and any dictionary
choice survive normalization intact**. Two builders at `-6` and `-9` produce
different bytes from identical input, and nothing downstream can tell:

```bash
$ yes "reproducible builds normalize archives" | head -3000 > c.txt
$ gzip -6 -n -c c.txt | sha256sum   # 6094116d923c…   413 bytes
$ gzip -9 -n -c c.txt | sha256sum   # 919e16f69dee…   413 bytes
```

The project documents the same hazard where it bites hardest — `git archive`
([`archives.md`][rb-archives]):

> In practice, the `tar` output is typically stable, but the internal `gzip`
> implementation is not. Using `git archive --format=tar TAG | gzip -6 -n` is
> more reliable.

"More reliable", because the fix is to move compression to a tool whose version
you pin — not to normalize the output of the one you have.

### Dimension 5 — digest

**None.** The retrofit defines no digest and names no hash function; that is
the point of it. It makes an archive a stable _input_ to somebody else's
digest — `sha256sum` over a release tarball, a `.deb`'s checksums, an
[OCI `DiffID`][oci]. Every other subject in this catalog owns its digest and
therefore owns the equality relation; here the equality relation is "the same
producer, at the same version, with the same flags, on the same tree", and
nobody owns it.

### Dimension 6 — partial verification

**None, and worse than none: the failures are silent.** Verification in this
world is `diff`-of-rebuild, at whole-archive granularity. `strip-nondeterminism`
compounds this by design — it is a best-effort filter that warns and returns
success on inputs it cannot handle ([`zip.pm`][snd-zip]):

```perl
warn "strip-nondeterminism: $zip_filename: ignoring zip64 file\n";
return 0;
```

with the reasoning stated in the comment above it: "Ignoring unsupported files,
instead of erroring out, is consistent with the rest of strip-nondeterminism's
behavior, but warn about it in case someone is confused why a `.zip` file is
left with nondeterminism in it." Signed JARs are skipped too, because
normalizing them would break the signature ([`jar.pm`][snd-jar]). An archive
that emerges un-normalized is indistinguishable, at the exit code, from one
that emerged canonical.

## What varies, and whether it can be fixed

| Field                                   | Format(s)               | Fixable by                                                                                                                     | Residual risk                                                                                                 |
| --------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Entry order                             | TAR                     | `--sort=name` (GNU ≥ 1.28), else `find \| LC_ALL=C sort -z \| tar --no-recursion --null -T -`                                  | No post-hoc fix exists — no tar handler ships. Wrong locale silently reorders.                                |
| Entry order                             | ZIP, JAR                | Post-hoc re-sort in `strip-nondeterminism` ([`zip.pm`][snd-zip]); JAR needs its own comparator                                 | Central-directory order and local-header order may legally differ ([APPNOTE § 4.4.1.3][appnote])              |
| Entry order                             | `ar`, cpio              | **Nothing.** "The above does not fix file ordering" ([`archives.md`][rb-archives])                                             | Linker/build-system order is the archive's order, permanently                                                 |
| mtime                                   | all                     | `--mtime=@$SOURCE_DATE_EPOCH` / `--clamp-mtime`; handlers for ZIP, `ar`, cpio, gzip, PNG `tIME`, gettext                       | gzip deliberately leaves `MTIME == 0` alone ([`gzip.pm`][snd-gzip]); ZIP cannot go below 1980 (see below)     |
| atime, ctime                            | TAR (pax)               | `--pax-option=delete=atime,delete=ctime`, or `--format=gnu` / `--format=ustar`                                                 | Emitted by default when the distro's tar defaults to pax; invisible until someone diffs                       |
| tar process PID                         | TAR (pax)               | `--pax-option=exthdr.name=%d/PaxHeaders/%f`                                                                                    | Only appears when `POSIXLY_CORRECT` is set — an environment variable leaking into archive bytes               |
| uid / gid                               | TAR, `ar`, cpio, ZIP    | `--owner=0 --group=0 --numeric-owner`; `ARFLAGS=Dcvr`; ZIP extra field `0x7875` zeroed ([`zip.pm`][snd-zip])                   | ZIP's uid/gid live in an _extra field_ `Archive::Zip` mishandles; the fix is a runtime method override        |
| uname / gname strings                   | TAR (ustar/pax)         | `--numeric-owner`                                                                                                              | Without it the builder's account name is in the bytes                                                         |
| Mode bits                               | TAR, ZIP, `ar`          | `--mode='go+u,go-w'`; collapse to `755`/`644` in handlers                                                                      | `umask` still decides before the archiver runs, if no flag is passed                                          |
| Timezone of the stored timestamp        | **ZIP**                 | `TZ=UTC` in the environment; `strip-nondeterminism`'s `init()` sets it                                                         | **Format-level**: DOS timestamps carry no zone. Same file, two zones, two archives (demonstrated below)       |
| 2-second timestamp granularity          | **ZIP**                 | **Unfixable** — `SOURCE_DATE_EPOCH` is rounded on the way in                                                                   | "MS-DOS uses year values relative to 1980 and 2 second precision" ([APPNOTE § 4.4.6][appnote])                |
| Timestamps before 1980                  | **ZIP**                 | **Unfixable** — clamped to `SAFE_EPOCH` = `315576060` ([`zip.pm`][snd-zip])                                                    | An epoch-0 `SOURCE_DATE_EPOCH` silently becomes 1980-01-01T12:01Z                                             |
| Extended-timestamp extra field `0x5455` | ZIP                     | Rewritten to the canonical time ([`zip.pm`][snd-zip])                                                                          | Only the fields the parser recognizes; unknown ids are copied through verbatim                                |
| NTFS extra field `0x000a`               | ZIP                     | m/a/ctime rewritten in 100 ns WinNT units ([`zip.pm`][snd-zip], [APPNOTE § 4.5.5][appnote])                                    | Three separate timestamps, all producer-dependent, in an optional block                                       |
| Unknown / vendor extra fields           | ZIP                     | **Nothing** — "use the current extra field unmodified" ([`zip.pm`][snd-zip])                                                   | Open-ended: any tool may add a field carrying anything                                                        |
| "Version made by" (host OS byte)        | ZIP                     | **Nothing** in the surveyed tooling                                                                                            | Producer's platform identity is in every central-directory entry ([APPNOTE § 4.4.2][appnote])                 |
| Archive format variant                  | TAR (gnu/ustar/pax)     | `--format=posix` or `--format=ustar`, chosen and pinned                                                                        | **Changes the bytes entirely** — same flags, same tree, different digest (demonstrated below)                 |
| Compression level / implementation      | gzip, ZIP DEFLATE, zstd | **Unfixable post hoc** — no normalizer recompresses                                                                            | `git archive`'s internal gzip is the canonical example ([`archives.md`][rb-archives])                         |
| gzip `FNAME`, `FHCRC`, `OS` byte        | gzip                    | `gzip -n`; handler clears `FNAME` and `FHCRC`                                                                                  | The `OS` byte is left alone — the handler's own `TODO` asks whether to normalize it ([`gzip.pm`][snd-gzip])   |
| Concatenated gzip members               | gzip                    | **Nothing** — "This will require reading and understanding each DEFLATE block […] since gzip doesn't include lengths anywhere" | Only the first member's header is normalized                                                                  |
| Device / inode numbers                  | cpio                    | Round-trip through `bsdtar --uid 0 --gid 0` ([`archives.md`][rb-archives])                                                     | "whilst deterministic, can vary from system to system"                                                        |
| Build-path and username strings         | JAR manifests, javadoc  | Drop `Bnd-LastModified` / `Built-By` lines; delete `javac.sh` ([`jar.pm`][snd-jar])                                            | A per-tool blocklist, enumerated by hand, one bug report at a time                                            |
| PNG `tIME`, `tEXt` date keys            | PNG                     | Rewritten / clamped ([`png.pm`][snd-png])                                                                                      | Only chunks under 4096 bytes are inspected; trailing garbage after `IEND` is preserved deliberately           |
| `POT-Creation-Date` in `.mo` catalogues | gettext                 | In-place string substitution ([`gettext.pm`][snd-gettext])                                                                     | **Only if the replacement is the same length** — `.mo` is an offset table, so a longer date cannot be written |
| Signed archives                         | JAR                     | **Nothing** — normalizing breaks the signature, so the file is skipped ([`jar.pm`][snd-jar])                                   | Silently returns success un-normalized                                                                        |
| ZIP64 archives                          | ZIP                     | **Nothing** — `Archive::Zip` cannot read them; warn and skip ([`zip.pm`][snd-zip])                                             | Silently returns success un-normalized                                                                        |
| Encrypted ZIP members                   | ZIP                     | **Nothing** — warn and skip ([`zip.pm`][snd-zip])                                                                              | Silently returns success un-normalized                                                                        |
| Sort collation                          | all                     | `LC_ALL=C`; GNU tar's manual says run "in the C locale"                                                                        | Ambient environment, not a flag; a wrong locale is invisible in the output                                    |

Two rows are worth showing rather than asserting. **Format variant**, with the
reproducible-builds flag set held fixed and only `--format` changed:

```bash
$ tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
      --numeric-owner -cf p1.tar t                     # GNU tar 1.35 default
$ tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
      --numeric-owner --format=ustar -cf p2.tar t
$ sha256sum p1.tar p2.tar
00e6f05bdce6…  p1.tar
5664cf74a61b…  p2.tar
```

**ZIP's DOS timestamp**, which is both coarse and zone-relative — the same file
at the same `mtime`, archived in two timezones, in two different archives:

```bash
$ for ts in 1700000000 1700000001 1700000002 1700000003; do
      touch -d "@$ts" c.txt; zip -qX z.zip c.txt; zipinfo -T z.zip; done
20231115.001320   # 1700000000
20231115.001322   # 1700000001  -- rounded
20231115.001322   # 1700000002
20231115.001324   # 1700000003

$ TZ=UTC        zip -qX zu.zip c.txt   # stored 20231114.221320, sha 9400296fd44f…
$ TZ=Asia/Tokyo zip -qX zt.zip c.txt   # stored 20231115.071320, sha e11e82380dd6…
```

Nothing in the ZIP header records which zone produced either one.

## Strengths

- **The only body of evidence of its kind**: a per-format, per-field census of
  what actually varies in the wild, accumulated from real divergences rather
  than from a threat model.
- **`SOURCE_DATE_EPOCH` is a genuinely good primitive** — one variable, RFC 2119
  rules, and a clamping semantics that preserves legitimately-old source
  timestamps instead of flattening the tree.
- **Works on formats nobody can replace.** `.deb`, `.jar`, `.apk` and
  `.tar.gz` are not going away, and this is the only lever available on them.
- **Composes downward.** The `jar` handler reuses `zip`, which reuses whatever
  handler each member's type selects — a recursion that also normalizes nested
  archives.
- **The residue is documented**, in per-handler `DEPRECATION PLAN`
  blocks naming why each one still has to exist.

## Weaknesses

- **Reproducibility is not canonicity.** The property achieved is indexed by
  producer, version, flags, locale and timezone; two honest builders can differ
  on all five.
- **The enumeration can never be closed.** ZIP extra fields are open-ended by
  design; an unrecognized id is copied through untouched.
- **Silent under-normalization.** ZIP64, encrypted and signed archives warn and
  return success — the caller cannot distinguish "canonical" from "gave up".
- **Compression is out of scope**, so the most common real-world divergence
  (`gzip -6` versus `-9`, zlib versus zlib-ng) survives every normalizer.
- **Unfixable ZIP floors**: 2-second granularity, the 1980 epoch, and a
  timestamp with no timezone.
- **Ordering is mostly unreachable** post hoc — TAR has no handler at all, and
  `ar`/cpio cannot be reordered.
- **Ambient state in the bytes**: `TZ`, `LC_ALL`, `umask` and `POSIXLY_CORRECT`
  each change archive output without appearing on any command line.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                                 | Trade-off                                                                                                     |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Normalize existing formats rather than define a new one           | The formats are load-bearing across every distribution; replacing them is not an option                   | Accepts a weaker property forever, and an open-ended list of fields                                           |
| One environment variable (`SOURCE_DATE_EPOCH`) as the whole clock | A single point of control every tool can read, specifiable in RFC 2119 terms                              | Requires per-tool adoption; a tool that ignores it is invisible until a rebuild diverges                      |
| Clamp timestamps instead of flattening them                       | "efficiently both preserve source-based timestamps and omit build-specific timestamps" ([spec][sde-spec]) | Two builds from the same source at different `SOURCE_DATE_EPOCH` still differ, correctly but inconveniently   |
| Prefer producer flags; post-process only as fallback              | Flags are cheap and cannot desynchronize from the format                                                  | Flags exist only where an upstream added them, and only in recent versions (`--sort=name` needs GNU tar 1.28) |
| Post-processing warns and continues on unsupported input          | "consistent with the rest of strip-nondeterminism's behavior" ([`zip.pm`][snd-zip])                       | No exit-code signal that an archive was left non-canonical                                                    |
| Skip signed archives rather than strip signatures                 | A signed JAR is probably source, not build output, so it carries no build nondeterminism                  | A signed archive is simply exempt from the guarantee                                                          |
| Set `TZ=UTC` globally in `init()`                                 | ZIP's DOS timestamps are zone-relative with no zone field                                                 | Fixes the producer's process only; anyone else's ZIP is still zone-dependent                                  |
| Collapse modes to `755`/`644`, uid/gid to `0`                     | The consumer needs the executable bit and nothing else                                                    | Converges on [NAR's][nar] model by deletion rather than by design — every new field reopens the question      |
| Never recompress                                                  | Recompressing would change content the producer chose, and cost O(size) on every artifact                 | The single largest residual class of divergence is out of scope by construction                               |

## What this says for the catalog

The retrofit's ceiling is visible in one comparison. [NAR][nar] answers
"is this tree's serialization unique?" by construction, in a grammar short
enough to quote in full. This subject answers the same question with a
thirteen-name handler census, a nine-option `tar` invocation, four ambient environment
variables, and a list of cases that provably cannot be reached — timestamp
granularity, format epochs, compression, and ordering in two of five formats.
[OCI][oci] is the same experiment run without the discipline, and the
specification's `tar-split` recommendation — store the original headers,
because you cannot regenerate them — is where that path ends.

The conclusion for anything choosing a format today: **the cost of a canonical
format is paid once, at design time; the cost of normalizing a non-canonical
one is paid forever, by everyone, and still does not close.**

## Sources

- [`reproducible-builds.org/docs/archives/`][rb-archives] — the archive-metadata
  guidance; tar flags, `ar` deterministic mode, cpio, ZIP extra fields,
  `git archive`
- [`reproducible-builds.org/specs/source-date-epoch/`][sde-spec] — the
  `SOURCE_DATE_EPOCH` specification, revision 1.1 (2017-11-27), RFC 2119
  requirements and the clamping rule
- [`_docs/stable_inputs.md`][rb-stable] — filesystem order, locale-dependent
  collation, the `find | LC_ALL=C sort` recipe
- [`_docs/stripping_unreproducible_information.md`][rb-strip] — why metadata is
  stripped rather than recorded
- [GNU tar manual § 8.4, "Making tar Archives More Reproducible"][gnutar-repro]
  — tar's own definition of "reproducible", the C-locale requirement, `gzip -n`
- [`strip-nondeterminism`][snd-repo] 1.15.1 — the handler table
  ([`StripNondeterminism.pm`][snd-main]) and the per-format normalizers:
  [`zip.pm`][snd-zip], [`jar.pm`][snd-jar], [`gzip.pm`][snd-gzip],
  [`ar.pm`][snd-ar], [`cpio.pm`][snd-cpio], [`png.pm`][snd-png],
  [`gettext.pm`][snd-gettext]; `SOURCE_DATE_EPOCH` ingestion in
  [`dh_strip_nondeterminism`][snd-dh]
- [PKWARE APPNOTE.TXT][appnote] — § 4.4.1.3 (central-directory order), § 4.4.2
  ("version made by"), § 4.4.6 (MS-DOS 2-second precision), § 4.5.5 (NTFS extra
  field)

Measurements in this page were run locally against GNU tar 1.35, Info-ZIP
`zip`/`zipinfo`, and GNU gzip; the commands are reproduced inline.

<!-- References -->

[nar]: ./nar.md
[git]: ./git-objects.md
[oci]: ./oci-layers.md
[index]: ./index.md
[fso]: ./concepts.md#file-system-object-fso
[rb-archives]: https://reproducible-builds.org/docs/archives/
[rb-stable]: https://salsa.debian.org/reproducible-builds/reproducible-website/-/blob/3eacf8758a18aa4d070e292f09f104f0d6106650/_docs/stable_inputs.md
[rb-strip]: https://salsa.debian.org/reproducible-builds/reproducible-website/-/blob/3eacf8758a18aa4d070e292f09f104f0d6106650/_docs/stripping_unreproducible_information.md
[sde-spec]: https://reproducible-builds.org/specs/source-date-epoch/
[gnutar-repro]: https://www.gnu.org/software/tar/manual/html_section/Reproducibility.html
[appnote]: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
[snd-repo]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism
[snd-readme]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/README
[snd-main]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/lib/File/StripNondeterminism.pm
[snd-zip]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/lib/File/StripNondeterminism/handlers/zip.pm
[snd-jar]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/lib/File/StripNondeterminism/handlers/jar.pm
[snd-gzip]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/lib/File/StripNondeterminism/handlers/gzip.pm
[snd-ar]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/lib/File/StripNondeterminism/handlers/ar.pm
[snd-cpio]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/lib/File/StripNondeterminism/handlers/cpio.pm
[snd-png]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/lib/File/StripNondeterminism/handlers/png.pm
[snd-gettext]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/lib/File/StripNondeterminism/handlers/gettext.pm
[snd-dh]: https://salsa.debian.org/reproducible-builds/strip-nondeterminism/-/blob/904281367bd7fbc34a0831a28dd40457b6753c1c/bin/dh_strip_nondeterminism
