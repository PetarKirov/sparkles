/**
Listings for applications: the files of a fileset beneath a directory on the
native file system, as relative paths, and the `--include`/`--exclude`
precedence the explorer gives its glob flags (`XPF2`).

$(UL
$(LI $(LREF listFiles) resolves a fileset at a root through `RingVfs`, on an
    event loop of its own when the host has one (FSD1, FSD3).)
$(LI $(LREF workTree) is git's view of a work tree: every file but `.git`
    and those its `.gitignore` files exclude (A16).)
$(LI $(LREF withGlobs) applies include and exclude globs: an include match
    admits a file whatever else says, `.git` aside; otherwise an exclude
    match drops it.)
$(LI $(LREF listRepository) puts the three together for a directory that
    may lie deep in a repository: the `.gitignore` files above it apply,
    as git applies them.)
$(LI $(LREF GlobFilter) is the same precedence for one path at a time,
    with no file system, and $(LREF GlobSet) the globs alone: whether one
    matches a file, and whether one may match beneath a directory.)
)

Globs are fileset patterns (FSG1): a pattern without a `/` matches a name at
any depth, one with a `/` is anchored to the directory listed, and `**`
matches any number of components, none included. That is the
`.gitignore` reading, which the M4 record compares with the old
`std.path.globMatch` one (A17).

Allocates, with the GC, what it returns: these are for applications, not for
the resolution's `@nogc` core.
*/
module sparkles.build_primitives.fileset.listing;

import std.conv : text;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.errors : NoGcHook;

import sparkles.build_primitives.fileset.pattern : CasePolicy;
import sparkles.build_primitives.fileset.value : Fileset, FilesetEvaluator, Filesets;

/**
The files a listing found, relative to the directory listed and sorted; the
directories it listed and found nothing selected in (FSV4), sorted; the
entries it could not read (FSE2), each `path: kind`; and how many
`.gitignore` rule lines it read that no fileset pattern expresses (A15).
Git applies such a line and the listing does not, so when the count is not
zero a file git ignores may be listed: a consumer should say so.
*/
struct Listing
{
    string[] files;      ///
    string[] emptyDirs;  /// selected whole, yet holding nothing selected (FSV4, D5)
    string[] unreadable; ///
    uint skippedIgnoreRules; /// `.gitignore` rule lines that did not apply

    /// What a consumer should tell its user the listing may lack or hold
    /// beyond git's view, or `null` when nothing.
    string caveat() const @safe pure
    {
        string note;
        if (skippedIgnoreRules)
            note = text(skippedIgnoreRules, " .gitignore rule", skippedIgnoreRules == 1 ? "" : "s",
                " too complex to apply, so files git ignores may be listed");
        if (unreadable.length)
            note ~= text(note.length ? "; " : "", unreadable.length, " entr",
                unreadable.length == 1 ? "y" : "ies", " could not be read, the first ",
                unreadable[0]);
        return note;
    }
}

///
@("fileset.listing.Listing.caveat")
@safe pure unittest
{
    assert(Listing(["a"]).caveat is null);
    assert(Listing(null, null, ["x: permission"], 2).caveat == "2 .gitignore rules too complex "
        ~ "to apply, so files git ignores may be listed; 1 entry could not be read, the first "
        ~ "x: permission");
}

/// What a listing returns: the listing, or why it failed. A resolution
/// fails as a whole (FSE1); so does a glob that is not a fileset pattern.
alias ListingResult = Expected!(Listing, string, NoGcHook);

/// A fileset, or the glob that could not be read as a pattern.
alias GlobsResult = Expected!(Fileset, string, NoGcHook);

/**
git's view of a work tree: every file except those its `.gitignore` files
exclude and any named `.git` or beneath one, the repository's own or a
nested repository's, which git never lists. Resolve it at the repository's
root, where the `.gitignore` files are (A16, A23).
*/
Fileset workTree(ref Filesets s) @safe nothrow @nogc =>
    s.difference(s.difference(s.everything, s.gitignored), s.glob(".git").value);

