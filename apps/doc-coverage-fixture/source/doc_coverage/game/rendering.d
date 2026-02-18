module doc_coverage.game.rendering;

/// Trait-like template used in docs for constraints.
bool hasRenderName(T) = is(typeof(T.renderName));

/// Renders type names for diagnostic overlays.
///
/// Example:
/// ---
/// struct Sprite { enum renderName = "sprite"; }
/// assert(renderLabel(Sprite.init) == "sprite");
/// ---
string renderLabel(T)(T value)
if (hasRenderName!T)
{
    return value.renderName;
}

struct Sprite
{
    enum renderName = "sprite";
}

@("docCoverage.game.rendering.renderLabel")
@safe
unittest
{
    assert(renderLabel(Sprite.init) == "sprite");
}
