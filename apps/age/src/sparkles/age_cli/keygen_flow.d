/++
The `age-keygen` command flow: generate a fresh X25519 identity file, or
convert an existing identity file to its `age1…` recipients (`-y`).

This module holds the $(I testable) core of the `age-keygen` binary; the
`src/age_keygen.d` entry point is a thin wrapper that parses the command line
and calls $(LREF runKeygen). Splitting the logic out keeps it reachable from the
`unittest` configuration (which excludes the two `mainSourceFile`s) and mirrors
the `sparkles.age_cli.*` layout used by the rest of the CLI.

# Behaviour (a faithful port of rage's `rage-keygen`)

$(UL
    $(LI $(B Generate) (no `-y`): draw a new key with
        $(REF generateKey, sparkles,age,keygen) and write the three-line identity
        file to the output. The output file is created with mode `0600` and
        refuses to overwrite an existing file; standard output is used when no
        `-o` is given. Whenever the output is $(I not) an interactive terminal
        (a real file, or a piped/redirected stdout), the generated public key is
        echoed to standard error as `Public key: age1…` — matching rage's
        `if !output.is_terminal() { eprintln!("Public key: …") }`.)
    $(LI $(B Convert) (`-y`): read the identity file named by the positional
        `INPUT` (or standard input when absent / `-`), parse it with
        $(REF parseIdentityFileText, sparkles,age,identity_file), and write one
        bare `age1…` recipient per native (X25519) identity to the output. An
        identity file with no native identities — or that holds only an SSH key,
        which has no `age1…` form — is rejected the way rage rejects an empty
        conversion (`No identities found in …`).)
)

# Errors

$(LREF KeygenError) carries the rage-style message $(I body) (no `Error: `
prefix, no UX footer); the entry point is responsible for the prefix, the
footer, and the exit code. Messages mirror rage's
`rage/i18n/en-US/rage.ftl` + `age/i18n/en-US/age.ftl`.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
+/
module sparkles.age_cli.keygen_flow;

import std.typecons : Nullable, nullable;

import sparkles.age_cli.io : InputReader, IoError, OutputFormat, OutputWriter;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Options
// ─────────────────────────────────────────────────────────────────────────────

/++
The parsed `age-keygen` command line.

Field meanings track rage's `rage-keygen` `AgeOptions`
(`rage/src/bin/rage-keygen/cli.rs`): an optional `-o/--output` path
(`null`/`"-"` ⇒ standard output), the `-y` "convert to recipients" toggle, and
the optional positional `INPUT` used only in convert mode (`null`/`"-"` ⇒
standard input).
+/
struct KeygenOptions
{
    /// `-o/--output <F>`: destination path. `null` (or `"-"`) ⇒ standard output.
    string output;

    /// `-y`: convert the identity file `INPUT` to its `age1…` recipients
    /// instead of generating a new key.
    bool convert;

