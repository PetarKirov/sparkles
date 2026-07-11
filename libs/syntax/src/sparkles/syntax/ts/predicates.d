/**
Query text predicates: parsing and evaluation.

The tree-sitter C API only $(I records) predicates
(`ts_query_predicates_for_pattern` returns raw step triples) — evaluation is
the caller's job. This module implements the reference highlighter's
text-predicate set:

$(LIST
    * `#eq?` / `#not-eq?` / `#any-eq?` / `#any-not-eq?` — capture text vs a
        literal, or capture vs capture (pairwise);
    * `#match?` / `#not-match?` / `#any-match?` / `#any-not-match?` — capture
        text vs a regex (compiled at parse time via `std.regex`);
    * `#any-of?` / `#not-any-of?` — capture text vs a string set;
    * `#set!` — parsed and stored (settings drive the injection milestone);
    * `#is?` / `#is-not?` — recognized and ignored (`local` recorded for a
        future locals milestone).
)

Anything else (editor-dialect predicates like `#lua-match?`) is reported as
$(D unsupported) — the config layer disables that one pattern with a warning
instead of failing the language: our query supply chain spans dialects, and
a batch highlighter always has the plain-text fallback. The same degrade
posture applies to a regex `std.regex` cannot compile.

The default quantifier over a capture's nodes within one match is ∀ (`all`,
empty set passes); the `any-` forms use ∃ (empty set fails) — the reference
crate's exact semantics.
*/
module sparkles.syntax.ts.predicates;

import std.regex : Regex, matchFirst, regex;

import sparkles.tree_sitter.tree_sitter_c : TSNode, TSQueryMatch,
    TSQueryPredicateStep, TSQueryPredicateStepType, ts_node_end_byte,
    ts_node_start_byte;
import sparkles.tree_sitter.wrappers : TsQuery;

/// One parsed text predicate.
struct TextPredicate
{
    /// Which check to run per captured node.
    enum Kind : ubyte
    {
        eqString,    /// text == `literal`
        eqCapture,   /// text == text of the paired `captureId2` node
        matchRegex,  /// `re` matches somewhere in the text
        anyOfString, /// text ∈ `literals`
    }

    Kind kind;         /// the check
    bool negated;      /// `not-` form: invert the per-node check
    bool anyMode;      /// `any-` form: ∃ over the capture's nodes instead of ∀
    uint captureId;    /// the capture the predicate tests
    uint captureId2;   /// the other capture (kind == eqCapture)
    string literal;    /// kind == eqString
    string[] literals; /// kind == anyOfString
    Regex!char re;     /// kind == matchRegex
}

/// A `#set!` directive (stored for the injection milestone).
struct Setting
{
    string key;
    string value;
}

/// Everything recorded for one query pattern.
struct PatternPredicates
{
    TextPredicate[] predicates; /// must all hold for a match to survive
    Setting[] settings;         /// `#set!` key/value pairs
    bool isNotLocal;            /// `#is-not? local` seen (unused in v1)
}

/// Parse result for one pattern: the predicates plus, when non-empty, the
/// name of an unsupported/malformed predicate (the pattern must be disabled).
struct ParsedPattern
{
    PatternPredicates predicates;
    string unsupported;
}

