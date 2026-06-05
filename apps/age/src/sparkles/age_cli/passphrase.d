/++
Passphrase prompting: reads a passphrase from `/dev/tty` with terminal echo
disabled, restoring the previous terminal state afterwards.

This is the security-sensitive entry point for the `age` CLI's `-p/--passphrase`
mode. The bytes the user types are captured directly into a
[sparkles.crypto.secret.SecretString] (which zeroizes on destruction and never
renders its contents), and terminal echo is suppressed while the user types so
the passphrase never appears on screen.

The single most important invariant of this module is that the terminal is
$(B always) restored to its prior state — even if a read fails or an exception
is thrown — so a caller can never leave the user's shell with echo disabled.
That is enforced with a `scope(exit)` guard around the echo-off region (see
$(LREF readPassphrase)).

$(H2 Surface)

$(UL
    $(LI $(LREF readPassphrase) — prompt once, return the typed passphrase.
        Mirrors rage's `read_secret(.., confirm: None)`: an empty input is an
        error (`Input is required`).)
    $(LI $(LREF readPassphraseConfirm) — prompt twice and require the two
        entries to match (constant-time compare). Mirrors rage's
        `read_secret(.., confirm: Some(..))`: an empty input is $(I allowed)
        here, because rage's encrypt-with-`-p` flow treats an empty passphrase
        as a request to autogenerate one. This module does not generate; the
        caller decides what an empty confirmed passphrase means.))

Both return a [PassphraseExpected] — the typed [sparkles.crypto.secret.SecretString]
on success, or a [PassphraseError] describing why the prompt could not be
completed (no controlling terminal, an `errno`-level failure, a confirmation
mismatch, or a required-but-empty input).

$(H2 Portability)

Echo suppression uses the POSIX `termios` API (`tcgetattr`/`tcsetattr`) on the
`/dev/tty` device, which is the user's controlling terminal regardless of how
`stdin`/`stdout` are redirected. On a platform without `version (Posix)`, or
when there is no controlling terminal (e.g. a pipe with no tty), the functions
return $(LREF PassphraseErrorCode.noTerminal) without ever touching terminal
state.

$(H2 Why not an output range / `@nogc`)

Reading from a device with `errno` handling, opening `/dev/tty`, and toggling
`termios` are inherently `@system` operations wrapped in `@trusted`; the public
surface is `@safe` but neither `pure`, `nothrow`, nor `@nogc` (a
`SecretString` is returned by value and the read loop appends to it). The one
piece of logic that $(I is) pure — trimming the line terminator off the raw
input — is factored out as $(LREF stripLineTerminator) and unit-tested directly,
since the live-tty path cannot be exercised in CI.
+/
module sparkles.age_cli.passphrase;

import core.lifetime : move;

import sparkles.crypto.secret : SecretString, fromString;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Error vocabulary
// ─────────────────────────────────────────────────────────────────────────────

/// Machine-readable reason a passphrase prompt could not be completed.
enum PassphraseErrorCode
{
    /// There is no controlling terminal to read from (no `/dev/tty`, stdin is
    /// not a tty, or the platform is not POSIX). The `age` CLI surfaces this as
    /// the inability to prompt interactively.
    noTerminal,
    /// A required passphrase was empty. Produced by $(LREF readPassphrase)
    /// (the non-confirming path), mirroring rage's `cli-secret-input-required`.
    emptyInput,
    /// The two entries of a confirmation prompt did not match. Produced by
    /// $(LREF readPassphraseConfirm), mirroring rage's `cli-secret-input-mismatch`.
    mismatch,
    /// A low-level I/O error occurred while reading the terminal (a failed
    /// `read`, `tcgetattr`, or `tcsetattr`).
    ioError,
}

/**
A passphrase-prompt failure: a $(LREF PassphraseErrorCode) rendered to a
human-readable message that mirrors the wording rage prints in the same
situations.
*/
struct PassphraseError
{
    /// What went wrong.
    PassphraseErrorCode code;

    /// Renders a human-readable message into an output range `w`.
    void toString(W)(ref W w) const
    {
        final switch (code)
        {
        case PassphraseErrorCode.noTerminal:
            w.put("could not read passphrase: no controlling terminal");
            break;
        case PassphraseErrorCode.emptyInput:
            // Mirrors rage's `cli-secret-input-required`.
            w.put("Input is required");
            break;
        case PassphraseErrorCode.mismatch:
            // Mirrors rage's `cli-secret-input-mismatch`.
            w.put("Inputs do not match");
            break;
        case PassphraseErrorCode.ioError:
            w.put("could not read passphrase: terminal I/O error");
            break;
        }
    }
}

