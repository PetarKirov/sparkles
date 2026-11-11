/**
The oracles of content addressing: each scheme's id of a tree equals the id
an independent implementation gives the same tree, materialized on disk.

The trees are hand-written ones aimed at the ordering hazard and at case
collisions, the fileset fixture set, and seeded random trees. A scheme runs
over the in-memory driver; its oracle reads the materialized copy.

Excluded from the `library` configuration, with `fileset/testing.d`, whose
fixtures it uses.
*/
module sparkles.build_primitives.content_addressing.testing;

import std.conv : text;
import std.digest.sha : SHA1, SHA256;
import std.file : rmdirRecurse;
import std.meta : AliasSeq;
import std.random : Mt19937, uniform;
import std.string : indexOf, lineSplitter, strip;

import sparkles.base.hash.blake3 : Blake3;
import sparkles.base.vfs.mem : MemVfs;
import sparkles.base.vfs.types : Rights;

import sparkles.build_primitives.content_addressing.cache;
import sparkles.build_primitives.content_addressing.castore;
import sparkles.build_primitives.content_addressing.git;
import sparkles.build_primitives.content_addressing.merkle;
import sparkles.build_primitives.content_addressing.nar;
import sparkles.build_primitives.content_addressing.outboard;
import sparkles.build_primitives.fileset.fso : EntryOrder, FsoFingerprint;
import sparkles.build_primitives.fileset.machine : ResolutionLimits;
import sparkles.build_primitives.fileset.pattern : CasePolicy;
import sparkles.build_primitives.fileset.scheme : FsoRef;
import sparkles.build_primitives.fileset.testing : RecordingExecutor, fixtureSet, materialize, openFixture,
    randomTree, schemeResolve, scratchFoldsCase, scratchTree;
import sparkles.build_primitives.fileset.value : Filesets;
import sparkles.test_runner.skip : skipTest;

/// A tree literal and what to call it when it fails.
struct OracleTree
{
    string label;   ///
    string literal; ///
}

/**
The trees every oracle is run on: the ordering hazard, every node kind, a
case collision, the empty tree, the fixture set, and `rounds` seeded random
trees whose files have contents.
*/
OracleTree[] oracleTrees(size_t rounds = 200) @safe
{
    import std.array : join, split;

    OracleTree[] trees = [
        // `a` the directory sorts after `a.b`, `a-b` and `a+` in git's order,
        // but before `a0`, as if it were `a/`.
        OracleTree("hazard", "a/x = 1\na.b = 2\na-b = 3\na+ = 4\na0 = 5\nab/c\n"),
        OracleTree("kinds", "a/b/c = deep\na.b/c = d\nempty/\nhollow/inner/\nrun +x = #!\n"
            ~ "l -> a/b\nz -> /nowhere\n"),
        OracleTree("case collision", "A = upper\na = lower\nB/x = 1\nb/x = 2\n"),
        OracleTree("no hazard", "a/x = 1\nb.c = 2\nc/y = 3\n"),
        OracleTree("empty tree", ""),
    ];
    foreach (fx; fixtureSet())
        trees ~= OracleTree(fx.name, fx.tree);
    auto rng = Mt19937(20_261_108);
    foreach (round; 0 .. rounds)
    {
        string[] lines;
        foreach (line; randomTree(rng).split("\n"))
            lines ~= line.length && line[$ - 1] != '/' ? line ~ " = " ~ line[0 .. line.length / 2]
                : line;
        trees ~= OracleTree(text("random round ", round), lines.join("\n"));
    }
    return trees;
}

/// The `oracleTrees` a scratch directory can hold: without the case collision
/// where the filesystem folds case (`scratchFoldsCase`).
OracleTree[] diskOracleTrees(size_t rounds = 200) @system
{
    import std.algorithm.iteration : filter;
    import std.array : array;

    const folds = scratchFoldsCase();
    return oracleTrees(rounds).filter!(t => !(folds && t.label == "case collision")).array;
}

/// The id scheme `S` gives the tree of `literal`, over the in-memory driver.
auto idOf(S)(string literal, ResolutionLimits limits = ResolutionLimits.init)
{
    auto sets = Filesets(CasePolicy.sensitive);
    RecordingExecutor exec;
    S scheme;
    return schemeResolve(literal, sets, sets.everything, scheme, exec, limits);
}

/**
The tree a fileset holding every file and link of `literal` names: without
its directories that hold no member, empty or holding only such
directories (C3).
*/
string membersOf(string literal) @safe pure
{
    import std.algorithm.iteration : filter, joiner;
    import std.algorithm.searching : canFind, endsWith;
    import std.conv : to;

    const kept = literal.lineSplitter
        .filter!(l => l.length && !(l.endsWith("/") && !l.canFind(" -> ") && !l.canFind(" = ")))
        .joiner("\n").to!string;
    return kept.length ? kept ~ "\n" : "";
}

/// Runs `oracle` on the members of `tree` (`membersOf`), materialized in
/// a scratch directory.
string onDisk(string tree, string label, string delegate(string dir) @system oracle) @system
{
    const dir = scratchTree(label);
    scope (exit) rmdirRecurse(dir);
    materialize(membersOf(tree), dir);
    return oracle(dir);
}

/// FSM3 under a fold: a directory's subdirectories listed in batches of
/// `maxPending` give each tree the id one batch gives it.
@("content_addressing.merkle.FSM3.splitBatches")
@system unittest
{
    size_t compared;
    foreach (t; oracleTrees(50))
    {
        const whole = idOf!(GitTreeScheme!SHA1)(t.literal);
        foreach (pending; [1u, 2u, 3u])
        {
            ResolutionLimits lim;
            lim.maxPending = pending;
            assert(idOf!(GitTreeScheme!SHA1)(t.literal, lim).digest == whole.digest,
                text(t.label, ": batches of ", pending, "\n", t.literal));
        }
        ++compared;
    }
    assert(compared > 50);
}

// --------------------------------------------------------------- git

/// `git add -A -f`, then `git write-tree`, in `dir`, a repository using
/// `format`'s object ids.
string gitWriteTree(string dir, string format) @system
{
    import sparkles.build_primitives.git_env : runGit;

    foreach (args; [["init", "-q", "--object-format=" ~ format],
            ["-c", "core.excludesFile=/dev/null", "add", "-A", "-f"]])
    {
        const r = runGit(args, dir);
        assert(r.status == 0, r.output);
    }
    const tree = runGit(["write-tree"], dir);
    assert(tree.status == 0, tree.output);
    return tree.output.strip;
}

/// Git's encoding sorted by bytes instead of git's order: the control that
/// shows the oracle catches the ordering hazard.
private struct BytewiseGitTree(H)
{
    GitTree!H git;
    alias Id = GitTree!H.Id;
    alias Leaf = GitTree!H.Leaf;
    enum order = EntryOrder.narOrder;

    void begin() { git.begin(); }
    void directory(scope const(char)[] name, ref const Id child) { git.directory(name, child); }
    void file(scope const(char)[] name, bool x, ref const GitTree!H.Digest id, ulong size)
    {
        git.file(name, x, id, size);
    }
    void symlink(scope const(char)[] name, scope const(char)[] target)
    {
        git.symlink(name, target);
    }
    Id seal() => git.seal();
}