/**
`base` under the explorer's glob precedence (`XPF2`): a file an `include`
glob matches is admitted whatever `base` says, unless it is in `.git`;
otherwise a file an `exclude` glob matches is dropped. An empty `include`
admits nothing extra. A glob that is not a fileset pattern is an error.
*/
GlobsResult withGlobs(ref Filesets s, Fileset base,
    scope const(string)[] include, scope const(string)[] exclude) @safe
{
    auto inc = globsOf(s, include);
    if (inc.hasError)
        return inc;
    auto exc = globsOf(s, exclude);
    if (exc.hasError)
        return exc;
    return ok!(string, NoGcHook)(s.union_(s.difference(base, exc.value),
        s.difference(inc.value, s.glob(".git").value)));
}

/// The union of `globs`, each a fileset pattern.
GlobsResult globsOf(ref Filesets s, scope const(string)[] globs)
    @safe
{
    Fileset u = s.nothing;
    foreach (g; globs)
    {
        auto one = s.glob(g);
        if (one.hasError)
            return err!(Fileset, NoGcHook)("not a fileset pattern: " ~ g);
        u = s.union_(u, one.value);
    }
    return ok!(string, NoGcHook)(u);
}

/**
The members of the fileset `make` builds, resolved at the directory `root`:
relative to it, sorted. Runs on the calling scheduler's fibers when there
is one, else on an event loop of its own, so the listing of sibling
directories and the `stat`s of their entries overlap; where the host has no
loop, one request after another.
*/
ListingResult listFiles(string root, scope Fileset delegate(ref Filesets) @safe make,
    CasePolicy policy = CasePolicy.sensitive) @safe
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : Rights;
    import sparkles.build_primitives.fileset.driver : PathCollector, resolve, resolveWith;
    import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
    import sparkles.event_horizon.admission : Admission;
    import sparkles.event_horizon.sched : Sched, currentScheduler, onScheduler;
    import sparkles.event_horizon.vfs : RingVfs;

    auto sets = Filesets(policy);
    const f = make(sets);
    auto vfs = new RingVfs;
    // Read rights too: a `gitignored` leaf reads each `.gitignore`.
    auto opened = openRoot!(Rights.readOnly)(vfs, root, ambientAuthority());
    if (opened.hasError)
        return err!(Listing, NoGcHook)("the directory to list could not be opened: " ~ root);

    ListingRun run;
    version (Posix)
        enum loopOffloads = true;
    else
        enum loopOffloads = false;
    static if (!loopOffloads)
    {
        // Where the loop has no blocking pool (Windows), `RingVfs` runs each
        // call inline on the fiber that makes it, so a loop overlaps
        // nothing, and the native backend's frames (a listing's buffer held
        // inline, wide-character paths) overflow a fiber's stack. One
        // request after another, then: on this thread's stack, or on a
        // thread of its own when this is a fiber.
        if (onScheduler())
        {
            import core.thread : Thread;

            enum size_t listingStack = 4 << 20;
            auto t = new Thread(() {
                run.began = true;
                run.result = resolve(opened.value.borrow, sets, f, run.sink);
                run.finished = true;
            }, listingStack);
            () @trusted { t.start(); t.join(); }();
        }
    }
    // On a scheduler already, as a UI loop is: resolve on its fibers.
    // Otherwise on a loop of our own, for as long as the listing takes.
    else if (onScheduler())
    {
        auto exec = LoopExecutor!Sched(&currentScheduler(), new Admission(32));
        run.began = true;
        run.result = resolveWith(opened.value.borrow, sets, f, run.sink, exec);
        run.finished = true;
    }
    else
    {
        Sched s;
        if (!Sched.create(s).hasError)
            cast(void) s.run(() {
                auto exec = LoopExecutor!Sched(&s, new Admission(32));
                run.began = true;
                run.result = resolveWith(opened.value.borrow, sets, f, run.sink, exec);
                run.finished = true;
            });
    }
    return settle(run, (ref PathCollector sink) => resolve(opened.value.borrow, sets, f, sink));
}

// One attempt at a listing on an event loop: whether its resolution began
// and finished, and what it collected.
private struct ListingRun
{
    import sparkles.build_primitives.fileset.driver : PathCollector, ResolutionResult;

    PathCollector sink;
    ResolutionResult result = ResolutionResult.init;
    bool began, finished;
}

