#!/usr/bin/env dub
/+ dub.sdl:
    name "highlight-file"
    dependency "sparkles:syntax" path="../../.."
    targetPath "build"
+/

// The full precise-mode pipeline: file → tree-sitter parse → highlights
// query → event stream → ANSI (stdout) or HTML. Grammars come from the nix
// bundle ($SPARKLES_TS_GRAMMAR_PATH, exported by the devshell); without it
// the program degrades to plain text — the totality law in action.
//
// Usage: highlight-file [--html] [path] (defaults to this file itself)

module highlight_file;

import std.array : appender;
import std.file : readText;
import std.path : baseName, extension;
import std.stdio : stderr, write, writeln;

import sparkles.syntax;

int main(string[] args)
{
    bool html = args.length > 1 && args[1] == "--html";
    const path = args.length > (html ? 2 : 1) ? args[html ? 2 : 1] : __FILE_FULL_PATH__;
    const source = readText(path);
    const lang = canonicalLanguage(path.extension.length ? path.extension[1 .. $] : "");

    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinDark, labels);

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
        output ~= "<style>\npre { background: #1e1e2e; color: #cdd6f4; padding: 1em; }\n";
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
