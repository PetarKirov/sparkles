#!/usr/bin/env dub
/+ dub.sdl:
name "git"
dependency "sparkles:core-cli" path="../../../../.."
targetPath "build"
+/
// ci: build-only

import sparkles.core_cli.args;
import sparkles.core_cli.prettyprint : prettyPrint;
import std.sumtype;

@(Command("add")
    .shortDescription("Add file contents to the index")
    .helpSections!("description")())
struct Add
{
    @(Option(`A|all`))
    bool all;

    @(Option(`u|update`))
    bool update;

    @(Option(`p|patch`))
    bool patch;

    @(Option(`n|dry-run`))
    bool dryRun;

    @(Argument("pathspec").optional())
    string[] pathspecs;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git add with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("commit")
    .shortDescription("Record changes to the repository")
    .helpSections!("description")())
struct Commit
{
    @(Option(`m|message`))
    string message;

    @(Option(`a|all`))
    bool all;

    @(Option(`v|verbose`))
    bool verbose;

    @(Option("amend", "Amend the last commit"))
    bool amend;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git commit with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("push")
    .shortDescription("Update remote refs along with associated objects")
    .helpSections!("description")())
struct Push
{
    @(Option(`u|set-upstream`))
    bool setUpstream;

    @(Option(`f|force`))
    bool force;

    @(Option("tags", "Push all tags"))
    bool tags;

    @(Argument("repository").optional())
    string repository;

    @(Argument("refspec").optional())
    string[] refspecs;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git push with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("pull")
    .shortDescription("Fetch from and integrate with another repository or a local branch")
    .helpSections!("description")())
struct Pull
{
    @(Option("rebase", "Fetch from and integrate with another repository or a local branch"))
    bool rebase;

    @(Argument("repository").optional())
    string repository;

    @(Argument("refspec").optional())
    string[] refspecs;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git pull with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("status")
    .shortDescription("Show the working tree status")
    .helpSections!("description")())
struct Status
{
    @(Option(`s|short`))
    bool short_;

    @(Option(`b|branch`))
    bool branch;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git status with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("log")
    .shortDescription("Show commit logs")
    .helpSections!("description")())
struct Log
{
    @(Option(`n|max-count`))
    int maxCount = -1;

    @(Option("oneline", "Shorten commit hash and show only the first line of the commit message"))
    bool oneline;

    @(Option("graph", "Show an ASCII graph of the commit history"))
    bool graph;

    @(Option(`p|patch`))
    bool patch;

    @(Argument("revision-range").optional())
    string revisionRange;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git log with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("branch")
    .shortDescription("List, create, or delete branches")
    .helpSections!("description")())
struct Branch
{
    @(Option(`a|all`))
    bool all;

    @(Option(`d|delete`))
    bool delete_;

    @(Option(`D`))
    bool forceDelete;

    @(Option(`m|move`))
    bool move;

    @(Option(`r|remotes`))
    bool remotes;

    @(Argument("branchname").optional())
    string branchName;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git branch with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("checkout")
    .shortDescription("Switch branches or restore working tree files")
    .helpSections!("description")())
struct Checkout
{
    @(Option(`b`))
    string newBranch;

    @(Option(`f|force`))
    bool force;

    @(Argument("branch-or-commit").optional())
    string target;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git checkout with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("diff")
    .shortDescription("Show changes between commits, commit and working tree, etc")
    .helpSections!("description")())
struct Diff
{
    @(Option("cached", "Show differences between index and last commit"))
    bool cached;

    @(Option("staged", "Alias for --cached"))
    bool staged;

    @(Argument("pathspec").optional())
    string[] pathspecs;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git diff with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("init")
    .shortDescription("Create an empty Git repository or reinitialize an existing one")
    .helpSections!("description")())
struct Init
{
    @(Option("bare", "Create a bare repository"))
    bool bare;

    @(Argument("directory").optional())
    string directory;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git init with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("clone")
    .shortDescription("Clone a repository into a new directory")
    .helpSections!("description")())
struct Clone
{
    @(Option("depth", "Create a shallow clone with a history truncated to the specified number of commits"))
    int depth;

    @(Option("recursive", "After the clone is created, initialize all submodules within"))
    bool recursive;

    @(Option(`b`))
    string branch;

    @(Argument("repository"))
    string repository;

    @(Argument("directory").optional())
    string directory;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git clone with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("clean")
    .shortDescription("Remove untracked files from the working tree")
    .helpSections!("description", "interactive mode")())
struct Clean
{
    @(Option(`d`))
    bool deleteDirectories;

    @(Option(`f|force`))
    bool force;

    @(Option(`i|interactive`))
    bool interactive;

    @(Option(`n|dry-run`))
    bool dryRun;

    @(Option(`q|quiet`))
    bool quiet;

    @(Option(`e|exclude`))
    string excludePattern;

    @(Option(`x`))
    bool deleteUntracked;

    @(Option(`X`))
    bool deleteIgnored;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git clean with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("git")
    .shortDescription("Distributed version control system")
    .helpSections!("description", "examples", "environment", "further-reading")())
struct Git
{
    @Subcommands
    SumType!(
        Add,
        Branch,
        Checkout,
        Clean,
        Clone,
        Commit,
        Diff,
        Init,
        Log,
        Pull,
        Push,
        Status
    ) command;
}

int main(string[] args)
{
    return runCli!Git(args, HelpInfo("git", "Distributed version control system"));
}
