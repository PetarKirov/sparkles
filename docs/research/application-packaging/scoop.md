# Scoop (Windows portable package manager)

Scoop is a Windows command-line package manager whose Git-backed buckets contain JSON
manifests pointing at upstream payloads; its preferred install model extracts versioned,
portable applications and exposes them through stable shims while preserving selected
state outside the version directory.

| Field             | Value                                                                |
| ----------------- | -------------------------------------------------------------------- |
| Language          | PowerShell, with native shim executables                             |
| License           | Unlicense or MIT                                                     |
| Repository        | [ScoopInstaller/Scoop][repo]                                         |
| Documentation     | [`README.md`][readme] and the [Scoop wiki][wiki]                     |
| Reviewed revision | [`b588a06e41d920d2123ec70aee682bae14935939`][revision] (`v0.5.3`)    |
| Category          | Portable-first package manager and decentralized manifest catalog    |
| Supported hosts   | Windows PowerShell and PowerShell on Windows                         |
| Target model      | User or global installs; `32bit`, `64bit`, and `arm64` manifest arms |
| OSS/paid boundary | The reviewed client is OSS; no paid service is required              |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

Scoop turns an upstream archive, executable, installer, or script into a repeatable
command-line install without requiring the publisher to manufacture an MSI. The bucket
stores a small JSON recipe, not a hosted copy of the application. The client downloads
and hashes the declared URL, extracts or runs it, creates shims and shortcuts, records
an installed manifest, and can later switch the `current` junction to another version.

The pinned `README.md` states the publisher-facing proposition directly:

> “You just need to compress your app to a `.zip` file and provide a JSON manifest that
> describes how to install it.” — [`README.md`][readme]

### Design philosophy

Scoop optimizes for relocatable, per-user tools with minimal machine-wide side effects.
Its own summary promises to avoid PATH pollution and unexpected install/uninstall side
effects, and calls portable archives—programs that run after extraction without registry
or out-of-tree writes—the best fit. A manifest can still run `installer`, `uninstaller`,
`pre_install`, and `post_install` scripts, so “portable-first” is a convention and review
policy, not a sandbox.

Catalogs are decentralized. A **bucket** is an ordinary Git repository containing JSON
manifests. `main` is installed by default; `extras`, `versions`, `nonportable`, and other
known buckets divide policy or release streams. Any reachable Git repository can be
added, including an internal one, with no central service protocol.

## How it works

A compact manifest separates the catalog entry from the vendor payload:

```json
{
  "version": "1.2.3",
  "description": "Example command",
  "homepage": "https://example.invalid/",
  "license": "MIT",
  "url": "https://example.invalid/example-1.2.3.zip",
  "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "bin": "example.exe",
  "persist": "config",
  "checkver": "github",
  "autoupdate": {
    "url": "https://example.invalid/example-$version.zip"
  }
}
```

The pinned [`schema.json`][schema] requires `version`, `homepage`, and `license`, and
models architecture-specific `url`, `hash`, extraction, shims, environment changes,
shortcuts, dependencies, hooks, native installer/uninstaller instructions, `persist`,
`checkver`, and `autoupdate`. It rejects unknown properties in most structured blocks,
but install hooks remain PowerShell-capable.

`install_app` in [`lib/install.ps1`][install] runs pre-install handling, links
`apps/<name>/current` to the selected version, creates declared shims and shortcuts,
links persistent data, and then runs post-install handling. `link_current` implements
the stable junction. `create_shims` resolves `bin` declarations and calls `shim`, which
places a launcher in the single shims directory already on PATH. `persist_data` moves
first-install state into `persist/<name>` and links it back into each version tree.

The download path computes the declared hash and aborts on mismatch. If a manifest has
no hash, [`lib/download.ps1`][download] warns and prints a computed SHA-256 rather than
providing a catalog integrity guarantee. For releases, `checkver.ps1` discovers a new
version and `Invoke-AutoUpdate` substitutes version variables into URLs and recomputes
or extracts hashes. [`bin/auto-pr.ps1`][auto-pr] can commit and push updates or open one
pull request per changed manifest.

## Analysis spine

### Input and staging

Inputs are a bucket manifest plus one or more upstream URLs. Scoop downloads into its
cache, validates hashes, extracts into a version directory such as
`~/scoop/apps/example/1.2.3`, and records the installed manifest. `extract_dir` and
`extract_to` reshape archives; architecture blocks select different URLs, hashes, bins,
or scripts. A direct executable or PowerShell script need not be archived. Native
installers can be driven with `installer.file`, `installer.args`, or
`installer.script`, but their writes escape Scoop's version tree.

Scoop does not build or re-host the application. The bucket commit and payload URL are
separate mutable inputs, and cache contents are an optimization rather than the public
catalog.

