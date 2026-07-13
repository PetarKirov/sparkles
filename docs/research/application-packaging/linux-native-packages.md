# DEB, RPM, and Arch native packages (Linux native packaging)

Linux native packages are filesystem payloads plus distribution-specific metadata that
participate in a system package database; they are not merely portable archives.

| Field                   | Value                                                                                                                                                    |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Platforms               | Debian-family, RPM-family, and Arch Linux systems                                                                                                        |
| Languages               | C/C++, Perl, shell, and format-specific build DSLs                                                                                                       |
| Licenses                | GPL-family implementations; component/library exceptions are recorded in each upstream tree                                                              |
| Format implementations  | [`dpkg`][dpkg-repo], [RPM][rpm-repo], and [`makepkg`/`libalpm`/`pacman`][pacman-repo]                                                                    |
| Documentation           | [Debian Policy][debian-policy] and `dpkg` manual pages; RPM format/manual documents; `pacman` manual pages                                               |
| Normative sources       | Debian Policy and format/manager manuals in the pinned source trees                                                                                      |
| Package outputs         | `.deb`; source/binary `.rpm`; `.pkg.tar.zst` (compression is configurable)                                                                               |
| Installed-state owners  | `dpkg` database; RPM database; `libalpm` local database                                                                                                  |
| Reviewed revisions      | `dpkg` [`e28873f8`][dpkg-sha] · Debian Policy [`b9024968`][policy-sha] · RPM [`375bdcdc`][rpm-sha] · `pacman` [`a6f7467d`][pacman-sha]                   |
| Category                | Native binary package formats, build recipes, and transactional system package managers                                                                  |
| Supported hosts/targets | Buildable on Linux for declared distribution architectures; ABI, policy, dependency names, and script environments remain distribution/release-specific  |
| OSS/paid boundary       | The formats and implementations surveyed here are open source; commercial signing, build farms, and repository hosting are optional surrounding services |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> **Specification, implementation, and recipe are different layers.** Debian Policy
> specifies archive/package behavior while `dpkg` implements it. RPM's checked-in
> format manuals describe its own implementation contract. An Arch `PKGBUILD` and an
> RPM `.spec` are executable build recipes; a `.deb`, binary `.rpm`, or
> `.pkg.tar.zst` is the installable result. This page labels format and manager behavior
> `[spec-verified]` or `[source-verified]`; it does not imply that one distribution's
> package is portable to another.

## Overview

### What it solves

Native packages let a distribution account for system files, enforce dependency and
conflict relationships, run ordered lifecycle actions, preserve selected local
configuration, and remove or upgrade software through one installed-state database.
They compose with higher-level solvers and repositories: APT selects `.deb` files and
invokes `dpkg`; DNF, Yum, or Zypper select RPMs and invoke RPM; `pacman` combines the
solver, downloader, and `libalpm` transaction engine.

The three formats put the same broad concerns into different containers:

| Concern            | DEB                                                                | RPM                                                           | Arch package                                                    |
| ------------------ | ------------------------------------------------------------------ | ------------------------------------------------------------- | --------------------------------------------------------------- |
| Container          | `ar` with ordered members                                          | Lead, signature header, main header, compressed payload       | Compressed `tar`                                                |
| Payload            | `data.tar.*`                                                       | `cpio`-derived archive indexed by header                      | Ordinary package paths in archive                               |
| Installed metadata | `control.tar.*`: `control`, scripts, `conffiles`, triggers, hashes | Typed header tags, file metadata, dependency tags, scriptlets | Dotfiles such as `.PKGINFO`, `.BUILDINFO`, `.MTREE`, `.INSTALL` |
| Build recipe       | `debian/control`, `debian/rules`, changelog, source-format files   | `.spec` plus sources and patches; optionally source RPM       | `PKGBUILD` plus sources and optional install script             |
| Identity/version   | package, architecture, `epoch:upstream-debian_revision`            | name, epoch, version, release, architecture (NEVRA)           | name, architecture, `epoch:pkgver-pkgrel`                       |

`dpkg`'s format manual states verbatim:

> “The file is an `ar` archive” and “The second required member is a tar archive
> containing the package metadata.” — [`man/deb.pod`][deb-format]

RPM's design document is equally explicit about the distribution boundary:

