/** Conformance of the public surface to SPEC §2/§11, and differential process
tests against the pinned, unmodified DUB parser. The oracle is test-only and
never joins the production import closure. */
module sparkles.wired.sdl.conformance;

version (unittest):

private auto normalizedScalar(scope const ref SdlScalar value)
{
    import std.base64 : Base64;
    import std.conv : text;
    import std.format : format;
    import std.json : JSONValue;

    string type;
    JSONValue payload;
    final switch (value.kind) with (SdlScalarKind)
    {
    case none: assert(false, "no scalar payload");
    case null_: return JSONValue(["type": JSONValue("null")]);
    case boolean: type = "bool"; payload = JSONValue(value.boolean); break;
    case string_: type = "string"; payload = JSONValue(value.stringValue.idup); break;
    case character: type = "dchar"; payload = JSONValue(cast(long) value.character); break;
    case integer: type = "int"; payload = JSONValue(cast(long) value.integer); break;
    case longInteger: type = "long"; payload = JSONValue(value.longInteger); break;
    case float_: type = "float"; payload = JSONValue(format("%a", value.floatValue)); break;
    case double_: type = "double"; payload = JSONValue(format("%a", value.doubleValue)); break;
    case decimal: type = "real"; payload = JSONValue(format("%a", value.decimalValue)); break;
    case binary: type = "binary"; payload = JSONValue(Base64.encode(value.binary)); break;
    case date:
        type = "date";
        const date = value.date;
        payload = JSONValue(text(date.year, "/", cast(int) date.month, "/", date.day));
        break;
    case dateTime:
    case zonedDateTime:
        const local = value.kind == dateTime ? value.dateTime : value.zonedDateTime.local;
        type = value.kind == dateTime ? "dateTime" : "zonedDateTime";
        payload = JSONValue([JSONValue(local.date.year), JSONValue(cast(int) local.date.month),
            JSONValue(local.date.day), JSONValue(local.hour), JSONValue(local.minute),
            JSONValue(local.second), JSONValue(local.fractionHnsecs)]);
        break;
    case duration:
        type = "duration"; payload = JSONValue(value.duration.total!"hnsecs"); break;
    }
    return JSONValue(["type": JSONValue(type), "payload": payload]);
}

/// Recipe decoding must not link disabled numeric or temporal conversion kernels.
@("sdl.conformance.recipeLinkedSymbols")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : write;
    import std.path : buildNormalizedPath, buildPath, dirName;
    import std.process : execute;

    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmp = TmpFS.create();
    const source = buildPath(tmp.dir(), "recipe.d");
    const root = buildNormalizedPath(__FILE_FULL_PATH__.dirName, "../../../../../..");
    write(source, "/+ dub.sdl:\nname \"sdl-recipe-symbol-probe\"\n"
        ~ "dependency \"sparkles:wired\" path=\"" ~ root ~ "\"\n+/\n"
        ~ q{
            import sparkles.wired.sdl.config : sdlDubRecipe;
            import sparkles.wired.sdl.reader : parseSdlDocument;
            void main(string[] args) {
                auto parsed = parseSdlDocument!sdlDubRecipe(args.length > 1 ? args[1] : "name \"demo\"\n");
                assert(parsed.hasValue);
            }
        });
    const build = execute(["dub", "build", "--single", source, "--compiler=ldc2", "--skip-registry=all"],
        workDir: tmp.dir());
    assert(build.status == 0, build.output);
    const symbols = execute(["nm", buildPath(tmp.dir(), "sdl-recipe-symbol-probe")]);
    assert(symbols.status == 0, build.output ~ symbols.output);
    assert(symbols.output.canFind("decodeSdlScalarInto"), "probe did not instantiate scalar decoding");
    foreach (name; ["decodeFloat", "readSdlDecimalFloat", "decodeInteger",
        "decodeDatePart", "decodeDateTimePart", "decodeDurationValue"])
        assert(!symbols.output.canFind(name), "disabled kernel linked: " ~ name);
}

import sparkles.wired.sdl.document : SdlNode, SdlScalar, SdlScalarKind;
import sparkles.wired.sdl.lexer : SdlTokenKind;
import std.json : JSONValue;

