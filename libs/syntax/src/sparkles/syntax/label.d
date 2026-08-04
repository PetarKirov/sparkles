/**
The label vocabulary: canonical dotted highlight names and their interning.

Both engine families converge on dot-separated semantic names — tree-sitter
capture names broadly track TextMate scope names — so one vocabulary (and one
theme layer) drives every engine. $(LREF standardLabels) is the canonical list,
following Helix's hierarchical theme scopes; $(LREF LabelSet) interns names to
`LabelId`s at configure time.

Resolution semantics are $(B longest-dot-prefix) (Helix's rule, shared with
theme resolution): `"function.builtin.static"` tries the full name, then
`"function.builtin"`, then `"function"`. This deliberately diverges from the
reference crate's part-subset rule (`"a.c"` matching capture `"a.b.c"`) —
prefix matching is order-preserving and uses one algorithm everywhere.

The convergence is only broad, which is why the vocabulary is hierarchical and
why $(LREF standardAliases) exists: upstream tree-sitter and older neovim
queries spell many of the same concepts flat (`number`, `property`,
`text.strong`), and a flat name gives longest-dot-prefix nothing to fall back
to. $(LREF LabelSet.resolve) folds those spellings onto the canonical names —
$(B capture names only), never theme selectors.
*/
module sparkles.syntax.label;

import std.algorithm.comparison : cmp;
import std.algorithm.iteration : map;
import std.algorithm.sorting : isStrictlyMonotonic;

import sparkles.syntax.event : LabelId;

/**
The canonical scope-compatible label names, sorted (byte-wise) and unique.

Hierarchical throughout, following Helix's theme scopes: a flat name would
give $(LREF LabelSet.resolve) nothing to degrade to, and a theme nothing to
inherit from. Other dialects' flat spellings live in $(LREF standardAliases)
rather than here, so each concept has exactly one label. Consumers with
different needs can build a custom vocabulary via $(LREF LabelSet.fromNames).
*/
static immutable string[] standardLabels = [
    "comment",
    "comment.block",
    "comment.documentation",
    "comment.line",
    "constant",
    "constant.builtin",
    "constant.builtin.boolean",
    "constant.character",
    "constant.character.escape",
    "constant.numeric",
    "constant.numeric.float",
    "constant.numeric.integer",
    "diff.delta",
    "diff.minus",
    "diff.plus",
    "embedded",
    "error",
    "function",
    "function.builtin",
    "function.constructor",
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
    "operator",
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
    "variable.parameter",
];

// byte-wise (code-unit) order — `<` on `string` is `LabelSet.find`'s `cmp` order.
static assert(standardLabels.isStrictlyMonotonic,
    "standardLabels must be byte-wise sorted and unique");
static assert(standardLabels.length < LabelId.none.value,
    "standardLabels exceeds the LabelId capacity");

/// One dialect spelling and the $(LREF standardLabels) entry it means.
struct LabelAlias
{
    string name;      /// the non-canonical capture name, as grammars write it
    string canonical; /// the vocabulary entry it resolves to
}

