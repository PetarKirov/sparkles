/** Presence-aware JSON input for the finite scalar configuration resolver. */
module sparkles.wired.config.json;

import core.lifetime : move;
import sparkles.wired.config.core;
import sparkles.wired.json.codec : Json, decodeOwnedScalarAt;
import sparkles.wired.json.document : JsonKind, JsonValue;
import sparkles.wired.json.error : JsonError, JsonStage, parseStageError;
import sparkles.wired.json.reader : JsonReadOptions, parseJsonDocument;
import sparkles.wired.policy : WireInvalid, hasWireStrict;
import sparkles.wired.schema : NodeKind;
import sparkles.wired.walk : WireWalk;

/// Unknown keys never create definitions. Strict schema sections always reject.
enum ConfigUnknownMembers : ubyte
{
    reject,
    ignore,
}

struct ConfigDecodeOptions
{
    ConfigUnknownMembers unknownMembers = ConfigUnknownMembers.reject;
}

/// Disjoint decoding and operational capture failures.
struct ConfigDecodeError
{
    bool isJsonError;
    JsonError jsonError;
    ConfigError configError;
}

/// Owns a successful capsule; transfer it with `takeValue`, never copy it.
struct ConfigDecodeResult(T)
{
    private ConfigResult!(OwnedConfigInput!T) captured;
    private bool jsonFailed;
    private JsonError jsonFailure;

    @disable this(this);

    bool hasValue() const @safe pure nothrow @nogc
        => !jsonFailed && captured.hasValue;
    bool hasError() const @safe pure nothrow @nogc
        => jsonFailed || captured.hasError;
    bool hasJsonError() const @safe pure nothrow @nogc => jsonFailed;
    bool hasConfigError() const @safe pure nothrow @nogc
        => !jsonFailed && captured.hasError;
    ref const(JsonError) jsonError() scope return const @safe pure nothrow @nogc
        => jsonFailure;
    ConfigError configError() const return scope @safe pure nothrow @nogc
        => captured.error;
    ConfigDecodeError error() const return scope @safe
        => ConfigDecodeError(jsonFailed, jsonFailure,
            jsonFailed ? ConfigError.init : captured.error);
    OwnedConfigInput!T takeValue() @safe
    {
        assert(hasValue, "configuration decode did not produce a capsule");
        return captured.takeValue();
    }
}

private ConfigDecodeResult!T jsonFailureResult(T)(JsonError error)
{
    ConfigDecodeResult!T result;
    result.jsonFailed = true;
    result.jsonFailure = error;
    return move(result);
}

private ConfigDecodeResult!T captureFailureResult(T)(ConfigError error)
{
    ConfigDecodeResult!T result;
    result.captured = errorResult!(OwnedConfigInput!T)(error);
    return move(result);
}

private template JsonLeafAdmission(V, Root, size_t site, string path)
{
    import std.typecons : Nullable;

    alias walk = WireWalk!(Json, Root);
    enum node = walk.node!site;
    static assert(node.kind != NodeKind.converted,
        "wired.config: WireConvert is unsupported at " ~ Root.stringof ~ "." ~ path);
    static assert(node.policy.field.onInvalid != WireInvalid.useDefault,
        "wired.config: WireOptional useDefault is unsupported at "
            ~ Root.stringof ~ "." ~ path);
    static if (is(V == Nullable!Contained, Contained))
        enum bool JsonLeafAdmission = JsonLeafAdmission!(Contained, Root,
            walk.child!(site, 0), path);
    else
        enum bool JsonLeafAdmission = true;
}

private template JsonSchemaAdmission(S, Root = S, size_t site = 0, string path = "")
{
    alias walk = WireWalk!(Json, Root);
    static assert(walk.node!site.kind == NodeKind.aggregate,
        "wired.config: original JSON section must be an aggregate at "
            ~ Root.stringof ~ "." ~ path ~ " (WireConvert is unsupported)");
    static assert(walk.node!site.edgeCount == ConfigFieldNames!S.length);
    static foreach (ordinal, name; ConfigFieldNames!S)
    {
        static assert(() {
            alias V = ConfigFieldType!(S, name);
            enum child = walk.child!(site, ordinal);
            enum childPath = path.length ? path ~ "." ~ name : name;
            static assert(walk.node!child.policy.field.onInvalid != WireInvalid.useDefault,
                "wired.config: WireOptional useDefault is unsupported at "
                    ~ Root.stringof ~ "." ~ childPath);
            static if (ConfigIsSection!(S, name))
                static assert(JsonSchemaAdmission!(V, Root, child, childPath));
            else
                static assert(JsonLeafAdmission!(V, Root, child, childPath));
            return true;
        }());
    }
    enum bool JsonSchemaAdmission = true;
}

