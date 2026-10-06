/** Consumer-visible collection composition acceptance scenarios. */
module sparkles.wired.config.collections_acceptance;

import sparkles.wired.config.core;
import sparkles.wired.config : ConfigBranchMetadata;
import sparkles.wired.config.payload : ConfigPresence;
import sparkles.wired.config.json : decodeConfigInput, ConfigDecodeOptions,
    ConfigUnknownMembers;
import std.typecons : Nullable;

private enum permutations = [
    [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
];

private ConfigSnapshot!T decodedSnapshot(T)(string text)
{
    auto decoded = decodeConfigInput!T(text);
    assert(decoded.hasValue);
    auto input = decoded.takeValue();
    auto created = ConfigBuilder!T.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "");
    assert(registered.hasValue);
    assert(builder.submitOwned(registered.value, input).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    return resolved.takeValue();
}

/// Arrival order, transfer grouping and root priority cannot replace list order.
@("wired.config.collections.listDefinitionSetPermutations")
@safe unittest
{
    struct Settings { @(ConfigMerge!(ListOf!Atomic)()) string[] paths; }
    immutable string[3] ids = ["b", "a", "aa"];
    immutable int[3] orders = [10, -10, 0];
    foreach (arrival; permutations)
    foreach (owned; [false, true])
    foreach (strong; [false, true])
    {
        auto created = ConfigBuilder!Settings.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        SourceRef[3] sources;
        foreach (i; arrival)
        {
            auto registered = builder.registerSource(SourceId(ids[i]),
                ConfigSourceKind.custom, "", strong && i == 2 ? 500 : 1000, orders[i]);
            assert(registered.hasValue);
            sources[i] = registered.value;
        }
        foreach (i; arrival)
        {
            Settings value;
            value.paths = i == 0 ? ["b", "b"] : i == 1 ? ["a"] : ["aa"];
            auto input = fullConfigInput!Settings(value);
            if (owned)
            {
                auto captured = captureInput!Settings(input);
                assert(captured.hasValue);
                auto capsule = captured.takeValue();
                assert(builder.submitOwned(sources[i], capsule).kind == ConfigErrorKind.none);
                assert(capsule.consumed);
            }
            else assert(builder.submitBorrowed(sources[i], input).kind == ConfigErrorKind.none);
        }
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue);
        const expected = strong ? ["aa"] : ["a", "aa", "b", "b"];
        assert(copied.value.paths == expected);
    }
}

/// Equal-order ties use unsigned source/local identities, not locale or arrival.
@("wired.config.collections.identityOrderAndLines")
@safe unittest
{
    struct Settings
    {
        @(ConfigMerge!(ListOf!Atomic)()) string[] paths;
        @(ConfigMerge!Lines()) string lines;
    }
    immutable string[3] ids = ["a", "aa", "b"];
    foreach (arrival; permutations)
    {
        auto created = ConfigBuilder!Settings.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        foreach (i; arrival)
        {
            auto registered = builder.registerSource(SourceId(ids[i]),
                ConfigSourceKind.custom, "", 1000);
            assert(registered.hasValue);
            Settings value;
            value.paths = [ids[i]];
            value.lines = i == 0 ? "a" : i == 1 ? "" : "b\n";
            auto input = fullConfigInput!Settings(value);
            assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.none);
        }
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.paths == ["a", "aa", "b"]);
        assert(copied.value.lines == "a\n\nb\n");
    }
    immutable(ubyte)[][3] bytes = [[cast(ubyte) 0x7f], [cast(ubyte) 0x80], [cast(ubyte) 0xff]];
    foreach (local; [false, true])
    {
        auto created = ConfigBuilder!Settings.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        SourceRef common;
        if (local)
        {
            auto registered = builder.registerSource(SourceId("same"), ConfigSourceKind.custom, "");
            assert(registered.hasValue);
            common = registered.value;
        }
        foreach (i; [2, 0, 1])
        {
            auto source = common;
            if (!local)
            {
                auto registered = builder.registerSource(SourceId(bytes[i]), ConfigSourceKind.custom, "");
                assert(registered.hasValue);
                source = registered.value;
            }
            Settings value;
            value.paths = i == 0 ? ["7f"] : i == 1 ? ["80"] : ["ff"];
            value.lines = i == 0 ? "7f" : i == 1 ? "80" : "ff";
            auto input = fullConfigInput!Settings(value);
            DefinitionMetadata!Settings metadata;
            if (local)
            {
                metadata.paths.localId = LocalId(bytes[i]);
                metadata.lines.localId = LocalId(bytes[i]);
            }
            assert(builder.submitBorrowed(source, input, metadata).kind == ConfigErrorKind.none);
        }
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.paths == ["7f", "80", "ff"]);
        assert(copied.value.lines == "7f\n80\nff");
    }
}

/// Common map keys recurse through their policy after whole-map selection.
@("wired.config.collections.mapParentSelectionAndListValues")
@safe unittest
{
    struct Settings { @(ConfigMerge!(AttrsOf!(ListOf!Atomic))()) int[][string] tools; }
    foreach (projectStrong; [false, true])
    foreach (reverse; [false, true])
    {
        auto created = ConfigBuilder!Settings.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "", 1000, 20);
        auto p = builder.registerSource(SourceId("p"), ConfigSourceKind.projectFile, "", projectStrong ? 500 : 1000, 10);
        assert(u.hasValue && p.hasValue);
        Settings user, project;
        user.tools = ["a": [1, 1], "b": [2]];
        project.tools = ["a": [3]];
        auto ui = fullConfigInput!Settings(user);
        auto pi = fullConfigInput!Settings(project);
        if (reverse)
        {
            assert(builder.submitBorrowed(p.value, pi).kind == ConfigErrorKind.none);
            assert(builder.submitBorrowed(u.value, ui).kind == ConfigErrorKind.none);
        }
        else
        {
            assert(builder.submitBorrowed(u.value, ui).kind == ConfigErrorKind.none);
            assert(builder.submitBorrowed(p.value, pi).kind == ConfigErrorKind.none);
        }
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue);
        auto result = copied.takeValue();
        assert(result.tools["a"] == (projectStrong ? [3] : [3, 1, 1]));
        assert(("b" in result.tools) is null ? projectStrong : !projectStrong);
        if (!projectStrong) assert(result.tools["b"] == [2]);
    }
}

/// Source and normalized payloads, active paths and record relationships all count.
@("wired.config.collections.exactListAccountingAndRollback")
@safe unittest
{
    struct Settings { @(ConfigMerge!(ListOf!Atomic)()) string[] paths; }
    foreach (boundary; [0, 1, 2, 3])
    foreach (headroom; [0, 1])
    {
        ConfigLimits limits;
        auto created = ConfigBuilder!Settings.create(limits);
        assert(created.hasValue);
        auto builder = created.takeValue();
        assert(builder.usage.payloadBytes == 25);
        auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "file", 1000, 0);
        assert(u.hasValue && builder.usage.payloadBytes == 30);
        Settings user;
        user.paths = ["a", "bb"];
        auto ui = fullConfigInput!Settings(user);
        auto detached = captureInput!Settings(ui);
        assert(detached.hasValue);
        auto detachedInput = detached.takeValue();
        assert(detachedInput.usage.payloadBytes == 9);
        assert(builder.submitBorrowed(u.value, ui).kind == ConfigErrorKind.none);
        assert(builder.usage.payloadBytes == 39);
        auto p = builder.registerSource(SourceId("p"), ConfigSourceKind.projectFile, "repo", 1000, 10);
        assert(p.hasValue && builder.usage.payloadBytes == 44);
        Settings project;
        project.paths = ["ccc"];
        auto pi = fullConfigInput!Settings(project);
        assert(builder.submitBorrowed(p.value, pi).kind == ConfigErrorKind.none);
        assert(builder.usage.payloadBytes == 48 && builder.usage.valueNodes == 6);
        if (boundary == 0) limits.maxPayloadBytes = 78;
        else if (boundary == 1) limits.maxValueNodes = 9;
        else if (boundary == 2) limits.maxResolvedRecords = 3;
        else limits.maxContributions = 4;
        assert(builder.setLimits(limits).kind == ConfigErrorKind.none);
        const before = builder.usage;
        auto rejected = builder.resolve();
        assert(rejected.hasError && rejected.error.kind == ConfigErrorKind.limitExceeded);
        assert(builder.collecting && builder.usage == before);
        ConfigInput!Settings empty;
        assert(builder.submitBorrowed(u.value, empty).kind == ConfigErrorKind.none);
        if (boundary == 0) limits.maxPayloadBytes = 79 + headroom;
        else if (boundary == 1) limits.maxValueNodes = 10 + headroom;
        else if (boundary == 2) limits.maxResolvedRecords = 4 + headroom;
        else limits.maxContributions = 5 + headroom;
        assert(builder.setLimits(limits).kind == ConfigErrorKind.none);
        auto resolved = builder.resolve();
        assert(resolved.hasValue && builder.consumed);
        auto snapshot = resolved.takeValue();
        assert(snapshot.usage.payloadBytes == 79 && snapshot.usage.sources == 3
            && snapshot.usage.definitions == 3 && snapshot.usage.options == 1
            && snapshot.usage.depth == 2 && snapshot.usage.valueNodes == 10
            && snapshot.usage.resolvedRecords == 4 && snapshot.usage.contributions == 5);
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.paths == ["a", "bb", "ccc"]);
    }
}

