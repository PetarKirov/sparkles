# linuxdeploy and appimagetool (AppImage backend primitives)

`linuxdeploy` stages and repairs an AppDir; `appimagetool` validates and finalizes that
AppDir into an AppImage. Together they are a concrete producer pipeline, not the
AppImage format itself and not a release repository or updater.

| Field                   | linuxdeploy                                                                 | appimagetool                                                            |
| ----------------------- | --------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Language                | C++                                                                         | C and C++                                                               |
| License                 | MIT                                                                         | MIT                                                                     |
| Repository              | [linuxdeploy/linuxdeploy][linuxdeploy-repo]                                 | [AppImage/appimagetool][appimagetool-repo]                              |
| Documentation           | [Pinned README/user guide][linuxdeploy-readme]                              | [Pinned README/CLI reference][appimagetool-readme]                      |
| Reviewed SHA/version    | [`a9f929ff`][linuxdeploy-sha] (`continuous`)                                | [`8c8c91f7`][appimagetool-sha] (`1.9.1`)                                |
| Primary input           | Executables, libraries, desktop metadata, icons, existing AppDir            | Complete AppDir                                                         |
| Primary output          | Populated AppDir; output plug-ins may add formats                           | Type-2 AppImage and optional `.zsync` file                              |
| Category                | Staging/dependency deployment primitive                                     | AppImage format finalizer                                               |
| Supported hosts/targets | Linux AppDir targets; upstream also build-tests the tool on FreeBSD         | Linux; `i686`, `x86_64`, `armhf`, `aarch64` runtimes in reviewed source |
| OSS/paid boundary       | Open source; CI runners, key custody, hosting, and publication are external | Open source; same external boundaries                                   |

**Last reviewed:** July 12, 2026

> [!NOTE]
> See [AppImage][appimage] for the portable-file contract, compatibility model,
> sandbox absence, and update-information semantics. This page assigns only observed
> implementation behavior to these tools.

## Overview

### What it solves

The format requires an AppDir, but discovering ELF dependencies, copying libraries,
fixing relative loader paths, and wiring desktop metadata is repetitive. linuxdeploy's
README states its scope precisely:

> “linuxdeploy is designed to be an AppDir maintenance tool.” —
> [linuxdeploy `README.md`][linuxdeploy-readme]

Once staging is complete, appimagetool supplies the lower-level finalization step:

> “`appimagetool` is used to generate an AppImage from an existing `AppDir`.” —
> [appimagetool `README.md`][appimagetool-readme]

### Design philosophy

The pipeline separates a mutable, inspectable filesystem tree from the immutable output.
linuxdeploy has a core for generic ELF/desktop staging and subprocess plug-ins for
framework-specific bundling or output formats. appimagetool deliberately assumes staging
is already correct; it validates required roots, chooses a runtime, creates SquashFS,
embeds metadata/signatures, and emits the final file. Release planning, compatibility
policy, publication, and refresh remain outside both tools.

## How it works

A typical pipeline is:

```bash
linuxdeploy \
  --appdir AppDir \
  --executable build/example \
  --desktop-file packaging/example.desktop \
  --icon-file packaging/example.png

ARCH=x86_64 appimagetool \
  --runtime-file runtime-x86_64 \
  --updateinformation 'gh-releases-zsync|OWNER|REPO|latest|Example-*-x86_64.AppImage.zsync' \
  AppDir Example-x86_64.AppImage
```

linuxdeploy's [`AppDir` implementation][appdir-source] calls `ldd`-style dependency
tracing through `ElfFile::traceDynamicDependencies`, filters a generated system-library
excludelist plus `LINUXDEPLOY_EXCLUDED_LIBRARIES`, copies selected libraries below
`usr/lib*`, and rewrites relative `RPATH` with `patchelf`. Its
[`AppDirRootSetup`][root-setup] links the selected desktop file and icon into the AppDir
root and creates or preserves `AppRun`.