/**
Git's tree id, SHA-1 and SHA-256, equals `git write-tree` of the same tree,
added whole. Sorted by bytes, the same encoding is wrong wherever the
ordering hazard arises, and the hazard arises often: on a quarter of the
trees at least.
*/
@("content_addressing.git.writeTree")
@system unittest
{
    import std.digest.sha : SHA1, SHA256;
    import std.traits : FunctionAttribute, functionAttributes;

    import sparkles.build_primitives.git_env : runGit;

    // Hashing an object never touches the GC.
    static assert(functionAttributes!(objectDigest!SHA1) & FunctionAttribute.nogc);
    static assert(functionAttributes!(GitTree!SHA1.seal) & FunctionAttribute.nogc);

    try
        cast(void) runGit(["--version"]);
    catch (Exception)
        return skipTest("git is not installed");

    size_t compared, hazards;
    foreach (t; diskOracleTrees())
    {
        const ours = idOf!(GitTreeScheme!SHA1)(t.literal);
        const bytewise = idOf!(MerkleFold!(BytewiseGitTree!SHA1))(t.literal);
        const sha1 = onDisk(t.literal, "git-sha1", dir => gitWriteTree(dir, "sha1"));
        assert(toHex(ours.digest)[] == sha1, text(t.label, ": ", toHex(ours.digest)[], " != ",
            sha1, "\n", t.literal));
        ++compared;
        hazards += bytewise.digest != ours.digest;

        const ours256 = idOf!(GitTreeScheme!SHA256)(t.literal);
        const sha256 = onDisk(t.literal, "git-sha256", dir => gitWriteTree(dir, "sha256"));
        assert(toHex(ours256.digest)[] == sha256, text(t.label, " (SHA-256): ",
            toHex(ours256.digest)[], " != ", sha256, "\n", t.literal));
    }
    assert(compared > 200);
    assert(hazards > compared / 4, text(hazards, " of ", compared));
    assert(idOf!(GitTreeScheme!SHA1)("a/x\na.b\n") != idOf!(MerkleFold!(BytewiseGitTree!SHA1))(
        "a/x\na.b\n"));
}

// --------------------------------------------------------------- castore

/// `snix-castore ingest` of `dir` into memory: the castore id Snix gives it.
string snixIngest(string snix, string dir) @system
{
    import std.process : Config, execute;

    enum memory = "memory:";
    const r = execute([snix, "ingest", "--blob-store-addr", memory, "--chunk-store-addr", memory,
        "--directory-service-addr", "redb+memory:", dir], null, Config.stderrPassThrough);
    assert(r.status == 0, text("snix-castore ingest ", dir, ": ", r.output));
    return r.output.strip;
}

/**
The castore id equals the one Snix's `snix-castore ingest` gives the same
tree. `$SPARKLES_SNIX_CASTORE` names the binary; without it the test is
skipped.
*/
@("content_addressing.castore.snix")
@system unittest
{
    import std.file : exists;
    import std.process : environment;

    const snix = environment.get("SPARKLES_SNIX_CASTORE");
    if (snix is null)
        return skipTest("SPARKLES_SNIX_CASTORE is not set");
    assert(snix.exists, snix);

    foreach (t; diskOracleTrees())
    {
        const ours = idOf!CastoreScheme(t.literal);
        const theirs = onDisk(t.literal, "castore", dir => snixIngest(snix, dir));
        assert(toCastoreText(ours.digest)[] == theirs, text(t.label, ": ",
            toCastoreText(ours.digest)[], " != ", theirs, "\n", t.literal));
    }
}

// --------------------------------------------------------------- NAR

/// The reference type of an entry resolved over a tree literal.
alias LiteralRef = FsoRef!(MemVfs, Rights.readOnly);

/// The NAR of a fileset over a tree literal, hashed by SHA-256.
alias LiteralNar = NarScheme!(SHA256, LiteralRef);

/// `nix-store --dump` of `dir`: the NAR Nix writes for it.
string nixDump(string dir) @system
{
    import std.process : Config, execute;

    const r = execute(["nix-store", "--dump", dir], null, Config.stderrPassThrough);
    assert(r.status == 0, text("nix-store --dump ", dir, ": ", r.output));
    return r.output;
}

/// Whether `nix-store` runs here.
bool haveNix() @system
{
    import std.process : execute;

    try
        return execute(["nix-store", "--version"]).status == 0;
    catch (Exception)
        return false;
}

/**
The NAR's SHA-256 and length equal those of `nix-store --dump` of the same
tree: every node kind, empty directories, files after a subdirectory's
subtree, and the ordering hazard, which NAR's byte order meets differently
from git's.
*/
@("content_addressing.nar.dump")
@system unittest
{
    import std.digest.sha : sha256Of;

    if (!haveNix())
        return skipTest("nix-store is not installed");

    foreach (t; diskOracleTrees())
    {
        const ours = idOf!LiteralNar(t.literal);
        const nar = onDisk(t.literal, "nar", dir => nixDump(dir));
        assert(ours.size == nar.length, text(t.label, ": ", ours.size, " != ", nar.length,
            " bytes\n", t.literal));
        assert(ours.digest == sha256Of(nar), text(t.label, ": ", toSri(ours.digest)[], " != ",
            toSri(sha256Of(nar))[], "\n", t.literal));
    }
}

/**
A fileset whose start roots lie beneath its root, and whose roots NAR orders
by component (`a/b` before `a-c`): the scheme writes the directories above
the roots, and its NAR equals that of the tree holding only the members.
*/
@("content_addressing.nar.startRoots")
@system unittest
{
    import std.digest.sha : sha256Of;

    if (!haveNix())
        return skipTest("nix-store is not installed");

    enum tree = "a/b/x = 1\na/b/d/y = 2\na/c = 3\na-c/z = 4\nq = 5\n";
    enum members = "a/b/x = 1\na/b/d/y = 2\na-c/z = 4\n";
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.unionOf(sets.glob("a/b/**").value, sets.glob("a-c/**").value);
    RecordingExecutor exec;
    LiteralNar scheme;
    const ours = schemeResolve(tree, sets, f, scheme, exec);
    const nar = onDisk(members, "nar-roots", dir => nixDump(dir));
    assert(ours.size == nar.length && ours.digest == sha256Of(nar),
        text(toSri(ours.digest)[], " != ", toSri(sha256Of(nar))[]));

    // A fileset holding nothing is the empty directory.
    LiteralNar nothing;
    const none = schemeResolve(tree, sets, sets.nothing, nothing, exec);
    const empty = onDisk("", "nar-empty", dir => nixDump(dir));
    assert(none.size == empty.length && none.digest == sha256Of(empty));
}

// --------------------------------------------------------------- tee

/**
One walk naming a tree by castore and by git, beside its NAR, gives each the
id it gets alone: castore's and git's entries re-sorted per directory from
NAR's byte order, git's empty directories dropped, castore's kept.
*/
@("content_addressing.tee.parts")
@system unittest
{
    import std.digest.sha : SHA1;

    alias Teed = NarScheme!(SHA256, LiteralRef, CastoreDirectory, GitTree!SHA1);
    foreach (t; oracleTrees())
    {
        const teed = idOf!Teed(t.literal);
        assert(teed.ids[0] == idOf!CastoreScheme(t.literal),
            text(t.label, ": castore ", toCastoreText(teed.ids[0].digest)[], "\n", t.literal));
        assert(teed.ids[1] == idOf!(GitTreeScheme!SHA1)(t.literal), text(t.label, ": git\n",
            t.literal));
        assert(teed.nar == idOf!LiteralNar(t.literal), text(t.label, ": nar\n", t.literal));
    }
}