/// An omitted dynamic member charges its fallback, not the ignored native field.
@("wired.config.collections.exactMapAccountingAndGeneratedDefaultRollback")
@safe unittest
{
    struct Entry { int width = 4; }
    struct Settings { @(ConfigMerge!(AttrsOf!Submodule)()) Entry[string] tools; }
    foreach (boundary; [0, 1, 2, 3, 4])
    {
        ConfigLimits limits;
        auto created = ConfigBuilder!Settings.create(limits);
        assert(created.hasValue);
        auto builder = created.takeValue();
        assert(builder.usage.payloadBytes == 43);
        auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "file");
        assert(u.hasValue && builder.usage.payloadBytes == 48);
        ConfigInput!Settings input;
        ConfigPresence!(Entry[string]) presence;
        presence.supplied = true;
        ConfigPresence!Entry entryPresence;
        entryPresence.supplied = true;
        presence.entries["k"] = entryPresence;
        input.tools = DefinitionSlot!(Entry[string])(true, ["k": Entry(999)], presence);
        assert(builder.submitBorrowed(u.value, input).kind == ConfigErrorKind.none);
        assert(builder.usage.payloadBytes == 56 && builder.usage.definitions == 2);
        if (boundary == 0) limits.maxPayloadBytes = 91;
        else if (boundary == 1) limits.maxDefinitions = 2;
        else if (boundary == 2) limits.maxValueNodes = 8;
        else if (boundary == 3) limits.maxResolvedRecords = 2;
        else limits.maxContributions = 2;
        assert(builder.setLimits(limits).kind == ConfigErrorKind.none);
        const before = builder.usage;
        auto rejected = builder.resolve();
        assert(rejected.hasError && rejected.error.kind == ConfigErrorKind.limitExceeded);
        assert(builder.collecting && builder.usage == before);
        if (boundary == 0) limits.maxPayloadBytes = 92;
        else if (boundary == 1) limits.maxDefinitions = 3;
        else if (boundary == 2) limits.maxValueNodes = 9;
        else if (boundary == 3) limits.maxResolvedRecords = 3;
        else limits.maxContributions = 3;
        assert(builder.setLimits(limits).kind == ConfigErrorKind.none);
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        assert(snapshot.usage.payloadBytes == 92 && snapshot.usage.sources == 2
            && snapshot.usage.definitions == 3 && snapshot.usage.options == 2
            && snapshot.usage.depth == 3 && snapshot.usage.valueNodes == 9
            && snapshot.usage.resolvedRecords == 3 && snapshot.usage.contributions == 3);
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.tools["k"].width == 4);
    }
}

/// Dynamic defaults are type initializers; selected built-ins are not doubled.
@("wired.config.collections.sparseDefaultsAndSelectedBuiltin")
@safe unittest
{
    struct Entry { int width = 4; bool enabled = true; }
    struct Settings
    {
        @(ConfigMerge!(AttrsOf!Submodule)()) Entry[string] tools = ["k": Entry(8, true)];
        @(ConfigMerge!(NullOr!Submodule)()) Nullable!Entry maybe;
    }
    {
        auto created = ConfigBuilder!Settings.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.tools["k"].width == 8 && copied.value.maybe.isNull);
    }
    {
        auto snapshot = decodedSnapshot!Settings(`{"tools":{"k":{"enabled":false}},"maybe":{}}`);
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue);
        auto value = copied.takeValue();
        assert(value.tools["k"].width == 4 && !value.tools["k"].enabled);
        assert(!value.maybe.isNull && value.maybe.get.width == 4 && value.maybe.get.enabled);
    }
    struct PresentBuiltin
    {
        @(ConfigMerge!(NullOr!Submodule)()) Nullable!Entry maybe = Nullable!Entry(Entry(8, false));
    }
    {
        auto created = ConfigBuilder!PresentBuiltin.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.maybe.get.width == 8 && !copied.value.maybe.get.enabled);
    }
    {
        auto snapshot = decodedSnapshot!PresentBuiltin(`{"maybe":{}}`);
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.maybe.get.width == 4 && copied.value.maybe.get.enabled);
    }
    struct WrappedMap { @(ConfigMerge!(AttrsOf!(NullOr!Submodule))()) Nullable!Entry[string] tools; }
    auto wrapped = decodedSnapshot!WrappedMap(`{"tools":{"k":{},"null":null}}`);
    auto copied = wrapped.copyConfig();
    assert(copied.hasValue && copied.value.tools["k"].get.width == 4
        && copied.value.tools["null"].isNull);
}

/// Null wrappers, null backing and non-null empty backing are different values.
@("wired.config.collections.nullableAndContainerStates")
@safe unittest
{
    struct Settings
    {
        @(ConfigMerge!(NullOr!(ListOf!Atomic))()) Nullable!(int[]) maybe;
        int[] atomicList;
        int[string] atomicMap;
    }
    foreach (state; [0, 1, 2, 3])
    {
        auto created = ConfigBuilder!Settings.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "");
        assert(u.hasValue);
        Settings value;
        if (state == 1) value.maybe = Nullable!(int[])(cast(int[]) null);
        else if (state == 2)
        {
            auto backing = new int[1];
            value.atomicList = backing[0 .. 0];
            value.atomicMap = ["seed": 1];
            value.atomicMap.remove("seed");
            assert(value.atomicList.ptr !is null && value.atomicMap !is null);
            value.maybe = Nullable!(int[])(value.atomicList);
        }
        else if (state == 3)
        {
            value.maybe = Nullable!(int[])([1, 2]);
            value.atomicList = [3, 4];
            value.atomicMap = ["k": 5];
        }
        auto input = fullConfigInput!Settings(value);
        assert(builder.submitBorrowed(u.value, input).kind == ConfigErrorKind.none);
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue);
        auto result = copied.takeValue();
        if (state == 0) assert(result.maybe.isNull);
        else
        {
            assert(!result.maybe.isNull);
            if (state == 1) assert(result.maybe.get.ptr is null);
            else if (state == 2) assert(result.maybe.get.length == 0 && result.maybe.get.ptr !is null);
            else assert(result.maybe.get == [1, 2]);
        }
        if (state <= 1) assert(result.atomicList.ptr is null && result.atomicMap is null);
        else if (state == 2) assert(result.atomicList.ptr !is null && result.atomicList.length == 0
            && result.atomicMap !is null && result.atomicMap.length == 0);
        else assert(result.atomicList == [3, 4] && result.atomicMap["k"] == 5);
    }
    struct Composed
    {
        @(ConfigMerge!(ListOf!Atomic)()) int[] paths;
        @(ConfigMerge!(AttrsOf!Atomic)()) int[string] tools;
        @(ConfigMerge!(NullOr!(ListOf!Atomic))()) Nullable!(int[]) maybe;
    }
    foreach (nullWrapper; [false, true])
    {
        auto created = ConfigBuilder!Composed.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        foreach (id; ["u", "p"])
        {
            auto registered = builder.registerSource(SourceId(id), ConfigSourceKind.custom, "");
            assert(registered.hasValue);
            Composed value;
            if (!(nullWrapper && id == "p"))
                value.maybe = Nullable!(int[])(id == "u" ? [1] : [2]);
            auto input = fullConfigInput!Composed(value);
            assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.none);
        }
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        assert(snapshot.visitOption!((scope ref const OptionView!(int[]) view) {
            assert(view.effective.hasValue && view.effective.get.length == 0
                && !view.effective.get.isNull);
        })("paths").kind == ConfigErrorKind.none);
        assert(snapshot.visitOption!((scope ref const OptionView!(int[string]) view) {
            assert(view.effective.hasValue && view.effective.get.length == 0
                && !view.effective.get.isNull);
        })("tools").kind == ConfigErrorKind.none);
        if (nullWrapper)
        {
            assert(snapshot.visitOption!((scope ref const OptionView!(Nullable!(int[])) view) {
                assert(view.status == OptionStatus.conflict && !view.effective.hasValue
                    && view.contributors.length == 2);
            })("maybe").kind == ConfigErrorKind.none);
            auto copied = snapshot.copyConfig();
            assert(copied.hasError && copied.error.failedOptions == ["maybe"]);
        }
        else
        {
            auto copied = snapshot.copyConfig();
            assert(copied.hasValue && copied.value.maybe.get == [2, 1]);
        }
    }
    auto absent = decodedSnapshot!Settings(`{}`);
    auto absentCopy = absent.copyConfig();
    assert(absentCopy.hasValue && absentCopy.value.maybe.isNull);
    auto invalidList = decodeConfigInput!Settings(`{"atomicList":null}`);
    auto invalidMap = decodeConfigInput!Settings(`{"atomicMap":null}`);
    assert(invalidList.hasJsonError && invalidMap.hasJsonError);
}

