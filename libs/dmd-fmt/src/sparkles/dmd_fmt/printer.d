/**
The printer — M3/M4 of the dmd-fmt proposal: walk the token spine guided by
the S2 group tree and emit the M2 `Doc` IR.

What this module implements is $(B tier 1) of the two-tier scope fixed in
`docs/specs/dmd-fmt/` (D9): the layout pass, which reformats without touching
the token stream and is therefore always on and verifiable by token equality.
The $(B rewrite tier) around it — trailing-comma insertion on by default,
everything else opt-in and each with its own verifier — is specified in D9 and
catalogued in `docs/research/code-formatting/prettier-decisions.md`; none of it
lives here yet.

Tier 1's policy, stated plainly:
$(B author's-breaks-preserved with structural reindentation) — the paradigm
gofmt proves out, chosen because it is verifiable today and needs no
unary-vs-binary token disambiguation. Concretely:

$(LIST
    * $(B Line structure is the author's): a newline between tokens stays a
        newline, same-line stays same-line. Indentation is recomputed
        structurally — brace nesting, `case`/`default` bodies one level
        deeper, wrapped statements one continuation level (dfmt's
        single-indent style).
    * $(B Horizontal whitespace is normalized): runs collapse to one space,
        zero-space adjacency is preserved (no opinion on `a+b` vs `a + b`),
        trailing whitespace cannot exist (the engine's lazy indent).
    * $(B Blank-line runs collapse) to `maxBlankLines` (M4; the one layout
        feature with empirical support), and are dropped right after an
        opening or before a closing brace.
    * $(B The magic trailing comma) (M4): a list whose author wrote a
        trailing comma is pinned one-element-per-line; without one, a list
        too wide for `softMaxLineLength` explodes via the greedy engine.
        Read, never written: writing it is the one default-on rewrite D9
        schedules, and it belongs to tier 2, not to this pass.
    * $(B Verbatim by default) (M3's do-no-harm valve): `// dfmt off` …
        `// dfmt on` ranges and `asm { … }` bodies are emitted
        byte-for-byte; `#line`/shebang directives, the `__EOF__` tail, the
        BOM, and every single-entry construct (`q{}`, delimited/hex/
        interpolated strings, comments — no reflow, DDoc included) pass
        through untouched.
)

Every output is checkable with [sparkles.dmd_fmt.verify]: the tests here
run `verifyFormat` + `checkConvergence` on each golden.
*/
module sparkles.dmd_fmt.printer;

import sparkles.dmd_fmt.config : FormatConfig;
import sparkles.dmd_fmt.doc;
import sparkles.dmd_fmt.groups : buildGroups, Group, GroupKind;
import sparkles.dmd_fmt.oracle : collectFacts;
import sparkles.dmd_fmt.spine : lexSpine, SpineClass, TokenSpine;

import dmd.tokens : TOK;

/**
Format `source`. Never fails: unparseable input degrades to bracket-only
structure (the oracle returns what parsed), and unmodelled constructs pass
through verbatim.
*/
string formatText(const(char)[] source, FormatConfig cfg = FormatConfig()) @system
{
    auto spine = lexSpine(source);
    auto facts = collectFacts(source);
    auto root = buildGroups(spine, facts);

    auto printer = new Printer(spine, cfg);
    auto doc = printer.buildDocument(root);

    RenderOptions opt = {
        width: cfg.softMaxLineLength,
        indentSize: cfg.indentSize,
        useTabs: cfg.useTabs,
        tabWidth: cfg.tabWidth,
    };
    auto result = layout(doc, opt);
    if (cfg.insertFinalNewline && result.length &&
        result[$ - 1] != '\n' && spine.tailStart == spine.source.length)
        result ~= '\n';
    return result;
}

private final class Printer
{
    TokenSpine spine;
    FormatConfig cfg;
    bool[] suppressed; // per spine entry: emit verbatim, do not restructure

    this(TokenSpine spine, FormatConfig cfg) @safe
    {
        this.spine = spine;
        this.cfg = cfg;
        computeSuppression();
    }

    // ---- suppression (M3 valve / M6 single mechanism) ---------------------

    private void computeSuppression() @safe
    {
        suppressed = new bool[](spine.entries.length);

        bool off;
        foreach (i, t; spine.entries)
        {
            if (t.cls == SpineClass.comment)
            {
                const directive = commentDirective(entryText(i));
                if (directive == "dfmt off")
                    off = true;
                if (off)
                    suppressed[i] = true;
                if (directive == "dfmt on")
                    off = false;
                continue;
            }
            if (off)
                suppressed[i] = true;
        }

        // asm bodies: from the keyword, the whole following brace span.
        foreach (i, t; spine.entries)
            if (t.kind == TOK.asm_ && t.cls == SpineClass.token)
            {
                size_t j = i + 1;
                while (j < spine.entries.length &&
                    spine.entries[j].kind != TOK.leftCurly)
                    j++;
                int depth;
                for (; j < spine.entries.length; j++)
                {
                    const k = spine.entries[j].kind;
                    if (k == TOK.leftCurly)
                        depth++;
                    else if (k == TOK.rightCurly && --depth == 0)
                    {
                        suppressed[i + 1 .. j + 1] = true;
                        break;
                    }
                    suppressed[j] = true;
                }
            }
    }