/**
Capture-name spellings from other dialects, mapped onto the canonical
vocabulary.

$(LREF standardLabels) is hierarchical (`constant.numeric`, `variable.member`)
because $(LREF LabelSet.resolve) degrades by chopping dotted segments, and only
a hierarchy gives it somewhere to degrade to: `constant.numeric.float` falls
back to `constant.numeric`, then `constant`. Upstream tree-sitter and older
neovim queries spell many of the same concepts flat (`number`, `property`,
`text.strong`), which chop to nothing.

The grammars behind `$SPARKLES_TS_GRAMMAR_PATH` are shipped as upstream wrote
them, so both dialects arrive at `resolve`. Without this table a third of what
they emit reaches no label a theme can style — numbers, properties, booleans
and the whole of markdown render unstyled. See
$(LINK2 ../../../../docs/specs/syntax/label-vocabulary-dialects.md, the spec).

This applies to $(B capture names) only. Theme selectors are written against
the canonical vocabulary and resolve through `writeThemeStyles`, which never
consults this table — so an alias can never be a theme selector, and one label
can never be targeted by two spellings of the same rule.
*/
static immutable LabelAlias[] standardAliases = [
    LabelAlias("attribute", "tag.attribute"),
    LabelAlias("boolean", "constant.builtin.boolean"),
    LabelAlias("character", "constant.character"),
    LabelAlias("conditional", "keyword.control"),
    // TextMate has no constructor scope — it writes them `entity.name.function`
    // — so a flat `constructor` label would be styled by nothing. Under
    // `function` it inherits the function color through longest-dot-prefix, and
    // a theme that does distinguish constructors can still say so.
    LabelAlias("constructor", "function.constructor"),
    // The legacy neovim preprocessor pair: `@define` marks a definition site,
    // `@preproc` the directive itself. Both are directives in this vocabulary.
    LabelAlias("define", "keyword.directive"),
    LabelAlias("delimiter", "punctuation.delimiter"),
    LabelAlias("escape", "string.escape"),
    LabelAlias("exception", "keyword.control"),
    // `@field` is the neovim spelling of `@property` — same target.
    LabelAlias("field", "variable.member"),
    LabelAlias("float", "constant.numeric.float"),
    // Dart's queries qualify under `identifier.` where the dialects qualify
    // under the role; chopping would reach a bare `identifier` that no
    // vocabulary defines, so both spellings are named outright.
    LabelAlias("identifier.constant", "constant"),
    LabelAlias("identifier.parameter", "variable.parameter"),
    LabelAlias("import", "keyword.control"),
    LabelAlias("include", "keyword.control"),
    // Math regions (latex). The vocabulary has no math axis; `markup.raw` is
    // its "set apart from prose, not prose" bucket, which is what a `$…$` run
    // is to the surrounding text.
    LabelAlias("markup.math", "markup.raw"),
    // `markup.strong` is the newer neovim spelling of `text.strong` above.
    LabelAlias("markup.strong", "markup.bold"),
    LabelAlias("method", "function.method"),
    LabelAlias("namespace", "module"),
    LabelAlias("number", "constant.numeric"),
    // Explicit: chopping would reach `number` and lose the float distinction.
    LabelAlias("number.float", "constant.numeric.float"),
    LabelAlias("parameter", "variable.parameter"),
    LabelAlias("preproc", "keyword.directive"),
    LabelAlias("property", "variable.member"),
    LabelAlias("repeat", "keyword.control"),
    LabelAlias("storageclass", "keyword.storage"),
    // A grammar nonterminal (ebnf). Its `.camel`/`.pascal`/`.upper`/`.lower`
    // children — the queries color by naming convention — chop onto this one.
    LabelAlias("symbol.grammar", "variable"),
    // The neovim markdown dialect the bundled markdown grammars still use.
    LabelAlias("text.emphasis", "markup.italic"),
    LabelAlias("text.literal", "markup.raw.inline"),
    LabelAlias("text.reference", "markup.link"),
    LabelAlias("text.strong", "markup.bold"),
    LabelAlias("text.title", "markup.heading"),
    LabelAlias("text.uri", "markup.link.url"),
    LabelAlias("var.reference", "variable"),
    LabelAlias("variable.other.member", "variable.member"),
];

// Same byte-wise order as `standardLabels` — `aliasFor` binary-searches it.
static assert(standardAliases.map!(a => a.name).isStrictlyMonotonic,
    "standardAliases must be byte-wise sorted and unique by name");

// An alias that resolves to nothing is a silent hole: the capture would land on
// `LabelId.none` and render unstyled, which is the defect this table exists to
// close. Every target must be a real vocabulary entry.
static assert(() {
    foreach (a; standardAliases)
        if (!assumeSortedNames.contains(a.canonical))
            return false;
    return true;
}(), "every standardAliases target must be in standardLabels");

// `@none` and `@spell` are deliberately absent: upstream uses them to suppress
// highlighting and to hint spellcheckers, so resolving to nothing is correct.
static assert(() {
    foreach (a; standardAliases)
        if (assumeSortedNames.contains(a.name))
            return false;
    return true;
}(), "a standardAliases name must not also be a standardLabels entry");

