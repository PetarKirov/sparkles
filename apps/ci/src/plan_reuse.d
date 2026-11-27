/**
A plan reused while nothing it read has changed (build-graph SPEC BGP2).

Planning records what it read (BGP1): every file with its digest, every
probe, listing and link, every environment variable and `pkg-config` query.
After it plans, `ci` keeps the plan beside the store, under
`<cache>/plans/<request>.json`, with that read set and each file's identity
(device, inode, size, modification and change times), taken on the handle
that read the file again and found the digest planning recorded. The next
run with the same request (the same arguments, tools, toolchain and its
table, `ci` binary and store layout, $(LREF planRequest)) checks the read set
($(LREF reusePlan)) through a fresh tree over the plan's roots, under the
rules planning read by (BGF3), and, when every entry still holds, takes the
plan instead of planning:

$(LIST
    * a file in the Nix store, which still exists, holds: its contents are its
        name's;
    * any other file holds unread when its identity is unchanged, it lies on
        the file system whose clock the plan was made by (a probe file's mtime,
        as BGK5 reads it), neither of its times is within two seconds of that
        clock when planning began, and its change time cannot be set; any other
        is read and its digest compared;
    * a probe, a listing and a link are made again and compared;
    * an environment variable is read and compared, but one a host's entry in
        the toolchain table supplies (its name holds the host, `<host>:NAME`),
        which the request covers through the table's digest;
    * a `pkg-config` query holds as the caller's check says: unasked while the
        program, every directory it searches and every variable it reads are
        covered by the request and lie in the Nix store, else asked again.
)

A lookup the tree refuses, as planning would, plans again. Any doubt plans
again, and the reason is logged at trace level.
*/
module plan_reuse;

import std.algorithm.searching : startsWith;
import std.conv : text, to;

import sparkles.build_graph.actions : Action, ActionGraph, ActionKind, DeclaredOutput;
import sparkles.build_primitives.resolve.tree : ResolveTree;
import sparkles.build_primitives.task.action : EnvEntry, InertAction, InProcessAction, ProcessAction,
    SandboxPolicy, StdinPolicy, TaskAction;
import sparkles.build_primitives.task.model : EdgeCondition, EdgeReason, TaskEdge, TaskId;
import sparkles.base.vfs.types : Stat;
import sparkles.build_primitives.workspace.discovery : ReadEntry, ReadKind, ReadSet;

/// The cache's own format: any change to what it holds, or to how a request
/// or an entry is checked, moves it.
enum uint planCacheFormat = 2;

/// BGK5: the clock a plan was made by, as the file system holding the cache
/// keeps it (the mtime of a file written as planning began), and that file
/// system's device. A file's identity vouches for it only on that device.
struct PlanClock
{
    bool known;   /// false: no identity vouches for any file
    long nowNs;   /// nanoseconds since the epoch
    ulong device; ///
}

/// BGK5's margin: a time this close to the clock does not vouch for a file.
enum long racyNs = 2_000_000_000;

/// What a reused plan carries: everything the run takes from planning but
/// the variant plan, which only `ci commits build-each` reads, and which
/// therefore never reuses.
struct ReusablePlan
{
    ActionGraph graph;          ///
    ReadSet reads;              ///
    string text;                /// the rendered plan
    size_t requests, targets;   ///
    string[] packageDirectories; ///
    string[] roots;             /// the trees planning read through
    string[][string] testTools; ///
    string[string] singleFileLinks;  ///
    string[string] singleFileErrors; ///
}

// ── the stored form: plain fields, so the codec needs no access to any type's
// internals, and the format is this module's to version ──────────────────────

private struct StoredEntry
{
    string path;
    bool found;
    string digest; // hex
    ReadKind kind;
    string names;
    // A file's identity when the plan was kept; `identified` false for any
    // other kind, or a file that could not be stat'ed (it is then read).
    bool identified;
    ulong device, inode, size;
    long mtime, ctime;
}

private struct StoredProcess
{
    string[] argv;
    EnvEntry[] envDelta;
    string cwd;
    StdinPolicy stdin;
    long timeoutHnsecs;
    SandboxPolicy sandbox;
    bool completeEnvironment;
}