    private const(char)[] entryText(size_t entry) const @safe
        => spine.source[spine.entries[entry].start .. spine.entries[entry].end];

    private static const(char)[] commentDirective(const(char)[] comment) @safe
    {
        import std.string : strip;

        if (comment.length >= 2 && comment[0 .. 2] == "//")
            return comment[2 .. $].strip;
        if (comment.length >= 4 &&
            (comment[0 .. 2] == "/*" || comment[0 .. 2] == "/+"))
            return comment[2 .. $ - 2].strip;
        return null;
    }

    // ---- item collection --------------------------------------------------

    private enum ItemKind : ubyte
    {
        token,
        comment,
        directive,   // #line / shebang: verbatim + line break
        verbatimRun, // suppressed range: exact original bytes
        child,       // a nested Group
    }

    private struct Item
    {
        ItemKind kind;
        size_t index;      // entry index, or child index for `child`
        uint runStart, runEnd; // byte range for verbatimRun
        int newlinesBefore;
        bool spaceBefore;
        uint gapStart, gapEnd; // byte range of the preceding whitespace gap
    }

    /// The visible items of `g`'s interior (`[from, to]`), with each item's
    /// preceding-gap summary. Children are opaque; suppressed entries are
    /// coalesced into verbatim runs (absorbing any intersecting child).
    private Item[] collectItems(const Group g, size_t from, size_t to) @safe
    {
        Item[] items;
        int newlines;
        bool space;
        uint gapStart = uint.max, gapEnd;
        size_t child;

        void gapEntry(size_t i) @safe
        {
            foreach (ch; entryText(i))
                if (ch == '\n')
                    newlines++;
            space = true;
            if (gapStart == uint.max)
                gapStart = spine.entries[i].start;
            gapEnd = spine.entries[i].end;
        }

        void resetGap() @safe
        {
            newlines = 0;
            space = false;
            gapStart = uint.max;
            gapEnd = 0;
        }

        for (size_t i = from; i <= to && i < spine.entries.length;)
        {
            // A child group starting here is one opaque item — unless it
            // begins inside a suppressed range, handled below.
            if (child < g.children.length && g.children[child].firstEntry == i
                && !suppressed[i])
            {
                items ~= Item(ItemKind.child, child, 0, 0, newlines, space,
                    gapStart == uint.max ? 0 : gapStart, gapEnd);
                resetGap();
                i = g.children[child].lastEntry + 1;
                child++;
                continue;
            }
            const t = spine.entries[i];
            if (suppressed[i])
            {
                // Coalesce the run, absorbing intersecting children.
                const runStart = t.start;
                size_t j = i;
                while (j + 1 <= to && j + 1 < spine.entries.length &&
                    suppressed[j + 1])
                    j++;
                while (child < g.children.length &&
                    g.children[child].firstEntry <= j)
                    child++;
                items ~= Item(ItemKind.verbatimRun, i, runStart,
                    spine.entries[j].end, newlines, space,
                    gapStart == uint.max ? 0 : gapStart, gapEnd);
                resetGap();
                i = j + 1;
                continue;
            }
            if (t.cls == SpineClass.whitespace)
            {
                gapEntry(i);
                i++;
                continue;
            }
            const kind = t.cls == SpineClass.comment ? ItemKind.comment
                : t.cls == SpineClass.directive ? ItemKind.directive
                : ItemKind.token;
            items ~= Item(kind, i, 0, 0, newlines, space,
                gapStart == uint.max ? 0 : gapStart, gapEnd);
            resetGap();
            i++;
        }
        return items;
    }

    // ---- document ---------------------------------------------------------

    Doc buildDocument(const Group root) @safe
    {
        Doc[] parts;
        if (spine.prefixEnd)
            parts ~= verbatim(spine.source[0 .. spine.prefixEnd].idup);

        const items = collectItems(root, root.firstEntry,
            spine.entries.length ? spine.entries.length - 1 : 0);
        parts ~= buildStatements(root, items);

        // The unlexed tail (__EOF__ …) is byte-verbatim; reattach it with
        // the author's separator.
        if (spine.tailStart < spine.source.length)
        {
            const trailingGap = trailingGapNewlines();
            if (trailingGap > 0)
                parts ~= hardline;
            else if (trailingGap == 0 && spine.entries.length)
                parts ~= text(" ");
            parts ~= verbatim(spine.source[spine.tailStart .. $].idup);
        }
        return sequence(parts);
    }

    private int trailingGapNewlines() const @safe
    {
        int n;
        foreach_reverse (i, t; spine.entries)
        {
            if (t.cls != SpineClass.whitespace)
                break;
            foreach (ch; entryText(i))
                if (ch == '\n')
                    n++;
        }
        return n;
    }

    // ---- containers -------------------------------------------------------