/*
The listing `run` made, whether or not the loop that ran it then failed. A
resolution the loop never began is made again by `inline`, into a sink of
its own; one it began and did not finish is an error, since what it
collected is a part of the listing.
*/
private ListingResult settle(Inline)(ref ListingRun run, scope Inline inline)
{
    import std.algorithm.sorting : sort;

    import sparkles.build_primitives.fileset.driver : PathCollector;

    if (!run.finished)
    {
        if (run.began)
            return err!(Listing, NoGcHook)("the listing's event loop stopped before it finished");
        run.sink = PathCollector.init;
        run.result = inline(run.sink);
    }
    if (run.result.hasError)
        return err!(Listing, NoGcHook)(run.result.error.context);
    // The directory listed is `""` in what the resolution reports.
    foreach (u; run.sink.unreadable)
        if (u.length >= 2 && u[0 .. 2] == ": ")
            return err!(Listing, NoGcHook)("the directory to list could not be read" ~ u[1 .. $]);
    return ok!(string, NoGcHook)(Listing(run.sink.members.sort.release,
        run.sink.emptyDirs.sort.release, run.sink.unreadable, run.sink.skippedIgnoreRules));
}

/// A listing the loop ran is taken as it is, even when the loop then fails:
/// nothing is collected twice. One it never began is made inline.
@("fileset.listing.settle")
@safe unittest
{
    import sparkles.build_primitives.fileset.driver : PathCollector, ResolutionResult;

    ResolutionResult again(ref PathCollector sink)
    {
        sink.members ~= "a";
        return ResolutionResult.init;
    }

    // Finished on the loop, which then failed: what it collected, once.
    ListingRun done;
    done.began = done.finished = true;
    done.sink.members = ["a"];
    assert(settle(done, &again).value.files == ["a"]);

    // Begun and cut off: a part of the listing is no listing.
    ListingRun cut;
    cut.began = true;
    cut.sink.members = ["a"];
    assert(settle(cut, &again).hasError);

    // Never begun: made inline, into a sink of its own.
    ListingRun never;
    never.sink.members = ["stale"];
    assert(settle(never, &again).value.files == ["a"]);
}

/**
The files of the work tree beneath `dir` that pass `include` and `exclude`
($(LREF withGlobs)), relative to `dir` and sorted. Globs are relative to
`dir`. See the other overload for where the fileset is resolved.
*/
ListingResult listRepository(string dir, scope const(string)[] include = null,
    scope const(string)[] exclude = null) @safe
{
    const abs = canonicalDir(dir);
    const base = repositoryBase(abs, repositoryRoot(abs));
    auto inc = rebased(include, base), exc = rebased(exclude, base);

    string refusal;
    auto listed = listRepository(dir, (ref Filesets s) @safe {
        auto globbed = withGlobs(s, workTree(s), inc, exc);
        if (globbed.hasError)
            refusal = globbed.error;
        return globbed.hasError ? s.nothing : globbed.value;
    });
    return refusal.length ? err!(Listing, NoGcHook)(refusal) : listed;
}

/**
The members beneath `dir` of the fileset `make` builds, relative to `dir`
and sorted. When `dir` lies in a git repository, the fileset is written
and resolved relative to the repository's root, so every `.gitignore` on the
way down to `dir` applies, and the plan starts at `dir`, listing nothing
beside it (FSA2). Outside a repository, it is resolved at `dir`.

`dir` is taken by its real path, links resolved, so a link to a directory
lists the directory it names, beneath the `.gitignore` files above that
one. A directory that cannot be read is an error, not an empty listing.
*/
ListingResult listRepository(string dir, scope Fileset delegate(ref Filesets) @safe make) @safe
{
    const abs = canonicalDir(dir);
    const top = repositoryRoot(abs);
    const base = repositoryBase(abs, top);
    auto listed = listFiles(top is null ? abs : top, (ref Filesets s) @safe {
        Fileset f = make(s);
        return base.length ? s.intersection(s.glob("/" ~ escapeGlob(base) ~ "/**").value, f) : f;
    });
    if (listed.hasError || !base.length)
        return listed;
    import std.algorithm.searching : find, startsWith;

    // The directory listed is the plan's start root; one it could not read
    // is reported as `base: kind`.
    auto unread = listed.value.unreadable.find!(p => p.startsWith(base ~ ": "));
    if (unread.length)
        return err!(Listing, NoGcHook)("the directory to list could not be read: " ~ unread[0]);
    // The restriction is a pattern, and patterns match names under NFC, so
    // it may also admit a sibling whose name differs from `base` only in
    // its encoding (`Keep` beside `\u212Aeep`, an NFD spelling beside an NFC
    // one). Identity is byte-exact (invariant 5): keep only what lies
    // beneath `base` byte for byte.
    import std.algorithm.iteration : filter, map;
    import std.array : array;

    const prefix = base ~ "/";
    auto l = listed.value;
    l.files = l.files.filter!(p => p.startsWith(prefix)).map!(p => p[prefix.length .. $]).array;
    // The directory listed is reported as `""`, as the fileset root is.
    l.emptyDirs = l.emptyDirs.filter!(p => p == base || p.startsWith(prefix))
        .map!(p => p == base ? "" : p[prefix.length .. $]).array;
    l.unreadable = l.unreadable.filter!(p => p.startsWith(prefix) || p.startsWith(base ~ ":")).array;
    return ok!(string, NoGcHook)(l);
}