private struct StoredAction
{
    ActionKind kind;
    string id;
    size_t variant;
    // Which of `TaskAction`'s kinds it is: 0 a process, 1 in-process, 2 inert.
    uint actionKind;
    StoredProcess process;
    string handler;
    string[] arguments;
    string note;
    DeclaredOutput[] outputs;
    uint weight;
    bool provisional;
    string[] searchInputs;
    string[] exclusiveKeys;
    string toolchain;
}

private struct StoredEdge
{
    string prerequisite, dependent;
    EdgeCondition condition;
    EdgeReason reason;
}

private struct Pair
{
    string key;
    string[] values;
}

private struct StoredPlan
{
    uint format;
    string request;
    bool clocked;      // whether the file system's clock was read (BGK5)
    long madeAtNs;     // when planning began, by that clock, in ns since the epoch
    ulong clockDevice; // the device that clock is the clock of
    StoredEntry[] reads;
    StoredAction[] actions;
    StoredEdge[] edges;
    string text;
    size_t requests, targets;
    string[] packageDirectories;
    string[] roots;
    Pair[] testTools;
    Pair[] singleFileLinks;  // one value each
    Pair[] singleFileErrors; // ditto
}

private string hex(const ubyte[32] d) @safe pure
{
    import std.digest : toHexString, LetterCase;

    return toHexString!(LetterCase.lower)(d).idup;
}

private bool unhex(string s, out ubyte[32] d) @safe pure
{
    if (s.length != 64)
        return false;
    foreach (i; 0 .. 32)
    {
        try
            d[i] = s[2 * i .. 2 * i + 2].to!ubyte(16);
        catch (Exception)
            return false;
    }
    return true;
}

private TaskId idOf(string text_) @safe pure
{
    import std.array : split;
    import sparkles.build_primitives.task.model : taskId;

    const id = taskId(text_.split(":"));
    return id.hasValue ? id.value : TaskId.init;
}

private Pair[] pairs(const string[][string] aa) @safe pure
{
    import std.algorithm.sorting : sort;

    Pair[] r;
    foreach (k; aa.keys.sort.release)
        r ~= Pair(k, aa[k].dup);
    return r;
}

private Pair[] pairs(const string[string] aa) @safe pure
{
    import std.algorithm.sorting : sort;

    Pair[] r;
    foreach (k; aa.keys.sort.release)
        r ~= Pair(k, [aa[k]]);
    return r;
}

private StoredAction stored(const ref Action a) @safe
{
    import std.sumtype : match;

    StoredAction s;
    s.kind = a.kind;
    s.id = a.id.text;
    s.variant = a.variant;
    a.action.match!(
        (ref const ProcessAction p) {
            s.actionKind = 0;
            s.process = StoredProcess(p.argv.dup, p.envDelta.dup, p.cwd, p.stdin, p.timeout.total!"hnsecs",
                p.sandbox, p.completeEnvironment);
        },
        (ref const InProcessAction p) {
            s.actionKind = 1;
            s.handler = p.handler;
            s.arguments = p.arguments.dup;
        },
        (ref const InertAction p) {
            s.actionKind = 2;
            s.note = p.note;
        });
    s.outputs = a.outputs.dup;
    s.weight = a.weight;
    s.provisional = a.provisional;
    s.searchInputs = a.searchInputs.dup;
    s.exclusiveKeys = a.exclusiveKeys.dup;
    s.toolchain = a.toolchain;
    return s;
}

// The action `s` stores, or one with an empty id when it does not restore.
private Action restored(const ref StoredAction s) @safe
{
    import core.time : hnsecs;

    static TaskAction actionOf(const ref StoredAction s, out bool ok) @safe
    {
        ok = true;
        if (s.actionKind == 0)
        {
            ProcessAction p;
            p.argv = s.process.argv.dup;
            p.envDelta = s.process.envDelta.dup;
            p.cwd = s.process.cwd;
            p.stdin = s.process.stdin;
            p.timeout = s.process.timeoutHnsecs.hnsecs;
            p.sandbox = s.process.sandbox;
            p.completeEnvironment = s.process.completeEnvironment;
            return TaskAction(p);
        }
        if (s.actionKind == 1)
            return TaskAction(InProcessAction(s.handler, s.arguments.dup));
        ok = s.actionKind == 2;
        return TaskAction(InertAction(s.note));
    }
    bool ok;
    auto act = actionOf(s, ok);
    const id = idOf(s.id);
    if (!ok || id.empty)
        return Action.init;
    return Action(s.kind, id, s.variant, act, s.outputs.dup, s.weight, s.provisional, s.searchInputs.dup,
        s.exclusiveKeys.dup, s.toolchain);
}

