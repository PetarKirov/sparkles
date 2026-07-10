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
}

/// Parses a `--stage` token; null on an unknown token.
Nullable!Stage parseStage(scope const(char)[] s)
{
    switch (s)
    {
        case "create-tag":              return nullable(Stage.createTag);
        case "push-tag":                return nullable(Stage.pushTag);
        case "create-gh-release-draft": return nullable(Stage.createGhReleaseDraft);
        case "publish-gh-release":      return nullable(Stage.publishGhRelease);
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
            Stage.createGhReleaseDraft, Stage.publishGhRelease])
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
}
