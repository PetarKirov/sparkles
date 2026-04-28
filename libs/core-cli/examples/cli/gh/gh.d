#!/usr/bin/env dub
/+ dub.sdl:
    name "gh"
    dependency "sparkles:core-cli" path="../../../../.."
    targetPath "build"
+/
// ci: build-only

import sparkles.core_cli.args;
import sparkles.core_cli.prettyprint : prettyPrint;
import std.sumtype;

// ─── auth ────────────────────────────────────────────────────────────────

@(Command("login")
    .shortDescription("Authenticate with a GitHub host")
    .helpSections!("description")())
struct AuthLogin
{
    @(Option(`h|hostname`, "Hostname of the GitHub instance to authenticate with"))
    string hostname = "github.com";

    @(Option(`s|scopes`, "Additional OAuth scopes to request. Can be specified multiple times."))
    string[] scopes;

    @(Option(`p|git-protocol`).allowedValues("https", "ssh"))
    string gitProtocol = "https";

    @(Option(`w|web`, "Open a browser to authenticate"))
    bool web;

    @(Option(`with-token`, "Read token from standard input"))
    bool withToken;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh auth login with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("logout")
    .shortDescription("Log out of a GitHub host")
    .helpSections!("description")())
struct AuthLogout
{
    @(Option(`h|hostname`, "Hostname to forget credentials for"))
    string hostname = "github.com";

    @(Option(`u|user`, "User account to log out, when more than one is configured"))
    string user;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh auth logout with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("status")
    .shortDescription("View authentication status")
    .helpSections!("description")())
struct AuthStatus
{
    @(Option(`h|hostname`, "Restrict the report to a single host"))
    string hostname;

    @(Option(`t|show-token`, "Display the auth token in the output"))
    bool showToken;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh auth status with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("refresh")
    .shortDescription("Refresh stored authentication credentials")
    .helpSections!("description")())
struct AuthRefresh
{
    @(Option(`h|hostname`, "Hostname to refresh credentials for"))
    string hostname = "github.com";

    @(Option(`s|scopes`, "Additional OAuth scopes to request. Can be specified multiple times."))
    string[] scopes;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh auth refresh with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("auth")
    .shortDescription("Authenticate gh and git with GitHub")
    .helpSections!("description")())
struct Auth
{
    @Subcommands
    SumType!(AuthLogin, AuthLogout, AuthStatus, AuthRefresh) command;
}

// ─── repo ────────────────────────────────────────────────────────────────

@(Command("create")
    .shortDescription("Create a new repository")
    .helpSections!("description")())
struct RepoCreate
{
    @(Option(`d|description`, "Description of the repository"))
    string description_;

    @(Option(`public`, "Make the new repository public"))
    bool public_;

    @(Option(`private`, "Make the new repository private"))
    bool private_;

    @(Option(`internal`, "Make the new repository internal to the organization"))
    bool internal;

    @(Option(`team`, "The team that should have access to this repository"))
    string team;

    @(Option(`clone`, "Clone the new repository to the local machine"))
    bool clone;

    @(Argument("name").optional())
    string name;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh repo create with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("clone")
    .shortDescription("Clone a repository locally")
    .helpSections!("description")())
struct RepoClone
{
    @(Option(`u|upstream-remote-name`, "Remote name for the upstream when cloning a fork"))
    string upstreamRemoteName = "upstream";

    @(Argument("repository"))
    string repository;

    @(Argument("directory").optional())
    string directory;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh repo clone with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("view")
    .shortDescription("View a repository")
    .helpSections!("description")())
struct RepoView
{
    @(Option(`w|web`, "Open the repository in a web browser"))
    bool web;

    @(Option(`b|branch`, "View the contents on the named branch"))
    string branch;

    @(Argument("repository").optional())
    string repository;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh repo view with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("list")
    .shortDescription("List repositories owned by user or organization")
    .helpSections!("description")())
struct RepoList
{
    @(Option(`L|limit`, "Maximum number of repositories to list"))
    int limit = 30;

    @(Option(`visibility`).allowedValues("public", "private", "internal"))
    string visibility;

    @(Option(`l|language`, "Filter by primary language"))
    string language;

    @(Option(`source`, "Show only non-fork repositories"))
    bool source;

    @(Option(`fork`, "Show only forks"))
    bool fork;

    @(Argument("owner").optional())
    string owner;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh repo list with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("fork")
    .shortDescription("Create a fork of a repository")
    .helpSections!("description")())
struct RepoFork
{
    @(Option(`clone`, "Clone the fork after creation"))
    bool clone;

    @(Option(`remote`, "Add a git remote for the fork"))
    bool remote;

    @(Option(`org`, "The organization to fork into"))
    string org;

    @(Argument("repository").optional())
    string repository;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh repo fork with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("repo")
    .shortDescription("Work with GitHub repositories")
    .helpSections!("description")())
struct Repo
{
    @Subcommands
    SumType!(RepoClone, RepoCreate, RepoFork, RepoList, RepoView) command;
}

// ─── pr ──────────────────────────────────────────────────────────────────

@(Command("create")
    .shortDescription("Create a pull request")
    .helpSections!("description")())
struct PrCreate
{
    @(Option(`t|title`).required())
    string title;

    @(Option(`b|body`, "Body of the pull request"))
    string body_;

    @(Option(`B|base`, "Branch to merge the pull request into"))
    string base;

    @(Option(`H|head`, "Branch the pull request originates from"))
    string head;

    @(Option(`d|draft`, "Create the pull request as a draft"))
    bool draft;

