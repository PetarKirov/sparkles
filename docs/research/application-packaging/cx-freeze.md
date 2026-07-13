# cx_Freeze (Python freezer and native package backends)

An open-source Python freezer that discovers imported modules and binary dependencies,
builds a self-contained executable directory around a native launcher and Python runtime,
and can wrap that directory in selected platform-native distribution formats.

| Field             | Value                                                                                               |
| ----------------- | --------------------------------------------------------------------------------------------------- |
| Language          | Python, with platform launcher/runtime components supplied by `freeze-core`                         |
| License           | PSF-derived cx_Freeze license; bundled `freeze-core` has its own compatible license                 |
| Repository        | [marcelotduarte/cx_Freeze][repo]                                                                    |
| Documentation     | [cx_Freeze documentation][docs]                                                                     |
| Reviewed revision | [`ecd80b36d241ce67d648ede65bd2cd5ac10436c4`][revision] (development after `8.6`)                    |
| Category          | **Python freezer plus installer/package backends**; not an updater or release control plane         |
| Desktop outputs   | Frozen directory; Windows MSI; macOS `.app`/DMG; Linux AppImage, RPM, DEB                           |
| Native hosts      | Freeze on the target OS; MSI requires Windows, app/DMG requires macOS, Linux packages require Linux |
| OSS/paid boundary | Entire reviewed implementation is OSS; no paid capability                                           |

**Last reviewed:** July 12, 2026

> [!NOTE]
> Claims are `[source-verified]` at the pinned revision. Source, docs, tests, samples,
> and workflows were inspected locally. This review did not execute Windows/macOS
> packaging, signing, installation, or updates, so those claims are not
> `[host-verified]`.

## Overview

### What it solves

cx_Freeze makes a Python application runnable on a machine that does not have the
application's Python environment. Its top-level promise is concise
([`README.md`][readme]):

> “Creates standalone executables from Python scripts with the same performance as the original script.”

The core `build_exe` operation traces Python imports, applies package-specific hooks,
collects native extension/shared-library dependencies, writes bytecode and resources,
and stamps one or more native launchers. Optional `bdist_*` commands then turn that
frozen directory into MSI, app bundle/DMG, AppImage, RPM, or DEB artifacts.

This classification matters. cx_Freeze is primarily a **freezer**; its package commands
are backend wrappers. It does not tag releases, compile arbitrary application source,
coordinate target jobs, publish artifacts, generate update feeds, or update installed
applications. A CI/release system must wrap it.

### Design philosophy

cx_Freeze keeps Python execution conventional while replacing the development
installation with a relocatable runtime layout:

1. `ModuleFinder` scans imports and metadata, with `includes`, `packages`, `excludes`,
   and hook overrides for dynamic behavior ([`finder.py`][finder]).
2. `Freezer` copies native launch bases and the Python shared library, writes modules to
   `lib/library.zip` or the filesystem, copies data/native extensions, follows binary
   dependencies, and adjusts platform loader paths ([`freezer.py`][freezer]).
3. A small launcher from the separately distributed `freeze-core` package initializes
   Python and runs the chosen module/script; the app does not need a system Python.
4. setuptools-compatible commands and `[tool.cxfreeze]` configuration expose the same
   model to `setup.py`, `pyproject.toml`, and `cxfreeze` CLI users
   ([`setup_script.rst`][setup-docs], [`cli.py`][cli]).

The result is not source-to-native compilation and not normally a single executable.
Python bytecode still runs in CPython; performance is therefore intended to match the
script rather than gain ahead-of-time compilation speed.

## How it works

A minimal `pyproject.toml` can identify an executable and tune module placement:

```toml
[tool.cxfreeze]
executables = [{ script = "src/example.py", target_name = "example" }]

[tool.cxfreeze.build_exe]
packages = ["httpx"]
excludes = ["tkinter", "unittest"]
zip_include_packages = ["encodings"]
include_files = [["assets", "assets"]]
```

The equivalent lifecycle is:

