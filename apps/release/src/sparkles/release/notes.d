/++
Release-notes acquisition: the `$EDITOR` path and the comment-stripping that
gives it `git commit`-style semantics.

`seedEditorBuffer` builds the commented template (suggested subject plus a
`#`-prefixed `git log --stat` for guidance); `openInEditor` launches the editor
on a temp file and returns the raw edited text; `stripComments` drops the `#`
lines and trims — an empty result signals "abort", exactly like aborting a
commit message.
+/
module sparkles.release.notes;

import sparkles.release.result : Result, success, failure;

@safe:

/// Drops `#`-leading lines and trims surrounding blank lines. An empty return
/// means the user aborted (wrote nothing but comments).
string stripComments(string edited) @safe pure
{
    import std.array : appender;
    import std.string : lineSplitter, strip;

    auto app = appender!string;
    bool first = true;
    foreach (line; edited.lineSplitter)
    {
        if (line.length && line[0] == '#')
            continue;
        if (!first)
            app.put('\n');
        app.put(line);
        first = false;
    }
    return app[].strip;
}

/// Builds the manual-mode editor buffer: the suggested subject line, then a
/// `#`-commented instruction block and `git log --stat` for reference.
string seedEditorBuffer(string suggestedSubject, string logStat) @safe pure
{
    import std.array : appender;
    import std.string : lineSplitter;

    auto app = appender!string;
    app.put(suggestedSubject);
    app.put("\n\n");
    app.put("# Lines starting with '#' are ignored. An empty message aborts the release.\n");
    app.put("# Write the annotated-tag body above; the first line is the subject.\n");
    app.put("#\n");
    foreach (line; logStat.lineSplitter)
    {
        app.put("# ");
        app.put(line);
        app.put('\n');
    }
    return app[];
}

/// Builds the agent-review editor buffer: the agent's notes followed by a
/// `#`-commented reminder.
string seedReviewBuffer(string agentNotes) @safe pure
{
    import std.array : appender;
    import std.algorithm.searching : endsWith;

    auto app = appender!string;
    app.put(agentNotes);
    if (!agentNotes.endsWith("\n"))
        app.put('\n');
    app.put("\n# Review the agent-generated notes above. '#' lines are ignored;\n");
    app.put("# an empty message aborts the release.\n");
    return app[];
}

/// `$VISUAL`, else `$EDITOR`, else `vi`.
string chooseEditor()
{
    import std.process : environment;

    const v = environment.get("VISUAL", "");
    if (v.length)
        return v;
    const e = environment.get("EDITOR", "");
    if (e.length)
        return e;
    return "vi";
}

/// Opens the user's editor on a temp file seeded with `seed`, returning the raw
/// edited contents (the caller runs $(LREF stripComments)).
Result!string openInEditor(string seed)
{
    import std.conv : text;
    import std.file : tempDir, write, readText, remove;
    import std.path : buildPath;
    import std.process : spawnProcess, wait, thisProcessID;
    import std.string : split;

    const path = buildPath(tempDir, text("sparkles-release-", thisProcessID, ".txt"));
    const editorArgs = chooseEditor().split(' ');

    try
    {
        write(path, seed);
        // Inherit the parent's stdio so a full-screen editor owns the terminal.
        auto pid = spawnProcess(editorArgs ~ path);
        const status = wait(pid);
        if (status != 0)
        {
            try
                remove(path);
            catch (Exception)
            {
            }
            return failure!string(
                "editor exited with status " ~ status.text);
        }
        auto edited = readText(path);
        try
            remove(path);
        catch (Exception)
        {
        }
        return success(edited);
    }
    catch (Exception e)
        return failure!string("could not open editor: " ~ e.msg);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("notes.stripComments.dropsHashLinesAndTrims")
@safe pure unittest
{
    const edited =
        "v0.5.0 — theme\n" ~
        "\n" ~
        "Some notes.\n" ~
        "# a comment\n" ~
        "More notes.\n" ~
        "# trailing comment\n";
    assert(stripComments(edited) ==
        "v0.5.0 — theme\n\nSome notes.\nMore notes.");
}

@("notes.stripComments.emptyMeansAbort")
@safe pure unittest
{
    assert(stripComments("# only\n# comments\n").length == 0);
    assert(stripComments("   \n\n").length == 0);
    // A '#' not at line start is kept.
    assert(stripComments("issue #42 fixed").length != 0);
}

@("notes.seedEditorBuffer.hasSubjectAndComments")
@safe pure unittest
{
    import std.algorithm.searching : canFind, startsWith;

    const seed = seedEditorBuffer("v0.5.0 — ", "3 files changed");
    assert(seed.startsWith("v0.5.0 — \n\n"));
    assert(seed.canFind("# 3 files changed"));
    // Stripping the seed back down yields just the subject line.
    assert(stripComments(seed) == "v0.5.0 —");
}
