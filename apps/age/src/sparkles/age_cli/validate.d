/++
Validation of parsed `age` options against the rage-compatible rules
(mutually exclusive flags, mode-specific constraints, missing
recipients/identities, etc.).

$(LREF validateOptions) takes a fully-parsed
$(REF AgeOptions, sparkles,age_cli,options) and returns the first
$(REF CliError, sparkles,age_cli,errors) that applies, or a null `Nullable`
when the command line is well-formed. It is `@safe pure nothrow @nogc`: it
inspects only the option fields and never touches the filesystem, so the one
rule that needs real-file resolution (identical input/output) is handled by a
small `@safe`, non-`pure` companion, $(LREF samePath), which the caller invokes
separately when both paths are concrete files.

# Check order

The order mirrors rage's `main.rs` so the $(I first) reported error matches the
reference tool for any command line that trips several rules at once:

$(OL
    $(LI `-e` and `-d` together → `mixedEncryptAndDecrypt`.)
    $(LI `-i` without `-e`/`-d` → `identityFlagAmbiguous`.)
    $(LI `-j` (plugins) → `pluginsUnsupported` — sparkles-age defers plugins
        entirely, so this fires regardless of mode, before the mode-specific
        checks rage would otherwise reach (`-j can't be used with -e` /
        `-i/--identity can't be used with -j`).)
    $(LI Decrypt mode: reject `-a`, `-p`, `-r`, `-R` in that order.)
    $(LI Encrypt mode (the default): `-p` is incompatible with `-i`/`-r`/`-R`
        (checked in that order); otherwise at least one recipient source or
        `-p` is required.)
)

The "missing identities" decrypt case and the "passphrase-encrypted file with
`-i`" case depend on inspecting the ciphertext at runtime (whether it is an
scrypt file), so they are $(B not) decided here; the main flow raises them after
parsing the header. The binary-to-TTY guard and the stdin-multiple-purposes
guard likewise depend on runtime I/O state and live in the I/O layer.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
+/
module sparkles.age_cli.validate;

import std.typecons : Nullable;

import sparkles.age_cli.errors : CliError;
import sparkles.age_cli.options : AgeOptions;

/++
Validate parsed options, returning the first applicable $(LREF CliError).

Pure, flag-only validation: every rule that can be decided from the option
fields alone (see the module-level check order). Rules that require touching the
filesystem (identical input/output) or runtime ciphertext/I/O state (missing
identities for a non-scrypt file, the binary-to-TTY guard,
stdin-used-twice) are handled by the caller — for the same-file check, via
$(LREF samePath).

Params:
    opts = the parsed command line.

Returns: a null `Nullable!CliError` if the options are well-formed, otherwise
        the first violated rule.
+/
Nullable!CliError validateOptions(in AgeOptions opts) @safe pure nothrow @nogc
{
    alias R = Nullable!CliError;

    // (1) Mode flags are mutually exclusive.
    if (opts.encrypt && opts.decrypt)
        return R(CliError.mixedEncryptAndDecrypt);

    // (2) `-i` is only meaningful once a mode is chosen.
    if (opts.identities.length && !opts.encrypt && !opts.decrypt)
        return R(CliError.identityFlagAmbiguous);

    // (3) Plugins are deferred in this build; any `-j` use is an error,
    //     regardless of mode.
    if (opts.pluginName !is null)
        return R(CliError.pluginsUnsupported);

    if (opts.decrypt)
        return validateDecrypt(opts);

    // Encryption is the default mode (no `-d`).
    return validateEncrypt(opts);
}

/// Decrypt-mode flag rejections (rage `decrypt()` prelude).
private Nullable!CliError validateDecrypt(in AgeOptions opts) @safe pure nothrow @nogc
{
    alias R = Nullable!CliError;

    if (opts.armor)
        return R(CliError.armorFlag);
    if (opts.passphrase)
        return R(CliError.passphraseFlag);
    if (opts.recipients.length)
        return R(CliError.recipientFlag);
    if (opts.recipientsFiles.length)
        return R(CliError.recipientsFileFlag);

    // Missing identities (for a non-scrypt file) is decided at runtime once the
    // header is parsed — not here.
    return R.init;
}

/// Encrypt-mode constraints (rage `encrypt()` prelude).
private Nullable!CliError validateEncrypt(in AgeOptions opts) @safe pure nothrow @nogc
{
    alias R = Nullable!CliError;

    if (opts.passphrase)
    {
        // `-p` excludes every recipient source. rage checks identity, then
        // recipient, then recipients-file — keep that order.
        if (opts.identities.length)
            return R(CliError.mixedIdentityAndPassphrase);
        if (opts.recipients.length)
            return R(CliError.mixedRecipientAndPassphrase);
        if (opts.recipientsFiles.length)
            return R(CliError.mixedRecipientsFileAndPassphrase);

        return R.init;
    }

    // No passphrase: at least one recipient source is required. (In encrypt
    // mode, `-i` derives recipients from the identities, so it counts.)
    if (!opts.recipients.length
        && !opts.recipientsFiles.length
        && !opts.identities.length)
        return R(CliError.missingRecipients);

    return R.init;
}

