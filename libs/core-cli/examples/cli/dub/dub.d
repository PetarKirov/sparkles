#!/usr/bin/env dub
/+ dub.sdl:
    name "dub"
    dependency "sparkles:core-cli" path="../../../../.."
    targetPath "build"
+/
// ci: build-only

import sparkles.core_cli.args;
import sparkles.core_cli.prettyprint : prettyPrint;
import std.sumtype;

@(Command("build", "b")
    .shortDescription("Builds a package (uses the main package in the current working directory by default)")
    .helpSections!("description")())
struct Build
{
    @(Option(`b|build`).allowedValues(
        "debug", "plain", "release", "release-debug", "release-nobounds",
        "unittest", "profile", "profile-gc", "docs", "ddox",
        "cov", "unittest-cov", "syntax",
    ))
    string buildType = "debug";

    @(Option(`compiler`).allowedValues("dmd", "ldc", "ldc2", "gdc"))
    string compiler;

    @(Option(`a|arch`))
    string arch;

    @(Option(`c|config`))
    string[] configs;

    @(Option(`f|force`))
    bool force;

    @(Option("combined", "Tries to build the whole project in a single compiler run"))
    bool combined;

    @(Option("rdmd", "Use rdmd instead of directly invoking the compiler"))
    bool rdmd;

    @(Option(`build-mode`).allowedValues("separate", "allAtOnce", "singleFile"))
    string buildMode = "separate";

    @(Option("temp-build", "Builds the project in the temp folder if possible"))
    bool tempBuild;

    @(Argument("package").optional())
    string packageName;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub build with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("run", "r")
    .shortDescription("Builds and runs a package")
    .helpSections!("description")())
struct Run
{
    @(Option(`b|build`).allowedValues(
        "debug", "plain", "release", "release-debug", "release-nobounds",
        "unittest", "profile", "profile-gc", "cov",
    ))
    string buildType = "debug";

    @(Option(`compiler`).allowedValues("dmd", "ldc", "ldc2", "gdc"))
    string compiler;

    @(Option(`c|config`))
    string[] configs;

    @(Option(`f|force`))
    bool force;

    @(Option("temp-build", "Builds in temp directory and runs from there"))
    bool tempBuild;

    @(Argument("package").optional())
    string packageName;

    @(Argument("program-args").optional())
    string[] programArgs;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub run with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("test", "t")
    .shortDescription("Executes the tests of the selected package")
    .helpSections!("description")())
struct Test
{
    @(Option(`b|build`).allowedValues(
        "unittest", "unittest-cov", "unittest-cov-ctfe", "debug",
    ))
    string buildType = "unittest";

    @(Option(`compiler`).allowedValues("dmd", "ldc", "ldc2", "gdc"))
    string compiler;

    @(Option(`c|config`))
    string[] configs;

    @(Option(`f|force`))
    bool force;

    @(Option("combined", "Tries to build the whole project in a single compiler run"))
    bool combined;

    @(Option("parallel", "Runs multiple compiler instances in parallel, if possible"))
    bool parallel_;

    @(Option("test", "Execute the built test binary after compilation. Pass --no-test to compile without running, e.g. for cross-compilation pipelines."))
    bool test_ = true;

    @(Option("coverage", "Enables code coverage statistics to be generated"))
    bool coverage;

    @(Option("coverage-ctfe", "Enables code coverage (including CTFE) statistics to be generated"))
    bool coverageCtfe;

    @(Option("main-file", "Specifies a custom file containing the main() function to use for running the tests"))
    string mainFile;

    @(Argument("package").optional())
    string packageName;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub test with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("clean")
    .shortDescription("Removes intermediate build files and cached build results")
    .helpSections!("description")())
struct Clean
{
    @(Option("all-packages", "Cleans all known packages, regardless of whether they are used by the current package or not"))
    bool allPackages;

    @(Option(`root`))
    string rootPath;

    @(Argument("package").optional())
    string packageName;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub clean with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("init")
    .shortDescription("Initializes an empty package skeleton")
    .helpSections!("description")())
