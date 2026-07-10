/++
Blocking, line-based interactive prompts: a numbered $(LREF select), a yes/no
$(LREF confirm), and a validated free-text $(LREF textInput).

Every prompt takes a $(LREF PromptPolicy) so non-interactive callers (`--auto`
flags, piped stdin) are handled uniformly instead of per call site: `interactive`
asks (re-prompting on invalid input), `takeDefault` resolves silently to the
default, and `fail` returns an error. I/O goes through an injectable
$(LREF PromptIo) pair, so prompts are unit-testable with canned input; EOF on
stdin is an error, never an accidental default.

Line-based on purpose (no raw mode, works over any pipe/ssh); a cursor-driven
selector can layer on later without changing call sites.
+/
module sparkles.core_cli.prompts;

import expected : Expected, err, ok;

import sparkles.core_cli.ui.theme : Semantic, Theme;

/// How a prompt resolves when it cannot, or should not, actually ask.
enum PromptPolicy
{
    interactive, /// Ask on the terminal, re-prompting on invalid input.
    takeDefault, /// Do not ask; resolve to the default (e.g. `--auto` runs).
    fail,        /// Do not ask; return an error (default required explicitly).
}

/// The I/O seam: `readLine` returns the next input line without its terminator,
/// or `null` on EOF; `write` emits prompt text (unbuffered or flushed).
struct PromptIo
{
    string delegate() readLine;
    void delegate(scope const(char)[] text) write;
}

/// The real stdin/stdout `PromptIo`.
PromptIo stdioPromptIo()
{
    import std.stdio : readln, stdout, write;
    import std.string : chomp;

    return PromptIo(
        readLine: () {
            auto line = readln();
            return line is null ? null : line.chomp;
        },
        write: (scope const(char)[] text) {
            stdout.rawWrite(text);
            stdout.flush();
        },
    );
}

/// One choice of a $(LREF select).
struct SelectOption
{
    string label;       /// Short name, shown after the number.
    string description; /// Optional context, rendered muted.
}

/// Ask the user to pick one of `options` by number. Renders the list (default
/// marked and painted accent), then loops until a valid number or an empty line
/// (= the default). Returns the chosen index; errors on EOF or a non-
/// interactive `fail` policy.
Expected!(size_t, string) select(
    string question,
    const(SelectOption)[] options,
    size_t defaultIndex,
    PromptPolicy policy,
    PromptIo io,
    const Theme theme = Theme.init,
)
in (options.length > 0 && defaultIndex < options.length)
{
    import std.conv : text, to;
    import std.string : strip;

    final switch (policy)
    {
        case PromptPolicy.takeDefault:
            return ok!string(defaultIndex);
        case PromptPolicy.fail:
            return err!size_t(question ~ ": interactive input unavailable");
        case PromptPolicy.interactive:
            break;
    }

    io.write(question ~ "\n");
    foreach (i, option; options)
    {
        const isDefault = i == defaultIndex;
        auto line = text("  ", isDefault ? "❯" : " ", " ", i + 1, ") ", option.label);
        if (option.description.length)
            line ~= "  " ~ theme.paint(Semantic.muted, option.description);
        io.write((isDefault ? theme.paint(Semantic.accent, line) : line) ~ "\n");
    }

    while (true)
    {
        io.write(text("Choice [", defaultIndex + 1, "]: "));
        const answer = io.readLine();
        if (answer is null)
            return err!size_t(question ~ ": end of input");
        const trimmed = answer.strip;
        if (trimmed.length == 0)
            return ok!string(defaultIndex);
        try
        {
            const n = trimmed.to!size_t;
            if (n >= 1 && n <= options.length)
                return ok!string(n - 1);
        }
        catch (Exception)
        {
        }
        io.write(text("Please enter a number between 1 and ", options.length, ".\n"));
    }
}

/// Ask a yes/no question (`y`/`yes`/`n`/`no`, case-insensitive; empty = the
/// default, shown as `[Y/n]`/`[y/N]`). Errors on EOF or the `fail` policy.
Expected!(bool, string) confirm(
    string question,
    bool defaultYes,
    PromptPolicy policy,
    PromptIo io,
    const Theme theme = Theme.init,
)
{
    import std.string : strip, toLower;

    final switch (policy)
    {
        case PromptPolicy.takeDefault:
            return ok!string(defaultYes);
        case PromptPolicy.fail:
            return err!bool(question ~ ": interactive input unavailable");
        case PromptPolicy.interactive:
            break;
    }

    const suffix = defaultYes ? " [Y/n] " : " [y/N] ";
    while (true)
    {
        io.write(question ~ suffix);
        const answer = io.readLine();
        if (answer is null)
            return err!bool(question ~ ": end of input");
        switch (answer.strip.toLower)
        {
            case "":            return ok!string(defaultYes);
            case "y", "yes":    return ok!string(true);
            case "n", "no":     return ok!string(false);
            default:
                io.write("Please answer y or n.\n");
        }
    }
}

