/++
The docs-site glossary: its data file, D schema, and consistency rules.

`docs/.vitepress/glossary.json` is the single source of truth for every term
the documentation defines. Like the sidebar (`sparkles.docs.sidebar`), it is
data with several consumers:

$(LIST
    $(ITEM a VitePress data loader renders it as the `/glossary` page and as
        per-library terminology sections)
    $(ITEM the site theme reads the same entries to show a term's `summary`
        when a reader hovers a link to it)
    $(ITEM `ci --check-glossary` validates the entries and every link into
        the glossary from the documentation, using this module)
)

A term has exactly one defining entry. Pages link to it — `[witness](../glossary.md#canonical-witness)` —
rather than restating it; the editorial rules are in
`docs/guidelines/spec-prose.md`.
+/
module sparkles.docs.glossary;

import std.algorithm.searching : canFind, startsWith;
import std.array : Appender, appender;
import std.conv : text;
import std.regex : ctRegex, matchAll;

import sparkles.base.text.case_text : unicodeLower;
import sparkles.wired.json : readJSONFile;
import sparkles.wired.policy : WireOptional;

import sparkles.docs.sidebar : LoadResult;

/// Path of the glossary data file, relative to the repository root.
enum glossaryDataPath = "docs/.vitepress/glossary.json";

/// Repository path of the rendered glossary page, without the `.md` suffix.
enum glossaryPagePath = "docs/glossary";

/// The `owner` of a term shared across libraries.
enum globalOwner = "global";

/// A labeled link to the source that defines or justifies a term.
struct GlossaryLink
{
    /// Link text, e.g. `RFC 9293 §3.10`.
    string text;

    /// Target: an external URL or a site-absolute route (`/research/…`).
    string link;
}

/++
One glossary entry, as it appears in `glossary.json`.

`summary` and `definition` serve different readers: the summary is one
plain-text sentence that must make sense alone in a hover card; the definition
is one to three sentences of inline Markdown for the glossary page.
+/
struct GlossaryEntry
{
    /// Stable anchor slug (`canonical-witness`). Never renamed or reused.
    string id;

    /// The term as written in prose.
    string term;

    /// Other spellings that denote the same term (plurals, abbreviations).
    @WireOptional() string[] aliases;

    /// One self-contained sentence of plain text — no Markdown links.
    string summary;

    /// One to three sentences of inline Markdown. Links are site-absolute or
    /// external, because the definition renders on more than one page.
    string definition;

    /// Authoritative sources, most authoritative first.
    @WireOptional() GlossaryLink[] authority;

    /// `global`, or the dub package that owns the term (`sparkles:fuzzy`).
    string owner;

    /// Ids of related entries.
    @WireOptional() string[] seeAlso;
}

/// Loads glossary entries from an explicit `glossary.json` path.
LoadResult!(GlossaryEntry[]) loadGlossaryFile(string path)
    => readJSONFile!(GlossaryEntry[])(path);

/// Loads the glossary from `<repoRoot>/docs/.vitepress/glossary.json`.
LoadResult!(GlossaryEntry[]) loadGlossary(string repoRoot)
{
    import std.path : buildPath;

    return loadGlossaryFile(repoRoot.buildPath(glossaryDataPath));
}

/++
Whether `s` is a valid entry id: lowercase ASCII letters and digits in groups
separated by single hyphens (`sans-io`, `regular-type`).
+/
@safe pure nothrow @nogc
bool isGlossaryId(scope const(char)[] s)
{
    if (s.length == 0 || s[0] == '-' || s[$ - 1] == '-')
        return false;
    char prev = 0;
    foreach (c; s)
    {
        const ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
        if (!ok || (c == '-' && prev == '-'))
            return false;
        prev = c;
    }
    return true;
}

/++
The `owner` a page declares in its YAML front matter, or an empty slice.

A specification names its owning package in front matter
(`docs/guidelines/spec-prose.md`), and may do so before the package exists:
a draft spec is how a library is proposed. `ci --check-glossary` therefore
accepts an owner declared here as well as the in-tree package names, so a
draft can own its terms from the start.

