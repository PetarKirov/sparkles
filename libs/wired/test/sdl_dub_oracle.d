/** Original process boundary for the unmodified, pinned DUB SDL oracle.

No upstream implementation or unittest body is copied into this file. The
upstream corpus is read from the pinned checkout at compile time: every string
literal inside a `unittest` block of the listed modules becomes one input, and
the compiler, not this file, evaluates its escapes. */
module sdl_dub_oracle;

import core.time : Duration, seconds;
import std.base64 : Base64;
import std.conv : text, to;
import std.datetime : Date, DateTime, SysTime;
import std.file : readText;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.stdio : writeln;
import std.traits : Unqual;
import std.utf : toUTF8;

import dub.internal.sdlang.ast : Tag;
import dub.internal.sdlang.lexer : lexSource;
import dub.internal.dyaml.stdsumtype : match;
import dub.internal.sdlang.parser : parseSource;
import dub.internal.sdlang.token : DateTimeFrac, DateTimeFracUnknownZone, Value;

private JSONValue civil(Date date, int hour, int minute, int second, long fraction)
{
    return JSONValue([JSONValue(date.year), JSONValue(cast(int) date.month),
        JSONValue(date.day), JSONValue(hour), JSONValue(minute), JSONValue(second),
        JSONValue(fraction)]);
}

private JSONValue scalar(T)(T value)
{
    alias V = Unqual!T;
    JSONValue result = JSONValue.init;
    static if (is(V == typeof(null)))
        result = JSONValue(["type": JSONValue("null")]);
    else
    {
        string type = V.stringof;
        JSONValue payload;
        static if (is(V == bool) || is(V == string))
            payload = JSONValue(value);
        else static if (is(V == dchar) || is(V == int) || is(V == long))
            payload = JSONValue(cast(long) value);
        else static if (is(V == float) || is(V == double) || is(V == real))
            payload = JSONValue(format("%a", value));
        else static if (is(V == ubyte[]))
        {
            type = "binary";
            payload = JSONValue(Base64.encode(value));
        }
        else static if (is(V == Duration))
        {
            type = "duration";
            payload = JSONValue(value.total!"hnsecs");
        }
        else static if (is(V == Date))
        {
            type = "date";
            payload = JSONValue(text(value.year, "/", cast(int) value.month, "/", value.day));
        }
        else static if (is(V == DateTimeFrac))
        {
            // A negative clock keeps a negative fraction (`-34:65:77.123` is
            // second 43 less 0.123 s); borrow a second for the same instant.
            auto clock = value.dateTime;
            auto fraction = value.fracSecs.total!"hnsecs";
            if (fraction < 0)
            {
                clock -= seconds(1);
                fraction += seconds(1).total!"hnsecs";
            }
            type = "dateTime";
            payload = civil(clock.date, clock.hour, clock.minute, clock.second, fraction);
        }
        else static if (is(V == SysTime))
        {
            type = "zonedDateTime";
            const local = cast(DateTime) value;
            payload = civil(local.date, local.hour, local.minute, local.second,
                value.fracSecs.total!"hnsecs");
        }
        else static if (is(V == DateTimeFracUnknownZone))
        {
            type = "zonedDateTime";
            payload = civil(value.dateTime.date, value.dateTime.hour,
                value.dateTime.minute, value.dateTime.second, value.fracSecs.total!"hnsecs");
        }
        result = JSONValue(["type": JSONValue(type), "payload": payload]);
    }
    return result;
}

private JSONValue scalarOf(Value value) => value.match!(v => scalar(v));

// The parsed tree in source order: values, then attributes and child tags
// across every namespace.
private JSONValue tree(Tag tag)
{
    JSONValue[] values, attributes, tags;
    foreach (value; tag.values)
        values ~= scalarOf(value);
    foreach (attribute; tag.all.attributes)
        attributes ~= JSONValue(["namespace": JSONValue(attribute.namespace),
            "name": JSONValue(attribute.name), "value": scalarOf(attribute.value)]);
    foreach (child; tag.all.tags)
        tags ~= tree(child);
    return JSONValue(["namespace": JSONValue(tag.namespace), "name": JSONValue(tag.name),
        "values": JSONValue(values), "attributes": JSONValue(attributes),
        "tags": JSONValue(tags)]);
}

private JSONValue outcome(string source)
{
    JSONValue result = JSONValue(["source": JSONValue(Base64.encode(cast(const(ubyte)[]) source)),
        "accepted": JSONValue(false), "parses": JSONValue(false)]);
    try
    {
        JSONValue[] tokens;
        foreach (token; lexSource(source))
        {
            string kind;
            JSONValue value;
            if (token.matches!"Value")
            {
                kind = "scalar";
                value = scalarOf(token.value);
            }
            else if (token.matches!"Ident") kind = "identifier";
            else if (token.matches!"EOL") kind = "terminator";
            else if (token.matches!":") kind = ":";
            else if (token.matches!"=") kind = "=";
            else if (token.matches!"{") kind = "{";
            else if (token.matches!"}") kind = "}";
            else assert(false, "unexpected oracle token");
            tokens ~= JSONValue(["kind": JSONValue(kind), "value": value]);
        }
        result["accepted"] = JSONValue(true);
        result["tokens"] = JSONValue(tokens);
    }
    catch (Exception _) {}
    try
    {
        result["tree"] = tree(parseSource(source));
        result["parses"] = JSONValue(true);
    }
    catch (Exception _) {}
    return result;
}

// ── Upstream corpus extraction (compile time) ────────────────────────────────

