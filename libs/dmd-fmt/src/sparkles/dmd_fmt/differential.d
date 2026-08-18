/**
M8 — corpus and differential testing, ruff's methodology
(`docs/research/code-formatting/rust-reimplementations.md`):

$(LIST
    * $(B The stability triad), run over every corpus file on every test
        run: the second pass must equal the first (idempotence via the M1
        harness), the output must remain token-equivalent with DDoc
        attachment intact (the M1 verifier — a stronger check than "output
        reparses"), and nothing may crash.
    * $(B The similarity index), ruff's published definition — neutral
        lines ÷ (neutral + removed) — computed with `sparkles:diff`.
        Per decision D3's amendment of ruff's practice it is a $(B ratchet,
        not a gate): beating dfmt's ceilings lowers dfmt-similarity by
        design, so the triad gates and the index informs. The index against
        the $(B original) is asserted with a generous floor purely as a
        churn tripwire: v1's author's-breaks policy should leave
        well-formatted code substantially alone.
    * $(B The dfmt differential) proper runs when a `dfmt` binary is
        present (it is not part of the dev shell); absent one, the test
        skips — external tooling is genuinely optional environment, unlike
        the flake-provided corpus.
)
*/
module sparkles.dmd_fmt.differential;

/**
ruff's similarity index between an old and a new text: the fraction of the
old text's lines that survive unchanged — neutral ÷ (neutral + removed).
`1.0` means untouched, `0.0` means every line changed.
*/
double similarityIndex(const(char)[] old, const(char)[] new_) @safe
{
    import sparkles.diff.myers : diffLines, splitDiffLines;

    bool missingA, missingB;
    auto oldLines = splitDiffLines(old, missingA);
    auto newLines = splitDiffLines(new_, missingB);
    if (!oldLines.length)
        return 1.0;
    const diff = diffLines(old, oldLines, new_, newLines, 4096);
    size_t neutral;
    foreach (i; 0 .. oldLines.length)
        if (!diff.oldRemoved[][i])
            neutral++;
    return cast(double) neutral / cast(double) oldLines.length;
}

@("differential.similarityIndex.definition")
@safe unittest
{
    assert(similarityIndex("a\nb\nc\n", "a\nb\nc\n") == 1.0);
    assert(similarityIndex("a\nb\nc\nd\n", "a\nx\ny\nd\n") == 0.5);
    assert(similarityIndex("", "anything\n") == 1.0);
    assert(similarityIndex("a\n", "b\n") == 0.0);
}

version (unittest)
{
    import sparkles.dmd_fmt.config : FormatConfig;
    import sparkles.dmd_fmt.printer : formatText;
    import sparkles.dmd_fmt.verify : checkConvergence, verifyFormat;

    /// The triad for one file; returns null or a description.
    private string triad(string name, string source) @system
    {
        import std.format : format;

        const formatted = formatText(source);
        const report = verifyFormat(source, formatted);
        if (!report.ok)
            return name ~ ": " ~ (report.tokenError !is null
                ? report.tokenError : report.ddocError);
        const conv = checkConvergence(
            (const(char)[] s) => cast(const(char)[]) formatText(s), source);
        if (conv.error !is null)
            return name ~ " (iteration " ~ format!"%s"(conv.iterations)
                ~ "): " ~ conv.error;
        if (!conv.converged)
            return name ~ ": did not converge within the bound";
        return null;
    }
}

@("differential.triad.repo-corpus")
@system unittest
{
    import core.exception : AssertError;
    import std.file : dirEntries, read, SpanMode;
    import std.path : buildPath, dirName;

    enum thisDir = __FILE_FULL_PATH__.dirName;
    enum repoRoot = thisDir.dirName.dirName.dirName.dirName.dirName;
    static immutable corpusDirs = [
        "libs/base/src",
        "libs/dmd-fmt/src",
        "libs/dmd-lsp/src",
    ];

    size_t files;
    double similaritySum = 0;
    foreach (dir; corpusDirs)
        foreach (entry; dirEntries(buildPath(repoRoot, dir), "*.d", SpanMode.depth))
        {
            const source = () @trusted { return cast(string) read(entry.name); }();
            if (const err = triad(entry.name, source))
                throw new AssertError(err);
            similaritySum += similarityIndex(source, formatText(source));
            files++;
        }
    assert(files > 20, "corpus unexpectedly small — path resolution broke?");

    // The churn tripwire, not a style gate: the v1 policy must leave
    // well-formatted code substantially alone. Measured mean at pinning
    // time: 0.927 over 54 repo modules; the residue is the documented v1
    // limitations (one continuation level where authors nested several,
    // wrap-policy deltas on width-exceeded lines). The floor trips only on
    // a policy regression, per the index-is-a-ratchet decision.
    const mean = similaritySum / files;
    assert(mean > 0.85, "v1 churn exceeded the tripwire");
}

@("differential.triad.expressionsem-20kloc")
@system unittest
{
    import core.exception : AssertError;
    import std.file : exists, read;
    import std.path : buildPath;
    import std.process : environment;

    const dmdSrc = environment.get("SPARKLES_FLAKE_INPUT_DMD_SRC", "");
    assert(dmdSrc.length,
        "SPARKLES_FLAKE_INPUT_DMD_SRC not set (enter `nix develop`)");
    const path = buildPath(dmdSrc, "compiler", "src", "dmd", "expressionsem.d");
    assert(path.exists,
        "expressionsem.d missing under SPARKLES_FLAKE_INPUT_DMD_SRC: " ~ path);
    const source = () @trusted { return cast(string) read(path); }();
    if (const err = triad("expressionsem.d", source))
        throw new AssertError(err);
}

@("differential.dfmt.similarity-when-available")
@system unittest
{
    import std.process : execute, executeShell;

    import sparkles.test_runner.skip : skipTest;

    // dfmt is deliberately NOT part of the dev shell; comparing against it
    // is optional tooling, so absence skips (unlike the flake corpus).
    const probe = executeShell("command -v dfmt");
    if (probe.status != 0)
        skipTest("no dfmt binary on PATH");

    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    enum sample = "void f(){\nint x=1;\n}\n";
    const tmp = buildPath(tempDir, "dmd-fmt-dfmt-sample.d");
    write(tmp, sample);
    scope (exit)
        remove(tmp);
    const theirs = execute(["dfmt", tmp]);
    assert(theirs.status == 0, theirs.output);
    // The index is a ratchet, reported rather than gated (D3's amendment
    // of ruff's practice) — here we only prove the plumbing computes
    // against a live dfmt.
    const index = similarityIndex(theirs.output, formatText(sample));
    assert(index >= 0.0 && index <= 1.0);
}
