/**
D source text as DMD's lexer reads it, in a form the scans can walk
without DMD's types.

The scans need a file's structure, never its meaning, but they must see
the tokens the compiler sees: every string form, nested comments, `__EOF__`,
a shebang line, `#line`. So the tokens come from DMD's own lexer
(`dmd:lexer`), reduced to a kind, a text and a line. Comments are dropped.

A keyword is an `identifier` token whose text is the keyword: the scans
match words, and D's keywords are words. A string literal's `value` is its
contents after escapes, as DMD decodes them; a token string's (`q{…}`) is its
text.

Lexing never fails. DMD's lexer reports an error to a sink this module
discards, and carries on; the compile of the same file reports it.
*/
module sparkles.d_source.tokens;

/// What a token is.
enum TokenKind : ubyte
{
    identifier, /// a name or a keyword
    string_,    /// a string literal of any form
    character,  /// a character literal
    number,     /// an integer or floating-point literal
    operator,   /// punctuation, one token per operator
    other,      /// anything else DMD returns (`#line` sequences are consumed)
}

/// One token.
struct Token
{
    TokenKind kind; ///
    /// An identifier's or keyword's name, or an operator's spelling; for a
    /// literal, its text in the source.
    const(char)[] text;
    /// A string literal's contents; otherwise the text.
    const(char)[] value;
    uint line; /// the 1-based line it starts on

    /// Whether this is the identifier, keyword or operator `s`.
    bool opEquals(scope const(char)[] s) const @safe pure nothrow @nogc
        => (kind == TokenKind.identifier || kind == TokenKind.operator) && text == s;
}

/// The tokens of `source`, up to its end or `__EOF__`.
Token[] tokenize(const(char)[] source) @trusted
{
    import sparkles.d_source.dmd_globals : withDmdGlobals;

    // DMD's lexer reads pointers into a buffer that ends in a 0 byte, and
    // holds the process-wide identifier table: both are its API, and the
    // copy and the lock make them safe here.
    Token[] tokens;
    withDmdGlobals(() { tokens = lexAll(source); });
    return tokens;
}

///
@("d_source.tokens.tokenize.basic")
@safe unittest
{
    const ts = tokenize("version (Foo) int x = 0x1F; // a comment\n");
    assert(ts.length == 9);
    assert(ts[0] == "version" && ts[2].kind == TokenKind.identifier && ts[2].text == "Foo");
    assert(ts[4] == "int" && ts[7].kind == TokenKind.number);
    assert(ts[8] == ";");
}

private Token[] lexAll(const(char)[] source) @system
{
    import dmd.errorsink : ErrorSinkNull;
    import dmd.lexer : Lexer;
    import dmd.tokens : TOK, DmdToken = Token;

    auto buf = new char[](source.length + 1);
    buf[0 .. source.length] = source[];
    buf[source.length] = '\0';
    const base = buf.ptr;

    scope sink = new ErrorSinkNull;
    scope lexer = new Lexer(null, base, 0, source.length,
        /*doDocComment*/ false, /*commentToken*/ false, /*whitespaceToken*/ false,
        sink);

    Token[] tokens;
    uint line = 1;
    size_t counted;
    for (TOK tok = lexer.nextToken(); tok != TOK.endOfFile; tok = lexer.nextToken())
    {
        const t = &lexer.token;
        const start = cast(size_t) (t.ptr - base);
        foreach (c; buf[counted .. start])
            if (c == '\n')
                ++line;
        counted = start;
        // `lexer.p` is past this token's last byte.
        const text = buf[start .. cast(size_t) (lexer.p - base)];

        Token out_;
        out_.line = line;
        switch (tok)
        {
            case TOK.identifier:
                out_.kind = TokenKind.identifier;
                out_.text = t.ident.toString();
                break;
            case TOK.string_:
            case TOK.hexadecimalString:
                out_.kind = TokenKind.string_;
                out_.text = text;
                out_.value = t.ustring[0 .. t.len].idup;
                break;
            case TOK.interpolated:
                out_.kind = TokenKind.string_;
                out_.text = text;
                break;
            case TOK.charLiteral:
            case TOK.wcharLiteral:
            case TOK.dcharLiteral:
                out_.kind = TokenKind.character;
                out_.text = text;
                break;
            case TOK.int32Literal: .. case TOK.imaginary80Literal:
                out_.kind = TokenKind.number;
                out_.text = text;
                break;
            default:
                const spelling = DmdToken.toString(tok);
                if (t.isKeyword())
                    out_.kind = TokenKind.identifier;
                else if (spelling.length)
                    out_.kind = TokenKind.operator;
                else
                    out_.kind = TokenKind.other;
                out_.text = spelling.length ? spelling : text;
                break;
        }
        if (out_.kind != TokenKind.string_)
            out_.value = out_.text;
        tokens ~= out_;
    }
    return tokens;
}

@("d_source.tokens.tokenize.commentsAndNesting")
@safe unittest
{
    const ts = tokenize("a /* version (X) */ b /+ c /+ version (Y) +/ d +/ e // f\ng");
    string[] texts;
    foreach (t; ts)
        texts ~= t.text.idup;
    assert(texts == ["a", "b", "e", "g"]);
    assert(ts[3].line == 2);
}

@("d_source.tokens.tokenize.stringForms")
@safe unittest
{
    const ts = tokenize(`"a\"b" r"c\" ` ~ "`d` q\"(e(f))\" q\"/g/\" q{ h(\"}\") } 'i' '\\'' \"j\"c");
    string[] values;
    foreach (t; ts)
        if (t.kind == TokenKind.string_)
            values ~= t.value.idup;
    assert(values == [`a"b`, `c\`, "d", "e(f)", "g", ` h("}") `, "j"]);
    assert(ts[6].kind == TokenKind.character && ts[7].kind == TokenKind.character);
}

@("d_source.tokens.tokenize.heredoc")
@safe unittest
{
    const ts = tokenize("q\"EOS\nversion (Z)\nEOS\" ;");
    assert(ts.length == 2);
    assert(ts[0].value == "version (Z)\n");
    assert(ts[1] == ";" && ts[1].line == 3);
}

@("d_source.tokens.tokenize.eofAndShebang")
@safe unittest
{
    const ts = tokenize("#!/usr/bin/env dub\nint a; __EOF__ version (X)");
    assert(ts.length == 3);
    assert(ts[0] == "int" && ts[0].line == 2);
}

@("d_source.tokens.tokenize.operators")
@safe unittest
{
    const ts = tokenize("a == b = c => d !is e .. f");
    assert(ts[1] == "==" && ts[3] == "=" && ts[5] == "=>" && ts[7] == "!" && ts[8] == "is");
    assert(ts[10] == "..");
}
