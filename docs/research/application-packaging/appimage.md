# AppImage (universal Linux application format)

AppImage is a portable, self-mounting Linux application image: a runtime executable is
concatenated with an immutable application filesystem so users can download one file,
mark it executable, and run it without a system package transaction.

| Field                        | Value                                                                               |
| ---------------------------- | ----------------------------------------------------------------------------------- |
| Language                     | Format specification; reference runtimes are native Linux executables               |
| Format                       | ELF runtime plus application filesystem, normally SquashFS (type 2)                 |
| Application staging contract | AppDir                                                                              |
| License                      | MIT (AppImage specification); individual runtimes and tools vary                    |
| Repository                   | [AppImage/AppImageSpec][spec-repo]                                                  |
| Documentation                | [Pinned specification draft][spec-draft]                                            |
| Historical rationale read    | [AppImage/AppImageKit][kit-repo] (`README.md` and `motivation.md`; no runtime code) |
| Reviewed revisions           | AppImageSpec [`51c2a146`][spec-sha] · AppImageKit rationale [`db405d11`][kit-sha]   |
| Category                     | Portable payload container; no installer database or sandbox                        |
| Supported hosts/targets      | Linux; image and runtime must match the target CPU architecture and ABI assumptions |
| OSS/paid boundary            | Open specification and implementations; hosting and update delivery are external    |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> This page describes the **format contract**. The separate
> [linuxdeploy/appimagetool page][tools] describes one staging and finalization
> implementation; neither tool defines every possible AppImage producer.

## Overview

### What it solves

AppImage gives an upstream project a publisher-owned, relocatable application image
without requiring a Debian/RPM repository or privileged installation. The specification
summarizes the user contract directly:

> “The AppImage Specification describes [AppImage], a format to deploy application
> software to Linux-based operating systems.” — [AppImage specification draft][spec-draft]

The application remains one ordinary file. Removal is deleting that file; multiple
versions can coexist under different names or paths. This simplicity deliberately omits
a central package database, dependency solver, mandatory catalog, and automatic updater.

### Design philosophy

The format puts the application and most non-base dependencies under publisher control
while relying on a sufficiently old Linux userspace ABI for compatibility. The
[AppDir contract][spec-appdir] supplies desktop metadata and an `AppRun` entry point;
the runtime exposes or mounts that tree and executes it. Integration, update metadata,
and signatures are optional capabilities rather than prerequisites for execution.

## How it works

A type-2 image begins with an ELF runtime and appends a filesystem image. The runtime
locates the embedded filesystem, mounts it (normally through FUSE), and invokes
`AppRun`. The payload follows an AppDir layout:

```text
Example.AppDir/
├── AppRun
├── example.desktop
├── .DirIcon -> usr/share/icons/hicolor/256x256/apps/example.png
└── usr/
    ├── bin/example
    ├── lib/
    ├── share/applications/example.desktop
    └── share/icons/hicolor/256x256/apps/example.png
```

The [type-2 image rules][spec-type2] reserve ELF sections including `.upd_info` for one
update-information string and `.sha256_sig` for a signature. The
[update specification][spec-update] defines `zsync`, `gh-releases-zsync`, and
`pling-v1-zsync` transports. Plain `zsync` and GitHub Releases identify a `.zsync`
control file; the Pling transport instead uses its product ID and matching AppImage filenames and says
the packager **must not** upload a `.zsync` file. These strings guide an external updater;
they do not make image execution perform updates.

```text
gh-releases-zsync|OWNER|REPOSITORY|latest|Example-*-x86_64.AppImage.zsync
```

`AppRun` is the publisher-controlled compatibility adapter. It can set loader/search
paths relative to `APPDIR`, choose a bundled executable, or perform migration. The
format itself does not virtualize the host: unless the user separately invokes a
sandbox, the payload has the same authority as any downloaded executable.

## Analysis spine

### Input and staging

The producer stages an AppDir containing `AppRun`, one root desktop entry, `.DirIcon`,
icons, executable code, resources, and selected shared libraries. The specification
recommends a conventional `usr/` prefix and says ELF `AppRun` should have as few runtime
dependencies as possible [source-verified: [AppDir rules][spec-appdir]]. Dependency
selection is producer policy, not encoded dependency metadata: bundle libraries that
cannot safely be assumed on the oldest supported target, but avoid replacing kernel,
loader, graphics-driver, NSS, and other host-coupled components blindly.

