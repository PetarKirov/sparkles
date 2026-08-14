/**
The publish run: the ordered steps, and the reporting around them.

Every decision worth testing has already been made by the time control reaches
here — `version_map` mapped the tag, `index` decided whether the version may be
published, `workfiles` produced the edited configuration. This module is the
sequencing and the I/O.
*/
module sparkles.fdroid.run;

import sparkles.fdroid.certs : signerFingerprints;
import sparkles.fdroid.env : EnvVar, PublishEnv, resolveEnv;
import sparkles.fdroid.index : appFromIndex, checkPublishable, describe, IndexedApp, PublishRefusal;
import sparkles.fdroid.manifest : ReleaseManifest, toJson;
import sparkles.fdroid.stage : Stage, stageNames;
import sparkles.fdroid.tools;
import sparkles.fdroid.version_map : ApkVersion, apkVersionForTag, describe;
import sparkles.fdroid.workfiles : withCurrentVersion, withRepoUrl;

import std.stdio : writeln, writefln;

@safe:

/// The application this repository publishes.
enum applicationId = "dev.sparkles.hue";

/// Inputs a run needs beyond the environment.
struct RunOptions
{
    string tag;
    Stage stage;
    bool dryRun;
    string workDir;
    string metadataDir;
    string flakeRef;
    string rcloneRemote;
    /// Refuse to build the APK locally — it must come from the binary cache,
    /// which is what makes the split model a split rather than a duplication.
    bool requireCached;
    string substituter;
}

