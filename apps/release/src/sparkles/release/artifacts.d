/++
Best-effort persistence of split-run artifacts under `.result/` (SPEC §9).

Each `--split` run gets `.result/release-split/<yyyymmdd-HHMMSS>/` at the
repository root, collecting the segmentation prompt, the raw agent replies,
the validated plan, and the per-tag notes prompts/bodies — so a run can be
reviewed later. Reviewing is never a blocker: every failure here degrades to a
logged warning, and a sink whose directory could not be created silently drops
writes.
+/
module sparkles.release.artifacts;

import sparkles.base.logger : warning;

@safe:

/// One run's artifact directory. `dir.length == 0` means "disabled": every
/// $(LREF ArtifactSink.save) becomes a no-op.
struct ArtifactSink
{
    string dir;

    /// Writes `content` to `<dir>/<name>`, logging (not raising) any failure.
    void save(string name, const(char)[] content) const
    {
        import std.file : write;
        import std.path : buildPath;

        if (dir.length == 0)
            return;
        try
            write(buildPath(dir, name), content);
        catch (Exception e)
            warning(i"Could not save artifact $(name): $(e.msg)");
    }
}

/// Creates `.result/release-split/<timestamp>/` under `repoRoot` and returns
/// its sink; a disabled sink (with a logged warning) when creation fails.
ArtifactSink makeArtifactSink(string repoRoot)
{
    import std.datetime.systime : Clock;
    import std.file : mkdirRecurse;
    import std.format : format;
    import std.path : buildPath;

    try
    {
        const now = Clock.currTime;
        const stamp = format!"%04d%02d%02d-%02d%02d%02d"(
            now.year, cast(int) now.month, now.day,
            now.hour, now.minute, now.second);
        const dir = buildPath(repoRoot, ".result", "release-split", stamp);
        mkdirRecurse(dir);
        return ArtifactSink(dir);
    }
    catch (Exception e)
    {
        warning(i"Could not create the artifact directory: $(e.msg)");
        return ArtifactSink(null);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("artifacts.sink.savesAndSurvivesFailure")
@safe unittest
{
    import std.conv : text;
    import std.file : exists, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    const root = buildPath(tempDir, text("sparkles-artifacts-", thisProcessID));
    scope (exit)
        if (root.exists)
            rmdirRecurse(root);

    const sink = makeArtifactSink(root);
    assert(sink.dir.length);
    sink.save("plan.json", `{"segments": []}`);
    assert(readText(buildPath(sink.dir, "plan.json")) == `{"segments": []}`);

    // A bad name degrades to a warning, not an exception.
    sink.save("no/such/dir.txt", "x");
}

@("artifacts.sink.disabledIsNoOp")
@safe unittest
{
    const sink = ArtifactSink(null);
    sink.save("anything.txt", "dropped");     // must not throw
}