Plugins are separate executables discovered beside linuxdeploy or on `PATH`.
Input/bundling plugins add framework resources; output plugins consume the completed
AppDir. `--output appimage` commonly delegates finalization to an AppImage output plugin
which in turn invokes appimagetool; this is layering, not an in-core format encoder.

appimagetool's [`appimagetool.c`][appimagetool-source] validates desktop/icon/AppStream
inputs, detects one supported architecture or requires `ARCH`, obtains a runtime, invokes
`mksquashfs`, writes update information into `.upd_info`, optionally signs through
GPGME, and invokes `zsyncmake` after signing. Version `1.9.1` downloads a current runtime
from `AppImage/type2-runtime` unless `--runtime-file` pins local bytes
[source-verified: [`fetch_runtime`][fetch-runtime]].

## Analysis spine

### Input and staging

linuxdeploy accepts an AppDir plus repeatable executables, libraries, desktop files,
icons, arbitrary files/directories, and plug-ins. `createBasicStructure`,
`deployExecutable`, `deployLibrary`, `deployDesktopFile`, `deployIcon`, and
`deployDependenciesForExistingFiles` expose the staged operations in
[`src/core/appdir.cpp`][appdir-source]. The test suite exercises structure, copying,
symlinks, ELF discovery, and dependency deployment in [`test_appdir.cpp`][appdir-tests].

appimagetool consumes the result rather than resolving application dependencies. The
reviewed implementation requires a desktop entry, derives or rewrites `.DirIcon` from
its icon, and warns about missing AppStream metadata. Although the format requires
`AppRun`, this implementation does not explicitly validate it before packing. That
boundary is important: successful finalization proves neither every AppDir invariant nor
that every target runtime dependency was bundled correctly.

### Outputs and target matrix

linuxdeploy's native output is an AppDir. Output plugins can produce AppImage or other
bundles, so credit belongs to the selected plugin/backend. appimagetool emits one
AppImage whose runtime architecture must agree with its payload; reviewed architecture
detection recognizes `i686`, `x86_64`, `armhf`, and `aarch64` in
[`appimagetool.c`][appimagetool-source]. Cross-staging can work with suitable target ELF
files and tools, but executing and compatibility-testing the result remains a target-host
or emulator job.

### Metadata and dependencies

linuxdeploy reads desktop `Exec` and `Icon` keys, stages icons into freedesktop paths,
and generates root links. ELF dependencies are discovered transitively, except files on
its excludelist or caller exclusions. That heuristic is not a package dependency model:
`dlopen` plug-ins, data-driven loaders, language packages, GPU libraries, and external
commands may require explicit staging or plugins. appimagetool embeds optional update
information and uses the desktop name/architecture for default naming, but it does not
invent a package-manager identity.

### Installation, upgrade, and uninstall

Neither tool installs on end-user systems. Their artifact inherits AppImage's run-in-place,
replace-or-coexist update, and delete-to-uninstall model. linuxdeploy plug-ins execute at
build time; appimagetool's generated runtime executes at launch. Desktop integration and
cleanup are handled by the payload or separate integrators, not by producer state retained
on the target.

### Signing and platform trust

appimagetool `--sign` hashes the current image bytes and only afterward embeds an
OpenPGP signature and public key using GPGME; its hashing routine does not itself locate,
exclude, or zero the reserved ELF sections. A first signature therefore relies on the
producer having created those sections as zero-filled, as required by the format;
re-signing behavior needs separate validation. `--sign-key` selects a key. The reviewed
README offers `APPIMAGETOOL_SIGN_PASSPHRASE` for noninteractive CI
[appimagetool-readme], but an environment-carried passphrase expands the secret-exposure
surface and should be scoped to an isolated signing job. linuxdeploy does not sign.
Neither tool distributes the verification key or makes host Linux enforce a publisher
identity.

### Publication and discovery

Neither project is a repository client or release publisher. appimagetool can create a
`.zsync` sidecar when update information is present and `zsyncmake` is available; the
release pipeline must upload both under names/URLs matching the embedded transport.
GitHub-specific inference in [`appimagetool.c`][appimagetool-source] is convenience
metadata generation, not publication or channel promotion.

