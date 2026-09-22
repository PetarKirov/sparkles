/**
Test fixtures for repository-shaped scenarios.

$(LREF TmpGitRepo) is a scratch directory that is also a real git repository,
so a test can check this library's behaviour against git's own — the only
independent oracle available for `.gitignore` semantics.

$(B Excluded from the library configuration.) This module is compiled only for
`unittest` builds, so `sparkles:test-utils` stays out of the closure of
everything that merely walks a directory. If a consumer outside this package
needs these fixtures, promote the module to a `testing` configuration rather
than making the dependency unconditional.
*/
module sparkles.build_primitives.testing;

import sparkles.build_primitives.git_env : runGit;
import sparkles.test_utils.tmpfs : TmpFS;

/**
`true` when a usable `git` is on `PATH`.

A test whose oracle is git should $(D skipTest) on `false` rather than
returning early: an early return counts a degraded environment as a pass.
*/
bool gitAvailable() @safe nothrow
{
    try
        return runGit(["--version"]).status == 0;
    catch (Exception)
        return false;
}

/**
A scratch directory that is also an initialized git repository, removed when
the instance goes out of scope.

Every git invocation goes through $(D runGit), which scrubs `GIT_DIR` and its
relatives. That is not a detail: git exports `GIT_DIR` to every child it
spawns, so a fixture that inherited one would `init` into whatever repository
is running the suite — which has twice left `core.bare = true` in this
repository's own config.

Identity and signing are supplied per invocation with `-c`, so a developer's
global `user.email` or `commit.gpgsign` cannot change what a test commits, and
nothing is written outside the scratch tree.
*/
struct TmpGitRepo
{
    private TmpFS fs;

    @disable this();
    @disable this(this);

    private this(TmpFS fs) @safe
    {
        import core.lifetime : move;

        this.fs = move(fs);
    }

    /**
    Creates the scratch directory and runs `git init` in it.

    Params:
        prefix = scratch directory name beneath the system temp directory;
            defaults to the calling function, which keeps one test's tree
            distinct from another's.

    Throws:
        `Exception` when `git init` fails. Callers that treat a missing git
        as a skip should consult $(LREF gitAvailable) first.
    */
    static TmpGitRepo create(string prefix = __FUNCTION__) @safe
    {
        import std.exception : enforce;

        auto fs = TmpFS.create(prefix);
        fs.ensureDir();

        const result = runGit(["-c", "init.defaultBranch=main", "init", "-q", fs.dir()]);
        enforce(result.status == 0, "git init failed: " ~ result.output);

        import core.lifetime : move;

        return TmpGitRepo(move(fs));
    }

    /// The repository's working directory.
    string dir() @safe => fs.dir();

    /// Writes `contents` at `relativePath`, creating missing parents, and
    /// returns the full path. The name is the caller's — it is usually part
    /// of the behaviour under test (`.gitignore`, `dub.sdl`).
    string writeFile(string relativePath, string contents) @safe
        => fs.writeFileAt(relativePath, contents);

    /// Runs git in this repository with a scrubbed environment, returning
    /// `std.process.execute`'s result. Use it for queries an oracle needs
    /// (`check-ignore -v`, `status --porcelain`, `ls-files`).
    auto git(scope const(string)[] args) @safe => runGit(args, fs.dir());

    /**
    Stages everything and commits it.

    Identity is passed with `-c` rather than written to the repository's
    config, and signing is disabled explicitly so a globally-configured
    signing key cannot make a fixture prompt or fail.

    Throws: `Exception` when staging or committing fails.
    */
    void commitAll(string message = "fixture") @safe
    {
        import std.exception : enforce;

        const staged = git(["add", "-A"]);
        enforce(staged.status == 0, "git add failed: " ~ staged.output);

        const committed = git([
            "-c", "user.name=sparkles-test",
            "-c", "user.email=sparkles-test@invalid",
            "-c", "commit.gpgsign=false",
            "commit", "-q", "-m", message,
        ]);
        enforce(committed.status == 0, "git commit failed: " ~ committed.output);
    }
}

/// A fixture is a real repository: git answers about it, and the tree is gone
/// afterwards.
@("buildPrimitives.testing.tmpGitRepo.isARealRepositoryAndCleansUp")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;
    import std.file : exists;
    import std.string : strip;

    if (!gitAvailable)
        return skipTest("git is not on PATH");

    string root;

    {
        auto repo = TmpGitRepo.create();
        root = repo.dir();

        repo.writeFile(".gitignore", "*.log\n");
        repo.writeFile("src/app.d", "void main() {}\n");
        repo.writeFile("debug.log", "noise\n");
        repo.commitAll();

        // git's own view: the ignored file is not tracked, the source is.
        const tracked = repo.git(["ls-files"]).output.strip;
        assert(tracked == ".gitignore\nsrc/app.d", "unexpected tracked set: " ~ tracked);

        // And a query an oracle would actually make.
        const ignored = repo.git(["check-ignore", "-v", "--no-index", "debug.log"]);
        assert(ignored.status == 0);
    }

    assert(!root.exists, "the scratch repository outlived its fixture");
}
