# Reproducibility & Non-Determinism Detection (Theme)

_Determinism_ is a property of an action: run it twice on the same declared inputs
and get the same bytes. _Reproducibility_ is a property of a pair of runs: whatever
differed — clock, path, ordering, host — did not reach the output. A build system
can only test the second, one axis at a time. What it can build is narrower: an
environment small enough that variance has nowhere to enter, knobs that make the
rest expressible, and a check that turns a silent difference into an error.

**Last reviewed:** November 3, 2026

| Field      | Value                                                                                          |
| ---------- | ---------------------------------------------------------------------------------------------- |
| Category   | Theme — cross-cutting; no single system                                                        |
| Question   | Which inputs leak into output bytes, what fixes each class, and how would anyone find out?     |
| Mechanisms | clock pinning and clamping, prefix maps, output canonicalisation, seeded names, order freezing |
| Systems    | Nix, Bazel, Buck2, BuildKit, BitBake, Meson, GNU Make, tup, Rattle                             |
| Vocabulary | [concepts] — _rebuilder_, _trace_, _shallow build_; this page does not redefine them           |

> [!NOTE]
> Scope is the **build system's** side: what it controls, what it asks of actions,
> what it can detect. Archive byte layouts have their own page
> ([reproducible-archives]). Catalog conclusions are marked **catalog inference**.

## Overview

### What it solves

Reproducibility is an audit channel: "identical binary packages are always generated
from a given source", so a rebuild exposes tampering ([sde-spec]). For a cache, a
key licenses reuse only if the bytes are a function of the key. [concepts] §4
records the paper's weakening — correctness for non-deterministic tasks drops
"from equality to membership in the set of possible results" (JFP §8.3), and for
deep constructive traces non-determinism becomes "an incorrect build" (JFP §8.4,
Figure 12): a Frankenbuild from two runs that never coexisted ([a-la-carte] §5.4).

### Design philosophy

Nix makes determinism the premise of its identity scheme — "The chief design
consideration for the building process is _determinism_" — because "Determinism is
what enables things that once worked to keep working" ([nix-building]). The
reproducible-builds project supplies the neutral formulation — "Ensure stable
inputs. Ensure stable outputs. Capture as little as possible from the environment"
([rb-deterministic]) — plus the reminder that the line is a _choice_: no constant
output is needed across build paths "when the build path is considered part of the
build environment" ([rb-deterministic]). A system claiming more than it varies is
overclaiming.

## How it works — four classes of variance

The project enumerates sixteen "variations" ([rb-env-variations]); this page folds
them into the four axes an engine can act on.

| Class       | Enters as                                                                    | Remedy                                                    | Enforced by                         |
| ----------- | ---------------------------------------------------------------------------- | --------------------------------------------------------- | ----------------------------------- |
| **Time**    | `__DATE__`/`__TIME__`, archive mtimes, build IDs, OCI `created`              | `SOURCE_DATE_EPOCH` + clamping, output canonicalisation   | compiler, archiver, exporter, store |
| **Place**   | paths in debug info and `__FILE__`, `$HOME`, hostname, locale, `umask`, `TZ` | prefix maps, cleared environment, fixed build directory   | driver flags, sandbox, store        |
| **Order**   | directory enumeration, locale collation, parallel log interleaving           | sort under `LC_ALL=C`, stable-input rules, control build  | build file, engine, harness         |
| **Entropy** | seeded symbol names, temp names, PIDs, uninitialised memory, UUIDs           | per-file seed, zeroed padding, deterministic archive mode | compiler, allocator, archiver       |

**Time.** `__DATE__`/`__TIME__` embedded in compiled code is the canonical failure
([rb-env-variations]); GCC warns on all three macros because they "might prevent
bitwise-identical reproducible compilations" ([gcc-wdate]). Clamping is the other
half — timestamps specific to one execution "MUST use a timestamp no later than the
value of this variable" ([sde-spec]). Nix canonicalises _after_ the action instead —
"timestamps and permissions are canonicalised" ([nix-building]) — as does BuildKit's
`rewrite-timestamp=true`, which applies the epoch to every exported file
([buildkit-repro]).