/// Deep capture and independent copying cannot share mutable nested storage.
@("wired.config.collections.nestedCaptureAndIndependentCopies")
@safe unittest
{
    struct Item { string name; int[] values; int[][string] nested; }
    struct Settings { Item[] items; Nullable!(Item[string]) maybe; int[2] fixedValues; }
    Settings first, second;
    {
        auto created = ConfigBuilder!Settings.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "");
        assert(u.hasValue);
        Settings caller;
        auto letters = "label".dup;
        string borrowed = () @trusted { return cast(string) letters; }();
        caller.items = [Item(borrowed, [1, 2], ["k": [3, 4]])];
        caller.maybe = Nullable!(Item[string])(["entry": Item("inside", [5, 6], ["deep": [7]])]);
        caller.fixedValues = [8, 9];
        auto input = fullConfigInput!Settings(caller);
        auto captured = captureInput!Settings(input);
        assert(captured.hasValue);
        auto capsule = captured.takeValue();
        letters[0] = 'X';
        caller.items[0].values[0] = 100;
        caller.items[0].nested["k"][0] = 200;
        caller.items[0].nested["extra"] = [300];
        caller.maybe.get["entry"].values[0] = 400;
        caller.maybe.get["entry"].nested["deep"][0] = 500;
        caller.maybe.get.remove("entry");
        caller.items[0].name = "replacement";
        input.items.presence.elements = null;
        assert(builder.submitOwned(u.value, capsule).kind == ConfigErrorKind.none);
        assert(capsule.consumed);
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        assert(snapshot.visitDefinitions!((scope ref const DefinitionView!(Item[]) view) {
            if (view.source == u.value)
            {
                assert(view.value.get[0].members.name == "label");
                assert(view.value.get[0].members.values.length == 2
                    && view.value.get[0].members.values[0] == 1
                    && view.value.get[0].members.values[1] == 2);
                assert(view.value.get[0].members.nested.length == 1
                    && view.value.get[0].members.nested["k"].length == 2
                    && view.value.get[0].members.nested["k"][0] == 3
                    && view.value.get[0].members.nested["k"][1] == 4);
            }
        })("items").kind == ConfigErrorKind.none);
        auto one = snapshot.copyConfig();
        auto two = snapshot.copyConfig();
        assert(one.hasValue && two.hasValue);
        first = one.takeValue();
        second = two.takeValue();
    }
    assert(first.items[0].name == "label" && first.maybe.get["entry"].values == [5, 6]
        && first.maybe.get["entry"].nested["deep"] == [7] && first.fixedValues == [8, 9]);
    first.items[0].values[0] = 10;
    first.items[0].nested["k"][0] = 20;
    first.items[0].nested["new"] = [30];
    first.maybe.get["entry"].values[0] = 40;
    first.maybe.get["entry"].nested["deep"][0] = 50;
    first.maybe.get.remove("entry");
    assert(second.items[0].values == [1, 2] && second.items[0].nested.length == 1
        && second.items[0].nested["k"] == [3, 4] && second.maybe.get["entry"].values == [5, 6]
        && second.maybe.get["entry"].nested["deep"] == [7]);
}

/// Presence and metadata have typed shapes; equal-size wrong-key trees are invalid.
@("wired.config.collections.shapeAdmissionAndIgnoredPayload")
@safe unittest
{
    enum Mode : int { valid = 1 }
    struct Entry { int width = 4; Mode mode = Mode.valid; string[] unused; }
    struct Settings
    {
        @(ConfigMerge!(AttrsOf!Submodule)()) Entry[string] tools;
        @(ConfigMerge!(ListOf!Submodule)()) Entry[] plugins;
        @(ConfigMerge!(NullOr!Submodule)()) Nullable!Entry maybe;
    }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "");
    assert(u.hasValue);
    ConfigPresence!Entry child;
    child.supplied = true;
    child.members.width.supplied = true;
    ConfigPresence!(Entry[string]) mapPresence;
    mapPresence.supplied = true;
    mapPresence.entries["wrong"] = child;
    ConfigInput!Settings input;
    input.tools = DefinitionSlot!(Entry[string])(true, ["k": Entry.init], mapPresence);
    const before = builder.usage;
    auto wrongKey = builder.submitBorrowed(u.value, input);
    assert(wrongKey.kind == ConfigErrorKind.invalidMetadata && builder.usage == before);
    mapPresence.entries.remove("wrong");
    mapPresence.entries["k"] = child;
    input.tools = DefinitionSlot!(Entry[string])(true,
        ["k": Entry(8, cast(Mode) 999, [(new char[1024]).idup])], mapPresence);
    auto captured = captureInput!Settings(input);
    assert(captured.hasValue);
    auto capsule = captured.takeValue();
    assert(builder.submitOwned(u.value, capsule).kind == ConfigErrorKind.none);
    const accepted = builder.usage;
    ConfigInput!Settings malformed;
    malformed.plugins = DefinitionSlot!(Entry[])(true, [Entry.init]);
    malformed.plugins.presence.elements = null;
    assert(builder.submitBorrowed(u.value, malformed).kind == ConfigErrorKind.invalidMetadata);
    assert(builder.usage == accepted);
    malformed = ConfigInput!Settings.init;
    malformed.maybe = DefinitionSlot!(Nullable!Entry)(true, Nullable!Entry(Entry.init));
    malformed.maybe.presence.hasValue = false;
    assert(builder.submitBorrowed(u.value, malformed).kind == ConfigErrorKind.invalidMetadata);
    assert(builder.usage == accepted);
    malformed = ConfigInput!Settings.init;
    malformed.tools = DefinitionSlot!(Entry[string])(true, ["k": Entry.init]);
    malformed.tools.presence.entries["k"].supplied = false;
    assert(builder.submitBorrowed(u.value, malformed).kind == ConfigErrorKind.invalidMetadata);
    assert(builder.usage == accepted);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.tools["k"].width == 8
        && copied.value.tools["k"].mode == Mode.valid && copied.value.tools["k"].unused is null);
}