    /// Positional `INPUT`: the identity file to convert (only meaningful with
    /// `-y`). `null` (or `"-"`) ⇒ standard input.
    string input;
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

/++
A failure of the `age-keygen` flow, carrying the rage-style message $(I body).

The entry point prepends `Error: ` and appends the shared UX footer, so this
type stays a plain message carrier. The wording mirrors rage's
`rage-keygen` `error::Error` (`Failed to open input/output`, `No identities
found in …`) and the underlying age-library convert error.
+/
class KeygenError : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// runKeygen
// ─────────────────────────────────────────────────────────────────────────────

/++
Runs the `age-keygen` flow described by `opts`.

Dispatches to $(LREF generateToOutput) (no `-y`) or $(LREF convertToOutput)
(`-y`). On success the output is committed (a file is atomically renamed into
place); on failure a $(LREF KeygenError) (or an underlying
$(REF IoError, sparkles,age_cli,io)) is thrown for the entry point to render.

Params:
    opts = the parsed command line.

Throws:
    $(LREF KeygenError) for a flow-level failure (bad input, no identities),
    or $(REF IoError, sparkles,age_cli,io) for an I/O failure (e.g. a missing
    output directory or a refused overwrite).
+/
void runKeygen(in KeygenOptions opts) @system
{
    // rage always uses Text output with mode 0600 for the generated/converted
    // file (`OutputWriter::new(opts.output, false, Text, 0o600, false)`); we
    // mirror that, and additionally refuse to overwrite an existing key file —
    // age-keygen never clobbers a key. (For standard output, mode/overwrite are
    // no-ops in the I/O layer.)
    import std.conv : octal;

    // rage wraps an output-open failure as `Failed to open output: <err>`
    // (`OutputWriter::new(...).map_err(Error::FailedToOpenOutput)`); mirror that
    // so e.g. a missing directory reads as rage's snapshot does.
    OutputWriter output;
    try
        output = OutputWriter.create(
            opts.output,
            OutputFormat.text,
            /*refuseOverwrite*/ true,
            /*mode*/ octal!600,
        );
    catch (IoError e)
        throw new KeygenError("Failed to open output: " ~ e.msg);

    if (opts.convert)
        convertToOutput(opts.input, output);
    else
        generateToOutput(output);

    output.finish();
}

// ─────────────────────────────────────────────────────────────────────────────
// Generate
// ─────────────────────────────────────────────────────────────────────────────

/++
Generates a fresh identity file into `output`, echoing the public key to
standard error when `output` is not an interactive terminal.

Writes the canonical three-line identity file
(`# created:` / `# public key: age1…` / `AGE-SECRET-KEY-1…`) via
$(REF generateKey, sparkles,age,keygen). When `output` is $(I not) a terminal
(a real file, or piped/redirected stdout), the `age1…` recipient embedded in
the `# public key:` line is echoed to standard error as `Public key: age1…`,
matching rage's `if !output.is_terminal()` behaviour.

Params:
    output = the (already-created) writer to fill; left uncommitted (the caller
        calls $(REF OutputWriter.finish, sparkles,age_cli,io)).
+/
void generateToOutput(ref OutputWriter output) @system
{
    import std.array : appender;

    import sparkles.age.keygen : generateKey;

    // Render the whole identity file once, then write it out. Capturing it in a
    // buffer first lets us recover the public key for the stderr echo without
    // generating a second (different!) key.
    auto buf = appender!string;
    generateKey(buf);
    const text = buf[];

    output.write(text);

    // rage echoes the public key whenever stdout is not a user-attended TTY,
    // so a redirected `age-keygen > key.txt` still reports the key. Reuse the
    // one printed in the file's "# public key:" line.
    if (!output.isTerminal)
    {
        const pk = extractPublicKey(text);
        if (pk !is null)
            printPublicKey(pk);
    }
}

// Echo "Public key: age1…" to standard error. Isolated in @trusted because the
// `stderr` global is @system (a __gshared FILE*).
private void printPublicKey(scope const(char)[] pk) @trusted
{
    import std.stdio : stderr;

    stderr.writeln("Public key: ", pk);
}

/++
Extracts the bare `age1…` recipient from the `# public key: …` line of a
generated identity-file `text`, or `null` if no such line is present.

The recipient is returned as a slice into `text` (no allocation). This is the
exact value $(REF generateKey, sparkles,age,keygen) wrote, so the stderr echo
always agrees with the file.
+/
const(char)[] extractPublicKey(return scope const(char)[] text) pure nothrow @nogc
{
    enum string PREFIX = "# public key: ";

    size_t pos = 0;
    while (pos < text.length)
    {
        size_t nl = pos;
        while (nl < text.length && text[nl] != '\n')
            ++nl;

        const line = text[pos .. nl];
        if (line.length >= PREFIX.length && line[0 .. PREFIX.length] == PREFIX)
            return stripTrailingCr(line[PREFIX.length .. $]);

        pos = nl < text.length ? nl + 1 : text.length;
    }
    return null;
}

// Drop a single trailing '\r' (defensive: a line carved before '\n' may keep a
// CR if the producer used CRLF; generateKey uses bare '\n', but be robust).
private const(char)[] stripTrailingCr(return scope const(char)[] s) pure nothrow @nogc
{
    if (s.length > 0 && s[$ - 1] == '\r')
        return s[0 .. $ - 1];
    return s;
}

// ─────────────────────────────────────────────────────────────────────────────
// Convert (-y)
// ─────────────────────────────────────────────────────────────────────────────

/++
Reads the identity file at `inputPath` (or standard input when `null`/`"-"`),
parses it, and writes one bare `age1…` recipient per native identity to
`output`.

Mirrors rage's `IdentityFile::write_recipients_file`: only native (X25519)
identities have an `age1…` form, so each parsed
$(REF X25519Identity, sparkles,age,recipients,x25519) is rendered (via its
public recipient) on its own line. An identity file that yields no native
recipients — empty, comments-only, or holding only an SSH key — is rejected
with rage's `No identities found in …` message.

Params:
    inputPath = the identity file path; `null`/`"-"` ⇒ standard input.
    output = the (already-created) writer to fill; left uncommitted.

Throws:
    $(LREF KeygenError) if the input cannot be opened/read, fails to parse as an
    identity file, or contains no native recipients.
+/
void convertToOutput(string inputPath, ref OutputWriter output) @system
{
    string text;
    try
    {
        auto reader = InputReader.open(inputPath);
        text = cast(string) reader.readAll();
    }
    catch (IoError e)
        throw new KeygenError("Failed to open input: " ~ e.msg);

    writeRecipients(text, inputPath, output);
}

/++
Parses the identity-file `text` and writes its `age1…` recipients to `output`,
one per line.

Separated from $(LREF convertToOutput) so the parse/format/no-identities logic
is exercisable without real I/O: the test feeds the text directly and a
file-backed $(REF OutputWriter, sparkles,age_cli,io).

Params:
    text = the full identity-file text.
    inputName = the source name used in the "no identities" diagnostic;
        `null`/`"-"` selects the "standard input" wording, anything else is
        quoted as a filename.
    output = the writer to fill.

Throws:
    $(LREF KeygenError) if `text` does not parse, or yields no native recipients.
+/
void writeRecipients(
    scope const(char)[] text,
    string inputName,
    ref OutputWriter output,
) @system
{
    import sparkles.age.identity_file : parseIdentityFileText;

    auto parsed = parseIdentityFileText(text);
    if (parsed.hasError)
        throw new KeygenError(noIdentitiesMessage(inputName));

    auto file = parsed.value;

    // Only native (X25519) identities have an `age1…` recipient form; an SSH
    // key has no `age1…` representation, so a file with no native identities is
    // treated as having "no identities" to convert (matching rage, whose
    // IdentityFileEntry only converts Native keys).
    if (file.x25519.length == 0)
        throw new KeygenError(noIdentitiesMessage(inputName));

    foreach (ref id; file.x25519)
    {
        auto line = appendRecipient(id.toPublic());
        output.write(line);
    }
}

// Render "age1…\n" for a recipient into a freshly allocated string.
private string appendRecipient(R)(in R recipient) @safe
{
    import std.array : appender;

    import sparkles.age.keygen : formatRecipient;

    auto w = appender!string;
    formatRecipient(w, recipient);
    w.put('\n');
    return w[];
}

// The rage-style "no identities found" message body, choosing the stdin vs.
// filename variant the way rage's IdentityFileConvertError::NoIdentities does.
private string noIdentitiesMessage(string inputName) pure nothrow @safe
{
    if (inputName is null || inputName == "-")
        return "No identities found in standard input.";
    return "No identities found in file '" ~ inputName ~ "'.";
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // A throwaway directory under tempDir, removed on scope exit. Kept local so
    // these tests don't depend on test-utils.
    private struct ScratchDir
    {
        import std.file : mkdirRecurse, rmdirRecurse, tempDir;
        import std.path : buildPath;
        import std.uuid : randomUUID;

        string path;
        @disable this(this);

        static ScratchDir create()
        {
            ScratchDir s;
            s.path = buildPath(tempDir, "age-keygen-test-" ~ randomUUID.toString());
            mkdirRecurse(s.path);
            return s;
        }

        string file(string name) => buildPath(path, name);

        ~this()
        {
            import std.file : exists;

            if (path !is null && path.exists)
                rmdirRecurse(path);
        }
    }

    // Read a whole file as text.
    private string slurp(string path) @system
    {
        import std.file : readText;

        return readText(path);
    }
}

@("cli.keygen.generate.writesThreeLineFileWithMode0600")
@system
unittest
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : startsWith;
    import std.array : array;
    import std.conv : octal;
    import std.file : getAttributes;

