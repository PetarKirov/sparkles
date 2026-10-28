/**
Review state in a versioned git ref (`DCM5`).

Draft comments, the files a reviewer has marked viewed, and the files they
folded live as JSON blobs in a commit on `refs/hue/data`, the git-spice
pattern. The ref is shared by every worktree of the repository, touches no
file in any of them, and keeps its history: `git log --patch refs/hue/data`
is the debugging interface.

Each save is one commit whose parent is the previous one, written with the
plumbing (`hash-object`, `mktree`, `commit-tree`) and moved with
`update-ref`, which checks the old value, so two hues saving at once lose
nothing silently: the second is refused and says so.
*/
module review_store;

import sparkles.doc_view.diff_comments : LocalComment;
import sparkles.doc_view.diff_session : AnchoredThread;

/// The ref the review state lives on.
enum string reviewRef = "refs/hue/data";

/// A file a reviewer marked viewed, at the content they saw.
struct ViewedMark
{
    /// The file, as the diff names its new side.
    string path;
    /// The git blob id of the new side they saw: when the file changes,
    /// the mark no longer holds ("changed since viewed").
    string blob;
}

/// Everything the ref holds.
struct ReviewData
{
    LocalComment[] comments;
    ViewedMark[] viewed;
    /// The files folded in the diff view.
    string[] folded;

    /// Whether `path` is marked viewed at `blob`.
    bool viewedAt(string path, string blob) const @safe pure nothrow @nogc
    {
        foreach (ref m; viewed)
            if (m.path == path)
                return m.blob == blob;
        return false;
    }

    /// Marks `path` viewed at `blob`, or clears its mark; returns whether it
    /// is now marked.
    bool toggleViewed(string path, string blob) @safe pure nothrow
    {
        foreach (i, ref m; viewed)
            if (m.path == path)
            {
                if (m.blob == blob)
                {
                    viewed = viewed[0 .. i] ~ viewed[i + 1 .. $];
                    return false;
                }
                m.blob = blob;
                return true;
            }
        viewed ~= ViewedMark(path, blob);
        return true;
    }
}

/// The git blob id of `text`, as `git hash-object` computes it.
string blobId(scope const(char)[] text) @safe pure nothrow
{
    import std.digest.sha : SHA1;
    import std.digest : toHexString, LetterCase;
    import std.conv : to;

    SHA1 sha;
    sha.start();
    sha.put(cast(const(ubyte)[]) "blob ");
    sha.put(cast(const(ubyte)[]) text.length.to!string);
    sha.put(cast(const(ubyte)[]) "\0");
    sha.put(cast(const(ubyte)[]) text);
    auto digest = sha.finish();
    return toHexString!(LetterCase.lower)(digest).idup;
}

/// The review state of the repository at `workDir`; empty when there is
/// none yet. Unreadable state is reported, never mistaken for empty.
string readReview(string workDir, out ReviewData data) @safe
{
    import sparkles.build_primitives.git_env : runGit;

    data = ReviewData.init;
    if (runGit(["rev-parse", "--verify", "--quiet", reviewRef], workDir).status != 0)
        return null; // nothing saved yet
    if (const failure = readBlob(workDir, "comments.json", data.comments))
        return failure;
    if (const failure = readBlob(workDir, "viewed.json", data.viewed))
        return failure;
    return readBlob(workDir, "folded.json", data.folded);
}