Only the block delimited by `---` lines at the very start of the page is read;
the value is trimmed, and a trailing `# comment` is dropped.
+/
@safe pure nothrow @nogc
inout(char)[] frontMatterOwner(return scope inout(char)[] markdown)
{
    static bool isDelimiter(scope const(char)[] line) => line == "---" || line == "---\r";

    size_t pos;
    // Bounds of the next line (without its `\n`), advancing `pos` past it.
    size_t[2] nextLine()
    {
        const start = pos;
        while (pos < markdown.length && markdown[pos] != '\n')
            ++pos;
        const end = pos;
        if (pos < markdown.length)
            ++pos;
        return [start, end];
    }

    const first = nextLine();
    if (!isDelimiter(markdown[first[0] .. first[1]]))
        return null;
    while (pos < markdown.length)
    {
        const bounds = nextLine();
        auto line = markdown[bounds[0] .. bounds[1]];
        if (isDelimiter(line))
            break;
        enum key = "owner:";
        if (line.length < key.length || line[0 .. key.length] != key)
            continue;
        auto value = line[key.length .. $];
        foreach (i, c; value)
            if (c == '#')
            {
                value = value[0 .. i];
                break;
            }
        size_t b = 0, e = value.length;
        while (b < e && (value[b] == ' ' || value[b] == '\t'))
            ++b;
        while (e > b && (value[e - 1] == ' ' || value[e - 1] == '\t' || value[e - 1] == '\r'))
            --e;
        return value[b .. e];
    }
    return null;
}

/// A link from a documentation page into the glossary.
struct GlossaryReference
{
    /// Repository-relative path of the linking page (`docs/specs/x/SPEC.md`).
    string file;

    /// One-based line of the link.
    size_t line;

    /// The anchor the link targets.
    string id;
}

/++
Finds every link in `markdown` (the contents of the repository file `file`)
whose target is the glossary page with an anchor.

Inline links (`[t](../glossary.md#id)`) and reference definitions
(`[t]: /glossary#id`) both count. A relative target is resolved against the
page's directory; a site-absolute one (`/glossary#id`) against `docs/`. Links
to other pages that happen to be named `glossary` do not count.
+/
@safe
GlossaryReference[] glossaryReferences(string file, string markdown)
{
    import std.path : buildNormalizedPath, dirName;
    import std.string : lineSplitter;

    static immutable targetRe =
        ctRegex!(`(?:\]\(|^\s*\[[^\]]+\]:\s+)<?([^\s()<>#]*glossary(?:\.md|\.html)?)#([^\s()<>]+)`);

    auto result = appender!(GlossaryReference[]);
    size_t lineNo;
    bool inFence;
    foreach (line; markdown.lineSplitter)
    {
        ++lineNo;
        const trimmed = stripLeadingSpace(line);
        if (trimmed.startsWith("```") || trimmed.startsWith("~~~"))
        {
            inFence = !inFence;
            continue;
        }
        if (inFence)
            continue;

        foreach (m; line.matchAll(targetRe))
        {
            string path = m[1];
            if (path.startsWith("/"))
                path = "docs" ~ path;
            else
                path = buildNormalizedPath(file.dirName, path);
            path = stripPageSuffix(path);
            if (path == glossaryPagePath)
                result.put(GlossaryReference(file, lineNo, m[2]));
        }
    }
    return result[];
}

private string stripLeadingSpace(string s) @safe pure nothrow @nogc
{
    size_t i;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
        ++i;
    return s[i .. $];
}

private string stripPageSuffix(string s) @safe pure nothrow
{
    import std.algorithm.searching : endsWith;

    foreach (suffix; [".md", ".html"])
        if (s.endsWith(suffix))
            return s[0 .. $ - suffix.length];
    return s;
}

/// Outcome of `checkGlossary`.
struct GlossaryReport
{
    /// Violations: the check fails when any are present.
    string[] errors;

    /// Ids no documentation page links to. Reported, never failed: a term
    /// may be defined ahead of the page that will use it.
    string[] unused;

    /// True when there are no errors.
    @safe pure nothrow @nogc
    bool ok() const => errors.length == 0;
}

/++
Validates glossary entries and the documentation's links into them.