> “RPM packages are targeting a specific distribution (and release thereof). They are
> typically not suited to be installed or even built elsewhere without tweaking.” —
> [`docs/man/rpm-design.7.scd`][rpm-design]

### Design philosophy

All three systems favor **declared ownership plus controlled escape hatches**. Payload
files and relationships are declarative; scripts exist for migrations that cannot be
expressed as files. Each system increasingly centralizes repeated cache/index work:
Debian triggers, RPM file/transaction triggers, and `libalpm` hooks avoid every package
open-coding the same action.

The native model optimizes for distribution integration rather than upstream
self-containment. Shared runtimes and libraries remain package dependencies, filesystem
locations follow distribution policy, and upgrades are interpreted against a system-wide
package graph. That enables coordinated security updates and clean ownership queries, but
makes “one binary package for every Linux” an unsafe release promise.

## How it works

### Debian binary packages

A modern `.deb` is `[spec-verified]` an ordered `ar` archive. `debian-binary` contains
format version `2.0`; `control.tar.*` carries package metadata; `data.tar.*` carries the
filesystem tree. The implementation permits several compression methods and rejects
unknown required members or archive types [in `deb(5)`][deb-format]. A minimal control
stanza resembles:

```text
Package: sparkles
Version: 1:0.4.0-2
Architecture: amd64
Depends: libc6 (>= 2.38), libgcc-s1
Conflicts: sparkles-preview
Replaces: sparkles-preview (<< 0.4.0)
Description: Sparkles command-line utilities
```

`Package`, `Version`, `Architecture`, `Maintainer`, and `Description` identify and
describe the binary; relationship fields constrain package-manager decisions. Debian
Policy defines comma as conjunction, `|` as an alternative, and `<<`, `<=`, `=`, `>=`,
`>>` as version relations [in `ch-relationships.rst`][deb-relationships]. Runtime fields
have distinct force: `Pre-Depends` must be satisfied early enough for `preinst`/unpack;
`Depends` is required for configuration/use; `Recommends` is normally installed by APT;
`Suggests` and `Enhances` are weaker. `Breaks`, `Conflicts`, `Replaces`, and `Provides`
model incompatibility, file takeover, renames, and virtual facilities rather than being
synonyms.

Versions compare as an optional numeric epoch, upstream version, then Debian revision.
Within components, digit and non-digit runs compare specially and `~` sorts before even
an empty string; therefore `1.0~rc1-1 < 1.0-1`, while an epoch overrides the remaining
text [in `deb-version(7)`][deb-version]. These are Debian semantics, not SemVer.

Lifecycle programs in `control.tar.*` are `preinst`, `postinst`, `prerm`, and `postrm`.
`dpkg` separates unpack from configure: an upgrade can run the old `prerm`, the new
`preinst`, unpack while backing up replaced files, run the old `postrm`, then configure
and run the new `postinst` [in `dpkg(1)`][dpkg-install]. `conffiles` declares
administrator-editable files; when both the local file and new packaged file changed,
`dpkg` can prompt or follow explicit force policy. `remove` preserves conffiles, while
`purge` also removes conffiles and invokes final `postrm` cleanup. Package states such as
`unpacked`, `half-configured`, `triggers-awaited`, and `installed` expose partial failure
rather than pretending every operation is rollback-safe.

### RPM packages

RPM's current v6 draft documents four logical regions: lead, signature, header, and
payload [in `format_v6.md`][rpm-format]. The immutable typed header is the package
database record: NEVRA, descriptions, file paths and attributes, provides/requires,
scriptlets, payload compression, and digests. The payload is a compressed, stripped-down
`cpio` variant whose entries refer back to header file indexes.

A `.spec` supplies package metadata and executable build/install sections:

```spec
Name: sparkles
Epoch: 1
Version: 0.4.0
Release: 2%{?dist}
Requires: glibc >= 2.38
Provides: sparkles-cli = %{epoch}:%{version}-%{release}

%install
install -Dm755 sparkles %{buildroot}%{_bindir}/sparkles

%files
%{_bindir}/sparkles
```

