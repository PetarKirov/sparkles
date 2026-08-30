module sparkles.dql.help;

import std.algorithm.searching : canFind;
import std.array : appender;
import std.stdio : stdout;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.styled_template : writeStyled;
import sparkles.base.term_color : ColorDepth;
import sparkles.base.text.width : alignField, Align;

@safe:

/// Documentation descriptor for a field addressable by DQL.
struct DqlPathDoc
{
    string path;
    string typeName;
    string description;
    string example;
    string[] aliases;
}

/// Formats a complete DQL reference guide, schema paths table, and tutorial to the given writer.
void writeDqlHelp(Writer)(ref Writer w, scope const(DqlPathDoc)[] paths,
    scope const(string)[] categories, string toolName = "wsi-input-echo", bool colored = true)
{
    const depth = colored ? ColorDepth.trueColor : ColorDepth.none;

    writeStyled(w, depth, i"{bold.cyan DQL (D Query Language) Reference & Filter Guide}\n");
    writeStyled(w, depth, i"{dim ══════════════════════════════════════════════════════════════════════════════}\n\n");

    // 1. Categories
    if (categories.length > 0)
    {
        writeStyled(w, depth, i"{bold.green AVAILABLE EVENT CATEGORIES}\n");
        writeStyled(w, depth, i"  Coarse-grained category tokens for fast-path O(1) bitset filtering:\n\n");
        foreach (cat; categories)
        {
            UniqueBuffer!(char, 32) catPadded;
            alignField(catPadded, cat, 14, Align.left);
            writeStyled(w, depth, i"    • {cyan $(catPadded[])} (e.g. {yellow -F \"$(cat)\"} or {yellow -F \"!$(cat)\"})\n");
        }
        writeStyled(w, depth, i"\n");
    }

    // 2. Paths Table
    if (paths.length > 0)
    {
        writeStyled(w, depth, i"{bold.green AVAILABLE DQL PATH ADDRESSES}\n");
        writeStyled(w, depth, i"  Fine-grained field paths queryable in event payloads:\n\n");

        size_t maxPath = 20;
        size_t maxType = 12;
        foreach (p; paths)
        {
            if (p.path.length > maxPath) maxPath = p.path.length;
            if (p.typeName.length > maxType) maxType = p.typeName.length;
        }

        UniqueBuffer!(char, 64) pBuf, tBuf, dBuf;
        alignField(pBuf, "Path", maxPath, Align.left);
        alignField(tBuf, "Type", maxType, Align.left);
        alignField(dBuf, "Description", 30, Align.left);
        writeStyled(w, depth, i"  {dim $(pBuf[])  $(tBuf[])  $(dBuf[])  Example}\n");

        UniqueBuffer!(char, 256) divBuf;
        divBuf.length = maxPath + maxType + 30 + 25 + 6;
        foreach (ref ch; divBuf[])
            ch = '-';
        writeStyled(w, depth, i"  {dim $(divBuf[])}\n");

        foreach (p; paths)
        {
            pBuf.length = 0;
            tBuf.length = 0;
            dBuf.length = 0;
            alignField(pBuf, p.path, maxPath, Align.left);
            alignField(tBuf, p.typeName, maxType, Align.left);
            alignField(dBuf, p.description, 30, Align.left);
            writeStyled(w, depth, i"  {cyan $(pBuf[])}  {blue $(tBuf[])}  $(dBuf[])  {yellow $(p.example)}\n");
            foreach (aliasPath; p.aliases)
                writeStyled(w, depth, i"  {dim aka} {cyan $(aliasPath)}\n");
        }
        writeStyled(w, depth, i"\n");
    }

    // 3. Operators & Syntax Tutorial
    writeStyled(w, depth, i"{bold.green OPERATOR SYNTAX & TUTORIAL}\n");
    writeStyled(w, depth, i"  DQL uses standard D expression syntax with zero runtime allocations:\n\n");

    writeStyled(w, depth, i"  {bold Equality & Comparison}\n");
    writeStyled(w, depth, i"    {cyan path == value}           Exact value or enum equality (e.g. {yellow pointer.phase == pressed})\n");
    writeStyled(w, depth, i"    {cyan path != value}           Inequality check (e.g. {yellow pointer.phase != moved})\n");
    writeStyled(w, depth, i"    {cyan path > n, < n, >=, <=}   Relational numeric comparison (e.g. {yellow pointer.logicalPosition.x > 400})\n");
    writeStyled(w, depth, i"    {cyan path == null, != null}   Nullability check for optional/pointer/array fields\n\n");

    writeStyled(w, depth, i"  {bold Pattern Matching Functions}\n");
    writeStyled(w, depth, i"    {cyan regexMatch(path, `re`)}   Regular expression matching (e.g. {yellow regexMatch(text.text, `^[0-9]+$`)}}\n");
    writeStyled(w, depth, i"    {cyan globMatch(path, `pat`)}   Glob wildcard matching (e.g. {yellow globMatch(text.text, `*test*`)}}\n");
    writeStyled(w, depth, i"    {cyan fuzzyMatch(path, `q`)}    Typo-tolerant fuzzy ranking search (e.g. {yellow fuzzyMatch(text.text, `hello`)}}\n\n");

    writeStyled(w, depth, i"  {bold Logical Combinators}\n");
    writeStyled(w, depth, i"    {cyan &&}                        Logical AND (both predicates must match)\n");
    writeStyled(w, depth, i"    {cyan ||} or {cyan ,}                 Logical OR (either predicate matches)\n");
    writeStyled(w, depth, i"    {cyan !}  or {cyan -}                 Logical NOT (negates the following predicate)\n");
    writeStyled(w, depth, i"    {cyan (...)}                    Group sub-expressions with parentheses for precedence\n\n");

}

/// Formats help directly from a reflected schema.
void writeDqlHelp(Schema, Writer)(ref Writer w, string toolName,
    bool colored = true)
{
    string[] categories;
    foreach (ref const category; Schema.categories)
        categories ~= category.name;
    writeDqlHelp(w, Schema.paths, categories, toolName, colored);
}

/// Helper that prints the DQL reference manual to standard output.
void printDqlHelp(scope const(DqlPathDoc)[] paths, scope const(string)[] categories,
    string toolName = "wsi-input-echo", bool colored = true)
{
    () @trusted {
        auto outRange = stdout.lockingTextWriter;
        writeDqlHelp(outRange, paths, categories, toolName, colored);
    }();
}

/// Prints help generated from a reflected schema.
void printDqlHelp(Schema)(string toolName, bool colored = true)
{
    () @trusted {
        auto outRange = stdout.lockingTextWriter;
        writeDqlHelp!Schema(outRange, toolName, colored);
    }();
}

@("dql.help: generates formatted help text")
unittest
{
    auto app = appender!string();
    DqlPathDoc[] samplePaths = [
        DqlPathDoc("pointer.phase", "PointerPhase", "Button click phase", "pointer.phase == pressed"),
        DqlPathDoc("key.action", "KeyAction", "Key stroke action", "key.action == release"),
    ];
    string[] sampleCats = ["pointer", "key", "motion"];
    writeDqlHelp(app, samplePaths, sampleCats, "test-tool", false);

    string outText = app.data;
    assert(outText.length > 0);
    assert(outText.canFind("DQL (D Query Language) Reference"));
    assert(outText.canFind("pointer.phase"));
    assert(outText.canFind("key.action"));
    assert(outText.canFind("OPERATOR SYNTAX & TUTORIAL"));
}
