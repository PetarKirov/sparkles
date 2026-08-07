// Git status for the explorer (`XPF1`): one `git status --porcelain -z
// --ignored=matching` per repo root, parsed into a path → status map with
// worst-status-wins ancestor propagation (ignored deliberately NOT
// propagated) and whole-untracked/ignored-dir inheritance — so a dir shows
// its subtree's worst change without the explorer listing the subtree.
//
// The cache half runs the git call **async** (a worker thread per refresh)
// with a TTL and a generation guard: a stale in-flight result never clobbers
// a newer request's. Pure parsing and propagation are unit-tested without
// git; the cache test uses a real temp repository (skipped when git is
// unavailable).
module git_status;

import core.time : Duration, MonoTime, seconds;
import std.parallelism : task, Task;
import std.path : absolutePath, buildNormalizedPath;

/// A path's git state, ordered by severity — `worst` is `max`. `ignored`
/// sits below `untracked` and is never propagated to ancestors.
enum GitStatus : ubyte
{
    none,
    ignored,
    untracked,
    added,
    renamed,
    modified,
    deleted,
    conflict,
}

/// The porcelain `XY` code pair as a severity-ordered status.
GitStatus classify(char x, char y) @safe pure nothrow @nogc
{
    if (x == '?')
        return GitStatus.untracked;
    if (x == '!')
        return GitStatus.ignored;
    if (x == 'U' || y == 'U' || (x == 'D' && y == 'D')
        || (x == 'A' && y == 'A'))
        return GitStatus.conflict;
    if (x == 'D' || y == 'D')
        return GitStatus.deleted;
    if (x == 'R' || y == 'R' || x == 'C')
        return GitStatus.renamed;
    if (x == 'M' || y == 'M' || x == 'T' || y == 'T')
        return GitStatus.modified;
    if (x == 'A')
        return GitStatus.added;
    return GitStatus.none;
}

/// The parsed status of one repository snapshot, queryable by absolute path.
struct GitStatusMap
{
    /// Explicit porcelain entries: repo-relative path (dir entries without
    /// their trailing slash) → status.
    GitStatus[string] entries;
    /// Worst non-ignored descendant status per ancestor dir (repo-relative).
    GitStatus[string] dirWorst;
    string toplevel; /// absolute repo root ("" ⇒ not a repository)
    bool present;    /// a successful status result is loaded

    /// The status of `path` (absolute or cwd-relative). Files inherit a
    /// listed whole-dir status (`?? dir/` / `!! dir/`) from their nearest
    /// listed ancestor; a dir additionally reports its subtree's worst
    /// non-ignored status (worst-wins propagation).
    GitStatus statusOf(scope const(char)[] path, bool isDir) const @safe
    {
        const rel = relOf(path);
        if (rel is null)
            return GitStatus.none;
        GitStatus st;
        if (const p = rel in entries)
            st = *p;
        else
            // Inherited: contents of a listed whole-untracked/ignored dir.
            for (auto anc = parentOf(rel); anc.length; anc = parentOf(anc))
                if (const p = anc in entries)
                {
                    if (*p == GitStatus.untracked || *p == GitStatus.ignored)
                        st = *p;
                    break;
                }
        if (isDir)
            if (const q = rel in dirWorst)
                st = *q > st ? *q : st;
        return st;
    }

    // The repo-relative form of `path`, or null when outside the repo (an
    // empty relative path — the toplevel itself — is "", which is not null).
    private const(char)[] relOf(scope const(char)[] path) const @safe
    {
        if (!toplevel.length)
            return null;
        const abs = buildNormalizedPath(absolutePath(path.idup));
        if (abs == toplevel)
            return "";
        const prefix = toplevel ~ "/";
        if (abs.length > prefix.length && abs[0 .. prefix.length] == prefix)
            return abs[prefix.length .. $];
        // The toplevel from `git rev-parse` is symlink-resolved while the
        // caller's spelling may not be (macOS: `/var/folders/…` vs
        // `/private/var/…`) — retry with the path resolved. Lazy: this
        // branch is never reached when the spellings already agree.
        const real_ = realPathOf(abs);
        if (real_.length)
        {
            if (real_ == toplevel)
                return "";
            if (real_.length > prefix.length
                && real_[0 .. prefix.length] == prefix)
                return real_[prefix.length .. $];
        }
        return null;
    }

    // `realpath(3)` (symlinks resolved; the file must exist), or null.
    private static string realPathOf(scope const(char)[] p) @trusted
    {
        version (Posix)
        {
            import core.stdc.string : strlen;
            import core.sys.posix.stdlib : free, realpath;
            import std.string : toStringz;

            auto r = realpath(p.toStringz, null);
            if (r is null)
                return null;
            scope (exit) free(r);
            return r[0 .. strlen(r)].idup;
        }
        else
            return null;
    }