/** Decode text with explicit native parser options and detached capsule limits. */
ConfigDecodeResult!T decodeConfigInput(T, JsonReadOptions parserOptions = JsonReadOptions.init)(
    scope const(char)[] text,
    scope auto ref const DefinitionMetadata!T metadata = DefinitionMetadata!T.init,
    ConfigLimits limits = ConfigLimits.init,
    ConfigDecodeOptions options = ConfigDecodeOptions.init)
{
    static assert(JsonSchemaAdmission!T);
    auto parsed = parseJsonDocument!parserOptions(text);
    if (parsed.hasError)
        return jsonFailureResult!T(parseStageError(parsed.error, text));
    JsonFailureSite failedSite;
    auto result = decodeRoot!T(parsed.document.root, metadata, limits, options, failedSite);
    if (result.hasJsonError)
    {
        size_t cursor, offset;
        if (locateSite!T(parsed.document.root, failedSite, text, cursor, offset))
            result.jsonFailure.setLocation(text, offset);
    }
    return move(result);
}

/** Decode a borrowed document view; the returned capsule does not borrow it. */
ConfigDecodeResult!T decodeConfigInput(T)(scope JsonValue root,
    scope auto ref const DefinitionMetadata!T metadata = DefinitionMetadata!T.init,
    ConfigLimits limits = ConfigLimits.init,
    ConfigDecodeOptions options = ConfigDecodeOptions.init)
{
    static assert(JsonSchemaAdmission!T);
    JsonFailureSite failedSite;
    return decodeRoot!T(root, metadata, limits, options, failedSite);
}

// Exact occurrence identity without retaining a borrowed arena view.
// The section index comes from the original schema; member ordinals are local
// document occurrences, so escaped duplicates remain individually locatable.
private struct JsonFailureSite
{
    size_t section;
    size_t occurrence = size_t.max; // the section itself, including the root
}

private ConfigDecodeResult!T decodeRoot(T)(scope JsonValue root,
    scope ref const DefinitionMetadata!T metadata, ConfigLimits limits,
    ConfigDecodeOptions options, ref JsonFailureSite failedSite)
{
    // Force core schema admission, including excluded shapes and merge policies.
    enum optionsCount = ConfigLeafCount!T;
    JsonError failure, unknownFailure;
    JsonFailureSite unknownSite;
    bool unknown;
    if (!enumerateOccurrences!(T, T, 0)(root, options, failure, failedSite,
            unknown, unknownFailure, unknownSite))
        return jsonFailureResult!T(failure);
    if (unknown)
    {
        failedSite = unknownSite;
        return jsonFailureResult!T(unknownFailure);
    }
    // Validate the original typed sites and exact budgets before allocating.
    // String counting emits no borrowed header and performs no string copy.
    ConfigInput!T staged;
    StringCaptureBudget counted;
    ConfigError captureFailure;
    if (!assembleSection!(T, T, 0, StringCaptureBudget, countString)(
            root, staged, counted, failure, captureFailure, failedSite))
    {
        if (captureFailure.kind != ConfigErrorKind.none)
            return captureFailureResult!T(captureFailure);
        return jsonFailureResult!T(failure);
    }
    const preflight = preflightInput!T(staged, metadata, limits, counted.bytes);
    if (preflight.kind != ConfigErrorKind.none)
        return captureFailureResult!T(preflight);
    auto begun = beginOwnedInput!T(metadata, limits);
    if (begun.hasError)
        return captureFailureResult!T(begun.error);
    auto capsule = begun.takeValue();
    assemblyInput(capsule) = staged;
    if (!assembleSection!(T, T, 0, OwnedConfigInput!T, captureString, true)(
            root, assemblyInput(capsule), capsule,
            failure, captureFailure, failedSite))
    {
        if (captureFailure.kind != ConfigErrorKind.none)
            return captureFailureResult!T(captureFailure);
        return jsonFailureResult!T(failure);
    }
    const completed = finishOwnedInput(capsule);
    if (completed.kind != ConfigErrorKind.none)
        return captureFailureResult!T(completed);
    ConfigDecodeResult!T result;
    result.captured = successResult(capsule);
    return move(result);
}

