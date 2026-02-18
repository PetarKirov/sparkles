/** Parses D source files via `dmd -X` JSON output and produces
 * a documentation model.
 *
 * See_Also: $(MREF sparkle_docs, model)
 */
module sparkle_docs.parser.dmd_json;

import std.algorithm.iteration : map;
import std.algorithm.searching : any, canFind;
import std.array : array, split;
import std.conv : to;
import std.datetime.systime : Clock;
import std.file : dirEntries, isDir, isFile, readText, SpanMode;
import std.json : parseJSON;
import std.path : dirName, extension, globMatch;
import std.string : endsWith, indexOf, join, replace, splitLines, startsWith, strip;

import sparkle_docs.model :
    ModuleDoc, Output, Parameter, Protection, SearchIndexEntry,
    Symbol, SymbolKind, TypeGraph, TypeGraphEdge, TypeGraphNode;
import sparkles.core_cli.json : fromJSON;
import sparkles.core_cli.string : enumToString;

/// A function parameter as represented in DMD's JSON AST.
struct DmdParam
{
    string name;
    string type;
    string default_;
    string[] storageClass;
}

/// A declaration node from DMD's `-X` JSON output.
struct DmdDecl
{
    string name;
    string kind;
    string protection;
    string file;
    string type;
    string base;
    string comment;
    string constraint;
    size_t line;
    size_t endline;
    size_t char_;
    DmdParam[] parameters;
    string[] interfaces;
    DmdDecl[] members;
}

/** Parses D source files by invoking `dmd -X` and converting
 * the resulting JSON AST into a documentation model.
 */
struct DmdJsonParser
{
    string[] sourcePaths;
    string[] excludePatterns;
    string[] importPaths;
    string[string] classBaseBySymbol;
    string[][string] interfacesBySymbol;
    string[string] aliasTargetBySymbol;
    bool includePrivate;

    this(string[] sourcePaths, string[] excludePatterns = [], bool includePrivate = false)
    {
        this.sourcePaths = sourcePaths;
        this.excludePatterns = excludePatterns;
        this.importPaths = inferImportPaths(sourcePaths);
        this.includePrivate = includePrivate;
    }

    /** Parse all configured source paths and return the documentation model.
     *
     * Discovers `.d` files, invokes `dmd -X` on each, and aggregates the
     * results into an $(REF Output, sparkle_docs, model, config).
     *
     * Returns: the populated documentation output
     */
    Output parse()
    {
        Output output;
        output.version_ = "0.1.0";
        output.generated = Clock.currTime.toUTC.toISOExtString();

        foreach (srcPath; sourcePaths)
        {
            foreach (dFile; findDFiles(srcPath))
            {
                if (isExcluded(dFile))
                    continue;

                auto moduleInfo = parseModule(dFile);
                if (moduleInfo.qualifiedName.length > 0)
                {
                    output.modules[moduleInfo.qualifiedName] = moduleInfo;
                    output.searchIndex ~= buildSearchIndex(moduleInfo);
                }
            }
        }

        output.typeGraph = buildTypeGraph(output.modules);

        return output;
    }

    ModuleDoc parseModule(string filePath)
    {
        auto rootDecls = generateDmdJson(filePath);
        if (rootDecls.length == 0)
            return ModuleDoc.init;

        DmdDecl root = rootDecls[0];
        foreach (decl; rootDecls)
        {
            if (decl.kind == "module")
            {
                root = decl;
                break;
            }
        }

        ModuleDoc mod;
        mod.fileName = filePath;
        mod.qualifiedName = root.name;
        mod.sourceFile = root.file.length > 0 ? root.file : filePath;

        string[] sourceLines = readText(filePath).splitLines();

        size_t lastDocSymbolIndex = size_t.max;
        foreach (member; root.members)
        {
            if (isUnittestDecl(member))
            {
                if (lastDocSymbolIndex != size_t.max)
                {
                    auto snippet = extractUnittestSnippet(member, sourceLines);
                    if (snippet.length > 0)
                        mod.symbols[lastDocSymbolIndex].unittests ~= snippet;
                }
                continue;
            }

            auto sym = parseSymbol(member, mod.qualifiedName, "", mod.sourceFile, sourceLines);
            if (sym.name.length == 0)
                continue;

            if (!includePrivate && sym.protection == Protection.private_)
                continue;

            mod.symbols ~= sym;
            lastDocSymbolIndex = mod.symbols.length - 1;
        }

        return mod;
    }

