/++
The reuse gate: when an action's recorded result may be reused without
checking the manifest entries its declared read set covers
([design](../../../../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md),
BGW10).

A result is recorded with its declared key, the input state id of its
declared read set (BGW7, BGW9), and its **residue**: the manifest entries
that the state id does not cover. When the key and the state id are the
same as recorded, and every residue entry still reads as recorded, the
result is reused without the manifest check. Otherwise the manifest decides,
exactly as the build graph's BGK3 states: a differing id never by itself
causes an action to run.

Every manifest entry inside the declared read set is a member of it, or a
path that would be one, so an unchanged state leaves each of them unchanged.
The residue is what that argument does not reach:

$(UL
$(LI $(B An absent candidate outside the set.) It must still be absent. It
    stands for its highest missing ancestor, so the compiler's
    working-directory lookups cost one check per top-level name.)
$(LI $(B A file under a root the key covers.) The toolchain, a registry
    source in an immutable store: no check.)
$(LI $(B A file under any other root.) A header `pkg-config` located in a
    host directory: checked as any manifest entry is.)
)

The gate is a gate, never a key: a reuse it allows is one the manifest
would allow too (the converse fails by design, since an edit to a module no
compile imported changes the set and not the manifest).
+/
module sparkles.build_primitives.workspace.gate;

/// A file's content id (D48).
alias Digest = ubyte[32];

/// One entry of an action's manifest (BGK2).
struct ManifestEntry
{
    string path;   /// repository-relative, or absolute beneath another root
    bool absent;   /// an absent candidate: the path was probed and missing
    Digest digest; /// the bytes read; zero for an absent candidate
}

/// What a gate records with a result.
struct GateRecord
{
    Digest key;              /// the declared key
    Digest state;            /// the input state id of the declared read set
    ManifestEntry[] residue; /// the entries the state id does not cover
}

/**
The residue of `manifest`: the entries `inSet` does not place in the
declared read set and no root of `coveredRoots` holds, an absent candidate
replaced by its highest missing ancestor (`exists` says which ancestors are
there), each once, in path order.
*/
ManifestEntry[] residueOf(scope const(ManifestEntry)[] manifest, scope bool delegate(string) @safe inSet,
    scope const(string)[] coveredRoots, scope bool delegate(string) @safe exists) @safe
{
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;

    ManifestEntry[] residue;
    foreach (ref e; manifest)
    {
        if (inSet(e.path) || coveredRoots.canFind!(r => beneath(e.path, r)))
            continue;
        ManifestEntry r = e;
        if (e.absent)
        {
            // Up to the highest ancestor that is missing.
            string at = e.path;
            for (auto parent = parentOf(at); parent.length && !exists(parent); parent = parentOf(parent))
                at = parent;
            r.path = at;
        }
        if (!residue.canFind!(x => x.path == r.path && x.absent == r.absent))
            residue ~= r;
    }
    residue.sort!((a, b) => a.path < b.path);
    return residue;
}

/**
Whether the result recorded as `record` may be reused without its
manifest's check: the declared key and the state id are the ones recorded,
and `holds` says every residue entry reads as recorded (an absent one still
absent, a file's digest the same). `false` means the manifest decides
(BGK3), never that the action must run.
*/
bool reusable(const ref GateRecord record, in Digest key, in Digest state,
    scope bool delegate(ref const ManifestEntry) @safe holds) @safe
{
    if (record.key != key || record.state != state)
        return false;
    foreach (ref e; record.residue)
        if (!holds(e))
            return false;
    return true;
}

// Whether `path` is `root` or lies beneath it.
private bool beneath(scope const(char)[] path, scope const(char)[] root) @safe pure nothrow @nogc
    => root.length == 0 || path == root
        || (path.length > root.length && path[0 .. root.length] == root && path[root.length] == '/');

// `a/b/c` → `a/b`; `a` → ``; `/x` → ``.
private string parentOf(string path) @safe pure nothrow @nogc
{
    size_t i = path.length;
    while (i > 0 && path[i - 1] != '/')
        --i;
    return i > 1 ? path[0 .. i - 1] : "";
}

/// The residue keeps what the set and the covered roots do not hold, and an
/// absent candidate becomes its highest missing ancestor.
@("workspace.gate.residueOf")
@safe unittest
{
    import std.algorithm.searching : startsWith;

    const Digest d = 7;
    const manifest = [
        ManifestEntry("pkg/src/a.d", false, d),
        ManifestEntry("pkg/src/gone.d", true),
        ManifestEntry("sparkles/base/buffer.d", true),
        ManifestEntry("sparkles/base/other.d", true),
        ManifestEntry("/nix/store/abc-ldc/import/object.d", false, d),
        ManifestEntry("/usr/include/x.h", false, d),
    ];
    const residue = residueOf(manifest, (string p) => p.startsWith("pkg/"), ["/nix/store"],
        (string p) => p == "/usr" || p == "/usr/include");
    assert(residue == [ManifestEntry("/usr/include/x.h", false, d), ManifestEntry("sparkles", true)]);
}

