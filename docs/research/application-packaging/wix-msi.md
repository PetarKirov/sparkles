# WiX Toolset and MSI (Windows installer database)

WiX compiles declarative source into Windows Installer packages and Burn bootstrapper
bundles; MSI itself is a Windows-owned relational installation and servicing contract.

| Field                   | Value                                                                                                                                                     |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Languages               | WiX: C#, C++, and WiX XML authoring; MSI: Windows Installer database tables/actions                                                                       |
| License                 | Microsoft Reciprocal License (MS-RL); WiX also documents an Open Source Maintenance Fee                                                                   |
| Repository              | [wixtoolset/wix][repo]                                                                                                                                    |
| Documentation           | [WiX documentation][wix-docs] and [Windows Installer documentation][msi-docs]                                                                             |
| Reviewed revision       | [`c5b1c40cd44145a24cb82349d988e7abdd0b94d5`][revision] (`v7.0.0-6-gc5b1c40c`)                                                                             |
| Category                | Native installer compiler/toolset plus bootstrapper engine                                                                                                |
| Supported hosts/targets | WiX targets Windows installation packages; Windows is required for authoritative install/repair/upgrade testing and normal SDK signing/validation         |
| OSS/paid boundary       | Source is MS-RL; the reviewed README says revenue-generating use requires the WiX Open Source Maintenance Fee; certificates/signing services are separate |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

MSI describes products as features composed of components and resources, then lets the
Windows Installer service plan and execute installation, repair, upgrade, rollback, and
removal under administrative policy. WiX provides source-controlled authoring,
compilation, extensions, and Burn bundles without replacing those MSI rules.

WiX states its scope directly:

> “The WiX Toolset is the most powerful set of tools available to create your Windows
> installation experience.” — [`README.md`][readme]

The important boundary is that `wix build` produces the database; `msiexec` and the
Windows Installer service interpret it. Burn produces a setup `.exe` that can detect,
cache, plan, and chain MSI/MSP/EXE prerequisites, but a Burn bundle is not itself an
MSI and has a separate bundle identity and lifecycle.

### Design philosophy

MSI favors declarative resource ownership and stable identity over arbitrary imperative
installation. The component is the indivisible unit of install state and servicing;
features are user/product selection groupings. Custom actions are an escape hatch, not
a substitute for tables, and must explicitly participate in deferred execution,
rollback, impersonation, and uninstall.

## How it works

A minimal WiX package declares one package lineage, a directory, a component, and its
key-path file:

```xml
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="Sparkles" Manufacturer="Sparkles"
           Version="1.2.3" UpgradeCode="PUT-STABLE-GUID-HERE">
    <MajorUpgrade DowngradeErrorMessage="A newer version is already installed." />
    <StandardDirectory Id="ProgramFiles6432Folder">
      <Directory Id="INSTALLFOLDER" Name="Sparkles">
        <Component Guid="PUT-STABLE-COMPONENT-GUID-HERE">
          <File Source="stage/sparkles.exe" KeyPath="yes" />
        </Component>
      </Directory>
    </StandardDirectory>
  </Package>
</Wix>
```

WiX binds this source into MSI tables and cabinet payload. At runtime Windows Installer
runs an immediate planning phase, creates execution and rollback scripts, then performs
deferred machine changes. Standard actions such as `InstallFiles`, registry actions,
shortcut actions, service actions, and `RemoveFiles` make ownership visible to repair
and uninstall.

### Identity is four different contracts

| Identifier                   | Exact role                                                                                      | Change policy                                                                                     |
| ---------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `PackageCode`                | Identifies one particular MSI database/package; stored in Summary Information `Revision Number` | Generate a new GUID whenever the package changes; never ship two different packages with one code |
| `ProductCode`                | Principal identity of one installed product configuration                                       | Keep for a small/minor update; change for a major upgrade and incompatible product identity       |
| `UpgradeCode`                | Stable family identifier used with `Upgrade`/`FindRelatedProducts` to discover related products | Keep across versions that should participate in one upgrade lineage                               |
| Component `ComponentId` GUID | Identifies one component/resource ownership unit across products and servicing                  | Keep only while the component obeys the same identity/key-path rules; do not casually regenerate  |