private JsonError sectionError(S)(scope JsonValue value, string reason) @safe
{
    JsonError failure;
    failure.stage = JsonStage.decode;
    failure.targetType = S.stringof;
    failure.actualKind = value.kind;
    failure.reason = reason;
    return failure;
}

// Occurrences are enumerated before any slot is assigned. A duplicate known
// member wins over unknown-member rejection, and both precede value capture.
private bool enumerateOccurrences(S, Root, size_t site)(scope JsonValue value,
    ConfigDecodeOptions options, ref JsonError failure, ref JsonFailureSite failedSite,
    ref bool unknown, ref JsonError unknownFailure, ref JsonFailureSite unknownSite)
{
    alias walk = WireWalk!(Json, Root);
    alias policies = walk.childPolicies!site;
    if (value.kind != JsonKind.object)
    {
        failure = sectionError!S(value, "expected a JSON object");
        failedSite = JsonFailureSite(site);
        return false;
    }
    bool[ConfigFieldNames!S.length] seen;
    size_t occurrence;
    foreach (member; value.byKeyValue)
    {
        bool known;
        static foreach (ordinal, name; ConfigFieldNames!S)
        {{
            if (member.key == policies[ordinal].key)
            {
                known = true;
                if (seen[ordinal])
                {
                    failure = sectionError!S(member.value,
                        "duplicate canonical configuration member");
                    failure.prependKey(member.key);
                    failedSite = JsonFailureSite(site, occurrence);
                    return false;
                }
                seen[ordinal] = true;
            }
        }}
        if (!known && !unknown && (options.unknownMembers == ConfigUnknownMembers.reject
                || hasWireStrict!(Json, S)))
        {
            unknown = true;
            unknownFailure = sectionError!S(member.value, "unknown configuration member");
            unknownFailure.prependKey(member.key);
            unknownSite = JsonFailureSite(site, occurrence);
        }
        occurrence++;
    }
    foreach (member; value.byKeyValue)
    {
        static foreach (ordinal, name; ConfigFieldNames!S)
        {{
            static if (ConfigIsSection!(S, name))
            {
                if (member.key == policies[ordinal].key)
                {
                    const hadUnknown = unknown;
                    if (!enumerateOccurrences!(ConfigFieldType!(S, name), Root,
                            walk.child!(site, ordinal))(member.value, options, failure,
                            failedSite, unknown, unknownFailure, unknownSite))
                    {
                        failure.prependKey(member.key);
                        return false;
                    }
                    if (!hadUnknown && unknown)
                        unknownFailure.prependKey(member.key);
                }
            }
        }}
    }
    return true;
}

private struct StringCaptureBudget
{
    ulong bytes;
}

private ConfigError countString(ref StringCaptureBudget budget,
    scope const(char)[] bytes, out string captured) @safe pure nothrow @nogc
{
    captured = null;
    if (bytes.length > ulong.max - budget.bytes)
        return ConfigError(ConfigErrorKind.arithmeticOverflow);
    budget.bytes += bytes.length;
    return ConfigError.init;
}

private bool assembleSection(S, Root, size_t site, Owner, alias capture,
    bool stringsOnly = false)(
    scope JsonValue value, ref ConfigInput!S input, ref Owner capsule, ref JsonError failure,
    ref ConfigError captureFailure, ref JsonFailureSite failedSite)
{
    import std.typecons : Nullable;

    alias walk = WireWalk!(Json, Root);
    alias policies = walk.childPolicies!site;
    size_t occurrence;
    foreach (member; value.byKeyValue)
    {
        static foreach (ordinal, name; ConfigFieldNames!S)
        {{
            if (member.key == policies[ordinal].key)
            {
                alias V = ConfigFieldType!(S, name);
                enum child = walk.child!(site, ordinal);
                static if (ConfigIsSection!(S, name))
                {
                    if (!assembleSection!(V, Root, child, Owner, capture, stringsOnly)(member.value,
                            __traits(getMember, input, name), capsule, failure,
                            captureFailure, failedSite))
                    {
                        failure.prependKey(member.key);
                        return false;
                    }
                }
                else static if (!stringsOnly || is(V == string) || is(V == Nullable!string))
                {
                    if (!decodeOwnedScalarAt!(V, Root, child, Owner,
                            ConfigError, capture)(member.value,
                            __traits(getMember, input, name).value,
                            failure, capsule, captureFailure))
                    {
                        failedSite = JsonFailureSite(site, occurrence);
                        failure.prependKey(member.key);
                        return false;
                    }
                    static if (!stringsOnly)
                        __traits(getMember, input, name).supplied = true;
                }
            }
        }}
        occurrence++;
    }
    return true;
}