    private static const(char)[] parentOf(scope return const(char)[] rel)
        @safe pure nothrow @nogc
    {
        foreach_reverse (i, ch; rel)
            if (ch == '/')
                return rel[0 .. i];
        return null;
    }
}

/**
Parses `git status --porcelain -z --ignored=matching` output (NUL-terminated
entries; a rename/copy carries a second NUL-terminated "from" path) into a
$(LREF GitStatusMap), propagating each non-ignored entry's status to its
ancestor dirs by worst-wins.
*/
GitStatusMap parsePorcelainZ(scope const(char)[] payload, string toplevel)
    @safe
{
    GitStatusMap m;
    m.toplevel = toplevel;
    m.present = true;

    size_t i = 0;
    while (i + 3 <= payload.length)
    {
        const x = payload[i];
        const y = payload[i + 1];
        i += 3; // "XY "
        const start = i;
        while (i < payload.length && payload[i] != '\0')
            ++i;
        auto path = payload[start .. i].idup;
        if (i < payload.length)
            ++i; // the NUL
        if (x == 'R' || x == 'C') // skip the rename/copy "from" path
        {
            while (i < payload.length && payload[i] != '\0')
                ++i;
            if (i < payload.length)
                ++i;
        }
        if (path.length && path[$ - 1] == '/') // a whole-dir entry
            path = path[0 .. $ - 1];
        const st = classify(x, y);
        if (st == GitStatus.none || !path.length)
            continue;
        if (const existing = path in m.entries)
            m.entries[path] = *existing > st ? *existing : st;
        else
            m.entries[path] = st;
        if (st != GitStatus.ignored) // ignored is never propagated
            for (auto anc = GitStatusMap.parentOf(path); anc.length;
                anc = GitStatusMap.parentOf(anc))
            {
                const key = anc.idup;
                if (const existing = key in m.dirWorst)
                    m.dirWorst[key] = *existing > st ? *existing : st;
                else
                    m.dirWorst[key] = st;
            }
    }
    return m;
}

/// One worker-thread refresh: resolve the toplevel, run the status call.
/// `gen` rides along so the cache can discard a stale in-flight result.
private struct StatusResult
{
    uint gen;
    bool ok;
    string toplevel;
    string payload;
}

private StatusResult runGitStatus(string root, uint gen)
{
    import std.process : execute;
    import std.string : strip;

    try
    {
        const top = execute(["git", "-C", root, "rev-parse",
            "--show-toplevel"]);
        if (top.status != 0)
            return StatusResult(gen, false);
        const st = execute(["git", "-C", root, "status", "--porcelain",
            "-z", "--ignored=matching"]);
        if (st.status != 0)
            return StatusResult(gen, false);
        return StatusResult(gen, true, top.output.strip, st.output);
    }
    catch (Exception) // git missing entirely
        return StatusResult(gen, false);
}

/**
The async status cache: $(LREF ensureFresh) kicks a refresh when the TTL has
lapsed (one worker thread, one git process), $(LREF poll) harvests a finished
one, and $(LREF force) invalidates immediately (the manual-refresh key). The
generation guard makes a `force` during an in-flight refresh discard that
refresh's result rather than letting stale data clobber the newer request.
*/
struct GitStatusCache
{
    string root;             /// the explorer root (any dir inside the repo)
    GitStatusMap map;
    Duration ttl = 5.seconds;

    /**
    The async driver seam (M17): when installed, a refresh is handed to this
    delegate instead of a worker thread — the event-horizon arm points it at
    a fiber that runs the git calls as spawned children (`capture`) and hands
    the outcome back through $(LREF deliver) with the same `gen` it was
    given. The loop can then drop its refresh-polling deadline cap: delivery
    is an event, not something to poll for ($(LREF asyncMode)).
    */
    void delegate(string root, uint gen) asyncSpawn;

    private Task!(runGitStatus, string, uint)* inFlight;
    private uint gen;
    private bool pendingForce;
    private MonoTime last;
    private bool haveLast;
    private bool asyncInFlight;
    private StatusResult asyncDone;
    private bool asyncReady;

@system:

    /// Installs `m` as the current result and marks the cache FRESH, so
    /// `ensureFresh` won't kick an async refresh for a TTL — the seeding
    /// seam deterministic tests need (a hand-seeded map must not race a
    /// late-landing worker under load).
    void seed(GitStatusMap m)
    {
        map = m;
        last = MonoTime.currTime;
        haveLast = true;
    }

    /// True while a refresh is in flight (the host may idle-tick on it).
    bool refreshing() const pure nothrow @nogc
        => inFlight !is null || asyncInFlight;

