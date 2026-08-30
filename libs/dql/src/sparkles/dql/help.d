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

/// Tutorial example strings derived from a doc set, so the help never
/// advertises a path its own schema does not carry.
package(sparkles.dql) struct TutorialExamples
{
    string equality;   /// an enum-flavored `path == token` example
    string relational; /// a numeric `path > n` example
    string textPath;   /// a text-typed path for the matcher functions
    string boolean;    /// a `path == true` example
}

private bool isBareIdentifierExample(string example) @safe pure nothrow @nogc
{
    // `path == token` where the token is a bare identifier (an enum member
    // spelling) — not a number, quote, `true`/`false`, or `null`.
    foreach (i; 0 .. example.length)
        if (i + 4 <= example.length && example[i .. i + 4] == " == ")
        {
            const rhs = example[i + 4 .. $];
            if (!rhs.length)
                return false;
            const c = rhs[0];
            const alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || c == '_';
            return alpha && rhs != "true" && rhs != "false" && rhs != "null"
                && rhs != "text";
        }
    return false;
}

private bool endsWith(string text, string suffix) @safe pure nothrow @nogc
    => text.length >= suffix.length && text[$ - suffix.length .. $] == suffix;

/// Scans a doc set for one representative example per tutorial line.
package(sparkles.dql) TutorialExamples pickExamples(
    scope const(DqlPathDoc)[] paths) @safe pure
{
    TutorialExamples t;
    foreach (ref const doc; paths)
    {
        if (!t.equality.length && isBareIdentifierExample(doc.example))
            t.equality = doc.example;
        if (!t.relational.length && doc.example.endsWith(" == 0"))
            t.relational = doc.path ~ " > 0";
        if (!t.textPath.length && doc.example.endsWith(" == `text`"))
            t.textPath = doc.path;
        if (!t.boolean.length && doc.example.endsWith(" == true"))
            t.boolean = doc.example;
    }
    return t;
}

/// The first category that owns at least one multi-segment path — the one
/// worth showcasing — else the first category, else `""`.
private string richCategory(scope const(DqlPathDoc)[] paths,
    scope const(string)[] categories) @safe pure
{
    foreach (category; categories)
        foreach (ref const doc; paths)
            if (doc.path.length > category.length
                && doc.path[0 .. category.length] == category
                && doc.path[category.length] == '.')
                return category;
    return categories.length ? categories[0] : "";
}