**Place.** Paths leak through debug info, `__FILE__` in assertions, generated
Makefiles, and any tool recording its invocation. GCC rewrites recorded references
as if the files "resided in directory _new_ instead" — "used to make reproducible
builds that are location independent" ([gcc-ffpm]). The WIP
`BUILD_PATH_PREFIX_MAP` spec generalises that into producer/consumer roles for tools
the build system does not own, and warns that the value "MUST NOT be saved as-is
into any output meant to form part of a reproducible binary artefact" ([bppm-spec]).
Nix removes the axis structurally — environment rebuilt from the derivation, `PATH`
set to `/path-not-set`, `HOME` to `/homeless-shelter`, a fresh working directory at a
deterministic path ([nix-building]).

**Order.** "Most filesystems do not guarantee that listing files in a directory
always results in the same order", and the sort must not depend on locale
([rb-stable-inputs]). GNU Make's `$(wildcard)` sorts by the ambient locale, so one
tree yields different object order under a different `LC_ALL`; parallel execution
reorders logs and `md5sums` listings the same way ([rb-env-variations]). Make turns
the hazard into a test — `--shuffle` reorders goals and prerequisites with a seed
([gnumake] §3) — while tup updates single-threaded, "since no locking is done"
([tup] §3).

**Entropy.** The honest fix is to stop using a random number, which compilers cannot
quite do: `-frandom-seed` supplies the seed "used in place of random numbers in
generating certain symbol names", so output can be "reproducibly identical" — with
the constraint that makes it a key, "the string should be different for every file
you compile" ([gcc-frandom]). Nixpkgs derives it from the output path: "the last part
of the out path" is deterministic across rebuilds of one derivation, does not "easily
collide with other builds", and is truncated "so that it cannot cause reference
cycles" ([nixpkgs-seed]). **Catalog inference:** seeding from `$out` couples the
object to the output path — right for input addressing, wrong for a content-addressed
rebuild, where the seed must follow the derivation and not a provisional path. The
rest of the class has no flag — memory addresses in `repr()`, PIDs in archive
headers, uninitialised padding, per-build UUIDs ([rb-env-variations]) — except
`ar`'s deterministic mode ([ar-man]).

## Detection, as documented

| Tool                  | Axes it induces                                                | Compares                            |
| --------------------- | -------------------------------------------------------------- | ----------------------------------- |
| `nix build --rebuild` | none — same environment                                        | store paths, bit for bit            |
| `reprotest`           | 16 named variations (time, path, user, locale, umask, CPUs, …) | artifacts via `diffoscope`          |
| Meson `reprotest.py`  | build directory, plus a second full build                      | output tree; intermediates optional |

**Nix ships determinism testing as a verb:**

> "This option allows you to check whether a derivation is deterministic. It
> rebuilds the specified derivation and checks whether the result is
> bitwise-identical with the existing outputs, printing an error if that's not the
> case."
>
> — Nix, [`nix-store --realise --check`][nix-check]

`nix build --rebuild` is the same mode in the newer CLI
([`build.cc`][nix-rebuild-flag]), and `-K` keeps the diverging output as
`/nix/store/<name>.check` ([nix-check]). The check is **opt-in**, not part of a
normal build; and though the protocol carries the verdict (`isNonDeterministic`, a
`NotDeterministic` status), the local daemon has no repeat driver in this checkout —
a grep for `buildRepeat` finds only "hasn't worked for ages anyway". **Catalog
inference:** the affordance exists for remote builders; locally you must ask.

**`reprotest` is the general instrument** — it "builds the same source code twice in
different environments, and then checks the binaries produced by each build for
differences" ([reprotest]) — implementing the sixteen axes with `faketime`,
`unshare`, `sudo` and `disorderfs`. One choice encodes an assumption about the
engine: "The control build uses only 1 CPU in order to try to reduce
nondeterminism that might exist due to multithreading" ([reprotest]).
**`disorderfs` is the variance source** — an overlay FUSE filesystem that "can
randomize the order in which directory entries are read", "useful for detecting
non-determinism in the build process" ([disorderfs]) — preferring a _reproducible_
perturbation, `--sort-dirents` over `--shuffle-dirents`, "to ensure that any
difference between builds is deterministic in itself" ([disorderfs]).