/++
Result of a passphrase read: $(I either) the typed
[sparkles.crypto.secret.SecretString] $(I or) a $(LREF PassphraseError).

A plain `Expected!(SecretString, …)` cannot be used here: `SecretString` is
move-only (`@disable this(this)`) and zeroizes on destruction, while
`expected.Expected` copies its payload through a postblit. This purpose-built
result is therefore also move-only — it carries the secret directly, by value,
and is returned by NRVO / `move`d into the caller. On the error path the secret
field stays empty.

Access the secret through $(LREF secret) (a `ref` accessor, never a copy); test
for failure with $(LREF hasError) and read the reason via $(LREF error).
+/
struct PassphraseResult
{
    @disable this(this);

@safe:

    private SecretString _secret;
    private PassphraseError _error;
    private bool _hasError;

    /// `true` iff the prompt failed; in that case $(LREF error) holds the reason
    /// and $(LREF secret) is empty.
    bool hasError() const pure nothrow @nogc => _hasError;

    /// The failure reason. Only meaningful when $(LREF hasError) is `true`.
    PassphraseError error() const pure nothrow @nogc => _error;

    /// The captured passphrase, by reference (the move-only secret is never
    /// copied). Only meaningful when $(LREF hasError) is `false`.
    ref inout(SecretString) secret() inout pure nothrow @nogc return => _secret;
}

/// Convenience constructor for a failed $(LREF PassphraseResult).
private PassphraseResult passphraseErr(PassphraseErrorCode code) @safe
{
    PassphraseResult r;
    r._error = PassphraseError(code);
    r._hasError = true;
    return r;
}

