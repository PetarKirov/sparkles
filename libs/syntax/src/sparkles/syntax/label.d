/**
The label vocabulary: canonical dotted highlight names and their interning.

Both engine families converge on dot-separated semantic names — tree-sitter
capture names deliberately track TextMate scope names — so one vocabulary
(and one theme layer) drives every engine. $(LREF standardLabels) is the
canonical list (the union of the reference tree-sitter highlighter's
recognized names and Helix's theme scopes); $(LREF LabelSet) interns names to
`LabelId`s at configure time.

Resolution semantics are $(B longest-dot-prefix) (Helix's rule, shared with
theme resolution): `"function.builtin.static"` tries the full name, then
`"function.builtin"`, then `"function"`. This deliberately diverges from the
reference crate's part-subset rule (`"a.c"` matching capture `"a.b.c"`) —
prefix matching is order-preserving and uses one algorithm everywhere.
*/
module sparkles.syntax.label;

import std.algorithm.comparison : cmp;
import std.algorithm.sorting : isStrictlyMonotonic;

import sparkles.syntax.event : LabelId;

/**
The canonical scope-compatible label names, sorted (byte-wise) and unique.

Sources: the reference tree-sitter highlighter's recognized capture names and
Helix's theme scopes, merged. Consumers with different needs can build a
custom vocabulary via $(LREF LabelSet.fromNames).
*/
static immutable string[] standardLabels = [
    "attribute",
    "boolean",
    "comment",
    "comment.block",
    "comment.documentation",
    "comment.line",
    "constant",
    "constant.builtin",
    "constant.character",
    "constant.character.escape",
    "constant.numeric",
    "constant.numeric.float",
    "constant.numeric.integer",
    "constructor",
    "constructor.builtin",
    "diff.delta",
    "diff.minus",
    "diff.plus",
    "embedded",
    "error",
    "escape",
    "function",
    "function.builtin",
    "function.macro",
    "function.method",
    "keyword",
    "keyword.control",
    "keyword.directive",
    "keyword.function",
    "keyword.operator",
    "keyword.storage",
    "label",
    "markup.bold",
    "markup.heading",
    "markup.italic",
    "markup.link",
    "markup.link.url",
    "markup.list",
    "markup.list.checked",
    "markup.list.numbered",
    "markup.list.unchecked",
    "markup.quote",
    "markup.raw",
    "markup.raw.block",
    "markup.raw.inline",
    "markup.strikethrough",
    "module",
    "namespace",
    "number",
    "operator",
    "property",
    "property.builtin",
    "punctuation",
    "punctuation.bracket",
    "punctuation.delimiter",
    "punctuation.special",
    "string",
    "string.escape",
    "string.regexp",
    "string.special",
    "string.special.key",
    "string.special.path",
    "string.special.symbol",
    "string.special.url",
    "tag",
    "tag.attribute",
    "type",
    "type.builtin",
    "variable",
    "variable.builtin",
    "variable.member",
    "variable.other.member",
    "variable.parameter",
];

// byte-wise (code-unit) order — `<` on `string` is `LabelSet.find`'s `cmp` order.
static assert(standardLabels.isStrictlyMonotonic,
    "standardLabels must be byte-wise sorted and unique");
static assert(standardLabels.length < LabelId.none.value,
    "standardLabels exceeds the LabelId capacity");

/**
An interned label vocabulary: a sorted, unique list of dotted names indexed
by `LabelId`.

Engines call $(LREF resolve) once per capture name at configure time; themes
resolve their selectors against the same set. The default vocabulary is
$(LREF standard); custom vocabularies come from $(LREF fromNames).
*/
struct LabelSet
{
    private immutable(string)[] _names;

    /// The canonical vocabulary ($(LREF standardLabels)). Allocation-free.
    static LabelSet standard() @safe pure nothrow @nogc
        => LabelSet(standardLabels);

    /**
    Builds a custom vocabulary: sorts and de-duplicates `names`.
    Configure-time only (allocates the interned table).
    */
    static LabelSet fromNames(scope const(string)[] names) @safe pure nothrow
    {
        import std.algorithm.iteration : uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;

        auto sorted = names.dup.sort().uniq().array;
        assert(sorted.length < LabelId.none.value,
            "LabelSet exceeds the LabelId capacity");
        return LabelSet(sorted.idup);
    }

    /// Number of names in the vocabulary.
    size_t length() const @safe pure nothrow @nogc
        => _names.length;

    /// The dotted name behind `id`. `id` must be a real label from this set.
    const(char)[] name(LabelId id) const @safe pure nothrow @nogc
    in (id.value < _names.length, "LabelId out of range for this LabelSet")
    {
        return _names[id.value];
    }

    /// Exact dotted-name lookup (binary search); `LabelId.none` on miss.
    LabelId find(scope const(char)[] dotted) const @safe pure nothrow @nogc
    {
        size_t lo = 0, hi = _names.length;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            const c = cmp(_names[mid], dotted);
            if (c == 0)
                return LabelId(cast(ushort) mid);
            if (c < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        return LabelId.none;
    }

    /**
    Longest-dot-prefix resolution: tries the full name, then chops trailing
    `.part` segments until a recognized name matches.
    `"function.builtin.static"` → `"function.builtin"` → `"function"`.
    Returns `LabelId.none` when no prefix matches.
    */
    LabelId resolve(scope const(char)[] captureName) const @safe pure nothrow @nogc
    {
        const(char)[] candidate = captureName;
        while (candidate.length)
        {
            if (const id = find(candidate))
                return id;

            size_t i = candidate.length;
            while (i > 0 && candidate[i - 1] != '.')
                --i;
            if (i == 0)
                break;
            candidate = candidate[0 .. i - 1];
        }
        return LabelId.none;
    }
}

///
@("label.LabelSet.resolve")
@safe pure nothrow @nogc
unittest
{
    const labels = LabelSet.standard();

    // exact hit
    assert(labels.resolve("string.special.key") == labels.find("string.special.key"));
    // one chop
    assert(labels.resolve("function.builtin.static") == labels.find("function.builtin"));
    // multi chop
    assert(labels.resolve("keyword.storage.type.qualifier") == labels.find("keyword.storage"));
    // miss
    assert(labels.resolve("totally.unknown.thing") == LabelId.none);
    assert(labels.resolve("") == LabelId.none);
}

@("label.LabelSet.resolveAtCompileTime")
@safe pure nothrow @nogc
unittest
{
    // The whole configure-time path is CTFE-able.
    static assert(LabelSet.standard().resolve("function.builtin.weird")
        == LabelSet.standard().find("function.builtin"));
    static assert(LabelSet.standard().resolve("no.such.label") == LabelId.none);
}

@("label.LabelSet.findAndName")
@safe pure nothrow @nogc
unittest
{
    const labels = LabelSet.standard();
    assert(labels.length == standardLabels.length);

    const id = labels.find("keyword");
    assert(id);
    assert(labels.name(id) == "keyword");

    assert(labels.find("keywor") == LabelId.none);
    assert(labels.find("keywordy") == LabelId.none);
}

@("label.LabelSet.fromNames")
@safe pure nothrow
unittest
{
    static immutable string[] custom = ["zeta", "alpha", "alpha", "mid.dle"];
    const labels = LabelSet.fromNames(custom);
    assert(labels.length == 3); // de-duplicated
    assert(labels.find("alpha"));
    assert(labels.find("mid.dle"));
    assert(labels.resolve("mid.dle.deep") == labels.find("mid.dle"));
    assert(labels.resolve("zeta.sub") == labels.find("zeta"));
}