## Where each system actually stands

| System   | Determinism is               | Knob it provides                                                  | Check it ships | On divergence                               |
| -------- | ---------------------------- | ----------------------------------------------------------------- | -------------- | ------------------------------------------- |
| Nix      | the premise of identity      | cleared env, sandbox paths, output canonicalisation               | `--check`      | error on check; silent acceptance otherwise |
| Bazel    | an author obligation         | `--stamp` split into stable/volatile status                       | none built in  | nothing — the action cache already answered |
| Buck2    | the environment's obligation | none specific                                                     | none           | nothing — DICE's theorem ignores computes   |
| BuildKit | a mode of the exporter       | `SOURCE_DATE_EPOCH`, `rewrite-timestamp`, `compatibility-version` | none           | a different digest, silently                |
| BitBake  | a property of the recipe     | none in the engine                                                | none           | a wrong cache entry, silently               |
| Meson    | a project property           | none specific                                                     | `reprotest.py` | a diff, on demand                           |
| GNU Make | not modelled                 | `--shuffle` for order                                             | `--shuffle`    | an intermittent failure                     |
| Rattle   | a per-command assumption     | `HashNonDeterministic` marks outputs                              | none           | the marked output is not compared           |

**Nix** claims it structurally: hash-as-identity, no default search path, a
store-only view, environment rebuilt from scratch ([nix-thesis] §2, [nix-building]).
Unsandboxed builds still expose "arbitrarily other store objects", defended only by
store paths being "relatively unpredictable" ([nix-building]). Validity, not
content, gates reuse, so ordinary builds compare nothing — **catalog inference:**
that is why `--check` is opt-in, and why a non-deterministic derivation is
indistinguishable from a deterministic one until two machines share a cache. The
docs admit the question is unanswerable — no way to audit a build trace entry
"except for by performing the build again from scratch" ([nix-build-trace]) — and
the protocol says so in a field: a false `isNonDeterministic` "does not mean the
build is deterministic, just that we don't have evidence" ([nix-result-schema]).

Current upstream also states the builder filesystem more strictly than the
thesis-era implementation: only the input closure should be exposed, outputs
must not pre-exist, the working directory is a fresh deterministic `/build`
inside the sandbox, basic devices/loopback/minimal identities are supplied,
and the environment is cleared before derivation variables plus fixed
`PATH=/path-not-set` and `HOME=/homeless-shelter` are installed
([nix-building]). Output processing then normalises permissions/timestamps
and scans outputs by input store-path digests to register references. That
narrows, but does not eliminate, tool-internal nondeterminism: randomness,
concurrency order, CPU dispatch, and reading permitted device/proc state can
still vary inside a perfectly constructed view.

**Bazel** treats hermeticity as isolation plus source identity and names the gap:
"there's no way to stop an action developer from doing something like introducing a
nondeterministic process as part of their action" ([bazel-artifact]). It names among
the _sources_ of non-hermeticity "Actions or tooling that create files
non-deterministically, usually involving build IDs or timestamps", and offers a
procedure rather than a check: run twice and "compare a hash of the file contents"
([bazel-hermeticity]). Its one _mechanism_ for time is deliberate unsoundness —
`--stamp` routes `BUILD_TIMESTAMP` into `volatile-status.txt`, and:

> "**Bazel pretends that the volatile file never changes**. In other words, if the
> volatile status file is the only file whose contents has changed, Bazel will not
> invalidate actions that depend on it."
>
> — Bazel [`user-manual.mdx`][bazel-user-manual]

because stable status "should not contain things like timestamps, because they
change all the time" ([bazel-user-manual]). Two builds of one key thus emit
different bytes — which is why authors are told tools "should not write timestamps
to their output, and they should use stable ordering for sets and maps"
([bazel-genrule]), and why remote execution demands the property: "Outputs must be
completely deterministic so that each worker can trust the results it receives"
([bazel-distributed]).

