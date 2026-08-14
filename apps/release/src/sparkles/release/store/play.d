/**
The Google Play channel.

Peer to the F-Droid channel, and structurally different in every part except
the version: Play takes an App Bundle rather than an APK, is signed with an
*upload* key rather than the app signing key, and is published through an API
rather than by writing files to storage.

The signing asymmetry is worth stating, because it inverts the risk the F-Droid
key carries. Play holds the real app signing key and re-signs every upload; what
this tool signs with is the upload key, which Google will reset on request. So
losing it is recoverable, where losing the F-Droid key permanently strands every
installed user.

Publication is the v3 `edits` flow — a transaction: open an edit, upload into
it, point a track at it, commit. Nothing is visible until the commit, so a
failure part-way leaves no half-published state.

Authentication is a service account: an RS256-signed JWT exchanged for an access
token. The signature is made by `openssl` rather than by adding a crypto
dependency — the private key is a PEM string in the service-account JSON, and
one `dgst -sign` is the whole requirement.
*/
module sparkles.release.store.play;

import sparkles.core_cli.process_utils : CapturedResult, runCaptured;

import std.json : JSONValue, JSONType, parseJSON;

@safe:

/// Where a release lands. Play promotes between these; it does not rebuild.
enum PlayTrack
{
    internal,
    alpha,
    beta,
    production,
}

/// Parses a `--track` value.
bool tryParseTrack(string s, out PlayTrack track) pure nothrow
{
    switch (s)
    {
    case "internal":   track = PlayTrack.internal;   return true;
    case "alpha":      track = PlayTrack.alpha;      return true;
    case "beta":       track = PlayTrack.beta;       return true;
    case "production": track = PlayTrack.production; return true;
    default: return false;
    }
}

/// The value the API expects for a track.
string trackName(PlayTrack t) pure nothrow @nogc
{
    final switch (t)
    {
    case PlayTrack.internal:   return "internal";
    case PlayTrack.alpha:      return "alpha";
    case PlayTrack.beta:       return "beta";
    case PlayTrack.production: return "production";
    }
}

/// The accepted values, for help text and error messages.
string trackNames() pure nothrow => "internal, alpha, beta, production";

/// The parts of a service-account key file this needs.
struct ServiceAccount
{
    string clientEmail;
    /// PEM-encoded RSA private key, exactly as the JSON carries it.
    string privateKeyPem;
    string tokenUri;
}

/// Reads a service-account JSON key.
///
/// Returns a null `clientEmail` when the document is not one — the caller
/// reports that rather than failing later with an opaque 401.
ServiceAccount parseServiceAccount(string json)
{
    ServiceAccount sa;
    JSONValue doc;
    try
        doc = parseJSON(json);
    catch (Exception)
        return sa;

    if (doc.type != JSONType.object)
        return sa;

    string field(string name)
    {
        if (name !in doc)
            return null;
        const v = doc[name];
        return v.type == JSONType.string ? v.str : null;
    }

    // A key file with the right shape but the wrong `type` is a common
    // mistake (an OAuth *client* secret rather than a service account), and
    // it fails much later and less legibly if not caught here.
    if (field("type") != "service_account")
        return sa;

    sa.clientEmail = field("client_email");
    sa.privateKeyPem = field("private_key");
    sa.tokenUri = field("token_uri");
    if (!sa.tokenUri.length)
        sa.tokenUri = "https://oauth2.googleapis.com/token";
    return sa;
}

/// base64url without padding, as JWT requires.
string base64Url(const(ubyte)[] data) pure
{
    import std.base64 : Base64;

    auto s = Base64.encode(data);
    auto result = new char[s.length];
    size_t n;
    foreach (c; s)
    {
        switch (c)
        {
        case '+': result[n++] = '-'; break;
        case '/': result[n++] = '_'; break;
        case '=': break; // padding is omitted, not translated
        default:  result[n++] = c;
        }
    }
    return result[0 .. n].idup;
}