### Outputs and target matrix

The output is one executable file per architecture and compatibility baseline. The
reviewed specification covers type 1 (ISO 9660 payload) and type 2 (runtime plus
filesystem image), while current tooling normally emits type 2. A single file does not
make machine code architecture-neutral: `x86_64`, `i686`, `aarch64`, and `armhf`
releases need matching runtimes and payloads. Cross-construction is possible when the
producer has target binaries and a target runtime; execution testing still needs the
actual architecture or emulation.

Compatibility is a publisher responsibility. An AppImage built on a new distribution
can require newer `glibc`, `libstdc++`, symbol versions, kernel features, or desktop
services than an older target provides. Bundling ordinary libraries reduces variation
but cannot bundle the kernel and does not eliminate loader/driver integration. Build on
an old-enough baseline and test the finished image across the declared distribution and
desktop matrix.

### Metadata and dependencies

Desktop metadata lives in the root `.desktop` file and conventional AppDir paths; icon
selection follows the freedesktop icon hierarchy. Optional AppStream metadata can aid
catalog integration, but there is no mandatory package name/version/dependency record
comparable to RPM or Flatpak refs. The filename is not a normative upgrade identity.
Dependencies are vendored payload or host assumptions, so inspection requires examining
ELF `DT_NEEDED`, `RPATH`/`RUNPATH`, `AppRun`, and the mounted filesystem.

### Installation, upgrade, and uninstall

There is no install transaction: make the image executable and run it. Desktop
integration is optional. The specification says such software **should** ask explicit
permission and **should not** offer integration when the documented
`no_desktopintegration` sentinels are present [spec-verified: [desktop
integration][spec-desktop]].
Upgrade is replacement or side-by-side download. Uninstall is deletion of the image;
launcher entries, configuration, caches, and user data created outside it need separate
cleanup and are not discoverable from an installer receipt.

### Signing and platform trust

A type-2 image may embed a signature over the image's SHA-256 while treating the
`.sha256_sig` section as zero-filled [spec-verified: [type-2 rules][spec-type2]]. The
signature binds bytes to a key only when the user obtains and trusts the correct public
key and actually verifies it. AppImage has no OS-enforced publisher identity equivalent
to a Snap Store assertion or a configured Flatpak remote key. HTTPS, release checksums,
external signatures, and provenance remain complementary controls.

### Publication and discovery

Publishers can attach images to a website or immutable release host. GitHub Releases
and Pling are update-information transports, not mandatory catalogs. AppImage discovery
sites and desktop integrators are independent layers. The portable file works offline
after download, but discoverability, moderation, takedown, mirrors, and bandwidth are
publisher or catalog responsibilities.

### Updates and release channels

Embedded update information names exactly one transport. `zsync` can reconstruct a new
image by fetching changed blocks over HTTP range requests; the GitHub variant resolves a
matching `.zsync` asset, while the Pling transport uses its product ID and matching
AppImage filenames without a publisher-uploaded `.zsync` sidecar. Channels are conventions encoded in the
URL, release selector, or filename glob, not a global format concept. The updater must
verify the reconstructed artifact under the publisher's trust policy and replace it
safely; the specification does not prescribe rollback, forced refresh, or downgrade
prevention.

### Automation and CI

CI should stage from an empty AppDir, audit dynamic dependencies, finalize once, and
publish the AppImage, checksum/signature, update control file, SBOM, and provenance from
the same job inputs. Test `--appimage-extract` or equivalent inspection, headless launch
where possible, desktop metadata, and actual startup on old/new distribution images.
FUSE availability varies in containers and restricted hosts, so extraction tests are a
useful fallback but are not equivalent to mounting and running the final image.

### Supply-chain evidence and reproducibility