### Outputs and targets

The normal output is an extracted application directory, a `current` junction, shims,
optional shortcuts/environment entries, and persistent links. There is no new
redistributable package artifact: Scoop consumes the vendor archive or installer.
Manifests can select `32bit`, `64bit`, and `arm64`; the host and target are Windows.
Global installs use the configured global root and may require elevation, while the
default per-user model avoids UAC.

The `nonportable` bucket acknowledges the exception: Scoop can wrap conventional
installers, but then the native installer—not Scoop's directory convention—owns much of
the filesystem, registry, privilege, and reboot behavior.

### Metadata and dependencies

Core metadata includes `version`, `homepage`, SPDX-like `license`, `description`, URL,
hash, architecture, extraction rules, `bin`, shortcuts, `env_add_path`, `env_set`, and
notes. `depends` names other Scoop packages; `suggest` is advisory. Dependencies are
package-manager ordering relationships, not declarations of every DLL or runtime inside
a portable archive.

`installer.args` and `uninstaller.args` pass switches to vendor programs. Generic hook
fields can perform arbitrary PowerShell operations before or after install/uninstall.
This is more expressive than a fixed installer-switch vocabulary but makes manifest
review equivalent to code review.

### Installation, upgrade, and uninstall

Installation creates a version directory and points `current` at it. Upgrade downloads a
new version, removes old shims, switches the junction, recreates integrations, and
relinks persistent state; old version directories can remain until `scoop cleanup`.
`scoop reset <app>@<version>` can reactivate an installed version, which provides a
simple local rollback when the old tree still exists.

Uninstall removes shims, shortcuts, environment entries, the current link, and managed
version directories, then runs declared uninstall hooks. Persistent data survives by
default; `scoop uninstall --purge` removes it. That default makes user state resilient
across upgrades and accidental uninstall, but means uninstall is intentionally not
always complete cleanup. For native installers, correctness depends on the manifest's
uninstaller and the upstream installer contract.

### Signing and platform trust

Scoop's universal payload check is the manifest hash, normally SHA-256. This establishes
that the downloaded bytes match the reviewed manifest; it does not authenticate the
bucket maintainer, prove who built the payload, or replace Authenticode. Bucket
transport and history inherit Git/hosting trust. The schema has no mandatory publisher
signature, code-signing identity, SBOM, or provenance field.

The client repository includes checksum files for its bundled native shim executables,
but that is an implementation distribution check, not a signature envelope for every
application. Hook-bearing manifests and arbitrary private buckets remain executable
supply-chain inputs.

### Publication and discovery

Publishing means committing a JSON file to a bucket. The core client clones a bucket
from a Git URL, searches manifests across added buckets, and updates them with `git
pull`; it does not upload application payloads. Official/known buckets obtain their own
pull-request review and CI, while third-party and internal buckets define independent
policy. The pinned core repository lists bucket locations but does not contain or
enforce the `main`/`extras` moderation rules.

This yields a clean internal-repository story: host a Git repository on a reachable
server, add its URL with `scoop bucket add <name> <url>`, and use ordinary Git
credentials/network controls. There is no separate Scoop repository server, promotion
API, or signed index.

### Updates and release channels

`checkver` discovers a vendor version through regex, GitHub/SourceForge conventions,
JSONPath, XPath, or custom script. `autoupdate` templates version-dependent URLs,
hashes, extraction paths, shims, shortcuts, and other fields; if no upstream hash can
be extracted, the tool downloads and computes one. This updates the **manifest**—it does
not silently publish the vendor release or update users until the bucket commit lands.

Users receive newer bucket manifests through `scoop update` and applications through
`scoop update <app>`. `scoop hold` suppresses upgrades. Alternative channels are usually
separate package names or buckets, notably `versions`; there is no first-class
stable/beta channel field or staged rollout percentage.

### Automation and CI

Bucket automation can run `checkver.ps1 -Update`, validate manifests with the JSON
schema and Scoop tests, then use `auto-pr.ps1` to push or open pull requests. The latter
creates per-app branches, commits the updated JSON, pushes them, and invokes GitHub's
`hub pull-request`. It is publication automation for catalog metadata, not an artifact
builder.

The reviewed core workflow runs the Pester suite on `windows-latest` under Windows
PowerShell and PowerShell. It tests the client and schema mechanics but does not publish
bucket updates or vendor payloads. Each bucket must supply its own review and CI policy.

### Supply-chain evidence and reproducibility

Pinned hashes make payload substitution detectable as long as the bucket commit is
trusted. Versioned app directories, retained manifests, caches, and Git history improve
auditability and rollback. Autoupdate's hash recomputation reduces maintainer toil but
still blesses whichever bytes the upstream URL serves at automation time; a protected
review boundary should compare URL provenance and expected release metadata before
merge.

