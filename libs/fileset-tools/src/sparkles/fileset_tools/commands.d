/**
The copy command (`XC`, `XV`, docs/specs/fsx): what `fscp` does, and what
the explorer's `cp` does through it.

`copyCommand` resolves the filter over the source, checks every destination
path and every absolute link before writing anything, hashes the source,
copies, hashes the destination's copied members, and succeeds only when the
two castore ids agree. What it would print goes into `output` (the dry
run's paths) and `error` (everything else), so a caller decides where they
go and a test can read them.
*/
module sparkles.fileset_tools.commands;

import std.conv : text;

import sparkles.build_primitives.fileset.fso : FsoKind;

import sparkles.fileset_tools.copy : CopyVfs;
import sparkles.fileset_tools.evaluate : Root;

/// When the source is hashed (`XV2`).
enum VerifyMode : ubyte
{
    separate, /// in a pass of its own, before any member is written
    inline,   /// from the bytes as the copy reads them
}

/// What to copy, where, and how.
struct CopyOptions
{
    Root source;                         /// a directory, when `ticket` is empty
    string ticket;                       /// an iroh source's ticket (`XR`)
    bool noRelay;                        /// reach the peer at its direct addresses only
    string bridgePath;                   /// the iroh bridge; its default search when empty
    string filter = "all()";             /// the query
    string dest;                         ///
    bool force;                          /// replace files and links in the way (`XC2`)
    bool dryRun;                         /// list and check, write nothing (`XC5`)
    bool stats;                          /// the Stats report first (`XV6`)
    bool treeHashes;                     /// verify the NAR and git names too (`XV4`)
    VerifyMode verify;                   ///
    CopyVfs vfs;                         /// (`XC7`)
    uint jobs = 16;                      /// files in flight on `CopyVfs.ring`
    string[] linkRoots;                  /// where absolute links may point (`XC4`)
    string program = "fscp";             /// what messages begin with
    /// Run after the source is hashed and after the copy, before the
    /// destination is: a test's way to change a file between the passes.
    void delegate() afterSourceHash, afterCopy;
}

