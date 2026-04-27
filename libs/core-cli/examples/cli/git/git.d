#!/usr/bin/env dub
/+ dub.sdl:
name "git"
dependency "sparkles:core-cli" path="../../../../.."
targetPath "build"
+/

import sparkles.core_cli.args;
import sparkles.core_cli.prettyprint : prettyPrint;
import std.sumtype;

@(Command("add")
    .ShortDescription("Add file contents to the index")
    .HelpSections!("description")())
struct Add
{
    @(option!("add", `A|all`, __FILE__))
    bool all;

    @(option!("add", `u|update`, __FILE__))
    bool update;

    @(option!("add", `p|patch`, __FILE__))
    bool patch;

    @(option!("add", `n|dry-run`, __FILE__))
    bool dryRun;

    @(Argument("pathspec").Optional())
    string[] pathspecs;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git add with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("commit")
    .ShortDescription("Record changes to the repository")
    .HelpSections!("description")())
struct Commit
{
    @(option!("commit", `m|message`, __FILE__))
    string message;

    @(option!("commit", `a|all`, __FILE__))
    bool all;

    @(option!("commit", `v|verbose`, __FILE__))
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
    .ShortDescription("Update remote refs along with associated objects")
    .HelpSections!("description")())
struct Push
{
    @(option!("push", `u|set-upstream`, __FILE__))
    bool setUpstream;

    @(option!("push", `f|force`, __FILE__))
    bool force;

    @(Option("tags", "Push all tags"))
    bool tags;

    @(Argument("repository").Optional())
    string repository;

    @(Argument("refspec").Optional())
    string[] refspecs;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git push with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("pull")
    .ShortDescription("Fetch from and integrate with another repository or a local branch")
    .HelpSections!("description")())
struct Pull
{
    @(Option("rebase", "Fetch from and integrate with another repository or a local branch"))
    bool rebase;

    @(Argument("repository").Optional())
    string repository;

    @(Argument("refspec").Optional())
    string[] refspecs;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git pull with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("status")
    .ShortDescription("Show the working tree status")
    .HelpSections!("description")())
struct Status
{
    @(option!("status", `s|short`, __FILE__))
    bool short_;

    @(option!("status", `b|branch`, __FILE__))
    bool branch;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git status with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("log")
    .ShortDescription("Show commit logs")
    .HelpSections!("description")())
struct Log
{
    @(option!("log", `n|max-count`, __FILE__))
    int maxCount = -1;

    @(Option("oneline", "Shorten commit hash and show only the first line of the commit message"))
    bool oneline;

    @(Option("graph", "Show an ASCII graph of the commit history"))
    bool graph;

    @(option!("log", `p|patch`, __FILE__))
    bool patch;

    @(Argument("revision-range").Optional())
    string revisionRange;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git log with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("branch")
    .ShortDescription("List, create, or delete branches")
    .HelpSections!("description")())
struct Branch
{
    @(option!("branch", `a|all`, __FILE__))
    bool all;

    @(option!("branch", `d|delete`, __FILE__))
    bool delete_;

    @(option!("branch", `D`, __FILE__))
    bool forceDelete;

    @(option!("branch", `m|move`, __FILE__))
    bool move;

    @(option!("branch", `r|remotes`, __FILE__))
    bool remotes;

    @(Argument("branchname").Optional())
    string branchName;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git branch with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("checkout")
    .ShortDescription("Switch branches or restore working tree files")
    .HelpSections!("description")())
struct Checkout
{
    @(option!("checkout", `b`, __FILE__))
    string newBranch;

    @(option!("checkout", `f|force`, __FILE__))
    bool force;

    @(Argument("branch-or-commit").Optional())
    string target;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git checkout with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("diff")
    .ShortDescription("Show changes between commits, commit and working tree, etc")
    .HelpSections!("description")())
struct Diff
{
    @(Option("cached", "Show differences between index and last commit"))
    bool cached;

    @(Option("staged", "Alias for --cached"))
    bool staged;

    @(Argument("pathspec").Optional())
    string[] pathspecs;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git diff with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("init")
    .ShortDescription("Create an empty Git repository or reinitialize an existing one")
    .HelpSections!("description")())
struct Init
{
    @(Option("bare", "Create a bare repository"))
    bool bare;

    @(Argument("directory").Optional())
    string directory;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git init with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("clone")
    .ShortDescription("Clone a repository into a new directory")
    .HelpSections!("description")())
struct Clone
{
    @(Option("depth", "Create a shallow clone with a history truncated to the specified number of commits"))
    int depth;

    @(Option("recursive", "After the clone is created, initialize all submodules within"))
    bool recursive;

    @(option!("clone", `b`, __FILE__))
    string branch;

    @(Argument("repository"))
    string repository;

    @(Argument("directory").Optional())
    string directory;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git clone with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("clean")
    .ShortDescription("Remove untracked files from the working tree")
    .HelpSections!("description", "interactive mode")())
struct Clean
{
    @(option!("clean", `d`, __FILE__))
    bool deleteDirectories;

    @(option!("clean", `f|force`, __FILE__))
    bool force;

    @(option!("clean", `i|interactive`, __FILE__))
    bool interactive;

    @(option!("clean", `n|dry-run`, __FILE__))
    bool dryRun;

    @(option!("clean", `q|quiet`, __FILE__))
    bool quiet;

    @(option!("clean", `e|exclude`, __FILE__))
    string excludePattern;

    @(option!("clean", `x`, __FILE__))
    bool deleteUntracked;

    @(option!("clean", `X`, __FILE__))
    bool deleteIgnored;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running git clean with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("git")
    .ShortDescription("Distributed version control system")
    .HelpSections!("description", "examples", "environment", "further-reading")())
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