Scoop neither rebuilds upstream software nor claims reproducible payloads. It emits no
SBOM, provenance attestation, transparency entry, or signed catalog snapshot. Mutable
URLs, arbitrary scripts, unsigned Git refs, native installers, and compromised bucket
automation are the principal trust seams.

### Extensibility and UX

The JSON schema covers portable archives, standalone files, scripts, native installers,
architecture variants, dependencies, shims, environment variables, shortcuts,
persistence, and version discovery. Custom buckets are the extension mechanism and can
be private. The CLI keeps a uniform `install`/`update`/`uninstall` UX across those cases.

That flexibility can conceal semantic differences. A pure archive is mostly confined to
Scoop's roots; `pre_install`, `installer.script`, or a vendor EXE can change the whole
machine. `persist` deliberately retains data, while a native uninstaller may leave data
for unrelated reasons. Consumers must read manifests, not infer safety from the common
command surface.

## Strengths

- Very small catalog entries point directly at vendor-hosted payloads.
- Version directories, a stable `current` junction, and shims make upgrades reversible.
- `persist` explicitly separates user state from replaceable application versions.
- Hash verification and schema validation cover the common portable path.
- `checkver`, `autoupdate`, and `auto-pr.ps1` form a practical catalog-update pipeline.
- Any Git repository can be a public or internal bucket without special server software.

## Weaknesses

- Bucket manifests and hooks are executable trust inputs without a mandatory signature.
- Hashes prove equality to a manifest, not publisher identity or build provenance.
- Native installer support abandons many portable isolation and uninstall advantages.
- Official moderation and publication are bucket-specific rather than client-enforced.
- Release channels are naming/bucket conventions, not typed or staged channel metadata.
- No built-in SBOM, provenance, signed index, or reproducible-build guarantee exists.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                     | Trade-off                                              |
| ------------------------------------------- | --------------------------------------------- | ------------------------------------------------------ |
| Git buckets containing JSON manifests       | Decentralized, reviewable catalogs            | Git/host identity is the catalog trust boundary        |
| Point at upstream payloads                  | Avoid binary mirroring and repository storage | Upstream availability and URL immutability are exposed |
| Version directories plus `current` junction | Stable paths and easy version switching       | Old trees require cleanup and junction support         |
| Shims instead of per-app PATH entries       | Keep PATH short and commands stable           | Shim generation becomes critical install state         |
| Explicit `persist` links                    | Preserve user data across replacement         | Default uninstall intentionally leaves state           |
| PowerShell lifecycle hooks                  | Accommodate irregular applications            | Manifests can execute arbitrary machine changes        |
| `checkver` plus templated `autoupdate`      | Automate repetitive version/hash edits        | Automation can bless compromised mutable downloads     |
| Buckets as release-channel convention       | No special channel service or schema needed   | No native promotion or staged-rollout semantics        |

## Sources

- [ScoopInstaller/Scoop at the exact reviewed revision][revision]
- [`README.md` — positioning, portable model, and known buckets][readme]
- [`schema.json` — manifest, architecture, installer, persistence, and autoupdate fields][schema]
- [`lib/install.ps1` — install order, shims, junctions, and persistence][install]
- [`lib/download.ps1` — download and hash validation][download]
- [`lib/autoupdate.ps1` and `bin/checkver.ps1` — version and checksum update mechanics][autoupdate]
- [`bin/auto-pr.ps1` — Git commit/push/pull-request automation][auto-pr]
- [`lib/buckets.ps1` and `libexec/scoop-update.ps1` — Git bucket sources and refresh][buckets]
- [`libexec/scoop-uninstall.ps1` — uninstall and purge behavior][uninstall]
- [Core GitHub Actions workflow and tests][ci]

Local provenance: `$REPOS/scoop` at
`b588a06e41d920d2123ec70aee682bae14935939`; inspected `schema.json`,
`lib/{install,download,autoupdate,buckets}.ps1`, `libexec/`, `bin/`, `test/`, and
`.github/workflows/ci.yml`. Claims are `[source-verified]`; Windows install behavior was
not executed and is not host-verified.

<!-- References -->

[repo]: https://github.com/ScoopInstaller/Scoop
[wiki]: https://github.com/ScoopInstaller/Scoop/wiki
[revision]: https://github.com/ScoopInstaller/Scoop/tree/b588a06e41d920d2123ec70aee682bae14935939
[readme]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/README.md
[schema]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/schema.json
[install]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/lib/install.ps1
[download]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/lib/download.ps1
[autoupdate]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/lib/autoupdate.ps1
[auto-pr]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/bin/auto-pr.ps1
[buckets]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/lib/buckets.ps1
[uninstall]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/libexec/scoop-uninstall.ps1
[ci]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/.github/workflows/ci.yml
