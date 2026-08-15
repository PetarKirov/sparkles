# Android Release Runbook

Operating the app channels: what to type, what to check, and what to do when a
step fails. The **why** lives in [hue on F-Droid](../specs/hue/fdroid.md); this
page assumes you have a tag to publish and the hardware tokens in front of you.

> [!IMPORTANT]
> Two things here cannot be undone. A **pushed tag** is ingested by
> code.dlang.org on its own schedule, and a **published `versionCode`** can
> never be reused on either channel. Everything else — the index, a Play track,
> a failed edit — is repeatable. When something goes wrong mid-publish, the
> first question is always which side of that line you are on; the
> [failure table](#when-something-fails) answers it per case.

## Where the work happens

Signing keys live on hardware tokens, which a GitHub-hosted runner cannot
reach. So the pipeline is split, and **you are the second half**:

|                                | CI  | You |
| ------------------------------ | --- | --- |
| Builds the APK and App Bundle  | ✓   |     |
| Pushes and pins them to Cachix | ✓   |     |
| Signs them                     |     | ✓   |
| Publishes both channels        |     | ✓   |

Nothing signing-related exists in CI — no passphrase, no keystore, no secret to
leak. What joins the halves is a nix store path: CI prints it, and your machine
must resolve the same one.

## Before the first publish

One-time. Until all four are done, the pipeline stops at `--stage index`.

- [ ] **Generate two keystores**, off any CI machine, and back them up offline.

      ```bash
      keytool -genkeypair -storetype PKCS12 -keyalg RSA -keysize 4096 \
        -validity 10000 -keystore hue-release.p12  -alias hue-release   -dname 'CN=…'
      keytool -genkeypair -storetype PKCS12 -keyalg RSA -keysize 4096 \
        -validity 10000 -keystore fdroid-index.p12 -alias sparkles-index -dname 'CN=…'
      ```

      They are not interchangeable and the consequences of losing them are not
      comparable — see [key custody](#key-custody).

- [ ] **Pin the APK certificate.** Sign anything once, read the fingerprint, and
      put it in `apps/hue/fdroid/metadata/dev.sparkles.hue.yml` under
      `AllowedAPKSigningKeys` — **quoted**, or an all-digit digest is parsed as
      a YAML integer and rejected.

      ```bash
      apksigner verify --print-certs <some.apk> | grep 'SHA-256 digest'
      ```

- [ ] **Create the object-storage bucket** and an access-key pair for its
      S3-compatible endpoint. That is a different credential type from a
      Cloudflare API token; one cannot substitute for the other.

- [ ] **Decide the public URL.** It must end in `/repo`. A custom domain is
      worth having: it puts a cache in front of a ~57 MB download.

For Play, additionally: the developer account, the $25 registration, identity
verification, and — for personal accounts created after 13 Nov 2023 — **12
testers opted into a closed test for 14 continuous days** before production
access. That last one is wall-clock-bound, not effort-bound, so start it early.

## Routine release

Steps 1–7 are the source release ([Cutting a Release](./release.md)). This
runbook picks up after the GitHub Release is published.

### 1. Wait for CI to build and cache the artifacts

Publishing the GitHub Release fires the **F-Droid** workflow. It builds the
unsigned APK and App Bundle, pushes them to Cachix, pins them, and writes the
store path to its job summary.

```bash
gh run list --workflow F-Droid --limit 1
gh run watch <run-id>
```

Do not proceed until it is green. If it failed, nothing is published and
nothing is lost — fix and re-run it.

### 2. Confirm your machine resolves the same artifact

```bash
release path --tag v0.5.0
```

This must print **exactly** the store path in the workflow's job summary. If it
differs, your tree is not what CI built — see
[the paths differ](#the-paths-differ).

### 3. Publish

On the machine with the tokens, with the environment from
[credentials](#credentials) exported:

```bash
nix run .#release-full -- publish --tag v0.5.0 --stage deploy
```

Both channels by default. `--channels fdroid` or `--channels play` narrows it;
`--track` picks the Play track (`internal` by default — promote from the Play
Console once someone has actually looked at it).

> [!NOTE]
> `release-full` (~3.2 GiB) is the configuration with fdroidserver, a JDK,
> rclone and bundletool pinned. Plain `.#release` is the lean package (~48 MB)
> that CI uses to build; it cannot publish, and says so rather than failing
> halfway.

A dry run prints the whole plan and touches nothing:

```bash
nix run .#release-full -- publish --tag v0.5.0 --stage deploy --dry-run
```

### 4. Verify

**F-Droid** — add the repository to a real client (or serve `repo/` locally
first) and confirm the app appears with its icon, description, screenshots and
"requires no permissions". Then check the index directly:

```bash
curl -s "$SPARKLES_FDROID_REPO_URL/index-v2.json" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); \
      p=d["packages"]["dev.sparkles.hue"]; \
      print(sorted(v["manifest"]["versionCode"] for v in p["versions"].values()))'
```

The new `versionCode` must be listed. An index that parses, is signed, and
contains **zero packages** is a specific failure — see
[the index came out empty](#the-index-came-out-empty).

**Play** — the Play Console shows the bundle on the chosen track. It is not
live until review passes, which is not instant.

## When something fails

The publisher is built to fail closed, so most of these leave nothing behind.

| Symptom                                        | Published anything? | Do this                                                         |
| ---------------------------------------------- | ------------------- | --------------------------------------------------------------- |
| CI's F-Droid workflow failed                   | No                  | Fix, re-run. Nothing was signed.                                |
| `is neither in the local store nor on <cache>` | No                  | [The paths differ](#the-paths-differ)                           |
| `cannot list <remote> — refusing to continue`  | No                  | [The remote is unreachable](#the-remote-is-unreachable)         |
| `this versionCode is already published`        | Previously          | [Already published](#already-published)                         |
| `a higher versionCode is already published`    | Previously          | Same — you are trying to publish an older tag over a newer one. |
| `<appid> is absent from the generated index`   | No                  | [The index came out empty](#the-index-came-out-empty)           |
| F-Droid succeeded, Play failed                 | **F-Droid yes**     | [A partial publish](#a-partial-publish)                         |
| Play upload rejected                           | No                  | Read the message; the edit was abandoned automatically.         |

### The paths differ

`release path` and CI disagree, or the artifact is not cached. Three causes, in
order of likelihood:

1. **CI has not finished**, or never ran for this tag.
2. **Your tree is dirty, or on a different commit.** `builtins.getFlake` hashes
   the working tree, not the commit, so any uncommitted change produces a
   different derivation. `git status` and `git log -1`.
3. **`--flake` points somewhere else** than what CI evaluated.

Do **not** reach for `--no-require-cached` to make the message go away. That
builds the artifact locally, which takes ~90 minutes and — worse — means you
would be signing something nobody compared against CI. The guard exists for
exactly that reason. It is legitimate only when you have deliberately decided
to publish a local build.

### The remote is unreachable

The publisher lists the bucket before deciding a section is absent, and refuses
to continue if that listing fails. This is deliberate: the deploy step is an
`rclone sync`, which deletes remote files absent locally. Treating an
unreachable remote as an empty one would regenerate the index from nothing and
then **unpublish every existing version**.

Check credentials and connectivity (`rclone lsf sparkles:<bucket>`) and retry.
Nothing was changed.

### Already published

That `versionCode` is on the channel and its bytes are immutable. There is no
supported way to replace them, and no flag to force it.

Cut a new tag. If the release was wrong, the fix is `v0.5.1`, not a second
`v0.5.0`.

### The index came out empty

`fdroid update` reports a signing-key mismatch as a **warning**, exits 0, and
writes a valid signed index containing no packages. The publisher catches this
by reading the index back, which is why you see an error instead of a silent
non-publication.

The cause is almost always `AllowedAPKSigningKeys` not matching the key that
actually signed. The error prints the signer's fingerprint; compare it with the
metadata:

```bash
grep -A2 AllowedAPKSigningKeys apps/hue/fdroid/metadata/dev.sparkles.hue.yml
```

If the metadata is wrong, fix and re-run — nothing was deployed. If the
_keystore_ is wrong, you signed with the wrong key; do not publish it.

### A partial publish

The channels are peers, so one can succeed while the other fails, and the exit
code reflects any failure. Recovery is **asymmetric**:

- **Play failed, F-Droid succeeded** — safe to re-run Play alone:

  ```bash
  nix run .#release-full -- publish --tag v0.5.0 --stage deploy --channels play
  ```

  The edit is a transaction; a failed attempt was abandoned and left nothing.

- **F-Droid failed, Play succeeded** — also safe to re-run F-Droid alone,
  _provided the F-Droid failure happened before deploy_. If the APK reached the
  repository, its `versionCode` is spent: see [already published](#already-published).

Re-running the whole command after a partial success is safe too — the
already-published channel refuses and the other proceeds — but narrowing with
`--channels` makes the intent explicit.

## Key custody

| Key                         | If lost                                                                                                                                                                                                                                                       |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **F-Droid APK signing key** | **Catastrophic.** Android refuses an update signed by a different certificate. Every installed user must uninstall — losing app data — and reinstall. There is no recovery, and v3 key rotation does not help: it needs the old key to authorise the new one. |
| Play **upload** key         | Recoverable. Google holds the real app signing key and re-signs every upload; request an upload-key reset in the Play Console.                                                                                                                                |
| F-Droid **index** key       | Recoverable. Users re-add the repository with the new fingerprint.                                                                                                                                                                                            |

That asymmetry is why the F-Droid key is generated offline, imported to several
hardware tokens, and backed up separately, while the Play upload key can live
on one token.

A certificate cannot vouch for a second key: Android does no chain validation
for app signing and pins the certificate itself, so a shared issuer confers
nothing. Nor can the certificate be renewed for the same key — a new
certificate is a new identity. Generate it with decades of validity and never
touch it.

## Credentials

Exported on the signing machine, never in CI. Passphrases are read by name
(`env:VAR`), never passed as arguments — `/proc` is world-readable and
fdroidserver publishes `sys.argv` in the index it deploys.

| Variable                                                                                                                  | For                                                                                     |
| ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `SPARKLES_FDROID_APK_KEYSTORE`, `…_APK_KEY_ALIAS`, `…_APK_STORE_PASS`, `…_APK_KEY_PASS`                                   | signing the APK                                                                         |
| `SPARKLES_FDROID_KEYSTORE`, `SPARKLES_FDROID_REPO_KEY_ALIAS`, `SPARKLES_FDROID_KEYSTORE_PASS`, `SPARKLES_FDROID_KEY_PASS` | signing the repository index                                                            |
| `SPARKLES_FDROID_REPO_URL`, `SPARKLES_FDROID_BUCKET`                                                                      | where the repository lives                                                              |
| `SPARKLES_PLAY_SERVICE_ACCOUNT`                                                                                           | Play API service-account JSON key                                                       |
| `SPARKLES_PLAY_UPLOAD_KEYSTORE`, `…_UPLOAD_KEY_ALIAS`, `…_UPLOAD_STORE_PASS`, `…_UPLOAD_KEY_PASS`                         | signing the App Bundle                                                                  |
| `RCLONE_CONFIG_SPARKLES_*`                                                                                                | the rclone remote, defined entirely in the environment so no credential file is written |

## Stages

`--stage` is cumulative — naming one runs it and everything before it. The
default is `index`, which does everything except publish.

| Stage    | Does                                                                        |
| -------- | --------------------------------------------------------------------------- |
| `build`  | derive the version from the tag, fetch/build the artifact                   |
| `sign`   | sign it, verify the certificate against the pin, write the release manifest |
| `pull`   | copy the live `repo/` and `archive/` down                                   |
| `index`  | guard the version, rewrite `CurrentVersion*`, `fdroid update`               |
| `deploy` | push back, and publish Play                                                 |

Stopping at `index` is a full dress rehearsal: it signs, generates and signs a
real index, and no user can observe any of it.