/**
BGW10's oracle, an exhaustive small model: for every single-file edit of a
fixture tree (each file changed, each file removed, each candidate and each
new name created), the gate allows a reuse only when no manifest entry of
any action changed. It allows some, so the check is not vacuous: the state
id moves for an edit inside a set, and the gate holds for one outside every
set and residue. And the model catches a gate that ignores the residue.
*/
@("workspace.gate.BGW10.exhaustive")
@system unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import std.conv : text;
    import sparkles.base.hash.blake3 : blake3;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : EntryKind, Rights;
    import sparkles.build_primitives.fileset.pattern : CasePolicy;
    import sparkles.build_primitives.fileset.testing : RecordingExecutor, openFixture;
    import sparkles.build_primitives.fileset.value : EntryFacts, Fileset, FilesetEvaluator, Filesets;
    import sparkles.build_primitives.workspace.input_state : DigestCache, observe;

    enum literal = "pkg/src/a.d = A\npkg/src/b.d = B\npkg/README = r\ndep/src/c.d = C\n"
        ~ "host/inc/h.h = H\nstore/lib/object.d = O\nother/x.txt = X\n";
    static immutable string[] files = ["pkg/src/a.d", "pkg/src/b.d", "pkg/README", "dep/src/c.d",
        "host/inc/h.h", "store/lib/object.d", "other/x.txt"];
    static immutable string[] fresh = ["pkg/src/sparkles/a.d", "dep/src/missing.d", "sparkles/a.d",
        "sparkles/c.d", "host/inc/new.h", "other/y.txt", "pkg/src/new.d", "dep/src/new.d", "sparkles2/z.d"];

    static struct Action
    {
        string[] patterns;        // the declared read set
        ManifestEntry[] manifest; // what the compile read, digests filled in below
    }

    Action[] actions = [
        Action(["pkg/src/**", "dep/src/**"], [
            ManifestEntry("pkg/src/a.d"), ManifestEntry("dep/src/c.d"), ManifestEntry("host/inc/h.h"),
            ManifestEntry("store/lib/object.d"), ManifestEntry("pkg/src/sparkles/a.d", true),
            ManifestEntry("dep/src/missing.d", true), ManifestEntry("sparkles/a.d", true),
        ]),
        Action(["dep/src/**"], [
            ManifestEntry("dep/src/c.d"), ManifestEntry("sparkles/c.d", true),
            ManifestEntry("store/lib/object.d"),
        ]),
    ];

    // A tree after `edit` (null for none), and what each action reads in it.
    static struct World
    {
        typeof(openFixture("")) made;
        Digest[] states;
        Digest key; // the declared key, which covers the toolchain under `store/`
    }

    auto sets = Filesets(CasePolicy.sensitive);
    auto declared = new Fileset[actions.length];
    foreach (i, ref a; actions)
    {
        auto f = sets.nothing;
        foreach (p; a.patterns)
            f = sets.union_(f, sets.glob(p).value);
        declared[i] = f;
    }

    bool exists(ref World w, string path) => w.made.value.get().vfs.exists(path);

    Digest digestOf(ref World w, string path)
    {
        auto bytes = w.made.value.get().vfs.contents(path);
        return bytes is null && !exists(w, path) ? Digest.init : blake3(bytes);
    }

    World world(void delegate(ref World) edit)
    {
        auto w = World(openFixture(literal));
        if (edit !is null)
            edit(w);
        auto root = openRoot!(Rights.readOnly)(&w.made.value.get().vfs, "", ambientAuthority());
        foreach (f; declared)
        {
            DigestCache!() cold;
            RecordingExecutor exec;
            auto got = observe(root.value.borrow, sets, f, cold, exec);
            assert(!got.hasError, got.hasError ? got.error.context : "");
            w.states ~= got.value.id;
        }
        w.key = blake3(w.made.value.get().vfs.contents("store/lib/object.d"));
        return w;
    }

    // The recording run.
    auto base = world(null);
    const key = base.key;
    GateRecord[] records;
    foreach (i, ref a; actions)
    {
        foreach (ref e; a.manifest)
            if (!e.absent)
                e.digest = digestOf(base, e.path);
        auto ev = FilesetEvaluator(sets, declared[i]);
        const f = declared[i];
        records ~= GateRecord(key, base.states[i], residueOf(a.manifest, (string p) @trusted {
            ev.judge(sets, p, EntryFacts.init);
            return ev.selects(f);
        }, ["store"], (string p) @trusted => exists(base, p)));
    }

    // Every single-file edit; each delegate made by a call of its own, so
    // that it keeps its own path.
    static void delegate(ref World) writing(string path, string bytes)
        => (ref World w) { assert(w.made.value.get().vfs.writeFile(path, cast(const(ubyte)[]) bytes)); };
    static void delegate(ref World) removing(string path)
        => (ref World w) { assert(w.made.value.get().vfs.remove(path)); };
    void delegate(ref World)[] edits;
    string[] names;
    foreach (path; files)
    {
        edits ~= writing(path, "edited");
        names ~= "change " ~ path;
        edits ~= removing(path);
        names ~= "remove " ~ path;
    }
    foreach (path; fresh)
    {
        edits ~= writing(path, "new");
        names ~= "create " ~ path;
    }

    size_t reused, decided;
    bool caught;
    foreach (k, edit; edits)
    {
        auto w = world(edit);
        foreach (i, ref a; actions)
        {
            bool holds(ref const ManifestEntry e) @trusted
                => e.absent ? !exists(w, e.path) : exists(w, e.path) && digestOf(w, e.path) == e.digest;
            bool changed;
            string why;
            foreach (ref e; a.manifest)
                if (!holds(e))
                {
                    changed = true;
                    why ~= " " ~ e.path;
                }
            const reuse = reusable(records[i], w.key, w.states[i], &holds);
            assert(!(reuse && changed), text(names[k], ": the gate reuses action ", i,
                " though its manifest changed:", why));
            // The model is tested too: a gate that skips the residue
            // reuses a result some edit has made stale.
            GateRecord bare = records[i];
            bare.residue = null;
            caught |= changed && reusable(bare, w.key, w.states[i], &holds);
            if (reuse)
                ++reused;
            else
                ++decided;
        }
    }
    assert(reused >= 4 && decided >= 20, text(reused, " reused, ", decided, " left to the manifest"));
    assert(caught, "the model must catch a gate that ignores the residue");
}
