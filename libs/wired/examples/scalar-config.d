#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_scalar_config"
    dependency "sparkles:wired" path="../../.."
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
module wired_scalar_config;

import std.stdio : writeln;
import sparkles.wired.config : ConfigBuilder, ConfigErrorKind, ConfigInput,
    ConfigSourceKind, DefinitionView, OptionStatus, OptionView, SourceId,
    decodeConfigInput, visitDefinitions, visitOption;
import sparkles.wired.policy : WireName;

struct Settings
{
    @WireName("tab-width") int tabWidth = 4;
}

void main() @safe
{
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto source = builder.registerSource(SourceId("user"),
        ConfigSourceKind.userFile, "settings.json", 1000);
    assert(source.hasValue);
    auto decoded = decodeConfigInput!Settings(`{"tab-width":8}`);
    assert(decoded.hasValue);
    auto input = decoded.takeValue();
    auto submitted = builder.submitOwned(source.value, input);
    assert(submitted.kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue);
    writeln("tabWidth=", copied.value.tabWidth);

    // The same public pipeline can inspect a complete failure without
    // fabricating a successful configuration or overwriting caller input.
    auto conflictCreated = ConfigBuilder!Settings.create();
    assert(conflictCreated.hasValue);
    auto conflictBuilder = conflictCreated.takeValue();
    auto user = conflictBuilder.registerSource(SourceId("user"),
        ConfigSourceKind.userFile, "user.json", 1000);
    auto project = conflictBuilder.registerSource(SourceId("project"),
        ConfigSourceKind.projectFile, "project.json", 1000);
    assert(user.hasValue && project.hasValue);
    ConfigInput!Settings userInput;
    userInput.tabWidth.supplied = true;
    userInput.tabWidth.value = 8;
    ConfigInput!Settings projectInput;
    projectInput.tabWidth.supplied = true;
    projectInput.tabWidth.value = 16;
    auto userSubmitted = conflictBuilder.submitBorrowed(user.value, userInput);
    auto projectSubmitted = conflictBuilder.submitBorrowed(project.value, projectInput);
    assert(userSubmitted.kind == ConfigErrorKind.none);
    assert(projectSubmitted.kind == ConfigErrorKind.none);
    auto conflictResolved = conflictBuilder.resolve();
    assert(conflictResolved.hasValue);
    auto conflict = conflictResolved.takeValue();
    auto inspected = conflict.visitOption!((scope ref const OptionView!int view) {
        assert(view.path == "tabWidth"
            && view.status == OptionStatus.conflict && !view.effective.hasValue);
        writeln("tabWidth: ", view.status, " at priority ", view.selectedPriority);
    })("tabWidth");
    assert(inspected.kind == ConfigErrorKind.none);
    auto definitions = conflict.visitDefinitions!((scope ref const DefinitionView!int view) {
        writeln("  ", view.priority, " ", view.value.get, " ", view.disposition);
    })("tabWidth");
    assert(definitions.kind == ConfigErrorKind.none);
    auto refused = conflict.copyConfig();
    assert(refused.hasError && refused.error.kind == ConfigErrorKind.notFullyResolved);
    assert(userInput.tabWidth.value == 8 && projectInput.tabWidth.value == 16);
}
