/++
The history of run records on `refs/perf/data` (observability §12, the slice
OD21 names): a signed append, and a reader that trusts only signed commits.

The ref is a chain of commits with no common ancestor with `main`. Each holds
`runs/<yyyy>/<mm>/<dd>/<commit12>-<run id>/`, one run record each (OBH1). An
appender builds the new tree with `git mktree` from the tip's tree, through no
index and no working tree, signs the commit, and pushes it without force,
retrying on a rejected push (OBH3). Every commit carries the fixed identity
`perf-data <perf-data@users.noreply.invalid>` (OBH6), and readers believe only
the runs added by a commit signed with a key that `nix/perf-data-signers`
lists (OBH8).

Readers go through a bare partial clone in `$XDG_CACHE_HOME/sparkles/perf/`
that fetches only the ref, without blobs, and fetches the blobs a command reads
in one batch (OBH9). When the remote cannot be reached, the cached clone is
used and its age reported (OBH10).
+/
module perf_history;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join, split;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment, execute, Config;
import std.string : indexOf, lineSplitter, strip;

import sparkles.base.expected : Expected, err, ok;
import sparkles.build_primitives.git_env : gitChildEnvironment;

import perf_record : isRunId, privacyRejection, Producer, recordSchema, recordVersion;

/// The ref the history lives on.
enum historyRef = "refs/perf/data";
/// The repository `ci perf` reads the history from, unless overridden.
enum canonicalRemote = "https://github.com/PetarKirov/sparkles.git";
/// Every commit's author and committer (OBH6).
enum historyName = "perf-data";
/// ditto
enum historyEmail = "perf-data@users.noreply.invalid";
/// A record's size bound, uncompressed (OBD10).
enum size_t recordSizeBound = 4 << 20;
/// At most this many records per job (OBH5).
enum uint recordsPerJob = 4;

/// The result of one git command: its status and standard output.
struct GitResult
{
    int status;
    string output;
    bool ok() const @safe pure nothrow @nogc => status == 0;
}

/**
Run git on the repository at `gitDir`, with the caller's environment minus
any inherited repository location (`gitChildEnvironment`), plus `extraEnv`.
Standard error passes through; `input`, when given, is written to stdin.
*/
GitResult git(string gitDir, string[] args, string[string] extraEnv = null, string input = null) @trusted
{
    import std.process : pipeProcess, Redirect, wait;
    import std.array : appender;

    auto env = gitChildEnvironment();
    foreach (k, v; extraEnv)
        env[k] = v;
    auto argv = ["git", "--git-dir", gitDir] ~ args;
    if (input is null)
    {
        const r = execute(argv, env, Config.newEnv | Config.stderrPassThrough);
        return GitResult(r.status, r.output);
    }
    auto p = pipeProcess(argv, Redirect.stdin | Redirect.stdout, env, Config.newEnv);
    p.stdin.write(input);
    p.stdin.close();
    auto out_ = appender!string;
    foreach (chunk; p.stdout.byChunk(64 * 1024))
        out_.put(cast(const(char)[]) chunk);
    return GitResult(wait(p.pid), out_.data);
}

/// The environment that gives a commit the fixed identity.
string[string] identityEnv() @safe pure nothrow => [
    "GIT_AUTHOR_NAME": historyName, "GIT_AUTHOR_EMAIL": historyEmail,
    "GIT_COMMITTER_NAME": historyName, "GIT_COMMITTER_EMAIL": historyEmail,
];

// ── reading ───────────────────────────────────────────────────────────────

/// A local view of the history: a bare repository and the signers it trusts.
struct History
{
    string gitDir;
    string signersFile;
    string[] degradations; /// What the reader could not do, such as fetching.
    bool unreachable; /// The remote did not answer; the history is the cached one, if any.
}