    import sparkles.age.recipients.x25519 : X25519Identity, X25519Recipient;

    auto scratch = ScratchDir.create();
    const target = scratch.file("key.txt");

    runKeygen(KeygenOptions(output: target));

    const text = slurp(target);
    auto lines = text.splitter('\n').array;
    // Three newline-terminated lines + trailing empty element.
    assert(lines.length == 4, "generate must write exactly three lines");
    assert(lines[0].startsWith("# created: "));
    assert(lines[1].startsWith("# public key: age1"));
    assert(lines[2].startsWith("AGE-SECRET-KEY-1"));

    version (Posix)
    {
        const perms = getAttributes(target) & octal!777;
        assert(perms == octal!600, "the key file must be mode 0600");
    }

    // The "# public key:" line and the secret key must be a matching pair.
    const pk = lines[1]["# public key: ".length .. $];
    auto recipient = X25519Recipient.parse(pk);
    assert(recipient.hasValue);
    X25519Identity id;
    auto idStatus = X25519Identity.parse(lines[2], id);
    assert(!idStatus.hasError);
    assert(id.toPublic().publicKey == recipient.value.publicKey);
}

@("cli.keygen.generate.refusesToOverwriteExistingFile")
@system
unittest
{
    import std.algorithm.searching : startsWith;
    import std.file : write;

    auto scratch = ScratchDir.create();
    const target = scratch.file("existing.key");
    write(target, "do not clobber");

    // The refusal surfaces (like rage) as a wrapped "Failed to open output:"
    // KeygenError, not a raw IoError.
    string caught;
    try
        runKeygen(KeygenOptions(output: target));
    catch (KeygenError e)
        caught = e.msg;
    assert(caught.startsWith("Failed to open output: refusing to overwrite existing file"),
        "age-keygen must refuse to overwrite an existing key file: " ~ caught);

    // The original contents must be untouched.
    assert(slurp(target) == "do not clobber");
}