// Only known schema sections can contain a deeper error site. Their recursion
// is bounded by the admitted schema, not the input. Everything else is skipped
// lexically with constant storage, including arbitrarily deep ignored values.
// The native parser has already validated the text; this does not reparse it.
private bool locateSite(S, Root = S, size_t site = 0)(
    scope JsonValue current, JsonFailureSite target,
    scope const(char)[] text, ref size_t cursor, out size_t offset)
{
    alias walk = WireWalk!(Json, Root);
    alias policies = walk.childPolicies!site;
    skipSpace(text, cursor);
    offset = cursor;
    if (target.section == site && target.occurrence == size_t.max)
        return true;
    if (current.kind != JsonKind.object)
    {
        skipValue(text, cursor);
        return false;
    }
    cursor++; // opening brace
    size_t occurrence;
    foreach (member; current.byKeyValue)
    {
        skipSpace(text, cursor);
        skipString(text, cursor);
        skipSpace(text, cursor);
        cursor++; // colon
        skipSpace(text, cursor);
        offset = cursor;
        if (target.section == site && target.occurrence == occurrence)
            return true;
        bool searchedSection;
        static foreach (ordinal, name; ConfigFieldNames!S)
        {{
            static if (ConfigIsSection!(S, name))
            {
                if (member.key == policies[ordinal].key)
                {
                    searchedSection = true;
                    if (locateSite!(ConfigFieldType!(S, name), Root,
                            walk.child!(site, ordinal))(
                            member.value, target, text, cursor, offset))
                        return true;
                }
            }
        }}
        if (!searchedSection)
            skipValue(text, cursor);
        skipSpace(text, cursor);
        if (cursor < text.length && text[cursor] == ',')
            cursor++;
        occurrence++;
    }
    skipSpace(text, cursor);
    cursor++; // closing brace
    return false;
}

private void skipValue(scope const(char)[] text, ref size_t cursor)
    @safe pure nothrow @nogc
{
    skipSpace(text, cursor);
    if (cursor == text.length)
        return;
    if (text[cursor] == '"')
    {
        skipString(text, cursor);
        return;
    }
    if (text[cursor] == '{' || text[cursor] == '[')
    {
        size_t depth;
        while (cursor < text.length)
        {
            if (text[cursor] == '"')
            {
                skipString(text, cursor);
                continue;
            }
            const c = text[cursor++];
            if (c == '{' || c == '[')
                depth++;
            else if (c == '}' || c == ']')
            {
                depth--;
                if (depth == 0)
                    return;
            }
        }
        return;
    }
    while (cursor < text.length && text[cursor] != ',' && text[cursor] != '}'
            && text[cursor] != ']' && text[cursor] != ' '
            && text[cursor] != '\t' && text[cursor] != '\r' && text[cursor] != '\n')
        cursor++;
}

private void skipSpace(scope const(char)[] text, ref size_t cursor)
    @safe pure nothrow @nogc
{
    while (cursor < text.length && (text[cursor] == ' ' || text[cursor] == '\t'
            || text[cursor] == '\r' || text[cursor] == '\n'))
        cursor++;
}

private void skipString(scope const(char)[] text, ref size_t cursor)
    @safe pure nothrow @nogc
{
    cursor++; // opening quote
    while (cursor < text.length)
    {
        const c = text[cursor++];
        if (c == '"')
            return;
        if (c == '\\')
            cursor++; // escaped byte; remaining hex digits are ordinary bytes
    }
}

version (unittest)
{
    private ConfigSnapshot!T snapshotFor(T)(ref OwnedConfigInput!T capsule)
    {
        auto created = ConfigBuilder!T.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        auto source = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "");
        assert(source.hasValue);
        assert(builder.submitOwned(source.value, capsule).kind == ConfigErrorKind.none);
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        return resolved.takeValue();
    }

    private void expectDefinitions(V, T)(ref ConfigSnapshot!T snapshot,
        string path, size_t count)
    {
        bool visited;
        const error = snapshot.visitOption!((scope ref const view) {
            static if (is(typeof(view) == const(OptionView!V)))
            {
                visited = true;
                assert(view.path == path);
                assert(view.definitions.length == count);
            }
            else
                assert(false, "unexpected value type for requested option");
        })(path);
        assert(error.kind == ConfigErrorKind.none && visited);
    }
}