/**
Saves `data` as a new commit on the ref of the repository at `workDir`,
whose parent is the commit it was read from. Returns why it could not, or
`null`.
*/
string writeReview(string workDir, in ReviewData data, string message) @safe
{
    import sparkles.build_primitives.git_env : runGit;
    import staging : runWithInput;
    import std.string : strip;

    string tree;
    foreach (name, json; [
        "comments.json": encode(data.comments),
        "folded.json": encode(data.folded),
        "viewed.json": encode(data.viewed),
    ])
    {
        if (json is null)
            return "the review state does not encode as JSON";
        const blob = runWithInput(["git", "hash-object", "-w", "--stdin"], json, workDir);
        if (blob.status != 0)
            return "git hash-object failed: " ~ blob.output.strip;
        tree ~= "100644 blob " ~ blob.output.strip ~ "\t" ~ name ~ "\n";
    }
    const made = runWithInput(["git", "mktree"], tree, workDir);
    if (made.status != 0)
        return "git mktree failed: " ~ made.output.strip;

    const parent = runGit(["rev-parse", "--verify", "--quiet", reviewRef], workDir);
    auto commitArgs = ["commit-tree", made.output.strip, "-m", message];
    if (parent.status == 0)
        commitArgs ~= ["-p", parent.output.strip];
    const commit = runGit(commitArgs, workDir);
    if (commit.status != 0)
        return "git commit-tree failed: " ~ commit.output.strip;

    // The old value makes the move a compare-and-swap: a save that raced
    // another is refused rather than dropping the other's work.
    enum noCommit = "0000000000000000000000000000000000000000";
    const old = parent.status == 0 ? parent.output.strip : noCommit;
    const moved = runGit(["update-ref", reviewRef, commit.output.strip, old], workDir);
    if (moved.status != 0)
        return "another save moved " ~ reviewRef ~ " first: " ~ moved.output.strip;
    return null;
}

private string encode(T)(in T value) @safe
{
    import sparkles.wired.json : toJSON;

    auto json = (() @trusted => toJSON(value))();
    return json.hasValue ? json.value[].idup : null;
}

private string readBlob(T)(string workDir, string name, ref T into) @safe
{
    import sparkles.build_primitives.git_env : runGit;
    import sparkles.wired.json : fromJSON;

    const shown = runGit(["show", reviewRef ~ ":" ~ name], workDir);
    if (shown.status != 0)
        return null; // an older store without this file
    auto decoded = (() @trusted => fromJSON!T(shown.output))();
    if (decoded.hasError)
        return "unreadable " ~ name ~ " on " ~ reviewRef;
    into = decoded.value;
    return null;
}

