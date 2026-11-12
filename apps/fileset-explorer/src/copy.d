/**
Copying a fileset's members out of its root (`FXC5`), through the capability
VFS on both sides, so the same copy runs over `BlockingVfs`, one file at a
time, and over `RingVfs` on scheduler fibers, several files in flight
(`--vfs`, `--jobs`), and the two can be compared.

The source is opened read-only; the destination, beneath its parent, with
the rights to create, write and replace entries and nothing more.
Directories are made first, one after another; then each member is copied
on work the executor runs: `InlineExecutor` runs it at once,
`LoopExecutor` on a fiber once its budget admits it.

A link holding an absolute target is made only beneath a root the command
line granted (`--link-root`, `VFO10`): the root is opened read-only, the
target must fall lexically beneath it, and the link is made with
`symlinkTo`, so its absolute part is the root's own path as the backend
reports it, never text from the source tree.
*/
module copy;

import core.time : Duration, MonoTime;

import sparkles.base.io.errors : ErrorKind;
import sparkles.base.vfs.handles : ambientAuthority, openRoot;
import sparkles.base.vfs.types : Access, Disposition, OpenMode, Rights, Shared;
import sparkles.build_primitives.fileset.fso : FsoKind;

import evaluate : Member;

/// Which VFS backend a copy runs over.
enum CopyVfs : ubyte
{
    blocking, /// `BlockingVfs`: each call blocks the thread, one file at a time
    ring,     /// `RingVfs`: calls park a fiber; `jobs` files in flight
}

/// What a copy did.
struct CopyReport
{
    size_t files;      ///
    size_t links;      ///
    ulong bytes;       /// the bytes written
    uint peak;         /// the most files in flight at once
    Duration took;     /// from opening the roots to the last file closed
    string failure;    /// the first member that failed, and why; empty when none
}

/**
The places absolute links may point into (`--link-root`): each root as
given, and the texts that name it, its normalized absolute path and the
path the backend reports for it, its links resolved.
*/
struct LinkRoots
{
    string[] paths;   /// as given
    string[][] names; /// per root: the texts a target may begin with
}

/**
Opens each of `paths` read-only, as the command line grants it, and reads
the names it goes by; `failure` names the first that cannot be opened.
*/
LinkRoots grantLinkRoots(string[] paths, out string failure)
{
    import std.conv : text;
    import std.path : absolutePath, buildNormalizedPath;
    import sparkles.event_horizon.sys : BlockingVfs;

    LinkRoots roots;
    auto vfs = new BlockingVfs;
    foreach (p; paths)
    {
        auto dir = openRoot!(Rights.readOnly)(vfs, p, ambientAuthority());
        if (dir.hasError)
        {
            failure = p ~ ": " ~ text(dir.error);
            return LinkRoots.init;
        }
        char[4096] buffer;
        auto n = vfs.pathOf(dir.value.backendHandle, buffer[]);
        if (n.hasError)
        {
            failure = p ~ ": " ~ text(n.error);
            return LinkRoots.init;
        }
        const given = buildNormalizedPath(absolutePath(p)), real_ = buffer[0 .. n.value].idup;
        roots.paths ~= p;
        roots.names ~= given == real_ ? [given] : [given, real_];
    }
    return roots;
}

/// Which granted root an absolute link target falls beneath, and the rest of
/// the target below it; `root` is -1 when none covers it.
struct Cover
{
    ptrdiff_t root = -1; ///
    string rest;         /// empty for the root itself
}

/**
The first root of `names` (`LinkRoots.names`) that `target` falls beneath,
lexically: it equals one of the root's names, or continues one past a
separator with a path `symlinkTo` accepts, no empty, `.` or `..` component.
*/
Cover coverOf(string target, const(string[])[] names) @safe pure nothrow
{
    import sparkles.base.vfs.names : checkBeneathPath;

    foreach (i, forms; names)
        foreach (r; forms)
        {
            if (target == r)
                return Cover(i, "");
            const prefixLength = r.length && r[$ - 1] == '/' ? r.length : r.length + 1;
            if (target.length <= prefixLength || target[0 .. r.length] != r
                || target[prefixLength - 1] != '/')
                continue;
            const rest = target[prefixLength .. $];
            if (checkBeneathPath(rest) == ErrorKind.other)
                return Cover(i, rest);
        }
    return Cover.init;
}