    Symbol parseSymbol(
        DmdDecl decl,
        string moduleQual,
        string parentQual = "",
        string moduleSourceFile = "",
        string[] sourceLines = []
    )
    {
        Symbol sym;

        sym.name = decl.name;
        sym.kind = parseSymbolKind(decl.kind);
        sym.protection = parseProtection(decl.protection);

        if (parentQual.length > 0)
            sym.qualifiedName = parentQual ~ "." ~ sym.name;
        else
            sym.qualifiedName = moduleQual ~ "." ~ sym.name;

        sym.line = decl.line;
        sym.column = decl.char_;
        sym.sourceFile = decl.file.length > 0 ? decl.file : moduleSourceFile;

        if (decl.type.length > 0)
            parseFunctionSignature(decl.type, sym);

        if (decl.base.length > 0)
            sym.baseTypes ~= decl.base;
        if (decl.interfaces.length > 0)
            sym.baseTypes ~= decl.interfaces;
        classBaseBySymbol[sym.qualifiedName] = decl.base;
        interfacesBySymbol[sym.qualifiedName] = decl.interfaces;
        if (decl.kind == "alias")
        {
            auto aliasTarget = parseAliasTarget(decl, sourceLines);
            if (aliasTarget.length > 0)
                aliasTargetBySymbol[sym.qualifiedName] = aliasTarget;
        }

        if (decl.comment.length > 0)
            parseComment(decl.comment, sym);

        foreach (param; decl.parameters)
        {
            Parameter p;
            p.name = param.name;
            p.type = param.type;
            p.defaultValue = param.default_;
            sym.parameters ~= p;
        }

        size_t lastDocMemberIndex = size_t.max;
        foreach (member; decl.members)
        {
            if (isUnittestDecl(member))
            {
                auto snippet = extractUnittestSnippet(member, sourceLines);
                if (snippet.length == 0)
                    continue;
                if (lastDocMemberIndex != size_t.max)
                    sym.members[lastDocMemberIndex].unittests ~= snippet;
                else
                    sym.unittests ~= snippet;
                continue;
            }

            auto childSym = parseSymbol(member, moduleQual, sym.qualifiedName, sym.sourceFile, sourceLines);
            if (childSym.name.length == 0)
                continue;

            if (!includePrivate && childSym.protection == Protection.private_)
                continue;

            sym.members ~= childSym;
            lastDocMemberIndex = sym.members.length - 1;
        }

        return sym;
    }

    static SymbolKind parseSymbolKind(string kind) @safe pure nothrow @nogc
    {
        switch (kind)
        {
            case "module": return SymbolKind.module_;
            case "package": return SymbolKind.package_;
            case "struct": return SymbolKind.struct_;
            case "class": return SymbolKind.class_;
            case "interface": return SymbolKind.interface_;
            case "enum": return SymbolKind.enum_;
            case "function": return SymbolKind.function_;
            case "variable": return SymbolKind.variable;
            case "alias": return SymbolKind.alias_;
            case "template": return SymbolKind.template_;
            case "constructor": return SymbolKind.constructor;
            case "destructor": return SymbolKind.destructor;
            case "postblit": return SymbolKind.postblit;
            case "invariant": return SymbolKind.invariant_;
            case "unittest": return SymbolKind.unittest_;
            case "enum member": return SymbolKind.enumMember;
            default: return SymbolKind.function_;
        }
    }

    static Protection parseProtection(string prot) @safe pure nothrow @nogc
    {
        switch (prot)
        {
            case "private": return Protection.private_;
            case "protected": return Protection.protected_;
            case "public": return Protection.public_;
            case "package": return Protection.package_;
            case "export": return Protection.export_;
            default: return Protection.public_;
        }
    }