@("cli.keygen.extractPublicKey.findsLine")
@safe pure
unittest
{
    const text =
        "# created: 2026-06-02T00:00:00Z\n"
        ~ "# public key: age1examplerecipient\n"
        ~ "AGE-SECRET-KEY-1SECRET\n";
    assert(extractPublicKey(text) == "age1examplerecipient");

    // No "# public key:" line ⇒ null.
    assert(extractPublicKey("nothing here\n") is null);
}

@("cli.keygen.convert.x25519FileYieldsRecipients")
@system
unittest
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : startsWith;
    import std.array : array;

    import sparkles.age_cli.io : OutputFormat, OutputWriter;

    // rage's published X25519 test key + its recipient.
    enum string TEST_SK =
        "AGE-SECRET-KEY-1GQ9778VQXMMJVE8SK7J6VT8UJ4HDQAJUVSFCWCM02D8GEWQ72PVQ2Y5J33";
    enum string TEST_PK =
        "age1t7rxyev2z3rw82stdlrrepyc39nvn86l5078zqkf5uasdy86jp6svpy7pa";

    auto scratch = ScratchDir.create();
    const target = scratch.file("recipients.txt");

    const idText =
        "# created: 2026-06-02T00:00:00Z\n"
        ~ "# public key: " ~ TEST_PK ~ "\n"
        ~ TEST_SK ~ "\n";

    {
        auto w = OutputWriter.create(target, OutputFormat.text);
        writeRecipients(idText, "id.txt", w);
        w.finish();
    }

    const out_ = slurp(target);
    auto lines = out_.splitter('\n').array;
    // One recipient line + trailing empty element.
    assert(lines.length == 2, "expected exactly one recipient line");
    assert(lines[0] == TEST_PK, "the converted recipient must match the identity");
}

