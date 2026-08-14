/**
Running a Play publication.

The sequencing and I/O for the Play channel, kept apart from `play.d` so that
module stays testable: everything there is either a pure transformation or a
single-call wrapper, and everything here is the order they happen in.

The whole upload is one `edits` transaction. Nothing is visible to any user
until the commit, so a failure part-way needs only the edit abandoned — which
is what the scope guard below does, rather than leaving an orphan edit that
blocks the next attempt.
*/
module sparkles.release.store.play_run;

import sparkles.release.store.play;

import std.stdio : writefln, writeln;

@safe:

/// What a Play publication needs beyond the artifact.
struct PlayOptions
{
    string applicationId;
    string aabPath;
    long versionCode;
    string releaseNotes;
    PlayTrack track;

    /// Path to the service-account JSON key.
    string serviceAccountFile;

    /// The upload keystore and how to open it. Play holds the real app signing
    /// key; this one only proves who is uploading, and Google will reset it on
    /// request — so losing it is an inconvenience, not the catastrophe the
    /// F-Droid key's loss would be.
    string keystore;
    string keyAlias;
    /// Names of the environment variables holding the passphrases, never the
    /// values: argv is world-readable through /proc.
    string storePassVar;
    string keyPassVar;
}

/// Signs an App Bundle with the upload key.
///
/// `jarsigner`, not `apksigner`: an AAB is a JAR, and apksigner only knows APKs.
/// A hardware token is reached the same way fdroidserver reaches one — a
/// PKCS#11 provider with `-keystore NONE`.
// `const`, not `in`: `-preview=in` implies `scope`, and the strings would then
// be uncopyable into the argv array below — the dip1000 clash AGENTS.md notes.
private auto signBundle(const PlayOptions opt)
{
    import sparkles.core_cli.process_utils : runCaptured;

    auto args = [
        "jarsigner",
        "-keystore", opt.keystore,
        "-storepass:env", opt.storePassVar,
        "-digestalg", "SHA-256",
        "-sigalg", "SHA256withRSA",
    ];
    if (opt.keyPassVar.length)
        args ~= ["-keypass:env", opt.keyPassVar];
    args ~= [opt.aabPath, opt.keyAlias];
    return runCaptured(args);
}

/// Publishes an App Bundle to a Play track. Returns a process exit code.
int publishToPlay(PlayOptions opt)
{
    import sparkles.core_cli.process_utils : runCaptured;
    import std.datetime : Clock;
    import std.file : exists, readText, remove, write;
    import std.path : buildPath;
    import std.process : environment, thisProcessID;
    import std.conv : text;

    if (!opt.aabPath.exists)
    {
        writefln("error: no bundle at %s", opt.aabPath);
        return 1;
    }
    if (!opt.serviceAccountFile.exists)
    {
        writefln("error: no service-account key at %s", opt.serviceAccountFile);
        return 1;
    }

    const sa = parseServiceAccount(readText(opt.serviceAccountFile));
    if (!sa.clientEmail.length)
    {
        writefln("error: %s is not a service-account key.", opt.serviceAccountFile);
        writeln("  Expected a JSON key with \"type\": \"service_account\" — an OAuth client");
        writeln("  secret has a similar shape and is the usual mix-up.");
        return 1;
    }

    // ── sign ────────────────────────────────────────────────────────────────
    writeln("· signing the bundle with the upload key");
    auto signed = signBundle(opt);
    if (!signed.succeeded)
    {
        writeln(signed.stderr);
        return 1;
    }

    // ── authenticate ────────────────────────────────────────────────────────
    // The PEM goes to a private temp file because `openssl dgst -sign` takes a
    // path, not a stream. It is removed on every exit path below.
    const now = Clock.currTime.toUnixTime;
    const keyFile = buildPath(environment.get("TMPDIR", "/tmp"),
        text("sparkles-play-key-", thisProcessID, ".pem"));
    write(keyFile, sa.privateKeyPem);
    scope (exit)
        if (keyFile.exists)
            remove(keyFile);
    version (Posix)
    {
        import std.file : setAttributes;
        import std.conv : octal;

        setAttributes(keyFile, octal!600);
    }

    const signingInput = jwtSigningInput(sa, now, now + 3600);
    auto sig = signRs256(signingInput, keyFile);
    if (!sig.succeeded)
    {
        writeln("error: could not sign the authentication assertion.");
        writeln(sig.stderr);
        return 1;
    }
    const assertion = signingInput ~ "." ~ base64Url(cast(const(ubyte)[]) sig.stdout);

    auto tokenReply = exchangeAssertion(sa.tokenUri, assertion);
    if (!tokenReply.succeeded)
    {
        writefln("error: token exchange failed: %s", apiError(tokenReply.stdout));
        return 1;
    }
    const token = replyField(tokenReply.stdout, "access_token");
    if (!token.length)
    {
        writeln("error: token exchange returned no access_token.");
        return 1;
    }

    // ── the edit transaction ────────────────────────────────────────────────
    writeln("· opening an edit");
    auto opened = insertEdit(token, opt.applicationId);
    if (!opened.succeeded)
    {
        writefln("error: could not open an edit: %s", apiError(opened.stdout));
        return 1;
    }
    const editId = replyField(opened.stdout, "id");
    if (!editId.length)
    {
        writeln("error: the edit reply carried no id.");
        return 1;
    }

    // Abandon rather than leak: an edit left open is not harmful, but it is
    // confusing state for the next run to find.
    bool committed;
    scope (exit)
        if (!committed)
            cast(void) deleteEdit(token, opt.applicationId, editId);

    writefln("· uploading %s", opt.aabPath);
    auto uploaded = uploadBundle(token, opt.applicationId, editId, opt.aabPath);
    if (!uploaded.succeeded)
    {
        writefln("error: upload failed: %s", apiError(uploaded.stdout));
        return 1;
    }

    writefln("· assigning to the %s track", trackName(opt.track));
    auto assigned = assignTrack(
        token, opt.applicationId, editId, opt.track, opt.versionCode, opt.releaseNotes);
    if (!assigned.succeeded)
    {
        writefln("error: track assignment failed: %s", apiError(assigned.stdout));
        return 1;
    }

    writeln("· committing");
    auto commit = commitEdit(token, opt.applicationId, editId);
    if (!commit.succeeded)
    {
        writefln("error: commit failed: %s", apiError(commit.stdout));
        return 1;
    }
    committed = true;

    writefln("published %s versionCode %s to the %s track",
        opt.applicationId, opt.versionCode, trackName(opt.track));
    return 0;
}
