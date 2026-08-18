/**
Formatting configuration — the D5/D6 defaults, plus M7's discovery via
`.editorconfig`, honoring dfmt's key names for migration.
*/
module sparkles.dmd_fmt.config;

/// The options the v1 formatter honors. Defaults follow dfmt where dfmt has
/// an opinion (soft max 80, hard max 120) and the D style elsewhere.
struct FormatConfig
{
    /// Columns per indentation level (`indent_size`).
    int indentSize = 4;
    /// Indent with tabs (`indent_style = tab`).
    bool useTabs = false;
    /// Columns one tab advances (`tab_width`).
    int tabWidth = 4;
    /// The width the greedy engine wraps toward
    /// (`dfmt_soft_max_line_length`): the greedy engine has one width, and
    /// the soft limit is the one wrapping targets — see D3/D6.
    int softMaxLineLength = 80;
    /// Accepted for dfmt compatibility (`max_line_length`); v1 keeps it for
    /// a future soft/hard split and does not act on it.
    int maxLineLength = 120;
    /// Most consecutive blank lines preserved (runs collapse — M4).
    int maxBlankLines = 2;
    /// Guarantee a single trailing newline (`insert_final_newline`).
    bool insertFinalNewline = true;
}

/**
The effective configuration for `filePath` — M7's discovery: walk parent
directories collecting `.editorconfig` files up to one with `root = true`,
then apply them outermost-first (nearest wins), matching each section's
glob against the file. dfmt's key names are honored where v1 has the
matching behavior; unrecognized keys — including the `dfmt_*` style options
v1 does not implement (brace styles, operator splitting, …) — are ignored,
which is the documented migration posture: a dfmt project's `.editorconfig`
keeps working for the subset v1 formats.

Honored keys: `indent_style`, `indent_size`, `tab_width`,
`max_line_length`, `insert_final_newline`, `dfmt_soft_max_line_length`.
*/
FormatConfig configFor(string filePath, FormatConfig base = FormatConfig()) @safe
{
    import std.file : exists, readText;
    import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;

    const target = buildNormalizedPath(absolutePath(filePath));

    static struct Level
    {
        string dir;
        string content;
    }

    // Nearest-first, stopping at (and including) a root = true file.
    Level[] levels;
    string dir = dirName(target);
    while (true)
    {
        const candidate = buildPath(dir, ".editorconfig");
        if (candidate.exists)
        {
            const content = readText(candidate);
            levels ~= Level(dir, content);
            if (isRootFile(content))
                break;
        }
        const parent = dirName(dir);
        if (parent == dir)
            break;
        dir = parent;
    }

    // Outermost-first so nearer files override.
    auto cfg = base;
    foreach_reverse (level; levels)
        applyEditorConfig(cfg, level.content, level.dir, target);
    return cfg;
}

private bool isRootFile(const(char)[] content) @safe
{
    foreach (line; iniLines(content))
    {
        if (line.length && line[0] == '[')
            return false; // the preamble ended without root = true
        const kv = splitKeyValue(line);
        if (kv[0] == "root" && kv[1] == "true")
            return true;
    }
    return false;
}

private void applyEditorConfig(ref FormatConfig cfg, const(char)[] content,
    string configDir, string target) @safe
{
    import std.path : relativePath;

    const rel = relativePath(target, configDir);
    bool active;
    foreach (line; iniLines(content))
    {
        if (line.length && line[0] == '[')
        {
            auto pattern = line[1 .. $];
            if (pattern.length && pattern[$ - 1] == ']')
                pattern = pattern[0 .. $ - 1];
            active = sectionMatches(pattern, rel);
            continue;
        }
        if (!active)
            continue;
        const kv = splitKeyValue(line);
        applyKey(cfg, kv[0], kv[1]);
    }
}

private void applyKey(ref FormatConfig cfg, const(char)[] key,
    const(char)[] value) @safe
{
    static int number(const(char)[] v) @safe
    {
        import std.conv : ConvException, to;

        try
            return v.to!int;
        catch (ConvException)
            return -1;
    }

    switch (key)
    {
        case "indent_style":
            if (value == "tab")
                cfg.useTabs = true;
            else if (value == "space")
                cfg.useTabs = false;
            break;
        case "indent_size":
            if (value == "tab")
                cfg.indentSize = cfg.tabWidth;
            else if (number(value) > 0)
                cfg.indentSize = number(value);
            break;
        case "tab_width":
            if (number(value) > 0)
                cfg.tabWidth = number(value);
            break;
        case "max_line_length":
            if (number(value) > 0)
                cfg.maxLineLength = number(value);
            break;
        case "dfmt_soft_max_line_length":
            if (number(value) > 0)
                cfg.softMaxLineLength = number(value);
            break;
        case "insert_final_newline":
            cfg.insertFinalNewline = value != "false";
            break;
        default:
            break; // unknown keys (incl. unimplemented dfmt_*) are ignored
    }
}