Errors are: a malformed or duplicate id; a missing term, summary, or
definition; a summary containing a Markdown link or URL; a relative link in a
definition or authority; an owner outside `knownOwners` (plus `global`); a
term or alias claimed by two entries; a `seeAlso` naming an unknown id or the
entry itself; and a reference to an id that does not exist. Ids that no
reference targets are returned as `unused`.
+/
@safe
GlossaryReport checkGlossary(
    in GlossaryEntry[] entries,
    in string[] knownOwners,
    in GlossaryReference[] references)
{
    auto errors = appender!(string[]);
    bool[string] ids;
    string[string] termOwner; // lowercased term or alias → id that claims it

    foreach (const ref e; entries)
    {
        const where = e.id.length ? e.id : "(entry with no id)";
        if (!isGlossaryId(e.id))
            errors.put(text(where, ": id is not a lowercase hyphenated slug"));
        else if (e.id in ids)
            errors.put(text(e.id, ": duplicate id"));
        ids[e.id] = true;

        if (e.term.length == 0)
            errors.put(text(where, ": empty term"));
        if (e.summary.length == 0)
            errors.put(text(where, ": empty summary"));
        else if (e.summary.canFind("](") || e.summary.canFind("://"))
            errors.put(text(where, ": summary must be plain text (it is shown alone on hover)"));
        if (e.definition.length == 0)
            errors.put(text(where, ": empty definition"));
        foreach (target; inlineLinkTargets(e.definition))
            if (!isPortableTarget(target))
                errors.put(text(where, ": definition link `", target,
                    "` must be site-absolute or external"));
        foreach (const ref a; e.authority)
            if (a.text.length == 0 || !isPortableTarget(a.link))
                errors.put(text(where, ": authority needs text and a site-absolute or external link"));

        if (e.owner != globalOwner && !knownOwners.canFind(e.owner))
            errors.put(text(where, ": unknown owner `", e.owner, "`"));

        foreach (name; [e.term] ~ e.aliases)
        {
            if (name.length == 0)
                continue;
            const key = name.unicodeLower;
            if (auto other = key in termOwner)
            {
                if (*other != e.id)
                    errors.put(text(where, ": `", name, "` is already defined by ", *other));
            }
            else
                termOwner[key] = e.id;
        }
    }

    foreach (const ref e; entries)
        foreach (s; e.seeAlso)
            if (s == e.id || s !in ids)
                errors.put(text(e.id, ": seeAlso `", s, "` is not another entry"));

    bool[string] used;
    foreach (const ref r; references)
    {
        if (r.id in ids)
            used[r.id] = true;
        else
            errors.put(text(r.file, ":", r.line, ": link to unknown glossary entry `", r.id, "`"));
    }

    auto unused = appender!(string[]);
    foreach (const ref e; entries)
        if (e.id.length && e.id !in used)
            unused.put(e.id);

    return GlossaryReport(errors[], unused[]);
}

private string[] inlineLinkTargets(string markdown) @safe
{
    static immutable linkRe = ctRegex!(`\]\(<?([^\s()<>]+)`);
    auto r = appender!(string[]);
    foreach (m; markdown.matchAll(linkRe))
        r.put(m[1]);
    return r[];
}

private bool isPortableTarget(string target) @safe pure nothrow @nogc
    => target.startsWith("/") || target.startsWith("https://") || target.startsWith("http://");

// ── unittests ──────────────────────────────────────────────────────────────

version (unittest)
private GlossaryEntry entry(string id, string term, string owner = globalOwner) @safe pure nothrow
    => GlossaryEntry(id: id, term: term, summary: "A plain sentence.",
        definition: "A *Markdown* sentence.", owner: owner);

@("glossary.isGlossaryId")
@safe pure nothrow @nogc
unittest
{
    assert(isGlossaryId("sans-io"));
    assert(isGlossaryId("regular-type"));
    assert(isGlossaryId("utf8"));
    assert(!isGlossaryId(""));
    assert(!isGlossaryId("Sans-IO"));
    assert(!isGlossaryId("-lead"));
    assert(!isGlossaryId("trail-"));
    assert(!isGlossaryId("double--hyphen"));
    assert(!isGlossaryId("under_score"));
}

@("glossary.frontMatterOwner")
@safe pure nothrow @nogc
unittest
{
    assert(frontMatterOwner("---\nstatus: draft\nowner: sparkles:font\nreviewed:\n---\n# Title\n")
        == "sparkles:font");
    // Comments, padding and CRLF line ends are tolerated.
    assert(frontMatterOwner("---\r\nowner:  sparkles:fuzzy  # the library\r\n---\r\n")
        == "sparkles:fuzzy");
    // No front matter, or an owner only after it closes, declares nothing.
    assert(frontMatterOwner("# Title\nowner: sparkles:font\n").length == 0);
    assert(frontMatterOwner("---\nstatus: draft\n---\nowner: sparkles:font\n").length == 0);
    // A key that merely starts like `owner` is not it.
    assert(frontMatterOwner("---\nowners: x\n---\n").length == 0);
    assert(frontMatterOwner("").length == 0);
}