RPM compares Epoch-Version-Release (EVR), not SemVer. Epoch is compared numerically
first; version and release are segmented by RPM's comparison rules, including special
`~` and `^` behavior documented by [`rpm-version(7)`][rpm-version]. The package name
establishes the normal update path, while architecture participates in the installed
instance identity. `Provides` and `Requires` are capability expressions: they can name
packages, virtual capabilities, ABI/library capabilities, paths, or rich Boolean
dependencies. File classifiers and dependency generators can derive requirements and
provisions from ELF and other payloads [in `rpm-dependency-generators(7)`][rpm-depgen].
`Conflicts` rejects coexistence; `Obsoletes` lets a new package replace an update path.

RPM package scripts include `%pre`, `%post`, `%preun`, and `%postun`; transaction slots
include `%pretrans` and `%posttrans`; package/file triggers react to other package or file
changes. The manual recommends package scripts only for package-specific actions and
central file triggers for caches and registries [in `rpm-scriptlets(7)`][rpm-scriptlets].
An upgrade installs the new instance and erases the old one in a defined interleaving.
Crucially, a script failure is not an ACID rollback boundary: RPM says, “RPM cannot undo
or roll back a transaction,” and a failing package pre-script can stop that package while
other transaction work continues [in the same manual][rpm-scriptlet-failure].

RPM records file ownership, modes, owners, digests, and configuration flags in the
RPM database. `%config(noreplace)` normally preserves a locally changed file and writes
the packaged replacement separately; plain `%config` may install the new file while
saving the old one. Exact suffix behavior is implementation/policy-sensitive, so release
automation should test the target distribution rather than promise a universal `.rpm`
configuration outcome.

### Arch packages

`makepkg` interprets a shell `PKGBUILD`, obtains and verifies sources, runs optional
`prepare()`, `build()`, `check()`, and `package()` functions, and emits a package archive;
`pacman` installs that archive. The `PKGBUILD` manual says:

> “Once a PKGBUILD is written, the actual package is built using makepkg and installed
> with pacman.” — [`doc/PKGBUILD.5.asciidoc`][pkgbuild-deps]

The built archive contains payload paths and generated metadata. `.PKGINFO` is the
machine-readable identity/dependency summary; `.BUILDINFO` records build-environment
inputs; `.MTREE` records payload metadata; an optional `.INSTALL` contains lifecycle
functions. These internal files are implementation products, while the `PKGBUILD` is a
recipe. A typical recipe declares:

```bash
pkgname=sparkles
pkgver=0.4.0
pkgrel=2
arch=('x86_64')
depends=('glibc>=2.38')
optdepends=('git: release repository operations')
provides=('sparkles-cli')
conflicts=('sparkles-preview')
backup=('etc/sparkles.conf')
sha256sums=('…')
```

Required runtime dependencies are `depends`; `makedepends` and `checkdepends` are build
inputs; `optdepends` is informational and does not participate in dependency resolution.
`provides`, `conflicts`, and `replaces` model virtual capabilities, non-coexistence, and
sysupgrade renames [in `PKGBUILD(5)`][pkgbuild-deps]. Version constraints use `=`, `<`,
`>`, `<=`, and `>=`; version identity is `epoch:pkgver-pkgrel`. `pacman`'s own ordering is
not SemVer: it compares numeric/alphanumeric segments and lets epoch dominate
[in `pacman(8)`][pacman-upgrade].

An optional install script defines `pre_install`, `post_install`, `pre_upgrade`,
`post_upgrade`, `pre_remove`, and `post_remove` [in `PKGBUILD(5)`][arch-install-script].
Repository-independent `libalpm` hooks can run before or after a transaction and can
abort only in the pre-transaction phase [in `alpm-hooks(5)`][alpm-hooks]. For files in
the `backup` array, three-way hash logic preserves a local edit and emits `.pacnew` when
both local and packaged versions diverged; removal can retain `.pacsave`
[in `pacman(8)`][pacman-config].

## Analysis spine

### Input and staging

All three consume a staged filesystem tree plus metadata, but their canonical recipes
are distribution build inputs, not portable application manifests. Debian source
packages use `debian/*` policy and helper tooling; RPM uses a `.spec`, sources, and
patches, often bundled into an SRPM; Arch uses a shell `PKGBUILD`. Staging must use final
absolute installation paths (`/usr/bin`, `/usr/lib`, `/usr/share`, configuration under
`/etc`) and must not capture host files accidentally.

Cross-packaging is technically possible in clean roots or containers, but
`[source-verified]` RPM explicitly targets a distribution release, and dependency names,
ABI baselines, macros, script interpreters, users/groups, and policy differ. The safe
target matrix is distribution × release × architecture, even when one Linux worker can
produce several cells.