private auto assumeSortedNames()
{
    import std.range : assumeSorted;

    return assumeSorted(standardLabels);
}

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
    private immutable(LabelAlias)[] _aliases;

    /// The canonical vocabulary ($(LREF standardLabels)) plus the dialect
    /// spellings in $(LREF standardAliases). Allocation-free.
    static LabelSet standard() @safe pure nothrow @nogc
        => LabelSet(standardLabels, standardAliases);

    /**
    Builds a custom vocabulary: sorts and de-duplicates `names`.
    Configure-time only (allocates the interned table).

    Carries no aliases — a caller who supplies its own vocabulary also owns the
    spellings that reach it.
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
    size_t length() const scope @safe pure nothrow @nogc
        => _names.length;

    /// The dotted name behind `id`. `id` must be a real label from this set.
    const(char)[] name(LabelId id) const scope @safe pure nothrow @nogc
    in (id.value < _names.length, "LabelId out of range for this LabelSet")
    {
        return _names[id.value];
    }

    /// Exact dotted-name lookup (binary search); `LabelId.none` on miss.
    LabelId find(scope const(char)[] dotted) const scope @safe pure nothrow @nogc
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

    Each prefix is tried against the vocabulary first and against
    $(LREF standardAliases) second, so a dialect spelling resolves at the same
    depth a canonical name would: `"number.float"` hits the alias table whole,
    while `"number.weird"` chops to `"number"` and lands on `constant.numeric`.
    Checking aliases only after the vocabulary misses keeps a real label
    unshadowable.
    */
    LabelId resolve(scope const(char)[] captureName) const scope @safe pure nothrow @nogc
    {
        const(char)[] candidate = captureName;
        while (candidate.length)
        {
            if (const id = find(candidate))
                return id;
            if (const canonical = aliasFor(candidate))
                if (const id = find(canonical))
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

    /// The canonical name `spelling` aliases, or `null` when it is not an
    /// alias. Exact match only — `resolve` supplies the prefix chopping.
    private const(char)[] aliasFor(scope const(char)[] spelling)
        const scope @safe pure nothrow @nogc
    {
        size_t lo = 0, hi = _aliases.length;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            const c = cmp(_aliases[mid].name, spelling);
            if (c == 0)
                return _aliases[mid].canonical;
            if (c < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        return null;
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

///
@("label.LabelSet.resolveAlias")
@safe pure nothrow @nogc
unittest
{
    const labels = LabelSet.standard();

    // The dialect spellings the bundled grammars actually emit.
    assert(labels.resolve("number") == labels.find("constant.numeric"));
    assert(labels.resolve("property") == labels.find("variable.member"));
    assert(labels.resolve("boolean") == labels.find("constant.builtin.boolean"));
    assert(labels.resolve("text.strong") == labels.find("markup.bold"));

    // An alias is exact; the chop still applies around it.
    assert(labels.resolve("number.float") == labels.find("constant.numeric.float"));
    assert(labels.resolve("number.weird") == labels.find("constant.numeric"));
    assert(labels.resolve("property.definition") == labels.find("variable.member"));

    // Upstream's deliberate no-ops must keep resolving to nothing.
    assert(labels.resolve("none") == LabelId.none);
    assert(labels.resolve("spell") == LabelId.none);
}

@("label.LabelSet.fromNamesHasNoAliases")
@safe pure nothrow
unittest
{
    // A caller supplying its own vocabulary owns the spellings that reach it.
    static immutable string[] custom = ["constant.numeric"];
    const labels = LabelSet.fromNames(custom);
    assert(labels.find("constant.numeric"));
    assert(labels.resolve("number") == LabelId.none);
}

@("label.LabelSet.aliasesNeverShadowLabels")
@safe pure nothrow @nogc
unittest
{
    const labels = LabelSet.standard();

    // A canonical name always wins over the alias table, at every depth.
    foreach (name; standardLabels)
        assert(labels.resolve(name) == labels.find(name));

    // And every alias lands on a real, distinct label.
    foreach (a; standardAliases)
    {
        assert(labels.find(a.name) == LabelId.none, "alias leaked into the vocabulary");
        assert(labels.resolve(a.name) == labels.find(a.canonical));
    }
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
