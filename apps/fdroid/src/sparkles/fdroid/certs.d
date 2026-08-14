/**
Parsing `apksigner verify --print-certs` output.

The signing certificate's SHA-256 fingerprint is what
`AllowedAPKSigningKeys` pins (`FDR6`), so the publisher has to read it back out
of a signed APK to check it against the metadata before publishing. Only the
parsing lives here, so it can be tested against literal tool output rather than
by signing something.
*/
module sparkles.fdroid.certs;

@safe:

/// Lowercase hex SHA-256 of a signer's DER certificate, as
/// `AllowedAPKSigningKeys` spells it.
alias Fingerprint = string;

/**
Extracts every signer's SHA-256 fingerprint from `apksigner verify
--print-certs` output, in signer order.

Returns an empty slice when the text contains none — which is what an unsigned
APK produces, and is a refusal to publish rather than an error to recover from.
*/
Fingerprint[] signerFingerprints(string printCertsOutput) pure
{
    import std.algorithm : startsWith;
    import std.array : appender;
    import std.ascii : isHexDigit, toLower;
    import std.string : indexOf, lineSplitter, strip;

    // apksigner prints one line per signer per digest algorithm:
    //   Signer #1 certificate SHA-256 digest: 1a57273081cb…
    // Match on the digest label rather than the "Signer #N" prefix, which
    // differs between the verify and the lineage subcommands.
    enum marker = "certificate SHA-256 digest:";

    auto found = appender!(Fingerprint[]);
    foreach (line; printCertsOutput.lineSplitter)
    {
        const at = line.indexOf(marker);
        if (at < 0)
            continue;

        const value = line[at + marker.length .. $].strip;
        if (value.length != 64)
            continue;

        auto lowered = new char[64];
        bool hex = true;
        foreach (i, c; value)
        {
            if (!c.isHexDigit)
            {
                hex = false;
                break;
            }
            lowered[i] = c.toLower;
        }
        if (hex)
            found ~= lowered.idup;
    }
    return found[];
}

@("fdroid.certs.readsRealApksignerOutput")
@safe unittest
{
    // Verbatim from `apksigner verify --print-certs` on a v2/v3-signed APK.
    enum output = "Signer #1 certificate DN: CN=probe\n"
        ~ "Signer #1 certificate SHA-256 digest: 1a57273081cb21aaa76bd2e3bdd9b111e40fe0f04074b21a6f184dd08e8956ce\n"
        ~ "Signer #1 certificate SHA-1 digest: 8a1f0c1c6ac0f0f5b7ef1f8e0b2a3c4d5e6f7a8b\n"
        ~ "Signer #1 certificate MD5 digest: 0123456789abcdef0123456789abcdef\n";

    const fps = signerFingerprints(output);
    assert(fps.length == 1);
    assert(fps[0] == "1a57273081cb21aaa76bd2e3bdd9b111e40fe0f04074b21a6f184dd08e8956ce");
}

@("fdroid.certs.normalizesCaseAndHandlesMultipleSigners")
@safe unittest
{
    enum output = "Signer #1 certificate SHA-256 digest: AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899\n"
        ~ "Signer #2 certificate SHA-256 digest: 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff\n";

    const fps = signerFingerprints(output);
    assert(fps.length == 2);
    // AllowedAPKSigningKeys is matched lowercase.
    assert(fps[0] == "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899");
    assert(fps[1] == "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
}

@("fdroid.certs.yieldsNothingForUnsignedOrJunk")
@safe unittest
{
    // What an unsigned APK produces.
    assert(signerFingerprints("DOES NOT VERIFY\nERROR: Missing META-INF/MANIFEST.MF\n").length == 0);
    assert(signerFingerprints("").length == 0);
    // Right label, wrong shape: neither is a fingerprint.
    assert(signerFingerprints("certificate SHA-256 digest: short\n").length == 0);
    assert(signerFingerprints(
        "certificate SHA-256 digest: zzbbccddeeff00112233445566778899aabbccddeeff00112233445566778899\n").length == 0);
}