@("wired.config.json.presenceDefaultEqualAndNull")
@safe unittest
{
    import std.typecons : Nullable;
    import sparkles.wired.policy : WireOptional;

    struct Settings
    {
        bool enabled;
        @WireOptional() int width;
        string title;
        Nullable!int optional;
    }
    auto absent = decodeConfigInput!Settings(`{}`);
    assert(absent.hasValue);
    auto empty = absent.takeValue();
    auto emptySnapshot = snapshotFor(empty);
    expectDefinitions!bool(emptySnapshot, "enabled", 1);
    expectDefinitions!int(emptySnapshot, "width", 1);
    expectDefinitions!string(emptySnapshot, "title", 1);
    expectDefinitions!(Nullable!int)(emptySnapshot, "optional", 1);

    auto present = decodeConfigInput!Settings(
        `{"enabled":false,"width":0,"title":"","optional":null}`);
    assert(present.hasValue);
    auto supplied = present.takeValue();
    auto suppliedSnapshot = snapshotFor(supplied);
    expectDefinitions!bool(suppliedSnapshot, "enabled", 2);
    expectDefinitions!int(suppliedSnapshot, "width", 2);
    expectDefinitions!string(suppliedSnapshot, "title", 2);
    expectDefinitions!(Nullable!int)(suppliedSnapshot, "optional", 2);
    auto suppliedCopy = suppliedSnapshot.copyConfig();
    assert(suppliedCopy.hasValue && !suppliedCopy.value.enabled
        && suppliedCopy.value.width == 0 && suppliedCopy.value.title == ""
        && suppliedCopy.value.title.ptr !is null && suppliedCopy.value.optional.isNull);
    auto nonnull = decodeConfigInput!Settings(`{"optional":0}`);
    assert(nonnull.hasValue);
    auto value = nonnull.takeValue();
    auto valueSnapshot = snapshotFor(value);
    expectDefinitions!(Nullable!int)(valueSnapshot, "optional", 2);
    auto valueCopy = valueSnapshot.copyConfig();
    assert(valueCopy.hasValue && !valueCopy.value.optional.isNull
        && valueCopy.value.optional.get == 0);
    auto invalid = decodeConfigInput!Settings(`{"title":null}`);
    assert(invalid.hasJsonError && !invalid.hasConfigError);
    assert(invalid.jsonError.path[] == ".title");
}

@("wired.config.json.originalNestedSitePolicies")
@safe unittest
{
    import std.typecons : Nullable;
    import sparkles.wired.policy : WireCase, WireName, WireRepr, Repr, CaseStyle;
    import sparkles.wired.overlay : WireSection;

    enum Mode : int
    {
        fastPath = 1,
        slowPath = 2,
        @WireName("accelerated") turboPath = 3,
    }
    @WireSection
    struct Viewer
    {
        @WireName("mode-choice")
        @WireCase(CaseStyle.snakeCase)
        Nullable!Mode selectedMode;
        @WireRepr(Repr.value) Mode numericMode = Mode.fastPath;
        int tabWidth;
    }
    struct Settings
    {
        @WireName("panel")
        @WireCase(CaseStyle.snakeCase)
        @(ConfigMerge!Submodule()) Viewer viewer;
    }
    auto decoded = decodeConfigInput!Settings(
        `{"panel":{"mode-choice":"slow_path","numeric_mode":2,"tab_width":0}}`);
    assert(decoded.hasValue);
    auto capsule = decoded.takeValue();
    auto snapshot = snapshotFor(capsule);
    expectDefinitions!(Nullable!Mode)(snapshot, "viewer.selectedMode", 2);
    expectDefinitions!Mode(snapshot, "viewer.numericMode", 2);
    expectDefinitions!int(snapshot, "viewer.tabWidth", 2);
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.viewer.selectedMode.get == Mode.slowPath
        && copied.value.viewer.numericMode == Mode.slowPath
        && copied.value.viewer.tabWidth == 0);
    auto renamed = decodeConfigInput!Settings(`{"panel":{"mode-choice":"accelerated"}}`);
    assert(renamed.hasValue);
    auto renamedCapsule = renamed.takeValue();
    auto renamedSnapshot = snapshotFor(renamedCapsule);
    auto renamedCopy = renamedSnapshot.copyConfig();
    assert(renamedCopy.hasValue
        && renamedCopy.value.viewer.selectedMode.get == Mode.turboPath);
    auto originalSpelling = decodeConfigInput!Settings(
        `{"viewer":{"tabWidth":8}}`);
    assert(originalSpelling.hasJsonError);
    auto bad = decodeConfigInput!Settings(
        "{\n  \"panel\": {\"mode-choice\":\"fast_path\", \"numeric_mode\": \"slowPath\"}\n}");
    assert(bad.hasJsonError && bad.jsonError.path[] == ".panel.numeric_mode");
    assert(bad.jsonError.targetType == Mode.stringof);
    assert(bad.jsonError.line == 2 && bad.jsonError.column > 1);
    assert(bad.jsonError.offset == 57);
}

