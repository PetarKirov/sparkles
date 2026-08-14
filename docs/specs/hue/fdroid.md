# hue on F-Droid — the release contract

_**Status:** in progress — the build-side requirements (`FDR1`–`FDR5`) are being
implemented; publication (`FDR6`–`FDR10`) waits on the out-of-tree signing keys
and the object-storage bucket. · **Date:** 2026-08-14 · **Scope:** distribution
of the Android port — `nix/packages/android/{build-apk,icon,hue,ndk}.nix`,
`apps/hue/android/{AndroidManifest.xml,icon/}`, `apps/hue/fdroid/`,
`apps/fdroid`, `.github/workflows/fdroid.yml`._

[android.md](./android.md) owns hue **running** on a phone. This document owns
hue **reaching** one: the release artifact, its identity, how it is signed, and
the channel it is served from. The split is not cosmetic — `AND1` already
requires that a release APK refuse the checked-in key, and the answer here is
stronger than that requirement anticipated: nix does not sign the published
artifact at all.

This is also the packaging specification
[Milestone 0](../../research/application-packaging/recommendations.md) asks for,
scoped to one product × one channel. It names no unowned credential, no
ambiguous version mapping, and no format without a user rationale.

## Why a self-hosted repository

f-droid.org's main repository builds every app on its own Debian buildserver.
That server has no Nix, and `nix/packages/android/` **is** the build: aapt2 →
zip → `strip-nondeterminism` → zipalign, with no Gradle, no Java and no DEX
anywhere in it. Reimplementing that against F-Droid's own SDK/NDK would create a
second build path whose output nobody compares to the first — the classic way a
distribution channel starts shipping something subtly different from what CI
tests.

A self-hosted repository keeps the existing build as the single source of truth.
The metadata is laid out in **fastlane** form regardless, so a later fdroiddata
submission is a delta rather than a rewrite.

## Identity

| Field              | Value                                                                        |
| ------------------ | ---------------------------------------------------------------------------- |
| Application id     | `dev.sparkles.hue`                                                           |
| Launcher label     | `hue`                                                                        |
| ABIs               | `arm64-v8a` + `x86_64`, one APK (not split)                                  |
| minSdk / targetSdk | 26 / 35                                                                      |
| Permissions        | **none** — the manifest declares no `<uses-permission>` at all               |
| Licence            | `BSL-1.0`; bundled components inventoried in the APK's generated `NOTICE`    |
| Source / tracker   | <https://github.com/PetarKirov/sparkles>                                     |
| Immutable origin   | the GitHub Release asset for the tag                                         |
| Channel            | a self-hosted F-Droid repository (object storage; URL pending — see `FDR10`) |

`hue-apk-repo` (`dev.sparkles.hue.repo`, the variant embedding the whole
repository as its browse surface) is a **dogfooding** artifact and is
deliberately not published: it differs only in its asset bundle, costs ~29 MB
more, and every published format carries an identity, upgrade and support
obligation.

## Version mapping

The tag is the version. `docs/guidelines/release.md` makes an annotated `vX.Y.Z`
the only place a version lives, and
[recommendations.md](../../research/application-packaging/recommendations.md)
principle 2 forbids adding a competing manifest version — so the APK's two
version fields are both **derived from the tag**, by a mapping that already
exists in this repository rather than by new arithmetic.

Android wants exactly what [`sparkles:versions`](../versions/SPEC.md) §3.2 calls
an **order key**: "a monotonic unsigned-integer key" obeying
`sign(a.orderKey <=> b.orderKey) == sign(a <=> b)`. That is the definition of a
`versionCode`. `Tiny` (`libs/versions/src/sparkles/versions/schemes/tiny.d`) is
the 4-byte scheme whose `orderKey` packs `major:16 | minor:8 | patch:8` into a
`uint`, and whose `tiny.orderKey.matchesOpCmp` unittest already asserts the
monotonicity law across a corpus.

| Tag      | `versionName` | `versionCode` |
| -------- | ------------- | ------------- |
| `v0.4.0` | `0.4.0`       | 1024          |
| `v0.4.1` | `0.4.1`       | 1025          |
| `v0.5.0` | `0.5.0`       | 1280          |
| `v1.0.0` | `1.0.0`       | 65536         |

Two guards the publisher enforces, because neither is expressible in `Tiny`:

- **`major ≤ 32767`.** Android's `versionCode` is a _signed_ int32, narrower
  than `Tiny`'s own 65535 ceiling.
- **no prerelease.** `Tiny` cannot represent one, and a prerelease has no
  business on a public channel.

