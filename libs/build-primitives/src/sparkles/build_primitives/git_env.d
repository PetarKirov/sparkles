/**
The environment a `git` child process needs when the caller names the
repository it means, instead of inheriting one.

Git exports $(D GIT_DIR) — and the rest of $(LREF repositoryLocationVars) —
to every process it spawns: a `rebase --exec` step, a hook, `bisect run`, a
`!` alias. A git command that inherits one of those operates on *that*
repository whatever directory it was pointed at, because neither
`git -C <dir>` nor a child working directory overrides them.

That is not hypothetical. A test fixture running `git init -q <tmpdir>` under
an inherited `GIT_DIR` re-initialises the **inherited** repository rather
than creating a new one; and when the inherited `GIT_DIR` is a linked
worktree's (`.git/worktrees/<name>`, which does not end in `/.git`), git
guesses that repository is bare and writes `core.bare = true` into the shared
config. Every linked worktree keeps working, so nothing looks broken — only
the main checkout dies, with `fatal: this operation must be run in a work
tree`. This repository lost a day to exactly that, twice, before the cause
was found.

So a git call that names its repository — through `-C <dir>`, a working
directory, or a path argument — goes through $(LREF runGit), or carries
$(LREF gitChildEnvironment) itself when it needs a pipe.

The converse is equally deliberate: a program that means "whatever repository
invoked me" must keep inheriting. `ci` running as a pre-commit hook and
`release` acting on the checkout it was started in are both in that second
category, and neither belongs here.

See_Also:
    $(LINK2 https://git-scm.com/docs/git#_environment_variables, git(1) —
    Environment Variables)
*/
module sparkles.build_primitives.git_env;

/**
The variables git reads at startup to locate repository state.

Each one redirects a different part of that state, and all of them survive
`-C`:

$(LIST
    * `GIT_DIR` — the repository directory itself.
    * `GIT_COMMON_DIR` — the shared half of a split (per-worktree) git dir.
    * `GIT_WORK_TREE` — the working tree the repository is attached to.
    * `GIT_INDEX_FILE` — the index that `add`/`apply --cached` writes.
    * `GIT_OBJECT_DIRECTORY` — where new objects are written.
    * `GIT_ALTERNATE_OBJECT_DIRECTORIES` — further object stores to read.
    * `GIT_NAMESPACE` — the namespace refs are read and written under.
)

Variables that only *constrain* discovery (`GIT_CEILING_DIRECTORIES`) or that
git exports for a script's benefit without reading back (`GIT_PREFIX`) are
deliberately absent: removing them changes no repository decision.
*/
immutable string[] repositoryLocationVars = [
    "GIT_DIR",
    "GIT_COMMON_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
];

/// `env` with every $(LREF repositoryLocationVars) entry removed. The whole
/// value of the result is what it leaves out, so it is only ever correct
/// paired with `Config.newEnv`.
string[string] withoutRepositoryLocation(string[string] env) @safe pure nothrow
{
    foreach (string name; repositoryLocationVars)
        env.remove(name);
    return env;
}

/// The current environment, scrubbed by $(LREF withoutRepositoryLocation),
/// in the shape `std.process` takes. Pass it with `Config.newEnv`: a non-null
/// `env` is otherwise *added* to the inherited environment, which would leave
/// every removed variable in place.
string[string] gitChildEnvironment() @safe
{
    import std.process : environment;

    return withoutRepositoryLocation(environment.toAA());
}

/// The same environment as the `"KEY=value"` list `sparkles:event-horizon`'s
/// `ProcessConfig.env` takes.
string[] gitChildEnvList() @safe
{
    import std.array : appender;

    auto list = appender!(string[]);
    foreach (name, value; gitChildEnvironment())
        list ~= name ~ "=" ~ value;
    return list[];
}