struct Init
{
    @(Option(`t|type`)
        .required()
        .allowedValues("minimal", "vibe.d", "deimos", "custom"))
    string type;

    @(Option(`f|format`).allowedValues("json", "sdl"))
    string format = "json";

    @(Option(`n|non-interactive`))
    bool nonInteractive;

    @(Argument("directory").optional())
    string directory;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub init with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("fetch")
    .shortDescription("Explicitly retrieves and caches packages")
    .helpSections!("description")())
struct Fetch
{
    @(Option(`r|recursive`, "Also fetches dependencies of specified packages"))
    bool recursive;

    @(Option(`cache`).allowedValues("local", "user", "system"))
    string cache = "user";

    @(Argument("package"))
    string packageName;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub fetch with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("add")
    .shortDescription("Adds dependencies to the package file")
    .helpSections!("description")())
struct Add
{
    @(Option("recipe", "Override path to recipe file (dub.sdl/dub.json)"))
    string recipe;

    @(Argument("packages"))
    string[] packages;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub add with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("remove", "uninstall")
    .shortDescription("Removes a cached package")
    .helpSections!("description")())
struct Remove
{
    @(Option(`n|non-interactive`, "Don't enter interactive mode"))
    bool nonInteractive;

    @(Argument("package"))
    string packageName;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub remove with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("upgrade")
    .shortDescription("Forces an upgrade of the dependencies")
    .helpSections!("description")())
struct Upgrade
{
    @(Option(`prerelease`, "Uses the latest pre-release version, even if release versions are available"))
    bool prerelease;

    @(Option(`s|sub-packages`, "Also upgrades dependencies of all directory based sub packages"))
    bool subPackages;

    @(Option(`verify`, "Updates the project and performs a build; if successful, rewrites the selected versions file"))
    bool verify;

    @(Option(`dry-run`, "Only print what would be upgraded, but don't actually upgrade anything"))
    bool dryRun;

    @(Argument("packages").optional())
    string[] packages;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub upgrade with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("describe")
    .shortDescription("Prints a JSON description of the project and its dependencies")
    .helpSections!("description")())
struct Describe
{
    @(Option(`data`))
    string[] data;

    @(Option("data-list", "Output --data information separated by newlines instead of spaces"))
    bool dataList;

    @(Option(`compiler`).allowedValues("dmd", "ldc", "ldc2", "gdc"))
    string compiler;

    @(Option(`c|config`))
    string config;

    @(Argument("package").optional())
    string packageName;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub describe with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("lint")
    .shortDescription("Executes the linter tests of the selected package")
    .helpSections!("description")())
struct Lint
{
    @(Option(`syntax-check`))
    bool syntaxCheck;

    @(Option(`style-check`))
    bool styleCheck;

    @(Option(`report-format`).allowedValues("default", "checkstyle", "github"))
    string reportFormat = "default";

    @(Option(`report-file`))
    string reportFile;

    @(Argument("package").optional())
    string packageName;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub lint with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("search")
    .shortDescription("Search for available packages")
    .helpSections!("description")())
struct Search
{
    @(Option(`skip-registry`).allowedValues("none", "standard", "configured", "all"))
    string skipRegistry = "none";

    @(Option(`registry`))
    string registry;

    @(Argument("query"))
    string query;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running dub search with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("dub")
    .shortDescription("Package manager and build tool for the D programming language")
    .helpSections!("description", "examples")())
struct Dub
{
    @(Option(`v|verbose`).counter())
    uint verbose;

    @(Option(`q|quiet`))
    bool quiet;

    @(Option(`vquiet`))
    bool vquiet;

    @(Option(`color`).allowedValues("auto", "always", "never"))
    string color = "auto";

    @Subcommands
    SumType!(
        Add,
        Build,
        Clean,
        Describe,
        Fetch,
        Init,
        Lint,
        Remove,
        Run,
        Search,
        Test,
        Upgrade,
    ) command;
}

int main(string[] args)
{
    return runCli!Dub(args, HelpInfo("dub", "Package manager and build tool for the D programming language"));
}
