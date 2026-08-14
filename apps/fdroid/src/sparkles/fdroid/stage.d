/**
How far a publish run goes.

Cumulative, in the same shape and vocabulary as `release --stage`: naming a
stage runs it and everything before it. The default stops short of the one
irreversible step, so the outward action is always something the operator asked
for by name.
*/
module sparkles.fdroid.stage;

@safe:

/// Ordered so `<=` means "at or before"; `requiredFor` and the runner both rely
/// on the ordering, not just the identity.
enum Stage
{
    /// Derive the version from the tag and build the unsigned release APK.
    build,
    /// Sign it with the APK key and check the certificate against the pin.
    sign,
    /// Copy the live repo/ and archive/ down. `fdroid update` must hash every
    /// indexed APK, and the deploy is an `rclone sync` that deletes whatever is
    /// absent locally.
    pull,
    /// Guard the version against what is published, then `fdroid update`.
    index,
    /// Push the result back. The irreversible one.
    deploy,
}

/// The default: everything except publishing. A full dress rehearsal, including
/// signing and index generation, that no user can observe.
enum Stage defaultStage = Stage.index;

/// Parses a `--stage` value.
bool tryParseStage(string s, out Stage stage) pure nothrow
{
    switch (s)
    {
    case "build":  stage = Stage.build;  return true;
    case "sign":   stage = Stage.sign;   return true;
    case "pull":   stage = Stage.pull;   return true;
    case "index":  stage = Stage.index;  return true;
    case "deploy": stage = Stage.deploy; return true;
    default: return false;
    }
}

/// The accepted values, for help text and error messages.
string stageNames() pure nothrow => "build, sign, pull, index, deploy";

@("fdroid.stage.parsesAndOrders")
@safe unittest
{
    Stage s;
    assert(tryParseStage("build", s) && s == Stage.build);
    assert(tryParseStage("deploy", s) && s == Stage.deploy);
    assert(!tryParseStage("publish", s));
    assert(!tryParseStage("", s));

    // Cumulative ordering is what `stage >= Stage.x` checks depend on.
    assert(Stage.build < Stage.sign);
    assert(Stage.sign < Stage.pull);
    assert(Stage.pull < Stage.index);
    assert(Stage.index < Stage.deploy);

    // The default must not be the irreversible one.
    assert(defaultStage < Stage.deploy);
}
