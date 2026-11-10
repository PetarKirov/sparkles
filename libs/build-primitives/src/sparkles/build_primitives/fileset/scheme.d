/**
The scheme seam (FSS1–FSS8): a resolution consumed by a scheme, whose
result is the resolution's (FSE4).

A scheme is a struct that declares, as enums, how it consumes a resolution,
and implements what that declaration calls for:

$(TABLE
$(TR $(TH Member) $(TH Meaning))
$(TR $(TD `enum order`) $(TD an `EntryOrder` (FSS1); default `none`))
$(TR $(TD `enum metadata`) $(TD an `FsoMetadata` mask (FSS2); default `none`))
$(TR $(TD `enum traversal`) $(TD a `Traversal` (FSS3); default `stream`))
$(TR $(TD `alias Result`) $(TD what the resolution returns))
$(TR $(TD `bool incomplete(path, ErrorKind)`) $(TD hears each entry that
    could not be read (FSE2); `false` aborts))
$(TR $(TD `bool visit(path, entries, empty, ref exec)`) $(TD a stream's
    directory, before its subdirectories; `false` aborts))
$(TR $(TD `Result finish()`) $(TD a stream's result, after all of it))
$(TR $(TD `bool leave(path, ref exec)`) $(TD optional, a stream's: hears
    that a directory and everything beneath it are done; `false` aborts))
$(TR $(TD `alias Value`) $(TD a fold's value of one directory))
$(TR $(TD `bool fold(path, entries, empty, ref exec, out Value)`) $(TD a
    fold's directory, after its subdirectories; `false` aborts))
$(TR $(TD `Result finish(ref Value root)`) $(TD a fold's result, from the
    fileset root's value))
$(TR $(TD `string failure()`) $(TD optional: why it aborted))
)

A fold that declares `EntryOrder.none` does not compile (FSS5): a value
computed over listing order is silently different on another host.

A stream sees its directories depth first, each before its subdirectories
and these in byte order. A serial format, which writes a directory's later
entries after the whole of an earlier subdirectory, declares `leave`: each
directory's `leave` comes once its subtree is done, and until then the
references the directory's `visit` was given stay valid, so the scheme can
read its remaining files then (A19).

Each entry is a `SchemeEntry`: the name, the node (FSO1), the declared
metadata, and an `FsoRef` — the directory handle holding the entry and its
name (FSD5), never bytes and never a digest (FSS4). A scheme reads content
itself: it opens a file through that handle during the call, and reads it
then, or hands the open file to work it starts with `exec.spawn` when it
wants the reads concurrent. The executor admits that work through the budget the walk
shares (FSS6), and the resolution does not finish until it has all run
(FSS7). Because a scheme locates an entry by handle and name, it can just as
well look up a tree supplied out of band — a sibling `.idsig`, an outboard
store — and verify against that without reading the entry (FSS8).

A scheme that aborts makes the resolution fail with `schemeFailed`: its
result would be wrong, not merely incomplete (FSE1).
*/
module sparkles.build_primitives.fileset.scheme;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.io.errors : ErrorKind;
import sparkles.base.text.errors : NoGcHook;
import sparkles.base.vfs.handles : DirRef;
import sparkles.base.vfs.types : Rights;

import sparkles.build_primitives.fileset.driver : FilesetDriver;
import sparkles.build_primitives.fileset.fso : EntryOrder, FsoFingerprint, FsoMetadata, FsoNode, SchemeShape,
    Traversal;
import sparkles.build_primitives.fileset.machine : Resolution, ResolutionError, ResolutionErrorCode,
    ResolutionLimits, StepKind, UnitEntry, noChild, noDir;
import sparkles.build_primitives.fileset.value : Fileset, Filesets;

