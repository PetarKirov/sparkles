/**
A JSX-like markup for the top-down builder, as a string mixin.

```d
mixin(markup!q{
    column(gap: 1) {
        label(slot: Slot.heading, text: "Stats");
        if (ids.computing) { label(text: i"computing… $(ids.query)"); }
        foreach (r; ids.rows; key: r.name) { keyValue(name: r.name, value: r.value); }
    }
});
```

`markup` parses the token string at compile time and returns D statements
that drive `ui_sketch`'s open/close builder. Everything inside the markup is
D tokens; attribute values are spliced verbatim (so they are evaluated in the
caller's scope), with four rewrites:

$(UL
    $(LI `name: i"…"` (an IES as the whole value) becomes `name: ui.text(i"…")`.)
    $(LI `ui.on(m)` / `ui.on!fn` become `ui.on!(Scope)(m)` / `ui.on!(Scope, fn)`,
        where `Scope` is the message type the enclosing `mapMsg` (or the
        component's `@emits!M`) expects: a mismatch is a compile-time error.)
    $(LI `name: { …markup… }` is a fragment: a `scope` delegate that builds
        the markup where it is placed.)
    $(LI `name: (params) { …markup… }` is a fragment that takes arguments.)
)

Grammar (`?` optional, `*` repeated):
---
nodes    := node*
node     := 'if' '(' expr ')' block ('else' (node-if | block))?
            | 'foreach' '(' decl ';' range ';' 'key' ':' expr ')' block
            | 'auto' ident '=' '{' nodes '}' ';'          // a fragment variable
            | ident ('(' args? ')')? (block | ';')        // an element
block    := '{' nodes '}'
---
Line numbers of the generated code match the markup's (see `Emitter`), so
errors in attribute expressions point at the markup line.
*/
module markup;

// ── the entry points ───────────────────────────────────────────────────────

/// Statements for a component body: `mixin(markup!q{ … });`. `mixin(` and
/// `markup!` must be on the same line (the line map is relative to it).
enum string markup(string src, string file = __FILE__, size_t line = __LINE__) =
    generate(src, file, line, Mode.statements);

/// An expression: a fragment (a subtree as a value), `scope f = mixin(fragment!q{ … });`.
enum string fragment(string src, string file = __FILE__, size_t line = __LINE__) =
    generate(src, file, line, Mode.fragment);

/// The generated code, for `pragma(msg, …)` while debugging the generator.
enum string markupSource(string src, string file = "app.d", size_t line = 1) =
    generate(src, file, line, Mode.statements);

enum Mode { statements, fragment }

// ── lexing (CTFE) ──────────────────────────────────────────────────────────

private enum TK { ident, str, num, punct, eof }

private struct Tok
{
    TK kind;
    size_t start, end;
    uint line, col; // 0-based line within the markup, 1-based column
    string text;
}

private bool isIdStart(char c) => c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80;
private bool isIdChar(char c) => isIdStart(c) || (c >= '0' && c <= '9');

private struct LexResult { Tok[] toks; string error; uint errLine; }

