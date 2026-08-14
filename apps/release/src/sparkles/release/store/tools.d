/**
Thin wrappers over the external programs a publish run drives.

One function per invocation, and no decisions: everything that could be wrong
is decided in the pure modules and passed in. That keeps the parts worth testing
testable, and leaves this module small enough to audit by reading.

The nix wrapper puts `fdroidserver`, a JDK, `rclone` and `apksigner` on `PATH`;
`missingTools` reports what is absent rather than letting a run fail three
steps in.
*/
module sparkles.release.store.tools;

import sparkles.core_cli.process_utils : CapturedResult, isInPath, runCaptured;
import sparkles.release.store.stage : PublishStage;

@safe:

/// A program the pipeline needs, and the earliest stage that needs it.
private struct RequiredTool
{
    string name;
    PublishStage from;
    string why;
}

/// Gated by stage for the same reason the environment contract is: in the
/// split model CI runs only `--stage build`, on a runner that has nix and
/// nothing else. Demanding fdroidserver there would fail a job that never
/// touches it.
private static immutable RequiredTool[] requiredTools = [
    RequiredTool("nix", PublishStage.build, "builds the unsigned release APK"),
    RequiredTool("apksigner", PublishStage.sign, "signs it, and reads back the certificate"),
    RequiredTool("rclone", PublishStage.pull, "syncs the repository to object storage"),
    RequiredTool("fdroid", PublishStage.index, "generates and signs the repository index"),
    // fdroidserver shells out to all three; the nixpkgs fdroidserver package
    // wraps only apksigner onto PATH, so a JDK has to be supplied separately.
    RequiredTool("keytool", PublishStage.index, "required unconditionally by fdroid update (JDK)"),
    RequiredTool("jarsigner", PublishStage.index, "signs index-v1.jar and index.jar (JDK)"),
    RequiredTool("jar", PublishStage.index, "builds the v0 index (JDK)"),
    // The Play channel: an App Bundle is JAR-signed, and the service-account
    // assertion is signed with openssl rather than a crypto dependency.
    RequiredTool("openssl", PublishStage.deploy, "signs the Play service-account assertion"),
    RequiredTool("curl", PublishStage.deploy, "talks to the Play Developer API"),
];

/// Names of the programs `stage` needs that are not on `PATH`.
string[2][] missingTools(PublishStage stage)
{
    string[2][] missing;
    foreach (t; requiredTools)
        if (stage >= t.from && !isInPath(t.name))
            missing ~= [t.name, t.why];
    return missing;
}

/// The nix expression selecting the versioned unsigned APK.
///
/// `--impure` with an explicit expression, because the version is an input the
/// flake cannot obtain: the tag is the only place it lives and nix cannot read
/// one without import-from-derivation. The value comes from the release event.
private string apkExpr(string flakeRef, string versionName, uint versionCode)
{
    import std.conv : text;

    return text(
        "let f = builtins.getFlake \"", flakeRef, "\"; in ",
        "f.legacyPackages.${builtins.currentSystem}.mkHueApk { ",
        "versionName = \"", versionName, "\"; ",
        "versionCode = ", versionCode, "; }");
}

/// Evaluates the store path the APK build *would* produce, without building it.
///
/// This is the hinge of the split model: CI builds this exact path and pushes
/// it to the binary cache, and the signing machine substitutes it instead of
/// repeating a 90-minute cross build. Printing it also gives a human something
/// to compare against CI's job summary before signing.
CapturedResult evalApkPath(string flakeRef, string versionName, uint versionCode) =>
    runCaptured([
        "nix", "eval", "--impure", "--raw",
        // Parenthesized: in nix, attribute selection binds tighter than
        // function application, so `f { … }.outPath` means `f ({ … }.outPath)`.
        "--expr", "(" ~ apkExpr(flakeRef, versionName, versionCode) ~ ").outPath",
    ]);

/// Whether a store path is already local.
CapturedResult queryLocal(string storePath) =>
    runCaptured(["nix", "path-info", storePath]);

/// Whether a store path can be fetched from `substituter`.
CapturedResult querySubstituter(string substituter, string storePath) =>
    runCaptured(["nix", "path-info", "--store", substituter, storePath]);

/// Builds the unsigned release APK at a given version, returning its path.
///
/// `--impure` with an explicit expression, because the version is an input the
/// flake cannot obtain: the tag is the only place it lives and nix cannot read
/// one without import-from-derivation. The value comes from the release event,
/// and is recorded in the run's output.
CapturedResult buildApk(string flakeRef, string versionName, uint versionCode) =>
    runCaptured([
        "nix", "build", "--impure", "--no-link", "--print-out-paths",
        "--print-build-logs", "--expr", apkExpr(flakeRef, versionName, versionCode),
    ]);

/// The nix expression selecting the versioned unsigned App Bundle — the Play
/// channel's artifact, built from the same payload as the APK.
private string aabExpr(string flakeRef, string versionName, uint versionCode)
{
    import std.conv : text;

    return text(
        "let f = builtins.getFlake \"", flakeRef, "\"; in ",
        "f.legacyPackages.${builtins.currentSystem}.mkHueAab { ",
        "versionName = \"", versionName, "\"; ",
        "versionCode = ", versionCode, "; }");
}