// The oracle's token vocabulary: DUB folds both terminators into `EOL` and
// every scalar into `Value`, and emits no end-of-input token.
private string[] oracleKind(SdlTokenKind kind) @safe pure nothrow
{
    final switch (kind) with (SdlTokenKind)
    {
    case eof: return null;
    case newline, semicolon: return ["terminator"];
    case colon: return [":"];
    case equals: return ["="];
    case openBrace: return ["{"];
    case closeBrace: return ["}"];
    case identifier: return ["identifier"];
    case null_, boolean, string_, character, integer, longInteger, float_,
        double_, decimal, binary, date, dateTime, zonedDateTime, duration:
        return ["scalar"];
    }
}

/// The SPEC §2 import list resolves, every §11 signature accepts its documented
/// call, the role projection stays package-internal, and no wired module
/// imports DUB.
@("sdl.conformance.publicSurface")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.array : appender;
    import std.file : SpanMode, dirEntries, readText;
    import std.path : buildNormalizedPath, dirName;

    // SPEC §2, verbatim.
    import sparkles.wired.sdl :
        Sdl,
        SdlAttribute, SdlChild, SdlExtra, SdlTagName, SdlTagNamespace, SdlTagValue,
        SdlDocument, SdlNode, SdlScalar, SdlScalarKind, SdlQualifiedName, SdlSpan,
        SdlDateTime, SdlZonedDateTime, SdlExtras, SdlExtraMember,
        SdlParseResult, SdlParserConfig, SdlScalarFeatures, SdlSyntaxFeatures,
        SdlSyntaxCompatibility, sdlFull, sdlDubCompat, sdlDubRecipe,
        SdlWriteOptions,
        SdlError, SdlErrorCode, SdlErrorStage, SdlString,
        parseSdlDocument, validateSDL, writeSdlDocument,
        fromSDL, writeSDL, toSDL, readSDLFile, writeSDLFile,
        Decoded, WireFieldSet, isWireRoundTrippable;
    // SPEC §2, the names specified in later sections.
    import sparkles.wired.sdl :
        SdlTokenKind, SdlToken, SdlLexer, lexSDL, SdlScalarStorage, decodeSdlScalar,
        SdlNameQuery, SdlNamespaceMatch, SdlFilteredAttributeRange,
        SdlFilteredChildRange, SdlValueRange, SdlAttributeRange, SdlChildRange,
        SdlAttributeView, SdlPosition, SdlTagValueAttr, SdlAttributeAttr,
        SdlChildAttr, SdlTagNameAttr, SdlTagNamespaceAttr, SdlExtraAttr,
        SdlExpected, sdlOk, sdlErr, OwnedSdlExtras, SdlOwnedExtraMember,
        SdlOwnedExtraNode, SdlOwnedExtraAttribute, SdlExtraChannel,
        writeSdlScalar, sdlParserConfigFor;

    static struct Doc { @SdlAttribute() int port; }
    static struct Sink
    {
        SdlError[] errors;
        void put(SdlError e) { errors ~= e; }
    }
    // SPEC §11, one documented call per signature.
    static assert(__traits(compiles, {
        string text, name;
        Sink sink;
        SdlString buffer;
        auto parsed = parseSdlDocument!sdlDubCompat(text, name);
        SdlExpected!void valid = validateSDL!sdlDubRecipe(text, name);
        valid = writeSdlDocument(parsed.document, buffer, SdlWriteOptions.init);
        auto token = lexSDL!sdlFull(text, name).front;
        SdlScalarStorage storage;
        SdlExpected!SdlScalar scalar = decodeSdlScalar!sdlFull(token.value, storage);
        valid = writeSdlScalar(scalar.value, buffer);
        SdlExpected!Doc a = fromSDL!Doc(text, name);
        SdlExpected!Doc b = fromSDL!(Doc, Sink)(text, sink, name);
        SdlExpected!Doc c = fromSDL!Doc(parsed.document.root);
        SdlExpected!Doc d = fromSDL!(Doc, Sink)(parsed.document.root, sink);
        SdlExpected!(Decoded!Doc) e = fromSDL!(Decoded!Doc)(text);
        const value = Doc(1);
        valid = writeSDL(value, buffer);
        SdlExpected!SdlString f = toSDL(value);
        SdlExpected!Doc g = readSDLFile!Doc(name);
        valid = writeSDLFile(value, name);
    }));

    import sparkles.wired.sdl.schema_annotations : sdlAggregateRoles;
    static assert(__traits(getVisibility, sdlAggregateRoles) == "package");

    // No wired source, test helpers aside, depends on DUB.
    const sources = buildNormalizedPath(__FILE_FULL_PATH__.dirName, "../..");
    auto offenders = appender!(string[]);
    enum needle = "import " ~ "dub."; // split so this file does not match
    foreach (entry; dirEntries(sources, "*.d", SpanMode.depth))
        if (readText(entry.name).canFind(needle))
            offenders ~= entry.name;
    assert(!offenders[].length, offenders[].length ? offenders[][0] : "");
}