    static void parseFunctionSignature(string type, ref Symbol sym) @safe pure nothrow
    {
        auto parenIdx = type.indexOf("(");
        sym.returnType = parenIdx >= 0 ? type[0 .. parenIdx].strip() : type;
    }

    DmdDecl[] generateDmdJson(string filePath)
    {
        import std.process : execute;
        string[] cmd = ["dmd", "-X", "-Xf=-", "-D", "-Df=/dev/null", "-o-"];
        foreach (importPath; importPaths)
            cmd ~= "-I" ~ importPath;
        cmd ~= filePath;

        auto result = execute(cmd);
        if (result.status != 0)
            throw new Exception(
                "dmd -X failed for '" ~ filePath ~ "' with status " ~ result.status.to!string
            );

        try
        {
            auto json = parseJSON(result.output);
            return json.fromJSON!(DmdDecl[]);
        }
        catch (Exception e)
        {
            throw new Exception("Failed to parse dmd JSON output for '" ~ filePath ~ "': " ~ e.msg);
        }
    }

    static string[] findDFiles(string path)
    {
        if (isFile(path) && path.extension == ".d")
            return [path];
        if (isDir(path))
            return dirEntries(path, "*.d", SpanMode.depth).map!(e => e.name).array;
        return [];
    }

    bool isExcluded(string filePath) => excludePatterns.any!(p => globMatch(filePath, p));

    static SearchIndexEntry[] buildSearchIndex(ModuleDoc mod)
    {
        SearchIndexEntry[] entries;

        void addSymbols(Symbol[] syms, string moduleQual)
        {
            foreach (sym; syms)
            {
                SearchIndexEntry entry;
                entry.qualifiedName = sym.qualifiedName;
                entry.name = sym.name;
                entry.kind = sym.kind.enumToString;
                entry.summary = sym.summary;
                entry.url = buildUrl(sym.qualifiedName);
                entries ~= entry;

                if (sym.members.length > 0)
                    addSymbols(sym.members, moduleQual);
            }
        }

        addSymbols(mod.symbols, mod.qualifiedName);
        return entries;
    }

    static string buildUrl(string qualifiedName) @safe pure =>
        "/api/" ~ qualifiedName.split(".").join("/");

    static bool isUnittestDecl(DmdDecl decl) @safe pure nothrow @nogc =>
        decl.kind == "unittest" || decl.name.startsWith("__unittest_");

    static string extractUnittestSnippet(DmdDecl decl, string[] sourceLines) @safe pure
    {
        if (sourceLines.length == 0 || decl.line == 0)
            return "";

        auto startLine = decl.line;
        auto endLine = decl.endline > 0 ? decl.endline : startLine;

        if (startLine == 0 || endLine == 0 || startLine > sourceLines.length)
            return "";

        if (endLine > sourceLines.length)
            endLine = sourceLines.length;
        if (endLine < startLine)
            endLine = startLine;

        string[] block;
        bool sawOpeningBrace;
        size_t depth;

        foreach (idx; startLine - 1 .. endLine)
        {
            auto line = sourceLines[idx];
            block ~= line;
            foreach (ch; line)
            {
                if (ch == '{')
                {
                    depth++;
                    sawOpeningBrace = true;
                }
                else if (ch == '}' && depth > 0)
                {
                    depth--;
                    if (sawOpeningBrace && depth == 0)
                        return trimAfterFinalBrace(block.join("\n"));
                }
            }
        }

        return trimAfterFinalBrace(block.join("\n"));
    }

    static void parseComment(string comment, ref Symbol sym) @safe pure
    {
        if (comment.length == 0)
            return;

        auto lines = comment.splitLines();
        string[] summaryLines;
        bool started;
        foreach (line; lines)
        {
            auto trimmed = line.strip;
            if (trimmed.length == 0)
            {
                if (started)
                    break;
                continue;
            }
            started = true;
            summaryLines ~= trimmed;
        }
        sym.summary = summaryLines.join(" ");
        sym.description = comment.strip;
        sym.examples ~= extractDdocExamples(comment);
    }