**Buck2** puts reproducibility outside the engine's contract: DICE's theorem "is
unconditional: it assumes nothing about the caller" ([buck2] §1). **BuildKit**
assembles it from three versioned knobs — pinned sources, `SOURCE_DATE_EPOCH`, and
`compatibility-version`, which "pins digest-affecting image assembly behavior"
([buildkit-repro]) — so a rebuild months later must pin which output format it
wants. **BitBake** verifies only that its _metadata_ is reproducible — `_build_data`
fails loudly if the basehash moved ([bitbake] §2) — and a search of the clone's
`doc/` and `lib/` finds no `SOURCE_DATE_EPOCH` handling, so output reproducibility
is a metadata-layer concern there (**catalog inference**); its contribution is the
expanded `run.do_<task>` script, "a reproducibility asset, but a debugging aid
rather than a boundary" ([bitbake] §5).

## Reproducibility and the rebuilder

Whether a divergence is fatal depends on the trace shape ([concepts] §3):

| Trace shape                         | A divergent output is…                                        | Systems                     |
| ----------------------------------- | ------------------------------------------------------------- | --------------------------- |
| Verifying (outputs on disk)         | invisible: metadata matches, so the build is skipped          | Bazel local, BuildKit local |
| Constructive (bytes in the cache)   | a wrong answer for whoever fetches the first writer's bytes   | Bazel remote, shared caches |
| Deep constructive (terminal inputs) | a different store path (CA) or a wrong path (input-addressed) | Nix, Buck, cloud models     |
| None (no key at all)                | re-executed every time, so never observable                   | Make, tup, Sparkles today   |

**Construction hides, verification shows**: a verifying trace never trusts bytes it
did not produce, so a divergent action merely rebuilds ([concepts] §3).
**Shared caches hand the first writer the pen**: BitBake's hash-equivalence server
repairs that by mapping a rebuilt-but-identical output to the same `unihash`
([bitbake] §2). **Content addressing converts wrong into different**: an impure Nix
build "simply lands at a different content address" ([nix-thesis] §2), provided
outputs keep one address across runs and provisional paths ([nix-ca-determinism]);
the thesis reports only a prototype, and [sandstone] and [nix-dynamic-derivations]
survey what shipping it has taken since.

## Correctness risks

- **Clamping removes the observation, not the dependency.** Bytes become stable
  without the action ceasing to read the clock; the epoch is a rewrite target, not a
  ban on `time(2)`, and Nix canonicalises mtimes _after_ the builder exits
  ([nix-building]). **Catalog inference:** that is why timestamps and randomness are
  separate variations — one tool can fix the first and mask the second
  ([rb-env-variations]).
- **Normalisation fixes metadata, not content.** `ar D` zeroes headers ([ar-man]);
  `strip-nondeterminism` exists for when "the build process itself cannot be made
  deterministic" (quoted in [reproducible-archives]); entry order in `ar` and cpio
  has no post-hoc fix, and compressed streams cannot be re-derived
  ([reproducible-archives]).
- **A green check is evidence, not proof.** Sixteen axes on one host cannot rule out
  a seventeenth, and `reprotest`'s manual documents axes that misbehave rather than
  measure — `faketime` "sometimes causes weird and hard-to-diagnose problems"
  ([reprotest]).
- **Caches hide the defect they are meant to expose.** A warm local cache never runs
  the divergent action; a compiler cache returns the first build's bytes; a remote
  cache means the second machine never runs it. **Catalog inference:** a determinism
  check must run cold and unshared, or it tests the cache.
- **Some knobs couple identity to the shuffle.** `-frandom-seed` must differ per file
  ([gcc-frandom]); a prefix map rewrites recorded references only ([gcc-ffpm]); an
  epoch derived from a generated file is unstable ([nixpkgs-sde]).

## Strengths

