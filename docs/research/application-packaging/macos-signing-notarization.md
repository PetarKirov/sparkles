# macOS signing, notarization, and Gatekeeper (macOS trust pipeline)

macOS distribution trust is a layered protocol: code signing binds bytes and
entitlements to an identity, hardened runtime restricts execution, notarization records
Apple's malware scan, stapling carries that record offline, and Gatekeeper applies
policy when quarantined software first crosses the execution boundary.

| Field              | Value                                                                                            |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| Platform           | macOS                                                                                            |
| Language           | N/A — platform trust protocol and command-line services                                          |
| License            | N/A — Apple platform contract                                                                    |
| Repository         | N/A — proprietary Apple platform services; open-source packager integrations are cited below     |
| Documentation      | [TN2206][tn2206] · [Notarization workflow][notarization] · [Platform Security][platform-signing] |
| Signing identities | Developer ID Application; Developer ID Installer; App Store identities                           |
| Signature tool     | `codesign` (`productsign` for installer products)                                                |
| Notary client      | `xcrun notarytool`                                                                               |
| Ticket client      | `xcrun stapler`                                                                                  |
| Policy probes      | `codesign`, `spctl`, `stapler`, `pkgutil`, quarantine extended attributes                        |
| Local verification | macOS 26.3.1 tool help and manual pages                                                          |
| Category           | Artifact identity, integrity, malware scan, and launch policy                                    |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

Code signing makes tampering detectable and carries executable policy such as
entitlements. Notarization adds an Apple-operated malware and policy check without
making Apple the developer's signer. Apple's Platform Security guide states:

> “Code signing and notarization work independently—and can be performed by different
> actors—for different goals.” — [App code signing process in macOS][platform-signing]

That distinction matters: a valid signature is not proof of notarization, a successful
notarization is not source review, and neither by itself decides every subsystem's
policy.

### Design philosophy

Trust is **subsystem-specific and layered**. TN2206 says, “Trust is determined by
policy”; Gatekeeper, App Sandbox, Keychain ACLs, library validation, and other
subsystems can evaluate the same signature differently. The release pipeline therefore
must preserve identity, integrity, runtime policy, and distribution evidence all the
way from nested helper to downloaded outer container.

## How it works

### Identity, requirements, and the code directory

`codesign` hashes executable pages and sealed resources into a signature structure,
embeds entitlements and requirements, and attaches a certificate chain when signing
with an identity. The **designated requirement** (DR) is the expression by which a
subsystem recognizes future versions as the “same” code. `codesign -d -r- App.app`
displays it; `codesign -d --entitlements :- App.app` inspects entitlements; and
`codesign --verify --strict --verbose=2 App.app` verifies integrity.

Developer ID Application is for apps, executables, frameworks, plug-ins, and disk
images distributed outside the store. Developer ID Installer is for signed flat
installer packages. Ad-hoc signing (`-`) gives a local code identity but no Developer
ID chain and is not an Internet distribution credential.

### Nested signing order

Every nested executable is its own signing unit. Sign deepest children first—dylibs,
framework versions, plug-ins, app extensions, XPC services, helpers—then their
containers, and finally the outer app. Apple TN2206 warns that `--deep` during signing
“applies the signing operation recursively to the content”; it recommends signing in
build order instead. `--deep` remains useful as one verification view, but verification
should also enumerate nested code explicitly so an entitlement or identity mismatch is
not obscured.

### Hardened runtime and entitlements

For Developer ID notarization, sign executable code with hardened runtime, commonly
`codesign --options runtime`. Runtime protections include code-signing enforcement,
library validation, and restrictions on debugging or executable memory. Entitlements
are targeted exceptions and capabilities, not a general compatibility switch. Apply
the smallest per-component set: the main app's entitlements do not automatically
become the helper's, and copying broad JIT/debug entitlements to every child enlarges
the attack surface. App Sandbox is a separate entitlement-driven boundary and is
mandatory for Mac App Store apps, not all Developer ID apps.

### Notarization, ticket, and assessment

A typical outside-store pipeline is:

```bash
# Sign every known nested helper/framework first, with its own entitlements.
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: Example Corp (TEAMID)" \
    Example.app/Contents/Frameworks/ExampleHelper.app

# Then sign the outer application and verify both levels explicitly.
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: Example Corp (TEAMID)" Example.app
codesign --verify --strict --verbose=2 \
    Example.app/Contents/Frameworks/ExampleHelper.app
codesign --verify --deep --strict --verbose=2 Example.app

# Submit a temporary transport ZIP, staple the accepted ticket into the app,
# then recreate the final ZIP so the published archive contains the mutation.
ditto -c -k --keepParent Example.app Example-submission.zip
xcrun notarytool submit Example-submission.zip --keychain-profile release --wait
xcrun stapler staple Example.app
xcrun stapler validate Example.app
rm Example-submission.zip
ditto -c -k --keepParent Example.app Example.zip
spctl --assess --type execute --verbose=4 Example.app
```

