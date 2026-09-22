/**
 * `.gitignore` parsing and matching primitives.
 */
module sparkles.build_primitives.gitignore;

import std.algorithm.searching : startsWith;
import std.array : appender;
import std.range.primitives : put;
import std.string : lineSplitter;

@safe:

/// One parsed `.gitignore` rule.
struct GitIgnoreRule
{
    string pattern;
    bool negated;
    bool directoryOnly;
    bool anchored;
    bool hasSlash;

    /// Path of the `.gitignore` that declared this rule, as given to
    /// $(LREF GitIgnore.parse) or $(LREF GitIgnore.fromFile). Empty when the
    /// rules were parsed without a source path.
    string sourceFile;

    /// 1-based line number of this rule within `sourceFile`. Zero when
    /// unknown. Blank and comment lines are counted, so the number addresses
    /// the file as an editor shows it.
    uint sourceLine;

    /// Returns true when this rule matches `normalizedPath`.
    bool matches(in const(char)[] normalizedPath, bool isDirectory) const pure
    {
        if (pattern.length == 0)
            return false;

        if (directoryOnly)
        {
            if (isDirectory)
                return matchesPath(pattern, normalizedPath, anchored, hasSlash);

            return matchesAnyParentDirectory(pattern, normalizedPath, anchored, hasSlash);
        }

        return matchesPath(pattern, normalizedPath, anchored, hasSlash);
    }
}

private bool matchesPath(
    in string pattern,
    in const(char)[] normalizedPath,
    bool anchored,
    bool hasSlash,
) pure
{
    if (anchored || hasSlash)
        return globMatch(pattern, normalizedPath);

    return matchesAnySegment(pattern, normalizedPath);
}

private bool matchesAnyParentDirectory(
    in string pattern,
    in const(char)[] normalizedPath,
    bool anchored,
    bool hasSlash,
) pure
{
    size_t end;
    while (end < normalizedPath.length)
    {
        if (normalizedPath[end] == '/')
        {
            const dirPath = normalizedPath[0 .. end];
            if (matchesPath(pattern, dirPath, anchored, hasSlash))
                return true;
        }

        end++;
    }

    return false;
}

/// Outcome of matching a path against one `.gitignore` file's rules.
enum IgnoreMatch
{
    none, /// No rule matched; the verdict falls through to outer scopes.
    ignored, /// The last matching rule ignores the path.
    notIgnored, /// The last matching rule is a negation (`!`) re-including it.
}

/// The verdict for a path together with the rule that produced it — the
/// information `git check-ignore -v` prints. `verdict` is `IgnoreMatch.none`
/// when no rule matched, in which case the remaining fields are unset.
struct IgnoreDecision
{
    IgnoreMatch verdict;
    string sourceFile; /// The `.gitignore` that declared the deciding rule.
    uint sourceLine; /// 1-based line of the deciding rule, or zero if unknown.
    string pattern; /// The deciding rule's pattern, without its `!` prefix.
    bool negated; /// Whether the deciding rule was a negation.
}

/// Value-semantics container for parsed `.gitignore` rules.
struct GitIgnore
{
    GitIgnoreRule[] rules;

    /// Parses all rules from a `.gitignore` text payload. `sourceFile` is
    /// recorded on every rule for diagnostics ($(LREF GitIgnoreRule.sourceFile));
    /// it is never used for matching.
    static GitIgnore parse(string source, string sourceFile = null) pure
    {
        GitIgnore result;
        uint lineNumber;
        foreach (line; source.lineSplitter)
            result.addLine(line, sourceFile, ++lineNumber);
        return result;
    }

    /// Loads `.gitignore` rules from `path`.
    /// Missing files are treated as an empty ignore list.
    static GitIgnore fromFile(string path)
    {
        import std.file : exists, readText;

        if (!path.exists)
            return GitIgnore.init;

        return parse(path.readText, path);
    }

    /// Adds a single rule line from a `.gitignore` file. `sourceFile` and
    /// `sourceLine` are recorded on the rule for diagnostics only.
    void addLine(string rawLine, string sourceFile = null, uint sourceLine = 0) pure
    {
        auto parsed = parseRuleLine(rawLine);
        if (!parsed.valid)
            return;

        parsed.rule.sourceFile = sourceFile;
        parsed.rule.sourceLine = sourceLine;
        rules ~= parsed.rule;
    }