/**
The JSON a plan is kept as, for `request`, made by `clock`. `identities`
gives a file entry's identity when the file still holds the digest planning
recorded, taken on the handle that read it (null: no identities); an
identity is kept only on the clock's device.
*/
string planText(const ref ReusablePlan p, string request, PlanClock clock,
    scope bool delegate(string path, const ubyte[32] digest, out Stat identity) @safe identities) @safe
{
    import sparkles.wired.json : toJSON;

    StoredPlan s;
    s.format = planCacheFormat;
    s.request = request;
    s.clocked = clock.known;
    s.madeAtNs = clock.nowNs;
    s.clockDevice = clock.device;
    foreach (ref e; p.reads.entries)
    {
        StoredEntry t = StoredEntry(e.path, e.found, hex(e.digest), e.kind, e.names);
        Stat st;
        if (e.kind == ReadKind.file && e.found && clock.known && identities !is null
                && identities(e.path, e.digest, st) && st.device == clock.device && !st.ctimeSettable)
        {
            t.identified = true;
            t.device = st.device;
            t.inode = st.inode;
            t.size = st.size;
            t.mtime = st.mtimeNs;
            t.ctime = st.ctimeNs;
        }
        s.reads ~= t;
    }
    foreach (ref a; p.graph.actions)
        s.actions ~= stored(a);
    foreach (ref e; p.graph.edges)
        s.edges ~= StoredEdge(e.prerequisite.text, e.dependent.text, e.condition, e.reason);
    s.text = p.text;
    s.requests = p.requests;
    s.targets = p.targets;
    s.packageDirectories = p.packageDirectories.dup;
    s.roots = p.roots.dup;
    s.testTools = pairs(p.testTools);
    s.singleFileLinks = pairs(p.singleFileLinks);
    s.singleFileErrors = pairs(p.singleFileErrors);
    auto json = toJSON(s);
    return json.hasValue ? json.value[].idup : null;
}

/// What checking a kept plan found.
struct Checked
{
    bool reused;        /// every entry held
    string why;         /// why not, when not
    ReusablePlan plan;  /// the plan, when reused
    size_t rehashed;    /// files read because their identity did not settle it
}