/**
With start roots beneath the fileset root, a root that is a file, or nothing
at all, the tee's castore id is the fold's and its NAR the stream's.
*/
@("content_addressing.tee.startRoots")
@system unittest
{
    import sparkles.build_primitives.fileset.value : Fileset;

    enum tree = "a/b/x = 1\na/b/d/y = 2\na/c = 3\na-c/z = 4\nq = 5\n";
    auto sets = Filesets(CasePolicy.sensitive);
    const Fileset[4] filesets = [
        sets.unionOf(sets.glob("a/b/**").value, sets.glob("a-c/**").value),
        sets.glob("a/c").value,
        sets.unionOf(sets.glob("a/b/d/y").value, sets.glob("q").value),
        sets.nothing,
    ];
    foreach (i, f; filesets)
    {
        RecordingExecutor exec;
        CastoreNar!LiteralRef teed;
        CastoreScheme fold;
        LiteralNar nar;
        const both = schemeResolve(tree, sets, f, teed, exec);
        assert(both.ids[0] == schemeResolve(tree, sets, f, fold, exec), text("fileset ", i,
            ": castore"));
        assert(both.nar == schemeResolve(tree, sets, f, nar, exec), text("fileset ", i, ": nar"));
    }
}

// What the counting leaf heard, on this test's thread.
private size_t leafFiles;
private ulong leafBytes, leafSizes;

// castore's leaf, counting the files it names and the bytes it is fed.
private struct CountingLeaf
{
    alias Id = DigestLeaf!Blake3.Id;
    private DigestLeaf!Blake3 inner;

    void start(ulong size)
    {
        ++leafFiles;
        leafSizes += size;
        inner.start(size);
    }

    void put(scope const(ubyte)[] bytes)
    {
        leafBytes += bytes.length;
        inner.put(bytes);
    }

    Id finish() => inner.finish();
}

// castore over the counting leaf.
private struct CountingCastore
{
    CastoreDirectory inner;
    alias inner this;
    alias Leaf = CountingLeaf;
}

/**
A tee reads each file once: the leaf hears every file once and every byte
once, from the same reads that write the NAR.
*/
@("content_addressing.tee.readsOnce")
@system unittest
{
    enum tree = "a/b/x = one\na/b/d/y = two\na/c = three\nrun +x = go\nl -> a\nempty/\n";
    leafFiles = leafBytes = leafSizes = 0;
    const teed = idOf!(NarScheme!(SHA256, LiteralRef, CountingCastore))(tree);
    assert(leafFiles == 4, text(leafFiles, " files"));
    assert(leafSizes == 13 && leafBytes == 13, text(leafSizes, " bytes stat-ed, ", leafBytes,
        " read"));
    assert(teed.ids[0] == idOf!CastoreScheme(tree));
    assert(teed.nar == idOf!LiteralNar(tree));
}

// ----------------------------------------------------- failing members

// What the resizing leaf rewrites when it hears its first `start`, on this
// test's thread: after the file was stat-ed, before any byte is read.
private MemVfs* resizeIn;
private string resizePath, resizeTo;

// `L`, rewriting the file `resizePath` to `resizeTo` once, as it starts.
private struct ResizingLeaf(L)
{
    alias Id = L.Id;
    private L inner;

    void start(ulong size)
    {
        if (resizeIn !is null)
        {
            assert(resizeIn.writeFile(resizePath, cast(const(ubyte)[]) resizeTo));
            resizeIn = null;
        }
        inner.start(size);
    }

    void put(scope const(ubyte)[] bytes) { inner.put(bytes); }

    Id finish() => inner.finish();
}

// castore over the resizing leaf, for a tee.
private struct ResizingCastore
{
    CastoreDirectory inner;
    alias inner this;
    alias Leaf = ResizingLeaf!(DigestLeaf!Blake3);
}

/// Resolves `literal` whole with `S`, after `prepare` has had the tree and
/// the executor, opening the root at `at`.
auto resolvePrepared(S)(string literal, scope void delegate(MemVfs*, ref RecordingExecutor) @system prepare,
    string at = "")
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;
    import sparkles.build_primitives.fileset.testing : openFixture;

    auto tree = openFixture(literal);
    auto vfs = &tree.value.get().vfs;
    RecordingExecutor exec;
    prepare(vfs, exec);
    auto root = openRoot!(Rights.readOnly)(vfs, at, ambientAuthority());
    assert(!root.hasError);
    auto sets = Filesets(CasePolicy.sensitive);
    S scheme;
    return resolveScheme(root.value.borrow, sets, sets.everything, scheme, exec);
}

/// Asserts that `r` failed with `schemeFailed`, saying `why`.
void assertSchemeFailed(R)(auto ref R r, string why, string label)
{
    import sparkles.build_primitives.fileset.machine : ResolutionErrorCode;

    assert(r.hasError, label ~ ": gave an id");
    assert(r.error.code == ResolutionErrorCode.schemeFailed && r.error.context == why,
        text(label, ": ", r.error.code, " ", r.error.context));
}

/**
CAM3: a file that grows or shrinks between its `stat` and its last read
fails the resolution, in a fold and in a tee, whose NAR stream reads the
file. A file rewritten at the same size is named by the bytes read, as the
contract says it is not detected.
*/
@("content_addressing.merkle.CAM3.resized")
@system unittest
{
    enum tree = "d/x = one\nl -> d\nempty/\n";
    enum why = "a member changed size while it was read";
    alias Castore = MerkleFold!(CastoreDirectory, ResizingLeaf!(DigestLeaf!Blake3));
    alias Git = MerkleFold!(GitTree!SHA1, ResizingLeaf!(GitTree!SHA1.Leaf));
    alias Tee = NarScheme!(SHA256, LiteralRef, ResizingCastore);

    static auto resizing(S)(string to)
    {
        return resolvePrepared!S(tree, (MemVfs* vfs, ref RecordingExecutor) {
            resizeIn = vfs;
            resizePath = "d/x";
            resizeTo = to;
        });
    }

    static foreach (S; AliasSeq!(Castore, Git, Tee))
    {
        foreach (to; ["one more", "o", ""])
        {
            assertSchemeFailed(resizing!S(to), why, text(S.stringof, " to ", to.length));
            assert(resizeIn is null, "the leaf heard no start");
        }
    }

    // The same size: undetected, and named by what was read.
    enum rewritten = "d/x = two\nl -> d\nempty/\n";
    const same = resizing!Castore("two");
    assert(!same.hasError && same.value == idOf!CastoreScheme(rewritten));
    const teed = resizing!Tee("two");
    assert(!teed.hasError && teed.value.ids[0] == idOf!CastoreScheme(rewritten)
        && teed.value.nar == idOf!LiteralNar(rewritten));
}