    /// Evaluates ignore status for a repository-relative path.
    ///
    /// The last matching rule wins, including negations.
    bool isIgnored(in const(char)[] relativePath, bool isDirectory = false) const pure
    {
        return match(relativePath, isDirectory) == IgnoreMatch.ignored;
    }

    /// Like `isIgnored`, but distinguishes "no rule matched" from an explicit
    /// negation, so callers layering several `.gitignore` files (see
    /// `GitIgnoreStack`) can let inner files override outer ones.
    IgnoreMatch match(in const(char)[] relativePath, bool isDirectory = false) const pure
    {
        const normalizedPath = normalizePath(relativePath);
        if (normalizedPath.length == 0)
            return IgnoreMatch.none;

        return explain(relativePath, isDirectory).verdict;
    }

    /// Like `match`, but also reports which rule decided — the file, line and
    /// pattern `git check-ignore -v` would name. Git's last-match-wins rule
    /// means the reported rule is the last one that matched, not the first.
    IgnoreDecision explain(in const(char)[] relativePath, bool isDirectory = false) const pure
    {
        const normalizedPath = normalizePath(relativePath);
        if (normalizedPath.length == 0)
            return IgnoreDecision.init;

        IgnoreDecision result;
        foreach (ref rule; rules)
        {
            if (!rule.matches(normalizedPath, isDirectory))
                continue;

            result = IgnoreDecision(
                verdict: rule.negated ? IgnoreMatch.notIgnored : IgnoreMatch.ignored,
                sourceFile: rule.sourceFile,
                sourceLine: rule.sourceLine,
                pattern: rule.pattern,
                negated: rule.negated,
            );
        }
        return result;
    }
}

/// Layered `.gitignore` scopes for a directory walk: one frame per directory
/// that contributes rules, from the walk root (`dirPrefix == ""`) downward.
///
/// Matches git's precedence: every frame whose directory contains the path is
/// consulted outermost-first, and a match in a deeper `.gitignore` overrides
/// any verdict from a shallower one. Frame patterns apply relative to the
/// frame's own directory, exactly as git reads nested `.gitignore` files.
struct GitIgnoreStack
{
    private static struct Frame
    {
        string dirPrefix; /// Walk-relative directory (`""` for the root), no trailing slash.
        string pathPrefix; /// For ancestor scopes: the walk root's path relative to the frame's directory.
        GitIgnore ignore;
    }

    private Frame[] frames;

    /// Pushes the `.gitignore` scope of `dirPrefix` (push/pop must nest with
    /// the walk: each entered directory pushes exactly one frame).
    void push(string dirPrefix, GitIgnore ignore) pure nothrow
    {
        frames ~= Frame(dirPrefix: dirPrefix, ignore: ignore);
    }

    /// Pushes the scope of a directory *above* the walk root — git also
    /// consults `.gitignore` files of ancestor directories up to the
    /// repository root. `pathPrefix` is the walk root's path relative to the
    /// ancestor (e.g. `"libs/base"` for the repo root's `.gitignore` when the
    /// walk starts at `libs/base`), so the frame sees every path the way that
    /// `.gitignore` would. Ancestor frames must be pushed outermost-first,
    /// before any `push` frame, and are never popped.
    void pushAncestor(string pathPrefix, GitIgnore ignore) pure
    {
        frames ~= Frame(pathPrefix: normalizePath(pathPrefix), ignore: ignore);
    }

    /// Pops the innermost scope.
    void pop() pure
    in (frames.length > 0, "Cannot pop from an empty GitIgnoreStack")
    {
        frames = frames[0 .. $ - 1];
    }

    /// Evaluates `relativePath` (walk-relative) against all applicable frames.
    bool isIgnored(in const(char)[] relativePath, bool isDirectory = false) const pure
    {
        return explain(relativePath, isDirectory).verdict == IgnoreMatch.ignored;
    }