### Updates and release channels

`--updateinformation` writes the format string; `--file-url` controls the URL written by
`zsyncmake`. appimagetool runs `zsyncmake` **after** signing, so its block hashes describe
the final signed bytes [source-verified: [`appimagetool.c`][appimagetool-source]]. A
GitHub Actions or GitLab environment can trigger inferred update strings, but explicit
release configuration is easier to audit. Channels are filename/release conventions;
these tools provide no rollback database, staged rollout, mandatory refresh, or promotion
transaction.

### Automation and CI

Both repositories build/test in Linux CI. linuxdeploy's
[`main.yml`][linuxdeploy-ci] builds the tool and runs CTest; its source includes unit tests
for `AppDir`, ELF, utilities, and plugin mechanics. appimagetool's
[`build.yml`][appimagetool-ci] builds architecture artifacts in containers. A consumer CI
should pin exact tool and runtime hashes, avoid release-time network resolution, validate
`desktop-file-validate`, inspect the SquashFS tree, test launch across baseline images,
and upload only after checksum/signature/SBOM generation succeeds.

### Supply-chain evidence and reproducibility

linuxdeploy's generated excludelist and host `ldd` resolution make staging sensitive to
the build image; pin that environment and diff an inventory of staged files. appimagetool
passes `-mkfs-time 0` when `SOURCE_DATE_EPOCH` is absent and otherwise leaves timestamp
handling to `mksquashfs` [source-verified: [`appimagetool.c`][appimagetool-source]], but
reproducibility also needs fixed runtime
bytes, compressor/options, ownership, modes, file order, and signing policy. Its default
network fetch targets a moving `continuous` runtime, so `--runtime-file` is the appropriate
hermetic release path. linuxdeploy itself also generates its exclusion list from the
moving `probonopd/AppImages/master/excludelist`, and its CI clones an output plug-in
without a ref; a release build must vendor or digest-pin those inputs rather than assuming
a pinned linuxdeploy commit closes the graph ([`generate-excludelist.sh`][excludelist],
[`ci/build.sh`][ci-build]). OpenPGP signatures authenticate bytes but do not substitute
for provenance or an SBOM.

### Extensibility and UX

linuxdeploy's CLI and executable plugin protocol let framework specialists own Qt, GTK,
GStreamer, or language-specific deployment without growing the core. The trade-off is a
larger executable supply chain and version-skew between bundled and adjacent plugins;
the README explicitly says adjacent newer plugins take precedence
[linuxdeploy-readme]. appimagetool has a smaller, focused CLI and recommends higher-level
tools for most users. Together they fit CI well when the release system makes every
implicit download and plugin explicit.

## Strengths

- Clean separation between inspectable staging and immutable finalization.
- linuxdeploy automates recursive ELF copying, `RPATH`, desktop entries, icons, and
  AppDir root setup.
- Plugin boundary accommodates framework-specific deployment and multiple outputs.
- appimagetool supports pinned runtimes, update metadata, OpenPGP signatures, and zsync.
- Checked-in unit tests and CI exercise important staging/finalization mechanics.

## Weaknesses

- Host-derived dependency tracing can miss runtime-loaded dependencies or capture the
  wrong compatibility baseline.
- A moving runtime download is the default unless releases pass `--runtime-file`.
- Build success does not establish cross-distribution execution compatibility.
- Plugins are additional executable dependencies with precedence/version-skew risk.
- Neither tool publishes, promotes, rolls back, manages keys, or supplies a sandbox.
- Environment passphrases are convenient but require careful CI secret isolation.

## Key design decisions and trade-offs