    private Doc buildGroupDoc(const Group g) @safe
    {
        final switch (g.kind)
        {
            case GroupKind.document:
                assert(false, "document is built once, at the top");
            case GroupKind.body_:
                return buildBraceContainer(g);
            case GroupKind.brackets:
                const open = spine.entries[g.firstEntry].kind;
                if (open == TOK.leftCurly)
                    return buildBraceContainer(g);
                return buildParenContainer(g);
            case GroupKind.templateParams, GroupKind.runtimeParams:
                return buildParenContainer(g);
            case GroupKind.decl, GroupKind.constraint, GroupKind.inContract,
                GroupKind.outContract:
                return buildClauseContainer(g);
        }
    }

    /// decl and clause groups: the author's newlines become hardlines —
    /// at the declaration's own column before a clause or body child (the
    /// D clause style), one continuation level deeper anywhere else (a
    /// wrapped `=>` body, a wrapped attribute run).
    private Doc buildClauseContainer(const Group g) @safe
    {
        const items = collectItems(g, g.firstEntry, g.lastEntry);
        Doc[] parts;
        Doc[] cont;
        bool inCont;

        void closeCont() @safe
        {
            if (cont.length)
                parts ~= indented(cont);
            cont = null;
            inCont = false;
        }

        foreach (i, item; items)
        {
            const baseLevel = (item.kind == ItemKind.child &&
                isClauseOrBody(g.children[item.index]))
                || inAttributePrefix(g, items, i);
            if (i != 0 && item.newlinesBefore > 0)
            {
                if (baseLevel)
                {
                    closeCont();
                    parts ~= hardline;
                }
                else
                {
                    inCont = true;
                    cont ~= hardline;
                }
            }
            else if (i != 0 && item.spaceBefore)
            {
                const gap = spine.source[item.gapStart .. item.gapEnd];
                (inCont ? cont : parts) ~=
                    item.kind == ItemKind.comment && gap.length > 1
                        ? text(gap.idup) : text(" ");
            }
            (inCont ? cont : parts) ~= buildItem(g, item);
        }
        closeCont();
        return sequence(parts);
    }

    /// Is everything before `upto` still the declaration's leading attribute
    /// run — UDAs (`@name`, `@name(args)`) and attribute keywords? A break
    /// there is the author separating attributes from what they modify, and D
    /// puts both at the same column:
    ///
    ///     @("case.name")
    ///     @safe unittest
    ///
    /// A break *after* the head has started is a genuine continuation and
    /// still indents. Without this, every declaration carrying a UDA on its
    /// own line had its head silently pushed one level right.
    private bool inAttributePrefix(const Group g, const Item[] items,
        size_t upto) const @safe
    {
        // `@` opens a UDA: `@name`, `@name(args)` and `@(args)` are all
        // legal, so a `(` child belongs to the UDA whether or not a name
        // came first.
        bool udaOpen;
        bool expectName;
        foreach (item; items[0 .. upto])
        {
            if (item.kind == ItemKind.comment)
                continue;
            if (item.kind == ItemKind.child)
            {
                if (!udaOpen || spine.entries[g.children[item.index]
                        .firstEntry].kind != TOK.leftParenthesis)
                    return false;
                udaOpen = expectName = false;
                continue;
            }
            if (item.kind != ItemKind.token)
                return false;
            const kind = spine.entries[item.index].kind;
            if (kind == TOK.at)
            {
                udaOpen = expectName = true;
                continue;
            }
            if (expectName && kind == TOK.identifier)
            {
                expectName = false;
                continue;
            }
            if (!isAttributeKeyword(kind))
                return false;
            udaOpen = expectName = false;
        }
        return true;
    }

    private static bool isAttributeKeyword(TOK kind) @safe pure nothrow @nogc
    {
        switch (kind)
        {
            case TOK.abstract_, TOK.align_, TOK.auto_, TOK.const_,
                TOK.deprecated_, TOK.export_, TOK.extern_, TOK.final_,
                TOK.gshared, TOK.immutable_, TOK.inout_, TOK.nothrow_,
                TOK.override_, TOK.package_, TOK.private_, TOK.protected_,
                TOK.public_, TOK.pure_, TOK.ref_, TOK.scope_, TOK.shared_,
                TOK.static_, TOK.synchronized_:
                return true;
            default:
                return false;
        }
    }

    private bool isClauseOrBody(const Group child) const @safe
    {
        final switch (child.kind)
        {
            case GroupKind.constraint, GroupKind.inContract,
                GroupKind.outContract, GroupKind.body_:
                return true;
            case GroupKind.brackets:
                // An aggregate body inside a template declaration is a plain
                // brace child (aggregates have no fbody marker); its Allman
                // `{` sits at the declaration's column, not a continuation.
                return spine.entries[child.firstEntry].kind == TOK.leftCurly;
            case GroupKind.document, GroupKind.decl,
                GroupKind.templateParams, GroupKind.runtimeParams:
                return false;
        }
    }

    /// Whether the group's final entry really is `closer` (broken input
    /// leaves groups unclosed at end of input; the printer must never
    /// invent the missing token).
    private bool hasCloser(const Group g, TOK closer) const @safe
        => g.lastEntry > g.firstEntry &&
            spine.entries[g.lastEntry].kind == closer &&
            !suppressed[g.lastEntry];

