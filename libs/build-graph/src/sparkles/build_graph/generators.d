/**
Generators (build-graph SPEC §7, BGG1–BGG3, BGG6): the `preGenerateCommands`
entries the resolver recognizes, typed, so that the action graph runs a tool
it builds with declared arguments and never a shell command.

$(LREF recognizeGenerator) reads one entry, in the directory of the package
that declares it (dub runs it there, whatever dependent folds a source
library in). Two shapes are recognized:

$(LIST
    * $(B a single-file D program) run through dub:
        `"$DUB_EXE" "--compiler=$DC" --single <file>.d -- <arguments>`, as the
        `dmd` registry package runs its `config.d`. The program is built as a
        host application variant (BGG6) from its own inline recipe, which may
        name no dependency.
        * $(B the shader compiler) (D53): `$DUB run … --root=<shader-compile> --
        --package=<dir> --out=<dir> --if-stale`. It becomes the tool's direct
        invocation, without `--if-stale`, since the cache decides staleness
        (BGG3).
)

Either way one argument names a string import root of the package: the
in-tree directory dub would have it write. It becomes the action's `$OUT`,
and the compile that reads the root reads the action's output directory in
its place (BGG2). Anything else is a resolution error, never a shell command
(BGG1).
*/
module sparkles.build_graph.generators;

import std.algorithm.searching : endsWith, startsWith;
import std.path : buildNormalizedPath;

/// The kinds of recognized generator.
enum GeneratorKind : ubyte
{
    singleFile,     /// a single-file D program, built by the graph
    shaderCompiler, /// `apps/shader-compile`, built by the graph (D53)
}

/// One recognized generator: the same command in the same package is one
/// generator, whichever variants read its output.
struct Generator
{
    GeneratorKind kind; ///
    string directory;   /// the declaring package's directory
    string command;     /// as the recipe writes it
    /// The program: a single-file program's source, or the shader
    /// compiler's package directory.
    string program;
    /// The string import root it fills, as the declaring package names it:
    /// replaced by the action's output directory (BGG2).
    string output;
    /// The tool's arguments, the output directory as `$OUT`.
    string[] arguments;
    /// The tool's variant in the plan; `size_t.max` until planned.
    size_t tool = size_t.max;
    /// For the shader compiler: the device configuration it compiles, as
    /// `dub describe` reports it, its worktree paths under `$ROOT`; empty
    /// for a single-file program (§7, BGG3).
    string described;
}

/// Why an entry is not a generator the graph can run.
struct GeneratorError
{
    string message; ///
}

/**
Recognizes `command`, declared by the package in `directory`, whose string
import roots are `stringImportPaths` (absolute, as the resolver gives them).

Returns: the generator, its `tool` not yet planned, or why it is not one
(BGG1).
*/
bool recognizeGenerator(string directory, string command, const string[] stringImportPaths,
    out Generator g, out GeneratorError e) @safe pure
{
    g.directory = directory;
    g.command = command;
    string[] words;
    if (!shellWords(command, directory, words))
    {
        e.message = "a pre-generate command with a quote left open: " ~ command;
        return false;
    }
    if (words.length == 0 || (words[0] != "$DUB" && words[0] != "$DUB_EXE"))
    {
        e.message = "a pre-generate command that does not run dub, so no generator the graph knows: " ~ command;
        return false;
    }
    size_t at = 1;
    bool run;
    string single, root;
    for (; at < words.length && words[at] != "--"; ++at)
    {
        const w = words[at];
        if (w == "run" && at == 1)
            run = true;
        else if (w == "--single" && at + 1 < words.length)
            single = words[++at];
        else if (w.startsWith("--root="))
            root = w["--root=".length .. $];
        else if (w == "-q" || w == "--quiet" || w == "--temp-build" || w == "--compiler=$DC")
            continue;
        else
        {
            e.message = "a pre-generate command with a dub option the graph does not model (" ~ w ~ "): "
                ~ command;
            return false;
        }
    }
    const arguments = at < words.length ? words[at + 1 .. $] : null;

    bool isOutput(string path)
    {
        const p = trimSlash(path);
        foreach (s; stringImportPaths)
            if (trimSlash(s) == p)
                return true;
        return false;
    }

    if (single.length && !root.length)
    {
        g.kind = GeneratorKind.singleFile;
        g.program = single;
        foreach (a; arguments)
            if (!g.output.length && isOutput(a))
            {
                g.output = trimSlash(a);
                g.arguments ~= "$OUT";
            }
            else
                g.arguments ~= a;
    }
    else if (run && root.length && !single.length && trimSlash(root).endsWith("/shader-compile"))
    {
        g.kind = GeneratorKind.shaderCompiler;
        g.program = buildNormalizedPath(root);
        foreach (a; arguments)
        {
            if (a == "--if-stale")
                continue; // BGG3: the cache decides staleness.
            if (a.startsWith("--out=") && !g.output.length && isOutput(a["--out=".length .. $]))
            {
                g.output = trimSlash(a["--out=".length .. $]);
                g.arguments ~= "--out=$OUT";
            }
            else
                g.arguments ~= a;
        }
    }
    else
    {
        e.message = "a pre-generate command that runs dub for something other than a generator the graph knows: "
            ~ command;
        return false;
    }
    if (!g.output.length)
    {
        e.message = "a generator whose output no string import root of its package reads: " ~ command;
        return false;
    }
    return true;
}