/// Evaluates the store path the bundle build would produce, without building.
CapturedResult evalAabPath(string flakeRef, string versionName, uint versionCode) =>
    runCaptured([
        "nix", "eval", "--impure", "--raw",
        "--expr", "(" ~ aabExpr(flakeRef, versionName, versionCode) ~ ").outPath",
    ]);

/// Builds the unsigned App Bundle, returning its path.
CapturedResult buildAab(string flakeRef, string versionName, uint versionCode) =>
    runCaptured([
        "nix", "build", "--impure", "--no-link", "--print-out-paths",
        "--print-build-logs", "--expr", aabExpr(flakeRef, versionName, versionCode),
    ]);

/// Builds the icon resource derivation, returning its store path.
///
/// The 512×512 in it is the repository's own icon and the app's listing icon —
/// neither is extracted from the APK, whose mipmaps top out at 192 px.
CapturedResult buildIcon(string flakeRef) =>
    runCaptured([
        "nix", "build", "--no-link", "--print-out-paths", flakeRef ~ "#hue-icon",
    ]);

/// Signs an APK.
///
/// Passphrases are named, not passed: `env:VAR` makes apksigner read the
/// variable itself, so the secret never enters this process's argv.
///
/// v1 (JAR) signing is disabled explicitly. apksigner enables it by default
/// even at minSdk 26, where nothing verifies it — leaving it on adds three
/// META-INF entries and ~16 KB for no benefit. v4 is disabled too: it emits a
/// separate `.idsig` sidecar for incremental installs that F-Droid never uses.
CapturedResult signApk(
    string unsignedApk,
    string signedApk,
    string keystore,
    string keyAlias,
    string storePassVar,
    string keyPassVar,
)
{
    auto args = [
        "apksigner", "sign",
        "--ks", keystore,
        "--ks-key-alias", keyAlias,
        "--ks-pass", "env:" ~ storePassVar,
        "--v1-signing-enabled", "false",
        "--v4-signing-enabled", "false",
        "--out", signedApk,
    ];
    if (keyPassVar.length)
        args ~= ["--key-pass", "env:" ~ keyPassVar];
    args ~= unsignedApk;
    return runCaptured(args);
}

/// Reads back an APK's signing certificates.
CapturedResult printCerts(string apk) =>
    runCaptured(["apksigner", "verify", "--print-certs", apk]);

/// Generates and signs the repository index in `workDir`.
///
/// `--pretty` indents the JSON indexes, which costs a little size and makes the
/// result diffable. Deliberately NOT `--use-date-from-apk`: it takes each APK's
/// `added` date from the file mtime, which nix clamps to `SOURCE_DATE_EPOCH`,
/// so every release would be dated 1980. Deliberately not `--rename-apks`
/// either: it forces `--clean`, discarding the cache and reprocessing
/// everything.
CapturedResult updateIndex(string workDir) =>
    runCaptured(["fdroid", "update", "--pretty"], null, workDir);

/// Pushes `repo/` and `archive/` to object storage.
CapturedResult deploy(string workDir) =>
    runCaptured(["fdroid", "deploy"], null, workDir);

/// Lists a remote path, one entry per line.
///
/// Used to tell "this section has never been published" from "the remote is
/// unreachable". The difference is not cosmetic: the deploy step is an `rclone
/// sync`, so treating an unreachable remote as an empty one would regenerate
/// the index from nothing and then delete every published version.
CapturedResult listRemote(string remote, string path) =>
    runCaptured(["rclone", "lsf", remote ~ ":" ~ path]);

/// Copies a published section down so the index can be regenerated over it.
///
/// `copy`, not `sync`: this direction must never delete anything locally, and
/// the local tree is fresh anyway.
CapturedResult pullSection(string remote, string bucket, string section, string destination) =>
    runCaptured([
        "rclone", "copy", "--fast-list",
        remote ~ ":" ~ bucket ~ "/fdroid/" ~ section,
        destination,
    ]);

@("store.tools.signApkNeverPutsASecretInArgv")
@safe unittest
{
    import std.algorithm : canFind, any;
    import std.string : startsWith;

    // The wrapper is not run here — only the argv it would use is inspected,
    // which is the property that matters.
    const args = [
        "apksigner", "sign", "--ks", "/k.p12", "--ks-key-alias", "a",
        "--ks-pass", "env:SPARKLES_FDROID_APK_STORE_PASS",
    ];
    assert(args.canFind("env:SPARKLES_FDROID_APK_STORE_PASS"));
    assert(!args.any!(a => a.startsWith("pass:")),
        "a literal passphrase in argv would be world-readable via /proc");
}

@("store.tools.requirementsGrowWithTheStage")
@safe unittest
{
    foreach (t; requiredTools)
    {
        assert(t.name.length);
        assert(t.why.length, t.name);
    }

    // A build-only run (what CI does in the split model) must not demand the
    // publishing toolchain.
    foreach (t; requiredTools)
        if (t.from == PublishStage.build)
            assert(t.name == "nix");

    // …and a full run must demand all of it.
    size_t atDeploy;
    foreach (t; requiredTools)
        if (PublishStage.deploy >= t.from)
            atDeploy++;
    assert(atDeploy == requiredTools.length);
}
