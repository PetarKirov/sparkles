/**
How far a publish run goes.

Cumulative, in the same shape and vocabulary as `release --stage`: naming a
stage runs it and everything before it. The default stops short of the one
irreversible step, so the outward action is always something the operator asked
for by name.
*/
module sparkles.release.store.stage;

@safe:

/// Ordered so `<=` means "at or before"; `requiredFor` and the runner both rely
/// on the ordering, not just the identity.
enum PublishStage
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
enum PublishStage defaultStage = PublishStage.index;

/// Parses a `--stage` value.
bool tryParseStage(string s, out PublishStage stage) pure nothrow
{
    switch (s)
    {
    case "build":  stage = PublishStage.build;  return true;
    case "sign":   stage = PublishStage.sign;   return true;
    case "pull":   stage = PublishStage.pull;   return true;
    case "index":  stage = PublishStage.index;  return true;
    case "deploy": stage = PublishStage.deploy; return true;
    default: return false;
    }
}

/// The accepted values, for help text and error messages.
string publishStageNames() pure nothrow => "build, sign, pull, index, deploy";

@("store.stage.parsesAndOrders")
@safe unittest
{
    PublishStage s;
    assert(tryParseStage("build", s) && s == PublishStage.build);
    assert(tryParseStage("deploy", s) && s == PublishStage.deploy);
    assert(!tryParseStage("publish", s));
    assert(!tryParseStage("", s));

    // Cumulative ordering is what `stage >= PublishStage.x` checks depend on.
    assert(PublishStage.build < PublishStage.sign);
    assert(PublishStage.sign < PublishStage.pull);
    assert(PublishStage.pull < PublishStage.index);
    assert(PublishStage.index < PublishStage.deploy);

    // The default must not be the irreversible one.
    assert(defaultStage < PublishStage.deploy);
}