/// Parses the predicate steps of `patternIndex` (see the module header for
/// the supported set and the degrade rules).
ParsedPattern parsePatternPredicates(ref const TsQuery query, uint patternIndex) @safe
{
    alias StepType = TSQueryPredicateStepType;

    ParsedPattern result;
    const steps = query.predicatesForPattern(patternIndex);

    size_t i = 0;
    while (i < steps.length)
    {
        size_t end = i;
        while (end < steps.length && steps[end].type != StepType.TSQueryPredicateStepTypeDone)
            ++end;
        const group = steps[i .. end];
        i = end + 1;

        if (group.length == 0)
            continue;
        if (group[0].type != StepType.TSQueryPredicateStepTypeString)
        {
            result.unsupported = "(malformed predicate)";
            continue;
        }
        const name = query.stringValue(group[0].value_id);

        bool isCapture(size_t idx)
            => idx < group.length && group[idx].type == StepType.TSQueryPredicateStepTypeCapture;
        bool isString(size_t idx)
            => idx < group.length && group[idx].type == StepType.TSQueryPredicateStepTypeString;
        string stringArg(size_t idx)
            => query.stringValue(group[idx].value_id).idup;

        TextPredicate pred;

        switch (name)
        {
            case "eq?":
            case "not-eq?":
            case "any-eq?":
            case "any-not-eq?":
            {
                if (group.length != 3 || !isCapture(1) || (!isCapture(2) && !isString(2)))
                {
                    result.unsupported = name.idup;
                    break;
                }
                pred.negated = name[0] == 'n' || name == "any-not-eq?";
                pred.anyMode = name[0] == 'a';
                pred.captureId = group[1].value_id;
                if (isCapture(2))
                {
                    pred.kind = TextPredicate.Kind.eqCapture;
                    pred.captureId2 = group[2].value_id;
                }
                else
                {
                    pred.kind = TextPredicate.Kind.eqString;
                    pred.literal = stringArg(2);
                }
                result.predicates.predicates ~= pred;
                break;
            }

            case "match?":
            case "not-match?":
            case "any-match?":
            case "any-not-match?":
            {
                if (group.length != 3 || !isCapture(1) || !isString(2))
                {
                    result.unsupported = name.idup;
                    break;
                }
                pred.kind = TextPredicate.Kind.matchRegex;
                pred.negated = name[0] == 'n' || name == "any-not-match?";
                pred.anyMode = name[0] == 'a';
                pred.captureId = group[1].value_id;
                try
                    pred.re = regex(stringArg(2));
                catch (Exception)
                {
                    // dialect drift (std.regex vs Rust regex): degrade this
                    // one pattern, never the language
                    result.unsupported = name.idup ~ " (regex failed to compile)";
                    break;
                }
                result.predicates.predicates ~= pred;
                break;
            }

            case "any-of?":
            case "not-any-of?":
            {
                if (group.length < 3 || !isCapture(1))
                {
                    result.unsupported = name.idup;
                    break;
                }
                pred.kind = TextPredicate.Kind.anyOfString;
                pred.negated = name[0] == 'n';
                pred.captureId = group[1].value_id;
                bool ok = true;
                foreach (idx; 2 .. group.length)
                {
                    if (!isString(idx))
                    {
                        ok = false;
                        break;
                    }
                    pred.literals ~= stringArg(idx);
                }
                if (!ok)
                {
                    result.unsupported = name.idup;
                    break;
                }
                result.predicates.predicates ~= pred;
                break;
            }

            case "set!":
            {
                // (#set! key value) — both strings; a capture-scoped form
                // exists in some dialects and is stored best-effort.
                if (group.length >= 2 && isString(1))
                    result.predicates.settings ~= Setting(stringArg(1),
                        group.length >= 3 && isString(2) ? stringArg(2) : null);
                break;
            }

            case "is?":
            case "is-not?":
            {
                if (name == "is-not?" && group.length >= 2 && isString(1)
                    && query.stringValue(group[1].value_id) == "local")
                    result.predicates.isNotLocal = true;
                // recognized property predicates; no highlight effect in v1
                break;
            }

            default:
                result.unsupported = name.idup;
                break;
        }
    }
    return result;
}

/// `true` iff every predicate of `pp` holds for `match` (the survival test
/// the highlighter runs before using any capture of the match).
bool satisfies(in PatternPredicates pp, in TSQueryMatch match,
    scope const(char)[] source) @trusted
{
    foreach (ref pred; pp.predicates)
        if (!satisfiesOne(pred, match, source))
            return false;
    return true;
}

private bool satisfiesOne(ref const TextPredicate pred, in TSQueryMatch match,
    scope const(char)[] source) @trusted
{
    import std.algorithm.searching : canFind;

    bool sawAny = false;
    bool allOk = true;
    bool anyOk = false;
    size_t pairOrdinal = 0;

    foreach (ci; 0 .. match.capture_count)
    {
        const capture = match.captures[ci];
        if (capture.index != pred.captureId)
            continue;
        const text = nodeText(cast(TSNode) capture.node, source);

        bool ok;
        final switch (pred.kind)
        {
            case TextPredicate.Kind.eqString:
                ok = (text == pred.literal) != pred.negated;
                break;

            case TextPredicate.Kind.eqCapture:
            {
                // pairwise zip with the other capture's nodes; unpaired
                // nodes are dropped (the reference's zip semantics)
                const(char)[] other;
                bool paired = false;
                size_t seen = 0;
                foreach (cj; 0 .. match.capture_count)
                {
                    const capture2 = match.captures[cj];
                    if (capture2.index != pred.captureId2)
                        continue;
                    if (seen++ == pairOrdinal)
                    {
                        other = nodeText(cast(TSNode) capture2.node, source);
                        paired = true;
                        break;
                    }
                }
                ++pairOrdinal;
                if (!paired)
                    continue;
                ok = (text == other) != pred.negated;
                break;
            }

            case TextPredicate.Kind.matchRegex:
                ok = !matchFirst(text, pred.re).empty != pred.negated;
                break;

            case TextPredicate.Kind.anyOfString:
                ok = pred.literals.canFind(text) != pred.negated;
                break;
        }

        sawAny = true;
        allOk &= ok;
        anyOk |= ok;
    }

    // ∀ over the empty set holds; ∃ does not (reference semantics)
    if (!sawAny)
        return !pred.anyMode;
    return pred.anyMode ? anyOk : allOk;
}

/// The captured node's text (defensively clamped to the source).
package const(char)[] nodeText(TSNode node, return scope const(char)[] source) @trusted nothrow @nogc
{
    const start = cast(size_t) ts_node_start_byte(node);
    const end = cast(size_t) ts_node_end_byte(node);
    const lo = start < source.length ? start : source.length;
    const hi = end < source.length ? end : source.length;
    return lo < hi ? source[lo .. hi] : null;
}
