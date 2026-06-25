/++
Pre-flight gating.

Before any tag is created (unless `--no-verify`), the tool reproduces the green
checks from `docs/guidelines/release.md`: a clean working tree, on `main`, and a
passing `ci --test` / `ci --verify`. Failures are collected and returned so
`app.d` can show them all at once and refuse to tag.
+/
module sparkles.release.preflight;

import sparkles.core_cli.process_utils : isInPath, runCaptured;

import sparkles.release.git : isWorkingTreeClean, currentBranch;

@safe:

/// The outcome of the pre-flight pass.
struct PreflightResult
{
    bool ok;
    string[] failures;
}

/// Runs every pre-flight check (from `repoRoot`) and reports all failures.
PreflightResult runPreflight(string repoRoot)
{
    string[] failures;

    auto clean = isWorkingTreeClean();
    if (clean.hasError)
        failures ~= "git status failed: " ~ clean.error;
    else if (!clean.value)
        failures ~= "working tree has uncommitted changes";

    auto branch = currentBranch();
    if (branch.hasError)
        failures ~= "branch check failed: " ~ branch.error;
    else if (branch.value == "HEAD")
        failures ~= "detached HEAD; checkout main before releasing";
    else if (branch.value != "main")
        failures ~= "not on main (on " ~ branch.value ~ ")";

    const ci = ciInvocation();
    if (ci.length == 0)
        failures ~= "ci tool not found (need `ci` on PATH or `nix` + flake); "
            ~ "use --no-verify to skip";
    else
    {
        if (auto f = runCi(ci, ["--test", "--fail-fast"], repoRoot, "ci --test"))
            failures ~= f;
        if (auto f = runCi(ci, ["--verify", "--files", "README.md"], repoRoot, "ci --verify"))
            failures ~= f;
    }

    return PreflightResult(
        ok: failures.length == 0,
        failures: failures,
    );
}

/// How to invoke `ci`: a bare `ci` when on PATH (the nix `release` package bundles
/// the flake-built one), else `nix run .#ci --`, else empty (unavailable).
string[] ciInvocation()
{
    if (isInPath("ci"))
        return ["ci"];
    if (isInPath("nix"))
        return ["nix", "run", ".#ci", "--"];
    return null;
}

/// Runs a single `ci` sub-command; returns a failure message, or `null` on success.
private string runCi(
    const(string)[] prefix, const(string)[] args, string workDir, string label)
{
    import std.conv : text;

    const(string)[] argv = prefix ~ args;
    auto r = runCaptured(argv, null, workDir);
    if (r.status == 0)
        return null;

    const tail = lastLines(r.stderr.length ? r.stderr : r.stdout, 8);
    return label ~ " failed (status " ~ r.status.text ~ ")"
        ~ (tail.length ? ":\n" ~ tail : "");
}

/// The last `n` non-empty lines of `s` (for compact failure output).
private string lastLines(string s, size_t n) @safe pure
{
    import std.string : lineSplitter;
    import std.array : array, join;

    auto lines = s.lineSplitter.array;
    return lines.length <= n ? lines.join("\n") : lines[$ - n .. $].join("\n");
}

@("preflight.lastLines")
@safe pure unittest
{
    assert(lastLines("a\nb\nc\nd", 2) == "c\nd");
    assert(lastLines("a\nb", 5) == "a\nb");
}
