# Contributor device probes (Android)

Collect comparable [AVF][avf] and [NNS][nns] evidence from a rooted Pixel 7 Pro
without altering its installed development environment.

**Last reviewed:** September 30, 2026.

## Run the collector

The [standalone D collector][collector] is packaged as the
`android-dev-env-probe` flake app. It supplies [ADB][adb] and GNU `timeout`; no
Android SDK or local D compiler is needed. Use the exact revision supplied with
the handoff, on a Linux or macOS computer with Nix installed:

```bash
REV=COMMIT_FROM_HANDOFF
nix run "github:PetarKirov/sparkles?rev=$REV#android-dev-env-probe" -- --list
nix run "github:PetarKirov/sparkles?rev=$REV#android-dev-env-probe" -- \
  --serial SERIAL_FROM_LIST --out ./pixel7-report
```

For an interactive device picker, use `--choose --out ./pixel7-report` instead
of `--serial`. The interface follows [core-cli's live task list][tasklist-example]
and [prompt examples][prompts-example]: themed help, a device chooser, animated
per-probe progress and explicit unavailable results. Piped output becomes a
plain transition log; saved evidence is always plain text and JSON.

Authorize USB debugging on the device. Root ADB should already be available;
the collector records `id` and never invokes `adb root` or `su`. A shell-only
run still produces a report, with denied root observations preserved.

For app and NNS process contexts, open the relevant terminal session first.
Repeat `--package PACKAGE` or `--pid PID` to select its processes. The collector
also discovers up to 32 processes whose names match Nix, PRoot, AVF and terminal
components. A process can exit during collection; a failed read is retained.

```bash
nix run "github:PetarKirov/sparkles?rev=$REV#android-dev-env-probe" -- \
  --serial SERIAL_FROM_LIST --out ./pixel7-app-report \
  --package YOUR_TERMINAL_PACKAGE --pid YOUR_NNS_SHELL_PID
```

Every ADB invocation has a 25-second timeout, a two-second termination grace
period and a 2-MiB output cap. Each report directory must be new. The directory
contains `report.md`, `manifest.json` and individual command logs with exit
statuses. Logs remove carriage returns and replace NUL terminators with
newlines; other output is retained. Unavailable probes do not abort the remaining collection. Compound
commands can contain failures before a successful final command, so inspect
the logs as well as the exit column. Running without arguments prints `SKIP`
and contacts no device; the repository CI compiles and exercises this path.

## Evidence collected and limits

| Area      | Evidence                                                                                                                 | Interpretation limit                                                              |
| --------- | ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| Device    | Model, build fingerprint, SoC, kernel, page size, memory, battery                                                        | One installed OS build; does not establish support across all Pixel releases      |
| Security  | Root/shell identity, SELinux, verified boot, seccomp and namespace limits                                                | Root ADB is a separate domain from an ordinary terminal application               |
| AVF       | Feature declarations, hypervisor nodes, `vm info`, existing guests, CLI and permission definitions                       | No guest starts; feature declarations alone do not prove custom Linux boots       |
| NNS       | Installed module metadata, launcher hashes and labels, physical store, daemon/socket, selected config and kernel options | Module metadata and hashes must be related to the author's actual source revision |
| Processes | Selected process identity, capabilities, seccomp, SELinux, namespace IDs and store-related mounts                        | Reading a running namespace does not demonstrate that another app can create it   |

The collector never executes `nix-enter`, starts or stops guests, installs APKs,
grants permissions, creates device files, changes SELinux, or modifies NNS.
Its reads may start the normal ADB host server. ADB service queries and root
metadata reads are not tests of application syscall permissions.

Reports stay local in a directory restricted to its host owner (`0700`).
Complete environment blocks, command lines, account data,
all-package inventories and Nix access tokens are not requested. Mount paths,
module metadata, build strings and process names can still reveal local
information. Review every file before publication; replace sensitive values
consistently and explain redactions. Never commit the raw report without review.

For executable application-context evidence, use [the existing Bionic syscall
probe][app-probe] and follow [the actual-app procedure][device-validation].
Capture it before and after NNS entry in the real terminal session. Root ADB,
`run-as`, and `su` with a changed UID do not reproduce that app's SELinux and
seccomp context. Record which context produced every result.

## Prompt for the contributor's agent

Replace the bracketed values before handing this prompt to the agent. The
initial task is evidence collection and a research PR; guest execution is a
separate, optional experiment agreed with the device owner.

```text
You are contributing device evidence to PetarKirov/sparkles's Android Nix
development environment research. The owner has a Google Pixel 7 Pro with
existing root ADB, AVF and their own NNS installation. The target is an
independently owned custom terminal app, without relying on the Termux app or
Android Terminal app. The Termux userspace distribution may still be reused.

Handoff revision: [COMMIT_FROM_HANDOFF]
Device serial: [SERIAL]
NNS source checkout: [PATH_TO_AUTHOR_NNS_CHECKOUT]
Terminal package / active NNS shell PID, if known: [PACKAGE_AND_PID]

1. Clone PetarKirov/sparkles (or use its existing checkout). Read AGENTS.md,
   docs/guidelines/research-docs.md, and the complete
   docs/research/android-dev-env/ catalog. Create a contribution branch.
   Inspect the handoff revision's collector source before running it.
   Run nix run "github:PetarKirov/sparkles?rev=REV#android-dev-env-probe" --
   --serial SERIAL --out NEW_LOCAL_DIRECTORY, adding --package and --pid as
   appropriate. Verify root ADB and retain denied or missing observations.
   Keep private raw output outside the tracked repository.

2. Read the local NNS source. Record git commit, remote, working tree changes
   and deployment provenance. Relate installed launcher hashes/module version
   to that source; do not infer exact source revision from module version.
   Explain the physical /data/nix/store versus canonical /nix/store view,
   mount/user namespace creation, SELinux transition, UID/capability handling,
   seccomp bypass (including any kernel patches), daemon/build users/sandbox,
   DNS bridge and terminal ioctls. Distinguish upstream NNS from local changes.
   Do not replace the installation or change its configuration.

3. With the owner's normal terminal session, collect actual app context
   before and after nix-enter: UID, SELinux, seccomp, namespaces, mounts and
   the existing app-probe.d results. Follow device-validation/index.md for
   cross-compilation and capture. Do not substitute root, run-as or su UID
   results for an app test. Record the launcher command and resulting shell
   PID. Execute nix --version, a pure evaluation, and an existing installed
   program in that NNS session. Discuss what is and is not established about
   ordinary unrooted app access, standard aarch64-linux cache compatibility,
   sandboxing and persistent ownership. Do not collect credentials or full
   environment/command-line dumps.

4. Inspect AVF's installed CLI, permissions, hypervisor, protected versus
   non-protected support, boot artifacts and currently running guests.
   Document the actual installed Android version and caller permission
   context. Booted Microdroid alone is not proof of arbitrary NixOS or a
   usable /nix/store. If the owner agrees to an active guest experiment,
   use a new disposable guest directory, <=512 MiB memory and a bounded
   execution time. Use supported AVF APIs/CLI and stop only guests created
   by this experiment. Prefer a canonical Linux root disk test that runs
   nix --version and a pure evaluation, then investigate NixOS readiness.
   State whether root ADB, protected debug mode, a vendor signing key,
   custom kernel, or privileged permissions were required. Do not change
   SELinux, kernel policy, bootloader state, firmware, existing guests, or
   the NNS daemon. Do not silently treat a debug guest's unsigned root disk
   as protected/attested application integrity. A shell CLI result does not
   prove a normal independent terminal app can own guest lifecycle.

5. Write a reproducible evidence page under
   docs/research/android-dev-env/device-validation/ and register it in
   docs/.vitepress/sidebar.json. Preserve sanitized command outputs in
   grounding/device/ as .txt artifacts, including unsuccessful tests.
   Explain any normalization or redaction. Cite primary sources at exact
   commits with real file paths; locally modified source needs snapshots
   or published commits. Compare Pixel results against the existing Pad
   and phone evidence, with explicit verified/untested distinctions.
   Update synthesis only where new evidence changes conclusions.

6. Follow research-docs.md validation and repository commit conventions.
   Compile/run changed examples with the CI helper, check links and pinned
   blob paths, and run yarn docs:build. Avoid committing generated dependency
   selections, private reports, binaries, disk images or keys. Review the
   diff for identifying information and secrets. Commit coherent changes,
   fetch origin and rebase with --update-refs on origin/main (preserve a
   backup tag before rewriting). Revalidate changes affected by rebasing.
   Push the contribution branch to an authorized remote/fork and open a PR
   against PetarKirov/sparkles main. The PR must list device/build, exact
   source revisions, verified results, failures, untested gates, validation,
   and evidence files. Return the PR URL. Do not merge it automatically.
   If publication credentials are unavailable, prepare the commit and PR
   body and tell the owner exactly what remains to publish.
```

## Sources

- [Collector implementation][collector] and [existing actual-app probe][app-probe].
- [Device validation procedures and observed results][device-validation].
- [AVF analysis][avf] and [NNS source analysis][nns].
- [Android Debug Bridge documentation][adb].

<!-- References -->

[collector]: ./examples/contributor-probe.d
[app-probe]: ./examples/app-probe.d
[device-validation]: ./index.md
[avf]: ../avf.md
[nns]: ../native-store.md
[adb]: https://developer.android.com/tools/adb
[tasklist-example]: ../../../../libs/core-cli/examples/live-tasklist.d
[prompts-example]: ../../../../libs/core-cli/examples/prompts.d
