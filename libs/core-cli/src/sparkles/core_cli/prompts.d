/++
Blocking, line-based interactive prompts: a numbered $(LREF select), a yes/no
$(LREF confirm), and a validated free-text $(LREF textInput).

Every prompt takes a $(LREF PromptPolicy) so non-interactive callers (`--auto`
flags, piped stdin) are handled uniformly instead of per call site: `interactive`
asks (re-prompting on invalid input), `takeDefault` resolves silently to the
default, and `fail` returns an error. I/O goes through an injectable
$(LREF PromptIo) pair, so prompts are unit-testable with canned input; EOF on
stdin is an error, never an accidental default.

Line-based by default (works over any pipe/ssh, and is what `confirm`/
`textInput` always use); $(LREF select) additionally layers a cursor-driven
mode on top when `PromptIo.beginKeySession` is available (a real terminal —
see $(REF stdioKeySession, sparkles,core_cli,key_input)), falling back to the
numbered flow otherwise.
+/
module sparkles.core_cli.prompts;

import expected : Expected, err, ok;

import sparkles.base.term_style : Style, stylize;
import sparkles.core_cli.key_input : Key, KeySession;
import sparkles.core_cli.ui.theme : Semantic, Theme;

/// How a prompt resolves when it cannot, or should not, actually ask.
enum PromptPolicy
{
    interactive, /// Ask on the terminal, re-prompting on invalid input.
    takeDefault, /// Do not ask; resolve to the default (e.g. `--auto` runs).
    fail,        /// Do not ask; return an error (default required explicitly).
}

/// The I/O seam: `readLine` returns the next input line without its terminator,
/// or `null` on EOF; `write` emits prompt text (unbuffered or flushed);
/// `beginKeySession` starts raw-mode key reading for $(LREF select)'s
/// cursor-driven mode, or is `null` when that isn't available (non-tty,
/// tests) — `select` then falls back to `readLine`.
struct PromptIo
{
    string delegate() readLine;
    void delegate(scope const(char)[] text) write;
    KeySession delegate() beginKeySession;
}

/// The real stdin/stdout `PromptIo`.
PromptIo stdioPromptIo()
{
    import std.stdio : readln, stdout, write;
    import std.string : chomp;
    import sparkles.core_cli.key_input : stdioKeySession;

    return PromptIo(
        readLine: () {
            auto line = readln();
            return line is null ? null : line.chomp;
        },
        write: (scope const(char)[] text) {
            stdout.rawWrite(text);
            stdout.flush();
        },
        beginKeySession: stdioKeySession(),
    );
}

/// One choice of a $(LREF select).
struct SelectOption
{
    string label;       /// Short name, shown after the number.
    string description; /// Optional context, rendered muted.
}

/// A vibrant highlight for the marked/selected row — deliberately more
/// eye-catching than `Semantic.accent`'s cyan (used for e.g. box/table
/// accents elsewhere), since this is the one thing the user's cursor is on.
private string paintHighlight(const Theme theme, string text)
    => theme.colors ? text.stylize(Style.brightBlue) : text;

/// Renders one option row (`i) label  description`), marking `highlighted`
/// with `❯` and the highlight style. Shared by $(LREF select)'s numbered
/// listing and its cursor-driven redraw, so both stay pixel-for-pixel
/// consistent.
private string renderOptionRow(size_t index, in SelectOption option, bool highlighted, const Theme theme)
{
    import std.conv : text;

    auto line = text("  ", highlighted ? "❯" : " ", " ", index + 1, ") ", option.label);
    if (option.description.length)
        line ~= "  " ~ theme.paint(Semantic.muted, option.description);
    return highlighted ? paintHighlight(theme, line) : line;
}