/// Ask for free text, re-prompting until `validate` accepts it (returns `null`)
/// or the user submits an empty line with a `defaultValue` present. `validate`
/// returns the error message to show for a rejected answer.
Expected!(string, string) textInput(
    string question,
    string defaultValue,
    string delegate(string answer) validate,
    PromptPolicy policy,
    PromptIo io,
)
{
    import std.string : strip;

    final switch (policy)
    {
        case PromptPolicy.takeDefault:
            return ok!string(defaultValue);
        case PromptPolicy.fail:
            return err!string(question ~ ": interactive input unavailable");
        case PromptPolicy.interactive:
            break;
    }

    const suffix = defaultValue.length ? " [" ~ defaultValue ~ "]: " : ": ";
    while (true)
    {
        io.write(question ~ suffix);
        const answer = io.readLine();
        if (answer is null)
            return err!string(question ~ ": end of input");
        auto value = answer.strip.length ? answer.strip : defaultValue;
        const complaint = validate is null ? null : validate(value);
        if (complaint is null)
            return ok!string(value);
        io.write(complaint ~ "\n");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    /// Canned-input PromptIo capturing everything written.
    private struct FakeIo
    {
        string[] lines;
        size_t next;
        string written;

        PromptIo io() return
        {
            return PromptIo(
                readLine: () => next < lines.length ? lines[next++] : null,
                write: (scope const(char)[] t) { written ~= t; },
            );
        }
    }

    private enum options = [
        SelectOption("minor", "suggested"),
        SelectOption("patch"),
        SelectOption("major"),
    ];
}

@("prompts.select.emptyTakesDefaultNumberPicks")
@system unittest
{
    auto empty = FakeIo([""]);
    assert(select("Bump?", options, 0, PromptPolicy.interactive, empty.io).value == 0);

    auto pick = FakeIo(["3"]);
    assert(select("Bump?", options, 0, PromptPolicy.interactive, pick.io).value == 2);
}

@("prompts.select.repromptsOnInvalid")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto io = FakeIo(["nonsense", "9", "2"]);
    assert(select("Bump?", options, 0, PromptPolicy.interactive, io.io).value == 1);
    assert(io.written.canFind("number between 1 and 3"));
    assert(io.written.canFind("❯ 1) minor")); // the default is marked
}

@("prompts.select.policiesAndEof")
@system unittest
{
    auto none = FakeIo(null);
    assert(select("Bump?", options, 1, PromptPolicy.takeDefault, none.io).value == 1);
    assert(select("Bump?", options, 1, PromptPolicy.fail, none.io).hasError);
    assert(select("Bump?", options, 1, PromptPolicy.interactive, none.io).hasError); // EOF
}

@("prompts.confirm.parsing")
@system unittest
{
    auto yes = FakeIo(["YES"]);
    assert(confirm("Push?", false, PromptPolicy.interactive, yes.io).value);

    auto no = FakeIo(["n"]);
    assert(!confirm("Push?", true, PromptPolicy.interactive, no.io).value);

    auto dflt = FakeIo([""]);
    assert(!confirm("Push?", false, PromptPolicy.interactive, dflt.io).value);

    auto retry = FakeIo(["maybe", "y"]);
    assert(confirm("Push?", false, PromptPolicy.interactive, retry.io).value);

    auto none = FakeIo(null);
    assert(confirm("Push?", true, PromptPolicy.takeDefault, none.io).value);
    assert(confirm("Push?", true, PromptPolicy.interactive, none.io).hasError);
}

@("prompts.textInput.validationLoop")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto io = FakeIo(["bogus", "minor"]);
    auto r = textInput("Bump", "patch",
        (string a) => a == "minor" || a == "patch" ? null : "unknown bump `" ~ a ~ "`",
        PromptPolicy.interactive, io.io);
    assert(r.value == "minor");
    assert(io.written.canFind("unknown bump `bogus`"));

    auto dflt = FakeIo([""]);
    assert(textInput("Bump", "patch", null, PromptPolicy.interactive, dflt.io).value == "patch");
}