/// The cached partial clone of `remote` (OBH9): `cache.git` for Sparkles' own
/// history, and one clone per other remote, so that a ref cached from one
/// remote is never read, or appended to, as another's.
string historyCacheDir(string remote = canonicalRemote) @safe
{
    import std.path : expandTilde;
    import perf_record : sha256Hex;

    const cache = environment.get("XDG_CACHE_HOME", expandTilde("~/.cache"));
    const name = remote == canonicalRemote ? "cache.git" : "cache-" ~ sha256Hex(remote)[0 .. 12] ~ ".git";
    return buildPath(cache, "sparkles", "perf", name);
}

/// What fetching the ref found.
private enum Sync : ubyte
{
    fetched, /// The remote has the ref, and the clone now has its tip.
    absent, /// The remote has no history: the clone's ref, if any, is removed.
    unreachable, /// The remote did not answer.
}

/// Ask the remote whether it has the ref before fetching it, so that a remote
/// with no history is told apart from one that cannot be reached.
private Sync syncRef(string gitDir) @trusted
{
    const listed = git(gitDir, ["ls-remote", "origin", historyRef]);
    if (!listed.ok)
        return Sync.unreachable;
    if (listed.output.strip.length == 0)
    {
        git(gitDir, ["update-ref", "-d", historyRef]);
        return Sync.absent;
    }
    const fetched = git(gitDir, ["fetch", "--quiet", "--no-tags", "--filter=blob:none", "origin",
        "+" ~ historyRef ~ ":" ~ historyRef]);
    return fetched.ok ? Sync.fetched : Sync.unreachable;
}

/**
Open the history at `gitDir`, creating a bare repository there on first use,
and fetch `refs/perf/data` from `remote` without blobs. A failed fetch is a
degradation when a cached ref exists, and an error when none does.
*/
Expected!(History, string) openHistory(string gitDir, string remote, string signersFile) @trusted
{
    import std.file : exists, mkdirRecurse;

    if (!exists(gitDir))
    {
        mkdirRecurse(gitDir);
        if (!git(gitDir, ["init", "--quiet", "--bare"]).ok)
            return err!History("cannot create the history cache at " ~ gitDir);
    }
    git(gitDir, ["config", "remote.origin.url", remote]);
    git(gitDir, ["config", "remote.origin.promisor", "true"]);
    git(gitDir, ["config", "remote.origin.partialclonefilter", "blob:none"]);
    History h = History(gitDir, signersFile);
    final switch (syncRef(gitDir))
    {
        case Sync.fetched:
            break;
        case Sync.absent:
            h.degradations ~= "no " ~ historyRef ~ " at " ~ remote;
            break;
        case Sync.unreachable:
            h.unreachable = true;
            if (!git(gitDir, ["rev-parse", "--verify", "--quiet", historyRef]).ok)
                h.degradations ~= "cannot reach " ~ remote ~ ", and no cached " ~ historyRef;
            else
                h.degradations ~= "cannot reach " ~ remote ~ "; using the cached history, last appended "
                    ~ git(gitDir, ["log", "-1", "--format=%cr", historyRef]).output.strip;
            break;
    }
    return ok(h);
}

/// Whether the history has a tip at all.
bool hasTip(in History h) @trusted => git(h.gitDir, ["rev-parse", "--verify", "--quiet", historyRef]).ok;

/**
The commit of the ref to read: `requested` when given (the planning job's
`--history-tip`), otherwise the newest commit whose committer time is not
later than `notAfterUnix`, so every shard of a run agrees (CIC14). Null when
the history has no such commit.
*/
string historyTip(in History h, string requested, long notAfterUnix) @trusted
{
    if (requested.length)
    {
        const r = git(h.gitDir, ["rev-parse", "--verify", "--quiet", requested ~ "^{commit}"]);
        return r.ok ? r.output.strip : null;
    }
    if (!hasTip(h))
        return null;
    const r = git(h.gitDir, ["rev-list", "-1", "--before=" ~ notAfterUnix.to!string, historyRef]);
    return r.ok && r.output.strip.length ? r.output.strip : null;
}