    @(Option(`r|reviewer`, "Request a review from the given user or team. Can be specified multiple times."))
    string[] reviewers;

    @(Option(`a|assignee`, "Assign the PR to the given user. Can be specified multiple times."))
    string[] assignees;

    @(Option(`l|label`, "Add the given label to the PR. Can be specified multiple times."))
    string[] labels;

    @(Option(`web`).hidden())
    bool web;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh pr create with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("list")
    .shortDescription("List pull requests in a repository")
    .helpSections!("description")())
struct PrList
{
    @(Option(`s|state`).allowedValues("open", "closed", "merged", "all"))
    string state = "open";

    @(Option(`a|assignee`, "Filter by assignee"))
    string assignee;

    @(Option(`A|author`, "Filter by author"))
    string author;

    @(Option(`l|label`, "Filter by label. Can be specified multiple times."))
    string[] labels;

    @(Option(`L|limit`, "Maximum number of pull requests to fetch"))
    int limit = 30;

    @(Option(`B|base`, "Filter by base branch"))
    string base;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh pr list with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("view")
    .shortDescription("View a pull request")
    .helpSections!("description")())
struct PrView
{
    @(Option(`w|web`, "Open the pull request in a web browser"))
    bool web;

    @(Option(`c|comments`, "View pull request comments"))
    bool comments;

    @(Argument("number").optional())
    string number;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh pr view with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("checkout", "co")
    .shortDescription("Check out a pull request in git")
    .helpSections!("description")())
struct PrCheckout
{
    @(Option(`b|branch`, "Local branch name to use for the checkout"))
    string branch;

    @(Option(`detach`, "Check out the PR with a detached HEAD"))
    bool detach;

    @(Option(`f|force`, "Reset the existing local branch to the latest PR state"))
    bool force;

    @(Argument("number"))
    string number;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh pr checkout with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("merge")
    .shortDescription("Merge a pull request")
    .helpSections!("description")())
struct PrMerge
{
    @(Option(`merge-method`).allowedValues("merge", "squash", "rebase"))
    string mergeMethod = "merge";

    @(Option(`d|delete-branch`, "Delete the local and remote branch after the merge"))
    bool deleteBranch;

    @(Option(`auto`, "Enable auto-merge once required checks pass"))
    bool auto_;

    @(Option(`subject`, "Subject text for the merge commit"))
    string subject;

    @(Argument("number").optional())
    string number;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh pr merge with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("close")
    .shortDescription("Close a pull request")
    .helpSections!("description")())
struct PrClose
{
    @(Option(`c|comment`, "Leave a closing comment on the pull request"))
    string comment;

    @(Option(`d|delete-branch`, "Delete the local and remote branch after closing"))
    bool deleteBranch;

    @(Argument("number"))
    string number;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh pr close with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("pr")
    .shortDescription("Work with GitHub pull requests")
    .helpSections!("description")())
struct Pr
{
    @Subcommands
    SumType!(PrCheckout, PrClose, PrCreate, PrList, PrMerge, PrView) command;
}

// ─── issue ───────────────────────────────────────────────────────────────

@(Command("create")
    .shortDescription("Create a new issue")
    .helpSections!("description")())
struct IssueCreate
{
    @(Option(`t|title`).required())
    string title;

    @(Option(`b|body`, "Body of the issue"))
    string body_;

    @(Option(`a|assignee`, "Assign the issue to the given user. Can be specified multiple times."))
    string[] assignees;

    @(Option(`l|label`, "Apply the given label. Can be specified multiple times."))
    string[] labels;

    @(Option(`m|milestone`, "Add the issue to the given milestone"))
    string milestone;

    @(Option(`p|project`, "Add the issue to the given project. Can be specified multiple times."))
    string[] projects;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh issue create with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("list")
    .shortDescription("List issues in a repository")
    .helpSections!("description")())
struct IssueList
{
    @(Option(`s|state`).allowedValues("open", "closed", "all"))
    string state = "open";

    @(Option(`a|assignee`, "Filter by assignee"))
    string assignee;

    @(Option(`A|author`, "Filter by author"))
    string author;

    @(Option(`l|label`, "Filter by label. Can be specified multiple times."))
    string[] labels;

    @(Option(`L|limit`, "Maximum number of issues to fetch"))
    int limit = 30;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh issue list with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("view")
    .shortDescription("View an issue")
    .helpSections!("description")())
struct IssueView
{
    @(Option(`w|web`, "Open the issue in a web browser"))
    bool web;

    @(Option(`c|comments`, "View issue comments"))
    bool comments;

    @(Argument("number"))
    string number;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh issue view with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("close")
    .shortDescription("Close an issue")
    .helpSections!("description")())
struct IssueClose
{
    @(Option(`c|comment`, "Leave a closing comment on the issue"))
    string comment;

    @(Option(`r|reason`).allowedValues("completed", "not planned"))
    string reason = "completed";

    @(Argument("number"))
    string number;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running gh issue close with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("issue")
    .shortDescription("Work with GitHub issues")
    .helpSections!("description")())
struct Issue
{
    @Subcommands
    SumType!(IssueClose, IssueCreate, IssueList, IssueView) command;
}

// ─── root ────────────────────────────────────────────────────────────────

@(Command("gh")
    .shortDescription("GitHub's official command line tool")
    .helpSections!("description", "examples")())
struct Gh
{
    @Subcommands
    SumType!(Auth, Issue, Pr, Repo) command;
}

int main(string[] args)
{
    return runCli!Gh(args, HelpInfo("gh", "GitHub's official command line tool"));
}
