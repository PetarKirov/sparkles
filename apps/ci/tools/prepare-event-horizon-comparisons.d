#!/usr/bin/env dub
/+ dub.sdl:
    name "prepare_event_horizon_comparisons"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
module prepare_event_horizon_comparisons;
import std.exception : enforce;
import std.file : exists, mkdirRecurse;
import std.path : absolutePath, buildPath, dirName;
import std.process : execute;
import std.stdio : writeln;
import std.string : strip, splitLines;

void checked(string[] command)
{
    auto result = execute(command);
    enforce(result.status == 0, result.output);
}

void prepare(string name, string url, string revision, string patchName, string[string] expectedFiles)
{
    // Never patch a user's registered checkout or global package cache.
    const root = absolutePath(".");
    enforce(buildPath(root, "libs/event-horizon/dub.sdl").exists,
        "run from the Sparkles repository root");
    const patch = buildPath(root, "apps/ci/tools", patchName);
    const target = buildPath(root, "docs/libs/event-horizon/tutorial/snippets/.deps", name);
    if (!target.exists)
    {
        mkdirRecurse(target.dirName);
        checked(["git", "clone", "--no-checkout", url, target]);
        checked(["git", "-C", target, "checkout", "--detach", revision]);
    }
    auto head = execute(["git", "-C", target, "rev-parse", "HEAD"]);
    enforce(head.status == 0 && head.output.strip == revision,
        "existing comparison dependency is not the pinned revision; left untouched");
    auto reverse = execute(["git", "-C", target, "apply", "--reverse", "--check", patch]);
    if (reverse.status != 0)
    {
        auto status = execute(["git", "-C", target, "status", "--porcelain"]);
        enforce(status.status == 0 && status.output.strip.length == 0,
            "existing comparison dependency has unexpected edits; left untouched");
        checked(["git", "-C", target, "apply", "--check", patch]);
        checked(["git", "-C", target, "apply", patch]);
    }
    auto dirty = execute(["git", "-C", target, "status", "--porcelain", "--untracked-files=all"]);
    enforce(dirty.status == 0, dirty.output);
    foreach (line; dirty.output.splitLines)
        enforce(line.length > 3 && line[0 .. 3] == " M " && (line[3 .. $] in expectedFiles) !is null,
            "unexpected dependency edit: " ~ line);
    foreach (file, expectedHash; expectedFiles)
    {
        auto hash = execute(["git", "-C", target, "hash-object", file]);
        enforce(hash.status == 0 && hash.output.strip == expectedHash,
            "dependency differs from reviewed patch: " ~ file);
    }
    writeln("Prepared ", name, " ", revision, " with the documented compatibility patch.");
}

void main()
{
    prepare("hunt", "https://github.com/huntlabs/hunt.git",
        "5264f181088fb04cea5702ccdeab0fd5e1c8486d", "hunt-1.7.17-runtime.patch", [
            "source/hunt/io/channel/AbstractChannel.d": "6f9a358e2cca97e170c9c1edf04bd24dce19356b"]);
    prepare("collie", "https://github.com/huntlabs/collie.git",
        "f1e58e38a2c36366766e4778d3ea655ebac6962c", "collie-0.10.16-compiler.patch", [
            "source/collie/bootstrap/client.d": "fc98ab9c638d3737c799155fbf2c8b6b959b56e1",
            "source/collie/channel/pipeline.d": "fb60d0f0a5330268681ff266652bae0e439e0da5"]);
    prepare("kiss", "https://github.com/huntlabs/kiss.git",
        "6d07c263c2b9bdec493996b7f4cedb95b5812271", "kiss-0.4.9-runtime.patch", [
            "source/kiss/event/core.d": "ad73e5a0a67eaf5f8eeda56b932ed5045ed6fea9",
            "source/kiss/event/selector/epoll.d": "c03ecf14f49d4beb5f017c2d65fa8d3dbab45a99",
            "source/kiss/event/timer/epoll.d": "2933a93964bba1638acc742021aed160366a2b71"]);
}