    /// Like `isIgnored`, but reports the deciding rule across every applicable
    /// frame — the file, line and pattern `git check-ignore -v` would name.
    /// Deeper frames are consulted last, so the deepest matching rule wins.
    IgnoreDecision explain(in const(char)[] relativePath, bool isDirectory = false) const pure
    {
        const normalizedPath = normalizePath(relativePath);

        IgnoreDecision decision;
        foreach (ref frame; frames)
        {
            const(char)[] localPath;
            if (frame.dirPrefix.length == 0)
                localPath = normalizedPath;
            else if (normalizedPath.length > frame.dirPrefix.length
                && normalizedPath.startsWith(frame.dirPrefix)
                && normalizedPath[frame.dirPrefix.length] == '/')
                localPath = normalizedPath[frame.dirPrefix.length + 1 .. $];
            else
                continue;

            // An ancestor frame evaluates the path as seen from its own
            // directory, above the walk root.
            if (frame.pathPrefix.length > 0)
                localPath = frame.pathPrefix ~ "/" ~ localPath;

            const frameDecision = frame.ignore.explain(localPath, isDirectory);
            if (frameDecision.verdict != IgnoreMatch.none)
                decision = frameDecision;
        }
        return decision;
    }
}

private:

struct ParseResult
{
    bool valid;
    GitIgnoreRule rule;
}

ParseResult parseRuleLine(string rawLine) pure
{
    string line = stripCarriageReturn(rawLine);
    if (line.length == 0)
        return ParseResult.init;

    if (line[0] == '#')
        return ParseResult.init;

    bool negated;
    if (line.length > 1 && line[0] == '\\' && (line[1] == '#' || line[1] == '!'))
    {
        line = line[1 .. $];
    }
    else if (line[0] == '!')
    {
        negated = true;
        line = line[1 .. $];
    }

    line = trimUnescapedTrailingSpaces(line);
    if (line.length == 0)
        return ParseResult.init;

    bool directoryOnly;
    if (line[$ - 1] == '/' && !isEscaped(line, line.length - 1))
    {
        directoryOnly = true;
        line = line[0 .. $ - 1];
    }

    bool anchored;
    if (line.length > 0 && line[0] == '/')
    {
        anchored = true;
        line = line[1 .. $];
    }

    if (line.length == 0)
        return ParseResult.init;

    return ParseResult(
        valid: true,
        rule: GitIgnoreRule(
            pattern: line,
            negated: negated,
            directoryOnly: directoryOnly,
            anchored: anchored,
            hasSlash: hasUnescapedSlash(line),
        ),
    );
}

string stripCarriageReturn(string line) pure
{
    if (line.length > 0 && line[$ - 1] == '\r')
        return line[0 .. $ - 1];
    return line;
}

string trimUnescapedTrailingSpaces(string line) pure
{
    size_t end = line.length;
    while (end > 0 && line[end - 1] == ' ' && !isEscaped(line, end - 1))
        end--;
    return line[0 .. end];
}

bool isEscaped(in string text, size_t index) pure
{
    size_t escapes;
    size_t i = index;
    while (i > 0 && text[i - 1] == '\\')
    {
        escapes++;
        i--;
    }
    return (escapes % 2) == 1;
}

bool hasUnescapedSlash(in string pattern) pure
{
    foreach (i, ch; pattern)
        if (ch == '/' && !isEscaped(pattern, i))
            return true;
    return false;
}

string normalizePath(in const(char)[] path) pure
{
    auto normalized = appender!string;
    foreach (ch; path)
        normalized.put(ch == '\\' ? '/' : ch);

    string result = normalized[];
    while (result.startsWith("./"))
        result = result[2 .. $];

    while (result.length > 0 && result[0] == '/')
        result = result[1 .. $];

    while (result.length > 1 && result[$ - 1] == '/')
        result = result[0 .. $ - 1];

    return result;
}

bool matchesAnySegment(in string pattern, in const(char)[] path) pure
{
    size_t start;
    while (true)
    {
        size_t end = start;
        while (end < path.length && path[end] != '/')
            end++;

        if (globMatch(pattern, path[start .. end]))
            return true;

        if (end == path.length)
            return false;

        start = end + 1;
    }
}

bool globMatch(in string pattern, in const(char)[] text) pure
{
    return globMatchAt(pattern, 0, text, 0);
}

