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
import std.random : Mt19937;
import std.string : lineSplitter, strip;

import sparkles.base.hash.blake3 : Blake3;
import sparkles.base.vfs.mem : MemVfs;
import sparkles.base.vfs.types : Rights;

import sparkles.build_primitives.content_addressing.castore;
import sparkles.build_primitives.content_addressing.git;
import sparkles.build_primitives.content_addressing.merkle;
import sparkles.build_primitives.content_addressing.nar;
import sparkles.build_primitives.content_addressing.outboard;
import sparkles.build_primitives.fileset.fso : EntryOrder;
import sparkles.build_primitives.fileset.pattern : CasePolicy;
import sparkles.build_primitives.fileset.scheme : FsoRef;
import sparkles.build_primitives.fileset.testing : RecordingExecutor, fixtureSet, materialize,
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
auto idOf(S)(string literal)
{
    auto sets = Filesets(CasePolicy.sensitive);
    RecordingExecutor exec;
    S scheme;
    return schemeResolve(literal, sets, sets.everything, scheme, exec);
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
    auto bad = broken.supply.store.trees["a/b/huge"].outboard.dup;
    bad[0] ^= 1;
    broken.supply.store.trees["a/b/huge"].outboard = bad;
    assertSchemeFailed(resolveScheme(root.value.borrow, sets, f, broken, exec),
        "a supplied tree does not chain to its root", "a flipped top record");
}
