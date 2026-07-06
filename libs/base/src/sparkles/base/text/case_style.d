/**
Identifier case conversion.

This module renames a single identifier from one convention (e.g. `fastPath`)
into another (`fast_path`, `FAST_PATH`, `FastPath`, …). It is a format-agnostic
text primitive with no serialization or UDA concerns — callers pass a string of
characters and get the recased text back.

$(UL
    $(LI $(LREF writeConvertedCase) — the primitive: recase into an output range,
        allocating nothing (`@nogc`-friendly).)
    $(LI $(LREF convertCase) — the allocating convenience wrapper that returns a
        fresh `string`, and is usable during CTFE.)
)

The normative behavior — word boundaries, per-style rejoining, and the CTFE
contract — is specified in `docs/specs/base/text/case-style.md`.
*/
module sparkles.base.text.case_style;

import std.range.primitives : ElementType, isForwardRange, isOutputRange, put;
import std.traits : isSomeChar;

/// The set of case styles $(LREF convertCase) can rejoin an identifier into.
enum CaseStyle
{
    original,           /// return the identifier unchanged (no split/rejoin)
    camelCase,          /// `fromXmlToJson` — lowercase first word, title-case the rest
    pascalCase,         /// `FromXmlToJson` — title-case every word
    snakeCase,          /// `from_xml_to_json` — lowercase words joined with `_`
    kebabCase,          /// `from-xml-to-json` — lowercase words joined with `-`
    screamingSnakeCase, /// `FROM_XML_TO_JSON` — uppercase words joined with `_`
}

/**
Recases `ident` into the output range `w` under `style`, allocating nothing of
its own — the primitive underlying $(LREF convertCase).

The identifier is split into words at (1) a lowercase/digit immediately followed
by an uppercase, (2) an uppercase that begins a new word after an acronym run (an
uppercase followed by an uppercase-then-lowercase, so `JSONValue` → `JSON`,
`Value`), and (3) an explicit `_`, `-`, or space separator (consumed). The words
are then rejoined per `style`. `CaseStyle.original` copies `ident` verbatim.

`style` is a template parameter so the whole call is a compile-time constant
branch and can run during CTFE.
*/
void writeConvertedCase(CaseStyle style, Writer, R)(ref Writer w, R ident)
if (isOutputRange!(Writer, char) && isForwardRange!R && isSomeChar!(ElementType!R))
{
    import std.ascii : isDigit, isLower, isUpper, toLower, toUpper;
    import std.utf : byCodeUnit;

    static if (style == CaseStyle.original)
    {
        for (auto r = ident.byCodeUnit; !r.empty; r.popFront())
            put(w, r.front);
    }
    else
    {
        enum bool hasJoin = style == CaseStyle.snakeCase
            || style == CaseStyle.kebabCase
            || style == CaseStyle.screamingSnakeCase;
        enum char joinCh = style == CaseStyle.kebabCase ? '-' : '_';

        bool atWordStart = true;
        size_t wordNumber = 0;
        bool emittedAny = false;
        char prev = 0;

        for (auto r = ident.byCodeUnit; !r.empty; r.popFront())
        {
            const char c = r.front;

            if (c == '_' || c == '-' || c == ' ')
            {
                atWordStart = true;
                prev = c;
                continue;
            }

            if (!atWordStart && c.isUpper)
            {
                auto rn = r.save;
                rn.popFront();
                const bool nextLower = !rn.empty && rn.front.isLower;
                const bool boundary = prev.isLower || prev.isDigit
                    || (prev.isUpper && nextLower);
                if (boundary)
                    atWordStart = true;
            }

            if (atWordStart)
            {
                if (emittedAny && hasJoin)
                    put(w, joinCh);

                static if (style == CaseStyle.snakeCase || style == CaseStyle.kebabCase)
                    put(w, cast(char) c.toLower);
                else static if (style == CaseStyle.screamingSnakeCase
                    || style == CaseStyle.pascalCase)
                    put(w, cast(char) c.toUpper);
                else // camelCase: lowercase the leading word, title-case the rest
                    put(w, cast(char)(wordNumber == 0 ? c.toLower : c.toUpper));

                atWordStart = false;
                emittedAny = true;
                wordNumber++;
            }
            else
            {
                static if (style == CaseStyle.screamingSnakeCase)
                    put(w, cast(char) c.toUpper);
                else
                    put(w, cast(char) c.toLower);
            }

            prev = c;
        }
    }
}

