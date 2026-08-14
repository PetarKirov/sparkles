/**
The `fdroid-publish` command line.

Two subcommands. `publish` is the pipeline; `version` answers the one question
worth asking on its own — what a tag maps to — without touching anything, which
is what makes the mapping easy to check from CI or by hand.
*/
module sparkles.fdroid.app;

import sparkles.core_cli.args;
import sparkles.fdroid.run : RunOptions, runPublish;
import sparkles.fdroid.stage : defaultStage, Stage, stageNames, tryParseStage;
import sparkles.fdroid.version_map : apkVersionForTag, describe;

import std.stdio : writefln, writeln;
import std.sumtype;

@(Command("version",
    shortDescription: "Show the APK version a release tag maps to",
    helpSections: ["description"],
))
struct VersionCmd
{
    @(Option(`t|tag`, description: "Release tag, with or without the leading v"))
    string tag;

    int run()
    {
        if (!tag.length)
        {
            writeln("error: --tag is required");
            return 2;
        }

        const mapped = apkVersionForTag(tag);
        if (!mapped.ok)
        {
            writefln("error: %s: %s", tag, describe(mapped.error));
            return 1;
        }

        writefln("versionName %s", mapped.version_.name);
        writefln("versionCode %s", mapped.version_.code);
        return 0;
    }
}

@(Command("publish",
    shortDescription: "Build, sign, index and deploy the release APK",
    helpSections: ["description"],
))
struct PublishCmd
{
    @(Option(`t|tag`, description: "Release tag, with or without the leading v"))
    string tag;

    @(Option(`s|stage`,
        description: "How far to go; cumulative. One of: build, sign, pull, index, deploy"))
    string stage = "index";

    @(Option(`n|dry-run`, description: "Report what would happen and stop"))
    bool dryRun;

    @(Option(`w|workdir`, description: "Scratch directory; must not be the repository checkout"))
    string workdir;

    @(Option(`m|metadata-dir`, description: "Committed F-Droid configuration"))
    string metadataDir = "apps/hue/fdroid";

    @(Option(`f|flake`, description: "Flake reference to build the APK from"))
    string flake = ".";

    @(Option(`r|rclone-remote`, description: "rclone remote name, as named in config.yml"))
    string rcloneRemote = "sparkles";

    int run()
    {
        import std.file : exists, isDir, tempDir;
        import std.path : absolutePath, buildPath;
        import std.process : thisProcessID;
        import std.conv : text;

        if (!tag.length)
        {
            writeln("error: --tag is required");
            return 2;
        }

        Stage parsed;
        if (!tryParseStage(stage, parsed))
        {
            writefln("error: unknown --stage %s (expected one of: %s)", stage, stageNames);
            return 2;
        }

        auto dir = workdir.length
            ? workdir
            : buildPath(tempDir, text("fdroid-publish-", thisProcessID));

        // fdroidserver publishes the working directory's git state in
        // repo/status/*.json — including untracked and modified files — so
        // running it inside a checkout leaks it.
        if (buildPath(dir.absolutePath, ".git").exists)
        {
            writefln("error: %s is a git checkout.", dir);
            writeln("  fdroid update records the working directory's git state — commit id,");
            writeln("  dirty flag, and the modified and untracked file lists — in");
            writeln("  repo/status/*.json, which is published. Use a scratch directory.");
            return 2;
        }

        return runPublish(RunOptions(
            tag: tag,
            stage: parsed,
            dryRun: dryRun,
            workDir: dir,
            metadataDir: metadataDir,
            flakeRef: flake.absolutePath,
            rcloneRemote: rcloneRemote,
        ));
    }
}

@(Command("fdroid-publish",
    shortDescription: "Publish hue to the self-hosted sparkles F-Droid repository",
    helpSections: ["description", "examples"],
))
struct FdroidPublish
{
    @Subcommands
    SumType!(PublishCmd, VersionCmd) command;
}