private LexResult lex(string s)
{
    LexResult r;
    size_t i = 0;
    uint line = 0, lineStart = 0;

    void nl(size_t at) { line++; lineStart = cast(uint) at + 1; }
    Tok mk(TK k, size_t a, uint l, uint c) => Tok(k, a, i, l, c, s[a .. i]);

    // Skips a "…" body (escapes; `$(…)` nesting when `ies`), `i` at the opening quote.
    bool skipQuoted(char q, bool escapes, bool ies)
    {
        i++;
        while (i < s.length && s[i] != q)
        {
            if (s[i] == '\n') nl(i);
            if (escapes && s[i] == '\\') { i += 2; continue; }
            if (ies && s[i] == '$' && i + 1 < s.length && s[i + 1] == '(')
            {
                i += 2;
                int depth = 1;
                while (i < s.length && depth)
                {
                    const c = s[i];
                    if (c == '(') depth++;
                    else if (c == ')') depth--;
                    else if (c == '"') { if (!skipQuoted('"', true, false)) return false; continue; }
                    else if (c == '\n') nl(i);
                    i++;
                }
                continue;
            }
            i++;
        }
        if (i >= s.length) return false;
        i++; // closing quote
        while (i < s.length && (s[i] == 'c' || s[i] == 'w' || s[i] == 'd')) i++;
        return true;
    }

    bool skipTokenString() // at `{`
    {
        int depth = 0;
        do
        {
            if (s[i] == '{') depth++;
            else if (s[i] == '}') depth--;
            else if (s[i] == '\n') nl(i);
            else if (s[i] == '"') { if (!skipQuoted('"', true, false)) return false; continue; }
            i++;
        } while (i < s.length && depth);
        return depth == 0;
    }

    while (i < s.length)
    {
        const c = s[i];
        const a = i;
        const l = line, col = cast(uint)(i - lineStart + 1);
        if (c == '\n') { nl(i); i++; continue; }
        if (c == ' ' || c == '\t' || c == '\r') { i++; continue; }
        if (c == '/' && i + 1 < s.length && s[i + 1] == '/')
        {
            while (i < s.length && s[i] != '\n') i++;
            continue;
        }
        if (c == '/' && i + 1 < s.length && (s[i + 1] == '*' || s[i + 1] == '+'))
        {
            const close = s[i + 1];
            int depth = 1;
            i += 2;
            while (i + 1 < s.length && depth)
            {
                if (s[i] == '\n') nl(i);
                if (s[i] == close && s[i + 1] == '/') { depth--; i += 2; continue; }
                if (close == '+' && s[i] == '/' && s[i + 1] == '+') { depth++; i += 2; continue; }
                i++;
            }
            continue;
        }
        bool ok = true;
        if (c == '"') ok = skipQuoted('"', true, false);
        else if (c == '`') ok = skipQuoted('`', false, false);
        else if (c == '\'') ok = skipQuoted('\'', true, false);
        else if ((c == 'i' || c == 'r' || c == 'x') && i + 1 < s.length && (s[i + 1] == '"' || s[i + 1] == '`'))
        {
            i++;
            ok = skipQuoted(s[i], s[i] == '"' && c != 'r', c == 'i');
        }
        else if ((c == 'q' || c == 'i') && i + 1 < s.length && s[i + 1] == '{'
            || c == 'i' && i + 2 < s.length && s[i + 1] == 'q' && s[i + 2] == '{')
        {
            i += c == 'i' && s[i + 1] == 'q' ? 2 : 1;
            ok = skipTokenString();
        }
        else if (isIdStart(c))
        {
            while (i < s.length && isIdChar(s[i])) i++;
            r.toks ~= mk(TK.ident, a, l, col);
            continue;
        }
        else if (c >= '0' && c <= '9')
        {
            while (i < s.length && (isIdChar(s[i]) || s[i] == '.' && i + 1 < s.length
                    && s[i + 1] >= '0' && s[i + 1] <= '9'))
                i++;
            r.toks ~= mk(TK.num, a, l, col);
            continue;
        }
        else
        {
            static immutable string[] two = ["=>", "==", "!=", "&&", "||", "<=", ">=", "..", "++", "--"];
            i++;
            foreach (t; two)
                if (i < s.length && s[a] == t[0] && s[i] == t[1]) { i++; break; }
            r.toks ~= mk(TK.punct, a, l, col);
            continue;
        }
        if (!ok)
        {
            r.error = "unterminated string literal";
            r.errLine = l;
            return r;
        }
        r.toks ~= mk(TK.str, a, l, col);
    }
    r.toks ~= Tok(TK.eof, s.length, s.length, line, cast(uint)(s.length - lineStart + 1), "");
    return r;
}

// ── emitting, with the line map ────────────────────────────────────────────

/**
The generated code keeps every spliced token on the line it had in the markup.

A string mixin's lines are numbered from the `mixin(` line, so line `k` of
the generated text reports as `L + k`, which is the markup token's real line
when `markup!q{` starts on line `L`. Glue is written without newlines, and
newlines are added only to advance to the next spliced token's line, so the
map holds for every token. (`#line` would be the obvious tool, but inside a
string mixin DMD 2.111+/LDC 1.41+ add the mixin's line twice — `#line N`
reports `N + 2·(L − 1)` — so it cannot name lines before `2L − 1`. See
README.md.)
*/
private struct Emitter
{
    string src, file, prefix;
    size_t baseLine;
    string code;
    uint outLine;
    uint counter;
    uint outCol = 1;

    void glue(string s) { code ~= s; outCol += cast(uint) s.length; }

    /// Moves to `line` without splicing, so the glue after it reports there.
    void ensureLine(uint line)
    {
        while (outLine < line) { code ~= "\n"; outLine++; outCol = 1; }
    }