/// One commit of the history and whether a listed key signed it.
struct HistoryCommit
{
    string id;
    bool trusted;
}

/// The commits of `tip`'s history, newest first, each with its signature's
/// verdict against the allowed signers (OBH8): `G` is trusted, anything else not.
HistoryCommit[] historyCommits(in History h, string tip) @trusted
{
    const r = git(h.gitDir, ["-c", "gpg.ssh.allowedSignersFile=" ~ h.signersFile, "log", "--format=%H %G?", tip]);
    HistoryCommit[] commits;
    if (!r.ok)
        return commits;
    foreach (line; r.output.lineSplitter)
    {
        const parts = line.strip.split(" ");
        if (parts.length == 2)
            commits ~= HistoryCommit(parts[0], parts[1] == "G");
    }
    return commits;
}

/// A run directory of the history and the commit that added it.
struct HistoryRun
{
    string dir; /// `runs/<yyyy>/<mm>/<dd>/<commit12>-<run id>`
    string commit;
}

/**
The run directories that trusted commits of `tip` added, newest first.
Runs a commit with a missing or unlisted signature added are left out, and
each such commit is reported in `ignored`.
*/
HistoryRun[] trustedRuns(in History h, string tip, out string[] ignored) @trusted
{
    const commits = historyCommits(h, tip);
    bool[string] trust;
    foreach (c; commits)
        trust[c.id] = c.trusted;

    const r = git(h.gitDir, ["log", "--format=commit %H", "--name-only", "--diff-filter=A", "--no-renames",
        tip, "--", "runs"]);
    HistoryRun[] runs;
    bool[string] seen;
    string current;
    foreach (line; r.output.lineSplitter)
    {
        if (line.startsWith("commit "))
        {
            current = line["commit ".length .. $].strip;
            if (!trust.get(current, false) && !ignored.canFind(current))
                ignored ~= current;
            continue;
        }
        const parts = line.strip.split("/");
        if (parts.length < 6 || parts[0] != "runs")
            continue;
        const dir = parts[0 .. 5].join("/");
        if (dir in seen || !trust.get(current, false))
            continue;
        seen[dir] = true;
        runs ~= HistoryRun(dir, current);
    }
    return runs;
}

/// Read `paths` of `tip`'s tree, fetching their missing blobs in one batch.
string[string] readFiles(in History h, string tip, in string[] paths) @trusted
{
    string[string] files;
    if (paths.length == 0)
        return files;
    // Blob ids from the trees, which the partial clone holds; no blob is read.
    string[string] oidOf;
    foreach (line; git(h.gitDir, ["ls-tree", "-r", tip, "--"] ~ paths.dup).output.lineSplitter)
    {
        const tab = line.indexOf('\t');
        const meta = tab > 0 ? line[0 .. tab].split(" ") : null;
        if (meta.length == 3 && meta[1] == "blob")
            oidOf[line[tab + 1 .. $].idup] = meta[2].idup;
    }
    if (oidOf.length == 0)
        return files;
    // Which the clone lacks, asked without fetching; then one fetch for them all.
    string ask;
    foreach (oid; oidOf)
        ask ~= oid ~ "\n";
    string[] missing;
    foreach (line; git(h.gitDir, ["cat-file", "--batch-check"], ["GIT_NO_LAZY_FETCH": "1"], ask).output.lineSplitter)
        if (line.endsWith(" missing"))
            missing ~= line[0 .. $ - " missing".length].idup;
    if (missing.length)
        git(h.gitDir, ["-c", "fetch.negotiationAlgorithm=noop", "fetch", "--quiet", "--no-tags",
            "--filter=blob:none", "origin"] ~ missing);
    // Every blob in one process: `<oid> blob <size>\n<content>\n` each.
    const batch = git(h.gitDir, ["cat-file", "--batch"], ["GIT_NO_LAZY_FETCH": "1"], ask).output;
    string[string] contentOf;
    size_t at;
    while (at < batch.length)
    {
        const eol = batch[at .. $].indexOf('\n');
        if (eol < 0)
            break;
        const header = batch[at .. at + eol].split(" ");
        at += eol + 1;
        if (header.length != 3 || header[1] != "blob")
            continue;
        const size = header[2].to!size_t;
        if (at + size > batch.length)
            break;
        contentOf[header[0]] = batch[at .. at + size];
        at += size + 1;
    }
    foreach (path, oid; oidOf)
        if (auto c = oid in contentOf)
            files[path] = *c;
    return files;
}