// `dir` as an absolute, normalized path, with every link on it resolved
// where it exists: a lexical path through a link names a repository, and an
// entry, the walk would not follow.
private string canonicalDir(string dir) @safe
{
    import std.path : absolutePath, buildNormalizedPath;

    const abs = dir.absolutePath.buildNormalizedPath;
    version (Posix)
    {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.string : fromStringz, toStringz;

        return () @trusted {
            auto resolved = realpath(abs.toStringz, null);
            if (resolved is null)
                return abs;
            scope (exit)
                free(resolved);
            return resolved.fromStringz.idup;
        }();
    }
    else
        return abs;
}

/// `path` as a pattern that matches it literally: each glob character escaped.
string escapeGlob(scope const(char)[] path) @safe pure nothrow
{
    string out_;
    foreach (c; path)
    {
        if (c == '*' || c == '?' || c == '[' || c == ']' || c == '{' || c == '}' || c == '\\'
            || c == '!')
            out_ ~= '\\';
        out_ ~= c;
    }
    return out_;
}

// `abs`, an absolute normalized path beneath the repository root `top`, as
// a path relative to `top` whose separator is `/`, the one fileset paths
// use; `""` when there is no repository or `abs` is its root. On Windows a
// native path separates with `\`, which in a pattern is an escape. A root
// that ends in a separator (`/`, `C:\`) contributes none of its own.
private string repositoryBase(string abs, string top) @safe
{
    import std.array : join;
    import std.path : isDirSeparator, pathSplitter;

    if (top is null || top == abs)
        return "";
    const skip = top.length + (isDirSeparator(top[$ - 1]) ? 0 : 1);
    return abs[skip .. $].pathSplitter.join("/");
}