/// Runs the publish pipeline. Returns a process exit code.
int runPublish(RunOptions opt)
{
    import std.array : join;
    import std.conv : text;
    import std.file : exists, getSize, mkdirRecurse, readText, write;
    import std.path : buildPath;

    // ── the version, before anything else can fail ──────────────────────────
    const mapped = apkVersionForTag(opt.tag);
    if (!mapped.ok)
    {
        writefln("error: cannot publish tag %s: %s", opt.tag, describe(mapped.error));
        return 1;
    }
    const v = mapped.version_;
    const apkName = text(applicationId, "_", v.code, ".apk");

    writefln("tag %s → versionName %s, versionCode %s", opt.tag, v.name, v.code);
    writefln("stage: through %s (of %s)", opt.stage, stageNames);
    writefln("artifact: repo/%s", apkName);

    // ── environment ─────────────────────────────────────────────────────────
    const env = resolveEnv(opt.stage);
    if (!env.ok)
    {
        writeln("error: missing environment for this stage:");
        foreach (m; env.missing)
            writefln("  %-38s %s", m.name, m.why);
        return 1;
    }

    if (opt.dryRun)
    {
        writeln();
        writeln("dry run — nothing was built, signed, written or uploaded.");
        writefln("  work dir     %s", opt.workDir);
        writefln("  metadata     %s", opt.metadataDir);
        if (opt.stage >= Stage.index)
            writefln("  repo url     %s", env.env.repoUrl);
        if (opt.stage >= Stage.deploy)
            writefln("  bucket       %s (rclone remote %s)", env.env.bucket, opt.rcloneRemote);
        return 0;
    }

    const missing = missingTools(opt.stage);
    if (missing.length)
    {
        writeln("error: required programs not on PATH:");
        foreach (m; missing)
            writefln("  %-12s %s", m[0], m[1]);
        return 1;
    }

    // ── build ───────────────────────────────────────────────────────────────
    //
    // In the split model this is a *fetch*, not a build: CI produced this exact
    // store path and pushed it to the binary cache, and the signing machine
    // substitutes it. Resolving the path first and reporting it is what makes
    // the two halves comparable by eye — CI prints the same string.
    writeln();
    auto evaluated = evalApkPath(opt.flakeRef, v.name, v.code);
    if (!evaluated.succeeded)
    {
        writeln("error: could not evaluate the APK derivation.");
        writeln(evaluated.stderr);
        return 1;
    }
    const expected = evaluated.stdout.lastLine;
    writefln("· APK store path%s", opt.requireCached ? " (must come from the cache)" : "");
    writefln("  %s", expected);

    const local = queryLocal(expected).succeeded;
    const cached = local || querySubstituter(opt.substituter, expected).succeeded;

    if (!cached && opt.requireCached)
    {
        writeln();
        writefln("error: %s is neither in the local store nor on %s.",
            expected, opt.substituter);
        writeln("  Building it here would take ~90 minutes and would defeat the point of");
        writeln("  the split: the artifact you sign should be the one CI built.");
        writeln();
        writeln("  Usual causes:");
        writeln("    * CI has not finished (or has not run) for this tag;");
        writeln("    * the working tree is dirty, or sits on a different commit than CI");
        writeln("      built — either changes the derivation, and so the store path;");
        writeln("    * --flake points somewhere other than what CI evaluated.");
        writeln();
        writeln("  Pass --no-require-cached to build locally anyway.");
        return 1;
    }
    writefln("  %s", local ? "already in the local store"
        : cached ? "substituting from " ~ opt.substituter
        : "not cached — building locally");

    auto built = buildApk(opt.flakeRef, v.name, v.code);
    if (!built.succeeded)
    {
        writeln(built.stderr);
        return 1;
    }
    const outPath = built.stdout.lastLine;
    if (outPath != expected)
    {
        // Should be impossible — the same expression produced both — but a
        // mismatch here means signing something other than what was reported.
        writefln("error: built %s but expected %s", outPath, expected);
        return 1;
    }
    const unsignedApk = buildPath(outPath, "hue-unsigned.apk");
    if (!unsignedApk.exists)
    {
        writefln("error: build produced no %s", unsignedApk);
        return 1;
    }
    writefln("  %s", unsignedApk);
    if (opt.stage == Stage.build)
        return 0;

    // ── work directory ──────────────────────────────────────────────────────
    // Assembled fresh, and NEVER the repository checkout: fdroidserver writes
    // repo/status/*.json containing the working directory's git state, down to
    // its modified and untracked file lists.
    const repoDir = buildPath(opt.workDir, "repo");
    mkdirRecurse(repoDir);
    mkdirRecurse(buildPath(opt.workDir, "archive"));

    // ── sign ────────────────────────────────────────────────────────────────
    writeln("· signing");
    const signedApk = buildPath(repoDir, apkName);
    auto signed = signApk(
        unsignedApk, signedApk,
        env.env.apkKeystore, env.env.apkKeyAlias,
        cast(string) EnvVar.apkStorePass, cast(string) EnvVar.apkKeyPass);
    if (!signed.succeeded)
    {
        writeln(signed.stderr);
        return 1;
    }

    auto certs = printCerts(signedApk);
    const fingerprints = signerFingerprints(certs.stdout);
    if (fingerprints.length != 1)
    {
        writefln("error: expected exactly one signer, found %s", fingerprints.length);
        return 1;
    }
    writefln("  signer SHA-256 %s", fingerprints[0]);

    // The manifest is generated from the bytes that will actually be served —
    // after signing, because signing changes them — rather than restated from
    // configuration (FDR8). It is what lets the copy in object storage be
    // matched against the one attached to the GitHub Release, and both against
    // the tag they claim to be.
    const manifest = ReleaseManifest(
        applicationId: applicationId,
        tag: opt.tag,
        versionName: v.name,
        versionCode: v.code,
        fileName: apkName,
        size: signedApk.getSize,
        sha256: sha256Of(signedApk),
        signerFingerprint: fingerprints[0],
        unsignedStorePath: outPath,
    );
    const manifestPath = buildPath(opt.workDir, "release-manifest.json");
    write(manifestPath, manifest.toJson);
    writefln("  sha256 %s", manifest.sha256);
    writefln("  manifest %s", manifestPath);

    if (opt.stage == Stage.sign)
        return 0;

    // ── pull ────────────────────────────────────────────────────────────────
    // The deploy below is an `rclone sync`, which deletes remote files absent
    // locally, and `fdroid update` hashes every APK it indexes. Both mean the
    // live repository has to be here before the index is regenerated.
    writeln("· pulling the published repository");

    // Prove the remote is reachable BEFORE deciding a section is empty. A first
    // publish legitimately has no fdroid/ yet, but an unreachable bucket looks
    // identical to `rclone copy` — and mistaking one for the other means
    // regenerating the index from nothing and then syncing that over
    // everything already published.
    auto bucketListing = listRemote(opt.rcloneRemote, env.env.bucket);
    if (!bucketListing.succeeded)
    {
        writefln("error: cannot list %s:%s — refusing to continue.",
            opt.rcloneRemote, env.env.bucket);
        writeln("  An unreachable remote is indistinguishable from an empty one, and");
        writeln("  the deploy step is an rclone sync: continuing could unpublish every");
        writeln("  existing version.");
        writeln(bucketListing.stderr);
        return 1;
    }

    auto sections = listRemote(opt.rcloneRemote, env.env.bucket ~ "/fdroid");
    foreach (section; ["repo", "archive"])
    {
        if (!sections.succeeded || !sections.stdout.listingHas(section))
        {
            writefln("  %s/ not published yet", section);
            continue;
        }
        auto pulled = pullSection(
            opt.rcloneRemote, env.env.bucket, section, buildPath(opt.workDir, section));
        if (!pulled.succeeded)
        {
            writeln(pulled.stderr);
            return 1;
        }
        writefln("  %s/ pulled", section);
    }
    if (opt.stage == Stage.pull)
        return 0;

    // ── version guard ───────────────────────────────────────────────────────
    const published = readPublished(opt.workDir);
    const refusal = checkPublishable(published, v.code);
    if (refusal != PublishRefusal.none)
    {
        writefln("error: versionCode %s: %s", v.code, describe(refusal));
        return 1;
    }

    // ── configuration ───────────────────────────────────────────────────────
    writeln("· assembling the working directory");
    copyTree(buildPath(opt.metadataDir, "config"), buildPath(opt.workDir, "config"));
    copyTree(buildPath(opt.metadataDir, "metadata"), buildPath(opt.workDir, "metadata"));

    write(
        buildPath(opt.workDir, "config.yml"),
        withRepoUrl(readText(buildPath(opt.metadataDir, "config.yml")), env.env.repoUrl));
    // fdroidserver warns when config.yml is group- or world-readable and any
    // passphrase key is set.
    setPrivate(buildPath(opt.workDir, "config.yml"));

    const appMetadata = buildPath(opt.workDir, "metadata", applicationId ~ ".yml");
    write(appMetadata, withCurrentVersion(readText(appMetadata), v.name, v.code));

    copyFile(env.env.indexKeystore, buildPath(opt.workDir, "keystore.p12"));
    setPrivate(buildPath(opt.workDir, "keystore.p12"));

    // The icons, from the same SVG the APK's mipmaps come from.
    //
    // `repo_icon: icon.png` resolves against the WORKING DIRECTORY, not
    // repo/icons/ — despite fdroidserver's warning naming the latter. A file
    // placed where the message says is silently replaced by a generated
    // placeholder.
    auto icon = buildIcon(opt.flakeRef);
    if (!icon.succeeded)
    {
        writeln(icon.stderr);
        return 1;
    }
    const icon512 = buildPath(icon.stdout.lastLine, "icon-512.png");
    copyFile(icon512, buildPath(opt.workDir, "icon.png"));
    // And the listing icon the client displays, which is independent of the
    // APK's mipmaps (those top out at 192 px).
    copyFile(icon512, buildPath(
        opt.workDir, "metadata", applicationId, "en-US", "images", "icon.png"));

    // ── index ───────────────────────────────────────────────────────────────
    writeln("· generating the index");
    auto updated = updateIndex(opt.workDir);
    if (!updated.succeeded)
    {
        writeln(updated.stderr);
        return 1;
    }

    // `fdroid update` exits 0 even when an AllowedAPKSigningKeys mismatch drops
    // every APK, leaving a valid signed index with no packages in it. The exit
    // code cannot answer this; the index has to.
    const indexed = readPublished(opt.workDir);
    if (!indexed.present)
    {
        writefln("error: %s is absent from the generated index.", applicationId);
        writeln("  fdroid update reports this as a warning and still exits 0 — the usual");
        writeln("  cause is an AllowedAPKSigningKeys mismatch. Signer was:");
        writefln("    %s", fingerprints[0]);
        return 1;
    }
    writefln("  indexed %s version(s), highest %s",
        indexed.versionCodes.length, indexed.highestVersionCode);
    if (opt.stage == Stage.index)
    {
        writeln();
        writefln("stopped before deploy. Pass --stage deploy to publish.");
        return 0;
    }

    // ── deploy ──────────────────────────────────────────────────────────────
    writeln("· deploying");
    auto pushed = deploy(opt.workDir);
    if (!pushed.succeeded)
    {
        writeln(pushed.stderr);
        return 1;
    }

    writeln();
    writefln("published %s %s (versionCode %s)", applicationId, v.name, v.code);
    writefln("  %s", env.env.repoUrl);
    return 0;
}

