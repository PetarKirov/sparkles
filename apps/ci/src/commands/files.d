/// Which files a command reads: tracked files, `--include-files` and
/// `--exclude-files` selection, and the repository root.
module commands.files;

import cli : FileSelection;
import sparkles.base.expected : ok;
import sparkles.base.logger : error;
import sparkles.core_cli.args : failRun, RunError, RunExpected;
import std.algorithm : canFind, filter, map, startsWith;
import std.array : array;
import std.conv : text, to;
import std.path : globMatch;
import std.process : execute;
import std.string : endsWith, lineSplitter, strip;

private string[] trackedMarkdownFiles()
{
    const result = execute(["git", "ls-files", "--", "*.md"]);
    if (result.status != 0)
    {
        error(i"Failed to enumerate markdown files with git ls-files");
        return [];
    }

    return result.output
        .lineSplitter
        .filter!(line => line.length != 0)
        .map!(line => line.idup)
        .array;
}

/// Git pathspecs for the repository's standalone example `.d` files — the
/// defaults `ci examples standalone` uses when no `--include-files` selection is
/// given: the `base`, `build-primitives`, and `core-cli` library demos plus the
/// worked examples that accompany the research docs
/// (`docs/research/async-io/io-uring/`, `docs/research/async-io/gcd/`,
/// `docs/research/units-of-measure/`,
/// `docs/research/cpu-pmu/`, `docs/research/sanitizers/`, `docs/research/manim/`,
/// `docs/research/anchored-overlays/`, `docs/research/property-tree/`, and the four
/// per-subject `examples/`
/// directories under `docs/research/platform-ui-guidelines/`).
@safe pure nothrow
private string[] standaloneExampleGlobs()
{
    return [
        "libs/base/examples/*.d",
        "libs/build-primitives/examples/*.d",
        "libs/core-cli/examples/*.d",
        "libs/event-horizon/examples/*.d",
        "docs/libs/event-horizon/tutorial/snippets/*.d",
        "libs/wired/examples/*.d",
        "libs/http/examples/*.d",
        "docs/research/async-io/io-uring/examples/*.d",
        "docs/research/async-io/gcd/examples/*.d",
        "docs/research/build-systems/examples/*.d",
        "docs/research/units-of-measure/examples/*.d",
        "docs/research/cpu-pmu/examples/*.d",
        "docs/research/sanitizers/examples/*.d",
        "docs/research/manim/examples/*.d",
        "docs/research/anchored-overlays/examples/*.d",
        "docs/research/property-tree/examples/*.d",
        "docs/research/algebraic-effects/durable-execution/examples/*.d",
        "docs/research/images/mir-algorithm/examples/*.d",
        "docs/research/images/wired-flat-fit/examples/*.d",
        "docs/research/platform-ui-guidelines/color-derivation/examples/*.d",
        "docs/research/platform-ui-guidelines/gnome/examples/*.d",
        "docs/research/platform-ui-guidelines/kde/examples/*.d",
        "docs/research/platform-ui-guidelines/terminal/examples/*.d",
        "docs/research/autological-artifacts/cosmopolitan-ape/examples/*.d",
        "docs/research/autological-artifacts/self-selfdb/examples/*.d",
        "docs/research/linux-on-macos/examples/*.d",
        "docs/research/android-dev-env/concepts/examples/*.d",
        "docs/research/android-dev-env/device-validation/examples/*.d",
        "docs/research/android-dev-env/termux-play-store/examples/*.d",
        "docs/research/safe-path-traversal/examples/*.d",
        "docs/research/font-libraries/examples/*.d",
        "docs/research/fine-grained-locking/examples/*.d",
        "docs/research/shading-languages/examples/*.d",
    ];
}

private string[] trackedStandaloneExampleFiles()
{
    const result = execute(["git", "ls-files", "--"] ~ standaloneExampleGlobs());
    if (result.status != 0)
    {
        error(i"Failed to enumerate standalone example files with git ls-files");
        return [];
    }

    return result.output
        .lineSplitter
        .filter!(line => line.length != 0)
        .map!(line => line.idup)
        .array;
}

@safe pure nothrow @nogc
private bool isGlobSelector(string selector)
{
    return selector.canFind("*")
        || selector.canFind("?")
        || selector.canFind("[");
}