@("wired.config.json.duplicateUnknownAndStrictPrecedence")
@safe unittest
{
    import sparkles.wired.policy : WireName, WireStrict;

    struct Settings { @WireName("w") int width; }
    DefinitionMetadata!Settings metadata;
    const ignoring = ConfigDecodeOptions(ConfigUnknownMembers.ignore);
    auto unknown = decodeConfigInput!Settings(`{"extra":1}`);
    assert(unknown.hasJsonError && unknown.jsonError.path[] == ".extra");
    auto ignored = decodeConfigInput!Settings(`{"extra":1}`, metadata,
        ConfigLimits.init, ignoring);
    assert(ignored.hasValue);
    auto capsule = ignored.takeValue();
    auto ignoredSnapshot = snapshotFor(capsule);
    expectDefinitions!int(ignoredSnapshot, "width", 1);
    auto duplicate = decodeConfigInput!Settings(`{"extra":1,"w":0,"\u0077":2}`);
    assert(duplicate.hasJsonError && duplicate.jsonError.path[] == ".w");
    assert(duplicate.jsonError.offset == 26);
    auto duplicateIgnored = decodeConfigInput!Settings(`{"w":0,"w":2}`,
        metadata, ConfigLimits.init, ignoring);
    assert(duplicateIgnored.hasJsonError);
    @WireStrict struct Strict { int width; }
    DefinitionMetadata!Strict strictMetadata;
    auto strict = decodeConfigInput!Strict(`{"extra":1}`, strictMetadata,
        ConfigLimits.init, ignoring);
    assert(strict.hasJsonError && strict.jsonError.path[] == ".extra");
}

@("wired.config.json.parsedDocumentAndTextLifetimes")
@safe unittest
{
    import std.typecons : Nullable;

    struct Settings { string title; Nullable!string subtitle; }
    OwnedConfigInput!Settings capsule;
    {
        auto document = parseJsonDocument(`{"title":"owned text","subtitle":"secondary"}`);
        assert(document.hasValue);
        auto decoded = decodeConfigInput!Settings(document.document.root);
        assert(decoded.hasValue);
        capsule = decoded.takeValue();
    }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto source = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "");
    assert(source.hasValue);
    assert(builder.submitOwned(source.value, capsule).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.title == "owned text"
        && copied.value.subtitle.get == "secondary");
}

@("wired.config.json.unsupportedPoliciesAreCompileErrors")
@safe unittest
{
    import sparkles.wired.policy : WireConvert, WireOptional, WireInvalid;

    struct Defaulting
    {
        @WireOptional(onInvalid: WireInvalid.useDefault) int width;
    }
    static assert(!__traits(compiles, decodeConfigInput!Defaulting(`{"width":1}`)));
    static int toWire(int value) @safe pure nothrow => value;
    static int fromWire(int value) @safe pure nothrow => value;
    struct Converted
    {
        @WireConvert!(toWire, fromWire) int width;
    }
    static assert(!__traits(compiles, decodeConfigInput!Converted(`{"width":1}`)));
    struct Collection { int[] widths; }
    static assert(!__traits(compiles, decodeConfigInput!Collection(`{"widths":[1]}`)));
}