    /// `{ … }` — a statement container.
    private Doc buildBraceContainer(const Group g) @safe
    {
        const closed = hasCloser(g, TOK.rightCurly);
        if (!closed)
        {
            // Unclosed at end of input: emit what exists, invent nothing.
            const rest = collectItems(g, g.firstEntry + 1, g.lastEntry);
            return sequence([text("{")]
                ~ [indented(buildStatements(g, rest))]);
        }
        const items = collectItems(g, g.firstEntry + 1,
            g.lastEntry > g.firstEntry ? g.lastEntry - 1 : g.firstEntry);
        const multiline = itemsSpanLines(items) || closerOnOwnLine(g);
        if (!multiline)
        {
            Doc[] parts = [text("{")];
            foreach (piece; joinInline(g, items, false))
                parts ~= piece;
            if (items.length)
                parts = [text("{"), text(" ")]
                    ~ joinInline(g, items, false) ~ [text(" ")];
            parts ~= text("}");
            return sequence(parts);
        }
        if (!items.length)
            // An empty body the author spread over two lines keeps that
            // shape — but `{` and `}` are then adjacent lines, not a block
            // with a blank one between them.
            return sequence(text("{"), hardline, text("}"));
        return sequence(text("{"),
            indented(hardline, buildStatements(g, items)),
            hardline, text("}"));
    }

    /// Did the author break the line immediately after the opener? A `(`/`[`
    /// container emits no break of its own before its first item, so without
    /// this the break is silently swallowed and the first item — often a
    /// `// dfmt off` marker or a leading comment — lands beside the bracket.
    private static bool opensOnOwnLine(const Item[] items) @safe
        => items.length > 0 && items[0].newlinesBefore > 0;

    private bool itemsSpanLines(const Item[] items) const @safe
    {
        foreach (item; items)
            if (item.newlinesBefore > 0)
                return true;
        return false;
    }

    private bool closerOnOwnLine(const Group g) const @safe
    {
        // Whitespace entries directly before the closing entry.
        foreach_reverse (i; g.firstEntry + 1 .. g.lastEntry)
        {
            const t = spine.entries[i];
            if (t.cls != SpineClass.whitespace)
                return false;
            foreach (ch; entryText(i))
                if (ch == '\n')
                    return true;
        }
        return false;
    }

    /// `( … )` / `[ … ]` — a list when it has top-level commas, otherwise
    /// an inline span with continuation indentation for author breaks.
    private Doc buildParenContainer(const Group g) @safe
    {
        const openText = entryText(g.firstEntry).idup;
        const closerTok = spine.entries[g.firstEntry].kind == TOK.leftParenthesis
            ? TOK.rightParenthesis : TOK.rightBracket;
        if (!hasCloser(g, closerTok))
        {
            const rest = collectItems(g, g.firstEntry + 1, g.lastEntry);
            return sequence([text(openText)]
                ~ [indented(joinInline(g, rest, true, opensOnOwnLine(rest)))]);
        }
        const closeText = entryText(g.lastEntry).idup;
        const items = collectItems(g, g.firstEntry + 1,
            g.lastEntry > g.firstEntry ? g.lastEntry - 1 : g.firstEntry);

        size_t commas;
        foreach (item; items)
            if (item.kind == ItemKind.token &&
                spine.entries[item.index].kind == TOK.comma)
                commas++;
        if (commas == 0)
        {
            if (!items.length)
                return sequence(text(openText), text(closeText));
            return sequence(text(openText),
                indented(joinInline(g, items, true, opensOnOwnLine(items))),
                itemsSpanLines(items) || closerOnOwnLine(g)
                    ? sequence(closerOnOwnLine(g)
                        ? [hardline, text(closeText)] : [text(closeText)])
                    : text(closeText));
        }
        return buildList(g, items, openText, closeText);
    }

    private Doc buildList(const Group g, const Item[] items, string openText,
        string closeText) @safe
    {
        // Split into elements at top-level commas.
        static struct Element
        {
            Item[] run;
            int newlinesAfterComma; // the gap following this element's comma
        }

        Element[] elements;
        Item[] run;
        bool trailingComma;
        foreach (i, item; items)
        {
            if (item.kind == ItemKind.token &&
                spine.entries[item.index].kind == TOK.comma)
            {
                const nlAfter = i + 1 < items.length
                    ? items[i + 1].newlinesBefore : 0;
                elements ~= Element(run, nlAfter);
                run = null;
                trailingComma = i + 1 == items.length ||
                    allTrailingComments(items[i + 1 .. $]);
                continue;
            }
            run ~= item;
        }
        const(Item)[] trailingComments;
        if (run.length && !allTrailingComments(run))
            elements ~= Element(run, 0);
        else if (run.length)
        {
            // Comments after the trailing comma must stay AFTER it — merged
            // into the last element they would precede the comma we emit,
            // and a `//` comment would then swallow it on re-lex (caught by
            // the M8 corpus triad on base/term_style.d).
            trailingComments = run;
        }

        Doc[] inner;
        if (trailingComma)
        {
            // The magic trailing comma (M4): canonical one-per-line.
            foreach (i, elem; elements)
            {
                if (i != 0)
                    inner ~= hardline;
                foreach (piece; joinInline(g, elem.run, false, false, true))
                    inner ~= piece;
                inner ~= text(",");
            }
            foreach (item; trailingComments)
            {
                inner ~= text(" ");
                inner ~= buildItem(g, item);
            }
            return sequence(text(openText), indented([hardline] ~ inner),
                hardline, text(closeText));
        }

        if (itemsSpanLines(items))
        {
            // The author already chose a multi-line shape: preserve it
            // exactly (commas, breaks and comments where they were), under
            // one continuation level. Flattening is off the table — it
            // would also let a `//` comment swallow the rest of the line.
            return sequence(text(openText),
                indented(joinInline(g, items, false, opensOnOwnLine(items),
                    true)),
                closerOnOwnLine(g) ? sequence(hardline, text(closeText))
                    : text(closeText));
        }

        // Single-line as written: keep flat while it fits, explode past
        // softMaxLineLength via the greedy group. An author-aligned gap
        // after a comma is preserved verbatim (and is then not a wrap
        // point: aligned rows are deliberate layout).
        foreach (i, elem; elements)
        {
            if (i != 0)
            {
                const(char)[] gap;
                if (elem.run.length && elem.run[0].newlinesBefore == 0)
                    gap = spine.source[elem.run[0].gapStart
                        .. elem.run[0].gapEnd];
                inner ~= gap.length > 1 ? text(gap.idup) : line;
            }
            foreach (piece; joinInline(g, elem.run, false, false, true))
                inner ~= piece;
            if (i + 1 < elements.length)
                inner ~= text(",");
        }
        return group([text(openText),
            indented([softline()] ~ inner), softline, text(closeText)]);
    }