/// Original enclosing key/value policy sites survive lists, maps and nullable layers.
@("wired.config.collections.originalSitePoliciesAndDuplicateOccurrences")
@safe unittest
{
    import sparkles.wired.policy : WireName, WireCase, WireRepr, Repr, CaseStyle, WireTarget;
    enum Key : int { fastPath = 1, slowPath = 2 }
    enum Mode : int { lowLevel = 1, highLevel = 2 }
    struct Entry
    {
        @WireName("choice")
        @WireCase(CaseStyle.kebabCase, WireTarget.value)
        Nullable!Mode selected;
    }
    struct Settings
    {
        @WireName("table")
        @WireCase(CaseStyle.snakeCase, WireTarget.key)
        @WireCase(CaseStyle.kebabCase, WireTarget.value)
        @(ConfigMerge!(AttrsOf!(ListOf!Atomic))()) Mode[][Key] tools;
        @WireName("extensions")
        @WireCase(CaseStyle.kebabCase, WireTarget.value)
        @(ConfigMerge!(ListOf!Submodule)()) Entry[] plugins;
    }
    auto snapshot = decodedSnapshot!Settings(
        `{"table":{"fast_path":["high-level"],"slow_path":["low-level"]},"extensions":[{"choice":"high-level"}]}`);
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.tools[Key.fastPath] == [Mode.highLevel]
        && copied.value.tools[Key.slowPath] == [Mode.lowLevel]
        && copied.value.plugins[0].selected.get == Mode.highLevel);
    auto original = decodeConfigInput!Settings(`{"table":{"fastPath":["high-level"]}}`);
    assert(original.hasJsonError);
    auto duplicate = decodeConfigInput!Settings(
        `{"table":{"fast_path":["high-level"],"fast\u005fpath":["high-level"]}}`);
    assert(duplicate.hasJsonError && duplicate.jsonError.path[] == ".table.fast_path");
    auto memberDuplicate = decodeConfigInput!Settings(
        `{"extensions":[{"choice":"high-level","ch\u006fice":"high-level"}]}`);
    assert(memberDuplicate.hasJsonError);
    auto unknownThenDuplicate = decodeConfigInput!Settings(
        `{"ignored":1,"extensions":[{"choice":"high-level","choice":"low-level"}]}`,
        DefinitionMetadata!Settings.init, ConfigLimits.init,
        ConfigDecodeOptions(ConfigUnknownMembers.ignore));
    assert(unknownThenDuplicate.hasJsonError);
    enum Aliased : int { first = 1, alsoFirst = 1, second = 2 }
    struct Numeric
    {
        @WireRepr(Repr.value, WireTarget.key)
        @(ConfigMerge!(AttrsOf!Atomic)()) int[Aliased] tools;
    }
    auto numeric = decodedSnapshot!Numeric(`{"tools":{"1":7,"2":9}}`);
    auto numericCopy = numeric.copyConfig();
    assert(numericCopy.hasValue && numericCopy.value.tools[Aliased.alsoFirst] == 7);
    auto alternateSpelling = decodedSnapshot!Numeric(`{"tools":{"01":7}}`);
    auto alternateCopy = alternateSpelling.copyConfig();
    assert(alternateCopy.hasValue && alternateCopy.value.tools[Aliased.first] == 7);
    auto numericDuplicate = decodeConfigInput!Numeric(`{"tools":{"1":7,"01":9}}`);
    assert(numericDuplicate.hasJsonError);
    auto undeclared = decodeConfigInput!Numeric(`{"tools":{"9":7}}`);
    assert(undeclared.hasJsonError);
    auto numericNull = decodeConfigInput!Numeric(`{"tools":null}`);
    assert(numericNull.hasJsonError);
}

/// Schema admission happens before any prospective priorities or map contents.
@("wired.config.collections.compileTimePolicyAndGraphAdmission")
@safe unittest
{
    import sparkles.wired.policy : WireCase, CaseStyle, WireTarget, WireConvert,
        WireOptional, WireSkip, WireInvalid;
    import sparkles.wired.overlay : WireSection;
    enum Key : int { fastPath = 1, fast_path = 2 }
    struct Colliding
    {
        @WireCase(CaseStyle.snakeCase, WireTarget.key)
        @(ConfigMerge!(AttrsOf!Atomic)()) int[Key] tools;
    }
    static assert(!__traits(compiles, ConfigBuilder!Colliding.create()));
    struct FixedList { @(ConfigMerge!(ListOf!Atomic)()) int[2] paths; }
    struct WrongLines { @(ConfigMerge!Lines()) int lines; }
    struct Duplicate { @(ConfigMerge!Atomic()) @(ConfigMerge!Lines()) string text; }
    @WireSection struct Section { int width; }
    struct SectionConflict { @(ConfigMerge!Atomic()) Section section; }
    struct Recursive { Recursive[] children; }
    struct Pointer { int* pointer; }
    struct NestedNull { Nullable!(Nullable!int) maybe; }
    struct CustomCopy { int[] values; this(this) {} }
    struct Custom { CustomCopy custom; }
    static assert(!__traits(compiles, ConfigBuilder!FixedList.create()));
    static assert(!__traits(compiles, ConfigBuilder!WrongLines.create()));
    static assert(!__traits(compiles, ConfigBuilder!Duplicate.create()));
    static assert(!__traits(compiles, ConfigBuilder!SectionConflict.create()));
    static assert(!__traits(compiles, ConfigBuilder!Recursive.create()));
    static assert(!__traits(compiles, ConfigBuilder!Pointer.create()));
    static assert(!__traits(compiles, ConfigBuilder!NestedNull.create()));
    static assert(!__traits(compiles, ConfigBuilder!Custom.create()));
    struct OptionalDefault
    {
        @WireOptional(WireSkip.whenDefault, WireInvalid.useDefault) int[] values;
    }
    static assert(!__traits(compiles, decodeConfigInput!OptionalDefault(`{"values":[1]}`)));
    enum Mode : int { valid = 1 }
    struct BadPrototype { Mode mode = cast(Mode) 999; }
    struct EmptyList { @(ConfigMerge!(ListOf!Submodule)()) BadPrototype[] items; }
    struct NullWrapper { @(ConfigMerge!(NullOr!Submodule)()) Nullable!BadPrototype maybe; }
    auto empty = ConfigBuilder!EmptyList.create();
    auto nullable = ConfigBuilder!NullWrapper.create();
    assert(empty.hasError && empty.error.kind == ConfigErrorKind.invalidValue);
    assert(nullable.hasError && nullable.error.kind == ConfigErrorKind.invalidValue);
}

/// Atomic ownership descent does not turn nested UDAs into composition or checks.
@("wired.config.collections.atomicDescentIgnoresChildConfigPolicies")
@safe unittest
{
    static ValidationResult reject(in int value) @safe pure nothrow
        => ValidationResult.reject("must-not-run");
    struct Data
    {
        @(ConfigMerge!Lines()) @(ConfigCheck!reject()) int width;
        int[] payload;
    }
    struct Settings { Data[] data; }
    auto snapshot = decodedSnapshot!Settings(`{"data":[{"width":8,"payload":[1,2]}]}`);
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.data[0].width == 8 && copied.value.data[0].payload == [1, 2]);
}

/// Fixed arrays lack a container tag; nullable arrays have two distinct tags.
@("wired.config.collections.fixedAndNullableLogicalCharges")
@safe unittest
{
    struct Fixed { int[2] pair; }
    Fixed fixedValue;
    fixedValue.pair = [1, 2];
    auto fixedInput = fullConfigInput!Fixed(fixedValue);
    ConfigLimits limits;
    limits.maxPayloadBytes = 11;
    auto fixedSmall = captureInput!Fixed(fixedInput, DefinitionMetadata!Fixed.init, limits);
    assert(fixedSmall.hasError && fixedSmall.error.kind == ConfigErrorKind.limitExceeded);
    limits.maxPayloadBytes = 12;
    auto fixedExact = captureInput!Fixed(fixedInput, DefinitionMetadata!Fixed.init, limits);
    assert(fixedExact.hasValue);
    auto fixedCapsule = fixedExact.takeValue();
    assert(fixedCapsule.usage.payloadBytes == 12 && fixedCapsule.usage.valueNodes == 3);
    struct Wrapped { Nullable!(int[]) maybe; }
    Wrapped wrapped;
    wrapped.maybe = Nullable!(int[])([1, 2]);
    auto wrappedInput = fullConfigInput!Wrapped(wrapped);
    limits.maxPayloadBytes = 14;
    auto wrappedSmall = captureInput!Wrapped(wrappedInput, DefinitionMetadata!Wrapped.init, limits);
    assert(wrappedSmall.hasError && wrappedSmall.error.kind == ConfigErrorKind.limitExceeded);
    limits.maxPayloadBytes = 15;
    auto wrappedExact = captureInput!Wrapped(wrappedInput, DefinitionMetadata!Wrapped.init, limits);
    assert(wrappedExact.hasValue);
    auto wrappedCapsule = wrappedExact.takeValue();
    assert(wrappedCapsule.usage.payloadBytes == 15 && wrappedCapsule.usage.valueNodes == 4);
}

/// Separating newlines and the rejected candidate remain charged after a check.
@("wired.config.collections.linesMergedCheckAndAccounting")
@safe unittest
{
    static ValidationResult reject(in string value) @safe pure nothrow
        => ValidationResult.reject("join");
    struct Settings { @(ConfigMerge!Lines()) @(ConfigCheck!reject()) string lines; }
    ConfigLimits limits;
    auto created = ConfigBuilder!Settings.create(limits);
    assert(created.hasValue);
    auto builder = created.takeValue();
    assert(builder.usage.payloadBytes == 24);
    foreach (i, id; ["a", "aa", "b"])
    {
        auto registered = builder.registerSource(SourceId(id), ConfigSourceKind.custom, "");
        assert(registered.hasValue);
        Settings value;
        value.lines = i == 0 ? "a" : i == 1 ? "" : "b\n";
        auto input = fullConfigInput!Settings(value);
        assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.none);
    }
    assert(builder.usage.payloadBytes == 36);
    limits.maxPayloadBytes = 44;
    assert(builder.setLimits(limits).kind == ConfigErrorKind.none);
    const before = builder.usage;
    auto rejected = builder.resolve();
    assert(rejected.hasError && rejected.error.kind == ConfigErrorKind.limitExceeded);
    assert(builder.collecting && builder.usage == before);
    limits.maxPayloadBytes = 45;
    assert(builder.setLimits(limits).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    assert(snapshot.usage.payloadBytes == 45 && snapshot.usage.valueNodes == 5);
    assert(snapshot.visitOption!((scope ref const OptionView!string view) {
        assert(view.status == OptionStatus.invalidMergedValue && !view.effective.hasValue);
        assert(view.contributors.length == 3 && view.diagnostic.hasValue
            && view.diagnostic.get.code == "join");
    })("lines").kind == ConfigErrorKind.none);
    auto copied = snapshot.copyConfig();
    assert(copied.hasError && copied.error.kind == ConfigErrorKind.notFullyResolved
        && copied.error.failedOptions == ["lines"]);
}