/++
Whether two path strings refer to the same on-disk file.

Used by the main flow to enforce rage's "Input and output are the same file"
rule. rage performs this check at the top level $(I after) the
`mixedEncryptAndDecrypt` / `identityFlagAmbiguous` checks and before dispatching
to the encrypt/decrypt path, so the caller should likewise call this once
$(LREF validateOptions) has returned null and both `opts.input` and
`opts.output` are set, reporting `CliError.sameInputAndOutput` on a `true`
result.

The strings `"-"` and `null` denote standard streams, never a real file, so
they never compare equal here. For two concrete paths the comparison resolves
symlinks / `.`/`..` via POSIX `realpath`; if $(B either) path cannot be
resolved (e.g. the output does not exist yet) the result is `false`. This
mirrors rage, which only reports the error when $(B both) paths canonicalize
successfully to the same file.

This is `@safe` but not `pure`/`@nogc`: it queries the filesystem.

Params:
    a = the first path (typically the input).
    b = the second path (typically the output).

Returns: `true` only when both are concrete paths resolving to the same file.
+/
bool samePath(string a, string b) @safe
{
    // Standard streams are never "the same file".
    if (a is null || b is null || a == "-" || b == "-")
        return false;

    auto ra = realPathOf(a);
    auto rb = realPathOf(b);

    // rage only errors when *both* paths canonicalize successfully.
    if (ra is null || rb is null)
        return false;

    return ra == rb;
}

