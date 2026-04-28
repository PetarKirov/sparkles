#!/usr/bin/env dub
/+ dub.sdl:
name "git"
dependency "sparkles:core-cli" path="../../../../.."
targetPath "build"
+/
// ci: build-only

import sparkles.core_cli.args;
import sparkles.core_cli.prettyprint : prettyPrint;
import sparkles.core_cli.styled_template : styledWriteln;
import std.sumtype;

int main(string[] args) => runCli!Git(args);

@(Command("add",
    shortDescription: "Add file contents to the index",
    helpSections: ["description"],
))
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

    @(Argument("pathspec", optional: true))
    string[] pathspecs;

    void run() =>
        styledWriteln(i"Running {bold git add} with params:\n$(prettyPrint(this))");
}

@(Command("commit",
    shortDescription: "Record changes to the repository",
    helpSections: ["description"],
))
struct Commit
{
    @(Option(`m|message`))
    string message;

    @(Option(`a|all`))
    bool all;

    @(Option(`v|verbose`))
    bool verbose;

    @(Option("amend", description: "Amend the last commit"))
    bool amend;

    void run() =>
        styledWriteln(i"Running {bold git commit} with params:\n$(prettyPrint(this))");
}

@(Command("push",
    shortDescription: "Update remote refs along with associated objects",
    helpSections: ["description"],
))
struct Push
{
    @(Option(`u|set-upstream`))
    bool setUpstream;

    @(Option(`f|force`))
    bool force;

    @(Option("tags", description: "Push all tags"))
    bool tags;

    @(Argument("repository", optional: true))
    string repository;

    @(Argument("refspec", optional: true))
    string[] refspecs;

    void run() =>
        styledWriteln(i"Running {bold git push} with params:\n$(prettyPrint(this))");
}

@(Command("pull",
    shortDescription: "Fetch from and integrate with another repository or a local branch",
    helpSections: ["description"],
))
struct Pull
{
    @(Option("rebase", description: "Fetch from and integrate with another repository or a local branch"))
    bool rebase;

    @(Argument("repository", optional: true))
    string repository;

    @(Argument("refspec", optional: true))
    string[] refspecs;

    void run() =>
        styledWriteln(i"Running {bold git pull} with params:\n$(prettyPrint(this))");
}

@(Command("status",
    shortDescription: "Show the working tree status",
    helpSections: ["description"],
))
struct Status
{
    @(Option(`s|short`))
    bool short_;

    @(Option(`b|branch`))
    bool branch;

    void run() =>
        styledWriteln(i"Running {bold git status} with params:\n$(prettyPrint(this))");
}

@(Command("log",
    shortDescription: "Show commit logs",
    helpSections: ["description"],
))
struct Log
{
    @(Option(`n|max-count`))
    int maxCount = -1;

    @(Option("oneline", description: "Shorten commit hash and show only the first line of the commit message"))
    bool oneline;

    @(Option("graph", description: "Show an ASCII graph of the commit history"))
    bool graph;

    @(Option(`p|patch`))
    bool patch;

    @(Argument("revision-range", optional: true))
    string revisionRange;

    void run() =>
        styledWriteln(i"Running {bold git log} with params:\n$(prettyPrint(this))");
}

@(Command("branch",
    shortDescription: "List, create, or delete branches",
    helpSections: ["description"],
))
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

    @(Argument("branchname", optional: true))
    string branchName;

    void run() =>
        styledWriteln(i"Running {bold git branch} with params:\n$(prettyPrint(this))");
}

@(Command("checkout",
    shortDescription: "Switch branches or restore working tree files",
    helpSections: ["description"],
))
struct Checkout
{
    @(Option(`b`))
    string newBranch;

    @(Option(`f|force`))
    bool force;

    @(Argument("branch-or-commit", optional: true))
    string target;

    void run() =>
        styledWriteln(i"Running {bold git checkout} with params:\n$(prettyPrint(this))");
}

@(Command("diff",
    shortDescription: "Show changes between commits, commit and working tree, etc",
    helpSections: ["description"],
))
struct Diff
{
    @(Option("cached", description: "Show differences between index and last commit"))
    bool cached;

    @(Option("staged", description: "Alias for --cached"))
    bool staged;

    @(Argument("pathspec", optional: true))
    string[] pathspecs;

    void run() =>
        styledWriteln(i"Running {bold git diff} with params:\n$(prettyPrint(this))");
}

@(Command("init",
    shortDescription: "Create an empty Git repository or reinitialize an existing one",
    helpSections: ["description"],
))
struct Init
{
    @(Option("bare", description: "Create a bare repository"))
    bool bare;

    @(Argument("directory", optional: true))
    string directory;

    void run() =>
        styledWriteln(i"Running {bold git init} with params:\n$(prettyPrint(this))");
}

@(Command("clone",
    shortDescription: "Clone a repository into a new directory",
    helpSections: ["description"],
))
struct Clone
{
    @(Option("depth", description: "Create a shallow clone with a history truncated to the specified number of commits"))
    int depth;

    @(Option("recursive", description: "After the clone is created, initialize all submodules within"))
    bool recursive;

    @(Option(`b`))
    string branch;

    @(Argument("repository"))
    string repository;

    @(Argument("directory", optional: true))
    string directory;

    void run() =>
        styledWriteln(i"Running {bold git clone} with params:\n$(prettyPrint(this))");
}

@(Command("clean",
    shortDescription: "Remove untracked files from the working tree",
    helpSections: ["description", "interactive mode"],
))
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

    void run() =>
        styledWriteln(i"Running {bold git clean} with params:\n$(prettyPrint(this))");
}

@(Command("git",
    shortDescription: "Distributed version control system",
    helpSections: ["description", "examples", "environment", "further-reading"]
))
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