    /// Splices src[t.start .. b] at its own line and column. Glue sits at
    /// the end of the line before where it can; on a shared line the column
    /// is kept when the glue left room, and drifts right when it did not.
    void splice(in Tok t, size_t b)
    {
        ensureLine(t.line);
        if (outCol < t.col)
            foreach (_; outCol .. t.col) { code ~= " "; outCol++; }
        else if (t.start > 0 && (src[t.start - 1] == ' ' || src[t.start - 1] == '\n'))
            { code ~= " "; outCol++; }
        code ~= src[t.start .. b];
        foreach (ch; src[t.start .. b])
        {
            if (ch == '\n') { outLine++; outCol = 1; }
            else outCol++;
        }
    }

    string fresh(string what) => prefix ~ what ~ toStr(counter++);

    /// A compile-time constant identity for the element at `t`.
    string site(in Tok t) =>
        "Site(" ~ toStr(fnv(file ~ ":" ~ toStr(baseLine + t.line) ~ ":" ~ toStr(t.col))) ~ "UL)";
}

private string toStr(ulong v)
{
    if (v == 0) return "0";
    char[20] b;
    size_t n = b.length;
    while (v) { b[--n] = cast(char)('0' + v % 10); v /= 10; }
    return b[n .. $].idup;
}

ulong fnv(string s) @safe pure nothrow @nogc
{
    ulong h = 0xcbf29ce484222325;
    foreach (c; s) { h ^= c; h *= 0x100000001b3; }
    return h;
}

// ── parsing + generation ───────────────────────────────────────────────────

private struct MarkupError { string msg; uint line; }

private static immutable string[] containers = ["column", "row"];
private static immutable string[] leaves = ["label", "toggle", "numberField", "keyValue"];

private bool among(string s, in string[] set)
{
    foreach (x; set) if (x == s) return true;
    return false;
}

private struct Gen
{
    Tok[] t;
    size_t p;
    Emitter e;
    MarkupError err;

    bool failed() const => err.msg.length != 0;
    ref const(Tok) cur() const return => t[p];
    bool isP(string s) const => t[p].kind == TK.punct && t[p].text == s;
    bool isId(string s) const => t[p].kind == TK.ident && t[p].text == s;

    void fail(string msg) { if (!failed) err = MarkupError(msg, t[p].line); }
    void fail(string msg, uint line) { if (!failed) err = MarkupError(msg, line); }

    bool expect(string s)
    {
        if (isP(s)) { p++; return true; }
        fail("expected `" ~ s ~ "`, found `" ~ (t[p].kind == TK.eof ? "end of markup" : t[p].text) ~ "`");
        return false;
    }

    /// Index of the token closing the bracket at `open` (which is `(`, `[` or `{`).
    size_t matching(size_t open)
    {
        int depth = 0;
        foreach (k; open .. t.length)
        {
            if (t[k].kind != TK.punct) continue;
            const s = t[k].text;
            if (s == "(" || s == "[" || s == "{") depth++;
            else if (s == ")" || s == "]" || s == "}")
                if (--depth == 0) return k;
        }
        fail("unbalanced `" ~ t[open].text ~ "`", t[open].line);
        return t.length - 1;
    }

    /// Splits tokens [a, b) at top-level `sep`.
    size_t[2][] split(size_t a, size_t b, string sep)
    {
        size_t[2][] parts;
        int depth = 0;
        size_t from = a;
        foreach (k; a .. b)
        {
            if (t[k].kind != TK.punct) continue;
            const s = t[k].text;
            if (s == "(" || s == "[" || s == "{") depth++;
            else if (s == ")" || s == "]" || s == "}") depth--;
            else if (depth == 0 && s == sep) { parts ~= [from, k]; from = k + 1; }
        }
        if (from < b || parts.length) parts ~= [from, b];
        return parts;
    }