/// Ask the user to pick one of `options` by number. Renders the list (default
/// marked and painted accent), then loops until a valid number or an empty line
/// (= the default). Returns the chosen index; errors on EOF or a non-
/// interactive `fail` policy.
///
/// When `io.beginKeySession` is available (a real terminal), arrow keys move
/// the highlighted row instead: Up/Down move, Enter confirms, Esc/Ctrl+C/
/// Ctrl+D cancel. `wrapAround` (on by default) makes Up from the first row
/// jump to the last (and Down from the last jump to the first); pass `false`
/// to clamp at the ends instead.
Expected!(size_t, string) select(
    string question,
    const(SelectOption)[] options,
    size_t defaultIndex,
    PromptPolicy policy,
    PromptIo io,
    const Theme theme = Theme.init,
    bool wrapAround = true,
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

    if (io.beginKeySession !is null)
        return selectWithArrowKeys(question, options, defaultIndex, io, theme, wrapAround);

    io.write(question ~ "\n");
    foreach (i, option; options)
        io.write(renderOptionRow(i, option, i == defaultIndex, theme) ~ "\n");

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

/// The hint line under the question in arrow-nav mode, with an ASCII fallback
/// for non-Unicode terminals (matching `StatusGlyphs`/`BorderStyle`'s dual
/// paths elsewhere in this package).
private string arrowNavHint(bool unicode)
    => (unicode
        ? "↑/↓ move · Enter select · Esc/Ctrl+C cancel"
        : "^/v move · Enter select · Esc/Ctrl+C cancel");

private string[] renderOptionRows(const(SelectOption)[] options, size_t cursor, const Theme theme)
{
    auto rows = new string[options.length];
    foreach (i, option; options)
        rows[i] = renderOptionRow(i, option, i == cursor, theme);
    return rows;
}

/// `select`'s cursor-driven mode: a `LiveRegion`-repainted option list moved
/// with Up/Down instead of a numbered re-prompt loop. `wrapAround` controls
/// whether Up/Down at the ends wrap to the other end or clamp.
private Expected!(size_t, string) selectWithArrowKeys(
    string question,
    const(SelectOption)[] options,
    size_t defaultIndex,
    PromptIo io,
    const Theme theme,
    bool wrapAround,
)
{
    import sparkles.core_cli.term_caps : terminalSize;
    import sparkles.core_cli.ui.live : LiveRegion;

    io.write(question ~ "\n");
    io.write(theme.paint(Semantic.muted, arrowNavHint(theme.unicode)) ~ "\n");

    auto session = io.beginKeySession();
    scope (exit) session.finish();

    auto region = LiveRegion(io.write, () => terminalSize().width, true);
    scope (exit) region.finish();

    size_t cursor = defaultIndex;
    region.update(renderOptionRows(options, cursor, theme));

    while (true)
    {
        const before = cursor;
        final switch (session.next())
        {
            case Key.up:
                if (cursor > 0) cursor--;
                else if (wrapAround) cursor = options.length - 1;
                break;
            case Key.down:
                if (cursor + 1 < options.length) cursor++;
                else if (wrapAround) cursor = 0;
                break;
            case Key.enter:
                return ok!string(cursor);
            case Key.cancel:
                return err!size_t(question ~ ": cancelled");
            case Key.other:
                break;
        }
        if (cursor != before)
            region.update(renderOptionRows(options, cursor, theme));
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
    /// Canned-input PromptIo capturing everything written. `keys` supplies a
    /// canned key sequence for `select`'s arrow-nav mode; when empty,
    /// `beginKeySession` stays `null` and `select` falls back to `readLine`.
    private struct FakeIo
    {
        string[] lines;
        Key[] keys;
        size_t next;
        size_t nextKey;
        string written;

        PromptIo io() return
        {
            return PromptIo(
                readLine: () => next < lines.length ? lines[next++] : null,
                write: (scope const(char)[] t) { written ~= t; },
                beginKeySession: keys.length
                    ? () => KeySession(
                        next: () => nextKey < keys.length ? keys[nextKey++] : Key.cancel,
                        finish: () {},
                    )
                    : null,
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

@("prompts.select.arrowNav.movesAndSelects")
@system unittest
{
    auto io = FakeIo(keys: [Key.down, Key.down, Key.enter]);
    assert(select("Bump?", options, 0, PromptPolicy.interactive, io.io).value == 2);
}

@("prompts.select.arrowNav.wrapsAtTopByDefault")
@system unittest
{
    // Up from the first row wraps to the last (wrapAround defaults to true).
    auto io = FakeIo(keys: [Key.up, Key.enter]);
    assert(select("Bump?", options, 0, PromptPolicy.interactive, io.io).value == options.length - 1);
}

@("prompts.select.arrowNav.wrapsAtBottomByDefault")
@system unittest
{
    // Down from the last row wraps to the first.
    auto io = FakeIo(keys: [Key.down, Key.enter]);
    assert(select("Bump?", options, options.length - 1, PromptPolicy.interactive, io.io).value == 0);
}

@("prompts.select.arrowNav.clampsWhenWrapAroundDisabled")
@system unittest
{
    auto io = FakeIo(keys: [Key.up, Key.up, Key.up, Key.down, Key.enter]);
    assert(select("Bump?", options, 0, PromptPolicy.interactive, io.io, Theme.init, wrapAround: false).value == 1);
}

@("prompts.select.arrowNav.cancelReturnsDistinctError")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto io = FakeIo(keys: [Key.down, Key.cancel]);
    const result = select("Bump?", options, 0, PromptPolicy.interactive, io.io);
    assert(result.hasError);
    assert(result.error.canFind("cancelled"));
}

@("prompts.select.arrowNav.fallsBackWhenSessionUnavailable")
@system unittest
{
    // No `keys` supplied ⇒ beginKeySession is null ⇒ today's readLine loop, unchanged.
    auto io = FakeIo(["2"]);
    assert(select("Bump?", options, 0, PromptPolicy.interactive, io.io).value == 1);
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