///
@("fileset.listing.repositoryBase")
@safe unittest
{
    assert(repositoryBase("/r/a/b", "/r") == "a/b");
    assert(repositoryBase("/r", "/r") == "");
    assert(repositoryBase("/a", "/") == "a");
    assert(repositoryBase("/a", null) == "");
    version (Windows)
    {
        assert(repositoryBase(`C:\repo\libs\base`, `C:\repo`) == "libs/base");
        assert(repositoryBase(`C:\x`, `C:\`) == "x");
    }
}

/**
The root of the git work tree holding the absolute, normalized path `dir`:
the nearest directory at or above it holding `.git` (a directory, or a file
naming a linked worktree's), or `null`.
*/
string repositoryRoot(string dir) @safe
{
    import std.file : exists;
    import std.path : buildPath, dirName;

    for (string d = dir;; d = d.dirName)
    {
        if (buildPath(d, ".git").exists)
            return d;
        if (d.dirName == d)
            return null;
    }
}

/**
A set of globs, asked one path at a time: whether one matches a file, and
whether one may match a file beneath a directory, decided as a resolution's
plan decides whether to enter it. No glob matches nothing.
*/
struct GlobSet
{
    private Filesets sets;
    private FilesetEvaluator ev;

    @disable this(this);

    /// The set of `globs`; an error when one is not a fileset pattern.
    static Expected!(GlobSet*, string, NoGcHook) make(scope const(string)[] globs,
        CasePolicy policy = CasePolicy.sensitive) @safe
    {
        auto g = new GlobSet;
        g.sets = Filesets(policy);
        auto u = globsOf(g.sets, globs);
        if (u.hasError)
            return err!(GlobSet*, NoGcHook)(u.error);
        g.ev = FilesetEvaluator(g.sets, u.value);
        return ok!(string, NoGcHook)(g);
    }

    /// Whether a glob matches the file `path`.
    bool matches(scope const(char)[] path) @safe => ev.contains(sets, path);

    /// Whether a glob may match a file beneath the directory `path`.
    bool reaches(scope const(char)[] path) @safe
    {
        import sparkles.build_primitives.fileset.value : DirVerdict;

        return ev.dirVerdictOf(sets, path) != DirVerdict.skip;
    }
}

/// Whether a glob matches a file, and may match beneath a directory.
@("fileset.listing.GlobSet")
@safe unittest
{
    auto g = GlobSet.make(["build/*.log", "*.md"]);
    assert(g.value.matches("build/a.log") && g.value.matches("x/y.md"));
    assert(!g.value.matches("x/build/a.log") && !g.value.matches("build/x/a.log"));
    assert(g.value.reaches("build") && g.value.reaches("") && g.value.reaches("x/y"),
        "*.md may match anywhere");
    auto anchored = GlobSet.make(["/build/*.log"]);
    assert(anchored.value.reaches("build") && !anchored.value.reaches("src"));
    assert(!anchored.value.reaches("build/x"));
    auto none = GlobSet.make(null);
    assert(!none.value.matches("a") && !none.value.reaches(""));
}

/**
The explorer's precedence (`XPF2`) for one path at a time, without a file
system: `passes(path)` is true when an `include` glob matches it, and
otherwise when no `exclude` glob does. `path` is relative to the directory
the globs are written for.
*/
struct GlobFilter
{
    private Filesets sets;
    private FilesetEvaluator include_, exclude_;
    private bool hasInclude;

    @disable this(this);

    /// The filter of `include` and `exclude`; an error when a glob is not a
    /// fileset pattern.
    static Expected!(GlobFilter*, string, NoGcHook) make(scope const(string)[] include,
        scope const(string)[] exclude, CasePolicy policy = CasePolicy.sensitive) @safe
    {
        auto f = new GlobFilter;
        f.sets = Filesets(policy);
        auto inc = globsOf(f.sets, include);
        if (inc.hasError)
            return err!(GlobFilter*, NoGcHook)(inc.error);
        auto exc = globsOf(f.sets, exclude);
        if (exc.hasError)
            return err!(GlobFilter*, NoGcHook)(exc.error);
        f.include_ = FilesetEvaluator(f.sets, inc.value);
        f.exclude_ = FilesetEvaluator(f.sets, exc.value);
        f.hasInclude = include.length != 0;
        return ok!(string, NoGcHook)(f);
    }

    /// Whether the file `path` passes.
    bool passes(scope const(char)[] path) @safe
    {
        if (hasInclude && include_.contains(sets, path))
            return true;
        return !exclude_.contains(sets, path);
    }
}

// Globs written relative to `base`, as patterns relative to the repository's
// root: an anchored one, or one with a `/`, beneath `base`; one without, which
// matches at any depth, as it is.
private string[] rebased(scope const(string)[] globs, string base) @safe
{
    import std.algorithm.searching : canFind, startsWith;

    string[] out_;
    foreach (g; globs)
    {
        if (!base.length)
            out_ ~= g;
        else
        {
            const body = g.startsWith("/") ? g[1 .. $] : g;
            const trimmed = body.length && body[$ - 1] == '/' ? body[0 .. $ - 1] : body;
            out_ ~= g.startsWith("/") || trimmed.canFind('/') ? "/" ~ escapeGlob(base) ~ "/" ~ body
                : g;
        }
    }
    return out_;
}

version (unittest)
{
    // A work tree on disk: a repository holding `sub`, with `.gitignore`
    // files at the top and beneath `sub`.
    private auto workTreeFixture() @system
    {
        import sparkles.test_utils.tmpfs : TmpFS;

        auto tmp = TmpFS.create();
        foreach (pair; [
            [".git/config", "[core]\n"],
            [".gitignore", "*.tmp\nbuild/\n"],
            ["top.d", "x"],
            ["sub/.gitignore", "local.d\n"],
            ["sub/app.d", "x"],
            ["sub/notes.md", "x"],
            ["sub/scratch.tmp", "x"],
            ["sub/local.d", "x"],
            ["sub/deep/more.md", "x"],
            ["sub/build/out.d", "x"],
        ])
            tmp.writeFileAt(pair[0], pair[1]);
        return tmp;
    }
}

/// The work tree beneath a directory deep in a repository: the `.gitignore`
/// above it applies, and so does its own; `.git` is never listed.
@("fileset.listing.listRepository.workTree")
@system unittest
{
    import std.path : buildPath;

    auto tmp = workTreeFixture();
    auto top = listRepository(tmp.dir);
    assert(!top.hasError, top.hasError ? top.error : "");
    assert(top.value.files == [".gitignore", "sub/.gitignore", "sub/app.d", "sub/deep/more.md",
        "sub/notes.md", "top.d"], top.value.files.text);

    auto sub = listRepository(buildPath(tmp.dir, "sub"));
    assert(sub.value.files == [".gitignore", "app.d", "deep/more.md", "notes.md"],
        sub.value.files.text);
}

/// `XPF2`: an include glob admits a file a `.gitignore` excludes, and wins
/// over an exclude glob; an exclude glob drops the rest; nothing comes from
/// `.git`. A glob that is not a pattern is an error.
@("fileset.listing.listRepository.globs")
@system unittest
{
    import std.path : buildPath;

    auto tmp = workTreeFixture();
    const sub = buildPath(tmp.dir, "sub");
    auto r = listRepository(sub, include: ["*.tmp", "/app.d"], exclude: ["*.d", "*.md"]);
    assert(!r.hasError, r.hasError ? r.error : "");
    assert(r.value.files == [".gitignore", "app.d", "scratch.tmp"], r.value.files.text);

    // An include glob anchored to `sub` reaches into an excluded directory
    // (forced entry, FSA5), and never into `.git`.
    auto forced = listRepository(sub, include: ["/build/**", "config"]);
    assert(forced.value.files == [".gitignore", "app.d", "build/out.d", "deep/more.md",
        "notes.md"], forced.value.files.text);
    auto atTop = listRepository(tmp.dir, include: ["config"]);
    assert(atTop.value.files.length == 6, atTop.value.files.text);

    assert(listRepository(sub, include: ["a/../b"]).hasError);
}

/// The same precedence, one path at a time.
@("fileset.listing.GlobFilter")
@safe unittest
{
    auto none = GlobFilter.make(null, null);
    assert(!none.hasError && none.value.passes("src/app.d"));

    auto f = GlobFilter.make(["app.d"], ["*.d", "/docs/**"]);
    assert(f.value.passes("src/app.d"), "an include wins over an exclude");
    assert(!f.value.passes("src/main.d"));
    assert(!f.value.passes("docs/a.md"));
    assert(f.value.passes("src/docs/a.md"), "an anchored glob is anchored");
    assert(f.value.passes("notes.md"));

    assert(GlobFilter.make(["[unclosed"], null).hasError);
}

/// Called from a fiber of a running scheduler, as a UI loop calls it, a
/// listing runs on that scheduler and gives the same files.
@("fileset.listing.listRepository.onScheduler")
@system unittest
{
    import sparkles.event_horizon.sched : Sched;
    import sparkles.test_runner.skip : skipTest;

    auto tmp = workTreeFixture();
    const alone = listRepository(tmp.dir).value.files;
    Sched s;
    if (Sched.create(s).hasError)
        return skipTest("no event loop on this host");
    string[] within;
    assert(!s.run(() { within = listRepository(tmp.dir).value.files; }).hasError);
    assert(within == alone, within.text);
}

/// Any fileset beneath a directory: the files a `.gitignore` excludes, its
/// own and the repository's above it. A directory whose name holds glob
/// characters is listed literally.
@("fileset.listing.listRepository.anyFileset")
@system unittest
{
    import std.path : buildPath;

    auto tmp = workTreeFixture();
    const sub = buildPath(tmp.dir, "sub");
    auto ignored = listRepository(sub, (ref Filesets s) @safe
        => s.difference(s.gitignored, s.glob("/.git").value));
    assert(ignored.value.files == ["build/out.d", "local.d", "scratch.tmp"],
        ignored.value.files.text);

    tmp.writeFileAt("odd[1]/x.d", "x");
    tmp.writeFileAt("odd1/y.d", "x");
    assert(listRepository(buildPath(tmp.dir, "odd[1]")).value.files == ["x.d"]);
    assert(escapeGlob("a*b[c]!") == `a\*b\[c\]\!`);

    // A directory two levels down: its base has a separator inside.
    assert(listRepository(buildPath(tmp.dir, "sub", "deep")).value.files == ["more.md"]);
}

/// A listing is byte-exact (invariant 5): a sibling whose name equals the
/// directory's only under NFC, `Keep` (KELVIN SIGN) beside `Keep`, or
/// an NFD `café` beside an NFC one, is not listed with it.
@("fileset.listing.listRepository.byteExact")
@system unittest
{
    import std.file : exists;
    import std.path : buildPath;

    import sparkles.test_runner.skip : skipTest;

    auto tmp = workTreeFixture();
    tmp.writeFileAt("Keep/a", "x");
    tmp.writeFileAt("Keep/x", "x");
    tmp.writeFileAt("café/n", "x");
    tmp.writeFileAt("café/d", "x");
    // A filesystem that folds case or normalization (macOS's APFS) holds
    // each pair as one directory, so there is nothing to tell apart.
    if (exists(buildPath(tmp.dir, "Keep", "x")) || exists(buildPath(tmp.dir, "café", "d")))
        skipTest("the filesystem folds case or normalization");
    assert(listRepository(buildPath(tmp.dir, "Keep")).value.files == ["a"]);
    assert(listRepository(buildPath(tmp.dir, "Keep")).value.files == ["x"]);
    assert(listRepository(buildPath(tmp.dir, "café")).value.files == ["n"]);
    assert(listRepository(buildPath(tmp.dir, "café")).value.files == ["d"]);
}

/// The directories a listing found nothing selected in, relative to the
/// directory listed.
@("fileset.listing.emptyDirs")
@system unittest
{
    import std.file : mkdirRecurse;
    import std.path : buildPath;

    auto tmp = workTreeFixture();
    mkdirRecurse(buildPath(tmp.dir, "sub/empty"));
    mkdirRecurse(buildPath(tmp.dir, "sub/hollow/inner"));
    auto l = listRepository(buildPath(tmp.dir, "sub"));
    assert(l.value.emptyDirs == ["empty", "hollow/inner"], l.value.emptyDirs.text);
}

/// A link to a directory lists the directory it names, beneath the
/// `.gitignore` files above that one, whether the link lies inside the
/// repository or outside any.
@("fileset.listing.listRepository.linkedDirectory")
@system unittest
{
    import std.path : buildPath;
    import sparkles.test_utils.tmpfs : TmpFS;

    version (Posix)
    {
        import std.file : symlink;

        auto tmp = workTreeFixture();
        symlink(buildPath(tmp.dir, "sub"), buildPath(tmp.dir, "link"));
        auto inside = listRepository(buildPath(tmp.dir, "link"));
        assert(!inside.hasError, inside.hasError ? inside.error : "");
        assert(inside.value.files == [".gitignore", "app.d", "deep/more.md", "notes.md"],
            inside.value.files.text);

        auto outside = TmpFS.create();
        symlink(buildPath(tmp.dir, "sub", "deep"), buildPath(outside.dir, "deep"));
        assert(listRepository(buildPath(outside.dir, "deep")).value.files == ["more.md"]);
    }
}

/// A directory the listing cannot read is an error, not an empty listing.
@("fileset.listing.listRepository.unreadableDirectory")
@system unittest
{
    import std.file : getAttributes, setAttributes;
    import std.path : buildPath;
    import sparkles.test_runner.skip : skipTest;

    version (Posix)
    {
        import core.sys.posix.unistd : geteuid;

        if (geteuid() == 0)
            return skipTest("root reads a directory whatever its mode");
        auto tmp = workTreeFixture();
        const sub = buildPath(tmp.dir, "sub");
        const mode = getAttributes(sub);
        setAttributes(sub, 0);
        scope (exit)
            setAttributes(sub, mode);
        auto listed = listRepository(sub);
        assert(listed.hasError, listed.hasError ? "" : listed.value.text);
    }
}