private struct Literal
{
    string spelling;  // D source text of a literal or a literal-only `~` chain
    size_t line;
}

private bool isWordChar(char c) => c == '_' || (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');

// Skips one comment, string, or character literal at `at`; false if none.
private bool skipOpaque(string s, ref size_t at)
{
    if (s[at] == '/' && at + 1 < s.length)
    {
        if (s[at + 1] == '/')
        {
            while (at < s.length && s[at] != '\n') at++;
            return true;
        }
        if (s[at + 1] == '*' || s[at + 1] == '+')
        {
            const close = s[at + 1];
            size_t depth = 1;
            at += 2;
            while (at + 1 < s.length && depth)
            {
                if (close == '+' && s[at] == '/' && s[at + 1] == '+') { depth++; at += 2; }
                else if (s[at] == close && s[at + 1] == '/') { depth--; at += 2; }
                else at++;
            }
            return true;
        }
    }
    if (s[at] == '"')
    {
        at++;
        while (s[at] != '"') at += s[at] == '\\' ? 2 : 1;
        at++;
        if (at < s.length && (s[at] == 'c' || s[at] == 'w' || s[at] == 'd')) at++;
        return true;
    }
    if (s[at] == '`')
    {
        at++;
        while (s[at] != '`') at++;
        at++;
        return true;
    }
    if (s[at] == '\'')
    {
        at++;
        while (s[at] != '\'') at += s[at] == '\\' ? 2 : 1;
        at++;
        return true;
    }
    return false;
}

private void skipSpace(string s, ref size_t at)
{
    while (at < s.length)
    {
        if (s[at] == ' ' || s[at] == '\t' || s[at] == '\r' || s[at] == '\n') at++;
        else if (s[at] == '/' && at + 1 < s.length
            && (s[at + 1] == '/' || s[at + 1] == '*' || s[at + 1] == '+'))
            skipOpaque(s, at);
        else break;
    }
}

private bool startsLiteral(string s, size_t at) => s[at] == '"' || s[at] == '`';

private size_t lineAt(string s, size_t at)
{
    size_t line = 1;
    foreach (c; s[0 .. at]) line += c == '\n';
    return line;
}

// Every string literal inside a `unittest` block. A `~` chain made only of
// literals is one input; a chain with any other operand yields its pieces.
private Literal[] unittestLiterals(string s)
{
    Literal[] found;
    size_t at;
    while (at < s.length)
    {
        if (skipOpaque(s, at)) continue;
        if (s[at .. $].length >= 8 && s[at .. at + 8] == "unittest"
            && (at == 0 || !isWordChar(s[at - 1]))
            && (at + 8 == s.length || !isWordChar(s[at + 8])))
        {
            at += 8;
            skipSpace(s, at);
            if (s[at] != '{') continue;
            size_t depth;
            do
            {
                if (startsLiteral(s, at))
                {
                    const start = at;
                    string[] pieces;
                    bool literalOnly = true;
                    for (;;)
                    {
                        const pieceStart = at;
                        skipOpaque(s, at);
                        pieces ~= s[pieceStart .. at];
                        size_t next = at;
                        skipSpace(s, next);
                        if (next >= s.length || s[next] != '~') break;
                        next++;
                        skipSpace(s, next);
                        if (!startsLiteral(s, next))
                        {
                            literalOnly = false;
                            break;
                        }
                        at = next;
                    }
                    const line = lineAt(s, start);
                    if (literalOnly)
                    {
                        string chain;
                        foreach (i, piece; pieces)
                            chain ~= (i ? " ~ " : "") ~ piece;
                        found ~= Literal(chain, line);
                    }
                    else
                        foreach (piece; pieces)
                            found ~= Literal(piece, line);
                    continue;
                }
                if (skipOpaque(s, at)) continue;
                if (s[at] == '{') depth++;
                else if (s[at] == '}') depth--;
                at++;
            }
            while (depth && at < s.length);
            continue;
        }
        at++;
    }
    return found;
}

private struct CorpusEntry
{
    string origin;
    string source;
}

// Modules whose unittest blocks hold SDL inputs, by `-J` import name.
private enum corpusModules = ["lexer.d", "parser.d", "ast.d", "token.d", "sdl.d"];

private string asUtf8(S)(S text)
{
    static if (is(S : const(char)[]))
        return text;
    else
        return toUTF8(text);
}

private string corpusExpression()
{
    string expression = "[";
    static foreach (name; corpusModules)
        foreach (literal; unittestLiterals(import(name)))
            expression ~= "CorpusEntry(\"" ~ name ~ ":" ~ literal.line.to!string
                ~ "\", asUtf8(" ~ literal.spelling ~ ")),\n";
    return expression ~ "]";
}

private immutable CorpusEntry[] upstreamCorpus = mixin(corpusExpression());

void main(string[] args)
{
    // Upstream's optional sdlangUnittest mode does not compile at the pinned
    // revision (DateTimeFrac tests omit its required fraction argument), so
    // its inputs run here through the unmodified production implementation.
    if (args.length == 1)
        return;
    JSONValue[] fixtures;
    foreach (entry; parseJSON(readText(args[1])).array)
        fixtures ~= outcome(entry.str);
    JSONValue[] corpus;
    bool[string] seen;
    foreach (entry; upstreamCorpus)
    {
        if (entry.source in seen)
            continue;
        seen[entry.source] = true;
        auto result = outcome(entry.source);
        result["origin"] = JSONValue(entry.origin);
        corpus ~= result;
    }
    writeln(JSONValue(["fixtures": JSONValue(fixtures), "corpus": JSONValue(corpus)]).toString);
}