@("glossary.GlossaryEntry.decode")
@system
unittest
{
    import sparkles.wired.json : fromJSON;

    auto res = fromJSON!(GlossaryEntry[])(`[
        {
            "id": "sans-io",
            "term": "sans-I/O",
            "summary": "A protocol implementation that performs no I/O.",
            "definition": "See [the manifesto](https://sans-io.readthedocs.io/).",
            "authority": [{ "text": "Sans-I/O", "link": "https://sans-io.readthedocs.io/" }],
            "owner": "global"
        },
        {
            "id": "canonical-witness",
            "term": "canonical witness",
            "aliases": ["witness"],
            "summary": "The one chosen set of matched characters.",
            "definition": "Defined in [admission](/specs/fuzzy/SPEC).",
            "owner": "sparkles:fuzzy",
            "seeAlso": ["sans-io"]
        }
    ]`);
    assert(!res.hasError, res.error.reason);
    const g = res.value;
    assert(g.length == 2);
    assert(g[0].aliases.length == 0 && g[0].authority[0].text == "Sans-I/O");
    assert(g[1].aliases == ["witness"] && g[1].seeAlso == ["sans-io"]);
    assert(g[1].owner == "sparkles:fuzzy");
}

@("glossary.glossaryReferences.resolvesOnlyTheGlossaryPage")
@safe
unittest
{
    const md = "See [witness](../../glossary.md#canonical-witness) and\n"
        ~ "[regular](/glossary#regular-type), not [x](../other/glossary.md#nope).\n"
        ~ "```markdown\n[fenced](../../glossary.md#ignored)\n```\n"
        ~ "[ref]: ../../glossary.md#sans-io\n";
    const refs = glossaryReferences("docs/specs/fuzzy/SPEC.md", md);
    assert(refs.length == 3, text(refs));
    assert(refs[0] == GlossaryReference("docs/specs/fuzzy/SPEC.md", 1, "canonical-witness"));
    assert(refs[1].id == "regular-type" && refs[1].line == 2);
    assert(refs[2].id == "sans-io" && refs[2].line == 6);
}

@("glossary.checkGlossary.clean")
@safe
unittest
{
    auto a = entry("sans-io", "sans-I/O");
    auto b = entry("canonical-witness", "canonical witness", "sparkles:fuzzy");
    b.aliases = ["witness"];
    b.seeAlso = ["sans-io"];
    const report = checkGlossary([a, b], ["sparkles:fuzzy"],
        [GlossaryReference("docs/a.md", 3, "sans-io")]);
    assert(report.ok, text(report.errors));
    assert(report.unused == ["canonical-witness"]);
}

@("glossary.checkGlossary.errors")
@safe
unittest
{
    auto dupId = entry("sans-io", "other term");
    auto badId = entry("Bad_Id", "bad");
    auto linkySummary = entry("linky", "linky");
    linkySummary.summary = "See [x](https://example.com).";
    auto relDef = entry("rel", "rel");
    relDef.definition = "See [x](../research/x.md).";
    auto owner = entry("owned", "owned", "sparkles:nope");
    auto clash = entry("clash", "SANS-I/O");
    auto see = entry("see", "see");
    see.seeAlso = ["see", "missing"];

    const report = checkGlossary(
        [entry("sans-io", "sans-I/O"), dupId, badId, linkySummary, relDef, owner, clash, see],
        ["sparkles:fuzzy"],
        [GlossaryReference("docs/a.md", 7, "ghost")]);

    bool has(string needle) => report.errors.canFind!(e => e.canFind(needle));
    assert(!report.ok);
    assert(has("sans-io: duplicate id"));
    assert(has("Bad_Id: id is not"));
    assert(has("linky: summary must be plain text"));
    assert(has("rel: definition link `../research/x.md`"));
    assert(has("owned: unknown owner `sparkles:nope`"));
    assert(has("clash: `SANS-I/O` is already defined by sans-io"));
    assert(has("see: seeAlso `see`"));
    assert(has("see: seeAlso `missing`"));
    assert(has("docs/a.md:7: link to unknown glossary entry `ghost`"));
}