```bash
cxfreeze build_exe
cxfreeze bdist_msi       # Windows only
cxfreeze bdist_dmg       # macOS only
cxfreeze bdist_appimage  # Linux only
```

`build_exe.run()` constructs `Freezer` from normalized command options and calls
`freeze()` ([`command/build_exe.py`][build-exe]). `Freezer.freeze()` discovers the
module graph, writes modules/resources, copies launch bases, traces dependent native
libraries, fixes Mach-O/ELF layout, and stamps Windows resources/checksums. Each
`bdist_*` command first runs or reuses `build_exe`, stages the frozen tree in the native
layout, then invokes or implements its format backend.

## Packaging analysis

### Input and staging

Inputs are Python entry scripts/modules and the active Python environment, plus explicit
`includes`, `packages`, `excludes`, `replace_paths`, `include_files`, binary include or
exclude rules, icons, constants, metadata, and per-executable base/manifest settings.
The environment is not merely a resolver: cx_Freeze copies its Python shared library,
stdlib/application modules, extension modules, distribution metadata, DLLs/shared
objects, and selected data into the target directory ([`freezer.py`][freezer]).

Module discovery parses imports and recursively includes modules. Hooks compensate for
implicit/dynamic imports and package data in ecosystems such as Qt, NumPy, pandas,
matplotlib, Torch, OpenCV, tkinter, timezone data, and certificate bundles
([`hooks/`][hooks]). Explicit options are the escape hatch when static discovery cannot
see `importlib`, plugin entry points, data files, or runtime-computed imports.

Frozen-runtime layout is selective:

- pure Python modules are compiled to `.pyc` and normally stored in
  `lib/library.zip`;
- packages selected by `zip_include_packages` can enter the ZIP, while
  `zip_exclude_packages` remain unpacked;
- package data and native extension modules must remain on disk when loaders cannot read
  them from ZIP;
- `zip_includes` adds arbitrary files to the shared archive;
- native libraries and the Python runtime live under the executable/lib tree;
- the launcher exposes a frozen `sys` environment and dispatches into bytecode.

`Freezer._write_modules()` preserves module/source mtimes in ZIP entries where available
and extracts temporary native files after archive creation ([`freezer.py`][freezer]).
This is a frozen directory, not an archive that extracts itself on every launch.

### Outputs and target matrix

| Command          | Output                                                                                            | Backend/important boundary                                        |
| ---------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `build_exe`      | Relocatable directory with launcher, Python runtime, `lib/library.zip`, extensions, and resources | cx_Freeze core                                                    |
| `bdist_msi`      | Windows `.msi`                                                                                    | Python `msilib` compatibility package and MSI database generation |
| `bdist_mac`      | macOS `.app`                                                                                      | cx_Freeze layout plus Mach-O relocation and `codesign` support    |
| `bdist_dmg`      | macOS `.dmg` containing the app                                                                   | `hdiutil` and generated DMG layout                                |
| `bdist_appimage` | Linux `.AppImage` and optional `.zsync` update metadata                                           | Downloaded/provided AppImage runtime and `appimagetool`           |
| `bdist_rpm`      | Linux `.rpm`                                                                                      | Generated spec plus `rpmbuild`                                    |
| `bdist_deb`      | Linux `.deb`                                                                                      | Builds RPM then converts with `alien`                             |

`[source-verified]` The documentation is explicit about host boundaries: “if you want to
freeze your programs for Windows, freeze it on Windows; if you want to run it on Macs,
freeze it on a macOS” ([`faq.rst`][faq]). Platform command `finalize_options()` methods
reject unsupported hosts. A freeze captures the active interpreter ABI and host-native
libraries, so a cross-compiled launcher alone would not make arbitrary cross-freezing
safe.

Architecture follows the installed Python/freeze-core and native dependencies. There is
no universal/fat assembly across separately frozen architectures and no remote/native
builder. Producers need a platform/architecture CI matrix.

### Metadata and dependencies

`setup()` extends setuptools distribution metadata with executable declarations and
command options. Application name/version/description/vendor/license feed RPM/DEB/MSI
or bundle metadata; `Executable` controls script, init module, base (`console`, `gui`,
`service`), target name, icon, shortcut fields, manifest, and Windows version resources
([`executable.py`][executable], [`keywords.rst`][keywords]).

