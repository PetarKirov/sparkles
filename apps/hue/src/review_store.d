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
import forge : ForgeResult, ReviewComment, ReviewDraft, SubmittedReview, ThreadSide;

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
    /// `DCM6`: the forge review this session drafts for, and the head commit
    /// it shows; empty for a local diff, whose comments stay local.
    string target;
    /// ditto
    string head;

    /**
    The state of the repository `doc` was produced in: for a diff git
    produced, or a forge review fetched into this checkout (`DCM6`), whose
    comments are kept apart as drafts for it. `null` for any other
    document, which has no repository to keep it in.
    */
    static ReviewSession open(in Document doc, MdDoc delegate(string) @system parse) @system
    {
        import sparkles.build_primitives.git_env : runGit;
        import sparkles.doc_view.document : ContentKind, DiffSource;
        import std.string : strip;

        if (doc.kind != ContentKind.diff
            || doc.diffSource.kind != DiffSource.Kind.git && doc.reviewTarget.length == 0)
            return null;
        const top = runGit(["rev-parse", "--show-toplevel"]);
        if (top.status != 0)
            return null;
        auto s = new ReviewSession;
        s.root = top.output.strip;
        const name = runGit(["config", "user.name"], s.root);
        s.author = name.status == 0 && name.output.strip.length ? name.output.strip : "me";
        s.parse = parse;
        s.target = doc.reviewTarget;
        s.head = doc.reviewHead;
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

        return threadsOf(ours(), path, oldText, newText, parse);
    }

    /// The comments this session shows: its review's, or the local ones.
    LocalComment[] ours() @safe pure nothrow
    {
        LocalComment[] mine;
        foreach (c; data.comments)
            if (c.review == target)
                mine ~= c;
        return mine;
    }

    /// Saves comment `c`, giving it its id. Returns why it could not be
    /// saved, or `null`; it is kept either way.
    string post(ref LocalComment c) @safe
    {
        import std.format : format;

        c.id = format!"%d-%d"(c.created, data.comments.length);
        c.review = target;
        data.comments ~= c;
        return writeReview(root, data, "hue: comment on " ~ c.path);
    }

    /// `DCM6`: the comments drafted for this session's review and not yet
    /// submitted.
    size_t drafts() const @safe pure nothrow @nogc
    {
        size_t n;
        foreach (ref c; data.comments)
            n += target.length && c.review == target && !c.submitted;
        return n;
    }

    /**
    `DCM6`: submits every draft as one review through `send`, which takes
    the draft to the forge, and marks them submitted. Returns what to tell
    the user. A draft whose anchor the session could not place stays a
    draft and is named, never dropped.
    */
    string submit(scope ForgeResult!SubmittedReview delegate(string target, in ReviewDraft draft)
        @system send) @system
    {
        import sparkles.doc_view.diff_comments : bodyWithSuggestion;
        import std.conv : text;

        if (target.length == 0)
            return "only a forge's pull request takes a review";
        ReviewDraft draft = { commitSha: head };
        size_t[] sent;
        size_t unplaced;
        foreach (i, ref c; data.comments)
        {
            if (c.review != target || c.submitted)
                continue;
            if (c.line == 0)
            {
                ++unplaced;
                continue;
            }
            draft.comments ~= ReviewComment(c.path, c.line,
                c.oldSide ? ThreadSide.oldSide : ThreadSide.newSide, bodyWithSuggestion(c));
            sent ~= i;
        }
        if (draft.comments.length == 0)
            return unplaced ? text(unplaced, " drafts are on no line and were kept")
                : "no drafts to submit";
        auto made = send(target, draft);
        if (made.hasError)
            return "the review was not submitted: " ~ made.error.toString();
        foreach (i; sent)
            data.comments[i].submitted = true;
        error = writeReview(root, data, "hue: submit review to " ~ target);
        return text("submitted ", sent.length, sent.length == 1 ? " comment" : " comments",
            unplaced ? text(" (", unplaced, " on no line kept)") : "",
            made.value.url.length ? ": " ~ made.value.url : "");
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

/**
`DCM4`: applies the local suggestion on the cursor's row to the working
tree with `git apply`, a dry run first. `true` once applied, when the host
must produce the diff again; `said` is what to tell the user.
*/
bool applySuggestionAtCursor(ref ViewerModel vm, ReviewSession review, out string said) @system
{
    import sparkles.doc_view.diff_comments : suggestionPatch;
    import staging : runWithInput;
    import std.string : strip;

    if (review is null || !vm.diffSession.editable)
    {
        said = "suggestions apply to a working-tree diff";
        return false;
    }
    const at = vm.diffCursorRow();
    if (at >= vm.diff.rows.length)
    {
        said = "no suggestion here";
        return false;
    }
    const fi = vm.fileOfRow(at);
    const row = vm.diff.rows[at];
    foreach (ref t; vm.diffSession.threads)
    {
        if (!t.hasSuggestion || t.oldSide || row.newLine == 0 || t.line != row.newLine)
            continue;
        foreach (ref c; review.data.comments)
        {
            if (c.id != t.localId)
                continue;
            const patch = suggestionPatch(c, vm.diffSides[fi].newText);
            if (patch is null)
            {
                said = "the suggested lines changed since";
                return false;
            }
            const checked = runWithInput(["git", "apply", "--check", "-"], patch, review.root);
            if (checked.status != 0)
            {
                said = "the suggestion no longer applies: " ~ checked.output.strip;
                return false;
            }
            const applied = runWithInput(["git", "apply", "-"], patch, review.root);
            if (applied.status != 0)
            {
                said = "git apply failed: " ~ applied.output.strip;
                return false;
            }
            said = "applied the suggestion to " ~ c.path;
            return true;
        }
    }
    said = "no suggestion on this row";
    return false;
}

@("review_store.ReviewSession.submitsDraftsAsOneReviewAndKeepsUnplacedOnes")
@system unittest
{
    import sparkles.build_primitives.testing : gitAvailable, TmpGitRepo;
    import sparkles.test_runner.skip : skipTest;
    import std.algorithm.searching : canFind;

    // `DCM6`: the drafts for this pull request go in one request against
    // its head; a local comment is not a draft, and one on no line stays.
    if (!gitAvailable)
        return skipTest("git is not installed");
    auto repo = TmpGitRepo.create();
    auto s = new ReviewSession;
    s.root = repo.dir;
    s.target = "github.com/o/r#7";
    s.head = "abc123";

    LocalComment placed, unplaced, local;
    placed.path = unplaced.path = local.path = "f.d";
    placed.line = 3;
    placed.body_ = "why?";
    unplaced.body_ = "where?";
    assert(s.post(placed) is null && s.post(unplaced) is null);
    s.data.comments ~= local; // drafted on a local diff: not this review's
    assert(s.drafts == 2);

    ReviewDraft got;
    const said = s.submit((string target, in ReviewDraft d) {
        assert(target == "github.com/o/r#7");
        got = ReviewDraft(d.commitSha, d.body_, d.comments.dup);
        return ForgeResult!SubmittedReview(SubmittedReview("https://example/review"));
    });
    assert(got.commitSha == "abc123" && got.comments.length == 1 && got.comments[0].line == 3);
    assert(said.canFind("submitted 1 comment") && said.canFind("1 on no line kept"), said);
    assert(s.drafts == 1, "the unplaced one is still a draft");

    ReviewData stored;
    assert(readReview(repo.dir, stored) is null);
    assert(stored.comments[0].submitted && !stored.comments[1].submitted);
}