private:

string trimSlash(string path) @safe pure nothrow @nogc
{
    while (path.length > 1 && path[$ - 1] == '/')
        path = path[0 .. $ - 1];
    return path;
}

/*
Splits `command` into words as a POSIX shell would, for the shapes recipes
write: double and single quotes and backslashes. `$PACKAGE_DIR` and
`${PACKAGE_DIR}` become `directory`; dub's other variables stay as written
(`$DUB`, `$DC`), so the recognizer can match them.
*/
bool shellWords(string command, string directory, out string[] words) @safe pure
{
    string word;
    bool inWord;
    size_t i;
    void variable()
    {
        foreach (spelling; ["${PACKAGE_DIR}", "$PACKAGE_DIR"])
            if (command[i .. $].startsWith(spelling)
                && (spelling[1] == '{' || i + spelling.length == command.length
                    || !isNameChar(command[i + spelling.length])))
            {
                word ~= directory;
                i += spelling.length;
                return;
            }
        word ~= command[i++];
    }
    while (i < command.length)
    {
        const c = command[i];
        if (c == ' ' || c == '\t' || c == '\n')
        {
            if (inWord)
                words ~= word;
            word = null;
            inWord = false;
            ++i;
            continue;
        }
        inWord = true;
        if (c == '\'')
        {
            const close = indexFrom(command, '\'', i + 1);
            if (close == size_t.max)
                return false;
            word ~= command[i + 1 .. close];
            i = close + 1;
        }
        else if (c == '"')
        {
            ++i;
            while (i < command.length && command[i] != '"')
            {
                if (command[i] == '\\' && i + 1 < command.length)
                {
                    word ~= command[i + 1];
                    i += 2;
                }
                else if (command[i] == '$')
                    variable();
                else
                    word ~= command[i++];
            }
            if (i == command.length)
                return false;
            ++i;
        }
        else if (c == '\\' && i + 1 < command.length)
        {
            word ~= command[i + 1];
            i += 2;
        }
        else if (c == '$')
            variable();
        else
            word ~= command[i++];
    }
    if (inWord)
        words ~= word;
    return true;
}

bool isNameChar(char c) @safe pure nothrow @nogc
    => c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');

size_t indexFrom(string s, char c, size_t from) @safe pure nothrow @nogc
{
    foreach (k; from .. s.length)
        if (s[k] == c)
            return k;
    return size_t.max;
}

/// `dmd`'s `config.d` command and the shader compiler's are recognized; a
/// shell command is not.
@("build_graph.generators.recognizeGenerator")
@safe pure unittest
{
    Generator g;
    GeneratorError e;
    const dmd = `"$DUB_EXE" "--compiler=$DC" --single "${PACKAGE_DIR}/config.d" -- "${PACKAGE_DIR}/generated/dub" "${PACKAGE_DIR}/VERSION" /etc`;
    assert(recognizeGenerator("/s/dmd", dmd, ["/s/dmd/compiler/src/dmd/res", "/s/dmd/generated/dub/"], g, e),
        e.message);
    assert(g.kind == GeneratorKind.singleFile && g.program == "/s/dmd/config.d");
    assert(g.output == "/s/dmd/generated/dub");
    assert(g.arguments == ["$OUT", "/s/dmd/VERSION", "/etc"]);

    const shader = "$DUB run -q --root=$PACKAGE_DIR/../../apps/shader-compile -- "
        ~ "--package=$PACKAGE_DIR --out=$PACKAGE_DIR/generated/shaders --if-stale";
    assert(recognizeGenerator("/r/libs/ui", shader, ["/r/libs/ui/generated/shaders"], g, e), e.message);
    assert(g.kind == GeneratorKind.shaderCompiler && g.program == "/r/apps/shader-compile");
    assert(g.arguments == ["--package=/r/libs/ui", "--out=$OUT"]);

    assert(!recognizeGenerator("/r/a", "echo -n /etc > SYSCONFDIR.imp", ["/r/a"], g, e));
    assert(!recognizeGenerator("/r/a", shader, ["/r/a/views"], g, e)); // writes no root it reads
    assert(!recognizeGenerator("/r/a", `"$DUB_EXE" --single "x.d`, ["/r/a"], g, e));
}