// The oracle's tree shape: values, then attributes and child tags in source
// order across every namespace.
private JSONValue normalizedTree(scope SdlNode node)
{
    JSONValue[] values, attributes, tags;
    foreach (value; node.byValue)
        values ~= normalizedScalar(value);
    foreach (attribute; node.byAttribute)
    {
        const name = attribute.qualifiedName;
        const value = attribute.value;
        attributes ~= JSONValue(["namespace": JSONValue(name.namespace_.idup),
            "name": JSONValue(name.localName.idup), "value": normalizedScalar(value)]);
    }
    foreach (child; node.byChild)
        tags ~= normalizedTree(child);
    const name = node.qualifiedName;
    return JSONValue(["namespace": JSONValue(name.namespace_.idup),
        "name": JSONValue(name.localName.idup), "values": JSONValue(values),
        "attributes": JSONValue(attributes), "tags": JSONValue(tags)]);
}

// Whether every scalar in an oracle tree is one the recipe profile admits.
private bool recipeScalarsOnly(scope const JSONValue tree)
{
    import std.algorithm.searching : all;

    static bool admitted(const JSONValue value)
        => value["type"].str == "string" || value["type"].str == "bool";
    return tree["values"].array.all!admitted
        && tree["attributes"].array.all!(a => admitted(a["value"]))
        && tree["tags"].array.all!(t => recipeScalarsOnly(t));
}