    /// True when refreshes go through $(LREF asyncSpawn) — completion is
    /// then delivered (and the loop woken) rather than polled for, so a
    /// host needs no refresh-bounded wait deadline.
    bool asyncMode() const pure nothrow @nogc => asyncSpawn !is null;

    /// The async driver's completion entry: the counterpart of the worker
    /// thread finishing. `gen` is the value `asyncSpawn` was handed; a stale
    /// generation is discarded by the next `poll` exactly like a stale
    /// thread result.
    void deliver(uint resultGen, bool ok, string toplevel, string payload)
        pure nothrow
    {
        asyncInFlight = false;
        asyncDone = StatusResult(resultGen, ok, toplevel, payload);
        asyncReady = true;
    }

    /// Starts a refresh if the TTL has lapsed and none is in flight.
    void ensureFresh()
    {
        if (refreshing)
            return;
        if (haveLast && MonoTime.currTime - last < ttl)
            return;
        spawn();
    }

    /// Invalidates now: the next result to apply must come from a refresh
    /// started after this call (the in-flight one, if any, is discarded).
    void force()
    {
        ++gen;
        if (!refreshing)
            spawn();
        else
            pendingForce = true;
    }

    /// Harvests a finished refresh (either driver); returns true when a new
    /// map applied.
    bool poll()
    {
        StatusResult r;
        if (asyncReady)
        {
            r = asyncDone;
            asyncReady = false;
            asyncDone = StatusResult.init;
        }
        else if (inFlight !is null && inFlight.done)
        {
            r = inFlight.yieldForce;
            inFlight = null;
        }
        else
            return false;
        if (pendingForce)
        {
            pendingForce = false;
            spawn();
        }
        if (r.gen != gen)
            return false; // stale: a newer request defines the truth
        last = MonoTime.currTime;
        haveLast = true;
        map = r.ok ? parsePorcelainZ(r.payload, r.toplevel)
            : GitStatusMap.init;
        return true;
    }

    private void spawn()
    {
        if (asyncSpawn !is null)
        {
            asyncInFlight = true;
            asyncSpawn(root, gen);
            return;
        }
        inFlight = task!runGitStatus(root, gen);
        inFlight.executeInNewThread();
    }
}

/// A status badge for a tree row: the conventional letter + color. `ignored`
/// and `none` carry no badge (ignored rows dim their label instead).
struct GitBadge
{
    string letter;
    import sparkles.base.term_color : RgbColor;

    RgbColor fg;
}

/// ditto
GitBadge gitBadge(GitStatus st) @safe pure nothrow @nogc
{
    import sparkles.base.term_color : RgbColor;

    final switch (st)
    {
        case GitStatus.none:
        case GitStatus.ignored:
            return GitBadge("");
        case GitStatus.untracked:
            return GitBadge("?", RgbColor(0x73, 0xc9, 0x91));
        case GitStatus.added:
            return GitBadge("A", RgbColor(0x73, 0xc9, 0x91));
        case GitStatus.renamed:
            return GitBadge("R", RgbColor(0x7a, 0xa2, 0xf7));
        case GitStatus.modified:
            return GitBadge("M", RgbColor(0xe0, 0xaf, 0x68));
        case GitStatus.deleted:
            return GitBadge("D", RgbColor(0xdb, 0x4b, 0x4b));
        case GitStatus.conflict:
            return GitBadge("U", RgbColor(0xbb, 0x9a, 0xf7));
    }
}

@("git_status.classify.severityOrder")
@safe pure nothrow @nogc
unittest
{
    assert(classify('?', '?') == GitStatus.untracked);
    assert(classify('!', '!') == GitStatus.ignored);
    assert(classify('M', ' ') == GitStatus.modified);
    assert(classify(' ', 'M') == GitStatus.modified);
    assert(classify('A', ' ') == GitStatus.added);
    assert(classify('A', 'M') == GitStatus.modified); // worktree edit wins
    assert(classify('R', ' ') == GitStatus.renamed);
    assert(classify('D', ' ') == GitStatus.deleted);
    assert(classify('U', 'U') == GitStatus.conflict);
    assert(classify('D', 'D') == GitStatus.conflict);
    assert(GitStatus.conflict > GitStatus.deleted);
    assert(GitStatus.deleted > GitStatus.modified);
    assert(GitStatus.untracked > GitStatus.ignored);
}