### Outputs and target matrix

A project normally emits one architecture-specific package per target plus optional
architecture-independent data/debug/development subpackages. Debian uses architecture
names such as `amd64` and `arm64`; RPM embeds architecture in NEVRA and may emit
`noarch`; Arch uses declared package architectures and `any` for architecture-neutral
content. Source packages/SRPMs/`PKGBUILD` repositories are reproducible inputs and review
artifacts, not substitutes for binary packages.

### Metadata and dependencies

DEB relationship alternatives are explicit and Debian version relations use `<<`/`>>`.
RPM dependencies are capabilities and can be automatically generated from payload ABI.
Arch metadata is deliberately smaller; build-only fields stay in the recipe and
`optdepends` is informational. None interprets `1.2.3-alpha` according to SemVer by
mere appearance; each has its own epoch and comparison algorithm.

For an upstream application, dependencies should name the target distribution's runtime
packages or capabilities and be validated in a minimal clean root. Vendoring a library
removes a runtime relationship but transfers security-update ownership to the
application; declaring it allows coordinated distribution updates but narrows the target
compatibility envelope.

### Installation, upgrade, and uninstall

The installed-state database, not the archive extractor, owns file replacement and
removal. DEB explicitly separates unpack/configure and remove/purge. RPM models an
upgrade as new installation plus old erasure. `pacman -U` describes upgrade as a
remove-then-add process [in `pacman(8)`][pacman-upgrade]. All preserve specially marked
configuration through format-specific logic.

“Transaction” means ordered checks and mutations under a database lock, not universal
filesystem rollback. Maintainer/scriptlet code can modify unowned state, call services,
or fail after payload mutations. Packages should therefore declare files, keep scripts
idempotent and noninteractive, centralize cache refreshes in triggers/hooks, and provide
repair/reconfigure paths where the ecosystem supports them.

### Signing and platform trust

The layers differ sharply:

- A normal `.deb` has payload hashes but APT's standard trust path signs repository
  `Release` metadata, not each downloaded `.deb`; Debian upload signatures are a separate
  producer-to-archive step. Optional `debsig` mechanisms are not the default APT model.
- RPM embeds digest/signature material in its signature/header regions. The v6 format
  signs the header, whose payload hashes bind the payload [in `format_v6.md`][rpm-format].
  RPM-MD repository metadata has a separate signature policy.
- Arch packages commonly carry detached OpenPGP `.sig` files. `pacman` has separate
  signature policy bits for packages and repository databases
  [in `pacman.conf(5)`][pacman-signatures].

A package signature authenticates bytes/key policy; it does not prove benign behavior,
source review, repository freshness, or reproducibility. Repository trust is covered in [Linux repositories][linux-repositories].

### Publication and discovery

These package files become discoverable only after repository metadata names their
identity, version, architecture, location, size, and digest. Uploading a `.deb` or `.rpm`
to a generic release page supports direct installation but does not create an APT,
RPM-MD, or `pacman` repository. Direct installation also weakens dependency discovery,
update-channel configuration, and repository-level freshness policy.

### Updates and release channels

Package managers choose candidates using repository priority/order, version comparison,
and channel policy. Stable/beta/nightly should be represented by separate repositories,
suites, or package identities rather than repeatedly mutating one URL without metadata.
Epoch can repair a broken version ordering, but it is persistent operational debt and
should not be used as a routine release counter.

Downgrade and side-by-side behavior is package-manager-specific. DEB and Arch normally
maintain one installed version per package identity; RPM can retain multiple instances
for intentionally install-only packages, but ordinary same-name packages follow their
EVR update path. Renames require explicit `Provides`/`Replaces`/`Breaks` or
`Obsoletes`/`Provides`/`replaces` metadata.

### Automation and CI

CI should build in target clean roots, inspect package metadata and file lists, then test
fresh install, upgrade from the previous release, downgrade policy where supported,
remove, purge/full cleanup, dependency failure, script failure, and locally edited
configuration. Useful probes include `dpkg-deb --info/--contents`, `rpm -qp --requires
--scripts` and `rpm -V`, and `bsdtar -tf` plus `pacman -Qip`.