/// Lines stripped of surrounding whitespace; blanks and full-line comments
/// dropped ('#'/';' may legitimately appear inside section globs).
private const(char)[][] iniLines(const(char)[] content) @safe
{
    import std.algorithm.iteration : splitter;
    import std.string : strip;

    const(char)[][] lines;
    foreach (raw; content.splitter('\n'))
    {
        auto line = raw.strip;
        if (!line.length || line[0] == '#' || line[0] == ';')
            continue;
        lines ~= line;
    }
    return lines;
}

/// `key = value`, both trimmed, the key lowercased. `["", ""]` when the
/// line has no `=`.
private const(char)[][2] splitKeyValue(const(char)[] line) @safe
{
    import std.algorithm.searching : countUntil;
    import std.string : strip;
    import std.uni : toLower;

    const eq = line.countUntil('=');
    if (eq < 0)
        return [cast(const(char)[]) "", ""];
    return [line[0 .. eq].strip.toLower, line[eq + 1 .. $].strip.toLower];
}

/**
EditorConfig glob matching, the subset real configs use: `*` (not across
`/`), `**`, `?`, and `{a,b}` alternation. A pattern without a `/` matches
the basename in any directory (the spec's implicit `**​/` prefix).
*/
private bool sectionMatches(const(char)[] pattern, const(char)[] path) @safe
{
    import std.algorithm.searching : canFind;
    import std.path : baseName;

    if (!pattern.canFind('/'))
        return globMatch_(pattern, baseName(path));
    return globMatch_(pattern, path);
}

private bool globMatch_(const(char)[] pattern, const(char)[] s) @safe
{
    if (!pattern.length)
        return !s.length;
    const c = pattern[0];
    switch (c)
    {
        case '*':
            if (pattern.length > 1 && pattern[1] == '*')
            {
                // `**` crosses directory separators.
                foreach (i; 0 .. s.length + 1)
                    if (globMatch_(pattern[2 .. $], s[i .. $]))
                        return true;
                return false;
            }
            foreach (i; 0 .. s.length + 1)
            {
                if (globMatch_(pattern[1 .. $], s[i .. $]))
                    return true;
                if (i < s.length && s[i] == '/')
                    break; // `*` stops at a separator
            }
            return false;
        case '?':
            return s.length && s[0] != '/' &&
                globMatch_(pattern[1 .. $], s[1 .. $]);
        case '{':
        {
            // Expand one alternation level.
            import std.algorithm.searching : countUntil;

            const close = pattern.countUntil('}');
            if (close < 0)
                goto default;
            const(char)[][] alts;
            size_t start = 1;
            foreach (i; 1 .. cast(size_t) close + 1)
                if (pattern[i] == ',' || i == close)
                {
                    alts ~= pattern[start .. i];
                    start = i + 1;
                }
            foreach (alt; alts)
            {
                const(char)[] expanded;
                expanded = alt ~ pattern[close + 1 .. $];
                if (globMatch_(expanded, s))
                    return true;
            }
            return false;
        }
        default:
            return s.length && s[0] == c &&
                globMatch_(pattern[1 .. $], s[1 .. $]);
    }
}

// ---------------------------------------------------------------------------

@("config.glob.editorconfig-subset")
@safe unittest
{
    assert(sectionMatches("*", "foo.d"));
    assert(sectionMatches("*.d", "foo.d"));
    assert(sectionMatches("*.d", "deep/nested/foo.d")); // basename rule
    assert(!sectionMatches("*.md", "foo.d"));
    assert(sectionMatches("{*.d,*.di}", "foo.di"));
    assert(sectionMatches("src/**/*.d", "src/a/b/foo.d"));
    assert(!sectionMatches("src/*.d", "src/a/foo.d")); // * stops at /
    assert(sectionMatches("f?o.d", "foo.d"));
}

@("config.discovery.walks-up-applies-nearest-last")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    const root = buildPath(tempDir, "dmd-fmt-cfg-test");
    scope (exit)
        rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "sub"));
    write(buildPath(root, ".editorconfig"),
        "root = true\n[*]\nindent_style = tab\nindent_size = 8\n"
        ~ "max_line_length = 100\ndfmt_brace_style = allman\n");
    write(buildPath(root, "sub", ".editorconfig"),
        "[*.d]\nindent_size = 2\ndfmt_soft_max_line_length = 60\n");

    const cfg = configFor(buildPath(root, "sub", "x.d"));
    assert(cfg.useTabs);          // outer file
    assert(cfg.indentSize == 2);  // nearer file wins
    assert(cfg.maxLineLength == 100);
    assert(cfg.softMaxLineLength == 60);
    // dfmt_brace_style is unimplemented: ignored, no error.

    const other = configFor(buildPath(root, "sub", "x.txt"));
    assert(other.indentSize == 8); // [*.d] does not match, outer [*] does
}

@("config.discovery.root-stops-the-walk")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    const root = buildPath(tempDir, "dmd-fmt-cfg-root-test");
    scope (exit)
        rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "inner"));
    write(buildPath(root, ".editorconfig"), "[*]\nindent_size = 8\n");
    write(buildPath(root, "inner", ".editorconfig"),
        "root = true\n[*]\nindent_size = 3\n");

    const cfg = configFor(buildPath(root, "inner", "x.d"));
    assert(cfg.indentSize == 3); // the outer file is never consulted
}
