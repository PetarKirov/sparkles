# Sparkles custom terminal baseline

**Last reviewed:** September 30, 2026.

The implementation under investigation is `/home/petar/code/repos/mine/sparkles-nix-on-droid`, revision `24f3e533987f6e48f260fce0b6fa3870dcb19634`. It is a separate checkout from this documentation branch. Relevant exact sources are preserved in [the ledger][sources] because that local revision was not publicly resolvable when inspected.

## Existing capabilities

| Capability                                                      | Evidence                              | Consequence for backend work                                         |
| --------------------------------------------------------------- | ------------------------------------- | -------------------------------------------------------------------- |
| NativeActivity, `hasCode=false`                                 | [Manifest snapshot][manifest]         | No own DEX; framework JNI remains possible                           |
| Native PTY with plain shell / nix-on-droid login                | [Session implementation][session]     | PRoot can fit existing transport                                     |
| Bootstrap staging, archive checks, symlink/executable manifests | [Session implementation][session]     | Reuse transaction; verify failure/recovery cases                     |
| Own package identity and environment                            | [Session implementation][session]     | Configurable app ID; no hard dependency on `com.termux.nix`          |
| Attached JNI worker                                             | [Android host implementation][host]   | Required when calling ART outside the native event fiber             |
| Minimum API 29; target API 28                                   | [Manifest][manifest]                  | Runtime API availability differs from executable-files policy target |
| App-private data and configuration                              | [Android implementation notes][notes] | Uninstall and UID changes affect persistent store ownership          |

## What was observed on physical devices

The user reports an initial version working on a physical device. This research additionally installed and launched the existing no-DEX APK on the [Pad 8 Pro][devices] and ran a real session child there. The earlier Snapdragon 888 phone had the custom terminal installed. On that phone, its plain shell/app home was observed, while PRoot processes belonged to the **separate** `com.termux.nix` UID. That does not independently prove a completed PRoot bootstrap in the custom app on that device.

The original sibling [Android specification snapshot][spec] contains earlier emulator-oriented validation notes. User-reported physical progress and this research's app-domain evidence are recorded separately rather than silently rewriting that source snapshot.

## Gaps relevant to the research

The current local session transport cannot launch a VM simply by substituting a host executable path. A VM needs an owner, image/configuration lifecycle, guest PTY/control service and failure/reconnect model. Background durability also needs a defined Android owner/helper lifecycle; partial wake locks alone do not provide it.

The APK does not establish `MANAGE_VIRTUAL_MACHINE` / `USE_CUSTOM_VIRTUAL_MACHINE` access, hidden-API compatibility, guest image boot or no-DEX VM ownership. [AVF][avf] describes the JNI hypothesis and explicit helper alternative. Native NNS entry needs a provisioned external stack; neither stock Xiaomi device supplies its namespace requirements.

## Sources

- [Exact source ledger][sources] and [physical observations][devices].
- [Session][session], [manifest][manifest], [native Android host][host].

<!-- References -->

[sources]: ./sources.md
[manifest]: ./grounding/sparkles/AndroidManifest.xml.txt
[session]: ./grounding/sparkles/session.d.txt
[host]: ./grounding/sparkles/android_app.d.txt
[notes]: ./grounding/sparkles/android.md.txt
[spec]: ./grounding/sparkles/android-spec.md.txt
[devices]: ./device-validation/index.md
[avf]: ./avf.md