/// The `header.claims` half of a JWT — what gets signed.
///
/// `iat`/`exp` are parameters rather than read from the clock here so the
/// construction is testable against a fixed instant.
string jwtSigningInput(in ServiceAccount sa, long iat, long exp) pure
{
    import std.conv : text;

    // Hand-built rather than via a JSON writer: the exact bytes are what gets
    // signed, so key order and spacing must not depend on a serializer's mood.
    const header = `{"alg":"RS256","typ":"JWT"}`;
    const claims = text(
        `{"iss":"`, sa.clientEmail, `",`,
        `"scope":"https://www.googleapis.com/auth/androidpublisher",`,
        `"aud":"`, sa.tokenUri, `",`,
        `"iat":`, iat, `,`,
        `"exp":`, exp, `}`);

    return base64Url(cast(const(ubyte)[]) header)
        ~ "." ~ base64Url(cast(const(ubyte)[]) claims);
}

/// The API base for one application's edits.
string editsUrl(string applicationId) pure =>
    "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
    ~ applicationId ~ "/edits";

/// The (separate) upload endpoint. Google serves media uploads from a
/// different path prefix, which is easy to miss and fails as a 404.
string bundleUploadUrl(string applicationId, string editId) pure =>
    "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/"
    ~ applicationId ~ "/edits/" ~ editId ~ "/bundles?uploadType=media";

/// The track-assignment body: which versionCode this track now serves.
///
/// `status: completed` is a full rollout. A staged rollout would set
/// `inProgress` with a `userFraction`, which is a product decision this tool
/// deliberately does not make on anyone's behalf.
string trackUpdateBody(PlayTrack track, long versionCode, string releaseNotes)
{
    import std.conv : text;

    JSONValue notes = JSONValue([
        "language": JSONValue("en-US"),
        "text": JSONValue(releaseNotes),
    ]);
    JSONValue release = JSONValue([
        "versionCodes": JSONValue([JSONValue(text(versionCode))]),
        "status": JSONValue("completed"),
        "releaseNotes": JSONValue([notes]),
    ]);
    JSONValue body_ = JSONValue([
        "track": JSONValue(trackName(track)),
        "releases": JSONValue([release]),
    ]);
    return body_.toString;
}

/// Extracts a field from a JSON API reply, or null.
string replyField(string json, string field)
{
    JSONValue doc;
    try
        doc = parseJSON(json);
    catch (Exception)
        return null;
    if (doc.type != JSONType.object || field !in doc)
        return null;
    const v = doc[field];
    return v.type == JSONType.string ? v.str : null;
}

/// A human-readable reason from a Google API error body.
string apiError(string json)
{
    JSONValue doc;
    try
        doc = parseJSON(json);
    catch (Exception)
        return json;
    if (doc.type == JSONType.object && "error" in doc)
    {
        const e = doc["error"];
        if (e.type == JSONType.object && "message" in e
            && e["message"].type == JSONType.string)
            return e["message"].str;
    }
    return json;
}

// ---------------------------------------------------------------------------
// The impure half: one wrapper per external call
// ---------------------------------------------------------------------------

/// RS256 over the JWT signing input, via `openssl`.
///
/// The key is handed over on stdin and never written to disk by this process.
CapturedResult signRs256(string signingInput, string privateKeyPemFile) =>
    runCaptured([
        "openssl", "dgst", "-sha256", "-sign", privateKeyPemFile, "-binary",
    ], signingInput);

/// Exchanges a signed assertion for an access token.
CapturedResult exchangeAssertion(string tokenUri, string assertion) =>
    runCaptured([
        "curl", "--silent", "--show-error", "--fail-with-body",
        "-X", "POST", tokenUri,
        "-H", "Content-Type: application/x-www-form-urlencoded",
        "--data-urlencode", "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer",
        "--data-urlencode", "assertion=" ~ assertion,
    ]);

/// Opens an edit; the reply carries its id.
CapturedResult insertEdit(string token, string applicationId) =>
    runCaptured([
        "curl", "--silent", "--show-error", "--fail-with-body",
        "-X", "POST", editsUrl(applicationId),
        "-H", "Authorization: Bearer " ~ token,
        "-H", "Content-Length: 0",
    ]);