///
@("fileset_explorer.copy.coverOf")
@safe pure nothrow unittest
{
    const names = [["/nix/store"], ["/home/u/via", "/home/u/real"], ["/"]];
    assert(coverOf("/nix/store/abc-x/bin", names) == Cover(0, "abc-x/bin"));
    assert(coverOf("/nix/store", names) == Cover(0, ""));
    assert(coverOf("/home/u/real/a", names) == Cover(1, "a"));
    assert(coverOf("/nix/storeroom/a", names) == Cover(2, "nix/storeroom/a"), "a name, not a prefix");
    assert(coverOf("/nix/store/../etc", names[0 .. 1]).root == -1, "never above the root");
    assert(coverOf("/nix/store//a", names[0 .. 1]).root == -1);
    assert(coverOf("/etc/passwd", names[0 .. 2]).root == -1);
}

/// The rights the destination is opened with: make, write and replace.
enum Rights destRights = cast(Rights)(Rights.lookup | Rights.stat | Rights.write | Rights.create
    | Rights.createShared | Rights.remove);

/**
Copies `members` from the directory `from` to `to`, each at its path, over
the backend `vfs`; `jobs` bounds the files in flight on `RingVfs`. The
destination's parent must exist; `to` itself is made if it does not. With
`force`, an entry in a member's way is removed first.
*/
CopyReport copyMembers(string from, string to, const(Member)[] members, bool force, CopyVfs vfs, uint jobs = 16,
    LinkRoots linkRoots = LinkRoots.init)
{
    import sparkles.build_primitives.fileset.driver : InlineExecutor;
    import sparkles.event_horizon.sys : BlockingVfs;

    CopyReport report;
    const t0 = MonoTime.currTime;
    final switch (vfs)
    {
        case CopyVfs.blocking:
            auto blocking = new BlockingVfs;
            InlineExecutor exec;
            copyOver(blocking, from, to, members, force, linkRoots, exec, report);
            report.peak = report.files + report.links ? 1 : 0;
            break;
        case CopyVfs.ring:
            import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
            import sparkles.event_horizon.admission : Admission;
            import sparkles.event_horizon.sched : Sched;
            import sparkles.event_horizon.vfs : RingVfs;

            Sched s;
            if (Sched.create(s).hasError)
            {
                report.failure = "no event loop on this host";
                break;
            }
            auto ran = s.run(() {
                auto rv = new RingVfs;
                auto exec = LoopExecutor!Sched(&s, new Admission(jobs ? jobs : 1));
                copyOver(rv, from, to, members, force, linkRoots, exec, report);
                report.peak = exec.peak;
            });
            if (ran.hasError && !report.failure.length)
                report.failure = "the event loop failed";
            break;
    }
    report.took = MonoTime.currTime - t0;
    return report;
}

/// Whether a member is in the way at `to/<path>`: an entry, a link counted
/// itself, exists there. A missing destination holds nothing.
bool[] inTheWay(string to, const(Member)[] members)
{
    import std.file : exists;
    import std.path : baseName, dirName;
    import sparkles.event_horizon.sys : BlockingVfs;

    auto there = new bool[members.length];
    if (!exists(to))
        return there;
    auto vfs = new BlockingVfs;
    auto root = openRoot!(Rights.readOnly)(vfs, to, ambientAuthority());
    if (root.hasError)
        return there;
    foreach (i, ref m; members)
    {
        const parent = dirName(m.path);
        auto dir = parent == "." ? root.value.walk("") : root.value.walk(parent);
        if (dir.hasError)
            continue; // its directory is not there, nor is it
        there[i] = !dir.value.statAt(baseName(m.path)).hasError;
    }
    return there;
}

// ---------------------------------------------------------------------------