- **The cheap wins are cheap**: `-Wdate-time` and a per-file `-frandom-seed` remove
  two entropy classes in one line each ([gcc-wdate], [gcc-frandom]); `LC_ALL=C` plus
  a sort removes the commonest ordering bug ([rb-stable-inputs]).
- **The strongest systems say what they do not know** ([nix-result-schema],
  [bazel-user-manual]) — a claim without a check is marketing.

## Weaknesses

- **The expensive part is the perimeter**: paths, hosts, locales and users are the
  bulk of the variations ([rb-env-variations]), and clearing the environment costs
  more than every seed flag combined.
- **Almost nothing is verified by default**: only Nix ships a check and it is opt-in
  ([nix-check]); elsewhere the evidence is a procedure a human must remember.

## Key design decisions and trade-offs

| Decision                              | Rationale                                          | Trade-off                                                  |
| ------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------- |
| Pin the clock instead of banning it   | One integer fixes every tool that reads it         | Clamping hides that the action still reads the clock       |
| Canonicalise outputs after the build  | Works for tools nobody will patch                  | Metadata only; content non-determinism survives            |
| Clear the environment                 | Removes `HOME`, `PATH`, locale, user at the source | Unsandboxed builds still see the whole store               |
| Split status into stable and volatile | Keeps stamping from invalidating every action      | Deliberately different bytes under one key                 |
| Make the check opt-in                 | Rebuilds are expensive; most users never ask       | Non-determinism invisible until two machines share a cache |

## Sparkles relevance

Sparkles has already met this problem once, and the fix is in the tree:

> "`install` without `-p` stamps the destination with the CURRENT time, and zip
> records that mtime in every local file header — so the APK differed on every
> rebuild and `nix build --rebuild` reported the derivation as
> non-deterministic."
>
> — [`nix/packages/android/build-apk.nix`][sparkles-apk]

The repair is a clamp to `$SOURCE_DATE_EPOCH` before zipping, noting that nixpkgs
sets it to 1980-01-01, "which is also zip's own floor, so nothing is silently
rounded" ([sparkles-apk]) — the same floor `strip-nondeterminism` works around
([reproducible-archives]). A divergence nobody would have noticed, a check that
named it, a knob that fixed it.