@("wired.config.json.captureBudgetBoundaries")
@safe unittest
{
    struct Settings { int width = 4; }
    DefinitionMetadata!Settings metadata;
    ConfigLimits limits;
    limits.maxPayloadBytes = 8;
    auto tooSmall = decodeConfigInput!Settings(`{"width":8}`,
        metadata, limits);
    assert(tooSmall.hasConfigError && !tooSmall.hasJsonError
        && tooSmall.configError.kind == ConfigErrorKind.limitExceeded);
    limits.maxPayloadBytes = 9;
    auto exact = decodeConfigInput!Settings(`{"width":8}`,
        metadata, limits);
    assert(exact.hasValue);
    auto capsule = exact.takeValue();
    assert(capsule.usage.payloadBytes == 9 && capsule.usage.definitions == 1);
    limits.maxPayloadBytes = 5;
    auto absent = decodeConfigInput!Settings(`{}`,
        metadata, limits);
    assert(absent.hasValue);
    limits.maxPayloadBytes = 4;
    auto missingSchemaBudget = decodeConfigInput!Settings(`{}`,
        metadata, limits);
    assert(missingSchemaBudget.hasConfigError
        && missingSchemaBudget.configError.kind == ConfigErrorKind.limitExceeded);
    // Document occurrences are validated before any allocation/budget failure.
    auto duplicate = decodeConfigInput!Settings(`{"width":1,"width":2}`,
        metadata, limits);
    assert(duplicate.hasJsonError && duplicate.jsonError.path[] == ".width");
    auto unknown = decodeConfigInput!Settings(`{"extra":1}`,
        metadata, limits);
    assert(unknown.hasJsonError && unknown.jsonError.path[] == ".extra");
}

@("wired.config.json.nativeParserOptionsAndParseLocation")
@safe unittest
{
    struct Settings { int width; }
    auto malformed = decodeConfigInput!Settings("{\n \"width\": }\n");
    assert(malformed.hasJsonError && malformed.jsonError.stage == JsonStage.parse);
    assert(malformed.jsonError.line == 2 && malformed.jsonError.column > 1);
    auto raw = decodeConfigInput!(Settings, JsonReadOptions(rawNumbers: true))(
        `{"width":8}`);
    assert(raw.hasJsonError && raw.jsonError.actualKind == JsonKind.rawNumber);
}

@("wired.config.json.metadataCaptureAndAbsentOverride")
@safe unittest
{
    struct Settings { int width = 4; }
    DefinitionMetadata!Settings metadata;
    metadata.width.priority = 500u;
    auto absent = decodeConfigInput!Settings(`{}`, metadata);
    assert(absent.hasConfigError
        && absent.configError.kind == ConfigErrorKind.invalidMetadata);
    metadata.width.priority.nullify();
    metadata.width.localId = LocalId("value");
    ConfigLimits limits;
    limits.maxPayloadBytes = 13;
    auto tooSmall = decodeConfigInput!Settings(`{"width":8}`, metadata, limits);
    assert(tooSmall.hasConfigError
        && tooSmall.configError.kind == ConfigErrorKind.limitExceeded);
    limits.maxPayloadBytes = 14;
    auto exact = decodeConfigInput!Settings(`{"width":8}`, metadata, limits);
    assert(exact.hasValue);
    auto capsule = exact.takeValue();
    assert(capsule.usage.payloadBytes == 14);
    metadata.width.localId = LocalId("different");
    auto snapshot = snapshotFor(capsule);
    bool observed;
    auto error = snapshot.visitDefinitions!((scope ref const DefinitionView!int view) {
        if (view.sourceId == SourceId("u").bytes)
        {
            observed = true;
            assert(view.localId == LocalId("value").bytes);
        }
    })("width");
    assert(error.kind == ConfigErrorKind.none && observed);
}

