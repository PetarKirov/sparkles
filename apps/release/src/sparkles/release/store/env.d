/**
The environment contract.

Every secret reaches this tool through the environment, never through argv:
`/proc/<pid>/cmdline` is world-readable, and fdroidserver's own
`repo/status/*.json` records `sys.argv` verbatim. Passphrases are therefore
passed onward by *name* (`apksigner --ks-pass env:VAR`), so the value is never
even assembled into a command line.

Which variables are required depends on how far the run goes, so resolution is
per-stage rather than all-or-nothing — a `--stage build` dry run must not demand
a signing key.
*/
module sparkles.release.store.env;

import sparkles.release.store.stage : PublishStage;

@safe:

/// Names of the environment variables this tool reads. Referenced from
/// `apps/hue/fdroid/config.yml`, which resolves the fdroidserver-side ones
/// itself through `{env: …}`, so the two must agree.
enum EnvVar : string
{
    repoUrl = "SPARKLES_FDROID_REPO_URL",

    apkKeystore = "SPARKLES_FDROID_APK_KEYSTORE",
    apkKeyAlias = "SPARKLES_FDROID_APK_KEY_ALIAS",
    apkStorePass = "SPARKLES_FDROID_APK_STORE_PASS",
    apkKeyPass = "SPARKLES_FDROID_APK_KEY_PASS",

    indexKeystore = "SPARKLES_FDROID_KEYSTORE",
    indexKeyAlias = "SPARKLES_FDROID_REPO_KEY_ALIAS",
    indexStorePass = "SPARKLES_FDROID_KEYSTORE_PASS",
    indexKeyPass = "SPARKLES_FDROID_KEY_PASS",

    bucket = "SPARKLES_FDROID_BUCKET",

    // The Play channel. Its key is the *upload* key, which Google resets on
    // request — a different risk class from the F-Droid key above.
    playServiceAccount = "SPARKLES_PLAY_SERVICE_ACCOUNT",
    playKeystore = "SPARKLES_PLAY_UPLOAD_KEYSTORE",
    playKeyAlias = "SPARKLES_PLAY_UPLOAD_KEY_ALIAS",
    playStorePass = "SPARKLES_PLAY_UPLOAD_STORE_PASS",
    playKeyPass = "SPARKLES_PLAY_UPLOAD_KEY_PASS",
}

/// Resolved configuration. Passphrase *values* are never stored — only the
/// names of the variables that hold them.
struct PublishEnv
{
    string repoUrl;
    string apkKeystore;
    string apkKeyAlias;
    string indexKeystore;
    string bucket;
}

/// The Play channel's configuration, resolved separately: the two channels are
/// peers, so neither's credentials are a precondition for the other's.
struct PlayEnv
{
    string serviceAccountFile;
    string keystore;
    string keyAlias;
    bool ok;
    MissingVar[] missing;
}

/// Reads the environment the Play channel needs.
PlayEnv resolvePlayEnv()
{
    import std.process : environment;

    PlayEnv result;
    string get(EnvVar v) => environment.get(cast(string) v, "");

    foreach (v; [
        EnvVar.playServiceAccount, EnvVar.playKeystore,
        EnvVar.playKeyAlias, EnvVar.playStorePass,
    ])
        if (get(v).length == 0)
            result.missing ~= MissingVar(cast(string) v, reasonFor(v));

    result.serviceAccountFile = get(EnvVar.playServiceAccount);
    result.keystore = get(EnvVar.playKeystore);
    result.keyAlias = get(EnvVar.playKeyAlias);
    result.ok = result.missing.length == 0;
    return result;
}

/// A missing variable, named so the message can say which.
struct MissingVar
{
    string name;
    string why;
}

/// Resolution outcome.
struct EnvResult
{
    PublishEnv env;
    MissingVar[] missing;
    bool ok() const pure nothrow @nogc => missing.length == 0;
}

