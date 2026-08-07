/**
`DST2`/`DST4`: handing a synthesized patch to git.

`sparkles:diff` builds the patch (`sparkles.diff.stage`); this applies it.
There is no in-process index bookkeeping anywhere in hue — the lazygit
recipe — because git's index is the truth and a second model of it would only
be a thing to get out of sync.

Every apply is preceded by `--check`, which is the whole reason this is safe
to offer: a patch that would not apply is REPORTED, not half-applied. git's
`apply` is atomic per invocation, so the pair (check, apply) never leaves a
partially staged selection behind.
*/
module staging;

import expected : err, Expected;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.diff : DiffDoc, emitSelectionPatch, FileEntry;

/// What a staging operation can report. Text for the human; the operation is
/// either done or it is not.
struct StageError
{
    string detail;

    string toString() const @safe pure => detail;
}

/// ditto
alias StageResult = Expected!(bool, StageError);

/// Which direction a patch is applied in.
enum StageAction : ubyte
{
    /// Add the selection to the index (`git apply --cached`).
    stage,
    /// Take it back out (`--cached --reverse`).
    unstage,
    /// `DST4`: undo it in the WORKING TREE. Destructive — the caller is
    /// responsible for having asked first.
    discard,
}

/// The patch for a selection, or empty when nothing was selected.
string selectionPatch(in DiffDoc doc, scope const(bool)[] selected) @safe
{
    SmallBuffer!char buf;
    foreach (fi; 0 .. doc.files.length)
        emitSelectionPatch(doc, doc.files[fi], selected, buf);
    return buf[].idup;
}

/**
Applies `patch` to the repository at `workDir`.

`--unidiff-zero` because the patch carries no context (see
`sparkles.diff.stage` for why it must not). `--check` first, always: the
answer to "would this apply?" is worth having before the answer to "did it?",
and a reviewer who is told a selection cannot be staged can go look at why.

Returns `false` (not an error) for an empty patch — nothing selected is not a
failure, and making the caller distinguish would push a branch into every
call site.
*/
StageResult applyPatch(string patch, StageAction action, string workDir = null)
    @safe
{
    import std.process : execute;
    import std.string : strip;

    if (patch.length == 0)
        return StageResult(false);

    string[] base = ["git", "apply", "--unidiff-zero"];
    final switch (action) with (StageAction)
    {
        case stage:
            base ~= "--cached";
            break;
        case unstage:
            base ~= ["--cached", "--reverse"];
            break;
        case discard:
            // The working tree, in reverse: this is `DST4`, and it destroys
            // work. Nothing here asks for confirmation — that belongs to the
            // caller, where the user is.
            base ~= "--reverse";
            break;
    }

    const checked = run(base ~ "--check", patch, workDir);
    if (checked.status != 0)
        return err!bool(StageError("the selection does not apply: "
            ~ checked.output.strip));

    const applied = run(base, patch, workDir);
    if (applied.status != 0)
        return err!bool(StageError("git apply failed: "
            ~ applied.output.strip));
    return StageResult(true);
}

private auto run(string[] argv, string input, string workDir) @safe
{
    import std.process : Config, pipeProcess, Redirect, wait;
    import std.stdio : File;

    struct Result
    {
        int status;
        string output;
    }

    auto pipes = pipeProcess(argv, Redirect.stdin | Redirect.stdout
        | Redirect.stderrToStdout, null, Config.none, workDir);
    pipes.stdin.rawWrite(input);
    pipes.stdin.close();

    string out_;
    foreach (line; pipes.stdout.byLine)
        out_ ~= line.idup ~ "\n";
    return Result(wait(pipes.pid), out_);
}

// ── Tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : Config, execute;

    /// A throwaway repository with one committed file, for the tests below.
    private string makeRepo(string name, string content) @safe
    {
        const dir = buildPath(tempDir(), name);
        try
            rmdirRecurse(dir);
        catch (Exception) {}
        mkdirRecurse(dir);
        foreach (argv; [["git", "init", "-q"],
                ["git", "config", "user.email", "t@example.com"],
                ["git", "config", "user.name", "t"]])
            execute(argv, null, Config.none, size_t.max, dir);
        write(buildPath(dir, "f.txt"), content);
        execute(["git", "add", "f.txt"], null, Config.none,
            size_t.max, dir);
        execute(["git", "commit", "-qm", "base"], null,
            Config.none, size_t.max, dir);
        return dir;
    }

    private string staged(string dir) @safe
    {
        const r = execute(["git", "diff", "--cached"], null,
            Config.none, size_t.max, dir);
        return r.output;
    }
}