/**
Run `git` on a repository the caller names, never an inherited one.

Params:
    args = the arguments after the program name (`["-C", dir, "status"]`).
    workDir = the child's working directory; `null` inherits the caller's.

Returns:
    `std.process.execute`'s result — `status` and combined `output`.

Throws:
    Whatever `execute` throws when git cannot be spawned at all. Callers that
    treat a missing git as a skip rather than a failure keep catching it; this
    function deliberately does not decide that for them.
*/
auto runGit(scope const(string)[] args, scope const(char)[] workDir = null) @safe
{
    import std.process : Config, execute;

    return execute("git" ~ args, gitChildEnvironment(), Config.newEnv,
        size_t.max, workDir);
}

@("git_env.withoutRepositoryLocation.removesEveryRedirectAndNothingElse")
@safe pure unittest
{
    string[string] env = ["PATH": "/usr/bin", "GIT_AUTHOR_NAME": "t"];
    foreach (string name; repositoryLocationVars)
        env[name] = "/somewhere/else";

    const scrubbed = withoutRepositoryLocation(env);

    foreach (string name; repositoryLocationVars)
        assert(name !in scrubbed, "a redirect survived the scrub: " ~ name);
    assert(scrubbed["PATH"] == "/usr/bin", "PATH must survive");
    assert(scrubbed["GIT_AUTHOR_NAME"] == "t",
        "git variables that do not name a repository must survive");
}

@("git_env.gitChildEnvironment.namesNoRepository")
@safe unittest
{
    const env = gitChildEnvironment();
    foreach (string name; repositoryLocationVars)
        assert(name !in env);
    // A scrub that returned an empty map would also pass the loop above.
    assert(env.length > 0, "the rest of the environment is carried through");
}

/// The defect itself, hermetically: a poisoned `GIT_DIR` captures a child git
/// even though the child is run inside another repository, and the scrub is
/// what releases it.
@("git_env.runGit.ignoresAnInheritedGitDir")
@safe unittest
{
    import sparkles.test_runner.skip : skipTest;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : Config, execute;
    import std.string : strip;

    const root = buildPath(tempDir(), "sparkles-git-env-test");

    static void discard(string dir) @safe nothrow
    {
        try
            rmdirRecurse(dir);
        catch (Exception) {}
    }

    discard(root);
    mkdirRecurse(root);
    scope (exit) discard(root);

    const subject = buildPath(root, "subject");
    const elsewhere = buildPath(root, "elsewhere");
    mkdirRecurse(subject);
    mkdirRecurse(elsewhere);
    try
    {
        if (runGit(["init", "-q", subject]).status != 0
            || runGit(["init", "-q", elsewhere]).status != 0)
            skipTest("git init failed");
    }
    catch (Exception)
        skipTest("git not available");

    // Every path compared below is a path git printed. Asking git what it
    // calls these two repositories, rather than assembling the names here,
    // is what keeps the test honest about a spelling it does not control:
    // macOS hands out a `/var/…` temp dir and reports the `/private/var/…`
    // it resolves to, and Windows answers with `/` where `buildPath` used
    // `\`. Both once failed this test while the behaviour it guards was
    // perfectly correct.
    const elsewhereDir = runGit(["rev-parse", "--absolute-git-dir"],
        elsewhere).output.strip;
    const subjectDir = runGit(["rev-parse", "--absolute-git-dir"],
        subject).output.strip;
    assert(elsewhereDir.length && subjectDir.length);
    assert(elsewhereDir != subjectDir, "the two fixtures must be distinct");

    // A caller that inherited a `GIT_DIR` pointing at `elsewhere`.
    auto poisoned = gitChildEnvironment();
    poisoned["GIT_DIR"] = elsewhereDir;

    const captured = execute(["git", "rev-parse", "--absolute-git-dir"],
        poisoned, Config.newEnv, size_t.max, subject);
    assert(captured.status == 0);
    assert(captured.output.strip == elsewhereDir,
        "the hazard this module exists for stopped reproducing");

    const released = execute(["git", "rev-parse", "--absolute-git-dir"],
        withoutRepositoryLocation(poisoned), Config.newEnv, size_t.max,
        subject);
    assert(released.status == 0);
    assert(released.output.strip == subjectDir,
        "the scrub must return the child to the directory it was given");
}