/// The files under `dir` in `tip`'s tree.
string[] listFiles(in History h, string tip, string dir) @trusted
{
    const r = git(h.gitDir, ["ls-tree", "-r", "--name-only", tip, "--", dir]);
    return r.ok ? r.output.lineSplitter.map!(l => l.strip.idup).filter!(l => l.length > 0).array : null;
}

/**
The wall times the trusted records of `placement` hold, newest record first,
reading at most `maxRecords` of them: per record, a map from task id to
`task.wall` in nanoseconds. A record of another schema or version is skipped.
*/
ulong[string][] placementWallTimes(in History h, string tip, string placement, uint maxRecords,
    out string[] ignoredCommits) @trusted
{
    // Two batched fetches: every candidate run.json, then the task files of
    // the records that match (OBH9). The newest runs are the candidates.
    enum candidates = 400;
    auto runs = trustedRuns(h, tip, ignoredCommits);
    if (runs.length > candidates)
        runs = runs[0 .. candidates];
    const heads = readFiles(h, tip, runs.map!(r => r.dir ~ "/run.json").array);
    string[] chosen;
    foreach (run; runs)
    {
        if (chosen.length >= maxRecords)
            break;
        const runJson = heads.get(run.dir ~ "/run.json", null);
        if (runJson !is null && recordMatches(runJson, placement))
            chosen ~= run.dir;
    }
    string[] taskPaths;
    foreach (dir; chosen)
        taskPaths ~= listFiles(h, tip, dir ~ "/tasks");
    const contents = readFiles(h, tip, taskPaths);
    ulong[string][] records;
    foreach (dir; chosen)
    {
        ulong[string] walls;
        foreach (path, content; contents)
            if (path.startsWith(dir ~ "/"))
                foreach (id, wall; taskWalls(content))
                    walls[id] = wall;
        if (walls.length)
            records ~= walls;
    }
    return records;
}

/// Whether `run.json` is a readable record (OBD6) of `placement`.
bool recordMatches(string runJson, string placement) @safe
{
    try
    {
        auto v = parseJSON(runJson);
        if ("schema" !in v || v["schema"].str != recordSchema || "version" !in v)
            return false;
        const ver = v["version"].integer;
        if (ver != recordVersion && ver != recordVersion - 1)
            return false;
        return "invocation" in v && "placement" in v["invocation"]
            && v["invocation"]["placement"].str == placement;
    }
    catch (Exception)
        return false;
}

/// The `task.wall` of each task in a `tasks/<s>.json`.
ulong[string] taskWalls(string content) @safe
{
    ulong[string] walls;
    try
    {
        auto v = parseJSON(content);
        foreach (t; (() @trusted => v["tasks"].array)())
            if ("id" in t && "metrics" in t && "task.wall" in t["metrics"])
                walls[t["id"].str] = cast(ulong) t["metrics"]["task.wall"].integer;
    }
    catch (Exception)
    {
    }
    return walls;
}

// ── validation ────────────────────────────────────────────────────────────

/// A record directory to append, its files by path relative to it.
struct RecordFiles
{
    string runId; /// From the directory name; checked against `run.json`.
    string[string] files;
}