Signing must occur after final package bytes exist. Recompression, metadata edits, or
script injection invalidate byte-level evidence. Build jobs should not hold long-lived
repository signing keys; a separate signing/publishing job can accept immutable digests
and return signatures.

### Supply-chain evidence and reproducibility

DEB `.buildinfo`, RPM source packages/build metadata, and Arch `.BUILDINFO` capture
different portions of the build environment. They improve rebuild diagnosis but do not
alone constitute SLSA provenance or prove reproducibility. Deterministic staging,
normalized ownership/timestamps, pinned sources, clean builders, and rebuild comparison
are still required.

Package hashes bind declared bytes; scripts can generate undeclared state at install
time. Minimizing scripts therefore improves both transactional recovery and the gap
between inspected artifact and installed system.

### Extensibility and UX

DEB's extensibility lies in control fields, maintainer scripts, triggers, and helper
policy; RPM exposes macros, typed tags, generators, Lua, plugins, scripts, and triggers;
Arch exposes a shell recipe, install script, and `libalpm` hooks. Flexibility is highest
where auditability is lowest: arbitrary shell can express any migration but is harder to
simulate, roll back, and reproduce.

The best user experience is native: one package-manager command resolves dependencies,
records ownership, integrates configuration, receives updates, and removes the package.
The cost is per-distribution maintenance rather than a single universal Linux artifact.

## Strengths

- Integrates dependency solving, file ownership, upgrades, verification, and removal.
- Reuses distribution runtimes and coordinated security updates instead of vendoring all
  dependencies.
- Exposes machine-readable identity, versions, relationships, payload inventory, and
  installed state.
- Supports clean system-wide triggers/hooks for shared caches and registries.
- Fits managed fleets and repository promotion better than opaque self-updaters.

## Weaknesses

- Distribution/release-specific ABI, policy, names, and version semantics multiply the
  target matrix.
- Arbitrary lifecycle scripts weaken rollback, noninteractivity, and reproducibility.
- Configuration preservation and failure states differ enough to require native tests.
- Package signatures, repository signatures, source provenance, and reproducibility are
  separate mechanisms that are easy to conflate.
- Producing a valid package does not create a repository or earn inclusion in an official
  distribution.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                                          | Trade-off                                                                 |
| -------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| System-owned payload and database            | Enable coordinated upgrades, verification, and uninstall           | Package must obey distribution filesystem and dependency policy           |
| Separate recipe/source from binary package   | Preserve reviewable build instructions and target-specific outputs | More artifacts and identities to publish                                  |
| Ecosystem-native version comparison          | Support distro revisions, backports, and emergency epochs          | Upstream SemVer ordering cannot be assumed                                |
| Declarative relationships plus virtual names | Let solvers coordinate shared capabilities                         | Requires per-distribution dependency mapping                              |
| Ordered lifecycle scripts                    | Permit migrations beyond file extraction                           | Side effects are difficult or impossible to roll back                     |
| Preserve designated configuration            | Respect administrator changes across upgrades                      | Merge prompts and `.dpkg-*`/`.rpm*`/`.pacnew` state require operator work |
| Separate package and repository trust        | Scale trust across mirrors and channels                            | Users and publishers must secure two distinct evidence layers             |
| Target a distribution release                | Match its ABI, policy, macros, and dependency universe             | No single native package is universal Linux                               |

## Sources

- `[source-verified]` `dpkg` at `e28873f8c2171213af0c98bd5553ef5344cb7838`
  (`$REPOS/packaging-research/linux/dpkg`): `man/deb.pod`, `man/deb-control.pod`,
  `man/deb-version.pod`, `man/dpkg.pod`, `man/deb-conffiles.pod`, and maintainer-script
  manual pages.
- `[spec-verified]` Debian Policy at
  `b90249686422bad1886eddd68fbb76db0932929e`
  (`$REPOS/packaging-research/linux/debian-policy`): `policy/ch-relationships.rst`,
  `policy/ch-maintainerscripts.rst`, `policy/ch-controlfields.rst`, and package-manager
  appendices.
- `[source-verified]` RPM at `375bdcdca7652755cdfdd1035f9d34250af48eff`
  (`$REPOS/packaging-research/linux/rpm`): `docs/manual/format_v6.md`,
  `docs/man/rpm-design.7.scd`, `rpm-version.7.scd`, `rpm-scriptlets.7.scd`, and dependency
  generator documentation. The v6 file-format document labels itself a draft; deployed
  RPM v4 packages differ in signature details.
