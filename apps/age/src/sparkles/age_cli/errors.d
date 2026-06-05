/++
Error types and human-readable messages shared by the `age` CLI flow,
mirroring the messages produced by the rage reference implementation.

$(LREF CliError) enumerates every validation/usage failure the `age` tool can
report $(I before) handing off to the `sparkles.age` library, and
$(LREF message) renders each one to the exact string rage prints (sourced from
rage's `i18n/en-US/rage.ftl` and the `tests/cmd/rage/*.toml` snapshots).

# Message shape

The returned text is the $(I body) of the error only. The caller (the `age`
main flow) is responsible for the `Error: ` prefix and the trailing UX footer

```
[ Did rage not do what you expected? Could an error be more useful? ]
[ Tell us: https://str4d.xyz/rage/report                            ]
```

so this module stays a pure, allocation-free string table. Several errors carry
a second "recommendation" line; those are returned as a single string with an
embedded `'\n'` (matching how rage's `wlnfl!`/`wfl!` pair stacks them), e.g.

```
Missing recipients.
Did you forget to specify -r/--recipient?
```

The `-i/--identity` "missing identities" case has two variants depending on
whether `-` (stdin) was requested as an identity source; both are exposed as
distinct $(LREF CliError) members.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
+/
module sparkles.age_cli.errors;

@safe pure nothrow @nogc:

/++
Every usage/validation failure the `age` CLI can report.

These mirror the variants of rage's `error::Error`, `error::EncryptError`, and
`error::DecryptError` that are reachable from option validation (the ones whose
messages are pinned by the `tests/cmd/rage/*.toml` snapshots). Runtime failures
that originate inside the `sparkles.age` library (bad recipient encodings,
decryption failures, I/O errors) are reported via the library's own error types,
not through this enum.
+/
enum CliError
{
    /// `-e/--encrypt` and `-d/--decrypt` were both given.
    mixedEncryptAndDecrypt,

    /// `-i/--identity` was given without `-e/--encrypt` or `-d/--decrypt`,
    /// leaving the intended mode ambiguous.
    identityFlagAmbiguous,

    /// The positional INPUT and `-o/--output` resolve to the same file.
    sameInputAndOutput,

    // ── Encryption mode ──────────────────────────────────────────────────────

    /// `-i/--identity` combined with `-p/--passphrase`.
    mixedIdentityAndPassphrase,

    /// `-r/--recipient` combined with `-p/--passphrase`.
    mixedRecipientAndPassphrase,

    /// `-R/--recipients-file` combined with `-p/--passphrase`.
    mixedRecipientsFileAndPassphrase,

    /// Encryption requested with neither recipients nor a passphrase.
    missingRecipients,

    /// `-j` (plugins) given in encryption mode.
    pluginNameFlag,

    // ── Decryption mode ──────────────────────────────────────────────────────

    /// `-a/--armor` given with `-d/--decrypt`.
    armorFlag,

    /// `-p/--passphrase` given with `-d/--decrypt`.
    passphraseFlag,

    /// `-r/--recipient` given with `-d/--decrypt`.
    recipientFlag,

    /// `-R/--recipients-file` given with `-d/--decrypt`.
    recipientsFileFlag,

    /// `-i/--identity` given for a passphrase-encrypted (scrypt) file.
    decryptMixedIdentityAndPassphrase,

    /// `-i/--identity` combined with `-j` in decryption mode.
    decryptMixedIdentityAndPluginName,

    /// Decryption requested with no identities, and the file is not
    /// passphrase-encrypted. No `-` (stdin) identity was requested.
    missingIdentities,

    /// Like $(LREF missingIdentities), but `-i -` requested reading the
    /// identity from standard input (which never arrived).
    missingIdentitiesStdin,

    /// `-j` (plugins) is not supported in this build.
    pluginsUnsupported,

    /// Standard input was claimed for more than one purpose (e.g. as both the
    /// INPUT file and an `-i -` identity source).
    stdinMultiplePurposes,

    /// Refusing to write binary ciphertext to a terminal without `-o`/`-a`.
    binaryToTerminal,
}

/++
The exact rage-style message body for a $(LREF CliError).

Returns a string literal (no allocation, valid forever). Multi-line messages
embed `'\n'` between the error line and its recommendation line, matching
rage's stacked `wlnfl!`/`wfl!` output. The caller prepends `Error: ` and
appends the shared UX footer.

Params:
    e = the error to render.

Returns: the message body for `e`.
+/
string message(CliError e)
{
    final switch (e)
    {
        // ── error::Error ──────────────────────────────────────────────────────
        case CliError.mixedEncryptAndDecrypt:
            return "-e/--encrypt can't be used with -d/--decrypt.";

        case CliError.identityFlagAmbiguous:
            return "-i/--identity requires either -e/--encrypt or -d/--decrypt.";

        case CliError.sameInputAndOutput:
            // rage interpolates the filename (`Input and output are the same
            // file '{$filename}'.`). The filename is appended by the caller.
            return "Input and output are the same file";

        // ── error::EncryptError ────────────────────────────────────────────────
        case CliError.mixedIdentityAndPassphrase:
            return "-i/--identity can't be used with -p/--passphrase.";

        case CliError.mixedRecipientAndPassphrase:
            return "-r/--recipient can't be used with -p/--passphrase.";

        case CliError.mixedRecipientsFileAndPassphrase:
            return "-R/--recipients-file can't be used with -p/--passphrase.";

        case CliError.missingRecipients:
            return "Missing recipients.\nDid you forget to specify -r/--recipient?";

        case CliError.pluginNameFlag:
            return "-j can't be used with -e/--encrypt.";

        // ── error::DecryptError ────────────────────────────────────────────────
        case CliError.armorFlag:
            return "-a/--armor can't be used with -d/--decrypt.\n"
                ~ "Note that armored files are detected automatically.";

        case CliError.passphraseFlag:
            return "-p/--passphrase can't be used with -d/--decrypt.\n"
                ~ "Note that passphrase-encrypted files are detected automatically.";

        case CliError.recipientFlag:
            return "-r/--recipient can't be used with -d/--decrypt.\n"
                ~ "Did you mean to use -i/--identity to specify a private key?";

        case CliError.recipientsFileFlag:
            return "-R/--recipients-file can't be used with -d/--decrypt.\n"
                ~ "Did you mean to use -i/--identity to specify a private key?";

        case CliError.decryptMixedIdentityAndPassphrase:
            return "-i/--identity can't be used with passphrase-encrypted files.";

        case CliError.decryptMixedIdentityAndPluginName:
            return "-i/--identity can't be used with -j.";

        case CliError.missingIdentities:
            return "Missing identities.\nDid you forget to specify -i/--identity?";

        case CliError.missingIdentitiesStdin:
            return "Missing identities.\n"
                ~ "Did you forget to provide the identity over standard input?";

        // ── sparkles-age-specific ──────────────────────────────────────────────
        case CliError.pluginsUnsupported:
            return "-j/plugins are not supported in this build.";

        case CliError.stdinMultiplePurposes:
            return "Standard input can't be used for multiple purposes.";

        case CliError.binaryToTerminal:
            return "Refusing to output binary to a terminal. "
                ~ "Use -a/--armor or -o to write to a file.";
    }
}

///
@safe pure nothrow @nogc
unittest
{
    assert(CliError.mixedEncryptAndDecrypt.message
        == "-e/--encrypt can't be used with -d/--decrypt.");

    // Multi-line messages stack the recommendation under the error.
    assert(CliError.missingRecipients.message
        == "Missing recipients.\nDid you forget to specify -r/--recipient?");
}

@("cli.errors.allVariantsHaveNonEmptyMessage")
@safe pure nothrow @nogc
unittest
{
    import std.traits : EnumMembers;

    static foreach (e; EnumMembers!CliError)
        assert(message(e).length > 0);
}

@("cli.errors.decryptRecommendationLines")
@safe pure nothrow @nogc
unittest
{
    // The decrypt-mode rejections each carry a second recommendation line.
    assert(CliError.armorFlag.message
        == "-a/--armor can't be used with -d/--decrypt.\n"
            ~ "Note that armored files are detected automatically.");
    assert(CliError.passphraseFlag.message
        == "-p/--passphrase can't be used with -d/--decrypt.\n"
            ~ "Note that passphrase-encrypted files are detected automatically.");
    assert(CliError.recipientFlag.message
        == "-r/--recipient can't be used with -d/--decrypt.\n"
            ~ "Did you mean to use -i/--identity to specify a private key?");
    // -R reuses the same recommendation line as -r.
    assert(CliError.recipientsFileFlag.message
        == "-R/--recipients-file can't be used with -d/--decrypt.\n"
            ~ "Did you mean to use -i/--identity to specify a private key?");
}

@("cli.errors.missingIdentitiesVariants")
@safe pure nothrow @nogc
unittest
{
    assert(CliError.missingIdentities.message
        == "Missing identities.\nDid you forget to specify -i/--identity?");
    assert(CliError.missingIdentitiesStdin.message
        == "Missing identities.\n"
            ~ "Did you forget to provide the identity over standard input?");
}