/// The recipe filter strings a doc set supports — every one parses against
/// the schema the docs came from, and each is satisfiable (the compound
/// pairs a field predicate with the category that owns its path).
package(sparkles.dql) string[] deriveRecipes(scope const(DqlPathDoc)[] paths,
    scope const(string)[] categories) @safe pure
{
    const t = pickExamples(paths);
    const showcase = richCategory(paths, categories);
    string[] recipes;
    if (showcase.length)
    {
        recipes ~= showcase;
        recipes ~= "!" ~ showcase;
    }
    foreach (category; categories)
        if (category != showcase)
        {
            recipes ~= showcase.length
                ? showcase ~ " || " ~ category : category;
            break;
        }
    if (t.equality.length)
        recipes ~= t.equality;
    if (t.relational.length)
    {
        // Pair the relational example with the category owning its path,
        // so the compound recipe can actually come true.
        string owner;
        foreach (category; categories)
            if (t.relational.length > category.length
                && t.relational[0 .. category.length] == category
                && t.relational[category.length] == '.')
            {
                owner = category;
                break;
            }
        recipes ~= owner.length
            ? owner ~ " && " ~ t.relational : t.relational;
    }
    return recipes;
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

    // 3. Operators & Syntax Tutorial — examples come from the doc set, so
    // the help never shows a path this schema does not carry.
    const t = pickExamples(paths);
    writeStyled(w, depth, i"{bold.green OPERATOR SYNTAX & TUTORIAL}\n");
    writeStyled(w, depth, i"  DQL uses standard D expression syntax with zero runtime allocations:\n\n");

    writeStyled(w, depth, i"  {bold Equality & Comparison}\n");
    writeExampleLine(w, depth, "path == value", "Exact value or enum equality", t.equality);
    writeExampleLine(w, depth, "path != value", "Inequality check", t.boolean);
    writeExampleLine(w, depth, "path > n, < n, >=, <=", "Relational comparison (bool orders as false < true)", t.relational);
    writeExampleLine(w, depth, "path == null, != null", "Presence check: absent variants and out-of-range indices", "");
    writeStyled(w, depth, i"\n");

    writeStyled(w, depth, i"  {bold Pattern Matching Functions}\n");
    writeExampleLine(w, depth, "regexMatch(path, `re`)", "Regular expression matching",
        t.textPath.length ? "regexMatch(" ~ t.textPath ~ ", `^[a-z]+$`)" : "");
    writeExampleLine(w, depth, "globMatch(path, `pat`)", "Glob wildcard matching",
        t.textPath.length ? "globMatch(" ~ t.textPath ~ ", `*test*`)" : "");
    writeExampleLine(w, depth, "fuzzyMatch(path, `q`)", "Typo-tolerant fuzzy ranking search",
        t.textPath.length ? "fuzzyMatch(" ~ t.textPath ~ ", `hello`)" : "");
    writeStyled(w, depth, i"\n");

    writeStyled(w, depth, i"  {bold Logical Combinators}\n");
    writeStyled(w, depth, i"    {cyan &&}                        Logical AND (both predicates must match)\n");
    writeStyled(w, depth, i"    {cyan ||} or {cyan ,}                 Logical OR (either predicate matches)\n");
    writeStyled(w, depth, i"    {cyan !}  or {cyan -}                 Logical NOT (negates the following predicate)\n");
    writeStyled(w, depth, i"    {cyan (...)}                    Group sub-expressions with parentheses for precedence\n\n");

    // 4. Recipes — derived from the same doc set.
    const recipes = deriveRecipes(paths, categories);
    if (recipes.length)
    {
        writeStyled(w, depth, i"{bold.green COMMON FILTER RECIPES}\n");
        foreach (recipe; recipes)
            writeStyled(w, depth, i"  $(toolName) {yellow -F \"$(recipe)\"}\n");
        writeStyled(w, depth, i"\n");
    }
}

/// One aligned tutorial line, with its example only when the doc set
/// offers one.
private void writeExampleLine(Writer)(ref Writer w, ColorDepth depth,
    string syntax, string explanation, string example)
{
    UniqueBuffer!(char, 64) sBuf;
    alignField(sBuf, syntax, 25, Align.left);
    if (example.length)
        writeStyled(w, depth, i"    {cyan $(sBuf[])} $(explanation) (e.g. {yellow $(example)})\n");
    else
        writeStyled(w, depth, i"    {cyan $(sBuf[])} $(explanation)\n");
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

@("dql.help: schema-driven tutorial and recipes parse against their schema")
@safe unittest
{
    import std.sumtype : SumType;
    import sparkles.dql.engine : DqlEngine;
    import sparkles.dql.parser : parseDql;
    import sparkles.dql.schema : DqlSchema;

    enum ModeKind { fast, slow }

    struct ModeEvent
    {
        ModeKind kind;
        bool live;
        int count;
        char[4] tag;
    }

    struct PadEvent { int p; }

    alias Schema = DqlSchema!(SumType!(ModeEvent, PadEvent));
    DqlEngine engine;

    string[] categories;
    foreach (ref const category; Schema.categories)
        categories ~= category.name;

    // Every derived recipe and tutorial example is a valid query against
    // the very schema it was derived from — the property the hardcoded
    // examples silently lost.
    foreach (recipe; deriveRecipes(Schema.paths, categories))
        assert(parseDql!Schema(engine, recipe).hasValue, recipe);

    const t = pickExamples(Schema.paths);
    assert(t.equality.length && t.relational.length && t.boolean.length
        && t.textPath.length);
    foreach (query; [t.equality, t.relational, t.boolean,
        "regexMatch(" ~ t.textPath ~ ", `^a`)"])
        assert(parseDql!Schema(engine, query).hasValue, query);

    auto app = appender!string();
    writeDqlHelp!Schema(app, "test-tool", false);
    assert(app.data.canFind(t.equality));
    assert(app.data.canFind("COMMON FILTER RECIPES"));
}
