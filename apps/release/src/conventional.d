/++
Conventional-commit parsing.

Turns a commit subject (`type(scope)!: description`) and body into a
$(LREF ConventionalCommit): the change `type`, optional `scope`, whether it is a
breaking change (a `!` marker on the subject or a `BREAKING CHANGE:` footer), and
the human description. The bump policy in `bump.d` reads only `type` and
`breaking`.

Parsing uses manual slice walks (no `splitter`/`std.utf`) so it stays
`@safe pure nothrow @nogc` — every returned string is a slice of the inputs.
+/
module conventional;

@safe pure nothrow @nogc:

/// The conventional-commit change types recognised by the bump policy. Anything
/// unrecognised (or a subject with no `type:` prefix) is `other`.
enum CommitType
{
    feat,
    fix,
    docs,
    refactor,
    build,
    ci,
    test,
    style,
    chore,
    config,
    other,
}

/// A parsed conventional commit. String fields are slices of the parsed inputs.
struct ConventionalCommit
{
    CommitType type = CommitType.other;
    string scope_;         /// the `(scope)` text, empty when absent
    bool breaking;         /// `!` marker or `BREAKING CHANGE:` footer
    string description;    /// subject text after the `:` (or the whole subject)
    string rawSubject;
    string rawBody;
}

/// Parses a commit `subject`/`body_` pair into a $(LREF ConventionalCommit).
ConventionalCommit parseConventional(string subject, string body_)
{
    ConventionalCommit c;
    c.rawSubject = subject;
    c.rawBody = body_;

    const colon = indexOf(subject, ':');
    if (colon < 0)
    {
        // No conventional prefix: keep the whole subject as the description.
        c.description = stripAscii(subject);
        c.breaking = bodyHasBreaking(body_);
        return c;
    }

    auto prefix = subject[0 .. colon];
    c.description = stripAscii(subject[colon + 1 .. $]);

    // A trailing `!` on the prefix marks a breaking change.
    if (prefix.length && prefix[$ - 1] == '!')
    {
        c.breaking = true;
        prefix = prefix[0 .. $ - 1];
    }

    // Split an optional `(scope)` off the type.
    auto typeText = prefix;
    const open = indexOf(prefix, '(');
    if (open >= 0)
    {
        typeText = prefix[0 .. open];
        const close = indexOf(prefix, ')');
        if (close > open)
            c.scope_ = prefix[open + 1 .. close];
    }

    c.type = parseType(stripAscii(typeText));
    c.breaking = c.breaking || bodyHasBreaking(body_);
    return c;
}

/// Maps a conventional-commit type token to a $(LREF CommitType); unrecognised
/// tokens become `CommitType.other`.
CommitType parseType(scope const(char)[] s)
{
    switch (s)
    {
        case "feat":     return CommitType.feat;
        case "fix":      return CommitType.fix;
        case "docs":     return CommitType.docs;
        case "refactor": return CommitType.refactor;
        case "build":    return CommitType.build;
        case "ci":       return CommitType.ci;
        case "test":     return CommitType.test;
        case "style":    return CommitType.style;
        case "chore":    return CommitType.chore;
        case "config":   return CommitType.config;
        default:         return CommitType.other;
    }
}

// ---------------------------------------------------------------------------
// Small slice helpers (kept local so the module stays @nogc)
// ---------------------------------------------------------------------------

/// Byte index of the first `c` in `s`, or `-1`.
private ptrdiff_t indexOf(scope const(char)[] s, char c)
{
    foreach (i, ch; s)
        if (ch == c)
            return i;
    return -1;
}

/// `s` with leading/trailing ASCII spaces and tabs removed.
private string stripAscii(return scope string s)
{
    size_t lo = 0, hi = s.length;
    while (lo < hi && (s[lo] == ' ' || s[lo] == '\t'))
        lo++;
    while (hi > lo && (s[hi - 1] == ' ' || s[hi - 1] == '\t'))
        hi--;
    return s[lo .. hi];
}

/// True when any body line begins with `BREAKING CHANGE:` or `BREAKING-CHANGE:`
/// (both spellings are allowed by the conventional-commits spec).
private bool bodyHasBreaking(scope const(char)[] body_)
{
    enum a = "BREAKING CHANGE:";
    enum b = "BREAKING-CHANGE:";

    size_t start = 0;
    while (start <= body_.length)
    {
        size_t end = start;
        while (end < body_.length && body_[end] != '\n')
            end++;
        auto line = body_[start .. end];
        if (lineStartsWith(line, a) || lineStartsWith(line, b))
            return true;
        if (end == body_.length)
            break;
        start = end + 1;
    }
    return false;
}

private bool lineStartsWith(scope const(char)[] line, scope const(char)[] prefix)
{
    return line.length >= prefix.length && line[0 .. prefix.length] == prefix;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("conventional.parse.typeAndScope")
@safe pure nothrow @nogc
unittest
{
    const c = parseConventional("feat(core-cli): add table renderer", "");
    assert(c.type == CommitType.feat);
    assert(c.scope_ == "core-cli");
    assert(!c.breaking);
    assert(c.description == "add table renderer");
}

@("conventional.parse.bangIsBreaking")
@safe pure nothrow @nogc
unittest
{
    const c = parseConventional("feat(base)!: remove legacy API", "");
    assert(c.type == CommitType.feat);
    assert(c.scope_ == "base");
    assert(c.breaking);
    assert(c.description == "remove legacy API");
}

@("conventional.parse.breakingFooter")
@safe pure nothrow @nogc
unittest
{
    const c = parseConventional(
        "fix(versions): tweak parser",
        "Body text.\n\nBREAKING CHANGE: parse() now rejects a leading v.\n");
    assert(c.type == CommitType.fix);
    assert(c.breaking);

    // The hyphenated spelling is also recognised.
    const h = parseConventional("fix: x", "BREAKING-CHANGE: gone");
    assert(h.breaking);
}

@("conventional.parse.noScope")
@safe pure nothrow @nogc
unittest
{
    const c = parseConventional("docs: document the release flow", "");
    assert(c.type == CommitType.docs);
    assert(c.scope_.length == 0);
    assert(c.description == "document the release flow");
}

@("conventional.parse.nonConventional")
@safe pure nothrow @nogc
unittest
{
    const c = parseConventional("Merge branch 'main'", "");
    assert(c.type == CommitType.other);
    assert(c.description == "Merge branch 'main'");
    assert(!c.breaking);
}

@("conventional.parse.unknownType")
@safe pure nothrow @nogc
unittest
{
    const c = parseConventional("perf(core): speed up", "");
    assert(c.type == CommitType.other);   // perf is not in our recognised set
    assert(c.scope_ == "core");
}