The image can be checksummed as one immutable object and its SquashFS payload inspected.
Reproducibility depends on producer control of file ordering, ownership, modes,
timestamps, compression options, runtime bytes, and embedded metadata. Optional
signatures do not prove how the payload was built. Pin the runtime and all downloaded
inputs rather than resolving a moving “continuous” runtime during a release, set a
stable epoch where supported, and publish an SBOM/provenance record alongside the image.

### Extensibility and UX

`AppRun` permits arbitrary startup adaptation, and optional ELF sections add metadata
without a package database. That flexibility supports many frameworks and portable CLI
or GUI apps, but every image can behave differently. Users get excellent download/run
and side-by-side UX, while administrators get no centralized permission review,
mandatory refresh policy, dependency inventory, or complete uninstall record.

## Strengths

- One relocatable file runs without root or a distribution package transaction.
- The publisher controls most userspace dependencies and can support offline execution.
- Side-by-side versions and uninstall-by-deletion are easy to understand.
- Optional zsync metadata supports bandwidth-efficient publisher-controlled updates.
- The file is straightforward to hash, mirror, sign, and attach to immutable releases.

## Weaknesses

- No built-in sandbox, least-privilege permission declaration, or portal contract.
- Compatibility still depends on kernel, libc baseline, CPU, drivers, and host services.
- No mandatory repository, publisher identity, dependency solver, or update enforcement.
- Desktop integration and user-state cleanup are outside the core file contract.
- Optional embedded signatures have value only with an external key-distribution policy.
- Flexible `AppRun` scripts make behavior harder to inspect uniformly.

## Key design decisions and trade-offs

| Decision                       | Rationale                                               | Trade-off                                       |
| ------------------------------ | ------------------------------------------------------- | ----------------------------------------------- |
| Self-mounting executable image | Minimize installation friction                          | Depends on runtime/FUSE or extraction support   |
| AppDir payload                 | Reuse freedesktop layout and simple staging             | Weak normative identity/dependency metadata     |
| Vendor most runtime libraries  | Reduce distribution variation                           | Larger images and host-integration hazards      |
| No mandatory sandbox           | Preserve compatibility with ordinary Linux applications | Downloaded code receives ambient user authority |
| Optional update information    | Allow decentralized hosting and zsync deltas            | No uniform refresh, rollback, or channel policy |
| Optional embedded signature    | Keep a self-contained verification envelope             | Key discovery and enforcement remain external   |

## Sources

- [AppImage specification draft at `51c2a146`][spec-draft] (`$REPOS/packaging/AppImageSpec/draft.md`).
- [AppImageKit rationale snapshot at `db405d11`][kit-sha]
  (`$REPOS/packaging/AppImageKit`); this reviewed tree contains only project rationale
  and delegates runtime/tool implementations to separate repositories.
- [AppDir rules][spec-appdir], [type-2 image rules][spec-type2],
  [update information][spec-update], and [desktop integration][spec-desktop].
- Related implementation: [linuxdeploy and appimagetool][tools].

<!-- References -->

[spec-repo]: https://github.com/AppImage/AppImageSpec
[kit-repo]: https://github.com/AppImage/AppImageKit
[spec-sha]: https://github.com/AppImage/AppImageSpec/tree/51c2a1465cfef1be7a159477ada8cc36a790e96c
[kit-sha]: https://github.com/AppImage/AppImageKit/tree/db405d11816bb4aa7fe21ad186492f71e043c5be
[spec-draft]: https://github.com/AppImage/AppImageSpec/blob/51c2a1465cfef1be7a159477ada8cc36a790e96c/draft.md
[spec-appdir]: https://github.com/AppImage/AppImageSpec/blob/51c2a1465cfef1be7a159477ada8cc36a790e96c/draft.md#appdir
[spec-type2]: https://github.com/AppImage/AppImageSpec/blob/51c2a1465cfef1be7a159477ada8cc36a790e96c/draft.md#type-2-image-format
[spec-update]: https://github.com/AppImage/AppImageSpec/blob/51c2a1465cfef1be7a159477ada8cc36a790e96c/draft.md#update-information
[spec-desktop]: https://github.com/AppImage/AppImageSpec/blob/51c2a1465cfef1be7a159477ada8cc36a790e96c/draft.md#desktop-integration
[tools]: ./linuxdeploy-appimagetool.md
