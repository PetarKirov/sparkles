#!/usr/bin/env dub
/+ dub.sdl:
    name "pin_nix_wasm"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Pins the dub recipe module that Nix evaluation reads recipes through
(docs/specs/wired/wasm, D2 and W4).

```
dub run --single apps/ci/tools/pin-nix-wasm.d -- --rev REV [--push]
```

Builds `dub-manifest-nix-wasm` at `REV` from the flake nix/nix-wasm-pin.json
names, so `REV` must be on that flake's remote. It then commits the module
to the orphan branch `nix-wasm-modules` as `REV/spk-dub-manifest.wasm`, and
rewrites the pin with that commit's raw URL and the module's hash. Without
`--push`, the branch commit stays local, and the URL it writes resolves only
after the commit is pushed. `ci --check-nix-wasm` rebuilds the pinned
revision and requires the published bytes.

Move the pin, in the same pull request, whenever the agreement check fails
with the pinned module: for example, when a recipe uses a directive the
pinned schema rejects.
*/
module pin_nix_wasm;

import std.algorithm.searching : startsWith;
import std.file : copy, exists, mkdirRecurse, readText, tempDir, write;
import std.format : format;
import std.path : buildPath;
import std.process : Config, execute, thisProcessID;
import std.stdio : stderr, writeln;
import std.string : strip;

import sparkles.build_primitives.git_env : runGit;

enum branch = "nix-wasm-modules";

int main(string[] args)
{
    import std.getopt : getopt;

    string rev;
    bool push;
    getopt(args, "rev", &rev, "push", &push);
    if (!rev.length)
    {
        stderr.writeln("usage: pin-nix-wasm --rev REV [--push]");
        return 2;
    }

    const root = runGit(["rev-parse", "--show-toplevel"]).output.strip;
    const pinPath = root.buildPath("nix", "nix-wasm-pin.json");
    const flake = flakeOf(readText(pinPath));
    if (!flake.startsWith("github:"))
    {
        stderr.writeln("pin-nix-wasm: the pin's flake must be github:OWNER/REPO, not ", flake);
        return 1;
    }

    // The module, built at the revision.
    const built = execute(["nix", "build", "--no-link", "--print-out-paths",
        flake ~ "/" ~ rev ~ "#dub-manifest-nix-wasm"], null, Config.stderrPassThrough);
    if (built.status != 0)
        return fail("the revision did not build");
    const module_ = built.output.strip.buildPath("spk-dub-manifest.wasm");
    const hashed = execute(["nix", "hash", "file", "--sri", module_]);
    if (hashed.status != 0)
        return fail("cannot hash " ~ module_);

    // The orphan branch, in a scratch worktree.
    const work = tempDir.buildPath(format!"pin-nix-wasm-%s"(thisProcessID));
    const known = runGit(["fetch", "origin", branch], root).status == 0;
    if (runGit(known ? ["worktree", "add", "--detach", work, "FETCH_HEAD"]
            : ["worktree", "add", "--detach", work], root).status != 0)
        return fail("cannot create a worktree at " ~ work);
    scope (exit)
        runGit(["worktree", "remove", "--force", work], root);
    if (!known)
    {
        runGit(["checkout", "--orphan", branch], work);
        runGit(["rm", "-rfq", "."], work);
        write(work.buildPath("README.md"), "# nix-wasm-modules\n\n"
            ~ "The dub recipe modules Nix evaluation fetches by hash "
            ~ "(docs/specs/wired/wasm on the main branch, D2): `<rev>/spk-dub-manifest.wasm` "
            ~ "is `dub-manifest-nix-wasm` built at `<rev>`. Append only: a pin names a "
            ~ "commit of this branch, and rewriting it breaks that pin.\n");
        runGit(["add", "README.md"], work);
    }
    mkdirRecurse(work.buildPath(rev));
    copy(module_, work.buildPath(rev, "spk-dub-manifest.wasm"));
    runGit(["add", rev], work);
    // The branch holds modules and a README, and no hook configuration, which
    // the repository's pre-commit hook refuses to run without.
    if (runGit(["commit", "--no-verify", "-qm", "nix-wasm: the dub recipe module at " ~ rev], work).status != 0)
        return fail("cannot commit the module");
    const commit = runGit(["rev-parse", "HEAD"], work).output.strip;
    if (push && runGit(["push", "origin", "HEAD:refs/heads/" ~ branch], work).status != 0)
        return fail("cannot push " ~ branch);

    const repo = flake["github:".length .. $];
    write(pinPath, format!"{\n  \"flake\": \"%s\",\n  \"hash\": \"%s\",\n  \"rev\": \"%s\",\n  \"url\": \"%s\"\n}\n"(
        flake, hashed.output.strip, rev,
        format!"https://raw.githubusercontent.com/%s/%s/%s/spk-dub-manifest.wasm"(repo, commit, rev)));
    writeln("pinned ", rev, " (", hashed.output.strip, ") at ", branch, " ", commit,
        push ? "" : "; not pushed");
    return 0;
}

private string flakeOf(string json)
{
    import std.json : parseJSON;

    return parseJSON(json)["flake"].str;
}

private int fail(string why)
{
    stderr.writeln("pin-nix-wasm: ", why);
    return 1;
}