/**
Recases `ident` under `style`, returning a fresh `string`. For
`CaseStyle.original` it returns `ident` unchanged; otherwise it builds the
result via $(LREF writeConvertedCase) at run time, and via an index-loop mirror
of the same split/rejoin rules during CTFE — the interpreter pays heavily for
the range and output-range machinery, and compile-time name derivation (e.g.
the `sparkles:wired` policy tables) calls this in every consumer build. The
`case_style.convertCase.ctfeMatchesRuntime` test locks the two paths together.
*/
string convertCase(CaseStyle style)(string ident)
{
    static if (style == CaseStyle.original)
    {
        return ident;
    }
    else
    {
        if (__ctfe)
        {
            import std.ascii : isDigit, isLower, isUpper, toLower, toUpper;

            enum bool hasJoin = style == CaseStyle.snakeCase
                || style == CaseStyle.kebabCase
                || style == CaseStyle.screamingSnakeCase;
            enum char joinCh = style == CaseStyle.kebabCase ? '-' : '_';

            string s;
            bool atWordStart = true;
            size_t wordNumber = 0;
            char prev = 0;

            foreach (i, c; ident)
            {
                if (c == '_' || c == '-' || c == ' ')
                {
                    atWordStart = true;
                    prev = c;
                    continue;
                }

                if (!atWordStart && c.isUpper)
                {
                    const bool nextLower = i + 1 < ident.length && ident[i + 1].isLower;
                    if (prev.isLower || prev.isDigit || (prev.isUpper && nextLower))
                        atWordStart = true;
                }

                if (atWordStart)
                {
                    if (s.length && hasJoin)
                        s ~= joinCh;

                    static if (style == CaseStyle.snakeCase || style == CaseStyle.kebabCase)
                        s ~= cast(char) c.toLower;
                    else static if (style == CaseStyle.screamingSnakeCase
                        || style == CaseStyle.pascalCase)
                        s ~= cast(char) c.toUpper;
                    else // camelCase: lowercase the leading word, title-case the rest
                        s ~= cast(char)(wordNumber == 0 ? c.toLower : c.toUpper);

                    atWordStart = false;
                    wordNumber++;
                }
                else
                {
                    static if (style == CaseStyle.screamingSnakeCase)
                        s ~= cast(char) c.toUpper;
                    else
                        s ~= cast(char) c.toLower;
                }

                prev = c;
            }
            return s;
        }

        version (D_BetterC)
        {
            // Under `-betterC` — the runner's `@betterC` extraction imports
            // modules (e.g. `sparkles.base.text.readers`) that reach this via a
            // CTFE `enum`, so the `if (__ctfe)` branch above always returns here.
            // The runtime writer path depends on `std.utf.byCodeUnit`, which is
            // not instantiable for a narrow `string` in a `-betterC` build, so it
            // is elided; a runtime call would be a bug.
            assert(0, "convertCase has no runtime path under -betterC (CTFE only)");
        }
        else
        {
            static struct StringSink
            {
                string s;
                void put(char c) { s ~= c; }
            }

            StringSink sink;
            writeConvertedCase!style(sink, ident);
            return sink.s;
        }
    }
}

// The CTFE fast path and the writer-based runtime path must agree, style by
// style, over the conformance corpus (acronyms, digits, separators, edges).
@("case_style.convertCase.ctfeMatchesRuntime")
@safe pure unittest
{
    static immutable inputs = ["fromXMLToJSON", "JSONValue", "fastPath",
        "html5Parser", "version2", "already_snake", "kebab-input", "Mixed_Sep hi",
        "A", "ab", "", "x Y z"];

    static foreach (m; __traits(allMembers, CaseStyle))
        static foreach (i; 0 .. inputs.length)
        {{
            enum ctfeResult =
                convertCase!(__traits(getMember, CaseStyle, m))(inputs[i]);
            assert(convertCase!(__traits(getMember, CaseStyle, m))(inputs[i])
                == ctfeResult);
        }}
}

// CTFE conformance (case-style spec §4/§5): every style, plus acronym, digit,
// and explicit-separator cases. `static assert` forces compile-time evaluation.
static assert(convertCase!(CaseStyle.original)("fromXMLToJSON") == "fromXMLToJSON");
static assert(convertCase!(CaseStyle.camelCase)("fromXMLToJSON") == "fromXmlToJson");
static assert(convertCase!(CaseStyle.pascalCase)("fromXMLToJSON") == "FromXmlToJson");
static assert(convertCase!(CaseStyle.snakeCase)("fromXMLToJSON") == "from_xml_to_json");
static assert(convertCase!(CaseStyle.kebabCase)("fromXMLToJSON") == "from-xml-to-json");
static assert(convertCase!(CaseStyle.screamingSnakeCase)("fromXMLToJSON") == "FROM_XML_TO_JSON");