/**
Validate a record before appending it (OBH5): the run identifier's syntax and
agreement with `run.json`, its prefix when the appender knows the run it
appends (`gh-<run id>-<attempt>-`), the schema and version, the size bound,
and the privacy scan's first rule. Returns why it is dropped, or null.
*/
string validateRecord(in RecordFiles r, string expectedPrefix) @safe
{
    if (!isRunId(r.runId))
        return "the run identifier " ~ r.runId ~ " is not valid";
    if (expectedPrefix.length && !r.runId.startsWith(expectedPrefix))
        return "the run identifier " ~ r.runId ~ " does not belong to this run";
    if ("run.json" !in r.files)
        return "no run.json";
    size_t total;
    foreach (path, content; r.files)
    {
        total += content.length;
        if (path != "run.json" && !(path.startsWith("tasks/") && path.endsWith(".json")
                && path.length == "tasks/0.json".length && path[6] >= '0' && path[6] <= '7'))
            return "an unexpected file " ~ path;
        if (const why = privacyRejection(content, Producer.init))
            return path ~ " holds " ~ why;
    }
    if (total > recordSizeBound)
        return format("%d bytes, over the %d-byte bound", total, recordSizeBound);
    try
    {
        auto v = parseJSON(r.files["run.json"]);
        if (v["schema"].str != recordSchema || v["version"].integer != recordVersion)
            return "not a version " ~ recordVersion.to!string ~ " " ~ recordSchema ~ " record";
        if (v["run"].str != r.runId)
            return "run.json names another run";
    }
    catch (Exception e)
        return "run.json is not a record: " ~ e.msg;
    return null;
}

@("perfHistory.validateRecord.rules")
@safe
unittest
{
    enum good = `{"schema":"sparkles.perf.run","version":1,"run":"gh-7-1-0123456789ab-1","origin":"ci"}`;
    auto r = RecordFiles("gh-7-1-0123456789ab-1", ["run.json": good, "tasks/3.json": `{"tasks":[]}`]);
    assert(validateRecord(r, "gh-7-1-") is null);
    assert(validateRecord(r, "gh-8-1-") !is null, "a record of another run");
    auto bad = RecordFiles("../x", r.files.dup);
    assert(validateRecord(bad, "") !is null);
    auto extra = RecordFiles(r.runId, ["run.json": good, ".github/x": "{}"]);
    assert(validateRecord(extra, "") !is null, "only run.json and tasks/<0-7>.json");
    auto leaky = RecordFiles(r.runId, ["run.json": good, "tasks/0.json": `{"p":"/home/u/x"}`]);
    assert(validateRecord(leaky, "") !is null, "the scan's first rule");
    auto other = RecordFiles("gh-7-1-0123456789ab-2", ["run.json": good]);
    assert(validateRecord(other, "") == "run.json names another run");
}

// ── appending ─────────────────────────────────────────────────────────────

/// One entry of a tree being built: a blob's content, or a subtree.
private struct Node
{
    string blob; /// The blob's id, for a file.
    Node[string] children; /// For a directory.
    bool isTree;
}

/// Write `files` (path → content) into the tree `base` (null for an empty
/// tree), never replacing an existing entry. Returns the new tree's id.
private string insertFiles(string gitDir, string base, in string[string] files) @trusted
{
    Node root;
    root.isTree = true;
    foreach (path, content; files)
    {
        const oid = git(gitDir, ["hash-object", "-w", "--stdin"], null, content).output.strip;
        Node* at = &root;
        const parts = path.split("/");
        foreach (i, part; parts)
        {
            if (i + 1 == parts.length)
            {
                Node leaf;
                leaf.blob = oid;
                at.children[part] = leaf;
            }
            else
            {
                if (part !in at.children)
                {
                    Node dir;
                    dir.isTree = true;
                    at.children[part] = dir;
                }
                at = &at.children[part];
            }
        }
    }
    return writeTree(gitDir, base, root);
}