    private bool allTrailingComments(const Item[] items) const @safe
    {
        foreach (item; items)
            if (item.kind != ItemKind.comment)
                return false;
        return items.length > 0;
    }

    // ---- statements -------------------------------------------------------

    /// The statement layout of a container's interior: statements separated
    /// by hardlines (blank runs collapsed), `case`/`default` bodies bumped
    /// one level, wrapped statements getting one continuation level.
    private const(Group)[] currentChildren;

    private Doc buildStatements(const Group g, const Item[] items) @safe
    {
        const savedChildren = currentChildren;
        currentChildren = g.children;
        scope (exit)
            currentChildren = savedChildren;

        static struct Stmt
        {
            Item[] run;
            int blanksBefore;
            bool sameLine;   // continues the previous statement's line
            bool caseLabel;  // `case …:` / `default:`
        }

        Stmt[] stmts;
        Item[] run;
        bool caseLabel;
        bool expectColonEnd;
        int ternaryDepth;
        TOK prevToken = TOK.reserved;

        void flush() @safe
        {
            if (!run.length)
                return;
            const first = run[0];
            stmts ~= Stmt(run,
                first.newlinesBefore > 1
                    ? min(first.newlinesBefore - 1, cfg.maxBlankLines) : 0,
                stmts.length > 0 && first.newlinesBefore == 0,
                caseLabel);
            run = null;
            caseLabel = false;
            expectColonEnd = false;
        }

        foreach (item; items)
        {
            // A comment or directive starting its own line while a statement
            // is in flight belongs to the statement's continuation; on a
            // fresh line with no statement open, it is its own unit.
            if (run.length && item.newlinesBefore == 0 &&
                (item.kind == ItemKind.comment))
            {
                run ~= item;
                continue;
            }
            if (!run.length &&
                (item.kind == ItemKind.comment || item.kind == ItemKind.directive
                    || item.kind == ItemKind.verbatimRun))
            {
                run ~= item;
                flush();
                continue;
            }
            if (run.length == 0 && item.kind == ItemKind.token)
            {
                const k = spine.entries[item.index].kind;
                if (k == TOK.case_ || k == TOK.default_)
                {
                    expectColonEnd = true;
                    caseLabel = true;
                }
            }
            if (item.kind == ItemKind.token)
            {
                const k = spine.entries[item.index].kind;
                if (k == TOK.question)
                    ternaryDepth++;
            }
            const terminated = isTerminator(item, expectColonEnd,
                ternaryDepth, prevToken);
            if (item.kind == ItemKind.token)
                prevToken = spine.entries[item.index].kind;
            run ~= item;
            if (terminated)
                flush();
        }
        flush();

        // Emit, bumping the statements after a case label one level until
        // the next label.
        Doc[] parts;
        Doc[] bumped;
        bool bumping;

        void endBump() @safe
        {
            if (bumping && bumped.length)
                parts ~= indented(bumped);
            bumped = null;
            bumping = false;
        }

        foreach (i, stmt; stmts)
        {
            if (stmt.caseLabel)
                endBump();
            auto target = bumping ? &bumped : &parts;
            if (i != 0 && !stmt.sameLine)
            {
                *target ~= hardline;
                foreach (_; 0 .. stmt.blanksBefore)
                    *target ~= hardline;
            }
            else if (i != 0)
            {
                // Same-line join: keep an author-aligned comment's gap.
                const first = stmt.run[0];
                const gap = spine.source[first.gapStart .. first.gapEnd];
                *target ~= first.kind == ItemKind.comment && gap.length > 1
                    ? text(gap.idup) : text(" ");
            }
            foreach (piece; buildStatement(g, stmt.run))
                *target ~= piece;
            if (stmt.caseLabel)
                bumping = true;
        }
        endBump();
        return sequence(parts);
    }