bool globMatchAt(in string pattern, size_t patternIndex, in const(char)[] text, size_t textIndex) pure
{
    while (patternIndex < pattern.length)
    {
        const ch = pattern[patternIndex];
        if (ch == '*')
        {
            if (patternIndex + 1 < pattern.length && pattern[patternIndex + 1] == '*')
            {
                size_t next = patternIndex + 2;
                while (next < pattern.length && pattern[next] == '*')
                    next++;

                if (next < pattern.length && pattern[next] == '/')
                {
                    if (globMatchAt(pattern, next + 1, text, textIndex))
                        return true;
                }

                foreach (i; textIndex .. text.length + 1)
                    if (globMatchAt(pattern, next, text, i))
                        return true;

                return false;
            }

            const next = patternIndex + 1;
            if (globMatchAt(pattern, next, text, textIndex))
                return true;

            size_t i = textIndex;
            while (i < text.length && text[i] != '/')
            {
                i++;
                if (globMatchAt(pattern, next, text, i))
                    return true;
            }
            return false;
        }

        if (ch == '?')
        {
            if (textIndex >= text.length || text[textIndex] == '/')
                return false;

            patternIndex++;
            textIndex++;
            continue;
        }

        if (ch == '\\' && patternIndex + 1 < pattern.length)
            patternIndex++;

        if (textIndex >= text.length || pattern[patternIndex] != text[textIndex])
            return false;

        patternIndex++;
        textIndex++;
    }

    return textIndex == text.length;
}

@("buildPrimitives.gitIgnore.commentsAndNegation")
@safe unittest
{
    const ignore = GitIgnore.parse(
        "# comment\n"
        ~ "*.o\n"
        ~ "!keep.o\n"
        ~ "build/\n"
    );

    assert(ignore.rules.length == 3);
    assert(ignore.isIgnored("main.o"));
    assert(ignore.isIgnored("src/main.o"));
    assert(!ignore.isIgnored("keep.o"));
    assert(ignore.isIgnored("build", true));
}

@("buildPrimitives.gitIgnore.rootAnchoredRules")
@safe unittest
{
    const ignore = GitIgnore.parse("/Cargo.lock\n");

    assert(ignore.isIgnored("Cargo.lock"));
    assert(!ignore.isIgnored("src/Cargo.lock"));
}

@("buildPrimitives.gitIgnore.doubleStarAndQuestion")
@safe unittest
{
    const ignore = GitIgnore.parse("src/**/generated?.d\n");

    assert(ignore.isIgnored("src/generated1.d"));
    assert(ignore.isIgnored("src/a/b/generated9.d"));
    assert(!ignore.isIgnored("src/a/generated10.d"));
}

@("buildPrimitives.gitIgnore.matchTriState")
@safe pure unittest
{
    const ignore = GitIgnore.parse("*.o\n!keep.o\n");

    assert(ignore.match("main.o") == IgnoreMatch.ignored);
    assert(ignore.match("keep.o") == IgnoreMatch.notIgnored);
    assert(ignore.match("main.d") == IgnoreMatch.none);
}

@("buildPrimitives.gitIgnoreStack.nestedScopes")
@safe pure unittest
{
    GitIgnoreStack stack;
    stack.push("", GitIgnore.parse("*.tmp\n"));
    stack.push("sub", GitIgnore.parse("*.log\n!keep.tmp\n"));

    // The root scope applies everywhere; the `sub` scope only under `sub/`.
    assert(stack.isIgnored("notes.tmp"));
    assert(stack.isIgnored("sub/notes.tmp"));
    assert(stack.isIgnored("sub/build.log"));
    assert(!stack.isIgnored("build.log"));

    // A deeper negation overrides the outer ignore rule — but only in scope.
    assert(!stack.isIgnored("sub/keep.tmp"));
    assert(stack.isIgnored("keep.tmp"));

    // Popping the inner frame restores the outer verdicts.
    stack.pop();
    assert(stack.isIgnored("sub/keep.tmp"));
    assert(!stack.isIgnored("sub/build.log"));
}

@("buildPrimitives.gitIgnoreStack.ancestorScopes")
@safe pure unittest
{
    // Walk rooted at `libs/base` inside a repository whose root `.gitignore`
    // ignores `build/` everywhere and `/docs` only at the repository root.
    GitIgnoreStack stack;
    stack.pushAncestor("libs/base", GitIgnore.parse("build/\n/docs/\n"));
    stack.push("", GitIgnore.parse("!build/\n"));

    // The unanchored ancestor rule reaches into the walk root, but the walk
    // root's own negation overrides it (deeper file wins).
    assert(!stack.isIgnored("build", true));

    // The anchored `/docs` rule matches only at the repository root, not the
    // walk root's `docs` (which the ancestor frame sees as `libs/base/docs`).
    assert(!stack.isIgnored("docs", true));
}