- `[source-verified]` `pacman` at
  `a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d`
  (`$REPOS/packaging-research/linux/pacman`): `doc/PKGBUILD.5.asciidoc`,
  `doc/pacman.8.asciidoc`, `doc/pacman.conf.5.asciidoc`, and
  `doc/alpm-hooks.5.asciidoc`.
- `[unverified]` No package was built or lifecycle-tested for this page; conclusions are
  source/specification verified, not host verified.

<!-- References -->

[alpm-hooks]: https://gitlab.archlinux.org/pacman/pacman/-/blob/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d/doc/alpm-hooks.5.asciidoc
[arch-install-script]: https://gitlab.archlinux.org/pacman/pacman/-/blob/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d/doc/PKGBUILD.5.asciidoc#install-upgrade-remove-scripting
[deb-format]: https://salsa.debian.org/dpkg-team/dpkg/-/blob/e28873f8c2171213af0c98bd5553ef5344cb7838/man/deb.pod
[deb-relationships]: https://salsa.debian.org/dbnpolicy/policy/-/blob/b90249686422bad1886eddd68fbb76db0932929e/policy/ch-relationships.rst
[deb-version]: https://salsa.debian.org/dpkg-team/dpkg/-/blob/e28873f8c2171213af0c98bd5553ef5344cb7838/man/deb-version.pod
[debian-policy]: https://www.debian.org/doc/debian-policy/
[linux-repositories]: ./linux-repositories.md
[dpkg-install]: https://salsa.debian.org/dpkg-team/dpkg/-/blob/e28873f8c2171213af0c98bd5553ef5344cb7838/man/dpkg.pod
[dpkg-repo]: https://salsa.debian.org/dpkg-team/dpkg
[dpkg-sha]: https://salsa.debian.org/dpkg-team/dpkg/-/commit/e28873f8c2171213af0c98bd5553ef5344cb7838
[pacman-config]: https://gitlab.archlinux.org/pacman/pacman/-/blob/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d/doc/pacman.8.asciidoc#handling-config-files
[pacman-repo]: https://gitlab.archlinux.org/pacman/pacman
[pacman-sha]: https://gitlab.archlinux.org/pacman/pacman/-/commit/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d
[pacman-signatures]: https://gitlab.archlinux.org/pacman/pacman/-/blob/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d/doc/pacman.conf.5.asciidoc
[pacman-upgrade]: https://gitlab.archlinux.org/pacman/pacman/-/blob/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d/doc/pacman.8.asciidoc
[pkgbuild-deps]: https://gitlab.archlinux.org/pacman/pacman/-/blob/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d/doc/PKGBUILD.5.asciidoc
[policy-sha]: https://salsa.debian.org/dbnpolicy/policy/-/commit/b90249686422bad1886eddd68fbb76db0932929e
[rpm-depgen]: https://github.com/rpm-software-management/rpm/blob/375bdcdca7652755cdfdd1035f9d34250af48eff/docs/man/rpm-dependency-generators.7.scd
[rpm-design]: https://github.com/rpm-software-management/rpm/blob/375bdcdca7652755cdfdd1035f9d34250af48eff/docs/man/rpm-design.7.scd
[rpm-format]: https://github.com/rpm-software-management/rpm/blob/375bdcdca7652755cdfdd1035f9d34250af48eff/docs/manual/format_v6.md
[rpm-repo]: https://github.com/rpm-software-management/rpm
[rpm-scriptlet-failure]: https://github.com/rpm-software-management/rpm/blob/375bdcdca7652755cdfdd1035f9d34250af48eff/docs/man/rpm-scriptlets.7.scd#exit-status
[rpm-scriptlets]: https://github.com/rpm-software-management/rpm/blob/375bdcdca7652755cdfdd1035f9d34250af48eff/docs/man/rpm-scriptlets.7.scd
[rpm-sha]: https://github.com/rpm-software-management/rpm/commit/375bdcdca7652755cdfdd1035f9d34250af48eff
[rpm-version]: https://github.com/rpm-software-management/rpm/blob/375bdcdca7652755cdfdd1035f9d34250af48eff/docs/man/rpm-version.7.scd
