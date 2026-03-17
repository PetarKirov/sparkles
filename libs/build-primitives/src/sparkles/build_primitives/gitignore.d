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

/// Value-semantics container for parsed `.gitignore` rules.
struct GitIgnore
{
    GitIgnoreRule[] rules;

    /// Parses all rules from a `.gitignore` text payload.
    static GitIgnore parse(string source)
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
    void addLine(string rawLine)
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
        const normalizedPath = normalizePath(relativePath);
        if (normalizedPath.length == 0)
            return false;

        bool ignored = false;
        foreach (rule; rules)
        {
            if (rule.matches(normalizedPath, isDirectory))
                ignored = !rule.negated;
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