`ProductVersion` is not an identity GUID. Windows Installer's product-version comparison
uses the first three fields; the first two fields are limited to 0–255 and the third to
0–65535. A fourth SemVer field or build metadata cannot drive `FindRelatedProducts`.
Current WiX also has author-facing `Package/@Id`; it is not a fourth Windows Installer
identity. If `Package/@ProductCode` is omitted, WiX generates a new `ProductCode` on
each build, which deliberately produces major-upgrade identity rather than a minor
upgrade.

### Components and key paths

A component contains resources installed/uninstalled together into one scope/directory
and has one key path—commonly its principal file or registry value. Installer checks the
key path to determine component state and repair. The component GUID must not be shared
by unrelated resources; the same resource must not be installed by multiple components
with conflicting identity. Moving a file to a different directory, changing a key path,
or changing 32/64-bit context can require a new component identity. “One file per
component” is a conservative harvesting rule, not an MSI law, but it sharply reduces
servicing ambiguity.

## Analysis spine

### Input and staging

WiX consumes staged files plus `.wxs` declarations for directories, components,
features, registry values, shortcuts, services, environment changes, custom actions,
properties, UI, and upgrade policy. Cabinet files may be embedded or external.
Component authoring must be stable across releases; harvesting without a persisted GUID
and path policy can silently break repair and upgrades.

Burn consumes a chain of packages and prerequisites plus a bootstrapper application.
Its packages may be embedded or downloaded. Their hashes, cache IDs, detect conditions,
install/uninstall commands, and rollback boundaries are part of bundle correctness.

### Outputs and targets

WiX emits `.msi`, transform `.mst`, patch `.msp`, and Burn bundle `.exe` outputs,
depending on authoring. MSI package architecture and component bitness must match the
resources and target registry/filesystem views. Separate x86, x64, and Arm64 packages
are normally clearer than condition-heavy mixed payloads.

A Burn bundle can chain architecture/prerequisite packages behind one UX. This solves
bootstrap and coordination, not MSI component design; every chained package retains its
own servicing and signature semantics.

### Metadata and dependencies

MSI tables encode product name/manufacturer/version/language, package platform,
features, components/resources, media, launch conditions, and action sequences. MSI has
no general repository dependency solver. Launch conditions can reject missing
prerequisites; Burn can detect and install prerequisite packages; enterprise deployment
can order packages externally.

Keep `UpgradeCode` and component GUID policies in durable release metadata. Treat
`ProductCode`, `PackageCode`, package language/platform, and version mapping as generated
release facts rather than casually edited strings.

### Installation, upgrade, and uninstall

Windows Installer installs selected features by executing their components. Repair
re-evaluates requested features/components and key paths, then reinstalls missing or
incorrect resources according to `REINSTALLMODE`; it is not a bytewise audit of every
non-key-path file. Source/cached package availability and authored overwrite/version
rules affect what repair can restore.

- **Minor upgrade:** keeps `ProductCode`, changes `PackageCode`, increases
  `ProductVersion`, and modifies the installed product through reinstall semantics. It
  may add features/components but cannot reorganize the existing feature-component tree
  or make another change that requires a new `ProductCode`. It is commonly delivered as
  an MSP or with explicit `REINSTALL`/`REINSTALLMODE`, not treated as an unrelated
  first-time install.
- **Major upgrade:** changes `ProductCode` and `PackageCode`, normally retains
  `UpgradeCode`, detects related products, installs the new product, and schedules
  `RemoveExistingProducts`. The WiX default `afterInstallValidate` removes the old
  product before `InstallInitialize`, outside the new install transaction; if the new
  install then fails, neither version may remain. `afterInstallInitialize` puts removal
  inside rollback. `afterInstallExecute`/`afterInstallExecuteAgain` install over the old
  product before removal and are rollback-capable but demand strict component-rule and
  reference-count correctness. `afterInstallFinalize` is outside the transaction and a
  removal failure can leave both versions. Choose one schedule deliberately and inject
  failures on both sides of it.