/**
CAM4: an entry the resolution could not read leaves the tree without an id,
in every scheme: a mount the walk does not cross, and a file gone between
its directory's listing and its `stat`.
*/
@("content_addressing.merkle.CAM4.incomplete")
@system unittest
{
    enum mounted = "r/a = 1\nr/m/b = 2\n";
    enum vanishing = "d/a = 1\nd/b = 2\n";
    enum fold = "an entry could not be read, so the tree has no id";
    enum stream = "an entry could not be read, so the tree has no NAR";

    static void check(S)(string why)
    {
        const crossing = resolvePrepared!S(mounted, (MemVfs* vfs, ref RecordingExecutor) {
            assert(vfs.mount("r/m"));
        }, "r");
        assertSchemeFailed(crossing, why, S.stringof ~ " over a mount");

        const gone = resolvePrepared!S(vanishing, (MemVfs* vfs, ref RecordingExecutor exec) {
            exec.beforeStats = () { assert(vfs.remove("d/a")); };
        });
        assertSchemeFailed(gone, why, S.stringof ~ " over a vanished file");
    }

    check!CastoreScheme(fold);
    check!(GitTreeScheme!SHA1)(fold);
    check!LiteralNar(stream);
    check!(CastoreNar!LiteralRef)(stream);

    // Without the fault, the same trees have ids.
    assert(!resolvePrepared!CastoreScheme(mounted, (MemVfs*, ref RecordingExecutor) {}, "r")
        .hasError);
    assert(!resolvePrepared!CastoreScheme(vanishing, (MemVfs*, ref RecordingExecutor) {})
        .hasError);
}

/// `nix hash path` of `dir`: the SRI form of its NAR's SHA-256.
string nixHashPath(string dir) @system
{
    import std.process : Config, execute;

    const r = execute(["nix", "--extra-experimental-features", "nix-command", "hash", "path",
        dir], null, Config.stderrPassThrough);
    assert(r.status == 0, text("nix hash path ", dir, ": ", r.output));
    return r.output.strip;
}

/**
CAN4: the text form of a `NarHash` is what `nix hash path` prints for the
same tree, on the hand-written trees, the fixture set and twenty random
trees.
*/
@("content_addressing.nar.CAN4.sri")
@system unittest
{
    if (!haveNix())
        return skipTest("nix-store is not installed");

    foreach (t; diskOracleTrees(20))
    {
        const ours = idOf!LiteralNar(t.literal);
        const theirs = onDisk(t.literal, "sri", dir => nixHashPath(dir));
        assert(toSri(ours.digest)[] == theirs, text(t.label, ": ", toSri(ours.digest)[], " != ",
            theirs, "\n", t.literal));
    }
}

// ------------------------------------------------------- start roots

// A tree, filesets over it whose start roots lie beneath its root, and for
// each, the tree holding only its members: what the scheme must name (CAM1).
private enum rootsTree = "a/b/x = 1\na/b/d/y = 2\na/c = 3\na-c/z = 4\nq = 5\n";

private struct RootsCase
{
    string label;   ///
    string members; /// the tree of the members alone
}

private immutable RootsCase[4] rootsCases = [
    RootsCase("a/b/** ∪ a-c/**", "a/b/x = 1\na/b/d/y = 2\na-c/z = 4\n"),
    RootsCase("a/c", "a/c = 3\n"),
    RootsCase("a/b/d/y ∪ q", "a/b/d/y = 2\nq = 5\n"),
    RootsCase("nothing", ""),
];

// The filesets of `rootsCases`, in order.
private auto rootsFilesets(ref Filesets sets)
{
    import sparkles.build_primitives.fileset.value : Fileset;

    Fileset[4] fs = [
        sets.unionOf(sets.glob("a/b/**").value, sets.glob("a-c/**").value),
        sets.glob("a/c").value,
        sets.unionOf(sets.glob("a/b/d/y").value, sets.glob("q").value),
        sets.nothing,
    ];
    return fs;
}

/**
CAM1 for git: a fileset whose start roots lie beneath its root has the git
tree id `git write-tree` gives the tree holding only its members, in SHA-1
and SHA-256 repositories.
*/
@("content_addressing.git.startRoots")
@system unittest
{
    import sparkles.build_primitives.git_env : runGit;

    try
        cast(void) runGit(["--version"]);
    catch (Exception)
        return skipTest("git is not installed");

    auto sets = Filesets(CasePolicy.sensitive);
    const filesets = rootsFilesets(sets);
    foreach (i, c; rootsCases)
    {
        RecordingExecutor exec;
        GitTreeScheme!SHA1 sha1;
        GitTreeScheme!SHA256 sha256;
        const ours1 = schemeResolve(rootsTree, sets, filesets[i], sha1, exec);
        const ours256 = schemeResolve(rootsTree, sets, filesets[i], sha256, exec);
        const theirs1 = onDisk(c.members, "git-roots", dir => gitWriteTree(dir, "sha1"));
        const theirs256 = onDisk(c.members, "git-roots", dir => gitWriteTree(dir, "sha256"));
        assert(toHex(ours1.digest)[] == theirs1, text(c.label, ": ", toHex(ours1.digest)[], " != ",
            theirs1));
        assert(toHex(ours256.digest)[] == theirs256, text(c.label, " (SHA-256): ",
            toHex(ours256.digest)[], " != ", theirs256));
    }
}

/**
CAM1 for castore: a fileset whose start roots lie beneath its root has the
id `snix-castore ingest` gives the tree holding only its members.
*/
@("content_addressing.castore.startRoots")
@system unittest
{
    import std.file : exists;
    import std.process : environment;

    const snix = environment.get("SPARKLES_SNIX_CASTORE");
    if (snix is null)
        return skipTest("SPARKLES_SNIX_CASTORE is not set");
    assert(snix.exists, snix);

    auto sets = Filesets(CasePolicy.sensitive);
    const filesets = rootsFilesets(sets);
    foreach (i, c; rootsCases)
    {
        RecordingExecutor exec;
        CastoreScheme scheme;
        const ours = schemeResolve(rootsTree, sets, filesets[i], scheme, exec);
        const theirs = onDisk(c.members, "castore-roots", dir => snixIngest(snix, dir));
        assert(toCastoreText(ours.digest)[] == theirs, text(c.label, ": ",
            toCastoreText(ours.digest)[], " != ", theirs));
    }
}

// --------------------------------------------------------- reads once

/**
CAT2, counted at the backend: over the walk alone, a tee of castore, git and
NAR opens one more entry per member file, and reads each file as often as
one scheme alone does: once through to its end, in reads of at most 16 KiB,
and one read more that finds the end.
*/
@("content_addressing.tee.opensOnce")
@system unittest
{
    import sparkles.base.io.errors : OpKind;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : PathScheme, resolveScheme;
    import sparkles.build_primitives.fileset.tree_literal : memTree;

    enum literal = "a/b/x = one\na/b/d/y = two\na/c = three\nrun +x = go\nl -> a\nempty/\nnil = \n";
    auto tree = memTree(literal, spareBytes: 64 * 1024);
    assert(!tree.hasError);
    auto vfs = &tree.value.get().vfs;
    auto big = new ubyte[](40_000);
    foreach (i, ref b; big)
        b = cast(ubyte)(i * 7);
    assert(vfs.writeFile("a/big", big));
    // x, y, c, run and big take one read of data each, big three; each
    // file, nil too, one more that finds its end.
    enum files = 6;
    enum reads = 4 + 3 + files;

    auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());
    assert(!root.hasError);
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;

    // The backend calls of `op` one resolution by `S` makes.
    ulong callsOf(S)(OpKind op)
    {
        RecordingExecutor exec;
        S scheme;
        const before = vfs.count(op);
        const r = resolveScheme(root.value.borrow, sets, f, scheme, exec);
        assert(!r.hasError, r.hasError ? r.error.context : "");
        return vfs.count(op) - before;
    }

    alias Tee = NarScheme!(SHA256, LiteralRef, CastoreDirectory, GitTree!SHA1);
    const walkOpens = callsOf!PathScheme(OpKind.openAt);
    assert(callsOf!PathScheme(OpKind.read) == 0, "the walk alone reads no file");

    assert(callsOf!Tee(OpKind.openAt) == walkOpens + files, text(callsOf!Tee(OpKind.openAt),
        " opens, ", walkOpens, " of them the walk's"));
    assert(callsOf!Tee(OpKind.read) == reads, text(callsOf!Tee(OpKind.read), " reads"));
    static foreach (S; AliasSeq!(CastoreScheme, GitTreeScheme!SHA1, LiteralNar))
    {
        assert(callsOf!S(OpKind.openAt) == walkOpens + files, S.stringof);
        assert(callsOf!S(OpKind.read) == reads, S.stringof);
    }
}