/// One conflicting and one rejected child cannot hide a successful sibling.
@("wired.config.collections.mixedBranchFailuresSuppressAncestorCheck")
@safe unittest
{
    static ValidationResult positive(in int value) @safe pure nothrow
        => value > 0 ? ValidationResult.accept() : ValidationResult.reject("positive", "must exceed zero");
    struct Entry
    {
        int width = 4;
        @(ConfigCheck!positive()) int bad = 1;
        bool enabled = true;
    }
    static ValidationResult rejectParent(in Entry[string] value) @safe pure nothrow
        => ValidationResult.reject("container", "child failures must win");
    struct Settings
    {
        @(ConfigMerge!(AttrsOf!Submodule)()) @(ConfigCheck!rejectParent()) Entry[string] tools;
    }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "");
    auto p = builder.registerSource(SourceId("p"), ConfigSourceKind.custom, "");
    assert(u.hasValue && p.hasValue);
    auto user = decodeConfigInput!Settings(`{"tools":{"k":{"width":8,"bad":0}}}`);
    auto project = decodeConfigInput!Settings(`{"tools":{"k":{"width":9,"enabled":false}}}`);
    assert(user.hasValue && project.hasValue);
    auto ui = user.takeValue();
    auto pi = project.takeValue();
    assert(builder.submitOwned(u.value, ui).kind == ConfigErrorKind.none);
    assert(builder.submitOwned(p.value, pi).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    assert(snapshot.visitOption!((scope ref const OptionView!(Entry[string]) view) {
        assert(view.status == OptionStatus.unresolvedChildren && !view.effective.hasValue);
        assert(!view.diagnostic.hasValue && view.contributors.length == 2);
    })("tools").kind == ConfigErrorKind.none);
    assert(snapshot.visitOption!((scope ref const OptionView!int view) {
        assert(view.status == OptionStatus.conflict && !view.effective.hasValue
            && view.contributors.length == 2);
    })(`tools["k"].width`).kind == ConfigErrorKind.none);
    assert(snapshot.visitOption!((scope ref const OptionView!int view) {
        assert(view.status == OptionStatus.invalidSelectedValue && !view.effective.hasValue);
        assert(view.diagnostic.hasValue && view.diagnostic.get.code == "positive"
            && view.diagnostic.get.detail == "must exceed zero");
    })(`tools["k"].bad`).kind == ConfigErrorKind.none);
    assert(snapshot.visitOption!((scope ref const OptionView!bool view) {
        assert(view.status == OptionStatus.resolved && view.effective.get == false);
    })(`tools["k"].enabled`).kind == ConfigErrorKind.none);
    bool userOriginal, projectOriginal;
    assert(snapshot.visitDefinitions!((scope ref const DefinitionView!(Entry[string]) view) {
        if (view.source == u.value)
        {
            userOriginal = true;
            assert(view.disposition == DefinitionDisposition.selected);
            assert(view.presence.entries["k"].members.width.supplied
                && view.presence.entries["k"].members.bad.supplied
                && !view.presence.entries["k"].members.enabled.supplied);
        }
        else if (view.source == p.value)
        {
            projectOriginal = true;
            assert(view.disposition == DefinitionDisposition.selected);
            assert(view.presence.entries["k"].members.width.supplied
                && !view.presence.entries["k"].members.bad.supplied
                && view.presence.entries["k"].members.enabled.supplied);
        }
    })("tools").kind == ConfigErrorKind.none);
    assert(userOriginal && projectOriginal);
    auto copied = snapshot.copyConfig();
    assert(copied.hasError && copied.error.kind == ConfigErrorKind.notFullyResolved);
    assert(copied.error.failedOptions == [`tools["k"].bad`, `tools["k"].width`]);
}

/// Type-initializer arrays/maps are privately captured, like submitted graphs.
@("wired.config.collections.mutableBuiltinGraphCapture")
@safe unittest
{
    struct Entry { int[] values = [1, 2]; int[][string] nested = ["k": [3, 4]]; }
    struct Settings { Entry[] items = [Entry.init]; }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    Settings caller;
    scope(exit)
    {
        caller.items[0].values[0] = 1;
        caller.items[0].nested["k"][0] = 3;
        caller.items[0].nested.remove("extra");
    }
    caller.items[0].values[0] = 100;
    caller.items[0].nested["k"][0] = 200;
    caller.items[0].nested["extra"] = [300];
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.items[0].values == [1, 2]
        && copied.value.items[0].nested.length == 1 && copied.value.items[0].nested["k"] == [3, 4]);
}

/// Unsupported ownership and conversion controls are rejected at nested sites.
@("wired.config.collections.nestedUnsupportedSchemaControls")
@safe unittest
{
    import sparkles.wired.policy : WireConvert;
    static int toWire(int value) @safe pure nothrow => value;
    static int fromWire(int value) @safe pure nothrow => value;
    struct Converted { @WireConvert!(toWire, fromWire) int width; }
    struct ConversionRoot { Converted[] items; }
    static assert(!__traits(compiles, decodeConfigInput!ConversionRoot(`{"items":[{"width":1}]}`)));
    struct Destructed { int[] values; ~this() {} }
    struct DestructionRoot { Destructed[string] values; }
    class Reference {}
    struct ClassRoot { Reference[] items; }
    static ValidationResult positive(in int value) @safe pure nothrow
        => ValidationResult.accept();
    struct DuplicateCheck
    {
        @(ConfigCheck!positive()) @(ConfigCheck!positive()) int width;
    }
    struct CheckedRoot { @(ConfigMerge!(ListOf!Submodule)()) DuplicateCheck[] items; }
    static assert(!__traits(compiles, ConfigBuilder!DestructionRoot.create()));
    static assert(!__traits(compiles, ConfigBuilder!ClassRoot.create()));
    static assert(!__traits(compiles, ConfigBuilder!CheckedRoot.create()));
}

/// An independent small-set oracle checks values and exact eligible conflict sets.
@("wired.config.collections.mapDefinitionSetAlgebra")
@safe unittest
{
    struct Settings { @(ConfigMerge!(AttrsOf!Atomic)()) int[string] tools; }
    immutable string[3] ids = ["a", "aa", "b"];
    foreach (priorityBits; 0 .. 8)
    foreach (keyBits; 0 .. 8)
    foreach (valueBits; 0 .. 8)
    foreach (arrival; permutations)
    foreach (partition; [0, 1])
    {
        uint[3] priorities;
        string[3] keys;
        int[3] values;
        uint selected = 1000;
        foreach (i; 0 .. 3)
        {
            priorities[i] = priorityBits & (1 << i) ? 500 : 1000;
            keys[i] = keyBits & (1 << i) ? "b" : "a";
            values[i] = valueBits & (1 << i) ? 2 : 1;
            if (priorities[i] == 500) selected = 500;
        }
        uint[2] expectedMasks;
        int[2] expectedValues;
        foreach (i; 0 .. 3)
            if (priorities[i] == selected)
            {
                const k = keys[i] == "a" ? 0 : 1;
                expectedMasks[k] |= 1 << i;
                expectedValues[k] = values[i];
            }
        auto created = ConfigBuilder!Settings.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        SourceRef[3] sources;
        foreach (i; arrival)
        {
            auto registered = builder.registerSource(SourceId(ids[i]), ConfigSourceKind.custom,
                "", priorities[i]);
            assert(registered.hasValue);
            sources[i] = registered.value;
        }
        foreach (i; arrival)
        {
            Settings value;
            value.tools[keys[i]] = values[i];
            auto input = fullConfigInput!Settings(value);
            if ((i < 2) == (partition == 0))
            {
                auto captured = captureInput!Settings(input);
                assert(captured.hasValue);
                auto capsule = captured.takeValue();
                assert(builder.submitOwned(sources[i], capsule).kind == ConfigErrorKind.none);
            }
            else assert(builder.submitBorrowed(sources[i], input).kind == ConfigErrorKind.none);
        }
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        bool anyConflict;
        foreach (k, key; ["a", "b"])
        {
            const mask = expectedMasks[k];
            if (!mask) continue;
            const conflict = (mask & (mask - 1)) != 0;
            anyConflict |= conflict;
            bool visited;
            const path = key == "a" ? `tools["a"]` : `tools["b"]`;
            assert(snapshot.visitBranch!((scope ref const BranchView!int view) {
                visited = true;
                assert(!view.declaredOption && view.owningOption == "tools");
                assert(view.selectedPriority == selected);
                assert(view.status == (conflict ? OptionStatus.conflict : OptionStatus.resolved));
                assert(view.effective.hasValue == !conflict);
                if (!conflict) assert(view.effective.get == expectedValues[k]);
            })(path).kind == ConfigErrorKind.none && visited);
            uint observedMask;
            assert(snapshot.visitBranchDefinitions!((scope ref const BranchDefinitionView!int view) {
                if (view.priority == selected)
                {
                    assert(view.disposition == (conflict ? DefinitionDisposition.conflicting
                        : DefinitionDisposition.contributing));
                    foreach (i; 0 .. 3)
                        if (view.source == sources[i]) observedMask |= 1 << i;
                }
            })(path).kind == ConfigErrorKind.none);
            assert(observedMask == mask);
        }
        auto copied = snapshot.copyConfig();
        if (anyConflict)
            assert(copied.hasError && copied.error.kind == ConfigErrorKind.notFullyResolved);
        else
        {
            assert(copied.hasValue);
            foreach (k, key; ["a", "b"])
            {
                if (expectedMasks[k]) assert(copied.value.tools[key] == expectedValues[k]);
                else assert((key in copied.value.tools) is null);
            }
        }
    }
}