- **Uninstall:** removes registered components/resources and product registration.
  Untracked files, application-created user data, and arbitrary custom-action effects
  remain unless explicitly and safely authored.

Rollback reverses standard deferred actions through Installer's rollback script when an
installation fails or is cancelled. It can be disabled by policy/property and cannot
magically reverse an EXE, network call, or custom action; every irreversible custom
operation needs a paired rollback action and failure testing. Commit custom actions run
only after the install script commits and therefore are not rollbackable in the same
way.

### Signing and platform trust

Authenticode-sign the final MSI and Burn `.exe` with SHA-256 and an RFC 3161 timestamp.
For external cabinets, sign cabinets first, inscribe their signatures into the MSI, then
sign the MSI; protect download URLs and hashes for Burn remote payloads. A package
signature authenticates publisher/bytes, not the safety or reversibility of privileged
custom actions.

Signing occurs after binding because any database, cabinet, or executable mutation
invalidates the corresponding signature. Burn needs its documented two-stage path:
detach and sign the engine, reattach it, then sign the final bundle executable. Verify
with `signtool verify` and execute administrative
install/repair/upgrade/uninstall tests on clean Windows VMs. MSI's internal package
identity is not cryptographic identity.

### Publication and discovery

MSIs and bundles can be direct downloads, immutable release assets, enterprise software
distribution inputs, Group Policy/management payloads, or installers referenced by
WinGet. MSI does not define a public catalog or update feed. Burn can download chained
packages but discovery of a newer bundle remains external.

### Updates and release channels

MSI supplies servicing relationships, not an update service. Publishers map stable,
beta, and enterprise channels to distinct `UpgradeCode`/product policies when
side-by-side installation is desired, or one lineage when replacement is intended.
Changing channel by accident through a shared `UpgradeCode` can remove another channel.

Patches preserve target-product constraints and transform existing MSI state; major
upgrades simplify structural change at the cost of a new `ProductCode` and two-product
transaction planning. Downgrade blocking must be explicitly authored and tested.

### Automation and CI

Pin the WiX SDK/tool version, compile source deterministically where possible, validate
the MSI, inspect tables, and retain symbol/debug outputs. CI should test first install,
change/repair, same-version invocation, upgrade from every supported predecessor,
downgrade rejection, cancellation/failure rollback, reboot cases, silent install, and
uninstall under per-user/per-machine and architecture variants.

The reviewed WiX source requires a substantial Windows/Visual Studio toolchain to build
itself. Package construction may work in other managed environments, but authoritative
Windows Installer execution, SDK validation, Authenticode verification, and lifecycle
tests are Windows-native. This research is `[source-verified]` and `[spec-verified]`,
not `[host-verified: windows]`.

### Supply-chain evidence and reproducibility

Record WiX source, extensions, compiler version, staged-file hashes, generated identity
ledger, MSI table dump, cabinet hashes, signature certificate/thumbprint, timestamp,
SBOM, and provenance. Stable component GUID generation must be deterministic from a
reviewed policy, while `PackageCode` must remain unique per package build—reproducibility
must not cause distinct bytes to reuse one `PackageCode`.

Cabinet compression, database summary timestamps, generated GUIDs, file metadata, and
Authenticode timestamps affect byte reproducibility. Compare staged inputs and unsigned
bound output separately from auditable signing.

### Extensibility and UX

WiX extensions add table authoring and native integration; custom actions can execute
code; Burn bootstrapper applications provide a custom multi-package UX. Each extension
increases privileged attack surface and compatibility obligations. Standard MSI silent
switches and logging through `msiexec` are predictable to administrators; a Burn or
custom UI must preserve reliable exit codes, logging, reboot reporting, and unattended
operation.

Prefer standard actions and a minimal feature tree. Expose one obvious install scope,
avoid user data in machine components, and keep repair from overwriting mutable
configuration.

## Strengths

- Windows-owned transaction, registration, repair, uninstall, and enterprise policy.
- Stable component model supports shared servicing and resilient repair.
- Major/minor upgrades and patches are explicit rather than filename conventions.
- WiX keeps installer databases reviewable as source and Burn handles prerequisites.
- Standard silent/logging interfaces suit managed deployment.

