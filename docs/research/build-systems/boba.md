# Fuchsia "Boba" (Bazel in fuchsia.git)

"Boba" is the name used for Fuchsia's next-generation platform build: Bazel becomes the dependency and action engine while GN/Ninja stays
the outer build during migration. No fetched public page uses the name, and it is not a standalone project. Vocabulary is [concepts]'s.

**Last reviewed:** November 2, 2026

> [!WARNING]
> **No source clone was available.** No standalone Boba repository exists, and `boba` has zero hits in the `fuchsia.dev` sitemap and opened in-tree files.
> The integration lives in-tree under `build/bazel/` in the multi-GB `fuchsia.git` (`$REPOS/build-systems-research/MANIFEST.md`), deliberately not cloned.
> This page uses public `fuchsia.dev` pages fetched on 2026-11-02 plus four in-tree files read through Gitiles; it is not a source-code deep-dive.

| Field              | Value                                                                                     |
| ------------------ | ----------------------------------------------------------------------------------------- |
| Language           | Starlark/Bazel rules, GN, Go (`fint`); no single implementation language                  |
| License            | BSD-style per every opened file header; the repo `LICENSE` was not opened                 |
| Repository         | No standalone repo; in-tree at [`fuchsia.googlesource.com/fuchsia`][repo], `build/bazel/` |
| Documentation      | `fuchsia.dev` build pages and [`build/bazel/README.md`][readme]                           |
| Category           | Industry — platform build; a Bazel graph embedded in a GN/Ninja build                     |
| Clone (pinned SHA) | **None.** Read at `77437da1e1819ee26c89f60b43a5b1f6864ec5e8` (2026-11-02) via Gitiles     |

## Overview

Fuchsia's GN/Ninja build was judged unable to guarantee hermetic clean or correct incremental builds, which is why Bazel was adopted ([rfc-0186]).
The migration is end-first: implement **product assembly** in Bazel, then extract components backwards through `fx build`.

> "The goal is to allow defining and building Bazel build targets in `BUILD.bazel`
> files in the platform source tree."
>
> — [`build/bazel/README.md`][readme]

The checkout is "intentionally **NOT** a Bazel workspace yet" ([readme]); `fx set`/`fx gen` synthesize `${BAZEL_TOPDIR}/workspace`,
and Bazel outputs are copied back into GN targets ([migration]).

## How it works

`fint set` runs `gn gen`; `fint build` runs `ninja`. Bazel is reached inside Ninja actions created by GN's `bazel_action()`, which wraps `bazel build`,
copies named outputs into the GN target's directory, and requires inputs declared through `bazel_input_*()` ([bazel-action]). It names the generated
repository `@legacy_ninja_build_outputs`; the README calls it `@gn_targets`.

**Classification.** The composite does not fit one cell of the [concepts] grid. The Bazel half is **restarting scheduler × constructive traces**:
Skyframe reevaluates, restarts on a missing dependency, and the action cache can supply a result. The GN/Ninja half is **topological × verifying
traces**. Boba is the _seam_: early cutoff exists inside Bazel, but one invocation is one coarse Ninja edge.

### Task model & scheduling

Ninja orders GN topologically; Bazel runs each `bazel_action()` as one inner Skyframe build. The seam costs seconds even on a no-op ([migration]),
so RFC-0186 allowed at most a 50% null-build regression ([rfc-0186]).

### Rebuilding & correctness

Bazel keys actions on command plus input digests and can supply outputs; not minimal (restarts redo work) but early cutoff applies.
Ninja sees only mtime/`restat`/`depfile`; the caches stay independent.

### Dependency discovery

Declared, not traced: `BUILD` edges plus `@gn_targets`, fed by `bazel_input_file()`/`bazel_input_directory()` ([readme], [bazel-action]).
The sandbox catches undeclared inputs; GN cannot see Bazel.

### Store & caching

`output_base` sits under the `fx` build directory with writable outputs ([outputs]); `FUCHSIA_BAZEL_DISK_CACHE` outlives `out/`,
is shareable, can be size-capped, and complements RBE ([disk-cache]).

### Hermeticity & provenance

Bazel's Linux sandbox exposes only declared inputs; RFC-0186 priced it at up to 10% of a clean build, with `--spawn_strategy=local` as fallback.
No SLSA/in-toto attestation is documented in the pages opened.

### Distribution

Stock Bazel RBE (`--config=remote`), disk cache as a lower-latency complement ([readme], [disk-cache]); no Fuchsia-specific worker protocol appears.

### Sparkles relevance