`notarytool submit` accepts an archive and can authenticate with an App Store Connect
API key or Apple ID/app-specific password, preferably referenced through a Keychain
profile. `--wait` polls but does not make the service transaction local; on failure,
retrieve the structured log by submission ID. After acceptance, Apple's ticket is
available online. `stapler staple` attaches it to a supported app bundle, UDIF disk
image, or signed flat package so assessment can succeed without fetching it. A ZIP is
a submission transport but cannot itself be stapled; staple the contained app before
creating the final ZIP, or publish a stapleable DMG/PKG.

A quarantine-aware downloader adds `com.apple.quarantine` provenance. On first open,
Gatekeeper evaluates downloaded apps, plug-ins, and installer packages. Apple's guide
says Gatekeeper checks that software is from an identified developer, notarized, and
unaltered, and requests user approval before first opening it. App translocation may
launch quarantined apps from a randomized read-only location, which is another reason
not to depend on a path adjacent to the downloaded app.

## Analysis spine

### Input and staging

Begin only after all binaries, resources, entitlements, and package metadata are final.
Generate an explicit graph of signable nested components and assign each its identity,
entitlement plist, and hardened-runtime policy. Keep provisioning profiles where the
distribution model needs them. Never repair a release bundle in place after signing;
return to staging and repeat outward.

### Outputs and targets

Outputs include signed Mach-O files and bundles, a signed flat PKG where applicable,
notary submission records/logs, and stapled final artifacts. Developer ID targets
direct distribution; App Store signing targets App Store Connect and sandbox policy.
DMG, app, and flat PKG can carry tickets; ZIP is an upload/transport wrapper. Separate
credentials and entitlement profiles by target rather than treating “macOS” as one
signing mode.

### Metadata and dependencies

Identity name, Team ID, bundle identifier, designated requirement, entitlements,
certificate chain, secure timestamp, hardened-runtime flags, package identifier, and
notary submission ID form the trust metadata. Nested libraries are dependencies in two
senses: `dyld` must resolve them, and the outer signature seals their signed form.
Record certificate SHA-256 fingerprints and expiration dates, but do not pin automation
to a human-readable identity string alone when multiple valid certificates can exist.

### Install, upgrade, and uninstall

Gatekeeper chiefly assesses acquisition/first use; it is not an installer or updater.
A stable DR lets subsystems recognize a properly signed replacement as the same product.
Changing Team ID or designated requirement changes the identity input seen by macOS
subsystems; TN2206 stresses that requirement interpretation is subsystem-specific.
Treat identity migration as an explicit compatibility test for every subsystem the app
uses rather than assuming one universal migration rule. Uninstalling files does not
revoke a Developer ID certificate or remove a notarization ticket from Apple's service;
credential compromise needs certificate revocation and incident response.

### Signing and trust

The trust stack is cumulative:

| Layer            | Evidence                                               | What it does not prove                       |
| ---------------- | ------------------------------------------------------ | -------------------------------------------- |
| Code signature   | Hash seal, identity chain, requirements, entitlements  | Malware-free, reviewed source, safe behavior |
| Hardened runtime | Runtime flags plus narrowly granted exceptions         | Sandbox confinement or absence of logic bugs |
| Notarization     | Apple accepted a submitted copy after automated checks | App Store review or permanent future safety  |
| Stapled ticket   | Offline-carried notarization result                    | Fresh revocation/policy state forever        |
| Gatekeeper       | Current local policy assessment and user approval      | That every later action is harmless          |

### Publication and discovery

Publish over HTTPS with hashes and signing/notary facts. Gatekeeper's trigger depends
on provenance/quarantine, so testing only a local build misses the real path. Download
the release through a quarantine-aware agent or deliberately reproduce the extended
attribute, then assess and launch on a clean supported macOS system. App Store discovery
uses Apple's signing and review path instead of Developer ID download assessment.

### Updates and channels

Each update must be signed by an identity accepted by the updater and OS policy, with
monotonically ordered versions and a fresh notarization. Channels may use different
feeds but should normally preserve Team ID and DR. Sign the update metadata itself
where the updater supports it; Developer ID on the payload does not authenticate an
untrusted feed's downgrade or artifact-selection instructions.

### Automation and CI

Use ephemeral keychains, narrowly scoped CI secret access, noninteractive
`notarytool` credentials, and machine-readable output (`--output-format json` or
`plist`). Serialize or isolate keychain operations. Fail on every sign, verify,
notarize, staple, and assessment error; archive notary logs. Verify again after
constructing the final DMG or PKG and after downloading the published bytes. Do not
use `--force` to bypass notary preflight except for diagnosis.

