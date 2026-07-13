# CPack (CMake / packaging backend)

CPack is CMake's generator-driven backend for turning a CMake install tree into
archives, native packages, and installers; it is not a release control plane.

| Field                   | Value                                                                         |
| ----------------------- | ----------------------------------------------------------------------------- |
| Language                | C++ and CMake language                                                        |
| License                 | BSD-3-Clause                                                                  |
| Repository              | [Kitware/CMake][repo]                                                         |
| Documentation           | [`cpack(1)`][cpack-manual] · [generator reference][generators]                |
| Reviewed source         | [`22fd26b6c44ef5ae36eb6a70324c30776005b239`][reviewed]                        |
| Category                | **Format/backend primitive** integrated with a build system                   |
| Supported hosts/targets | Archives on several hosts; native generators depend on host tools and formats |
| OSS/paid boundary       | Fully open source; no paid CPack execution or distribution tier               |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> **Classification:** CPack stages install rules and dispatches format generators. It
> does not plan a multi-host release, build target binaries, publish release assets or
> repositories, manage channels, or update installed applications. A CI/release system
> must invoke CPack on suitable hosts and carry its outputs through signing and
> publication.

---

## Overview

### What it solves

CPack gives CMake projects one packaging entry point over a deliberately varied set of
backends. Its manual states the abstraction precisely:

> “For each installer or package format, `cpack` has a specific backend, called
> ‘generator’. A generator is responsible for generating the required inputs and
> invoking the specific package creation tools.”
>
> — [`Help/manual/cpack.1.rst`][cpack-manual]

The normal input is not the build directory copied wholesale. `include(CPack)` emits
`CPackConfig.cmake`; a later `cpack` process runs the project's CMake `install()` rules
into a private working tree and hands that tree to one or more generators
([`Modules/CPack.cmake`][cpack-module]). It can also package another configured CMake
project through `CPACK_INSTALL_CMAKE_PROJECTS`, arbitrary directories through
`CPACK_INSTALLED_DIRECTORIES`, or custom install scripts/commands
([`Modules/CPack.cmake`][cpack-module]).

### Design philosophy

The common layer owns install-tree acquisition, common identity, components, output
naming, checksums, and generator dispatch. Format policy remains generator-specific.
`CPACK_PROJECT_CONFIG_FILE` is loaded once per selected generator after
`CPACK_GENERATOR` has been narrowed to that generator, providing an explicit escape
hatch for per-format settings ([`Modules/CPack.cmake`][cpack-module]).

This makes CPack broad but not uniform. `DEB` and `RPM` model distribution metadata;
`WIX`, `NSIS`, `InnoSetup`, and `IFW` invoke installer toolchains; `DragNDrop`,
`productbuild`, and `Bundle` use Apple facilities; `TGZ`, `TXZ`, `ZIP`, and their peers
are archives. The `External` generator can export the staged tree and a JSON description
to a project-supplied packaging script rather than claim every format itself
([`Help/cpack_gen/external.rst`][external]).

## How it works

A minimal integration declares installation destinations before loading CPack:

```cmake
install(TARGETS acme RUNTIME DESTINATION bin)
install(FILES LICENSE DESTINATION share/doc/acme)

set(CPACK_PACKAGE_NAME "acme")
set(CPACK_PACKAGE_VERSION "1.2.3")
set(CPACK_GENERATOR "TGZ;DEB")
include(CPack)
```

The resulting execution graph is:

```text
built project
  -> CMake install rules
  -> <package-directory>/_CPack_Packages/<system>/<generator>/<staged-prefix>
  -> selected generator(s)
  -> archive/package/installer + optional checksum sidecars
```

`cpack -G "TGZ;DEB"` iterates the list, resets `CPACK_GENERATOR` for each pass, loads
any `CPACK_PROJECT_CONFIG_FILE`, and produces each result independently. `-C` selects an
already-built multi-configuration build; the manual explicitly leaves building that
configuration to the caller ([`cpack(1)`][cpack-manual]). Build-system targets such as
`package` are convenience edges to the same backend, not release workflows.

## Analysis dimensions

### Input and staging

The strongest path is a declarative CMake install tree. Relative `install()`
`DESTINATION` values are replayed below CPack's staging prefix; absolute destinations
are ignored by the normal CPack integration ([`Modules/CPack.cmake`][cpack-module]).
Components and component groups can split one logical install graph into selectable or
separate packages through `CPackComponent` ([`Modules/CPackComponent.cmake`][components]).

`CPACK_SET_DESTDIR` changes staging to a `DESTDIR`-style tree for generators that
support it, but generator documentation records exceptions. Inputs are copied into the
working area; CPack is not a dependency scanner that discovers all shared libraries or
runtime resources automatically. `InstallRequiredSystemLibraries` and project install
rules can add such files, but that remains build configuration.

### Outputs and target matrix

The reviewed tree documents these generator families:

| Family                      | Generators / artifacts                          | Practical host boundary                                                                                          |
| --------------------------- | ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Portable/source archives    | `7Z`, `TBZ2`, `TGZ`, `TXZ`, `TZ`, `TZST`, `ZIP` | Broadly portable when archive tools/libraries are available                                                      |
| Linux/Unix packages         | `DEB`, `RPM`, `FreeBSD`, `Cygwin`, `AppImage`   | Require the generator and often native package utilities/runtime assumptions                                     |
| Windows installers/packages | `NSIS`, `NSIS64`, `WIX`, `InnoSetup`, `NuGet`   | WiX/Inno/NSIS capabilities depend on their external toolchains; Windows installers are normally built on Windows |
| macOS artifacts             | `DragNDrop` DMG, `productbuild` PKG, `Bundle`   | Native Apple tools make macOS the realistic and required signing host                                            |
| Framework/extensible        | `IFW`, `External`                               | Require Qt Installer Framework or a caller-supplied script                                                       |

The set compiled into a CPack binary is host-dependent; `cpack --help` is the
authoritative list for that installation ([`cpack(1)`][cpack-manual]). Selecting a
foreign package name is therefore not evidence of hermetic cross-packaging. CPack also
packages bytes already built for the target—it does not cross-compile them.

### Metadata and dependencies

Common variables cover package name/version/vendor, description, homepage, license/readme,
icon, install directory, file name, and components. Native dependency semantics are not
normalized: `CPACK_DEBIAN_PACKAGE_DEPENDS` carries Debian relationship syntax, while
`CPACK_RPM_PACKAGE_REQUIRES` and related pre/post variants carry RPM syntax
([`deb.rst`][deb], [`rpm.rst`][rpm]). Optional dependency inference such as Debian
`dpkg-shlibdeps` or RPM auto-requires is backend- and host-tool-specific.

Upgrade identity is likewise native. WiX exposes stable `CPACK_WIX_UPGRADE_GUID` and an
optional product GUID; Apple and Linux generators map their own identity/version fields
([`wix.rst`][wix]). The common CPack model cannot guarantee equivalent upgrade behavior
across formats.

### Installation, upgrade, and uninstall

CPack constructs artifacts; it does not install or track them. Archive lifecycle is
copy/extract/delete. DEB/RPM/FreeBSD packages delegate file ownership, scripts,
transactions, upgrades, and removal to their package managers. WiX delegates to Windows
Installer; NSIS, Inno Setup, and IFW generate installer-specific uninstall behavior;
PKG delegates to Apple's Installer. Component selection is a package-construction input,
not a cross-format transaction API.

There is no common repair, rollback, downgrade, or uninstall contract. Those properties
must be tested per generated format and identity configuration.

### Signing and platform trust

Signing is mostly generator-specific pass-through, not one CPack trust stage. The
`productbuild` generator passes an identity and keychain to Apple's tool;
`CPACK_IFW_PACKAGE_SIGNING_IDENTITY` configures Qt IFW on macOS; WiX accepts extra tool
flags/extensions and patch sources ([`productbuild.rst`][productbuild],
[`ifw.rst`][ifw], [`wix.rst`][wix]). Other outputs commonly need a separate
post-package signing command.

`CPACK_PACKAGE_CHECKSUM` emits digest sidecars, but a checksum is not a signature,
notarization ticket, repository signature, SBOM, or provenance attestation
([`Modules/CPack.cmake`][cpack-module]). CPack has no general Authenticode pipeline and
no Apple notarize/staple workflow. Signing mutates package bytes, so release orchestration
must order any outer checksums and attestations after the final signing step.

### Publication and discovery

Not applicable by design. CPack writes files to `CPACK_PACKAGE_DIRECTORY`; it does not
create GitHub Releases, upload assets, submit WinGet/Homebrew records, or maintain APT/RPM
repository indexes. Qt IFW can describe online repositories, but that is a capability of
that delegated installer ecosystem, not a general CPack publication plane.

### Updates and release channels

No common update client, feed, delta format, rollout, or stable/beta/nightly model exists.
Native package managers or installer frameworks may provide upgrade behavior after an
artifact is placed in their distribution channel. CPack itself does not publish that
channel or coordinate versions across it.

### Automation and CI

`cmake --build <dir> --target package`, `cpack --preset`, `-G`, `-C`, and `-D` are
straightforward CI surfaces. A release pipeline must fan out to hosts containing both the
target binaries and required backend tools, retain packages, sign/notarize them in native
jobs, then fan in for publication. CPack does not schedule that matrix or isolate secrets.

`External` is a useful seam: `CPACK_EXTERNAL_ENABLE_STAGING` materializes the tree and
`CPACK_EXTERNAL_PACKAGE_SCRIPT` receives a machine-readable description, but idempotency,
retries, and remote execution belong to that script and its caller ([`external.rst`][external]).

### Supply-chain evidence and reproducibility