/// Losing root maps cannot re-enter through a stronger child override.
@("wired.config.collections.excludedParentAndOriginalProjectionLookup")
@safe unittest
{
    struct Entry { int width = 4; bool enabled = true; }
    struct Settings { @(ConfigMerge!(AttrsOf!Submodule)()) Entry[string] tools; }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "", 1000);
    auto p = builder.registerSource(SourceId("p"), ConfigSourceKind.projectFile, "", 1100);
    assert(u.hasValue && p.hasValue);
    auto user = decodeConfigInput!Settings(`{"tools":{"k":{"width":8}}}`);
    DefinitionMetadata!Settings metadata;
    metadata.tools.branches.shaped = true;
    metadata.tools.branches.entries["k"] = ConfigBranchMetadata!Entry.init;
    metadata.tools.branches.entries["k"].shaped = true;
    metadata.tools.branches.entries["k"].members.enabled.priority = 0u;
    metadata.tools.branches.entries["k"].members.enabled.location = SourceLocation(42, 3, 7);
    auto project = decodeConfigInput!Settings(`{"tools":{"k":{"enabled":false}}}`, metadata);
    assert(user.hasValue && project.hasValue);
    auto ui = user.takeValue();
    auto pi = project.takeValue();
    assert(builder.submitOwned(u.value, ui).kind == ConfigErrorKind.none);
    assert(builder.submitOwned(p.value, pi).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.tools["k"].width == 8 && copied.value.tools["k"].enabled);
    DefinitionRef excluded;
    bool foundRoot;
    assert(snapshot.visitDefinitions!((scope ref const DefinitionView!(Entry[string]) view) {
        if (view.source == p.value)
        {
            excluded = view.reference;
            foundRoot = true;
            assert(view.disposition == DefinitionDisposition.overridden);
            assert(!view.presence.entries["k"].members.width.supplied
                && view.presence.entries["k"].members.enabled.supplied);
        }
    })("tools").kind == ConfigErrorKind.none);
    assert(foundRoot);
    bool foundOriginal;
    assert(snapshot.visitBranchDefinitions!((scope ref const BranchDefinitionView!bool view) {
        foundOriginal = true;
        assert(view.parent == excluded && view.originalLocator == `["k"].enabled`);
        assert(view.disposition == DefinitionDisposition.overridden && view.priority == 0);
        assert(view.value.hasValue && !view.value.get && view.presence.supplied);
        assert(!view.location.isNull && view.location.get == SourceLocation(42, 3, 7));
    })(excluded, `["k"].enabled`).kind == ConfigErrorKind.none);
    assert(foundOriginal);
}

/// A generated child winner replaces the enclosing fully supplied native value.
@("wired.config.collections.generatedChildOverridesFullSuppliedContainer")
@safe unittest
{
    struct Entry { int width = 4; }
    struct Settings { @(ConfigMerge!(AttrsOf!Submodule)()) Entry[string] tools; }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "", 1000);
    assert(registered.hasValue);
    Settings value;
    value.tools["k"] = Entry(8);
    auto input = fullConfigInput!Settings(value);
    DefinitionMetadata!Settings metadata;
    metadata.tools.branches.shaped = true;
    ConfigBranchMetadata!Entry branch;
    branch.shaped = true;
    branch.members.width.priority = 2000u;
    metadata.tools.branches.entries["k"] = branch;
    assert(builder.submitBorrowed(registered.value, input, metadata).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    assert(snapshot.visitBranch!((scope ref const BranchView!int view) {
        assert(view.effective.hasValue && view.effective.get == 4);
        assert(view.selectedPriority == 1500);
    })(`tools["k"].width`).kind == ConfigErrorKind.none);
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.tools["k"].width == 4);
}

/// Source index zero remains zero when it contributes to effective index two.
@("wired.config.collections.typedBranchesAndSourceEffectiveLocators")
@safe unittest
{
    struct Entry { bool enabled = true; }
    struct Settings
    {
        @(ConfigMerge!(ListOf!Submodule)()) Entry[] plugins;
        @(ConfigMerge!(ListOf!Atomic)()) string[] paths;
        @(ConfigMerge!(AttrsOf!Atomic)()) int[string] tools;
    }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "", 1000, 20);
    auto p = builder.registerSource(SourceId("p"), ConfigSourceKind.custom, "", 1000, 10);
    assert(u.hasValue && p.hasValue);
    DefinitionMetadata!Settings metadata;
    metadata.plugins.location = SourceLocation(10, 2, 1);
    metadata.plugins.branches.shaped = true;
    metadata.plugins.branches.elements.length = 1;
    metadata.plugins.branches.elements[0].shaped = true;
    metadata.plugins.branches.elements[0].members.enabled.location = SourceLocation(20, 2, 11);
    auto user = decodeConfigInput!Settings(`{"plugins":[{"enabled":false}],"paths":["u"],"tools":{"<key>":7}}`, metadata);
    auto project = decodeConfigInput!Settings(`{"plugins":[{"enabled":true},{"enabled":false}],"paths":["p"]}`);
    assert(user.hasValue && project.hasValue);
    auto ui = user.takeValue();
    auto pi = project.takeValue();
    assert(builder.submitOwned(u.value, ui).kind == ConfigErrorKind.none);
    assert(builder.submitOwned(p.value, pi).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    DefinitionRef userRoot;
    bool rootSeen;
    assert(snapshot.visitDefinitions!((scope ref const DefinitionView!(Entry[]) view) {
        if (view.source == u.value)
        {
            userRoot = view.reference;
            rootSeen = true;
            assert(view.value.get.length == 1 && !view.value.get[0].members.enabled);
            assert(view.presence.elements.length == 1
                && view.presence.elements[0].members.enabled.supplied);
        }
    })("plugins").kind == ConfigErrorKind.none);
    assert(rootSeen);
    bool activeSeen, originalSeen;
    ContributionRef projected;
    assert(snapshot.visitBranch!((scope ref const BranchView!bool view) {
        activeSeen = true;
        assert(view.path == "plugins[2].enabled" && view.pattern == "plugins[<index>].enabled");
        assert(view.declaredOption && view.status == OptionStatus.resolved
            && view.selectedPriority == 1000 && !view.effective.get);
    })("plugins[2].enabled").kind == ConfigErrorKind.none && activeSeen);
    assert(snapshot.visitBranchDefinitions!((scope ref const BranchDefinitionView!bool view) {
        if (view.source == u.value)
        {
            originalSeen = true;
            projected = view.ref_;
            assert(view.parent == userRoot && view.originalLocator == "[0].enabled");
            assert(view.path == "plugins[2].enabled" && view.pattern == "plugins[<index>].enabled");
            assert(!view.location.isNull && view.location.get == SourceLocation(20, 2, 11));
            assert(view.disposition == DefinitionDisposition.contributing && !view.value.get);
        }
    })("plugins[2].enabled").kind == ConfigErrorKind.none && originalSeen);
    bool byOriginal;
    assert(snapshot.visitBranchDefinitions!((scope ref const BranchDefinitionView!bool view) {
        byOriginal = true;
        assert(view.ref_ == projected && view.path == "plugins[2].enabled");
    })(userRoot, "[0].enabled").kind == ConfigErrorKind.none && byOriginal);
    bool dataSeen;
    assert(snapshot.visitBranch!((scope ref const BranchView!string view) {
        dataSeen = true;
        assert(view.effective.get == "p" && !view.declaredOption && view.owningOption == "paths");
    })("paths[0]").kind == ConfigErrorKind.none && dataSeen);
    assert(snapshot.visitOption!((scope ref const OptionView!(string[]) view) {
        assert(view.path == "paths" && view.effective.get.length == 2
            && view.effective.get[0] == "p" && view.effective.get[1] == "u");
    })("paths[0]").kind == ConfigErrorKind.none);
    assert(snapshot.visitOption!((scope ref const OptionView!bool view) {
        assert(view.path == "plugins[2].enabled" && !view.effective.get);
    })("plugins[2].enabled").kind == ConfigErrorKind.none);
    assert(snapshot.visitBranch!((scope ref const BranchView!int view) {
        assert(view.path == `tools["<key>"]` && !view.declaredOption && view.effective.get == 7);
    })(`tools["<key>"]`).kind == ConfigErrorKind.none);
    uint[3] enabledOrder;
    size_t at;
    assert(snapshot.visitBranches!((scope ref const view) {
        static if (is(typeof(view) == const(BranchView!bool)))
        {
            assert(at < 3 && view.pattern == "plugins[<index>].enabled");
            enabledOrder[at] = view.effective.get ? 1 : 0;
            ++at;
        }
    })().kind == ConfigErrorKind.none);
    assert(at == 3 && enabledOrder == [1, 0, 0]);
    import std.algorithm.mutation : move;
    auto moved = move(snapshot);
    bool movedProjection;
    assert(moved.visitBranchDefinitions!((scope ref const BranchDefinitionView!bool view) {
        movedProjection = true;
        assert(view.ref_ == projected && view.parent == userRoot
            && view.path == "plugins[2].enabled");
    })(userRoot, "[0].enabled").kind == ConfigErrorKind.none && movedProjection);
    auto otherCreated = ConfigBuilder!Settings.create();
    assert(otherCreated.hasValue);
    auto otherBuilder = otherCreated.takeValue();
    auto otherResolved = otherBuilder.resolve();
    assert(otherResolved.hasValue);
    auto other = otherResolved.takeValue();
    bool wrongOwnerCalled;
    auto wrongOwner = other.visitBranchDefinitions!((scope ref const BranchDefinitionView!bool view) {
        wrongOwnerCalled = true;
    })(userRoot, "[0].enabled");
    assert(wrongOwner.kind == ConfigErrorKind.wrongOwner && !wrongOwnerCalled);
}