@("wired.config.json.sectionPriorityAppliesOnlyToPresentLeaves")
@safe unittest
{
    struct Viewer { int width = 4; bool enabled = true; }
    struct Settings { @(ConfigMerge!Submodule()) Viewer viewer; }
    DefinitionMetadata!Settings metadata;
    metadata.viewer.priority = 500u;
    auto decoded = decodeConfigInput!Settings(`{"viewer":{"width":8}}`, metadata);
    assert(decoded.hasValue);
    auto capsule = decoded.takeValue();
    auto snapshot = snapshotFor(capsule);
    expectDefinitions!int(snapshot, "viewer.width", 2);
    expectDefinitions!bool(snapshot, "viewer.enabled", 1);
    bool observed;
    auto error = snapshot.visitOption!((scope ref const view) {
        static if (is(typeof(view) == const(OptionView!int)))
        {
            observed = true;
            assert(view.path == "viewer.width");
            assert(view.selectedPriority == 500 && view.effective.hasValue
                && view.effective.get == 8);
        }
        else
            assert(false, "unexpected value type for viewer.width");
    })("viewer.width");
    assert(error.kind == ConfigErrorKind.none && observed);
    metadata.viewer.members.enabled.priority = 250u;
    auto invalid = decodeConfigInput!Settings(`{"viewer":{"width":8}}`, metadata);
    assert(invalid.hasConfigError
        && invalid.configError.kind == ConfigErrorKind.invalidMetadata);
}

@("wired.config.json.emptySchemasAndOtherFormatPolicies")
@safe unittest
{
    import sparkles.wired.policy : WireOptional, WireInvalid;

    struct Empty {}
    auto empty = decodeConfigInput!Empty(`{}`);
    assert(empty.hasValue);
    auto capsule = empty.takeValue();
    assert(capsule.usage.options == 0 && capsule.usage.definitions == 0);
    auto unknown = decodeConfigInput!Empty(`{"extra":0}`);
    assert(unknown.hasJsonError && unknown.jsonError.path[] == ".extra");

    struct OtherFormat {}
    struct Settings
    {
        @WireOptional!OtherFormat(onInvalid: WireInvalid.useDefault) int width = 4;
    }
    auto decoded = decodeConfigInput!Settings(`{"width":8}`);
    assert(decoded.hasValue);
    auto supplied = decoded.takeValue();
    auto snapshot = snapshotFor(supplied);
    auto copy = snapshot.copyConfig();
    assert(copy.hasValue && copy.value.width == 8);
    auto invalid = decodeConfigInput!Settings(`{"width":"bad"}`);
    assert(invalid.hasJsonError && invalid.jsonError.path[] == ".width");
}

@("wired.config.json.locatingAfterDeepIgnoredValue")
@safe unittest
{
    struct Settings { int width; }
    enum uint nesting = 65_536;
    enum prefix = `{"extra":`;
    enum middle = `"text [ { \"quoted\" } ]"`;
    enum suffix = ",\n \"width\": \"bad\"}";
    auto text = new char[](prefix.length + 2 * nesting + middle.length + suffix.length);
    size_t cursor;
    text[cursor .. cursor + prefix.length] = prefix;
    cursor += prefix.length;
    text[cursor .. cursor + nesting] = '[';
    cursor += nesting;
    text[cursor .. cursor + middle.length] = middle;
    cursor += middle.length;
    text[cursor .. cursor + nesting] = ']';
    cursor += nesting;
    text[cursor .. $] = suffix;
    DefinitionMetadata!Settings metadata;
    auto decoded = decodeConfigInput!(Settings, JsonReadOptions(maxDepth: nesting + 4))(
        text, metadata, ConfigLimits.init, ConfigDecodeOptions(ConfigUnknownMembers.ignore));
    assert(decoded.hasJsonError && decoded.jsonError.stage == JsonStage.decode);
    assert(decoded.jsonError.path[] == ".width" && decoded.jsonError.targetType == int.stringof
        && decoded.jsonError.actualKind == JsonKind.string_);
    assert(decoded.jsonError.offset == cursor + suffix.length - `"bad"}`.length);
    assert(decoded.jsonError.line == 2 && decoded.jsonError.column == 11);
}

@("wired.config.json.locatingRootAndSectionTypeErrors")
@safe unittest
{
    import sparkles.wired.overlay : WireSection;

    @WireSection struct Viewer { int width; }
    struct Settings { Viewer viewer; }
    auto root = decodeConfigInput!Settings("\n []");
    assert(root.hasJsonError && root.jsonError.path[].length == 0
        && root.jsonError.actualKind == JsonKind.array);
    assert(root.jsonError.offset == 2 && root.jsonError.line == 2
        && root.jsonError.column == 2);
    auto section = decodeConfigInput!Settings("{\n \"viewer\": []}");
    assert(section.hasJsonError && section.jsonError.path[] == ".viewer"
        && section.jsonError.actualKind == JsonKind.array);
    assert(section.jsonError.offset == 13 && section.jsonError.line == 2
        && section.jsonError.column == 12);
}