/// Reads the app's entry from whichever index sections exist in `workDir`.
private IndexedApp readPublished(string workDir)
{
    import std.file : exists, readText;
    import std.json : parseJSON;
    import std.path : buildPath;

    IndexedApp merged;
    foreach (section; ["repo", "archive"])
    {
        const path = buildPath(workDir, section, "index-v2.json");
        if (!path.exists)
            continue;
        const app = appFromIndex(parseJSON(readText(path)), applicationId);
        if (app.present)
        {
            merged.present = true;
            merged.versionCodes ~= app.versionCodes;
        }
    }
    return merged;
}

/// The last non-empty line of a command's output — `nix build
/// --print-out-paths` prints the store path there, after any log lines.
private string lastLine(string s) pure
{
    import std.string : lineSplitter, strip;

    string last;
    foreach (line; s.lineSplitter)
        if (line.strip.length)
            last = line.strip;
    return last;
}

/// Lowercase hex SHA-256 of a file, read in chunks — the APK is ~64 MB and
/// there is no reason to hold it in memory.
private string sha256Of(string path)
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : SHA256;
    import std.stdio : File;

    SHA256 hash;
    hash.start();
    // `byChunk`'s `front` is `@system` — it hands out a buffer it reuses. The
    // read loop is the only unsafe operation here, so it alone is trusted
    // rather than the whole function.
    () @trusted {
        foreach (ubyte[] chunk; File(path, "rb").byChunk(1 << 20))
            hash.put(chunk);
    }();
    return hash.finish().toHexString!(LetterCase.lower).idup;
}