// ------------------------------------------------------ members only

/**
C3: the tree a fileset names holds only the directories on the way to a
member, and the fileset root. An unanchored pattern, which makes the walk
enter every directory, names the same tree as its anchored spelling, and
a tree's empty and hollow directories are not part of it, in every format
and in the tee. The fileset root is named even when it holds nothing.
*/
@("content_addressing.merkle.C3.membersOnly")
@system unittest
{
    import sparkles.build_primitives.fileset.value : Fileset;

    enum tree = "a/b/x = 1\na/b/d/y = 2\na/c = 3\na-c/z = 4\nq = 5\nempty/\nhollow/inner/\n";
    alias Tee = NarScheme!(SHA256, LiteralRef, CastoreDirectory, GitTree!SHA1);
    auto sets = Filesets(CasePolicy.sensitive);

    // Each spelling, and the tree of its members alone.
    static struct Spelling
    {
        Fileset f;
        string members;
    }
    const Spelling[5] spellings = [
        Spelling(sets.glob("q").value, "q = 5\n"),
        Spelling(sets.glob("/q").value, "q = 5\n"),
        Spelling(sets.glob("**/y").value, "a/b/d/y = 2\n"),
        Spelling(sets.everything, "a/b/x = 1\na/b/d/y = 2\na/c = 3\na-c/z = 4\nq = 5\n"),
        Spelling(sets.glob("/nope").value, ""),
    ];
    foreach (i, s; spellings)
    {
        RecordingExecutor exec;
        CastoreScheme castore;
        GitTreeScheme!SHA1 git;
        LiteralNar nar;
        Tee teed;
        const label = text("spelling ", i);
        assert(schemeResolve(tree, sets, s.f, castore, exec) == idOf!CastoreScheme(s.members),
            label);
        assert(schemeResolve(tree, sets, s.f, git, exec) == idOf!(GitTreeScheme!SHA1)(s.members),
            label);
        assert(schemeResolve(tree, sets, s.f, nar, exec) == idOf!LiteralNar(s.members), label);
        const t = schemeResolve(tree, sets, s.f, teed, exec);
        assert(t.ids[0] == idOf!CastoreScheme(s.members) && t.ids[1] == idOf!(GitTreeScheme!SHA1)(
            s.members) && t.nar == idOf!LiteralNar(s.members), label);
    }

    // A tree of empty directories alone is the empty directory.
    assert(idOf!CastoreScheme("empty/\nhollow/inner/\n") == idOf!CastoreScheme(""));
    assert(idOf!LiteralNar("empty/\nhollow/inner/\n") == idOf!LiteralNar(""));
    assert(membersOf("a/\nb -> c/\nd/e = 1/\nf/g/\n") == "b -> c/\nd/e = 1/\n");
}

// ---------------------------------------------------------- outboards

/// `bao-outboard` on each of `paths`: one root and outboard per file, in hex.
string[2][] baoOutboards(string bao, string[] paths) @system
{
    import std.array : split;
    import std.process : Config, execute;

    const r = execute([bao] ~ paths, null, Config.stderrPassThrough);
    assert(r.status == 0, text("bao-outboard: ", r.output));
    string[2][] lines;
    foreach (line; r.output.lineSplitter)
    {
        auto parts = line.split(' ');
        lines ~= [parts[0], parts.length > 1 ? parts[1] : ""];
    }
    assert(lines.length == paths.length, r.output);
    return lines;
}

/// Lowercase hex of `bytes`.
string hexOf(scope const(ubyte)[] bytes) @safe pure
{
    import std.format : format;

    return format!"%(%02x%)"(bytes);
}

/**
C2: the outboard is iroh's. For files of every size around the chunk-group
boundaries, and of seeded random sizes up to 40 groups, the root and the
pre-order outboard equal the ones n0's `bao-tree` computes at iroh's
16 KiB groups. `$SPARKLES_BAO_OUTBOARD` names the oracle; without it the
test is skipped.
*/
@("content_addressing.outboard.baoTree")
@system unittest
{
    import std.file : exists, write;
    import std.path : buildPath;
    import std.process : environment;
    import std.random : uniform;

    const bao = environment.get("SPARKLES_BAO_OUTBOARD");
    if (bao is null)
        return skipTest("SPARKLES_BAO_OUTBOARD is not set");
    assert(bao.exists, bao);

    ulong[] sizes = [0, 1, 1023, 1024, 1025, chunkGroupSize - 1, chunkGroupSize,
        chunkGroupSize + 1, 2 * chunkGroupSize, 3 * chunkGroupSize - 5, 4 * chunkGroupSize,
        5 * chunkGroupSize + 1, 8 * chunkGroupSize, 8 * chunkGroupSize + 1, 13 * chunkGroupSize];
    auto rng = Mt19937(2026_11_09);
    foreach (_; 0 .. 40)
        sizes ~= uniform(0, 40 * chunkGroupSize, rng);

    const dir = scratchTree("bao");
    scope (exit) rmdirRecurse(dir);
    string[] paths;
    ubyte[][] contents;
    foreach (i, size; sizes)
    {
        auto bytes = new ubyte[](cast(size_t) size);
        foreach (ref b; bytes)
            b = cast(ubyte) uniform(0, 256, rng);
        paths ~= buildPath(dir, text(i));
        write(paths[$ - 1], bytes);
        contents ~= bytes;
    }

    const theirs = baoOutboards(bao, paths);
    OutboardLeaf leaf;
    foreach (i, bytes; contents)
    {
        leaf.start(bytes.length);
        leaf.put(bytes);
        const root = leaf.finish();
        assert(hexOf(root) == theirs[i][0], text("size ", bytes.length, ": root"));
        assert(hexOf(leaf.outboard) == theirs[i][1], text("size ", bytes.length, ": outboard\n",
            hexOf(leaf.outboard), "\n", theirs[i][1]));
    }
}

/// A store of supplied trees, by path from the fileset root.
private struct TreeStore
{
    SuppliedTree[string] trees;
    string[] asked;

    bool find(scope const(char)[] dir, scope const(char)[] name, out SuppliedTree tree) @safe
    {
        const path = dir.length ? text(dir, "/", name) : name.idup;
        asked ~= path;
        if (auto t = path in trees)
        {
            tree = *t;
            return true;
        }
        return false;
    }
}

