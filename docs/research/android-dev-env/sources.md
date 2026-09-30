# Source ledger and reproducibility

**Last reviewed:** September 30, 2026.

## Revision ledger

| Source                          | Inspected revision                         | Provenance / scope                                                                                     |
| ------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| Sparkles sibling implementation | `24f3e533987f6e48f260fce0b6fa3870dcb19634` | Clean tracked tree; unpublished local revision, relevant exact files copied below                      |
| nix-on-droid local fork         | `ae506ea303c49d1866e92632d68b9a5bb7ce6d1a` | Unpublished app-ID/module changes; unrelated untracked screenshots excluded                            |
| nix-on-droid published baseline | `55b6449b4582a4ba3ce712543c973360a026db7d` | Published upstream commit, used for original scope/README                                              |
| nix-on-droid-app                | `e87b6091bffa7b6eafb1b59cc7824f5692441cd0` | Local upstream clone; installer/service source inspected                                               |
| NNS                             | `28d2229a664cbe29e55a051d648a789b6511f735` | Clean published source; launcher/kernel/bridge/tests inspected, custom VM harness not run              |
| AOSP Virtualization main        | `175a51b30123fa6b02b541f1969665708f7ec2c3` | Framework, native demo, permission, pvmfw/Microdroid source; main is not universally shipping firmware |
| AOSP Android 16 release         | `46351de83cd509bc9a9fee8fc99b07fcc0cdd0bd` | `android-16.0.0_r3` resolved to commit; custom image class checked in release tree                     |
| nixos-avf                       | `d0a62c3f64b45a39570fde31a3a490b214bf19ee` | Guest and image construction; default owner is Android Terminal                                        |
| Podroid                         | `ce0121896b2895637ab1f656cbb0d75fa2874489` | Independent managed app engine; private API use examined                                               |
| Gunyah device guide             | `61ac570c2d467274d1d7d73605dcc685af6945b8` | Rooted Lenovo demonstration, protected variant and networking                                          |
| DroidVM                         | `5c896915789294e3dbb9af81d6a53ee5f436887b` | Current backend and device registry, not locally run                                                   |
| Termux PRoot                    | `ab2e3464d04483b98a0614b470f3f8950d5a6468` | Exact PRoot revision pinned by inspected nix-on-droid expression                                       |
| Nix upstream                    | `1ed54a0fd62da96d4f5e9c806555861e46f65341` | Local chroot-store documentation and `run.cc` equal upstream files at this revision                    |

External citations in the deep dives point at exact implementation paths. Official Android policy documentation is a living source, reviewed on the date above. The QEMU and Nix manuals provide adjacent concepts rather than tested Android implementations.

## Exact local grounding

Copies preserve source headers and original contents; they are not maintained implementations or standalone CI examples. Use them to inspect the particular local revision rather than assume a moving sibling checkout still matches it.

| Source path in original checkout            | Catalog copy                           |
| ------------------------------------------- | -------------------------------------- |
| `apps/terminal/src/session.d`               | [Session snapshot][session]            |
| `apps/terminal/src/android_app.d`           | [Android host snapshot][host]          |
| `apps/terminal/android/AndroidManifest.xml` | [Manifest snapshot][manifest]          |
| `docs/apps/terminal/android.md`             | [Implementation notes snapshot][notes] |
| `docs/specs/terminal/android.md`            | [Specification snapshot][spec]         |
| `modules/build/config.nix`                  | [Package configuration][config]        |
| `modules/environment/login/login.nix`       | [Outer login][login]                   |
| `modules/environment/login/login-inner.nix` | [Inner login][inner]                   |
| `modules/environment/nix.nix`               | [Nix settings][nix]                    |
| `modules/environment/networking.nix`        | [Resolver settings][network]           |
| `pkgs/nix-directory.nix`                    | [Store bootstrap][directory]           |
| `pkgs/bootstrap.nix`                        | [Bootstrap archive][bootstrap]         |
| `pkgs/proot-termux/default.nix`             | [PRoot derivation][proot]              |

The source paths above are relative to the original checkout. All thirteen snapshots were checked for byte equality against their original files. Text suffixes protect them from code formatters; local snapshot links intentionally bypass VitePress page resolution because these are source artifacts.

## Runnable evidence

| Program                               | Demonstrates                                                   | CI / hardware boundary                                    |
| ------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------- |
| [ELF loader reader][elf-example]      | Real `PT_INTERP` parsing and loader paths                      | Ordinary Linux host                                       |
| [Namespace probe][namespace-example]  | Actual namespace syscall and unchanged parent                  | Capability-dependent; skips on rejection                  |
| [Device inventory][inventory-example] | Explicitly selected hardware inventory                         | No serial means no hardware contacted                     |
| [App-domain probe][app-example]       | Real UID, SELinux/seccomp state, namespace and socket attempts | Linux CI plus Bionic Android cross-build and UI execution |

[Device validation][devices] records the commands, privilege context, failures, cleanup and limitations. Documentation CI is not presented as an Android integration test.

## Sources

- Implementation links are collected in the subject pages: [PRoot][proot-page], [AVF][avf], [Gunyah][gunyah], [native stores][native].
- [Recorded device evidence][devices] and [baseline][baseline].

<!-- References -->

[session]: ./grounding/sparkles/session.d.txt
[host]: ./grounding/sparkles/android_app.d.txt
[manifest]: ./grounding/sparkles/AndroidManifest.xml.txt
[notes]: ./grounding/sparkles/android.md.txt
[spec]: ./grounding/sparkles/android-spec.md.txt
[config]: ./grounding/nix-on-droid/build-config.nix.txt
[login]: ./grounding/nix-on-droid/login.nix.txt
[inner]: ./grounding/nix-on-droid/login-inner.nix.txt
[nix]: ./grounding/nix-on-droid/nix.nix.txt
[network]: ./grounding/nix-on-droid/networking.nix.txt
[directory]: ./grounding/nix-on-droid/nix-directory.nix.txt
[bootstrap]: ./grounding/nix-on-droid/bootstrap.nix.txt
[proot]: ./grounding/nix-on-droid/proot.nix.txt
[elf-example]: ./concepts/examples/elf-loader.d
[namespace-example]: ./concepts/examples/namespace-probe.d
[inventory-example]: ./device-validation/examples/inventory.d
[app-example]: ./device-validation/examples/app-probe.d
[devices]: ./device-validation/index.md
[proot-page]: ./nix-on-droid.md
[avf]: ./avf.md
[gunyah]: ./gunyah.md
[native]: ./native-store.md
[baseline]: ./sparkles-baseline.md