/**
Checks the plan kept as `source` for `request` against the file system,
through the tree `treeOver` makes over the plan's roots (a fresh one), with
`environment` reading a variable. `queryHolds` says whether a `pkg-config`
query (its arguments, and whether and what it answered) still answers the
same (see the module).
*/
Checked reusePlan(string source, string request, scope ResolveTree delegate(const(string)[] roots) @safe treeOver,
    scope bool delegate(string name, out string value) @safe environment,
    scope bool delegate(string arguments, bool succeeded, const ubyte[32] answer) @safe queryHolds) @safe
{
    import std.algorithm.iteration : splitter;
    import std.array : array;
    import sparkles.base.hash.blake3 : blake3;
    import sparkles.wired.json : fromJSON;

    Checked c;
    auto parsed = fromJSON!StoredPlan(source);
    if (parsed.hasError)
        return Checked(why: "the kept plan does not parse");
    auto s = parsed.value;
    if (s.format != planCacheFormat)
        return Checked(why: text("the kept plan is in format ", s.format));
    if (s.request != request)
        return Checked(why: "the kept plan is another request's");
    auto tree = treeOver(s.roots);
    foreach (ref e; s.reads)
    {
        ubyte[32] want;
        if (!unhex(e.digest, want))
            return Checked(why: "a kept entry's digest does not parse: " ~ e.path);
        final switch (e.kind)
        {
        case ReadKind.file:
            if (!e.found)
            {
                if (tree.exists(e.path))
                    return Checked(why: e.path ~ " appeared");
                break;
            }
            Stat st;
            if (e.path.startsWith("/nix/store/") && tree.identify(e.path, st))
                break; // a store path's contents are its name's
            if (e.identified && s.clocked && tree.identify(e.path, st) && st.device == s.clockDevice
                && !st.ctimeSettable && st.device == e.device && st.inode == e.inode && st.size == e.size
                && st.mtimeNs == e.mtime && st.ctimeNs == e.ctime && st.mtimeNs < s.madeAtNs - racyNs
                && st.ctimeNs < s.madeAtNs - racyNs)
                break;
            string bytes;
            ++c.rehashed;
            if (!tree.readText(e.path, bytes) || blake3(cast(const(ubyte)[]) bytes) != want)
                return Checked(why: e.path ~ " changed");
            break;
        case ReadKind.probe:
            const now = e.names == "directory" ? tree.isDirectory(e.path) : tree.exists(e.path);
            if (now != e.found)
                return Checked(why: e.path ~ (e.found ? " is gone" : " appeared"));
            break;
        case ReadKind.listing:
            const patterns = e.names.splitter(' ').array;
            const listed = tree.recorded(() { cast(void) tree.files(e.path, patterns); });
            bool same;
            foreach (ref r; listed.entries)
                if (r.kind == ReadKind.listing && r.path == e.path && r.names == e.names)
                    same = r.found == e.found && r.digest == want;
            if (!same)
                return Checked(why: "the listing of " ~ e.path ~ " (" ~ e.names ~ ") changed");
            break;
        case ReadKind.link:
            string target;
            if (!tree.linkTarget(e.path, target) || target != e.names)
                return Checked(why: "the link " ~ e.path ~ " changed");
            break;
        case ReadKind.query:
            if (!queryHolds(e.names, e.found, want))
                return Checked(why: "a pkg-config query answers otherwise: " ~ e.names);
            break;
        case ReadKind.environment:
            import std.algorithm.searching : canFind;

            // A host's variable, from its toolchain table entry: the request
            // holds the table's digest.
            if (e.path.canFind(':'))
                break;
            string value;
            const set = environment(e.path, value);
            if (set != e.found || set && blake3(cast(const(ubyte)[]) value) != want)
                return Checked(why: "the environment variable " ~ e.path ~ " changed");
            break;
        }
    }
    // A lookup refused, as planning would refuse it (BGF3).
    foreach (ref f; tree.faults)
        return Checked(why: "a lookup is refused: " ~ f.path ~ (f.target.length ? " -> " ~ f.target : "") ~ " ("
            ~ f.reason ~ ")");
    // Every entry held: the plan.
    ReusablePlan p;
    foreach (ref e; s.reads)
    {
        ReadEntry r = ReadEntry(e.path, e.found);
        cast(void) unhex(e.digest, r.digest);
        r.kind = e.kind;
        r.names = e.names;
        p.reads.entries ~= r; // kept in the order the set had them
    }
    foreach (ref a; s.actions)
    {
        auto restoredAction = restored(a);
        if (restoredAction.id.empty)
            return Checked(why: "a kept action does not restore: " ~ a.id);
        p.graph.actions ~= restoredAction;
    }
    foreach (ref e; s.edges)
        p.graph.edges ~= TaskEdge(idOf(e.prerequisite), idOf(e.dependent), e.condition, e.reason);
    p.text = s.text;
    p.requests = s.requests;
    p.targets = s.targets;
    p.packageDirectories = s.packageDirectories;
    p.roots = s.roots;
    foreach (ref t; s.testTools)
        p.testTools[t.key] = t.values;
    foreach (ref t; s.singleFileLinks)
        if (t.values.length)
            p.singleFileLinks[t.key] = t.values[0];
    foreach (ref t; s.singleFileErrors)
        if (t.values.length)
            p.singleFileErrors[t.key] = t.values[0];
    return Checked(reused: true, plan: p, rehashed: c.rehashed);
}


/**
The request a plan answers, as a digest: every value planning reads that is
not in its read set. A field added to `T` (the tools) is covered without a
change here, as each is written in order, an associative array's entries
sorted.
*/
string planRequest(T)(const ref T tools, scope const(string)[] parts) @safe
{
    import sparkles.base.hash.blake3 : blake3;

    string s = text("plan-cache ", planCacheFormat, "\n");
    foreach (part; parts)
        s ~= part ~ "\n";
    s ~= fieldsText(tools);
    return hex(blake3(cast(const(ubyte)[]) s));
}

// The fields of `value`, one per line, an associative array's by sorted key.
private string fieldsText(T)(const ref T value) @safe
{
    import std.algorithm.sorting : sort;
    import std.traits : isAssociativeArray;

    string s;
    static foreach (i, field; T.tupleof)
    {{
        alias F = typeof(field);
        s ~= __traits(identifier, T.tupleof[i]) ~ " ";
        static if (isAssociativeArray!F)
        {
            foreach (k; value.tupleof[i].keys.sort.release)
                s ~= text("[", k, "]=", value.tupleof[i][k], " ");
        }
        else
            s ~= text(value.tupleof[i]);
        s ~= "\n";
    }}
    return s;
}