    static string[] extractDdocExamples(string comment) @safe pure
    {
        auto lines = comment.splitLines();
        string[] examples;
        bool inExampleSection;
        bool inFence;
        string[] block;

        foreach (line; lines)
        {
            auto trimmed = line.strip;

            if (!inExampleSection)
            {
                if (trimmed == "Example:" || trimmed == "Examples:")
                    inExampleSection = true;
                continue;
            }

            if ((trimmed == "Example:" || trimmed == "Examples:") && block.length > 0)
            {
                examples ~= block.join("\n").strip;
                block = [];
                inFence = false;
                continue;
            }

            if (!inFence && isDdocSectionHeader(trimmed))
                break;

            if (trimmed == "---")
            {
                if (inFence)
                {
                    auto text = block.join("\n").strip;
                    if (text.length > 0)
                        examples ~= text;
                    block = [];
                    inFence = false;
                }
                else
                {
                    inFence = true;
                    block = [];
                }
                continue;
            }

            if (inFence || trimmed.length > 0)
                block ~= line;
        }

        if (block.length > 0)
        {
            auto text = block.join("\n").strip;
            if (text.length > 0)
                examples ~= text;
        }

        return examples;
    }

    static bool isDdocSectionHeader(string line) @safe pure nothrow @nogc
    {
        if (line.length < 2)
            return false;

        auto sep = line.indexOf(':');
        if (sep <= 0)
            return false;

        foreach (ch; line[0 .. sep])
        {
            if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_'))
                return false;
        }
        return true;
    }

    static string trimAfterFinalBrace(string snippet) @safe pure
    {
        auto lines = snippet.splitLines();
        ptrdiff_t lastBraceLine = -1;
        foreach (idx, line; lines)
        {
            if (line.strip == "}")
                lastBraceLine = cast(ptrdiff_t) idx;
        }
        if (lastBraceLine >= 0)
            return lines[0 .. cast(size_t) lastBraceLine + 1].join("\n");
        return snippet;
    }

    static string[] inferImportPaths(string[] paths)
    {
        string[] results;

        void addPath(string p)
        {
            if (p.length == 0 || results.canFind(p))
                return;
            results ~= p;
        }

        foreach (inputPath; paths)
        {
            string candidate = inputPath;
            if (isFile(candidate))
                candidate = candidate.dirName;

            addPath(candidate);

            auto normalized = candidate.replace("\\", "/");
            auto srcMarkerIndex = normalized.indexOf("/src/");
            if (srcMarkerIndex >= 0)
            {
                addPath(normalized[0 .. srcMarkerIndex + 4]);
                continue;
            }
            if (normalized.endsWith("/src"))
                addPath(normalized);
        }

        return results;
    }

