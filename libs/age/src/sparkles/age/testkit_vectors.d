/**
The full set of official age testkit vector names (§12 conformance).

These 114 vectors are vendored from the upstream age test suite into
`libs/age/tests/testkit/<name>`. Each file is a sequence of header lines, then
ONE blank line, then the raw binary age file (which may itself be ASCII-armored);
see `docs/specs/age/SPEC.md` §12 for the per-file format.

This module exposes the names as a compile-time `string[]` so the conformance
test driver can `import("testkit/<name>")` each vector body (resolved through
`stringImportPaths "tests"` in `libs/age/dub.sdl`) and iterate over the whole
suite with a `static foreach`. The array is `version (unittest)`-gated because it
exists solely to drive the test suite — it carries no runtime payload for library
consumers.

The list is sorted lexicographically and kept in lock-step with the vendored
directory: $(B if you add or remove a testkit file, update this array to match)
(the driver asserts `testkitVectorNames.length` equals the file count).

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.testkit_vectors;

version (unittest):

/// The 114 official age testkit vector names (sorted), one per file under
/// `libs/age/tests/testkit/`. See the module summary for the file format.
enum string[] testkitVectorNames = [
    "armor",
    "armor_crlf",
    "armor_empty_line_begin",
    "armor_empty_line_end",
    "armor_eol_between_padding",
    "armor_full_last_line",
    "armor_garbage_encoded",
    "armor_garbage_leading",
    "armor_garbage_trailing",
    "armor_header_crlf",
    "armor_headers",
    "armor_invalid_character_header",
    "armor_invalid_character_payload",
    "armor_long_line",
    "armor_lowercase",
    "armor_no_end_line",
    "armor_no_eol",
    "armor_no_match",
    "armor_no_padding",
    "armor_not_canonical",
    "armor_pgp_checksum",
    "armor_short_line",
    "armor_whitespace_begin",
    "armor_whitespace_end",
    "armor_whitespace_eol",
    "armor_whitespace_last_line",
    "armor_whitespace_line_start",
    "armor_whitespace_outside",
    "armor_wrong_type",
    "header_crlf",
    "hmac_bad",
    "hmac_extra_space",
    "hmac_garbage",
    "hmac_missing",
    "hmac_no_space",
    "hmac_not_canonical",
    "hmac_trailing_space",
    "hmac_truncated",
    "scrypt",
    "scrypt_and_x25519",
    "scrypt_bad_tag",
    "scrypt_double",
    "scrypt_extra_argument",
    "scrypt_long_file_key",
    "scrypt_no_match",
    "scrypt_not_canonical_body",
    "scrypt_not_canonical_salt",
    "scrypt_salt_long",
    "scrypt_salt_missing",
    "scrypt_salt_short",
    "scrypt_uppercase",
    "scrypt_work_factor_23",
    "scrypt_work_factor_hex",
    "scrypt_work_factor_leading_garbage",
    "scrypt_work_factor_leading_plus",
    "scrypt_work_factor_leading_zero_decimal",
    "scrypt_work_factor_leading_zero_octal",
    "scrypt_work_factor_missing",
    "scrypt_work_factor_negative",
    "scrypt_work_factor_overflow",
    "scrypt_work_factor_trailing_garbage",
    "scrypt_work_factor_wrong",
    "scrypt_work_factor_zero",
    "stanza_bad_start",
    "stanza_base64_padding",
    "stanza_empty_argument",
    "stanza_empty_body",
    "stanza_empty_last_line",
    "stanza_invalid_character",
    "stanza_long_line",
    "stanza_missing_body",
    "stanza_missing_final_line",
    "stanza_multiple_short_lines",
    "stanza_no_arguments",
    "stanza_not_canonical",
    "stanza_spurious_cr",
    "stanza_valid_characters",
    "stream_bad_tag",
    "stream_bad_tag_second_chunk",
    "stream_bad_tag_second_chunk_full",
    "stream_empty_payload",
    "stream_last_chunk_empty",
    "stream_last_chunk_full",
    "stream_last_chunk_full_second",
    "stream_missing_tag",
    "stream_no_chunks",
    "stream_no_final",
    "stream_no_final_full",
    "stream_no_final_two_chunks",
    "stream_no_final_two_chunks_full",
    "stream_no_nonce",
    "stream_short_chunk",
    "stream_short_nonce",
    "stream_short_second_chunk",
    "stream_three_chunks",
    "stream_trailing_garbage_long",
    "stream_trailing_garbage_short",
    "stream_two_chunks",
    "stream_two_final_chunks",
    "version_unsupported",
    "x25519",
    "x25519_bad_tag",
    "x25519_extra_argument",
    "x25519_grease",
    "x25519_identity",
    "x25519_long_file_key",
    "x25519_long_share",
    "x25519_low_order",
    "x25519_lowercase",
    "x25519_multiple_recipients",
    "x25519_no_match",
    "x25519_not_canonical_body",
    "x25519_not_canonical_share",
    "x25519_short_share",
];

/// The vendored testkit must carry exactly the 114 official vectors.
@("testkit_vectors.count")
@safe pure nothrow @nogc
unittest
{
    static assert(testkitVectorNames.length == 114,
        "the age testkit defines 114 conformance vectors");
}

/// The names are sorted and unique (the driver relies on a stable, dedup'd set).
/// Not `@nogc`: the lexicographic `<` over two `string`s lowers to a runtime
/// array compare that the compiler will not infer as `@nogc`.
@("testkit_vectors.sortedUnique")
@safe pure nothrow
unittest
{
    foreach (i; 1 .. testkitVectorNames.length)
        assert(testkitVectorNames[i - 1] < testkitVectorNames[i],
            "testkitVectorNames must be strictly sorted (sorted + unique)");
}