Borrow **a foreign engine as one declared node**: an input manifest, a declared output set, and a cache key over them, exactly what `bazel_input_*()` provides.
Two caches without a shared key can disagree about dirtiness.

## Strengths

- End-first migration with an explicit contract, not a big-bang rewrite ([rfc-0186]).
- Keeps `fx`/`fint` workflows stable while the engine underneath changes.
- Hermeticity, early cutoff and RBE arrive with Bazel, not reimplemented.

## Weaknesses

- Two graphs, two caches and two correctness models; the seam costs seconds on a no-op.
- Dual `BUILD.gn`/`BUILD.bazel` definitions invite skew ([migration]).
- Public docs omit provenance, and "Boba" is unattested on `fuchsia.dev`.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                                     | Trade-off                                                               |
| -------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Keep `fx`/`fint` as the frontend             | Preserve workflows through the migration ([rfc-0186])         | Hides two graphs; debugging needs `fx bazel` and boundary knowledge     |
| Synthesize the workspace under the build dir | `fx clean` owns the lifecycle; source root stays non-Bazel    | Extra generation step; unpredictable output paths ([outputs])           |
| Wrap each Bazel invocation as one GN action  | GN remains the spine; post-build clients still see GN outputs | Seconds per invocation; no inner incrementality across the seam         |
| Adopt Bazel despite sandbox cost             | Hermetic cleans, correct increments, RBE, early cutoff        | Up to ~10% clean-build overhead unless cache/RBE repays it ([rfc-0186]) |

## Sources

- Public docs: [RFC-0186][rfc-0186] (reviewed 2022-08-29), [migration
  guidelines][migration] (updated 2025-03-06), [build overview][overview], [disk
  cache][disk-cache], [build outputs][outputs], [project layout][layout], and the
  [sitemap][sitemap] checked for `boba`.
- In-tree at `77437da1e1819ee26c89f60b43a5b1f6864ec5e8`: [`build/bazel/README.md`][readme],
  [`build/bazel/bazel_action.gni`][bazel-action], [`build/bazel/toplevel.MODULE.bazel`][module],
  [`tools/integration/fint/README.md`][fint].
- Not opened: the full `fuchsia.git` tree, `build/bazel_sdk/`, `bazel2gn`, internal design docs.

### What a follow-up sparse checkout would verify

A blobless, sparse checkout pinned to `77437da1e1819ee26c89f60b43a5b1f6864ec5e8`
would let `git grep -i boba` / `git log --grep=boba` settle the name and expose
the live seam (`bazel_inputs.gni`, `remote_services.gni`, `shac/`, `warm_up/`),
whether `build/bazel_sdk/` shares rules, and the real `fint` path for Bazel.

```bash
git clone --filter=blob:none --no-checkout https://fuchsia.googlesource.com/fuchsia
git -C fuchsia sparse-checkout set --cone build/bazel build/bazel_sdk \
    tools/integration/fint docs/development/build
git -C fuchsia checkout 77437da1e1819ee26c89f60b43a5b1f6864ec5e8
```

<!-- References -->

[repo]: https://fuchsia.googlesource.com/fuchsia
[readme]: https://fuchsia.googlesource.com/fuchsia/+/77437da1e1819ee26c89f60b43a5b1f6864ec5e8/build/bazel/README.md
[bazel-action]: https://fuchsia.googlesource.com/fuchsia/+/77437da1e1819ee26c89f60b43a5b1f6864ec5e8/build/bazel/bazel_action.gni
[module]: https://fuchsia.googlesource.com/fuchsia/+/77437da1e1819ee26c89f60b43a5b1f6864ec5e8/build/bazel/toplevel.MODULE.bazel
[fint]: https://fuchsia.googlesource.com/fuchsia/+/77437da1e1819ee26c89f60b43a5b1f6864ec5e8/tools/integration/fint/README.md
[rfc-0186]: https://fuchsia.dev/fuchsia-src/contribute/governance/rfcs/0186_bazel_for_fuchsia
[migration]: https://fuchsia.dev/fuchsia-src/development/build/bazel_migration_guidelines
[overview]: https://fuchsia.dev/fuchsia-src/development/build/overview
[disk-cache]: https://fuchsia.dev/fuchsia-src/development/build/bazel_disk_cache
[outputs]: https://fuchsia.dev/fuchsia-src/development/build/bazel_concepts/build_outputs
[layout]: https://fuchsia.dev/fuchsia-src/development/build/bazel_concepts/project_layout
[sitemap]: https://fuchsia.dev/sitemap_0_of_1.xml
[concepts]: ./concepts.md
