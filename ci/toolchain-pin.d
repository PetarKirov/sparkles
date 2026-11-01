#!/usr/bin/env dub
/+ dub.sdl:
    name "toolchain-pin"
    dependency "sparkles:core-cli" path=".."
    dependency "sparkles:base" path=".."
    dependency "sparkles:ui" path=".."
    dependency "sparkles:event-horizon" path=".."
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    dflags "-i=derivation_pin" "-i=derivation_pin_cachix" "-i=derivation_pin_process"
    dflags "-i=derivation_pin_set" "-i=derivation_pin_signals"
    dflags "-I$PACKAGE_DIR/../apps/ci/src"

    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    configuration "application" {
        targetType "executable"
    }
+/
/// Push and pin derivations with scoped Event Horizon fibers.
module toolchain_pin;

import sparkles.core_cli.args : runCli;

import derivation_pin : ToolchainPin;

version (unittest) {}
else
int main(string[] args) => runCli!ToolchainPin(args);
