/++
Pre-flight gating.

Before any tag is created (unless `--no-verify`), the tool reproduces the green
checks from `docs/guidelines/release.md`: a clean working tree, on `main`, and a
passing `ci --test` / `ci --verify`. Failures are collected and returned so
`app.d` can refuse to tag; per-check progress is reported through
$(LREF PreflightProgress) callbacks so the app can drive a live checklist, and
child `ci` output streams through the `output` callback as it is produced
(instead of a multi-minute silence).
+/
module sparkles.release.preflight;

import sparkles.core_cli.process_utils : isInPath, runStreaming;

import sparkles.release.git : isWorkingTreeClean, currentBranch;

/// The outcome of the pre-flight pass.
struct PreflightResult
{
    bool ok;
    string[] failures;
}

/// Progress callbacks for a live checklist; any of them may be null.
struct PreflightProgress
{
    void delegate(string label) started;                        /// a check began
    void delegate(string label, bool ok, string detail) finished; /// … and ended
    void delegate(scope const(char)[] line) output;             /// live child-output line
}

/// Runs every pre-flight check (from `repoRoot`) and reports all failures.
PreflightResult runPreflight(
    string repoRoot, PreflightProgress progress = PreflightProgress.init)
{
    string[] failures;

    // Runs one named check; `check` returns null on success, else the failure
    // text (which is both reported to the callback and collected).
    void step(string label, string delegate() check)
    {
        if (progress.started)
            progress.started(label);
        auto failure = check();
        if (progress.finished)
            progress.finished(label, failure is null, failure);
        if (failure !is null)
            failures ~= failure;
    }

    step("working tree clean", {
        auto clean = isWorkingTreeClean();
        if (clean.hasError)
            return "git status failed: " ~ clean.error;
        if (!clean.value)
            return "working tree has uncommitted changes";
        return null;
    });

    step("on branch main", {
        auto branch = currentBranch();
        if (branch.hasError)
            return "branch check failed: " ~ branch.error;
        if (branch.value == "HEAD")
            return "detached HEAD; checkout main before releasing";
        if (branch.value != "main")
            return "not on main (on " ~ branch.value ~ ")";
        return null;
    });

    const ci = ciInvocation();
    if (ci.length == 0)
    {
        const msg = "ci tool not found (need `ci` on PATH or `nix` + flake); "
            ~ "use --no-verify to skip";
        if (progress.started)
            progress.started("ci checks");
        if (progress.finished)
            progress.finished("ci checks", false, msg);
        failures ~= msg;
    }
    else
    {
        step("ci --test",
            () => runCi(ci, ["--test", "--fail-fast"], repoRoot, "ci --test",
                progress.output));
        step("ci --verify README.md",
            () => runCi(ci, ["--verify", "--files", "README.md"], repoRoot,
                "ci --verify", progress.output));
    }

    return PreflightResult(
        ok: failures.length == 0,
        failures: failures,
    );
}

/// How to invoke `ci`: a bare `ci` when on PATH (the nix `release` package bundles
/// the flake-built one), else `nix run .#ci --`, else empty (unavailable).
string[] ciInvocation() @safe
{
    if (isInPath("ci"))
        return ["ci"];
    if (isInPath("nix"))
        return ["nix", "run", ".#ci", "--"];
    return null;
}

/// Runs a single `ci` sub-command, streaming its (merged) output to `output`
/// as it appears; returns a failure message, or `null` on success.
private string runCi(
    const(string)[] prefix, const(string)[] args, string workDir, string label,
    void delegate(scope const(char)[] line) output)
{
    import std.conv : text;

    const(string)[] argv = prefix ~ args;
    auto r = runStreaming(argv, (scope const(char)[] line) {
        if (output)
            output(line);
    }, workDir);
    if (r.status == 0)
        return null;

    const tail = lastLines(r.stdout, 8);
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

@("preflight.progress.callbacksFireInOrder")
@system unittest
{
    import std.algorithm.searching : canFind;

    // Only the two git-based checks are exercised deterministically here (the
    // ci steps would run the real test suite); this pins the callback protocol:
    // started fires before finished for each label, in declaration order.
    string[] events;
    auto progress = PreflightProgress(
        started: (string label) { events ~= "start:" ~ label; },
        finished: (string label, bool ok, string detail) {
            events ~= "end:" ~ label;
        },
    );

    // A bogus repo root makes the ci steps fail fast rather than run the suite;
    // the git checks run against the real repo (their outcome is not asserted).
    cast(void) runPreflight("/nonexistent-sparkles-preflight-test", progress);

    assert(events.length >= 4);
    assert(events[0] == "start:working tree clean");
    assert(events[1] == "end:working tree clean");
    assert(events[2] == "start:on branch main");
    assert(events[3] == "end:on branch main");
}
