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
import std.digest.sha : SHA256;
import std.file : rmdirRecurse;
import std.random : Mt19937;
import std.string : strip;

import sparkles.base.vfs.mem : MemVfs;
import sparkles.base.vfs.types : Rights;

import sparkles.build_primitives.content_addressing.castore;
import sparkles.build_primitives.content_addressing.git;
import sparkles.build_primitives.content_addressing.merkle;
import sparkles.build_primitives.content_addressing.nar;
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

/// Runs `oracle` on `tree` materialized in a scratch directory.
string onDisk(string tree, string label, string delegate(string dir) @system oracle) @system
{
    const dir = scratchTree(label);
    scope (exit) rmdirRecurse(dir);
    materialize(tree, dir);
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