@("review_store.blobId.matchesGit")
@safe unittest
{
    // `git hash-object` of these bytes, as git prints them.
    assert(blobId("") == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    assert(blobId("hello\n") == "ce013625030ba8dba906f756967f9e9ca394464a");
}

@("review_store.roundTripsThroughTheRef")
@safe unittest
{
    import sparkles.build_primitives.git_env : runGit;
    import sparkles.build_primitives.testing : gitAvailable, TmpGitRepo;
    import sparkles.test_runner.skip : skipTest;

    if (!gitAvailable)
        return skipTest("git is not installed");
    auto repo = TmpGitRepo.create();
    ReviewData data;
    assert(readReview(repo.dir, data) is null && data.comments.length == 0,
        "no ref yet: empty, not an error");

    LocalComment c;
    c.id = "c1";
    c.path = "f.d";
    c.line = 3;
    c.context = ["a", "b", "c"];
    c.anchorAt = 1;
    c.body_ = "why?";
    data.comments ~= c;
    data.folded = ["big.d"];
    assert(data.toggleViewed("f.d", blobId("x")));
    assert(writeReview(repo.dir, data, "hue: comment") is null);
    data.comments[0].resolved = true;
    assert(writeReview(repo.dir, data, "hue: resolve") is null);

    ReviewData back;
    assert(readReview(repo.dir, back) is null);
    assert(back.comments.length == 1 && back.comments[0].body_ == "why?"
        && back.comments[0].resolved && back.comments[0].context == ["a", "b", "c"]);
    assert(back.folded == ["big.d"] && back.viewedAt("f.d", blobId("x")));
    const log = runGit(["rev-list", "--count", reviewRef], repo.dir);
    assert(log.status == 0 && log.output[0] == '2', "each save is a commit");
    const files = runGit(["status", "--porcelain"], repo.dir);
    assert(files.output.length == 0, "no working-tree file is touched");
}

/**
The review state of the repository a diff session is in, as its host keeps
it (`DCM1`, `DCM2`, `DCM5`): read once when the diff opens, applied to every
document it produces, and saved on every change.
*/
final class ReviewSession
{
    import sparkles.doc_view.diff_session : AnchoredThread;
    import sparkles.doc_view.document : Document;
    import sparkles.syntax.md.model : MdDoc;

    /// The repository's top level.
    string root;
    /// Who comments: `git config user.name`.
    string author;
    ReviewData data;
    /// Why the stored state could not be read; it then starts empty.
    string error;
    /// Parses a comment body for its thread block.
    MdDoc delegate(string markdown) @system parse;

    /**
    The state of the repository `doc` was produced in, for a diff git
    produced; `null` for any other document, which has no repository to
    keep it in.
    */
    static ReviewSession open(in Document doc, MdDoc delegate(string) @system parse) @system
    {
        import sparkles.build_primitives.git_env : runGit;
        import sparkles.doc_view.document : ContentKind, DiffSource;
        import std.string : strip;

        if (doc.kind != ContentKind.diff || doc.diffSource.kind != DiffSource.Kind.git)
            return null;
        const top = runGit(["rev-parse", "--show-toplevel"]);
        if (top.status != 0)
            return null;
        auto s = new ReviewSession;
        s.root = top.output.strip;
        const name = runGit(["config", "user.name"], s.root);
        s.author = name.status == 0 && name.output.strip.length ? name.output.strip : "me";
        s.parse = parse;
        s.error = readReview(s.root, s.data);
        return s;
    }

    /// Hangs the comments on `doc`'s files and restores their folds and
    /// viewed marks.
    void apply(ref Document doc) @system
    {
        import std.algorithm.searching : canFind;

        doc.diffSession.threads = forgeThreads(doc.diffSession.threads);
        foreach (fi, ref e; doc.diffSession.entries)
        {
            const path = pathOf(e.oldPath, e.newPath);
            const old = fi < doc.diffSides.length ? doc.diffSides[fi].oldText : null;
            const new_ = fi < doc.diffSides.length ? doc.diffSides[fi].newText : null;
            doc.diffSession.threads ~= threadsFor(path, old, new_);
            e.collapsed = e.collapsed || data.folded.canFind(path);
            e.viewed = data.viewedAt(path, blobId(new_));
        }
    }

    /// The thread blocks of the comments on `path`, re-located in its sides.
    AnchoredThread[] threadsFor(string path, string oldText, string newText) @system
    {
        import sparkles.doc_view.diff_comments : threadsOf;

        return threadsOf(data.comments, path, oldText, newText, parse);
    }

    /// Saves comment `c`, giving it its id. Returns why it could not be
    /// saved, or `null`; it is kept either way.
    string post(ref LocalComment c) @safe
    {
        import std.format : format;

        c.id = format!"%d-%d"(c.created, data.comments.length);
        data.comments ~= c;
        return writeReview(root, data, "hue: comment on " ~ c.path);
    }

    /// Marks comment `id` resolved, or open again. `false` when there is no
    /// such comment; a failed save is in `error`.
    bool toggleResolved(string id) @safe
    {
        foreach (ref c; data.comments)
            if (c.id == id)
            {
                c.resolved = !c.resolved;
                error = writeReview(root, data,
                    (c.resolved ? "hue: resolve comment on " : "hue: reopen comment on ") ~ c.path);
                return true;
            }
        return false;
    }

    /// Marks `path` viewed at `newText`, or clears its mark; returns whether
    /// it is now marked. A failed save is in `error`.
    bool toggleViewed(string path, string newText) @safe
    {
        const now = data.toggleViewed(path, blobId(newText));
        error = writeReview(root, data, (now ? "hue: viewed " : "hue: unviewed ") ~ path);
        return now;
    }

    /// Records `path` folded or not. A failed save is in `error`.
    void fold(string path, bool collapsed) @safe
    {
        import std.algorithm.searching : canFind;
        import std.algorithm.iteration : filter;
        import std.array : array;

        if (collapsed == data.folded.canFind(path))
            return;
        data.folded = collapsed ? data.folded ~ path
            : data.folded.filter!(p => p != path).array;
        error = writeReview(root, data, (collapsed ? "hue: fold " : "hue: unfold ") ~ path);
    }

    /// Records which of a session's files are folded, in one save when any
    /// changed. A failed save is in `error`.
    void syncFolds(in string[] paths, in bool[] collapsed) @safe
    {
        import std.algorithm.searching : canFind;

        string[] folded;
        foreach (p; data.folded)
            if (!paths.canFind(p))
                folded ~= p; // a file this session does not show keeps its fold
        foreach (i, p; paths)
            if (collapsed[i])
                folded ~= p;
        if (folded == data.folded)
            return;
        data.folded = folded;
        error = writeReview(root, data, "hue: folds");
    }
}

/// The file a session entry names: its new path, or its old one when it was
/// deleted.
string pathOf(string oldPath, string newPath) @safe pure nothrow @nogc
    => newPath.length && newPath != "/dev/null" ? newPath : oldPath;

/// The forge's threads among `threads`: everything but local comments.
AnchoredThread[] forgeThreads(AnchoredThread[] threads) @safe pure nothrow
{
    AnchoredThread[] kept;
    foreach (t; threads)
        if (t.localId.length == 0)
            kept ~= t;
    return kept;
}

// ── The review actions both hosts take, over the viewer's model ──────────────

import sparkles.doc_view.viewer_model : ViewerModel;

/// Posts the comment being written to `review`'s state; with no review (no
/// repository) it is kept for this run only. Returns what to tell the user.
string postComment(ref ViewerModel vm, ReviewSession review) @system
{
    import sparkles.doc_view.diff_comments : threadsOf;
    import sparkles.syntax.md.model : MdDoc;
    import std.datetime.systime : Clock;

    LocalComment c;
    const fi = vm.fileOfRow(vm.diffCursorRow());
    if (!vm.commentTake(c, review !is null ? review.author : "me", Clock.currTime.toUnixTime))
        return "write the comment first";
    if (review is null)
    {
        c.id = "run";
        if (fi < vm.diffSides.length)
            vm.diffSession.threads ~= threadsOf([c], c.path, vm.diffSides[fi].oldText,
                vm.diffSides[fi].newText, (string md) => MdDoc.init);
        vm.rebuild();
        return "not in a git repository: the comment is kept for this run only";
    }
    const failure = review.post(c);
    refreshLocalThreads(vm, review);
    return failure !is null ? failure : "comment saved to " ~ reviewRef;
}

/// Re-hangs the local threads and viewed marks after the state changed.
void refreshLocalThreads(ref ViewerModel vm, ReviewSession review) @system
{
    if (review is null)
        return;
    auto threads = forgeThreads(vm.diffSession.threads);
    foreach (fi, ref e; vm.diffSession.entries)
        if (fi < vm.diffSides.length)
        {
            const path = pathOf(e.oldPath, e.newPath);
            threads ~= review.threadsFor(path, vm.diffSides[fi].oldText, vm.diffSides[fi].newText);
            e.viewed = review.data.viewedAt(path, blobId(vm.diffSides[fi].newText));
        }
    vm.diffSession.threads = threads;
    vm.rebuild();
}

/// Resolves the local comment on the cursor's row, or reopens it.
string resolveCommentAtCursor(ref ViewerModel vm, ReviewSession review) @system
{
    import sparkles.diff.model : RowKind;

    const at = vm.diffCursorRow();
    if (review is null || at >= vm.diff.rows.length)
        return "no comment here";
    const row = vm.diff.rows[at];
    const e = vm.diffSession.entries[vm.fileOfRow(at)];
    const path = pathOf(e.oldPath, e.newPath);
    foreach (ref t; vm.diffSession.threads)
    {
        const line = t.oldSide ? row.oldLine : row.newLine;
        if (t.localId.length && t.path == path && line != 0 && t.line == line
            && t.oldSide == (row.kind == RowKind.removed))
        {
            cast(void) review.toggleResolved(t.localId);
            refreshLocalThreads(vm, review);
            return review.error;
        }
    }
    return "no comment on this row";
}

/// Marks the cursor's file viewed at its content, or clears the mark.
string toggleViewedAtCursor(ref ViewerModel vm, ReviewSession review) @system
{
    const fi = vm.diffCursorFile();
    if (review is null || fi >= vm.diffSession.entries.length || fi >= vm.diffSides.length)
        return "viewed marks need a git repository";
    auto e = &vm.diffSession.entries[fi];
    e.viewed = review.toggleViewed(pathOf(e.oldPath, e.newPath), vm.diffSides[fi].newText);
    vm.rebuild();
    return review.error;
}

/// Saves which of the session's files are folded.
string persistFolds(ref ViewerModel vm, ReviewSession review) @system
{
    if (review is null)
        return null;
    string[] paths;
    bool[] collapsed;
    foreach (ref e; vm.diffSession.entries)
    {
        paths ~= pathOf(e.oldPath, e.newPath);
        collapsed ~= e.collapsed;
    }
    review.syncFolds(paths, collapsed);
    return review.error;
}
