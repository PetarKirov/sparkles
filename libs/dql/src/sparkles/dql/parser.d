module sparkles.dql.parser;

import std.algorithm.comparison : among;
import std.regex : regex;
import std.string : strip;
import std.sumtype : match;

import expected : Expected, err, ok;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.float_conv : readDecimalFloat;
import sparkles.base.text.readers : isHexDigit, readQuotedString, skipSpaces;
import sparkles.base.text.span : TextSpan;
import sparkles.dql.ast;
import sparkles.dql.engine : DqlEngine, DqlParseError;
import sparkles.fuzzy.common : PathFlavor;
import sparkles.fuzzy.glob : compileGlob, GlobProgram;
import sparkles.fuzzy.query : parseQuery, QueryStorage;

@safe:

/// Token kinds produced by DQL lexer.
enum DqlTokenKind : ubyte
{
    eof,
    identifier,
    stringLiteral,
    numberLiteral,
    boolLiteral,
    nullLiteral,
    opEq,         // ==
    opNeq,        // !=
    opLt,         // <
    opLte,        // <=
    opGt,         // >
    opGte,        // >=
    kwAnd,        // &&
    kwOr,         // || or ,
    kwNot,        // ! or -
    lParen,       // (
    rParen,       // )
    comma,        // ,
    fnRegexMatch, // regexMatch
    fnGlobMatch,  // globMatch
    fnFuzzyMatch, // fuzzyMatch
}

/// Token with byte span and typed payload.
struct DqlToken
{
    DqlTokenKind kind;
    TextSpan text;
    double numberValue = 0.0;
    bool boolValue = false;
    TextSpan span;
}

/// Tokenizer for DQL expressions.
struct DqlLexer
{
    const(char)[] source;
    size_t cursor;
    UniqueBuffer!(char, 64) unescapeBuffer;

    @safe:

    bool empty() const pure nothrow @nogc => cursor >= source.length;

    void skipWs() pure nothrow @nogc
    {
        while (cursor < source.length && source[cursor].among!(' ', '\t', '\r', '\n'))
            cursor++;
    }