@("buildPrimitives.gitIgnoreStack.prefixBoundary")
@safe pure unittest
{
    GitIgnoreStack stack;
    stack.push("sub", GitIgnore.parse("*.log\n"));

    // `subdir` is not inside `sub` — the frame must not leak past the `/`.
    assert(!stack.isIgnored("subdir/build.log"));
    assert(stack.isIgnored("sub/build.log"));
}

@("buildPrimitives.gitIgnore.directoryRuleAppliesToDescendants")
@safe unittest
{
    const ignore = GitIgnore.parse("build/\n/src/gen/\n");

    assert(ignore.isIgnored("build", true));
    assert(ignore.isIgnored("build/out.txt"));
    assert(ignore.isIgnored("src/build/tmp.bin"));

    assert(ignore.isIgnored("src/gen", true));
    assert(ignore.isIgnored("src/gen/code.d"));
    assert(!ignore.isIgnored("nested/src/gen/code.d"));
}

@("buildPrimitives.gitIgnore.ruleProvenanceRecordsFileAndLine")
@safe unittest
{
    // Blank and comment lines are counted, so a reported line number addresses
    // the file the way an editor shows it — which is what `git check-ignore -v`
    // prints and therefore what a reader will compare against.
    const ignore = GitIgnore.parse(
        "# comment\n"
            ~ "\n"
            ~ "*.o\n"
            ~ "!keep.o\n",
        "libs/base/.gitignore",
    );

    assert(ignore.rules.length == 2);
    assert(ignore.rules[0].pattern == "*.o");
    assert(ignore.rules[0].sourceFile == "libs/base/.gitignore");
    assert(ignore.rules[0].sourceLine == 3);
    assert(ignore.rules[1].sourceLine == 4);
}

@("buildPrimitives.gitIgnore.explainReportsTheDecidingRule")
@safe unittest
{
    const ignore = GitIgnore.parse("*.o\n!keep.o\n", ".gitignore");

    // Last match wins, so the negation on line 2 is the deciding rule for
    // `keep.o` even though the broader rule on line 1 also matches.
    const kept = ignore.explain("keep.o");
    assert(kept.verdict == IgnoreMatch.notIgnored);
    assert(kept.sourceLine == 2);
    assert(kept.pattern == "keep.o");
    assert(kept.negated);

    const dropped = ignore.explain("main.o");
    assert(dropped.verdict == IgnoreMatch.ignored);
    assert(dropped.sourceLine == 1);
    assert(!dropped.negated);

    // No rule matched: the verdict falls through and nothing is attributed.
    const untouched = ignore.explain("README.md");
    assert(untouched.verdict == IgnoreMatch.none);
    assert(untouched.sourceFile.length == 0);
    assert(untouched.sourceLine == 0);
}

@("buildPrimitives.gitIgnoreStack.explainAttributesTheDeepestScope")
@safe unittest
{
    GitIgnoreStack stack;
    stack.push("", GitIgnore.parse("*.log\n", ".gitignore"));
    stack.push("logs", GitIgnore.parse("!keep.log\n", "logs/.gitignore"));

    const decision = stack.explain("logs/keep.log");
    assert(decision.verdict == IgnoreMatch.notIgnored);
    assert(decision.sourceFile == "logs/.gitignore");
    assert(decision.sourceLine == 1);
    assert(!stack.isIgnored("logs/keep.log"));

    // A path the deeper scope does not cover keeps the root scope's verdict,
    // attributed to the root file.
    const outer = stack.explain("logs/other.log");
    assert(outer.verdict == IgnoreMatch.ignored);
    assert(outer.sourceFile == ".gitignore");
    assert(stack.isIgnored("logs/other.log"));
}