/**
CAO1: a castore fold given supplied trees names those files without opening
them. Counted at the backend, it opens exactly the supplied files fewer
than the plain castore scheme, and gives the same id. A supplied tree whose
top record does not chain to its root fails the resolution before the file
is read.
*/
@("content_addressing.outboard.CAO1.supplied")
@system unittest
{
    import sparkles.base.io.errors : OpKind;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;
    import sparkles.build_primitives.fileset.tree_literal : memTree;

    enum literal = "a/b/x = one\na/c = three\nq = five\nempty/\n";
    auto mem = memTree(literal, spareBytes: 256 * 1024);
    assert(!mem.hasError);
    auto vfs = &mem.value.get().vfs;

    // Two large files, whose trees are supplied, and q, of a single group.
    ubyte[][string] bytes;
    foreach (path, size; ["a/big": 40_000, "a/b/huge": 9 * chunkGroupSize + 3, "q": 5])
    {
        auto b = new ubyte[](size);
        foreach (i, ref x; b)
            x = cast(ubyte)(i * 13 + size);
        assert(vfs.writeFile(path, b));
        bytes[path] = b;
    }
    TreeStore store;
    foreach (path, b; bytes)
    {
        OutboardLeaf leaf;
        leaf.start(b.length);
        leaf.put(b);
        const root = leaf.finish();
        store.trees[path] = SuppliedTree(root, b.length, leaf.outboard.dup);
    }

    auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());
    assert(!root.hasError);
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;
    alias Supplied = MerkleFold!(CastoreDirectory, CastoreDirectory.Leaf, OutboardSupply!TreeStore);

    RecordingExecutor exec;
    CastoreScheme plain;
    auto opens = vfs.count(OpKind.openAt);
    const want = resolveScheme(root.value.borrow, sets, f, plain, exec);
    assert(!want.hasError);
    const plainOpens = vfs.count(OpKind.openAt) - opens;

    Supplied supplied;
    supplied.supply.store = store;
    opens = vfs.count(OpKind.openAt);
    const reads = vfs.count(OpKind.read);
    const got = resolveScheme(root.value.borrow, sets, f, supplied, exec);
    assert(!got.hasError, got.hasError ? got.error.context : "");
    assert(got.value == want.value, "the id is the one reading gives");
    assert(vfs.count(OpKind.openAt) - opens == plainOpens - 3, text(vfs.count(OpKind.openAt) - opens,
        " opens, ", plainOpens, " without supplied trees"));
    // x and c are read, each once with data and once at its end.
    assert(vfs.count(OpKind.read) - reads == 4, text(vfs.count(OpKind.read) - reads, " reads"));
    assert(supplied.supply.store.asked.length == 5, text(supplied.supply.store.asked));

    // A flipped top record is refused, and nothing beneath it is read.
    Supplied broken;
    broken.supply.store = store;
    const good = store.trees["a/b/huge"].outboard;
    auto bad = good.dup;
    bad[0] ^= 1;
    broken.supply.store.trees["a/b/huge"].outboard = bad;
    assertSchemeFailed(resolveScheme(root.value.borrow, sets, f, broken, exec),
        "a supplied tree does not chain to its root", "a flipped top record");

    // A tree that holds together but is not the size its file now has is
    // stale: it names another file, and is refused rather than trusted.
    assert(vfs.writeFile("q", bytes["q"] ~ cast(ubyte) 0));
    Supplied stale;
    stale.supply.store = store;
    // The trees are shared with `broken`'s store: put the top record back.
    stale.supply.store.trees["a/b/huge"].outboard = good.dup;
    assertSchemeFailed(resolveScheme(root.value.borrow, sets, f, stale, exec),
        "a supplied tree's size is not its file's", "a stale tree");
}

// ── M7: the subtree cache ────────────────────────────────────────────────

/// A validator that lies: every recorded file is unchanged.
struct TrustingValidator
{
    bool unchanged(in FsoFingerprint recorded, in FsoFingerprint now, long stampNs) const
        @safe pure nothrow @nogc => true;
}

/// A validator that compares the fingerprint but not the change time, as a
/// cache that keeps only modification times does.
struct MtimeValidator
{
    bool unchanged(in FsoFingerprint recorded, in FsoFingerprint now, long stampNs) const
        @safe pure nothrow @nogc
        => recorded.size == now.size && recorded.mtimeNs == now.mtimeNs
        && recorded.device == now.device && recorded.inode == now.inode;
}

/// A validator that trusts a matching fingerprint however close to the
/// recording it was taken: racy-git's bug.
struct RacyValidator
{
    bool unchanged(in FsoFingerprint recorded, in FsoFingerprint now, long stampNs) const
        @safe pure nothrow @nogc => recorded == now;
}

/// One run's outcome: its id, and the record it leaves for the next.
struct CachedRun
{
    string id;      /// `toCastoreText` of the root, or why the run failed
    ubyte[] record; /// the encoded cache
    size_t filesRead, filesReused, dirsReused, dirsEncoded; ///
}

/**
Resolves the tree in `vfs` with the castore fold and a cache loaded from
`previous` (none when empty), stamped with the backend's clock.
*/
CachedRun cachedRun(V = StatValidator)(ref MemVfs vfs, const(ubyte)[] previous, V validator = V.init)
    @system
{
    import std.array : Appender;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    auto sets = Filesets(CasePolicy.sensitive);
    auto root = openRoot!(Rights.readOnly)(&vfs, "", ambientAuthority());
    assert(!root.hasError);
    RecordingExecutor exec;
    CachedFold!(CastoreDirectory, CastoreDirectory.Leaf, V) fold;
    fold.cache.validator = validator;
    if (previous.length)
        assert(!fold.cache.load(previous).hasError, "a cache this module wrote loads");
    fold.cache.begin(vfs.clockNs);
    const got = resolveScheme(root.value.borrow, sets, sets.everything, fold, exec);
    CachedRun run;
    if (got.hasError)
    {
        run.id = got.error.context.idup;
        return run;
    }
    run.id = toCastoreText(got.value.digest).idup;
    Appender!(ubyte[]) bytes;
    assert(fold.cache.encode(bytes));
    run.record = bytes[];
    run.filesRead = fold.cache.filesRead;
    run.filesReused = fold.cache.filesReused;
    run.dirsReused = fold.cache.dirsReused;
    run.dirsEncoded = fold.cache.dirsEncoded;
    return run;
}

/// The id of the tree in `vfs` with no cache at all.
string coldId(ref MemVfs vfs) @system
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    auto sets = Filesets(CasePolicy.sensitive);
    auto root = openRoot!(Rights.readOnly)(&vfs, "", ambientAuthority());
    RecordingExecutor exec;
    CastoreScheme plain;
    const got = resolveScheme(root.value.borrow, sets, sets.everything, plain, exec);
    return got.hasError ? got.error.context.idup : toCastoreText(got.value.digest).idup;
}

/// What a script does to the tree between two runs.
enum Change : ubyte
{
    sameSizeRestoredTimes, /// rewrite at the same size, mtime put back (`touch -r`)
    resize,                /// rewrite at another size
    add,                   /// a new file
    remove,                /// a file removed
    recreate,              /// removed and written again: same size, mtime, often inode
    chmod,                 /// the executable bit flipped
    relink,                /// a link's target changed
    rename,                /// a file moved to a new name
}

