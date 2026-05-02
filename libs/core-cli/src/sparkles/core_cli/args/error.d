module sparkles.core_cli.args.error;

static import expected;

public import expected : Expected;

enum CliErrorKind
{
    parse,
    help,
}

struct CliError
{
    CliErrorKind kind;
    string message;
    string help;
    int exitCode = 1;

    bool isHelp() const @safe pure nothrow @nogc => kind == CliErrorKind.help;
}

alias CliExpected(T) = Expected!(T, CliError);

/// `Expected`-success constructors with the error type fixed to `CliError`.
/// Mirrors `expected.ok` but removes the need to repeat `!CliError` at every
/// call site.
auto ok(T)(T value) => expected.ok!CliError(value);

/// ditto
auto ok() => expected.ok!CliError();

/// `Expected`-failure constructor with the error type fixed to `CliError`.
/// `T` is the value type of the resulting `Expected!(T, CliError)`; defaults
/// to `void`. Mirrors `expected.err` but skips the `CliError` boilerplate.
auto error(T = void)(CliError e)
{
    static if (is(T == void))
        return expected.err(e);
    else
        return expected.err!T(e);
}
