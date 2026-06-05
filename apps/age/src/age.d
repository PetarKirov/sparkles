/++
The `age` command-line tool: encrypt and decrypt files in the
`age-encryption.org/v1` format.

This entry point wires the parsed-and-validated command line
($(REF AgeOptions, sparkles,age_cli,options) /
$(REF validateOptions, sparkles,age_cli,validate)) to the `sparkles.age`
library, reproducing rage's `rage/src/bin/rage/main.rs` flow:

$(OL
    $(LI parse `argv` into an $(REF AgeOptions, sparkles,age_cli,options);)
    $(LI run the pure flag-validation matrix
        ($(REF validateOptions, sparkles,age_cli,validate)) plus the
        same-file guard; on any failure print the rage-style message to stderr
        and exit `1`;)
    $(LI dispatch to encrypt (the default) or decrypt (`-d`).))

# Encryption

Recipients are gathered from three sources, in command-line-source order:

$(UL
    $(LI `-r/--recipient` — each argument is parsed first as a native
        `age1…` X25519 recipient, then as an `ssh-ed25519` `authorized_keys`
        line. An `ssh-rsa` key (deferred in this build) and any otherwise
        unparseable value are rejected with a clear message.)
    $(LI `-R/--recipients-file` — every non-blank, non-`#` line of each file is
        parsed the same way; a bad line is reported with its file and line
        number, mirroring rage's `err-read-invalid-recipients-file`.)
    $(LI `-i/--identity` — in encrypt mode the identities' $(I public) halves
        are used as recipients (X25519 via `toPublic`, ssh-ed25519 by rebuilding
        its recipient from the embedded public key).))

Alternatively `-p/--passphrase` encrypts to a single scrypt recipient whose
passphrase is read (twice, with confirmation) from the controlling terminal.

The plaintext is read fully into memory and encrypted in one shot
($(REF Encryptor.encryptToBytes, sparkles,age,protocol)), then written to the
output — ASCII-armored when `-a/--armor` was given. If the plaintext already
looks like an age file a `Warning:` is printed to stderr (rage's
`warn-double-encrypting`).

# Decryption

The ciphertext is read fully; if it $(I looks armored) it is de-armored first.
The header is parsed ($(REF Decryptor.parse, sparkles,age,protocol)); a
passphrase-encrypted (scrypt) file is decrypted with a passphrase read from the
terminal, otherwise the `-i` identity files are parsed
($(REF parseIdentityFileText, sparkles,age,identity_file) →
$(REF toAnyIdentities, sparkles,age,identity_file)) and tried. A file that needs
identities but was given none is the runtime "Missing identities" case the flag
validator deferred. The recovered plaintext is written to the output.

Library `EncryptError`/`DecryptError` values and the I/O layer's `IoError` are
rendered to a stderr message and turn into exit code `1`.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
+/
module age_main;

import std.array : appender;
import std.stdio : stderr;

import sparkles.core_cli.text.errors : ParseError, ParseErrorCode;

import sparkles.age;

import sparkles.age_cli.errors : CliError, message;
import sparkles.age_cli.io :
    InputReader, IoError, OutputFormat, OutputWriter, StdinGuard;
import sparkles.age_cli.options : AgeOptions, parseAgeOptions;
import sparkles.age_cli.passphrase : readPassphrase, readPassphraseConfirm;
import sparkles.age_cli.usage : ageUsage, requestedHelp;
import sparkles.age_cli.validate : samePath, validateOptions;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

/++
The `age` process entry point.

`@system` because `std.getopt` (the parser) and the standard-stream globals are
`@system`. Parses, validates, then runs the encrypt or decrypt flow, translating
every failure into a stderr message and exit code `1`. Returns `0` on success.
+/
int main(string[] argv) @system
{
    // Help is handled first, before any parsing or I/O, so `-h`/`--help`
    // always prints usage to stdout and exits cleanly with no side effects.
    if (requestedHelp(argv))
    {
        import std.stdio : write;
        write(ageUsage);
        return 0;
    }

    AgeOptions opts;
    try
        opts = parseAgeOptions(argv);
    catch (Exception e)
    {
        fail(e.msg);
        return 1;
    }

    // Pure flag validation (the rage-compatible matrix).
    auto err = validateOptions(opts);
    if (!err.isNull)
    {
        failCliBare(err.get);
        return 1;
    }

    // The one rule that needs the filesystem: identical input/output. rage
    // checks this once flag validation has passed and both paths are concrete.
    if (samePath(opts.input, opts.output))
    {
        failCliWithFile(CliError.sameInputAndOutput, opts.output);
        return 1;
    }

    try
    {
        // Encryption is the default mode (no `-d`).
        return opts.decrypt ? runDecrypt(opts) : runEncrypt(opts);
    }
    catch (IoError e)
    {
        fail(e.msg);
        return 1;
    }
    catch (Exception e)
    {
        // A defensive catch-all: the flows below funnel library errors through
        // explicit `fail*` calls, but any unexpected exception still becomes a
        // clean exit-1 rather than an uncaught-throw stack dump.
        fail(e.msg);
        return 1;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Encryption flow
// ─────────────────────────────────────────────────────────────────────────────

/++
Runs the encrypt flow for `opts` and returns the process exit code.

Gathers recipients (or a passphrase), reads the input fully, encrypts it in one
shot, and writes the result (armored when `-a`).
+/
private int runEncrypt(in AgeOptions opts) @system
{
    // The output payload is binary unless `-a/--armor` was requested; that
    // classification drives the binary-to-TTY guard in `OutputWriter`.
    const format = opts.armor ? OutputFormat.text : OutputFormat.binary;

    if (opts.passphrase)
        return encryptWithPassphrase(opts, format);

    // Recipient mode: collect every `-r`, `-R`, and (public half of) `-i`.
    AnyRecipient[] recipients;
    if (!gatherRecipients(opts, recipients))
        return 1; // gatherRecipients already printed the error.

    auto enc = Encryptor.withRecipients(recipients);
    if (!enc.hasValue)
    {
        failRendered(enc.error);
        return 1;
    }

    return emitEncrypted(opts, enc.value, format);
}

/++
Encrypts `opts`'s input to a passphrase read (with confirmation) from the
terminal.

Mirrors rage's `-p` encrypt path, but $(B requires a non-empty passphrase):
rage auto-generates one for an empty input, which this build does not (a
deliberate simplification — see the module/CLI notes). `readPassphraseConfirm`
permits an empty confirmed input, so the emptiness is rejected here explicitly.
+/
private int encryptWithPassphrase(in AgeOptions opts, OutputFormat format) @system
{
    auto pass = readPassphraseConfirm("Enter passphrase");
    if (pass.hasError)
    {
        failRendered(pass.error);
        return 1;
    }

    auto secret = pass.secret.exposeSecret();
    if (secret.length == 0)
    {
        // Simplification vs. rage: we do not auto-generate a passphrase.
        fail("a passphrase is required (auto-generation is not supported in this build).");
        return 1;
    }

    auto enc = Encryptor.withPassphrase(secret);
    return emitEncrypted(opts, enc, format);
}

/++
Reads the input, runs `encryptor` over it, and writes the (optionally armored)
age file to the output. Shared by the recipient and passphrase paths.

`encryptor` is taken by `in` (`const`) so both an lvalue (the recipient path's
`Expected.value`) and an rvalue (the passphrase path's `withPassphrase` result)
bind; `Encryptor.encryptToBytes` is itself `const`.
+/
private int emitEncrypted(in AgeOptions opts, in Encryptor encryptor, OutputFormat format) @system
{
    // Claim stdin if the input comes from it, so a later `-i -` (in encrypt
    // mode, deriving recipients) cannot also consume it. The guard releases on
    // scope exit.
    auto stdinGuard = claimInputStdin(opts);

    auto reader = InputReader.open(opts.input);
    const plaintext = reader.readAll();

    // rage warns when encrypting something that already looks like an age file.
    if (looksLikeAgeFile(plaintext))
        warn("Encrypting an already-encrypted file");

    auto file = encryptor.encryptToBytes(plaintext);

    auto writer = OutputWriter.create(opts.output, format);
    if (opts.armor)
    {
        auto w = appender!(char[]);
        armorEncode(file, w);
        writer.write(w[]);
    }
    else
        writer.write(file);
    writer.finish();
    return 0;
}

/++
Collects recipients from `-r`, `-R`, and (in encrypt mode) `-i` into
`recipients`, in source order: explicit `-r`, then each `-R` file, then each
`-i` identity's public half.

Returns `true` on success; on a parse failure it prints the rage-style error to
stderr and returns `false`.
+/
private bool gatherRecipients(in AgeOptions opts, ref AnyRecipient[] recipients) @system
{
    // (1) Explicit `-r/--recipient` arguments.
    foreach (r; opts.recipients)
    {
        if (!parseRecipientInto(r, recipients))
        {
            failInvalidRecipient(r);
            return false;
        }
    }

    // (2) `-R/--recipients-file` files: one recipient per non-blank, non-`#`
    //     line. A bad line names its file + 1-based line number (rage parity).
    foreach (path; opts.recipientsFiles)
    {
        string text;
        try
        {
            auto reader = InputReader.open(path);
            text = cast(string) reader.readAll();
        }
        catch (IoError)
        {
            fail("Recipients file not found: " ~ path);
            return false;
        }

        size_t lineNo = 0;
        foreach (line; splitLines(text))
        {
            ++lineNo;
            const trimmed = stripAsciiWs(line);
            if (trimmed.length == 0 || trimmed[0] == '#')
                continue;

            if (!parseRecipientInto(trimmed, recipients))
            {
                import std.conv : to;

                fail("Recipients file '" ~ path
                    ~ "' contains non-recipient data on line " ~ lineNo.to!string ~ ".");
                return false;
            }
        }
    }

    // (3) `-i/--identity` in encrypt mode: derive each identity's recipient.
    foreach (path; opts.identities)
    {
        if (!recipientsFromIdentityFile(path, recipients))
            return false; // already reported.
    }

    if (recipients.length == 0)
    {
        // Defensive: the flag validator already requires at least one recipient
        // source, but every `-R` file could have been empty/comment-only.
        failCliBare(CliError.missingRecipients);
        return false;
    }

    return true;
}

/++
Parses one recipient string and, on success, appends it to `recipients`.

Tries the native X25519 `age1…` form first, then an `ssh-ed25519`
`authorized_keys` line. Returns `true` if either parsed (and was appended). A
leading `ssh-rsa` token is treated as a hard, recognised-but-deferred failure
(see $(LREF isSshRsa)); any other unparseable value also returns `false` (the
caller prints the message).

The recipient is appended (not returned) because $(REF AnyRecipient,
sparkles,age,recipient) is non-copyable — a passphrase recipient member holds a
secret — so it must be $(I moved) into the array rather than returned by value.
+/
private bool parseRecipientInto(scope const(char)[] s, ref AnyRecipient[] recipients) @safe
{
    // Native age recipient (`age1…`).
    auto x = X25519Recipient.parse(s);
    if (x.hasValue)
    {
        appendMove(recipients, AnyRecipient(x.value));
        return true;
    }

    // ssh-ed25519 reuse of an OpenSSH public key (`ssh-ed25519 <base64> …`).
    auto ssh = SshEd25519Recipient.parse(s);
    if (ssh.hasValue)
    {
        appendMove(recipients, AnyRecipient(ssh.value));
        return true;
    }

    return false;
}

/++
Parses the identity file at `path` and appends each identity's $(I public half)
to `recipients` (encrypt-mode `-i`).

X25519 identities contribute their `toPublic()` recipient; ssh-ed25519
identities contribute a recipient rebuilt from the embedded public key
(`ed25519Secret[32 .. 64]`) and the retained SSH wire public key. Returns
`true` on success; on a parse/IO failure it prints the error and returns
`false`.
+/
private bool recipientsFromIdentityFile(string path, ref AnyRecipient[] recipients) @system
{
    // A `-i -` identity reads from stdin; claim it so a stdin INPUT (or another
    // `-i -`) cannot also consume it. The guard releases on this scope's exit.
    auto guard = StdinGuard.init;
    if (path == "-")
        guard = StdinGuard.claim("identity");

    auto reader = InputReader.open(path);
    const text = cast(string) reader.readAll();

    auto parsed = parseIdentityFileText(text);
    if (parsed.hasError)
    {
        failIdentityFile(parsed.error, path);
        return false;
    }

    foreach (ref id; parsed.value.x25519)
        appendMove(recipients, AnyRecipient(id.toPublic()));

    foreach (ref id; parsed.value.sshEd25519)
    {
        SshEd25519Recipient r;
        // The 64-byte libsodium secret is `seed ‖ pub`; the trailing 32 bytes
        // are the raw Ed25519 public point.
        r.ed25519Pub = id.ed25519Secret[32 .. 64];
        r.wirePubkey = id.wirePubkey.dup;
        appendMove(recipients, AnyRecipient(r));
    }

    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Decryption flow
// ─────────────────────────────────────────────────────────────────────────────

/++
Runs the decrypt flow for `opts` and returns the process exit code.

Reads the ciphertext (de-armoring if it looks armored), parses the header, and
either prompts for a passphrase (scrypt files) or gathers `-i` identities, then
decrypts and writes the plaintext.
+/
private int runDecrypt(in AgeOptions opts) @system
{
    auto stdinGuard = claimInputStdin(opts);

    auto reader = InputReader.open(opts.input);
    const raw = reader.readAll();

    // Auto-detect armor: a `-----BEGIN AGE ENCRYPTED FILE-----` block is
    // de-armored to the binary header+payload before parsing.
    const(ubyte)[] binary = raw;
    if (looksArmored(cast(const(char)[]) raw))
    {
        auto de = armorDecode(cast(const(char)[]) raw);
        if (de.hasError)
        {
            failRendered(de.error);
            return 1;
        }
        binary = de.value;
    }

    auto dec = Decryptor.parse(binary);
    if (dec.hasError)
    {
        failRendered(dec.error);
        return 1;
    }

    // Bind the decryptor to a named lvalue: `Expected.value` does not reliably
    // yield an lvalue ref (its mutable overload can return by value), and the
    // helpers take `ref Decryptor`.
    Decryptor decryptor = dec.value;
    const result = decryptor.isScrypt
        ? decryptScrypt(opts, decryptor)
        : decryptWithIdentities(opts, decryptor);

    // The helper either already printed an error (and we just propagate its
    // exit code) or handed back the recovered plaintext.
    if (result.handled)
        return result.exitCode;

    auto writer = OutputWriter.create(opts.output, OutputFormat.text);
    writer.write(result.plaintext);
    writer.finish();
    return 0;
}

/++
The outcome of a decrypt-helper: either it $(I handled) the request itself
(printing any error and yielding an exit code), or it produced the recovered
`plaintext` for $(LREF runDecrypt) to write.

This avoids overloading `DecryptExpected` with a third "already-reported" state:
the helpers prompt for passphrases, parse identity files, and surface several
distinct diagnostics, so a plain success/error pair cannot capture "we already
told the user". `handled == false` is the only path that carries a `plaintext`.
+/
private struct DecryptResult
{
    /// `true` when the helper finished the request itself (success or a
    /// printed error); `exitCode` is then authoritative and `plaintext` unset.
    bool handled;
    /// The process exit code when `handled` is `true`.
    int exitCode;
    /// The recovered plaintext when `handled` is `false`.
    ubyte[] plaintext;

    /// A "handled, exit with `code`" result (the error was already printed).
    static DecryptResult done(int code) @safe pure nothrow @nogc
        => DecryptResult(handled: true, exitCode: code, plaintext: null);

    /// A "here is the plaintext to write" result.
    static DecryptResult ok(ubyte[] plaintext) @safe pure nothrow @nogc
        => DecryptResult(handled: false, exitCode: 0, plaintext: plaintext);
}

/++
Decrypts a passphrase-encrypted (scrypt) file: prompts once for the passphrase
and tries it as a single $(REF ScryptIdentity, sparkles,age,recipients,scrypt),
honouring `--max-work-factor`.
+/
private DecryptResult decryptScrypt(in AgeOptions opts, ref Decryptor decryptor) @system
{
    auto pass = readPassphrase("Enter passphrase");
    if (pass.hasError)
    {
        failRendered(pass.error);
        return DecryptResult.done(1);
    }

    const maxWork = opts.maxWorkFactor.isNull
        ? defaultMaxWorkFactor
        : opts.maxWorkFactor.get;

    AnyIdentity[1] identities = [
        AnyIdentity(ScryptIdentity(pass.secret.exposeSecret(), maxWork)),
    ];
    return finishDecrypt(decryptor.decrypt(identities[]));
}

/++
Decrypts a non-scrypt file with the `-i` identity files.

If no `-i` was given this is the runtime "Missing identities" case the flag
validator deferred (it cannot know the file is not scrypt).
+/
private DecryptResult decryptWithIdentities(in AgeOptions opts, ref Decryptor decryptor) @system
{
    if (opts.identities.length == 0)
    {
        failCliBare(CliError.missingIdentities);
        return DecryptResult.done(1);
    }

    AnyIdentity[] identities;
    foreach (path; opts.identities)
    {
        auto guard = StdinGuard.init;
        if (path == "-")
            guard = StdinGuard.claim("identity");

        auto reader = InputReader.open(path);
        const text = cast(string) reader.readAll();

        auto parsed = parseIdentityFileText(text);
        if (parsed.hasError)
        {
            failIdentityFile(parsed.error, path);
            return DecryptResult.done(1);
        }
        appendIdentities(identities, toAnyIdentities(parsed.value));
    }

    return finishDecrypt(decryptor.decrypt(identities));
}

/++
Appends every element of `src` onto `dst`, $(B moving) each one.

`AnyIdentity` is a `SumType` over move-only identity structs (`@disable
this(this)`), so a plain array `~=` (which copy-constructs elements) does not
compile. `src` is a fresh, owned `AnyIdentity[]` (the result of
$(REF toAnyIdentities, sparkles,age,identity_file)); we grow `dst` by `src.length`
default-initialised slots and `moveEmplace` each source element into place.

The placement is wrapped in `@trusted`: the destination slots are freshly
`length`-extended array elements that `dst` owns, and `moveEmplace` over a
default-initialised target is the documented way to relocate a non-copyable
`SumType` (cf. the testkit runner's `placeIdentity`).
+/
private void appendIdentities(ref AnyIdentity[] dst, AnyIdentity[] src) @trusted
{
    import core.lifetime : moveEmplace;

    const base = dst.length;
    dst.length += src.length;
    foreach (i, ref s; src)
        moveEmplace(s, dst[base + i]);
}

/++
Folds a library `DecryptExpected` into a $(LREF DecryptResult): a value becomes
an `ok` result, an error is printed and becomes a handled exit-1.
+/
private DecryptResult finishDecrypt(DecryptExpected!(ubyte[]) r) @system
{
    if (r.hasError)
    {
        failRendered(r.error);
        return DecryptResult.done(1);
    }
    return DecryptResult.ok(r.value);
}

// ─────────────────────────────────────────────────────────────────────────────
// Small helpers
// ─────────────────────────────────────────────────────────────────────────────

/++
Claims standard input for the primary INPUT when the input comes from stdin
(absent or `-`), returning the guard so a later `-i -` cannot also consume it.

Returns a default (inactive) $(REF StdinGuard, sparkles,age_cli,io) when the
input is a real file. The active guard releases on the caller's scope exit.
+/
private StdinGuard claimInputStdin(in AgeOptions opts) @system
{
    if (opts.input is null || opts.input == "-")
        return StdinGuard.claim("input");
    return StdinGuard.init;
}

/++
Moves the recipient `r` onto the end of `recipients`.

$(REF AnyRecipient, sparkles,age,recipient) is non-copyable (a passphrase
recipient member holds a secret), so a plain `recipients ~= r` would not
compile. This grows the array by one default-initialised slot and `moveEmplace`s
the freshly-built `r` into it — the same pattern
$(REF toAnyIdentities, sparkles,age,identity_file) uses for the identity sum
type. `r` is an rvalue parameter, so no copy occurs at the call site either.
+/
private void appendMove(ref AnyRecipient[] recipients, AnyRecipient r) @safe
{
    import core.lifetime : moveEmplace;

    recipients.length += 1;
    () @trusted { moveEmplace(r, recipients[$ - 1]); }();
}

/++
`true` if `data` already looks like an age file — it begins with the
`age-encryption.org/` magic or the ASCII-armor BEGIN marker (after leading
whitespace for the latter). Used for the double-encryption warning.
+/
private bool looksLikeAgeFile(scope const(ubyte)[] data) @safe pure nothrow @nogc
{
    const text = cast(const(char)[]) data;
    if (text.length >= AGE_MAGIC.length && text[0 .. AGE_MAGIC.length] == AGE_MAGIC)
        return true;
    return looksArmored(text);
}

/++
Splits `text` into lines on `\n`, $(I not) including the terminators. A trailing
`\r` is left attached (callers strip it via $(LREF stripAsciiWs)). Returns a
freshly-allocated array of sub-slices.

`text` is taken without `scope`: every call site passes GC-owned text (the bytes
read from a recipients file), and the returned slices alias `text`, so a `scope`
parameter would force the whole result to be `scope` and trip dip1000 escape
analysis on the GC-backed result.
+/
private const(char)[][] splitLines(const(char)[] text) @safe pure nothrow
{
    const(char)[][] lines;
    size_t pos = 0;
    while (pos <= text.length)
    {
        size_t nl = pos;
        while (nl < text.length && text[nl] != '\n')
            ++nl;
        lines ~= text[pos .. nl];
        if (nl >= text.length)
            break;
        pos = nl + 1;
    }
    return lines;
}

/// Strips leading/trailing ASCII whitespace (incl. a trailing `\r`) — no alloc.
private const(char)[] stripAsciiWs(return scope const(char)[] s) @safe pure nothrow @nogc
{
    static bool ws(char c) @safe pure nothrow @nogc
        => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';

    size_t lo = 0, hi = s.length;
    while (lo < hi && ws(s[lo]))
        ++lo;
    while (hi > lo && ws(s[hi - 1]))
        --hi;
    return s[lo .. hi];
}

/// `true` if `s` is an `ssh-rsa` `authorized_keys` line (deferred in this
/// build). The token is matched case-sensitively and must be followed by a
/// space, matching how OpenSSH writes the line.
private bool isSshRsa(scope const(char)[] s) @safe pure nothrow @nogc
{
    enum prefix = "ssh-rsa ";
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

// ─────────────────────────────────────────────────────────────────────────────
// Diagnostics (stderr)
// ─────────────────────────────────────────────────────────────────────────────

/// Prints `Error: <msg>` to stderr.
private void fail(scope const(char)[] msg) @system
{
    stderr.writeln("Error: ", msg);
}

/// Prints `Warning: <msg>` to stderr.
private void warn(scope const(char)[] msg) @system
{
    stderr.writeln("Warning: ", msg);
}

/++
Reports an unparseable `-r/--recipient` argument.

An `ssh-rsa` key gets a dedicated, clear "deferred in this build" message
(sparkles-age does not yet implement ssh-rsa recipients); anything else gets
rage's generic `Invalid recipient '…'.`
+/
private void failInvalidRecipient(scope const(char)[] r) @system
{
    if (isSshRsa(r))
        fail("ssh-rsa recipients are not supported in this build.");
    else
        fail("Invalid recipient '" ~ r ~ "'.");
}

/// Prints a $(REF CliError, sparkles,age_cli,errors)'s message to stderr.
private void failCliBare(CliError e) @system
{
    fail(message(e));
}

/// Prints a $(REF CliError, sparkles,age_cli,errors) whose message takes a
/// trailing filename (the `sameInputAndOutput` case).
private void failCliWithFile(CliError e, scope const(char)[] file) @system
{
    fail(message(e) ~ " '" ~ file ~ "'.");
}

/++
Renders a library error value that exposes an output-range `toString` (e.g.
`EncryptError`, `DecryptError`, `ArmorError`, `PassphraseError`) to
`Error: <message>` on stderr.

$(REF ParseError, sparkles,core_cli,text,errors) has $(B no) `toString`; render
it with $(LREF failIdentityFile) instead.
+/
private void failRendered(E)(in E e) @system
{
    auto w = appender!string;
    e.toString(w);
    fail(w[]);
}

/++
Reports a failure to parse the identity file at `path`.

$(REF ParseError, sparkles,core_cli,text,errors) is a plain `{code, offset}`
value with no message renderer, so this maps it to a clear, rage-flavoured
string. An SSH-classified rejection (recovered via
$(REF sshReason, sparkles,age,recipients,ssh_keys)) names the specific reason —
an encrypted OpenSSH key, an unsupported key type (e.g. ssh-rsa, deferred), or a
hardware key — otherwise an empty file or a malformed key line is reported.
+/
private void failIdentityFile(in ParseError e, string path) @system
{
    fail("'" ~ path ~ "': " ~ identityErrorReason(e));
}

/// The human-readable reason for an identity-file $(REF ParseError,
/// sparkles,core_cli,text,errors).
private string identityErrorReason(in ParseError e) @safe
{
    // An SSH-classified rejection packs its reason into the error; surface the
    // specific cause (these are the deferred/unsupported SSH cases).
    auto reason = sshReason(e);
    if (!reason.isNull)
    {
        final switch (reason.get)
        {
            case SshKeyParseReason.malformed:
                return "malformed SSH key.";
            case SshKeyParseReason.unsupportedKeyType:
                return "unsupported SSH key type "
                    ~ "(only ssh-ed25519 is supported in this build).";
            case SshKeyParseReason.hardwareKey:
                return "hardware-backed SSH keys (sk-…) cannot be used to decrypt.";
            case SshKeyParseReason.encryptedKey:
                return "the OpenSSH private key is encrypted; "
                    ~ "encrypted keys are not supported in this build.";
            case SshKeyParseReason.invalidStructure:
                return "the OpenSSH private key is structurally invalid.";
        }
    }

    if (e.code == ParseErrorCode.emptyInput)
        return "no identities found in the file.";

    return "invalid identity file.";
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────
//
// The `age` binary's main() drives real I/O (stdin/stdout, /dev/tty) and the
// getopt parser, so it cannot be exercised wholesale in the unit runner. These
// tests cover the pure, self-contained helpers that the flow leans on; the
// end-to-end behaviour is verified by the rage-parity snapshot suite and the
// README examples.

@("cli.age.looksLikeAgeFile.binaryMagic")
@safe pure nothrow @nogc
unittest
{
    assert(looksLikeAgeFile(cast(const(ubyte)[]) "age-encryption.org/v1\n"));
    assert(!looksLikeAgeFile(cast(const(ubyte)[]) "hello, plaintext"));
    assert(!looksLikeAgeFile(cast(const(ubyte)[]) ""));
}

@("cli.age.looksLikeAgeFile.armorMarker")
@safe pure nothrow @nogc
unittest
{
    // The ASCII-armor BEGIN marker (with tolerated leading whitespace) also
    // counts as an age file for the double-encryption warning.
    assert(looksLikeAgeFile(
        cast(const(ubyte)[]) "-----BEGIN AGE ENCRYPTED FILE-----\n"));
    assert(looksLikeAgeFile(
        cast(const(ubyte)[]) "\n  -----BEGIN AGE ENCRYPTED FILE-----\n"));
}

@("cli.age.isSshRsa")
@safe pure nothrow @nogc
unittest
{
    assert(isSshRsa("ssh-rsa AAAAB3NzaC1yc2E... user@host"));
    assert(!isSshRsa("ssh-ed25519 AAAAC3NzaC1lZDI1... user@host"));
    assert(!isSshRsa("age1qqq"));
    // The token must be followed by a space, not just be a prefix.
    assert(!isSshRsa("ssh-rsa"));
    assert(!isSshRsa("ssh-rsax foo"));
}

@("cli.age.stripAsciiWs")
@safe pure nothrow @nogc
unittest
{
    assert(stripAsciiWs("  age1abc  ") == "age1abc");
    assert(stripAsciiWs("age1abc\r") == "age1abc");
    assert(stripAsciiWs("\t\n age1abc \n") == "age1abc");
    assert(stripAsciiWs("") == "");
    assert(stripAsciiWs("   ") == "");
}

@("cli.age.splitLines")
@safe pure nothrow
unittest
{
    // A trailing newline does not produce a spurious final empty line beyond the
    // single empty tail (mirrors per-line iteration; callers skip blanks).
    auto a = splitLines("one\ntwo\nthree");
    assert(a == ["one", "two", "three"]);

    auto b = splitLines("one\ntwo\n");
    assert(b == ["one", "two", ""]);

    // CRLF leaves the '\r' attached for the caller to strip.
    auto c = splitLines("a\r\nb");
    assert(c == ["a\r", "b"]);

    auto empty = splitLines("");
    assert(empty == [""]);
}

@("cli.age.parseRecipientInto.x25519")
@safe
unittest
{
    import std.sumtype : match;

    // rage's published X25519 recipient.
    enum pk = "age1t7rxyev2z3rw82stdlrrepyc39nvn86l5078zqkf5uasdy86jp6svpy7pa";

    AnyRecipient[] recipients;
    assert(parseRecipientInto(pk, recipients), "a valid age1… recipient must parse");
    assert(recipients.length == 1);

    const isX25519 = recipients[0].match!((ref active) {
        alias A = typeof(active);
        return is(A == X25519Recipient);
    });
    assert(isX25519, "an age1… string must erase to X25519Recipient");
}

@("cli.age.parseRecipientInto.sshEd25519")
@safe
unittest
{
    import std.sumtype : match;

    // The verified ssh-ed25519 authorized_keys line from the library's own
    // ssh_ed25519 tests (the public half of rage's published OpenSSH key).
    enum line =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHsKLqeplhpW+uObz5dvMgjz1OxfM/XXUB+VHtZ6isGN"
        ~ " alice@rust";

    AnyRecipient[] recipients;
    assert(parseRecipientInto(line, recipients), "a valid ssh-ed25519 line must parse");
    assert(recipients.length == 1);

    const isSsh = recipients[0].match!((ref active) {
        alias A = typeof(active);
        return is(A == SshEd25519Recipient);
    });
    assert(isSsh, "an ssh-ed25519 line must erase to SshEd25519Recipient");
}

@("cli.age.parseRecipientInto.rejectsGarbageAndRsa")
@safe
unittest
{
    AnyRecipient[] recipients;
    // Plain garbage is not a recipient.
    assert(!parseRecipientInto("not-a-key", recipients));
    // An ssh-rsa key is recognised by isSshRsa but is not parseable as a
    // recipient here (deferred), so parseRecipientInto reports failure.
    assert(!parseRecipientInto("ssh-rsa AAAAB3NzaC1yc2EAAAA... user@host", recipients));
    // Nothing was appended on failure.
    assert(recipients.length == 0);
}

@("cli.age.decryptResult.handledVsPlaintext")
@safe
unittest
{
    // A "handled" result carries an exit code and no plaintext; an "ok" result
    // carries the bytes to write and exits 0.
    const handled = DecryptResult.done(1);
    assert(handled.handled);
    assert(handled.exitCode == 1);
    assert(handled.plaintext is null);

    auto bytes = cast(ubyte[]) [1, 2, 3];
    const okResult = DecryptResult.ok(bytes);
    assert(!okResult.handled);
    assert(okResult.plaintext == bytes);
}