/// The variables `stage` (and everything before it) needs.
EnvVar[] requiredFor(PublishStage stage) pure nothrow
{
    EnvVar[] needed;
    if (stage >= PublishStage.sign)
        needed ~= [EnvVar.apkKeystore, EnvVar.apkKeyAlias, EnvVar.apkStorePass];
    if (stage >= PublishStage.pull)
        needed ~= EnvVar.bucket;
    if (stage >= PublishStage.index)
        needed ~= [
            EnvVar.repoUrl, EnvVar.indexKeystore, EnvVar.indexKeyAlias,
            EnvVar.indexStorePass, EnvVar.indexKeyPass,
        ];
    return needed;
}

/// Why each variable is needed, for the error message.
private string reasonFor(EnvVar v) pure nothrow @nogc
{
    final switch (v)
    {
    case EnvVar.repoUrl:
        return "baked into the signed index as the repository address";
    case EnvVar.apkKeystore:
        return "the APK signing key — held outside this repository";
    case EnvVar.apkKeyAlias:
        return "which key in the APK keystore to sign with";
    case EnvVar.apkStorePass:
        return "read by apksigner as env:" ~ EnvVar.apkStorePass;
    case EnvVar.apkKeyPass:
        return "read by apksigner as env:" ~ EnvVar.apkKeyPass;
    case EnvVar.indexKeystore:
        return "the repository index signing key";
    case EnvVar.indexKeyAlias:
        return "resolved by fdroidserver from config.yml";
    case EnvVar.indexStorePass:
        return "resolved by fdroidserver from config.yml";
    case EnvVar.indexKeyPass:
        return "resolved by fdroidserver from config.yml";
    case EnvVar.bucket:
        return "the object-storage bucket rclone syncs against";
    case EnvVar.playServiceAccount:
        return "path to the Play service-account JSON key";
    case EnvVar.playKeystore:
        return "the Play upload keystore (not the app signing key — Google holds that)";
    case EnvVar.playKeyAlias:
        return "which key in the upload keystore to sign with";
    case EnvVar.playStorePass:
        return "read by jarsigner as -storepass:env";
    case EnvVar.playKeyPass:
        return "read by jarsigner as -keypass:env";
    }
}

/// Reads the environment for everything `stage` requires.
EnvResult resolveEnv(PublishStage stage)
{
    import std.process : environment;

    EnvResult result;

    string get(EnvVar v)
    {
        const value = environment.get(cast(string) v, "");
        return value;
    }

    foreach (v; requiredFor(stage))
        if (get(v).length == 0)
            result.missing ~= MissingVar(cast(string) v, reasonFor(v));

    result.env = PublishEnv(
        repoUrl: get(EnvVar.repoUrl),
        apkKeystore: get(EnvVar.apkKeystore),
        apkKeyAlias: get(EnvVar.apkKeyAlias),
        indexKeystore: get(EnvVar.indexKeystore),
        bucket: get(EnvVar.bucket),
    );
    return result;
}

@("store.env.requirementsGrowWithTheStage")
@safe unittest
{
    import std.algorithm : canFind;

    // A build-only run needs no credentials at all — that is what makes a
    // fork's dry run possible.
    assert(requiredFor(PublishStage.build).length == 0);

    assert(requiredFor(PublishStage.sign).canFind(EnvVar.apkKeystore));
    assert(!requiredFor(PublishStage.sign).canFind(EnvVar.repoUrl));

    // Indexing signs the index, so it needs that key and the address.
    const idx = requiredFor(PublishStage.index);
    assert(idx.canFind(EnvVar.repoUrl));
    assert(idx.canFind(EnvVar.indexKeystore));
    assert(idx.canFind(EnvVar.apkKeystore), "cumulative: still needs the earlier stages'");

    // Deploying needs everything.
    const dep = requiredFor(PublishStage.deploy);
    assert(dep.canFind(EnvVar.bucket));
    assert(dep.length >= idx.length);
}

@("store.env.everyVariableExplainsItself")
@safe unittest
{
    import std.traits : EnumMembers;

    static foreach (v; EnumMembers!EnvVar)
        assert(reasonFor(v).length, cast(string) v);
}