// The copy over the backend `vfs`, its work run by `exec`.
private void copyOver(V, Exec)(V* vfs, string from, string to, const(Member)[] members, bool force,
    LinkRoots linkRoots, ref Exec exec, ref CopyReport report)
{
    import core.lifetime : move;
    import std.conv : text;
    import std.path : absolutePath, baseName, buildNormalizedPath, dirName;

    auto src = openRoot!(Rights.readOnly)(vfs, from, ambientAuthority());
    if (src.hasError)
        return fail(report, from, text(src.error));
    // The roots absolute links may point into, on this backend.
    alias Granted = typeof(src.value);
    auto granted = new Granted[linkRoots.paths.length];
    scope (exit)
        foreach (ref g; granted)
            destroy(g);
    foreach (i, p; linkRoots.paths)
    {
        auto g = openRoot!(Rights.readOnly)(vfs, p, ambientAuthority());
        if (g.hasError)
            return fail(report, p, text(g.error));
        granted[i] = move(g.value);
    }
    auto grantedRefs = new typeof(granted[0].borrow())[granted.length];
    foreach (i, ref g; granted)
        grantedRefs[i] = g.borrow;
    const dest = buildNormalizedPath(absolutePath(to));
    auto parent = openRoot!destRights(vfs, dirName(dest), ambientAuthority());
    if (parent.hasError)
        return fail(report, dirName(dest), text(parent.error));
    auto top = parent.value.walkAll(baseName(dest), Shared());
    if (top.hasError)
        return fail(report, dest, text(top.error));
    auto from_ = src.value.borrow;
    auto dst = top.value.borrow;

    // Every directory a member needs, before any file is copied, one at a
    // time: two files of one directory never race to make it.
    bool[string] made;
    foreach (ref m; members)
    {
        const d = dirName(m.path);
        if (d == "." || d in made)
            continue;
        made[d] = true;
        auto dir = dst.walkAll(d, Shared());
        if (dir.hasError)
            return fail(report, d, text(dir.error));
    }

    // Each job in a frame of its own: closures made in one loop body share
    // its frame, and would all copy the last member once run on fibers.
    void delegate() jobFor(size_t i)
    {
        return () {
            if (report.failure.length)
                return; // one failure ends the copy: start nothing more
            const why = copyOne(from_, dst, members[i], force, grantedRefs, linkRoots.names, report);
            if (why.length)
                fail(report, members[i].path, why);
        };
    }

    foreach (i; 0 .. members.length)
        exec.spawn(jobFor(i));
    exec.join();
}

// Copies one member; returns why it could not, or null.
private string copyOne(D, S, G)(ref S src, ref D dst, ref const Member m, bool force, G[] granted,
    const(string[])[] grantedNames, ref CopyReport report)
{
    import std.conv : text;
    import std.path : baseName, dirName;
    import sparkles.base.vfs.names : isAbsolutePath;

    const parent = dirName(m.path), name = baseName(m.path);
    auto into = parent == "." ? dst.walk("") : dst.walk(parent);
    if (into.hasError)
        return text(into.error);
    if (force && !into.value.statAt(name).hasError)
    {
        const gone = into.value.unlinkAt(name);
        if (gone.hasError)
            return text(gone.error);
    }
    if (m.kind == FsoKind.symlink)
    {
        if (isAbsolutePath(m.target))
        {
            const cover = coverOf(m.target, grantedNames);
            if (cover.root < 0)
                return "its target, " ~ m.target ~ ", is beneath no --link-root";
            const made = into.value.symlinkTo(name, granted[cover.root], cover.rest);
            if (made.hasError)
                return text(made.error);
            ++report.links;
            return null;
        }
        const made = into.value.symlinkAt(name, m.target);
        if (made.hasError)
            return text(made.error);
        ++report.links;
        return null;
    }

    auto fromDir = parent == "." ? src.walk("") : src.walk(parent);
    if (fromDir.hasError)
        return text(fromDir.error);
    auto input = fromDir.value.openFile!(OpenMode.read)(name);
    if (input.hasError)
        return text(input.error);
    auto output = m.executable
        ? into.value.openFile!(OpenMode(Access.write, Disposition.createNew, true))(name, Shared())
        : into.value.openFile!(OpenMode(Access.write, Disposition.createNew, false))(name, Shared());
    if (output.hasError)
        return text(output.error);
    auto buffer = new ubyte[64 * 1024];
    for (;;)
    {
        auto got = input.value.read(buffer);
        if (got.hasError)
            return text(got.error);
        if (got.value == 0)
            break;
        size_t done;
        while (done < got.value)
        {
            auto put = output.value.write(buffer[done .. got.value]);
            if (put.hasError)
                return text(put.error);
            if (put.value == 0)
                return "a write made no progress";
            done += put.value;
        }
        report.bytes += got.value;
    }
    ++report.files;
    return null;
}

private void fail(ref CopyReport report, scope const(char)[] path, string why)
{
    if (!report.failure.length)
        report.failure = path.idup ~ ": " ~ why;
}