/**
What scheme `S` declares. Instantiating it for a fold that declares
`EntryOrder.none` fails to compile (FSS5).
*/
template shapeOf(S)
{
    static if (__traits(hasMember, S, "order"))
        private enum EntryOrder order_ = S.order;
    else
        private enum EntryOrder order_ = EntryOrder.none;
    static if (__traits(hasMember, S, "metadata"))
        private enum FsoMetadata metadata_ = S.metadata;
    else
        private enum FsoMetadata metadata_ = FsoMetadata.none;
    static if (__traits(hasMember, S, "traversal"))
        private enum Traversal traversal_ = S.traversal;
    else
        private enum Traversal traversal_ = Traversal.stream;

    private enum bool leave_ = __traits(hasMember, S, "leave");
    static assert(!(traversal_ == Traversal.fold && leave_),
        S.stringof ~ " is a fold with `leave`: a fold already sees each directory "
        ~ "after its subtree");
    static assert(!(traversal_ == Traversal.fold && order_ == EntryOrder.none),
        S.stringof ~ " is a fold over EntryOrder.none: a value over listing order "
        ~ "differs between runs and hosts (FSS5)");

    enum SchemeShape shapeOf = SchemeShape(order_, metadata_, traversal_, leave_);
}

/// The reference a scheme gets for an entry (FSS4, FSD5): the handle of the
/// directory holding it, and its name. It is borrowed for the call it is
/// passed to: the driver closes the directory once the call returns, so
/// work spawned for later opens its files first and owns those handles. The
/// handle is not alive for an entry of a directory above the start roots,
/// which was never opened.
struct FsoRef(V, Rights R)
{
    DirRef!(V, R) dir;  ///
    const(char)[] name; ///
}

/**
One entry handed to a scheme. For a fold, a subdirectory's `value` is the
one its own `fold` produced.
*/
struct SchemeEntry(V, Rights R, Value = void)
{
    const(char)[] name;  ///
    FsoNode node;        /// FSO1
    bool hasMtime;       /// FSS2
    long mtimeNs;        /// ditto
    bool hasFingerprint; /// FSC2: a member file's, when declared
    FsoFingerprint fingerprint; /// ditto
    FsoRef!(V, R) ref_;  /// FSS4

    static if (!is(Value == void))
    {
        private Value[] values_;
        private uint child_ = noChild;

        /// A subdirectory's value; only for a directory.
        ref inout(Value) value() inout return
        in (child_ != noChild, "only a directory has a value")
            => values_[child_];
    }
}

/// The entries of one directory, in the scheme's declared order.
struct SchemeEntries(V, Rights R, Value, Units)
{
    private Units units;
    private DirRef!(V, R) dir;
    static if (!is(Value == void))
        private Value[] values;

    ///
    bool empty() const => units.empty;
    ///
    size_t length() const => units.length;
    ///
    void popFront() { units.popFront(); }

    ///
    SchemeEntry!(V, R, Value) front()
    {
        const UnitEntry u = units.front;
        SchemeEntry!(V, R, Value) e;
        e.name = u.name;
        e.node = u.node;
        e.hasMtime = u.hasMtime;
        e.mtimeNs = u.mtimeNs;
        e.hasFingerprint = u.hasFingerprint;
        e.fingerprint = u.fingerprint;
        e.ref_ = FsoRef!(V, R)(dir, u.name);
        static if (!is(Value == void))
        {
            e.values_ = values;
            e.child_ = u.child;
        }
        return e;
    }
}

/// What a resolution consumed by `S` returns (FSE4).
template SchemeResult(S)
{
    alias SchemeResult = Expected!(S.Result, ResolutionError, NoGcHook);
}

