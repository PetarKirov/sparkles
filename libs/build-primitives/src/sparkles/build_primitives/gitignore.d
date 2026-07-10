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

/// Value-semantics container for parsed `.gitignore` rules.
struct GitIgnore
{
    GitIgnoreRule[] rules;

    /// Parses all rules from a `.gitignore` text payload.
    static GitIgnore parse(string source) pure
    {
        GitIgnore result;
        foreach (line; source.lineSplitter)
            result.addLine(line);
        return result;
    }

    /// Loads `.gitignore` rules from `path`.
    /// Missing files are treated as an empty ignore list.
    static GitIgnore fromFile(string path)
    {
        import std.file : exists, readText;

        if (!path.exists)
            return GitIgnore.init;

        return parse(path.readText);
    }

    /// Adds a single rule line from a `.gitignore` file.
    void addLine(string rawLine) pure
    {
        const parsed = parseRuleLine(rawLine);
        if (parsed.valid)
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

        auto result = IgnoreMatch.none;
        foreach (rule; rules)
        {
            if (rule.matches(normalizedPath, isDirectory))
                result = rule.negated ? IgnoreMatch.notIgnored : IgnoreMatch.ignored;
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
        const normalizedPath = normalizePath(relativePath);

        bool ignored = false;
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

            final switch (frame.ignore.match(localPath, isDirectory))
            {
                case IgnoreMatch.none:
                    break;
                case IgnoreMatch.ignored:
                    ignored = true;
                    break;
                case IgnoreMatch.notIgnored:
                    ignored = false;
                    break;
            }
        }
        return ignored;
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