    /// Emits tokens [a, b) as an expression, with the `ui.on` rewrite. Runs
    /// between rewrites are spliced verbatim, so they keep their columns.
    void expr(size_t a, size_t b, string scopeMsg)
    {
        size_t run = a, k = a;
        void flush(size_t upTo) { if (upTo > run) e.splice(t[run], t[upTo - 1].end); }
        while (k < b)
        {
            // ui . on ( …   →   ui.on!(Scope)( …
            // ui . on ! ( …  →  ui.on!(Scope, …
            // ui . on ! fn   →  ui.on!(Scope, fn)
            if (k + 3 < b && t[k].text == "ui" && t[k + 1].text == "." && t[k + 2].text == "on")
            {
                const nx = t[k + 3];
                if (nx.kind == TK.punct && nx.text == "(")
                {
                    flush(k + 3);
                    e.glue("!(" ~ scopeMsg ~ ")");
                    run = k = k + 3;
                    continue;
                }
                if (nx.kind == TK.punct && nx.text == "!" && k + 4 < b)
                {
                    flush(k + 3);
                    e.glue("!(" ~ scopeMsg ~ ",");
                    if (t[k + 4].text != "(")
                    {
                        e.splice(t[k + 4], t[k + 4].end);
                        e.glue(")");
                    }
                    run = k = k + 5;
                    continue;
                }
            }
            k++;
        }
        flush(b);
    }

    /// One attribute value (tokens [a, b)) with the fragment and IES rewrites.
    void value(size_t a, size_t b, string scopeMsg)
    {
        if (a >= b) { fail("an attribute needs a value", t[a].line); return; }
        // `{ markup }`: a fragment.
        if (t[a].text == "{" && t[a].kind == TK.punct && matching(a) == b - 1)
        {
            e.glue("delegate (ref Ui ui, MsgTag!(" ~ scopeMsg ~ ") __tag) @safe pure nothrow @nogc {");
            const save = p;
            p = a + 1;
            nodes(b - 1, scopeMsg);
            p = save;
            e.glue("}");
            return;
        }
        // `(params) { markup }`: a fragment taking arguments.
        if (t[a].text == "(" && t[a].kind == TK.punct)
        {
            const close = matching(a);
            if (close + 1 < b && t[close + 1].text == "{" && matching(close + 1) == b - 1)
            {
                e.glue("delegate (ref Ui ui, MsgTag!(" ~ scopeMsg ~ ") __tag, ");
                if (close > a + 1)
                    e.splice(t[a + 1], t[close - 1].end);
                e.glue(") @safe pure nothrow @nogc {");
                const save = p;
                p = close + 2;
                nodes(b - 1, scopeMsg);
                p = save;
                e.glue("}");
                return;
            }
        }
        // An IES as the whole value: format it into the frame.
        if (b == a + 1 && t[a].kind == TK.str && t[a].text[0] == 'i')
        {
            e.glue("ui.text(");
            e.splice(t[a], t[a].end);
            e.glue(")");
            return;
        }
        expr(a, b, scopeMsg);
    }

    /// `name: value, …` inside parens [a, b): emits `, name: value` per attribute.
    /// Returns the plain-identifier values (for the fragment check).
    string[] attrs(size_t a, size_t b, string scopeMsg, bool named)
    {
        string[] idents;
        foreach (part; split(a, b, ","))
        {
            if (part[0] >= part[1]) continue; // trailing comma
            size_t v = part[0];
            if (v > a) e.splice(t[v - 1], t[v - 1].end); // the source comma, in its column
            else e.glue(",");
            if (part[1] - part[0] >= 2 && t[v].kind == TK.ident && t[v + 1].text == ":")
            {
                e.splice(t[v], t[v + 1].end);
                v += 2;
            }
            else if (named)
            {
                fail("attributes are named: write `name: value`", t[v].line);
                return idents;
            }
            if (part[1] == v + 1 && t[v].kind == TK.ident)
                idents ~= t[v].text;
            value(v, part[1], scopeMsg);
        }
        return idents;
    }

    void nodes(size_t end, string scopeMsg)
    {
        while (p < end && !failed)
            node(scopeMsg);
    }

    void block(string scopeMsg)
    {
        if (!isP("{")) { fail("expected a `{ … }` block, found `" ~ cur.text ~ "`"); return; }
        const close = matching(p);
        p++;
        nodes(close, scopeMsg);
        p = close + 1;
    }