/**
Resolves `f` beneath `root` into `scheme`, running each batch, and the
scheme's spawned work, on `exec`. Returns the scheme's result, or why the
resolution failed; in either case only once the scheme's spawned work is
done (FSS7).
*/
SchemeResult!S resolveScheme(V, Rights R, S, Exec)(DirRef!(V, R) root, ref const Filesets sets,
    Fileset f, ref S scheme, ref Exec exec, ResolutionLimits limits = ResolutionLimits.init,
    size_t budget = 4096)
{
    import sparkles.base.vfs.types : SymlinkPolicy;

    enum shape = shapeOf!S;
    enum isFold = shape.traversal == Traversal.fold;
    static if (isFold)
        alias Value = S.Value;
    else
        alias Value = void;

    const followLinks = root.policy.symlinks == SymlinkPolicy.beneath;
    auto m = Resolution(sets, f, limits, followLinks, false, shape);
    auto driver = FilesetDriver!(V, R)(limits.maxFrames);
    auto cursor = m.start();
    static if (isFold)
        Value[] values; // each finished directory's, its parent's children last

    SchemeResult!S fail(ResolutionError e)
    {
        exec.join();
        return err!(S.Result, NoGcHook)(e);
    }

    SchemeResult!S aborted()
    {
        static if (__traits(hasMember, S, "failure"))
            const string why = scheme.failure;
        else
            const string why = "the scheme failed";
        return fail(ResolutionError(ResolutionErrorCode.schemeFailed, ResolutionError.init.kind, why));
    }

    for (;;)
    {
        StepKind kind;
        if (!m.step(sets, cursor, budget, kind))
            return fail(m.error);
        // A unit's directory stays open while the scheme sees it.
        if (kind != StepKind.unit)
            driver.retire(m.retired);
        final switch (kind)
        {
            case StepKind.needIO:
                exec.run(m.batch, (size_t i) { driver.perform(m, root, i); });
                break;
            case StepKind.unit:
                const dirId = m.unitDir;
                auto dir = dirId == noDir ? DirRef!(V, R).init : driver.borrowDir(dirId);
                static if (isFold)
                {
                    size_t children;
                    foreach (u; m.unitEntries)
                        children += u.child != noChild;
                    const base = values.length - children;
                    auto entries = SchemeEntries!(V, R, Value, typeof(m.unitEntries()))(
                        m.unitEntries, dir, values[base .. $]);
                    Value v;
                    const okay = scheme.fold(m.unitPath, entries, m.unitEmpty, exec, v);
                    driver.retire(m.retired);
                    if (!okay)
                        return aborted();
                    values.length = base;
                    values ~= v;
                }
                else
                {
                    auto entries = SchemeEntries!(V, R, Value, typeof(m.unitEntries()))(
                        m.unitEntries, dir);
                    const okay = scheme.visit(m.unitPath, entries, m.unitEmpty, exec);
                    driver.retire(m.retired);
                    if (!okay)
                        return aborted();
                }
                break;
            case StepKind.leave:
                static if (shape.leave)
                {
                    if (!scheme.leave(m.leftPath, exec))
                        return aborted();
                }
                else
                    assert(0, "only a scheme with `leave` hears one");
                break;
            case StepKind.incomplete:
                if (!scheme.incomplete(m.incompletePath, m.incompleteKind))
                    return aborted();
                break;
            case StepKind.ignoreDecision:
            case StepKind.budget:
                break;
            case StepKind.done:
                exec.join();
                static if (isFold)
                {
                    assert(values.length == 1, "a fold ends with the fileset root's value");
                    return ok!(ResolutionError, NoGcHook)(scheme.finish(values[0]));
                }
                else
                    return ok!(ResolutionError, NoGcHook)(scheme.finish());
        }
    }
}

/**
A stream scheme collecting member paths and the entries that could not be
read: the path-collecting consumer of FSE4. Its result names paths and
nothing else.
*/
struct PathScheme
{
    /// What a `PathScheme` resolution returns.
    static struct Paths
    {
        string[] members;    /// relative to the fileset root, in visiting order
        string[] unreadable; /// `path: kind` of each incomplete entry (FSE2)
    }

    alias Result = Paths; ///
    private Paths paths;

    /// Collects a directory's members.
    bool visit(Entries, Exec)(scope const(char)[] path, Entries entries, bool empty, ref Exec exec)
    {
        import sparkles.build_primitives.fileset.fso : FsoKind;

        foreach (e; entries)
            if (e.node.kind != FsoKind.directory)
                paths.members ~= path.length ? (path ~ "/" ~ e.name).idup : e.name.idup;
        return true;
    }

    /// Records an entry that could not be read.
    bool incomplete(scope const(char)[] path, ErrorKind kind)
    {
        import std.conv : to;

        paths.unreadable ~= (path ~ ": " ~ kind.to!string).idup;
        return true;
    }

    /// The collected paths.
    Paths finish() => paths;
}