/// Metadata shape mismatches and absent-child overrides reject atomically.
@("wired.config.collections.metadataShapeAndAbsentOverrideAdmission")
@safe unittest
{
    struct Entry { int width = 4; bool enabled = true; }
    struct Settings { @(ConfigMerge!(AttrsOf!Submodule)()) Entry[string] tools; }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "");
    assert(registered.hasValue);
    ConfigPresence!(Entry[string]) presence;
    presence.supplied = true;
    ConfigPresence!Entry entry;
    entry.supplied = true;
    entry.members.width.supplied = true;
    presence.entries["k"] = entry;
    ConfigInput!Settings input;
    input.tools = DefinitionSlot!(Entry[string])(true, ["k": Entry(8, true)], presence);
    DefinitionMetadata!Settings metadata;
    metadata.tools.branches.shaped = true;
    metadata.tools.branches.entries["wrong"] = ConfigBranchMetadata!Entry.init;
    metadata.tools.branches.entries["wrong"].shaped = true;
    metadata.tools.branches.entries["wrong"].members.width.priority = 500u;
    const before = builder.usage;
    auto wrongKey = builder.submitBorrowed(registered.value, input, metadata);
    assert(wrongKey.kind == ConfigErrorKind.invalidMetadata && builder.usage == before);
    metadata.tools.branches.entries.remove("wrong");
    metadata.tools.branches.entries["k"] = ConfigBranchMetadata!Entry.init;
    metadata.tools.branches.entries["k"].shaped = true;
    metadata.tools.branches.entries["k"].members.enabled.priority = 0u;
    auto absentMember = captureInput!Settings(input, metadata);
    assert(absentMember.hasError && absentMember.error.kind == ConfigErrorKind.invalidMetadata);
    assert(builder.usage == before);
    metadata.tools.branches.entries["k"].members.enabled.priority.nullify();
    metadata.tools.branches.entries["k"].members.width.priority = 500u;
    metadata.tools.branches.entries["extra"] = ConfigBranchMetadata!Entry.init;
    metadata.tools.branches.entries["extra"].shaped = true;
    assert(builder.submitBorrowed(registered.value, input, metadata).kind == ConfigErrorKind.invalidMetadata);
    assert(builder.usage == before);
    metadata.tools.branches.entries.remove("extra");
    assert(builder.submitBorrowed(registered.value, input, metadata).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    assert(snapshot.visitOption!((scope ref const OptionView!int view) {
        assert(view.selectedPriority == 500 && view.effective.get == 8);
    })(`tools["k"].width`).kind == ConfigErrorKind.none);
}

/// Empty prototypes still determine depth; dynamic instances do not add patterns.
@("wired.config.collections.declaredPatternDepthAndLimitValidation")
@safe unittest
{
    struct Deep { string[][][] paths; }
    ConfigLimits limits;
    limits.maxDepth = 3;
    auto tooShallow = ConfigBuilder!Deep.create(limits);
    assert(tooShallow.hasError && tooShallow.error.kind == ConfigErrorKind.limitExceeded);
    limits.maxDepth = 4;
    auto deep = ConfigBuilder!Deep.create(limits);
    assert(deep.hasValue);
    auto deepBuilder = deep.takeValue();
    assert(deepBuilder.usage.depth == 4);
    static foreach (field; ["maxValueNodes", "maxResolvedRecords", "maxContributions"])
    {{
        ConfigLimits invalid;
        __traits(getMember, invalid, field) = 0;
        auto rejected = ConfigBuilder!Deep.create(invalid);
        assert(rejected.hasError && rejected.error.kind == ConfigErrorKind.invalidLimits);
    }}
    struct Entry { int width = 4; }
    struct Settings { @(ConfigMerge!(AttrsOf!Submodule)()) Entry[string] tools; }
    limits = ConfigLimits.init;
    limits.maxOptions = 1;
    auto tooFewPatterns = ConfigBuilder!Settings.create(limits);
    assert(tooFewPatterns.hasError && tooFewPatterns.error.kind == ConfigErrorKind.limitExceeded);
    limits.maxOptions = 2;
    auto created = ConfigBuilder!Settings.create(limits);
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto source = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "");
    assert(source.hasValue);
    auto decoded = decodeConfigInput!Settings(`{"tools":{"a":{},"b":{},"c":{}}}`);
    assert(decoded.hasValue);
    auto capsule = decoded.takeValue();
    assert(builder.submitOwned(source.value, capsule).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    assert(snapshot.usage.options == 2);
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.tools["a"].width == 4
        && copied.value.tools["b"].width == 4 && copied.value.tools["c"].width == 4);
}

/// Quoted runtime key addresses and byte-ordered enumeration use typed keys.
@("wired.config.collections.canonicalMapKeysAndBranchEnumeration")
@safe unittest
{
    struct Settings { @(ConfigMerge!(AttrsOf!Atomic)()) int[string] tools; }
    auto snapshot = decodedSnapshot!Settings(
        `{"tools":{"é":8,"a.b":3,"[x]":2,"":1,"quote\"":6,"slash\\":7,"<key>":9,"a":4,"aa":5}}`);
    immutable string[9] paths = [
        `tools[""]`, `tools["<key>"]`, `tools["[x]"]`, `tools["a"]`,
        `tools["a.b"]`, `tools["aa"]`, `tools["quote\""]`, `tools["slash\\"]`, `tools["é"]`,
    ];
    immutable int[9] values = [1, 9, 2, 4, 3, 5, 6, 7, 8];
    size_t at;
    assert(snapshot.visitBranches!((scope ref const view) {
        static if (is(typeof(view) == const(BranchView!int)))
        {
            assert(at < paths.length);
            assert(view.path == paths[at] && !view.declaredOption && view.effective.get == values[at]);
            ++at;
        }
    })().kind == ConfigErrorKind.none);
    assert(at == paths.length);
    foreach (i, path; paths)
    {
        bool visited;
        assert(snapshot.visitBranch!((scope ref const BranchView!int view) {
            visited = true;
            assert(view.effective.get == values[i]);
        })(path).kind == ConfigErrorKind.none && visited);
    }
    bool called;
    auto patternAsRuntime = snapshot.visitBranch!((scope ref const BranchView!int view) {
        called = true;
    })("tools[<key>]");
    assert(patternAsRuntime.kind == ConfigErrorKind.unknownOption && !called);
}

