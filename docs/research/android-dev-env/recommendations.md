# Recommended implementation and validation sequence

**Last reviewed:** September 30, 2026.

## Recommendation

Keep [PRoot][proot] as the broad-coverage backend for the working custom terminal. Define an execution-backend interface now, then add an [AVF NixOS][avf] path only after independent ownership and custom-image boot pass on a specific firmware. Retain [native namespace entry][native] as a provisioned-device option. Treat [Gunyah custom boot][gunyah] as a separate compatibility track, informed by the Pad's working stock protected guest.

The Pad changes the immediate next experiment: it can exercise AVF ownership/permission machinery, but its protected-only capability means it cannot be the assumed test target for an unsigned nonprotected nixos-avf image. Pixel 10 Pro tests are deferred at the user's request; no hardware purchase or broad SoC support recommendation follows from the current evidence.

[The contributor Pixel 7 Pro][pixel7] now supplies both AVF capability bits and an existing NNS app-UID session. Run two targeted follow-ups on that provisioned device: verify NNS source/kernel/policy identity and a real Nix workload; independently boot a bounded custom Linux root disk through non-protected AVF. The collector started no guest and used root ADB, so independent app/helper ownership and actual permission grants remain separate gates. Its current nix-on-droid frontend does not satisfy Sparkles integration by itself.

## Backend contract

Separate environment management from terminal transport. A proposed contract should cover:

- `probe`: backend availability, privilege tier, permission state, supported guest modes and a concrete failure reason.
- `prepare`: verified bootstrap/image acquisition, disk/store initialization, transaction and recovery.
- `startEnvironment` / `stopEnvironment`: owned process/VM lifetime, bounded startup and shutdown.
- `openSession`: working directory, environment, guest/local identity and a terminal byte stream.
- `resizeSession` / `signalSession` / `closeSession`: explicit control independent of VT bytes.
- `reconnect`: session discovery and reattachment after UI/transport loss.
- `status` / `logs` / `backup`: persistent state and actionable failures.

This is a research recommendation, not an accepted API specification. Translate it into a small [specification][spec-guide] after the ownership spike supplies evidence.

## Milestones and acceptance gates

| Milestone                      | Work                                                                            | Exit evidence                                                                                                   |
| ------------------------------ | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| M0: custom PRoot baseline      | Complete bootstrap in the custom package; shell/cache/package/local derivation  | Same app UID/domain recorded; canonical store, signed substitution, compiler and Git workflow run               |
| M1: capability model           | Integrate inventory and backend probes                                          | Stock app, shell and root authority reported separately; protected-only mode surfaced accurately                |
| M2: no-DEX AVF owner           | Instantiate framework via attached JNI worker or deploy explicitly owned helper | Create/start/query/stop/delete a small guest without Android Terminal running; APK still contains no DEX        |
| M3: custom Linux boot          | Prove supported boot inputs on selected firmware                                | Kernel/root disk boots; custom permission and verification path documented; no policy weakening hidden in setup |
| M4: full NixOS session         | Adapt image generation and replace Terminal guest services                      | NixOS systemd, Nix cache/build, guest PTY tabs, resize, signals, files and DNS all work                         |
| M5: lifecycle reliability      | UI/owner/transport death, backgrounding, low-memory and reboot/unlock tests     | Specified reconnect/persistence behavior, no orphan VMs or corrupted disks                                      |
| M6: provisioned native backend | Integrate launcher only on explicitly managed stack                             | Same UID, parent namespace unchanged, store unwritable to app, DNS/TTY and service tests pass                   |
| M7: measurable comparison      | Run identical workloads on same device under two functioning backends           | Repeated times, RSS/PSS, thermal/battery state and failure counts published                                     |

M2 must test actual firmware APIs rather than assume Podroid's managed hidden-API bypass can be reproduced without DEX. M3 is independent of M2: management of stock Microdroid does not prove custom NixOS support. If a protected-only device rejects arbitrary Linux boot inputs, keep PRoot as its supported environment while documenting the precise gate.

The Pixel report partially informs M1 and M6: same UID, separate namespace views and a live canonical executable are observed. It does not close M6's store-write, DNS/TTY and lifecycle tests, M0's custom-app workload gate, or M2–M4's VM ownership/boot gates. Use [the contributor protocol][contributing] for follow-up collection and explicit authority labeling.

## Device protocol

Use [the recorded probes][devices] before any installation or boot test. No unlock/flash/SELinux changes are needed for capability discovery. An advanced root/custom-kernel track is a separate provisioning decision, not an automatic next step after rejection.

For the reported Pixel 7 configuration, both capability bits have been collected; next confirm requested development grants, test disposable custom Linux boot, and exercise the app/helper owner. Record the actual kernel/policy modifications before generalizing those results to stock devices. Pixel 10 remains deferred. For MediaTek, identify actual GenieZone or other backend and vendor firmware; do not extrapolate from the Pixel. For the Pad, inspect supported custom protected configurations and firmware trust rules before investing in a large NixOS disk download.

## Performance experiment after functionality

Select a signed cache substitution, a metadata-heavy package operation, a small local compile, a Git checkout and a representative interactive editor/language-server session. Fix outputs, CPU/resource settings and storage location; separate cold cache/bootstrap from warm steady state. Publish at least five trials with median/range, memory and thermal conditions. Failures and unsupported workloads belong in the results table. Guest-only or phone-vs-tablet timings do not isolate backend cost.

## Sources

- [Comparison][comparison] and the four implementation deep dives.
- [Observed device capabilities][devices]; [research-to-spec guidance][spec-guide].

<!-- References -->

[proot]: ./nix-on-droid.md
[avf]: ./avf.md
[native]: ./native-store.md
[gunyah]: ./gunyah.md
[devices]: ./device-validation/index.md
[comparison]: ./comparison.md
[spec-guide]: ../../guidelines/spec-docs.md
[pixel7]: ./device-validation/pixel7.md
[contributing]: ./device-validation/contributing.md