///
@("plan_reuse.roundTripAndChecks")
@safe unittest
{
    import core.time : seconds;
    import sparkles.base.hash.blake3 : blake3;
    import sparkles.build_primitives.resolve.tree : memoryTree;
    import sparkles.build_primitives.task.model : taskId;

    // A plan of two actions, an edge and one read of each kind but a link.
    auto tree = memoryTree(["/r/a.d": "module a;", "/r/lib/b.d": "module b;"]);
    string a;
    cast(void) tree.readText("/r/a.d", a);
    cast(void) tree.exists("/r/none.d");
    cast(void) tree.isDirectory("/r/lib");
    cast(void) tree.files("/r/lib", ["*.d"]);
    tree.noteEnvironment("V", "1", true);
    tree.noteEnvironment("android:MIN_SDK", "24", true);
    ReusablePlan p;
    p.reads = tree.reads;
    const compile = taskId("compile", "r.a", "library", "ldc", "abc").value;
    const link = taskId("link", "r.a", "application", "ldc", "abc").value;
    p.graph.actions ~= Action(ActionKind.compile, compile, 0,
        TaskAction(ProcessAction(argv: ["ldc2", "-c", "a.d"], timeout: 30.seconds)), [DeclaredOutput("a.o")], 2);
    p.graph.actions ~= Action(ActionKind.link, link, 0, TaskAction(InProcessAction("link", ["x"])),
        [DeclaredOutput("a")], 2);
    p.graph.edges ~= TaskEdge(compile, link, EdgeCondition.onSuccess, EdgeReason.packageDependency);
    p.text = "plan";
    p.requests = 1;
    p.roots = ["/r"];
    p.testTools["a"] = ["dub"];
    const kept = planText(p, "req", PlanClock.init, null);
    assert(kept.length);

    bool env(string name, out string value)
    {
        value = name == "V" ? "1" : null;
        return name == "V";
    }
    bool holds(string, bool, const ubyte[32]) => true;

    auto same = memoryTree(["/r/a.d": "module a;", "/r/lib/b.d": "module b;"]);
    const c = reusePlan(kept, "req", (const(string)[]) => same, &env, &holds);
    assert(c.reused, c.why);
    assert(c.rehashed == 1, "with no identity, the file is read");
    assert(c.plan.graph.actions.length == 2 && c.plan.graph.actions[0].id == compile);
    assert(c.plan.graph.actions == p.graph.actions && c.plan.graph.edges == p.graph.edges);
    assert(c.plan.text == "plan" && c.plan.testTools["a"] == ["dub"] && c.plan.reads.entries == p.reads.entries);

    // Each kind of entry, changed, plans again, naming it.
    assert(reusePlan(kept, "other", (const(string)[]) => same, &env, &holds).why == "the kept plan is another request's");
    assert(reusePlan(kept, "req", (const(string)[]) => memoryTree(["/r/a.d": "module a2;", "/r/lib/b.d": "module b;"]),
        &env, &holds).why == "/r/a.d changed");
    assert(reusePlan(kept, "req", (const(string)[]) => memoryTree(["/r/a.d": "module a;", "/r/lib/b.d": "module b;",
        "/r/none.d": ""]), &env, &holds).why == "/r/none.d appeared");
    assert(reusePlan(kept, "req", (const(string)[]) => memoryTree(["/r/a.d": "module a;", "/r/lib/b.d": "module b;",
        "/r/lib/c.d": ""]), &env, &holds).why == "the listing of /r/lib/ (*.d) changed");
    bool otherEnv(string name, out string value)
    {
        value = "2";
        return true;
    }
    assert(reusePlan(kept, "req", (const(string)[]) => same, &otherEnv, &holds).why
        == "the environment variable V changed");
    assert(!reusePlan("{", "req", (const(string)[]) => same, &env, &holds).reused);
}