@("staging.applyPatch.stagesOnlyTheSelectedLines")
@safe unittest
{
    import sparkles.diff : diffText, RowKind, selectHunk;
    import std.algorithm.searching : canFind;

    // The claim this whole wave rests on: git accepts the patch we synthesize.
    // Nothing but a real `git apply` can establish that, so the test runs one.
    enum before = "one\ntwo\nthree\n";
    enum after = "ONE\ntwo\nTHREE\n";
    const dir = makeRepo("hue-staging-lines", before);
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "f.txt"), after);

    auto doc = diffText(before, after, "f.txt", "f.txt");
    auto sel = new bool[](doc.rows.length);
    foreach (i; 0 .. doc.rows.length)
    {
        const row = doc.rows[i];
        const t = doc.rowText(row);
        if (row.kind != RowKind.context && (t == "one" || t == "ONE"))
            sel[i] = true;
    }

    auto res = applyPatch(selectionPatch(doc, sel), StageAction.stage, dir);
    assert(!res.hasError, res.hasError ? res.error.detail : "");
    assert(res.value, "something was staged");

    // Line-granular: the first edit is in the index, the third is not.
    const idx = staged(dir);
    assert(idx.canFind("+ONE"), "the selected line");
    assert(!idx.canFind("+THREE"), "the line the reviewer left alone");

    // And unstaging is the same patch, reversed.
    auto back = applyPatch(selectionPatch(doc, sel), StageAction.unstage, dir);
    assert(!back.hasError && back.value);
    assert(staged(dir).length == 0, "the index is back where it started");
}

@("staging.applyPatch.checksBeforeItApplies")
@safe unittest
{
    import sparkles.diff : diffText, selectHunk;

    // A patch against content the index does not have. `--check` must catch
    // it and report, rather than leaving a half-applied selection behind.
    const dir = makeRepo("hue-staging-check", "actual\n");
    scope (exit) rmdirRecurse(dir);

    auto doc = diffText("something else\n", "changed\n", "f.txt", "f.txt");
    auto sel = new bool[](doc.rows.length);
    selectHunk(doc, doc.hunks[0].id, sel);

    auto res = applyPatch(selectionPatch(doc, sel), StageAction.stage, dir);
    assert(res.hasError, "a patch that cannot apply must be refused");
    assert(staged(dir).length == 0, "and must have changed nothing");
}

@("staging.applyPatch.emptySelectionIsNotAFailure")
@safe unittest
{
    import sparkles.diff : diffText;

    auto doc = diffText("a\n", "b\n", "f.txt", "f.txt");
    auto none = new bool[](doc.rows.length);
    auto res = applyPatch(selectionPatch(doc, none), StageAction.stage, null);
    assert(!res.hasError && !res.value,
        "nothing selected is nothing done, not an error to report");
}

@("staging.applyPatch.discardRevertsTheWorkingTree")
@safe unittest
{
    import sparkles.diff : diffText, selectHunk;
    import std.file : readText;

    // `DST4`: destructive, and the reason the caller must confirm first.
    enum before = "keep\n";
    enum after = "clobbered\n";
    const dir = makeRepo("hue-staging-discard", before);
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "f.txt"), after);

    auto doc = diffText(before, after, "f.txt", "f.txt");
    auto sel = new bool[](doc.rows.length);
    selectHunk(doc, doc.hunks[0].id, sel);

    auto res = applyPatch(selectionPatch(doc, sel), StageAction.discard, dir);
    assert(!res.hasError, res.hasError ? res.error.detail : "");
    assert(readText(buildPath(dir, "f.txt")) == before,
        "the working tree is back to the committed content");
    assert(staged(dir).length == 0, "and the index was never touched");
}

@("staging.applyPatch.insertionsAndDeletionsLandWhereTheyBelong")
@safe unittest
{
    import sparkles.diff : diffText, selectHunk;
    import std.file : readText;

    // git spells the three hunk shapes differently and `--unidiff-zero` still
    // LOCATES by those numbers, so a replacement applying proves nothing
    // about an insertion or a deletion. Both, against real git.
    enum before = "a\nb\nc\n";
    enum after = "a\nINSERTED\nb\n"; // c deleted, INSERTED added
    const dir = makeRepo("hue-staging-shapes", before);
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "f.txt"), after);

    auto doc = diffText(before, after, "f.txt", "f.txt");
    auto sel = new bool[](doc.rows.length);
    foreach (hi; 0 .. doc.hunks.length)
        selectHunk(doc, doc.hunks[hi].id, sel);

    auto res = applyPatch(selectionPatch(doc, sel), StageAction.stage, dir);
    assert(!res.hasError, res.hasError ? res.error.detail : "");

    // Staging everything must reproduce the working tree exactly in the
    // index — the strongest available statement that the line numbers are
    // right, since a wrong one would place text somewhere else.
    const r = execute(["git", "show", ":f.txt"], null, Config.none,
        size_t.max, dir);
    assert(r.status == 0);
    assert(r.output == after, "the index must match the file byte for byte");
}

@("staging.applyPatch.aPureInsertionAtTheTopOfAFile")
@safe unittest
{
    import sparkles.diff : diffText, selectHunk;

    // The edge the walk-back has to get right: an addition with no old line
    // before it anywhere.
    enum before = "body\n";
    enum after = "header\nbody\n";
    const dir = makeRepo("hue-staging-top", before);
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "f.txt"), after);

    auto doc = diffText(before, after, "f.txt", "f.txt");
    auto sel = new bool[](doc.rows.length);
    selectHunk(doc, doc.hunks[0].id, sel);

    auto res = applyPatch(selectionPatch(doc, sel), StageAction.stage, dir);
    assert(!res.hasError, res.hasError ? res.error.detail : "");

    const r = execute(["git", "show", ":f.txt"], null, Config.none,
        size_t.max, dir);
    assert(r.output == after);
}