## Weaknesses

- Component/GUID/key-path mistakes can damage every later upgrade.
- MSI version comparison does not map directly to full SemVer.
- Custom actions are privileged, difficult to roll back, and often overused.
- Major-upgrade sequencing creates real rollback/component trade-offs.
- Windows-native validation and lifecycle matrices make CI expensive.
- Burn adds a second identity/cache/bootstrapper lifecycle beside MSI.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                        | Trade-off                                               |
| -------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------- |
| Stable `UpgradeCode` per replacement lineage | Discover versions that should upgrade each other | Accidental sharing couples unrelated channels/products  |
| New `ProductCode` for major upgrades         | Permit structural component change               | Upgrade temporarily coordinates two products            |
| New `PackageCode` for every changed package  | Keep one database identity bound to one package  | Rebuilt bytes cannot silently retain package identity   |
| Stable component GUID and key path           | Make repair/reference counting coherent          | Filesystem refactors become servicing decisions         |
| Standard actions before custom actions       | Gain Installer rollback/repair semantics         | Some unusual operations need external logic             |
| Burn only for prerequisite/chaining needs    | Coordinate multiple packages and one UX          | Adds EXE signing, cache, detection, and bundle upgrades |

## Sources

- [WiX repository at exact reviewed revision][revision], locally read from
  `$REPOS/wix` (`README.md`, schemas, compiler/linker tests, Burn engine/API)
- [Windows Installer product codes][product-code]
- [Windows Installer package codes][package-code]
- [Windows Installer upgrade codes][upgrade-code]
- [Organizing applications into components][components]
- [Changing a component code][changing-component]
- [Windows Installer major upgrades][major-upgrades]
- [Windows Installer rollback installation][rollback]
- [WiX `Package` identity schema][wix-package-schema]
- [WiX `MajorUpgrade` element][major-upgrade-element]
- [WiX signing targets for MSI and Burn][wix-signing]
- [Microsoft SignTool command reference][signtool]
- Related: [packaging concepts][concepts] · [Windows portable][portable] · [Inno Setup/NSIS][inno-nsis]

<!-- References -->

[repo]: https://github.com/wixtoolset/wix
[revision]: https://github.com/wixtoolset/wix/tree/c5b1c40cd44145a24cb82349d988e7abdd0b94d5
[readme]: https://github.com/wixtoolset/wix/blob/c5b1c40cd44145a24cb82349d988e7abdd0b94d5/README.md
[wix-docs]: https://docs.firegiant.com/wixtoolset/
[msi-docs]: https://learn.microsoft.com/windows/win32/msi/windows-installer-portal
[product-code]: https://learn.microsoft.com/windows/win32/msi/productcode
[package-code]: https://learn.microsoft.com/windows/win32/msi/package-codes
[upgrade-code]: https://learn.microsoft.com/windows/win32/msi/upgradecode
[components]: https://learn.microsoft.com/windows/win32/msi/organizing-applications-into-components
[changing-component]: https://learn.microsoft.com/windows/win32/msi/changing-the-component-code
[major-upgrades]: https://learn.microsoft.com/windows/win32/msi/major-upgrades
[rollback]: https://learn.microsoft.com/windows/win32/msi/rollback-installation
[wix-package-schema]: https://github.com/wixtoolset/wix/blob/c5b1c40cd44145a24cb82349d988e7abdd0b94d5/src/xsd/wix/Package.xsd#L86-L157
[major-upgrade-element]: https://docs.firegiant.com/wix/schema/wxs/majorupgrade/
[wix-signing]: https://github.com/wixtoolset/wix/blob/c5b1c40cd44145a24cb82349d988e7abdd0b94d5/src/wix/WixToolset.Sdk/tools/WixToolset.Signing.targets#L220-L299
[signtool]: https://learn.microsoft.com/windows/win32/seccrypto/signtool
[concepts]: ./concepts.md
[portable]: ./windows-portable.md
[inno-nsis]: ./inno-setup-nsis.md