private string writeTree(string gitDir, string base, ref Node node) @trusted
{
    // The existing entries, by name: `<mode> <type> <oid>\t<name>`.
    string[string] existing;
    if (base.length)
        foreach (line; git(gitDir, ["ls-tree", base]).output.lineSplitter)
        {
            const tab = line.indexOf('\t');
            if (tab > 0)
                existing[line[tab + 1 .. $].idup] = line[0 .. tab].idup;
        }
    foreach (name, ref child; node.children)
    {
        if (child.isTree)
        {
            string sub;
            if (auto e = name in existing)
                sub = (*e).split(" ")[2];
            existing[name] = "040000 tree " ~ writeTree(gitDir, sub, child);
        }
        else if (name !in existing)
            existing[name] = "100644 blob " ~ child.blob;
    }
    string listing;
    foreach (name; existing.keys.sort)
        listing ~= existing[name] ~ "\t" ~ name ~ "\n";
    // `--missing`: a partial clone holds the trees but not the blobs it never
    // read, and the remote has them, so mktree must not ask for them.
    return git(gitDir, ["mktree", "--missing"], null, listing).output.strip;
}

/**
Whether a tree may be committed (OBH2): no `.github/` directory and no
executable file anywhere in it.
*/
bool dataOnly(string gitDir, string tree) @trusted
{
    foreach (line; git(gitDir, ["ls-tree", "-r", "-t", tree]).output.lineSplitter)
    {
        const tab = line.indexOf('\t');
        if (tab < 0)
            continue;
        const path = line[tab + 1 .. $];
        if (line.startsWith("100755") || path == ".github" || path.startsWith(".github/") || path.canFind("/.github"))
            return false;
    }
    return true;
}

/// The README the ref's first commit carries (OBH1).
enum readme = "# refs/perf/data\n\nThe history of Sparkles' build, test and CI run records: data only,"
    ~ " signed by the keys `nix/perf-data-signers` lists on `main`. The schema is"
    ~ " `docs/specs/build-primitives/observability/SPEC.md`, §11 and §12.\n";

/// A record to append, and where in the tree it goes.
struct Append
{
    string dir; /// `runs/<yyyy>/<mm>/<dd>/<commit12>-<run id>`, from trusted identity.
    RecordFiles record;
}