Python dependency handling is reachability-based vendoring, **not package-manager
resolution**. cx_Freeze starts from the already-installed environment and traces imports;
it does not resolve a lockfile or install requirements itself. Distribution metadata is
included when hooks or package relationships need it. Binary parsers inspect PE imports
(on Windows), Mach-O references/rpaths (macOS), or ELF dependencies using `ldd`/LIEF and
`patchelf` support (Linux) ([`dep_parser.py`][dep-parser], [`darwintools.py`][darwin]).

Format dependencies are separate. RPM exposes requirements/provides/conflicts fields;
DEB inherits its metadata through RPM-to-DEB conversion; MSI records product name,
version, product code, optional upgrade code, install scope, shortcuts, and PATH changes.
The portable frozen directory itself declares no system dependency manifest—it is
expected to carry everything not safely assumed present.

### Installation, upgrade, and uninstall

`build_exe` has no installer database: users copy/run the directory and uninstall by
deleting it. AppImage is likewise a portable image. A DMG transports an `.app`, which is
normally copied/replaced and deleted to uninstall.

MSI delegates installation, repair, upgrade, rollback, and removal to Windows Installer.
`bdist_msi` generates a fresh product code by default and accepts a stable
`upgrade_code`; maintaining upgrade identity is therefore a producer responsibility
([`command/bdist_msi.py`][msi]). It can create shortcuts, PATH entries, UI, launch-on-finish,
and per-user/per-machine installation data.

RPM owns files and scripts through the RPM database. DEB lifecycle comes from the RPM
metadata translated by `alien`, which is less native than constructing Debian control
data directly. cx_Freeze does not provide a shared migration, rollback, or application
state policy above these native mechanisms.

### Signing and platform trust

macOS `bdist_mac` supports signing identity, entitlements, timestamp, options, strict
mode, verification with `codesign`/`spctl`, and inside-out signing of nested binaries
([`command/bdist_mac.py`][mac]). It also applies ad-hoc signatures when modifying Mach-O
files. **It does not submit Apple notarization or staple a ticket.** Producers must add
those release steps after the app/DMG is built.

AppImage packaging can pass `--sign` and `--sign-key` to `appimagetool`, producing its
embedded GPG signature when the external tool supports it
([`command/bdist_appimage.py`][appimage]). This is AppImage trust, not an update feed or
Linux repository signature.

There is no integrated Windows Authenticode/MSI signing or timestamp workflow in the
reviewed `bdist_msi` command, no RPM/DEB repository signing, no checksum/signature
manifest, and no secret-management abstraction. Native signing commands must run on
native hosts or in downstream jobs. Signing, notarization, and package/repository trust
remain separate responsibilities.

### Publication and discovery

cx_Freeze writes artifacts under build/distribution directories and appends native
outputs to setuptools' `dist_files` where appropriate. It has no GitHub Releases, S3,
PyPI-for-apps, Store, Homebrew, WinGet, APT/YUM repository, Flatpak, or update-server
publisher. The project's own workflow publishes **cx_Freeze's Python wheel** to
TestPyPI; that workflow is not a feature available to applications frozen by the tool
([`.github/workflows/ci.yml`][ci]).

Users must upload portable outputs/installers, construct repository metadata or catalog
manifests, and manage retention/discovery separately. This hard boundary is why
cx_Freeze is a freezer/backend collection rather than a release control plane.

### Updates and release channels

There is no installed runtime updater, feed parser, update scheduler, delta engine,
channel model, phased rollout, rollback controller, or package publication history.
Frozen applications are inert until replaced by a user, installer, OS package manager,
or separately integrated updater.

`bdist_appimage --updateinformation` embeds the update-information string consumed by
external AppImageUpdate-compatible tooling and causes the backend tool to emit `.zsync`
metadata; `guess` derives a supported CI/forge pattern from environment and project
metadata ([`command/bdist_appimage.py`][appimage], [`bdist_appimage.rst`][appimage-docs]).
It does not host an update, check for updates at runtime, or define stable/beta channels. MSI/RPM/DEB upgrades become possible only when producers preserve native
identity and publish new versions through external infrastructure.

