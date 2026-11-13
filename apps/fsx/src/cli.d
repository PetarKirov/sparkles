/**
`fsx`'s command line (`XA1`–`XA5`, docs/specs/fsx): `cp`, `ls` and `diff`,
and the same under the names `fscp`, `fsls` and `fsdiff`.

`runFsxTo` parses and runs a command line, returning its exit status and
what it would print on each stream; `runFsx` prints them.
*/
module cli;

import std.sumtype : match, SumType;

import sparkles.core_cli.args : Command, Option, Subcommands;

import sparkles.fileset_tools.copy : CopyVfs;

/// The command line.
@(Command("fsx", shortDescription:
    "Copy, list and compare the files a fileset selects, from a directory or an iroh peer."))
struct Fsx
{
    @Subcommands
    SumType!(Cp, Ls, Diff) command;
}

/// `cp` (`XC`, `XV`): copy the members, verified.
@(Command("cp", shortDescription:
    "Copy the members of --filter over --src to --dst, each at its path, and verify the copy."))
struct Cp
{
    mixin SourceOptions;

    @(Option("dst", description: "Where the members go; created if missing, its parent must exist.",
        placeholder: "PATH", required: true))
    string dst;

    @(Option("f|force", description: "Replace files and links in the way; a directory is never replaced."))
    bool force;

    @(Option("n|dry-run", description: "Print each destination path and the totals, check, and copy nothing."))
    bool dryRun;

    @(Option("stats", description: "Print the source's Stats report on standard error first."))
    bool stats;

    @(Option("tree-hashes", description: "Verify the NAR hash and git tree id as well as castore, and print them."))
    bool treeHashes;

    @(Option("verify", description: "Hash the source in a pass of its own before copying (separate), "
        ~ "or from the bytes as the copy reads them (inline).", placeholder: "WHEN",
        allowedValues: ["separate", "inline"]))
    string verify = "separate";

    @(Option("link-root", description: "A directory links with absolute targets may point into, such as "
        ~ "/nix/store; repeatable.", placeholder: "PATH"))
    string[] linkRoots;

    @(Option("vfs", description: "The VFS backend: blocking, one file at a time, or ring, --jobs at once.",
        placeholder: "BACKEND", allowedValues: ["blocking", "ring"]))
    string vfs = "blocking";

    @(Option("jobs", description: "The most files in flight with --vfs ring.", placeholder: "N"))
    uint jobs = 16;
}

/// `ls` (`XL`): list the members.
@(Command("ls", shortDescription: "List the members of --filter over --src, one path per line."))
struct Ls
{
    mixin SourceOptions;

    @(Option("0|null", description: "End each path with a NUL byte instead of a newline."))
    bool nul;

    @(Option("l|long", description: "Kind and executable bit, size, path and a link's target, tab-separated."))
    bool long_;

    @(Option("tree", description: "Draw the members as a tree."))
    bool tree;

    @(Option("stats", description: "Print the Stats report on standard error after the listing."))
    bool stats;

    @(Option("tree-hashes", description: "Print the members' castore, NAR and git ids on standard error."))
    bool treeHashes;
}

/// `diff` (`XD`): compare two sources' members; in the `full` build only.
@(Command("diff", shortDescription: "Compare the members of --filter over two sources (the full build)."))
struct Diff
{
    @(Option("filter", description: "The fileset query; all() when absent.", placeholder: "EXPR"))
    string filter;

    @(Option("filter-file", description: "A file holding the query; - reads standard input.",
        placeholder: "PATH"))
    string filterFile;

    @(Option("p|patch", description: "Add a unified diff of each changed text file."))
    bool patch;

    @(Option("a", description: "The first source.", placeholder: "SOURCE", hidden: true))
    string a;

    @(Option("b", description: "The second source.", placeholder: "SOURCE", hidden: true))
    string b;
}

/// The options every source-reading subcommand takes (`XA2`, `XS1`).
mixin template SourceOptions()
{
    @(Option("src", description: "The source: a directory, a file: URI, or an iroh ticket "
        ~ "(bare, iroh:… or web+iroh-sendme:…).", placeholder: "SOURCE", required: true))
    string src;

    @(Option("filter", description: "The fileset query; all() when absent.", placeholder: "EXPR"))
    string filter;

    @(Option("filter-file", description: "A file holding the query; - reads standard input.",
        placeholder: "PATH"))
    string filterFile;
}

/// The subcommand a program name stands for (`XA1`): `fscp` is `cp`.
string subcommandOfName(string programPath) @safe pure
{
    import std.algorithm.searching : endsWith;
    import std.path : baseName;

    string name = baseName(programPath);
    version (Windows)
        if (name.endsWith(".exe"))
            name = name[0 .. $ - 4];
    switch (name)
    {
        case "fscp": return "cp";
        case "fsls": return "ls";
        case "fsdiff": return "diff";
        default: return null;
    }
}

/// Runs `args` and prints what it produced; returns the exit status.
int runFsx(string[] args)
{
    import std.stdio : stderr, stdout;

    string output, error;
    const status = runFsxTo(args, output, error);
    stdout.rawWrite(output);
    stdout.flush();
    stderr.rawWrite(error);
    return status;
}