Republishing a tag does **not** produce a new code: identical inputs give an
identical code, and the publisher refuses to replace bytes already served. That
is the pipeline's "never fix a published version by replacing its bytes" rule
falling out of the mapping rather than being bolted on beside it.

Nix cannot read a git tag without import-from-derivation, so the release build
takes the version as a parameter (`legacyPackages.mkHueApk`) rather than
inventing one. `packages.hue-apk` keeps its date stamp: it is a development
track, never published, and its versions never need to interleave with these.

## Architecture decisions

| Decision              | Choice                                                                                            | Where                                 |
| --------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------- |
| Who signs             | **Not nix.** The build stops after `zipalign`; `apps/fdroid` signs outside the store              | `build-apk.nix` `sign`, `apps/fdroid` |
| Key count             | Two, in two keystores: an APK key and a repository-index key                                      | `apps/fdroid/…/keystore.d`            |
| Version source        | the git tag, mapped through `sparkles:versions` `Tiny.orderKey`                                   | `apps/fdroid/…/plan.d`                |
| Icon                  | one SVG, rasterized deterministically to density PNGs by `resvg`; no checked-in binaries          | `nix/packages/android/icon.nix`       |
| Repository generation | `fdroidserver` 2.4.x over a pulled copy of the live repository, then pushed back                  | `apps/fdroid/…/fdroidserver.d`        |
| Retention             | `archive_older: 3` — `repo/` keeps 4 versions, older ones **move** to `archive/`                  | `apps/hue/fdroid/config.yml`          |
| Trigger               | `release: published`, matching `release.yml`'s stance that publication (not tag push) is the gate | `.github/workflows/fdroid.yml`        |

### Why nix must not hold the key

Every input a derivation references is copied into `/nix/store`, which is
world-readable and pushed to a public binary cache. A keystore handed to nix is
a published private key. So `buildAndroidApk` grows an explicit third state —
signed-debug, signed-release, **unsigned** — and the F-Droid path takes the
third. This also happens to be the order `apksigner` wants: it preserves an
already-aligned input's alignment, so signing after `zipalign` is correct rather
than merely convenient.

The publisher signs with **v1 (JAR) signing disabled**. apksigner enables it by
default even when the APK's own minSdk is 26, and at that floor it is dead
weight: every Android version that can install this APK understands v2/v3. With
`--v1-signing-enabled false` the signed artifact carries no `META-INF/` entries
at all, so it differs from the unsigned one by exactly the appended signing
block — measured at 4301 bytes on the 64 MB APK, against 20878 bytes and three
extra archive entries when v1 is left on. That is what makes `FDR8`'s manifest
meaningful: the only difference between what nix built and what users install is
the signature.

Losing the two keys has very different costs, which is why they are separate:

| Key   | Signs                                    | If lost                                                                                                                           |
| ----- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| APK   | `dev.sparkles.hue_<versionCode>.apk`     | **Catastrophic** — Android refuses an update signed by a different certificate; every installed user must uninstall and reinstall |
| Index | `entry.jar`, `index-v1.jar`, `index.jar` | Recoverable — users re-add the repository with the new fingerprint                                                                |

## Requirements

| ID    | Requirement                                                                                                                                                                                                                            | Status      | Where                                           |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------- |
| FDR1  | `buildAndroidApk` has exactly three states — signed-debug, signed-release (external key), unsigned — and the combinations that would leak a debug-signed or accidentally-unsigned artifact are **eval errors**, not conventions        | in progress | `build-apk.nix` `sign` + four assertions        |
| FDR2  | No signing key or passphrase reaches `/nix/store` or a process's argv (`apksigner --ks-pass env:`, never `pass:`; `/proc` is world-readable)                                                                                           | in progress | `build-apk.nix`, `apps/fdroid/…/keystore.d`     |
| FDR3  | The APK carries a launcher icon at every density, rasterized deterministically from **one** committed SVG; the F-Droid listing icon (512×512) comes from the same source                                                               | in progress | `icon.nix`, `AndroidManifest.xml`               |
| FDR4  | The declared minSdk equals the real floor. Set by the Skia/Graphite/Vulkan backend (26), above libkqueue's independent ≥23 (`sigwaitinfo`); the previously declared 21 installed on devices that could not load `libhue.so`            | done        | `ndk.nix`, `libkqueue.nix`                      |
| FDR5  | `versionName`/`versionCode` derive from the tag through `sparkles:versions` (`Tiny.orderKey`), with the signed-int32 and no-prerelease guards enforced before a build starts                                                           | in progress | `mkHueApk`, `apps/fdroid/…/plan.d`              |
| FDR6  | The published APK's signing certificate is **pinned** in metadata (`AllowedAPKSigningKeys`), so a swapped CI secret cannot publish under this application id                                                                           | planned     | `apps/hue/fdroid/metadata/dev.sparkles.hue.yml` |
| FDR7  | Publication is idempotent and never replaces published bytes: re-running may fill a missing asset, but a differing digest for an existing `versionCode` fails closed                                                                   | planned     | `apps/fdroid/…/plan.d`, `deploy.d`              |
| FDR8  | A release manifest — filename, size, SHA-256, tag, commit, signing status — is generated from the actual bytes **after** signing, and the signed APK is attached to the GitHub Release as the immutable origin before the channel copy | planned     | `apps/fdroid/…/plan.d`, `fdroid.yml`            |
| FDR9  | The workflow has a non-publishing path: `workflow_dispatch` defaults to a dry run that builds, signs, and indexes into an artifact without deploying, and forks never see the secrets                                                  | planned     | `.github/workflows/fdroid.yml`                  |
| FDR10 | The install path is documented and trust-anchored: repository URL, SHA-256 fingerprint, and QR, published in the README and the docs site                                                                                              | planned     | `README.md`, docs                               |

