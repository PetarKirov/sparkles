/++
`--build-each-commit`: build the chosen sub-packages at every commit of a range.

CI builds a pull request's $(I tip). A stacked series is merged by rebase, so
every commit in it lands on `main` and becomes a `git bisect` stop, and the
repository asks each one to build on its own ([Git hygiene](../../docs/guidelines/AGENTS.md#git-hygiene--atomic-commits)).
Nothing checked that. The gap is widest for the apps whose default configuration
is a GUI build: `dub test` compiles their `unittest` configuration and never the
one a user runs (`hue`'s `gui`, the gallery's and the diagram board's `full`).
Before this mode, that loop was run by hand before every push.

The loop is a scratch worktree, detached, walked from the oldest commit to the
newest. It is one worktree, not one per commit, so each build is incremental
on the last. Uncommitted changes are not part of any commit and are not built.

This module is the planning half: what the range is, which packages. The
execution lives with the other dub modes in `app.d`.
+/
module each_commit;

import std.algorithm : canFind;
import std.path : baseName;
import std.string : indexOf, lineSplitter, strip;

/++
The packages built when `--packages` names none: the ones whose default
configuration `dub test` never compiles, which is exactly where a commit that
passes its tests can still fail to build.
+/
immutable string[] defaultEachCommitPackages = ["hue", "ui-gallery", "diagram"];

/// One commit of the range.
struct RangeCommit
{
    string sha;     /// abbreviated
    string subject; /// the first line of its message
}

/++
The commits `git log --reverse --format='%h %s' <base>..HEAD` printed, oldest
first, the order a bisect-minded reader walks them in.
+/
RangeCommit[] parseCommitRange(scope const(char)[] logOutput) @safe pure
{
    RangeCommit[] commits;
    foreach (line; logOutput.lineSplitter)
    {
        const l = line.strip;
        if (l.length == 0)
            continue;
        const sp = l.indexOf(' ');
        commits ~= sp < 0
            ? RangeCommit(l.idup, "")
            : RangeCommit(l[0 .. sp].idup, l[sp + 1 .. $].idup);
    }
    return commits;
}

@("each_commit.parseCommitRange.oldestFirstWithSubjects")
@safe pure
unittest
{
    const r = parseCommitRange("d0d91e6 fix(ui): cut text (LAY14)\n7bf3f4b feat(ui.dock): toolbars\n\n");
    assert(r.length == 2);
    assert(r[0] == RangeCommit("d0d91e6", "fix(ui): cut text (LAY14)"));
    assert(r[1].sha == "7bf3f4b" && r[1].subject == "feat(ui.dock): toolbars");
    assert(parseCommitRange("").length == 0, "an empty range is no commits");
}

/++
Maps package names to the sub-package paths the root recipe declares
(`apps/hue`, `libs/ui`). A name that matches none is returned in `unknown`,
so a typo fails before any worktree is created rather than after an hour of
builds that never included the package it meant.
+/
string[] selectPackages(in string[] requested, in string[] subPackagePaths,
    out string[] unknown) @safe pure
{
    string[] chosen;
    foreach (name; requested)
    {
        bool found;
        foreach (path; subPackagePaths)
            if (path.baseName == name)
            {
                if (!chosen.canFind(path))
                    chosen ~= path;
                found = true;
                break;
            }
        if (!found)
            unknown ~= name;
    }
    return chosen;
}

@("each_commit.selectPackages.namesResolveToPathsAndTyposAreKept")
@safe pure
unittest
{
    const paths = ["apps/hue", "apps/ui-gallery", "libs/ui", "apps/diagram"];
    string[] unknown;
    const chosen = selectPackages(["ui", "hue", "hue", "gallery"], paths, unknown);
    assert(chosen == ["libs/ui", "apps/hue"], "in request order, once each");
    assert(unknown == ["gallery"], "a name no package has is reported");

    selectPackages(defaultEachCommitPackages, paths, unknown);
    assert(unknown.length == 0, "the defaults are real packages");
}

/// One package that did not build at one commit.
struct CommitFailure
{
    RangeCommit commit;
    string pkg;
}

/// The closing report, one line per failure, oldest commit first.
string failureReport(in CommitFailure[] failures, size_t commits,
    size_t packages) @safe pure
{
    import std.conv : text;

    if (failures.length == 0)
        return text("every commit builds: ", commits, " commit(s) × ",
            packages, " package(s)");
    string s = text(failures.length, " build(s) failed across ", commits,
        " commit(s):");
    foreach (f; failures)
        s ~= text("\n  ", f.commit.sha, "  :", f.pkg, "  ", f.commit.subject);
    return s;
}

@("each_commit.failureReport.namesTheCommitAndThePackage")
@safe pure
unittest
{
    assert(failureReport(null, 3, 2) == "every commit builds: 3 commit(s) × 2 package(s)");
    const f = [CommitFailure(RangeCommit("7bf3f4b", "feat: x"), "hue")];
    assert(failureReport(f, 3, 2)
        == "1 build(s) failed across 3 commit(s):\n  7bf3f4b  :hue  feat: x");
}
