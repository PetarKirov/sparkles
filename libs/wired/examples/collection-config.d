#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_collection_config"
    dependency "sparkles:wired" path="../../.."
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
module wired_collection_config;

import std.stdio : stdout, writeln;
import sparkles.base.text.writers : writeText;
import sparkles.wired.config : AttrsOf, BranchDefinitionView, BranchView,
    ConfigBuilder, ConfigErrorKind, ConfigMerge, ConfigSourceKind, DefinitionDisposition, ListOf,
    OptionStatus, SourceId, Submodule, decodeConfigInput, visitBranch, visitBranchDefinitions;

struct Plugin
{
    string label = "default";
    bool enabled = true;
}

struct Tool
{
    int width = 4;
    bool enabled = true;
}

struct Settings
{
    @(ConfigMerge!(ListOf!Submodule)()) Plugin[] plugins;
    @(ConfigMerge!(AttrsOf!Submodule)()) Tool[string] tools;
}

void main() @safe
{
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto user = builder.registerSource(SourceId("user"), ConfigSourceKind.userFile, "user.json");
    auto project = builder.registerSource(SourceId("project"), ConfigSourceKind.projectFile, "project.json");
    assert(user.hasValue && project.hasValue);
    auto userDecoded = decodeConfigInput!Settings(
        `{"plugins":[{"label":"user"}],"tools":{"build":{"width":12}}}`);
    auto projectDecoded = decodeConfigInput!Settings(
        `{"plugins":[{"label":"project","enabled":false}],"tools":{"build":{"enabled":false},"lint":{"width":6}}}`);
    assert(userDecoded.hasValue && projectDecoded.hasValue);
    auto userInput = userDecoded.takeValue();
    auto projectInput = projectDecoded.takeValue();
    auto userError = builder.submitOwned(user.value, userInput);
    auto projectError = builder.submitOwned(project.value, projectInput);
    assert(userError.kind == ConfigErrorKind.none && projectError.kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue);
    foreach (i, plugin; copied.value.plugins)
        writeln("plugins[", i, "]: ", plugin.label, ", enabled=", plugin.enabled);
    writeln("build: width=", copied.value.tools["build"].width,
        ", enabled=", copied.value.tools["build"].enabled);
    writeln("lint: width=", copied.value.tools["lint"].width,
        ", enabled=", copied.value.tools["lint"].enabled);
    auto inspected = snapshot.visitBranch!((scope ref const BranchView!int view) {
        auto writer = (() @trusted => stdout.lockingTextWriter)();
        writeText(writer, i"$(view.path): $(view.status), value=$(view.effective.get)\n");
    })(`tools["build"].width`);
    assert(inspected.kind == ConfigErrorKind.none);
    auto definitions = snapshot.visitBranchDefinitions!((scope ref const BranchDefinitionView!string view) {
        if (view.disposition == DefinitionDisposition.contributing)
        {
            auto writer = (() @trusted => stdout.lockingTextWriter)();
            writeText(writer, i"original=$(view.originalLocator), effective=$(view.path)\n");
        }
    })("plugins[1].label");
    assert(definitions.kind == ConfigErrorKind.none);

    // Equally preferred members conflict; successful siblings stay inspectable.
    auto conflictCreated = ConfigBuilder!Settings.create();
    assert(conflictCreated.hasValue);
    auto conflictBuilder = conflictCreated.takeValue();
    auto left = conflictBuilder.registerSource(SourceId("left"), ConfigSourceKind.custom, "");
    auto right = conflictBuilder.registerSource(SourceId("right"), ConfigSourceKind.custom, "");
    assert(left.hasValue && right.hasValue);
    auto leftDecoded = decodeConfigInput!Settings(`{"tools":{"build":{"width":12}}}`);
    auto rightDecoded = decodeConfigInput!Settings(`{"tools":{"build":{"width":13}}}`);
    assert(leftDecoded.hasValue && rightDecoded.hasValue);
    auto leftInput = leftDecoded.takeValue();
    auto rightInput = rightDecoded.takeValue();
    auto leftError = conflictBuilder.submitOwned(left.value, leftInput);
    auto rightError = conflictBuilder.submitOwned(right.value, rightInput);
    assert(leftError.kind == ConfigErrorKind.none && rightError.kind == ConfigErrorKind.none);
    auto conflictResolved = conflictBuilder.resolve();
    assert(conflictResolved.hasValue);
    auto conflictSnapshot = conflictResolved.takeValue();
    auto rejectedCopy = conflictSnapshot.copyConfig();
    assert(rejectedCopy.hasError && rejectedCopy.error.kind == ConfigErrorKind.notFullyResolved);
    auto conflictInspected = conflictSnapshot.visitBranch!((scope ref const BranchView!int view) {
        assert(view.status == OptionStatus.conflict && !view.effective.hasValue
            && view.contributors.length == 2);
        auto writer = (() @trusted => stdout.lockingTextWriter)();
        writeText(writer, i"conflict=$(view.path), contributors=$(view.contributors.length)\n");
    })(`tools["build"].width`);
    assert(conflictInspected.kind == ConfigErrorKind.none);
    auto siblingInspected = conflictSnapshot.visitBranch!((scope ref const BranchView!bool view) {
        assert(view.effective.hasValue && view.effective.get);
    })(`tools["build"].enabled`);
    assert(siblingInspected.kind == ConfigErrorKind.none);
}