/**
Append `records` to `refs/perf/data` at `remote` (OBH3): fetch and verify the
tip, write the new tree with `git mktree`, skipping a directory that exists,
sign the commit with `signingKey`, push it without force, and on a rejected
push start again, for at most `deadline`. Returns the run directories
appended, or why it could not.
*/
Expected!(string[], string) appendRecords(string gitDir, string remote, string signersFile,
    in Append[] records, string signingKey, string message, uint deadlineSeconds = 600) @trusted
{
    import core.thread : Thread;
    import core.time : MonoTime, msecs;
    import std.random : uniform;

    auto opened = openHistory(gitDir, remote, signersFile);
    if (opened.hasError)
        return err!(string[])(opened.error);
    // An appender builds only on the remote's own tip, never on a cached one (OBH3).
    if (opened.value.unreachable)
        return err!(string[])("cannot reach " ~ remote ~ "; nothing appended");
    const start = MonoTime.currTime;
    uint attempt;
    while (true)
    {
        ++attempt;
        if (attempt > 1 && syncRef(gitDir) == Sync.unreachable)
            return err!(string[])("lost " ~ remote ~ " while retrying; nothing appended");
        string parent, baseTree;
        if (hasTip(opened.value))
        {
            parent = git(gitDir, ["rev-parse", historyRef]).output.strip;
            const commits = historyCommits(opened.value, parent);
            if (commits.length == 0 || !commits[0].trusted)
                return err!(string[])("refusing to append onto " ~ parent
                    ~ ": its signature is missing or from a key the allowed signers do not list");
            baseTree = git(gitDir, ["rev-parse", parent ~ "^{tree}"]).output.strip;
        }

        string[string] files;
        string[] appended;
        if (parent.length == 0)
            files["README.md"] = readme;
        foreach (a; records)
        {
            if (parent.length && git(gitDir, ["rev-parse", "--verify", "--quiet", parent ~ ":" ~ a.dir]).ok)
                continue; // a repeated append is a no-op
            foreach (path, content; a.record.files)
                files[a.dir ~ "/" ~ path] = content;
            appended ~= a.dir;
        }
        if (appended.length == 0)
            return ok(appended);

        const tree = insertFiles(gitDir, baseTree, files);
        if (!dataOnly(gitDir, tree))
            return err!(string[])("refusing a tree that holds .github/ or an executable file");
        auto commitArgs = ["-c", "gpg.format=ssh", "-c", "user.signingKey=" ~ signingKey, "commit-tree", "-S",
            "-m", message];
        if (parent.length)
            commitArgs ~= ["-p", parent];
        const commit = git(gitDir, commitArgs ~ tree, identityEnv());
        if (!commit.ok)
            return err!(string[])("cannot create a signed commit with " ~ signingKey);
        const pushed = git(gitDir, ["push", "--quiet", "origin", commit.output.strip ~ ":" ~ historyRef]);
        if (pushed.ok)
        {
            git(gitDir, ["update-ref", historyRef, commit.output.strip]);
            return ok(appended);
        }
        if ((MonoTime.currTime - start).total!"seconds" > deadlineSeconds)
            return err!(string[])(format("could not push for %d s; not appended: %-(%s, %)", deadlineSeconds,
                appended));
        Thread.sleep(uniform(500, 500 + 1000 * attempt).msecs);
    }
}