/**
Parses and runs `args` (`XA1`–`XA3`). What would go to standard output is
appended to `output`, the rest to `error`. A usage error exits 2.
*/
int runFsxTo(string[] args, out string output, out string error)
{
    import std.array : appender;
    import sparkles.core_cli.args : CliError, parseCli, reportCliError;

    const sub = args.length ? subcommandOfName(args[0]) : null;
    string[] argv = sub.length ? ["fsx", sub] ~ args[1 .. $] : args.dup;
    if (sub == "diff")
        argv = diffArgs(argv);
    auto parsed = parseCli!Fsx(argv);
    if (!parsed)
    {
        CliError e = parsed.error;
        if (e.kind == CliError.Kind.parse)
            e.exitCode = 2;
        auto o = appender!string, r = appender!string;
        const status = reportCliError(e, o, r);
        output = o[];
        error = r[];
        return status;
    }
    if (!parsed.value.commandSelected)
    {
        error = "fsx: name a subcommand: cp, ls or diff (fsx --help lists them)\n";
        return 2;
    }
    return parsed.value.command.match!(
        (ref Cp c) => runCp(c, output, error),
        (ref Ls l) => runLs(l, output, error),
        (ref Diff d) => runDiff(d, output, error),
    );
}

// `fsdiff A B …`: the two sources are its first two operands; core-cli
// reads them as the hidden options.
private string[] diffArgs(string[] argv)
{
    import std.algorithm.searching : startsWith;

    string[] rest = argv[0 .. 2], operands;
    foreach (a; argv[2 .. $])
        if (!a.startsWith("-") && operands.length < 2)
            operands ~= a;
        else
            rest ~= a;
    if (operands.length > 0)
        rest ~= ["--a", operands[0]];
    if (operands.length > 1)
        rest ~= ["--b", operands[1]];
    return rest;
}

/// The filter `--filter` or `--filter-file` names (`XA2`): `null` beside a
/// message and the status to exit with when it cannot be had.
string filterOf(string filter, string filterFile, string program, out string why, out int status)
{
    import std.file : readText;
    import std.stdio : stdin;

    if (filter.length && filterFile.length)
    {
        why = program ~ ": give --filter or --filter-file, not both\n";
        status = 2;
        return null;
    }
    if (filterFile.length == 0)
        return filter.length ? filter : "all()";
    try
    {
        if (filterFile == "-")
        {
            string text;
            foreach (chunk; stdin.byChunk(64 * 1024))
                text ~= cast(const(char)[]) chunk;
            return text;
        }
        return readText(filterFile);
    }
    catch (Exception e)
    {
        why = program ~ ": --filter-file " ~ filterFile ~ ": " ~ e.msg ~ "\n";
        status = 1;
        return null;
    }
}

/// The local directory `src` names, or `null` beside the reason (`XS1`).
string localSource(string src, string program, out string why)
{
    import std.file : exists;
    import sparkles.fileset_tools.source : parseSource, SourceKind;

    auto parsed = parseSource(src, (string p) @trusted => exists(p));
    if (!parsed.ok)
    {
        why = program ~ ": --src " ~ parsed.error ~ "\n";
        return null;
    }
    if (parsed.source.kind == SourceKind.iroh)
    {
        why = program ~ ": --src names an iroh ticket; reading from an iroh peer needs the bridge's "
            ~ "receive half, which this build does not have yet\n";
        return null;
    }
    return parsed.source.path;
}

private int runCp(ref Cp c, ref string output, ref string error)
{
    import sparkles.fileset_tools.commands : copyCommand, CopyOptions, VerifyMode;
    import sparkles.fileset_tools.evaluate : Root;

    int status;
    const filter = filterOf(c.filter, c.filterFile, "fscp", error, status);
    if (filter is null)
        return status;
    const dir = localSource(c.src, "fscp", error);
    if (dir is null)
        return 1;
    CopyOptions o;
    o.source = Root(dir: dir);
    o.filter = filter;
    o.dest = c.dst;
    o.force = c.force;
    o.dryRun = c.dryRun;
    o.stats = c.stats;
    o.treeHashes = c.treeHashes;
    o.verify = c.verify == "inline" ? VerifyMode.inline : VerifyMode.separate;
    o.vfs = c.vfs == "ring" ? CopyVfs.ring : CopyVfs.blocking;
    o.jobs = c.jobs;
    o.linkRoots = c.linkRoots;
    string out_, err;
    const r = copyCommand(o, out_, err);
    output ~= out_;
    error ~= err;
    return r;
}

private int runLs(ref Ls l, ref string output, ref string error)
{
    import ls : listCommand, ListOptions;

    int status;
    const filter = filterOf(l.filter, l.filterFile, "fsls", error, status);
    if (filter is null)
        return status;
    const dir = localSource(l.src, "fsls", error);
    if (dir is null)
        return 1;
    ListOptions o;
    o.dir = dir;
    o.filter = filter;
    o.nul = l.nul;
    o.long_ = l.long_;
    o.tree = l.tree;
    o.stats = l.stats;
    o.treeHashes = l.treeHashes;
    return listCommand(o, output, error);
}

private int runDiff(ref Diff d, ref string output, ref string error)
{
    version (FsxDiff)
    {
        import diff_command : diffCommand;

        return diffCommand(d, output, error);
    }
    else
    {
        error = "fsdiff: this fsx was built without diff; its full configuration has it\n";
        return 2;
    }
}