Deliberately **not** requirements here: SBOM and provenance attestation
(Milestone 2 of the packaging roadmap, and out of scope for one channel), per-ABI
split APKs, and any reduction in APK size.

## The pipeline

```console
$ nix build .#hue-apk-unsigned      # release APK, aligned, deliberately unsigned
$ nix run .#fdroid-publish -- all --tag v0.4.0 --dry-run
```

`fdroid-publish all` is cumulative, in the `release --stage` vocabulary:

| Stage    | Does                                                                                              |
| -------- | ------------------------------------------------------------------------------------------------- |
| `build`  | derives the version from the tag, then `mkHueApk`                                                 |
| `sign`   | `apksigner`, then verifies the resulting certificate against the pinned fingerprint               |
| `pull`   | copies the live `repo/` and `archive/` down — `fdroid update` must hash every indexed APK         |
| `index`  | guards version monotonicity against the pulled index, rewrites `CurrentVersion*`, `fdroid update` |
| `deploy` | pushes back, then re-reads the digest to confirm the upload                                       |

The pull-modify-push shape is not incidental: the deploy step is an `rclone
sync`, which **deletes remote files absent locally**. Generating an index from
an empty working directory would unpublish every previous version.

### The working directory

`fdroid` runs against a scratch tree assembled per publish, never against this
checkout (`repo/status/*.json` records the working directory's git state,
including its modified and untracked file lists). The layout below is what
`fdroid update` was verified to accept:

```text
<workdir>/
├── config.yml                  copied from apps/hue/fdroid/, with repo_url appended
├── config/categories.yml       copied
├── metadata/…                  copied, with CurrentVersion* rewritten
├── icon.png                    the 512×512 repo icon — see the trap below
├── keystore.p12                decoded from the CI secret, mode 600
├── repo/dev.sparkles.hue_<versionCode>.apk
└── archive/
```

Verified end to end against fdroidserver 2.4.2 with a real 64 MB APK: the index
carries the app under both categories, the licence, every URL, the fastlane
summary and icon, `minSdkVersion 26`, both ABIs — and, as intended, an empty
permission list and **no** `features` entry, because the `<uses-feature>` in the
manifest carries no `android:name` for fdroidserver to record.

## Credentials

Nothing here is committed. GitHub Actions secrets, gated behind the `fdroid`
environment so a reviewer stands between "CI can build this" and "CI can sign as
me":

| Secret                       | What                               |
| ---------------------------- | ---------------------------------- |
| `HUE_RELEASE_KEYSTORE_B64`   | the APK signing keystore, base64   |
| `HUE_RELEASE_KEYSTORE_PASS`  | its store passphrase               |
| `HUE_RELEASE_KEY_PASS`       | its key passphrase                 |
| `FDROID_INDEX_KEYSTORE_B64`  | the index signing keystore, base64 |
| `FDROID_INDEX_KEYSTORE_PASS` | its store passphrase               |
| `FDROID_INDEX_KEY_PASS`      | its key passphrase                 |
| `R2_ACCESS_KEY_ID`           | object-storage access key (S3 API) |
| `R2_SECRET_ACCESS_KEY`       | object-storage secret              |

Repository variables, which are not secret: `FDROID_APK_KEY_ALIAS`,
`FDROID_INDEX_KEY_ALIAS`, `FDROID_REPO_URL`, `FDROID_BUCKET`,
`FDROID_S3_ENDPOINT`.

The object-storage credential is an **access-key pair for the S3-compatible
endpoint**, which is a different kind of token from the `CLOUDFLARE_API_TOKEN`
the docs deployment already uses; one cannot substitute for the other.