@("perfHistory.appendAndRead.localRemote")
@system
unittest
{
    import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
    import std.process : execute;
    import sparkles.test_runner.skip : skipTest;

    if (execute(["ssh-keygen", "-?"]).status == 127 || execute(["git", "--version"]).status != 0)
        skipTest("needs ssh-keygen and git");
    const root = buildPath(tempDir, format("perf-history-%d", MonoTimeNow()));
    mkdirRecurse(root);
    scope (exit)
        rmdirRecurse(root);
    foreach (k; ["good", "evil"])
        assert(execute(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "t", "-f", buildPath(root, k)])
            .status == 0);
    const signers = buildPath(root, "signers");
    write(signers, "ci namespaces=\"git\" " ~ readText(buildPath(root, "good.pub")).split(" ")[0 .. 2].join(" ")
        ~ "\n");
    // A `file://` remote that honours `--filter`, as GitHub does: the clones
    // then hold no blob they did not ask for, and tree building must cope.
    const remoteDir = buildPath(root, "remote.git");
    mkdirRecurse(remoteDir);
    assert(git(remoteDir, ["init", "--quiet", "--bare"]).ok);
    assert(git(remoteDir, ["config", "uploadpack.allowFilter", "true"]).ok);
    const remote = "file://" ~ remoteDir;

    enum run = `{"schema":"sparkles.perf.run","version":1,"run":"%s","origin":"ci",`
        ~ `"invocation":{"command":"--test","options":[],"placement":"%s"}}`;
    Append rec(string id, string placement, ulong wall) => Append("runs/2026/11/17/0123456789ab-" ~ id,
        RecordFiles(id, ["run.json": format(run, id, placement),
            "tasks/0.json": format(`{"tasks":[{"id":"test:base:unittest:serial","metrics":{"task.wall":%d}}]}`,
                wall)]));

    const appender = buildPath(root, "appender.git");
    const first = appendRecords(appender, remote, signers, [rec("gh-1-1-0123456789ab-1", "p", 10)],
        buildPath(root, "good"), "append runs of gh-1");
    assert(first.hasValue && first.value.length == 1, first.hasError ? first.error : "");
    const again = appendRecords(appender, remote, signers, [rec("gh-1-1-0123456789ab-1", "p", 10)],
        buildPath(root, "good"), "append runs of gh-1");
    assert(again.hasValue && again.value.length == 0, "a repeated append is a no-op");
    assert(appendRecords(appender, remote, signers, [rec("gh-2-1-0123456789ab-1", "p", 20),
        rec("gh-2-1-0123456789ab-2", "q", 99)], buildPath(root, "good"), "append runs of gh-2").hasValue);

    // Someone with push access, and no listed key, appends a commit of their own.
    const forger = openHistory(buildPath(root, "forger.git"), remote, signers).value.gitDir;
    const parent = git(forger, ["rev-parse", historyRef]).output.strip;
    enum forgedDir = "runs/2026/11/17/0123456789ab-gh-3-1-0123456789ab-1/";
    const forgedTree = insertFiles(forger, git(forger, ["rev-parse", parent ~ "^{tree}"]).output.strip, [
        forgedDir ~ "run.json": format(run, "gh-3-1-0123456789ab-1", "p"),
        forgedDir ~ "tasks/0.json": `{"tasks":[{"id":"test:base:unittest:serial","metrics":{"task.wall":1}}]}`,
    ]);
    const forged = git(forger, ["-c", "gpg.format=ssh", "-c", "user.signingKey=" ~ buildPath(root, "evil"),
        "commit-tree", "-S", "-m", "forged", "-p", parent, forgedTree], identityEnv()).output.strip;
    assert(git(forger, ["push", "--quiet", "origin", forged ~ ":" ~ historyRef]).ok);
    // Readers ignore its runs, and appenders refuse to build on it.

    auto h = openHistory(buildPath(root, "reader.git"), remote, signers).value;
    const tip = historyTip(h, null, long.max);
    string[] ignored;
    const walls = placementWallTimes(h, tip, "p", 10, ignored);
    assert(walls.length == 2 && walls[0]["test:base:unittest:serial"] == 20
        && walls[1]["test:base:unittest:serial"] == 10, "newest first, placement q left out");
    assert(ignored.length == 1, "the forged commit is reported");
    const refused = appendRecords(appender, remote, signers, [rec("gh-4-1-0123456789ab-1", "p", 5)],
        buildPath(root, "good"), "after the forgery");
    assert(refused.hasError, "an appender refuses an unverified tip");

    const author = git(h.gitDir, ["log", "-1", "--format=%an <%ae> %cn <%ce>", tip]).output.strip;
    assert(author == "perf-data <perf-data@users.noreply.invalid> perf-data <perf-data@users.noreply.invalid>");

    // A clone that cached one remote's ref, appending to another remote with no
    // history, starts that remote's history afresh rather than building on the
    // cached tip (whose blobs the new remote cannot serve).
    const fresh = buildPath(root, "fresh.git");
    mkdirRecurse(fresh);
    assert(git(fresh, ["init", "--quiet", "--bare"]).ok);
    const moved = appendRecords(appender, fresh, signers, [rec("gh-5-1-0123456789ab-1", "p", 7)],
        buildPath(root, "good"), "a new remote");
    assert(moved.hasValue && moved.value.length == 1, moved.hasError ? moved.error : "");
    assert(git(fresh, ["rev-list", "--count", historyRef]).output.strip == "1", "a root commit");
    assert(git(fresh, ["cat-file", "-e", historyRef ~ ":README.md"]).ok);

    // An unreachable remote: the appender refuses instead of using its cache.
    const gone = appendRecords(appender, buildPath(root, "missing.git"), signers,
        [rec("gh-6-1-0123456789ab-1", "p", 7)], buildPath(root, "good"), "nowhere");
    assert(gone.hasError && gone.error.canFind("cannot reach"));
}

private long MonoTimeNow() @safe nothrow
{
    import core.time : MonoTime;

    return MonoTime.currTime.ticks;
}