CPack can create checksums and can preserve a declarative install graph, but it does not
emit SBOMs or SLSA provenance. Reproducibility varies by generator, external tool version,
input mtimes, archive settings, and native signing. The working directory and verbose/tool
logs aid diagnosis; they are not a hermetic build record. Pinning CMake, generator tools,
inputs, and environment remains the release system's responsibility.

### Extensibility and UX

The CLI/config model is stable and scriptable, package presets make CI configuration
shareable, and per-generator variables expose native features without flattening them.
The price is a large `CPACK_*` namespace and uneven capability. `CPACK_PROJECT_CONFIG_FILE`,
resource templates, tool extra flags, and the `External` generator are powerful escape
hatches, but each reduces portability and requires format-aware review.

## Strengths

- Reuses the authoritative CMake `install()` graph instead of maintaining a second file list.
- Offers broad archive, package, and installer coverage behind one dispatch model.
- Preserves backend-specific controls and supports components and package presets.
- Can emit checksum sidecars and expose a staged tree to custom generators.
- Fits naturally as a backend node in native CI jobs.

## Weaknesses

- Generator availability and correctness depend on host OS and external tools.
- Common metadata does not imply common dependency, upgrade, or uninstall semantics.
- Signing support is fragmented and notarization/publication are absent.
- No build-matrix scheduler, artifact fan-in, release host, repository publisher, updater,
  SBOM, or provenance engine.
- Broad `CPACK_*` configuration and generator exceptions create a substantial testing matrix.

## Key design decisions and trade-offs

| Decision                              | Rationale                                                    | Trade-off                                                                       |
| ------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| Stage from CMake install rules        | Keep packaging aligned with installed build outputs          | Best integration assumes a CMake-owned install graph                            |
| Dispatch independent generators       | Add formats without pretending they share one implementation | Outputs and host requirements remain uneven                                     |
| Keep format-specific variables        | Preserve native package capabilities                         | Configuration is large and non-portable                                         |
| Delegate to native tools              | Reuse mature package and installer backends                  | CI must provision tools and native hosts                                        |
| Provide `External` as an escape hatch | Support formats outside CPack core                           | Custom scripts own correctness and lifecycle                                    |
| Stop at local artifacts               | Keep CPack a build/packaging primitive                       | Release orchestration, trust completion, and distribution require another layer |

## Sources

- CMake local clone at `/home/petar/code/repos/pkg-research-native/CMake`, reviewed at
  `22fd26b6c44ef5ae36eb6a70324c30776005b239`.
- [`Help/manual/cpack.1.rst`][cpack-manual], [`Modules/CPack.cmake`][cpack-module], and
  checked-in generator documentation under [`Help/cpack_gen/`][generators].
- Generator implementations under [`Source/CPack/`][source-tree] and component support in
  [`Modules/CPackComponent.cmake`][components].
- Evidence level: `[source-verified]`; no packages were host-built for this review.

<!-- References -->

[repo]: https://github.com/Kitware/CMake
[reviewed]: https://github.com/Kitware/CMake/tree/22fd26b6c44ef5ae36eb6a70324c30776005b239
[cpack-manual]: https://github.com/Kitware/CMake/blob/22fd26b6c44ef5ae36eb6a70324c30776005b239/Help/manual/cpack.1.rst
[generators]: https://github.com/Kitware/CMake/tree/22fd26b6c44ef5ae36eb6a70324c30776005b239/Help/cpack_gen
[cpack-module]: https://github.com/Kitware/CMake/blob/22fd26b6c44ef5ae36eb6a70324c30776005b239/Modules/CPack.cmake
[components]: https://github.com/Kitware/CMake/blob/22fd26b6c44ef5ae36eb6a70324c30776005b239/Modules/CPackComponent.cmake
[external]: https://github.com/Kitware/CMake/blob/22fd26b6c44ef5ae36eb6a70324c30776005b239/Help/cpack_gen/external.rst
[deb]: https://github.com/Kitware/CMake/blob/22fd26b6c44ef5ae36eb6a70324c30776005b239/Help/cpack_gen/deb.rst
[rpm]: https://github.com/Kitware/CMake/blob/22fd26b6c44ef5ae36eb6a70324c30776005b239/Help/cpack_gen/rpm.rst
[wix]: https://github.com/Kitware/CMake/blob/22fd26b6c44ef5ae36eb6a70324c30776005b239/Help/cpack_gen/wix.rst
[productbuild]: https://github.com/Kitware/CMake/blob/22fd26b6c44ef5ae36eb6a70324c30776005b239/Help/cpack_gen/productbuild.rst
[ifw]: https://github.com/Kitware/CMake/blob/22fd26b6c44ef5ae36eb6a70324c30776005b239/Help/cpack_gen/ifw.rst
[source-tree]: https://github.com/Kitware/CMake/tree/22fd26b6c44ef5ae36eb6a70324c30776005b239/Source/CPack