    private bool isTerminator(const Item item, bool expectColonEnd,
        ref int ternaryDepth, TOK prevToken) const @safe
    {
        if (item.kind == ItemKind.child)
        {
            // Only brace-bodied children end a statement; a parameter list
            // or a parenthesized condition is mid-statement — and so is an
            // expression brace (a struct initializer or lambda body after
            // `=`, `(`, `,`, `return` or `=>`).
            const child = &currentChildren[item.index];
            if (child.kind == GroupKind.decl || child.kind == GroupKind.body_)
                return true;
            if (child.kind != GroupKind.brackets ||
                spine.entries[child.firstEntry].kind != TOK.leftCurly)
                return false;
            switch (prevToken)
            {
                case TOK.assign, TOK.comma, TOK.leftParenthesis,
                    TOK.leftBracket, TOK.return_, TOK.goesTo:
                    return false;
                default:
                    return true;
            }
        }
        if (item.kind != ItemKind.token)
            return false;
        const k = spine.entries[item.index].kind;
        if (expectColonEnd)
            return k == TOK.colon;
        if (k == TOK.colon)
        {
            // An attribute/label statement (`pure nothrow @nogc:`,
            // `private:`, `retry:`) ends at its colon — but a ternary's
            // colon belongs to its pending `?`.
            if (ternaryDepth > 0)
            {
                ternaryDepth--;
                return false;
            }
            return true;
        }
        return k == TOK.semicolon || k == TOK.comma || k == TOK.rightCurly;
    }

    /// One statement: inline joining with a single continuation level for
    /// the author's wrapped lines. A trailing brace-bodied child that starts
    /// its own line (an Allman `{`) sits at the statement's indent, outside
    /// the continuation scope.
    private Doc[] buildStatement(const Group g, const Item[] run) @safe
    {
        size_t tail = run.length;
        if (run.length && run[$ - 1].kind == ItemKind.child &&
            run[$ - 1].newlinesBefore > 0 && braceBodied(g, run[$ - 1]))
            tail = run.length - 1;

        Doc[] parts = buildStatementRun(g, run[0 .. tail], true);
        if (tail < run.length)
            parts ~= [hardline, buildItem(g, run[$ - 1])];
        return parts;
    }

    /**
    One statement's items under the author's breaks.

    The first break opens a continuation level. A break that follows a
    $(B clause header) — `if (…)`, `foreach (…)`, a bare `else` — opens
    another, because what comes after it is that clause's body rather than
    the rest of the same expression:

    ---
    foreach (i; 0 .. n)
        if (i == 3)
            return true;
    ---

    Every other break stays at the level the first one opened, however many
    times it happens, which is v1's one-continuation-level policy — a wrapped
    expression or a member chain steps right once, not once per line.
    */
    private Doc[] buildStatementRun(const Group g, const Item[] run,
        bool atStatementStart) @safe
    {
        // A break inside the statement's leading attribute run is the author
        // separating `@uda` from what it modifies; those stay at the
        // statement's own level, and only the outermost run has one.
        size_t brk = size_t.max;
        foreach (i, item; run)
            if (i != 0 && item.newlinesBefore > 0
                && !(atStatementStart && inAttributePrefix(g, run, i)))
            {
                brk = i;
                break;
            }
        if (brk == size_t.max)
            return joinInline(g, run, false);

        const head = run[0 .. brk];
        auto parts = joinInline(g, head, false);
        if (endsClauseHeader(g, head))
            return parts ~ [indented([hardline]
                ~ buildStatementRun(g, run[brk .. $], false))];
        // An own-line comment annotates what follows it; the two are siblings
        // at one level, not a wrap and its continuation. Without this, a
        // comment between a clause header and its body pushes the body right.
        if (startsOwnLineComment(head[$ - 1]))
            return parts ~ [hardline]
                ~ buildStatementRun(g, run[brk .. $], false);
        return parts ~ [indented(joinInline(g, run[brk .. $], false,
            /*leadingBreak*/ true))];
    }

    /// A comment that began its own line — as opposed to one trailing code,
    /// where the break after it really is a wrap.
    private static bool startsOwnLineComment(const Item item) @safe pure nothrow @nogc
        => item.kind == ItemKind.comment && item.newlinesBefore > 0;

    /// Does `head` end with a clause header — `if (…)`, `foreach (…)`, or a
    /// bare `else`/`do`/`try`? A call ends with a parenthesis too, so the
    /// keyword before it is what distinguishes `if (c)` from `foo(c)`.
    private bool endsClauseHeader(const Group g, const Item[] head) const @safe
    {
        if (!head.length)
            return false;
        const last = head[$ - 1];
        if (last.kind == ItemKind.token)
        {
            const k = spine.entries[last.index].kind;
            return k == TOK.else_ || k == TOK.do_ || k == TOK.try_;
        }
        if (last.kind != ItemKind.child || head.length < 2)
            return false;
        if (spine.entries[g.children[last.index].firstEntry].kind
                != TOK.leftParenthesis)
            return false;
        const before = head[$ - 2];
        return before.kind == ItemKind.token
            && isClauseKeyword(spine.entries[before.index].kind);
    }