static assert(convertCase!(CaseStyle.snakeCase)("JSONValue") == "json_value");
static assert(convertCase!(CaseStyle.pascalCase)("JSONValue") == "JsonValue");
static assert(convertCase!(CaseStyle.camelCase)("JSONValue") == "jsonValue");

static assert(convertCase!(CaseStyle.snakeCase)("fastPath") == "fast_path");
static assert(convertCase!(CaseStyle.kebabCase)("fastPath") == "fast-path");
static assert(convertCase!(CaseStyle.pascalCase)("fastPath") == "FastPath");

// digit boundaries: a digit→upper transition splits; letter→digit does not.
static assert(convertCase!(CaseStyle.snakeCase)("html5Parser") == "html5_parser");
static assert(convertCase!(CaseStyle.screamingSnakeCase)("html5Parser") == "HTML5_PARSER");
static assert(convertCase!(CaseStyle.snakeCase)("version2") == "version2");

// explicit separators round-trip through the word splitter.
static assert(convertCase!(CaseStyle.snakeCase)("fast_path") == "fast_path");
static assert(convertCase!(CaseStyle.snakeCase)("fast-path") == "fast_path");
static assert(convertCase!(CaseStyle.snakeCase)("fast path") == "fast_path");
static assert(convertCase!(CaseStyle.pascalCase)("fast_path") == "FastPath");
static assert(convertCase!(CaseStyle.camelCase)("fast-path") == "fastPath");

// original is verbatim.
static assert(convertCase!(CaseStyle.original)("already_snake") == "already_snake");

@("text.case_style.convertCase.everyStyle")
@safe pure unittest
{
    assert(convertCase!(CaseStyle.original)("fromXMLToJSON") == "fromXMLToJSON");
    assert(convertCase!(CaseStyle.camelCase)("fromXMLToJSON") == "fromXmlToJson");
    assert(convertCase!(CaseStyle.pascalCase)("fromXMLToJSON") == "FromXmlToJson");
    assert(convertCase!(CaseStyle.snakeCase)("fromXMLToJSON") == "from_xml_to_json");
    assert(convertCase!(CaseStyle.kebabCase)("fromXMLToJSON") == "from-xml-to-json");
    assert(convertCase!(CaseStyle.screamingSnakeCase)("fromXMLToJSON") == "FROM_XML_TO_JSON");
}

@("text.case_style.convertCase.acronymAndDigit")
@safe pure unittest
{
    assert(convertCase!(CaseStyle.snakeCase)("JSONValue") == "json_value");
    assert(convertCase!(CaseStyle.pascalCase)("parsedJSON") == "ParsedJson");
    assert(convertCase!(CaseStyle.snakeCase)("html5Parser") == "html5_parser");
    assert(convertCase!(CaseStyle.snakeCase)("version2") == "version2");
}

@("text.case_style.writeConvertedCase.nogcIntoSmallBuffer")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    writeConvertedCase!(CaseStyle.snakeCase)(buf, "fromXMLToJSON");
    buf ~= ' ';
    writeConvertedCase!(CaseStyle.pascalCase)(buf, "parsedJSON");
    assert(buf[] == "from_xml_to_json ParsedJson");
}

@("text.case_style.writeConvertedCase.matchesConvertCase")
@safe pure unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    static foreach (style; [
        CaseStyle.original, CaseStyle.camelCase, CaseStyle.pascalCase,
        CaseStyle.snakeCase, CaseStyle.kebabCase, CaseStyle.screamingSnakeCase])
        static foreach (id; ["fromXMLToJSON", "JSONValue", "fastPath", "html5Parser"])
        {{
            SmallBuffer!(char, 64) buf;
            writeConvertedCase!style(buf, id);
            assert(buf[] == convertCase!style(id));
        }}
}

@("text.case_style.writeConvertedCase.constCharSlice")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    const(char)[] id = "fromXMLToJSON";
    SmallBuffer!(char, 64) buf;
    writeConvertedCase!(CaseStyle.kebabCase)(buf, id);
    assert(buf[] == "from-xml-to-json");
}
