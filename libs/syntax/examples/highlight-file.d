#!/usr/bin/env dub
/+ dub.sdl:
    name "highlight-file"
    dependency "sparkles:syntax" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

// The full precise-mode pipeline: file → tree-sitter parse → highlights
// query → event stream → ANSI (stdout) or HTML. Grammars come from the nix
// bundle ($SPARKLES_TS_GRAMMAR_PATH, exported by the devshell); without it
// the program degrades to plain text — the totality law in action.
//
// Usage: highlight-file [--html] [--theme <theme>] [path] (defaults to this file itself)

module highlight_file;

import std.array : appender;
import std.file : readText;
import std.path : baseName, extension;
import std.stdio : stderr, write, writeln;

import sparkles.syntax;
import sparkles.core_cli.args;

struct CliParams
{
    @CliOption("html", "Output formatted HTML instead of ANSI terminal escapes.")
    bool html;

    @CliOption("theme", "Syntax highlighting theme name.")
    string theme = "sparkles-dark";
}

int main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(
        HelpInfo(
            "highlight-file",
            "The full precise-mode pipeline: file -> tree-sitter parse -> highlights query -> event stream -> ANSI (stdout) or HTML.",
            null
        )
    );

    bool html = cli.html;
    string themeName = cli.theme;
    const path = args.length > 1 ? args[1] : __FILE_FULL_PATH__;
    const source = readText(path);
    const lang = canonicalLanguage(path.extension.length ? path.extension[1 .. $] : "");

    const labels = LabelSet.standard();

    const(Theme)* themeVal = &builtinDark;
    if (auto t = themeName in builtinThemes)
    {
        themeVal = t;
    }
    else
    {
        stderr.writef("Warning: theme '%s' not found. Falling back to default dark theme.\n", themeName);
    }
    const theme = resolveTheme(*themeVal, labels);

    // Engine side: any failure falls back to plain text.
    auto events = appender!(HighlightEvent[]);
    auto registry = GrammarRegistry.fromEnvironment();

    bool highlighted = false;
    auto grammar = registry.grammar(lang);
    auto queryText = registry.queryText(lang);
    if (!grammar.hasError && !queryText.hasError)
    {
        TsError error;
        auto config = TsHighlightConfig.create(grammar.value, queryText.value, error);
        if (!error)
        {
            config.configure(labels);
            highlighted = !highlight(config, source, events).hasError;
        }
    }
    if (!highlighted)
    {
        stderr.writeln("note: no grammar for '", lang, "' — plain text");
        events ~= HighlightEvent.sourceSpan(0, source.length);
    }

    auto output = appender!string;
    if (html)
    {
        import std.format : format;
        string bgStr = theme.defaults.bg.isSet ? format("background: #%02x%02x%02x;", theme.defaults.bg.rgb.r, theme.defaults.bg.rgb.g, theme.defaults.bg.rgb.b) : "";
        string fgStr = theme.defaults.fg.isSet ? format("color: #%02x%02x%02x;", theme.defaults.fg.rgb.r, theme.defaults.fg.rgb.g, theme.defaults.fg.rgb.b) : "";
        output ~= format("<style>\npre { %s %s padding: 1em; }\n", bgStr, fgStr);
        writeThemeStylesheet(theme, output);
        output ~= "</style>\n<pre><code>";
        renderHtml(source, events[], theme, output,
            HtmlOptions(mode: HtmlMode.cssClasses));
        output ~= "</code></pre>\n";
    }
    else
        renderAnsi(source, events[], theme, output,
            AnsiOptions(depth: detectColorDepth(), italics: true));

    write(output[]);
    return 0;
}