    /// The keywords whose body may be a bare statement rather than a braced
    /// block, and whose header therefore nests what follows it.
    private static bool isClauseKeyword(TOK kind) @safe pure nothrow @nogc
    {
        switch (kind)
        {
            case TOK.catch_, TOK.debug_, TOK.for_, TOK.foreach_,
                TOK.foreach_reverse_, TOK.if_, TOK.scope_, TOK.switch_,
                TOK.synchronized_, TOK.version_, TOK.while_, TOK.with_:
                return true;
            default:
                return false;
        }
    }

    private bool braceBodied(const Group g, const Item item) const @safe
    {
        const child = &g.children[item.index];
        return child.kind == GroupKind.body_ ||
            (child.kind == GroupKind.brackets &&
                spine.entries[child.firstEntry].kind == TOK.leftCurly);
    }

    /// Inline joining: author newlines become hardlines (optionally under a
    /// continuation indent applied by the caller), horizontal gaps become
    /// one space, adjacency stays tight.
    private Doc[] joinInline(const Group g, const Item[] items,
        bool continuationIndent, bool leadingBreak = false,
        bool preserveAlignment = false) @safe
    {
        Doc[] parts;
        foreach (i, item; items)
        {
            if (i == 0 && leadingBreak)
            {
                // The author broke the line right after the opener. Keep the
                // break (v1's first policy bullet: a newline between tokens
                // stays a newline) but not the blank lines — a blank at a
                // container's edge is dropped, as it is after `{`.
                parts ~= hardline;
            }
            else if (i != 0)
            {
                if (item.newlinesBefore > 0)
                {
                    parts ~= hardline;
                    const blanks = item.newlinesBefore > 1
                        ? min(item.newlinesBefore - 1, cfg.maxBlankLines) : 0;
                    foreach (_; 0 .. blanks)
                        parts ~= hardline;
                }
                else if (item.spaceBefore)
                {
                    // v1 has no alignment engine, so it must not destroy the
                    // author's: a same-line gap wider than one space is kept
                    // verbatim before a comment anywhere, and before
                    // anything inside a list element (aligned table
                    // literals). Statements still normalize to one space.
                    const gap = spine.source[item.gapStart .. item.gapEnd];
                    const keep = gap.length > 1 &&
                        (item.kind == ItemKind.comment || preserveAlignment);
                    parts ~= keep ? text(gap.idup) : text(" ");
                }
            }
            parts ~= buildItem(g, item);
        }
        if (continuationIndent) {} // reserved: v1 applies it at call sites
        return parts;
    }

    private Doc buildItem(const Group g, const Item item) @safe
    {
        final switch (item.kind)
        {
            case ItemKind.token:
                return tokenDoc(item.index);
            case ItemKind.comment:
                return tokenDoc(item.index);
            case ItemKind.directive:
            {
                auto t = entryText(item.index).idup;
                const trimmed = t.length && t[$ - 1] == '\n' ? t[0 .. $ - 1] : t;
                return sequence(verbatim(trimmed), hardline);
            }
            case ItemKind.verbatimRun:
                return verbatim(
                    spine.source[item.runStart .. item.runEnd].idup);
            case ItemKind.child:
                return buildGroupDoc(g.children[item.index]);
        }
    }

    private Doc tokenDoc(size_t entry) @safe
    {
        auto t = entryText(entry).idup;
        foreach (ch; t)
            if (ch == '\n')
                return verbatim(t); // multi-line literals/comments: untouched
        return .text(t);
    }

    private static int min(int a, int b) @safe pure nothrow @nogc
        => a < b ? a : b;
}

// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.dmd_fmt.verify : checkConvergence, verifyFormat;

    /// Format, assert the golden, and prove safety + idempotence.
    private void checkFormat(string source, string expected,
        FormatConfig cfg = FormatConfig(),
        string file = __FILE__, size_t line = __LINE__) @system
    {
        import core.exception : AssertError;

        const got = formatText(source, cfg);
        if (got != expected)
            throw new AssertError("formatted output differs:\n" ~ got, file, line);
        const report = verifyFormat(source, got);
        if (!report.ok)
            throw new AssertError(
                report.tokenError ~ report.ddocError, file, line);
        const conv = checkConvergence(
            (const(char)[] s) => cast(const(char)[]) formatText(s, cfg), source);
        if (!conv.converged || conv.error !is null)
            throw new AssertError("did not converge: " ~ conv.error, file, line);
    }
}

@("printer.reindent.structural")
@system unittest
{
    checkFormat("void f(){\nint x=1;\n   if(x>0){\nx=2;\n}\n}\n",
        "void f(){\n    int x=1;\n    if(x>0){\n        x=2;\n    }\n}\n");
}

@("printer.blank-lines.collapse-to-max")
@system unittest
{
    checkFormat("int a;\n\n\n\n\nint b;\n", "int a;\n\n\nint b;\n");
    FormatConfig one = {maxBlankLines: 1};
    checkFormat("int a;\n\n\n\n\nint b;\n", "int a;\n\nint b;\n", one);
}

