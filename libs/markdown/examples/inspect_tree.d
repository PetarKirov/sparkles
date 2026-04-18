#!/usr/bin/env dub
/+ dub.sdl:
    name "markdown-inspect-tree"
    dependency "sparkles:markdown" path="../../../"
    dependency "sparkles:core-cli" path="../../../"
    targetPath "build"
+/

import std.algorithm.searching : startsWith;
import std.array : Appender, appender, join;
import std.conv : to;
import std.file : readText;
import std.range.primitives : put;
import std.stdio : File, stderr, stdin, stdout;

import sparkles.core_cli.ui.tree_view : TreeViewProps, drawTree;
import sparkles.markdown : AstKind, AstNode, DiagnosticLevel, ParseResult, TaskStatus, parse;

struct CliOptions
{
    string inputPath;
    bool help;
}

struct InspectNode
{
    string label;
    InspectNode[] children;
}

int main(string[] args)
{
    CliOptions options;
    string parseError;
    if (!parseCliArgs(args, options, parseError))
    {
        stderr.writeln(parseError);
        printUsage(stderr);
        return 2;
    }

    if (options.help)
    {
        printUsage(stdout);
        return 0;
    }

    string markdown;
    try
    {
        markdown = options.inputPath.length > 0 ? readText(options.inputPath) : readFromStdin();
    }
    catch (Exception ex)
    {
        stderr.writeln("Failed to read input: ", ex.msg);
        return 2;
    }

    ParseResult result = parse(markdown);
    auto inspectTree = buildInspectTree(result.ast);

    auto rendered = drawTree(inspectTree, TreeViewProps!void(useColors: false));
    stdout.writeln(rendered);

    if (result.diagnostics.length > 0)
        printDiagnostics(result);

    return hasErrors(result) ? 1 : 0;
}

private bool parseCliArgs(string[] args, ref CliOptions options, out string error)
{
    for (size_t i = 1; i < args.length; ++i)
    {
        const arg = args[i];

        if (arg == "-h" || arg == "--help")
        {
            options.help = true;
            continue;
        }

        if (arg == "-i" || arg == "--input")
        {
            if (i + 1 >= args.length)
            {
                error = "Missing value for --input.";
                return false;
            }

            options.inputPath = args[++i];
            continue;
        }

        if (arg.startsWith("--input="))
        {
            options.inputPath = arg["--input=".length .. $];
            if (options.inputPath.length == 0)
            {
                error = "Missing value for --input.";
                return false;
            }

            continue;
        }

        error = "Unknown argument: " ~ arg;
        return false;
    }

    return true;
}

private void printUsage(ref File file)
{
    file.writeln("Markdown AST inspect tree");
    file.writeln("Usage: inspect_tree.d [--input FILE]");
    file.writeln("Reads markdown from stdin when --input is omitted.");
}

private string readFromStdin()
{
    Appender!string writer = appender!string;
    char[] line;
    while (stdin.readln(line))
    {
        put(writer, line);
    }

    return writer.data;
}

private InspectNode buildInspectTree(in AstNode node)
{
    InspectNode[] children;
    foreach (child; node.children)
    {
        children ~= buildInspectTree(child);
    }

    return InspectNode(nodeLabel(node), children);
}

private string nodeLabel(in AstNode node)
{
    string label = node.kind.to!string;
    string[] details;

    if (node.kind == AstKind.heading)
        details ~= "level=" ~ node.level.to!string;

    if (node.kind == AstKind.listBlock)
    {
        details ~= node.ordered ? "ordered" : "unordered";
        if (node.ordered)
            details ~= "start=" ~ node.start.to!string;
        if (!node.tight)
            details ~= "loose";
    }

    if (node.kind == AstKind.listItem && node.taskStatus != TaskStatus.none)
        details ~= "task=" ~ node.taskStatus.to!string;

    if (node.customId.length > 0)
        details ~= "id=" ~ quotePreview(node.customId, 24);

    if (node.infoString.length > 0)
        details ~= "info=" ~ quotePreview(node.infoString, 32);

    if (node.languageHint.length > 0)
        details ~= "lang=" ~ quotePreview(node.languageHint, 20);

    if (node.destination.length > 0)
        details ~= "dest=" ~ quotePreview(node.destination, 48);

    if (node.title.length > 0)
        details ~= "title=" ~ quotePreview(node.title, 32);

    if (node.name.length > 0)
        details ~= "name=" ~ quotePreview(node.name, 24);

    if (shouldShowLiteral(node.kind) && node.literal.length > 0)
        details ~= "text=" ~ quotePreview(node.literal, 40);

    if (details.length == 0)
        return label;

    return label ~ " [" ~ details.join(", ") ~ "]";
}

private bool shouldShowLiteral(AstKind kind)
{
    switch (kind)
    {
        case AstKind.text:
        case AstKind.code:
        case AstKind.fencedCode:
        case AstKind.indentedCode:
        case AstKind.htmlInline:
        case AstKind.htmlBlock:
        case AstKind.mathInline:
        case AstKind.mathBlock:
        case AstKind.mdxExpression:
        case AstKind.mdxEsmImport:
        case AstKind.mdxEsmExport:
            return true;
        default:
            return false;
    }
}

private string quotePreview(const(char)[] text, size_t maxChars)
{
    Appender!string writer = appender!string;
    size_t count = 0;
    bool truncated = false;

    foreach (ch; text)
    {
        if (count >= maxChars)
        {
            truncated = true;
            break;
        }

        switch (ch)
        {
            case '\\':
                put(writer, "\\\\");
                break;
            case '"':
                put(writer, "\\\"");
                break;
            case '\n':
                put(writer, "\\n");
                break;
            case '\r':
                put(writer, "\\r");
                break;
            case '\t':
                put(writer, "\\t");
                break;
            default:
                put(writer, ch);
                break;
        }

        ++count;
    }

    if (truncated)
        put(writer, "...");

    return "\"" ~ writer.data ~ "\"";
}

private void printDiagnostics(in ParseResult result)
{
    stderr.writeln("Diagnostics:");
    foreach (diagnostic; result.diagnostics)
    {
        auto location = result.sourceMap.locationAt(diagnostic.span.offset);
        stderr.writeln(
            "- ",
            diagnostic.level.to!string,
            " ",
            diagnostic.code.to!string,
            " at ",
            location.line,
            ":",
            location.column,
            " - ",
            diagnostic.message,
        );
    }
}

private bool hasErrors(in ParseResult result)
{
    foreach (diagnostic; result.diagnostics)
    {
        if (diagnostic.level == DiagnosticLevel.error)
            return true;
    }

    return false;
}