    TypeGraph buildTypeGraph(ModuleDoc[string] modules)
    {
        TypeGraph graph;
        bool[string] seenNodes;
        bool[string] seenEdges;

        void addNode(string id, string kind)
        {
            if (id.length == 0 || (id in seenNodes))
                return;
            seenNodes[id] = true;
            graph.nodes ~= TypeGraphNode(id, id, kind);
        }

        void addEdge(string from, string to, string relation)
        {
            if (from.length == 0 || to.length == 0)
                return;
            auto key = from ~ "|" ~ to ~ "|" ~ relation;
            if (key in seenEdges)
                return;
            seenEdges[key] = true;
            graph.edges ~= TypeGraphEdge(from, to, relation);
        }

        void visitSymbols(Symbol[] symbols)
        {
            foreach (sym; symbols)
            {
                auto kind = sym.kind.enumToString;
                addNode(sym.qualifiedName, kind);

                if (sym.members.length > 0)
                {
                    foreach (member; sym.members)
                    {
                        addNode(member.qualifiedName, member.kind.enumToString);
                        addEdge(sym.qualifiedName, member.qualifiedName, "has-part");
                    }
                }

                if (kind == "alias")
                {
                    auto aliasTarget = sym.qualifiedName in aliasTargetBySymbol;
                    if (aliasTarget !is null && (*aliasTarget).length > 0)
                    {
                        addNode(*aliasTarget, "unknown");
                        addEdge(sym.qualifiedName, *aliasTarget, "aliases");
                    }
                }

                bool canHaveTypeEdges = kind == "class" || kind == "interface";
                if (canHaveTypeEdges)
                {
                    auto classBase = sym.qualifiedName in classBaseBySymbol;
                    auto interfaces = sym.qualifiedName in interfacesBySymbol;

                    if (kind == "class" && classBase !is null && (*classBase).length > 0)
                    {
                        addNode(*classBase, "unknown");
                        addEdge(sym.qualifiedName, *classBase, "extends");
                    }

                    if (kind == "interface")
                    {
                        if (interfaces !is null)
                        foreach (iface; *interfaces)
                        {
                            if (iface.length == 0)
                                continue;
                            addNode(iface, "unknown");
                            addEdge(sym.qualifiedName, iface, "extends");
                        }
                    }
                    else if (kind == "class")
                    {
                        if (interfaces !is null)
                        foreach (iface; *interfaces)
                        {
                            if (iface.length == 0)
                                continue;
                            addNode(iface, "unknown");
                            addEdge(sym.qualifiedName, iface, "implements");
                        }
                    }
                    else
                    {
                        foreach (baseType; sym.baseTypes)
                        {
                            if (baseType.length == 0)
                                continue;
                            addNode(baseType, "unknown");
                            addEdge(sym.qualifiedName, baseType, "references");
                        }
                    }
                }

                if (!canHaveTypeEdges && sym.baseTypes.length > 0)
                {
                    foreach (baseType; sym.baseTypes)
                    {
                        if (baseType.length == 0)
                            continue;
                        addNode(baseType, "unknown");
                        addEdge(sym.qualifiedName, baseType, "references");
                    }
                }

                if (sym.members.length > 0)
                    visitSymbols(sym.members);
            }
        }

        foreach (_moduleName, mod; modules)
            visitSymbols(mod.symbols);

        return graph;
    }

    static string parseAliasTarget(DmdDecl decl, string[] sourceLines) @safe pure
    {
        if (decl.line == 0 || decl.line > sourceLines.length)
            return "";

        auto line = sourceLines[decl.line - 1].strip;
        if (!line.startsWith("alias "))
            return "";

        auto eqIdx = line.indexOf('=');
        if (eqIdx < 0)
            return "";

        auto semIdx = line.indexOf(';');
        if (semIdx < 0 || semIdx <= eqIdx)
            return "";

        auto target = line[eqIdx + 1 .. semIdx].strip;
        return target;
    }
}

// ---------------------------------------------------------------------------
// Unit tests for static helper methods
// ---------------------------------------------------------------------------

@("DmdJsonParser.parseSymbolKind.knownKinds")
@safe pure nothrow @nogc
unittest
{
    alias p = DmdJsonParser.parseSymbolKind;
    assert(p("module") == SymbolKind.module_);
    assert(p("struct") == SymbolKind.struct_);
    assert(p("class") == SymbolKind.class_);
    assert(p("enum") == SymbolKind.enum_);
    assert(p("function") == SymbolKind.function_);
    assert(p("enum member") == SymbolKind.enumMember);
    assert(p("unittest") == SymbolKind.unittest_);
    assert(p("alias") == SymbolKind.alias_);
    assert(p("template") == SymbolKind.template_);
    assert(p("constructor") == SymbolKind.constructor);
    assert(p("destructor") == SymbolKind.destructor);
}

@("DmdJsonParser.parseSymbolKind.unknownDefaultsToFunction")
@safe pure nothrow @nogc
unittest
{
    assert(DmdJsonParser.parseSymbolKind("bogus") == SymbolKind.function_);
    assert(DmdJsonParser.parseSymbolKind("") == SymbolKind.function_);
}

@("DmdJsonParser.parseProtection.knownLevels")
@safe pure nothrow @nogc
unittest
{
    alias p = DmdJsonParser.parseProtection;
    assert(p("private") == Protection.private_);
    assert(p("protected") == Protection.protected_);
    assert(p("public") == Protection.public_);
    assert(p("package") == Protection.package_);
    assert(p("export") == Protection.export_);
}

@("DmdJsonParser.parseProtection.unknownDefaultsToPublic")
@safe pure nothrow @nogc
unittest
{
    assert(DmdJsonParser.parseProtection("") == Protection.public_);
    assert(DmdJsonParser.parseProtection("bogus") == Protection.public_);
}