@("printer.magic-trailing-comma.pins-one-per-line")
@system unittest
{
    checkFormat("auto a = [\n    1, 2,\n];\n",
        "auto a = [\n    1,\n    2,\n];\n");
    // Without the comma, a fitting list stays as written.
    checkFormat("auto b = f(x, y);\n", "auto b = f(x, y);\n");
}

@("printer.width.list-explodes-past-soft-max")
@system unittest
{
    FormatConfig narrow = {softMaxLineLength: 80};
    checkFormat(
        "void g()\n{\n    callWithLongName(argumentOne, argumentTwo, "
        ~ "argumentThree, argumentFour, five);\n}\n",
        "void g()\n{\n    callWithLongName(\n        argumentOne,\n"
        ~ "        argumentTwo,\n        argumentThree,\n        argumentFour,\n"
        ~ "        five\n    );\n}\n", narrow);
}

@("printer.case-bodies.bump-one-level")
@system unittest
{
    enum src = "void f(int x)\n{\n    switch (x)\n    {\n        case 1:\n"
        ~ "            g();\n            break;\n        default:\n"
        ~ "            break;\n    }\n}\n";
    checkFormat(src, src); // already formatted: fixed point
}

@("printer.continuation.single-level")
@system unittest
{
    enum src = "void f()\n{\n    auto x = aaa +\n        bbb;\n}\n";
    checkFormat(src, src);
}

@("printer.decl.clauses-at-declaration-column")
@system unittest
{
    enum src = "auto tr(T)(T a)\nif (isX!T)\nin (a > 0)\n{\n    return a;\n}\n";
    checkFormat(src, src);
}

@("printer.suppression.dfmt-off-preserves-bytes")
@system unittest
{
    enum src = "int a;\n// dfmt off\nint    weird   =    1;\n// dfmt on\nint b;\n";
    checkFormat(src, src);
}

@("printer.suppression.dfmt-off-marker-keeps-its-own-line")
@system unittest
{
    // A `(`/`[` container emits no break of its own before its first item, so
    // an author break after the opener used to be swallowed — which pulled a
    // leading `// dfmt off` up beside the bracket and made the marker read as
    // if it applied to the opener.
    enum src = "enum t = [\n    // dfmt off\n    1,   2,\n"
        ~ "    // dfmt on\n];\n";
    checkFormat(src, src);
}

@("printer.brackets.author-break-after-opener-survives")
@system unittest
{
    // The same defect, in its general form: v1's first policy bullet is that a
    // newline between tokens stays a newline.
    checkFormat("auto x = foo(\n    a + b);\n", "auto x = foo(\n    a + b);\n");
    checkFormat("auto y = [\n    1, 2,\n    3, 4];\n",
        "auto y = [\n    1, 2,\n    3, 4];\n");
    checkFormat("auto z = foo(\n    // note\n    a);\n",
        "auto z = foo(\n    // note\n    a);\n");
    // A single-line list is still laid out by the engine, not pinned.
    checkFormat("auto v = foo(a, b);\n", "auto v = foo(a, b);\n");
}

@("printer.brackets.blank-line-after-opener-is-dropped")
@system unittest
{
    // Blank lines at a container's edge go, exactly as they do after `{`.
    checkFormat("auto w = [\n\n    1, 2];\n", "auto w = [\n    1, 2];\n");
}

@("printer.suppression.asm-body-verbatim")
@system unittest
{
    enum src = "void f()\n{\n    asm {  mov  EAX,  1 ;  }\n}\n";
    checkFormat(src, src);
}

@("printer.brace-styles.preserved-not-imposed")
@system unittest
{
    enum src = "void a()\n{\n    return;\n}\nvoid b() {\n    return;\n}\n";
    checkFormat(src, src);
}

@("printer.verbatim-constructs.untouched")
@system unittest
{
    enum src = "auto s = q{ int nested;  { tokens } };\n"
        ~ "auto t = q\"EOS\nkeep   me\nEOS\";\n"
        ~ "/** doc\n *  kept */\nvoid f();\n";
    checkFormat(src, src);
}

@("printer.broken-input.never-fails")
@system unittest
{
    // Unparseable input still formats (bracket-only structure) and verifies.
    enum src = "void f( {\nint x = ;\n";
    const got = formatText(src);
    const report = verifyFormat(src, got);
    assert(report.ok, report.tokenError ~ report.ddocError);
}

@("printer.final-newline.inserted-when-missing")
@system unittest
{
    checkFormat("int a;", "int a;\n");
    FormatConfig off = {insertFinalNewline: false};
    checkFormat("int a;", "int a;", off);
}

@("printer.smoke.formats-a-real-module")
@system unittest
{
    import std.file : read;
    import std.path : buildPath, dirName;

    enum thisDir = __FILE_FULL_PATH__.dirName;
    enum repoRoot = thisDir.dirName.dirName.dirName.dirName.dirName;
    const path = buildPath(repoRoot, "libs", "base", "src", "sparkles",
        "base", "smallbuffer.d");
    const source = () @trusted { return cast(string) read(path); }();

    const got = formatText(source);
    const report = verifyFormat(source, got);
    assert(report.ok, report.tokenError ~ report.ddocError);
    const conv = checkConvergence(
        (const(char)[] s) => cast(const(char)[]) formatText(s), source);
    assert(conv.converged && conv.error is null, conv.error);
}