/**
M7's oracle. Runs the cached fold over `literal` and then after each change
of `script`, each run loading the record the one before left, and compares
every id with a cold run's. Returns the first divergence, or `null`.

The backend's clock moves by `tickNs` before each change, and each run is
stamped with it. A tick of zero places a change in the same timestamp tick
as the run before it.
*/
string cacheDivergence(V = StatValidator)(string literal, const(Change)[] script, long tickNs,
    ulong seed = 1, V validator = V.init) @system
{
    import std.algorithm.searching : canFind, endsWith;

    auto made = openFixture(literal);
    auto vfs = &made.value.get().vfs;
    vfs.clockNs = 10_000_000_000;
    string[] files, links;
    foreach (line; literal.lineSplitter)
    {
        const l = line.strip;
        if (!l.length || l.endsWith("/"))
            continue;
        if (l.canFind(" -> "))
            links ~= l[0 .. l.indexOf(" -> ")];
        else
        {
            const name = l.canFind(" = ") ? l[0 .. l.indexOf(" = ")] : l;
            files ~= name.endsWith(" +x") ? name[0 .. $ - 3] : name;
        }
    }
    auto rng = Mt19937(cast(uint) seed);
    const(ubyte)[] record;
    foreach (step; 0 .. script.length + 1)
    {
        if (step)
        {
            vfs.clockNs += tickNs;
            const what = text(change(*vfs, script[step - 1], files, links, rng));
            const cold = coldId(*vfs);
            const warm = cachedRun!V(*vfs, record, validator);
            if (warm.id != cold)
                return text("after change ", step, " (", script[step - 1], what, "): the cache gives ",
                    warm.id, ", a cold run ", cold);
            record = warm.record;
        }
        else
        {
            const first = cachedRun!V(*vfs, null, validator);
            if (first.id != coldId(*vfs))
                return "the first run differs from a cold one";
            record = first.record;
        }
    }
    return null;
}

// Applies `c` to a random file or link; returns what it changed.
private string change(ref MemVfs vfs, Change c, ref string[] files, ref string[] links,
    ref Mt19937 rng) @system
{

    const ns = vfs.clockNs;
    if (!files.length && c != Change.add && c != Change.relink)
        c = Change.add;
    if (c == Change.relink && !links.length)
        c = Change.add;
    const pick = files.length ? uniform(0, files.length, rng) : 0;
    final switch (c)
    {
        case Change.sameSizeRestoredTimes:
        {
            const path = files[pick];
            auto bytes = vfs.contents(path).dup;
            if (!bytes.length)
                bytes = cast(ubyte[]) "".dup;
            foreach (ref b; bytes)
                b = cast(ubyte)(b == 'Q' ? 'R' : 'Q');
            const exec = isExecutable(vfs, path);
            assert(vfs.writeFile(path, bytes, exec));
            // `touch -r`: the mtime the file had, which the fixtures leave at 0.
            assert(vfs.setMtime(path, 0));
            return " " ~ path;
        }
        case Change.resize:
        {
            const path = files[pick];
            auto bytes = vfs.contents(path).dup ~ cast(ubyte) '+';
            assert(vfs.writeFile(path, bytes, isExecutable(vfs, path)));
            assert(vfs.setMtime(path, ns));
            return " " ~ path;
        }
        case Change.add:
        {
            const path = text("added", uniform(0, 1_000_000, rng));
            assert(vfs.writeFile(path, cast(const(ubyte)[]) path));
            files ~= path;
            return " " ~ path;
        }
        case Change.remove:
        {
            const path = files[pick];
            assert(vfs.remove(path));
            files = files[0 .. pick] ~ files[pick + 1 .. $];
            return " " ~ path;
        }
        case Change.recreate:
        {
            const path = files[pick];
            auto bytes = vfs.contents(path).dup;
            foreach (ref b; bytes)
                b = cast(ubyte)(b == 'Q' ? 'R' : 'Q');
            const exec = isExecutable(vfs, path);
            assert(vfs.remove(path));
            assert(vfs.writeFile(path, bytes, exec));
            assert(vfs.setMtime(path, 0));
            return " " ~ path;
        }
        case Change.chmod:
        {
            const path = files[pick];
            assert(vfs.writeFile(path, vfs.contents(path).dup, !isExecutable(vfs, path)));
            return " " ~ path;
        }
        case Change.relink:
        {
            const path = links[uniform(0, links.length, rng)];
            assert(vfs.remove(path));
            assert(vfs.symlink(path, text("elsewhere", uniform(0, 1_000_000, rng))));
            return " " ~ path;
        }
        case Change.rename:
        {
            const path = files[pick];
            const to = text("moved", uniform(0, 1_000_000, rng));
            assert(vfs.rename(path, to));
            files[pick] = to;
            return " " ~ path ~ " to " ~ to;
        }
    }
}

private bool isExecutable(ref MemVfs vfs, string path) @system
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    import std.string : lastIndexOf;

    auto root = openRoot!(Rights.readOnly)(&vfs, "", ambientAuthority());
    const slash = path.lastIndexOf('/');
    if (slash < 0)
        return root.value.statAt(path).value.executable;
    auto dir = root.value.walk(path[0 .. slash]);
    return dir.value.statAt(path[slash + 1 .. $]).value.executable;
}

/**
FSC1, M7's gate: the cache is advisory. A run with a cache recorded on the
same tree gives the id a cold run gives, on every oracle tree, and reads no
file and encodes no directory; with the cache deleted it gives that id too,
reading every file.
*/
@("content_addressing.cache.FSC1.advisory")
@system unittest
{
    size_t trees, reused;
    foreach (t; oracleTrees(50))
    {
        auto made = openFixture(t.literal);
        auto vfs = &made.value.get().vfs;
        vfs.clockNs = 10_000_000_000;
        const cold = coldId(*vfs);
        const first = cachedRun(*vfs, null);
        assert(first.id == cold, t.label);
        assert(first.filesReused == 0 && first.dirsReused == 0, t.label);

        vfs.clockNs += 3_000_000_000;
        const warm = cachedRun(*vfs, first.record);
        assert(warm.id == cold, t.label);
        assert(warm.filesRead == 0 && warm.dirsEncoded == 0,
            text(t.label, ": ", warm.filesRead, " files read, ", warm.dirsEncoded, " directories encoded"));
        assert(warm.dirsReused == first.dirsEncoded, t.label);
        const third = cachedRun(*vfs, warm.record);
        assert(third.id == cold && third.dirsEncoded == 0, text(t.label, ": a reused run records what it reused"));

        const deleted = cachedRun(*vfs, null);
        assert(deleted.id == cold && deleted.filesRead == first.filesRead, t.label);
        ++trees;
        reused += warm.filesReused;
    }
    assert(trees > 50 && reused > 500, text(trees, " trees, ", reused, " files reused"));
}