/// Convenience constructor for a successful $(LREF PassphraseResult), `move`ing
/// the move-only secret into the result.
private PassphraseResult passphraseOk(ref SecretString secret) @safe
{
    PassphraseResult r;
    r._secret = move(secret);
    return r;
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/**
Prompt once for a passphrase on the controlling terminal, with echo disabled.

The `prompt` text is written to standard error followed by `": "` (so it does
not pollute a redirected stdout), the user's input is read from `/dev/tty` with
terminal echo suppressed, and the line terminator is stripped. An empty input is
treated as an error ($(LREF PassphraseErrorCode.emptyInput)), matching rage's
non-confirming `read_secret`.

The terminal's echo state is restored before this function returns, on every
path including a thrown exception.

Params:
    prompt = Short label shown to the user, e.g. `"Enter passphrase"`.

Returns:
    A $(LREF PassphraseResult): the typed passphrase, or a
    $(LREF PassphraseError).
*/
PassphraseResult readPassphrase(scope const(char)[] prompt)
{
    auto first = promptOnce(prompt);
    if (first.hasError)
        return move(first);

    if (first.secret.length == 0)
        return passphraseErr(PassphraseErrorCode.emptyInput);

    return move(first);
}

/**
Prompt twice for a passphrase (entry + confirmation) on the controlling
terminal, with echo disabled, and require the two entries to match.

The first prompt uses `prompt`; the confirmation prompt uses
`"Confirm passphrase"`. The two entries are compared in constant time
(via [sparkles.crypto.ct.ctEquals]); on mismatch a
$(LREF PassphraseErrorCode.mismatch) error is returned. Unlike
$(LREF readPassphrase), an $(I empty) confirmed passphrase is permitted — rage's
encrypt-with-`-p` flow interprets that as "autogenerate a passphrase for me", a
policy decision left to the caller.

The terminal's echo state is restored before this function returns, on every
path including a thrown exception.

Params:
    prompt = Short label shown for the first entry, e.g. `"Enter passphrase"`.

Returns:
    A $(LREF PassphraseResult): the confirmed passphrase, or a
    $(LREF PassphraseError).
*/
PassphraseResult readPassphraseConfirm(scope const(char)[] prompt)
{
    import sparkles.crypto.ct : ctEquals;

    auto first = promptOnce(prompt);
    if (first.hasError)
        return move(first);

    auto second = promptOnce("Confirm passphrase");
    if (second.hasError)
        return move(second);

    // Constant-time compare so a timing side channel cannot reveal how many
    // leading characters matched. `ctEquals` treats length as public, which is
    // acceptable: the lengths are already observable from keystroke timing.
    // The char->ubyte reinterpret is a benign element-type view of an
    // already-borrowed slice, hence the @trusted wrapper.
    static const(ubyte)[] asBytes(scope const(char)[] s) @trusted
        => cast(const(ubyte)[]) s;

    if (!ctEquals(asBytes(first.secret.exposeSecret()), asBytes(second.secret.exposeSecret())))
        return passphraseErr(PassphraseErrorCode.mismatch);

    return move(first);
}

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper (unit-tested directly)
// ─────────────────────────────────────────────────────────────────────────────

/**
Return `line` with a single trailing line terminator removed.

A trailing `"\r\n"` or a lone `"\n"` is stripped; a lone trailing `"\r"` is
also stripped (some terminals deliver carriage returns). At most one terminator
is removed, so an intentional blank line of input collapses to the empty slice
rather than swallowing further characters. The slice is a sub-slice of the
input — no allocation.

This is the only piece of $(LREF readPassphrase)'s logic that is `pure`, so it
carries the module's behavioural unit tests; the live-tty read path cannot be
driven in CI.

Params:
    line = Raw bytes read from the terminal, possibly including a terminator.

Returns:
    `line` without its trailing line terminator.
*/
const(char)[] stripLineTerminator(return scope const(char)[] line)
    @safe pure nothrow @nogc
{
    if (line.length >= 2 && line[$ - 2] == '\r' && line[$ - 1] == '\n')
        return line[0 .. $ - 2];
    if (line.length >= 1 && (line[$ - 1] == '\n' || line[$ - 1] == '\r'))
        return line[0 .. $ - 1];
    return line;
}

@("cli.passphrase.stripLineTerminator")
@safe pure nothrow @nogc
unittest
{
    assert(stripLineTerminator("hunter2\n") == "hunter2");
    assert(stripLineTerminator("hunter2\r\n") == "hunter2");
    assert(stripLineTerminator("hunter2\r") == "hunter2");
    assert(stripLineTerminator("hunter2") == "hunter2");

    // Only one terminator is removed.
    assert(stripLineTerminator("a\n\n") == "a\n");

    // Empty and terminator-only inputs collapse to empty.
    assert(stripLineTerminator("") == "");
    assert(stripLineTerminator("\n") == "");
    assert(stripLineTerminator("\r\n") == "");

    // Embedded carriage returns / spaces are preserved (only the tail trims).
    assert(stripLineTerminator("a b\tc\n") == "a b\tc");
}

// ─────────────────────────────────────────────────────────────────────────────
// Terminal I/O (the riskiest part — echo must always be restored)
// ─────────────────────────────────────────────────────────────────────────────

/**
Write `prompt ~ ": "` to stderr, read one line from `/dev/tty` with echo
disabled, strip the terminator, and return the bytes as a `SecretString`.

On a non-POSIX platform, or when `/dev/tty` cannot be opened (no controlling
terminal), returns $(LREF PassphraseErrorCode.noTerminal). On a low-level
failure of `tcgetattr`/`tcsetattr`/`read`, returns
$(LREF PassphraseErrorCode.ioError).

This delegates to the platform-specific implementation; the `version (Posix)`
branch is the only one with real logic.
*/
private PassphraseResult promptOnce(scope const(char)[] prompt)
{
    version (Posix)
        return promptOncePosix(prompt);
    else
        return passphraseErr(PassphraseErrorCode.noTerminal);
}

version (Posix)
{
    /++
    POSIX implementation of $(LREF promptOnce).

    Flow:
    $(OL
        $(LI Open `/dev/tty` read-write with `O_NOCTTY` (do not let opening it
            steal a controlling terminal). Failure -> `noTerminal`.)
        $(LI `scope(exit)` close the fd — runs on every exit path.)
        $(LI `tcgetattr` the current attributes; failure -> `ioError`. Save a copy
            for restoration.)
        $(LI Clear the `ECHO` bit and `tcsetattr(TCSAFLUSH)`. $(B Immediately)
            register a `scope(exit)` that restores the saved attributes, so echo
            is re-enabled even if the subsequent read throws or returns early.)
        $(LI Write the prompt to stderr, read bytes one at a time until newline or
            EOF, append to the `SecretString`, then print a trailing newline (the
            user's own Enter was not echoed).)
        $(LI Strip the line terminator from the collected bytes and return.))

    The whole body is `@trusted`: it makes raw syscalls and reads one byte at a
    time into a stack cell, but the pointer/length arguments are explicit and the
    secret bytes go straight into the zeroizing `SecretString`. The transient
    single-char holding cell is wiped before returning.
    +/
    private PassphraseResult promptOncePosix(scope const(char)[] prompt) @trusted
    {
        import core.sys.posix.fcntl : open, O_RDWR, O_NOCTTY;
        import core.sys.posix.unistd : read, write, close;
        import core.sys.posix.termios : termios, tcgetattr, tcsetattr,
            TCSAFLUSH, ECHO;

        // 2 == STDERR_FILENO. Prompt on stderr so a redirected stdout stays
        // clean. We ignore short writes on the prompt: it is purely cosmetic and
        // a failure here must not abort the (more important) read.
        static void writeStderr(scope const(char)[] s) @trusted
        {
            if (s.length)
                cast(void) write(2, s.ptr, s.length);
        }

        // String literals are NUL-terminated, so `.ptr` is a valid C string.
        int fd = open("/dev/tty".ptr, O_RDWR | O_NOCTTY);
        if (fd < 0)
            return passphraseErr(PassphraseErrorCode.noTerminal);
        scope (exit)
            cast(void) close(fd);

        termios saved;
        if (tcgetattr(fd, &saved) != 0)
            return passphraseErr(PassphraseErrorCode.ioError);

        termios noEcho = saved;
        noEcho.c_lflag &= ~(cast(typeof(noEcho.c_lflag)) ECHO);
        if (tcsetattr(fd, TCSAFLUSH, &noEcho) != 0)
            return passphraseErr(PassphraseErrorCode.ioError);

        // CRITICAL: restore the terminal no matter how we leave this function —
        // normal return, early `return`, or a thrown exception. Registered the
        // instant echo was disabled so there is no window in between.
        scope (exit)
            cast(void) tcsetattr(fd, TCSAFLUSH, &saved);

        // Emit the prompt only after echo is off and restoration is armed.
        writeStderr(prompt);
        writeStderr(": ");

        SecretString secret;
        char ch;
        bool ioFailed = false;
        for (;;)
        {
            immutable n = read(fd, &ch, 1);
            if (n < 0)
            {
                ioFailed = true;
                break;
            }
            if (n == 0) // EOF
                break;
            if (ch == '\n')
                break;
            secret.put(ch);
        }
        // Wipe the transient single-char holding cell.
        ch = 0;

        // The user's Enter was not echoed; move the cursor to the next line so
        // the terminal looks normal afterwards.
        writeStderr("\n");

        if (ioFailed)
            return passphraseErr(PassphraseErrorCode.ioError);

        // `read` gives us raw bytes; we split on '\n' (so it never enters the
        // secret), but a trailing '\r' from a CRLF terminal may remain. Route
        // the collected bytes through the unit-tested `stripLineTerminator` to
        // drop it. If nothing was trimmed, return the secret as-is (a move) to
        // avoid an extra copy; otherwise rebuild the trimmed prefix into a fresh
        // secret and let the original zeroize on scope exit (no truncate
        // primitive on SecretString).
        auto bytes = secret.exposeSecret();
        const trimmed = stripLineTerminator(bytes);
        if (trimmed.length == bytes.length)
            return passphraseOk(secret);

        auto rebuilt = fromString(trimmed);
        return passphraseOk(rebuilt);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Smoke / compile tests
// ─────────────────────────────────────────────────────────────────────────────
//
// The live-tty path (`promptOnce` -> `promptOncePosix`) cannot be exercised in
// CI: it requires a real controlling terminal with a human typing into it, and
// it deliberately reads from `/dev/tty` (not stdin) so it cannot be fed from a
// pipe. These tests therefore cover everything reachable without a tty:
//   - the pure `stripLineTerminator` logic (above);
//   - the `PassphraseError` message wording;
//   - that the public entry points compile and are callable with the expected
//     signatures (a smoke test — not actually invoked, since calling them would
//     block on terminal input in an interactive shell, or open `/dev/tty`).

@("cli.passphrase.PassphraseError.messages")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(PassphraseError(PassphraseErrorCode.noTerminal),
        "could not read passphrase: no controlling terminal");
    checkToString(PassphraseError(PassphraseErrorCode.emptyInput),
        "Input is required");
    checkToString(PassphraseError(PassphraseErrorCode.mismatch),
        "Inputs do not match");
    checkToString(PassphraseError(PassphraseErrorCode.ioError),
        "could not read passphrase: terminal I/O error");
}

@("cli.passphrase.api.callable")
@system
unittest
{
    // Compile-time smoke test of the public surface. We do NOT call the
    // functions here — they would block on `/dev/tty` input under an
    // interactive runner, or fail open as `noTerminal` under CI. We only assert
    // the signatures resolve and produce a `PassphraseResult`.
    alias R1 = typeof(readPassphrase("Enter passphrase"));
    alias R2 = typeof(readPassphraseConfirm("Enter passphrase"));
    static assert(is(R1 == PassphraseResult));
    static assert(is(R2 == PassphraseResult));

    // The error constructor is reachable and yields the right code.
    auto e = passphraseErr(PassphraseErrorCode.noTerminal);
    assert(e.hasError);
    assert(e.error.code == PassphraseErrorCode.noTerminal);
}
