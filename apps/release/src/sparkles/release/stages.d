/++
The cumulative release stages.

`--stage` names how far the tool goes; each stage implies the earlier ones, so
the enum is ordered and $(LREF stageAtLeast) is a simple `>=`. The actual side
effects (tag, push, GitHub release) live in `app.d`; this module is the pure
vocabulary so it can be unit-tested.
+/
module sparkles.release.stages;

import std.typecons : Nullable, nullable;

@safe pure nothrow @nogc:

/// Release stages in cumulative order: each implies the earlier ones.
enum Stage
{
    createTag,            /// create the local annotated tag (default)
    pushTag,              /// also `git push origin <tag>`
    createGhReleaseDraft, /// also `gh release create --draft`
    publishGhRelease,     /// also publish the GitHub release (fires the release workflow)
    publishApps,          /// also sign and publish the app stores (see below)
}

/**
Why the Android channel is a stage and not a separate errand.

`publish-apps` signs the release artifacts with a key on a hardware token and
publishes every app channel — the self-hosted F-Droid repository and Google
Play. Two consequences follow from that, and both are deliberate:

$(UL
$(LI It cannot run where the earlier stages usually do. A GitHub-hosted runner
    has no USB token, so reaching this stage from CI fails — by design. The
    stage is meant to be typed on the workstation that holds the tokens.)
$(LI It is last, and the ladder is cumulative, so it is only ever reached when
    named. The default remains `create-tag`; nothing drifts into publishing an
    app by accident.)
)

The guards that make this safe live in `sparkles.release.store`: it refuses to
reuse a published `versionCode`, refuses to build the artifact locally rather
than substituting what CI built, and verifies the signing certificate against
the pin in the metadata.

One stage covers both channels rather than one each, because they are peers:
neither is the primary, and a linear ladder cannot express "these two, in no
particular order".
*/

/// Parses a `--stage` token; null on an unknown token.
Nullable!Stage parseStage(scope const(char)[] s)
{
    switch (s)
    {
        case "create-tag":              return nullable(Stage.createTag);
        case "push-tag":                return nullable(Stage.pushTag);
        case "create-gh-release-draft": return nullable(Stage.createGhReleaseDraft);
        case "publish-gh-release":      return nullable(Stage.publishGhRelease);
        case "publish-apps":            return nullable(Stage.publishApps);
        default:                        return Nullable!Stage.init;
    }
}

/// The `--stage` token for `s` (inverse of $(LREF parseStage)).
string stageToken(Stage s)
{
    final switch (s)
    {
        case Stage.createTag:            return "create-tag";
        case Stage.pushTag:              return "push-tag";
        case Stage.createGhReleaseDraft: return "create-gh-release-draft";
        case Stage.publishGhRelease:     return "publish-gh-release";
        case Stage.publishApps:          return "publish-apps";
    }
}

/// True when the `chosen` stage reaches at least `step` (so `step` should run).
bool stageAtLeast(Stage chosen, Stage step) => chosen >= step;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("stages.parseStage.roundTrip")
@safe pure nothrow @nogc
unittest
{
    static foreach (s; [Stage.createTag, Stage.pushTag,
            Stage.createGhReleaseDraft, Stage.publishGhRelease, Stage.publishApps])
        assert(parseStage(stageToken(s)).get == s);

    assert(parseStage("nonsense").isNull);
}

@("stages.stageAtLeast.cumulative")
@safe pure nothrow @nogc
unittest
{
    // publish implies every earlier stage.
    assert(stageAtLeast(Stage.publishGhRelease, Stage.createTag));
    assert(stageAtLeast(Stage.publishGhRelease, Stage.pushTag));
    // create-tag (default) implies only itself.
    assert(stageAtLeast(Stage.createTag, Stage.createTag));
    assert(!stageAtLeast(Stage.createTag, Stage.pushTag));
    assert(!stageAtLeast(Stage.pushTag, Stage.createGhReleaseDraft));

    // The app stores are last, and publishing the GitHub release does NOT
    // reach them — the two halves run on different machines.
    assert(stageAtLeast(Stage.publishApps, Stage.publishGhRelease));
    assert(!stageAtLeast(Stage.publishGhRelease, Stage.publishApps));
}
