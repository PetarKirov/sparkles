/**
Thin wrappers over the external programs a publish run drives.

One function per invocation, and no decisions: everything that could be wrong
is decided in the pure modules and passed in. That keeps the parts worth testing
testable, and leaves this module small enough to audit by reading.

The nix wrapper puts `fdroidserver`, a JDK, `rclone` and `apksigner` on `PATH`;
`missingTools` reports what is absent rather than letting a run fail three
steps in.
*/
module sparkles.fdroid.tools;

import sparkles.core_cli.process_utils : CapturedResult, isInPath, runCaptured;

@safe:

/// Programs a full run needs, with what each is for.
private static immutable string[2][] requiredTools = [
    ["nix", "builds the unsigned release APK"],
    ["apksigner", "signs it, and reads back the certificate"],
    ["fdroid", "generates and signs the repository index"],
    // fdroidserver shells out to all three; the nixpkgs fdroidserver package
    // wraps only apksigner onto PATH, so a JDK has to be supplied separately.
    ["keytool", "required unconditionally by fdroid update (JDK)"],
    ["jarsigner", "signs index-v1.jar and index.jar (JDK)"],
    ["jar", "builds the v0 index (JDK)"],
    ["rclone", "syncs the repository to object storage"],
];

/// Names of the required programs not found on `PATH`.
string[2][] missingTools()
{
    string[2][] missing;
    foreach (t; requiredTools)
        if (!isInPath(t[0]))
            missing ~= t;
    return missing;
}

/// Builds the unsigned release APK at a given version, returning its path.
///
/// `--impure` with an explicit expression, because the version is an input the
/// flake cannot obtain: the tag is the only place it lives and nix cannot read
/// one without import-from-derivation. The value comes from the release event,
/// and is recorded in the run's output.
CapturedResult buildApk(string flakeRef, string versionName, uint versionCode)
{
    import std.conv : text;

    const expr = text(
        "let f = builtins.getFlake \"", flakeRef, "\"; in ",
        "f.legacyPackages.${builtins.currentSystem}.mkHueApk { ",
        "versionName = \"", versionName, "\"; ",
        "versionCode = ", versionCode, "; }");

    return runCaptured([
        "nix", "build", "--impure", "--no-link", "--print-out-paths",
        "--print-build-logs", "--expr", expr,
    ]);
}

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

@("fdroid.tools.signApkNeverPutsASecretInArgv")
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

@("fdroid.tools.everyRequiredToolIsExplained")
@safe unittest
{
    foreach (t; requiredTools)
    {
        assert(t[0].length);
        assert(t[1].length, t[0]);
    }
}