    void node(string scopeMsg)
    {
        const head = p;
        if (cur.kind != TK.ident)
        {
            fail("expected an element, `if`, `foreach` or `auto name = { … };`, found `" ~ cur.text ~ "`");
            return;
        }
        const name = cur.text;

        if (name == "if")
        {
            e.splice(t[p], t[p].end);
            p++;
            if (!isP("(")) { fail("expected `(` after `if`"); return; }
            const close = matching(p);
            e.splice(t[p], t[p].end);
            expr(p + 1, close, scopeMsg);
            e.splice(t[close], t[close].end);
            p = close + 1;
            e.glue("{");
            block(scopeMsg);
            e.glue("}");
            if (isId("else"))
            {
                e.splice(t[p], t[p].end);
                p++;
                if (isId("if"))
                    node(scopeMsg);
                else
                {
                    e.glue("{");
                    block(scopeMsg);
                    e.glue("}");
                }
            }
            return;
        }

        if (name == "foreach")
        {
            p++;
            if (!isP("(")) { fail("expected `(` after `foreach`"); return; }
            const close = matching(p);
            auto parts = split(p + 1, close, ";");
            if (parts.length != 3 || parts[2][1] - parts[2][0] < 3
                || t[parts[2][0]].text != "key" || t[parts[2][0] + 1].text != ":")
            {
                fail("a `foreach` in markup needs a key: `foreach (r; rows; key: r.name)`"
                    ~ " (rows are identified by key, not position)", t[head].line);
                return;
            }
            e.splice(t[head], t[head].end);
            e.glue("(");
            e.splice(t[parts[0][0]], t[parts[0][1] - 1].end);
            e.glue(";");
            expr(parts[1][0], parts[1][1], scopeMsg);
            e.glue(") { auto " ~ e.fresh("k") ~ " = ui.keyed(" ~ e.site(t[head]) ~ ",");
            expr(parts[2][0] + 2, parts[2][1], scopeMsg);
            e.glue(");");
            p = close + 1;
            block(scopeMsg);
            e.glue("}");
            return;
        }

        if (name == "auto")
        {
            // auto name = { markup };
            p++;
            if (cur.kind != TK.ident) { fail("expected a name after `auto`"); return; }
            const var = p;
            p++;
            if (!expect("=")) return;
            const vstart = p;
            if (!isP("{") && !isP("(")) { fail("`auto " ~ t[var].text ~ " = …` in markup holds a fragment: `{ … }`"); return; }
            size_t vend = isP("{") ? matching(p) + 1 : matching(matching(p) + 1) + 1;
            e.glue("scope ");
            e.splice(t[var], t[var].end);
            e.glue(" = ");
            value(vstart, vend, scopeMsg);
            p = vend;
            expect(";");
            e.glue(";");
            return;
        }

        // An element: name, optional `(args)`, then `{ children }` or `;`.
        p++;
        size_t argA = p, argB = p;
        if (isP("("))
        {
            const close = matching(p);
            argA = p + 1;
            argB = close;
            p = close + 1;
        }
        const hasBlock = isP("{");
        if (!hasBlock && !isP(";"))
        {
            fail("expected `{` or `;` after element `" ~ name ~ "`", t[p - 1].line);
            return;
        }
        // Glue stays on the line before (attributes keep their columns); `ensureLine`
        // moves to the element's line before glue whose errors must report there.
        const site = e.site(t[head]);
        const line = t[head].line;

        if (name == "mapMsg")
        {
            if (!hasBlock) { fail("`mapMsg` wraps children: `mapMsg(fn) { … }`"); return; }
            const fn = e.fresh("f"), inner = e.fresh("M");
            e.glue("{ alias " ~ fn ~ " = ");
            expr(argA, argB, scopeMsg);
            e.ensureLine(line);
            e.glue("; alias " ~ inner ~ " = MapFrom!" ~ fn ~ "; static assert(is(MapTo!" ~ fn ~ " == "
                ~ scopeMsg ~ "), \"markup: this mapMsg produces \" ~ MapTo!" ~ fn ~ ".stringof ~ \", but "
                ~ "its parent expects \" ~ " ~ scopeMsg ~ ".stringof); auto " ~ e.fresh("e") ~ " = ui.mapMsg!"
                ~ fn ~ "(" ~ site ~ ");");
            block(inner);
            e.glue("}");
            return;
        }
        if (name == "embed")
        {
            if (hasBlock) { fail("`embed(fragment, args…)` has no children"); return; }
            e.glue("ui.embed!(" ~ scopeMsg ~ ")(" ~ site);
            attrs(argA, argB, scopeMsg, false);
            e.ensureLine(line);
            e.glue(");");
            p++;
            return;
        }
        if (name == "memo")
        {
            if (!hasBlock) { fail("`memo(deps: …) { … }` wraps children"); return; }
            const parts = split(argA, argB, ",");
            if (parts.length != 1 || t[parts[0][0]].text != "deps" || t[parts[0][0] + 1].text != ":")
            {
                fail("`memo` takes one attribute, `deps:`");
                return;
            }
            e.glue("{ auto " ~ e.fresh("e") ~ " = ui.memo(" ~ site ~ ",");
            expr(parts[0][0] + 2, parts[0][1], scopeMsg);
            e.ensureLine(line);
            e.glue(");");
            block(scopeMsg);
            e.glue("}");
            return;
        }
        if (name.among(containers))
        {
            e.glue("{ auto " ~ e.fresh("e") ~ " = ui." ~ name ~ "(" ~ site);
            attrs(argA, argB, scopeMsg, true);
            e.ensureLine(line);
            e.glue(");");
            if (hasBlock) block(scopeMsg); else p++;
            e.glue("}");
            return;
        }
        if (name.among(leaves))
        {
            if (hasBlock) { fail("`" ~ name ~ "` has no children"); return; }
            e.glue("ui." ~ name ~ "(" ~ site);
            attrs(argA, argB, scopeMsg, true);
            e.ensureLine(line);
            e.glue(");");
            p++;
            return;
        }

        // A component: `name(attrs) { children }` calls `name(ui, attrs, children: fragment)`.
        // The placement check reports at the element's line, so it goes before the call.
        e.ensureLine(line);
        e.glue("{ static assert(placeable!(" ~ name ~ ", " ~ scopeMsg ~ "), \"markup: `" ~ name
            ~ "` sends \" ~ EmitsOf!(" ~ name ~ ").stringof ~ \", but here \" ~ " ~ scopeMsg
            ~ ".stringof ~ \" is expected: wrap it in mapMsg(…)\"); auto " ~ e.fresh("c") ~ " = ui.enter("
            ~ site ~ "); " ~ name ~ "(ui");
        const idents = attrs(argA, argB, scopeMsg, true);
        if (hasBlock)
        {
            e.glue(", children: delegate (ref Ui ui, MsgTag!(" ~ scopeMsg ~ ") __tag) @safe pure nothrow @nogc {");
            block(scopeMsg);
            e.glue("}");
        }
        else
            p++;
        e.glue(");");
        foreach (id; idents)
            e.glue(" static assert(fragmentFits!(typeof(" ~ id ~ "), " ~ scopeMsg ~ "), \"markup: fragment `"
                ~ id ~ "` was written under another message type\");");
        e.glue("}");
    }
}