/// Value locations identify original occurrences, not another identical element.
@("wired.config.collections.originalOccurrenceErrorLocations")
@safe unittest
{
    import std.string : indexOf;
    struct Entry { bool enabled = true; }
    struct Settings { @(ConfigMerge!(ListOf!Submodule)()) Entry[] plugins; }
    immutable text = "{\n  \"plugins\": [\n    {\"enabled\": true},\n    {\"enabled\": \"bad\"}\n  ]\n}";
    auto rejected = decodeConfigInput!Settings(text);
    assert(rejected.hasJsonError && rejected.jsonError.path[] == ".plugins[1].enabled");
    assert(rejected.jsonError.offset == indexOf(text, `"bad"`)
        && rejected.jsonError.line == 4 && rejected.jsonError.column == 17);
    struct MapSettings { @(ConfigMerge!(AttrsOf!Submodule)()) Entry[string] tools; }
    immutable mapText = "{\"tools\":{\"a\":{\"ignored\":{\"deep\":[[[]]]},\"enabled\":true},\"b\":{\"enabled\":\"bad\"}}}";
    auto mapRejected = decodeConfigInput!MapSettings(mapText,
        DefinitionMetadata!MapSettings.init, ConfigLimits.init,
        ConfigDecodeOptions(ConfigUnknownMembers.ignore));
    assert(mapRejected.hasJsonError && mapRejected.jsonError.path[] == ".tools.b.enabled");
    assert(mapRejected.jsonError.offset == indexOf(mapText, `"bad"`));
}

/// Equal enum aliases within one document duplicate; separate roots may overlap.
@("wired.config.collections.enumAliasKeysAcrossDefinitions")
@safe unittest
{
    enum Key : int { first = 1, aliasFirst = 1, second = 2 }
    struct Settings { @(ConfigMerge!(AttrsOf!Atomic)()) int[Key] tools; }
    auto duplicate = decodeConfigInput!Settings(`{"tools":{"first":7,"aliasFirst":9}}`);
    assert(duplicate.hasJsonError);
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    foreach (id; ["u", "p"])
    {
        auto registered = builder.registerSource(SourceId(id), ConfigSourceKind.custom, "");
        assert(registered.hasValue);
        Settings value;
        value.tools[id == "u" ? Key.first : Key.aliasFirst] = id == "u" ? 7 : 9;
        auto input = fullConfigInput!Settings(value);
        assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.none);
    }
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    bool found;
    assert(snapshot.visitBranches!((scope ref const view) {
        static if (is(typeof(view) == const(BranchView!int)))
        {
            found = true;
            assert(view.status == OptionStatus.conflict && !view.effective.hasValue
                && view.contributors.length == 2);
        }
    })().kind == ConfigErrorKind.none);
    assert(found);
}

/// Arena-owned branch string values cannot escape a safe visitor.
@("wired.config.collections.scopedBranchValueEscape")
@safe unittest
{
    struct Settings { @(ConfigMerge!(ListOf!Atomic)()) string[] paths; }
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!Settings owner;
        const(char)[] escaped;
        auto visited = owner.visitBranch!((scope ref const BranchView!string view) @safe {
            escaped = view.effective.get;
        })("paths[0]");
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!Settings owner;
        const(char)[] escaped;
        auto visited = owner.visitBranchDefinitions!((scope ref const BranchDefinitionView!string view) @safe {
            escaped = view.value.get;
        })("paths[0]");
    })()));
}

/// Selected collection built-ins contribute once; stronger roots discard them.
@("wired.config.collections.selectedListBuiltinAndPriorityOrder")
@safe unittest
{
    struct Settings { @(ConfigMerge!(ListOf!Atomic)()) string[] paths = ["bundle"]; }
    {
        auto created = ConfigBuilder!Settings.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.paths == ["bundle"]);
    }
    foreach (projectStrong; [false, true])
    {
        auto created = ConfigBuilder!Settings.create(ConfigLimits.init, 1000, 0);
        assert(created.hasValue);
        auto builder = created.takeValue();
        auto u = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "", 1000, 20);
        auto p = builder.registerSource(SourceId("p"), ConfigSourceKind.custom, "", projectStrong ? 500 : 1000, 10);
        assert(u.hasValue && p.hasValue);
        Settings user, project;
        user.paths = ["user-a", "user-b"];
        project.paths = ["project"];
        auto ui = fullConfigInput!Settings(user);
        auto pi = fullConfigInput!Settings(project);
        assert(builder.submitBorrowed(u.value, ui).kind == ConfigErrorKind.none);
        assert(builder.submitBorrowed(p.value, pi).kind == ConfigErrorKind.none);
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        string[] expected = projectStrong ? ["project"] : ["bundle", "project", "user-a", "user-b"];
        assert(copied.hasValue && copied.value.paths == expected);
    }
    struct Extremes { @(ConfigMerge!(ListOf!Atomic)()) int[] paths; }
    auto created = ConfigBuilder!Extremes.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    foreach (i, order; [int.max, int.min, 0])
    {
        auto registered = builder.registerSource(SourceId(i == 0 ? "max" : i == 1 ? "min" : "zero"),
            ConfigSourceKind.custom, "", 1000, order);
        assert(registered.hasValue);
        Extremes value;
        value.paths = [cast(int) i];
        auto input = fullConfigInput!Extremes(value);
        assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.none);
    }
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.paths == [1, 2, 0]);
}

/// Direct section checks see the complete merge and keep successful children inspectable.
@("wired.config.collections.directSectionMergedCheckAndSuppression")
@safe unittest
{
    struct Section { int width = 2; int height = 3; }
    static ValidationResult different(in Section value) @safe pure nothrow @nogc
        => value.width != value.height ? ValidationResult.accept()
            : ValidationResult.reject("equal", "width and height must differ");
    struct Settings
    {
        @(ConfigMerge!Submodule()) @(ConfigCheck!different())
        Section section = Section(5, 6);
    }
    {
        auto snapshot = decodedSnapshot!Settings(`{}`);
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.section.width == 5 && copied.value.section.height == 6);
    }
    {
        auto snapshot = decodedSnapshot!Settings(`{"section":{"width":8,"height":8}}`);
        auto refused = snapshot.copyConfig();
        assert(refused.hasError && refused.error.failedOptions == ["section"]);
        auto visited = snapshot.visitBranch!((scope ref const BranchView!Section view) {
            assert(view.status == OptionStatus.invalidMergedValue && !view.effective.hasValue);
            assert(view.diagnostic.hasValue && view.diagnostic.get.code == "equal"
                && view.diagnostic.get.detail == "width and height must differ");
            assert(view.contributors.length == 2 && !view.declaredOption);
        })("section");
        assert(visited.kind == ConfigErrorKind.none);
        auto child = snapshot.visitOption!((scope ref const OptionView!int view) {
            assert(view.status == OptionStatus.resolved && view.effective.get == 8);
        })("section.width");
        assert(child.kind == ConfigErrorKind.none);
    }
    static ValidationResult neverRun(in Section value) @safe pure nothrow @nogc
    {
        assert(false, "A failed child must suppress its section check");
    }
    struct Suppressed
    {
        @(ConfigMerge!Submodule()) @(ConfigCheck!neverRun()) Section section;
    }
    auto created = ConfigBuilder!Suppressed.create(ConfigLimits.init, 1000);
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto source = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "", 1000);
    assert(source.hasValue);
    auto decoded = decodeConfigInput!Suppressed(`{"section":{"width":8}}`);
    assert(decoded.hasValue);
    auto input = decoded.takeValue();
    assert(builder.submitOwned(source.value, input).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasError && copied.error.failedOptions == ["section.width"]);
    auto inspected = snapshot.visitBranch!((scope ref const BranchView!Section view) {
        assert(view.status == OptionStatus.unresolvedChildren && !view.effective.hasValue);
        assert(view.failedChildren == ["section.width"] && !view.diagnostic.hasValue);
    })("section");
    assert(inspected.kind == ConfigErrorKind.none);
    auto sibling = snapshot.visitOption!((scope ref const OptionView!int view) {
        assert(view.status == OptionStatus.resolved && view.effective.get == 3);
    })("section.height");
    assert(sibling.kind == ConfigErrorKind.none);
}