### Automation and CI

The CLI and setuptools command model are scriptable and source-control-friendly.
`pyproject.toml` provides declarative options; `cxfreeze-quickstart` can scaffold a
configuration; samples cover GUI frameworks, services, multiprocessing, package data,
and each distribution backend ([`samples/`][samples]).

Upstream CI tests Ubuntu, Windows, and macOS across Python `3.10`–`3.14` plus free-threaded
variants where available, installs Linux RPM/DEB tooling, builds its wheel, and executes
frozen sample programs ([`.github/workflows/ci.yml`][ci]). Format-specific tests inspect
MSI databases, DMG command construction, Linux package metadata, dependency discovery,
hooks, and runtime output.

Consumer release automation still needs one job per target OS/architecture, installation
smoke tests, downstream signing/notarization, artifact fan-in, publication, and release
metadata. cx_Freeze does not generate that workflow.

### Supply-chain evidence and reproducibility

Positive project controls include pinned GitHub Action SHAs, hardened-runner audit mode,
CodeQL, dependency review, multi-OS runtime tests, explicit license copying, and a
separate `freeze-core` runtime package. Finder output and the module report make included
modules inspectable; native dependencies are copied from known host paths.

Final application artifacts are not claimed byte-reproducible:

- `BUILD_TIMESTAMP` records the current UTC time and `SOURCE_TIMESTAMP` derives from
  sources ([`module.py`][module]);
- bytecode/ZIP entries use source or current mtimes;
- file metadata is copied from the host;
- MSI product code defaults to a random UUID;
- DMG/AppImage/RPM/DEB invoke host tools and compression;
- code signing/timestamps add external state;
- the active Python environment is not locked by cx_Freeze.

There is no application SBOM, SLSA provenance, attestation, dependency lock, signed
checksum list, or reproducibility report. Downstream release CI should construct the
environment from a lock, pin Python/cx_Freeze/freeze-core and native tools, inventory the
frozen directory, generate SBOM/provenance, and sign artifacts/evidence after packaging.

### Extensibility and UX

The extension surface is practical but internal rather than a stable third-party backend
ABI:

- module hooks (`load_<module>`, `missing_<module>`) add/exclude imports, metadata,
  libraries, and data;
- explicit include/exclude/package/ZIP controls repair static-discovery gaps;
- `Executable` and `Freezer` can be used programmatically;
- setuptools command classes can be subclassed;
- MSI data tables, RPM options, DMG layout, macOS plist/signing, and AppImage fields are
  configurable.

Adding a new first-class artifact generally means implementing another command and
registering it in cx_Freeze; there is no provider-neutral publication or updater plugin.
UX benefits include familiar Python packaging configuration, a quickstart generator,
clear build reports, and a reusable frozen directory. Sharp edges include debugging
hidden imports, package-specific hooks, native dependency leakage, per-host builds,
large output trees, and uneven backend maturity—especially DEB's `alien` conversion.

## Strengths

- Mature, fully OSS Python freezing with broad package/framework hooks.
- Produces applications that do not require a preinstalled Python interpreter.
- Preserves CPython runtime performance and normal extension-module behavior.
- Fine-grained control over module reachability, ZIP placement, data, and binary files.
- Native dependency discovery and platform loader-path repair.
- Optional MSI, app/DMG, AppImage, RPM, and DEB outputs from the same frozen tree.
- Strong multi-OS/multi-Python upstream runtime test coverage.

## Weaknesses

- Cross-freezing is unsupported; every target OS/architecture needs a suitable Python
  environment and native runner.