// Resolve `p` to its canonical absolute path, or `null` if it cannot be
// resolved (e.g. it does not exist).
private string realPathOf(string p) @safe
{
    version (Posix)
    {
        import core.sys.posix.stdlib : realpath;
        import core.stdc.stdlib : free;
        import std.string : toStringz, fromStringz;

        return () @trusted {
            auto c = realpath(p.toStringz, null);
            if (c is null)
                return string.init;
            scope (exit) free(c);
            return c.fromStringz.idup;
        }();
    }
    else
    {
        import std.file : exists;
        import std.path : absolutePath, buildNormalizedPath;

        return p.exists ? p.absolutePath.buildNormalizedPath : null;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — every VALIDATION MATRIX case
// ─────────────────────────────────────────────────────────────────────────────

@("cli.validate.wellFormed.encryptWithRecipient")
@safe pure nothrow
unittest
{
    AgeOptions o;
    o.recipients = ["age1abc"]; // default (no -d) => encrypt
    assert(validateOptions(o).isNull);
}

@("cli.validate.wellFormed.encryptExplicitWithRecipientsFile")
@safe pure nothrow
unittest
{
    AgeOptions o;
    o.encrypt = true;
    o.recipientsFiles = ["rec.txt"];
    assert(validateOptions(o).isNull);
}

@("cli.validate.wellFormed.encryptWithPassphrase")
@safe pure nothrow @nogc
unittest
{
    AgeOptions o;
    o.passphrase = true;
    assert(validateOptions(o).isNull);
}

@("cli.validate.wellFormed.encryptWithIdentityExplicit")
@safe pure nothrow
unittest
{
    // -i in encrypt mode derives recipients; valid as long as -e is explicit.
    AgeOptions o;
    o.encrypt = true;
    o.identities = ["key.txt"];
    assert(validateOptions(o).isNull);
}

@("cli.validate.wellFormed.decryptWithIdentity")
@safe pure nothrow
unittest
{
    AgeOptions o;
    o.decrypt = true;
    o.identities = ["key.txt"];
    assert(validateOptions(o).isNull);
}

@("cli.validate.wellFormed.decryptNoIdentity")
@safe pure nothrow @nogc
unittest
{
    // Bare `-d`: missing-identities is a *runtime* decision (scrypt vs not),
    // so flag validation must accept it.
    AgeOptions o;
    o.decrypt = true;
    assert(validateOptions(o).isNull);
}

@("cli.validate.mixedEncryptAndDecrypt")
@safe pure nothrow @nogc
unittest
{
    AgeOptions o;
    o.encrypt = true;
    o.decrypt = true;
    assert(validateOptions(o).get == CliError.mixedEncryptAndDecrypt);
}

@("cli.validate.identityFlagAmbiguous")
@safe pure nothrow
unittest
{
    // -i without -e or -d.
    AgeOptions o;
    o.identities = ["key.txt"];
    assert(validateOptions(o).get == CliError.identityFlagAmbiguous);
}

@("cli.validate.encrypt.mixedIdentityAndPassphrase")
@safe pure nothrow
unittest
{
    AgeOptions o;
    o.encrypt = true;
    o.passphrase = true;
    o.identities = ["key.txt"];
    assert(validateOptions(o).get == CliError.mixedIdentityAndPassphrase);
}

@("cli.validate.encrypt.mixedRecipientAndPassphrase")
@safe pure nothrow
unittest
{
    AgeOptions o;
    o.encrypt = true;
    o.passphrase = true;
    o.recipients = ["age1abc"];
    assert(validateOptions(o).get == CliError.mixedRecipientAndPassphrase);
}

@("cli.validate.encrypt.mixedRecipientsFileAndPassphrase")
@safe pure nothrow
unittest
{
    AgeOptions o;
    o.passphrase = true; // default mode => encrypt
    o.recipientsFiles = ["rec.txt"];
    assert(validateOptions(o).get == CliError.mixedRecipientsFileAndPassphrase);
}

@("cli.validate.encrypt.passphraseChecksIdentityFirst")
@safe pure nothrow
unittest
{
    // When -p is combined with several recipient sources, identity is reported
    // first (matching rage's check order).
    AgeOptions o;
    o.encrypt = true;
    o.passphrase = true;
    o.identities = ["key.txt"];
    o.recipients = ["age1abc"];
    o.recipientsFiles = ["rec.txt"];
    assert(validateOptions(o).get == CliError.mixedIdentityAndPassphrase);
}

@("cli.validate.encrypt.missingRecipients")
@safe pure nothrow @nogc
unittest
{
    // -e (or default) with no recipients and no -p.
    AgeOptions o;
    o.encrypt = true;
    assert(validateOptions(o).get == CliError.missingRecipients);
}

@("cli.validate.encrypt.missingRecipientsDefaultMode")
@safe pure nothrow @nogc
unittest
{
    // Bare command line (no flags at all) => encrypt mode, no recipients.
    AgeOptions o;
    assert(validateOptions(o).get == CliError.missingRecipients);
}

@("cli.validate.decrypt.rejectsArmor")
@safe pure nothrow @nogc
unittest
{
    AgeOptions o;
    o.decrypt = true;
    o.armor = true;
    assert(validateOptions(o).get == CliError.armorFlag);
}

@("cli.validate.decrypt.rejectsPassphrase")
@safe pure nothrow @nogc
unittest
{
    AgeOptions o;
    o.decrypt = true;
    o.passphrase = true;
    assert(validateOptions(o).get == CliError.passphraseFlag);
}

@("cli.validate.decrypt.rejectsRecipient")
@safe pure nothrow
unittest
{
    AgeOptions o;
    o.decrypt = true;
    o.recipients = ["age1abc"];
    assert(validateOptions(o).get == CliError.recipientFlag);
}

@("cli.validate.decrypt.rejectsRecipientsFile")
@safe pure nothrow
unittest
{
    AgeOptions o;
    o.decrypt = true;
    o.recipientsFiles = ["rec.txt"];
    assert(validateOptions(o).get == CliError.recipientsFileFlag);
}

@("cli.validate.decrypt.armorCheckedBeforeRecipient")
@safe pure nothrow
unittest
{
    // rage's decrypt prelude checks armor first.
    AgeOptions o;
    o.decrypt = true;
    o.armor = true;
    o.recipients = ["age1abc"];
    assert(validateOptions(o).get == CliError.armorFlag);
}

@("cli.validate.pluginsUnsupported.encrypt")
@safe pure nothrow @nogc
unittest
{
    AgeOptions o;
    o.encrypt = true;
    o.pluginName = "yubikey";
    assert(validateOptions(o).get == CliError.pluginsUnsupported);
}

@("cli.validate.pluginsUnsupported.decrypt")
@safe pure nothrow
unittest
{
    // -j is deferred regardless of mode; reported before mode-specific checks.
    AgeOptions o;
    o.decrypt = true;
    o.pluginName = "yubikey";
    o.identities = ["key.txt"];
    assert(validateOptions(o).get == CliError.pluginsUnsupported);
}

@("cli.validate.precedence.mixedModeBeatsAmbiguousIdentity")
@safe pure nothrow
unittest
{
    // -e -d -i: the mode conflict is reported first.
    AgeOptions o;
    o.encrypt = true;
    o.decrypt = true;
    o.identities = ["key.txt"];
    assert(validateOptions(o).get == CliError.mixedEncryptAndDecrypt);
}

@("cli.validate.precedence.ambiguousIdentityBeatsPlugin")
@safe pure nothrow
unittest
{
    // -i (no mode) + -j: ambiguous-identity is checked before the plugin guard.
    AgeOptions o;
    o.identities = ["key.txt"];
    o.pluginName = "yubikey";
    assert(validateOptions(o).get == CliError.identityFlagAmbiguous);
}

@("cli.validate.samePath.standardStreamsNeverEqual")
@safe
unittest
{
    assert(!samePath("-", "-"));
    assert(!samePath(null, "out.txt"));
    assert(!samePath("in.txt", "-"));
}

@("cli.validate.samePath.sameFileResolves")
@safe
unittest
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    import std.conv : to;
    import std.datetime.systime : Clock;

    auto dir = tempDir;
    auto name = buildPath(dir, "age-cli-samepath-" ~ Clock.currTime.toUnixTime.to!string ~ ".tmp");
    write(name, "x");
    scope (exit) remove(name);

    // The same concrete file resolves equal to itself; a different,
    // non-existent path does not.
    assert(samePath(name, name));
    assert(!samePath(name, name ~ ".other"));
}
