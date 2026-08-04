# DDoc rendering: feature test plan

_**Status:** in progress · **Date:** 2026-07-30 · **Scope:** the DDoc →
CommonMark translator (`libs/dmd-lsp/src/sparkles/dmd_lsp/ddoc.d`) and the way
its output travels through the twoslash pipeline (`Tip.doc`/`Tip.tags` →
`Node.docs`/`Node.tags` → the HTML/ANSI/GUI renderers)._

The translator does not reimplement DDoc: it drives **DMD's own documentation
engine** — `DocComment.parse` for the section split, `Section.write` /
`ParamSection.write` and `highlightText` for Markdown, links, code blocks and
identifier auto-emphasis, `MacroTable.expand` for macros — and steers the result
to CommonMark by installing a **markdown-emitting macro table** in place of the
HTML theme (`$(EM …)` → `*…*`, `$(D_CODE …)` → a ` ```d ` fence, and so
on). Sections route JSDoc-style, matching the TypeScript twoslash reference
fixture `15-markdown-docs`: Summary, Description, `Examples:` and custom
sections form the `docs` body, while `Params:` rows and the other standard
sections become `[name, text]` tag chips. Two divergences from `dmd -D` are
deliberate: an **undefined macro renders its arguments** instead of vanishing
(dmd's `DDOC_UNDEFINED_MACRO` default deletes the whole invocation, which would
blank most Phobos-style docs, since `$(REF …)`/`$(LREF …)` are dlang.org macros
rather than compiler builtins), and the **output is CommonMark, not HTML** — so
`<`, `>` and `&` pass through raw for the downstream markdown renderer to
escape, and `$(DDOC_COMMENT …)` drops rather than emitting an HTML comment.

Status legend and ID conventions: [hue spec](../hue/index.md#status-scheme).
Because this page is a **test plan**, the status column reads as _verification_
status: **full (`<sha>`)** means a committed test pins the behavior,
**not started** means the engine very likely already handles it but nothing
pins it, **partial** means current behavior knowingly diverges from or
approximates the spec (the row says how), and **deferred** means out of scope
for tooltips.

The grounding source is the language specification — `spec/ddoc.dd` in a
`dlang/dmd` checkout (1349 lines); `ddoc.dd:NNN` traces are line references into
it.
Sample traces name planned additions to the D corpus in
`libs/twoslash-d/examples/{src,fixtures}`: `29-ddoc-sections`,
`30-ddoc-params`, `31-ddoc-macros`, `32-ddoc-fences`, `33-ddoc-markdown`,
`34-ddoc-escapes`, `35-ddoc-ditto`, `36-ddoc-unittest-examples`.

## Comment forms and attachment (`DDC1`-`DDC15`)

Lexical forms, the summary/description split, and how comments bind to
declarations (`ddoc.dd:82-196`).

| ID    | Requirement                                                                                                                                                                                 | Status            | Traces to                                                                      |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------------ |
| DDC1  | A `/** … */` comment attached to a declaration is recognized and its body reaches `renderDdoc` via `Dsymbol.comment`.                                                                       | full (`d7a33164`) | all six `ddoc.render.*` tests                                                  |
| DDC2  | The `/++ … +/` form is equivalent; extra `+`s after the opener are not content. It is the form that allows `/* … */` inside an embedded code block.                                         | full              | `ddoc.render.commentFormsAndAttachment`                                        |
| DDC3  | The `///` one-line form is equivalent, and consecutive `///` lines form one comment.                                                                                                        | full              | `ddoc.render.commentFormsAndAttachment`                                        |
| DDC4  | Extra `*`/`+` on the opener, the closer, and the left margin are stripped, so a `*`-prefixed continuation line contributes only its text (`ddoc.dd:96-137`).                                | full              | `ddoc.render.commentFormsAndAttachment`                                        |
| DDC5  | The **Summary** is the first paragraph, ending at a blank line or a section name, and is emitted as the first block of `docs`.                                                              | full (`d7a33164`) | `ddoc.render.summaryDescriptionSections`                                       |
| DDC6  | A blank line **inside an embedded code block** does not end the Summary.                                                                                                                    | full              | `ddoc.render.commentFormsAndAttachment`                                        |
| DDC7  | The **Description** is every following paragraph up to the first section name; it joins the `docs` body after the Summary, separated by a blank line.                                       | full (`d7a33164`) | `ddoc.render.summaryDescriptionSections`                                       |
| DDC8  | Multiple doc comments applying to the same declaration are concatenated before parsing.                                                                                                     | full              | `ddoc.render.commentFormsAndAttachment`                                        |
| DDC9  | A doc comment to the **right** of a declaration documents that declaration (`int b; /// …`).                                                                                                | full              | `ddoc.render.commentFormsAndAttachment`                                        |
| DDC10 | A prefix comment and a postfix comment on the same declaration both apply and concatenate (`/** for g */ int g; /// more for g`).                                                           | full              | `ddoc.render.commentFormsAndAttachment`                                        |
| DDC11 | A comment consisting only of `ditto` (case-insensitive, trailing whitespace tolerated) reuses the previous declaration's comment at the same scope, including a member-then-class sequence. | full              | `visitor.dittoTarget`; `visitor.docForSymbol.dittoInheritsThePrecedingComment` |
| DDC12 | Enum members carry their own doc comments and render like any other symbol.                                                                                                                 | full              | `ddoc.render.commentFormsAndAttachment`                                        |
| DDC13 | An empty doc comment is legal; for tooltips it must yield empty `docs`/`tags`, never a crash or a stray heading.                                                                            | full              | `ddoc.render.commentFormsAndAttachment`                                        |
| DDC14 | Destructors, postblits, invariants, static constructors/destructors and `TypeInfo`/`ModuleInfo` get no `-D` output.                                                                         | partial           | divergence, see caveat below                                                   |
| DDC15 | A documented `unittest` following a declaration appends its body to that declaration's `Examples:` section; several documented unittests append in order (`ddoc.dd:1273-1297`).             | full              | `ddoc.documentedUnittests`; `36-ddoc-unittest-examples`                        |

`DDC11` note: ditto resolution lives in `dmd.doc.emitComment` (`doc.d:1396`),
which the translator does not run — it reads `Dsymbol.comment` directly. It is
reproduced in `visitor.dittoTarget` by walking the enclosing scope's members
backwards to the nearest one with a real comment, flattening attribute blocks
(`private:`), which are scopes for lookup but not for ditto. Phobos feels this
most: `std.range.iota`'s overloads all hovered as the literal word `Ditto`.

`DDC14` caveat: the suppression also lives in `emitComment`, so a documented
destructor **does** produce a tip here. That is the right behavior for hovers
(the user asked about that symbol) and is recorded as an intentional divergence
rather than a defect.

`DDC15` note: the unittest → `Examples:` merge is likewise `emitComment`'s job.
`ddoc.documentedUnittests` walks the `ddocUnittest` chain the parser builds and
appends the section to the comment text, so the ordinary section machinery
renders it. Each body is emitted as a fence labelled `unittest`, which the
markdown view's header band shows — the example is executable, not
illustrative. A `/// ditto` unittest contributes another such fence and no
prose: the idiom exists so a second example needs no second write-up.

Two gates apply, and they differ by module. The body text is only captured when
`compileEnv.ddocOutput` is set — the lexer's own copy of `params.ddoc.doOutput`,
which `init_` now sets alongside it. And the **root** module's own unittests
need `-unittest`, because without it the parser has no reason to build their
ASTs at all.

Imported symbols need neither: `parse.d` used to skip those bodies wholesale
(`doUnittests && mod.isRoot()`, a template codegen-culling guard), so no Phobos
hover could ever show an example. Under `version(LanguageServer)` the fork's
skip branch now records the body's extent as it counts braces and copies the
text out — no AST, no semantic, and so none of the hazard the guard exists to
avoid — then links the declaration's `ddocUnittest` (`+ls.4`).

The chain hangs off whichever declaration the unittest followed in source,
which for a call site is rarely the symbol resolved to: `each!(int[])` is an
instance of the inner eponymous `each(Iterable)`, itself a member of the outer
`template each(alias pred)` — and it is the outer one the `/// …` unittest came
after. `documentedUnittests` climbs the template links the same way
`docForSymbol` does.

## Sections (`DDC16`-`DDC28`)

Section recognition, the standard vocabulary, and the two sections with special
syntax (`ddoc.dd:198-432`).

| ID    | Requirement                                                                                                                                                                                                                                                     | Status            | Traces to                                                                                           |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------- |
| DDC16 | A section name is the first non-blank text on a line **immediately** followed by `:` — no space before the colon, or it is ordinary prose.                                                                                                                      | full (`d7a33164`) | `ddoc.render.summaryDescriptionSections`                                                            |
| DDC17 | Section names are matched case-insensitively (`returns:` == `Returns:`).                                                                                                                                                                                        | full              | `ddoc.render.sectionNameRulesAndParamRows` — the rule is an uppercase initial, see below            |
| DDC18 | A line starting with `http://` or `https://` is **not** a section name, despite the colon.                                                                                                                                                                      | full              | `ddoc.render.sectionNameRulesAndParamRows`                                                          |
| DDC19 | The thirteen standard sections route to lowercase `[name, text]` chips: `Returns`, `Throws`, `See_Also` → `see`, `Deprecated`, `Authors`, `Bugs`, `Date`, `History`, `License`, `Standards`, `Version`, `Copyright` (plus `Examples`, which stays in the body). | full (`d7a33164`) | `ddoc.render.summaryDescriptionSections` (four chips pinned; the rest share the same routing table) |
| DDC20 | `See_Also:` matches with the underscore and emits the chip name `see`, matching the JSDoc `@see` shape.                                                                                                                                                         | full (`d7a33164`) | `ddoc.render.summaryDescriptionSections`                                                            |
| DDC21 | A non-standard section becomes a `### Name` heading in the body, with underscores rendered as spaces.                                                                                                                                                           | full              | `ddoc.render.sectionNameRulesAndParamRows`                                                          |
| DDC22 | `Copyright:` is special only on the **module** declaration, where it sets the `COPYRIGHT` macro (`ddoc.dd:386-396`).                                                                                                                                            | partial           | routed to a `copyright` chip for every symbol                                                       |
| DDC23 | `Params:` rows are `name = description`; each becomes a `["param", "name description"]` chip, and `paramDocFor` resolves one row for per-parameter hovers.                                                                                                      | full (`d7a33164`) | `ddoc.render.paramsRows`                                                                            |
| DDC24 | A `Params:` description may span multiple lines; continuation lines fold into one whitespace-normalized description.                                                                                                                                            | full (`d7a33164`) | `ddoc.render.paramsRows`                                                                            |
| DDC25 | Text in a `Params:` section before the first `name =` is dropped by the engine's row parser.                                                                                                                                                                    | full              | `ddoc.render.sectionNameRulesAndParamRows`                                                          |
| DDC26 | A `Params:` name that matches no actual parameter still renders as a chip (documentation drift must not lose text).                                                                                                                                             | full              | `ddoc.render.sectionNameRulesAndParamRows`                                                          |
| DDC27 | `Macros:` is a `NAME = value` list with the same continuation syntax as `Params:`; its definitions override the builtin table and the section itself never appears in the output.                                                                               | full (`d7a33164`) | `ddoc.render.macros`                                                                                |
| DDC28 | `ESCAPES = /c/string/` inside a `Macros:` section is intercepted into the module escape table rather than defined as a macro.                                                                                                                                   | deferred          | see the escape caveat under `DDC58`                                                                 |

## Embedded code, inline code, and HTML (`DDC29`-`DDC37`)

Code delimiters and the constructs that must pass through untouched
(`ddoc.dd:437-545`).

| ID    | Requirement                                                                                                                                                    | Status            | Traces to                                                               |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ----------------------------------------------------------------------- |
| DDC29 | A line of at least three hyphens, backticks or tildes (leading whitespace ignored) opens and closes an embedded code block, which renders as a ` ```d ` fence. | full (`d7a33164`) | `ddoc.render.markdownAndFences` (`---` form pinned)                     |
| DDC30 | A language string after the opening delimiter (` ``` cpp `) suppresses D highlighting; the block renders as ` ```cpp `.                                        | not started       | `OTHER_CODE` macro; `32-ddoc-fences`                                    |
| DDC31 | Fence content is reproduced verbatim — blank lines, indentation and trailing spaces intact.                                                                    | full              | `ddoc.render.fenceContentIsVerbatim`                                    |
| DDC32 | A code block indented to a list item's content column stays inside that item (`ddoc.dd:716-727`).                                                              | not started       | `33-ddoc-markdown`                                                      |
| DDC33 | Inline code uses backticks with both delimiters on the **same line**; the span is escaped per the entity rules but macros still expand inside it.              | not started       | `DDOC_BACKQUOTED`; `32-ddoc-fences`                                     |
| DDC34 | An unpaired backtick on a line is a literal backtick, as is the `$(BACKTICK)` macro.                                                                           | not started       | `32-ddoc-fences`                                                        |
| DDC35 | Embedded HTML is passed through unchanged (`ddoc.dd:526-545`).                                                                                                 | partial           | raw into CommonMark; sanitization note below                            |
| DDC36 | `$(DDOC_COMMENT text)` is a comment in the source doc and does not nest.                                                                                       | partial           | defined as empty: the text drops                                        |
| DDC37 | Stray, unbalanced parentheses in section text must not corrupt macro expansion (dmd runs `escapeStrayParenthesis` before highlighting).                        | partial           | `ddoc.render.strayParensDoNotCorruptTheRest`; one shape diverges, below |

`DDC35` note: `ddoc.dd:1327-1335` flags embedded `<script>` as an XSS vector for
published DDoc HTML. Here the raw HTML lands in a CommonMark string that a
downstream renderer may or may not sanitize, so the sanitization decision
belongs to the HTML renderer (`TwoslashHtmlOptions.renderDocsMarkdown`), not to
this translator. A test should pin which of the two escapes it.

`DDC37` note: `renderDdocText` bypasses `Section.write` for non-`Params`
sections (it writes `sec.body_` and calls `highlightText` directly), which also
skips `escapeStrayParenthesis`, so an unbalanced paren in prose reaches
`MacroTable.expand` unescaped. Checked against `dmd -D` on the same inputs: it
makes no difference to prose — a stray `(` or `)` beside a macro renders
identically either way. The one shape that differs is a genuinely malformed
invocation (`$(B bold (unclosed) tail.`), where the unmatched `$(` keeps its
`$` here and dmd's escape pass renders a bare `(`. Both render the text; the
row stays `partial` because the difference is real, and the test pins it so a
change is noticed. Closing it properly needs `escapeStrayParenthesis` exposed
from the fork, which is not worth a pin bump for one `$`.

## Markdown constructs (`DDC38`-`DDC57`)

The Markdown subset DMD's `highlightText` understands (`ddoc.dd:547-841`).

| ID    | Requirement                                                                                                                                                       | Status                                                   | Traces to                                                                           |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| DDC38 | A line starting with `#` plus whitespace is a level-1 heading and renders as `# text`.                                                                            | full (`d7a33164`)                                        | `ddoc.render.markdownAndFences`                                                     |
| DDC39 | Levels `##` through `######` render at the matching depth, and any number of trailing `#`s is dropped.                                                            | full                                                     | `ddoc.render.markdownConstructs`                                                    |
| DDC40 | `*text*` is emphasis and renders as `*text*`.                                                                                                                     | full (`d7a33164`)                                        | `ddoc.render.markdownAndFences`                                                     |
| DDC41 | `**text**` is strong emphasis and renders as `**text**`.                                                                                                          | full (`d7a33164`)                                        | `ddoc.render.markdownAndFences`                                                     |
| DDC42 | `\*` emits a literal asterisk without starting emphasis.                                                                                                          | full                                                     | `ddoc.render.markdownConstructs`                                                    |
| DDC43 | Underscores never emphasize, so `snake_case_name` and `_prefixed` identifiers survive intact.                                                                     | full (`d7a33164`)                                        | `ddoc.render.markdownAndFences`                                                     |
| DDC44 | Inline links `[text](url)` render as CommonMark links, with an optional title in single quotes, double quotes or parentheses.                                     | full                                                     | `ddoc.render.markdownConstructs`                                                    |
| DDC45 | Reference links work in all three shapes — `[text][ref]`, bare `[ref]`, and a `[ref]: url "title"` definition elsewhere in the same comment (`ddoc.dd:574-585`).  | partial                                                  | `ddoc.render.markdownConstructsThatDiverge` — reference definitions are not applied |
| DDC46 | A reference label that names a **D symbol in scope** resolves to that symbol (`[Object]`).                                                                        | full                                                     | `ddoc.render.markdownConstructs`                                                    |
| DDC47 | When a label matches both a D symbol and a reference definition, the reference definition wins.                                                                   | not started                                              | `33-ddoc-markdown`                                                                  |
| DDC48 | Bare URLs starting `http://`/`https://` are auto-detected, must contain at least one period, and are recognized before macro substitution.                        | full                                                     | `ddoc.render.markdownConstructs`                                                    |
| DDC49 | Images are links with a leading `!`, in both inline and reference form; the link text becomes alt text.                                                           | full                                                     | `ddoc.render.markdownConstructs`                                                    |
| DDC50 | Unordered lists start with `-`, `*` or `+`; every item in one list must use the same marker, and a changed marker starts a new list.                              | full (`d7a33164`)                                        | `ddoc.render.markdownAndFences` (`-` form pinned)                                   |
| DDC51 | Inside a `/** */` comment a `*` bullet must be doubled (the first `*` is comment margin); the same caveat applies to `+` in `/++ +/` (`ddoc.dd:692-708`).         | full                                                     | `ddoc.render.markdownConstructs`                                                    |
| DDC52 | Ordered lists start with a number and a period, nest, and preserve their numbering and start index.                                                               | full                                                     | `reflowListsAndTables`; `ddoc.render.orderedListsKeepTheirNumbers`                  |
| DDC53 | A list item may contain further block content — paragraphs, headings, code blocks, sub-items — indented to the item's content column.                             | partial                                                  | `ddoc.render.markdownConstructsThatDiverge` — item continuations detach             |
| DDC54 | A table is a header row, a delimiter row and zero or more data rows separated by `\| full                                                                         | `delimiterRow`; `ddoc.render.tablesGetTheirDelimiterRow` | the emitted table has **no delimiter row**, so the result is not a CommonMark table |
| DDC55 | Colons in the delimiter row set per-column alignment (left, right, or centered).                                                                                  | full                                                     | `delimiterRow` (`:---`/`---:`/`:---:`)                                              |
| DDC56 | A `>`-prefixed line starts a blockquote; unprefixed lines directly following it continue it (lazy continuation), and quotes may contain headings, lists and code. | full                                                     | `ddoc.render.markdownConstructs`                                                    |
| DDC57 | Three or more asterisks, underscores, or **spaced** hyphens form a horizontal rule; unspaced `---` is a code fence, not a rule.                                   | partial                                                  | `ddoc.render.markdownConstructsThatDiverge` — underscore form only                  |

`DDC17` correction: the row's claim (`returns:` == `Returns:`) is not what the
engine does. `doc.d:484` gates the whole section scan on `isupper(*p)`, so a
section name's **first** letter must be uppercase and only the rest is
case-insensitive: `ReTurNs:` is a section, `returns:` is prose. Both are pinned,
because getting it backwards silently moves a `Returns:` chip into the body.

`DDC46` note: a `[Symbol]` reference resolves to a dlang.org URL
(`object.html#.Object`), which is a dead link anywhere but that site — and a
tooltip is anywhere but that site. `SYMBOL_LINK` renders the name as code and
drops the target.

`DDC57` note: only the underscore form survives inside `/** */`. `* * *` is
eaten by the same rule `DDC51` documents — the line's first `*` is comment
margin, so what reaches the markdown parser is a bullet list, not a rule.

## Escapes and character entities (`DDC58`-`DDC62`)

`ddoc.dd:856-896`.

| ID    | Requirement                                                                                                                  | Status      | Traces to                        |
| ----- | ---------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------- |
| DDC58 | `<`, `>` and `&` are replaced by character entities, and only when the character is immediately followed by a letter or `#`. | partial     | CommonMark divergence, see below |
| DDC59 | A backslash escapes any ASCII punctuation symbol and is itself removed from the output.                                      | not started | `34-ddoc-escapes`                |
| DDC60 | `\(`, `\)` and `\,` expand to the `LPAREN`, `RPAREN` and `COMMA` macros rather than to bare characters.                      | not started | `34-ddoc-escapes`                |
| DDC61 | `\\` outputs one backslash, and a backslash before non-punctuation is literal, so `C:\dmd2\bin\dmd.exe` needs no escaping.   | not started | `34-ddoc-escapes`                |
| DDC62 | No escape processing happens inside embedded or inline code; backslashes there are output as-is.                             | not started | `32-ddoc-fences`                 |

`DDC58` caveat: the module escape table is only populated by `gendocfile`, which
this translator never runs, so `escapeChar` returns null and `<`/`>`/`&` pass
through raw. That is the intended CommonMark behavior (the markdown renderer
owns escaping), but it also means the engine's embedded-HTML comment-skipping
branch, which is gated on the table producing `&lt;`, never runs (see `DDC35`).

## Macros (`DDC63`-`DDC76`)

`ddoc.dd:913-1205`.

| ID    | Requirement                                                                                                                                                                                                                | Status            | Traces to                                    |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------------- |
| DDC63 | `$(NAME)` and `$(NAME args)` expand to the named macro's replacement text.                                                                                                                                                 | full (`d7a33164`) | `ddoc.render.macros`                         |
| DDC64 | `$0` in a replacement is the whole argument text, with argument commas restored.                                                                                                                                           | full (`d7a33164`) | `ddoc.render.macros` (`WRAP = [[$0]]`)       |
| DDC65 | Commas split arguments: `$1`–`$9` select the first through ninth.                                                                                                                                                          | full (`d7a33164`) | `ddoc.render.dlangShims` (`REF`, `HTTP`)     |
| DDC66 | `$+` is everything after the **first** comma to the closing parenthesis.                                                                                                                                                   | full (`d7a33164`) | `ddoc.render.dlangShims` (`HTTP` title)      |
| DDC67 | Argument text may contain nested parentheses, `""`/`''` strings, `<!-- … -->` comments and tags without terminating the invocation.                                                                                        | not started       | `31-ddoc-macros`                             |
| DDC68 | Stray unnested parentheses inside arguments can be backslash-escaped as `\(` / `\)`.                                                                                                                                       | not started       | `31-ddoc-macros`                             |
| DDC69 | A literal comma is written `\,`, or handled with the `ARGS = $0` idiom; the two forms are equivalent (`ddoc.dd:1002-1009`).                                                                                                | not started       | `ARGS` is defined as `$0`; `31-ddoc-macros`  |
| DDC70 | Replacement text is rescanned recursively for further macros.                                                                                                                                                              | not started       | `31-ddoc-macros`                             |
| DDC71 | A macro re-encountered inside its own expansion with no argument or the same argument text expands to nothing (the recursion guard, plus `global.recursionLimit`).                                                         | not started       | `31-ddoc-macros`                             |
| DDC72 | An invocation that spans a replacement-text boundary is not expanded.                                                                                                                                                      | not started       | `31-ddoc-macros`                             |
| DDC73 | An undefined macro becomes `$(DDOC_UNDEFINED_MACRO NAME, args)`. **Divergence:** it is defined as `$+`, so the arguments survive instead of the invocation vanishing.                                                      | partial           | `ddoc.render.macros`; no-argument case below |
| DDC74 | `\$` outputs a literal `$`, leaving `\$(NAME)` unexpanded in the output.                                                                                                                                                   | full (`d7a33164`) | `ddoc.render.macros`                         |
| DDC75 | Definition sources form a hierarchy: a `Macros:` section overrides predefined macros of the same name, and the `D_`/`DDOC_` prefixes are reserved.                                                                         | full (`d7a33164`) | `ddoc.render.macros` (user `WRAP`)           |
| DDC76 | The dlang.org vocabulary is shimmed — `REF`, `REF1`, `LREF`, `MREF`, `XREF`, `D`, `HTTP`, `HTTPS`, `WEB`, `BIGOH`, `NBSP`, `TT`, `ARGS`, `PHOBOSSRC`, `DDSUBLINK` and friends — so real-world Phobos docs never blank out. | full (`d7a33164`) | `ddoc.render.dlangShims` (five pinned)       |

`DDC73` caveat: dmd prepends the macro name to the argument text only when
there **are** arguments (`dmacro.d:186-198`). An undefined macro invoked with no
arguments, such as `$(MATH_DOCS)`, therefore has `$+` empty and still vanishes.
Closing that gap needs a fallback that can see the name, e.g. `$1` with a
name-only invocation handled separately.

## Identifier auto-emphasis (`DDC77`-`DDC80`)

`ddoc.dd:843-854`.

| ID    | Requirement                                                                                                                         | Status            | Traces to                                         |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------- |
| DDC77 | An identifier in prose that names a **function parameter** of the documented declaration is emphasized, and renders as a code span. | full (`d7a33164`) | `ddoc.render.autoEmphasisAndSuppression`          |
| DDC78 | Identifiers naming other symbols in scope at the declaration are emphasized the same way.                                           | not started       | `DDOC_AUTO_PSYMBOL`; `29-ddoc-sections`           |
| DDC79 | Only `true`, `false` and `null` are auto-emphasized as keywords.                                                                    | full (`d7a33164`) | `ddoc.render.autoEmphasisAndSuppression` (`null`) |
| DDC80 | A leading underscore suppresses emphasis and is stripped from the output (`_y` renders as `y`, unemphasized).                       | full (`d7a33164`) | `ddoc.render.autoEmphasisAndSuppression`          |

## Out of scope for tooltips (`DDC81`-`DDC84`)

These are document-generation concerns: they exist only when DDoc drives a file
writer, which the tooltip path never does.

| ID    | Requirement                                                                                                                                                         | Status   | Rationale                                                                                             |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ----------------------------------------------------------------------------------------------------- |
| DDC81 | Ddoc **file mode**: a `.d` file whose first token is `Ddoc` is processed as a general document (`ddoc.dd:1299-1325`).                                               | deferred | no declarations, hence no tips; `apps/hue` renders such files as markdown instead.                    |
| DDC82 | Macro definitions from the `DDOCFILE` setting, from `-Dd`-driven runs, and from `*.ddoc` files on the command line.                                                 | deferred | the translator owns its macro table; a per-project `.ddoc` override could be a later `Options` field. |
| DDC83 | User `ESCAPES` substitutions applied to the output text (`ddoc.dd:1117-1133`).                                                                                      | deferred | the CommonMark sink defines escaping; see the `DDC58` caveat and the leak note below.                 |
| DDC84 | Wholesale `DDOC_*` theme redefinition beyond the table in `defineMacros` (`DDOC_DECL`, `DDOC_MEMBERS`, `DDOC_CONSTRAINT`, the per-section wrappers, `DDOC` itself). | deferred | those macros are emitted by `gendocfile`/`emitComment`, which the tooltip path bypasses.              |

`DDC83` note: `renderDdocText` does pass the module's escape table to
`DocComment.parseMacros`, so an `ESCAPES` definition in one symbol's `Macros:`
section is stored on the **module** and would then affect `highlightText` for
every later symbol in that module. Nothing pins this today; the safest fix is a
per-render throwaway `Escape` table.

## Canonical fixtures

The specification carries reusable corpora; each is worth lifting verbatim into
a sample rather than inventing a new one.

| `ddoc.dd` lines | Fixture                                                                                        | Feeds                             |
| --------------- | ---------------------------------------------------------------------------------------------- | --------------------------------- |
| 168-196         | The attachment/`ditto` matrix: prefix, postfix, concatenation, `ditto` in a class and after it | `DDC8`–`DDC11`; `35-ddoc-ditto`   |
| 404-416         | The `Params:` example with a continued description                                             | `DDC23`–`DDC26`; `30-ddoc-params` |
| 716-727         | A parent list item with a second paragraph, a sub-item, and a code block inside the sub-item   | `DDC32`, `DDC53`                  |
| 738-746         | The table example, including a row without edge pipes and a right-aligned column               | `DDC54`, `DDC55`                  |
| 574-585         | All four link styles plus a reference definition with a title                                  | `DDC44`–`DDC49`                   |

## Non-goals

- **Reproducing `dmd -D` byte-for-byte.** The target is CommonMark for a
  tooltip, so the HTML theme, the document boilerplate (`DDOC`, `BODY`,
  `TITLE`, `DATETIME`) and the members/decl scaffolding are all out of scope.
- **A DDoc _writer_.** Nothing here generates or reformats doc comments.
- **Cross-module symbol links.** `[Object]`-style references resolve to a code
  span, not to a URL; real navigation is hue's
  [navigation spec](../hue/navigation.md).
- **Rendering the doc body.** Turning the CommonMark into pixels or cells is
  the renderers' job (`sparkles:twoslash` HTML/ANSI/GUI backends).

This `DDC` matrix **supersedes** the one-line description in `DOC3`
([feature requirements](./feature-requirements.md), "DDoc extraction &
rendering") and is the requirement of record for ddoc rendering; `DOC1`/`DOC2`
continue to own retention and node population.

→ [Overview](./index.md) · [Feature requirements](./feature-requirements.md) ·
[DDoc authoring guidelines](../../guidelines/ddoc.md)