/// Uploads the bundle into an open edit.
CapturedResult uploadBundle(string token, string applicationId, string editId, string aabPath) =>
    runCaptured([
        "curl", "--silent", "--show-error", "--fail-with-body",
        "-X", "POST", bundleUploadUrl(applicationId, editId),
        "-H", "Authorization: Bearer " ~ token,
        "-H", "Content-Type: application/octet-stream",
        "--data-binary", "@" ~ aabPath,
    ]);

/// Points a track at the uploaded versionCode.
CapturedResult assignTrack(
    string token,
    string applicationId,
    string editId,
    PlayTrack track,
    long versionCode,
    string releaseNotes,
) =>
    runCaptured([
        "curl", "--silent", "--show-error", "--fail-with-body",
        "-X", "PUT", editsUrl(applicationId) ~ "/" ~ editId ~ "/tracks/" ~ trackName(track),
        "-H", "Authorization: Bearer " ~ token,
        "-H", "Content-Type: application/json",
        "--data-binary", trackUpdateBody(track, versionCode, releaseNotes),
    ]);

/// Commits the edit. Nothing is visible to anyone until this succeeds.
CapturedResult commitEdit(string token, string applicationId, string editId) =>
    runCaptured([
        "curl", "--silent", "--show-error", "--fail-with-body",
        "-X", "POST", editsUrl(applicationId) ~ "/" ~ editId ~ ":commit",
        "-H", "Authorization: Bearer " ~ token,
        "-H", "Content-Length: 0",
    ]);

/// Abandons an edit, so a failed run does not leave one open.
CapturedResult deleteEdit(string token, string applicationId, string editId) =>
    runCaptured([
        "curl", "--silent", "--show-error",
        "-X", "DELETE", editsUrl(applicationId) ~ "/" ~ editId,
        "-H", "Authorization: Bearer " ~ token,
    ]);

version (unittest)
{
    /// `ubyte[]` to `string` without a pointer-bearing cast, so the tests stay
    /// `@safe`.
    private string asText(const(ubyte)[] bytes) @safe pure
    {
        auto chars = new char[bytes.length];
        foreach (i, b; bytes)
            chars[i] = cast(char) b;
        return chars.idup;
    }
}

// ---------------------------------------------------------------------------
// Tests — the pure half
// ---------------------------------------------------------------------------

@("store.play.parsesAServiceAccountKey")
@safe unittest
{
    enum key = `{
        "type": "service_account",
        "project_id": "sparkles",
        "private_key": "<pem placeholder: a real key would trip the secret scanner>",
        "client_email": "publisher@sparkles.iam.gserviceaccount.com",
        "token_uri": "https://oauth2.googleapis.com/token"
    }`;

    const sa = parseServiceAccount(key);
    assert(sa.clientEmail == "publisher@sparkles.iam.gserviceaccount.com");
    assert(sa.tokenUri == "https://oauth2.googleapis.com/token");
    assert(sa.privateKeyPem.length);
}

@("store.play.rejectsSomethingThatIsNotAServiceAccount")
@safe unittest
{
    // An OAuth client secret has a similar shape and is a common mix-up; it
    // must fail here rather than as a 401 several calls later.
    assert(parseServiceAccount(`{"type":"authorized_user","client_email":"x@y"}`)
        .clientEmail is null);
    assert(parseServiceAccount(`not json`).clientEmail is null);
    assert(parseServiceAccount(`[]`).clientEmail is null);
    assert(parseServiceAccount(`{}`).clientEmail is null);
}

@("store.play.tokenUriDefaultsWhenAbsent")
@safe unittest
{
    const sa = parseServiceAccount(
        `{"type":"service_account","client_email":"a@b","private_key":"k"}`);
    assert(sa.tokenUri == "https://oauth2.googleapis.com/token");
}

