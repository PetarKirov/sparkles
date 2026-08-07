/// The child-process environment policy: which inherited variables must not
/// reach the shell, and what this terminal advertises instead.
///
/// Programs like yazi pick their image protocol from these: a leaked
/// `TERM_PROGRAM=ghostty` makes yazi skip its Kitty-graphics probe, and a
/// leaked `ZELLIJ_SESSION_NAME` makes it assume a multiplexer that can't pass
/// graphics through — so images degrade to chafa block art even though this
/// terminal supports the Kitty graphics protocol.
module child_env;

/// Variables dropped by exact name.
private static immutable droppedVars = [
    "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
    "TERMINFO", // points into the host terminal's own terminfo tree
    "WINDOWID", "VTE_VERSION",
    "TMUX", "TMUX_PANE",
    "ITERM_SESSION_ID", "ITERM_PROFILE",
    "KONSOLE_VERSION", "KONSOLE_DBUS_SESSION", "KONSOLE_DBUS_SERVICE",
    "WT_SESSION", "WT_PROFILE_ID",
];

/// Variable prefixes dropped wholesale (terminal- and multiplexer-specific).
private static immutable droppedPrefixes = [
    "GHOSTTY_", "ZELLIJ", "KITTY_", "WEZTERM_", "ALACRITTY_",
];

/// Whether an inherited variable named `name` must be dropped from the child's
/// environment — the pure decision, separated so the policy is testable
/// without mutating this process's environment.
@safe pure nothrow @nogc
bool dropsFromChildEnv(scope const(char)[] name)
{
    foreach (v; droppedVars)
        if (name == v)
            return true;
    foreach (p; droppedPrefixes)
        if (name.length >= p.length && name[0 .. p.length] == p)
            return true;
    return false;
}

@("child_env.dropsFromChildEnv")
@safe pure nothrow @nogc
unittest
{
    // Exact names.
    assert(dropsFromChildEnv("TERM_PROGRAM"));
    assert(dropsFromChildEnv("TMUX"));
    // Prefixes.
    assert(dropsFromChildEnv("GHOSTTY_RESOURCES_DIR"));
    assert(dropsFromChildEnv("ZELLIJ_SESSION_NAME"));
    assert(dropsFromChildEnv("KITTY_WINDOW_ID"));
    // Kept: the child needs these.
    assert(!dropsFromChildEnv("TERM"));
    assert(!dropsFromChildEnv("PATH"));
    assert(!dropsFromChildEnv("HOME"));
    assert(!dropsFromChildEnv("COLORTERM"));
    // A prefix must anchor at the start.
    assert(!dropsFromChildEnv("MY_KITTY_THING"));
}

/// Applies the policy to *this* process, then advertises what this terminal
/// actually is: 256-color xterm-compatible with 24-bit SGR color support
/// (matching the DA1/XTVERSION responses). Must run before `forkpty` — the
/// child inherits the parent's environment.
void sanitizeChildEnv()
{
    import core.sys.posix.stdlib : setenv, unsetenv;
    import std.process : environment;
    import std.string : toStringz;

    foreach (name; environment.toAA.byKey)
        if (dropsFromChildEnv(name))
            unsetenv(name.toStringz);

    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);
}