| Decision                          | Rationale                                    | Trade-off                                                   |
| --------------------------------- | -------------------------------------------- | ----------------------------------------------------------- |
| Mutable AppDir before final image | Make staging inspectable and reusable        | Two phases must agree on invariants                         |
| Host ELF tracing plus excludelist | Automate common dependency deployment        | Host-sensitive and incomplete for dynamic loading           |
| Executable plugin protocol        | Decouple framework and output support        | More unpinned executable inputs                             |
| Separate appimagetool finalizer   | Keep format construction focused             | Users need orchestration around both tools                  |
| Runtime auto-download             | Easy first use and architecture selection    | Non-hermetic moving network input                           |
| `--runtime-file` override         | Permit offline and reproducible construction | Release pipeline must curate runtimes                       |
| Sign before `zsyncmake`           | Sidecar describes exact published bytes      | Signing secret required before update metadata finalization |

## Sources

- [linuxdeploy at `a9f929ff`][linuxdeploy-sha], locally reviewed at
  `$REPOS/packaging/linuxdeploy`: [`README.md`][linuxdeploy-readme],
  [`src/core/appdir.cpp`][appdir-source], [`src/core/appdir_root_setup.cpp`][root-setup],
  and [`tests/core/test_appdir.cpp`][appdir-tests].
- [appimagetool `1.9.1` at `8c8c91f7`][appimagetool-sha], locally reviewed at
  `$REPOS/packaging/appimagetool`: [`README.md`][appimagetool-readme],
  [`src/appimagetool.c`][appimagetool-source], signature code, runtime fetcher, and CI.
- Related format contract: [AppImage][appimage].

<!-- References -->

[linuxdeploy-repo]: https://github.com/linuxdeploy/linuxdeploy
[appimagetool-repo]: https://github.com/AppImage/appimagetool
[linuxdeploy-sha]: https://github.com/linuxdeploy/linuxdeploy/tree/a9f929ff0e32d5c4bcb7b5c380adff4802f918ba
[appimagetool-sha]: https://github.com/AppImage/appimagetool/tree/8c8c91f762b412a19f4e8d2c4b35afb98f2d7c81
[linuxdeploy-readme]: https://github.com/linuxdeploy/linuxdeploy/blob/a9f929ff0e32d5c4bcb7b5c380adff4802f918ba/README.md
[appdir-source]: https://github.com/linuxdeploy/linuxdeploy/blob/a9f929ff0e32d5c4bcb7b5c380adff4802f918ba/src/core/appdir.cpp
[root-setup]: https://github.com/linuxdeploy/linuxdeploy/blob/a9f929ff0e32d5c4bcb7b5c380adff4802f918ba/src/core/appdir_root_setup.cpp
[appdir-tests]: https://github.com/linuxdeploy/linuxdeploy/blob/a9f929ff0e32d5c4bcb7b5c380adff4802f918ba/tests/core/test_appdir.cpp
[linuxdeploy-ci]: https://github.com/linuxdeploy/linuxdeploy/blob/a9f929ff0e32d5c4bcb7b5c380adff4802f918ba/.github/workflows/main.yml
[excludelist]: https://github.com/linuxdeploy/linuxdeploy/blob/a9f929ff0e32d5c4bcb7b5c380adff4802f918ba/src/core/generate-excludelist.sh#L19-L21
[ci-build]: https://github.com/linuxdeploy/linuxdeploy/blob/a9f929ff0e32d5c4bcb7b5c380adff4802f918ba/ci/build.sh#L76-L81
[appimagetool-readme]: https://github.com/AppImage/appimagetool/blob/8c8c91f762b412a19f4e8d2c4b35afb98f2d7c81/README.md
[appimagetool-source]: https://github.com/AppImage/appimagetool/blob/8c8c91f762b412a19f4e8d2c4b35afb98f2d7c81/src/appimagetool.c
[fetch-runtime]: https://github.com/AppImage/appimagetool/blob/8c8c91f762b412a19f4e8d2c4b35afb98f2d7c81/src/appimagetool_fetch_runtime.cpp
[appimagetool-ci]: https://github.com/AppImage/appimagetool/blob/8c8c91f762b412a19f4e8d2c4b35afb98f2d7c81/.github/workflows/build.yml
[appimage]: ./appimage.md