/**
Copies the members of `o.filter` over `o.source` to `o.dest` (`XC1`–`XC7`)
and verifies the copy (`XV1`–`XV6`). Returns the exit status: 0 for a
verified copy or a clean dry run, 1 for a refusal or a failure.
*/
int copyCommand(in CopyOptions o, out string output, out string error)
{
    import std.format : format;
    import std.path : absolutePath, buildNormalizedPath, buildPath;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.names : isAbsolutePath;
    import sparkles.base.vfs.types : Rights;
    import sparkles.event_horizon.sys : BlockingVfs;
    import sparkles.fileset_tools.copy : copyMembers, coverOf, grantLinkRoots, InTheWay, inTheWay;
    import sparkles.fileset_tools.evaluate : evaluate, evaluatePaths, humanBytes;
    import sparkles.fileset_tools.stats : formatStats, statsRows;
    import sparkles.fileset_tools.verify : castoreText, digestMembers, firstDifference, MemberDigest;

    const p = o.program;
    if (o.ticket.length)
        return copyFromIroh(o, output, error);
    if (o.source.inMemory)
    {
        error = p ~ ": a tree held in memory has no files to copy\n";
        return 1;
    }
    const found = evaluate(o.source, o.filter, withIds: o.treeHashes || o.stats);
    if (found.failed)
    {
        error = text(p, ": ", o.filter, ": ", found.error.message, " (at offset ", found.error.offset, ")\n");
        return 1;
    }
    const members = found.found.members;
    string[] paths;
    foreach (ref m; members)
        paths ~= m.path;
    if (o.stats)
        error ~= formatStats(statsRows(found, found, ""));

    // Absolute links, only beneath a granted root (`XC4`).
    string refused;
    auto granted = grantLinkRoots(o.linkRoots.dup, refused);
    if (refused.length)
    {
        error ~= p ~ ": --link-root " ~ refused ~ "\n";
        return 1;
    }
    string[] outside;
    // A link made through a root reached by another name holds the root's
    // real path (`XC4`): the target the copy is checked against.
    string[size_t] rewritten;
    foreach (i, ref m; members)
    {
        if (m.kind != FsoKind.symlink || !isAbsolutePath(m.target))
            continue;
        const cover = coverOf(m.target, granted.names);
        if (cover.root < 0)
        {
            outside ~= m.path ~ " -> " ~ m.target;
            continue;
        }
        const real_ = granted.names[cover.root][$ - 1];
        const made = cover.rest.length == 0 ? real_
            : real_.length && real_[$ - 1] == '/' ? real_ ~ cover.rest : real_ ~ "/" ~ cover.rest;
        if (made != m.target)
            rewritten[i] = made;
    }
    if (outside.length)
    {
        error ~= text(p, ": copied nothing: ", outside.length, outside.length == 1 ? " link points" : " links point",
            " outside the fileset and beneath no --link-root:\n") ~ listed(outside);
        return 1;
    }

    if (rewritten.length && o.treeHashes)
    {
        string[] names;
        foreach (i, made; rewritten)
            names ~= members[i].path ~ " -> " ~ made;
        error ~= text(p, ": copied nothing: --tree-hashes needs the source's names, and ", rewritten.length,
            rewritten.length == 1 ? " link would hold" : " links would hold",
            " a granted root's real path instead (name the root by it):\n") ~ listed(names);
        return 1;
    }

    // Every destination path, before anything is written (`XC2`).
    size_t files, links;
    string[] clashes, directories;
    const there = inTheWay(o.dest, members);
    foreach (i, ref m; members)
    {
        files += m.kind == FsoKind.regular;
        links += m.kind == FsoKind.symlink;
        const to = buildPath(o.dest, m.path);
        if (o.dryRun)
            output ~= to ~ "\n";
        if (there[i] == InTheWay.directory)
            directories ~= to;
        else if (there[i] == InTheWay.entry)
            clashes ~= to;
    }
    const totals = text(files, files == 1 ? " file" : " files", " (", humanBytes(found.bytes), ")",
        links ? text(" and ", links, links == 1 ? " link" : " links") : "");
    if (directories.length)
    {
        error ~= text(p, ": copied nothing: ", directories.length,
            directories.length == 1 ? " directory is" : " directories are",
            " where a member goes, and nothing replaces a directory:\n") ~ listed(directories);
        return 1;
    }
    if (clashes.length && !o.force)
    {
        error ~= text(p, ": copied nothing: ", clashes.length, clashes.length == 1 ? " path exists" : " paths exist",
            " (--force replaces them):\n") ~ listed(clashes);
        return 1;
    }
    if (o.dryRun)
    {
        error ~= text(p, ": would copy ", totals, " to ", o.dest, "\n");
        return 0;
    }

    // The source's records: before the copy, or as it reads (`XV2`).
    const base = buildNormalizedPath(absolutePath(o.source.dir));
    auto vfs = new BlockingVfs;
    MemberDigest[] expected;
    if (o.verify == VerifyMode.separate)
    {
        auto src = openRoot!(Rights.readOnly)(vfs, base, ambientAuthority());
        if (src.hasError)
        {
            error ~= text(p, ": ", base, ": ", src.error, "\n");
            return 1;
        }
        string why;
        expected = digestMembers(src.value.borrow, paths, why);
        if (why.length)
        {
            error ~= text(p, ": copied nothing: cannot hash ", why, "\n");
            return 1;
        }
        if (o.afterSourceHash !is null)
            o.afterSourceHash();
    }
    auto report = copyMembers(base, o.dest, members, o.force, o.vfs, o.jobs, granted,
        hashInline: o.verify == VerifyMode.inline);
    if (report.failure.length)
    {
        error ~= text(p, ": ", report.failure, "\n", p, ": what was copied is left at ", o.dest, "\n");
        return 1;
    }
    if (o.verify == VerifyMode.inline)
        expected = report.read;
    foreach (i, made; rewritten)
        expected[i].target = made;
    if (o.afterCopy !is null)
        o.afterCopy();

    // The destination's copied members, and nothing else beneath it (`XV1`).
    auto dst = openRoot!(Rights.readOnly)(vfs, o.dest, ambientAuthority());
    if (dst.hasError)
    {
        error ~= text(p, ": ", o.dest, ": ", dst.error, "\n");
        return 1;
    }
    string why;
    const actual = digestMembers(dst.value.borrow, paths, why);
    if (why.length)
    {
        error ~= text(p, ": cannot hash the copy: ", why, "\n");
        return 1;
    }
    const want = castoreText(expected), got = castoreText(actual);
    const differs = firstDifference(expected, actual);
    if (differs.length || want != got)
    {
        error ~= text(p, ": the copy differs from the source: ", differs.length ? differs : "the trees differ", "\n",
            "  source  castore ", want.length ? want : "(none)", "\n",
            "  copy    castore ", got.length ? got : "(none)", "\n",
            p, ": the copy is left at ", o.dest, " for inspection\n");
        return 1;
    }
    string names = text(p, ": verified: castore ", want, "\n");

    // The NAR and git names as well (`XV4`).
    if (o.treeHashes)
    {
        const copied = evaluatePaths(o.dest, paths, withIds: true);
        const string[3] keys = ["castore", "NarHash", "git tree"];
        const string[3] mine = [found.castore, found.narHash, found.gitTree];
        const string[3] theirs = [copied.castore, copied.narHash, copied.gitTree];
        names = "";
        foreach (k; 0 .. 3)
            names ~= format!"%s: %-8s source %s\n%s: %-8s copy   %s\n"(p, keys[k], mine[k], p, keys[k], theirs[k]);
        foreach (k; 0 .. 3)
            if (!copied.hasIds || mine[k] != theirs[k])
            {
                error ~= names ~ text(p, ": the copy's ", keys[k], " differs; the copy is left at ", o.dest,
                    " for inspection\n");
                return 1;
            }
        names ~= text(p, ": verified: castore, NarHash and git tree\n");
    }

    error ~= text(p, ": copied ", totals, " to ", o.dest, format!" in %.2f ms"(report.took.total!"usecs" / 1000.0),
        " (", o.vfs == CopyVfs.ring ? text("RingVfs, ", report.peak, " in flight at most") : "BlockingVfs", ")\n")
        ~ names;
    return 0;
}