@("cli.keygen.convert.multipleIdentitiesYieldOnePerLine")
@system
unittest
{
    import std.algorithm.iteration : splitter;
    import std.array : array;

    import sparkles.age_cli.io : OutputFormat, OutputWriter;

    enum string TEST_SK =
        "AGE-SECRET-KEY-1GQ9778VQXMMJVE8SK7J6VT8UJ4HDQAJUVSFCWCM02D8GEWQ72PVQ2Y5J33";
    enum string TEST_PK =
        "age1t7rxyev2z3rw82stdlrrepyc39nvn86l5078zqkf5uasdy86jp6svpy7pa";

    auto scratch = ScratchDir.create();
    const target = scratch.file("recipients.txt");

    const idText = TEST_SK ~ "\n# comment\n" ~ TEST_SK ~ "\n";

    {
        auto w = OutputWriter.create(target, OutputFormat.text);
        writeRecipients(idText, "id.txt", w);
        w.finish();
    }

    auto lines = slurp(target).splitter('\n').array;
    // Two recipient lines + trailing empty element.
    assert(lines.length == 3);
    assert(lines[0] == TEST_PK);
    assert(lines[1] == TEST_PK);
}

@("cli.keygen.convert.emptyFileRejectedWithFilename")
@system
unittest
{
    import sparkles.age_cli.io : OutputFormat, OutputWriter;

    auto scratch = ScratchDir.create();
    const target = scratch.file("out.txt");

    string caught;
    try
    {
        auto w = OutputWriter.create(target, OutputFormat.text);
        writeRecipients("# only a comment\n\n", "id.txt", w);
    }
    catch (KeygenError e)
        caught = e.msg;
    assert(caught == "No identities found in file 'id.txt'.", caught);
}

@("cli.keygen.convert.emptyStdinRejectedWithStdinWording")
@system
unittest
{
    import sparkles.age_cli.io : OutputFormat, OutputWriter;

    auto scratch = ScratchDir.create();
    const target = scratch.file("out.txt");

    // A null/"-" input name selects the "standard input" diagnostic.
    foreach (name; [null, "-"])
    {
        string caught;
        try
        {
            auto w = OutputWriter.create(target, OutputFormat.text);
            writeRecipients("", name, w);
        }
        catch (KeygenError e)
            caught = e.msg;
        assert(caught == "No identities found in standard input.", caught);
    }
}

@("cli.keygen.convert.sshOnlyFileHasNoAgeRecipients")
@system
unittest
{
    import sparkles.age_cli.io : OutputFormat, OutputWriter;

    // rage's published unencrypted OpenSSH ed25519 private key. It parses fine
    // as an identity file, but has no `age1…` recipient form, so conversion is
    // rejected as "no identities".
    enum string SSH_PEM =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        ~ "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n"
        ~ "QyNTUxOQAAACB7Ci6nqZYaVvrjm8+XbzII89TsXzP111AflR7WeorBjQAAAJCfEwtqnxML\n"
        ~ "agAAAAtzc2gtZWQyNTUxOQAAACB7Ci6nqZYaVvrjm8+XbzII89TsXzP111AflR7WeorBjQ\n"
        ~ "AAAEADBJvjZT8X6JRJI8xVq/1aU8nMVgOtVnmdwqWwrSlXG3sKLqeplhpW+uObz5dvMgjz\n"
        ~ "1OxfM/XXUB+VHtZ6isGNAAAADHN0cjRkQGNhcmJvbgE=\n"
        ~ "-----END OPENSSH PRIVATE KEY-----";

    auto scratch = ScratchDir.create();
    const target = scratch.file("out.txt");

    string caught;
    try
    {
        auto w = OutputWriter.create(target, OutputFormat.text);
        writeRecipients(SSH_PEM, "ssh.key", w);
    }
    catch (KeygenError e)
        caught = e.msg;
    assert(caught == "No identities found in file 'ssh.key'.", caught);
}

@("cli.keygen.noIdentitiesMessage.variants")
@safe pure
unittest
{
    assert(noIdentitiesMessage(null) == "No identities found in standard input.");
    assert(noIdentitiesMessage("-") == "No identities found in standard input.");
    assert(noIdentitiesMessage("keys.txt") == "No identities found in file 'keys.txt'.");
}