    Expected!(DqlToken, DqlParseError) nextToken(ref DqlEngine engine)
    {
        skipWs();
        if (empty)
            return ok!DqlParseError(DqlToken(DqlTokenKind.eof, engine.intern(""), 0, false, TextSpan.of(cast(uint) cursor, cast(uint) cursor)));

        const size_t start = cursor;
        const char c = source[cursor];

        // 1. Quoted string literals
        if (c == '"' || c == '\'' || c == '`')
        {
            unescapeBuffer.length = 0;
            const size_t beforeLen = source.length - cursor;
            auto rest = source[cursor .. $];
            auto readRes = readQuotedString(rest, unescapeBuffer);
            if (!readRes.hasValue)
            {
                return err!DqlToken(DqlParseError(
                    "unterminated or invalid string literal",
                    start,
                    cursor + 1 - start
                ));
            }
            const size_t consumed = beforeLen - rest.length;
            cursor += consumed;
            auto interned = engine.intern(unescapeBuffer[]);
            return ok!DqlParseError(DqlToken(
                DqlTokenKind.stringLiteral,
                interned,
                0,
                false,
                TextSpan.of(cast(uint) start, cast(uint) cursor)
            ));
        }

        // 2. Operators & punctuation
        if (cursor + 1 < source.length)
        {
            const s2 = source[cursor .. cursor + 2];
            if (s2 == "==") { cursor += 2; return ok!DqlParseError(DqlToken(DqlTokenKind.opEq, engine.intern("=="), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
            if (s2 == "!=") { cursor += 2; return ok!DqlParseError(DqlToken(DqlTokenKind.opNeq, engine.intern("!="), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
            if (s2 == "<=") { cursor += 2; return ok!DqlParseError(DqlToken(DqlTokenKind.opLte, engine.intern("<="), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
            if (s2 == ">=") { cursor += 2; return ok!DqlParseError(DqlToken(DqlTokenKind.opGte, engine.intern(">="), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
            if (s2 == "&&") { cursor += 2; return ok!DqlParseError(DqlToken(DqlTokenKind.kwAnd, engine.intern("&&"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
            if (s2 == "||") { cursor += 2; return ok!DqlParseError(DqlToken(DqlTokenKind.kwOr, engine.intern("||"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
        }

        if (c == '<') { cursor++; return ok!DqlParseError(DqlToken(DqlTokenKind.opLt, engine.intern("<"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
        if (c == '>') { cursor++; return ok!DqlParseError(DqlToken(DqlTokenKind.opGt, engine.intern(">"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
        if (c == '!' || c == '-') { cursor++; return ok!DqlParseError(DqlToken(DqlTokenKind.kwNot, engine.intern("!"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
        if (c == ',') { cursor++; return ok!DqlParseError(DqlToken(DqlTokenKind.kwOr, engine.intern(","), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
        if (c == '(') { cursor++; return ok!DqlParseError(DqlToken(DqlTokenKind.lParen, engine.intern("("), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }
        if (c == ')') { cursor++; return ok!DqlParseError(DqlToken(DqlTokenKind.rParen, engine.intern(")"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor))); }

        // 3. Numbers
        if (c >= '0' && c <= '9')
        {
            const(char)[] numRest = source[cursor .. $];
            auto floatRes = readDecimalFloat(numRest);
            if (floatRes.hasValue)
            {
                const size_t consumed = source.length - cursor - numRest.length;
                cursor += consumed;
                return ok!DqlParseError(DqlToken(
                    DqlTokenKind.numberLiteral,
                    engine.intern(source[start .. cursor]),
                    floatRes.value,
                    false,
                    TextSpan.of(cast(uint) start, cast(uint) cursor)
                ));
            }
        }

        // 4. Identifiers, keywords, booleans, function names
        size_t idEnd = cursor;
        while (idEnd < source.length)
        {
            const ch = source[idEnd];
            if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' ||
                ch == '(' || ch == ')' || ch == ',' || ch == '=' || ch == '!' ||
                ch == '<' || ch == '>' || ch == '&' || ch == '|' || ch == '"' ||
                ch == '\'' || ch == '`')
                break;
            idEnd++;
        }

        const idSlice = source[cursor .. idEnd];
        cursor = idEnd;

        if (idSlice == "true")
            return ok!DqlParseError(DqlToken(DqlTokenKind.boolLiteral, engine.intern("true"), 1.0, true, TextSpan.of(cast(uint) start, cast(uint) cursor)));
        if (idSlice == "false")
            return ok!DqlParseError(DqlToken(DqlTokenKind.boolLiteral, engine.intern("false"), 0.0, false, TextSpan.of(cast(uint) start, cast(uint) cursor)));
        if (idSlice == "null")
            return ok!DqlParseError(DqlToken(DqlTokenKind.nullLiteral, engine.intern("null"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor)));
        if (idSlice == "regexMatch")
            return ok!DqlParseError(DqlToken(DqlTokenKind.fnRegexMatch, engine.intern("regexMatch"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor)));
        if (idSlice == "globMatch")
            return ok!DqlParseError(DqlToken(DqlTokenKind.fnGlobMatch, engine.intern("globMatch"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor)));
        if (idSlice == "fuzzyMatch")
            return ok!DqlParseError(DqlToken(DqlTokenKind.fnFuzzyMatch, engine.intern("fuzzyMatch"), 0, false, TextSpan.of(cast(uint) start, cast(uint) cursor)));

        return ok!DqlParseError(DqlToken(
            DqlTokenKind.identifier,
            engine.intern(idSlice),
            0,
            false,
            TextSpan.of(cast(uint) start, cast(uint) cursor)
        ));
    }
}

/// Recursive Pratt parser with binding-power operator precedence.
struct DqlParser
{
    DqlEngine* engine;
    DqlLexer lexer;
    DqlToken currentToken;
    DqlFilter filter;

    @safe:

    this(ref DqlEngine eng, scope const(char)[] source) @trusted
    {
        engine = &eng;
        lexer = DqlLexer(source, 0);
    }

    Expected!(DqlFilter, DqlParseError) parseFilter()
    {
        auto t = lexer.nextToken(*engine);
        if (!t.hasValue)
            return err!DqlFilter(t.error);
        currentToken = t.value;

        if (currentToken.kind == DqlTokenKind.eof)
            return ok!DqlParseError(DqlFilter.init);

        auto rootRes = parseExpression(0);
        if (!rootRes.hasValue)
            return err!DqlFilter(rootRes.error);

        if (currentToken.kind != DqlTokenKind.eof)
            return err!DqlFilter(DqlParseError("unexpected trailing token", currentToken.span.startOffset, currentToken.span.length));

        filter.rootIndex = rootRes.value;
        return ok!DqlParseError(filter);
    }

    Expected!(uint, DqlParseError) parseExpression(ubyte minBindingPower)
    {
        auto leftRes = parsePrefix();
        if (!leftRes.hasValue)
            return leftRes;

        uint leftIndex = leftRes.value;

        while (currentToken.kind != DqlTokenKind.eof)
        {
            const binding = infixBindingPower(currentToken.kind);
            if (binding[0] < minBindingPower)
                break;

            const opKind = currentToken.kind;
            const opSpan = currentToken.span;

            auto nextT = lexer.nextToken(*engine);
            if (!nextT.hasValue)
                return err!uint(nextT.error);
            currentToken = nextT.value;

            auto rightRes = parseExpression(binding[1]);
            if (!rightRes.hasValue)
                return rightRes;

            const uint rightIndex = rightRes.value;
            const nodeKind = (opKind == DqlTokenKind.kwAnd) ? DqlNodeKind.and_ : DqlNodeKind.or_;
            const span = TextSpan.of(filter.nodes[leftIndex].span.startOffset, filter.nodes[rightIndex].span.endOffset);

            uint nodeIdx = cast(uint) filter.nodes.length;
            filter.nodes ~= DqlAstNode(nodeKind, BinaryPayload(leftIndex, rightIndex), span);
            leftIndex = nodeIdx;
        }

        return ok!DqlParseError(leftIndex);
    }

    private Expected!(uint, DqlParseError) parsePrefix()
    {
        const token = currentToken;

        // Unary NOT: ! or -
        if (token.kind == DqlTokenKind.kwNot)
        {
            auto nextT = lexer.nextToken(*engine);
            if (!nextT.hasValue)
                return err!uint(nextT.error);
            currentToken = nextT.value;

            auto childRes = parseExpression(30); // Prefix binding power
            if (!childRes.hasValue)
                return childRes;

            const uint childIdx = childRes.value;
            const span = TextSpan.of(token.span.startOffset, filter.nodes[childIdx].span.endOffset);

            uint nodeIdx = cast(uint) filter.nodes.length;
            filter.nodes ~= DqlAstNode(DqlNodeKind.not_, UnaryPayload(childIdx), span);
            return ok!DqlParseError(nodeIdx);
        }

        // Grouping: (...)
        if (token.kind == DqlTokenKind.lParen)
        {
            auto nextT = lexer.nextToken(*engine);
            if (!nextT.hasValue)
                return err!uint(nextT.error);
            currentToken = nextT.value;

            auto innerRes = parseExpression(0);
            if (!innerRes.hasValue)
                return innerRes;

            if (currentToken.kind != DqlTokenKind.rParen)
                return err!uint(DqlParseError("expected ')'", currentToken.span.startOffset, currentToken.span.length));

            const endSpan = currentToken.span;
            auto nextT2 = lexer.nextToken(*engine);
            if (!nextT2.hasValue)
                return err!uint(nextT2.error);
            currentToken = nextT2.value;

            return innerRes;
        }

        // Functions: regexMatch(path, pattern), globMatch(path, pattern), fuzzyMatch(path, query)
        if (token.kind == DqlTokenKind.fnRegexMatch || token.kind == DqlTokenKind.fnGlobMatch || token.kind == DqlTokenKind.fnFuzzyMatch)
            return parseFunctionCall(token.kind, token.span);

        // Identifier or Comparison: path == val, or category token
        if (token.kind == DqlTokenKind.identifier)
        {
            auto nextT = lexer.nextToken(*engine);
            if (!nextT.hasValue)
                return err!uint(nextT.error);
            currentToken = nextT.value;

            // Check if comparison operator follows
            if (isComparisonOp(currentToken.kind))
            {
                const cmpToken = currentToken;
                const op = tokenToOp(cmpToken.kind);

                auto valT = lexer.nextToken(*engine);
                if (!valT.hasValue)
                    return err!uint(valT.error);
                currentToken = valT.value;

                filter.hasFineGrainedPredicates = true;
                const valToken = currentToken;

                auto advanceT = lexer.nextToken(*engine);
                if (!advanceT.hasValue)
                    return err!uint(advanceT.error);
                currentToken = advanceT.value;

                if (valToken.kind == DqlTokenKind.nullLiteral)
                {
                    const span = TextSpan.of(token.span.startOffset, valToken.span.endOffset);
                    uint nodeIdx = cast(uint) filter.nodes.length;
                    filter.nodes ~= DqlAstNode(DqlNodeKind.nullCheck, NullCheckPayload(token.text, op == DqlOp.eq), span);
                    return ok!DqlParseError(nodeIdx);
                }

                DqlValue dqlVal;
                if (valToken.kind == DqlTokenKind.numberLiteral)
                    dqlVal = DqlValue(valToken.numberValue);
                else if (valToken.kind == DqlTokenKind.boolLiteral)
                    dqlVal = DqlValue(valToken.boolValue);
                else if (valToken.kind == DqlTokenKind.stringLiteral || valToken.kind == DqlTokenKind.identifier)
                    dqlVal = DqlValue(valToken.text);
                else
                    return err!uint(DqlParseError("expected comparison target value", valToken.span.startOffset, valToken.span.length));

                const span = TextSpan.of(token.span.startOffset, valToken.span.endOffset);
                uint nodeIdx = cast(uint) filter.nodes.length;
                filter.nodes ~= DqlAstNode(DqlNodeKind.compare, ComparePayload(token.text, op, dqlVal), span);
                return ok!DqlParseError(nodeIdx);
            }

            // Bare identifier is an event category token
            uint nodeIdx = cast(uint) filter.nodes.length;
            filter.nodes ~= DqlAstNode(DqlNodeKind.category, CategoryPayload(token.text), token.span);
            return ok!DqlParseError(nodeIdx);
        }

        return err!uint(DqlParseError("unexpected token in filter expression", token.span.startOffset, token.span.length));
    }

    private Expected!(uint, DqlParseError) parseFunctionCall(DqlTokenKind fnKind, TextSpan fnSpan)
    {
        auto pT = lexer.nextToken(*engine);
        if (!pT.hasValue) return err!uint(pT.error);
        currentToken = pT.value;

        if (currentToken.kind != DqlTokenKind.lParen)
            return err!uint(DqlParseError("expected '(' after function name", currentToken.span.startOffset, currentToken.span.length));

        // Argument 1: path (identifier or string)
        auto pathT = lexer.nextToken(*engine);
        if (!pathT.hasValue) return err!uint(pathT.error);
        currentToken = pathT.value;

        if (currentToken.kind != DqlTokenKind.identifier && currentToken.kind != DqlTokenKind.stringLiteral)
            return err!uint(DqlParseError("expected path argument in function call", currentToken.span.startOffset, currentToken.span.length));

        const path = currentToken.text;

        // Comma
        auto commaT = lexer.nextToken(*engine);
        if (!commaT.hasValue) return err!uint(commaT.error);
        currentToken = commaT.value;

        if (currentToken.kind != DqlTokenKind.comma && currentToken.kind != DqlTokenKind.kwOr)
            return err!uint(DqlParseError("expected ',' in function argument list", currentToken.span.startOffset, currentToken.span.length));

        // Argument 2: pattern or query string
        auto patT = lexer.nextToken(*engine);
        if (!patT.hasValue) return err!uint(patT.error);
        currentToken = patT.value;

        if (currentToken.kind != DqlTokenKind.stringLiteral && currentToken.kind != DqlTokenKind.identifier)
            return err!uint(DqlParseError("expected pattern/query argument in function call", currentToken.span.startOffset, currentToken.span.length));

        const pattern = currentToken.text;
        const patSlice = engine.textOf(pattern);

        // Closing paren
        auto closeT = lexer.nextToken(*engine);
        if (!closeT.hasValue) return err!uint(closeT.error);
        currentToken = closeT.value;

        if (currentToken.kind != DqlTokenKind.rParen)
            return err!uint(DqlParseError("expected ')' after function arguments", currentToken.span.startOffset, currentToken.span.length));

        const endSpan = currentToken.span;
        auto advanceT = lexer.nextToken(*engine);
        if (!advanceT.hasValue) return err!uint(advanceT.error);
        currentToken = advanceT.value;

        filter.hasFineGrainedPredicates = true;
        const span = TextSpan.of(fnSpan.startOffset, endSpan.endOffset);
        uint nodeIdx = cast(uint) filter.nodes.length;

        if (fnKind == DqlTokenKind.fnRegexMatch)
        {
            try
            {
                auto re = regex(patSlice);
                const uint rIdx = engine.registerRegex(RegexHolder(re));
                filter.nodes ~= DqlAstNode(DqlNodeKind.regex, RegexPayload(path, rIdx), span);
            }
            catch (Exception e)
            {
                return err!uint(DqlParseError("invalid regular expression: " ~ e.msg, fnSpan.startOffset, fnSpan.length));
            }
        }
        else if (fnKind == DqlTokenKind.fnGlobMatch)
        {
            GlobProgram!() prog;
            auto compileRes = compileGlob(patSlice, PathFlavor.unix, false, prog);
            if (compileRes.hasError)
                return err!uint(DqlParseError("invalid glob pattern: " ~ compileRes.error.context, fnSpan.startOffset, fnSpan.length));
            const uint gIdx = engine.registerGlob(prog);
            filter.nodes ~= DqlAstNode(DqlNodeKind.glob, GlobPayload(path, gIdx), span);
        }
        else if (fnKind == DqlTokenKind.fnFuzzyMatch)
        {
            auto qRes = parseQuery(patSlice);
            if (!qRes.hasValue)
                return err!uint(DqlParseError("invalid fuzzy query", fnSpan.startOffset, fnSpan.length));
            const uint fIdx = engine.registerFuzzy(qRes.value);
            filter.nodes ~= DqlAstNode(DqlNodeKind.fuzzy, FuzzyPayload(path, fIdx), span);
        }

        return ok!DqlParseError(nodeIdx);
    }

    private static ubyte[2] infixBindingPower(DqlTokenKind kind) pure nothrow @nogc
    {
        switch (kind)
        {
            case DqlTokenKind.kwOr:
                return [10, 11]; // Left-associative OR
            case DqlTokenKind.kwAnd:
                return [20, 21]; // Left-associative AND
            default:
                return [0, 0];
        }
    }

    private static bool isComparisonOp(DqlTokenKind kind) pure nothrow @nogc
    {
        return kind == DqlTokenKind.opEq || kind == DqlTokenKind.opNeq
            || kind == DqlTokenKind.opLt || kind == DqlTokenKind.opLte
            || kind == DqlTokenKind.opGt || kind == DqlTokenKind.opGte;
    }

    private static DqlOp tokenToOp(DqlTokenKind kind) pure nothrow @nogc
    {
        switch (kind)
        {
            case DqlTokenKind.opEq:  return DqlOp.eq;
            case DqlTokenKind.opNeq: return DqlOp.neq;
            case DqlTokenKind.opLt:  return DqlOp.lt;
            case DqlTokenKind.opLte: return DqlOp.lte;
            case DqlTokenKind.opGt:  return DqlOp.gt;
            case DqlTokenKind.opGte: return DqlOp.gte;
            default:                 return DqlOp.eq;
        }
    }
}

/// Parses a DQL filter expression using `engine`.
Expected!(DqlFilter, DqlParseError) parseDql(ref DqlEngine engine, scope const(char)[] expr)
{
    const(char)[] s = expr.strip;
    if (s.length == 0)
        return ok!DqlParseError(DqlFilter.init);

    DqlParser parser = DqlParser(engine, s);
    return parser.parseFilter();
}

/// Convenience overload using a local engine.
Expected!(DqlFilter, DqlParseError) parseDql(scope const(char)[] expr)
{
    DqlEngine engine;
    return parseDql(engine, expr);
}

@("dql.parser: parse expressions, operators, and functions")
unittest
{
    DqlEngine engine;
    auto res1 = parseDql(engine, "!motion && !scroll");
    assert(!res1.hasError);
    assert(res1.value.nodes[res1.value.rootIndex].kind == DqlNodeKind.and_);

    auto res2 = parseDql(engine, "pointer.phase == pressed && pointer.button == left");
    assert(!res2.hasError);
    assert(res2.value.nodes[res2.value.rootIndex].kind == DqlNodeKind.and_);

    auto res3 = parseDql(engine, "pointer.logicalPosition.x > 400 || modifiers.ctrl == true");
    assert(!res3.hasError);
    assert(res3.value.nodes[res3.value.rootIndex].kind == DqlNodeKind.or_);

    auto res4 = parseDql(engine, "regexMatch(text.text, `^[0-9]+$`)");
    assert(!res4.hasError);
    assert(res4.value.nodes[res4.value.rootIndex].kind == DqlNodeKind.regex);

    auto res5 = parseDql(engine, "globMatch(path, `*.png`)");
    assert(!res5.hasError);
    assert(res5.value.nodes[res5.value.rootIndex].kind == DqlNodeKind.glob);

    auto res6 = parseDql(engine, "fuzzyMatch(title, `wsi echo`)");
    assert(!res6.hasError);
    assert(res6.value.nodes[res6.value.rootIndex].kind == DqlNodeKind.fuzzy);

    auto res7 = parseDql(engine, "text.text != null");
    assert(!res7.hasError);
    assert(res7.value.nodes[res7.value.rootIndex].kind == DqlNodeKind.nullCheck);

    // Test commas inside quoted regex / glob
    auto res8 = parseDql(engine, `regexMatch(text.text, "^[a,b]+$")`);
    assert(!res8.hasError);
}