/** Differential conformance with the pinned, unmodified DUB implementation.

Inputs are the original fixtures below plus every string literal inside a
`unittest` block of DUB's SDLang lexer, parser, AST, and token modules and of
its SDL recipe module, read from the pinned checkout by the oracle (see
PROVENANCE.md). For each input, `sdlDubCompat` must match DUB on lexer
acceptance, token kinds, scalar payloads, parser acceptance, and the parsed
tree; `sdlDubRecipe` must accept exactly the inputs DUB parses whose scalars
are all strings or booleans, with the same tree. */
@("sdl.conformance.pinnedDub")
@system unittest
{
    import std.base64 : Base64;
    import std.file : exists, write;
    import std.json : JSONValue, parseJSON;
    import std.path : buildPath, dirName;
    import std.process : environment, execute;

    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.wired.sdl.config : sdlDubCompat, sdlDubRecipe;
    import sparkles.wired.sdl.lexer : lexSDL, decodeSdlScalar, SdlScalarStorage;
    import sparkles.wired.sdl.reader : parseSdlDocument;

    const root = environment.get("SPARKLES_FLAKE_INPUT_DUB_SDL_SRC");
    assert(root.length && exists(root), "enter the updated dev shell: missing pinned DUB input");
    auto tmp = TmpFS.create();
    const oracle = buildPath(tmp.dir(), "oracle");
    const helper = buildPath(__FILE_FULL_PATH__.dirName, "../../../../test/sdl_dub_oracle.d");
    const source = buildPath(root, "source");
    const compiled = execute(["ldc2", "-i", "-I=" ~ source,
        "-J=" ~ buildPath(source, "dub", "internal", "sdlang"),
        "-J=" ~ buildPath(source, "dub", "recipe"), helper, "-of=" ~ oracle]);
    assert(compiled.status == 0, compiled.output);
    // These are original Sparkles inputs, not copied upstream unittest bodies.
    string[] fixtures = ["", "name \"demo\"\n", "enabled on; disabled off\n",
        "ns:tag 1 2L 3F 4D 5BD attr=true\n", "tag null 'x' [YWJj]\n",
        "tag `raw` \"escaped\\ntext\"\n", "// comment\ntag { child 1\n}\n",
        "tag 2026/10/22\n", "tag 01:02:03.004\n", "tag 1:02\n",
        "tag 2026/10/22 01:02:03-GMT+02:00\n", "tag \"unterminated",
        "tag [!bad]\n", "tag {", "tag =\n", "tag 1 2\n",
        "tag \"a b\"\n", "tag `a b c`\n", "tag \"a\x01b\"\n",
        "x:a 1 y:b=2 c=3 {\n  y:d\n  e\n  x:f\n}\n", "\"anonymous\" k=1\n"];
    const inputs = buildPath(tmp.dir(), "inputs.json");
    write(inputs, JSONValue(fixtures).toString);
    const run = execute([oracle, inputs]);
    assert(run.status == 0, run.output);
    const results = parseJSON(run.output);
    assert(results["fixtures"].array.length == fixtures.length);
    const corpus = results["corpus"].array;
    assert(corpus.length >= 500, "the upstream corpus extraction found too few inputs");

    string[] mismatches;
    void compare(scope const ref JSONValue result, string origin)
    {
        const input = cast(string) Base64.decode(result["source"].str);
        void differs(string what)
        {
            mismatches ~= origin ~ ": " ~ what ~ " differ for " ~ JSONValue(input).toString;
        }

        bool accepted = true;
        string[] kinds;
        JSONValue[] scalars;
        SdlScalarStorage storage;
        foreach (token; lexSDL!sdlDubCompat(input))
        {
            if (token.hasError)
            {
                accepted = false;
                break;
            }
            kinds ~= oracleKind(token.value.kind);
            if (token.value.kind >= SdlTokenKind.null_)
            {
                const decoded = decodeSdlScalar!sdlDubCompat(token.value, storage);
                if (decoded.hasError)
                {
                    accepted = false;
                    break;
                }
                scalars ~= normalizedScalar(decoded.value);
            }
        }
        if (accepted != result["accepted"].boolean)
            return differs("lexer outcomes");
        if (accepted)
        {
            string[] upstreamKinds;
            JSONValue[] upstreamScalars;
            foreach (token; result["tokens"].array)
            {
                upstreamKinds ~= token["kind"].str;
                if (token["kind"].str == "scalar")
                    upstreamScalars ~= token["value"];
            }
            if (kinds != upstreamKinds)
                return differs("token kinds");
            if (scalars != upstreamScalars)
                return differs("scalar payloads");
        }

        const parses = result["parses"].boolean;
        auto parsed = parseSdlDocument!sdlDubCompat(input);
        if (parsed.hasValue != parses)
            return differs("parser outcomes");
        auto recipe = parseSdlDocument!sdlDubRecipe(input);
        const recipeExpected = parses && recipeScalarsOnly(result["tree"]);
        if (recipe.hasValue != recipeExpected)
            return differs("recipe-profile outcomes");
        if (!parses)
            return;
        // The roots are synthetic on both sides; their names are not data.
        auto upstream = result["tree"];
        auto ours = normalizedTree(parsed.document.root);
        ours["name"] = upstream["name"];
        ours["namespace"] = upstream["namespace"];
        if (ours != upstream)
            return differs("parsed trees");
        if (recipeExpected)
        {
            auto recipeTree = normalizedTree(recipe.document.root);
            recipeTree["name"] = upstream["name"];
            recipeTree["namespace"] = upstream["namespace"];
            if (recipeTree != upstream)
                differs("recipe-profile trees");
        }
    }

    foreach (i, result; results["fixtures"].array)
        compare(result, "fixture " ~ fixtures[i]);
    foreach (result; corpus)
        compare(result, "dub " ~ result["origin"].str);
    import std.array : join;
    import std.conv : text;

    assert(!mismatches.length, text(mismatches.length, " of ",
        fixtures.length + corpus.length, " inputs differ from DUB:\n",
        mismatches.join("\n")));
}