/// FSC1 through changes: the cached id equals a cold run's after every
/// change of every kind, on random trees, with changes in the same tick
/// as the run before them and in later ones.
@("content_addressing.cache.FSC1.throughChanges")
@system unittest
{
    import std.traits : EnumMembers;

    static immutable Change[] every = [EnumMembers!Change];
    size_t scripts;
    foreach (t; oracleTrees(40)[5 .. $])
        foreach (tick; [0L, 1_000_000_000L, 3_000_000_000L])
        {
            auto rng = Mt19937(cast(uint)(scripts + 7));
            Change[] script;
            foreach (_; 0 .. 12)
                script ~= every[uniform(0, every.length, rng)];
            const why = cacheDivergence(t.literal, script, tick, scripts);
            assert(why is null, text(t.label, ", tick ", tick, ": ", why));
            ++scripts;
        }
    assert(scripts > 100);
}

/**
M7's fault injection: the oracle is tested, not only the cache. A validator
that reports a changed file unchanged must make `cacheDivergence` fail,
for each way a `stat` comparison can be fooled; the real one passes the same
scripts.
*/
@("content_addressing.cache.M7.faultInjection")
@system unittest
{
    enum literal = "a/x = abcd\na/y = efgh\nb/z = ijkl\nl -> a/x\n";
    enum tick = 3_000_000_000L;
    // Wait a tick so the first record is trusted, then rewrite in place.
    static immutable Change[] rewrite = [Change.add, Change.sameSizeRestoredTimes,
        Change.sameSizeRestoredTimes, Change.sameSizeRestoredTimes];
    assert(cacheDivergence!TrustingValidator(literal, rewrite, tick) !is null,
        "a validator that trusts everything is caught");
    assert(cacheDivergence!MtimeValidator(literal, rewrite, tick) !is null,
        "a rewrite whose modification time was put back is caught");
    assert(cacheDivergence(literal, rewrite, tick) is null);

    // A change in the same tick as the run that recorded the file: the
    // fingerprint is identical, and only the stamp rule notices.
    static immutable Change[] racy = [Change.recreate, Change.recreate, Change.recreate,
        Change.sameSizeRestoredTimes, Change.sameSizeRestoredTimes];
    assert(cacheDivergence!RacyValidator(literal, racy, 0) !is null,
        "a validator without the stamp rule is caught");
    assert(cacheDivergence(literal, racy, 0) is null);
}

/// FSC4: a change deep in the tree re-encodes the directories on its path
/// and reuses every other; only the changed file is read.
@("content_addressing.cache.FSC4.pathUpward")
@system unittest
{
    auto made = openFixture("a/b/c/deep = 1\na/b/side = 2\na/other/o = 3\ntop = 4\n");
    auto vfs = &made.value.get().vfs;
    vfs.clockNs = 10_000_000_000;
    const first = cachedRun(*vfs, null);
    assert(first.dirsEncoded == 5);
    vfs.clockNs += 3_000_000_000;
    assert(vfs.writeFile("a/b/c/deep", cast(const(ubyte)[]) "22"));
    vfs.clockNs += 3_000_000_000;
    const after = cachedRun(*vfs, first.record);
    assert(after.id == coldId(*vfs));
    // a/b/c, a/b, a and the root are re-encoded; a/other is reused.
    assert(after.dirsEncoded == 4 && after.dirsReused == 1, text(after));
    assert(after.filesRead == 1 && after.filesReused == 3, text(after));
}

/**
FSC5, FSC6: `load` rejects a cache whole when it is truncated, damaged, of
another format or of another scheme, and a run after a rejection reads
everything and still gives the right id.
*/
@("content_addressing.cache.FSC5.rejections")
@system unittest
{
    import std.array : Appender;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    auto made = openFixture("a/x = 1\nb = 2\nl -> b\n");
    auto vfs = &made.value.get().vfs;
    vfs.clockNs = 10_000_000_000;
    const good = cachedRun(*vfs, null).record;

    SubtreeCache!(CastoreDirectory, CastoreDirectory.Leaf) c;
    assert(c.load(good).value == 2 && c.loadedDirs == 2);
    assert(c.load(good[0 .. 10]).error == CacheRejection.truncated);
    assert(c.loadedDirs == 0, "a rejected cache leaves nothing loaded");
    assert(c.load(good[0 .. $ - 1]).error == CacheRejection.truncated);
    auto flipped = good.dup;
    flipped[$ / 2] ^= 1;
    assert(c.load(flipped).error == CacheRejection.damaged);
    auto versioned = good.dup;
    versioned[8] ^= 0xff;
    assert(c.load(versioned).error == CacheRejection.otherFormat);

    // A cache of another file identity.
    auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    RecordingExecutor exec;
    // The same layout as castore's, with git's framed blobs: another file identity.
    CachedFold!(CastoreDirectory, FramedLeaf!(Blake3, "blob")) framed;
    framed.cache.begin(vfs.clockNs);
    assert(!resolveScheme(root.value.borrow, sets, sets.everything, framed, exec).hasError);
    Appender!(ubyte[]) framedBytes;
    assert(framed.cache.encode(framedBytes));
    assert(c.load(framedBytes[]).error == CacheRejection.otherScheme);
    // Every rejected cache leaves a run cold, and right.
    vfs.clockNs += 3_000_000_000;
    foreach (bad; [flipped, versioned, framedBytes[], good[0 .. 10]])
    {
        CachedFold!CastoreDirectory fold;
        assert(fold.cache.load(bad).hasError);
        fold.cache.begin(vfs.clockNs);
        const id = resolveScheme(root.value.borrow, sets, sets.everything, fold, exec);
        assert(toCastoreText(id.value.digest) == coldId(*vfs));
        assert(fold.cache.filesRead == 2 && fold.cache.filesReused == 0);
    }

    // A run that did not complete records nothing.
    CachedFold!CastoreDirectory unfinished;
    unfinished.cache.begin(0);
    Appender!(ubyte[]) none;
    assert(!unfinished.cache.encode(none) && none[].length == 0);
}

/// FSC3: `StatValidator` accepts an equal fingerprint only when it was
/// recorded at least the margin before its run's stamp.
@("content_addressing.cache.FSC3.statValidator")
@safe pure nothrow @nogc unittest
{
    const fp = FsoFingerprint(5, 1, 9, 100, 1_000);
    StatValidator v;
    v.marginNs = 10;
    assert(v.unchanged(fp, fp, 1_011));
    assert(!v.unchanged(fp, fp, 1_010), "a change time within the margin is racy");
    foreach (i; 0 .. 5)
    {
        FsoFingerprint other = fp;
        final switch (i)
        {
            case 0: other.size++; break;
            case 1: other.device++; break;
            case 2: other.inode++; break;
            case 3: other.mtimeNs++; break;
            case 4: other.ctimeNs++; break;
        }
        assert(!v.unchanged(fp, other, 10_000));
    }
}

/// FSC3: a change time a caller can set, as Windows's can be, proves
/// nothing, so a backend reporting one gives no fingerprint and the cache
/// reads every file again: correct, only slower.
@("content_addressing.cache.FSC3.settableChangeTime")
@system unittest
{
    auto made = openFixture("a/x = 1\nb = 2\n");
    auto vfs = &made.value.get().vfs;
    vfs.ctimeSettable = true;
    vfs.clockNs = 10_000_000_000;
    const first = cachedRun(*vfs, null);
    vfs.clockNs += 3_000_000_000;
    const warm = cachedRun(*vfs, first.record);
    assert(warm.id == coldId(*vfs));
    assert(warm.filesRead == 2 && warm.filesReused == 0 && warm.dirsReused == 0, text(warm));
}