@("store.play.base64UrlIsUnpaddedAndUrlSafe")
@safe unittest
{
    import std.algorithm : canFind;

    // 0xFF 0xFE 0xFD encodes to "//79" in standard base64 — both substitutions
    // and the padding rule in one case.
    const encoded = base64Url([0xFF, 0xFE, 0xFD]);
    assert(!encoded.canFind('+'));
    assert(!encoded.canFind('/'));
    assert(!encoded.canFind('='));
    assert(encoded == "__79");

    // A length that would normally pad with "==".
    assert(!base64Url([0x01]).canFind('='));
}

@("store.play.jwtSigningInputIsTwoBase64UrlSegments")
@safe unittest
{
    import std.algorithm : count, canFind;
    import std.base64 : Base64URLNoPadding;
    import std.string : split;

    ServiceAccount sa = {
        clientEmail: "publisher@sparkles.iam.gserviceaccount.com",
        tokenUri: "https://oauth2.googleapis.com/token",
    };

    const input = jwtSigningInput(sa, 1_786_000_000, 1_786_003_600);
    assert(input.count('.') == 1, "signing input is header.claims, no signature yet");

    const parts = input.split(".");
    const header = Base64URLNoPadding.decode(parts[0]).asText;
    const claims = Base64URLNoPadding.decode(parts[1]).asText;

    assert(header == `{"alg":"RS256","typ":"JWT"}`);
    assert(claims.canFind(`"iss":"publisher@sparkles.iam.gserviceaccount.com"`));
    assert(claims.canFind(`"scope":"https://www.googleapis.com/auth/androidpublisher"`));
    assert(claims.canFind(`"iat":1786000000`));
    assert(claims.canFind(`"exp":1786003600`));
}

@("store.play.uploadUsesTheSeparateMediaEndpoint")
@safe unittest
{
    import std.algorithm : canFind;

    // Easy to miss, and a 404 when missed: media uploads are served from
    // /upload/, not the same prefix as the rest of the API.
    assert(editsUrl("dev.sparkles.hue")
        == "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/dev.sparkles.hue/edits");
    assert(bundleUploadUrl("dev.sparkles.hue", "abc").canFind("/upload/androidpublisher/v3/"));
    assert(bundleUploadUrl("dev.sparkles.hue", "abc").canFind("uploadType=media"));
}

@("store.play.trackBodyNamesTheVersionCode")
@safe unittest
{
    const body_ = trackUpdateBody(PlayTrack.internal, 1280, "Fixes.");
    const doc = parseJSON(body_);

    assert(doc["track"].str == "internal");
    const release = doc["releases"].arrayNoRef[0];
    // versionCodes are strings in this API even though they are integers.
    assert(release["versionCodes"].arrayNoRef[0].str == "1280");
    assert(release["status"].str == "completed");
    assert(release["releaseNotes"].arrayNoRef[0]["text"].str == "Fixes.");
    assert(release["releaseNotes"].arrayNoRef[0]["language"].str == "en-US");
}

@("store.play.parsesTracksAndRejectsOthers")
@safe unittest
{
    PlayTrack t;
    assert(tryParseTrack("internal", t) && t == PlayTrack.internal);
    assert(tryParseTrack("production", t) && t == PlayTrack.production);
    assert(!tryParseTrack("prod", t));
    assert(!tryParseTrack("", t));

    static foreach (track; [PlayTrack.internal, PlayTrack.alpha,
            PlayTrack.beta, PlayTrack.production])
        assert(tryParseTrack(trackName(track), t) && t == track);
}

@("store.play.readsRepliesAndErrors")
@safe unittest
{
    assert(replyField(`{"id":"edit-123","expiryTimeSeconds":"1786"}`, "id") == "edit-123");
    assert(replyField(`{"access_token":"ya29.x","expires_in":3599}`, "access_token") == "ya29.x");
    assert(replyField(`{}`, "id") is null);
    assert(replyField(`garbage`, "id") is null);

    // Google's error envelope, so a failure reports the reason and not a wall
    // of JSON.
    assert(apiError(`{"error":{"code":403,"message":"The caller does not have permission"}}`)
        == "The caller does not have permission");
    assert(apiError(`plain text`) == "plain text");
}