/// True when `path` should be dropped by a single `--exclude-files` selector.
///
/// Glob selectors use $(REF globMatch, std,path) (supports `**`). Non-glob
/// selectors match the path exactly, or any path under that directory
/// (`libs/foo` excludes `libs/foo` and `libs/foo/bar.md`).
@safe pure
private bool pathMatchesExclude(string path, string selector)
{
    if (path.length == 0 || selector.length == 0)
        return false;

    if (isGlobSelector(selector))
        return globMatch(path, selector);

    if (path == selector)
        return true;

    // Directory / prefix form: `libs/syntax/test/data` excludes the tree.
    const prefix = selector.endsWith("/") ? selector : selector ~ "/";
    return path.startsWith(prefix);
}

/// True when `path` matches any selector in `excludeSelectors`.
@safe pure
private bool isExcludedBy(string path, const(string)[] excludeSelectors)
{
    foreach (selector; excludeSelectors)
        if (pathMatchesExclude(path, selector))
            return true;
    return false;
}

@("ci.pathMatchesExclude.globAndPrefix")
@safe pure
unittest
{
    enum golden = "libs/syntax/test/data/md/goldens/code-tall.md";

    assert(pathMatchesExclude(golden, "libs/syntax/test/data/**"));
    assert(pathMatchesExclude(golden, "**/goldens/**"));
    assert(pathMatchesExclude(golden, "libs/syntax/test/data"));
    assert(pathMatchesExclude(golden, "libs/syntax/test/data/"));
    assert(pathMatchesExclude(golden, golden));
    assert(!pathMatchesExclude(golden, "libs/syntax/test/other/**"));
    assert(!pathMatchesExclude(golden, "libs/syntax/test/dat")); // not a path prefix
    assert(!pathMatchesExclude("README.md", "libs/syntax/test/data/**"));
    assert(!pathMatchesExclude("", "**"));
    assert(!pathMatchesExclude(golden, ""));
}

@("ci.isExcludedBy.anySelector")
@safe pure
unittest
{
    enum golden = "libs/syntax/test/data/md/goldens/code-tall.md";
    assert(isExcludedBy(golden, ["docs/**", "libs/syntax/test/data/**"]));
    assert(!isExcludedBy(golden, ["docs/**", "apps/**"]));
    assert(!isExcludedBy(golden, cast(string[])[]));
}

private string[] trackedFilesMatching(string pattern)
{
    const result = execute(["git", "ls-files", "--", pattern]);
    if (result.status != 0)
    {
        error(i"Failed to enumerate tracked files matching $(pattern)");
        return [];
    }

    return result.output
        .lineSplitter
        .filter!(line => line.length != 0)
        .map!(line => line.idup)
        .array;
}

/// The files `selectors` name: globs through `git ls-files`, paths as given.
package string[] selectedFiles(in string[] selectors)
{
    string[] selected;
    foreach (selector; selectors)
    {
        if (selector.length == 0)
            continue;

        if (isGlobSelector(selector))
            selected ~= trackedFilesMatching(selector);
        else
            selected ~= selector.idup;
    }
    return selected;
}

/// What a file-selecting command reads by default, and which files it takes.
package enum InputFiles
{
    markdown,         /// `.md` files, by default the tracked ones
    markdownExamples, /// `.md` files, with no default: the files must be named
    standalone,       /// `.d` example programs, by default the tracked example directories
}

/**
The files a command reads: `files.include` (or the defaults of `kind`), minus
`files.exclude`. An error when nothing is left: a selection that matched
nothing is a mistake, and so is a command with no default given no files.
*/
package RunExpected!(string[]) collectInputFiles(in FileSelection files, InputFiles kind, string command)
{
    string[] inputFiles = selectedFiles(files.include);
    if (inputFiles.length == 0 && files.include.length == 0)
        final switch (kind)
        {
            case InputFiles.markdown:
                inputFiles = trackedMarkdownFiles();
                break;
            case InputFiles.standalone:
                inputFiles = trackedStandaloneExampleFiles();
                break;
            case InputFiles.markdownExamples:
                return failRun!(string[])(command ~ " needs --include-files FILE|GLOB...");
        }

    const requiredSuffix = kind == InputFiles.standalone ? ".d" : ".md";
    auto selected = inputFiles
        .filter!(path => path.length > 0)
        .filter!(path => path.endsWith(requiredSuffix))
        .filter!(path => !isExcludedBy(path, files.exclude))
        .map!(path => path.idup)
        .array;
    if (selected.length == 0)
        return failRun!(string[])(text(command, ": the selection matched no ", requiredSuffix, " file"));
    return ok!RunError(selected);
}

string detectRepoRoot()
{
    const result = execute(["git", "rev-parse", "--show-toplevel"]);
    return result.status == 0
        ? result.output.strip
        : null;
}