Passphrases are never passed as arguments. `apksigner` is told the _name_ of the
variable (`--ks-pass env:…`) and reads it itself, and fdroidserver resolves its
own through `{env: …}` in `config.yml`. Both matter because
`/proc/<pid>/cmdline` is world-readable and fdroidserver publishes `sys.argv`
verbatim in `repo/status/update.json`.

## Traps

- **`resources.arsc` must be stored, not deflated.** The APK had no resource
  table at all until the icon landed; creating one at `targetSdk 35` makes
  Android 11+ refuse the install unless it is uncompressed and 4-byte aligned.
  aapt2 only stores it by default at minSdk ≥ 30, so the link needs `-0 arsc`.
  Assert it with `unzip -v` — nothing else in the build would catch this.
- **`repo_url` cannot come from `{env:}`.** `common.read_config` validates it
  eagerly with `config['repo_url'].endswith('/repo')`, while a `{env: …}` value
  is still a dict at that point — the failure is a bare
  `AttributeError: 'dict' object has no attribute 'endswith'`. Every other
  string key, passphrases included, resolves lazily and is fine. `archive_url`
  needs no entry at all: it defaults to `repo_url[:-4] + 'archive'`.
- **`repo_icon` resolves against the working directory, not `repo/icons/`.**
  The warning reads `repo_icon "repo/icons/icon.png" does not exist`, but the
  code checks `os.path.exists(repo_icon)` — a bare relative path — and _copies_
  it into `repo/icons/`. Putting the file where the message names it silently
  gets you a generated placeholder instead.
- **A signing-key mismatch is a warning, not an error.** With
  `AllowedAPKSigningKeys` set, an APK signed by anything else is dropped and
  `fdroid update` still exits 0 — leaving a perfectly valid, signed index with
  zero packages in it. Assert the app is present in the result; the exit code
  will not tell you.
- **Quote the fingerprint.** A 64-character digest of only decimal digits is
  parsed by YAML as an integer, and the resulting error claims `'0'` failed the
  `^[a-fA-F0-9]{64}$` check.
- **apksigner writes a v1 signature even when nothing verifies it.** At minSdk
  26 `apksigner verify` reports `v1 scheme (JAR signing): false` — and the APK
  still contains `META-INF/MANIFEST.MF`, `*.SF` and `*.RSA`, because the _signing_
  default is independent of what verification uses. Pass
  `--v1-signing-enabled false` explicitly.
- **`aapt2 dump badging` does not print the minSdk.** It reports
  `targetSdkVersion` and omits `sdkVersion` entirely, so the obvious check looks
  like the floor is missing. `aapt2 dump xmltree --file AndroidManifest.xml`
  shows the synthesized `<uses-sdk>` with both attributes; that is the one to
  verify against.
- **`aapt2 compile --dir` walks the filesystem.** Resource IDs are assigned in
  input order, so the directory form makes the resource table
  order-dependent — pass an explicitly sorted file list instead, or reproducibility
  dies quietly.
- **Never pass `--use-date-from-apk` to `fdroid update`.** It takes each APK's
  `added` date from the file mtime, which nix clamps to `SOURCE_DATE_EPOCH` —
  every release would be dated 1980.
- **`pkgs.fdroidserver` ships no JDK.** It only prefixes `apksigner` onto
  `PATH`, while `fdroid update` hard-requires `keytool`, `jarsigner` and `jar`.
  A bare `nix run nixpkgs#fdroidserver -- update` fails.
- **Run `fdroid` outside the checkout.** `repo/status/*.json` publishes
  `sys.argv` and, whenever a `.git` is present, the commit id, dirty flag, and
  the modified and untracked file lists.
- **The binary is `fdroid-publish`, not `fdroid`.** Its own wrapper puts
  `fdroidserver` on `PATH`; a binary named `fdroid` would shadow the tool it
  drives.
- **F-Droid's listing icon and the launcher icon are independent.** The client
  displays `metadata/<appid>/en-US/images/icon.png`; the home screen uses
  `res/mipmap-*/ic_launcher.png`, which `fdroid update` extracts by globbing for
  exactly that path. Shipping only an adaptive icon leaves both blank.
- **A named `<uses-feature>` filters devices.** Today's
  `<uses-feature android:glEsVersion=…>` carries no `android:name`, so
  fdroidserver ignores it and hue is never marked incompatible. A Vulkan entry
  for the Skia backend _would_ carry one, land in the index, and hide the app
  from devices that do not advertise it — so it needs `required="false"` unless
  the GLES path is genuinely gone.
- **A debug install cannot be upgraded to a release build.** Different signing
  certificate: Android's same-package-same-certificate rule means the user must
  uninstall first, losing app data. Say so in the release notes the first time.