@("git_status.parse.propagationAndInheritance")
@system
unittest
{
    // A modified nested file, an untracked whole dir, an ignored whole dir,
    // and a staged rename (whose "from" path must be skipped).
    const payload = " M src/app.d\0?? new-dir/\0!! build/\0"
        ~ "R  docs/b.md\0docs/a.md\0";
    auto m = parsePorcelainZ(payload, "/repo");

    assert(m.entries["src/app.d"] == GitStatus.modified);
    assert(m.entries["new-dir"] == GitStatus.untracked);
    assert(m.entries["build"] == GitStatus.ignored);
    assert(m.entries["docs/b.md"] == GitStatus.renamed);
    assert("docs/a.md" !in m.entries); // the rename "from" is not an entry

    // Worst-wins propagation to ancestors — but never from ignored.
    assert(m.dirWorst["src"] == GitStatus.modified);
    assert(m.dirWorst["docs"] == GitStatus.renamed);
    assert("build" !in m.dirWorst);

    // Absolute-path queries: files inherit a listed whole-dir status
    // without the dir's contents being listed.
    assert(m.statusOf("/repo/src/app.d", false) == GitStatus.modified);
    assert(m.statusOf("/repo/src", true) == GitStatus.modified);
    assert(m.statusOf("/repo/new-dir/inner.txt", false) == GitStatus.untracked);
    assert(m.statusOf("/repo/build/out.o", false) == GitStatus.ignored);
    assert(m.statusOf("/repo/README.md", false) == GitStatus.none);
    assert(m.statusOf("/elsewhere/x", false) == GitStatus.none);
}

@("git_status.cache.asyncDriverGenerationGuard")
@system
unittest
{
    // The async seam replaces the worker thread entirely: every spawn goes
    // through the delegate, and delivery + the generation guard behave like
    // the thread path's harvest — a stale in-flight result never clobbers a
    // newer request's, and a `force` during flight respawns on harvest.
    GitStatusCache c;
    c.root = "/repo";
    string[] spawns;
    uint[] gens;
    c.asyncSpawn = (string root, uint g) { spawns ~= root; gens ~= g; };

    c.force();
    assert(c.asyncMode && c.refreshing);
    assert(spawns == ["/repo"] && gens.length == 1);

    // A second force while in flight: no respawn yet, just invalidation.
    c.force();
    assert(spawns.length == 1);

    // The first (now stale) refresh delivers: discarded, and the pending
    // force respawns with the current generation.
    c.deliver(gens[0], true, "/repo", " M src/app.d\0");
    assert(!c.poll(), "a stale generation must not apply");
    assert(!c.map.present);
    assert(spawns.length == 2 && gens[1] == gens[0] + 1, "the force respawned");
    assert(c.refreshing);

    // The current generation delivers and applies.
    c.deliver(gens[1], true, "/repo", " M src/app.d\0");
    assert(c.poll());
    assert(c.map.present);
    assert(c.map.statusOf("/repo/src/app.d", false) == GitStatus.modified);
    assert(!c.refreshing);

    // Fresh within the TTL: ensureFresh spawns nothing.
    c.ensureFresh();
    assert(spawns.length == 2);

    // A failed refresh clears the map rather than keeping a stale one.
    c.force();
    c.deliver(gens[2], false, null, null);
    assert(c.poll());
    assert(!c.map.present);
}

@("git_status.cache.ttlGenerationAndRealRepo")
@system
unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import sparkles.test_runner.skip : skipTest;

    // A real throwaway repository (git comes with the dev shell).
    const root = buildPath(tempDir(), "hue-git-status-test");
    if (root.exists)
        rmdirRecurse(root);
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    try
    {
        if (execute(["git", "init", "-q", root]).status != 0)
            skipTest("git init failed");
    }
    catch (Exception)
        skipTest("git not available");
    write(buildPath(root, "fresh.txt"), "hi\n");
    write(buildPath(root, ".gitignore"), "junk/\n");
    mkdirRecurse(buildPath(root, "junk"));
    write(buildPath(root, "junk", "x.o"), "");

    GitStatusCache c;
    c.root = root;
    c.force();
    foreach (_; 0 .. 5000)
    {
        if (c.poll())
            break;
        Thread.sleep(1.msecs);
    }
    assert(c.map.present, "the async refresh completed");
    assert(c.map.statusOf(buildPath(root, "fresh.txt"), false)
        == GitStatus.untracked);
    assert(c.map.statusOf(buildPath(root, "junk"), true)
        == GitStatus.ignored);
    // Within the TTL nothing respawns.
    c.ensureFresh();
    assert(!c.poll());

    // A symlinked spelling of the repo still resolves (macOS: tempDir is
    // `/var/…` while git's toplevel is the resolved `/private/var/…`).
    version (Posix)
    {
        import std.file : symlink;

        const alias_ = root ~ "-alias";
        symlink(root, alias_);
        scope (exit)
        {
            import std.file : remove;

            remove(alias_);
        }
        assert(c.map.statusOf(buildPath(alias_, "fresh.txt"), false)
            == GitStatus.untracked, "symlinked spelling resolves");
    }
}