// The first twenty of `paths`, indented, and how many more.
private string listed(const(string)[] paths)
{
    string s;
    foreach (c; paths[0 .. paths.length < 20 ? $ : 20])
        s ~= "  " ~ c ~ "\n";
    if (paths.length > 20)
        s ~= text("  and ", paths.length - 20, " more\n");
    return s;
}

/**
`copyCommand` for an iroh source (`XR`): the names first, the filter over
them, the destination checked, then only the selected files, verified as
they arrive and, once written, against the castore id assembled from the
collection's digests (`XV3`).
*/
private int copyFromIroh(in CopyOptions o, ref string output, ref string error)
{
    import std.format : format;
    import std.path : buildPath;
    import core.time : MonoTime;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : Rights;
    import sparkles.event_horizon.sys : BlockingVfs;
    import sparkles.iroh_send.bridge : loadIrohSend;
    import sparkles.fileset_tools.copy : InTheWay, inTheWay;
    import sparkles.fileset_tools.evaluate : evaluatePaths, humanBytes, Member;
    import sparkles.fileset_tools.iroh_source : openIroh, receiveMembers, selectIroh;
    import sparkles.fileset_tools.verify : castoreText, digestMembers, firstDifference;

    const p = o.program;
    const t0 = MonoTime.currTime;
    auto lib = loadIrohSend(o.bridgePath);
    if (lib.hasError)
    {
        error ~= text(p, ": an iroh source needs the iroh bridge: ", lib.error, "\n");
        return 1;
    }
    auto opened = openIroh(lib.value, o.ticket, o.noRelay);
    if (opened.hasError)
    {
        error ~= text(p, ": ", opened.error, "\n");
        return 1;
    }
    auto source = opened.value;
    scope (exit) source.close();
    auto chosen = selectIroh(source.members, o.filter);
    if (chosen.hasError)
    {
        error ~= text(p, ": ", o.filter, ": ", chosen.error, "\n");
        return 1;
    }
    Member[] members;
    string[] paths;
    foreach (i; chosen.value)
    {
        members ~= Member(source.members[i].path, FsoKind.regular);
        paths ~= source.members[i].path;
    }
    const from = source.label.length ? text("`", source.label, "` from the peer") : "the peer's collection";
    if (o.stats)
        error ~= text(p, ": ", from, " lists ", source.members.length, " files; the filter selects ",
            members.length, "; opening it read ", humanBytes(source.openedBytes), "\n");

    // Every destination path, before anything is fetched (`XC2`).
    string[] clashes, directories;
    const there = inTheWay(o.dest, members);
    foreach (i, ref m; members)
    {
        const to = buildPath(o.dest, m.path);
        if (o.dryRun)
            output ~= to ~ "\n";
        if (there[i] == InTheWay.directory)
            directories ~= to;
        else if (there[i] == InTheWay.entry)
            clashes ~= to;
    }
    if (directories.length)
    {
        error ~= text(p, ": copied nothing: ", directories.length,
            directories.length == 1 ? " directory is" : " directories are",
            " where a member goes, and nothing replaces a directory:\n") ~ listed(directories);
        return 1;
    }
    if (clashes.length && !o.force)
    {
        error ~= text(p, ": copied nothing: ", clashes.length, clashes.length == 1 ? " path exists" : " paths exist",
            " (--force replaces them):\n") ~ listed(clashes);
        return 1;
    }
    if (o.dryRun)
    {
        error ~= text(p, ": would copy ", members.length, members.length == 1 ? " file" : " files", " of ",
            source.members.length, " from ", from, " to ", o.dest, "\n");
        return 0;
    }

    auto got = receiveMembers(source, o.dest, chosen.value, o.force);
    if (got.failure.length)
    {
        error ~= text(p, ": ", got.failure, "\n", p, ": what was copied is left at ", o.dest, "\n");
        return 1;
    }

    // The copy, against the id the collection's digests name (`XV1`, `XV3`).
    auto vfs = new BlockingVfs;
    auto dst = openRoot!(Rights.readOnly)(vfs, o.dest, ambientAuthority());
    if (dst.hasError)
    {
        error ~= text(p, ": ", o.dest, ": ", dst.error, "\n");
        return 1;
    }
    string why;
    const actual = digestMembers(dst.value.borrow, paths, why);
    if (why.length)
    {
        error ~= text(p, ": cannot hash the copy: ", why, "\n");
        return 1;
    }
    const want = castoreText(got.expected), have = castoreText(actual);
    const differs = firstDifference(got.expected, actual);
    if (differs.length || want != have)
    {
        error ~= text(p, ": the copy differs from the collection: ", differs.length ? differs : "the trees differ", "\n",
            "  collection castore ", want.length ? want : "(none)", "\n",
            "  copy       castore ", have.length ? have : "(none)", "\n",
            p, ": the copy is left at ", o.dest, " for inspection\n");
        return 1;
    }
    string names = text(p, ": verified: castore ", want, "\n");
    if (o.treeHashes)
    {
        // Equal castore ids are equal trees: the copy's names are the source's.
        const copied = evaluatePaths(o.dest, paths, withIds: true);
        names ~= text(p, ": NarHash  ", copied.narHash, "\n", p, ": git tree ", copied.gitTree,
            "\n", p, ": the NAR and git names are the copy's, which castore proved equal to the source\n");
    }
    const ms = (MonoTime.currTime - t0).total!"usecs" / 1000.0;
    error ~= text(p, ": copied ", got.files, got.files == 1 ? " file (" : " files (", humanBytes(got.bytes),
        ") of ", source.members.length, " from ", from, " to ", o.dest, format!" in %.2f ms"(ms),
        " (iroh; opening it read ", humanBytes(source.openedBytes), ")\n") ~ names;
    return 0;
}