/// A file whose identity is unchanged, on the clock's device and not racily
/// recent by it, holds unread; any other is read.
@("plan_reuse.identityShortcut")
@safe unittest
{
    import sparkles.base.vfs.types : Stat;
    import sparkles.build_primitives.resolve.tree : memoryTree;

    auto tree = memoryTree(["/r/a.d": "module a;"]);
    string a;
    cast(void) tree.readText("/r/a.d", a);
    ReusablePlan p;
    p.reads = tree.reads;
    p.roots = ["/r"];
    Stat st;
    assert(tree.identify("/r/a.d", st));
    bool ids(string path, const ubyte[32] digest, out Stat s)
    {
        ubyte[32] d;
        return tree.readIdentified(path, s, d) && d == digest;
    }
    bool env(string, out string v) => false;
    bool holds(string, bool, const ubyte[32]) => true;
    // The memory tree stamps every file at 0.
    const clock = PlanClock(true, 100_000_000_000, st.device);
    const kept = planText(p, "req", clock, &ids);

    // Unchanged identity: not read, even though this tree's content differs
    // (in memory, a same-sized edit at the same instant keeps the identity).
    auto edited = memoryTree(["/r/a.d": "module b;"]);
    assert(reusePlan(kept, "req", (const(string)[]) => edited, &env, &holds).rehashed == 0);
    // A size changed: read, and the change seen.
    assert(reusePlan(kept, "req", (const(string)[]) => memoryTree(["/r/a.d": "module bb;"]), &env, &holds).why
        == "/r/a.d changed");
    // Kept racily recent by the clock, on another device, or unclocked: read.
    foreach (other; [PlanClock(true, 1_000_000_000, st.device), PlanClock(true, 100_000_000_000, st.device + 1),
        PlanClock.init])
    {
        const k = planText(p, "req", other, &ids);
        assert(reusePlan(k, "req", (const(string)[]) => edited, &env, &holds).why == "/r/a.d changed");
    }
    // A file that changed since planning read it keeps no identity.
    bool stale(string path, const ubyte[32] digest, out Stat s)
    {
        ubyte[32] d;
        return edited.readIdentified(path, s, d) && d == digest;
    }
    const keptStale = planText(p, "req", clock, &stale);
    assert(reusePlan(keptStale, "req", (const(string)[]) => edited, &env, &holds).why == "/r/a.d changed");
}

/// A link is read again through the tree: a changed target plans again, and
/// so does a lookup the tree refuses, as planning would.
@("plan_reuse.links")
@safe unittest
{
    import sparkles.build_primitives.resolve.tree : memoryTree;

    auto tree = memoryTree(["/r/real/a.d": "module a;", "/r/other/a.d": "module a;"], ["/r/l": "real"]);
    string a;
    assert(tree.readText("/r/l/a.d", a));
    ReusablePlan p;
    p.reads = tree.reads;
    p.roots = ["/r"];
    const kept = planText(p, "req", PlanClock.init, null);
    bool env(string, out string v) => false;
    bool holds(string, bool, const ubyte[32]) => true;
    const files = ["/r/real/a.d": "module a;", "/r/other/a.d": "module a;"];
    assert(reusePlan(kept, "req", (const(string)[]) => memoryTree(files, ["/r/l": "real"]), &env, &holds).reused);
    assert(reusePlan(kept, "req", (const(string)[]) => memoryTree(files, ["/r/l": "other"]), &env, &holds).why
        == "the link /r/l changed");
    const refused = reusePlan(kept, "req", (const(string)[]) => memoryTree(files, ["/r/l": "/r/real"]), &env, &holds);
    assert(!refused.reused);
}

/// A query holds only as the caller's check says.
@("plan_reuse.queries")
@safe unittest
{
    import sparkles.build_primitives.resolve.tree : memoryTree;

    auto tree = memoryTree(null);
    tree.noteQuery(["--libs", "zlib"], 0, "-lz");
    ReusablePlan p;
    p.reads = tree.reads;
    bool env(string, out string v) => false;
    string asked;
    bool same(string arguments, bool ok, const ubyte[32])
    {
        asked = arguments;
        return ok;
    }
    bool other(string, bool, const ubyte[32]) => false;
    const kept = planText(p, "req", PlanClock.init, null);
    assert(reusePlan(kept, "req", (const(string)[]) => memoryTree(null), &env, &same).reused);
    assert(asked == "--libs zlib");
    assert(reusePlan(kept, "req", (const(string)[]) => memoryTree(null), &env, &other).why
        == "a pkg-config query answers otherwise: --libs zlib");
}