- Output is normally a directory/runtime tree, not one executable.
- Static import discovery needs hooks or explicit includes for dynamic applications.
- No end-user updater, feeds, deltas, channels, or rollout policy.
- No application publication/repository/catalog integration.
- Signing is incomplete: no Windows signing and no Apple notarization/stapling.
- DEB generation depends on RPM plus `alien` rather than native Debian construction.
- No generated SBOM, provenance, lockfile, checksum manifest, or reproducibility claim.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                         | Trade-off                                                                 |
| ------------------------------------------------------------ | ------------------------------------------------- | ------------------------------------------------------------------------- |
| Trace imports from an installed Python environment           | Automatically collect the reachable application   | Dynamic imports/data require hooks or explicit declarations               |
| Ship CPython and bytecode rather than compile to native code | Preserve Python semantics and performance         | Larger runtime tree and no AOT optimization                               |
| Store most pure modules in `library.zip`                     | Reduce file count and centralize bytecode         | Native extensions/package data must remain unpacked                       |
| Keep a relocatable directory as the core output              | Provide a simple backend-neutral staging artifact | Not a transactional installer or single-file executable                   |
| Copy host-native binary dependencies                         | Make the application self-contained               | Host leakage, license inventory, and ABI compatibility are producer risks |
| Require target-native freezing                               | Match interpreter ABI and platform loader tools   | Multi-host CI and architecture fan-out are mandatory                      |
| Layer `bdist_*` commands over `build_exe`                    | Reuse one frozen tree across native containers    | Backend quality and lifecycle semantics vary significantly                |
| Delegate MSI/RPM/DMG/AppImage semantics to native tools      | Avoid reimplementing every format contract        | Tool availability, version drift, and native-host constraints             |
| Expose hooks and include/exclude controls                    | Repair Python's dynamic import/resource behavior  | Configuration can become package-specific and brittle                     |
| Leave publishing and updating downstream                     | Keep the project focused on freezing/packaging    | Consumers must build the entire release control plane themselves          |

## Sources

- [Repository and exact reviewed tree][revision]
- [`README.md` — positioning, platform scope, and license][readme]
- [`cx_Freeze/finder.py` — import graph, packages, ZIP selection, and hooks][finder]
- [`cx_Freeze/freezer.py` — frozen layout, bytecode archive, runtime, and binary copying][freezer]
- [`cx_Freeze/command/build_exe.py` — command-to-freezer boundary][build-exe]
- [`cx_Freeze/command/bdist_*` — MSI, macOS/DMG, AppImage, RPM, and DEB backends][commands]
- [`cx_Freeze/dep_parser.py` and `darwintools.py` — native dependency/loader handling][dep-parser]
- [`doc/src/faq.rst` — native-host requirement and runtime licensing][faq]
- [`doc/src/setup_script.rst` — public configuration surface][setup-docs]
- [Tests, samples, and upstream CI workflows][tests]

<!-- References -->

[repo]: https://github.com/marcelotduarte/cx_Freeze
[docs]: https://cx-freeze.readthedocs.io/
[revision]: https://github.com/marcelotduarte/cx_Freeze/tree/ecd80b36d241ce67d648ede65bd2cd5ac10436c4
[readme]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/README.md
[cli]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/cli.py
[finder]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/finder.py
[freezer]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/freezer.py
[executable]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/executable.py
[module]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/module.py
[build-exe]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/command/build_exe.py
[msi]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/command/bdist_msi.py
[mac]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/command/bdist_mac.py
[appimage]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/command/bdist_appimage.py
[appimage-docs]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/doc/src/bdist_appimage.rst
[commands]: https://github.com/marcelotduarte/cx_Freeze/tree/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/command
[dep-parser]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/dep_parser.py
[darwin]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/darwintools.py
[hooks]: https://github.com/marcelotduarte/cx_Freeze/tree/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/cx_Freeze/hooks
[faq]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/doc/src/faq.rst
[setup-docs]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/doc/src/setup_script.rst
[keywords]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/doc/src/keywords.rst
[samples]: https://github.com/marcelotduarte/cx_Freeze/tree/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/samples
[ci]: https://github.com/marcelotduarte/cx_Freeze/blob/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/.github/workflows/ci.yml
[tests]: https://github.com/marcelotduarte/cx_Freeze/tree/ecd80b36d241ce67d648ede65bd2cd5ac10436c4/tests