@("buildPrimitives.gitIgnore.normalizePathFoldsWindowsSeparators")
@safe pure unittest
{
    // The `git check-ignore` parity gate compares our recorded source path
    // against git's, and git reports repository-relative paths with `/` on
    // every platform. `std.path.relativePath` yields the *platform*
    // separator, so the comparison only holds once folded — which is what
    // broke the Windows CI leg when the gate first landed.
    assert(normalizePath("logs\\.gitignore") == "logs/.gitignore");
    assert(normalizePath("a\\b\\c.txt") == "a/b/c.txt");
    assert(normalizePath(".gitignore") == ".gitignore");
}

/// `git check-ignore -v` parity: the rule this module attributes a verdict to
/// must be the rule git attributes it to — same file, same line, same pattern.
///
/// This is the acceptance gate for rule provenance
/// ([`FSI3`](../../../../../docs/specs/build-primitives/filesets/SPEC.md)).
/// It is an independent oracle rather than a round trip: git is a separate
/// implementation of the semantics this module copies, so agreement is
/// evidence and disagreement names the defect.
@("buildPrimitives.gitIgnore.explainMatchesGitCheckIgnore")
@system unittest
{
    import sparkles.build_primitives.git_env : runGit;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.algorithm.searching : endsWith;
    import std.conv : to;
    import std.path : relativePath;
    import std.string : splitLines, split, strip;

    // A missing git is a degraded environment, not a failure: skip loudly
    // rather than returning early and counting it as a pass.
    try
    {
        if (runGit(["--version"]).status != 0)
            return skipTest("git is not usable");
    }
    catch (Exception)
        return skipTest("git is not on PATH");

    // `TmpFS` owns the scratch tree: it creates the directory, names the files,
    // and removes the whole thing — the `.git` git is about to create
    // included — without a cleanup failure masking a real assertion.
    auto tmp = TmpFS.create();
    const rootIgnore = tmp.writeFileAt(".gitignore", "# comment\n\n*.log\nbuild/\n");
    const nestedIgnore = tmp.writeFileAt("logs/.gitignore", "!keep.log\n");
    const root = tmp.dir();

    // `runGit` scrubs GIT_DIR and friends. Inheriting them here would point
    // `git init` at whatever repository is running the test suite, which has
    // twice left `core.bare = true` in this repository's own config.
    assert(runGit(["init", "-q", root]).status == 0, "git init failed");

    GitIgnoreStack stack;
    stack.push("", GitIgnore.fromFile(rootIgnore));
    stack.push("logs", GitIgnore.fromFile(nestedIgnore));

    // Paths chosen so that each exercises a different deciding rule: the root
    // pattern, the nested negation, and the directory-only rule.
    foreach (relPath; ["a.log", "logs/other.log", "logs/keep.log", "build/x.o"])
    {
        const result = runGit(["check-ignore", "-v", "--no-index", relPath], root);

        const ours = stack.explain(relPath);
        if (result.status != 0)
        {
            // git reports no match; so must we, or one of us is wrong about
            // which rules apply.
            assert(ours.verdict != IgnoreMatch.ignored,
                "we ignore '" ~ relPath ~ "' and git does not");
            continue;
        }

        // `<source>:<line>:<pattern>\t<path>`
        const fields = result.output.splitLines[0].split("\t")[0].split(":");
        assert(fields.length == 3, "unexpected check-ignore output");

        // git reports the source repository-relative with `/` separators on
        // every platform; ours is whatever path the caller opened, which is
        // backslash-separated on Windows. Normalize both before comparing, and
        // compare for equality rather than suffix: `endsWith` would also
        // accept `xlogs/.gitignore`.
        const oursSource = normalizePath(relativePath(ours.sourceFile, root));
        assert(oursSource == fields[0],
            "source mismatch for '" ~ relPath ~ "': git says '" ~ fields[0]
                ~ "', we say '" ~ oursSource ~ "' (from '" ~ ours.sourceFile ~ "')");
        assert(ours.sourceLine == fields[1].to!uint,
            "line mismatch for '" ~ relPath ~ "': git says " ~ fields[1]
                ~ ", we say " ~ ours.sourceLine.to!string);

        const gitPattern = fields[2].strip;
        const oursPattern = (ours.negated ? "!" : "") ~ ours.pattern
            ~ (gitPattern.endsWith("/") ? "/" : "");
        assert(oursPattern == gitPattern,
            "pattern mismatch for '" ~ relPath ~ "': git says '" ~ gitPattern
                ~ "', we say '" ~ oursPattern ~ "'");
    }
}