@("DmdJsonParser.parseFunctionSignature.withParens")
@safe pure nothrow
unittest
{
    Symbol sym;
    DmdJsonParser.parseFunctionSignature("int(string, int)", sym);
    assert(sym.returnType == "int");
}

@("DmdJsonParser.parseFunctionSignature.withoutParens")
@safe pure nothrow
unittest
{
    Symbol sym;
    DmdJsonParser.parseFunctionSignature("string", sym);
    assert(sym.returnType == "string");
}

@("DmdJsonParser.buildUrl")
@safe pure
unittest
{
    assert(DmdJsonParser.buildUrl("std.algorithm.sort") == "/api/std/algorithm/sort");
    assert(DmdJsonParser.buildUrl("mymod") == "/api/mymod");
}

@("DmdJsonParser.isUnittestDecl")
@safe pure nothrow @nogc
unittest
{
    DmdDecl ut;
    ut.kind = "unittest";
    assert(DmdJsonParser.isUnittestDecl(ut));

    DmdDecl named;
    named.name = "__unittest_L42_C1";
    assert(DmdJsonParser.isUnittestDecl(named));

    DmdDecl regular;
    regular.kind = "function";
    regular.name = "foo";
    assert(!DmdJsonParser.isUnittestDecl(regular));
}

@("DmdJsonParser.isDdocSectionHeader")
@safe pure nothrow @nogc
unittest
{
    alias h = DmdJsonParser.isDdocSectionHeader;
    assert(h("Params:"));
    assert(h("Returns:"));
    assert(h("See_Also:"));
    assert(!h(""));
    assert(!h("x"));
    assert(!h(":"));
    assert(!h("123:"));
}

@("DmdJsonParser.trimAfterFinalBrace")
@safe pure
unittest
{
    assert(DmdJsonParser.trimAfterFinalBrace("{\n    x;\n}") == "{\n    x;\n}");
    assert(DmdJsonParser.trimAfterFinalBrace("{\n}\ntrailing") == "{\n}");
    assert(DmdJsonParser.trimAfterFinalBrace("no braces") == "no braces");
}

@("DmdJsonParser.parseComment.summary")
@safe pure
unittest
{
    Symbol sym;
    DmdJsonParser.parseComment("First line of summary.\n\nBody paragraph.", sym);
    assert(sym.summary == "First line of summary.");
    assert(sym.description == "First line of summary.\n\nBody paragraph.");
}

@("DmdJsonParser.parseComment.multiLineSummary")
@safe pure
unittest
{
    Symbol sym;
    DmdJsonParser.parseComment("Line one\nline two\n\nBody.", sym);
    assert(sym.summary == "Line one line two");
}

@("DmdJsonParser.extractDdocExamples.fencedExample")
@safe pure
unittest
{
    auto examples = DmdJsonParser.extractDdocExamples(
        "Summary\n\nExamples:\n---\nauto x = 1;\n---\n"
    );
    assert(examples.length == 1);
    assert(examples[0] == "auto x = 1;");
}

@("DmdJsonParser.extractDdocExamples.noExamples")
@safe pure
unittest
{
    auto examples = DmdJsonParser.extractDdocExamples("Just a summary.\n\nParams:\n  x = value\n");
    assert(examples.length == 0);
}

@("DmdJsonParser.parseAliasTarget.simpleAlias")
@safe pure
unittest
{
    DmdDecl decl;
    decl.line = 1;
    auto target = DmdJsonParser.parseAliasTarget(decl, ["alias Foo = Bar;"]);
    assert(target == "Bar");
}

@("DmdJsonParser.parseAliasTarget.noAlias")
@safe pure
unittest
{
    DmdDecl decl;
    decl.line = 1;
    assert(DmdJsonParser.parseAliasTarget(decl, ["int x = 42;"]) == "");
}

@("DmdJsonParser.parseAliasTarget.outOfBounds")
@safe pure
unittest
{
    DmdDecl decl;
    decl.line = 5;
    assert(DmdJsonParser.parseAliasTarget(decl, ["alias Foo = Bar;"]) == "");
}