/// True when `rclone lsf` output lists `name` as a directory. `lsf` prints one
/// entry per line, directories with a trailing slash.
private bool listingHas(string listing, string name) pure
{
    import std.string : lineSplitter, strip;

    foreach (line; listing.lineSplitter)
    {
        const entry = line.strip;
        if (entry == name || entry == name ~ "/")
            return true;
    }
    return false;
}

private void copyFile(string from, string to)
{
    import std.file : copy, mkdirRecurse;
    import std.path : dirName;

    mkdirRecurse(to.dirName);
    copy(from, to);
}

private void copyTree(string from, string to)
{
    import std.file : dirEntries, SpanMode, mkdirRecurse;
    import std.path : absolutePath, buildNormalizedPath, buildPath;

    // Slice the known prefix rather than `relativePath`: that returns its input
    // unchanged when it cannot relativize (which it could not here, silently
    // reproducing the whole source path inside the destination). `dirEntries`
    // always prefixes what it is given, so the prefix is exact.
    const root = from.absolutePath.buildNormalizedPath;

    mkdirRecurse(to);
    foreach (entry; dirEntries(root, SpanMode.breadth))
    {
        const target = buildPath(to, entry.name[root.length + 1 .. $]);
        if (entry.isDir)
            mkdirRecurse(target);
        else
            copyFile(entry.name, target);
    }
}

/// `chmod 600`. Used for the keystore and for config.yml, which fdroidserver
/// warns about when it is readable by anyone else and carries a passphrase key.
private void setPrivate(string path)
{
    version (Posix)
    {
        import std.file : setAttributes;
        import std.conv : octal;

        setAttributes(path, octal!600);
    }
}

@("fdroid.run.recognizesAnUnpublishedSection")
@safe unittest
{
    // `rclone lsf` marks directories with a trailing slash.
    enum listing = "repo/\narchive/\n";
    assert(listing.listingHas("repo"));
    assert(listing.listingHas("archive"));
    assert(!listing.listingHas("repository"));

    // A first publish: the bucket lists, but nothing is in it yet.
    assert(!"".listingHas("repo"));
    // A near-miss must not count as published, or the pull would be skipped
    // and the sync would delete the real one.
    assert(!"repo-backup/\n".listingHas("repo"));
}

@("fdroid.run.lastLinePicksTheStorePath")
@safe unittest
{
    // `nix build --print-build-logs --print-out-paths` interleaves logs with
    // the path, which lands last.
    assert(lastLine("hue> building\nhue> done\n/nix/store/abc-hue-unsigned-0.4.0\n")
        == "/nix/store/abc-hue-unsigned-0.4.0");
    assert(lastLine("/nix/store/x\n\n\n") == "/nix/store/x");
    assert(lastLine("") == "");
}