private string generate(string src, string file, size_t line, Mode mode)
{
    const lexed = lex(src);
    Emitter e = Emitter(src: src, file: file, prefix: "__mk" ~ toStr(line) ~ "_", baseLine: line);
    if (lexed.error.length)
        return errorCode(e, lexed.error, lexed.errLine);
    Gen g = Gen(t: cast(Tok[]) lexed.toks, e: e);
    const root = g.e.fresh("M");
    final switch (mode)
    {
        case Mode.statements:
            const anchor = g.e.fresh("anchor");
            g.e.glue("{ struct " ~ anchor ~ " {} alias " ~ root ~ " = EmitsOf!(EnclosingComponent!"
                ~ anchor ~ ");");
            g.nodes(g.t.length - 1, root);
            g.e.glue("}");
            break;
        case Mode.fragment:
            // The message type is the enclosing component's. An expression
            // cannot declare the anchor symbol, so a lambda inside `typeof`
            // does (`__FUNCTION__` is empty in a delegate's parameter list).
            const anchor = g.e.fresh("anchor");
            g.e.glue("delegate (ref Ui ui, typeof(() { struct " ~ anchor ~ " {} return MsgTag!(EmitsOf!("
                ~ "EnclosingComponent!" ~ anchor ~ ")).init; }()) __tag) @safe pure nothrow @nogc"
                ~ " { alias " ~ root ~ " = typeof(__tag).Msg;");
            g.nodes(g.t.length - 1, root);
            g.e.glue("}");
            break;
    }
    if (g.failed)
        return errorCode(e, g.err.msg, g.err.line, mode);
    return g.e.code;
}

private string errorCode(Emitter e, string msg, uint line, Mode mode = Mode.statements)
{
    string code;
    foreach (_; 0 .. line) code ~= "\n";
    string escaped;
    foreach (ch; msg) escaped ~= ch == '"' ? "\\\"" : [ch];
    const assertion = "static assert(0, \"markup: " ~ escaped ~ "\");";
    return code ~ (mode == Mode.statements ? assertion : "() { " ~ assertion ~ " }");
}