On the engine side there is nothing to weaken yet: `sparkles.build_primitives.task`
has no store and no key — `TaskId` is a stable text identity and `toHash` hashes
that text, not any input
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`).
Every admitted task runs, so divergence is re-executed rather than reused. When a
cache arrives, determinism becomes load-bearing, and [semantic-caching] owns the
key-design half. Three mechanics port now:

- **Plumb `SOURCE_DATE_EPOCH` into every archiving or install step.** Anything that
  writes file metadata from a clock needs the clamp at the seam.
- **Lint the source, not the binary.** D's lexer already rewrites `__DATE__`,
  `__TIME__` and `__TIMESTAMP__` into string literals ([compile-time-execution]),
  and `sparkles.dmd_fmt` tests exactly that
  ([`spine.d`](../../../libs/dmd-fmt/src/sparkles/dmd_fmt/spine.d)) — a check with
  no syscall layer and no rebuild.
- **Add a `--check`-shaped mode to `ci` before adding a cache**, and let a task be
  marked "not compared" — Rattle's `HashNonDeterministic` shape ([rattle] §2) rather
  than a global "we are reproducible" claim. State the perimeter in the same breath:
  Sparkles' tasks see the ambient environment, the `dub` cache and the Nix store,
  and until that sentence exists "reproducible" is not a property to assert.

## Sources

In-corpus pages synthesized: [concepts] (§3 trace shapes, §4 correctness),
[a-la-carte], [bazel], [buck2], [buildkit], [bitbake], [meson], [gnumake], [tup],
[rattle], [nix-thesis], [semantic-caching], [reproducible-archives],
[compile-time-execution], [sandstone], [nix-dynamic-derivations]. Primary sources,
from clones under `$REPOS/build-systems-research/src/`:

- Nix `1ed54a0fd62da96d4f5e9c806555861e46f65341`: [`building.md`][nix-building],
  [`build-trace.md`][nix-build-trace], [`content-address.md`][nix-ca-determinism],
  [`build-result-v1.yaml`][nix-result-schema], [`realise.md`][nix-check],
  [`src/nix/build.cc`][nix-rebuild-flag].
- Bazel `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`: [`hermeticity.mdx`][bazel-hermeticity],
  [`distributed-builds.mdx`][bazel-distributed], [`artifact-based-builds.mdx`][bazel-artifact],
  [`user-manual.mdx`][bazel-user-manual], [`be/general.mdx` 8.5.1][bazel-genrule].
- BuildKit `c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5`: [`build-repro.md`][buildkit-repro].
- Nixpkgs `327cb14b5075c016abc85c2e9b84faae5e6e53ae`: [`reproducible-builds.sh`][nixpkgs-seed],
  [`set-source-date-epoch-to-latest.sh`][nixpkgs-sde].
- Meson `27f69b22e5fe403d3ec5788216adaa85046d0e8f`: [`reprotest.py`][meson-reprotest].

<!-- References -->

[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[buildkit]: ./buildkit.md
[bitbake]: ./bitbake.md
[meson]: ./meson.md
[gnumake]: ./gnumake.md
[tup]: ./tup.md
[rattle]: ./rattle.md
[nix-thesis]: ./nix-thesis.md
[sandstone]: ./sandstone.md
[nix-dynamic-derivations]: ./nix-dynamic-derivations.md
[semantic-caching]: ./semantic-caching.md
[compile-time-execution]: ./compile-time-execution.md
[reproducible-archives]: ../content-addressing/reproducible-archives.md
[sde-spec]: https://reproducible-builds.org/specs/source-date-epoch/
[bppm-spec]: https://reproducible-builds.org/specs/build-path-prefix-map/
[rb-deterministic]: https://reproducible-builds.org/docs/deterministic-build-systems/
[rb-env-variations]: https://reproducible-builds.org/docs/env-variations/
[rb-stable-inputs]: https://reproducible-builds.org/docs/stable-inputs/
[reprotest]: https://pypi.org/project/reprotest/
[disorderfs]: https://manpages.debian.org/unstable/disorderfs/disorderfs.1.en.html
[gcc-wdate]: https://gcc.gnu.org/onlinedocs/gcc/Warning-Options.html#index-_002dWdate_002dtime
[gcc-frandom]: https://gcc.gnu.org/onlinedocs/gcc/Developer-Options.html#index-_002dfrandom_002dseed
[gcc-ffpm]: https://gcc.gnu.org/onlinedocs/gcc/Overall-Options.html#index-_002dffile_002dprefix_002dmap
[ar-man]: https://sourceware.org/binutils/docs/binutils/ar-cmdline.html
[nix-building]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/store/building.md
[nix-build-trace]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/store/build-trace.md
[nix-ca-determinism]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/store/derivation/outputs/content-address.md
[nix-result-schema]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/protocols/json/schema/build-result-v1.yaml
[nix-check]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/command-ref/nix-store/realise.md
[nix-rebuild-flag]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/nix/build.cc
[bazel-hermeticity]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/basics/hermeticity.mdx
[bazel-distributed]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/basics/distributed-builds.mdx
[bazel-artifact]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/basics/artifact-based-builds.mdx
[bazel-user-manual]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/docs/user-manual.mdx
[bazel-genrule]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/versions/8.5.1/reference/be/general.mdx
[buildkit-repro]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/build-repro.md
[nixpkgs-seed]: https://github.com/NixOS/nixpkgs/blob/327cb14b5075c016abc85c2e9b84faae5e6e53ae/pkgs/build-support/setup-hooks/reproducible-builds.sh
[nixpkgs-sde]: https://github.com/NixOS/nixpkgs/blob/327cb14b5075c016abc85c2e9b84faae5e6e53ae/pkgs/build-support/setup-hooks/set-source-date-epoch-to-latest.sh
[meson-reprotest]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/scripts/reprotest.py
[sparkles-apk]: ../../../nix/packages/android/build-apk.nix
