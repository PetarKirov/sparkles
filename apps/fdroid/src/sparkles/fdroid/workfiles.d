/**
The two text edits the publisher makes to its working copy of the committed
F-Droid configuration.

Both are deliberately line-oriented rewrites of a file the repository owns,
rather than a YAML round-trip: emitting YAML would reformat the comments that
carry most of `apps/hue/fdroid/config.yml`'s value, and the surface being
changed is two keys.

Kept pure and separate from the filesystem so the transformations are tested on
strings.
*/
module sparkles.fdroid.workfiles;

@safe:

/**
Appends the `repo_url` that `apps/hue/fdroid/config.yml` deliberately omits.

It cannot be a `{env: …}` reference: `fdroidserver.common.read_config`
validates it eagerly with `config['repo_url'].endswith('/repo')` while the value
is still a dict, which fails as a bare `AttributeError`. `archive_url` needs no
entry — fdroidserver derives it as `repo_url[:-4] + 'archive'`.
*/
string withRepoUrl(string configYaml, string repoUrl) pure
{
    import std.algorithm : endsWith;

    assert(repoUrl.endsWith("/repo"),
        "repo_url must end in /repo — fdroidserver raises otherwise");

    const separator = configYaml.length && configYaml[$ - 1] == '\n' ? "" : "\n";
    return configYaml ~ separator
        ~ "\n# Appended by fdroid-publish; see sparkles.fdroid.workfiles.\n"
        ~ "repo_url: " ~ repoUrl ~ "\n";
}

/**
Rewrites `CurrentVersion` and `CurrentVersionCode` in an app's metadata.

`fdroid update` reads both: the code selects which build the client suggests,
and keys the fastlane changelog (`changelogs/<code>.txt`). Every other line —
including the commented-out `AllowedAPKSigningKeys` block — is preserved byte
for byte.
*/
string withCurrentVersion(string metadataYaml, string versionName, uint versionCode) pure
{
    import std.array : appender;
    import std.conv : text;
    import std.string : lineSplitter, startsWith;

    auto out_ = appender!string;
    bool sawName, sawCode;

    foreach (line; metadataYaml.lineSplitter)
    {
        if (line.startsWith("CurrentVersionCode:"))
        {
            out_ ~= text("CurrentVersionCode: ", versionCode);
            sawCode = true;
        }
        else if (line.startsWith("CurrentVersion:"))
        {
            out_ ~= "CurrentVersion: " ~ versionName;
            sawName = true;
        }
        else
            out_ ~= line;
        out_ ~= "\n";
    }

    // A metadata file that never declared them is still valid; append rather
    // than silently publishing without a suggested version.
    if (!sawName)
        out_ ~= "CurrentVersion: " ~ versionName ~ "\n";
    if (!sawCode)
        out_ ~= text("CurrentVersionCode: ", versionCode, "\n");

    return out_[];
}

@("fdroid.workfiles.appendsRepoUrl")
@safe unittest
{
    import std.algorithm : endsWith, startsWith;
    import std.string : indexOf;

    const result = withRepoUrl("repo_name: sparkles\n", "https://example.org/fdroid/repo");
    assert(result.startsWith("repo_name: sparkles\n"));
    assert(result.endsWith("repo_url: https://example.org/fdroid/repo\n"));

    // A file not ending in a newline must not have its last key swallowed.
    const noTrailing = withRepoUrl("repo_name: sparkles", "https://example.org/fdroid/repo");
    assert(noTrailing.indexOf("sparklesrepo_url") < 0);
    assert(noTrailing.indexOf("\nrepo_url: ") > 0);
}

@("fdroid.workfiles.rewritesCurrentVersionInPlace")
@safe unittest
{
    import std.string : indexOf;

    enum before = "Categories:\n  - Development\n"
        ~ "License: BSL-1.0\n"
        ~ "# AllowedAPKSigningKeys:\n#   - \"00\"\n"
        ~ "CurrentVersion: 0.0.0\n"
        ~ "CurrentVersionCode: 0\n";

    const after = withCurrentVersion(before, "0.4.0", 1024);

    assert(after.indexOf("CurrentVersion: 0.4.0\n") >= 0);
    assert(after.indexOf("CurrentVersionCode: 1024\n") >= 0);
    // The old values are gone…
    assert(after.indexOf("CurrentVersion: 0.0.0") < 0);
    assert(after.indexOf("CurrentVersionCode: 0\n") < 0);
    // …and nothing else moved, comments included.
    assert(after.indexOf("License: BSL-1.0\n") >= 0);
    assert(after.indexOf("# AllowedAPKSigningKeys:\n") >= 0);
    assert(after.indexOf("  - Development\n") >= 0);
}

@("fdroid.workfiles.currentVersionCodePrefixIsNotAmbiguous")
@safe unittest
{
    import std.string : indexOf;

    // `CurrentVersion:` is a prefix of nothing else, but `CurrentVersionCode:`
    // starts with `CurrentVersion` — the code branch must be tested first or
    // the code line gets rewritten as the name.
    const after = withCurrentVersion("CurrentVersionCode: 7\nCurrentVersion: 9.9.9\n", "0.4.0", 1024);
    assert(after.indexOf("CurrentVersionCode: 1024\n") >= 0);
    assert(after.indexOf("CurrentVersion: 0.4.0\n") >= 0);
    assert(after.indexOf("CurrentVersionCode: 0.4.0") < 0);
}

@("fdroid.workfiles.appendsWhenAbsent")
@safe unittest
{
    import std.string : indexOf;

    const after = withCurrentVersion("License: BSL-1.0\n", "0.4.0", 1024);
    assert(after.indexOf("License: BSL-1.0\n") >= 0);
    assert(after.indexOf("CurrentVersion: 0.4.0\n") >= 0);
    assert(after.indexOf("CurrentVersionCode: 1024\n") >= 0);
}