### Supply chain and reproducibility

Signing authenticates the staged bytes, so a compromised build before signing receives
a perfectly valid signature. Require reviewed provenance, pinned dependencies,
hermetic or at least isolated staging, artifact manifests, and dual control over
release credentials. Secure timestamps and service-issued tickets intentionally add
external state, making the signed artifact a poor sole reproducibility target. Compare
unsigned payloads, then publish a transparent attestation linking payload hash, signed
hash, certificate, notary ID, source revision, and builder.

### Extensibility and UX

Entitlements make otherwise-forbidden capabilities possible, but each exception is a
security and review cost. Model them per nested component and explain user-visible
permissions. A healthy UX produces the normal first-open Gatekeeper dialog and then
launches without “right-click Open,” quarantine stripping, or disabling policy. An
installer should not ask users to run `xattr -d`, `spctl --global-disable`, or other
trust bypasses.

## Strengths

- Tamper-evident nested code and resources with stable identity semantics.
- Entitlements bind privileged capabilities to signed code rather than paths alone.
- Notarization and stapling support direct distribution and offline first launch.
- Gatekeeper combines identity, notarization, integrity, provenance, and consent.
- CLI tools expose verification and machine-readable CI workflows.

## Weaknesses

- Several independent layers and identities make failures difficult to diagnose.
- Nested code and per-component entitlements require an explicit signing graph.
- Apple service availability and credentials enter the release critical path.
- A valid Developer ID/notarization is not source provenance or a safety guarantee.
- Exact signed-byte reproducibility conflicts with timestamps and service tickets.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                                     | Trade-off                                                    |
| ------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------ |
| Designated requirement as stable identity   | Let policy recognize updates despite changed hashes           | Identity migration is difficult and subsystem-specific       |
| Inside-out explicit signing                 | Give every nested unit correct entitlements and seal children | More release-graph complexity                                |
| Hardened runtime by default                 | Restrict injection, unsigned memory, and library loading      | JITs/debuggers need narrowly justified exceptions            |
| Separate Developer ID Application/Installer | Distinguish executable and installer trust roles              | Two certificate classes and pipelines                        |
| Online notarization plus optional staple    | Central scanning with offline evidence                        | External service dependency and another mutable release step |
| Quarantine-triggered Gatekeeper             | Focus consent and assessment on acquired software             | Local-build tests can miss the real user path                |

## Sources

- [Apple TN2206: macOS Code Signing In Depth][tn2206]
- [Apple Platform Security: App code signing process in macOS][platform-signing]
- [Apple Platform Security: Gatekeeper and runtime protection][gatekeeper] · [durable
  snapshot][gatekeeper-snapshot]
- [Apple: Notarizing macOS software before distribution][notarization] · [durable
  snapshot][notarization-snapshot]
- [Apple: Resolving common notarization issues][notary-issues] · [durable
  snapshot][notary-issues-snapshot]
- [Durable macOS 26.3.1 `codesign(1)` and `stapler help` transcript][host-evidence]
  captured July 13, 2026; its SHA-256 is recorded in the grounding ledger.
- [Durable TN2206 text snapshot][tn2206-snapshot] and [Apple Platform Security text
  snapshot][platform-signing-snapshot], with canonical URLs and SHA-256 digests recorded
  in the [grounding ledger][grounding-ledger].
- [electron-builder signing/notarization order at pinned SHA][electron-signing]
- Related: [application bundles][bundles] · [DMG, PKG, and XIP][containers] ·
  [Homebrew][homebrew]

<!-- References -->

[tn2206]: https://developer.apple.com/library/archive/technotes/tn2206/_index.html
[host-evidence]: ./grounding/apple-host-evidence-2026-07-13.txt
[tn2206-snapshot]: ./grounding/apple-tn2206-2026-07-13.txt
[platform-signing-snapshot]: ./grounding/apple-platform-security-2026-07-13.txt
[grounding-ledger]: ./grounding/README.txt
[platform-signing]: https://support.apple.com/guide/security/app-code-signing-process-sec3ad8e6e53/web
[gatekeeper]: https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web
[gatekeeper-snapshot]: ./grounding/apple-gatekeeper-2026-07-13.html.gz
[notarization]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
[notarization-snapshot]: ./grounding/apple-notarization-2026-07-13.html.txt
[notary-issues]: https://developer.apple.com/documentation/security/resolving-common-notarization-issues
[notary-issues-snapshot]: ./grounding/apple-notarization-issues-2026-07-13.html.txt
[electron-signing]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/macPackager.ts#L420-L466
[bundles]: ./macos-app-bundles.md
[containers]: ./macos-dmg-pkg-xip.md
[homebrew]: ./homebrew.md
